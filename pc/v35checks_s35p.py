"""2026-11-28（s35。担当 p）: 家の PC の s35 の分を確かめる（K35 の POST /work/photo・features "workphoto"）。

    python pc/v35checks_s35p.py          （v34checks_s34p.py の最後にも呼ばれる。CI の手順を増やさずに動かすため）

本物の HOME・母艦・iPhone は使わない（一時フォルダに作りものの母艦）。写真は作りものの数バイト（JPEG の頭だけ）。
母艦のスクリプトは実際には起こさず、s30pwork.SPAWN を差し替えて呼ばれ方だけ確かめる。
"""

from __future__ import annotations

import base64
import io
import json
import os
import sys
import tempfile
import threading
import urllib.error
import urllib.request
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

if not any(mark in os.environ.get("LOCALAPPDATA", "")
           for mark in ("v25s", "v26s", "v27s", "v30s", "v31s", "v32s", "v33s", "v34s", "v35s")):
    os.environ["LOCALAPPDATA"] = str(Path(tempfile.mkdtemp(prefix="v35s-local-")))

import s30pwork  # noqa: E402
import s35pwork  # noqa: E402
from v6checks import say  # noqa: E402

TMP = Path(tempfile.mkdtemp(prefix="v35s-"))
KEY = "check-key"


class Fake:
    """受け口の作り物"""

    def __init__(self, body=b"") -> None:
        data = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.rfile = io.BytesIO(data)
        self.headers = {"Content-Length": str(len(data))}
        self.sent: list = []
        self.discarded = False

    def send_json(self, status: int, body) -> None:
        self.sent = [status, body]

    def discard_body(self) -> None:
        self.discarded = True


class Spawns:
    def __init__(self) -> None:
        self.calls: list = []

    def __call__(self, script, python, base) -> None:
        self.calls.append((Path(script), Path(python), Path(base)))


def reset(spawns: Spawns | None) -> None:
    s30pwork.SPAWN = spawns
    s30pwork._last_kick[0] = float("-inf")


def mother(name: str, script: bool = True) -> Path:
    base = TMP / name
    base.mkdir(parents=True)
    if script:
        (base / "scripts").mkdir()
        (base / "scripts" / "Run-WorkNow.py").write_text("# 見本\n", encoding="utf-8")
    return base


def jpeg(n: int = 0, size: int = 64) -> bytes:
    """作りものの JPEG（頭の FF D8 と、番号ごとに違う中身）"""
    return b"\xff\xd8\xff\xe0" + bytes([n % 256]) * size + b"\xff\xd9"


def photo(ident: str, index: int, count: int, day: str = "2026-11-28", data: bytes | None = None, **more) -> dict:
    row = {"id": ident, "day": day, "index": index, "count": count,
           "jpeg_b64": base64.b64encode(data if data is not None else jpeg(index)).decode("ascii")}
    row.update(more)
    return row


def post(base: Path | None, body, logs: list | None = None) -> tuple:
    f = Fake(body)
    cfg = {"mothership_python": str(Path(sys.executable))}
    s35pwork.http_post(f, "/work/photo", cfg, base, (logs.append if logs is not None else None))
    return f.sent


