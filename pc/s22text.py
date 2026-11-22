"""LifeLog PC: s22（2026-11-22）の文字の分。決まりと測った数は docs/s22-pc.md。0 円・言語モデルなし。

- 確18 行ごとの確かさ conf（0〜1）: iPhone が付けた confidence と、モデルの票の割れ（いちばん遠い 2 つの近さ）の小さいほう。
  どちらも無い行には付けない。records の行に省ける "conf" として付ける（母艦の M がまとめと検索で軽く扱う）。
- 確20 数字と表記のゆれをそろえた文 norm: 全角の数字→半角・漢数字（数え方の言葉の前だけ）→算用数字・「15時30分」→「15:30」・
  「午後3時」→「15時」。元の文（text）は消さない。そろえて変わった行だけ "norm" を付ける。
- 確19 数字・日付・金額がモデルの票で割れた行: 票ごとに数字の並び（norm にしてから取り出す）が違えば候補にする
  （choices＝票の文。同じ文は 1 つ）。
- 確12 無音で出る決まり文句: lifelog_pc.WHISPER_JUNK（whisper だけ）に足りない分を EXTRA_JUNK に足す。
  「これだけの文」で、ほかのモデルが何も書いていない行だけ捨てる（文の途中にあるものは捨てない）。
- 確21 行の時刻を言葉の時刻から: 選んだ文の言葉ごとの時刻（"words"）があれば、行の始まり・終わりを最初と最後の言葉に寄せる
  （区間の中・寄せる幅 MAX_SHIFT 秒まで）。既定はオフ（config.json の "word_line_times": true で使う）。測った数は docs。
- 確11 区切りの境目: 区切りの最初の行が 0.3 秒より前から始まり、前の区切り（同じ端末・続いた時刻）の最後の行が終わりの
  0.3 秒より後まで続いていれば、言葉が切れた見込みが高いので、行に "joinPrev": true（省ける）を付ける。音声はつながない（docs）。
文の中身は記録（log.txt）に書かない。
"""

from __future__ import annotations

import difflib
import re
import unicodedata

CONF_ROUND = 2
MAX_SHIFT = 1.5          # 確21: 行の始まり・終わりを言葉の時刻に寄せる幅（秒）
EDGE = 0.3               # 確11: 区切りの端から何秒以内を「端にかかっている」と見るか

# 確12: lifelog_pc.WHISPER_JUNK（ご視聴ありがとうございました・ご清聴・チャンネル登録・お疲れ様でした・字幕・ありがとうございました）
# は「これだけの文」で声が無いときに捨てる決まり。Whisper の仲間だけが書いた行は、もともと作り話として捨てている（vote）。
# 足りなかったのは「ほかのモデルが別のことを書いた行で、Whisper の票だけが決まり文句」の場合。2026-11-15〜22 の jobs の答え
# 8,659 行で数えたら、Whisper の票が下の文で haas の文と似ていない（近さの中央値 0.10）行が 90 行・そのうち 9 行で選ばれていた。
EXTRA_JUNK = re.compile(
    r"^(ご協力ありがとうございました|以上です|以上で終わります|お待ちしております|おやすみなさい|"
    r"最後までご視聴(いただき)?ありがとうございました|ご視聴いただきありがとうございました|"
    r"チャンネル登録(を|と高評価を?)?お願い(いた)?します|高評価(と|&)チャンネル登録(を)?お願い(いた)?します|"
    r"ご視聴ありがとうございました|ご清聴ありがとうございました|お疲れ様でした|ありがとうございました|字幕.*)[。！!\s]*$")
INVENTING = {"whisper", "kotoba", "mine", "qwen", "cloud", "parakeet", "sensevoice"}
JUNK_KEEP = 0.5   # ほかのモデルの文とこれ以上似ていれば、本当に言ったとみなして残す
JUNK_ON = True    # config.json の "junk_votes": false で止める（s22pc.start が入れる）


