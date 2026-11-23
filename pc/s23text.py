"""LifeLog PC: s23 続8（2026-11-23）。summary.md の生の英語のエラーと読みにくい数を、日本語の 1 行と人の読む数にする。

楽4（アプリの S22ErrorText）・見5（アプリの LLNumber）と同じ決まりの、家の PC の分。0 円・言語モデルなし。どれも純粋な関数。
- friendly_error(文): 生の英語のエラー（TLS・つながらない・時間切れ・Google の 429 の JSON・401・5xx・cancelled など）を
  日本語の 1 行に。知らない英語は「英語のエラー（くわしくは元のファイル）」と頭の 40 字だけ。日本語の文はそのまま。
- readable_numbers(文): 「12792 分」→「約 8.9 日」・「1536 秒」→「約 26 分」・「0.0 秒」→「0 秒」・10000 以上の数に桁区切り。
  日付・時刻・版の番号・ファイルの大きさ（MB）には触らない（「分」「秒」「個」「行」「回」「件」のすぐ前の数だけ）。
- english_date(文): 「Nov 22, 2026 at 3:32」→「11/22 3:32」
- tidy(文, 上限): 上の 3 つ＋改行をつぶして 1 行にし、上限で切る（diag.py が自己点検の行・落ちた理由に使う）
元の文は diag の latest.json と日ごとの .jsonl にそのまま残る（ここで変えるのは summary.md に書く文だけ）。
"""

from __future__ import annotations

import re

MONTHS = {m: i + 1 for i, m in enumerate(("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"))}
ENGLISH_DATE = re.compile(r"\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.? (\d{1,2}), (\d{4})(?: at (\d{1,2}):(\d{2})(?::\d{2})?"
                          r"(?:\s?([AP]M))?)?")
# 英語のエラーの型 → 日本語の 1 行（上から順に見る。最初に合ったもの）
ERRORS: tuple[tuple[re.Pattern, str], ...] = tuple((re.compile(p, re.I), t) for p, t in (
    (r"\b429\b|quota exceeded|rate.?limit|too many requests", "使える回数の上限に当たりました（少し待つと戻ります）"),
    (r"\b401\b|unauthori[sz]ed|invalid.?(api.?)?key|authentication", "鍵か合言葉が通りませんでした（入れ直しが要るかも）"),
    (r"\b403\b|forbidden|permission denied", "使う許しがありませんでした"),
    (r"\b404\b|not found", "相手の所に見つかりませんでした"),
    (r"\b5\d\d\b|internal server error|bad gateway|service unavailable", "相手のサーバーの調子が悪いようです（あとでやり直します）"),
    (r"\bTLS\b|\bSSL\b|certificate|secure connection", "安全なつなぎ方（TLS）でつまずきました（通信が不安定だったかも）"),
    (r"timed? ?out|timeout|deadline exceeded", "時間切れになりました（通信が遅かったかも）"),
    (r"network connection was lost|connection (was )?(reset|refused|aborted|closed)|connection error|could not connect|"
     r"not connected to the internet|offline|unreachable|name resolution|getaddrinfo|dns", "通信がつながりませんでした"),
    (r"^\s*cancell?ed\s*\.?\s*$|\bcancell?ed\b", "途中で取りやめになりました（アプリが閉じたなど）"),
    (r"no space left|disk full|quota.*storage", "置き場所がいっぱいでした"),
    (r"out of memory|memoryerror|cannot allocate", "メモリーが足りませんでした"),
    (r"permission|access is denied", "ファイルに書く許しがありませんでした"),
    (r"json|decod|parse|unexpected (token|character)|invalid (data|format)", "返ってきた中身が読めませんでした"),
))
ASCII_RUN = re.compile(r"[A-Za-z][A-Za-z0-9 ,.'\"_:/()\-{}\[\]=@#%&?!+*;<>|\\]{14,}")
SHORT_TAIL = re.compile(r"(?<=[:：] )[A-Za-z][A-Za-z .]{1,14}$")   # 「…: cancelled」のような短い英語の終わり
UNIT_NUMBER =re.compile(r"(?<![\d.:/\-])(\d+(?:\.\d+)?)\s?(分|秒)(?!\d)")
BIG_NUMBER = re.compile(r"(?<![\d.,:/\-A-Za-z_])(\d{5,})(?=\s?(個|行|回|件|字|人|組|分|秒|KB|kb)(?!\w))")


def english_date(text: str) -> str:
    """「Nov 22, 2026 at 3:32」→「11/22 3:32」（午後の PM は 24 時間に）"""
    def fix(match: re.Match) -> str:
        month, day = MONTHS[match.group(1)[:3]], int(match.group(2))
        if match.group(4) is None:
            return f"{month}/{day:02d}"
        hour = int(match.group(4))
        if match.group(6) == "PM" and hour < 12:
            hour += 12
        elif match.group(6) == "AM" and hour == 12:
            hour = 0
        return f"{month}/{day:02d} {hour}:{match.group(5)}"
    return ENGLISH_DATE.sub(fix, text)


def readable_duration(value: float, unit: str) -> str:
    """数と単位（分・秒）→ 人の読む長さ（「約 9 日」「約 26 分」「0 秒」）"""
    seconds = float(value) * (60 if unit == "分" else 1)
    if seconds < 0.05:
        return "0 秒"
    if unit == "秒" and seconds < 120:
        return f"{value} 秒"
    if unit == "分" and seconds < 120 * 60:
        return f"{value} 分"
    if seconds < 2 * 3600:
        return f"約 {round(seconds / 60):,} 分"
    if seconds < 2 * 86400:
        return f"約 {seconds / 3600:.1f} 時間"
    return f"約 {seconds / 86400:.1f} 日"


def readable_numbers(text: str) -> str:
    """「12792 分」→「約 8.9 日」・「1536 秒」→「約 26 分」・「0.0 秒」→「0 秒」・大きな数（個・行・回など）に桁区切り"""
    text = UNIT_NUMBER.sub(lambda m: readable_duration(float(m.group(1)) if "." in m.group(1) else int(m.group(1)), m.group(2)), text)
    return BIG_NUMBER.sub(lambda m: f"{int(m.group(1)):,}", text)


def has_english(text: str) -> bool:
    return bool(ASCII_RUN.search(text or ""))


def friendly_error(text: str) -> str:
    """生の英語のエラーを日本語の 1 行に。日本語の頭（「ドキュメントに書けませんでした:」など）は残し、英語の所だけ替える"""
    text = " ".join(str(text or "").split())
    match = ASCII_RUN.search(text) or SHORT_TAIL.search(text)
    if not match:
        return text
    head, english = text[:match.start()].rstrip(" {[(\"'"), text[match.start():]
    for pattern, said in ERRORS:
        if pattern.search(english):
            plain = said
            break
    else:
        plain = "英語のエラー（くわしくは diag の元のファイル）: " + english[:40].rstrip() + ("…" if len(english) > 40 else "")
    if head.endswith((":", "：")):
        return f"{head} {plain}"
    return f"{head}（{plain}）" if head else plain


def tidy(value, limit: int = 160, errors: bool = True) -> str:
    """summary.md の 1 行にする（改行をつぶす・英語のエラー・英語の日付・読みにくい数）。上限で切る。
    errors=False なら英語のエラーの言い換えはしない（落ちた理由の EXC_BAD_ACCESS など、元の言葉が手がかりのもの）"""
    text = english_date(" ".join(str(value if value is not None else "—").split()))
    text = readable_numbers(friendly_error(text) if errors else text)
    return text if len(text) <= limit else text[:limit] + "…"
