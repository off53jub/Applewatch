"""LifeLog PC: s32（2026-11-27。担当 p）知7・知8・知9 — 仕事の聞き取りを、仕事に合わせる。K32-4（型の頭は s32p）。

- 知9 会議の出席者で、話し手の候補を寄せる
  母艦の state/s32_meeting_people_for_pc.json（母艦 M2 が作る）: {"items":[{"day","start","end","name","people":[名前]}]}
  その会議の時間に入る区切りの「名前のある人かも」の近さに、出席者だけ meeting_bonus を足す（s22pc.prior_bonus につなぐ）。
  足すのは候補の近さだけ。記録の話し手は書き換えない・名前はまとめない。ファイルが無ければ何もしない。
- 知7（聞き取り側） 仕事の言葉を、職場の時間の文字起こしのヒントの先頭に（lifelog_pc.place_hints_for から）
  元: 母艦の state/vocab_for_app.json の "sure": true の言葉・state/work_for_app.json の glossary のうち、
      "for_asr": true（"asr": true でも可。M2 が聞き取りに回す印）か firm の付いたもの。
  職場の時間 = 仕事に付いた "work": true の仕事、または会議の窓に区切りの始まりが入るとき。足す数は WORK_HINTS_MAX（仮）まで。
  元のヒントの数の上限は変えない（hintpolicy.CURRENT_MAX の 40 の中。先頭に足すので、あふれるのは後ろ）。
- 知8（番号） 職場の会話の行に、読み上げた番号の候補を "numbers"（optional）で付ける。規則は s32pnumbers.py。文は変えない。
- 止める切り替え: 母艦の state/s27_work_config.json の "s32p": {"meeting": false, "hints": false, "numbers": false}（書かなければオン。どれも候補・先頭のヒントだけ）

記録（log.txt）には数だけ。名前・言葉・文は書かない。
"""

from __future__ import annotations

import datetime
import re
from pathlib import Path

import s27pwork
import s32pnumbers

MEETINGS = Path("state") / "s32_meeting_people_for_pc.json"
VOCAB = Path("state") / "vocab_for_app.json"
WORK = s27pwork.WORK
MEETING_BONUS = 0.03        # 出席者の「名前のある人かも」に足す近さ（仮。s22 の prior_bonus 0.02 より少し強い）
WORK_HINTS_MAX = 8          # 仕事の言葉をヒントの先頭に足す数（仮。people_hints の 4 の倍）
WORD_MIN, WORD_MAX = 2, 24
READ_MAX = 3 * 1024 * 1024
CHUNK_SECONDS = 300.0       # 区切りの長さ（5 分）。始まりがこの間に会議と重なれば職場の時間
HHMM = re.compile(r"(\d{1,2}):(\d{2})")


def switch(base: Path | None, name: str) -> bool:
    """state/s27_work_config.json の "s32p" の切り替え（書かなければオン）"""
    if base is None:
        return True
    data, _ = s27pwork._load(base, s27pwork.CONFIG, 64 * 1024)
    mine = data.get("s32p") if isinstance(data, dict) else None
    value = mine.get(name) if isinstance(mine, dict) else None
    return value if isinstance(value, bool) else True


# MARK: - 知9 会議の窓


def _epoch(day: str, hhmm: str) -> float | None:
    m = HHMM.fullmatch(str(hhmm or "").strip())
    if not m or not isinstance(day, str):
        return None
    try:
        d = datetime.date.fromisoformat(day)
        return datetime.datetime(d.year, d.month, d.day, int(m[1]), int(m[2])).timestamp()
    except ValueError:
        return None


def read_meetings(base: Path | None) -> list[dict]:
    """[{start, end（1970 年からの秒）, name, people:[名前]}]。無い・壊れている・止めてあるときは []"""
    if base is None or not switch(base, "meeting"):
        return []
    data, _ = s27pwork._load(base, MEETINGS, READ_MAX)
    out = []
    for x in (data or {}).get("items") or []:
        if not isinstance(x, dict):
            continue
        a, b = _epoch(x.get("day"), x.get("start")), _epoch(x.get("day"), x.get("end"))
        people = [str(p).strip() for p in x.get("people") or [] if isinstance(p, str) and str(p).strip()]
        if a is None or b is None or b <= a or not people:
            continue
        out.append({"start": a, "end": b, "name": str(x.get("name") or "")[:60], "people": people[:40]})
    return out


def people_at(meetings: list[dict], epoch: float | None) -> set[str]:
    """その時刻に開いている会議の出席者（重なる会議はすべて）"""
    if epoch is None:
        return set()
    found: set[str] = set()
    for m in meetings:
        if m["start"] <= epoch < m["end"]:
            found |= set(m["people"])
    return found


