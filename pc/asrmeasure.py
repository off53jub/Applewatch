"""LifeLog PC: 文字起こしの変更を、同じ物差しで測る道具（強化案 131・132・135。2026-11-16）。

物差し: PLAUD の文字起こし（母艦 archive/plaud）と、この PC の文字起こしの行を、5 分ごとの窓で比べた
「文字の合い方」（表記 = 正規化した文字の最長一致の適合率・再現率・F。読み = かなにして同じ）。
行の時刻は judgecheck.py の決まり（録音の頭を合わせて、前後 5 秒を足す）。新しい日を足したいときは prepare を回し直す。

使い方（venv は faster_whisper・av・numpy が入ったもの。pykakasi は --lib で足せる）:
  prepare  --work 作業フォルダ     jobs/*.result の行（votes つき）と PLAUD と重なる行の一覧を作る（lines.pkl・targets.json）
  run      --work … --cond none|hint10|now|place [--stop-at 04:50] [--wait]
           Whisper large-v3 を GPU で、同じ行にかけ直す（作業フォルダの whisper_<cond>.jsonl に足していく。やり直せる）。
           ヒントの条件: none=渡さない／hint10=仕事のヒントの先頭 10 語／now=今と同じ（40 語）／place=先頭 10 語＋その時間の地名（placehints.py）
           重い計算なので、00:00〜05:00 と 08:30〜18:00 の外では始めない（--wait でその時間まで待つ）。動いている LifeLog PC は触らない。
  （135 あなた向けモデルを入れる前に測る手順: run --cond now --model <あなた向けのモデルのフォルダ（lifelog_pc.PERSONAL_MODEL）>
   --tag mine を、今の large-v3 の now と同じ行にかけ、score --conds now,mine で比べる。点が上がり（95% の幅が 0 をまたがない）、
   haas＋whisper との比べで下がらなければ入れる。全部の行に回すと 30 分ほどの GPU。00:00〜05:00 に回す）
  score    --work … --conds none,hint10,now[,place]   条件ごとの合い方と、迷った所だけ Whisper に回す形（selective.py）の点と GPU の割合
  speakers --work …                            133（PLAUD の話し手で声の見本を増やせる量）と 134（機械ごとの区間の合い方）を数える

出力は数だけ（文・名前は出さない）。作業フォルダは、リポジトリの外（スクラッチ）に置く。
"""

from __future__ import annotations

import argparse
import datetime
import difflib
import io
import json
import os
import pickle
import random
import re
import sys
import threading
import time
import unicodedata
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
HOME = Path(os.environ.get("LOCALAPPDATA") or Path.home() / ".local" / "share") / "LifeLogPC"
RATE = 16000
HEAVY = ((0, 0, 5, 0), (8, 30, 18, 0))
CORE = ("haas", "reazon", "whisper")
PAD, BIN = 5.0, 300.0
JUNK = re.compile(
    r"^(ご視聴ありがとうございました|ご清聴ありがとうございました|チャンネル登録(よろしくお願いします|をお願いします)?|"
    r"お疲れ様でした|字幕.*|ありがとうございました)[。！!]*$")


def heavy_ok(now: datetime.datetime | None = None) -> bool:
    now = now or datetime.datetime.now()
    minute = now.hour * 60 + now.minute
    return any(a * 60 + b <= minute < c * 60 + d for a, b, c, d in HEAVY)


def _hms(text: str) -> int:
    h, m = text.split(":")
    return int(h) * 60 + int(m)


def app_vote():
    """lifelog_pc.py の vote() を、そのままの中身で（読み込むと重いので、必要な所だけ私用の名前空間で実行する）"""
    src = (HERE / "lifelog_pc.py").read_text(encoding="utf-8")
    a, b = src.index("_kakasi = None"), src.index("def _voter_order")
    ns = {"re": re, "unicodedata": unicodedata, "difflib": difflib, "threading": threading}
    exec("from __future__ import annotations\n" + src[a:b], ns)
    return ns["vote"], ns["parse_weights"], ns["similarity"]


def reader(lib: str | None):
    if lib:
        sys.path.insert(0, lib)
    import pykakasi

    k = pykakasi.kakasi()
    cache: dict[str, str] = {}

    def reading(text: str) -> str:
        import judgecheck as jc

        text = jc.norm(text)
        got = cache.get(text)
        if got is None:
            try:
                got = "".join(p["hira"] for p in k.convert(text))
            except Exception:  # noqa: BLE001
                got = text
            got = got.replace("ー", "")
            cache[text] = got
        return got

    return reading


