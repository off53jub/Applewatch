"""LifeLog PC 版 7: GPU の時間割（文字起こしの GPU のモデルを下ろす・戻す）と、この PC の Ollama のモデルを下ろす・戻す。

決まりは docs/v7-plan.md の「4. 学び直しと GPU の時間割」。
- 昼は、文字起こしのモデル（whisper・kotoba・mine）が GPU に載っている。
- 夜（初めは 1:00〜6:00。config.json の "gpu_night" で変えられる）に30分仕事が無ければ、GPU のモデルを下ろし、
  CPU のモデル（haas・reazon）だけで受ける。言語モデル（Ollama）と学び直しに GPU を空けるため。
- 学び直しのあいだも下ろす（hold("train")）。そのあいだは、仕事が来ても戻さない。
- 仕事が来たら戻す（戻るまでは CPU で受ける）。戻すときに GPU に載らなかったもの（CPU に落ちたもの）は使わず、
  5 分おいてやり直す。
ここには文字にする仕組みは無い。ops.py が、今の Ensemble を返す get_ensemble と、モデルを作り直す build を渡す。
"""

from __future__ import annotations

import gc
import json
import os
import subprocess
import threading
import time
from pathlib import Path
from typing import Callable

GPU_NAMES = ("whisper", "kotoba", "mine")
ORDER = ["haas", "reazon", "whisper", "kotoba", "mine", "qwen"]
RETRY = 300.0                # 戻せなかったときに、やり直すまでの秒
SMI_EVERY = 30.0
OLLAMA_URL = "http://127.0.0.1:11434"
# 戻す前に GPU の空きを確かめる（MB のおおよそ。空きが足りないときは載せようとせず、あとでやり直す。
# 足りないまま載せると、Whisper は CPU に落ちて遅くなるため）
NEED_MB = {"whisper": 3300, "kotoba": 1800, "mine": 1800}


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


def gpu_memory(cache: dict = {}) -> dict | None:  # noqa: B006 — 30 秒だけ覚えておく
    """nvidia-smi で GPU のメモリーの使用量（MB）を見る（{"used", "total", "name"}）。見られなければ None。"""
    now = time.time()
    if cache.get("at") and now - cache["at"] < SMI_EVERY:
        return cache.get("value")
    value = None
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=memory.used,memory.total,name", "--format=csv,noheader,nounits"],
                             capture_output=True, text=True, timeout=10,
                             creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        first = (out.stdout or "").strip().splitlines()[0]
        used, total, name = [p.strip() for p in first.split(",", 2)]
        value = {"used": int(float(used)), "total": int(float(total)), "name": name}
    except (OSError, ValueError, IndexError, subprocess.SubprocessError):
        value = None
    cache.update(at=now, value=value)
    return value


def free_engine(engine) -> None:
    """文字起こしのモデルを GPU から下ろす（動いている最中なら、終わるのを待ってから）"""
    lock = getattr(engine, "lock", None)
    if lock is not None:
        lock.acquire()
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
    finally:
        if lock is not None:
            lock.release()
    gc.collect()


class GpuPlan:
    """文字起こしの GPU のモデルを、時間割と学び直しに合わせて下ろす・戻す。"""

    def __init__(self, get_ensemble: Callable[[], object], build: Callable[[str], object],
                 log: Callable[[str], None], clock: Callable[[], float] = time.time,
                 free_mb: Callable[[], int | None] | None = None) -> None:
        self.get_ensemble = get_ensemble
        self.build = build
        self.log = log
        self.clock = clock
        self.free_mb = free_mb or self._free_mb
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
        memory = gpu_memory()
        return None if memory is None else memory["total"] - memory["used"]

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
            return {"mode": mode, "text": names.get(mode, mode), "down": list(self.down), "holds": sorted(self.holds),
                    "since": self.changed, "last_work": self.last_work, "failed": dict(self.failed),
                    "night": None if self.night is None else {
                        "start": "%02d:%02d" % self.night["start"], "end": "%02d:%02d" % self.night["end"],
                        "idle_minutes": round(self.night["idle"] / 60)}}

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
            for name in wanted:
                free = self.free_mb()
                if free is not None and free < NEED_MB.get(name, 0):
                    self.failed[name] = f"GPU の空きが足りません（{free} MB）"
                    self.log(f"GPU の時間割: GPU の空きが {free} MB なので、{name} はまだ戻しません"
                             f"（{RETRY / 60:.0f} 分あとにやり直します）")
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


class Ollama:
    """http://127.0.0.1:11434 の /api/ps で載っているモデルを見て、keep_alive 0 で下ろす。この PC の中にだけつなぐ。"""

    def __init__(self, url: str = OLLAMA_URL, log: Callable[[str], None] = print) -> None:
        import urllib.request
        from urllib.parse import urlparse

        if (urlparse(url).hostname or "") not in ("127.0.0.1", "localhost", "::1"):
            raise ValueError("Ollama の宛先はこの PC の中にしてください")
        self.url = url.rstrip("/")
        self.log = log
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
        try:
            answer = self.call("/api/generate", {"model": name, "keep_alive": keep_alive}, timeout=120.0)
            if not answer.get("error"):
                return
        except Exception:  # noqa: BLE001
            pass
        self.call("/api/embed", {"model": name, "input": " ", "keep_alive": keep_alive}, timeout=120.0)

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
