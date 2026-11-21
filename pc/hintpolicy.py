"""LifeLog PC: 聞き取りのヒントの渡し方を決める（強化案 99・131。2026-11-16）。

測った事実（2026-11-16。PLAUD と 5 分ごとの文字の合い方。docs/s16-pc-place-search-2026-11-16.md）:
- kotoba はヒントを渡すとほとんど書かない（ランダム 300 行で、ヒントあり 1,449 字／なし 3,800 字）。→ kotoba には**いつも渡さない**。
- whisper は、今のヒント（40 語）で haas より 24% 多く書き、合った割合は低い（0.515 対 0.631）。
  ヒントの数を変えたときの合い方は docs の表（asrmeasure.py の score）。
- 2026-11-17〜18 の夜に 4,787 行で測り直した: whisper だけの F は、渡さない 0.512・先頭 10 語 0.424・今の 40 語 0.431・
  先頭 10 語＋地名 0.414（渡すほうがどれも 95% の幅で下）。haas との多数決のあとはどれも 0.505 前後で差が無い
  （地名だけ -0.0014 と少し下）。→ whisper の既定は**渡さない**、地名は**足さない**（2026-11-18 本人の決定）。

config.json の設定（無ければ既定）:
  "whisper_hints": "current" | "none" | "top10"   whisper（と あなた向け）に渡すヒント。既定は "none"（docs §5）
  "place_hints": false                              その時間・その日の地名をヒントに足す（既定はオフ。測ったら少し下がった）
haas のヒント（hotwords）はここでは変えない（CPU のモデルで、登録した言葉を足し引きするだけ）。
"""

from __future__ import annotations

from pathlib import Path

import placehints

WHISPER_HINTS_DEFAULT = "none"        # 2026-11-18 本人の決定。測り直し（131）の結果: docs/s16-pc-place-search-2026-11-16.md §5
WHISPER_HINT_MODES = ("current", "none", "top10")
CURRENT_MAX = 40
TOP_N = 10
NO_HINT_ENGINES = ("kotoba",)         # ヒントを渡すとほとんど書かなくなる


def whisper_mode(config: dict | None) -> str:
    value = str((config or {}).get("whisper_hints") or WHISPER_HINTS_DEFAULT)
    return value if value in WHISPER_HINT_MODES else WHISPER_HINTS_DEFAULT


def engine_hints(engine_name: str, hints: list[str], config: dict | None) -> list[str]:
    """モデルごとに、渡すヒントを決める（haas は対象外。Whisper 系だけ）"""
    if engine_name in NO_HINT_ENGINES:
        return []
    mode = whisper_mode(config)
    if mode == "none":
        return []
    if mode == "top10":
        return list(hints[:TOP_N])
    return list(hints[:CURRENT_MAX])


def place_hints_on(config: dict | None) -> bool:
    return bool((config or {}).get("place_hints") is True)


def augment(hints: list[str], epoch: float | None, base: Path | None, home: Path | None,
            config: dict | None, extra: list[str] | None = None) -> tuple[list[str], int]:
    """ヒントの先頭に地名を足す（先頭ほど効く）。(新しいヒント, 足した数)。オフ・地名なし・時刻なしは前と同じ"""
    if not place_hints_on(config) or base is None or epoch is None:
        return list(hints), 0
    try:
        words = placehints.words_at(base, epoch, home=home, extra=extra)
    except Exception:  # noqa: BLE001 — 地名が読めなくても、ヒントは前のまま
        return list(hints), 0
    fresh = [w for w in words if w not in hints]
    return fresh + list(hints), len(fresh)


def epoch_of(name: str) -> float | None:
    """区切りの名前の頭（YYYYMMDD-HHMMSS。この PC の時刻）の 1970 年からの秒"""
    import datetime
    import re

    m = re.match(r"^(\d{8})-(\d{6})", name or "")
    if not m:
        return None
    try:
        return datetime.datetime.strptime(m[1] + m[2], "%Y%m%d%H%M%S").timestamp()
    except ValueError:
        return None


# MARK: - s21 精12: その日に会う人の名前（2026-11-22。既定はオフ）
#
# 確かめたこと（2026-11-22）: その日の予定の場所・いた所・よく行く所は、すでに place_hints（上の augment。placehints.words_at が
# archive/calendar の「場所:」も読む）で足せる。ただし 2026-11-18 に測ったら少し下がったので、本人の決定で既定はオフのまま。
# 足りなかったのは「会う人の名前」だけなので、同じ決まり（既定はオフ・config.json で入れたときだけ）で足す口を作った:
#   "people_hints": true   その日の予定（archive/calendar/YYYY/MM/DD.md）に名前が出てくる人（state/people-index.md の表の
#                          いちばん左の名前。読むだけ）を、ヒントの先頭に PEOPLE_MAX 人まで足す。
# 人の名前は記録（log.txt）に書かない（数だけ）。

PEOPLE_MAX = 4


def people_hints_on(config: dict | None) -> bool:
    return bool((config or {}).get("people_hints") is True)


def people_names(base: Path) -> list[str]:
    """people-index.md の表のいちばん左の名前（見出しの行・「自分」の行は除く。「名前（よみ）」は名前だけ）"""
    import re

    try:
        lines = (Path(base) / "state" / "people-index.md").read_text(encoding="utf-8-sig").splitlines()
    except OSError:
        return []
    names: list[str] = []
    for i, line in enumerate(lines):
        if not line.startswith("|") or line.startswith("|---") or line.startswith("| ---"):
            continue
        if i + 1 < len(lines) and lines[i + 1].replace(" ", "").startswith("|---"):
            continue  # 見出しの行
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        head = re.split(r"[（(\[]", cells[0])[0].strip() if cells else ""
        if len(head) >= 2 and head not in names and "me" not in (cells[1] if len(cells) > 1 else "") \
                and head not in ("自分", "本人", "-"):
            names.append(head)
    return names


def people_on(base: Path, day: str, limit: int = PEOPLE_MAX) -> list[str]:
    """その日の予定に名前が出てくる人（予定に出てくる順）"""
    try:
        text = (Path(base) / "archive" / "calendar" / day[:4] / day[5:7] / f"{day[8:10]}.md").read_text(encoding="utf-8-sig")
    except OSError:
        return []
    found = sorted(((text.find(name), name) for name in people_names(base) if name in text), key=lambda x: x[0])
    return [name for _, name in found][:limit]


def add_people(hints: list[str], epoch: float | None, base: Path | None, config: dict | None) -> tuple[list[str], int]:
    """"people_hints": true のときだけ、その日に会う人の名前をヒントの先頭に足す。(新しいヒント, 足した数)"""
    if not people_hints_on(config) or base is None or epoch is None:
        return list(hints), 0
    import datetime

    try:
        names = people_on(base, datetime.datetime.fromtimestamp(epoch).strftime("%Y-%m-%d"))
    except Exception:  # noqa: BLE001 — 読めなくても、ヒントは前のまま
        return list(hints), 0
    fresh = [n for n in names if n not in hints]
    return fresh + list(hints), len(fresh)
