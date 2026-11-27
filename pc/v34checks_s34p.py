"""2026-11-27（s34。担当 p）: 家の PC の s34 の分を確かめる（自6 自分の見本・自7 よく会う人の見本・自8 自動で本番／戻す・
自9 仮の数・K34-2 s34p_status.json・K34-1 GET /s34・円1 の受け口 POST /work/digest）。

    python pc/v34checks_s34p.py          （v33checks_s33p.py の最後にも呼ばれる。CI の手順を増やさずに動かすため）

本物の HOME・母艦・iPhone は使わない（一時フォルダに作りものの記録・声の特徴・予定・PLAUD。人は「甲」「乙」「丙」…の記号だけ）。
モデルは動かさない（声の特徴は作りものの数の並び）。
"""

from __future__ import annotations

import datetime
import io
import json
import os
import sys
import tempfile
import threading
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

if not any(mark in os.environ.get("LOCALAPPDATA", "") for mark in ("v25s", "v26s", "v27s", "v30s", "v31s", "v32s", "v33s", "v34s")):
    os.environ["LOCALAPPDATA"] = str(Path(tempfile.mkdtemp(prefix="v34s-local-")))

import numpy as np  # noqa: E402

import s34pswitch  # noqa: E402
import s34pvoice  # noqa: E402
import s34pwork  # noqa: E402
import voices  # noqa: E402
from v6checks import say  # noqa: E402

TMP = Path(tempfile.mkdtemp(prefix="v34s-"))
TODAY = datetime.date(2026, 11, 27)
D1, D2, D3 = "2026-11-26", "2026-11-25", "2026-11-24"
DIM = 16
RNG = np.random.default_rng(34)
DIRS = {k: v / np.linalg.norm(v) for k, v in ((k, RNG.normal(size=DIM)) for k in ("甲", "乙", "丙", "丁", "戊", "me"))}
KEY = "check-key"


class Store:
    def __init__(self, days: dict) -> None:
        self.days_ = days

    def day(self, day: str):
        return self.days_.get(day)

    def audio_file(self, name: str):
        return Path(name)


class Fake:
    def __init__(self) -> None:
        self.sent: list = []

    def send_json(self, status: int, body) -> None:
        self.sent = [status, body]


def write(path: Path, body) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(body, ensure_ascii=False) if not isinstance(body, str) else body, encoding="utf-8")


def ms(day: str, hh: int, mm: int, ss: int = 0) -> int:
    return int(datetime.datetime.strptime(f"{day} {hh:02d}:{mm:02d}:{ss:02d}", "%Y-%m-%d %H:%M:%S").timestamp() * 1000)


def clock(t: int) -> str:
    return datetime.datetime.fromtimestamp(t / 1000).strftime("%H:%M:%S")


def vec(who: str, noise: float = 0.10) -> np.ndarray:
    v = DIRS[who] + noise * RNG.normal(size=DIM)
    return (v / np.linalg.norm(v)).astype(np.float32)


def make_day(home: Path, day: str, convs: list[dict]) -> dict:
    """convs: [{"at": (時, 分), "lines": [(話し手, speakerID, 声の向き)], "place"?, "work"?, "media"?}]"""
    ds = voices.DayStore(home, day).load()
    conversations = []
    for ci, c in enumerate(convs):
        start = ms(day, *c["at"])
        audio = f"{day.replace('-', '')}-{c['at'][0]:02d}{c['at'][1]:02d}{ci:02d}.m4a"
        lines = []
        for i, (speaker, ident, who) in enumerate(c["lines"]):
            line = {"time": start + i * 3000, "speaker": speaker, "speakerID": ident, "audio": audio,
                    "offset": float(i * 3), "end": float(i * 3) + 2.5, "text": f"見本の行その{i}です"}
            lines.append(line)
            ds.vectors[voices.seg_key(audio, line["offset"], line["end"])] = vec(who)
        conversations.append({"start": start, "end": start + len(lines) * 3000, "lines": lines, "place": c.get("place"),
                              "work": c.get("work"), "media": c.get("media")})
    ds.save()
    return {"conversations": conversations, "audio_names": {}}


def canonical(base: Path, day: str, parsed: dict, plan: dict[int, dict[str, str]]) -> None:
    """plan: {会話の番号: {speakerID: PLAUD の話し手}}（会話ごとに録音 1 本）"""
    rows = []
    for ci, mapping in plan.items():
        for line in parsed["conversations"][ci]["lines"]:
            p = mapping.get(line["speakerID"])
            if p:
                rows.append({"time": clock(line["time"]), "source": "plaud", "clock": "aligned", "speaker": "x",
                             "speaker_id": line["speakerID"], "speaker_how": "line", "plaud_speaker": p, "rec": ci, "text": "x"})
    write(base / "digests" / "canonical" / f"{day}.json", {"version": 1, "day": day, "lines": rows})


