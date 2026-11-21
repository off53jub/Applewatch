"""LifeLog PC: s21（2026-11-22）の家の PC の分をまとめてつなぐ所。決まりと確かめ方は docs/s21-pc.md。

lifelog_pc.py から呼ぶのは start(main)（start_v6 の中。後で受け取る文字起こしを作ったあと）と FEATURES だけ。
summary.md の「## s21 の数」の節は ops.write_summary が summary_lines(...) で足す。

裏の仕事（TICK＝1 分ごとに見る。最初は FIRST_WAIT 秒おく）:
- 速4: 10 分ごとに、糸ごとの CPU の秒（threadcpu.py）を HOME/load-threads.json に足す（"load_meter": false で止める）
- 速9: 1 時間ごとに log.txt を回す・週 1 回 semantic.db の空きを詰める（housekeep.py。"housekeep": false で止める）
- 精1: 01:00〜05:00 に 1 回、昨日〜3 日前の PLAUD との文字の合い方を quality-daily.json に（plaudmatch.py）
- 精10: 00:00〜05:00 に、前から 7 日たっていれば、モデルごとの当たり率と重み（仮）を HOME/engine-weights.json に（plaudmatch.py）
- 精15: 重い仕事の時間帯に、PC の版が変わっていれば正解集の点数を出す（goldset.py）
  精1・精10・精15 は、新しい区切りが待っているあいだ（jobfirst.busy()）はしない。
受け口（jobqueue の on_failed・on_result）:
- 速8: 失敗を理由ごとに HOME/job-failures.json（{"days": {日: {理由: 数}}}。14 日）に数える
- 精7: sampleNoVoice=1 の区切りが文字になったら、quality-daily.json の今日に "novoice_sampled"（数）と
  "novoice_had_voice"（行が 1 つでもあった数＝本当は声があった）を足す
数えるだけ・文の中身は書かない。
"""

from __future__ import annotations

import collections
import datetime
import json
import os
import re
import statistics
import threading
import time
from pathlib import Path

import goldset
import housekeep
import jobfirst
import plaudmatch
import quality
import threadcpu

FEATURES = ["shake", "novoicesample"]
TICK = 60.0
FIRST_WAIT = 120.0
THREADS_EVERY = 600.0
ROTATE_EVERY = 3600.0
FAILURES_FILE = "job-failures.json"
KEEP_DAYS = 14
SUMMARY_DAYS = 7
DIAG_CACHE_TODAY = 1800.0   # 今日の実機の様子の日ごとの数え直しの間（秒）
HEAVY = ((0, 0, 5, 0), (8, 30, 18, 0))
PERSON = re.compile(r"人物(\d+)")


class S:
    main = None
    home: Path | None = None
    thread: threading.Thread | None = None
    meter: threadcpu.Meter | None = None
    next_threads = 0.0
    next_rotate = 0.0
    vacuum_at = 0.0
    night_day: str | None = None
    lock = threading.Lock()
    diag_cache: dict = {}
    people_cache: dict = {}


def heavy_now(moment: datetime.datetime) -> bool:
    minute = moment.hour * 60 + moment.minute
    return any(a * 60 + b <= minute < c * 60 + d for a, b, c, d in HEAVY)


def _config() -> dict:
    try:
        return S.main.load_config() or {}
    except Exception:  # noqa: BLE001
        return {}


def _base() -> Path | None:
    try:
        return S.main.mothership.home(_config())
    except Exception:  # noqa: BLE001
        return None


def start(main) -> None:
    S.main = main
    S.home = Path(main.HOME)
    jobs = getattr(main.App, "jobs", None)
    if jobs is not None:
        jobfirst.register(jobs, main.load_config)
        jobs.on_failed = note_failed
        jobs.on_result = note_result
    S.meter = threadcpu.Meter(S.home)
    if S.thread is None:
        S.thread = threading.Thread(target=_loop, name="s21", daemon=True)
        S.thread.start()


def _loop() -> None:
    time.sleep(FIRST_WAIT)
    failed_at = 0.0
    while True:
        try:
            tick()
        except Exception as error:  # noqa: BLE001 — 裏の仕事が止まっても、受け付けは続ける
            if time.time() - failed_at > 3600:
                failed_at = time.time()
                S.main.log(f"s21 の見回りでつまずきました: {type(error).__name__}")
        time.sleep(TICK)


