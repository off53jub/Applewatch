"""LifeLog PC: s31（2026-11-27。担当 p）の「文字（Teams・LINE）と声の結び」を配る口。取り決め K31-2（名前と形を変えない）。

- GET /links?day=YYYY-MM-DD / GET /links?person=<名前か id>（オーナーの Bearer）
  母艦の state/s31_links_for_app.json（母艦 s31m が作る）を、日か人で絞って返す。
  返事: {"version", "generated_at", "links": [...], "people": [...], "available": true}
  - day: links はその日のもの・people はその日に出てくる人
  - person: people はその人だけ・links はその人の link_ids か、話し手・書き手にその名前があるもの
  - 両方なら両方で絞る
  - 母艦が無い・止めてある・ファイルが無い・大きすぎ・壊れている → {"available": false, "reason": …}
  - day の形が違う、day も person も無い → 400
- features "links"（ファイルがあって、止めていないとき）
- 止める切り替え: 母艦の state/s27_work_config.json の "s31p": {"links": false}（無ければオン）

読むたびに開かない（更新時刻と大きさが同じなら s27pwork の覚えを使う）。中身（文・名前・日）は記録に出さない。
"""

from __future__ import annotations

import datetime
import re
import urllib.parse
from pathlib import Path

import s27pwork

LINKS = Path("state") / "s31_links_for_app.json"
GETS = ("/links",)
LINKS_READ_MAX = 12 * 1024 * 1024   # これより大きければ読まない（仮）
PERSON_MAX = 100
DAY = re.compile(r"\d{4}-\d{2}-\d{2}")


def _switch(base: Path | None) -> bool:
    """state/s27_work_config.json の "s31p" の "links"（書かなければオン）"""
    if base is None:
        return True
    data, _ = s27pwork._load(base, s27pwork.CONFIG, 64 * 1024)
    mine = data.get("s31p") if isinstance(data, dict) else None
    value = mine.get("links") if isinstance(mine, dict) else None
    return value if isinstance(value, bool) else True


def features(base: Path | None) -> list[str]:
    """ファイルがあって、止めていないときだけ links"""
    if base is None or not Path(base).is_dir() or not _switch(base):
        return []
    return ["links"] if (Path(base) / LINKS).is_file() else []


def _valid_day(value) -> bool:
    if not isinstance(value, str) or not DAY.fullmatch(value):
        return False
    try:
        datetime.date.fromisoformat(value)
    except ValueError:
        return False
    return True


def _off(reason: str) -> dict:
    return {"available": False, "reason": reason}


def _names(link: dict) -> set[str]:
    out: set[str] = set()
    text, voice = link.get("text"), link.get("voice")
    if isinstance(text, dict) and isinstance(text.get("who"), list):
        out.update(x for x in text["who"] if isinstance(x, str))
    if isinstance(voice, dict) and isinstance(voice.get("speakers"), list):
        out.update(x for x in voice["speakers"] if isinstance(x, str))
    return out


def select(data: dict, day: str | None, person: str | None) -> dict:
    links = [x for x in data.get("links") or [] if isinstance(x, dict)]
    people = [x for x in data.get("people") or [] if isinstance(x, dict)]
    if day:
        links = [x for x in links if x.get("day") == day]
        people = [x for x in people if isinstance(x.get("days"), list) and day in x["days"]]
    if person:
        key = person.strip().casefold()
        mine = [x for x in people if str(x.get("name") or "").casefold() == key
                or (x.get("person_id") is not None and str(x.get("person_id")).casefold() == key)]
        ids = {i for x in mine for i in (x.get("link_ids") or []) if isinstance(i, str)}
        names = {str(x.get("name")) for x in mine if x.get("name")} or {person.strip()}
        links = [x for x in links if x.get("id") in ids or _names(x) & names]
        people = mine
    return {"version": data.get("version"), "generated_at": data.get("generated_at"),
            "links": links, "people": people, "available": True}


def read_links(base: Path, day: str | None, person: str | None) -> dict:
    data, failure = s27pwork._load(base, LINKS, LINKS_READ_MAX)
    if data is None:
        return _off(s27pwork._reason("文字と声の結び", failure))
    if not isinstance(data.get("links", []), list) or not isinstance(data.get("people", []), list):
        return _off(s27pwork._reason("文字と声の結び", "shape"))
    return select(data, day, person)


def http_get(handler, path: str, query: str, base: Path | None) -> None:
    """GET /links（合言葉は lifelog_pc.py が確かめてから）"""
    params = urllib.parse.parse_qs(query or "")
    day = (params.get("day") or [None])[0]
    person = (params.get("person") or [None])[0]
    if day is not None and not _valid_day(day):
        handler.send_json(400, {"error": "day は YYYY-MM-DD です"})
        return
    if person is not None:
        person = person.strip()
        if not person or len(person) > PERSON_MAX:
            handler.send_json(400, {"error": f"person は 1〜{PERSON_MAX} 文字です"})
            return
    if day is None and person is None:
        handler.send_json(400, {"error": "day か person が要ります"})
        return
    if base is not None and not Path(base).is_dir():
        base = None
    try:
        if base is None:
            handler.send_json(200, _off("母艦が見つかりません"))
        elif not _switch(base):
            handler.send_json(200, _off("止めてあります"))
        else:
            handler.send_json(200, read_links(base, day, person))
    except Exception as error:  # noqa: BLE001
        handler.send_json(200, _off(f"読めませんでした: {type(error).__name__}"))
