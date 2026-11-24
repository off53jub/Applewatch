"""LifeLog PC: 1 人の名前に声が集まりすぎている話し手を見つけ、「分けるかも」の候補を出す（s20 の次5。2026-11-21）。

自動では分けない・名前を付け替えない・まとめない。候補（見立て・仮）と根拠（その話し手の行から、2 つの群それぞれの代表の行）を出すだけで、
分けるかどうかは本人が聞いて決める（アプリの確かめ待ち → 本人が押したときだけ、アプリが元に戻せる直しをする）。
言語モデルは使わない（0 円）。声の特徴は voices/<日>.npz にある今までのもの（新しくは測らない）。

見つけ方（直近 window_days 日。名前のある人・名前の無い人物N。自分は見ない）:
- 声の特徴のある行が min_items 以上ある話し手だけ（少ないとばらつきが当てにならない）。
- 声の特徴（長さ 1 にそろえたもの）を 2-means（決まった初期値・乱数なし）で 2 つの群に分け、
  ・群の真ん中どうしの近さ（centroid_cos）が split_cos 以下
  ・小さいほうの群が全体の min_share 以上・どちらの群も min_cluster 行以上
  ・両方の群が同じ音声（区切り）に出る割合（mixed）が max_mixed 以下＝群が別々の場面に分かれている（同じ場面に両方出るのは、
   同じ人の声の揺れの可能性が高い）
  のときだけ候補にする。しきい値はすべて仮（DEFAULTS。config.json の "speaker_split" で上書き）。測った数は docs と PR に。
- 重い仕事なので voices.heavy_ok の時間だけ（00:00〜05:00・08:30〜18:00）。最後に作ってから min_gap_hours 時間は作り直さない。

置き場所: HOME/speaker-split/candidates.json（作り直すたびに置き換え）。母艦 inbox/speaker-split/candidates.json に同じ写し。
GET /speaker-split（knowme の口）。items の 1 件は、母艦の確かめ待ちの列（review_queue_for_app.json）の形そのまま:
  {"id", "kind": "speaker_split", "question", "answer": "yesno", "choices"?, "evidence": [{"text", "ref", …}], "expires", "group"}
  に、省略可能な欄（label・text・clusters・centroid_cos…）が足してある。answer は「同じ人（はい）」「別の人（いいえ）」。
記録（log.txt）には数だけ（人名・文は書かない）。
"""

from __future__ import annotations

import datetime
import json
import os
import re
import time
from pathlib import Path
from typing import Callable

import numpy as np

import voices

FOLDER = "speaker-split"
FILE = "candidates.json"
MOTHER_FILE = Path("inbox") / "speaker-split" / FILE
VERSION = 1
LABEL = "見立て（仮）"
KIND = "speaker_split"

DEFAULTS = {
    "_note": "仮（2026-11-21・P）。直すのは本人かまとめ役。測った数は PR の説明",
    "enabled": True,
    "window_days": 14,        # 仮: 見る日数
    "min_items": 40,          # 仮: 声の特徴のある行がこれ未満の話し手は見ない
    "split_cos": 0.40,        # 仮: 2 群の真ん中どうしの近さがこれ以下
    "min_share": 0.10,        # 仮: 小さいほうの群の割合
    "min_cluster": 15,        # 仮: どちらの群もこの行数以上
    "max_mixed": 0.5,         # 仮: 両方の群が同じ音声に出る割合がこれ以下
    "samples": 3,             # 各群の代表の行の数
    "max_candidates": 10,
    "expires_days": 14,       # 確かめ待ちの列で流れる日数
    "skip_self": True,
    "min_gap_hours": 6.0,     # 仮: 作り直しの間隔
}
SELF = "me"
TEXT_HEAD = 30


def settings(config: dict | None) -> dict:
    out = dict(DEFAULTS)
    mine = (config or {}).get("speaker_split")
    if isinstance(mine, dict):
        out.update({k: v for k, v in mine.items() if k in DEFAULTS and not k.startswith("_")})
    return out


def _write(path: Path, data: dict) -> bool:
    text = json.dumps(data, ensure_ascii=False, indent=1)
    try:
        if path.read_text(encoding="utf-8") == text:
            return False
    except OSError:
        pass
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)
    return True


