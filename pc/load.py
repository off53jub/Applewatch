"""この PC の負荷を毎日数える（2026-11-15）。

背景: 「Ollama と LifeLogPC の CPU が高い」と言われたとき、その場で測るしか無かった。前と後を同じ数え方で比べられるよう、
1 分に 1 回見回って、毎日の数を HOME\quality-daily.json のその日の所に足していく（quality.add_today）。

- cpu_self_s    LifeLog PC 自身が使った CPU の秒（time.process_time の増えた分）
- cpu_ollama_s  Ollama のプロセス（priority.find で見つかるもの）が使った CPU の秒（Windows の GetProcessTimes の増えた分）。
                プロセスが入れ替わった（pid が同じでも始まった時刻が違う）ときは、新しいプロセスの分を頭から足す。読めなければ足さない
- yield_min     PC を使っているので母艦の取り込みを譲っていた分（見回りの回数＝分。presence.in_use が True だったとき）
- config.json の "load_meter": false で止める。Windows のほかでは Ollama の分は読めない（足さない）。
数えるだけで、何も変えない。--fake-models のときは始めない（lifelog_pc.py）。
"""

from __future__ import annotations

import os
import threading
import time
from pathlib import Path
from typing import Callable

import presence
import priority
import quality

EVERY = 60.0
KEEP_PROCESSES = 64   # 見えなくなったプロセスを覚えておく数の上限


def enabled(config: dict | None) -> bool:
    """config.json の "load_meter"。false（・"off"・0）なら数えない"""
    value = (config or {}).get("load_meter", True)
    if isinstance(value, str):
        return value.strip().lower() not in ("off", "false", "no", "0")
    return value is not False and value != 0


def delta(previous: dict[int, tuple[int, float]] | None,
          current: dict[int, tuple[int, float]]) -> float:
    """プロセスごとの (始まった時刻, CPU の秒) の前回と今回から、増えた秒の合計。
    - 前回が None（最初の見回り）: 基準を覚えるだけで 0
    - 同じプロセス（pid も始まった時刻も同じ）: 増えた分（減っていたら 0）
    - 前回に無い pid・始まった時刻が違う（入れ替わった）: 新しいプロセスの分を頭から足す
    - 前回にあって今回無い（終わった）: 足さない"""
    if previous is None:
        return 0.0
    total = 0.0
    for pid, (created, seconds) in current.items():
        before = previous.get(pid)
        if before is not None and before[0] == created:
            total += max(0.0, seconds - before[1])
        else:
            total += max(0.0, seconds)
    return total


def read_cpu(pid: int) -> tuple[int, float] | None:
    """pid の (始まった時刻, 使った CPU の秒)（Windows の GetProcessTimes）。Windows のほか・読めないときは None"""
    if os.name != "nt":
        return None
    try:
        import ctypes
        from ctypes import wintypes

        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.OpenProcess.restype = wintypes.HANDLE
        kernel.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
        kernel.GetProcessTimes.argtypes = (wintypes.HANDLE, ctypes.POINTER(wintypes.FILETIME),
                                           ctypes.POINTER(wintypes.FILETIME), ctypes.POINTER(wintypes.FILETIME),
                                           ctypes.POINTER(wintypes.FILETIME))
        kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
        handle = kernel.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
        if not handle:
            return None
        try:
            created, exited, kernel_time, user_time = (wintypes.FILETIME() for _ in range(4))
            if not kernel.GetProcessTimes(handle, ctypes.byref(created), ctypes.byref(exited),
                                          ctypes.byref(kernel_time), ctypes.byref(user_time)):
                return None

            def ticks(value) -> int:
                return (int(value.dwHighDateTime) << 32) | int(value.dwLowDateTime)

            return ticks(created), (ticks(kernel_time) + ticks(user_time)) / 1e7  # 100 ナノ秒単位
        finally:
            kernel.CloseHandle(handle)
    except Exception:  # noqa: BLE001 — 読めなければ足さない
        return None


def read_ollama(finder: Callable[[], list[tuple[int, str]]] = priority.find,
                reader: Callable[[int], tuple[int, float] | None] = read_cpu) -> dict[int, tuple[int, float]]:
    """いま動いている Ollama のプロセスの (始まった時刻, CPU の秒)。読めないものは入れない"""
    found: dict[int, tuple[int, float]] = {}
    try:
        processes = finder()
    except Exception:  # noqa: BLE001
        return found
    for pid, _name in processes:
        got = reader(pid)
        if got is not None:
            found[pid] = got
    return found


class Meter:
    """見回りごとの前回の値を覚えておく（tick を 1 分ごとに呼ぶ）"""

    def __init__(self) -> None:
        self.self_cpu: float | None = None
        self.ollama: dict[int, tuple[int, float]] | None = None

    def reset(self) -> None:
        self.self_cpu = None
        self.ollama = None

    def tick(self, config: dict | None, own: float | None = None, idle: float | None = None,
             ollama: dict[int, tuple[int, float]] | None = None, adder: Callable[[dict], object] | None = None,
             ) -> dict:
        """1 回の見回り。数えた増えた分（cpu_self_s・cpu_ollama_s・yield_min のうち 0 でないもの）を返し、adder で足す。
        止める設定のときは何も足さず、前回の値も忘れる（また始めたときは基準から）。own・idle・ollama は検査で渡す作り物の値"""
        if not enabled(config):
            self.reset()
            return {}
        own = time.process_time() if own is None else own
        ollama = read_ollama() if ollama is None else ollama
        added_self = 0.0 if self.self_cpu is None else max(0.0, own - self.self_cpu)
        added_ollama = delta(self.ollama, ollama)
        # 読めなかった回があっても、次に同じプロセスが読めたとき頭から足し直さないよう、見えなかった分も覚えておく
        kept = {pid: value for pid, value in (self.ollama or {}).items() if pid not in ollama}
        kept.update(ollama)
        self.self_cpu, self.ollama = own, dict(list(kept.items())[-KEEP_PROCESSES:])
        values = {}
        if added_self > 0:
            values["cpu_self_s"] = round(added_self, 2)
        if added_ollama > 0:
            values["cpu_ollama_s"] = round(added_ollama, 2)
        if presence.in_use(config, idle):
            values["yield_min"] = 1
        if values and adder is not None:
            adder(values)
        return values


_started = False


def start(config: Callable[[], dict], log: Callable[[str], None], home: Path, every: float = EVERY) -> None:
    """裏で 1 分ごとに数える（1 回だけ始める）。書けなくても受け付けは続ける"""
    global _started
    if _started:
        return
    _started = True
    meter = Meter()

    def run() -> None:
        while True:
            try:
                meter.tick(config(), adder=lambda values: quality.add_today(values, home))
            except Exception:  # noqa: BLE001 — 数えられなくても受け付けは続ける
                pass
            time.sleep(every)

    threading.Thread(target=run, name="load-meter", daemon=True).start()
