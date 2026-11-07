"""LifeLog PC 版 7: 家の PC から iPhone を起こす（APNs の見えない通知）。

決まりは docs/v7-plan.md の「3. 見えない通知」。
- 鍵: <home>/apns/AuthKey_<KEYID>.p8（見守りの画面から入れるか、手で置く）。チーム（team）は、iPhone が /diag の push で
  知らせてくる（<home>/apns/config.json に "team" があれば、そちらを使う）。鍵かチームが無いときは何もしない（エラーにしない）。
- HTTP/2 で api.push.apple.com（開発用は api.sandbox.push.apple.com）に、ES256 の JWT（kid = 鍵の ID、iss = チーム）で送る。
- 端末ごとのトークン・送った時刻・使えなくなったトークン（APNs が 410 を返したもの）は <home>/apns/state.json に置く。
- 送る回数の上限: job は同じ端末へ10分に1回、wake は1時間に2回・1日12回、diag は1日4回（1時間に1回まで）、
  nightly は1日1回。上限を超えるものは送らない（数えるのは、APNs が受け取った 200 のものだけ）。
記録（log.txt）には、端末の種類・送った種類・答えの番号だけを書く（トークンは書かない）。
"""

from __future__ import annotations

import base64
import json
import os
import re
import threading
import time
from pathlib import Path
from typing import Callable

KEY_FILE = re.compile(r"AuthKey_([A-Z0-9]{10})\.p8")
KEY_ID = re.compile(r"[A-Z0-9]{10}")
TEAM = re.compile(r"[A-Z0-9]{10}")
TOKEN = re.compile(r"[0-9a-fA-F]{32,512}")
TOPIC_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9.\-]{0,150}")
TOPIC = "com.off53jub.lifelog"
HOSTS = {"production": "https://api.push.apple.com", "development": "https://api.sandbox.push.apple.com"}
JWT_EVERY = 45 * 60          # APNs の JWT は 20 分〜60 分ごとに作り直す
KINDS = ("wake", "job", "nightly", "diag", "test")
# (秒, 回数): その秒の間に送ってよい回数（端末ごと）
LIMITS = {"job": ((600, 1),), "wake": ((3600, 2), (86400, 12)), "diag": ((3600, 1), (86400, 4)),
          "nightly": ((20 * 3600, 1),), "test": ((10, 1),)}
# APNs が届けるのをあきらめるまでの秒（端末が電波の無い所にいるとき）
EXPIRE = {"job": 3600, "wake": 1800, "diag": 3600, "nightly": 3 * 3600, "test": 600}
TEST_ALERT = {"title": "LifeLog PC", "body": "テストの通知です（家の PC から届きました）"}
HISTORY = 50
DEAD_KEEP = 90 * 86400
TIMEOUT = 20.0


def payload(kind: str, job: str | None = None) -> dict:
    """送る中身。test だけは目に見える通知、ほかは見えない通知"""
    if kind == "test":
        return {"aps": {"alert": dict(TEST_ALERT), "sound": "default"}, "lifelog": {"kind": "test"}}
    body: dict = {"aps": {"content-available": 1}, "lifelog": {"kind": kind}}
    if kind == "job" and job:
        body["lifelog"]["job"] = job
    return body


def headers_for(kind: str, topic: str, token: str, now: float) -> dict:
    """APNs に付ける見出し（authorization は jwt を作ってから足す）"""
    alert = kind == "test"
    return {"authorization": f"bearer {token}", "apns-push-type": "alert" if alert else "background",
            "apns-priority": "10" if alert else "5", "apns-topic": topic,
            "apns-expiration": str(int(now + EXPIRE.get(kind, 3600)))}


# MARK: - 鍵と JWT（ES256）


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def es256_jwt(key, header: dict, claims: dict) -> str:
    """ES256 で署名した JWT（署名は r と s をそれぞれ 32 バイトにつなげたもの）"""
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

    signing = (b64url(json.dumps(header, separators=(",", ":")).encode("utf-8")) + "."
               + b64url(json.dumps(claims, separators=(",", ":")).encode("utf-8")))
    r, s = decode_dss_signature(key.sign(signing.encode("ascii"), ec.ECDSA(hashes.SHA256())))
    return signing + "." + b64url(r.to_bytes(32, "big") + s.to_bytes(32, "big"))


