"""LifeLog PC: 声で直す（s18 の 63 の「解釈」。受け口のアプリ・時計は A。2026-11-19）。

本人が時計に「違う、〇〇さん」と言うと、アプリ（A）がその言葉を PC に送る。PC はそれを読み解いて、
今までの「PC から直す」と同じ直し（edits.db の pending。iPhone が GET /edits で取りに来て当てる）にする。

- POST /voice-fix {"text": "違う、〇〇さん", "at": "ISO 8601", "target_id"?: "..."}（形は仮。A の PR がまだ無いので、
  s18 の決まりの {text, at, target_id?} にした。A の形が決まったら合わせる）
  target_id は "YYYY-MM-DD|<行の時刻のミリ秒>" か、行の時刻の ISO 8601。無ければ at より前 WINDOW_S 秒（仮）の中で
  いちばん新しい「自分ではない」行（話し手を直すとき）／いちばん新しい行（言葉を直すとき）。
- 読み解き（言葉の決まりだけ。AI は使わない）:
  - 話し手: 「違う、〇〇（さん・くん・ちゃん）（だよ・です）」→ その行の話し手を 〇〇 に。「違う、自分／俺／僕／私」→ 自分。
  - 言葉: 「〇〇じゃなくて△△」「〇〇じゃない、△△」→ その行の文の 〇〇 を △△ に（〇〇 が文に無ければ直さない）。
- 名前は記録にもう出てくる名前だけ（records.RecordStore.make_edit と同じ。新しい名前は作らない・人をまとめない・
  名前を付け替えない）。名前が 1 つに決まらない・見つからないときは直さずに {"status": "ask", "candidates": [...]} を返す。
- 答え: {"status": "edited"|"ask"|"not_understood"|"no_target", "kind", "day", "line_time", "message", "candidates"?}
- 控え: HOME/knowme/voice-fix.jsonl に 1 行ずつ（本人の言葉・読み解き・結果。この PC の中だけ）。
  記録（log.txt）には結果の種類だけを書く（名前・文は書かない）。
"""

from __future__ import annotations

import datetime
import json
import re
import time
import unicodedata
from pathlib import Path
from typing import Callable

import records

POSTS = ("/voice-fix",)
LOG_FILE = Path("knowme") / "voice-fix.jsonl"
WINDOW_S = 300.0        # 仮: 行を探す、言った時刻より前の秒
BODY_MAX = 4096
TEXT_MAX = 200
SELF_WORDS = ("自分", "俺", "おれ", "オレ", "僕", "ぼく", "私", "わたし", "あたし")
NO = r"(?:違う|ちがう|ちゃう|違います|ちがいます)"
HONORIFIC = r"(?:さん|くん|君|ちゃん|様|さま|氏)"
TAIL = r"(?:だよ|です|でした|だった|だね|だから|や|よ|ね)?"
SPEAKER = re.compile(rf"^\s*{NO}[、,，。.\s!！]*(?P<name>[^、,，。.\s!！?？]{{1,20}}?){HONORIFIC}?{TAIL}[。.!！]*\s*$")
REPLACE = re.compile(r"^\s*(?:" + NO + r"[、,，。.\s]*)?(?P<wrong>[^、,，。\s]{1,20}?)(?:じゃなくて|ではなくて|じゃなく|じゃない[、,，\s]*)"
                     r"(?P<right>[^、,，。\s!！]{1,20}?)(?:だよ|です|だ)?[。.!！]*\s*$")


def interpret(text: str) -> dict | None:
    """{"kind": "speaker", "name"} か {"kind": "text", "wrong", "right"}。分からなければ None"""
    text = unicodedata.normalize("NFKC", text or "").strip()
    m = REPLACE.match(text)
    if m and m.group("wrong") != m.group("right"):
        return {"kind": "text", "wrong": m.group("wrong"), "right": m.group("right")}
    m = SPEAKER.match(text)
    if m:
        name = m.group("name")
        if name in SELF_WORDS:
            name = records.SELF_NAME
        return {"kind": "speaker", "name": name}
    return None


def resolve_name(store, name: str) -> tuple[str | None, list[str]]:
    """(1 つに決まった名前, 候補)。記録に出てくる名前だけ"""
    names = [s["name"] for s in store.speakers()]
    if name in names:
        return name, [name]
    plain = [n for n in names if re.sub(HONORIFIC + "$", "", n) == name]
    if len(plain) == 1:
        return plain[0], plain
    starts = [n for n in names if n.startswith(name) and not records.UNNAMED.fullmatch(n)] if len(name) >= 2 else []
    if len(starts) == 1:
        return starts[0], starts
    return None, (plain or starts or [n for n in names if name in n])[:5]


def parse_moment(value) -> int | None:
    if not isinstance(value, str):
        return None
    try:
        return records.parse_time(value, "at")
    except ValueError:
        return None


