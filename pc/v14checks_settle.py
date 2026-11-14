"""強化案 36・37・41・49（2026-11-15。中身は settle.py・claude.py の止め・上限・費用・appfeeds.py の check と wish）を確かめる。

    python pc/v14checks_settle.py

本物の鍵・ネット・母艦は使わない（作り物の Claude・一時のフォルダ）。本物の HOME に書かない（isolate_home）。確かめること:
- claude-config.json の stopped・daily_caps を読む（おかしな値は落とす）。前方一致は一番長いもの
- stopped の用途は頼まずに 409（purpose_off "stopped"）。daily_caps は今日のその用途の帳簿の合計が上限に届いたら 409（"daily_cap"）。
  きのうの分・ほかの用途は数えない。割れた行の審判（asr-judge）も止まる
- GET /costs: 今月・見込み・今日の用途（止めた用途は使っていなくても出す・上限）・今月の用途ごとの額と回数
- GET /rollout・/checks: 形を確かめ、おかしな行を落とす・無ければ available false
- POST /feedback の kind "check"（right・wrong・unsure だけ）・提案の kind "wish"・通信簿の省ける "check_right"
- 記録（log.txt）に施策の名前・主張の文を書かない
"""

from __future__ import annotations

import datetime
import json
import sys
import tempfile
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import appfeeds  # noqa: E402
import claude  # noqa: E402
import ops  # noqa: E402
import settle  # noqa: E402
from v6checks import KEY, Client, say  # noqa: E402
from v11checks import FakeClaude, put_config, put_key, reset_files  # noqa: E402

SECRET_CLAIM = "見本の秘密の主張"
SECRET_TITLE = "見本の秘密の施策"


def run(main) -> int:
    main.isolate_home()
    saved_factory = claude.CLIENT_FACTORY
    failed = 0
    try:
        failed += check_config()
        failed += check_gate()
        failed += check_costs()
        failed += check_feeds()
        failed += check_feedback_kinds()
        failed += check_http(main)
    finally:
        claude.CLIENT_FACTORY = saved_factory
        reset_files()
    print(("NG の数: " + str(failed)) if failed else "施策の検品表・Claude の費用・正しさの抜き取り（2026-11-15）: 全部 OK", flush=True)
    return failed


def write(base: Path, rel: Path, value) -> None:
    (base / rel).parent.mkdir(parents=True, exist_ok=True)
    text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
    (base / rel).write_text(text, encoding="utf-8-sig")


def ledger_row(purpose: str, usd: float, at: str | None = None, who: str = "mothership") -> None:
    claude.append_ledger({"at": at or claude.now_iso(), "who": who, "purpose": purpose, "model": claude.HAIKU, "usd": usd})


def check_config() -> int:
    failed = 0
    reset_files()
    config = claude.load_config()
    failed += say(config["daily_caps"] == {} and config["stopped"] == [], "設定が無ければ daily_caps {}・stopped []")
    put_config({"monthly_usd": 100, "daily_caps": {"misheard": 0.5, "minutes": 1, "minutes.notes": 0.05, "": 3,
                                                   "bad": -1, "s": "1", "t": True},
                "stopped": ["asr-judge", 5, "", "asr-judge"]})
    config = claude.load_config()
    failed += say(config["daily_caps"] == {"misheard": 0.5, "minutes": 1.0, "minutes.notes": 0.05}
                  and config["stopped"] == ["asr-judge"],
                  f"おかしな上限・用途は落とす（{config['daily_caps']}・{config['stopped']}）")
    caps = config["daily_caps"]
    got = [claude.cap_for("minutes.notes", caps), claude.cap_for("minutes", caps), claude.cap_for("minutesX", caps),
           claude.cap_for("notes", caps)]
    failed += say(got == [("minutes.notes", 0.05), ("minutes", 1.0), ("minutes", 1.0), None],
                  f"前方一致は一番長いもの（{got}）")
    put_config({"daily_caps": [1], "stopped": "asr-judge"})
    config = claude.load_config()
    failed += say(config["daily_caps"] == {} and config["stopped"] == [], "形の違う daily_caps・stopped は既定のまま")
    reset_files()
    return failed


