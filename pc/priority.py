"""この PC の Ollama の優先度を「通常以下」にする（2026-11-15）。

11/15 の実測: 母艦の意味の索引を作るあいだ、Ollama の llama-server が 8 コア中 3 コア強を使い、PC 全体が 100% だった。
速さを削る（スレッドを減らす・止める）のではなく、優先度だけを下げる。PC が空いていれば今までどおりの速さで進み、
ほかの仕事（文字起こし・画面・ほかのソフト）があればそちらが先に CPU を使う。

- 名前が ollama.exe・ollama app.exe・llama-server.exe のプロセスのうち、優先度が「通常」のものだけを下げる
  （本人が手で変えたもの・ほかの値のものには触らない）。Windows では、「通常以下」のプロセスが作る子プロセスも
  「通常以下」になるので、Ollama がモデルを読み込み直すたびに作る llama-server も下がる。念のため 1 分ごとに見直す。
- config.json の "ollama_priority": "below_normal"（既定）・"idle"（もっと下げる）・"normal"（何もしない＝前と同じ）。
- Windows のほかでは何もしない。下げられなくても（権限など）受け付けは続ける。記録には、下げたときだけ 1 行書く。
"""

from __future__ import annotations

import os
import threading
import time
from typing import Callable

NAMES = ("ollama.exe", "ollama app.exe", "llama-server.exe")
EVERY = 60.0
NORMAL = 0x00000020
BELOW_NORMAL = 0x00004000
IDLE = 0x00000040
LEVELS = {"below_normal": BELOW_NORMAL, "idle": IDLE}
LABELS = {BELOW_NORMAL: "通常以下", IDLE: "低"}


def level(config: dict | None) -> int | None:
    """config.json の "ollama_priority" から、下げる先の優先度（"normal" なら None＝何もしない）"""
    value = (config or {}).get("ollama_priority", "below_normal")
    if value is False:
        return None
    text = str(value).strip().lower().replace("-", "_").replace(" ", "_") if isinstance(value, str) else "below_normal"
    if text in ("normal", "off", "none"):
        return None
    return LEVELS.get(text, BELOW_NORMAL)


def find(names: tuple[str, ...] = NAMES) -> list[tuple[int, str]]:
    """名前が names のプロセス（pid, 名前）。Windows のほかでは空"""
    if os.name != "nt":
        return []
    import ctypes
    from ctypes import wintypes

    class Entry(ctypes.Structure):
        _fields_ = [("dwSize", wintypes.DWORD), ("cntUsage", wintypes.DWORD), ("th32ProcessID", wintypes.DWORD),
                    ("th32DefaultHeapID", ctypes.c_size_t), ("th32ModuleID", wintypes.DWORD),
                    ("cntThreads", wintypes.DWORD), ("th32ParentProcessID", wintypes.DWORD),
                    ("pcPriClassBase", ctypes.c_long), ("dwFlags", wintypes.DWORD),
                    ("szExeFile", ctypes.c_wchar * 260)]

    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
    kernel.CreateToolhelp32Snapshot.argtypes = (wintypes.DWORD, wintypes.DWORD)
    kernel.Process32FirstW.argtypes = (wintypes.HANDLE, ctypes.POINTER(Entry))
    kernel.Process32NextW.argtypes = (wintypes.HANDLE, ctypes.POINTER(Entry))
    kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
    snap = kernel.CreateToolhelp32Snapshot(0x00000002, 0)  # TH32CS_SNAPPROCESS
    if not snap or snap == wintypes.HANDLE(-1).value:
        return []
    wanted = {n.lower() for n in names}
    found: list[tuple[int, str]] = []
    try:
        entry = Entry()
        entry.dwSize = ctypes.sizeof(Entry)
        ok = kernel.Process32FirstW(snap, ctypes.byref(entry))
        while ok:
            name = entry.szExeFile
            if name.lower() in wanted:
                found.append((int(entry.th32ProcessID), name))
            ok = kernel.Process32NextW(snap, ctypes.byref(entry))
    finally:
        kernel.CloseHandle(snap)
    return found


def lower(pid: int, to: int) -> bool:
    """pid の優先度が「通常」なら to に下げる。下げたら True（通常でない・開けない・下げられないときは False）"""
    if os.name != "nt":
        return False
    import ctypes
    from ctypes import wintypes

    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
    kernel.GetPriorityClass.argtypes = (wintypes.HANDLE,)
    kernel.SetPriorityClass.argtypes = (wintypes.HANDLE, wintypes.DWORD)
    kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
    # PROCESS_SET_INFORMATION | PROCESS_QUERY_LIMITED_INFORMATION
    handle = kernel.OpenProcess(0x0200 | 0x1000, False, pid)
    if not handle:
        return False
    try:
        if kernel.GetPriorityClass(handle) != NORMAL:
            return False
        return bool(kernel.SetPriorityClass(handle, to))
    finally:
        kernel.CloseHandle(handle)


def sweep(config: dict | None, log: Callable[[str], None] | None = None,
          finder: Callable[[], list[tuple[int, str]]] = find, setter: Callable[[int, int], bool] = lower) -> list[str]:
    """いま動いている Ollama のプロセスのうち「通常」のものを下げる。下げたものの名前（pid つき）"""
    to = level(config)
    if to is None:
        return []
    done: list[str] = []
    for pid, name in finder():
        try:
            if setter(pid, to):
                done.append(f"{name}（{pid}）")
        except OSError:
            continue
    if done and log is not None:
        log(f"この PC の Ollama の優先度を「{LABELS.get(to, '通常以下')}」にしました: {'・'.join(done)}"
            "（速さは削らず、ほかの仕事を先に通します。config.json の \"ollama_priority\": \"normal\" で前と同じ）")
    return done


_started = False


def start(config: Callable[[], dict], log: Callable[[str], None], every: float = EVERY) -> None:
    """裏で 1 分ごとに sweep する（1 回だけ始める。Windows のほかでは何もしない）"""
    global _started
    if _started or os.name != "nt":
        return
    _started = True

    def run() -> None:
        while True:
            try:
                sweep(config(), log)
            except Exception:  # noqa: BLE001 — 下げられなくても受け付けは続ける
                pass
            time.sleep(every)

    threading.Thread(target=run, name="ollama-priority", daemon=True).start()
