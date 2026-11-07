"""LifeLog PC 版 7: GPU の時間割（文字起こしの GPU のモデルを下ろす・戻す）と、この PC の Ollama のモデルを下ろす・戻す。

決まりは docs/v7-plan.md の「4. 学び直しと GPU の時間割」。
- 昼は、文字起こしのモデル（whisper・kotoba・mine）が GPU に載っている。
- 夜（初めは 1:00〜6:00。config.json の "gpu_night" で変えられる）に30分仕事が無ければ、GPU のモデルを下ろし、
  CPU のモデル（haas・reazon）だけで受ける。言語モデル（Ollama）と学び直しに GPU を空けるため。
- 学び直しのあいだも下ろす（hold("train")）。そのあいだは、仕事が来ても戻さない。
- 仕事が来たら戻す（戻るまでは CPU で受ける）。戻すときに GPU に載らなかったもの（CPU に落ちたもの）は使わず、
  5 分おいてやり直す。
ここには文字にする仕組みは無い。ops.py が、今の Ensemble を返す get_ensemble と、モデルを作り直す build を渡す。

GPU のメモリーに余裕を作る（2026-11-07。8GB の GPU に large-v3 と kotoba を float16 で載せると、空きが約 600MB だった）:
- 合計 10GB 未満の GPU では、Whisper の重みを 8 ビット（int8_float16）にして載せる（compute_for。"whisper_compute"）
- GPU に文字起こしのモデルが載っている（読み込み中も）あいだは、この PC の Ollama を CPU だけで動かす
  （ollama_options が {"num_gpu": 0} を返す。"ollama_gpu"）。夜の割り当てで下ろしているあいだは、今までどおり GPU を使ってよい
- 載せる前に GPU の空きを確かめ、動かすのに要る分と残しておく分（"gpu_free_min_mb"。初めは 1024MB）が無ければ載せない
"""

from __future__ import annotations

import contextlib
import gc
import json
import os
import subprocess
import threading
import time
import weakref
from pathlib import Path
from typing import Callable

GPU_NAMES = ("whisper", "kotoba", "mine")
ORDER = ["haas", "reazon", "whisper", "kotoba", "mine", "qwen"]
RETRY = 300.0                # 戻せなかったときに、やり直すまでの秒
SMI_EVERY = 30.0
OLLAMA_URL = "http://127.0.0.1:11434"
# 2026-11-07 11:22 に ctranslate2.dll の中で落ちた（0xc0000005）ことへの直し: GPU の文字起こしのモデル
# （whisper・kotoba・mine・qwen）は、この PC の中で1度に1つだけ動かす（読み込む・下ろすときも）。
# 持つ順は、いつも「モデルの lock → GPU_LOCK」（逆にしない。どこでも GPU_LOCK を持ったままモデルの lock を待たない）。
GPU_LOCK = threading.RLock()


def parse_clock(text, default: str) -> tuple[int, int]:
    """"02:00" → (2, 0)。おかしければ default"""
    for value in (text, default):
        try:
            hours, minutes = str(value).strip().split(":")
            h, m = int(hours), int(minutes)
            if 0 <= h <= 24 and 0 <= m < 60:
                return h, m
        except (ValueError, AttributeError):
            continue
    return 0, 0


def in_window(when: float, start: tuple[int, int], end: tuple[int, int]) -> bool:
    """この PC の時刻 when が、毎日の start〜end の間か（end が start より前なら日をまたぐ）"""
    local = time.localtime(when)
    minute = local.tm_hour * 60 + local.tm_min
    a, b = start[0] * 60 + start[1], end[0] * 60 + end[1]
    if a == b:
        return False
    return a <= minute < b if a < b else (minute >= a or minute < b)


def night_config(config: dict) -> dict | None:
    """config.json の "gpu_night"（false でやめる。{"start", "end", "idle_minutes"} で変える）"""
    value = config.get("gpu_night", True)
    if value is False:
        return None
    value = value if isinstance(value, dict) else {}
    try:
        idle = max(1.0, float(value.get("idle_minutes", 30))) * 60
    except (TypeError, ValueError):
        idle = 1800.0
    return {"start": parse_clock(value.get("start"), "01:00"), "end": parse_clock(value.get("end"), "06:00"),
            "idle": idle}


