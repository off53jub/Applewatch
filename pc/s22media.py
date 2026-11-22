"""LifeLog PC: s22 確10 の PC の側。Windows の「いま再生中」（GSMTC）と、PC を触っていた時間を記録する（2026-11-22）。

- 1 分ごとに、Windows の再生中の情報（GlobalSystemMediaTransportControlsSessionManager）から、再生中（Playing）の
  アプリの名前だけを読む。**曲名・動画の題・アーティストは読まない・記録しない**。読むのは Windows PowerShell の短い命令
  （WinRT。新しい部品は足さない）。Windows でないとき・読めないときは何もしない。
- PC を触っていた時間（最後にキーかマウスを使ってから IDLE_ACTIVE 秒以内）も、時刻だけ記録する（GetLastInputInfo）。
- 置き場所: HOME/s22/media/<日>.json = {"day", "playing": [[始まり, 終わり, アプリ]], "active": [[始まり, 終わり]]}（epoch 秒）。
  続いた見本（MERGE_GAP 秒以内）は 1 つにまとめる。KEEP_DAYS 日より古いものは消す。PC の外には出さない
  （母艦の M が日ごとの数を読むときは HOME を読む）。
- near(home, ms): 記録の行の時刻が再生中の時間（前後 NEAR 秒）に入るか → 記録の行に省ける "mediaNearby": true（records.py）
  と、話し手の札「動画の声かも」（s22voice.py）。
config.json の "media_watch": false で止める。記録（log.txt）には数だけ。
"""

from __future__ import annotations

import datetime
import json
import os
import re
import subprocess
import sys
import threading
import time
from pathlib import Path

EVERY = 60.0
MERGE_GAP = 150.0
NEAR = 30.0
IDLE_ACTIVE = 120.0
KEEP_DAYS = 30
APP_NAME = re.compile(r"[^A-Za-z0-9._!-]")
SCRIPT = r"""
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
$null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager,Windows.Media.Control,ContentType=WindowsRuntime]
$op = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()
$t = $asTask.MakeGenericMethod([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]).Invoke($null, @($op))
$null = $t.Wait(3000)
foreach ($s in $t.Result.GetSessions()) { $p = $s.GetPlaybackInfo(); "{0}`t{1}" -f $s.SourceAppUserModelId, $p.PlaybackStatus }
"""

_lock = threading.Lock()
_cache: dict = {}


def folder(home: Path) -> Path:
    return Path(home) / "s22" / "media"


def app_name(raw: str) -> str:
    """アプリの名前だけ（"…\\chrome.exe" → "chrome.exe"・"Microsoft.ZuneMusic_…!App" → "Microsoft.ZuneMusic"）"""
    name = str(raw or "").strip().replace("\\", "/").split("/")[-1]
    name = name.split("_")[0] if "!" in name else name
    return APP_NAME.sub("", name)[:40] or "?"


def parse_sessions(text: str) -> list[str]:
    """PowerShell の出力（アプリ<TAB>状態）から、再生中のアプリの名前"""
    out = []
    for raw in str(text or "").splitlines():
        app, _, status = raw.partition("\t")
        if status.strip().lower() == "playing" and app.strip():
            name = app_name(app)
            if name not in out:
                out.append(name)
    return out


def read_playing() -> list[str] | None:
    """いま再生中のアプリ（Windows でない・読めないときは None）"""
    if sys.platform != "win32":
        return None
    try:
        flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        done = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                               "-Command", SCRIPT], capture_output=True, text=True, timeout=20, creationflags=flags)
    except (OSError, subprocess.SubprocessError):
        return None
    if done.returncode != 0:
        return None
    return parse_sessions(done.stdout)


def idle_seconds() -> float | None:
    if sys.platform != "win32":
        return None
    try:
        import ctypes

        class LASTINPUTINFO(ctypes.Structure):
            _fields_ = [("cbSize", ctypes.c_uint), ("dwTime", ctypes.c_uint)]

        info = LASTINPUTINFO()
        info.cbSize = ctypes.sizeof(LASTINPUTINFO)
        if not ctypes.windll.user32.GetLastInputInfo(ctypes.byref(info)):
            return None
        return max(0.0, (ctypes.windll.kernel32.GetTickCount() - info.dwTime) / 1000.0)
    except Exception:  # noqa: BLE001
        return None


