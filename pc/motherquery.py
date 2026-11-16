"""LifeLog PC: 母艦の「場所・年表・約束・人と場所のページ」を、絞って引く道具（強化案 129。2026-11-16）。

askmother.py（「聞く」の探し方に lookups として）と lifelog_mcp.py（Claude から読む道具）が同じものを使う。
どれも**母艦（mothership.home。ふだんは D:\\Lifelog）を読むだけ**で、ファイルが無ければ空で返す。

  where_at(base, day, time)           その時どこにいたか（年表の位置の行。前後の滞在も）
  day_timeline(base, day, lanes)      1日の年表（時刻・種類・文・場所・金額）。会話の行は include_conversations のときだけ
  by_place(base, name, frm, to)       場所の名前（一部でよい）で、その場所にいた日・時間
  promises(base, who, limit)          約束・宿題（state/TODO.md の open の行。who があればその言葉を含む行）
  person_page(base, name)             人のページ（people/<名前>.md）
  place_page(base, name)              場所のページ（places/<名前>.md）

職場の会話は返さない決まりのまま: 年表の「会話」の行は、呼び出し側が「職場の会話も返してよい」（lifelog_mcp.INCLUDE_WORK）と
決めているときだけ出す。人・場所のページは、会話の行そのものではなくまとめのノート。
位置の座標（緯度経度）は返さない。人の名前は引数で受けるだけで、記録（log.txt）には書かない。
"""

from __future__ import annotations

import datetime
import json
import re
import unicodedata
from pathlib import Path

import mothersearch_extra

LANES_ALL = ("位置", "予定", "決済", "写真", "会話", "LINE", "PC", "閲覧", "天気", "体調")
LIMIT_MAX = 300
PAGE_MAX = 6000
DAY = re.compile(r"^\d{4}-\d{2}-\d{2}$")
CLOCK = re.compile(r"^(\d{1,2}):(\d{2})")
OPEN_TODO = re.compile(r"^\s*-\s*\[ \]\s*(.+)$")


def fold(text: str) -> str:
    return unicodedata.normalize("NFKC", str(text or "")).casefold().replace(" ", "").replace("　", "")


def valid_day(day) -> bool:
    if not isinstance(day, str) or not DAY.match(day):
        return False
    try:
        datetime.date.fromisoformat(day)
    except ValueError:
        return False
    return True


def _minutes(text) -> int | None:
    m = CLOCK.match(str(text or "").strip())
    return int(m[1]) * 60 + int(m[2]) if m else None


