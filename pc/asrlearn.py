"""LifeLog PC: 本人が直した言葉を、聞き取りの後で直す辞書に自動で足す（s18 の 72。2026-11-19）。

聞き取りの最中に whisper へヒントを渡すのは、測ったうえでやめた（hintpolicy.py の既定は "none"）。ここは**聞き取りの後**だけ。

1. 本人の直しを集める（読むだけ）:
   - この PC の記録 records/<日>.json の行の history で、by が「手で直した」「PC で直した」のもの（直す前 from → 直した後）
   - edits.db の文の直し（PC の画面で本人が直したもの。base_text → text）
   ここ（asrlearn）が自分で当てた直しは、HOME/knowme/asr-applied.json に控え、集めるときに外す（自分の直しで辞書を育てない）。
   「言語モデルの直し」「夜の聞き直し」「登録した書き方」など、機械の直しは入れない。
2. 直す前と後を文字で比べ（difflib）、入れ替わった所（2〜12 文字。1 文字の入れ替えは、となりの同じ文字を足して 2 文字に）を「聞き違い → 正しい書き方」の組にする。
   数字・句読点・空白だけの違い、片方が空（足した・消しただけ）、正しい方が聞き違いを含む組（当てると増え続ける）は入れない。
3. 組ごとに: corrected（本人が直した回数）・remaining（直近 SCAN_DAYS 日の記録に、まだ聞き違いの方が残っている行の数）・
   precision ＝ corrected ÷（corrected ＋ remaining）。段（母艦 M3 の tier と同じ語）:
   auto ＝ corrected ≥ AUTO_MIN かつ precision ≥ AUTO_PRECISION（仮） … 新しい行に黙って当てる
   tentative ＝ precision ≥ TENTATIVE_PRECISION（仮） … 当てずに「聞いて直す」の並びに理由 "dict" で出す
   ask ＝ それ以外（日常語で、直さなかった行の方が多い）… 何もしない（辞書には残す）
4. 置き場所: HOME/knowme/asr-learned.json（作り直すたびに置き換え）と、母艦 inbox/asr-learned/asr_learned_pairs.json の写し
   （母艦の misheard_pairs.json・asr_corrections.log・Apply-AsrDictionary.py・vocabulary.md の隣に置く「本人の直しから来た組」。
   母艦の側でどう使うかは docs/_incoming/s18-P.md）。
5. 当てる（auto だけ・config.json の "asr_learned_apply": false で止める）: 直近 APPLY_DAYS 日の、まだ本人が直していない行・
   テレビなどでない行に、今までの「PC から直す」と同じ edits（pending）を作る。iPhone が取りに来て当てる。
   当てた行は asr-applied.json に控え、同じ行に二度当てない。
記録（log.txt）には数だけ書く（言葉は書かない）。
"""

from __future__ import annotations

import datetime
import difflib
import json
import re
import sqlite3
import unicodedata
from pathlib import Path
from typing import Callable

import records

OUT = Path("knowme") / "asr-learned.json"
APPLIED = Path("knowme") / "asr-applied.json"
MOTHER_FILE = Path("inbox") / "asr-learned" / "asr_learned_pairs.json"
HUMAN_BY = ("手で直した", "PC で直した")
SPAN_MIN, SPAN_MAX = 2, 12
AUTO_MIN = 3              # 仮: 黙って当てるのに要る本人の直しの回数
AUTO_PRECISION = 0.9      # 仮
TENTATIVE_PRECISION = 0.5 # 仮
SCAN_DAYS = 30
APPLY_DAYS = 2
ONLY_TRIVIAL = re.compile(r"^[\s\d０-９、。，．,.!！?？・ー\-〜~「」『』（）()]*$")


def _norm(text: str) -> str:
    return unicodedata.normalize("NFKC", text or "")


