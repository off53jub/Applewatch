"""強化案 50・51・52（2026-11-15。中身は livecoach.py）を確かめる。

    python pc/v15checks_live.py            # 作り物の Claude・一時のフォルダ（CI と同じ）
    python pc/v15checks_live.py --measure  # この PC の本物の記録で遅れを測る（下の measure。本物の Claude に 1 回頼む）

本物の鍵・ネット・母艦は使わない（--measure のときだけ本物の HOME を読み、Claude に 1 回頼む）。確かめること:
- 接地: quote が会議の行（番号の行と前後1行、無ければ全部）に無いものは捨てる・同じものは 1 つ・各 5 つまで
- 会議モード: 始める・同じ始まりは続き（行を消さない）・別の始まりは新しい会議・15 分 届かなければ終わり・会議の時刻を残す
- 区切りの文: 会議モードの外・始まりより前の区切り・同じ文の区切りはためない。「自分」と分けた行を自分にする
- 更新: 1 分に 1 回まで・Claude を使わない設定と職場の設定では頼まない・用途の上限（409）でも止まらない・遅れを数える
- GET /meeting-live?since=（版が同じなら中身を省く）・POST /meeting-live/state（おかしな中身は 400）・合言葉
- /transcribe の答えの行が会議の相棒にたまる（作り物のモデル）
- GET /coach・/tension（形を確かめ、おかしな行を落とす・無ければ available false）
- POST /health/hr（分ごとに母艦の archive/health-hr へ・同じ分は新しい値・古い・先の時刻・おかしな値は落とす）
- 記録（log.txt）に会議の文・宿題の文を書かない
"""

from __future__ import annotations

import json
import sys
import tempfile
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import claude  # noqa: E402
import livecoach  # noqa: E402
import ops  # noqa: E402
from v6checks import KEY, Client, say, tone_wav  # noqa: E402
from v11checks import FakeClaude, put_config, put_key, reset_files  # noqa: E402

SECRET_LINE = "見本の秘密の会議の文で予算は来月までに決めます"
SECRET_TASK = "見本の秘密の宿題"


class Clock:
    def __init__(self) -> None:
        self.now = time.time()

    def __call__(self) -> float:
        return self.now


def answer(decided=None, homework=None, unasked=None) -> str:
    return json.dumps({"decided": decided or [], "homework": homework or [], "unasked": unasked or []}, ensure_ascii=False)


def check_ground() -> int:
    failed = 0
    lines = [{"n": 0, "t": 1.0, "text": "では予算は来月までに決めます"}, {"n": 1, "t": 2.0, "text": "資料は私が金曜に送ります"},
             {"n": 2, "t": 3.0, "text": "担当はまだ決まっていません"}]
    data = {"decided": [{"text": "予算は来月まで", "line": 0, "quote": "予算は来月までに"},
                        {"text": "作り話", "line": 0, "quote": "そんなことは言っていない"},
                        {"text": "予算は来月まで", "line": 0, "quote": "予算は来月"}],
            "homework": [{"text": "資料を金曜に送る", "line": 2, "quote": "私が金曜に送ります"}],
            "unasked": [{"text": "担当は誰か", "line": 99, "quote": "担当はまだ"},
                        {"text": "短い", "line": 2, "quote": "担"}]}
    kept = livecoach.ground(data, lines)
    failed += say([i["text"] for i in kept["decided"]] == ["予算は来月まで"], "接地: 行に無い quote と同じ項目を捨てる")
    failed += say(len(kept["homework"]) == 1 and kept["homework"][0]["at"] == 3.0, "接地: 前後1行の quote は残す")
    failed += say(len(kept["unasked"]) == 1 and kept["unasked"][0]["at"] is None, "接地: 番号が外れても、会議の行にあれば残す")
    many = {"decided": [{"text": f"決めたこと{i}", "line": 0, "quote": "予算は来月まで"} for i in range(9)]}
    failed += say(len(livecoach.ground(many, lines)["decided"]) == livecoach.ITEMS_PER_KIND, "接地: 各 5 つまで")
    failed += say(livecoach.ground("おかしな答え", lines) == {k: [] for k in livecoach.KINDS}, "接地: おかしな答えは空")
    return failed


