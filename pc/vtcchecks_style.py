"""2026-11-28（K-TC・K-TC2）: トータルコーデのアプリとの窓口（tcstyle.py・tcphoto.py）を確かめる。

    python pc/vtcchecks_style.py          （v36checks_s36p.py の最後にも呼ばれる。CI の手順を増やさずに動かすため）

本物の HOME・母艦・iPhone は使わない（一時フォルダに作りものの母艦）。写真は作りものの数バイト（JPEG の頭だけ）。
母艦の Make-TryOn.py・Build-Wardrobe.py は実際には起こさず、tcstyle.SPAWN・tcphoto.RUN を差し替えて呼ばれ方だけ確かめる。
"""

from __future__ import annotations

import io
import json
import os
import re
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

if not any(mark in os.environ.get("LOCALAPPDATA", "")
           for mark in ("v25s", "v26s", "v27s", "v30s", "v31s", "v32s", "v33s", "v34s", "v35s", "v36s", "vtcs")):
    os.environ["LOCALAPPDATA"] = str(Path(tempfile.mkdtemp(prefix="vtcs-local-")))

import tcphoto  # noqa: E402
import tcstyle  # noqa: E402
from v6checks import say  # noqa: E402

TMP = Path(tempfile.mkdtemp(prefix="vtcs-"))
KEY = "check-key"
BOUNDARY = "----check-boundary-7f3a"
ASK_SECRET = "ひみつの注文 X1"


class Fake:
    """受け口の作り物（send_json と、絵を返すときの send_response など）"""

    def __init__(self, body: bytes = b"", content_type: str | None = None, length: int | None = None) -> None:
        self.rfile = io.BytesIO(body)
        self.headers = {"Content-Length": str(len(body) if length is None else length)}
        if content_type is not None:
            self.headers["Content-Type"] = content_type
        self.sent: list = []
        self.discarded = False
        self.wfile = io.BytesIO()
        self.raw_headers: dict = {}

    def send_json(self, status: int, body) -> None:
        self.sent = [status, body]

    def discard_body(self) -> None:
        self.discarded = True

    def send_response(self, status: int) -> None:
        self.sent = [status, None]

    def send_header(self, key: str, value: str) -> None:
        self.raw_headers[key] = value

    def end_headers(self) -> None:
        pass


class Spawns:
    def __init__(self) -> None:
        self.calls: list = []

    def __call__(self, script, python, base) -> None:
        self.calls.append((Path(script), Path(python), Path(base)))


def reset(spawns: Spawns | None) -> Spawns | None:
    tcstyle.SPAWN = spawns
    tcstyle._last_kick[0] = float("-inf")
    return spawns


def mother(name: str, script: bool = True) -> Path:
    base = TMP / name
    base.mkdir(parents=True)
    if script:
        (base / "scripts").mkdir()
        (base / "scripts" / "Make-TryOn.py").write_text("# 見本\n", encoding="utf-8")
    return base


def jpeg(n: int = 0, size: int = 64) -> bytes:
    return b"\xff\xd8\xff\xe0" + bytes([n % 256]) * size + b"\xff\xd9"


def form(fields: list[tuple[str, bytes | str, str | None]], boundary: str = BOUNDARY) -> bytes:
    """[(name, 中身, filename)] → multipart の体"""
    out = b""
    for name, value, filename in fields:
        data = value.encode("utf-8") if isinstance(value, str) else value
        disp = f'form-data; name="{name}"' + (f'; filename="{filename}"' if filename else "")
        out += f"--{boundary}\r\nContent-Disposition: {disp}\r\n".encode("utf-8")
        if filename:
            out += b"Content-Type: image/jpeg\r\n"
        out += b"\r\n" + data + b"\r\n"
    return out + f"--{boundary}--\r\n".encode("utf-8")


def good(kind: str = "outfit", photos: int = 3, ask: str | None = None) -> bytes:
    fields: list = [("kind", kind, None)]
    if ask is not None:
        fields.append(("ask", ask, None))
    fields += [("photo", jpeg(n), f"p{n}.jpg") for n in range(photos)]
    return form(fields)


CT = f"multipart/form-data; boundary={BOUNDARY}"
CFG = {"mothership_python": str(Path(sys.executable))}


def post(base: Path | None, body: bytes, content_type: str | None = CT, logs: list | None = None,
         length: int | None = None) -> tuple:
    f = Fake(body, content_type, length)
    tcstyle.http_post(f, "/style/tryon", CFG, base, (logs.append if logs is not None else None))
    return f.sent[0], f.sent[1], f


def get(base: Path | None, path: str, logs: list | None = None) -> tuple:
    f = Fake()
    tcstyle.http_get(f, path, CFG, base, (logs.append if logs is not None else None))
    return f.sent[0], f.sent[1], f


