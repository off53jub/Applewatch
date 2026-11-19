"""LifeLog PC: PLAUD と時計（アプリ）の 2 本を比べ、食い違う所だけ疑う（s18 の 73。2026-11-19）。

比べるのは母艦がもうやっている（Build-PlaudGap.py → state/plaud_gap_for_app.json、Build-CaptureLoss.py →
state/misheard_pairs.json）。ここでは新しく比べ直さず、その結果をこの PC の「聞いて直す」の並び（records.review_queue）に
つなぐだけ:
- 疑う（理由 "plaud"）: misheard_pairs.json の組（その日の、アプリの文が PLAUD と合わなかった行）と同じ文の行。
  自信が低くない行でも並びに出す（PLAUD と食い違ったので）。
- 疑わない: 母艦が省ける state/plaud_line_match_for_pc.json {"days": {"YYYY-MM-DD": {"agree": ["行の時刻 ISO", …]}}} を
  出していれば、PLAUD と合った行は「確からしさが低い」「票が食い違う」だけの理由なら並びから外す（2 本が合ったので聞かない）。
  まだ母艦に無い（Build-PlaudGap は行ごとの当たりを外に出していない）。出すかは母艦の担当が決める（docs/_incoming/s18-P.md）。
- GET /plaud-doubts → {"available", "days": {日: [{"line_time", "conversation_start", "match", "plaud"}]}}（features の "plauddoubt"）
読むだけ（母艦のファイルも記録も変えない）。記録（log.txt）には数だけ。
"""

from __future__ import annotations

import json
import re
import threading
import time
import unicodedata
from pathlib import Path

import records
import voicetone

MISHEARD = Path("state") / "misheard_pairs.json"
AGREE = Path("state") / "plaud_line_match_for_pc.json"
CACHE_S = 300.0
PLAIN = re.compile(r"[\s、。，．,.!！?？・「」『』（）()〜~ー\-…]")
QUIET_REASONS = {"low", "votes"}   # PLAUD と合った行で、これだけの理由なら聞かない

_cache: dict = {"at": 0.0, "base": None, "misheard": {}, "agree": {}}
_lock = threading.Lock()


def _plain(text: str) -> str:
    return PLAIN.sub("", unicodedata.normalize("NFKC", text or ""))


def _load(base: Path | None) -> tuple[dict, dict]:
    with _lock:
        if _cache["base"] == base and time.time() - _cache["at"] < CACHE_S:
            return _cache["misheard"], _cache["agree"]
    misheard: dict[str, list[dict]] = {}
    agree: dict[str, set[int]] = {}
    if base is not None:
        try:
            data = json.loads((base / MISHEARD).read_text(encoding="utf-8-sig"))
            for item in data.get("items") or []:
                if isinstance(item, dict) and isinstance(item.get("day"), str) and isinstance(item.get("app"), str):
                    misheard.setdefault(item["day"], []).append(item)
        except (OSError, ValueError, AttributeError):
            pass
        try:
            data = json.loads((base / AGREE).read_text(encoding="utf-8-sig"))
            for day, entry in (data.get("days") or {}).items():
                for t in (entry or {}).get("agree") or []:
                    try:
                        agree.setdefault(day, set()).add(records.parse_time(t, "agree"))
                    except ValueError:
                        continue
        except (OSError, ValueError, AttributeError):
            pass
    with _lock:
        _cache.update({"at": time.time(), "base": base, "misheard": misheard, "agree": agree})
    return misheard, agree


def doubts(base: Path | None, day: str, parsed: dict) -> tuple[dict[int, list[str]], set[int]]:
    """(足す理由 {行の時刻: ["plaud"]}, 聞かない行の時刻)"""
    misheard, agree = _load(base)
    wanted = {_plain(i["app"]) for i in misheard.get(day, []) if _plain(i["app"])}
    add: dict[int, list[str]] = {}
    if wanted:
        for c in parsed.get("conversations", []):
            for line in c["lines"]:
                if _plain(line.get("text") or "") in wanted:
                    add[line["time"]] = ["plaud"]
    return add, set(agree.get(day, set()))


def listing(base: Path | None, store, days: int = 3) -> dict:
    misheard, _ = _load(base)
    out: dict[str, list] = {}
    for day in sorted(misheard)[-days:]:
        parsed = store.day(day) if store is not None else None
        by_text = {}
        for c in (parsed or {}).get("conversations", []):
            for line in c["lines"]:
                by_text.setdefault(_plain(line.get("text") or ""), (line, c))
        rows = []
        for item in misheard[day]:
            hit = by_text.get(_plain(item["app"]))
            rows.append({"line_time": voicetone._iso(hit[0]["time"]) if hit else None,
                         "conversation_start": voicetone._iso(hit[1]["start"]) if hit else None,
                         "match": item.get("match"), "app": item["app"][:200], "plaud": str(item.get("plaud") or "")[:200],
                         "evidence_kinds": ["plaud"], "tier": "ask", "tier_why": "PLAUD と食い違った"})
        out[day] = rows
    return {"available": bool(misheard), "days": out}
