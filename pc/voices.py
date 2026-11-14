"""LifeLog PC: 声の特徴の置き場と、日をまたぐ「同じ人かも」・名前のある人との照らし（強化案 56。2026-11-15）。

番号は母艦の docs/system-proposal-2026-11-13.md の「追記 3」。測り方と数は docs/s7-voices-2026-11-15.md。

- 置き場所: HOME/voices/<日>.npz（その日の記録の行＝話し手の 1 回ぶんの区間ごとの声の特徴。/speakers と同じ CAM++）。
  中身は keys（"音声の名前|始まり|終わり"）・vecs（float16）・bad（測れなかった区間）・model だけ。文・名前は入れない。
  KEEP_DAYS より古い日は消す。この PC の中だけに置く（リポジトリ・母艦・クラウドには置かない）。
- 足し方: 行の長さが CLIP_MIN〜CLIP_MAX 秒で、テレビなどの声でない行だけ。まだ無い区間だけを足す（同じ区間は二度測らない）。
  重い仕事なので heavy_ok() の時間（00:00〜05:00・08:30〜18:00）だけ、1 回の見回りの時間に上限をつけて（quality.py から）。
- 束ね方: 日ごとに、その日の全部の区間の平均（マイク・部屋の癖）を引いてから長さ 1 にそろえる（docs/s2-accuracy-2026-11-13.md）。
  話し手（人物N・名前のある人・自分）ごとに、長い区間から CENTER_CLIPS 個まで（なるべく違う区切りから）の平均を真ん中にする。
  - 日をまたぐ組（across）: 直近 WINDOW 日の名前の無い人物N を、平均の近さが ACROSS_LINK 以上なら組に
    （同じ区切りに出た 2 つは組にしない・GROUP_MAX 人まで）。同じ日にしか出ない組は sameperson.py の 1 日の組に任せ、
    ここでは「別々の日にしか出ていない 2 人」を含む組だけを出す。
  - 名前のある人かも（maybe）: 名前のある人の真ん中と比べ、いちばん近いのが名前のある人（自分ではない）で、
    NAMED_MIN 以上・2 番目（自分を含む）との差が NAMED_MARGIN 以上のときだけ。同じ区切りに出た名前のある人は候補にしない。
- 自動ではまとめない・名前を付けない・変えない。アプリの「直す」の「同じ人かも」に出し、本人が押したときだけ
  アプリが元に戻せるまとめ（mergePerson・assign）を使う。
- 置き場所: HOME/same-person/voices.json（作り直すたびに置き換え）。GET /same-person の "across"・"maybe"（sameperson.read）。
  記録（log.txt）には数だけを書く（文・名前は書かない）。
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

FOLDER = "voices"
OUT_FOLDER = "same-person"
OUT_FILE = "voices.json"
MODEL = os.environ.get("LIFELOG_SPEAKER_MODEL", "3dspeaker_speech_campplus_sv_en_voxceleb_16k.onnx")
UNNAMED = re.compile(r"人物(\d+)")
SELF_ID = "me"
SELF_LABEL = "me"

CLIP_MIN = 1.5          # 区間の長さ（秒）。短い区間は声の特徴がぶれる（sameperson.py と同じ）
CLIP_MAX = 20.0
KEEP_DAYS = 21          # 置き場所に残す日数
WINDOW = 7              # 束ねる日数（今日を入れて）
MEAN_MIN = 20           # その日の平均を引くのに要る区間の数（少ない日は束ねに使わない）
CENTER_CLIPS = 12       # 真ん中に使う区間の数
MIN_CLIPS = 2           # 真ん中を作るのに要る区間の数（1 つだけの人物N はぶれるので比べない）
REF_MIN_CLIPS = 4       # 名前のある人の真ん中に要る区間の数
GROUP_MAX = 4
# 下の 3 つは 2026-11-10〜14 の記録で測って決めた（docs/s7-voices-2026-11-15.md。名前のある人と自分を区切りごとに
# 分けた「仮の人物N」で、組の 2 人が同じ人だった割合と、名前のある人の当て方の合っていた割合から）。
# 名前のある人かもは 0.60 で 0.67〜0.72、0.65 で 0.90〜0.91（外れの多くは自分の声に名前を当てたもの）。差の条件は効かなかった。
# 組の方は 0.50〜0.80 のどこでも 0.98〜1.00 で差が出なかったので、名前のある人の当て方が良くなる所（0.65）にそろえた
ACROSS_LINK = 0.65
NAMED_MIN = 0.65
NAMED_MARGIN = 0.10
ACROSS_MAX = 20
MAYBE_MAX = 20
# 1 人の名前のある人に出す「◯◯さんかも」の数。2026-11-10〜14 で、よく出る名前のある人 1 人に候補 14 件が集まった
# （声の特徴の「どの声にも近い人」になっている＝【仮説】）。近い順に 3 件だけにし、本人の「別の人」の数で見直す
MAYBE_PER_NAMED = 3
SAMPLES = 3
TEXT_MAX = 40
SERVE_STALE_DAYS = 3    # これより古い voices.json は出さない
SAVE_EVERY = 200        # これだけ足したら途中でも置く（時間切れで止まっても無駄にしない）

_lock = threading.Lock()


def folder(home: Path) -> Path:
    return Path(home) / FOLDER


def heavy_ok(moment: datetime.datetime) -> bool:
    """重い仕事をしてよい時間（00:00〜05:00・08:30〜18:00。本人が PC を使う時間は避ける）"""
    minutes = moment.hour * 60 + moment.minute
    return minutes < 5 * 60 or 8 * 60 + 30 <= minutes < 18 * 60


def _num(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and value == value


def seg_key(audio: str, start: float, end: float) -> str:
    return f"{audio}|{float(start):.2f}|{float(end):.2f}"


def label_of(line: dict) -> str | None:
    """行の話し手の印: "me"（自分）・"u:12"（名前の無い人物12）・"n:5"（名前のある人の番号）・None（分からない）"""
    name = line.get("speaker") or ""
    ident = line.get("speakerID")
    if ident == SELF_ID:
        return SELF_LABEL
    match = UNNAMED.fullmatch(name)
    if match:
        if ident not in (None, match.group(1)):
            return None  # 名前と番号が合わない行は使わない（sameperson.py と同じ）
        return "u:" + match.group(1)
    if name and isinstance(ident, str) and ident and not UNNAMED.fullmatch(ident):
        return "n:" + ident
    return None


def segments(parsed: dict) -> list[dict]:
    """声の特徴を取る区間（その日の記録の行のうち、長さが範囲に入り、テレビなどの声でないもの）"""
    out = []
    for conversation in parsed.get("conversations") or []:
        if conversation.get("media"):
            continue
        for line in conversation.get("lines") or []:
            if line.get("media") is not None:
                continue
            audio, start, end = line.get("audio"), line.get("offset"), line.get("end")
            if not isinstance(audio, str) or not audio or not _num(start) or not _num(end):
                continue
            if not CLIP_MIN <= float(end) - float(start) <= CLIP_MAX:
                continue
            out.append({"key": seg_key(audio, start, end), "audio": audio, "start": float(start), "end": float(end),
                        "label": label_of(line), "line": line})
    return out


# MARK: - 置き場所（HOME/voices/<日>.npz）


class DayStore:
    """1 日ぶんの区間の声の特徴。読む前に書かない（load してから save）"""

    def __init__(self, home: Path, day: str) -> None:
        self.path = folder(home) / f"{day}.npz"
        self.vectors: dict[str, np.ndarray] = {}
        self.bad: set[str] = set()

    def load(self) -> "DayStore":
        try:
            with np.load(self.path, allow_pickle=False) as data:
                if str(data["model"]) != MODEL:
                    return self  # 前のモデルの特徴は比べられないので、測り直す
                keys = [str(k) for k in data["keys"]]
                vecs = np.asarray(data["vecs"], dtype=np.float32)
                if len(keys) == len(vecs):
                    self.vectors = {k: vecs[i] for i, k in enumerate(keys)}
                self.bad = {str(k) for k in data["bad"]}
        except (OSError, KeyError, ValueError):
            pass
        return self

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        keys = sorted(self.vectors)
        size = len(self.vectors[keys[0]]) if keys else 0
        vecs = np.stack([self.vectors[k] for k in keys]).astype(np.float16) if keys else np.zeros((0, size), np.float16)
        part = self.path.with_name(self.path.stem + ".part.npz")
        with _lock:
            np.savez(part, keys=np.array(keys, dtype=str), vecs=vecs, bad=np.array(sorted(self.bad), dtype=str),
                     model=np.array(MODEL))
            os.replace(part, self.path)


def prune(home: Path, today: datetime.date | None = None) -> int:
    limit = ((today or datetime.date.today()) - datetime.timedelta(days=KEEP_DAYS)).isoformat()
    gone = 0
    for path in folder(home).glob("????-??-??.npz"):
        if path.stem < limit:
            try:
                path.unlink()
                gone += 1
            except OSError:
                pass
    return gone


def update_day(home: Path, store, day: str, find_audio: Callable[[str], Path | None],
               embed: Callable[[Path, list[tuple[float, float]]], list], deadline: float | None = None) -> dict | None:
    """その日のまだ測っていない区間を測って置く。記録が無ければ None。数だけを返す"""
    parsed = store.day(day) if store is not None else None
    if parsed is None:
        return None
    ds = DayStore(home, day).load()
    todo: dict[str, list[dict]] = {}
    for s in segments(parsed):
        if s["key"] in ds.vectors or s["key"] in ds.bad:
            continue
        todo.setdefault(s["audio"], []).append(s)
    added = bad = missing = unsaved = 0
    stopped = False
    for audio, segs in todo.items():
        if deadline is not None and time.time() > deadline:
            stopped = True
            break
        path = find_audio(audio)
        if path is None:
            missing += len(segs)  # 音声が残っていない（後で届くことがあるので、測れなかった印は付けない）
            continue
        try:
            got = embed(path, [(s["start"], s["end"]) for s in segs])
        except Exception:  # noqa: BLE001 — 読めない音声は飛ばす
            got = [None] * len(segs)
        for s, vector in zip(segs, list(got) + [None] * (len(segs) - len(got))):
            if vector is None or len(vector) == 0:
                ds.bad.add(s["key"])
                bad += 1
            else:
                ds.vectors[s["key"]] = np.asarray(vector, dtype=np.float32)
                added += 1
                unsaved += 1
        if unsaved >= SAVE_EVERY:
            ds.save()
            unsaved = 0
    if added or bad:
        ds.save()
    return {"added": added, "bad": bad, "missing": missing, "total": len(ds.vectors), "stopped": stopped}


def cached_embed(home: Path, day: str, name: str | None, path: Path, ranges: list[tuple[float, float]],
                 embed: Callable) -> list:
    """置き場所にある区間はそのまま返し、無い区間だけを測る（sameperson.py の 1 日の組を作り直すときに使う）"""
    ds = DayStore(home, day).load() if name else None
    out: list = [None] * len(ranges)
    need: list[int] = []
    for i, (start, end) in enumerate(ranges):
        hit = ds.vectors.get(seg_key(name, start, end)) if ds is not None else None
        if hit is not None:
            out[i] = [float(x) for x in hit]
        else:
            need.append(i)
    if need:
        got = embed(path, [ranges[i] for i in need])
        for i, vector in zip(need, got):
            out[i] = vector
            if ds is not None and vector is not None and len(vector) > 0:
                ds.vectors[seg_key(name, *ranges[i])] = np.asarray(vector, dtype=np.float32)
        if ds is not None:
            ds.save()
    return out


# MARK: - 束ねる


def _unit(vector: np.ndarray) -> np.ndarray | None:
    norm = float(np.linalg.norm(vector))
    return vector / norm if norm > 0 and np.isfinite(norm) else None


def _iso(ms: int | float) -> str:
    moment = datetime.datetime(1970, 1, 1, tzinfo=datetime.timezone.utc) + datetime.timedelta(milliseconds=int(ms))
    return moment.strftime("%Y-%m-%dT%H:%M:%S") + f".{int(ms) % 1000:03d}Z"


def _text(value, n: int = TEXT_MAX) -> str:
    return " ".join(str(value or "").split())[:n]


def gather(home: Path, store, days: list[str]) -> dict:
    """直近の日の区間を、話し手ごとに（日の平均を引いた特徴つきで）集める。
    {"labels": {印: {"items": [...], "days": set, "lines": int, "seconds": float, "audios": set, "name": str}},
     "segments": int, "days": [使えた日]}"""
    labels: dict[str, dict] = {}
    used_days, total = [], 0
    for day in days:
        parsed = store.day(day) if store is not None else None
        if parsed is None:
            continue
        ds = DayStore(home, day).load()
        segs = [s for s in segments(parsed) if s["key"] in ds.vectors]
        # 話した行の数・秒・同じ区切りに出たか（声の特徴の有無にかかわらず、その日の全部の行から）
        for conversation in parsed.get("conversations") or []:
            if conversation.get("media"):
                continue
            for line in conversation.get("lines") or []:
                if line.get("media") is not None:
                    continue
                label = label_of(line)
                if label is None:
                    continue
                entry = labels.setdefault(label, {"items": [], "days": set(), "lines": 0, "seconds": 0.0,
                                                  "audios": set(), "name": line.get("speaker") or ""})
                entry["lines"] += 1
                entry["days"].add(day)
                if isinstance(line.get("audio"), str) and line["audio"]:
                    entry["audios"].add(line["audio"])
                start, end = line.get("offset"), line.get("end")
                if _num(start) and _num(end) and end > start:
                    entry["seconds"] += float(end) - float(start)
                if label.startswith("n:") and line.get("speaker"):
                    entry["name"] = line["speaker"]  # 新しい日の名前（名前を付け替えたとき）
        if len(segs) < MEAN_MIN:
            continue
        used_days.append(day)
        mean = np.mean(np.stack([ds.vectors[s["key"]] for s in segs]), axis=0)
        for s in segs:
            if s["label"] is None:
                continue
            vector = _unit(ds.vectors[s["key"]].astype(np.float64) - mean)
            if vector is None:
                continue
            labels[s["label"]]["items"].append({"day": day, "audio": s["audio"], "start": s["start"], "end": s["end"],
                                                "length": s["end"] - s["start"], "vec": vector,
                                                "time": s["line"].get("time"), "text": s["line"].get("text")})
            total += 1
    return {"labels": labels, "segments": total, "days": used_days}


def pick(items: list[dict], count: int) -> list[dict]:
    """長い区間から count 個まで（なるべく違う区切りから）"""
    ordered = sorted(items, key=lambda x: -x["length"])
    picked, seen = [], set()
    for item in ordered:
        if item["audio"] in seen:
            continue
        picked.append(item)
        seen.add(item["audio"])
        if len(picked) >= count:
            return picked
    for item in ordered:
        if len(picked) >= count:
            break
        if not any(item is p for p in picked):
            picked.append(item)
    return picked


def center(items: list[dict], count: int = CENTER_CLIPS) -> np.ndarray | None:
    chosen = pick(items, count)
    if not chosen:
        return None
    return _unit(np.mean(np.stack([c["vec"] for c in chosen]), axis=0))


def apart_pairs(labels: dict[str, dict]) -> set[tuple[str, str]]:
    """同じ区切り（同じ音声）に出た 2 つ（iPhone が別の声と分けた）"""
    by_audio: dict[str, list[str]] = {}
    for label, entry in labels.items():
        for audio in entry["audios"]:
            by_audio.setdefault(audio, []).append(label)
    pairs = set()
    for ids in by_audio.values():
        ids = sorted(set(ids))
        for i, a in enumerate(ids):
            for b in ids[i + 1:]:
                pairs.add((a, b))
    return pairs


def cluster(ids: list[str], centers: np.ndarray, apart: set[tuple[str, str]], link: float,
            size: int = GROUP_MAX) -> list[tuple[list[str], float]]:
    """平均の近さで近い組からまとめる（同じ区切りに出た 2 つは同じ組にしない・size 人まで）。
    返すのは 2 人以上の組と、組の中の近さの平均（高い順）。numpy の表で数える（人物N が数百でも数秒）"""
    n = len(ids)
    if n < 2:
        return []
    sims = centers @ centers.T
    sums = sims.copy()
    counts = np.ones(n)
    alive = np.ones(n, dtype=bool)
    blocked = np.eye(n, dtype=bool)
    index = {x: i for i, x in enumerate(ids)}
    for a, b in apart:
        if a in index and b in index:
            blocked[index[a], index[b]] = blocked[index[b], index[a]] = True
    members = [[i] for i in range(n)]
    upper = np.triu(np.ones((n, n), dtype=bool), k=1)
    while True:
        avg = sums / np.outer(counts, counts)
        bad = blocked | ~upper | ~alive[:, None] | ~alive[None, :] | (counts[:, None] + counts[None, :] > size)
        avg[bad] = -np.inf
        k = int(np.argmax(avg))
        i, j = divmod(k, n)
        if not np.isfinite(avg[i, j]) or avg[i, j] < link:
            break
        sums[i, :] += sums[j, :]
        sums[:, i] += sums[:, j]
        blocked[i, :] |= blocked[j, :]
        blocked[:, i] |= blocked[:, j]
        counts[i] += counts[j]
        alive[j] = False
        members[i] += members[j]
        members[j] = []
    out = []
    for group in members:
        if len(group) < 2:
            continue
        values = [float(sims[a, b]) for x, a in enumerate(group) for b in group[x + 1:]]
        out.append(([ids[g] for g in group], round(sum(values) / len(values), 3)))
    out.sort(key=lambda x: -x[1])
    return out


def suggest_named(centers: dict[str, np.ndarray], refs: dict[str, np.ndarray], apart: set[tuple[str, str]],
                  low: float = NAMED_MIN, margin: float = NAMED_MARGIN) -> dict[str, tuple[str, float, float]]:
    """名前の無い人物N ごとに、いちばん近い名前のある人（自分ではない）。{印: (名前のある人の印, 近さ, 2 番目との差)}"""
    out = {}
    for label, vector in centers.items():
        scored = []
        for ref, rv in refs.items():
            if (min(label, ref), max(label, ref)) in apart:
                continue
            scored.append((float(np.dot(vector, rv)), ref))
        if not scored:
            continue
        scored.sort(reverse=True)
        best, ref = scored[0]
        second = scored[1][0] if len(scored) > 1 else -1.0
        if ref == SELF_LABEL or best < low or best - second < margin:
            continue
        out[label] = (ref, round(best, 3), round(best - second, 3))
    return out


def _member(label: str, entry: dict) -> dict:
    ident = label[2:]
    samples = []
    for item in pick(entry["items"], SAMPLES):
        if not _num(item.get("time")):
            continue
        samples.append({"time": _iso(item["time"]), "text": _text(item.get("text")), "audio": item["audio"],
                        "start": round(item["start"], 2), "end": round(item["end"], 2)})
    return {"id": ident, "name": f"人物{ident}", "lines": entry["lines"], "seconds": round(entry["seconds"], 1),
            "days": sorted(entry["days"]), "samples": samples}


def _hash(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:12]


def build(home: Path, store, today: datetime.date | None = None, window: int = WINDOW) -> dict:
    """直近 window 日の「日をまたぐ組」と「名前のある人かも」（置かない）"""
    today = today or datetime.date.today()
    days = [(today - datetime.timedelta(days=k)).isoformat() for k in range(window - 1, -1, -1)]
    got = gather(home, store, days)
    labels = got["labels"]
    apart = apart_pairs(labels)
    unnamed = {k: center(e["items"]) for k, e in labels.items() if k.startswith("u:") and len(e["items"]) >= MIN_CLIPS}
    unnamed = {k: v for k, v in unnamed.items() if v is not None}
    refs = {k: center(e["items"], CENTER_CLIPS * 3) for k, e in labels.items()
            if (k.startswith("n:") or k == SELF_LABEL) and len(e["items"]) >= REF_MIN_CLIPS
            and len({i["audio"] for i in e["items"]}) >= 2}
    refs = {k: v for k, v in refs.items() if v is not None}
    ids = sorted(unnamed)
    across = []
    if ids:
        matrix = np.stack([unnamed[i] for i in ids])
        for group, score in cluster(ids, matrix, apart, ACROSS_LINK):
            spread = False
            for x, a in enumerate(group):
                for b in group[x + 1:]:
                    if not labels[a]["days"] & labels[b]["days"]:
                        spread = True
            if not spread:
                continue  # 同じ日にしか出ない組は、sameperson.py の 1 日の組に任せる
            members = sorted(group, key=lambda g: -labels[g]["lines"])
            all_days = sorted(set().union(*[labels[g]["days"] for g in group]))
            across.append({"id": "sx-" + _hash("|".join(sorted(group))), "day": all_days[-1], "days": all_days,
                           "score": score, "people": [_member(g, labels[g]) for g in members]})
            if len(across) >= ACROSS_MAX:
                break
    maybe = []
    per_named: dict[str, int] = {}
    named = suggest_named(unnamed, refs, apart, NAMED_MIN, NAMED_MARGIN)
    for label, (ref, score, gap) in sorted(named.items(), key=lambda kv: -kv[1][1]):
        entry = labels[label]
        name = _text(labels[ref]["name"], 20)
        if not name or per_named.get(ref, 0) >= MAYBE_PER_NAMED:
            continue
        per_named[ref] = per_named.get(ref, 0) + 1
        maybe.append({"id": "pm-" + _hash(label + ">" + ref), "day": sorted(entry["days"])[-1], "score": score,
                      "margin": gap, "person": _member(label, entry), "named": {"id": ref[2:], "name": name}})
        if len(maybe) >= MAYBE_MAX:
            break
    return {"version": 1, "generated_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
            "window": got["days"], "segments": got["segments"], "unnamed": len(unnamed),
            "named": sum(1 for k in refs if k != SELF_LABEL), "across": across, "maybe": maybe}


def save(home: Path, built: dict) -> Path:
    target = Path(home) / OUT_FOLDER / OUT_FILE
    target.parent.mkdir(parents=True, exist_ok=True)
    part = target.with_name(target.name + ".part")
    with _lock:
        part.write_text(json.dumps(built, ensure_ascii=False), encoding="utf-8")
        os.replace(part, target)
    return target


def run(home: Path, store, log: Callable[[str], None], today: datetime.date | None = None) -> dict:
    """束ねて置く。数だけを記録に書く"""
    started = time.time()
    built = build(home, store, today)
    save(home, built)
    log(f"声の名寄せ: 日 {len(built['window'])}・区間 {built['segments']}・人物N {built['unnamed']}・名前のある人 {built['named']}"
        f" → 日をまたぐ組 {len(built['across'])}・名前のある人かも {len(built['maybe'])}、{time.time() - started:.0f} 秒")
    return built


def update_recent(home: Path, store, find_audio, embed, days: int, budget: float,
                  today: datetime.date | None = None) -> dict:
    """直近 days 日の、まだ測っていない区間を新しい日から測る（budget 秒まで）。足した数の合計を返す"""
    today = today or datetime.date.today()
    deadline = time.time() + budget
    total = {"added": 0, "bad": 0, "missing": 0, "stopped": False}
    for back in range(days):
        if time.time() > deadline:
            total["stopped"] = True
            break
        day = (today - datetime.timedelta(days=back)).isoformat()
        got = update_day(home, store, day, find_audio, embed, deadline)
        if got is None:
            continue
        for key in ("added", "bad", "missing"):
            total[key] += got[key]
        total["stopped"] = total["stopped"] or got["stopped"]
    prune(home, today)
    return total


# MARK: - GET /same-person に足す分


def _valid_member(p) -> bool:
    return isinstance(p, dict) and UNNAMED.fullmatch(str(p.get("name") or "")) is not None \
        and str(p.get("name"))[2:] == str(p.get("id")) and isinstance(p.get("samples"), list)


def read_extra(home: Path, now: float | None = None) -> dict:
    """voices.json の "across"・"maybe"（古い・読めない・形が違うものは出さない）"""
    path = Path(home) / OUT_FOLDER / OUT_FILE
    try:
        if (now or time.time()) - path.stat().st_mtime > SERVE_STALE_DAYS * 86400:
            return {}
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    if not isinstance(data, dict):
        return {}
    across = []
    for g in data.get("across") or []:
        if not isinstance(g, dict) or not isinstance(g.get("id"), str) or not isinstance(g.get("people"), list):
            continue
        if not 2 <= len(g["people"]) <= GROUP_MAX or not all(_valid_member(p) for p in g["people"]):
            continue
        if not _num(g.get("score")) or not isinstance(g.get("days"), list):
            continue
        across.append(g)
        if len(across) >= ACROSS_MAX:
            break
    maybe = []
    for m in data.get("maybe") or []:
        if not isinstance(m, dict) or not isinstance(m.get("id"), str) or not _valid_member(m.get("person")):
            continue
        named = m.get("named")
        if not isinstance(named, dict) or not isinstance(named.get("id"), str) or not named["id"] \
                or named["id"] == SELF_ID or UNNAMED.fullmatch(str(named.get("name") or "")) \
                or not isinstance(named.get("name"), str) or not named["name"].strip() or not _num(m.get("score")):
            continue
        maybe.append(m)
        if len(maybe) >= MAYBE_MAX:
            break
    return {"across": across, "maybe": maybe}
