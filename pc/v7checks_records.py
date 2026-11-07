"""LifeLog PC 版 7（records）を確かめる（--check-v7-records）。本物のモデル・本物の Ollama・ふだんの置き場所は使わない。

- 日時の読み方（ミリ秒なし・時差つき）・日の名前・記録の中身の読み方
- POST /records/<日>（置く・1つ前を残す・断り方）と features
- 記録の画面（合言葉・中身・HTML として扱わない・キャッシュさせない・文字で探す・意味で探す（作り物の Ollama））
- 直す（文・話し手。選べる名前・番号の決め方・重なったときの扱い）と GET /edits・POST /edits/ack
- 音声の保存（DELETE /jobs で移す・起動し直しても残す・7 日の片付け・30 日と大きさの上限・Range で返す）
--try-records のときは、一時のフォルダと作り物の記録で起動する（モデルを読み込まない）。
人の名前はすべて作り物（田中・佐藤・鈴木）。
"""

from __future__ import annotations

import base64
import http.client
import io
import json
import math
import os
import sys
import tempfile
import threading
import time
import wave
from pathlib import Path
from urllib.parse import quote

import dashboard
import jobqueue
import records
import recordsui
import semantic
import v6checks

KEY = "check-key"
DAY = "2026-11-07"


def say(ok: bool, text: str) -> int:
    print(("OK " if ok else "NG ") + text, flush=True)
    return 0 if ok else 1


def raw_call(port: int, method: str, path: str, body: bytes | None = None,
             headers: dict | None = None) -> tuple[int, bytes, dict]:
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
    try:
        connection.request(method, path, body=body, headers=headers or {})
        response = connection.getresponse()
        return response.status, response.read(), {k.lower(): v for k, v in response.getheaders()}
    except OSError as error:
        return 0, repr(error).encode(), {}
    finally:
        connection.close()


# MARK: - 作り物の記録


def _at(base: int, seconds: float) -> int:
    return base + int(round(seconds * 1000))


def _plain(ms: int) -> str:
    """ミリ秒なしの書き方（ms は秒ちょうどにしておく）"""
    return records.iso_ms(ms)[:-5] + "Z"