def check_live(home: Path) -> int:
    failed = 0
    reset_files()
    put_key()
    fake = FakeClaude()
    claude.CLIENT_FACTORY = fake.factory
    clock = Clock()
    logged: list[str] = []
    live = livecoach.Live(home, logged.append, clock)
    failed += say(live.feed([{"start": 0, "text": "会議の外の文"}]) == 0, "会議モードの外の区切りはためない")
    start = clock.now
    stamp = claude.now_iso(start)
    got = live.set_state({"on": True, "start": stamp, "title": "見本の定例", "claude": True, "work": True, "work_ok": True})
    failed += say(got.get("on") is True and live.active(), "会議モードを始める")
    early = live.feed([{"start": 0, "text": "前の区切りの文"}], start + 5, chunk_start=start - 600)
    lines = [{"start": 1.0, "text": SECRET_LINE}, {"start": 4.0, "text": "資料は私が金曜に送ります"}]
    added = live.feed(lines, start + 30, chunk_start=start + 5, chunk_end=start + 25)
    again = live.feed(lines, start + 31)
    failed += say(early == 0 and added == 2 and again == 0, f"始まりより前・同じ文の区切りはためない（{early}・{added}・{again}）")
    live.set_state({"on": True, "start": stamp, "mine": [{"at": stamp, "text": "資料は私が金曜に送ります"}]})
    failed += say(len(live.s["lines"]) == 2 and live.s["lines"][1]["me"] and not live.s["lines"][0]["me"],
                  "同じ始まりは続き（行を消さない）・「自分」と分けた行を自分にする")
    fake.text = answer(decided=[{"text": "予算は来月まで", "line": 0, "quote": "予算は来月までに決めます"}],
                       homework=[{"text": SECRET_TASK, "line": 1, "quote": "金曜に送ります"},
                                 {"text": "作り話", "line": 1, "quote": "言っていないこと"}])
    clock.now = start + 40
    result = live.update()
    sent = json.loads(fake.calls[-1][1]["messages"][0]["content"]) if fake.calls else {}
    speakers = [r["speaker"] for r in sent.get("lines", [])]
    view = live.view()
    failed += say(result["asked"] == 1 and view["counts"] == {"decided": 1, "homework": 1, "unasked": 0}
                  and view["version"] == 1 and view["latest"][0].startswith("宿 "),
                  f"更新: 接地したものだけ・新しいものが latest に（{view.get('counts')}）")
    failed += say(speakers == ["?", "自分"] and sent.get("new_from") == 0 and fake.calls[-1][1]["model"] == claude.TIERS["light"],
                  "Claude には「自分」「?」の話し手・新しい行の番号・軽いモデル")
    failed += say(view.get("delay", {}).get("last") == 10.0 and view["delay"]["n"] == 1,
                  f"遅れ: 受け取ってから更新し終えるまで（{view.get('delay')}）")
    calls = len(fake.calls)
    live.feed([{"start": 0, "text": "次の区切りの文です"}], start + 50, chunk_start=start + 45)
    clock.now = start + 60
    live.update()
    failed += say(len(fake.calls) == calls, "1 分に 1 回まで（前の更新から 60 秒たつまで頼まない）")
    clock.now = start + 101
    fake.text = answer(decided=[{"text": "予算は来月まで", "line": 0, "quote": "予算は来月までに決めます"}])
    live.update()
    view2 = live.view(since="1")
    same = live.view(since=str(view2["version"]))
    failed += say(len(fake.calls) == calls + 1 and view2["changed"] and same["changed"] is False and "decided" not in same,
                  "60 秒たてば頼む・版が同じなら中身を省く")
    live.set_state({"on": True, "start": stamp, "claude": False})
    live.feed([{"start": 0, "text": "Claude を使わないときの文"}], start + 110)
    clock.now = start + 170
    live.update()
    failed += say(len(fake.calls) == calls + 1 and "Claude" in (live.view().get("reason") or ""),
                  "アプリの設定で Claude を使わないなら頼まない（わけを出す）")
    live.set_state({"on": True, "start": stamp, "claude": True, "work": True, "work_ok": False})
    clock.now = start + 240
    live.update()
    failed += say(len(fake.calls) == calls + 1 and "職場" in (live.view().get("reason") or ""),
                  "職場の時間で「職場の会話も Claude で」がオフなら頼まない")
    put_config({"daily_caps": {"meeting-live": 0.000001}})
    live.set_state({"on": True, "start": stamp, "claude": True, "work": False, "work_ok": False})
    clock.now = start + 300
    live.update()
    failed += say(len(fake.calls) == calls + 1 and live.active(), "1日の上限（409）でも止まらず、頼まない")
    put_config({})
    clock.now = start + 300 + livecoach.QUIET_OFF + 5
    failed += say(not live.active() and live.view()["on"] is False, "15 分 届かなければ会議モードは終わり")
    sessions = json.loads((home / "meetinglive" / "sessions.json").read_text(encoding="utf-8"))
    failed += say(len(sessions) == 1 and sessions[0]["end"] is not None and abs(sessions[0]["start"] - start) < 1,
                  "会議の始まりと終わりを sessions.json に残す")
    clock.now += livecoach.KEEP_AFTER + 5
    failed += say(live.view() == {"available": True, "on": False, "version": live.s["version"], "changed": False},
                  "終わって 30 分たてば中身を出さない")
    reborn = livecoach.Live(home, logged.append, clock)
    failed += say(reborn.s["version"] == live.s["version"] and len(reborn.s["lines"]) == len(live.s["lines"]),
                  "起動し直しても続きから（state.json）")
    second = clock.now
    live.set_state({"on": True, "start": claude.now_iso(second)})
    failed += say(live.s["lines"] == [] and live.s["version"] == 0, "別の始まりは新しい会議（前の行は持ち越さない）")
    for bad in ({"on": "yes"}, {"on": True, "start": "きのう"}, {"on": True, "claude": 1}, [], {"on": True, "mine": "x"}):
        try:
            live.set_state(bad)
            failed += say(False, f"おかしな中身は断る: {bad!r}")
        except ValueError:
            pass
    text = "\n".join(logged)
    failed += say(SECRET_LINE not in text and SECRET_TASK not in text and "予算" not in text, "記録に会議の文・宿題を書かない")
    return failed


