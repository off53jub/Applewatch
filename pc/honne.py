"""LifeLog PC: 時計に話した独り言を、自動で「本音メモ」に分ける（s18 の 47。2026-11-19）。

1. 独り言を拾う（この PC の記録 records/<日>.json から。読むだけ）: 会話の中で
   - 自分の行が 1 つ以上・ほかの人（自分でも話し手なしでもない）の行が 0
   - 話し手なしの行が UNKNOWN_MAX（仮）以下・時計の音声（名前が -w.m4a）の行が WATCH_MIN（仮）以上
   - 文字が MIN_CHARS（仮）以上・テレビなどの会話ではない
2. 分ける（llmroute.judge。安い AI → 自信が低いものだけ高い AI。用途 "honne"・1 日の上限あり・帳簿は共有）:
   kind は "honne"（気持ち・考え・迷い・決めたこと）・"memo"（やること・思いつき・覚え書き）・
   "task"（作業の実況・読み上げ・数え）・"other"。頼めないとき（鍵が無い・上限・止め）は kind None・tier "ask"。
   頼む文に見本の文は入れない（決まりのとおり）。新しい文は書かせない（分けるだけ）。
3. 置く: HOME/knowme/honne/<日>.json（作り直すたびに置き換え。同じ会話・同じ文は二度頼まない）と
   母艦 inbox/honne/<日>.json の写し。GET /honne?days=7 で直近の分を返す（features の "honne"）。
見立ての印: 分け方は AI の見立てなので label "見立て（仮）"・layer "hypothesis"・kind "hypothesis.honne"（tier_kind）。
文は本人の言葉そのまま（400 字まで）。記録（log.txt）には数だけ書く。
"""

from __future__ import annotations

import datetime
import hashlib
from pathlib import Path
from typing import Callable

import claude
import llmroute
import voicetone

FOLDER = Path("knowme") / "honne"
MOTHER_DIR = Path("inbox") / "honne"
PURPOSE = "honne"
UNKNOWN_MAX = 0.3      # 仮: 話し手なしの行の割合の上限
WATCH_MIN = 0.5        # 仮: 時計の音声の行の割合の下限
MIN_CHARS = 12         # 仮: 独り言とみなす文字の数の下限
TEXT_MAX = 400
KINDS = ("honne", "memo", "task", "other")
SYSTEM = ("あなたは、本人が腕時計に向かって一人で話した言葉を分ける係です。"
          "次の4つのどれか1つを kind に選びます。honne: 本人の気持ち・考え・迷い・不満・決めたこと。"
          "memo: やること・思いつき・あとで使う覚え書き。task: 作業しながらの実況・読み上げ・数を数えるなど。"
          "other: どれでもない・聞き取りが崩れていて分からない。"
          "文を書き直したり要約したりはしません。confidence には選んだ kind の確からしさを 0〜1 で入れます。")
SCHEMA = {"type": "object", "properties": {"kind": {"type": "string", "enum": list(KINDS)}},
          "required": ["kind"], "additionalProperties": False}


def is_watch(name: str | None) -> bool:
    return bool(name) and name.endswith("-w.m4a")


def monologues(parsed: dict, day: str) -> list[dict]:
    out = []
    for c in parsed.get("conversations", []):
        if c.get("media"):
            continue
        lines = [l for l in c["lines"] if (l.get("text") or "").strip() and l.get("media") is None]
        if not lines:
            continue
        mine = [l for l in lines if voicetone.is_self(l)]
        others = [l for l in lines if not voicetone.is_self(l) and (l.get("speakerID") or l.get("speaker"))]
        unknown = len(lines) - len(mine) - len(others)
        watch = sum(1 for l in lines if is_watch(l.get("audio")))
        text = "".join(l["text"] for l in lines)
        if not mine or others or unknown / len(lines) > UNKNOWN_MAX or watch / len(lines) < WATCH_MIN \
                or len(voicetone.PLAIN.sub("", text)) < MIN_CHARS:
            continue
        first = lines[0]
        out.append({"id": hashlib.sha1(f"{day}|{c['start']}|{text}".encode()).hexdigest()[:12], "day": day,
                    "conversation_start": voicetone._iso(c["start"]), "line_time": voicetone._iso(first["time"]),
                    "audio": first.get("audio"), "offset": first.get("offset"), "source": "app",
                    "text": text[:TEXT_MAX], "lines": len(lines), "work": c.get("work")})
    return out