def find_target(store, kind: str, at_ms: int, target_id) -> tuple[str, int] | None:
    """(日, 行の時刻のミリ秒)"""
    if isinstance(target_id, str) and target_id:
        if "|" in target_id:
            day, _, ms = target_id.partition("|")
            if records.valid_day(day) and ms.isdigit():
                return day, int(ms)
        moment = parse_moment(target_id)
        if moment is not None:
            day = datetime.datetime.fromtimestamp(moment / 1000).date().isoformat()
            return day, moment
        return None
    best = None
    when = datetime.datetime.fromtimestamp(at_ms / 1000).date()
    for day in {when.isoformat(), (when - datetime.timedelta(days=1)).isoformat()}:
        parsed = store.day(day)
        for c in (parsed or {}).get("conversations", []):
            for line in c["lines"]:
                t = line["time"]
                if not (at_ms - WINDOW_S * 1000 <= t <= at_ms) or not (line.get("text") or "").strip():
                    continue
                if kind == "speaker" and (line.get("speakerID") == records.SELF_ID or line.get("speaker") == records.SELF_NAME):
                    continue
                if best is None or t > best[1]:
                    best = (day, t)
    return best


def handle(store, body: dict) -> dict:
    text = body.get("text")
    if not isinstance(text, str) or not text.strip() or len(text) > TEXT_MAX:
        return {"status": "not_understood", "message": "言葉がありません"}
    at_ms = parse_moment(body.get("at")) or int(time.time() * 1000)
    meaning = interpret(text)
    if meaning is None:
        return {"status": "not_understood", "message": "「違う、〇〇さん」か「〇〇じゃなくて△△」の形で言ってください"}
    target = find_target(store, meaning["kind"], at_ms, body.get("target_id"))
    if target is None:
        return {"status": "no_target", "kind": meaning["kind"], "message": "直す行が見つかりませんでした"}
    day, moment = target
    out = {"kind": meaning["kind"], "day": day, "line_time": records.iso_ms(moment)}
    if meaning["kind"] == "speaker":
        name, candidates = resolve_name(store, meaning["name"])
        if name is None:
            return {**out, "status": "ask", "candidates": candidates,
                    "message": "名前が 1 つに決まりませんでした。アプリで選んでください"}
        value = name
    else:
        line, _, _ = store.find_line(day, moment)
        if line is None or meaning["wrong"] not in line["text"]:
            return {**out, "status": "ask", "message": "直す言葉がその行に見つかりませんでした"}
        value = line["text"].replace(meaning["wrong"], meaning["right"])
    try:
        made = store.make_edit(day, moment, meaning["kind"], value)
    except ValueError as error:
        return {**out, "status": "ask", "message": str(error)[:120]}
    return {**out, "status": "edited", "message": made.get("message"), "edit_id": (made.get("edit") or {}).get("id")}


def note(home: Path, body: dict, result: dict) -> None:
    row = {"at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
           "text": str(body.get("text"))[:TEXT_MAX], "said_at": body.get("at"), "target_id": body.get("target_id"),
           **{k: result.get(k) for k in ("status", "kind", "day", "line_time", "candidates")}}
    path = home / LOG_FILE
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")


def http_post(handler, home: Path, store, log: Callable[[str], None]) -> None:
    length = int(handler.headers.get("Content-Length") or 0)
    if length <= 0 or length > BODY_MAX:
        handler.send_json(400, {"error": "中身の大きさが正しくありません"})
        return
    try:
        body = json.loads(handler.rfile.read(length).decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        handler.send_json(400, {"error": "JSON ではありません"})
        return
    if not isinstance(body, dict):
        handler.send_json(400, {"error": "JSON のまとまりではありません"})
        return
    if store is None:
        handler.send_json(503, {"error": "記録がまだ使えません"})
        return
    result = handle(store, body)
    try:
        note(home, body, result)
    except OSError:
        pass
    log(f"声で直す: {result['status']}（{result.get('kind') or '-'}）")
    handler.send_json(200, result)


INBOX = Path("inbox") / "voice_fixes.jsonl"     # アプリ（A）の POST /know/voice-fix が母艦に足す行（knowapp.py）
DONE_FILE = Path("knowme") / "voice-fix-inbox.json"


def drain_inbox(home: Path, mother: Path | None, store, log: Callable[[str], None]) -> int:
    """2026-11-19: 時計の「違う、〇〇さん」はアプリが母艦の inbox に置く。まだ当てていない行を読み解いて直す。
    当てた行は said_at と言葉の組で覚える（同じ行を二度当てない）。返り値は当てようとした行の数。"""
    if mother is None or store is None:
        return 0
    path = Path(mother) / INBOX
    if not path.exists():
        return 0
    done_path = Path(home) / DONE_FILE
    try:
        done = set(json.loads(done_path.read_text(encoding="utf-8")).get("done", []))
    except (OSError, ValueError):
        done = set()
    count = 0
    for raw in path.read_text(encoding="utf-8").splitlines():
        try:
            row = json.loads(raw)
        except ValueError:
            continue
        if not isinstance(row, dict) or not isinstance(row.get("text"), str):
            continue
        key = f"{row.get('said_at')}|{row['text']}"
        if key in done:
            continue
        near = row.get("near") if isinstance(row.get("near"), dict) else {}
        body = {"text": row["text"], "at": row.get("said_at"), "target_id": near.get("line_time")}
        result = handle(store, body)
        try:
            note(home, body, result)
        except OSError:
            pass
        log(f"声で直す（時計から）: {result['status']}（{result.get('kind') or '-'}）")
        done.add(key)
        count += 1
    if count:
        done_path.parent.mkdir(parents=True, exist_ok=True)
        done_path.write_text(json.dumps({"done": sorted(done)[-2000:]}, ensure_ascii=False), encoding="utf-8")
    return count
