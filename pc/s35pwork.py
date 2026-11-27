"""LifeLog PC: s35（2026-11-28。担当 p）の「仕事のまとめの写真そのものも母艦へ」の口。取り決め K35（名前と形を変えない）。

iPhone の中の文字の読み取り（Vision）は、画面の折り返しで項目がちぎれる。そこで写真そのものも母艦に置き、
母艦の側で Claude に書き起こさせる（母艦の読む段は別の担当）。この口は受けて置いて起こすだけ。

- POST /work/photo（オーナーの Bearer）。1 枚ずつ。
  体: {"id": まとめの id（POST /work/digest と同じ）, "day": "YYYY-MM-DD", "index": 0 から, "count": 枚数, "jpeg_b64": "..."}
  返事: {"ok": true, "have": そろった枚数, "count": n, "run": "started"|"already"|"off"|"waiting"}
  検め: id は UUID・day は本当にある日・count は 1〜12・index は 0 以上 count 未満・jpeg_b64 は base64 で、
  デコードしたあと 3MB まで・中身は JPEG の頭（FF D8）で始まる。どれかに外れたら 400。
  置き場: 母艦の inbox/work_photo/<id>/<index>.jpg と inbox/work_photo/<id>/meta.json
  （{"id","day","count","received":[index…],"at"}）。どちらも一時ファイルに書いてから入れ替える（s30pwork と同じ）。
  count 枚がそろったら、POST /work/digest と同じ起こし方（s30pwork.kick → Run-WorkNow.py --kick。二重起こしの抑えも同じ）。
  そろっていなければ run は "waiting"。
  同じ id で count か day が前と違えば、新しい組として受け直す（前の received を捨て、count 以上の番号の写真は消す）。
  同じ番号を送り直したら置き換え（二重に数えない）。
- 止める切り替え・母艦が無いとき: s30pwork と同じ（state/s27_work_config.json の "s30p": {"push": false}）。
  そのときは書かず {"ok": false, "have": 0, "count": 0, "run": "off"}。
- features "workphoto"（母艦の置き場があって止めていないとき。s30pwork.features と同じ決まり）
- 記録（log）に中身（写真・文字）は書かない。書くのは id の頭 8 字と枚数だけ。
"""

from __future__ import annotations

import base64
import binascii
import datetime
import json
import os
import threading
from pathlib import Path

import s30pwork

INBOX = Path("inbox") / "work_photo"
META = "meta.json"

POSTS = ("/work/photo",)
FEATURE = "workphoto"

COUNT_MAX = 12                         # 1 回のまとめの写真の枚数
PHOTO_MAX_BYTES = 3 * 1024 * 1024      # 1 枚（デコードしたあと）
# 体の全部（3MB を base64 にした 4MB と、まわりの JSON の余裕）
BODY_MAX = PHOTO_MAX_BYTES * 4 // 3 + 64 * 1024
JPEG_HEAD = b"\xff\xd8"

_lock = threading.Lock()


def features(base: Path | None) -> list[str]:
    """母艦の置き場があって止めていないときだけ workphoto（s30pwork の workpush と同じ決まり）"""
    return [FEATURE] if s30pwork._open(base) else []


# MARK: - 体を検める


def _int(value) -> int | None:
    """True/False は数にしない"""
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def check_photo(body) -> tuple[dict | None, str | None]:
    """(残す形, 断る理由)。残す形は {"id", "day", "index", "count", "jpeg": bytes}"""
    if not isinstance(body, dict):
        return None, "形が違います"
    ident = body.get("id")
    if not isinstance(ident, str) or not s30pwork.UUID.fullmatch(ident):
        return None, "id は UUID です"
    day = body.get("day")
    if not s30pwork._valid_day(day):
        return None, "day は YYYY-MM-DD です"
    count, index = _int(body.get("count")), _int(body.get("index"))
    if count is None or not 1 <= count <= COUNT_MAX:
        return None, f"count は 1〜{COUNT_MAX} です"
    if index is None or not 0 <= index < count:
        return None, "index は 0 以上 count 未満です"
    raw = body.get("jpeg_b64")
    if not isinstance(raw, str) or not raw:
        return None, "jpeg_b64 は文字です"
    if len(raw) > PHOTO_MAX_BYTES * 4 // 3 + 8:
        return None, f"写真は 1 枚 {PHOTO_MAX_BYTES // (1024 * 1024)}MB までです"
    try:
        jpeg = base64.b64decode(raw, validate=True)
    except (binascii.Error, ValueError):
        return None, "jpeg_b64 が base64 ではありません"
    if len(jpeg) > PHOTO_MAX_BYTES:
        return None, f"写真は 1 枚 {PHOTO_MAX_BYTES // (1024 * 1024)}MB までです"
    if not jpeg.startswith(JPEG_HEAD):
        return None, "JPEG ではありません"
    return {"id": ident.lower(), "day": day, "index": index, "count": count, "jpeg": jpeg}, None


