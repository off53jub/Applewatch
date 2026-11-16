"""2026-11-16（強化案 85・99・100・128・129・130・131・132。docs/s16-pc-place-search-2026-11-16.md）: 地名・探す・聞き取りの直しを確かめる。

    python pc/v20checks_place.py

本物の母艦・GPU・Claude・iPhone は使わない（一時フォルダに作り物の母艦と PC の記録を作る）。例に使う名前は全部作り物。確かめること:
- placehints: 台帳（places-index.json があればそれ・無ければ places_for_app.json）・年表の位置・予定の場所を読み、自宅・職場のような
  一般の呼び名は入れない。ファイルが無ければ空（今のまま）。地名の辞書（gazetteer）が無くても動く
- hintpolicy: kotoba にはヒントを渡さない・whisper のヒントは設定どおり・地名を足すのは設定でオンのときだけ（既定はオフ）
- placefix: 読み（かな）が近い地名を「直す候補」にする（勝手に直さない。すでに書けている・遠い語は出さない）。夜の読み直しの流れに乗る
- mothersearch: 年表（位置・予定・決済・写真だけ・座標は消す・会話は読まない）・予定・写真の読み取り・場所のノート・台帳を置ける
- motherquery / MCP: 場所で引く・その時どこにいたか・1日の年表（会話は出さない）・約束・人と場所のページ。--exclude-work では人と場所のページを出さない
- askmother: lookups の読み方と引き方・答えの出どころに音声の所を付ける（残っていなければ「もう無い」）
- selective: 迷った区間の決まり・Ensemble が設定 "doubt" のときだけ迷った区間にだけ Whisper をかける（既定は全部）
"""

from __future__ import annotations

import json
import sys
import tempfile
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

from v6checks import say  # noqa: E402

DAY = "2026-11-10"


def make_mother(base: Path) -> None:
    (base / "state").mkdir(parents=True)
    (base / "digests" / "timeline").mkdir(parents=True)
    (base / "archive" / "calendar" / "2026" / "11").mkdir(parents=True)
    (base / "archive" / "photos" / "notes" / "2026" / "11").mkdir(parents=True)
    (base / "places").mkdir()
    (base / "people").mkdir()
    (base / "state" / "places_for_app.json").write_text(json.dumps({"version": 1, "items": [
        {"id": "a", "name": "さくら町駅", "sure": True, "visit_days": 4, "visits": 6, "last_day": "2026-11-09"},
        {"id": "b", "name": "自宅", "sure": True, "visit_days": 9, "last_day": "2026-11-10"},
        {"id": "c", "name": "つばめ図書館", "sure": False, "visit_days": 1, "last_day": "2026-11-03"}]}), encoding="utf-8")
    rows = [
        {"time": "09:00", "end": "10:30", "lane": "位置", "text": "滞在（1時間30分）", "amount": None, "place": "たぶんつばめ図書館"},
        {"time": "11:00", "end": "11:40", "lane": "位置", "text": "滞在（40分）", "amount": None, "place": "ひばり商店街付近"},
        {"time": "12:00", "end": "13:00", "lane": "位置", "text": "滞在（1時間）", "amount": None, "place": "自宅"},
        {"time": "10:15", "end": None, "lane": "決済", "text": "480円 あおぞらパン（35.67345, 139.70001）", "amount": 480,
         "place": "あおぞらパン"},
        {"time": "14:00", "end": "15:00", "lane": "予定", "text": "打ち合わせ", "amount": None, "place": None},
        {"time": "16:00", "end": None, "lane": "写真", "text": "見たもの 写真2枚", "amount": None, "place": None},
        {"time": "09:30", "end": "09:50", "lane": "会話", "text": "会話の題（秘密の話題）", "amount": None, "place": None},
        {"time": "00:00", "end": None, "lane": "天気", "text": "晴れ 11度", "amount": None, "place": None}]
    (base / "digests" / "timeline" / f"{DAY}.json").write_text(json.dumps({"version": 1, "day": DAY, "rows": rows},
                                                                          ensure_ascii=False), encoding="utf-8")
    (base / "archive" / "calendar" / "2026" / "11" / "10.md").write_text(
        "# Calendar 2026-11-10\n\n## 時間指定\n\n- 14:00 - 15:00  打ち合わせ\n  - 場所: ほしぞら会館（東京都どこか区1-2-3）\n"
        "  - source: メール\n", encoding="utf-8")
    (base / "archive" / "photos" / "notes" / "2026" / "11" / "10.md").write_text(
        "# 写真の読み取り 2026-11-10\n\n- 16:00 レシート: あおぞらパン 合計480円 食パンとジャム\n", encoding="utf-8")
    (base / "places" / "つばめ図書館.md").write_text("# つばめ図書館\n\n## 立ち寄り\n\n- 2026-11-10 09:00 本を返した\n", encoding="utf-8")
    (base / "people" / "テスト太郎.md").write_text("# テスト太郎\n\n## いまの様子\n\n最近は忙しそう\n", encoding="utf-8")
    (base / "state" / "TODO.md").write_text("# TODO\n\n## Open\n- [ ] ヒバリ商店で灯油を買う\n- [ ] テスト太郎へお礼を送る\n"
                                           "- [x] 終わったこと\n\n## Done\n- [ ] 見ない行\n", encoding="utf-8")


