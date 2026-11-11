"""LifeLog PC 版 10（時計の外の道）を確かめる（--check-v10 から呼ぶ。本物のモデル・本物の Tailscale・ふだんの置き場所は使わない）。

- Tailscale Funnel の様子の読み方（serve status --json の形。作り物の JSON で）
- 時計の外の道: 時計の合言葉（HOME/watch-token.txt）・GET /w/ping・ほかは全部 404・名前の形・8MB まで・待ち合わせをしない・
  "origin": "watch"・GET /jobs?origin=watch・あとから iPhone が同じ名前を送っても（wait=1 でも）2つにならない・
  10 分に 10 回違えば 429・番号が使われていても止まらない・記録に時計の合言葉を書かない
- ふだんの受け口の GET /watch-route（合言葉・形・Funnel の様子を覚えておく）と /hello の features、見守りの画面
- 時計から預かった仕事も、でき上がりで「できた」の見えない通知（仕事の名前つき）を送る
- 母艦のやること（2026-11-09）: 無いときは available=false・形の違うものは読まない・済みの id の形・同じ日の同じ id は1行だけ
- 仕事のまとめ（2026-11-10）: 「仕事のまとめ.json」の読み方（見出し・まとめが無いときの生の文・同じ日の同じ行は1回・読むだけ）・
  意味で探すに置く（kind が work-digest・時刻なし・既定では出ない・変わったときだけ置き直す・無くなった行は消す）・
  MCP の search_digest・get_digest と、search_text・search_meaning の digest_hits（hits の形は変えない）
番号はどれも空いているもの（127.0.0.1 の 0 番）を使う。確かめるときは、本物の HOME に書かない（isolate_home）。
"""

from __future__ import annotations

import json
import os
import socket
import tempfile
import threading
import time
from pathlib import Path

import dashboard
import jobqueue
import mothership
import ops
import watchroute
import lifelog_mcp
import semantic
from v6checks import KEY, Client, say
from v8checks import raw_post, wait_until

HOST = "desktop-test.tail0000.ts.net"


def run(main) -> int:
    main.isolate_home()
    failed = 0
    failed += check_isolated(main)
    failed += check_funnel_parse()
    failed += check_routes(main)
    failed += check_push()
    failed += check_mothership()
    failed += check_card()
    failed += check_vocab()
    failed += check_digest()
    print(("NG の数: " + str(failed)) if failed else "版 10: 全部 OK", flush=True)
    return failed


def check_isolated(main) -> int:
    home = Path(main.HOME)
    ok = main._isolated is not None and home.is_relative_to(main._isolated) and home != Path(main._START_HOME) \
        and os.environ.get("LOCALAPPDATA") == str(main._isolated)
    return say(ok, f"確かめるときは、HOME を一時のフォルダに替える（{home.name}）")


# MARK: - Funnel の様子の読み方


def serve_config(host: str, proxy: str, allow: bool = True, port: str = "443") -> dict:
    """`tailscale serve status --json` の形（2026-11-07 にこの PC で Funnel をオンにしたときの答えと同じ形）"""
    key = f"{host}:{port}"
    return {"TCP": {port: {"HTTPS": True}}, "Web": {key: {"Handlers": {"/": {"Proxy": proxy}}}},
            "AllowFunnel": {key: allow}}


def check_funnel_parse() -> int:
    failed = 0
    port = 47617
    real = {"TCP": {"443": {"HTTPS": True}},
            "Web": {"desktop-7ki97gp.tail997110.ts.net:443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:47617"}}}},
            "AllowFunnel": {"desktop-7ki97gp.tail997110.ts.net:443": True}}
    cases = [
        ("この PC の本当の形", real, "desktop-7ki97gp.tail997110.ts.net"),
        ("localhost:番号", serve_config(HOST, "localhost:47617"), HOST),
        ("番号だけ", serve_config(HOST, "47617"), HOST),
        ("http://localhost:番号/", serve_config(HOST, "http://localhost:47617/"), HOST),
        ("名前の末尾の点は取る", serve_config(HOST + ".", "http://127.0.0.1:47617"), HOST),
        ("Funnel がオフ（tailnet の中だけ）", serve_config(HOST, "http://127.0.0.1:47617", allow=False), None),
        ("AllowFunnel が無い", {"TCP": {"443": {"HTTPS": True}},
                               "Web": {f"{HOST}:443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:47617"}}}}}, None),
        ("ほかの番号に向いている", serve_config(HOST, "http://127.0.0.1:47615"), None),
        ("https に向いている", serve_config(HOST, "https://127.0.0.1:47617"), None),
        ("この PC の外に向いている", serve_config(HOST, "http://192.168.1.20:47617"), None),
        ("443 でない（8443）", serve_config(HOST, "http://127.0.0.1:47617", port="8443"), None),
        ("前で動かしている funnel（Foreground）", {"Foreground": {"abc": serve_config(HOST, "http://127.0.0.1:47617")}},
         HOST),
        ("空の設定", {}, None),
        ("壊れた答え", ["x"], None),
    ]
    wrong = [(label, watchroute.funnel_host(config, port), want) for label, config, want in cases
             if watchroute.funnel_host(config, port) != want]
    failed += say(not wrong, f"Funnel の様子の読み方（{len(cases)} 通り）" + (f": 違う {wrong}" if wrong else ""))
    return failed


# MARK: - 時計の外の道と、ふだんの受け口


def raw(port: int, method: str, path: str, token: str | None = None, body: bytes = b"",
        length: int | None = None, timeout: float = 30.0) -> tuple[int, bytes, float]:
    """見出しの Content-Length を好きに書いて送る（大きすぎる音声を、中身を送らずに試す）"""
    sock = socket.create_connection(("127.0.0.1", port), timeout=timeout)
    started = time.time()
    auth = f"Authorization: Bearer {token}\r\n" if token is not None else ""
    head = (f"{method} {path} HTTP/1.1\r\nHost: 127.0.0.1\r\n{auth}"
            f"Content-Length: {len(body) if length is None else length}\r\n\r\n").encode("ascii")
    data = b""
    try:
        sock.sendall(head + body)
        # 送るのはここまで（中身が見出しの長さより短くても、PC が読み捨てるのを待たせない）
        sock.shutdown(socket.SHUT_WR)
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            data += chunk
    except OSError:
        pass
    finally:
        sock.close()
    header, _, rest = data.partition(b"\r\n\r\n")
    status = int(header.split(b" ")[1]) if header.startswith(b"HTTP/") else 0
    return status, rest, time.time() - started


