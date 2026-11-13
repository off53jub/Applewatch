"""LifeLog PC: 割れた行の審判（asr-judge・精6）が、PLAUD の公式の文字起こしに近づけたかを測る（施策 11。2026-11-13）。

測り方（docs/s2-accuracy-2026-11-13.md に数と一緒に書いた）:
1. 後で受け取る文字起こしの答え（HOME/jobs/*.result。7 日で消える）のうち、審判が番号を返した行（"judge"）を集める。
   "judge.before" がある行は審判が文を替えた行（before＝多数決の文、text＝審判の選んだ文）。無い行は多数決のまま。
2. 行の時刻＝区切りの名前の頭（20261113-123456）＋行の start 秒。
3. 母艦の archive/plaud の公式の文字起こし（時刻は録音の頭からの経過）の録音ごとの開始時刻を、
   その日の記録（HOME/records/<日>.json）の行との文字の一致から決める（母艦の Build-PlaudGap.py の estimate_t0 と同じ決まり）。
4. 行の時刻の前後 WINDOW 秒にある PLAUD の発話をつないだ文を物差しにして、多数決の文と審判の文の近さを比べる。
   近さ＝PLAUD と同じ並びで合った文字の数×2 − その文の文字の数（合った字は +1、合わない字は −1。短い文が得をしない）。
5. 「審判のほうが近い」「多数決のほうが近い」「同じ」を数える。judge_agree_plaud＝審判のほうが近い ÷（どちらかが近い）。
   どちらかが近い行が MIN_DECIDED 行より少なければ None（測れない）。

文の中身は記録にも答えにも出さない（数だけ）。
    python judgecheck.py [--base D:\\Lifelog] [--days 2026-11-13,…]   測って数だけを表示する
"""

from __future__ import annotations

import argparse
import bisect
import datetime
import difflib
import glob
import json
import os
import re
import statistics
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path

CPS = 6.0              # 1 秒に話す文字数の目安（PLAUD の発話の長さの見積り。Build-PlaudGap.py と同じ）
HINT_RANGE = 1500      # startTime がある録音は前後 25 分だけ探す
MIN_VOTES_HINT = 4
MIN_VOTES_FREE = 6
WINDOW = 20.0          # 行の前後これだけの秒の PLAUD の発話を物差しにする
MIN_DECIDED = 5        # 割合を出すのに要る、どちらかが近い行の数
LABEL = re.compile(r"^(.{1,20}?) (\d\d):(\d\d):(\d\d)$")
CHUNK = re.compile(r"(\d{8})-(\d{6})")


def norm(s: str) -> str:
    return re.sub(r"[\s\W_]+", "", unicodedata.normalize("NFKC", s or ""))


def bigrams(n: str) -> set:
    return {n[i:i + 2] for i in range(len(n) - 1)}


def _local(day: str, h: int = 0, m: int = 0, s: int = 0) -> float:
    base = datetime.datetime.strptime(day, "%Y-%m-%d")
    return (base + datetime.timedelta(hours=h, minutes=m, seconds=s)).timestamp()


def chunk_epoch(name: str) -> float | None:
    """区切りの名前の頭（YYYYMMDD-HHMMSS。この PC の時刻）の 1970 年からの秒"""
    match = CHUNK.match(name or "")
    if not match:
        return None
    try:
        return datetime.datetime.strptime(match[1] + match[2], "%Y%m%d%H%M%S").timestamp()
    except ValueError:
        return None


# MARK: - 審判の行