def check_placehints(base: Path) -> int:
    import placehints

    failed = 0
    placehints.clear_cache()
    failed += say(placehints.clean_name("たぶんつばめ図書館") == "つばめ図書館" and placehints.clean_name("ひばり商店街付近") == "ひばり商店街"
                  and placehints.clean_name("さくら町駅近く") == "さくら町駅" and placehints.clean_name("自宅") == ""
                  and placehints.clean_name("あ") == "", "名前の整え（たぶん・付近を外す・自宅や短すぎは入れない）")
    places = placehints.load_places(base)
    failed += say({p["name"] for p in places} == {"さくら町駅", "つばめ図書館"},
                  f"台帳（places_for_app.json）の読み。自宅は入れない（{[p['name'] for p in places]}）")
    (base / "state" / "places-index.json").write_text(json.dumps({"places": [
        {"name": "あおぞらパン", "aliases": ["青空パン"], "reading": "あおぞらぱん", "kind": "店", "visits": 3, "last_day": "2026-11-10"}]},
        ensure_ascii=False), encoding="utf-8")
    placehints.clear_cache()
    names = [p["name"] for p in placehints.load_places(base)]
    failed += say(names == ["あおぞらパン"], f"places-index.json があれば、そちらを読む（{names}）")
    (base / "state" / "places-index.json").unlink()
    placehints.clear_cache()
    when = time.mktime(time.strptime(f"{DAY} 09:20:00", "%Y-%m-%d %H:%M:%S"))
    words = placehints.words_at(base, when)
    failed += say(words[:1] == ["つばめ図書館"] and "ほしぞら会館" in words and "さくら町駅" in words,
                  f"その時間にいた所 → 予定の場所 → よく行く所の順（{words}）")
    failed += say(len(placehints.words_at(base, when, limit=2)) == 2 and "自宅" not in words, "数の上限・自宅は入れない")
    empty = Path(tempfile.mkdtemp())
    placehints.clear_cache()
    failed += say(placehints.words_at(empty, when) == [] and placehints.known_names(empty, DAY) == []
                  and placehints.gazetteer_names() == [], "母艦に何も無ければ空（今のまま動く）・辞書が無くても動く")
    known = placehints.known_names(base, DAY)
    failed += say({k["origin"] for k in known} >= {"stay", "calendar", "ledger"}, f"聞き間違い用の名前の出どころ（{sorted({k['origin'] for k in known})}）")
    return failed


