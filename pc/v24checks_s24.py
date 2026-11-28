"""2026-11-24（s24。担当 P）: 家の PC の分を確かめる（急3・急7・当1・減3・減5・当2・当5・当7・当8・当11・当12）。

    python pc/v24checks_s24.py          （v24checks_s23.py の最後にも呼ばれる。CI の手順を増やさずに動かすため）

本物の HOME・母艦・iPhone・APNs は使わない（一時フォルダに作り物を作る。人の名前は「甲」「乙」などの記号だけ）。確かめること（check_*）:
- 決まり s24rules: same_person_ask・promise_push は初めは false・pc_question_days は 3（仮）・GET /same-person と split の問いを抜く形
- 急3 apns・s24pc: kind urgent の中身（見える知らせ・lifelog.kind/key・1 日 8 回）・合言葉のファイル（32 桁の 16 進）・
  X-LifeLog-Local が違えば 401・同じ key は 24 時間に 1 回（ok true・suppressed）・1 日 8 回を超えたら ok false・中身を出さない設定・
  形の違う体は 400・記録に題・文・key を書かない
- 急7 watchroute: watchDirectLast（預かった時刻・ファイルに残す・時間帯付き ISO）
- 減5 promises: promise_push が無ければ送らない（台帳は残る）・true なら送る
- 当1・減3・当12 s24pc.shape_review: 母艦の問いはそのまま・同じ人かの問いは止める・3 日で閉じる（expires）・閉じた数・
  名前の無い人の問いは行の多い上位 5 人だけ・行の多い順
- 当1 quality: GET /same-person の組を抜く（設定で戻る）
- 当2 s24pc.snorm_rule: 7 晩・毎晩 +0.1・答え 20 で候補
- 当7 s24night: 年表から場面（歩きながら・電車・車・店・自宅・速い移動）・場面ごとの合計
- 当8 s24night: 区切りの選び方（PLAUD が録っている時間だけ）・切れ目の決まり・影の数（作り物の VAD）
- 当11 s24night: PLAUD と合わない組から語の候補（今の辞書の語は外す・2 回以上・5 語まで）
- 当5 s24night: 答えのある組（時計の声に限らない・音声が残っている見本だけ）
- summary.md の「s24 の数」の節が書けること・見回りの軽い分
"""

from __future__ import annotations

import datetime
import io
import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

if "v24s" not in os.environ.get("LOCALAPPDATA", ""):  # 単独で動かすときも、本物の HOME に触れない
    os.environ["LOCALAPPDATA"] = str(Path(tempfile.mkdtemp(prefix="v24s24-local-")))

import apns  # noqa: E402
import promises  # noqa: E402
import quality  # noqa: E402
import s24night  # noqa: E402
import s24pc  # noqa: E402
import s24rules  # noqa: E402
import sameperson  # noqa: E402
import watchroute  # noqa: E402
from v6checks import say  # noqa: E402

TMP = Path(tempfile.mkdtemp(prefix="v24s24-"))
LOGS: list[str] = []


class Fake:
    client_address = ("127.0.0.1", 0)

    def __init__(self, body=b"", headers: dict | None = None) -> None:
        data = json.dumps(body, ensure_ascii=False).encode() if not isinstance(body, bytes) else body
        self.rfile = io.BytesIO(data)
        self.headers = {"Content-Length": str(len(data)), **(headers or {})}
        self.wfile = io.BytesIO()
        self.sent: list = []

    def send_json(self, status: int, body) -> None:
        self.sent = [status, body]

    def discard_body(self) -> None:
        pass


class FakePusher:
    def __init__(self, devices=("dev-0001-aaaa",)) -> None:
        self.sent: list[dict] = []
        self.devices = {d: {} for d in devices}
        self.count: dict = {}
        self.ok = True

    def ready(self) -> bool:
        return True

    def usable(self, device: str) -> bool:
        return device in self.devices

    def allowed(self, device: str, kind: str, now=None) -> bool:
        return self.count.get(device, 0) < 8

    def send(self, kind, devices=None, job=None, respect_limits=True, alert=None, extra=None):
        self.sent.append({"kind": kind, "devices": devices, "alert": alert, "extra": extra})
        out = []
        for d in devices or list(self.devices):
            if self.ok:
                self.count[d] = self.count.get(d, 0) + 1
            out.append({"device": d, "ok": self.ok, "reason": None if self.ok else "作り物の失敗"})
        return out