def check_gate() -> int:
    failed = 0
    reset_files()
    put_key()
    fake = FakeClaude()
    claude.CLIENT_FACTORY = fake.factory
    put_config({"stopped": ["asr-judge", "brief-compare"], "daily_caps": {"misheard": 0.10, "mis": 5}})
    try:
        claude.call(None, "見本", purpose="brief-compare")
        failed += say(False, "止めた用途は頼まない")
    except claude.ClaudeError as error:
        failed += say(error.status == claude.PURPOSE_OFF == 409 and error.body.get("purpose_off") == "stopped"
                      and not fake.calls, f"止めた用途は頼まずに 409・purpose_off stopped（{error.status}）")
    yesterday = (datetime.datetime.now().astimezone() - datetime.timedelta(days=1)).isoformat(timespec="seconds")
    ledger_row("misheard", 0.50, at=yesterday)
    ledger_row("misheard", 0.04)
    got = claude.call(None, "見本", purpose="misheard")
    failed += say(bool(got.get("text")) and len(fake.calls) == 1, "きのうの分は数えない（今日の上限の下なら頼む）")
    ledger_row("misheard", 0.06, who="pc")
    try:
        claude.call(None, "見本", purpose="misheard")
        failed += say(False, "今日の上限に届いたら頼まない")
    except claude.ClaudeError as error:
        failed += say(error.status == 409 and error.body.get("purpose_off") == "daily_cap" and len(fake.calls) == 1
                      and "$0.10" in error.body.get("error", ""),
                      f"今日のその用途の合計（母艦・PC の両方）が上限に届いたら 409・daily_cap（{error.body}）")
    got = claude.call(None, "見本", purpose="misheard2")
    failed += say(len(fake.calls) == 2, "ほかの用途（一番長い前方一致が別の上限）は頼む")
    failed += say(claude.judge_gate(False) == "止めた用途", f"審判（asr-judge）を止めたら審判もしない（{claude.judge_gate(False)}）")
    lines = [{"text": "あ", "confidence": 0.2, "votes": {"a": "あ", "b": "い"}}]
    result = claude.judge(lines, work=False)
    failed += say(result["calls"] == 0 and result["skipped"] == "止めた用途" and len(fake.calls) == 2,
                  f"審判: 止めた用途なら Claude に送らない（{result}）")
    put_config({"daily_caps": {"asr-judge": 0.001}})
    ledger_row("asr-judge", 0.002)
    failed += say(claude.judge_gate(False) == "今日の額の上限", f"審判: 今日の額の上限（{claude.judge_gate(False)}）")
    failed += say(claude.available(), "用途の止め・上限は features の claude を消さない（今月の上限の下なら使える）")
    reset_files()
    return failed


