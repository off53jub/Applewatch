"""LifeLog PC 版 7: 記録（POST /records/<日>）・音声の保存・直し（GET /edits・POST /edits/ack）。

- iPhone は、閉じた会話の1日分（同期と同じ中身 ConversationLog.SyncDay）を JSON で送ってくる。
  PC は <home>/records/<日>.json に置き、中身が変わったときは1つ前を <日>.prev.json に残す。
- 見守りの画面（recordsui.py）で、読む・文字で探す・意味で探す・行の文を直す・行の話し手を変える。
  直した分は <home>/edits.db（SQLite）に置き、iPhone が GET /edits で取りに来て、当てたら POST /edits/ack で知らせる。
- iPhone が預けた区切りを消したら（DELETE /jobs/<名前>）、音声は消さずに <home>/audio/<日>/<名前> に移す
  （jobqueue.JobQueue の keep_audio）。30 日か合計 30GB（config.json の "audio_keep_days"・"audio_keep_gb"）を
  超えた古いものから消す。
記録・音声・直しは、この PC の外には送らない。記録（log）には、会話の文や人の名前を書かない。

版 9 で足したもの:
- 職場の会話の印: POST /records/<日> の省ける項目 "work"（職場の会話の start の並び）を日ごとに残し、
  会話ごとに "work"（True＝職場・False＝職場ではない・None＝分からない＝古い iPhone から来た日）を付ける。
- 「聞いて直す」並び: 自信の低い行（確からしさが低い・モデルの票が食い違う・話し手に「？」）で、PC に音声がある行。
  「合っている」の答えは edits.db の reviews に残す。直した行・「合っている」行は、PC の音声から材料を作る（sampler）。
"""

from __future__ import annotations

import contextlib
import datetime
import json
import os
import re
import sqlite3
import threading
import time
import unicodedata
from collections import OrderedDict
from pathlib import Path
from typing import Callable
from urllib.parse import parse_qs, unquote

import jobqueue

RECORD_LIMIT = 8 * 1024 * 1024    # POST /records/<日> の大きさの上限（8MB）
ACK_LIMIT = 1_000_000             # POST /edits/ack の大きさの上限
EDITS_LIMIT = 500                 # GET /edits で一度に返す数の上限
ACK_ITEMS = 2000                  # POST /edits/ack で一度に受ける数の上限
TEXT_MAX = 2000                   # 直した文の長さの上限（文字）
REASON_MAX = 500
SELF_NAME = "自分"                # iPhone の SpeakerLabeler.selfName
SELF_ID = "me"                    # iPhone の SpeakerLabeler.selfID
AUDIO_KEEP_DAYS = 30              # 音声を残す日数（config.json の "audio_keep_days"。0 なら残さない）
AUDIO_KEEP_GB = 30.0              # 音声を残す合計の大きさ（config.json の "audio_keep_gb"）
AUDIO_CLEAN_EVERY = 3600.0        # 古い音声を消すのを確かめる間（秒）
PARSED_CACHE = 8                  # 読んだ日を覚えておく数（画面で開いた日）
DAY = re.compile(r"\d{4}-\d{2}-\d{2}")
MOMENT = re.compile(r"(\d{4})-(\d{2})-(\d{2})[Tt ](\d{2}):(\d{2})(?::(\d{2})(?:[.,](\d{1,9}))?)?"
                    r"\s*(Z|z|[+-]\d{2}(?::?\d{2})?)")
EPOCH = datetime.datetime(1970, 1, 1, tzinfo=datetime.timezone.utc)
UNNAMED = re.compile(r"人物\d+")
STATUSES = ("applied", "skipped", "failed")
# Windows では使えないファイルの名前（音声を移す先の名前にしない）
RESERVED = re.compile(r"(CON|PRN|AUX|NUL|COM\d|LPT\d)(\..*)?", re.IGNORECASE)


# MARK: - 日時・日の名前


def parse_time(value, what: str) -> int:
    """ISO 8601 の日時（"2026-11-07T06:58:25.123Z"。ミリ秒なし・"+09:00" のような時差つきも読む）を、
    1970 年からのミリ秒にする。読めなければ ValueError。"""
    if not isinstance(value, str):
        raise ValueError(f"{what} の日時が読めません（ISO 8601 の文字で送ってください）")
    match = MOMENT.fullmatch(value.strip())
    if not match:
        raise ValueError(f"{what} の日時が読めません（ISO 8601 の形ではありません）")
    year, month, day, hour, minute = (int(match.group(i)) for i in range(1, 6))
    second = min(int(match.group(6) or 0), 59)      # うるう秒の 60 は 59 にする
    micro = int(((match.group(7) or "") + "000000")[:6])
    zone = match.group(8)
    offset = 0
    if zone not in ("Z", "z"):
        digits = zone[1:].replace(":", "")
        offset = (int(digits[:2]) * 60 + int(digits[2:4] or 0)) * (-1 if zone[0] == "-" else 1)
    try:
        moment = datetime.datetime(year, month, day, hour, minute, second, micro,
                                   tzinfo=datetime.timezone(datetime.timedelta(minutes=offset)))
    except ValueError as error:
        raise ValueError(f"{what} の日時が読めません（{error}）") from error
    delta = moment - EPOCH
    return (delta.days * 86400 + delta.seconds) * 1000 + delta.microseconds // 1000


def iso_ms(ms: int) -> str:
    """1970 年からのミリ秒を "2026-11-07T06:58:25.123Z"（UTC・ミリ秒つき）にする"""
    moment = EPOCH + datetime.timedelta(milliseconds=int(ms))
    return moment.strftime("%Y-%m-%dT%H:%M:%S") + f".{int(ms) % 1000:03d}Z"


def now_ms() -> int:
    return int(time.time() * 1000)


def valid_day(day) -> bool:
    """日の名前（"2026-11-07"）として正しいか"""
    if not isinstance(day, str) or not DAY.fullmatch(day):
        return False
    try:
        return 2000 <= datetime.date.fromisoformat(day).year <= 2100
    except ValueError:
        return False


def fold(text: str) -> str:
    """文字で探すときの比べ方（全角・半角と大文字・小文字の違いをそろえる）"""
    return unicodedata.normalize("NFKC", text or "").casefold()


def clean_text(text) -> str:
    """直した文: 前後の空白を除き、改行は空白にする（記録の行は1行）"""
    if not isinstance(text, str):
        return ""
    text = unicodedata.normalize("NFC", text)
    return re.sub(r"\s*[\r\n]+\s*", " ", text).strip()


# MARK: - 記録の中身（ConversationLog.SyncDay）を読む


