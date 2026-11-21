"""2026-11-21（s19「休日のライフログ」の家の PC の分。休12・13・14・15。docs/s19-holiday-pc.md）を確かめる。

    python pc/v23checks_holiday.py

本物の HOME・母艦・iPhone は使わない（一時フォルダに作り物の記録と母艦を作る。話し手は「甲」「乙」「丙」の記号だけ）。確かめること:
- 休12 loud_venue: 場の言葉＋騒がしい（または周りの音が多い）会話だけ印・場の言葉だけ／騒がしいだけでは付けない・
  母艦の滞在の名前でも場の言葉を拾う・声の調子は信用 low（tier_cap）になる
- 休13 in_car_media: iPhone の車内の印（inCar・vehicle。records が読む）で、テレビ印・ナビらしい文・音楽の中の自分でない行だけ印・
  自分の行は入れない・印が無くても動く（動きと車の音からは「maybe」）・印も動きも無ければ付けない
- 休14 media_suspect: 休日（土日・母艦の休日の印）に家で、本人も名前のある人もいなくて、同じ声が 8 割以上
  ・休日でない日・本人の行がある・名前がある・テレビ印は付けない・config で休日だけを外せる
- 休15 couple_topic: 3 人以上で「彼女」「同棲」「家事」「喧嘩」が出たときだけ確かめ待ち（pending・question・行の時刻）・2 人なら付けない・
  名前は入らない（人名のまとめ・付け替えをしない）
- 置き方: 記録を書き換えない・省略可能なフィールドだけ・母艦の inbox に写す・作り直しで中身が同じなら書かない・
  GET /holiday-marks・features・config の "knowme": false で止まる・しきい値は config で上書きでき「仮」と書いてある
"""

from __future__ import annotations

import datetime
import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from v6checks import say  # noqa: E402

TMP = Path(tempfile.mkdtemp(prefix="v23holiday-"))
os.environ["LOCALAPPDATA"] = str(TMP / "local")
os.environ.pop("ANTHROPIC_API_KEY", None)

import holidaymarks  # noqa: E402
import knowme  # noqa: E402
import records  # noqa: E402
import voicetone  # noqa: E402

SAT = "2026-11-21"   # 土曜
WED = "2026-11-18"   # 水曜
assert datetime.date.fromisoformat(SAT).weekday() == 5 and datetime.date.fromisoformat(WED).weekday() == 2


def L(day: str, h: int, m: int, s: int, text: str, speaker, **kw) -> dict:
    line = {"time": f"{day}T{h:02d}:{m:02d}:{s:02d}+09:00", "text": text}
    if speaker == "me":
        line.update(speaker="自分", speakerID="me")
    elif speaker:
        line["speaker"] = speaker
    line.update(kw)
    return line


def conv(day: str, h: int, m: int, lines: list[dict], **kw) -> dict:
    return {"start": f"{day}T{h:02d}:{m:02d}:00+09:00", "end": f"{day}T{h:02d}:{m + 9:02d}:00+09:00", "lines": lines, **kw}


def parsed_of(day: str, convs: list[dict]) -> dict:
    return records.parse_record({"conversations": convs})


def kinds(parsed: dict, day: str, mother: Path | None = None, config: dict | None = None) -> list[list[str]]:
    return [[m["kind"] for m in c["marks"]] for c in holidaymarks.day_marks(parsed, day, mother, config)]


def noisy_lines(day: str, h: int, n: int, noisy: bool, names=("me", "甲", "乙")) -> list[dict]:
    return [L(day, h, 0, i, f"はなし{i}", names[i % len(names)], **({"noisy": True} if noisy else {})) for i in range(n)]