def calendar(base: Path, day: str, events: list[tuple[str, str, str]]) -> None:
    text = "".join(f"- {a} - {b} 見本の予定\n  - 相手: {who}\n" for a, b, who in events)
    write(base / "archive" / "calendar" / day[:4] / day[5:7] / f"{day[8:10]}.md", text)


ME = ("自分", "me", "me")


def world() -> tuple[Path, Path, Store]:
    home, base = TMP / "home", TMP / "mother"
    home.mkdir(parents=True, exist_ok=True)
    (base / "state").mkdir(parents=True, exist_ok=True)
    d1 = make_day(home, D1, [
        {"at": (7, 0), "place": "自宅", "lines": [ME] * 4},                                       # 0 家でひとり
        {"at": (7, 30), "place": "自宅", "lines": [ME, ("甲", "p1", "甲")]},                     # 1 家・ほかの声あり
        {"at": (10, 0), "work": True, "lines": [("人物5", "5", "me")] * 12 + [("甲", "p1", "甲")] * 3},  # 2 職場（自分が人物5 に）
        {"at": (13, 0), "lines": [("人物6", "6", "me")] * 10 + [("乙", "p2", "乙")] * 2},       # 3 外
        {"at": (15, 0), "lines": [("甲", "p1", "甲")] * 5 + [("乙", "p2", "乙")] * 5},          # 4
        {"at": (19, 0), "lines": [("人物7", "7", "丙")] * 4 + [ME] * 2},                          # 5 予定の相手 丙
        {"at": (21, 0), "place": "自宅", "media": "tv", "lines": [ME] * 3},                      # 6 テレビ
        {"at": (16, 0), "lines": [("人物8", "8", "乙")] * 10},                                     # 7 PLAUD でいちばん多いが自分ではない
    ])
    canonical(base, D1, d1, {2: {"5": "話者1", "p1": "話者2"}, 3: {"6": "話者1", "p2": "話者2"}, 7: {"8": "話者1"}})
    d2 = make_day(home, D2, [
        {"at": (7, 0), "place": "自宅", "lines": [ME] * 4},
        {"at": (9, 0), "lines": [("甲", "p1", "甲")] * 8 + [("乙", "p2", "乙")] * 8},
        {"at": (19, 0), "lines": [("人物10", "10", "me")] * 5 + [("人物9", "9", "丙")] * 4},     # 予定の相手 丙（自分に近い声は除く）
        {"at": (12, 0), "lines": [("人物11", "11", "丁")] * 3 + [ME] * 2},                       # LINE で約束した 丁
    ])
    d3 = make_day(home, D3, [
        {"at": (8, 0), "lines": [("丙", "p3", "丙"), ("丁", "p4", "丁")] + [("甲", "p1", "甲")] * 8 + [("乙", "p2", "乙")] * 8},
        {"at": (10, 0), "work": True, "lines": [("人物12", "12", "甲")] * 3 + [ME] * 2},         # 会議（甲・乙）
        {"at": (19, 0), "lines": [("人物13", "13", "戊")] * 3},                                  # 予定の相手 戊（記録に名前が無い）
    ])
    calendar(base, D1, [("19:00", "20:00", "丙")])
    calendar(base, D2, [("19:00", "20:00", "丙")])
    calendar(base, D3, [("19:00", "20:00", "戊")])
    write(base / "state" / "talk_guess_for_pc.json", {"items": [
        {"talk_id": "", "day": D2, "start": ms(D2, 12, 0), "end": ms(D2, 12, 30), "candidates": [{"name": "丁", "score": 0.9, "why": ["LINE で約束"]}]}]})
    write(base / "state" / "s32_meeting_people_for_pc.json", {"items": [
        {"day": D3, "start": "10:00", "end": "11:00", "name": "見本の会議", "people": ["甲", "乙"]}]})
    return home, base, Store({D1: d1, D2: d2, D3: d3})


# MARK: - 自6


