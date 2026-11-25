"""LifeLog PC: s26 結7（2026-11-25。担当 P）。記録を引く口（lifelog_mcp.py）に足す道具の中身。母艦（mothership.home）を読むだけ。

読む道具:
  get_body(day)                 体の記録（母艦 archive/health/YYYY/MM/DD.md。睡眠・歩数・心拍など）
  search_line(query, from, to)  LINE の行を言葉で探す（母艦 archive/line。reports/line-rooms.md で「外す」にした部屋は出さない）
  list_photos(day)              その日の写真・動画の一覧（母艦 archive/photos の索引。名前と時刻だけ。画像は返さない）
  day_actuals(day)              予定の実績（その日の予定の行と、その時刻に実際にいた所・その時間の会話の数）
  events_since(since, limit)    出来事の流れ（母艦 state/events_stream.jsonl。取り決め K8）
書く道具（**候補を置くだけ**。台帳・人物ノート・TODO には書かない。母艦の M が読み、決めるのは本人）:
  add_note(text, day)                       → 母艦 inbox/mcp_candidates.jsonl に {"kind":"note",...}
  add_person_fact(name, fact, evidence)     → 同じファイルに {"kind":"person_fact",...}（人物ノートを作るのは事実 2 件以上の決まりのまま）
HOME（%LOCALAPPDATA%\\LifeLogPC）には書かない。中身は記録に書かない（数だけ）。
"""

from __future__ import annotations

import datetime
import json
import re
import threading
import unicodedata
from pathlib import Path

import motherquery
import s26pfeeds

PAGE_MAX = 8000
LINE_LIMIT_MAX = 300
CANDIDATES = Path("inbox") / "mcp_candidates.jsonl"
LINE_ROW = re.compile(r"^\s*-\s*\*\*(\d{1,2}:\d{2})\*\*\s*([^:：]{0,40})[:：]\s*(.*)$")
ROOM = re.compile(r"^## (.{1,80})$")
ROOM_OFF = re.compile(r"^- \[([xX])\]\s*`(.+?)`|^- \[ \]\s*外す\s*`(.+?)`|^外す\s*-?\s*\[?[ xX]?\]?\s*`(.+?)`")
_lock = threading.Lock()


def fold(text: str) -> str:
    return unicodedata.normalize("NFKC", str(text or "")).lower()


def _day(day) -> str:
    if not motherquery.valid_day(day):
        raise ValueError("day は YYYY-MM-DD です")
    return day


def _archive(base: Path, kind: str, day: str) -> Path:
    return Path(base) / "archive" / kind / day[:4] / day[5:7] / f"{day[8:10]}.md"


def _page(path: Path) -> dict:
    try:
        text = path.read_text(encoding="utf-8-sig")
    except OSError:
        return {"found": False}
    out = {"found": True, "text": text[:PAGE_MAX]}
    if len(text) > PAGE_MAX:
        out["more"] = len(text) - PAGE_MAX
    return out


def get_body(base: Path, day: str) -> dict:
    return {"day": _day(day), **_page(_archive(base, "health", day))}


def list_photos(base: Path, day: str) -> dict:
    return {"day": _day(day), **_page(_archive(base, "photos", day))}


def rooms_off(base: Path) -> set[str]:
    try:
        lines = (Path(base) / "reports" / "line-rooms.md").read_text(encoding="utf-8-sig").splitlines()
    except OSError:
        return set()
    out = set()
    for line in lines:
        m = ROOM_OFF.match(line.strip())
        if m:
            out.add(m.group(2) or m.group(3) or m.group(4))
    return out


def search_line(base: Path, query: str, frm: str | None = None, to: str | None = None, limit: int = 50) -> dict:
    terms = [fold(t) for t in str(query or "").split() if t.strip()]
    if not terms:
        raise ValueError("query が空です")
    limit = max(1, min(int(limit or 50), LINE_LIMIT_MAX))
    folder = Path(base) / "archive" / "line"
    files = sorted(folder.glob("????/??/??.md"), reverse=True) if folder.is_dir() else []
    off = rooms_off(base)
    hits, hidden = [], 0
    for path in files:
        day = f"{path.parent.parent.name}-{path.parent.name}-{path.stem}"
        if (frm and day < frm) or (to and day > to):
            continue
        try:
            lines = path.read_text(encoding="utf-8-sig").splitlines()
        except OSError:
            continue
        room = None
        for raw in lines:
            head = ROOM.match(raw)
            if head:
                room = head.group(1).strip()
                continue
            m = LINE_ROW.match(raw)
            if not m:
                continue
            if not all(t in fold(raw) for t in terms):
                continue
            if room in off:
                hidden += 1
                continue
            hits.append({"day": day, "time": m.group(1), "room": room, "who": m.group(2).strip(), "text": m.group(3)[:500]})
            if len(hits) >= limit:
                return {"hits": hits, "more": True, "excluded_rooms": hidden}
    return {"hits": hits, "excluded_rooms": hidden}


