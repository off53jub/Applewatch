"""LifeLog PC: s25 大4（2026-11-24。担当 P）。PLAUD の文を先生にした、自分専用の文字起こしモデルの学び直し。

- 材料（夜 01:00〜05:00・1 晩 TEACHER_NIGHT 個まで・仮）: 後で受け取る文字起こしの行（HOME/jobs の .result と音声）のうち、
  時刻の合う PLAUD の文と TEACHER_MATCH 以上合う行（仮）について、**PLAUD の文のほう**（行に合う所だけを切り出したもの・
  句読点はそのまま）を正しい文にして、学び直しの材料（HOME/personal/data）に足す。"source": {"origin": "pc-plaud-teacher",
  "auto": true, "job", "offset", "plaud"}。自動の材料なので、正解集（goldset.py）・試験には入らない（train_personal の決まり）。
  s22 確16 の "pc-plaud"（モデルの文のほうを正しいとした材料）とは別。同じ区切りの同じ時刻の材料は 2 重に足さない。
- 学び直し（1 回だけ・家の PC が自分で動かす）: この版が入って最初の晩の 00:00〜05:00 に、trainer.AutoTrainer に
  「この晩だけの時間帯」を渡し、train_personal.py を --test-human-all --candidate で動かす。
    --test-human-all … 人が確かめた材料（正解集と同じもの）を全部試験に使い、学ぶのは自動の材料だけ（前後を正解集で測る）
    --candidate      … 良くなっても入れ替えない。HOME/personal/model.candidate に置いて trained.json に前後の CER を書く
  材料の数・部品・GPU・仕事の様子の決まりは今までの学び直しと同じ（足りなければ動かず「待っています」）。
  config.json の "s25p_train_once": false で止める。初めはオン（ただし切り替えない）。"s25p_teacher": false で材料も足さない。
- 切り替えるかは本人（summary.md に前後の CER を 1 行。自動では切り替えない）。
"""

from __future__ import annotations

import collections
import datetime
import json
import os
import time
import unicodedata
from pathlib import Path

ORIGIN = "pc-plaud-teacher"
TEACHER_NIGHT = 300          # 仮
TEACHER_TOTAL = 3000
TEACHER_MATCH = 0.7          # 仮: 行の字のうち PLAUD と同じ並びで合った割合
TEACHER_LEN = (0.7, 1.4)     # 仮: 切り出した PLAUD の字の数 ÷ 行の字の数
TEACHER_DAYS = 14
MIN_CHARS = 6
ONCE_FILE = Path("s25p") / "train-once.json"
ONCE_ARGS = ["--test-human-all", "--candidate"]
ONCE_TRIES = 7               # 仮: 材料が足りないなどで動けなかった晩を、これだけ待つ


def _raw_index(raw: str) -> tuple[str, list[int]]:
    """raw を judgecheck.norm と同じ決まりで 1 字ずつ縮め、縮めた字ごとの raw の位置"""
    import judgecheck

    out, index = [], []
    for i, ch in enumerate(raw):
        for n in judgecheck.norm(ch):
            out.append(n)
            index.append(i)
    return "".join(out), index


def teacher_text(machine_norm: str, blocks: list[str]) -> tuple[str, float] | None:
    """機械の行（縮めた字）に合う所を、PLAUD の文（blocks の生の文をつないだもの）から切り出す。(文, 合った割合)"""
    import difflib

    raw = "".join(blocks)
    ref, index = _raw_index(raw)
    if not machine_norm or not ref:
        return None
    matcher = difflib.SequenceMatcher(None, machine_norm, ref, autojunk=False)
    parts = [b for b in matcher.get_matching_blocks() if b.size >= 2]
    if not parts:
        return None
    matched = sum(b.size for b in parts)
    rate = matched / len(machine_norm)
    if rate < TEACHER_MATCH:
        return None
    j0, j1 = parts[0].b, parts[-1].b + parts[-1].size
    # 行の頭・終わりが合っていなければ、その分だけ PLAUD の側も広げる（字の数で）
    j0 = max(0, j0 - parts[0].a)
    j1 = min(len(ref), j1 + (len(machine_norm) - (parts[-1].a + parts[-1].size)))
    span = j1 - j0
    if not (TEACHER_LEN[0] <= span / len(machine_norm) <= TEACHER_LEN[1]):
        return None
    start, end = index[j0], index[j1 - 1] + 1
    while end < len(raw) and raw[end] in "。、！？!?」』）)":   # 句読点はそのまま付ける
        end += 1
    text = unicodedata.normalize("NFC", raw[start:end]).strip()
    return (text, round(rate, 3)) if text else None


def near_blocks(recs: list[dict], t: float, window: float = 20.0) -> list[str] | None:
    for rec in recs:
        t0 = rec.get("t0")
        if t0 is None:
            continue
        rel = t - t0
        if rel < -window or rel > rec["blocks"][-1]["end"] + window:
            continue
        near = [b["text"] for b in rec["blocks"] if b["end"] >= rel - window and b["t"] <= rel + window]
        if near:
            return near
    return None


