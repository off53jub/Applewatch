"""母艦が作る3つの「アプリ向けの写し」を確かめて返す（2026-11-12）。

- GET /self-candidates（features の "selfcand"）← state/self_candidates_for_app.json
  職場の「自分の声」の候補（PLAUD と突き合わせて見つけた、自分が話していそうな場面）。
- GET /freshness（"fresh"）← state/freshness.json  自動取得が止まっていないかの一覧。
- GET /plaud-gap（"plaudgap"）← state/plaud_gap_for_app.json  アプリの文字起こしと PLAUD の差。
2026-11-13（Claude の API と一緒に足したもの。母艦の scripts が作る）:
- GET /proposals（"proposals"）← state/proposals_for_app.json  母艦からの提案（1日に新しいのは3つまで）。
  期限（expires）の過ぎたものは返さない。
- POST /proposals/answer {"id", "answer": "accept"|"later"|"never"} → 母艦の inbox/proposal_answers.jsonl に
  {"id", "kind", "answer", "at"} を1行足す（kind は今の提案の一覧から。分からなければ ""）。
- GET /plaud-fill（"plaudfill"）← state/plaud_fill_for_app.json  アプリに行の無い時間の PLAUD の文（見せるだけ）。
- GET /speaker-doubts（"spkdoubt"）← state/speaker_doubts_for_app.json  話し手が違うかもしれない行（疑いだけ。
  名前は自動で替えない）。
どれも読むだけ。型・長さ・形を確かめ、おかしな行は落とす。無い・読めないときは {"available": false, "reason": …}。
中身（文・ファイル名）は記録（log.txt）に書かない。
"""

from __future__ import annotations

import datetime
import json
import re
import threading
import time
from pathlib import Path

SELF_CANDIDATES = Path("state") / "self_candidates_for_app.json"
FRESHNESS = Path("state") / "freshness.json"
PLAUD_GAP = Path("state") / "plaud_gap_for_app.json"
PROPOSALS = Path("state") / "proposals_for_app.json"
PLAUD_FILL = Path("state") / "plaud_fill_for_app.json"
SPEAKER_DOUBTS = Path("state") / "speaker_doubts_for_app.json"
PROPOSAL_ANSWERS = Path("inbox") / "proposal_answers.jsonl"
ROUTES = {"/self-candidates": ("selfcand", SELF_CANDIDATES), "/freshness": ("fresh", FRESHNESS),
          "/plaud-gap": ("plaudgap", PLAUD_GAP), "/proposals": ("proposals", PROPOSALS),
          "/plaud-fill": ("plaudfill", PLAUD_FILL), "/speaker-doubts": ("spkdoubt", SPEAKER_DOUBTS)}

PROPOSAL_LIMIT = 60
PROPOSAL_KINDS = ("followup", "research", "selffix", "pattern", "review", "chance", "health", "prep", "vocab")
EVIDENCE_LIMIT = 10
EVIDENCE_SOURCES = ("conversation", "line", "calendar", "plaud", "stats", "task", "web")
ACTION_TYPES = ("task", "vocab", "none")
ANSWERS = ("accept", "later", "never")
FILL_DAYS = 14
FILL_RANGES = 60
FILL_LINES = 200
DOUBT_LIMIT = 200
DOUBT_SUGGEST = ("self", "other")
DOUBT_WHY = ("plaud-turn", "text")
_answers_lock = threading.Lock()

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


def _moment(text: str | None) -> datetime.datetime | None:
    """ISO の日時を比べられる形に（時差が無いものは、この PC の時刻とみなす）"""
    if not text:
        return None
    try:
        when = datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    return when if when.tzinfo is not None else when.astimezone()


# MARK: - 母艦からの提案（2026-11-13）


