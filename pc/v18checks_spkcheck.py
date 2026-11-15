"""話し手の見比べ（2026-11-16。中身は voices.py の check_day・run_check・read_check、quality.py の GET /speaker-check）を確かめる。

    python pc/v18checks_spkcheck.py

本物の HOME・音声・声のモデルは使わない（一時のフォルダ・作り物の声の特徴）。確かめること:
- 名前のある人の行に、ほかの人の声が混ざっていれば疑いにする（言いそうな人＝その声の人）
- 本人の声の行は疑いにしない・人物N の行は見比べない・行の少ない人は物差しにしない・短い行は見ない
- 物差しは同じ音声の行を除いて作る（1 つの区切りの中で声がそろっていても、その区切りだけで決めない）
- 物差しは直近の日の行をまとめて作る（その日に名前のある人が少なくても、前の日の行で見比べる）
- HOME/same-person/speaker-check.json に置き、GET /speaker-check で返す（古い・形が違うものは出さない）
- voices.run（名寄せ）のついでに作られる・features に spkcheck が並ぶ
- 記録（log.txt）に文・名前を書かない
"""

from __future__ import annotations

import datetime
import json
import os
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import numpy as np  # noqa: E402

import quality  # noqa: E402
import records  # noqa: E402
import voices  # noqa: E402

SECRET_TEXT = "見本の秘密の会話の文です"
SECRET_NAME = "見本花子"
OTHER_NAME = "見本太郎"
DIM = 32
DAY = "2026-01-05"


def say(ok: bool, what: str) -> int:
    print(("OK " if ok else "NG ") + what, flush=True)
    return 0 if ok else 1