def check_venue(mother: Path) -> int:
    failed = 0
    loud = parsed_of(SAT, [conv(SAT, 19, 0, noisy_lines(SAT, 19, 10, True), place="たぶん居酒屋")])
    failed += say(kinds(loud, SAT) == [["loud_venue"]], "休12: 場の言葉（居酒屋）＋騒がしい行で印")
    m = holidaymarks.day_marks(loud, SAT, None)[0]["marks"][0]
    failed += say(m["effect"] == "speaker_caution" and m["label"] == "見立て（仮）" and m["venue"] == "飲み会" and m["evidence"],
                  "休12: effect は speaker_caution・「見立て（仮）」・根拠つき")
    quiet = parsed_of(SAT, [conv(SAT, 19, 0, noisy_lines(SAT, 19, 10, False), place="たぶん居酒屋")])
    failed += say(kinds(quiet, SAT) == [], "休12: 場の言葉だけ（静か）では印を付けない")
    nowords = parsed_of(SAT, [conv(SAT, 19, 0, noisy_lines(SAT, 19, 10, True), place="たぶん自宅")])
    failed += say(kinds(nowords, SAT) == [], "休12: 騒がしいだけ（場の言葉なし）では印を付けない（78 の信用 low の仕事）")
    music = parsed_of(SAT, [conv(SAT, 19, 0, [L(SAT, 19, 0, i, f"こえ{i}", "甲", sound="音楽") for i in range(10)], event="ライブ")])
    failed += say(kinds(music, SAT) == [["loud_venue"]], "休12: 周りの音（音楽）が多くても印")
    short = parsed_of(SAT, [conv(SAT, 19, 0, noisy_lines(SAT, 19, 3, True), place="居酒屋")])
    failed += say(kinds(short, SAT) == [], "休12: 行が少ない会話は付けない")
    # 母艦の滞在の名前
    (mother / "state").mkdir(parents=True, exist_ok=True)
    (mother / "state" / "stays_labeled.json").write_text(json.dumps({"days": {SAT: {"stays": [
        {"s": "18:00", "e": "21:00", "label": "カラオケ店", "where": ""}]}}}, ensure_ascii=False), encoding="utf-8")
    by_stay = parsed_of(SAT, [conv(SAT, 19, 0, noisy_lines(SAT, 19, 10, True))])
    failed += say(kinds(by_stay, SAT, mother) == [["loud_venue"]] and kinds(by_stay, SAT, None) == [],
                  "休12: 母艦の滞在の名前（カラオケ）でも拾う・母艦が無くても動く")
    after = parsed_of(SAT, [conv(SAT, 22, 0, noisy_lines(SAT, 22, 10, True))])
    failed += say(kinds(after, SAT, mother) == [], "休12: 滞在の時間の外は拾わない")
    # 声の調子: 信用 low
    convs = voicetone.day_numbers(loud, None, None)[0]
    holidaymarks.hold(convs, loud, SAT, None)
    failed += say(convs and convs[0]["trust"] == "low" and convs[0].get("tier_cap") == "tentative"
                  and convs[0]["holiday_marks"] == ["loud_venue"], "休12: 声の調子の信用が low・tier_cap（確定にしない）")
    calm = parsed_of(SAT, [conv(SAT, 19, 0, noisy_lines(SAT, 19, 10, False))])
    c2 = voicetone.day_numbers(calm, None, None)[0]
    holidaymarks.hold(c2, calm, SAT, None)
    failed += say(c2 and c2[0]["trust"] == "normal" and "holiday_marks" not in c2[0], "休12: 印の無い会話の声の調子は変えない")
    return failed