def check_hintpolicy(base: Path) -> int:
    import hintpolicy

    failed = 0
    hints = [f"語{i}" for i in range(50)]
    failed += say(hintpolicy.engine_hints("kotoba", hints, {"whisper_hints": "current"}) == [], "kotoba にはヒントを渡さない")
    failed += say(len(hintpolicy.engine_hints("whisper", hints, {})) == 40
                  and hintpolicy.WHISPER_HINTS_DEFAULT in hintpolicy.WHISPER_HINT_MODES, "既定の渡し方は決まっている")
    failed += say(hintpolicy.engine_hints("whisper", hints, {"whisper_hints": "none"}) == []
                  and hintpolicy.engine_hints("whisper", hints, {"whisper_hints": "top10"}) == hints[:10]
                  and len(hintpolicy.engine_hints("whisper", hints, {"whisper_hints": "おかしい"})) == len(
                      hintpolicy.engine_hints("whisper", hints, {})), "none・top10・おかしな値は既定")
    when = time.mktime(time.strptime(f"{DAY} 09:20:00", "%Y-%m-%d %H:%M:%S"))
    import placehints

    placehints.clear_cache()
    same, n0 = hintpolicy.augment(["語1"], when, base, None, {})
    failed += say(same == ["語1"] and n0 == 0, "地名を足すのは設定でオンのときだけ（既定はオフ）")
    more, n1 = hintpolicy.augment(["語1", "つばめ図書館"], when, base, None, {"place_hints": True})
    failed += say(more[0] == "つばめ図書館" or more[0] in ("ほしぞら会館", "さくら町駅"), f"オンなら先頭に足す（{more[:3]}）")
    failed += say(more.count("つばめ図書館") == 1 and n1 >= 1, "同じ語は 2 回入れない")
    none, n2 = hintpolicy.augment(["語1"], when, Path(tempfile.mkdtemp()), None, {"place_hints": True})
    failed += say(none == ["語1"] and n2 == 0, "地名が無ければ前のまま")
    failed += say(hintpolicy.epoch_of("20261110-092000-w.m4a") == when - 0 + 0 or abs(hintpolicy.epoch_of("20261110-092000-w.m4a") - when) < 1,
                  "区切りの名前の頭から時刻")
    return failed


def check_placefix(base: Path, home: Path) -> int:
    failed = 0
    try:
        import placefix

        placefix._kks()
    except Exception:  # noqa: BLE001
        print("OK pykakasi が無い環境では地名の聞き間違いは出さない（省略）")
        return 0
    import placehints

    placehints.clear_cache()
    (base / "state" / "places_for_app.json").write_text(json.dumps({"items": [
        {"name": "ほしぞら会館", "sure": True, "visit_days": 4, "last_day": "2026-11-09"}]}), encoding="utf-8")
    placehints.clear_cache()
    base_ms = int(time.mktime(time.strptime(f"{DAY} 09:00:00", "%Y-%m-%d %H:%M:%S")) * 1000)
    lines = [{"time": base_ms, "who": "自分", "text": "星空会館で待ち合わせしよう", "conversation": base_ms},
             {"time": base_ms + 1000, "who": "自分", "text": "ほしぞら会館で降りた", "conversation": base_ms},
             {"time": base_ms + 2000, "who": "自分", "text": "今日はいい天気ですね", "conversation": base_ms}]
    items = placefix.for_day(DAY, lines, base, home)
    failed += say(len(items) == 1 and items[0]["wrong"] == "星空会館" and items[0]["guess"] == "ほしぞら会館",
                  f"読みが近い地名を直す候補に（{[(i['wrong'], i['guess']) for i in items]}）")
    failed += say(all(i["wrong"] in lines[0]["text"] for i in items) and items and items[0]["reason"].startswith("読みが近い"),
                  "wrong は文にそのまま含まれる・理由がつく")
    failed += say(placefix.for_day(DAY, lines, None, home) == [], "母艦が無ければ出さない")
    failed += say(lines[0]["text"] == "星空会館で待ち合わせしよう", "勝手に直さない（文は変わらない）")
    # 地名の辞書（任意）: tsv があれば、そこからも
    import placehints as ph

    folder = Path(tempfile.mkdtemp())
    saved = ph.GAZETTEER_DIR
    ph.GAZETTEER_DIR = folder
    (folder / "names.tsv").write_text("# 名前\tよみ\t種類\nうみかぜ市\tうみかぜし\t市\n", encoding="utf-8")
    ph.clear_cache()
    try:
        got = placefix.for_day(DAY, [{"time": base_ms, "who": "", "text": "海風市に引っ越す予定です", "conversation": base_ms}],
                               base, home)
        failed += say(any(i["guess"] == "うみかぜ市" for i in got), f"辞書があればそこからも（{[(i['wrong'], i['guess']) for i in got]}）")
    finally:
        ph.GAZETTEER_DIR = saved
        ph.clear_cache()
    # 夜の読み直しの流れ（Claude なし）に乗る
    import nightreview

    home_config = home / "config.json"
    home_config.write_text(json.dumps({"lifelog_home": str(base)}), encoding="utf-8")
    parsed = {"conversations": [{"start": base_ms, "lines": [{"time": base_ms, "speaker": "自分", "text": "星空会館で待ち合わせしよう"}]}]}

    class Store:
        def day(self, day):
            return parsed if day == DAY else None

    logged: list[str] = []
    saved_settings = nightreview.settings
    nightreview.settings = lambda: {"on": False, "usd": 0.0}
    try:
        count = nightreview.run_day(home, Store(), DAY, logged.append)
    finally:
        nightreview.settings = saved_settings
    saved_file = json.loads((home / "night-review" / f"{DAY}.json").read_text(encoding="utf-8"))
    failed += say(count == 1 and saved_file["misheard"][0]["guess"] == "ほしぞら会館" and saved_file["place_fix"] == 1,
                  "Claude を使わなくても、地名の候補は夜の読み直しの結果に入る")
    served = nightreview.read(home)
    failed += say(served["available"] and served["items"][0]["wrong"] == "星空会館", "GET /night-review に出る（アプリの聞き間違いかもの形）")
    home_config.write_text(json.dumps({"lifelog_home": str(base), "place_fix": False}), encoding="utf-8")
    nightreview.settings = lambda: {"on": False, "usd": 0.0}
    try:
        none = nightreview.run_day(home, Store(), DAY, logged.append)
    finally:
        nightreview.settings = saved_settings
    failed += say(none is None, '"place_fix": false で止める')
    return failed


