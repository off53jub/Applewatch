"""2026-11-13 の施策（1〜21 のアプリ側の口）を確かめる（--check-v11 の中から呼ぶ。本物の母艦は使わない）。

- GET /weekly・/prep・/brief-compare・/accuracy・/unused: 無いとき・形が違うときは available false、おかしな行は落とし、
  長さ・数を切る（値の無い所は null）
- POST /feedback・/mood・/app-usage: 決めた組だけ受け、母艦の inbox の jsonl に1行足す。おかしな中身は 400、合言葉が違えば 401
- /hello の features に weekly・prep・briefcmp・accuracy・unused・feedback・mood・appusage
- 記録（log.txt）に、アプリの名前・気分の値・覚え書き・id を書かない
母艦はいつも一時のフォルダ（config.json の "lifelog_home" をそこに向ける）。
"""

from __future__ import annotations

import json
import tempfile
import threading
from pathlib import Path

import appfeeds
import mothership
import ops
from v6checks import KEY, Client, say


def run(main) -> int:
    failed = 0
    failed += check_readers()
    failed += check_parsers()
    failed += check_http(main)
    print(("NG の数: " + str(failed)) if failed else "施策の口（2026-11-13）: 全部 OK", flush=True)
    return failed


def write(base: Path, rel: Path, value) -> None:
    (base / rel).parent.mkdir(parents=True, exist_ok=True)
    text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
    (base / rel).write_text(text, encoding="utf-8-sig")


NEW_GETS = ("/weekly", "/prep", "/brief-compare", "/accuracy", "/unused")
NEW_POSTS = ("/feedback", "/mood", "/app-usage")