def check_post() -> int:
    failed = 0
    base = mother("post")
    spawns = reset(Spawns())
    logs: list = []
    st, reply, _ = post(base, good(ask=f"もう少し\n明るい色で\t{ASK_SECRET}"), logs=logs)
    ident = (reply or {}).get("id", "")
    failed += say(st == 200 and reply.get("status") == "queued" and re.fullmatch(r"\d{8}-\d{6}-[0-9a-f]{6}", ident or "") is not None,
                  f"POST: すぐ queued と id を返す {reply}")
    row = json.loads((base / tcstyle.INBOX / f"{ident}.json").read_text(encoding="utf-8"))
    folder = (base / tcstyle.IN / ident).resolve()
    failed += say(row.get("id") == ident and row.get("kind") == "outfit"
                  and row.get("photos") == [str(folder / f"{n:02d}.jpg") for n in (1, 2, 3)],
                  "POST: inbox/tryon/<id>.json に kind と写真の絶対パス（送った順に 01.jpg…）")
    failed += say(all(Path(p).is_absolute() and Path(p).read_bytes() == jpeg(n) for n, p in enumerate(row["photos"])),
                  "POST: 写真は中身のまま in/<id>/ に")
    failed += say(row.get("ask") == f"もう少し 明るい色で {ASK_SECRET}", f"POST: ask の改行・タブは空白に {row.get('ask')!r}")
    failed += say(not list((base / tcstyle.INBOX).glob(".*")) and not list(folder.glob(".*")), "POST: 一時ファイルが残らない")
    call = spawns.calls[0] if spawns.calls else None
    failed += say(len(spawns.calls) == 1 and call[0] == base / tcstyle.SCRIPT and call[2] == base,
                  "POST: Make-TryOn.py を母艦で起こす")
    joined = "\n".join(logs)
    failed += say(bool(logs) and ASK_SECRET not in joined and "p0.jpg" not in joined and ident not in joined,
                  f"POST: 記録に ask・ファイル名・id の全部を書かない（{len(logs)} 行）")
    # 鍵があれば起こさない（置くだけ）
    (base / tcstyle.LOCK).parent.mkdir(parents=True, exist_ok=True)
    (base / tcstyle.LOCK).write_text("1", encoding="utf-8")
    st, reply, _ = post(base, good(kind="hair", photos=1))
    failed += say(st == 200 and len(spawns.calls) == 1 and (base / tcstyle.INBOX / f"{reply['id']}.json").is_file(),
                  "POST: 鍵（.lock）があれば起こさず置くだけ")
    old = time.time() - tcstyle.LOCK_FRESH_SECONDS - 60
    os.utime(base / tcstyle.LOCK, (old, old))
    st, reply, _ = post(base, good(kind="makeup", photos=4))
    failed += say(st == 200 and len(spawns.calls) == 2, "POST: 30 分より古い鍵は残骸として起こす")
    (base / tcstyle.LOCK).unlink()
    # ask なし・最大の 4 枚・ちょうど 15MB
    big = b"\xff\xd8" + b"a" * (tcstyle.PHOTO_MAX_BYTES - 2)
    st, reply, _ = post(base, form([("kind", "outfit", None), ("photo", big, "a.jpg")]))
    row = json.loads((base / tcstyle.INBOX / f"{reply['id']}.json").read_text(encoding="utf-8")) if st == 200 else {}
    failed += say(st == 200 and row.get("ask") == "" and len(row.get("photos") or []) == 1, "POST: ask なし・ちょうど 15MB は受ける")
    # 引用符つきの boundary
    st, reply, _ = post(base, good(photos=1), content_type=f'multipart/form-data; boundary="{BOUNDARY}"')
    failed += say(st == 200, "POST: boundary に引用符があっても読む")
    # 母艦が無い・Make-TryOn が無い
    st, reply, f = post(None, good())
    failed += say(st == 503 and "error" in reply and f.discarded, "POST: 母艦が無ければ 503")
    st, reply, f = post(TMP / "nowhere", good())
    failed += say(st == 503, "POST: 母艦のフォルダが無ければ 503")
    none = mother("noscript", script=False)
    st, reply, f = post(none, good())
    failed += say(st == 503 and not (none / tcstyle.INBOX).exists(), "POST: Make-TryOn.py が無ければ 503（何も置かない）")
    return failed