def _jst(ms: int) -> str:
    """+09:00 の時差つきの書き方"""
    moment = time.gmtime(ms // 1000 + 9 * 3600)
    return time.strftime("%Y-%m-%dT%H:%M:%S", moment) + f".{ms % 1000:03d}+09:00"


def sample(base: int, audio: str = "A.m4a", job: str = "20261107-090000.m4a") -> tuple[dict, dict]:
    """作り物の1日分（ConversationLog.SyncDay の形）と、行の時刻（名前 → ミリ秒）。日時の書き方をわざと混ぜる。
    base は最初の会話の始まり（秒ちょうど）。"""
    z = records.iso_ms
    c1, c2, c3 = base, _at(base, 3.5 * 3600), _at(base, 11 * 3600)
    t = {"hello": _at(c1, 1), "tanaka": _at(c1, 4), "reply": _at(c1, 7.2), "plain": _at(c1, 12), "sato7": _at(c1, 15.5),
         "sato8": _at(c2, 2), "unnamed": _at(c2, 5), "lunch": _at(c2, 8), "tv": _at(c3, 3), "dup": _at(c3, 9)}
    conversations = [
        {"start": z(c1), "end": z(_at(c1, 600)), "docIndex": 1, "title": "来月の予算の相談",
         "points": ["来月の予算を見直す", "資料は金曜までに送る"], "place": "会社", "scene": "職場", "event": "定例会",
         "closed": True, "rev": 3, "heartRate": 82, "heartRateMax": 101, "tense": True,
         "lines": [
             {"time": z(t["hello"]), "speaker": "自分", "speakerID": "me", "text": "おはようございます", "audio": audio,
              "offset": 1.0, "confidence": 0.95},
             {"time": _jst(t["tanaka"]), "speaker": "田中", "speakerID": "5", "text": "来月の予算の資料はできましたか",
              "audio": audio, "offset": 4.0, "end": 6.5, "confidence": 0.62, "marked": True,
              "history": [{"at": z(_at(c1, 100)), "by": "言語モデルの直し", "from": "来月の余算の資料はできましたか"}]},
             {"time": z(t["reply"]), "speaker": "自分", "speakerID": "me", "text": "まだです。金曜までに送ります",
              "audio": audio, "offset": 7.2, "confidence": 0.3},
             {"time": _plain(t["plain"]), "speaker": "田中", "speakerID": "5", "text": "わかりました、待っています",
              "audio": audio, "offset": 12.0, "checked": True},
             {"time": z(t["sato7"]), "speaker": "佐藤", "speakerID": "7", "text": "<script>alert(1)</script> 予算は足りますか",
              "audio": audio, "offset": 15.5, "confidence": 0.8, "votes": {"haas": "予算は足りますか"}}]},
        {"start": _jst(c2), "end": z(_at(c2, 300)), "docIndex": 50, "title": "昼ごはん", "points": [],
         "movement": "歩きながら", "closed": True,
         "lines": [
             {"time": z(t["sato8"]), "speaker": "佐藤", "speakerID": "8", "text": "駅前のラーメン屋に行こう", "audio": "B.m4a",
              "offset": 2.0},
             {"time": z(t["unnamed"]), "speaker": "人物12", "speakerID": "12", "text": "いいですね", "audio": "B.m4a",
              "offset": 5.0},
             {"time": z(t["lunch"]), "speaker": "自分", "speakerID": "me", "text": "行きましょう", "audio": "B.m4a",
              "offset": 8.0}]},
        {"start": z(c3), "end": z(_at(c3, 120)), "docIndex": 90, "media": "テレビ", "program": "ニュース", "closed": True,
         "lines": [
             {"time": z(t["tv"]), "speaker": "テレビ", "text": "明日は晴れるでしょう", "media": "テレビ",
              "heardSpeaker": "人物13", "heardSpeakerID": "13"},
             {"time": z(t["dup"]), "speaker": "鈴木", "speakerID": "9", "text": "同じ時刻の行その一"},
             {"time": z(t["dup"]), "speaker": "鈴木", "speakerID": "9", "text": "同じ時刻の行その二"}]},
    ]
    body = {"conversations": conversations, "removed": [{"start": z(_at(c1, -3600)), "rev": 2}], "summaryWritten": True,
            "summary": {"flow": ["9:00〜9:10 会社 来月の予算の相談（田中さん）"], "decisions": ["資料は金曜までに送る"],
                        "todos": ["資料を送る"], "topics": ["予算"]},
            "build": 160, "audioNames": {audio: job}}
    return body, t


def index_items(day: str, body: dict) -> list[dict]:
    """iPhone の Pipeline.indexItems と同じ形（意味で探す。テレビの行は入れない）"""
    items = []
    for c in body["conversations"]:
        if c.get("media"):
            continue
        start = records.parse_time(c["start"], "start")
        for line in c["lines"]:
            ms = records.parse_time(line["time"], "time")
            items.append({"id": f"{day}|{ms}", "day": day, "time": ms / 1000, "speaker": line.get("speaker"),
                          "text": line["text"], "work": c.get("scene") == "職場", "conversation": f"{day}|{start}"})
    return items


def tone_wav(seconds: float) -> bytes:
    """1秒ごとに高さの変わる音（再生できるかを試す）"""
    rate = 16000
    frames = bytearray()
    for i in range(int(seconds * rate)):
        pitch = 330 + 110 * (int(i / rate) % 4)
        value = int(0.2 * 32767 * math.sin(2 * math.pi * pitch * i / rate)) if (i % rate) < rate * 0.6 else 0
        frames += value.to_bytes(2, "little", signed=True)
    out = io.BytesIO()
    with wave.open(out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(bytes(frames))
    return out.getvalue()


# MARK: - まとめて動かす


def run(main) -> int:
    failed = 0
    failed += check_times()
    failed += check_parse()
    failed += check_edit_rules()
    failed += check_server(main)
    failed += check_audio(main)
    print(("NG の数: " + str(failed)) if failed else "版 7（records）: 全部 OK", flush=True)
    return failed


def check_times() -> int:
    failed = 0
    want = records.parse_time("2026-11-07T06:58:25.123Z", "t")
    import datetime

    exact = int(datetime.datetime(2026, 11, 7, 6, 58, 25, 123000, tzinfo=datetime.timezone.utc).timestamp() * 1000)
    forms = {"ミリ秒つき": want, "ミリ秒なし": records.parse_time("2026-11-07T06:58:25Z", "t"),
             "+09:00": records.parse_time("2026-11-07T15:58:25.123+09:00", "t"),
             "+0900・ミリ秒なし": records.parse_time("2026-11-07T15:58:25+0900", "t"),
             "-05:00": records.parse_time("2026-11-07T01:58:25.123-05:00", "t"),
             "細かい秒": records.parse_time("2026-11-07T06:58:25.1239876Z", "t"),
             "小文字の z": records.parse_time("2026-11-07t06:58:25.123z", "t")}
    ok = want == exact and forms["ミリ秒なし"] == exact - 123 and forms["+09:00"] == exact \
        and forms["+0900・ミリ秒なし"] == exact - 123 and forms["-05:00"] == exact and forms["細かい秒"] == exact \
        and forms["小文字の z"] == exact and records.iso_ms(exact) == "2026-11-07T06:58:25.123Z" \
        and records.iso_ms(exact - 123) == "2026-11-07T06:58:25.000Z"
    failed += say(ok, f"日時の読み方: {forms} → 書き方 {records.iso_ms(exact)}")
    refused = []
    for bad in (783000000.0, "2026-11-07 06:58:25", "2026-02-30T00:00:00Z", "きのう", None, "2026-11-07T06:58:25+25:00"):
        try:
            records.parse_time(bad, "t")
        except ValueError as error:
            refused.append(str(error)[:12])
    ok = len(refused) == 6
    failed += say(ok, f"読めない日時は断る（数・時差なし・無い日・文字・null・時差がおかしい）: {len(refused)} 個")
    days = {d: records.valid_day(d) for d in ("2026-11-07", "2026-13-01", "2026-11-7", "../2026-11", "1999-01-01",
                                              "2026-02-29", "2024-02-29", 20261107)}
    ok = days == {"2026-11-07": True, "2026-13-01": False, "2026-11-7": False, "../2026-11": False, "1999-01-01": False,
                  "2026-02-29": False, "2024-02-29": True, 20261107: False}
    failed += say(ok, f"日の名前: {days}")
    names = {n: records.audio_day(n, 0) for n in ("20261107-090000.m4a", "20261107-090000-w.m4a", "20261399-0.m4a")}
    ok = names["20261107-090000.m4a"] == "2026-11-07" and names["20261107-090000-w.m4a"] == "2026-11-07" \
        and names["20261399-0.m4a"] == time.strftime("%Y-%m-%d", time.localtime(0)) \
        and not records.safe_audio_name("CON") and not records.safe_audio_name("nul.m4a") \
        and not records.safe_audio_name("a.") and not records.safe_audio_name("../a.m4a") \
        and records.safe_audio_name("20261107-090000-w.m4a")
    failed += say(ok, f"音声の置き場所の日と名前: {names}")
    return failed


def check_parse() -> int:
    failed = 0
    base = records.parse_time(f"{DAY}T00:00:00Z", "t")
    body, t = sample(base)
    parsed = records.parse_record(body)
    lines = [line for c in parsed["conversations"] for line in c["lines"]]
    by_time = {line["time"]: line for line in lines}
    ok = len(parsed["conversations"]) == 3 and parsed["lines"] == 11 and by_time[t["tanaka"]]["speaker"] == "田中" \
        and by_time[t["plain"]]["time"] == t["plain"] and by_time[t["tanaka"]]["marked"] \
        and by_time[t["plain"]]["checked"] and by_time[t["tanaka"]]["edited"] == 1 \
        and parsed["audio_names"] == {"A.m4a": "20261107-090000.m4a"} and parsed["summary"]["todos"] == ["資料を送る"] \
        and records.people(parsed["conversations"][0]) == ["田中", "佐藤"] and records.people(parsed["conversations"][2]) == []
    failed += say(ok, f"記録の中身を読む: 会話 {len(parsed['conversations'])}・行 {parsed['lines']}"
                      f"（ミリ秒なし・+09:00 の行も同じ時刻に）")
    errors = {}
    cases = {"conversations なし": {"removed": []},
             "文が数": {"conversations": [{"start": records.iso_ms(base), "lines": [{"time": records.iso_ms(base), "text": 3}]}]},
             "話し手が数": {"conversations": [{"start": records.iso_ms(base), "lines": [
                 {"time": records.iso_ms(base), "text": "a", "speaker": 5}]}]},
             "日時が数": {"conversations": [{"start": 784000000.5, "lines": []}]},
             "消した会話の日時": {"conversations": [], "removed": [{"start": "?", "rev": 1}]},
             "audioNames が並び": {"conversations": [], "audioNames": ["a"]},
             "まとまりでない": ["a"]}
    for name, case in cases.items():
        try:
            records.parse_record(case)
            errors[name] = None
        except ValueError as error:
            errors[name] = str(error)
    ok = all(errors.values()) and "ISO 8601" in errors["日時が数"] and "conversations[0].start" in errors["日時が数"]
    failed += say(ok, f"おかしな記録は、どこがおかしいかを言って断る: {errors}")
    return failed


# MARK: - 直しの決まり（重なったとき）


def check_edit_rules() -> int:
    failed = 0
    with tempfile.TemporaryDirectory() as folder:
        store = records.EditStore(Path(folder) / "edits.db")
        line = {"text": "元の文", "speaker": "田中", "speakerID": "5"}
        a = store.create(DAY, 1000, "text", dict(line), {"text": "直した文1"}, now=1)["edit"]
        b = store.create(DAY, 1000, "text", dict(line), {"text": "直した文2"}, now=2)["edit"]
        rows = {r["id"]: r for r in store.for_day(DAY)}
        ok = rows[a["id"]]["status"] == "superseded" and rows[b["id"]]["base"] == line and b["text"] == "直した文2" \
            and [r["id"] for r in store.pending(0, now=3)] == [b["id"]]
        failed += say(ok, "iPhone が読みに来る前に同じ行の文を2回直したら、新しいほうだけ残し、元は記録の文のまま")
        # b は渡した（sent）ので、次の直しは b の後に続ける
        c = store.create(DAY, 1000, "text", dict(line), {"text": "直した文3"}, now=4)["edit"]
        ok = c["base"]["text"] == "直した文2" and {r["id"]: r["status"] for r in store.for_day(DAY)}[b["id"]] == "pending"
        failed += say(ok, f"iPhone が読みに来た直しの後は、その直しの後の文を元にする: {c['base']}")
        # 話し手の直しは、まだ当てていない文の直しの後の文を元にする
        d = store.create(DAY, 1000, "speaker", dict(line), {"speaker": "自分", "speakerID": "me"}, now=5)["edit"]
        ok = d["base"] == {"text": "直した文3", "speaker": "田中", "speakerID": "5"} and d["speakerID"] == "me"
        failed += say(ok, f"話し手を変えるときの元: {d['base']}")
        # 読みに来る前の文の直し c を置き換えると、後に続く話し手の直し d の元も直す
        e = store.create(DAY, 1000, "text", dict(line), {"text": "直した文4"}, now=6)
        rows = {r["id"]: r for r in store.for_day(DAY)}
        pending = [r["id"] for r in store.pending(c["id"] - 1, now=7)]
        ok = rows[c["id"]]["status"] == "superseded" and rows[d["id"]]["base"]["text"] == "直した文2" \
            and e["edit"]["base"] == {"text": "直した文2", "speaker": "自分", "speakerID": "me"} \
            and pending == [d["id"], e["edit"]["id"]] and e["replaced"] == [c["id"]]
        failed += say(ok, f"置き換えたあとの順と元: 残り {pending}、話し手の直しの元 {rows[d['id']]['base']['text']}")
        # 元の文に戻すと、置き換えるだけで新しい直しは作らない（まだ読みに来ていないとき）
        f1 = store.create(DAY, 2000, "text", dict(line), {"text": "いったん直した"}, now=8)["edit"]
        back = store.create(DAY, 2000, "text", dict(line), {"text": "元の文"}, now=9)
        try:
            store.create(DAY, 2000, "text", dict(line), {"text": "元の文"}, now=10)
            same = False
        except ValueError as error:
            same = "変わっていません" in str(error)
        ok = back["edit"] is None and back["replaced"] == [f1["id"]] and "取り消しました" in back["message"] and same
        failed += say(ok, f"元の文に戻す: {back['message']}・同じ文は「変わっていません」")
        # 記録があとから変わっても、まだ当てていない直しのつながりは前の元のまま（iPhone が全部飛ばす）
        g = store.create(DAY, 3000, "text", dict(line), {"text": "直したG"}, now=11)["edit"]
        changed = {"text": "iPhone で変わった文", "speaker": "田中", "speakerID": "5"}
        h = store.create(DAY, 3000, "speaker", changed, {"speaker": "自分", "speakerID": "me"}, now=12)["edit"]
        ok = {r["id"]: r for r in store.for_day(DAY)}[g["id"]]["base"] == line and h["base"]["text"] == "直したG"
        failed += say(ok, "記録があとから変わっても、PC の古い見立てで iPhone の新しい文を上書きしない（元は変えない）")
        # 知らせ
        counts = store.ack([{"id": b["id"], "status": "applied", "reason": None},
                            {"id": d["id"], "status": "skipped", "reason": "iPhone の記録が先に変わっていました"},
                            {"id": 99999, "status": "failed", "reason": None}], now=13)
        rows = {r["id"]: r for r in store.for_day(DAY)}
        left = [r["id"] for r in store.pending(0, now=14)]
        ok = counts == {"applied": 1, "skipped": 1, "failed": 0, "unknown": 1} and rows[b["id"]]["status"] == "applied" \
            and rows[d["id"]]["reason"] == "iPhone の記録が先に変わっていました" and b["id"] not in left and d["id"] not in left \
            and e["edit"]["id"] in left
        failed += say(ok, f"知らせ: {counts}、まだ当てていない {left}")
        public = records.EditStore.public(rows[d["id"]])
        ok = set(public) == {"id", "day", "time", "kind", "base", "text", "speaker", "speakerID", "created"} \
            and public["text"] is None and public["speaker"] == "自分" and public["time"] == "1970-01-01T00:00:01.000Z" \
            and records.EditStore.public(rows[b["id"]])["speaker"] is None
        failed += say(ok, f"GET /edits の形: {json.dumps(public, ensure_ascii=False)}")
        # 起動し直しても番号は使い直さない
        again = records.EditStore(Path(folder) / "edits.db")
        k = again.create(DAY, 4000, "text", dict(line), {"text": "起動し直した後"}, now=15)["edit"]
        failed += say(k["id"] > h["id"], f"起動し直しても直しの番号は増える一方: {h['id']} → {k['id']}")
    return failed


# MARK: - 受け付けと画面


class Context:
    def __init__(self, main, folder: Path) -> None:
        self.main = main
        self.folder = folder
        self.logged: list[str] = []
        self.config: dict = {}
        self.store = records.RecordStore(folder, self.capture, lambda: self.config)
        self.port = 0
        self.basic = {"Authorization": "Basic " + base64.b64encode(f"だれでも:{KEY}".encode()).decode()}
        self.bearer = {"Authorization": f"Bearer {KEY}"}

    def capture(self, message: str) -> None:
        self.logged.append(message)
        print("  記録: " + message, flush=True)

    def call(self, method: str, path: str, body=None, headers: dict | None = None) -> tuple[int, object, dict]:
        data = body if body is None or isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode("utf-8")
        status, raw, got = raw_call(self.port, method, path, data, headers)
        kind = got.get("content-type", "")
        if "json" in kind:
            try:
                return status, json.loads(raw or b"{}"), got
            except ValueError:
                return status, raw, got
        if kind.startswith("text/"):
            return status, raw.decode("utf-8", "replace"), got
        return status, raw, got

    def page(self, path: str) -> tuple[int, str, dict]:
        status, body, got = self.call("GET", path, headers=self.basic)
        return status, body if isinstance(body, str) else "", got

    def edit(self, day: str, moment: int, kind: str, value, mark: bool = True) -> tuple[int, dict]:
        body = {"day": day, "time": moment, "kind": kind, ("text" if kind == "text" else "speaker"): value}
        headers = {**self.basic, "Content-Type": "application/json"}
        if mark:
            headers[dashboard.HEADER] = "1"
        status, reply, _ = self.call("POST", "/dash/records/edit", body, headers)
        return status, reply if isinstance(reply, dict) else {}


def check_server(main) -> int:
    failed = 0
    saved = (main.App.records, main.App.semantic, main.App.jobs, getattr(main.Handler, "key", None), main.log)
    v6checks.FakeOllama.models = ["bge-m3:latest"]
    v6checks.FakeOllama.allow_pull = False
    fake = v6checks.ThreadingHTTPServer(("127.0.0.1", 0), v6checks.FakeOllama)
    threading.Thread(target=fake.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory() as folder:
        ctx = Context(main, Path(folder))
        server = None
        try:
            main.log = ctx.capture
            main.Handler.key = KEY
            main.App.records = ctx.store
            main.App.jobs = None
            index = semantic.SemanticIndex(Path(folder) / "semantic.db",
                                           semantic.OllamaEmbedder(f"http://127.0.0.1:{fake.server_address[1]}"), ctx.capture)
            index.available(force=True)
            main.App.semantic = index
            server = main.Server(("127.0.0.1", 0), main.Handler)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            ctx.port = server.server_address[1]
            failed += check_records_post(ctx)
            failed += check_pages(ctx, index)
            failed += check_edits_http(ctx)
            ok = not any(word in line for line in ctx.logged
                         for word in ("田中", "佐藤", "鈴木", "人物12", "予算", "ラーメン", "おはよう", "直した文", "check-key"))
            failed += say(ok, f"記録（log）に会話の文・人の名前・合言葉が出ていない（{len(ctx.logged)} 行）")
            # 起動し直したとき
            again = records.RecordStore(Path(folder), ctx.capture)
            days = [d["day"] for d in again.days()]
            names = {s["name"]: s["id"] for s in again.speakers()}
            ok = days == ["2026-11-08", DAY] and names.get("田中") == "5" and "佐藤" in names and names["佐藤"] is None \
                and list(names)[0] == "自分" and names["自分"] == "me" and list(names)[-1] == "人物12" and "テレビ" not in names
            failed += say(ok, f"起動し直しても日の一覧と話し手の名前が戻る: {days}・{names}")
        finally:
            if server is not None:
                server.shutdown()
                server.server_close()
            main.App.records, main.App.semantic, main.App.jobs, main.Handler.key, main.log = saved
            fake.shutdown()
            fake.server_close()
    return failed


def check_records_post(ctx: Context) -> int:
    failed = 0
    base = records.parse_time(f"{DAY}T00:00:00Z", "t")
    body, _ = sample(base)
    first = ctx.call("POST", f"/records/{DAY}", body, ctx.bearer)
    path = ctx.folder / "records" / f"{DAY}.json"
    prev = ctx.folder / "records" / f"{DAY}.prev.json"
    sent = json.dumps(body, ensure_ascii=False).encode("utf-8")
    again = ctx.call("POST", f"/records/{DAY}", body, ctx.bearer)
    no_prev = not prev.exists()
    changed = json.loads(json.dumps(body))
    changed["conversations"][1]["title"] = "昼ごはんの相談"
    third = ctx.call("POST", f"/records/{DAY}", changed, ctx.bearer)
    ok = first[:2] == (200, {"ok": True, "conversations": 3, "lines": 11}) and again[0] == 200 and no_prev \
        and third[0] == 200 and prev.read_bytes() == sent and json.loads(path.read_bytes())["conversations"][1]["title"] \
        == "昼ごはんの相談" and "records" in ctx.main.features() and "edits" in ctx.main.features()
    failed += say(ok, f"POST /records/{DAY}: {first[:2]}・同じ中身では1つ前を作らない {no_prev}・"
                      f"変わったら1つ前を {prev.name} に残す・features {[f for f in ctx.main.features() if f in ('records', 'edits')]}")
    # 次の日（ミリ秒なしの日時だけ）
    other, _ = sample(records.parse_time("2026-11-08T00:00:00Z", "t"), audio="C.m4a", job="20261108-090000.m4a")
    ctx.call("POST", "/records/2026-11-08", other, ctx.bearer)
    big = b"{" + b" " * (records.RECORD_LIMIT + 10) + b"}"
    wrong_date = json.loads(json.dumps(body))
    wrong_date["conversations"][0]["lines"][0]["time"] = 784000000.123
    checks = {"日の名前": ctx.call("POST", "/records/2026-13-01", b"{}", ctx.bearer)[0],
              "日の名前の後ろ": ctx.call("POST", f"/records/{DAY}x", b"{}", ctx.bearer)[0],
              "../": ctx.call("POST", "/records/..%2F2026-11-07", b"{}", ctx.bearer)[0],
              "大きすぎる": ctx.call("POST", f"/records/{DAY}", big, ctx.bearer)[0],
              "JSON でない": ctx.call("POST", f"/records/{DAY}", b"{", ctx.bearer)[0],
              "空": ctx.call("POST", f"/records/{DAY}", b"", ctx.bearer)[0],
              "合言葉違い": ctx.call("POST", f"/records/{DAY}", body, {"Authorization": "Bearer nope"})[0],
              "合言葉なし": ctx.call("POST", f"/records/{DAY}", body)[0]}
    date_error = ctx.call("POST", f"/records/{DAY}", wrong_date, ctx.bearer)
    ok = checks == {"日の名前": 400, "日の名前の後ろ": 400, "../": 400, "大きすぎる": 413, "JSON でない": 400, "空": 400,
                    "合言葉違い": 401, "合言葉なし": 401} \
        and date_error[0] == 400 and "conversations[0].lines[0].time" in str(date_error[1]) \
        and json.loads(path.read_bytes())["conversations"][1]["title"] == "昼ごはんの相談"
    failed += say(ok, f"POST /records の断り方: {checks}・日時が数 {date_error[:2]}（置いてあるものは変えない）")
    return failed


def check_pages(ctx: Context, index) -> int:
    failed = 0
    store = ctx.store
    base = records.parse_time(f"{DAY}T00:00:00Z", "t")
    body, t = sample(base)
    # 音声を1つだけ PC に置く（A.m4a → 20261107-090000.m4a。B.m4a は PC に無い）
    source = ctx.folder / "src.audio"
    source.write_bytes(bytes(range(256)) * 40)
    store.keep_audio("20261107-090000.m4a", source, {"queued_at": time.time()})
    count = index.index(semantic.parse_index(json.dumps({"items": index_items(DAY, body)}, ensure_ascii=False).encode()))
    plain = ctx.call("GET", "/dash/records")
    wrong = ctx.call("GET", "/dash/records", headers={"Authorization": "Basic " + base64.b64encode(b"x:nope").decode()})
    bearer_only = ctx.call("GET", "/dash/records", headers={"Authorization": "Bearer nope"})
    login = ctx.call("GET", f"/dash/records/{DAY}?key={KEY}&x=1")
    jar = (login[2].get("set-cookie") or "").split(";")[0]
    by_cookie = ctx.call("GET", f"/dash/records/{DAY}", headers={"Cookie": jar})
    ok = plain[0] == 401 and "basic" in plain[2].get("www-authenticate", "").lower() and wrong[0] == 401 \
        and bearer_only[0] == 401 and login[0] == 303 and login[2].get("location") == f"/dash/records/{DAY}?x=1" \
        and "HttpOnly" in login[2].get("set-cookie", "") and by_cookie[0] == 200 \
        and ctx.call("GET", "/dash/audio/20261107-090000.m4a")[0] == 401
    failed += say(ok, f"記録の画面の合言葉: なし {plain[0]}・違う {wrong[0]}・?key= {login[0]} → {login[2].get('location')}・"
                      f"クッキー {by_cookie[0]}・音声も合言葉なしは断る")
    status, html, got = ctx.page("/dash/records")
    ok = status == 200 and "11/7（土）" in html and "11/8（日）" in html and "会話 3・行 11" in html \
        and "default-src 'none'" in got.get("content-security-policy", "") \
        and "media-src 'self'" in got.get("content-security-policy", "") and got.get("cache-control") == "no-store" \
        and "<script src" not in html and "<link" not in html and "https://" not in html and "http://" not in html \
        and "文字で探す" in html and "意味で探す" in html and "PC にある音声" in html and "1 個" in html \
        and html.index("11/8（日）") < html.index("11/7（土）")
    failed += say(ok, f"日の一覧（{len(html)} 文字、新しい日が上・キャッシュさせない・外の部品なし）")
    status, html, got = ctx.page(f"/dash/records/{DAY}")
    ok = status == 200 and "2026年11月7日（土）" in html and "来月の予算の相談" in html and "田中" in html \
        and "&lt;script&gt;alert(1)&lt;/script&gt;" in html and "<script>alert(1)" not in html \
        and f"id='t{t['tanaka']}'" in html and "★" in html and "不確か 0.30" in html and "手で直した行" in html \
        and "data-audio='20261107-090000.m4a'" in html and "PC に音声がありません" in html \
        and "data-stop='6.80'" in html and "相手 田中・佐藤" in html and "場面 職場" in html and "移動 歩きながら" in html \
        and "テレビ「ニュース」" in html and "1日のまとめ" in html and "資料を送る" in html \
        and "<option value='自分'>自分</option>" in html and "<option value='テレビ'>" not in html \
        and html.index("<option value='自分'>") < html.index("<option value='田中'>") < html.index("<option value='人物12'>") \
        and "前の日" not in html and "次の日" in html and got.get("cache-control") == "no-store"
    failed += say(ok, f"1日の会話（{len(html)} 文字）: 見出し・相手・場面・印・確からしさ・再生・音声の無い会話・"
                      "話し手に選べる名前（自分が先、テレビは出さない）")
    missing = ctx.page("/dash/records/2026-10-01")
    bad = ctx.page("/dash/records/..%2F..%2Fx")
    ok = missing[0] == 404 and bad[0] == 404 and "その日の記録は PC にありません" in missing[1]
    failed += say(ok, f"無い日 {missing[0]}・おかしな日の名前 {bad[0]}")
    # 文字で探す
    status, html, _ = ctx.page("/dash/records/search?" + "q=" + quote("予算") + "&mode=text")
    hits = html.count("class='hit'")
    ok = status == 200 and hits == 4 and "<mark>予算</mark>" in html and f"/dash/records/{DAY}#t{t['tanaka']}" in html \
        and "<script>alert" not in html
    two = ctx.page("/dash/records/search?q=" + quote("田中 わかりました") + "&mode=text")[1].count("class='hit'")
    width = ctx.page("/dash/records/search?q=" + quote("ＳＣＲＩＰＴ") + "&mode=text")[1].count("class='hit'")
    failed += say(ok and two == 2 and width == 2,
                  f"文字で探す: 「予算」{hits} 件（全部の日・印つき）・「田中 わかりました」{two} 件（日ごと）・全角と大文字 {width} 件")
    # 意味で探す（作り物の Ollama）
    status, html, _ = ctx.page("/dash/records/search?q=" + quote("来月の予算の資料") + "&mode=meaning")
    ok = status == 200 and count == 8 and "近さ" in html and f"/dash/records/{DAY}#t{t['tanaka']}" in html \
        and html.index(f"#t{t['tanaka']}") < html.index(f"#t{t['lunch']}") and "職場" in html
    failed += say(ok, f"意味で探す（作り物の Ollama、置いた行 {count}）: いちばん近い行へ飛べる")
    # 音声（Range）
    data = (ctx.folder / "audio" / DAY / "20261107-090000.m4a").read_bytes()
    full = raw_call(ctx.port, "GET", "/dash/audio/20261107-090000.m4a", headers=ctx.basic)
    part = raw_call(ctx.port, "GET", "/dash/audio/20261107-090000.m4a", headers={**ctx.basic, "Range": "bytes=10-19"})
    tail = raw_call(ctx.port, "GET", "/dash/audio/20261107-090000.m4a", headers={**ctx.basic, "Range": "bytes=-5"})
    open_end = raw_call(ctx.port, "GET", "/dash/audio/20261107-090000.m4a",
                        headers={**ctx.basic, "Range": f"bytes={len(data) - 3}-"})
    beyond = raw_call(ctx.port, "GET", "/dash/audio/20261107-090000.m4a", headers={**ctx.basic, "Range": "bytes=999999-"})
    unknown = raw_call(ctx.port, "GET", "/dash/audio/20261107-120000.m4a", headers=ctx.basic)
    sneaky = raw_call(ctx.port, "GET", "/dash/audio/..%2Frecords%2F2026-11-07.json", headers=ctx.basic)
    ok = full[0] == 200 and full[1] == data and full[2].get("content-type") == "audio/mp4" \
        and full[2].get("accept-ranges") == "bytes" and full[2].get("cache-control") == "no-store" \
        and part[0] == 206 and part[1] == data[10:20] and part[2].get("content-range") == f"bytes 10-19/{len(data)}" \
        and tail[0] == 206 and tail[1] == data[-5:] and open_end[1] == data[-3:] and beyond[0] == 416 \
        and beyond[2].get("content-range") == f"bytes */{len(data)}" and unknown[0] == 404 and sneaky[0] == 404
    failed += say(ok, f"音声を返す: 全部 {full[0]}・bytes=10-19 {part[0]} {part[2].get('content-range')}・最後の 5 {tail[0]}・"
                      f"範囲の外 {beyond[0]}・無い音声 {unknown[0]}・外を指す名前 {sneaky[0]}")
    ranges = [recordsui.parse_range(h, 100) for h in (None, "bytes=0-0", "bytes=5-", "bytes=-0", "bytes=1-2,4-5", "items=1-2",
                                                       "bytes=50-10")]
    ok = ranges == [None, (0, 0), (5, 99), "bad", None, None, "bad"] and recordsui.parse_range("bytes=0-", 0) == "bad"
    failed += say(ok, f"Range の読み方: {ranges}")
    # 見守りの画面からの入口
    status, html, _ = ctx.call("GET", "/dash", headers=ctx.basic)
    failed += say(status == 200 and "href='/dash/records'" in str(html), "見守りの画面に記録の画面への入口がある")
    return failed


def check_edits_http(ctx: Context) -> int:
    failed = 0
    base = records.parse_time(f"{DAY}T00:00:00Z", "t")
    _, t = sample(base)
    no_mark = ctx.edit(DAY, t["tanaka"], "text", "来月の予算の資料はできた？", mark=False)
    no_auth = ctx.call("POST", "/dash/records/edit", {"day": DAY}, {dashboard.HEADER: "1"})
    first = ctx.edit(DAY, t["tanaka"], "text", "  来月の予算の資料は\nできましたか？ ")
    got = ctx.call("GET", "/edits?after=0", headers=ctx.bearer)
    edits = got[1].get("edits", []) if isinstance(got[1], dict) else []
    one = edits[0] if edits else {}
    ok = no_mark[0] == 403 and no_auth[0] == 401 and first[0] == 200 and first[1].get("id") == 1 \
        and "iPhone に送る前" in first[1].get("html", "") and "iPhone に送る前" in first[1].get("message", "") \
        and got[0] == 200 and len(edits) == 1 and one.get("time") == records.iso_ms(t["tanaka"]) \
        and one.get("base") == {"text": "来月の予算の資料はできましたか", "speaker": "田中", "speakerID": "5"} \
        and one.get("text") == "来月の予算の資料は できましたか？" and one.get("kind") == "text" \
        and one.get("speaker") is None and one.get("speakerID") is None and one.get("created", "").endswith("Z") \
        and one.get("day") == DAY
    failed += say(ok, f"文を直す → GET /edits: {json.dumps(one, ensure_ascii=False)}（印の無いボタン {no_mark[0]}・"
                      f"合言葉なし {no_auth[0]}）")
    # 話し手（選べるのは、記録に出てくる名前と「自分」だけ。番号は1つに決まるときだけ）
    me = ctx.edit(DAY, t["sato7"], "speaker", "自分")
    tanaka = ctx.edit(DAY, t["hello"], "speaker", "田中")
    sato = ctx.edit(DAY, t["lunch"], "speaker", "佐藤")
    unnamed = ctx.edit(DAY, t["sato8"], "speaker", "人物12")
    new_name = ctx.edit(DAY, t["hello"], "speaker", "山田")
    tv = ctx.edit(DAY, t["hello"], "speaker", "テレビ")
    same = ctx.edit(DAY, t["reply"], "speaker", "自分")
    dup = ctx.edit(DAY, t["dup"], "text", "直す")
    gone = ctx.edit(DAY, t["tanaka"] + 7, "text", "直す")
    empty = ctx.edit(DAY, t["reply"], "text", "  ")
    no_day = ctx.edit("2026-10-01", t["reply"], "text", "直す")
    listed = {e["id"]: e for e in ctx.call("GET", "/edits?after=1", headers=ctx.bearer)[1].get("edits", [])}
    ids = {name: r[1].get("id") for name, r in (("me", me), ("tanaka", tanaka), ("sato", sato), ("unnamed", unnamed))}
    ok = all(r[0] == 200 for r in (me, tanaka, sato, unnamed)) \
        and listed[ids["me"]]["speaker"] == "自分" and listed[ids["me"]]["speakerID"] == "me" \
        and listed[ids["tanaka"]]["speakerID"] == "5" and listed[ids["sato"]]["speakerID"] is None \
        and listed[ids["unnamed"]]["speakerID"] == "12" and listed[ids["me"]]["base"]["speaker"] == "佐藤" \
        and new_name[0] == 400 and "新しい名前は作れません" in new_name[1].get("error", "") and tv[0] == 400 \
        and same[0] == 400 and "変わっていません" in same[1].get("error", "") \
        and dup[0] == 400 and "同じ時刻" in dup[1].get("error", "") and gone[0] == 400 and empty[0] == 400 \
        and no_day[0] == 400
    failed += say(ok, f"話し手を変える: 自分 → me・田中 → 5・佐藤（番号が2つ）→ null・人物12 → 12、"
                      f"新しい名前 {new_name[0]}・テレビ {tv[0]}・同じ話し手 {same[0]}・同じ時刻の行 {dup[0]}・"
                      f"無い行 {gone[0]}・空の文 {empty[0]}・無い日 {no_day[0]}")
    # 重なり: 1 は渡した → 続ける。まだ渡していないものは新しいほうだけ
    second = ctx.edit(DAY, t["tanaka"], "text", "来月の予算の資料、できましたか")
    third = ctx.edit(DAY, t["tanaka"], "text", "来月の予算の資料はもうできましたか")
    rows = {e["id"]: e for e in ctx.store.edits.for_day(DAY)}
    after = [e["id"] for e in ctx.call("GET", "/edits?after=0", headers=ctx.bearer)[1].get("edits", [])]
    ok = second[0] == 200 and third[0] == 200 and rows[second[1]["id"]]["status"] == "superseded" \
        and rows[third[1]["id"]]["base"]["text"] == "来月の予算の資料は できましたか？" and 1 in after \
        and second[1]["id"] not in after and third[1]["id"] in after and "置き換え" in " ".join(ctx.logged)
    failed += say(ok, f"同じ行の直しが重なったとき: 渡した直しの後に続け、渡す前の直しは新しいほうだけ（残り {after}）")
    status, html, _ = ctx.page(f"/dash/records/{DAY}")
    ok = status == 200 and "来月の予算の資料はもうできましたか" in html and "data-expect='来月の予算の資料はもうできましたか'" in html \
        and "iPhone が受け取り、直すのを待っています" in html
    failed += say(ok, "1日の会話に、直しの様子と、直す欄の初めの文（まだ当てていない直しを当てた後の文）が出る")
    # 知らせ
    ack = ctx.call("POST", "/edits/ack", {"results": [
        {"id": 1, "status": "applied", "reason": None},
        {"id": ids["me"], "status": "skipped", "reason": "iPhone の記録が先に変わっていました"},
        {"id": ids["tanaka"], "status": "failed", "reason": "その人が iPhone にいません"},
        {"id": 99999, "status": "applied"}]}, ctx.bearer)
    bad = {"JSON でない": ctx.call("POST", "/edits/ack", b"{", ctx.bearer)[0],
           "results なし": ctx.call("POST", "/edits/ack", {"x": 1}, ctx.bearer)[0],
           "status": ctx.call("POST", "/edits/ack", {"results": [{"id": 1, "status": "done"}]}, ctx.bearer)[0],
           "id が文字": ctx.call("POST", "/edits/ack", {"results": [{"id": "1", "status": "applied"}]}, ctx.bearer)[0],
           "合言葉違い": ctx.call("POST", "/edits/ack", {"results": []}, {"Authorization": "Bearer nope"})[0],
           "after が文字": ctx.call("GET", "/edits?after=abc", headers=ctx.bearer)[0],
           "after が負": ctx.call("GET", "/edits?after=-1", headers=ctx.bearer)[0],
           "一覧の合言葉違い": ctx.call("GET", "/edits", headers={"Authorization": "Bearer nope"})[0]}
    left = [e["id"] for e in ctx.call("GET", "/edits", headers=ctx.bearer)[1].get("edits", [])]
    ok = ack[:2] == (200, {"ok": True, "updated": 3}) and bad == {"JSON でない": 400, "results なし": 400, "status": 400,
                                                                 "id が文字": 400, "合言葉違い": 401, "after が文字": 400,
                                                                 "after が負": 400, "一覧の合言葉違い": 401} \
        and 1 not in left and ids["me"] not in left and ids["sato"] in left
    failed += say(ok, f"POST /edits/ack: {ack[:2]}・断り方 {bad}・まだ当てていない {left}")
    status, html, _ = ctx.page(f"/dash/records/{DAY}")
    index_page = ctx.page("/dash/records")[1]
    ok = "iPhone で直しました" in index_page and "iPhone で直せませんでした（iPhone の記録が先に変わっていました）" in html \
        and "iPhone で直せませんでした（その人が iPhone にいません）" in html and "直し " in index_page \
        and "件（送る前）" in index_page
    failed += say(ok, "直しの様子: 「iPhone に送る前」「iPhone で直しました」「iPhone で直せませんでした（理由）」")
    # iPhone で当てた直しは、その日の記録が届き直すまでのあいだも、次の直しの元に入れる
    e1 = ctx.edit(DAY, t["plain"], "text", "わかりました。待っています")
    ctx.call("GET", "/edits?after=0", headers=ctx.bearer)
    ctx.call("POST", "/edits/ack", {"results": [{"id": e1[1].get("id"), "status": "applied", "reason": None}]}, ctx.bearer)
    page_before = ctx.page(f"/dash/records/{DAY}")[1]
    e2 = ctx.edit(DAY, t["plain"], "text", "わかりました！待っています")
    rows = {e["id"]: e for e in ctx.store.edits.for_day(DAY)}
    base2 = rows.get(e2[1].get("id"), {}).get("base", {}).get("text")
    ctx.call("POST", "/edits/ack", {"results": [{"id": e2[1].get("id"), "status": "skipped", "reason": "試し"}]}, ctx.bearer)
    time.sleep(0.05)
    # iPhone が送り直した記録（その行は、そのあと iPhone でさらに変わっていた）
    stored = json.loads((ctx.folder / "records" / f"{DAY}.json").read_bytes())
    for c in stored["conversations"]:
        for line in c["lines"]:
            if records.parse_time(line["time"], "t") == t["plain"]:
                line["text"] = "iPhone でさらに直した文"
    resent = ctx.call("POST", f"/records/{DAY}", stored, ctx.bearer)
    e3 = ctx.edit(DAY, t["plain"], "text", "わかりました、待っていますね")
    rows = {e["id"]: e for e in ctx.store.edits.for_day(DAY)}
    base3 = rows.get(e3[1].get("id"), {}).get("base", {}).get("text")
    ok = e1[0] == 200 and e2[0] == 200 and base2 == "わかりました。待っています" and resent[0] == 200 \
        and e3[0] == 200 and base3 == "iPhone でさらに直した文" \
        and "data-expect='わかりました。待っています'" in page_before
    failed += say(ok, f"iPhone で当てた直しは、記録が届き直すまで次の直しの元に入れる（{base2}）・"
                      f"届き直したら記録のほうを元にする（{base3}）")
    return failed


# MARK: - 音声の保存


def check_audio(main) -> int:
    failed = 0
    saved = (main.App.records, main.App.jobs, getattr(main.Handler, "key", None), main.log)
    logged: list[str] = []
    with tempfile.TemporaryDirectory() as folder:
        root = Path(folder)
        config: dict = {}
        store = records.RecordStore(root, logged.append, lambda: config)
        runner = (lambda path, params, name: ({"lines": [], "seconds": 0.0}, {"audio_seconds": 1.0}))

        def put(queue: jobqueue.JobQueue, name: str, data: bytes) -> None:
            assert queue.begin(name)[0] == "ok"
            queue.part_path(name).write_bytes(data)
            queue.commit(name, {"hints": []}, len(data))

        jobs = root / "jobs"
        queue = jobqueue.JobQueue(jobs, runner, logged.append, keep_audio=store.keep_audio)
        put(queue, "20261107-090000.m4a", b"audio-1")
        put(queue, "abc.m4a", b"audio-2")
        while queue.step():
            pass
        kept = queue.audio_path("20261107-090000.m4a").exists() and queue.audio_path("abc.m4a").exists()
        restarted = jobqueue.JobQueue(jobs, runner, logged.append, keep_audio=store.keep_audio)
        survived = restarted.audio_path("20261107-090000.m4a").exists()
        gone = restarted.delete("20261107-090000.m4a")
        moved = root / "audio" / "2026-11-07" / "20261107-090000.m4a"
        queued_day = time.strftime("%Y-%m-%d", time.localtime(restarted.jobs["abc.m4a"]["queued_at"]))
        restarted.clean(now=time.time() + jobqueue.KEEP_SECONDS + 10)
        cleaned = root / "audio" / queued_day / "abc.m4a"
        left = [p.name for p in jobs.iterdir()]
        ok = kept and survived and gone and moved.read_bytes() == b"audio-1" and cleaned.read_bytes() == b"audio-2" \
            and left == [] and store.audio_file("20261107-090000.m4a") == moved and store.audio_file("abc.m4a") == cleaned
        failed += say(ok, f"音声は iPhone が消すまで残し（起動し直しても）、消したら {moved.parent.name}/{moved.name} に、"
                          f"7 日の片付けでは {cleaned.parent.name}/ に移す（jobs に残り {left}）")
        # 残す先が無いとき（版 6 と同じ）・0 日の設定
        plain = jobqueue.JobQueue(root / "jobs6", runner, logged.append)
        put(plain, "20261107-100000.m4a", b"x")
        plain.step()
        v6_like = not plain.audio_path("20261107-100000.m4a").exists()
        config["audio_keep_days"] = 0
        zero = jobqueue.JobQueue(root / "jobs0", runner, logged.append, keep_audio=store.keep_audio)
        put(zero, "20261107-110000.m4a", b"y")
        zero.step()
        zero.delete("20261107-110000.m4a")
        not_kept = store.audio_file("20261107-110000.m4a") is None and not any((root / "jobs0").iterdir())
        config.clear()
        failed += say(v6_like and not_kept, "残す先が無ければ版 6 と同じに消す・\"audio_keep_days\": 0 なら残さない")
        # DELETE /jobs/<名前>（受け付けから）
        try:
            main.log = logged.append
            main.Handler.key = KEY
            main.App.records = store
            main.App.jobs = jobqueue.JobQueue(root / "jobs-http", runner, logged.append, keep_audio=store.keep_audio)
            server = main.Server(("127.0.0.1", 0), main.Handler)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            port = server.server_address[1]
            posted = raw_call(port, "POST", "/jobs?name=20261107-120000-w.m4a", b"watch-audio",
                              {"Authorization": f"Bearer {KEY}"})
            main.App.jobs.step()
            deleted = raw_call(port, "DELETE", "/jobs/20261107-120000-w.m4a", headers={"Authorization": f"Bearer {KEY}"})
            served = raw_call(port, "GET", "/dash/audio/20261107-120000-w.m4a",
                              headers={"Authorization": "Basic " + base64.b64encode(f"x:{KEY}".encode()).decode()})
            server.shutdown()
            server.server_close()
        finally:
            main.App.records, main.App.jobs, main.Handler.key, main.log = saved
        ok = posted[0] == 200 and deleted[0] == 200 and json.loads(deleted[1]) == {"id": "20261107-120000-w.m4a", "deleted": True} \
            and served[0] == 200 and served[1] == b"watch-audio"
        failed += say(ok, f"DELETE /jobs/<名前> → 音声を移して、画面から再生できる: {deleted[0]} → {served[0]}")
        # 30 日・大きさの上限
        now = time.time()
        folder_old = root / "audio" / "2026-09-01"
        folder_old.mkdir(parents=True, exist_ok=True)
        samples = {"old.m4a": 40, "mid.m4a": 20, "new.m4a": 1}
        for name, days in samples.items():
            path = folder_old / name
            path.write_bytes(b"z" * 1000)
            os.utime(path, (now - days * 86400, now - days * 86400))
        removed = store.clean_audio(now=now)
        after_days = sorted(p.name for p in folder_old.iterdir())
        config["audio_keep_gb"] = 1500 / 1e9   # 1500 バイトまで（今は約 2000 バイト）
        removed_size = store.clean_audio(now=now)
        names = sorted(p.name for p in (root / "audio").glob("*/*"))
        total = sum(p.stat().st_size for p in (root / "audio").glob("*/*"))
        config["audio_keep_days"] = 10
        config["audio_keep_gb"] = "たくさん"
        limits = store.audio_limits()
        config.clear()
        ok = removed == 1 and after_days == ["mid.m4a", "new.m4a"] and removed_size == 1 and total <= 1500 \
            and "new.m4a" in names and "mid.m4a" not in names and limits == (10.0, records.AUDIO_KEEP_GB) \
            and any("古いものを" in m for m in logged)
        failed += say(ok, f"古い音声を消す: 30 日より前 {removed} 個・大きさの上限で {removed_size} 個（残り {names}・{total} バイト）・"
                          f"おかしな設定は決まりの値 {limits}")
        failed += check_try_home(main, root)
    return failed


def check_try_home(main, root: Path) -> int:
    """--try-records は、ふだんの置き場所と番号を使わない"""
    try:
        try_serve(main, main.PORT, str(root / "try"), dry=True)
        port_refused = False
    except SystemExit:
        port_refused = True
    try:
        try_serve(main, 47699, str(main.HOME), dry=True)
        home_refused = False
    except SystemExit:
        home_refused = True
    return say(port_refused and home_refused, "--try-records は、ふだんの番号（47615）とふだんの置き場所では始めない")


# MARK: - 試しに起動する（--try-records）


class Silent:
    """文字にしない作り物のモデル（モデルを読み込まずに起動するため）"""
    name = "try"
    label = "試し（文字起こしはしません）"
    provider = "cpu"

    def run(self, audio, segments, hints, prompt):
        return ["" for _ in segments]


def try_serve(main, port: int, home: str | None, dry: bool = False) -> None:
    """一時のフォルダ（home）と作り物の記録で、記録の画面を試す。この PC の中（127.0.0.1）だけで受ける。"""
    default_home = Path(os.environ.get("LOCALAPPDATA") or Path.home() / ".local" / "share") / "LifeLogPC"
    if port == main.PORT:
        print(f"試すときは、ふだんの番号 {main.PORT} ではない番号にしてください（例 --port 47690）", flush=True)
        sys.exit(2)
    folder = Path(home) if home else Path(tempfile.mkdtemp(prefix="lifelog-try-"))
    for real in {default_home, main.HOME}:
        try:
            same = folder.resolve() == Path(real).resolve()
        except OSError:
            same = False
        if same:
            print("試すときは、ふだんの置き場所ではない一時のフォルダを --try-home で渡してください", flush=True)
            sys.exit(2)
    if dry:
        return
    folder.mkdir(parents=True, exist_ok=True)
    # ふだんの置き場所を使わないよう、置き場所をすべて一時のフォルダに替える
    main.HOME = folder
    for name, sub in (("MODEL_DIR", "model"), ("REAZON_DIR", "reazon"), ("WHISPER_DIR", "whisper"), ("CUDA_DIR", "cuda"),
                      ("CONFIG", "config.json"), ("LOG", "log.txt"), ("PERSONAL_DIR", "personal"),
                      ("PERSONAL_DATA", "personal/data"), ("PERSONAL_MODEL", "personal/model"), ("JOBS_DIR", "jobs"),
                      ("SEMANTIC_DB", "semantic.db")):
        setattr(main, name, folder / sub)
    key = main.passphrase()
    main.App.auto_update = False
    main.App.use_semantic = False
    # 預けた区切りの声の区間は、Silero VAD を取ってこないで、音の大きさで探す
    main._vad_failed = time.time()
    main.Handler.engine = main.Ensemble([Silent()])
    main.Handler.key = key
    main.start_records()
    main.start_v6(1)
    store = main.App.records
    # 作り物の記録（きのう・きょう。9:00 から）と、聞ける音声（1つ目の会話だけ）
    v6checks.FakeOllama.models = ["bge-m3:latest"]
    v6checks.FakeOllama.allow_pull = False
    fake = v6checks.ThreadingHTTPServer(("127.0.0.1", 0), v6checks.FakeOllama)
    threading.Thread(target=fake.serve_forever, daemon=True).start()
    main.App.semantic = semantic.SemanticIndex(folder / "semantic.db",
                                               semantic.OllamaEmbedder(f"http://127.0.0.1:{fake.server_address[1]}"), main.log)
    main.App.semantic.available(force=True)
    if store is not None and not store.days():
        for back in (1, 0):
            day = time.strftime("%Y-%m-%d", time.localtime(time.time() - back * 86400))
            start = int(time.mktime(time.strptime(day + " 09:00:00", "%Y-%m-%d %H:%M:%S")) * 1000)
            job = day.replace("-", "") + "-090000.wav"
            body, _ = sample(start, audio="talk.wav", job=job)
            store.put(day, json.dumps(body, ensure_ascii=False).encode("utf-8"))
            source = folder / "try.wav"
            source.write_bytes(tone_wav(30))
            store.keep_audio(job, source, {"queued_at": time.time()})
            main.App.semantic.index(semantic.parse_index(json.dumps({"items": index_items(day, body)},
                                                                    ensure_ascii=False).encode("utf-8")))
    server = main.Server(("127.0.0.1", port), main.Handler)
    print("=" * 60)
    print(" 記録の画面を試すために起動しました（モデルは読み込んでいません。文字起こしはできません）")
    print(f" 置き場所（一時）: {folder}")
    print(f" 画面: http://127.0.0.1:{port}/dash/records?key={key}")
    print(f" iPhone の代わりに送るとき: Authorization: Bearer {key}")
    print(" 意味で探すは作り物の Ollama です（言葉の近さで探します）。止めるときは Ctrl+C")
    print("=" * 60, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        fake.shutdown()
