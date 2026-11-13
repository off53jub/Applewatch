"""LifeLog PC: 品質の記録と夜の流れ（施策 9・10・11。2026-11-13）。

- HOME\\quality-daily.json（母艦の 12「精度の通信簿」が読む。共通の約束の形）:
  {"version": 1, "days": {"YYYY-MM-DD": {"judge_calls": int, "judge_agree_plaud": float|null,
   "night_review_items": int, "same_person_groups": int, "promise_alerts": int}}}
  書くときは必ず読んでから、自分の項目だけを置き換える（ほかの担当の項目・知らない項目は残す）。60 日より古い日は消す。
- 夜の流れ（01:00〜05:00 に1回。重い仕事をしてよい夜の枠の中）: 昨日の分について
  1. judge_calls（帳簿の asr-judge の回数）と judge_agree_plaud（judgecheck.py。昨日〜3日前を測り直す）
  2. 同じ人かも（sameperson.py）→ same_person_groups
  3. 夜の読み直し（nightreview.py）→ night_review_items
  どれが失敗しても、ほかは続ける。済んだ日は HOME\\quality-night.json に覚える（同じ夜に2回しない）。
- GET /same-person（features の "sameperson"。?refresh=1 で今日と昨日を裏で作り直す）・GET /night-review（"nightreview"）。
"""

from __future__ import annotations

import datetime
import json
import os
import threading
import time
from pathlib import Path
from typing import Callable
from urllib.parse import parse_qs

import claude
import judgecheck
import nightreview
import sameperson

FILE = "quality-daily.json"
NIGHT_FILE = "quality-night.json"
KEEP_DAYS = 60
NIGHT_START, NIGHT_END = 1, 5     # 01:00〜05:00（記録がそろうのを少し待つ）
CHECK_EVERY = 600.0
AGREE_BACK = 3                    # 審判と PLAUD の合い方は、PLAUD が遅れて届くので 3 日前まで測り直す
GETS = ("/same-person", "/night-review")
FIELDS = ("judge_calls", "judge_agree_plaud", "night_review_items", "same_person_groups", "promise_alerts")

_lock = threading.Lock()


class State:
    home: Path | None = None
    store = None
    jobs = None
    base: Callable[[], Path] | None = None
    embed: Callable | None = None
    log: Callable[[str], None] = staticmethod(lambda _m: None)
    thread: threading.Thread | None = None
    refreshing = False


# MARK: - quality-daily.json


def path(home: Path) -> Path:
    return Path(home) / FILE