def gpu_memory(fresh: bool = False, cache: dict = {}) -> dict | None:  # noqa: B006 — 30 秒だけ覚えておく
    """nvidia-smi で GPU のメモリー（MB）を見る（{"used", "total", "free", "name"}）。見られなければ None。
    fresh なら、覚えておいたものを使わずに見直す（モデルを載せる前と後に測るとき）。"""
    now = time.time()
    if not fresh and cache.get("at") and now - cache["at"] < SMI_EVERY:
        return cache.get("value")
    value = None
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=memory.used,memory.total,memory.free,name",
                              "--format=csv,noheader,nounits"],
                             capture_output=True, text=True, timeout=10,
                             creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        first = (out.stdout or "").strip().splitlines()[0]
        used, total, free, name = [p.strip() for p in first.split(",", 3)]
        value = {"used": int(float(used)), "total": int(float(total)), "free": int(float(free)), "name": name}
    except (OSError, ValueError, IndexError, subprocess.SubprocessError):
        value = None
    cache.update(at=now, value=value)
    return value


# MARK: - GPU のメモリーに余裕を作る（2026-11-07）

SMALL_GPU_MB = 10 * 1024        # 合計がこれより少ない GPU では、Whisper の重みを 8 ビット（int8_float16）にする
COMPUTE_TYPES = ("float16", "int8_float16", "int8")   # config.json の "whisper_compute" に書けるもの（と auto）
# この GPU では速く動かせない形のときに、代わりに使う形（軽いものから）。CTranslate2 も自分で置き換えるが、
# float16 を使えない古い GPU（Compute Capability 6.1 など）では float32 になって重くなるので、8 ビットを先に選ぶ
FALLBACK = {"int8_float16": ("int8_float32", "int8", "float16"), "float16": ("int8_float16", "int8_float32", "int8"),
            "int8": ("int8_float32", "int8_float16")}
FREE_MIN_MB = 1024              # 載せたあとにも残しておく GPU の空き（config.json の "gpu_free_min_mb" で変えられる）
# 載せて動かすのに要る GPU のメモリー（MB のおおよそ）。whisper（large-v3）は faster-whisper の README の表
# （large-v2 を beam 5 で動かしたときの最大: float16 4525MB・int8 2926MB。CUDA の初めの分も入っている）から。
# 重みは int8_float16 で半分（約 3.1GB → 1.6GB）になるが、途中の計算（beam 5 の分の注意の写し、約 1.3GB）は
# float16 のまま。int8 は、float16 で保存したモデル（large-v3・kotoba・mine はどれもそう）では CTranslate2 が
# int8_float16 にする（src/types.cc の resolve_compute_type）ので同じ。int8_float32 は途中の計算が float32 になって重い。
# kotoba・mine（kotoba を学び直したもの）は重みが large-v3 の半分ほど（756M）。whisper のあとに載せるので、
# whisper がまだ使っていない途中の計算の分（約 1.3GB。int8_float32 では約 2.5GB）も足しておく
NEED_MB = {"whisper": {"float16": 4500, "int8_float16": 2900, "int8": 2900, "int8_float32": 4500, "float32": 8800},
           "kotoba": {"float16": 2800, "int8_float16": 2100, "int8": 2100, "int8_float32": 3300, "float32": 5500},
           "mine": {"float16": 2800, "int8_float16": 2100, "int8": 2100, "int8_float32": 3300, "float32": 5500}}


def compute_for(config: dict | None, total_mb: int | None, supported: set[str] | None = None) -> tuple[str, str]:
    """GPU に Whisper（large-v3・kotoba・mine）を載せる形（CTranslate2 の compute_type）と、そう決めた理由。
    config.json の "whisper_compute": "auto"（既定）・"float16"・"int8_float16"・"int8"。
    auto は、GPU のメモリーが合計 10GB 未満（か分からない）なら int8_float16、それ以上なら float16。
    supported（この GPU で速く動かせる形）に無ければ、FALLBACK から選び直す。"""
    raw = (config or {}).get("whisper_compute", "auto")
    wanted = raw.strip().lower() if isinstance(raw, str) else "auto"
    note = ""
    if wanted not in ("auto", *COMPUTE_TYPES):
        note = f"（config.json の whisper_compute「{raw}」は使えないので auto にしました）"
        wanted = "auto"
    if wanted != "auto":
        compute, why = wanted, "config.json の whisper_compute で決めた形"
    elif total_mb is None:
        compute, why = "int8_float16", "GPU のメモリーの合計が分からないので、軽いほうの形"
    elif total_mb < SMALL_GPU_MB:
        compute, why = "int8_float16", f"GPU のメモリーが合計 {total_mb} MB（10GB 未満）なので、重みを 8 ビットにした形"
    else:
        compute, why = "float16", f"GPU のメモリーが合計 {total_mb} MB あるので、今までどおりの形"
    if supported and compute not in supported:
        other = next((c for c in FALLBACK.get(compute, ()) if c in supported), None)
        if other:
            why += f"。この GPU は {compute} を速く動かせないので {other} にしました"
            compute = other
    return compute, why + note


