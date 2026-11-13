"""施策 13（会話の直後に約束だけ）と 15（記録に質問するを母艦まで）を確かめる（2026-11-13）。

    python pc/v12checks_promises.py

本物の鍵・ネット・母艦・APNs は使わない（作り物の Claude・作り物の検索・作り物の通知の相手）。本物の HOME に書かない
（isolate_home）。確かめること:
- 約束: 比べ方（アプリの TaskBook.similar と同じ）・接地（quote がその行に無いものは捨てる）・会話の選び方（10 分の静けさ・
  3 時間より古いもの・短い会話・テレビ）・通知の文（60 文字・中身を隠す）・品質の記録（ほかの項目を消さない・読めなければ書かない）・
  見回り（設定が届くまで何もしない・職場の扱い・1回だけ頼む・行が増えたら見直す・重ねない・頼まれごと帳・上限で送れなかったら
  あとでまとめる）・APNs の promise（目に見える通知・カテゴリ・ids・1日6回と10分に1回・1時間）・受け口（/promises-now・
  /promises/settings・合言葉・features）。記録に会話の文を書かない
- 母艦: 探し方の確かめ（言葉は正規表現の文字に・知らない系統を落とす・期間）・Search-Lifelog.py の出力の読み方・お金の行・
  長さの上限・見つからなければ答えの Claude に頼まない・出どころ・受け口（/ask-mothership・400・features）
"""

from __future__ import annotations

import datetime
import json
import sys
import tempfile
import threading
import time
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent))

import apns  # noqa: E402
import askmother  # noqa: E402
import claude  # noqa: E402
import ops  # noqa: E402
import promises  # noqa: E402
from v6checks import KEY, Client, say  # noqa: E402
from v11checks import FakeClaude, put_config, put_key, reset_files  # noqa: E402

SECRET_TEXT = "見本の秘密の会話"


def run(main) -> int:
    main.isolate_home()
    saved_factory = claude.CLIENT_FACTORY
    saved_run = askmother.RUN
    failed = 0
    try:
        failed += check_compare()
        failed += check_ground()
        failed += check_select()
        failed += check_text_and_quality()
        failed += check_apns()
        failed += check_watcher()
        failed += check_plan_and_output()
        failed += check_ask()
        failed += check_http(main)
    finally:
        claude.CLIENT_FACTORY = saved_factory
        askmother.RUN = saved_run
        promises.W = None
        reset_files()
    print(("NG の数: " + str(failed)) if failed else "約束と母艦への質問（2026-11-13）: 全部 OK", flush=True)
    return failed


# MARK: - 作り物


class FakeStore:
    """records.RecordStore の代わり（day だけ）"""

    def __init__(self) -> None:
        self.days: dict[str, dict] = {}

    def day(self, day: str):
        return self.days.get(day)


def line(ms: int, speaker: str, text: str, ident: str | None = None, media: str | None = None) -> dict:
    return {"time": ms, "text": text, "speaker": speaker, "speakerID": ident or ("me" if speaker == "自分" else "3"),
            "media": media}


def conversation(start_ms: int, lines: list[dict], work=None, media=None) -> dict:
    return {"start": start_ms, "end": max(l["time"] for l in lines), "lines": lines, "work": work, "media": media}


def talk(end_ms: int, extra: str = "") -> list[dict]:
    """約束を含む作り物の会話（end_ms が最後の行）"""
    texts = [("見本 花子", "明日の会議の資料はどうなっていますか"),
             ("自分", "金曜までに見積もりを送りますね" + extra),
             ("見本 花子", "お願いします"),
             ("自分", "わかりました")]
    step = 20_000
    first = end_ms - step * (len(texts) - 1)
    return [line(first + i * step, who, text) for i, (who, text) in enumerate(texts)]


class FakePusher:
    def __init__(self) -> None:
        self.sent: list[dict] = []
        self.devices = {"dev-0001-aaaa": {}}
        self.limit_ok = True
        self.fail = False

    def ready(self) -> bool:
        return True

    def usable(self, device: str) -> bool:
        return device in self.devices

    def allowed(self, device: str, kind: str, now=None) -> bool:
        return self.limit_ok

    def send(self, kind, devices=None, job=None, respect_limits=True, alert=None, extra=None):
        self.sent.append({"kind": kind, "devices": devices, "alert": alert, "extra": extra})
        return [{"device": d, "ok": not self.fail} for d in devices or list(self.devices)]