# MARK: - 母艦の inbox に置く


def _replace(final: Path, data: bytes) -> None:
    """一時ファイル（.tmp）に書いてから入れ替える（s30pwork.write_entries と同じ書き方）"""
    tmp = final.parent / f".{final.name}.{os.getpid()}.{threading.get_ident()}.tmp"
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


def _read_meta(folder: Path) -> dict:
    try:
        raw = (folder / META).read_bytes()
        data = json.loads(raw.decode("utf-8")) if len(raw) <= 64 * 1024 else {}
    except (OSError, ValueError, UnicodeDecodeError):
        data = {}
    return data if isinstance(data, dict) else {}


def write_photo(base: Path, photo: dict, now: datetime.datetime | None = None) -> dict:
    """1 枚を置いて meta.json を書き直す。返すのは書いた meta"""
    folder = Path(base) / INBOX / photo["id"]
    with _lock:
        folder.mkdir(parents=True, exist_ok=True)
        old = _read_meta(folder)
        received: list[int] = []
        if old.get("count") == photo["count"] and old.get("day") == photo["day"]:
            received = sorted({n for n in (old.get("received") or []) if _int(n) is not None and 0 <= n < photo["count"]})
        else:
            # 新しい組: count 以上の番号の写真は消す（数え直す）
            for stale in folder.glob("*.jpg"):
                try:
                    if int(stale.stem) >= photo["count"]:
                        stale.unlink()
                except (ValueError, OSError):
                    pass
        _replace(folder / f"{photo['index']}.jpg", photo["jpeg"])
        received = sorted(set(received) | {photo["index"]})
        stamp = (now or datetime.datetime.now().astimezone()).isoformat(timespec="seconds")
        meta = {"id": photo["id"], "day": photo["day"], "count": photo["count"], "received": received, "at": stamp}
        _replace(folder / META, json.dumps(meta, ensure_ascii=False).encode("utf-8"))
    return meta


# MARK: - 受け口


def http_post(handler, path: str, config: dict, base: Path | None, log=None) -> None:
    """POST /work/photo（合言葉は lifelog_pc.py が確かめてから）。log は文字 1 つを受ける（中身は渡さない）"""
    say = log or (lambda message: None)
    if base is not None and not Path(base).is_dir():
        base = None
    if base is None or not s30pwork._switch(base):
        discard = getattr(handler, "discard_body", None)
        if discard:
            discard()
        handler.send_json(200, {"ok": False, "have": 0, "count": 0, "run": "off"})
        return
    try:
        length = int(handler.headers.get("Content-Length") or 0)
    except ValueError:
        length = 0
    if length <= 0 or length > BODY_MAX:
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
    photo, problem = check_photo(body)
    if photo is None:
        say("POST /work/photo: 形が違うので断りました")
        handler.send_json(400, {"error": problem})
        return
    try:
        meta = write_photo(base, photo)
    except OSError as error:
        say(f"POST /work/photo: 母艦に書けませんでした: {type(error).__name__}")
        handler.send_json(500, {"error": "母艦に書けませんでした"})
        return
    have, count = len(meta["received"]), meta["count"]
    run = s30pwork.kick(base, config) if have >= count else "waiting"
    say(f"POST /work/photo: {photo['index'] + 1}/{count} 枚目・そろった {have} 枚・起こし {run}（id {photo['id'][:8]}…）")
    handler.send_json(200, {"ok": True, "have": have, "count": count, "run": run})
