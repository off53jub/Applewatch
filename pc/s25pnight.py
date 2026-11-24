"""LifeLog PC: s25（2026-11-24。担当 P）の測りと夜の時間割。0 円・言語モデルは呼ばない。数だけ（文・名前は記録に書かない）。

- 早2: 夜の測り（s22pc.night・s23pc.night・s24pc.night・quality.run_night と、s25 の夜の分）のかかった時間を夜ごとに数える
  （HOME/s25p/night-times.json）。直近 3 晩の中央値の合計が 01:00〜05:00 の 4 時間に収まらない晩は、
  THIN_ORDER の順（あとから足した・効きの軽い測りから。quality＝審判・声の名寄せ・同じ人かも・夜の読み直しは間引かない）に
  その晩は動かさない。config.json の "s25p_night_thin": false で間引かない（数えるのは続ける）。初めはオン（仮）。
  合計は糸ごとの時間の足し算（同時に動く分も足す＝CPU の重さの目安）。
- 早1・早3: 区切りごとの段の待ち（録音の終わり→iPhone・iPhone で持っていた・iPhone→PC・PC の列・PC の作業・下書き）を
  日ごと・時計／iPhone ごとに中央値で（HOME/s25p/stages.json）。いちばん長い段に印。iPhone→PC は長さの段ごとの数と、
  まとめて届いた割合（60 秒以内に続けて受けた区切り）も数える（早3。Wi-Fi 待ちかどうかは PC からは見えない＝仮説のまま）。
- K6（堅4）: 1 日 1 回（12 時台・仮）、静かな APNs（kind "ping"）を送る。その日のうちにアプリの様子（diag の tally
  "s25.ping.got"）に返ったかを見て、quality-daily.json の "s25p_ping_sent"・"s25p_ping_got" と summary.md に。
  "s25p_ping": false で止める。初めはオン（見えない通知なので本人への知らせは増えない）。
- 大3: マイクの見直しの測り（夜・3 日前まで）。同じ時間に PLAUD・iPhone・時計の音が重なっている分で、時計と iPhone の行が
  PLAUD の文とどれだけ合うか（合った字の割合）・声の秒（区切りの voiced_seconds）・1 分あたりの字を比べる（HOME/s25p/mic.json）。
  3 日たまったら「主にする音」の候補を summary.md に 1 行。切り替えは自動ではしない。
- 連16: 母艦の archive/line の「☎ 通話時間」を読み、その時間に重なる会話に、その部屋の名前を相手の候補として出す
  （HOME/s25p/line-calls.json と母艦 inbox/pc-line-calls/s25p_call_candidates.json。候補だけ・名前は付け替えない）。
- 大9（材料）: 会話に名前のある相手が付いた割合（日ごと）と、付いていない会話の候補の数（通話・声の近い人）を HOME/s25p/partner.json に。
"""

from __future__ import annotations

import datetime
import json
import os
import re
import statistics
import threading
import time
from pathlib import Path

NIGHT_WINDOW = 4 * 3600.0
THIN_ORDER = ("s25p_mic", "s24", "s23", "s22")   # 間引く順（仮）
NEVER_THIN = ("quality", "s25p_train")
HISTORY_NIGHTS = 3
KEEP_NIGHTS = 21
PING_HOUR = 12
STAGE_DAYS = 14
STAGES = (("rec_to_phone", "録音の終わり→iPhone"), ("phone_hold", "iPhone で持っていた"), ("to_pc", "iPhone→PC"),
          ("pc_wait", "PC の列"), ("pc_work", "PC の作業"), ("draft", "下書きまで"))
TO_PC_BUCKETS = ((60, "1 分未満"), (600, "1〜10 分"), (3600, "10〜60 分"), (float("inf"), "1 時間より長い"))
BATCH_GAP = 60.0
MIC_DAYS = 3
MIC_MIN_OVERLAP = 30          # 仮: 候補を出すのに要る重なりの分（3 日の合計）
CALL = re.compile(r"^- \*\*(\d{1,2}):(\d{2})\*\* [^:：]{0,40}[:：] ☎ 通話時間 (\d{1,2}):(\d{2})(?::(\d{2}))?\s*$")
ROOM = re.compile(r"^## (.{1,60})$")
CALL_SLACK = 120.0
UNNAMED = re.compile(r"人物\d+")
_lock = threading.Lock()