def promise_reply(quote: str = "金曜までに見積もりを送ります", line_no: int = 1, what: str = "見積もりを送る",
                  extra: list | None = None):
    items = [{"line": line_no, "quote": quote, "kind": "promised", "who": "見本 花子", "what": what, "due": "金曜まで"}]
    return json.dumps({"items": items + (extra or [])}, ensure_ascii=False)


# MARK: - 約束: 比べ方・接地・選び方


def check_compare() -> int:
    failed = 0
    failed += say(promises.similar("見積もりを送る", "見積もりを送ります") and promises.similar("資料を送る。", "資料を送る")
                  and not promises.similar("見積もりを送る", "会議室を取る") and not promises.similar("", "x"),
                  "比べ方: 終わりの「ます」・句読点の違いは同じ、別のことは違う（TaskBook.similar と同じ）")
    tasks = [{"what": "見積もりを送る", "day": "2026-11-01", "state": "done"},
             {"what": "会議室を取る", "day": None, "state": "open"}]
    failed += say(promises.is_duplicate("見積もりを送ります", "2026-11-01", [], tasks, [])
                  and not promises.is_duplicate("見積もりを送ります", "2026-11-13", [], tasks, [])
                  and promises.is_duplicate("会議室を取ります", "2026-11-13", [], tasks, [])
                  and promises.is_duplicate("資料を直す", "2026-11-13", [{"what": "資料を直す"}], [], [])
                  and promises.is_duplicate("資料を直す", "2026-11-13", [], [], ["資料を直す"]),
                  "重ねない: 同じ日の帳・まだのもの・前に拾ったもの・その日のまとめのやること")
    with tempfile.TemporaryDirectory() as folder:
        path = Path(folder) / "頼まれごと帳.json"
        path.write_text(json.dumps([{"what": "見本のこと", "day": "2026-11-13", "state": "open", "said": 1.0},
                                    {"bad": 1}, "x"], ensure_ascii=False), encoding="utf-8")
        got = promises.read_task_book(path)
        broken = Path(folder) / "broken.json"
        broken.write_text("{", encoding="utf-8")
        failed += say(got == [{"what": "見本のこと", "day": "2026-11-13", "state": "open"}]
                      and promises.read_task_book(broken) == [] and promises.read_task_book(None) == []
                      and promises.read_task_book(Path(folder) / "none.json") == [],
                      "頼まれごと帳の写し: 読むだけ・おかしな行と読めないファイルは空")
        failed += say(promises.task_book_file({"task_book_file": str(path)}) == path,
                      "頼まれごと帳の場所: config.json の task_book_file")
    return failed


def check_ground() -> int:
    failed = 0
    lines = talk(1_700_000_000_000)
    data = json.loads(promise_reply(extra=[
        {"line": 1, "quote": "来週までに送ります", "kind": "promised", "who": "", "what": "作り話", "due": ""},
        {"line": 9, "quote": "お願いします", "kind": "asked", "who": "", "what": "範囲の外", "due": ""},
        {"line": 2, "quote": "お願いします", "kind": "other", "who": "", "what": "知らない種類", "due": ""},
        {"line": 2, "quote": "お願いします", "kind": "asked", "who": "人物12", "what": "前後の行", "due": ""},
        {"line": True, "quote": "お願いします", "kind": "asked", "who": "", "what": "番号が bool", "due": ""},
        {"line": 0, "quote": "資料", "kind": "asked", "who": "", "what": "短すぎ", "due": ""},
    ]))
    kept = promises.ground(data, lines)
    whats = [k["what"] for k in kept]
    failed += say(whats == ["見積もりを送る", "前後の行"] and kept[1]["who"] == "",
                  f"接地: その行（と前後1行）にある言葉だけ・番号と種類を確かめる・「人物N」は相手にしない（{whats}）")
    spaced = promises.ground({"items": [{"line": 1, "quote": "金曜までに、見積もりを 送りますね", "kind": "promised",
                                         "who": "", "what": "見積もり", "due": ""}]}, lines)
    failed += say(len(spaced) == 1 and promises.ground("x", lines) == [] and promises.ground({"items": 3}, lines) == [],
                  "接地: 空白・句読点の違いは同じとみなす・形の違う答えは空")
    return failed


