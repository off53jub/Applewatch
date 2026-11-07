"""LifeLog PC 版 7: TestFlight の報告（スクショつきの報告・落ちた報告）を、App Store Connect API で読んで PC に置く。

<home>/asc/ に API キー（AuthKey_<KEYID>.p8 と config.json の {"key_id", "issuer_id"}）があるときだけ動く
（issuer_id が空なら、個人のキーとして sub: "user" で JWT を作る）。キーは見守りの画面からも入れられる。
1日に4回（起動して5分後と、そのあと6時間ごと）と、見守りの画面のボタンで読む。
置き場所は <home>/feedback/<報告の ID>/（info.json・screenshot-1.jpg …・crash.txt）と <home>/feedback/index.json。
読んだものは PC の外に出さない（リポジトリは公開なので、GitHub などにも置かない）。記録（log.txt）には数だけを書く。
テスターのメールアドレスは置かない。

使う API（Apple の文書 developer.apple.com/documentation/appstoreconnectapi で確かめた名前・2026-11-07）:
- GET /v1/apps?filter[bundleId]=com.off53jub.lifelog                     アプリの ID
- GET /v1/apps/{id}/betaFeedbackScreenshotSubmissions?include=build      スクショつきの報告（attributes.screenshots の url）
- GET /v1/apps/{id}/betaFeedbackCrashSubmissions?include=build           落ちた報告
- GET /v1/betaFeedbackCrashSubmissions/{id}/crashLog                     落ちた記録（attributes.logText）
JWT は ES256（kid = キーの ID、iss = issuer ID、aud = appstoreconnect-v1、20 分より短い exp）。
"""

from __future__ import annotations

import json
import os
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Callable

import apns

BASE = "https://api.appstoreconnect.apple.com"
BUNDLE_ID = "com.off53jub.lifelog"
FIRST = 300.0                # 起動してから最初に読むまで
EVERY = 6 * 3600.0           # そのあと読む間（1日に4回）
PAGE = 100
ITEM_ID = re.compile(r"[A-Za-z0-9-]{1,100}")
ISSUER = re.compile(r"[0-9a-fA-F-]{36}")
IMAGE_MAX = 25_000_000
LOG_MAX = 8_000_000
KEEP_FIELDS = ("createdDate", "comment", "deviceModel", "osVersion", "locale", "timeZone", "architecture",
               "connectionType", "pairedAppleWatch", "appUptimeInMilliseconds", "diskBytesAvailable", "diskBytesTotal",
               "batteryPercentage", "screenWidthInPoints", "screenHeightInPoints", "appPlatform", "devicePlatform",
               "deviceFamily", "buildBundleId")
IMAGE_TYPES = {"image/jpeg": "jpg", "image/jpg": "jpg", "image/png": "png", "image/heic": "heic", "image/webp": "webp"}
KIND_LABEL = {"screenshot": "スクショつきの報告", "crash": "落ちた報告"}


