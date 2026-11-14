"""強化案 58・60 の家の PC の口（2026-11-15。番号は D:\\Lifelog\\docs\\system-proposal-2026-11-13.md の「追記 3」）。

- GET /replies（features の "replies"）← 母艦の state/replies_for_app.json（58。母艦の Build-Replies.py が作る）
  {"version":1,"generated_at","items":[{"id","chat"(≤40),"who"(≤20),"last_at":ISO,"waiting_hours":int,"ask"(≤120),
   "draft"(≤300),"note"(≤80)}](≤10),"mails":[{"id","to"(≤40),"subject"(≤80),"body"(≤800),"why"(≤120),"day"}](≤5)}
  LINE の返事待ちの下書きと、約束したメールの下書き。**何も送らない**（アプリは「写す」「LINE を開く」だけ）。
- GET /time-ledger（"timeledger"）← 母艦の state/time_for_app.json（60。母艦の Build-TimeLedger.py が作る）
  {"version":1,"generated_at","method"(≤400),"categories":[{"key","label","overlay"}](≤16),
   "weeks":[{"week","from","to","days","covered","hours":{key: 時間}}](≤12)}
読むだけ。型・長さ・形を確かめ、おかしな行は落とす。無い・読めないときは {"available": false, "reason": …}。
中身（名前・下書きの文）は記録（log.txt）に書かない。
"""

from __future__ import annotations

import re
from pathlib import Path

import appfeeds

REPLIES = Path("state") / "replies_for_app.json"
TIME_LEDGER = Path("state") / "time_for_app.json"
FEATURES = ("replies", "timeledger")
REPLY_ITEMS = 10
MAIL_ITEMS = 5
CATEGORY_LIMIT = 16
WEEKS = 12
KEY = re.compile(r"[a-z_]{1,20}")
WEEK = re.compile(r"\d{4}-W\d{2}")


def _long(value, n: int) -> str:
    """改行を残す文（下書き）。前後の空白を除き、n 文字まで"""
    if not isinstance(value, str):
        return ""
    return value.replace("\r\n", "\n").strip()[:n]


def read_replies(base: Path) -> dict:
    data, failure = appfeeds._load(base, REPLIES, "返事の下書き")
    if failure or data is None or not isinstance(data.get("items"), list):
        return failure or {"available": False, "reason": "母艦の返事の下書きの形が違います"}
    items, seen = [], set()
    for x in data["items"][:REPLY_ITEMS * 4]:
        if not isinstance(x, dict):
            continue
        item_id, chat, draft = appfeeds._id(x.get("id")), appfeeds._text(x.get("chat"), 40), _long(x.get("draft"), 300)
        last_at = appfeeds._when(x.get("last_at"))
        if item_id is None or item_id in seen or not chat or not draft or last_at is None:
            continue
        seen.add(item_id)
        items.append({"id": item_id, "chat": chat, "who": appfeeds._text(x.get("who"), 20), "last_at": last_at,
                      "waiting_hours": appfeeds._int(x.get("waiting_hours"), 0, 10_000) or 0,
                      "ask": appfeeds._text(x.get("ask"), 120), "draft": draft, "note": appfeeds._text(x.get("note"), 80)})
        if len(items) >= REPLY_ITEMS:
            break
    mails, seen = [], set()
    for x in (data.get("mails") if isinstance(data.get("mails"), list) else [])[:MAIL_ITEMS * 4]:
        if not isinstance(x, dict):
            continue
        item_id, subject, body = appfeeds._id(x.get("id")), appfeeds._text(x.get("subject"), 80), _long(x.get("body"), 800)
        if item_id is None or item_id in seen or not subject or not body:
            continue
        seen.add(item_id)
        mails.append({"id": item_id, "to": appfeeds._text(x.get("to"), 40), "subject": subject, "body": body,
                      "why": appfeeds._text(x.get("why"), 120), "day": appfeeds._day(x.get("day"))})
        if len(mails) >= MAIL_ITEMS:
            break
    return {"available": True, "version": appfeeds._version(data), "generated_at": appfeeds._iso(data.get("generated_at")),
            "items": items, "mails": mails}


def read_time_ledger(base: Path) -> dict:
    data, failure = appfeeds._load(base, TIME_LEDGER, "時間の家計簿")
    if failure or data is None or not isinstance(data.get("weeks"), list) or not isinstance(data.get("categories"), list):
        return failure or {"available": False, "reason": "母艦の時間の家計簿の形が違います"}
    categories, keys = [], set()
    for c in data["categories"][:CATEGORY_LIMIT * 2]:
        if not isinstance(c, dict):
            continue
        key, label = c.get("key"), appfeeds._text(c.get("label"), 30)
        if not isinstance(key, str) or not KEY.fullmatch(key) or key in keys or not label:
            continue
        keys.add(key)
        categories.append({"key": key, "label": label, "overlay": c.get("overlay") is True})
        if len(categories) >= CATEGORY_LIMIT:
            break
    weeks, seen = [], set()
    for w in data["weeks"][:WEEKS * 4]:
        if not isinstance(w, dict) or not isinstance(w.get("week"), str) or not WEEK.fullmatch(w["week"]) \
                or w["week"] in seen or not isinstance(w.get("hours"), dict):
            continue
        hours = {}
        for key in keys:
            value = appfeeds._num(w["hours"].get(key), 0, 24 * 7)
            hours[key] = round(value, 1) if value is not None else 0.0
        seen.add(w["week"])
        weeks.append({"week": w["week"], "from": appfeeds._day(w.get("from")), "to": appfeeds._day(w.get("to")),
                      "days": appfeeds._int(w.get("days"), 0, 7) or 0,
                      "covered": appfeeds._num(w.get("covered"), 0, 1) or 0.0, "hours": hours})
    weeks.sort(key=lambda w: w["week"], reverse=True)
    return {"available": True, "version": appfeeds._version(data), "generated_at": appfeeds._iso(data.get("generated_at")),
            "method": appfeeds._text(data.get("method"), 400), "categories": categories, "weeks": weeks[:WEEKS]}


READERS = {"/replies": read_replies, "/time-ledger": read_time_ledger}