class Main:
    """s24pc.start に渡す lifelog_pc の代わり"""

    def __init__(self, home: Path, config: dict) -> None:
        self.HOME = home
        self.config = config
        self.App = type("App", (), {"records": None, "jobs": None})()
        self.mothership = type("M", (), {"home": staticmethod(lambda _c: None)})()

    def load_config(self) -> dict:
        return dict(self.config)

    def log(self, text: str) -> None:
        LOGS.append(text)


def write(path: Path, body) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(body, ensure_ascii=False), encoding="utf-8")


def use(home: Path, config: dict) -> Main:
    main = Main(home, config)
    s24pc.S.main, s24pc.S.home, s24pc.S.token = main, home, None
    s24rules.CONFIG = main.load_config
    return main


# MARK: - 決まり


def check_rules() -> int:
    failed = 0
    failed += say(not s24rules.same_person_ask({}) and not s24rules.promise_push({}) and s24rules.question_days({}) == 3
                  and s24rules.same_person_ask({"same_person_ask": True}) and s24rules.promise_push({"promise_push": True})
                  and s24rules.question_days({"pc_question_days": 5}) == 5 and s24rules.question_days({"pc_question_days": 0}) == 3,
                  "決まり: 同じ人かの問い・約束の知らせは初めはオフ・問いは 3 日（仮）")
    body = {"available": True, "days": [{"day": "2026-11-23", "groups": [{"id": "g1"}, {"id": "g2"}]}],
            "across": [{"id": "a"}], "maybe": [{"id": "m"}]}
    held = s24rules.hold_same_person(body, {})
    failed += say(held["available"] is True and held["days"][0]["groups"] == [] and "across" not in held and "maybe" not in held
                  and held["held"] == {"groups": 2, "across": 1, "maybe": 1} and held["ask"] is False
                  and s24rules.hold_same_person(body, {"same_person_ask": True}) is body,
                  "当1: GET /same-person の組を抜く（数は held に・設定で戻る）")
    split = {"version": 1, "items": [{"id": "split-u:1"}]}
    failed += say(s24rules.hold_items(split, {})["items"] == [] and s24rules.hold_items(split, {})["held"] == 1
                  and s24rules.hold_items(split, {"same_person_ask": True}) is split,
                  "当1: 「A の声と B の声は同じ人ですか」（split）も抜く")
    return failed


# MARK: - 急3