def _evidence(value) -> list[dict]:
    out = []
    for e in (value if isinstance(value, list) else [])[:EVIDENCE_LIMIT * 2]:
        if not isinstance(e, dict) or e.get("source") not in EVIDENCE_SOURCES:
            continue
        text = _text(e.get("text"), 120)
        when = e.get("when")
        if not text or (when is not None and _iso(when) is None):
            continue
        out.append({"text": text, "when": _iso(when), "source": e["source"]})
    return out[:EVIDENCE_LIMIT]


def _action(value) -> dict | None:
    if not isinstance(value, dict) or value.get("type") not in ACTION_TYPES:
        return None
    kind = value["type"]
    text = _text(value.get("text"), 80)
    if kind != "none" and not text:
        return None
    reading = value.get("reading")
    if reading is not None and not isinstance(reading, str):
        return None
    return {"type": kind, "text": text, "reading": (_text(reading, 40) or None) if kind == "vocab" else None}


def read_proposals(base: Path, now: datetime.datetime | None = None) -> dict:
    data, failure = _load(base, PROPOSALS, "提案")
    if failure or data is None or not isinstance(data.get("items"), list):
        return failure or {"available": False, "reason": "母艦の提案の形が違います"}
    now = now or datetime.datetime.now().astimezone()
    items, seen = [], set()
    for x in data["items"]:
        if not isinstance(x, dict):
            continue
        item_id = str(x.get("id") or "") if isinstance(x.get("id"), str) else ""
        title, body = _text(x.get("title"), 60), _text(x.get("body"), 400)
        created, expires, action = _iso(x.get("created")), x.get("expires"), _action(x.get("action"))
        if (not ID.fullmatch(item_id) or item_id in seen or x.get("kind") not in PROPOSAL_KINDS or not title
                or created is None or action is None or (expires is not None and _iso(expires) is None)):
            continue
        ends = _moment(_iso(expires))
        if ends is not None and ends < now:
            continue  # 期限が過ぎたものは出さない
        seen.add(item_id)
        items.append({"id": item_id, "kind": x["kind"], "title": title, "body": body,
                      "evidence": _evidence(x.get("evidence")), "action": action,
                      "created": created, "expires": _iso(expires)})
    return {"available": True, "generated_at": _text(data.get("generated_at"), 40), "items": items[:PROPOSAL_LIMIT]}


def parse_answer(data: bytes) -> dict:
    """POST /proposals/answer の中身。おかしければ ValueError"""
    try:
        body = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise ValueError("中身が JSON ではありません") from None
    if not isinstance(body, dict):
        raise ValueError("中身が JSON ではありません")
    item_id = body.get("id")
    if not isinstance(item_id, str) or not ID.fullmatch(item_id):
        raise ValueError("id は英数字と _ . : - で 64 文字までです")
    if body.get("answer") not in ANSWERS:
        raise ValueError("answer は accept・later・never のどれかです")
    return {"id": item_id, "answer": body["answer"]}


def append_answer(base: Path, answer: dict, now: float | None = None) -> dict:
    """母艦の inbox/proposal_answers.jsonl に1行足す。足した行を返す"""
    found = read_proposals(base)
    kinds = {i["id"]: i["kind"] for i in found.get("items") or []}
    if answer["id"] not in kinds:
        # 期限が過ぎて一覧から外れたものでも、元のファイルにあれば kind を引く
        raw, _ = _load(base, PROPOSALS, "提案")
        listed = (raw or {}).get("items")
        for x in listed if isinstance(listed, list) else []:
            if isinstance(x, dict) and x.get("id") == answer["id"] and x.get("kind") in PROPOSAL_KINDS:
                kinds[answer["id"]] = x["kind"]
                break
    moment = datetime.datetime.fromtimestamp(time.time() if now is None else now).astimezone()
    row = {"id": answer["id"], "kind": kinds.get(answer["id"], ""), "answer": answer["answer"],
           "at": moment.isoformat(timespec="seconds")}
    path = base / PROPOSAL_ANSWERS
    with _answers_lock:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8", newline="\n") as f:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
    return row