def check_self() -> int:
    failed = 0
    home, base, store = world()
    body = s34pvoice.collect_self(home, base, store, TODAY)
    c = body["counts"]
    failed += say(c["home"] >= 1 and c["work"] >= 1 and c["out"] >= 1, f"自6: 場面別に見本がある（家 {c['home']}・職場 {c['work']}・外 {c['out']}）")
    home_rows = body["scenes"]["home"]
    failed += say(all(r["why"] == "home_alone" for r in home_rows) and len(home_rows) <= s34pvoice.PER_SCENE,
                  "家でひとりの会話からだけ（テレビ・ほかの声のある会話は使わない）")
    starts = {r["conversation_start"] for r in home_rows}
    failed += say(voices._iso(store.day(D1)["conversations"][1]["start"]) not in starts
                  and voices._iso(store.day(D1)["conversations"][6]["start"]) not in starts, "家でもほかの声・テレビの会話は入らない")
    failed += say(all(r["why"] == "plaud_major" for r in body["scenes"]["work"]), "職場の見本は PLAUD でいちばん多い声から（iPhone は人物5 にしていた）")
    failed += say(body["dropped"]["not_self"] >= 1, "PLAUD でいちばん多くても、自分の声の真ん中から遠い声は入れない")
    failed += say(all(r.get("auto") is True and r["path"].startswith("/audio-clip?") for s in body["scenes"].values() for r in s),
                  "見本は auto の印つき・/audio-clip で聞ける")
    failed += say(body["added"] > 0 and s34pvoice.collect_self(home, base, store, TODAY)["added"] == 0, "2 回目は新しく入った数が 0")
    text = (home / "s34p" / "self-samples.json").read_text(encoding="utf-8")
    failed += say("見本の行" not in text, "見本の置き場に文は入れない")
    # 近さ（levels）で外す
    levels = {"lines": {}, "chunks": {}}
    for line in store.day(D1)["conversations"][2]["lines"]:
        levels["lines"][voices.seg_key(line["audio"], line["offset"], line["end"])] = -40.0
        levels["chunks"][line["audio"]] = {"voicedP50": -20.0}
    write(home / "s22" / "levels" / f"{D1}.json", levels)
    far = s34pvoice.collect_self(home, base, store, TODAY)
    failed += say(far["counts"]["work"] == 0 and far["dropped"]["far"] >= 1, "近い声でない（区切りの真ん中より 3 dB 以上小さい）なら入れない")
    (home / "s22" / "levels" / f"{D1}.json").unlink()
    s34pvoice.collect_self(home, base, store, TODAY)
    # 口
    import selfvoice
    import voicesamples

    saved = (voicesamples.read, selfvoice.read)
    try:
        voicesamples.read = lambda h: {"available": True, "people": [{"speaker": "甲", "speakerID": "p1", "samples": []}]}
        selfvoice.read = lambda h: {"available": True, "steps": []}
        config: dict = {}
        s34pvoice.install(lambda: home, lambda: config)
        got = voicesamples.read(home)
        mine = [p for p in got["people"] if p["speaker"] == "自分"]
        failed += say(len(mine) == 1 and mine[0]["speakerID"] == "me" and mine[0]["auto"] is True and mine[0]["tier"] == "tentative"
                      and {s.get("scene") for s in mine[0]["samples"]} == {"home", "work", "out"},
                      "GET /voice-samples に「自分」の候補（場面つき・仮）")
        failed += say(got["people"][0]["speaker"] == "甲", "今の候補はそのまま")
        sv = selfvoice.read(home)
        failed += say(sv["s34_auto"]["record_needed"] is False and sv["steps"] == [], "GET /self-voice: 3 場面そろえば 3 通り録る操作は要らない")
        config["s34p_self_samples"] = False
        failed += say(not [p for p in voicesamples.read(home)["people"] if p["speaker"] == "自分"]
                      and "s34_auto" not in selfvoice.read(home), "止める（s34p_self_samples: false）")
    finally:
        voicesamples.read, selfvoice.read = saved
    return failed


# MARK: - 自7


def check_people() -> int:
    failed = 0
    home, base, store = world()
    me = s34pvoice.self_center_of(home, store, TODAY)
    failed += say(me is not None and float(me @ DIRS["me"]) > 0.3, "自分の声の真ん中（家でひとりから）")
    body = s34pvoice.collect_people(home, base, store, TODAY, me=me)
    adopted = body["adopted"]
    waiting = {w["name"]: w for w in body["waiting"]}
    failed += say("丙" in adopted and adopted["丙"]["speakerID"] == "p3" and len(adopted["丙"]["days"]) == 2,
                  "予定の相手が 1 人の声が、別の日 2 回そろったら採用")
    failed += say(adopted.get("丙", {}).get("auto") is True and adopted.get("丙", {}).get("similarity", 0) >= s34pvoice.PEOPLE_AGREE,
                  "採用は auto の印つき・近さを控える")
    failed += say("丁" in waiting and waiting["丁"]["sources"] == ["line"], "LINE で約束した相手は 1 回だけなら待ち")
    failed += say("甲" in waiting and "meeting" in waiting["甲"]["sources"], "出席者の分かる会議（2 人以上）は、声がいちばん近い出席者の候補")
    failed += say("戊" not in adopted and "戊" not in waiting, "記録に名前の無い人は対象にしない（人を作らない）")
    samples = adopted.get("丙", {}).get("samples") or []
    failed += say(samples and all(s["audio"].endswith(".m4a") for s in samples)
                  and not any("1910" in s["audio"] and "02" in s["audio"][-6:] for s in samples), "見本は丙の声の行")
    # 自分の声が多い人物10 は除かれ、丙の人物9 が選ばれている
    d2 = [s for s in samples if s["day"] == D2]
    line9 = [x for x in store.day(D2)["conversations"][2]["lines"] if x["speaker"] == "人物9"]
    failed += say(d2 and any(abs(float(d2[0]["offset"]) - x["offset"]) < 0.01 for x in line9), "自分に近い声（人物10）は候補にしない")
    again = s34pvoice.collect_people(home, base, store, TODAY, me=me)
    failed += say(again["added"] == 0 and "丙" in again["adopted"], "採用は残る（2 回目は増えない）")
    counts = s34pvoice.people_counts(home)
    failed += say(counts == {"added": 1, "waiting": len(again["waiting"])}, "数（K34-2 の people_samples）")
    import voicesamples

    saved = voicesamples.read
    try:
        voicesamples.read = lambda h: {"available": True, "people": []}
        config: dict = {"s34p_self_samples": False}
        s34pvoice.install(lambda: home, lambda: config)
        got = voicesamples.read(home)["people"]
        failed += say([p["speaker"] for p in got] == ["丙"] and got[0]["evidence_kinds"] == ["scene", "voice"],
                      "GET /voice-samples に採用した人（名前はそのまま）")
        config["s34p_people_samples"] = False
        failed += say(voicesamples.read(home)["people"] == [], "止める（s34p_people_samples: false）")
    finally:
        voicesamples.read = saved
    return failed