def check_costs() -> int:
    failed = 0
    reset_files()
    put_config({"monthly_usd": 100, "stopped": ["asr-judge"], "daily_caps": {"misheard": 0.5, "brief": 1}})
    now = datetime.datetime.now().astimezone()
    ledger_row("misheard", 0.25)
    ledger_row("misheard", 0.05)
    ledger_row("brief-compare", 1.5)
    ledger_row("headline", 0.01, who="pc")
    first = now.replace(day=1, hour=0, minute=0, second=1, microsecond=0)
    if first.date() != now.date():
        ledger_row("headline", 0.5, at=first.isoformat(timespec="seconds"))
    last_month = (now.replace(day=1) - datetime.timedelta(days=2)).isoformat(timespec="seconds")
    ledger_row("weekly", 9.0, at=last_month)
    got = claude.costs_report()
    month_total = 1.81 + (0.5 if first.date() != now.date() else 0.0)
    today = {r["purpose"]: r for r in got.get("today") or []}
    failed += say(got.get("available") is True and got.get("month") == now.strftime("%Y-%m")
                  and abs(got.get("month_usd", 0) - month_total) < 1e-6 and got.get("monthly_usd") == 100.0,
                  f"GET /costs: 今月の合計（先月の分は入れない）（{got.get('month_usd')}）")
    failed += say(set(today) == {"misheard", "brief-compare", "headline", "asr-judge"}
                  and today["misheard"]["cap"] == 0.5 and abs(today["misheard"]["usd"] - 0.30) < 1e-6
                  and today["brief-compare"]["cap"] == 1.0 and today["headline"]["cap"] is None
                  and today["asr-judge"]["stopped"] is True and today["asr-judge"]["usd"] == 0.0
                  and today["misheard"]["stopped"] is False and got["today"][0]["purpose"] == "brief-compare",
                  f"today: 今日の用途と止めた用途・上限・多い順（{got.get('today')}）")
    rows = {r["purpose"]: r for r in got.get("month_by_purpose") or []}
    failed += say(rows.get("misheard", {}).get("calls") == 2 and abs(rows["misheard"]["usd"] - 0.30) < 1e-6
                  and "weekly" not in rows and set(rows["misheard"]) == {"purpose", "usd", "calls"},
                  f"month_by_purpose: 今月の用途ごとの額と回数（{got.get('month_by_purpose')}）")
    failed += say(set(got) == {"available", "month", "month_usd", "projected_usd", "monthly_usd", "today", "month_by_purpose"}
                  and set(got["today"][0]) == {"purpose", "usd", "cap", "stopped"}, "GET /costs の形は約束どおり")
    # 見込み: 11/15 の正午に $14.5 → 14.5 日で割って 30 日
    noon = time.mktime((2026, 11, 15, 12, 0, 0, 0, 0, -1))
    failed += say(abs(claude.projected(14.5, noon) - 30.0) < 1e-6 and abs(claude.projected(1.0, time.mktime((2026, 2, 1, 3, 0, 0, 0, 0, -1))) - 28.0) < 1e-6,
                  f"見込み: 過ぎた日数で割って月の日数を掛ける・1 日目は 1 日として（{claude.projected(14.5, noon)}）")
    reset_files()
    return failed


