"""LifeLog PC: s22 確19・確27。家の PC が作る確かめ待ちと、答えを同じ声のかたまりに広げる所（2026-11-22）。0 円・言語モデルなし。

確かめ待ち（HOME/s22/review/items.json。GET /review-queue の items の後ろに s22feeds.merge_review が足す。母艦にも
inbox/pc-review/candidates.json として写す。形は母艦の review_queue_for_app.json の 1 件と同じ）:
- 確19 kind "number"（id "num-…"）: 記録の行のモデルの票で、数字・日付・金額の並びが割れた行（s22text.number_split）。
  {"question": "この行の数字はどれですか", "answer": "pick", "choices": [票の文…], "evidence": [{"text": 行の文, "ref": "日|ミリ秒"}]}
  答え（選んだ文）が今の文と違えば、その行の文を直す（edits.db の pending。iPhone が取りに来て当てる。今までの「PC から直す」と同じ）。
- 確27 kind "speaker_line"（id "spk-…"）: 名前の無い人物N で、声が名前のある人にとても近いもの（voices.json の maybe）。
  {"question": "この声は ○○ さんですか", "answer": "yesno", "spread": 広げる行の数}。
  「はい」なら、その日の同じ人物N の行のうち、声が近い（spread_cos 以上）か同じ区切りの行の話し手を ○○ にする
  （名前は記録にもう出てくる名前だけ。records.RecordStore.make_edit。新しい名前は作らない）。
答え（POST /feedback の kind review）を受けたら spread(…) が直した行の数を返し、受け口は {"ok": true, "done": {"changed": n}} を返す。
母艦 inbox/review_expanded.jsonl に {"id", "lines": n, "at"} を 1 行（母艦の Build-ReviewQueue.py が done の changed に出す）。
config.json の "review_spread": false で広げない（答えは今までどおり母艦に置くだけ）。記録（log.txt）には数だけ。
"""

from __future__ import annotations

import datetime
import hashlib
import json
import os
import re
from pathlib import Path

import numpy as np

import s22text
import s22voice
import voices

PER_DAY = 5
SPEAKER_PER_DAY = 3
EXPIRE_DAYS = 7
SPREAD_COS = 0.5
TEXT_MAX = 80
UNNAMED = re.compile(r"人物(\d+)")


def folder(home: Path) -> Path:
    return Path(home) / "s22" / "review"


