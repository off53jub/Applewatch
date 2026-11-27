"""LifeLog PC: s36（2026-11-28。担当 p）の口。取り決め K36-1・K36-3（名前と形を変えない）。

lifelog_pc.py から呼ぶのは features(base)・GETS・http_get・POSTS・http_post。
K36-2（POST /work/photo の kind と 30 枚）は s35pwork.py、K36-4（/ask-mothership の scope）は askmother.py に足した。

- K36-1 GET /s36（オーナーの Bearer）: 母艦の state/s36_for_app.json をそのまま返す（作るのは母艦の担当）。
  大きすぎ・壊れ・無い・止めてある・母艦が無い → {"available": false, "reason": …}（s34 の GET /s34 と同じ「まだ」の返事）。
  features "s36"（ファイルがあって止めていないとき）。
- K36-3 POST /s36/stop（オーナーの Bearer）: 体 {"id": str（1〜80 字）, "choice": "stop"|"keep"} を検めて、
  母艦の inbox/s36_stop/<時刻>-<id の安全な形>.json に {"id","choice","at"} を書くだけ（止めるのは母艦の担当が、
  選ばれた stop だけ。ここでは何も止めない）。返事 {"ok": true}。形が違えば 400。
  止めてある・母艦が無いときは書かずに {"ok": false, "reason": …}。features "s36stop"（母艦があって止めていないとき）。
  一時ファイル（頭が "."・終わりが .tmp）に書いてから入れ替える（母艦が読みかけを拾わないように）。
- 止める切り替え: 母艦の state/s27_work_config.json の "s36p": {"s36": false} / {"stop": false}（書かなければオン）。
- 記録（log）には中身を書かない（id は書かない。choice と数だけ）。
"""

from __future__ import annotations

import datetime
import json
import os
import re
import threading
from pathlib import Path

import s27pwork

S36 = Path("state") / "s36_for_app.json"
STOP_INBOX = Path("inbox") / "s36_stop"
GETS = ("/s36",)
POSTS = ("/s36/stop",)
FEATURE = "s36"
FEATURE_STOP = "s36stop"
S36_READ_MAX = 12 * 1024 * 1024
STOP_BODY_MAX = 4 * 1024
ID_MAX = 80
CHOICES = ("stop", "keep")
CONTROL = re.compile(r"[\x00-\x1f\x7f]")
UNSAFE = re.compile(r"[^0-9A-Za-z_-]+")

_lock = threading.Lock()


# MARK: - 切り替え・features


def _switch(base: Path | None, name: str) -> bool:
    if base is None:
        return True
    data, _ = s27pwork._load(base, s27pwork.CONFIG, 64 * 1024)
    mine = data.get("s36p") if isinstance(data, dict) else None
    value = mine.get(name) if isinstance(mine, dict) else None
    return value if isinstance(value, bool) else True


def _home(base: Path | None) -> Path | None:
    return Path(base) if base is not None and Path(base).is_dir() else None


def features(base: Path | None) -> list[str]:
    base = _home(base)
    if base is None:
        return []
    found = []
    if _switch(base, "s36") and (base / S36).is_file():
        found.append(FEATURE)
    if _switch(base, "stop"):
        found.append(FEATURE_STOP)
    return found


# MARK: - K36-1 GET /s36


def _off(reason: str) -> dict:
    return {"available": False, "reason": reason}


def read_s36(base: Path) -> dict:
    data, failure = s27pwork._load(base, S36, S36_READ_MAX)
    if data is None:
        return _off(s27pwork._reason("s36 のまとめ", failure))
    return data


def http_get(handler, path: str, query: str, base: Path | None) -> None:
    """GET /s36（合言葉は lifelog_pc.py が確かめてから）"""
    base = _home(base)
    try:
        if base is None:
            handler.send_json(200, _off("母艦が見つかりません"))
        elif not _switch(base, "s36"):
            handler.send_json(200, _off("止めてあります"))
        else:
            handler.send_json(200, read_s36(base))
    except Exception as error:  # noqa: BLE001
        handler.send_json(200, _off(f"読めませんでした: {type(error).__name__}"))


# MARK: - K36-3 POST /s36/stop


def check_stop(body) -> tuple[dict | None, str | None]:
    """(残す形, 断る理由)。残す形は {"id", "choice"}"""
    if not isinstance(body, dict):
        return None, "形が違います"
    ident = body.get("id")
    if not isinstance(ident, str) or not ident.strip():
        return None, "id は文字です"
    if len(ident) > ID_MAX:
        return None, f"id は {ID_MAX} 字までです"
    if CONTROL.search(ident):
        return None, "id に使えない文字があります"
    choice = body.get("choice")
    if choice not in CHOICES:
        return None, "choice は stop か keep です"
    return {"id": ident, "choice": choice}, None


def safe_id(ident: str) -> str:
    """ファイルの名前に使える形（英数字・_・- だけ。ほかは _ にまとめる。80 字まで）"""
    text = UNSAFE.sub("_", ident).strip("_")[:ID_MAX]
    return text or "x"


def write_stop(base: Path, answer: dict, now: datetime.datetime | None = None) -> Path:
    """inbox/s36_stop/<時刻>-<id の安全な形>.json に置く。返すのは置いた所"""
    moment = now or datetime.datetime.now().astimezone()
    folder = Path(base) / STOP_INBOX
    stem = f"{moment.strftime('%Y%m%dT%H%M%S%f')}-{safe_id(answer['id'])}"
    data = json.dumps({"id": answer["id"], "choice": answer["choice"],
                       "at": moment.isoformat(timespec="seconds")}, ensure_ascii=False).encode("utf-8")
    with _lock:
        folder.mkdir(parents=True, exist_ok=True)
        final = folder / f"{stem}.json"
        n = 1
        while final.exists():
            n += 1
            final = folder / f"{stem}-{n}.json"
        tmp = folder / f".{final.name}.{os.getpid()}.{threading.get_ident()}.tmp"
        try:
            with open(tmp, "wb") as handle:
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(tmp, final)
        finally:
            try:
                tmp.unlink()
            except OSError:
                pass
    return final


def http_post(handler, path: str, base: Path | None, log=None) -> None:
    """POST /s36/stop（合言葉は lifelog_pc.py が確かめてから）。log には中身を渡さない"""
    say = log or (lambda message: None)
    base = _home(base)
    if base is None or not _switch(base, "stop"):
        discard = getattr(handler, "discard_body", None)
        if discard:
            discard()
        handler.send_json(200, {"ok": False, "reason": "母艦が見つかりません" if base is None else "止めてあります"})
        return
    try:
        length = int(handler.headers.get("Content-Length") or 0)
    except ValueError:
        length = 0
    if length <= 0 or length > STOP_BODY_MAX:
        discard = getattr(handler, "discard_body", None)
        if discard:
            discard()
        handler.send_json(400 if length <= 0 else 413, {"error": "中身がありません" if length <= 0 else "長すぎます"})
        return
    raw = handler.rfile.read(length)
    try:
        body = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        handler.send_json(400, {"error": "JSON ではありません"})
        return
    answer, problem = check_stop(body)
    if answer is None:
        say("POST /s36/stop: 形が違うので断りました")
        handler.send_json(400, {"error": problem})
        return
    try:
        write_stop(base, answer)
    except OSError as error:
        say(f"POST /s36/stop: 母艦に書けませんでした: {type(error).__name__}")
        handler.send_json(500, {"error": "母艦に書けませんでした"})
        return
    say(f"POST /s36/stop: {answer['choice']} を 1 件置きました")
    handler.send_json(200, {"ok": True})
