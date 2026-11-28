"""LifeLog PC: トータルコーデのアプリとの窓口 K-TC2（2026-11-28）。クローゼットの服の写真。名前と形を変えない。

母艦（D:\\Lifelog）の形（母艦の担当が決めた）:
- 帳簿 private/style/wardrobe.json の各 item に "photo": null か {"file","src":"shop|own","sure":"maybe|yes","page"}
- 写真 private/style/photos/<id>.jpg
- 写真の台帳 private/style/photo_map.json: {"<id>": {"src","sure","page","url","match","removed","rejected":[url…]}}
- scripts/Build-Wardrobe.py が台帳と写真を見て photo を付け直す（15 分ごと。数秒・0 円）。
  この窓口は台帳か写真を書いたあと、すぐ 1 回起こす（答えを返す前に終わるのを待つ。20 秒で見切る）。

どれもオーナーの Bearer（lifelog_pc.py が確かめてから）。<id> は wardrobe.json の items にある物だけ（無ければ 404）。
- GET /style/photo/<id> → private/style/photos/<id>.jpg（image/jpeg）。無い・台帳で removed なら 404。
- POST /style/photo/<id>（multipart/form-data・欄 photo を 1 枚・JPEG・15MB まで）
  → photos/<id>.jpg に置き（一時ファイルに書いてから入れ替える）、台帳を {"src":"own","sure":"yes"} に
    （removed・page・url・match は外す。rejected は残す）→ Build-Wardrobe.py → {"ok": true}
- POST /style/photo/<id>/judge（JSON {"ok": true|false}）
  true: 台帳の sure を yes（写真が無ければ 404）／false: 写真ファイルを消し、台帳に removed: true と、
  その url を rejected に足す → Build-Wardrobe.py → {"ok": true}
- 形が違えば 400・大きすぎれば 413・母艦が無ければ 503（どれも {"error"}）。
- features "style-photo"（母艦の帳簿があるとき）
- 記録（log）に写真の中身・品名は書かない（id と、した事だけ）。
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import threading
from pathlib import Path

import s30pwork
import tcstyle

FEATURE = "style-photo"
PREFIX = "/style/photo/"
WARDROBE = tcstyle.WARDROBE
PHOTOS = Path("private") / "style" / "photos"
PMAP = Path("private") / "style" / "photo_map.json"
SCRIPT = Path("scripts") / "Build-Wardrobe.py"

PHOTO_MAX_BYTES = 15 * 1024 * 1024
BODY_MAX = PHOTO_MAX_BYTES + 256 * 1024
JUDGE_MAX = 4 * 1024
PMAP_MAX = 8 * 1024 * 1024
BUILD_TIMEOUT = 20
ITEM_ID = re.compile(r"[0-9A-Za-z][0-9A-Za-z_-]{0,63}")
ROUTE = re.compile(r"/style/photo/([^/]+)(/judge)?")

_lock = threading.Lock()
# 試しで差し替える（実際には起こさない）。(スクリプト, Python, 母艦) → bool（作り直せた）
RUN = None


def _home(base: Path | None) -> Path | None:
    return Path(base) if base is not None and Path(base).is_dir() else None


def features(base: Path | None) -> list[str]:
    base = _home(base)
    return [FEATURE] if base is not None and (base / WARDROBE).is_file() else []


def handles_get(path: str) -> bool:
    return path.startswith(PREFIX)


def handles_post(path: str) -> bool:
    return path.startswith(PREFIX)


# MARK: - 母艦を読む・書く


def item_ids(base: Path) -> set[str]:
    try:
        raw = (Path(base) / WARDROBE).read_bytes()
        data = json.loads(raw.decode("utf-8")) if len(raw) <= tcstyle.WARDROBE_MAX else {}
    except (OSError, ValueError, UnicodeDecodeError):
        return set()
    items = data.get("items") if isinstance(data, dict) else None
    return {i["id"] for i in items or [] if isinstance(i, dict) and isinstance(i.get("id"), str)}


def read_map(base: Path) -> dict:
    try:
        raw = (Path(base) / PMAP).read_bytes()
        data = json.loads(raw.decode("utf-8")) if len(raw) <= PMAP_MAX else {}
    except FileNotFoundError:
        return {}
    except (OSError, ValueError, UnicodeDecodeError) as error:
        raise OSError(f"写真の台帳を読めません: {type(error).__name__}") from error
    if not isinstance(data, dict):
        raise OSError("写真の台帳の形が違います")
    return data


def write_map(base: Path, data: dict) -> None:
    path = Path(base) / PMAP
    path.parent.mkdir(parents=True, exist_ok=True)
    tcstyle._replace(path, json.dumps(data, ensure_ascii=False, indent=1).encode("utf-8"))


def photo_path(base: Path, ident: str) -> Path:
    return Path(base) / PHOTOS / f"{ident}.jpg"


def _run(script: Path, python: Path, base: Path) -> bool:
    flags = 0
    if sys.platform == "win32":
        flags = getattr(subprocess, "CREATE_NO_WINDOW", 0) | getattr(subprocess, "BELOW_NORMAL_PRIORITY_CLASS", 0)
    try:
        done = subprocess.run([str(python), str(script)], cwd=str(base), creationflags=flags, timeout=BUILD_TIMEOUT,
                              stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return done.returncode == 0


def rebuild(base: Path, config: dict) -> bool:
    """Build-Wardrobe.py を 1 回（帳簿の photo を付け直す）。できなくても 15 分ごとの回で直る"""
    script = Path(base) / SCRIPT
    python = s30pwork.python_path(config)
    if not script.is_file() or (RUN is None and not python.is_file()):
        return False
    return bool((RUN or _run)(script, python, Path(base)))


def save_own(base: Path, ident: str, jpeg: bytes) -> None:
    with _lock:
        pmap = read_map(base)
        path = photo_path(base, ident)
        path.parent.mkdir(parents=True, exist_ok=True)
        tcstyle._replace(path, jpeg)
        old = pmap.get(ident) if isinstance(pmap.get(ident), dict) else {}
        row = {"src": "own", "sure": "yes"}
        if isinstance(old.get("rejected"), list):
            row["rejected"] = old["rejected"]
        pmap[ident] = row
        write_map(base, pmap)


def judge(base: Path, ident: str, ok: bool) -> bool:
    """False は写真が無い（judge するものが無い）"""
    with _lock:
        pmap = read_map(base)
        row = dict(pmap.get(ident)) if isinstance(pmap.get(ident), dict) else {}
        path = photo_path(base, ident)
        if not path.is_file() or row.get("removed"):
            return False
        if ok:
            row["sure"] = "yes"
        else:
            path.unlink()
            row["removed"] = True
            url = row.get("url")
            rejected = [u for u in row.get("rejected") or [] if isinstance(u, str)]
            if isinstance(url, str) and url and url not in rejected:
                rejected.append(url)
            row["rejected"] = rejected
        pmap[ident] = row
        write_map(base, pmap)
    return True


# MARK: - 受け口


def _route(path: str, base: Path | None) -> tuple[str | None, bool, str | None]:
    """(id, judge か, 断る理由)。母艦が無い・知らない id は理由つき"""
    match = ROUTE.fullmatch(path)
    if not match or not ITEM_ID.fullmatch(match.group(1)):
        return None, False, "その服はありません"
    ident = match.group(1)
    if base is None or ident not in item_ids(base):
        return None, bool(match.group(2)), "その服はありません"
    return ident, bool(match.group(2)), None


def http_get(handler, path: str, base: Path | None) -> None:
    base = _home(base)
    ident, is_judge, problem = _route(path, base)
    if ident is None or is_judge:
        handler.send_json(404, {"error": problem or "その写真はありません"})
        return
    try:
        row = read_map(base).get(ident)
    except OSError:
        row = None
    path_ = photo_path(base, ident)
    data = None
    if not (isinstance(row, dict) and row.get("removed")):
        try:
            data = path_.read_bytes() if path_.stat().st_size <= PHOTO_MAX_BYTES * 2 else None
        except OSError:
            data = None
    if data is None:
        handler.send_json(404, {"error": "その写真はありません"})
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
    ident, is_judge, problem = _route(path, base)
    if ident is None:
        refuse(404, problem)
        return
    try:
        length = int(handler.headers.get("Content-Length") or 0)
    except ValueError:
        length = 0
    if length <= 0:
        refuse(400, "中身がありません")
        return
    if length > (JUDGE_MAX if is_judge else BODY_MAX):
        refuse(413, "大きすぎます")
        return
    if is_judge:
        try:
            body = json.loads(handler.rfile.read(length).decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            handler.send_json(400, {"error": "JSON ではありません"})
            return
        ok = body.get("ok") if isinstance(body, dict) else None
        if not isinstance(ok, bool):
            handler.send_json(400, {"error": "ok は true か false です"})
            return
        try:
            found = judge(base, ident, ok)
        except OSError as error:
            say(f"POST /style/photo/judge: 母艦に書けませんでした: {type(error).__name__}")
            handler.send_json(500, {"error": "母艦に書けませんでした"})
            return
        if not found:
            handler.send_json(404, {"error": "その写真はありません"})
            return
        built = rebuild(base, config)
        say(f"POST /style/photo/judge: {ident} を{'合っている' if ok else '違う（写真を消した）'}・帳簿の作り直し {'済み' if built else 'あとで'}")
        handler.send_json(200, {"ok": True})
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
        say("POST /style/photo: 形が違うので断りました")
        handler.send_json(400, {"error": problem})
        return
    try:
        save_own(base, ident, photos[0])
    except OSError as error:
        say(f"POST /style/photo: 母艦に書けませんでした: {type(error).__name__}")
        handler.send_json(500, {"error": "母艦に書けませんでした"})
        return
    built = rebuild(base, config)
    say(f"POST /style/photo: {ident} に本人の写真・帳簿の作り直し {'済み' if built else 'あとで'}")
    handler.send_json(200, {"ok": True})