def check_urgent() -> int:
    failed = 0
    body = apns.payload("urgent", alert={"title": "録音が止まっています", "body": "時計の区切りが 3 時間届いていません"},
                        extra={"key": "watch-stalled"})
    headers = apns.headers_for("urgent", apns.TOPIC, "t", 1000.0)
    failed += say(body["aps"]["alert"]["title"] == "録音が止まっています" and body["aps"]["sound"] == "default"
                  and body["lifelog"] == {"kind": "urgent", "key": "watch-stalled"} and "content-available" not in body["aps"]
                  and headers["apns-push-type"] == "alert" and headers["apns-priority"] == "10"
                  and apns.LIMITS["urgent"] == ((86400, 8),) and "urgent" in apns.KINDS,
                  "急3: kind urgent は見える知らせ（lifelog.kind・key）・1 日 8 回まで")
    home = TMP / "urgent-home"
    use(home, {})
    token = s24pc.local_token(home)
    again = s24pc.local_token(home)
    failed += say(len(token) == 32 and all(c in "0123456789abcdef" for c in token) and again == token
                  and (home / s24pc.TOKEN_FILE).is_file(), "急3: 合言葉のファイル（32 桁の 16 進・あれば作り直さない）")
    pusher = FakePusher()
    old = s24pc._pusher
    s24pc._pusher = lambda: pusher
    LOGS.clear()
    try:
        request = {"key": "watch-stalled", "title": "録音が止まっています", "body": "秘密の文"}
        h = Fake(request, {s24pc.TOKEN_HEADER: "0" * 32})
        s24pc.http_post(h, "/notify/urgent")
        failed += say(h.sent[0] == 401 and h.sent[1]["ok"] is False and not pusher.sent, "急3: 合言葉が違えば 401（送らない）")
        h = Fake(request)
        s24pc.http_post(h, "/notify/urgent")
        failed += say(h.sent[0] == 401, "急3: 合言葉が無ければ 401")
        h = Fake(request, {s24pc.TOKEN_HEADER: token.upper()})
        s24pc.http_post(h, "/notify/urgent")
        failed += say(h.sent == [200, {"ok": True, "sent": 1, "suppressed": False, "reason": ""}]
                      and pusher.sent[-1]["kind"] == "urgent" and pusher.sent[-1]["extra"] == {"key": "watch-stalled"}
                      and pusher.sent[-1]["alert"]["body"] == "秘密の文", f"急3: 送れたら sent 1（{h.sent}）")
        h = Fake(request, {s24pc.TOKEN_HEADER: token})
        s24pc.http_post(h, "/notify/urgent")
        failed += say(h.sent[1]["ok"] is True and h.sent[1]["sent"] == 0 and h.sent[1]["suppressed"] is True
                      and len(pusher.sent) == 1, "急3: 同じ key は 24 時間に 1 回（ok true・suppressed true）")
        for i in range(7):
            s24pc.send_urgent({"key": f"k{i}", "title": "題", "body": "文"}, pusher)
        capped = s24pc.send_urgent({"key": "k-over", "title": "題", "body": "文"}, pusher)
        failed += say(capped["ok"] is False and capped["suppressed"] is True and "8" in capped["reason"] and pusher.count["dev-0001-aaaa"] == 8,
                      f"急3: 1 端末 1 日 8 回を超えたら送らない（ok false・母艦は別の道へ）（{capped}）")
        later = s24pc.send_urgent({"key": "watch-stalled", "title": "題", "body": "文"}, FakePusher(), now=__import__("time").time() + 86401)
        failed += say(later["sent"] == 1, "急3: 24 時間たてば同じ key でも送る")
        pusher2 = FakePusher()
        pusher2.ok = False
        failed_send = s24pc.send_urgent({"key": "x-fail", "title": "題", "body": "文"}, pusher2)
        state = json.loads((home / "s24" / "urgent.json").read_text(encoding="utf-8"))
        failed += say(failed_send["ok"] is False and failed_send["sent"] == 0 and "x-fail" not in state["keys"],
                      "急3: 送れなかった key は覚えない（次にまた送る）")
        none = s24pc.send_urgent({"key": "y", "title": "題", "body": "文"}, None)
        failed += say(none["ok"] is False and none["suppressed"] is False and none["reason"], "急3: 送る用意が無ければ ok false と理由")
        # 中身を出さない設定（約束の設定の hide_body）
        saved = promises.W
        promises.W = type("W", (), {"settings": staticmethod(lambda: {"hide_body": True})})()
        hidden = FakePusher()
        s24pc.send_urgent({"key": "hide", "title": "題", "body": "秘密の文"}, hidden)
        promises.W = saved
        failed += say(hidden.sent[-1]["alert"]["body"] == s24pc.HIDDEN_BODY, "急3: 「通知に中身を出さない」なら文を出さない")
        bad = []
        for data in (b"not json", json.dumps({"key": "", "title": "t", "body": "b"}).encode(),
                     json.dumps({"key": "k", "title": "t"}).encode(), json.dumps(["k"]).encode()):
            h = Fake(data, {s24pc.TOKEN_HEADER: token})
            s24pc.http_post(h, "/notify/urgent")
            bad.append(h.sent[0])
        big = Fake(b"x" * (s24pc.URGENT_BODY_LIMIT + 1), {s24pc.TOKEN_HEADER: token})
        s24pc.http_post(big, "/notify/urgent")
        failed += say(bad == [400, 400, 400, 400] and big.sent[0] == 413, f"急3: 形の違う体は 400・長すぎれば 413（{bad}・{big.sent[0]}）")
        text = "\n".join(LOGS)
        failed += say("秘密の文" not in text and "watch-stalled" not in text and token not in text and "録音が止まって" not in text,
                      "急3: 記録に題・文・key・合言葉を書かない")
    finally:
        s24pc._pusher = old
    return failed


# MARK: - 急7


def check_direct() -> int:
    failed = 0
    home = TMP / "direct-home"
    home.mkdir(parents=True, exist_ok=True)
    saved = (watchroute.W.main, watchroute.W.last_direct)
    try:
        watchroute.W.main = Main(home, {})
        watchroute.W.last_direct = None
        failed += say(watchroute.last_direct() is None and watchroute.iso_local(None) is None,
                      "急7: まだ預かっていなければ watchDirectLast は null")
        watchroute.note_direct(1795500000.0)
        stamp = watchroute.iso_local(watchroute.last_direct())
        failed += say(watchroute.last_direct() == 1795500000.0 and (home / watchroute.LAST_FILE).is_file()
                      and stamp is not None and stamp[-6] in "+-" and stamp[-3] == ":"
                      and datetime.datetime.fromisoformat(stamp).timestamp() == 1795500000.0,
                      f"急7: 預かった時刻を覚え、時間帯付きの ISO で返す（{stamp}）")
        watchroute.W.last_direct = None
        failed += say(watchroute.last_direct() == 1795500000.0, "急7: 起動し直してもファイルから読む")
    finally:
        watchroute.W.main, watchroute.W.last_direct = saved
    return failed