def check_routes(main) -> int:
    failed = 0
    logged: list[str] = []
    gates: dict[str, threading.Event] = {}
    notified: list[tuple[str, str | None, bool]] = []
    status_box: dict = {"config": {}, "calls": 0}

    def runner(path, params, name, draft):
        gate = gates.get(name)
        if gate is not None:
            gate.wait(20)
        return {"lines": [{"start": 0.0, "end": 1.0, "text": "でき上がり"}], "seconds": 0.1}, {"audio_seconds": 1.0}

    def status():
        status_box["calls"] += 1
        return status_box["config"]

    saved = (main.App.jobs, getattr(main.Handler, "engine", None), getattr(main.Handler, "key", None), main.log,
             watchroute.W.status, watchroute.W.clock, watchroute.W.funnel_cache)
    server = None
    try:
        main.log = logged.append
        main.Handler.key = KEY
        main.Handler.engine = main.Ensemble(ops.fake_engines())
        main.App.jobs = queue = jobqueue.JobQueue(Path(main.HOME) / "jobs-v10", runner, logged.append)
        queue.on_done = lambda name, meta: notified.append((name, meta.get("origin"), bool(meta.get("handed"))))
        queue.start()
        server = main.Server(("127.0.0.1", 0), main.Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        port = server.server_address[1]
        home_client = Client(port)
        watchroute.W.status = status
        watchroute.W.funnel_cache = None
        watchroute.W.fails.clear()
        watchroute.W.locked_until = 0.0
        before = "watchroute" in main.features()

        # 1. 時計の合言葉と、受け口を始める
        started = watchroute.start(main, 0)
        wport = watchroute.W.port
        token_path = Path(main.HOME) / watchroute.TOKEN_FILE
        token = token_path.read_text(encoding="utf-8").strip() if token_path.exists() else ""
        ok = started and bool(wport) and token == watchroute.W.token and len(token) >= 40 and token != KEY \
            and watchroute.token(main.HOME) == token and not before and "watchroute" in main.features()
        failed += say(ok, f"時計の合言葉を HOME/{watchroute.TOKEN_FILE} に作り（{len(token)} 文字・2 回目も同じ）、"
                          f"127.0.0.1 の空いている番号で待つ。features に watchroute（始める前は無い）")
        watch = Client(wport)

        # 2. GET /w/ping
        good = watch.call("GET", "/w/ping", key=token)
        bad = watch.call("GET", "/w/ping", key="wrong-token")
        none = watch.call("GET", "/w/ping", key=None)
        main_key = watch.call("GET", "/w/ping", key=KEY)
        ok = good[0] == 200 and good[1] == {"ok": True} and bad[0] == 401 and none[0] == 401 and main_key[0] == 401 \
            and good[2].get("cache-control") == "no-store"
        failed += say(ok, f"GET /w/ping: 時計の合言葉なら 200 {good[1]}、違う・無い・ふだんの合言葉なら 401"
                          f"（{bad[0]}・{none[0]}・{main_key[0]}）")

        # 3. ほかは全部 404（時計の合言葉があっても）
        tried = [("GET", "/dash"), ("GET", "/dash/records"), ("GET", "/records"), ("GET", "/records/2026-11-07"),
                 ("GET", "/jobs"), ("GET", "/jobs/x.m4a"), ("GET", "/hello"), ("GET", "/watch-route"), ("GET", "/"),
                 ("GET", "/w/jobs"), ("POST", "/w/ping"), ("POST", "/jobs?name=20261107-135444-w.m4a"),
                 ("POST", "/transcribe"), ("POST", "/dash/restart"), ("DELETE", "/jobs/x.m4a"), ("PUT", "/w/jobs")]
        answers = {f"{m} {p}": watch.call(m, p, b"x" if m in ("POST", "PUT") else None, key=token) for m, p in tried}
        wrong = {k: v[0] for k, v in answers.items() if v[0] != 404 or v[1] != {"error": "not found"}}
        tiny = raw(wport, "GET", "/dash", token)
        ok = not wrong and tiny[0] == 404 and len(tiny[1]) < 64 and not queue.jobs
        failed += say(ok, f"時計の外の道では /w/ping・/w/jobs のほかは全部 404（{len(tried)} 通り。中身は {len(tiny[1])} バイト）"
                          + (f": 違う {wrong}" if wrong else ""))

        # 4. 名前の形
        names = ["foo.m4a", "20261107-135444.m4a", "20261107-135444-w.wav", "20261107-1354-w.m4a", "../x-w.m4a",
                 "2026110-135444-w.m4a", ""]
        codes = [watch.call("POST", f"/w/jobs?name={n}", b"audio", key=token)[0] for n in names]
        ok = all(c == 400 for c in codes) and not queue.jobs
        failed += say(ok, f"名前は 年月日-時分秒…-w.m4a の形だけ（ほかは 400: {codes}）")

        # 5. 8MB まで
        limit = jobqueue.WATCH_BODY_LIMIT
        big = raw(wport, "POST", "/w/jobs?name=20261107-100000-w.m4a", token, length=limit + 1)
        full_name = "20261107-100500-w.m4a"
        full = watch.call("POST", f"/w/jobs?name={full_name}", b"a" * limit, key=token)
        ok = big[0] == 413 and "20261107-100000-w.m4a" not in queue.jobs and full[0] == 200 \
            and (queue.jobs.get(full_name) or {}).get("size") == limit
        failed += say(ok, f"8MB（{limit} バイト）までは預かり、1 バイトでも大きければ 413（{big[0]}・{full[0]}）")

        # 6. 待ち合わせをしない・origin を付ける・時刻を残す
        n1 = "20261107-135444-w.m4a"
        gates[n1] = threading.Event()
        stamp = "2026-11-07T04:54:44.000Z"
        began = time.time()
        stored = watch.call("POST", f"/w/jobs?name={n1}&wait=1&chunk_start={stamp}&chunk_end={stamp}&sent={stamp}"
                                    "&hints=%E3%83%92%E3%83%9F%E3%83%84", b"audio-1", key=token)
        took = time.time() - began
        wait_until(lambda: (queue.jobs.get(n1) or {}).get("status") == "working", 5)
        meta = dict(queue.jobs.get(n1) or {})
        ok = stored[0] == 200 and stored[1] == {"id": n1, "status": "queued"} and took < 2.0 \
            and n1 not in queue.waiters and meta.get("origin") == "watch" and "chunk_end" in (meta.get("times") or {}) \
            and any(f"時計から（外の道） {n1}: " in line and "を預かりました" in line for line in logged) \
            and not any("ヒミツ" in line for line in logged)
        failed += say(ok, f"POST /w/jobs: wait=1 でも待たずに答え（{took:.2f} 秒・{stored[1]}）、origin watch と時刻を残し、"
                          "記録に「時計から（外の道）」と書く（ヒントは書かない）")

        # 7. あとから iPhone が同じ名前を送っても（wait なし）、2つにならない
        seq = meta.get("seq")
        phone = home_client.call("POST", f"/jobs?name={n1}", b"audio-from-phone")
        ok = phone[0] == 200 and phone[1] == {"id": n1, "status": "working"} and queue.jobs[n1].get("seq") == seq \
            and queue.jobs[n1].get("origin") == "watch" and queue.jobs[n1].get("size") == len(b"audio-1")
        failed += say(ok, f"あとから iPhone が同じ名前を POST /jobs で送っても、預かっている仕事の様子を返すだけ（{phone[1]}）")

        # 8. iPhone が wait=1 で送ると、預かっている仕事のでき上がりを待って答え、渡したので通知しない
        box: dict = {}
        thread = threading.Thread(target=lambda: box.update(raw_post(port, f"/jobs?name={n1}&wait=1", b"audio-again")),
                                  daemon=True)
        thread.start()
        entered = wait_until(lambda: n1 in queue.waiters, 5)
        gates[n1].set()
        thread.join(15)
        answer = box.get("answer") or {}
        time.sleep(0.3)
        ok = entered and box.get("status") == 200 and answer.get("status") == "done" \
            and (answer.get("result") or {}).get("lines", [{}])[0].get("text") == "でき上がり" \
            and answer.get("origin") == "watch" and queue.jobs[n1].get("seq") == seq and queue.jobs[n1].get("handed") is True \
            and not any(n == n1 for n, _, _ in notified)
        failed += say(ok, f"iPhone が同じ名前を wait=1 で送ると、時計から預かった仕事のでき上がりで答え（{answer.get('status')}）、"
                          "渡したので「できた」の通知はしない")

        # 9. 時計から預かって、だれも待っていなかった仕事は、でき上がりで通知の口（on_done）を呼ぶ
        n2 = "20261107-140000-w.m4a"
        watch.call("POST", f"/w/jobs?name={n2}", b"audio-2", key=token)
        wait_until(lambda: any(n == n2 for n, _, _ in notified), 5)
        ok = (n2, "watch", False) in notified
        failed += say(ok, f"時計から預かって渡せなかった仕事は、でき上がりで「できた」の通知の口を呼ぶ {[x for x in notified]}")

        # 10. 時計から同じ名前をもう一度送っても、2つにならない
        again = watch.call("POST", f"/w/jobs?name={n2}", b"audio-2-again", key=token)
        ok = again[0] == 200 and again[1].get("id") == n2 and again[1].get("status") == "done" \
            and any(f"時計から（外の道） {n2}: もう預かっています" in line for line in logged)
        failed += say(ok, f"時計から同じ名前をもう一度送っても、預かっている仕事の様子を返すだけ（{again[1]}）")

        # 11. GET /jobs?origin=watch と、ふだんの GET /jobs
        home_client.call("POST", "/jobs?name=phone-only.m4a", b"audio-phone")
        wait_until(lambda: (queue.jobs.get("phone-only.m4a") or {}).get("status") == "done", 5)
        only = home_client.call("GET", "/jobs?origin=watch")
        plain = home_client.call("GET", "/jobs")
        one = home_client.call("GET", f"/jobs/{n1}")
        listed = [j.get("id") for j in (only[1] or {}).get("jobs", [])] if only[0] == 200 else []
        everything = {j.get("id"): j for j in (plain[1] or {}).get("jobs", [])} if plain[0] == 200 else {}
        phone_job = everything.get("phone-only.m4a") or {}
        ok = listed == [n2, n1, full_name] \
            and all(j.get("origin") == "watch" for j in only[1]["jobs"]) \
            and set(phone_job) == {"id", "status", "queued_at", "done_at"} \
            and (everything.get(n1) or {}).get("origin") == "watch" and len(everything) == 4 \
            and one[0] == 200 and one[1].get("origin") == "watch"
        failed += say(ok, f"GET /jobs?origin=watch は時計から預かった仕事だけ（新しい順 {listed}）。ふだんの GET /jobs は "
                          "origin が付くだけで、iPhone の仕事の形は今までどおり")

        # 12. GET /watch-route（ふだんの合言葉）
        no_key = home_client.call("GET", "/watch-route", key=None)
        wrong_key = home_client.call("GET", "/watch-route", key="wrong")
        with_token = home_client.call("GET", "/watch-route", key=token)
        off = home_client.call("GET", "/watch-route")
        body = off[1] if isinstance(off[1], dict) else {}
        ok = no_key[0] == 401 and wrong_key[0] == 401 and with_token[0] == 401 and off[0] == 200 \
            and set(body) == {"url", "token", "funnel", "port"} and body.get("token") == token \
            and body.get("port") == wport and body.get("funnel") is False and body.get("url") is None \
            and off[2].get("cache-control") == "no-store"
        failed += say(ok, f"GET /watch-route: ふだんの合言葉でだけ答え（無い・違う・時計の合言葉は 401）、"
                          f"Funnel がオフなら url は null（{ {k: v for k, v in body.items() if k != 'token'} }）")
        status_box["config"] = serve_config(HOST, f"http://127.0.0.1:{wport}")
        watchroute.W.funnel_cache = None
        calls = status_box["calls"]
        on = home_client.call("GET", "/watch-route")
        status_box["config"] = {}
        cached = home_client.call("GET", "/watch-route")
        ok = on[0] == 200 and on[1].get("funnel") is True and on[1].get("url") == f"https://{HOST}" \
            and cached[1].get("funnel") is True and status_box["calls"] == calls + 1
        failed += say(ok, f"Funnel がこの受け口に向いていれば funnel true・url {on[1].get('url')}。"
                          f"様子は {watchroute.FUNNEL_CACHE:.0f} 秒覚えておく（読んだ回数 {status_box['calls'] - calls}）")
        hello = home_client.call("GET", "/hello")
        ok = hello[0] == 200 and "watchroute" in (hello[1].get("features") or []) and hello[1].get("version") == main.VERSION
        failed += say(ok, f"/hello: 版 {hello[1].get('version')}・features に watchroute")

        # 13. 見守りの画面（時計の合言葉は出さない）
        info = watchroute.dash_info()
        page = dashboard.render({"version": main.VERSION, "watch": info})
        ok = info.get("listening") is True and info.get("funnel") is True and info.get("today") == 3 \
            and info.get("locked") is False and "時計の外の道" in page and "今日預かった区切り" in page \
            and token not in page and token not in json.dumps(info) and "token" not in info
        failed += say(ok, f"見守りの画面の「時計の外の道」: 受け口・Funnel・今日預かった数 {info.get('today')}・断っているか"
                          "（時計の合言葉は出さない）")

        # 14. 番号が使われていても止まらない
        taken = watchroute.start(main, wport)
        ok = taken is False and watchroute.running() and watchroute.W.port == wport \
            and any("ほかのソフトが使っている" in line for line in logged) \
            and watch.call("GET", "/w/ping", key=token)[0] == 200
        failed += say(ok, "番号がほかに使われていれば、記録に書いて、時計の外の道は無しで続ける")

        # 15. 10 分に 10 回違えば、10 分のあいだ、だれにも 429
        watchroute.W.fails.clear()
        wrongs = [watch.call("GET", "/w/ping", key=f"wrong-{i}")[0] for i in range(10)]
        blocked = watch.call("GET", "/w/ping", key=token)
        blocked_post = watch.call("POST", f"/w/jobs?name=20261107-141000-w.m4a", b"audio", key=token)
        blocked_other = watch.call("GET", "/dash", key=token)
        more = [watch.call("GET", "/w/ping", key="wrong")[0] for _ in range(3)]
        lock_lines = [line for line in logged if "だれからも受け付けません" in line]
        locked_info = watchroute.dash_info()
        page = dashboard.render({"version": main.VERSION, "watch": locked_info})
        real_clock = watchroute.W.clock
        watchroute.W.clock = lambda: real_clock() + watchroute.LOCK_SECONDS + 1
        after = watch.call("GET", "/w/ping", key=token)
        watchroute.W.clock = real_clock
        ok = wrongs == [401] * 10 and blocked[0] == 429 and blocked[2].get("retry-after") == "600" \
            and blocked_post[0] == 429 and blocked_other[0] == 429 and more == [429] * 3 and len(lock_lines) == 1 \
            and "20261107-141000-w.m4a" not in queue.jobs and locked_info.get("locked") is True \
            and "だれからも受け付けません" in page and after[0] == 200
        failed += say(ok, f"合言葉が 10 回違うと、正しい合言葉でも 429（{blocked[0]}・{blocked_post[0]}・{blocked_other[0]}）。"
                          f"記録には始めたときに 1 回だけ（{len(lock_lines)} 行）。10 分たてば戻る（{after[0]}）")
        watchroute.W.locked_until = 0.0
        watchroute.W.fails.clear()

        # 16. 記録に時計の合言葉を書かない
        ok = bool(logged) and not any(token in line for line in logged)
        failed += say(ok, f"記録（{len(logged)} 行）に時計の合言葉を書かない")

        # 17. 止めると features から消え、GET /watch-route は 503
        watchroute.stop()
        gone = home_client.call("GET", "/watch-route")
        ok = "watchroute" not in main.features() and gone[0] == 503 and not watchroute.running()
        failed += say(ok, f"時計の外の道が動いていなければ、features に watchroute は無く、GET /watch-route は {gone[0]}")
    finally:
        for gate in gates.values():
            gate.set()
        watchroute.stop()
        if server is not None:
            server.shutdown()
            server.server_close()
        engine = getattr(main.Handler, "engine", None)
        pool = getattr(engine, "pool", None)
        if pool is not None:
            pool.shutdown(wait=False)
        (main.App.jobs, main.Handler.engine, main.Handler.key, main.log, watchroute.W.status, watchroute.W.clock,
         watchroute.W.funnel_cache) = saved
    return failed


# MARK: - 見えない通知


def check_push() -> int:
    """ops.job_done は、時計から預かった仕事（送ってきた iPhone の宛先が無い）にも、名前つきで job の通知を送る"""

    class Pusher:
        def __init__(self) -> None:
            self.sent: list = []

        def ready(self) -> bool:
            return True

        def usable(self, device) -> bool:
            return True

        def send(self, kind, devices=None, job=None):
            self.sent.append((kind, devices, job))
            return [{"ok": True}]

    class Diag:
        def device_for_ip(self, ip):
            return None

    names = ("started", "pusher", "diag", "home", "job_ip")
    saved = {n: getattr(ops.O, n, None) for n in names}
    pusher = Pusher()
    name = "20261107-135444-w.m4a"
    with tempfile.TemporaryDirectory() as folder:
        try:
            ops.O.started, ops.O.pusher, ops.O.diag, ops.O.home = True, pusher, Diag(), Path(folder)
            ops.O.job_ip = {}
            ops.job_done("20261107-130000-w.m4a", {"status": "done", "origin": "watch", "handed": True})
            ops.job_done(name, {"status": "done", "origin": "watch"})
            wait_until(lambda: pusher.sent, 3)
            time.sleep(0.2)
        finally:
            for n, v in saved.items():
                setattr(ops.O, n, v)
    return say(pusher.sent == [("job", None, name)],
               f"見えない通知: 時計から預かった仕事も、でき上がりで名前つきの job を送る（渡したものには送らない） {pusher.sent}")


# MARK: - 母艦のやること（2026-11-09）

def check_mothership() -> int:
    failed = 0
    with tempfile.TemporaryDirectory() as folder:
        base = Path(folder)
        config = {"lifelog_home": folder}
        failed += say(mothership.home(config) == base and mothership.home({}) == mothership.DEFAULT_HOME,
                      "母艦の場所: config.json の lifelog_home、無ければ D:\\Lifelog")
        failed += say(mothership.read_export(base).get("available") is False, "母艦のやること: 無いときは available=false")
        (base / "state").mkdir()
        (base / "state" / "todo_for_app.json").write_text('{"items": "x"}', encoding="utf-8")
        failed += say(mothership.read_export(base).get("available") is False, "母艦のやること: 形の違うものは読まない")
        export = {"generated_at": "2026-11-09T07:05:00+09:00",
                  "today_three": [{"id": "0123456789ab", "text": "資料を送る", "why": "期限が今日"}],
                  "items": [{"id": "0123456789ab", "text": "資料を送る", "project": "", "work": True,
                             "added": "2026-11-01", "due": "2026-11-09", "source": "x"}]}
        # 母艦が BOM 付きで書いても読める
        (base / "state" / "todo_for_app.json").write_text(json.dumps(export, ensure_ascii=False), encoding="utf-8-sig")
        got = mothership.read_export(base)
        failed += say(got.get("available") is True and len(got.get("items", [])) == 1
                      and got["today_three"][0]["id"] == "0123456789ab", "母艦のやること: そのまま返す")
        bad = 0
        for body in (b"x", b"[]", b'{"id": "XYZ"}', b'{"id": "0123456789abc"}'):
            try:
                mothership.parse_done(body)
            except ValueError:
                bad += 1
        failed += say(bad == 4, "母艦のやることの済み: id は12文字の16進だけ")
        item = mothership.parse_done('{"id": "0123456789AB", "text": "資料を送る"}'.encode("utf-8"))
        now = time.mktime((2026, 11, 9, 8, 0, 0, 0, 0, -1))
        path = mothership.append_done(base, item, now=now)
        mothership.append_done(base, item, now=now + 60)
        lines = path.read_text(encoding="utf-8").splitlines()
        failed += say(path.name == "2026-11-09.jsonl" and len(lines) == 1
                      and json.loads(lines[0])["id"] == "0123456789ab",
                      f"母艦のやることの済み: 日ごとの jsonl に1行（同じ日の同じ id は1回だけ） {path.name} {len(lines)}")
        failed += say("kind" not in json.loads(lines[0]), "母艦のやることの済み: done は前と同じ形（kind を書かない）")
        wrong = mothership.parse_done(b'{"id": "0123456789ab", "text": "x", "kind": "wrong"}')
        mothership.append_done(base, wrong, now=now + 120)
        mothership.append_done(base, wrong, now=now + 180)
        lines = path.read_text(encoding="utf-8").splitlines()
        failed += say(len(lines) == 2 and json.loads(lines[1]).get("kind") == "wrong",
                      f"母艦のやることの「違う」: kind を付けて1行（同じ id でも済みとは別に数える） {len(lines)}")
        try:
            mothership.parse_done(b'{"id": "0123456789ab", "kind": "delete"}')
            failed += say(False, "母艦のやること: 知らない kind は受けない")
        except ValueError:
            failed += say(True, "母艦のやること: 知らない kind は受けない")
    return failed


# MARK: - カードの利用速報（2026-11-09）

def check_card() -> int:
    failed = 0
    failed += say(mothership.read_card(None).get("available") is False, "カードの利用速報: ファイルが無いときは available=false")
    with tempfile.TemporaryDirectory() as folder:
        path = Path(folder) / "card-mail.json"
        failed += say(mothership.card_file({"card_mail_file": str(path)}) == path, "カードの利用速報: config.json の card_mail_file")
        path.write_text('{"items": "x"}', encoding="utf-8")
        failed += say(mothership.read_card(path).get("available") is False, "カードの利用速報: 形の違うものは読まない")
        data = {"generated_at": "2026-11-09T07:00:00+09:00", "items": [
            {"id": "19a0b1c2d3e4f5a6", "time": "2026-10-20T07:10:00+09:00", "amount": 35000, "shop": "テスト銀行",
             "card": "PayPayカード ゴールド（Visa）"},
            {"id": "bad id!", "time": "2026-10-20T07:10:00+09:00", "amount": 1, "shop": "x"},
            {"id": "a1", "time": "きのう", "amount": 1, "shop": "x"},
            {"id": "a2", "time": "2026-10-20T07:10:00+09:00", "amount": True, "shop": "x"},
            {"id": "a3", "time": "2026-10-20T07:10:00+09:00", "amount": 0, "shop": "x"}]}
        path.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8-sig")
        got = mothership.read_card(path)
        failed += say(got.get("available") is True and [i["id"] for i in got["items"]] == ["19a0b1c2d3e4f5a6"]
                      and got["items"][0]["shop"] == "テスト銀行", "カードの利用速報: おかしな行は落として返す")
    failed += say("/card" in mothership.GETS, "カードの利用速報: GET /card")
    return failed


# MARK: - 母艦の言葉の候補（2026-11-10）

def check_vocab() -> int:
    failed = 0
    with tempfile.TemporaryDirectory() as folder:
        base = Path(folder)
        failed += say(mothership.read_vocab(base).get("available") is False, "言葉の候補: ファイルが無いときは available=false")
        (base / "state").mkdir()
        path = base / mothership.VOCAB
        path.write_text('{"items": "x"}', encoding="utf-8")
        failed += say(mothership.read_vocab(base).get("available") is False, "言葉の候補: 形の違うものは読まない")
        data = {"generated_at": "2026-11-10T08:00:00+09:00", "items": [
            {"word": "設備台帳", "category": "専門用語", "count": 12, "last": "2026-11-09", "variants": ["台帳", 3, ""]},
            {"word": "", "count": 1},
            {"word": "<b>", "count": 1},
            {"word": 5},
            "x",
            {"word": "数だけ違う", "count": True, "variants": "x"}]}
        path.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8-sig")
        got = mothership.read_vocab(base)
        words = [i["word"] for i in got.get("items", [])]
        failed += say(got.get("available") is True and words == ["設備台帳", "数だけ違う"], "言葉の候補: おかしな行は落として返す")
        failed += say(got["items"][0]["variants"] == ["台帳"] and got["items"][0]["count"] == 12
                      and got["items"][1]["count"] == 0 and got["items"][1]["variants"] == [],
                      "言葉の候補: 別の書き方と回数を確かめる")
        many = {"items": [{"word": f"言葉{n}"} for n in range(mothership.VOCAB_LIMIT + 50)]}
        path.write_text(json.dumps(many, ensure_ascii=False), encoding="utf-8")
        failed += say(len(mothership.read_vocab(base)["items"]) == mothership.VOCAB_LIMIT, "言葉の候補: 多すぎるときは上限まで")
    failed += say("/vocab" in mothership.GETS, "言葉の候補: GET /vocab")
    # いいこと帳（2026-11-12）
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)
        failed += say(mothership.read_good(base).get("available") is False, "いいこと帳: 無ければ available false")
        (base / "state").mkdir()
        data = {"generated_at": "2026-11-12T01:00:00+0900",
                "weeks": [{"start": "2026-11-09", "thanks": 2, "praise": True, "done": 1, "own": 30, "laughs": None}, {"start": "x"}],
                "days": [{"day": "2026-11-10", "words": [{"time": "17:17", "kind": "お礼", "who": "Aさん", "text": "ありがとう"},
                                                         {"time": "bad", "kind": "お礼"}],
                          "done": [{"time": "09:00", "what": "資料を送る"}], "laughs": ["19:58", 3]}, {"day": 5}]}
        (base / mothership.GOOD).write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
        got = mothership.read_good(base)
        failed += say(got.get("available") is True and len(got["weeks"]) == 1 and got["weeks"][0]["praise"] == 0
                      and got["weeks"][0]["laughs"] is None, "いいこと帳: 週の数を確かめる")
        failed += say(len(got["days"]) == 1 and len(got["days"][0]["words"]) == 1 and got["days"][0]["laughs"] == ["19:58"],
                      "いいこと帳: おかしな行は落として返す")
    failed += say("/good" in mothership.GETS, "いいこと帳: GET /good")
    # いいこと帳の足し（先月・初めて・今夜・頼られた・ウケた確認。2026-11-12）
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)
        (base / "state").mkdir()
        data = {"weeks": [{"start": "2026-11-09", "thanks": 1, "consulted": 4}],
                "days": [{"day": "2026-11-12", "words": [], "done": [], "laughs": ["10:00"], "laughs_ok": ["10:00", "x", 5]}],
                "month": {"this": {"thanks": 3, "consulted": True, "own": 9}, "last": "bad"},
                "firsts": [{"day": "2026-11-11", "kind": "初めての場所", "text": "公園"}, {"day": "2026-11-11", "kind": "ほか"}] + [
                    {"day": "2026-11-10", "kind": "初めて話した人", "text": f"人{n}"} for n in range(30)],
                "tonight": [{"kind": "お礼", "text": "ありがとう", "time": "17:17"}, {"kind": "変", "text": "x", "time": "17:18"}] + [
                    {"kind": "頼られた", "text": f"件{n}", "time": "18:00"} for n in range(5)]}
        (base / mothership.GOOD).write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
        got = mothership.read_good(base)
        failed += say(got["weeks"][0]["consulted"] == 4 and got["days"][0]["laughs_ok"] == ["10:00"],
                      "いいこと帳: 頼られた回数とウケた確認を通す")
        failed += say(got["month"]["this"]["thanks"] == 3 and got["month"]["this"]["consulted"] is None and "last" not in got["month"],
                      "いいこと帳: 先月との比べは型を確かめる")
        failed += say(len(got["firsts"]) == 20 and len(got["tonight"]) == 3 and got["tonight"][0]["text"] == "ありがとう",
                      "いいこと帳: 初めては20件・今夜は3件まで")
        (base / mothership.GOOD).write_text(json.dumps({"weeks": [], "days": []}), encoding="utf-8")
        failed += say(not {"month", "firsts", "tonight"} & set(mothership.read_good(base)), "いいこと帳: 足しが無くても読める")
    # いいこと帳の直しを母艦へ（2026-11-12）
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)
        ok = {"id": "2026-11-12|17:17|word|ありがとう", "day": "2026-11-12", "time": "17:17", "kind": "word", "verdict": "wrong"}
        body = json.dumps({"items": [ok, {**ok, "day": "11/12"}, {**ok, "time": "7:17"}, {**ok, "kind": "x"}, {**ok, "verdict": "x"},
                                     {**ok, "id": "あ" * 201}, {**ok, "id": ""}, "bad"]}, ensure_ascii=False).encode()
        items = mothership.parse_good_feedback(body)
        failed += say(items == [ok], "いいこと帳の直し: おかしな行は落とす")
        many = json.dumps({"items": [{**ok, "id": f"i{n}"} for n in range(mothership.GOOD_FEEDBACK_MAX + 10)]}).encode()
        failed += say(len(mothership.parse_good_feedback(many)) == mothership.GOOD_FEEDBACK_MAX
                      and len(many) < mothership.body_limit("/good/feedback"), "いいこと帳の直し: 2000 件まで・上限に収まる")
        try:
            mothership.parse_good_feedback(b"[]")
            failed += say(False, "いいこと帳の直し: 形が違えば断る")
        except ValueError:
            failed += say(True, "いいこと帳の直し: 形が違えば断る")
        mothership.write_good_feedback(base, items)
        mothership.write_good_feedback(base, [])
        saved = json.loads((base / mothership.GOOD_FEEDBACK_FILE).read_text(encoding="utf-8"))
        failed += say(saved["items"] == [] and not list((base / mothership.GOOD_FEEDBACK_FILE).parent.glob("*.tmp")),
                      "いいこと帳の直し: 母艦に置き換えで書く")
    failed += say("/good/feedback" in mothership.POSTS, "いいこと帳の直し: POST /good/feedback")
    # 自分の声の候補・新しさ・PLAUD との差（2026-11-12）
    import appfeeds
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)
        failed += say(all(r(base).get("available") is False for r in appfeeds.READERS.values()), "アプリ向けの写し3つ: 無ければ available false")
        (base / "state").mkdir()
        cands = {"version": 1, "generated_at": "2026-11-12T01:00:00+09:00", "items": [
            {"id": "c1", "day": "2026-11-10", "audio": "chunk_1.m4a", "start": 3, "end": 9.5, "text": "お願いします", "score": 0.4, "why": "plaud-match"},
            {"id": "c2", "day": "2026-11-10", "audio": "chunk_2.m4a", "start": 0, "end": 5, "text": "x" * 200, "score": 0.9, "why": "plaud-most-talk"},
            {"id": "c1", "day": "2026-11-10", "audio": "chunk_1.m4a", "start": 3, "end": 9, "score": 0.5, "why": "plaud-match"},
            {"id": "c3", "day": "2026-11-10", "audio": "../etc/passwd", "start": 0, "end": 5, "score": 0.5, "why": "plaud-match"},
            {"id": "c4", "day": "2026-11-10", "audio": "a.m4a", "start": 5, "end": 2, "score": 0.5, "why": "plaud-match"},
            {"id": "c5", "day": "2026-11-10", "audio": "a.m4a", "start": 0, "end": 2, "score": 2, "why": "plaud-match"},
            {"id": "c6", "day": "2026-11-10", "audio": "a.m4a", "start": 0, "end": 2, "score": 0.5, "why": "other"}, "x"]}
        (base / appfeeds.SELF_CANDIDATES).write_text(json.dumps(cands, ensure_ascii=False), encoding="utf-8")
        got = appfeeds.read_self_candidates(base)
        failed += say([i["id"] for i in got["items"]] == ["c2", "c1"] and len(got["items"][0]["text"]) == 60,
                      "自分の声の候補: 点の高い順・おかしな行と重なりは落とす・文は60字まで")
        fresh = {"version": 1, "items": [
            {"key": "line", "label": "LINE取得", "last_ok": "2026-11-04T07:00:00+09:00", "limit_hours": 26, "stale": True, "note": "止まっている"},
            {"key": "bad key!", "label": "x", "limit_hours": 1, "stale": False}, {"key": "p", "last_ok": "昨日", "limit_hours": 1, "stale": "yes"},
            {"key": "plaud", "label": "PLAUD", "last_ok": None, "limit_hours": 48, "stale": False}]}
        (base / appfeeds.FRESHNESS).write_text(json.dumps(fresh, ensure_ascii=False), encoding="utf-8")
        got = appfeeds.read_freshness(base)
        failed += say([i["key"] for i in got["items"]] == ["line", "plaud"] and got["items"][1]["last_ok"] is None
                      and got["items"][0]["stale"] is True, "新しさ: おかしな行は落とす・last_ok は null も通す")
        gap = {"version": 1, "days": [{"day": "2026-11-09", "source": "plaud", "app_chars": 100, "plaud_chars": 400, "ratio": 0.25,
                                       "gaps": [{"from": "09:00", "to": "09:30"}, {"from": "x", "to": "y"}], "misheard": ["あ", 3], "score": 40},
                                      {"day": "bad"}], "missing_official": ["2026-11-08", "x", 5]}
        (base / appfeeds.PLAUD_GAP).write_text(json.dumps(gap, ensure_ascii=False), encoding="utf-8")
        got = appfeeds.read_plaud_gap(base)
        failed += say(len(got["days"]) == 1 and len(got["days"][0]["gaps"]) == 1 and got["missing_official"] == ["2026-11-08"]
                      and got["days"][0]["score"] == 40, "PLAUD との差: おかしな日・隙間は落とす")
        (base / appfeeds.FRESHNESS).write_text("[1]", encoding="utf-8")
        failed += say(appfeeds.read_freshness(base).get("available") is False, "新しさ: 形が違えば available false")
    failed += say(all(k in mothership.GETS for k in appfeeds.READERS), "自分の声の候補・新しさ・PLAUD との差: GETS に入っている")
    # 支払いの記録を母艦へ（2026-11-11）
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)
        items = mothership.parse_taps(json.dumps({"items": [
            {"id": "tap-AB", "time": "2026-11-11T07:20:00+09:00", "amount": 0, "shop": "", "card": "PASMO"},
            {"id": "bad id", "time": "x", "amount": 1}]}).encode())
        failed += say(len(items) == 1, "支払い: おかしなかざした記録は落とす")
        mothership.write_taps(base, items)
        failed += say(json.loads((base / mothership.TAPS_FILE).read_text(encoding="utf-8"))["items"][0]["card"] == "PASMO",
                      "支払い: かざした記録を母艦に置く")
        csv = "a,b\n1,2\n".encode()
        failed += say(mothership.write_paypay(base, csv) is not None and mothership.write_paypay(base, csv) is None,
                      "支払い: 同じ明細は2回置かない")
    failed += say("/pay/taps" in mothership.POSTS and mothership.body_limit("/pay/paypay") > mothership.BODY_LIMIT,
                  "支払い: POST /pay/taps・/pay/paypay")
    return failed



