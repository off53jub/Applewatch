"""2026-11-27（s30。担当 p）: 家の PC の s30 の分を確かめる（K30-2 の POST /work/digest・GET /work/run・features "workpush"）。

    python pc/v30checks_s30p.py          （v29checks_s29p.py の最後にも呼ばれる。CI の手順を増やさずに動かすため）

本物の HOME・母艦・iPhone は使わない（一時フォルダに作り物の母艦を作る）。母艦のスクリプトは実際には起こさず、
s30pwork.SPAWN を差し替えて呼ばれ方だけ確かめる。見本の文はすべて作りもの。
"""

from __future__ import annotations

import datetime
import io
import json
import os
import subprocess
import sys
import tempfile
import threading
import urllib.error
import urllib.request
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

if not any(mark in os.environ.get("LOCALAPPDATA", "") for mark in ("v25s", "v26s", "v27s", "v30s")):
    os.environ["LOCALAPPDATA"] = str(Path(tempfile.mkdtemp(prefix="v30s-local-")))

import s30pwork  # noqa: E402
from v6checks import say  # noqa: E402

TMP = Path(tempfile.mkdtemp(prefix="v30s-"))
SAMPLE = "見本の仕事のまとめ（作りもの）"


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


def write(path: Path, body) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(body, ensure_ascii=False) if not isinstance(body, str) else body, encoding="utf-8")


def entry(**more) -> dict:
    row = {"id": str(uuid.uuid4()).upper(), "day": "2026-11-27", "text": SAMPLE,
           "sections": [{"title": "見出し", "body": "中身"}], "source": "photo", "addedAt": "2026-11-27T10:00:00+09:00"}
    row.update(more)
    return row


def mother(name: str, script: bool = True) -> Path:
    base = TMP / name
    base.mkdir(parents=True)
    if script:
        (base / "scripts").mkdir()
        (base / "scripts" / "Run-WorkNow.py").write_text("# 見本\n", encoding="utf-8")
    return base


class Spawns:
    def __init__(self) -> None:
        self.calls: list = []

    def __call__(self, script, python, base) -> None:
        self.calls.append((Path(script), Path(python), Path(base)))


def reset(spawns: Spawns | None) -> None:
    s30pwork.SPAWN = spawns
    s30pwork._last_kick[0] = float("-inf")


def post(base: Path | None, body, config: dict | None = None, logs: list | None = None) -> tuple:
    f = Fake(body)
    cfg = config if config is not None else {"mothership_python": str(Path(sys.executable))}
    s30pwork.http_post(f, "/work/digest", cfg, base, (logs.append if logs is not None else None))
    return f.sent


def check_receive() -> int:
    failed = 0
    base = mother("receive")
    spawns = Spawns()
    reset(spawns)
    logs: list = []
    a, b = entry(), entry(day="2026-11-26")
    st, reply = post(base, {"entries": [a, b]}, logs=logs)
    inbox = base / s30pwork.INBOX
    failed += say(st == 200 and reply == {"accepted": 2, "run": "started", "available": True} and len(list(inbox.glob("*.json"))) == 2,
                  f"POST: 2 件受けて 1 件 1 ファイルで書き、起こす {reply}")
    saved = json.loads((inbox / f"{a['id'].lower()}.json").read_text(encoding="utf-8"))
    failed += say(saved["text"] == SAMPLE and saved["day"] == a["day"] and saved["source"] == "photo" and saved["sections"] == a["sections"],
                  "POST: 書いた中身は体の 1 件のまま")
    failed += say(not list(inbox.glob(".*")) and not list(inbox.glob("*.tmp")), "POST: 一時ファイルが残らない（rename で原子的に置く）")
    call = spawns.calls[0] if spawns.calls else None
    failed += say(len(spawns.calls) == 1 and call[0] == base / s30pwork.SCRIPT and call[2] == base,
                  "起こし: 母艦の Run-WorkNow.py を母艦の作業フォルダで")
    failed += say(bool(logs) and not any(SAMPLE in m or "見出し" in m for m in logs), f"記録に文の中身を出さない（{len(logs)} 行）")
    # 二重送り: 同じ id は置き換えで 1 件
    reset(Spawns())
    st, reply = post(base, {"entries": [a]})
    failed += say(st == 200 and reply["accepted"] == 1 and len(list(inbox.glob("*.json"))) == 2, "POST: 同じ id を送り直しても 1 件")
    st, reply = post(base, {"entries": [dict(a), dict(a)]})
    failed += say(reply["accepted"] == 1, "POST: 1 回の中の同じ id は 1 件")
    return failed


