"""LifeLog PC（2026-11-13: 施策 9・10・11・14）を確かめる。本物の鍵・ネット・モデル・本物の HOME は使わない。

    python pc/v12checks.py          （lifelog_pc を読み込み、isolate_home で一時のフォルダに替えてから確かめる）

- 品質の記録（quality-daily.json）: 読んでから書く・ほかの担当の項目を残す・古い日を消す・形
- 審判と PLAUD の合い方（judgecheck.py）: 作り物の後で受け取る文字起こしの答え・PLAUD の公式の文字起こし・記録で、
  時刻合わせ・近さの数え方・審判のほうが近い割合・測れないときは None
- 同じ人かも（sameperson.py）: 名前の無い人物N だけ・同じ区切りに出た2つは組にしない・日の平均を引く・組の形・
  GET /same-person（合言葉・features の "sameperson"）
- 夜の読み直し（nightreview.py）: 入力に当たらない答えを捨てる・1日の上限・使わない設定・指示文に例文が無い・
  GET /night-review と、話し手の疑い（why "night"）を GET /speaker-doubts に混ぜる
- 夜の流れ（quality.run_night）: 済んだ段は2回しない・品質の記録に数を書く
- 施策 14 の印: 自分の声の候補・話し手の疑い・言葉の候補の "sure"・"sure_why" を通す（無ければ付けない）
"""

from __future__ import annotations

import datetime
import json
import os
import sys
import tempfile
import threading
from pathlib import Path
from types import SimpleNamespace

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

import appfeeds  # noqa: E402
import claude  # noqa: E402
import judgecheck  # noqa: E402
import mothership  # noqa: E402
import nightreview  # noqa: E402
import quality  # noqa: E402
import records  # noqa: E402
import sameperson  # noqa: E402
from v6checks import KEY, Client, say  # noqa: E402
from v11checks import FakeClaude, put_key, reset_files  # noqa: E402

DAY = "2026-11-12"
KANA = "あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわをん"


def run(main) -> int:
    main.isolate_home()
    saved_env = os.environ.pop("ANTHROPIC_API_KEY", None)
    saved_factory = claude.CLIENT_FACTORY
    failed = 0
    try:
        failed += say(claude.home() == Path(main.HOME) and main._isolated is not None,
                      "確かめるときは一時のフォルダ（本物の HOME に書かない）")
        failed += check_quality_file()
        failed += check_judgecheck()
        failed += check_sameperson()
        failed += check_nightreview()
        failed += check_sure()
        failed += check_run_night()
        failed += check_http(main)
    finally:
        claude.CLIENT_FACTORY = saved_factory
        if saved_env is not None:
            os.environ["ANTHROPIC_API_KEY"] = saved_env
    print(("NG の数: " + str(failed)) if failed else "施策 9・10・11・14（2026-11-13）: 全部 OK", flush=True)
    return failed


# MARK: - 品質の記録


def check_quality_file() -> int:
    failed = 0
    with tempfile.TemporaryDirectory() as folder:
        home = Path(folder)
        (home / quality.FILE).write_text(json.dumps({"version": 1, "days": {
            DAY: {"promise_alerts": 3, "other": "x"}, "2026-01-01": {"judge_calls": 1}}}), encoding="utf-8")
        data = quality.update_day(home, DAY, {"judge_calls": 400, "judge_agree_plaud": None},
                                  now=datetime.date(2026, 11, 13))
        again = json.loads((home / quality.FILE).read_text(encoding="utf-8"))
        failed += say(again == data and again["days"][DAY] == {"promise_alerts": 3, "other": "x", "judge_calls": 400,
                                                               "judge_agree_plaud": None},
                      "quality-daily.json: 読んでから書き、ほかの担当の項目（promise_alerts）と知らない項目を残す")
        failed += say("2026-01-01" not in again["days"] and again["version"] == 1, "quality-daily.json: 60 日より古い日は消す")
        (home / quality.FILE).write_text("壊れた", encoding="utf-8")
        data = quality.update_day(home, DAY, {"same_person_groups": 2}, now=datetime.date(2026, 11, 13))
        failed += say(data == {"version": 1, "days": {DAY: {"same_person_groups": 2}}}, "壊れた quality-daily.json は作り直す")
    return failed


# MARK: - 審判と PLAUD


