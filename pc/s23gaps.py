"""LifeLog PC: s23 続4・届7・止1 の受け口（2026-11-23）。家の PC のデータで数えるだけ。0 円・言語モデルなし。

続4 PLAUD と合わない分の最多「抜け」（母艦の Build-MismatchTypes.py の 34%）が、どの段で落ちたか（日ごと・PLAUD の文字数）:
- 抜け＝PLAUD の発話（8 字以上）の 2 文字の並びが、その時間（前後 MISS_WINDOW 秒）の記録の行に 12% も含まれないもの（母艦と同じ決まり）。
- 段（上から先に当たったもの）:
    not_recorded  録れていない      … その時刻を覆う区切り（jobs の chunk_start〜audio_seconds）が無い
    novoice       声が無いと捨てた（見立て）… 区切りの間の穴が区切り 1〜2 個ぶんで、その日に時計が「声が無いので捨てた」がある
                                    （時計は捨てた区切りの時刻を送らないので、時刻からの見立て。仮）
    no_text       文字にならなかった … 区切りはあるのに、PC の文字起こし（jobs の .result）にもその発話が無い
    dropped_after 記録で落とした    … PC の文字起こしにはある（含まれ率 5 割以上）のに、記録（records。正本の元）に無い
    unknown       分からない        … 区切りはあるが、文字起こしの結果がもう消えている
- 置き場所: quality-daily.json のその日の "plaud_miss_stages"（{"blocks","chars","not_recorded",…}。文字数）。文は出さない。
届7 版ごとの「1 日に録れた時間」:
- 日ごとに、録れた時間（分。時計は diag の watchRecordedToday の日の最大、iPhone は jobs の audio_seconds の和）と、その日の終わりの版
  （アプリ build・時計 watchBuild・家の PC の BUILD）を quality-daily.json の "recorded_min"・"builds" に置く。
- 版を上げたあと、新しい版の日（終わった日）の平均が前の版の平均より DROP_SHARE（3 割・仮）以上少なければ、summary.md の気になる所に 1 行。
止1 の受け口（アプリが diag の state に載せる、中断から戻るまでの数。名前はまだ決まっていない）:
- state の "phoneResume…"・"watchResume…" で始まる省ける項目を、日ごとの最後の値で 3 日並べて summary.md に出す（守1 と同じやり方）。
  数ならそのまま、{"median"…} ならその真ん中、並びなら数。知らない名前でもそのまま出す。
"""

from __future__ import annotations

import datetime
import json
import re
import statistics
from pathlib import Path

MISS_WINDOW = 25.0     # 母艦の Build-MismatchTypes と同じ（前後の秒）
MISS_COVER = 0.12      # これより含まれ率が低ければ「抜け」
HAD_COVER = 0.5        # PC の文字起こしにあったとみなす含まれ率
MIN_CHARS = 8
SLACK = 2.0            # 区切りの端の余り（秒）
DEFAULT_CHUNK = 300.0
DROP_SHARE = 0.3       # 届7（仮）: 前の版の平均よりこれ以上減ったら知らせる
DROP_FLOOR_MIN = 60.0  # 前の版の平均がこれより少なければ比べない
RESUME = re.compile(r"^(phone|watch)Resume[A-Za-z0-9_]*$")
STAGES = ("not_recorded", "novoice", "no_text", "dropped_after", "unknown")
STAGE_LABEL = {"not_recorded": "録れていない", "novoice": "声が無いと捨てた（見立て）", "no_text": "文字にならなかった",
               "dropped_after": "記録で落とした", "unknown": "分からない"}


def _bigrams(n: str) -> set:
    return {n[i:i + 2] for i in range(len(n) - 1)}


def cover(block_n: str, texts: list[str]) -> float:
    """PLAUD の発話の 2 文字の並びのうち、texts のどれかに含まれる割合"""
    grams = _bigrams(block_n)
    if not grams:
        return 0.0
    pool: set = set()
    for text in texts:
        pool |= _bigrams(text)
    return len(grams & pool) / len(grams)