# MARK: - 減5


def check_promise_push() -> int:
    failed = 0
    with tempfile.TemporaryDirectory() as folder:
        for config, expected in (({}, 0), ({"promise_push": True}, 1)):
            pusher = FakePusher()
            watcher = promises.Watcher(Path(folder), lambda: None, lambda: pusher, LOGS.append, lambda c=config: c)
            watcher.state["settings"] = {"on": True, "claude": True, "hide_body": False}
            watcher.state["items"] = [{"id": "p1", "day": "2026-11-24", "kind": "asked", "who": "甲", "what": "資料を送る",
                                       "due": None, "quote": "資料", "created": watcher.clock(), "alerted": False}]
            pushed = watcher._push_pending()
            failed += say(pushed == expected and len(pusher.sent) == expected
                          and len(watcher.state["items"]) == 1 and watcher.state["items"][0]["alerted"] is bool(expected),
                          f"減5: promise_push {'あり' if expected else '無し'}なら知らせを {'送る' if expected else '送らない（台帳は残る）'}")
        # s38 K38-2（続5）: 仕事の約束（work が true）は promise_push_work が true のときだけ送る
        for config, expected, sent_ids in (({"promise_push": True}, 1, ["p2"]),
                                           ({"promise_push": True, "promise_push_work": True}, 1, ["p1", "p2"])):
            pusher = FakePusher()
            watcher = promises.Watcher(Path(folder), lambda: None, lambda: pusher, LOGS.append, lambda c=config: c)
            watcher.state["settings"] = {"on": True, "claude": True, "hide_body": False}
            now = watcher.clock()
            watcher.state["items"] = [
                {"id": "p1", "day": "2026-11-28", "kind": "asked", "who": "見本さん", "what": "見本の案件 A の資料を送る",
                 "due": None, "quote": "資料", "created": now, "alerted": False, "work": True},
                {"id": "p2", "day": "2026-11-28", "kind": "mine", "who": "", "what": "見本の店を予約する",
                 "due": None, "quote": "予約", "created": now - 1, "alerted": False, "work": False}]
            pushed = watcher._push_pending()
            alerted = sorted(i["id"] for i in watcher.state["items"] if i["alerted"])
            failed += say(pushed == expected and len(pusher.sent) == 1 and alerted == sent_ids
                          and len(watcher.state["items"]) == 2,
                          f"続5: 仕事の約束は {'promise_push_work が true なので送る' if len(sent_ids) == 2 else '送らない（台帳には残る）'}")
        pusher = FakePusher()
        config = {"promise_push": True}
        watcher = promises.Watcher(Path(folder), lambda: None, lambda: pusher, LOGS.append, lambda c=config: c)
        watcher.state["settings"] = {"on": True, "claude": True, "hide_body": False}
        watcher.state["items"] = [{"id": "p3", "day": "2026-11-28", "kind": "asked", "who": "見本さん", "what": "見本の案件 A",
                                   "due": None, "quote": "見本", "created": watcher.clock(), "alerted": False, "work": True}]
        failed += say(watcher._push_pending() == 0 and not pusher.sent and watcher.state["items"][0]["alerted"] is False,
                      "続5: 仕事の約束だけなら何も送らない")
        failed += say(not s24rules.promise_push_work({}) and s24rules.promise_push_work({"promise_push_work": True})
                      and not s24rules.promise_push_work({"promise_push_work": "true"}),
                      "続5: promise_push_work は true のときだけ")
    return failed


# MARK: - 当1・減3・当12


