"""定額の枠（pc/subscription.py・2026-11-26）の確かめ。claude -p は呼ばない（偽物の exe と偽物の出力で見る）。"""
from __future__ import annotations

import datetime
import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import subscription  # noqa: E402


def say(ok: bool, text: str) -> int:
    print(("OK  " if ok else "NG  ") + text, flush=True)
    return 0 if ok else 1


def check_parse() -> int:
    f = 0
    ok = json.dumps({"type": "result", "subtype": "success", "is_error": False, "result": "答え", "total_cost_usd": 0.02})
    f += say(subscription.parse_output(ok)[:3] == ("答え", 0.02, False), "ふつうの答えを読める")
    so = json.dumps({"subtype": "success", "is_error": False, "result": "", "structured_output": {"a": 1}})
    f += say(json.loads(subscription.parse_output(so)[0]) == {"a": 1}, "決まった形の答え（structured_output）を読める")
    bad = json.dumps({"subtype": "success", "is_error": True, "result": "Failed to authenticate: OAuth session expired"})
    t, _, failed, why = subscription.parse_output(bad)
    f += say(failed and "authenticate" in why, "ログイン切れを失敗として読む")
    f += say(subscription.parse_output("こわれた")[2], "壊れた出力は失敗")
    return f


def check_route() -> int:
    f = 0
    saved = os.environ.get("LIFELOG_SUBSCRIPTION")
    with tempfile.TemporaryDirectory() as tmp:
        state = Path(tmp) / "state"
        state.mkdir()
        exe = Path(tmp) / "claude.exe"
        exe.write_text("x")
        orig = subscription._files
        subscription._files = lambda: (state / "claude_route.json", state / "claude_route_status.json")
        try:
            os.environ.pop("LIFELOG_SUBSCRIPTION", None)
            (state / "claude_route.json").write_text(json.dumps({"exe": str(exe), "daily_calls": 2}), encoding="utf-8")
            now = datetime.datetime(2026, 11, 26, 10, 0, tzinfo=subscription.JST)
            f += say(subscription.route_for("night-review", "standard", now) is not None, "Sonnet の頼みは定額の枠へ")
            f += say(subscription.route_for("correct", "light", now) is None, "Haiku の頼みは API のまま")
            (state / "claude_route_status.json").write_text(json.dumps({"rest_until": "2026-11-26T10:30:00+09:00"}), encoding="utf-8")
            f += say(subscription.route_for("night-review", "standard", now) is None, "休みのあいだは API に戻る")
            (state / "claude_route_status.json").write_text(json.dumps({"calls": {"2026-11-26": 2}}), encoding="utf-8")
            f += say(subscription.route_for("night-review", "standard", now) is None, "1 日の回数を越えたら API に戻る")
            (state / "claude_route_status.json").write_text("{}", encoding="utf-8")
            (state / "claude_route.json").write_text(json.dumps({"exe": str(exe), "purposes_api": ["night"]}), encoding="utf-8")
            f += say(subscription.route_for("night-review", "standard", now) is None, "purposes_api で API に決め打ちできる")
            (state / "claude_route.json").write_text(json.dumps({"exe": str(exe), "on": False}), encoding="utf-8")
            f += say(subscription.route_for("night-review", "standard", now) is None, "on false なら使わない")
            os.environ["LIFELOG_SUBSCRIPTION"] = "0"
            (state / "claude_route.json").write_text(json.dumps({"exe": str(exe)}), encoding="utf-8")
            f += say(subscription.route_for("night-review", "standard", now) is None, "確かめのときは呼ばない")
        finally:
            subscription._files = orig
            if saved is None:
                os.environ.pop("LIFELOG_SUBSCRIPTION", None)
            else:
                os.environ["LIFELOG_SUBSCRIPTION"] = saved
    return f


CHECKS = [check_parse, check_route]


def run_all() -> int:
    failed = 0
    for check in CHECKS:
        try:
            failed += check()
        except Exception as error:  # noqa: BLE001
            import traceback

            traceback.print_exc()
            failed += say(False, f"{check.__name__} が途中で落ちました: {error!r}")
    return failed


def main() -> int:
    failed = run_all()
    print("ぜんぶ OK" if not failed else f"NG の数: {failed}", flush=True)
    return failed


if __name__ == "__main__":
    sys.exit(main())