def day_actuals(base: Path, day: str, conversations=None) -> dict:
    """予定の行ごとに、その時刻にいた所と、その時間（始まり〜終わり。終わりが無ければ 1 時間）の会話の数"""
    day = _day(day)
    plan = motherquery.day_timeline(base, day, ["予定"], include_conversations=False, limit=100)["rows"]
    out = []
    for row in plan:
        start = motherquery._minutes(row.get("time"))
        if start is None:
            out.append({**row, "where": None})
            continue
        end = motherquery._minutes(row.get("end")) or start + 60
        where = motherquery.where_at(base, day, row["time"])
        here = where.get("here") or []
        item = {**row, "where": [h.get("place") or h.get("text") for h in here][:3] or None}
        if not here:
            item["where_before"] = (where.get("before") or {}).get("place")
        if conversations is not None:
            item["conversations"] = sum(1 for a, b in conversations if a <= end and b >= start)
        out.append(item)
    return {"day": day, "plans": out, "count": len(out)}


def events_since(base: Path, since: str | None = None, limit: int = 100) -> dict:
    return s26pfeeds.read_events(base, since, limit)


def _append(base: Path, row: dict) -> dict:
    path = Path(base) / CANDIDATES
    row = {**row, "at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"), "by": "mcp", "status": "candidate"}
    with _lock:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8", newline="\n") as handle:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")
    return {"ok": True, "placed": "候補として置きました（決めるのは本人・母艦が次の回に読む）"}


def add_note(base: Path, text: str, day: str | None = None) -> dict:
    text = " ".join(str(text or "").split())
    if not text or len(text) > 1000:
        raise ValueError("text は 1〜1000 文字です")
    if day is not None:
        _day(day)
    return _append(base, {"kind": "note", "text": text, "day": day or datetime.date.today().isoformat()})


def add_person_fact(base: Path, name: str, fact: str, evidence: str | None = None) -> dict:
    name, fact = " ".join(str(name or "").split()), " ".join(str(fact or "").split())
    if not name or len(name) > 40:
        raise ValueError("name は 1〜40 文字です")
    if not fact or len(fact) > 500:
        raise ValueError("fact は 1〜500 文字です")
    row = {"kind": "person_fact", "name": name, "fact": fact}
    if evidence:
        row["evidence"] = " ".join(str(evidence).split())[:300]
    return _append(base, row)


TOOLS = [
    {"name": "get_body",
     "description": "1日の体の記録（睡眠・歩数・心拍・HRV など。母艦の archive/health の文）。",
     "inputSchema": {"type": "object", "required": ["day"], "properties": {"day": {"type": "string", "description": "日（YYYY-MM-DD）"}}}},
    {"name": "search_line",
     "description": "LINE の行を言葉で探す（空白で区切った言葉が全部ある行。新しい日から）。外すにした部屋は出さない。",
     "inputSchema": {"type": "object", "required": ["query"], "properties": {
         "query": {"type": "string"}, "from": {"type": "string"}, "to": {"type": "string"},
         "limit": {"type": "integer", "description": f"出す数（{LINE_LIMIT_MAX} まで。既定 50）"}}}},
    {"name": "list_photos",
     "description": "その日の写真・動画の一覧（時刻と名前だけ。画像は返さない）。",
     "inputSchema": {"type": "object", "required": ["day"], "properties": {"day": {"type": "string"}}}},
    {"name": "day_actuals",
     "description": "予定の実績: その日の予定の行ごとに、その時刻に実際にいた所と、その時間の会話の数。",
     "inputSchema": {"type": "object", "required": ["day"], "properties": {"day": {"type": "string"}}}},
    {"name": "events_since",
     "description": "出来事の流れ（新しい約束・期限・人物の更新・版の出荷など。1 行 1 出来事）。since（ISO 8601）より新しいもの。無ければ 24 時間。",
     "inputSchema": {"type": "object", "properties": {"since": {"type": "string"},
                                                      "limit": {"type": "integer", "description": "出す数（300 まで）"}}}},
    {"name": "add_note",
     "description": "メモを候補として置く（母艦の inbox に 1 行。台帳には書かない。決めるのは本人）。",
     "inputSchema": {"type": "object", "required": ["text"], "properties": {"text": {"type": "string"}, "day": {"type": "string"}}}},
    {"name": "add_person_fact",
     "description": "人物の事実の候補を置く（母艦の inbox に 1 行。人物ノートは直さない・作らない。決めるのは本人）。",
     "inputSchema": {"type": "object", "required": ["name", "fact"], "properties": {
         "name": {"type": "string"}, "fact": {"type": "string"}, "evidence": {"type": "string", "description": "根拠（会話の id など）"}}}},
]
WRITE_TOOLS = ("add_note", "add_person_fact")