def need_mb(name: str, compute: str) -> int:
    """name を compute の形で GPU に載せて動かすのに要る、おおよその MB（分からないモデルは 0）"""
    table = NEED_MB.get(name)
    if not table:
        return 0
    return int(table.get(compute, table["float16"]))


def free_min_mb(config: dict | None) -> int:
    """載せたあとにも残しておく GPU の空き（config.json の "gpu_free_min_mb"。おかしければ 1024）"""
    value = (config or {}).get("gpu_free_min_mb", FREE_MIN_MB)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return FREE_MIN_MB
    return int(min(65536, max(0, value)))


def need_with_spare(name: str, config: dict | None, total_mb: int | None = None) -> int:
    """name を、今の設定の形で GPU に載せるのに要る空き（動かす分と残しておく分）。GPU の時間割が戻す前に使う"""
    if total_mb is None:
        memory = gpu_memory()
        total_mb = memory["total"] if memory else None
    return need_mb(name, compute_for(config, total_mb)[0]) + free_min_mb(config)


# MARK: - GPU に文字起こしのモデルが載っているか（この PC の Ollama を GPU に載せないため）
# GPU に載せたモデル（WhisperEngine・QwenEngine・--fake-models の GPU の作り物）を覚えておく。捨てられたモデルは自然に忘れ、
# free_engine で下ろしたもの（model が None）は数えない。読み込んでいる最中（loading）も「載っている」とみなす。

_ON_GPU: weakref.WeakSet = weakref.WeakSet()
_LOADING: dict[str, int] = {}
_state_lock = threading.Lock()
_write_lock = threading.Lock()
_written: tuple | None = None
STATE_FILE = "gpu-state.json"
# lifelog_pc.main() が、受け付けを始めるときに <home>/gpu-state.json にする（別のプロセスの MCP サーバーが読む）。
# 確かめ・--test・--fake-models のときは None（何も書かない）
STATE_PATH: Path | None = None
# lifelog_pc.main() が入れる口（確かめ・--fake-models のときは無い = 何もしない）
BEFORE_LOAD: Callable[[], None] | None = None   # GPU に載せる前に、LifeLog が使う Ollama のモデルを GPU から下ろす
AFTER_NIGHT: Callable[[], None] | None = None   # 夜の割り当てで下ろしたあと、CPU に載っていた Ollama のモデルを下ろす
_SKIPPED: list[str] = []      # 空きが足りないので起動のときに GPU に載せなかったもの（GPU の時間割があとで載せ直す）


def register(engine) -> None:
    """GPU に載せた文字起こしのモデルを覚える"""
    with _state_lock:
        _ON_GPU.add(engine)
    note_change()


@contextlib.contextmanager
def loading(name: str):
    """GPU に読み込んでいる最中（この間も、Ollama は CPU だけで動かす）"""
    with _state_lock:
        _LOADING[name] = _LOADING.get(name, 0) + 1
    note_change()
    try:
        yield
    finally:
        with _state_lock:
            _LOADING[name] -= 1
            if _LOADING[name] <= 0:
                del _LOADING[name]
        note_change()


def asr_state() -> dict:
    """{"on": GPU に文字起こしのモデルが載っているか（読み込み中も）, "names": 載っているもの, "loading": 読み込み中のもの}"""
    with _state_lock:
        names = sorted({str(getattr(e, "name", "?")) for e in list(_ON_GPU)
                        if getattr(e, "model", None) is not None and getattr(e, "provider", "") == "cuda"})
        busy = sorted(_LOADING)
    return {"on": bool(names or busy), "names": names, "loading": busy}


def asr_on_gpu() -> bool:
    return asr_state()["on"]


def skipped(name: str) -> None:
    """空きが足りないので、起動のときに name を GPU に載せなかった（ops.start が GPU の時間割に、あとで載せ直させる）"""
    with _state_lock:
        if name not in _SKIPPED:
            _SKIPPED.append(name)


def take_skipped() -> list[str]:
    with _state_lock:
        names = list(_SKIPPED)
        _SKIPPED.clear()
    return names


def note_change() -> None:
    """GPU に載っているかが変わったら、<home>/gpu-state.json を書き直す（STATE_PATH が無ければ何もしない）"""
    global _written
    path = STATE_PATH
    if path is None:
        return
    state = asr_state()
    key = (str(path), state["on"], tuple(state["names"]), tuple(state["loading"]))
    with _write_lock:
        if key == _written:
            return
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            part = path.with_name(path.name + ".part")
            part.write_text(json.dumps({"asr_gpu": state["on"], "names": state["names"], "loading": state["loading"],
                                        "pid": os.getpid(), "at": time.time()}), encoding="utf-8")
            part.replace(path)
            _written = key
        except OSError:
            pass


