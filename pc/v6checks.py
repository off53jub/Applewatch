"""LifeLog PC 版 6 の機能を確かめる（--check-vote から呼ぶ。本物のモデル・本物の GitHub・本物の Ollama は使わない）。

- 後で受け取る文字起こし: 作り物のモデルで、受け付け・同じ名前・失敗のやり直し・消す・起動し直し・古いものの片付け
- 見守りの画面: 合言葉（Basic・クッキー・?key=）・画面の中身・ボタンの守り
- 自分で入れ替える: リリースの選び方・ハッシュ・zip の展開・作り物の GitHub から取ってくる・.cmd の手順を本当に動かす
- 意味で探す: 作り物の Ollama で、置く・探す・前後の行・絞り込み・消す
--check-semantic のときだけ、この PC の本物の Ollama（bge-m3）で日本語の文を置いて探す。
"""

from __future__ import annotations

import base64
import hashlib
import http.client
import io
import json
import os
import shutil
import subprocess
import tempfile
import threading
import time
import wave
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import quote

import numpy as np

import dashboard
import jobqueue
import semantic
import updater

KEY = "check-key"


def say(ok: bool, text: str) -> int:
    print(("OK " if ok else "NG ") + text, flush=True)
    return 0 if ok else 1


class Client:
    """PC の中だけに送る、ただの http（暗号の部品を使わない）"""

    def __init__(self, port: int) -> None:
        self.port = port

    def call(self, method: str, path: str, body: bytes | None = None, headers: dict | None = None,
             key: str | None = KEY) -> tuple[int, dict | str, dict]:
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=60)
        try:
            sent = dict(headers or {})
            if key is not None:
                sent.setdefault("Authorization", f"Bearer {key}")
            connection.request(method, path, body=body, headers=sent)
            response = connection.getresponse()
            raw = response.read()
            kind = response.getheader("Content-Type") or ""
            data = json.loads(raw or b"{}") if "json" in kind else raw.decode("utf-8", "replace")
            return response.status, data, {k.lower(): v for k, v in response.getheaders()}
        except OSError as error:
            return 0, {"error": repr(error)}, {}
        finally:
            connection.close()


