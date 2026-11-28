"""LifeLog PC: トータルコーデのアプリとの窓口 K-TC（2026-11-28）。名前と形を変えない（約束は docs ではなく下のとおり）。

考える・絵を作るのは母艦（D:\\Lifelog）: 全身の帳簿 private/style/wardrobe.json（scripts/Build-Wardrobe.py）と、
試着の絵を作る scripts/Make-TryOn.py（受け口 inbox/tryon/*.json → --queue で 1 件ずつ・鍵 private/style/tryon/.lock）。
この口は受けて置いて起こすだけ。lifelog_pc.py から呼ぶのは features(base)・handles_get・http_get・POSTS・http_post。

どれもオーナーの Bearer（lifelog_pc.py が確かめてから）。
- GET /style/wardrobe → 母艦の private/style/wardrobe.json をそのまま（JSON として読めないとき・無いときは 404 {"error"}）
- POST /style/tryon（multipart/form-data）: kind＝outfit|hair|makeup、ask＝任意（500 字まで・改行や制御文字は空白に）、
  photo を送った順に 1〜4 枚（JPEG・1 枚 15MB まで）。
  → 写真を母艦の private/style/tryon/in/<id>/01.jpg… に、頼みを inbox/tryon/<id>.json（{"id","kind","photos":[絶対パス],"ask"}）に
    置き（どちらも一時ファイルに書いてから入れ替える）、Make-TryOn.py --queue を後ろで起こす（鍵があれば起こさない）。
  → 200 {"id","status":"queued"}。形が違えば 400・大きすぎれば 413・母艦か Make-TryOn.py が無ければ 503（どれも {"error"}）。
- GET /style/tryon/<id> → {"id","status","say","images":[ファイル名…]}
  結果（private/style/tryon/<id>.result.json）があればその status（ok・failed・timeout・login・limit・bad）と say と images。
  無ければ、頼みが待っているとき queued（その回を作っていて鍵があれば running）。知らない id は 404。
  待っているのに鍵が無い（起こし損ねた）ときは、ここでもう一度起こす（間を置いて）。
- GET /style/tryon/<id>/image/<n> → n は 1 から（images の順）。image/jpeg（.png なら image/png）。無ければ 404。
- 顔の写真を長く残さない: 結果が出た頼みの in/<id>/ は消す（POST・GET のたびに見回る。24 時間より古い残りも消す）。
  Make-TryOn.py も、済んだ回の in/<id>/ を消す（母艦の側）。
- features "style"（母艦のフォルダがあるとき）
- 記録（log）に中身（写真・ask）や名前は書かない。書くのは kind・枚数・id の頭だけ。
"""

from __future__ import annotations

import datetime
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

import s30pwork

FEATURE = "style"
POSTS = ("/style/tryon",)
WARDROBE_PATH = "/style/wardrobe"
TRYON_PREFIX = "/style/tryon/"

WARDROBE = Path("private") / "style" / "wardrobe.json"
TRYON = Path("private") / "style" / "tryon"
IN = TRYON / "in"
LOCK = TRYON / ".lock"
INBOX = Path("inbox") / "tryon"
SCRIPT = Path("scripts") / "Make-TryOn.py"

KINDS = ("outfit", "hair", "makeup")
PHOTOS_MAX = 4
PHOTO_MAX_BYTES = 15 * 1024 * 1024
BODY_MAX = PHOTOS_MAX * PHOTO_MAX_BYTES + 1024 * 1024
ASK_MAX = 500
PARTS_MAX = 12
WARDROBE_MAX = 32 * 1024 * 1024
IMAGE_MAX = 64 * 1024 * 1024
LOCK_FRESH_SECONDS = 30 * 60          # Make-TryOn.py と同じ（これより古い鍵は残骸）
LEFTOVER_SECONDS = 24 * 3600          # 結果の出ない in/<id>/ もこれより古ければ消す
REKICK_SECONDS = 60                   # GET で起こし直す間
JPEG_HEAD = b"\xff\xd8"
ID = re.compile(r"[0-9A-Za-z][0-9A-Za-z_-]{0,63}")
TRYON_GET = re.compile(r"/style/tryon/([^/]+)(?:/image/([0-9]{1,3}))?")
SPACES = re.compile(r"[\s\x00-\x1f\x7f]+")
SAY = {"queued": "順番を待っています", "running": "絵を作っています（数分かかります）"}

