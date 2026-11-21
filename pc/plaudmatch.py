"""LifeLog PC: PLAUD の文と、アプリ・PC の文の合い方を、言語モデルを使わずに文字の比べで数える（s21 精1・精10。2026-11-22）。

物差しは judgecheck.py と同じ: 母艦の archive/plaud の公式の文字起こしを、その日の記録（HOME/records/<日>.json）の行との
文字の一致から時刻合わせし（estimate_t0）、行の時刻の前後 20 秒の PLAUD の発話をつないだ文を「物差しの文」にする。

精1（毎晩。quality-daily.json に書く）:
  記録の行ごとに「行の文字のうち、物差しの文と同じ並びで合った文字の割合」を出し、その日の全部の行で
  合った文字の合計 ÷ 行の文字の合計 を "plaud_match"（0〜1）、比べられた行の数を "plaud_match_lines" に書く。
  比べられた行が MIN_LINES 行より少なければ "plaud_match" は null（測れない）。PLAUD は遅れて届くので 3 日前まで測り直す。
  ※ 時刻合わせにも同じ記録の行を使うので、合わない行が多い録音は時刻が決まらず数から外れる（少し甘めに出る。仮）。
精10（週 1。HOME/engine-weights.json に書く）:
  後で受け取る文字起こしの答え（HOME/jobs/*.result の行の "votes"）のモデルごとの文で同じことをして、モデルごとの当たり率
  （合った文字 ÷ 書いた文字）を出す。当たり率が真ん中のモデルより低いモデルの票を軽く、高いモデルを重くする
  （重み＝当たり率 ÷ 真ん中の当たり率 を WEIGHT_MIN〜WEIGHT_MAX に収める。どれも仮）。
  比べられた行が ENGINE_MIN_LINES 行・ENGINE_MIN_CHARS 字に足りないモデルは 1（変えない）。
  使うのは run_job（lifelog_pc.py）で、iPhone が送ってきた重み（答え合わせから学んだもの）に掛ける（0.5〜2.0 に収める）。
  config.json の "engine_weights": false で使わない（数えるのは続ける）。

文の中身はどこにも出さない（数だけ）。
"""

from __future__ import annotations

import datetime
import difflib
import json
import os
import statistics
import time
from collections import defaultdict
from pathlib import Path

import judgecheck

MIN_LINES = 20            # 精1: その日の割合を出すのに要る、比べられた行の数
MIN_CHARS = 4             # これより短い行は比べない（相づち）
BACK_DAYS = 3             # 精1: PLAUD が遅れて届くので、何日前まで測り直すか
ENGINE_DAYS = 7           # 精10: 何日分の答えで数えるか
ENGINE_EVERY = 7 * 86400  # 精10: 数え直す間
ENGINE_MIN_LINES = 30     # 仮
ENGINE_MIN_CHARS = 300    # 仮
WEIGHT_MIN, WEIGHT_MAX = 0.8, 1.2   # 仮: PC が掛ける重みの幅
WEIGHTS_FILE = "engine-weights.json"


def matched(candidate_norm: str, reference_norm: str) -> int:
    """同じ並びで合った文字の数（judgecheck.closeness と同じ数え方の、合った字の分だけ）"""
    if not candidate_norm or not reference_norm:
        return 0
    blocks = difflib.SequenceMatcher(None, candidate_norm, reference_norm, autojunk=False).get_matching_blocks()
    return sum(block.size for block in blocks)


def _timed(home: Path, base: Path, day: str) -> tuple[list[dict], list[dict]]:
    """(時刻の決まった PLAUD の録音, その日の記録の行)"""
    recs = judgecheck.load_officials(base, day)
    if not recs:
        return [], []
    lines = judgecheck.record_lines(home, day)
    for rec in recs:
        rec["t0"] = judgecheck.estimate_t0(rec["blocks"], lines, rec["hint"])
    return [r for r in recs if r.get("t0") is not None], lines


def day_match(home: Path, base: Path, day: str) -> dict:
    """精1: その日の {"lines", "chars", "matched", "match"（割合か None）, "recordings", "timed"}"""
    recs, lines = _timed(Path(home), Path(base), day)
    out = {"lines": 0, "chars": 0, "matched": 0, "match": None, "recordings": len(judgecheck.load_officials(base, day)),
           "timed": len(recs)}
    if not recs:
        return out
    for line in lines:
        if line["media"] or len(line["n"]) < MIN_CHARS:
            continue
        ref = judgecheck.reference(recs, line["t"])
        if ref is None:
            continue
        out["lines"] += 1
        out["chars"] += len(line["n"])
        out["matched"] += matched(line["n"], ref)
    if out["lines"] >= MIN_LINES and out["chars"]:
        out["match"] = round(out["matched"] / out["chars"], 3)
    return out


def nightly(home: Path, base: Path | None, today: datetime.date, update_day) -> dict:
    """精1: 昨日〜3 日前の plaud_match を quality-daily.json に書く（update_day は quality.update_day）。書いた日 → 割合"""
    if base is None or not Path(base).is_dir():
        return {}
    out = {}
    for back in range(1, BACK_DAYS + 1):
        day = (today - datetime.timedelta(days=back)).isoformat()
        stats = day_match(home, base, day)
        if stats["lines"] or back == 1:
            update_day(home, day, {"plaud_match": stats["match"], "plaud_match_lines": stats["lines"]})
            out[day] = stats["match"]
    return out


