"""LifeLog PC 版 7（ops）: 実機の様子・TestFlight の報告・見えない通知・学び直しと GPU の時間割を、lifelog_pc.py につなぐ。

中身はそれぞれ diag.py・ascfeedback.py・apns.py・trainer.py・gpu.py。ここは、それらを始めて、決まった時刻に動かす所。
lifelog_pc.py から呼ぶのは次だけ（どれも start() の前に呼ばれたら何もしない。--check-vote のときなど）:
- configure(...)                  main() が、モデルを作り直すのに要る設定を渡す
- start(main)                     受け付けを始めるときに、版 7 の裏の仕事を始める
- seen(handler)                   合言葉の合った受け付けのたび（iPhone から最後に来た時刻・仕事が来たこと）
- http_diag(handler, length)      POST /diag
- dash_get(handler, url)・dash_post(handler, url)   見守りの画面の /dash/ops/…（TestFlight の報告の詳しい画面・鍵を入れるボタンなど）
- features()・train_auto()・dash_info()・busy()
裏の仕事（15 秒ごと）: GPU の時間割・1 分ごとに学び直しの見回りと毎日 3:30 の nightly・10 分ごとに通知の見回りと summary.md・
6 時間ごとに TestFlight の報告。
"""

from __future__ import annotations

import collections
import contextlib
import json
import os
import threading
import time
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import apns
import ascfeedback
import dashboard
import diag
import gpu
import trainer

POSTS = ("/diag",)
TICK = 15.0
PATROL = 600.0
SILENT = 30 * 60             # 録音中なのに、その端末からこれだけ何も来なければ wake
DASH_BODY = 64_000


class O:
    """版 7 の部品をまとめておく所（start() で作る）"""

    started = False
    main = None
    home: Path = Path(".")
    clock = staticmethod(time.time)
    diag: diag.DiagStore
    pusher: apns.Pusher
    feedback: ascfeedback.Feedback
    gpu: gpu.GpuPlan
    trainer: trainer.AutoTrainer
    ollama: gpu.Ollama | None = None
    settings: dict = {"names": ["haas", "reazon", "whisper", "kotoba", "mine"], "whisper": "auto", "device": "auto",
                      "threads": 4, "fake": False}
    last_seen = 0.0
    seen_ip: dict[str, float] = {}
    job_ip: collections.OrderedDict = collections.OrderedDict()
    summary_lock = threading.Lock()
    started_at = 0.0
    next_minute = 0.0
    next_patrol = 0.0
    next_feedback = 0.0
    nightly_day: str | None = None
    thread: threading.Thread | None = None
    stopping = False


def log(message: str) -> None:
    """lifelog_pc.log に書く（確かめのときに取り替えられても、取り替えたほうに書く）"""
    if O.main is not None:
        O.main.log(message)


