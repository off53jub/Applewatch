"""LifeLog PC: s32（2026-11-27。担当 p）知8 — 口で読み上げた番号を、番号の候補にする（純粋な関数だけ。母艦 M2 も読める）。

  「さんのにーよんご」→「3-245」／「まるいちのごのご」→「①-5-5」／「ぜろ・いち・に」→ 区切りが「の」「ハイフン」「ダッシュ」のとき

決まり（どれも仮）:
- 記録の文は変えない。見つけたら `{"text": 元の字, "value": 直した番号, "start", "end", "cue"}` の候補を返すだけ。
- 数字の読みが 3 つ以上つながったとき、または 2 つ以上＋前後に「番号・チケット・ケース・案件・ナンバー・番」があるときだけ候補にする。
- 日付・時刻・数え方（月・日・時・分・円・人・件・回・年…）が続くものは候補にしない。十・百・千・万 がつながるものも対象外。
- 「し」「く」「よ」の 1 文字の読みは使わない（助詞・動詞とまざるので）。「よん」「きゅう」「なな」「ぜろ」は使う。
- 「まる」＋ 1〜9 は丸数字（①〜⑨）。数字（0-9）がすでに字になっているものも、読みとまざって数える。
"""

from __future__ import annotations

import re
import unicodedata

DIGITS = {
    "ぜろ": "0", "れい": "0", "ゼロ": "0", "零": "0",
    "いち": "1", "一": "1", "に": "2", "二": "2", "さん": "3", "三": "3",
    "よん": "4", "四": "4", "ご": "5", "五": "5", "ろく": "6", "六": "6",
    "なな": "7", "しち": "7", "七": "7", "はち": "8", "八": "8", "きゅう": "9", "九": "9",
}
CIRCLED = "①②③④⑤⑥⑦⑧⑨"
SEPARATORS = ("の", "ハイフン", "はいふん", "ダッシュ", "だっしゅ", "-", "−", "‐", "ー-")
UNITS = "月日時分秒円人個件回年目階歳万千百十本枚匹台冊度週曜"
CUE_BEFORE = re.compile(r"(番号|ナンバー|ばんごう|なんばー|チケット|ちけっと|ケース|けーす|案件|インシデント|No\.?|NO\.?|#)\s*[のはがを]?\s*$")
CUE_AFTER = re.compile(r"^\s*(番|ばん|の件|の案件)")
MAX_RUN = 24            # 1 つの番号の読みの長さの上限（読みの数）
MAX_FOUND = 12          # 1 つの文で出す候補の上限（仮）

_KATA = {c: chr(ord(c) - 0x60) for c in map(chr, range(0x30A1, 0x30F7))}
_WORDS = sorted(DIGITS, key=len, reverse=True)


def _hira(text: str) -> str:
    """カタカナをひらがなに（長さを変えない。ー はそのまま）。全角英数は半角へ（長さは 1 字対 1 字）"""
    out = []
    for c in text:
        c = _KATA.get(c, c)
        if "０" <= c <= "９":
            c = chr(ord(c) - 0xFEE0)
        out.append(c)
    return "".join(out)


def _digit_at(norm: str, i: int) -> tuple[str, int] | None:
    """i の位置から読める 1 つぶんの数字。(1 字の数字か丸数字, 読みの終わり)"""
    if norm.startswith("まる", i):
        got = _digit_at(norm, i + 2)
        if got and got[0] in "123456789" and not norm.startswith("まる", i + 2):
            return CIRCLED[int(got[0]) - 1], got[1]
        return None
    if i < len(norm) and norm[i].isdigit() and norm[i].isascii():
        return norm[i], i + 1
    for word in _WORDS:
        key = _hira(word)
        if norm.startswith(key, i):
            end = i + len(key)
            if end < len(norm) and norm[end] == "ー":
                end += 1  # にー・ごー・きゅー などの伸ばし
            return DIGITS[word], end
    return None


def _separator_at(norm: str, i: int) -> int | None:
    for sep in SEPARATORS:
        key = _hira(sep)
        if norm.startswith(key, i):
            return i + len(key)
    return None


def _runs(norm: str) -> list[tuple[int, int, str, int]]:
    """(始まり, 終わり, 番号, 数字の数)"""
    found: list[tuple[int, int, str, int]] = []
    i = 0
    while i < len(norm):
        first = _digit_at(norm, i)
        if first is None:
            i += 1
            continue
        groups = [first[0]]
        count, pos = 1, first[1]
        while count < MAX_RUN:
            nxt = _digit_at(norm, pos)
            if nxt is not None:
                groups[-1] += nxt[0]
                count += 1
                pos = nxt[1]
                continue
            sep = _separator_at(norm, pos)
            if sep is not None:
                after = _digit_at(norm, sep)
                if after is not None:
                    groups.append(after[0])
                    count += 1
                    pos = after[1]
                    continue
            break
        found.append((i, pos, "-".join(groups), count))
        i = max(pos, i + 1)
    return found


def find(text: str) -> list[dict]:
    """文の中の、読み上げた番号の候補（文は変えない）"""
    if not isinstance(text, str) or not text:
        return []
    # NFKC は長さを変えることがあるので使わない（位置を元の文に合わせるため）。ここでは字ごとの変換だけ
    norm = _hira(text)
    out: list[dict] = []
    for start, end, value, count in _runs(norm):
        if count < 2:
            continue
        before, after = text[:start], text[end:]
        if before and before[-1] in "十百千万" or after[:1] in tuple("十百千万"):
            continue
        # 前の字が数字・かな・英字の続きなら、言葉の途中なので外す（ただし助詞の前の「の」で終わった所は別）
        if before and (re.match(r"[ぁ-んァ-ヶ一-龥A-Za-z]", before[-1])) and not CUE_BEFORE.search(before):
            if not re.match(r"[をはがもでにへと、。 　]", before[-1]):
                continue
        if re.match(rf"[{UNITS}]|ぷん|ふん|がつ|にち|じ(?![ぁ-ん])|えん|にん|こ(?![ぁ-ん])|けん|かい|ねん", _hira(after)) \
                and not CUE_AFTER.match(after):
            continue
        cue = bool(CUE_BEFORE.search(before)) or bool(CUE_AFTER.match(after))
        if count < 3 and not (count >= 2 and cue):
            continue
        out.append({"text": text[start:end], "value": value, "start": start, "end": end, "cue": cue})
        if len(out) >= MAX_FOUND:
            break
    return out


def annotate(lines: list[dict]) -> int:
    """行の "numbers" に候補を足す（文・話し手は書き換えない。候補があった行の数を返す）"""
    n = 0
    for line in lines or []:
        if not isinstance(line, dict):
            continue
        got = find(str(line.get("text") or ""))
        if got:
            line["numbers"] = got
            n += 1
    return n
