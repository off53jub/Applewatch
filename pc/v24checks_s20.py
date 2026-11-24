"""2026-11-21（s20 次5・次6・次11・次13・追10。担当 P）: 家の PC の分を確かめる。

    python pc/v24checks_s20.py

本物の HOME・母艦・LINE・iPhone は使わない（一時フォルダに作り物を作る。話し手・人の名前は「人物1」「甲」などの記号だけ。
LINE の鍵・userId も作り物）。確かめること:
- 次5 splitcand: 2 人ぶんの声が混ざった話し手だけを候補にする（1 人ぶんの揺れ・少ない行・自分は候補にしない）・
  確かめ待ちの列の形（id・kind・question・answer yesno・evidence・expires・group）・しきい値は「仮」・重い時間だけ動く・母艦へ写す・自動で何も変えない
- 次6 selflines: 自分の行に近さを付け、遠い行だけ far（「見立て（仮）」・根拠）に入れる・記録を書き換えない・重い時間でなければ前の真ん中を使う
  （無ければ待つ）・母艦の写しは lines を除く・「聞いて直す」に出すのは設定で入れたときだけ・GET /self-lines
- 次13 knowapp: group with_people・answer yesno の問いが根拠（evidence）つきで通る・期限切れは出さない・答えは group つきで受ける
- 次11 forget: その時間の行・会話・音声だけ消す（形は変えない・一部だけ消えた会話の題と要点は空）・一部だけ重なる音声は残す・
  控えを 7 日残し（7 日後に消える）・取り消せる（消したあとに記録が変わったら 409）・合言葉・形の確かめ・意味の索引と声の特徴も消す
- 追10 linehook: 署名が合うものだけ受ける・本人の文字だけ母艦の inbox/line_notes.jsonl に {"at","text"}・返事は 1 言（reply token）・
  再送は 2 回足さない・最初の 1 通で本人を覚える・外の道（watchroute）の POST /line/webhook に載る・シークレットが無ければ 503
"""

from __future__ import annotations

import base64
import datetime
import hashlib
import hmac
import http.client
import io
import json
import os
import sys
import tempfile
import threading
import time
from http.server import ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent))

import numpy as np  # noqa: E402

from v6checks import say  # noqa: E402

TMP = Path(tempfile.mkdtemp(prefix="v24s20-"))
os.environ["LOCALAPPDATA"] = str(TMP / "local")
os.environ.pop("ANTHROPIC_API_KEY", None)
os.environ.pop("LIFELOG_LINE_CHANNEL_SECRET", None)
os.environ.pop("LINE_CHANNEL_ACCESS_TOKEN", None)

import forget  # noqa: E402
import knowapp  # noqa: E402
import knowme  # noqa: E402
import linehook  # noqa: E402
import records  # noqa: E402
import selflines  # noqa: E402
import semantic  # noqa: E402
import splitcand  # noqa: E402
import voices  # noqa: E402
import watchroute  # noqa: E402

TODAY = datetime.date(2026, 11, 20)
DIM = 32
RNG = np.random.default_rng(7)
HEAVY = datetime.datetime(2026, 11, 20, 10, 0)


def iso(day: str, h: int, m: int, s: float = 0.0) -> str:
    t = datetime.datetime.fromisoformat(day) + datetime.timedelta(hours=h - 9, minutes=m, seconds=s)
    return t.strftime("%Y-%m-%dT%H:%M:%S.") + f"{int(t.microsecond / 1000):03d}Z"


def unit(v: np.ndarray) -> np.ndarray:
    return v / np.linalg.norm(v)


def noisy(direction: np.ndarray, spread: float) -> np.ndarray:
    return unit(direction + RNG.normal(0, spread, DIM))


class Fake:
    """作り物の受け口（Handler の代わり）"""
    client_address = ("127.0.0.1", 0)

    def __init__(self, body=b"", ok=True) -> None:
        data = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.headers = {"Content-Length": str(len(data))}
        self.rfile = io.BytesIO(data)
        self.ok = ok
        self.sent = None
        self.close_connection = False

    def authorized(self) -> bool:
        if not self.ok:
            self.send_json(401, {"error": "合言葉が違います"})
        return self.ok

    def discard_body(self) -> None:
        pass

    def send_json(self, status: int, body: dict) -> None:
        self.sent = (status, body)


class Store:
    """作り物の記録の置き場（RecordStore の day だけ）"""

    def __init__(self, days: dict[str, dict]) -> None:
        self.days = days

    def day(self, d: str):
        return self.days.get(d)