def check_validate() -> int:
    failed = 0
    base = mother("validate")
    spawns = Spawns()
    reset(spawns)
    bad = {
        "entries が無い": {},
        "entries が空": {"entries": []},
        "entries が並びでない": {"entries": "x"},
        "51 件": {"entries": [entry() for _ in range(51)]},
        "id が UUID でない": {"entries": [entry(id="not-a-uuid")]},
        "id が ../ を含む": {"entries": [entry(id="../../x")]},
        "day の形が違う": {"entries": [entry(day="2026/11/27")]},
        "day が無い日": {"entries": [entry(day="2026-02-30")]},
        "text が文字でない": {"entries": [entry(text=123)]},
        "text が大きすぎ": {"entries": [entry(text="a" * (s30pwork.TEXT_MAX_BYTES + 1))]},
        "2 バイト以上の文字で大きすぎ": {"entries": [entry(text="あ" * (s30pwork.TEXT_MAX_BYTES // 3 + 1))]},
        "1 件が形違い": {"entries": [entry(), "x"]},
        "良い 1 件のあとに悪い 1 件": {"entries": [entry(), entry(day="x")]},
    }
    for label, body in bad.items():
        st, reply = post(base, body)
        failed += say(st == 400 and "error" in reply, f"検め: {label} は 400")
    inbox = base / s30pwork.INBOX
    failed += say(not inbox.exists() or not list(inbox.glob("*")), "検め: 断ったときは 1 件も書かない（半端に書かない）")
    failed += say(not spawns.calls, "検め: 断ったときは起こさない")
    f = Fake(b"{broken")
    s30pwork.http_post(f, "/work/digest", {}, base)
    failed += say(f.sent[0] == 400, "検め: 壊れた JSON は 400")
    f = Fake(b"")
    s30pwork.http_post(f, "/work/digest", {}, base)
    failed += say(f.sent[0] == 400 and f.discarded, "検め: 中身が無ければ 400")
    f = Fake(b"x")
    f.headers["Content-Length"] = str(s30pwork.BODY_MAX + 1)
    s30pwork.http_post(f, "/work/digest", {}, base)
    failed += say(f.sent[0] == 413 and f.discarded, "検め: 体が大きすぎれば 413（読まずに断る）")
    st, reply = post(base, {"entries": [entry(text="a" * s30pwork.TEXT_MAX_BYTES) for _ in range(3)]})
    failed += say(st == 200 and reply["accepted"] == 3, "検め: ちょうど 200 KB の text は受ける")
    st, reply = post(base, {"entries": [entry() for _ in range(50)]})
    failed += say(st == 200 and reply["accepted"] == 50, "検め: 50 件ちょうどは受ける")
    return failed


def check_kick() -> int:
    failed = 0
    base = mother("kick")
    spawns = Spawns()
    reset(spawns)
    cfg = {"mothership_python": str(Path(sys.executable))}
    now = datetime.datetime(2026, 11, 27, 12, 0, 0).astimezone()

    def ago(minutes: int) -> str:
        return (now - datetime.timedelta(minutes=minutes)).isoformat()

    s30pwork._last_kick[0] = -1e9   # 前の確かめ（本物の時刻で起こした HTTP の確かめなど）の印を消す
    write(base / s30pwork.STATE, {"state": "running", "started_at": ago(3), "finished_at": None, "ok": None})
    failed += say(s30pwork.kick(base, cfg, now, 1000.0) == "already" and not spawns.calls, "二重起こし: running で 3 分前なら already")
    write(base / s30pwork.STATE, {"state": "running", "started_at": ago(11), "finished_at": None, "ok": None})
    failed += say(s30pwork.kick(base, cfg, now, 2000.0) == "started" and len(spawns.calls) == 1, "二重起こし: running でも 11 分前なら起こし直す")
    failed += say(s30pwork.kick(base, cfg, now, 2005.0) == "already" and len(spawns.calls) == 1,
                  "二重起こし: 起こした直後の 5 秒後は already（状態のファイルがまだ無くても）")
    failed += say(s30pwork.kick(base, cfg, now, 2100.0) == "started" and len(spawns.calls) == 2, "二重起こし: 20 秒すぎれば起こせる")
    write(base / s30pwork.STATE, {"state": "idle", "started_at": ago(1), "finished_at": ago(0), "ok": True})
    failed += say(s30pwork.kick(base, cfg, now, 3000.0) == "started", "二重起こし: idle なら起こす")
    # POST 経由で already（running 3 分前）
    reset(Spawns())
    write(base / s30pwork.STATE, {"state": "running", "started_at": datetime.datetime.now().astimezone().isoformat()})
    st, reply = post(base, {"entries": [entry()]}, cfg)
    failed += say(reply.get("run") == "already" and reply.get("accepted") == 1, "POST: running なら already（ファイルは書く）")
    # Run-WorkNow.py が無い
    none = mother("kick-noscript", script=False)
    spawns2 = Spawns()
    reset(spawns2)
    st, reply = post(none, {"entries": [entry()]}, cfg)
    failed += say(st == 200 and reply == {"accepted": 1, "run": "off", "available": True} and not spawns2.calls
                  and len(list((none / s30pwork.INBOX).glob("*.json"))) == 1,
                  f"Run-WorkNow.py が無ければ off（ファイルは書く・起こさない） {reply}")
    # Python が無い
    reset(None)
    st, reply = post(base, {"entries": [entry()]}, {"mothership_python": str(TMP / "nowhere" / "python.exe")})
    failed += say(reply.get("run") == "off" and reply.get("accepted") == 1, "Python が見つからなければ off（ファイルは書く）")
    # 起こし方（窓なし・低い優先度・切り離し・母艦で）
    seen: dict = {}
    original = subprocess.Popen
    subprocess.Popen = lambda cmd, **kw: seen.update(cmd=cmd, **kw)  # type: ignore[assignment]
    try:
        s30pwork._spawn(base / "scripts" / "Run-WorkNow.py", Path("py.exe"), base)
    finally:
        subprocess.Popen = original  # type: ignore[assignment]
    want = (getattr(subprocess, "CREATE_NO_WINDOW", 0) | getattr(subprocess, "BELOW_NORMAL_PRIORITY_CLASS", 0)
            | getattr(subprocess, "DETACHED_PROCESS", 0)) if sys.platform == "win32" else 0
    failed += say(seen.get("cmd", [])[-1:] == ["--kick"] and seen.get("cwd") == str(base) and seen.get("creationflags") == want
                  and seen.get("stdin") == subprocess.DEVNULL, "起こし方: --kick・母艦の作業フォルダ・窓なし/低い優先度/切り離し・入出力なし")
    # 止める切り替え
    reset(Spawns())
    off = mother("switch")
    write(off / s30pwork.s27pwork.CONFIG, {"s30p": {"push": False}})
    st, reply = post(off, {"entries": [entry()]})
    failed += say(st == 200 and reply["run"] == "off" and reply["available"] is False and reply["accepted"] == 0
                  and not (off / s30pwork.INBOX).exists(), "止める切り替え: push false なら書かず off・available false")
    failed += say(s30pwork.features(off) == [], "止める切り替え: features に workpush を出さない")
    write(off / s30pwork.s27pwork.CONFIG, {"s27p": {"work": False}})
    failed += say(s30pwork.features(off) == ["workpush"], "切り替えが無ければオン（s27p の切り替えとは別）")
    failed += say(s30pwork.features(TMP / "nowhere") == [] and s30pwork.features(None) == [], "母艦が無ければ features に出さない")
    st, reply = post(None, {"entries": [entry()]})
    failed += say(st == 200 and reply["available"] is False, "母艦が見つからなければ available false")
    return failed


def check_run() -> int:
    failed = 0
    base = mother("run")
    f = Fake()
    s30pwork.http_get(f, "/work/run", base)
    failed += say(f.sent[1] == {"state": "idle", "started_at": None, "finished_at": None, "ok": None, "available": True},
                  "GET /work/run: 状態のファイルが無ければ idle")
    write(base / s30pwork.STATE, {"state": "running", "started_at": "2026-11-27T12:00:00+09:00", "finished_at": None, "ok": None, "extra": 1})
    f = Fake()
    s30pwork.http_get(f, "/work/run", base)
    failed += say(f.sent[1] == {"state": "running", "started_at": "2026-11-27T12:00:00+09:00", "finished_at": None, "ok": None,
                                "available": True}, "GET /work/run: running を返す（余計な欄は返さない）")
    write(base / s30pwork.STATE, {"state": "idle", "started_at": "2026-11-27T12:00:00+09:00",
                                  "finished_at": "2026-11-27T12:02:00+09:00", "ok": False})
    f = Fake()
    s30pwork.http_get(f, "/work/run", base)
    failed += say(f.sent[1]["state"] == "idle" and f.sent[1]["ok"] is False and f.sent[1]["finished_at"].startswith("2026-11-27T12:02"),
                  "GET /work/run: 終わった状態（ok false）")
    write(base / s30pwork.STATE, "{壊れた")
    f = Fake()
    s30pwork.http_get(f, "/work/run", base)
    failed += say(f.sent[1]["state"] == "idle" and f.sent[1]["available"] is True, "GET /work/run: 壊れていれば idle")
    write(base / s30pwork.STATE, {"state": "running", "started_at": "でたらめ", "ok": "yes"})
    f = Fake()
    s30pwork.http_get(f, "/work/run", base)
    failed += say(f.sent[1]["started_at"] is None and f.sent[1]["ok"] is None, "GET /work/run: 時刻や ok の形が違えば null")
    f = Fake()
    s30pwork.http_get(f, "/work/run", None)
    failed += say(f.sent[1]["available"] is False and f.sent[1]["state"] == "idle", "GET /work/run: 母艦が見つからなければ available false")
    return failed


def check_http() -> int:
    """本物の受け口（lifelog_pc.Handler）に HTTP でつなぐ: 鍵が無い・違うと 401、合っていれば受ける。
    この PC に lifelog_pc.py の部品が無くて import で落ちるときは、そう言って飛ばす"""
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
        main.Handler.key = "check-key"
        if not had_engine:
            main.Handler.engine = type("FakeEngine", (), {"label": "check", "provider": "check", "engines": []})()
        main.log = lambda message: None
        main.load_config = lambda: {"lifelog_home": str(base), "mothership_python": str(Path(sys.executable))}
        server = main.Server(("127.0.0.1", 0), main.Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        port = server.server_address[1]

        def call(method: str, path: str, body=None, key: str | None = "check-key") -> tuple[int, dict]:
            data = json.dumps(body, ensure_ascii=False).encode("utf-8") if body is not None else None
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

        payload = {"entries": [entry()]}
        for key in (None, "wrong"):
            label = "無い" if key is None else "違う"
            st, _ = call("POST", "/work/digest", payload, key)
            failed += say(st == 401, f"POST /work/digest: 鍵が{label}と 401")
            st, _ = call("GET", "/work/run", None, key)
            failed += say(st == 401, f"GET /work/run: 鍵が{label}と 401")
        failed += say(not (base / s30pwork.INBOX).exists() and not spawns.calls, "401 のときは書かず・起こさない")
        st, reply = call("POST", "/work/digest", payload)
        failed += say(st == 200 and reply.get("accepted") == 1 and reply.get("run") == "started", f"POST /work/digest: 鍵が合えば受ける {reply}")
        st, reply = call("GET", "/work/run")
        failed += say(st == 200 and reply.get("state") == "idle" and reply.get("available") is True, "GET /work/run: 鍵が合えば返す")
        st, reply = call("GET", "/hello")
        failed += say(st == 200 and "workpush" in (reply.get("features") or []), "features に workpush")
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
    text = (Path(__file__).resolve().parent / "lifelog_pc.py").read_text(encoding="utf-8")
    failed += say("import s30pwork" in text and "s30pwork.features(mothership.home(load_config()))" in text
                  and "path in s30pwork.GETS" in text and "path in s30pwork.POSTS" in text,
                  "lifelog_pc.py: features・GET・POST につないである")
    for marker in ("path in s30pwork.GETS", "url.path in s30pwork.POSTS"):
        failed += say("self.authorized()" in text[text.index(marker):][:200], f"lifelog_pc.py: {marker} はオーナーの鍵の後ろ")
    import mothership
    import s27pwork

    failed += say(not set(s30pwork.GETS) & (set(mothership.GETS) | set(s27pwork.GETS))
                  and not set(s30pwork.POSTS) & set(mothership.POSTS), "ほかの口と道の名前がぶつからない")
    return failed


CHECKS = [check_receive, check_validate, check_kick, check_run, check_http, check_hub]


def run_all() -> int:
    failed = 0
    for check in CHECKS:
        try:
            failed += check()
        except Exception as error:  # noqa: BLE001 — 1 つが落ちても、ほかは確かめる
            import traceback

            traceback.print_exc()
            failed += say(False, f"{check.__name__} が途中で落ちました: {error!r}")
    # s31（2026-11-27。担当 p）の確かめも続けて（CI の手順を増やさないため）
    import v31checks_s31p

    failed += v31checks_s31p.run_all()
    return failed


def main() -> int:
    failed = run_all()
    print("ぜんぶ OK" if not failed else f"NG の数: {failed}", flush=True)
    return failed


if __name__ == "__main__":
    sys.exit(main())