# MARK: - 仕事のまとめ（2026-11-10。made-up の中身だけ）

def digest_sample() -> list[dict]:
    return [
        {"id": "e1", "day": "2026-11-09", "text": "【11月9日】\n生の文は使わない", "source": "paste", "addedAt": 1.0e9,
         "sections": {"decided": ["Aさんが来週の資料を作る", "定例は水曜に移す"], "homework": ["見積もりを確かめる"],
                      "others": None, "topics": [], "checks": ["Bさんの返事 待ち"], "words": ["台帳"], "sources": ["会議A"]}},
        {"id": "e2", "day": "2026-11-09", "text": "x", "source": "photo", "addedAt": 1.0e9 + 5,
         "sections": {"decided": ["定例は 水曜に 移す", "別の決定"], "homework": [], "others": [], "topics": [], "checks": []}},
        {"id": "e3", "day": "2026-11-08", "text": "【11月8日】\n\n先に掃除を終える\n  \n次の週に回す", "source": "camera", "addedAt": 2.0e9},
        {"id": "e4", "day": "2026-11-08", "text": "空のまとめ", "source": "paste", "addedAt": 2.0e9 + 1,
         "sections": {"decided": [], "homework": [], "others": [], "topics": [], "checks": []}},
        {"id": "e5", "day": "きのう", "text": "日が変", "sections": None},
        "x"]