def tick(moment: datetime.datetime | None = None) -> dict:
    """1 分ごとの見回り。したことの名前を返す（確かめ用）"""
    moment = moment or datetime.datetime.now()
    now = time.time()
    config = _config()
    home = S.home
    done: dict = {}
    if home is None:
        return done
    if config.get("load_meter") is not False and S.meter is not None and now >= S.next_threads:
        S.next_threads = now + THREADS_EVERY
        S.meter.add(S.meter.sample(), moment.date().isoformat())
        done["threads"] = True
    if config.get("housekeep") is not False and now >= S.next_rotate:
        S.next_rotate = now + ROTATE_EVERY
        moved = housekeep.rotate_log(S.main.LOG, getattr(S.main, "LOG_LOCK", threading.Lock()), home / "logs", moment)
        if moved is not None:
            S.main.log(f"記録（log.txt）の {housekeep.KEEP_DAYS} 日より前の分を {moved.name} に移しました")
            done["rotate"] = moved.name
        stats = housekeep.db_stats(S.main.SEMANTIC_DB)
        if housekeep.vacuum_due(stats, S.vacuum_at, moment) and not jobfirst.busy():
            S.vacuum_at = now
            done["vacuum"] = housekeep.vacuum(S.main.SEMANTIC_DB, S.main.log)
    if jobfirst.busy():
        return done
    base = _base()
    day = moment.date().isoformat()
    if 1 <= moment.hour < 5 and S.night_day != day and base is not None and base.is_dir():
        S.night_day = day
        got = plaudmatch.nightly(home, base, moment.date(), quality.update_day)
        S.main.log("PLAUD との文字の合い方: " + ("・".join(f"{d[5:]} {v:.0%}" if v is not None else f"{d[5:]} —"
                                                     for d, v in got.items()) or "測れる日がありません"))
        done["plaud"] = got
    if moment.hour < 5 and base is not None and base.is_dir() and config.get("engine_weights_measure") is not False:
        body = plaudmatch.weekly(home, base, moment)
        if body is not None:
            S.main.log("モデルごとの当たり率（PLAUD と比べた週 1・仮）: " + "・".join(
                f"{k} {v['rate']:.0%}→重み {v['weight']}" for k, v in body["engines"].items() if v.get("rate") is not None))
            done["engines"] = True
    if heavy_now(moment) and config.get("goldset") is not False:
        done["goldset"] = run_goldset()
    return done