def load_judged(jobs: Path, days: set[str] | None = None) -> list[dict]:
    """審判が番号を返した行: {"day", "t", "default", "judge", "changed"}（文は比べるためだけに持つ。外に出さない）"""
    out = []
    for path in sorted(Path(jobs).glob("*.result")):
        try:
            result = json.loads(path.read_text(encoding="utf-8"))
            meta = json.loads(path.with_suffix(".json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not isinstance(result, dict) or not isinstance(meta, dict):
            continue
        begin = chunk_epoch(str(meta.get("id") or ""))
        if begin is None:
            continue
        for line in result.get("lines") or []:
            if not isinstance(line, dict) or not isinstance(line.get("judge"), dict):
                continue
            start = line.get("start")
            if isinstance(start, bool) or not isinstance(start, (int, float)):
                continue
            t = begin + float(start)
            day = datetime.datetime.fromtimestamp(t).strftime("%Y-%m-%d")
            if days is not None and day not in days:
                continue
            text = str(line.get("text") or "")
            before = line["judge"].get("before")
            changed = isinstance(before, str)
            out.append({"day": day, "t": t, "default": before if changed else text, "judge": text, "changed": changed})
    return out


# MARK: - PLAUD の公式の文字起こし


def parse_official(path: Path) -> dict | None:
    try:
        text = Path(path).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None
    meta, blocks, cur = {}, [], None
    for line in text.splitlines():
        m = re.match(r"- (\w+): (.*)", line)
        if m and cur is None:
            meta[m[1]] = m[2].strip()
            continue
        if cur is None and line.startswith("#"):
            continue
        m = LABEL.match(line)
        if m:
            cur = {"t": int(m[2]) * 3600 + int(m[3]) * 60 + int(m[4]), "spk": m[1], "text": ""}
            blocks.append(cur)
            continue
        if cur is not None and line.strip():
            cur["text"] += line.strip()
    day = meta.get("date") or ""
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", day) or not blocks:
        return None
    hint = None
    if re.fullmatch(r"\d{1,2}:\d{2}", meta.get("startTime") or ""):
        h, mi = meta["startTime"].split(":")
        hint = _local(day, int(h), int(mi), 30)
    blocks.sort(key=lambda b: b["t"])
    for i, b in enumerate(blocks):
        b["n"] = norm(b["text"])
        b["bg"] = bigrams(b["n"])
        nxt = blocks[i + 1]["t"] if i + 1 < len(blocks) else None
        dur = len(b["n"]) / CPS + 2
        b["end"] = min(nxt, b["t"] + dur) if nxt is not None else b["t"] + dur
    return {"day": day, "hint": hint, "blocks": blocks}


def load_officials(base: Path, day: str) -> list[dict]:
    folder = Path(base) / "archive" / "plaud" / day[:4] / day[5:7]
    out = []
    for path in sorted(folder.glob(f"{day[8:10]}*.md")):
        rec = parse_official(path)
        if rec and rec["day"] == day:
            out.append(rec)
    return out


def record_lines(home: Path, day: str) -> list[dict]:
    """その日の記録の行（時刻合わせ用）"""
    try:
        data = json.loads((Path(home) / "records" / f"{day}.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    lines = []
    for conv in data.get("conversations") or [] if isinstance(data, dict) else []:
        for line in conv.get("lines") or [] if isinstance(conv, dict) else []:
            try:
                t = datetime.datetime.fromisoformat(str(line["time"]).replace("Z", "+00:00")).timestamp()
            except (KeyError, ValueError, TypeError):
                continue
            n = norm(str(line.get("text") or ""))
            lines.append({"t": t, "n": n, "bg": bigrams(n), "nb": max(len(n) - 1, 0), "media": bool(line.get("media"))})
    return sorted(lines, key=lambda x: x["t"])


def estimate_t0(blocks: list[dict], lines: list[dict], hint: float | None) -> float | None:
    """録音の頭の時刻（母艦の Build-PlaudGap.py の estimate_t0 と同じ決まり。決められなければ None）"""
    idx = defaultdict(list)
    for i, l in enumerate(lines):
        if l["nb"] >= 5 and not l["media"]:
            for g in l["bg"]:
                idx[g].append(i)
    votes = []
    for b in blocks:
        if len(b["n"]) < 12:
            continue
        hits = Counter()
        for g in b["bg"]:
            p = idx.get(g)
            if p and len(p) <= 40:
                hits.update(p)
        for i, h in hits.items():
            l = lines[i]
            if h / l["nb"] < 0.5:
                continue
            k = -1
            for j in range(len(l["n"]) - 1):
                k = b["n"].find(l["n"][j:j + 2])
                if k >= 0:
                    k = max(0, k - j)
                    break
            if k < 0:
                continue
            t0 = l["t"] - b["t"] - k / CPS
            if hint is not None and abs(t0 - hint) > HINT_RANGE:
                continue
            votes.append(t0)
    need = MIN_VOTES_HINT if hint is not None else MIN_VOTES_FREE
    if len(votes) < need:
        return None
    votes.sort()
    best, bi = 0, 0
    for i, v in enumerate(votes):
        j = bisect.bisect_right(votes, v + 60)
        if j - i > best:
            best, bi = j - i, i
    if best < need:
        return None
    others = [v for v in votes if abs(v - votes[bi]) > 600]
    if others:
        ob = max(sum(1 for w in others if 0 <= w - v <= 60) for v in others)
        if ob * 2 > best:
            return None
    return statistics.median(votes[bi:bi + best])


def closeness(candidate: str, reference: str) -> int:
    """合った文字の数×2 − 文字の数（文字は norm したもの）"""
    a, b = norm(candidate), norm(reference)
    if not a:
        return 0
    matched = sum(block.size for block in difflib.SequenceMatcher(None, a, b, autojunk=False).get_matching_blocks())
    return 2 * matched - len(a)


def reference(recs: list[dict], t: float) -> str | None:
    """時刻 t の前後 WINDOW 秒の PLAUD の発話をつないだ文（その時刻を録っていなければ None）"""
    for rec in recs:
        t0 = rec.get("t0")
        if t0 is None:
            continue
        rel = t - t0
        if rel < -WINDOW or rel > rec["blocks"][-1]["end"] + WINDOW:
            continue
        near = [b["n"] for b in rec["blocks"] if b["end"] >= rel - WINDOW and b["t"] <= rel + WINDOW]
        if near:
            return "".join(near)
    return None


def measure(home: Path, base: Path, days: list[str] | None = None) -> dict[str, dict]:
    """日ごとの数: {"judged", "changed", "aligned", "judge_better", "default_better", "tie", "recordings", "timed",
    "agree"（judge_better の割合。測れなければ None）}"""
    judged = load_judged(Path(home) / "jobs", set(days) if days else None)
    by_day: dict[str, list[dict]] = defaultdict(list)
    for row in judged:
        by_day[row["day"]].append(row)
    out: dict[str, dict] = {}
    for day in sorted(set(days or []) | set(by_day)):
        rows = by_day.get(day, [])
        stats = {"judged": len(rows), "changed": sum(1 for r in rows if r["changed"]), "aligned": 0,
                 "judge_better": 0, "default_better": 0, "tie": 0, "recordings": 0, "timed": 0, "agree": None}
        recs = load_officials(base, day)
        stats["recordings"] = len(recs)
        if recs and any(r["changed"] for r in rows):
            lines = record_lines(home, day)
            for rec in recs:
                rec["t0"] = estimate_t0(rec["blocks"], lines, rec["hint"])
            stats["timed"] = sum(1 for rec in recs if rec["t0"] is not None)
            for row in rows:
                if not row["changed"]:
                    continue
                ref = reference(recs, row["t"])
                if ref is None:
                    continue
                stats["aligned"] += 1
                a, b = closeness(row["judge"], ref), closeness(row["default"], ref)
                stats["judge_better" if a > b else "default_better" if b > a else "tie"] += 1
        decided = stats["judge_better"] + stats["default_better"]
        if decided >= MIN_DECIDED:
            stats["agree"] = round(stats["judge_better"] / decided, 3)
        out[day] = stats
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description="審判の選び直しが PLAUD に近づけたかを数える（数だけ表示）")
    parser.add_argument("--home", default=str(Path(os.environ.get("LOCALAPPDATA") or ".") / "LifeLogPC"))
    parser.add_argument("--base", default=r"D:\Lifelog")
    parser.add_argument("--days", default="")
    args = parser.parse_args()
    days = [d for d in args.days.split(",") if d] or None
    for day, stats in measure(Path(args.home), Path(args.base), days).items():
        print(day, json.dumps(stats, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