def classify(item: dict, config: dict | None, log) -> dict:
    try:
        got = llmroute.judge(PURPOSE, SYSTEM, "本人が一人で話した言葉:\n" + item["text"], SCHEMA,
                             work=bool(item.get("work")), max_tokens=400, config=config, log=log)
    except claude.ClaudeError as error:
        return {"kind": None, "confidence": None, "tier": "ask", "tier_why": "分けられなかった",
                "error": str(error.body.get("error"))[:80]}
    except ValueError as error:
        return {"kind": None, "confidence": None, "tier": "ask", "tier_why": "分けられなかった", "error": str(error)[:80]}
    data = got.get("data") if isinstance(got.get("data"), dict) else {}
    kind = data.get("kind") if data.get("kind") in KINDS else None
    conf = got.get("confidence")
    tier = "tentative" if kind and conf is not None and conf >= llmroute.REVIEW_BELOW else "ask"
    return {"kind": kind, "confidence": conf, "tier": tier,
            "tier_why": "見立ては黙って事実にしない" if tier == "tentative" else "自信が低い",
            "model": got.get("model"), "reviewed": got.get("reviewed"), "usd": got.get("usd")}


def build_day(home: Path, store, day: str, config: dict | None, log: Callable[[str], None],
              ask: bool = True, limit: int = 60) -> dict | None:
    parsed = store.day(day)
    if parsed is None:
        return None
    path = home / FOLDER / f"{day}.json"
    old = {i["id"]: i for i in (voicetone.read_json(path) or {}).get("items") or []}
    items = []
    asked = 0
    for item in monologues(parsed, day):
        prev = old.get(item["id"])
        if prev and prev.get("kind"):
            items.append(prev)
            continue
        if ask and asked < limit:
            asked += 1
            item.update(classify(item, config, log))
        else:
            item.update({"kind": None, "confidence": None, "tier": "ask", "tier_why": "まだ分けていない"})
        item.update({"layer": "hypothesis", "label": "見立て（仮）", "tier_kind": "hypothesis.honne", "made_on": day,
                     "recheck_by": (datetime.date.fromisoformat(day) + datetime.timedelta(days=90)).isoformat(),
                     "status": "alive", "evidence_kinds": ["voice"]})
        items.append(item)
    counts = {k: sum(1 for i in items if i.get("kind") == k) for k in KINDS}
    counts["unsorted"] = sum(1 for i in items if not i.get("kind"))
    built = {"version": 1, "day": day, "items": items, "counts": counts}
    voicetone._write(path, built)
    return built


def copy_to_mother(home: Path, mother: Path | None, days: list[str]) -> int:
    if mother is None or not mother.is_dir():
        return 0
    n = 0
    for day in days:
        data = voicetone.read_json(home / FOLDER / f"{day}.json")
        if data is not None and voicetone._write(mother / MOTHER_DIR / f"{day}.json", data):
            n += 1
    return n


def run(home: Path, store, mother: Path | None, config: dict | None, log: Callable[[str], None], days: list[str],
        ask: bool = True, mother_copy: bool = True) -> dict:
    made = []
    for day in days:
        try:
            built = build_day(home, store, day, config, log, ask=ask)
        except Exception as error:  # noqa: BLE001
            log(f"本音メモ: {day} を作れませんでした: {type(error).__name__}")
            continue
        if built is not None:
            made.append(built)
    copied = copy_to_mother(home, mother, days) if mother_copy else 0
    if made:
        log(f"本音メモ: 独り言 {sum(len(b['items']) for b in made)}（本音 {sum(b['counts'].get('honne', 0) for b in made)}）"
            f"・母艦へ {copied}")
    return {"days": made, "copied": copied}


def read_recent(home: Path, days: int = 7, today: datetime.date | None = None) -> dict:
    today = today or datetime.date.today()
    items = []
    for i in range(max(1, min(days, 31))):
        day = (today - datetime.timedelta(days=i)).isoformat()
        items += (voicetone.read_json(home / FOLDER / f"{day}.json") or {}).get("items") or []
    return {"available": True, "items": items}
