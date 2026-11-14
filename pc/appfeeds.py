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
2026-11-13（施策 9）: 家の PC の夜の読み直し（nightreview.py）の疑いを why "night" で混ぜる。
2026-11-13（施策 14）: 自分の声の候補・話し手の疑いの各行の省ける "sure"（true のときだけ）・"sure_why"（60 字まで）を通す
（母艦が「本人が見ればほぼ必ず OK する」と印を付けたもの。アプリは「まとめて OK」にする。押すまでは何も変えない）。
2026-11-13 の施策（番号は D:\\Lifelog\\docs\\system-proposal-2026-11-13.md。母艦の scripts が state を作る）:
- GET /weekly（"weekly"）← state/weekly_for_app.json  週のふり返り（2）と見立ての台帳（3）と、出したものの使われ方の数（1）。
- GET /prep（"prep"）← state/prep_for_app.json  これから 36 時間の予定の「会う前の一枚」（4）。
- GET /brief-compare（"briefcmp"）← state/brief_compare_for_app.json  同じ日の朝のまとめ 2 つ（Codex と Claude。5）。
- GET /accuracy（"accuracy"）← state/accuracy_for_app.json  精度の通信簿（週ごと。12）。値の無い所は null。
- GET /unused（"unused"）← state/unused_features_for_app.json  あまり開かれていない画面（月 1 回。21）。
- POST /feedback（"feedback"）{"kind", "id", "value", "day"} → 母艦の inbox/app_feedback.jsonl に
  {"kind", "id", "value", "day", "at"} を1行（1。kind と value の組は FEEDBACK に決めたものだけ）。
- POST /mood（"mood"）{"day", "at", "mood", "energy", "grip", "note"?} → inbox/mood.jsonl（夜の 10 秒。6。1〜5 の整数）。
- POST /app-usage（"appusage"）{"at", "app", "event"} → inbox/app_usage.jsonl（ショートカットのオートメーションから。8）。
  iPhone の「スクリーンタイム」と Safari の履歴は、ほかのアプリからは読めない（Apple の決まり）ので、この口にした。
2026-11-15: 提案の kind "wish"（49）・POST /feedback の kind "check"（41）・通信簿の週の省ける "check_right"（41）。
  GET /rollout・/checks・/costs は settle.py。
どれも読むだけ（POST は1行足すだけ）。型・長さ・形を確かめ、おかしな行は落とす。無い・読めないときは {"available": false, "reason": …}。
中身（文・ファイル名・アプリの名前・気分の値）は記録（log.txt）に書かない。
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
WEEKLY = Path("state") / "weekly_for_app.json"
PREP = Path("state") / "prep_for_app.json"
BRIEF_COMPARE = Path("state") / "brief_compare_for_app.json"
ACCURACY = Path("state") / "accuracy_for_app.json"
UNUSED = Path("state") / "unused_features_for_app.json"
FEEDBACK_FILE = Path("inbox") / "app_feedback.jsonl"
MOOD_FILE = Path("inbox") / "mood.jsonl"
APP_USAGE_FILE = Path("inbox") / "app_usage.jsonl"
ROUTES = {"/self-candidates": ("selfcand", SELF_CANDIDATES), "/freshness": ("fresh", FRESHNESS),
          "/plaud-gap": ("plaudgap", PLAUD_GAP), "/proposals": ("proposals", PROPOSALS),
          "/plaud-fill": ("plaudfill", PLAUD_FILL), "/speaker-doubts": ("spkdoubt", SPEAKER_DOUBTS),
          "/weekly": ("weekly", WEEKLY), "/prep": ("prep", PREP), "/brief-compare": ("briefcmp", BRIEF_COMPARE),
          "/accuracy": ("accuracy", ACCURACY), "/unused": ("unused", UNUSED)}
# 2026-11-13 の施策で足した名前（/hello の features。lifelog_pc.features() が足す）
FEATURES = ("weekly", "prep", "briefcmp", "accuracy", "unused", "feedback", "mood", "appusage")

