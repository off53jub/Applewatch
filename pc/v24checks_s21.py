"""2026-11-22（s21。担当 P）: 家の PC の分を確かめる。決まりは docs/s21-pc.md。

    python pc/v24checks_s21.py          （v24checks_s20.py の最後にも呼ばれる。CI の手順を増やさずに動かすため）

本物の HOME・母艦・LINE・iPhone は使わない（一時フォルダに作り物を作る。人の名前は「甲」「乙」などの記号だけ。
LINE の鍵・userId も作り物）。確かめること（check_*）:
- 速1・速3 jobqueue: 次に文字にする順（待ち合わせ → 新しい区切り → 古い区切り・古い区切りも 3 時間で先に）・
  wait の印と latency の waited・watch・失敗の理由（on_failed）・sampleNoVoice の印
- 速3 jobfirst: 新しい区切りが待っている・文字にしている・待ち合わせのときだけ譲る（古い区切りだけなら譲らない・設定で止まる）
- 精6 trainer: 材料 30 個からは、そろう前でも 01:00〜05:00 に部品を用意し始める（30 個より少ない・時間の外・設定でやめた・
  そろっていれば今までどおり）・あと何個（need）・時間帯の既定は 02:00〜05:00
- 精1・精10 plaudmatch: PLAUD と記録の行の文字の合い方・3 日前まで quality-daily.json へ・モデルごとの当たり率と重み（仮）・
  iPhone の重みに掛ける（0.5〜2.0・設定でやめる）
- 精15 goldset: 自動の材料は正解集に入れない・版が変わったら点数を出す・途中で止めたら書かない・summary の行
- 速9 housekeep: 15 日より前の行だけ縮めて移す・日付の無い行は前の行と一緒・空きが少なければ詰めない
- 速4 threadcpu: 糸ごとの増えた分・名前のまとめ方・名前の無い糸（全体との差）
- 使13 linehook: 「きのう」で日のまとめを返す（記録に足さない・[[ ]] と source を外す・長さ）・無い日は「まだ」・本人でなければ返さない
- 使10 appfeeds: POST /feedback の kind shake（形・400・inbox に 1 行）と summary の数
- 電1・電2・守1・守5・精11・精7・速8 s21pc: summary の節（電池の減り・送り方の実験・止まりかけ・版のずれ（気になる所にも）・
  人物N・声が無いはずの区切り・失敗の理由）と、見回り（tick）が夜に PLAUD の合い方を書くこと
- 精12 hintpolicy: 会う人の名前は既定で足さない・入れたら予定に出てくる人だけ
- 使12 updater: 確かめる間が 1 時間
"""

from __future__ import annotations

import base64
import datetime
import gzip
import hashlib
import hmac
import io
import json
import os
import sqlite3
import sys
import tempfile
import threading
import time
import wave
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent))

if "v24s20-" not in os.environ.get("LOCALAPPDATA", ""):  # 単独で動かすときも、本物の HOME に触れない
    os.environ["LOCALAPPDATA"] = str(Path(tempfile.mkdtemp(prefix="v24s21-local-")))
os.environ.pop("LIFELOG_LINE_CHANNEL_SECRET", None)
os.environ.pop("LINE_CHANNEL_ACCESS_TOKEN", None)

import numpy as np  # noqa: E402

import appfeeds  # noqa: E402
import diag  # noqa: E402
import goldset  # noqa: E402
import hintpolicy  # noqa: E402
import housekeep  # noqa: E402
import jobfirst  # noqa: E402
import jobqueue  # noqa: E402
import linehook  # noqa: E402
import mothership  # noqa: E402
import plaudmatch  # noqa: E402
import quality  # noqa: E402
import s21pc  # noqa: E402
import threadcpu  # noqa: E402
import trainer  # noqa: E402
import updater  # noqa: E402
from v6checks import say  # noqa: E402

TMP = Path(tempfile.mkdtemp(prefix="v24s21-"))
SECRET = "check-channel-secret"
OWNER = "U" + "a" * 32
OTHER = "U" + "b" * 32
RNG = np.random.default_rng(21)


class Fake:
    """作り物の受け口（Handler の代わり）"""
    client_address = ("127.0.0.1", 0)

    def __init__(self, body=b"") -> None:
        data = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.headers = {"Content-Length": str(len(data))}
        self.rfile = io.BytesIO(data)
        self.sent = None

    def send_json(self, status: int, body: dict) -> None:
        self.sent = (status, body)


def local(y, mo, d, h=0, mi=0, s=0) -> float:
    return datetime.datetime(y, mo, d, h, mi, s).timestamp()


def make_queue(name: str) -> jobqueue.JobQueue:
    return jobqueue.JobQueue(TMP / name, lambda *_: ({"lines": []}, {}), lambda _m: None)


def meta(name: str, seq: int, queued_at: float, recorded: float | None = None, status: str = "queued", **extra) -> dict:
    out = {"id": name, "status": status, "seq": seq, "queued_at": queued_at, "params": {}}
    if recorded is not None:
        out["times"] = {"chunk_start": recorded}
    out.update(extra)
    return out


# MARK: - 速1・速3