def check_review() -> int:
    failed = 0
    home, base = TMP / "review-home", TMP / "review-base"
    (base / "inbox").mkdir(parents=True, exist_ok=True)
    use(home, {})
    day = datetime.date(2026, 11, 24)
    write(home / "s24" / "top-people.json", {"2026-11-23": {"top": ["人物1", "人物2", "人物3", "人物4", "人物5", "人物6"],
                                                             "counts": {"人物1": 50, "人物2": 40, "人物3": 30, "人物4": 20,
                                                                        "人物5": 10, "人物6": 5}}})

    def spk(n):
        return {"id": f"spk-{n}", "kind": "speaker_line", "person": f"人物{n}", "question": "この声は 甲 さんですか",
                "evidence": [{"text": "…", "ref": f"2026-11-23|{n}"}], "expires": "2026-11-30"}

    mother = {"available": True, "items": [{"id": "m-1", "kind": "place", "expires": "2026-12-31"},
                                           {"id": "m-2", "kind": "voice_pair"}]}
    pc_items = [{"id": "vp-1", "kind": "voice_pair"}, {"id": "split-u:1", "kind": "speaker_split"},
                {"id": "num-1", "kind": "number", "expires": "2026-11-30"}, spk(6), spk(5), spk(1)]
    body = {**mother, "items": mother["items"] + pc_items}
    got = s24pc.shape_review(json.loads(json.dumps(body)), {"m-1", "m-2"}, home, base, {}, day)
    ids = [i["id"] for i in got["items"]]
    failed += say(ids[:2] == ["m-1", "m-2"] and "vp-1" not in ids and "split-u:1" not in ids and "num-1" in ids,
                  f"当1: 母艦の問いはそのまま・家の PC の「同じ人か」の問いは止める（{ids}）")
    failed += say("spk-6" not in ids and ids.index("spk-1") < ids.index("spk-5") and got["pc_held"]["top"] == 1
                  and got["pc_held"]["same"] == 2, f"当12: 名前の無い人の問いは行の多い上位 5 人だけ・多い順（{ids}）")
    num = next(i for i in got["items"] if i["id"] == "num-1")
    failed += say(num["expires"] == "2026-11-26" and next(i for i in got["items"] if i["id"] == "m-1")["expires"] == "2026-12-31",
                  f"減3: 家の PC の問いの expires は出した日から 3 日（{num['expires']}）・母艦の問いは変えない")
    on = s24pc.shape_review(json.loads(json.dumps(body)), {"m-1", "m-2"}, home, base, {"same_person_ask": True}, day)
    failed += say({"vp-1", "split-u:1"} <= {i["id"] for i in on["items"]}, "当1: same_person_ask が true なら出す")
    later = s24pc.shape_review(json.loads(json.dumps(body)), {"m-1", "m-2"}, home, base, {}, day + datetime.timedelta(days=2))
    gone = s24pc.shape_review(json.loads(json.dumps(body)), {"m-1", "m-2"}, home, base, {}, day + datetime.timedelta(days=3))
    failed += say("num-1" in [i["id"] for i in later["items"]] and "num-1" not in [i["id"] for i in gone["items"]]
                  and [i["id"] for i in gone["items"]][:2] == ["m-1", "m-2"], "減3: 3 日目までは出し、4 日目に閉じる（母艦の問いは残す）")
    with (base / "inbox" / "app_feedback.jsonl").open("a", encoding="utf-8") as handle:
        handle.write(json.dumps({"kind": "review", "id": "spk-5", "answer": "yes"}) + "\n")
    closed = s24pc.close_questions(home, base, {}, day + datetime.timedelta(days=3))
    daily = quality.read_daily(home)["days"]
    # 出した問い: num-1・spk-1・spk-5（答えた）・vp-1 と split-u:1（設定で戻したときに出した）→ 閉じたのは 4
    failed += say(closed == 4 and daily["2026-11-27"]["pc_questions_closed"] == 4
                  and s24pc.close_questions(home, base, {}, day + datetime.timedelta(days=3)) == 0,
                  f"減3: 答えの無いまま閉じた数を quality-daily に（答えたものは数えない・二度は数えない）（{closed}）")
    counted = s24pc.top_people({"conversations": [{"lines": [{"speaker": "人物2"}, {"speaker": "人物2"}, {"speaker": "人物9"},
                                                             {"speaker": "自分"}, {"speaker": "人物9", "media": "テレビ"}]},
                                                  {"media": "ラジオ", "lines": [{"speaker": "人物9"}]}]})
    failed += say(counted["top"][:2] == ["人物2", "人物9"] and counted["counts"] == {"人物2": 2, "人物9": 1},
                  f"当12: 行の多い人物N を数える（テレビなどの声・自分は数えない）（{counted}）")
    return failed