def check_feeds(base: Path) -> int:
    failed = 0
    failed += say(livecoach.read_coach(base).get("available") is False, "GET /coach: 無ければ available false")
    failed += say(livecoach.read_tension(base).get("available") is False, "GET /tension: 無ければ available false")
    (base / "state").mkdir(parents=True, exist_ok=True)
    coach = {"version": 1, "generated_at": "2026-11-15T22:30:00+09:00", "day": "2026-11-15",
             "good": {"text": "結論から言うと、来週で大丈夫です", "why": "先に結論", "time": "2026-11-15T10:00:00+09:00",
                      "audio": "20261115-100000.m4a", "offset": 12.5, "end": 15.0},
             "improve": {"text": "えっと、あの、たぶん", "why": "言いよどみ", "better": "来週に出します", "time": "2026-11-15T11:00:00+09:00",
                         "audio": "../../秘密.m4a", "offset": 3, "end": 1},
             "week": {"from": "2026-11-09", "to": "2026-11-15", "lines": 300, "conclusion_first": 0.42, "judged": 30,
                      "filler_per_min": 2.5, "questions": 12, "talk_share_meetings": 1.7, "meetings": 2, "meeting_source": "mode"},
             "rehearse": {"seeds": 3, "first": "見本の練習の題材"}}
    (base / livecoach.COACH).write_text(json.dumps(coach, ensure_ascii=False), encoding="utf-8")
    got = livecoach.read_coach(base)
    failed += say(got["available"] and got["good"]["audio"] == "20261115-100000.m4a" and got["good"]["offset"] == 12.5
                  and got["improve"]["audio"] is None and got["improve"]["offset"] is None
                  and got["week"]["talk_share_meetings"] is None and got["week"]["conclusion_first"] == 0.42
                  and got["rehearse"]["seeds"] == 3, "GET /coach: 音声の名前・位置・割合を確かめる（おかしなものは落とす）")
    tension = {"version": 1, "generated_at": "2026-11-15T23:00:00+09:00", "from": "2026-11-09", "to": "2026-11-15",
               "source": "minute",
               "items": [{"id": "t-1", "day": "2026-11-15", "start": "2026-11-15T10:00:00+09:00", "end": None, "peak_bpm": 112,
                          "baseline_bpm": 64, "conversation": {"title": "見本の会議", "people": ["見本さん", 3], "place": "会議室"}},
                         {"id": "t-2", "day": "きのう", "start": "2026-11-15T10:00:00+09:00", "peak_bpm": 112, "baseline_bpm": 64},
                         {"id": "t-3", "day": "2026-11-15", "start": "2026-11-15T10:00:00+09:00", "peak_bpm": 999, "baseline_bpm": 64}],
               "by_person": [{"name": "見本さん", "times": 2, "of": 5}, {"name": "", "times": 1}],
               "by_topic": [{"word": "予算", "times": 3}]}
    (base / livecoach.TENSION).write_text(json.dumps(tension, ensure_ascii=False), encoding="utf-8")
    got = livecoach.read_tension(base)
    failed += say(got["available"] and [i["id"] for i in got["items"]] == ["t-1"] and got["items"][0]["delta"] == 48
                  and got["items"][0]["conversation"]["people"] == ["見本さん"] and got["by_person"] == [{"name": "見本さん", "times": 2, "of": 5}]
                  and got["source"] == "minute", "GET /tension: おかしな行を落とす・上がった幅を足す")
    now = time.time()
    t0 = int(now - 3600) // 60 * 60
    body = {"samples": [{"t": t0, "bpm": 70}, {"t": t0 + 60, "bpm": 300}, {"t": now - 30 * 86400, "bpm": 70},
                        {"t": now + 3600, "bpm": 70}, {"t": True, "bpm": 70}, "x"],
            "steps": [{"t": t0, "n": 12}]}
    days = livecoach.parse_hr(json.dumps(body).encode("utf-8"), now)
    failed += say(sum(len(s["hr"]) for s in days.values()) == 1 and sum(len(s["steps"]) for s in days.values()) == 1,
                  "心拍: 古い・先の時刻・おかしな値は落とす")
    livecoach.store_hr(base, days, now)
    later = livecoach.parse_hr(json.dumps({"samples": [{"t": t0, "bpm": 75}, {"t": t0 + 120, "bpm": 80}]}).encode("utf-8"), now)
    livecoach.store_hr(base, later, now)
    day = time.strftime("%Y-%m-%d", time.localtime(t0))
    y, m, d = day.split("-")
    saved = json.loads((base / livecoach.HR_DIR / y / m / f"{d}.json").read_text(encoding="utf-8"))
    failed += say(len(saved["hr"]) == 2 and saved["hr"][time.strftime("%H:%M", time.localtime(t0))] == 75
                  and len(saved["steps"]) == 1 and saved["day"] == day, "心拍: 分ごとに足す（同じ分は新しい値・歩数は残す）")
    for bad in (b"not json", json.dumps({"samples": "x"}).encode("utf-8"),
                json.dumps({"samples": [{"t": now, "bpm": 70}] * (livecoach.HR_SAMPLES + 1)}).encode("utf-8")):
        try:
            livecoach.parse_hr(bad, now)
            failed += say(False, "心拍: おかしな中身は断る")
        except ValueError:
            pass
    return failed