# MARK: - 自8


def check_pairs() -> int:
    failed = 0
    day = D1
    t = ms(day, 10, 0)
    phone, watch = "20261126-100000.m4a", "20261126-100000-w.m4a"

    def line(audio, i, speaker, ident, text, dt=0):
        return {"time": t + i * 4000 + dt, "speaker": speaker, "speakerID": ident, "audio": audio,
                "offset": float(i * 4), "end": float(i * 4) + 3.0, "text": text}

    texts = ["見本の一つ目の発話です", "見本の二つ目の発話です", "見本の三つ目の発話です", "見本の四つ目の発話です"]
    who = [("自分", "me"), ("人物1", "1"), ("自分", "me"), ("人物1", "1")]
    lines = [line(phone, i, *who[i], texts[i]) for i in range(4)]
    lines += [line(watch, i, *who[i], texts[i], dt=300) for i in range(3)]
    lines += [line(watch, 3, "人物2", "2", texts[3], dt=300)]      # 時計は別の人に（確かでない）
    parsed = {"conversations": [{"start": t, "lines": sorted(lines, key=lambda x: x["time"])}]}
    conf = s34pswitch.mic_confident(parsed)
    failed += say(len(conf) == 6 and all(c[1] in ("me", "u:1") for c in conf), "2 本のマイクで印が同じ所だけ確か（違う所は外す）")
    pairs = s34pswitch._pairs_from(conf, day, "mic", 100)
    failed += say(any(p["same"] for p in pairs) and any(not p["same"] for p in pairs), "確かな所から同じ人・違う人の組")
    # PLAUD と合う割合
    rows = []
    for i in range(6):
        ident = "1" if i < 3 else "2"   # iPhone は 1 人（A）を 2 人に分けた
        rows.append({"rec": "0", "plaud": "A", "line": {"speaker": f"人物{ident}", "speakerID": ident, "audio": "a.m4a",
                                                         "offset": float(i * 3), "end": float(i * 3) + 2.0}})
    for i in range(6, 9):
        rows.append({"rec": "0", "plaud": "B", "line": {"speaker": "乙", "speakerID": "p2", "audio": "a.m4a",
                                                         "offset": float(i * 3), "end": float(i * 3) + 2.0}})
    merged = lambda x: "x" if x["speakerID"] in ("1", "2") else "y"  # noqa: E731
    got = s34pswitch.plaud_agreement(rows, merged)
    failed += say(got is not None and got["new"] == 1.0 and got["now"] < 1.0 and got["n"] == 36, "PLAUD と合った所の当たり（分けすぎを直すと上がる）")
    body = {"items": [{"audio": "a.m4a", "start": 9.0, "end": 11.0, "to": {"id": "1", "name": "人物1"}},
                      {"audio": "a.m4a", "start": 12.0, "end": 14.0, "to": {"id": "me", "name": "自分"}}]}
    lab = s34pswitch.label_canonical(body)
    failed += say(lab(rows[3]["line"]) == "u:1" and lab(rows[4]["line"]) == "me" and lab(rows[0]["line"]) == "u:1",
                  "夜の分け直しの案を当てた印（人物N は u:・自分は me）")
    diar = s34pswitch.label_diar({"base_where": {voices.seg_key("a.m4a", 0.0, 2.0): 3}})
    failed += say(diar(rows[0]["line"]) == "c:3" and diar(rows[1]["line"]) is None, "1 日まるごとのかたまりの印")
    return failed