def check_readers() -> int:
    failed = 0
    with tempfile.TemporaryDirectory() as folder:
        base = Path(folder)
        failed += say(all(appfeeds.READERS[p](base).get("available") is False for p in NEW_GETS),
                      "新しい写し5つ: 無ければ available false")
        failed += say(all(p in mothership.GETS for p in NEW_GETS) and all(p in mothership.POSTS for p in NEW_POSTS),
                      "GETS・POSTS に入っている")
        for rel in (appfeeds.WEEKLY, appfeeds.PREP, appfeeds.BRIEF_COMPARE, appfeeds.ACCURACY, appfeeds.UNUSED):
            write(base, rel, "[1, 2]")
        failed += say(all(appfeeds.READERS[p](base).get("available") is False for p in NEW_GETS),
                      "新しい写し5つ: 形が違えば available false")
        for rel in (appfeeds.WEEKLY, appfeeds.PREP, appfeeds.BRIEF_COMPARE, appfeeds.ACCURACY, appfeeds.UNUSED):
            write(base, rel, "{壊れた")
        failed += say(all("読めませんでした" in appfeeds.READERS[p](base).get("reason", "") for p in NEW_GETS),
                      "新しい写し5つ: 読めなければ理由つきで available false")

        # 週のふり返り・見立ての台帳
        item = {"id": "w-1", "kind": "theme", "title": "題" * 50, "body": "本文" * 200,
                "evidence": [{"day": "2026-11-10", "source": "conversation", "quote": "引用" * 50},
                             {"day": "きのう", "source": "line", "quote": "日が変"},
                             {"day": "2026-11-11", "source": "line", "quote": ""}]
                + [{"day": "2026-11-12", "source": "x", "quote": "q"}] * 10}
        weekly = {"version": 1, "generated_at": "2026-11-16T21:00:00+09:00", "week": "2026-W46", "from": "2026-11-09",
                  "to": "2026-11-15",
                  "items": [item, dict(item, id="w-1"), dict(item, id="w-2", kind="other"), dict(item, id="w 3"),
                            dict(item, id="w-4", title=""), dict(item, id="w-5", kind="stuck"),
                            dict(item, id="w-6", kind="change"), dict(item, id="w-7"), dict(item, id="w-8"),
                            dict(item, id="w-9"), "文", 3],
                  "hypotheses": [{"id": "h-1", "text": "見立て" * 50, "said_on": "2026-10-01", "status": "alive",
                                  "note": "n" * 300, "checked_on": "2026-11-15"},
                                 {"id": "h-2", "text": "x", "said_on": "2026-02-30", "status": "weakened", "note": ""},
                                 {"id": "h-3", "text": "x", "said_on": "2026-10-01", "status": "maybe"},
                                 {"id": "h-1", "text": "同じ id", "said_on": "2026-10-01", "status": "unknown"}]
                  + [{"id": f"h-x{i}", "text": "t", "status": "confirmed"} for i in range(40)],
                  "feedback": {"today_three": {"done": 3, "skipped": -1, "unknown": True},
                               "proposal": {"accept": 2, "later": "1"}, "brief_read": 4}}
        write(base, appfeeds.WEEKLY, weekly)
        got = appfeeds.read_weekly(base)
        items = got.get("items") or []
        first = items[0] if items else {}
        hyps = got.get("hypotheses") or []
        failed += say(got.get("available") is True and [i["id"] for i in items] == ["w-1", "w-5", "w-6", "w-7", "w-8"]
                      and len(first.get("title", "")) == 40 and len(first.get("body", "")) == 300
                      and len(first.get("evidence", [])) == 5 and len(first["evidence"][0]["quote"]) == 80
                      and got.get("week") == "2026-W46" and got.get("from") == "2026-11-09",
                      f"週のふり返り: おかしな行・同じ id を落とし、5 つ・40/300/80 文字まで（{[i['id'] for i in items]}）")
        failed += say(len(hyps) == 30 and hyps[0]["id"] == "h-1" and len(hyps[0]["text"]) == 120
                      and len(hyps[0]["note"]) == 200 and hyps[1]["said_on"] is None and hyps[1]["checked_on"] is None
                      and all(h["status"] in appfeeds.HYPOTHESIS_STATUS for h in hyps),
                      f"見立ての台帳: 知らない状態・同じ id を落とし、30 個まで・無い日は null（{len(hyps)}）")
        failed += say(got.get("feedback") == {"today_three": {"done": 3, "skipped": 0, "unknown": 0},
                                              "proposal": {"accept": 2, "later": 0, "never": 0}, "brief_read": 4},
                      f"使われ方の数: 数でないものは 0（{got.get('feedback')}）")
        write(base, appfeeds.WEEKLY, {"items": []})
        got = appfeeds.read_weekly(base)
        failed += say(got.get("available") is True and got.get("feedback") is None and got.get("week") is None
                      and got.get("hypotheses") == [], "週のふり返り: 中身が無くても available true（数は null）")

        # 会う前の一枚
        prep_item = {"id": "e-1", "start": "2026-11-14T10:00:00+09:00", "end": "2026-11-14T11:00:00+09:00",
                     "title": "見本の打ち合わせ" * 10, "people": ["見本 太郎" * 5, "", 3, "見本 花子"] + ["人"] * 10,
                     "last_talk": {"day": "2026-11-01", "summary": "前回" * 200},
                     "promises": ["約束" * 50], "recent": ["近況"]}
        prep = {"version": 1, "items": [dict(prep_item, id="e-2", start="2026-11-14T09:00:00+09:00", end=None,
                                             last_talk={"day": "x", "summary": "日が変"}),
                                        prep_item, dict(prep_item, id="e-1"),
                                        dict(prep_item, id="e-3", start="あした"),
                                        dict(prep_item, id="e-4", end="2026-11-14T08:00:00+09:00"),
                                        dict(prep_item, id="e-5", title=""), dict(prep_item, id="e-6", end="のち"),
                                        dict(prep_item, id="e-7", start="2026-13-40T10:00:00+09:00")]
                + [dict(prep_item, id=f"e-x{i}", start=f"2026-11-15T{i:02d}:00:00+09:00", end=None) for i in range(12)]}
        write(base, appfeeds.PREP, prep)
        got = appfeeds.read_prep(base)
        items = got.get("items") or []
        e1 = next((i for i in items if i["id"] == "e-1"), {})
        e2 = next((i for i in items if i["id"] == "e-2"), {})
        failed += say(got.get("available") is True and len(items) == 10 and [i["id"] for i in items[:2]] == ["e-2", "e-1"]
                      and len(e1.get("title", "")) == 60 and e1.get("people", [None])[0] == ("見本 太郎" * 5)[:20]
                      and len(e1.get("people", [])) == 5 and len(e1.get("last_talk", {}).get("summary", "")) == 200
                      and len(e1.get("promises", [""])[0]) == 80 and e2.get("last_talk") is None and e2.get("end") is None
                      and not any(i["id"] in ("e-3", "e-4", "e-5", "e-6", "e-7") for i in items),
                      f"会う前の一枚: 始まりの順・10 件・おかしな時刻と題を落とす（{[i['id'] for i in items[:3]]}）")

        # 朝のまとめの比べ
        long_text = "一行目\r\n二行目\n" + "長" * 30000
        compare = {"days": [{"day": "2026-11-12", "codex": "コーデックス\n二行", "claude": "クロード"},
                            {"day": "2026-11-13", "codex": long_text, "claude": "c"},
                            {"day": "2026-11-12", "codex": "同じ日", "claude": "同じ日"},
                            {"day": "2026-11-11", "codex": "片方だけ", "claude": ""},
                            {"day": "11/10", "codex": "a", "claude": "b"}]
                + [{"day": f"2026-10-{d:02d}", "codex": "a", "claude": "b"} for d in range(1, 12)]}
        write(base, appfeeds.BRIEF_COMPARE, compare)
        got = appfeeds.read_brief_compare(base)
        days = got.get("days") or []
        failed += say(got.get("available") is True and len(days) == 7 and days[0]["day"] == "2026-11-13"
                      and len(days[0]["codex"]) == 20000 and days[0]["codex"].startswith("一行目\n二行目")
                      and days[1]["codex"] == "コーデックス\n二行"
                      and not any(d["day"] == "2026-11-11" for d in days),
                      "朝のまとめの比べ: 改行を残し 2 万文字まで・片方だけの日と同じ日を落とし、新しい順に 7 日")

        # 精度の通信簿
        week = {"week": "2026-W46", "from": "2026-11-09", "to": "2026-11-15", "caught_self": 0.7, "caught_other": 1.5,
                "person_n_kinds_median": 80, "fix_kept_ratio": None, "judge_agree": "0.5", "night_review_kept": True,
                "speaking_score": 61.5}
        accuracy = {"weeks": [week, dict(week, week="2026-W45", person_n_kinds_median=2.5), dict(week, week="46"),
                              dict(week)] + [dict(week, week=f"2025-W{i:02d}") for i in range(10, 30)]}
        write(base, appfeeds.ACCURACY, accuracy)
        got = appfeeds.read_accuracy(base)
        weeks = got.get("weeks") or []
        w = weeks[0] if weeks else {}
        failed += say(got.get("available") is True and len(weeks) == 12 and w.get("week") == "2026-W46"
                      and w.get("caught_self") == 0.7 and w.get("caught_other") is None
                      and w.get("person_n_kinds_median") == 80 and w.get("fix_kept_ratio") is None
                      and w.get("judge_agree") is None and w.get("night_review_kept") is None
                      and w.get("speaking_score") == 61.5 and weeks[1].get("person_n_kinds_median") is None,
                      f"精度の通信簿: 範囲の外・型の違う値は null・同じ週は1つ・新しい順に 12 週（{len(weeks)}）")

        # 開かれていない画面
        unused = {"month": "2026-11", "items": [{"screen": "goodThings", "opens": 0, "days": 30, "note": "n" * 100},
                                                {"screen": "goodThings", "opens": 1, "days": 30},
                                                {"screen": "", "opens": 0, "days": 30},
                                                {"screen": "money", "opens": -1, "days": 30},
                                                {"screen": "ask", "opens": 2, "days": True}]
                  + [{"screen": f"s{i}", "opens": 0, "days": 30} for i in range(60)]}
        write(base, appfeeds.UNUSED, unused)
        got = appfeeds.read_unused(base)
        items = got.get("items") or []
        failed += say(got.get("available") is True and got.get("month") == "2026-11" and len(items) == 40
                      and items[0] == {"screen": "goodThings", "opens": 0, "days": 30, "note": "n" * 80}
                      and not any(i["screen"] in ("money", "ask") for i in items),
                      "開かれていない画面: おかしな数・同じ画面を落とし、40 件・80 文字まで")
    return failed