def check_jobqueue() -> int:
    failed = 0
    q = make_queue("jobs-order")
    now = time.time()
    q.jobs = {"old1": meta("old1", 1, now - 600, now - 4 * 86400), "old2": meta("old2", 2, now - 590, now - 4 * 86400),
              "new1": meta("new1", 3, now - 60, now - 300), "new2": meta("new2", 4, now - 30, now - 200)}
    with q.lock:
        first = q.next_job()[0]
    failed += say(first == "new2", f"速3: 古い区切り（4 日前の時計のまとめ送り）があっても、新しい区切りの新しい順から（{first}）")
    q.waiters["new1"] = 1
    with q.lock:
        waited = q.next_job()[0]
    q.waiters.clear()
    failed += say(waited == "new1", f"速1: 待ち合わせで待っている人がいる仕事をいちばん先に（{waited}）")
    q.jobs["old1"]["queued_at"] = now - 4 * 3600
    with q.lock:
        starved = q.next_job()[0]
    failed += say(starved == "old1", f"速3: 古い区切りも 3 時間より長く待ったら先にする（{starved}）")
    q.jobs = {"old1": meta("old1", 1, now - 1200, now - 4 * 86400), "old2": meta("old2", 2, now - 60, now - 4 * 86400)}
    with q.lock:
        only_old = q.next_job()[0]
    failed += say(only_old == "old1", f"速3: 古い区切りだけなら今までの決まり（15 分より長く待ったものを先に: {only_old}）")
    q.jobs = {"a": meta("20261122-030000.m4a", 1, now - 10), "b": meta("b", 2, now - 5)}
    q.jobs = {m["id"]: m for m in q.jobs.values()}
    recorded = jobqueue.recorded_at(q.jobs["20261122-030000.m4a"])
    failed += say(abs(recorded - local(2026, 11, 22, 3, 0)) < 1 and jobqueue.recorded_at(q.jobs["b"]) == now - 5,
                  "速3: 録った時刻は chunk_start → 名前の頭 → 受けた時刻の順で見る")
    # 待ち合わせの印と latency
    done = time.time()
    q.jobs = {"w1": meta("w1", 1, done - 100, status="done", started_at=done - 90, done_at=done - 80, wait=True, handed=True),
              "w2": meta("w2", 2, done - 100, status="done", started_at=done - 90, done_at=done - 70, wait=True),
              "x-w.m4a": meta("x-w.m4a", 3, done - 100, status="done", started_at=done - 90, done_at=done - 60, origin="watch")}
    stats = q.latency()
    lines = diag.pc_latency(stats)
    failed += say(stats["waited"] == 2 and stats["handed"] == 1 and stats["watch"] == 1
                  and any("待ち合わせで渡した: 1 / 2 件" in x and "時計から直接の 1 件" in x for x in lines),
                  f"速1: 渡した割合の分母は待ち合わせを頼まれた数・時計の仕事は分けて出す（{lines[-1]}）")
    params = jobqueue.parse_params({"sampleNoVoice": ["1"], "hints": ["甲\n乙"]})
    failed += say(params.get("sample_no_voice") is True and "sample_no_voice" not in jobqueue.parse_params({}),
                  "精7: sampleNoVoice=1 を params に残す（無ければ付けない）")
    reasons = [jobqueue.fail_reason(x) for x in ("InvalidDataError(1, 'Invalid data')", "ConnectionAbortedError(10053)",
                                                 "文字にしている最中に LifeLog PC が 3 回止まったので", None)]
    failed += say(reasons == ["音声を読めない", "送り手が途中で切った", "PC が途中で止まった", "そのほか"],
                  f"速8: 失敗の文を理由に分ける（{reasons}）")
    got: list[str] = []
    results: list[str] = []
    q2 = jobqueue.JobQueue(TMP / "jobs-fail", lambda *_: (_ for _ in ()).throw(RuntimeError("InvalidDataError(1)")),
                           lambda _m: None)
    q2.on_failed = got.append
    q2.on_result = lambda name, m: results.append(m["status"])
    (TMP / "jobs-fail").mkdir(exist_ok=True)
    q2.part_path("j1").write_bytes(b"x")
    q2.receiving.add("j1")
    q2.commit("j1", {}, 1, wait=True)
    first_meta = dict(q2.jobs["j1"])
    q2.step()
    q2.note_receive_failed(ConnectionAbortedError(10053, "x"))
    failed += say(first_meta.get("wait") is True and got == ["音声を読めない", "受け取り: 送り手が途中で切った"] and results == ["failed"],
                  f"速8: 失敗は on_failed に理由で知らせ（{got}）、でき上がり・失敗は on_result に（{results}）。wait の印を残す")
    return failed