def _measures(home: Path, name: str, start: datetime.date, days: int, now: float, new: float, n: int = 20) -> None:
    for k in range(days):
        day = (start - datetime.timedelta(days=k + 1)).isoformat()
        s34pswitch.record_measures(home, day, {name: {"n": n, "now": now, "new": new}})


def check_switch() -> int:
    failed = 0
    import s26pc
    import s29pc
    import s29pgate

    home = TMP / "switch-home"
    home.mkdir(parents=True, exist_ok=True)
    saved = (s26pc.on, s29pc.on, s29pgate.snorm_mode, s29pgate.apply_snorm)
    try:
        config: dict = {}
        s34pswitch.install(lambda: home, lambda: config)
        failed += say(s29pc.on({}, "s29p_canonical") is False and s26pc.on({}, "s26p_day_diar") is False, "はじめは影のまま")
        _measures(home, "canonical", TODAY, 7, 0.60, 0.70)
        _measures(home, "day_diar", TODAY, 7, 0.60, 0.61)
        _measures(home, "boost", TODAY, 7, 0.40, 0.60)
        _measures(home, "snorm", TODAY, 7, 0.55, 0.80, n=10)
        got = s34pswitch.decide(home, config, TODAY)
        rows = got["state"]["switches"]
        failed += say(got["decided"] and rows["canonical"]["state"] == "on" and "canonical" in got["changed"], "良くなったら自動で本番（canonical）")
        failed += say(rows["day_diar"]["state"] == "shadow", "良くなり方が足りなければ影のまま（day_diar）")
        failed += say(rows["boost"]["state"] == "shadow" and "口がまだ無い" in rows["boost"]["why"], "本番の口が無いもの（boost）は測るだけ")
        failed += say(rows["separate"].get("decision_needed") is True, "speechbrain が要るもの（separate）は判断が要る")
        failed += say(rows["snorm"]["state"] == "on", "s-norm も機械の組で本番に")
        failed += say(s29pc.on({}, "s29p_canonical") is True and s29pgate.snorm_mode({}) == "on", "本番にしたら、今の切り替えが on として読む")
        failed += say(s29pc.on({"s29p_canonical": False}, "s29p_canonical") is False and s29pgate.snorm_mode({"s29p_snorm_score": "off"}) == "off",
                      "本人が config.json に書いた値がいつも上")
        sp = s29pgate.apply_snorm({"days": [{"groups": [{"id": "a", "snorm": 0.1}, {"id": "b", "snorm": 2.0}]}]}, home, {})
        failed += say(sp["s29_score"] == "snorm" and [g["id"] for g in sp["days"][0]["groups"]] == ["b", "a"],
                      "GET /same-person の並びが s-norm に（本人の答えの判断を待たない）")
        log = s34pswitch._jsonl(home / "s34p" / "switch-log.jsonl")
        failed += say({r["name"] for r in log} == {"canonical", "snorm"} and all(r["to"] == "on" for r in log), "切り替えの記録")
        failed += say(s34pswitch.decide(home, config, TODAY + datetime.timedelta(days=3))["decided"] is False, "決めるのは 7 日ごと")
        # 次の週に落ちたら戻す
        week2 = TODAY + datetime.timedelta(days=7)
        _measures(home, "canonical", week2, 7, 0.60, 0.58)
        _measures(home, "snorm", week2, 7, 0.55, 0.80, n=10)
        got = s34pswitch.decide(home, config, week2)
        rows = got["state"]["switches"]
        failed += say(rows["canonical"]["state"] == "rolled_back" and s29pc.on({}, "s29p_canonical") is False, "次の週に数が落ちたら自動で戻す")
        failed += say(rows["snorm"]["state"] == "on", "落ちていなければ本番のまま")
        log = s34pswitch._jsonl(home / "s34p" / "switch-log.jsonl")
        failed += say(log[-1]["name"] == "canonical" and log[-1]["to"] == "rolled_back", "戻した記録")
        week3 = week2 + datetime.timedelta(days=7)
        _measures(home, "canonical", week3, 7, 0.60, 0.70)
        failed += say(s34pswitch.decide(home, config, week3)["state"]["switches"]["canonical"]["state"] == "rolled_back",
                      f"戻してから {s34pswitch.COOL_DAYS} 日はもう一度本番にしない")
        app = {r["name"]: r for r in s34pswitch.for_app(home)}
        failed += say(set(app) == set(s34pswitch.SWITCHES) and app["snorm"]["state"] == "on" and app["snorm"]["now"] == 0.8
                      and all(set(r) >= {"name", "state", "since", "metric", "now", "prev"} for r in app.values()),
                      "K34-1 の auto_switch の形")
        config["s34p_auto_switch"] = False
        failed += say(s29pgate.snorm_mode({"s34p_auto_switch": False}) == "candidate", "自動を止めると前の既定に戻る")
        h2 = TMP / "switch-home2"
        _measures(h2, "canonical", TODAY, 7, 0.60, 0.70)
        failed += say(s34pswitch.decide(h2, {"s34p_auto_switch": False}, TODAY)["state"]["switches"]["canonical"]["state"] == "shadow",
                      "止めてあれば数えるだけ")
        h3 = TMP / "switch-home3"
        _measures(h3, "canonical", TODAY, 2, 0.60, 0.80, n=100)
        failed += say(s34pswitch.decide(h3, {}, TODAY)["state"]["switches"]["canonical"]["state"] == "shadow",
                      f"測れた日が {s34pswitch.MIN_DAYS} 日に足りなければ本番にしない")
        h4 = TMP / "switch-home4"
        _measures(h4, "canonical", TODAY, 7, 0.60, 0.50)
        row = s34pswitch.decide(h4, {"s29p_canonical": True}, TODAY)["state"]["switches"]["canonical"]
        failed += say(row["state"] == "on" and row["by"] == "本人" and not s34pswitch._jsonl(h4 / "s34p" / "switch-log.jsonl"),
                      "本人が書いた値はそのまま（自動で戻さない・記録も増えない）")
    finally:
        s26pc.on, s29pc.on, s29pgate.snorm_mode, s29pgate.apply_snorm = saved
    return failed


