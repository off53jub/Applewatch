"""LifeLog PC 版 7（ops）の機能を確かめる（--check-v7-ops。ネット・GPU・本物の Apple・本物の Ollama は使わない）。

一時フォルダの HOME と、この PC の中だけの作り物の相手（APNs の HTTP/2・App Store Connect・Ollama）で確かめる:
- 実機の様子: POST /diag の受け付け・置き場所・気になる所・60 日の片づけ・summary.md・見守りの画面
- 見えない通知: 鍵・JWT（ES256）・HTTP/2 で送る中身・回数の上限・410・鍵が無いとき・テスト通知のボタン・鍵を入れるボタン
- TestFlight の報告: キーを入れるボタン・JWT・報告とスクショと落ちた記録を置く・詳しい画面
- GPU の時間割: 夜に30分仕事が無ければ下ろす・仕事が来たら戻す・学び直しのあいだは戻さない・空きが足りなければ待つ
- Ollama: 載っているモデルを下ろし、長く載せておく設定だったものだけ載せ直す
- 自動の学び直し: 時間帯・材料の数・作り物の学び直し（.cmd）で、良くなった・良くならなかった・断られた・時間切れ、
  子のプロセスに SSLKEYLOGFILE を渡さない
- 部品の用意: ハッシュが合わない Python は使わない・tar の外を指すものは展開しない・pip に --require-hashes で頼む
- jobqueue の「仕事が終わったとき」の口・features・/train-status の auto
"""

from __future__ import annotations

import base64
import datetime
import hashlib
import http.client
import io
import json
import os
import socket
import tarfile
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import apns
import ascfeedback
import dashboard
import diag
import gpu
import jobqueue
import ops
import trainer

KEY = "check-key"
DEVICE = "6F1C2B3A-1111-4222-8333-944455556666"
TOKEN = "ab" * 32
TEAM = "ABCDE12345"
BASIC = {"Authorization": "Basic " + base64.b64encode(f"x:{KEY}".encode()).decode()}


def say(ok: bool, text: str) -> int:
    print(("OK " if ok else "NG ") + text, flush=True)
    return 0 if ok else 1


class Clock:
    """作り物の時計（ops・diag・apns・gpu・trainer に同じものを渡す）"""

    def __init__(self, start: float) -> None:
        self.now = float(start)

    def __call__(self) -> float:
        return self.now

    def set(self, when: float) -> None:
        self.now = float(when)

    def advance(self, seconds: float) -> None:
        self.now += seconds


def local(y: int, mo: int, d: int, h: int, mi: int) -> float:
    return time.mktime((y, mo, d, h, mi, 0, 0, 0, -1))


class Client:
    """PC の中だけに送る、ただの http"""

    def __init__(self, port: int) -> None:
        self.port = port

    def call(self, method: str, path: str, body: bytes | None = None, headers: dict | None = None,
             key: str | None = KEY) -> tuple[int, dict | str | bytes, dict]:
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=60)
        try:
            sent = dict(headers or {})
            if key is not None:
                sent.setdefault("Authorization", f"Bearer {key}")
            connection.request(method, path, body=body, headers=sent)
            response = connection.getresponse()
            raw = response.read()
            kind = response.getheader("Content-Type") or ""
            if "json" in kind:
                data = json.loads(raw or b"{}")
            elif kind.startswith("image/"):
                data = raw
            else:
                data = raw.decode("utf-8", "replace")
            return response.status, data, {k.lower(): v for k, v in response.getheaders()}
        except OSError as error:
            return 0, {"error": repr(error)}, {}
        finally:
            connection.close()


def wait_for(condition, seconds: float = 10.0) -> bool:
    deadline = time.time() + seconds
    while time.time() < deadline:
        if condition():
            return True
        time.sleep(0.05)
    return bool(condition())


# MARK: - 作り物の相手


class FakeApns:
    """h2c（暗号なしの HTTP/2）で APNs のふりをする。来た頼みを覚え、決めておいた答えを返す。"""

    def __init__(self) -> None:
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(8)
        self.port = self.sock.getsockname()[1]
        self.requests: list[dict] = []
        self.replies: list[tuple[int, bytes]] = []
        self.lock = threading.Lock()
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self) -> None:
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self.handle, args=(conn,), daemon=True).start()

    def handle(self, conn: socket.socket) -> None:
        import h2.config
        import h2.connection
        import h2.events

        h2c = h2.connection.H2Connection(config=h2.config.H2Configuration(client_side=False, header_encoding="utf-8"))
        h2c.initiate_connection()
        conn.sendall(h2c.data_to_send())
        streams: dict[int, dict] = {}
        try:
            while True:
                data = conn.recv(65535)
                if not data:
                    break
                for event in h2c.receive_data(data):
                    if isinstance(event, h2.events.RequestReceived):
                        streams[event.stream_id] = {"headers": dict(event.headers), "body": b""}
                    elif isinstance(event, h2.events.DataReceived):
                        streams[event.stream_id]["body"] += event.data
                        h2c.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                    elif isinstance(event, h2.events.StreamEnded):
                        request = streams.pop(event.stream_id)
                        with self.lock:
                            self.requests.append(request)
                            status, body = self.replies.pop(0) if self.replies else (200, b"")
                        headers = [(":status", str(status)), ("apns-id", "00000000-0000-4000-8000-000000000001")]
                        if body:
                            headers += [("content-type", "application/json"), ("content-length", str(len(body)))]
                        h2c.send_headers(event.stream_id, headers, end_stream=not body)
                        if body:
                            h2c.send_data(event.stream_id, body, end_stream=True)
                out = h2c.data_to_send()
                if out:
                    conn.sendall(out)
        except Exception:  # noqa: BLE001 — 作り物なので、切れたら終わり
            pass
        finally:
            conn.close()

    def close(self) -> None:
        self.sock.close()