def check_jobfirst() -> int:
    failed = 0
    q = make_queue("jobs-first")
    now = time.time()
    jobfirst.register(None)
    failed += say(jobfirst.busy() is False, "速3: 仕事の列が無ければ譲らない")
    jobfirst.register(q, lambda: {})
    q.jobs = {"old": meta("old", 1, now - 60, now - 3 * 86400)}
    old_only = jobfirst.busy()
    q.jobs["new"] = meta("new", 2, now - 10, now - 120)
    fresh = jobfirst.busy()
    q.jobs["new"]["status"] = "done"
    done = jobfirst.busy()
    q.waiters["old"] = 1
    waiting = jobfirst.busy()
    q.waiters.clear()
    q.jobs["new"]["status"] = "working"
    working = jobfirst.busy()
    jobfirst.register(q, lambda: {"jobs_first": False})
    off = jobfirst.busy()
    jobfirst.register(q, lambda: {})
    naps: list[float] = []
    q.jobs["new"]["status"] = "queued"
    day_wait = jobfirst.wait_at_night(hour=10, limit=3, sleep=naps.append)
    night_wait = jobfirst.wait_at_night(hour=3, limit=3, sleep=naps.append)
    q.jobs["new"]["status"] = "working"
    working_wait = jobfirst.wait_at_night(hour=3, limit=3, sleep=naps.append)
    failed += say(day_wait == 0 and night_wait == 3 and working_wait == 0 and len(naps) == 3,
                  f"速3: 00:00〜06:00 の /transcribe は、新しい区切りが待っていれば上限まで待つ（昼 {day_wait}・夜 {night_wait}・"
                  f"文字にしている最中の 1 つだけ {working_wait} 秒）")
    jobfirst.register(None, lambda: {})
    failed += say(not old_only and fresh and not done and waiting and working and not off,
                  f"速3: 新しい区切りが待っている（{fresh}）・文字にしている（{working}）・待ち合わせ（{waiting}）のときだけ譲る。"
                  f"古い区切りだけ（{old_only}）・終わった（{done}）・\"jobs_first\": false（{off}）なら譲らない")
    return failed


# MARK: - 精6


class FakeRuntime:
    def __init__(self, ready: bool = False) -> None:
        self.requirements = Path(__file__).resolve().parent / trainer.REQUIREMENTS
        self.is_ready = ready
        self.preparing = False
        self.prepared = 0
        self.drop_paths: list = []
        self.python = Path(sys.executable)

    def ready(self) -> bool:
        return self.is_ready

    def status(self) -> str:
        return "用意できています" if self.is_ready else "まだありません"

    def prepare(self) -> None:
        self.prepared += 1
        self.is_ready = True


def check_trainer() -> int:
    failed = 0
    clock = {"t": local(2026, 11, 22, 3, 0)}
    counter = {"n": 46}

    def make(config: dict | None = None, ready: bool = False):
        runtime = FakeRuntime(ready)
        auto = trainer.AutoTrainer(TMP / "train-home", Path(__file__).resolve().parent, lambda _m: None, gpu_plan=None,
                                   ollama=None, count_samples=lambda: counter["n"], is_idle=lambda: True,
                                   has_gpu=lambda: True, on_improved=lambda: None, runtime=runtime,
                                   clock=lambda: clock["t"])
        auto.configure(config or {})
        return auto, runtime

    def tick(auto) -> None:
        auto.tick()
        for thread in threading.enumerate():
            if thread.name == "train-prepare":
                thread.join(timeout=10)

    auto, runtime = make()
    tick(auto)
    status = auto.status()
    failed += say(runtime.prepared == 1 and status["state"] == "材料を待っています" and status["need"] == 254,
                  f"精6: 材料 46 個（300 に足りない）でも、03:00 なら部品を用意し始める（{runtime.prepared} 回）・あと {status['need']} 個")
    counter["n"] = 12
    auto, runtime = make()
    tick(auto)
    few = runtime.prepared
    counter["n"] = 46
    clock["t"] = local(2026, 11, 22, 5, 30)
    auto, runtime = make()
    tick(auto)
    late = runtime.prepared
    clock["t"] = local(2026, 11, 22, 3, 0)
    auto, runtime = make({"autotrain": {"prepare_ahead": False}})
    tick(auto)
    off = runtime.prepared
    failed += say(few == 0 and late == 0 and off == 0,
                  f"精6: 材料 30 個より少ない（{few}）・05:00 より後（{late}）・\"prepare_ahead\": false（{off}）なら用意しない")
    counter["n"] = 320
    auto, runtime = make(ready=False)
    clock["t"] = local(2026, 11, 22, 5, 30)
    tick(auto)
    failed += say(runtime.prepared == 0 and "1:00〜5:00" in auto.status()["state"],
                  f"精6: 材料がそろっていても、部品を用意するのは 01:00〜05:00 だけ（{auto.status()['state']}）")
    failed += say(trainer.window_text(trainer.train_config({})) == "日曜 02:00〜05:00",
                  "精6: 学び直しの時間帯の既定は 02:00〜05:00（重い仕事は 05:00 まで）")
    return failed


# MARK: - 精1・精10


def cjk(count: int) -> str:
    return "".join(chr(0x4E00 + int(x)) for x in RNG.integers(0, 20000, count))


