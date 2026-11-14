"""強化案 53・54・55・61（2026-11-15。中身は pages.py）を確かめる。

    python pc/v15checks_pages.py

本物の鍵・ネット・母艦は使わない（一時のフォルダ）。本物の HOME に書かない（isolate_home）。名前・題はすべて作り物。確かめること:
- GET /people-pages・/threads・/place-pages・/decisions: 無ければ available false・形が違えば available false・
  おかしな行（id・名前・日・種類・数）を落とし、長さを切り、重なりを 1 つに・並べ方
- POST /decisions/answer: 今の写しで id と選択肢を確かめる（無ければ 409）・0 はデフォルト・文は写しから作る
  （アプリの送った文は使わない）・母艦の inbox に 1 行・おかしな中身は 400
- /hello の features に 4 つの名前・合言葉が違えば 401
- 記録（log.txt）に名前・題・選んだものを書かない
"""

from __future__ import annotations

import json
import sys
import tempfile
import threading
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import ops  # noqa: E402
import pages  # noqa: E402
from v6checks import KEY, Client, say  # noqa: E402
from v11checks import reset_files  # noqa: E402

SECRET_NAME = "見本の秘密の人"
SECRET_TITLE = "見本の秘密の決めごと"
SECRET_LABEL = "見本の秘密の選択"


def write(base: Path, rel: Path, value) -> None:
    (base / rel).parent.mkdir(parents=True, exist_ok=True)
    text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
    (base / rel).write_text(text, encoding="utf-8-sig")


def run(main) -> int:
    main.isolate_home()
    failed = 0
    try:
        failed += check_people()
        failed += check_threads()
        failed += check_places()
        failed += check_decisions()
        failed += check_http(main)
    finally:
        reset_files()
    print(("NG の数: " + str(failed)) if failed else "人・話題の糸・場所・決めごとのページ（2026-11-15）: 全部 OK", flush=True)
    return failed


def check_people() -> int:
    failed = 0
    with tempfile.TemporaryDirectory() as folder:
        base = Path(folder)
        failed += say(pages.read_people_pages(base).get("available") is False, "人のページ: 無ければ available false")
        write(base, pages.PEOPLE, {"items": {}})
        failed += say("形が違います" in pages.read_people_pages(base).get("reason", ""), "人のページ: 形が違えば available false")
        good = {"id": "pp-000000000001", "name": "見本 花子" * 5, "group": "仕事", "aliases": ["見本", 5, "", "花子"],
                "last_talk": {"day": "2026-11-14", "summary": "話" * 200, "source": "app"}, "last_line": "2026-11-13",
                "line_7d": 4, "line_30d": 20, "talks_30d": -1,
                "topics": [{"text": "旅行の宿", "day": "2026-11-10"}, {"text": "", "day": "2026-11-10"}, {"text": "日が変", "day": "11/1"}],
                "promises": [{"text": "資料を送る", "by": "me", "day": "2026-11-12", "source": "line"},
                             {"text": "だれ", "by": "who", "source": "line"}, {"text": "出どころ", "by": "them", "source": "x"}],
                "likes": ["甘いもの"] * 9, "next_line": "宿は決まりましたか", "next_why": "旅行の宿をまだ決めていない",
                "upcoming": {"day": "2026-11-20", "time": "18:30", "title": "見本の飲み会"}, "updated": "2026-11-15"}
        rows = [good, dict(good, name="重なり"), {"id": "bad id", "name": "id が変"}, {"id": "pp-2", "name": ""},
                {"id": "pp-3", "name": "最小", "last_talk": {"day": "2026-11-14", "summary": "x", "source": "plaud"},
                 "upcoming": {"day": "2026-11-20", "time": "夜", "title": "見本"}}, "行ではない"]
        write(base, pages.PEOPLE, {"version": 1, "generated_at": "2026-11-15T03:00:00+09:00", "items": rows})
        got = pages.read_people_pages(base)
        items = got.get("items") or []
        a = items[0] if items else {}
        failed += say([i["id"] for i in items] == ["pp-000000000001", "pp-3"] and len(a["name"]) == 20
                      and len(a["last_talk"]["summary"]) == 120 and a["talks_30d"] == 0 and a["aliases"] == ["見本", "花子"],
                      f"人のページ: おかしな行と重なりを落とし、20/120 文字・数は 0 以上（{[i['id'] for i in items]}）")
        failed += say(a.get("topics") == [{"text": "旅行の宿", "day": "2026-11-10"}, {"text": "日が変", "day": None}]
                      and [p["text"] for p in a.get("promises", [])] == ["資料を送る"] and len(a.get("likes", [])) == 6,
                      "人のページ: 話題は文の無いものを落とし日は確かめる・約束は by と出どころが決めたものだけ・好みは 6 つまで")
        b = items[1] if len(items) > 1 else {}
        failed += say(b.get("last_talk") is None and b.get("upcoming") == {"day": "2026-11-20", "time": "", "title": "見本"}
                      and b.get("topics") == [] and b.get("next_line") == "",
                      "人のページ: 出どころの違う最後の話は null・時刻の読めない予定は時刻を空に・無い項目は空")
        failed += say(set(a) == {"id", "name", "group", "aliases", "last_talk", "last_line", "line_7d", "line_30d", "talks_30d",
                                 "topics", "promises", "likes", "next_line", "next_why", "upcoming", "updated"},
                      "人のページ: 行の形は約束どおり")
        write(base, pages.PEOPLE, {"items": [dict(good, id=f"pp-{i}") for i in range(100)]})
        failed += say(len(pages.read_people_pages(base)["items"]) == pages.PEOPLE_LIMIT == 60, "人のページ: 60 人まで")
    return failed