def pairs_from(before: str, after: str) -> list[tuple[str, str]]:
    """直す前と後から、入れ替わった所の組"""
    a, b = _norm(before), _norm(after)
    out = []
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
        if op != "replace":
            continue
        if ONLY_TRIVIAL.match(a[i1:i2]) or ONLY_TRIVIAL.match(b[j1:j2]):
            continue
        # 1 文字だけの入れ替え（講→口）は、となりの同じ文字を足して 2 文字以上にする（講座→口座）。1 文字のままは広く当たりすぎる
        while min(i2 - i1, j2 - j1) < SPAN_MIN:
            if i2 < len(a) and j2 < len(b) and a[i2] == b[j2] and not ONLY_TRIVIAL.match(a[i2]):
                i2, j2 = i2 + 1, j2 + 1
            elif i1 > 0 and j1 > 0 and a[i1 - 1] == b[j1 - 1] and not ONLY_TRIVIAL.match(a[i1 - 1]):
                i1, j1 = i1 - 1, j1 - 1
            else:
                break
        wrong, right = a[i1:i2].strip(), b[j1:j2].strip()
        if not wrong or not right or wrong in right:
            continue
        if not (SPAN_MIN <= min(len(wrong), len(right)) and len(wrong) <= SPAN_MAX and len(right) <= SPAN_MAX):
            continue
        if ONLY_TRIVIAL.match(wrong) or ONLY_TRIVIAL.match(right):
            continue
        out.append((wrong, right))
    return out