def check_validate() -> int:
    failed = 0
    base = mother("validate")
    spawns = reset(Spawns())
    big = b"\xff\xd8" + b"a" * (tcstyle.PHOTO_MAX_BYTES - 1)
    bad = {
        "kind が無い": form([("photo", jpeg(), "a.jpg")]),
        "kind が free": good(kind="free"),
        "kind が知らない": good(kind="shoes"),
        "写真が 0 枚": good(photos=0),
        "写真が 5 枚": good(photos=5),
        "写真が JPEG でない": form([("kind", "outfit", None), ("photo", b"\x89PNG\r\n\x1a\n" + b"x" * 20, "a.png")]),
        "写真が 15MB を超える": form([("kind", "outfit", None), ("photo", big, "a.jpg")]),
        "ask が 501 字": good(ask="あ" * 501),
        "ask が UTF-8 でない": form([("kind", "outfit", None), ("ask", b"\xff\xfe\x00", None), ("photo", jpeg(), "a.jpg")]),
        "途中で切れた": good()[:-30],
        "名前の無い欄": f"--{BOUNDARY}\r\nContent-Disposition: form-data\r\n\r\nx\r\n--{BOUNDARY}--\r\n".encode(),
        "区切りが無い": b"kind=outfit",
        "欄が多すぎる": form([("x", "1", None)] * 13 + [("kind", "outfit", None), ("photo", jpeg(), "a.jpg")]),
    }
    for label, body in bad.items():
        st, reply, _ = post(base, body)
        failed += say(st == 400 and "error" in reply, f"検め: {label} は 400（{reply}）")
    for label, ct in (("JSON で送った", "application/json"), ("boundary が無い", "multipart/form-data"), ("Content-Type が無い", None)):
        st, reply, f = post(base, good(), content_type=ct)
        failed += say(st == 400 and f.discarded, f"検め: {label} は 400（読まずに断る）")
    st, reply, f = post(base, b"")
    failed += say(st == 400 and f.discarded, "検め: 中身が無ければ 400")
    st, reply, f = post(base, b"x", length=tcstyle.BODY_MAX + 1)
    failed += say(st == 413 and f.discarded, "検め: 体が大きすぎれば 413（読まずに断る）")
    failed += say(not (base / tcstyle.INBOX).exists() and not (base / tcstyle.IN).exists() and not spawns.calls,
                  "検め: 断ったときは何も置かず・起こさない")
    return failed


def put_result(base: Path, ident: str, status: str, images: list[str], say_: str = "1 枚できた") -> None:
    folder = base / tcstyle.TRYON
    folder.mkdir(parents=True, exist_ok=True)
    (folder / f"{ident}.result.json").write_text(json.dumps({"id": ident, "status": status, "say": say_, "images": images,
                                                             "child": "子の返事"}, ensure_ascii=False), encoding="utf-8")


def check_status() -> int:
    failed = 0
    base = mother("status")
    spawns = reset(Spawns())
    st, reply, _ = post(base, good(photos=2))
    ident = reply["id"]
    calls = len(spawns.calls)
    # 待ち（鍵なし）: queued。起こした直後は起こし直さない
    st, reply, _ = get(base, f"/style/tryon/{ident}")
    failed += say(st == 200 and reply == {"id": ident, "status": "queued", "say": tcstyle.SAY["queued"], "images": []},
                  f"GET: 待ちは queued {reply}")
    failed += say(len(spawns.calls) == calls, "GET: 起こした直後は起こし直さない")
    tcstyle._last_kick[0] = float("-inf")
    st, reply, _ = get(base, f"/style/tryon/{ident}")
    failed += say(reply["status"] == "queued" and len(spawns.calls) == calls + 1, "GET: 待っているのに鍵が無ければ起こし直す")
    # 鍵があってもほかの回を作っているなら queued、この回の work/<id> があれば running
    (base / tcstyle.LOCK).write_text("1", encoding="utf-8")
    st, reply, _ = get(base, f"/style/tryon/{ident}")
    failed += say(reply["status"] == "queued" and len(spawns.calls) == calls + 1, "GET: 鍵があってほかの回なら queued（起こさない）")
    (base / tcstyle.TRYON / "work" / ident).mkdir(parents=True)
    st, reply, _ = get(base, f"/style/tryon/{ident}")
    failed += say(reply["status"] == "running" and reply["say"] == tcstyle.SAY["running"], f"GET: この回を作っていれば running {reply}")
    # 結果が出た: ok・images はファイル名だけ・写真は消す
    day = base / tcstyle.TRYON / "2026-11-28"
    day.mkdir(parents=True)
    (day / f"{ident}-1.jpg").write_bytes(jpeg(7))
    (day / f"{ident}-2.png").write_bytes(b"\x89PNG-check")
    (TMP / "secret.jpg").write_bytes(b"secret")
    (base / tcstyle.TRYON / "work" / ident).rmdir()
    (base / tcstyle.LOCK).unlink()
    (base / tcstyle.INBOX / f"{ident}.json").unlink()
    put_result(base, ident, "ok", [f"private/style/tryon/2026-11-28/{ident}-1.jpg", f"private/style/tryon/2026-11-28/{ident}-2.png",
                                   "../secret.jpg", "private/style/wardrobe.json", 5])
    failed += say((base / tcstyle.IN / ident).is_dir(), "（前提）結果の前は写真が in/<id>/ にある")
    st, reply, _ = get(base, f"/style/tryon/{ident}")
    failed += say(st == 200 and reply == {"id": ident, "status": "ok", "say": "1 枚できた", "images": [f"{ident}-1.jpg", f"{ident}-2.png"]},
                  f"GET: ok と say とファイル名だけ（母艦の外・帳簿などは出さない） {reply}")
    failed += say(not (base / tcstyle.IN / ident).exists(), "GET: 結果が出た頼みの写真（in/<id>/）は消す")
    st, _, f = get(base, f"/style/tryon/{ident}/image/1")
    failed += say(st == 200 and f.wfile.getvalue() == jpeg(7) and f.raw_headers.get("Content-Type") == "image/jpeg"
                  and f.raw_headers.get("Content-Length") == str(len(jpeg(7))), "GET image/1: JPEG を返す")
    st, _, f = get(base, f"/style/tryon/{ident}/image/2")
    failed += say(st == 200 and f.raw_headers.get("Content-Type") == "image/png", "GET image/2: .png なら image/png")
    for n in ("0", "3", "99"):
        st, reply, _ = get(base, f"/style/tryon/{ident}/image/{n}")
        failed += say(st == 404 and "error" in reply, f"GET image/{n}: 無い番号は 404")
    # 失敗の結果
    put_result(base, "20261128-000000-aaaaaa", "limit", [], "今日はもう作れません（Gemini の 1 日の上限）")
    st, reply, _ = get(base, "/style/tryon/20261128-000000-aaaaaa")
    failed += say(reply == {"id": "20261128-000000-aaaaaa", "status": "limit", "say": "今日はもう作れません（Gemini の 1 日の上限）",
                            "images": []}, f"GET: 失敗の status と say {reply}")
    st, reply, _ = get(base, "/style/tryon/20261128-000000-aaaaaa/image/1")
    failed += say(st == 404, "GET image: ok でなければ 404")
    # 知らない id・変な id
    for path in ("/style/tryon/20991231-000000-ffffff", "/style/tryon/..", "/style/tryon/../wardrobe", "/style/tryon/",
                 "/style/tryon/a b", f"/style/tryon/{ident}/image/x", f"/style/tryon/{ident}/other"):
        st, reply, _ = get(base, path)
        failed += say(st == 404 and "error" in reply, f"GET {path}: 404")
    st, reply, _ = get(None, f"/style/tryon/{ident}")
    failed += say(st == 404, "GET: 母艦が無ければ 404")
    return failed


