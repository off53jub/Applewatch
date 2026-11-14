"""LifeLog PC: 1日の正本を配る（強化案 57。2026-11-15）。

- GET /canonical?day=YYYY-MM-DD（features の "canonical"）← 母艦の digests/canonical/YYYY-MM-DD.json
  （母艦の scripts/Build-Canonical.py が作る。形の正本は母艦の docs/scripts.md の Build-Canonical.py の節）。
  直近 14 日だけ。無い・読めない・形が違うときは {"available": false, "reason"}。行の型・長さ・値を確かめ、おかしな行は落とす。
  返す形: {"available": true, "version", "day", "generated_at", "counts": {...}, "recordings": [...], "lines": [...]}
  （行は {"time": "HH:MM:SS", "source": "plaud"|"app", "clock", "speaker", "speaker_id", "speaker_how", "plaud_speaker", "text"}）
- 中身（文・名前）は記録（log.txt）に書かない。
"""

from __future__ import annotations

import datetime
import json
import re
from pathlib import Path
from urllib.parse import parse_qs, urlparse

FOLDER = Path("digests") / "canonical"
GETS = ("/canonical",)
DAYS = 14
LINES_MAX = 12000
TEXT_MAX = 600
SPEAKER_MAX = 20
RECORDINGS_MAX = 60
SOURCES = ("plaud", "app")
CLOCKS = ("app", "aligned", "start_time")
HOWS = ("app", "line", "turn", "mixed")
COUNT_KEYS = ("lines", "plaud", "app", "with_speaker", "named_or_self", "plaud_with_speaker", "plaud_turn",
              "app_in_plaud_dropped", "plaud_unplaced")
DAY = re.compile(r"\d{4}-\d{2}-\d{2}")
CLOCK = re.compile(r"([01]\d|2[0-3]):[0-5]\d:[0-5]\d")


def features() -> list[str]:
    return ["canonical"]


def _day(value) -> str | None:
    if not isinstance(value, str) or not DAY.fullmatch(value):
        return None
    try:
        datetime.date.fromisoformat(value)
    except ValueError:
        return None
    return value


def _str(value, n: int) -> str | None:
    if not isinstance(value, str):
        return None
    text = " ".join(value.split())
    return text[:n] if text else None


def _count(value) -> int | None:
    return value if isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= 10_000_000 else None


def clean_line(x) -> dict | None:
    if not isinstance(x, dict) or not isinstance(x.get("time"), str) or not CLOCK.fullmatch(x["time"]):
        return None
    source, clock, text = x.get("source"), x.get("clock"), _str(x.get("text"), TEXT_MAX)
    if source not in SOURCES or clock not in CLOCKS or not text:
        return None
    if source == "app" and clock != "app":
        return None
    speaker = _str(x.get("speaker"), SPEAKER_MAX)
    how = x.get("speaker_how") if x.get("speaker_how") in HOWS else None
    if speaker is None and how != "mixed":
        how = None
    if speaker is not None and how in (None, "mixed"):
        how = "app" if source == "app" else "line"
    ident = x.get("speaker_id") if isinstance(x.get("speaker_id"), str) and len(x["speaker_id"]) <= 40 else None
    return {"time": x["time"], "source": source, "clock": clock, "speaker": speaker,
            "speaker_id": ident if speaker is not None else None, "speaker_how": how,
            "plaud_speaker": _str(x.get("plaud_speaker"), SPEAKER_MAX), "text": text}


def read_canonical(base: Path, day: str | None, today: datetime.date | None = None) -> dict:
    today = today or datetime.datetime.now().astimezone().date()
    if _day(day) is None:
        return {"available": False, "reason": "日付は YYYY-MM-DD です"}
    asked = datetime.date.fromisoformat(day)
    if not today - datetime.timedelta(days=DAYS - 1) <= asked <= today:
        return {"available": False, "reason": f"正本は直近 {DAYS} 日の分だけです"}
    try:
        data = json.loads((Path(base) / FOLDER / f"{day}.json").read_text(encoding="utf-8-sig"))
    except FileNotFoundError:
        return {"available": False, "reason": "母艦のこの日の正本がまだありません"}
    except (OSError, ValueError) as error:
        return {"available": False, "reason": f"母艦の正本を読めませんでした: {type(error).__name__}"}
    if not isinstance(data, dict) or not isinstance(data.get("lines"), list):
        return {"available": False, "reason": "母艦の正本の形が違います"}
    if data.get("day") != day:
        return {"available": False, "reason": "母艦の正本の日付が違います"}
    lines = []
    for x in data["lines"][:LINES_MAX * 2]:
        line = clean_line(x)
        if line is not None:
            lines.append(line)
            if len(lines) >= LINES_MAX:
                break
    lines.sort(key=lambda r: r["time"])  # 同じ時刻は母艦の並びのまま
    counts_raw = data.get("counts") if isinstance(data.get("counts"), dict) else {}
    counts = {k: _count(counts_raw.get(k)) for k in COUNT_KEYS if _count(counts_raw.get(k)) is not None}
    counts["lines"] = len(lines)
    counts["plaud"] = sum(1 for x in lines if x["source"] == "plaud")
    counts["app"] = len(lines) - counts["plaud"]
    counts["with_speaker"] = sum(1 for x in lines if x["speaker"])
    recordings = []
    for r in data.get("recordings") or []:
        if isinstance(r, dict) and isinstance(r.get("from"), str) and CLOCK.fullmatch(r["from"]) \
                and isinstance(r.get("to"), str) and CLOCK.fullmatch(r["to"]) and r.get("clock") in CLOCKS[1:]:
            recordings.append({"from": r["from"], "to": r["to"], "clock": r["clock"]})
            if len(recordings) >= RECORDINGS_MAX:
                break
    version = data.get("version") if isinstance(data.get("version"), int) and not isinstance(data.get("version"), bool) else 1
    generated = data.get("generated_at") if isinstance(data.get("generated_at"), str) else None
    return {"available": True, "version": version, "day": day, "generated_at": generated, "counts": counts,
            "recordings": recordings, "lines": lines}


def http_get(handler, base: Path) -> None:
    query = parse_qs(urlparse(handler.path).query)
    values = query.get("day") or []
    day = values[0] if values else datetime.datetime.now().astimezone().date().isoformat()
    if _day(day) is None:
        handler.send_json(400, {"error": "day は YYYY-MM-DD です"})
        return
    handler.send_json(200, read_canonical(base, day))
