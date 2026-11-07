"""LifeLog PC 版 8 の機能を確かめる（--check-v8 から呼ぶ。本物のモデル・本物の APNs は使わない）。
決まりは docs/v8-latency.md。一時フォルダの HOME と作り物のモデルで、次を確かめる:

- 時間: POST /jobs の chunk_start・chunk_end・arrived・sent を読み、GET と待ち合わせの答えに "timing" を付ける
- 待ち合わせ（wait=1）: 空白が届く・でき上がりで答えが来る・上限（短くして試す）で pending・切れたとき・閉じるとき
- 通知: 待ち合わせで渡した仕事には「できた」の通知を送らない。渡せなかった仕事だけ送る
- 下書き: haas・reazon だけの下書きが先にでき、GET で見える。haas・reazon は2回読まない。下書きに失敗しても多数決は続く
- 新しい区切りから: 待っているものが2つ以上なら、新しく受けたものから
- 見守りの画面・実機の様子の時間の行
- 確かめるときは、本物の HOME に書かない
- 2026-11-07 の落ち方の直し（--check-crash）と、GPU に余裕を作る直し（--check-gpu。run_gpu）
"""

from __future__ import annotations

import gc
import json
import re
import socket
import sys
import tempfile
import threading
import time
import types
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import quote

import numpy as np

import dashboard
import diag
import gpu
import jobqueue
import ops
from v6checks import KEY, Client, say, tone_wav

ISO = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$")


def run(main) -> int:
    # LOCALAPPDATA を一時にしていなくても、本物の HOME（log.txt・データ）に書かない
    main.isolate_home()
    failed = 0
    failed += check_isolated(main)
    failed += check_times()
    failed += check_order()
    with tempfile.TemporaryDirectory() as folder:
        root = Path(folder)
        failed += check_draft_pipeline(main, root / "draft")
        failed += check_draft_failures(main, root / "draft-fail")
        failed += check_wait(main, root / "wait")
    failed += check_push_skip()
    failed += check_screens()
    failed += check_gpu_lock(main)
    failed += check_crash_guard(main)
    failed += run_gpu(main, summary=False)
    return failed


def run_crash(main) -> int:
    """--check-crash: 2026-11-07 の落ち方の直し（GPU のモデルは1度に1つ・使っている最中に下ろさない・
    落ちたあとの守り）だけを確かめる"""
    main.isolate_home()
    failed = check_isolated(main) + check_gpu_lock(main) + check_crash_guard(main)
    print(("NG の数: " + str(failed)) if failed else "GPU のロック: 全部 OK", flush=True)
    return failed


# MARK: - 本物の HOME に書かない


def check_isolated(main) -> int:
    import os

    home = Path(main.HOME)
    inside = all(Path(getattr(main, name)).is_relative_to(home) for name, _ in main.HOME_PATHS)
    ok = main._isolated is not None and home.is_relative_to(main._isolated) and home != Path(main._START_HOME) \
        and inside and os.environ.get("LOCALAPPDATA") == str(main._isolated) and Path(main.LOG).parent == home
    return say(ok, f"確かめるときは、HOME とその下の置き場所（{len(main.HOME_PATHS)} 個）を一時のフォルダに替える"
                   f"（LOCALAPPDATA も。{home.name}）")


# MARK: - 時間


def check_times() -> int:
    query = {"chunk_start": ["2026-11-07T06:50:00.123Z"], "chunk_end": ["2026-11-07T15:55:00+09:00"],
             "arrived": ["2026-11-07T06:55:30"], "sent": ["あいうえお"], "other": ["2026-11-07T06:55:30Z"]}
    times = jobqueue.parse_times(query)
    meta = {"times": times, "queued_at": 1762498530.5, "started_at": 1762498531.25, "draft_at": None,
            "done_at": 1762498560.0}
    out = jobqueue.timing(meta)
    ok = set(times) == {"chunk_start", "chunk_end", "arrived"} \
        and out == {"chunk_start": "2026-11-07T06:50:00.123Z", "chunk_end": "2026-11-07T06:55:00.000Z",
                    "arrived": "2026-11-07T06:55:30.000Z", "received": diag.iso(1762498530.5),
                    "started": diag.iso(1762498531.25), "finished": diag.iso(1762498560.0)} \
        and all(ISO.match(v) for v in out.values())
    return say(ok, f"timing: iPhone の時刻（Z・+09:00・時差なし）を UTC のミリ秒つきにそろえ、読めないもの・分からないものは省く {out}")


# MARK: - 新しい区切りから


def put(queue: jobqueue.JobQueue, name: str, data: bytes = b"x", times: dict | None = None) -> None:
    assert queue.begin(name)[0] == "ok"
    queue.part_path(name).write_bytes(data)
    queue.commit(name, {"hints": []}, len(data), times)


def check_order() -> int:
    order: list[str] = []
    with tempfile.TemporaryDirectory() as folder:
        queue = jobqueue.JobQueue(Path(folder), lambda path, params, name: (order.append(name) or {"lines": []}, {}),
                                  lambda m: None)
        for name in ("a.m4a", "b.m4a", "c.m4a"):
            put(queue, name)
        queue.step()
        put(queue, "d.m4a")
        while queue.step():
            pass
        put(queue, "e.m4a")
        queue.step()
    ok = order == ["c.m4a", "d.m4a", "b.m4a", "a.m4a", "e.m4a"]
    return say(ok, f"新しい区切りから: 待っているものが2つ以上なら新しく受けたものから、1つなら今までどおり {order}")


# MARK: - 下書き（作り物のモデルで、lifelog_pc.run_job を通して）


class Fake:
    """作り物のモデル。gate があれば、それが開くまで書き終えない。読んだ回数を数える"""
    provider = "cpu"

    def __init__(self, name: str, text: str, gate: threading.Event | None = None) -> None:
        self.name = self.label = name
        self.text = text
        self.gate = gate
        self.calls = 0

    def run(self, audio, segments, hints, prompt):
        self.calls += 1
        if self.gate is not None:
            self.gate.wait(20)
        return [self.text for _ in segments]