def kana(seed: int, n: int = 20) -> str:
    rng = np.random.default_rng(seed)
    return "".join(KANA[i] for i in rng.integers(0, len(KANA), n))


def local_iso(moment: datetime.datetime) -> str:
    return moment.astimezone().isoformat(timespec="milliseconds")


def make_day(home: Path, base: Path, judged: list[tuple[str, str]]) -> None:
    """作り物の PLAUD（10:00 から、20 秒ごとの発話）・その日の記録（同じ文）・審判の行（chunk は 10:00:00）"""
    t0 = datetime.datetime(2026, 11, 12, 10, 0, 0)
    texts = [kana(i) for i in range(12)]
    folder = base / "archive" / "plaud" / "2026" / "11"
    folder.mkdir(parents=True, exist_ok=True)
    body = ["# 見本", "", "- source: plaud", f"- date: {DAY}", "- startTime: 10:00", ""]
    for i, text in enumerate(texts):
        body += [f"話者1 00:00:{i * 4:02d}" if i * 4 < 60 else f"話者1 00:01:{i * 4 - 60:02d}", text]
    (folder / "12_見本.md").write_text("\n".join(body), encoding="utf-8")
    lines = [{"time": local_iso(t0 + datetime.timedelta(seconds=i * 4)), "text": text, "speaker": "自分"}
             for i, text in enumerate(texts)]
    (home / "records").mkdir(parents=True, exist_ok=True)
    (home / "records" / f"{DAY}.json").write_text(json.dumps({"conversations": [
        {"start": local_iso(t0), "lines": lines}]}, ensure_ascii=False), encoding="utf-8")
    jobs = home / "jobs"
    jobs.mkdir(parents=True, exist_ok=True)
    result_lines = []
    for i, (picked, before) in enumerate(judged):
        line = {"start": i * 4.0, "end": i * 4.0 + 3, "text": picked, "confidence": 0.3, "votes": {},
                "judge": {"picked": 1, "model": "m"}}
        if before is not None:
            line["judge"]["before"] = before
        result_lines.append(line)
    (jobs / "a.json").write_text(json.dumps({"id": "20261112-100000.m4a", "status": "done"}), encoding="utf-8")
    (jobs / "a.result").write_text(json.dumps({"lines": result_lines}, ensure_ascii=False), encoding="utf-8")


def check_judgecheck() -> int:
    failed = 0
    texts = [kana(i) for i in range(12)]
    failed += say(judgecheck.closeness(texts[0], texts[0]) == len(texts[0])
                  and judgecheck.closeness(texts[0][:5], texts[0]) == 5
                  and judgecheck.closeness("ゐゐゐゐゐ", texts[0]) == -5,
                  "近さ: 合った字は +1、合わない字は −1（短い文が得をしない）")
    with tempfile.TemporaryDirectory() as a, tempfile.TemporaryDirectory() as b:
        home, base = Path(a), Path(b)
        judged = []
        for i in range(8):
            if i < 6:
                judged.append((texts[i], "ゐゑ" + texts[i][4:]))    # 審判のほうが PLAUD に近い
            elif i == 6:
                judged.append(("ゐゑゐゑ" + texts[i][4:], texts[i]))  # 多数決のほうが近い
            else:
                judged.append((texts[i], None))                     # 審判は多数決のまま
        make_day(home, base, judged)
        got = judgecheck.measure(home, base, [DAY])[DAY]
        failed += say(got["judged"] == 8 and got["changed"] == 7 and got["timed"] == 1 and got["aligned"] == 7
                      and got["judge_better"] == 6 and got["default_better"] == 1 and got["agree"] == round(6 / 7, 3),
                      f"審判と PLAUD: 時刻を合わせ、審判のほうが近い 6・多数決のほうが近い 1 → 0.857（{got}）")
        few = judgecheck.measure(home, base, ["2026-11-11"])["2026-11-11"]
        failed += say(few["judged"] == 0 and few["agree"] is None, "審判の行が無い日は測れない（None）")
        (base / "archive" / "plaud" / "2026" / "11" / "12_見本.md").unlink()
        none = judgecheck.measure(home, base, [DAY])[DAY]
        failed += say(none["recordings"] == 0 and none["aligned"] == 0 and none["agree"] is None,
                      "PLAUD が無い日は測れない（None）")
    return failed


# MARK: - 同じ人かも