def read_daily(home: Path) -> dict:
    try:
        data = json.loads(path(home).read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return {"version": 1, "days": {}}
    if not isinstance(data, dict) or not isinstance(data.get("days"), dict):
        return {"version": 1, "days": {}}
    return data


def update_day(home: Path, day: str, values: dict, now: datetime.date | None = None) -> dict:
    """その日の項目を置き換える（読んでから書く。ほかの項目は残す）。書いたあとの全体を返す"""
    with _lock:
        data = read_daily(home)
        days = data["days"]
        entry = days.get(day) if isinstance(days.get(day), dict) else {}
        entry.update(values)
        days[day] = entry
        limit = ((now or datetime.date.today()) - datetime.timedelta(days=KEEP_DAYS)).isoformat()
        for old in [d for d in days if isinstance(d, str) and d < limit]:
            days.pop(old, None)
        data["version"] = data.get("version") or 1
        target = path(home)
        target.parent.mkdir(parents=True, exist_ok=True)
        part = target.with_name(target.name + ".part")
        part.write_text(json.dumps(data, ensure_ascii=False, sort_keys=True), encoding="utf-8")
        os.replace(part, target)
        return data


# MARK: - 夜の流れ


def _night_done(home: Path) -> dict:
    try:
        data = json.loads((Path(home) / NIGHT_FILE).read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _mark_done(home: Path, day: str, step: str) -> None:
    with _lock:
        data = _night_done(home)
        data.setdefault(day, {})[step] = int(time.time())
        for old in sorted(data)[:-30]:
            data.pop(old, None)
        target = Path(home) / NIGHT_FILE
        part = target.with_name(target.name + ".part")
        part.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
        os.replace(part, target)


def find_audio(name: str) -> Path | None:
    """行の音声（HOME/audio に移したもの。無ければ、まだ後で受け取る文字起こしの所にあるもの）"""
    if State.store is not None:
        found = State.store.audio_file(name)
        if found is not None:
            return found
    if State.jobs is not None:
        try:
            candidate = State.jobs.audio_path(name)
            if candidate.is_file():
                return candidate
        except Exception:  # noqa: BLE001
            return None
    return None


def judge_stats(home: Path, day: str, base: Path | None) -> dict:
    values: dict = {"judge_calls": claude.LEDGER.day_calls(day, claude.JUDGE_PURPOSE)}
    if base is not None:
        try:
            values["judge_agree_plaud"] = judgecheck.measure(Path(home), base, [day])[day]["agree"]
        except Exception:  # noqa: BLE001 — 測れなければ null
            values["judge_agree_plaud"] = None
    return values


def run_night(today: datetime.date | None = None, steps: tuple = ("judge", "sameperson", "night")) -> dict:
    """昨日の分の夜の流れ（済んだ段は飛ばす）。数だけを返す"""
    home = State.home
    if home is None:
        return {}
    today = today or datetime.date.today()
    day = (today - datetime.timedelta(days=1)).isoformat()
    done = _night_done(home).get(day, {})
    log = State.log
    out: dict = {}
    if "judge" in steps and "judge" not in done:
        try:
            base = State.base() if State.base else None
            for back in range(1, AGREE_BACK + 1):
                d = (today - datetime.timedelta(days=back)).isoformat()
                values = judge_stats(home, d, base)
                if back > 1:
                    # 前の日は、測れたときだけ合い方を足す（回数は前の夜に書いてある）
                    values = {k: v for k, v in values.items() if k == "judge_agree_plaud" and v is not None}
                if values:
                    update_day(home, d, values)
            out["judge"] = True
            _mark_done(home, day, "judge")
        except Exception as error:  # noqa: BLE001
            log(f"品質の記録（審判）を書けませんでした: {type(error).__name__}")
    if "sameperson" in steps and "sameperson" not in done and State.embed is not None:
        try:
            groups = sameperson.run_day(home, State.store, day, find_audio, State.embed, log)
            if groups is not None:
                update_day(home, day, {"same_person_groups": groups})
                out["sameperson"] = groups
            _mark_done(home, day, "sameperson")
        except Exception as error:  # noqa: BLE001
            log(f"同じ人かもを作れませんでした: {type(error).__name__}")
    if "night" in steps and "night" not in done:
        try:
            items = nightreview.run_day(home, State.store, day, log)
            if items is not None:
                update_day(home, day, {"night_review_items": items})
                out["night"] = items
            _mark_done(home, day, "night")
        except Exception as error:  # noqa: BLE001
            log(f"夜の読み直しをできませんでした: {type(error).__name__}")
    return out


def in_window(moment: datetime.datetime) -> bool:
    return NIGHT_START <= moment.hour < NIGHT_END


def _loop() -> None:
    while True:
        try:
            if in_window(datetime.datetime.now()):
                run_night()
        except Exception as error:  # noqa: BLE001 — 夜の流れが止まっても、受け付けは続ける
            State.log(f"夜の流れ: {type(error).__name__}")
        time.sleep(CHECK_EVERY)


def start(home: Path, store, jobs, base: Callable[[], Path] | None, embed: Callable | None,
          log: Callable[[str], None]) -> None:
    """夜の流れを始める（lifelog_pc.py の start_v6 から）。store（記録）が無ければ始めない"""
    State.home, State.store, State.jobs, State.base, State.embed, State.log = Path(home), store, jobs, base, embed, log
    if store is None or State.thread is not None:
        return
    State.thread = threading.Thread(target=_loop, name="quality-night", daemon=True)
    State.thread.start()


def features() -> list[str]:
    if State.home is None or State.store is None:
        return []
    found = ["nightreview"]
    if State.embed is not None:
        found.insert(0, "sameperson")
    return found


# MARK: - GET /same-person・/night-review


def refresh_same_person() -> bool:
    """今日と昨日の「同じ人かも」を裏で作り直す（作り直している最中なら何もしない）。始めたら True"""
    if State.refreshing or State.home is None or State.embed is None or State.store is None:
        return False
    State.refreshing = True

    def work() -> None:
        try:
            today = datetime.date.today()
            for back in (0, 1):
                d = (today - datetime.timedelta(days=back)).isoformat()
                groups = sameperson.run_day(State.home, State.store, d, find_audio, State.embed, State.log)
                if groups is not None:
                    update_day(State.home, d, {"same_person_groups": groups})
        except Exception as error:  # noqa: BLE001
            State.log(f"同じ人かもを作り直せませんでした: {type(error).__name__}")
        finally:
            State.refreshing = False

    threading.Thread(target=work, name="same-person", daemon=True).start()
    return True


def http_get(handler, url) -> None:
    """認証は呼ぶ側（lifelog_pc.py）が済ませてから"""
    if State.home is None:
        handler.send_json(200, {"available": False, "reason": "記録の機能が動いていません"})
        return
    try:
        if url.path == "/same-person":
            query = parse_qs(url.query or "")
            started = (query.get("refresh") or ["0"])[0] == "1" and refresh_same_person()
            body = sameperson.read(State.home)
            if started or State.refreshing:
                body["refreshing"] = True
            handler.send_json(200, body)
        else:
            handler.send_json(200, nightreview.read(State.home))
    except Exception as error:  # noqa: BLE001
        handler.send_json(500, {"error": f"読めませんでした: {type(error).__name__}"})