def _read(path: Path) -> dict | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def gather(home: Path, store, days: list[str]) -> dict[str, dict]:
    """話し手の印ごとに、声の特徴（長さ 1）と行の位置。{印: {"vecs": [..], "rows": [..], "days": set, "name": 名前}}"""
    labels: dict[str, dict] = {}
    for day in days:
        parsed = store.day(day) if store is not None else None
        if parsed is None:
            continue
        ds = voices.DayStore(home, day).load()
        if not ds.vectors:
            continue
        for seg in voices.segments(parsed):
            label = seg["label"]
            vec = ds.vectors.get(seg["key"])
            if label is None or vec is None:
                continue
            unit = voices._unit(np.asarray(vec, dtype=np.float64))
            if unit is None:
                continue
            entry = labels.setdefault(label, {"vecs": [], "rows": [], "days": set(), "name": ""})
            entry["vecs"].append(unit)
            entry["days"].add(day)
            line = seg["line"]
            entry["rows"].append({"day": day, "audio": seg["audio"], "start": seg["start"], "end": seg["end"],
                                  "time": line.get("time"), "text": line.get("text") or ""})
            if line.get("speaker"):
                entry["name"] = line["speaker"]
    return labels


def two_means(vectors: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """長さ 1 の特徴を 2 群に分ける（コサインの 2-means。初期値は「真ん中から最も遠い 1 つ」と「それから最も遠い 1 つ」。乱数なし）。
    (群の番号の並び, 2 つの真ん中) を返す"""
    mean = vectors.mean(axis=0)
    mean = mean / np.linalg.norm(mean)
    first = vectors[int(np.argmin(vectors @ mean))]
    second = vectors[int(np.argmin(vectors @ first))]
    centers = np.stack([first, second])
    assign = np.argmax(vectors @ centers.T, axis=1)
    for _ in range(30):
        assign = np.argmax(vectors @ centers.T, axis=1)
        fresh = []
        for k in (0, 1):
            part = vectors[assign == k]
            c = part.mean(axis=0) if len(part) else centers[k]
            fresh.append(c / np.linalg.norm(c))
        fresh = np.stack(fresh)
        if np.allclose(fresh, centers):
            break
        centers = fresh
    return assign, centers


def measure(entry: dict) -> dict:
    """1 人ぶんの数: 行数・2 群の真ん中どうしの近さ・小さい群の割合・同じ音声に両方出る割合"""
    vectors = np.stack(entry["vecs"])
    assign, centers = two_means(vectors)
    sizes = [int((assign == k).sum()) for k in (0, 1)]
    audios = [{r["audio"] for r, a in zip(entry["rows"], assign) if a == k} for k in (0, 1)]
    union = audios[0] | audios[1]
    return {"items": len(vectors), "days": len(entry["days"]), "centroid_cos": float(centers[0] @ centers[1]),
            "share": min(sizes) / len(vectors), "sizes": sizes,
            "mixed": len(audios[0] & audios[1]) / len(union) if union else 1.0,
            "assign": assign, "centers": centers, "vectors": vectors}


def is_candidate(numbers: dict, cfg: dict) -> bool:
    return (numbers["centroid_cos"] <= cfg["split_cos"] and numbers["share"] >= cfg["min_share"]
            and min(numbers["sizes"]) >= cfg["min_cluster"] and numbers["mixed"] <= cfg["max_mixed"])


def _iso(moment) -> str | None:
    return moment if isinstance(moment, str) else None


def build_item(label: str, entry: dict, numbers: dict, cfg: dict, today: datetime.date) -> dict:
    who = entry["name"] or label
    samples, evidence, clusters = cfg["samples"], [], []
    for k, tag in ((0, "A"), (1, "B")):
        idx = [i for i, a in enumerate(numbers["assign"]) if a == k]
        near = sorted(idx, key=lambda i: -float(numbers["vectors"][i] @ numbers["centers"][k]))
        pick, seen = [], set()
        for i in near:  # 代表の行は、なるべく違う音声から
            if entry["rows"][i]["audio"] in seen:
                continue
            seen.add(entry["rows"][i]["audio"])
            pick.append(i)
            if len(pick) >= samples:
                break
        for i in pick:
            row = entry["rows"][i]
            head = re.sub(r"\s+", " ", row["text"]).strip()[:TEXT_HEAD]
            item = {"text": f"{tag}の声: {head}" if head else f"{tag}の声", "cluster": tag, "day": row["day"],
                    "ref": voices.seg_key(row["audio"], row["start"], row["end"])}
            when = _iso(row["time"])
            if when:
                item["line_time"] = when
            evidence.append(item)
        clusters.append({"cluster": tag, "lines": len(idx), "days": len({entry["rows"][i]["day"] for i in idx})})
    expires = (today + datetime.timedelta(days=int(cfg["expires_days"]))).isoformat()
    return {"id": f"split-{label}", "kind": KIND, "group": KIND, "answer": "yesno", "label": LABEL,
            "question": f"「{who}」の声が、2 人ぶん混ざっているかもしれません（仮）。A の声と B の声は、同じ人ですか？"
                        "（はい＝同じ人・いいえ＝別の人）",
            "text": f"「{who}」の声が 2 つの群に分かれます（行 {numbers['items']}・{numbers['days']} 日）。分けるかは聞いて決めてください。",
            "speaker": label, "evidence": evidence, "clusters": clusters, "expires": expires,
            "centroid_cos": round(numbers["centroid_cos"], 3), "mixed": round(numbers["mixed"], 2),
            "why": f"2 群の声の近さ {numbers['centroid_cos']:.2f}（しきい値 {cfg['split_cos']}・仮）・"
                   f"小さい群 {numbers['share']:.0%}・同じ音声に両方出る割合 {numbers['mixed']:.0%}"}


def build(home: Path, store, config: dict | None = None, today: datetime.date | None = None) -> dict:
    cfg = settings(config)
    today = today or datetime.date.today()
    days = [(today - datetime.timedelta(days=i)).isoformat() for i in range(int(cfg["window_days"]))]
    labels = gather(home, store, days)
    items, checked, near = [], 0, 0
    for label, entry in sorted(labels.items(), key=lambda kv: -len(kv[1]["vecs"])):
        if (cfg["skip_self"] and label == SELF) or len(entry["vecs"]) < int(cfg["min_items"]):
            continue
        checked += 1
        numbers = measure(entry)
        if is_candidate(numbers, cfg):
            items.append(build_item(label, entry, numbers, cfg, today))
        elif numbers["centroid_cos"] <= cfg["split_cos"] + 0.1:
            near += 1
    items = items[:int(cfg["max_candidates"])]
    return {"version": VERSION, "made_on": today.isoformat(),
            "generated_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
            "window": {"from": days[-1], "to": days[0]},
            "thresholds": {**{k: v for k, v in cfg.items() if not k.startswith("_")}, "仮": True},
            "summary": {"speakers": len(labels), "checked": checked, "candidates": len(items), "near_misses": near},
            "items": items}


def run(home: Path, store, mother: Path | None, config: dict, log: Callable[[str], None], heavy: bool,
        mother_copy: bool = True, today: datetime.date | None = None, force: bool = False) -> dict:
    cfg = settings(config)
    if not cfg["enabled"]:
        return {"skipped": "stopped"}
    target = Path(home) / FOLDER / FILE
    if not force:
        if not heavy:
            return {"skipped": "not heavy time"}
        try:
            if time.time() - target.stat().st_mtime < float(cfg["min_gap_hours"]) * 3600:
                return {"skipped": "recent"}
        except OSError:
            pass
    built = build(home, store, config, today)
    _write(target, built)
    copied = 0
    if mother_copy and mother is not None and Path(mother).is_dir():
        import s24rules  # s24 当1（取り決め C4）: 母艦の確かめ待ちにも、same_person_ask のときだけ問いを写す

        copied = int(_write(Path(mother) / MOTHER_FILE, s24rules.hold_items(built, config)))
    s = built["summary"]
    log(f"集まりすぎの話し手: 話し手 {s['speakers']}・見た {s['checked']}・候補 {s['candidates']}（惜しい {s['near_misses']}）・母艦へ {copied}")
    return {"checked": s["checked"], "candidates": s["candidates"], "copied": copied}


def read(home: Path) -> dict:
    """GET /speaker-split（古い・読めないものは出さない）"""
    path = Path(home) / FOLDER / FILE
    data = _read(path)
    if not data or not isinstance(data.get("items"), list):
        return {"available": False, "reason": "まだ見つけていません（重い仕事の時間に作ります）"}
    try:
        if time.time() - path.stat().st_mtime > 3 * 86400:
            return {"available": False, "reason": "古くなっています"}
    except OSError:
        return {"available": False}
    return {"available": True, **data}