def check_select() -> int:
    failed = 0
    now = time.time()
    now_ms = int(now * 1000)
    day = promises.local_day(now)
    store = FakeStore()
    store.days[day] = {"conversations": [
        conversation(now_ms - 3_600_000, talk(now_ms - 15 * 60_000)),                       # 15 分前に終わった → 見る
        conversation(now_ms - 600_000, talk(now_ms - 5 * 60_000)),                          # 5 分前 → まだ
        conversation(now_ms - 6 * 3_600_000, talk(now_ms - 4 * 3_600_000)),                 # 4 時間前 → 古い
        conversation(now_ms - 7_200_000, talk(now_ms - 30 * 60_000), media="tv"),           # テレビ
        conversation(now_ms - 7_200_000, talk(now_ms - 40 * 60_000)[:2]),                   # 2 行だけ
        conversation(now_ms - 7_200_000, talk(now_ms - 20 * 60_000)[:2]
                     + [line(now_ms - 19 * 60_000, "テレビ", "番組の声", media="tv")] * 3),  # テレビの行は数えない
    ]}
    picked = promises.quiet_conversations(store, now)
    failed += say([c["start"] for _, c, _, _ in picked] == [now_ms - 3_600_000],
                  f"会話の選び方: 最後の行から10分〜3時間・3行以上・テレビを除く（{len(picked)} 件）")
    rows = promises.transcript([line(i, "自分", "あ" * 300, "me") for i in range(200)])
    failed += say(rows[-1]["n"] == 199 and sum(len(r["text"]) + 14 for r in rows) <= promises.TEXT_MAX + 400
                  and rows[0]["speaker"] == "自分",
                  "長い会話は終わりの方を、決まった長さまで渡す")
    return failed


def check_text_and_quality() -> int:
    failed = 0
    item = {"kind": "promised", "who": "見本 花子", "what": "見積もりを送る" * 10, "due": "金曜まで"}
    title, body = promises.push_text([item, dict(item)], hide=False)
    _, hidden = promises.push_text([item, dict(item)], hide=True)
    failed += say(len(body) <= promises.BODY_MAX and body.endswith("ほか1件") and body.startswith("見本 花子と：")
                  and "見本" not in hidden and "2 件" in hidden and title,
                  f"通知の文: 60 文字まで・ほかの数・隠すときは中身を出さない（{body}）")
    with tempfile.TemporaryDirectory() as folder:
        path = Path(folder) / "quality-daily.json"
        path.write_text(json.dumps({"version": 1, "days": {"2026-11-13": {"judge_calls": 7, "judge_agree_plaud": None}},
                                    "other": True}), encoding="utf-8")
        promises.bump_quality(Path(folder), "2026-11-13")
        promises.bump_quality(Path(folder), "2026-11-13")
        promises.bump_quality(Path(folder), "2026-11-14")
        data = json.loads(path.read_text(encoding="utf-8"))
        failed += say(data["days"]["2026-11-13"] == {"judge_calls": 7, "judge_agree_plaud": None, "promise_alerts": 2}
                      and data["days"]["2026-11-14"] == {"promise_alerts": 1} and data["other"] is True
                      and data["version"] == 1,
                      "品質の記録: promise_alerts だけを足す（ほかの担当の項目・ほかの日は消さない）")
        path.write_text("{壊れた", encoding="utf-8")
        promises.bump_quality(Path(folder), "2026-11-13")
        failed += say(path.read_text(encoding="utf-8") == "{壊れた", "品質の記録: 読めないファイルは上書きしない")
        empty = Path(folder) / "new"
        empty.mkdir()
        promises.bump_quality(empty, "2026-11-13")
        failed += say(json.loads((empty / "quality-daily.json").read_text(encoding="utf-8"))
                      == {"version": 1, "days": {"2026-11-13": {"promise_alerts": 1}}},
                      "品質の記録: 無ければ契約の形で作る")
    return failed


# MARK: - APNs の promise