def check_measure_world() -> int:
    """作りものの世界で、毎晩の物差しが出ること（PLAUD と合った所・機械の組）"""
    failed = 0
    home, base, store = world()
    import s29pvoice

    s29pvoice.canonical(home, base, store, D1, {})
    got = s34pswitch.measure_day(home, base, store, D1)
    failed += say("canonical" in got and "day_diar" in got and got["canonical"]["n"] > 0, "PLAUD と合った所の当たりが出る")
    failed += say("snorm" in got and got["snorm"]["n"] > 0, "機械の組の AUC が出る")
    failed += say("_scored" not in json.dumps({k: {a: b for a, b in v.items() if not a.startswith("_")} for k, v in got.items()}),
                  "数だけ")
    return failed


# MARK: - 自9


def check_tune() -> int:
    failed = 0
    spec = s34pswitch.TUNABLES["prior_bonus"]
    best, got, base = s34pswitch.best_value(0.02, spec, lambda b: b)   # 大きいほど良い
    failed += say(best == 0.03, f"1 回に max_move まで（0.02 → {best}）")
    best, _, _ = s34pswitch.best_value(0.05, spec, lambda b: b)
    failed += say(best == 0.05, "幅の上を超えない")
    best, _, _ = s34pswitch.best_value(0.02, spec, lambda b: None)
    failed += say(best == 0.02, "材料が無ければ動かさない")
    best, _, _ = s34pswitch.best_value(0.02, spec, lambda b: 1.0)
    failed += say(best == 0.02, "同じ当たりなら今の値")
    rows = [{"score": 0.62, "same": True, "hint": {"prior": True}} for _ in range(15)] + \
           [{"score": 0.50, "same": False, "hint": {"prior": True}} for _ in range(15)]
    score, n = s34pswitch._bonus_score(rows, "prior")
    failed += say(n == 30 and score(0.03) > score(0.02), "加点の当たり（点＋加点 ≥ NAMED_MIN）")
    link, n = s34pswitch._link_score([{"raw": 0.7, "same": True}] * 20 + [{"raw": 0.52, "same": False}] * 20)
    failed += say(link(0.55) == 1.0 and link(0.75) == 0.5, "近さのしきいの当たり（つり合いをとった割合）")
    import s22voice
    import s26pvoice
    import s29pgroups
    import s32pwork

    old = s34pswitch._originals()
    home = TMP / "tune-home"
    try:
        got = s34pswitch.tune(home, None, Store({}), {}, TODAY)
        failed += say(got["tuned"] and got["values"] == old, "材料が無ければ元の値のまま")
        rows = {r["name"]: r for r in s34pswitch.tuned_for_app(home)}
        failed += say(set(rows) == set(s34pswitch.TUNABLES) and all("材料が足りない" in r["why"] and r["old"] == r["new"] for r in rows.values()),
                      "K34-1 の tuned（old・new・range・why）")
        s34pswitch.apply_values({"prior_bonus": 0.03, "guess_bonus": 0.06, "meeting_bonus": 0.04, "group_link": 0.55, "chain_link": 0.55})
        failed += say(s22voice.settings({})["prior_bonus"] == 0.03 and s26pvoice.GUESS_BONUS == 0.06
                      and s32pwork.meeting_score.__defaults__ == (0.04,) and s29pgroups.GROUP_LINK == 0.55
                      and s22voice.settings({})["chain_link"] == 0.55, "当てた値が今の仕組みに入る")
        failed += say(s22voice.settings({"s22_voice": {"prior_bonus": 0.01}})["prior_bonus"] == 0.01, "本人の config の値が上")
        body = json.loads((home / "s34p" / "tuned.json").read_text(encoding="utf-8"))
        body["values"]["prior_bonus"]["new"] = 0.9   # 幅の外は当てない
        write(home / "s34p" / "tuned.json", body)
        failed += say(s34pswitch.current_values(home)["prior_bonus"] == 0.05, "控えの値が幅の外なら幅の中へ")
        got = s34pswitch.tune(home, None, Store({}), {"s34p_tune": False}, TODAY)
        failed += say(not got["tuned"] and s22voice.DEFAULTS["prior_bonus"] == old["prior_bonus"] and s26pvoice.GUESS_BONUS == old["guess_bonus"]
                      and s29pgroups.GROUP_LINK == old["group_link"], "止める（s34p_tune: false）と元の値へ")
    finally:
        s34pswitch.apply_values({})
    return failed


