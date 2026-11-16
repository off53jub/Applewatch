"""LifeLog PC: 「迷った所だけ」Whisper に回す（強化案 132。2026-11-16）。

今は全部の区切りの全部の区間を Whisper（GPU）にかけて、haas と多数決している。測ると、多数決は haas だけとほぼ同じ点
（PLAUD との文字の合い方 0.494 対 0.496）なので、haas が迷った区間だけ Whisper に回しても点が落ちないかもしれない。
ここは「迷った」の決まりだけ（Whisper にかけるかどうか）。使うかどうかは config.json の "whisper_scope":
  "all"（既定。今と同じ）／"doubt"（迷った区間だけ）。数と点は docs/s16-pc-place-search-2026-11-16.md。

迷った（doubtful）区間:
  - 速いモデル（haas・reazon）が何も書かなかった（区間が MIN_SECONDS 以上のとき）
  - 速いモデルが 2 つ以上あって、書いた文の近さ（vote と同じ similarity）が AGREE 未満
  - 1 秒あたりの文字数が少なすぎる（SPARSE_CPS 未満・区間が SPARSE_SECONDS 以上）= 声を取りこぼした疑い
  - 速いモデルの文が JUNK_REPEAT 回以上同じ字の繰り返し
"""

from __future__ import annotations

import re
from typing import Callable

FAST_ENGINES = ("haas", "reazon")
SLOW_ENGINES = ("whisper",)
MIN_SECONDS = 1.0
AGREE = 0.75
SPARSE_CPS = 1.2
SPARSE_SECONDS = 2.5
JUNK_REPEAT = 6
REPEAT = re.compile(r"(.)\1{%d,}" % (JUNK_REPEAT - 1))


def scope(config: dict | None) -> str:
    return "doubt" if str((config or {}).get("whisper_scope") or "all") == "doubt" else "all"


def doubtful(texts: dict[str, str], seconds: float, similarity: Callable[[str, str], float],
             agree: float = AGREE, sparse_cps: float = SPARSE_CPS) -> str | None:
    """迷った理由（"disagree"・"sparse"・"repeat"）。迷っていなければ None。texts は速いモデルの文だけ"""
    heard = {k: (v or "").strip() for k, v in texts.items() if k in FAST_ENGINES}
    spoken = [v for v in heard.values() if v]
    if not heard or not spoken:
        return None
    if any(REPEAT.search(v) for v in spoken):
        return "repeat"
    if len(spoken) >= 2:
        names = [k for k, v in heard.items() if v]
        for i, a in enumerate(names):
            for b in names[i + 1:]:
                if similarity(heard[a], heard[b]) < agree:
                    return "disagree"
    if len(spoken) < len(heard) and seconds >= MIN_SECONDS:
        return "disagree"            # 片方だけ書いた
    if seconds >= SPARSE_SECONDS and max(len(v) for v in spoken) / seconds < sparse_cps:
        return "sparse"
    return None