def check_apns() -> int:
    failed = 0
    body = apns.payload("promise", alert={"title": "題", "body": "文" * 300}, extra={"ids": ["a", "b"], "day": "2026-11-13"})
    failed += say(body["aps"]["category"] == "promise" and body["ids"] == ["a", "b"] and "content-available" not in body["aps"]
                  and len(body["aps"]["alert"]["body"]) == apns.ALERT_MAX and body["lifelog"] == {"kind": "promise", "day": "2026-11-13"},
                  "promise の中身: 目に見える通知・カテゴリ promise・一番上に ids")
    headers = apns.headers_for("promise", "t", "x", 1000.0)
    failed += say(headers["apns-push-type"] == "alert" and headers["apns-priority"] == "10"
                  and headers["apns-expiration"] == str(1000 + 3600)
                  and apns.headers_for("wake", "t", "x", 0.0)["apns-push-type"] == "background",
                  "promise の見出し: alert・すぐ・1時間であきらめる（ほかの種類は今までどおり）")
    with tempfile.TemporaryDirectory() as folder:
        clock = [100_000.0]
        pusher = apns.Pusher(Path(folder), lambda _m: None, lambda: clock[0])
        pusher.sent = {"d": {"promise": []}}
        ok = [pusher.allowed("d", "promise")]
        pusher.sent["d"]["promise"].append(clock[0])
        ok.append(pusher.allowed("d", "promise"))
        clock[0] += 601
        ok.append(pusher.allowed("d", "promise"))
        pusher.sent["d"]["promise"] = [clock[0] - 700 * i for i in range(1, 7)]
        ok.append(pusher.allowed("d", "promise"))
        failed += say(ok == [True, False, True, False], f"promise の上限: 10分に1回・1日6回（{ok}）")
        # 本物の Pusher で送る形（鍵と JWT は作り物に替える。相手も作り物。ネットは使わない）
        posted: list[tuple] = []
        pusher = apns.Pusher(Path(folder) / "real", lambda _m: None, lambda: clock[0],
                             post=lambda url, headers, data: (posted.append((headers, data)) or (200, {}, b"")))
        pusher.key = lambda: ("ABCDEFGHIJ", object())
        pusher.token_for = lambda *args, **kwargs: "jwt"
        pusher.register("dev-0001-aaaa", {"token": "ab" * 32, "environment": "development", "team": "TEAM123456"},
                        "iPhone", "x")
        saved = apns.http2_available
        apns.http2_available = lambda: True
        try:
            first = pusher.send("promise", alert={"title": "題", "body": "文"}, extra={"ids": ["p1"]})
            second = pusher.send("promise", alert={"title": "題", "body": "文"}, extra={"ids": ["p2"]})
        finally:
            apns.http2_available = saved
        sent = json.loads(posted[0][1]) if posted else {}
        failed += say(first[0]["ok"] and not second[0]["ok"] and len(posted) == 1 and sent.get("ids") == ["p1"]
                      and posted[0][0]["apns-push-type"] == "alert" and sent["aps"]["category"] == "promise",
                      "本物の Pusher: promise を送る・すぐ次は上限で送らない")
    return failed


# MARK: - 見回り


