"""LifeLog PC: 「自分」の行に、自分の声の見本との近さを付け、遠い行に「本人かどうか仮」の印を付ける（s20 の次6。2026-11-21）。

動画・実況・ゲーム・店内の声が「自分」の発話に混ざるのを、声の近さで見つける。記録は書き換えない・行を消さない。
印は HOME/self-lines/<日>.json に置く（省略可能。無くても今まで通り動く）。言語モデルは使わない（0 円）。
- 自分の声の見本の真ん中: selfvoice.gather（今ある自分の行の声の特徴。静か・騒がしいの両方）の平均から、さらに
  真ん中に近い行（trim 以上）だけで取り直す（遠い行が混ざった平均で測ると、混ざった行を近いと見てしまうため）。
  声の特徴は voices/<日>.npz にある今までのもの。新しくは測らない（embed を呼ばない）。
- 行ごとの近さ sim = 声の特徴と真ん中の cos。far（仮）未満の行が「本人かどうか仮」（kind "self_far"・label "見立て（仮）"）。
  各行の [時刻ミリ秒, sim] を lines に、遠い行（近さの低い順・far_max_per_day 件まで）を far に置く。
- 真ん中の作り直し（14 日ぶんの npz を読む）は voices.heavy_ok の時間（00:00〜05:00・08:30〜18:00）だけ。ほかの時間は、
  前に作った真ん中（HOME/self-lines/center.json）で今日と昨日の行だけ測る（軽い）。
- しきい値はすべて仮（DEFAULTS。config.json の "self_lines" で上書き）。測った数は PR の説明。
- 「聞いて直す」に出すのは、設定で "doubts": true にしたときだけ（既定は出さない＝本人の画面を増やさない）。
- s37 精2（2026-11-28）: 母艦に「PLAUD の音で本人と確かめた区間だけ」で作った見本（state/s37v_self_center.json・
  母艦の scripts/s37v-Voice-Models.py が作る）があり、use が true・同じ型・同じ次元・30 日以内（仮）なら、それで測る。
  前の見本（center.json）は今まで通り作って残す。母艦の見張りが use を false に戻したら（物差しが下がったら）次の回から前の見本へ。
  config.json の "self_lines": {"clean_center": false} で止めて前の見本に戻せる。各日の center に source（clean／own）を書く。
置き場所: HOME/self-lines/<日>.json。母艦 inbox/self-lines/days/<日>.json（lines を除いた写し）。GET /self-lines?day=（knowme の口）。
記録（log.txt）には数だけ。
"""

from __future__ import annotations

import datetime
import json
import os
import re
from pathlib import Path
from typing import Callable

import numpy as np

import selfvoice
import voices

FOLDER = "self-lines"
CENTER_FILE = "center.json"
MOTHER_DIR = Path("inbox") / "self-lines"
VERSION = 1
LABEL = "見立て（仮）"
KIND = "self_far"
DOUBT_REASON = "声が自分の見本から遠い（本人かどうか仮）"

DEFAULTS = {
    "_note": "仮（2026-11-21・P）。直すのは本人かまとめ役。測った数は PR の説明",
    "enabled": True,
    "far": 0.40,              # 仮: 自分の声の見本との近さがこれ未満の行を「本人かどうか仮」にする
    "trim": 0.50,             # 仮: 見本の真ん中を取り直すとき、この近さ以上の行だけ使う
    "scan_days": 14,          # 真ん中を作る日数
    "min_center": 30,         # 真ん中に要る行の数
    "far_max_per_day": 200,   # 1 日の far に置く行の数の上限
    "keep_days": 30,          # 置き場所に残す日数
    "doubts": False,          # 仮: 「聞いて直す」に遠い行を出すか（既定は出さない）
    "clean_center": True,     # s37 精2: 母艦の確かめた見本があれば使う（false で前の見本だけ）
    "clean_max_age_days": 30, # 仮: 母艦の見本がこれより古ければ使わない
}
CLEAN_FILE = Path("state") / "s37v_self_center.json"   # 母艦（s37v-Voice-Models.py が書く）


def settings(config: dict | None) -> dict:
    out = dict(DEFAULTS)
    mine = (config or {}).get("self_lines")
    if isinstance(mine, dict):
        out.update({k: v for k, v in mine.items() if k in DEFAULTS and not k.startswith("_")})
    return out


def _read(path: Path) -> dict | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def _write(path: Path, data: dict) -> bool:
    text = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
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


