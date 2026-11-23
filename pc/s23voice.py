"""LifeLog PC: s23 続1・続10（2026-11-23）。声の見分けのモデルを替えるかを決める物差しと、同じ人かの点の答え合わせ。0 円・言語モデルなし。

続1 時計の声だけの答えの組（30 組まで）:
- s22 確2 の測り（wespeaker34 の AUC 0.88 対 今の CAM++ 0.54）は、iPhone の聞き分けが付けた印と比べていた（物差しが片寄っている・仮説）。
  本人が答えた組だけ・時計の声（音声の名前が "-w.m4a"）だけで測り直す。
- 答えの出どころ: 母艦 inbox/app_feedback.jsonl の kind same_person（merged＝同じ・different＝違う）と、
  家の PC の確かめ待ちの「この 2 つの声は同じ人ですか」（id "vp-…"・kind review の yes/no）。
- 確かめ待ち（HOME/s23/review/voice-pairs.json。s23pc が s22 の確かめ待ちに足す）: その日の記録の時計の行から、
  同じ人物N の 2 行（同じ人のはず）と、違う話し手の 2 行（違う人のはず）を交互に作る。音は 2 つとも /audio-clip で聞ける（clips）。
  1 日 PAIRS_PER_DAY 問まで・答えのある組が WANTED 組になったら作るのをやめる。config.json の "voice_pairs": false で作らない。
- 測るのは pc/s23measure.py の speakers（重い。00:00〜04:50 だけ）。影で並べるのは s23pc の shadow（config "speaker_shadow"。初めはオフ）。

続10 同じ人かの点（s-norm・s22 確1）の答え合わせ:
- 毎晩、same-person/snorm.json（s22 が書く）と組の今の点（score）を、本人の答え（same_person・vp- の答え）と突き合わせて AUC を出し、
  quality-daily.json の昨日に "snorm_auc"・"raw_auc"・"snorm_pairs"・"snorm_same" を置く（母艦の M が読む）。組が少ないあいだは null。
"""

from __future__ import annotations

import datetime
import hashlib
import json
import os
import re
from pathlib import Path
from typing import Callable

import numpy as np

WATCH = re.compile(r"-w\.m4a$")
WANTED = 30              # 続1: 答えのある時計の声だけの組をこの数まで集める
PAIRS_PER_DAY = 2        # 続1: 1 日に足す問いの数（仮）
PAIR_MIN, PAIR_MAX = 3.0, 12.0   # 問いにする行の長さ（秒）
EXPIRE_DAYS = 14
TEXT_MAX = 60
MIN_PAIRS_AUC = 4        # 続10: 同じ組・違う組がそれぞれこれより少なければ AUC は null（仮）
COHORT_TOP = 50


def is_watch(name) -> bool:
    return isinstance(name, str) and bool(WATCH.search(name))


def auc(pos: list[float], neg: list[float]) -> float | None:
    """同じ組の点が違う組の点より高い割合（同点は半分）。どちらかが空なら None"""
    if not pos or not neg:
        return None
    a, b = np.asarray(pos, dtype=float), np.asarray(neg, dtype=float)
    wins = (a[:, None] > b[None, :]).sum() + 0.5 * (a[:, None] == b[None, :]).sum()
    return round(float(wins / (len(a) * len(b))), 3)


def folder(home: Path) -> Path:
    return Path(home) / "s23" / "review"


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


def answers(base: Path | None) -> dict[str, bool]:
    """本人の答え {組の id: 同じ人なら True}（same_person の merged/different と、vp- の yes/no。あとの答えが勝つ）"""
    out: dict[str, bool] = {}
    if base is None:
        return out
    try:
        rows = (Path(base) / "inbox" / "app_feedback.jsonl").read_text(encoding="utf-8").splitlines()
    except OSError:
        return out
    for raw in rows:
        try:
            row = json.loads(raw)
        except ValueError:
            continue
        if not isinstance(row, dict) or not row.get("id"):
            continue
        if row.get("kind") == "same_person" and row.get("value") in ("merged", "different"):
            out[str(row["id"])] = row["value"] == "merged"
        elif row.get("kind") == "review" and str(row["id"]).startswith("vp-") and row.get("answer") in ("yes", "no", "はい", "いいえ"):
            out[str(row["id"])] = row["answer"] in ("yes", "はい")
    return out


