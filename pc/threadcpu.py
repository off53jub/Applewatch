"""LifeLog PC: この PC の CPU を、どの糸（スレッド）が使っているかを数える（s21 速4。2026-11-22）。

背景: quality-daily.json の cpu_self_s が 1 日 2〜3.7 万秒（7〜10 時間ぶん）。何が使っているかが分からなかった。
- EVERY（10 分）ごとに、Python の糸ごとの CPU の秒（Windows の GetThreadTimes）を読み、前の回から増えた分を、糸の名前ごとに
  その日の分へ足す（HOME/load-threads.json。{"days": {"YYYY-MM-DD": {名前: 秒}}}。14 日より古い日は消す）。
- 名前は数字を除いてまとめる（「Thread-12 (process_request_thread)」→「受け付け（process_request_thread）」）。
- Python の糸の合計と、このプロセス全体（time.process_time）の差は「モデルの中の計算など（名前の無い糸）」にする
  （onnxruntime・CTranslate2 が自分で作る糸。文字起こしの計算はほとんどここに入る）。
- Windows のほかでは、Python の糸ごとには読めないので、全体だけを数える。
数えるだけで、何も変えない。config.json の "load_meter": false で止める（load.py と同じ設定）。
"""

from __future__ import annotations

import datetime
import json
import os
import re
import threading
import time
from pathlib import Path

EVERY = 600.0
KEEP_DAYS = 14
FILE = "load-threads.json"
NATIVE = "モデルの中の計算など（名前の無い糸）"
_DIGITS = re.compile(r"[-_ ]?\d+")


def thread_seconds(native_id: int) -> float | None:
    """その糸が使った CPU の秒（Windows の GetThreadTimes。読めなければ None）"""
    if os.name != "nt" or not native_id:
        return None
    try:
        import ctypes
        from ctypes import wintypes

        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.OpenThread.restype = wintypes.HANDLE
        kernel.OpenThread.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
        kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
        handle = kernel.OpenThread(0x0800, False, int(native_id))  # THREAD_QUERY_LIMITED_INFORMATION
        if not handle:
            return None
        try:
            times = [wintypes.FILETIME() for _ in range(4)]
            if not kernel.GetThreadTimes(handle, *(ctypes.byref(t) for t in times)):
                return None
            return sum(((t.dwHighDateTime << 32) | t.dwLowDateTime) / 1e7 for t in times[2:])
        finally:
            kernel.CloseHandle(handle)
    except Exception:  # noqa: BLE001
        return None


def label(name: str) -> str:
    """糸の名前を数え方の名前にする（数字を除く。受け付けの糸はまとめる）"""
    text = str(name or "")
    match = re.fullmatch(r"Thread-\d+(?: \((.+)\))?", text)
    if match:
        return f"受け付けなど（{match[1]}）" if match[1] else "名前の無い Python の糸"
    if text.startswith("ThreadPoolExecutor"):
        return "多数決のモデルを回す糸（ThreadPoolExecutor）"
    return _DIGITS.sub("", text) or "名前の無い Python の糸"


class Meter:
    def __init__(self, home: Path, reader=thread_seconds, process=time.process_time) -> None:
        self.home = Path(home)
        self.reader = reader
        self.process = process
        self.before: dict[int, float] | None = None
        self.process_before: float | None = None
        self.lock = threading.Lock()

    def sample(self, threads: list[threading.Thread] | None = None) -> dict[str, float]:
        """前の回から増えた秒（名前ごと）。最初の回は基準を覚えるだけで空"""
        threads = list(threading.enumerate()) if threads is None else threads
        now: dict[int, tuple[str, float]] = {}
        for thread in threads:
            seconds = self.reader(getattr(thread, "native_id", 0) or 0)
            if seconds is not None:
                now[int(thread.native_id)] = (label(thread.name), seconds)
        total = self.process()
        with self.lock:
            before, process_before = self.before, self.process_before
            self.before = {k: v for k, (_, v) in now.items()}
            self.process_before = total
        if before is None or process_before is None:
            return {}
        added: dict[str, float] = {}
        named = 0.0
        for ident, (name, seconds) in now.items():
            grew = max(0.0, seconds - before.get(ident, 0.0))
            if grew > 0:
                added[name] = added.get(name, 0.0) + grew
                named += grew
        rest = max(0.0, (total - process_before) - named)
        if rest > 0:
            added[NATIVE] = added.get(NATIVE, 0.0) + rest
        return added

    def add(self, added: dict[str, float], day: str | None = None) -> None:
        if not added:
            return
        day = day or datetime.date.today().isoformat()
        data = read(self.home)
        days = data["days"]
        entry = days.setdefault(day, {})
        for name, seconds in added.items():
            entry[name] = round(float(entry.get(name, 0.0)) + seconds, 1)
        limit = (datetime.date.fromisoformat(day) - datetime.timedelta(days=KEEP_DAYS)).isoformat()
        for old in [d for d in days if d < limit]:
            days.pop(old, None)
        path = self.home / FILE
        part = path.with_name(path.name + ".part")
        part.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
        os.replace(part, path)


def read(home: Path) -> dict:
    try:
        data = json.loads((Path(home) / FILE).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"days": {}}
    return data if isinstance(data, dict) and isinstance(data.get("days"), dict) else {"days": {}}


def summary_line(home: Path, day: str | None = None, top: int = 5) -> str | None:
    """その日（無ければ今日）に CPU を多く使った糸の上位"""
    days = read(home)["days"]
    if not days:
        return None
    day = day if day in days else max(days)
    entry = days[day]
    total = sum(entry.values()) or 1.0
    ranked = sorted(entry.items(), key=lambda kv: kv[1], reverse=True)[:top]
    return (f"CPU を使った糸（{day}・合計 {total / 3600:.1f} 時間ぶん）: "
            + "・".join(f"{name} {seconds / total:.0%}" for name, seconds in ranked))
