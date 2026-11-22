"""LifeLog PC: s22（2026-11-22）の人と声の分。決まりと測った数は docs/s22-pc.md。0 円・言語モデルなし。

どれも「印」「候補」を出すだけ。記録の話し手は変えない・人をまとめない・名前を付け替えない（まとめるのはアプリで本人が押したとき）。
声の特徴は voices/<日>.npz にある今までのもの（新しくは測らない）。重い所（音の大きさを測る）は 00:00〜05:00・08:30〜18:00 だけ。

- 確1「同じ人か」の点の作り直し: 組の見本の声の特徴から s-norm（その日の人たちの声との近さでならした点）を出し、
  組に省ける "snorm"（数）を足す。短い声（どちらかの見本が合わせて short_seconds 秒より短い）は点を付けない（"snorm": null・"short": true）。
  snorm_min より低い組は GET /same-person に出さない（隠した数は "s22": {"hidden"}）。答えのある 14 組で測った AUC:
  今の点 0.31 → s-norm 0.82（docs）。"score" は前のまま（母艦の答え合わせが読む）。HOME/same-person/snorm.json に {id: {snorm, short}}。
- 確3 区切りをまたいで声をつなぐ: 同じ端末で続いた区切り（間が chain_gap 秒まで）の名前の無い人物N どうしで、
  日の平均を引いた真ん中の近さが chain_link 以上かつ互いにいちばん近い組を「同じ人かも」の候補（id "sc-…"・"why": "chain"）にする。
  同じ区切りに一緒に出た 2 つは組にしない。GET /same-person のその日の groups に足す（今の組と同じ顔ぶれなら足さない）。
- 確5 いそうな人: その日の予定（archive/calendar）・その場所で前に話した人（記録）・直前 3 時間の LINE の相手（archive/line）に
  出てくる名前（記録にもう出てくる名前だけ）は、「名前のある人かも」の近さに prior_bonus を足す（voices.PRIOR_BONUS）。
- 確6 人数が分かるとき: 予定に「N人」「N名」と書いてある会話（時間が重なる予定）と、本人が答えた人数（母艦 inbox/headcount.jsonl。
  形は {"day","start","count"}・まだ誰も書いていない）で、話し手（自分を除く）が N−1 人より多い会話は、近い人物N から順に
  N−1 人になるまでつないだ候補（id "sn-…"・"why": "count"）を出す。
- 確7 通りすがり: その日 1 つの区切りにしか出ず、passerby_lines 行・passerby_seconds 秒以下の人物N に「通りすがり」の札。
- 確8 重なり: 同じ会話で、前の行（ちがう話し手）の終わりが次の行の始まりより overlap_seconds 秒以上あとの 2 行に「重なり」の札。
- 確9 遠い声: 行の音の大きさ（dB）が同じ区切りの声の真ん中より far_db 以上小さい、自分でない行に「遠い声（仮）」の札（初めは札だけ）。
- 確10 動画の声かも: PC で動画・音楽を再生していた時間（s22media.py）に重なる行に「動画の声かも」の札。
置き場所: HOME/s22/speaker-tags/<日>.json（GET /speaker-tags?day=。features "speakertags"）・HOME/s22/chain/<日>.json・
HOME/s22/levels/<日>.json（行と区切りの音の大きさ）。母艦 inbox/speaker-tags/<日>.json に文を除いた写し。
記録（log.txt）には数だけ。
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

import voices

DEFAULTS = {"snorm_min": 1.5, "short_seconds": 4.0, "cohort": 300, "cohort_top": 50,
            "chain_link": 0.50, "chain_gap": 120.0, "chain_max": 20,
            "prior_bonus": 0.02, "line_hours": 3.0,
            "passerby_lines": 2, "passerby_seconds": 8.0,
            "overlap_seconds": 0.3, "far_db": 12.0, "count_max": 10}
FOLDER = "s22"
UNNAMED = re.compile(r"人物(\d+)")
AUDIO_TIME = re.compile(r"(\d{8})-(\d{6})")
HEADCOUNT = re.compile(r"(\d{1,2})\s*[人名]")
SAMPLES = 3
TEXT_MAX = 40
CHUNK_MIN = 45.0
SELF_ID = "me"
SELF_NAME = "自分"

_lock = threading.Lock()
_cache: dict = {}


CONFIG: Callable[[], dict] | None = None   # s22pc.start が lifelog_pc.load_config を入れる


def current_config() -> dict:
    try:
        return (CONFIG() if CONFIG is not None else {}) or {}
    except Exception:  # noqa: BLE001
        return {}


def settings(config: dict | None) -> dict:
    extra = (config or {}).get("s22_voice")
    out = dict(DEFAULTS)
    if isinstance(extra, dict):
        out.update({k: v for k, v in extra.items() if k in DEFAULTS})
    return out


def folder(home: Path, name: str) -> Path:
    return Path(home) / FOLDER / name


def _write(path: Path, body) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    part = path.with_name(path.name + ".part")
    part.write_text(json.dumps(body, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(part, path)


def _read(path: Path, default=None):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def day_of_audio(audio: str) -> str | None:
    match = AUDIO_TIME.search(str(audio or ""))
    if not match:
        return None
    d = match.group(1)
    return f"{d[:4]}-{d[4:6]}-{d[6:8]}"


def audio_epoch(audio: str) -> float | None:
    match = AUDIO_TIME.search(str(audio or ""))
    if not match:
        return None
    try:
        return datetime.datetime.strptime(match.group(1) + match.group(2), "%Y%m%d%H%M%S").timestamp()
    except ValueError:
        return None


def _unit(vector: np.ndarray) -> np.ndarray | None:
    norm = float(np.linalg.norm(vector))
    return vector / norm if norm > 0 and np.isfinite(norm) else None


def day_vectors(home: Path, day: str) -> dict[str, np.ndarray]:
    """voices/<日>.npz の {区間の鍵: 声の特徴}（ファイルが変わったときだけ読み直す）"""
    path = voices.folder(home) / f"{day}.npz"
    try:
        stamp = path.stat().st_mtime
    except OSError:
        return {}
    hit = _cache.get(str(path))
    if hit and hit[0] == stamp:
        return hit[1]
    got = voices.DayStore(home, day).load().vectors
    with _lock:
        _cache[str(path)] = (stamp, got)
        if len(_cache) > 30:
            _cache.pop(next(iter(_cache)))
    return got


# MARK: - 確1 s-norm


def _samples_vectors(home: Path, samples) -> tuple[list[np.ndarray], float, set[str]]:
    vecs, seconds, days = [], 0.0, set()
    for s in samples if isinstance(samples, list) else []:
        if not isinstance(s, dict):
            continue
        audio, start, end = s.get("audio"), s.get("start"), s.get("end")
        day = day_of_audio(audio)
        if day is None or not isinstance(start, (int, float)) or not isinstance(end, (int, float)):
            continue
        vector = day_vectors(home, day).get(voices.seg_key(audio, start, end))
        if vector is None:
            continue
        vecs.append(np.asarray(vector, dtype=np.float64))
        seconds += float(end) - float(start)
        days.add(day)
    return vecs, seconds, days


def _cohort(home: Path, days: set[str], size: int) -> tuple[np.ndarray | None, np.ndarray | None]:
    every = []
    for day in sorted(days):
        every.extend(day_vectors(home, day).values())
    if len(every) < 10:
        return None, None
    matrix = np.asarray(every, dtype=np.float64)
    mean = matrix.mean(axis=0)
    step = max(1, len(matrix) // max(1, size))
    cohort = matrix[::step] - mean
    norms = np.linalg.norm(cohort, axis=1, keepdims=True)
    cohort = cohort / np.where(norms > 0, norms, 1)
    return mean, cohort


def snorm(home: Path, people: list, cfg: dict) -> tuple[float | None, bool]:
    """確1: 見本の並び（人ごとの samples）の組の s-norm。(点, 短い声か)。点を出せなければ None"""
    got = [_samples_vectors(home, samples) for samples in people]
    if len(got) < 2 or any(not vecs for vecs, _, _ in got):
        return None, False
    if any(seconds < float(cfg["short_seconds"]) for _, seconds, _ in got):
        return None, True
    days = set().union(*[d for _, _, d in got])
    mean, cohort = _cohort(home, days, int(cfg["cohort"]))
    if mean is None:
        return None, False
    centers = [_unit(np.mean([v - mean for v in vecs], axis=0)) for vecs, _, _ in got]
    if any(c is None for c in centers):
        return None, False
    top = int(cfg["cohort_top"])
    values = []
    for i in range(len(centers)):
        for j in range(i + 1, len(centers)):
            a, b = centers[i], centers[j]
            raw = float(a @ b)
            sa = np.sort(cohort @ a)[-top:]
            sb = np.sort(cohort @ b)[-top:]
            values.append(0.5 * ((raw - sa.mean()) / (sa.std() + 1e-6) + (raw - sb.mean()) / (sb.std() + 1e-6)))
    return round(float(np.mean(values)), 3), False


def _people_samples(item: dict) -> list:
    if isinstance(item.get("people"), list):
        return [p.get("samples") or [] for p in item["people"] if isinstance(p, dict)]
    person, named = item.get("person"), item.get("named")
    if isinstance(person, dict) and isinstance(named, dict):
        return [person.get("samples") or [], named.get("samples") or []]
    return []


def rescore(home: Path, item: dict, cfg: dict) -> dict:
    value, short = snorm(home, _people_samples(item), cfg)
    out = dict(item)
    out["snorm"] = value
    if short:
        out["short"] = True
    return out


def adjust_same_person(home: Path, body: dict, config: dict | None = None) -> dict:
    """GET /same-person の答えに snorm を足し、低い組を隠し、区切りをまたぐ組・人数の組を足す"""
    cfg = settings(config)
    low = cfg["snorm_min"]
    hidden = 0
    if not isinstance(body, dict):
        return body
    days = body.get("days") if isinstance(body.get("days"), list) else []
    for entry in days:
        if not isinstance(entry, dict):
            continue
        kept = []
        for group in entry.get("groups") or []:
            group = rescore(home, group, cfg)
            if isinstance(low, (int, float)) and group["snorm"] is not None and group["snorm"] < low:
                hidden += 1
                continue
            kept.append(group)
        seen = {frozenset(str(p.get("id")) for p in g.get("people") or []) for g in kept}
        for extra in extra_groups(home, str(entry.get("day") or "")):
            members = frozenset(str(p.get("id")) for p in extra.get("people") or [])
            if members in seen or any(members <= s for s in seen):
                continue
            seen.add(members)
            kept.append(rescore(home, extra, cfg))
        entry["groups"] = kept
    for key in ("across", "maybe"):
        if isinstance(body.get(key), list):
            kept = []
            for item in body[key]:
                item = rescore(home, item, cfg)
                if key == "across" and isinstance(low, (int, float)) and item["snorm"] is not None and item["snorm"] < low:
                    hidden += 1
                    continue
                kept.append(item)
            body[key] = kept
    body["s22"] = {"hidden": hidden, "snorm_min": low}
    return body


def export_snorm(home: Path, config: dict | None = None) -> int:
    """母艦の答え合わせ用に HOME/same-person/snorm.json へ {id: {"snorm", "short"?}}（今ある組の全部）"""
    cfg = settings(config)
    out = {}
    base = Path(home) / "same-person"
    for path in sorted(base.glob("2???-??-??.json")):
        for group in (_read(path, {}) or {}).get("groups") or []:
            if isinstance(group, dict) and group.get("id"):
                got = rescore(home, group, cfg)
                out[group["id"]] = {k: got[k] for k in ("snorm", "short") if k in got}
    extra = _read(base / "voices.json", {}) or {}
    for key in ("across", "maybe"):
        for item in extra.get(key) or []:
            if isinstance(item, dict) and item.get("id"):
                got = rescore(home, item, cfg)
                out[item["id"]] = {k: got[k] for k in ("snorm", "short") if k in got}
    for path in sorted(folder(home, "chain").glob("2???-??-??.json")):
        for group in (_read(path, {}) or {}).get("groups") or []:
            if isinstance(group, dict) and group.get("id"):
                got = rescore(home, group, cfg)
                out[group["id"]] = {k: got[k] for k in ("snorm", "short") if k in got}
    _write(base / "snorm.json", {"generated_at": datetime.datetime.now().isoformat(timespec="seconds"),
                                 "note": "s-norm（仮）。null は短い声か声の特徴が無い組", "items": out})
    return len(out)


# MARK: - 確3・確6 区切りをまたぐ組・人数の組


def _iso(ms) -> str:
    moment = datetime.datetime(1970, 1, 1, tzinfo=datetime.timezone.utc) + datetime.timedelta(milliseconds=int(ms))
    return moment.strftime("%Y-%m-%dT%H:%M:%S") + f".{int(ms) % 1000:03d}Z"


def _text(value, n: int = TEXT_MAX) -> str:
    return " ".join(str(value or "").split())[:n]


def unnamed_by_chunk(home: Path, parsed: dict, day: str) -> tuple[dict, dict, set]:
    """({人物の番号: {"lines", "seconds", "audios", "items", "vecs"}}, {音声: {"start", "length", "watch"}}, 同じ区切りの組)"""
    vectors = day_vectors(home, day)
    people: dict[str, dict] = {}
    chunks: dict[str, dict] = {}
    together: dict[str, set] = {}
    for conversation in parsed.get("conversations") or []:
        if conversation.get("media"):
            continue
        for line in conversation.get("lines") or []:
            audio = line.get("audio")
            if not isinstance(audio, str) or not audio:
                continue
            start, end = line.get("offset"), line.get("end")
            epoch = audio_epoch(audio)
            if epoch is not None:
                chunk = chunks.setdefault(audio, {"start": epoch, "length": 0.0, "watch": audio.endswith("-w.m4a")})
                if isinstance(end, (int, float)):
                    chunk["length"] = max(chunk["length"], float(end))
            match = UNNAMED.fullmatch(str(line.get("speaker") or ""))
            if not match or line.get("media") is not None:
                continue
            ident = match.group(1)
            entry = people.setdefault(ident, {"lines": 0, "seconds": 0.0, "audios": set(), "items": [], "vecs": {}})
            entry["lines"] += 1
            entry["audios"].add(audio)
            together.setdefault(audio, set()).add(ident)
            if isinstance(start, (int, float)) and isinstance(end, (int, float)):
                entry["seconds"] += max(0.0, float(end) - float(start))
                entry["items"].append({"time": line.get("time"), "text": line.get("text"), "audio": audio,
                                       "start": float(start), "end": float(end)})
                vector = vectors.get(voices.seg_key(audio, start, end))
                if vector is not None:
                    entry["vecs"].setdefault(audio, []).append(np.asarray(vector, dtype=np.float64))
    apart = set()
    for members in together.values():
        for a in members:
            for b in members:
                if a < b:
                    apart.add((a, b))
    return people, chunks, apart


def _member(ident: str, entry: dict) -> dict:
    items = sorted(entry["items"], key=lambda x: -(x["end"] - x["start"]))[:SAMPLES]
    return {"id": ident, "name": f"人物{ident}", "lines": entry["lines"], "seconds": round(entry["seconds"], 1),
            "samples": [{"time": _iso(x["time"]) if isinstance(x["time"], (int, float)) else None, "text": _text(x["text"]),
                         "audio": x["audio"], "start": round(x["start"], 2), "end": round(x["end"], 2)} for x in items]}


def _centers(home: Path, day: str, people: dict, audio: str | None = None) -> dict[str, np.ndarray]:
    every = list(day_vectors(home, day).values())
    mean = np.mean(np.asarray(every, dtype=np.float64), axis=0) if len(every) >= 2 else None
    out = {}
    for ident, entry in people.items():
        vecs = entry["vecs"].get(audio, []) if audio else [v for vs in entry["vecs"].values() for v in vs]
        if not vecs or mean is None:
            continue
        center = _unit(np.mean([v - mean for v in vecs], axis=0))
        if center is not None:
            out[ident] = center
    return out


class _Union:
    def __init__(self) -> None:
        self.parent: dict[str, str] = {}

    def find(self, x: str) -> str:
        self.parent.setdefault(x, x)
        while self.parent[x] != x:
            self.parent[x] = self.parent[self.parent[x]]
            x = self.parent[x]
        return x

    def join(self, a: str, b: str) -> None:
        self.parent[self.find(a)] = self.find(b)


def chain_day(home: Path, parsed: dict, day: str, cfg: dict) -> dict:
    """確3: 続いた区切りの人物N をつなぐ候補。{"groups", "people", "after"}"""
    people, chunks, apart = unnamed_by_chunk(home, parsed, day)
    order = sorted(chunks.items(), key=lambda kv: (kv[1]["watch"], kv[1]["start"]))
    per_chunk = {audio: _centers(home, day, {i: e for i, e in people.items() if audio in e["audios"]}, audio)
                 for audio, _ in order}
    links: list[tuple[float, str, str]] = []
    for (a_audio, a), (b_audio, b) in zip(order, order[1:]):
        # 区切りの長さは行の終わりからしか分からない（声の無い終わりは短く見える）ので、45 秒より短くは見ない
        if a["watch"] != b["watch"] or not 0 <= b["start"] - (a["start"] + max(a["length"], CHUNK_MIN)) <= float(cfg["chain_gap"]):
            continue
        left, right = per_chunk.get(a_audio) or {}, per_chunk.get(b_audio) or {}
        if not left or not right:
            continue
        sims = {(x, y): float(left[x] @ right[y]) for x in left for y in right if x != y and (min(x, y), max(x, y)) not in apart}
        for (x, y), value in sims.items():
            if value < float(cfg["chain_link"]):
                continue
            best_x = max((v for (p, q), v in sims.items() if p == x), default=-1)
            best_y = max((v for (p, q), v in sims.items() if q == y), default=-1)
            if value >= best_x and value >= best_y:
                links.append((value, x, y))
    union = _Union()
    scores: dict[tuple[str, str], float] = {}
    for value, x, y in sorted(links, reverse=True):
        rx, ry = union.find(x), union.find(y)
        if rx == ry:
            continue
        members_x = [m for m in people if union.find(m) == rx]
        members_y = [m for m in people if union.find(m) == ry]
        if len(members_x) + len(members_y) > voices.GROUP_MAX:
            continue
        if any((min(p, q), max(p, q)) in apart for p in members_x for q in members_y):
            continue
        union.join(x, y)
        scores[(x, y)] = value
    components: dict[str, list[str]] = {}
    for ident in people:
        components.setdefault(union.find(ident), []).append(ident)
    groups = []
    for members in components.values():
        if len(members) < 2:
            continue
        values = [v for (x, y), v in scores.items() if x in members and y in members]
        members = sorted(members, key=lambda m: -people[m]["lines"])
        groups.append({"id": "sc-" + day.replace("-", "") + "-" + hashlib.sha256("|".join(sorted(members)).encode()).hexdigest()[:10],
                       "score": round(float(np.mean(values)), 3) if values else None, "why": "chain",
                       "people": [_member(m, people[m]) for m in members]})
    groups.sort(key=lambda g: -(g["score"] or 0))
    return {"groups": groups[:int(cfg["chain_max"])], "people": len(people),
            "after": len(people) - sum(len(g["people"]) - 1 for g in groups)}


def headcounts(base: Path | None, day: str) -> list[tuple[int, int, int]]:
    """確6: その日の人数の分かる時間 [(始まりのミリ秒, 終わりのミリ秒, 人数)]（予定の「N人」・本人の答え）"""
    out = []
    if base is None:
        return out
    y, m, d = day.split("-")
    try:
        text = (Path(base) / "archive" / "calendar" / y / m / f"{d}.md").read_text(encoding="utf-8")
    except OSError:
        text = ""
    for raw in text.splitlines():
        match = re.match(r"\s*-\s*(\d{1,2}):(\d{2})(?:\s*[-〜~]\s*(\d{1,2}):(\d{2}))?\s+(.*)", raw)
        if not match:
            continue
        count = HEADCOUNT.search(match.group(5))
        if not count or not 2 <= int(count.group(1)) <= 30:
            continue
        begin = datetime.datetime.strptime(f"{day} {match.group(1)}:{match.group(2)}", "%Y-%m-%d %H:%M")
        end = (datetime.datetime.strptime(f"{day} {match.group(3)}:{match.group(4)}", "%Y-%m-%d %H:%M")
               if match.group(3) else begin + datetime.timedelta(hours=2))
        out.append((int(begin.timestamp() * 1000), int(end.timestamp() * 1000), int(count.group(1))))
    try:
        rows = (Path(base) / "inbox" / "headcount.jsonl").read_text(encoding="utf-8").splitlines()
    except OSError:
        rows = []
    for raw in rows:
        try:
            row = json.loads(raw)
            if row.get("day") != day or not isinstance(row.get("count"), int):
                continue
            begin = datetime.datetime.fromisoformat(str(row["start"]).replace("Z", "+00:00"))
            ms = int(begin.timestamp() * 1000)
            out.append((ms - 600_000, ms + 3 * 3600_000, int(row["count"])))
        except (ValueError, TypeError, KeyError):
            continue
    return out


def count_day(home: Path, parsed: dict, day: str, base: Path | None, cfg: dict) -> list[dict]:
    """確6: 人数が分かる会話で、話し手が多すぎる分を近い人物N からつなぐ候補（"sn-…"）"""
    known = headcounts(base, day)
    if not known:
        return []
    people, _chunks, apart = unnamed_by_chunk(home, parsed, day)
    centers = _centers(home, day, people)
    out = []
    for conversation in parsed.get("conversations") or []:
        start, end = conversation.get("start"), conversation.get("end")
        fit = [n for a, b, n in known if isinstance(start, int) and a <= start <= b or isinstance(end, int) and a <= end <= b]
        if not fit:
            continue
        allowed = max(fit) - 1
        speakers = {str(line.get("speaker") or "") for line in conversation.get("lines") or []
                    if line.get("speakerID") != SELF_ID and line.get("speaker") not in (None, "", SELF_NAME)
                    and line.get("media") is None}
        unnamed = [UNNAMED.fullmatch(s).group(1) for s in speakers if UNNAMED.fullmatch(s)]
        extra = len(speakers) - allowed
        if extra <= 0 or len(unnamed) < 2:
            continue
        union = _Union()
        pairs = sorted(((float(centers[a] @ centers[b]), a, b) for i, a in enumerate(unnamed) for b in unnamed[i + 1:]
                        if a in centers and b in centers and (min(a, b), max(a, b)) not in apart), reverse=True)
        joined = []
        for value, a, b in pairs:
            if extra <= 0:
                break
            ra, rb = union.find(a), union.find(b)
            if ra == rb:
                continue
            left = [m for m in unnamed if union.find(m) == ra]
            right = [m for m in unnamed if union.find(m) == rb]
            if any((min(p, q), max(p, q)) in apart for p in left for q in right):
                continue   # 同じ区切りに一緒に出た 2 人は、同じ人にしない
            union.join(a, b)
            joined.append((value, a, b))
            extra -= 1
        comps: dict[str, list[str]] = {}
        for ident in unnamed:
            comps.setdefault(union.find(ident), []).append(ident)
        for members in comps.values():
            if len(members) < 2:
                continue
            values = [v for v, a, b in joined if a in members and b in members]
            members = sorted(members, key=lambda m: -people[m]["lines"])
            out.append({"id": "sn-" + day.replace("-", "") + "-" + hashlib.sha256("|".join(sorted(members)).encode()).hexdigest()[:10],
                        "score": round(float(np.mean(values)), 3) if values else None, "why": "count",
                        "headcount": max(fit), "people": [_member(m, people[m]) for m in members]})
            if len(out) >= int(cfg["count_max"]):
                return out
    return out


def write_chain(home: Path, parsed: dict, day: str, base: Path | None, config: dict | None) -> dict:
    cfg = settings(config)
    got = chain_day(home, parsed, day, cfg)
    counted = count_day(home, parsed, day, base, cfg)
    body = {"day": day, "generated_at": datetime.datetime.now().isoformat(timespec="seconds"),
            "people": got["people"], "after": got["after"], "groups": got["groups"] + counted,
            "chain": len(got["groups"]), "count": len(counted)}
    _write(folder(home, "chain") / f"{day}.json", body)
    return body


def extra_groups(home: Path, day: str) -> list[dict]:
    body = _read(folder(home, "chain") / f"{day}.json", {}) or {}
    return [g for g in body.get("groups") or [] if isinstance(g, dict) and isinstance(g.get("people"), list)]


# MARK: - 確5 いそうな人


def known_names(parsed_days: list[dict]) -> set[str]:
    names = set()
    for parsed in parsed_days:
        for conversation in parsed.get("conversations") or []:
            for line in conversation.get("lines") or []:
                name = str(line.get("speaker") or "")
                if name and name != SELF_NAME and not UNNAMED.fullmatch(name) and line.get("speakerID") != SELF_ID:
                    names.add(name)
    return names


def _mentions(text: str, names: set[str]) -> set[str]:
    return {n for n in names if len(n) >= 2 and n in text}


def likely_people(base: Path | None, parsed: dict, day: str, names: set[str], history: list[dict] | None = None,
                  hours: float = 3.0) -> dict[str, set[str]]:
    """確5: {"calendar", "place", "line"} → その日にいそうな名前（names にあるものだけ）"""
    out = {"calendar": set(), "place": set(), "line": set()}
    if base is not None:
        y, m, d = day.split("-")
        try:
            out["calendar"] = _mentions((Path(base) / "archive" / "calendar" / y / m / f"{d}.md").read_text(encoding="utf-8"),
                                        names)
        except OSError:
            pass
        try:
            line_text = (Path(base) / "archive" / "line" / y / m / f"{d}.md").read_text(encoding="utf-8")
        except OSError:
            line_text = ""
        starts = [c.get("start") for c in parsed.get("conversations") or [] if isinstance(c.get("start"), int)]
        if line_text and starts:
            minutes = []
            for raw in line_text.splitlines():
                match = re.match(r"\s*-\s*\*\*(\d{1,2}):(\d{2})\*\*\s*([^:：]{1,40})[:：]", raw)
                if match:
                    minutes.append((int(match.group(1)) * 60 + int(match.group(2)), match.group(3)))
            for start in starts:
                moment = datetime.datetime.fromtimestamp(start / 1000)
                now = moment.hour * 60 + moment.minute
                for minute, sender in minutes:
                    if 0 <= now - minute <= hours * 60:
                        out["line"] |= _mentions(sender, names)
    places = {str(c.get("place")) for c in parsed.get("conversations") or [] if c.get("place")}
    for old in history or []:
        for conversation in old.get("conversations") or []:
            if conversation.get("place") and str(conversation["place"]) in places:
                out["place"] |= {str(line.get("speaker")) for line in conversation.get("lines") or []
                                 if str(line.get("speaker") or "") in names}
    return out


# MARK: - 確7・確8・確9・確10 札


def line_key(line: dict) -> str | None:
    audio, start, end = line.get("audio"), line.get("offset"), line.get("end")
    if not isinstance(audio, str) or not isinstance(start, (int, float)) or not isinstance(end, (int, float)):
        return None
    return voices.seg_key(audio, start, end)


def tags_day(parsed: dict, day: str, cfg: dict, levels: dict | None = None,
             media: Callable[[int], bool] | None = None) -> dict:
    """その日の札（文は入れない）"""
    tags = []
    people: dict[str, dict] = {}
    for conversation in parsed.get("conversations") or []:
        lines = sorted(conversation.get("lines") or [], key=lambda x: x.get("time") or 0)
        for line in lines:
            match = UNNAMED.fullmatch(str(line.get("speaker") or ""))
            if match and line.get("media") is None:
                entry = people.setdefault(match.group(1), {"lines": [], "audios": set(), "seconds": 0.0})
                entry["lines"].append(line.get("time"))
                entry["audios"].add(line.get("audio"))
                if isinstance(line.get("offset"), (int, float)) and isinstance(line.get("end"), (int, float)):
                    entry["seconds"] += max(0.0, float(line["end"]) - float(line["offset"]))
        for a, b in zip(lines, lines[1:]):
            if a.get("speaker") == b.get("speaker") or not isinstance(a.get("time"), int) or not isinstance(b.get("time"), int):
                continue
            if not isinstance(a.get("offset"), (int, float)) or not isinstance(a.get("end"), (int, float)):
                continue
            a_end = a["time"] + int((float(a["end"]) - float(a["offset"])) * 1000)
            if a_end - b["time"] >= float(cfg["overlap_seconds"]) * 1000:
                for line in (a, b):
                    tags.append({"time": _iso(line["time"]), "ms": line["time"], "kind": "overlap", "label": "重なり"})
        chunk_levels = (levels or {}).get("chunks") or {}
        line_levels = (levels or {}).get("lines") or {}
        for line in lines:
            if not isinstance(line.get("time"), int):
                continue
            if line.get("speakerID") != SELF_ID and line.get("speaker") != SELF_NAME:
                key = line_key(line)
                db = line_levels.get(key) if key else None
                chunk = chunk_levels.get(line.get("audio")) or {}
                middle = chunk.get("voicedP50")
                if isinstance(db, (int, float)) and isinstance(middle, (int, float)) and middle - db >= float(cfg["far_db"]):
                    tags.append({"time": _iso(line["time"]), "ms": line["time"], "kind": "far", "label": "遠い声（仮）",
                                 "db": round(float(db), 1), "chunk_db": round(float(middle), 1)})
            if media is not None and media(line["time"]):
                tags.append({"time": _iso(line["time"]), "ms": line["time"], "kind": "media", "label": "動画の声かも"})
    for ident, entry in people.items():
        if len(entry["audios"]) == 1 and len(entry["lines"]) <= int(cfg["passerby_lines"]) \
                and entry["seconds"] <= float(cfg["passerby_seconds"]):
            for moment in entry["lines"]:
                if isinstance(moment, int):
                    tags.append({"time": _iso(moment), "ms": moment, "kind": "passerby", "label": "通りすがり",
                                 "speaker": f"人物{ident}"})
    counts: dict[str, int] = {}
    for tag in tags:
        counts[tag["kind"]] = counts.get(tag["kind"], 0) + 1
    passerby = {t["speaker"] for t in tags if t["kind"] == "passerby"}
    return {"day": day, "generated_at": datetime.datetime.now().isoformat(timespec="seconds"),
            "tags": sorted(tags, key=lambda t: (t["ms"], t["kind"])), "counts": counts,
            "people": len(people), "passerby_people": len(passerby)}


def write_tags(home: Path, base: Path | None, parsed: dict, day: str, config: dict | None,
               media: Callable[[int], bool] | None = None) -> dict:
    body = tags_day(parsed, day, settings(config), _read(folder(home, "levels") / f"{day}.json", {}), media)
    _write(folder(home, "speaker-tags") / f"{day}.json", body)
    if base is not None and Path(base).is_dir():
        try:
            _write(Path(base) / "inbox" / "speaker-tags" / f"{day}.json", body)
        except OSError:
            pass
    return body


def read_tags(home: Path, day: str | None) -> dict:
    if not day or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", day):
        day = datetime.date.today().isoformat()
    body = _read(folder(home, "speaker-tags") / f"{day}.json")
    if not isinstance(body, dict):
        return {"available": False, "reason": "その日の札はまだありません", "day": day}
    return {"available": True, **body}


# MARK: - 音の大きさ（確9・確4。重い所）


def _db(samples: np.ndarray) -> float | None:
    if len(samples) == 0:
        return None
    rms = float(np.sqrt(np.mean(np.square(samples, dtype=np.float64))))
    return round(20 * np.log10(max(rms, 1e-7)), 1)


def chunk_levels(audio: np.ndarray, rate: int, voiced: list[tuple[float, float]]) -> dict:
    """1 秒ごとの dB の p10・p50・p90 と、声の区間の dB の真ん中（アプリの "levels" と同じ名前）"""
    frames = [_db(audio[i:i + rate]) for i in range(0, max(0, len(audio) - rate // 2), rate)]
    frames = [f for f in frames if f is not None]
    voiced_db = [d for d in (_db(audio[int(a * rate):int(b * rate)]) for a, b in voiced) if d is not None]
    if not frames:
        return {}
    out = {f"p{q}": round(float(np.percentile(frames, q)), 1) for q in (10, 50, 90)}
    if voiced_db:
        out["voicedP50"] = round(float(np.median(voiced_db)), 1)
    return out


def measure_levels(home: Path, parsed: dict, day: str, find_audio: Callable[[str], Path | None],
                   load_audio: Callable[[bytes], np.ndarray], rate: int, deadline: float) -> dict:
    """その日の行の音の大きさ（PC で測る。重い仕事の時間だけ・deadline まで）。数を返す"""
    path = folder(home, "levels") / f"{day}.json"
    body = _read(path, {}) or {}
    lines_db = body.setdefault("lines", {})
    chunks_db = body.setdefault("chunks", {})
    by_audio: dict[str, list[dict]] = {}
    for conversation in parsed.get("conversations") or []:
        for line in conversation.get("lines") or []:
            key = line_key(line)
            if key and key not in lines_db:
                by_audio.setdefault(line["audio"], []).append(line)
    done = missing = 0
    stopped = False
    for audio_name, lines in by_audio.items():
        if time.time() > deadline:
            stopped = True
            break
        found = find_audio(audio_name)
        if found is None:
            missing += len(lines)
            continue
        try:
            audio = load_audio(Path(found).read_bytes())
        except Exception:  # noqa: BLE001 — 読めない音声は飛ばす
            continue
        spans = [(float(x["offset"]), float(x["end"])) for x in lines]
        for line, (a, b) in zip(lines, spans):
            db = _db(audio[int(a * rate):int(b * rate)])
            if db is not None:
                lines_db[line_key(line)] = db
                done += 1
        if audio_name not in chunks_db:
            chunks_db[audio_name] = chunk_levels(audio, rate, spans)
    if done:
        body["day"] = day
        _write(path, body)
    return {"lines": done, "missing": missing, "stopped": stopped}


def self_separation(parsed: dict, levels: dict, app_levels: dict | None = None) -> dict | None:
    """確4（仮説）: 行の大きさ − 区切りの声の真ん中（時計の "levels" があればそれ）で、自分の行とほかの行が分かれるか（AUC）"""
    line_db = (levels or {}).get("lines") or {}
    chunk_db = dict((levels or {}).get("chunks") or {})
    for name, value in (app_levels or {}).items():
        if isinstance(value, dict) and isinstance(value.get("voicedP50"), (int, float)):
            chunk_db[name] = value
    mine, others = [], []
    for conversation in parsed.get("conversations") or []:
        for line in conversation.get("lines") or []:
            key = line_key(line)
            middle = (chunk_db.get(line.get("audio")) or {}).get("voicedP50")
            db = line_db.get(key) if key else None
            if not isinstance(db, (int, float)) or not isinstance(middle, (int, float)) or line.get("media") is not None:
                continue
            rel = float(db) - float(middle)
            if line.get("speakerID") == SELF_ID or line.get("speaker") == SELF_NAME:
                mine.append(rel)
            elif line.get("speaker"):
                others.append(rel)
    if len(mine) < 10 or len(others) < 10:
        return None
    a = np.asarray(mine)
    b = np.asarray(others)
    wins = (a[:, None] > b[None, :]).sum() + 0.5 * (a[:, None] == b[None, :]).sum()
    return {"auc": round(float(wins / (len(a) * len(b))), 3), "self": len(mine), "others": len(others),
            "self_median": round(float(np.median(a)), 1), "others_median": round(float(np.median(b)), 1)}
