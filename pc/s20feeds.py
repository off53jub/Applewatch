"""s20（2026-11-21）: アプリの新しい画面が読む、母艦の写しの道（担当 D のアプリが features の名前で使う）。0 円・言語モデルなし・読むだけ。

- GET /review-queue（"reviewq"）← 母艦の state/review_queue_for_app.json（確かめ待ちの 1 列。次3・体11〜15）
- GET /feature-check（"featcheck"）← state/audit/feature_check_for_app.json（検品表の通信簿。次1・体26）
- GET /device-checks（"devchecks"）← state/device_checks.json（実機の確かめ。次16）
- GET /interview-sheet（"interview"）← reports/interview-sheet.html（面談の 1 枚。次20。html をそのまま返す。無ければ 404）
- GET /holiday-tags（"holidaytags"）← state/holiday/tags.json（休日の札。{日付: [{tag, …}]}）
- POST /feature-answer（"featcheck"）{"id", "keep": true|false, "at"?} → inbox/feature_answers.jsonl に {"id","keep","at"}
- POST /feedback の kind "review"（{"kind":"review","id","answer","at"}）は appfeeds.parse_feedback が受ける
  （→ inbox/app_feedback.jsonl。母艦の Build-ReviewQueue.py が読む）
無い・読めないときは {"available": false, "reason": …}。中身（問い・答え・文）は記録（log.txt）に書かない。
"""

from __future__ import annotations

import datetime
import json
from pathlib import Path

import appfeeds

REVIEW = Path("state") / "review_queue_for_app.json"
FEATURE_CHECK = Path("state") / "audit" / "feature_check_for_app.json"
DEVICE_CHECKS = Path("state") / "device_checks.json"
HOLIDAY_TAGS = Path("state") / "holiday" / "tags.json"
INTERVIEW = Path("reports") / "interview-sheet.html"
FEATURE_ANSWERS = Path("inbox") / "feature_answers.jsonl"
FEATURES = ("reviewq", "featcheck", "devchecks", "interview", "holidaytags")
REVIEW_LIMIT = 100
HTML_LIMIT = 2 * 1024 * 1024


def _read(base: Path, rel: Path, label: str) -> dict:
    data, failed = appfeeds._load(base, rel, label)
    if failed:
        return failed
    return {"available": True, **{k: v for k, v in data.items() if k != "available"}}


def read_review(base: Path) -> dict:
    out = _read(base, REVIEW, "確かめ待ちの列")
    if out.get("available"):
        items = out.get("items")
        rows = []
        # アプリは 1 行でも形が違うと列ごと読めないので、ここで落とす（kind・answer・evidence の text が文であること）
        for i in items if isinstance(items, list) else []:
            if not isinstance(i, dict) or appfeeds._id(i.get("id")) is None or not isinstance(i.get("question"), str) \
                    or not isinstance(i.get("kind"), str):
                continue
            row = {**i, "answer": i.get("answer") if isinstance(i.get("answer"), str) else "yesno"}
            ev = i.get("evidence")
            row["evidence"] = [e for e in ev if isinstance(e, dict) and isinstance(e.get("text"), str)] if isinstance(ev, list) else []
            ch = i.get("choices")
            if ch is not None and not (isinstance(ch, list) and all(isinstance(c, str) for c in ch)):
                row.pop("choices")
            rows.append(row)
        out["items"] = rows[:REVIEW_LIMIT]
    return out


def read_feature_check(base: Path) -> dict:
    return _read(base, FEATURE_CHECK, "検品表")


RESULT_OK = {"ok": True, "ng": False}


def read_device_checks(base: Path) -> dict:
    """母艦の {"result": ok|ng|unknown, "evidence", "fix"} に、アプリの読む {"ok": true|false|null, "note"} を足す"""
    out = _read(base, DEVICE_CHECKS, "実機の確かめ")
    checks = out.get("checks") if out.get("available") else None
    if isinstance(checks, list):
        rows = []
        for c in checks:
            if not isinstance(c, dict) or not isinstance(c.get("id"), str) or not isinstance(c.get("name"), str):
                continue
            ok = RESULT_OK.get(c.get("result"))
            note = " ".join(str(x) for x in (c.get("evidence"), None if ok else c.get("fix")) if isinstance(x, str) and x)
            rows.append({**c, "ok": ok, "note": note[:300]})
        out["checks"] = rows
    return out


def read_holiday_tags(base: Path) -> dict:
    data, failed = appfeeds._load(base, HOLIDAY_TAGS, "休日の札")
    if failed:
        return failed
    return {k: v for k, v in data.items() if appfeeds.DAY.fullmatch(str(k)) and isinstance(v, list)}


READERS = {"/review-queue": read_review, "/feature-check": read_feature_check, "/device-checks": read_device_checks,
           "/holiday-tags": read_holiday_tags}
HTML_GETS = ("/interview-sheet",)
GETS = (*READERS, *HTML_GETS)


def http_get_html(handler, base: Path) -> None:
    """GET /interview-sheet: 母艦の印刷用 html をそのまま返す（無い・大きすぎるときは 404）"""
    try:
        data = (base / INTERVIEW).read_bytes()
    except OSError:
        data = b""
    if not data or len(data) > HTML_LIMIT:
        handler.send_json(404, {"available": False, "reason": "母艦の面談の 1 枚がまだありません"})
        return
    handler.send_response(200)
    handler.send_header("Content-Type", "text/html; charset=utf-8")
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)


def parse_feature_answer(data: bytes) -> dict:
    body = appfeeds._json_body(data)
    if appfeeds._id(body.get("id")) is None:
        raise ValueError("id は英数字と _ . : - で 64 文字までです")
    if not isinstance(body.get("keep"), bool):
        raise ValueError("keep は true か false です")
    at = body.get("at")
    if at is not None and appfeeds._iso(at) is None:
        raise ValueError("at は ISO 8601 の日時です")
    return {"id": body["id"], "keep": body["keep"],
            "at": at or datetime.datetime.now().astimezone().isoformat(timespec="seconds")}


def http_post_feature_answer(handler, base: Path, data: bytes, log) -> None:
    appfeeds._http_inbox(handler, base, data, log, parse_feature_answer, FEATURE_ANSWERS, "検品表の答え", False,
                         lambda r: "続ける" if r["keep"] else "止める")


POSTS = {"/feature-answer": http_post_feature_answer}


def http_get(handler, base: Path, path: str) -> None:
    if path in HTML_GETS:
        http_get_html(handler, base)
    else:
        handler.send_json(200, READERS[path](base))