def matched(a: str, b: str) -> int:
    if not a or not b:
        return 0
    return sum(x.size for x in difflib.SequenceMatcher(None, a, b, autojunk=False).get_matching_blocks())


# MARK: - prepare


def load_audio(data: bytes):
    import av
    import numpy as np

    chunks = []
    with av.open(io.BytesIO(data)) as c:
        st = c.streams.audio[0]
        rs = av.AudioResampler(format="flt", layout="mono", rate=RATE)
        for fr in c.decode(st):
            for o in rs.resample(fr):
                chunks.append(o.to_ndarray().reshape(-1))
        for o in rs.resample(None):
            chunks.append(o.to_ndarray().reshape(-1))
    return np.concatenate(chunks).astype(np.float32) if chunks else np.zeros(0, np.float32)


def cmd_prepare(args) -> int:
    import judgecheck as jc

    vote, parse_weights, _ = app_vote()
    base = Path(args.lifelog)
    work = Path(args.work)
    work.mkdir(parents=True, exist_ok=True)
    rows, stats = [], defaultdict(int)
    for path in sorted((HOME / "jobs").glob("*.result")):
        try:
            res = json.loads(path.read_text(encoding="utf-8"))
            meta = json.loads(path.with_suffix(".json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            stats["unreadable"] += 1
            continue
        begin = jc.chunk_epoch(str(meta.get("id") or ""))
        if begin is None:
            continue
        origin = str(meta.get("origin") or "iphone")
        weights = parse_weights((meta.get("params") or {}).get("weights"))
        for line in res.get("lines") or []:
            v = line.get("votes") if isinstance(line, dict) else None
            if not isinstance(v, dict) or not all(k in v for k in CORE):
                stats["skipped"] += 1
                continue
            j = line.get("judge")
            before = j.get("before") if isinstance(j, dict) else None
            final = str(line.get("text") or "")
            t = begin + float(line.get("start") or 0)
            t_end = begin + float(line.get("end") or line.get("start") or 0)
            row = {"day": datetime.datetime.fromtimestamp(t).strftime("%Y-%m-%d"), "t": t, "t_end": t_end,
                   "job": path.stem, "origin": origin, "final": final,
                   "majority": before if isinstance(before, str) else final}
            for k in CORE:
                row[k] = str(v.get(k) or "").strip()
            r = vote({"haas": row["haas"], "whisper": row["whisper"]}, weights)
            row["haas+whisper"] = (r or {}).get("text", "")
            rows.append(row)
    (work / "lines.pkl").write_bytes(pickle.dumps((rows, dict(stats))))
    by_day = defaultdict(list)
    for r in rows:
        by_day[r["day"]].append(r)
    targets, gone = {}, set()
    for day in sorted(by_day):
        recs = jc.load_officials(base, day)
        if not recs:
            continue
        rl = jc.record_lines(HOME, day)
        for rec in recs:
            t0 = jc.estimate_t0(rec["blocks"], rl, rec["hint"])
            if t0 is None:
                continue
            lo, hi = t0 - jc.WINDOW, t0 + rec["blocks"][-1]["end"] + jc.WINDOW
            for r in by_day[day]:
                if lo <= r["t"] <= hi:
                    jp = HOME / "jobs" / (r["job"] + ".json")
                    if not jp.exists() or not jp.with_suffix(".audio").exists():
                        gone.add(r["job"])
                        continue
                    begin = jc.chunk_epoch(json.loads(jp.read_text(encoding="utf-8"))["id"])
                    targets[f'{r["job"]}@{r["t"]:.3f}'] = {"job": r["job"], "start": r["t"] - begin, "end": r["t_end"] - begin}
    (work / "targets.json").write_text(json.dumps(targets), encoding="utf-8")
    print(f"lines {len(rows)} targets {len(targets)} jobs {len({v['job'] for v in targets.values()})} "
          f"seconds {round(sum(v['end'] - v['start'] for v in targets.values()))} gone_jobs {len(gone)}")
    return 0


# MARK: - run（GPU）


def hints_for(cond: str, meta: dict, begin: float | None, start: float) -> str | None:
    hints = list((meta.get("params") or {}).get("hints") or [])
    if cond == "none":
        return None
    if cond == "hint10":
        return "、".join(hints[:10]) or None
    if cond == "now":
        return "、".join(hints[:40]) or None
    if cond == "place":
        import hintpolicy
        import placehints

        words = []
        if begin is not None:
            words = placehints.words_at(Path(os.environ.get("LIFELOG_HOME", r"D:\Lifelog")), begin + start, home=HOME, limit=6)
        merged = [w for w in words if w not in hints[:10]] + hints[:10]
        _ = hintpolicy
        return "、".join(merged) or None
    raise SystemExit(f"知らない条件: {cond}")


def cmd_run(args) -> int:
    import judgecheck as jc

    work = Path(args.work)
    cuda = HOME / "cuda"
    os.add_dll_directory(str(cuda))
    os.environ["PATH"] = str(cuda) + os.pathsep + os.environ.get("PATH", "")
    from faster_whisper import WhisperModel

    while not heavy_ok():
        if not args.wait:
            print("重い計算をしてよい時間（00:00〜05:00・08:30〜18:00）ではないので、始めません", flush=True)
            return 2
        time.sleep(30)
    stop = _hms(args.stop_at)
    targets = json.loads((work / "targets.json").read_text(encoding="utf-8"))
    out = work / f"whisper_{args.tag or args.cond}.jsonl"
    done = set()
    if out.exists():
        for ln in out.read_text(encoding="utf-8").splitlines():
            try:
                done.add(json.loads(ln)["key"])
            except ValueError:
                pass
    byjob: dict[str, list] = {}
    for k, v in targets.items():
        if k not in done:
            byjob.setdefault(v["job"], []).append((k, v))
    print("todo_lines", sum(len(x) for x in byjob.values()), "done", len(done), flush=True)
    model = None
    while model is None:
        try:
            model = WhisperModel(args.model, device="cuda", compute_type=args.compute, download_root=str(HOME / "whisper"))
        except Exception as error:  # noqa: BLE001 — GPU の空きが足りない間は待つ（動いている LifeLog PC を優先する）
            print("model_load_failed", type(error).__name__, flush=True)
            if not heavy_ok(datetime.datetime.now() + datetime.timedelta(minutes=15)):
                return 3
            time.sleep(600)
    n, secs, busy = 0, 0.0, 0.0
    with out.open("a", encoding="utf-8") as f:
        for job, items in byjob.items():
            now = datetime.datetime.now()
            if not heavy_ok(now + datetime.timedelta(minutes=5)) or (stop <= now.hour * 60 + now.minute < 8 * 60 + 30):
                print("stop_at_window", flush=True)
                break
            if not (HOME / "jobs" / (job + ".json")).exists() or not (HOME / "jobs" / (job + ".audio")).exists():
                continue  # 録音が消された分は測れない（スコアは両方そろった行だけで比べる）
            meta = json.loads((HOME / "jobs" / (job + ".json")).read_text(encoding="utf-8"))
            begin = jc.chunk_epoch(str(meta.get("id") or ""))
            audio = load_audio((HOME / "jobs" / (job + ".audio")).read_bytes())
            for key, v in items:
                a, b = max(0, int(v["start"] * RATE)), min(len(audio), int(v["end"] * RATE))
                text = ""
                if b - a >= int(0.3 * RATE):
                    s = time.time()
                    pieces, _ = model.transcribe(audio[a:b], language="ja", beam_size=5,
                                                 initial_prompt=hints_for(args.cond, meta, begin, v["start"]),
                                                 condition_on_previous_text=False, without_timestamps=True,
                                                 vad_filter=False, temperature=0.0)
                    kept = []
                    for p in pieces:
                        t = p.text.strip()
                        if p.no_speech_prob > 0.6 and p.avg_logprob < -1.0:
                            continue
                        if JUNK.match(t):
                            continue
                        kept.append(t)
                    text = "".join(kept)
                    busy += time.time() - s
                    secs += (b - a) / RATE
                f.write(json.dumps({"key": key, "text": text}, ensure_ascii=False) + "\n")
                n += 1
            f.flush()
    print("finished_lines", n, "audio_s", round(secs), "work_s", round(busy), "rtf", round(busy / secs, 3) if secs else None,
          flush=True)
    return 0


# MARK: - score


def build_bins(rows: list[dict], systems: list[str], reading, lifelog: Path):
    import judgecheck as jc

    by_day = defaultdict(list)
    for r in rows:
        by_day[r["day"]].append(r)
    bins = []
    for day in sorted(by_day):
        recs = jc.load_officials(lifelog, day)
        if not recs:
            continue
        rl = jc.record_lines(HOME, day)
        for rec in recs:
            t0 = jc.estimate_t0(rec["blocks"], rl, rec["hint"])
            if t0 is None:
                continue
            lo, hi = t0 - jc.WINDOW, t0 + rec["blocks"][-1]["end"] + jc.WINDOW
            groups = defaultdict(list)
            for r in sorted([r for r in by_day[day] if lo <= r["t"] <= hi], key=lambda r: r["t"]):
                groups[int((r["t"] - t0) // BIN)].append(r)
            for rs in groups.values():
                spans = [(r["t"] - t0 - PAD, r["t_end"] - t0 + PAD) for r in rs]
                ref = "".join(bk["n"] for bk in rec["blocks"] if any(bk["end"] >= x and bk["t"] <= y for x, y in spans))
                if not ref:
                    continue
                refr = reading(ref)
                e = {"day": day, "ref": len(ref), "refr": len(refr), "sys": {}, "t0": t0}
                for s in systems:
                    hyp = "".join(jc.norm(r[s]) for r in rs)
                    hr = reading(hyp)
                    e["sys"][s] = (matched(hyp, ref), len(hyp), matched(hr, refr), len(hr))
                bins.append(e)
    return bins


def f_score(bs: list[dict], s: str, kind: str) -> tuple[float, float, float]:
    i = 0 if kind == "surf" else 2
    m = sum(b["sys"][s][i] for b in bs)
    h = sum(b["sys"][s][i + 1] for b in bs)
    rl = sum(b["ref" if kind == "surf" else "refr"] for b in bs)
    p = m / h if h else 0.0
    rc = m / rl if rl else 0.0
    return p, rc, (2 * p * rc / (p + rc) if p + rc else 0.0)


def boot(bins: list[dict], a: str, b: str, kind: str, seed: int = 131, n: int = 1000) -> tuple[float, float, float]:
    rnd = random.Random(seed)
    ds = []
    for _ in range(n):
        bs = [bins[rnd.randrange(len(bins))] for _ in bins]
        ds.append(f_score(bs, a, kind)[2] - f_score(bs, b, kind)[2])
    ds.sort()
    return sum(ds) / len(ds), ds[int(n * 0.025)], ds[int(n * 0.975) - 1]


def load_rows(work: Path) -> list[dict]:
    """lines.pkl の行。origin（iphone / watch。仕事の控えの "origin"）が無ければ足す"""
    rows, _ = pickle.loads((work / "lines.pkl").read_bytes())
    origins: dict[str, str] = {}
    for r in rows:
        if "origin" not in r:
            job = r["job"]
            if job not in origins:
                try:
                    meta = json.loads((HOME / "jobs" / (job + ".json")).read_text(encoding="utf-8"))
                    origins[job] = str(meta.get("origin") or "iphone")
                except (OSError, ValueError):
                    origins[job] = "iphone"
            r["origin"] = origins[job]
    return rows


def cmd_score(args) -> int:
    import selective

    work = Path(args.work)
    vote, parse_weights, similarity = app_vote()
    reading = reader(args.lib)
    rows = load_rows(work)
    conds = [c for c in args.conds.split(",") if c]
    texts: dict[str, dict] = {}
    for c in conds:
        path = work / f"whisper_{c}.jsonl"
        texts[c] = {}
        if path.exists():
            for ln in path.read_text(encoding="utf-8").splitlines():
                d = json.loads(ln)
                texts[c][d["key"]] = d["text"].strip()
    wanted = set(json.loads((work / "targets.json").read_text(encoding="utf-8")))
    keys = [f'{r["job"]}@{r["t"]:.3f}' for r in rows]
    have = [c for c in conds if texts[c]]
    use = [(r, k) for r, k in zip(rows, keys) if k in wanted and all(k in texts[c] for c in have)] if have else []
    print("conds", have, "rows_in_all_conditions", len(use))
    w = parse_weights(None)
    systems = ["majority", "haas", "whisper", "haas+whisper"]
    rows2 = []
    secs_all = sum(r["t_end"] - r["t"] for r, _ in use) or 1.0
    for r, k in use:
        r = dict(r)
        for c in have:
            r[f"w_{c}"] = texts[c][k]
            r[f"hw_{c}"] = (vote({"haas": r["haas"], "whisper": texts[c][k]}, w) or {}).get("text", "")
        rows2.append(r)
    for c in have:
        systems += [f"w_{c}", f"hw_{c}"]
    # 迷った所だけ（haas だけ／haas+reazon）
    stats = {}
    for fast_names, tag in ((("haas",), "doubt-haas"), (("haas", "reazon"), "doubt-haas+reazon")):
        for c in have:
            name = f"{tag}:{c}"
            n_doubt, sec_doubt, reasons = 0, 0.0, defaultdict(int)
            for r in rows2:
                dur = r["t_end"] - r["t"]
                why = selective.doubtful({k: r[k] for k in fast_names}, dur, similarity)
                if why:
                    n_doubt += 1
                    sec_doubt += dur
                    reasons[why] += 1
                    r[name] = r[f"hw_{c}"]
                else:
                    r[name] = r["haas"] if len(fast_names) == 1 else ((vote({k: r[k] for k in fast_names}, w) or {}).get("text", ""))
            systems.append(name)
            stats[name] = (n_doubt, sec_doubt, dict(reasons))
    bins = build_bins(rows2, systems, reading, Path(args.lifelog))
    print("bins", len(bins), "ref_chars", sum(b["ref"] for b in bins), "rows", len(rows2), "audio_s", round(secs_all))
    for kind in ("surf", "read"):
        for s in systems:
            p, rc, f = f_score(bins, s, kind)
            extra = ""
            if s in stats:
                nd, sd, rs = stats[s]
                extra = f"  whisper回し={nd}/{len(rows2)}行 音声の{sd / secs_all:.1%}（{rs}）"
            print(f"{kind} {s:28s} P={p:.3f} R={rc:.3f} F={f:.3f}{extra}")
        base = "haas+whisper"
        for s in systems:
            if s in (base,) or not (s.startswith("hw_") or s.startswith("w_") or s.startswith("doubt")):
                continue
            m, lo, hi = boot(bins, s, base, kind)
            print(f"boot {kind} {s} - {base}: {m:+.4f} 95%=[{lo:+.4f},{hi:+.4f}]")
    return 0


# MARK: - speakers（133・134）


def cmd_speakers(args) -> int:
    """133: PLAUD の話し手の区切りを先生にすると、声の見本（話し手ごとの区間）がどれだけ増えるか。
    134: 時計・iPhone の区間が PLAUD の時間をどれだけ覆い、PLAUD との文字の合い方がどれだけ違うか。数だけ"""
    import judgecheck as jc

    work = Path(args.work)
    reading = reader(args.lib)
    rows = load_rows(work)
    lifelog = Path(args.lifelog)
    by_day = defaultdict(list)
    for r in rows:
        by_day[r["day"]].append(r)
    clip_min, clip_max = 1.5, 20.0
    plaud_spk_secs: dict[str, float] = defaultdict(float)
    taught_clips = taught_secs = 0
    pure = mixed = 0
    spk_lines = defaultdict(lambda: defaultdict(int))
    windows = 0
    spk_clips: dict[tuple, int] = defaultdict(int)     # (窓, 話し手) ごとの区間の数
    spk_per_window: list[int] = []
    cover = {"iphone": 0.0, "watch": 0.0}
    plaud_secs = 0.0
    bins_by = {"iphone": [0, 0, 0, 0], "watch": [0, 0, 0, 0]}  # 合った字数・書いた字数・PLAUD の字数
    best_pick = [0, 0, 0]                                      # 良い方を採った合った字数・書いた字数・PLAUD の字数
    both_bins = 0
    for day in sorted(by_day):
        recs = jc.load_officials(lifelog, day)
        if not recs:
            continue
        rl = jc.record_lines(HOME, day)
        for rec in recs:
            t0 = jc.estimate_t0(rec["blocks"], rl, rec["hint"])
            if t0 is None:
                continue
            windows += 1
            spk_per_window.append(len({b["spk"] for b in rec["blocks"]}))
            lo, hi = t0 - jc.WINDOW, t0 + rec["blocks"][-1]["end"] + jc.WINDOW
            for b in rec["blocks"]:
                plaud_spk_secs[b["spk"]] += max(0.0, b["end"] - b["t"])
                plaud_secs += max(0.0, b["end"] - b["t"])
            inside = [r for r in by_day[day] if lo <= r["t"] <= hi]
            for r in inside:
                d = r["t_end"] - r["t"]
                cover[r["origin"] if r["origin"] in cover else "iphone"] += d
                mid = r["t"] - t0 + d / 2
                blocks = [b for b in rec["blocks"] if b["t"] <= mid <= b["end"]]
                if blocks and clip_min <= d <= clip_max:
                    spk_clips[(day, windows, blocks[0]["spk"])] += 1
                    spk_lines[blocks[0]["spk"]]["clips"] += 1
                    taught_clips += 1
                    taught_secs += d
            # 話し手ごとに、区間が 1 つの話し手に収まる割合（先生として使える割合）
            for r in inside:
                d = r["t_end"] - r["t"]
                if not (clip_min <= d <= clip_max):
                    continue
                spks = {b["spk"] for b in rec["blocks"] if b["end"] >= r["t"] - t0 and b["t"] <= r["t_end"] - t0}
                if len(spks) == 1:
                    pure += 1
                elif len(spks) > 1:
                    mixed += 1
            groups = defaultdict(lambda: {"iphone": [], "watch": []})
            for r in inside:
                groups[int((r["t"] - t0) // BIN)][r["origin"] if r["origin"] in cover else "iphone"].append(r)
            for g in groups.values():
                allrs = g["iphone"] + g["watch"]
                spans = [(r["t"] - t0 - PAD, r["t_end"] - t0 + PAD) for r in allrs]
                ref = "".join(bk["n"] for bk in rec["blocks"] if any(bk["end"] >= x and bk["t"] <= y for x, y in spans))
                if not ref:
                    continue
                refr = reading(ref)
                per = {}
                for origin in ("iphone", "watch"):
                    hyp = "".join(jc.norm(r["majority"]) for r in g[origin])
                    hr = reading(hyp)
                    m, h = matched(hr, refr), len(hr)
                    per[origin] = (m, h)
                    if g[origin]:
                        bins_by[origin][0] += m
                        bins_by[origin][1] += h
                        bins_by[origin][2] += len(refr)
                        bins_by[origin][3] += 1
                if g["iphone"] and g["watch"]:
                    both_bins += 1
                    pick = max(per.values(), key=lambda x: (2 * x[0] / (x[1] + len(refr)) if x[1] + len(refr) else 0))
                    best_pick[0] += pick[0]
                    best_pick[1] += pick[1]
                    best_pick[2] += len(refr)
    print("plaud_windows", windows, "plaud_speakers_total_secs", round(plaud_secs))
    print("plaud_speakers_per_window", sorted(spk_per_window))
    print("windows_x_speakers_with_clips>=4", sum(1 for v in spk_clips.values() if v >= 4),
          ">=12", sum(1 for v in spk_clips.values() if v >= 12), "of", len(spk_clips))
    print("pc_clips_(1.5-20s)_with_plaud_speaker", taught_clips, "seconds", round(taught_secs),
          "single_speaker_clips", pure, "multi_speaker_clips", mixed)
    voices = sorted((HOME / "voices").glob("*.npz"))
    existing = 0
    try:
        import numpy as np

        for p in voices:
            existing += len(np.load(p, allow_pickle=False)["keys"])
    except Exception:  # noqa: BLE001
        pass
    print("existing_voice_samples_in_PC", existing, "(days", len(voices), ")")
    print("iphone_secs_inside_plaud_windows", round(cover["iphone"]), "watch_secs", round(cover["watch"]))

    def prf(m, h, r):
        p = m / h if h else 0
        rc = m / r if r else 0
        return p, rc, (2 * p * rc / (p + rc) if p + rc else 0)

    for origin, (m, h, r, n) in bins_by.items():
        print("read", origin, "bins", n, "P/R/F", tuple(round(x, 3) for x in prf(m, h, r)))
    print("bins_with_both", both_bins, "best-of-both (oracle, upper bound) P/R/F", tuple(round(x, 3) for x in prf(*best_pick)))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["prepare", "run", "score", "speakers"])
    parser.add_argument("--work", required=True)
    parser.add_argument("--lifelog", default=os.environ.get("LIFELOG_HOME", r"D:\Lifelog"))
    parser.add_argument("--lib", default=None, help="pykakasi が入った場所")
    parser.add_argument("--cond", default="none")
    parser.add_argument("--conds", default="none,hint10,now")
    parser.add_argument("--model", default="large-v3", help="Whisper のモデル（名前かフォルダ）。あなた向けのモデルを測るときはそのフォルダ")
    parser.add_argument("--tag", default=None, help="結果のファイル名の印（既定は --cond）。モデルを替えて測るとき（例 mine）に使う")
    parser.add_argument("--compute", default="int8_float16")
    parser.add_argument("--stop-at", default="04:50")
    parser.add_argument("--wait", action="store_true")
    args = parser.parse_args()
    return {"prepare": cmd_prepare, "run": cmd_run, "score": cmd_score, "speakers": cmd_speakers}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