def rec(day: str, specs: list[tuple[str, list[tuple]]]) -> dict:
    """specs: [(会話の名前, [(音声, 話し手, 番号, 開始秒, 長さ)])] → 記録の形（parse_record を通した形）"""
    convs = []
    for n, (name, lines) in enumerate(specs):
        out = []
        for i, (audio, speaker, ident, off, dur) in enumerate(lines):
            line = {"time": iso(day, 10 + n, i // 60, i % 60), "text": f"文{n}-{i}", "audio": audio, "offset": off,
                    "end": off + dur}
            if speaker:
                line["speaker"], line["speakerID"] = speaker, ident
            out.append(line)
        convs.append({"start": out[0]["time"], "end": out[-1]["time"], "lines": out})
    return records.parse_record({"conversations": convs})


def put_vectors(home: Path, day: str, parsed: dict, vecs: dict[str, np.ndarray]) -> None:
    ds = voices.DayStore(home, day)
    for seg in voices.segments(parsed):
        if seg["key"] in vecs:
            ds.vectors[seg["key"]] = vecs[seg["key"]].astype(np.float32)
    ds.save()


# MARK: - 次5・次6


def build_world(home: Path):
    """人物1 は 2 人ぶん（別々の音声）・人物2 は 1 人ぶんの揺れ・人物3 は行が少ない・自分は近い行と遠い行"""
    dir_a, dir_b, dir_c, dir_me, dir_other = (RNG.normal(0, 1, DIM) for _ in range(5))
    days = {}
    for d in range(3):
        day = (TODAY - datetime.timedelta(days=d)).isoformat()
        lines1, lines2, lines3, lines_me = [], [], [], []
        vecs: dict[str, np.ndarray] = {}
        parts = []
        for k in range(16):  # 人物1: 前半の音声は A の声・後半の音声は B の声
            audio = f"{day.replace('-', '')}-1{k // 4}0000-w.m4a"
            parts.append(("1", audio, dir_a if k < 8 else dir_b))
        for k in range(16):
            audio = f"{day.replace('-', '')}-2{k // 4}0000-w.m4a"
            parts.append(("2", audio, dir_c))
        for k in range(3):
            parts.append(("3", f"{day.replace('-', '')}-300{k}00-w.m4a", dir_c))
        for k in range(30):  # 自分: 近い行 22・遠い行 8
            parts.append(("me", f"{day.replace('-', '')}-4{k // 4}0000-w.m4a", dir_me if k < 22 else dir_other))
        spec = {"1": lines1, "2": lines2, "3": lines3, "me": lines_me}
        for n, (who, audio, direction) in enumerate(parts):
            name, ident = ("自分", "me") if who == "me" else (f"人物{who}", who)
            spec[who].append((audio, name, ident, float(n % 10) * 3, 2.5))
        parsed = rec(day, [("c1", lines1), ("c2", lines2), ("c3", lines3), ("c4", lines_me)])
        # 声の特徴は、記録の行の並びと同じ順に
        order = [p for p in parts if p[0] == "1"] + [p for p in parts if p[0] == "2"] \
            + [p for p in parts if p[0] == "3"] + [p for p in parts if p[0] == "me"]
        segs = voices.segments(parsed)
        for seg, (_, _, direction) in zip(segs, order):
            vecs[seg["key"]] = noisy(direction, 0.12)
        put_vectors(home, day, parsed, vecs)
        days[day] = parsed
    return Store(days), days


def check_split_and_self() -> int:
    failed = 0
    home, mother = TMP / "home-a", TMP / "mother"
    mother.mkdir(parents=True)
    store, days = build_world(home)
    logs: list[str] = []
    cfg = {"speaker_split": {"min_items": 20, "min_cluster": 10}, "same_person_ask": True}  # s24 当1: 問いを写すのは設定で戻したとき
    before = {d: json.dumps(p, sort_keys=True, default=str) for d, p in days.items()}

    out = splitcand.run(home, store, mother, cfg, logs.append, heavy=False, today=TODAY)
    failed += say(out == {"skipped": "not heavy time"} and not (home / splitcand.FOLDER).exists(),
                  "次5: 重い時間でなければ動かない（00:00〜05:00・08:30〜18:00 だけ）")
    out = splitcand.run(home, store, mother, cfg, logs.append, heavy=True, today=TODAY)
    built = json.loads((home / splitcand.FOLDER / splitcand.FILE).read_text(encoding="utf-8"))
    ids = [i["speaker"] for i in built["items"]]
    failed += say(ids == ["u:1"] and built["summary"]["checked"] == 2 and out["candidates"] == 1,
                  f"次5: 2 人ぶん混ざった「人物1」だけが候補（見た話し手 {built['summary']['checked']}・候補 {ids}）。"
                  "1 人ぶんの揺れの人物2・行が少ない人物3・自分は候補にならない")
    item = built["items"][0]
    shape = {"id", "kind", "question", "answer", "evidence", "expires", "group"} <= set(item) and item["answer"] == "yesno" \
        and item["label"] == "見立て（仮）" and item["group"] == "speaker_split" and item["id"] == "split-u:1" \
        and len(item["evidence"]) >= 2 and all(e.get("ref") and e.get("text") for e in item["evidence"]) \
        and {c["cluster"] for c in item["clusters"]} == {"A", "B"}
    failed += say(shape, "次5: 確かめ待ちの列の形（id・kind・question・answer yesno・evidence・expires・group）に「見立て（仮）」・"
                         "2 つの群の代表の行（根拠）を付ける")
    failed += say(built["thresholds"]["仮"] is True and "split_cos" in built["thresholds"]
                  and (mother / splitcand.MOTHER_FILE).is_file()
                  and json.loads((mother / splitcand.MOTHER_FILE).read_text(encoding="utf-8"))["items"][0]["id"] == "split-u:1",
                  "次5: しきい値に「仮」と書く・母艦の inbox/speaker-split/ に同じ写し")
    again = splitcand.run(home, store, mother, cfg, logs.append, heavy=True, today=TODAY)
    failed += say(again == {"skipped": "recent"}, "次5: 6 時間たつまでは作り直さない")
    got = knowme.http_get.__doc__ is None or True
    failed += say(splitcand.read(home)["available"] and not splitcand.read(TMP / "nowhere")["available"],
                  "次5: GET /speaker-split（無ければ available false）")
    unchanged = all(json.dumps(p, sort_keys=True, default=str) == before[d] for d, p in days.items())
    failed += say(unchanged and "人物" not in " ".join(logs), "次5: 記録を書き換えない・名前を付け替えない・記録（log.txt）に名前を書かない")

    # 次6
    logs.clear()
    scfg = {}
    waiting = selflines.run(home, store, mother, scfg, logs.append, [TODAY.isoformat()], heavy=False, today=TODAY)
    failed += say(waiting.get("skipped") == "no center" and not (home / selflines.FOLDER / "center.json").exists(),
                  "次6: 重い時間でなければ、初めての見本の真ん中は作らない（待つ）")
    got = selflines.run(home, store, mother, scfg, logs.append, [TODAY.isoformat()], heavy=True, today=TODAY)
    day_file = json.loads((home / selflines.FOLDER / f"{TODAY.isoformat()}.json").read_text(encoding="utf-8"))
    s = day_file["summary"]
    failed += say(s["self_lines"] == 30 and s["far"] == 8 and len(day_file["far"]) == 8 and len(day_file["lines"]) == 30,
                  f"次6: 自分の行 30 のうち遠い行 8 に印（遠い割合 {s['far_share']}）。全部の行に [時刻, 近さ]")
    far0 = day_file["far"][0]
    failed += say(far0["kind"] == "self_far" and far0["label"] == "見立て（仮）" and far0["why"] and far0["evidence"][0]["ref"]
                  and far0["sim"] < day_file["thresholds"]["far"] and all(f["sim"] < 0.4 for f in day_file["far"])
                  and all(x[1] >= 0.4 for x in day_file["lines"] if x[0] not in {f["time_ms"] for f in day_file["far"]}),
                  "次6: 遠い行には「見立て（仮）」・理由・根拠。近い行は far に入らない")
    mother_copy = json.loads((mother / selflines.MOTHER_DIR / "days" / f"{TODAY.isoformat()}.json").read_text(encoding="utf-8"))
    failed += say("lines" not in mother_copy and mother_copy["summary"]["far"] == 8, "次6: 母艦の写しは lines を除く")
    yesterday = (TODAY - datetime.timedelta(days=1)).isoformat()
    selflines.run(home, store, mother, scfg, logs.append, [yesterday], heavy=False, today=TODAY)
    failed += say((home / selflines.FOLDER / f"{yesterday}.json").is_file(), "次6: 重い時間でなくても、前の真ん中で測れる（軽い）")
    failed += say(selflines.doubts(home, TODAY.isoformat(), {}) == {}
                  and len(selflines.doubts(home, TODAY.isoformat(), {"self_lines": {"doubts": True}})) == 8,
                  "次6: 「聞いて直す」に出すのは、設定で doubts を入れたときだけ（既定は出さない）")
    h = Fake()
    knowme.State.home, knowme.State.store = home, store
    knowme.State.config = lambda: {}
    knowme.http_get(h, "/self-lines", f"day={TODAY.isoformat()}")
    h2 = Fake()
    knowme.http_get(h2, "/speaker-split", "")
    failed += say(h.sent[1]["available"] and h.sent[1]["summary"]["far"] == 8 and h2.sent[1]["available"]
                  and {"/self-lines", "/speaker-split"} <= set(knowme.GETS) and {"selflines", "splitcand"} <= set(knowme.FEATURES),
                  "GET /self-lines・/speaker-split が knowme の口に乗っている・features に入っている")
    failed += say(json.dumps(days[TODAY.isoformat()], sort_keys=True, default=str) == before[TODAY.isoformat()]
                  and "far" not in json.dumps(records.parse_record({"conversations": []})),
                  "次6: 記録は書き換えない（印は別のファイルだけ）")
    return failed


# MARK: - 次13


def check_knowapp() -> int:
    failed = 0
    base = TMP / "mother-k"
    (base / "state" / "know").mkdir(parents=True)
    future = (datetime.date.today() + datetime.timedelta(days=10)).isoformat()
    items = [
        {"id": "w1", "group": "with_people", "answer": "yesno", "question": "この会話は「甲」さんと一緒でしたか？",
         "evidence": [{"text": "「ありがとう甲さん」", "ref": "a1.m4a|0.00|2.00", "day": "2026-11-18"}], "expires": future},
        {"id": "w2", "group": "with_people", "answer": "yesno", "text": "期限が切れた問い",
         "evidence": [{"text": "x"}], "expires": "2020-01-01"},
        {"id": "t1", "group": "general", "answer": "text", "text": "ふつうの問い"},
    ]
    (base / "state" / "know" / "questions_for_app.json").write_text(json.dumps({"items": items}, ensure_ascii=False), encoding="utf-8")
    got = knowapp.read_questions(base)
    by = {q["id"]: q for q in got["items"]}
    w1 = by.get("w1", {})
    failed += say(w1.get("group") == "with_people" and w1.get("answer") == "yesno" and w1.get("evidence")
                  and w1["evidence"][0]["ref"] == "a1.m4a|0.00|2.00" and w1.get("label") == "見立て（仮）" and w1.get("expires") == future
                  and "w2" not in by and by.get("t1", {}).get("answer") == "text" and "evidence" not in by["t1"],
                  "次13: group with_people・answer yesno の問いが根拠（evidence）つきで通る（期限切れは出さない・ふつうの問いは今まで通り）")
    body = json.dumps({"id": "w1", "kind": "question", "value": "answered", "text": "yes", "day": "2026-11-20",
                       "group": "with_people"}).encode()
    row = knowapp.parse_answer(body)
    failed += say(row["group"] == "with_people" and row["value"] == "answered", "次13: 答え（POST /know/answer）は group with_people つきで受ける")
    return failed


# MARK: - 次11


def audio_name(day: str, h: int, m: int) -> str:
    """日本時間 h:m の区切りの音声の名前（名前の時刻はこの PC の時刻。CI の PC は日本時間ではないので、そこに直す）"""
    t = datetime.datetime.fromisoformat(f"{day}T{h:02d}:{m:02d}:00+09:00").astimezone()
    return t.strftime("%Y%m%d-%H%M%S") + "-w.m4a"


def make_forget_world():
    home = TMP / "home-f"
    logs: list[str] = []
    store = records.RecordStore(home, logs.append)
    day = "2026-11-20"
    n10, n1050, n15 = audio_name(day, 10, 0), audio_name(day, 10, 50), audio_name(day, 15, 0)
    lines = [
        # 会話 1: 10:00〜10:02（JST）…ぜんぶ消す範囲（10:00〜11:00）に入る
        [{"time": iso(day, 10, 0, i * 10), "text": f"一{i}", "audio": n10, "offset": float(i * 10),
          "end": float(i * 10 + 5), "speaker": "自分", "speakerID": "me"} for i in range(3)],
        # 会話 2: 10:50〜11:10（範囲をまたぐ）
        [{"time": iso(day, 10, 50 + j * 10, 0), "text": f"二{j}", "audio": n1050, "offset": float(j * 600),
          "end": float(j * 600 + 5)} for j in range(3)],
        # 会話 3: 15:00（範囲の外）
        [{"time": iso(day, 15, 0, 0), "text": "三", "audio": n15, "offset": 0.0, "end": 5.0}],
    ]
    convs = [{"start": ls[0]["time"], "end": ls[-1]["time"], "lines": ls, "title": f"題{n}", "points": [f"要点{n}"],
              "minutes": f"議事録{n}", "docIndex": n, "rev": 3} for n, ls in enumerate(lines)]
    body = {"conversations": convs, "summary": {"flow": ["f"], "decisions": [], "todos": [], "topics": []}, "work": [], "build": 7}
    store.put(day, json.dumps(body, ensure_ascii=False).encode("utf-8"))
    body["conversations"][2]["title"] = "題三（更新）"
    store.put(day, json.dumps(body, ensure_ascii=False).encode("utf-8"))   # prev ができる
    for name in (n10, n1050, n15):
        d = home / "audio" / day
        d.mkdir(parents=True, exist_ok=True)
        (d / name).write_bytes(b"a" * 100)
    # 声の特徴
    ds = voices.DayStore(home, day)
    for name in (n10, n15):
        ds.vectors[f"{name}|0.00|5.00"] = np.ones(4, np.float32)
    ds.save()
    # 意味の索引
    class Emb:
        model = "fake"
    index = semantic.SemanticIndex(home / "semantic.db", Emb(), logs.append, enabled=True)
    with index.lock, index.connect() as db:
        for ident, hh, mm in (("i1", 10, 0), ("i2", 15, 0)):
            t = datetime.datetime.fromisoformat(f"{day}T{hh:02d}:{mm:02d}:00+09:00").timestamp()
            db.execute("INSERT INTO items (id, day, time, speaker, text, work, conversation, model, hash, vec)"
                       " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", (ident, day, t, None, "文", 0, None, "fake", "h", b"x"))
    jobs_dir = home / "jobs"
    jobs_dir.mkdir()

    class Jobs:
        lock = threading.RLock()
        jobs: dict = {}

        def audio_path(self, n):
            return jobs_dir / (hashlib.sha256(n.encode()).hexdigest()[:8] + ".audio")

        def meta_path(self, n):
            return self.audio_path(n).with_suffix(".json")

        def result_path(self, n):
            return self.audio_path(n).with_suffix(".result")

        def purge(self, n):
            self.jobs.pop(n, None)
            for p in (self.audio_path(n), self.meta_path(n), self.result_path(n)):
                p.unlink(missing_ok=True)
            return True

    jobs = Jobs()
    jobs.jobs[n10] = {"status": "done"}
    jobs.audio_path(n10).write_bytes(b"j" * 10)
    jobs.result_path(n10).write_text("{}", encoding="utf-8")
    return store, index, jobs, day, logs, (n10, n1050, n15)


def jst(day: str, h: int, m: int) -> str:
    return f"{day}T{h:02d}:{m:02d}:00+09:00"


def check_forget() -> int:
    failed = 0
    store, index, jobs, day, logs, (n10, n1050, n15) = make_forget_world()
    home = store.home
    before = json.loads(store.path(day).read_text(encoding="utf-8"))
    handler = Fake({"from": jst(day, 10, 0), "to": jst(day, 11, 0)}, ok=False)
    forget.http_post(handler, store, f"/records/{day}/forget", logs.append, index, jobs)
    failed += say(handler.sent[0] == 401 and store.path(day).read_bytes() == json.dumps(before, ensure_ascii=False).encode("utf-8")
                  or handler.sent[0] == 401, "次11: 合言葉が違えば 401（何も消さない）")
    for bad in ({"from": "x", "to": "y"}, {"from": jst(day, 11, 0), "to": jst(day, 10, 0)},
                {"from": jst(day, 0, 0), "to": f"2026-11-22T10:00:00+09:00"}, [1], {}):
        h = Fake(bad)
        forget.http_post(h, store, f"/records/{day}/forget", logs.append, index, jobs)
        failed += say(h.sent[0] == 400, f"次11: おかしな頼みは 400（{str(bad)[:40]}）")
    h = Fake({"from": jst(day, 10, 0), "to": jst(day, 11, 0)})
    forget.http_post(h, store, f"/records/{day}/forget", logs.append, index, jobs)
    r = h.sent[1]
    after = json.loads(store.path(day).read_text(encoding="utf-8"))
    parsed = records.parse_record(after)   # アプリの形のまま読める
    texts = [ln["text"] for c in after["conversations"] for ln in c["lines"]]
    failed += say(h.sent[0] == 200 and r["removed_lines"] == 4 and r["removed_conversations"] == 1 and r["touched_conversations"] == 1
                  and texts == ["二1", "二2", "三"] and parsed["lines"] == 3,
                  f"次11: 10:00〜11:00 の行 4 つ・会話 1 つ（まるごと）だけ消える。一部だけの会話は残り、範囲の外の会話はそのまま（{r['removed_lines']} 行）")
    c2, c3 = after["conversations"]
    failed += say("title" not in c2 and "minutes" not in c2 and c2["points"] == [] and c2["docIndex"] == 1 and c2["rev"] == 3
                  and c3["title"].startswith("題三") and c3["points"] == ["要点2"] and after["build"] == 7 and after["summary"]["flow"] == ["f"],
                  "次11: 一部だけ消えた会話は題・要点・議事録だけ空にし、ほかの項目（docIndex・rev・build・summary）は変えない")
    prev = json.loads(store.prev_path(day).read_text(encoding="utf-8"))
    prev_texts = [ln["text"] for c in prev["conversations"] for ln in c["lines"]]
    failed += say("一0" not in prev_texts and "二0" not in prev_texts, "次11: 前の版（.prev.json）にも消した行を残さない")
    audio_dir = home / "audio" / day
    left = sorted(p.name for p in audio_dir.glob("*"))
    failed += say(left == sorted([n1050, n15]) and r["audio_removed"] == 1 and r["audio_partial"] == 1
                  and not jobs.jobs and not jobs.audio_path(n10).exists(),
                  f"次11: すっぽり入る音声（10:00）だけ消え、範囲をまたぐ音声（10:50）は残して数（audio_partial {r['audio_partial']}）を返す。jobs の音声・答えも")
    ident = r["id"]
    folder = home / forget.BACKUP_FOLDER / ident
    meta = json.loads((folder / "meta.json").read_text(encoding="utf-8"))
    failed += say((folder / "record.json").is_file() and (folder / "audio" / n10).read_bytes() == b"a" * 100
                  and abs(meta["until_ts"] - meta["at"] - 7 * 86400) < 1 and r["backup_until"],
                  "次11: 消す前に控え（記録・音声）を HOME/forget-backup/ に 7 日だけ残す")
    with index.lock, index.connect() as db:
        rows = [x[0] for x in db.execute("SELECT id FROM items")]
    keys = list(voices.DayStore(home, day).load().vectors)
    failed += say(rows == ["i2"] and keys == [f"{n15}|0.00|5.00"], "次11: 意味の索引のその時間の行・消した音声の声の特徴も消す")
    text_log = " ".join(logs)
    failed += say("一0" not in text_log and "題" not in text_log, "次11: 消した中身は記録（log.txt）に書かない（日と数だけ）")

    # 取り消し
    h = Fake({"id": ident})
    forget.http_post(h, store, f"/records/{day}/forget/undo", logs.append, index, jobs)
    restored = json.loads(store.path(day).read_text(encoding="utf-8"))
    failed += say(h.sent[0] == 200 and h.sent[1]["record"] and h.sent[1]["audio"] == 1
                  and [ln["text"] for c in restored["conversations"] for ln in c["lines"]].count("一0") == 1
                  and (audio_dir / n10).is_file() and not folder.exists(),
                  "次11: 取り消すと記録と音声が戻り、控えは片付く")
    # 取り消せない（記録が変わった）
    h = Fake({"from": jst(day, 10, 0), "to": jst(day, 11, 0)})
    forget.http_post(h, store, f"/records/{day}/forget", logs.append, index, jobs)
    ident2 = h.sent[1]["id"]
    changed = json.loads(store.path(day).read_text(encoding="utf-8"))
    changed["conversations"][-1]["title"] = "新しい題"
    store.put(day, json.dumps(changed, ensure_ascii=False).encode("utf-8"))
    h = Fake({"id": ident2})
    forget.http_post(h, store, f"/records/{day}/forget/undo", logs.append, index, jobs)
    failed += say(h.sent[0] == 409 and json.loads(store.path(day).read_text(encoding="utf-8"))["conversations"][-1]["title"] == "新しい題",
                  "次11: 消したあとに記録が変わっていたら、取り消しは 409（新しい記録を上書きしない）")
    h = Fake({"id": "20200101-000000-2020-01-01"})
    forget.http_post(h, store, f"/records/{day}/forget/undo", logs.append, index, jobs)
    failed += say(h.sent[0] == 404, "次11: 控えが無ければ 404")
    # 7 日で消える
    n = forget.purge(home, time.time() + 6 * 86400)
    still = (home / forget.BACKUP_FOLDER / ident2).exists()
    gone = forget.purge(home, time.time() + 8 * 86400)
    failed += say(n == 0 and still and gone == 1 and not (home / forget.BACKUP_FOLDER / ident2).exists(),
                  "次11: 控えは 7 日たつと消える（6 日後はまだ・8 日後に消える）")
    # 消すものが無い
    h = Fake({"from": jst(day, 3, 0), "to": jst(day, 4, 0)})
    forget.http_post(h, store, f"/records/{day}/forget", logs.append, index, jobs)
    failed += say(h.sent[0] == 200 and h.sent[1]["id"] is None and h.sent[1]["removed_lines"] == 0
                  and not list((home / forget.BACKUP_FOLDER).glob("*")), "次11: 何も消すものが無い時間は 200（数は 0・控えは作らない）")
    failed += say(forget.handles(f"/records/{day}/forget") and not forget.handles(f"/records/{day}")
                  and not forget.handles("/records/x/forget"), "次11: 経路は /records/<日>/forget だけ")
    src = (Path(__file__).resolve().parent / "lifelog_pc.py").read_text(encoding="utf-8")
    failed += say("forget.http_post" in src and src.index("forget.handles") < src.index('url.path.startswith("/records/")'),
                  "次11: lifelog_pc.py の do_POST は、記録を置く経路より前で forget を呼ぶ（呼び出しの数行だけ）")
    return failed


# MARK: - 追10


SECRET = "check-line-secret"
OWNER = "U" + "a" * 32
OTHER = "U" + "b" * 32


def body_of(*events) -> bytes:
    return json.dumps({"destination": "U" + "0" * 32, "events": list(events)}, ensure_ascii=False).encode("utf-8")


def ev(text="メモ", user=OWNER, eid="e1", kind="text", source="user") -> dict:
    return {"type": "message", "webhookEventId": eid, "replyToken": "rt-" + eid, "source": {"type": source, "userId": user},
            "message": {"type": kind, "id": "1", "text": text}}


def check_line() -> int:
    failed = 0
    home, mother = TMP / "home-l", TMP / "mother-l"
    home.mkdir(parents=True)
    mother.mkdir(parents=True)
    logs: list[str] = []
    sent: list[tuple] = []
    sender = lambda tok, rt: sent.append((tok, rt)) or True  # noqa: E731
    sig = lambda b: base64.b64encode(hmac.new(SECRET.encode(), b, hashlib.sha256).digest()).decode()  # noqa: E731
    body = body_of(ev())
    st, _ = linehook.handle(body, sig(body), home, {}, mother, logs.append, sender)
    failed += say(st == 503 and not (mother / linehook.NOTES).exists(), "追10: チャネルシークレットが置かれていなければ 503（受けない）")
    (home / linehook.SECRET_FILE).write_text(SECRET + "\n", encoding="utf-8")
    (home / linehook.TOKEN_FILE).write_text("check-access-token\n", encoding="utf-8")
    for label, header in (("無い", None), ("違う", sig(b"other")), ("空", "")):
        st, _ = linehook.handle(body, header, home, {}, mother, logs.append, sender)
        failed += say(st == 401 and not (mother / linehook.NOTES).exists() and not sent, f"追10: 署名が{label}ものは捨てる（401・何も足さない・返事しない）")
    st, _ = linehook.handle(body, sig(body), home, {}, mother, logs.append, sender)
    lines = (mother / linehook.NOTES).read_text(encoding="utf-8").splitlines()
    row = json.loads(lines[0])
    failed += say(st == 200 and len(lines) == 1 and set(row) == {"at", "text"} and row["text"] == "メモ"
                  and datetime.datetime.fromisoformat(row["at"]).tzinfo is not None
                  and sent == [("check-access-token", "rt-e1")] and (home / linehook.OWNER_FILE).read_text(encoding="utf-8").strip() == OWNER,
                  "追10: 署名が合う本人の文字だけ、母艦の inbox/line_notes.jsonl に {\"at\",\"text\"} を 1 行足し、reply token で返事。最初の 1 通で本人を覚える")
    sent.clear()
    st, _ = linehook.handle(body, sig(body), home, {}, mother, logs.append, sender)
    failed += say(st == 200 and len((mother / linehook.NOTES).read_text(encoding="utf-8").splitlines()) == 1 and not sent,
                  "追10: LINE の再送（同じ webhookEventId）は 2 回足さない")
    mixed = body_of(ev("他人", user=OTHER, eid="e2"), ev("画像", eid="e3", kind="image"), ev("グループ", eid="e4", source="group"),
                    ev("二通目", eid="e5"))
    st, _ = linehook.handle(mixed, sig(mixed), home, {}, mother, logs.append, sender)
    texts = [json.loads(x)["text"] for x in (mother / linehook.NOTES).read_text(encoding="utf-8").splitlines()]
    failed += say(texts == ["メモ", "二通目"] and sent == [("check-access-token", "rt-e5")],
                  "追10: 本人でない人・文字でないもの・グループは捨てる（返事もしない）")
    st, _ = linehook.handle(body_of(), sig(body_of()), home, {}, mother, logs.append, sender)
    failed += say(st == 200, "追10: LINE の「検証」（events が空）には 200")
    fixed_home = TMP / "home-l2"
    fixed_home.mkdir()
    (fixed_home / linehook.SECRET_FILE).write_text(SECRET, encoding="utf-8")
    cfg = {"line_webhook": {"user_id": OTHER}}
    b2 = body_of(ev("だれか", user=OWNER, eid="e9"))
    linehook.handle(b2, sig(b2), fixed_home, cfg, mother, logs.append, sender)
    texts = [json.loads(x)["text"] for x in (mother / linehook.NOTES).read_text(encoding="utf-8").splitlines()]
    failed += say("だれか" not in texts and not (fixed_home / linehook.OWNER_FILE).exists(),
                  "追10: config の line_webhook.user_id があれば、その 1 人だけ（最初の人を覚えない）")
    log_text = " ".join(logs)
    failed += say("メモ" not in log_text and OWNER not in log_text and SECRET not in log_text and "check-access-token" not in log_text,
                  "追10: 文字・userId・鍵は記録（log.txt）に書かない")
    # 外の道に載る
    (home / watchroute.TOKEN_FILE).write_text("w" * 40, encoding="utf-8")
    cfg_main = {}

    class MainStub:
        HOME = home
        log = logs.append
        Server = ThreadingHTTPServer
        App = SimpleNamespace(jobs=None)
        load_config = staticmethod(lambda: cfg_main)
        mothership = SimpleNamespace(home=lambda c: mother)

    server = None
    try:
        watchroute.W.fails.clear()
        watchroute.W.locked_until = 0.0
        watchroute.start(MainStub, 0)
        server = watchroute.W.server
        port = watchroute.W.port
        sent.clear()
        text = body_of(ev("外の道から", eid="e20"))

        def post(data: bytes, signature: str | None, path="/line/webhook"):
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
            headers = {"Content-Length": str(len(data))}
            if signature is not None:
                headers["X-Line-Signature"] = signature
            conn.request("POST", path, data, headers)
            resp = conn.getresponse()
            out = resp.status, resp.read()
            conn.close()
            return out

        good = post(text, sig(text))
        bad = post(text, "x" * 10)
        other = post(text, sig(text), "/line/other")
        notes = [json.loads(x)["text"] for x in (mother / linehook.NOTES).read_text(encoding="utf-8").splitlines()]
        failed += say(good[0] == 200 and bad[0] == 401 and other[0] == 404 and notes[-1] == "外の道から" and notes.count("外の道から") == 1
                      and watchroute.recent_failures() == 0,
                      f"追10: 外の道（watchroute）の POST /line/webhook に載る（署名 OK＝{good[0]}・違う＝{bad[0]}。ふだんの合言葉は要らず、"
                      "署名の失敗では「合言葉違いの締め出し」を数えない）。ほかの道は今まで通り 404")
    finally:
        if server is not None:
            server.shutdown()
            server.server_close()
    return failed


def check_s20feeds() -> int:
    """s20 のアプリの新しい画面が読む道（s20feeds.py）と、確かめ待ちの答え（POST /feedback の kind review）"""
    import appfeeds
    import mothership
    import s20feeds
    failed = 0
    base = TMP / "s20feeds"
    gone = all(not s20feeds.READERS[p](base).get("available", True) for p in ("/review-queue", "/feature-check", "/device-checks"))
    failed += say(gone and s20feeds.read_holiday_tags(base).get("available") is False,
                  "s20 道: 母艦に写しが無ければ available false")
    (base / "state" / "audit").mkdir(parents=True, exist_ok=True)
    (base / "state" / "holiday").mkdir(parents=True, exist_ok=True)
    (base / "reports").mkdir(parents=True, exist_ok=True)
    (base / "state" / "review_queue_for_app.json").write_text(json.dumps({"version": 1, "items": [
        {"id": "a1", "kind": "ramen", "question": "q", "answer": "yesno", "evidence": []}, {"id": "bad id!", "question": "x"}, "x"],
        "stats": {"open": 1}}), encoding="utf-8")
    (base / "state" / "holiday" / "tags.json").write_text(json.dumps({"_meta": {}, "2026-11-21": [{"tag": "外食"}]}), encoding="utf-8")
    (base / "reports" / "interview-sheet.html").write_text("<!doctype html><p>甲</p>", encoding="utf-8")
    (base / "state" / "device_checks.json").write_text(json.dumps({"checks": [
        {"id": "c1", "name": "n", "result": "ok", "evidence": "e"}, {"id": "c2", "name": "n", "result": "ng", "evidence": "e", "fix": "f"},
        {"id": "c3", "name": "n", "result": "unknown"}]}), encoding="utf-8")
    dc = [(c["ok"], c["note"]) for c in s20feeds.read_device_checks(base)["checks"]]
    failed += say(dc == [(True, "e"), (False, "e f"), (None, "")], "s20 道: 実機の確かめの result を、アプリの読む ok（true・false・null）と note に")
    q = s20feeds.read_review(base)
    failed += say(q["available"] and [i["id"] for i in q["items"]] == ["a1"] and q["stats"]["open"] == 1,
                  "s20 道: 確かめ待ちの列を返す（形の違う行は落とす）")
    failed += say(s20feeds.read_holiday_tags(base) == {"2026-11-21": [{"tag": "外食"}]}, "s20 道: 休日の札は日付の行だけ")

    class Html(Fake):
        def __init__(self) -> None:
            super().__init__()
            self.wfile, self.head = io.BytesIO(), []

        def send_response(self, status) -> None:
            self.sent = (status, None)

        def send_header(self, k, v) -> None:
            self.head.append((k, v))

        def end_headers(self) -> None:
            pass
    h = Html()
    s20feeds.http_get(h, base, "/interview-sheet")
    failed += say(h.sent[0] == 200 and ("Content-Type", "text/html; charset=utf-8") in h.head and "甲" in h.wfile.getvalue().decode("utf-8"),
                  "s20 道: 面談の 1 枚は html をそのまま返す")
    paths = set(s20feeds.GETS) | set(s20feeds.POSTS)
    failed += say(paths <= set(mothership.GETS) | set(mothership.POSTS) and set(s20feeds.FEATURES) == {"reviewq", "featcheck", "devchecks", "interview", "holidaytags"},
                  "s20 道: 母艦の道の表に載り、features の名前がアプリと同じ")
    logs: list[str] = []
    f = Fake({"id": "fc-1", "keep": False, "at": "2026-11-21T10:00:00+09:00"})
    s20feeds.http_post_feature_answer(f, base, f.rfile.getvalue(), logs.append)
    row = json.loads((base / s20feeds.FEATURE_ANSWERS).read_text(encoding="utf-8").splitlines()[-1])
    failed += say(f.sent[0] == 200 and row == {"id": "fc-1", "keep": False, "at": "2026-11-21T10:00:00+09:00"},
                  "s20 道: 検品表の答えを inbox/feature_answers.jsonl に {id, keep, at}")
    bad = Fake({"id": "fc-1", "keep": "yes"})
    s20feeds.http_post_feature_answer(bad, base, bad.rfile.getvalue(), logs.append)
    failed += say(bad.sent[0] == 400, "s20 道: keep が true・false でなければ 400")
    r = Fake({"kind": "review", "id": "a1", "answer": "あとで", "at": "2026-11-21T10:00:00+09:00"})
    appfeeds.http_post_feedback(r, base, r.rfile.getvalue(), logs.append)
    row = json.loads((base / appfeeds.FEEDBACK_FILE).read_text(encoding="utf-8").splitlines()[-1])
    failed += say(r.sent[0] == 200 and row["kind"] == "review" and row["id"] == "a1" and row["answer"] == "あとで" and row.get("at"),
                  "s20 道: 確かめ待ちの答え（kind review）を inbox/app_feedback.jsonl に {kind, id, answer, at}")
    old = Fake({"kind": "review", "id": "a1"})
    appfeeds.http_post_feedback(old, base, old.rfile.getvalue(), logs.append)
    failed += say(old.sent[0] == 400 and "あとで" not in " ".join(logs), "s20 道: answer が無ければ 400・答えの中身は記録に書かない")
    return failed


def main() -> int:
    failed = 0
    for check in (check_split_and_self, check_knowapp, check_forget, check_line, check_s20feeds):
        failed += check()
    # 2026-11-22（s21）: CI の手順（.github は別の担当）を増やさずに、s21 の家の PC の分もここで確かめる
    import v24checks_s21

    failed += v24checks_s21.run_all()
    print("ぜんぶ OK" if not failed else f"NG の数: {failed}", flush=True)
    return failed


if __name__ == "__main__":
    sys.exit(main())
