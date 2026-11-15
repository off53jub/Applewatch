"""2026-11-15: 時計の音声を渡す口（GET /jobs/<名前>/audio）・PC を使っているあいだ母艦の取り込みを譲る（presence.py）・
PC の負荷を毎日数える（load.py）を確かめる。

    python pc/v17checks_relay.py

本物の GPU・Ollama・ネットワークは使わない（一時のフォルダ・作り物の音声・作り物の時刻・作り物の「最後に触ってからの秒」・
作り物のプロセスの CPU の秒で。本物の HOME（%LOCALAPPDATA%\\LifeLogPC）には書かない）。確かめること:
- 音声の口: 仕事の置き場の音声→残してある音声の順に探す・200・audio/mp4・Content-Length・中身が同じ（数 MB を少しずつ）・
  名前が決まりに合わない・知らない・音声が無いときは 404 {"error": "not found"}・途中で相手が切れても落ちない（数えない）・
  渡したら記録に 1 行と audio_pulled を 1 足す・合言葉が無ければ 401・GET /jobs/<名前> は前と同じ・features に jobaudio
- 譲る: yield_after の読み方（既定 180・false/0/"off" は譲らない・30 秒より短くしない）・in_use（読めなければ譲らない）・
  母艦の取り込みは、重い時間でも使っているあいだは軽いほう（1 回の数が少ない）・記録は 1 時間に 1 回まで・設定で前と同じ
- 数える: 増えた分の出し方（最初は基準だけ・入れ替わりは頭から・減ったら 0）・止める設定・quality-daily.json への足し方
- Windows では、presence.idle_seconds() が数か None・load で自分の CPU の秒が読める（何も変えない）
"""

from __future__ import annotations

import datetime
import http.client
import io
import json
import os
import sys
import tempfile
import threading
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import jobqueue  # noqa: E402
import load  # noqa: E402
import mothersearch  # noqa: E402
import presence  # noqa: E402
import quality  # noqa: E402
from v6checks import say  # noqa: E402

KEY = "check-key"
NAME = "20261115-093000-w.m4a"


class Body(io.BytesIO):
    """broken_after バイトを書いたら、相手が切れたことにする"""

    def __init__(self, broken_after: int | None) -> None:
        super().__init__()
        self.broken_after = broken_after

    def write(self, data) -> int:
        if self.broken_after is not None and self.tell() + len(data) > self.broken_after:
            raise BrokenPipeError("作り物の切断")
        return super().write(data)


class FakeHandler:
    """jobqueue.http_get が使う分だけの作り物の handler"""

    def __init__(self, broken_after: int | None = None) -> None:
        self.status = 0
        self.headers: dict[str, str] = {}
        self.wfile = Body(broken_after)
        self.client_address = ("100.64.0.9", 5555)
        self.close_connection = False
        self.json: dict | None = None

    def send_response(self, status: int) -> None:
        self.status = status

    def send_header(self, key: str, value: str) -> None:
        self.headers[key] = value

    def end_headers(self) -> None:
        pass

    def send_json(self, status: int, body: dict) -> None:
        self.status, self.json = status, body


def make_queue(folder: Path, logged: list[str]) -> jobqueue.JobQueue:
    return jobqueue.JobQueue(folder, lambda path, params, name: ({"lines": []}, {}), logged.append)