def check_watcher() -> int:
    failed = 0
    reset_files()
    put_key()
    fake = FakeClaude()
    claude.CLIENT_FACTORY = fake.factory
    fake.reply = lambda kwargs: promise_reply()
    logged: list[str] = []
    now = time.time()
    now_ms = int(now * 1000)
    day = promises.local_day(now)
    store = FakeStore()
    start = now_ms - 3_600_000
    store.days[day] = {"conversations": [conversation(start, talk(now_ms - 15 * 60_000), work=False)],
                       "summary": {"todos": []}}
    pusher = FakePusher()
    with tempfile.TemporaryDirectory() as folder:
        home = Path(folder)
        book = home / "book.json"
        watcher = promises.Watcher(home, lambda: store, lambda: pusher, logged.append,
                                   lambda: {"task_book_file": str(book)})
        result = watcher.tick()
        failed += say(result["skipped"] == "アプリから設定がまだ届いていない" and not fake.calls and not pusher.sent,
                      "見回り: アプリから設定が届くまでは何もしない")
        watcher.set_settings({"on": True, "claude": True, "work": True, "hide_body": False, "device": "dev-0001-aaaa"})
        result = watcher.tick()
        call = fake.calls[-1][1] if fake.calls else {}
        failed += say(result["asked"] == 1 and result["kept"] == 1 and len(fake.calls) == 1
                      and call.get("model") == claude.TIERS["light"] and "output_config" in call,
                      f"見回り: 10分たった会話を軽いモデルに1回頼む（JSON の形つき）{result}")
        sent = pusher.sent[-1] if pusher.sent else {}
        failed += say(sent.get("kind") == "promise" and sent.get("devices") == ["dev-0001-aaaa"]
                      and len(sent["extra"]["ids"]) == 1 and "見積もり" in sent["alert"]["body"],
                      "見回り: 設定を送ってきた端末に promise を送る")
        quality = json.loads((home / "quality-daily.json").read_text(encoding="utf-8"))
        failed += say(quality["days"][day]["promise_alerts"] == 1, "見回り: 送れたら promise_alerts を足す")
        again = watcher.tick()
        failed += say(again["asked"] == 0 and len(fake.calls) == 1 and len(pusher.sent) == 1,
                      "見回り: 同じ会話は2回頼まない・知らせたものは2回送らない")
        # 行が増えたら見直す（同じ約束は重ねない。新しい約束だけ）
        store.days[day]["conversations"][0]["lines"].append(line(now_ms - 12 * 60_000, "自分", "それと会議室も予約しておきます"))
        fake.reply = lambda kwargs: promise_reply(extra=[{"line": 4, "quote": "会議室も予約しておきます", "kind": "promised",
                                                          "who": "", "what": "会議室を予約する", "due": ""}])
        grown = watcher.tick()
        items = watcher.now_items()["items"]
        failed += say(grown["asked"] == 1 and grown["kept"] == 1 and len(items) == 2 and len(pusher.sent) == 2
                      and pusher.sent[-1]["extra"]["ids"] == [items[0]["id"]],
                      f"見回り: 行が増えた会話は見直し、前に拾ったものは重ねない {grown}")
        # 頼まれごと帳にあるものは足さない
        book.write_text(json.dumps([{"what": "資料を直す", "day": day, "state": "candidate"}], ensure_ascii=False),
                        encoding="utf-8")
        store.days[day]["conversations"].append(conversation(start + 1, talk(now_ms - 20 * 60_000), work=False))
        fake.reply = lambda kwargs: promise_reply(what="資料を直します")
        third = watcher.tick()
        failed += say(third["asked"] == 1 and third["kept"] == 0, "見回り: アプリの頼まれごと帳にあるものは足さない")
        # 職場の会話（と分からない会話）は「職場の会話も Claude で」がオフなら送らない
        watcher.set_settings({"on": True, "claude": True, "work": False, "hide_body": True})
        store.days[day]["conversations"] += [conversation(start + 2, talk(now_ms - 25 * 60_000), work=True),
                                             conversation(start + 3, talk(now_ms - 26 * 60_000), work=None)]
        calls = len(fake.calls)
        work = watcher.tick()
        failed += say(work["asked"] == 0 and len(fake.calls) == calls, "見回り: 職場を送らない設定なら、職場と分からない会話は頼まない")
        # 上限で送れなかったものは、1時間以内なら次にまとめて送る（中身を隠す設定）
        watcher.set_settings({"on": True, "claude": True, "work": True, "hide_body": True})
        store.days[day]["conversations"].append(conversation(start + 4, talk(now_ms - 27 * 60_000, "ね"), work=False))
        fake.reply = lambda kwargs: promise_reply(what="見本の書類を出す", quote="見積もりを送りますねね")
        pusher.limit_ok = False
        held = watcher.tick()
        pushes = len(pusher.sent)
        pusher.limit_ok = True
        later = watcher.tick()
        failed += say(held["kept"] == 1 and held["pushed"] == 0 and later["pushed"] == 1 and len(pusher.sent) == pushes + 1
                      and "見本" not in pusher.sent[-1]["alert"]["body"],
                      "見回り: 上限で送れなかったものはあとで送る・中身を隠す設定なら文に出さない")
        # オフなら頼まない
        watcher.set_settings({"on": False, "claude": True, "work": True, "hide_body": False})
        store.days[day]["conversations"].append(conversation(start + 5, talk(now_ms - 28 * 60_000), work=False))
        calls = len(fake.calls)
        off = watcher.tick()
        failed += say(off["skipped"] == "アプリの設定でオフ" and len(fake.calls) == calls, "見回り: アプリでオフなら頼まない")
        # 保存して読み直しても続きから
        again = promises.Watcher(home, lambda: store, lambda: pusher, logged.append)
        failed += say(len(again.now_items()["items"]) == 3 and again.settings()["on"] is False,
                      "見回り: 状態を保存して、起動し直しても続きから")
        everything = "\n".join(logged)
        failed += say("見積もり" not in everything and "見本 花子" not in everything and "会議室" not in everything,
                      "記録に会話の文・人の名前・約束の中身を書かない")
        # 頼めなかったら（混んでいる）やり直す・上限なら止める
        watcher.set_settings({"on": True, "claude": True, "work": True, "hide_body": False})
        fake.error = type("Busy", (Exception,), {"status_code": 429})("busy")
        busy = watcher.tick()
        fake.error = None
        retry = watcher.tick()
        failed += say(busy["asked"] >= 1 and busy["kept"] == 0 and retry["asked"] >= 1,
                      "見回り: 混んでいて頼めなかった会話は、次の見回りでやり直す")
    reset_files()
    return failed


# MARK: - 母艦