# MARK: - 続4


def chunk_spans(jobs_dir: Path, day: str) -> list[dict]:
    """その日の区切り [{"name","start","end","watch","result"}]（jobs の .json。始まりは chunk_start か名前の時刻）"""
    import judgecheck

    out = []
    for meta_path in Path(jobs_dir).glob("*.json"):
        try:
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        name = str(meta.get("id") or "")
        times = meta.get("times") if isinstance(meta.get("times"), dict) else {}
        start = times.get("chunk_start") if isinstance(times.get("chunk_start"), (int, float)) else judgecheck.chunk_epoch(name)
        if start is None:
            continue
        if datetime.datetime.fromtimestamp(float(start)).date().isoformat() != day:
            continue
        length = meta.get("audio_seconds")
        length = float(length) if isinstance(length, (int, float)) and length > 0 else DEFAULT_CHUNK
        result = meta_path.with_suffix(".result")
        out.append({"name": name, "start": float(start), "end": float(start) + length, "watch": name.endswith("-w.m4a"),
                    "result": result if result.is_file() else None, "status": meta.get("status")})
    return sorted(out, key=lambda c: c["start"])


def job_lines(chunks: list[dict]) -> list[tuple[float, str]]:
    """区切りの文字起こしの行 [(時刻, そろえた文)]"""
    import judgecheck

    out = []
    for chunk in chunks:
        if chunk.get("result") is None:
            continue
        try:
            body = json.loads(Path(chunk["result"]).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        for line in body.get("lines") or []:
            try:
                out.append((chunk["start"] + float(line["start"]), judgecheck.norm(str(line.get("text") or ""))))
            except (KeyError, TypeError, ValueError):
                continue
    return out


def classify_misses(blocks: list[tuple[float, float, str]], record_lines: list[tuple[float, str]], chunks: list[dict],
                    pc_lines: list[tuple[float, str]], dropped_novoice: int = 0) -> dict:
    """続4（純粋な関数）: PLAUD の発話 [(始まり, 終わり, そろえた文)] の「抜け」を段に分ける（文字数）。
    record_lines・pc_lines は [(時刻, そろえた文)]、chunks は chunk_spans の形、dropped_novoice はその日の時計の「声が無いので捨てた」の数"""
    out = {"blocks": 0, "chars": 0, "all_blocks": 0, **{s: 0 for s in STAGES}}
    lengths = [c["end"] - c["start"] for c in chunks]
    typical = statistics.median(lengths) if lengths else DEFAULT_CHUNK

    def near(lines, a, b):
        return [n for t, n in lines if a - MISS_WINDOW <= t <= b + MISS_WINDOW]

    for start, end, text in blocks:
        if len(text) < MIN_CHARS:
            continue
        out["all_blocks"] += 1
        if cover(text, near(record_lines, start, end)) >= MISS_COVER:
            continue
        out["blocks"] += 1
        out["chars"] += len(text)
        mid = (start + end) / 2
        inside = [c for c in chunks if c["start"] - SLACK <= mid <= c["end"] + SLACK]
        if not inside:
            before = [c for c in chunks if c["end"] < mid]
            after = [c for c in chunks if c["start"] > mid]
            hole = (after[0]["start"] - before[-1]["end"]) if before and after else None
            stage = "novoice" if dropped_novoice > 0 and hole is not None and hole <= 2.5 * typical else "not_recorded"
        elif all(c.get("result") is None for c in inside):
            stage = "unknown"
        elif cover(text, near(pc_lines, start, end)) >= HAD_COVER:
            stage = "dropped_after"
        else:
            stage = "no_text"
        out[stage] += len(text)
    return out


def plaud_blocks(home: Path, base: Path, day: str) -> list[tuple[float, float, str]]:
    """その日の、時刻の決まった PLAUD の発話 [(始まり, 終わり, そろえた文)]（plaudmatch と同じ時刻合わせ）"""
    import plaudmatch

    recs, _ = plaudmatch._timed(Path(home), Path(base), day)
    out = []
    for rec in recs:
        for block in rec.get("blocks") or []:
            try:
                out.append((rec["t0"] + float(block["t"]), rec["t0"] + float(block["end"]), str(block.get("n") or "")))
            except (KeyError, TypeError, ValueError):
                continue
    return out


def miss_stages(home: Path, base: Path | None, day: str, dropped_novoice: int = 0) -> dict | None:
    """続4: その日の段ごとの数（PLAUD が無い日は None）"""
    import judgecheck

    if base is None:
        return None
    blocks = plaud_blocks(home, base, day)
    if not blocks:
        return None
    records = [(line["t"], line["n"]) for line in judgecheck.record_lines(home, day)]
    chunks = chunk_spans(Path(home) / "jobs", day)
    return classify_misses(blocks, records, chunks, job_lines(chunks), dropped_novoice)


# MARK: - 届7・止1（diag の日ごとの履歴から）


def diag_day(diag_folder: Path, day: str) -> dict:
    """その日の端末の様子: {"app","watch"（その日の最後の版）,"watch_recorded_s"（watchRecordedToday の最大）,
    "novoice"（watchNoVoiceDropped の最大）,"resume": {名前: 最後の値}}"""
    out = {"app": None, "watch": None, "watch_recorded_s": None, "novoice": 0, "resume": {}}
    root = Path(diag_folder)
    if not root.is_dir():
        return out
    for device in sorted(p for p in root.iterdir() if p.is_dir()):
        try:
            handle = (device / f"{day}.jsonl").open(encoding="utf-8")
        except OSError:
            continue
        with handle:
            for raw in handle:
                try:
                    record = json.loads(raw)
                except ValueError:
                    continue
                state = record.get("state") if isinstance(record.get("state"), dict) else {}
                if record.get("build") is not None:
                    out["app"] = str(record["build"])
                if state.get("watchBuild") is not None:
                    out["watch"] = str(state["watchBuild"])
                for key, field in (("watch_recorded_s", "watchRecordedToday"), ("novoice", "watchNoVoiceDropped")):
                    value = state.get(field)
                    if isinstance(value, (int, float)) and not isinstance(value, bool):
                        out[key] = value if out[key] is None else max(out[key], value)
                for key, value in state.items():
                    if RESUME.match(str(key)):
                        out["resume"][key] = value
    return out


def recorded_minutes(chunks: list[dict], watch_recorded_s: float | None) -> dict:
    """{"watch": 分, "phone": 分}（時計は時計が数えた秒があればそれ、無ければ区切りの長さの和）"""
    watch = sum(c["end"] - c["start"] for c in chunks if c["watch"])
    phone = sum(c["end"] - c["start"] for c in chunks if not c["watch"])
    if isinstance(watch_recorded_s, (int, float)) and watch_recorded_s > 0:
        watch = float(watch_recorded_s)
    return {"watch": round(watch / 60, 1), "phone": round(phone / 60, 1)}


def build_drops(days: dict[str, dict], today: str, share: float = DROP_SHARE) -> list[dict]:
    """届7（純粋な関数）: days は {日: {"recorded_min": {"watch","phone"}, "builds": {"app","watch","pc"}}}。
    終わった日（today より前）だけで、版ごとの 1 日の平均を出し、いちばん新しい版がその前の版より share 以上少なければ
    [{"part","old","new","old_min","new_min","old_days","new_days"}]"""
    out = []
    done = sorted(d for d in days if d < today and isinstance(days[d].get("recorded_min"), dict))
    for part in ("app", "watch", "pc"):
        runs: list[tuple[str, list[float]]] = []
        for day in done:
            build = (days[day].get("builds") or {}).get(part)
            if build in (None, "", "0"):
                continue
            minutes = days[day]["recorded_min"]
            total = float(minutes.get("watch") or 0) + float(minutes.get("phone") or 0)
            if runs and runs[-1][0] == str(build):
                runs[-1][1].append(total)
            else:
                runs.append((str(build), [total]))
        if len(runs) < 2:
            continue
        (old, old_v), (new, new_v) = runs[-2], runs[-1]
        old_mean, new_mean = statistics.mean(old_v), statistics.mean(new_v)
        if old_mean >= DROP_FLOOR_MIN and new_mean < old_mean * (1 - share):
            out.append({"part": part, "old": old, "new": new, "old_min": round(old_mean), "new_min": round(new_mean),
                        "old_days": len(old_v), "new_days": len(new_v)})
    return out


PART_LABEL = {"app": "アプリ", "watch": "時計", "pc": "家の PC"}


def drop_lines(drops: list[dict]) -> list[str]:
    return [f"{PART_LABEL[d['part']]}の版を {d['old']} から {d['new']} に上げたあと、1 日に録れた時間が {d['old_min']} 分 → "
            f"{d['new_min']} 分（{d['new_days']} 日の平均）に減りました（3 割以上・しきい値は仮）" for d in drops]


def resume_value(value) -> str | None:
    """止1: 省ける項目の値を短い文字に（数・{"median"…}・並び）。分からない形は None"""
    if isinstance(value, bool):
        return "はい" if value else "いいえ"
    if isinstance(value, (int, float)):
        return f"{value:g}"
    if isinstance(value, dict):
        for key in ("median", "last", "count", "n"):
            if isinstance(value.get(key), (int, float)) and not isinstance(value.get(key), bool):
                return f"{key} {value[key]:g}"
        return f"{len(value)} 項目"
    if isinstance(value, list):
        return f"{len(value)} 件"
    if isinstance(value, str) and len(value) <= 24:
        return value
    return None


def resume_label(key: str) -> str:
    who = "iPhone" if key.startswith("phone") else "時計"
    rest = key.split("Resume", 1)[1] or "（名前なし）"
    hints = (("Seconds", "戻るまでの秒"), ("Secs", "戻るまでの秒"), ("Failed", "戻れなかった"), ("Fail", "戻れなかった"),
             ("Attempt", "何回目で戻った"), ("Tries", "何回目で戻った"), ("Ok", "戻った"), ("Count", "回数"))
    for word, said in hints:
        if word in rest:
            return f"{who} {said}（{key}）"
    return f"{who} {key}"


def resume_line(by_day: dict[str, dict]) -> str | None:
    """止1: 3 日の並び（来ていなければ None）"""
    keys = sorted({k for entry in by_day.values() for k in (entry or {})})
    if not keys:
        return None
    parts = []
    for key in keys:
        cells = []
        for day in sorted(by_day):
            text = resume_value((by_day[day] or {}).get(key)) if key in (by_day[day] or {}) else None
            cells.append(f"{day[5:]} {text if text is not None else '—'}")
        parts.append(f"{resume_label(key)}: " + "・".join(cells))
    return "中断から戻るまで（止1・3 日。アプリが送る分）: " + " / ".join(parts)


def stage_line(days: dict[str, dict]) -> str | None:
    """続4: 直近の日の段の割合を 1 行に"""
    parts = []
    for day in sorted(days)[-3:]:
        entry = days[day] or {}
        chars = entry.get("chars") or 0
        if not chars:
            continue
        bits = "・".join(f"{STAGE_LABEL[s]} {entry.get(s, 0) / chars:.0%}" for s in STAGES if entry.get(s))
        parts.append(f"{day[5:]} 抜け {entry.get('blocks', 0)} 発話・{chars:,} 字（{bits}）")
    return "PLAUD と比べた「抜け」の落ちた段（続4。文字数の割合・見立ては仮）: " + " / ".join(parts) if parts else None
