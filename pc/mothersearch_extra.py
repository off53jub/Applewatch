"""LifeLog PC: 母艦の場所・予定・支払い・写真の読み取りも意味で探す（強化案 128。2026-11-16）。

mothersearch.py の系統（source）に、次を足す（母艦は**読むだけ**。どのファイルも無ければ何も足さない）:

  timeline      digests/timeline/YYYY-MM-DD.json  1日の年表のうち、位置（滞在）・予定・決済（支払い）・写真の行だけ。
                会話・LINE・PC・閲覧・天気・体調の行は読まない（会話は lifelog-pc と LINE で、すでに入っている）
  calendar      archive/calendar/YYYY/MM/DD.md    予定（時間・題・場所）
  photo-notes   archive/photos/notes/YYYY/MM/DD.md 写真の読み取りの控え（レシート・看板・ホワイトボードなど。画像は読まない）
  places        places/*.md                        場所のノート（立ち寄りの表など）
  places-index  state/places-index.json            場所の台帳（母艦の場所の担当が作る。無ければ state/places_for_app.json）

職場の会話の扱いは今の決まりのまま（本人の決定: 母艦に出してよい）。会話そのものはここでは足さない。
位置の座標（緯度経度）は文に入れない（年表の文の中の座標は消す）。
"""

from __future__ import annotations

import json
import re
from pathlib import Path

SOURCES = ("timeline", "calendar", "photo-notes", "places", "places-index")
UNDATED = ("places", "places-index")
LABELS = {"timeline": "1日の年表（場所・予定・支払い・写真）", "calendar": "予定", "photo-notes": "写真の読み取り",
          "places": "場所のノート", "places-index": "場所の一覧"}
LANES = {"位置": "滞在", "予定": "予定", "決済": "支払い", "写真": "写真"}
COORD = re.compile(r"[（(]\s*-?\d{1,3}\.\d+\s*[,、]\s*-?\d{1,3}\.\d+[^）)]*[）)]?")
DAY_JSON = re.compile(r"^(\d{4}-\d{2}-\d{2})\.json$")
DAY_MD = re.compile(r"^(\d{4})/(\d{2})/(\d{2})\.md$")
NO_EVENTS = "(予定なし)"


def _files(folder: Path, pattern: str):
    try:
        return sorted(folder.glob(pattern)) if folder.is_dir() else []
    except OSError:
        return []


def discover(base: Path, days: set[str] | None, with_state: bool) -> list[tuple[str, Path]]:
    found: list[tuple[str, Path]] = []
    for f in _files(base / "digests" / "timeline", "*.json"):
        m = DAY_JSON.match(f.name)
        if m and (days is None or m.group(1) in days):
            found.append(("timeline", f))
    for source, sub in (("calendar", "archive/calendar"), ("photo-notes", "archive/photos/notes")):
        folder = base / sub
        for f in _files(folder, "*/*/*.md"):
            m = DAY_MD.match(f.relative_to(folder).as_posix())
            if m and (days is None or f"{m.group(1)}-{m.group(2)}-{m.group(3)}" in days):
                found.append((source, f))
    if days is None or with_state:
        for f in _files(base / "places", "*.md"):
            found.append(("places", f))
        for name in ("places-index.json", "places_for_app.json"):
            f = base / "state" / name
            if f.is_file():
                found.append(("places-index", f))
                break
    return found


def day_of(source: str, base: Path, path: Path) -> str | None:
    """日（YYYY-MM-DD）。日の無いものと決められないものは None（呼び出し側がファイルの更新日にする）"""
    if source == "timeline":
        m = DAY_JSON.match(path.name)
        return m.group(1) if m else None
    sub = {"calendar": "archive/calendar", "photo-notes": "archive/photos/notes"}.get(source)
    if sub:
        try:
            m = DAY_MD.match(path.relative_to(base / sub).as_posix())
        except ValueError:
            return None
        return f"{m.group(1)}-{m.group(2)}-{m.group(3)}" if m else None
    return None


def _clean(text) -> str:
    return re.sub(r"\s+", " ", COORD.sub("", str(text or ""))).strip()


def chunk_timeline(text: str) -> list[tuple[str, str, str]]:
    """年表の行を、種類ごとに時間の順で。[(見出し=種類, 時刻, 文)]（mothersearch._pack に渡す）"""
    try:
        data = json.loads(text)
    except ValueError:
        return []
    units: list[tuple[str, str, str]] = []
    for row in (data.get("rows") if isinstance(data, dict) else None) or []:
        if not isinstance(row, dict) or row.get("lane") not in LANES:
            continue
        label = LANES[row["lane"]]
        start, end = str(row.get("time") or ""), str(row.get("end") or "")
        body = _clean(row.get("text"))
        place = _clean(row.get("place"))
        if place and place not in body:
            body = f"{place} {body}".strip()
        amount = row.get("amount")
        if amount not in (None, "") and str(amount) not in body:
            body += f"（{amount}円）"
        units.append((label, start, f"{start}{'〜' + end if end else ''} {body}"))
    units.sort(key=lambda u: (u[0], u[1]))
    return units


def chunk_places_index(text: str) -> list[tuple[str, str, str]]:
    try:
        data = json.loads(text)
    except ValueError:
        return []
    rows: list = data if isinstance(data, list) else []
    if isinstance(data, dict):
        rows = next((data[k] for k in ("places", "items", "entries") if isinstance(data.get(k), list)), [])
    units = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        name = _clean(row.get("name") or row.get("canonical"))
        if not name:
            continue
        aliases = [a for a in (row.get("aliases") or row.get("names") or []) if isinstance(a, str) and a != name]
        bits = [name] + ([f"別名: {'・'.join(aliases[:5])}"] if aliases else [])
        for key, word in (("kind", "種類"), ("visit_days", "来た日数"), ("visits", "来た回数"), ("last_day", "最後に行った日")):
            if row.get(key) not in (None, ""):
                bits.append(f"{word} {row[key]}")
        units.append(("場所", "", "　".join(bits)))
    return units


def day_text_ok(source: str, text: str) -> bool:
    return not (source == "calendar" and NO_EVENTS in text and len(text) < 80)