def tone_wav(seconds: float, voiced: list[tuple[float, float]]) -> bytes:
    """周りの音（約 -50dBFS）の中に、voiced の所だけ大きな音のある wav"""
    rate = 16000
    rng = np.random.default_rng(0)
    audio = (rng.standard_normal(int(seconds * rate)) * 0.003).astype(np.float32)
    t = np.arange(len(audio)) / rate
    tone = (0.2 * np.sin(2 * np.pi * 220 * t)).astype(np.float32)
    for a, b in voiced:
        audio[int(a * rate):int(b * rate)] += tone[int(a * rate):int(b * rate)]
    body = io.BytesIO()
    with wave.open(body, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes((np.clip(audio, -1, 1) * 32767).astype("<i2").tobytes())
    return body.getvalue()


def run(main) -> int:
    failed = 0
    failed += check_jobs(main)
    failed += check_dashboard(main)
    failed += check_updater()
    failed += check_semantic(main)
    return failed


# MARK: - 後で受け取る文字起こし


def check_jobs(main) -> int:
    failed = 0
    saved = (main.App.jobs, getattr(main.Handler, "engine", None), getattr(main.Handler, "key", None),
             main._vad_failed, main.log)
    logged: list[str] = []

    def capture(message: str) -> None:
        logged.append(message)
        print("  記録: " + message, flush=True)

    class Fake:
        provider = "cpu"

        def __init__(self, name: str, text: str) -> None:
            self.name = self.label = name
            self.text = text

        def run(self, audio, segments, hints, prompt):
            return [self.text for _ in segments]

    with tempfile.TemporaryDirectory() as folder:
        try:
            main.log = capture
            # Silero VAD を取ってこないで、音の大きさで声の区間を探す（モデル無しで確かめる）
            main._vad_failed = time.time()
            main.Handler.engine = main.Ensemble([Fake("haas", "今日は秘密の会議です"), Fake("reazon", "今日は秘密の会議です"),
                                                 Fake("whisper", "")])
            main.Handler.key = KEY
            main.App.jobs = jobqueue.JobQueue(Path(folder) / "jobs", main.run_job, capture)
            main.App.jobs.start()
            server = main.Server(("127.0.0.1", 0), main.Handler)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            client = Client(server.server_address[1])
            name = "20261106-103200-w.m4a"
            audio = tone_wav(8.0, [(1.0, 2.5), (4.0, 6.0)])
            hints = quote("今日\n会議")
            first = client.call("POST", f"/jobs?name={name}&hints={hints}&noisy=0", audio)
            again = client.call("POST", f"/jobs?name={name}&noisy=0", audio)
            seq = main.App.jobs.jobs[name]["seq"] if name in main.App.jobs.jobs else None

            def wait(job: str) -> tuple[int, dict]:
                deadline = time.time() + 60
                while time.time() < deadline:
                    status, body, _ = client.call("GET", f"/jobs/{job}")
                    if status != 200 or body.get("status") in ("done", "failed"):
                        return status, body
                    time.sleep(0.2)
                return 0, {}

            status, done = wait(name)
            result = done.get("result") or {}
            lines = result.get("lines") or []
            ok = first[0] == 200 and first[1] == {"id": name, "status": "queued"} and again[0] == 200 \
                and again[1].get("id") == name and again[1].get("status") in ("queued", "working", "done") \
                and main.App.jobs.jobs[name]["seq"] == seq and status == 200 and done.get("status") == "done" \
                and isinstance(done.get("queued_at"), float) and isinstance(done.get("done_at"), float) \
                and "error" not in done and len(lines) == 2 \
                and abs(lines[0]["start"] - 0.9) <= 0.15 and abs(lines[1]["end"] - 6.1) <= 0.15 \
                and lines[0]["text"] == "今日は秘密の会議です" and "votes" in lines[0] and "confidence" in lines[0] \
                and not any(line.get("extra") for line in lines) \
                and result.get("engines") == ["haas", "reazon", "whisper"] and "seconds" in result \
                and result.get("silent") == {"whisper": 2} and result.get("heard_lines") == 2 \
                and "pairs" in result and "pair_lines" in result \
                and not main.App.jobs.audio_path(name).exists()
            failed += say(ok, f"後で受け取る文字起こし: 預ける {first[:2]} 同じ名前 {again[:2]} → {status} "
                              f"{json.dumps({k: v for k, v in done.items() if k != 'result'}, ensure_ascii=False)} "
                              f"行 {[(l['start'], l['end']) for l in lines]}")
            # 記録には文の中身を書かない
            ok = any(f"後で受け取る文字起こし {name}: 8 秒" in line for line in logged) \
                and not any("秘密" in line for line in logged)
            failed += say(ok, "後で受け取る文字起こしの記録に、1区切りの行があり、文の中身が無い")
            # 音声でないものは失敗にし、同じ名前で送り直すとやり直す
            bad = client.call("POST", "/jobs?name=broken-1.m4a", b"not audio at all" * 100)
            _, broken = wait("broken-1.m4a")
            retry = client.call("POST", "/jobs?name=broken-1.m4a&enhance=0", audio)
            _, fixed = wait("broken-1.m4a")
            ok = bad[1] == {"id": "broken-1.m4a", "status": "queued"} and broken.get("status") == "failed" \
                and broken.get("error") and "result" not in broken and retry[1] == {"id": "broken-1.m4a", "status": "queued"} \
                and fixed.get("status") == "done" and len(fixed["result"]["lines"]) == 2 \
                and main.App.jobs.jobs["broken-1.m4a"]["params"]["enhance"] is False
            failed += say(ok, f"失敗したものだけ送り直すとやり直す: {broken.get('status')}（{broken.get('error')}）→ {fixed.get('status')}")
            # 名前・合言葉・大きさ
            checks = {"名前なし": client.call("POST", "/jobs", audio)[0],
                      "../": client.call("POST", "/jobs?name=../x", audio)[0],
                      "点だけ": client.call("POST", "/jobs?name=..", audio)[0],
                      "長すぎる名前": client.call("POST", f"/jobs?name={'a' * 81}", audio)[0],
                      "空": client.call("POST", "/jobs?name=empty.m4a", b"")[0],
                      "合言葉違い": client.call("POST", "/jobs?name=x.m4a", audio, key="wrong")[0],
                      "一覧の合言葉違い": client.call("GET", "/jobs", key="wrong")[0],
                      "知らない名前": client.call("GET", "/jobs/unknown.m4a")[0]}
            ok = checks == {"名前なし": 400, "../": 400, "点だけ": 400, "長すぎる名前": 400, "空": 400, "合言葉違い": 401,
                            "一覧の合言葉違い": 401, "知らない名前": 404}
            failed += say(ok, f"後で受け取る文字起こしの断り方: {checks}")
            # 一覧は新しい順。待ちが多すぎれば 503
            listing = client.call("GET", "/jobs")
            ids = [j["id"] for j in listing[1].get("jobs", [])]
            main.App.jobs.pause()
            main.App.jobs.limit = 1
            one = client.call("POST", "/jobs?name=wait-1.m4a", audio)
            full = client.call("POST", "/jobs?name=wait-2.m4a", audio)
            main.App.jobs.limit = jobqueue.QUEUE_LIMIT
            main.App.jobs.resume()
            ok = ids == ["broken-1.m4a", name] and set(listing[1]["jobs"][0]) == {"id", "status", "queued_at", "done_at"} \
                and one[0] == 200 and full[0] == 503 and "jobs" in main.features()
            failed += say(ok, f"一覧（新しい順）: {ids}、待ちが多すぎるとき {full[0]}、features に jobs: {'jobs' in main.features()}")
            wait("wait-1.m4a")
            # 消す
            gone = client.call("DELETE", f"/jobs/{name}")
            after = client.call("GET", f"/jobs/{name}")
            twice = client.call("DELETE", f"/jobs/{name}")
            files = [p.name for p in (Path(folder) / "jobs").iterdir() if p.name.startswith(main.App.jobs.base(name).name)]
            ok = gone[:2] == (200, {"id": name, "deleted": True}) and after[0] == 404 and twice[0] == 404 and files == []
            failed += say(ok, f"消す: {gone[:2]} → {after[0]}・もう一度 {twice[0]}・残ったファイル {files}")
            server.shutdown()
            server.server_close()
        finally:
            main.App.jobs, main.Handler.engine, main.Handler.key, main._vad_failed, main.log = saved
        failed += check_jobs_restart(Path(folder) / "restart")
    return failed


def check_jobs_restart(folder: Path) -> int:
    """起動し直したとき・古いものの片付け（裏の仕事は動かさない）"""
    messages: list[str] = []

    def put(queue: jobqueue.JobQueue, name: str, data: bytes = b"x") -> None:
        assert queue.begin(name)[0] == "ok"
        queue.part_path(name).write_bytes(data)
        queue.commit(name, {"hints": []}, len(data))

    queue = jobqueue.JobQueue(folder, lambda path, params, name: ({"lines": []}, {}), messages.append, limit=3)
    for name in ("a.m4a", "b.m4a", "c.m4a"):
        put(queue, name)
    full = queue.begin("d.m4a")[0]
    # 途中で止まった（working のまま）もの・音声の無い待ち
    meta = queue.jobs["a.m4a"]
    meta["status"] = "working"
    jobqueue._write_json(queue.meta_path("a.m4a"), meta)
    queue.audio_path("b.m4a").unlink()
    (folder / "stray.audio.part").write_bytes(b"x")
    again = jobqueue.JobQueue(folder, lambda path, params, name: ({"lines": [1]}, {"audio_seconds": 1.0}),
                              messages.append, limit=3)
    states = {n: m["status"] for n, m in again.jobs.items()}
    order = []
    while again.step():
        order.append([n for n, m in again.jobs.items() if m["status"] == "done"])
    done = again.get("a.m4a")
    # 7 日より前にでき上がったものは消す
    removed = again.clean(now=time.time() + jobqueue.KEEP_SECONDS + 10)
    ok = full == "full" and states == {"a.m4a": "queued", "b.m4a": "failed", "c.m4a": "queued"} \
        and not (folder / "stray.audio.part").exists() and order == [["a.m4a"], ["a.m4a", "c.m4a"]] \
        and done["status"] == "done" and done["result"] == {"lines": [1]} and removed == 3 and not again.jobs \
        and list(folder.iterdir()) == []
    return say(ok, f"起動し直したとき: 途中のもの・音声の無いもの {states}、来た順 {order}、7 日で片付け {removed} 個")


# MARK: - 見守りの画面


def check_dashboard(main) -> int:
    failed = 0
    recent = dashboard.Recent(size=100)
    for took, voiced in ((10, 20), (30, 20), (5, 10), (1, 0)):
        recent.record("transcribe", took, voiced, 300, {"pairs": {"haas-reazon": 0.8}, "pair_lines": {"haas-reazon": 2},
                                                        "silent": {"whisper": 1}, "heard_lines": 2})
    recent.record("job", 100, 10, 300, {"pairs": {"haas-reazon": 0.2}, "pair_lines": {"haas-reazon": 2},
                                        "silent": {}, "heard_lines": 2})
    speed, count = recent.speed("transcribe")
    pairs = recent.pairs()
    ok = speed == 0.5 and count == 3 and pairs["pairs"] == {"haas-reazon": 0.68} and pairs["silent"] == {"whisper": 4} \
        and pairs["requests"] == 5 and pairs["pair_lines"] == {"haas-reazon": 10}
    failed += say(ok, f"見守りの画面の数: 速さ {speed}（{count} 回）、組の近さ {pairs}")
    lines = ["2026-11-06 10:00:00 Whisper を読み込みました", "2026-11-06 10:00:01 GPU で読み込めませんでした。CPU で動かします: "
             "RuntimeError('CUDA driver version is insufficient')", "2026-11-06 10:00:02 <script>alert(1)</script> できませんでした"]
    ok = dashboard.problems(lines) == lines[1:] and "insufficient" in (dashboard.last_cuda_error(lines) or "") \
        and dashboard.last_cuda_error(lines[:1]) is None
    failed += say(ok, "記録から失敗の行と GPU の最後の失敗を拾う")
    # 合言葉
    basic = {"Authorization": "Basic " + base64.b64encode(f"だれでも:{KEY}".encode()).decode()}
    wrong = {"Authorization": "Basic " + base64.b64encode(b"x:nope").decode()}
    cookie = {"Cookie": f"a=b; {dashboard.COOKIE}={dashboard.token(KEY)}"}
    got = [dashboard.check(basic, "", KEY), dashboard.check(wrong, "", KEY), dashboard.check(cookie, "", KEY),
           dashboard.check({}, f"key={KEY}", KEY), dashboard.check({}, "key=nope", KEY),
           dashboard.check({"Authorization": f"Bearer {KEY}"}, "", KEY), dashboard.check({"Cookie": f"{dashboard.COOKIE}={KEY}"}, "", KEY)]
    ok = got == [(True, False), (False, False), (True, False), (True, True), (False, False), (True, False), (False, False)] \
        and KEY not in dashboard.cookie_header(KEY) and "HttpOnly" in dashboard.cookie_header(KEY)
    failed += say(ok, f"見守りの画面の合言葉: {got}")
    saved = (getattr(main.Handler, "key", None), main.App.updater, main.App.jobs)
    with tempfile.TemporaryDirectory() as folder:
        try:
            main.Handler.key = KEY
            main.App.updater = None
            main.App.jobs = jobqueue.JobQueue(Path(folder) / "jobs", lambda *a: ({}, {}), lambda m: None)
            server = main.Server(("127.0.0.1", 0), main.Handler)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            client = Client(server.server_address[1])
            plain = client.call("GET", "/dash", key=None)
            page = client.call("GET", "/dash", headers=basic, key=None)
            denied = client.call("GET", "/dash", headers=wrong, key=None)
            login = client.call("GET", f"/dash?key={KEY}", key=None)
            jar = (login[2].get("set-cookie") or "").split(";")[0]
            by_cookie = client.call("GET", "/dash", headers={"Cookie": jar}, key=None)
            no_mark = client.call("POST", "/dash/update", headers=basic, key=None)
            no_auth = client.call("POST", "/dash/restart", headers={dashboard.HEADER: "1"}, key=None)
            no_updater = client.call("POST", "/dash/update", headers={**basic, dashboard.HEADER: "1"}, key=None)
            html = page[1] if isinstance(page[1], str) else ""
            ok = plain[0] == 401 and "basic" in plain[2].get("www-authenticate", "").lower() and page[0] == 200 \
                and f"LifeLog PC 版 {main.VERSION}" in html and "後で受け取る文字起こし" in html and "再起動" in html \
                and "更新を確かめる" in html and "prefers-color-scheme" in html and "src=" not in html \
                and "https://" not in html and "http://" not in html and denied[0] == 401 \
                and login[0] == 303 and login[2].get("location") == "/dash" and "HttpOnly" in login[2].get("set-cookie", "") \
                and by_cookie[0] == 200 and no_mark[0] == 403 and no_auth[0] == 401 and no_updater[0] == 503 \
                and "default-src 'none'" in page[2].get("content-security-policy", "")
            failed += say(ok, f"見守りの画面: 合言葉なし {plain[0]}・Basic {page[0]}（{len(html)} 文字）・違う {denied[0]}・"
                              f"?key= {login[0]}・クッキー {by_cookie[0]}・印なしのボタン {no_mark[0]}・"
                              f"合言葉なしのボタン {no_auth[0]}・入れ替えの仕組みなし {no_updater[0]}")
            server.shutdown()
            server.server_close()
        finally:
            main.Handler.key, main.App.updater, main.App.jobs = saved
    info = {"version": 6, "build": 12, "engines": [{"name": "haas", "label": "Haas-ja", "provider": "cpu"}],
            "gpu": {"nvidia": True, "used": False, "last_error": "<b>CUDA</b> insufficient"},
            "jobs": [{"id": "a.m4a", "status": "failed", "error": "<img src=x>", "audio_seconds": 300,
                      "voiced_seconds": 100, "processing_seconds": 50, "queued_at": time.time()}],
            "job_counts": {"failed": 1}, "problems": ["<script>x</script>"], "speed": (0.42, 3),
            "pairs": recent.pairs(), "update": {"auto": True, "state": "今の版がいちばん新しい版です"}}
    page = dashboard.render(info)
    ok = "<script>x</script>" not in page and "&lt;script&gt;" in page and "<img" not in page and "<b>CUDA" not in page \
        and "0.50" in page and "0.42" in page and "番号 12" in page
    failed += say(ok, "見守りの画面は、記録や失敗の文を HTML として扱わない（速さ 処理 50 秒 ÷ 声 100 秒 = 0.50）")
    return failed


# MARK: - 自分で入れ替える


def make_zip(folder: Path, build: int, nested: bool = True, evil: bool = False) -> bytes:
    body = io.BytesIO()
    prefix = "LifeLogPC/" if nested else ""
    with zipfile.ZipFile(body, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr(prefix + "LifeLogPC.exe", b"new exe")
        z.writestr(prefix + "BUILD.txt", f"{build}\n")
        z.writestr(prefix + "_internal/新しい部品.txt", "新しい")
        if evil:
            z.writestr("../outside.txt", "bad")
    return body.getvalue()


def check_updater() -> int:
    failed = 0
    releases = [
        {"tag_name": "v2026.11.06-3", "assets": [{"name": "LifeLog.ipa", "browser_download_url": "u"}]},
        {"tag_name": "pc-v6-40", "draft": True, "assets": [{"name": "LifeLogPC.zip", "browser_download_url": "z40"},
                                                           {"name": "LifeLogPC.zip.sha256", "browser_download_url": "s40"}]},
        {"tag_name": "pc-v6-31", "assets": [{"name": "LifeLogPC.zip", "browser_download_url": "z31", "size": 5},
                                            {"name": "LifeLogPC.zip.sha256", "browser_download_url": "s31"}]},
        {"tag_name": "pc-v6-35", "assets": [{"name": "LifeLogPC.zip", "browser_download_url": "z35"}]},
        {"tag_name": "pc-v6-29", "assets": [{"name": "LifeLogPC.zip", "browser_download_url": "z29"},
                                            {"name": "LifeLogPC.zip.sha256", "browser_download_url": "s29"}]},
        "garbage",
    ]
    picked = updater.pick_release(releases, 30)
    ok = picked == {"tag": "pc-v6-31", "version": 6, "build": 31, "zip": "z31", "zip_size": 5, "sha": "s31"} \
        and updater.pick_release(releases, 31) is None and updater.pick_release({"message": "rate"}, 0) is None \
        and updater.parse_tag("pc-v7-1") == (7, 1) and updater.parse_tag("pc-v6-") is None \
        and updater.parse_tag("v2026.11.06-1") is None
    failed += say(ok, f"リリースの選び方: 番号 30 より新しいもの → {picked and picked['tag']}（下書き・zip だけのもの・アプリのものは除く）")
    digest = "ab" * 32
    with tempfile.TemporaryDirectory() as folder:
        root = Path(folder)
        sample = root / "x.zip"
        sample.write_bytes(b"hello")
        right = hashlib.sha256(b"hello").hexdigest()
        ok = updater.parse_sha256(f"{digest.upper()}  LifeLogPC.zip\n") == digest and updater.parse_sha256("nope") is None \
            and updater.verify_sha256(sample, right) and updater.verify_sha256(sample, right.upper()) \
            and not updater.verify_sha256(sample, digest) and not updater.verify_sha256(sample, None) \
            and not updater.verify_sha256(root / "none.zip", right)
        failed += say(ok, "ハッシュの読み方と確かめ方（違えば使わない）")
        evil = root / "evil.zip"
        evil.write_bytes(make_zip(root, 1, evil=True))
        try:
            updater.safe_extract(evil, root / "out")
            refused = False
        except ValueError:
            refused = True
        ok = refused and not (root / "outside.txt").exists()
        failed += say(ok, "zip の中に外を指すもの（../）があれば展開しない")
        script = updater.update_script(1234, Path(r"C:\x\LifeLogPC (1)"), Path(r"C:\x\LifeLogPC (1) 新しい版"),
                                       Path(r"C:\x\LifeLogPC (1) 前の版"), "Lifelog-HomePC-Autostart",
                                       [r"C:\x\LifeLogPC (1)\LifeLogPC.exe", "--engines", "haas,reazon", "100%"],
                                       Path(r"C:\x\LifeLogPC (1)"), Path(r"C:\log.txt"))
        try:
            updater.update_script(1, root, root, root, None, ['a"b'], root, root / "l")
            quoted = False
        except ValueError:
            quoted = True
        lines = script.split("\r\n")
        ok = lines[0] == "@echo off" and lines[1] == "chcp 65001 >nul" and lines[0].isascii() and lines[1].isascii() \
            and 'schtasks /run /tn "Lifelog-HomePC-Autostart"' in script and '"100%%"' in script \
            and 'move "C:\\x\\LifeLogPC (1)" "C:\\x\\LifeLogPC (1) 前の版"' in script and 'del "%~f0"' in lines[-2] \
            and 'findstr /C:" 1234 "' in script and quoted
        failed += say(ok, "入れ替えの .cmd の中身（UTF-8 の名前・% の書き方・タスクで起動・自分を消す）")
        failed += check_updater_download(root)
        if os.name == "nt":
            failed += check_update_script(root / "run")
    return failed


def check_updater_download(root: Path) -> int:
    """作り物の GitHub（この PC の中）から、取ってくる・確かめる・展開する。番号の上限・回数の上限も。"""
    failed = 0
    good = make_zip(root, 31)
    files = {"/z31": good, "/s31": f"{hashlib.sha256(good).hexdigest()}  LifeLogPC.zip\n".encode(),
             "/z32": make_zip(root, 32, nested=False), "/s32": ("0" * 64 + "  LifeLogPC.zip\n").encode()}
    mode = {"limit": False}

    class FakeGitHub(BaseHTTPRequestHandler):
        def log_message(self, format: str, *args) -> None:
            pass

        def do_GET(self) -> None:
            base = f"http://127.0.0.1:{self.server.server_address[1]}"
            if self.path.startswith("/releases"):
                if mode["limit"]:
                    self.send_response(403)
                    self.send_header("X-RateLimit-Remaining", "0")
                    self.send_header("X-RateLimit-Reset", str(int(time.time()) + 600))
                    self.send_header("Content-Length", "2")
                    self.end_headers()
                    self.wfile.write(b"{}")
                    return
                body = json.dumps([{"tag_name": "pc-v6-31", "assets": [
                    {"name": "LifeLogPC.zip", "browser_download_url": base + "/z31", "size": len(good)},
                    {"name": "LifeLogPC.zip.sha256", "browser_download_url": base + "/s31"}]}]).encode()
            elif self.path in files:
                body = files[self.path]
            else:
                self.send_response(404)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    fake = ThreadingHTTPServer(("127.0.0.1", 0), FakeGitHub)
    threading.Thread(target=fake.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{fake.server_address[1]}"
    messages: list[str] = []
    install = root / "LifeLogPC (1)"
    install.mkdir()
    (install / "LifeLogPC.exe").write_bytes(b"old exe")
    try:
        up = updater.Updater(root / "home", 30, False, install, True, lambda: False, lambda: None, lambda: None,
                             messages.append, task=None, api=base + "/releases?per_page=30", exit=lambda: None)
        up.run()
        python_only = up.status()
        staging = up.prepare(updater.pick_release(up.fetch_releases(), 30), install)
        ok = "入れ替えません" in python_only["state"] and python_only["latest"] == "pc-v6-31" \
            and staging == updater.staging_dir(install) and (staging / "LifeLogPC.exe").read_bytes() == b"new exe" \
            and updater.read_build(staging) == 31 and (staging / "_internal" / "新しい部品.txt").exists() \
            and (install / "LifeLogPC.exe").read_bytes() == b"old exe" \
            and not list((root / "home" / "update").glob("*.zip")) \
            and not (staging.with_name(staging.name + ".tmp")).exists()
        failed += say(ok, f"作り物の GitHub から取ってきて、ハッシュを確かめ、隣に展開する: {staging.name}"
                          f"（Python のままなら: {python_only['state']}）")
        try:
            up.prepare({"tag": "pc-v6-32", "build": 32, "zip": base + "/z32", "sha": base + "/s32", "zip_size": 0},
                       install)
            mismatch = False
        except RuntimeError as error:
            mismatch = "ハッシュ" in str(error)
        ok = mismatch and not list((root / "home" / "update").glob("LifeLogPC-32.zip*")) \
            and updater.read_build(updater.staging_dir(install)) == 31
        failed += say(ok, "ハッシュが合わない zip は消して、使わない")
        mode["limit"] = True
        up.run()
        ok = up.status()["state"] == "確かめられませんでした" and "回数" in (up.status()["error"] or "")
        failed += say(ok, f"GitHub の回数の上限: {up.status()['error']}")
    finally:
        fake.shutdown()
        fake.server_close()
    return failed


def check_update_script(root: Path) -> int:
    """.cmd の手順を、作り物のフォルダと、すぐ終わるもの（ping）で本当に動かす（Windows だけ）"""
    failed = 0
    root.mkdir(parents=True)
    install = root / "LifeLogPC (1)"
    staging = updater.staging_dir(install)
    backup = updater.backup_dir(install)
    for folder, mark in ((install, "今の版"), (staging, "新しい版"), (backup, "古い前の版")):
        folder.mkdir()
        (folder / "版.txt").write_text(mark, encoding="utf-8")
    starter = root / "起動.cmd"
    # start で .cmd を起動すると窓が残る（cmd /K）ので、最後に exit で閉じる
    starter.write_text('@echo off\r\nchcp 65001 >nul\r\n> "%~dp0started.txt" echo %CD%\r\nexit\r\n', encoding="utf-8")
    log = root / "log.txt"
    waiter = subprocess.Popen(["ping", "-n", "3", "127.0.0.1"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    script = root / "LifeLogPC-update.cmd"
    script.write_text(updater.update_script(waiter.pid, install, staging, backup, None, [str(starter)], install, log),
                      encoding="utf-8")
    started = time.time()
    updater.launch(script, root)
    while time.time() - started < 90 and not (root / "started.txt").exists():
        time.sleep(0.5)
    time.sleep(1.0)
    waited = waiter.poll() is not None
    read = (lambda p: p.read_text(encoding="utf-8") if p.exists() else None)
    text = read(log) or ""
    ok = (root / "started.txt").exists() and waited and read(install / "版.txt") == "新しい版" \
        and read(backup / "版.txt") == "今の版" and not staging.exists() and not script.exists() \
        and "入れ替えました" in text and "起動しました" in text \
        and str(install) in (read(root / "started.txt") or "")
    failed += say(ok, f".cmd の手順を本当に動かす（{time.time() - started:.1f} 秒）: 終わるのを待つ {waited}・"
                      f"入っている版 {read(install / '版.txt')}・前の版 {read(backup / '版.txt')}・"
                      f"新しい版のフォルダが残っていない {not staging.exists()}・手順が消えた {not script.exists()}")
    # 起動し直すだけの .cmd
    (root / "started.txt").unlink(missing_ok=True)
    waiter = subprocess.Popen(["ping", "-n", "2", "127.0.0.1"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    script = root / "LifeLogPC-restart.cmd"
    script.write_text(updater.restart_script(waiter.pid, None, [str(starter)], root, log), encoding="utf-8")
    started = time.time()
    updater.launch(script, root)
    while time.time() - started < 60 and not (root / "started.txt").exists():
        time.sleep(0.5)
    time.sleep(0.5)
    ok = (root / "started.txt").exists() and waiter.poll() is not None and not script.exists() \
        and not updater.task_exists("LifeLog-no-such-task-for-check")
    failed += say(ok, f"再起動の .cmd を本当に動かす（{time.time() - started:.1f} 秒）")
    return failed


# MARK: - 意味で探す


class FakeOllama(BaseHTTPRequestHandler):
    """/api/tags・/api/pull・/api/embed だけの作り物。数の並びは、文字の 2 文字ずつの組から作る。"""

    models: list[str] = []
    embeds = 0
    allow_pull = True

    def log_message(self, format: str, *args) -> None:
        pass

    def reply(self, body: dict) -> None:
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:
        self.reply({"models": [{"name": m} for m in FakeOllama.models]})

    def do_POST(self) -> None:
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)))
        if self.path == "/api/pull":
            if not FakeOllama.allow_pull:
                self.reply({"error": "取ってこられません"})
                return
            FakeOllama.models.append(body["model"] + ":latest")
            self.reply({"status": "success"})
        elif self.path == "/api/embed":
            FakeOllama.embeds += len(body["input"])
            self.reply({"embeddings": [fake_vector(t).tolist() for t in body["input"]]})
        else:
            self.reply({"error": "?"})


def fake_vector(text: str) -> np.ndarray:
    vector = np.zeros(64, dtype=np.float32)
    for a, b in zip(text, text[1:]):
        vector[int(hashlib.md5((a + b).encode()).hexdigest(), 16) % 64] += 1.0
    vector[63] += 0.01
    return vector


ITEMS = [
    {"id": "c1-1", "day": "2026-11-01", "time": 100.0, "speaker": "自分", "text": "おはようございます", "work": False,
     "conversation": "c1"},
    {"id": "c1-2", "day": "2026-11-01", "time": 101.0, "speaker": "田中さん", "text": "明日の会議の資料はできましたか",
     "work": True, "conversation": "c1"},
    {"id": "c1-3", "day": "2026-11-01", "time": 102.0, "speaker": "自分", "text": "まだです。午後に送ります", "work": True,
     "conversation": "c1"},
    {"id": "c1-4", "day": "2026-11-01", "time": 103.0, "speaker": "田中さん", "text": "よろしくお願いします", "work": True,
     "conversation": "c1"},
    {"id": "c2-1", "day": "2026-11-03", "time": 200.0, "speaker": "母", "text": "週末は温泉に行こうか", "work": False,
     "conversation": "c2"},
    {"id": "c2-2", "day": "2026-11-03", "time": 201.0, "speaker": None, "text": "いいね、箱根の温泉がいい", "work": False},
]


def check_semantic(main) -> int:
    failed = 0
    FakeOllama.models = []
    FakeOllama.embeds = 0
    FakeOllama.allow_pull = True
    fake =ThreadingHTTPServer(("127.0.0.1", 0), FakeOllama)
    threading.Thread(target=fake.serve_forever, daemon=True).start()
    saved = (main.App.semantic, getattr(main.Handler, "key", None))
    with tempfile.TemporaryDirectory() as folder:
        try:
            messages: list[str] = []
            index = semantic.SemanticIndex(Path(folder) / "semantic.db",
                                           semantic.OllamaEmbedder(f"http://127.0.0.1:{fake.server_address[1]}"),
                                           messages.append)
            # モデルが無ければ取ってきてもらう
            first = index.available(force=True)
            deadline = time.time() + 20
            while time.time() < deadline and (index.pulling or not index.ok):
                time.sleep(0.1)
                index.available(force=True)
            pulled = index.ok and FakeOllama.models == ["bge-m3:latest"]
            try:
                semantic.OllamaEmbedder("http://192.168.1.2:11434")
                local_only = False
            except ValueError:
                local_only = True
            failed += say(not first and pulled and local_only,
                          f"意味で探す: bge-m3 が無ければ Ollama に取ってきてもらう（{FakeOllama.models}）・宛先はこの PC の中だけ")
            main.App.semantic = index
            main.Handler.key = KEY
            server = main.Server(("127.0.0.1", 0), main.Handler)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            client = Client(server.server_address[1])

            def post(path: str, body) -> tuple[int, dict]:
                data = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode("utf-8")
                status, reply, _ = client.call("POST", path, data, {"Content-Type": "application/json"})
                return status, reply

            put = post("/index", {"items": ITEMS})
            embeds = FakeOllama.embeds
            again = post("/index", {"items": [dict(ITEMS[1], speaker="田中部長")]})
            embeds = FakeOllama.embeds - embeds
            status = client.call("GET", "/index/status")
            hits = post("/search", {"query": "会議の資料", "k": 3})
            top = (hits[1].get("hits") or [{}])[0]
            context = [(c["id"], c["offset"]) for c in top.get("context", [])]
            ok = put == (200, {"indexed": 6}) and again == (200, {"indexed": 1}) and embeds == 0 \
                and status[:2] == (200, {"count": 6, "model": "bge-m3", "ready": True}) and hits[0] == 200 \
                and top.get("id") == "c1-2" and top.get("speaker") == "田中部長" and top.get("work") is True \
                and top.get("conversation") == "c1" and 0 < top.get("score", 0) <= 1.0001 \
                and context == [("c1-1", -1), ("c1-3", 1), ("c1-4", 2)] and len(hits[1]["hits"]) == 3 \
                and set(top) == {"id", "day", "time", "speaker", "text", "work", "conversation", "score", "context"} \
                and "semantic" in main.features()
            failed += say(ok, f"置く {put} 置き直し {again}（数の並びは作り直さない）・状態 {status[1]}・"
                              f"探す 最初 {top.get('id')} {top.get('score')} 前後 {context}")
            filters = {
                "仕事を除く": sorted(h["id"] for h in post("/search", {"query": "会議の資料", "include_work": False})[1]["hits"]),
                "日付": sorted(h["id"] for h in post("/search", {"query": "温泉", "from": "2026-11-02", "to": "2026-11-03"})[1]["hits"]),
                "話し手": sorted(h["id"] for h in post("/search", {"query": "会議", "speaker": "田中"})[1]["hits"]),
                "前後なし": post("/search", {"query": "箱根の温泉", "k": 1})[1]["hits"][0]["context"],
            }
            ok = filters == {"仕事を除く": ["c1-1", "c2-1", "c2-2"], "日付": ["c2-1", "c2-2"],
                             "話し手": ["c1-2", "c1-4"], "前後なし": []}
            failed += say(ok, f"絞り込み: {filters}")
            bad = {"JSON でない": post("/index", b"{")[0], "多すぎる": post("/index", {"items": [ITEMS[0]] * 501})[0],
                   "日付の形": post("/index", {"items": [dict(ITEMS[0], day="11/01")]})[0],
                   "問いなし": post("/search", {"query": " "})[0], "合言葉違い": client.call("GET", "/index/status", key="x")[0]}
            ok = bad == {"JSON でない": 400, "多すぎる": 400, "日付の形": 400, "問いなし": 400, "合言葉違い": 401}
            failed += say(ok, f"意味で探すの断り方: {bad}")
            gone = post("/forget", {"ids": ["c1-2", "nothing"]})
            empty = post("/index", {"items": [dict(ITEMS[2], text="")]})
            after = client.call("GET", "/index/status")[1]
            left = [h["id"] for h in post("/search", {"query": "会議の資料", "k": 10})[1]["hits"]]
            ok = gone == (200, {"forgotten": 1}) and empty == (200, {"indexed": 0}) and after["count"] == 4 \
                and "c1-2" not in left and "c1-3" not in left and not any("会議" in m for m in messages)
            failed += say(ok, f"消す {gone}・文が空なら消す {empty}・残り {after['count']} 行・記録に文の中身が無い")
            # モデルが消え、取ってこられないとき
            FakeOllama.models = []
            FakeOllama.allow_pull = False
            index.available(force=True)
            while index.pulling:
                time.sleep(0.05)
            down = post("/search", {"query": "会議"})
            ok = down[0] == 503 and "semantic" not in main.features() and post("/forget", {"ids": []})[0] == 200
            failed += say(ok, f"モデルが無くなったら: 探す {down[0]}・features から semantic が消える")
            server.shutdown()
            server.server_close()
        finally:
            main.App.semantic, main.Handler.key = saved
            fake.shutdown()
            fake.server_close()
    return failed


def check_semantic_real(main) -> None:
    """この PC の本物の Ollama（bge-m3）で、日本語の文を置いて探す（一時フォルダの SQLite）。"""
    import sys

    url = main.LLM.url
    print(f"Ollama: {url}（モデル {semantic.EMBED_MODEL}）", flush=True)
    with tempfile.TemporaryDirectory() as folder:
        index = semantic.SemanticIndex(Path(folder) / "semantic.db", semantic.OllamaEmbedder(url), main.log)
        started = time.time()
        index.available(force=True)
        while not index.ok and time.time() - started < 3600:
            if not index.pulling and index.error:
                print("NG " + index.error)
                sys.exit(1)
            time.sleep(5)
            index.available(force=True)
        if not index.ok:
            print("NG Ollama が答えないか、bge-m3 を用意できませんでした")
            sys.exit(1)
        items = ITEMS + [
            {"id": "c3-1", "day": "2026-11-04", "time": 300.0, "speaker": "自分", "text": "歯が痛いので歯医者を予約した",
             "work": False, "conversation": "c3"},
            {"id": "c3-2", "day": "2026-11-04", "time": 301.0, "speaker": "自分", "text": "駅前のラーメン屋が美味しかった",
             "work": False, "conversation": "c3"},
            {"id": "c3-3", "day": "2026-11-05", "time": 400.0, "speaker": "佐藤さん", "text": "来月の予算の見積もりを出してください",
             "work": True, "conversation": "c4"},
        ]
        started = time.time()
        count = index.index(semantic.parse_index(json.dumps({"items": items}, ensure_ascii=False).encode()))
        took = time.time() - started
        failed = 0
        print(f"置いた行: {count}（{took:.1f} 秒）", flush=True)
        # 「旅行の相談」のような短く抽象的な問いは、「よろしくお願いします」のような短い決まり文句が上に来ることがある
        for query, want in (("プレゼンの準備はどうなっている？", "c1-2"), ("週末に家族で出かける計画", "c2-1"),
                            ("虫歯の治療", "c3-1"), ("お金の計画", "c3-3"), ("食事の感想", "c3-2")):
            started = time.time()
            hits = index.search(semantic.parse_search(json.dumps({"query": query, "k": 3}, ensure_ascii=False).encode()))
            top = hits[0] if hits else {}
            ok = top.get("id") == want
            failed += say(ok, f"「{query}」→ {top.get('id')}「{top.get('text')}」{top.get('score')}"
                              f"（{time.time() - started:.2f} 秒、前後 {len(top.get('context', []))} 行）"
                              f" 次: {[(h['id'], h['score']) for h in hits[1:]]}")
        with index.lock, index.connect() as db:
            blob = db.execute("SELECT vec FROM items LIMIT 1").fetchone()[0]
        failed += say(len(blob) == 1024 * 2, f"数の並びは float16 で {len(blob) // 2} 次元")
        if failed:
            sys.exit(1)
