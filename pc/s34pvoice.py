"""LifeLog PC: s34（2026-11-27。担当 p）自6・自7 — 声の見本を「確かな場面」から機械が自分で集める。0 円・言語モデルなし。

声の特徴は HOME/voices/<日>.npz の今までのもの（新しくは測らない・モデルを動かさない）。記録の話し手は変えない・人をまとめない・
名前を付けない・名前を変えない。見本を足すのは本人の端末（GET /voice-samples の候補。足すかどうかはアプリ）。

自6 自分の声の見本（"s34p_self_samples"。既定オン）:
  確かな場面は 2 つだけ。
  - 家でひとり（"home_alone"）: 会話の場所が家（会話の place に「自宅」・母艦の滞在が自宅・区切りの scene が home）で、
    会話の中の話し手の印が自分だけ（ほかの声・テレビなどの声が無い）・自分の行が HOME_ALONE_MIN 行以上。
  - PLAUD でいちばん近くて多い声（"plaud_major"）: 母艦 digests/canonical/<日>.json の PLAUD の録音ごとに、いちばん多い話し手
    （行の割合 PLAUD_SHARE 以上・PLAUD_LINES 行以上・仮）の行と、時刻（PLAUD_DT 秒）と話し手の番号で結べたアプリの行。
    「近い」は、行の大きさ（s22 の levels）が区切りの声の真ん中 − NEAR_DB 以上。家でひとりの声の真ん中があれば、
    それと SELF_SIMILAR 以上も要る。どちらの確かめもできない行は使わない。
  見本は場面別（home・work・out）に PER_SCENE 個まで。場面: 家の手がかりがあれば home、会話の "work" が true なら work、ほかは out。
  HOME/s34p/self-samples.json。GET /voice-samples に「自分」（speakerID "me"）の候補として足し、GET /self-voice に
  省ける "s34_auto"（場面ごとの数と、3 通り録る操作が要るか）を足す。
自7 よく会う人の見本（"s34p_people_samples"。既定オン）:
  確かな場面は 3 つ。どれも、名前が記録にもう出てくる人（speakerID のある名前）だけ。
  - 予定の相手が 1 人（archive/calendar の「相手:」が 1 人。s26pvoice.single_partner_events）
  - LINE で直前に約束した相手（母艦 state/talk_guess_for_pc.json の候補で、理由に LINE があるもの）
  - 出席者が分かっている会議（state/s32_meeting_people_for_pc.json）。出席者が 1 人ならいちばん長い名前の無い声、
    2 人以上なら、名前の無い声の真ん中が出席者の声の真ん中といちばん近く（HINT_MIN 以上・2 番目と HINT_MARGIN 以上の差）のときだけ
  その時間の名前の無い声（自分の真ん中に NOT_SELF 以上近い声は除く）を、その人の候補にする。
  別の日の 2 回の声の真ん中が PEOPLE_AGREE 以上でそろったら採用（仮）。HOME/s34p/people-samples.json。
  採用した人は GET /voice-samples に足す（tier "tentative"・"auto": true）。採用は取り消せる（config.json の "s34p_people_samples": false）。

記録（log.txt）には数だけ。名前・文は書かない（HOME の中のファイルには名前がある。この PC の中だけ）。
"""

from __future__ import annotations

import datetime
import itertools
import json
import os
import re
from pathlib import Path

import numpy as np

import voices

FOLDER = "s34p"
SELF_FILE = "self-samples.json"
PEOPLE_FILE = "people-samples.json"
SCAN_DAYS = 14
SAMPLE_MIN, SAMPLE_MAX = 2.0, 10.0   # 仮: 見本にする行の長さ（秒）
PER_SCENE = 5                        # 仮
SCENES = ("home", "work", "out")
HOME_ALONE_MIN = 2                   # 仮
PLAUD_SHARE, PLAUD_LINES = 0.45, 10  # 仮
PLAUD_DT = 3.0                       # 秒
NEAR_DB = 3.0                        # 仮
SELF_SIMILAR = 0.5                   # 仮
NOT_SELF = 0.6                       # 仮
PEOPLE_AGREE = 0.6                   # 仮
PEOPLE_DAYS = 2                      # 仮: 別の日がこれだけそろったら採用（agree_pair は 2 回の組）
HINT_MIN, HINT_MARGIN = 0.45, 0.05   # 仮（s29pvoice.HINT_MIN と同じ）
PER_PERSON = 3
UNNAMED = re.compile(r"人物\d+")
CLOCK = re.compile(r"(\d{1,2}):(\d{2}):(\d{2})")
JST = datetime.timezone(datetime.timedelta(hours=9))