def check_car() -> int:
    failed = 0
    lines = [L(WED, 9, 0, 0, "そろそろ出ようか", "me"), L(WED, 9, 0, 3, "300メートル先、右です", None, media="テレビ"),
             L(WED, 9, 0, 6, "まもなく目的地です", "丙"), L(WED, 9, 0, 9, "いい曲だね", "me"),
             L(WED, 9, 0, 12, "歌声", "丁", sound="音楽"), L(WED, 9, 0, 15, "つぎ曲がるよ", "甲")]
    body = {"conversations": [conv(WED, 9, 0, lines, inCar=True)]}
    parsed = records.parse_record(body)
    failed += say(parsed["conversations"][0]["inCar"] is True and parsed["conversations"][0]["vehicle"] is None,
                  "休13: records が inCar を読む（省略可能）")
    plain = records.parse_record({"conversations": [conv(WED, 9, 0, lines)]})
    failed += say(plain["conversations"][0]["inCar"] is False, "休13: 印が無ければ False（今まで通り）")
    marks = holidaymarks.day_marks(parsed, WED, None)[0]["marks"]
    car = [m for m in marks if m["kind"] == "in_car_media"][0]
    times = {records.parse_time(L(WED, 9, 0, s, "", None)["time"], "t") for s in (3, 6, 12)}
    failed += say(set(car["line_times"]) == times and car["car"] == "strong" and car["effect"] == "not_self",
                  "休13: テレビ印・ナビの文・音楽の中の自分でない行だけ（自分と普通の会話は外す）")
    failed += say(kinds(plain, WED) == [], "休13: 車内の印も乗り物の動きも無ければ付けない（無くても動く）")
    v = records.parse_record({"conversations": [{**conv(WED, 9, 0, lines), "vehicle": "car"}]})
    failed += say(kinds(v, WED) == [["in_car_media"]], "休13: vehicle の文字でも車内")
    maybe = records.parse_record({"conversations": [{**conv(WED, 9, 0, lines), "movement": "電車・車で"}]})
    mm = holidaymarks.day_marks(maybe, WED, None)
    failed += say(mm and mm[0]["marks"][0]["car"] == "maybe", "休13: 印が無くても、乗り物の動き＋ナビの文なら「maybe」（車内は推し量り）")
    train = records.parse_record({"conversations": [{**conv(WED, 9, 0, [L(WED, 9, 0, i, "ふつうの話", "甲") for i in range(8)]),
                                                     "movement": "電車で"}]})
    failed += say(kinds(train, WED) == [], "休13: 電車の動きだけでは車内にしない")
    return failed


def check_media(mother: Path) -> int:
    failed = 0
    voices = [L(SAT, 14, 0, i, f"ことば{i}", "人物7" if i % 10 else "人物8") for i in range(12)]
    sat = parsed_of(SAT, [conv(SAT, 14, 0, voices, place="たぶん自宅")])
    failed += say(kinds(sat, SAT) == [["media_suspect"]], "休14: 休日に家で、同じ声が一方的に続く会話に印（メディアの音（仮））")
    m = holidaymarks.day_marks(sat, SAT, None)[0]["marks"][0]
    failed += say(m["effect"] == "not_self" and m["scope"] == "conversation" and "仮" in m["why"], "休14: effect は not_self・仮と書く")
    wed = parsed_of(WED, [conv(WED, 14, 0, [{**l, "time": l["time"].replace(SAT, WED)} for l in voices], place="たぶん自宅")])
    failed += say(kinds(wed, WED) == [], "休14: 休日でない日は動きを変えない")
    failed += say(kinds(wed, WED, None, {"holiday_marks": {"media_holiday_only": False}}) == [["media_suspect"]],
                  "休14: config で休日だけを外せる")
    (mother / "state" / "holiday").mkdir(parents=True, exist_ok=True)
    (mother / "state" / "holiday" / "days.json").write_text(json.dumps({WED: {"off": True, "why": "祝日"}, SAT: {"off": False}}),
                                                           encoding="utf-8")
    failed += say(kinds(wed, WED, mother) == [["media_suspect"]], "休14: 母艦の休日の印（祝日）を使う")
    failed += say(kinds(sat, SAT, mother) == [], "休14: 母艦が「休みでない」なら土曜でも付けない")
    with_self = voices[:11] + [L(SAT, 14, 0, 50, "えっ", "me")]
    failed += say(kinds(parsed_of(SAT, [conv(SAT, 14, 0, with_self, place="たぶん自宅")]), SAT) == [],
                  "休14: 本人の行があれば付けない")
    named = [{**l, "speaker": "甲"} if i == 3 else l for i, l in enumerate(voices)]
    failed += say(kinds(parsed_of(SAT, [conv(SAT, 14, 0, named, place="たぶん自宅")]), SAT) == [], "休14: 名前のある人がいれば付けない")
    away = parsed_of(SAT, [conv(SAT, 14, 0, voices, place="駅前")])
    failed += say(kinds(away, SAT) == [], "休14: 家でなければ付けない")
    tv = parsed_of(SAT, [conv(SAT, 14, 0, voices, place="たぶん自宅", media="テレビ")])
    failed += say(kinds(tv, SAT) == [], "休14: テレビ印がもうある会話は付けない（二重にしない）")
    mixed = [L(SAT, 14, 0, i, f"ことば{i}", f"人物{i}") for i in range(12)]
    failed += say(kinds(parsed_of(SAT, [conv(SAT, 14, 0, mixed, place="たぶん自宅")]), SAT) == [],
                  "休14: 声がばらばら（来客など）なら付けない")
    return failed