def check_http(main) -> int:
    failed = 0
    reset_files()
    put_key()
    fake = FakeClaude()
    claude.CLIENT_FACTORY = fake.factory
    logged: list[str] = []
    saved = (getattr(main.Handler, "engine", None), getattr(main.Handler, "key", None), main.log, livecoach.L)
    old_config = main.load_config()
    with tempfile.TemporaryDirectory() as folder:
        base = Path(folder)
        server = None
        try:
            main.log = logged.append
            main.Handler.key = KEY
            main.Handler.engine = main.Ensemble(ops.fake_engines())
            config = dict(old_config)
            config["lifelog_home"] = folder
            main.save_config(config)
            livecoach.start(base / "pc-home", logged.append, background=False)
            server = main.Server(("127.0.0.1", 0), main.Handler)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            client = Client(server.server_address[1])

            def post(path: str, body, key=KEY):
                data = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode("utf-8")
                return client.call("POST", path, data, {"Content-Type": "application/json"}, key=key)

            hello = client.call("GET", "/hello")
            names = set(hello[1].get("features", [])) if hello[0] == 200 else set()
            failed += say({"meetinglive", "coach", "tension", "hrsamples"} <= names, "/hello の features に 4 つ")
            status, body, _ = client.call("GET", "/meeting-live?since=0")
            failed += say(status == 200 and body.get("available") is True and body.get("on") is False,
                          f"GET /meeting-live: 会議モードの外は on false（{status}）")
            status, body, _ = post("/meeting-live/state", {"on": True, "start": claude.now_iso(), "claude": True,
                                                           "work": False, "work_ok": True})
            failed += say(status == 200 and body.get("on") is True, f"POST /meeting-live/state（{status}）")
            status, body, _ = post("/meeting-live/state", b"{not json")
            failed += say(status == 400, f"POST /meeting-live/state: JSON でなければ 400（{status}）")
            wav = tone_wav(3.0, [(0.5, 2.5)])
            status, body, _ = client.call("POST", "/transcribe?segments=0.50-2.50", wav, {"Content-Type": "audio/wav"})
            if status == 500 and "No module named" in str(body):
                # 音声を読む部品（av）の無い手元の Python。CI（pc/requirements.txt を入れる）では確かめる
                print("SKIP /transcribe の答えの行が会議の相棒にたまる（音声を読む部品が無い）", flush=True)
                livecoach.L.feed([{"start": 0.5, "text": "作り物の文です"}], time.time())
            else:
                failed += say(status == 200 and len(livecoach.L.s["lines"]) >= 1,
                              f"/transcribe の答えの行が会議の相棒にたまる（{status}）")
            fake.text = answer(decided=[{"text": "見本の決定", "line": 0, "quote": "作り物の文です"}])
            livecoach.L.update()
            status, body, _ = client.call("GET", "/meeting-live?since=0")
            failed += say(status == 200 and body.get("on") is True and body.get("counts", {}).get("decided") == 1
                          and body.get("decided", [{}])[0].get("text") == "見本の決定" and "delay" in body,
                          f"GET /meeting-live: 更新した中身と遅れ（{status}）")
            status, body, _ = post("/health/hr", {"samples": [{"t": int(time.time()) - 120, "bpm": 72}]})
            failed += say(status == 200 and body.get("minutes") == 1 and any((base / livecoach.HR_DIR).rglob("*.json")),
                          f"POST /health/hr → 母艦の archive/health-hr（{status}）")
            status, body, _ = client.call("GET", "/coach")
            failed += say(status == 200 and body.get("available") is False, f"GET /coach: 無ければ available false（{status}）")
            unauth = [client.call("GET", p, key="wrong")[0] for p in ("/meeting-live", "/coach", "/tension")]
            unauth.append(post("/health/hr", {"samples": []}, key="wrong")[0])
            failed += say(unauth == [401, 401, 401, 401], f"合言葉が違えば 401（{unauth}）")
            failed += say("作り物の文です" not in "\n".join(logged), "記録に会議の文を書かない")
        finally:
            if server is not None:
                server.shutdown()
                server.server_close()
            main.save_config(old_config)
            main.Handler.engine, main.Handler.key, main.log, livecoach.L = saved
            reset_files()
    return failed