def check_feeds() -> int:
    failed = 0
    with tempfile.TemporaryDirectory() as folder:
        base = Path(folder)
        failed += say(settle.read_rollout(base).get("available") is False and settle.read_checks(base).get("available") is False,
                      "検品表・抜き取り: 無ければ available false")
        write(base, settle.ROLLOUT, {"items": "x"})
        failed += say("形が違います" in settle.read_rollout(base).get("reason", ""), "検品表: 形が違えば available false")
        items = [
            {"no": 37, "title": "費用" * 30, "first_live": "2026-11-14", "last_live": None, "uses_7d": 3,
             "evidence": "根拠" * 60, "status": "live"},
            {"no": 2, "title": "週のふり返り", "first_live": None, "last_live": None, "uses_7d": None,
             "evidence": "", "status": "not_started"},
            {"no": 2, "title": "二度目", "status": "live"},
            {"no": 3, "title": "状態が変", "status": "dead"},
            {"no": 0, "title": "番号が変", "status": "live"},
            {"no": "4", "title": "番号が文", "status": "live"},
            {"no": 5, "title": "", "status": "live"},
            {"no": 6, "title": "日が変", "first_live": "2026-02-30", "uses_7d": -1, "status": "retire_candidate"},
            "行ではない",
        ]
        write(base, settle.ROLLOUT, {"version": 1, "generated_at": "2026-11-15T07:00:00+09:00", "items": items})
        got = settle.read_rollout(base)
        listed = got.get("items") or []
        failed += say([i["no"] for i in listed] == [2, 6, 37] and len(listed[2]["title"]) == 40
                      and len(listed[2]["evidence"]) == 80 and listed[2]["uses_7d"] == 3 and listed[0]["uses_7d"] is None
                      and listed[1]["first_live"] is None and listed[1]["uses_7d"] is None
                      and got.get("generated_at") == "2026-11-15T07:00:00+09:00",
                      f"検品表: 番号・状態・題の無い行と重なりを落とし、40/80 文字・あり得ない日は null・番号の順（{[i['no'] for i in listed]}）")
        failed += say(set(listed[0]) == {"no", "title", "first_live", "last_live", "uses_7d", "evidence", "status"},
                      "検品表: 行の形は約束どおり")
        checks = [
            {"id": "c-1", "day": "2026-11-13", "source": "digest", "claim": "主張" * 80, "evidence": "根拠" * 80},
            {"id": "c-2", "day": "2026-11-14", "source": "promise", "claim": "約束の主張"},
            {"id": "c-2", "day": "2026-11-14", "source": "promise", "claim": "重なり"},
            {"id": "c 3", "day": "2026-11-14", "source": "digest", "claim": "id が変"},
            {"id": "c-4", "day": "11/14", "source": "digest", "claim": "日が変"},
            {"id": "c-5", "day": "2026-11-14", "source": "line", "claim": "出どころが変"},
            {"id": "c-6", "day": "2026-11-14", "source": "weekly", "claim": ""},
        ] + [{"id": f"m-{i}", "day": "2026-11-01", "source": "weekly", "claim": "多い"} for i in range(10)]
        write(base, settle.CHECKS, {"version": 1, "items": checks})
        got = settle.read_checks(base)
        listed = got.get("items") or []
        failed += say(len(listed) == settle.CHECK_ITEMS == 7 and listed[0]["id"] == "c-2" and listed[1]["id"] == "c-1"
                      and len(listed[1]["claim"]) == 120 and len(listed[1]["evidence"]) == 120 and listed[0]["evidence"] == "",
                      f"抜き取り: おかしな行を落とし、7 つまで・新しい日から・120 文字（{[i['id'] for i in listed]}）")
        # 通信簿の省ける check_right
        write(base, appfeeds.ACCURACY, {"weeks": [{"week": "2026-W46", "check_right": 0.75}, {"week": "2026-W45", "check_right": 2},
                                                  {"week": "2026-W44"}]})
        weeks = appfeeds.read_accuracy(base)["weeks"]
        failed += say([w["check_right"] for w in weeks] == [0.75, None, None], f"通信簿: check_right は 0〜1 だけ（{weeks}）")
        # 提案の wish
        now = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
        write(base, appfeeds.PROPOSALS, {"items": [{"id": "w-1", "kind": "wish", "title": "見本の欲しい物", "created": now,
                                                    "action": {"type": "none"}}]})
        got = appfeeds.read_proposals(base)
        failed += say([i["kind"] for i in got.get("items") or []] == ["wish"], "提案: kind wish を通す")
    return failed


def check_feedback_kinds() -> int:
    failed = 0
    ok = 0
    for value in ("right", "wrong", "unsure"):
        row = appfeeds.parse_feedback(json.dumps({"kind": "check", "id": "c-1", "value": value, "day": "2026-11-15"}).encode())
        ok += row == {"kind": "check", "id": "c-1", "value": value, "day": "2026-11-15"}
    failed += say(ok == 3, "POST /feedback: check の right・wrong・unsure を受ける")
    try:
        appfeeds.parse_feedback(json.dumps({"kind": "check", "id": "c-1", "value": "ok", "day": "2026-11-15"}).encode())
        failed += say(False, "check の value は決めたものだけ")
    except ValueError:
        failed += say(True, "check の value は決めたものだけ")
    return failed


