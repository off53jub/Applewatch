"""LifeLog PC: s24（2026-11-24）の設定の決まり。ほかのファイルから読む小さな口だけ（重い import はしない）。

取り決め（名前と形を変えない）:
- C4（当1）: 「同じ人か」の問いは config.json の "same_person_ask" が true のときだけ出す（初めは false）。
  止めるのは出す所だけ。組を作る・点を出す・答え合わせ（s-norm・AUC）は続ける。
  止める問い: GET /same-person の組（日ごと・日をまたぐ・名前のある人かも）、確かめ待ちの「この 2 つの声は同じ人ですか」
  （kind voice_pair）、「A の声と B の声は同じ人ですか」（kind speaker_split。GET /speaker-split と母艦への写し）。
- C5（減5）: APNs の kind promise は "promise_push" が true のときだけ送る（初めは false）。約束の台帳・GET /promises-now は続ける。
- C3（減3）: 家の PC が出す問いは "pc_question_days"（初めは 3 日・仮）で閉じる（s24pc.py）。
"""

from __future__ import annotations

import sys

# 「同じ人か」の問いの種類（確かめ待ちの kind）
SAME_KINDS = ("voice_pair", "speaker_split", "same_person")
QUESTION_DAYS = 3          # 仮: 家の PC の問いを閉じるまでの日数

# s24pc.start が lifelog_pc.load_config を入れる。無ければ読み込み済みの lifelog_pc から探す
CONFIG = None


def current_config() -> dict:
    try:
        if CONFIG is not None:
            return CONFIG() or {}
        for name in ("lifelog_pc", "__main__"):
            module = sys.modules.get(name)
            loader = getattr(module, "load_config", None)
            if callable(loader):
                return loader() or {}
    except Exception:  # noqa: BLE001 — 読めなければ既定（止める側）
        pass
    return {}


def _config(config: dict | None) -> dict:
    return current_config() if config is None else (config or {})


def same_person_ask(config: dict | None = None) -> bool:
    """C4: 「同じ人か」の問いを出すか（初めは出さない）"""
    return _config(config).get("same_person_ask") is True


def promise_push(config: dict | None = None) -> bool:
    """C5: 約束の知らせ（APNs の kind promise）を送るか（初めは送らない）"""
    return _config(config).get("promise_push") is True


def question_days(config: dict | None = None) -> int:
    """C3: 家の PC の問いを閉じるまでの日数（1〜30。初めは 3・仮）"""
    value = _config(config).get("pc_question_days")
    if isinstance(value, int) and not isinstance(value, bool) and 1 <= value <= 30:
        return value
    return QUESTION_DAYS


def hold_same_person(body: dict, config: dict | None = None) -> dict:
    """GET /same-person の答えから、出さない設定なら組を抜く（available はそのまま・抜いた数は "held"）"""
    if same_person_ask(config) or not isinstance(body, dict) or not body.get("available"):
        return body
    groups = sum(len(d.get("groups") or []) for d in body.get("days") or [] if isinstance(d, dict))
    held = {"groups": groups, "across": len(body.get("across") or []), "maybe": len(body.get("maybe") or [])}
    out = {k: v for k, v in body.items() if k not in ("across", "maybe")}
    out["days"] = [{**d, "groups": []} for d in body.get("days") or [] if isinstance(d, dict)]
    out.update({"ask": False, "held": held,
                "reason": "「同じ人か」の問いは止めています（config.json の \"same_person_ask\": true で戻せます）"})
    return out


def hold_items(body: dict, config: dict | None = None) -> dict:
    """GET /speaker-split・母艦への写し: 出さない設定なら items を空にする（"held" に数）"""
    if same_person_ask(config) or not isinstance(body, dict) or not isinstance(body.get("items"), list):
        return body
    return {**body, "items": [], "held": len(body["items"]), "ask": False}
