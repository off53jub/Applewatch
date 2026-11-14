"""強化案 56・57（2026-11-15。中身は voices.py・quality.py・canonical.py）を確かめる。

    python pc/v15checks_voices.py

本物の HOME・音声・声のモデル・母艦は使わない（一時のフォルダ・作り物の声の特徴）。確かめること:
- 声の特徴の置き場所（HOME/voices/<日>.npz）: 置いて読める・モデルが違えば測り直す・測れなかった区間の印・古い日を消す
- 足し方: まだ無い区間だけを測る（2 回目は 0）・時間切れで止まる・音声が無い区間は印を付けずに後で測る・テレビなどの声の行は測らない
- 束ね方: 日の平均を引いてから比べる（日ごとの癖が大きくても、違う人をまとめない）・別の日の同じ声を「日をまたぐ組」にする・
  同じ区切りに出た 2 つはまとめない・同じ日にしか出ない組は出さない・名前のある人に近い人物N を「◯◯さんかも」にする・
  自分に近い人物N は名前のある人の候補にしない・2 番目との差が小さければ出さない
- 1 日の組（sameperson.py）は置いてある特徴を使い、無い区間だけを測る
- GET /same-person に "across"・"maybe" が足される（形が違うもの・自分を名前のある人にしたもの・古いファイルは出さない）
- GET /canonical?day=: 母艦の正本を確かめて返す（直近 14 日だけ・日付が違えば available false・おかしな行は落とす）
- 重い仕事の時間（00:00〜05:00・08:30〜18:00）の外では昼の見回りをしない
- 記録（log.txt）に文・名前を書かない
"""

from __future__ import annotations

import datetime
import json
import os
import sys
import tempfile
import threading
import time
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import numpy as np  # noqa: E402

import canonical  # noqa: E402
import ops  # noqa: E402
import quality  # noqa: E402
import records  # noqa: E402
import voices  # noqa: E402
from v6checks import KEY, Client, say  # noqa: E402

SECRET_TEXT = "見本の秘密の会話の文です"
SECRET_NAME = "見本花子"
DIM = 32
DAY1, DAY2 = "2026-01-05", "2026-01-06"


def run(main) -> int:
    main.isolate_home()
    failed = 0
    failed += check_store()
    failed += check_update()
    failed += check_build()
    failed += check_cached()
    failed += check_read_extra()
    failed += check_canonical()
    failed += check_windows()
    failed += check_http(main)
    print(("NG の数: " + str(failed)) if failed else "声の名寄せ・1日の正本（2026-11-15）: 全部 OK", flush=True)
    return failed


# MARK: - 作り物