def ms(seconds: float) -> int:
    return int(datetime.datetime(2026, 11, 12, 9, 0, 0).timestamp() * 1000 + seconds * 1000)


def person_day() -> dict:
    """人物1・人物2（同じ声・違う区切り）、人物3（違う声）、人物4（人物1 と同じ区切り）、名前のある人・自分"""
    def line(t, who, ident, audio, text="見本の文です"):
        return {"time": ms(t), "speaker": who, "speakerID": ident, "audio": audio, "offset": 1.0, "end": 4.0,
                "text": text, "media": None}
    lines = [line(0, "人物1", "1", "c1.m4a"), line(1, "人物1", "1", "c1b.m4a"),
             line(50, "人物2", "2", "c2.m4a"), line(100, "人物3", "3", "c3.m4a"),
             line(2, "人物4", "4", "c1.m4a"), line(150, "見本さん", "9", "c4.m4a"),
             line(160, "自分", "me", "c5.m4a"), line(170, "人物5", "7", "c6.m4a")]
    return {"conversations": [{"start": ms(0), "media": None, "lines": lines}]}


VOICES = {"c1.m4a": [1, 0, 0, 0], "c1b.m4a": [0.95, 0.1, 0, 0], "c2.m4a": [0.97, 0.05, 0, 0], "c3.m4a": [0, 1, 0, 0],
          "c4.m4a": [0.96, 0.02, 0, 0], "c5.m4a": [0.94, 0, 0.1, 0], "c6.m4a": [0.98, 0, 0, 0]}


def fake_embed(path: Path, ranges):
    v = np.asarray(VOICES[path.name] + [0.0] * 4, dtype=np.float64)
    return [list(v / np.linalg.norm(v)) for _ in ranges]


def check_sameperson() -> int:
    failed = 0
    parsed = person_day()
    labels = sameperson.unnamed_labels(parsed)
    failed += say(sorted(labels) == ["1", "2", "3", "4"],
                  "同じ人かも: 名前の無い人物N だけ（名前のある人・自分・番号の合わない行は入れない）")
    failed += say(sameperson.apart_pairs(labels) == {("1", "4")}, "同じ区切りに出た2つは「別の声」の組")
    with tempfile.TemporaryDirectory() as folder:
        root = Path(folder)
        for name in VOICES:
            (root / name).write_bytes(b"x")
        built = sameperson.build_day(DAY, parsed, lambda n: root / n if (root / n).exists() else None, fake_embed,
                                     link=0.3)
        groups = [sorted(p["id"] for p in g["people"]) for g in built["groups"]]
        failed += say(built["labels"] == 4 and built["measured"] == 4 and any(set(g) >= {"1", "2"} for g in groups)
                      and not any({"1", "4"} <= set(g) for g in groups) and not any("9" in g or "me" in g for g in groups),
                      f"人物1・人物2 は同じ組、人物1 と人物4（同じ区切り）は組にしない、名前のある人は入れない（{groups}）")
        sample = built["groups"][0]["people"][0]["samples"][0] if built["groups"] else {}
        failed += say(set(sample) == {"time", "text", "audio", "start", "end"} and sample["time"].endswith("Z")
                      and records.parse_time(sample["time"], "t") in (ms(0), ms(1), ms(50)),
                      "組の聞く所: 記録の行と同じ時刻（UTC・ミリ秒）・音声の名前・始まり・終わり")
        raw = {"a": [np.array([1.0, 0.2]), np.array([1.0, 0.25])], "b": [np.array([1.0, -0.2])]}
        centers = sameperson.centered(raw)
        failed += say(float(np.dot(centers["a"], centers["b"])) < 0,
                      "日の平均を引いてから比べる（同じ向きに寄った声どうしを近く見すぎない）")
        missing = sameperson.build_day(DAY, parsed, lambda n: None, fake_embed)
        failed += say(missing["measured"] == 0 and missing["groups"] == [], "音声が無ければ組を作らない")
        home = root / "home"
        sameperson.save_day(home, built)
        served = sameperson.read(home)
        failed += say(served["available"] and served["days"][0]["day"] == DAY
                      and all(p["name"].startswith("人物") for g in served["days"][0]["groups"] for p in g["people"]),
                      "GET /same-person の中身: 日ごとの組（人物N だけ）")
        bad = dict(built, groups=[{"id": "x", "people": [{"id": "9", "name": "見本さん"}, {"id": "1", "name": "人物1"}]}])
        sameperson.save_day(home, bad)
        failed += say(sameperson.read(home)["days"][0]["groups"] == [], "名前のある人が混ざった組は返さない")
        failed += say(sameperson.read(root / "none") == {"available": False, "reason": "まだ「同じ人かも」を作っていません"},
                      "まだ作っていなければ available false")
    return failed