# MARK: - K34-2・GET /s34・裏の仕事


def check_status_and_daily() -> int:
    failed = 0
    home, base, store = world()
    out = s34pwork.daily(home, base, store, {}, TODAY, clock=lambda: datetime.datetime(2026, 11, 27, 20, 0))
    failed += say(all(v == "時間外・時間切れ" for v in out.values()), "重い計算は時間外（20 時）にしない")
    out = s34pwork.daily(home, base, store, {}, TODAY, clock=lambda: datetime.datetime(2026, 11, 27, 0, 30))
    failed += say(all(v == "時間外・時間切れ" for v in out.values()), "00 時台は s26・s29 の夜に譲る")
    out = s34pwork.daily(home, base, store, {}, TODAY, clock=lambda: datetime.datetime(2026, 11, 27, 2, 0))
    failed += say(isinstance(out.get("self"), dict) and isinstance(out.get("people"), dict) and "error" not in json.dumps(out),
                  f"02 時に回る（{json.dumps(out, ensure_ascii=False)[:160]}）")
    st = json.loads((home / s34pwork.STATUS).read_text(encoding="utf-8"))
    failed += say(set(st) >= {"auto_switch", "self_samples", "people_samples"} and set(st["self_samples"]) == {"added", "scenes"}
                  and set(st["self_samples"]["scenes"]) == {"home", "work", "out"} and set(st["people_samples"]) == {"added", "waiting"},
                  "K34-2 の s34p_status.json の形")
    failed += say("丙" not in json.dumps(st, ensure_ascii=False), "s34p_status.json に名前は入れない（数だけ）")
    for moment, want in ((datetime.datetime(2026, 11, 27, 4, 59), True), (datetime.datetime(2026, 11, 27, 5, 0), False),
                         (datetime.datetime(2026, 11, 27, 8, 30), True), (datetime.datetime(2026, 11, 27, 18, 0), False),
                         (datetime.datetime(2026, 11, 27, 0, 59), False)):
        failed += say(s34pwork.heavy_now(moment) is want, f"重い計算の時間 {moment:%H:%M} → {want}")
    return failed


def mother(name: str, body=None, config=None) -> Path:
    base = TMP / name
    (base / "state").mkdir(parents=True, exist_ok=True)
    if body is not None:
        (base / s34pwork.S34).write_text(json.dumps(body, ensure_ascii=False) if not isinstance(body, str) else body, encoding="utf-8")
    if config is not None:
        (base / "state" / "s27_work_config.json").write_text(json.dumps(config), encoding="utf-8")
    return base


SAMPLE = {"self_fixed": {"week": "2026-W48", "speaker": {"fixed": 3, "left": 2, "undone": 0}},
          "auto_switch": [{"name": "snorm", "state": "shadow", "since": None, "metric": "見本", "now": None, "prev": None}]}


def check_get() -> int:
    failed = 0

    def get(base):
        f = Fake()
        s34pwork.http_get(f, "/s34", "", base)
        return f.sent

    st, r = get(mother("ok", SAMPLE))
    failed += say(st == 200 and r == SAMPLE, "GET /s34: 母艦のファイルをそのまま返す")
    failed += say(get(TMP / "nothing")[1].get("available") is False, "母艦が無い → available false")
    failed += say(get(mother("nofile"))[1].get("available") is False, "ファイルが無い → available false")
    failed += say(get(mother("broken", "{こわれ"))[1].get("available") is False, "壊れている → available false")
    off = mother("off", SAMPLE, {"s34p": {"s34": False}})
    failed += say("止めて" in get(off)[1].get("reason", ""), "止める切り替え（s34: false）")
    failed += say(s34pwork.features(off) == [] and s34pwork.features(mother("on", SAMPLE)) == ["s34"]
                  and s34pwork.features(mother("on2")) == [] and s34pwork.features(None) == [], "features: ファイルがあって止めていないときだけ s34")
    saved = s34pwork.S34_READ_MAX
    try:
        s34pwork.S34_READ_MAX = 10
        failed += say("大きすぎ" in get(mother("big", SAMPLE))[1].get("reason", ""), "大きすぎ → available false")
    finally:
        s34pwork.S34_READ_MAX = saved
    return failed