def read_applied(home: Path) -> dict:
    try:
        data = json.loads((home / APPLIED).read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def human_edits(home: Path, days: list[str]) -> list[dict]:
    """[{"day", "time", "before", "after", "source"}]（本人の直しだけ）"""
    applied = read_applied(home).get("lines") or {}
    out = []
    for day in days:
        try:
            data = json.loads((home / "records" / f"{day}.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        for c in data.get("conversations") or []:
            for line in c.get("lines") or []:
                history = line.get("history") if isinstance(line.get("history"), list) else []
                try:
                    moment = records.parse_time(line.get("time"), "time")
                except ValueError:
                    continue
                if not history or f"{day}|{moment}" in applied:
                    continue
                texts = [h.get("from") for h in history] + [line.get("text")]
                for i, h in enumerate(history):
                    if isinstance(h, dict) and h.get("by") in HUMAN_BY and isinstance(texts[i], str) \
                            and isinstance(texts[i + 1], str):
                        out.append({"day": day, "time": records.iso_ms(moment), "before": texts[i], "after": texts[i + 1],
                                    "source": "history"})
    try:
        with sqlite3.connect(home / "edits.db") as db:
            rows = db.execute("SELECT id, day, time, base_text, text FROM edits WHERE kind='text' AND text IS NOT NULL "
                              "AND status IN ('applied','pending')").fetchall()
    except sqlite3.Error:
        rows = []
    mine = set((read_applied(home).get("edits") or []))
    seen = {(e["before"], e["after"]) for e in out}
    for ident, day, moment, base, text in rows:
        if ident in mine or (base, text) in seen:
            continue
        out.append({"day": day, "time": records.iso_ms(moment), "before": base, "after": text, "source": "pc"})
    return out


def corpus(store, days: list[str]) -> list[str]:
    texts = []
    for day in days:
        parsed = store.day(day)
        for c in (parsed or {}).get("conversations", []):
            texts += [_norm(l["text"]) for l in c["lines"] if l.get("text")]
    return texts


def build(home: Path, store, today: datetime.date | None = None) -> dict:
    today = today or datetime.date.today()
    days = [(today - datetime.timedelta(days=i)).isoformat() for i in range(SCAN_DAYS)]
    found: dict[tuple[str, str], dict] = {}
    for edit in human_edits(home, days):
        for wrong, right in pairs_from(edit["before"], edit["after"]):
            item = found.setdefault((wrong, right), {"wrong": wrong, "right": right, "corrected": 0, "evidence": []})
            item["corrected"] += 1
            if len(item["evidence"]) < 5:
                item["evidence"].append({"day": edit["day"], "line_time": edit["time"], "source": "app"})
    texts = corpus(store, days)
    items = []
    for item in found.values():
        remaining = sum(1 for t in texts if item["wrong"] in t)
        precision = item["corrected"] / (item["corrected"] + remaining)
        if item["corrected"] >= AUTO_MIN and precision >= AUTO_PRECISION:
            tier, why = "auto", "本人が何度も直し、残りも少ない"
        elif precision >= TENTATIVE_PRECISION:
            tier, why = "tentative", "本人の直しがまだ少ない"
        else:
            tier, why = "ask", "直さなかった行の方が多い（日常語かも）"
        items.append({**item, "remaining": remaining, "precision": round(precision, 3), "confidence": round(precision, 3),
                      "tier": tier, "tier_why": why, "kind": "text", "evidence_kinds": ["user"], "layer": "fact"})
    items.sort(key=lambda i: (-i["corrected"], -i["precision"], i["wrong"]))
    out = {"version": 1, "made_on": today.isoformat(), "scan_days": SCAN_DAYS, "items": items,
           "thresholds": {"auto_min": AUTO_MIN, "auto_precision": AUTO_PRECISION,
                          "tentative_precision": TENTATIVE_PRECISION, "仮": True}}
    path = home / OUT
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(out, ensure_ascii=False, indent=1), encoding="utf-8")
    return out


def tentative_doubts(home: Path, parsed: dict) -> dict[int, list[str]]:
    """「聞いて直す」に足す理由（tentative の組の聞き違いを含む行）。{行の時刻: ["dict"]}"""
    try:
        items = json.loads((home / OUT).read_text(encoding="utf-8")).get("items") or []
    except (OSError, ValueError):
        return {}
    wrongs = [i["wrong"] for i in items if i.get("tier") == "tentative"]
    if not wrongs:
        return {}
    out: dict[int, list[str]] = {}
    for c in parsed.get("conversations", []):
        for line in c["lines"]:
            text = _norm(line.get("text") or "")
            if any(w in text for w in wrongs):
                out[line["time"]] = ["dict"]
    return out


def apply_auto(home: Path, store, built: dict, today: datetime.date | None = None) -> int:
    today = today or datetime.date.today()
    pairs = [(i["wrong"], i["right"]) for i in built.get("items") or [] if i.get("tier") == "auto"]
    if not pairs:
        return 0
    applied = read_applied(home)
    lines_done = applied.setdefault("lines", {})
    edits_done = applied.setdefault("edits", [])
    made = 0
    for i in range(APPLY_DAYS):
        day = (today - datetime.timedelta(days=i)).isoformat()
        parsed = store.day(day)
        if parsed is None:
            continue
        human = store.edits.edited_lines()
        for c in parsed["conversations"]:
            if c.get("media"):
                continue
            for line in c["lines"]:
                key = f"{day}|{line['time']}"
                if key in lines_done or line.get("checked") or line.get("media") is not None \
                        or (day, line["time"]) in human:
                    continue
                text = line["text"]     # 元の書き方のまま（全角・半角をそろえ直さない）
                new = text
                for wrong, right in pairs:
                    new = new.replace(wrong, right)
                if new == text:
                    continue
                try:
                    got = store.make_edit(day, line["time"], "text", new)
                except ValueError:
                    continue
                lines_done[key] = 1
                if (got.get("edit") or {}).get("id") is not None:
                    edits_done.append(got["edit"]["id"])
                made += 1
    (home / APPLIED).parent.mkdir(parents=True, exist_ok=True)
    (home / APPLIED).write_text(json.dumps(applied, ensure_ascii=False), encoding="utf-8")
    return made


def copy_to_mother(home: Path, mother: Path | None) -> bool:
    if mother is None or not mother.is_dir():
        return False
    try:
        text = (home / OUT).read_text(encoding="utf-8")
    except OSError:
        return False
    dest = mother / MOTHER_FILE
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(text, encoding="utf-8")
    return True


def run(home: Path, store, mother: Path | None, config: dict, log: Callable[[str], None], mother_copy: bool = True) -> dict:
    built = build(home, store)
    made = apply_auto(home, store, built) if config.get("asr_learned_apply", True) is not False else 0
    copied = copy_to_mother(home, mother) if mother_copy else False
    tiers = {t: sum(1 for i in built["items"] if i["tier"] == t) for t in ("auto", "tentative", "ask")}
    log(f"聞き取りの後の辞書: 組 {len(built['items'])}（黙って {tiers['auto']}・仮 {tiers['tentative']}・聞く {tiers['ask']}）"
        f"・当てた行 {made}・母艦へ {'写した' if copied else '-'}")
    return {"built": built, "applied": made, "copied": copied}
