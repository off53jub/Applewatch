"""LifeLog PC: s26（2026-11-25。担当 P）のアプリ向けの口。取り決め K4・K5・K6・K8（名前と形を変えない）。

母艦（M2）が state/ に置く写しを確かめて返すだけ（0 円・言語モデルなし）。無い・読めないときは {"available": false, "reason": …}。
- K4（軽9）: GET /machine-actions ← state/machine_actions_for_app.json
  {"available": true, "version", "generated_at", "items": [{"id","at","kind","what","undo"}]}（新しい順）。
  kind は task_closed・fix・name・other。undo が true でも、id が POST /feedback の id の決まり（英数字と _ . : - で 64 字まで）に
  合わないものは undo false にして返す（戻すの答えを受けられないため）。戻すの答えは POST /feedback の kind "undo"・value "undo"・id
  （appfeeds.FEEDBACK。母艦の inbox/app_feedback.jsonl に 1 行。M2 が次の回で戻す）。
- K5（軽5）: GET /waiting ← state/waiting_for_app.json
  {"available": true, ..., "items": [{"id","title","steps","link","copy","done"}]}（済んでいないものが先）。
  link は lifelog://・https:// だけ（ほかは null）。copy に秘密らしい文（鍵・合言葉・トークンの形）があれば null にして "copy_hidden": true。
- K6（軽11）: GET /gap-task ← state/gap_task_for_app.json
  {"available": true, ..., "items": [{"from","to","task_id","text","minutes"}], "now": 今の時刻に当たる 1 件 か null}。
  終わった（to が過ぎた）ものは返さない。
- K8（結6）: GET /events?since=ISO ← state/events_stream.jsonl（1 行 {"at","kind","text","link"}）
  {"available": true, "items": [...]（古い順・since より新しいもの・EVENTS_MAX 件まで＝多ければ新しい側を残す）, "more": bool}。
  since が無ければ直近 24 時間。MCP の道具（lifelog_mcp.py の events_since）も同じ読み方。
中身（文）は記録（log.txt）に書かない。
"""

from __future__ import annotations

import datetime
import json
import re
from pathlib import Path

import appfeeds

MACHINE_ACTIONS = Path("state") / "machine_actions_for_app.json"
WAITING = Path("state") / "waiting_for_app.json"
GAP_TASK = Path("state") / "gap_task_for_app.json"
EVENTS = Path("state") / "events_stream.jsonl"
GETS = ("/machine-actions", "/waiting", "/gap-task", "/events")
FEATURES = ("machineactions", "waiting", "gaptask", "events")

ACTION_KINDS = ("task_closed", "fix", "name", "other")
ACTIONS_MAX = 200
WAITING_MAX = 60
STEPS_MAX = 12
COPY_MAX = 2000
GAP_MAX = 40
EVENTS_MAX = 300
EVENTS_READ_MAX = 8 * 1024 * 1024     # 90 日分の流れでも、読むのは後ろの 8 MB まで
LINK = re.compile(r"(lifelog|https)://[^\s\x00-\x1f\x7f]{1,500}")
# copy に入れてはいけないもの（K5。母艦が気をつけるが、ここでも形で止める・仮）
SECRET_WORDS = re.compile(r"(?i)(password|passwd|token|secret|api[_-]?key|bearer|sk-ant-|-----BEGIN|合言葉|パスワード)")
SECRET_SHAPE = re.compile(r"[A-Za-z0-9_\-+/=]{32,}")
KIND = re.compile(r"[0-9A-Za-z_.:-]{1,40}")


def _ident(value) -> str | None:
    if not isinstance(value, str) or not value or len(value) > 80 or re.search(r"[\x00-\x1f\x7f]", value):
        return None
    return value


def _moment(value) -> datetime.datetime | None:
    """ISO 8601 → 時差つきの日時（時差の無いものはこの PC の時刻とみなす）"""
    if not isinstance(value, str) or appfeeds.ISO.fullmatch(value) is None:
        return None
    try:
        moment = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return moment if moment.tzinfo is not None else moment.astimezone()


def _link(value) -> str | None:
    return value if isinstance(value, str) and LINK.fullmatch(value) else None


def _head(data: dict) -> dict:
    return {"available": True, "version": appfeeds._version(data), "generated_at": appfeeds._iso(data.get("generated_at"))}


# MARK: - K4 GET /machine-actions


def read_machine_actions(base: Path) -> dict:
    data, failure = appfeeds._load(Path(base), MACHINE_ACTIONS, "機械がしたことの一覧")
    if failure or data is None or not isinstance(data.get("items"), list):
        return failure or {"available": False, "reason": "母艦の機械がしたことの一覧の形が違います"}
    items, seen = [], set()
    for x in data["items"][:ACTIONS_MAX * 4]:
        if not isinstance(x, dict):
            continue
        ident, at, kind = _ident(x.get("id")), _moment(x.get("at")), x.get("kind")
        what = appfeeds._text(x.get("what"), 200)
        if ident is None or ident in seen or at is None or kind not in ACTION_KINDS or not what \
                or not isinstance(x.get("undo"), bool):
            continue
        seen.add(ident)
        undo = x["undo"] and appfeeds._id(ident) is not None
        items.append((at, {"id": ident, "at": x["at"], "kind": kind, "what": what, "undo": undo}))
    items.sort(key=lambda pair: pair[0], reverse=True)
    return {**_head(data), "items": [row for _, row in items[:ACTIONS_MAX]]}


# MARK: - K5 GET /waiting


def safe_copy(value) -> tuple[str | None, bool]:
    """(返してよい copy, 隠したか)"""
    if not isinstance(value, str) or not value.strip():
        return None, False
    if len(value) > COPY_MAX or SECRET_WORDS.search(value) or SECRET_SHAPE.search(value):
        return None, True
    return value, False


