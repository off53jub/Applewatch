"""LifeLog PC: s22（2026-11-22）の家の PC の分をまとめてつなぐ所。決まりと確かめ方・測った数は docs/s22-pc.md。

lifelog_pc.py から呼ぶのは start(main)（start_v6 の中。s21pc.start のあと）と FEATURES・GETS・http_get。
summary.md の「## s22 の数」の節は ops.write_summary が summary_lines(...) で足す。0 円・言語モデルの呼び出しは足さない。

つなぐ口（start で入れる。どれも無ければ今までどおり）:
- 記録（POST /records/<日>）を置く前に、行に省ける "conf"（確18）・"norm"（確20）・"mediaNearby"（確10）を足す（records.annotate）
- 後で受け取る文字起こしができたら、区切りの "recExp"（確24）・"levels"（確4）・行の数を HOME/s22/chunks/<日>.jsonl に（on_result）
- 「名前のある人かも」の近さに、いそうな人の重み（確5。voices.PRIOR_BONUS）
- 確かめ待ちの答え（POST /feedback の kind review）を声のかたまりに広げる（確27。appfeeds.REVIEW_HOOK）
- 再生中の情報（確10。s22media.Watcher）
見回り（1 分ごと）:
- 30 分ごと（軽い）: 今日と昨日の札（確7〜確10）・区切りをまたぐ組と人数の組（確3・確6）・家の PC の確かめ待ち（確19・確27）・
  同じ人かの s-norm の写し（確1）・録り方の実験の数（確24）
- 重い仕事の時間（00:00〜05:00・08:30〜18:00）で新しい区切りが待っていないとき: 行の音の大きさ（確9・確4。1 回 90 秒まで）
- 01:00〜05:00 に 1 回: PLAUD と合う行を学び直しの材料に（確16）・職場かどうか分からない割合（確30）・自分の声と音の大きさ（確4）
- 00:00〜05:00: 切り替えたモデルの足りないファイルを取る（確2・確13・確15。s22models）
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

import jobfirst
import judgecheck
import plaudmatch
import quality
import s22feeds
import s22media
import s22models
import s22review
import s22text
import s22voice
import voices

FEATURES = [*s22feeds.FEATURES, "levels", "recexp", "reviewspread"]
GETS = s22feeds.GETS
TICK = 60.0
FIRST_WAIT = 150.0
LIGHT_EVERY = 1800.0
LEVELS_BUDGET = 90.0
HEAVY = ((0, 0, 5, 0), (8, 30, 18, 0))
REC_EXP = ("32k45", "48k45", "32k300", "48k300")
PLAUD_DAILY = 60          # 確16（仮）: 1 日に足す PLAUD と合う行の材料の数
PLAUD_TOTAL = 1500
PLAUD_MATCH = 0.9         # 確16（仮）: 行の文字のうち PLAUD の文と同じ並びで合った割合
PLAUD_MIN_CHARS = 6
PLAUD_ORIGIN = "pc-plaud"
UNNAMED = re.compile(r"人物(\d+)")


class S:
    main = None
    home: Path | None = None
    thread: threading.Thread | None = None
    media: s22media.Watcher | None = None
    next_light = 0.0
    night_day: str | None = None
    lock = threading.Lock()
    last: dict = {}


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
        base = S.main.mothership.home(_config())
        return base if base is not None and Path(base).is_dir() else None
    except Exception:  # noqa: BLE001
        return None


def _store():
    return getattr(getattr(S.main, "App", None), "records", None)


def start(main) -> None:
    S.main = main
    S.home = Path(main.HOME)
    store = _store()
    if store is not None:
        store.annotate = annotate_record
    jobs = getattr(main.App, "jobs", None)
    if jobs is not None:
        before = jobs.on_result

        def both(name: str, meta: dict) -> None:
            if before is not None:
                before(name, meta)
            note_result(name, meta)

        jobs.on_result = both
    voices.PRIOR_BONUS = prior_bonus
    s22text.JUNK_ON = _config().get("junk_votes") is not False
    s22voice.CONFIG = _config
    try:
        import s20feeds

        s20feeds.REVIEW_EXTRA = lambda body, base: s22feeds.merge_review(body, base, S.home)
    except Exception:  # noqa: BLE001
        pass
    try:
        import appfeeds

        appfeeds.REVIEW_HOOK = review_hook
    except Exception:  # noqa: BLE001
        pass
    S.media = s22media.Watcher(S.home, _config, main.log)
    S.media.start()
    if S.thread is None:
        S.thread = threading.Thread(target=_loop, name="s22", daemon=True)
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
                S.main.log(f"s22 の見回りでつまずきました: {type(error).__name__}")
        time.sleep(TICK)


def _days(today: datetime.date, count: int) -> list[str]:
    return [(today - datetime.timedelta(days=i)).isoformat() for i in range(count)][::-1]


def tick(moment: datetime.datetime | None = None) -> dict:
    """1 分ごとの見回り。したことの名前を返す（確かめ用）"""
    moment = moment or datetime.datetime.now()
    now = time.time()
    config = _config()
    home, store, base = S.home, _store(), _base()
    done: dict = {}
    if home is None:
        return done
    if now >= S.next_light:
        S.next_light = now + LIGHT_EVERY
        done["light"] = light(home, store, base, config, moment.date())
    busy = jobfirst.busy()
    if heavy_now(moment) and not busy and store is not None and config.get("s22_levels") is not False:
        done["levels"] = levels_tick(home, store, moment.date())
    if s22models.download_window(moment) and not busy:
        got = s22models.fetch_missing(home, config, S.main.fetch, S.main.log, moment)
        if got:
            done["models"] = got
    day = moment.date().isoformat()
    if 1 <= moment.hour < 5 and S.night_day != day and not busy:
        S.night_day = day
        done["night"] = night(home, store, base, config, moment.date())
    return done


def light(home: Path, store, base: Path | None, config: dict, today: datetime.date) -> dict:
    out: dict = {}
    days = _days(today, 2)
    for day in days:
        parsed = store.day(day) if store is not None else None
        if parsed is None:
            continue
        try:
            got = s22voice.write_chain(home, parsed, day, base, config)
            out[f"chain {day}"] = (got["people"], got["after"], got["chain"], got["count"])
        except Exception as error:  # noqa: BLE001
            out[f"chain {day}"] = type(error).__name__
        try:
            media = (lambda ms: s22media.near(home, ms)) if config.get("media_watch") is not False else None
            got = s22voice.write_tags(home, base, parsed, day, config, media)
            out[f"tags {day}"] = got["counts"]
        except Exception as error:  # noqa: BLE001
            out[f"tags {day}"] = type(error).__name__
    try:
        out["review"] = s22review.build(home, store, base, _days(today, 3))
    except Exception as error:  # noqa: BLE001
        out["review"] = type(error).__name__
    try:
        out["snorm"] = s22voice.export_snorm(home, config)
    except Exception as error:  # noqa: BLE001
        out["snorm"] = type(error).__name__
    try:
        import s22place

        out["place_words"] = s22place.build(home, store, today)["places"]
    except Exception as error:  # noqa: BLE001
        out["place_words"] = type(error).__name__
    try:
        out["recexp"] = rec_exp_days(home, store, today)
    except Exception as error:  # noqa: BLE001
        out["recexp"] = type(error).__name__
    s22media.prune(home, today)
    S.last["light"] = out
    return out


def levels_tick(home: Path, store, today: datetime.date) -> dict:
    deadline = time.time() + LEVELS_BUDGET
    out = {}
    for day in _days(today, 3)[::-1]:
        parsed = store.day(day)
        if parsed is None:
            continue
        got = s22voice.measure_levels(home, parsed, day, quality.find_audio, S.main.load_audio, S.main.RATE, deadline)
        out[day] = got["lines"]
        if got["stopped"] or time.time() > deadline:
            break
    return out


def night(home: Path, store, base: Path | None, config: dict, today: datetime.date) -> dict:
    out: dict = {}
    try:
        out["plaud_samples"] = plaud_samples(home, base, today, config)
    except Exception as error:  # noqa: BLE001
        out["plaud_samples"] = type(error).__name__
    yesterday = (today - datetime.timedelta(days=1)).isoformat()
    parsed = store.day(yesterday) if store is not None else None
    if parsed is not None:
        try:
            work = work_unknown(store, parsed, yesterday, today)
            quality.update_day(home, yesterday, work)
            out["work"] = work
        except Exception as error:  # noqa: BLE001
            out["work"] = type(error).__name__
        try:
            levels = s22voice._read(s22voice.folder(home, "levels") / f"{yesterday}.json", {}) or {}
            sep = s22voice.self_separation(parsed, levels, app_levels(home, yesterday))
            if sep is not None:
                quality.update_day(home, yesterday, {"self_level_auc": sep["auc"], "self_level_gap_db":
                                                     round(sep["self_median"] - sep["others_median"], 1)})
            out["self_level"] = sep
        except Exception as error:  # noqa: BLE001
            out["self_level"] = type(error).__name__
    S.main.log("s22 の夜の数: " + "・".join(f"{k} {v if not isinstance(v, dict) else len(v)}" for k, v in out.items()))
    return out


# MARK: - 記録の行に足す（確18・確20・確10）


def annotate_record(day: str, body: dict) -> dict:
    """POST /records/<日> の中身の行に conf・norm・mediaNearby を足した写し（records.RecordStore.put が呼ぶ）"""
    import records

    config = _config()
    home = S.home
    media_on = home is not None and config.get("media_watch") is not False and \
        bool(s22media.read_day(home, day)["playing"])
    out = dict(body)
    conversations = []
    for conversation in body.get("conversations") or []:
        if not isinstance(conversation, dict):
            conversations.append(conversation)
            continue
        conversation = dict(conversation)
        lines = []
        for line in conversation.get("lines") or []:
            if not isinstance(line, dict):
                lines.append(line)
                continue
            line = s22text.annotate_line(line)
            if media_on:
                try:
                    if s22media.near(home, records.parse_time(line.get("time"), "time")):
                        line["mediaNearby"] = True
                    else:
                        line.pop("mediaNearby", None)
                except ValueError:
                    pass
            lines.append(line)
        conversation["lines"] = lines
        conversations.append(conversation)
    out["conversations"] = conversations
    return out


# MARK: - 区切りごと（確4・確24）


def parse_levels(value) -> dict | None:
    """省ける "levels"（query の JSON か "p10,p50,p90,voicedP50" の並び。dB）"""
    if value is None:
        return None
    if isinstance(value, str):
        value = value.strip()
        try:
            value = json.loads(value) if value.startswith("{") else dict(zip(("p10", "p50", "p90", "voicedP50"),
                                                                              [float(x) for x in value.split(",")]))
        except ValueError:
            return None
    if not isinstance(value, dict):
        return None
    out = {k: round(float(value[k]), 1) for k in ("p10", "p50", "p90", "voicedP50")
           if isinstance(value.get(k), (int, float)) and not isinstance(value.get(k), bool) and -160 <= value[k] <= 20}
    return out or None


def parse_rec_exp(value) -> str | None:
    return value if isinstance(value, str) and value in REC_EXP else None


def note_result(name: str, meta: dict) -> None:
    """でき上がった区切りの実験の組・声の大きさの要約・行の数を日ごとに残す（文は入れない）"""
    if S.home is None or meta.get("status") != "done":
        return
    params = meta.get("params") or {}
    times = meta.get("times") or {}
    start = times.get("chunk_start") if isinstance(times, dict) else None
    moment = start if isinstance(start, (int, float)) else meta.get("queued_at") or time.time()
    day = datetime.datetime.fromtimestamp(float(moment)).date().isoformat()
    row = {"name": name, "exp": params.get("rec_exp"), "levels": params.get("levels"),
           "lines": int(meta.get("lines") or 0), "audio_s": meta.get("audio_seconds"), "voiced_s": meta.get("voiced_seconds")}
    path = S.home / "s22" / "chunks" / f"{day}.jsonl"
    with S.lock:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")


def chunk_rows(home: Path, day: str) -> dict[str, dict]:
    try:
        raw = (Path(home) / "s22" / "chunks" / f"{day}.jsonl").read_text(encoding="utf-8").splitlines()
    except OSError:
        return {}
    out = {}
    for line in raw:
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict) and row.get("name"):
            out[str(row["name"])] = row
    return out


def app_levels(home: Path, day: str) -> dict:
    return {name: row["levels"] for name, row in chunk_rows(home, day).items() if isinstance(row.get("levels"), dict)}


def hourly_exp(diag_folder: Path | None, day: str) -> tuple[dict[int, str], dict[int, float]]:
    """diag の recExpHourly（{時: 組} か [[時刻, 組]…]）と、時計の電池の見本（watchBatteryAt）"""
    hours: dict[int, str] = {}
    battery: dict[int, float] = {}
    if diag_folder is None:
        return hours, battery
    for device in Path(diag_folder).iterdir() if Path(diag_folder).is_dir() else []:
        try:
            raw = (device / f"{day}.jsonl").read_text(encoding="utf-8").splitlines()
        except OSError:
            continue
        for line in raw:
            try:
                record = json.loads(line)
            except ValueError:
                continue
            for holder in (record.get("state"), record.get("detail")):
                if not isinstance(holder, dict):
                    continue
                value = holder.get("recExpHourly")
                if isinstance(value, dict):
                    for hour, combo in value.items():
                        if str(hour).isdigit() and 0 <= int(hour) < 24 and combo in REC_EXP:
                            hours[int(hour)] = combo
                elif isinstance(value, list):
                    for item in value:
                        if isinstance(item, list) and len(item) >= 2 and item[1] in REC_EXP and isinstance(item[0], (int, float)):
                            when = datetime.datetime.fromtimestamp(item[0])
                            if when.date().isoformat() == day:
                                hours[when.hour] = item[1]
                for sample in holder.get("watchBatteryAt") or []:
                    if isinstance(sample, list) and len(sample) >= 2 and all(isinstance(x, (int, float)) for x in sample[:2]):
                        battery[int(sample[0])] = float(sample[1])
    return hours, battery


def rec_exp_days(home: Path, store, today: datetime.date, days: int = 8) -> dict:
    """確24: 日ごと・組ごとの数（区切り・行・声の分・人物N の種類・時間・電池の減り）を HOME/s22/rec-exp.json と
    quality-daily.json の "rec_exp" に置く（母艦の M が報告を作る）"""
    diag_folder = Path(home) / "diag"
    out_days = {}
    for day in _days(today, days):
        rows = chunk_rows(home, day)
        hours, battery = hourly_exp(diag_folder, day)
        if not any(r.get("exp") for r in rows.values()) and not hours:
            continue
        combos: dict[str, dict] = {}
        for name, row in rows.items():
            combo = row.get("exp") or "—"
            entry = combos.setdefault(combo, {"chunks": 0, "lines": 0, "audio_min": 0.0, "voiced_min": 0.0,
                                              "people_kinds": 0, "hours": 0, "battery_per_hour": None})
            entry["chunks"] += 1
            entry["lines"] += int(row.get("lines") or 0)
            entry["audio_min"] += float(row.get("audio_s") or 0) / 60
            entry["voiced_min"] += float(row.get("voiced_s") or 0) / 60
        parsed = store.day(day) if store is not None else None
        people: dict[str, set] = collections.defaultdict(set)
        for conversation in (parsed or {}).get("conversations") or []:
            for line in conversation.get("lines") or []:
                match = UNNAMED.fullmatch(str(line.get("speaker") or ""))
                if match and line.get("audio") in rows:
                    people[rows[line["audio"]].get("exp") or "—"].add(match.group(1))
        for combo, idents in people.items():
            combos.setdefault(combo, {"chunks": 0, "lines": 0, "audio_min": 0.0, "voiced_min": 0.0, "people_kinds": 0,
                                      "hours": 0, "battery_per_hour": None})["people_kinds"] = len(idents)
        points = sorted(battery.items())
        drops: dict[str, list[float]] = collections.defaultdict(list)
        for (t0, l0), (t1, l1) in zip(points, points[1:]):
            combo = hours.get(datetime.datetime.fromtimestamp(t0).hour)
            if combo is None or l1 > l0 or not 600 <= t1 - t0 <= 3 * 3600:
                continue
            drops[combo].append((l0 - l1) / (t1 - t0) * 3600)
        for hour, combo in hours.items():
            entry = combos.setdefault(combo, {"chunks": 0, "lines": 0, "audio_min": 0.0, "voiced_min": 0.0,
                                              "people_kinds": 0, "hours": 0, "battery_per_hour": None})
            entry["hours"] += 1
        for combo, values in drops.items():
            combos[combo]["battery_per_hour"] = round(statistics.median(values), 4)
        for entry in combos.values():
            entry["audio_min"] = round(entry["audio_min"], 1)
            entry["voiced_min"] = round(entry["voiced_min"], 1)
        out_days[day] = combos
        quality.update_day(home, day, {"rec_exp": combos})
    body = {"generated_at": datetime.datetime.now().isoformat(timespec="seconds"), "combos": list(REC_EXP),
            "note": "s22 確24。組は時計の録り方（ビットレート k × 区切りの秒）。「—」は印の無い区切り。電池は割合／時", "days": out_days}
    path = Path(home) / "s22" / "rec-exp.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    part = path.with_name(path.name + ".part")
    part.write_text(json.dumps(body, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(part, path)
    return {d: len(c) for d, c in out_days.items()}


# MARK: - 確5 いそうな人


def prior_bonus(labels: dict, days: list[str]):
    """voices.build から呼ぶ。(人物N の印, 名前のある人の印) → 足す近さ（予定・場所・LINE に出てくる人だけ）"""
    store, base = _store(), _base()
    config = _config()
    bonus = float(s22voice.settings(config)["prior_bonus"])
    if store is None or bonus <= 0 or config.get("people_prior") is False:
        return None
    parsed_days = {d: store.day(d) for d in days}
    parsed_days = {d: p for d, p in parsed_days.items() if p is not None}
    names = s22voice.known_names(list(parsed_days.values()))
    likely: dict[str, set[str]] = {}
    for day, parsed in parsed_days.items():
        history = [p for d, p in parsed_days.items() if d < day]
        got = s22voice.likely_people(base, parsed, day, names, history)
        likely[day] = set().union(*got.values())
    name_of = {k: str(v.get("name") or "") for k, v in labels.items()}

    def score(label: str, ref: str) -> float:
        entry = labels.get(label) or {}
        target = name_of.get(ref) or ""
        return bonus if target and any(target in likely.get(d, set()) for d in entry.get("days") or []) else 0.0

    return score


# MARK: - 確27 答えを広げる


def review_hook(row: dict) -> dict | None:
    if S.home is None:
        return None
    try:
        return s22review.spread(S.home, _store(), _base(), row, _config(), S.main.log)
    except Exception as error:  # noqa: BLE001 — 広げられなくても答えは母艦に置く
        S.main.log(f"確かめ待ちの答えを広げられませんでした: {type(error).__name__}")
        return None


# MARK: - 確16 PLAUD と合う行を材料に


def plaud_samples(home: Path, base: Path | None, today: datetime.date, config: dict) -> int:
    """昨日〜3 日前の後で受け取る文字起こしの行のうち、PLAUD の文とよく合う行を、学び直しの材料に足す（自動の材料として）"""
    main = S.main
    if base is None or config.get("plaud_samples") is False:
        return 0
    rows = main.read_samples(main.PERSONAL_DATA)
    mine = [r for r in rows if isinstance(r.get("source"), dict) and r["source"].get("origin") == PLAUD_ORIGIN]
    stamp = today.isoformat()
    room = min(PLAUD_DAILY - sum(1 for r in mine if str(r.get("added") or "").startswith(stamp)), PLAUD_TOTAL - len(mine))
    if room <= 0:
        return 0
    wanted = {(today - datetime.timedelta(days=i)).isoformat() for i in range(1, 4)}
    by_day: dict[str, list] = collections.defaultdict(list)
    for path in sorted((Path(home) / "jobs").glob("*.result"), reverse=True):
        try:
            result = json.loads(path.read_text(encoding="utf-8"))
            meta = json.loads(path.with_suffix(".json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        name = str(meta.get("id") or "")
        begin = judgecheck.chunk_epoch(name)
        if begin is None:
            continue
        for line in result.get("lines") or []:
            try:
                start, end = float(line["start"]), float(line["end"])
            except (KeyError, TypeError, ValueError):
                continue
            day = datetime.datetime.fromtimestamp(begin + start).strftime("%Y-%m-%d")
            if day in wanted:
                by_day[day].append((begin + start, start, end, str(line.get("text") or ""), name, path))
    added = 0
    for day in sorted(by_day, reverse=True):
        recs, _ = plaudmatch._timed(Path(home), Path(base), day)
        if not recs:
            continue
        for moment, start, end, text, name, path in by_day[day]:
            if added >= room:
                break
            normed = judgecheck.norm(text)
            if not 2.0 <= end - start <= main.SAMPLE_MAX or len(normed) < PLAUD_MIN_CHARS:
                continue
            ref = judgecheck.reference(recs, moment)
            if ref is None or plaudmatch.matched(normed, ref) / len(normed) < PLAUD_MATCH:
                continue
            audio_path = path.with_suffix(".audio")
            if not audio_path.is_file():
                continue
            try:
                audio = main.load_audio(audio_path.read_bytes())
                _, put = main.save_sample(main.PERSONAL_DATA, audio, start, end, text.strip(),
                                          {"origin": PLAUD_ORIGIN, "auto": True, "job": name[:80], "offset": round(start, 2),
                                           "plaud": round(plaudmatch.matched(normed, ref) / len(normed), 3)})
            except (ValueError, OSError):
                continue
            added += put
    if added:
        main.log(f"  PLAUD と合う行の材料（仮）: {added} 個足しました（1 日の上限 {PLAUD_DAILY}）")
    return added


# MARK: - 確30 職場かどうか分からない


def work_unknown(store, parsed: dict, day: str, today: datetime.date, history_days: int = 14) -> dict:
    """その日の会話の「職場かどうか分からない」の数と割合、場所・時間から見当が付く数（数えるだけ・しきい値は仮）"""
    work_places: collections.Counter = collections.Counter()
    for back in range(1, history_days + 1):
        old = store.day((today - datetime.timedelta(days=back)).isoformat())
        for conversation in (old or {}).get("conversations") or []:
            if conversation.get("work") is True and conversation.get("place"):
                work_places[str(conversation["place"])] += 1
    total = unknown = by_place = by_time = 0
    for conversation in parsed.get("conversations") or []:
        total += 1
        if conversation.get("work") is not None:
            continue
        unknown += 1
        if work_places.get(str(conversation.get("place") or "")) and work_places[str(conversation["place"])] >= 2:
            by_place += 1
            continue
        start = conversation.get("start")
        if isinstance(start, int):
            moment = datetime.datetime.fromtimestamp(start / 1000)
            if moment.weekday() < 5 and 9 <= moment.hour < 19:
                by_time += 1
    return {"work_unknown": unknown, "work_unknown_share": round(unknown / total, 3) if total else None,
            "work_guess_place": by_place, "work_guess_time": by_time}


# MARK: - summary.md


def _read_json(path: Path, default=None):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def summary_lines(diag_store=None, now: float | None = None) -> tuple[list[str], list[str]]:
    home = S.home
    if home is None:
        return [], []
    today = datetime.date.fromtimestamp(now or time.time())
    lines: list[str] = []
    worries: list[str] = []

    def chain_line():
        parts = []
        for day in _days(today, 3):
            body = _read_json(s22voice.folder(home, "chain") / f"{day}.json")
            if isinstance(body, dict):
                parts.append(f"{day[5:]} 人物N {body.get('people')} 人→つなぐと {body.get('after')} 人"
                             f"（区切りをまたぐ組 {body.get('chain')}・人数の組 {body.get('count')}）")
        return "区切りをまたいで声をつなぐ候補（確3・確6。自動ではまとめない）: " + "・".join(parts) if parts else None

    def tags_line():
        parts = []
        for day in _days(today, 3):
            body = _read_json(s22voice.folder(home, "speaker-tags") / f"{day}.json")
            if isinstance(body, dict):
                counts = body.get("counts") or {}
                parts.append(f"{day[5:]} 通りすがり {body.get('passerby_people', 0)} 人・重なり {counts.get('overlap', 0)}・"
                             f"遠い声 {counts.get('far', 0)}・動画の声かも {counts.get('media', 0)}")
        return "話し手の札（確7〜確10。消さない・札だけ）: " + "・".join(parts) if parts else None

    def snorm_line():
        body = _read_json(Path(home) / "same-person" / "snorm.json", {}) or {}
        items = body.get("items") or {}
        if not items:
            return None
        values = [v.get("snorm") for v in items.values() if isinstance(v.get("snorm"), (int, float))]
        short = sum(1 for v in items.values() if v.get("short"))
        low = s22voice.settings(_config())["snorm_min"]
        hidden = sum(1 for v in values if isinstance(low, (int, float)) and v < low)
        return (f"同じ人かの点（s-norm・仮）: 組 {len(items)}・点あり {len(values)}・短い声で点なし {short}・"
                f"{low} より低くて出さない {hidden}")

    def review_line():
        body = _read_json(s22review.folder(home) / "items.json", {}) or {}
        counts = collections.Counter(i.get("kind") for i in body.get("items") or [] if isinstance(i, dict))
        if not counts:
            return None
        return "家の PC の確かめ待ち（確19・確27）: " + "・".join(f"{k} {v}" for k, v in counts.items())

    def recexp_line():
        body = _read_json(Path(home) / "s22" / "rec-exp.json", {}) or {}
        days = body.get("days") or {}
        if not days:
            return "録り方の実験（確24）: 印の付いた区切りはまだありません（アプリの入れ替えがオンになると数えます）"
        parts = []
        for day in sorted(days)[-3:]:
            parts.append(f"{day[5:]} " + "／".join(
                f"{combo} 区切り {e.get('chunks', 0)}・人物N {e.get('people_kinds', 0)}・{e.get('hours', 0)} 時間"
                + (f"・電池 {e['battery_per_hour']:.1%}/時" if isinstance(e.get('battery_per_hour'), (int, float)) else "")
                for combo, e in sorted(days[day].items())))
        return "録り方の実験（確24・組ごと。HOME/s22/rec-exp.json）: " + "・".join(parts)

    def media_line():
        parts = []
        for day in _days(today, 2):
            got = s22media.day_counts(home, day)
            if got["playing_min"] or got["active_min"]:
                parts.append(f"{day[5:]} 再生 {got['playing_min']} 分・PC を触っていた {got['active_min']} 分")
        return "PC の再生中の時間（確10。アプリの名前と時刻だけ）: " + "・".join(parts) if parts else None

    def daily_line():
        days = quality.read_daily(home)["days"]
        parts = []
        for day in _days(today, 4)[:-1]:
            entry = days.get(day) or {}
            bits = []
            if isinstance(entry.get("work_unknown_share"), (int, float)):
                bits.append(f"職場か分からない {entry['work_unknown_share']:.0%}（{entry.get('work_unknown', 0)} 件・"
                            f"場所で見当 {entry.get('work_guess_place', 0)}・時間で見当 {entry.get('work_guess_time', 0)}）")
            if isinstance(entry.get("self_level_auc"), (int, float)):
                bits.append(f"自分の声と音の大きさの AUC {entry['self_level_auc']}（差 {entry.get('self_level_gap_db')} dB）")
            if bits:
                parts.append(f"{day[5:]} " + "・".join(bits))
        return "確30・確4（仮）: " + " / ".join(parts) if parts else None

    def samples_line():
        try:
            rows = S.main.read_samples(S.main.PERSONAL_DATA)
        except Exception:  # noqa: BLE001
            return None
        plaud = sum(1 for r in rows if isinstance(r.get("source"), dict) and r["source"].get("origin") == PLAUD_ORIGIN)
        return f"学び直しの材料: 全部 {len(rows)} 個（PLAUD と合う行から {plaud} 個。確16）"

    def models_line():
        config = _config()
        missing = s22models.wanted(home, config)
        return (f"モデルの切り替え（確2・確13・確15）: 話し手 {s22models.speaker_choice(config)}・雑音除去 "
                f"{s22models.enhance_choice(config)}・足すモデル {','.join(s22models.asr_extra(config)) or 'なし'}"
                + (f"（まだ無いファイル {len(missing)} 個。00:00〜05:00 に取ります）" if missing else ""))

    def device_line():
        """アプリ（A1・PR #97）の省ける様子: launchToToday {last,median,n}・ipadReader・deviceChecksManual・
        時計の finishedRecent・muffledToday。来ていなければ書かない"""
        if diag_store is None:
            return None
        parts = []
        for record in diag_store.devices():
            state = record.get("state") if isinstance(record.get("state"), dict) else {}
            bits = []
            launch = state.get("launchToToday")
            if isinstance(launch, dict) and isinstance(launch.get("median"), (int, float)):
                bits.append(f"開いてから今日の画面まで 真ん中 {launch['median']:.1f} 秒（最後 {launch.get('last')}・{launch.get('n')} 回）")
            if isinstance(state.get("ipadReader"), bool):
                bits.append("iPad の読むだけの形" + ("（オン）" if state["ipadReader"] else "（オフ）"))
            for key, label in (("deviceChecksManual", "実機の確かめ（手で）"), ("finishedRecent", "時計の最近の録り終わり"),
                               ("muffledToday", "時計のこもった音（今日）")):
                value = state.get(key)
                if isinstance(value, (int, float)) and not isinstance(value, bool):
                    bits.append(f"{label} {value}")
                elif isinstance(value, (list, dict)):
                    bits.append(f"{label} {len(value)} 件")
            if bits:
                parts.append(f"{str(record.get('device') or record.get('deviceID') or '端末')[:20]}: " + "・".join(bits))
        return "アプリの省ける様子（s22 A1）: " + " / ".join(parts) if parts else None

    for name, make in (("device", device_line), ("chain", chain_line), ("tags", tags_line), ("snorm", snorm_line), ("review", review_line),
                       ("recexp", recexp_line), ("media", media_line), ("daily", daily_line), ("samples", samples_line),
                       ("models", models_line)):
        try:
            text = make()
            if text:
                lines.append(f"- {text}")
        except Exception as error:  # noqa: BLE001 — 1 つ書けなくても、ほかは書く
            lines.append(f"- （{name} を数えられませんでした: {type(error).__name__}）")
    return worries, lines


def http_get(handler, path: str, query: str) -> None:
    s22feeds.http_get(handler, path, query, _base(), S.home, S.main.log if S.main else (lambda _m: None))
