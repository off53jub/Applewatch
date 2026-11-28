"""s39（2026-11-29）: iPhone と iPad が同じ部屋で同時に録ったときの、2 台の記録のつなぎ合わせ。

- 家の PC は、端末の印（POST /records/<日> の省ける "device"・"deviceKind"）がある記録を
  <home>/records/devices/<端末>/<日>.json に端末ごとにそのまま置き（控え）、合わせた 1 日を
  今までどおり <home>/records/<日>.json に置く。読む側（画面・探す・MCP・夜の仕事）は今までどおり <日>.json を読む。
- 重なりの見分け方（どれも仮。config.json の "two_devices" で変えられる）:
  時刻の差が window_s 秒（仮 30）以内で、文字の似ている度合い（正規化した 2 文字ずつの重なり）が
  similarity（仮 0.6）以上か、短い方（4 文字以上）が長い方にそのまま入っている行は「同じ発言」とみなし 1 行にする。
- 残すのは iPhone（と、端末の印の無い古い送り＝iPhone）の行。iPad の行の確からしさが
  confidence_margin（仮 0.2）より高いときだけ iPad の行を残す。
  まとめた行には "overlap": true・"devices"（元の端末）・"device"（残した端末）を付ける。
- 1 台分しか無い日は、届いた中身をそのまま置く（今までと同じ）。

アプリの同期でも同じ見分け方を使う（LifeLog/S39Overlap.swift。数字はここと同じ）。
会話の文・人の名前は記録（log）に書かない（数だけ）。
"""

from __future__ import annotations

import bisect
import copy
import re
import unicodedata

import records

LEGACY = "legacy"          # 端末の印の無い古い送り（いままでの iPhone）
DEVICE = re.compile(r"[0-9a-z]{1,32}")
KINDS = ("phone", "pad")

DEFAULTS = {
    "on": True,
    "window_s": 30.0,          # 仮: 同じ発言とみなす時刻の差（秒）
    "similarity": 0.6,         # 仮: 同じ発言とみなす似ている度合い（0〜1）
    "contain_min": 4,          # 仮: 「短い方が長い方に入っている」を同じとみなす、短い方の文字数の下限
    "confidence_margin": 0.2,  # 仮: iPad の行を残すのに要る、確からしさの差
}


def settings(config: dict | None) -> dict:
    """config.json の "two_devices" を読む（読めない値は既定のまま）"""
    out = dict(DEFAULTS)
    raw = (config or {}).get("two_devices")
    if isinstance(raw, dict):
        for key, default in DEFAULTS.items():
            value = raw.get(key)
            if isinstance(default, bool):
                if isinstance(value, bool):
                    out[key] = value
            elif isinstance(value, (int, float)) and not isinstance(value, bool) and value >= 0:
                out[key] = type(default)(value)
    return out


def valid_device(value) -> bool:
    return isinstance(value, str) and DEVICE.fullmatch(value) is not None


def kind_of(value) -> str:
    return value if value in KINDS else "phone"


# MARK: - 似ている度合い（Swift の S39Overlap と同じ）


def norm(text) -> str:
    """全角・半角と大文字・小文字をそろえ、空白・句読点・記号を除く"""
    text = unicodedata.normalize("NFKC", text or "").casefold()
    return "".join(ch for ch in text if unicodedata.category(ch)[0] in ("L", "N"))


def _grams(text: str) -> dict[str, int]:
    out: dict[str, int] = {}
    for i in range(len(text) - 1):
        gram = text[i:i + 2]
        out[gram] = out.get(gram, 0) + 1
    return out


def similarity(a: str, b: str, contain_min: int = 4) -> float:
    """正規化した文の似ている度合い（0〜1）。2 文字ずつの重なり（Dice）。
    短い方（contain_min 文字以上）が長い方にそのまま入っていれば 1"""
    a, b = norm(a), norm(b)
    if not a or not b:
        return 0.0
    if a == b:
        return 1.0
    short, long_ = (a, b) if len(a) <= len(b) else (b, a)
    if len(short) >= max(contain_min, 1) and short in long_:
        return 1.0
    ga, gb = _grams(a), _grams(b)
    total = sum(ga.values()) + sum(gb.values())
    if total == 0:
        return 0.0
    both = sum(min(count, gb.get(gram, 0)) for gram, count in ga.items())
    return 2.0 * both / total


def same_line(t1: int, text1: str, t2: int, text2: str, cfg: dict) -> float | None:
    """同じ発言なら似ている度合い、違えば None（t は 1970 年からのミリ秒）"""
    if abs(t1 - t2) > cfg["window_s"] * 1000:
        return None
    score = similarity(text1, text2, int(cfg["contain_min"]))
    return score if score >= cfg["similarity"] else None


def _conf(line: dict) -> float | None:
    value = line.get("confidence")
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


def other_wins(base: dict, other: dict, base_kind: str, other_kind: str, cfg: dict) -> bool:
    """重なった 2 行のうち、other（あとから合わせる端末）の行を残すか。
    iPhone を優先し、iPad の行は確からしさが margin より高いときだけ。同じ種類なら確からしさの高い方"""
    a, b = _conf(base), _conf(other)
    if b is None:
        return False
    if a is None:
        return base_kind != "phone"
    margin = cfg["confidence_margin"] if base_kind == "phone" and other_kind != "phone" else 0.0
    return b - a > margin


# MARK: - 合わせる


def _time(value) -> int | None:
    try:
        return records.parse_time(value, "time")
    except ValueError:
        return None