def check_couple() -> int:
    failed = 0
    three = [L(SAT, 20, 0, 0, "最近どうなの", "甲"), L(SAT, 20, 0, 3, "彼女と同棲の話が出てて", "乙"), L(SAT, 20, 0, 6, "へえ", "me"),
             L(SAT, 20, 0, 9, "家事の分担でもめてる", "乙"), L(SAT, 20, 0, 12, "そうなんだ", "丙")]
    p = parsed_of(SAT, [conv(SAT, 20, 0, three)])
    marks = holidaymarks.day_marks(p, SAT, None)[0]["marks"]
    c = [m for m in marks if m["kind"] == "couple_topic"][0]
    t1 = records.parse_time(three[1]["time"], "t")
    t3 = records.parse_time(three[3]["time"], "t")
    failed += say(c["effect"] == "needs_check" and c["pending"] is True and c["line_times"] == [t1, t3]
                  and c["words"] == sorted(["同棲", "家事", "彼女"]),
                  "休15: 3 人以上で「彼女」「同棲」「家事」が出た行を確かめ待ちに（行の時刻つき）")
    failed += say("?" in c["question"] or "？" in c["question"], "休15: 確かめの文がある")
    dumped = json.dumps(holidaymarks.day_marks(p, SAT, None), ensure_ascii=False)
    failed += say(all(name not in dumped for name in ("甲", "乙", "丙")) and "最近どうなの" not in dumped,
                  "休15: 印に人名・会話の文を入れない（人名のまとめ・付け替えをしない）")
    two = parsed_of(SAT, [conv(SAT, 20, 0, [x for x in three if x.get("speaker") != "丙" and x.get("speaker") != "甲"])])
    failed += say(kinds(two, SAT) == [], "休15: 2 人の会話には付けない")
    fight = parsed_of(SAT, [conv(SAT, 20, 0, [L(SAT, 20, 0, 0, "きのう喧嘩してさ", "甲"), L(SAT, 20, 0, 3, "えー", "乙"),
                                              L(SAT, 20, 0, 6, "どうして", "me")])])
    failed += say(kinds(fight, SAT) == [["couple_topic"]], "休15: 「喧嘩」でも（3 人）")
    none = parsed_of(SAT, [conv(SAT, 20, 0, [L(SAT, 20, 0, i, "ふつうの話", n) for i, n in enumerate(("甲", "乙", "me"))])])
    failed += say(kinds(none, SAT) == [], "休15: 言葉が無ければ付けない")
    tv = parsed_of(SAT, [conv(SAT, 20, 0, three, media="テレビ")])
    failed += say(kinds(tv, SAT) == [], "休15: テレビの会話は対象外")
    return failed