def make_center(units: list[np.ndarray], cfg: dict) -> tuple[np.ndarray | None, int]:
    """自分の行の声の特徴から見本の真ん中を作る（まず全部の平均・次に近い行だけで取り直す）。(真ん中, 使った行数)"""
    if len(units) < int(cfg["min_center"]):
        return None, len(units)
    matrix = np.stack(units)
    first = voices._unit(matrix.mean(axis=0))
    if first is None:
        return None, 0
    near = matrix[matrix @ first >= float(cfg["trim"])]
    if len(near) < int(cfg["min_center"]):
        return first, len(matrix)
    return voices._unit(near.mean(axis=0)), len(near)


def center_of(home: Path, store, cfg: dict, today: datetime.date, heavy: bool) -> tuple[np.ndarray | None, dict]:
    """見本の真ん中。heavy でなければ前の真ん中を使う（無ければ作る＝初めの 1 回だけ）"""
    path = Path(home) / FOLDER / CENTER_FILE
    cached = _read(path)
    # 前に作った真ん中がある: 重い時間でなければそのまま・重い時間でも今日作ったものなら（1 日 1 回だけ作り直す）
    if cached and (not heavy or cached.get("made_on") == today.isoformat()):
        try:
            vec = voices._unit(np.asarray(cached["vec"], dtype=np.float64))
            if vec is not None:
                return vec, {"lines": cached.get("lines"), "made_on": cached.get("made_on"), "cached": True}
        except (KeyError, TypeError, ValueError):
            pass
    if not heavy:  # 初めての真ん中は、重い時間まで待つ（14 日ぶんの声の特徴を読むため）
        return None, {"waiting": "heavy time"}
    units = selfvoice.gather(home, store, today)
    pooled = units["quiet"] + units["noisy"]
    vec, used = make_center(pooled, cfg)
    meta = {"lines": used, "made_on": today.isoformat(), "pool": len(pooled), "cached": False}
    if vec is not None:
        _write(path, {"version": VERSION, "made_on": today.isoformat(), "lines": used, "pool": len(pooled),
                      "vec": [round(float(x), 6) for x in vec]})
    return vec, meta


def clean_center(mother: Path | None, cfg: dict, today: datetime.date, dim: int) -> tuple[np.ndarray | None, dict]:
    """s37 精2: 母艦の確かめた見本。使えないときは (None, 理由)（＝前の見本のまま）"""
    if not cfg.get("clean_center"):
        return None, {"clean": "stopped"}
    if mother is None:
        return None, {"clean": "no mother"}
    data = _read(Path(mother) / CLEAN_FILE)
    if not data:
        return None, {"clean": "none"}
    if data.get("use") is not True:
        return None, {"clean": "not used"}
    if data.get("model") != voices.MODEL:
        return None, {"clean": "other model"}
    try:
        made = datetime.date.fromisoformat(str(data.get("made_at") or "")[:10])
    except ValueError:
        return None, {"clean": "bad date"}
    if (today - made).days > int(cfg["clean_max_age_days"]):
        return None, {"clean": "old"}
    try:
        vec = voices._unit(np.asarray(data.get("vec"), dtype=np.float64))
    except (TypeError, ValueError):
        vec = None
    if vec is None or vec.ndim != 1 or len(vec) != dim:
        return None, {"clean": "bad vector"}
    return vec, {"source": "clean", "clean_sha": data.get("sha"), "clean_made_at": data.get("made_at"),
                 "clean_lines": data.get("lines"), "clean_auc": [data.get("auc_now"), data.get("auc_new")]}