def folder(home: Path) -> Path:
    return Path(home) / "s25p"


def _read(path: Path, default=None):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def _write(path: Path, body) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    part = path.with_name(path.name + ".part")
    part.write_text(json.dumps(body, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(part, path)


def _epoch(value) -> float | None:
    """ISO 8601 の文か、記録の読み込み（records.parse_record）のミリ秒 → 1970 年からの秒"""
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return float(value) / 1000.0 if value > 1e11 else float(value)
    try:
        return datetime.datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
    except (TypeError, ValueError):
        return None


# MARK: - 早2 夜の時間割


class Night:
    home: Path | None = None
    config = staticmethod(lambda: {})
    clock = staticmethod(time.time)


def night_key(now: float) -> str:
    """その晩の名前（01:00〜05:00 の日付。0 時台は同じ日に数える）"""
    return datetime.date.fromtimestamp(now).isoformat()


def record_time(home: Path, name: str, seconds: float, ended: float) -> None:
    key = night_key(ended)
    with _lock:
        path = folder(home) / "night-times.json"
        body = _read(path, {}) or {}
        nights = body.get("nights") if isinstance(body.get("nights"), dict) else {}
        entry = nights.setdefault(key, {})
        row = entry.setdefault(name, {"seconds": 0.0, "runs": 0})
        row["seconds"] = round(float(row.get("seconds") or 0) + seconds, 1)
        row["runs"] = int(row.get("runs") or 0) + 1
        row["ended"] = datetime.datetime.fromtimestamp(ended).strftime("%H:%M")
        for old in sorted(nights)[:-KEEP_NIGHTS]:
            nights.pop(old, None)
        body["nights"] = nights
        _write(path, body)


def record_skip(home: Path, name: str, now: float) -> None:
    key = night_key(now)
    with _lock:
        path = folder(home) / "night-times.json"
        body = _read(path, {}) or {}
        nights = body.get("nights") if isinstance(body.get("nights"), dict) else {}
        entry = nights.setdefault(key, {})
        skipped = entry.setdefault("_skipped", [])
        if name not in skipped:
            skipped.append(name)
        body["nights"] = nights
        _write(path, body)


def estimates(home: Path, before: str) -> dict[str, float]:
    """名前 → 直近 HISTORY_NIGHTS 晩（before より前・間引いていない晩）の秒の中央値"""
    nights = (_read(folder(home) / "night-times.json", {}) or {}).get("nights") or {}
    seen: dict[str, list[float]] = {}
    for key in sorted(nights, reverse=True):
        if key >= before:
            continue
        for name, row in nights[key].items():
            if name.startswith("_") or not isinstance(row, dict):
                continue
            values = seen.setdefault(name, [])
            if len(values) < HISTORY_NIGHTS:
                values.append(float(row.get("seconds") or 0))
    return {k: statistics.median(v) for k, v in seen.items() if v}


def thin_plan(est: dict[str, float], window: float = NIGHT_WINDOW, order=THIN_ORDER) -> list[str]:
    """収まらなければ、order の順に外す名前の並び（収まれば空）"""
    total = sum(est.values())
    dropped: list[str] = []
    for name in order:
        if total <= window:
            break
        if name in est:
            total -= est[name]
            dropped.append(name)
    return dropped


def should_skip(home: Path, name: str, config: dict, now: float) -> bool:
    if name in NEVER_THIN or config.get("s25p_night_thin") is False:
        return False
    est = estimates(home, night_key(now))
    if len(est) < 2:
        return False
    return name in thin_plan(est)


def timed(name: str, original):
    """夜の測りを包む（かかった時間を数え、間引く晩は動かさない）"""

    def run(*args, **kwargs):
        home = Night.home
        if home is None:
            return original(*args, **kwargs)
        now = Night.clock()
        try:
            skip = should_skip(home, name, Night.config() or {}, now)
        except Exception:  # noqa: BLE001
            skip = False
        if skip:
            record_skip(home, name, now)
            return {"s25p_skipped": True}
        started = time.time()
        try:
            return original(*args, **kwargs)
        finally:
            spent = time.time() - started
            if spent >= 1.0 or name != "quality":   # quality は 5 分ごとに呼ばれて、済んだ段は飛ばすので短いものは数えない
                try:
                    record_time(home, name, spent, Night.clock())
                except OSError:
                    pass

    run.s25p_wrapped = True  # type: ignore[attr-defined]
    return run


def install(home: Path, config) -> list[str]:
    """s22pc・s23pc・s24pc の night と quality.run_night を包む。包んだ名前"""
    Night.home, Night.config = Path(home), config
    done = []
    for name, module_name, attr in (("s22", "s22pc", "night"), ("s23", "s23pc", "night"), ("s24", "s24pc", "night"),
                                    ("quality", "quality", "run_night")):
        try:
            module = __import__(module_name)
            original = getattr(module, attr)
            if getattr(original, "s25p_wrapped", False):
                continue
            setattr(module, attr, timed(name, original))
            done.append(name)
        except Exception:  # noqa: BLE001
            continue
    return done


def night_summary(home: Path, today: datetime.date) -> dict:
    nights = (_read(folder(home) / "night-times.json", {}) or {}).get("nights") or {}
    last = sorted(nights)[-1] if nights else None
    entry = nights.get(last) or {}
    rows = {k: v for k, v in entry.items() if not k.startswith("_") and isinstance(v, dict)}
    total = sum(float(v.get("seconds") or 0) for v in rows.values())
    ended = max((str(v.get("ended") or "") for v in rows.values()), default="")
    return {"night": last, "total": total, "rows": rows, "skipped": entry.get("_skipped") or [], "ended": ended,
            "plan": thin_plan(estimates(home, (today + datetime.timedelta(days=1)).isoformat()))}


# MARK: - 早1・早3 段ごとの待ち


def job_metas(home: Path) -> list[dict]:
    out = []
    for path in (Path(home) / "jobs").glob("*.json"):
        meta = _read(path, None)
        if isinstance(meta, dict) and meta.get("status") == "done":
            out.append(meta)
    return out


def _span(a, b) -> float | None:
    if isinstance(a, (int, float)) and isinstance(b, (int, float)) and not isinstance(a, bool) and b >= a - 5:
        return max(0.0, float(b) - float(a))
    return None


def stages_for(metas: list[dict], days: set[str]) -> dict:
    """{日: {"watch"|"iphone": {段: {"median","p90","count"}}, "to_pc_buckets": {...}, "batched": 割合, "longest": 段}}"""
    spans: dict = {}
    received: dict = {}
    for meta in metas:
        times = meta.get("times") or {}
        end = times.get("chunk_end") or times.get("chunk_start")
        if not isinstance(end, (int, float)):
            continue
        day = datetime.date.fromtimestamp(float(end)).isoformat()
        if day not in days:
            continue
        device = "watch" if str(meta.get("id") or "").endswith("-w.m4a") else "iphone"
        route = "direct" if meta.get("origin") == "watch" else "phone"
        values = {"rec_to_phone": _span(times.get("chunk_end"), times.get("arrived")),
                  "phone_hold": _span(times.get("arrived"), times.get("sent")),
                  "to_pc": _span(times.get("sent"), meta.get("queued_at")),
                  "pc_wait": _span(meta.get("queued_at"), meta.get("started_at")),
                  "pc_work": _span(meta.get("started_at"), meta.get("done_at")),
                  "draft": _span(meta.get("started_at"), meta.get("draft_at")),
                  "total": _span(times.get("chunk_end"), meta.get("done_at"))}
        bucket = spans.setdefault(day, {}).setdefault(device, {})
        for key, value in values.items():
            if value is not None:
                bucket.setdefault(key, []).append(value)
        if route == "phone" and isinstance(meta.get("queued_at"), (int, float)):
            received.setdefault(day, []).append((float(meta["queued_at"]), values["to_pc"]))
    out: dict = {}
    for day, devices in spans.items():
        entry: dict = {}
        for device, bucket in devices.items():
            entry[device] = {k: {"median": round(statistics.median(v), 1),
                                 "p90": round(sorted(v)[min(len(v) - 1, int(len(v) * 0.9))], 1), "count": len(v)}
                             for k, v in bucket.items()}
        main = entry.get("iphone") or entry.get("watch") or {}
        parts = {k: v["median"] for k, v in main.items() if k in dict(STAGES) and k != "draft"}
        entry["longest"] = max(parts, key=parts.get) if parts else None
        rows = sorted(received.get(day) or [])
        counts = {label: 0 for _, label in TO_PC_BUCKETS}
        for _, span in rows:
            if span is None:
                continue
            for limit, label in TO_PC_BUCKETS:
                if span < limit:
                    counts[label] += 1
                    break
        entry["to_pc_buckets"] = counts
        batched = sum(1 for i, (t, _) in enumerate(rows)
                      if (i > 0 and t - rows[i - 1][0] <= BATCH_GAP) or (i + 1 < len(rows) and rows[i + 1][0] - t <= BATCH_GAP))
        entry["batched"] = round(batched / len(rows), 3) if rows else None
        entry["phone_jobs"] = len(rows)
        out[day] = entry
    return out


def update_stages(home: Path, today: datetime.date) -> int:
    days = {(today - datetime.timedelta(days=i)).isoformat() for i in range(STAGE_DAYS)}
    body = _read(folder(home) / "stages.json", {}) or {}
    got = stages_for(job_metas(home), days)
    stored = body.get("days") if isinstance(body.get("days"), dict) else {}
    stored.update(got)
    limit = (today - datetime.timedelta(days=30)).isoformat()
    stored = {k: v for k, v in stored.items() if k >= limit}
    _write(folder(home) / "stages.json", {"generated_at": datetime.datetime.now().isoformat(timespec="seconds"),
                                          "note": "s25 早1・早3（数だけ・秒）", "days": stored})
    return len(got)


# MARK: - K6 静かな試し


def ping_got(home: Path, day: str) -> bool:
    for path in (Path(home) / "diag").glob("*/latest.json"):
        tally = (_read(path, {}) or {}).get("tally")
        counts = tally.get(day) if isinstance(tally, dict) else None
        if isinstance(counts, dict) and isinstance(counts.get("s25.ping.got"), (int, float)) and counts["s25.ping.got"] > 0:
            return True
    return False


def ping_tick(home: Path, pusher, config: dict, moment: datetime.datetime) -> dict | None:
    """12 時台に 1 回送る。その日の返りも見る。したこと（無ければ None）"""
    if config.get("s25p_ping") is False:
        return None
    import quality

    path = folder(home) / "ping.json"
    body = _read(path, {}) or {}
    days = body.get("days") if isinstance(body.get("days"), dict) else {}
    day = moment.date().isoformat()
    entry = days.get(day) or {}
    out = None
    if not entry.get("sent_at") and moment.hour == PING_HOUR and pusher is not None:
        try:
            ready = pusher.ready()
        except Exception:  # noqa: BLE001
            ready = False
        if ready:
            results = pusher.send("ping")
            ok = sum(1 for r in results if isinstance(r, dict) and r.get("ok"))
            entry = {"sent_at": moment.isoformat(timespec="seconds"), "sent": ok, "tried": len(results)}
            quality.update_day(home, day, {"s25p_ping_sent": ok})
            out = {"sent": ok}
    if entry.get("sent") and not entry.get("got") and ping_got(home, day):
        entry["got"] = True
        quality.update_day(home, day, {"s25p_ping_got": True})
        out = {**(out or {}), "got": True}
    if out is not None:   # 変わったときだけ書く（1 分ごとに呼ばれる）
        days[day] = entry
        for old in sorted(days)[:-30]:
            days.pop(old, None)
        _write(path, {"days": days})
    return out


# MARK: - 大3 マイクの見直し


def _minutes(a: float, b: float) -> range:
    return range(int(a // 60), int(b // 60) + 1)


def mic_day(home: Path, base: Path, day: str, metas: list[dict] | None = None, parsed: dict | None = None) -> dict | None:
    """その日の、PLAUD と重なる分の時計・iPhone の比べ（PLAUD の録音が無い日は None）"""
    import judgecheck
    import plaudmatch

    recs, _ = plaudmatch._timed(Path(home), Path(base), day)
    if not recs:
        return None
    plaud_min: set[int] = set()
    plaud_chars: dict[int, int] = {}
    for rec in recs:
        t0 = rec["t0"]
        for block in rec["blocks"]:
            plaud_min.update(_minutes(t0 + block["t"], t0 + block["end"]))
            minute = int((t0 + block["t"]) // 60)
            plaud_chars[minute] = plaud_chars.get(minute, 0) + len(block["n"])
    device_min: dict[str, set[int]] = {"watch": set(), "iphone": set()}
    voiced: dict[str, dict[int, float]] = {"watch": {}, "iphone": {}}
    for meta in metas if metas is not None else job_metas(home):
        times = meta.get("times") or {}
        start, end = times.get("chunk_start"), times.get("chunk_end")
        if not isinstance(start, (int, float)) or not isinstance(end, (int, float)) or end <= start:
            continue
        if datetime.date.fromtimestamp(float(start)).isoformat() != day:
            continue
        device = "watch" if str(meta.get("id") or "").endswith("-w.m4a") else "iphone"
        mins = list(_minutes(float(start), float(end) - 1))
        device_min[device].update(mins)
        share = float(meta.get("voiced_seconds") or 0) / max(1, len(mins))
        for m in mins:
            voiced[device][m] = voiced[device].get(m, 0.0) + share
    if parsed is None:
        try:
            parsed = json.loads((Path(home) / "records" / f"{day}.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            parsed = {}
    lines: dict[str, list[tuple[float, str]]] = {"watch": [], "iphone": []}
    for conversation in (parsed or {}).get("conversations") or []:
        if not isinstance(conversation, dict) or conversation.get("media"):
            continue
        for line in conversation.get("lines") or []:
            if not isinstance(line, dict) or line.get("media") or not isinstance(line.get("audio"), str):
                continue
            t = _epoch(line.get("time"))
            if t is None:
                continue
            device = "watch" if line["audio"].endswith("-w.m4a") else "iphone"
            lines[device].append((t, judgecheck.norm(str(line.get("text") or ""))))
    both = plaud_min & device_min["watch"] & device_min["iphone"]
    out: dict = {"minutes": {"plaud": len(plaud_min), "watch": len(device_min["watch"]), "iphone": len(device_min["iphone"]),
                             "all3": len(both)}, "devices": {}, "all3": {}}
    for scope, chosen in (("devices", None), ("all3", both)):
        for device in ("watch", "iphone"):
            overlap = plaud_min & device_min[device] if chosen is None else chosen
            if not overlap:
                continue
            chars = matched = 0
            for t, n in lines[device]:
                if int(t // 60) not in overlap or len(n) < plaudmatch.MIN_CHARS:
                    continue
                ref = judgecheck.reference(recs, t)
                if ref is None:
                    continue
                chars += len(n)
                matched += plaudmatch.matched(n, ref)
            out[scope][device] = {"overlap_min": len(overlap), "chars": chars, "matched": matched,
                                  "match": round(matched / chars, 3) if chars else None,
                                  "voiced_s": round(sum(voiced[device].get(m, 0.0) for m in overlap), 1),
                                  "chars_per_min": round(chars / len(overlap), 1),
                                  "plaud_chars_per_min": round(sum(plaud_chars.get(m, 0) for m in overlap) / len(overlap), 1)}
    return out


def mic_nightly(home: Path, base: Path, today: datetime.date) -> dict:
    path = folder(home) / "mic.json"
    body = _read(path, {}) or {}
    days = body.get("days") if isinstance(body.get("days"), dict) else {}
    metas = job_metas(home)
    done = {}
    for back in range(1, MIC_DAYS + 1):   # PLAUD は遅れて届くので 3 日前まで数え直す
        day = (today - datetime.timedelta(days=back)).isoformat()
        got = mic_day(home, base, day, metas)
        if got is not None:
            days[day] = got
            done[day] = got["minutes"]["all3"]
    limit = (today - datetime.timedelta(days=30)).isoformat()
    days = {k: v for k, v in days.items() if k >= limit}
    _write(path, {"generated_at": datetime.datetime.now().isoformat(timespec="seconds"),
                  "note": "s25 大3（仮）。数だけ。切り替えはしない", "days": days})
    return done


def mic_candidate(home: Path, today: datetime.date, need_days: int = MIC_DAYS) -> dict:
    """直近 14 日の、PLAUD と重なる分の合計で比べる。{"days","watch","iphone","pick","plaud_first"}"""
    days = (_read(folder(home) / "mic.json", {}) or {}).get("days") or {}
    limit = (today - datetime.timedelta(days=14)).isoformat()
    total = {"watch": {"overlap_min": 0, "chars": 0, "matched": 0, "voiced_s": 0.0, "plaud": 0.0},
             "iphone": {"overlap_min": 0, "chars": 0, "matched": 0, "voiced_s": 0.0, "plaud": 0.0}}
    used = 0
    for day, entry in days.items():
        if day < limit or not isinstance(entry, dict):
            continue
        rows = entry.get("devices") or {}
        if rows:
            used += 1
        for device, row in rows.items():
            if device in total and isinstance(row, dict):
                t = total[device]
                t["overlap_min"] += int(row.get("overlap_min") or 0)
                t["chars"] += int(row.get("chars") or 0)
                t["matched"] += int(row.get("matched") or 0)
                t["voiced_s"] += float(row.get("voiced_s") or 0)
                t["plaud"] += float(row.get("plaud_chars_per_min") or 0) * int(row.get("overlap_min") or 0)
    for t in total.values():
        t["match"] = round(t["matched"] / t["chars"], 3) if t["chars"] else None
        t["cover"] = round(t["chars"] / t["plaud"], 3) if t["plaud"] else None   # PLAUD の字のうち、その音から出た字の割合（目安）
    ok = [d for d, t in total.items() if t["overlap_min"] >= MIC_MIN_OVERLAP and t["match"] is not None]
    pick = None
    if used >= need_days and ok:
        pick = max(ok, key=lambda d: (total[d]["match"] or 0) * (min(1.0, total[d]["cover"] or 0) or 0.01))
    plaud_first = bool(pick) and all((total[d]["cover"] or 0) < 0.5 for d in ok)
    return {"days": used, **total, "pick": pick, "plaud_first": plaud_first}


# MARK: - 連16 LINE の通話


def line_calls(base: Path, day: str) -> list[dict]:
    """その日の LINE の「☎ 通話時間」: [{"room", "at"(この PC の時刻の秒), "seconds"}]"""
    path = Path(base) / "archive" / "line" / day[:4] / day[5:7] / f"{day[8:10]}.md"
    try:
        text = path.read_text(encoding="utf-8-sig")
    except OSError:
        return []
    out, room = [], None
    for line in text.splitlines():
        head = ROOM.match(line)
        if head:
            room = head.group(1).strip()
            continue
        match = CALL.match(line.strip())
        if not match or not room:
            continue
        h, m = int(match[1]), int(match[2])
        a, b, c = int(match[3]), int(match[4]), match[5]
        seconds = a * 3600 + b * 60 + int(c) if c is not None else a * 60 + b
        at = datetime.datetime.strptime(day, "%Y-%m-%d").replace(hour=min(h, 23), minute=m).timestamp()
        out.append({"room": room, "at": at, "seconds": seconds})
    return out


def call_candidates(base: Path, day: str, parsed: dict | None) -> list[dict]:
    """通話の時間（記録の時刻は通話の終わりか始まりか分からないので、前後どちらにも長さぶん広げる）に重なる会話"""
    out = []
    calls = [c for c in line_calls(base, day) if c["seconds"] >= 30]
    for conversation in (parsed or {}).get("conversations") or []:
        if not isinstance(conversation, dict) or conversation.get("media"):
            continue
        start, end = _epoch(conversation.get("start")), _epoch(conversation.get("end"))
        if start is None:
            continue
        end = end if end is not None and end >= start else start
        names = {line.get("speaker") for line in conversation.get("lines") or [] if isinstance(line, dict)}
        for call in calls:
            low, high = call["at"] - call["seconds"] - CALL_SLACK, call["at"] + call["seconds"] + CALL_SLACK
            if start <= high and end >= low:
                out.append({"day": day, "conversation_start": conversation.get("start"), "room": call["room"],
                            "call_seconds": call["seconds"],
                            "call_at": datetime.datetime.fromtimestamp(call["at"]).strftime("%H:%M"),
                            "already": call["room"] in names,
                            "unnamed": sorted(n for n in names if isinstance(n, str) and UNNAMED.fullmatch(n))})
    return out


def calls_nightly(home: Path, base: Path, store, today: datetime.date) -> int:
    items = []
    for back in range(1, 4):
        day = (today - datetime.timedelta(days=back)).isoformat()
        parsed = store.day(day) if store is not None else None
        items.extend(call_candidates(base, day, parsed))
    body = {"version": 1, "generated_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
            "note": "s25 連16。LINE の通話の時間に重なる会話の、相手の名前の候補（候補だけ・付け替えない）", "items": items}
    _write(folder(home) / "line-calls.json", body)
    try:
        _write(Path(base) / "inbox" / "pc-line-calls" / "s25p_call_candidates.json", body)
    except OSError:
        pass
    return len(items)


# MARK: - 大9 相手の付き方の材料


def partner_day(parsed: dict | None) -> dict:
    total = named = only_unnamed = 0
    for conversation in (parsed or {}).get("conversations") or []:
        if not isinstance(conversation, dict) or conversation.get("media"):
            continue
        names = {line.get("speaker") for line in conversation.get("lines") or []
                 if isinstance(line, dict) and line.get("media") is None and isinstance(line.get("speaker"), str)}
        others = {n for n in names if n != "自分"}
        if not others:
            continue
        total += 1
        if any(not UNNAMED.fullmatch(n) for n in others):
            named += 1
        else:
            only_unnamed += 1
    return {"conversations": total, "named": named, "only_unnamed": only_unnamed,
            "rate": round(named / total, 3) if total else None}


def partner_update(home: Path, store, today: datetime.date) -> dict:
    days = {}
    calls = (_read(folder(home) / "line-calls.json", {}) or {}).get("items") or []
    maybe = (_read(Path(home) / "same-person" / "voices.json", {}) or {}).get("maybe") or []
    for back in range(0, 7):
        day = (today - datetime.timedelta(days=back)).isoformat()
        parsed = store.day(day) if store is not None else None
        if parsed is None:
            continue
        entry = partner_day(parsed)
        entry["call_candidates"] = sum(1 for c in calls if isinstance(c, dict) and c.get("day") == day and not c.get("already"))
        entry["voice_maybe"] = sum(1 for m in maybe if isinstance(m, dict) and m.get("day") == day)
        days[day] = entry
    _write(folder(home) / "partner.json", {"generated_at": datetime.datetime.now().isoformat(timespec="seconds"),
                                           "note": "s25 大9 の材料（数だけ）", "days": days})
    return days
