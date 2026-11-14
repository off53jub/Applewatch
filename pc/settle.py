"""強化案 36・37・41 の家の PC の口（2026-11-15。番号は D:\\Lifelog\\docs\\system-proposal-2026-11-13.md の「追記 2」）。

- GET /rollout（features の "rollout"）← 母艦の state/rollout_for_app.json  入れた施策の様子（36。母艦が毎朝作る）
  {"version":1,"generated_at","items":[{"no","title"(≤40),"first_live","last_live","uses_7d","evidence"(≤80),"status"}]}
  status は live・unused・not_started・broken・retire_candidate（畳むのは本人が決める）
- GET /checks（"checks"）← 母艦の state/checks_for_app.json  正しさの抜き取り（41。1日1つ。7つまで）
  {"version":1,"generated_at","items":[{"id","day","source":"digest"|"proposal"|"promise"|"weekly","claim"(≤120),"evidence"(≤120)}]}
  答えは POST /feedback の kind "check"・value right|wrong|unsure（appfeeds.FEEDBACK）
- GET /costs（"costs"）← この PC の Claude の帳簿（claude-usage.jsonl。母艦も同じ帳簿に足す）と claude-config.json（37）
  {"available":true,"month","month_usd","projected_usd","monthly_usd","today":[{"purpose","usd","cap","stopped"}],
   "month_by_purpose":[{"purpose","usd","calls"}]}
読むだけ。型・長さ・形を確かめ、おかしな行は落とす。無い・読めないときは {"available": false, "reason": …}。
中身（施策の名前・主張の文）は記録（log.txt）に書かない。
"""

from __future__ import annotations

from pathlib import Path

import appfeeds
import claude

ROLLOUT = Path("state") / "rollout_for_app.json"
CHECKS = Path("state") / "checks_for_app.json"
FEATURES = ("rollout", "checks", "costs")
ROLLOUT_STATUS = ("live", "unused", "not_started", "broken", "retire_candidate")
ROLLOUT_ITEMS = 80
CHECK_SOURCES = ("digest", "proposal", "promise", "weekly")
CHECK_ITEMS = 7


def read_rollout(base: Path) -> dict:
    data, failure = appfeeds._load(base, ROLLOUT, "施策の検品表")
    if failure or data is None or not isinstance(data.get("items"), list):
        return failure or {"available": False, "reason": "母艦の施策の検品表の形が違います"}
    items, seen = [], set()
    for x in data["items"][:ROLLOUT_ITEMS * 4]:
        if not isinstance(x, dict):
            continue
        no, title = appfeeds._int(x.get("no"), 1, 10_000), appfeeds._text(x.get("title"), 40)
        if no is None or no in seen or not title or x.get("status") not in ROLLOUT_STATUS:
            continue
        uses = x.get("uses_7d")
        seen.add(no)
        items.append({"no": no, "title": title, "first_live": appfeeds._day(x.get("first_live")),
                      "last_live": appfeeds._day(x.get("last_live")),
                      "uses_7d": appfeeds._int(uses, 0, 10_000_000) if uses is not None else None,
                      "evidence": appfeeds._text(x.get("evidence"), 80), "status": x["status"]})
        if len(items) >= ROLLOUT_ITEMS:
            break
    items.sort(key=lambda i: i["no"])
    return {"available": True, "version": appfeeds._version(data), "generated_at": appfeeds._iso(data.get("generated_at")),
            "items": items}


def read_checks(base: Path) -> dict:
    data, failure = appfeeds._load(base, CHECKS, "正しさの抜き取り")
    if failure or data is None or not isinstance(data.get("items"), list):
        return failure or {"available": False, "reason": "母艦の正しさの抜き取りの形が違います"}
    items, seen = [], set()
    for x in data["items"][:CHECK_ITEMS * 4]:
        if not isinstance(x, dict):
            continue
        item_id, day, claim = appfeeds._id(x.get("id")), appfeeds._day(x.get("day")), appfeeds._text(x.get("claim"), 120)
        if item_id is None or item_id in seen or day is None or not claim or x.get("source") not in CHECK_SOURCES:
            continue
        seen.add(item_id)
        items.append({"id": item_id, "day": day, "source": x["source"], "claim": claim,
                      "evidence": appfeeds._text(x.get("evidence"), 120)})
        if len(items) >= CHECK_ITEMS:
            break
    items.sort(key=lambda i: i["day"], reverse=True)
    return {"available": True, "version": appfeeds._version(data), "generated_at": appfeeds._iso(data.get("generated_at")),
            "items": items}


def read_costs(base: Path) -> dict:
    """母艦の場所は使わない（帳簿はこの PC の HOME にある）。読めなければ available false"""
    try:
        return claude.costs_report()
    except Exception as error:  # noqa: BLE001 — 帳簿が読めなくても受け付けは続ける
        return {"available": False, "reason": f"帳簿を読めませんでした: {type(error).__name__}"}


READERS = {"/rollout": read_rollout, "/checks": read_checks, "/costs": read_costs}