def is_extra_junk(text: str) -> bool:
    return bool(EXTRA_JUNK.match(str(text or "").strip()))


def drop_junk(hypotheses: dict) -> dict:
    """確12: Whisper の仲間の票が決まり文句だけで、ほかのモデルの文と似ていなければ、その票を空にする（行は消さない）"""
    others = [str(t or "") for k, t in hypotheses.items()
              if k.removesuffix("_e") not in INVENTING and str(t or "").strip()]
    out = dict(hypotheses)
    for name, text in hypotheses.items():
        if name.removesuffix("_e") not in INVENTING or not is_extra_junk(text or ""):
            continue
        if others and max(similarity(text, o) for o in others) >= JUNK_KEEP:
            continue
        out[name] = ""
    return out


# MARK: - 確20 そろえる

KANJI_DIGITS = {"〇": 0, "零": 0, "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9}
KANJI_UNITS = {"十": 10, "百": 100, "千": 1000}
KANJI_BIG = {"万": 10_000, "億": 100_000_000}
COUNTERS = "時分秒日月年円人回個本枚件歳才階番号点度割台杯泊週万億千百"
KANJI_NUM = re.compile(r"[〇零一二三四五六七八九十百千万億]+(?=[" + COUNTERS + r"])")
CLOCK = re.compile(r"(\d{1,2})時(\d{1,2})分")
PM = re.compile(r"(午後|夜の?)(\d{1,2})時")
AM = re.compile(r"午前(\d{1,2})時")
# 「一人」「一緒」「一番」など、数ではない語の頭の漢数字は替えない
NOT_NUMBER = re.compile(r"^(一(人|緒|番|つ|度|回|気|応|旦|生|部|切|般|日中|時的)|二人|万が一|千葉|十分|百均|一本化)")


def kanji_to_int(text: str) -> int | None:
    total, section, digit = 0, 0, None
    for ch in text:
        if ch in KANJI_DIGITS:
            if digit is not None:   # 「二三」のような並びは数にしない
                return None
            digit = KANJI_DIGITS[ch]
        elif ch in KANJI_UNITS:
            section += (digit if digit is not None else 1) * KANJI_UNITS[ch]
            digit = None
        elif ch in KANJI_BIG:
            section += digit or 0
            total += (section or 1) * KANJI_BIG[ch]
            section, digit = 0, None
        else:
            return None
    return total + section + (digit or 0)


def normalize(text: str) -> str:
    """確20: 数字と時刻の書き方をそろえた文（元の文は呼ぶ側が残す）"""
    out = unicodedata.normalize("NFKC", str(text or ""))

    def kanji(match: re.Match) -> str:
        word = match.group(0)
        head = out[match.start():match.start() + 4]
        if NOT_NUMBER.match(head):
            return word
        value = kanji_to_int(word)
        return str(value) if value is not None else word

    out = KANJI_NUM.sub(kanji, out)
    out = PM.sub(lambda m: f"{int(m.group(2)) + 12 if int(m.group(2)) < 12 else int(m.group(2))}時", out)
    out = AM.sub(lambda m: f"{int(m.group(1))}時", out)
    out = CLOCK.sub(lambda m: f"{int(m.group(1))}:{int(m.group(2)):02d}", out)
    out = re.sub(r"(\d),(\d{3})", r"\1\2", out)
    return out


NUMBER = re.compile(r"\d+(?::\d{2})?(?:[." + "]" + r"\d+)?\s*[" + COUNTERS + r"]?")


def numbers_of(text: str) -> tuple[str, ...]:
    """確19: そろえた文の数字の並び（「3時」「1500円」「15:30」など）"""
    return tuple(m.group(0).replace(" ", "") for m in NUMBER.finditer(normalize(text)))


def number_split(votes: dict | None) -> list[str] | None:
    """確19: 票の数字の並びが割れていれば、候補の文（同じ文は 1 つ・数字のある票だけ・2 つ以上）。割れていなければ None"""
    if not isinstance(votes, dict):
        return None
    texts = []
    for _name, text in votes.items():
        text = str(text or "").strip()
        if text and text not in texts:
            texts.append(text)
    found = {t: numbers_of(t) for t in texts}
    with_numbers = [t for t in texts if found[t]]
    if len(with_numbers) < 2 or len({found[t] for t in with_numbers}) < 2:
        return None
    return with_numbers[:4]


# MARK: - 確18 確かさ


def similarity(a: str, b: str) -> float:
    a = re.sub(r"[\s、。！？!?,.]", "", unicodedata.normalize("NFKC", a or ""))
    b = re.sub(r"[\s、。！？!?,.]", "", unicodedata.normalize("NFKC", b or ""))
    if not a and not b:
        return 1.0
    if not a or not b:
        return 0.0
    return difflib.SequenceMatcher(None, a, b, autojunk=False).ratio()


def agreement(votes: dict | None) -> float | None:
    """票のいちばん遠い 2 つの近さ（黙っていた票は 0 として数える）。票が 2 つ未満なら None"""
    if not isinstance(votes, dict):
        return None
    texts = [str(v or "") for v in votes.values()]
    if len(texts) < 2:
        return None
    worst = 1.0
    for i, a in enumerate(texts):
        for b in texts[i + 1:]:
            worst = min(worst, similarity(a, b))
    return worst


def line_conf(line: dict) -> float | None:
    """確18: 行の確かさ（0〜1）。iPhone の confidence と票の割れの小さいほう。どちらも無ければ None"""
    parts = []
    conf = line.get("confidence")
    if isinstance(conf, (int, float)) and not isinstance(conf, bool) and conf == conf:
        parts.append(min(1.0, max(0.0, float(conf))))
    agree = agreement(line.get("votes"))
    if agree is not None:
        parts.append(agree)
    if not parts:
        return None
    return round(min(parts), CONF_ROUND)


# MARK: - 確21・確11 時刻


def refine_times(lines: list[dict], max_shift: float = MAX_SHIFT) -> int:
    """確21: 言葉の時刻があれば行の start・end を寄せる（元は "segStart"・"segEnd"）。寄せた行の数"""
    moved = 0
    for line in lines:
        words = line.get("words")
        if not isinstance(words, list) or not words:
            continue
        try:
            first, last = float(words[0][0]), float(words[-1][1])
            start, end = float(line["start"]), float(line["end"])
        except (TypeError, ValueError, KeyError, IndexError):
            continue
        new_start = first if start <= first <= start + max_shift else start
        new_end = last if end - max_shift <= last <= end else end
        if new_end - new_start < 0.2 or (new_start == start and new_end == end):
            continue
        line["segStart"], line["segEnd"] = start, end
        line["start"], line["end"] = round(new_start, 2), round(new_end, 2)
        moved += 1
    return moved


def boundary_cut(prev_lines: list[dict] | None, prev_length: float | None, lines: list[dict]) -> bool:
    """確11: 前の区切りの最後の行が終わりまで続き、この区切りの最初の行が頭から始まっているか"""
    if not lines or not prev_lines or not prev_length:
        return False
    try:
        head = float(lines[0]["start"])
        tail = max(float(x["end"]) for x in prev_lines)
    except (TypeError, ValueError, KeyError):
        return False
    return head <= EDGE and tail >= float(prev_length) - EDGE


def annotate_line(line: dict) -> dict:
    """確18・確20: 記録の行（iPhone の形の dict）に conf・norm を付けた写し（元の行は変えない）"""
    out = dict(line)
    conf = line_conf(line)
    if conf is not None:
        out["conf"] = conf
    else:
        out.pop("conf", None)
    text = line.get("text")
    if isinstance(text, str):
        norm = normalize(text)
        if norm != text:
            out["norm"] = norm
        else:
            out.pop("norm", None)
    return out
