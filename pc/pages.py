"""人・話題の糸・場所・決めごとのページ（2026-11-15。強化案 53・54・55・61。番号は D:\\Lifelog\\docs\\system-proposal-2026-11-13.md の「追記 3」）。

母艦の scripts が作る state を確かめて返す（どれも名前と文を含む非公開のフィード。形は母艦の Check-AppFeeds.py と同じ）:
- GET /people-pages（features の "peoplepages"）← state/people_for_app.json  人のページ（直近 60 日に話した・LINE した人。53）
  {"version":1,"generated_at","items":[{"id","name"(≤20),"group"(≤10),"aliases":[≤20](≤10),
    "last_talk":{"day","summary"(≤120),"source":"app"|"line"}|null,"last_line":day|null,"line_7d","line_30d","talks_30d",
    "topics":[{"text"(≤60),"day"|null}](≤5),"promises":[{"text"(≤80),"by":"me"|"them","day"|null,"source"}](≤8),
    "likes":[≤60](≤6),"next_line"(≤100),"next_why"(≤80),"upcoming":{"day","time","title"(≤40)}|null,"updated":day}](≤60)}
- GET /threads（"threads"）← state/threads_for_app.json  話題の糸（何日もまたぐ同じ話。54）
  {"items":[{"id","title"(≤40),"kind":"work"|"private","status":"open"|"settled","decided":[{"text"(≤100),"day"|null}](≤8),
    "open":[…](≤8),"next"(≤100),"days":[day](≤30),"last_day":day,"source":"machine"|"claude"}](≤40)}
- GET /place-pages（"placepages"）← state/places_for_app.json  場所のページ（55）
  {"items":[{"id","name"(≤40),"sure":bool,"visit_days","visits","last_day","spent":int|null,"with":[≤20](≤6),
    "recent":[{"day","time"("HH:MM–HH:MM"),"amount":int|null,"with":[≤20](≤4),"talk"(≤100)}](≤20)}](≤80)}
- GET /decisions（"decisions"）← state/decisions_for_app.json  決めごと（DECISIONS.md の Open。61）
  {"items":[{"id","title"(≤60),"deadline":day|null,"default"(≤120),"options":[{"n","label"(≤60),"detail"(≤120),"is_default"}](≤8),
    "background"(≤300),"opened":day|null}](≤30)}
- POST /decisions/answer（"decisions"）{"id", "choice": 0〜20（0 はデフォルト）, "day"} → 今の決めごとの写しで id と選択肢を
  確かめ、母艦の inbox/decision_answers.jsonl に {"id","title","choice","label","day","at"} を 1 行（帳面に書くのは母艦の
  Build-Decisions.py。選んだものの文は写しから作り、アプリの送った文は使わない）。写しに無い id・選択肢は 409。
読むだけ（POST は 1 行足すだけ）。型・長さ・形を確かめ、おかしな行は落とす。無い・読めないときは {"available": false, "reason": …}。
中身（名前・題・選んだもの）は記録（log.txt）に書かない。
"""

from __future__ import annotations

import datetime
import re
from pathlib import Path

import appfeeds as A

PEOPLE = Path("state") / "people_for_app.json"
THREADS = Path("state") / "threads_for_app.json"
PLACES = Path("state") / "places_for_app.json"
DECISIONS = Path("state") / "decisions_for_app.json"
ANSWERS = Path("inbox") / "decision_answers.jsonl"
FEATURES = ("peoplepages", "threads", "placepages", "decisions")
PEOPLE_LIMIT = 60
THREAD_LIMIT = 40
PLACE_LIMIT = 80
DECISION_LIMIT = 30
CHOICE_MAX = 20
PROMISE_SOURCES = ("line", "talk", "task", "todo")
SPAN = re.compile(r"\d{2}:\d{2}–\d{2}:\d{2}")
HM = re.compile(r"\d{1,2}:\d{2}")


def _rows(value, limit: int) -> list[dict]:
    return [x for x in (value if isinstance(value, list) else [])[:limit * 4] if isinstance(x, dict)]


def _bool(value) -> bool:
    return value is True


def _yen(value) -> int | None:
    return A._int(value, 0, 100_000_000)


def _dated(value, n: int, limit: int) -> list[dict]:
    out = []
    for x in _rows(value, limit):
        text = A._text(x.get("text"), n)
        if text:
            out.append({"text": text, "day": A._day(x.get("day"))})
        if len(out) >= limit:
            break
    return out


def _head(data: dict, items: list) -> dict:
    return {"available": True, "version": A._version(data), "generated_at": A._iso(data.get("generated_at")), "items": items}