def teacher_samples(main, home: Path, base: Path, today: datetime.date, config: dict, dry: bool = False,
                    deadline: float | None = None) -> dict:
    """材料を足す（dry なら数えるだけで何も書かない）。{"added","candidates","days","skipped"}"""
    import judgecheck
    import plaudmatch

    out = {"added": 0, "candidates": 0, "days": 0, "changed": 0}
    if base is None or config.get("s25p_teacher") is False:
        return out
    rows = main.read_samples(main.PERSONAL_DATA)
    mine = [r for r in rows if isinstance(r.get("source"), dict) and r["source"].get("origin") == ORIGIN]
    have = {(r["source"].get("job"), r["source"].get("offset")) for r in rows if isinstance(r.get("source"), dict)}
    room = min(TEACHER_NIGHT, TEACHER_TOTAL - len(mine))
    if room <= 0 and not dry:
        return out
    wanted = {(today - datetime.timedelta(days=i)).isoformat() for i in range(1, TEACHER_DAYS + 1)}
    by_day: dict[str, list] = collections.defaultdict(list)
    for path in sorted((Path(home) / "jobs").glob("*.result"), reverse=True):
        try:
            result = json.loads(path.read_text(encoding="utf-8"))
            meta = json.loads(path.with_suffix(".json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        name = str(meta.get("id") or "")
        begin = judgecheck.chunk_epoch(name)
        if begin is None:
            continue
        for line in result.get("lines") or []:
            try:
                start, end = float(line["start"]), float(line["end"])
            except (KeyError, TypeError, ValueError):
                continue
            day = datetime.datetime.fromtimestamp(begin + start).strftime("%Y-%m-%d")
            if day in wanted:
                by_day[day].append((begin + start, start, end, str(line.get("text") or ""), name, path))
    for day in sorted(by_day, reverse=True):
        if deadline is not None and time.time() > deadline:
            break
        recs, _ = plaudmatch._timed(Path(home), Path(base), day)
        if not recs:
            continue
        out["days"] += 1
        for moment, start, end, text, name, path in by_day[day]:
            if not dry and out["added"] >= room:
                break
            normed = judgecheck.norm(text)
            if not 2.0 <= end - start <= main.SAMPLE_MAX or len(normed) < MIN_CHARS:
                continue
            if (name[:80], round(start, 2)) in have:
                continue
            blocks = near_blocks(recs, moment)
            got = teacher_text(normed, blocks) if blocks else None
            if got is None:
                continue
            out["candidates"] += 1
            label, rate = got
            if judgecheck.norm(label) != normed:
                out["changed"] += 1          # 機械の文と違う（先生が直す）材料
            if dry:
                continue
            audio_path = path.with_suffix(".audio")
            if not audio_path.is_file():
                continue
            try:
                audio = main.load_audio(audio_path.read_bytes())
                _, put = main.save_sample(main.PERSONAL_DATA, audio, start, end, label[:main.SAMPLE_TEXT_MAX],
                                          {"origin": ORIGIN, "auto": True, "job": name[:80], "offset": round(start, 2),
                                           "plaud": rate})
            except (ValueError, OSError):
                continue
            if put:
                have.add((name[:80], round(start, 2)))
                out["added"] += 1
    return out


# MARK: - 1 回だけの学び直し


def _read(path: Path) -> dict:
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def _write(path: Path, body) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    part = path.with_name(path.name + ".part")
    part.write_text(json.dumps(body, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(part, path)


def once_window(home: Path, config: dict, now: float, build: str = "0") -> dict | None:
    """この版で 1 回だけの学び直しの時間帯（00:00〜05:00）。{"window": (始め, 終わり), "args": [...]}。済んだ・止めたら None。
    動けた（refused 以外で終わった）晩で済みにする。材料が足りないなどで動けなければ、次の晩も渡す（ONCE_TRIES 晩まで）"""
    if config.get("s25p_train_once") is False:
        return None
    state = _read(Path(home) / ONCE_FILE)
    if state.get("done") or len(state.get("nights") or []) > ONCE_TRIES:
        return None
    moment = datetime.datetime.fromtimestamp(now)
    if not 0 <= moment.hour < 5:
        return None
    night = moment.date().isoformat()
    nights = list(state.get("nights") or [])
    if night not in nights:
        nights.append(night)
        state.update({"nights": nights, "build": str(build)})
        _write(Path(home) / ONCE_FILE, state)
    begin = datetime.datetime.combine(moment.date(), datetime.time(0, 0)).timestamp()
    finish = datetime.datetime.combine(moment.date(), datetime.time(5, 0)).timestamp()
    return {"window": (begin, finish), "args": list(ONCE_ARGS)}


def once_finished(home: Path, result: dict) -> None:
    """trainer が 1 回だけの学び直しを終えたとき（refused は数えない＝次の晩にもう一度）"""
    if not isinstance(result, dict) or result.get("result") == "refused":
        return
    state = _read(Path(home) / ONCE_FILE)
    state.update({"done": True, "result": {k: result.get(k) for k in ("at", "result", "cer_before", "cer_after", "seconds")}})
    _write(Path(home) / ONCE_FILE, state)


def candidate_info(home: Path) -> dict | None:
    info = _read(Path(home) / "personal" / "model.candidate" / "trained.json")
    return info or None