# MARK: - 精10: モデルごとの当たり率


def job_votes(jobs: Path, days: set[str]) -> dict[str, list[dict]]:
    """日 → [{"t", "votes": {モデル: 文}}]（後で受け取る文字起こしの答えのうち、票の付いた行）"""
    out: dict[str, list[dict]] = defaultdict(list)
    for path in Path(jobs).glob("*.result"):
        try:
            result = json.loads(path.read_text(encoding="utf-8"))
            meta = json.loads(path.with_suffix(".json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        begin = judgecheck.chunk_epoch(str((meta or {}).get("id") or "")) if isinstance(meta, dict) else None
        if begin is None or not isinstance(result, dict):
            continue
        for line in result.get("lines") or []:
            votes = line.get("votes") if isinstance(line, dict) else None
            start = line.get("start") if isinstance(line, dict) else None
            if not isinstance(votes, dict) or isinstance(start, bool) or not isinstance(start, (int, float)):
                continue
            t = begin + float(start)
            day = datetime.datetime.fromtimestamp(t).strftime("%Y-%m-%d")
            if day in days:
                out[day].append({"t": t, "votes": {str(k): str(v or "") for k, v in votes.items()}})
    return out


def engine_rates(home: Path, base: Path, today: datetime.date, days: int = ENGINE_DAYS) -> dict[str, dict]:
    """モデル → {"lines", "chars", "matched", "rate"}（直近 days 日。昨日まで）"""
    wanted = {(today - datetime.timedelta(days=i)).isoformat() for i in range(1, days + 1)}
    votes = job_votes(Path(home) / "jobs", wanted)
    totals: dict[str, dict] = defaultdict(lambda: {"lines": 0, "chars": 0, "matched": 0})
    for day, rows in votes.items():
        recs, _ = _timed(Path(home), Path(base), day)
        if not recs:
            continue
        for row in rows:
            ref = judgecheck.reference(recs, row["t"])
            if ref is None:
                continue
            for name, text in row["votes"].items():
                n = judgecheck.norm(text)
                if len(n) < MIN_CHARS:
                    continue
                entry = totals[name]
                entry["lines"] += 1
                entry["chars"] += len(n)
                entry["matched"] += matched(n, ref)
    out = {}
    for name, entry in totals.items():
        entry = dict(entry)
        entry["rate"] = round(entry["matched"] / entry["chars"], 4) if entry["chars"] else None
        out[name] = entry
    return out


def weights_from(rates: dict[str, dict]) -> dict[str, float]:
    """当たり率から重み（数が足りないモデルは 1）"""
    usable = {k: v["rate"] for k, v in rates.items() if v.get("rate") is not None
              and v["lines"] >= ENGINE_MIN_LINES and v["chars"] >= ENGINE_MIN_CHARS}
    if len(usable) < 2:
        return {k: 1.0 for k in rates}
    middle = statistics.median(usable.values()) or 1.0
    return {k: (round(min(WEIGHT_MAX, max(WEIGHT_MIN, usable[k] / middle)), 3) if k in usable else 1.0) for k in rates}


def read_weights(home: Path) -> dict:
    try:
        data = json.loads((Path(home) / WEIGHTS_FILE).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def weekly(home: Path, base: Path | None, now: datetime.datetime, force: bool = False) -> dict | None:
    """精10: 前に数えてから 7 日たっていれば数え直して HOME/engine-weights.json に書く。書いたものを返す（しなければ None）"""
    if base is None or not Path(base).is_dir():
        return None
    old = read_weights(home)
    if not force and time.time() - float(old.get("at_epoch") or 0) < ENGINE_EVERY:
        return None
    rates = engine_rates(home, base, now.date())
    weights = weights_from(rates)
    body = {"at": now.isoformat(timespec="seconds"), "at_epoch": round(time.time()), "days": ENGINE_DAYS,
            "engines": {k: dict(v, weight=weights.get(k, 1.0)) for k, v in rates.items()},
            "note": "重みは仮（当たり率 ÷ 真ん中の当たり率 を 0.8〜1.2 に収めたもの）"}
    path = Path(home) / WEIGHTS_FILE
    part = path.with_name(path.name + ".part")
    part.write_text(json.dumps(body, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(part, path)
    return body


def merge(iphone: dict[str, float], home: Path, config: dict | None) -> dict[str, float]:
    """run_job で使う重み: iPhone の重み × PC の重み（0.5〜2.0）。"engine_weights": false か、まだ数えていなければ iPhone のまま"""
    if (config or {}).get("engine_weights") is False:
        return dict(iphone)
    engines = read_weights(home).get("engines")
    if not isinstance(engines, dict) or not engines:
        return dict(iphone)
    out = dict(iphone)
    for name, entry in engines.items():
        weight = entry.get("weight") if isinstance(entry, dict) else None
        if isinstance(weight, (int, float)) and not isinstance(weight, bool) and weight != 1.0:
            out[name] = round(min(2.0, max(0.5, out.get(name, 1.0) * float(weight))), 3)
    return out