def make_plaud_world(home: Path, mother: Path, day: str = "2026-11-20", lines: int = 35) -> list[str]:
    """PLAUD の公式の文字起こし（10:00 から 30 秒ごと）・同じ時刻の記録の行（5 行に 1 文字ずつ違う）・票のある仕事の答え"""
    texts = [cjk(15) for _ in range(lines)]
    folder = mother / "archive" / "plaud" / day[:4] / day[5:7]
    folder.mkdir(parents=True, exist_ok=True)
    body = [f"- date: {day}", "- startTime: 10:00", "", "# 作り物の録音", ""]
    for i, text in enumerate(texts):
        body += [f"甲 {i * 30 // 3600:02d}:{i * 30 // 60 % 60:02d}:{i * 30 % 60:02d}", text, ""]
    (folder / f"{day[8:10]}_check.md").write_text("\n".join(body), encoding="utf-8")
    base = datetime.datetime.fromisoformat(day + "T10:00:00")
    rec_lines = []
    for i, text in enumerate(texts):
        when = (base + datetime.timedelta(seconds=i * 30)).astimezone(datetime.timezone.utc)
        changed = text if i % 5 else "〇" + text[1:]
        rec_lines.append({"time": when.strftime("%Y-%m-%dT%H:%M:%S.000Z"), "text": changed, "audio": "a", "offset": i * 30.0})
    (home / "records").mkdir(parents=True, exist_ok=True)
    (home / "records" / f"{day}.json").write_text(json.dumps({"conversations": [{"lines": rec_lines}]}, ensure_ascii=False),
                                                  encoding="utf-8")
    jobs = home / "jobs"
    jobs.mkdir(parents=True, exist_ok=True)
    name = day.replace("-", "") + "-100000.m4a"
    (jobs / "j1.json").write_text(json.dumps({"id": name}), encoding="utf-8")
    votes = [{"start": i * 30.0, "text": t, "votes": {"haas": t, "reazon": t[:7] + cjk(8), "whisper": t[:12] + cjk(3)}}
             for i, t in enumerate(texts)]
    (jobs / "j1.result").write_text(json.dumps({"lines": votes}, ensure_ascii=False), encoding="utf-8")
    return texts


def check_plaudmatch() -> int:
    failed = 0
    home, mother = TMP / "home-p", TMP / "mother-p"
    texts = make_plaud_world(home, mother)
    stats = plaudmatch.day_match(home, mother, "2026-11-20")
    chars = sum(len(t) for t in texts)
    expect = round((chars - 7) / chars, 3)  # 35 行のうち 7 行で 1 文字ずつ違う
    failed += say(stats["timed"] == 1 and stats["lines"] == 35 and stats["match"] == expect,
                  f"精1: PLAUD の時刻を合わせ、記録の行の文字のうち合った割合（{stats['match']}・{stats['lines']} 行。{expect} のはず）")
    few = plaudmatch.day_match(home, mother, "2026-11-19")
    failed += say(few["match"] is None and few["lines"] == 0, "精1: PLAUD が無い日は測れない（None）")
    got = plaudmatch.nightly(home, mother, datetime.date(2026, 11, 21), quality.update_day)
    days = quality.read_daily(home)["days"]
    failed += say(got.get("2026-11-20") == expect and days["2026-11-20"]["plaud_match_lines"] == 35
                  and "plaud_match" in days["2026-11-20"] and "2026-11-18" not in days,
                  f"精1: 毎晩、昨日（と 3 日前まで、測れた日だけ）を quality-daily.json の plaud_match・plaud_match_lines に（{got}）")
    rates = plaudmatch.engine_rates(home, mother, datetime.date(2026, 11, 21))
    weights = plaudmatch.weights_from(rates)
    failed += say(rates["haas"]["rate"] == 1.0 and rates["reazon"]["rate"] < rates["whisper"]["rate"] < 1.0
                  and weights["haas"] > 1.0 and weights["reazon"] == plaudmatch.WEIGHT_MIN and weights["whisper"] == 1.0,
                  f"精10: モデルごとの当たり率（haas {rates['haas']['rate']}・whisper {rates['whisper']['rate']}・"
                  f"reazon {rates['reazon']['rate']}）から重み（{weights}。0.8〜1.2・仮）")
    small = plaudmatch.weights_from({"haas": {"rate": 0.9, "lines": 3, "chars": 40}, "reazon": {"rate": 0.5, "lines": 3, "chars": 40}})
    failed += say(small == {"haas": 1.0, "reazon": 1.0}, "精10: 数が足りないモデルの重みは 1（変えない）")
    body = plaudmatch.weekly(home, mother, datetime.datetime(2026, 11, 21, 3, 0))
    again = plaudmatch.weekly(home, mother, datetime.datetime(2026, 11, 21, 3, 10))
    merged = plaudmatch.merge({"haas": 1.9, "whisper": 0.7}, home, {})
    off = plaudmatch.merge({"haas": 1.9}, home, {"engine_weights": False})
    failed += say(body is not None and again is None and (home / plaudmatch.WEIGHTS_FILE).is_file()
                  and merged["haas"] == 2.0 and merged["whisper"] == 0.7 and merged["reazon"] == plaudmatch.WEIGHT_MIN
                  and off == {"haas": 1.9},
                  f"精10: 週 1 回だけ数え直し、iPhone の重みに掛ける（0.5〜2.0。{merged}）・\"engine_weights\": false で iPhone のまま")
    return failed


# MARK: - 精15


def write_wav(path: Path, seconds: float) -> None:
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(np.zeros(int(seconds * 16000), dtype="<i2").tobytes())