def voice(seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    v = rng.normal(size=DIM)
    return v / np.linalg.norm(v)


PEOPLE = {"A": voice(1), "B": voice(2), "ME": voice(3), "U": voice(4)}
BIAS = voice(100) * 1.5  # 日の癖（全部の行に同じだけ）


def line(minute: int, who: str, speaker: str, ident: str, audio: str, start: float = 1.0, length: float = 3.0) -> dict:
    return {"time": f"{DAY}T10:{minute:02d}:{int(start):02d}+09:00", "text": SECRET_TEXT, "speaker": speaker,
            "speakerID": ident, "audio": audio, "offset": start, "end": start + length, "_who": who}


def day_lines() -> list[dict]:
    out = []
    for i in range(5):
        out.append(line(i, "A", SECRET_NAME, "7", f"a-{i}.m4a"))
        out.append(line(10 + i, "B", OTHER_NAME, "8", f"b-{i}.m4a"))
        out.append(line(20 + i, "ME", "自分", "me", f"m-{i}.m4a"))
        out.append(line(30 + i, "U", "人物12", "12", f"u-{i}.m4a"))
    # A の名前が付いているが、声は B（疑いにする。言いそうな人は B＝"8"）
    out.append(line(40, "B", SECRET_NAME, "7", "a-0.m4a", start=10.0))
    # 短い行（1.5 秒より短い）は見ない
    out.append(line(41, "B", SECRET_NAME, "7", "a-1.m4a", start=20.0, length=1.0))
    # 人物12 の行に自分の声が入っていても、人物N は見比べない
    out.append(line(42, "ME", "人物12", "12", "u-0.m4a", start=10.0))
    # 行の少ない名前のある人（2 行だけ）は物差しにしない
    out.append(line(50, "U", "見本次郎", "9", "c-0.m4a"))
    out.append(line(51, "U", "見本次郎", "9", "c-1.m4a"))
    return out


class FakeStore:
    def __init__(self, lines: list[dict]) -> None:
        clean = [{k: v for k, v in x.items() if k != "_who"} for x in lines]
        body = {"conversations": [{"start": clean[0]["time"], "lines": clean}]}
        self.parsed = {DAY: records.parse_record(json.loads(json.dumps(body)))}

    def day(self, day: str):
        return self.parsed.get(day)


def fill_store(home: Path, lines: list[dict], day: str = DAY) -> None:
    """置き場所に、話し手の声＋日の癖＋少しのゆらぎを置く（測ったことにする）"""
    ds = voices.DayStore(home, day)
    rng = np.random.default_rng(9)
    for x in lines:
        key = voices.seg_key(x["audio"], x["offset"], x["end"])
        ds.vectors[key] = PEOPLE[x["_who"]] + BIAS + rng.normal(size=DIM) * 0.15
    ds.save()


class Handler:
    def __init__(self) -> None:
        self.sent = None

    def send_json(self, status, body) -> None:
        self.sent = (status, json.loads(json.dumps(body)))


class URL:
    def __init__(self, path: str, query: str = "") -> None:
        self.path, self.query = path, query


def main() -> int:
    failed = 0
    with tempfile.TemporaryDirectory() as tmp:
        home = Path(tmp)
        lines = day_lines()
        store = FakeStore(lines)
        fill_store(home, lines)

        got = voices.check_day(home, store, DAY)
        items = got["items"] if got else []
        failed += say(got is not None and len(items) == 1, f"疑いは混ざった 1 行だけ（{len(items)} 行）")
        if items:
            x = items[0]
            failed += say(x["assigned"] == "7" and x["suggest"] == "8" and x["audio"] == "a-0.m4a"
                          and x["start"] == 10.0 and x["gap"] >= voices.CHECK_MARGIN,
                          "疑いの行は A の名前で、言いそうな人は B")
            failed += say(x["line_time"].startswith(DAY.replace("-", "-")) and x["line_time"].endswith("Z"),
                          "行の時刻は UTC の ISO で返す")
            failed += say(SECRET_TEXT not in json.dumps(x, ensure_ascii=False)
                          and SECRET_NAME not in json.dumps(x, ensure_ascii=False), "疑いに文・名前を入れない")
        # 見た行: A 5＋混ざった 1・B 5・自分 5（人物N・短い行・2 行だけの人は入らない）
        failed += say(got is not None and got["checked"] == 16, f"見た行は 16（{got and got['checked']}）")
        failed += say(not any(i["assigned"] in ("12", "9") or i["suggest"] in ("12", "9") for i in items),
                      "人物N と行の少ない人は見比べに使わない")

        # 物差しは同じ音声の行を除く: 1 人しか物差しが作れない日は見比べない
        only = FakeStore([x for x in lines if x["_who"] == "A" and x["speakerID"] == "7"])
        got2 = voices.check_day(home, only, DAY)
        failed += say(got2 is not None and got2["checked"] == 0 and got2["items"] == [], "物差しが 1 人なら見比べない")
        failed += say(voices.check_day(home, store, "2026-01-01") is None, "記録の無い日は None")

        # 次の日は自分の行と、A の名前で B の声の行だけ（その日だけでは物差しが 1 人）。前の日とまとめれば見比べられる
        day2 = "2026-01-06"
        later = [{**x, "time": x["time"].replace(DAY, day2), "audio": "n-" + x["audio"]}
                 for x in lines if x["_who"] == "ME" and x["speakerID"] == "me"]
        later.append({**line(45, "B", SECRET_NAME, "7", "n-x.m4a"), "time": f"{day2}T11:45:01+09:00"})
        both = FakeStore(lines)
        both.parsed[day2] = FakeStore(later).parsed[DAY]
        fill_store(home, later, day2)
        alone = voices.check_day(home, both, day2)
        pooled = {d["day"]: d for d in voices.check_days(home, both, [day2, DAY])}
        failed += say(alone is not None and alone["checked"] == 0, "その日だけでは見比べない（物差しが 1 人）")
        failed += say(day2 in pooled and [i["suggest"] for i in pooled[day2]["items"]] == ["8"]
                      and pooled[day2]["items"][0]["day"] == day2 and pooled[DAY]["checked"] == 16,
                      "前の日とまとめた物差しで、次の日の混ざった行を見つける")

        # voices.run のついでに置かれ、GET /speaker-check で読める
        logged: list[str] = []
        voices.run(home, store, logged.append, datetime.date(2026, 1, 5))
        path = home / voices.OUT_FOLDER / voices.CHECK_FILE
        failed += say(path.exists(), "名寄せのついでに speaker-check.json を置く")
        failed += say(any("話し手の見比べ" in m for m in logged)
                      and not any(SECRET_TEXT in m or SECRET_NAME in m or OTHER_NAME in m for m in logged),
                      "記録には数だけを書く")
        read = voices.read_check(home)
        failed += say(read.get("available") is True and len(read["days"]) == 1 and len(read["days"][0]["items"]) == 1
                      and read["days"][0]["checked"] == 16, "GET /speaker-check の中身")

        # 形が違うもの・同じ人を言うもの・人物N を言うものは出さない
        data = json.loads(path.read_text(encoding="utf-8"))
        good = data["days"][0]["items"][0]
        data["days"][0]["items"] += [{**good, "suggest": good["assigned"]}, {**good, "assigned": "人物3"},
                                     {**good, "gap": "大"}, "壊れた行", {**good, "day": "2026-01-04"}]
        data["days"].append({"day": "日付でない", "checked": 3, "items": []})
        data["days"].append({"day": "2026-01-04", "checked": True, "items": []})
        path.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
        read = voices.read_check(home)
        failed += say(len(read["days"]) == 1 and len(read["days"][0]["items"]) == 1, "おかしな行・日は落とす")
        failed += say(voices.read_check(home, now=time.time() + 10 * 86400).get("available") is False,
                      "古いファイルは出さない")
        path.write_text("壊れた", encoding="utf-8")
        failed += say(voices.read_check(home).get("available") is False, "読めないファイルは available false")

        # quality.py の口と features
        voices.run(home, store, logged.append, datetime.date(2026, 1, 5))
        saved = (quality.State.home, quality.State.store, quality.State.embed, quality.State.thread)
        try:
            quality.State.home, quality.State.store, quality.State.embed = home, store, (lambda *_: [])
            failed += say("spkcheck" in quality.features() and "/speaker-check" in quality.GETS,
                          "features に spkcheck・GET /speaker-check の口")
            h = Handler()
            quality.http_get(h, URL("/speaker-check"))
            failed += say(h.sent is not None and h.sent[0] == 200 and h.sent[1].get("available") is True
                          and h.sent[1]["days"][0]["items"][0]["suggest"] == "8", "GET /speaker-check が返す")
            quality.State.embed = None
            failed += say("spkcheck" not in quality.features(), "声の特徴を測れないときは spkcheck を出さない")
        finally:
            quality.State.home, quality.State.store, quality.State.embed, quality.State.thread = saved
    print(("NG の数: " + str(failed)) if failed else "話し手の見比べ（2026-11-16）: ぜんぶ OK", flush=True)
    return failed


if __name__ == "__main__":
    sys.exit(1 if main() else 0)