_lock = threading.Lock()
_last_kick = [float("-inf")]
# 試しで差し替える（実際には起こさない）。(スクリプト, Python, 母艦) → None。失敗は OSError
SPAWN = None


def _home(base: Path | None) -> Path | None:
    return Path(base) if base is not None and Path(base).is_dir() else None


def features(base: Path | None) -> list[str]:
    return [FEATURE] if _home(base) is not None else []


def handles_get(path: str) -> bool:
    return path == WARDROBE_PATH or path.startswith(TRYON_PREFIX)


# MARK: - 返す


def _send_bytes(handler, data: bytes, kind: str) -> None:
    handler.send_response(200)
    handler.send_header("Content-Type", kind)
    handler.send_header("Content-Length", str(len(data)))
    handler.send_header("Cache-Control", "no-store")
    handler.end_headers()
    handler.wfile.write(data)


# MARK: - multipart を読む


def boundary_of(content_type: str) -> bytes | None:
    kind, _, rest = (content_type or "").partition(";")
    if kind.strip().lower() != "multipart/form-data":
        return None
    match = re.search(r'(?i)(?:^|;)\s*boundary=(?:"([^"]{1,70})"|([^;\s]{1,70}))', rest)
    if not match:
        return None
    return (match.group(1) or match.group(2)).encode("latin-1", "replace")


def parse_multipart(body: bytes, boundary: bytes) -> tuple[list[tuple[str, str | None, bytes]] | None, str | None]:
    """[(name, filename, 中身)]・断る理由。RFC 7578 の素直な形だけ読む"""
    pieces = (b"\r\n" + body).split(b"\r\n--" + boundary)
    if len(pieces) < 3:
        return None, "multipart の形が違います"
    parts: list[tuple[str, str | None, bytes]] = []
    closed = False
    for piece in pieces[1:]:
        if piece.startswith(b"--"):
            closed = True
            break
        line_end = piece.find(b"\r\n")
        if line_end < 0 or piece[:line_end].strip(b" \t"):
            return None, "multipart の形が違います"
        head, sep, content = piece[line_end + 2:].partition(b"\r\n\r\n")
        if not sep:
            return None, "multipart の形が違います"
        name, filename = None, None
        for line in head.decode("utf-8", "replace").split("\r\n"):
            key, _, value = line.partition(":")
            if key.strip().lower() != "content-disposition":
                continue
            found = re.search(r'(?:^|;)\s*name="([^"]*)"', value)
            name = found.group(1) if found else None
            found = re.search(r'(?:^|;)\s*filename="([^"]*)"', value)
            filename = found.group(1) if found else None
        if name is None:
            return None, "multipart の欄に名前がありません"
        parts.append((name, filename, content))
        if len(parts) > PARTS_MAX:
            return None, "欄が多すぎます"
    if not closed:
        return None, "multipart が途中で切れています"
    return parts, None


def check_request(parts: list[tuple[str, str | None, bytes]]) -> tuple[dict | None, str | None]:
    """(頼み, 断る理由)。頼みは {"kind", "ask", "photos": [bytes…]}"""
    kind, ask, photos = None, "", []
    for name, _filename, content in parts:
        if name == "kind":
            kind = content.decode("utf-8", "replace").strip()
        elif name == "ask":
            try:
                text = content.decode("utf-8")
            except UnicodeDecodeError:
                return None, "ask は UTF-8 の文字です"
            ask = SPACES.sub(" ", text).strip()
            if len(ask) > ASK_MAX:
                return None, f"ask は {ASK_MAX} 字までです"
        elif name == "photo":
            if len(content) > PHOTO_MAX_BYTES:
                return None, f"写真は 1 枚 {PHOTO_MAX_BYTES // (1024 * 1024)}MB までです"
            if not content.startswith(JPEG_HEAD):
                return None, "写真は JPEG です"
            photos.append(content)
    if kind not in KINDS:
        return None, "kind は " + "・".join(KINDS) + " のどれかです"
    if not 1 <= len(photos) <= PHOTOS_MAX:
        return None, f"photo は 1〜{PHOTOS_MAX} 枚です"
    return {"kind": kind, "ask": ask, "photos": photos}, None


