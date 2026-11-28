"""LifeLog PC: トータルコーデのアプリとの窓口 K-TC3（2026-11-28）。服のおすすめ（かっこいい系 cool・かわいい系 cute）と自分の写真。

作るのは母艦（D:\\Lifelog）の scripts/Build-StyleRecs.py（案は定額の枠の Claude・商品は Chrome で ZOZOTOWN を見る・数十分）。
出力は private/style/recs.json（{"generated_at","state":"ready|running|failed","say","running_since","ideas":[…]}）と
private/style/recs/img/<product_id>.jpg。この口は読む・頼みを置いて起こす・本人の答えを 1 行足すだけ。

どれもオーナーの Bearer（lifelog_pc.py が確かめてから）。
- GET /style/recs → recs.json（無ければ {"state":"none"}）。running のまま 2 時間より古ければ（止まった）state を failed にして返す。
  頼みが待っているのに動いていなければ、ここで起こし直す（間を置いて）。
- GET /style/recs/image/<file> → JPEG（<file> は recs.json の products[].image。無ければ 404）
- POST /style/recs/refresh（JSON {"taste":"cool|cute|both"}）→ 母艦の inbox/style_recs/<時刻>.json に {"taste","at"} を置き、
  Build-StyleRecs.py --queue を後ろで起こす（もう動いていれば起こさない＝動いている回が拾う）→ {"status":"queued"}
- POST /style/recs/judge（JSON {"idea_id","product_id"(任意),"ok":true|false}）→ 母艦の private/style/recs_feedback.jsonl に
  {"at","idea_id","product_id","ok","taste","title","product_name"} を 1 行（案・商品は recs.json にある物だけ。無ければ 404）→ {"ok":true}
- POST /style/me（multipart・欄 photo を 1 枚・JPEG・15MB まで）→ 母艦の private/style/me.jpg（一時ファイルから入れ替え）→ {"ok":true}
- GET /style/me → {"exists": true|false}（写真そのものは返さない）
- features "style-recs"（母艦に Build-StyleRecs.py があるとき）
- 記録（log）に写真・案の中身は書かない。
"""

from __future__ import annotations

import datetime
import json
import os
import re
import secrets
import subprocess
import sys
import threading
import time
from pathlib import Path

import s30pwork
import tcstyle

FEATURE = "style-recs"
GETS = ("/style/recs", "/style/me")
POSTS = ("/style/recs/refresh", "/style/recs/judge", "/style/me")
IMAGE_PREFIX = "/style/recs/image/"

RECS = Path("private") / "style" / "recs.json"
REC_IMG = tcstyle.REC_IMG
ME = tcstyle.ME
FEEDBACK = Path("private") / "style" / "recs_feedback.jsonl"
REQUESTS = Path("inbox") / "style_recs"
SCRIPT = Path("scripts") / "Build-StyleRecs.py"

TASTES = ("cool", "cute", "both")
JSON_MAX = 4 * 1024
RECS_MAX = 8 * 1024 * 1024
PHOTO_MAX_BYTES = tcstyle.PHOTO_MAX_BYTES
BODY_MAX = PHOTO_MAX_BYTES + 256 * 1024
STALE_SECONDS = 2 * 3600
KICK_GUARD = 60
ID = re.compile(r"[0-9A-Za-z][0-9A-Za-z_-]{0,63}")

_lock = threading.Lock()
_last_kick = [float("-inf")]
# 試しで差し替える（実際には起こさない）。(スクリプト, Python, 母艦) → None。失敗は OSError
SPAWN = None


def _home(base: Path | None) -> Path | None:
    return Path(base) if base is not None and Path(base).is_dir() else None


def features(base: Path | None) -> list[str]:
    base = _home(base)
    return [FEATURE] if base is not None and (base / SCRIPT).is_file() else []


def handles_get(path: str) -> bool:
    return path in GETS or path.startswith(IMAGE_PREFIX)


def handles_post(path: str) -> bool:
    return path in POSTS


# MARK: - 読む・起こす


def read_recs(base: Path) -> dict | None:
    try:
        raw = (Path(base) / RECS).read_bytes()
        data = json.loads(raw.decode("utf-8")) if len(raw) <= RECS_MAX else None
    except (OSError, ValueError, UnicodeDecodeError):
        return None
    return data if isinstance(data, dict) else None