def check_files(mother: Path) -> int:
    failed = 0
    (mother / "state" / "holiday" / "days.json").unlink(missing_ok=True)   # 母艦の休日の印が無い（土日で見る）場合
    home = TMP / "home"
    store = records.RecordStore(home, lambda _t: None)
    day = SAT
    body = {"conversations": [
        conv(day, 19, 0, noisy_lines(day, 19, 10, True), place="たぶん居酒屋"),
        conv(day, 20, 30, [L(day, 20, 30, 0, "最近どうなの", "甲"), L(day, 20, 30, 3, "彼女がさ", "乙"), L(day, 20, 30, 6, "へえ", "me")])]}
    store.put(day, json.dumps(body).encode())
    raw = store.path(day).read_bytes()
    logs: list[str] = []
    (mother / "inbox").mkdir(parents=True, exist_ok=True)
    out = holidaymarks.run(home, store, mother, {}, logs.append, [day, WED])
    failed += say(out["counts"] == {"loud_venue": 1, "couple_topic": 1} and out["pending"] == 1,
                  f"置く: 印の数 {out['counts']}")
    failed += say(store.path(day).read_bytes() == raw, "置く: 記録（records）を書き換えない")
    mine = json.loads((home / "holiday-marks" / f"{day}.json").read_text(encoding="utf-8"))
    failed += say(mine["holiday"] is True and mine["thresholds"]["仮"] is True and len(mine["conversations"]) == 2,
                  "置く: 日ごとの印・しきい値に「仮」・休日の印")
    dest = mother / "inbox" / "holiday-marks"
    failed += say((dest / "days" / f"{day}.json").is_file() and (dest / "needs_check.json").is_file(), "置く: 母艦の inbox に写す")
    queue = json.loads((dest / "needs_check.json").read_text(encoding="utf-8"))
    failed += say(isinstance(queue["items"], list) and all(i["kind"] == "couple_topic" for i in queue["items"]),
                  "置く: 確かめ待ちの束（needs_check.json）")
    again = holidaymarks.run(home, store, mother, {}, logs.append, [day])
    failed += say(again["copied"] == 0, "置く: 中身が同じなら書き直さない")
    failed += say(all(name not in "\n".join(logs) for name in ("甲", "乙", "最近どうなの")), "記録（log）には数だけ")
    off = holidaymarks.run(home, store, mother, {}, logs.append, [day], mother_copy=False)
    failed += say(off["copied"] == 0, "母艦への写しだけ止められる")
    custom = holidaymarks.settings({"holiday_marks": {"venue_min_lines": 99, "unknown": 1}})
    failed += say(custom["venue_min_lines"] == 99 and "unknown" not in custom and holidaymarks.DEFAULTS["_note"].startswith("仮"),
                  "しきい値は config で上書きできる・「仮」と書いてある")
    # voicetone の流れの中で
    built = voicetone.build_day(home, store, day, mother)
    lows = [c for c in built["conversations"] if c.get("holiday_marks")]
    failed += say(len(lows) == 1 and lows[0]["trust"] == "low" and built["self"]["low_trust"] >= 1,
                  "声の調子の 1 日の流れ（build_day）でも騒がしい場は信用 low")
    return failed


class Handler:
    def __init__(self) -> None:
        self.sent: tuple = ()

    def send_json(self, code: int, body) -> None:
        self.sent = (code, body)


def check_hub(mother: Path) -> int:
    failed = 0
    home = TMP / "home"
    store = records.RecordStore(home, lambda _t: None)
    cfg = {"value": {}}
    knowme.State.home, knowme.State.store, knowme.State.config = home, store, lambda: cfg["value"]
    knowme.State.mother = lambda: mother
    knowme.State.first_done = True
    h = Handler()
    knowme.http_get(h, "/holiday-marks", f"day={SAT}")
    failed += say(h.sent[0] == 200 and h.sent[1]["available"] and h.sent[1]["day"] == SAT, "GET /holiday-marks?day=")
    knowme.http_get(h, "/holiday-marks", "day=2000-01-01")
    failed += say(h.sent[1] == {"available": False}, "GET /holiday-marks（無い日は available false）")
    knowme.http_get(h, "/holiday-marks", "day=../x")
    failed += say(h.sent[1] == {"available": False}, "GET /holiday-marks（日の形でなければ読まない）")
    failed += say("/holiday-marks" in knowme.GETS and "holidaymarks" in knowme.features(), "knowme の GETS・features に入っている")
    out = knowme.tick(datetime.datetime(2026, 11, 21, 12, 0))
    failed += say(out.get("holidaymarks") == "ok", "knowme の見回りの 1 つとして動く")
    cfg["value"] = {"knowme": False}
    failed += say(knowme.tick() == {} and knowme.features() == [], "config の \"knowme\": false で止まる")
    src = (Path(__file__).resolve().parent / "lifelog_pc.py").read_text(encoding="utf-8")
    failed += say("holidaymarks" not in src, "lifelog_pc.py は触らない（knowme の口に乗せた）")
    return failed


def main() -> int:
    mother = TMP / "mother"
    mother.mkdir(parents=True)
    failed = 0
    for check in (lambda: check_venue(mother), check_car, lambda: check_media(mother), check_couple,
                  lambda: check_files(mother), lambda: check_hub(mother)):
        failed += check()
    print("ぜんぶ OK" if not failed else f"NG の数: {failed}", flush=True)
    return failed


if __name__ == "__main__":
    sys.exit(main())