# MARK: - 母艦に置く・起こす


def _replace(final: Path, data: bytes) -> None:
    """一時ファイル（頭が "."・終わりが .tmp）に書いてから入れ替える（Make-TryOn.py の *.json に拾われない）"""
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


def new_id(now: datetime.datetime | None = None) -> str:
    return (now or datetime.datetime.now().astimezone()).strftime("%Y%m%d-%H%M%S-") + secrets.token_hex(3)


def write_request(base: Path, req: dict, ident: str) -> Path:
    """写真と頼みを置く。返すのは頼みのファイル"""
    base = Path(base).resolve()
    folder = base / IN / ident
    folder.mkdir(parents=True, exist_ok=True)
    paths = []
    for n, data in enumerate(req["photos"], 1):
        path = folder / f"{n:02d}.jpg"
        _replace(path, data)
        paths.append(str(path))
    inbox = base / INBOX
    inbox.mkdir(parents=True, exist_ok=True)
    final = inbox / f"{ident}.json"
    row = {"id": ident, "kind": req["kind"], "photos": paths, "ask": req["ask"]}
    _replace(final, json.dumps(row, ensure_ascii=False).encode("utf-8"))
    return final


def lock_active(base: Path) -> bool:
    try:
        age = time.time() - (Path(base) / LOCK).stat().st_mtime
    except OSError:
        return False
    return age <= LOCK_FRESH_SECONDS