def read_waiting(base: Path) -> dict:
    data, failure = appfeeds._load(Path(base), WAITING, "本人の操作待ちの一覧")
    if failure or data is None or not isinstance(data.get("items"), list):
        return failure or {"available": False, "reason": "母艦の本人の操作待ちの一覧の形が違います"}
    items, seen = [], set()
    for x in data["items"][:WAITING_MAX * 4]:
        if not isinstance(x, dict):
            continue
        ident, title = _ident(x.get("id")), appfeeds._text(x.get("title"), 120)
        steps = x.get("steps")
        if ident is None or ident in seen or not title or not isinstance(steps, list) or not isinstance(x.get("done"), bool):
            continue
        seen.add(ident)
        kept = [appfeeds._long(s, 300) for s in steps[:STEPS_MAX] if isinstance(s, str) and s.strip()]
        copy, hidden = safe_copy(x.get("copy"))
        row = {"id": ident, "title": title, "steps": kept, "link": _link(x.get("link")), "copy": copy, "done": x["done"]}
        if hidden:
            row["copy_hidden"] = True
        items.append(row)
        if len(items) >= WAITING_MAX:
            break
    items.sort(key=lambda r: r["done"])   # 済んでいないものが先（その中の順は母艦のまま）
    return {**_head(data), "items": items}


# MARK: - K6 GET /gap-task


def read_gap_task(base: Path, now: datetime.datetime | None = None) -> dict:
    now = (now or datetime.datetime.now()).astimezone()
    data, failure = appfeeds._load(Path(base), GAP_TASK, "すきまの 1 件")
    if failure or data is None or not isinstance(data.get("items"), list):
        return failure or {"available": False, "reason": "母艦のすきまの 1 件の形が違います"}
    items = []
    for x in data["items"][:GAP_MAX * 4]:
        if not isinstance(x, dict):
            continue
        start, end, text = _moment(x.get("from")), _moment(x.get("to")), appfeeds._text(x.get("text"), 200)
        minutes = appfeeds._int(x.get("minutes"), 1, 24 * 60)
        task = x.get("task_id")
        if start is None or end is None or end <= start or not text or minutes is None \
                or (task is not None and _ident(task) is None):
            continue
        if end <= now:
            continue
        items.append((start, end, {"from": x["from"], "to": x["to"], "task_id": task, "text": text, "minutes": minutes}))
    items.sort(key=lambda t: t[0])
    current = next((row for start, end, row in items if start <= now < end), None)
    return {**_head(data), "items": [row for _, _, row in items[:GAP_MAX]], "now": current}


# MARK: - K8 GET /events?since=


def _tail(path: Path, limit: int = EVENTS_READ_MAX) -> list[str]:
    with path.open("rb") as handle:
        handle.seek(0, 2)
        size = handle.tell()
        handle.seek(max(0, size - limit))
        data = handle.read()
    if size > limit:
        data = data[data.find(b"\n") + 1:]   # 途中から読んだ最初の行は捨てる
    return data.decode("utf-8-sig", errors="replace").splitlines()


def read_events(base: Path, since: str | None = None, limit: int = EVENTS_MAX,
                now: datetime.datetime | None = None) -> dict:
    now = (now or datetime.datetime.now()).astimezone()
    if since is not None and _moment(since) is None:
        return {"available": False, "reason": "since は ISO 8601 の日時です"}
    floor = _moment(since) if since else now - datetime.timedelta(hours=24)
    path = Path(base) / EVENTS
    try:
        raw = _tail(path)
    except FileNotFoundError:
        return {"available": False, "reason": "母艦の出来事の流れがまだありません"}
    except OSError as error:
        return {"available": False, "reason": f"母艦の出来事の流れを読めませんでした: {type(error).__name__}"}
    rows = []
    for text in raw:
        try:
            x = json.loads(text)
        except ValueError:
            continue
        if not isinstance(x, dict):
            continue
        at, kind, body = _moment(x.get("at")), x.get("kind"), appfeeds._long(x.get("text"), 500)
        if at is None or at <= floor or not isinstance(kind, str) or KIND.fullmatch(kind) is None or not body:
            continue
        rows.append((at, {"at": x["at"], "kind": kind, "text": body, "link": _link(x.get("link"))}))
    rows.sort(key=lambda pair: pair[0])
    limit = max(1, min(int(limit or EVENTS_MAX), EVENTS_MAX))
    more = len(rows) > limit
    return {"available": True, "since": floor.isoformat(timespec="seconds"), "items": [r for _, r in rows[-limit:]],
            "more": more}


# MARK: - 受け口


def http_get(handler, path: str, query: str, base: Path | None) -> None:
    """GET /machine-actions・/waiting・/gap-task・/events（合言葉は lifelog_pc.py が確かめてから）"""
    if base is None:
        handler.send_json(200, {"available": False, "reason": "母艦が見つかりません"})
        return
    try:
        if path == "/machine-actions":
            body = read_machine_actions(base)
        elif path == "/waiting":
            body = read_waiting(base)
        elif path == "/gap-task":
            body = read_gap_task(base)
        else:
            import urllib.parse

            params = urllib.parse.parse_qs(query or "")
            since = (params.get("since") or [None])[0]
            try:
                limit = int((params.get("limit") or [EVENTS_MAX])[0])
            except ValueError:
                limit = EVENTS_MAX
            body = read_events(base, since, limit)
        handler.send_json(200, body)
    except Exception as error:  # noqa: BLE001
        handler.send_json(200, {"available": False, "reason": f"読めませんでした: {type(error).__name__}"})
