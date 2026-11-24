"""2026-11-24（s25。担当 P）: 家の PC の s25 の分を確かめる（K1〜K4・K6・K7・連16・早1〜3・大3・大4・大9・活1）。

    python pc/v25checks_s25p.py          （v24checks_s24.py の最後にも呼ばれる。CI の手順を増やさずに動かすため）

本物の HOME・母艦・iPhone・APNs・LINE・Claude は使わない（一時フォルダに作り物を作る。人の名前は「甲」「乙」などの記号だけ）。
"""

from __future__ import annotations

import base64
import datetime
import hashlib
import hmac
import io
import json
import os
import sys
import tempfile
import time
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent))

if "v25s" not in os.environ.get("LOCALAPPDATA", ""):  # 単独で動かすときも、本物の HOME に触れない
    os.environ["LOCALAPPDATA"] = str(Path(tempfile.mkdtemp(prefix="v25s-local-")))

import apns  # noqa: E402
import linehook  # noqa: E402
import plaudmatch  # noqa: E402
import s25pc  # noqa: E402
import s25pcheck  # noqa: E402
import s25pfeeds  # noqa: E402
import s25pline  # noqa: E402
import s25pnight  # noqa: E402
import s25ptrain  # noqa: E402
import trainer  # noqa: E402
import train_personal  # noqa: E402
from v6checks import say  # noqa: E402

TMP = Path(tempfile.mkdtemp(prefix="v25s-"))
LOGS: list[str] = []
TODAY = datetime.date(2026, 11, 25)


class Fake:
    client_address = ("127.0.0.1", 0)

    def __init__(self, body=b"", headers: dict | None = None) -> None:
        data = json.dumps(body, ensure_ascii=False).encode() if not isinstance(body, bytes) else body
        self.rfile = io.BytesIO(data)
        self.headers = {"Content-Length": str(len(data)), **(headers or {})}
        self.sent: list = []

    def send_json(self, status: int, body) -> None:
        self.sent = [status, body]

    def discard_body(self) -> None:
        pass


class Store:
    def __init__(self, days: dict) -> None:
        self.days_ = days

    def day(self, day: str):
        return self.days_.get(day)


def write(path: Path, body) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(body, ensure_ascii=False) if not isinstance(body, str) else body, encoding="utf-8")


def ms(day: str, hh: int, mm: int, ss: int = 0) -> int:
    return int(datetime.datetime.strptime(f"{day} {hh:02d}:{mm:02d}:{ss:02d}", "%Y-%m-%d %H:%M:%S").timestamp() * 1000)


# MARK: - K1・K2


def check_feeds() -> int:
    failed = 0
    base = TMP / "mother-feeds"
    write(base / "state" / "line_tasks_for_app.json", {"version": 1, "generated_at": "2026-11-25T06:00:00+09:00", "items": [
        {"id": "lt-1", "text": "資料を送る", "who": "甲", "due": "2026-11-27", "day": "2026-11-24", "work": False,
         "evidence": "資料おくって", "expires": "2026-11-30"},
        {"id": "lt-2", "text": "古い", "who": None, "due": None, "day": "2026-11-01", "work": False, "evidence": "", "expires": "2026-11-02"},
        {"id": "lt-3", "text": "職場の頼まれごと", "who": "乙", "due": None, "day": "2026-11-24", "work": True, "evidence": "",
         "expires": "2026-11-30"},
        {"id": "lt-4", "text": "職場で期限あり", "who": "乙", "due": "2026-11-26", "day": "2026-11-24", "work": True, "evidence": "",
         "expires": "2026-11-30"},
        {"id": "lt-5", "text": "形が違う", "day": "2026-11-24", "work": "yes", "expires": "2026-11-30"},
        {"id": "lt-1", "text": "同じ id", "day": "2026-11-24", "work": False, "expires": "2026-11-30"}]})
    got = s25pfeeds.read_line_tasks(base, TODAY)
    ids = [i["id"] for i in got.get("items") or []]
    failed += say(got.get("available") and ids == ["lt-1", "lt-4"] and got.get("held_work") == 1
                  and set(got["items"][0]) == {"id", "text", "who", "due", "day", "work", "evidence", "expires"},
                  f"K1: GET /line-tasks（期限切れ・形の違い・同じ id を落とす・職場は who と due の両方: {ids}）")
    failed += say(s25pfeeds.read_line_tasks(TMP / "none", TODAY).get("available") is False, "K1: 無ければ available false")
    write(base / "state" / "drafts_for_app.json", {"version": 1, "generated_at": "2026-11-25T06:00:00+09:00", "items": [
        {"id": "d-1", "kind": "reply", "title": "返事", "body": "了解です", "to": "甲", "when": None, "evidence": "e",
         "expires": "2026-11-28", "source": "m1"},
        {"id": "d-2", "kind": "settle", "title": "精算", "body": "表", "to": None, "when": "2026-11-26T10:00:00+09:00",
         "evidence": None, "expires": "2026-11-28", "source": "m2"},
        {"id": "d-3", "kind": "spam", "title": "x", "body": "y", "expires": "2026-11-28", "source": "m1"},
        {"id": "d-4", "kind": "report", "title": "古い", "body": "y", "expires": "2026-11-20", "source": "m2"}]})
    got = s25pfeeds.read_drafts(base, TODAY)
    failed += say(got.get("available") and [i["id"] for i in got["items"]] == ["d-1", "d-2"]
                  and got["items"][1]["when"] == "2026-11-26T10:00:00+09:00",
                  "K2: GET /drafts（kind の決まり・期限切れを落とす）")
    return failed