def check_receive() -> int:
    failed = 0
    base = mother("receive")
    spawns = Spawns()
    reset(spawns)
    logs: list = []
    ident = str(uuid.uuid4()).upper()
    folder = base / s35pwork.INBOX / ident.lower()
    st, reply = post(base, photo(ident, 0, 3), logs)
    failed += say(st == 200 and reply == {"ok": True, "have": 1, "count": 3, "run": "waiting"} and not spawns.calls,
                  f"1/3 枚目: waiting で起こさない {reply}")
    failed += say((folder / "0.jpg").read_bytes() == jpeg(0), "1/3 枚目: <id>/0.jpg に中身のまま置く（id は小文字）")
    meta = json.loads((folder / "meta.json").read_text(encoding="utf-8"))
    failed += say(meta.get("id") == ident.lower() and meta.get("day") == "2026-11-28" and meta.get("count") == 3
                  and meta.get("received") == [0] and isinstance(meta.get("at"), str), f"meta.json の形 {meta}")
    # 順が入れ替わって届いても数える
    st, reply = post(base, photo(ident, 2, 3), logs)
    failed += say(reply == {"ok": True, "have": 2, "count": 3, "run": "waiting"}, "3 枚目が先に届いても数える")
    # 同じ番号を送り直しても二重に数えない
    st, reply = post(base, photo(ident, 2, 3, data=jpeg(9)), logs)
    failed += say(reply["have"] == 2 and (folder / "2.jpg").read_bytes() == jpeg(9), "同じ番号の送り直しは置き換え（二重に数えない）")
    failed += say(not spawns.calls, "そろうまでは起こさない")
    st, reply = post(base, photo(ident, 1, 3), logs)
    failed += say(st == 200 and reply == {"ok": True, "have": 3, "count": 3, "run": "started"} and len(spawns.calls) == 1,
                  f"そろったら起こす {reply}")
    call = spawns.calls[0] if spawns.calls else None
    failed += say(call is not None and call[0] == base / s30pwork.SCRIPT and call[2] == base,
                  "起こし: POST /work/digest と同じ（母艦の Run-WorkNow.py を母艦で）")
    meta = json.loads((folder / "meta.json").read_text(encoding="utf-8"))
    failed += say(meta.get("received") == [0, 1, 2], "meta.json の received は並べた番号")
    failed += say(not list(folder.glob(".*")) and not list(folder.glob("*.tmp")), "一時ファイルが残らない（入れ替えで置く）")
    # 二重起こしの抑え（POST /work/digest と同じ）
    st, reply = post(base, photo(ident, 0, 3), logs)
    failed += say(reply["run"] == "already" and len(spawns.calls) == 1, "そろったあとの送り直しは二重起こしの抑えで already")
    joined = "\n".join(logs)
    failed += say(bool(logs) and "jpeg" not in joined.lower() and base64.b64encode(jpeg(0)).decode() not in joined
                  and ident.lower() not in joined and ident.lower()[:8] in joined,
                  f"記録には id の頭 8 字と枚数だけ（{len(logs)} 行）")
    # count か day が変われば新しい組
    st, reply = post(base, photo(ident, 0, 2, day="2026-11-27"))
    failed += say(reply == {"ok": True, "have": 1, "count": 2, "run": "waiting"} and not (folder / "2.jpg").exists(),
                  f"同じ id で count・day が変われば数え直し、count 以上の番号は消す {reply}")
    # 1 枚だけのまとめ
    reset(Spawns())
    one = str(uuid.uuid4())
    st, reply = post(base, photo(one, 0, 1))
    failed += say(reply == {"ok": True, "have": 1, "count": 1, "run": "started"}, "1 枚だけならすぐ起こす")
    # Run-WorkNow.py が無い
    none = mother("noscript", script=False)
    reset(Spawns())
    st, reply = post(none, photo(str(uuid.uuid4()), 0, 1))
    failed += say(st == 200 and reply["run"] == "off" and reply["ok"] is True, "Run-WorkNow.py が無ければ off（写真は置く）")
    return failed


def check_validate() -> int:
    failed = 0
    base = mother("validate")
    spawns = Spawns()
    reset(spawns)
    ident = str(uuid.uuid4())
    big = b"\xff\xd8" + b"a" * (s35pwork.PHOTO_MAX_BYTES - 2)  # ちょうど 3MB
    bad = {
        "並びでない": [photo(ident, 0, 1)],
        "id が UUID でない": photo("not-a-uuid", 0, 1),
        "id が ../ を含む": photo("../../x", 0, 1),
        "day の形が違う": photo(ident, 0, 1, day="2026/11/28"),
        "day が無い日": photo(ident, 0, 1, day="2026-02-30"),
        "count が 0": photo(ident, 0, 0),
        "count が 13": photo(ident, 0, 13),
        "count が文字": dict(photo(ident, 0, 1), count="1"),
        "count が true": dict(photo(ident, 0, 1), count=True),
        "index がマイナス": photo(ident, -1, 2),
        "index が count と同じ": photo(ident, 2, 2),
        "index が小数": dict(photo(ident, 0, 2), index=0.5),
        "jpeg_b64 が無い": {"id": ident, "day": "2026-11-28", "index": 0, "count": 1},
        "jpeg_b64 が base64 でない": photo(ident, 0, 1, jpeg_b64="これは写真ではない"),
        "JPEG の頭でない": photo(ident, 0, 1, data=b"\x89PNG\r\n\x1a\n" + b"x" * 20),
        "3MB を超える": photo(ident, 0, 1, data=big + b"a"),
    }
    for label, body in bad.items():
        st, reply = post(base, body)
        failed += say(st == 400 and "error" in reply, f"検め: {label} は 400")
    inbox = base / s35pwork.INBOX
    failed += say(not inbox.exists() or not list(inbox.rglob("*")), "検め: 断ったときは何も書かない")
    failed += say(not spawns.calls, "検め: 断ったときは起こさない")
    f = Fake(b"{broken")
    s35pwork.http_post(f, "/work/photo", {}, base)
    failed += say(f.sent[0] == 400, "検め: 壊れた JSON は 400")
    f = Fake(b"")
    s35pwork.http_post(f, "/work/photo", {}, base)
    failed += say(f.sent[0] == 400 and f.discarded, "検め: 中身が無ければ 400")
    f = Fake(b"x")
    f.headers["Content-Length"] = str(s35pwork.BODY_MAX + 1)
    s35pwork.http_post(f, "/work/photo", {}, base)
    failed += say(f.sent[0] == 413 and f.discarded, "検め: 体が大きすぎれば 413（読まずに断る）")
    st, reply = post(base, photo(ident, 0, 12, data=big))
    failed += say(st == 200 and reply["count"] == 12 and reply["run"] == "waiting", "検め: ちょうど 3MB・count 12 は受ける")
    st, reply = post(base, photo(ident, 11, 12))
    failed += say(st == 200 and reply["have"] == 2, "検め: index 11（count 12）は受ける")
    return failed


