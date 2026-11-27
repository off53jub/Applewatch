"""LifeLog PC: s29（2026-11-27。担当 P）声2・声3・声5・声6・声7・声12・声13・声17。どれも影・既定オフ（数えるだけ）。

記録の話し手は変えない・人をまとめない・名前を付けない。モデルのダウンロード・新しい部品の導入はしない。

- 声5 夜の 1 日まるごとの分け直しの「正本の候補」（"s29p_canonical"。既定オフ＝口に出さない。数えるのは "s29p_canonical_shadow"・既定オン）:
  s26 聞4 と同じかたまり（日の平均を引いた声の特徴・DIAR_LINK）に、声7・声12・声13 の手がかりを重ね、名前の無い行の
  「付け直し案」（from → to）を作る。HOME/s29p/canonical/<日>.json。GET /s29/canonical?day=YYYY-MM-DD（オンのときだけ items）:
    {"available": bool, "on": bool, "day", "items": [{"time": ISO, "audio", "start", "end", "from": {"id","name"},
     "to": {"id","name"}, "why": ["diar"|"headcount"|"chain"|"hint"]}], "counts": {...}, "gate": {...}}
  本番にする条件は s29pgate.GATES["canonical"]（答えた組で iPhone の分けより当たったら・数は仮）。条件を満たしても自動で本番にしない。
- 声7 予定・本人の答えの人数（s22voice.headcounts）が分かる会話は、自分以外のかたまりをその人数 − 1 まで（近いかたまりへ寄せる）。
- 声12 交互の鎖: 1 つの会話の中で、区切り（音声）ごとに「自分 と 名前の無い 1 人」だけが交互に話していて、その 1 人が区切りごとに
  別の人物N になっているとき、あとの人物N を前の人物N に寄せる案。
- 声13 予定の相手が 1 人だけの時間（s26pvoice.single_partner_events）と、母艦 M2 の場面の見込みで LINE が理由の候補
  （state/talk_guess_for_pc.json）を手がかりに、その時間の名前の無いかたまりが、その人の声の真ん中と HINT_MIN（0.45・仮）以上なら案に。
- 声2 iPhone と時計の 2 本（"s29p_two_mic"。既定オン＝影で数えるだけ。夜に音声を読むだけでモデルは使わない）:
  同じ時間に iPhone と時計の両方の区切りがあるかを先に確かめ、無ければ "材料なし"。あれば音の包絡で時間の差を合わせ、記録の行ごとに
  2 本の音の大きさの差（時計 − iPhone の dB）で「自分／近い相手／遠い人」に分ける（SELF_DB・NEAR_DB は仮）。
  自分の行（記録の印 me）を当てる AUC を、2 本の差と 1 本（iPhone）の大きさで比べる。HOME/s29p/two-mic.json。
- 声3 雑音を消してから声の特徴（"s29p_denoise_embed"。既定オフ・夜の重い時間だけ）: 既にある GTCRN で消した音と消さない音で、
  答えた組の声の特徴を測り、AUC を比べる。モデルのファイルが手元に無ければ測らない（取ってこない）。HOME/s29p/denoise-embed.json。
- 声6 重なりを 2 本に分ける: s26pnight.separate（"s26p_separate"・既定オフ）がそのまま口。speechbrain の部品があるかだけを数える
  （入れない・本人の判断待ち）。
- 声17 声の特徴のモデル 4 種（s22models.SPEAKERS）を、答えた組と across/maybe（機械の「同じ人かも」）で比べる道具:
  python pc/s29pvoice.py models [--home HOME] [--mother 母艦]。HOME/speaker に無いモデルは「無し」で飛ばす（取ってこない）。
"""

from __future__ import annotations

import argparse
import bisect
import datetime
import importlib.util
import json
import os
import re
import sys
import time
from pathlib import Path

import numpy as np

import voices