# MARK: - 夜の読み直し


def night_day() -> dict:
    lines = [{"time": ms(i * 10), "speaker": "自分" if i % 2 == 0 else "人物3", "speakerID": None, "audio": None,
              "offset": None, "end": None, "text": f"見本の文{i}です、かいぎはさんじから", "media": None}
             for i in range(6)]
    lines.append({"time": ms(70), "speaker": "人物3", "text": "テレビの声", "media": "tv"})
    return {"conversations": [{"start": ms(0), "media": None, "lines": lines}]}


def check_nightreview() -> int:
    failed = 0
    failed += say("例" not in nightreview.SYSTEM and "「" not in nightreview.SYSTEM.replace("「自分」", ""),
                  "夜の読み直しの指示文に例文が無い")
    lines = nightreview.day_lines(night_day())
    failed += say(len(lines) == 6, "テレビなどの声の行は読ませない")
    answer = {"misheard": [{"n": 0, "wrong": "さんじ", "right": "三時", "why": "時刻"},
                           {"n": 1, "wrong": "無い言葉", "right": "x", "why": ""},
                           {"n": 99, "wrong": "さんじ", "right": "三時", "why": ""},
                           {"n": 2, "wrong": "かいぎ", "right": "かいぎ", "why": ""},
                           {"n": 0, "wrong": "さんじ", "right": "三時", "why": "2回目"}],
              "speaker": [{"n": 1, "quote": "見本の文1", "suggest": "self", "why": "流れ"},
                          {"n": 0, "quote": "見本の文0", "suggest": "self", "why": "もう自分"},
                          {"n": 3, "quote": "無い文です", "suggest": "other", "why": ""},
                          {"n": 4, "quote": "見本の文4", "suggest": "other", "why": "相手の言葉"}]}
    misheard, speaker, dropped = nightreview.ground(answer, lines, list(range(6)), DAY)
    failed += say([(m["wrong"], m["guess"]) for m in misheard] == [("さんじ", "三時")] and dropped == 6
                  and [(s["current"], s["suggest"], s["why"]) for s in speaker] == [("人物3", "self", "night"),
                                                                                    ("自分", "other", "night")],
                  f"答えは入力に当てて確かめる（行に無い言葉・番号違い・同じ文・自分の行の「自分かも」を捨てる。捨てた {dropped}）")
    failed += say(misheard[0]["line_time"].endswith("Z") and records.parse_time(misheard[0]["line_time"], "t") == ms(0)
                  and set(misheard[0]) == {"id", "day", "line_time", "wrong", "guess", "reason"},
                  "聞き間違いの候補の形（アプリの「聞き間違いかも」に入る形）")
    calls = []

    def fake_call(system, prompt, **kw):
        calls.append(kw)
        return {"data": answer, "usd": 0.01, "model": "m", "text": ""}

    built = nightreview.review_day(DAY, night_day(), call=fake_call, cap_usd=1.0)
    failed += say(built["calls"] == 1 and calls[0]["tier"] == "standard" and calls[0]["work"] is True
                  and calls[0]["purpose"] == nightreview.PURPOSE and calls[0]["schema"] == nightreview.SCHEMA
                  and len(built["misheard"]) == 1 and len(built["speaker"]) == 2,
                  "夜の読み直し: standard・職場も送る・形を渡す・候補を集める")
    capped = nightreview.review_day(DAY, night_day(), call=fake_call, cap_usd=0.0001)
    failed += say(capped["calls"] == 0 and capped["stopped"] == "1日の上限", "1日の上限を越えそうなら頼まない")
    with tempfile.TemporaryDirectory() as folder:
        home = Path(folder)
        nightreview.save_day(home, built)
        served = nightreview.read(home)
        failed += say(served["available"] and len(served["items"]) == 1 and served["items"][0]["guess"] == "三時",
                      "GET /night-review: 聞き間違いの候補")
        failed += say(len(nightreview.doubt_items(home)) == 2, "話し手の疑いは /speaker-doubts に混ぜる分として読める")
    return failed


