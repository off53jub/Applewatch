"""LifeLog PC: 本人が ○ を付けた会話から、よく会う人の声の見本の候補を自動で増やす（s18 の 70。2026-11-19）。

○ の出どころ（どれも本人の操作。機械の判定は ○ にしない）:
- 「聞いて直す」で「合っている」と答えた行（edits.db の reviews の ok）
- 本人が話し手を直した行（edits.db の speaker の直し。直した後の話し手）
- 会話ごとの ○（POST /conversation-ok {"day", "conversation_start", "verdict": "ok"|"ng"}。アプリの ○ の受け口。
  形は仮。HOME/knowme/conversation-ok.jsonl に 1 行ずつ。ng の会話は使わない）
よく会う人: 名前のある人（自分・人物N を除く）で、直近 FREQ_DAYS 日に FREQ_MIN（仮）以上の会話に出た人。
見本の候補: ○ の行（○ の会話ではその人の全部の行）のうち、長さ SAMPLE_MIN〜SAMPLE_MAX 秒（仮）・騒がしくない・
テレビなどでない・周りの音が無い・前後の行と重ならない・信用が低くない会話（voicetone の trust）・音声がまだ PC にあるもの。
声の特徴が置いてあれば（voices/<日>.npz。新しくは測らない）、その人の候補の真ん中から遠い（SIMILAR_MIN 未満・仮）ものは外す。
1 人 PER_PERSON 個まで（iPhone は 1 人の見本を 3 つまで持つ）。

- 名前をまとめる・付け替える・新しい名前を作ることはしない。○ の行の話し手（もう付いている名前）の見本を足す候補を出すだけ。
  足すのはアプリ（A）: GET /voice-samples の候補を本人の端末で、その人（speakerID）の声の見本として足す。
- GET /voice-samples → {"available", "made_on", "people": [{"speaker", "speakerID", "conversations", "samples": [
    {"day", "line_time", "conversation_start", "audio", "offset", "length", "path", "why", "similarity"}]}]}
  path は GET /audio-clip（audioclip.py）の形。
- 置き場所: HOME/knowme/voice-samples.json（作り直すたびに置き換え）。記録（log.txt）には数だけ。
"""

from __future__ import annotations

import datetime
import json
import sqlite3
from pathlib import Path
from typing import Callable

import numpy as np

import records
import voices
import voicetone

OUT = Path("knowme") / "voice-samples.json"
OK_FILE = Path("knowme") / "conversation-ok.jsonl"
POSTS = ("/conversation-ok",)
FREQ_DAYS = 14
FREQ_MIN = 3             # 仮: よく会う人とみなす会話の数
SAMPLE_MIN, SAMPLE_MAX = 2.0, 10.0   # 仮: 見本にする行の長さ（秒）
SIMILAR_MIN = 0.5        # 仮: その人の候補の真ん中との近さ（cos）がこれ未満なら外す
PER_PERSON = 3
SCAN_DAYS = 14


def ok_lines(home: Path) -> dict[tuple[str, int], tuple[str, str | None]]:
    """(日, 行の時刻) → (出どころ "ok"・"speaker_edit", 話し手の直しなら直した後の名前)"""
    out: dict[tuple[str, int], tuple[str, str | None]] = {}
    try:
        with sqlite3.connect(home / "edits.db") as db:
            for day, moment in db.execute("SELECT day, time FROM reviews WHERE answer='ok'"):
                out[(day, int(moment))] = ("ok", None)
            # 話し手の直しは、iPhone が当てて記録がその名前になった行だけ（当てる前の記録の名前を ○ にしない）
            for day, moment, speaker in db.execute(
                    "SELECT day, time, speaker FROM edits WHERE kind='speaker' AND status='applied' ORDER BY id"):
                out[(day, int(moment))] = ("speaker_edit", speaker)
    except sqlite3.Error:
        pass
    return out


def ok_conversations(home: Path) -> tuple[set[tuple[str, int]], set[tuple[str, int]]]:
    """(○ の会話, × の会話)。あとの答えが前の答えに勝つ"""
    latest: dict[tuple[str, int], str] = {}
    try:
        for raw in (home / OK_FILE).read_text(encoding="utf-8").splitlines():
            try:
                row = json.loads(raw)
                key = (row["day"], records.parse_time(row["conversation_start"], "conversation_start"))
            except (ValueError, KeyError, TypeError):
                continue
            if row.get("verdict") in ("ok", "ng"):
                latest[key] = row["verdict"]
    except OSError:
        pass
    return {k for k, v in latest.items() if v == "ok"}, {k for k, v in latest.items() if v == "ng"}


def _clean(line: dict, before: dict | None, after: dict | None) -> bool:
    dur = (line.get("end") or 0) - (line.get("offset") or 0) if line.get("offset") is not None else 0
    if not SAMPLE_MIN <= dur <= SAMPLE_MAX or line.get("noisy") or line.get("media") is not None or line.get("sound"):
        return False
    start = line["time"]
    if before is not None and before.get("end") is not None and before.get("offset") is not None \
            and before["time"] + (before["end"] - before["offset"]) * 1000 > start:
        return False
    if after is not None and after["time"] < start + dur * 1000:
        return False
    return True


