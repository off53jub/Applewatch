"""LifeLog PC: 同じ日の名前の無い「人物N」を、声の近さで「同じ人かも」の組にする（施策 10。2026-11-13）。

- 夜（quality.py の夜の流れ。00:00〜05:00）と、頼まれたとき（GET /same-person?refresh=1）に、その日の記録
  （HOME/records/<日>.json）の「人物N」ごとに、行の音声（HOME/audio か HOME/jobs に残っているもの）から
  声の特徴（/speakers と同じ CAM++）を CLIPS 個まで取り、真ん中どうしの近さ（コサイン）で組にする。
- 組にするのは、名前の無い「人物N」だけ（名前のある人・自分・テレビなどの声は入れない）。
  同じ区切り（同じ音声）の中に出てきた2つは、iPhone の聞き分けが別の声と分けたものなので、組にしない。
- 自動ではまとめない。アプリの「直す」の「同じ人かも」に出し、本人が「同じ人」を押したときだけ、
  アプリの「まとめる」（Pipeline.mergePerson。元に戻せる）を使う。
- 置き場所: HOME/same-person/<日>.json（作り直すたびに置き換え。7 日より古いものは消す）。
  記録（log.txt）には数だけを書く（文・名前は書かない）。

GET /same-person（features の "sameperson"）→
  {"available": true, "generated_at": ISO, "days": [{"day", "groups": [{"id", "score",
     "people": [{"id": "12", "name": "人物12", "lines": int, "seconds": float,
                 "samples": [{"time": ISO, "text": str(≤40), "audio": str, "start": float, "end": float}](≤3)}](2〜4)}](≤20)}](≤3)}
  まだ作っていない・作れないときは {"available": false, "reason": …}。
  2026-11-15（強化案 56。voices.py）: 省ける "across"（日をまたぐ組。上の組と同じ形に "day"（いちばん新しい日）・
  "days"・人ごとの "days" を足したもの・≤20）と "maybe"（名前のある人かも。{"id", "day", "score", "margin",
  "person": 上の人の形, "named": {"id", "name"}}・≤20）を quality.http_get が足す。
"""

from __future__ import annotations

import datetime
import hashlib
import json
import os
import re
import threading
import time
from pathlib import Path
from typing import Callable

import numpy as np

UNNAMED = re.compile(r"人物(\d+)")
FOLDER = "same-person"
CLIPS = 3              # 1つの人物N から声の特徴を取る行の数
CLIP_MIN = 1.5         # 行の長さ（秒）。短い行は声の特徴がぶれる
CLIP_MAX = 20.0
LINK = 0.60            # 仮: 日の平均を引いた真ん中どうしのコサインがこれ以上なら「同じ人かも」（docs/s2-accuracy-2026-11-13.md）
GROUP_MAX = 4          # 1つの組の人物N の数
GROUPS_PER_DAY = 20
SAMPLES = 3
KEEP_DAYS = 7
SERVE_DAYS = 3
TEXT_MAX = 40

_lock = threading.Lock()


def folder(home: Path) -> Path:
    return Path(home) / FOLDER


def _iso(ms: int | float) -> str:
    """記録の行の時刻（records.iso_ms と同じ形。UTC・ミリ秒つき。アプリが行を時刻で探せるように）"""
    moment = datetime.datetime(1970, 1, 1, tzinfo=datetime.timezone.utc) + datetime.timedelta(milliseconds=int(ms))
    return moment.strftime("%Y-%m-%dT%H:%M:%S") + f".{int(ms) % 1000:03d}Z"


def _text(value, n: int = TEXT_MAX) -> str:
    return " ".join(str(value or "").split())[:n]


# MARK: - 人物N ごとの行


def unnamed_labels(parsed: dict) -> dict[str, dict]:
    """その日の記録（records.parse_record の形）から、名前の無い「人物N」ごとの行。
    {"12": {"name": "人物12", "lines": [行…], "audios": {音声の名前…}, "seconds": float}}"""
    labels: dict[str, dict] = {}
    for conversation in parsed.get("conversations") or []:
        if conversation.get("media"):
            continue
        for line in conversation.get("lines") or []:
            name = line.get("speaker") or ""
            match = UNNAMED.fullmatch(name)
            if not match or line.get("media") is not None:
                continue
            ident = match.group(1)
            if line.get("speakerID") not in (None, ident):
                continue  # 名前と番号が合わない行は使わない（名前の付いた人の番号かもしれない）
            entry = labels.setdefault(ident, {"name": name, "lines": [], "audios": set(), "seconds": 0.0})
            entry["lines"].append(line)
            if line.get("audio"):
                entry["audios"].add(line["audio"])
            offset, end = line.get("offset"), line.get("end")
            if isinstance(offset, (int, float)) and isinstance(end, (int, float)) and end > offset:
                entry["seconds"] += float(end) - float(offset)
    return labels