def check_goldset() -> int:
    failed = 0
    home = TMP / "home-g"
    folder = home / "personal" / "data"
    folder.mkdir(parents=True)
    rows = [("a.wav", 1.0, "今日は晴れ", None), ("b.wav", 2.0, "明日は雨", {"origin": "pc-review"}),
            ("c.wav", 3.0, "会議です", {"origin": "pc-auto", "auto": True}), ("d.wav", 4.0, "出張です", None)]
    with (folder / "samples.jsonl").open("w", encoding="utf-8") as f:
        for name, seconds, text, source in rows:
            write_wav(folder / name, seconds)
            f.write(json.dumps({"audio": name, "text": text, "seconds": seconds, **({"source": source} if source else {})},
                               ensure_ascii=False) + "\n")
    found = goldset.items(folder)
    failed += say([x["text"] for x in found] == ["今日は晴れ", "明日は雨", "出張です"],
                  "精15: 正解集は人が確かめた材料だけ（自動の材料 pc-auto は入れない）")
    heard = {1.0: ("今日は晴れ", "今日は春"), 2.0: ("明日は雨", "明日は雨"), 4.0: ("出張です", "出張でした")}

    def transcribe(audio):
        voted, other = heard[round(len(audio) / 16000, 1)]
        return [{"text": voted, "votes": {"haas": voted, "whisper": other}}]

    logs: list[str] = []
    failed += say(goldset.due(home, 7, len(found)), "精15: まだ点数の無い版は点数を出す時")
    stopped = goldset.score(home, folder, 7, transcribe, lambda: True, logs.append)
    failed += say(stopped is None and not (home / goldset.FILE).exists(), "精15: 新しい区切りが来たら途中でやめ、書かない")
    entry = goldset.score(home, folder, 7, transcribe, lambda: False, logs.append)
    expect_whisper = round((2 + 0 + 2) / (5 + 4 + 4), 4)  # 晴れ→春（置き換え・抜け）・です→でした（置き換え・足し）
    failed += say(entry is not None and entry["items"] == 3 and entry["cer"] == 0.0 and entry["engines"]["whisper"] == expect_whisper
                  and not goldset.due(home, 7, 3) and goldset.due(home, 8, 3) and goldset.due(home, 7, 3 + goldset.RESCORE_GROWTH),
                  f"精15: 多数決とモデルごとの誤りの割合（{entry}）・同じ版は出し直さない（正解集が 20 増えたら出し直す）")
    lines = goldset.lines_for_summary(home)
    failed += say(len(lines) == 1 and lines[0].startswith("版 7") and "多数決 0.0%" in lines[0] and "whisper" in lines[0],
                  f"精15: summary.md の行（{lines}）")
    failed += say(goldset.edit_distance("きょう", "きのう") == 1 and goldset.cer([("あいう", "あいう")]) == 0.0,
                  "精15: 文字の誤りの数え方（置き換え 1）")
    return failed


# MARK: - 速9・速4


def check_housekeep() -> int:
    failed = 0
    folder = TMP / "home-h"
    folder.mkdir()
    log = folder / "log.txt"
    old = "".join(f"2026-10-{d:02d} 10:00:00 古い行 {d}\n" for d in range(1, 31)) + "  続きの行（日付なし）\n"
    new = "".join(f"2026-11-{d:02d} 10:00:00 新しい行 {d}\n" for d in range(8, 23))
    log.write_text(old + new, encoding="utf-8")
    lock = threading.Lock()
    small = housekeep.rotate_log(log, lock, folder / "logs", datetime.datetime(2026, 11, 22, 12), limit=10 ** 9)
    moved = housekeep.rotate_log(log, lock, folder / "logs", datetime.datetime(2026, 11, 22, 12), limit=100)
    kept = log.read_text(encoding="utf-8")
    # Windows の write_text は改行を \r\n で書く（縮めたものはファイルのまま）
    archived = gzip.decompress(moved.read_bytes()).decode("utf-8").replace("\r\n", "\n") if moved else ""
    failed += say(small is None and moved is not None and kept == new and archived == old,
                  f"速9: log.txt が大きいときだけ、15 日より前の行（日付の無い続きの行も）を {moved.name if moved else '—'} に縮めて移す")
    again = housekeep.rotate_log(log, lock, folder / "logs", datetime.datetime(2026, 11, 22, 13), limit=100)
    failed += say(again is None and log.read_text(encoding="utf-8") == new, "速9: 15 日より前の行が無ければ何もしない（消さない）")
    db = folder / "s.db"
    con = sqlite3.connect(db)
    con.execute("CREATE TABLE t(x)")
    con.executemany("INSERT INTO t VALUES (?)", [("x" * 1000,)] * 500)
    con.commit()
    full = housekeep.db_stats(db)
    con.execute("DELETE FROM t")
    con.commit()
    con.close()
    empty = housekeep.db_stats(db)
    night = datetime.datetime(2026, 11, 22, 3)
    failed += say(full["free"] == 0 and empty["free"] > 0.5 and not housekeep.vacuum_due(full, 0, night)
                  and housekeep.vacuum_due(empty, 0, night) and not housekeep.vacuum_due(empty, 0, datetime.datetime(2026, 11, 22, 10))
                  and not housekeep.vacuum_due(empty, time.time(), night),
                  f"速9: semantic.db は空きが 10% 以上・00:00〜05:00・前から 7 日のときだけ詰める（空き {full['free']:.0%} → {empty['free']:.0%}）")
    done = housekeep.vacuum(db, lambda _m: None)
    failed += say(done and housekeep.db_stats(db)["bytes"] < empty["bytes"], "速9: 詰めると小さくなる（行は消さない）")
    return failed