RATE = 16000
DIAR_LINK = 0.6          # 仮（s26pvoice.DIAR_LINK と同じ）
DIAR_PURE = 0.6
DIAR_MIN = 3
HINT_MIN = 0.45          # 仮
SELF_DB, NEAR_DB, LOUD_DB = 4.0, -30.0, -45.0   # 声2（仮）: 時計 − iPhone ≥ SELF_DB で自分・大きい方が NEAR_DB 以上で近い相手
FRAME = 0.02
MAX_LAG = 3.0
PAIR_WINDOW = 600.0      # 区切りの始まりがこれ以内なら、重なっているかを確かめる（秒）
TWO_MIC_NIGHT = 20
CANON_ITEMS = 500
UNNAMED = re.compile(r"人物\d+")
NAME_TIME = re.compile(r"(\d{8})-(\d{6})(-w)?")


def folder(home: Path) -> Path:
    return Path(home) / "s29p"


def _write(path: Path, body) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    part = path.with_name(path.name + ".part")
    part.write_text(json.dumps(body, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(part, path)


def _read(path: Path, default=None):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return default


def _named(name) -> bool:
    return isinstance(name, str) and bool(name) and name != "自分" and not UNNAMED.fullmatch(name)


def _iso(ms) -> str | None:
    try:
        return voices._iso(ms)
    except (TypeError, ValueError, OverflowError):
        return None


def _ms(value) -> int | None:
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return int(value)
    try:
        return int(datetime.datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp() * 1000)
    except ValueError:
        return None


# MARK: - 声5・声7・声12・声13 正本の候補


def _greedy(segs: list[dict], vectors: dict[str, np.ndarray], link: float = DIAR_LINK) -> tuple[list[np.ndarray], dict[str, int]]:
    """長い区間から順に、近い束へ（s26pvoice.day_diar と同じ）。(束の真ん中, 区間の鍵 → 束の番号)"""
    order = sorted(segs, key=lambda s: -(s["end"] - s["start"]))
    centers: list[np.ndarray] = []
    sums: list[np.ndarray] = []
    where: dict[str, int] = {}
    for s in order:
        v = vectors[s["key"]]
        if centers:
            sims = np.stack(centers) @ v
            k = int(np.argmax(sims))
            if sims[k] >= link:
                sums[k] = sums[k] + v
                centers[k] = voices._unit(sums[k])
                where[s["key"]] = k
                continue
        centers.append(v)
        sums.append(v.copy())
        where[s["key"]] = len(centers) - 1
    return centers, where


def _cluster_names(segs: list[dict], where: dict[str, int]) -> dict[int, tuple[str, str]]:
    """束 → (名前, speakerID)（名前のある行・自分の行が DIAR_PURE 以上・2 行以上の束だけ）"""
    counts: dict[int, dict[tuple[str, str], int]] = {}
    sizes: dict[int, int] = {}
    for s in segs:
        k = where.get(s["key"])
        if k is None:
            continue
        sizes[k] = sizes.get(k, 0) + 1
        label, line = s["label"], s["line"]
        if label == voices.SELF_LABEL:
            who = ("自分", "me")
        elif label and label.startswith("n:") and _named(line.get("speaker")):
            who = (str(line.get("speaker")), str(line.get("speakerID")))
        else:
            continue
        counts.setdefault(k, {}).setdefault(who, 0)
        counts[k][who] += 1
    out = {}
    for k, c in counts.items():
        if sizes.get(k, 0) < DIAR_MIN:
            continue
        top = max(c, key=c.get)
        if c[top] >= 2 and c[top] / max(1, sum(c.values())) >= DIAR_PURE:
            out[k] = top
    return out


def hint_windows(base: Path | None, day: str) -> list[tuple[int, int, str, str]]:
    """声13: [(始まり ms, 終わり ms, 名前, "calendar"|"line")]"""
    out = []
    try:
        import s26pvoice

        for e in s26pvoice.single_partner_events(base, day):
            out.append((int(e["start"]), int(e["end"]), e["name"], "calendar"))
        for item in s26pvoice.read_guess(base):
            if item.get("day") != day:
                continue
            for c in item.get("candidates") or []:
                why = [str(w) for w in c.get("why") or []]
                if any("LINE" in w for w in why) and _named(c.get("name")):
                    start, end = _ms(item.get("start")), _ms(item.get("end"))
                    if start is not None and end is not None:
                        out.append((start, end, str(c["name"]), "line"))
    except Exception:  # noqa: BLE001 — 手がかりが読めなくても、声だけで続ける
        pass
    return out


def canonical(home: Path, base: Path | None, store, day: str, refs: dict[str, tuple[np.ndarray, int]] | None = None,
              headcounts=None, hints=None) -> dict | None:
    """その日の正本の候補（付け直し案）と数。記録は変えない。refs は名前 → (声の真ん中, 数)（s26pvoice.name_refs）"""
    import s26pvoice

    parsed = store.day(day) if store is not None else None
    if not parsed:
        return None
    vectors = s26pvoice.day_vectors(home, parsed, day)
    segs = [s for s in voices.segments(parsed) if s["key"] in vectors]
    if not segs:
        return None
    centers, where = _greedy(segs, vectors)
    base_where = dict(where)
    names = _cluster_names(segs, where)
    ids = {}
    for s in voices.segments(parsed):
        if s["label"] and s["label"].startswith("n:") and _named(s["line"].get("speaker")):
            ids[str(s["line"]["speaker"])] = str(s["line"]["speakerID"])
    counts = {"diar": 0, "headcount": 0, "chain": 0, "hint": 0}
    why: dict[str, list[str]] = {}
    forced: dict[str, tuple[str, str]] = {}

    # 声7: 人数の分かる会話は、自分以外の束をその人数 − 1 まで
    rows = headcounts if headcounts is not None else _headcounts(base, day)
    by_conv = _conversations(parsed, vectors)
    for conv in by_conv:
        limit = None
        for start, end, count in rows:
            if conv["start"] is not None and start <= conv["start"] < end:
                limit = max(1, int(count) - 1)
        if limit is None:
            continue
        others = {}
        for s in conv["segs"]:
            if s["label"] != voices.SELF_LABEL:
                others.setdefault(where[s["key"]], []).append(s)
        if len(others) <= limit:
            continue
        keep = sorted(others, key=lambda k: -len(others[k]))[:limit]
        for k in [k for k in others if k not in keep]:
            target = max(keep, key=lambda j: float(centers[j] @ centers[k]))
            for s in others[k]:
                where[s["key"]] = target
                why.setdefault(s["key"], []).append("headcount")
                counts["headcount"] += 1
    names = _cluster_names(segs, where)

    # 声12: 交互の鎖（区切りごとに 自分 と 名前の無い 1 人 だけ）
    for conv in by_conv:
        head = None
        for audio, group in conv["by_audio"]:
            labels = {s["label"] for s in group}
            others = [x for x in labels if x != voices.SELF_LABEL]
            if voices.SELF_LABEL in labels and len(others) == 1 and others[0] and others[0].startswith("u:") and _alternates(group):
                mine = [s for s in group if s["label"] == others[0]]
                if head is None:
                    spots = [where[s["key"]] for s in mine]
                    head = (others[0], max(set(spots), key=spots.count))
                elif others[0] != head[0]:
                    for s in mine:
                        where[s["key"]] = head[1]
                        why.setdefault(s["key"], []).append("chain")
                        forced[s["key"]] = (f"人物{head[0][2:]}", head[0][2:])
                        counts["chain"] += 1
            else:
                head = None

    # 声13: 予定・LINE の手がかり
    windows = hints if hints is not None else hint_windows(base, day)
    if windows and refs:
        for s in segs:
            if not (s["label"] and s["label"].startswith("u:")):
                continue
            t = _ms(s["line"].get("time"))
            for start, end, name, source in windows:
                if t is None or not start <= t < end or name not in refs or name not in ids:
                    continue
                k = where[s["key"]]
                if k in names:
                    continue
                if float(centers[k] @ refs[name][0]) >= HINT_MIN:
                    forced[s["key"]] = (name, ids[name])
                    why.setdefault(s["key"], []).append("hint")
                    counts["hint"] += 1
                break

    items = []
    for s in segs:
        if not (s["label"] and s["label"].startswith("u:")):
            continue
        k = where[s["key"]]
        to = names.get(k)
        if to is not None:
            why.setdefault(s["key"], []).insert(0, "diar")
            counts["diar"] += 1
        else:
            to = forced.get(s["key"])
        if to is None or to[1] == s["label"][2:]:
            continue
        line = s["line"]
        items.append({"time": _iso(line.get("time")) if isinstance(line.get("time"), (int, float)) else line.get("time"),
                      "audio": s["audio"], "start": round(s["start"], 2), "end": round(s["end"], 2),
                      "from": {"id": s["label"][2:], "name": f"人物{s['label'][2:]}"}, "to": {"id": to[1], "name": to[0]},
                      "why": sorted(set(why.get(s["key"], ["diar"])), key=["diar", "headcount", "chain", "hint"].index)})
    body = {"version": 1, "day": day, "generated_at": datetime.datetime.now().isoformat(timespec="seconds"),
            "segments": len(segs), "clusters": len(set(where.values())), "counts": counts, "items": items[:CANON_ITEMS],
            "where": {k: int(v) for k, v in where.items()}, "base_where": {k: int(v) for k, v in base_where.items()},
            "note": "s29 声5・声7・声12・声13（仮・影）。記録には付けない。付け直すのは本人の端末だけ"}
    _write(folder(home) / "canonical" / f"{day}.json", body)
    return body


def _headcounts(base: Path | None, day: str) -> list[tuple[int, int, int]]:
    try:
        import s22voice

        return s22voice.headcounts(base, day)
    except Exception:  # noqa: BLE001
        return []


def _conversations(parsed: dict, vectors: dict) -> list[dict]:
    out = []
    for conversation in parsed.get("conversations") or []:
        if conversation.get("media"):
            continue
        segs = [s for s in voices.segments({"conversations": [conversation]}) if s["key"] in vectors]
        by_audio: list[tuple[str, list[dict]]] = []
        for s in segs:
            if by_audio and by_audio[-1][0] == s["audio"]:
                by_audio[-1][1].append(s)
            else:
                by_audio.append((s["audio"], [s]))
        out.append({"start": _ms(conversation.get("start")), "segs": segs, "by_audio": by_audio})
    return out


def _alternates(group: list[dict]) -> bool:
    """自分とほかの人が交互に（入れ替わりが 2 回以上）"""
    turns = 0
    for a, b in zip(group, group[1:]):
        turns += (a["label"] == voices.SELF_LABEL) != (b["label"] == voices.SELF_LABEL)
    return turns >= 2


def same_of(body: dict | None, key: str = "where"):
    """答えた組で「同じ束か」を返す関数（見本がその日の束に無ければ None）"""
    where = (body or {}).get(key) or {}

    def guess(pair: dict):
        spots = []
        for side in pair["people"][:2]:
            got = {where.get(voices.seg_key(s["audio"], s["start"], s["end"])) for s in side} - {None}
            if len(got) != 1:
                return None
            spots.append(got.pop())
        return spots[0] == spots[1]

    return guess


def read_canonical(home: Path, day: str | None, on: bool, gate: dict | None = None) -> dict:
    if not on:
        return {"available": False, "on": False,
                "reason": "正本の候補は既定オフです（config.json の \"s29p_canonical\": true で出します。付け直すのは本人の端末だけ）"}
    day = day or (datetime.date.today() - datetime.timedelta(days=1)).isoformat()
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", day or ""):
        return {"available": False, "on": True, "reason": "day は YYYY-MM-DD です"}
    body = _read(folder(home) / "canonical" / f"{day}.json", None)
    if not isinstance(body, dict):
        return {"available": False, "on": True, "day": day, "reason": "その日の候補はまだありません（夜に作ります）"}
    return {"available": True, "on": True, "day": day, "items": body.get("items") or [], "counts": body.get("counts") or {},
            "generated_at": body.get("generated_at"), "gate": gate or {}}


# MARK: - 声2 iPhone と時計の 2 本


def chunk_start(name: str) -> float | None:
    m = NAME_TIME.search(name or "")
    if not m:
        return None
    try:
        return datetime.datetime.strptime(m[1] + m[2], "%Y%m%d%H%M%S").timestamp()
    except ValueError:
        return None


def is_watch(name: str) -> bool:
    m = NAME_TIME.search(name or "")
    return bool(m and m[3])


def overlap_candidates(names: list[str], window: float = PAIR_WINDOW) -> list[tuple[str, str]]:
    """始まりが window 秒以内の (iPhone の区切り, 時計の区切り)。そろっているかの下調べ（長さは音声を読んでから確かめる）"""
    watch = sorted((chunk_start(n), n) for n in names if is_watch(n) and chunk_start(n) is not None)
    times = [t for t, _ in watch]
    out = []
    for n in sorted(names):
        t = chunk_start(n)
        if is_watch(n) or t is None:
            continue
        for _, w in watch[bisect.bisect_left(times, t - window):bisect.bisect_right(times, t + window)]:
            out.append((n, w))
    return out


def envelope(audio: np.ndarray, frame: float = FRAME) -> np.ndarray:
    n = int(frame * RATE)
    usable = len(audio) // n * n
    if usable <= 0:
        return np.zeros(0)
    power = np.mean(np.square(audio[:usable].reshape(-1, n).astype(np.float64)), axis=1)
    return 10 * np.log10(power + 1e-10)


def align(a: np.ndarray, b: np.ndarray, guess: float = 0.0, max_lag: float = MAX_LAG) -> tuple[float, float]:
    """b の時刻 = a の時刻 + guess + lag になる lag（秒）と、合い方（相関）。包絡の相関で探す"""
    ea, eb = envelope(a), envelope(b)
    if len(ea) < 10 or len(eb) < 10:
        return 0.0, 0.0
    ea = (ea - ea.mean()) / (ea.std() + 1e-9)
    eb = (eb - eb.mean()) / (eb.std() + 1e-9)
    best = (0.0, -1.0)
    steps = int(max_lag / FRAME)
    base_shift = int(round(guess / FRAME))
    for k in range(-steps, steps + 1):
        shift = base_shift + k
        lo = max(0, -shift)
        hi = min(len(ea), len(eb) - shift)
        if hi - lo < 10:
            continue
        r = float(np.mean(ea[lo:hi] * eb[lo + shift:hi + shift]))
        if r > best[1]:
            best = (k * FRAME, r)
    return best


def level(audio: np.ndarray, start: float, end: float) -> float | None:
    a, b = max(0, int(start * RATE)), min(len(audio), int(end * RATE))
    if b - a < RATE // 4:
        return None
    return float(10 * np.log10(np.mean(np.square(audio[a:b].astype(np.float64))) + 1e-10))


def classify(watch_db: float, phone_db: float) -> str:
    """仮: 時計のほうが SELF_DB 以上大きければ自分（手首は口に近い）・大きいほうが NEAR_DB 以上なら近い相手・ほかは遠い人"""
    if watch_db - phone_db >= SELF_DB and max(watch_db, phone_db) >= LOUD_DB:
        return "self"
    if max(watch_db, phone_db) >= NEAR_DB:
        return "near"
    return "far"


def two_mic(home: Path, store, days: list[str], load_audio, find_audio, deadline: float | None = None,
            limit: int = TWO_MIC_NIGHT) -> dict:
    """{"status": "材料なし"|"測った", "candidates","pairs","lines","classes","auc_two","auc_one"}"""
    import s23voice

    lines_by_audio: dict[str, list[dict]] = {}
    for day in days:
        for s in voices.segments((store.day(day) if store is not None else None) or {}):
            lines_by_audio.setdefault(s["audio"], []).append(s)
    names = set(lines_by_audio)
    for day in days:
        audio_dir = Path(home) / "audio" / day
        if audio_dir.is_dir():
            names.update(p.name for p in audio_dir.iterdir() if p.is_file())
    cands = [(p, w) for p, w in overlap_candidates(sorted(names)) if find_audio(p) is not None and find_audio(w) is not None]
    out = {"status": "材料なし", "candidates": len(cands), "pairs": 0, "lines": 0,
           "classes": {"self": 0, "near": 0, "far": 0}, "auc_two": None, "auc_one": None,
           "note": "s29 声2（仮・影）。記録は変えない"}
    if not cands:
        out["why"] = "同じ時間に iPhone と時計の両方の音声がそろっていません"
        return out
    pos2, neg2, pos1, neg1 = [], [], [], []
    for phone_name, watch_name in cands[:limit]:
        if deadline is not None and time.time() > deadline:
            out["stopped"] = True
            break
        try:
            pa = load_audio(find_audio(phone_name).read_bytes())
            wa = load_audio(find_audio(watch_name).read_bytes())
        except Exception:  # noqa: BLE001
            continue
        guess = chunk_start(phone_name) - chunk_start(watch_name)   # iPhone の 0 秒は 時計の guess 秒
        if not (-len(wa) / RATE < guess < len(pa) / RATE + len(wa) / RATE):
            continue
        lag, r = align(wa, pa, -guess)
        shift = guess + lag
        if r < 0.2:
            continue
        out["pairs"] += 1
        for s in lines_by_audio.get(phone_name, []):
            w = level(wa, s["start"] + shift, s["end"] + shift)
            p = level(pa, s["start"], s["end"])
            if w is None or p is None:
                continue
            out["lines"] += 1
            out["classes"][classify(w, p)] += 1
            is_self = s["label"] == voices.SELF_LABEL
            if s["label"] is None:
                continue
            (pos2 if is_self else neg2).append(w - p)
            (pos1 if is_self else neg1).append(p)
    if out["pairs"]:
        out["status"] = "測った"
        out["auc_two"] = s23voice.auc(pos2, neg2)
        out["auc_one"] = s23voice.auc(pos1, neg1)
    elif "why" not in out:
        out["why"] = "時間を合わせられる組がありませんでした"
    return out


# MARK: - 声3 雑音を消してから声の特徴


def denoise_compare(pairs: list[dict], vec_plain, vec_clean, cohort: list[dict] | None = None) -> dict:
    """答えた組の AUC（消さない音・消した音）。vec_* は見本 → 長さ 1 の声の特徴か None"""
    import s23voice

    plain = s23voice.pair_scores(vec_plain, pairs, cohort or [])
    clean = s23voice.pair_scores(vec_clean, pairs, cohort or [])
    for got in (plain, clean):
        got.pop("scored", None)
    return {"plain": plain, "denoised": clean, "pairs": min(plain["pairs"], clean["pairs"])}


def audio_vec(load_audio, find_audio, embed, denoise=None, cache_limit: int = 50):
    """見本 → 声の特徴（音声を読んで、denoise があれば消してから embed(音, [(始まり, 終わり)])）"""
    cache: dict = {}

    def vec(sample: dict):
        name = sample["audio"]
        if name not in cache:
            path = find_audio(name)
            try:
                cache[name] = load_audio(path.read_bytes()) if path else None
            except Exception:  # noqa: BLE001
                cache[name] = None
            if len(cache) > cache_limit:
                cache.pop(next(iter(cache)))
        audio = cache.get(name)
        if audio is None:
            return None
        a, b = int(sample["start"] * RATE), int(sample["end"] * RATE)
        piece = np.ascontiguousarray(audio[a:b], dtype=np.float32)
        if len(piece) < RATE // 2:
            return None
        if denoise is not None:
            piece = denoise(piece)
        got = embed(piece, [(0.0, len(piece) / RATE)])
        if not got or got[0] is None:
            return None
        return voices._unit(np.asarray(got[0], np.float64))

    return vec


# MARK: - 声6


def separate_parts() -> dict:
    """speechbrain・torch が入っているか（読み込まない・入れない）"""
    return {name: importlib.util.find_spec(name) is not None for name in ("speechbrain", "torch")}


# MARK: - 声17 声の特徴のモデルを比べる


def proxy_pairs(home: Path, store, days: list[str], limit: int = 40) -> list[dict]:
    """機械の答え（本人の答えではない）: across/maybe の組 ＝ 同じ人かも・同じ区切りで iPhone が分けた 2 人 ＝ 違う人かも"""
    out = []
    body = _read(Path(home) / voices.OUT_FOLDER / voices.OUT_FILE, {}) or {}
    for g in (body.get("across") or [])[:limit]:
        people = [[{k: s[k] for k in ("audio", "start", "end")} for s in p.get("samples") or []] for p in g.get("people") or []]
        if len(people) >= 2 and all(people[:2]):
            out.append({"id": g.get("id"), "same": True, "people": people[:2], "day": g.get("day") or ""})
    for m in (body.get("maybe") or [])[:limit]:
        a = [{k: s[k] for k in ("audio", "start", "end")} for s in (m.get("person") or {}).get("samples") or []]
        if a:
            out.append({"id": m.get("id"), "same": True, "people": [a, []], "day": m.get("day") or "", "maybe": True})
    got = voices.gather(home, store, days)
    labels = got["labels"]
    count = 0
    for a, b in sorted(voices.apart_pairs(labels)):
        if count >= limit:
            break
        ia, ib = voices.pick(labels[a]["items"], 2), voices.pick(labels[b]["items"], 2)
        if ia and ib and a != voices.SELF_LABEL and b != voices.SELF_LABEL:
            out.append({"id": f"apart-{count}", "same": False, "day": "",
                        "people": [[{k: x[k] for k in ("audio", "start", "end")} for x in ia],
                                   [{k: x[k] for k in ("audio", "start", "end")} for x in ib]]})
            count += 1
    return [p for p in out if all(p["people"][:2])]


def compare_models(home: Path, answered: list[dict], proxies: list[dict], vec_for, models=None) -> dict:
    """{名前: {"status": "無し"|"測った", "answers": {...}, "machine": {...}}}。vec_for(名前) は見本 → 声の特徴"""
    import s22models
    import s23voice

    out = {}
    for name, entry in (models or s22models.SPEAKERS).items():
        path = Path(home) / "speaker" / str(entry.get("file") or "")
        if not path.is_file():
            out[name] = {"status": "無し", "file": entry.get("file")}
            continue
        vec = vec_for(name)
        ans = s23voice.pair_scores(vec, answered, [])
        mach = s23voice.pair_scores(vec, proxies, [])
        ans.pop("scored", None)
        mach.pop("scored", None)
        out[name] = {"status": "測った", "answers": ans, "machine": mach}
    return out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="s29 声17: 声の特徴のモデルを答えた組で比べる（重い。夜か手で）")
    parser.add_argument("what", choices=["models"])
    parser.add_argument("--home", default=str(Path(os.environ.get("LOCALAPPDATA", "")) / "LifeLogPC"))
    parser.add_argument("--mother", default=None)
    parser.add_argument("--days", type=int, default=7)
    args = parser.parse_args(argv)
    import records
    import s24night
    import s29pgate
    import sherpa_onnx

    home = Path(args.home)
    base = Path(args.mother) if args.mother else None
    store = records.RecordStore(home, lambda _m: None)
    today = datetime.date.today()
    days = [(today - datetime.timedelta(days=k)).isoformat() for k in range(args.days)]
    answered = s29pgate.answered_pairs(home, base)
    proxies = proxy_pairs(home, store, days)

    def vec_for(name):
        import s22models

        path = Path(home) / "speaker" / s22models.SPEAKERS[name]["file"]
        ex = sherpa_onnx.SpeakerEmbeddingExtractor(sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(path), num_threads=2))

        def embed(piece, ranges):
            st = ex.create_stream()
            st.accept_waveform(RATE, piece)
            st.input_finished()
            return [ex.compute(st) if ex.is_ready(st) else None]

        return audio_vec(s24night.load_audio, lambda n: s24night.find_audio(home, n), embed)

    table = compare_models(home, answered, proxies, vec_for)
    _write(folder(home) / "models.json", {"generated_at": datetime.datetime.now().isoformat(timespec="seconds"), "models": table})
    for name, row in table.items():
        if row["status"] == "無し":
            print(f"{name}: 無し（{row['file']} が HOME/speaker に無い。取ってこない）")
        else:
            print(f"{name}: 答えた組 {row['answers']['pairs']} 組 AUC {row['answers']['auc_raw']}・機械の組 "
                  f"{row['machine']['pairs']} 組 AUC {row['machine']['auc_raw']}")
    return 0


if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    sys.exit(main())