def _age(value) -> float | None:
    try:
        then = datetime.datetime.fromisoformat(str(value))
    except (TypeError, ValueError):
        return None
    if then.tzinfo is None:
        then = then.astimezone()
    return (datetime.datetime.now(datetime.timezone.utc) - then).total_seconds()


def running(data: dict | None) -> bool:
    if not isinstance(data, dict) or data.get("state") != "running":
        return False
    age = _age(data.get("running_since"))
    return age is not None and age <= STALE_SECONDS


def pending(base: Path) -> bool:
    try:
        return any(p.suffix == ".json" and not p.name.startswith(".") for p in (Path(base) / REQUESTS).iterdir())
    except OSError:
        return False


def _spawn(script: Path, python: Path, base: Path) -> None:
    flags = 0
    if sys.platform == "win32":
        flags = (getattr(subprocess, "CREATE_NO_WINDOW", 0) | getattr(subprocess, "BELOW_NORMAL_PRIORITY_CLASS", 0)
                 | getattr(subprocess, "DETACHED_PROCESS", 0))
    subprocess.Popen([str(python), str(script), "--queue"], cwd=str(base), creationflags=flags, close_fds=True,
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def kick(base: Path, config: dict, guard: float = 0.0) -> str:
    """"started"・"already"（動いている・起こした直後）・"off"。頼みを置いたあとに呼ぶ"""
    base = Path(base)
    script = base / SCRIPT
    python = s30pwork.python_path(config)
    if not script.is_file() or (SPAWN is None and not python.is_file()):
        return "off"
    with _lock:
        if running(read_recs(base)) or 0 <= time.monotonic() - _last_kick[0] < max(guard, 20.0):
            return "already"
        try:
            (SPAWN or _spawn)(script, python, base)
        except OSError:
            return "off"
        _last_kick[0] = time.monotonic()
    return "started"


# MARK: - 受け口


def _read_json(handler) -> tuple[dict | None, int, str]:
    try:
        length = int(handler.headers.get("Content-Length") or 0)
    except ValueError:
        length = 0
    if length <= 0:
        return None, 400, "中身がありません"
    if length > JSON_MAX:
        return None, 413, "大きすぎます"
    try:
        body = json.loads(handler.rfile.read(length).decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None, 400, "JSON ではありません"
    if not isinstance(body, dict):
        return None, 400, "形が違います"
    return body, 200, ""


def http_get(handler, path: str, config: dict, base: Path | None, log=None) -> None:
    say = log or (lambda message: None)
    base = _home(base)
    if path == "/style/me":
        handler.send_json(200, {"exists": base is not None and (base / ME).is_file()})
        return
    if path == "/style/recs":
        data = read_recs(base) if base is not None else None
        if data is None:
            data = {"state": "none"}
        elif data.get("state") == "running" and not running(data):
            data = dict(data, state="failed", say="おすすめ作りが途中で止まりました（もう一度頼めます）")
        if base is not None and pending(base) and not running(data):
            if kick(base, config, guard=KICK_GUARD) == "started":
                say("GET /style/recs: 待ちの頼みがあるので起こし直しました")
        handler.send_json(200, data)
        return
    file = path[len(IMAGE_PREFIX):]
    if base is None or not tcstyle.REC_FILE.fullmatch(file):
        handler.send_json(404, {"error": "その画像はありません"})
        return
    data = tcstyle._read_jpeg(base / REC_IMG / file)
    if data is None:
        handler.send_json(404, {"error": "その画像はありません"})
        return
    tcstyle._send_bytes(handler, data, "image/jpeg")


def http_post(handler, path: str, config: dict, base: Path | None, log=None) -> None:
    say = log or (lambda message: None)

    def refuse(status: int, message: str) -> None:
        discard = getattr(handler, "discard_body", None)
        if discard:
            discard()
        handler.send_json(status, {"error": message})

    base = _home(base)
    if base is None:
        refuse(503, "母艦が見つかりません")
        return
    if path == "/style/me":
        _post_me(handler, base, say, refuse)
        return
    if path == "/style/recs/refresh" and not (base / SCRIPT).is_file():
        refuse(503, "おすすめを作る仕組み（Build-StyleRecs.py）がありません")
        return
    body, status, problem = _read_json(handler)
    if body is None:
        if status == 413:
            refuse(413, problem)
        else:
            handler.send_json(status, {"error": problem})
        return
    if path == "/style/recs/refresh":
        taste = body.get("taste", "both")
        if taste not in TASTES:
            handler.send_json(400, {"error": "taste は cool・cute・both のどれかです"})
            return
        stamp = datetime.datetime.now().astimezone()
        folder = base / REQUESTS
        try:
            folder.mkdir(parents=True, exist_ok=True)
            row = {"taste": taste, "at": stamp.isoformat(timespec="seconds")}
            tcstyle._replace(folder / f"{stamp:%Y%m%d-%H%M%S}-{secrets.token_hex(3)}.json",
                             json.dumps(row, ensure_ascii=False).encode("utf-8"))
        except OSError as error:
            say(f"POST /style/recs/refresh: 母艦に書けませんでした: {type(error).__name__}")
            handler.send_json(500, {"error": "母艦に書けませんでした"})
            return
        run = kick(base, config)
        say(f"POST /style/recs/refresh: {taste}・起こし {run}")
        handler.send_json(200, {"status": "queued"})
        return
    # judge
    idea_id, product_id, ok = body.get("idea_id"), body.get("product_id"), body.get("ok")
    if not isinstance(ok, bool) or not isinstance(idea_id, str) or not ID.fullmatch(idea_id) \
            or (product_id is not None and (not isinstance(product_id, str) or not ID.fullmatch(product_id))):
        handler.send_json(400, {"error": "idea_id（文字）・product_id（任意の文字）・ok（true か false）です"})
        return
    data = read_recs(base) or {}
    idea = next((i for i in data.get("ideas") or [] if isinstance(i, dict) and i.get("id") == idea_id), None)
    product = None
    if idea is not None and product_id is not None:
        product = next((p for p in idea.get("products") or [] if isinstance(p, dict) and p.get("id") == product_id), None)
    if idea is None or (product_id is not None and product is None):
        handler.send_json(404, {"error": "そのおすすめはありません"})
        return
    row = {"at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"), "idea_id": idea_id,
           "product_id": product_id, "ok": ok, "taste": idea.get("taste"), "title": str(idea.get("title") or "")[:80],
           "product_name": str((product or {}).get("name") or "")[:80] or None}
    try:
        with _lock:
            path_ = base / FEEDBACK
            path_.parent.mkdir(parents=True, exist_ok=True)
            with open(path_, "a", encoding="utf-8") as handle:
                handle.write(json.dumps(row, ensure_ascii=False) + "\n")
    except OSError as error:
        say(f"POST /style/recs/judge: 母艦に書けませんでした: {type(error).__name__}")
        handler.send_json(500, {"error": "母艦に書けませんでした"})
        return
    say(f"POST /style/recs/judge: {'いい' if ok else 'いらない'}（{'商品' if product_id else '案'}）")
    handler.send_json(200, {"ok": True})


def _post_me(handler, base: Path, say, refuse) -> None:
    try:
        length = int(handler.headers.get("Content-Length") or 0)
    except ValueError:
        length = 0
    if length <= 0:
        refuse(400, "中身がありません")
        return
    if length > BODY_MAX:
        refuse(413, "大きすぎます")
        return
    boundary = tcstyle.boundary_of(handler.headers.get("Content-Type") or "")
    if boundary is None:
        refuse(400, "multipart/form-data で送ってください")
        return
    parts, problem = tcstyle.parse_multipart(handler.rfile.read(length), boundary)
    photos = [content for name, _f, content in parts or [] if name == "photo"]
    if parts is not None:
        if len(photos) != 1:
            problem = "photo は 1 枚です"
        elif len(photos[0]) > PHOTO_MAX_BYTES:
            problem = f"写真は {PHOTO_MAX_BYTES // (1024 * 1024)}MB までです"
        elif not photos[0].startswith(tcstyle.JPEG_HEAD):
            problem = "写真は JPEG です"
        else:
            problem = None
    if problem is not None:
        say("POST /style/me: 形が違うので断りました")
        handler.send_json(400, {"error": problem})
        return
    try:
        (base / ME).parent.mkdir(parents=True, exist_ok=True)
        tcstyle._replace(base / ME, photos[0])
    except OSError as error:
        say(f"POST /style/me: 母艦に書けませんでした: {type(error).__name__}")
        handler.send_json(500, {"error": "母艦に書けませんでした"})
        return
    say("POST /style/me: 自分の写真を置き換えました")
    handler.send_json(200, {"ok": True})
