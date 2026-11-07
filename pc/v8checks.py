"""LifeLog PC 版 8 の機能を確かめる（--check-v8 から呼ぶ。本物のモデル・本物の APNs は使わない）。
決まりは docs/v8-latency.md。一時フォルダの HOME と作り物のモデルで、次を確かめる:

- 時間: POST /jobs の chunk_start・chunk_end・arrived・sent を読み、GET と待ち合わせの答えに "timing" を付ける
- 待ち合わせ（wait=1）: 空白が届く・でき上がりで答えが来る・上限（短くして試す）で pending・切れたとき・閉じるとき
- 通知: 待ち合わせで渡した仕事には「できた」の通知を送らない。渡せなかった仕事だけ送る
- 下書き: haas・reazon だけの下書きが先にでき、GET で見える。haas・reazon は2回読まない。下書きに失敗しても多数決は続く
- 新しい区切りから: 待っているものが2つ以上なら、新しく受けたものから
- 見守りの画面・実機の様子の時間の行
- 確かめるときは、本物の HOME に書かない
"""

from __future__ import annotations

import json
import re
import socket
import tempfile
import threading
import time
from pathlib import Path
from urllib.parse import quote

import dashboard
import diag
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