def pick_clips(lines: list[dict], count: int = CLIPS) -> list[dict]:
    """声の特徴を取る行（長い順。なるべく違う区切りから）"""
    usable = []
    for line in lines:
        offset, end = line.get("offset"), line.get("end")
        if not line.get("audio") or not isinstance(offset, (int, float)) or not isinstance(end, (int, float)):
            continue
        length = float(end) - float(offset)
        if CLIP_MIN <= length <= CLIP_MAX:
            usable.append((length, line))
    usable.sort(key=lambda x: -x[0])
    picked, seen = [], set()
    for _, line in usable:
        if line["audio"] in seen:
            continue
        picked.append(line)
        seen.add(line["audio"])
        if len(picked) >= count:
            return picked
    for _, line in usable:
        if line not in picked:
            picked.append(line)
            if len(picked) >= count:
                break
    return picked


def apart_pairs(labels: dict[str, dict]) -> set[tuple[str, str]]:
    """同じ区切り（同じ音声）に出てきた2つ（iPhone が別の声と分けた）"""
    by_audio: dict[str, list[str]] = {}
    for ident, entry in labels.items():
        for audio in entry["audios"]:
            by_audio.setdefault(audio, []).append(ident)
    pairs = set()
    for ids in by_audio.values():
        ids = sorted(set(ids))
        for i, a in enumerate(ids):
            for b in ids[i + 1:]:
                pairs.add((a, b))
    return pairs


def centroid(vectors: list) -> np.ndarray | None:
    usable = [np.asarray(v, dtype=np.float64) for v in vectors if v is not None and len(v) > 0]
    if not usable:
        return None
    size = len(usable[0])
    usable = [v for v in usable if len(v) == size]
    center = np.mean(usable, axis=0)
    norm = float(np.linalg.norm(center))
    return center / norm if norm > 0 and np.isfinite(norm) else None


def centered(raw: dict[str, list]) -> dict[str, np.ndarray]:
    """その日の声の特徴の平均を引いてから、人物N ごとの真ん中にする（マイク・部屋の癖を除く。
    引かないと、違う人どうしも近く出た。docs/s2-accuracy-2026-11-13.md）"""
    every = [v for vectors in raw.values() for v in vectors]
    if not every:
        return {}
    size = len(every[0])
    every = [v for v in every if len(v) == size]
    mean = np.mean(every, axis=0) if len(every) >= 2 else np.zeros(size)
    out = {}
    for ident, vectors in raw.items():
        center = centroid([v - mean for v in vectors if len(v) == size])
        if center is not None:
            out[ident] = center
    return out


def group(centers: dict[str, np.ndarray], apart: set[tuple[str, str]], link: float = LINK,
          size: int = GROUP_MAX) -> list[tuple[list[str], float]]:
    """平均の近さでまとめていく（近い組から。同じ区切りに出た2つは同じ組にしない・size まで）。
    返すのは 2 つ以上の組と、その組の中の近さの平均（高い順）"""
    ids = sorted(centers, key=lambda x: int(x) if x.isdigit() else 0)
    clusters: list[list[str]] = [[i] for i in ids]

    def sim(a: str, b: str) -> float:
        return float(np.dot(centers[a], centers[b]))

    def linkage(x: list[str], y: list[str]) -> float | None:
        for a in x:
            for b in y:
                if (min(a, b), max(a, b)) in apart:
                    return None
        values = [sim(a, b) for a in x for b in y]
        return sum(values) / len(values)

    while True:
        best: tuple[float, int, int] | None = None
        for i in range(len(clusters)):
            for j in range(i + 1, len(clusters)):
                if len(clusters[i]) + len(clusters[j]) > size:
                    continue
                value = linkage(clusters[i], clusters[j])
                if value is None or value < link:
                    continue
                if best is None or value > best[0]:
                    best = (value, i, j)
        if best is None:
            break
        _, i, j = best
        clusters[i] = clusters[i] + clusters[j]
        del clusters[j]
    out = []
    for members in clusters:
        if len(members) < 2:
            continue
        values = [sim(a, b) for k, a in enumerate(members) for b in members[k + 1:]]
        out.append((members, round(sum(values) / len(values), 3)))
    out.sort(key=lambda x: -x[1])
    return out


def group_id(day: str, members: list[str]) -> str:
    digest = hashlib.sha256((day + "|" + ",".join(sorted(members))).encode("utf-8")).hexdigest()[:12]
    return f"sp-{day.replace('-', '')}-{digest}"