def check_http(main) -> int:
    failed = 0
    reset_files()
    put_key()
    fake = FakeClaude()
    claude.CLIENT_FACTORY = fake.factory
    put_config({"stopped": ["asr-judge", "app-stopped"], "daily_caps": {"app": 50}})
    logged: list[str] = []
    saved = (getattr(main.Handler, "engine", None), getattr(main.Handler, "key", None), main.log)
    old_config = main.load_config()
    with tempfile.TemporaryDirectory() as folder:
        base = Path(folder)
        server = None
        try:
            main.log = logged.append
            main.Handler.key = KEY
            main.Handler.engine = main.Ensemble(ops.fake_engines())
            config = dict(old_config)
            config["lifelog_home"] = folder
            main.save_config(config)
            server = main.Server(("127.0.0.1", 0), main.Handler)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            client = Client(server.server_address[1])

            def post(path: str, body, key=KEY):
                data = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode("utf-8")
                return client.call("POST", path, data, {"Content-Type": "application/json"}, key=key)

            hello = client.call("GET", "/hello")
            names = set(hello[1].get("features", [])) if hello[0] == 200 else set()
            failed += say({"rollout", "checks", "costs", "claude"} <= names, "/hello の features に rollout・checks・costs")
            status, body, _ = client.call("GET", "/rollout")
            failed += say(status == 200 and body.get("available") is False, f"GET /rollout: 無ければ available false（{status}）")
            write(base, settle.ROLLOUT, {"items": [{"no": 36, "title": SECRET_TITLE, "status": "live", "uses_7d": 2}]})
            write(base, settle.CHECKS, {"items": [{"id": "c-1", "day": "2026-11-14", "source": "digest", "claim": SECRET_CLAIM}]})
            rollout = client.call("GET", "/rollout")
            checks = client.call("GET", "/checks")
            failed += say(rollout[0] == 200 and rollout[1]["items"][0]["title"] == SECRET_TITLE
                          and checks[0] == 200 and checks[1]["items"][0]["claim"] == SECRET_CLAIM,
                          "GET /rollout・/checks: 母艦の写しを確かめて返す")
            status, body, _ = post("/claude", {"prompt": "見本", "purpose": "app-stopped", "work": False})
            failed += say(status == 409 and body.get("purpose_off") == "stopped" and not fake.calls,
                          f"POST /claude: 止めた用途は 409（{status}・{body}）")
            status, body, _ = post("/claude", {"prompt": "見本", "purpose": "app", "work": False})
            failed += say(status == 200 and len(fake.calls) == 1, f"POST /claude: ほかの用途は頼む（{status}）")
            status, body, _ = client.call("GET", "/costs")
            today = {r["purpose"]: r for r in body.get("today") or []} if status == 200 else {}
            failed += say(status == 200 and body.get("available") is True and "app" in today and today["app"]["cap"] == 50.0
                          and today.get("app-stopped", {}).get("stopped") is True and body.get("month_usd", 0) > 0,
                          f"GET /costs: 今頼んだ分と止めた用途が出る（{status}）")
            status, body, _ = post("/feedback", {"kind": "check", "id": "c-1", "value": "wrong", "day": "2026-11-14"})
            lines = (base / appfeeds.FEEDBACK_FILE).read_text(encoding="utf-8").splitlines() \
                if (base / appfeeds.FEEDBACK_FILE).exists() else []
            row = json.loads(lines[-1]) if lines else {}
            failed += say(status == 200 and row.get("kind") == "check" and row.get("value") == "wrong" and "at" in row,
                          f"POST /feedback check → 母艦の inbox に1行（{status}）")
            unauth = [client.call("GET", p, key="wrong")[0] for p in ("/rollout", "/checks", "/costs")]
            failed += say(unauth == [401, 401, 401], f"GET の3つ: 合言葉が違えば 401（{unauth}）")
            text = "\n".join(logged)
            failed += say(SECRET_CLAIM not in text and SECRET_TITLE not in text,
                          "記録に施策の名前・主張の文を書かない")
        finally:
            if server is not None:
                server.shutdown()
                server.server_close()
            main.save_config(old_config)
            main.Handler.engine, main.Handler.key, main.log = saved
            reset_files()
    return failed


if __name__ == "__main__":
    import lifelog_pc

    sys.exit(1 if run(lifelog_pc) else 0)