def check_same_person_http() -> int:
    failed = 0
    home = TMP / "same-home"
    saved = (quality.State.home, s24rules.CONFIG)
    try:
        quality.State.home = home
        people = [{"id": "1", "name": "人物1", "lines": 3, "seconds": 9.0, "samples": []},
                  {"id": "2", "name": "人物2", "lines": 3, "seconds": 9.0, "samples": []}]
        sameperson.save_day(home, {"day": "2026-11-23", "generated_at": "x", "groups": [{"id": "g1", "score": 0.9, "people": people}]})

        def get(config):
            s24rules.CONFIG = lambda: config
            h = Fake()
            quality.http_get(h, type("U", (), {"path": "/same-person", "query": ""})())
            return h.sent

        off, on = get({}), get({"same_person_ask": True})
        failed += say(off[0] == 200 and off[1].get("ask") is False and all(not d["groups"] for d in off[1].get("days") or [])
                      and on[0] == 200 and "ask" not in on[1] and any(d["groups"] for d in on[1].get("days") or []),
                      f"当1: GET /same-person は初めは組を出さない・設定で戻る（{off[0]}・{on[0]}）")
    finally:
        quality.State.home, s24rules.CONFIG = saved
    return failed


# MARK: - 当2


def check_snorm_rule() -> int:
    failed = 0
    today = datetime.date(2026, 11, 30)
    daily = {(today - datetime.timedelta(days=i)).isoformat(): {"snorm_auc": 0.8, "raw_auc": 0.4, "snorm_pairs": 22}
             for i in range(1, 8)}
    failed += say(s24pc.snorm_rule(daily, today)["candidate"] is True, "当2: 7 晩・毎晩 s-norm ≥ 今 + 0.1・答え 20 以上で候補")
    short = {k: v for k, v in list(daily.items())[:6]}
    weak = {**daily, (today - datetime.timedelta(days=3)).isoformat(): {"snorm_auc": 0.45, "raw_auc": 0.4, "snorm_pairs": 22}}
    few = {k: {**v, "snorm_pairs": 12} for k, v in daily.items()}
    failed += say(not s24pc.snorm_rule(short, today)["candidate"] and not s24pc.snorm_rule(weak, today)["candidate"]
                  and not s24pc.snorm_rule(few, today)["candidate"] and s24pc.snorm_rule(short, today)["nights"] == 6,
                  "当2: 6 晩・差が 0.1 未満の晩がある・答えが 20 未満なら候補にしない")
    return failed


# MARK: - 当7・当8・当11・当5