def check_sweep() -> int:
    failed = 0
    base = mother("sweep")
    reset(Spawns())
    folder = base / tcstyle.IN
    for name in ("done1", "waiting1", "old1", "new1"):
        (folder / name).mkdir(parents=True)
        (folder / name / "01.jpg").write_bytes(jpeg())
    put_result(base, "done1", "failed", [])
    (base / tcstyle.INBOX).mkdir(parents=True)
    (base / tcstyle.INBOX / "waiting1.json").write_text("{}", encoding="utf-8")
    old = time.time() - tcstyle.LEFTOVER_SECONDS - 60
    for name in ("waiting1", "old1"):
        os.utime(folder / name, (old, old))
    removed = tcstyle.sweep(base)
    left = sorted(p.name for p in folder.iterdir())
    failed += say(removed == 2 and left == ["new1", "waiting1"],
                  f"見回り: 結果の出たもの・24 時間より古い残りは消し、待っているもの・新しいものは残す {left}")
    failed += say(tcstyle.sweep(TMP / "nowhere") == 0, "見回り: in/ が無くても落ちない")
    return failed


def check_wardrobe() -> int:
    failed = 0
    base = mother("wardrobe")
    st, reply, _ = get(base, "/style/wardrobe")
    failed += say(st == 404 and "error" in reply, "GET /style/wardrobe: 無ければ 404")
    raw = json.dumps({"items": [{"id": "x", "name": "白いシャツ"}]}, ensure_ascii=False, indent=1).encode("utf-8")
    (base / tcstyle.WARDROBE).parent.mkdir(parents=True, exist_ok=True)
    (base / tcstyle.WARDROBE).write_bytes(raw)
    st, _, f = get(base, "/style/wardrobe")
    failed += say(st == 200 and f.wfile.getvalue() == raw and f.raw_headers.get("Content-Type", "").startswith("application/json"),
                  "GET /style/wardrobe: そのまま返す")
    (base / tcstyle.WARDROBE).write_bytes(b'{"items": [')
    st, reply, _ = get(base, "/style/wardrobe")
    failed += say(st == 404, "GET /style/wardrobe: 壊れていれば 404")
    st, reply, _ = get(None, "/style/wardrobe")
    failed += say(st == 404, "GET /style/wardrobe: 母艦が無ければ 404")
    failed += say(tcstyle.features(base) == ["style"] and tcstyle.features(None) == [] and tcstyle.features(TMP / "nowhere") == [],
                  "features: 母艦があれば style")
    return failed


class Runs:
    def __init__(self, ok: bool = True) -> None:
        self.calls: list = []
        self.ok = ok

    def __call__(self, script, python, base) -> bool:
        self.calls.append((Path(script), Path(base)))
        return self.ok


ITEMS = ["to-9d07a06a", "bo-0b7881cd", "sh-11111111"]