def _item_epoch(item: dict) -> float | None:
    import s22voice

    base = s22voice.audio_epoch(str(item.get("audio") or ""))
    start = item.get("start")
    if base is None:
        return None
    return base + (float(start) if isinstance(start, (int, float)) else 0.0)


def meeting_score(base: Path | None, labels: dict, bonus: float = MEETING_BONUS):
    """voices.PRIOR_BONUS と同じ形の関数 score(人物N の印, 名前のある人の印) → 足す近さ。会議が無ければ None。
    人物N の声のどれかが、その人が出席者の会議の時間に入っていれば bonus。"""
    meetings = read_meetings(base)
    if not meetings or bonus <= 0:
        return None
    name_of = {k: str(v.get("name") or "") for k, v in labels.items()}
    seen: dict[str, set[str]] = {}

    def attendees(label: str) -> set[str]:
        if label not in seen:
            found: set[str] = set()
            for item in (labels.get(label) or {}).get("items") or []:
                found |= people_at(meetings, _item_epoch(item))
            seen[label] = found
        return seen[label]

    def score(label: str, ref: str) -> float:
        target = name_of.get(ref) or ""
        return bonus if target and target in attendees(label) else 0.0

    return score


def combine(first, second):
    """2 つの近さの関数を 1 つに（大きいほう。足し合わせて強くなりすぎないように）。どちらかが None ならもう片方"""
    if first is None:
        return second
    if second is None:
        return first

    def score(label: str, ref: str) -> float:
        return max(float(first(label, ref) or 0.0), float(second(label, ref) or 0.0))

    return score


# MARK: - 知7 仕事の言葉をヒントの先頭に


def work_words(base: Path | None, limit: int = WORK_HINTS_MAX) -> list[str]:
    """聞き取りに回す仕事の言葉（M2 の印つきが先・そのなかは多く出る順。同じ言葉は 1 つ）"""
    if base is None or limit <= 0:
        return []
    rows: list[tuple[int, int, str]] = []   # (元の順位。0=M2 の印つき・1=辞書, 多さ, 言葉)
    vocab, _ = s27pwork._load(base, VOCAB, READ_MAX)
    for x in (vocab or {}).get("items") or []:
        if isinstance(x, dict) and x.get("sure") is True and isinstance(x.get("word"), str):
            rows.append((1, int(x.get("count") or 0) if isinstance(x.get("count"), (int, float)) else 0, x["word"]))
    work, _ = s27pwork._load(base, WORK, READ_MAX)
    for x in (work or {}).get("glossary") or []:
        if not isinstance(x, dict) or not isinstance(x.get("term"), str):
            continue
        if x.get("for_asr") is True or x.get("asr") is True or (x.get("firm") is True and "for_asr" not in x and "asr" not in x):
            days = x.get("days")
            rows.append((0, len(days) if isinstance(days, list) else 0, x["term"]))
    out: list[str] = []
    for _, _, word in sorted(rows, key=lambda r: (r[0], -r[1])):
        word = re.sub(r"\s+", "", word)
        if WORD_MIN <= len(word) <= WORD_MAX and word not in out:
            out.append(word)
        if len(out) >= limit:
            break
    return out


def is_work_time(base: Path | None, epoch: float | None, work_flag) -> bool:
    if work_flag is True:
        return True
    if epoch is None:
        return False
    return any(m["start"] < epoch + CHUNK_SECONDS and epoch < m["end"] for m in read_meetings(base))


def add_hints(hints: list[str], epoch: float | None, base: Path | None, work_flag=None) -> tuple[list[str], int]:
    """職場の時間のとき、仕事の言葉をヒントの先頭に。(新しいヒント, 足した数)。それ以外・止めてある・言葉が無いときは前と同じ"""
    try:
        if base is None or not switch(base, "hints") or not is_work_time(base, epoch, work_flag):
            return list(hints), 0
        fresh = [w for w in work_words(base) if w not in hints]
    except Exception:  # noqa: BLE001 — 読めなくても、ヒントは前のまま
        return list(hints), 0
    return fresh + list(hints), len(fresh)


# MARK: - 知8 番号の候補


def add_numbers(lines: list[dict], base: Path | None, epoch: float | None, work_flag=None) -> int:
    """職場の時間の行に "numbers" を足す。候補のあった行の数。文は変えない"""
    try:
        if not lines or not switch(base, "numbers") or not is_work_time(base, epoch, work_flag):
            return 0
        return s32pnumbers.annotate(lines)
    except Exception:  # noqa: BLE001
        return 0