def check_mothersearch(base: Path) -> int:
    import mothersearch
    import mothersearch_extra as ex
    import semantic

    failed = 0
    found = mothersearch.discover(base)
    sources = {s for s, _ in found}
    failed += say({"timeline", "calendar", "photo-notes", "places"} <= sources, f"新しい系統を見つける（{sorted(sources)}）")
    failed += say(set(ex.SOURCES) <= set(mothersearch.SOURCES) and ex.SOURCES[0] in mothersearch.LABELS, "系統と名前が登録されている")
    path = next(p for s, p in found if s == "timeline")
    chunks = mothersearch.chunks_for("timeline", path, path.read_text(encoding="utf-8"))
    joined = "\n".join(c["text"] for c in chunks)
    failed += say("つばめ図書館" in joined and "あおぞらパン" in joined and "打ち合わせ" in joined and "写真2枚" in joined,
                  "年表の位置・支払い・予定・写真を入れる")
    failed += say("秘密の話題" not in joined and "晴れ" not in joined and "35.67345" not in joined and "139.70001" not in joined,
                  "会話・天気の行は読まない・座標は消す")
    failed += say(mothersearch.day_of("timeline", base, path) == DAY
                  and mothersearch.day_of("calendar", base, next(p for s, p in found if s == "calendar")) == DAY
                  and mothersearch.day_of("photo-notes", base, next(p for s, p in found if s == "photo-notes")) == DAY, "日の決め方")
    only = mothersearch.discover(base, days={DAY}, with_state=False)
    failed += say({s for s, _ in only} == {"timeline", "calendar", "photo-notes"}, "日で絞れる（日の無いものは with_state のときだけ）")
    (base / "state" / "places-index.json").write_text(json.dumps([{"name": "ほしぞら会館", "aliases": ["星空会館"], "kind": "施設",
                                                                    "visits": 2, "last_day": "2026-11-10"}], ensure_ascii=False), encoding="utf-8")
    idx = [(s, p) for s, p in mothersearch.discover(base) if s == "places-index"]
    failed += say(len(idx) == 1 and idx[0][1].name == "places-index.json", "台帳は places-index.json を先に使う")
    text = mothersearch.chunks_for("places-index", idx[0][1], idx[0][1].read_text(encoding="utf-8"))
    failed += say(text and "星空会館" in text[0]["text"] and "施設" in text[0]["text"], "台帳の 1 件を 1 まとまりにする")
    (base / "state" / "places-index.json").unlink()
    (base / "archive" / "calendar" / "2026" / "11" / "11.md").write_text("# Calendar 2026-11-11\n\n(予定なし)\n", encoding="utf-8")
    cal = base / "archive" / "calendar" / "2026" / "11" / "11.md"
    failed += say(mothersearch.chunks_for("calendar", cal, cal.read_text(encoding="utf-8")) == [], "予定の無い日は置かない")

    class Fake:
        model = semantic.EMBED_MODEL

        def embed(self, texts):
            out = np.zeros((len(texts), 8), dtype=np.float32)
            for i, t in enumerate(texts):
                out[i, len(t) % 8] = 1.0
            return out

    with tempfile.TemporaryDirectory() as tmp:
        index = mothersearch.MotherIndex(Path(tmp) / "s.db", Fake(), lambda: base, lambda m: None)
        result = index.step(budget=1000)
        status = index.status()
        by = status["by_source"]
        failed += say(by.get("timeline", 0) >= 1 and by.get("calendar", 0) >= 1 and by.get("photo-notes", 0) >= 1
                      and by.get("places", 0) >= 1 and result["pending"] == 0, f"置ける（系統ごとの数 {by}）")
        hits = index.search("つばめ", k=3, sources=["timeline"])
        failed += say(all(h["source"] == "timeline" for h in hits) and hits, "系統でしぼって探せる")
    return failed