def closet(name: str, pmap: dict | None = None, script: bool = True) -> Path:
    base = mother(name, script=False)
    (base / tcstyle.WARDROBE).parent.mkdir(parents=True, exist_ok=True)
    items = [{"id": i, "name": f"品 {i}", "photo": None} for i in ITEMS]
    (base / tcstyle.WARDROBE).write_text(json.dumps({"version": 1, "items": items}, ensure_ascii=False), encoding="utf-8")
    if script:
        (base / "scripts").mkdir(exist_ok=True)
        (base / tcphoto.SCRIPT).write_text("# 見本\n", encoding="utf-8")
    if pmap is not None:
        (base / tcphoto.PMAP).write_text(json.dumps(pmap, ensure_ascii=False), encoding="utf-8")
    return base


def photo_post(base: Path | None, path: str, body: bytes, content_type: str | None = CT, logs: list | None = None,
               length: int | None = None) -> tuple:
    f = Fake(body, content_type, length)
    tcphoto.http_post(f, path, CFG, base, (logs.append if logs is not None else None))
    return f.sent[0], f.sent[1], f


def photo_get(base: Path | None, path: str) -> Fake:
    f = Fake()
    tcphoto.http_get(f, path, base)
    return f


def judge_body(value) -> bytes:
    return json.dumps({"ok": value}).encode("utf-8")


def pmap_of(base: Path) -> dict:
    return json.loads((base / tcphoto.PMAP).read_text(encoding="utf-8"))


SHOP = {"src": "shop", "sure": "maybe", "page": "https://shop.example/p/1", "url": "https://shop.example/i/1.jpg",
        "match": 0.8, "rejected": ["https://old.example/x.jpg"]}
JSON_CT = "application/json"


def check_photo() -> int:
    failed = 0
    base = closet("photo", {"to-9d07a06a": dict(SHOP), "bo-0b7881cd": dict(SHOP)})
    runs = Runs()
    tcphoto.RUN = runs
    logs: list = []
    failed += say(photo_get(base, "/style/photo/to-9d07a06a").sent[0] == 404, "GET /style/photo: 写真ファイルが無ければ 404")
    st, reply, _ = photo_post(base, "/style/photo/to-9d07a06a", form([("photo", jpeg(3), "a.jpg")]), logs=logs)
    failed += say(st == 200 and reply == {"ok": True}, f"POST /style/photo: ok true {reply}")
    failed += say(tcphoto.photo_path(base, "to-9d07a06a").read_bytes() == jpeg(3), "POST /style/photo: photos/<id>.jpg に中身のまま")
    row = pmap_of(base)["to-9d07a06a"]
    failed += say(row == {"src": "own", "sure": "yes", "rejected": ["https://old.example/x.jpg"]},
                  f"POST /style/photo: 台帳は own・yes（removed・page・url・match は外し rejected は残す） {row}")
    failed += say(pmap_of(base)["bo-0b7881cd"] == SHOP, "POST /style/photo: ほかの服の台帳は変えない")
    failed += say(runs.calls == [(base / tcphoto.SCRIPT, base)], "POST /style/photo: Build-Wardrobe.py を母艦で 1 回")
    failed += say(not list((base / tcphoto.PHOTOS).glob(".*")) and not list((base / tcphoto.PMAP).parent.glob(".*.tmp")),
                  "POST /style/photo: 一時ファイルが残らない")
    f = photo_get(base, "/style/photo/to-9d07a06a")
    failed += say(f.sent[0] == 200 and f.wfile.getvalue() == jpeg(3) and f.raw_headers.get("Content-Type") == "image/jpeg",
                  "GET /style/photo: JPEG を返す")
    failed += say(bool(logs) and not any("品 " in line for line in logs), "記録に品名を書かない")
    # judge true（お店の写真を「合っている」）
    tcphoto.photo_path(base, "bo-0b7881cd").write_bytes(jpeg(4))
    st, reply, _ = photo_post(base, "/style/photo/bo-0b7881cd/judge", judge_body(True), JSON_CT)
    row = pmap_of(base)["bo-0b7881cd"]
    failed += say(st == 200 and reply == {"ok": True} and row == dict(SHOP, sure="yes") and len(runs.calls) == 2,
                  f"judge true: sure を yes（ほかは変えない）・作り直し {row}")
    # judge false（「違う」）
    st, reply, _ = photo_post(base, "/style/photo/bo-0b7881cd/judge", judge_body(False), JSON_CT)
    row = pmap_of(base)["bo-0b7881cd"]
    failed += say(st == 200 and not tcphoto.photo_path(base, "bo-0b7881cd").exists() and row.get("removed") is True
                  and row.get("rejected") == ["https://old.example/x.jpg", "https://shop.example/i/1.jpg"] and len(runs.calls) == 3,
                  f"judge false: 写真を消し removed・url を rejected に足す {row}")
    failed += say(photo_get(base, "/style/photo/bo-0b7881cd").sent[0] == 404, "GET /style/photo: 消したあとは 404")
    st, reply, _ = photo_post(base, "/style/photo/bo-0b7881cd/judge", judge_body(False), JSON_CT)
    failed += say(st == 404, "judge: 写真が無ければ 404")
    tcphoto.photo_path(base, "bo-0b7881cd").write_bytes(jpeg(5))  # removed のまま残ったファイル
    failed += say(photo_get(base, "/style/photo/bo-0b7881cd").sent[0] == 404, "GET /style/photo: 台帳で removed なら、ファイルがあっても 404")
    st, reply, _ = photo_post(base, "/style/photo/bo-0b7881cd/judge", judge_body(True), JSON_CT)
    failed += say(st == 404, "judge: 台帳で removed なら 404")
    st, reply, _ = photo_post(base, "/style/photo/bo-0b7881cd", form([("photo", jpeg(6), "b.jpg")]))
    row = pmap_of(base)["bo-0b7881cd"]
    failed += say(st == 200 and row == {"src": "own", "sure": "yes", "rejected": ["https://old.example/x.jpg", "https://shop.example/i/1.jpg"]},
                  f"POST /style/photo: removed を外して本人の写真に {row}")
    # 台帳が無い・Build-Wardrobe が無い
    fresh = closet("photo-fresh", None, script=False)
    runs2 = Runs()
    tcphoto.RUN = runs2
    st, reply, _ = photo_post(fresh, "/style/photo/sh-11111111", form([("photo", jpeg(7), "c.jpg")]))
    failed += say(st == 200 and pmap_of(fresh) == {"sh-11111111": {"src": "own", "sure": "yes"}} and not runs2.calls,
                  "POST /style/photo: 台帳が無ければ作る・Build-Wardrobe.py が無くても ok（15 分ごとの回で直る）")
    broken = closet("photo-broken", None)
    (broken / tcphoto.PMAP).write_text("{broken", encoding="utf-8")
    st, reply, _ = photo_post(broken, "/style/photo/sh-11111111", form([("photo", jpeg(7), "c.jpg")]))
    failed += say(st == 500 and (broken / tcphoto.PMAP).read_text(encoding="utf-8") == "{broken"
                  and not tcphoto.photo_path(broken, "sh-11111111").exists(), "壊れた台帳は上書きせず 500（写真も置かない）")
    tcphoto.RUN = runs
    return failed


