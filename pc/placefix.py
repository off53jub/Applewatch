"""LifeLog PC: 地名の聞き間違いを、読み（かな）で照らして「直す候補」に出す（強化案 100。2026-11-16）。

文字起こしの語を、その日いた所・予定の場所・前に行った所（母艦の場所の台帳）・地名の辞書（HOME/gazetteer。任意）の
名前と、読み（かな）で照らし、読みが近いのに書き方が違う所を、夜の読み直し（nightreview.py）の聞き間違い（misheard）と
同じ形の候補にする。**勝手には直さない**（アプリの「聞き間違いかも」に出て、本人が押したときだけ直る）。

決まり:
- 読みは pykakasi（この PC がもう使っているもの）。無ければ何も出さない。
- 候補は、文の中の続いた語（トークンの並び 2〜12 文字）を、名前の読みと比べる。読みが同じ（漢字違い。名前の読みが 3 字以上）か、
  読みの違いが少しだけ（名前の読みが 6 字以上で 1〜2 字。edits）で、最初か最後の読みが同じ。語が名前の一部・名前が語の一部
  （東京と東京都）、名前がすでにその文に書かれている、別名ですでに書けている、ときは出さない。
  （2026-11-16 の実データで、読みの近さだけでは短い名前がふつうの語に当たりすぎた。docs/s16-pc-place-search-2026-11-16.md）
- 1 日の上限 DAY_MAX。同じ（行・語）は 1 つ。記録（log.txt）には数だけ（文・名前は書かない）。
- 地名の辞書の名前は多いので、読みの 2 文字の並び（bigram）の索引で絞ってから比べる。
"""

from __future__ import annotations

import datetime
import difflib
import hashlib
import math
from pathlib import Path

import placehints

SIMILAR = 0.80                 # find() の引数として残している（いまは edits で決める）
SAME_READING_MIN = 3           # 読みが同じ（漢字違い）で出せる、名前の読みの最短
NEAR_READING_MIN = 6           # 読みが少し違う語まで出せる、名前の読みの最短（5 字の名前は延長・身長のようなふつうの語に当たりすぎた）
WRONG_MIN, WRONG_MAX = 2, 12
NAME_READING_MIN = 3
DAY_MAX = 100
_kakasi = None
_cache: dict[str, list[tuple[str, str]]] = {}


def _kks():
    global _kakasi
    if _kakasi is None:
        import pykakasi

        _kakasi = pykakasi.kakasi()
    return _kakasi


def tokens(text: str) -> list[tuple[str, str]]:
    """[(表記, 読み（ひらがな。長音は除く）)]"""
    got = _cache.get(text)
    if got is None:
        try:
            got = [(str(p["orig"]), str(p["hira"]).replace("ー", "")) for p in _kks().convert(text)]
        except Exception:  # noqa: BLE001 — 読めなければ出さない
            got = []
        if len(_cache) > 20000:
            _cache.clear()
        _cache[text] = got
    return got


def reading_of(name: str) -> str:
    return "".join(r for _, r in tokens(name))


def _bigrams(text: str) -> set[str]:
    return {text[i:i + 2] for i in range(len(text) - 1)}


class NameIndex:
    """名前（[{"name", "reading"?, "origin"}]）を、読みの 2 文字の並びで引けるようにしたもの"""

    def __init__(self, names: list[dict]) -> None:
        self.items: list[dict] = []
        self.known = {n.get("name") for n in names}
        self.index: dict[str, list[int]] = {}
        seen = set()
        for n in names:
            name = n.get("name") or ""
            if name in seen:
                continue
            seen.add(name)
            reading = (n.get("reading") or "").replace("ー", "") or reading_of(name)
            if len(reading) < NAME_READING_MIN:
                continue
            item = {"name": name, "reading": reading, "origin": n.get("origin") or ""}
            self.items.append(item)
            for g in _bigrams(reading):
                self.index.setdefault(g, []).append(len(self.items) - 1)

    def near(self, line_reading: str) -> list[dict]:
        grams = _bigrams(line_reading)
        count: dict[int, int] = {}
        for g in grams:
            for i in self.index.get(g, ()):
                count[i] = count.get(i, 0) + 1
        out = []
        for i, c in count.items():
            if c >= max(2, math.ceil((len(self.items[i]["reading"]) - 1) * 0.5)):
                out.append(self.items[i])
        return out