def check_audio() -> int:
    failed = 0
    with tempfile.TemporaryDirectory() as folder:
        root = Path(folder)
        logged: list[str] = []
        queue = make_queue(root / "jobs", logged)
        counted: list[tuple[str, int]] = []
        queue.on_pulled = lambda name, size: counted.append((name, size))
        data = os.urandom(2_500_000 + 123)  # 256KB より大きく、きりの悪い大きさ
        queue.audio_path(NAME).write_bytes(data)

        # 1. 仕事の置き場の音声
        handler = FakeHandler()
        jobqueue.http_get(handler, queue, f"/jobs/{NAME}/audio")
        failed += say(handler.status == 200 and handler.headers.get("Content-Type") == "audio/mp4"
                      and handler.headers.get("Content-Length") == str(len(data)) and handler.wfile.getvalue() == data,
                      f"仕事の置き場の音声: 200・audio/mp4・Content-Length {len(data)}・中身が同じ")
        failed += say(len(logged) == 1 and "へ音声を渡しました" in logged[0] and NAME in logged[0] and "100.64.0.9" in logged[0]
                      and "2.4 MB" in logged[0] and counted == [(NAME, len(data))],
                      f"渡したら記録に 1 行・数える口を 1 回呼ぶ（{logged[:1]}）")

        # 2. 名前が合わない・知らない・音声が無い
        results = []
        for name in ["no-such.m4a", "..", "a b", "x" * 100, "名前", ".", "a%2Fb", "%2e%2e"]:
            h = FakeHandler()
            jobqueue.http_get(h, queue, f"/jobs/{name}/audio")
            results.append((h.status, h.json, h.wfile.getvalue()))
        failed += say(all(r == (404, {"error": "not found"}, b"") for r in results),
                      "知らない名前・決まりに合わない名前（.. など）は 404 {\"error\": \"not found\"}")
        h = FakeHandler()
        jobqueue.http_get(h, queue, "/jobs//audio")
        failed += say((h.status, h.json) == (404, {"error": "not found"}), "名前が空でも 404")
        h = FakeHandler()
        jobqueue.http_get(h, queue, "/jobs/audio")
        failed += say(h.status == 404 and (h.json or {}).get("id") == "audio",
                      "/jobs/audio は、名前が audio の仕事の問い合わせのまま（前と同じ）")
        gone = "20261115-100000-w.m4a"
        queue.audio_path(gone).write_bytes(b"x")
        queue.audio_path(gone).unlink()
        h = FakeHandler()
        jobqueue.http_get(h, queue, f"/jobs/{gone}/audio")
        failed += say(h.status == 404, "音声がもう無ければ 404")
        failed += say(len(counted) == 1 and len(logged) == 1, "渡せなかったものは記録にも数にも入れない")

        # 3. 残してある音声（find_kept）
        kept = root / "audio" / "2026-11-15" / "20261115-110000-w.m4a"
        kept.parent.mkdir(parents=True)
        kept_data = os.urandom(300_001)
        kept.write_bytes(kept_data)
        other = "20261115-110000-w.m4a"
        h = FakeHandler()
        jobqueue.http_get(h, queue, f"/jobs/{other}/audio")
        before = h.status
        queue.find_kept = lambda name: kept if name == other else None
        h = FakeHandler()
        jobqueue.http_get(h, queue, f"/jobs/{other}/audio")
        failed += say(before == 404 and h.status == 200 and h.wfile.getvalue() == kept_data,
                      "仕事の置き場に無ければ、残してある音声から（探す口を付ける前は 404）")

        def broken_finder(name):
            raise RuntimeError("作り物")

        queue.find_kept = broken_finder
        h = FakeHandler()
        jobqueue.http_get(h, queue, f"/jobs/{other}/audio")
        failed += say(h.status == 404, "探す口が失敗しても 404（落ちない）")
        queue.find_kept = lambda name: kept if name == other else None
        queue.audio_path(other).write_bytes(b"first")
        h = FakeHandler()
        jobqueue.http_get(h, queue, f"/jobs/{other}/audio")
        failed += say(h.wfile.getvalue() == b"first", "両方にあれば、仕事の置き場の音声が先")
        queue.audio_path(other).unlink()

        # 4. 途中で相手が切れても落ちない・数えない
        n_logged, n_counted = len(logged), len(counted)
        h = FakeHandler(broken_after=600_000)
        try:
            jobqueue.http_get(h, queue, f"/jobs/{NAME}/audio")
            ok = True
        except Exception:  # noqa: BLE001
            ok = False
        failed += say(ok and h.close_connection and len(logged) == n_logged and len(counted) == n_counted,
                      "途中で相手が切れても落ちない（接続を閉じる・渡したことにしない）")

        # 5. 少しずつ送る（1 回 AUDIO_CHUNK まで）・送っているあいだ音声のファイルを開いたままにしない
        #    （開いたままだと、Windows では iPhone が仕事を消したときに、音声を残す先へ動かせない）・大きすぎる音声は渡さない
        sizes: list[int] = []
        moved: list[bool] = []
        h = FakeHandler()
        real_write = h.wfile.write
        source = queue.audio_path(NAME)
        aside = source.with_name(source.name + ".moved")

        def spy_write(chunk) -> int:
            sizes.append(len(chunk))
            if not moved:  # 送っている最中に、音声を動かして戻せるか
                try:
                    os.replace(source, aside)
                    os.replace(aside, source)
                    moved.append(True)
                except OSError:
                    moved.append(False)
            return real_write(chunk)

        h.wfile.write = spy_write
        jobqueue.http_get(h, queue, f"/jobs/{NAME}/audio")
        failed += say(h.wfile.getvalue() == data and sizes and all(0 < n <= jobqueue.AUDIO_CHUNK for n in sizes) and len(sizes) >= 9
                      and moved == [True],
                      f"少しずつ送る（{len(sizes)} 回・1 回 {jobqueue.AUDIO_CHUNK // 1024}KB まで）・送っているあいだも音声を動かせる（{moved}）")
        old_max = jobqueue.AUDIO_MAX
        jobqueue.AUDIO_MAX = 1024
        try:
            h = FakeHandler()
            jobqueue.http_get(h, queue, f"/jobs/{NAME}/audio")
        finally:
            jobqueue.AUDIO_MAX = old_max
        failed += say(h.status == 404 and h.json == {"error": "not found"}, "大きすぎる音声は渡さない（404）")

        # 5b. 音声を残す先へ移すとき、ちょうど読まれている最中（PermissionError）なら、少し待ってやり直す
        tries: list[int] = []

        def flaky(name: str, path: Path, meta: dict) -> None:
            tries.append(1)
            if len(tries) < 3:
                raise PermissionError("作り物の掴み")

        old_keep = queue.keep_audio
        queue.keep_audio = flaky
        n_logged = len(logged)
        try:
            queue._keep_audio(NAME, {})
        finally:
            queue.keep_audio = old_keep
        failed += say(len(tries) == 3 and len(logged) == n_logged, f"移せないときは 3 回までやり直す（{len(tries)} 回・記録は増えない）")

        # 6. 渡した数を quality-daily.json に足す
        home = root / "home"
        today = datetime.date.today().isoformat()
        queue.on_pulled = lambda name, size: quality.add_today({"audio_pulled": 1}, home)
        for _ in range(2):
            jobqueue.http_get(FakeHandler(), queue, f"/jobs/{NAME}/audio")
        days = quality.read_daily(home)["days"]
        failed += say(days.get(today, {}).get("audio_pulled") == 2, f"quality-daily.json の audio_pulled を 1 ずつ足す（{days}）")

        # 7. GET /jobs・GET /jobs/<名前> は前と同じ
        h = FakeHandler()
        jobqueue.http_get(h, queue, "/jobs")
        h2 = FakeHandler()
        jobqueue.http_get(h2, queue, "/jobs/nothing")
        failed += say(h.status == 200 and "jobs" in (h.json or {}) and h2.status == 404 and (h2.json or {}).get("id") == "nothing",
                      "GET /jobs・GET /jobs/<名前> は前と同じ")
        none = FakeHandler()
        jobqueue.http_get(none, None, f"/jobs/{NAME}/audio")
        failed += say(none.status == 503, "仕事の受け口が無いときは前と同じ 503")
    return failed