def _read_json(path: Path) -> dict:
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def _write_json(path: Path, body) -> None:
    part = path.with_name(path.name + ".part")
    part.write_text(json.dumps(body, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(part, path)


def save_key(folder: Path, key_id: str, issuer_id: str, pem: str) -> Path:
    """見守りの画面から入れたキーを folder（<home>/asc）に置く。おかしければ ValueError。"""
    issuer_id = (issuer_id or "").strip().lower()
    if issuer_id and not ISSUER.fullmatch(issuer_id):
        raise ValueError("issuer ID は 36 文字（英数字と -）です（個人のキーなら空にします）")
    path = apns.save_key(folder, key_id, pem)
    _write_json(Path(folder) / "config.json", {"key_id": (key_id or "").strip().upper(), "issuer_id": issuer_id})
    return path


class Feedback:
    """TestFlight の報告を読んで置く。キーが無ければ何もしない。"""

    def __init__(self, home: Path, log: Callable[[str], None], clock: Callable[[], float] = time.time,
                 base: str = BASE, opener: Callable | None = None) -> None:
        self.keys = Path(home) / "asc"
        self.folder = Path(home) / "feedback"
        self.log = log
        self.clock = clock
        self.base = base.rstrip("/")
        self.opener = opener or self._open
        self.running = threading.Lock()
        self.state = "まだ読んでいません"
        self.error: str | None = None
        index = _read_json(self.folder / "index.json")
        self.items: dict[str, dict] = index.get("items") if isinstance(index.get("items"), dict) else {}
        self.app_id: str | None = index.get("app_id") if isinstance(index.get("app_id"), str) else None
        self.checked: float | None = index.get("checked") if isinstance(index.get("checked"), (int, float)) else None
        self.token_cache: tuple[str, float, tuple] | None = None

    # MARK: キー

    def credentials(self) -> tuple[str, str, object] | None:
        """(キーの ID, issuer ID（個人のキーなら空）, 鍵)。そろっていなければ None。"""
        found = apns.find_key(self.keys)
        if not found:
            return None
        key_id, path = found
        config = _read_json(self.keys / "config.json")
        if str(config.get("key_id") or key_id).strip().upper() != key_id:
            return None
        issuer = str(config.get("issuer_id") or "").strip().lower()
        try:
            return key_id, issuer, apns.load_p8(path.read_bytes())
        except (OSError, ValueError):
            return None

    def configured(self) -> bool:
        return self.credentials() is not None

    def token(self) -> str:
        found = self.credentials()
        if found is None:
            raise RuntimeError("App Store Connect のキーがありません")
        key_id, issuer, key = found
        now = int(self.clock())
        if self.token_cache and self.token_cache[2] == (key_id, issuer) and now - self.token_cache[1] < 600:
            return self.token_cache[0]
        claims = {"iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}
        claims.update({"iss": issuer} if issuer else {"sub": "user"})
        token = apns.es256_jwt(key, {"alg": "ES256", "kid": key_id, "typ": "JWT"}, claims)
        self.token_cache = (token, now, (key_id, issuer))
        return token

    # MARK: 問い合わせ

    @staticmethod
    def _open(request: urllib.request.Request, timeout: float):
        import updater  # 暗号の設定（SSLKEYLOGFILE に左右されない・Windows の証明書を使う）は自分で入れ替えるときと同じ

        context = updater.https_context() if request.full_url.startswith("https:") else None
        return urllib.request.urlopen(request, timeout=timeout, context=context)

    def get(self, path: str, params: dict | None = None, raw: bool = False, limit: int = 20_000_000):
        url = path if path.startswith("http") else self.base + path
        if params:
            url += "?" + urllib.parse.urlencode(params)
        request = urllib.request.Request(url, headers={"Authorization": f"Bearer {self.token()}",
                                                       "User-Agent": "LifeLogPC", "Accept": "application/json"})
        try:
            with self.opener(request, 60.0) as response:
                data = response.read(limit + 1)
        except urllib.error.HTTPError as error:
            raise RuntimeError(self._explain(error)) from error
        if len(data) > limit:
            raise RuntimeError("答えが大きすぎます")
        return data if raw else json.loads(data or b"{}")

    @staticmethod
    def _explain(error: urllib.error.HTTPError) -> str:
        reasons = {401: "キーが合いません（キーの ID・issuer ID・.p8 を確かめてください）",
                   403: "このキーでは読めません（役割が Admin・App Manager・Developer のキーが要ります）",
                   404: "見つかりません", 429: "問い合わせが多すぎます（しばらく待ちます）"}
        return f"App Store Connect が {error.code} を返しました: {reasons.get(error.code, error.reason)}"

    def find_app(self) -> str:
        if self.app_id:
            return self.app_id
        data = self.get("/v1/apps", {"filter[bundleId]": BUNDLE_ID, "limit": 1, "fields[apps]": "bundleId"})
        rows = data.get("data") or []
        if not rows or not isinstance(rows[0], dict) or not ITEM_ID.fullmatch(str(rows[0].get("id") or "")):
            raise RuntimeError(f"App Store Connect に {BUNDLE_ID} のアプリが見つかりません")
        self.app_id = str(rows[0]["id"])
        return self.app_id

    # MARK: 読む

    def fetch(self) -> dict:
        """新しい報告を読んで置く。{"new", "screenshots", "crashes"} を返す。キーが無ければ RuntimeError。"""
        if not self.running.acquire(blocking=False):
            return {"new": 0, "busy": True}
        try:
            self.state = "読んでいます"
            got = self._fetch()
            self.checked = self.clock()
            self.error = None
            self.state = "読みました"
            self.save_index()
            if got["new"]:
                self.log(f"TestFlight の報告: 新しいものが {got['new']} 件ありました"
                         f"（スクショつき {got['screenshots']}・落ちた {got['crashes']}）")
            return got
        except Exception as error:  # noqa: BLE001 — 読めなくても、ほかはいつもどおり動く
            self.error = str(error) or repr(error)
            self.state = "読めませんでした"
            self.save_index()
            self.log(f"TestFlight の報告を読めませんでした: {self.error}")
            raise
        finally:
            self.running.release()

    def _fetch(self) -> dict:
        app = self.find_app()
        counts = {"new": 0, "screenshots": 0, "crashes": 0}
        for kind, kind_path in (("screenshot", "betaFeedbackScreenshotSubmissions"),
                                ("crash", "betaFeedbackCrashSubmissions")):
            page = self.get(f"/v1/apps/{app}/{kind_path}", {"sort": "-createdDate", "limit": PAGE,
                                                             "include": "build", "fields[builds]": "version"})
            builds = {str(i.get("id")): str((i.get("attributes") or {}).get("version") or "")
                      for i in page.get("included") or [] if isinstance(i, dict) and i.get("type") == "builds"}
            for item in page.get("data") or []:
                if not isinstance(item, dict) or not ITEM_ID.fullmatch(str(item.get("id") or "")):
                    continue
                known = self.items.get(item["id"])
                if known and (kind != "crash" or known.get("crash") or not self._retry_log(known)):
                    continue
                if self._store(kind, item, builds):
                    counts["new"] += 0 if known else 1
                    counts["screenshots" if kind == "screenshot" else "crashes"] += 0 if known else 1
        return counts

    def _retry_log(self, known: dict) -> bool:
        """落ちた記録がまだ取れていない報告は、3 日のあいだ取り直す"""
        return self.clock() - float(known.get("fetched") or 0) < 3 * 86400

    def _store(self, kind: str, item: dict, builds: dict) -> bool:
        sid = item["id"]
        attrs = item.get("attributes") if isinstance(item.get("attributes"), dict) else {}
        relation = ((item.get("relationships") or {}).get("build") or {}).get("data") or {}
        build = builds.get(str(relation.get("id"))) if isinstance(relation, dict) else None
        folder = self.folder / sid
        folder.mkdir(parents=True, exist_ok=True)
        info = {k: attrs.get(k) for k in KEEP_FIELDS if k in attrs}
        info.update(id=sid, kind=kind, build=build)
        _write_json(folder / "info.json", info)
        files: list[str] = []
        if kind == "screenshot":
            for n, shot in enumerate(attrs.get("screenshots") or [], 1):
                if isinstance(shot, dict) and isinstance(shot.get("url"), str):
                    name = self._image(folder, n, shot)
                    if name:
                        files.append(name)
        crash = None
        if kind == "crash":
            try:
                log = self.get(f"/v1/betaFeedbackCrashSubmissions/{sid}/crashLog", {"fields[betaCrashLogs]": "logText"},
                               limit=LOG_MAX)
                text = str(((log.get("data") or {}).get("attributes") or {}).get("logText") or "")
                if text:
                    (folder / "crash.txt").write_text(text, encoding="utf-8")
                    crash = "crash.txt"
            except RuntimeError as error:
                if "404" not in str(error):
                    raise
        known = self.items.get(sid) or {}
        comment = str(attrs.get("comment") or "")
        self.items[sid] = {"kind": kind, "created": attrs.get("createdDate"), "build": build,
                           "device": attrs.get("deviceModel"), "os": attrs.get("osVersion"),
                           "comment": comment[:300] + ("…" if len(comment) > 300 else ""),
                           "files": files or known.get("files") or [], "crash": crash or known.get("crash"),
                           "fetched": known.get("fetched") or self.clock()}
        return True

    def _image(self, folder: Path, n: int, shot: dict) -> str | None:
        """スクショを取ってくる。url は期限つきの宛先なので、合言葉（JWT）は付けない（Apple の中の宛先で断られたときだけ付ける）。"""
        url = shot["url"]
        if "{w}" in url or "{h}" in url:
            url = url.replace("{w}", str(shot.get("width") or 1000)).replace("{h}", str(shot.get("height") or 2000)) \
                .replace("{f}", "png")
        if not url.startswith(("https://", "http://127.0.0.1")):
            return None
        for with_key in (False, True):
            headers = {"User-Agent": "LifeLogPC"}
            if with_key:
                host = urllib.parse.urlparse(url).hostname or ""
                if not host.endswith(".apple.com"):
                    break
                headers["Authorization"] = f"Bearer {self.token()}"
            try:
                with self.opener(urllib.request.Request(url, headers=headers), 60.0) as response:
                    data = response.read(IMAGE_MAX + 1)
                    kind = (response.headers.get("Content-Type") or "").split(";")[0].strip().lower()
            except urllib.error.HTTPError as error:
                if error.code in (401, 403) and not with_key:
                    continue
                self.log(f"TestFlight の報告: スクショを取ってこられませんでした（{error.code}）")
                return None
            except OSError as error:
                self.log(f"TestFlight の報告: スクショを取ってこられませんでした: {error!r}")
                return None
            if len(data) > IMAGE_MAX:
                return None
            ext = IMAGE_TYPES.get(kind) or ("png" if data[:8] == b"\x89PNG\r\n\x1a\n" else "jpg")
            name = f"screenshot-{n}.{ext}"
            (folder / name).write_bytes(data)
            return name
        return None

    def save_index(self) -> None:
        try:
            self.folder.mkdir(parents=True, exist_ok=True)
            _write_json(self.folder / "index.json", {"app_id": self.app_id, "checked": self.checked, "items": self.items})
        except OSError:
            pass

    # MARK: 見守りの画面

    def recent(self, count: int = 10) -> list[dict]:
        rows = [dict(v, id=k) for k, v in list(self.items.items())]
        rows.sort(key=lambda r: str(r.get("created") or ""), reverse=True)
        return rows[:count]

    def item(self, sid: str) -> tuple[dict, Path] | None:
        """見守りの画面の「詳しく」に出す1件（info.json の中身とフォルダ）"""
        if not ITEM_ID.fullmatch(sid or "") or sid not in self.items:
            return None
        folder = self.folder / sid
        info = _read_json(folder / "info.json")
        info.update({k: v for k, v in self.items[sid].items() if k in ("files", "crash", "kind", "build")})
        return info, folder

    def status(self) -> dict:
        found = apns.find_key(self.keys)
        return {"configured": self.configured(), "key_id": found[0] if found else None,
                "state": self.state, "error": self.error, "checked": self.checked, "count": len(self.items),
                "recent": self.recent(10), "folder": str(self.folder)}