def check_threadcpu() -> int:
    failed = 0
    values = {1: 10.0, 2: 5.0}
    total = {"t": 100.0}
    meter = threadcpu.Meter(TMP / "home-t", reader=lambda ident: values.get(ident), process=lambda: total["t"])
    (TMP / "home-t").mkdir()
    threads = [SimpleNamespace(native_id=1, name="jobs"), SimpleNamespace(native_id=2, name="Thread-12 (process_request_thread)")]
    first = meter.sample(threads)
    values.update({1: 40.0, 2: 6.0})
    total["t"] = 200.0
    added = meter.sample(threads)
    meter.add(added, "2026-11-22")
    line = threadcpu.summary_line(TMP / "home-t", "2026-11-22")
    failed += say(first == {} and added == {"jobs": 30.0, "受け付けなど（process_request_thread）": 1.0, threadcpu.NATIVE: 69.0}
                  and line is not None and "モデルの中の計算など" in line and "69%" in line,
                  f"速4: 糸ごとの増えた分と、名前の無い糸（全体との差）（{added}）・{line}")
    failed += say(threadcpu.label("ThreadPoolExecutor-0_3").startswith("多数決") and threadcpu.label("knowme") == "knowme",
                  "速4: 名前は数字を除いてまとめる")
    return failed


# MARK: - 使13・使10


def check_line_day() -> int:
    failed = 0
    home, mother = TMP / "home-l", TMP / "mother-l"
    home.mkdir()
    (mother / "digests" / "daily").mkdir(parents=True)
    (home / linehook.SECRET_FILE).write_text(SECRET + "\n", encoding="utf-8")
    (home / linehook.TOKEN_FILE).write_text("check-access-token\n", encoding="utf-8")
    (home / linehook.OWNER_FILE).write_text(OWNER + "\n", encoding="utf-8")
    (mother / "digests" / "daily" / "2026-11-21.md").write_text(
        "---\ntype: digest\n---\n# 2026-11-21 日報\n\n## サマリ\n\n[[甲]]と[[UAT|受入テスト]]の話をした。\n\n## 使ったお金\n\n計 500円\n\n"
        "## 主要な出来事\n\n- 10:00 会議 (source: canonical, 10:00〜11:00)\n" + "".join(f"- {h}:00 予定{h}\n" for h in range(11, 23))
        + "\n## 新規 TODO\n\n- [ ] 何か\n", encoding="utf-8")
    sent: list[tuple] = []
    noted: list[tuple] = []
    sig = lambda b: base64.b64encode(hmac.new(SECRET.encode(), b, hashlib.sha256).digest()).decode()  # noqa: E731

    def body_of(text, user=OWNER, eid="d1"):
        return json.dumps({"events": [{"type": "message", "webhookEventId": eid, "replyToken": "rt-" + eid,
                                       "source": {"type": "user", "userId": user},
                                       "message": {"type": "text", "id": "1", "text": text}}]}, ensure_ascii=False).encode()

    logs: list[str] = []
    body = body_of("きのう")
    st, _ = linehook.handle(body, sig(body), home, {}, mother, logs.append, lambda t, r: noted.append((t, r)) or True,
                            lambda t, r, text: sent.append((r, text)) or True, today=datetime.date(2026, 11, 22))
    text = sent[0][1] if sent else ""
    failed += say(st == 200 and len(sent) == 1 and sent[0][0] == "rt-d1" and text.startswith("2026-11-21 のまとめ")
                  and "甲と受入テストの話をした。" in text and "会議" in text and "source" not in text and "[[" not in text
                  and "500円" not in text and "何か" not in text and len(text) <= linehook.DAY_REPLY_MAX
                  and not (mother / linehook.NOTES).exists() and not noted,
                  "使13: 「きのう」で母艦の日のまとめの「サマリ」「主要な出来事」を短く切って返す（記録には足さない・[[ ]] と source を外す）")
    short = linehook.day_summary(mother, "2026-11-21", limit=40)
    failed += say(short is not None and len(short) == 40 and short.endswith("…"), "使13: 長いまとめは切る（…）")
    sent.clear()
    body = body_of("今日", eid="d2")
    linehook.handle(body, sig(body), home, {}, mother, logs.append, None, lambda t, r, text: sent.append((r, text)) or True,
                    today=datetime.date(2026, 11, 22))
    failed += say(len(sent) == 1 and "まだありません" in sent[0][1], f"使13: まとめがまだ無い日は「まだありません」（{sent[0][1] if sent else '—'}）")
    sent.clear()
    body = body_of("きのう", user=OTHER, eid="d3")
    linehook.handle(body, sig(body), home, {}, mother, logs.append, None, lambda t, r, text: sent.append((r, text)) or True,
                    today=datetime.date(2026, 11, 22))
    failed += say(not sent and not any("受入" in x for x in logs), "使13: 本人でなければ返さない・記録（log.txt）に中身を書かない")
    words = [linehook.day_word(x) for x in ("今日", "きのう？", "昨日のまとめ", "今日はいい日", "メモ")]
    failed += say(words == [0, 1, 1, None, None], f"使13: 「今日」「きのう」だけの文を見分ける（{words}）")
    return failed


