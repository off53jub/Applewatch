"""LifeLog PC 版 9 を確かめる（--check-v9 から呼ぶ。本物のモデル・本物の Ollama・ふだんの置き場所は使わない）。

- 職場の会話の印: POST /records/<日> の "work" を読み、会話ごとに 職場・職場ではない・分からない（印の無い日）を付ける
- 聞いて直す: 自信の低い行で PC に音声がある行の並び（新しい日から）・文を直す・話し手を変える・合っている・
  PC の音声から材料を作る・iPhone から同じ行の材料が届いても2重に入らない・見守りの画面の材料の数と入口
- 記録を読む MCP サーバー: 作り物の記録（職場の印あり・なし・分からない を混ぜる）で、どの道具からも
  職場の会話と分からない会話が出ないこと・外した数を返すこと・HOME に何も書かないこと・標準出力に MCP の答えしか出ないこと
人の名前と会話はすべて作り物。確かめるときは、本物の HOME に書かない（isolate_home）。
"""

from __future__ import annotations

import base64
import io
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import wave
from pathlib import Path

import numpy as np

import dashboard
import lifelog_mcp
import records
import semantic
import v6checks
import v7checks_records
from v7checks_records import raw_call

KEY = "check-key"
# 職場の会話・分からない会話にだけ出てくる言葉（どの道具の答えにも出てはいけない）
SECRETS = ("ヒミツ案件", "極秘の打ち合わせ", "社長サン", "本社ビル", "合併の話", "ナイショ")


def say(ok: bool, text: str) -> int:
    print(("OK " if ok else "NG ") + text, flush=True)
    return 0 if ok else 1


def run(main) -> int:
    main.isolate_home()
    failed = 0
    failed += check_isolated(main)
    failed += check_work_parse()
    failed += check_review(main)
    failed += check_mcp(main)
    print(("NG の数: " + str(failed)) if failed else "版 9: 全部 OK", flush=True)
    return failed


def check_isolated(main) -> int:
    home = Path(main.HOME)
    ok = main._isolated is not None and home.is_relative_to(main._isolated) and home != Path(main._START_HOME) \
        and Path(main.PERSONAL_DATA).is_relative_to(home) and os.environ.get("LOCALAPPDATA") == str(main._isolated)
    return say(ok, f"確かめるときは、HOME と材料の置き場所を一時のフォルダに替える（{home.name}）")


# MARK: - 作り物の記録

z = records.iso_ms


def ms(day: str, clock: str) -> int:
    return records.parse_time(f"{day}T{clock}.000Z", "t")