def _path(home: Path, day: str) -> Path:
    return folder(home) / f"{day}.json"


def read_day(home: Path, day: str) -> dict:
    path = _path(home, day)
    try:
        stamp = path.stat().st_mtime
    except OSError:
        return {"day": day, "playing": [], "active": []}
    hit = _cache.get(str(path))
    if hit and hit[0] == stamp:
        return hit[1]
    try:
        body = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        body = {}
    body = {"day": day, "playing": [x for x in body.get("playing") or [] if isinstance(x, list) and len(x) == 3],
            "active": [x for x in body.get("active") or [] if isinstance(x, list) and len(x) == 2]}
    _cache[str(path)] = (stamp, body)
    return body


def _extend(spans: list, now: float, key=None) -> None:
    for span in reversed(spans):
        if (key is None or span[2] == key) and now - span[1] <= MERGE_GAP:
            span[1] = round(now, 1)
            return
    spans.append([round(now, 1), round(now, 1)] + ([key] if key is not None else []))


def note(home: Path, playing: list[str] | None, idle: float | None, now: float | None = None) -> dict:
    """1 回分の見本を足す"""
    now = time.time() if now is None else now
    day = datetime.datetime.fromtimestamp(now).date().isoformat()
    with _lock:
        body = read_day(home, day)
        body = {"day": day, "playing": [list(x) for x in body["playing"]], "active": [list(x) for x in body["active"]]}
        for app in playing or []:
            _extend(body["playing"], now, app)
        if idle is not None and idle <= IDLE_ACTIVE:
            _extend(body["active"], now)
        path = _path(home, day)
        path.parent.mkdir(parents=True, exist_ok=True)
        part = path.with_name(path.name + ".part")
        part.write_text(json.dumps(body, ensure_ascii=False), encoding="utf-8")
        os.replace(part, path)
        _cache.pop(str(path), None)
    return body


def near(home: Path, ms: int, near_s: float = NEAR) -> bool:
    """その時刻（ミリ秒）に PC で何かを再生していたか（前後 near_s 秒）"""
    moment = ms / 1000.0
    day = datetime.datetime.fromtimestamp(moment).date().isoformat()
    for start, end, _app in read_day(home, day)["playing"]:
        if start - near_s <= moment <= end + near_s:
            return True
    return False


def day_counts(home: Path, day: str) -> dict:
    body = read_day(home, day)
    playing = sum(max(0.0, b - a) for a, b, _ in body["playing"]) / 60
    active = sum(max(0.0, b - a) for a, b in body["active"]) / 60
    apps: dict[str, float] = {}
    for a, b, app in body["playing"]:
        apps[app] = apps.get(app, 0.0) + max(0.0, b - a) / 60
    return {"playing_min": round(playing), "active_min": round(active),
            "apps": {k: round(v) for k, v in sorted(apps.items(), key=lambda kv: -kv[1])[:5]}}


def prune(home: Path, today: datetime.date | None = None) -> int:
    limit = ((today or datetime.date.today()) - datetime.timedelta(days=KEEP_DAYS)).isoformat()
    gone = 0
    for path in folder(home).glob("????-??-??.json"):
        if path.stem < limit:
            try:
                path.unlink()
                gone += 1
            except OSError:
                pass
    return gone


class Watcher:
    def __init__(self, home: Path, config, log) -> None:
        self.home = Path(home)
        self.config = config
        self.log = log
        self.thread: threading.Thread | None = None
        self.failed = 0

    def start(self) -> None:
        if sys.platform != "win32" or self.thread is not None:
            return
        self.thread = threading.Thread(target=self._loop, name="s22-media", daemon=True)
        self.thread.start()

    def _loop(self) -> None:
        time.sleep(30)
        while True:
            try:
                if (self.config() or {}).get("media_watch") is not False:
                    playing = read_playing()
                    if playing is None:
                        self.failed += 1
                        if self.failed == 3:
                            self.log("再生中の情報（GSMTC）を読めませんでした（動画の声かもの印は付けません）")
                    note(self.home, playing, idle_seconds())
            except Exception as error:  # noqa: BLE001 — 読めなくても、ほかは続ける
                self.failed += 1
                if self.failed in (1, 100):
                    self.log(f"再生中の情報を記録できませんでした: {type(error).__name__}")
            time.sleep(EVERY)
