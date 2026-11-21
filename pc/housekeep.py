"""LifeLog PC: 記録（log.txt）を回す・意味で探す索引（semantic.db）を詰める（s21 速9。2026-11-22）。

消すのではなく、古い分を回す:
- log.txt が ROTATE_AT（8MB）を超えたら、直近 KEEP_DAYS（15 日。母艦の Build-CaptureLoss.py が 14 日分を読むため）の行を残し、
  それより前の行を HOME/logs/log-YYYYMMDD-HHMMSS.txt.gz に縮めて移す。15 日より前の行が無ければ何もしない。
  書いている最中の行が切れないよう、lifelog_pc.log と同じ lock を持って行う。
  縮めたものは KEEP_ARCHIVES（100 個）より多くなったら、古いものから片づける（100 個で 8MB×100＝縮める前 約 800MB 分）。
- semantic.db は、空き（使われていないページ）が VACUUM_FREE（10%）以上のときだけ、週に 1 回、00:00〜05:00 に VACUUM する
  （行は消さない。空きを詰めるだけ）。2026-11-22 に測ったときは空き 0%（324MB は全部使っている行。bge-m3 の 51,447 行と
  母艦の 22,516 まとまり）だったので、今は詰めても小さくならない。大きさと空きの割合は summary.md に出す。
config.json の "housekeep": false で両方止める。
"""

from __future__ import annotations

import datetime
import gzip
import os
import sqlite3
import threading
import time
from pathlib import Path
from typing import Callable

ROTATE_AT = 8 * 1024 * 1024
KEEP_DAYS = 15
KEEP_ARCHIVES = 100
VACUUM_FREE = 0.10
VACUUM_EVERY = 7 * 86400
VACUUM_HOURS = (0, 5)


def first_kept(data: bytes, since: str) -> int:
    """since（YYYY-MM-DD）の日からの行が始まる位置（そこから残す）。日付で始まらない行は前の行に付ける"""
    key = since.encode("ascii")
    position = 0
    while position < len(data):
        head = data[position:position + 10]
        if len(head) == 10 and head[4:5] == b"-" and head[7:8] == b"-" and head[:4].isdigit() and head >= key:
            return position
        end = data.find(b"\n", position)
        position = len(data) if end < 0 else end + 1
    return len(data)


def rotate_log(path: Path, lock: threading.Lock | threading.RLock, folder: Path, now: datetime.datetime | None = None,
               limit: int = ROTATE_AT, keep_days: int = KEEP_DAYS) -> Path | None:
    """log.txt が limit を超えていれば、keep_days 日より前の行を folder/log-<時刻>.txt.gz に移す。
    移したファイルを返す（しなければ None）"""
    path = Path(path)
    try:
        if path.stat().st_size <= limit:
            return None
    except OSError:
        return None
    now = now or datetime.datetime.now()
    since = (now.date() - datetime.timedelta(days=keep_days)).isoformat()
    folder = Path(folder)
    target = folder / f"log-{now.strftime('%Y%m%d-%H%M%S')}.txt.gz"
    with lock:
        data = path.read_bytes()
        cut = first_kept(data, since)
        if cut <= 0:
            return None
        folder.mkdir(parents=True, exist_ok=True)
        head, tail = data[:cut], data[cut:]
        part = target.with_name(target.name + ".part")
        with gzip.open(part, "wb") as f:
            f.write(head)
        os.replace(part, target)
        rest = path.with_name(path.name + ".part")
        rest.write_bytes(tail)
        os.replace(rest, path)
    archives = sorted(folder.glob("log-*.txt.gz"))
    for old in archives[:-KEEP_ARCHIVES]:
        try:
            old.unlink()
        except OSError:
            pass
    return target


def db_stats(path: Path) -> dict | None:
    """{"bytes", "pages", "free_pages", "free"（割合）}（読むだけ）。無ければ None"""
    path = Path(path)
    if not path.is_file():
        return None
    try:
        db = sqlite3.connect(f"file:{path.as_posix()}?mode=ro", uri=True, timeout=5)
        try:
            pages = db.execute("PRAGMA page_count").fetchone()[0]
            free = db.execute("PRAGMA freelist_count").fetchone()[0]
        finally:
            db.close()
    except sqlite3.Error:
        return None
    return {"bytes": path.stat().st_size, "pages": pages, "free_pages": free, "free": round(free / pages, 4) if pages else 0.0}


def vacuum_due(stats: dict | None, last: float, now: datetime.datetime) -> bool:
    if not stats or stats["free"] < VACUUM_FREE:
        return False
    return VACUUM_HOURS[0] <= now.hour < VACUUM_HOURS[1] and time.time() - last >= VACUUM_EVERY


def vacuum(path: Path, log: Callable[[str], None]) -> bool:
    """VACUUM する（ほかの書き込みが終わるのを 60 秒まで待つ）。できたら True"""
    before = Path(path).stat().st_size
    try:
        db = sqlite3.connect(str(path), timeout=60)
        try:
            db.execute("VACUUM")
        finally:
            db.close()
    except sqlite3.Error as error:
        log(f"索引を詰められませんでした（次の週にやり直します）: {type(error).__name__}")
        return False
    log(f"索引（{Path(path).name}）を詰めました: {before / 1e6:.0f}MB → {Path(path).stat().st_size / 1e6:.0f}MB")
    return True


def summary_line(log_path: Path, folder: Path, db_path: Path) -> str:
    try:
        size = Path(log_path).stat().st_size
    except OSError:
        size = 0
    archives = sorted(Path(folder).glob("log-*.txt.gz")) if Path(folder).is_dir() else []
    stats = db_stats(db_path)
    db = (f"semantic.db {stats['bytes'] / 1e6:.0f}MB（空き {stats['free']:.0%}。{VACUUM_FREE:.0%} 以上で週 1 回詰めます）"
          if stats else "semantic.db —")
    return (f"記録と索引: log.txt {size / 1e6:.1f}MB（{ROTATE_AT / 1e6:.0f}MB で回す）・回した分 {len(archives)} 個"
            f"（{Path(folder)}）・{db}")