def folder(home: Path) -> Path:
    return Path(home) / FOLDER


def _read(path: Path, default=None):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return default


def _write(path: Path, body) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    part = path.with_name(path.name + ".part")
    part.write_text(json.dumps(body, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(part, path)


def _named(name) -> bool:
    return isinstance(name, str) and bool(name) and name != "自分" and not UNNAMED.fullmatch(name)


def _days(today: datetime.date, back: int = SCAN_DAYS) -> list[str]:
    return [(today - datetime.timedelta(days=k)).isoformat() for k in range(1, back + 1)]


def _num(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _clean(line: dict) -> bool:
    if not _num(line.get("offset")) or not _num(line.get("end")) or not isinstance(line.get("audio"), str):
        return False
    length = float(line["end"]) - float(line["offset"])
    return SAMPLE_MIN <= length <= SAMPLE_MAX and not line.get("noisy") and line.get("media") is None and not line.get("sound")


def _key(line: dict) -> str:
    return voices.seg_key(line["audio"], line["offset"], line["end"])


def _sample(day: str, line: dict, conversation: dict, names: dict, why: str, scene: str | None = None) -> dict:
    job = names.get(line["audio"], line["audio"])
    length = round(float(line["end"]) - float(line["offset"]), 2)
    row = {"day": day, "line_time": voices._iso(line["time"]), "conversation_start": voices._iso(conversation["start"]),
           "audio": job, "offset": round(float(line["offset"]), 2), "length": length,
           "path": f"/audio-clip?audio={job}&offset={float(line['offset']):.2f}&length={length:.2f}", "why": why, "auto": True}
    if scene is not None:
        row["scene"] = scene
    return row


def _has_audio(store, job: str) -> bool:
    finder = getattr(store, "audio_file", None)
    if finder is None:
        return True
    try:
        return finder(job) is not None
    except Exception:  # noqa: BLE001
        return False


def _vectors(home: Path, parsed: dict, day: str) -> dict[str, np.ndarray]:
    import s26pvoice

    try:
        return s26pvoice.day_vectors(home, parsed, day)
    except Exception:  # noqa: BLE001
        return {}


# MARK: - 場面（家・職場・外）


class Scenes:
    """その日の会話の場面。家の手がかり（会話の place・母艦の滞在・区切りの scene）が先、次に職場の印"""

    def __init__(self, home: Path, base: Path | None, day: str, names: dict) -> None:
        self.names = names
        self.stays: list[dict] = []
        self.jobs: dict[str, str] = {}
        try:
            import holidaymarks

            self.stays = holidaymarks.stays_of(day, Path(base)) if base is not None else []
        except Exception:  # noqa: BLE001
            self.stays = []
        try:
            import s24night

            self.jobs = s24night.job_scenes(Path(home), day)
        except Exception:  # noqa: BLE001
            self.jobs = {}

    def _stay(self, ms: int) -> dict | None:
        t = datetime.datetime.fromtimestamp(ms / 1000, JST).strftime("%H:%M")
        for s in self.stays:
            a, b = s.get("s"), s.get("e")
            if isinstance(a, str) and isinstance(b, str) and a <= t < b:
                return s
        return None

    def is_home(self, conversation: dict) -> bool:
        if "自宅" in str(conversation.get("place") or ""):
            return True
        stay = self._stay(int(conversation["start"])) if isinstance(conversation.get("start"), int) else None
        if stay is not None and stay.get("label") == "自宅":
            return True
        for line in conversation.get("lines") or []:
            if isinstance(line, dict) and self.jobs.get(self.names.get(line.get("audio"), line.get("audio"))) == "home":
                return True
        return False

    def of(self, conversation: dict) -> str:
        if self.is_home(conversation):
            return "home"
        if conversation.get("work") is True:
            return "work"
        return "out"


# MARK: - 自6 自分の声


def home_alone(parsed: dict, scenes: Scenes) -> list[tuple[dict, dict]]:
    """[(会話, 自分の行)]（家で、話し手の印が自分だけの会話）"""
    out = []
    for c in parsed.get("conversations") or []:
        if not isinstance(c, dict) or c.get("media") or not isinstance(c.get("start"), int):
            continue
        lines = [x for x in c.get("lines") or [] if isinstance(x, dict)]
        if not lines or any(x.get("media") is not None for x in lines):
            continue
        labels = {voices.label_of(x) for x in lines}
        if labels != {voices.SELF_LABEL}:
            continue
        mine = [x for x in lines if _clean(x) and isinstance(x.get("time"), int)]
        if len(mine) < HOME_ALONE_MIN or not scenes.is_home(c):
            continue
        out.extend((c, x) for x in mine)
    return out


def _clock_ms(day: str, clock) -> int | None:
    m = CLOCK.fullmatch(str(clock or "").strip())
    if not m:
        return None
    try:
        d = datetime.date.fromisoformat(day)
        moment = datetime.datetime(d.year, d.month, d.day, int(m[1]), int(m[2]), int(m[3]))
    except ValueError:
        return None
    return int(moment.timestamp() * 1000)


def plaud_rows(base: Path | None, day: str, parsed: dict) -> list[dict]:
    """PLAUD の行と結べたアプリの行 [{"rec","plaud","line","conversation","consistent"}]（母艦の canonical から）。
    consistent は、その録音の中で PLAUD の話し手とアプリの話し手の多い向きが互いに合っている行"""
    if base is None:
        return []
    body = _read(Path(base) / "digests" / "canonical" / f"{day}.json", None)
    if not isinstance(body, dict):
        return []
    index: list[tuple[int, dict, dict]] = []
    for c in parsed.get("conversations") or []:
        if not isinstance(c, dict) or c.get("media"):
            continue
        for x in c.get("lines") or []:
            if isinstance(x, dict) and isinstance(x.get("time"), int):
                index.append((x["time"], x, c))
    index.sort(key=lambda r: r[0])
    times = [r[0] for r in index]
    import bisect

    found = []
    for row in body.get("lines") or []:
        if not isinstance(row, dict) or row.get("source") != "plaud" or not row.get("plaud_speaker"):
            continue
        t = _clock_ms(day, row.get("time"))
        if t is None:
            continue
        want = str(row.get("speaker_id") or "")
        best = None
        lo, hi = bisect.bisect_left(times, t - PLAUD_DT * 1000), bisect.bisect_right(times, t + PLAUD_DT * 1000)
        for when, line, conv in index[lo:hi]:
            if want and str(line.get("speakerID") or "") != want:
                continue
            gap = abs(when - t)
            if best is None or gap < best[0]:
                best = (gap, line, conv)
        if best is not None:
            found.append({"rec": str(row.get("rec")), "plaud": str(row["plaud_speaker"]), "line": best[1], "conversation": best[2]})
    by_rec: dict[str, list[dict]] = {}
    for r in found:
        by_rec.setdefault(r["rec"], []).append(r)
    for rows in by_rec.values():
        to_app: dict[str, dict] = {}
        to_plaud: dict[str, dict] = {}
        for r in rows:
            a = str(voices.label_of(r["line"]))
            to_app.setdefault(r["plaud"], {}).setdefault(a, 0)
            to_app[r["plaud"]][a] += 1
            to_plaud.setdefault(a, {}).setdefault(r["plaud"], 0)
            to_plaud[a][r["plaud"]] += 1
        for r in rows:
            a = str(voices.label_of(r["line"]))
            r["consistent"] = max(to_app[r["plaud"]], key=to_app[r["plaud"]].get) == a \
                and max(to_plaud[a], key=to_plaud[a].get) == r["plaud"]
    return found


def plaud_major_speakers(base: Path | None, day: str) -> dict[str, str]:
    """録音 → いちばん多い PLAUD の話し手（割合と行の数が足りる録音だけ。結べなかった行も数える）"""
    body = _read(Path(base) / "digests" / "canonical" / f"{day}.json", None) if base is not None else None
    counts: dict[str, dict[str, int]] = {}
    for row in (body or {}).get("lines") or [] if isinstance(body, dict) else []:
        if isinstance(row, dict) and row.get("source") == "plaud" and row.get("plaud_speaker"):
            rec = counts.setdefault(str(row.get("rec")), {})
            rec[str(row["plaud_speaker"])] = rec.get(str(row["plaud_speaker"]), 0) + 1
    out = {}
    for rec, c in counts.items():
        total = sum(c.values())
        top = max(c, key=c.get)
        if total >= PLAUD_LINES and c[top] / total >= PLAUD_SHARE:
            out[rec] = top
    return out


def _levels(home: Path, day: str) -> dict:
    return _read(Path(home) / "s22" / "levels" / f"{day}.json", {}) or {}


def is_near(levels: dict, line: dict) -> bool | None:
    """行の大きさが区切りの声の真ん中 − NEAR_DB 以上か（分からなければ None）"""
    db = ((levels or {}).get("lines") or {}).get(_key(line))
    middle = (((levels or {}).get("chunks") or {}).get(line.get("audio")) or {}).get("voicedP50")
    if not _num(db) or not _num(middle):
        return None
    return float(db) >= float(middle) - NEAR_DB


def self_center(rows: list[dict]) -> np.ndarray | None:
    vecs = [r["_vec"] for r in rows if r.get("_vec") is not None]
    if len(vecs) < 2:
        return None
    return voices._unit(np.mean(np.stack(vecs), axis=0))


def collect_self(home: Path, base: Path | None, store, today: datetime.date | None = None, still_ok=None) -> dict:
    """自6。HOME/s34p/self-samples.json を作り直して返す"""
    today = today or datetime.date.today()
    home = Path(home)
    before = _read(folder(home) / SELF_FILE, {}) or {}
    seen = {f"{s.get('audio')}|{s.get('offset')}" for rows in (before.get("scenes") or {}).values() if isinstance(rows, list)
            for s in rows if isinstance(s, dict)}
    seen |= set(before.get("seen") or [])
    alone: list[dict] = []
    plaud: list[dict] = []
    days_done = 0
    for day in _days(today):
        if still_ok is not None and not still_ok():
            break
        parsed = store.day(day) if store is not None else None
        if not parsed:
            continue
        days_done += 1
        names = parsed.get("audio_names") or {}
        scenes = Scenes(home, base, day, names)
        vectors = _vectors(home, parsed, day)
        for c, line in home_alone(parsed, scenes):
            job = names.get(line["audio"], line["audio"])
            if not _has_audio(store, job):
                continue
            alone.append({**_sample(day, line, c, names, "home_alone", "home"), "_vec": vectors.get(_key(line))})
        majors = plaud_major_speakers(base, day)
        if not majors:
            continue
        levels = _levels(home, day)
        for r in plaud_rows(base, day, parsed):
            line = r["line"]
            if majors.get(r["rec"]) != r["plaud"] or not _clean(line):
                continue
            job = names.get(line["audio"], line["audio"])
            if not _has_audio(store, job):
                continue
            plaud.append({**_sample(day, line, r["conversation"], names, "plaud_major", scenes.of(r["conversation"])),
                          "_vec": vectors.get(_key(line)), "_near": is_near(levels, line)})
    center = self_center(alone)
    kept: list[dict] = list(alone)
    dropped = {"far": 0, "unsure": 0, "not_self": 0}
    for row in plaud:
        sim = float(row["_vec"] @ center) if center is not None and row["_vec"] is not None else None
        checks = [x for x in (row["_near"], None if sim is None else sim >= SELF_SIMILAR) if x is not None]
        if not checks:
            dropped["unsure"] += 1
            continue
        if row["_near"] is False:
            dropped["far"] += 1
            continue
        if sim is not None and sim < SELF_SIMILAR:
            dropped["not_self"] += 1
            continue
        kept.append(row)
    for row in kept:
        row["similarity"] = round(float(row["_vec"] @ center), 3) if center is not None and row.get("_vec") is not None else None
    by_scene: dict[str, list[dict]] = {s: [] for s in SCENES}
    unique: dict[str, dict] = {}
    for row in kept:
        unique.setdefault(f"{row['audio']}|{row['offset']}", row)
    for row in unique.values():
        by_scene[row["scene"]].append(row)
    out_scenes = {}
    added = 0
    for scene, rows in by_scene.items():
        rows.sort(key=lambda r: (r["similarity"] is None, -(r["similarity"] or 0), r["why"] != "home_alone", -r["length"]))
        chosen = []
        for r in rows[:PER_SCENE]:
            r = {k: v for k, v in r.items() if not k.startswith("_")}
            key = f"{r['audio']}|{r['offset']}"
            added += key not in seen
            seen.add(key)
            chosen.append(r)
        out_scenes[scene] = chosen
    body = {"version": 1, "generated_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
            "scenes": out_scenes, "counts": {s: len(v) for s, v in out_scenes.items()}, "added": added,
            "found": {"home_alone": len(alone), "plaud_major": len(plaud)}, "dropped": dropped,
            "center_clips": len([r for r in alone if r.get("_vec") is not None]), "days": days_done,
            "seen": sorted(seen)[-2000:],
            "thresholds": {"sample_min": SAMPLE_MIN, "sample_max": SAMPLE_MAX, "per_scene": PER_SCENE,
                           "plaud_share": PLAUD_SHARE, "plaud_lines": PLAUD_LINES, "near_db": NEAR_DB,
                           "self_similar": SELF_SIMILAR, "仮": True},
            "note": "s34 自6（仮）。確かな場面（家でひとり・PLAUD でいちばん近くて多い声）から機械が集めた候補。足すのは本人の端末"}
    _write(folder(home) / SELF_FILE, body)
    return body


def self_counts(home: Path) -> dict:
    body = _read(folder(Path(home)) / SELF_FILE, {}) or {}
    counts = body.get("counts") if isinstance(body.get("counts"), dict) else {}
    return {"added": int(body.get("added") or 0), "scenes": {s: int(counts.get(s) or 0) for s in SCENES}}


def self_center_of(home: Path, store, today: datetime.date | None = None) -> np.ndarray | None:
    """家でひとりの自分の声の真ん中（自7 で「自分の声」を除くため）"""
    today = today or datetime.date.today()
    rows = []
    for day in _days(today):
        parsed = store.day(day) if store is not None else None
        if not parsed:
            continue
        vectors = _vectors(Path(home), parsed, day)
        scenes = Scenes(Path(home), None, day, parsed.get("audio_names") or {})
        for _, line in home_alone(parsed, scenes):
            v = vectors.get(_key(line))
            if v is not None:
                rows.append({"_vec": v})
    return self_center(rows)


# MARK: - 自7 よく会う人


def windows(base: Path | None, day: str) -> list[dict]:
    """[{"start","end"（ミリ秒）,"names":[…],"source": "calendar"|"line"|"meeting"}]"""
    out = []
    try:
        import s29pvoice

        for start, end, name, source in s29pvoice.hint_windows(base, day):
            out.append({"start": int(start), "end": int(end), "names": [name], "source": source})
    except Exception:  # noqa: BLE001
        pass
    try:
        import s32pwork

        d = datetime.date.fromisoformat(day)
        first = datetime.datetime(d.year, d.month, d.day).timestamp()
        for m in s32pwork.read_meetings(base):
            if first <= m["start"] < first + 86400:
                people = [p for p in m["people"] if _named(p)]
                if people:
                    out.append({"start": int(m["start"] * 1000), "end": int(m["end"] * 1000), "names": people[:40],
                                "source": "meeting"})
    except Exception:  # noqa: BLE001
        pass
    return out


def _unnamed_in(parsed: dict, window: dict, vectors: dict) -> dict[str, dict]:
    """名前の無い声の印 → {"vecs","seconds","lines","conversation"}（その時間の、テレビなどでない会話）"""
    out: dict[str, dict] = {}
    for c in parsed.get("conversations") or []:
        if not isinstance(c, dict) or c.get("media"):
            continue
        for x in c.get("lines") or []:
            if not isinstance(x, dict) or not isinstance(x.get("time"), int) or not window["start"] <= x["time"] <= window["end"]:
                continue
            label = voices.label_of(x)
            if not label or not label.startswith("u:") or x.get("media") is not None:
                continue
            if not _num(x.get("offset")) or not _num(x.get("end")) or not isinstance(x.get("audio"), str):
                continue
            entry = out.setdefault(label, {"vecs": [], "seconds": 0.0, "lines": [], "conversation": c})
            v = vectors.get(_key(x))
            if v is not None:
                entry["vecs"].append(v)
            entry["seconds"] += float(x["end"]) - float(x["offset"])
            entry["lines"].append(x)
    return out


def people_candidates(home: Path, base: Path | None, store, today: datetime.date, refs: dict | None = None,
                      me: np.ndarray | None = None, still_ok=None) -> tuple[list[dict], dict[str, str]]:
    """([{"name","day","source","label","vec","clips","sample"}], 名前 → speakerID)"""
    home = Path(home)
    ids: dict[str, str] = {}
    rows: list[dict] = []
    for day in _days(today):
        if still_ok is not None and not still_ok():
            break
        parsed = store.day(day) if store is not None else None
        if not parsed:
            continue
        for c in parsed.get("conversations") or []:
            for x in c.get("lines") or [] if isinstance(c, dict) else []:
                if isinstance(x, dict) and _named(x.get("speaker")) and isinstance(x.get("speakerID"), str):
                    ids.setdefault(x["speaker"], x["speakerID"])
        wins = windows(base, day)
        if not wins:
            continue
        vectors = _vectors(home, parsed, day)
        names = parsed.get("audio_names") or {}
        for w in wins:
            voices_in = {k: v for k, v in _unnamed_in(parsed, w, vectors).items() if len(v["vecs"]) >= 2}
            centers = {k: voices._unit(np.mean(np.stack(v["vecs"]), axis=0)) for k, v in voices_in.items()}
            if me is not None:
                centers = {k: c for k, c in centers.items() if c is not None and float(c @ me) < NOT_SELF}
            centers = {k: c for k, c in centers.items() if c is not None}
            if not centers:
                continue
            picks: list[tuple[str, str]] = []
            if len(w["names"]) == 1:
                label = max(centers, key=lambda k: voices_in[k]["seconds"])
                picks.append((label, w["names"][0]))
            else:
                for label, center in centers.items():
                    scored = sorted(((float(center @ refs[n][0]), n) for n in w["names"] if refs and n in refs), reverse=True)
                    if not scored:
                        continue
                    second = scored[1][0] if len(scored) > 1 else -1.0
                    if scored[0][0] >= HINT_MIN and scored[0][0] - second >= HINT_MARGIN:
                        picks.append((label, scored[0][1]))
            for label, name in picks:
                if not _named(name):
                    continue
                entry = voices_in[label]
                clean = [x for x in entry["lines"] if _clean(x) and _key(x) in vectors]
                if not clean:
                    continue
                longest = max(clean, key=lambda x: float(x["end"]) - float(x["offset"]))
                job = names.get(longest["audio"], longest["audio"])
                if not _has_audio(store, job):
                    continue
                rows.append({"name": name, "day": day, "source": w["source"], "label": label, "vec": centers[label],
                             "clips": len(entry["vecs"]),
                             "sample": _sample(day, longest, entry["conversation"], names, w["source"])})
    return rows, ids


def agree_pair(rows: list[dict], agree: float = PEOPLE_AGREE) -> tuple[dict, dict, float] | None:
    """違う日の 2 回で、声の真ん中がいちばん近い組（agree 以上のときだけ）"""
    best = None
    for a, b in itertools.combinations(rows[:20], 2):
        if a["day"] == b["day"]:
            continue
        sim = float(a["vec"] @ b["vec"])
        if sim >= agree and (best is None or sim > best[2]):
            best = (a, b, sim)
    return best


def collect_people(home: Path, base: Path | None, store, today: datetime.date | None = None, refs: dict | None = None,
                   me: np.ndarray | None = None, still_ok=None) -> dict:
    """自7。HOME/s34p/people-samples.json（採用した人は残す。名前のある人だけ・人は作らない）"""
    today = today or datetime.date.today()
    home = Path(home)
    path = folder(home) / PEOPLE_FILE
    state = _read(path, {}) or {}
    adopted = state.get("adopted") if isinstance(state.get("adopted"), dict) else {}
    if refs is None and store is not None:
        try:
            import s26pvoice

            refs = s26pvoice.name_refs(home, store, [(today - datetime.timedelta(days=k)).isoformat() for k in range(voices.WINDOW)])
        except Exception:  # noqa: BLE001
            refs = {}
    rows, ids = people_candidates(home, base, store, today, refs, me, still_ok)
    by_name: dict[str, list[dict]] = {}
    for r in rows:
        by_name.setdefault(r["name"], []).append(r)
    added = 0
    waiting = []
    for name, items in sorted(by_name.items()):
        if name not in ids:
            continue
        if name in adopted:
            continue
        pair = agree_pair(items)
        if pair is None:
            waiting.append({"name": name, "days": sorted({r["day"] for r in items}), "sources": sorted({r["source"] for r in items})})
            continue
        a, b, sim = pair
        adopted[name] = {"name": name, "speakerID": ids[name], "at": datetime.datetime.now().isoformat(timespec="seconds"),
                         "days": sorted({a["day"], b["day"]}), "sources": sorted({a["source"], b["source"]}),
                         "similarity": round(sim, 3), "samples": [a["sample"], b["sample"]][:PER_PERSON], "auto": True}
        added += 1
    body = {"version": 1, "generated_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
            "adopted": adopted, "waiting": waiting, "added": added, "candidates": len(rows),
            "thresholds": {"agree": PEOPLE_AGREE, "days": PEOPLE_DAYS, "hint_min": HINT_MIN, "hint_margin": HINT_MARGIN,
                           "not_self": NOT_SELF, "仮": True},
            "note": "s34 自7（仮）。確かな場面（予定の相手が 1 人・LINE で直前に約束・出席者の分かる会議）で、別の日 2 回の声がそろった人だけ。"
                    "名前のある人だけ・人は作らない・まとめない"}
    _write(path, body)
    return body


def people_counts(home: Path) -> dict:
    body = _read(folder(Path(home)) / PEOPLE_FILE, {}) or {}
    adopted = body.get("adopted") if isinstance(body.get("adopted"), dict) else {}
    return {"added": len(adopted), "waiting": len(body.get("waiting") or [])}


# MARK: - 口に足す（GET /voice-samples・GET /self-voice）


def _on(config_of, name: str) -> bool:
    try:
        value = (config_of() or {}).get(name)
    except Exception:  # noqa: BLE001
        value = None
    return value if isinstance(value, bool) else True


def extra_people(home: Path, config_of) -> list[dict]:
    out = []
    if _on(config_of, "s34p_self_samples"):
        body = _read(folder(Path(home)) / SELF_FILE, {}) or {}
        samples = [s for scene in SCENES for s in (body.get("scenes") or {}).get(scene) or [] if isinstance(s, dict)]
        if samples:
            out.append({"speaker": "自分", "speakerID": voices.SELF_ID,
                        "conversations": len({(s.get("day"), s.get("conversation_start")) for s in samples}),
                        "samples": samples, "candidates": len(samples), "scenes": self_counts(home)["scenes"],
                        "tier": "tentative", "auto": True,
                        "tier_why": "確かな場面（家でひとり・PLAUD でいちばん近くて多い声）から機械が集めた。足すのは本人の端末",
                        "evidence_kinds": ["scene", "voice"]})
    if _on(config_of, "s34p_people_samples"):
        body = _read(folder(Path(home)) / PEOPLE_FILE, {}) or {}
        for e in (body.get("adopted") or {}).values():
            if isinstance(e, dict) and e.get("samples") and _named(e.get("name")):
                out.append({"speaker": e["name"], "speakerID": e["speakerID"], "conversations": len(e.get("samples") or []),
                            "samples": e["samples"], "candidates": len(e["samples"]), "tier": "tentative", "auto": True,
                            "tier_why": "確かな場面で、別の日 2 回の声がそろった（仮）。足すのは本人の端末",
                            "evidence_kinds": ["scene", "voice"]})
    return out


def wrap_samples(original, home_of, config_of):
    def read(home: Path) -> dict:
        body = original(home)
        try:
            extra = extra_people(home_of() or home, config_of)
            if extra:
                have = {p.get("speaker") for p in body.get("people") or []}
                body = {**body, "available": True,
                        "people": list(body.get("people") or []) + [p for p in extra if p["speaker"] not in have]}
        except Exception:  # noqa: BLE001 — 足せなくても今の答えを返す
            pass
        return body

    read.s34p_wrapped = True  # type: ignore[attr-defined]
    return read


def wrap_self(original, home_of, config_of):
    def read(home: Path) -> dict:
        body = original(home)
        try:
            if _on(config_of, "s34p_self_samples") and isinstance(body, dict):
                counts = self_counts(home_of() or home)["scenes"]
                body = {**body, "s34_auto": {"scenes": counts, "record_needed": not all(counts[s] > 0 for s in SCENES),
                                             "note": "家・職場・外のどれにも機械の見本があれば、3 通り録る操作は要りません（仮）"}}
        except Exception:  # noqa: BLE001
            pass
        return body

    read.s34p_wrapped = True  # type: ignore[attr-defined]
    return read


def install(home_of, config_of) -> None:
    import selfvoice
    import voicesamples

    if not getattr(voicesamples.read, "s34p_wrapped", False):
        voicesamples.read = wrap_samples(voicesamples.read, home_of, config_of)
    if not getattr(selfvoice.read, "s34p_wrapped", False):
        selfvoice.read = wrap_self(selfvoice.read, home_of, config_of)
