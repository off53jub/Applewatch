"""LifeLog PC: s22 確23 場所ごとの言葉の辞書（2026-11-22）。**既定はオフ**（config.json の "place_words": true で使う）。

前に「その時間の地名をヒントに足す」を測ったら少し下がった（hintpolicy.py。2026-11-18）ので、これも測ってから本人が決める。
- 作る（見回りの 30 分ごと・軽い）: 直近 DAYS 日の記録の会話の place ごとに、その場所の行に多く出て、ほかの場所ではあまり出ない言葉
  （カタカナ 3 字以上・漢字 2 字以上の並び）を TOP 個。HOME/s22/place-words.json = {"places": {場所: [言葉…]}}。
  人の名前（記録の話し手の名前）は入れない。
- 使う: 後で受け取る文字起こしのヒントの後ろに、その時刻にいた所（母艦の年表の位置。placehints.stays）の言葉を MAX_HINTS まで。
記録（log.txt）には数だけ。
"""

from __future__ import annotations

import collections
import datetime
import json
import math
import os
import re
from pathlib import Path

import placehints

DAYS = 30
TOP = 8
MAX_HINTS = 5
MIN_COUNT = 3
WORD = re.compile(r"[ァ-ヶー]{3,}|[一-龥]{2,}")
FILE = Path("s22") / "place-words.json"


def build(home: Path, store, today: datetime.date | None = None) -> dict:
    today = today or datetime.date.today()
    per_place: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
    names: set[str] = set()
    for back in range(DAYS):
        parsed = store.day((today - datetime.timedelta(days=back)).isoformat()) if store is not None else None
        for conversation in (parsed or {}).get("conversations") or []:
            place = placehints.clean_name(conversation.get("place") or "")
            for line in conversation.get("lines") or []:
                if line.get("speaker"):
                    names.add(str(line["speaker"]))
                if place and line.get("media") is None:
                    per_place[place].update(WORD.findall(str(line.get("text") or "")))
    spread = collections.Counter()
    for counter in per_place.values():
        spread.update(set(counter))
    total = max(1, len(per_place))
    places = {}
    for place, counter in per_place.items():
        scored = [(count * math.log(1 + total / spread[word]), word) for word, count in counter.items()
                  if count >= MIN_COUNT and word not in names and spread[word] <= max(1, total // 3)]
        words = [w for _, w in sorted(scored, reverse=True)[:TOP]]
        if words:
            places[place] = words
    body = {"generated_at": datetime.datetime.now().isoformat(timespec="seconds"), "days": DAYS, "places": places}
    path = Path(home) / FILE
    path.parent.mkdir(parents=True, exist_ok=True)
    part = path.with_name(path.name + ".part")
    part.write_text(json.dumps(body, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(part, path)
    return {"places": len(places)}


def add(hints: list[str], epoch: float | None, base: Path | None, home: Path, config: dict) -> tuple[list[str], int]:
    """"place_words": true のときだけ、その時刻にいた所の言葉をヒントの後ろに足す"""
    if config.get("place_words") is not True or epoch is None or base is None:
        return hints, 0
    try:
        places = json.loads((Path(home) / FILE).read_text(encoding="utf-8")).get("places") or {}
    except (OSError, ValueError):
        return hints, 0
    when = datetime.datetime.fromtimestamp(epoch)
    minute = when.hour * 60 + when.minute
    here = [s["place"] for s in placehints.stays(base, when.strftime("%Y-%m-%d"))
            if s["start"] <= minute <= max(s["end"], s["start"]) + 5]
    out = list(hints)
    added = 0
    for place in here:
        for word in places.get(place) or []:
            if added >= MAX_HINTS:
                break
            if word not in out:
                out.append(word)
                added += 1
    return out, added