def check_digest() -> int:
    failed = 0
    with tempfile.TemporaryDirectory() as folder:
        base = Path(folder)
        path = base / "仕事のまとめ.json"
        failed += say(mothership.read_digests(path) is None and mothership.read_digests(None) is None,
                      "仕事のまとめ: ファイルが無いときは静かに空")
        failed += say(mothership.digest_file({"work_digest_file": str(path)}) == path, "仕事のまとめ: config.json の work_digest_file")
        path.write_text('{"a": 1}', encoding="utf-8")
        failed += say(mothership.read_digests(path) is None, "仕事のまとめ: 形の違うものは読まない")
        path.write_text(json.dumps(digest_sample(), ensure_ascii=False), encoding="utf-8")
        before = (path.stat().st_mtime_ns, path.read_bytes())
        got = mothership.read_digests(path)
        lines = got["lines"] if got else []
        pairs = [(l["day"], l["heading"], l["text"]) for l in lines]
        failed += say(pairs[:5] == [("2026-11-09", "出どころ", "会議A"), ("2026-11-09", "決まったこと", "Aさんが来週の資料を作る"),
                                    ("2026-11-09", "決まったこと", "定例は水曜に移す"), ("2026-11-09", "自分の宿題", "見積もりを確かめる"),
                                    ("2026-11-09", "あとで確かめること", "Bさんの返事 待ち")],
                      "仕事のまとめ: 見出しの並びと、日の新しい順")
        failed += say(("2026-11-09", "決まったこと", "別の決定") in pairs and
                      sum(1 for p in pairs if "定例" in p[2]) == 1, "仕事のまとめ: 同じ日の同じ行は（空白が違っても）1回だけ")
        failed += say([p[2] for p in pairs if p[0] == "2026-11-08"] == ["先に掃除を終える", "次の週に回す", "空のまとめ"],
                      "仕事のまとめ: まとめが無いときは生の文を行にし、【日付】だけの行は飛ばす")
        failed += say(not any(p[0] == "きのう" for p in pairs) and not any("生の文は使わない" in p[2] for p in pairs),
                      "仕事のまとめ: 日の形が変な項目は飛ばし、まとめがあれば生の文は使わない")
        failed += say(before == (path.stat().st_mtime_ns, path.read_bytes()), "仕事のまとめ: 読むだけ（ファイルを書き換えない）")

        # 意味で探す
        from v9checks import FakeEmbedder

        index = semantic.SemanticIndex(base / "semantic.db", FakeEmbedder(), lambda m: None)
        index.index([{"id": "c1", "day": "2026-11-09", "time": 1762650000.0, "speaker": "Aさん", "text": "定例は水曜に移す話",
                      "work": False, "conversation": "k1"}])
        read = lambda: mothership.read_digests(path)  # noqa: E731
        count = index.digest_tick(read)
        failed += say(count == len(lines) and index.digest_tick(read) is None, "仕事のまとめ: 索引に置き、ファイルが同じなら置き直さない")
        plain = index.search({"query": "定例は水曜に移す", "k": 20, "from": None, "to": None, "speaker": None, "include_work": True})
        failed += say(plain and all("kind" not in h and h["id"] == "c1" for h in plain), "意味で探す: 既定では仕事のまとめの行を出さない（形も前のまま）")
        both = index.search({"query": "定例は水曜に移す", "k": 20, "from": None, "to": None, "speaker": None, "include_work": True,
                             "include_digest": True})
        digest = [h for h in both if h.get("kind") == "work-digest"]
        failed += say(digest and digest[0]["text"] == "定例は水曜に移す" and digest[0]["heading"] == "決まったこと"
                      and digest[0]["day"] == "2026-11-09" and "time" not in digest[0] and "context" not in digest[0]
                      and any(h["id"] == "c1" for h in both), "意味で探す: 仕事のまとめの行は kind・day・heading つき（時刻なし）")
        only = index.search({"query": "定例", "k": 50, "from": "2026-11-09", "to": "2026-11-09", "speaker": None, "include_work": True,
                             "only_digest": True})
        failed += say(only and all(h.get("kind") == "work-digest" and h["day"] == "2026-11-09" for h in only), "意味で探す: only_digest と日の範囲")
        spoken = index.search({"query": "定例", "k": 50, "from": None, "to": None, "speaker": "決まった", "include_work": True,
                               "include_digest": True})
        failed += say(not any(h.get("kind") for h in spoken), "意味で探す: 話し手で絞るときは、見出しを話し手とみなさない")
        try:
            semantic.parse_search(json.dumps({"query": "a", "include_digest": "yes"}).encode())
            bad = False
        except ValueError:
            bad = True
        ok = semantic.parse_search(json.dumps({"query": "a"}).encode())
        failed += say(bad and ok["include_digest"] is False and ok["only_digest"] is False, "意味で探す: include_digest は true か false、既定は false")
        # ファイルが変わったら置き直し、無くなった行は消す
        changed = digest_sample()
        changed[0]["sections"]["decided"] = ["Aさんが来週の資料を作る"]
        time.sleep(0.02)
        path.write_text(json.dumps(changed, ensure_ascii=False), encoding="utf-8")
        again = index.digest_tick(read)
        left = index.search({"query": "定例は水曜に移す", "k": 50, "from": None, "to": None, "speaker": None, "include_work": True,
                             "only_digest": True})
        failed += say(again is not None and not any(h["text"] == "定例は水曜に移す" for h in left),
                      "仕事のまとめ: ファイルが変わったら置き直し、無くなった行は索引から消す")
        missing = base / "ない.json"
        failed += say(index.digest_tick(lambda: mothership.read_digests(missing)) is None and left, "仕事のまとめ: ファイルが消えても索引はそのまま")

        # MCP
        home = base / "LifeLogPC"
        home.mkdir()
        shutil_copy = (base / "semantic.db").read_bytes()
        (home / "semantic.db").write_bytes(shutil_copy)
        tools = lifelog_mcp.Tools(home, FakeEmbedder(), {"work_digest_file": str(path)})
        found = tools.call("search_digest", {"query": "資料 aさん"})
        failed += say(len(found["hits"]) == 1 and found["hits"][0]["kind"] == "work-digest" and found["hits"][0]["day"] == "2026-11-09"
                      and "time" not in found["hits"][0], "MCP search_digest: 言葉が全部ある行だけ（全角・半角と大文字・小文字は同じ）")
        failed += say(not tools.call("search_digest", {"query": "資料", "from": "2026-11-10"})["hits"]
                      and len(tools.call("search_digest", {"query": "掃除", "to": "2026-11-08"})["hits"]) == 1, "MCP search_digest: 日の範囲")
        one = tools.call("get_digest", {"day": "2026-11-09"})
        failed += say([x["heading"] for x in one["sections"]][:2] == ["出どころ", "決まったこと"] and one["lines"] >= 4
                      and tools.call("get_digest", {"day": "2026-01-01"})["lines"] == 0, "MCP get_digest: 見出しごとに1日分、無い日は空")
        text = tools.call("search_text", {"query": "資料"})
        failed += say("hits" in text and "excluded_work" in text and [h["text"] for h in text["digest_hits"]] == ["Aさんが来週の資料を作る"],
                      "MCP search_text: digest_hits を別に付け、hits の形は前のまま")
        plain = tools.call("search_text", {"query": "資料", "include_digest": False})
        failed += say("digest_hits" not in plain, "MCP search_text: include_digest=false なら付けない")
        meaning = tools.call("search_meaning", {"query": "定例は水曜に移す話", "k": 5})
        failed += say(all(h.get("kind") is None for h in meaning["hits"]) and "digest_hits" in meaning
                      and all(h["kind"] == "work-digest" for h in meaning["digest_hits"]), "MCP search_meaning: digest_hits は別の欄")
        lifelog_mcp.INCLUDE_WORK = False
        try:
            hidden = (tools.call("search_digest", {"query": "資料"}), tools.call("get_digest", {"day": "2026-11-09"}),
                      tools.call("search_text", {"query": "資料"}), tools.call("search_meaning", {"query": "定例"}))
        finally:
            lifelog_mcp.INCLUDE_WORK = True
        failed += say(not hidden[0]["hits"] and hidden[1]["lines"] == 0 and "digest_hits" not in hidden[2]
                      and "digest_hits" not in hidden[3], "MCP: --exclude-work のときは仕事のまとめを出さない")
        names = {t["name"] for t in lifelog_mcp.TOOLS}
        failed += say({"search_digest", "get_digest"} <= names, "MCP: 道具の一覧に search_digest・get_digest")
    return failed
