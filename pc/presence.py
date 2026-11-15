"""PC を使っているか（最後にキーボード・マウスを触ってからの秒）を見る（2026-11-15）。

背景: 母艦の取り込み（mothersearch.py）は、08:30〜18:00 と 00:00〜05:00 を「重く回してよい時間」にしている。
これは「平日の昼は家にいない」という前提で、休みの日に本人が PC を使っていると重なる（11/15 の日曜の朝に重なった）。
そこで、PC を触っているあいだは、重く回さずに「軽いほう」（時間の外と同じ動き）にする。
文字起こし（届いた音声を文字にする仕事）は譲らない。触るのは母艦の取り込みだけ。

- config.json の "yield_when_used": 秒（既定 180＝3 分）。30 より小さい数は 30 にする。false・0・"off" なら譲らない（前と同じ）。
- Windows のほかや、最後に触った時刻が読めないときは「使っていない」とみなす（前と同じに動く）。
"""

from __future__ import annotations

import os

DEFAULT_AFTER = 180.0
MIN_AFTER = 30.0


def idle_seconds() -> float | None:
    """最後にキーボード・マウスを触ってからの秒（Windows の GetLastInputInfo）。Windows でない・読めないときは None"""
    if os.name != "nt":
        return None
    try:
        import ctypes
        from ctypes import wintypes

        class Info(ctypes.Structure):
            _fields_ = [("cbSize", wintypes.UINT), ("dwTime", wintypes.DWORD)]

        user = ctypes.WinDLL("user32", use_last_error=True)
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        user.GetLastInputInfo.argtypes = (ctypes.POINTER(Info),)
        user.GetLastInputInfo.restype = wintypes.BOOL
        kernel.GetTickCount.restype = wintypes.DWORD
        info = Info()
        info.cbSize = ctypes.sizeof(Info)
        if not user.GetLastInputInfo(ctypes.byref(info)):
            return None
        # どちらも 32 ビットで 49 日ごとに一周する。引き算も 32 ビットで回す
        millis = (int(kernel.GetTickCount()) - int(info.dwTime)) & 0xFFFFFFFF
        return millis / 1000.0
    except Exception:  # noqa: BLE001 — 読めなければ「分からない」
        return None


def yield_after(config: dict | None) -> float | None:
    """譲り始めるまでの秒（最後に触ってから、この秒より短いあいだは「使っている」）。譲らない設定なら None"""
    value = (config or {}).get("yield_when_used", DEFAULT_AFTER)
    if value is None:
        return DEFAULT_AFTER
    if value is False:
        return None
    if value is True:
        return DEFAULT_AFTER
    if isinstance(value, str):
        text = value.strip().lower()
        if text in ("off", "false", "no", "none", "0", ""):
            return None
        try:
            value = float(text)
        except ValueError:
            return DEFAULT_AFTER
    if isinstance(value, (int, float)):
        if value != value or value <= 0:  # nan・0・負の数
            return None
        return max(MIN_AFTER, float(value))
    return DEFAULT_AFTER


def in_use(config: dict | None, idle: float | None = None) -> bool:
    """PC を使っている（最後に触ってから yield_after より短い）か。譲らない設定・読めないときは False（前と同じ）。
    idle を渡さなければ、いまの値を読む（検査では作り物の値を渡す）"""
    after = yield_after(config)
    if after is None:
        return False
    if idle is None:
        idle = idle_seconds()
    if idle is None:
        return False
    return idle < after