# MARK: - 施策 14 の印


def check_sure() -> int:
    failed = 0
    with tempfile.TemporaryDirectory() as folder:
        base = Path(folder)
        (base / "state").mkdir()
        cand = {"day": DAY, "audio": "20261112-090000.m4a", "start": 1.0, "end": 3.0, "text": "見本", "score": 0.9,
                "why": "plaud-match"}
        (base / appfeeds.SELF_CANDIDATES).write_text(json.dumps({"items": [
            dict(cand, id="c1", sure=True, sure_why="PLAUD で自分"), dict(cand, id="c2", sure=False),
            dict(cand, id="c3"), dict(cand, id="c4", sure="yes")]}, ensure_ascii=False), encoding="utf-8")
        got = {i["id"]: (i.get("sure"), i.get("sure_why")) for i in appfeeds.read_self_candidates(base)["items"]}
        failed += say(got == {"c1": (True, "PLAUD で自分"), "c2": (None, None), "c3": (None, None), "c4": (None, None)},
                      f"自分の声の候補: sure が true のときだけ sure・sure_why を付ける（{got}）")
        doubt = {"day": DAY, "conversation_start": "2026-11-12T09:00:00+09:00", "line_time": "2026-11-12T09:00:05+09:00",
                 "text_head": "見本", "current": "人物3", "suggest": "self", "why": "plaud-turn", "score": 0.8}
        (base / appfeeds.SPEAKER_DOUBTS).write_text(json.dumps({"items": [
            dict(doubt, sure=True, sure_why="x" * 90), dict(doubt, why="night")]}), encoding="utf-8")
        items = appfeeds.read_speaker_doubts(base)["items"]
        failed += say(items[0].get("sure") is True and len(items[0]["sure_why"]) == 60 and "sure" not in items[1],
                      "話し手の疑い: sure・sure_why（60 字まで）を通す・母艦の why night も読める")
        (base / mothership.VOCAB).write_text(json.dumps({"items": [{"word": "見本語", "sure": True, "sure_why": "毎日"},
                                                                    {"word": "別語"}]}, ensure_ascii=False),
                                             encoding="utf-8")
        words = mothership.read_vocab(base)["items"]
        failed += say(words[0].get("sure") is True and words[0]["sure_why"] == "毎日" and "sure" not in words[1],
                      "言葉の候補（GET /vocab）: sure・sure_why を通す")
    return failed


# MARK: - 夜の流れ


class FakeStore:
    def __init__(self, days: dict) -> None:
        self.days = days

    def day(self, day: str):
        return self.days.get(day)

    def audio_file(self, name: str):
        return None


def check_run_night() -> int:
    failed = 0
    reset_files()
    put_key()
    fake = FakeClaude()

    def reply(kwargs) -> str:
        rows = json.loads(kwargs["messages"][0]["content"])["lines"]
        n = next(r["n"] for r in rows if "さんじ" in r["text"])
        return json.dumps({"misheard": [{"n": n, "wrong": "さんじ", "right": "三時", "why": "時刻"}], "speaker": []},
                          ensure_ascii=False)

    fake.reply = reply
    claude.CLIENT_FACTORY = fake.factory
    with tempfile.TemporaryDirectory() as folder:
        home = Path(folder)
        today = datetime.date(2026, 11, 13)
        logged: list[str] = []
        audio = home / "aud"
        audio.mkdir()
        for name in VOICES:
            (audio / name).write_bytes(b"x")
        store = FakeStore({DAY: {"conversations": person_day()["conversations"] + night_day()["conversations"]}})
        store.audio_file = lambda name: audio / name if (audio / name).exists() else None
        saved = (quality.State.home, quality.State.store, quality.State.jobs, quality.State.base, quality.State.embed,
                 quality.State.log, quality.State.thread)
        try:
            quality.State.thread = object()  # 裏の流れは始めない
            quality.start(home, store, None, lambda: home / "base", fake_embed, logged.append)
            failed += say(quality.features() == ["sameperson", "nightreview"], "features に sameperson・nightreview")
            out = quality.run_night(today)
            daily = quality.read_daily(home)["days"].get(DAY, {})
            failed += say(out.get("night") == 1 and "judge" in out and daily.get("night_review_items") == 1
                          and daily.get("judge_calls") == 0 and "same_person_groups" in daily
                          and "judge_agree_plaud" in daily,
                          f"夜の流れ: 昨日の分の数を quality-daily.json に書く（{daily}）")
            before = len(fake.calls)
            again = quality.run_night(today)
            failed += say(again == {} and len(fake.calls) == before, "同じ夜に2回しない（済んだ段は飛ばす）")
            failed += say(not any("三時" in m or "見本" in m or "さんじ" in m for m in logged),
                          "記録（log）に文・名前を書かない")
            failed += say(quality.in_window(datetime.datetime(2026, 11, 13, 1, 0))
                          and not quality.in_window(datetime.datetime(2026, 11, 13, 5, 0))
                          and not quality.in_window(datetime.datetime(2026, 11, 13, 0, 30)),
                          "夜の流れは 01:00〜05:00 だけ")
            claude.config_path().write_text(json.dumps({"night_review": False}), encoding="utf-8")
            failed += say(nightreview.run_day(home, store, DAY, logged.append) is None, "night_review: false なら読み直さない")
        finally:
            (quality.State.home, quality.State.store, quality.State.jobs, quality.State.base, quality.State.embed,
             quality.State.log, quality.State.thread) = saved
            reset_files()
    return failed