def edits(a: str, b: str) -> int:
    """読みの違い（1 字の入れ替え・足す・抜くを 1 と数える）"""
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y)))
        prev = cur
    return prev[-1]


def allowed_edits(length: int) -> int:
    """読みの長さごとの、許す違いの数（短い名前は同じ読みだけ。ふつうの語と取り違えやすいので）"""
    if length < SAME_READING_MIN:
        return -1
    if length < NEAR_READING_MIN:
        return 0
    return 1 if length <= 8 else 2


def find(text: str, index: NameIndex, similar: float = SIMILAR) -> list[dict]:
    """1 つの文から [{"wrong", "guess", "score", "origin"}]。名前ごとに一番近い 1 つだけ。
    読みが同じ（漢字違い）か、読みの違いが少しだけ（allowed_edits）の語。語が名前の一部・名前が語の一部（東京と東京都）は出さない。
    すでに知っている名前（別名）で書けていれば、その名前は出さない"""
    toks = tokens(text)
    if not toks or not index.items:
        return []
    line_reading = "".join(r for _, r in toks)
    out = []
    for item in index.near(line_reading):
        name, reading = item["name"], item["reading"]
        if name in text:
            continue
        limit = allowed_edits(len(reading))
        if limit < 0:
            continue
        gazetteer = item["origin"] == "gazetteer"
        if gazetteer:
            limit = 0      # 辞書（全国の駅など数が多い）は、読みが同じで漢字が違う語だけ。読みが近いだけだと、ふつうの語に当たりすぎる
        best, resolved = None, False
        for i in range(len(toks)):
            surface = seg = ""
            for j in range(i, len(toks)):
                surface += toks[j][0]
                seg += toks[j][1]
                if len(surface) > WRONG_MAX or len(seg) > len(reading) + limit:
                    break
                if len(seg) < len(reading) - limit or len(surface) < WRONG_MIN:
                    continue
                if seg[:1] != reading[:1] and seg[-1:] != reading[-1:]:
                    continue
                gap = edits(seg, reading)
                if gap > limit:
                    continue
                if surface in index.known:
                    best, resolved = None, True     # すでに知っている名前（別名）で書けている
                    break
                if surface == name or surface in name or name in surface:
                    continue
                if gazetteer and not (set(surface) & set(name.rstrip("駅"))):
                    continue   # 辞書の名前とは、1 字も同じ字が無い語（有益と由宇駅など）は出さない
                score = 1.0 - gap / max(len(reading), 1)
                if best is None or score > best[0]:
                    best = (score, surface)
            if resolved:
                break
        if best:
            out.append({"wrong": best[1], "guess": name, "score": round(best[0], 3), "origin": item["origin"]})
    return out


ORIGIN_WORDS = {"stay": "その日いた所", "calendar": "予定の場所", "record": "その時間にいた所", "ledger": "前に行った所",
                "gazetteer": "地名の辞書"}


def iso_ms(ms: int) -> str:
    return datetime.datetime.fromtimestamp(ms / 1000).astimezone().isoformat(timespec="seconds")


def for_day(day: str, lines: list[dict], base: Path | None, home: Path | None, use_gazetteer: bool = True) -> list[dict]:
    """その日の行（nightreview.day_lines の形: time(ms)・text）から、聞き間違いの候補（nightreview の misheard と同じ形）。
    地名の出どころが無ければ空"""
    if base is None:
        return []
    try:
        _kks()
    except Exception:  # noqa: BLE001 — pykakasi が無ければ出さない
        return []
    names = placehints.known_names(base, day, home)
    if use_gazetteer:
        names += [{"name": g["name"], "reading": g["reading"], "origin": "gazetteer"} for g in placehints.gazetteer_names()]
    if not names:
        return []
    index = NameIndex(names)
    out, seen = [], set()
    for line in lines:
        for hit in find(line["text"], index):
            key = (line["time"], hit["wrong"])
            if key in seen or hit["wrong"] not in line["text"]:
                continue
            seen.add(key)
            digest = hashlib.sha256(f"{day}|place|{line['time']}|{hit['wrong']}".encode()).hexdigest()[:12]
            out.append({"id": f"nr-{day.replace('-', '')}-p{digest}", "day": day, "line_time": iso_ms(line["time"]),
                        "wrong": hit["wrong"], "guess": hit["guess"][:20],
                        "reason": f"読みが近い地名（{ORIGIN_WORDS.get(hit['origin'], '地名')}）"[:60], "place": True})
            if len(out) >= DAY_MAX:
                return out
    return out