SAMPLE_OUTPUT = (
    "⚠️ 知らない系統を飛ばしました: x\n"
    "\n\x1b[1m2026-11-01 12:34\x1b[0m  (line)\n"
    "    [見本の相手] 前の行\n"
    "  ★ [見本の相手] - 見本の餃子屋に7時で\n"
    "    [見本の相手] 次の行\n"
    "\n\x1b[1m2026-11-02 --:--\x1b[0m  (photos)\n"
    "  ★ [写真] 件数: 3（見本）\n"
    "\n\x1b[1m2026-11-03 +00:01:02\x1b[0m  (plaud-whisper)\n"
    "  ★ [見本の会議] 見本の話\n"
    "\n--- 3件ヒット（2026-08-01〜2026-11-13 / 系統: line）\n"
)


def check_plan_and_output() -> int:
    failed = 0
    today = datetime.date(2026, 11, 13)
    plan = askmother.parse_plan({"queries": [
        {"words": ["a.b", "見本 屋", "x", "y"], "sources": ["line", "browser", "line"], "from": "2026-11-20", "to": "2026-11-01"},
        {"words": [], "sources": [], "from": "", "to": ""},
        {"words": ["餃子"], "sources": [], "from": "bad", "to": ""},
        {"words": ["餃子"], "sources": [], "from": "bad", "to": ""},
        {"words": ["2"], "sources": [], "from": "", "to": ""}, {"words": ["3"], "sources": [], "from": "", "to": ""},
        {"words": ["4"], "sources": [], "from": "", "to": ""},
    ], "money": True, "money_words": ["見本"]}, today)
    q = plan["queries"]
    failed += say(len(q) == 4 and q[0]["pattern"] == "a\\.b 見本屋 x" and q[0]["sources"] == ["line"]
                  and (q[0]["from"], q[0]["to"]) == ("2026-11-01", "2026-11-20")
                  and (q[1]["from"], q[1]["to"]) == ("2026-08-15", "2026-11-13") and q[1]["sources"] == []
                  and plan["money"] is True and plan["money_words"] == ["見本"],
                  f"探し方: 言葉は正規表現の文字に・3語まで・知らない系統を落とす・期間を直す・同じものは1つ・4つまで")
    failed += say(askmother.parse_plan("x", today) == {"queries": [], "money": False, "money_words": []},
                  "探し方: 形の違う答えは空")
    hits = askmother.parse_output(SAMPLE_OUTPUT)
    failed += say([(h["day"], h["time"], h["source"]) for h in hits]
                  == [("2026-11-01", "12:34", "line"), ("2026-11-02", "", "photos"), ("2026-11-03", "+00:01:02", "plaud-whisper")]
                  and hits[0]["context"] == ["[見本の相手] 前の行", "[見本の相手] 次の行"]
                  and hits[0]["text"] == "[見本の相手] - 見本の餃子屋に7時で",
                  "Search-Lifelog.py の出力を読む（色の印・前後の行・時刻の無い行・PLAUD の経過時間）")
    with tempfile.TemporaryDirectory() as folder:
        base = Path(folder)
        (base / "reports" / "spending" / "card").mkdir(parents=True)
        (base / "reports" / "spending" / "card" / "2026-11.md").write_text(
            "# カード\n| 日時 | 金額 | 店 |\n|---|---:|---|\n| 11-01 12:04 | 1,000円 | 見本の店 | 見本カード | — |\n"
            "| 11-20 09:00 | 2,000円 | 期間の外 | 見本カード | — |\n", encoding="utf-8")
        (base / "reports" / "spending" / "2026-10.md").write_text(
            "# 支出\n## サマリ\n| 項目 | 額 |\n|---|---|\n| 合計 | 5,000円 |\n## 監視対象\n- 見本の店 3回\n", encoding="utf-8")
        found = askmother.money_lines(base, "2026-10-01", "2026-11-13", ["見本"])
        plain = askmother.money_lines(base, "2026-10-01", "2026-11-13", [])
        failed += say([f["day"] for f in found] == ["2026-10", "2026-11-01"] and all(f["source"] == "money" for f in found)
                      and any("合計" in f["text"] for f in plain) and not any("監視対象" in f["text"] for f in plain),
                      "お金: カードの明細（期間の中）と月のまとめ。言葉が無ければまとめのサマリ・カテゴリだけ")
    many = [[{"day": f"2026-11-{d:02d}", "time": "", "source": "line", "text": "あ" * 500, "context": ["い" * 500] * 5}
             for d in range(1, 29)] for _ in range(3)]
    picked = askmother.gather(many + [[{"day": "2026-11-01", "time": "", "source": "line", "text": "あ" * 500}]])
    size = sum(len(p["text"]) + sum(len(c) for c in p["context"]) for p in picked)
    failed += say(0 < len(picked) <= askmother.SNIPPETS and size <= askmother.TOTAL_MAX
                  and all(len(p["text"]) <= askmother.SNIPPET_MAX and len(p["context"]) <= 2 for p in picked)
                  and picked[0]["day"] == "2026-11-28" and [p["n"] for p in picked] == list(range(1, len(picked) + 1)),
                  f"抜き出し: 新しい日から・同じものは1つ・長さと数の上限（{len(picked)} 件・{size} 文字）")
    return failed