def run(main) -> int:
    main.isolate_home()
    saved_factory = claude.CLIENT_FACTORY
    failed = 0
    try:
        failed += check_ground()
        with tempfile.TemporaryDirectory() as folder:
            failed += check_live(Path(folder))
        with tempfile.TemporaryDirectory() as folder:
            failed += check_feeds(Path(folder))
        failed += check_http(main)
    finally:
        claude.CLIENT_FACTORY = saved_factory
        reset_files()
    print(("NG の数: " + str(failed)) if failed else "会議の相棒・話し方コーチ・緊張した場面（2026-11-15）: 全部 OK", flush=True)
    return failed


# MARK: - この PC の本物の記録で遅れを測る（--measure。CI では動かさない）


def measure(count: int = 5) -> int:
    """本物の HOME の「後で受け取る文字起こし」の記録（7 日）から、区切りの終わり → 受け取り → 文字になるまでの秒を数え、
    いちばん新しい長めの区切り count 個の文を、一時のフォルダの会議の相棒にため、本物の Claude（軽いモデル）に 1 回頼んで
    「区切りを受け取ってから更新し終えるまで」を測る。出すのは数だけ（文は出さない）"""
    import statistics

    jobs = claude.home() / "jobs"
    metas = []
    for path in jobs.glob("*.json"):
        try:
            meta = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if isinstance(meta, dict) and meta.get("status") == "done" and meta.get("done_at") \
                and time.time() - float(meta.get("queued_at") or 0) < 7 * 86400:
            metas.append((path, meta))

    def q(values: list[float], p: float) -> float | None:
        return round(sorted(values)[int(len(values) * p)], 1) if values else None

    upload = [m["queued_at"] - m["times"]["chunk_end"] for _, m in metas if (m.get("times") or {}).get("chunk_end")]
    asr = [m["done_at"] - m["queued_at"] for _, m in metas]
    print(f"区切り {len(metas)} 個（7 日）: 区切りの終わり→受け取り 中央 {q(upload, .5)} 秒・9 割 {q(upload, .9)} 秒、"
          f"受け取り→文字 中央 {q(asr, .5)} 秒・9 割 {q(asr, .9)} 秒")
    picked = []
    for path, meta in sorted(metas, key=lambda pm: -float(pm[1]["queued_at"])):
        for candidate in (path.with_suffix(".result"),):  # jobqueue.result_path と同じ名前
            try:
                reply = json.loads(candidate.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            if len(reply.get("lines") or []) >= 4:
                picked.append((meta, reply["lines"]))
                break
        if len(picked) >= count:
            break
    if not picked:
        print("文の多い区切りが見つかりませんでした（Claude は呼びません）")
        return 0
    with tempfile.TemporaryDirectory() as folder:
        live = livecoach.Live(Path(folder), lambda _m: None)
        live.set_state({"on": True, "start": claude.now_iso(time.time() - 600), "claude": True, "work": True, "work_ok": True})
        received = time.time()
        for meta, lines in reversed(picked):
            live.feed(lines, received)
        live.s["last_call"] = 0.0
        result = live.update()
        view = live.view()
        delay = view.get("delay") or {}
        print(f"会議の相棒: 区切り {len(picked)} 個・{len(live.s['lines'])} 行 → 頼んだ {result['asked']}・残した {result['kept']}・"
              f"受け取り→更新 {delay.get('last')} 秒（うち Claude {delay.get('claude')} 秒）・理由 {view.get('reason')}")
        if asr and delay.get("last") is not None:
            middle = statistics.median(upload) if upload else 0
            print(f"見込み（区切りの終わり→ロック画面の手前）: {round(middle + statistics.median(asr) + delay['last'], 1)} 秒 "
                  f"＋ 1 分に 1 回の待ち 0〜60 秒 ＋ アプリの見に行く間 0〜60 秒")
    return 0


if __name__ == "__main__":
    if "--measure" in sys.argv[1:]:
        sys.exit(measure())
    import lifelog_pc

    sys.exit(1 if run(lifelog_pc) else 0)