# MARK: - K3


def check_share() -> int:
    failed = 0
    home = TMP / "share-home"
    f = Fake({"name": "甲/乙:*?", "text": "[LINE] トーク履歴\n12:00 甲 こんにちは"})
    s25pfeeds.http_post_share(f, home, LOGS.append)
    saved = list((home / "line-share").glob("*.txt"))
    failed += say(f.sent[0] == 200 and f.sent[1]["ok"] and len(saved) == 1 and "/" not in saved[0].name and ":" not in saved[0].name
                  and saved[0].read_text(encoding="utf-8").startswith("[LINE]"),
                  f"K3: POST /line/share を HOME/line-share に置く（{saved[0].name if saved else '無い'}）")
    f = Fake({"name": "x", "text": "あ" * (s25pfeeds.SHARE_TEXT_MAX // 3 + 10)})
    s25pfeeds.http_post_share(f, home, LOGS.append)
    failed += say(f.sent[0] in (400, 413), "K3: 1 MB を超える text は断る")
    f = Fake({"name": 1, "text": "x"})
    s25pfeeds.http_post_share(f, home, LOGS.append)
    failed += say(f.sent[0] == 400 and not any("甲" in line for line in LOGS), "K3: 形の違う体は 400・記録に名前を書かない")
    return failed


# MARK: - K4


SECRET = "check-channel-secret"


def sig(body: bytes) -> str:
    return base64.b64encode(hmac.new(SECRET.encode(), body, hashlib.sha256).digest()).decode()


def event(text: str, n: int) -> bytes:
    return json.dumps({"events": [{"type": "message", "webhookEventId": f"ev-{n}-{time.time()}", "replyToken": f"rt-{n}",
                                   "source": {"type": "user", "userId": "U" + "a" * 32},
                                   "message": {"type": "text", "text": text}}]}, ensure_ascii=False).encode()


def check_bot() -> int:
    failed = 0
    home, mother = TMP / "bot-home", TMP / "bot-mother"
    home.mkdir(parents=True)
    replies: list = []
    sender = lambda tok, rt, text: replies.append(text) or True  # noqa: E731
    st, _ = s25pline.handle(event("まとめ", 0), sig(event("まとめ", 0)), home, {}, mother, LOGS.append, sender)
    failed += say(st == 503 and not replies, "K4: チャネルシークレットが無ければ 503（答えない）")
    (home / linehook.SECRET_FILE).write_text(SECRET + "\n", encoding="utf-8")
    (home / linehook.TOKEN_FILE).write_text("check-access-token\n", encoding="utf-8")
    write(mother / "state" / "line_bot_feed.json", {"version": 1, "updated": "2026-11-25T06:00:00+09:00", "summary": "今日のまとめの文",
                                                    "letters": [{"id": "l1", "text": "便り 1", "at": "2026-11-25T07:00:00+09:00"},
                                                                {"id": "l2", "text": "便り 2", "at": "2026-11-25T08:00:00+09:00"}],
                                                    "people": {"甲": "甲さんとは 11/20 に話した"}})
    body = event("まとめ", 1)
    st, _ = s25pline.handle(body, "bad", home, {}, mother, LOGS.append, sender)
    failed += say(st == 401 and not replies, "K4: 署名が違えば 401（中身を見ない）")
    for n, (text, want) in enumerate((("まとめ", "今日のまとめの文"), ("甲さん", "甲さんとは 11/20 に話した"),
                                      ("丙さん", "丙さんの 1 行はまだありません"), ("メモ 駅で傘を買う", "入れました"))):
        body = event(text, 10 + n)
        replies.clear()
        st, _ = s25pline.handle(body, sig(body), home, {}, mother, LOGS.append, sender)
        failed += say(st == 200 and replies == [want], f"K4: 「{text}」→ 返信 1 言（{replies}）")
    memo = (home / s25pline.MEMO_FILE).read_text(encoding="utf-8").splitlines()
    failed += say(len(memo) == 1 and json.loads(memo[0])["text"] == "駅で傘を買う" and "at" in json.loads(memo[0]),
                  "K4: メモは HOME/line-memo.jsonl に {at, text}")
    body = event("便り", 20)
    replies.clear()
    s25pline.handle(body, sig(body), home, {}, mother, LOGS.append, sender)
    first = replies[-1] if replies else ""
    body = event("こんにちは", 21)
    s25pline.handle(body, sig(body), home, {}, mother, LOGS.append, sender)
    second = replies[-1] if replies else ""
    failed += say("便り 2" in first and "便り 1" in first and first.index("便り 2") < first.index("便り 1")
                  and second == "溜まっている便りはありません",
                  "K4: 便りかそのほか → 溜まっている便り（新しい順）・返したら印（2 回目は無い）")
    failed += say(not any("甲" in line or "傘" in line for line in LOGS), "K4: 記録（log）には中身・名前を書かない")
    # LINE の再送（同じ webhookEventId）は 2 回答えない
    body = json.dumps({"events": [{"type": "message", "webhookEventId": "same-ev", "replyToken": "r",
                                   "source": {"type": "user", "userId": "U" + "a" * 32},
                                   "message": {"type": "text", "text": "まとめ"}}]}).encode()
    replies.clear()
    s25pline.handle(body, sig(body), home, {}, mother, LOGS.append, sender)
    s25pline.handle(body, sig(body), home, {}, mother, LOGS.append, sender)
    failed += say(len(replies) == 1, "K4: 再送は 2 回答えない")
    return failed


# MARK: - K6


class Pusher:
    def __init__(self) -> None:
        self.sent: list = []

    def ready(self) -> bool:
        return True

    def send(self, kind, devices=None, **_):
        self.sent.append(kind)
        return [{"device": "d1", "ok": True}]


def check_ping() -> int:
    failed = 0
    home = TMP / "ping-home"
    pusher = Pusher()
    failed += say("ping" in apns.KINDS and apns.LIMITS["ping"] == ((20 * 3600, 1),)
                  and apns.payload("ping") == {"aps": {"content-available": 1}, "lifelog": {"kind": "ping"}},
                  "K6: APNs の kind ping は見えない通知・20 時間に 1 回")
    morning = datetime.datetime(2026, 11, 25, 9, 0)
    noon = datetime.datetime(2026, 11, 25, 12, 5)
    failed += say(s25pnight.ping_tick(home, pusher, {}, morning) is None and not pusher.sent, "K6: 12 時台より前は送らない")
    got = s25pnight.ping_tick(home, pusher, {}, noon)
    again = s25pnight.ping_tick(home, pusher, {}, noon + datetime.timedelta(minutes=10))
    failed += say(got == {"sent": 1} and again is None and pusher.sent == ["ping"], "K6: 1 日 1 回だけ送る")
    write(home / "diag" / "dev" / "latest.json", {"tally": {"2026-11-25": {"s25.ping.got": 1}}})
    got = s25pnight.ping_tick(home, pusher, {}, noon + datetime.timedelta(minutes=30))
    import quality

    day = quality.read_daily(home)["days"].get("2026-11-25") or {}
    failed += say(got == {"got": True} and day.get("s25p_ping_sent") == 1 and day.get("s25p_ping_got") is True,
                  "K6: 様子の tally s25.ping.got で返りを見て quality-daily に")
    failed += say(s25pnight.ping_tick(home / "off", pusher, {"s25p_ping": False}, noon) is None, "K6: s25p_ping false で止まる")
    return failed


# MARK: - K7


def check_whisper() -> int:
    failed = 0
    now = ms("2026-11-25", 15, 0) / 1000
    parsed = {"conversations": [{"start": ms("2026-11-25", 14, 50), "title": "", "lines": [
        {"time": ms("2026-11-25", 14, 55), "speaker": "甲", "media": None, "text": "a"},
        {"time": ms("2026-11-25", 14, 56), "speaker": "甲", "media": None, "text": "b"},
        {"time": ms("2026-11-25", 14, 57), "speaker": "人物3", "media": None, "text": "c"},
        {"time": ms("2026-11-25", 14, 58), "speaker": "自分", "media": None, "text": "d"}]}]}
    before = {"conversations": [{"start": ms("2026-11-20", 10, 0), "title": "週末の話", "lines": [
        {"time": ms("2026-11-20", 10, 1), "speaker": "甲", "media": None, "text": "x"}]}]}
    store = Store({"2026-11-25": parsed, "2026-11-20": before})
    failed += say(s25pfeeds.whisper_now(store, {}, now) == {}, "K7: 初めはオフ（{}）")
    got = s25pfeeds.whisper_now(store, {"whisper_now": True}, now)
    failed += say(got.get("person") == "甲" and got.get("last_talk") == "11-20 週末の話" and got.get("promises") == [],
                  f"K7: 直近 10 分の名前の付いた相手・前に話したこと（{got}）")
    failed += say(s25pfeeds.whisper_now(store, {"whisper_now": True}, now + 3600) == {}, "K7: 10 分より前なら {}")
    return failed


# MARK: - 早1・早2・早3


def check_stages() -> int:
    failed = 0
    t = datetime.datetime(2026, 11, 24, 10, 0).timestamp()
    metas = [
        {"id": "20261124-095500.m4a", "status": "done", "times": {"chunk_start": t - 300, "chunk_end": t, "arrived": t + 2, "sent": t + 30},
         "queued_at": t + 90, "started_at": t + 100, "draft_at": t + 105, "done_at": t + 160},
        {"id": "20261124-100000.m4a", "status": "done", "times": {"chunk_start": t, "chunk_end": t + 300, "arrived": t + 302, "sent": t + 303},
         "queued_at": t + 120, "started_at": t + 400, "done_at": t + 460},
        {"id": "20261124-100500-w.m4a", "status": "done", "origin": "watch",
         "times": {"chunk_start": t + 300, "chunk_end": t + 600, "sent": t + 601}, "queued_at": t + 605, "started_at": t + 606,
         "done_at": t + 700}]
    got = s25pnight.stages_for(metas, {"2026-11-24"}).get("2026-11-24") or {}
    phone = got.get("iphone") or {}
    failed += say(phone.get("pc_work", {}).get("count") == 2 and phone.get("phone_hold", {}).get("median") is not None
                  and (got.get("watch") or {}).get("pc_work", {}).get("median") == 94.0 and got.get("longest") in dict(s25pnight.STAGES)
                  and got.get("batched") == 1.0 and sum(got["to_pc_buckets"].values()) >= 1,
                  f"早1・早3: 段ごとの待ち（いちばん長い段 {got.get('longest')}・まとめて届いた割合 {got.get('batched')}）")
    est = {"s22": 3600.0, "s23": 3600.0, "s24": 3600.0, "quality": 7200.0, "s25p_mic": 600.0}
    failed += say(s25pnight.thin_plan(est) == ["s25p_mic", "s24"] and s25pnight.thin_plan({"s22": 100, "quality": 100}) == [],
                  "早2: 4 時間に収まらなければ軽いものから間引く（quality は間引かない）")
    home = TMP / "night-home"
    s25pnight.Night.home, s25pnight.Night.config = home, (lambda: {})
    for key, sec in (("2026-11-21", 9000), ("2026-11-22", 9000), ("2026-11-23", 9000)):
        clock = datetime.datetime.strptime(key + " 03:00", "%Y-%m-%d %H:%M").timestamp()
        for name in ("s24", "quality"):
            s25pnight.record_time(home, name, sec, clock)
    s25pnight.Night.clock = staticmethod(lambda: datetime.datetime(2026, 11, 24, 1, 30).timestamp())
    ran: list = []
    wrapped = s25pnight.timed("s24", lambda *a: ran.append(1) or {"ok": 1})
    out = wrapped()
    nights = (json.loads((home / "s25p" / "night-times.json").read_text(encoding="utf-8")))["nights"]
    failed += say(out == {"s25p_skipped": True} and not ran and "s24" in nights["2026-11-24"]["_skipped"],
                  "早2: 収まらない晩は間引き、間引いた名前を残す")
    s25pnight.Night.config = lambda: {"s25p_night_thin": False}
    out = wrapped()
    failed += say(out == {"ok": 1} and ran and nights.get("2026-11-23", {}).get("s24", {}).get("seconds") == 9000,
                  "早2: s25p_night_thin false なら間引かない・時間を数える")
    s25pnight.Night.clock = staticmethod(time.time)
    return failed


# MARK: - 大3・連16・大9


def check_mic_calls() -> int:
    failed = 0
    home, base = TMP / "mic-home", TMP / "mic-mother"
    day = "2026-11-24"
    t0 = datetime.datetime(2026, 11, 24, 10, 0).timestamp()
    import judgecheck

    blocks = []
    for i, text in enumerate(["今日は駅前の店で打ち合わせをしました", "来週の予定を決めましょう"]):
        b = {"t": i * 30, "text": text, "n": judgecheck.norm(text)}
        b["end"] = b["t"] + 20
        blocks.append(b)
    saved = plaudmatch._timed
    plaudmatch._timed = lambda h, b, d: ([{"t0": t0, "blocks": blocks, "day": day}], []) if d == day else ([], [])
    try:
        metas = [{"id": "20261124-100000-w.m4a", "status": "done", "times": {"chunk_start": t0, "chunk_end": t0 + 300},
                  "voiced_seconds": 60},
                 {"id": "20261124-100000.m4a", "status": "done", "times": {"chunk_start": t0, "chunk_end": t0 + 300},
                  "voiced_seconds": 30}]
        iso = lambda s: datetime.datetime.fromtimestamp(t0 + s, datetime.timezone.utc).isoformat().replace("+00:00", "Z")  # noqa: E731
        parsed = {"conversations": [{"lines": [
            {"time": iso(2), "audio": "20261124-100000-w.m4a", "text": "今日は駅前の店で打ち合わせをしました", "media": None},
            {"time": iso(3), "audio": "20261124-100000.m4a", "text": "今日は液のミセで", "media": None}]}]}
        got = s25pnight.mic_day(home, base, day, metas, parsed)
        w, p = got["devices"]["watch"], got["devices"]["iphone"]
        failed += say(got["minutes"]["all3"] >= 1 and w["match"] == 1.0 and p["match"] is not None and p["match"] < 1.0
                      and w["voiced_s"] > p["voiced_s"],
                      f"大3: 同じ時間の時計・iPhone を PLAUD と比べる（時計 {w['match']}・iPhone {p['match']}）")
        s25pnight._write(home / "s25p" / "mic.json", {"days": {"2026-11-22": got, "2026-11-23": got, day: got}})
        cand = s25pnight.mic_candidate(home, TODAY, need_days=3)
        failed += say(cand["pick"] is None and cand["days"] == 3, "大3: 重なりが短いうちは候補を出さない（仮 30 分）")
        big = json.loads(json.dumps(got))
        for d in big["devices"].values():
            d["overlap_min"] = 20
        s25pnight._write(home / "s25p" / "mic.json", {"days": {"2026-11-22": big, "2026-11-23": big, day: big}})
        cand = s25pnight.mic_candidate(home, TODAY, need_days=3)
        failed += say(cand["pick"] == "watch", f"大3: 3 日たまったら主にする音の候補（{cand['pick']}）")
    finally:
        plaudmatch._timed = saved
    write(base / "archive" / "line" / "2026" / "11" / "24.md",
          "# 2026-11-24 LINE\n\n## 甲\n\n- **10:10** 甲: ☎ 通話時間 5:00\n- **11:00** 甲: こんにちは\n\n## 乙\n\n- **20:00** 乙: ☎ 通話時間 0:10\n")
    calls = s25pnight.line_calls(base, day)
    failed += say([c["room"] for c in calls] == ["甲", "乙"] and calls[0]["seconds"] == 300, "連16: LINE の「☎ 通話時間」を読む")
    conv = {"start": ms(day, 10, 6), "end": ms(day, 10, 9), "lines": [{"speaker": "人物2", "media": None}]}
    far = {"start": ms(day, 15, 0), "end": ms(day, 15, 5), "lines": [{"speaker": "人物4", "media": None}]}
    got = s25pnight.call_candidates(base, day, {"conversations": [conv, far]})
    failed += say(len(got) == 1 and got[0]["room"] == "甲" and got[0]["unnamed"] == ["人物2"] and got[0]["already"] is False,
                  "連16: 通話の時間に重なる会話に、相手の名前の候補（短い通話・離れた会話は出さない）")
    store = Store({day: {"conversations": [conv, far]}})
    n = s25pnight.calls_nightly(home, base, store, TODAY)
    failed += say(n == 1 and (base / "inbox" / "pc-line-calls" / "s25p_call_candidates.json").is_file(), "連16: 母艦の inbox にも写す")
    named = {"start": ms(day, 12, 0), "lines": [{"speaker": "甲", "media": None}, {"speaker": "自分", "media": None}]}
    got = s25pnight.partner_day({"conversations": [conv, far, named, {"media": "tv", "lines": []}]})
    failed += say(got == {"conversations": 3, "named": 1, "only_unnamed": 2, "rate": 0.333}, f"大9: 相手の付き方（{got}）")
    return failed


# MARK: - 大4


def check_teacher() -> int:
    failed = 0
    import judgecheck

    got = s25ptrain.teacher_text(judgecheck.norm("今日は駅の前の店で打ち合わせ"), ["えっと。", "今日は駅前の店で打ち合わせをしました。", "はい"])
    failed += say(got is not None and got[0].startswith("今日は駅前の店で打ち合わせ") and got[1] >= 0.7,
                  f"大4: 行に合う所を PLAUD の文から切り出して先生の文にする（{got}）")
    failed += say(s25ptrain.teacher_text(judgecheck.norm("まったく違う話をしている"), ["今日は駅前の店で打ち合わせ"]) is None,
                  "大4: 合わない行は材料にしない")
    home = TMP / "train-home"
    night = datetime.datetime(2026, 11, 25, 0, 30).timestamp()
    day = datetime.datetime(2026, 11, 25, 12, 0).timestamp()
    w = s25ptrain.once_window(home, {}, night, "300")
    failed += say(w is not None and w["args"] == ["--test-human-all", "--candidate"] and w["window"][0] <= night < w["window"][1]
                  and s25ptrain.once_window(home, {}, day) is None and s25ptrain.once_window(home, {"s25p_train_once": False}, night) is None,
                  "大4: この版で 1 回だけの時間帯（00:00〜05:00・止められる）")
    s25ptrain.once_finished(home, {"result": "refused"})
    still = s25ptrain.once_window(home, {}, night) is not None
    s25ptrain.once_finished(home, {"result": "not_improved", "cer_before": 0.2, "cer_after": 0.19})
    failed += say(still and s25ptrain.once_window(home, {}, night) is None, "大4: 断られた晩は数えず、動けたら済み")
    # trainer が 1 回だけの時間帯と引数を使うか（作り物）
    t = trainer.AutoTrainer(TMP / "trainer-home", TMP, LOGS.append, gpu_plan=None, ollama=None,
                            count_samples=lambda: 400, is_idle=lambda: True, has_gpu=lambda: True,
                            on_improved=lambda: None, clock=lambda: datetime.datetime(2026, 11, 25, 0, 30).timestamp())
    t.configure({"autotrain": {"days": ["sun"]}})   # 11/25 は水曜＝ふだんの時間帯ではない
    t.available = lambda: True
    t.runtime = SimpleNamespace(ready=lambda: True, preparing=False)
    started: list = []
    t.start = lambda count: started.append((count, t.command()))
    t.tick()
    failed += say(not started, "大4: 1 回だけの口が無ければ、ふだんの時間帯の外では動かない")
    t.once = lambda now: s25ptrain.once_window(TMP / "trainer-once", {}, now)
    t.python = lambda: "py"
    t.tick()
    failed += say(len(started) == 1 and started[0][1][-2:] == ["--test-human-all", "--candidate"],
                  "大4: 1 回だけの時間帯で train_personal を --test-human-all --candidate で動かす")
    rows = [{"audio": "a", "hash": "1"}, {"audio": "b", "hash": "2", "source": {"origin": "pc-plaud-teacher", "auto": True}},
            {"audio": "c", "hash": "3", "source": {"origin": "pc-review"}}]
    train, test = train_personal.split_human_all(rows)
    failed += say([r["audio"] for r in train] == ["b"] and [r["audio"] for r in test] == ["a", "c"],
                  "大4: 学ぶのは自動の材料・試すのは人が確かめた材料の全部（正解集で前後を測る）")
    return failed


# MARK: - 大9 s-norm の口・活1


def check_snorm_precheck() -> int:
    failed = 0
    body = {"days": [{"groups": [{"id": "g", "score": 0.6, "snorm": 2.1}, {"id": "h", "score": 0.5, "snorm": None}]}], "maybe": []}
    s25pc.S.home = TMP / "snorm-home"
    same = s25pc.snorm_switch(json.loads(json.dumps(body)), {})
    forced = s25pc.snorm_switch(json.loads(json.dumps(body)), {"s25p_snorm_switch": True, "s25p_snorm_force": True})
    not_yet = s25pc.snorm_switch(json.loads(json.dumps(body)), {"s25p_snorm_switch": True})
    g = forced["days"][0]["groups"]
    failed += say(same == body and not_yet == body and g[0]["score"] == 2.1 and g[0]["score_raw"] == 0.6 and g[1]["score"] == 0.5,
                  "大9: s-norm に切り替える口（初めはオフ・候補になるまで切り替えない・強いても s-norm の無い組はそのまま）")
    home = TMP / "check-home"
    write(home / "s22" / "review" / "items.json", {"items": [
        {"id": "num-1", "kind": "number", "choices": ["3時に", "33時に"], "evidence": [{"text": "3時に", "ref": "2026-11-24|1"}]},
        {"id": "num-2", "kind": "number", "choices": ["5千円", "5円"], "evidence": [{"text": "5円", "ref": "2026-11-24|2"}]},
        {"id": "spk-1", "kind": "speaker_line"}]})
    failed += say(s25pcheck.run(home, None, {})["stopped"] == "off", "活1: 初めはオフ（Claude を呼ばない）")
    asked: list = []

    def caller(system, prompt, **kwargs):
        asked.append(kwargs.get("purpose"))
        return {"data": {"pick": 0, "sure": True}}

    got = s25pcheck.run(home, None, {"s25p_precheck": True}, TODAY, caller)
    failed += say(got["asked"] == 2 and got["closed"] == 1 and got["kept"] == 1 and asked == ["s25-precheck"] * 2,
                  f"活1: 数字の問いだけを見て、確かで今の文と同じものだけ閉じる（{got}）")
    again = s25pcheck.run(home, None, {"s25p_precheck": True}, TODAY, caller)
    failed += say(again["asked"] == 0, "活1: 同じ問いは 2 回見ない")
    queue = {"available": True, "items": [{"id": "num-1"}, {"id": "num-2"}, {"id": "m-1"}]}
    out = s25pcheck.drop_closed(queue, home)
    failed += say([i["id"] for i in out["items"]] == ["num-2", "m-1"] and out["pc_held"] == {"precheck": 1},
                  "活1: GET /review-queue から閉じた問いを抜く")
    capped = TMP / "cap-home"
    write(capped / "s22" / "review" / "items.json", {"items": [
        {"id": f"num-{i}", "kind": "number", "choices": ["a", "b"], "evidence": [{"text": "a", "ref": "x"}]} for i in range(9)]})
    got = s25pcheck.run(capped, None, {"s25p_precheck": True}, TODAY, caller)
    failed += say(got["asked"] == 5 and got["stopped"] == "count", "活1: 1 日 5 問（仮）まで")
    return failed


# MARK: - summary.md


def check_summary() -> int:
    failed = 0
    home = TMP / "summary-home"
    home.mkdir(parents=True, exist_ok=True)
    s25pc.S.home = home
    s25pc.S.main = SimpleNamespace(load_config=lambda: {}, log=LOGS.append, HOME=home,
                                   mothership=SimpleNamespace(home=lambda c: None),
                                   read_samples=lambda folder: [], PERSONAL_DATA=home / "personal" / "data")
    worries, lines = s25pc.summary_lines(None)
    text = "\n".join(lines)
    failed += say(not any("数えられませんでした" in line for line in lines) and "K4" in text and "早2" in text and "大4" in text
                  and "活1" in text, f"summary.md の「s25 の数」の節（{len(lines)} 行）")
    failed += say(set(s25pc.features({})) >= {"linetasks", "drafts", "lineshare", "linehook", "ping"}
                  and "whispernow" not in s25pc.features({}) and "whispernow" in s25pc.features({"whisper_now": True}),
                  "/hello の features（whispernow はオンのときだけ）")
    f = Fake()
    s25pc.http_get(f, "/line-tasks")
    failed += say(f.sent[0] == 200 and f.sent[1].get("available") is False, "GET /line-tasks: 母艦が無ければ available false")
    return failed



def check_search() -> int:
    """K8: POST /mother-search の中身の確かめと、返す形（まとめ役が 2026-11-25 に足した）"""
    import datetime as _dt
    failed = 0
    r = s25pc.search_request(json.dumps({"query": "見本", "k": 99, "days": 7}).encode(), today=_dt.date(2026, 11, 25))
    failed += say(r["k"] == s25pc.SEARCH_K_MAX and r["frm"] == "2026-11-18", "検索: k の上限と days から始まりの日")
    try:
        s25pc.search_request(b'{"query": ""}')
        failed += say(False, "検索: 空の query を断る")
    except ValueError:
        failed += say(True, "検索: 空の query を断る")
    hits = s25pc.search_hits([{"source": "line", "day": "2026-11-20", "time": "10:00", "text": "見本さんと話した", "path": "x", "score": 0.9},
                              {"source": "line", "day": "2026-11-20", "text": "ほかの話"}], "見本", 5)
    failed += say(len(hits) == 1 and "path" not in hits[0] and "score" not in hits[0], "検索: 人でしぼり、path と点を出さない")
    import appfeeds
    failed += say(appfeeds.FEEDBACK.get("draft") == ("sent", "edited", "dropped"), "下書きの答えを受ける（K2）")
    return failed

CHECKS = [check_feeds, check_share, check_bot, check_ping, check_whisper, check_stages, check_mic_calls, check_teacher,
          check_snorm_precheck, check_summary, check_search]


def run_all() -> int:
    failed = 0
    saved = (s25pc.S.main, s25pc.S.home)
    for check in CHECKS:
        try:
            failed += check()
        except Exception as error:  # noqa: BLE001 — 1 つが落ちても、ほかは確かめる
            import traceback

            traceback.print_exc()
            failed += say(False, f"{check.__name__} が途中で落ちました: {error!r}")
    s25pc.S.main, s25pc.S.home = saved
    return failed


def main() -> int:
    failed = run_all()
    print("ぜんぶ OK" if not failed else f"NG の数: {failed}", flush=True)
    return failed


if __name__ == "__main__":
    sys.exit(main())