# MARK: - 人のページ（53）

def read_people_pages(base: Path) -> dict:
    data, failure = A._load(base, PEOPLE, "人のページ")
    if failure or data is None or not isinstance(data.get("items"), list):
        return failure or {"available": False, "reason": "母艦の人のページの形が違います"}
    items, seen = [], set()
    for x in _rows(data["items"], PEOPLE_LIMIT):
        pid, name = A._id(x.get("id")), A._text(x.get("name"), 20)
        if pid is None or pid in seen or not name:
            continue
        last = x.get("last_talk")
        last_talk = None
        if isinstance(last, dict) and A._day(last.get("day")) and last.get("source") in ("app", "line") \
                and A._text(last.get("summary"), 120):
            last_talk = {"day": last["day"], "summary": A._text(last["summary"], 120), "source": last["source"]}
        promises = []
        for p in _rows(x.get("promises"), 8):
            text = A._text(p.get("text"), 80)
            if text and p.get("by") in ("me", "them") and p.get("source") in PROMISE_SOURCES:
                promises.append({"text": text, "by": p["by"], "day": A._day(p.get("day")), "source": p["source"]})
            if len(promises) >= 8:
                break
        up = x.get("upcoming")
        upcoming = None
        if isinstance(up, dict) and A._day(up.get("day")) and A._text(up.get("title"), 40):
            time = up.get("time") if isinstance(up.get("time"), str) and HM.fullmatch(up["time"]) else ""
            upcoming = {"day": up["day"], "time": time, "title": A._text(up["title"], 40)}
        seen.add(pid)
        items.append({"id": pid, "name": name, "group": A._text(x.get("group"), 10),
                      "aliases": A._strings(x.get("aliases"), 20, 10), "last_talk": last_talk,
                      "last_line": A._day(x.get("last_line")),
                      "line_7d": A._int(x.get("line_7d"), 0, 1_000_000) or 0,
                      "line_30d": A._int(x.get("line_30d"), 0, 1_000_000) or 0,
                      "talks_30d": A._int(x.get("talks_30d"), 0, 1_000_000) or 0,
                      "topics": _dated(x.get("topics"), 60, 5), "promises": promises,
                      "likes": A._strings(x.get("likes"), 60, 6), "next_line": A._text(x.get("next_line"), 100),
                      "next_why": A._text(x.get("next_why"), 80), "upcoming": upcoming, "updated": A._day(x.get("updated"))})
        if len(items) >= PEOPLE_LIMIT:
            break
    return _head(data, items)


# MARK: - 話題の糸（54）

def read_threads(base: Path) -> dict:
    data, failure = A._load(base, THREADS, "話題の糸")
    if failure or data is None or not isinstance(data.get("items"), list):
        return failure or {"available": False, "reason": "母艦の話題の糸の形が違います"}
    items, seen = [], set()
    for x in _rows(data["items"], THREAD_LIMIT):
        tid, title = A._id(x.get("id")), A._text(x.get("title"), 40)
        days = []
        for d in (x.get("days") if isinstance(x.get("days"), list) else [])[:120]:
            if A._day(d) and d not in days:
                days.append(d)
        days = sorted(days, reverse=True)[:30]
        if tid is None or tid in seen or not title or x.get("kind") not in ("work", "private") \
                or x.get("status") not in ("open", "settled") or not days:
            continue
        seen.add(tid)
        items.append({"id": tid, "title": title, "kind": x["kind"], "status": x["status"],
                      "decided": _dated(x.get("decided"), 100, 8), "open": _dated(x.get("open"), 100, 8),
                      "next": A._text(x.get("next"), 100), "days": days, "last_day": days[0],
                      "source": x.get("source") if x.get("source") in ("machine", "claude") else "machine"})
        if len(items) >= THREAD_LIMIT:
            break
    items.sort(key=lambda t: t["last_day"], reverse=True)
    return _head(data, items)


# MARK: - 場所のページ（55）