def run_goldset() -> dict | None:
    main = S.main
    engine = getattr(main.Handler, "engine", None)
    try:
        import ops

        fake = bool(ops.O.settings.get("fake"))
    except Exception:  # noqa: BLE001
        fake = False
    if engine is None or fake:
        return None
    found = goldset.items(main.PERSONAL_DATA)
    if not goldset.due(S.home, main.BUILD, len(found)):
        return None

    def transcribe(audio):
        length = len(audio) / main.RATE
        segments = [(start, min(length, start + main.MAX_SEGMENT)) for start in
                    [i * main.MAX_SEGMENT for i in range(int(length // main.MAX_SEGMENT) + 1)] if start < length - 0.2]
        return engine.transcribe(audio, segments or [(0.0, length)], votes=True)

    return goldset.score(S.home, main.PERSONAL_DATA, main.BUILD, transcribe, jobfirst.busy, main.log)


# MARK: - 受け口（jobqueue から）


def _read(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"days": {}}
    return data if isinstance(data, dict) and isinstance(data.get("days"), dict) else {"days": {}}


def note_failed(reason: str) -> None:
    """速8: 失敗を理由ごとに数える"""
    if S.home is None:
        return
    path = S.home / FAILURES_FILE
    day = datetime.date.today().isoformat()
    with S.lock:
        data = _read(path)
        entry = data["days"].setdefault(day, {})
        entry[reason] = int(entry.get(reason, 0)) + 1
        limit = (datetime.date.today() - datetime.timedelta(days=KEEP_DAYS)).isoformat()
        for old in [d for d in data["days"] if d < limit]:
            data["days"].pop(old, None)
        part = path.with_name(path.name + ".part")
        part.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
        os.replace(part, path)


def note_result(name: str, meta: dict) -> None:
    """精7: 印の付いた「声が無いはずの区切り」が本当に声が無かったかを数える"""
    if S.home is None or not (meta.get("params") or {}).get("sample_no_voice") or meta.get("status") != "done":
        return
    had = int(meta.get("lines") or 0) > 0
    quality.add_today({"novoice_sampled": 1, "novoice_had_voice": 1 if had else 0}, S.home)


# MARK: - summary.md


def _days(today: datetime.date, count: int = SUMMARY_DAYS) -> list[str]:
    return [(today - datetime.timedelta(days=i)).isoformat() for i in range(count)][::-1]


def plaud_line(home: Path, today: datetime.date) -> str:
    days = quality.read_daily(home)["days"]
    parts = []
    for day in _days(today):
        entry = days.get(day) or {}
        value = entry.get("plaud_match")
        parts.append(f"{day[5:]} " + (f"{value:.0%}（{entry.get('plaud_match_lines', 0)} 行）"
                                       if isinstance(value, (int, float)) else "—"))
    return "PLAUD との文字の合い方（行の文字のうち PLAUD と合った割合。毎晩・言語モデルなし）: " + "・".join(parts)


def novoice_line(home: Path, today: datetime.date) -> str | None:
    days = quality.read_daily(home)["days"]
    rows = [(d, days.get(d) or {}) for d in _days(today)]
    if not any(e.get("novoice_sampled") for _, e in rows):
        return None
    return "時計が「声が無い」と捨てるはずの区切り（印つきで送られた分）: " + "・".join(
        f"{d[5:]} {e.get('novoice_sampled', 0)} 個（声があった {e.get('novoice_had_voice', 0)}）"
        for d, e in rows if e.get("novoice_sampled"))


def failures_line(home: Path, today: datetime.date) -> str:
    data = _read(home / FAILURES_FILE)["days"]
    total: collections.Counter = collections.Counter()
    for day in _days(today):
        total.update(data.get(day) or {})
    if not total:
        return "PC の仕事の失敗（7 日・理由ごと）: ありません"
    return "PC の仕事の失敗（7 日・理由ごと・多い順）: " + "・".join(f"{k} {v}" for k, v in total.most_common(8))


def engines_line(home: Path) -> str | None:
    data = plaudmatch.read_weights(home)
    engines = data.get("engines") if isinstance(data.get("engines"), dict) else {}
    parts = [f"{k} {v['rate']:.1%}（{v.get('lines', 0)} 行・重み {v.get('weight', 1.0)}）"
             for k, v in sorted(engines.items()) if isinstance(v, dict) and isinstance(v.get("rate"), (int, float))]
    if not parts:
        return None
    return f"モデルごとの当たり率（PLAUD と比べた {data.get('days', 7)} 日・{str(data.get('at') or '')[:10]}・重みは仮）: " \
           + "・".join(parts)


def gold_line(home: Path) -> str:
    scored = goldset.lines_for_summary(home)
    if scored:
        return "正解集（本人が直した行）の誤りの割合（版ごと。小さいほど良い）: " + " / ".join(scored)
    return (f"正解集（本人が直した行）: {len(goldset.items(S.main.PERSONAL_DATA))} 個"
            "（PC の版が変わったら、重い仕事の時間帯に点数を出します）")


def people_counts(home: Path, day: str) -> dict | None:
    """その日の記録の「人物N」の数と、いちばん大きい番号（記録が変わったときだけ数え直す）"""
    path = Path(home) / "records" / f"{day}.json"
    try:
        stamp = path.stat().st_mtime
    except OSError:
        return None
    cached = S.people_cache.get(str(path))
    if cached and cached[0] == stamp:
        return cached[1]
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    seen: set[int] = set()
    for conv in data.get("conversations") or [] if isinstance(data, dict) else []:
        for line in conv.get("lines") or [] if isinstance(conv, dict) else []:
            match = PERSON.fullmatch(str(line.get("speaker") or "")) if isinstance(line, dict) else None
            if match:
                seen.add(int(match[1]))
    result = {"count": len(seen), "max": max(seen) if seen else None}
    S.people_cache[str(path)] = (stamp, result)
    return result


def people_line(home: Path, today: datetime.date) -> str | None:
    parts = []
    days = _days(today, SUMMARY_DAYS + 1)
    previous = None   # 前の日までに出たいちばん大きい番号
    for index, day in enumerate(days):
        got = people_counts(home, day)
        if got is None:
            continue
        if index > 0:
            grew = f"・番号 +{max(0, got['max'] - previous)}" if got["max"] is not None and previous is not None else ""
            parts.append(f"{day[5:]} {got['count']} 人{grew}")
        if got["max"] is not None:
            previous = got["max"] if previous is None else max(previous, got["max"])
    if not parts:
        return None
    return "名前の無い人物N（日ごと: その日に出た人数・新しく振られた番号の数）: " + "・".join(parts)


# 電1・電2・守1・守5: 端末の日ごとの様子（diag の日ごとの履歴から）


def _device_day(path: Path) -> dict:
    """その日の履歴の、時計の電池の見本・止まりかけ・実験の組・版"""
    out = {"battery": {}, "stalls": None, "resumed": None, "route": collections.Counter(), "watch_build": None,
           "phone_build": None}
    try:
        handle = path.open(encoding="utf-8")
    except OSError:
        return out
    with handle:
        for raw in handle:
            try:
                record = json.loads(raw)
            except ValueError:
                continue
            state = record.get("state") if isinstance(record.get("state"), dict) else {}
            for sample in state.get("watchBatteryAt") or []:
                if isinstance(sample, list) and len(sample) >= 2 and all(isinstance(x, (int, float)) for x in sample[:2]):
                    out["battery"][int(sample[0])] = float(sample[1])
            for key, field in (("stalls", "watchStalls"), ("resumed", "watchAutoResumed")):
                value = state.get(field)
                if isinstance(value, int) and not isinstance(value, bool):
                    out[key] = value if out[key] is None else max(out[key], value)
            route = state.get("watchRouteExp")
            if route in ("direct", "phone"):
                out["route"][route] += 1
            if state.get("watchBuild") is not None:
                out["watch_build"] = str(state["watchBuild"])
            if record.get("build") is not None:
                out["phone_build"] = str(record["build"])
    return out


def device_days(folder: Path, days: list[str]) -> dict[str, dict]:
    """日 → その日の様子（終わった日は 1 回だけ数える。今日は DIAG_CACHE_TODAY 秒ごと）"""
    out = {}
    today = datetime.date.today().isoformat()
    for day in days:
        path = Path(folder) / f"{day}.jsonl"
        try:
            stamp = path.stat().st_mtime
        except OSError:
            continue
        key = str(path)
        cached = S.diag_cache.get(key)
        fresh = cached and (cached[0] == stamp or (day == today and time.time() - cached[2] < DIAG_CACHE_TODAY))
        if not fresh:
            cached = (stamp, _device_day(path), time.time())
            S.diag_cache[key] = cached
        out[day] = cached[1]
    return out


def hourly_drop(samples: dict[int, float], day: str) -> float | None:
    """その日の、充電していないあいだの 1 時間あたりの減り（割合。見本の間の減りの真ん中）"""
    points = sorted(samples.items())
    rates = []
    for (t0, l0), (t1, l1) in zip(points, points[1:]):
        if datetime.datetime.fromtimestamp(t1).strftime("%Y-%m-%d") != day or t1 - t0 < 600 or t1 - t0 > 3 * 3600:
            continue
        if l1 > l0:   # 増えた＝充電していた
            continue
        rates.append((l0 - l1) / (t1 - t0) * 3600)
    return round(statistics.median(rates), 4) if rates else None


def device_lines(diag_store, today: datetime.date) -> tuple[list[str], list[str]]:
    """(気になる所, 行)"""
    worries, lines = [], []
    if diag_store is None:
        return worries, lines
    import diag

    for record in diag_store.devices():
        device = record.get("deviceID")
        received = diag.parse_time(record.get("receivedAt"))
        if not device or received is None or time.time() - received > diag.RETIRED:
            continue
        name = diag.label(record)
        days = _days(today)
        got = device_days(diag_store.folder / device, days)
        if not got:
            continue
        battery: dict[int, float] = {}
        for entry in got.values():
            battery.update(entry["battery"])
        drops = [(d, hourly_drop(battery, d), got[d]["route"].most_common(1)[0][0] if got[d]["route"] else None)
                 for d in days if d in got]
        if any(v is not None for _, v, _ in drops):
            lines.append(f"{name} 時計の電池の 1 時間あたりの減り（充電していない間の真ん中）: " + "・".join(
                f"{d[5:]} " + (f"{v:.1%}" if v is not None else "—") + (f"（{route}）" if route else "")
                for d, v, route in drops))
        if any(route for _, _, route in drops):
            by_route: dict[str, list[float]] = collections.defaultdict(list)
            for _, v, route in drops:
                if route and v is not None:
                    by_route[route].append(v)
            lines.append(f"{name} 送り方の実験（PC に直接 direct・iPhone 経由 phone）の日ごとの減りの真ん中: " + "・".join(
                f"{route} {statistics.median(vs):.1%}（{len(vs)} 日）" for route, vs in sorted(by_route.items())))
        recent = [d for d in days[-3:] if d in got and got[d]["stalls"] is not None]
        if recent:
            lines.append(f"{name} 時計の止まりかけ（3 日）: " + "・".join(
                f"{d[5:]} {got[d]['stalls']} 回（自動で戻せた {got[d]['resumed'] if got[d]['resumed'] is not None else '—'}）"
                for d in recent))
        state = record.get("state") if isinstance(record.get("state"), dict) else {}
        watch_build, phone_build = state.get("watchBuild"), record.get("build")
        if watch_build is not None and phone_build is not None:
            same = str(watch_build).strip() == str(phone_build).strip()
            lines.append(f"{name} 版: iPhone {phone_build}・時計 {watch_build}" + ("（同じ）" if same else "（ずれています）"))
            if not same:
                worries.append(f"- {name}: iPhone の版 {phone_build} と時計の版 {watch_build} がずれています"
                               "（時計のアプリが入れ替わっていないかもしれません）")
    return worries, lines


def shake_line(base: Path | None, today: datetime.date) -> str | None:
    """使10: 振って「いまの画面が変」と送られた数（7 日。母艦の inbox/app_feedback.jsonl の kind shake）"""
    if base is None:
        return None
    try:
        rows = (Path(base) / "inbox" / "app_feedback.jsonl").read_text(encoding="utf-8").splitlines()
    except OSError:
        return None
    since = _days(today)[0]
    counts: collections.Counter = collections.Counter()
    screens: collections.Counter = collections.Counter()
    for raw in rows[-5000:]:
        try:
            row = json.loads(raw)
        except ValueError:
            continue
        if isinstance(row, dict) and row.get("kind") == "shake" and str(row.get("at") or "")[:10] >= since:
            counts[str(row["at"])[:10]] += 1
            screens[str(row.get("screen") or "—")[:40]] += 1
    if not counts:
        return None
    return (f"振って送られた「いまの画面が変」（7 日）: {sum(counts.values())} 件（"
            + "・".join(f"{d[5:]} {n}" for d, n in sorted(counts.items())) + "）・画面: "
            + "・".join(f"{s} {n}" for s, n in screens.most_common(5)))


def summary_lines(diag_store=None, now: float | None = None) -> tuple[list[str], list[str]]:
    """(気になる所の行, 「## s21 の数」の節の行)。ops.write_summary が呼ぶ"""
    home = S.home
    if home is None:
        return [], []
    today = datetime.date.fromtimestamp(now or time.time())
    lines: list[str] = []
    worries: list[str] = []
    safe = [("plaud", lambda: [plaud_line(home, today)]),
            ("engines", lambda: [engines_line(home)]),
            ("gold", lambda: [gold_line(home)]),
            ("people", lambda: [people_line(home, today)]),
            ("novoice", lambda: [novoice_line(home, today)]),
            ("failures", lambda: [failures_line(home, today)]),
            ("threads", lambda: [threadcpu.summary_line(home)]),
            ("housekeep", lambda: [housekeep.summary_line(S.main.LOG, home / "logs", S.main.SEMANTIC_DB)]),
            ("shake", lambda: [shake_line(_base(), today)])]
    for _name, make in safe:
        try:
            lines.extend(f"- {text}" for text in make() if text)
        except Exception as error:  # noqa: BLE001 — 1 つ書けなくても、ほかは書く
            lines.append(f"- （{_name} を数えられませんでした: {type(error).__name__}）")
    try:
        found, device = device_lines(diag_store, today)
        worries.extend(found)
        lines.extend(f"- {text}" for text in device)
    except Exception as error:  # noqa: BLE001
        lines.append(f"- （端末の日ごとの様子を数えられませんでした: {type(error).__name__}）")
    return worries, lines