def _sample(item) -> dict | None:
    if not isinstance(item, dict) or not isinstance(item.get("audio"), str):
        return None
    try:
        start, end = float(item["start"]), float(item["end"])
    except (KeyError, TypeError, ValueError):
        return None
    return {"audio": item["audio"], "start": start, "end": end} if end > start else None


def groups_with_samples(home: Path) -> dict[str, dict]:
    """{id: {"people": [[見本…], …], "score": 今の点 or None, "day"}}（same-person の日ごとの組・日をまたぐ組・名前のある人かも・
    続1 の 2 つの声の問い）"""
    out: dict[str, dict] = {}
    base = Path(home) / "same-person"
    for path in sorted(base.glob("2???-??-??.json")):
        for group in (_read(path, {}) or {}).get("groups") or []:
            if isinstance(group, dict) and group.get("id"):
                out[str(group["id"])] = {"people": [[s for s in map(_sample, p.get("samples") or []) if s]
                                                    for p in group.get("people") or [] if isinstance(p, dict)],
                                         "score": group.get("score"), "day": path.stem}
    extra = _read(base / "voices.json", {}) or {}
    for item in extra.get("across") or []:
        if isinstance(item, dict) and item.get("id"):
            out[str(item["id"])] = {"people": [[s for s in map(_sample, p.get("samples") or []) if s]
                                               for p in item.get("people") or [] if isinstance(p, dict)],
                                    "score": item.get("score"), "day": item.get("day")}
    for item in extra.get("maybe") or []:
        if isinstance(item, dict) and item.get("id"):
            person, named = item.get("person") or {}, item.get("named") or {}
            out[str(item["id"])] = {"people": [[s for s in map(_sample, person.get("samples") or []) if s],
                                               [s for s in map(_sample, named.get("samples") or []) if s]],
                                    "score": item.get("score"), "day": item.get("day")}
    for pid, pair in ((_read(folder(home) / "voice-pairs.json", {}) or {}).get("pairs") or {}).items():
        a, b = _sample(pair.get("a")), _sample(pair.get("b"))
        if a and b:
            out[str(pid)] = {"people": [[a], [b]], "score": None, "day": pair.get("day")}
    return out


def watch_pairs(home: Path, base: Path | None, limit: int = WANTED) -> list[dict]:
    """続1: 本人の答えがあり、見本が全部時計の声の組（新しい順に limit まで）。[{"id","same","people","day"}]"""
    known = answers(base)
    out = []
    for gid, group in groups_with_samples(home).items():
        if gid not in known:
            continue
        people = [p for p in group["people"] if p]
        if len(people) < 2 or not all(is_watch(s["audio"]) for p in people for s in p):
            continue
        out.append({"id": gid, "same": known[gid], "people": people, "day": str(group.get("day") or "")})
    out.sort(key=lambda g: g["day"], reverse=True)
    return out[:limit]


# MARK: - 続1 2 つの声の問いを作る


def _hash(text: str) -> str:
    return hashlib.sha1(text.encode("utf-8")).hexdigest()[:10]


def _clip(sample: dict) -> str:
    length = round(max(PAIR_MIN, min(PAIR_MAX, sample["end"] - sample["start"])), 2)
    return f"audio-clip?audio={sample['audio']}&offset={round(sample['start'], 2)}&length={length}"