def check_photo_validate() -> int:
    failed = 0
    base = closet("photo-validate", {})
    runs = Runs()
    tcphoto.RUN = runs
    big = b"\xff\xd8" + b"a" * (tcphoto.PHOTO_MAX_BYTES - 1)
    cases = {
        "写真が 0 枚": form([("kind", "x", None)]),
        "写真が 2 枚": form([("photo", jpeg(), "a.jpg"), ("photo", jpeg(), "b.jpg")]),
        "JPEG でない": form([("photo", b"\x89PNG\r\n\x1a\n" + b"x" * 20, "a.png")]),
        "15MB を超える": form([("photo", big, "a.jpg")]),
        "途中で切れた": form([("photo", jpeg(), "a.jpg")])[:-20],
    }
    for label, body in cases.items():
        st, reply, _ = photo_post(base, "/style/photo/to-9d07a06a", body)
        failed += say(st == 400 and "error" in reply, f"POST /style/photo 検め: {label} は 400")
    st, reply, f = photo_post(base, "/style/photo/to-9d07a06a", form([("photo", jpeg(), "a.jpg")]), content_type="image/jpeg")
    failed += say(st == 400 and f.discarded, "POST /style/photo 検め: multipart でなければ 400")
    st, reply, f = photo_post(base, "/style/photo/to-9d07a06a", b"x", length=tcphoto.BODY_MAX + 1)
    failed += say(st == 413 and f.discarded, "POST /style/photo 検め: 大きすぎれば 413")
    for value in ("yes", 1, None):
        st, reply, _ = photo_post(base, "/style/photo/to-9d07a06a/judge", judge_body(value), JSON_CT)
        failed += say(st == 400, f"judge 検め: ok が {value!r} なら 400")
    st, reply, _ = photo_post(base, "/style/photo/to-9d07a06a/judge", b"{broken", JSON_CT)
    failed += say(st == 400, "judge 検め: 壊れた JSON は 400")
    st, reply, f = photo_post(base, "/style/photo/to-9d07a06a/judge", b"x", JSON_CT, length=tcphoto.JUDGE_MAX + 1)
    failed += say(st == 413 and f.discarded, "judge 検め: 大きすぎれば 413")
    for path in ("/style/photo/zz-00000000", "/style/photo/..", "/style/photo/", "/style/photo/to-9d07a06a/other",
                 "/style/photo/a b", "/style/photo/zz-00000000/judge"):
        st, reply, f = photo_post(base, path, form([("photo", jpeg(), "a.jpg")]))
        failed += say(st == 404 and f.discarded, f"POST {path}: 帳簿に無い・形の違う道は 404（読まずに断る）")
        failed += say(photo_get(base, path).sent[0] == 404, f"GET {path}: 404")
    failed += say(photo_get(base, "/style/photo/to-9d07a06a/judge").sent[0] == 404, "GET .../judge: 404")
    failed += say(not (base / tcphoto.PHOTOS).exists() and pmap_of(base) == {} and not runs.calls, "検め: 断ったときは何も書かず・起こさない")
    st, reply, f = photo_post(None, "/style/photo/to-9d07a06a", form([("photo", jpeg(), "a.jpg")]))
    failed += say(st == 503 and f.discarded, "POST: 母艦が無ければ 503")
    failed += say(tcphoto.features(base) == ["style-photo"] and tcphoto.features(mother("photo-nowardrobe")) == []
                  and tcphoto.features(None) == [], "features: 帳簿があれば style-photo")
    return failed