def check_parsers() -> int:
    failed = 0
    good_feedback = [("today_three", "done"), ("today_three", "skipped"), ("brief", "read"), ("weekly", "useful"),
                     ("weekly", "not_useful"), ("prep", "useful"), ("brief_compare", "codex"),
                     ("brief_compare", "claude"), ("night_review", "kept"), ("same_person", "different"),
                     ("promise", "ignored"), ("bulk", "ok")]
    ok = 0
    for kind, value in good_feedback:
        row = appfeeds.parse_feedback(json.dumps({"kind": kind, "id": "x-1", "value": value, "day": "2026-11-13"}).encode())
        ok += row == {"kind": kind, "id": "x-1", "value": value, "day": "2026-11-13"}
    failed += say(ok == len(good_feedback), f"POST /feedback: 決めた組は受ける（{ok}/{len(good_feedback)}）")
    bad_feedback = [b"x", b"[]", {"kind": "brief", "id": "x", "value": "done", "day": "2026-11-13"},
                    {"kind": "today_three", "id": "x", "value": "read", "day": "2026-11-13"},
                    {"kind": "unknown", "id": "x", "value": "ok", "day": "2026-11-13"},
                    {"kind": "bulk", "id": "bad id!", "value": "ok", "day": "2026-11-13"},
                    {"kind": "bulk", "id": "x" * 65, "value": "ok", "day": "2026-11-13"},
                    {"kind": "bulk", "id": 3, "value": "ok", "day": "2026-11-13"},
                    {"kind": "bulk", "id": "x", "value": "ok", "day": "2026-02-30"},
                    {"kind": "bulk", "id": "x", "value": "ok"}, {"kind": ["bulk"], "id": "x", "value": "ok", "day": "2026-11-13"}]
    failed += say(rejected(appfeeds.parse_feedback, bad_feedback) == len(bad_feedback),
                  f"POST /feedback: おかしな組・id・日は受けない（{rejected(appfeeds.parse_feedback, bad_feedback)}/{len(bad_feedback)}）")
    mood = {"day": "2026-11-13", "at": "2026-11-13T21:40:00+09:00", "mood": 4, "energy": 2, "grip": 5}
    row = appfeeds.parse_mood(json.dumps(dict(mood, note="  よく  眠れた  ")).encode())
    plain = appfeeds.parse_mood(json.dumps(dict(mood, note="   ")).encode())
    failed += say(row == dict(mood, note="よく 眠れた") and plain == mood and "note" not in plain,
                  "POST /mood: 1〜5 の 3 つと覚え書き（空なら付けない）")
    bad_mood = [b"{}", dict(mood, mood=0), dict(mood, energy=6), dict(mood, grip=True), dict(mood, grip=3.0),
                dict(mood, mood="4"), dict(mood, day="11/13"), dict(mood, at="夜"), dict(mood, note="n" * 201),
                dict(mood, note=5), {k: v for k, v in mood.items() if k != "energy"}]
    failed += say(rejected(appfeeds.parse_mood, bad_mood) == len(bad_mood),
                  f"POST /mood: 範囲の外・型の違い・長すぎる覚え書きは受けない（{rejected(appfeeds.parse_mood, bad_mood)}/{len(bad_mood)}）")
    usage = {"at": "2026-11-13T21:40:00+09:00", "app": "  見本アプリ ", "event": "open"}
    row = appfeeds.parse_app_usage(json.dumps(usage).encode())
    events = [appfeeds.parse_app_usage(json.dumps(dict(usage, event=e)).encode())["event"] for e in appfeeds.APP_EVENTS]
    failed += say(row == {"at": usage["at"], "app": "見本アプリ", "event": "open"} and events == list(appfeeds.APP_EVENTS),
                  "POST /app-usage: 4 つの出来事を受け、名前の前後の空白を除く")
    bad_usage = [b"[]", dict(usage, app=""), dict(usage, app="   "), dict(usage, app="a" * 41), dict(usage, app=7),
                 dict(usage, event="launch"), dict(usage, at="2026-11-13"), {"app": "x", "event": "open"}]
    failed += say(rejected(appfeeds.parse_app_usage, bad_usage) == len(bad_usage),
                  f"POST /app-usage: おかしな中身は受けない（{rejected(appfeeds.parse_app_usage, bad_usage)}/{len(bad_usage)}）")
    return failed