PROPOSAL_LIMIT = 60
# "profile"（2026-11-14。強化案 32）: 本人の台帳（profile.md・people-index.md）に入れる候補。action は none だけ
# （受けても答えを返すだけで、台帳に足すのは母艦）
# "wish"（2026-11-15。強化案 49）: 欲しい物リストから・会話の「欲しい」から（受けたら WISHLIST.md に足すのは母艦）
PROPOSAL_KINDS = ("followup", "research", "selffix", "pattern", "review", "chance", "health", "prep", "vocab", "profile",
                  "wish")
EVIDENCE_LIMIT = 10
EVIDENCE_SOURCES = ("conversation", "line", "calendar", "plaud", "stats", "task", "web")
ACTION_TYPES = ("task", "vocab", "none")
ANSWERS = ("accept", "later", "never")
FILL_DAYS = 14
FILL_RANGES = 60
FILL_LINES = 200
DOUBT_LIMIT = 200
DOUBT_SUGGEST = ("self", "other")
DOUBT_WHY = ("plaud-turn", "text", "night")
SURE_WHY = 60
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


def sure(x: dict) -> dict:
    """施策 14 の省ける印。sure が true のときだけ {"sure": True, "sure_why": …}（無い・true でなければ {}）"""
    if not isinstance(x, dict) or x.get("sure") is not True:
        return {}
    return {"sure": True, "sure_why": _text(x.get("sure_why"), SURE_WHY)}


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
                      "text": _text(x.get("text"), 60), "score": score, "why": x["why"], **sure(x)})
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
        evidence = _evidence(x.get("evidence"))
        if x["kind"] == "profile" and (action["type"] != "none" or not evidence):
            continue  # 台帳の候補は、根拠つきで、受けても何も変えないものだけ（2026-11-14）
        seen.add(item_id)
        items.append({"id": item_id, "kind": x["kind"], "title": title, "body": body,
                      "evidence": evidence, "action": action,
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


def _night_doubts() -> list:
    """家の PC の夜の読み直しの話し手の疑い（施策 9。読めなければ空）"""
    try:
        import claude
        import nightreview

        return nightreview.doubt_items(claude.home())
    except Exception:  # noqa: BLE001 — 夜の読み直しが読めなくても、母艦の疑いは返す
        return []


def read_speaker_doubts(base: Path) -> dict:
    data, failure = _load(base, SPEAKER_DOUBTS, "話し手の疑い")
    night = _night_doubts()
    if (failure or data is None or not isinstance(data.get("items"), list)) and not night:
        return failure or {"available": False, "reason": "母艦の話し手の疑いの形が違います"}
    listed = data.get("items") if isinstance(data, dict) and isinstance(data.get("items"), list) else []
    items = []
    for x in listed[:DOUBT_LIMIT * 2] + night[:DOUBT_LIMIT]:
        if not isinstance(x, dict):
            continue
        start, when, score = _iso(x.get("conversation_start")), _iso(x.get("line_time")), _num(x.get("score"), 0, 1)
        current = _text(x.get("current"), 20)
        if (not DAY.fullmatch(str(x.get("day") or "")) or start is None or when is None or score is None
                or not current or x.get("suggest") not in DOUBT_SUGGEST or x.get("why") not in DOUBT_WHY):
            continue
        items.append({"day": x["day"], "conversation_start": start, "line_time": when,
                      "text_head": _text(x.get("text_head"), 40), "current": current, "suggest": x["suggest"],
                      "why": x["why"], "score": score, **sure(x)})
    generated = _text(data.get("generated_at"), 40) if isinstance(data, dict) else ""
    # 母艦の疑いを先に（上限は母艦の分で埋まらないよう、夜の読み直しの分を少し残す）
    mother = [i for i in items if i["why"] != "night"]
    night_items = [i for i in items if i["why"] == "night"]
    keep = mother[:DOUBT_LIMIT - min(len(night_items), DOUBT_LIMIT // 4)]
    return {"available": True, "generated_at": generated, "items": (keep + night_items)[:DOUBT_LIMIT]}


# MARK: - 2026-11-13 の施策（週のふり返り・会う前の一枚・朝のまとめの比べ・精度の通信簿・開かれていない画面）

WEEK = re.compile(r"\d{4}-W\d{2}")
MONTH = re.compile(r"\d{4}-\d{2}")
WEEKLY_KINDS = ("theme", "stuck", "change")
HYPOTHESIS_STATUS = ("alive", "weakened", "confirmed", "unknown")
WEEKLY_ITEMS = 5
WEEKLY_EVIDENCE = 5
HYPOTHESES = 30
PREP_ITEMS = 10
PREP_LIST = 5
COMPARE_DAYS = 7
COMPARE_CHARS = 20000
ACCURACY_WEEKS = 12
UNUSED_ITEMS = 40


def _day(value) -> str | None:
    """"YYYY-MM-DD" で、本当にある日か"""
    if not isinstance(value, str) or not DAY.fullmatch(value):
        return None
    try:
        datetime.date.fromisoformat(value)
    except ValueError:
        return None
    return value


def _when(value) -> str | None:
    """ISO 8601 の日時で、本当にある日時か（時差が無ければ、この PC の時刻とみなす）"""
    text = _iso(value)
    return text if text is not None and _moment(text) is not None else None


def _id(value) -> str | None:
    return value if isinstance(value, str) and ID.fullmatch(value) else None


def _strings(value, n: int, limit: int) -> list[str]:
    """文の並び（文でないもの・空のものは落とし、n 文字まで・limit 個まで）"""
    out = []
    for x in value if isinstance(value, list) else []:
        if not isinstance(x, str):
            continue
        text = _text(x, n)
        if text:
            out.append(text)
        if len(out) >= limit:
            break
    return out


def _long(value, n: int) -> str:
    """改行を残す長い文（朝のまとめ）。前後の空白を除き、n 文字まで"""
    if not isinstance(value, str):
        return ""
    return value.replace("\r\n", "\n").strip()[:n]


def _int(value, low: int, high: int) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    return value if low <= value <= high else None


def _version(data: dict) -> int:
    return data["version"] if _int(data.get("version"), 1, 1000) is not None else 1


def read_weekly(base: Path) -> dict:
    data, failure = _load(base, WEEKLY, "週のふり返り")
    if failure or data is None or not isinstance(data.get("items"), list):
        return failure or {"available": False, "reason": "母艦の週のふり返りの形が違います"}
    items, seen = [], set()
    for x in data["items"][:WEEKLY_ITEMS * 4]:
        if not isinstance(x, dict):
            continue
        item_id, title = _id(x.get("id")), _text(x.get("title"), 40)
        if item_id is None or item_id in seen or x.get("kind") not in WEEKLY_KINDS or not title:
            continue
        evidence = []
        for e in (x.get("evidence") if isinstance(x.get("evidence"), list) else [])[:WEEKLY_EVIDENCE * 4]:
            if not isinstance(e, dict):
                continue
            day, quote = _day(e.get("day")), _text(e.get("quote"), 80)
            if day is None or not quote:
                continue
            evidence.append({"day": day, "source": _text(e.get("source"), 20), "quote": quote})
            if len(evidence) >= WEEKLY_EVIDENCE:
                break
        seen.add(item_id)
        items.append({"id": item_id, "kind": x["kind"], "title": title, "body": _text(x.get("body"), 300),
                      "evidence": evidence})
        if len(items) >= WEEKLY_ITEMS:
            break
    hypotheses, seen = [], set()
    for h in (data.get("hypotheses") if isinstance(data.get("hypotheses"), list) else [])[:HYPOTHESES * 4]:
        if not isinstance(h, dict):
            continue
        h_id, text = _id(h.get("id")), _text(h.get("text"), 120)
        if h_id is None or h_id in seen or not text or h.get("status") not in HYPOTHESIS_STATUS:
            continue
        seen.add(h_id)
        hypotheses.append({"id": h_id, "text": text, "said_on": _day(h.get("said_on")), "status": h["status"],
                           "note": _text(h.get("note"), 200), "checked_on": _day(h.get("checked_on"))})
        if len(hypotheses) >= HYPOTHESES:
            break
    feedback = None
    raw = data.get("feedback")
    if isinstance(raw, dict):
        def counts(value, names) -> dict:
            value = value if isinstance(value, dict) else {}
            return {n: _count(value.get(n)) or 0 for n in names}
        feedback = {"today_three": counts(raw.get("today_three"), ("done", "skipped", "unknown")),
                    "proposal": counts(raw.get("proposal"), ("accept", "later", "never")),
                    "brief_read": _count(raw.get("brief_read")) or 0}
    return {"available": True, "version": _version(data), "generated_at": _iso(data.get("generated_at")),
            "week": data["week"] if isinstance(data.get("week"), str) and WEEK.fullmatch(data["week"]) else None,
            "from": _day(data.get("from")), "to": _day(data.get("to")),
            "items": items, "hypotheses": hypotheses, "feedback": feedback}


def read_prep(base: Path) -> dict:
    data, failure = _load(base, PREP, "会う前の一枚")
    if failure or data is None or not isinstance(data.get("items"), list):
        return failure or {"available": False, "reason": "母艦の会う前の一枚の形が違います"}
    items, seen = [], set()
    for x in data["items"][:PREP_ITEMS * 4]:
        if not isinstance(x, dict):
            continue
        item_id, start, title = _id(x.get("id")), _when(x.get("start")), _text(x.get("title"), 60)
        end = x.get("end")
        if item_id is None or item_id in seen or start is None or not title or (end is not None and _when(end) is None):
            continue
        if end is not None and _moment(end) < _moment(start):
            continue  # 終わりが始まりより前
        last = x.get("last_talk")
        last_talk = None
        if isinstance(last, dict) and _day(last.get("day")) and _text(last.get("summary"), 200):
            last_talk = {"day": last["day"], "summary": _text(last.get("summary"), 200)}
        seen.add(item_id)
        items.append({"id": item_id, "start": start, "end": _when(end), "title": title,
                      "people": _strings(x.get("people"), 20, PREP_LIST), "last_talk": last_talk,
                      "promises": _strings(x.get("promises"), 80, PREP_LIST),
                      "recent": _strings(x.get("recent"), 80, PREP_LIST)})
    items.sort(key=lambda i: _moment(i["start"]))
    return {"available": True, "version": _version(data), "generated_at": _iso(data.get("generated_at")),
            "items": items[:PREP_ITEMS]}


def read_brief_compare(base: Path) -> dict:
    data, failure = _load(base, BRIEF_COMPARE, "朝のまとめの比べ")
    if failure or data is None or not isinstance(data.get("days"), list):
        return failure or {"available": False, "reason": "母艦の朝のまとめの比べの形が違います"}
    days, seen = [], set()
    for x in data["days"][:COMPARE_DAYS * 4]:
        if not isinstance(x, dict):
            continue
        day, codex, by_claude = _day(x.get("day")), _long(x.get("codex"), COMPARE_CHARS), _long(x.get("claude"), COMPARE_CHARS)
        if day is None or day in seen or not codex or not by_claude:
            continue  # 2 つそろっていなければ比べられない
        seen.add(day)
        days.append({"day": day, "codex": codex, "claude": by_claude})
    days.sort(key=lambda d: d["day"], reverse=True)
    return {"available": True, "version": _version(data), "generated_at": _iso(data.get("generated_at")),
            "days": days[:COMPARE_DAYS]}


def read_accuracy(base: Path) -> dict:
    data, failure = _load(base, ACCURACY, "精度の通信簿")
    if failure or data is None or not isinstance(data.get("weeks"), list):
        return failure or {"available": False, "reason": "母艦の精度の通信簿の形が違います"}
    weeks, seen = [], set()
    for x in data["weeks"][:ACCURACY_WEEKS * 4]:
        if not isinstance(x, dict) or not isinstance(x.get("week"), str) or not WEEK.fullmatch(x["week"]) \
                or x["week"] in seen:
            continue
        seen.add(x["week"])
        weeks.append({"week": x["week"], "from": _day(x.get("from")), "to": _day(x.get("to")),
                      "caught_self": _num(x.get("caught_self"), 0, 1), "caught_other": _num(x.get("caught_other"), 0, 1),
                      "person_n_kinds_median": _int(x.get("person_n_kinds_median"), 0, 100000),
                      "fix_kept_ratio": _num(x.get("fix_kept_ratio"), 0, 1), "judge_agree": _num(x.get("judge_agree"), 0, 1),
                      "night_review_kept": _num(x.get("night_review_kept"), 0, 1),
                      "speaking_score": _num(x.get("speaking_score"), 0, 100),
                      # 正しさの抜き取りで「合ってる」だった割合（2026-11-15。強化案 41。省ける）
                      "check_right": _num(x.get("check_right"), 0, 1)})
    weeks.sort(key=lambda w: w["week"], reverse=True)
    return {"available": True, "version": _version(data), "generated_at": _iso(data.get("generated_at")),
            "weeks": weeks[:ACCURACY_WEEKS]}


def read_unused(base: Path) -> dict:
    data, failure = _load(base, UNUSED, "開かれていない画面")
    if failure or data is None or not isinstance(data.get("items"), list):
        return failure or {"available": False, "reason": "母艦の開かれていない画面の形が違います"}
    items, seen = [], set()
    for x in data["items"][:UNUSED_ITEMS * 4]:
        if not isinstance(x, dict):
            continue
        screen, opens, days = _text(x.get("screen"), 40), _count(x.get("opens")), _count(x.get("days"))
        if not screen or screen in seen or opens is None or days is None:
            continue
        seen.add(screen)
        items.append({"screen": screen, "opens": opens, "days": days, "note": _text(x.get("note"), 80)})
        if len(items) >= UNUSED_ITEMS:
            break
    month = data.get("month")
    return {"available": True, "version": _version(data), "generated_at": _iso(data.get("generated_at")),
            "month": month if isinstance(month, str) and MONTH.fullmatch(month) else None, "items": items}


# MARK: - アプリから母艦へ（1行足すだけ。proposals/answer と同じ鍵・同じ大きさの決まり）

# kind → 受ける value
FEEDBACK = {"today_three": ("done", "skipped"), "brief": ("read",), "weekly": ("useful", "not_useful"),
            "prep": ("useful", "not_useful"), "brief_compare": ("codex", "claude"), "night_review": ("kept", "dropped"),
            "same_person": ("merged", "different"), "promise": ("added", "ignored"), "bulk": ("ok",),
            # 正しさの抜き取りの答え（2026-11-15。強化案 41。GET /checks の id）
            "check": ("right", "wrong", "unsure")}
APP_EVENTS = ("open", "close", "focus_on", "focus_off")
_inbox_lock = threading.Lock()


def _json_body(data: bytes) -> dict:
    try:
        body = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise ValueError("中身が JSON ではありません") from None
    if not isinstance(body, dict):
        raise ValueError("中身が JSON ではありません")
    return body


def parse_feedback(data: bytes) -> dict:
    """POST /feedback の中身。おかしければ ValueError"""
    body = _json_body(data)
    kind = body.get("kind")
    if not isinstance(kind, str) or kind not in FEEDBACK:
        raise ValueError("kind は " + "・".join(FEEDBACK) + " のどれかです")
    if body.get("value") not in FEEDBACK[kind]:
        raise ValueError(f"{kind} の value は " + "・".join(FEEDBACK[kind]) + " のどれかです")
    if _id(body.get("id")) is None:
        raise ValueError("id は英数字と _ . : - で 64 文字までです")
    if _day(body.get("day")) is None:
        raise ValueError("day は YYYY-MM-DD です")
    return {"kind": kind, "id": body["id"], "value": body["value"], "day": body["day"]}


def _score(value, name: str) -> int:
    if _int(value, 1, 5) is None:
        raise ValueError(f"{name} は 1〜5 の整数です")
    return value


def parse_mood(data: bytes) -> dict:
    """POST /mood の中身（夜の 10 秒）。おかしければ ValueError"""
    body = _json_body(data)
    if _day(body.get("day")) is None:
        raise ValueError("day は YYYY-MM-DD です")
    if _when(body.get("at")) is None:
        raise ValueError("at は ISO 8601 の日時です")
    row = {"day": body["day"], "at": body["at"], "mood": _score(body.get("mood"), "mood"),
           "energy": _score(body.get("energy"), "energy"), "grip": _score(body.get("grip"), "grip")}
    note = body.get("note")
    if note is not None:
        if not isinstance(note, str) or len(note) > 200:
            raise ValueError("note は 200 文字までの文です")
        if _text(note, 200):
            row["note"] = _text(note, 200)
    return row


def parse_app_usage(data: bytes) -> dict:
    """POST /app-usage の中身（ショートカットのオートメーションから）。おかしければ ValueError"""
    body = _json_body(data)
    if _when(body.get("at")) is None:
        raise ValueError("at は ISO 8601 の日時です")
    app = body.get("app")
    if not isinstance(app, str) or not _text(app, 40) or len(app.strip()) > 40:
        raise ValueError("app は 1〜40 文字の文です")
    if body.get("event") not in APP_EVENTS:
        raise ValueError("event は " + "・".join(APP_EVENTS) + " のどれかです")
    return {"at": body["at"], "app": _text(app, 40), "event": body["event"]}


def append_inbox(base: Path, rel: Path, row: dict) -> dict:
    """母艦の inbox の jsonl に1行足す（同じ PC の中の書き込みは1つずつ）"""
    path = base / rel
    with _inbox_lock:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8", newline="\n") as f:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
    return row


def _http_inbox(handler, base: Path, data: bytes, log, parse, rel: Path, label: str, add_at: bool, detail) -> None:
    try:
        row = parse(data)
    except ValueError as error:
        handler.send_json(400, {"error": str(error)})
        return
    if add_at:
        row["at"] = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
    try:
        append_inbox(base, rel, row)
    except OSError as error:
        log(f"{label}を母艦に置けませんでした: {type(error).__name__}")
        handler.send_json(503, {"error": "母艦に置けませんでした"})
        return
    # 中身（id・アプリの名前・気分の値・覚え書き）は書かない
    log(f"{handler.client_address[0]} から{label}を母艦へ" + (f": {detail(row)}" if detail else ""))
    handler.send_json(200, {"ok": True})


def http_post_feedback(handler, base: Path, data: bytes, log) -> None:
    _http_inbox(handler, base, data, log, parse_feedback, FEEDBACK_FILE, "使われ方の記録", True,
                lambda r: f"{r['kind']} {r['value']}")


def http_post_mood(handler, base: Path, data: bytes, log) -> None:
    _http_inbox(handler, base, data, log, parse_mood, MOOD_FILE, "夜の 10 秒", False, None)


def http_post_app_usage(handler, base: Path, data: bytes, log) -> None:
    _http_inbox(handler, base, data, log, parse_app_usage, APP_USAGE_FILE, "アプリを開いた記録", False,
                lambda r: r["event"])


READERS = {"/self-candidates": read_self_candidates, "/freshness": read_freshness, "/plaud-gap": read_plaud_gap,
           "/proposals": read_proposals, "/plaud-fill": read_plaud_fill, "/speaker-doubts": read_speaker_doubts,
           "/weekly": read_weekly, "/prep": read_prep, "/brief-compare": read_brief_compare,
           "/accuracy": read_accuracy, "/unused": read_unused}
POSTS = {"/proposals/answer": http_post_answer, "/feedback": http_post_feedback, "/mood": http_post_mood,
         "/app-usage": http_post_app_usage}
