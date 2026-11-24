"""LifeLog PC: s25 活1（PC 側。2026-11-24。担当 P）。機械が迷った問いを Claude が先に見て、確かなものだけ閉じる口。初めはオフ。

- 見るのは、家の PC が作る確かめ待ちの「この行の数字はどれですか」（s22 確19・kind "number"。HOME/s22/review/items.json）だけ
  （文だけで決められる問い。声の問いは Claude には聞こえないので見ない）。
- Claude（pc/claude.py の上限と台帳を通す・purpose "s25-precheck"・light）に、選びの文と前後の行を渡し、
  {"pick": 番号, "sure": true|false} だけを答えてもらう（新しい文は書かせない）。
- 閉じるのは「確か（sure）で、選んだのが今の文（多数決の文）と同じ」ときだけ＝機械の見立てのままでよいと分かったもの。
  今の文と違う番号を選んだときは閉じない（本人に聞く問いのまま。文も直さない）。
- 1 日の上限: purpose の額 "s25p_precheck_usd"（初めは $0.05・仮）と、1 日の数 "s25p_precheck_daily"（初めは 5 問・仮）。
  claude-config.json の daily_caps・stopped・今月の上限もそのまま効く。
- config.json の "s25p_precheck": true で動く（初めはオフ）。答えは HOME/s25p/precheck.json（{id: {"verdict","at"}}。文は残さない）。
  GET /review-queue からは、閉じたものを抜く（"pc_held" の "precheck" に数）。
"""

from __future__ import annotations

import datetime
import json
import os
from pathlib import Path

PURPOSE = "s25-precheck"
DAILY_USD = 0.05        # 仮
DAILY_COUNT = 5         # 仮
KEEP_DAYS = 30
SYSTEM = ("あなたは日本語の文字起こしの確かめ役です。音声を文字にしたある行の、数字・日付・金額の部分について、"
          "いくつかの候補の文があります。前後の行から考えて、いちばん正しい候補の番号を 1 つ選んでください。"
          "迷う・どれとも言えないときは sure を false にします。新しい文は書かず、番号だけを答えます。")
SCHEMA = {"type": "object", "properties": {"pick": {"type": "integer"}, "sure": {"type": "boolean"}},
          "required": ["pick", "sure"], "additionalProperties": False}


def folder(home: Path) -> Path:
    return Path(home) / "s25p"


def _read(path: Path, default=None):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def _write(path: Path, body) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    part = path.with_name(path.name + ".part")
    part.write_text(json.dumps(body, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(part, path)


def state(home: Path) -> dict:
    body = _read(folder(home) / "precheck.json", {}) or {}
    return body if isinstance(body.get("items"), dict) else {"items": {}}


def closed_ids(home: Path) -> set:
    return {k for k, v in state(home)["items"].items() if isinstance(v, dict) and v.get("verdict") == "closed"}


def on(config: dict) -> bool:
    return (config or {}).get("s25p_precheck") is True


def context_lines(store, ref: str, around: int = 2) -> list[str]:
    """ref（"日|ミリ秒"）の行の前後 around 行の文"""
    try:
        day, ms = ref.split("|")
        ms = int(ms)
        parsed = store.day(day) if store is not None else None
    except (ValueError, AttributeError):
        return []
    for conversation in (parsed or {}).get("conversations") or []:
        lines = conversation.get("lines") or []
        for i, line in enumerate(lines):
            if line.get("time") == ms:
                return [str(x.get("text") or "")[:120] for x in lines[max(0, i - around):i + around + 1]]
    return []


def prompt_for(item: dict, context: list[str]) -> str:
    choices = "\n".join(f"{i}: {c}" for i, c in enumerate(item.get("choices") or []))
    near = "\n".join(context) if context else "（前後の行はありません）"
    return f"前後の行:\n{near}\n\n候補:\n{choices}\n\n番号（0 から）と、確かかどうかを JSON で答えてください。"


def run(home: Path, store, config: dict, today: datetime.date | None = None, caller=None) -> dict:
    """まだ見ていない kind number の問いを、1 日の上限まで見る。{"asked","closed","kept","stopped"}"""
    out = {"asked": 0, "closed": 0, "kept": 0, "stopped": None}
    if not on(config):
        out["stopped"] = "off"
        return out
    import claude

    today = today or datetime.date.today()
    day = today.isoformat()
    limit_usd = config.get("s25p_precheck_usd") if isinstance(config.get("s25p_precheck_usd"), (int, float)) else DAILY_USD
    limit_count = config.get("s25p_precheck_daily") if isinstance(config.get("s25p_precheck_daily"), int) else DAILY_COUNT
    items = (_read(Path(home) / "s22" / "review" / "items.json", {}) or {}).get("items") or []
    body = state(home)
    seen = body["items"]
    asked_today = sum(1 for v in seen.values() if isinstance(v, dict) and v.get("at", "")[:10] == day)
    call = caller or claude.call
    for item in items:
        if not isinstance(item, dict) or item.get("kind") != "number" or item.get("id") in seen:
            continue
        if asked_today >= limit_count:
            out["stopped"] = "count"
            break
        if caller is None and claude.LEDGER.day_usd(day, PURPOSE) >= float(limit_usd):
            out["stopped"] = "usd"
            break
        choices = item.get("choices") or []
        evidence = (item.get("evidence") or [{}])[0] or {}
        current = str(evidence.get("text") or "")
        if len(choices) < 2:
            continue
        try:
            got = call(SYSTEM, prompt_for(item, context_lines(store, str(evidence.get("ref") or ""))), json=True,
                       max_tokens=60, tier="light", purpose=PURPOSE, schema=SCHEMA, who="pc", work=True)
            data = got.get("data") if isinstance(got, dict) else None
        except Exception as error:  # noqa: BLE001 — 頼めなければ、今日はここまで
            out["stopped"] = type(error).__name__
            break
        asked_today += 1
        out["asked"] += 1
        pick = data.get("pick") if isinstance(data, dict) else None
        sure = isinstance(data, dict) and data.get("sure") is True
        verdict = "kept"
        if sure and isinstance(pick, int) and 0 <= pick < len(choices) and current and choices[pick].strip()[:80] == current.strip()[:80]:
            verdict = "closed"
            out["closed"] += 1
        else:
            out["kept"] += 1
        seen[str(item["id"])] = {"verdict": verdict, "at": datetime.datetime.now().isoformat(timespec="seconds"),
                                 "sure": bool(sure)}
    limit = (today - datetime.timedelta(days=KEEP_DAYS)).isoformat()
    body["items"] = {k: v for k, v in seen.items() if isinstance(v, dict) and str(v.get("at", "")) >= limit}
    if out["asked"]:
        _write(folder(home) / "precheck.json", body)
    return out


def drop_closed(body: dict, home: Path | None) -> dict:
    """GET /review-queue から、Claude が先に見て閉じた問いを抜く"""
    if home is None or not isinstance(body, dict) or not isinstance(body.get("items"), list):
        return body
    closed = closed_ids(home)
    if not closed:
        return body
    kept = [i for i in body["items"] if not (isinstance(i, dict) and i.get("id") in closed)]
    held = len(body["items"]) - len(kept)
    out = {**body, "items": kept}
    if held:
        out["pc_held"] = {**(body.get("pc_held") or {}), "precheck": held}
    return out