def wait_until(test, timeout: float = 10.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if test():
            return True
        time.sleep(0.05)
    return bool(test())


def check_draft_pipeline(main, folder: Path) -> int:
    failed = 0
    logged: list[str] = []
    saved = (getattr(main.Handler, "engine", None), main._vad_failed, main.log)
    gate = threading.Event()
    haas, reazon = Fake("haas", "今日は会議です"), Fake("reazon", "今日は会議です")
    whisper = Fake("whisper", "今日は会議でした", gate)
    try:
        main.log = logged.append
        main._vad_failed = time.time()  # Silero VAD を取ってこないで、音の大きさで声の区間を探す
        main.Handler.engine = main.Ensemble([haas, reazon, whisper])
        queue = jobqueue.JobQueue(folder, main.run_job, logged.append)
        put(queue, "20261107-150000.m4a", tone_wav(6.0, [(1.0, 2.5), (3.5, 5.0)]),
            {"chunk_end": time.time() - 30, "sent": time.time() - 2})
        worker = threading.Thread(target=queue.step, daemon=True)
        worker.start()
        seen = wait_until(lambda: "draft" in (queue.get("20261107-150000.m4a") or {}))
        working = queue.get("20261107-150000.m4a") or {}
        draft = working.get("draft") or {}
        gate.set()
        worker.join(20)
        done = queue.get("20261107-150000.m4a") or {}
        result = done.get("result") or {}
        timing = done.get("timing") or {}
        lines = draft.get("lines") or []
        ok = seen and working.get("status") == "working" and draft.get("draft") is True \
            and draft.get("engines") == ["haas", "reazon"] and len(lines) == 2 \
            and all(line["text"] == "今日は会議です" for line in lines) \
            and set(working.get("timing") or {}) >= {"received", "started", "draft_at"} \
            and "finished" not in (working.get("timing") or {}) and "result" not in working
        failed += say(ok, f"下書き: 文字にしている最中に GET すると working と haas・reazon だけの下書き（{len(lines)} 行）と timing")
        order = [timing.get(k) for k in ("received", "started", "draft_at", "finished")]
        ok = done.get("status") == "done" and "draft" not in done and result.get("engines") == ["haas", "reazon", "whisper"] \
            and len(result.get("lines") or []) == 2 and all(order) and order == sorted(order) \
            and haas.calls == 1 and reazon.calls == 1 and whisper.calls == 1 \
            and not queue.draft_path("20261107-150000.m4a").exists() \
            and any("下書き 2 行" in m for m in logged) and not any("会議" in m for m in logged)
        failed += say(ok, f"下書きのあと多数決で差し替える: haas・reazon は1回だけ読む（{haas.calls}・{reazon.calls}）・"
                          f"でき上がったら下書きは消す・時刻の順 {order}・記録に文の中身を書かない")
    finally:
        gate.set()
        main.Handler.engine, main._vad_failed, main.log = saved
    return failed


def check_draft_failures(main, folder: Path) -> int:
    failed = 0
    logged: list[str] = []
    saved = (main.log, main._vad_failed)
    try:
        main.log = logged.append
        main._vad_failed = time.time()
        audio = main.load_audio(tone_wav(4.0, [(1.0, 2.5)]))
        segments = [(0.9, 2.6)]
        engine = main.Ensemble([Fake("haas", "はい"), Fake("reazon", "はい"), Fake("whisper", "はい")])

        def broken(lines, names):
            raise RuntimeError("作り物の下書きの失敗")

        lines = engine.transcribe(audio, segments, on_draft=broken)
        ok = len(lines) == 1 and lines[0]["text"] == "はい" and any("下書きを作れませんでした" in m for m in logged)
        failed += say(ok, "下書きを作るのに失敗しても、多数決はいつもどおり続く")
        called: list = []
        only_fast = main.Ensemble([Fake("haas", "はい"), Fake("reazon", "はい")])
        only_fast.transcribe(audio, segments, on_draft=lambda lines, names: called.append(names))
        no_fast = main.Ensemble([Fake("whisper", "はい"), Fake("kotoba", "はい")])
        no_fast.transcribe(audio, segments, on_draft=lambda lines, names: called.append(names))
        failed += say(called == [], f"速いモデルしか無い・速いモデルが無いときは、下書きを作らない {called}")

        # 下書きを残せなくても（中身を書けない）、でき上がりは残る
        def runner(path, params, name, draft):
            kept = draft({"lines": [], "bad": object()})
            return {"lines": [], "kept": kept}, {}

        queue = jobqueue.JobQueue(folder, runner, logged.append)
        put(queue, "bad-draft.m4a")
        queue.step()
        got = queue.get("bad-draft.m4a") or {}
        ok = got.get("status") == "done" and got.get("result") == {"lines": [], "kept": False} \
            and any("下書きを残せませんでした" in m for m in logged)
        failed += say(ok, f"下書きを残せなくても、仕事はでき上がる（{got.get('status')}）")
        # 3つしか受けない版 7 までの runner も、そのまま使える
        old = jobqueue.JobQueue(folder / "old", lambda path, params, name: ({"lines": [1]}, {}), logged.append)
        put(old, "old.m4a")
        old.step()
        failed += say((old.get("old.m4a") or {}).get("result") == {"lines": [1]} and not old.runner_drafts,
                      "下書きの口を受けない runner（版 7 まで）も、そのまま動く")
    finally:
        main.log, main._vad_failed = saved
    return failed


# MARK: - 待ち合わせ（wait=1）と通知


def raw_post(port: int, path: str, body: bytes, close_after: float | None = None,
             timeout: float = 30.0, hold: float = 0.0) -> dict:
    """待ち合わせの答えを、届いた順に読む。close_after 秒で、こちらから切る。
    hold 秒: 答えを読み終えても、すぐには閉じない（届いたか PC に分からないとき）"""
    sock = socket.create_connection(("127.0.0.1", port), timeout=timeout)
    started = time.time()
    head = (f"POST {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {KEY}\r\n"
            f"Content-Length: {len(body)}\r\nContent-Type: application/octet-stream\r\n\r\n").encode("ascii")
    sock.sendall(head + body)
    data = b""
    chunks: list[tuple[float, bytes]] = []
    try:
        while True:
            if close_after is not None and time.time() - started >= close_after:
                break
            sock.settimeout(0.1 if close_after is not None else timeout)
            try:
                chunk = sock.recv(65536)
            except socket.timeout:
                if close_after is not None:
                    continue
                raise
            if not chunk:
                break
            chunks.append((time.time() - started, chunk))
            data += chunk
        if hold:
            time.sleep(hold)
    finally:
        sock.close()
    header, _, rest = data.partition(b"\r\n\r\n")
    status = int(header.split(b" ")[1]) if header.startswith(b"HTTP/") else 0
    spaces = len(rest) - len(rest.lstrip(b" "))
    try:
        answer = json.loads(rest.decode("utf-8")) if rest.strip() else None
    except ValueError:
        answer = None
    # 空白が、答えより前に、少しずつ届いたか（最初の空白が届いた時刻）
    first_space = None
    seen = 0
    for at, chunk in chunks:
        if first_space is None and b" " in chunk and seen + len(chunk) > len(header) + 4:
            first_space = at
        seen += len(chunk)
    return {"status": status, "header": header.decode("latin-1"), "spaces": spaces, "answer": answer,
            "took": time.time() - started, "first_space": first_space}


def check_wait(main, folder: Path) -> int:
    failed = 0
    logged: list[str] = []
    gates: dict[str, threading.Event] = {}
    notified: list[tuple[str, bool]] = []

    def runner(path, params, name, draft):
        draft({"lines": [{"start": 0.0, "end": 1.0, "text": "仮"}], "draft": True, "engines": ["haas", "reazon"]})
        gate = gates.get(name)
        if gate is not None:
            gate.wait(20)
        return {"lines": [{"start": 0.0, "end": 1.0, "text": "でき上がり"}], "seconds": 0.1}, {"audio_seconds": 1.0}

    saved = (main.App.jobs, getattr(main.Handler, "engine", None), getattr(main.Handler, "key", None), main.log,
             jobqueue.WAIT_PING, jobqueue.WAIT_LIMIT, jobqueue.WAIT_CONFIRM)
    server = None
    try:
        main.log = logged.append
        main.Handler.key = KEY
        main.Handler.engine = main.Ensemble([Fake("haas", "x"), Fake("reazon", "x"), Fake("whisper", "x")])
        main.App.jobs = queue = jobqueue.JobQueue(folder, runner, logged.append)
        queue.on_done = lambda name, meta: notified.append((name, bool(meta.get("handed"))))
        queue.start()
        jobqueue.WAIT_PING = 0.2
        jobqueue.WAIT_LIMIT = 1.5
        server = main.Server(("127.0.0.1", 0), main.Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        port = server.server_address[1]
        client = Client(port)
        sent_at = diag.iso(time.time() - 1.0)  # iPhone が送り始めた時刻（1 秒前）
        stamp = quote(sent_at)
        features = main.features()

        # 1. でき上がりまで待たせ、空白を書き、GET と同じ形で答える
        gates["w1.m4a"] = threading.Event()
        box: dict = {}
        thread = threading.Thread(target=lambda: box.update(raw_post(
            port, f"/jobs?name=w1.m4a&wait=1&chunk_start={stamp}&chunk_end={stamp}&arrived={stamp}&sent={stamp}",
            b"audio")), daemon=True)
        thread.start()
        wait_until(lambda: (queue.get("w1.m4a") or {}).get("draft") is not None, 5)
        time.sleep(0.7)
        middle = client.call("GET", "/jobs/w1.m4a")
        gates["w1.m4a"].set()
        thread.join(10)
        answer = box.get("answer") or {}
        timing = answer.get("timing") or {}
        meta = dict(queue.jobs.get("w1.m4a") or {})
        ok = box.get("status") == 200 and box.get("spaces", 0) >= 2 and box.get("first_space") is not None \
            and box["first_space"] < box["took"] - 0.3 and answer.get("status") == "done" \
            and (answer.get("result") or {}).get("lines", [{}])[0].get("text") == "でき上がり" \
            and "draft" not in answer and timing.get("chunk_end") == sent_at \
            and set(timing) == {"chunk_start", "chunk_end", "arrived", "sent", "received", "started", "draft_at",
                                "finished"} \
            and middle[0] == 200 and middle[1].get("status") == "working" \
            and (middle[1].get("draft") or {}).get("draft") is True and "draft_at" in (middle[1].get("timing") or {}) \
            and meta.get("handed") is True and "connection: close" in box.get("header", "").lower()
        failed += say(ok, f"待ち合わせ: 空白 {box.get('spaces')} 個が先に届き（最初は {box.get('first_space') or 0:.1f} 秒）、"
                          f"でき上がりで GET と同じ形（{answer.get('status')}・timing {len(timing)} 個）。待っているあいだの GET は "
                          f"{middle[1].get('status') if isinstance(middle[1], dict) else middle[0]} と下書き")
        # 2. 渡した仕事には通知しない。待ち合わせでない仕事には通知する
        gates.pop("plain.m4a", None)
        plain = client.call("POST", "/jobs?name=plain.m4a", b"audio")
        wait_until(lambda: (queue.get("plain.m4a") or {}).get("status") == "done", 5)
        wait_until(lambda: ("plain.m4a", False) in notified, 2)
        ok = plain[1] == {"id": "plain.m4a", "status": "queued"} and ("plain.m4a", False) in notified \
            and not any(n == "w1.m4a" for n, _ in notified)
        failed += say(ok, f"通知: 待ち合わせで渡した仕事には送らず、待ち合わせでない仕事にだけ送る {notified}")
        # 3. 同じ名前をもう一度 wait=1 で送ると、預かっている仕事の答えがすぐ来る（音声は読み捨てる）
        again = raw_post(port, "/jobs?name=w1.m4a&wait=1", b"audio-again")
        ok = again["status"] == 200 and (again["answer"] or {}).get("status") == "done" and again["took"] < 1.0 \
            and queue.jobs["w1.m4a"]["seq"] == meta.get("seq")
        failed += say(ok, f"同じ名前を wait=1 で送り直すと、すぐ答える（{(again['answer'] or {}).get('status')}・{again['took']:.2f} 秒）")
        # 4. 上限（ここでは 1.5 秒）を過ぎたら pending を返して閉じる。仕事は続け、でき上がったら通知する
        gates["slow.m4a"] = threading.Event()
        slow = raw_post(port, "/jobs?name=slow.m4a&wait=1", b"audio")
        pending = slow["answer"] or {}
        gates["slow.m4a"].set()
        wait_until(lambda: ("slow.m4a", False) in notified, 5)
        ok = pending.get("status") == "pending" and pending.get("job_status") == "working" \
            and "received" in (pending.get("timing") or {}) and 1.3 <= slow["took"] <= 4.0 \
            and slow["spaces"] >= 3 and ("slow.m4a", False) in notified \
            and not queue.jobs["slow.m4a"].get("handed")
        failed += say(ok, f"上限を過ぎたら pending（{pending.get('status')}・{slow['took']:.1f} 秒）を返し、"
                          "仕事は続けて、でき上がりで通知する")
        # 5. iPhone が途中で切ったら、渡せなかったので、でき上がりで通知する
        gates["cut.m4a"] = threading.Event()
        raw_post(port, "/jobs?name=cut.m4a&wait=1", b"audio", close_after=0.3)
        left = wait_until(lambda: "cut.m4a" not in queue.waiters, 5)
        gates["cut.m4a"].set()
        wait_until(lambda: ("cut.m4a", False) in notified, 5)
        ok = left and ("cut.m4a", False) in notified and not queue.jobs["cut.m4a"].get("handed")
        failed += say(ok, "途中で切れたら、待つのをやめて、でき上がりで通知する")
        # 6. 起動し直す・閉じるとき（pause_work）は、すぐ pending を返す
        jobqueue.WAIT_LIMIT = 30.0
        gates["close.m4a"] = threading.Event()
        box2: dict = {}
        thread = threading.Thread(target=lambda: box2.update(raw_post(port, "/jobs?name=close.m4a&wait=1", b"audio")),
                                  daemon=True)
        thread.start()
        wait_until(lambda: "close.m4a" in queue.waiters and (queue.get("close.m4a") or {}).get("status") == "working", 5)
        paused_at = time.time()
        main.pause_work()
        drained = time.time() - paused_at
        thread.join(5)
        main.resume_work()
        gates["close.m4a"].set()
        wait_until(lambda: ("close.m4a", False) in notified, 5)
        ok = (box2.get("answer") or {}).get("status") == "pending" and drained < 2.5 and not queue.waiters \
            and ("close.m4a", False) in notified
        failed += say(ok, f"起動し直す・閉じるときは、すぐ pending を返す（{drained:.1f} 秒で待っている人がいなくなる）")
        # 7. 預けてすぐ終わる仕事でも、待ち合わせなら通知しない
        fast = raw_post(port, "/jobs?name=fast.m4a&wait=1", b"audio")
        time.sleep(0.3)
        ok = (fast["answer"] or {}).get("status") == "done" and not any(n == "fast.m4a" for n, _ in notified)
        failed += say(ok, "すぐでき上がる仕事でも、待ち合わせで渡したら通知しない")
        # 8. 答えを書いても、相手が読み終えて閉じるのが来なければ（つながりが途中で消えたなど）、渡せたか分からないので通知する
        jobqueue.WAIT_CONFIRM = 0.5
        unsure = raw_post(port, "/jobs?name=unsure.m4a&wait=1", b"audio", hold=1.5)
        wait_until(lambda: ("unsure.m4a", False) in notified, 3)
        ok = (unsure["answer"] or {}).get("status") == "done" and ("unsure.m4a", False) in notified \
            and not queue.jobs["unsure.m4a"].get("handed")
        failed += say(ok, "答えを書いても、iPhone が読み終えて閉じたと分からなければ、渡せなかったとして通知する")
        ok = all(f in features for f in ("jobs", "jobwait", "timing", "draft"))
        failed += say(ok, f"features に jobwait・timing・draft（{[f for f in features if f in ('jobwait', 'timing', 'draft')]}）")
        # 待ち合わせの数（見守りの画面）
        stats = queue.latency()
        ok = stats["count"] >= 5 and stats["handed"] >= 2 and stats["wait"] is not None and stats["work"] is not None \
            and stats["draft"] is not None and stats["to_pc"] is not None
        failed += say(ok, f"直近の仕事の時間: {json.dumps(stats, ensure_ascii=False)}")
    finally:
        for gate in gates.values():
            gate.set()
        if server is not None:
            server.shutdown()
            server.server_close()
        (main.App.jobs, main.Handler.engine, main.Handler.key, main.log, jobqueue.WAIT_PING, jobqueue.WAIT_LIMIT,
         jobqueue.WAIT_CONFIRM) = saved
        main.App.closing = False
    return failed


def check_push_skip() -> int:
    """ops.job_done は、渡した仕事（handed）に「できた」の通知を送らない"""

    class Pusher:
        def __init__(self) -> None:
            self.sent: list = []

        def ready(self) -> bool:
            return True

        def usable(self, device) -> bool:
            return True

        def send(self, kind, devices=None, job=None):
            self.sent.append((kind, job))
            return [{"ok": True}]

    class Diag:
        def device_for_ip(self, ip):
            return None

    names = ("started", "pusher", "diag", "home", "job_ip")
    saved = {n: getattr(ops.O, n, None) for n in names}
    pusher = Pusher()
    with tempfile.TemporaryDirectory() as folder:
        try:
            ops.O.started, ops.O.pusher, ops.O.diag, ops.O.home = True, pusher, Diag(), Path(folder)
            ops.O.job_ip = {}
            ops.job_done("handed.m4a", {"status": "done", "handed": True})
            ops.job_done("failed.m4a", {"status": "failed"})
            ops.job_done("plain.m4a", {"status": "done"})
            wait_until(lambda: pusher.sent, 3)
            time.sleep(0.2)
        finally:
            for n, v in saved.items():
                setattr(ops.O, n, v)
    return say(pusher.sent == [("job", "plain.m4a")], f"見えない通知: 渡した仕事・失敗した仕事には送らない {pusher.sent}")


# MARK: - 見守りの画面・実機の様子・summary.md の行


def check_screens() -> int:
    failed = 0
    now = time.time()
    jobs = [{"id": "20261107-150000.m4a", "status": "done", "queued_at": now - 60, "started_at": now - 55,
             "draft_at": now - 50, "done_at": now - 30, "processing_seconds": 25.0, "audio_seconds": 120.0,
             "voiced_seconds": 50.0, "handed": True}]
    stats = {"count": 1, "handed": 1, "wait": {"median": 5.0, "max": 5.0, "count": 1},
             "work": {"median": 25.0, "max": 25.0, "count": 1}, "draft": {"median": 5.0, "max": 5.0, "count": 1},
             "to_pc": None}
    page = dashboard.render({"version": 7, "jobs": jobs, "job_counts": {"done": 1}, "job_latency": stats})
    ok = "待ち合わせで渡した" in page and "PC の待ち（受け終わり→文字にし始め）: 中央値 5.0 秒" in page \
        and "PC の作業（文字にし始め→でき上がり）: 中央値 25.0 秒" in page and "<th class='num'>下書き</th>" in page \
        and "待ち合わせで渡した: 1 / 1 件" in page
    failed += say(ok, "見守りの画面に、直近の仕事の待ち・作業・下書きまでの時間（中央値）と、渡したかを出す")
    record = {"state": {"latency": {"count": 12, "toPhone": 40.5, "toPC": 3.2, "pcWait": 1.0, "pcWork": 25.4,
                                    "toRecord": 6.0, "total": 80.1, "bad": "x"}}}
    lines = diag.state_lines(record)
    want = ("文字になるまでの時間（iPhone で測った直近24時間の中央値）: 録音の終わり→iPhone 40.5 秒・iPhone→PC 3.2 秒・"
            "PC の待ち 1.0 秒・PC の作業 25.4 秒・PC→記録 6.0 秒・合計 80.1 秒（12 件）")
    missing = diag.phone_latency({"latency": {"toPC": 3.2}})
    ok = want in lines and missing == "iPhone→PC 3.2 秒" and diag.phone_latency({}) is None \
        and diag.phone_latency({"latency": {"toPC": "x"}}) is None
    failed += say(ok, f"実機の様子（画面と summary.md）に、iPhone から届いた区間ごとの時間を出す（分からない区間は省く）: {lines[-1:]}")
    empty = diag.pc_latency(None)
    failed += say(empty == ["まだでき上がった仕事がありません"], "まだ仕事が無いときの summary.md の行")
    return failed


# MARK: - GPU のロック（2026-11-07 11:22 に ctranslate2.dll の中で落ちたことへの直し）


class GpuState:
    """作り物の GPU。今いくつ GPU で動いているか・下ろしたあとに使われたか・使っている最中に下ろされたかを数える"""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.active = 0
        self.max_active = 0
        self.calls = 0
        self.after_free = 0
        self.unload_busy = 0
        self.loads = 0

    def enter(self) -> None:
        with self.lock:
            self.active += 1
            self.calls += 1
            self.max_active = max(self.max_active, self.active)

    def leave(self) -> None:
        with self.lock:
            self.active -= 1


class FakeCT2:
    """faster-whisper の WhisperModel の作り物。本物と同じく、transcribe のあと pieces を読む間に GPU を使う。
    .model.unload_model() は CTranslate2 の Whisper の代わり"""

    class Piece:
        def __init__(self, text: str) -> None:
            self.text = text
            self.no_speech_prob = 0.0
            self.avg_logprob = -0.1
            self.words = None
            self.seek = 0

    class Inner:
        def __init__(self, owner) -> None:
            self.owner = owner

        def unload_model(self) -> None:
            owner = self.owner
            if owner.running:
                owner.state.unload_busy += 1
            owner.freed = True

    def __init__(self, state: GpuState, text: str, seconds: float = 0.02) -> None:
        self.state = state
        self.text = text
        self.seconds = seconds
        self.running = 0
        self.freed = False
        self.model = FakeCT2.Inner(self)

    def _busy(self) -> None:
        if self.freed:
            self.state.after_free += 1
        self.running += 1
        self.state.enter()
        try:
            time.sleep(self.seconds)
        finally:
            self.state.leave()
            self.running -= 1

    def transcribe(self, audio, **kwargs):
        self._busy()  # 音の特徴・encode の代わり

        def pieces():
            self._busy()  # generate（文を作る）の代わり
            yield FakeCT2.Piece(self.text)

        return pieces(), None


class FakeCpu:
    """CPU のモデル（haas）の作り物。GPU のモデルが動いている間にも動けたかを数える"""
    name = label = "haas"
    provider = "cpu"

    def __init__(self, state: GpuState) -> None:
        self.state = state
        self.lock = threading.Lock()
        self.overlap = 0

    def run(self, audio, segments, hints, prompt):
        with self.lock:
            out = []
            for _ in segments:
                time.sleep(0.01)
                if self.state.active > 0:
                    self.overlap += 1
                out.append("作り物")
            return out


def fake_gpu_engine(main, name: str, state: GpuState, shared=True):
    """本物の WhisperEngine（run_timed は本物のまま）に、作り物の WhisperModel を持たせる（読み込みはしない）"""
    kinds = {"whisper": main.WhisperEngine, "kotoba": main.KotobaEngine, "mine": main.MineEngine}
    engine = object.__new__(kinds[name])
    lock = gpu.GPU_LOCK if shared else None
    # 本物の読み込み（WhisperEngine.__init__）と同じく、GPU に載せる間も GPU_LOCK を持つ
    with (lock or threading.Lock()):
        state.enter()
        state.loads += 1
        time.sleep(0.05)
        state.leave()
    engine.model = FakeCT2(state, "作り物")
    engine.provider = "cuda"
    engine.label = name
    engine.lock = threading.Lock()
    engine.gpu_lock = lock
    return engine


def check_gpu_lock(main) -> int:
    failed = 0
    saved = (main.log, main.WORD_TIMES)
    logged: list[str] = []
    try:
        main.log = logged.append
        main.WORD_TIMES = False
        audio = np.zeros(6 * main.RATE, dtype=np.float32)
        segments = [(0.0, 2.0), (2.0, 4.0), (4.0, 6.0)]

        # 1. 比べるため: GPU_LOCK を使わない（前のまま）と、whisper と kotoba が GPU で同時に動く（この確かめで見つけられる）
        before = GpuState()
        old = main.Ensemble([fake_gpu_engine(main, "whisper", before, shared=False),
                             fake_gpu_engine(main, "kotoba", before, shared=False)])
        old.transcribe(audio, segments)
        failed += say(before.max_active >= 2,
                      f"比べるため: GPU_LOCK が無いと、GPU のモデルが同時に動く（同時に {before.max_active} つ）")

        # 2. /transcribe・後で受け取る仕事・多数決のスレッドが重なり、その最中に GPU の時間割が下ろす・戻すを3回
        state = GpuState()
        cpu = FakeCpu(state)
        ensemble = main.Ensemble([cpu, fake_gpu_engine(main, "whisper", state), fake_gpu_engine(main, "kotoba", state)])
        messages: list[str] = []
        plan = gpu.GpuPlan(lambda: ensemble, lambda name: fake_gpu_engine(main, name, state), messages.append,
                           free_mb=lambda: None)
        errors: list[str] = []
        results: list[int] = []
        stop = threading.Event()

        def caller(n: int) -> None:
            while not stop.is_set():
                try:
                    lines = ensemble.transcribe(audio, segments, hints=[], prompt=None)
                    results.append(len(lines))
                except Exception as error:  # noqa: BLE001
                    errors.append(repr(error))
                time.sleep(0.005 * n)

        callers = [threading.Thread(target=caller, args=(n,), daemon=True) for n in range(4)]
        for thread in callers:
            thread.start()
        cycles = []
        for _ in range(3):
            time.sleep(0.25)
            down = plan.unload("night")
            time.sleep(0.15)
            back = plan.restore()
            cycles.append((down, back))
        time.sleep(0.25)
        stop.set()
        for thread in callers:
            thread.join(30)
        names = [e.name for e in ensemble.engines]
        ok = state.max_active == 1 and state.calls > 20 and not errors and len(results) >= 8 \
            and all(down == ["whisper", "kotoba"] and back == ["whisper", "kotoba"] for down, back in cycles) \
            and names == ["haas", "whisper", "kotoba"]
        failed += say(ok, f"GPU_LOCK: 4 つのスレッドの文字起こしと、下ろす・戻す（3 回）が重なっても、GPU で動くのは同時に "
                          f"{state.max_active} つだけ（GPU の仕事 {state.calls} 回・読み込み {state.loads} 回・文字起こし "
                          f"{len(results)} 回・失敗 {len(errors)}・今のモデル {names}）")
        ok = state.unload_busy == 0 and state.after_free == 0
        failed += say(ok, f"使っている最中には下ろさない（{state.unload_busy} 回）・下ろしたモデルはもう使わない（{state.after_free} 回）")
        gone = sum(1 for m in logged if "GPU から下ろしたので使えません" in m)
        failed += say(cpu.overlap > 0,
                      f"CPU のモデル（haas）は GPU_LOCK を待たない（GPU が動いている間に {cpu.overlap} 区間）・"
                      f"下ろす前に選ばれていた票はその回だけ抜く（{gone} 回）")

        # 3. 作り物のモデル（--fake-models）も、GPU の作り物どうしは同時に動かない
        seen = {"active": 0, "max": 0}
        guard = threading.Lock()

        class Watch(ops.FakeEngine):
            def run(self, audio, segments, hints, prompt):
                with self.lock, (self.gpu_lock or threading.Lock()):
                    with guard:
                        seen["active"] += 1
                        seen["max"] = max(seen["max"], seen["active"])
                    time.sleep(0.05)
                    with guard:
                        seen["active"] -= 1
                return super().run(audio, segments, hints, prompt)

        fakes = main.Ensemble([Watch("whisper", "cuda"), Watch("kotoba", "cuda")])
        threads = [threading.Thread(target=fakes.transcribe, args=(audio, segments)) for _ in range(3)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(30)
        fake = ops.FakeEngine("whisper", "cuda")
        failed += say(seen["max"] == 1 and fake.gpu_lock is gpu.GPU_LOCK and ops.FakeEngine("haas").gpu_lock is None,
                      f"--fake-models の GPU の作り物も GPU_LOCK で1つずつ（同時に {seen['max']} つ）")
    finally:
        main.log, main.WORD_TIMES = saved
    return failed

def check_crash_guard(main) -> int:
    """落ちたあとの守り: 同じ仕事で2回止まったら CPU のモデルだけ・3回なら飛ばす。GPU で2回止まったら、その起動は CPU だけ"""
    failed = 0
    with tempfile.TemporaryDirectory() as folder:
        root = Path(folder)
        # 1. 仕事ごと: 文字にしている最中（working）のまま止まった仕事を、起動し直すたびに読み込む
        seen: list[tuple[str, bool]] = []
        queue_dir = root / "jobs"

        def runner(path, params, name):
            seen.append((name, bool(params.get("cpu_only"))))
            return {"lines": []}, {}

        logs: list[str] = []
        queue = jobqueue.JobQueue(queue_dir, runner, logs.append)
        put(queue, "20261107-093037-w.m4a")
        stops = []
        for _ in range(3):
            meta_path = queue.meta_path("20261107-093037-w.m4a")
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
            meta["status"] = "working"  # 文字にしている最中に落ちた
            meta_path.write_text(json.dumps(meta), encoding="utf-8")
            queue = jobqueue.JobQueue(queue_dir, runner, logs.append)
            got = queue.jobs["20261107-093037-w.m4a"]
            stops.append((got.get("status"), got.get("interrupted")))
        ok = stops == [("queued", 1), ("queued", 2), ("failed", 3)] \
            and "飛ばしました" in (queue.jobs["20261107-093037-w.m4a"].get("error") or "") \
            and any("CPU のモデルだけで" in m for m in logs) and any("飛ばします" in m for m in logs)
        failed += say(ok, f"同じ仕事で止まった回数を数え、2 回目は CPU のモデルだけ・3 回目は飛ばす {stops}")
        # step が runner に cpu_only を渡す（2 回止まった仕事だけ）
        seen.clear()
        queue2 = jobqueue.JobQueue(root / "jobs2", runner, logs.append)
        put(queue2, "a.m4a")
        put(queue2, "b.m4a")
        meta_path = queue2.meta_path("b.m4a")
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
        meta.update(status="working", interrupted=1)
        meta_path.write_text(json.dumps(meta), encoding="utf-8")
        queue2 = jobqueue.JobQueue(root / "jobs2", runner, logs.append)
        while queue2.step():
            pass
        saved_params = json.loads(queue2.meta_path("b.m4a").read_text(encoding="utf-8")).get("params") or {}
        ok = sorted(seen) == [("a.m4a", False), ("b.m4a", True)] and "cpu_only" not in saved_params
        failed += say(ok, f"2 回止まった仕事だけ runner に cpu_only を渡す（保存はしない） {sorted(seen)}")

        # 2. 起動ごと: GPU のモデルで文字にしている最中に止まったら、次の起動で分かる。2 回で GPU を使わない
        home = root / "home"
        home.mkdir()
        messages: list[str] = []
        guard = gpu.CrashGuard(home, messages.append)
        first = guard.startup()
        guard.enter()
        busy = guard.busy_path.exists()
        guard.leave()
        cleared = not guard.busy_path.exists()
        guard.enter()  # ここで落ちたことにする（消さない）
        again = gpu.CrashGuard(home, messages.append)
        second = again.startup()
        again.enter()  # また落ちた
        third = gpu.CrashGuard(home, messages.append)
        safe = third.startup()
        ok = not first and busy and cleared and not second and safe and len(third.crashes) == 2 \
            and not third.busy_path.exists() and any("CPU のモデルだけ" in m for m in messages)
        failed += say(ok, f"GPU で文字にしている間だけ印を置き（{busy}・{cleared}）、印を残して 2 回止まったら、その起動は GPU を使わない"
                          f"（1 回目 {second}・2 回目 {safe}）")
        old = gpu.CrashGuard(home, messages.append, clock=lambda: time.time() + gpu.CrashGuard.WINDOW + 60)
        failed += say(not old.startup(), "6 時間より前に止まった分は数えない（時間がたって起動し直すと、また GPU を使う）")

        # 3. Ensemble: GPU を使わない起動・cpu_only の仕事では GPU のモデルを呼ばない。GPU を使う回は印を置く
        state = GpuState()
        cpu = FakeCpu(state)
        whisper = fake_gpu_engine(main, "whisper", state)
        ensemble = main.Ensemble([cpu, whisper])
        audio = np.zeros(4 * main.RATE, dtype=np.float32)
        saved = (gpu.GUARD, main.log, main.WORD_TIMES)
        try:
            main.log = lambda m: None
            main.WORD_TIMES = False
            gpu.GUARD = gpu.CrashGuard(root / "home2", messages.append)
            (root / "home2").mkdir()
            gpu.GUARD.startup()
            marks: list[bool] = []
            original = whisper.model.transcribe

            def watched(audio, **kwargs):
                marks.append(gpu.GUARD.busy_path.exists())
                return original(audio, **kwargs)

            whisper.model.transcribe = watched
            ensemble.transcribe(audio, [(0.0, 2.0)])
            normal = state.calls
            lines = ensemble.transcribe(audio, [(0.0, 2.0)], cpu_only=True)
            only = state.calls
            gpu.GUARD.safe = True
            ensemble.transcribe(audio, [(0.0, 2.0)])
            safe_calls = state.calls
            ok = normal > 0 and only == normal and safe_calls == normal and marks and all(marks) \
                and not gpu.GUARD.busy_path.exists() and lines and set(lines[0].get("votes", {"haas": 1})) == {"haas"}
            failed += say(ok, f"cpu_only の仕事・GPU を使わない起動では GPU のモデルを呼ばない（GPU の仕事 {normal}→{only}→{safe_calls}）・"
                              "GPU で文字にしている間だけ印がある")
        finally:
            gpu.GUARD, main.log, main.WORD_TIMES = saved
    return failed


# MARK: - GPU に余裕を作る（2026-11-07。8GB の GPU に large-v3 と kotoba を float16 で載せると、空きが約 600MB だった）
# 本物の GPU・nvidia-smi・faster-whisper の読み込み・Ollama は使わない。GPU のメモリーは FakeGpu、faster_whisper.WhisperModel は
# FakeWhisperModel、Ollama はこの PC の中の空いた番号の FakeOllamaGpu、GPU のモデルは --fake-models の作り物（ops.FakeEngine）。


class FakeGpu:
    """作り物の GPU のメモリー（gpu.gpu_memory の代わり）。作り物の WhisperModel が GPU に載ると空きが減り、下ろすと戻る"""

    def __init__(self, total: int = 8192, free: int = 6000) -> None:
        self.total = total
        self.free = free
        self.visible = True   # False なら nvidia-smi で見られないふり

    def read(self, fresh: bool = False, cache: dict | None = None) -> dict | None:
        if not self.visible:
            return None
        return {"used": self.total - self.free, "total": self.total, "free": self.free, "name": "作り物の GPU"}


class FakeWhisperModel:
    """faster_whisper.WhisperModel の作り物（取ってこない・読み込まない）。読み込まれた (モデル, 場所, 形) を覚える。
    GPU に載ると FakeGpu の空きを減らす（large-v3 は CUDA の初めの分も入れて、kotoba は重みだけ）。.model.unload_model() で戻す"""

    made: list[tuple[str, str, str]] = []
    gpu: FakeGpu | None = None
    extra = 0             # 思ったより多く使う分（MB）
    on_load = None        # 読み込むたびに呼ぶもの（読み込み中の様子を見るため）
    LARGE = {"float16": 3500, "int8_float16": 2000, "int8": 2000, "int8_float32": 2000}
    SMALL = {"float16": 1500, "int8_float16": 800, "int8": 800, "int8_float32": 800}

    class Inner:
        def __init__(self, owner) -> None:
            self.owner = owner

        def unload_model(self) -> None:
            self.owner.release()

    def __init__(self, model, device="cpu", compute_type="default", cpu_threads=0, download_root=None, **kwargs) -> None:
        FakeWhisperModel.made.append((str(model), device, compute_type))
        if FakeWhisperModel.on_load is not None:
            FakeWhisperModel.on_load()
        self.used = 0
        if device == "cuda" and FakeWhisperModel.gpu is not None:
            sizes = FakeWhisperModel.SMALL if "kotoba" in str(model) else FakeWhisperModel.LARGE
            self.used = sizes.get(compute_type, 3500) + FakeWhisperModel.extra
            FakeWhisperModel.gpu.free -= self.used
        self.model = FakeWhisperModel.Inner(self)

    def release(self) -> None:
        if self.used and FakeWhisperModel.gpu is not None:
            FakeWhisperModel.gpu.free += self.used
        self.used = 0


class FakeOllamaGpu(BaseHTTPRequestHandler):
    """/api/tags・/api/ps・/api/chat・/api/embed・/api/generate の作り物。頼まれた中身を覚え、載せ方を本物に似せる:
    options の num_gpu が 0 なら CPU だけ（size_vram 0）、付いていなければ GPU（すでに載っていれば、そのまま。本物の Ollama も
    num_gpu を付けない頼みでは読み込み直さない）。keep_alive 0 なら下ろす。bge-m3 は言葉を作れない（generate を断る）"""

    calls: list[tuple[str, dict]] = []
    loaded: dict[str, int] = {}     # 載っているモデル → size_vram（MB のつもり。0 なら CPU だけ）
    lock = threading.Lock()

    def log_message(self, format: str, *args) -> None:
        pass

    def reply(self, body: dict) -> None:
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:
        if self.path == "/api/ps":
            with FakeOllamaGpu.lock:
                models = [{"name": n, "model": n, "size_vram": v} for n, v in FakeOllamaGpu.loaded.items()]
            self.reply({"models": models})
            return
        self.reply({"models": [{"name": "qwen3:8b"}, {"name": "bge-m3:latest"}, {"name": "llama3:latest"}]})

    def do_POST(self) -> None:
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        name = gpu.plain_model(body.get("model", ""))
        options = body.get("options") or {}
        with FakeOllamaGpu.lock:
            FakeOllamaGpu.calls.append((self.path, body))
        if self.path == "/api/generate" and name.startswith("bge-m3"):
            self.reply({"error": '"bge-m3" does not support generate'})
            return
        with FakeOllamaGpu.lock:
            if body.get("keep_alive") == 0:
                FakeOllamaGpu.loaded.pop(name, None)
            elif name not in FakeOllamaGpu.loaded or "num_gpu" in options:
                FakeOllamaGpu.loaded[name] = 0 if options.get("num_gpu") == 0 else 4000
        if self.path == "/api/chat":
            self.reply({"message": {"role": "assistant", "content": "はい"}, "done": True})
        elif self.path == "/api/embed":
            texts = body.get("input")
            count = len(texts) if isinstance(texts, list) else 1
            self.reply({"embeddings": [[1.0, 0.0, 0.0] for _ in range(count)]})
        else:
            self.reply({"done": True})


def run_gpu(main, summary: bool = True) -> int:
    """--check-gpu（--check-v8 にも入れる）: GPU に余裕を作る直し。Whisper を載せる形（合計 10GB 未満は int8_float16・
    config.json の whisper_compute）・載せる前と後の空きの記録・空きが少ないときは載せない・GPU の文字起こしのモデルがあるあいだ
    この PC の Ollama に num_gpu 0（/llm・bge-m3・学び直しのあとの載せ直し・MCP サーバー）・夜の割り当てでは付けない"""
    import semantic

    main.isolate_home()  # 本物の HOME（%LOCALAPPDATA%\LifeLogPC）には書かない
    failed = check_isolated(main) if summary else 0
    fake_gpu = FakeGpu()
    module = types.ModuleType("faster_whisper")
    module.WhisperModel = FakeWhisperModel
    saved = {"memory": gpu.gpu_memory, "prepare": main.prepare_cuda, "types": main.cuda_compute_types,
             "nvidia": main.has_nvidia_gpu, "module": sys.modules.get("faster_whisper"), "log": main.log,
             "before": gpu.BEFORE_LOAD, "after": gpu.AFTER_NIGHT, "state": gpu.STATE_PATH, "llm": main.LLM,
             "key": getattr(main.Handler, "key", None), "engine": getattr(main.Handler, "engine", None),
             "semantic": main.App.semantic, "use_semantic": main.App.use_semantic, "cpu": main._ollama_cpu,
             "settings": dict(ops.O.settings)}
    logged: list[str] = []
    config_path = Path(main.CONFIG)
    try:
        gc.collect()  # ほかの確かめの GPU の作り物が残っていないように
        gpu.gpu_memory = fake_gpu.read
        main.prepare_cuda = lambda: True   # GPU の部品（cuBLAS・cuDNN）を取ってこない
        # RTX 2070 SUPER（Compute Capability 7.5）で ctranslate2 4.8.5 が返したものと同じ
        main.cuda_compute_types = lambda: {"float16", "float32", "int8", "int8_float16", "int8_float32"}
        main.has_nvidia_gpu = lambda: True
        sys.modules["faster_whisper"] = module
        main.log = logged.append
        gpu.BEFORE_LOAD = gpu.AFTER_NIGHT = None
        gpu.STATE_PATH = None
        gpu.take_skipped()
        FakeWhisperModel.gpu = fake_gpu
        for name, check in (("形と要る空き", check_compute_choice),
                            ("読み込み", lambda: check_whisper_load(main, fake_gpu, logged, config_path)),
                            ("Ollama の num_gpu", lambda: check_ollama_num_gpu(main, semantic, logged, config_path))):
            try:
                failed += check()
            except Exception as error:  # noqa: BLE001 — 止まっても NG として数え、残りを確かめる
                failed += say(False, f"{name}の確かめが途中で止まりました: {error!r}")
                clear_gpu()
    finally:
        gpu.gpu_memory = saved["memory"]
        main.prepare_cuda, main.cuda_compute_types, main.has_nvidia_gpu = saved["prepare"], saved["types"], saved["nvidia"]
        if saved["module"] is not None:
            sys.modules["faster_whisper"] = saved["module"]
        else:
            sys.modules.pop("faster_whisper", None)
        main.log = saved["log"]
        gpu.BEFORE_LOAD, gpu.AFTER_NIGHT, gpu.STATE_PATH = saved["before"], saved["after"], saved["state"]
        main.LLM, main.Handler.key = saved["llm"], saved["key"]
        if saved["engine"] is not None:
            main.Handler.engine = saved["engine"]
        main.App.semantic, main.App.use_semantic, main._ollama_cpu = saved["semantic"], saved["use_semantic"], saved["cpu"]
        ops.O.settings.clear()
        ops.O.settings.update(saved["settings"])
        FakeWhisperModel.gpu = None
        FakeWhisperModel.on_load = None
        FakeWhisperModel.extra = 0
        config_path.unlink(missing_ok=True)
        gpu.take_skipped()
        clear_gpu()
    if summary:
        print(("NG の数: " + str(failed)) if failed else "GPU に余裕を作る直し: 全部 OK", flush=True)
    return failed


def clear_gpu() -> None:
    """確かめで GPU に載せたことにしたもの（作り物）を全部下ろす（途中で止まったときも、あとの確かめに残さない）"""
    for engine in list(gpu._ON_GPU):
        try:
            gpu.free_engine(engine)
        except Exception:  # noqa: BLE001
            pass
    with gpu._state_lock:
        gpu._LOADING.clear()
    gc.collect()


def check_compute_choice() -> int:
    """載せる形・要る空き・Ollama の置き場所の決まり（数だけ。モデルも GPU も使わない）"""
    failed = 0
    turing = {"float16", "float32", "int8", "int8_float16", "int8_float32"}   # RTX 2070 SUPER（Compute Capability 7.5）
    pascal = {"float32", "int8", "int8_float32"}                               # Compute Capability 6.1（float16 が遅い）
    cases = {"8GB・既定": (gpu.compute_for({}, 8192, turing)[0], "int8_float16"),
             "10GB ちょうど": (gpu.compute_for({}, 10240, turing)[0], "float16"),
             "24GB・auto": (gpu.compute_for({"whisper_compute": "auto"}, 24576, turing)[0], "float16"),
             "合計が分からない": (gpu.compute_for({}, None, turing)[0], "int8_float16"),
             "8GB に float16 と書いた": (gpu.compute_for({"whisper_compute": "float16"}, 8192, turing)[0], "float16"),
             "8GB に INT8 と書いた": (gpu.compute_for({"whisper_compute": "INT8"}, 8192, turing)[0], "int8"),
             "24GB に int8_float16 と書いた": (gpu.compute_for({"whisper_compute": "int8_float16"}, 24576, turing)[0],
                                              "int8_float16"),
             "おかしな値": (gpu.compute_for({"whisper_compute": "fp8"}, 8192, turing)[0], "int8_float16"),
             "float16 が遅い GPU": (gpu.compute_for({}, 8192, pascal)[0], "int8_float32"),
             "形が分からない GPU": (gpu.compute_for({}, 8192, None)[0], "int8_float16")}
    got = {k: v[0] for k, v in cases.items()}
    ok = all(v[0] == v[1] for v in cases.values()) and "auto にしました" in gpu.compute_for({"whisper_compute": "fp8"}, 8192)[1]
    failed += say(ok, f"Whisper を GPU に載せる形（合計 10GB 未満は int8_float16・config.json の whisper_compute で変える）: {got}")
    spare = [gpu.free_min_mb({}), gpu.free_min_mb({"gpu_free_min_mb": 1500}), gpu.free_min_mb({"gpu_free_min_mb": "x"}),
             gpu.free_min_mb({"gpu_free_min_mb": -5}), gpu.free_min_mb({"gpu_free_min_mb": True})]
    need = {"whisper int8_float16": gpu.need_mb("whisper", "int8_float16"), "whisper float16": gpu.need_mb("whisper", "float16"),
            "whisper int8": gpu.need_mb("whisper", "int8"), "kotoba int8_float16": gpu.need_mb("kotoba", "int8_float16"),
            "kotoba float16": gpu.need_mb("kotoba", "float16"), "haas": gpu.need_mb("haas", "float16")}
    # int8 は、float16 で保存したモデルでは CTranslate2 が int8_float16 にするので、要る空きも同じ
    ok = spare == [1024, 1500, 1024, 0, 1024] and need["whisper int8_float16"] < need["whisper float16"] \
        and need["whisper int8"] == need["whisper int8_float16"] and need["kotoba int8_float16"] < need["kotoba float16"] \
        and need["haas"] == 0 \
        and gpu.need_with_spare("kotoba", {"gpu_free_min_mb": 500}, 8192) == need["kotoba int8_float16"] + 500 \
        and gpu.need_with_spare("whisper", {"whisper_compute": "float16"}, 8192) == need["whisper float16"] + 1024
    failed += say(ok, f"載せて動かすのに要る空き（MB）{need}・残しておく空き（既定・1500・おかしな値・負・true）{spare}")
    modes = [gpu.ollama_gpu_mode(c) for c in ({}, {"ollama_gpu": "auto"}, {"ollama_gpu": "always"}, {"ollama_gpu": True},
                                              {"ollama_gpu": "never"}, {"ollama_gpu": False}, {"ollama_gpu": "?"})]
    extra = [gpu.ollama_options({}, on_gpu=True), gpu.ollama_options({}, on_gpu=False),
             gpu.ollama_options({"ollama_gpu": "always"}, on_gpu=True), gpu.ollama_options({"ollama_gpu": "never"}, on_gpu=False)]
    ok = modes == ["auto", "auto", "always", "always", "never", "never", "auto"] \
        and extra == [{"num_gpu": 0}, {}, {}, {"num_gpu": 0}]
    failed += say(ok, f"この PC の Ollama の置き場所（config.json の ollama_gpu）: {modes}・足す options {extra}")
    return failed


def check_whisper_load(main, fake_gpu: FakeGpu, logged: list[str], config_path: Path) -> int:
    """本物の WhisperEngine・KotobaEngine・load_engines・ops.start を、作り物の faster-whisper と作り物の GPU のメモリーで動かす"""
    failed = 0
    config_path.parent.mkdir(parents=True, exist_ok=True)

    def setting(body: dict | None) -> None:
        if body is None:
            config_path.unlink(missing_ok=True)
        else:
            config_path.write_text(json.dumps(body), encoding="utf-8")

    def fresh(total: int = 8192, free: int = 6000, visible: bool = True) -> None:
        fake_gpu.total, fake_gpu.free, fake_gpu.visible = total, free, visible
        FakeWhisperModel.made.clear()
        FakeWhisperModel.extra = 0
        logged.clear()

    def memory_lines() -> list[str]:
        return [m for m in logged if m.startswith("GPU のメモリー（")]

    def refused(make) -> str | None:
        try:
            make()
        except RuntimeError as error:
            return str(error)
        return None

    # 1. 8GB の GPU・既定（auto）: large-v3 も kotoba も int8_float16 で GPU に。載せる前と後の空きを記録に書く
    setting(None)
    fresh()
    whisper = main.WhisperEngine("auto", "cuda", 2)
    kotoba = main.KotobaEngine("auto", "cuda", 2)
    lines = memory_lines()
    names = gpu.asr_state()["names"]
    ok = FakeWhisperModel.made == [("large-v3", "cuda", "int8_float16"), (main.KOTOBA_REPO, "cuda", "int8_float16")] \
        and whisper.provider == kotoba.provider == "cuda" and whisper.compute == kotoba.compute == "int8_float16" \
        and len(lines) == 4 and "空き 6000 MB／全体 8192 MB" in lines[0] and "約 2000 MB" in lines[1] \
        and "約 800 MB" in lines[3] and names == ["kotoba", "whisper"] and gpu.asr_on_gpu() \
        and any("int8_float16（GPU のメモリーが合計 8192 MB（10GB 未満）" in m for m in logged)
    failed += say(ok, f"8GB の GPU（既定）: {FakeWhisperModel.made}・GPU に載っているもの {names}・空き {fake_gpu.free} MB・"
                      f"記録 {lines}")
    for engine in (whisper, kotoba):
        gpu.free_engine(engine)
    ok = not gpu.asr_on_gpu() and fake_gpu.free == 6000
    failed += say(ok, f"下ろしたら GPU に載っているものは無い（{gpu.asr_state()}）・空きは {fake_gpu.free} MB に戻る")

    # 2. config.json で float16 にすると、whisper のあとの空き（2500 MB）では kotoba が足りないので、GPU にも CPU にも載せない
    setting({"whisper_compute": "float16"})
    fresh()
    forced = main.WhisperEngine("auto", "cuda", 2)
    why = refused(lambda: main.KotobaEngine("auto", "cuda", 2))
    skipped = gpu.take_skipped()
    ok = FakeWhisperModel.made == [("large-v3", "cuda", "float16")] and forced.compute == "float16" \
        and why is not None and "GPU には載せません" in why and skipped == ["kotoba"]
    failed += say(ok, f"whisper_compute を float16 にすると: {FakeWhisperModel.made}・kotoba は「{why}」・あとで載せ直すもの {skipped}")
    gpu.free_engine(forced)
    setting(None)
    fresh(total=24576, free=22000)
    big = main.WhisperEngine("auto", "cuda", 2)
    ok = big.compute == "float16" and FakeWhisperModel.made == [("large-v3", "cuda", "float16")]
    failed += say(ok, f"24GB の GPU は、今までどおり float16: {FakeWhisperModel.made}")
    gpu.free_engine(big)

    # 3. 空きが少ないとき（ほかのソフトが GPU を使っている）: whisper は CPU（large-v3-turbo）、kotoba は載せない。
    #    GPU の時間割が戻すとき（gpu_only）は、CPU にも読み込まない（戻せなかったものとして、あとでやり直す）
    fresh(free=1500)
    small = main.WhisperEngine("auto", "cuda", 2)
    why = refused(lambda: main.KotobaEngine("auto", "cuda", 2))
    skipped = gpu.take_skipped()
    made = list(FakeWhisperModel.made)
    FakeWhisperModel.made.clear()
    only = refused(lambda: main.WhisperEngine("auto", "cuda", 2, gpu_only=True))
    ok = small.provider == "cpu" and small.compute == "int8" and made == [("large-v3-turbo", "cpu", "int8")] \
        and why is not None and "GPU には載せません" in why and skipped == ["kotoba"] and not gpu.asr_on_gpu() \
        and fake_gpu.free == 1500 and any("CPU で動かします" in m for m in logged) \
        and only is not None and "CPU には読み込みません" in only and FakeWhisperModel.made == []
    failed += say(ok, f"空きが 1500 MB のとき: whisper は {made}・kotoba は載せない・GPU は使わない・"
                      f"GPU の時間割が戻すときは CPU にも読み込まない")

    # 4. 載せたら思ったより使って、残しておく 1024 MB より少なくなった: kotoba は下ろす（whisper は残す）
    fresh(free=5200)
    first = main.WhisperEngine("auto", "cuda", 2)
    FakeWhisperModel.extra = 1500
    why = refused(lambda: main.KotobaEngine("auto", "cuda", 2))
    skipped = gpu.take_skipped()
    ok = why is not None and "GPU から下ろしました" in why and fake_gpu.free == 3200 \
        and gpu.asr_state()["names"] == ["whisper"] and skipped == ["kotoba"]
    failed += say(ok, f"載せたあとの空きが足りなければ kotoba を下ろす（空き {fake_gpu.free} MB に戻る・載っているもの "
                      f"{gpu.asr_state()['names']}）")
    gpu.free_engine(first)

    # 5. nvidia-smi で見られないとき: 空きは記録に書かず、軽いほうの形で載せる
    fresh(visible=False)
    blind = main.WhisperEngine("auto", "cuda", 2)
    ok = blind.provider == "cuda" and blind.compute == "int8_float16" and not memory_lines()
    failed += say(ok, f"nvidia-smi で見られないときは、空きを記録に書かずに載せる（{FakeWhisperModel.made}）")
    gpu.free_engine(blind)

    # 6. load_engines: 先に Ollama の LifeLog のモデルを GPU から下ろす口を呼び、読み込み終わるまで「GPU に載っている」とみなす
    order: list[tuple] = []
    during: list[bool] = []
    gpu.BEFORE_LOAD = lambda: order.append((len(FakeWhisperModel.made), gpu.asr_on_gpu()))
    FakeWhisperModel.on_load = lambda: during.append(gpu.asr_on_gpu())
    fresh()
    try:
        ensemble = main.load_engines(["whisper", "kotoba"], 2, "cpu", "auto", "cuda")
    finally:
        gpu.BEFORE_LOAD = None
        FakeWhisperModel.on_load = None
    loaded = [(e.name, e.provider, getattr(e, "compute", None)) for e in ensemble.engines]
    ok = order == [(0, False)] and during == [True, True] \
        and loaded == [("whisper", "cuda", "int8_float16"), ("kotoba", "cuda", "int8_float16")]
    failed += say(ok, f"起動のとき: 読み込む前に Ollama を GPU から下ろす口を呼ぶ {order}・読み込み中も GPU に載っているとみなす "
                      f"{during}・{loaded}")
    ensemble.pool.shutdown(wait=False)
    for engine in ensemble.engines:
        gpu.free_engine(engine)

    # 7. 空きが足りなくて載せなかった kotoba は、GPU の時間割（ops.start）があとで載せる（空きができたら）
    fresh(free=4500)
    ensemble = main.load_engines(["whisper", "kotoba"], 2, "cpu", "auto", "cuda")
    main.Handler.engine = ensemble
    ops.configure(names=["whisper", "kotoba"], whisper="auto", device="cuda", threads=2, fake=False)
    first_names = [e.name for e in ensemble.engines]
    try:
        ops.start(main, home=Path(main.HOME) / "ops-gpu-check", background=False, ollama_url="http://127.0.0.1:9",
                  has_gpu=lambda: False, count_samples=lambda: 0)
        wanted = list(ops.O.gpu.down)
        early = ops.O.gpu.restore()       # whisper のあとの空き 2500 MB では、まだ載せない
        fake_gpu.free += 2000             # ほかのソフトが GPU を空けた
        later = ops.O.gpu.restore()
    finally:
        ops.stop()
    names = [(e.name, e.provider) for e in ensemble.engines]
    ok = first_names == ["whisper"] and wanted == ["kotoba"] and early == [] and later == ["kotoba"] \
        and names == [("whisper", "cuda"), ("kotoba", "cuda")] and any("まだ戻しません" in m for m in logged) \
        and any("空きができたら載せます" in m for m in logged)
    failed += say(ok, f"起動のときに載せなかった kotoba（{first_names}）は、空きが 2500 MB ではまだ載せず {early}、"
                      f"4500 MB になったら載せる {later}: {names}")
    ensemble.pool.shutdown(wait=False)
    for engine in ensemble.engines:
        gpu.free_engine(engine)
    return failed


def check_ollama_num_gpu(main, semantic, logged: list[str], config_path: Path) -> int:
    """作り物の Ollama で: GPU の文字起こしのモデルがあるあいだ（読み込み中も）は num_gpu 0、無ければ付けない"""
    failed = 0
    FakeOllamaGpu.calls = []
    FakeOllamaGpu.loaded = {}
    server = ThreadingHTTPServer(("127.0.0.1", 0), FakeOllamaGpu)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{server.server_address[1]}"
    home = Path(main.HOME)
    listener = None
    fakes: list = []

    def last(path: str) -> dict:
        with FakeOllamaGpu.lock:
            return next((dict(b) for p, b in reversed(FakeOllamaGpu.calls) if p == path), {})

    def unloads() -> list[str]:
        with FakeOllamaGpu.lock:
            return sorted({gpu.plain_model(b.get("model")) for _, b in FakeOllamaGpu.calls if b.get("keep_alive") == 0})

    try:
        config_path.unlink(missing_ok=True)
        main.LLM = main.LocalLLM(url=url, model="qwen3:8b", enabled=True, options=main.ollama_options)
        main.App.use_semantic = True
        embedder = semantic.OllamaEmbedder(url, options=main.ollama_options)
        again = gpu.Ollama(url, logged.append, options=lambda: gpu.ollama_options(main.load_config()))

        # 1. GPU に文字起こしのモデルが無いとき: 今までどおり（num_gpu を付けない）
        clean = not gpu.asr_on_gpu()
        main.LLM.generate("作り物の頼み", False, 20)
        chat = last("/api/chat")
        embedder.embed(["作り物の行"])
        embed = last("/api/embed")
        ok = clean and chat.get("options") == {"num_predict": 20} and "options" not in embed
        failed += say(ok, f"GPU に文字起こしのモデルが無いとき: /api/chat の options {chat.get('options')}・"
                          f"/api/embed の options {embed.get('options')}（付けない）")

        # 2. --fake-models の GPU の作り物（whisper・kotoba）が載っている: /llm・bge-m3・学び直しのあとの載せ直しに num_gpu 0。
        #    下ろすとき（keep_alive 0）には付けない
        fakes = ops.fake_engines()
        main.LLM.generate("作り物の頼み", True, 30)
        chat = last("/api/chat")
        embedder.embed(["作り物の行", "作り物の行2"])
        embed = last("/api/embed")
        again.restore([{"name": "qwen3:8b", "long": True}])
        load = last("/api/generate")
        with FakeOllamaGpu.lock:
            placed = dict(FakeOllamaGpu.loaded)
            FakeOllamaGpu.calls = []
        again.unload_all()
        with FakeOllamaGpu.lock:
            quiet = bool(FakeOllamaGpu.calls) and all("options" not in b for _, b in FakeOllamaGpu.calls)
            emptied = FakeOllamaGpu.loaded == {}
        ok = chat.get("options") == {"num_predict": 30, "num_gpu": 0} and embed.get("options") == {"num_gpu": 0} \
            and load == {"model": "qwen3:8b", "keep_alive": -1, "options": {"num_gpu": 0}} \
            and placed == {"qwen3:8b": 0, "bge-m3:latest": 0} and quiet and emptied
        failed += say(ok, f"GPU の作り物が載っているとき: /api/chat {chat.get('options')}・/api/embed {embed.get('options')}・"
                          f"載せ直し {load.get('options')}（Ollama の置き場所 {placed}。0 は CPU だけ）・下ろすときは付けない {quiet}")

        # 3. 読み込んでいる最中も付ける。下ろしたら付けない
        for engine in fakes:
            gpu.free_engine(engine)
        with gpu.loading("whisper"):
            main.LLM.generate("作り物の頼み", False, 5)
            during = last("/api/chat").get("options")
        main.LLM.generate("作り物の頼み", False, 5)
        after = last("/api/chat").get("options")
        ok = during == {"num_predict": 5, "num_gpu": 0} and after == {"num_predict": 5}
        failed += say(ok, f"読み込んでいる最中 {during}・下ろしたあと {after}")

        # 4. 夜の割り当て: 下ろしたら GPU を使ってよい（昼に CPU だけで載った LifeLog のモデルは下ろし、ほかのソフトのものには触らない）。
        #    朝に戻すときは、先に GPU にいる LifeLog のモデルを下ろし、戻したあとはまた num_gpu 0
        fakes = ops.fake_engines()
        ensemble = main.Ensemble(fakes)
        plan = gpu.GpuPlan(lambda: ensemble, lambda name: ops.FakeEngine(name, "cuda"), logged.append, free_mb=lambda: None)
        gpu.BEFORE_LOAD = main.ollama_make_room
        gpu.AFTER_NIGHT = main.ollama_after_night
        with FakeOllamaGpu.lock:
            FakeOllamaGpu.loaded = {"qwen3:8b": 0, "bge-m3:latest": 0, "llama3:latest": 0}
            FakeOllamaGpu.calls = []
        down = plan.unload("night")
        night_unloads = unloads()
        main.LLM.generate("作り物の頼み", False, 7)
        night = last("/api/chat").get("options")
        with FakeOllamaGpu.lock:
            FakeOllamaGpu.loaded["llama3:latest"] = 3000   # ほかのソフトが GPU に載せたもの
            at_night = dict(FakeOllamaGpu.loaded)
            FakeOllamaGpu.calls = []
        back = plan.restore()
        morning_unloads = unloads()
        main.LLM.generate("作り物の頼み", False, 9)
        day = last("/api/chat").get("options")
        with FakeOllamaGpu.lock:
            placed = dict(FakeOllamaGpu.loaded)
        ok = down == ["whisper", "kotoba"] and night_unloads == ["bge-m3:latest", "qwen3:8b"] \
            and night == {"num_predict": 7} and at_night.get("qwen3:8b") == 4000 \
            and back == ["whisper", "kotoba"] and morning_unloads == ["qwen3:8b"] and day == {"num_predict": 9, "num_gpu": 0} \
            and placed == {"llama3:latest": 3000, "qwen3:8b": 0} \
            and any("GPU から下ろしました" in m and "qwen3:8b" in m for m in logged) \
            and any("CPU だけで載っていた" in m for m in logged)
        failed += say(ok, f"夜の割り当て: 下ろしたら CPU だけで載っていた {night_unloads} を下ろし、付けない {night}（GPU に載る "
                          f"{at_night}）・朝に戻す前に GPU の {morning_unloads} だけ下ろし、戻したら {day}（{placed}）")

        # 5. config.json の ollama_gpu: always なら GPU のモデルがあっても付けない（下ろしもしない）・never なら無くても付ける
        config_path.parent.mkdir(parents=True, exist_ok=True)
        config_path.write_text(json.dumps({"ollama_gpu": "always"}), encoding="utf-8")
        main.LLM.generate("作り物の頼み", False, 3)
        always = last("/api/chat").get("options")
        with FakeOllamaGpu.lock:
            FakeOllamaGpu.loaded["qwen3:8b"] = 4000
            FakeOllamaGpu.calls = []
        main.ollama_make_room()
        kept = unloads() == []
        for engine in list(ensemble.engines):
            gpu.free_engine(engine)
        config_path.write_text(json.dumps({"ollama_gpu": "never"}), encoding="utf-8")
        main.LLM.generate("作り物の頼み", False, 4)
        never = last("/api/chat").get("options")
        config_path.unlink(missing_ok=True)
        ok = always == {"num_predict": 3} and kept and never == {"num_predict": 4, "num_gpu": 0} and not gpu.asr_on_gpu()
        failed += say(ok, f"ollama_gpu が always なら {always}（GPU から下ろさない {kept}）・never なら GPU のモデルが無くても {never}")
        ensemble.pool.shutdown(wait=False)

        # 6. MCP サーバー（別のプロセス）: LifeLog PC が書く <home>/gpu-state.json を読み、bge-m3 に num_gpu 0 を付ける
        import lifelog_mcp

        gpu.STATE_PATH = home / gpu.STATE_FILE
        gpu.note_change()
        tools = lifelog_mcp.make_tools(home, url)
        mcp = tools.index.embedder
        mcp.embed(["作り物の行"])
        off = last("/api/embed").get("options")
        watcher = ops.FakeEngine("whisper", "cuda")
        state_on = gpu.read_state(home)
        mcp.embed(["作り物の行"])
        on = last("/api/embed").get("options")
        gpu.free_engine(watcher)
        state_off = gpu.read_state(home)
        mcp.embed(["作り物の行"])
        off_again = last("/api/embed").get("options")
        gpu.STATE_PATH = None
        ok = off is None and on == {"num_gpu": 0} and off_again is None and state_on.get("asr_gpu") is True \
            and state_on.get("names") == ["whisper"] and state_off.get("asr_gpu") is False \
            and gpu.state_options(home / "どこにも無い", {}) == {}
        failed += say(ok, f"MCP サーバー: gpu-state.json（{state_on.get('names')}）を読んで bge-m3 に {on}・下ろしたら {off_again}・"
                          f"ファイルが無ければ付けない")

        # 7. --fake-models の受け口（/llm・/index）: GPU の作り物があるあいだは num_gpu 0、夜の割り当てで下ろしたら付けない
        gpu.BEFORE_LOAD = gpu.AFTER_NIGHT = None
        main.Handler.key = KEY
        main.Handler.engine = main.Ensemble(ops.fake_engines())
        main.App.semantic = semantic.SemanticIndex(home / "semantic-gpu-check.db",
                                                   semantic.OllamaEmbedder(url, options=main.ollama_options), logged.append)
        listener = main.Server(("127.0.0.1", 0), main.Handler)
        threading.Thread(target=listener.serve_forever, daemon=True).start()
        client = Client(listener.server_address[1])
        headers = {"Content-Type": "application/json"}
        prompt = json.dumps({"prompt": "作り物の頼み", "max_tokens": 11}, ensure_ascii=False).encode("utf-8")
        first = client.call("POST", "/llm", prompt, headers)
        chat = last("/api/chat").get("options")
        items = json.dumps({"items": [{"id": "gpu-check-1", "day": "2026-11-07", "time": 1.0, "text": "作り物の行"}]},
                           ensure_ascii=False).encode("utf-8")
        indexed = client.call("POST", "/index", items, headers)
        embed = last("/api/embed").get("options")
        night_plan = gpu.GpuPlan(lambda: main.Handler.engine, lambda name: ops.FakeEngine(name, "cuda"), logged.append,
                                 free_mb=lambda: None)
        night_plan.unload("night")
        second = client.call("POST", "/llm", prompt, headers)
        chat_night = last("/api/chat").get("options")
        listener.shutdown()
        listener.server_close()
        listener = None
        main.Handler.engine.pool.shutdown(wait=False)
        private = not any("作り物の頼み" in m or "作り物の行" in m for m in logged)
        ok = first[0] == 200 and chat == {"num_predict": 11, "num_gpu": 0} and indexed[0] == 200 \
            and embed == {"num_gpu": 0} and second[0] == 200 and chat_night == {"num_predict": 11} and private
        failed += say(ok, f"--fake-models の受け口: /llm {first[0]} {chat}・/index {indexed[0]} {embed}・夜の割り当てのあと /llm "
                          f"{second[0]} {chat_night}・記録に頼みの文や行の文を書かない {private}")

        # 8. 見守りの画面: モデルの形と、この PC の Ollama の置き場所
        page = dashboard._ops_train({"gpu": {"ollama": gpu.ollama_text({}), "memory": {"used": 4000, "total": 8192}}})
        table = dashboard.render({"engines": [{"name": "whisper", "label": "Whisper large-v3", "provider": "cuda",
                                               "compute": "int8_float16"}], "gpu": {"nvidia": True, "used": True}})
        ok = "この PC の Ollama" in page and "GPU を使ってよい" in page and "cuda（int8_float16）" in table
        failed += say(ok, "見守りの画面に、モデルの形（cuda（int8_float16））と、この PC の Ollama の置き場所を出す")
    finally:
        if listener is not None:
            try:
                listener.shutdown()
                listener.server_close()
            except Exception:  # noqa: BLE001
                pass
        server.shutdown()
        server.server_close()
        gpu.STATE_PATH = None
        gpu.BEFORE_LOAD = gpu.AFTER_NIGHT = None
        config_path.unlink(missing_ok=True)
        for engine in fakes:
            gpu.free_engine(engine)
        gc.collect()
    return failed