def check_http() -> int:
    """本物の受け口（lifelog_pc.Handler）に HTTP でつなぐ: 鍵が無い・違うと 401、合っていれば受ける"""
    failed = 0
    try:
        import lifelog_pc as main
    except Exception as error:  # noqa: BLE001
        print(f"SKIP  lifelog_pc を読み込めないので HTTP の確かめを飛ばす: {type(error).__name__}: {error}", flush=True)
        return failed
    base = mother("http")
    spawns = reset(Spawns())
    saved = (getattr(main.Handler, "key", None), main.log, main.load_config)
    had_engine = hasattr(main.Handler, "engine")
    server = None
    try:
        main.Handler.key = KEY
        if not had_engine:
            main.Handler.engine = type("FakeEngine", (), {"label": "check", "provider": "check", "engines": []})()
        main.log = lambda message: None
        main.load_config = lambda: {"lifelog_home": str(base), "mothership_python": str(Path(sys.executable))}
        server = main.Server(("127.0.0.1", 0), main.Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        port = server.server_address[1]

        def call(method: str, path: str, body: bytes | None = None, key: str | None = KEY,
                 content_type: str = CT) -> tuple[int, bytes, str]:
            req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=body, method=method)
            if body is not None:
                req.add_header("Content-Type", content_type)
            if key is not None:
                req.add_header("Authorization", f"Bearer {key}")
            try:
                with urllib.request.urlopen(req, timeout=10) as r:
                    return r.status, r.read(), r.headers.get("Content-Type", "")
            except urllib.error.HTTPError as error:
                return error.code, error.read(), error.headers.get("Content-Type", "")

        for key in (None, "wrong"):
            for method, path, body in (("POST", "/style/tryon", good()), ("GET", "/style/wardrobe", None),
                                       ("GET", "/style/tryon/20261128-000000-aaaaaa", None),
                                       ("GET", "/style/tryon/20261128-000000-aaaaaa/image/1", None)):
                st, _, _ = call(method, path, body, key)
                failed += say(st == 401, f"{method} {path}: 鍵が{'無い' if key is None else '違う'}と 401")
        failed += say(not (base / tcstyle.INBOX).exists() and not spawns.calls, "401 のときは置かず・起こさない")
        st, raw, _ = call("POST", "/style/tryon", good(photos=3))
        reply = json.loads(raw.decode("utf-8"))
        failed += say(st == 200 and reply.get("status") == "queued" and len(spawns.calls) == 1, f"POST /style/tryon: 鍵が合えば受ける {reply}")
        ident = reply.get("id", "")
        st, raw, _ = call("GET", f"/style/tryon/{ident}")
        failed += say(st == 200 and json.loads(raw.decode("utf-8")).get("status") == "queued", "GET /style/tryon/<id>: queued")
        day = base / tcstyle.TRYON / "2026-11-28"
        day.mkdir(parents=True, exist_ok=True)
        (day / f"{ident}-1.jpg").write_bytes(jpeg(5))
        put_result(base, ident, "ok", [f"private/style/tryon/2026-11-28/{ident}-1.jpg"])
        st, raw, _ = call("GET", f"/style/tryon/{ident}")
        failed += say(st == 200 and json.loads(raw.decode("utf-8")).get("images") == [f"{ident}-1.jpg"], "GET /style/tryon/<id>: ok と絵の名前")
        st, raw, kind = call("GET", f"/style/tryon/{ident}/image/1")
        failed += say(st == 200 and raw == jpeg(5) and kind == "image/jpeg", "GET /style/tryon/<id>/image/1: JPEG")
        st, raw, _ = call("POST", "/style/tryon", good(kind="free"))
        failed += say(st == 400, "POST /style/tryon: 形が違えば 400")
        st, raw, _ = call("GET", "/style/wardrobe")
        failed += say(st == 404, "GET /style/wardrobe: 無ければ 404")
        st, raw, _ = call("GET", "/hello")
        features = json.loads(raw.decode("utf-8")).get("features") or []
        failed += say(st == 200 and "style" in features and "style-photo" not in features,
                      "features に style（帳簿が無いので style-photo は無し）")
        # K-TC2: 服の写真
        runs = Runs()
        tcphoto.RUN = runs
        (base / tcstyle.WARDROBE).parent.mkdir(parents=True, exist_ok=True)
        (base / tcstyle.WARDROBE).write_text(json.dumps({"items": [{"id": "to-9d07a06a"}]}), encoding="utf-8")
        (base / tcphoto.SCRIPT).write_text("# 見本\n", encoding="utf-8")
        for key in (None, "wrong"):
            for method, path, body, ct in (("GET", "/style/photo/to-9d07a06a", None, CT),
                                           ("POST", "/style/photo/to-9d07a06a", form([("photo", jpeg(1), "a.jpg")]), CT),
                                           ("POST", "/style/photo/to-9d07a06a/judge", judge_body(True), "application/json")):
                st, _, _ = call(method, path, body, key, ct)
                failed += say(st == 401, f"{method} {path}: 鍵が{'無い' if key is None else '違う'}と 401")
        failed += say(not (base / tcphoto.PHOTOS).exists() and not runs.calls, "401 のときは書かず・起こさない")
        st, raw, _ = call("POST", "/style/photo/to-9d07a06a", form([("photo", jpeg(1), "a.jpg")]))
        failed += say(st == 200 and json.loads(raw.decode("utf-8")) == {"ok": True} and len(runs.calls) == 1,
                      "POST /style/photo: 鍵が合えば受ける（Build-Wardrobe.py を 1 回）")
        st, raw, kind = call("GET", "/style/photo/to-9d07a06a")
        failed += say(st == 200 and raw == jpeg(1) and kind == "image/jpeg", "GET /style/photo: JPEG")
        st, raw, _ = call("POST", "/style/photo/to-9d07a06a/judge", judge_body(False), content_type="application/json")
        failed += say(st == 200 and not tcphoto.photo_path(base, "to-9d07a06a").exists(), "POST /style/photo/<id>/judge: 違う → 消す")
        st, raw, _ = call("GET", "/hello")
        features = json.loads(raw.decode("utf-8")).get("features") or []
        failed += say("style-photo" in features, "features に style-photo（帳簿があるとき）")
    finally:
        if server is not None:
            server.shutdown()
            server.server_close()
        main.Handler.key, main.log, main.load_config = saved
        if not had_engine and hasattr(main.Handler, "engine"):
            del main.Handler.engine
    return failed