def b64decode(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def check_jwt(token: str, public_key) -> tuple[dict, dict, bool]:
    """(見出し, 中身, 署名が合うか)"""
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature

    head, claims, sig = token.split(".")
    raw = b64decode(sig)
    try:
        public_key.verify(encode_dss_signature(int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big")),
                          f"{head}.{claims}".encode("ascii"), ec.ECDSA(hashes.SHA256()))
        good = len(raw) == 64
    except Exception:  # noqa: BLE001
        good = False
    return json.loads(b64decode(head)), json.loads(b64decode(claims)), good


PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64


class FakeAsc(BaseHTTPRequestHandler):
    """App Store Connect API の作り物（アプリ・スクショつきの報告・落ちた報告・落ちた記録・スクショの画像）"""

    requests: list[dict] = []

    def log_message(self, format: str, *args) -> None:
        pass

    def reply(self, status: int, body: bytes, kind: str = "application/json") -> None:
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        url = urlparse(self.path)
        query = parse_qs(url.query)
        FakeAsc.requests.append({"path": url.path, "query": query, "auth": self.headers.get("Authorization")})
        base = f"http://127.0.0.1:{self.server.server_address[1]}"
        if url.path == "/img/1.png":
            self.reply(200, PNG, "image/png")
            return
        if not (self.headers.get("Authorization") or "").startswith("Bearer "):
            self.reply(401, b'{"errors":[{"status":"401"}]}')
            return
        if url.path == "/v1/apps":
            body = {"data": [{"type": "apps", "id": "app1"}]} if query.get("filter[bundleId]") == [ascfeedback.BUNDLE_ID] \
                else {"data": []}
        elif url.path == "/v1/apps/app1/betaFeedbackScreenshotSubmissions":
            body = {"data": [{"type": "betaFeedbackScreenshotSubmissions", "id": "shot-1",
                              "attributes": {"createdDate": "2026-11-07T01:02:03.000Z", "comment": "秘密のコメントです",
                                             "email": "tester@example.com", "deviceModel": "iPhone17,1",
                                             "osVersion": "26.1", "batteryPercentage": 80,
                                             "screenshots": [{"url": base + "/img/1.png", "width": 10, "height": 20,
                                                              "expirationDate": "2026-11-08T00:00:00Z"}]},
                              "relationships": {"build": {"data": {"type": "builds", "id": "b1"}}}}],
                    "included": [{"type": "builds", "id": "b1", "attributes": {"version": "154"}}],
                    "links": {"self": base + url.path}}
        elif url.path == "/v1/apps/app1/betaFeedbackCrashSubmissions":
            body = {"data": [{"type": "betaFeedbackCrashSubmissions", "id": "crash-1",
                              "attributes": {"createdDate": "2026-11-06T22:00:00Z", "comment": "落ちました",
                                             "deviceModel": "iPhone17,1", "osVersion": "26.1"},
                              "relationships": {"build": {"data": {"type": "builds", "id": "b1"}}}}],
                    "included": [{"type": "builds", "id": "b1", "attributes": {"version": "154"}}],
                    "links": {"self": base + url.path}}
        elif url.path == "/v1/betaFeedbackCrashSubmissions/crash-1/crashLog":
            body = {"data": {"type": "betaCrashLogs", "id": "log-1",
                             "attributes": {"logText": "Incident Identifier: X\nThread 0 Crashed:\n0 LifeLog 0x1"}}}
        else:
            self.reply(404, b'{"errors":[{"status":"404"}]}')
            return
        self.reply(200, json.dumps(body, ensure_ascii=False).encode("utf-8"))


class FakeOllama(BaseHTTPRequestHandler):
    """/api/ps・/api/generate・/api/embed だけの作り物。bge-m3 は言葉を作れない（generate を断る）モデルのふり"""

    calls: list[tuple[str, dict]] = []
    expires: dict[str, str] = {}

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
        self.reply({"models": [{"name": n, "model": n, "expires_at": e} for n, e in FakeOllama.expires.items()]})

    def do_POST(self) -> None:
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        FakeOllama.calls.append((self.path, body))
        if self.path == "/api/generate" and body.get("model", "").startswith("bge-m3"):
            self.reply({"error": '"bge-m3" does not support generate'})
        elif self.path == "/api/embed":
            self.reply({"embeddings": [[0.0, 1.0]]})
        else:
            self.reply({"done": True})


class Fake:
    """作り物の文字起こしのモデル"""

    def __init__(self, name: str, provider: str = "cpu") -> None:
        self.name = self.label = name
        self.provider = provider
        self.lock = threading.Lock()
        self.model = object()

    def run(self, audio, segments, hints, prompt):
        return ["作り物" for _ in segments]


class FakeEnsemble:
    def __init__(self, engines: list) -> None:
        self.engines = engines
        self.label = "＋".join(e.name for e in engines)
        self.provider = "cuda"


# MARK: - まとめて動かす


def run(main) -> int:
    # 版 8: LOCALAPPDATA を一時にしていなくても、本物の HOME（log.txt・データ）に書かない
    main.isolate_home()
    failed = 0
    saved_env = {k: os.environ.get(k) for k in ("SSLKEYLOGFILE", "LIFELOG_FAKE_TRAIN")}
    saved = (main.log, getattr(main.Handler, "key", None), getattr(main.Handler, "engine", None), main.App.jobs,
             main.App.transcribing, dict(ops.O.settings), main.PERSONAL_DATA, main.PERSONAL_MODEL)
    logged: list[str] = []

    def capture(message: str) -> None:
        logged.append(message)
        print("  記録: " + message, flush=True)

    with tempfile.TemporaryDirectory() as folder:
        root = Path(folder)
        try:
            main.log = capture
            # /train-status が数える材料も一時フォルダのもの（この PC の本物の HOME は読まない）
            main.PERSONAL_DATA = root / "home" / "personal" / "data"
            main.PERSONAL_MODEL = root / "home" / "personal" / "model"
            failed += check_diag_units()
            failed += check_gpu_plan(root / "gpu")
            failed += check_ollama()
            failed += check_runtime(root / "runtime", main)
            failed += check_trainer(root / "train", main)
            failed += check_jobqueue_callback(root / "jobs")
            failed += check_live(root / "home", main, logged)
        finally:
            ops.stop()
            (main.log, main.Handler.key, engine, main.App.jobs, main.App.transcribing, settings, main.PERSONAL_DATA,
             main.PERSONAL_MODEL) = saved
            if engine is not None:
                main.Handler.engine = engine
            ops.O.settings.clear()
            ops.O.settings.update(settings)
            for name, value in saved_env.items():
                if value is None:
                    os.environ.pop(name, None)
                else:
                    os.environ[name] = value
    print(("すべて OK" if not failed else f"NG が {failed} 個あります"), flush=True)
    return failed


# MARK: - 実機の様子（決まりだけ）


def check_diag_units() -> int:
    failed = 0
    utc = datetime.timezone.utc
    want = datetime.datetime(2026, 11, 7, 6, 58, 25, tzinfo=utc).timestamp()
    got = [diag.parse_time("2026-11-07T06:58:25.123Z"), diag.parse_time("2026-11-07T06:58:25Z"),
           diag.parse_time("2026-11-07T15:58:25+09:00"), diag.parse_time("2026-11-07T06:58:25.123"),
           diag.parse_time(want), diag.parse_time("きのう"), diag.parse_time(None), diag.parse_time(True)]
    ok = abs(got[0] - (want + 0.123)) < 1e-6 and got[1] == want and got[2] == want and abs(got[3] - (want + 0.123)) < 1e-6 \
        and got[4] == want and got[5:] == [None, None, None] and diag.iso(want + 0.123) == "2026-11-07T06:58:25.123Z"
    failed += say(ok, f"日時の読み方（ミリ秒あり・なし・Z・+09:00・時差なし）: {got[:4]}")
    ids = [diag.valid_device(DEVICE), diag.valid_device("../x"), diag.valid_device("short"), diag.valid_device(None),
           diag.valid_device("a" * 65)]
    failed += say(ids == [True, False, False, False, False], f"端末の ID の決まり: {ids}")
    now = want
    record = {"deviceID": DEVICE, "receivedAt": diag.iso(now - 10), "sentAt": diag.iso(now - 20),
              "rows": [{"group": "端末", "name": "空き容量", "value": "1 GB", "ok": False},
                       {"group": "端末", "name": "電池", "value": "80%", "ok": True}],
              "crashes": [{"kind": "落ちた", "at": diag.iso(now - 3600), "detail": "例外 EXC_BAD_ACCESS"},
                          {"kind": "crash", "at": diag.iso(now - 2 * 86400)}, {"kind": "CPU を使いすぎた", "at": diag.iso(now)}],
              "state": {"phoneRecording": False, "watchRecording": True, "watchHeartbeatAt": diag.iso(now - 45 * 60),
                        "lastChunkAt": diag.iso(now - 75 * 60)}}
    found = diag.concerns(record, now)
    texts = " / ".join(found)
    ok = len(found) == 4 and "24時間以内に 落ちた 1 回" in texts and "空き容量" in texts and "時計からの便り" in texts \
        and "録音の区切り" in texts and "届いていません" not in texts
    failed += say(ok, f"気になる所（落ちた・ok でない行・時計の便り・録音の区切り）: {found}")
    stale = diag.concerns(dict(record, receivedAt=diag.iso(now - 4 * 3600), sentAt=diag.iso(now - 4 * 3600),
                               rows=[], crashes=[], state={}), now)
    retired = diag.concerns(dict(record, receivedAt=diag.iso(now - 15 * 86400)), now)
    calm = diag.concerns(dict(record, rows=[], crashes=[], state={"phoneRecording": True, "lastChunkAt": diag.iso(now - 300)}), now)
    ok = len(stale) == 1 and "様子が届いていません" in stale[0] and retired == [] and calm == []
    failed += say(ok, f"3時間届かない {stale}・使わなくなった端末は数えない {retired}・何もなければ {calm}")
    return failed


# MARK: - GPU の時間割


def check_gpu_plan(folder: Path) -> int:
    failed = 0
    messages: list[str] = []
    clock = Clock(local(2026, 11, 8, 0, 30))
    ensemble = FakeEnsemble([Fake("haas"), Fake("reazon"), Fake("whisper", "cuda"), Fake("kotoba", "cuda")])
    built: list[str] = []
    memory = {"free": 7000}
    behavior = {"provider": "cuda"}

    def build(name: str):
        built.append(name)
        return Fake(name, behavior["provider"])

    plan = gpu.GpuPlan(lambda: ensemble, build, messages.append, clock, free_mb=lambda: memory["free"])
    plan.night = gpu.night_config({})
    plan.last_work = clock()
    plan.tick(False)
    early = [e.name for e in ensemble.engines]
    clock.set(local(2026, 11, 8, 1, 10))
    plan.tick(False)
    night = [e.name for e in ensemble.engines]
    ok = early == ["haas", "reazon", "whisper", "kotoba"] and night == ["haas", "reazon"] \
        and plan.status()["mode"] == "night" and ensemble.provider == "cpu" and ensemble.label == "haas＋reazon"
    failed += say(ok, f"0:30 は下ろさない {early}・1:10（40 分仕事なし）は下ろす {night}・{plan.status()['text']}")
    clock.advance(60)
    plan.note_work()
    back = wait_for(lambda: [e.name for e in ensemble.engines] == ["haas", "reazon", "whisper", "kotoba"]
                    and plan.status()["mode"] == "day", 10)
    failed += say(back and built == ["whisper", "kotoba"] and ensemble.provider == "cuda",
                  f"仕事が来たら戻す: {[e.name for e in ensemble.engines]}（作り直したもの {built}）")
    # 学び直しのあいだは、仕事が来ても戻さない
    plan.hold("train")
    held = [e.name for e in ensemble.engines]
    plan.note_work()
    time.sleep(0.3)
    still = [e.name for e in ensemble.engines]
    plan.want("mine")
    plan.release("train", wait=True)
    after = [e.name for e in ensemble.engines]
    ok = held == ["haas", "reazon"] and still == held and after == ["haas", "reazon", "whisper", "kotoba", "mine"] \
        and plan.status()["mode"] == "day" and not plan.status()["down"]
    failed += say(ok, f"学び直しのあいだ {held}（仕事が来ても {still}）→ 終わったら mine も載せて {after}")
    # 夜に学び直しが終わり、仕事も無ければ、下ろしたまま
    clock.set(local(2026, 11, 8, 4, 0))
    plan.last_work = clock() - 3600
    plan.hold("train")
    plan.release("train", wait=True)
    stay = [e.name for e in ensemble.engines]
    ok = stay == ["haas", "reazon"] and plan.status()["mode"] == "night"
    failed += say(ok, f"夜に学び直しが終わって仕事も無ければ、下ろしたまま: {stay}（{plan.status()['mode']}）")
    # GPU の空きが足りないとき・CPU に落ちたものは使わない（5 分おいてやり直す）
    memory["free"] = 500
    built.clear()
    plan.note_work()
    time.sleep(0.5)
    short = [e.name for e in ensemble.engines]
    tried = list(built)
    memory["free"] = 7000
    behavior["provider"] = "cpu"
    clock.advance(gpu.RETRY + 1)
    plan.restore()
    fell = [e.name for e in ensemble.engines]
    behavior["provider"] = "cuda"
    clock.advance(gpu.RETRY + 1)
    plan.tick(True)
    recovered = wait_for(lambda: [e.name for e in ensemble.engines] == ["haas", "reazon", "whisper", "kotoba", "mine"], 10)
    ok = short == ["haas", "reazon"] and tried == [] and fell == ["haas", "reazon"] and recovered \
        and any("空きが" in m for m in messages) and any("GPU に載らなかった" in m for m in messages)
    failed += say(ok, f"空きが足りなければ戻さない {short}・CPU に落ちたものは使わない {fell}・あとで戻す {recovered}")
    config = gpu.night_config({"gpu_night": {"start": "02:30", "end": "05:00", "idle_minutes": 10}})
    off = gpu.night_config({"gpu_night": False})
    windows = [gpu.in_window(local(2026, 11, 8, 23, 30), (23, 0), (6, 0)), gpu.in_window(local(2026, 11, 8, 6, 0), (1, 0), (6, 0)),
               gpu.in_window(local(2026, 11, 8, 1, 0), (1, 0), (6, 0))]
    ok = config == {"start": (2, 30), "end": (5, 0), "idle": 600.0} and off is None and windows == [True, False, True]
    failed += say(ok, f"夜の割り当ての設定: {config}・やめる {off}・日をまたぐ時間帯 {windows}")
    return failed


# MARK: - Ollama


def check_ollama() -> int:
    FakeOllama.calls = []
    now = time.time()
    FakeOllama.expires = {"qwen3:8b": diag.iso(now + 300), "bge-m3:latest": "2318-01-01T00:00:00Z"}
    server = ThreadingHTTPServer(("127.0.0.1", 0), FakeOllama)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    messages: list[str] = []
    try:
        client = gpu.Ollama(f"http://127.0.0.1:{server.server_address[1]}", messages.append)
        saved = client.unload_all(now)
        unload_calls = list(FakeOllama.calls)
        FakeOllama.calls = []
        back = client.restore(saved)
        restore_calls = list(FakeOllama.calls)
        try:
            gpu.Ollama("http://192.168.1.2:11434")
            local_only = False
        except ValueError:
            local_only = True
    finally:
        server.shutdown()
        server.server_close()
    ok = saved == [{"name": "qwen3:8b", "long": False}, {"name": "bge-m3:latest", "long": True}] \
        and ("/api/generate", {"model": "qwen3:8b", "keep_alive": 0}) in unload_calls \
        and ("/api/embed", {"model": "bge-m3:latest", "input": " ", "keep_alive": 0}) in unload_calls \
        and back == 1 and ("/api/embed", {"model": "bge-m3:latest", "input": " ", "keep_alive": -1}) in restore_calls \
        and not any(c[1].get("model") == "qwen3:8b" for c in restore_calls) and local_only
    return say(ok, f"Ollama: 下ろす {saved}・長く載せておく設定だったものだけ載せ直す（{back} 個）・宛先はこの PC の中だけ")


# MARK: - 学び直しの部品


def make_tar(members: dict[str, bytes]) -> bytes:
    body = io.BytesIO()
    with tarfile.open(fileobj=body, mode="w:gz") as tar:
        for name, data in members.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
    return body.getvalue()


def check_runtime(folder: Path, main) -> int:
    failed = 0
    folder.mkdir(parents=True)
    good = make_tar({"python/python.exe": b"fake", "python/Lib/os.py": b"#", "python/bin/python3": b"fake"})
    digest = hashlib.sha256(good).hexdigest()
    commands: list[tuple[list[str], dict]] = []
    messages: list[str] = []

    def runner(command, log_path, env, timeout, cwd) -> int:
        commands.append((list(command), dict(env)))
        return 0

    def bad_download(url, target):
        Path(target).write_bytes(b"not the python we wanted")

    def good_download(url, target):
        Path(target).write_bytes(good)

    os.environ["SSLKEYLOGFILE"] = str(folder / "keylog.txt")
    home = folder / "home"
    wrong = trainer.Runtime(home, main.INSTALL_DIR, messages.append, download=bad_download, run=runner, sha256=digest)
    wrong.need_disk = 0
    try:
        wrong.prepare()
        refused = False
    except RuntimeError as error:
        refused = "ハッシュ" in str(error)
    ok = refused and not (home / "train" / "python").exists() and not list((home / "train" / "download").glob("*")) \
        and commands == [] and not wrong.ready()
    failed += say(ok, "学び直しの部品: ハッシュの合わない Python は使わない（消して、展開もしない）")
    right = trainer.Runtime(home, main.INSTALL_DIR, messages.append, download=good_download, run=runner, sha256=digest,
                            drop_paths=[home / "cuda"])
    right.need_disk = 0
    right.prepare()
    install = next((c for c, _ in commands if "install" in c), [])
    envs = [e for _, e in commands]
    ok = right.ready() and right.python.exists() and len(commands) == 3 and "--require-hashes" in install \
        and "--no-deps" in install and "--only-binary=:all:" in install and str(right.requirements) in install \
        and install[install.index("--index-url") + 1] == trainer.PIP_INDEX \
        and all("SSLKEYLOGFILE" not in e for e in envs) and all(e.get("HF_HOME") == str(home / "train" / "hf") for e in envs) \
        and all(e.get("PYTHONNOUSERSITE") == "1" for e in envs)
    failed += say(ok, f"学び直しの部品: 確かめて展開し、pip に --require-hashes で頼む（{len(commands)} 回）・"
                      "子に SSLKEYLOGFILE を渡さない")
    # pip の途中で止まった（ready.json が無い）ときは、Python を取ってき直さずに続きから
    (home / "train" / "ready.json").unlink()
    commands.clear()
    resumed = trainer.Runtime(home, main.INSTALL_DIR, messages.append, download=bad_download, run=runner, sha256=digest)
    resumed.need_disk = 0
    resumed.prepare()
    ok = resumed.ready() and len(commands) == 3 and (home / "train" / "python" / "Lib" / "os.py").exists()
    failed += say(ok, "学び直しの部品: 途中で止まっても、Python は取ってき直さずに続きから用意する")
    evil = folder / "evil.tar.gz"
    evil.write_bytes(make_tar({"../outside.txt": b"bad"}))
    try:
        trainer.safe_untar(evil, folder / "out")
        stopped = False
    except ValueError:
        stopped = True
    failed += say(stopped and not (folder / "outside.txt").exists(), "tar の中に外を指すもの（../）があれば展開しない")
    # 決めておいた部品の一覧（torch は Windows・Python 3.12 の cu124 の wheel、どれもハッシュつき）
    text = (Path(main.INSTALL_DIR) / trainer.REQUIREMENTS).read_text(encoding="utf-8")
    entries = [e for e in text.replace("\\\n", " ").splitlines() if e.strip() and not e.startswith("#")]
    names = {e.split("==")[0].split(" @ ")[0].strip() for e in entries}
    ok = all("--hash=sha256:" in e and ("==" in e or e.startswith("torch @ https://download.pytorch.org/")) for e in entries) \
        and {"torch", "transformers", "peft", "accelerate", "ctranslate2", "faster-whisper", "numpy"} <= names \
        and "cu124-cp312-cp312-win_amd64.whl" in text
    failed += say(ok, f"{trainer.REQUIREMENTS}: {len(entries)} 個、どれも版とハッシュが決まっている")
    os.environ.pop("SSLKEYLOGFILE", None)
    return failed


# MARK: - 自動の学び直し


FAKE_TRAIN = r"""@echo off
setlocal
> "%~3\personal\args.txt" echo %2 [%~3]
> "%~3\personal\env.txt" echo [%SSLKEYLOGFILE%]
if "%LIFELOG_FAKE_TRAIN%"=="refuse" goto refuse
if "%LIFELOG_FAKE_TRAIN%"=="slow" goto slow
echo 10:00:00 base model
echo 10:00:01 before CER: 12.00%%
echo 10:00:02   1 epoch
echo 10:00:03 after CER: 10.00%%
if "%LIFELOG_FAKE_TRAIN%"=="same" exit /b 0
if not exist "%~3\personal\model" mkdir "%~3\personal\model"
> "%~3\personal\model\model.bin" echo x
> "%~3\personal\model\trained.json" echo {"trained": "%RANDOM%%RANDOM%", "cer_before": 0.12, "cer_after": 0.10, "samples": 320}
exit /b 0
:refuse
type "%~dp0refuse.txt"
exit /b 2
:slow
ping -n 20 127.0.0.1 >nul
exit /b 0
"""


def check_trainer(folder: Path, main) -> int:
    failed = 0
    parsed = trainer.train_config({"autotrain": {"days": ["sat", "日"], "start": "03:00", "end": "05:30", "min_samples": 10,
                                                 "min_new": 5, "max_hours": 0.5, "args": ["--batch", "2"]}})
    bad_args = trainer.train_config({"autotrain": {"args": ["--home", "x"]}})["args"]
    off = trainer.train_config({"autotrain": False})["enabled"]
    friday = trainer.next_window(local(2026, 11, 6, 10, 0), ["sun"], "02:00", "06:00")
    inside = trainer.next_window(local(2026, 11, 8, 3, 0), ["sun"], "02:00", "06:00")
    after = trainer.next_window(local(2026, 11, 8, 7, 0), ["sun"], "02:00", "06:00")
    ok = parsed["days"] == ["sat", "sun"] and parsed["start"] == "03:00" and parsed["end"] == "05:30" \
        and parsed["min_samples"] == 10 and parsed["args"] == ["--batch", "2"] and bad_args is None and off is False \
        and friday == (local(2026, 11, 8, 2, 0), local(2026, 11, 8, 6, 0)) \
        and inside == (local(2026, 11, 8, 2, 0), local(2026, 11, 8, 6, 0)) \
        and after == (local(2026, 11, 15, 2, 0), local(2026, 11, 15, 6, 0)) \
        and trainer.window_text(trainer.train_config({})) == "日曜 02:00〜06:00"
    failed += say(ok, f"学び直しの時間帯: 金曜 10:00 → {time.strftime('%m/%d %H:%M', time.localtime(friday[0]))}・"
                      f"日曜 7:00 → {time.strftime('%m/%d %H:%M', time.localtime(after[0]))}・設定 {parsed['days']}")
    if os.name != "nt":
        return failed + say(True, "作り物の学び直し（.cmd）は Windows だけで確かめます")
    home = folder / "home"
    (home / "personal").mkdir(parents=True)
    tools = folder / "tools"
    tools.mkdir()
    fake = tools / "fake-python.cmd"
    fake.write_text(FAKE_TRAIN.replace("\n", "\r\n"), encoding="utf-8")
    (tools / "refuse.txt").write_text("GPU のメモリが足りませんでした。--batch 2 で、もう一度試してください。モデルは入れ替えていません。\r\n",
                                      encoding="utf-8")
    # 部品は用意できていることにする
    runtime = trainer.Runtime(home, main.INSTALL_DIR, print)
    runtime.python.parent.mkdir(parents=True)
    runtime.python.write_bytes(b"fake")
    trainer._write_json(home / "train" / "ready.json", {"python": runtime.sha256, "lock": runtime.lock_hash()})
    clock = Clock(local(2026, 11, 7, 12, 0))
    messages: list[str] = []
    counter = {"n": 299, "busy": False, "improved": 0}
    ensemble = FakeEnsemble([Fake("haas"), Fake("reazon"), Fake("whisper", "cuda")])
    plan = gpu.GpuPlan(lambda: ensemble, lambda name: Fake(name, "cuda"), messages.append, clock, free_mb=lambda: None)
    plan.night = None  # 夜の割り当ては check_gpu_plan で確かめる（ここでは、学び直しが終わったら戻すことだけを見る）
    during: list[list[str]] = []
    original_hold = plan.hold

    def hold(reason: str) -> None:
        original_hold(reason)
        during.append([e.name for e in ensemble.engines])

    plan.hold = hold
    FakeOllama.calls = []
    FakeOllama.expires = {"qwen3:8b": diag.iso(time.time() + 300)}
    server = ThreadingHTTPServer(("127.0.0.1", 0), FakeOllama)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    auto = trainer.AutoTrainer(home, main.INSTALL_DIR, messages.append, gpu_plan=plan,
                               ollama=gpu.Ollama(f"http://127.0.0.1:{server.server_address[1]}", messages.append),
                               count_samples=lambda: counter["n"], is_idle=lambda: not counter["busy"],
                               has_gpu=lambda: True, on_improved=lambda: counter.__setitem__("improved", counter["improved"] + 1),
                               runtime=runtime, clock=clock, python=lambda: str(fake))
    auto.configure({})
    os.environ["SSLKEYLOGFILE"] = str(folder / "keylog.txt")
    try:
        def tick_wait() -> None:
            auto.tick()
            if auto.thread is not None:
                auto.thread.join(timeout=60)
                auto.thread = None

        tick_wait()
        few = auto.status()["state"]
        counter["n"] = 320
        tick_wait()
        outside = auto.status()["state"]
        clock.set(local(2026, 11, 8, 2, 30))
        counter["busy"] = True
        tick_wait()
        busy_state = auto.status()["state"]
        counter["busy"] = False
        os.environ["LIFELOG_FAKE_TRAIN"] = "improved"
        tick_wait()
        status = auto.status()
        last = status["last"] or {}
        args_text = (home / "personal" / "args.txt").read_text(encoding="utf-8", errors="replace").strip()
        env_text = (home / "personal" / "env.txt").read_text(encoding="utf-8", errors="replace").strip()
        ok = few == "材料を待っています" and outside == "学び直しの時間帯を待っています" and busy_state == "仕事が終わるのを待っています" \
            and last.get("result") == "improved" and last.get("cer_after") == 0.10 and counter["improved"] == 1 \
            and auto.state.get("base_count") == 320 and during == [["haas", "reazon"]] \
            and [e.name for e in ensemble.engines] == ["haas", "reazon", "whisper"] \
            and args_text == f"--home [{home}]" and env_text == "[]" \
            and ("/api/generate", {"model": "qwen3:8b", "keep_alive": 0}) in FakeOllama.calls \
            and any("良くなったので" in m for m in messages)
        failed += say(ok, f"自動の学び直し: 材料 299 → {few}・時間帯の外 → {outside}・仕事中 → {busy_state}・"
                          f"時間帯で仕事なし → {last.get('result')}（GPU は {during}、終わって {[e.name for e in ensemble.engines]}）・"
                          f"子の引数 {args_text}・子の SSLKEYLOGFILE {env_text}")
        clock.set(local(2026, 11, 15, 2, 30))
        counter["n"] = 330
        tick_wait()
        more = auto.status()["state"]
        counter["n"] = 380
        os.environ["LIFELOG_FAKE_TRAIN"] = "same"
        tick_wait()
        same = auto.status()["last"] or {}
        ok = more == "材料を待っています" and same.get("result") == "not_improved" and same.get("cer_before") == 0.12 \
            and same.get("cer_after") == 0.10 and auto.state.get("base_count") == 380 and counter["improved"] == 1
        failed += say(ok, f"増えた材料が 50 より少なければ待つ（{more}）・良くならなければ {same.get('result')}"
                          f"（{same.get('cer_before')} → {same.get('cer_after')}、前のモデルのまま）")
        clock.set(local(2026, 11, 22, 2, 30))
        counter["n"] = 440
        os.environ["LIFELOG_FAKE_TRAIN"] = "refuse"
        tick_wait()
        refused = auto.status()["last"] or {}
        smaller = auto.command()
        clock.advance(600)
        tick_wait()
        done_state = auto.status()["state"]
        ok = refused.get("result") == "refused" and "メモリが足りません" in (refused.get("message") or "") \
            and smaller[-4:] == ["--batch", "2", "--accumulate", "4"] and auto.state.get("base_count") == 380 \
            and done_state == "この時間帯の学び直しは終わりました"
        failed += say(ok, f"断られたら {refused.get('result')}（{refused.get('message')}）・次は小さく学ぶ {smaller[-4:]}・"
                          f"同じ時間帯には1回だけ（{done_state}）")
        clock.set(local(2026, 11, 29, 2, 30))
        os.environ["LIFELOG_FAKE_TRAIN"] = "slow"
        auto.configure({"autotrain": {"max_hours": 0.5}})
        (home / "personal" / "args.txt").unlink(missing_ok=True)
        auto.tick()
        # 子のプロセスが動き出してから（始めた時刻を覚えてから）、時計を進める
        started = auto.running and wait_for(lambda: (home / "personal" / "args.txt").exists(), 20)
        clock.advance(3600)
        if auto.thread is not None:
            auto.thread.join(timeout=60)
        slow = auto.status()["last"] or {}
        ok = started and slow.get("result") == "timeout" and not auto.running \
            and [e.name for e in ensemble.engines] == ["haas", "reazon", "whisper"]
        failed += say(ok, f"時間がかかりすぎたら止める: {slow.get('result')}（{slow.get('message')}）")
        report = auto.status()
        ok = set(report) >= {"enabled", "available", "state", "window", "next", "last", "count", "since_last", "runtime"} \
            and report["available"] and report["runtime"] == "用意できています"
        failed += say(ok, f"/train-status の auto の項目: {sorted(report)}")
    finally:
        os.environ.pop("SSLKEYLOGFILE", None)
        os.environ.pop("LIFELOG_FAKE_TRAIN", None)
        server.shutdown()
        server.server_close()
    return failed


# MARK: - jobqueue の「仕事が終わったとき」の口


def check_jobqueue_callback(folder: Path) -> int:
    finished: list[tuple[str, str]] = []

    def runner(path, params, name):
        if name.startswith("bad"):
            raise RuntimeError("作り物の失敗")
        return {"lines": []}, {"audio_seconds": 1.0}

    def broken(name: str, meta: dict) -> None:
        raise RuntimeError("口が失敗")

    queue = jobqueue.JobQueue(folder, runner, lambda m: None)
    queue.on_done = lambda name, meta: finished.append((name, meta.get("status")))
    for name in ("good-1.m4a", "bad-1.m4a"):
        assert queue.begin(name)[0] == "ok"
        queue.part_path(name).write_bytes(b"x")
        queue.commit(name, {"hints": []}, 1)
    while queue.step():
        pass
    queue.on_done = broken
    assert queue.begin("good-2.m4a")[0] == "ok"
    queue.part_path("good-2.m4a").write_bytes(b"x")
    queue.commit("good-2.m4a", {"hints": []}, 1)
    survived = queue.step() and queue.get("good-2.m4a")["status"] == "done"
    # 版 8 から、待っているものが2つ以上なら新しいほうから文字にするので、並びは見ない
    ok = sorted(finished) == sorted([("good-1.m4a", "done"), ("bad-1.m4a", "failed")]) and survived
    return say(ok, f"jobqueue の「仕事が終わったとき」の口: {finished}・口が失敗しても裏の仕事は続く {survived}")


# MARK: - 受け付け・見守りの画面・通知・TestFlight の報告（一時フォルダの HOME で ops を本当に動かす）


def check_live(home: Path, main, logged: list[str]) -> int:
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ec

    failed = 0
    home.mkdir(parents=True)
    clock = Clock(local(2026, 11, 7, 12, 0))
    push = FakeApns()
    FakeAsc.requests = []
    asc = ThreadingHTTPServer(("127.0.0.1", 0), FakeAsc)
    threading.Thread(target=asc.serve_forever, daemon=True).start()
    FakeOllama.calls = []
    FakeOllama.expires = {}
    ollama = ThreadingHTTPServer(("127.0.0.1", 0), FakeOllama)
    threading.Thread(target=ollama.serve_forever, daemon=True).start()
    main.Handler.key = KEY
    main.App.jobs = None
    main.App.transcribing = 0
    ops.configure(fake=True)
    main.Handler.engine = main.Ensemble(ops.fake_engines())
    ops.start(main, home=home, background=False, clock=clock,
              apns_hosts={"production": f"http://127.0.0.1:{push.port}", "development": f"http://127.0.0.1:{push.port}"},
              asc_base=f"http://127.0.0.1:{asc.server_address[1]}", ollama_url=f"http://127.0.0.1:{ollama.server_address[1]}",
              has_gpu=lambda: True, free_mb=lambda: None, count_samples=lambda: 12)
    server = main.Server(("127.0.0.1", 0), main.Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    client = Client(server.server_address[1])
    try:
        # 鍵が無いとき（何もしない。テスト通知のボタンは、鍵が無いと言う）
        hello = client.call("GET", "/hello")
        no_key = client.call("POST", "/dash/ops/apns-test", b"{}", headers={**BASIC, dashboard.HEADER: "1"}, key=None)
        quiet = ops.O.pusher.send("wake")
        ok = hello[0] == 200 and "diag" in hello[1]["features"] and "push" not in hello[1]["features"] \
            and "autotrain" in hello[1]["features"] and no_key[0] == 200 and "鍵がありません" in no_key[1].get("message", "") \
            and quiet == [{"ok": False, "reason": "鍵がありません"}] and not push.requests
        failed += say(ok, f"鍵が無いとき: features {hello[1].get('features') if hello[0] == 200 else hello}・"
                          f"テスト通知のボタン「{no_key[1].get('message') if no_key[0] == 200 else no_key}」・送らない")
        # POST /diag
        now = clock()
        body = {"deviceID": DEVICE, "device": "iPhone", "model": "iPhone17,1", "os": "26.1", "build": 154,
                "install": "testflight", "sentAt": diag.iso(now),
                "rows": [{"group": "端末", "name": "空き容量", "value": "12 GB", "ok": True},
                         {"group": "録音", "name": "マイク", "value": "秘密の値です", "ok": False}],
                "crashes": [{"kind": "落ちた", "at": diag.iso(now - 3600), "detail": "例外 EXC_BAD_ACCESS"}],
                "metrickit": [{"crashDiagnostics": [{"callStackTree": {}}], "timeStampEnd": "2026-11-07 00:00"}],
                "tally": {"2026-11-07": {"jobs.sent": 3}},
                "state": {"phoneRecording": True, "watchRecording": False, "queue": 2, "jobsPending": 1,
                          "lastChunkAt": diag.iso(now - 120), "nightlyDoneFor": "2026-11-06"},
                "push": {"token": TOKEN, "environment": "production", "topic": "com.off53jub.lifelog", "team": TEAM}}
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        first = client.call("POST", "/diag", data, {"Content-Type": "application/json"})
        again = client.call("POST", "/diag", data, {"Content-Type": "application/json"})
        folder = home / "diag" / DEVICE
        today = time.strftime("%Y-%m-%d", time.localtime(now))
        latest = json.loads((folder / "latest.json").read_text(encoding="utf-8"))
        summary = (home / "diag" / "summary.md").read_text(encoding="utf-8")
        ok = first[:2] == (200, {"ok": True}) and again[0] == 200 \
            and len((folder / f"{today}.jsonl").read_text(encoding="utf-8").splitlines()) == 2 \
            and len(list((folder / "metrickit").glob("*.json"))) == 1 and latest["receivedAt"] == diag.iso(now) \
            and latest["metrickit"][0].startswith("metrickit/") and latest["ip"] == "127.0.0.1" \
            and "気になる所" in summary and "iPhone（iPhone17,1・6F1C）" in summary and "マイク" in summary \
            and "24時間以内に 落ちた 1 回" in summary
        failed += say(ok, f"POST /diag: {first[:2]}・置き場所（latest.json・{today}.jsonl 2 行・MetricKit 1 つ）・summary.md")
        bad = {"deviceID なし": client.call("POST", "/diag", b'{"device": "iPhone"}')[0],
               "../": client.call("POST", "/diag", json.dumps({"deviceID": "../../x"}).encode())[0],
               "JSON でない": client.call("POST", "/diag", b"{")[0],
               "大きすぎる": client.call("POST", "/diag", b"x" * (diag.BODY_LIMIT + 10))[0],
               "合言葉違い": client.call("POST", "/diag", data, key="wrong")[0]}
        ok = bad == {"deviceID なし": 400, "../": 400, "JSON でない": 400, "大きすぎる": 413, "合言葉違い": 401} \
            and not (home / "diag" / "x").exists()
        failed += say(ok, f"POST /diag の断り方: {bad}")
        # 鍵を入れる（見守りの画面のボタン）
        key = ec.generate_private_key(ec.SECP256R1())
        pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                serialization.NoEncryption()).decode("ascii")
        (home / "apns").mkdir(exist_ok=True)
        (home / "apns" / "AuthKey_OLDKEY0001.p8").write_text(pem, encoding="utf-8")
        os.utime(home / "apns" / "AuthKey_OLDKEY0001.p8", (time.time() - 100, time.time() - 100))
        dash = {**BASIC, dashboard.HEADER: "1", "Content-Type": "application/json"}
        upload = {"broken": client.call("POST", "/dash/ops/apns-key", json.dumps({"key_id": "TESTKEY123", "p8": "nope"}).encode(),
                                        dash, key=None)[0],
                  "id": client.call("POST", "/dash/ops/apns-key", json.dumps({"key_id": "x/../y", "p8": pem}).encode(),
                                    dash, key=None)[0],
                  "印なし": client.call("POST", "/dash/ops/apns-key", json.dumps({"key_id": "TESTKEY123", "p8": pem}).encode(),
                                      {**BASIC, "Content-Type": "application/json"}, key=None)[0],
                  "合言葉なし": client.call("POST", "/dash/ops/apns-key", json.dumps({"key_id": "TESTKEY123", "p8": pem}).encode(),
                                         {dashboard.HEADER: "1"}, key=None)[0]}
        saved = client.call("POST", "/dash/ops/apns-key", json.dumps({"key_id": "TESTKEY123", "p8": pem}).encode(), dash, key=None)
        hello = client.call("GET", "/hello")
        ok = upload == {"broken": 400, "id": 400, "印なし": 403, "合言葉なし": 401} and saved[0] == 200 \
            and (home / "apns" / "AuthKey_TESTKEY123.p8").exists() and (home / "apns" / "AuthKey_OLDKEY0001.p8.old").exists() \
            and not (home / "apns" / "AuthKey_OLDKEY0001.p8").exists() and "push" in hello[1]["features"] \
            and ops.O.pusher.team_for() == TEAM
        failed += say(ok, f"通知の鍵を入れるボタン: {upload}・正しい鍵 {saved[0]}（{saved[1].get('message') if saved[0] == 200 else ''}）・"
                          f"features に push {('push' in hello[1].get('features', [])) if hello[0] == 200 else hello}")
        # 文字起こしができた → job（その端末へ。同じ端末へは10分に1回まで）
        client.call("POST", "/jobs?name=job-1.m4a", b"x" * 10)
        ops.job_done("job-1.m4a", {"status": "done"})
        got = wait_for(lambda: len(push.requests) == 1, 10)
        request = push.requests[0] if push.requests else {"headers": {}, "body": b"{}"}
        headers = request["headers"]
        auth = headers.get("authorization", "")
        head, claims, signed = check_jwt(auth.removeprefix("bearer "), key.public_key()) if auth.startswith("bearer ") \
            else ({}, {}, False)
        ok = got and headers.get(":method") == "POST" and headers.get(":path") == f"/3/device/{TOKEN}" \
            and headers.get("apns-push-type") == "background" and headers.get("apns-priority") == "5" \
            and headers.get("apns-topic") == "com.off53jub.lifelog" and headers.get("apns-expiration", "").isdigit() \
            and json.loads(request["body"]) == {"aps": {"content-available": 1}, "lifelog": {"kind": "job", "job": "job-1.m4a"}} \
            and head == {"alg": "ES256", "kid": "TESTKEY123"} and claims.get("iss") == TEAM \
            and abs(claims.get("iat", 0) - clock()) < 2 and signed
        failed += say(ok, f"job の通知（HTTP/2）: {headers.get(':path', '')[:20]}… {headers.get('apns-push-type')} "
                          f"優先度 {headers.get('apns-priority')}・JWT {head} iss {claims.get('iss')} 署名 {signed}")
        ops.job_done("job-2.m4a", {"status": "done"})
        time.sleep(0.5)
        limited = len(push.requests)
        clock.advance(601)
        ops.job_done("job-2.m4a", {"status": "done"})
        later = wait_for(lambda: len(push.requests) == 2, 10)
        ops.job_done("job-3.m4a", {"status": "failed"})
        time.sleep(0.3)
        ok = limited == 1 and later and len(push.requests) == 2
        failed += say(ok, f"job は同じ端末へ10分に1回まで（すぐの2回目 {limited} 件のまま・10分あと {len(push.requests)} 件）・失敗した仕事には送らない")
        # 10 分ごとの見回り: 録音中なのに30分なにも来ていない → wake（1時間に2回まで）
        clock.advance(31 * 60)
        sent1 = ops.patrol(clock())
        clock.advance(11 * 60)
        sent2 = ops.patrol(clock())
        clock.advance(11 * 60)
        sent3 = ops.patrol(clock())
        kinds = [json.loads(r["body"])["lifelog"]["kind"] for r in push.requests]
        ok = sent1 == [(DEVICE, "wake")] and sent2 == [(DEVICE, "wake")] and sent3 == [] and kinds[-2:] == ["wake", "wake"]
        failed += say(ok, f"見回り: 録音中で30分なにも来ない → {sent1}・{sent2}・3回目は上限 {sent3}")
        many = [clock() - k * 4000 for k in range(1, 13)]
        ops.O.pusher.sent[DEVICE]["wake"] = many
        full = ops.O.pusher.allowed(DEVICE, "wake")
        ops.O.pusher.sent[DEVICE]["wake"] = many[:11]
        room = ops.O.pusher.allowed(DEVICE, "wake")
        ops.O.pusher.sent[DEVICE]["wake"] = []
        failed += say(not full and room, f"wake は1日12回まで（12 回送ったあと {full}・11 回なら {room}）")
        # 3 時間 diag が来ない → diag（1時間に1回・1日4回まで）
        clock.advance(3 * 3600)
        stale = ops.patrol(clock())
        diag_body = json.loads(push.requests[-1]["body"])
        again_stale = ops.patrol(clock() + 60)
        ok = stale == [(DEVICE, "diag")] and (DEVICE, "diag") not in again_stale \
            and diag_body == {"aps": {"content-available": 1}, "lifelog": {"kind": "diag"}}
        failed += say(ok, f"3時間様子が来ない → {stale}・すぐの2回目に diag は送らない {again_stale}")
        # 毎日 3:30 → nightly（1日1回）
        clock.set(local(2026, 11, 8, 3, 35))
        nightly1 = ops.nightly(clock())
        nightly2 = ops.nightly(clock() + 120)
        clock.set(local(2026, 11, 8, 3, 0))
        early = ops.nightly(clock())
        ok = nightly1 == [DEVICE] and nightly2 == [] and early == [] \
            and json.loads(push.requests[-1]["body"])["lifelog"]["kind"] == "nightly"
        failed += say(ok, f"3:35 に nightly {nightly1}・同じ日の2回目 {nightly2}")
        clock.set(local(2026, 11, 8, 9, 0))
        # テスト通知のボタン（目に見える通知）
        test = client.call("POST", "/dash/ops/apns-test", b"{}", headers=dash, key=None)
        last = push.requests[-1]
        alert = json.loads(last["body"])
        ok = test[0] == 200 and "届けました" in test[1].get("message", "") and last["headers"].get("apns-push-type") == "alert" \
            and last["headers"].get("apns-priority") == "10" and alert["aps"]["alert"]["title"] == "LifeLog PC" \
            and alert["lifelog"] == {"kind": "test"}
        failed += say(ok, f"テスト通知のボタン: {test[1].get('message') if test[0] == 200 else test}")
        # 403 ExpiredProviderToken → JWT を作り直してもう一度・410 → そのトークンは使わない
        count = len(push.requests)
        push.replies = [(403, b'{"reason":"ExpiredProviderToken"}')]
        retried = ops.O.pusher.send("wake", [DEVICE], respect_limits=False)
        retry_count = len(push.requests) - count
        push.replies = [(410, b'{"reason":"Unregistered","timestamp":1762498705000}')]
        clock.advance(3601)
        gone = ops.O.pusher.send("wake", [DEVICE], respect_limits=False)
        count = len(push.requests)
        skipped = ops.O.pusher.send("wake", [DEVICE], respect_limits=False)
        no_more = len(push.requests) == count
        body["push"] = dict(body["push"], token="cd" * 32)
        renewed = client.call("POST", "/diag", json.dumps(body, ensure_ascii=False).encode("utf-8"))
        usable = ops.O.pusher.usable(DEVICE)
        ok = retried[0].get("ok") and retry_count == 2 and gone[0].get("status") == 410 \
            and not skipped[0].get("ok") and "トークン" in skipped[0].get("reason", "") and no_more \
            and renewed[0] == 200 and usable and any("もう使いません" in m for m in logged)
        failed += say(ok, f"403 ExpiredProviderToken は作り直して送る（{retry_count} 回）・410 → {gone[0].get('reason')}、"
                          f"次は送らない・新しいトークンで使える {usable}")
        # TestFlight の報告: キーを入れるボタン → 読む
        asc_key = ec.generate_private_key(ec.SECP256R1())
        asc_pem = asc_key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                        serialization.NoEncryption()).decode("ascii")
        issuer = "57246542-96fe-1a63-e053-0824d011072a"
        bad_issuer = client.call("POST", "/dash/ops/asc-key",
                                 json.dumps({"key_id": "ASCKEY0001", "issuer_id": "x", "p8": asc_pem}).encode(), dash, key=None)
        put = client.call("POST", "/dash/ops/asc-key",
                          json.dumps({"key_id": "ASCKEY0001", "issuer_id": issuer, "p8": asc_pem}).encode(), dash, key=None)
        fetched = wait_for(lambda: ops.O.feedback.checked is not None and not ops.O.feedback.running.locked(), 20)
        shot = home / "feedback" / "shot-1"
        crash = home / "feedback" / "crash-1"
        info = json.loads((shot / "info.json").read_text(encoding="utf-8")) if (shot / "info.json").exists() else {}
        api_calls = [r for r in FakeAsc.requests if r["path"].startswith("/v1/")]
        image_calls = [r for r in FakeAsc.requests if r["path"] == "/img/1.png"]
        token = (api_calls[0]["auth"] or "").removeprefix("Bearer ") if api_calls else ""
        head, claims, signed = check_jwt(token, asc_key.public_key()) if token else ({}, {}, False)
        ok = bad_issuer[0] == 400 and put[0] == 200 and fetched and ops.O.feedback.error is None \
            and (shot / "screenshot-1.png").read_bytes() == PNG and "email" not in info and info.get("build") == "154" \
            and (crash / "crash.txt").read_text(encoding="utf-8").startswith("Incident") \
            and head == {"alg": "ES256", "kid": "ASCKEY0001", "typ": "JWT"} and claims.get("iss") == issuer \
            and claims.get("aud") == "appstoreconnect-v1" and 0 < claims.get("exp", 0) - claims.get("iat", 0) <= 1200 \
            and signed and image_calls and image_calls[0]["auth"] is None \
            and api_calls[0]["query"].get("filter[bundleId]") == [ascfeedback.BUNDLE_ID] \
            and any(r["path"].endswith("/betaFeedbackScreenshotSubmissions") and r["query"].get("include") == ["build"]
                    for r in api_calls)
        failed += say(ok, f"TestFlight の報告: キーのボタン {put[0]}（issuer が違えば {bad_issuer[0]}）・"
                          f"スクショ {(shot / 'screenshot-1.png').exists()}・落ちた記録 {(crash / 'crash.txt').exists()}・"
                          f"JWT {head} aud {claims.get('aud')} 署名 {signed}・画像には JWT を付けない")
        second = ops.O.feedback.fetch()
        ok = second["new"] == 0 and len(ops.O.feedback.items) == 2 \
            and any("新しいものが 2 件" in m for m in logged)
        failed += say(ok, f"もう一度読んでも同じものは増えない: {second}")
        # 見守りの画面
        page = client.call("GET", "/dash", headers=BASIC, key=None)
        html = page[1] if isinstance(page[1], str) else ""
        detail = client.call("GET", "/dash/ops/feedback?id=shot-1", headers=BASIC, key=None)
        image = client.call("GET", "/dash/ops/feedback-file?id=shot-1&name=screenshot-1.png", headers=BASIC, key=None)
        other = client.call("GET", "/dash/ops/feedback-file?id=shot-1&name=info.json", headers=BASIC, key=None)
        unknown = client.call("GET", "/dash/ops/feedback?id=nothing", headers=BASIC, key=None)
        locked = client.call("GET", "/dash/ops/feedback?id=shot-1", key=None)
        keys = client.call("GET", "/dash/ops/keys", headers=BASIC, key=None)
        ok = page[0] == 200 and all(s in html for s in ("実機の様子", "見えない通知", "TestFlight の報告", "学び直しと GPU の時間割",
                                                        "テスト通知を送る", "iPhone（iPhone17,1・6F1C）", "秘密のコメント"[:2])) \
            and "src=" not in html and "http://" not in html and "https://" not in html \
            and "default-src 'none'" in page[2].get("content-security-policy", "") \
            and detail[0] == 200 and "img-src 'self'" in detail[2].get("content-security-policy", "") \
            and "/dash/ops/feedback-file?id=shot-1&amp;name=screenshot-1.png" in str(detail[1]) \
            and image[0] == 200 and image[1] == PNG and image[2].get("content-type") == "image/png" \
            and other[0] == 404 and unknown[0] == 404 and locked[0] == 401 and keys[0] == 200 and "通知の鍵を入れる" in str(keys[1])
        failed += say(ok, f"見守りの画面: /dash {page[0]}（{len(html)} 文字）・詳しい画面 {detail[0]}・スクショ {image[0]}・"
                          f"報告に無いファイル {other[0]}・知らない報告 {unknown[0]}・合言葉なし {locked[0]}・鍵の画面 {keys[0]}")
        # /train-status の auto・summary.md・ops の裏の仕事（1回）
        status = client.call("GET", "/train-status")
        ops.step(clock())
        summary = (home / "diag" / "summary.md").read_text(encoding="utf-8")
        ok = status[0] == 200 and isinstance(status[1].get("auto"), dict) and "next" in status[1]["auto"] \
            and status[1]["auto"]["count"] == 12 and "TestFlight の報告" in summary and "秘密のコメントです" in summary \
            and "AuthKey_TESTKEY123" in summary and "学び直し" in summary
        failed += say(ok, f"/train-status の auto: {status[1].get('auto', {}).get('state') if status[0] == 200 else status}・"
                          "summary.md に TestFlight の報告・通知・学び直し")
        # 60 日たったら片づける
        clock.advance(61 * 86400)
        removed = ops.O.diag.prune()
        failed += say(removed >= 1 and not folder.exists() and ops.O.diag.devices() == [],
                      f"60 日より長く届いていない端末のものは片づける（{removed} 個）")
        # 記録には中身を書かない
        failed += say(not any("秘密" in m for m in logged), "記録（log.txt）に、自己点検の値や TestFlight のコメントを書かない")
    finally:
        ops.stop()
        server.shutdown()
        server.server_close()
        asc.shutdown()
        asc.server_close()
        ollama.shutdown()
        ollama.server_close()
        push.close()
    return failed
