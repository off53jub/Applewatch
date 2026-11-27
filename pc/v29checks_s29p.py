"""2026-11-27（s29。担当 P）: 家の PC の s29 の分を確かめる（声22 答えの受け・声9 s-norm の判断・声25 分け間違い・声26 条件・
声19 かたまり・声2 2 本のマイク・声3・声5/7/12/13 正本の候補・声6・声17・夜の通し・つなぎ）。

    python pc/v29checks_s29p.py          （v27checks_s27p.py の最後にも呼ばれる。CI の手順を増やさずに動かすため）

本物の HOME・母艦・iPhone は使わない（一時フォルダに作りものの記録・声の特徴・答え。人は「甲」「乙」「丙」の記号だけ）。
モデルは動かさない（声の特徴は作りものの数の並び）。
"""

from __future__ import annotations

import datetime
import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

if not any(mark in os.environ.get("LOCALAPPDATA", "") for mark in ("v25s", "v26s", "v27s", "v29s")):
    os.environ["LOCALAPPDATA"] = str(Path(tempfile.mkdtemp(prefix="v29s-local-")))

import numpy as np  # noqa: E402

import appfeeds  # noqa: E402
import quality  # noqa: E402
import s23voice  # noqa: E402
import s24night  # noqa: E402
import s24rules  # noqa: E402
import s29panswers  # noqa: E402
import s29pc  # noqa: E402
import s29pgate  # noqa: E402
import s29pgroups  # noqa: E402
import s29pvoice  # noqa: E402
import voices  # noqa: E402
from v6checks import say  # noqa: E402

TMP = Path(tempfile.mkdtemp(prefix="v29s-"))
TODAY = datetime.date(2026, 11, 27)
DIM = 16
RNG = np.random.default_rng(29)
DIRS = {k: v / np.linalg.norm(v) for k, v in ((k, RNG.normal(size=DIM)) for k in ("甲", "乙", "丙", "me", "x", "y"))}


class Store:
    def __init__(self, days: dict) -> None:
        self.days_ = days

    def day(self, day: str):
        return self.days_.get(day)


def write(path: Path, body) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(body, ensure_ascii=False) if not isinstance(body, str) else body, encoding="utf-8")