def _iso(ms: int) -> str:
    return datetime.datetime.fromtimestamp(ms / 1000, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + f"{ms % 1000:03d}Z"


def build_day(home: Path, store, day: str, center: np.ndarray, center_meta: dict, cfg: dict) -> dict | None:
    parsed = store.day(day)
    if parsed is None:
        return None
    ds = voices.DayStore(home, day).load()
    if not ds.vectors:
        return None
    rows = []
    for seg in voices.segments(parsed):
        if seg["label"] != voices.SELF_LABEL:
            continue
        vec = ds.vectors.get(seg["key"])
        unit = voices._unit(np.asarray(vec, dtype=np.float64)) if vec is not None else None
        when = seg["line"].get("time")
        if unit is None or not isinstance(when, int):
            continue
        rows.append((when, float(unit @ center), seg))
    far_cut = float(cfg["far"])
    far_rows = sorted((r for r in rows if r[1] < far_cut), key=lambda r: r[1])
    sims = sorted(r[1] for r in rows)
    far = []
    for when, sim, seg in far_rows[:int(cfg["far_max_per_day"])]:
        item = {"kind": KIND, "label": LABEL, "line_time": _iso(when), "time_ms": when, "audio": seg["audio"],
                "start": round(seg["start"], 2), "end": round(seg["end"], 2), "sim": round(sim, 3),
                "why": f"自分の声の見本との近さ {sim:.2f}（しきい値 {far_cut}・仮）",
                "evidence": [{"text": "自分の行の声が見本から遠い", "ref": voices.seg_key(seg["audio"], seg["start"], seg["end"])}]}
        if seg["line"].get("noisy"):
            item["noisy"] = True
        if seg["line"].get("sound"):
            item["sound"] = seg["line"]["sound"]
        far.append(item)
    built = {"version": VERSION, "day": day, "center": center_meta,
             "thresholds": {"far": far_cut, "trim": float(cfg["trim"]), "仮": True},
             "summary": {"self_lines": len(rows), "far": len(far_rows),
                         "far_share": round(len(far_rows) / len(rows), 3) if rows else None,
                         "median": round(sims[len(sims) // 2], 3) if sims else None},
             "far": far, "lines": [[w, round(s, 3)] for w, s, _ in sorted(rows, key=lambda r: r[0])]}
    _write(Path(home) / FOLDER / f"{day}.json", built)
    return built


def prune(home: Path, keep_days: int, today: datetime.date) -> int:
    removed = 0
    limit = (today - datetime.timedelta(days=keep_days)).isoformat()
    for path in (Path(home) / FOLDER).glob("????-??-??.json"):
        if path.stem < limit:
            try:
                path.unlink()
                removed += 1
            except OSError:
                pass
    return removed


def run(home: Path, store, mother: Path | None, config: dict, log: Callable[[str], None], days: list[str], heavy: bool,
        mother_copy: bool = True, today: datetime.date | None = None) -> dict:
    cfg = settings(config)
    if not cfg["enabled"]:
        return {"skipped": "stopped"}
    today = today or datetime.date.today()
    center, meta = center_of(home, store, cfg, today, heavy)
    if center is None:
        return {"skipped": "no center", "pool": meta.get("pool")}
    clean, why = clean_center(mother, cfg, today, len(center))
    if clean is not None:
        meta = {**meta, **why, "own_lines": meta.get("lines")}
        center = clean
    else:
        meta = {**meta, "source": "own", **why}
    todo = list(days)
    if heavy:  # 重い時間は、まだ作っていない日（直近 scan_days 日）も作る
        for i in range(int(cfg["scan_days"])):
            day = (today - datetime.timedelta(days=i)).isoformat()
            if day not in todo and not (Path(home) / FOLDER / f"{day}.json").exists():
                todo.append(day)
    made = []
    for day in todo:
        try:
            built = build_day(home, store, day, center, meta, cfg)
        except Exception as error:  # noqa: BLE001 — 1 日が失敗しても続ける
            log(f"自分の行の近さ: {day} を作れませんでした: {type(error).__name__}")
            continue
        if built is not None:
            made.append(built)
    copied = 0
    if mother_copy and mother is not None and Path(mother).is_dir():
        for built in made:
            slim = {k: v for k, v in built.items() if k != "lines"}
            copied += int(_write(Path(mother) / MOTHER_DIR / "days" / f"{built['day']}.json", slim))
    prune(home, int(cfg["keep_days"]), today)
    if made:
        lines = sum(b["summary"]["self_lines"] for b in made)
        far = sum(b["summary"]["far"] for b in made)
        log(f"自分の行の近さ: {len(made)} 日・自分の行 {lines}・遠い行 {far}・母艦へ {copied}・見本 {meta.get('source')}")
    return {"days": len(made), "far": sum(b["summary"]["far"] for b in made), "copied": copied, "source": meta.get("source")}


def read_day(home: Path, day: str) -> dict:
    data = _read(Path(home) / FOLDER / f"{day}.json") if re.fullmatch(r"\d{4}-\d{2}-\d{2}", day) else None
    return {"available": True, **data} if data else {"available": False}


def doubts(home: Path, day: str, config: dict | None) -> dict[int, list[str]]:
    """records.RecordStore.extra_doubts に足す分: 遠い行の時刻 → 理由。設定で "doubts": true のときだけ"""
    if not settings(config)["doubts"]:
        return {}
    data = _read(Path(home) / FOLDER / f"{day}.json") or {}
    return {int(x["time_ms"]): [DOUBT_REASON] for x in data.get("far") or []
            if isinstance(x, dict) and isinstance(x.get("time_ms"), int)}