def check_ask() -> int:
    failed = 0
    reset_files()
    put_key()
    fake = FakeClaude()
    claude.CLIENT_FACTORY = fake.factory
    runs: list[list[str]] = []

    def runner(args, **kwargs):
        runs.append(args)
        return SimpleNamespace(stdout=SAMPLE_OUTPUT.encode("utf-8"), returncode=0)

    def reply(kwargs):
        if kwargs["model"] == claude.TIERS["light"]:
            return json.dumps({"queries": [{"words": ["餃子"], "sources": ["line"], "from": "", "to": ""}],
                               "money": False, "money_words": []}, ensure_ascii=False)
        return json.dumps({"answer": "11/1 の LINE で見本の餃子屋に7時と決めていました [1]", "used": [1, 99], "found": True},
                          ensure_ascii=False)

    fake.reply = reply
    askmother.RUN = runner
    with tempfile.TemporaryDirectory() as folder:
        config = {"lifelog_home": folder, "mothership_python": "py.exe"}
        failed += say(not askmother.available(config), "母艦: 検索の道具が無ければ features に出さない")
        try:
            askmother.ask("どこで食べた？", config)
            failed += say(False, "母艦: 検索の道具が無ければ 503")
        except askmother.AskError as error:
            failed += say(error.status == 503, "母艦: 検索の道具が無ければ 503")
        (Path(folder) / "scripts").mkdir()
        (Path(folder) / "scripts" / "Search-Lifelog.py").write_text("# 見本\n", encoding="utf-8")
        failed += say(askmother.available(config), "母艦: 道具があり Claude が使えれば features の askmother")
        got = askmother.ask("どこで食べた？", config, today=datetime.date(2026, 11, 13))
        args = runs[-1] if runs else []
        # 抜き出しは新しい日から番号を付ける（1 番は 11/3 の PLAUD）
        failed += say(got["found"] and got["sources"][0]["source"] == "plaud-whisper" and got["sources"][0]["label"] == "PLAUD"
                      and len(got["sources"]) == 1 and got["searched"]["snippets"] == 3
                      and args[:3] == ["py.exe", "-X", "utf8"] and "--source" in args and args[args.index("--source") + 1] == "line"
                      and args[args.index("--from") + 1] == "2026-08-15",
                      f"母艦: 探し方 → Search-Lifelog.py → 標準のモデルが出どころつきで答える {got['searched']}")
        answer_call = fake.calls[-1][1]
        failed += say(answer_call["model"] == claude.TIERS["standard"] and "見本の餃子屋" in answer_call["messages"][0]["content"],
                      "母艦: 答えは標準のモデル・見つかった抜き出しだけを渡す")
        askmother.RUN = lambda args, **kwargs: SimpleNamespace(stdout=b"\n--- 0\xe4\xbb\xb6\n", returncode=0)
        calls = len(fake.calls)
        none = askmother.ask("無いこと", config)
        failed += say(not none["found"] and none["answer"] == askmother.NOT_FOUND and len(fake.calls) == calls + 1,
                      "母艦: 見つからなければ「見つかりませんでした」・答えの Claude に頼まない")
        def slow(args, **kwargs):
            raise askmother.subprocess.TimeoutExpired(args, 1)
        askmother.RUN = slow
        failed += say(askmother.run_search(config, {"pattern": "x", "from": "2026-11-01", "to": "2026-11-02", "sources": []}, 1) == [],
                      "母艦: 検索が時間切れなら空（落ちない）")
        askmother.RUN = runner
    reset_files()
    return failed


# MARK: - 受け口