def _write(path: Path, body) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    part = path.with_name(path.name + ".part")
    part.write_text(json.dumps(body, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(part, path)


def _hash(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:10]


def _expires(day: str) -> str:
    return (datetime.date.fromisoformat(day) + datetime.timedelta(days=EXPIRE_DAYS)).isoformat()


def number_items(parsed: dict, day: str, raw_lines: dict[int, dict]) -> list[dict]:
    """確19: その日の、数字が割れた行（新しい順・PER_DAY まで）"""
    out = []
    for conversation in parsed.get("conversations") or []:
        if conversation.get("media"):
            continue
        for line in conversation.get("lines") or []:
            if line.get("media") is not None or not isinstance(line.get("time"), int):
                continue
            votes = (raw_lines.get(line["time"]) or {}).get("votes") or line.get("votes")
            choices = s22text.number_split(votes)
            if not choices:
                continue
            text = str(line.get("text") or "").strip()
            if text and text not in choices:
                choices = [text] + choices
            ref = f"{day}|{line['time']}"
            out.append({"id": "num-" + _hash(ref), "kind": "number", "question": "この行の数字はどれですか",
                        "answer": "pick", "choices": choices[:4], "group": "number", "priority": 0.6,
                        "evidence": [{"text": text[:TEXT_MAX], "ref": ref}], "expires": _expires(day), "today": False})
    out.sort(key=lambda i: i["evidence"][0]["ref"], reverse=True)
    return out[:PER_DAY]


def speaker_items(home: Path, store, maybe: list[dict]) -> list[dict]:
    """確27: 名前のある人かも（voices.json の maybe）を「この声は ○○ さんですか」に。広げる行の数も付ける"""
    out = []
    names = {s["name"] for s in store.speakers()} if store is not None else set()
    for item in sorted(maybe, key=lambda m: -(m.get("score") or 0)):
        person, named = item.get("person") or {}, item.get("named") or {}
        name = str(named.get("name") or "")
        day = str(item.get("day") or "")
        samples = person.get("samples") or []
        if not name or name not in names or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", day) or not samples:
            continue
        sample = samples[0]
        moment = _ms(sample.get("time"))
        if moment is None:
            continue
        lines = cluster_lines(home, store, day, str(person.get("id") or ""), sample)
        ref = f"{day}|{moment}"
        out.append({"id": "spk-" + _hash(ref + ">" + name), "kind": "speaker_line",
                    "question": f"この声は {name} さんですか", "answer": "yesno", "group": "speaker_line",
                    "priority": 0.55, "evidence": [{"text": str(sample.get("text") or "")[:TEXT_MAX], "ref": ref}],
                    "expires": _expires(day), "today": False, "spread": len(lines), "name": name,
                    "person": f"人物{person.get('id')}"})
        if len(out) >= SPEAKER_PER_DAY:
            break
    return out


def _ms(value) -> int | None:
    if isinstance(value, int) and not isinstance(value, bool):
        return value
    try:
        moment = datetime.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    return int(moment.timestamp() * 1000)


def cluster_lines(home: Path, store, day: str, ident: str, sample: dict, cos: float = SPREAD_COS) -> list[int]:
    """その日の人物<ident> の行のうち、見本の声に近い（cos 以上）か、見本と同じ区切りにある行の時刻（ミリ秒）"""
    parsed = store.day(day) if store is not None else None
    if parsed is None or not ident:
        return []
    vectors = s22voice.day_vectors(home, day)
    every = list(vectors.values())
    mean = np.mean(np.asarray(every, dtype=np.float64), axis=0) if len(every) >= 2 else None
    anchor = vectors.get(voices.seg_key(sample.get("audio"), sample.get("start"), sample.get("end"))) \
        if isinstance(sample.get("start"), (int, float)) and isinstance(sample.get("end"), (int, float)) else None
    anchor_unit = None
    if anchor is not None and mean is not None:
        anchor_unit = s22voice._unit(np.asarray(anchor, dtype=np.float64) - mean)
    out = []
    for conversation in parsed.get("conversations") or []:
        for line in conversation.get("lines") or []:
            if line.get("speaker") != f"人物{ident}" or not isinstance(line.get("time"), int):
                continue
            if line.get("audio") == sample.get("audio"):
                out.append(line["time"])
                continue
            key = s22voice.line_key(line)
            vector = vectors.get(key) if key else None
            if vector is None or anchor_unit is None:
                continue
            unit = s22voice._unit(np.asarray(vector, dtype=np.float64) - mean)
            if unit is not None and float(unit @ anchor_unit) >= cos:
                out.append(line["time"])
    return sorted(set(out))


def build(home: Path, store, base: Path | None, days: list[str]) -> dict:
    """確かめ待ちを作り直して置く（母艦にも写す）。数を返す"""
    items = []
    for day in days:
        parsed = store.day(day) if store is not None else None
        if parsed is None:
            continue
        raw_lines = raw_votes(store, day)
        items.extend(number_items(parsed, day, raw_lines))
    try:
        maybe = (json.loads((Path(home) / "same-person" / "voices.json").read_text(encoding="utf-8")) or {}).get("maybe") or []
    except (OSError, ValueError):
        maybe = []
    items.extend(speaker_items(home, store, [m for m in maybe if isinstance(m, dict) and m.get("day") in days]))
    body = {"version": 1, "generated_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"), "items": items}
    _write(folder(home) / "items.json", body)
    if base is not None and Path(base).is_dir():
        try:
            _write(Path(base) / "inbox" / "pc-review" / "candidates.json", body)
        except OSError:
            pass
    counts: dict[str, int] = {}
    for item in items:
        counts[item["kind"]] = counts.get(item["kind"], 0) + 1
    return counts


def raw_votes(store, day: str) -> dict[int, dict]:
    """記録のファイルの行の票（parse_record は票を残すが、念のため元のファイルからも読む）"""
    out: dict[int, dict] = {}
    try:
        body = json.loads(store.path(day).read_text(encoding="utf-8"))
    except (OSError, ValueError, AttributeError):
        return out
    import records

    for conversation in body.get("conversations") or []:
        for line in conversation.get("lines") or [] if isinstance(conversation, dict) else []:
            try:
                moment = records.parse_time(line.get("time"), "time")
            except (ValueError, AttributeError):
                continue
            if isinstance(line.get("votes"), dict):
                out[moment] = {"votes": line["votes"]}
    return out


def find_item(home: Path, item_id: str) -> dict | None:
    try:
        body = json.loads((folder(home) / "items.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    for item in body.get("items") or []:
        if isinstance(item, dict) and item.get("id") == item_id:
            return item
    return None


def spread(home: Path, store, base: Path | None, row: dict, config: dict | None, log) -> dict | None:
    """答え 1 つを広げて直す。{"changed": 行の数}。家の PC の確かめ待ちでなければ None"""
    item = find_item(home, str(row.get("id") or ""))
    if item is None or store is None:
        return None
    if (config or {}).get("review_spread") is False:
        return {"changed": 0}
    answer = str(row.get("answer") or "")
    ref = str(((item.get("evidence") or [{}])[0]).get("ref") or "")
    day, _, ms = ref.partition("|")
    if not ms.isdigit():
        return {"changed": 0}
    changed = 0
    if item.get("kind") == "number":
        line, _, _ = store.find_line(day, int(ms))
        if line is not None and answer in (item.get("choices") or []) and answer != line.get("text"):
            try:
                store.make_edit(day, int(ms), "text", answer)
                changed = 1
            except ValueError:
                changed = 0
    elif item.get("kind") == "speaker_line" and answer in ("yes", "はい"):
        ident = str(item.get("person") or "").removeprefix("人物")
        parsed = store.day(day)
        sample = None
        for conversation in (parsed or {}).get("conversations") or []:
            for line in conversation.get("lines") or []:
                if line.get("time") == int(ms):
                    sample = {"audio": line.get("audio"), "start": line.get("offset"), "end": line.get("end")}
        for moment in cluster_lines(home, store, day, ident, sample or {}):
            try:
                store.make_edit(day, moment, "speaker", str(item.get("name") or ""))
                changed += 1
            except ValueError:
                continue
    if base is not None and Path(base).is_dir():
        try:
            path = Path(base) / "inbox" / "review_expanded.jsonl"
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps({"id": item["id"], "lines": changed,
                                         "at": datetime.datetime.now().astimezone().isoformat(timespec="seconds")},
                                        ensure_ascii=False) + "\n")
        except OSError:
            pass
    log(f"確かめ待ちの答え（{item.get('kind')}）を広げて直しました: {changed} 行")
    return {"changed": changed}