def config() -> dict:
    """<home>/config.json（ふだんは lifelog_pc.CONFIG と同じもの）"""
    try:
        value = json.loads((O.home / "config.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def configure(names: list[str] | None = None, whisper: str | None = None, device: str | None = None,
              threads: int | None = None, fake: bool | None = None) -> None:
    for key, value in (("names", names), ("whisper", whisper), ("device", device), ("threads", threads),
                       ("fake", fake)):
        if value is not None:
            O.settings[key] = value


# MARK: - 作り物のモデル（--fake-models。モデルを読み込まずに、受け口と画面と GPU の時間割を試す）


class FakeEngine:
    def __init__(self, name: str, provider: str = "cpu") -> None:
        self.name = name
        self.label = f"作り物の {name}"
        self.provider = provider
        self.lock = threading.Lock()
        self.model = object()
        # 本物と同じく、GPU の作り物は gpu.GPU_LOCK で1度に1つだけ動く
        self.gpu_lock = gpu.GPU_LOCK if provider == "cuda" else None
        self.compute = "作り物"
        if provider == "cuda":
            # 本物と同じく、GPU の作り物が載っているあいだは、この PC の Ollama を CPU だけで動かす（num_gpu 0）
            gpu.register(self)

    def run(self, audio, segments, hints, prompt):
        with self.lock, (self.gpu_lock or contextlib.nullcontext()):
            # 版 8: 試すときだけ、環境変数 LIFELOG_FAKE_SECONDS で GPU の作り物（whisper・kotoba）を遅くできる
            # （待ち合わせの空白・下書きが先に出ることを、起動して確かめるため。GPU の作り物どうしは順に動く）
            if self.provider == "cuda":
                try:
                    time.sleep(max(0.0, min(600.0, float(os.environ.get("LIFELOG_FAKE_SECONDS") or 0))))
                except ValueError:
                    pass
            return ["作り物の文です" if self.model is not None else "" for _ in segments]


def fake_engines() -> list:
    return [FakeEngine("haas"), FakeEngine("reazon"), FakeEngine("whisper", "cuda"), FakeEngine("kotoba", "cuda")]


def build_engine(name: str):
    """GPU の時間割で、下ろしたモデルを作り直す（読み込むのは lifelog_pc の WhisperEngine など）"""
    if O.settings.get("fake"):
        time.sleep(1.0)
        return FakeEngine(name, "cuda")
    main = O.main
    kinds = {"whisper": main.WhisperEngine, "kotoba": main.KotobaEngine, "mine": main.MineEngine}
    # GPU に載せられないときは CPU で読み込まない（CPU に落ちたものは使わないので。2026-11-07）
    return kinds[name](O.settings["whisper"], O.settings["device"], int(O.settings["threads"]), gpu_only=True)


# MARK: - 始める


def start(main, home: Path | None = None, background: bool = True, clock=None, apns_hosts: dict | None = None,
          apns_post=None, asc_base: str | None = None, asc_opener=None, ollama_url: str | None = None,
          has_gpu=None, runtime=None, python=None, free_mb=None, count_samples=None) -> None:
    """版 7 の部品を作って、裏の仕事を始める。どれかが失敗しても、受け付けは続ける。"""
    O.main = main
    O.home = Path(home or main.HOME)
    O.clock = clock or time.time
    O.last_seen = 0.0
    O.seen_ip = {}
    O.job_ip = collections.OrderedDict()
    O.nightly_day = None
    O.stopping = False
    O.diag = diag.DiagStore(O.home / "diag", log, O.clock)
    O.pusher = apns.Pusher(O.home / "apns", log, O.clock, hosts=apns_hosts, post=apns_post)
    O.feedback = ascfeedback.Feedback(O.home, log, O.clock, base=asc_base or ascfeedback.BASE, opener=asc_opener)
    fake = bool(O.settings.get("fake"))
    # 戻す前に要る GPU の空き: config.json の whisper_compute と gpu_free_min_mb で決める（2026-11-07）
    O.gpu = gpu.GpuPlan(lambda: main.Handler.engine, build_engine, log, O.clock,
                        free_mb=free_mb or ((lambda: None) if fake else None),
                        need_mb=lambda name: gpu.need_with_spare(name, config()))
    # 空きが足りないので起動のときに GPU に載せなかったもの（kotoba など）は、空きができたら GPU の時間割が載せる
    for name in gpu.take_skipped():
        O.gpu.want(name)
        log(f"GPU の時間割: {name} は、GPU の空きができたら載せます")
    try:
        # 学び直しのあとに載せ直すときも、GPU の文字起こしのモデルが載っていれば CPU だけで（num_gpu 0）
        O.ollama = gpu.Ollama(ollama_url or getattr(getattr(main, "LLM", None), "url", None) or gpu.OLLAMA_URL, log,
                              options=lambda: gpu.ollama_options(config()))
    except ValueError:
        O.ollama = None
    data = O.home / "personal" / "data"
    O.trainer = trainer.AutoTrainer(
        O.home, main.INSTALL_DIR, log, gpu_plan=O.gpu, ollama=O.ollama,
        count_samples=count_samples or (lambda: len(main.read_samples(data))),
        is_idle=idle, has_gpu=has_gpu or main.has_nvidia_gpu, on_improved=improved,
        runtime=runtime or trainer.Runtime(O.home, main.INSTALL_DIR, log, drop_paths=[O.home / "cuda"]),
        clock=O.clock, python=python)
    settings = config()
    O.trainer.configure(settings)
    O.gpu.night = gpu.night_config(settings)
    if getattr(main.App, "jobs", None) is not None:
        main.App.jobs.on_done = job_done
    now = O.clock()
    O.started_at = now
    O.next_minute = now + 30
    O.next_patrol = now + 60
    O.next_feedback = now + ascfeedback.FIRST
    O.started = True
    if background:
        O.thread = threading.Thread(target=loop, name="ops", daemon=True)
        O.thread.start()
    log("版 7 の見守り（実機の様子・通知・TestFlight の報告・学び直しと GPU の時間割）を始めました")


def stop() -> None:
    """確かめのあとに、元に戻す"""
    O.stopping = True
    O.started = False
    if O.main is not None and getattr(O.main.App, "jobs", None) is not None \
            and getattr(O.main.App.jobs, "on_done", None) is job_done:
        O.main.App.jobs.on_done = None


def loop() -> None:
    failed_at = 0.0
    while not O.stopping:
        try:
            step()
        except Exception as error:  # noqa: BLE001 — 裏の仕事は止めない
            if time.time() - failed_at > 3600:
                failed_at = time.time()
                log(f"版 7 の裏の仕事でつまずきました: {error!r}")
        time.sleep(TICK)


def working() -> bool:
    """文字にしている最中・待っている仕事があるか"""
    main = O.main
    jobs = getattr(main.App, "jobs", None)
    queued = 0
    if jobs is not None:
        try:
            queued = jobs.counts().get("queued", 0)
        except Exception:  # noqa: BLE001
            queued = 0
    return main.App.transcribing > 0 or (jobs is not None and jobs.busy()) or queued > 0


def idle() -> bool:
    return not working()


def step(now: float | None = None) -> None:
    """15 秒ごとの裏の仕事"""
    if not O.started:
        return
    now = O.clock() if now is None else now
    settings = config()
    O.gpu.tick(working(), settings)
    gpu.note_change()  # 捨てられて GPU から下りたモデルがあれば、gpu-state.json（MCP サーバーが読む）を書き直す
    if now >= O.next_minute:
        O.next_minute = now + 60
        O.trainer.configure(settings)
        O.trainer.tick()
        nightly(now, settings)
    if now >= O.next_patrol:
        O.next_patrol = now + PATROL
        patrol(now, settings)
        write_summary(now)
    if now >= O.next_feedback:
        O.next_feedback = now + ascfeedback.EVERY
        if settings.get("testflight") is not False and O.feedback.configured():
            threading.Thread(target=fetch_feedback, name="testflight", daemon=True).start()


def improved() -> None:
    """学び直しで mine が入れ替わった。戻すときに新しい mine を読み込む（mine を使う設定のときだけ）"""
    names = O.settings.get("names") or []
    if "mine" in names and O.settings.get("whisper") != "off":
        O.gpu.want("mine")


def busy() -> bool:
    """学び直している最中か（このあいだは、自分で入れ替えるのを待つ）"""
    return O.started and O.trainer.running


# MARK: - iPhone からの受け付け


def seen(handler) -> None:
    """合言葉の合った受け付けのたびに呼ぶ（iPhone から最後に来た時刻と、仕事が来たこと）"""
    if not O.started:
        return
    try:
        ip = handler.client_address[0]
        now = O.clock()
        O.last_seen = now
        O.seen_ip[ip] = now
        url = urlparse(handler.path)
        if handler.command == "POST" and url.path in ("/transcribe", "/jobs"):
            O.gpu.note_work()
            if url.path == "/jobs":
                name = (parse_qs(url.query).get("name") or [""])[0]
                if name:
                    O.job_ip[name] = ip
                    while len(O.job_ip) > 2000:
                        O.job_ip.popitem(last=False)
    except Exception:  # noqa: BLE001 — 見守りのための記録なので、失敗しても受け付けは続ける
        pass


def note_watch() -> None:
    """版 10: 時計の外の道から仕事を預かった（127.0.0.1 から届くので seen は呼ばない。iPhone の最後に来た時刻も変えない）。
    夜の割り当てで GPU のモデルを下ろしていれば戻す"""
    if O.started:
        O.gpu.note_work()


def job_done(name: str, meta: dict) -> None:
    """後で受け取る文字起こしが1つ終わった（jobqueue から呼ばれる）。でき上がったら、その端末に job の通知。
    版 8: 待ち合わせ（wait=1）の答えで iPhone に渡した仕事（"handed"）には送らない（渡せなかったときの保険）
    版 10: 時計の外の道から預かった仕事（"origin": "watch"）は、送ってきた iPhone の宛先が無いので、通知を登録した端末の全部に
    送る（中身に仕事の名前。iPhone が同じ名前を wait=1 で送って受け取っていれば handed なので送らない）"""
    if not O.started or meta.get("status") != "done" or meta.get("handed") or not O.pusher.ready():
        return
    if config().get("push") is False:
        return
    device = O.diag.device_for_ip(O.job_ip.get(name))
    devices = [device] if device and O.pusher.usable(device) else None
    threading.Thread(target=O.pusher.send, args=("job", devices, name), name="push-job", daemon=True).start()


def http_diag(handler, length: int) -> None:
    """POST /diag（合言葉は確かめてある）"""
    if not O.started:
        handler.discard_body()
        handler.send_json(503, {"error": "実機の様子は今は受け付けていません"})
        return
    if length <= 0 or length > diag.BODY_LIMIT:
        handler.discard_body()
        handler.send_json(400 if length <= 0 else 413,
                          {"error": "中身がありません" if length <= 0 else "大きすぎます（2MB まで）"})
        return
    data = handler.rfile.read(length)
    try:
        body = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        handler.send_json(400, {"error": "中身が JSON ではありません"})
        return
    try:
        record = O.diag.receive(body, handler.client_address[0])
    except ValueError as error:
        handler.send_json(400, {"error": str(error)})
        return
    except Exception as error:  # noqa: BLE001 — 何があっても受け付けは続ける
        log(f"実機の様子を置けませんでした: {error!r}")
        handler.send_json(500, {"error": f"実機の様子を置けませんでした: {error}"})
        return
    try:
        O.pusher.register(record["deviceID"], body.get("push"), record.get("device"), record.get("model"))
    except Exception as error:  # noqa: BLE001
        log(f"通知の登録を覚えられませんでした: {error!r}")
    found = diag.concerns(record, O.clock())
    # 行の中身は記録に書かない（数だけ）
    log(f"実機の様子: {diag.label(record)}（build {record.get('build') or '—'}・{record.get('install') or '—'}）から "
        f"自己点検 {len(record.get('rows') or [])} 行・落ちた記録 {len(record.get('crashes') or [])}・"
        f"MetricKit {len(record.get('metrickit') or [])}" + (f"・気になる所 {len(found)}" if found else ""))
    write_summary()
    handler.send_json(200, {"ok": True})


# MARK: - 見回り（通知）


def last_contact(record: dict, received: float) -> float:
    """その端末から最後に何か来た時刻（/diag と、同じ宛先からの受け付け。宛先が分からなければ、どの受け口でも最後に来た時刻）"""
    ip = record.get("ip")
    other = O.seen_ip.get(ip) if ip else O.last_seen
    return max(received, other or 0.0)


def patrol(now: float, settings: dict | None = None) -> list[tuple[str, str]]:
    """10 分ごと: 録音中なのに 30 分なにも来ない端末に wake、3 時間 diag が来ない端末に diag。送ったもの（端末, 種類）を返す。"""
    settings = config() if settings is None else settings
    if settings.get("push") is False or not O.pusher.ready():
        return []
    sent = []
    for record in O.diag.devices():
        device = record.get("deviceID")
        received = diag.parse_time(record.get("receivedAt"))
        if not device or received is None or now - received > diag.RETIRED or not O.pusher.usable(device):
            continue
        state = record.get("state") if isinstance(record.get("state"), dict) else {}
        recording = state.get("phoneRecording") is True or state.get("watchRecording") is True
        wanted = []
        if now - received > diag.STALE:
            wanted.append("diag")
        if recording and now - last_contact(record, received) > SILENT:
            wanted.append("wake")
        for kind in wanted:
            if O.pusher.allowed(device, kind, now):
                result = O.pusher.send(kind, [device])
                if result and result[0].get("ok"):
                    sent.append((device, kind))
                break
    return sent


def nightly(now: float, settings: dict | None = None) -> list[str]:
    """毎日 3:30 に nightly（夜の処理がまだなら進めて）を、最近様子の届いた端末に1回だけ送る"""
    settings = config() if settings is None else settings
    local = time.localtime(now)
    today = time.strftime("%Y-%m-%d", local)
    if settings.get("push") is False or O.nightly_day == today or not ((3, 30) <= (local.tm_hour, local.tm_min) < (6, 0)):
        return []
    if not O.pusher.ready():
        return []
    O.nightly_day = today
    devices = [r["deviceID"] for r in O.diag.devices()
               if now - (diag.parse_time(r.get("receivedAt")) or 0) <= diag.RETIRED and O.pusher.usable(r["deviceID"])]
    if not devices:
        return []
    results = O.pusher.send("nightly", devices)
    return [r.get("device") for r in results if r.get("ok")]


def fetch_feedback() -> None:
    try:
        O.feedback.fetch()
    except Exception:  # noqa: BLE001 — 失敗は Feedback が記録に書く
        pass
    write_summary()


# MARK: - summary.md（この PC で動く Claude が読む）


def write_summary(now: float | None = None) -> Path | None:
    if not O.started:
        return None
    now = O.clock() if now is None else now
    worries, devices = O.diag.summary_lines(now)
    lines = ["# LifeLog の実機の様子（家の PC の LifeLog PC が書き直します）", "",
             f"書いた時刻: {time.strftime('%Y-%m-%d %H:%M', time.localtime(now))}（この PC の時刻）。"
             "iPhone が POST /diag で送った様子・TestFlight の報告・通知・学び直しの様子をまとめたものです。",
             f"もとのファイル: {O.home / 'diag'}（端末ごとの latest.json と日ごとの .jsonl）・{O.home / 'feedback'}", "",
             "## 気になる所", ""]
    lines.extend(worries or ["- 今は、気になる所はありません"])
    # 版 8: 文字になるまでの時間（PC で測った分。iPhone で測った分は端末ごとの「文字になるまでの時間」の行）
    lines += ["", "## 文字になるまでの時間（PC で測った分・直近 50 件のでき上がり）", ""]
    jobs = getattr(getattr(O.main, "App", None), "jobs", None)
    try:
        stats = jobs.latency() if jobs is not None else None
    except Exception:  # noqa: BLE001
        stats = None
    lines.extend(f"- {text}" for text in diag.pc_latency(stats))
    lines += ["", "## 端末ごと", ""]
    lines.extend(devices or ["（まだ様子が届いていません）", ""])
    lines += ["## TestFlight の報告（新しい 10 件）", ""]
    status = O.feedback.status()
    if not status["configured"]:
        lines.append("- App Store Connect のキーがまだありません（見守りの画面から入れられます）")
    else:
        lines.append(f"- 最後に読んだ: {diag.clock(status['checked'])}" + (f"・失敗: {status['error']}" if status["error"] else ""))
        for item in status["recent"]:
            kind = ascfeedback.KIND_LABEL.get(item.get("kind"), item.get("kind"))
            lines.append(f"- {diag.clock(diag.parse_time(item.get('created')))} {kind}・build {item.get('build') or '—'}・"
                         f"{item.get('device') or '—'}・iOS {item.get('os') or '—'}: {item.get('comment') or '（コメントなし）'}"
                         f"（{O.feedback.folder / str(item['id'])}）")
    lines += ["", "## 見えない通知", ""]
    push = O.pusher.status()
    lines.append(f"- 鍵: {('AuthKey_' + push['key_id']) if push['key_id'] else 'まだありません'}・チーム: {push['team'] or '—'}・"
                 f"HTTP/2 の部品: {'あり' if push['http2'] else 'なし'}" + (f"・最後の失敗: {push['last_error']}" if push["last_error"] else ""))
    for row in push["history"][-10:]:
        lines.append(f"- {diag.clock(row.get('at'))} {row.get('kind')} → {row.get('status')}" + (f" {row['reason']}" if row.get("reason") else ""))
    lines += ["", "## 学び直しと GPU の時間割", ""]
    auto = O.trainer.status()
    last = auto.get("last") or {}
    lines.append(f"- 自動の学び直し: {auto['state']}・時間帯 {auto['window']}・次 {diag.clock(diag.parse_time(auto['next']))}・"
                 f"材料 {auto['count']} 個（前回から +{auto['since_last']}）・部品 {auto['runtime']}")
    if last:
        lines.append(f"- 前回: {diag.clock(diag.parse_time(last.get('at')))} {trainer.AutoTrainer.result_line(last)}")
    plan = O.gpu.status()
    lines.append(f"- GPU: {plan['text']}" + (f"（下ろしているもの {'・'.join(plan['down'])}）" if plan["down"] else ""))
    text = "\n".join(lines) + "\n"
    path = O.home / "diag" / "summary.md"
    with O.summary_lock:
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            part = path.with_name(path.name + ".part")
            part.write_text(text, encoding="utf-8")
            part.replace(path)
        except OSError as error:
            log(f"summary.md を書けませんでした: {error!r}")
            return None
    return path


# MARK: - features・/train-status・見守りの画面


def features() -> list[str]:
    if not O.started:
        return []
    found = ["diag"]
    try:
        if config().get("push") is not False and O.pusher.ready():
            found.append("push")
        if O.trainer.available():
            found.append("autotrain")
    except Exception:  # noqa: BLE001
        pass
    return found


def train_auto() -> dict | None:
    """/train-status の "auto"（自動の学び直しの様子）。始めていなければ None"""
    if not O.started:
        return None
    return O.trainer.status()


def dash_info() -> dict:
    """見守りの画面の版 7 の節に出すもの（文字起こしの文の中身は入れない）"""
    if not O.started:
        return {}
    now = O.clock()
    devices = []
    for record in O.diag.devices():
        received = diag.parse_time(record.get("receivedAt"))
        devices.append({"label": diag.label(record), "record": record, "received": received,
                        "concerns": diag.concerns(record, now), "state": diag.state_lines(record),
                        "old": received is not None and now - received > diag.RETIRED})
    memory = gpu.gpu_memory() if not O.settings.get("fake") and O.trainer.has_gpu() else None
    return {"now": now, "devices": devices, "push": O.pusher.status(), "feedback": O.feedback.status(),
            "train": O.trainer.status(), "gpu": dict(O.gpu.status(), memory=memory),
            "summary": str(O.home / "diag" / "summary.md")}


def _auth(handler, url) -> bool:
    ok, set_cookie = dashboard.check(handler.headers, url.query, handler.key)
    if not ok:
        handler.discard_body()
        dashboard.send(handler, 401, dashboard.login_page(),
                       extra={"WWW-Authenticate": 'Basic realm="LifeLog PC", charset="UTF-8"'})
    return ok


def dash_get(handler, url) -> None:
    """GET /dash/ops/keys（鍵を入れる画面）・/dash/ops/feedback?id=…（TestFlight の報告の詳しい画面）・
    /dash/ops/feedback-file?id=…&name=…（スクショ）"""
    if not _auth(handler, url):
        return
    if not O.started:
        dashboard.send_json(handler, 503, {"error": "版 7 の見守りが動いていません"})
        return
    if url.path == "/dash/ops/keys":
        dashboard.send(handler, 200, dashboard.keys_page(O.pusher.status(), O.feedback.status()))
        return
    query = parse_qs(url.query)
    sid = (query.get("id") or [""])[0]
    found = O.feedback.item(sid)
    if found is None:
        dashboard.send_json(handler, 404, {"error": "その報告はありません"})
        return
    info, folder = found
    if url.path == "/dash/ops/feedback":
        crash = None
        if info.get("crash"):
            try:
                crash = (folder / "crash.txt").read_text(encoding="utf-8", errors="replace")[:400_000]
            except OSError:
                crash = None
        page = dashboard.feedback_page(info, crash)
        dashboard.send(handler, 200, page, extra={"Content-Security-Policy": dashboard.FEEDBACK_CSP})
        return
    name = (query.get("name") or [""])[0]
    if url.path != "/dash/ops/feedback-file" or name not in (info.get("files") or []):
        dashboard.send_json(handler, 404, {"error": "そのファイルはありません"})
        return
    try:
        data = (folder / name).read_bytes()
    except OSError:
        dashboard.send_json(handler, 404, {"error": "そのファイルはありません"})
        return
    kind = {"jpg": "image/jpeg", "png": "image/png", "heic": "image/heic", "webp": "image/webp"}.get(
        name.rsplit(".", 1)[-1], "application/octet-stream")
    handler.send_response(200)
    handler.send_header("Content-Type", kind)
    handler.send_header("Content-Length", str(len(data)))
    for key, value in dashboard.SECURITY_HEADERS.items():
        handler.send_header(key, value)
    handler.end_headers()
    handler.wfile.write(data)


def _read_body(handler) -> dict | None:
    try:
        length = int(handler.headers.get("Content-Length") or 0)
    except ValueError:
        length = 0
    if length > DASH_BODY:
        handler.discard_body()
        dashboard.send_json(handler, 413, {"error": "大きすぎます"})
        return None
    data = handler.rfile.read(length) if length > 0 else b"{}"
    try:
        body = json.loads(data.decode("utf-8") or "{}")
    except (UnicodeDecodeError, ValueError):
        dashboard.send_json(handler, 400, {"error": "中身が JSON ではありません"})
        return None
    if not isinstance(body, dict):
        dashboard.send_json(handler, 400, {"error": "中身が JSON ではありません"})
        return None
    return body


def dash_post(handler, url) -> None:
    """見守りの画面のボタン: 通知の鍵を入れる・テスト通知を送る・App Store Connect のキーを入れる・TestFlight の報告を今すぐ読む"""
    if not _auth(handler, url):
        return
    if handler.headers.get(dashboard.HEADER) != "1":
        handler.discard_body()
        dashboard.send_json(handler, 403, {"error": "この画面のボタンから押してください"})
        return
    if not O.started:
        handler.discard_body()
        dashboard.send_json(handler, 503, {"error": "版 7 の見守りが動いていません"})
        return
    body = _read_body(handler)
    if body is None:
        return
    path = url.path
    try:
        if path == "/dash/ops/apns-key":
            saved = apns.save_key(O.home / "apns", str(body.get("key_id") or ""), str(body.get("p8") or ""))
            team = str(body.get("team") or "").strip()
            if team:
                O.pusher.set_team(team)
            log(f"通知の鍵を見守りの画面から入れました（{saved.name}）")
            message = f"通知の鍵を入れました（{saved.name}）。"
            message += f"チームの ID は {O.pusher.team_for()} を使います。" if O.pusher.team_for() else \
                "チームの ID は、iPhone の LifeLog が様子を送ってくると分かります（ここで入れることもできます）。"
            dashboard.send_json(handler, 200, {"message": message})
        elif path == "/dash/ops/apns-test":
            results = O.pusher.send("test")
            if results and results[0].get("reason") == "鍵がありません":
                text = "通知の鍵がありません。下の「通知の鍵を入れる」から入れてください（送っていません）。"
            elif results and results[0].get("reason") == "通知を登録した端末がありません":
                text = "通知を登録した端末がありません。iPhone の LifeLog を開くと登録されます（送っていません）。"
            else:
                parts = [("届けました" if r.get("ok") else f"送れませんでした（{r.get('status') or ''} {r.get('reason') or ''}）")
                         for r in results]
                text = "テスト通知: " + "・".join(parts)
            dashboard.send_json(handler, 200, {"message": text})
        elif path == "/dash/ops/asc-key":
            saved = ascfeedback.save_key(O.home / "asc", str(body.get("key_id") or ""), str(body.get("issuer_id") or ""),
                                         str(body.get("p8") or ""))
            log(f"App Store Connect のキーを見守りの画面から入れました（{saved.name}）")
            threading.Thread(target=fetch_feedback, name="testflight-now", daemon=True).start()
            dashboard.send_json(handler, 200, {"message": f"キーを入れました（{saved.name}）。TestFlight の報告を読み始めました。"
                                                          "少したってから画面を開き直してください。"})
        elif path == "/dash/ops/asc-fetch":
            if not O.feedback.configured():
                dashboard.send_json(handler, 200, {"message": "App Store Connect のキーがありません。下から入れてください。"})
                return
            threading.Thread(target=fetch_feedback, name="testflight-now", daemon=True).start()
            dashboard.send_json(handler, 200, {"message": "TestFlight の報告を読み始めました。少したってから画面を開き直してください。"})
        else:
            dashboard.send_json(handler, 404, {"error": "not found"})
    except ValueError as error:
        dashboard.send_json(handler, 400, {"error": str(error)})
    except Exception as error:  # noqa: BLE001 — 何があっても受け付けは続ける
        log(f"見守りの画面のボタンでつまずきました: {error!r}")
        dashboard.send_json(handler, 500, {"error": f"うまくいきませんでした: {error}"})