def _str(value) -> str | None:
    return value if isinstance(value, str) else None


def _num(value) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value != value or value in (float("inf"), float("-inf")):
        return None
    return float(value)


def _int(value) -> int | None:
    number = _num(value)
    return int(number) if number is not None else None


def _flag(value) -> bool:
    return value is True


def _name(value, what: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise ValueError(f"{what} は文字か null です")
    return value


def parse_line(line, where: str) -> dict:
    if not isinstance(line, dict):
        raise ValueError(f"{where} が JSON のまとまりではありません")
    text = line.get("text")
    if not isinstance(text, str):
        raise ValueError(f"{where}.text は文字です")
    history = line.get("history") if isinstance(line.get("history"), list) else []
    for i, edit in enumerate(history):
        if isinstance(edit, dict) and "at" in edit:
            parse_time(edit.get("at"), f"{where}.history[{i}].at")
    return {"time": parse_time(line.get("time"), f"{where}.time"), "text": text,
            "speaker": _name(line.get("speaker"), f"{where}.speaker"),
            "speakerID": _name(line.get("speakerID"), f"{where}.speakerID"),
            "audio": _str(line.get("audio")), "offset": _num(line.get("offset")), "end": _num(line.get("end")),
            "marked": _flag(line.get("marked")), "confidence": _num(line.get("confidence")),
            "checked": _flag(line.get("checked")), "media": _str(line.get("media")), "noisy": _flag(line.get("noisy")),
            "sound": _str(line.get("sound")), "edited": len(history),
            # 版 9: 多数決で食い違った行のモデルごとの文・2つの声のモデルで話し手が食い違った行の、もう片方の番号
            "votes": _votes(line.get("votes")), "speakerDoubt": _str(line.get("speakerDoubt"))}


def _votes(value) -> dict[str, str]:
    if not isinstance(value, dict):
        return {}
    return {k: v for k, v in value.items() if isinstance(k, str) and isinstance(v, str)}


WORK_SLACK = 1   # 職場の会話の印と会話の始まりの、ずれてよいミリ秒（直しの行の探し方と同じ。1ms 未満のずれ）


def parse_work(value) -> list[int] | None:
    """省ける項目 "work"（職場の会話の start の並び）。無ければ None（分からない）"""
    if value is None:
        return None
    if not isinstance(value, list):
        raise ValueError("work は、職場の会話の start（ISO 8601）の並びです")
    return sorted({parse_time(item, f"work[{i}]") for i, item in enumerate(value)})


def mark_work(conversations: list[dict], work: list[int] | None) -> None:
    """会話ごとに "work" を付ける: True＝職場・False＝職場ではない・None＝分からない（印の無い日）"""
    for conversation in conversations:
        if work is None:
            conversation["work"] = None
        else:
            start = conversation["start"]
            conversation["work"] = any(abs(start - moment) <= WORK_SLACK for moment in work)


def parse_record(body) -> dict:
    """POST /records/<日> の中身を読む。おかしければ ValueError（どこがおかしいかを言う）。"""
    if not isinstance(body, dict):
        raise ValueError("中身が JSON のまとまりではありません")
    items = body.get("conversations")
    if not isinstance(items, list):
        raise ValueError("conversations がありません")
    conversations = []
    count = 0
    for i, item in enumerate(items):
        where = f"conversations[{i}]"
        if not isinstance(item, dict):
            raise ValueError(f"{where} が JSON のまとまりではありません")
        raw = item.get("lines")
        if raw is None:
            raw = []
        if not isinstance(raw, list):
            raise ValueError(f"{where}.lines が並びではありません")
        lines = [parse_line(line, f"{where}.lines[{j}]") for j, line in enumerate(raw)]
        start = parse_time(item.get("start"), f"{where}.start")
        end = parse_time(item.get("end"), f"{where}.end") if item.get("end") is not None \
            else max([start] + [line["time"] for line in lines])
        points = [p for p in item.get("points") or [] if isinstance(p, str)] if isinstance(item.get("points"), list) else []
        conversations.append({
            "start": start, "end": end, "title": _str(item.get("title")), "points": points,
            "place": _str(item.get("place")), "scene": _str(item.get("scene")), "event": _str(item.get("event")),
            "movement": _str(item.get("movement")), "media": _str(item.get("media")), "program": _str(item.get("program")),
            "heartRate": _int(item.get("heartRate")), "heartRateMax": _int(item.get("heartRateMax")),
            "tense": _flag(item.get("tense")), "minutes": _str(item.get("minutes")), "closed": _flag(item.get("closed")),
            "lines": lines})
        count += len(lines)
    removed = body.get("removed")
    if removed is not None:
        if not isinstance(removed, list):
            raise ValueError("removed が並びではありません")
        for i, item in enumerate(removed):
            if not isinstance(item, dict):
                raise ValueError(f"removed[{i}] が JSON のまとまりではありません")
            parse_time(item.get("start"), f"removed[{i}].start")
    summary = body.get("summary")
    if isinstance(summary, dict):
        summary = {key: [x for x in summary.get(key) or [] if isinstance(x, str)] if isinstance(summary.get(key), list) else []
                   for key in ("flow", "decisions", "todos", "topics")}
    else:
        summary = None
    names = body.get("audioNames")
    if names is not None and not isinstance(names, dict):
        raise ValueError("audioNames は {\"音声の名前\": \"PC の仕事の名前\"} の形です")
    audio_names = {k: v for k, v in (names or {}).items()
                   if isinstance(k, str) and isinstance(v, str) and jobqueue.valid_name(v)}
    conversations.sort(key=lambda c: c["start"])
    # 版 9: 職場の会話の印（無い日は「分からない」）
    work = parse_work(body.get("work"))
    mark_work(conversations, work)
    return {"conversations": conversations, "summary": summary, "audio_names": audio_names, "lines": count,
            "build": _int(body.get("build")), "work": work}


def people(conversation: dict) -> list[str]:
    """話した相手（iPhone の Conversation.people と同じ。テレビなどの声と「自分」は数えない）"""
    if conversation.get("media"):
        return []
    seen: list[str] = []
    for line in conversation["lines"]:
        name = line.get("speaker")
        if line.get("media") is None and name and name != SELF_NAME and name not in seen:
            seen.append(name)
    return seen


def summarize(parsed: dict, stamp: list, received: float) -> dict:
    """日の一覧に出す数と、話し手の名前（名前 → 行の数・付いている番号）"""
    names: dict[str, dict] = {}
    for conversation in parsed["conversations"]:
        for line in conversation["lines"]:
            name = line.get("speaker")
            if not name or line.get("media") is not None:
                continue
            entry = names.setdefault(name, {"count": 0, "ids": []})
            entry["count"] += 1
            ident = line.get("speakerID")
            if ident and ident not in entry["ids"]:
                entry["ids"].append(ident)
    # 版 9: 職場の会話の数（印の無い日は None＝分からない）
    work = None if parsed.get("work") is None else sum(1 for c in parsed["conversations"] if c.get("work"))
    return {"stamp": list(stamp), "received": received, "conversations": len(parsed["conversations"]),
            "lines": parsed["lines"], "names": names, "work": work}


# MARK: - 直し（<home>/edits.db）


def apply_edit(edit: dict, state: dict) -> dict:
    """直しを当てたあとの行（文・話し手・番号）"""
    out = dict(state)
    if edit["kind"] == "text":
        out["text"] = edit["text"]
    else:
        out["speaker"] = edit["speaker"]
        out["speakerID"] = edit["speakerID"]
    return out


COLUMNS = ("id", "day", "time", "kind", "base_text", "base_speaker", "base_speaker_id", "text", "speaker", "speaker_id",
           "created", "status", "reason", "sent", "acked")


class EditStore:
    """PC の画面で作った直し。id は増える一方（消しても使い直さない）。
    status: pending（まだ当てていない）・applied・skipped・failed（iPhone の知らせ）・superseded（あとの直しに置き換えた）"""

    def __init__(self, path: Path) -> None:
        self.path = Path(path)
        self.lock = threading.Lock()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.connect() as db:
            db.execute("CREATE TABLE IF NOT EXISTS edits (id INTEGER PRIMARY KEY AUTOINCREMENT, day TEXT NOT NULL,"
                       " time INTEGER NOT NULL, kind TEXT NOT NULL, base_text TEXT NOT NULL, base_speaker TEXT,"
                       " base_speaker_id TEXT, text TEXT, speaker TEXT, speaker_id TEXT, created INTEGER NOT NULL,"
                       " status TEXT NOT NULL, reason TEXT, sent INTEGER, acked INTEGER)")
            db.execute("CREATE INDEX IF NOT EXISTS edits_line ON edits (day, time)")
            db.execute("CREATE INDEX IF NOT EXISTS edits_status ON edits (status, id)")
            # 版 9: 「聞いて直す」で「合っている」と答えた行（iPhone には送らない。並びから外すのと、材料に使う）
            db.execute("CREATE TABLE IF NOT EXISTS reviews (day TEXT NOT NULL, time INTEGER NOT NULL, answer TEXT NOT NULL,"
                       " text TEXT, created INTEGER NOT NULL, PRIMARY KEY (day, time))")

    @contextlib.contextmanager
    def connect(self):
        """SQLite につなぐ。うまくいけば書いたものを確定し、最後に必ず閉じる。"""
        db = sqlite3.connect(str(self.path), timeout=30)
        try:
            yield db
            db.commit()
        except BaseException:
            db.rollback()
            raise
        finally:
            db.close()

    @staticmethod
    def _row(values) -> dict:
        row = dict(zip(COLUMNS, values))
        row["base"] = {"text": row["base_text"], "speaker": row["base_speaker"], "speakerID": row["base_speaker_id"]}
        row["speakerID"] = row["speaker_id"]
        return row

    def _select(self, db, where: str, params: tuple) -> list[dict]:
        return [self._row(r) for r in db.execute(f"SELECT {', '.join(COLUMNS)} FROM edits WHERE {where}", params)]

    @staticmethod
    def public(row: dict) -> dict:
        """GET /edits の1つ分（docs/v7-plan.md の形）"""
        text_kind = row["kind"] == "text"
        return {"id": row["id"], "day": row["day"], "time": iso_ms(row["time"]), "kind": row["kind"],
                "base": dict(row["base"]),
                "text": row["text"] if text_kind else None,
                "speaker": None if text_kind else row["speaker"],
                "speakerID": None if text_kind else row["speaker_id"],
                "created": iso_ms(row["created"])}

    def create(self, day: str, moment: int, kind: str, state: dict, target: dict, now: int | None = None) -> dict:
        """直しを1つ足す。state は PC にある記録の、その行の今の形。
        同じ行に、まだ当てていない直しがあるときは、こう扱う:
        - 直しの元（base）は、まだ当てていない直しを古い順に当てた後の形にする（iPhone も古い順に当てる）。
          つながりの始まりは、いちばん古い直しの元のまま（記録があとから変わっていたら、iPhone は全部飛ばす。
          iPhone の新しい中身を、PC の古い見立てで上書きしないため）
        - iPhone がまだ読みに来ていない直しのうち、同じ種類（文・話し手）のものは、新しいほうだけ残す（superseded）
        - iPhone が読みに来た直しは、iPhone が当てるかもしれないので、そのまま残し、その後に続ける
        直した結果が今と同じなら足さない（同じ種類の直しを取り消しただけになる）。"""
        now = now_ms() if now is None else now
        with self.lock, self.connect() as db:
            rows = self._select(db, "day=? AND time=? AND status='pending' ORDER BY id", (day, moment))
            if rows:
                state = dict(rows[0]["base"])
            last_sent = max((i for i, r in enumerate(rows) if r["sent"] is not None), default=-1)
            for row in rows[:last_sent + 1]:
                state = apply_edit(row, state)
            replaced = []
            for row in rows[last_sent + 1:]:
                if row["kind"] == kind:
                    replaced.append(row["id"])
                    continue
                if row["base"] != state:
                    db.execute("UPDATE edits SET base_text=?, base_speaker=?, base_speaker_id=? WHERE id=?",
                               (state["text"], state["speaker"], state["speakerID"], row["id"]))
                state = apply_edit(row, state)
            for ident in replaced:
                db.execute("UPDATE edits SET status='superseded', reason=?, acked=? WHERE id=?",
                           ("あとの直しに置き換えました", now, ident))
            if kind == "text":
                same = target["text"] == state["text"]
            else:
                same = target["speaker"] == state["speaker"]
            if same:
                if not replaced:
                    raise ValueError("文は変わっていません" if kind == "text" else "話し手は変わっていません")
                return {"edit": None, "replaced": replaced, "state": state,
                        "message": "前の直しを取り消しました（iPhone には送りません）"}
            cursor = db.execute(
                "INSERT INTO edits (day, time, kind, base_text, base_speaker, base_speaker_id, text, speaker, speaker_id,"
                " created, status) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending')",
                (day, moment, kind, state["text"], state["speaker"], state["speakerID"],
                 target.get("text") if kind == "text" else None,
                 target.get("speaker") if kind == "speaker" else None,
                 target.get("speakerID") if kind == "speaker" else None, now))
            row = self._select(db, "id=?", (cursor.lastrowid,))[0]
        return {"edit": row, "replaced": replaced, "state": apply_edit(row, state),
                "message": "直しました。iPhone に送る前です（iPhone が次につながったときに渡します）"}

    def pending(self, after: int, limit: int = EDITS_LIMIT, now: int | None = None) -> list[dict]:
        """まだ当てていない直しのうち id が after より大きいもの（古い順）。渡したものには渡した時刻を付ける。"""
        now = now_ms() if now is None else now
        with self.lock, self.connect() as db:
            rows = self._select(db, "status='pending' AND id>? ORDER BY id LIMIT ?", (int(after), int(limit)))
            db.executemany("UPDATE edits SET sent=? WHERE id=? AND sent IS NULL",
                           [(now, r["id"]) for r in rows if r["sent"] is None])
        return rows

    def ack(self, results: list[dict], now: int | None = None) -> dict[str, int]:
        """iPhone の知らせ（applied・skipped・failed）を書く。知らない id は飛ばす。"""
        now = now_ms() if now is None else now
        counts = {"applied": 0, "skipped": 0, "failed": 0, "unknown": 0}
        with self.lock, self.connect() as db:
            for item in results:
                cursor = db.execute("UPDATE edits SET status=?, reason=?, acked=?, sent=COALESCE(sent, ?) WHERE id=?",
                                    (item["status"], item["reason"], now, now, item["id"]))
                counts[item["status"] if cursor.rowcount else "unknown"] += 1
        return counts

    def for_day(self, day: str) -> list[dict]:
        with self.lock, self.connect() as db:
            return self._select(db, "day=? ORDER BY id", (day,))

    def recent(self, limit: int = 30) -> list[dict]:
        with self.lock, self.connect() as db:
            return self._select(db, "status<>'superseded' ORDER BY id DESC LIMIT ?", (int(limit),))

    def counts(self) -> dict[str, int]:
        with self.lock, self.connect() as db:
            rows = db.execute("SELECT status, COUNT(*) FROM edits GROUP BY status").fetchall()
        return {status: int(n) for status, n in rows}

    def pending_days(self) -> dict[str, int]:
        with self.lock, self.connect() as db:
            rows = db.execute("SELECT day, COUNT(*) FROM edits WHERE status='pending' GROUP BY day").fetchall()
        return {day: int(n) for day, n in rows}

    # 版 9: 「聞いて直す」の答え

    def answer(self, day: str, moment: int, answer: str, text: str | None, now: int | None = None) -> None:
        """「合っている」（answer="ok"）を残す。同じ行は新しい答えで置き換える。"""
        now = now_ms() if now is None else now
        with self.lock, self.connect() as db:
            db.execute("INSERT OR REPLACE INTO reviews (day, time, answer, text, created) VALUES (?, ?, ?, ?, ?)",
                       (day, int(moment), answer, text, now))

    def answers(self) -> dict[tuple[str, int], str]:
        """(日, 行の時刻) → 答え"""
        with self.lock, self.connect() as db:
            return {(day, int(moment)): answer for day, moment, answer in db.execute("SELECT day, time, answer FROM reviews")}

    def edited_lines(self) -> dict[tuple[str, int], set[str]]:
        """(日, 行の時刻) → 直した種類（text・speaker。置き換えたものは数えない）"""
        with self.lock, self.connect() as db:
            rows = db.execute("SELECT day, time, kind FROM edits WHERE status<>'superseded'").fetchall()
        out: dict[tuple[str, int], set[str]] = {}
        for day, moment, kind in rows:
            out.setdefault((day, int(moment)), set()).add(kind)
        return out


def expected_lines(edits: list[dict]) -> dict[int, list[dict]]:
    """日の直しを、行の時刻ごとにまとめる（古い順）"""
    out: dict[int, list[dict]] = {}
    for edit in edits:
        out.setdefault(edit["time"], []).append(edit)
    return out


def settled_state(line: dict, edits: list[dict], received_ms: int | None) -> dict:
    """iPhone の今の行の見立て: PC にある記録の行に、その記録が届いたあとで iPhone が当てた（applied）直しを当てた形。
    （iPhone は当てた日を送り直すが、届くまでのあいだに次の直しを作っても、元がずれないように）"""
    state = {"text": line["text"], "speaker": line.get("speaker"), "speakerID": line.get("speakerID")}
    for edit in edits:
        if edit["status"] == "applied" and received_ms is not None and int(edit.get("acked") or 0) > received_ms:
            state = apply_edit(edit, state)
    return state


def expected_state(line: dict, edits: list[dict], received_ms: int | None = None) -> dict:
    """まだ当てていない直しを古い順に当てた形（画面の「直す」の初めの中身。EditStore.create と同じつなぎ方）"""
    pending = [edit for edit in edits if edit["status"] == "pending"]
    state = dict(pending[0]["base"]) if pending else settled_state(line, edits, received_ms)
    for edit in pending:
        state = apply_edit(edit, state)
    return state


# MARK: - 版 9: 「聞いて直す」並び


def _plain_vote(text: str) -> str:
    """票の比べ方（全角・半角・大文字小文字・空白と句読点の違いは見ない）"""
    return re.sub(r"[\s、。，．,.!！?？・「」『』（）()〜~ー-]", "", fold(text))


def doubt_reasons(line: dict, unsure: float) -> list[str]:
    """自信の低い行の理由（無ければ空）。手で直した行・テレビなどの行は選ばない。
    "low"＝確からしさが低い・"votes"＝モデルの票が食い違う・"speaker"＝2つの声のモデルで話し手が食い違う（「？」付き）"""
    if line.get("checked") or line.get("media") is not None or not (line.get("text") or "").strip():
        return []
    reasons = []
    if line.get("confidence") is not None and line["confidence"] < unsure:
        reasons.append("low")
    votes = {_plain_vote(v) for v in (line.get("votes") or {}).values() if v.strip()}
    if len(votes) >= 2 or (len(votes) == 1 and _plain_vote(line["text"]) not in votes):
        reasons.append("votes")
    doubt = line.get("speakerDoubt")
    if doubt and doubt != line.get("speakerID"):
        reasons.append("speaker")
    return reasons


def sample_span(offset: float, end: float | None, text: str) -> tuple[float, float]:
    """材料にする音声の区間（iPhone の Benchmark.span と sendPersonalSamples と同じ決め方。
    同じ行を iPhone があとで送ってきても、同じ長さになるように）"""
    start = max(0.0, float(offset) - 0.3)
    if end is not None and end > offset:
        return start, float(end)
    return start, float(offset) + min(15.0, max(1.5, len(text) * 0.17 + 0.8))


REVIEW_UNSURE = 0.45   # iPhone の「確かめたほうがよい行」の初めの線（ConversationLog.Line.uncertainBelow）


# MARK: - 音声の置き場所


def safe_audio_name(name) -> bool:
    """音声のファイルの名前として使えるか（区切りの名前の決まり・Windows で使えない名前を除く）"""
    return jobqueue.valid_name(name) and not name.endswith(".") and RESERVED.fullmatch(name) is None


def audio_day(name: str, queued_at=None) -> str:
    """音声を置く日（区切りの名前の頭の 20261107- から。分からなければ預かった日）"""
    match = re.match(r"(\d{4})(\d{2})(\d{2})(?:[-_T]|$)", name)
    if match:
        day = f"{match.group(1)}-{match.group(2)}-{match.group(3)}"
        if valid_day(day):
            return day
    try:
        return time.strftime("%Y-%m-%d", time.localtime(float(queued_at)))
    except (TypeError, ValueError, OverflowError, OSError):
        return time.strftime("%Y-%m-%d")


def _limit(value, default: float) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value != value or value < 0:
        return default
    return float(value)


# MARK: - 記録の置き場所


class RecordStore:
    def __init__(self, home: Path, log: Callable[[str], None], config: Callable[[], dict] | None = None) -> None:
        self.home = Path(home)
        self.folder = self.home / "records"
        self.audio = self.home / "audio"
        self.log = log
        self.config = config or (lambda: {})
        self.lock = threading.RLock()
        self.cache: OrderedDict[str, tuple[tuple, dict]] = OrderedDict()
        self.rows: dict[str, tuple[tuple, list[dict]]] = {}
        self.summaries: dict[str, dict] = {}
        self.wake = threading.Event()
        self.thread: threading.Thread | None = None
        self.folder.mkdir(parents=True, exist_ok=True)
        self._recover()
        self._load_index()
        self.edits = EditStore(self.home / "edits.db")
        # 版 9: 材料を作る仕組み（lifelog_pc.py が入れる。(音声のファイル, 始まり, 終わり, 文, 出どころ) → (材料の数, 足したか)）
        self.sampler: Callable[[Path, float, float, str, dict], tuple[int, bool]] | None = None

    # MARK: 置く

    def path(self, day: str) -> Path:
        return self.folder / f"{day}.json"

    def prev_path(self, day: str) -> Path:
        return self.folder / f"{day}.prev.json"

    def _recover(self) -> None:
        """置き換えの途中で止まったもの（<日>.json.part）を片付ける"""
        for part in self.folder.glob("*.json.part"):
            target = part.with_name(part.name[:-len(".part")])
            try:
                if target.exists():
                    part.unlink()
                else:
                    os.replace(part, target)
            except OSError:
                pass

    def _load_index(self) -> None:
        try:
            body = json.loads((self.folder / "index.json").read_text(encoding="utf-8"))
            days = body.get("days") if isinstance(body, dict) else None
            if isinstance(days, dict):
                self.summaries = {d: s for d, s in days.items() if valid_day(d) and isinstance(s, dict)}
        except (OSError, ValueError):
            self.summaries = {}

    def _save_index(self) -> None:
        path = self.folder / "index.json"
        part = path.with_name(path.name + ".part")
        try:
            part.write_text(json.dumps({"days": self.summaries}, ensure_ascii=False), encoding="utf-8")
            os.replace(part, path)
        except OSError as error:
            self.log(f"記録の一覧を書けませんでした（次に作り直します）: {error!r}")

    def put(self, day: str, data: bytes) -> dict:
        """POST /records/<日> の中身を置く。中身が前と違えば、前のものを <日>.prev.json に残す。"""
        if not valid_day(day):
            raise ValueError("日の名前は YYYY-MM-DD（例 2026-11-07）です")
        try:
            body = json.loads(data.decode("utf-8"))
        except (UnicodeDecodeError, ValueError) as error:
            raise ValueError("中身が JSON ではありません") from error
        parsed = parse_record(body)
        with self.lock:
            path = self.path(day)
            try:
                current = path.read_bytes()
            except FileNotFoundError:
                current = None
            changed = current != data
            if changed:
                part = path.with_name(path.name + ".part")
                part.write_bytes(data)
                if current is not None:
                    os.replace(path, self.prev_path(day))
                os.replace(part, path)
            else:
                # 同じ中身でも、受け取った時刻は新しくする（iPhone で当てた直しが、この記録に入っているかの見立てに使う）
                try:
                    os.utime(path, None)
                except OSError:
                    pass
            stat = path.stat()
            stamp = (stat.st_mtime_ns, stat.st_size)
            self.cache[day] = (stamp, parsed)
            self.cache.move_to_end(day)
            while len(self.cache) > PARSED_CACHE:
                self.cache.popitem(last=False)
            self.rows.pop(day, None)
            self.summaries[day] = summarize(parsed, list(stamp), stat.st_mtime)
            self._save_index()
        return {"conversations": len(parsed["conversations"]), "lines": parsed["lines"], "changed": changed}

    # MARK: 読む

    def day(self, day: str) -> dict | None:
        """その日の記録（読めなければ None）"""
        if not valid_day(day):
            return None
        path = self.path(day)
        # 置き換え（put）と重ならないよう、ファイルを読むところまではロックを持つ
        with self.lock:
            try:
                stat = path.stat()
            except OSError:
                return None
            stamp = (stat.st_mtime_ns, stat.st_size)
            hit = self.cache.get(day)
            if hit is not None and hit[0] == stamp:
                self.cache.move_to_end(day)
                return hit[1]
            try:
                data = path.read_bytes()
            except OSError as error:
                self.log(f"記録 {day} を読めませんでした: {error!r}")
                return None
        try:
            parsed = parse_record(json.loads(data.decode("utf-8")))
        except UnicodeDecodeError:
            # repr には中身が入るので、記録には書かない
            self.log(f"記録 {day} を読めませんでした: UTF-8 ではありません")
            return None
        except ValueError as error:
            self.log(f"記録 {day} を読めませんでした: {type(error).__name__}")
            return None
        with self.lock:
            self.cache[day] = (stamp, parsed)
            self.cache.move_to_end(day)
            while len(self.cache) > PARSED_CACHE:
                self.cache.popitem(last=False)
        return parsed

    def days(self) -> list[dict]:
        """記録のある日（新しい順）。{"day", "conversations", "lines", "received", "names"}"""
        files = {p.name[:-len(".json")]: p for p in self.folder.glob("????-??-??.json")}
        with self.lock:
            summaries = dict(self.summaries)
        changed = False
        out = []
        for day, path in files.items():
            if not valid_day(day):
                continue
            try:
                stat = path.stat()
            except OSError:
                continue
            stamp = [stat.st_mtime_ns, stat.st_size]
            summary = summaries.get(day)
            if summary is None or summary.get("stamp") != stamp:
                parsed = self.day(day)
                if parsed is None:
                    continue
                summary = summarize(parsed, stamp, stat.st_mtime)
                summaries[day] = summary
                changed = True
            out.append(dict(summary, day=day))
        for day in list(summaries):
            if day not in files:
                summaries.pop(day)
                changed = True
        if changed:
            with self.lock:
                self.summaries = summaries
                self._save_index()
        return sorted(out, key=lambda s: s["day"], reverse=True)

    def speakers(self) -> list[dict]:
        """話し手に選べる名前（「自分」と、記録に出てくる名前。行の多い順、名前の無い「人物N」は後ろ）。
        "id" は、記録の中でその名前に付いている番号が1つに決まるときだけ（決まらなければ None）。"""
        totals: dict[str, dict] = {}
        for summary in self.days():
            for name, info in (summary.get("names") or {}).items():
                entry = totals.setdefault(name, {"count": 0, "ids": set()})
                entry["count"] += int(info.get("count") or 0)
                entry["ids"].update(info.get("ids") or [])
        me = totals.pop(SELF_NAME, {"count": 0})
        out = [{"name": SELF_NAME, "id": SELF_ID, "count": me["count"]}]
        for name, entry in sorted(totals.items(), key=lambda kv: (UNNAMED.fullmatch(kv[0]) is not None,
                                                                   -kv[1]["count"], kv[0])):
            out.append({"name": name, "count": entry["count"],
                        "id": next(iter(entry["ids"])) if len(entry["ids"]) == 1 else None})
        return out

    def _search_rows(self, day: str) -> list[dict]:
        path = self.path(day)
        try:
            stat = path.stat()
        except OSError:
            return []
        stamp = (stat.st_mtime_ns, stat.st_size)
        with self.lock:
            hit = self.rows.get(day)
            if hit is not None and hit[0] == stamp:
                return hit[1]
        parsed = self.day(day)
        rows = []
        for conversation in (parsed or {}).get("conversations", []):
            for line in conversation["lines"]:
                rows.append({"day": day, "time": line["time"], "speaker": line.get("speaker"), "text": line["text"],
                             "media": line.get("media"), "title": conversation.get("title"),
                             "conversation": conversation["start"],
                             "fold": fold(f"{line.get('speaker') or ''} {line['text']}")})
        with self.lock:
            self.rows[day] = (stamp, rows)
        return rows

    def search_text(self, query: str, limit: int = 300) -> tuple[list[dict], bool]:
        """全部の日から、文字で探す（空白で区切った言葉が全部ある行。話し手の名前でも当たる）。
        (見つかった行（新しい日から）, 上限で打ち切ったか)"""
        terms = [fold(t) for t in (query or "").split() if t.strip()]
        if not terms:
            return [], False
        hits: list[dict] = []
        for summary in self.days():
            for row in self._search_rows(summary["day"]):
                if all(term in row["fold"] for term in terms):
                    hits.append(row)
                    if len(hits) >= limit:
                        return hits, True
        return hits, False

    def received_ms(self, day: str) -> int | None:
        """その日の記録を最後に受け取った時刻（1970 年からのミリ秒）"""
        try:
            return int(self.path(day).stat().st_mtime * 1000)
        except OSError:
            return None

    def find_line(self, day: str, moment: int) -> tuple[dict | None, dict | None, int]:
        """その日の、その時刻の行と会話と、同じ時刻の行の数"""
        parsed = self.day(day)
        found = [(line, c) for c in (parsed or {}).get("conversations", []) for line in c["lines"] if line["time"] == moment]
        if not found:
            return None, None, 0
        return found[0][0], found[0][1], len(found)

    # MARK: 直す

    def make_edit(self, day: str, moment, kind: str, value) -> dict:
        """画面からの直し（kind は text か speaker）。おかしければ ValueError（画面に出す文）。"""
        if kind not in ("text", "speaker"):
            raise ValueError("kind は text か speaker です")
        if not valid_day(day):
            raise ValueError("日の名前が正しくありません")
        if isinstance(moment, bool) or not isinstance(moment, int):
            raise ValueError("行の時刻が正しくありません")
        if self.day(day) is None:
            raise ValueError("その日の記録が PC にありません")
        line, _, count = self.find_line(day, moment)
        if line is None:
            raise ValueError("その行が記録にありません（iPhone から新しい記録が届いて変わったのかもしれません。画面を開き直してください）")
        if count > 1:
            raise ValueError("同じ時刻の行がほかにもあるので、この行は PC から直せません")
        line_edits = [e for e in self.edits.for_day(day) if e["time"] == moment]
        state = settled_state(line, line_edits, self.received_ms(day))
        if kind == "text":
            text = clean_text(value)
            if not text:
                raise ValueError("文が空です")
            if len(text) > TEXT_MAX:
                raise ValueError(f"文が長すぎます（{TEXT_MAX} 文字まで）")
            target = {"text": text}
        else:
            name = value.strip() if isinstance(value, str) else ""
            choices = {s["name"]: s for s in self.speakers()}
            if name not in choices:
                raise ValueError("話し手は、記録に出てくる名前か「自分」から選んでください（PC から新しい名前は作れません）")
            target = {"speaker": name, "speakerID": choices[name]["id"]}
        return self.edits.create(day, moment, kind, state, target)

    # MARK: 版 9: 聞いて直す

    def review_queue(self, limit: int = 30, unsure: float = REVIEW_UNSURE) -> tuple[list[dict], int]:
        """自信の低い行で、PC に音声がある行（新しい日から。日の中は時刻の順）。(初めの limit 個, 全部の数)。
        答えた行は外す（文を直した・「合っている」→ 外す、話し手を変えた → 「？」の理由だけ外す）。
        同じ時刻の行が2つある行は、PC から直せないので出さない。"""
        available = self.audio_names()
        answers = self.edits.answers()
        edited = self.edits.edited_lines()
        items: list[dict] = []
        total = 0
        for summary in self.days():
            day = summary["day"]
            parsed = self.day(day)
            if parsed is None:
                continue
            names = parsed["audio_names"]
            counts: dict[int, int] = {}
            for c in parsed["conversations"]:
                for line in c["lines"]:
                    counts[line["time"]] = counts.get(line["time"], 0) + 1
            for c in parsed["conversations"]:
                if c.get("media"):
                    continue
                lines = c["lines"]
                for i, line in enumerate(lines):
                    reasons = doubt_reasons(line, unsure)
                    if not reasons or counts.get(line["time"], 0) > 1:
                        continue
                    key = (day, line["time"])
                    kinds = edited.get(key, set())
                    if key in answers or "text" in kinds:
                        continue
                    if "speaker" in kinds:
                        reasons = [r for r in reasons if r != "speaker"]
                    job = names.get(line["audio"], line["audio"]) if line.get("audio") else None
                    if not reasons or not job or job not in available or not safe_audio_name(job) \
                            or line.get("offset") is None:
                        continue
                    total += 1
                    if len(items) < limit:
                        items.append({"day": day, "conversation": c, "line": line, "index": i, "job": job,
                                      "reasons": reasons,
                                      "before": lines[i - 1] if i > 0 else None,
                                      "after": lines[i + 1] if i + 1 < len(lines) else None})
        return items, total

    def review(self, day: str, moment, kind: str, value) -> dict:
        """「聞いて直す」の答え。kind は text（文を直す）・speaker（話し手を変える）・ok（合っている）。
        text と ok は、PC にある音声からその行の所を切り出して、学び直しの材料に足す（sampler があるとき）。"""
        if kind not in ("text", "speaker", "ok"):
            raise ValueError("kind は text・speaker・ok のどれかです")
        if kind != "ok":
            result = self.make_edit(day, moment, kind, value)
        else:
            if not valid_day(day) or isinstance(moment, bool) or not isinstance(moment, int):
                raise ValueError("行が正しくありません")
            line, _, count = self.find_line(day, moment)
            if line is None:
                raise ValueError("その行が記録にありません（画面を開き直してください）")
            if count > 1:
                raise ValueError("同じ時刻の行がほかにもあるので、この行は PC から答えられません")
            edits = [e for e in self.edits.for_day(day) if e["time"] == moment]
            state = expected_state(line, edits, self.received_ms(day))
            self.edits.answer(day, moment, "ok", state["text"])
            result = {"edit": None, "replaced": [], "state": state,
                      "message": "「合っている」と残しました（iPhone には送りません）"}
        result["sample"] = None
        if kind in ("text", "ok"):
            result["sample"] = self._review_sample(day, moment, result["state"]["text"], kind)
        return result

    def _review_sample(self, day: str, moment: int, text: str, kind: str) -> dict:
        """その行の音声を切り出して材料に足す。足せなくても答えはそのまま（理由を返す）"""
        line, _, _ = self.find_line(day, moment)
        parsed = self.day(day) or {}
        if self.sampler is None:
            return {"added": False, "reason": "材料を作る仕組みが動いていません"}
        if line is None or not line.get("audio") or line.get("offset") is None:
            return {"added": False, "reason": "その行の音声の位置が分かりません"}
        job = (parsed.get("audio_names") or {}).get(line["audio"], line["audio"])
        path = self.audio_file(job)
        if path is None:
            return {"added": False, "reason": "PC に音声がありません"}
        start, end = sample_span(line["offset"], line.get("end"), text)
        source = {"origin": "pc-review", "answer": kind, "day": day, "time": iso_ms(moment), "audio": job,
                  "line": line["audio"], "offset": round(float(line["offset"]), 2)}
        try:
            count, added = self.sampler(path, start, end, text, source)
        except ValueError as error:
            return {"added": False, "reason": str(error)}
        except Exception as error:  # noqa: BLE001 — 材料が作れなくても、答えは残す
            self.log(f"聞いて直す: 材料を作れませんでした: {type(error).__name__}")
            return {"added": False, "reason": f"材料を作れませんでした（{type(error).__name__}）"}
        return {"added": added, "count": count, "reason": None if added else "同じ材料がもうあります"}

    # MARK: 音声（jobqueue.JobQueue の keep_audio）

    def audio_limits(self) -> tuple[float, float]:
        """(残す日数, 残す合計の GB)。config.json の "audio_keep_days"・"audio_keep_gb" で変えられる"""
        try:
            config = self.config() or {}
        except Exception:  # noqa: BLE001 — 設定が読めなければ決まりの値
            config = {}
        return _limit(config.get("audio_keep_days"), AUDIO_KEEP_DAYS), _limit(config.get("audio_keep_gb"), AUDIO_KEEP_GB)

    def keep_audio(self, name: str, path: Path, meta: dict) -> None:
        """iPhone が消した区切りの音声を <home>/audio/<日>/<名前> に移す（jobqueue が、ロックを持って呼ぶ。速く終える）。
        残さない設定（0 日）・使えない名前なら何もしない（jobqueue が消す）。"""
        days, _ = self.audio_limits()
        if days <= 0 or not safe_audio_name(name):
            return
        folder = self.audio / audio_day(name, meta.get("queued_at"))
        folder.mkdir(parents=True, exist_ok=True)
        os.replace(path, folder / name)
        self.wake.set()

    def audio_file(self, name: str) -> Path | None:
        """保存した音声のファイル（無ければ None）"""
        if not safe_audio_name(name):
            return None
        first = self.audio / audio_day(name) / name
        if first.is_file():
            return first
        try:
            for path in self.audio.glob(f"*/{name}"):
                if path.is_file():
                    return path
        except OSError:
            pass
        return None

    def audio_names(self) -> set[str]:
        """保存した音声の名前（画面で「再生」を出すかを決める）"""
        try:
            return {p.name for p in self.audio.glob("*/*") if p.is_file()}
        except OSError:
            return set()

    def audio_stats(self) -> dict:
        count, size = 0, 0
        try:
            for path in self.audio.glob("*/*"):
                try:
                    if path.is_file():
                        count += 1
                        size += path.stat().st_size
                except OSError:
                    continue
        except OSError:
            pass
        days, gb = self.audio_limits()
        return {"count": count, "bytes": size, "keep_days": days, "keep_gb": gb}

    def clean_audio(self, now: float | None = None) -> int:
        """古い音声（keep_days より前に PC が受けたもの）と、合計が keep_gb を超えた分の古いものを消す。消した数を返す。"""
        now = time.time() if now is None else now
        days, gb = self.audio_limits()
        files = []
        try:
            for path in self.audio.glob("*/*"):
                try:
                    stat = path.stat()
                except OSError:
                    continue
                if path.is_file():
                    files.append((stat.st_mtime, stat.st_size, path))
        except OSError:
            return 0
        files.sort(key=lambda f: (f[0], str(f[2])))
        total = sum(size for _, size, _ in files)
        cutoff = now - days * 86400
        limit = gb * 1e9
        removed, freed = 0, 0
        for mtime, size, path in files:
            if mtime >= cutoff and total <= limit:
                break
            try:
                path.unlink()
            except OSError:
                continue
            removed += 1
            freed += size
            total -= size
        try:
            for folder in self.audio.iterdir():
                if folder.is_dir() and not any(folder.iterdir()):
                    folder.rmdir()
        except OSError:
            pass
        if removed:
            self.log(f"保存した音声: 古いものを {removed} 個消しました（{freed / 1e9:.2f} GB。"
                     f"{days:g} 日・{gb:g} GB まで残します）")
        return removed

    def start(self) -> None:
        """古い音声を消す裏の仕事（1時間ごと。音声を移したあとは少し待って）"""
        if self.thread is not None:
            return

        def loop() -> None:
            while True:
                try:
                    self.clean_audio()
                except Exception as error:  # noqa: BLE001 — 裏の仕事は止めない
                    self.log(f"保存した音声の片付けでつまずきました: {error!r}")
                self.wake.wait(AUDIO_CLEAN_EVERY)
                if self.wake.is_set():
                    self.wake.clear()
                    time.sleep(30)

        self.thread = threading.Thread(target=loop, name="records-audio", daemon=True)
        self.thread.start()


# MARK: - 受け付け（lifelog_pc.py の Handler から呼ぶ）


def _read(handler, limit: int, what: str) -> bytes | None:
    """中身を読む。無い・大きすぎる・途中で切れたときは答えを返して None。"""
    try:
        length = int(handler.headers.get("Content-Length") or 0)
    except ValueError:
        length = 0
    if length <= 0 or length > limit:
        handler.discard_body()
        handler.send_json(400 if length <= 0 else 413,
                          {"error": "中身がありません" if length <= 0 else f"{what}が大きすぎます（{limit // 1_000_000}MB まで）"})
        return None
    data = handler.rfile.read(length)
    if len(data) < length:
        handler.close_connection = True
        handler.send_json(400, {"error": "中身が途中で切れました"})
        return None
    return data


def parse_ack(data: bytes) -> list[dict]:
    """POST /edits/ack の {"results": [{"id": 12, "status": "applied", "reason": null}]}"""
    try:
        body = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as error:
        raise ValueError("中身が JSON ではありません") from error
    results = body.get("results") if isinstance(body, dict) else None
    if not isinstance(results, list):
        raise ValueError("results がありません")
    if len(results) > ACK_ITEMS:
        raise ValueError(f"results が多すぎます（{ACK_ITEMS} 個まで）")
    out = []
    for i, item in enumerate(results):
        if not isinstance(item, dict):
            raise ValueError(f"results[{i}] が JSON のまとまりではありません")
        ident = item.get("id")
        if isinstance(ident, bool) or not isinstance(ident, int):
            raise ValueError(f"results[{i}].id は数です")
        status = item.get("status")
        if status not in STATUSES:
            raise ValueError(f"results[{i}].status は applied・skipped・failed のどれかです")
        reason = item.get("reason")
        if reason is not None and not isinstance(reason, str):
            raise ValueError(f"results[{i}].reason は文字か null です")
        out.append({"id": ident, "status": status, "reason": reason.strip()[:REASON_MAX] if reason else None})
    return out


def http_post(handler, store: RecordStore | None, path: str, log: Callable[[str], None]) -> None:
    """POST /records/<日>・POST /edits/ack（合言葉は Bearer）"""
    if not handler.authorized():
        return
    if store is None:
        handler.discard_body()
        handler.send_json(503, {"error": "記録の機能は今は使えません"})
        return
    if path == "/edits/ack":
        data = _read(handler, ACK_LIMIT, "知らせ")
        if data is None:
            return
        try:
            counts = store.edits.ack(parse_ack(data))
        except ValueError as error:
            handler.send_json(400, {"error": str(error)})
            return
        except Exception as error:  # noqa: BLE001 — 何があっても受け付けは続ける
            log(f"直しの知らせを書けませんでした: {error!r}")
            handler.send_json(500, {"error": f"直しの知らせを書けませんでした: {error}"})
            return
        log(f"iPhone から直しの知らせ: 直した {counts['applied']}・飛ばした {counts['skipped']}・"
            f"失敗 {counts['failed']}" + (f"・知らない番号 {counts['unknown']}" if counts["unknown"] else ""))
        handler.send_json(200, {"ok": True, "updated": counts["applied"] + counts["skipped"] + counts["failed"]})
        return
    day = unquote(path[len("/records/"):])
    if not valid_day(day):
        handler.discard_body()
        handler.send_json(400, {"error": "日の名前は YYYY-MM-DD（例 2026-11-07）です"})
        return
    data = _read(handler, RECORD_LIMIT, "記録")
    if data is None:
        return
    started = time.time()
    try:
        result = store.put(day, data)
    except ValueError as error:
        handler.send_json(400, {"error": str(error)})
        return
    except Exception as error:  # noqa: BLE001 — 何があっても受け付けは続ける
        log(f"記録 {day} を置けませんでした: {error!r}")
        handler.send_json(500, {"error": f"記録を置けませんでした: {error}"})
        return
    # 会話の中身・人の名前は記録に書かない（日と数だけ）
    log(f"{handler.client_address[0]} から記録 {day}: 会話 {result['conversations']}・行 {result['lines']}"
        + ("" if result["changed"] else "（前と同じ）") + f"、{time.time() - started:.2f} 秒")
    handler.send_json(200, {"ok": True, "conversations": result["conversations"], "lines": result["lines"]})


def http_get_edits(handler, store: RecordStore | None, query_text: str, log: Callable[[str], None]) -> None:
    """GET /edits?after=<id>（合言葉は Bearer）"""
    if not handler.authorized():
        return
    if store is None:
        handler.send_json(503, {"error": "記録の機能は今は使えません"})
        return
    raw = (parse_qs(query_text).get("after") or ["0"])[0].strip() or "0"
    if not re.fullmatch(r"\d{1,18}", raw):
        handler.send_json(400, {"error": "after は 0 以上の数です"})
        return
    try:
        rows = store.edits.pending(int(raw))
    except Exception as error:  # noqa: BLE001
        log(f"直しを読めませんでした: {error!r}")
        handler.send_json(500, {"error": f"直しを読めませんでした: {error}"})
        return
    if rows:
        log(f"{handler.client_address[0]} に直しを渡しました: {len(rows)} 件")
    handler.send_json(200, {"edits": [EditStore.public(r) for r in rows]})
