"""LifeLog PC: 新しい区切りを、夜の読み直し・声の特徴・意味で探す索引づくりより先にする（s21 速3。2026-11-22）。

後で受け取る文字起こし（jobqueue.JobQueue）に、録ってから jobqueue.FRESH_AGE（2 時間）以内の区切りが待っている・
文字にしている最中・待ち合わせで待っている人がいるあいだは、busy() が True を返す。重い裏の仕事はこれを見て譲る:
- quality.py の夜の流れ（審判の合い方・声の特徴・同じ人かも・夜の読み直し）と昼の声の特徴 … 1 分おいて見直す
- knowme.py の重い所（声の調子の音声・自分の声）… 軽いほうだけにする
- mothersearch.py（母艦の文を意味で探す索引）… 重い時間でも、ゆっくりのほうにする
- semantic.py（仕事のまとめの索引）… その回は見送る
- /transcribe（00:00〜06:00。iPhone の夜の聞き直しがほとんど）… 新しい区切りが待っていれば、頭で 30 秒まで待つ（wait_at_night）
古い区切り（時計がまとめて送ってきた何日か前の分）だけが待っているときは譲らない（いつまでも夜の仕事ができなくなるため）。
config.json の "jobs_first": false で譲らない（前と同じ）。
"""

from __future__ import annotations

import time
from typing import Callable

import jobqueue

QUEUE: "jobqueue.JobQueue | None" = None
CONFIG: Callable[[], dict] = lambda: {}  # noqa: E731


def register(queue, config: Callable[[], dict] | None = None) -> None:
    global QUEUE, CONFIG
    QUEUE = queue
    if config is not None:
        CONFIG = config


def busy(now: float | None = None) -> bool:
    queue = QUEUE
    if queue is None:
        return False
    try:
        if (CONFIG() or {}).get("jobs_first") is False:
            return False
    except Exception:  # noqa: BLE001
        pass
    now = time.time() if now is None else now
    with queue.lock:
        if any(count > 0 for count in queue.waiters.values()):
            return True
        for meta in queue.jobs.values():
            if meta.get("status") in ("queued", "working") and now - jobqueue.recorded_at(meta) <= jobqueue.FRESH_AGE:
                return True
    return False


NIGHT_HOURS = (0, 6)     # この時間の /transcribe（iPhone の夜の聞き直しがほとんど）は、新しい区切りを少し先に通す
NIGHT_WAIT = 30.0        # 待つ長さの上限（秒。iPhone は /transcribe を 180 秒まで待つ）


def queued_fresh(now: float | None = None) -> bool:
    """録って 2 時間以内の区切りが、文字にされるのを待っているか（文字にしている最中の 1 つは数えない）"""
    queue = QUEUE
    if queue is None:
        return False
    now = time.time() if now is None else now
    with queue.lock:
        return any(meta.get("status") == "queued" and now - jobqueue.recorded_at(meta) <= jobqueue.FRESH_AGE
                   for meta in queue.jobs.values())


def wait_at_night(hour: int | None = None, limit: float = NIGHT_WAIT, sleep=time.sleep) -> float:
    """00:00〜06:00 の /transcribe の頭で、新しい区切りが待っていれば limit 秒まで待つ。待った秒を返す"""
    try:
        if (CONFIG() or {}).get("jobs_first") is False:
            return 0.0
    except Exception:  # noqa: BLE001
        pass
    hour = time.localtime().tm_hour if hour is None else hour
    if not (NIGHT_HOURS[0] <= hour < NIGHT_HOURS[1]):
        return 0.0
    waited = 0.0
    while waited < limit and queued_fresh():
        sleep(1.0)
        waited += 1.0
    return waited
