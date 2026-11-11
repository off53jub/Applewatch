"""母艦が作る3つの「アプリ向けの写し」を確かめて返す（2026-11-12）。

- GET /self-candidates（features の "selfcand"）← state/self_candidates_for_app.json
  職場の「自分の声」の候補（PLAUD と突き合わせて見つけた、自分が話していそうな場面）。
- GET /freshness（"fresh"）← state/freshness.json  自動取得が止まっていないかの一覧。
- GET /plaud-gap（"plaudgap"）← state/plaud_gap_for_app.json  アプリの文字起こしと PLAUD の差。
どれも読むだけ。型・長さ・形を確かめ、おかしな行は落とす。無い・読めないときは {"available": false, "reason": …}。
中身（文・ファイル名）は記録（log.txt）に書かない。
"""

from __future__ import annotations

import json
import re
from pathlib import Path

SELF_CANDIDATES = Path("state") / "self_candidates_for_app.json"
FRESHNESS = Path("state") / "freshness.json"
PLAUD_GAP = Path("state") / "plaud_gap_for_app.json"
ROUTES = {"/self-candidates": ("selfcand", SELF_CANDIDATES), "/freshness": ("fresh", FRESHNESS),
          "/plaud-gap": ("plaudgap", PLAUD_GAP)}

CAND_LIMIT = 100
FRESH_LIMIT = 40
GAP_DAYS = 31
GAP_LIMIT = 20

DAY = re.compile(r"\d{4}-\d{2}-\d{2}")
ID = re.compile(r"[0-9A-Za-z_.:-]{1,64}")
# チャンクの音声のファイル名（フォルダを含まない）
AUDIO = re.compile(r"[0-9A-Za-z_.-]{1,120}")
KEY = re.compile(r"[0-9A-Za-z_.-]{1,40}")
CLOCK = re.compile(r"\d{2}:\d{2}(:\d{2})?")
ISO = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?(\.\d+)?(Z|[+-]\d{2}:?\d{2})?")
WHY = ("plaud-match", "plaud-most-talk")


def _text(value, n: int) -> str:
    return " ".join(str(value or "").split())[:n] if isinstance(value, (str, int)) and not isinstance(value, bool) else ""


def _num(value, low: float, high: float) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value != value:
        return None
    return float(value) if low <= value <= high else None


def _count(value) -> int | None:
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else None


def _iso(value) -> str | None:
    text = str(value or "") if isinstance(value, str) else ""
    return text if ISO.fullmatch(text) else None


def _load(base: Path, rel: Path, label: str) -> tuple[dict | None, dict | None]:
    """(中身, 失敗の返事)。どちらか一方だけが入る"""
    try:
        data = json.loads((base / rel).read_text(encoding="utf-8-sig"))
    except FileNotFoundError:
        return None, {"available": False, "reason": f"母艦の{label}がまだありません"}
    except (OSError, ValueError) as error:
        return None, {"available": False, "reason": f"母艦の{label}を読めませんでした: {type(error).__name__}"}
    if not isinstance(data, dict):
        return None, {"available": False, "reason": f"母艦の{label}の形が違います"}
    return data, None


def read_self_candidates(base: Path) -> dict:
    data, failure = _load(base, SELF_CANDIDATES, "自分の声の候補")
    if failure or data is None or not isinstance(data.get("items"), list):
        return failure or {"available": False, "reason": "母艦の自分の声の候補の形が違います"}
    items, seen = [], set()
    for x in data["items"]:
        if not isinstance(x, dict):
            continue
        item_id, audio = str(x.get("id") or ""), str(x.get("audio") or "")
        start, end, score = _num(x.get("start"), 0, 86400), _num(x.get("end"), 0, 86400), _num(x.get("score"), 0, 1)
        if (not ID.fullmatch(item_id) or item_id in seen or not DAY.fullmatch(str(x.get("day") or ""))
                or not AUDIO.fullmatch(audio) or ".." in audio or start is None or end is None or end <= start
                or score is None or x.get("why") not in WHY):
            continue
        seen.add(item_id)
        items.append({"id": item_id, "day": x["day"], "audio": audio, "start": start, "end": end,
                      "text": _text(x.get("text"), 60), "score": score, "why": x["why"]})
    items.sort(key=lambda i: -i["score"])
    return {"available": True, "generated_at": _text(data.get("generated_at"), 40), "items": items[:CAND_LIMIT]}


def read_freshness(base: Path) -> dict:
    data, failure = _load(base, FRESHNESS, "新しさの一覧")
    if failure or data is None or not isinstance(data.get("items"), list):
        return failure or {"available": False, "reason": "母艦の新しさの一覧の形が違います"}
    items = []
    for x in data["items"]:
        if not isinstance(x, dict) or not KEY.fullmatch(str(x.get("key") or "")):
            continue
        limit = _num(x.get("limit_hours"), 0, 24 * 365)
        if limit is None or not isinstance(x.get("stale"), bool):
            continue
        items.append({"key": x["key"], "label": _text(x.get("label"), 30) or x["key"], "last_ok": _iso(x.get("last_ok")),
                      "limit_hours": limit, "stale": x["stale"], "note": _text(x.get("note"), 80)})
    return {"available": True, "generated_at": _text(data.get("generated_at"), 40), "items": items[:FRESH_LIMIT]}


def read_plaud_gap(base: Path) -> dict:
    data, failure = _load(base, PLAUD_GAP, "PLAUD との差")
    if failure or data is None or not isinstance(data.get("days"), list):
        return failure or {"available": False, "reason": "母艦の PLAUD との差の形が違います"}
    days = []
    for x in data["days"][:GAP_DAYS]:
        if not isinstance(x, dict) or not DAY.fullmatch(str(x.get("day") or "")):
            continue
        gaps = [{"from": g["from"], "to": g["to"]} for g in (x.get("gaps") or [])[:GAP_LIMIT]
                if isinstance(g, dict) and CLOCK.fullmatch(str(g.get("from") or "")) and CLOCK.fullmatch(str(g.get("to") or ""))]
        misheard = [_text(m, 40) for m in (x.get("misheard") or [])[:GAP_LIMIT]] if isinstance(x.get("misheard"), list) else []
        days.append({"day": x["day"], "source": _text(x.get("source"), 20), "app_chars": _count(x.get("app_chars")) or 0,
                     "plaud_chars": _count(x.get("plaud_chars")) or 0, "ratio": _num(x.get("ratio"), 0, 1000),
                     "gaps": gaps, "misheard": [m for m in misheard if m], "score": _num(x.get("score"), 0, 1000)})
    missing = [d for d in (data.get("missing_official") or [])[:62] if isinstance(d, str) and DAY.fullmatch(d)] \
        if isinstance(data.get("missing_official"), list) else []
    return {"available": True, "generated_at": _text(data.get("generated_at"), 40), "days": days, "missing_official": missing}


READERS = {"/self-candidates": read_self_candidates, "/freshness": read_freshness, "/plaud-gap": read_plaud_gap}
