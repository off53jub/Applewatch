"""LifeLog PC: 本人が直した行を正解集にして、PC の版が変わるたびに同じ音声で点数を出す（s21 精15。2026-11-22）。

正解集＝あなた向けのモデルの材料（HOME/personal/data の samples.jsonl と .wav）のうち、人が確かめたもの
（iPhone で直した文・PC の「聞いて直す」で答えたもの）。自動の材料（"origin": "pc-auto"。モデルが書いた文）は入れない。
新しく貯める置き場は作らない（同じ材料をそのまま使う。材料は勝手に消さない決まりなので、正解集も減らない）。

点数（HOME/goldset-scores.json。{"builds": {"<BUILD>": {"at", "items", "cer", "engines": {モデル: cer}, "seconds"}}}）:
- PC の版（BUILD.txt の番号）が前に点数を出した版と違えば、重い仕事の時間帯（00:00〜05:00・08:30〜18:00）で、
  新しい区切りの仕事が待っていないときに、正解集の音声を今のモデルで文字にして、文字の誤りの割合（CER。小さいほど良い）を出す。
  多数決の文の CER と、モデルごとの文の CER。1 回の上限は BUDGET 秒。途中で新しい区切りが来たら止めて、あとでやり直す。
- 同じ版でも、正解集が前より RESCORE_GROWTH 個以上増えたら出し直す（数が違う点数を比べないよう、items を残す）。
文の中身はどこにも出さない（数だけ）。
"""

from __future__ import annotations

import datetime
import json
import os
import time
import unicodedata
import wave
from pathlib import Path
from typing import Callable

import numpy as np

FILE = "goldset-scores.json"
BUDGET = 900.0          # 1 回の上限（秒）
RESCORE_GROWTH = 20     # 正解集がこれだけ増えたら、同じ版でも出し直す
KEEP_BUILDS = 30
RATE = 16000


def norm(text: str) -> str:
    return "".join(ch for ch in unicodedata.normalize("NFKC", text or "") if ch.isalnum())


def edit_distance(a: str, b: str) -> int:
    """文字の置き換え・足し・抜けの数（Levenshtein）"""
    if len(a) < len(b):
        a, b = b, a
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        current = [i]
        for j, cb in enumerate(b, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (ca != cb)))
        previous = current
    return previous[-1]


def cer(pairs: list[tuple[str, str]]) -> float | None:
    """(正解, 書いた文) の並びの CER（誤りの数の合計 ÷ 正解の文字の合計）"""
    total = sum(len(norm(ref)) for ref, _ in pairs)
    if not total:
        return None
    return round(sum(edit_distance(norm(ref), norm(hyp)) for ref, hyp in pairs) / total, 4)


def items(folder: Path) -> list[dict]:
    """正解集（人が確かめた材料で、音声のファイルがあるもの）"""
    out = []
    try:
        lines = (Path(folder) / "samples.jsonl").read_text(encoding="utf-8").splitlines()
    except OSError:
        return out
    for raw in lines:
        try:
            row = json.loads(raw)
        except ValueError:
            continue
        source = row.get("source") if isinstance(row, dict) else None
        if not isinstance(row, dict) or (isinstance(source, dict) and source.get("origin") == "pc-auto"):
            continue
        audio = Path(folder) / str(row.get("audio") or "")
        if row.get("audio") and audio.is_file() and norm(str(row.get("text") or "")):
            out.append({"audio": audio, "text": str(row["text"])})
    return out


def read_wav(path: Path) -> np.ndarray:
    with wave.open(str(path), "rb") as w:
        frames = w.readframes(w.getnframes())
    return np.frombuffer(frames, dtype="<i2").astype(np.float32) / 32768.0


def read_scores(home: Path) -> dict:
    try:
        data = json.loads((Path(home) / FILE).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"builds": {}}
    return data if isinstance(data, dict) and isinstance(data.get("builds"), dict) else {"builds": {}}


def due(home: Path, build: int, count: int) -> bool:
    """この版の点数を出す（出し直す）時か"""
    if count == 0:
        return False
    done = read_scores(home)["builds"].get(str(build))
    return not isinstance(done, dict) or count - int(done.get("items") or 0) >= RESCORE_GROWTH


def score(home: Path, folder: Path, build: int, transcribe: Callable[[np.ndarray], list[dict]],
          should_stop: Callable[[], bool], log: Callable[[str], None], budget: float = BUDGET) -> dict | None:
    """正解集を文字にして点数を出し、HOME/goldset-scores.json に書く。途中で止めたら None（書かない）。
    transcribe(音声) は多数決の行（"text"・"votes"）を返す"""
    found = items(folder)
    if not found:
        return None
    started = time.time()
    voted: list[tuple[str, str]] = []
    by_engine: dict[str, list[tuple[str, str]]] = {}
    for item in found:
        if should_stop() or time.time() - started > budget:
            log(f"正解集の点数: 途中でやめました（{len(voted)}/{len(found)} 個。あとでやり直します）")
            return None
        try:
            lines = transcribe(read_wav(item["audio"]))
        except Exception as error:  # noqa: BLE001 — 1 つ読めなくても、ほかは続ける
            log(f"正解集の点数: 1 つ文字にできませんでした（{type(error).__name__}）")
            continue
        voted.append((item["text"], "".join(str(line.get("text") or "") for line in lines)))
        engines = {name for line in lines for name in (line.get("votes") or {})}
        for name in engines:
            text = "".join(str((line.get("votes") or {}).get(name) or "") for line in lines)
            by_engine.setdefault(name, []).append((item["text"], text))
    if not voted:
        return None
    entry = {"at": datetime.datetime.now().isoformat(timespec="seconds"), "items": len(voted), "cer": cer(voted),
             "engines": {name: cer(pairs) for name, pairs in sorted(by_engine.items()) if len(pairs) == len(voted)},
             "seconds": round(time.time() - started, 1)}
    data = read_scores(home)
    data["builds"][str(build)] = entry
    for old in sorted(data["builds"], key=lambda b: str(data["builds"][b].get("at") or ""))[:-KEEP_BUILDS]:
        data["builds"].pop(old, None)
    path = Path(home) / FILE
    part = path.with_name(path.name + ".part")
    part.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(part, path)
    log(f"正解集の点数: 版 {build} で {len(voted)} 個、誤りの割合 {entry['cer']:.1%}（{entry['seconds']:.0f} 秒）"
        if entry["cer"] is not None else f"正解集の点数: 版 {build} で {len(voted)} 個")
    return entry


def lines_for_summary(home: Path, limit: int = 5) -> list[str]:
    """summary.md の行（新しい版から）"""
    builds = read_scores(home)["builds"]
    if not builds:
        return []
    out = []
    for build in sorted(builds, key=lambda b: str(builds[b].get("at") or ""), reverse=True)[:limit]:
        entry = builds[build]
        engines = "・".join(f"{k} {v:.1%}" for k, v in (entry.get("engines") or {}).items() if isinstance(v, (int, float)))
        total = entry.get("cer")
        out.append(f"版 {build}（{str(entry.get('at') or '')[:16].replace('T', ' ')}・{entry.get('items')} 個）: "
                   f"多数決 {total:.1%}" if isinstance(total, (int, float)) else f"版 {build}: —")
        if engines:
            out[-1] += f"（{engines}）"
    return out