def voice(seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    v = rng.normal(size=DIM)
    return v / np.linalg.norm(v)


PEOPLE = {"A": voice(1), "B": voice(2), "C": voice(3), "D": voice(4), "N": voice(5), "ME": voice(6)}
DAY_BIAS = {DAY1: voice(100) * 3.0, DAY2: voice(200) * 3.0}  # 日ごとの癖（声の違いより大きい）


def line(day: str, minute: int, who: str, speaker: str | None, ident: str | None, audio: str, start: float,
         length: float = 3.0, media: bool = False) -> dict:
    moment = f"{day}T10:{minute:02d}:{int(start) % 60:02d}+09:00"
    out = {"time": moment, "text": SECRET_TEXT, "speaker": speaker, "speakerID": ident, "audio": audio,
           "offset": start, "end": start + length, "_who": who}
    if media:
        out["media"] = "tv"
    return out


def record(lines: list[dict]) -> dict:
    clean = [{k: v for k, v in x.items() if k != "_who"} for x in lines]
    body = {"conversations": [{"start": clean[0]["time"], "lines": clean}]}
    return records.parse_record(json.loads(json.dumps(body)))


def day_lines() -> dict[str, list[dict]]:
    d1 = []
    d2 = []
    # A: 1 日目は人物11、2 日目は人物21（同じ声）
    for i in range(3):
        d1.append(line(DAY1, i, "A", "人物11", "11", f"a1-{i}.m4a", 1.0 + i))
        d2.append(line(DAY2, i, "A", "人物21", "21", f"a2-{i}.m4a", 1.0 + i))
    # B と C は同じ区切りに出る（iPhone が別の声と分けた）。C は B と同じ声にしておく（まとめてはいけない）
    for i in range(3):
        d1.append(line(DAY1, 10 + i, "B", "人物12", "12", f"bc-{i}.m4a", 1.0))
        d1.append(line(DAY1, 10 + i, "B", "人物13", "13", f"bc-{i}.m4a", 6.0))
    # N: 名前のある人（番号 7）。1 日目に名前つきの行、2 日目に人物22 として出る
    for i in range(5):
        d1.append(line(DAY1, 20 + i, "N", SECRET_NAME, "7", f"n1-{i}.m4a", 1.0))
    for i in range(3):
        d2.append(line(DAY2, 20 + i, "N", "人物22", "22", f"n2-{i}.m4a", 1.0))
    # 自分: 1 日目に自分の行、2 日目に人物23 として出る（名前のある人の候補にしない）
    for i in range(5):
        d1.append(line(DAY1, 30 + i, "ME", "自分", "me", f"m1-{i}.m4a", 1.0))
    for i in range(3):
        d2.append(line(DAY2, 30 + i, "ME", "人物23", "23", f"m2-{i}.m4a", 1.0))
    # D: どちらの日にも、ほかに似た声の無い人
    for i in range(3):
        d1.append(line(DAY1, 40 + i, "D", "人物14", "14", f"d1-{i}.m4a", 1.0))
    # 埋め草: 日の平均を作るための、いろいろな声（話し手の分からない行）
    for i in range(30):
        d1.append(line(DAY1, 50, f"x{i}", None, None, f"x1-{i}.m4a", 1.0))
        d2.append(line(DAY2, 50, f"y{i}", None, None, f"x2-{i}.m4a", 1.0))
    # テレビなどの声・短すぎる行は測らない
    d1.append(line(DAY1, 59, "A", "人物11", "11", "tv.m4a", 1.0, media=True))
    d1.append(line(DAY1, 59, "A", "人物11", "11", "short.m4a", 1.0, length=0.5))
    return {DAY1: d1, DAY2: d2}


class FakeStore:
    def __init__(self, days: dict[str, list[dict]]) -> None:
        self.parsed = {d: record(v) for d, v in days.items()}

    def day(self, day: str):
        return self.parsed.get(day)


class FakeEmbed:
    """区間の声の特徴: 話し手の声＋日の癖＋少しのゆらぎ（音声の名前と始まりから決まる）"""

    def __init__(self, days: dict[str, list[dict]]) -> None:
        self.who: dict[tuple[str, float], tuple[str, str]] = {}
        for d, lines in days.items():
            for x in lines:
                self.who[(x["audio"], float(x["offset"]))] = (x["_who"], d)
        self.calls = 0
        self.ranges = 0

    def __call__(self, path: Path, ranges: list[tuple[float, float]]) -> list:
        self.calls += 1
        out = []
        for start, _ in ranges:
            self.ranges += 1
            who, d = self.who[(path.name, float(start))]
            base = PEOPLE.get(who)
            if base is None:
                base = voice(1000 + zlib.crc32(who.encode("utf-8")) % 10_000)
            jitter = voice(int(start * 1000) + zlib.crc32(path.name.encode("utf-8")) % 99_991) * 0.15
            v = base + DAY_BIAS[d] + jitter
            out.append([float(t) for t in v / np.linalg.norm(v)])
        return out


def find_audio(name: str) -> Path | None:
    return None if name.startswith("gone") else Path("/fake") / name


# MARK: - 確かめ


def check_store() -> int:
    failed = 0
    with tempfile.TemporaryDirectory() as folder:
        home = Path(folder)
        ds = voices.DayStore(home, DAY1)
        ds.vectors["a|1.00|2.00"] = np.ones(DIM, dtype=np.float32) / np.sqrt(DIM)
        ds.bad.add("b|1.00|2.00")
        ds.save()
        back = voices.DayStore(home, DAY1).load()
        failed += say("a|1.00|2.00" in back.vectors and back.bad == {"b|1.00|2.00"}
                      and abs(float(np.linalg.norm(back.vectors["a|1.00|2.00"])) - 1) < 1e-2,
                      "声の特徴の置き場所: 置いて読める（float16）・測れなかった印も残る")
        saved = voices.MODEL
        try:
            voices.MODEL = "another-model.onnx"
            other = voices.DayStore(home, DAY1).load()
            failed += say(not other.vectors and not other.bad, "モデルが違えば、前の特徴を使わない（測り直す）")
        finally:
            voices.MODEL = saved
        old = voices.DayStore(home, "2000-01-01")
        old.vectors["x|1.00|2.00"] = np.ones(DIM, dtype=np.float32)
        old.save()
        gone = voices.prune(home, datetime.date(2026, 1, 6))
        failed += say(gone == 1 and (home / "voices" / f"{DAY1}.npz").exists(), f"古い日を消す（{gone}）")
    return failed


def check_update() -> int:
    failed = 0
    days = day_lines()
    store = FakeStore(days)
    embed = FakeEmbed(days)
    with tempfile.TemporaryDirectory() as folder:
        home = Path(folder)
        got = voices.update_day(home, store, DAY1, find_audio, embed)
        expected = len([x for x in days[DAY1] if not x.get("media") and x["end"] - x["offset"] >= voices.CLIP_MIN])
        failed += say(got["added"] == expected and got["total"] == expected,
                      f"足し方: テレビの声・短い行を除いた区間を測る（{got['added']} / {expected}）")
        again = voices.update_day(home, store, DAY1, find_audio, embed)
        failed += say(again["added"] == 0, "2 回目は、まだ無い区間だけ（0）")
        stopped = voices.update_day(home, store, DAY2, find_audio, embed, deadline=time.time() - 1)
        failed += say(stopped["stopped"] and stopped["added"] == 0, "時間切れなら測らずに止まる")
        gone = FakeStore({DAY1: [line(DAY1, 1, "A", "人物11", "11", "gone-1.m4a", 1.0)]})
        miss = voices.update_day(home, gone, DAY1, find_audio, embed)
        failed += say(miss["missing"] == 1 and not voices.DayStore(home, DAY1).load().bad,
                      "音声が無い区間は印を付けない（後で届いたら測る）")
        failed += say(voices.update_day(home, store, "2026-02-01", find_audio, embed) is None, "記録の無い日は None")
    return failed


def built_for(home: Path, store, embed) -> dict:
    for d in (DAY1, DAY2):
        voices.update_day(home, store, d, find_audio, embed)
    return voices.build(home, store, datetime.date(2026, 1, 6), window=2)


def check_build() -> int:
    failed = 0
    days = day_lines()
    store = FakeStore(days)
    embed = FakeEmbed(days)
    with tempfile.TemporaryDirectory() as folder:
        home = Path(folder)
        built = built_for(home, store, embed)
        groups = [sorted(p["id"] for p in g["people"]) for g in built["across"]]
        failed += say(["11", "21"] in groups, f"別の日の同じ声（人物11・人物21）を日をまたぐ組に（{groups}）")
        failed += say(all(not ({"12", "13"} <= set(g)) for g in groups), "同じ区切りに出た 2 つはまとめない")
        failed += say(all(len({p for p in g if p in ("12", "13", "14")}) < 2 or {"21", "22", "23"} & set(g) for g in groups),
                      "同じ日にしか出ない組は出さない（1 日の組に任せる）")
        maybe = {m["person"]["id"]: m for m in built["maybe"]}
        failed += say("22" in maybe and maybe["22"]["named"] == {"id": "7", "name": SECRET_NAME},
                      f"名前のある人に近い人物22 を「◯◯さんかも」に（{sorted(maybe)}）")
        failed += say("23" not in maybe, "自分に近い人物23 は、名前のある人の候補にしない")
        g = next((x for x in built["across"] if sorted(p["id"] for p in x["people"]) == ["11", "21"]), None)
        failed += say(g is not None and g["days"] == [DAY1, DAY2] and g["day"] == DAY2
                      and all(p["samples"] and p["samples"][0]["audio"] for p in g["people"]),
                      "組の形: days・day（新しい日）・聞くための区間")
        # 日の平均を引かないと、違う人どうしも日の癖で近くなる（引けば分かれる）
        mixed = [x for x in built["across"] if {"14", "21"} <= {p["id"] for p in x["people"]}]
        failed += say(not mixed, "日の癖が大きくても、違う人（人物14・人物21）をまとめない")
        voices.NAMED_MARGIN, saved = 2.5, voices.NAMED_MARGIN
        try:
            strict = voices.build(home, store, datetime.date(2026, 1, 6), window=2)
            failed += say(not strict["maybe"], "2 番目との差が小さければ「◯◯さんかも」を出さない")
        finally:
            voices.NAMED_MARGIN = saved
        logged: list[str] = []
        voices.run(home, store, logged.append, datetime.date(2026, 1, 6))
        text = "\n".join(logged)
        saved_file = (home / "same-person" / "voices.json").read_text(encoding="utf-8")
        failed += say(bool(logged) and SECRET_NAME not in text and SECRET_TEXT[:6] not in text,
                      "記録には数だけ（名前・文を書かない）")
        failed += say(json.loads(saved_file)["across"] == built["across"], "HOME/same-person/voices.json に置く")
    return failed


def check_cached() -> int:
    failed = 0
    days = day_lines()
    store = FakeStore(days)
    embed = FakeEmbed(days)
    with tempfile.TemporaryDirectory() as folder:
        home = Path(folder)
        voices.update_day(home, store, DAY1, find_audio, embed)
        before = embed.ranges
        x = days[DAY1][0]
        got = voices.cached_embed(home, DAY1, x["audio"], Path("/fake") / x["audio"],
                                  [(x["offset"], x["end"]), (x["offset"], x["end"] + 1)], embed)
        failed += say(embed.ranges == before + 1 and got[0] is not None and got[1] is not None,
                      "1 日の組は置いてある特徴を使い、無い区間だけを測る")
        quality.State.home, quality.State.embed = home, embed
        saved_find = quality.find_audio
        try:
            quality.find_audio = find_audio
            find, wrapped = quality.cached(DAY1)
            path = find(x["audio"])
            before = embed.ranges
            wrapped(path, [(x["offset"], x["end"])])
            failed += say(embed.ranges == before, "quality.cached: 音声の名前で置き場所を引く")
        finally:
            quality.find_audio = saved_find
            quality.State.home, quality.State.embed = None, None
    return failed


def check_read_extra() -> int:
    failed = 0
    with tempfile.TemporaryDirectory() as folder:
        home = Path(folder)
        member = {"id": "21", "name": "人物21", "lines": 3, "seconds": 9.0, "days": [DAY2], "samples": []}
        good = {"id": "sx-1", "day": DAY2, "days": [DAY1, DAY2], "score": 0.8, "people": [member, dict(member, id="11", name="人物11")]}
        bad_name = dict(good, id="sx-2", people=[member, dict(member, id="7", name=SECRET_NAME)])
        maybe_ok = {"id": "pm-1", "day": DAY2, "score": 0.7, "margin": 0.2, "person": member, "named": {"id": "7", "name": SECRET_NAME}}
        maybe_self = dict(maybe_ok, id="pm-2", named={"id": "me", "name": "自分"})
        maybe_unnamed = dict(maybe_ok, id="pm-3", named={"id": "9", "name": "人物9"})
        voices.save(home, {"across": [good, bad_name], "maybe": [maybe_ok, maybe_self, maybe_unnamed]})
        extra = voices.read_extra(home)
        failed += say([g["id"] for g in extra["across"]] == ["sx-1"] and [m["id"] for m in extra["maybe"]] == ["pm-1"],
                      "GET /same-person に足す分: 名前のある人が入った組・自分や人物N を名前のある人にしたものは出さない")
        failed += say(voices.read_extra(home, now=time.time() + 4 * 86400) == {}, "古い voices.json は出さない")
    return failed


def canonical_line(**kw) -> dict:
    base = {"time": "10:00:00", "source": "plaud", "clock": "aligned", "speaker": "自分", "speaker_id": "me",
            "speaker_how": "line", "plaud_speaker": "話者1", "rec": 0, "text": SECRET_TEXT}
    base.update(kw)
    return base


def check_canonical() -> int:
    failed = 0
    with tempfile.TemporaryDirectory() as folder:
        base = Path(folder)
        today = datetime.date(2026, 1, 6)
        data = {"version": 1, "day": DAY2, "generated_at": "2026-01-06T07:00:00+09:00",
                "recordings": [{"id": "f_x", "from": "10:00:00", "to": "11:00:00", "clock": "aligned", "blocks": 2}],
                "counts": {"lines": 4, "plaud": 2, "app": 2, "with_speaker": 3},
                "lines": [canonical_line(), canonical_line(time="10:00:05", speaker=None, speaker_id=None, speaker_how=None),
                          canonical_line(time="12:00:00", source="app", clock="app", rec=None, speaker="人物3", speaker_id="3",
                                         speaker_how="app", plaud_speaker=None),
                          canonical_line(time="25:00:00"), canonical_line(time="12:01:00", source="app", clock="aligned"),
                          canonical_line(time="12:02:00", text="")]}
        (base / canonical.FOLDER).mkdir(parents=True)
        (base / canonical.FOLDER / f"{DAY2}.json").write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
        got = canonical.read_canonical(base, DAY2, today)
        failed += say(got["available"] and len(got["lines"]) == 3 and got["counts"]["lines"] == 3
                      and got["counts"]["plaud"] == 2 and got["counts"]["with_speaker"] == 2,
                      f"GET /canonical: 形を確かめ、おかしな行（時刻・出どころ・空の文）を落とす（{len(got.get('lines', []))}）")
        failed += say(got["lines"][1]["speaker"] is None and got["lines"][1]["speaker_how"] is None,
                      "話し手の無い行は speaker_how も空")
        far = canonical.read_canonical(base, "2025-12-01", today)
        none = canonical.read_canonical(base, DAY1, today)
        (base / canonical.FOLDER / f"{DAY1}.json").write_text(json.dumps(dict(data, day=DAY2)), encoding="utf-8")
        wrong = canonical.read_canonical(base, DAY1, today)
        failed += say(far["available"] is False and none["available"] is False and wrong["available"] is False,
                      "直近 14 日の外・無い日・日付が違う日は available false")
    return failed


def check_windows() -> int:
    failed = 0
    at = datetime.datetime
    ok = [voices.heavy_ok(at(2026, 1, 6, h, m)) for h, m in ((0, 10), (4, 59), (5, 0), (8, 29), (8, 30), (17, 59), (18, 0), (23, 0))]
    failed += say(ok == [True, True, False, False, True, True, False, False], f"重い仕事の時間（{ok}）")
    calls: list[int] = []
    saved = quality.run_voices
    try:
        quality.run_voices = lambda days, budget, today=None: calls.append(days) or {}
        quality.State.voices_at = 0.0
        quality.voices_tick(at(2026, 1, 6, 20, 0))
        quality.voices_tick(at(2026, 1, 6, 2, 0))
        quality.voices_tick(at(2026, 1, 6, 9, 0))
        quality.voices_tick(at(2026, 1, 6, 9, 10))
        failed += say(calls == [2], f"昼の見回り: 重い仕事の時間だけ・30 分に 1 回・夜の流れの時間はしない（{calls}）")
    finally:
        quality.run_voices = saved
        quality.State.voices_at = 0.0
    return failed


def check_http(main) -> int:
    failed = 0
    logged: list[str] = []
    saved = (getattr(main.Handler, "engine", None), getattr(main.Handler, "key", None), main.log)
    saved_state = (quality.State.home, quality.State.store, quality.State.embed)
    old_config = main.load_config()
    with tempfile.TemporaryDirectory() as folder, tempfile.TemporaryDirectory() as mother:
        home = Path(folder)
        server = None
        try:
            days = day_lines()
            store = FakeStore(days)
            embed = FakeEmbed(days)
            built = built_for(home, store, embed)
            voices.save(home, built)
            quality.State.home, quality.State.store, quality.State.embed = home, store, embed
            today = datetime.date.today().isoformat()
            (Path(mother) / canonical.FOLDER).mkdir(parents=True)
            (Path(mother) / canonical.FOLDER / f"{today}.json").write_text(json.dumps(
                {"version": 1, "day": today, "generated_at": "x", "recordings": [], "counts": {},
                 "lines": [canonical_line(source="app", clock="app", rec=None, speaker_how="app")]}, ensure_ascii=False),
                encoding="utf-8")
            main.log = logged.append
            main.Handler.key = KEY
            main.Handler.engine = main.Ensemble(ops.fake_engines())
            config = dict(old_config)
            config["lifelog_home"] = mother
            main.save_config(config)
            server = main.Server(("127.0.0.1", 0), main.Handler)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            client = Client(server.server_address[1])
            hello = client.call("GET", "/hello")
            names = set(hello[1].get("features", [])) if hello[0] == 200 else set()
            failed += say("canonical" in names, "/hello の features に canonical")
            status, body, _ = client.call("GET", "/same-person")
            failed += say(status == 200 and body.get("available") is True and body.get("across") and body.get("maybe")
                          and body["maybe"][0]["named"]["name"] == SECRET_NAME,
                          f"GET /same-person に across・maybe が足される（{status}）")
            status, body, _ = client.call("GET", f"/canonical?day={today}")
            failed += say(status == 200 and body.get("available") is True and len(body.get("lines") or []) == 1,
                          f"GET /canonical?day=: 母艦の正本を返す（{status}）")
            status, _, _ = client.call("GET", "/canonical?day=bad")
            failed += say(status == 400, f"GET /canonical?day=bad は 400（{status}）")
            unauth = [client.call("GET", p, key="wrong")[0] for p in ("/same-person", f"/canonical?day={today}")]
            failed += say(unauth == [401, 401], f"合言葉が違えば 401（{unauth}）")
            text = "\n".join(logged)
            failed += say(SECRET_NAME not in text and SECRET_TEXT not in text, "記録に名前・文を書かない")
        finally:
            if server is not None:
                server.shutdown()
                server.server_close()
            main.save_config(old_config)
            main.Handler.engine, main.Handler.key, main.log = saved
            quality.State.home, quality.State.store, quality.State.embed = saved_state
    return failed


if __name__ == "__main__":
    import lifelog_pc

    sys.exit(1 if run(lifelog_pc) else 0)