def check_audio_http(main) -> int:
    """本物の受け口（作り物のモデル・一時の HOME）に、合言葉つきで問い合わせる"""
    failed = 0
    main.isolate_home()
    import ops

    logged: list[str] = []
    saved = (main.App.jobs, getattr(main.Handler, "engine", None), getattr(main.Handler, "key", None), main.log)
    server = None
    try:
        main.log = logged.append
        main.Handler.key = KEY
        main.Handler.engine = main.Ensemble(ops.fake_engines())
        main.App.jobs = None
        without = "jobaudio" in main.features()
        folder = Path(main.HOME) / "jobs-v17"
        main.App.jobs = queue = make_queue(folder, logged)
        data = os.urandom(700_000)
        queue.audio_path(NAME).write_bytes(data)
        with_jobs = "jobaudio" in main.features()
        server = main.Server(("127.0.0.1", 0), main.Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        port = server.server_address[1]

        def get(path: str, token: str | None = KEY) -> tuple[int, dict, bytes]:
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
            try:
                conn.request("GET", path, headers={"Authorization": f"Bearer {token}"} if token else {})
                response = conn.getresponse()
                return response.status, dict(response.getheaders()), response.read()
            finally:
                conn.close()

        status, headers, body = get(f"/jobs/{NAME}/audio")
        failed += say(status == 200 and headers.get("Content-Type") == "audio/mp4" and body == data
                      and headers.get("Content-Length") == str(len(data)), "本物の受け口: 200・audio/mp4・中身が同じ")
        status, _, body = get(f"/jobs/{NAME}/audio", token=None)
        failed += say(status == 401 and data[:50] not in body, "合言葉が無ければ 401（音声は出ない）")
        status, _, body = get(f"/jobs/{NAME}/audio", token="wrong-key")
        failed += say(status == 401, "合言葉が違えば 401")
        status, _, body = get("/jobs/nothing-here.m4a/audio")
        failed += say(status == 404 and json.loads(body) == {"error": "not found"}, "知らない名前は 404 {\"error\": \"not found\"}")
        status, _, body = get(f"/w/jobs/{NAME}/audio")
        failed += say(status == 404, "時計の外の道の形（/w/…）では出さない")
        failed += say(with_jobs and not without, "features に jobaudio（仕事の受け口があるときだけ）")
    finally:
        if server is not None:
            server.shutdown()
            server.server_close()
        main.App.jobs, main.Handler.engine, main.Handler.key, main.log = saved
    return failed


def check_presence() -> int:
    failed = 0
    failed += say(presence.yield_after({}) == 180.0 and presence.yield_after(None) == 180.0, "yield_when_used が無ければ 180 秒")
    table = {False: None, 0: None, "off": None, "OFF": None, "0": None, "false": None, 600: 600.0, "90": 90.0,
             10: 30.0, 29.9: 30.0, 30: 30.0, True: 180.0, "ふしぎ": 180.0, -5: None, 1.5: 30.0}
    wrong = {}
    for key, want in table.items():
        got = presence.yield_after({"yield_when_used": key})
        if got != want:
            wrong[repr(key)] = got
    failed += say(not wrong, f"yield_when_used: false・0・\"off\" は譲らない・数はその秒（30 より短くしない）（ちがい {wrong}）")
    failed += say(presence.in_use({}, 10.0) and presence.in_use({}, 179.9) and not presence.in_use({}, 180.0)
                  and not presence.in_use({}, 3600.0), "最後に触ってから 180 秒より短ければ使っている")
    failed += say(not presence.in_use({"yield_when_used": False}, 1.0) and not presence.in_use({"yield_when_used": "off"}, 0.0),
                  "譲らない設定なら、触っていても使っているとしない（前と同じ）")
    failed += say(presence.in_use({"yield_when_used": 600}, 599.0) and not presence.in_use({"yield_when_used": 600}, 601.0),
                  "設定の秒に従う")
    saved = presence.idle_seconds
    try:
        presence.idle_seconds = lambda: None
        failed += say(presence.in_use({}) is False, "最後に触った時刻が読めなければ、使っているとしない（前と同じ）")
        presence.idle_seconds = lambda: 5.0
        failed += say(presence.in_use({}) is True, "idle を渡さなければ idle_seconds() を読む")
    finally:
        presence.idle_seconds = saved
    got = presence.idle_seconds()
    if os.name == "nt":
        failed += say(got is None or (isinstance(got, float) and 0 <= got < 10 * 365 * 86400),
                      f"Windows で idle_seconds() が数か None（{None if got is None else round(got, 1)}）")
    else:
        failed += say(got is None, "Windows のほかでは None")
    return failed


class FakeEmbedder:
    model = "fake"

    def embed(self, texts):
        import numpy as np

        out = np.zeros((len(texts), 8), dtype=np.float32)
        for i, text in enumerate(texts):
            out[i, sum(map(ord, text)) % 8] = 1.0
        return out

    def models(self):
        return [self.model]


def check_mothersearch() -> int:
    failed = 0
    noon = datetime.datetime(2026, 11, 15, 10, 0)      # 重い時間（日曜の朝）
    evening = datetime.datetime(2026, 11, 15, 19, 0)   # 重い時間の外
    state = {"now": noon, "idle": 5.0, "config": {}}
    logged: list[str] = []
    with tempfile.TemporaryDirectory() as folder:
        root = Path(folder)

        def build(name: str) -> mothersearch.MotherIndex:
            return mothersearch.MotherIndex(root / f"{name}.db", FakeEmbedder(), lambda: root / "base", logged.append,
                                            clock=lambda: state["now"], config=lambda: state["config"],
                                            idle=lambda: state["idle"])

        index = build("a")
        # 1. 重い時間かどうかの決まり
        state.update(now=noon, idle=5.0, config={})
        using = index.heavy()
        state["idle"] = 600.0
        resting = index.heavy()
        state.update(idle=5.0, config={"yield_when_used": False})
        off = index.heavy()
        state.update(idle=None, config={})
        unknown = index.heavy()
        state.update(now=evening, idle=600.0, config={})
        outside = index.heavy()
        state.update(now=evening, idle=1.0)
        outside_using = index.heavy()
        failed += say((using, resting, off, unknown, outside, outside_using) == (False, True, True, True, False, False), "重い時間でも、使っているあいだは軽いほう・触らなくなれば戻る・設定 false／読めないときは前と同じ・時間の外は軽い（" + str((using, resting, off, unknown, outside, outside_using)) + "）")
        # 2. 記録は譲り始めたとき 1 行・1 時間に 1 回まで
        logged.clear()
        index = build("b")
        state.update(now=noon, idle=5.0, config={})
        for minutes in (0, 1, 30, 59):
            state["now"] = noon + datetime.timedelta(minutes=minutes)
            index.heavy()
        one = len(logged)
        state["now"] = noon + datetime.timedelta(minutes=61)
        index.heavy()
        two = len(logged)
        index.heavy(record=False)
        failed += say(one == 1 and two == 2 and len(logged) == 2 and "ゆっくり" in logged[0] and "3 分で戻ります" in logged[0]
                      and '"yield_when_used": false' in logged[0], f"記録は 1 時間に 1 回まで（{one}→{two} 行）: {logged[:1]}")
        failed += say(index.status()["heavy_now"] is False and len(logged) == 2,
                      "status の heavy_now も、使っているあいだは False（記録は増やさない）")
        # 3. 1 回に置く数: 使っているあいだは軽い（SMALL_BUDGET）・使っていなければ重い
        base = root / "base"
        for day in range(1, 31):
            body = "# 見本\n\n" + "\n".join(f"- 十一月{day}日の{i}番目の話。" + f"{day:02d}{i}あいうえおかきくけこ" * 30 for i in range(3))
            path = base / "archive" / "lifelog-pc" / "2026" / "10" / f"{day:02d}.md"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(body, encoding="utf-8")
        state.update(now=noon, idle=5.0, config={})
        light = build("c").step()
        state["idle"] = 900.0
        heavy = build("d").step()
        failed += say(light["embedded"] < heavy["embedded"] and light["pending"] > 0 and heavy["pending"] == 0
                      and light["embedded"] <= mothersearch.SMALL_BUDGET + 6,
                      f"使っているあいだは少しずつ（{light['embedded']} 個・残り {light['pending']}）、触らなければ前と同じ（{heavy['embedded']} 個）")
        # 4. 譲る判断を使うのは母艦の取り込みだけ（文字起こしは譲らない）
        here = Path(__file__).resolve().parent
        users = sorted(p.name for p in here.glob("*.py")
                       if p.name not in ("presence.py", "load.py") and not p.name.startswith("v")
                       and "presence." in p.read_text(encoding="utf-8").replace("presence.py", ""))
        failed += say(users == ["mothersearch.py"], f"譲る判断（presence）を使うのは mothersearch だけ（文字起こしは譲らない）: {users}")
    return failed


def check_load() -> int:
    failed = 0
    # 1. 増えた分の出し方
    first = {10: (100, 5.0), 11: (200, 2.0)}
    failed += say(load.delta(None, first) == 0.0, "最初の見回りは基準を覚えるだけ（0）")
    second = {10: (100, 7.5), 11: (200, 2.0)}
    failed += say(load.delta(first, second) == 2.5, "同じプロセスは増えた分だけ")
    swapped = {10: (999, 1.25), 11: (200, 2.0)}
    failed += say(load.delta(first, swapped) == 1.25, "pid が同じでも始まった時刻が違えば、新しいプロセスの分を頭から足す")
    fresh = {10: (100, 7.5), 12: (300, 0.75)}
    failed += say(load.delta(second, fresh) == 0.75, "新しく増えたプロセスは頭から・終わったものは足さない")
    failed += say(load.delta({10: (100, 9.0)}, {10: (100, 3.0)}) == 0.0, "CPU の秒が減って見えても 0（マイナスにしない）")
    failed += say(load.delta({10: (1, 1.0)}, {}) == 0.0, "プロセスが無ければ 0")
    # 2. 見回り
    added: list[dict] = []
    meter = load.Meter()
    got1 = meter.tick({}, own=10.0, idle=600.0, ollama={1: (1, 4.0)}, adder=added.append)
    got2 = meter.tick({}, own=10.5, idle=10.0, ollama={1: (1, 6.0), 2: (9, 1.0)}, adder=added.append)
    failed += say(got1 == {} and got2 == {"cpu_self_s": 0.5, "cpu_ollama_s": 3.0, "yield_min": 1} and added == [got2],
                  f"最初は基準だけ・次から自分と Ollama の増えた分・使っていれば yield_min 1（{got2}）")
    got3 = meter.tick({}, own=10.5, idle=600.0, ollama={1: (1, 6.0), 2: (9, 1.0)}, adder=added.append)
    failed += say(got3 == {} and len(added) == 1, "増えなければ何も足さない")
    got4 = meter.tick({}, own=11.0, idle=600.0, ollama={}, adder=added.append)
    got5 = meter.tick({}, own=11.0, idle=600.0, ollama={1: (1, 6.5), 2: (9, 1.0)}, adder=added.append)
    failed += say(got4 == {"cpu_self_s": 0.5} and got5 == {"cpu_ollama_s": 0.5},
                  "読めなかった回があっても、同じプロセスが戻れば増えた分だけ（頭から足し直さない）")
    off = meter.tick({"load_meter": False}, own=99.0, idle=1.0, ollama={1: (1, 99.0)}, adder=added.append)
    again = meter.tick({}, own=100.0, idle=600.0, ollama={1: (1, 100.0)}, adder=added.append)
    failed += say(off == {} and again == {} and len(added) == 3, "load_meter false なら足さず、戻したときは基準から")
    failed += say(not load.enabled({"load_meter": False}) and not load.enabled({"load_meter": "off"}) and load.enabled({})
                  and load.enabled({"load_meter": True}), "load_meter の読み方")

    def broken_list():
        raise OSError("作り物")

    failed += say(load.read_ollama(lambda: [(5, "a"), (6, "b")], lambda pid: (1, 2.0) if pid == 5 else None) == {5: (1, 2.0)}
                  and load.read_ollama(broken_list) == {}, "読めなかったプロセスは入れない・一覧が読めなければ空")
    # 3. quality-daily.json に足す
    with tempfile.TemporaryDirectory() as folder:
        home = Path(folder)
        moment = datetime.datetime(2026, 11, 15, 12, 0)
        quality.update_day(home, "2026-11-15", {"judge_calls": 7, "cpu_self_s": 1.25}, now=moment.date())
        quality.add_today({"cpu_self_s": 0.333, "cpu_ollama_s": 2.0, "yield_min": 1}, home, now=moment)
        quality.add_today({"cpu_self_s": 0.333, "yield_min": 1, "audio_pulled": 1}, home, now=moment)
        day = quality.read_daily(home)["days"]["2026-11-15"]
        failed += say(day == {"judge_calls": 7, "cpu_self_s": 1.91, "cpu_ollama_s": 2.0, "yield_min": 2, "audio_pulled": 1},
                      f"quality-daily.json: ほかの項目を残して足す・小数は丸める（{day}）")
        (home / quality.FILE).write_text("壊れた", encoding="utf-8")
        quality.add_today({"yield_min": 1}, home, now=moment)
        failed += say(quality.read_daily(home)["days"]["2026-11-15"] == {"yield_min": 1}, "壊れていれば作り直す")
    saved_home = quality.State.home
    try:
        quality.State.home = None
        failed += say(quality.add_today({"yield_min": 1}) is False, "置き場所が分からなければ足さない")
    finally:
        quality.State.home = saved_home
    # 4. 本物の読み取り
    mine = load.read_cpu(os.getpid())
    if os.name == "nt":
        failed += say(mine is not None and mine[1] > 0 and mine[0] > 0,
                      f"Windows で自分の CPU の秒が GetProcessTimes で読める（{None if mine is None else round(mine[1], 2)} 秒）")
        probe = load.Meter()
        probe.tick({}, ollama={})
        sum(i * i for i in range(2_000_000))
        values = probe.tick({}, ollama={})
        failed += say(values.get("cpu_self_s", 0) > 0, "自分の CPU の秒（time.process_time）の増えた分を数えられる")
    else:
        failed += say(mine is None, "Windows のほかでは Ollama の分は読まない")
    return failed


def main() -> int:
    import lifelog_pc

    failed = check_audio() + check_audio_http(lifelog_pc) + check_presence() + check_mothersearch() + check_load()
    print("ぜんぶ OK" if not failed else f"NG が {failed} 個")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