def check_http(main) -> int:
    failed = 0
    reset_files()
    put_key()
    fake = FakeClaude()
    claude.CLIENT_FACTORY = fake.factory
    logged: list[str] = []
    saved = (getattr(main.Handler, "engine", None), getattr(main.Handler, "key", None), main.log)
    with tempfile.TemporaryDirectory() as folder:
        try:
            main.log = logged.append
            main.Handler.key = KEY
            main.Handler.engine = main.Ensemble(ops.fake_engines())
            config = main.load_config()
            config["lifelog_home"] = folder
            config["mothership_python"] = "py.exe"
            main.save_config(config)
            (Path(folder) / "scripts").mkdir()
            (Path(folder) / "scripts" / "Search-Lifelog.py").write_text("# 見本\n", encoding="utf-8")
            askmother.RUN = lambda args, **kwargs: SimpleNamespace(stdout=SAMPLE_OUTPUT.encode("utf-8"), returncode=0)
            fake.reply = lambda kwargs: (json.dumps({"queries": [{"words": ["餃子"], "sources": [], "from": "", "to": ""}],
                                                     "money": False, "money_words": []})
                                         if kwargs["model"] == claude.TIERS["light"]
                                         else json.dumps({"answer": "答え [2]", "used": [2], "found": True}, ensure_ascii=False))
            store = FakeStore()
            promises.start(Path(folder) / "home", lambda: store, lambda: None, logged.append, background=False)
            server = main.Server(("127.0.0.1", 0), main.Handler)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            client = Client(server.server_address[1])
            hello = client.call("GET", "/hello")
            failed += say(hello[0] == 200 and {"promisesnow", "askmother"} <= set(hello[1]["features"]),
                          "/hello の features: promisesnow・askmother")
            status, body, _ = client.call("GET", "/promises-now")
            failed += say(status == 200 and body["available"] is True and body["items"] == [] and body["on"] is False,
                          f"GET /promises-now: 設定が届く前は空・on は false {status}")
            wrong = client.call("GET", "/promises-now", key="wrong")
            failed += say(wrong[0] == 401, "GET /promises-now も合言葉が要る")

            def post(path, value, key=KEY):
                data = value if isinstance(value, bytes) else json.dumps(value, ensure_ascii=False).encode("utf-8")
                return client.call("POST", path, data, {"Content-Type": "application/json"}, key=key)

            bad = [post("/promises/settings", b)[0] for b in (b"x", b"[]", {"on": "yes"}, {"device": "a b"})]
            failed += say(bad == [400, 400, 400, 400], f"POST /promises/settings: おかしな中身は 400（{bad}）")
            status, body, _ = post("/promises/settings", {"on": True, "claude": True, "work": False, "hide_body": False,
                                                          "device": "dev-0001-aaaa"})
            now_body = client.call("GET", "/promises-now")[1]
            failed += say(status == 200 and body == {"ok": True} and now_body["on"] is True
                          and promises.W.settings()["work"] is False,
                          "POST /promises/settings: 置いて、GET の on に出る")
            failed += say(post("/promises/settings", {"on": True}, key="wrong")[0] == 401,
                          "POST /promises/settings も合言葉が要る")
            status, body, _ = post("/ask-mothership", {"question": "どこで食べた？"})
            failed += say(status == 200 and body["found"] and body["sources"][0]["day"] == "2026-11-02"
                          and body["sources"][0]["label"] == "写真" and body["answer"] == "答え [2]",
                          f"POST /ask-mothership: 答えと出どころ {status}")
            bad = [post("/ask-mothership", b)[0] for b in (b"x", {"question": " "}, {"question": "あ" * 501}, {"q": 1})]
            failed += say(bad == [400, 400, 400, 400], f"POST /ask-mothership: おかしな中身は 400（{bad}）")
            failed += say(post("/ask-mothership", {"question": "x"}, key="wrong")[0] == 401,
                          "POST /ask-mothership も合言葉が要る")
            put_config({"work": False})
            failed += say(post("/ask-mothership", {"question": "x"})[0] == 403,
                          "POST /ask-mothership: 家の PC が職場を送らない設定なら 403（母艦には職場の中身もある）")
            put_config({})
            text = "\n".join(logged)
            failed += say("どこで食べた" not in text and "餃子" not in text and "答え [" not in text,
                          "記録に質問・抜き出し・答えを書かない")
            server.shutdown()
            server.server_close()
        finally:
            main.Handler.engine, main.Handler.key, main.log = saved
            promises.W = None
    reset_files()
    return failed


if __name__ == "__main__":
    import lifelog_pc

    sys.exit(1 if run(lifelog_pc) else 0)