def jsonl(path: Path, rows: list[dict]) -> None:
    write(path, "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))


def ms(day: str, hh: int, mm: int, ss: int = 0) -> int:
    return int(datetime.datetime.strptime(f"{day} {hh:02d}:{mm:02d}:{ss:02d}", "%Y-%m-%d %H:%M:%S").timestamp() * 1000)


def vec(who: str, noise: float = 0.12) -> np.ndarray:
    v = DIRS[who] + noise * RNG.normal(size=DIM)
    return (v / np.linalg.norm(v)).astype(np.float32)


def make_day(home: Path, day: str, convs: list[tuple[int, list[tuple[str, str | None, str]]]], tag: str = "") -> dict:
    """convs: [(始まりの ms, [(話し手, speakerID, 声の向き)])]。会話ごとに別の音声（区切り）"""
    ds = voices.DayStore(home, day).load()
    conversations = []
    for ci, (start, people) in enumerate(convs):
        audio = f"{day.replace('-', '')}-{100000 + ci:06d}{tag}.m4a"
        lines = []
        for i, (speaker, ident, who) in enumerate(people):
            line = {"time": start + i * 3000, "speaker": speaker, "speakerID": ident, "audio": audio,
                    "offset": float(i * 3), "end": float(i * 3) + 2.5, "text": f"行{i}"}
            lines.append(line)
            ds.vectors[voices.seg_key(audio, line["offset"], line["end"])] = vec(who)
        conversations.append({"start": start, "end": start + len(people) * 3000, "lines": lines})
    ds.save()
    return {"conversations": conversations}


def filler() -> list[tuple[str, str | None, str]]:
    return [("甲", "1", "甲")] * 7 + [("乙", "2", "乙")] * 7 + [("自分", "me", "me")] * 6


def side(parsed: dict, ident: str | None, speaker: str | None = None, n: int = 3) -> list[dict]:
    out = []
    for c in parsed["conversations"]:
        for line in c["lines"]:
            if (ident is None or line["speakerID"] == ident) and (speaker is None or line["speaker"] == speaker):
                out.append({"audio": line["audio"], "start": line["offset"], "end": line["end"]})
    return out[:n]


class Fake:
    def __init__(self) -> None:
        self.sent: list = []
        self.client_address = ("127.0.0.1", 0)

    def send_json(self, status: int, body) -> None:
        self.sent = [status, body]


# MARK: - 声22


def check_receive() -> int:
    failed = 0
    home = TMP / "recv-home"
    original = appfeeds.parse_feedback
    parse = s29panswers.wrap_parse(original, lambda: home)
    old = parse(json.dumps({"kind": "same_person", "id": "sp-20261126-abc", "value": "merged", "day": "2026-11-26"}).encode())
    failed += say(old == {"kind": "same_person", "id": "sp-20261126-abc", "value": "merged", "day": "2026-11-26"},
                  "声22: 前の形（s29_* なし）は前のまま受ける")
    body = {"kind": "same_person", "id": "s29n-1", "value": "different", "day": "2026-11-26", "s29_kind": "move",
            "s29_screen": "voice_review", "s29_scope": "line", "s29_from": "5", "s29_to": "1",
            "s29_a": {"audio": "20261126-100000.m4a", "offset": 3.0, "end": 5.5},
            "s29_b": [{"audio": "20261126-100001.m4a", "start": 0, "end": 2.5}, {"audio": "../x", "start": 0, "end": 1}]}
    row = parse(json.dumps(body).encode())
    failed += say(row.get("s29_kind") == "move" and row.get("s29_a") == [{"audio": "20261126-100000.m4a", "start": 3.0, "end": 5.5}]
                  and len(row.get("s29_b") or []) == 1 and row.get("s29_from") == "5" and row.get("s29_screen") == "voice_review",
                  "声22: 新しい形の s29_*（offset も start として・おかしな見本は落とす）")
    bad = parse(json.dumps({**body, "s29_kind": 5, "s29_from": "名前 は 送らない", "s29_a": "x", "s29_b": None,
                            "s29_scope": "all"}).encode())
    failed += say(bad["value"] == "different" and not any(k.startswith("s29_") and k != "s29_screen" and k != "s29_to" for k in bad),
                  "声22: 形の違う s29_* は落として、答えそのものは受ける")
    try:
        parse(json.dumps({"kind": "same_person", "id": "x", "value": "maybe", "day": "2026-11-26"}).encode())
        failed += say(False, "声22: value の決まりは前のまま")
    except ValueError:
        failed += say(True, "声22: value の決まりは前のまま（merged・different だけ）")
    unknown = parse(json.dumps({**body, "s29_kind": "something_new"}).encode())
    failed += say(unknown["s29_kind"] == "pair", "声22: 知らない s29_kind は pair として受ける")
    s29n = {"kind": "same_person", "id": "s29g-abc", "value": "merged", "day": "2026-11-27", "s29_kind": "merged",
            "s29_pairs": [{"same": True, "ids": ["12", "7"],
                           "people": [[{"audio": "20261126-090000.m4a", "start": 1.0, "end": 4.0}],
                                      [{"audio": "20261125-100000.m4a", "start": 2.0, "end": 5.0}]]},
                          {"same": True, "people": [[{"audio": "x.m4a", "start": 1, "end": 2}], []]}],
            "s29_ids": ["12", "7"], "s29_group": "s29g-abc", "s29_at": "2026-11-27T09:00:00+09:00"}
    row = parse(json.dumps(s29n).encode())
    failed += say(row["s29_kind"] == "merged" and len(row["s29_pairs"]) == 1 and row["s29_pairs"][0]["ids"] == ["12", "7"]
                  and row["s29_ids"] == ["12", "7"] and row["s29_group"] == "s29g-abc" and row["s29_at"] == s29n["s29_at"],
                  "声22: S29N の形（s29_pairs・s29_ids・s29_group・s29_at）を落とさない（片方の見本が無い組は落とす）")
    got = s29panswers.received(home, today=datetime.date.today())
    failed += say(got["app_old"] == 1 and got["app_s29"] == 4 and got["dropped_fields"] >= 5,
                  f"声22: 受けた数を前の形・新しい形で数える（{got}）")
    # 受け口を通して母艦の inbox に s29_* ごと 1 行（s29pc.install の包みで）
    base = TMP / "recv-mother"
    base.mkdir(parents=True)
    import s23voice as sv
    saved = (appfeeds.parse_feedback, sv.answers, sv.groups_with_samples, s24rules.hold_same_person)
    try:
        s29pc.install(lambda: home)
        first = (appfeeds.parse_feedback, sv.answers, sv.groups_with_samples, s24rules.hold_same_person)
        s29pc.install(lambda: home)
        failed += say(first == (appfeeds.parse_feedback, sv.answers, sv.groups_with_samples, s24rules.hold_same_person)
                      and getattr(appfeeds.parse_feedback, "s29p_wrapped", False), "声22: 包みは 1 回だけ入る")
        handler = Fake()
        appfeeds.http_post_feedback(handler, base, json.dumps(body).encode(), lambda m: None)
        rows = [json.loads(x) for x in (base / "inbox" / "app_feedback.jsonl").read_text(encoding="utf-8").splitlines()]
        failed += say(handler.sent[0] == 200 and rows[-1].get("s29_kind") == "move" and rows[-1].get("at"),
                      "声22: POST /feedback を通すと s29_* も母艦の inbox に残る")
    finally:
        appfeeds.parse_feedback, sv.answers, sv.groups_with_samples, s24rules.hold_same_person = saved
    return failed


def check_import() -> int:
    failed = 0
    home, base = TMP / "imp-home", TMP / "imp-mother"
    base.mkdir(parents=True)
    d = "2026-11-26"
    parsed = make_day(home, d, [(ms(d, 10, 0), filler()), (ms(d, 14, 0), [("自分", "me", "me")] * 3 + [("人物5", "5", "甲")] * 4)])
    store = Store({d: parsed})
    groups = {"sp-old-1": {"people": [side(parsed, "1"), side(parsed, "2")], "score": 0.2, "day": d}}
    jsonl(base / "inbox" / "app_feedback.jsonl", [
        {"kind": "same_person", "id": "sp-old-1", "value": "different", "day": d, "at": "2026-11-26T09:00:00+09:00"},
        {"kind": "same_person", "id": "sp-gone", "value": "merged", "day": "2026-11-17", "at": "2026-11-17T09:00:00+09:00"},
        {"kind": "same_person", "id": "s29n-a", "value": "merged", "day": d, "s29_kind": "named",
         "s29_a": side(parsed, None, "人物5", 2), "s29_b": side(parsed, "1", None, 2), "at": "2026-11-26T10:00:00+09:00"},
        {"kind": "same_person", "id": "s29n-b", "value": "merged", "day": d, "s29_kind": "move", "s29_to": "1",
         "s29_a": side(parsed, None, "人物5", 1), "at": "2026-11-26T10:01:00+09:00"},
        {"kind": "same_person", "id": "s29n-c", "value": "different", "day": d, "s29_kind": "keep", "s29_from": "2",
         "s29_a": side(parsed, "1", None, 1), "at": "2026-11-26T10:02:00+09:00"},
        {"kind": "same_person", "id": "s29-merged-1-x", "value": "merged", "day": d, "s29_kind": "merged",
         "s29_pairs": [{"same": True, "ids": ["5", "1"], "people": [side(parsed, "5", None, 2), side(parsed, "1", None, 2)]},
                       {"same": False, "ids": ["5", "2"], "people": [side(parsed, "5", None, 1), side(parsed, "2", None, 1)]}]},
        {"kind": "same_person", "id": "s29g-team", "value": "merged", "day": d, "s29_kind": "named"},
        {"kind": "same_person", "id": "s29g-split", "value": "different", "day": d, "s29_kind": "split"},
        {"kind": "promise", "id": "x", "value": "added", "day": d}])
    groups["s29g-team"] = {"people": [side(parsed, "5", None, 2), side(parsed, "1", None, 2), side(parsed, "2", None, 1)],
                           "day": d, "source": "s29_groups", "score": None}
    groups["s29g-split"] = dict(groups["s29g-team"])
    got = s29panswers.import_feedback(home, base, groups, store.day)
    stored = s29panswers.load(home)["pairs"]
    failed += say(got["old"] == 1 and got["app"] == 5 and got["group"] == 2 and got["unresolved"] == 2
                  and set(stored) == {"sp-old-1", "s29n-a", "s29n-b", "s29n-c", "s29-merged-1-x#0", "s29-merged-1-x#1",
                                      "s29g-team#1", "s29g-team#2"}
                  and stored["s29-merged-1-x#1"]["same"] is False and stored["s29g-team#2"]["same"] is True,
                  f"声22: 前の形は組の見本を写して残す・新しい形は見本か記録から（{got}）")
    failed += say(stored["sp-old-1"]["orig_same"] is False and stored["s29n-c"]["orig_same"] is False
                  and stored["s29n-a"]["orig_same"] is False and len(stored["s29n-b"]["people"][1]) == 3,
                  "声22: 答える前の iPhone の分け（orig_same）・s29_to から相手の見本を探す")
    again = s29panswers.import_feedback(home, base, {}, store.day)
    failed += say(again["changed"] == 0 and "sp-old-1" in s29panswers.load(home)["pairs"],
                  "声22: 組のファイルが消えても、写した答えは残る")
    # 包みを通すと、s24 の答えた組（speaker_answers.pairs の元）に入る
    saved = (s23voice.answers, s23voice.groups_with_samples)
    try:
        s23voice.answers = s29panswers.wrap_answers(s23voice.answers, lambda: home)
        s23voice.groups_with_samples = s29panswers.wrap_groups(s23voice.groups_with_samples)
        pairs = s24night.answer_pairs(home, base, exists=lambda name: True)
        failed += say({p["id"] for p in pairs} >= {"sp-old-1", "s29n-a", "s29n-b", "s29n-c", "s29-merged-1-x#0", "s29g-team#1"}
                      and not {p["id"] for p in pairs} & {"s29g-team", "s29g-split", "s29-merged-1-x"},
                      f"声22: s24 の答えた組の数（speaker_answers.pairs）に入る（{len(pairs)} 組）")
    finally:
        s23voice.answers, s23voice.groups_with_samples = saved
    # spt（母艦のいちばん多く話す人の問い）に名前を打った答え
    jsonl(base / "inbox" / "app_feedback.jsonl", [
        {"kind": "review", "id": "spt-5", "answer": "甲", "at": "2026-11-26T11:00:00+09:00"},
        {"kind": "review", "id": "spt-9", "answer": "新しい人", "at": "2026-11-26T11:00:00+09:00"},
        {"kind": "review", "id": "spt-7", "answer": "unsure"}])
    s = s29panswers.import_spt(home, base, store.day, datetime.date(2026, 11, 26))
    pid = [k for k in s29panswers.load(home)["pairs"] if k.startswith("s29t-")]
    failed += say(s == {"answers": 2, "pairs": 1, "no_match": 1} and len(pid) == 1,
                  f"声22: 「いちばん多く話す人」に打った名前が記録の人と同じなら組に（{s}）")
    return failed


def check_records_diff() -> int:
    failed = 0
    home = TMP / "diff-home"
    d, d2 = "2026-11-26", "2026-11-25"
    first = make_day(home, d, [(ms(d, 10, 0), filler()),
                               (ms(d, 14, 0), [("自分", "me", "me")] * 2 + [("人物5", "5", "甲")] * 5),
                               (ms(d, 16, 0), [("人物8", "8", "x")] * 3)])
    other = make_day(home, d2, [(ms(d2, 10, 0), filler())])
    store = Store({d: first, d2: other})
    got = s29panswers.scan_records(home, store.day, TODAY)
    failed += say(got == {"days": 2, "pairs": 0, "new": 0} and (home / "s29p" / "snap" / f"{d}.json").is_file(),
                  "声22: 初めは写しを作るだけ")
    changed = json.loads(json.dumps(first))
    lines = changed["conversations"][1]["lines"]
    for line in lines[2:5]:      # 人物5 の 3 行を「甲」へ（本人の直し）
        line.update(speaker="甲", speakerID="1")
    for line in changed["conversations"][2]["lines"]:   # 名前の無い人どうしの付け替え（機械のまとめ）
        line.update(speaker="人物9", speakerID="9")
    store.days_[d] = changed
    got = s29panswers.scan_records(home, store.day, TODAY)
    pairs = {k: v for k, v in s29panswers.load(home)["pairs"].items() if k.startswith("s29r-")}
    same = [v for v in pairs.values() if v["same"]]
    diff = [v for v in pairs.values() if not v["same"]]
    failed += say(got["pairs"] == 2 and len(same) == 1 and len(diff) == 1 and same[0]["orig_same"] is False
                  and diff[0]["orig_same"] is True and len(diff[0]["people"][1]) == 2,
                  f"声22: 名前のある人への直しから 同じ人（移した先）・違う人（もとに残った行）の組（{got}）")
    failed += say(all("人物9" not in json.dumps(v) and "8|" not in json.dumps(v["people"]) for v in pairs.values()),
                  "声22: 名前の無い人どうしの付け替えは答えにしない")
    again = s29panswers.scan_records(home, store.day, TODAY)
    failed += say(again["pairs"] == 0, "声22: 同じ直しを二度数えない")
    bulk = json.loads(json.dumps(changed))
    for c in bulk["conversations"][:1]:
        for line in c["lines"]:
            if line["speakerID"] == "2":
                line.update(speaker="丙", speakerID="3")
    s29panswers.BULK_MAX, saved = 3, s29panswers.BULK_MAX
    try:
        store.days_[d] = bulk
        got = s29panswers.scan_records(home, store.day, TODAY)
    finally:
        s29panswers.BULK_MAX = saved
    failed += say(got["pairs"] == 0, "声22: 一度にたくさん変わったら番号の付け替えとみなして入れない")
    return failed


# MARK: - 声9・声25・声26


def answered_world():
    home, base = TMP / "gate-home", TMP / "gate-mother"
    base.mkdir(parents=True, exist_ok=True)
    days = {}
    pairs = []
    for i in range(8):
        d = (TODAY - datetime.timedelta(days=i + 1)).isoformat()
        convs = [(ms(d, 10, 0), filler() + [("人物20", "20", "x")] * 3 + [("人物21", "21", "y")] * 3),
                 (ms(d, 14, 0), [("自分", "me", "me")] * 2 + [(f"人物{30 + i}", str(30 + i), "甲")] * 3),
                 (ms(d, 15, 0), [(f"人物{40 + i}", str(40 + i), "丙")] * 3)]
        days[d] = make_day(home, d, convs)
        p = days[d]
        pairs.append({"id": f"s-{i}", "same": True, "people": [side(p, str(30 + i)), side(p, "1")], "day": d, "orig_same": False})
        pairs.append({"id": f"d-{i}", "same": False, "people": [side(p, str(40 + i)), side(p, "2")], "day": d, "orig_same": True})
    return home, base, Store(days), pairs


def check_snorm() -> int:
    failed = 0
    home, base, store, pairs = answered_world()
    store_body = {"version": 1, "pairs": {p["id"]: {"same": p["same"], "people": p["people"], "day": p["day"], "source": "records",
                                                    "orig_same": p["orig_same"], "at": "2026-11-26T00:00:00"} for p in pairs}}
    write(home / "s29p" / "answers.json", store_body)
    got = s29pgate.answered_pairs(home, base)
    scored = s29pgate.score_pairs(home, got)
    failed += say(len(got) == 16 and scored["pairs"] == 16 and scored["auc_raw"] is not None and scored["auc_raw"] >= 0.9,
                  f"声9: 置いてある声の特徴で答えた組の点（モデルは動かさない。組 {scored['pairs']}・AUC {scored['auc_raw']}）")
    few = s29pgate.snorm_decide({"pairs": 6, "same": 3, "auc_raw": 0.3, "auc_snorm": 0.9})
    failed += say(few["decision"] == "raw" and "足りない" in few["reason"], "声9: 答えた組が少ないうちは今の点のまま")
    good = s29pgate.snorm_decide({"pairs": 14, "same": 5, "auc_raw": 0.31, "auc_snorm": 0.82})
    flat = s29pgate.snorm_decide({"pairs": 14, "same": 5, "auc_raw": 0.80, "auc_snorm": 0.82})
    one_side = s29pgate.snorm_decide({"pairs": 14, "same": 2, "auc_raw": 0.31, "auc_snorm": 0.82})
    failed += say(good["decision"] == "snorm" and flat["decision"] == "raw" and one_side["decision"] == "raw",
                  "声9: N 組以上・両側 4 組以上・s-norm ≥ 今 + 0.05 のときだけ s-norm（7 晩は待たない）")
    s29pgate.record_decision(home, good, "2026-11-26")
    body = {"available": True, "days": [{"day": "2026-11-26", "groups": [{"id": "a", "score": 0.9, "snorm": 0.5},
                                                                        {"id": "b", "score": 0.4, "snorm": 2.5}]}]}
    cand = s29pgate.apply_snorm(body, home, {})
    used = s29pgate.apply_snorm(body, home, {"s29p_snorm_score": "on"})
    failed += say(cand["s29_score"] == "raw" and [g["id"] for g in cand["days"][0]["groups"]] == ["a", "b"]
                  and used["s29_score"] == "snorm" and [g["id"] for g in used["days"][0]["groups"]] == ["b", "a"]
                  and used["days"][0]["groups"][0]["score"] == 0.4,
                  "声9: 既定は候補に出すだけ・\"on\" で判断が s-norm の晩だけ並べ替え（score は前のまま）")
    s29pgate.record_decision(home, few, "2026-11-27")
    again = s29pgate.apply_snorm(body, home, {"s29p_snorm_score": "on"})
    failed += say(again["s29_score"] == "raw", "声9: \"on\" でも、いちばん新しい判断が raw なら今の点のまま")
    rows = (home / "s29p" / "snorm-decisions.jsonl").read_text(encoding="utf-8").splitlines()
    failed += say(len(rows) == 2 and json.loads(rows[-1])["decision"] == "raw", "声9: 判断の数を毎晩 1 行ずつ記録")
    return failed


def check_split() -> int:
    failed = 0
    d = "2026-11-26"
    t0 = ms(d, 12, 0)
    parsed = {"conversations": [
        {"start": t0, "lines": [
            {"time": t0, "audio": "20261126-120000.m4a", "speaker": "自分", "speakerID": "me", "text": "今日はいい天気ですね", "offset": 0, "end": 2},
            {"time": t0 + 500, "audio": "20261126-120000-w.m4a", "speaker": "自分", "speakerID": "me", "text": "今日はいい天気ですね", "offset": 0, "end": 2},
            {"time": t0 + 9000, "audio": "20261126-120000.m4a", "speaker": "人物5", "speakerID": "5", "text": "そうですねえ本当に", "offset": 9, "end": 11},
            {"time": t0 + 9300, "audio": "20261126-120000-w.m4a", "speaker": "人物6", "speakerID": "6", "text": "そうですね本当に", "offset": 9, "end": 11},
            {"time": t0 + 20000, "audio": "20261126-120000-w.m4a", "speaker": "人物6", "speakerID": "6", "text": "まったく別の話です", "offset": 20, "end": 22}]}]}
    mic = s29pgate.mic_checks(parsed)
    failed += say(mic == {"checks": 2, "wrong": 1}, f"声25: iPhone と時計の同じ発話で、話し手の印の食い違いを数える（{mic}）")
    pairs = [{"id": "a", "same": True, "orig_same": False, "people": []}, {"id": "b", "same": False, "orig_same": False, "people": []},
             {"id": "c", "same": True, "orig_same": None, "people": []}]
    base = TMP / "split-mother"
    write(base / "digests" / "canonical" / f"{d}.json", {"lines": [
        {"source": "plaud", "plaud_speaker": "Speaker 1", "speaker_id": "me", "speaker_how": "line", "rec": "r"},
        {"source": "plaud", "plaud_speaker": "Speaker 1", "speaker_id": "me", "speaker_how": "line", "rec": "r"},
        {"source": "plaud", "plaud_speaker": "Speaker 1", "speaker_id": "5", "speaker_how": "line", "rec": "r"},
        {"source": "plaud", "plaud_speaker": "Speaker 2", "speaker_id": "5", "speaker_how": "turn", "rec": "r"}]})
    got = s29pgate.split_wrong(TMP, base, pairs, lambda day: parsed if day == d else None, d,
                               {"scored": [{"raw": 0.7, "same": True}, {"raw": 0.7, "same": False}]})
    failed += say(got["speaker_split_wrong"] == {"wrong": 2, "pairs": 4}
                  and got["s29_split_detail"]["plaud_compared"] == 3 and got["s29_split_detail"]["plaud_either"] == 1
                  and got["s29_split_detail"]["point_wrong"] == 1,
                  f"声25: 分け間違い＝答えた組 1/2 ＋ マイク 1/2 → {{wrong 2, pairs 4}}（PLAUD は内訳だけ）（{got}）")
    none = s29pgate.split_wrong(TMP, None, [], lambda day: None, d)
    failed += say(none["speaker_split_wrong"] is None, "声25: 数が 1 つも無い晩は書かない")
    return failed


def check_gates() -> int:
    failed = 0
    settings = s29pgate.gate_settings({"s29p_gates": {"snorm": {"need": 20, "margin": 0.1}, "boost": {"need": "x"}}})
    failed += say(settings["snorm"]["need"] == 20 and settings["snorm"]["margin"] == 0.1 and settings["boost"]["need"] == 30,
                  "声26: 条件の数は config の s29p_gates で上書き（おかしな値は既定のまま）")
    failed += say(set(s29pgate.GATES) >= {"snorm", "day_diar", "separate", "boost", "canonical", "denoise_embed", "two_mic"}
                  and all({"config", "need", "margin", "metric"} <= set(g) for g in s29pgate.GATES.values()),
                  "声26: s26p_day_diar・重なり・持ち上げ・s-norm ほかの本番入りの条件が 1 か所に")
    body = s29pgate.gates_status({}, {"snorm": {"n": 14, "now": 0.31, "new": 0.82}, "boost": {"n": 5, "now": 1.0, "new": 1.5},
                                      "day_diar": {"n": 40, "now": 0.7, "new": 0.72}}, {"snorm": "candidate"})
    g = body["gates"]
    failed += say(g["snorm"]["candidate"] and not g["boost"]["candidate"] and "足りない" in g["boost"]["why"]
                  and not g["day_diar"]["candidate"] and g["separate"]["why"] == "材料なし" and body["auto_promote"] is False
                  and g["day_diar"]["state"] == "shadow",
                  "声26: 答えた組で良くなったものだけ候補・数が足りない／材料なしは候補にしない・自動で本番にしない")
    return failed


# MARK: - 声19


def check_groups() -> int:
    failed = 0
    home = TMP / "groups-home"
    days = {}
    for i in range(3):
        d = (TODAY - datetime.timedelta(days=i)).isoformat()
        days[d] = make_day(home, d, [(ms(d, 10, 0), filler()),
                                     (ms(d, 13, 0), [("自分", "me", "me")] * 2 + [(f"人物{50 + i}", str(50 + i), "丙")] * 3),
                                     (ms(d, 15, 0), [(f"人物{60 + i}", str(60 + i), "x")] * 3 + [(f"人物{70 + i}", str(70 + i), "x")] * 2)])
    store = Store(days)
    write(home / "same-person" / "voices.json", {"across": [{"id": "sx-1", "people": [{"name": "人物50"}, {"name": "人物51"}]}]})
    body = s29pgroups.build(home, store, TODAY, [])
    groups = body["groups"]
    with50 = [g for g in groups if "人物50" in g["labels"]]
    apart = [g for g in groups if "人物60" in g["labels"] and "人物70" in g["labels"]]
    failed += say(len(with50) == 1 and set(with50[0]["labels"]) == {"人物50", "人物51", "人物52"} and with50[0]["days"] == 3
                  and not apart and body["measure"]["across_kept"] == 1,
                  f"声19: 日をまたいで割れた同じ人を 1 つのかたまりに（同じ区切りの 2 人はまとめない）（{[g['labels'] for g in groups]}）")
    failed += say(set(body["table"]) == {"0.50", "0.55", "0.60", "0.65", "0.70"}, "声19: しきい値を変えた表も残す（仮の数を決めるため）")
    served = s29pgroups.read(home)
    failed += say(served and all(set(g) == {"id", "labels", "score", "seconds", "days"} and isinstance(g["id"], str)
                                 and isinstance(g["score"], float) and isinstance(g["seconds"], float) and isinstance(g["days"], int)
                                 for g in served), "声19: s29_groups の形（id・labels・score・seconds・days）")
    hold = s29pgroups.wrap_hold(lambda body, config=None: s24rules.hold_same_person(body, {"same_person_ask": False}), lambda: home)
    out = hold({"available": True, "days": [{"day": "x", "groups": [{"id": "g"}]}], "across": [{"id": "a"}]})
    failed += say(out.get("s29_groups") == served and out["days"][0]["groups"] == [] and "across" not in out and out["s29_score"] == "raw",
                  "声19: 「同じ人か」の問いを止めていても s29_groups は出す（組は前のとおり抜く）")
    seen = s29pgroups.seen_groups(home)
    failed += say(set(seen) >= {g["id"] for g in served} and all(len(v["people"]) >= 2 for v in seen.values()),
                  "声19・声22: 出したかたまりの見本を残す（まとまり全体の答えを組にするため。groups_with_samples に入る）")
    before = json.dumps(days, sort_keys=True)
    failed += say(json.dumps(store.days_, sort_keys=True) == before, "声19: まとめるだけで記録は書き換えない")
    # 答えた組での当たり
    p = days[TODAY.isoformat()]
    other = days[(TODAY - datetime.timedelta(days=1)).isoformat()]
    answered = [{"id": "a", "same": True, "people": [side(p, "50"), side(other, "51")]},
                {"id": "b", "same": False, "people": [side(p, "50"), side(p, "60")]}]
    m = s29pgroups.build(home, store, TODAY, answered)["measure"]
    failed += say(m["answers"] == 2 and m["answers_right"] == 2, f"声19: 答えた組で当たりを測る（{m}）")
    return failed


# MARK: - 声2・声3・声6・声17


def check_two_mic() -> int:
    failed = 0
    rate = 16000
    rng = np.random.default_rng(3)
    noise = rng.normal(size=rate * 20).astype(np.float32) * 0.01
    burst = noise.copy()
    for a in (2, 6, 11, 15):
        burst[a * rate:(a + 1) * rate] *= 30
    shifted = np.concatenate([np.zeros(int(0.5 * rate), np.float32), burst])[:len(burst)]
    lag, r = s29pvoice.align(burst, shifted, 0.0)
    failed += say(abs(lag - 0.5) < 0.05 and r > 0.5, f"声2: 2 本の音の時間の差を包絡で合わせる（{lag:.2f} 秒・{r:.2f}）")
    failed += say(s29pvoice.classify(-20, -30) == "self" and s29pvoice.classify(-25, -24) == "near" and s29pvoice.classify(-50, -48) == "far",
                  "声2: 大きさの差で 自分／近い相手／遠い人（仮）")
    home = TMP / "mic-home"
    d = "2026-11-26"
    store = Store({d: {"conversations": [{"lines": [
        {"audio": "20261126-120000-w.m4a", "offset": 1, "end": 3, "speaker": "自分", "speakerID": "me", "time": 0, "text": "a"}]}]}})
    none = s29pvoice.two_mic(home, store, [d], lambda b: None, lambda n: s24night.find_audio(home, n))
    failed += say(none["status"] == "材料なし" and none["candidates"] == 0, "声2: 両方そろっていなければ「材料なし」")
    folder = home / "audio" / d
    folder.mkdir(parents=True)
    phone = np.zeros(rate * 20, np.float32)
    watch = np.zeros(rate * 22, np.float32)
    lines = []
    for i, who in enumerate(["me", "x", "me", "x", "me", "x"]):
        start = 1 + i * 3
        loud_w, loud_p = (0.3, 0.05) if who == "me" else (0.05, 0.08)
        seg = rng.normal(size=rate * 2).astype(np.float32)
        phone[start * rate:(start + 2) * rate] = seg * loud_p
        watch[(start + 2) * rate:(start + 4) * rate] = seg * loud_w   # 時計は 2 秒早く始まった
        lines.append({"audio": "20261126-120002.m4a", "offset": float(start), "end": float(start + 2),
                      "speaker": "自分" if who == "me" else "人物5", "speakerID": "me" if who == "me" else "5", "time": 0, "text": "t"})
    (folder / "20261126-120002.m4a").write_bytes(b"P")
    (folder / "20261126-120000-w.m4a").write_bytes(b"W")
    store = Store({d: {"conversations": [{"lines": lines}]}})
    got = s29pvoice.two_mic(home, store, [d], lambda b: phone if b == b"P" else watch, lambda n: s24night.find_audio(home, n))
    failed += say(got["status"] == "測った" and got["pairs"] == 1 and got["lines"] == 6 and got["classes"]["self"] == 3
                  and got["auc_two"] == 1.0, f"声2: そろった所で行ごとに分けて、自分の行の当たりを数える（{got['classes']}・{got['auc_two']}）")
    return failed


def check_denoise_models() -> int:
    failed = 0
    pairs = [{"id": f"p{i}", "same": i % 2 == 0, "people": [[{"audio": f"a{i}", "start": 0, "end": 2}],
                                                          [{"audio": f"b{i}", "start": 0, "end": 2}]]} for i in range(10)]
    def plain(s):
        i = int(s["audio"][1:])
        return voices._unit(np.asarray(vec("甲" if (s["audio"][0] == "a" or i % 2 == 0) else "乙", 0.9), np.float64))

    def clean(s):
        i = int(s["audio"][1:])
        return voices._unit(np.asarray(vec("甲" if (s["audio"][0] == "a" or i % 2 == 0) else "乙", 0.05), np.float64))

    got = s29pvoice.denoise_compare(pairs, plain, clean)
    failed += say(got["pairs"] == 10 and got["denoised"]["auc_raw"] >= got["plain"]["auc_raw"] and got["denoised"]["auc_raw"] == 1.0,
                  f"声3: 消した音と消さない音で答えた組の AUC を比べる（{got['plain']['auc_raw']} → {got['denoised']['auc_raw']}）")
    home = TMP / "models-home"
    (home / "speaker").mkdir(parents=True)
    (home / "speaker" / "have.onnx").write_bytes(b"x")
    table = s29pvoice.compare_models(home, pairs, pairs[:4], lambda name: clean,
                                     {"have": {"file": "have.onnx"}, "missing": {"file": "missing.onnx"}})
    failed += say(table["missing"]["status"] == "無し" and table["have"]["status"] == "測った"
                  and table["have"]["answers"]["pairs"] == 10, "声17: 手元に無いモデルは「無し」で飛ばす（取ってこない）")
    parts = s29pvoice.separate_parts()
    failed += say(set(parts) == {"speechbrain", "torch"} and all(isinstance(v, bool) for v in parts.values()),
                  "声6: 部品があるかだけを見る（入れない）")
    return failed


# MARK: - 声5・声7・声12・声13


def check_canonical() -> int:
    failed = 0
    home = TMP / "canon-home"
    d = "2026-11-26"
    t = ms(d, 18, 0)
    convs = [(ms(d, 10, 0), filler()),
             (ms(d, 14, 0), [("自分", "me", "me")] * 2 + [("人物5", "5", "甲")] * 3),
             (ms(d, 16, 0), [("自分", "me", "me"), ("人物8", "8", "x"), ("自分", "me", "me"), ("人物8", "8", "x"), ("自分", "me", "me")]),
             (ms(d, 16, 1), [("自分", "me", "me"), ("人物9", "9", "x"), ("自分", "me", "me"), ("人物9", "9", "x"), ("自分", "me", "me")]),
             (t, [("自分", "me", "me")] * 2 + [("人物11", "11", "丙")] * 3),
             (ms(d, 20, 0), [("人物12", "12", "x")] * 3 + [("人物13", "13", "y")] * 3)]
    parsed = make_day(home, d, convs)
    # 声12: 16:00 と 16:01 は 1 つの会話の 2 つの区切り
    c16, c161 = parsed["conversations"][2], parsed["conversations"][3]
    c16["lines"] += c161["lines"]
    parsed["conversations"].remove(c161)
    store = Store({d: parsed})
    refs = {"丙": (voices._unit(DIRS["丙"].astype(np.float64)), 10)}
    ids_line = {"time": t, "speaker": "丙", "speakerID": "3", "audio": "20261126-999999.m4a", "offset": 0.0, "end": 2.5, "text": "x"}
    parsed["conversations"][0]["lines"].append(ids_line)
    body = s29pvoice.canonical(home, None, store, d, refs, headcounts=[(ms(d, 20, 0), ms(d, 21, 0), 2)],
                               hints=[(t - 60000, t + 600000, "丙", "calendar")])
    items = body["items"]
    by_from = {}
    for it in items:
        by_from.setdefault(it["from"]["name"], set()).add((it["to"]["name"], tuple(it["why"])))
    failed += say(("甲", ("diar",)) in by_from.get("人物5", set()), f"声5: 名前のある人の束に入った人物N に付け直し案（{by_from.get('人物5')}）")
    failed += say(any(to == "人物8" and "chain" in why for to, why in by_from.get("人物9", set())),
                  f"声12: 交互の鎖で、区切りごとに割れた相手を前の人物N へ（{by_from.get('人物9')}）")
    failed += say(any(to == "丙" and "hint" in why for to, why in by_from.get("人物11", set())),
                  f"声13: 予定の相手が 1 人の時間で、声が近ければその人へ（{by_from.get('人物11')}）")
    failed += say(body["counts"]["headcount"] >= 1, f"声7: 人数の分かる会話は自分以外を 人数 − 1 まで（{body['counts']}）")
    failed += say(all(set(i) == {"time", "audio", "start", "end", "from", "to", "why"} for i in items)
                  and json.dumps(store.days_[d]) == json.dumps(parsed), "声5: 候補の形・記録は書き換えない")
    off = s29pvoice.read_canonical(home, d, False)
    on = s29pvoice.read_canonical(home, d, True, {"candidate": False})
    failed += say(off["available"] is False and "items" not in off and on["available"] and on["items"] == items
                  and on["gate"] == {"candidate": False}, "声5: 既定オフは何も出さない・オンで GET /s29/canonical に")
    guess = s29pvoice.same_of(body)
    pair = {"people": [side(parsed, "5", None, 2), side(parsed, "1", None, 2)], "same": True}
    failed += say(guess(pair) is True and guess({"people": [[{"audio": "nope", "start": 0, "end": 1}], side(parsed, "1")]}) is None,
                  "声26: 正本の候補の束で答えた組を当てる（見本が無ければ数えない）")
    return failed


# MARK: - 夜の通し・つなぎ


def check_night() -> int:
    failed = 0
    home, base, store, pairs = answered_world()
    home2 = TMP / "night-home"
    import shutil

    shutil.copytree(home, home2)
    write(home2 / "s29p" / "answers.json", {"version": 1, "pairs": {p["id"]: {
        "same": p["same"], "people": p["people"], "day": p["day"], "source": "records", "orig_same": p["orig_same"],
        "at": "2026-11-26T00:00:00"} for p in pairs}})
    out = s29pc.night(home2, base, store, {}, TODAY, deadline=None, load_audio=lambda b: None, denoise_parts=lambda: None)
    errors = {k: v for k, v in out.items() if isinstance(v, dict) and "error" in v}
    daily = quality.read_daily(home2)["days"].get("2026-11-26") or {}
    gates = json.loads((home2 / "s29p" / "gates.json").read_text(encoding="utf-8"))
    failed += say(not errors and out["denoise"] == "off" and out["two_mic"] == "材料なし", f"夜の通し: つまずき無し（{errors or out}）")
    failed += say(daily.get("speaker_split_wrong") == {"wrong": 16, "pairs": 16} and daily["s29_snorm"]["pairs"] == 16
                  and "s29_answers" in daily and "s29_split_detail" in daily,
                  f"声25・声9: quality-daily.json の昨日に speaker_split_wrong・s29_snorm（{daily.get('speaker_split_wrong')}）")
    failed += say(gates["auto_promote"] is False and gates["gates"]["snorm"]["n"] == 16 and gates["gates"]["canonical"]["state"] == "off"
                  and gates["gates"]["day_diar"]["state"] == "off",
                  "声26: 夜に gates.json（自動で本番にしない・既定はオフのまま）")
    s29pc.S.home = home2
    try:
        handler = Fake()
        s29pc.http_get(handler, "/s29/gates")
        g = handler.sent
        s29pc.http_get(handler, "/s29/canonical", "day=2026-11-26")
        c = handler.sent
        worries, lines = s29pc.summary_lines()
    finally:
        s29pc.S.home = None
    failed += say(g[0] == 200 and g[1]["available"] and c[1]["available"] is False and c[1]["on"] is False,
                  "GET /s29/gates・/s29/canonical（既定オフ）")
    failed += say(len(lines) == 6 and not any("数えられませんでした" in x for x in lines), f"summary.md の「## s29 の数」（{len(lines)} 行）")
    return failed


def check_hub() -> int:
    failed = 0
    text = (Path(__file__).resolve().parent / "lifelog_pc.py").read_text(encoding="utf-8")
    failed += say("import s29pc" in text and "s29pc.features()" in text and "s29pc.start(sys.modules[__name__])" in text
                  and "path in s29pc.GETS" in text, "lifelog_pc.py: features・start・GET の道につないである")
    block = text[text.index("path in s29pc.GETS"):][:200]
    failed += say("self.authorized()" in block, "lifelog_pc.py: /s29/* はオーナーの鍵の後ろ")
    ops = (Path(__file__).resolve().parent / "ops.py").read_text(encoding="utf-8")
    failed += say("s29pc.summary_lines" in ops, "ops.py: summary.md に s29 の節")
    import mothership
    import s26pc
    import s27pwork

    failed += say(not set(s29pc.GETS) & (set(mothership.GETS) | set(s26pc.GETS) | set(s27pwork.GETS) | set(quality.GETS)),
                  "ほかの口と道の名前がぶつからない")
    failed += say(all(not s29pc.DEFAULTS[k] for k in ("s29p_canonical", "s29p_denoise_embed")), "既定: 正本の候補・雑音を消した特徴はオフ")
    return failed


CHECKS = [check_receive, check_import, check_records_diff, check_snorm, check_split, check_gates, check_groups, check_two_mic,
          check_denoise_models, check_canonical, check_night, check_hub]


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