def check_shake() -> int:
    failed = 0
    base = TMP / "mother-s"
    base.mkdir()
    logs: list[str] = []
    good = Fake({"kind": "shake", "screen": "日の画面", "note": "表が崩れた", "at": "2026-11-22T10:00:00+09:00"})
    appfeeds.http_post_feedback(good, base, good.rfile.getvalue(), logs.append)
    row = json.loads((base / appfeeds.FEEDBACK_FILE).read_text(encoding="utf-8").splitlines()[-1])
    failed += say(good.sent[0] == 200 and row["kind"] == "shake" and row["screen"] == "日の画面" and row["note"] == "表が崩れた"
                  and row["sent_at"] == "2026-11-22T10:00:00+09:00" and row.get("at") and not any("崩れ" in x for x in logs),
                  "使10: kind shake を inbox/app_feedback.jsonl に {kind, screen, note, sent_at, at}（中身は記録に書かない）")
    for label, body in (("screen が無い", {"kind": "shake"}), ("note が長い", {"kind": "shake", "screen": "x", "note": "あ" * 501}),
                        ("at が日時でない", {"kind": "shake", "screen": "x", "at": "きのう"})):
        bad = Fake(body)
        appfeeds.http_post_feedback(bad, base, bad.rfile.getvalue(), logs.append)
        failed += say(bad.sent[0] == 400, f"使10: {label}なら 400")
    today = datetime.date.fromisoformat(row["at"][:10])
    line = s21pc.shake_line(base, today)
    failed += say(line is not None and "1 件" in line and "日の画面 1" in line, f"使10: summary.md に 7 日の数と画面（{line}）")
    return failed


# MARK: - summary の節（電1・電2・守1・守5・精11・精7・速8）と見回り


def write_day(folder: Path, day: str, states: list[dict], build: int = 356) -> None:
    folder.mkdir(parents=True, exist_ok=True)
    with (folder / f"{day}.jsonl").open("w", encoding="utf-8") as f:
        for state in states:
            f.write(json.dumps({"deviceID": folder.name, "build": build, "state": state}) + "\n")


def check_summary() -> int:
    failed = 0
    home, mother = TMP / "home-sum", TMP / "mother-sum"
    home.mkdir()
    mother.mkdir()
    logs: list[str] = []
    s21pc.S.home = home
    s21pc.S.main = SimpleNamespace(PERSONAL_DATA=home / "personal" / "data", LOG=home / "log.txt", SEMANTIC_DB=home / "semantic.db",
                                   load_config=lambda: {"lifelog_home": str(mother)}, mothership=mothership, log=logs.append,
                                   LOG_LOCK=threading.Lock(), Handler=SimpleNamespace(engine=None), BUILD=0)
    store = diag.DiagStore(home / "diag", logs.append)
    device = "CHECKDEV-0001"
    today = datetime.date.today()
    yesterday, before = (today - datetime.timedelta(days=1)), (today - datetime.timedelta(days=2))

    def samples(day: datetime.date, per_hour: float) -> list[list]:
        start = datetime.datetime.combine(day, datetime.time(8)).timestamp()
        out = [[start + h * 3600, round(1.0 - per_hour * h, 3), 0] for h in range(10)]
        out.append([start + 10 * 3600, 1.0, 0])  # 充電した（増えた分は数えない）
        return out

    write_day(store.folder / device, before.isoformat(),
              [{"watchBatteryAt": samples(before, 0.04), "watchStalls": 1, "watchAutoResumed": 1, "watchRouteExp": "phone"}])
    write_day(store.folder / device, yesterday.isoformat(),
              [{"watchBatteryAt": samples(yesterday, 0.05), "watchStalls": 2, "watchRouteExp": "direct"},
               {"watchStalls": 3, "watchAutoResumed": 2, "watchRouteExp": "direct"}])
    store.receive({"deviceID": device, "device": "iPhone", "model": "iPhone18,1", "build": 357,
                   "state": {"watchBuild": "356", "watchStalls": 0, "watchAutoResumed": 0}})
    worries, lines = s21pc.summary_lines(store)
    text = "\n".join(lines)
    failed += say(f"{yesterday.isoformat()[5:]} 5.0%（direct）" in text and f"{before.isoformat()[5:]} 4.0%（phone）" in text,
                  "電1・電2: 時計の電池の 1 時間あたりの減り（充電した所は数えない）を日ごとに、その日の送り方の組と並べる")
    failed += say("direct 5.0%（1 日）" in text and "phone 4.0%（1 日）" in text, "電2: 送り方ごとの減りの真ん中")
    failed += say(f"{yesterday.isoformat()[5:]} 3 回（自動で戻せた 2）" in text and f"{today.isoformat()[5:]} 0 回" in text,
                  "守1: 時計の止まりかけと自動で戻せた回数を 3 日の並びで（その日の最後の数）")
    failed += say("iPhone 357・時計 356（ずれています）" in text and any("ずれています" in w for w in worries),
                  "守5: iPhone と時計の版のずれを summary.md と気になる所に")
    store2 = diag.DiagStore(home / "diag2", logs.append)
    store2.receive({"deviceID": "CHECKDEV-0002", "build": 357, "state": {}})
    _, plain = s21pc.summary_lines(store2)
    failed += say(not any("時計の電池" in x or "版:" in x or "止まりかけ" in x for x in plain),
                  "電1・電2・守1・守5: アプリがまだ送っていなければ黙って出さない")
    # 精11 人物N・精7・速8・精1 の行
    (home / "records").mkdir()
    for back, ids in ((2, [1, 2, 3]), (1, [3, 4, 9]), (0, [9, 10])):
        day = (today - datetime.timedelta(days=back)).isoformat()
        conv = {"lines": [{"speaker": f"人物{i}", "text": "…"} for i in ids] + [{"speaker": "自分", "text": "…"}]}
        (home / "records" / f"{day}.json").write_text(json.dumps({"conversations": [conv]}, ensure_ascii=False), encoding="utf-8")
    s21pc.note_result("j", {"status": "done", "lines": 2, "params": {"sample_no_voice": True}})
    s21pc.note_result("j", {"status": "done", "lines": 0, "params": {"sample_no_voice": True}})
    s21pc.note_result("j", {"status": "done", "lines": 5, "params": {}})
    s21pc.note_failed("音声を読めない")
    s21pc.note_failed("受け取り: 送り手が途中で切った")
    s21pc.note_failed("受け取り: 送り手が途中で切った")
    quality.update_day(home, yesterday.isoformat(), {"plaud_match": 0.73, "plaud_match_lines": 120})
    _, lines = s21pc.summary_lines(store2)
    text = "\n".join(lines)
    failed += say(f"{yesterday.isoformat()[5:]} 3 人・番号 +6" in text and f"{today.isoformat()[5:]} 2 人・番号 +1" in text,
                  "精11: 人物N の日ごとの人数と、新しく振られた番号の数（前の日までのいちばん大きい番号から）")
    failed += say("2 個（声があった 1）" in text, "精7: 印つきの「声が無いはずの区切り」の数と、本当は声があった数（印の無い区切りは数えない）")
    failed += say("受け取り: 送り手が途中で切った 2・音声を読めない 1" in text, "速8: 失敗を理由ごとに多い順")
    failed += say(f"{yesterday.isoformat()[5:]} 73%（120 行）" in text, "精1: PLAUD との文字の合い方を 7 日の並びで")
    failed += say("正解集（本人が直した行）: 0 個" in text and "記録と索引: log.txt" in text, "精15・速9: 正解集と記録の大きさの行")
    # 見回り（tick）: 夜に PLAUD の合い方を書く・新しい区切りが待っていればしない
    make_plaud_world(home, mother, yesterday.isoformat(), lines=25)
    s21pc.S.night_day = None
    s21pc.S.next_threads = s21pc.S.next_rotate = 0.0
    s21pc.S.meter = threadcpu.Meter(home)
    q = make_queue("jobs-tick")
    q.jobs = {"n": meta("n", 1, time.time(), time.time())}
    jobfirst.register(q, lambda: {})
    busy = s21pc.tick(datetime.datetime.combine(today, datetime.time(3)))
    jobfirst.register(None)
    s21pc.S.night_day = None
    done = s21pc.tick(datetime.datetime.combine(today, datetime.time(3)))
    failed += say("plaud" not in busy and "threads" in busy and yesterday.isoformat() in (done.get("plaud") or {})
                  and quality.read_daily(home)["days"][yesterday.isoformat()]["plaud_match_lines"] == 25,
                  f"精1: 見回りは 01:00〜05:00 に 1 回 PLAUD の合い方を書く（新しい区切りが待っていればしない）（{done.get('plaud')}）")
    s21pc.S.home = None
    return failed