def check_motherquery(base: Path) -> int:
    import motherquery as q

    failed = 0
    where = q.where_at(base, DAY, "09:30")
    failed += say([w["place"] for w in where["here"]] == ["たぶんつばめ図書館"], "その時刻にいた所（「たぶん」はそのまま返す）")
    gap = q.where_at(base, DAY, "10:50")
    failed += say(not gap["here"] and gap["before"]["place"] == "たぶんつばめ図書館" and gap["after"]["place"] == "ひばり商店街付近",
                  "滞在の間なら直前と直後")
    day = q.day_timeline(base, DAY)
    failed += say(day["excluded_conversations"] == 1 and all(r["lane"] != "会話" for r in day["rows"])
                  and "35.67345" not in json.dumps(day, ensure_ascii=False), "1日の年表は会話を出さない・座標を出さない")
    failed += say([r["lane"] for r in q.day_timeline(base, DAY, ["決済"])["rows"]] == ["決済"], "種類でしぼれる")
    withconv = q.day_timeline(base, DAY, include_conversations=True)
    failed += say(any(r["lane"] == "会話" for r in withconv["rows"]), "職場の会話も返してよい設定のときだけ会話の行も出す")
    place = q.by_place(base, "ひばり")
    failed += say(place["count"] == 1 and place["hits"][0]["day"] == DAY, "場所の名前の一部で引く")
    failed += say(q.by_place(base, "つばめ", frm="2026-11-11")["count"] == 0, "期間でしぼれる")
    failed += say(q.promises(base)["items"] == ["ヒバリ商店で灯油を買う", "テスト太郎へお礼を送る"]
                  and q.promises(base, "太郎")["count"] == 1, "約束は open の行だけ・言葉でしぼれる")
    page = q.person_page(base, "テスト")
    failed += say(page["found"] and "いまの様子" in page["text"] and q.place_page(base, "つばめ")["found"]
                  and q.place_page(base, "なし")["found"] is False, "人と場所のページ")
    try:
        q.where_at(base, "2026-13-40", "09:00")
        failed += say(False, "おかしな日付は断る")
    except ValueError:
        failed += say(True, "おかしな日付は断る")
    # MCP
    import lifelog_mcp

    home = Path(tempfile.mkdtemp())
    tools = lifelog_mcp.Tools(home, None, {"lifelog_home": str(base)})
    names = {t["name"] for t in lifelog_mcp.TOOLS}
    failed += say({"search_place", "where_at", "day_timeline", "list_promises", "get_person_page", "get_place_page"} <= names
                  and all(t["annotations"]["readOnlyHint"] for t in lifelog_mcp.TOOLS), "MCP に 6 つ足した（どれも読むだけ）")
    failed += say(tools.call("where_at", {"day": DAY, "time": "09:30"})["here"][0]["place"] == "たぶんつばめ図書館"
                  and tools.call("search_place", {"name": "ひばり"})["count"] == 1
                  and tools.call("day_timeline", {"day": DAY})["excluded_conversations"] == 1
                  and tools.call("list_promises", {"who": "灯油"})["count"] == 1
                  and tools.call("get_person_page", {"name": "テスト太郎"})["found"]
                  and tools.call("get_place_page", {"name": "つばめ図書館"})["found"], "MCP の呼び出し")
    lifelog_mcp.INCLUDE_WORK = False
    try:
        failed += say(not tools.call("get_person_page", {"name": "テスト太郎"})["found"]
                      and tools.call("list_promises", {})["items"] == []
                      and all(r["lane"] != "会話" for r in tools.call("day_timeline", {"day": DAY})["rows"]),
                      "--exclude-work では人と場所のページ・約束を出さない（年表の会話はいつも出さない）")
    finally:
        lifelog_mcp.INCLUDE_WORK = True
    return failed