def check_threads() -> int:
    failed = 0
    with tempfile.TemporaryDirectory() as folder:
        base = Path(folder)
        failed += say(pages.read_threads(base).get("available") is False, "話題の糸: 無ければ available false")
        rows = [
            {"id": "th-1", "title": "見本案件", "kind": "work", "status": "open",
             "decided": [{"text": "金曜に出す", "day": "2026-11-12"}], "open": [{"text": "資料" * 80, "day": None}],
             "next": "資料を直す", "days": ["2026-11-10", "2026-11-12", "2026-11-12", "bad"], "last_day": "x", "source": "claude"},
            {"id": "th-2", "title": "見本旅行", "kind": "private", "status": "settled", "decided": [], "open": [],
             "next": "", "days": ["2026-11-14", "2026-11-09"], "source": "???"},
            {"id": "th-3", "title": "種類が変", "kind": "life", "status": "open", "days": ["2026-11-14"]},
            {"id": "th-4", "title": "日が無い", "kind": "work", "status": "open", "days": []},
            {"id": "th-5", "title": "状態が変", "kind": "work", "status": "done", "days": ["2026-11-14"]},
        ]
        write(base, pages.THREADS, {"version": 1, "items": rows})
        items = pages.read_threads(base).get("items") or []
        a = next((i for i in items if i["id"] == "th-1"), {})
        b = next((i for i in items if i["id"] == "th-2"), {})
        failed += say([i["id"] for i in items] == ["th-2", "th-1"], f"話題の糸: おかしな行を落とし、新しい日の順（{[i['id'] for i in items]}）")
        failed += say(a.get("days") == ["2026-11-12", "2026-11-10"] and a.get("last_day") == "2026-11-12"
                      and len(a["open"][0]["text"]) == 100 and a["open"][0]["day"] is None and b.get("source") == "machine",
                      "話題の糸: 日は確かめて重なりを落とし新しい順・最後の日は日から・100 文字・知らない出どころは machine")
    return failed


def check_places() -> int:
    failed = 0
    with tempfile.TemporaryDirectory() as folder:
        base = Path(folder)
        failed += say(pages.read_place_pages(base).get("available") is False, "場所のページ: 無ければ available false")
        rows = [
            {"id": "pl-1", "name": "見本カフェ", "sure": "yes", "visit_days": 2, "visits": 3, "last_day": "2026-11-12",
             "spent": 1280, "with": ["見本 花子"],
             "recent": [{"day": "2026-11-12", "time": "14:28–14:45", "amount": 780, "with": ["見本 花子"], "talk": "話" * 200},
                        {"day": "2026-11-12", "time": "14:28-14:45", "amount": 1}, {"day": "x", "time": "14:28–14:45"}]},
            {"id": "pl-2", "name": "見本の駅前", "sure": True, "visit_days": 1, "visits": 1, "last_day": "2026-11-14",
             "spent": -5, "with": [], "recent": []},
            {"id": "pl-3", "name": "数が変", "visit_days": "1", "visits": 1, "last_day": "2026-11-14"},
        ]
        write(base, pages.PLACES, {"version": 1, "items": rows})
        items = pages.read_place_pages(base).get("items") or []
        a = next((i for i in items if i["id"] == "pl-1"), {})
        b = next((i for i in items if i["id"] == "pl-2"), {})
        failed += say([i["id"] for i in items] == ["pl-2", "pl-1"] and a.get("sure") is False and b.get("sure") is True
                      and b.get("spent") is None and len(a.get("recent", [])) == 1 and len(a["recent"][0]["talk"]) == 100,
                      "場所のページ: 数の変な行を落とす・sure は true だけ・負の額は null・時間の形を確かめる・100 文字・新しい日の順")
    return failed


DECISIONS = [
    {"id": "d-000000000001", "title": SECRET_TITLE, "deadline": "2026-11-17", "default": "やめる",
     "options": [{"n": 1, "label": "やめる", "detail": "何もしない", "is_default": True},
                 {"n": 2, "label": SECRET_LABEL, "detail": "", "is_default": False},
                 {"n": 2, "label": "番号の重なり"}, {"n": 0, "label": "番号が変"}],
     "background": "背" * 400, "opened": "2026-11-10"},
    {"id": "d-000000000002", "title": "期限なし", "deadline": None, "default": "残す", "options": []},
    {"id": "d-000000000003", "title": "選べない", "deadline": "2026-11-16", "default": "", "options": []},
    {"id": "d-000000000004", "title": "早い期限", "deadline": "2026-11-16", "default": "見送る", "options": []},
]