def http_post_answer(handler, base: Path, data: bytes, log) -> None:
    try:
        answer = parse_answer(data)
    except ValueError as error:
        handler.send_json(400, {"error": str(error)})
        return
    try:
        row = append_answer(base, answer)
    except OSError as error:
        log(f"提案への答えを母艦に置けませんでした: {type(error).__name__}")
        handler.send_json(503, {"error": "母艦に置けませんでした"})
        return
    # 提案の文は書かない（答えの種類と提案の種類だけ）
    log(f"{handler.client_address[0]} から提案への答えを母艦へ: {row['answer']}（{row['kind'] or '種類不明'}）")
    handler.send_json(200, {"ok": True})


# MARK: - アプリに行の無い時間の PLAUD の文（2026-11-13。見せるだけ）


def read_plaud_fill(base: Path) -> dict:
    data, failure = _load(base, PLAUD_FILL, "PLAUD の文の補い")
    if failure or data is None or not isinstance(data.get("days"), list):
        return failure or {"available": False, "reason": "母艦の PLAUD の文の補いの形が違います"}
    days = []
    for x in data["days"][:FILL_DAYS * 2]:
        if not isinstance(x, dict) or not DAY.fullmatch(str(x.get("day") or "")) or not isinstance(x.get("ranges"), list):
            continue
        ranges = []
        for r in x["ranges"][:FILL_RANGES * 2]:
            if not isinstance(r, dict) or not isinstance(r.get("lines"), list):
                continue
            start, end = _iso(r.get("start")), _iso(r.get("end"))
            a, b = _moment(start), _moment(end)
            if a is None or b is None or b <= a:
                continue
            lines = []
            for line in r["lines"][:FILL_LINES * 2]:
                if not isinstance(line, dict):
                    continue
                when, text, speaker = _iso(line.get("time")), _text(line.get("text"), 400), line.get("speaker")
                if when is None or not text or (speaker is not None and not isinstance(speaker, str)):
                    continue
                lines.append({"time": when, "speaker": (_text(speaker, 20) or None) if speaker is not None else None,
                              "text": text})
            if lines:
                ranges.append({"start": start, "end": end, "lines": lines[:FILL_LINES]})
        if ranges:
            days.append({"day": x["day"], "ranges": ranges[:FILL_RANGES]})
    return {"available": True, "generated_at": _text(data.get("generated_at"), 40), "days": days[:FILL_DAYS]}


# MARK: - 話し手が違うかもしれない行（2026-11-13。疑いだけ。名前は自動で替えない）


def read_speaker_doubts(base: Path) -> dict:
    data, failure = _load(base, SPEAKER_DOUBTS, "話し手の疑い")
    if failure or data is None or not isinstance(data.get("items"), list):
        return failure or {"available": False, "reason": "母艦の話し手の疑いの形が違います"}
    items = []
    for x in data["items"][:DOUBT_LIMIT * 2]:
        if not isinstance(x, dict):
            continue
        start, when, score = _iso(x.get("conversation_start")), _iso(x.get("line_time")), _num(x.get("score"), 0, 1)
        current = _text(x.get("current"), 20)
        if (not DAY.fullmatch(str(x.get("day") or "")) or start is None or when is None or score is None
                or not current or x.get("suggest") not in DOUBT_SUGGEST or x.get("why") not in DOUBT_WHY):
            continue
        items.append({"day": x["day"], "conversation_start": start, "line_time": when,
                      "text_head": _text(x.get("text_head"), 40), "current": current, "suggest": x["suggest"],
                      "why": x["why"], "score": score})
    return {"available": True, "generated_at": _text(data.get("generated_at"), 40), "items": items[:DOUBT_LIMIT]}


READERS = {"/self-candidates": read_self_candidates, "/freshness": read_freshness, "/plaud-gap": read_plaud_gap,
           "/proposals": read_proposals, "/plaud-fill": read_plaud_fill, "/speaker-doubts": read_speaker_doubts}
POSTS = {"/proposals/answer": http_post_answer}