def check_ask(base: Path, home: Path) -> int:
    import askmother
    import audioclip

    failed = 0
    today = __import__("datetime").date(2026, 11, 11)
    looks = askmother.parse_lookups({"lookups": [
        {"tool": "where_at", "name": "", "day": DAY, "time": "9:30", "from": "", "to": ""},
        {"tool": "where_at", "name": "", "day": DAY, "time": "なし", "from": "", "to": ""},
        {"tool": "ひみつ", "name": "x", "day": "", "time": "", "from": "", "to": ""},
        {"tool": "by_place", "name": "つばめ", "day": "", "time": "", "from": "2026-13-01", "to": ""},
        {"tool": "promises", "name": "", "day": "", "time": "", "from": "", "to": ""},
        {"tool": "person_page", "name": "", "day": "", "time": "", "from": "", "to": ""}]}, today)
    failed += say([x["tool"] for x in looks] == ["where_at", "by_place", "promises"] and looks[1]["from"] == "",
                  f"lookups は決まりに合うものだけ（{[x['tool'] for x in looks]}）")
    failed += say(askmother.parse_lookups({}, today) == [] and askmother.parse_lookups(None, today) == [], "無ければ空")
    props = askmother.PLAN_SCHEMA["properties"]["lookups"]["items"]
    failed += say("lookups" in askmother.PLAN_SCHEMA["required"] and set(props["required"]) == set(props["properties"]),
                  "探し方の答えの形に lookups がある（全部の項目が必須）")
    got = askmother.run_lookups(base, looks + [{"tool": "day_timeline", "name": "", "day": DAY, "time": "", "from": "", "to": ""}])
    text = "\n".join(g["text"] for g in got)
    failed += say(got and all(g["source"] == "lookup" for g in got) and "つばめ図書館" in text and "灯油" in text
                  and "秘密の話題" not in text and "35.67345" not in text, "絞って引いた行を抜き出しの形に（会話・座標は入らない）")
    failed += say(askmother.LABELS["lookup"] and "place" in askmother.TOPICS and "places" in askmother.TOPIC_SOURCES["place"], "系統の名前・話題 place")
    # 130: 答えの出どころ → 音声
    base_ms = int(time.mktime(time.strptime(f"{DAY} 09:20:30", "%Y-%m-%d %H:%M:%S")) * 1000)
    parsed = {"audio_names": {}, "conversations": [{"start": base_ms, "lines": [
        {"time": base_ms, "speaker": "A", "text": "明日は図書館に本を返しに行く", "audio": "20261110-092000.m4a", "offset": 30.0, "end": 34.0},
        {"time": base_ms + 60000, "speaker": "A", "text": "音声が消えた行の話", "audio": "20261110-092100-gone.m4a", "offset": 2.0}]}]}

    class Store:
        def __init__(self, keep):
            self.keep = keep

        def day(self, day):
            return parsed if day == DAY else None

        def audio_file(self, name):
            return Path("x") if name in self.keep else None

    found = audioclip.locate(Store({"20261110-092000.m4a"}), DAY, "09:20", "明日は図書館に本を返しに行く", "app")
    failed += say(found and found["available"] and found["audio"] == "20261110-092000.m4a" and found["offset"] == 29.0
                  and found["path"].startswith("/audio-clip?audio=20261110-092000.m4a") and found["conversation"].startswith(DAY + "|"),
                  f"出どころの行から音声の名前と位置（{found}）")
    gone = audioclip.locate(Store(set()), DAY, "09:21", "音声が消えた行の話", "app")
    failed += say(gone and gone["available"] is False and "もう残っていません" in gone["message"], "音声が無ければ「もう無い」と返すだけ")
    failed += say(audioclip.locate(Store(set()), DAY, "09:22", "ぜんぜん違う文", "app") is None
                  and audioclip.locate(Store(set()), DAY, "09:20", "明日は図書館", "line") is None
                  and audioclip.locate(Store(set()), DAY, "09:20", "明日は図書館", "money") is None, "行が無い・会話でない出どころには付けない")
    # /audio-clip の入り口（名前の決まりに合わない・無い音声は 404）
    class Handler:
        def __init__(self):
            self.sent = None

        def send_json(self, status, body):
            self.sent = (status, body)

    h = Handler()
    audioclip.http_get(h, "audio=..%2f..%2fsecret&offset=0&length=5", Store(set()), lambda m: None)
    failed += say(h.sent and h.sent[0] == 404 and h.sent[1]["error"] == "gone", "危ない名前・無い音声は 404")
    return failed