def check_decisions() -> int:
    failed = 0
    with tempfile.TemporaryDirectory() as folder:
        base = Path(folder)
        failed += say(pages.read_decisions(base).get("available") is False, "決めごと: 無ければ available false")
        write(base, pages.DECISIONS, {"version": 1, "items": DECISIONS})
        items = pages.read_decisions(base).get("items") or []
        a = next((i for i in items if i["id"] == "d-000000000001"), {})
        failed += say([i["id"] for i in items] == ["d-000000000004", "d-000000000001", "d-000000000002"]
                      and [o["n"] for o in a.get("options", [])] == [1, 2] and len(a.get("background", "")) == 300,
                      f"決めごと: 選べないものを落とし、期限の近い順（期限なしは最後）・番号の重なりと 0 を落とす（{[i['id'] for i in items]}）")

        def parse(body) -> dict | str:
            try:
                return pages.parse_decision_answer(json.dumps(body, ensure_ascii=False).encode("utf-8"), base)
            except pages.Conflict:
                return "409"
            except ValueError:
                return "400"

        got = parse({"id": "d-000000000001", "choice": 2, "day": "2026-11-15", "label": "アプリの勝手な文"})
        failed += say(isinstance(got, dict) and got["label"] == SECRET_LABEL and got["title"] == SECRET_TITLE and got["choice"] == 2,
                      "POST /decisions/answer: 選んだものの文は写しから作る（アプリの送った文は使わない）")
        got = parse({"id": "d-000000000002", "choice": 0, "day": "2026-11-15"})
        failed += say(isinstance(got, dict) and got["label"] == "残す", "POST /decisions/answer: 0 はデフォルト")
        bad = [parse({"id": "d-000000000001", "choice": 9, "day": "2026-11-15"}), parse({"id": "d-x", "choice": 1, "day": "2026-11-15"}),
               parse({"id": "d-000000000001", "choice": 1, "day": "11/15"}), parse({"id": "d-000000000001", "choice": True, "day": "2026-11-15"}),
               parse({"id": "d 1", "choice": 1, "day": "2026-11-15"}), parse({"id": "d-000000000001", "choice": 99, "day": "2026-11-15"})]
        failed += say(bad == ["409", "409", "400", "400", "400", "400"],
                      f"POST /decisions/answer: 写しに無い選択肢・id は 409、形の違う中身は 400（{bad}）")
    return failed


def check_http(main) -> int:
    failed = 0
    reset_files()
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
            failed += say({"peoplepages", "threads", "placepages", "decisions"} <= names,
                          "/hello の features に peoplepages・threads・placepages・decisions")
            gets = [client.call("GET", p) for p in ("/people-pages", "/threads", "/place-pages", "/decisions")]
            failed += say(all(g[0] == 200 and g[1].get("available") is False for g in gets), "GET の 4 つ: 無ければ available false")
            write(base, pages.PEOPLE, {"items": [{"id": "pp-1", "name": SECRET_NAME}]})
            write(base, pages.DECISIONS, {"items": DECISIONS})
            people = client.call("GET", "/people-pages")
            failed += say(people[0] == 200 and people[1]["items"][0]["name"] == SECRET_NAME, "GET /people-pages: 母艦の写しを確かめて返す")
            status, body, _ = post("/decisions/answer", {"id": "d-000000000001", "choice": 2, "day": "2026-11-15"})
            lines = (base / pages.ANSWERS).read_text(encoding="utf-8").splitlines() if (base / pages.ANSWERS).exists() else []
            row = json.loads(lines[-1]) if lines else {}
            failed += say(status == 200 and body.get("label") == SECRET_LABEL and row.get("label") == SECRET_LABEL
                          and row.get("title") == SECRET_TITLE and row.get("choice") == 2 and "at" in row and len(lines) == 1,
                          f"POST /decisions/answer → 母艦の inbox に 1 行（{status}）")
            status, _, _ = post("/decisions/answer", {"id": "d-000000000009", "choice": 1, "day": "2026-11-15"})
            status2, _, _ = post("/decisions/answer", b"not json")
            failed += say(status == 409 and status2 == 400, f"POST /decisions/answer: 写しに無ければ 409・JSON でなければ 400（{status}・{status2}）")
            unauth = [client.call("GET", p, key="wrong")[0] for p in ("/people-pages", "/threads", "/place-pages", "/decisions")]
            unauth.append(post("/decisions/answer", {"id": "d-000000000001", "choice": 1, "day": "2026-11-15"}, key="wrong")[0])
            failed += say(unauth == [401] * 5, f"合言葉が違えば 401（{unauth}）")
            text = "\n".join(logged)
            failed += say(SECRET_NAME not in text and SECRET_TITLE not in text and SECRET_LABEL not in text,
                          "記録に名前・題・選んだものを書かない")
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