def check_night() -> int:
    failed = 0
    base, home = TMP / "night-base", TMP / "night-home"
    day = "2026-11-23"
    write(base / "digests" / "timeline" / f"{day}.json", {"rows": [
        {"time": "10:00", "end": "10:20", "lane": "会話", "text": "たぶん乙駅近く（歩きながら） 話題（10行）"},
        {"time": "11:00", "end": "11:30", "lane": "会話", "text": "丙町付近（電車・車で） 話題（5行）"},
        {"time": "12:00", "end": "13:00", "lane": "位置", "text": "たぶん甲ラーメン店（1時間）", "place": "甲ラーメン店"},
        {"time": "14:00", "end": "15:00", "lane": "位置", "text": "移動中（名前の無い地点 3・約60.0km）", "place": None},
        {"time": "15:00", "end": "15:30", "lane": "位置", "text": "移動中（名前の無い地点 1・約1.0km）", "place": None},
        {"time": "22:00", "end": "24:00", "lane": "位置", "text": "自宅（2時間）", "place": "自宅"}]})
    spans = s24night.timeline_spans(base, day)
    at = lambda hh, mm: datetime.datetime(2026, 11, 23, hh, mm).timestamp()  # noqa: E731
    scenes = [s24night.scene_of(at(h, m), "a.m4a", spans, {}) for h, m in ((10, 5), (11, 10), (12, 30), (14, 30), (15, 10), (23, 0), (8, 0))]
    failed += say(scenes == ["outside", "vehicle", "shop", "vehicle", "outside", "home", "other"]
                  and s24night.scene_of(at(23, 0), "b.m4a", spans, {"b.m4a": "train"}) == "train",
                  f"当7: 年表から場面（歩きながら・電車・車・店・速い移動・遅い移動・自宅・ほか。POST /jobs の scene が先）（{scenes}）")
    total = s24night.scene_total({"d1": {"shop": {"lines": 6, "chars": 60, "matched": 30}},
                                  "d2": {"shop": {"lines": 6, "chars": 40, "matched": 30}, "home": {"lines": 3, "chars": 30, "matched": 30}}})
    failed += say(total["shop"]["match"] == 0.6 and total["shop"]["days"] == 2 and total["home"]["match"] is None,
                  "当7: 日を合わせて場面ごとの割合（行が少なければ —）")
    # 当8
    failed += say(s24night.merge_regions([(1.0, 1.2), (1.4, 1.6), (5.0, 5.1)], 10.0) == [(0.9, 1.7000000000000002)]
                  and s24night.subtract([(0.0, 10.0)], [(2.0, 3.0)]) == [(0.0, 2.0), (3.0, 10.0)]
                  and abs(s24night.plaud_in([(100.0, 110.0, "あいうえおかきくけこ")], 105.0, 120.0) - 5.0) < 1e-9,
                  "当8: 切れ目をつなぐ・短いものを捨てる・今の声を引く・PLAUD の字数を重なりで分ける")
    log = home / "log.txt"
    log.parent.mkdir(parents=True, exist_ok=True)
    log.write_text("2026-11-23 10:01:00 後で受け取る文字起こし 20261123-100000-w.m4a: 300 秒（声 0 秒）→ 0 行、1.0 秒\n"
                   "2026-11-23 10:06:00 後で受け取る文字起こし 20261123-100500-w.m4a: 300 秒（声 90 秒）→ 20 行、9.0 秒\n"
                   "2026-11-23 10:11:00 後で受け取る文字起こし 20261123-101000-w.m4a: 300 秒（声 30 秒）→ 5 行、9.0 秒\n"
                   "2026-11-23 10:16:00 後で受け取る文字起こし 20261123-200000-w.m4a: 300 秒（声 0 秒）→ 0 行、1.0 秒\n",
                   encoding="utf-8")
    for name in ("20261123-100000-w.m4a", "20261123-100500-w.m4a", "20261123-101000-w.m4a", "20261123-200000-w.m4a"):
        (home / "audio" / day / name).parent.mkdir(parents=True, exist_ok=True)
        (home / "audio" / day / name).write_bytes(b"x")
    jobs = s24night.read_log_jobs(home, "2026-11-20")
    start = s24night.chunk_epoch("20261123-100000-w.m4a")
    low, normal = s24night.pick_chunks(home, jobs, set(), datetime.date(2026, 11, 24),
                                       lambda n: s24night.chunk_epoch(n) < start + 3600)
    failed += say(jobs["20261123-100000-w.m4a"] == {"dur": 300, "voice": 0, "lines": 0} and low == ["20261123-100000-w.m4a"]
                  and normal == ["20261123-100500-w.m4a"], f"当8: 声なし側とふだんの区切り（PLAUD が録っている時間だけ・声 10% は使わない）（{low}・{normal}）")
    saved = (s24night.make_vad, s24night.load_audio, s24night.plaud_day)
    try:
        import numpy as np

        s24night.load_audio = lambda _data: np.zeros(300 * s24night.RATE, np.float32)
        s24night.make_vad = lambda _model, t: (lambda _audio, t=t: [] if t >= 0.5 else [(10.0, 20.0)] if t >= 0.35 else [(10.0, 20.0), (100.0, 110.0)])
        s24night.plaud_day = lambda _h, _b, _d, _c: ([(start + 12.0, start + 18.0, "あ" * 30)], [(start - 60, start + 400)])
        state: dict = {}
        info = s24night.measure_vad(home, base, home / "vad.onnx", state, datetime.date(2026, 11, 24), jobs=jobs)
        total = s24night.vad_total(state)
        low_t = total["low"]
        failed += say(info["added"] >= 1 and abs(low_t["0.35"]["new_s"] - 10.2) < 0.01 and low_t["0.35"]["new_plaud_chars"] == 30
                      and abs(low_t["0.2"]["new_empty_s"] - 10.2) < 0.01 and low_t["0.5"]["new_s"] == 0,
                      f"当8: しきい値を下げた影で、拾える字数（PLAUD）とごみ（PLAUD に話の無い秒）を数える（{low_t}）")
        again = s24night.measure_vad(home, base, home / "vad.onnx", state, datetime.date(2026, 11, 24), jobs=jobs)
        failed += say(again["added"] == 0, "当8: 測った区切りは測り直さない")
    finally:
        s24night.make_vad, s24night.load_audio, s24night.plaud_day = saved
    # 当11
    write(base / "state" / "misheard_pairs.json", {"items": [
        {"day": "2026-11-22", "app": "きょうはこうやまにいく", "plaud": "きょうは甲山にいく"},
        {"day": "2026-11-23", "app": "あしたもこうやまでね", "plaud": "あしたも甲山でね"},
        {"day": "2026-11-23", "app": "おつかわにいった", "plaud": "乙川にいった"},
        {"day": "2026-11-23", "app": "おつかわでたべた", "plaud": "乙川でたべた"},
        {"day": "2026-11-23", "app": "へいでらまで", "plaud": "丙寺まで"}]})
    write(base / "state" / "vocab_for_app.json", {"items": [{"word": "乙川", "variants": []}]})
    got = s24night.vocab_candidates(home, base, datetime.date(2026, 11, 24))
    words = [i["word"] for i in got["items"]]
    failed += say(words == ["甲山"] and got["items"][0]["count"] == 2 and got["items"][0]["days"] == 2
                  and got["pairs_seen"] == 5 and "仮" in got["note"],
                  f"当11: PLAUD と合わない組から語の候補（今の辞書の語・1 回だけの語は外す）（{len(words)} 語）")
    # 当5
    write(base / "inbox" / "app_feedback.jsonl", None)
    (base / "inbox" / "app_feedback.jsonl").write_text(
        "\n".join(json.dumps(r) for r in [{"kind": "same_person", "id": "sp-a", "value": "merged"},
                                           {"kind": "same_person", "id": "sp-b", "value": "different"},
                                           {"kind": "same_person", "id": "sp-c", "value": "different"}]) + "\n", encoding="utf-8")
    sample = lambda audio, a, b: {"audio": audio, "start": a, "end": b}  # noqa: E731
    write(home / "same-person" / "2026-11-23.json", {"groups": [
        {"id": "sp-a", "score": 0.7, "people": [{"samples": [sample("20261123-100000-w.m4a", 1, 4)]},
                                                {"samples": [sample("20261123-100500-w.m4a", 1, 4)]}]},
        {"id": "sp-b", "score": 0.6, "people": [{"samples": [sample("20261123-101000-w.m4a", 1, 4)]},
                                                {"samples": [sample("20261123-100000.m4a", 1, 4)]}]},
        {"id": "sp-c", "score": 0.5, "people": [{"samples": [sample("20261123-100000-w.m4a", 1, 4)]},
                                                {"samples": [sample("20261123-999999-w.m4a", 1, 4)]}]}]})
    pairs = s24night.answer_pairs(home, base, lambda name: name != "20261123-999999-w.m4a")
    failed += say(sorted(p["id"] for p in pairs) == ["sp-a", "sp-b"] and s24night.self_pairs(home, []) == [],
                  "当5: 答えのある組（時計の声に限らない・音声の無い見本の組は使わない）・登録の声が無ければ 0 組")
    return failed