def load_p8(data: bytes | str):
    """App Store Connect・APNs の .p8（PKCS#8 の P-256 の秘密鍵）を読む。違えば ValueError。"""
    try:
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric import ec
    except Exception as error:  # noqa: BLE001
        raise ValueError(f"鍵を読む部品（cryptography）がありません: {error}") from error
    if isinstance(data, str):
        data = data.encode("utf-8")
    try:
        key = serialization.load_pem_private_key(data.strip() + b"\n", password=None)
    except Exception as error:  # noqa: BLE001
        raise ValueError("鍵のファイルが読めません（.p8 の中身をそのまま入れてください）") from error
    if not isinstance(key, ec.EllipticCurvePrivateKey) or key.curve.name != "secp256r1":
        raise ValueError("P-256 の鍵ではありません（App Store Connect で作った .p8 を入れてください）")
    return key


def find_key(folder: Path) -> tuple[str, Path] | None:
    """folder の AuthKey_<KEYID>.p8（いくつかあれば、新しく置いたもの）。無ければ None。"""
    found = []
    try:
        for path in Path(folder).iterdir():
            match = KEY_FILE.fullmatch(path.name)
            if match and path.is_file():
                found.append((path.stat().st_mtime, match.group(1), path))
    except OSError:
        return None
    if not found:
        return None
    _, key_id, path = max(found)
    return key_id, path


def save_key(folder: Path, key_id: str, pem: str) -> Path:
    """見守りの画面から入れた鍵を folder/AuthKey_<KEYID>.p8 に置く（前の鍵は .old に名前を変える）。おかしければ ValueError。"""
    key_id = (key_id or "").strip().upper()
    if not KEY_ID.fullmatch(key_id):
        raise ValueError("鍵の ID は英数字 10 文字です（AuthKey_XXXXXXXXXX.p8 の XXXXXXXXXX）")
    load_p8(pem)
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / f"AuthKey_{key_id}.p8"
    part = target.with_name(target.name + ".part")
    part.write_text(pem.strip() + "\n", encoding="utf-8")
    os.replace(part, target)
    for path in folder.iterdir():
        if KEY_FILE.fullmatch(path.name) and path != target:
            os.replace(path, path.with_name(path.name + ".old"))
    return target


def http2_available() -> bool:
    """HTTP/2 で送る部品（httpx2 と h2）があるか"""
    try:
        import h2.connection  # noqa: F401
        import httpx2  # noqa: F401
    except Exception:  # noqa: BLE001
        return False
    return True