# MARK: - 円1 の受け口


class PostFake(Fake):
    def __init__(self, body: dict) -> None:
        super().__init__()
        raw = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.headers = {"Content-Length": str(len(raw))}
        self.rfile = io.BytesIO(raw)


def check_photo_digest() -> int:
    failed = 0
    import s30pwork

    base = TMP / "photo-mother"
    base.mkdir(parents=True, exist_ok=True)
    entries = [{"id": "0b5d6c1e-6a52-4b3e-9f39-2c5a2f1e8a01", "day": "2026-11-27", "text": "【決まったこと】見本の決まり",
                "sections": {"decided": ["見本の決まり"], "from_photo": True}, "source": "photo", "addedAt": 786000000.5},
               {"id": "0b5d6c1e-6a52-4b3e-9f39-2c5a2f1e8a02", "day": "2026-11-27", "text": "【決まったこと】見本の 2",
                "sections": None, "source": "photo_auto", "addedAt": 786000001.0}]
    clean, problem = s30pwork.check_entries({"entries": entries})
    failed += say(problem is None and len(clean) == 2 and clean[0]["source"] == "photo" and clean[1]["source"] == "photo_auto"
                  and clean[0]["sections"]["from_photo"] is True, "円1: 写真から読んだ文字（写真からの印つき）も今の形のまま通る")
    f = PostFake({"entries": entries})
    s30pwork.http_post(f, "/work/digest", {}, base)
    files = sorted((base / s30pwork.INBOX).glob("*.json"))
    failed += say(f.sent[0] == 200 and f.sent[1]["accepted"] == 2 and len(files) == 2, "POST /work/digest: 母艦の inbox に 1 件 1 ファイル")
    if files:
        row = json.loads(files[0].read_text(encoding="utf-8"))
        failed += say(row.get("source") in ("photo", "photo_auto") and "text" in row, "印（source）がそのまま残る")
    return failed


# MARK: - つなぎ・HTTP


def check_http() -> int:
    failed = 0
    try:
        import lifelog_pc as main
    except Exception as error:  # noqa: BLE001
        print(f"SKIP  lifelog_pc を読み込めないので HTTP の確かめを飛ばす: {type(error).__name__}: {error}", flush=True)
        return failed
    base = mother("http", SAMPLE)
    saved = (getattr(main.Handler, "key", None), main.log, main.load_config)
    had_engine = hasattr(main.Handler, "engine")
    server = None
    try:
        main.Handler.key = KEY
        if not had_engine:
            main.Handler.engine = type("FakeEngine", (), {"label": "check", "provider": "check", "engines": []})()
        main.log = lambda message: None
        main.load_config = lambda: {"lifelog_home": str(base)}
        server = main.Server(("127.0.0.1", 0), main.Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        port = server.server_address[1]

        def call(path: str, key: str | None = KEY) -> tuple[int, dict]:
            req = urllib.request.Request(f"http://127.0.0.1:{port}{path}")
            if key is not None:
                req.add_header("Authorization", f"Bearer {key}")
            try:
                with urllib.request.urlopen(req, timeout=10) as r:
                    return r.status, json.loads(r.read().decode("utf-8"))
            except urllib.error.HTTPError as error:
                return error.code, json.loads(error.read().decode("utf-8") or "{}")

        for key in (None, "wrong"):
            st, r = call("/s34", key)
            failed += say(st == 401 and "self_fixed" not in r, f"GET /s34: 鍵が{'無い' if key is None else '違う'}と 401")
        st, r = call("/s34")
        failed += say(st == 200 and r == SAMPLE, "GET /s34: 鍵が合えば返す")
        st, r = call("/hello")
        failed += say(st == 200 and "s34" in (r.get("features") or []), "features に s34")
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
    failed += say("import s34pwork" in hub and "s34pwork.http_get(" in hub and "s34pwork.features(" in hub and "s34pwork.start(" in hub,
                  "lifelog_pc.py: s34 につないである")
    return failed


CHECKS = [check_self, check_people, check_pairs, check_switch, check_measure_world, check_tune, check_status_and_daily,
          check_get, check_photo_digest, check_http, check_hub]


def run_all() -> int:
    failed = 0
    for check in CHECKS:
        try:
            failed += check()
        except Exception as error:  # noqa: BLE001
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