def build(home: Path, store, today: datetime.date | None = None) -> dict:
    today = today or datetime.date.today()
    days = [(today - datetime.timedelta(days=i)).isoformat() for i in range(max(SCAN_DAYS, FREQ_DAYS))]
    lines_ok = ok_lines(home)
    convs_ok, convs_ng = ok_conversations(home)
    seen: dict[str, set] = {}
    cands: dict[str, list[dict]] = {}
    ids: dict[str, str] = {}
    for day in days:
        parsed = store.day(day)
        if parsed is None:
            continue
        tone = {c.get("start_ms"): c for c in (voicetone.read_json(home / voicetone.FOLDER / f"{day}.json") or {})
                .get("conversations") or []}
        ds = voices.DayStore(home, day).load()
        names = parsed.get("audio_names") or {}
        for c in parsed["conversations"]:
            for name in voicetone.partner_names(c):
                seen.setdefault(name, set()).add((day, c["start"]))
            ckey = (day, c["start"])
            if c.get("media") or ckey in convs_ng or (tone.get(c["start"]) or {}).get("trust") == "low":
                continue
            lines = c["lines"]
            for i, line in enumerate(lines):
                name = line.get("speaker")
                if not name or voicetone.is_self(line) or records.UNNAMED.fullmatch(name) or not line.get("speakerID"):
                    continue
                why, expect = lines_ok.get((day, line["time"])) or (("conversation_ok" if ckey in convs_ok else None), None)
                if expect is not None and expect != name:
                    continue
                if why is None or not _clean(line, lines[i - 1] if i else None, lines[i + 1] if i + 1 < len(lines) else None):
                    continue
                job = names.get(line["audio"], line["audio"]) if line.get("audio") else None
                if not job or store.audio_file(job) is None:
                    continue
                ids[name] = line["speakerID"]
                length = round(line["end"] - line["offset"], 2)
                vec = ds.vectors.get(voices.seg_key(line["audio"], line["offset"], line["end"]))
                cands.setdefault(name, []).append({
                    "day": day, "line_time": voicetone._iso(line["time"]), "conversation_start": voicetone._iso(c["start"]),
                    "audio": job, "offset": round(line["offset"], 2), "length": length,
                    "path": f"/audio-clip?audio={job}&offset={line['offset']:.2f}&length={length:.2f}", "why": why,
                    "_vec": vec})
    people = []
    recent = {(today - datetime.timedelta(days=i)).isoformat() for i in range(FREQ_DAYS)}
    for name, items in sorted(cands.items()):
        count = len({k for k in seen.get(name, set()) if k[0] in recent})
        if count < FREQ_MIN:
            continue
        vecs = [voices._unit(np.asarray(i["_vec"], dtype=np.float32)) for i in items if i["_vec"] is not None]
        vecs = [v for v in vecs if v is not None]
        center = voices._unit(np.mean(vecs, axis=0)) if len(vecs) >= 2 else None
        kept = []
        for item in items:
            sim = None
            if center is not None and item["_vec"] is not None:
                unit = voices._unit(np.asarray(item["_vec"], dtype=np.float32))
                sim = round(float(unit @ center), 3) if unit is not None else None
            item.pop("_vec")
            item["similarity"] = sim
            if sim is not None and sim < SIMILAR_MIN:
                continue
            kept.append(item)
        kept.sort(key=lambda i: (i["similarity"] is None, -(i["similarity"] or 0), -i["length"]))
        if kept:
            people.append({"speaker": name, "speakerID": ids[name], "conversations": count,
                           "samples": kept[:PER_PERSON], "candidates": len(kept),
                           "tier": "tentative", "tier_why": "本人の ○ から。足すのは本人の端末", "evidence_kinds": ["user", "voice"]})
    out = {"version": 1, "made_on": today.isoformat(), "people": people,
           "ok_lines": len(lines_ok), "ok_conversations": len(convs_ok),
           "thresholds": {"freq_min": FREQ_MIN, "sample_min": SAMPLE_MIN, "sample_max": SAMPLE_MAX,
                          "similar_min": SIMILAR_MIN, "仮": True}}
    voicetone._write(home / OUT, out)
    return out


def read(home: Path) -> dict:
    data = voicetone.read_json(home / OUT)
    return {"available": True, **data} if data else {"available": False}


def http_post(handler, home: Path, log: Callable[[str], None]) -> None:
    """POST /conversation-ok {"day", "conversation_start", "verdict": "ok"|"ng"}"""
    length = int(handler.headers.get("Content-Length") or 0)
    if length <= 0 or length > 4096:
        handler.send_json(400, {"error": "中身の大きさが正しくありません"})
        return
    try:
        body = json.loads(handler.rfile.read(length).decode("utf-8"))
        day, start, verdict = body["day"], body["conversation_start"], body["verdict"]
        records.parse_time(start, "conversation_start")
        if not records.valid_day(day) or verdict not in ("ok", "ng"):
            raise ValueError
    except (UnicodeDecodeError, ValueError, KeyError, TypeError):
        handler.send_json(400, {"error": "{day, conversation_start, verdict: ok|ng} の形で送ってください"})
        return
    path = home / OK_FILE
    path.parent.mkdir(parents=True, exist_ok=True)
    row = {"day": day, "conversation_start": start, "verdict": verdict,
           "at": datetime.datetime.now().astimezone().isoformat(timespec="seconds")}
    with path.open("a", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")
    log(f"会話の ○×: {verdict}")
    handler.send_json(200, {"ok": True})