def _read_json(path: Path) -> dict:
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def _write_json(path: Path, body: dict) -> None:
    part = path.with_name(path.name + ".part")
    part.write_text(json.dumps(body, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(part, path)


# MARK: - 送る


class Pusher:
    """端末のトークンを覚えて、決まりの回数の中で見えない通知を送る。"""

    def __init__(self, folder: Path, log: Callable[[str], None], clock: Callable[[], float] = time.time,
                 hosts: dict | None = None, post: Callable | None = None) -> None:
        self.folder = Path(folder)
        self.log = log
        self.clock = clock
        self.hosts = dict(hosts or HOSTS)
        self.post = post or self._http2_post
        self.lock = threading.RLock()
        self.send_lock = threading.Lock()
        self.jwt: dict[tuple[str, str], tuple[str, float]] = {}
        self.key_cache: tuple | None = None
        self.blocked: tuple[str, str] | None = None   # 鍵とチームが合わないと言われたもの（鍵かチームが変わるまで送らない）
        self.last_error: str | None = None
        self.folder.mkdir(parents=True, exist_ok=True)
        state = _read_json(self.folder / "state.json")
        self.devices: dict[str, dict] = state.get("devices") if isinstance(state.get("devices"), dict) else {}
        self.dead: dict[str, dict] = state.get("dead") if isinstance(state.get("dead"), dict) else {}
        self.sent: dict[str, dict] = state.get("sent") if isinstance(state.get("sent"), dict) else {}
        self.history: list[dict] = state.get("history") if isinstance(state.get("history"), list) else []

    # MARK: 状態

    def save(self) -> None:
        with self.lock:
            now = self.clock()
            for device in list(self.sent):
                for kind in list(self.sent[device]):
                    self.sent[device][kind] = [t for t in self.sent[device][kind] if now - float(t) < 86400 * 2]
            self.dead = {t: d for t, d in self.dead.items() if now - float(d.get("at") or 0) < DEAD_KEEP}
            body = {"devices": self.devices, "dead": self.dead, "sent": self.sent, "history": self.history[-HISTORY:]}
            try:
                _write_json(self.folder / "state.json", body)
            except OSError as error:
                self.log(f"通知: 状態を保存できませんでした: {error!r}")

    def config_team(self) -> str | None:
        team = str(_read_json(self.folder / "config.json").get("team") or "").strip().upper()
        return team if TEAM.fullmatch(team) else None

    def set_team(self, team: str) -> None:
        team = (team or "").strip().upper()
        if not TEAM.fullmatch(team):
            raise ValueError("チームの ID は英数字 10 文字です")
        config = _read_json(self.folder / "config.json")
        config["team"] = team
        _write_json(self.folder / "config.json", config)

    def key(self):
        """(鍵の ID, 鍵) か None。ファイルが変わったら読み直す。読めない鍵は一度だけ記録に書く。"""
        found = find_key(self.folder)
        if not found:
            self.key_cache = None
            return None
        key_id, path = found
        try:
            stamp = (str(path), path.stat().st_mtime)
        except OSError:
            return None
        if self.key_cache and self.key_cache[0] == stamp:
            return self.key_cache[1]
        try:
            value = (key_id, load_p8(path.read_bytes()))
        except (OSError, ValueError) as error:
            self.log(f"通知: 鍵 {path.name} を読めませんでした: {error}")
            value = None
        self.key_cache = (stamp, value)
        return value

    def team_for(self, device: str | None = None) -> str | None:
        team = self.config_team()
        if team:
            return team
        info = self.devices.get(device or "") or {}
        if TEAM.fullmatch(str(info.get("team") or "")):
            return str(info["team"])
        for other in self.devices.values():
            if TEAM.fullmatch(str(other.get("team") or "")):
                return str(other["team"])
        return None

    def ready(self) -> bool:
        """送れるか（鍵・チーム・HTTP/2 の部品がそろっているか）"""
        return self.key() is not None and self.team_for() is not None and http2_available()

    def register(self, device: str, push, kind: str | None = None, model: str | None = None) -> bool:
        """/diag の push（トークン・環境・トピック・チーム）を覚える。変わったら True。"""
        if not isinstance(push, dict):
            return False
        token = str(push.get("token") or "").strip().lower()
        if not TOKEN.fullmatch(token):
            return False
        environment = "development" if push.get("environment") == "development" else "production"
        topic = str(push.get("topic") or TOPIC)
        if not TOPIC_NAME.fullmatch(topic):
            topic = TOPIC
        team = str(push.get("team") or "").strip().upper().rstrip(".")
        entry = {"token": token, "environment": environment, "topic": topic,
                 "team": team if TEAM.fullmatch(team) else None,
                 "device": str(kind or "端末")[:40], "model": str(model or "")[:40], "updated": self.clock()}
        with self.lock:
            before = self.devices.get(device) or {}
            changed = any(before.get(k) != entry[k] for k in ("token", "environment", "topic", "team"))
            self.devices[device] = entry
            if changed:
                self.save()
        if changed:
            self.log(f"通知: {entry['device']} の通知の登録を覚えました（{environment}）")
        return changed

    def usable(self, device: str) -> bool:
        info = self.devices.get(device) or {}
        token = str(info.get("token") or "")
        return bool(token) and token not in self.dead

    def allowed(self, device: str, kind: str, now: float | None = None) -> bool:
        """回数の上限の中か"""
        now = self.clock() if now is None else now
        times = [float(t) for t in (self.sent.get(device) or {}).get(kind, [])]
        return all(sum(1 for t in times if now - t < window) < count for window, count in LIMITS.get(kind, ()))

    def sent_count(self, device: str, kind: str, within: float, now: float | None = None) -> int:
        now = self.clock() if now is None else now
        return sum(1 for t in (self.sent.get(device) or {}).get(kind, []) if now - float(t) < within)

    def token_for(self, key_id: str, key, team: str, force: bool = False) -> str:
        """JWT（45 分ごとに作り直す）"""
        now = self.clock()
        cached = self.jwt.get((key_id, team))
        if cached and not force and now - cached[1] < JWT_EVERY:
            return cached[0]
        token = es256_jwt(key, {"alg": "ES256", "kid": key_id}, {"iss": team, "iat": int(now)})
        self.jwt[(key_id, team)] = (token, now)
        return token

    # MARK: 送る

    def send(self, kind: str, devices: list[str] | None = None, job: str | None = None,
             respect_limits: bool = True) -> list[dict]:
        """kind の通知を、devices（None なら使えるトークンのある全部の端末）に送る。端末ごとの結果の並びを返す。
        鍵・チーム・部品が無いときは何もせず、理由だけを返す（記録には書かない）。"""
        if kind not in KINDS:
            raise ValueError(f"知らない通知の種類です: {kind}")
        found = self.key()
        if found is None:
            return [{"ok": False, "reason": "鍵がありません"}]
        if not http2_available():
            return [{"ok": False, "reason": "HTTP/2 で送る部品がありません"}]
        key_id, key = found
        with self.lock:
            targets = [d for d in (devices if devices is not None else list(self.devices)) if d in self.devices]
        results = []
        with self.send_lock:
            for device in targets:
                results.append(self._send_one(device, kind, job, key_id, key, respect_limits))
        if any(r.get("status") is not None for r in results):
            self.save()
        return results or [{"ok": False, "reason": "通知を登録した端末がありません"}]

    def _send_one(self, device: str, kind: str, job: str | None, key_id: str, key, respect_limits: bool) -> dict:
        info = dict(self.devices.get(device) or {})
        name = info.get("device") or "端末"
        if not self.usable(device):
            return {"device": device, "ok": False, "reason": "トークンが使えません（iPhone から新しいトークンが届くのを待ちます）"}
        team = self.team_for(device)
        if not team:
            return {"device": device, "ok": False, "reason": "チームの ID が分かりません"}
        if self.blocked == (key_id, team):
            return {"device": device, "ok": False, "reason": "鍵とチームの ID が合わないと言われています"}
        now = self.clock()
        if respect_limits and not self.allowed(device, kind, now):
            return {"device": device, "ok": False, "reason": "回数の上限です"}
        url = f"{self.hosts.get(info.get('environment'), self.hosts['production'])}/3/device/{info['token']}"
        body = json.dumps(payload(kind, job), ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        status, reason = None, None
        for attempt in range(2):
            try:
                headers = headers_for(kind, info.get("topic") or TOPIC, self.token_for(key_id, key, team, attempt > 0), now)
                status, _, raw = self.post(url, headers, body)
                try:
                    reason = (json.loads(raw or b"{}") or {}).get("reason")
                except ValueError:
                    reason = None
            except Exception as error:  # noqa: BLE001 — 送れなくても、ほかはいつもどおり動く
                status, reason = None, f"{type(error).__name__}: {error}"
            if status == 403 and reason == "ExpiredProviderToken" and attempt == 0:
                continue
            break
        with self.lock:
            self.history.append({"at": now, "device": device, "kind": kind, "status": status, "reason": reason})
            self.history = self.history[-HISTORY:]
            if status == 200:
                self.sent.setdefault(device, {}).setdefault(kind, []).append(now)
                self.last_error = None
            elif status == 410 or (status == 400 and reason == "BadDeviceToken"):
                self.dead[info["token"]] = {"at": now, "status": status, "reason": reason}
            elif status == 403 and reason == "InvalidProviderToken":
                self.blocked = (key_id, team)
            if status != 200:
                self.last_error = f"{kind} → {status if status is not None else '送れません'}" + (f" {reason}" if reason else "")
        if status == 200:
            self.log(f"通知: {name} へ {kind} を送りました（200）")
        elif status == 410 or (status == 400 and reason == "BadDeviceToken"):
            self.log(f"通知: {name} へ送れませんでした（{status} {reason}）。このトークンはもう使いません")
        else:
            self.log(f"通知: {name} へ {kind} を送れませんでした（{status if status is not None else '送れません'}"
                     + (f" {reason}" if reason else "") + "）")
        return {"device": device, "ok": status == 200, "status": status, "reason": reason}

    def _http2_post(self, url: str, headers: dict, body: bytes) -> tuple[int, dict, bytes]:
        """HTTP/2 だけで送る（APNs は HTTP/2 しか受けない）。暗号の設定は Windows の証明書を使う（httpx2 の決まり）。"""
        import httpx2

        with httpx2.Client(http1=False, http2=True, trust_env=False, timeout=TIMEOUT) as client:
            response = client.post(url, headers=headers, content=body)
            return response.status_code, {k.lower(): v for k, v in response.headers.items()}, response.content

    # MARK: 見守りの画面

    def status(self) -> dict:
        found = self.key()
        with self.lock:
            devices = []
            for device, info in self.devices.items():
                token = str(info.get("token") or "")
                last = next((h for h in reversed(self.history) if h.get("device") == device), None)
                devices.append({"id": device, "device": info.get("device"), "model": info.get("model"),
                                "environment": info.get("environment"), "token_tail": token[-8:],
                                "dead": self.dead.get(token), "last": last,
                                "today": {k: self.sent_count(device, k, 86400) for k in KINDS}})
            history = list(self.history[-10:])
        return {"key_id": found[0] if found else None, "key_file": bool(find_key(self.folder)),
                "team": self.team_for(), "team_config": self.config_team(), "http2": http2_available(),
                "ready": found is not None and self.team_for() is not None and http2_available(),
                "blocked": bool(self.blocked), "last_error": self.last_error, "devices": devices,
                "history": history, "folder": str(self.folder)}
