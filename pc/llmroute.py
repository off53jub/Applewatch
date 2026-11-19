"""LifeLog PC: 安い AI で判定して、自信が低いものだけ高い AI で見直す（s18 の 69。2026-11-19）。

- 呼び出し口は claude.call だけ（鍵・今月の上限・用途ごとの止め／1 日の上限・帳簿 claude-usage.jsonl は
  家の PC と母艦で共有の仕組みをそのまま通る）。新しい帳簿・新しい鍵の置き場所は作らない。
- judge(purpose, system, prompt, schema):
  1. tier "light"（Haiku）で頼む。答えの JSON に "confidence"（0〜1）を必ず入れてもらう（schema に足す）。
  2. confidence が REVIEW_BELOW（仮）より小さいときだけ、同じ頼みを tier "standard"（Sonnet）で頼み直す。
     見直しの用途は "<purpose>.review"（帳簿で安い方と高い方を分けて数えられる）。
  3. 見直しが頼めない（上限・止め・失敗）ときは、安い方の答えを "reviewed": false のまま返す。
- 1 日の上限（新しい有料の呼び出しなので必ず置く）: claude-config.json の "daily_caps" に用途の鍵があればそれ、
  無ければ DAILY_CAPS（仮）。その日の帳簿の合計が上限に届いたら頼まない（ClaudeError 409。claude.purpose_gate と同じ数え方）。
  家の PC の config.json の "llm_route_caps": {"<用途>": usd} でも替えられる（claude-config.json の方が先）。
- 頼む文と答えの中身は記録（log.txt）に書かない（claude.call が長さと値段だけを書く）。
"""

from __future__ import annotations

from typing import Callable

import claude

REVIEW_BELOW = 0.7            # 仮: これより自信が低ければ高い AI で見直す
CHEAP_TIER = "light"
REVIEW_TIER = "standard"
# 仮: 新しい用途の 1 日の上限（ドル）。honne は 1 日に数十件の独り言の分け方（Haiku 1 件 $0.0005 ほどの見込み）
DAILY_CAPS = {"honne": 0.10, "honne.review": 0.10}


def cap_for(purpose: str, config: dict | None = None) -> float | None:
    """その用途の 1 日の上限（claude-config.json の daily_caps → config.json の llm_route_caps → 既定の DAILY_CAPS）"""
    shared = claude.load_config().get("daily_caps") or {}
    found = claude.cap_for(purpose, shared)
    if found is not None:
        return found[1]
    local = (config or {}).get("llm_route_caps")
    if isinstance(local, dict):
        found = claude.cap_for(purpose, {k: float(v) for k, v in local.items()
                                         if isinstance(k, str) and isinstance(v, (int, float)) and not isinstance(v, bool)})
        if found is not None:
            return found[1]
    found = claude.cap_for(purpose, DAILY_CAPS)
    return found[1] if found is not None else None


def gate(purpose: str, config: dict | None = None) -> str | None:
    """今日はもう頼まないなら、わけの文。頼んでよければ None"""
    cap = cap_for(purpose, config)
    if cap is not None and claude.LEDGER.day_usd(claude.today(), purpose) >= cap:
        return f"この用途の今日の上限 ${cap:.2f} に届きました"
    return None


def with_confidence(schema: dict) -> dict:
    """答えの形に confidence（0〜1）を足す（元の形は変えない）"""
    out = dict(schema)
    props = dict(out.get("properties") or {})
    props["confidence"] = {"type": "number"}
    out["properties"] = props
    required = list(out.get("required") or [])
    if "confidence" not in required:
        required.append("confidence")
    out["required"] = required
    return out


def _confidence(data) -> float | None:
    value = data.get("confidence") if isinstance(data, dict) else None
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return max(0.0, min(1.0, float(value)))
    return None


def judge(purpose: str, system: str, prompt: str, schema: dict, work: bool = False, max_tokens: int = 512,
          config: dict | None = None, below: float = REVIEW_BELOW, log: Callable[[str], None] | None = None) -> dict:
    """{"data", "confidence", "model", "usd", "reviewed": bool, "review_error": 文|None} を返す。
    安い方も頼めなければ claude.ClaudeError（409 は 1 日の上限）。"""
    stop = gate(purpose, config)
    if stop:
        raise claude.ClaudeError(claude.PURPOSE_OFF, stop, purpose_off="daily_cap")
    shaped = with_confidence(schema)
    first = claude.call(system, prompt, json=True, max_tokens=max_tokens, tier=CHEAP_TIER, purpose=purpose,
                        work=work, schema=shaped, log=log)
    conf = _confidence(first.get("data"))
    result = {"data": first.get("data"), "confidence": conf, "model": first.get("model"), "usd": first.get("usd", 0.0),
              "reviewed": False, "review_error": None, "first_confidence": conf}
    if conf is not None and conf >= below:
        return result
    review = f"{purpose}.review"[:40]
    stop = gate(review, config)
    if stop:
        result["review_error"] = stop
        return result
    try:
        second = claude.call(system, prompt, json=True, max_tokens=max_tokens, tier=REVIEW_TIER, purpose=review,
                             work=work, schema=shaped, log=log)
    except claude.ClaudeError as error:
        result["review_error"] = str(error.body.get("error") if isinstance(getattr(error, "body", None), dict)
                                     else "見直しを頼めませんでした")[:80]
        return result
    result.update({"data": second.get("data"), "confidence": _confidence(second.get("data")),
                   "model": second.get("model"), "usd": round(result["usd"] + second.get("usd", 0.0), 6),
                   "reviewed": True})
    return result