# MARK: - 1日分を作る


def build_day(day: str, parsed: dict, find_audio: Callable[[str], Path | None],
              embed: Callable[[Path, list[tuple[float, float]]], list], link: float = LINK) -> dict:
    """その日の組を作る（置かない）。embed(音声のファイル, [(始まり, 終わり)…]) → 声の特徴の並び（取れない区間は None）"""
    labels = unnamed_labels(parsed)
    raw: dict[str, list] = {}
    for ident, entry in labels.items():
        clips = pick_clips(entry["lines"])
        by_audio: dict[str, list[dict]] = {}
        for line in clips:
            by_audio.setdefault(line["audio"], []).append(line)
        vectors = []
        for audio, lines in by_audio.items():
            path = find_audio(audio)
            if path is None:
                continue
            try:
                got = embed(path, [(float(l["offset"]), float(l["end"])) for l in lines])
            except Exception:  # noqa: BLE001 — 読めない音声は飛ばす
                continue
            vectors.extend(np.asarray(v, dtype=np.float64) for v in got if v is not None and len(v) > 0)
        if vectors:
            raw[ident] = vectors
    centers = centered(raw)
    measured = len(centers)
    groups = []
    for members, score in group(centers, apart_pairs(labels), link)[:GROUPS_PER_DAY]:
        people = []
        for ident in sorted(members, key=lambda x: -len(labels[x]["lines"])):
            entry = labels[ident]
            samples = []
            for line in pick_clips(entry["lines"], SAMPLES):
                samples.append({"time": _iso(line["time"]), "text": _text(line.get("text")), "audio": str(line["audio"]),
                                "start": round(float(line["offset"]), 2), "end": round(float(line["end"]), 2)})
            people.append({"id": ident, "name": entry["name"], "lines": len(entry["lines"]),
                           "seconds": round(entry["seconds"], 1), "samples": samples})
        groups.append({"id": group_id(day, members), "score": score, "people": people})
    return {"version": 1, "day": day, "generated_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
            "labels": len(labels), "measured": measured, "groups": groups}


def save_day(home: Path, built: dict) -> Path:
    target = folder(home) / f"{built['day']}.json"
    target.parent.mkdir(parents=True, exist_ok=True)
    part = target.with_name(target.name + ".part")
    with _lock:
        part.write_text(json.dumps(built, ensure_ascii=False), encoding="utf-8")
        os.replace(part, target)
    return target


def prune(home: Path, now: float | None = None) -> int:
    limit = (time.time() if now is None else now) - KEEP_DAYS * 86400
    gone = 0
    for path in folder(home).glob("????-??-??.json"):
        try:
            if path.stat().st_mtime < limit:
                path.unlink()
                gone += 1
        except OSError:
            pass
    return gone


def run_day(home: Path, store, day: str, find_audio, embed, log: Callable[[str], None]) -> int | None:
    """その日の組を作って置く。組の数を返す（記録が無ければ None）。文・名前は記録に書かない"""
    parsed = store.day(day) if store is not None else None
    if parsed is None:
        return None
    started = time.time()
    built = build_day(day, parsed, find_audio, embed)
    save_day(home, built)
    prune(home)
    log(f"同じ人かも（{day}）: 人物N {built['labels']}・声を測れた {built['measured']} → 組 {len(built['groups'])}、"
        f"{time.time() - started:.0f} 秒")
    return len(built["groups"])


# MARK: - GET /same-person


def _valid_group(g) -> bool:
    if not isinstance(g, dict) or not isinstance(g.get("id"), str) or not isinstance(g.get("people"), list):
        return False
    if not 2 <= len(g["people"]) <= GROUP_MAX:
        return False
    for p in g["people"]:
        if not isinstance(p, dict) or not UNNAMED.fullmatch(str(p.get("name") or "")) \
                or str(p.get("name"))[2:] != str(p.get("id")):
            return False
    return True


def read(home: Path) -> dict:
    files = sorted(folder(home).glob("????-??-??.json"), reverse=True)[:SERVE_DAYS]
    if not files:
        return {"available": False, "reason": "まだ「同じ人かも」を作っていません"}
    days, generated = [], ""
    for path in files:
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not isinstance(data, dict) or not isinstance(data.get("groups"), list):
            continue
        groups = [g for g in data["groups"] if _valid_group(g)][:GROUPS_PER_DAY]
        days.append({"day": str(data.get("day") or path.stem), "groups": groups})
        generated = max(generated, str(data.get("generated_at") or ""))
    if not days:
        return {"available": False, "reason": "「同じ人かも」を読めませんでした"}
    return {"available": True, "generated_at": generated, "days": days}