def jst(value: int) -> str:
    moment = time.gmtime(value // 1000 + 9 * 3600)
    return time.strftime("%Y-%m-%dT%H:%M:%S", moment) + f".{value % 1000:03d}+09:00"


def line(at: int, speaker: str | None, text: str, **extra) -> dict:
    body = {"time": z(at), "speaker": speaker, "text": text}
    if speaker == "自分":
        body["speakerID"] = "me"
    body.update(extra)
    return body


def mcp_days() -> dict[str, dict]:
    """MCP を確かめる作り物の記録: 職場の印あり（職場と職場ではない）・印なし（分からない）・印が空（全部職場ではない）"""
    a, b, c = "2026-11-05", "2026-11-06", "2026-11-07"
    a1, a2, a3 = ms(a, "00:30:00"), ms(a, "09:00:00"), ms(a, "11:00:00")
    days = {}
    days[a] = {"conversations": [
        {"start": z(a1), "end": z(a1 + 600_000), "title": "極秘の打ち合わせ", "points": ["ヒミツ案件を進める"],
         "place": "本社ビル", "scene": "職場", "closed": True, "lines": [
             line(a1 + 1000, "社長サン", "ヒミツ案件の資料を見せてください"),
             line(a1 + 4000, "田中", "合併の話はまだナイショです"),
             line(a1 + 8000, "自分", "わかりました、温泉の話はまた今度")]},
        {"start": z(a2), "end": z(a2 + 300_000), "title": "家族と週末の相談", "points": ["週末は箱根の温泉"],
         "place": "家", "closed": True, "lines": [
             line(a2 + 1000, "母", "週末は温泉に行こうか"),
             line(a2 + 4000, "自分", "いいね、箱根の温泉がいい"),
             line(a2 + 8000, "母", "お弁当も作ろう")]},
        {"start": z(a3), "end": z(a3 + 120_000), "media": "テレビ", "program": "ニュース", "closed": True, "lines": [
            line(a3 + 1000, "テレビ", "明日は晴れるでしょう", media="テレビ")]}],
        # 職場の印は +09:00 で書いても、同じ時刻なら合う
        "work": [jst(a1)],
        "summary": {"flow": ["ヒミツ案件の打ち合わせ", "家族と温泉の相談"], "decisions": ["合併の話は来週"],
                    "todos": [], "topics": ["温泉"]}}
    b1 = ms(b, "02:00:00")
    days[b] = {"conversations": [
        {"start": z(b1), "end": z(b1 + 300_000), "title": "ナイショの相談", "points": ["本社ビルで会う"], "closed": True,
         "lines": [line(b1 + 1000, "佐藤", "ヒミツ案件は佐藤が持ちます"),
                   line(b1 + 4000, "自分", "温泉の話もしましょう")]}],
        "summary": {"flow": ["ナイショの相談"], "decisions": [], "todos": [], "topics": []}}  # work の項目が無い（古い iPhone）
    c1, c2 = ms(c, "03:00:00"), ms(c, "10:00:00")
    days[c] = {"conversations": [
        {"start": z(c1), "end": z(c1 + 300_000), "title": "田中さんと釣りの話", "points": ["日曜に釣り"], "closed": True,
         "lines": [line(c1 + 1000, "田中", "日曜は海に釣りに行きませんか"),
                   line(c1 + 4000, "自分", "いいですね、温泉にも寄りましょう")]},
        {"start": z(c2), "end": z(c2 + 300_000), "title": "母と夕ごはん", "points": [], "closed": True,
         "lines": [line(c2 + 1000, "母", "夕ごはんは鍋にしよう"),
                   line(c2 + 4000, "自分", "鍋なら白菜を買ってくる")]}],
        "work": [], "summary": {"flow": ["田中さんと釣りの話", "母と夕ごはん"], "decisions": [], "todos": [],
                                "topics": ["釣り", "鍋"]}}
    return days


def semantic_items(days: dict[str, dict]) -> list[dict]:
    """iPhone の indexItems と同じ形。iPhone の work の印は、わざと全部 false にする（記録の印だけでも外せるか）"""
    items = []
    for day, body in days.items():
        for c in body["conversations"]:
            if c.get("media"):
                continue
            start = records.parse_time(c["start"], "start")
            for item in c["lines"]:
                at = records.parse_time(item["time"], "time")
                items.append({"id": f"{day}|{at}", "day": day, "time": at / 1000, "speaker": item.get("speaker"),
                              "text": item["text"], "work": False, "conversation": f"{day}|{start}"})
    # PC に記録が無い日の行（分からない）
    items.append({"id": "2026-10-01|1", "day": "2026-10-01", "time": 1759276800.0, "speaker": "社長サン",
                  "text": "ヒミツ案件の温泉旅行", "work": False, "conversation": "2026-10-01|1759276800000"})
    return items


# MARK: - A. 職場の会話の印


def check_work_parse() -> int:
    failed = 0
    days = mcp_days()
    a = records.parse_record(days["2026-11-05"])
    b = records.parse_record(days["2026-11-06"])
    c = records.parse_record(days["2026-11-07"])
    flags = ([x["work"] for x in a["conversations"]], [x["work"] for x in b["conversations"]],
             [x["work"] for x in c["conversations"]])
    ok = flags == ([True, False, False], [None], [False, False]) and b["work"] is None and c["work"] == []
    failed += say(ok, f"work の印: 印のある会話は職場・無い会話は職場ではない・work の項目が無い日は分からない {flags}")
    bad = []
    for value in ("2026-11-05", [123], ["きのう"], {"x": 1}):
        try:
            records.parse_record({"conversations": [], "work": value})
            bad.append(False)
        except ValueError:
            bad.append(True)
    failed += say(all(bad), f"work が並びでない・日時が読めないときは 400 にする {bad}")
    summary = records.summarize(a, [0, 0], 0.0)
    unknown = records.summarize(b, [0, 0], 0.0)
    failed += say(summary.get("work") == 1 and unknown.get("work") is None,
                  f"日の一覧に職場の会話の数を残す（印の無い日は分からない）: {summary.get('work')}・{unknown.get('work')}")
    return failed


# MARK: - B. 聞いて直す


def tone(seconds: float, rate: int = 16000) -> np.ndarray:
    t = np.arange(int(seconds * rate)) / rate
    return (0.2 * np.sin(2 * np.pi * (220 + 40 * np.floor(t)) * t)).astype(np.float32)


def wav_bytes(samples: np.ndarray, rate: int = 16000) -> bytes:
    out = io.BytesIO()
    with wave.open(out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes((np.clip(samples, -1, 1) * 32767).astype("<i2").tobytes())
    return out.getvalue()


def review_days() -> dict[str, dict]:
    day, newer = "2026-11-07", "2026-11-08"
    c1 = ms(day, "01:00:00")
    body = {"conversations": [
        {"start": z(c1), "end": z(c1 + 120_000), "title": "田中さんと釣りの話", "closed": True, "lines": [
            line(c1 + 1000, "田中", "日曜は海に釣りに行きませんか", speakerID="5", audio="A.wav", offset=1.0, end=3.0,
                 confidence=0.3),
            line(c1 + 4000, "自分", "いいですね", audio="A.wav", offset=4.0, confidence=0.8,
                 votes={"haas": "いいですね", "reazon": "いいですか"}),
            line(c1 + 6000, "田中", "朝は早いです", speakerID="5", audio="A.wav", offset=6.0, confidence=0.9,
                 speakerDoubt="7"),
            line(c1 + 8000, "田中", "道具は貸します", speakerID="5", audio="A.wav", offset=8.0, confidence=0.95),
            line(c1 + 10000, "自分", "助かります", audio="A.wav", offset=10.0, confidence=0.2, checked=True),
            line(c1 + 12000, "自分", "PC に音声が無い行", audio="Z.wav", offset=1.0, confidence=0.1),
            line(c1 + 14000, "佐藤", "同じ票なら選ばない", audio="A.wav", offset=14.0, confidence=0.9,
                 votes={"haas": "同じ票なら、選ばない", "reazon": "同じ票なら選ばない。"})]},
        {"start": z(c1 + 600_000), "end": z(c1 + 700_000), "media": "テレビ", "closed": True, "lines": [
            line(c1 + 601_000, "テレビ", "テレビの行", media="テレビ", audio="A.wav", offset=2.0, confidence=0.1)]}],
        "work": [], "audioNames": {"A.wav": "20261107-010000.wav"}}
    c2 = ms(newer, "01:00:00")
    other = {"conversations": [
        {"start": z(c2), "end": z(c2 + 60_000), "title": "母と買い物", "closed": True, "lines": [
            line(c2 + 1000, "母", "白菜を買ってきて", audio="20261108-010000.wav", offset=2.0, end=4.0, confidence=0.4)]}],
        "work": []}
    return {day: body, newer: other}


class Ctx:
    def __init__(self, main, folder: Path) -> None:
        self.main = main
        self.folder = folder
        self.logged: list[str] = []
        self.store = records.RecordStore(folder, self.capture, lambda: {})
        self.store.sampler = main.review_sample
        self.port = 0
        self.basic = {"Authorization": "Basic " + base64.b64encode(f"だれでも:{KEY}".encode()).decode()}
        self.bearer = {"Authorization": f"Bearer {KEY}"}

    def capture(self, message: str) -> None:
        self.logged.append(message)
        print("  記録: " + message, flush=True)

    def call(self, method: str, path: str, body=None, headers: dict | None = None):
        data = body if body is None or isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode("utf-8")
        status, raw, got = raw_call(self.port, method, path, data, headers)
        if "json" in got.get("content-type", ""):
            try:
                return status, json.loads(raw or b"{}")
            except ValueError:
                return status, raw
        return status, raw.decode("utf-8", "replace")

    def review(self, day: str, moment: int, kind: str, value=None, mark: bool = True):
        body = {"day": day, "time": moment, "kind": kind}
        if kind == "text":
            body["text"] = value
        if kind == "speaker":
            body["speaker"] = value
        headers = {**self.basic, "Content-Type": "application/json"}
        if mark:
            headers[dashboard.HEADER] = "1"
        return self.call("POST", "/dash/records/review", body, headers)


def check_review(main) -> int:
    failed = 0
    saved = (main.App.records, main.App.jobs, main.App.semantic, getattr(main.Handler, "key", None), main.log)
    data = Path(main.PERSONAL_DATA)
    with tempfile.TemporaryDirectory() as folder:
        ctx = Ctx(main, Path(folder))
        audio = tone(20.0)
        for day, name in (("2026-11-07", "20261107-010000.wav"), ("2026-11-08", "20261108-010000.wav")):
            (Path(folder) / "audio" / day).mkdir(parents=True, exist_ok=True)
            (Path(folder) / "audio" / day / name).write_bytes(wav_bytes(audio))
        server = None
        try:
            main.log = ctx.capture
            main.Handler.key = KEY
            main.App.records = ctx.store
            main.App.jobs = None
            main.App.semantic = None
            server = main.Server(("127.0.0.1", 0), main.Handler)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            ctx.port = server.server_address[1]
            for day, body in review_days().items():
                status, reply = ctx.call("POST", f"/records/{day}", body, ctx.bearer)
                failed += say(status == 200, f"POST /records/{day}（work つき）: {status} {reply}")
            day = "2026-11-07"
            c1 = ms(day, "01:00:00")
            t = {"low": c1 + 1000, "votes": c1 + 4000, "doubt": c1 + 6000, "same": c1 + 14000}
            newer = ms("2026-11-08", "01:00:00") + 1000
            items, total = ctx.store.review_queue()
            order = [(i["day"], i["line"]["time"], tuple(i["reasons"])) for i in items]
            want = [("2026-11-08", newer, ("low",)), (day, t["low"], ("low",)), (day, t["votes"], ("votes",)),
                    (day, t["doubt"], ("speaker",))]
            failed += say(order == want and total == 4,
                          "並び: 新しい日から・確からしさが低い／票が食い違う／話し手に「？」の行だけ"
                          f"（手で直した行・音声の無い行・テレビ・句読点だけ違う票は出さない） {order}")
            # 画面
            status, html = ctx.call("GET", "/dash/records/review", headers=ctx.basic)
            positions = [html.find(f"data-time='{m}'") for m in (newer, t["low"], t["votes"], t["doubt"])]
            ok = status == 200 and all(p > 0 for p in positions) and positions == sorted(positions) \
                and "▶ 聞く" in html and "合っている" in html and "data-audio='20261107-010000.wav'" in html \
                and "data-start='1.00'" in html and "data-stop='3.30'" in html and "<b id='rv-left'>4</b>" in html \
                and f"data-time='{t['same']}'" not in html and "（300 個で学び直せます）" in html
            failed += say(ok, f"聞いて直すの画面: 新しい日から・▶ で聞く所（区切りの名前と位置）・残りの数・材料の数 {status}")
            status, index = ctx.call("GET", "/dash/records", headers=ctx.basic)
            failed += say(status == 200 and "/dash/records/review" in index, "記録の一覧から「聞いて直す」に入れる")
            status, page = ctx.call("GET", f"/dash/records/{day}", headers=ctx.basic)
            failed += say(status == 200 and "職場" not in page.split("<h1>")[1].split("</p>")[0]
                          and "？</span>" in page, "1日の画面: 職場の印が届いた日は注意を出さない・話し手の「？」を出す")
            # 断り方
            checks = {"印なし": ctx.review(day, t["low"], "ok", mark=False)[0],
                      "種類": ctx.review(day, t["low"], "bad")[0],
                      "無い行": ctx.review(day, t["low"] + 1, "ok")[0],
                      "同じ文": ctx.review(day, t["low"], "text", "日曜は海に釣りに行きませんか")[0]}
            failed += say(checks == {"印なし": 403, "種類": 400, "無い行": 400, "同じ文": 400}, f"聞いて直すの断り方 {checks}")
            before = len(main.read_samples(data))
            # 文を直す
            status, reply = ctx.review(day, t["low"], "text", "日曜は海へ釣りに行きませんか")
            rows = main.read_samples(data)
            row = rows[-1] if rows else {}
            with wave.open(str(data / row.get("audio", "x")), "rb") as w:
                seconds = w.getnframes() / w.getframerate()
            span = records.sample_span(1.0, 3.0, "日曜は海へ釣りに行きませんか")
            edits = ctx.call("GET", "/edits?after=0", headers=ctx.bearer)[1].get("edits", [])
            ok = status == 200 and reply.get("done") is True and reply.get("sample", {}).get("added") is True \
                and len(rows) == before + 1 and row.get("text") == "日曜は海へ釣りに行きませんか" \
                and row.get("source", {}).get("origin") == "pc-review" and row["source"].get("audio") == "20261107-010000.wav" \
                and abs(seconds - (span[1] - span[0])) < 0.01 and span == (0.7, 3.0) \
                and [e["kind"] for e in edits] == ["text"] and edits[0]["text"] == "日曜は海へ釣りに行きませんか"
            failed += say(ok, f"文を直す: iPhone に渡す直しを作り、PC の音声の {span[0]:.1f}〜{span[1]:.1f} 秒を材料に足す"
                              f"（{seconds:.2f} 秒）・次の行へ {reply.get('done')}")
            # 合っている
            status, reply = ctx.review(day, t["votes"], "ok")
            rows = main.read_samples(data)
            edits = ctx.call("GET", "/edits?after=0", headers=ctx.bearer)[1].get("edits", [])
            ok = status == 200 and reply.get("done") and reply.get("sample", {}).get("added") and len(rows) == before + 2 \
                and rows[-1]["text"] == "いいですね" and rows[-1]["source"]["answer"] == "ok" and len(edits) == 1 \
                and ctx.store.edits.answers().get((day, t["votes"])) == "ok"
            failed += say(ok, "合っている: 答えを残して並びから外し、材料に足す（iPhone には送らない）")
            again = ctx.review(day, t["votes"], "ok")[1]
            failed += say(again.get("sample", {}).get("added") is False and len(main.read_samples(data)) == before + 2,
                          f"同じ行に2度答えても、材料は2重に入らない（{again.get('sample', {}).get('reason')}）")
            # 話し手を変える（「？」だけの行）
            status, reply = ctx.review(day, t["doubt"], "speaker", "自分")
            edits = ctx.call("GET", "/edits?after=0", headers=ctx.bearer)[1].get("edits", [])
            ok = status == 200 and reply.get("done") is True and reply.get("sample") is None \
                and len(main.read_samples(data)) == before + 2 and edits[-1]["kind"] == "speaker" \
                and edits[-1]["speakerID"] == "me"
            failed += say(ok, "話し手を変える: iPhone に渡す直しを作る・「？」だけの行は並びから外す・材料にはしない")
            name_new = ctx.review(day, t["doubt"], "speaker", "新しい人")[0]
            failed += say(name_new == 400, f"聞いて直すからも、新しい名前は作れない（{name_new}）")
            items, total = ctx.store.review_queue()
            failed += say([(i["day"], i["line"]["time"]) for i in items] == [("2026-11-08", newer)] and total == 1,
                          f"答えた行は並びから外れる（残り {total}）")
            # iPhone から同じ行の材料が届く（iPhone は、行の前後 1 秒を切り出して、ずらした位置を送ってくる）
            clip = wav_bytes(audio[0:int(4.0 * 16000)])
            status, sent = ctx.call("POST", "/train-sample?start=0.70&end=3.00&text=" + quote("日曜は海へ釣りに行きませんか"),
                                    clip, {**ctx.bearer, "Content-Type": "audio/wav"})
            status2, sent2 = ctx.call("POST", "/train-sample?start=0.70&end=3.00&text=" + quote("日曜は海で釣りをしませんか"),
                                      clip, {**ctx.bearer, "Content-Type": "audio/wav"})
            ok = status == 200 and sent.get("added") is False and status2 == 200 and sent2.get("added") is True \
                and len(main.read_samples(data)) == before + 3
            failed += say(ok, f"iPhone から同じ行・同じ文の材料が届いても2重に入らない（{sent}）・文が違えば足す（{sent2}）")
            # 逆に、iPhone が先に送った行を、あとで PC で「合っている」
            clip2 = wav_bytes(audio[int(0.7 * 16000):int(5.0 * 16000)])
            status, first = ctx.call("POST", "/train-sample?start=1.00&end=3.30&text=" + quote("白菜を買ってきて")
                                     + "&audio=20261108-010000.wav&offset=2.0", clip2, {**ctx.bearer, "Content-Type": "audio/wav"})
            status, reply = ctx.review("2026-11-08", newer, "ok")
            rows = main.read_samples(data)
            ok = first.get("added") is True and reply.get("done") and reply.get("sample", {}).get("added") is False \
                and len(rows) == before + 4 and rows[-1].get("source") == {"audio": "20261108-010000.wav", "offset": 2.0}
            failed += say(ok, f"iPhone が先に送った行を PC で答えても2重に入らない（{reply.get('sample', {}).get('reason')}）")
            # 見守りの画面
            personal = main.personal_info()
            page_plain = dashboard.render({"version": 8, "personal": personal})
            page_ops = "".join(dashboard.ops_sections({"train": {"state": "待っています"}, "gpu": {}, "devices": [],
                                                       "push": {}, "feedback": {}}, personal))
            left = 300 - personal["count"]
            ok = personal["need"] == 300 and personal["count"] == before + 4 \
                and f"あと <b>{left}</b> 個で学び直せます" in page_plain and "/dash/records/review" in page_plain \
                and f"あと <b>{left}</b> 個で学び直せます" in page_ops and "/dash/records/review" in page_ops
            failed += say(ok, f"見守りの画面の学び直しの所に、材料 {personal['count']} 個・あと {left} 個・「聞いて直す」への入口")
            full = dashboard.personal_text({"count": 320, "need": 300})
            failed += say("学び直せる数です" in full, "300 個を超えたら「学び直せる数です」と出す")
            words = ("日曜", "釣り", "いいですね", "田中", "自分", "白菜", "母", KEY)
            ok = not any(w in m for m in ctx.logged for w in words)
            failed += say(ok, f"記録（log）に会話の文・人の名前・合言葉が出ていない（{len(ctx.logged)} 行）")
        finally:
            if server is not None:
                server.shutdown()
                server.server_close()
            main.App.records, main.App.jobs, main.App.semantic, main.Handler.key, main.log = saved
    return failed


def quote(text: str) -> str:
    from urllib.parse import quote as q

    return q(text, safe="")


# MARK: - C. 記録を読む MCP サーバー


class FakeEmbedder:
    model = semantic.EMBED_MODEL

    def models(self) -> list[str]:
        return ["bge-m3:latest"]

    def embed(self, texts: list[str]) -> np.ndarray:
        return semantic.normalize(np.stack([v6checks.fake_vector(t) for t in texts])) if texts \
            else np.zeros((0, 0), dtype=np.float32)


def snapshot(folder: Path, skip: tuple[str, ...] = ()) -> dict[str, tuple[int, int]]:
    out = {}
    for path in sorted(folder.rglob("*")):
        if path.is_file() and not path.name.endswith(skip):
            stat = path.stat()
            out[str(path.relative_to(folder))] = (stat.st_size, stat.st_mtime_ns)
    return out


def make_home(folder: Path, days: dict[str, dict]) -> None:
    (folder / "records").mkdir(parents=True, exist_ok=True)
    for day, body in days.items():
        (folder / "records" / f"{day}.json").write_text(json.dumps(body, ensure_ascii=False), encoding="utf-8")
    index = semantic.SemanticIndex(folder / "semantic.db", FakeEmbedder(), lambda m: None)
    index.index(semantic_items(days))


def leaks(text: str) -> list[str]:
    return [s for s in SECRETS if s in text]


TOOL_CALLS = [
    ("list_conversations", {}),
    ("list_conversations", {"day": "2026-11-05"}),
    ("list_conversations", {"day": "2026-11-06"}),
    ("list_conversations", {"day": "2026-11-07"}),
    ("list_conversations", {"from": "2026-11-01", "to": "2026-11-30", "limit": 300}),
    ("search_text", {"query": "ヒミツ案件"}),
    ("search_text", {"query": "温泉"}),
    ("search_text", {"query": "社長サン"}),
    ("search_text", {"query": "の"}),
    ("search_meaning", {"query": "ヒミツ案件の資料", "k": 50}),
    ("search_meaning", {"query": "温泉に行く", "k": 50}),
    ("search_meaning", {"query": "合併の話はまだナイショ", "k": 50}),
    ("conversations_with", {"name": "社長"}),
    ("conversations_with", {"name": "田中"}),
    ("conversations_with", {"name": "佐藤"}),
    ("conversations_with", {"name": "母"}),
]


def check_mcp(main) -> int:
    """--exclude-work のとき職場の会話が漏れないことと、既定（2026-11-07 本人の決定で全部返す）で職場の会話も返ること"""
    lifelog_mcp.INCLUDE_WORK = False
    try:
        failed = check_mcp_excluding(main)
    finally:
        lifelog_mcp.INCLUDE_WORK = True
    with tempfile.TemporaryDirectory() as folder:
        home = Path(folder) / "LifeLogPC"
        make_home(home, mcp_days())
        answer = lifelog_mcp.Tools(home, FakeEmbedder()).call("search_text", {"query": "ヒミツ案件"})
        text = json.dumps(answer, ensure_ascii=False)
        failed += say("ヒミツ案件" in text and answer.get("excluded_work", 0) == 0,
                      "既定では職場の会話も返す（本人の決定。--exclude-work で外せる）")
    return failed


def check_mcp_excluding(main) -> int:
    failed = 0
    with tempfile.TemporaryDirectory() as folder:
        home = Path(folder) / "LifeLogPC"
        days = mcp_days()
        make_home(home, days)
        a1 = ms("2026-11-05", "00:30:00")
        a2 = ms("2026-11-05", "09:00:00")
        b1 = ms("2026-11-06", "02:00:00")
        c1 = ms("2026-11-07", "03:00:00")
        before = snapshot(home)
        tools = lifelog_mcp.Tools(home, FakeEmbedder())
        answers = {}
        for i, (name, args) in enumerate(TOOL_CALLS):
            answers[i] = tools.call(name, args)
        for ident in (f"2026-11-05|{a1}", f"2026-11-06|{b1}", f"2026-11-05|{a2}", f"2026-11-07|{c1}"):
            answers[ident] = tools.call("get_conversation", {"id": ident})
        everything = json.dumps(answers, ensure_ascii=False)
        found = leaks(everything)
        failed += say(not found, f"どの道具からも、職場の会話と分からない会話の中身・見出し・要点・相手・場所が出ない"
                                 f"（{len(answers)} 回呼んだ。出てしまった言葉 {found}）")
        listing = answers[0]
        ids = [c["id"] for c in listing["conversations"]]
        ok = listing["excluded_work"] == 2 and ids == [f"2026-11-07|{c1}", f"2026-11-07|{ms('2026-11-07', '10:00:00')}",
                                                       f"2026-11-05|{a2}", f"2026-11-05|{ms('2026-11-05', '11:00:00')}"]
        failed += say(ok, f"日付で会話の一覧: 職場ではない会話だけ（新しい日から）・外した数 {listing['excluded_work']}")
        ok = "day_summary" not in answers[1] and "day_summary" not in answers[2] \
            and answers[3].get("day_summary", {}).get("topics") == ["釣り", "鍋"] \
            and answers[2]["conversations"] == [] and answers[2]["excluded_work"] == 1
        failed += say(ok, "1日のまとめは、職場の会話も分からない会話も無い日だけ返す・印の無い日は全部外す")
        texts = answers[6]["hits"]
        ok = answers[5]["hits"] == [] and answers[7]["hits"] == [] and {h["day"] for h in texts} == {"2026-11-05", "2026-11-07"} \
            and len(texts) == 3 and answers[5]["excluded_work"] == 2 and all("audio" not in h and "offset" not in h for h in texts)
        failed += say(ok, f"言葉で探す: 職場の会話の言葉では何も出ない・ほかの会話の「温泉」は出る（{len(texts)} 行。音声は返さない）")
        meaning = answers[9]
        warm = answers[10]
        ok = all(h["day"] in ("2026-11-05", "2026-11-07") for h in meaning["hits"] + warm["hits"]) \
            and meaning["excluded_work"] >= 4 and any("温泉" in h["text"] for h in warm["hits"]) \
            and all("before" in h and "after" in h for h in warm["hits"])
        failed += say(ok, f"意味で探す: iPhone の印が false でも、記録の印（職場・分からない・記録の無い日）で外す"
                          f"（外した数 {meaning['excluded_work']}・{len(warm['hits'])} 件）")
        people = [answers[i] for i in (12, 13, 14, 15)]
        ok = people[0]["conversations"] == [] and people[0]["excluded_work"] == 2 \
            and [c["id"] for c in people[1]["conversations"]] == [f"2026-11-07|{c1}"] \
            and people[2]["conversations"] == [] \
            and [c["id"] for c in people[3]["conversations"]][-1] == f"2026-11-05|{a2}"
        failed += say(ok, "人の名前で探す: 職場の会話にだけ出る人は何も出ない・田中さんは職場ではない会話だけ")
        hidden = [answers[f"2026-11-05|{a1}"], answers[f"2026-11-06|{b1}"]]
        shown = answers[f"2026-11-07|{c1}"]
        ok = all(h["conversation"] is None and h["excluded_work"] == 1 for h in hidden) \
            and len(shown["conversation"]["lines"]) == 2 and all("audio" not in x for x in shown["conversation"]["lines"])
        failed += say(ok, "1つの会話の中身: 職場の会話と分からない会話は断る・ほかは行を返す（音声は返さない）")
        errors = []
        for name, args in (("search_text", {}), ("list_conversations", {"day": "11/07"}), ("get_conversation", {"id": "x"}),
                           ("conversations_with", {"name": "自分"}), ("nothing", {})):
            try:
                tools.call(name, args)
                errors.append(False)
            except (ValueError, LookupError):
                errors.append(True)
        failed += say(all(errors), f"おかしな引数は断る {errors}")
        failed += say(snapshot(home) == before, "道具を呼んでも、HOME のファイルは1つも増えず、変わらない（読むだけ）")
        # PC が動いているとき（semantic.db に -wal がある）も、読むだけで探せる
        writer = sqlite3_open(home / "semantic.db")
        try:
            during = snapshot(home, skip=("-shm",))
            again = lifelog_mcp.Tools(home, FakeEmbedder()).call("search_meaning", {"query": "温泉に行く"})
            ok = (home / "semantic.db-wal").exists() and again["hits"] and not leaks(json.dumps(again, ensure_ascii=False)) \
                and snapshot(home, skip=("-shm",)) == during
            failed += say(ok, f"PC が semantic.db を開いているあいだも、読むだけで意味で探せる（{len(again['hits'])} 件）")
        finally:
            writer.close()
        failed += check_mcp_stdio(main, home)
    return failed


def sqlite3_open(path: Path):
    import sqlite3

    db = sqlite3.connect(str(path))
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("CREATE TABLE IF NOT EXISTS keep_open (x INTEGER)")
    db.execute("INSERT INTO keep_open VALUES (1)")
    db.commit()
    return db


def check_mcp_stdio(main, home: Path) -> int:
    """MCP の通り道（標準入出力の JSON-RPC）で、Claude Code と同じように呼ぶ。作り物の Ollama を使う。"""
    failed = 0
    v6checks.FakeOllama.models = ["bge-m3:latest"]
    v6checks.FakeOllama.allow_pull = False
    fake = v6checks.ThreadingHTTPServer(("127.0.0.1", 0), v6checks.FakeOllama)
    threading.Thread(target=fake.serve_forever, daemon=True).start()
    before = snapshot(home)
    try:
        if getattr(sys, "frozen", False):
            command = [sys.executable, "--mcp"]
        else:
            command = [sys.executable, str(Path(main.__file__).resolve()), "--mcp"]
        command += ["--exclude-work", "--home", str(home), "--ollama-url", f"http://127.0.0.1:{fake.server_address[1]}"]
        messages = [{"jsonrpc": "2.0", "id": 1, "method": "initialize",
                     "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                                "clientInfo": {"name": "check", "version": "1"}}},
                    {"jsonrpc": "2.0", "method": "notifications/initialized"},
                    {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
                    {"jsonrpc": "2.0", "id": 3, "method": "ping"}]
        for i, (name, args) in enumerate(TOOL_CALLS):
            messages.append({"jsonrpc": "2.0", "id": 100 + i, "method": "tools/call",
                             "params": {"name": name, "arguments": args}})
        messages.append({"jsonrpc": "2.0", "id": 200, "method": "tools/call",
                         "params": {"name": "get_conversation", "arguments": {"id": f"2026-11-05|{ms('2026-11-05', '00:30:00')}"}}})
        messages.append({"jsonrpc": "2.0", "id": 201, "method": "tools/call", "params": {"name": "write_record", "arguments": {}}})
        messages.append({"jsonrpc": "2.0", "id": 202, "method": "no/such"})
        data = b"".join(json.dumps(m, ensure_ascii=False).encode("utf-8") + b"\n" for m in messages) + b"{oops\n"
        env = dict(os.environ, PYTHONIOENCODING="utf-8")
        done = subprocess.run(command, input=data, capture_output=True, timeout=180, env=env)
        out_lines = [x for x in done.stdout.split(b"\n") if x.strip()]
        replies = []
        try:
            replies = [json.loads(x.decode("utf-8")) for x in out_lines]
            parsed = True
        except (UnicodeDecodeError, ValueError):
            parsed = False
        by_id = {r.get("id"): r for r in replies if isinstance(r, dict)}
        stdout = done.stdout.decode("utf-8", "replace")
        stderr = done.stderr.decode("utf-8", "replace")
        init = by_id.get(1, {}).get("result", {})
        names = [t["name"] for t in by_id.get(2, {}).get("result", {}).get("tools", [])]
        ok = done.returncode == 0 and parsed and len(replies) == len(messages) - 1 + 1 \
            and init.get("protocolVersion") == "2025-06-18" and "tools" in init.get("capabilities", {}) \
            and names == ["list_conversations", "search_text", "search_meaning", "conversations_with", "get_conversation", "search_digest", "get_digest"] \
            and by_id.get(3, {}).get("result") == {} and by_id.get(201, {}).get("error", {}).get("code") == -32602 \
            and by_id.get(202, {}).get("error", {}).get("code") == -32601 and by_id.get(None, {}).get("error", {}).get("code") == -32700
        failed += say(ok, f"MCP の通り道: 標準出力は MCP の答えだけ（{len(replies)} 行・すべて JSON）・initialize・tools/list "
                          f"{names}・ping・知らない道具と method は断る（終わりの番号 {done.returncode}）")
        calls = [by_id.get(100 + i, {}).get("result", {}) for i in range(len(TOOL_CALLS))]
        texts = [json.loads(c["content"][0]["text"]) for c in calls if c.get("content") and not c.get("isError")]
        meaning = [t for t, (name, _) in zip(texts, TOOL_CALLS) if name == "search_meaning"]
        ok = len(texts) == len(TOOL_CALLS) and not leaks(stdout) and not leaks(stderr) \
            and any(h for m in meaning for h in m["hits"]) \
            and json.loads(by_id[200]["result"]["content"][0]["text"])["conversation"] is None
        failed += say(ok, f"MCP の通り道からも、職場の会話と分からない会話は出ない（意味で探すは作り物の Ollama で "
                          f"{sum(len(m['hits']) for m in meaning)} 件。出てしまった言葉 {leaks(stdout) + leaks(stderr)}）")
        words = ("田中", "母", "温泉", "釣り", "佐藤")
        failed += say(not any(w in stderr for w in words), f"知らせ（標準エラー）に会話の文や人の名前を書かない（{len(stderr.splitlines())} 行）")
        failed += say(snapshot(home) == before, "MCP サーバーを動かしても、HOME は変わらない（読むだけ）")
    finally:
        fake.shutdown()
        fake.server_close()
    return failed