def pair_candidates(parsed: dict, day: str) -> list[tuple[str, dict, dict]]:
    """その日の時計の行から [(見込み "same"|"different", 行 a, 行 b)]。同じ見込みは同じ人物N の別の区切りの 2 行、
    違う見込みは同じ会話の話し手の違う 2 行（自分と人物N・人物N どうし）。話し手の分からない行・動画の声の行は使わない"""
    import voices

    rows = []
    for conversation in parsed.get("conversations") or []:
        if conversation.get("media"):
            continue
        for line in conversation.get("lines") or []:
            audio, start, end = line.get("audio"), line.get("offset"), line.get("end")
            if line.get("media") is not None or not is_watch(audio) or not isinstance(line.get("time"), int):
                continue
            try:
                start, end = float(start), float(end)
            except (TypeError, ValueError):
                continue
            label = voices.label_of(line)
            if label is None or not PAIR_MIN <= end - start <= PAIR_MAX:
                continue
            rows.append({"label": label, "audio": audio, "start": start, "end": end, "time": line["time"],
                         "text": " ".join(str(line.get("text") or "").split())[:TEXT_MAX],
                         "conv": conversation.get("start")})
    same, different = [], []
    by_label: dict[str, list[dict]] = {}
    for row in rows:
        by_label.setdefault(row["label"], []).append(row)
    for label, items in sorted(by_label.items()):
        if not label.startswith("u:"):
            continue
        for a in items:
            b = next((x for x in items if x["audio"] != a["audio"]), None)
            if b is not None:
                same.append(("same", a, b))
                break
    by_conv: dict = {}
    for row in rows:
        by_conv.setdefault(row["conv"], []).append(row)
    for _, items in sorted(by_conv.items(), key=lambda kv: str(kv[0])):
        firsts: dict[str, dict] = {}
        for row in items:
            firsts.setdefault(row["label"], row)
        labels = sorted(firsts)
        if len(labels) >= 2:
            different.append(("different", firsts[labels[0]], firsts[labels[1]]))
    out = []
    for pair in zip(same, different):
        out.extend(pair)
    out.extend(same[len(different):] or different[len(same):])
    return out


def make_pair_items(home: Path, parsed: dict | None, day: str, base: Path | None, config: dict | None,
                    today: datetime.date | None = None) -> list[dict]:
    """続1: その日の 2 つの声の問いを作って HOME/s23/review/voice-pairs.json に残し、まだ答えの無い問いを返す
    （s22 の確かめ待ちの形。kind "voice_pair"・answer "yesno"・clips 2 つ）"""
    today = today or datetime.date.today()
    path = folder(home) / "voice-pairs.json"
    body = _read(path, {}) or {}
    pairs: dict = body.get("pairs") if isinstance(body.get("pairs"), dict) else {}
    known = answers(base)
    enough = len(watch_pairs(home, base)) >= WANTED
    on = (config or {}).get("voice_pairs") is not False
    if on and not enough and parsed is not None and not any(p.get("day") == day for p in pairs.values()):
        made = 0
        for guess, a, b in pair_candidates(parsed, day):
            if made >= PAIRS_PER_DAY:
                break
            pid = "vp-" + _hash(f"{day}|{a['time']}|{b['time']}")
            if pid in pairs:
                continue
            pairs[pid] = {"day": day, "guess": guess, "made_at": datetime.datetime.now().isoformat(timespec="seconds"),
                          **{k: {"audio": r["audio"], "start": r["start"], "end": r["end"], "time": r["time"], "text": r["text"]}
                             for k, r in (("a", a), ("b", b))}}
            made += 1
        body = {"version": 1, "note": "s23 続1。2 つの時計の声が同じ人かの問い（答えは母艦 inbox/app_feedback.jsonl の kind review）",
                "pairs": pairs}
        _write(path, body)
    items = []
    limit = (today - datetime.timedelta(days=EXPIRE_DAYS)).isoformat()
    if not on:
        return items
    for pid, pair in sorted(pairs.items(), key=lambda kv: str(kv[1].get("day")), reverse=True):
        if pid in known or str(pair.get("day") or "") < limit:
            continue
        a, b = pair.get("a") or {}, pair.get("b") or {}
        if not (_sample(a) and _sample(b)):
            continue
        expires = (datetime.date.fromisoformat(pair["day"]) + datetime.timedelta(days=EXPIRE_DAYS)).isoformat()
        items.append({"id": pid, "kind": "voice_pair", "question": "この 2 つの声は同じ人ですか（声だけで決めてください）",
                      "answer": "yesno", "group": "voice_pair", "priority": 0.5, "today": False, "expires": expires,
                      "clips": [{"label": "声 1", "path": _clip(_sample(a))}, {"label": "声 2", "path": _clip(_sample(b))}],
                      "evidence": [{"text": str(a.get("text") or "")[:TEXT_MAX], "ref": f"{pair['day']}|{a.get('time')}"},
                                   {"text": str(b.get("text") or "")[:TEXT_MAX], "ref": f"{pair['day']}|{b.get('time')}"}]})
    return items