# MARK: - summary.md・見回り


def check_summary() -> int:
    failed = 0
    home = TMP / "review-home"
    use(home, {})
    worries, lines = s24pc.summary_lines(None)
    text = "\n".join(lines)
    failed += say(not any("数えられませんでした" in line for line in lines) and "急ぎの知らせ" in text and "止めている" in text
                  and "閉じた数" in text and "切り替え" in text, f"summary.md の「s24 の数」の節（{len(lines)} 行）")
    done = s24pc.light(home, None, None, {}, datetime.date(2026, 11, 28))
    failed += say(done.get("top") == 0 and isinstance(done.get("closed"), int), f"見回りの軽い分（{done}）")
    return failed


CHECKS = [check_rules, check_urgent, check_direct, check_promise_push, check_review, check_same_person_http, check_snorm_rule,
          check_night, check_summary]


def run_all() -> int:
    failed = 0
    saved = (s24pc.S.main, s24pc.S.home, s24pc.S.token, s24rules.CONFIG)
    for check in CHECKS:
        try:
            failed += check()
        except Exception as error:  # noqa: BLE001 — 1 つが落ちても、ほかは確かめる
            import traceback

            traceback.print_exc()
            failed += say(False, f"{check.__name__} が途中で落ちました: {error!r}")
    s24pc.S.main, s24pc.S.home, s24pc.S.token, s24rules.CONFIG = saved
    # s25（2026-11-24。担当 P）: K1〜K4・K6・K7・連16・早1〜3・大3・大4・大9・活1（CI の手順を増やさずに動かす）
    import v25checks_s25p

    failed += v25checks_s25p.run_all()
    return failed


def main() -> int:
    failed = run_all()
    print("ぜんぶ OK" if not failed else f"NG の数: {failed}", flush=True)
    return failed


if __name__ == "__main__":
    sys.exit(main())