def read_place_pages(base: Path) -> dict:
    data, failure = A._load(base, PLACES, "場所のページ")
    if failure or data is None or not isinstance(data.get("items"), list):
        return failure or {"available": False, "reason": "母艦の場所のページの形が違います"}
    items, seen = [], set()
    for x in _rows(data["items"], PLACE_LIMIT):
        pid, name, last = A._id(x.get("id")), A._text(x.get("name"), 40), A._day(x.get("last_day"))
        days, visits = A._int(x.get("visit_days"), 0, 100_000), A._int(x.get("visits"), 0, 100_000)
        if pid is None or pid in seen or not name or last is None or days is None or visits is None:
            continue
        recent = []
        for r in _rows(x.get("recent"), 20):
            span = r.get("time") if isinstance(r.get("time"), str) and SPAN.fullmatch(r["time"]) else None
            if A._day(r.get("day")) is None or span is None:
                continue
            recent.append({"day": r["day"], "time": span, "amount": _yen(r.get("amount")),
                           "with": A._strings(r.get("with"), 20, 4), "talk": A._text(r.get("talk"), 100)})
            if len(recent) >= 20:
                break
        seen.add(pid)
        items.append({"id": pid, "name": name, "sure": _bool(x.get("sure")), "visit_days": days, "visits": visits,
                      "last_day": last, "spent": _yen(x.get("spent")), "with": A._strings(x.get("with"), 20, 6),
                      "recent": recent})
        if len(items) >= PLACE_LIMIT:
            break
    items.sort(key=lambda p: (p["last_day"], p["visit_days"]), reverse=True)
    return _head(data, items)


# MARK: - 決めごと（61）

def read_decisions(base: Path) -> dict:
    data, failure = A._load(base, DECISIONS, "決めごと")
    if failure or data is None or not isinstance(data.get("items"), list):
        return failure or {"available": False, "reason": "母艦の決めごとの形が違います"}
    items, seen = [], set()
    for x in _rows(data["items"], DECISION_LIMIT):
        did, title = A._id(x.get("id")), A._text(x.get("title"), 60)
        if did is None or did in seen or not title:
            continue
        options, numbers = [], set()
        for o in _rows(x.get("options"), 8):
            n, label = A._int(o.get("n"), 1, CHOICE_MAX), A._text(o.get("label"), 60)
            if n is None or n in numbers or not label:
                continue
            numbers.add(n)
            options.append({"n": n, "label": label, "detail": A._text(o.get("detail"), 120), "is_default": _bool(o.get("is_default"))})
            if len(options) >= 8:
                break
        default = A._text(x.get("default"), 120)
        if not options and not default:
            continue  # 選べるものが無い
        seen.add(did)
        items.append({"id": did, "title": title, "deadline": A._day(x.get("deadline")), "default": default,
                      "options": options, "background": A._text(x.get("background"), 300), "opened": A._day(x.get("opened"))})
        if len(items) >= DECISION_LIMIT:
            break
    items.sort(key=lambda d: (d["deadline"] is None, d["deadline"] or ""))
    return _head(data, items)


class Conflict(ValueError):
    """写しに無い id・選択肢（アプリの写しが古い）"""


def parse_decision_answer(data: bytes, base: Path) -> dict:
    """POST /decisions/answer の中身。おかしければ ValueError、写しに無ければ Conflict"""
    body = A._json_body(data)
    if A._id(body.get("id")) is None:
        raise ValueError("id は英数字と _ . : - で 64 文字までです")
    choice = A._int(body.get("choice"), 0, CHOICE_MAX)
    if choice is None:
        raise ValueError(f"choice は 0〜{CHOICE_MAX} の整数です（0 はデフォルト）")
    if A._day(body.get("day")) is None:
        raise ValueError("day は YYYY-MM-DD です")
    feed = read_decisions(base)
    item = next((d for d in feed.get("items") or [] if d["id"] == body["id"]), None) if feed.get("available") else None
    if item is None:
        raise Conflict("その決めごとは、もう帳面にありません（読み直してください）")
    if choice == 0:
        label = item["default"]
    else:
        label = next((o["label"] for o in item["options"] if o["n"] == choice), "")
    if not label:
        raise Conflict("その選択肢は、いまの帳面にありません（読み直してください）")
    return {"id": item["id"], "title": item["title"], "choice": choice, "label": label, "day": body["day"]}


def http_post_decision(handler, base: Path, data: bytes, log) -> None:
    try:
        row = parse_decision_answer(data, base)
    except Conflict as error:
        handler.send_json(409, {"error": str(error)})
        return
    except ValueError as error:
        handler.send_json(400, {"error": str(error)})
        return
    row["at"] = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
    try:
        A.append_inbox(base, ANSWERS, row)
    except OSError as error:
        log(f"決めごとの答えを母艦に置けませんでした: {type(error).__name__}")
        handler.send_json(503, {"error": "母艦に置けませんでした"})
        return
    # 題・選んだものは書かない
    log(f"{handler.client_address[0]} から決めごとの答えを母艦へ: 1 件")
    handler.send_json(200, {"ok": True, "label": row["label"]})


READERS = {"/people-pages": read_people_pages, "/threads": read_threads, "/place-pages": read_place_pages,
           "/decisions": read_decisions}
POSTS = {"/decisions/answer": http_post_decision}