def check_hub() -> int:
    failed = 0
    hub = (Path(__file__).resolve().parent / "lifelog_pc.py").read_text(encoding="utf-8")
    failed += say("import tcphoto" in hub and "tcphoto.features(mothership.home(load_config()))" in hub
                  and "tcphoto.handles_get(path)" in hub and "tcphoto.handles_post(url.path)" in hub,
                  "lifelog_pc.py: K-TC2 を features・GET・POST につないである")
    for marker in ("tcphoto.handles_get(path)", "tcphoto.handles_post(url.path)"):
        failed += say("self.authorized()" in hub[hub.index(marker):][:200], f"lifelog_pc.py: {marker} はオーナーの鍵の後ろ")
    failed += say(not any(tcphoto.handles_get(p) for p in ("/style/wardrobe", "/style/tryon/x"))
                  and not tcstyle.handles_get("/style/photo/x") and not tcphoto.handles_post("/style/tryon"),
                  "K-TC と K-TC2 の道がぶつからない")
    failed += say("import tcstyle" in hub and "tcstyle.features(mothership.home(load_config()))" in hub
                  and "tcstyle.handles_get(path)" in hub and "url.path in tcstyle.POSTS" in hub, "lifelog_pc.py: features・GET・POST につないである")
    for marker in ("tcstyle.handles_get(path)", "url.path in tcstyle.POSTS"):
        failed += say("self.authorized()" in hub[hub.index(marker):][:200], f"lifelog_pc.py: {marker} はオーナーの鍵の後ろ")
    import askmother
    import mothership
    import s30pwork
    import s35pwork
    import s36pwork

    posts = set(mothership.POSTS) | set(s30pwork.POSTS) | set(s35pwork.POSTS) | set(s36pwork.POSTS) | set(askmother.POSTS)
    failed += say(not set(tcstyle.POSTS) & posts and not any(tcstyle.handles_get(p) for p in s36pwork.GETS),
                  "ほかの口と道の名前がぶつからない")
    return failed


CHECKS = [check_post, check_validate, check_status, check_sweep, check_wardrobe, check_photo, check_photo_validate, check_http, check_hub]


def run_all() -> int:
    failed = 0
    for check in CHECKS:
        try:
            failed += check()
        except Exception as error:  # noqa: BLE001 — 1 つが落ちても、ほかは確かめる
            import traceback

            traceback.print_exc()
            failed += say(False, f"{check.__name__} が途中で落ちました: {error!r}")
    tcstyle.SPAWN = None
    tcphoto.RUN = None
    return failed


def main() -> int:
    failed = run_all()
    print("ぜんぶ OK" if not failed else f"NG の数: {failed}", flush=True)
    return failed


if __name__ == "__main__":
    sys.exit(main())