# MARK: - 受け口


def check_http(main) -> int:
    failed = 0
    saved = (getattr(main.Handler, "engine", None), getattr(main.Handler, "key", None), main.log)
    state = (quality.State.home, quality.State.store, quality.State.jobs, quality.State.base, quality.State.embed,
             quality.State.log, quality.State.thread)
    import ops

    with tempfile.TemporaryDirectory() as folder:
        try:
            main.log = lambda _m: None
            main.Handler.key = KEY
            main.Handler.engine = main.Ensemble(ops.fake_engines())
            home = Path(folder) / "home"
            quality.State.thread = object()
            quality.start(home, FakeStore({}), None, None, fake_embed, lambda _m: None)
            config = main.load_config()
            config["lifelog_home"] = str(Path(folder) / "base")
            main.save_config(config)
            server = main.Server(("127.0.0.1", 0), main.Handler)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            client = Client(server.server_address[1])
            hello = client.call("GET", "/hello")
            failed += say(hello[0] == 200 and {"sameperson", "nightreview"} <= set(hello[1]["features"]),
                          "/hello の features に sameperson・nightreview")
            failed += say(client.call("GET", "/same-person", key="wrong")[0] == 401
                          and client.call("GET", "/night-review", key=None)[0] == 401, "合言葉が要る")
            status, body, _ = client.call("GET", "/same-person")
            failed += say(status == 200 and body.get("available") is False, "GET /same-person: まだ無ければ available false")
            sameperson.save_day(home, {"day": DAY, "generated_at": "x", "groups": []})
            status, body, _ = client.call("GET", "/same-person?refresh=1")
            failed += say(status == 200 and body.get("available") is True and body["days"][0]["day"] == DAY,
                          "GET /same-person?refresh=1: 前のものを返し、裏で作り直す")
            nightreview.save_day(home, {"day": DAY, "generated_at": "x", "misheard": [], "speaker": [
                {"day": DAY, "conversation_start": "2026-11-12T00:00:00.000Z", "line_time": "2026-11-12T00:00:05.000Z",
                 "text_head": "見本", "current": "人物3", "suggest": "self", "why": "night", "score": 0.55}]})
            status, body, _ = client.call("GET", "/night-review")
            failed += say(status == 200 and body.get("available") is True and body["items"] == [], "GET /night-review")
            os.environ["LOCALAPPDATA"] = str(home.parent)
            (Path(folder) / "home").rename(Path(folder) / "LifeLogPC")
            status, body, _ = client.call("GET", "/speaker-doubts")
            failed += say(status == 200 and body.get("available") is True and [i["why"] for i in body["items"]] == ["night"],
                          "GET /speaker-doubts: 母艦の疑いが無くても、夜の読み直しの疑い（why night）を返す")
            server.shutdown()
            server.server_close()
        finally:
            os.environ["LOCALAPPDATA"] = str(main._isolated)
            main.Handler.engine, main.Handler.key, main.log = saved
            (quality.State.home, quality.State.store, quality.State.jobs, quality.State.base, quality.State.embed,
             quality.State.log, quality.State.thread) = state
    return failed


if __name__ == "__main__":
    import lifelog_pc

    sys.exit(1 if run(lifelog_pc) else 0)