def _rows(base: Path, day: str) -> list[dict]:
    try:
        data = json.loads((Path(base) / "digests" / "timeline" / f"{day}.json").read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return []
    rows = data.get("rows") if isinstance(data, dict) else None
    return [r for r in rows or [] if isinstance(r, dict)]


def _out(row: dict) -> dict:
    out = {"time": str(row.get("time") or ""), "lane": str(row.get("lane") or ""),
           "text": mothersearch_extra._clean(row.get("text"))}
    if row.get("end"):
        out["end"] = str(row["end"])
    if row.get("place"):
        out["place"] = mothersearch_extra._clean(row["place"])
    if row.get("amount") not in (None, ""):
        out["amount"] = row["amount"]
    return out


def day_timeline(base: Path, day: str, lanes=None, include_conversations: bool = False, limit: int = 200) -> dict:
    if not valid_day(day):
        raise ValueError("day は YYYY-MM-DD です")
    wanted = [x for x in (lanes or []) if x in LANES_ALL]
    rows, hidden = [], 0
    for r in _rows(base, day):
        lane = r.get("lane")
        if lane == "会話" and not include_conversations:
            hidden += 1
            continue
        if wanted and lane not in wanted:
            continue
        rows.append(_out(r))
    rows.sort(key=lambda r: (_minutes(r["time"]) if _minutes(r["time"]) is not None else 9999))
    limit = max(1, min(int(limit), LIMIT_MAX))
    out = {"day": day, "rows": rows[:limit], "count": len(rows), "excluded_conversations": hidden}
    if len(rows) > limit:
        out["more"] = len(rows) - limit
    return out


def where_at(base: Path, day: str, time_text: str) -> dict:
    """その時刻（HH:MM）にいた所。滞在の行に入っていればそれ、無ければ直前と直後の滞在"""
    if not valid_day(day):
        raise ValueError("day は YYYY-MM-DD です")
    minute = _minutes(time_text)
    if minute is None:
        raise ValueError("time は HH:MM です")
    stays = [_out(r) for r in _rows(base, day) if r.get("lane") == "位置"]
    inside, before, after = [], None, None
    for s in stays:
        a = _minutes(s["time"])
        b = _minutes(s.get("end")) if s.get("end") else a
        if a is None:
            continue
        b = a if b is None else b
        if a <= minute <= b:
            inside.append(s)
        elif b < minute and (before is None or b > (_minutes(before.get("end")) or _minutes(before["time"]) or 0)):
            before = s
        elif a > minute and (after is None or a < (_minutes(after["time"]) or 9999)):
            after = s
    out = {"day": day, "time": time_text, "here": inside}
    if not inside:
        out["before"], out["after"] = before, after
    out["stays_that_day"] = len(stays)
    return out


def by_place(base: Path, name: str, frm: str | None = None, to: str | None = None, limit: int = 50) -> dict:
    wanted = fold(name)
    if len(wanted) < 2:
        raise ValueError("場所の名前は 2 文字以上です")
    folder = Path(base) / "digests" / "timeline"
    days = sorted(p.stem for p in folder.glob("????-??-??.json")) if folder.is_dir() else []
    hits = []
    for day in reversed(days):
        if (frm and day < frm) or (to and day > to):
            continue
        for r in _rows(base, day):
            if r.get("lane") != "位置":
                continue
            o = _out(r)
            if wanted in fold(o.get("place", "")) or wanted in fold(o["text"]):
                hits.append(dict(o, day=day))
    limit = max(1, min(int(limit), LIMIT_MAX))
    out = {"hits": hits[:limit], "count": len(hits), "days_searched": len(days)}
    if len(hits) > limit:
        out["more"] = len(hits) - limit
    return out


def promises(base: Path, who: str | None = None, limit: int = 50) -> dict:
    try:
        text = (Path(base) / "state" / "TODO.md").read_text(encoding="utf-8-sig")
    except OSError:
        return {"items": [], "count": 0}
    items = []
    in_open = False
    for line in text.splitlines():
        if line.startswith("## "):
            in_open = line.strip().lower().startswith("## open")
            continue
        m = OPEN_TODO.match(line)
        if in_open and m:
            items.append(re.sub(r"\s+", " ", m[1]).strip()[:300])
    if who:
        w = fold(who)
        items = [i for i in items if w in fold(i)]
    limit = max(1, min(int(limit), LIMIT_MAX))
    return {"items": items[:limit], "count": len(items)}


def _page(base: Path, folder: str, name: str) -> dict:
    wanted = fold(name)
    if len(wanted) < 1:
        raise ValueError("名前がありません")
    root = Path(base) / folder
    try:
        files = sorted(root.glob("*.md"))
    except OSError:
        files = []
    exact = [p for p in files if fold(p.stem) == wanted]
    near = exact or [p for p in files if wanted in fold(p.stem)]
    if not near:
        return {"found": False, "candidates": []}
    if len(near) > 1 and not exact:
        return {"found": False, "candidates": [p.stem for p in near[:10]]}
    path = near[0]
    try:
        text = path.read_text(encoding="utf-8-sig", errors="replace")
    except OSError:
        return {"found": False, "candidates": []}
    return {"found": True, "name": path.stem, "text": text[:PAGE_MAX], "truncated": len(text) > PAGE_MAX}


def person_page(base: Path, name: str) -> dict:
    return _page(base, "people", name)


def place_page(base: Path, name: str) -> dict:
    return _page(base, "places", name)