def check_selective() -> int:
    import selective

    failed = 0

    def sim(a, b):
        return 1.0 if a == b else 0.3

    d = selective.doubtful
    failed += say(d({"haas": ""}, 3.0, sim) is None and d({}, 3.0, sim) is None,
                  "何も書かなかった区間は迷いにしない（Whisper だけの行は作り話として捨てられるので、かけてもむだ）")
    failed += say(d({"haas": "こんにちは今日はいい天気ですね", "reazon": "こんにちは今日は良い天気ですね"}, 4.0, lambda a, b: 0.9) is None
                  and d({"haas": "こんにちは今日は", "reazon": "ちがう文です"}, 4.0, sim) == "disagree", "2 つの近さで迷いを決める")
    failed += say(d({"haas": "あ"}, 8.0, sim) == "sparse" and d({"haas": "あああああああ"}, 3.0, sim) == "repeat"
                  and d({"haas": "今日は晴れていて気持ちがいいですね"}, 3.0, sim) is None, "取りこぼし・繰り返しの疑い")
    failed += say(d({"whisper": "別のモデルは見ない"}, 3.0, sim) is None, "遅いモデルの文は迷いの判断に使わない")
    failed += say(selective.scope({}) == "all" and selective.scope({"whisper_scope": "doubt"}) == "doubt"
                  and selective.scope({"whisper_scope": "x"}) == "all", "設定の読み（既定は全部）")
    return failed


def check_ensemble() -> int:
    import lifelog_pc

    lifelog_pc.isolate_home()
    failed = 0

    class Engine:
        provider = "cpu"

        def __init__(self, name, texts):
            self.name, self.label, self.texts, self.asked = name, name, texts, []

        def run_timed(self, audio, segments, hints, prompt):
            self.asked.append(list(segments))
            return [(self.texts(s), None) for s in segments]

    segments = [(0.0, 3.0), (4.0, 7.0), (8.0, 9.0), (10.0, 14.0)]
    haas_text = {0.0: "こんにちは今日はいい天気", 4.0: "", 8.0: "あああああああ", 10.0: "あ"}
    audio = np.zeros(16000 * 15, dtype=np.float32)
    saved_load, saved_clean = lifelog_pc.load_config, lifelog_pc.CLEAN_AUDIO
    lifelog_pc.CLEAN_AUDIO = False
    try:
        for scope, expect_asked in (("all", 4), ("doubt", 2)):
            haas = Engine("haas", lambda s: haas_text[s[0]])
            whisper = Engine("whisper", lambda s: "ウィスパーの文")
            lifelog_pc.load_config = lambda scope=scope: {"whisper_scope": scope}
            stats: dict = {}
            lines = lifelog_pc.Ensemble([haas, whisper]).transcribe(audio, segments, votes=True, stats=stats)
            asked = sum(len(a) for a in whisper.asked)
            failed += say(asked == expect_asked, f'"{scope}": Whisper にかけた区間は {asked}（期待 {expect_asked}）')
            failed += say(len(lines) == 3 and all(l["text"] for l in lines),
                          f'"{scope}": 速いモデルが書いた区間に文がある（Whisper だけの区間は作り話として捨てる）')
            if scope == "doubt":
                skipped = [l for l in lines if "whisper" not in l["votes"]]
                failed += say(len(skipped) == 1 and stats["whisper_scope"]["doubt_lines"] == 2
                              and stats["whisper_scope"]["lines"] == 4, f"迷わなかった区間は票が haas だけ（{len(skipped)}）・数を返す")
                failed += say(whisper.asked[0] == [(8.0, 9.0), (10.0, 14.0)], "迷った区間（繰り返し・まばら）だけをかける")
            else:
                failed += say("whisper_scope" not in stats, '既定は前と同じ（"whisper_scope" の数は付かない）')
    finally:
        lifelog_pc.load_config, lifelog_pc.CLEAN_AUDIO = saved_load, saved_clean
    return failed


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp) / "mother"
        home = Path(tmp) / "home"
        home.mkdir()
        make_mother(base)
        failed = check_placehints(base) + check_hintpolicy(base) + check_mothersearch(base) + check_motherquery(base) \
            + check_ask(base, home) + check_placefix(base, home) + check_selective() + check_ensemble()
    print("ぜんぶ OK" if not failed else f"NG が {failed} 個")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