def order(sources: list[dict]) -> list[dict]:
    """iPhone（古い送りを含む）を先に、端末の名前の順"""
    return sorted(sources, key=lambda s: (0 if kind_of(s.get("kind")) == "phone" else 1,
                                          0 if s["device"] == LEGACY else 1, s["device"]))


def merge(sources: list[dict], cfg: dict) -> tuple[dict, dict]:
    """端末ごとの 1 日（[{"device", "kind", "body"}]）を 1 つにする。(合わせた中身, 数)"""
    sources = order([s for s in sources if isinstance(s.get("body"), dict)])
    stats = {"sources": len(sources), "merged": 0, "replaced": 0, "added_lines": 0, "added_conversations": 0}
    if not sources:
        return {"conversations": []}, stats
    first = sources[0]
    merged = copy.deepcopy(first["body"])
    if len(sources) == 1:
        return merged, stats
    window = cfg["window_s"] * 1000
    convs = [c for c in merged.get("conversations") or [] if isinstance(c, dict)]
    merged["conversations"] = convs
    # 合わせた行の並び（時刻, 会話, 行）と、その行の端末
    kinds = {s["device"]: kind_of(s.get("kind")) for s in sources}
    for conv in convs:
        for line in conv.get("lines") or []:
            if isinstance(line, dict):
                line.setdefault("device", first["device"])
    index: list[tuple[int, dict]] = []
    times: list[int] = []

    def rebuild() -> None:
        index.clear()
        for conv in convs:
            for line in conv.get("lines") or []:
                t = _time(line.get("time")) if isinstance(line, dict) else None
                if t is not None:
                    index.append((t, line))
        index.sort(key=lambda item: item[0])
        times[:] = [t for t, _ in index]

    rebuild()
    for source in sources[1:]:
        device, kind = source["device"], kinds[source["device"]]
        for oc in source["body"].get("conversations") or []:
            if not isinstance(oc, dict):
                continue
            fresh = []
            for line in oc.get("lines") or []:
                if not isinstance(line, dict) or not isinstance(line.get("text"), str):
                    continue
                t = _time(line.get("time"))
                if t is None:
                    continue
                best, best_score = None, None
                lo_i = bisect.bisect_left(times, t - window)
                hi_i = bisect.bisect_right(times, t + window)
                for bt, bl in index[lo_i:hi_i]:
                    score = same_line(bt, bl.get("text") or "", t, line["text"], cfg)
                    if score is not None and (best_score is None or score > best_score):
                        best, best_score = bl, score
                if best is None:
                    item = copy.deepcopy(line)
                    item["device"] = device
                    fresh.append((t, item))
                    continue
                stats["merged"] += 1
                devices = sorted(set(best.get("devices") or [best.get("device") or first["device"]]) | {device})
                if other_wins(best, line, kinds.get(best.get("device"), "phone"), kind, cfg):
                    keep = copy.deepcopy(line)
                    best.clear()
                    best.update(keep)
                    best["device"] = device
                    stats["replaced"] += 1
                best["devices"] = devices
                best["overlap"] = True
            if not fresh:
                continue
            start, end = _time(oc.get("start")), _time(oc.get("end"))
            lo = min([start] + [t for t, _ in fresh]) if start is not None else min(t for t, _ in fresh)
            hi = max([end or lo] + [t for t, _ in fresh])
            host = None
            for conv in convs:
                cs, ce = _time(conv.get("start")), _time(conv.get("end"))
                if cs is None:
                    continue
                ce = ce if ce is not None else cs
                if lo <= ce + window and hi >= cs - window:
                    host = conv
                    break
            if host is None:
                item = copy.deepcopy(oc)
                item["lines"] = [line for _, line in fresh]
                item["device"] = device
                convs.append(item)
                stats["added_conversations"] += 1
            else:
                lines = [line for line in host.get("lines") or [] if isinstance(line, dict)] + [line for _, line in fresh]
                lines.sort(key=lambda line: _time(line.get("time")) or 0)
                host["lines"] = lines
                cs, ce = _time(host.get("start")), _time(host.get("end"))
                if cs is not None and lo < cs:
                    host["start"] = records.iso_ms(lo)
                if ce is not None and hi > ce:
                    host["end"] = records.iso_ms(hi)
                host["devices"] = sorted(set(host.get("devices") or [first["device"]]) | {device})
            stats["added_lines"] += len(fresh)
            rebuild()
        # 1 日の項目を足し合わせる
        body = source["body"]
        if isinstance(body.get("work"), list):
            work = merged.get("work") if isinstance(merged.get("work"), list) else []
            seen = {_time(w) for w in work}
            for w in body["work"]:
                t = _time(w)
                if t is not None and t not in seen:
                    work.append(w)
                    seen.add(t)
            merged["work"] = work
        if isinstance(body.get("audioNames"), dict):
            names = merged.get("audioNames") if isinstance(merged.get("audioNames"), dict) else {}
            for k, v in body["audioNames"].items():
                names.setdefault(k, v)
            merged["audioNames"] = names
        if isinstance(body.get("removed"), list):
            removed = merged.get("removed") if isinstance(merged.get("removed"), list) else []
            seen = {(r.get("start"), r.get("rev")) for r in removed if isinstance(r, dict)}
            for r in body["removed"]:
                if isinstance(r, dict) and (r.get("start"), r.get("rev")) not in seen:
                    removed.append(r)
            merged["removed"] = removed
        if not isinstance(merged.get("summary"), dict) and isinstance(body.get("summary"), dict):
            merged["summary"] = copy.deepcopy(body["summary"])
    convs.sort(key=lambda c: _time(c.get("start")) or 0)
    merged["mergedFrom"] = [s["device"] for s in sources]
    merged.pop("device", None)
    merged.pop("deviceKind", None)
    return merged, stats