def _spawn(script: Path, python: Path, base: Path) -> None:
    flags = 0
    if sys.platform == "win32":
        flags = (getattr(subprocess, "CREATE_NO_WINDOW", 0) | getattr(subprocess, "BELOW_NORMAL_PRIORITY_CLASS", 0)
                 | getattr(subprocess, "DETACHED_PROCESS", 0))
    subprocess.Popen([str(python), str(script), "--queue"], cwd=str(base), creationflags=flags, close_fds=True,
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def kick(base: Path, config: dict, guard: float = 0.0) -> str:
    """"started"・"already"（鍵がある・起こした直後）・"off"。頼みを置いたあとに呼ぶ（置く→鍵を見る の順で取りこぼさない）"""
    base = Path(base)
    script = base / SCRIPT
    if not script.is_file():
        return "off"
    python = s30pwork.python_path(config)
    if SPAWN is None and not python.is_file():
        return "off"
    with _lock:
        if lock_active(base) or 0 <= time.monotonic() - _last_kick[0] < guard:
            return "already"
        try:
            (SPAWN or _spawn)(script, python, base)
        except OSError:
            return "off"
        _last_kick[0] = time.monotonic()
    return "started"


def sweep(base: Path, now: float | None = None) -> int:
    """結果の出た頼みの写真（in/<id>/）と、24 時間より古い残りを消す。返すのは消した数"""
    base = Path(base)
    now = time.time() if now is None else now
    removed = 0
    try:
        folders = [p for p in (base / IN).iterdir() if p.is_dir()]
    except OSError:
        return 0
    for folder in folders:
        done = (base / TRYON / f"{folder.name}.result.json").is_file()
        try:
            old = now - folder.stat().st_mtime > LEFTOVER_SECONDS
        except OSError:
            old = False
        waiting = (base / INBOX / f"{folder.name}.json").is_file()
        if done or (old and not waiting):
            shutil.rmtree(folder, ignore_errors=True)
            removed += 0 if folder.exists() else 1
    return removed


# MARK: - 様子を読む


def read_result(base: Path, ident: str) -> dict | None:
    path = Path(base) / TRYON / f"{ident}.result.json"
    try:
        raw = path.read_bytes()
        data = json.loads(raw.decode("utf-8")) if len(raw) <= 1024 * 1024 else None
    except (OSError, ValueError, UnicodeDecodeError):
        return None
    return data if isinstance(data, dict) else None


def _image_paths(base: Path, result: dict) -> list[Path]:
    """結果の images（母艦からの相対の道）を、private/style/tryon の中にあるものだけ実の道に"""
    root = (Path(base) / TRYON).resolve()
    out = []
    for item in result.get("images") or []:
        if not isinstance(item, str):
            continue
        path = (Path(base) / item).resolve()
        if root in path.parents and path.suffix.lower() in (".jpg", ".jpeg", ".png"):
            out.append(path)
    return out


def status_of(base: Path, ident: str) -> dict | None:
    """GET /style/tryon/<id> の返事（知らない id は None）"""
    result = read_result(base, ident)
    if result is not None:
        status = str(result.get("status") or "failed")
        say = str(result.get("say") or "")
        images = [p.name for p in _image_paths(base, result)] if status == "ok" else []
        return {"id": ident, "status": status, "say": say, "images": images}
    waiting = (Path(base) / INBOX / f"{ident}.json").is_file()
    if not waiting and not (Path(base) / IN / ident).is_dir():
        return None
    running = waiting and lock_active(base) and (Path(base) / TRYON / "work" / ident).is_dir()
    status = "running" if running else "queued"
    return {"id": ident, "status": status, "say": SAY[status], "images": []}


# MARK: - 受け口


def http_get(handler, path: str, config: dict, base: Path | None, log=None) -> None:
    say = log or (lambda message: None)
    base = _home(base)
    if path == WARDROBE_PATH:
        data = None
        if base is not None:
            try:
                raw = (base / WARDROBE).read_bytes()
                if len(raw) <= WARDROBE_MAX:
                    json.loads(raw.decode("utf-8"))
                    data = raw
            except (OSError, ValueError, UnicodeDecodeError):
                data = None
        if data is None:
            handler.send_json(404, {"error": "まだ帳簿がありません"})
            return
        _send_bytes(handler, data, "application/json; charset=utf-8")
        return
    match = TRYON_GET.fullmatch(path)
    if base is None or not match or not ID.fullmatch(match.group(1)):
        handler.send_json(404, {"error": "その頼みはありません"})
        return
    ident = match.group(1)
    sweep(base)
    reply = status_of(base, ident)
    if reply is None:
        handler.send_json(404, {"error": "その頼みはありません"})
        return
    if match.group(2) is None:
        if reply["status"] == "queued" and not lock_active(base):
            run = kick(base, config, guard=REKICK_SECONDS)  # 起こし損ねた・待っている間に前の回が終わった
            if run == "started":
                say(f"GET /style/tryon: 待ちの頼みがあるので起こし直しました（id {ident[:8]}…）")
        handler.send_json(200, reply)
        return
    n = int(match.group(2))
    paths = _image_paths(base, read_result(base, ident) or {}) if reply["status"] == "ok" else []
    if not 1 <= n <= len(paths):
        handler.send_json(404, {"error": "その絵はありません"})
        return
    try:
        data = paths[n - 1].read_bytes() if paths[n - 1].stat().st_size <= IMAGE_MAX else None
    except OSError:
        data = None
    if data is None:
        handler.send_json(404, {"error": "その絵はありません"})
        return
    _send_bytes(handler, data, "image/png" if paths[n - 1].suffix.lower() == ".png" else "image/jpeg")


def http_post(handler, path: str, config: dict, base: Path | None, log=None) -> None:
    """POST /style/tryon。log は文字 1 つを受ける（中身は渡さない）"""
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
    if not (base / SCRIPT).is_file():
        refuse(503, "試着の絵を作る仕組み（Make-TryOn.py）がありません")
        return
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
    boundary = boundary_of(handler.headers.get("Content-Type") or "")
    if boundary is None:
        refuse(400, "multipart/form-data で送ってください")
        return
    body = handler.rfile.read(length)
    parts, problem = parse_multipart(body, boundary)
    req = None
    if parts is not None:
        req, problem = check_request(parts)
    if req is None:
        say("POST /style/tryon: 形が違うので断りました")
        handler.send_json(400, {"error": problem})
        return
    ident = new_id()
    try:
        write_request(base, req, ident)
    except OSError as error:
        shutil.rmtree(base / IN / ident, ignore_errors=True)
        say(f"POST /style/tryon: 母艦に書けませんでした: {type(error).__name__}")
        handler.send_json(500, {"error": "母艦に書けませんでした"})
        return
    sweep(base)
    run = kick(base, config)
    say(f"POST /style/tryon: {req['kind']}・写真 {len(req['photos'])} 枚・起こし {run}（id {ident[:15]}…）")
    handler.send_json(200, {"id": ident, "status": "queued"})