def check_switch() -> int:
    failed = 0
    reset(Spawns())
    off = mother("switch")
    (off / "state").mkdir()
    (off / s30pwork.s27pwork.CONFIG).write_text(json.dumps({"s30p": {"push": False}}), encoding="utf-8")
    st, reply = post(off, photo(str(uuid.uuid4()), 0, 1))
    failed += say(st == 200 and reply == {"ok": False, "have": 0, "count": 0, "run": "off"} and not (off / s35pwork.INBOX).exists(),
                  "止める切り替え（s30p の push false）: 書かず off")
    failed += say(s35pwork.features(off) == [], "止める切り替え: features に workphoto を出さない")
    on = mother("features")
    failed += say(s35pwork.features(on) == ["workphoto"], "母艦があれば features に workphoto")
    failed += say(s35pwork.features(TMP / "nowhere") == [] and s35pwork.features(None) == [], "母艦が無ければ features に出さない")
    st, reply = post(None, photo(str(uuid.uuid4()), 0, 1))
    failed += say(st == 200 and reply["ok"] is False and reply["run"] == "off", "母艦が見つからなければ ok false・off")
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
    spawns = Spawns()
    reset(spawns)
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

        def call(method: str, path: str, body=None, key: str | None = KEY) -> tuple[int, dict]:
            data = json.dumps(body).encode("utf-8") if body is not None else None
            req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data, method=method)
            if data is not None:
                req.add_header("Content-Type", "application/json")
            if key is not None:
                req.add_header("Authorization", f"Bearer {key}")
            try:
                with urllib.request.urlopen(req, timeout=10) as r:
                    return r.status, json.loads(r.read().decode("utf-8"))
            except urllib.error.HTTPError as error:
                return error.code, json.loads(error.read().decode("utf-8") or "{}")

        ident = str(uuid.uuid4())
        for key in (None, "wrong"):
            st, _ = call("POST", "/work/photo", photo(ident, 0, 1), key)
            failed += say(st == 401, f"POST /work/photo: 鍵が{'無い' if key is None else '違う'}と 401")
        failed += say(not (base / s35pwork.INBOX).exists() and not spawns.calls, "401 のときは書かず・起こさない")
        st, reply = call("POST", "/work/photo", photo(ident, 0, 1))
        failed += say(st == 200 and reply == {"ok": True, "have": 1, "count": 1, "run": "started"}, f"POST /work/photo: 鍵が合えば受ける {reply}")
        st, reply = call("POST", "/work/photo", photo(ident, 0, 1, day="x"))
        failed += say(st == 400, "POST /work/photo: 形が違えば 400")
        st, reply = call("GET", "/hello")
        failed += say(st == 200 and "workphoto" in (reply.get("features") or []) and "workpush" in (reply.get("features") or []),
                      "features に workphoto（workpush と並んで）")
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
    failed += say("import s35pwork" in hub and "s35pwork.features(mothership.home(load_config()))" in hub
                  and "url.path in s35pwork.POSTS" in hub, "lifelog_pc.py: features・POST につないである")
    marker = "url.path in s35pwork.POSTS"
    failed += say(marker in hub and "self.authorized()" in hub[hub.index(marker):][:200], "lifelog_pc.py: POST /work/photo はオーナーの鍵の後ろ")
    import mothership

    failed += say(not set(s35pwork.POSTS) & (set(mothership.POSTS) | set(s30pwork.POSTS)), "ほかの口と道の名前がぶつからない")
    return failed


CHECKS = [check_receive, check_validate, check_switch, check_http, check_hub]


def run_all() -> int:
    failed = 0
    for check in CHECKS:
        try:
            failed += check()
        except Exception as error:  # noqa: BLE001 — 1 つが落ちても、ほかは確かめる
            import traceback

            traceback.print_exc()
            failed += say(False, f"{check.__name__} が途中で落ちました: {error!r}")
    return failed


def main() -> int:
    failed = run_all()
    print("ぜんぶ OK" if not failed else f"NG の数: {failed}", flush=True)
    return failed


if __name__ == "__main__":
    sys.exit(main())