# MARK: - 精12・使12


def check_hints_and_updater() -> int:
    failed = 0
    base = TMP / "mother-hint"
    (base / "state").mkdir(parents=True)
    (base / "archive" / "calendar" / "2026" / "11").mkdir(parents=True)
    (base / "state" / "people-index.md").write_text(
        "# 人の索引\n\n| 名前 | 立場 | LINE |\n|---|---|---|\n| 自分(本名) | 自分(me) | - |\n| 甲野 | 友人 | あり |\n"
        "| 乙川(おとかわ) | 同僚 | - |\n| 丙 | - | - |\n", encoding="utf-8")
    (base / "archive" / "calendar" / "2026" / "11" / "22.md").write_text(
        "# Calendar 2026-11-22\n\n## 予定\n\n- 10:00 乙川さんと打ち合わせ\n- 19:00 甲野と食事\n", encoding="utf-8")
    names = hintpolicy.people_names(base)
    epoch = local(2026, 11, 22, 10, 0)
    off = hintpolicy.add_people(["登録語"], epoch, base, {})
    on = hintpolicy.add_people(["登録語"], epoch, base, {"people_hints": True})
    failed += say(names == ["甲野", "乙川"] and off == (["登録語"], 0) and on == (["乙川", "甲野", "登録語"], 2),
                  f"精12: 会う人の名前は既定で足さない・\"people_hints\": true なら予定に出てくる人（予定の順）を先頭に（{on}）")
    failed += say(updater.CHECK_EVERY == 3600.0, "使12: 新しい版を確かめる間は 1 時間")
    return failed


CHECKS = (check_jobqueue, check_jobfirst, check_trainer, check_plaudmatch, check_goldset, check_housekeep, check_threadcpu,
          check_line_day, check_shake, check_summary, check_hints_and_updater)


def run_all() -> int:
    failed = 0
    for check in CHECKS:
        try:
            failed += check()
        except Exception as error:  # noqa: BLE001 — 1 つが落ちても、ほかは確かめる
            import traceback

            traceback.print_exc()
            failed += say(False, f"{check.__name__} が途中で落ちました: {error!r}")
    return failed


def main() -> int:
    failed = run_all()
    print("ぜんぶ OK" if not failed else f"NG の数: {failed}", flush=True)
    return failed


if __name__ == "__main__":
    sys.exit(main())