def ollama_gpu_mode(config: dict | None) -> str:
    """config.json の "ollama_gpu": "auto"（既定。GPU に文字起こしのモデルが載っているあいだだけ CPU）・
    "always" か true（今までどおり、いつも GPU を使ってよい）・"never" か false（いつも CPU だけ）"""
    value = (config or {}).get("ollama_gpu", "auto")
    if value is True or (isinstance(value, str) and value.strip().lower() in ("always", "gpu", "on")):
        return "always"
    if value is False or (isinstance(value, str) and value.strip().lower() in ("never", "cpu", "off")):
        return "never"
    return "auto"


def ollama_options(config: dict | None, on_gpu: bool | None = None) -> dict:
    """この PC の Ollama に頼むときに options へ足すもの。GPU に載せないときは {"num_gpu": 0}（Ollama は CPU だけで動かす。
    num_gpu は GPU に置く層の数で、0 なら GPU を使わない。読み込み済みのモデルの num_gpu と違えば、Ollama が読み込み直す）"""
    mode = ollama_gpu_mode(config)
    if mode == "always":
        return {}
    if mode == "never":
        return {"num_gpu": 0}
    return {"num_gpu": 0} if (asr_on_gpu() if on_gpu is None else on_gpu) else {}


def read_state(home: Path) -> dict:
    """別のプロセス（MCP サーバー）から、<home>/gpu-state.json を読む（無ければ空）"""
    try:
        value = json.loads((Path(home) / STATE_FILE).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def state_options(home: Path, config: dict | None) -> dict:
    """MCP サーバーが Ollama に頼むときの options の足し分（LifeLog PC が書いた gpu-state.json で決める）。
    LifeLog PC が落ちて gpu-state.json が古いまま残っても、CPU で動かすだけ（落ちない側）"""
    return ollama_options(config, on_gpu=read_state(home).get("asr_gpu") is True)


def ollama_text(config: dict | None) -> str:
    """見守りの画面に出す、この PC の Ollama の置き場所"""
    mode = ollama_gpu_mode(config)
    if mode == "always":
        return "いつも GPU を使ってよい設定です（config.json の ollama_gpu）"
    if mode == "never":
        return "いつも CPU だけで動かす設定です（config.json の ollama_gpu）"
    state = asr_state()
    if state["on"]:
        what = "・".join(state["names"]) + ("（読み込み中のものも）" if state["names"] and state["loading"] else "") \
            if state["names"] else "読み込み中のもの"
        return f"CPU だけ（GPU に文字起こしのモデル {what} があるので、num_gpu 0 で頼みます）"
    return "GPU を使ってよい（GPU に文字起こしのモデルが無いため）"


def make_room() -> None:
    """GPU に文字起こしのモデルを載せる前に呼ぶ（LifeLog が使う Ollama のモデルが GPU にいれば下ろす。口が無ければ何もしない）"""
    hook = BEFORE_LOAD
    if hook is not None:
        try:
            hook()
        except Exception:  # noqa: BLE001 — 下ろせなくても、空きを確かめてから載せる
            pass


class CrashGuard:
    """GPU のモデルで文字にしている最中に LifeLog PC が止まった（落ちた）ことを、次に起動したときに知る守り。
    文字にしている間だけ <home>/gpu-busy.json を置き、終わったら消す。起動したときに残っていれば、前は GPU を使っている
    最中に止まった。それが CRASH_WINDOW の間に CRASH_LIMIT 回あれば、この起動のあいだは GPU のモデルを使わない
    （CPU のモデルだけで受ける）。<home>/gpu-crashes.json を消すか、時間がたってから起動し直すと、また GPU を使う。"""

    LIMIT = 2
    WINDOW = 6 * 3600.0

    def __init__(self, home: Path, log: Callable[[str], None], clock: Callable[[], float] = time.time) -> None:
        self.busy_path = Path(home) / "gpu-busy.json"
        self.history_path = Path(home) / "gpu-crashes.json"
        self.log = log
        self.clock = clock
        self.lock = threading.Lock()
        self.count = 0
        self.safe = False
        self.crashes: list[float] = []

    def startup(self) -> bool:
        """起動したときに1回呼ぶ。GPU を使わないことにしたら True"""
        now = self.clock()
        try:
            history = json.loads(self.history_path.read_text(encoding="utf-8"))
            history = [float(t) for t in history if isinstance(t, (int, float))] if isinstance(history, list) else []
        except (OSError, ValueError):
            history = []
        if self.busy_path.exists():
            try:
                at = float(json.loads(self.busy_path.read_text(encoding="utf-8")).get("at") or now)
            except (OSError, ValueError, AttributeError, TypeError):
                at = now
            history.append(at)
            self.log("前の LifeLog PC は、GPU のモデルで文字にしている最中に止まりました（落ちた疑い）")
            try:
                self.busy_path.unlink()
            except OSError:
                pass
        self.crashes = [t for t in history if now - t < self.WINDOW]
        try:
            self.history_path.write_text(json.dumps(self.crashes), encoding="utf-8")
        except OSError:
            pass
        self.safe = len(self.crashes) >= self.LIMIT
        if self.safe:
            self.log(f"GPU のモデルで文字にしている最中に {len(self.crashes)} 回止まったので、この起動のあいだは GPU のモデルを"
                     f"使わず、CPU のモデルだけで文字にします（{self.history_path} を消して起動し直すと、また GPU を使います）")
        return self.safe

    def enter(self) -> None:
        with self.lock:
            self.count += 1
            if self.count == 1:
                try:
                    self.busy_path.write_text(json.dumps({"pid": os.getpid(), "at": self.clock()}), encoding="utf-8")
                except OSError:
                    pass

    def leave(self) -> None:
        with self.lock:
            self.count = max(0, self.count - 1)
            if self.count == 0:
                try:
                    self.busy_path.unlink()
                except OSError:
                    pass


GUARD: CrashGuard | None = None    # lifelog_pc.serve() が起動したときに作る（確かめのときは無い）


def start_guard(home: Path, log: Callable[[str], None]) -> CrashGuard:
    global GUARD
    GUARD = CrashGuard(home, log)
    GUARD.startup()
    return GUARD


def safe_mode() -> bool:
    """GPU のモデルで落ち続けたので、この起動のあいだは GPU のモデルを使わないか"""
    return GUARD is not None and GUARD.safe


def free_engine(engine) -> None:
    """文字起こしのモデルを GPU から下ろす（動いている最中なら、終わるのを待ってから）。
    GPU のモデル（gpu_lock を持つもの）は、ほかの GPU のモデルが動いていない間に下ろし、捨てるところまで済ませる。"""
    lock = getattr(engine, "lock", None)
    shared = getattr(engine, "gpu_lock", None)
    if lock is not None:
        lock.acquire()
    if shared is not None:
        shared.acquire()
    try:
        model = getattr(engine, "model", None)
        inner = getattr(model, "model", None)
        try:
            if inner is not None and hasattr(inner, "unload_model"):
                inner.unload_model()
        except Exception:  # noqa: BLE001 — 下ろせなくても、捨てれば GPU は空く
            pass
        if hasattr(engine, "model"):
            engine.model = None
        engine.unloaded = True
        del model, inner
        gc.collect()
    finally:
        if shared is not None:
            shared.release()
        if lock is not None:
            lock.release()
    note_change()  # GPU に載っているものが減った（gpu-state.json を書き直す）


class GpuPlan:
    """文字起こしの GPU のモデルを、時間割と学び直しに合わせて下ろす・戻す。"""

    def __init__(self, get_ensemble: Callable[[], object], build: Callable[[str], object],
                 log: Callable[[str], None], clock: Callable[[], float] = time.time,
                 free_mb: Callable[[], int | None] | None = None,
                 need_mb: Callable[[str], int] | None = None) -> None:
        self.get_ensemble = get_ensemble
        self.build = build
        self.log = log
        self.clock = clock
        self.free_mb = free_mb or self._free_mb
        # 戻す前に要る GPU の空き（動かす分と残しておく分）。ops.start が config.json を読むものを渡す
        self.need_mb = need_mb or (lambda name: need_with_spare(name, self.settings))
        self.settings: dict = {}           # tick が受け取った config.json（Ollama の置き場所を status に出すため）
        self.lock = threading.RLock()
        self.holds: set[str] = set()
        self.down: list[str] = []          # 下ろしているモデルの名前（戻すもの）
        self.mode = "day"                  # day・night・train・restoring
        self.changed = clock()
        self.last_work = clock()
        self.retry_at = 0.0
        self.restoring = False
        self.failed: dict[str, str] = {}
        self.night: dict | None = {"start": (1, 0), "end": (6, 0), "idle": 1800.0}

    # MARK: 今の様子

    @staticmethod
    def _free_mb() -> int | None:
        # 1つ戻すたびに空きが減るので、覚えておいたもの（30 秒）は使わずに見直す
        memory = gpu_memory(fresh=True)
        return None if memory is None else memory["free"]

    def gpu_engines(self) -> list:
        ensemble = self.get_ensemble()
        return [e for e in list(getattr(ensemble, "engines", []) or [])
                if getattr(e, "name", "") in GPU_NAMES and getattr(e, "provider", "") == "cuda"]

    def _set_engines(self, engines: list) -> None:
        """Ensemble の並びを入れ替える（読み込みの順にそろえ、名前と動く場所も直す）"""
        ensemble = self.get_ensemble()
        engines = sorted(engines, key=lambda e: ORDER.index(e.name) if e.name in ORDER else len(ORDER))
        ensemble.engines = engines
        try:
            ensemble.label = "＋".join(getattr(e, "label", e.name) for e in engines)
            ensemble.provider = "cuda" if any(getattr(e, "provider", "") == "cuda" for e in engines) else "cpu"
        except AttributeError:
            pass

    def status(self) -> dict:
        names = {"day": "昼の割り当て（文字起こしのモデルが GPU にいます）",
                 "night": "夜の割り当て（30分仕事が無いので、GPU の文字起こしのモデルを下ろしています）",
                 "train": "学び直しのため、GPU の文字起こしのモデルを下ろしています",
                 "restoring": "GPU の文字起こしのモデルを戻しています（戻るまでは CPU のモデルで受けます）"}
        with self.lock:
            mode = "restoring" if self.restoring else self.mode
            text = names.get(mode, mode)
            if safe_mode():
                text = "GPU のモデルで落ち続けたので、この起動のあいだは CPU のモデルだけで文字にしています（" + text + "）"
            settings = dict(self.settings)
            return {"mode": mode, "text": text, "safe": safe_mode(), "down": list(self.down), "holds": sorted(self.holds),
                    "since": self.changed, "last_work": self.last_work, "failed": dict(self.failed),
                    "night": None if self.night is None else {
                        "start": "%02d:%02d" % self.night["start"], "end": "%02d:%02d" % self.night["end"],
                        "idle_minutes": round(self.night["idle"] / 60)},
                    "ollama": ollama_text(settings)}

    # MARK: 下ろす・戻す

    def unload(self, reason: str) -> list[str]:
        """GPU の文字起こしのモデルを下ろす。下ろした名前を返す。"""
        with self.lock:
            engines = self.gpu_engines()
            if not engines:
                return []
            ensemble = self.get_ensemble()
            self._set_engines([e for e in ensemble.engines if e not in engines])
            names = [e.name for e in engines]
            self.down.extend(n for n in names if n not in self.down)
            self.mode = reason
            self.changed = self.clock()
        for engine in engines:
            free_engine(engine)
        why = "学び直しのため" if reason == "train" else "夜で仕事が無いので"
        self.log(f"GPU の時間割: {why}、{'・'.join(names)} を GPU から下ろしました（CPU のモデルで受けます）")
        hook = AFTER_NIGHT
        if reason == "night" and hook is not None:
            # 昼に CPU だけで載せた Ollama のモデル（num_gpu 0）が長く残る設定でも、次は GPU で読み込まれるように
            try:
                hook()
            except Exception:  # noqa: BLE001
                pass
        return names

    def restore(self) -> list[str]:
        """下ろしたモデルを戻す（この呼び出しの中で読み込む）。戻した名前を返す。"""
        with self.lock:
            if self.holds or not self.down or self.restoring:
                return []
            self.restoring = True
            wanted = list(self.down)
        back = []
        try:
            # 戻している間も「GPU に載っている」とみなす（この間に頼まれた Ollama も CPU だけで動かす）
            with loading("restore"):
                make_room()  # LifeLog が使う Ollama のモデルが GPU にいれば、先に下ろす
                for name in wanted:
                    free = self.free_mb()
                    need = self.need_mb(name)
                    if free is not None and free < need:
                        self.failed[name] = f"GPU の空きが足りません（{free} MB。{need} MB 要ります）"
                        self.log(f"GPU の時間割: GPU の空きが {free} MB なので、{name} はまだ戻しません"
                                 f"（動かす分と残しておく分で {need} MB 要ります。{RETRY / 60:.0f} 分あとにやり直します）")
                        continue
                    try:
                        engine = self.build(name)
                    except Exception as error:  # noqa: BLE001 — 戻せなくても、CPU のモデルで受け続ける
                        self.failed[name] = str(error) or repr(error)
                        self.log(f"GPU の時間割: {name} を戻せませんでした（{RETRY / 60:.0f} 分あとにやり直します）: {error!r}")
                        continue
                    if getattr(engine, "provider", "") != "cuda":
                        free_engine(engine)
                        self.failed[name] = "GPU に載りませんでした"
                        self.log(f"GPU の時間割: {name} が GPU に載らなかったので使いません（{RETRY / 60:.0f} 分あとにやり直します）")
                        continue
                    self.failed.pop(name, None)
                    back.append(name)
                    with self.lock:
                        ensemble = self.get_ensemble()
                        current = [e for e in ensemble.engines if e.name != name]
                        self._set_engines(current + [engine])
                        if name in self.down:
                            self.down.remove(name)
        finally:
            with self.lock:
                self.restoring = False
                if not self.down:
                    self.mode = "day"
                    self.retry_at = 0.0
                else:
                    self.retry_at = self.clock() + RETRY
                self.changed = self.clock()
        if back:
            self.log(f"GPU の時間割: {'・'.join(back)} を GPU に戻しました")
        return back

    def restore_later(self) -> None:
        """裏で戻す（仕事は、戻るまで CPU のモデルで受ける）"""
        with self.lock:
            if self.holds or not self.down or self.restoring:
                return
        threading.Thread(target=self.restore, name="gpu-restore", daemon=True).start()

    def want(self, name: str) -> None:
        """name も GPU に載せたい（学び直しで新しくなった・初めてできた mine）。今は載せず、次に戻すときに作り直して載せる。"""
        with self.lock:
            if name not in self.down:
                self.down.append(name)

    def hold(self, reason: str) -> None:
        """reason（学び直しなど）が終わるまで、GPU の文字起こしのモデルを下ろしておく"""
        with self.lock:
            self.holds.add(reason)
        self.unload(reason)
        with self.lock:
            self.mode = reason
            self.changed = self.clock()

    def release(self, reason: str, wait: bool = True) -> None:
        """hold をやめる。夜で仕事が無ければ夜の割り当てのまま、そうでなければ戻す。"""
        with self.lock:
            self.holds.discard(reason)
            if self.holds:
                return
            now = self.clock()
            stay = self.night is not None and in_window(now, self.night["start"], self.night["end"]) \
                and now - self.last_work >= self.night["idle"] and bool(self.down)
            self.mode = "night" if stay else "day"
            self.changed = now
        if stay:
            self.log("GPU の時間割: 学び直しが終わりました。夜で仕事が無いので、GPU は下ろしたままにします")
            return
        if wait:
            self.restore()
        else:
            self.restore_later()

    # MARK: 時計と仕事

    def note_work(self) -> None:
        """仕事が来た（/transcribe・/jobs）。夜の割り当てなら戻す。"""
        with self.lock:
            self.last_work = self.clock()
            back = bool(self.down) and not self.holds and self.last_work >= self.retry_at
        if back:
            self.restore_later()

    def tick(self, busy: bool, config: dict | None = None) -> None:
        """15 秒ごとに呼ぶ。夜に30分仕事が無ければ下ろす・夜が明けたら戻す・戻せなかったものをやり直す。"""
        now = self.clock()
        if config is not None:
            self.night = night_config(config)
            self.settings = dict(config)
        with self.lock:
            if busy:
                self.last_work = now
            if self.holds or self.restoring:
                return
            night = self.night is not None and in_window(now, self.night["start"], self.night["end"])
            idle = now - self.last_work >= (self.night or {}).get("idle", 1800.0)
            down_now = night and idle and bool(self.gpu_engines())
            back = bool(self.down) and (not night or not idle) and now >= self.retry_at
        if down_now:
            self.unload("night")
        elif back:
            self.restore_later()


# MARK: - この PC の Ollama（学び直しの前に下ろし、終わったら戻す）


def plain_model(name: str) -> str:
    """Ollama のモデルの名前をそろえる（"bge-m3" は "bge-m3:latest" と同じ）"""
    name = str(name or "")
    return name if ":" in name else name + ":latest"


class Ollama:
    """http://127.0.0.1:11434 の /api/ps で載っているモデルを見て、keep_alive 0 で下ろす。この PC の中にだけつなぐ。
    options を渡すと、載せ直すとき（keep_alive が 0 でないとき）に、その options を付ける（GPU の文字起こしのモデルが
    載っているあいだは {"num_gpu": 0}）。下ろすときには付けない（付けると、Ollama が CPU で読み込み直してから下ろすため）。"""

    def __init__(self, url: str = OLLAMA_URL, log: Callable[[str], None] = print,
                 options: Callable[[], dict] | None = None) -> None:
        import urllib.request
        from urllib.parse import urlparse

        if (urlparse(url).hostname or "") not in ("127.0.0.1", "localhost", "::1"):
            raise ValueError("Ollama の宛先はこの PC の中にしてください")
        self.url = url.rstrip("/")
        self.log = log
        self.options = options
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def call(self, path: str, body: dict | None = None, timeout: float = 30.0) -> dict:
        import urllib.request

        data = None if body is None else json.dumps(body).encode("utf-8")
        request = urllib.request.Request(self.url + path, data=data, method="GET" if body is None else "POST",
                                         headers={"Content-Type": "application/json"})
        with self.opener.open(request, timeout=timeout) as response:
            return json.loads(response.read() or b"{}")

    def loaded(self) -> list[dict]:
        """載っているモデル（Ollama が動いていなければ空）"""
        try:
            models = self.call("/api/ps", timeout=5.0).get("models") or []
        except Exception:  # noqa: BLE001
            return []
        return [m for m in models if isinstance(m, dict) and (m.get("name") or m.get("model"))]

    def _keep(self, name: str, keep_alive) -> None:
        """keep_alive を変える（0 なら下ろす）。言葉のモデル（/api/generate）で断られたら、埋め込みのモデルとして頼む。"""
        extra: dict = {}
        if keep_alive != 0 and self.options is not None:
            try:
                extra = dict(self.options() or {})
            except Exception:  # noqa: BLE001
                extra = {}
        more = {"options": extra} if extra else {}
        try:
            answer = self.call("/api/generate", {"model": name, "keep_alive": keep_alive, **more}, timeout=120.0)
            if not answer.get("error"):
                return
        except Exception:  # noqa: BLE001
            pass
        self.call("/api/embed", {"model": name, "input": " ", "keep_alive": keep_alive, **more}, timeout=120.0)

    def unload_where(self, names: list[str], on_gpu: bool, wait: float = 10.0) -> list[str]:
        """names（LifeLog が使うモデル）のうち、GPU に載っているもの（on_gpu。/api/ps の size_vram が 0 より大きい）か、
        CPU だけに載っているもの（size_vram が 0）を下ろす。下りるまで wait 秒まで待つ。下ろした名前を返す。
        ほかのソフトが使うモデル（names に無いもの）には触らない。"""
        wanted = {plain_model(n) for n in names if n}

        def matching() -> list[str]:
            found = []
            for model in self.loaded():
                name = str(model.get("name") or model.get("model"))
                try:
                    vram = int(model.get("size_vram") or 0)
                except (TypeError, ValueError):
                    vram = 0
                if plain_model(name) in wanted and (vram > 0) == on_gpu:
                    found.append(name)
            return found

        targets = matching()
        for name in targets:
            try:
                self._keep(name, 0)
            except Exception as error:  # noqa: BLE001 — 下ろせなくても、空きを確かめてから載せる
                self.log(f"Ollama の {name} を下ろせませんでした: {error!r}")
        if targets:
            deadline = time.time() + wait
            while time.time() < deadline and set(matching()) & set(targets):
                time.sleep(0.25)
        return targets

    def unload_all(self, now: float | None = None) -> list[dict]:
        """載っているモデルを全部下ろす。戻すときのために、(名前, 長く載せておく設定だったか) を返す。"""
        import datetime

        now = time.time() if now is None else now
        saved = []
        for model in self.loaded():
            name = str(model.get("name") or model.get("model"))
            until = None
            try:
                text = str(model.get("expires_at") or "")
                until = datetime.datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp() if text else None
            except ValueError:
                until = None
            try:
                self._keep(name, 0)
                saved.append({"name": name, "long": until is not None and until - now > 3600})
            except Exception as error:  # noqa: BLE001 — 下ろせなくても学び直しは試す
                self.log(f"Ollama の {name} を下ろせませんでした: {error!r}")
        if saved:
            self.log(f"学び直しのため、Ollama のモデルを {len(saved)} 個下ろしました")
        return saved

    def restore(self, saved: list[dict]) -> int:
        """unload_all で下ろしたもののうち、長く載せておく設定だったものを載せ直す（短い設定のものは、どのみち下りていた）"""
        back = 0
        for model in saved or []:
            if not model.get("long"):
                continue
            try:
                self._keep(str(model["name"]), -1)
                back += 1
            except Exception as error:  # noqa: BLE001
                self.log(f"Ollama の {model.get('name')} を載せ直せませんでした: {error!r}")
        if back:
            self.log(f"Ollama のモデルを {back} 個載せ直しました")
        return back


def nvidia_present() -> bool:
    import shutil

    if shutil.which("nvidia-smi"):
        return True
    return Path(os.environ.get("SystemRoot", r"C:\Windows"), "System32", "nvidia-smi.exe").exists()