def rejected(parse, bodies) -> int:
    n = 0
    for body in bodies:
        data = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode("utf-8")
        try:
            parse(data)
        except ValueError:
            n += 1
    return n


def check_http(main) -> int:
    failed = 0
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
            failed += say(hello[0] == 200 and all(f in hello[1].get("features", []) for f in appfeeds.FEATURES),
                          "/hello の features に weekly・prep・briefcmp・accuracy・unused・feedback・mood・appusage")
            missing = [client.call("GET", p)[1].get("available") for p in NEW_GETS]
            failed += say(missing == [False] * 5, f"GET の5つ: 母艦に無ければ available false（{missing}）")
            write(base, appfeeds.ACCURACY, {"weeks": [{"week": "2026-W46", "caught_self": 0.5}]})
            status, body, _ = client.call("GET", "/accuracy")
            failed += say(status == 200 and body.get("available") is True and body["weeks"][0]["caught_other"] is None,
                          "GET /accuracy: 母艦の写しを確かめて返す")
            unauth = [client.call("GET", p, key="wrong")[0] for p in NEW_GETS]
            failed += say(unauth == [401] * 5, f"GET の5つ: 合言葉が違えば 401（{unauth}）")

            status, body, _ = post("/feedback", {"kind": "today_three", "id": "t-1", "value": "done", "day": "2026-11-13"})
            post("/feedback", {"kind": "brief", "id": "brief-2026-11-13", "value": "read", "day": "2026-11-13"})
            lines = [json.loads(x) for x in (base / appfeeds.FEEDBACK_FILE).read_text(encoding="utf-8").splitlines()]
            failed += say(status == 200 and body == {"ok": True} and len(lines) == 2
                          and set(lines[0]) == {"kind", "id", "value", "day", "at"} and lines[0]["value"] == "done"
                          and appfeeds._iso(lines[0]["at"]) is not None,
                          "POST /feedback → 母艦の inbox/app_feedback.jsonl に1行ずつ（at は PC が付ける）")
            status, body, _ = post("/mood", {"day": "2026-11-13", "at": "2026-11-13T21:40:00+09:00", "mood": 3,
                                             "energy": 1, "grip": 4, "note": "ひみつの覚え書き"})
            line = json.loads((base / appfeeds.MOOD_FILE).read_text(encoding="utf-8").strip())
            failed += say(status == 200 and line == {"day": "2026-11-13", "at": "2026-11-13T21:40:00+09:00", "mood": 3,
                                                     "energy": 1, "grip": 4, "note": "ひみつの覚え書き"},
                          "POST /mood → 母艦の inbox/mood.jsonl に1行")
            status, body, _ = post("/app-usage", {"at": "2026-11-13T21:41:00+09:00", "app": "ひみつのアプリ", "event": "open"})
            line = json.loads((base / appfeeds.APP_USAGE_FILE).read_text(encoding="utf-8").strip())
            failed += say(status == 200 and line == {"at": "2026-11-13T21:41:00+09:00", "app": "ひみつのアプリ",
                                                     "event": "open"},
                          "POST /app-usage → 母艦の inbox/app_usage.jsonl に1行")
            bad = [post("/feedback", {"kind": "brief", "id": "x", "value": "done", "day": "2026-11-13"})[0],
                   post("/mood", {"day": "2026-11-13", "at": "2026-11-13T21:40:00+09:00", "mood": 9, "energy": 1,
                                  "grip": 1})[0],
                   post("/app-usage", {"at": "x", "app": "a", "event": "open"})[0], post("/feedback", b"x")[0]]
            failed += say(bad == [400] * 4, f"POST の3つ: おかしな中身は 400（{bad}）")
            big = post("/mood", b"{" + b" " * (mothership.BODY_LIMIT + 10) + b"}")[0]
            failed += say(big == 413, f"POST /mood: 大きすぎる中身は 413（{big}）")
            wrong = [post(p, {"kind": "bulk", "id": "x", "value": "ok", "day": "2026-11-13"}, key="wrong")[0]
                     for p in NEW_POSTS]
            failed += say(wrong == [401] * 3, f"POST の3つ: 合言葉が違えば 401（{wrong}）")
            counts = [len((base / f).read_text(encoding="utf-8").splitlines())
                      for f in (appfeeds.FEEDBACK_FILE, appfeeds.MOOD_FILE, appfeeds.APP_USAGE_FILE)]
            failed += say(counts == [2, 1, 1], f"断ったものは inbox に足さない（{counts}）")
            text = "\n".join(logged)
            failed += say("ひみつ" not in text and "t-1" not in text and "brief-2026" not in text
                          and "使われ方の記録を母艦へ" in text and "夜の 10 秒を母艦へ" in text,
                          "記録には、アプリの名前・覚え書き・id を書かない（種類だけ）")
        finally:
            if server is not None:
                server.shutdown()
                server.server_close()
            main.save_config(old_config)
            main.Handler.engine, main.Handler.key, main.log = saved
    return failed