# MARK: - 続10 s-norm の答え合わせ


def snorm_check(home: Path, base: Path | None) -> dict:
    """{"snorm_auc","raw_auc","snorm_pairs","snorm_same","raw_pairs"}（答えのある組だけ。少なければ AUC は None）"""
    known = answers(base)
    items = (_read(Path(home) / "same-person" / "snorm.json", {}) or {}).get("items") or {}
    groups = groups_with_samples(home)
    sn_pos, sn_neg, raw_pos, raw_neg = [], [], [], []
    for gid, same in known.items():
        value = (items.get(gid) or {}).get("snorm")
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            (sn_pos if same else sn_neg).append(float(value))
        raw = (groups.get(gid) or {}).get("score")
        if isinstance(raw, (int, float)) and not isinstance(raw, bool):
            (raw_pos if same else raw_neg).append(float(raw))

    def enough(pos, neg):
        return auc(pos, neg) if len(pos) >= MIN_PAIRS_AUC and len(neg) >= MIN_PAIRS_AUC else None

    return {"snorm_auc": enough(sn_pos, sn_neg), "snorm_pairs": len(sn_pos) + len(sn_neg), "snorm_same": len(sn_pos),
            "raw_auc": enough(raw_pos, raw_neg), "raw_pairs": len(raw_pos) + len(raw_neg)}


# MARK: - 続1 声の特徴で組の点を出す（測る台本と、影で並べる見回りの両方が使う）


def centroid(vectors: list[np.ndarray], mean: np.ndarray | None) -> np.ndarray | None:
    vs = [v - mean if mean is not None else v for v in vectors if v is not None]
    if not vs:
        return None
    c = np.mean(vs, axis=0)
    n = float(np.linalg.norm(c))
    return c / n if n > 0 else None


def pair_scores(vec: Callable[[dict], np.ndarray | None], pairs: list[dict], cohort: list[dict]) -> dict:
    """答えのある組の点（日の平均を引いた真ん中の近さ・s-norm）と AUC。vec(見本) は長さ 1 の声の特徴か None"""
    coh = [v for v in (vec(s) for s in cohort) if v is not None]
    mean = np.mean(coh, axis=0) if coh else None
    cmat = np.asarray([(c - mean) / (np.linalg.norm(c - mean) + 1e-9) for c in coh]) if len(coh) >= 10 else None
    raw_s, raw_d, sn_s, sn_d = [], [], [], []
    scored = []
    for pair in pairs:
        cents = [centroid([vec(s) for s in people], mean) for people in pair["people"][:2]]
        if any(c is None for c in cents):
            continue
        a, b = cents
        raw = float(a @ b)
        sn = None
        if cmat is not None:
            sa, sb = np.sort(cmat @ a)[-COHORT_TOP:], np.sort(cmat @ b)[-COHORT_TOP:]
            sn = float(0.5 * ((raw - sa.mean()) / (sa.std() + 1e-6) + (raw - sb.mean()) / (sb.std() + 1e-6)))
        (raw_s if pair["same"] else raw_d).append(raw)
        if sn is not None:
            (sn_s if pair["same"] else sn_d).append(sn)
        scored.append({"id": pair["id"], "same": pair["same"], "raw": round(raw, 4), "snorm": None if sn is None else round(sn, 3)})
    return {"pairs": len(scored), "same": len(raw_s), "auc_raw": auc(raw_s, raw_d), "auc_snorm": auc(sn_s, sn_d), "scored": scored}


def cohort_from(parsed_days: list[dict], limit: int = 250, seed: int = 23) -> list[dict]:
    """ならし用の見本（記録の時計の行 2〜15 秒から limit まで。決まった順で選ぶ）"""
    import random

    import voices

    rows = []
    for parsed in parsed_days:
        for seg in voices.segments(parsed or {}):
            if is_watch(seg["audio"]) and 2.0 <= seg["end"] - seg["start"] <= 15.0:
                rows.append({"audio": seg["audio"], "start": seg["start"], "end": seg["end"]})
    random.Random(seed).shuffle(rows)
    return rows[:limit]
