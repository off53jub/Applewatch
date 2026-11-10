"""LifeLog PC 版 9: この PC の Claude Code から、家の PC の記録を読む MCP サーバー（stdio・読むだけ）。

動かし方（登録のしかたは README.txt）:
    LifeLogPC.exe --mcp                      exe のとき
    python pc/lifelog_mcp.py                 Python のとき
    （どちらも --home <フォルダ>・--ollama-url <この PC の中の Ollama> を付けられる）

出す道具（どれも読むだけ。音声は返さない。記録を書き換える道具は無い）:
- list_conversations  日付（1日か、from〜to）で会話の一覧
- search_text         言葉で探す（空白で区切った言葉が全部ある行）
- search_meaning      意味で探す（この PC の Ollama の bge-m3。今の semantic.db を読むだけ）
- conversations_with  人の名前で、その人と話した会話を探す
- get_conversation    1つの会話の中身（行ごとの時刻・話し手・文）
- search_digest       仕事のまとめ（iPhone がドライブの「仕事のまとめ.json」に書くもの）の行を、言葉で探す
- get_digest          1日の仕事のまとめを、見出しごとに読む
  （search_text・search_meaning も、include_digest（既定 true）なら digest_hits に仕事のまとめの行を別に付ける。
   hits の形は変えない。仕事のまとめは職場の話なので、--exclude-work のときは出さない。ファイルは読むだけ）

**職場の会話は、どの道具からも返さない。** 職場の印（iPhone が POST /records/<日> の "work" で送る）が付いた会話と、
印が分からない会話（古い iPhone から来た日・PC に記録が無い日の、意味で探すの行）は、返す前に必ず外す。外した数だけ返す。
1日のまとめ（1日の流れ・決まったことなど）は、職場の会話も混ぜて作られているので、その日に職場の会話も
分からない会話も無いときだけ返す。
HOME（%LOCALAPPDATA%\\LifeLogPC）には何も書かない（記録のファイルは読むだけ。semantic.db は読むだけで開く）。
答えの通り道（標準出力）には MCP の答えしか書かない。知らせは標準エラーに、数だけ書く（会話の文や人の名前は書かない）。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import sys
import threading
import time
from pathlib import Path

import gpu
import mothership
import records
import semantic

NAME = "lifelog"
SERVER_VERSION = "9"
PROTOCOLS = ("2025-06-18", "2025-03-26", "2024-11-05")
OLLAMA_URL = "http://127.0.0.1:11434"
LIMIT_DEFAULT = 50
LIMIT_MAX = 300
K_DEFAULT = 10
K_MAX = 50
TEXT_LIMIT = 200          # 探す言葉の長さの上限
CONTEXT = 2               # 意味で探すときに前後に付ける行の数
DAY = re.compile(r"\d{4}-\d{2}-\d{2}")
INSTRUCTIONS = ("家の PC（LifeLog PC）にある会話の記録を読むための道具です。読むだけで、記録は変えられません。"
                "職場の会話と、職場かどうか分からない会話は返しません（外した数だけ返します）。"
                "時刻の local はこの PC の時刻です。会話の id は get_conversation に渡します。")


def default_home() -> Path:
    return Path(os.environ.get("LOCALAPPDATA") or Path.home() / ".local" / "share") / "LifeLogPC"


def note(message: str) -> None:
    """知らせ（標準エラー。数だけ。会話の文や人の名前は書かない）"""
    try:
        sys.stderr.write(time.strftime("%Y-%m-%d %H:%M:%S ") + "LifeLog MCP: " + message + "\n")
        sys.stderr.flush()
    except (OSError, ValueError):
        pass


def local_time(ms: int) -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(ms / 1000))


# MARK: - 記録を読む（読むだけ）


class Reader:
    """HOME/records/<日>.json を読むだけ（置き換え・一覧の書き直し・片付けをしない。records.RecordStore は使わない）"""

    def __init__(self, home: Path) -> None:
        self.home = Path(home)
        self.folder = self.home / "records"
        self.lock = threading.Lock()
        self.cache: dict[str, tuple[tuple, dict | None]] = {}

    def days(self, start: str | None = None, end: str | None = None) -> list[str]:
        """記録のある日（新しい順）"""
        try:
            names = [p.name[:-len(".json")] for p in self.folder.glob("????-??-??.json")]
        except OSError:
            return []
        out = [d for d in names if records.valid_day(d) and (start is None or d >= start) and (end is None or d <= end)]
        return sorted(out, reverse=True)

    def day(self, day: str) -> dict | None:
        if not records.valid_day(day):
            return None
        path = self.folder / f"{day}.json"
        try:
            stat = path.stat()
        except OSError:
            return None
        stamp = (stat.st_mtime_ns, stat.st_size)
        with self.lock:
            hit = self.cache.get(day)
            if hit is not None and hit[0] == stamp:
                return hit[1]
        try:
            parsed = records.parse_record(json.loads(path.read_bytes().decode("utf-8")))
        except (OSError, UnicodeDecodeError, ValueError) as error:
            note(f"記録 {day} を読めませんでした: {type(error).__name__}")
            parsed = None
        with self.lock:
            if len(self.cache) > 64:
                self.cache.clear()
            self.cache[day] = (stamp, parsed)
        return parsed


# 2026-11-07 本人の決定「情報は全部わたしてよい・どこにも全部よい」: 職場の会話も返す（既定）。
# --exclude-work で起動したときだけ、前と同じく職場の会話と分からない会話を外す
INCLUDE_WORK = True


def is_open(conversation: dict) -> bool:
    """返してよい会話か。既定は全部。--exclude-work のときは「職場ではない」とはっきりしている会話だけ"""
    return INCLUDE_WORK or conversation.get("work") is False


def conversation_id(day: str, conversation: dict) -> str:
    return f"{day}|{conversation['start']}"


def brief(day: str, c: dict) -> dict:
    """会話の一覧の1つ分（音声の名前・位置は入れない）"""
    out = {"id": conversation_id(day, c), "day": day, "start": records.iso_ms(c["start"]), "end": records.iso_ms(c["end"]),
           "local": f"{local_time(c['start'])}〜{local_time(c['end'])[11:]}", "title": c.get("title"),
           "points": list(c.get("points") or []), "people": records.people(c), "lines": len(c["lines"])}
    for key in ("place", "scene", "event", "movement", "media", "program"):
        if c.get(key):
            out[key] = c[key]
    return out


def line_out(line: dict) -> dict:
    """行の1つ分（音声の名前・位置は入れない）"""
    out = {"time": records.iso_ms(line["time"]), "local": local_time(line["time"])[11:], "speaker": line.get("speaker"),
           "text": line["text"]}
    if line.get("media"):
        out["media"] = line["media"]
    if line.get("marked"):
        out["marked"] = True
    if line.get("confidence") is not None and not line.get("checked") and line["confidence"] < records.REVIEW_UNSURE:
        out["unsure"] = True
    return out


def day_summary(parsed: dict) -> dict | None:
    """1日のまとめ。職場の会話も分からない会話も無い日だけ（まとめには職場の話も混ざるので）"""
    summary = parsed.get("summary")
    if not summary:
        return None
    if not INCLUDE_WORK and (parsed.get("work") is None or not all(is_open(c) for c in parsed["conversations"])):
        return None
    return summary


# MARK: - 意味で探す（semantic.db を読むだけ）


class ReadOnlyIndex(semantic.SemanticIndex):
    """semantic.SemanticIndex の探し方を、読むだけで使う（表を作らない・書き方を変えない・モデルを取ってこさせない）"""

    def __init__(self, path: Path, embedder) -> None:  # noqa: D107 — 親の __init__ は表を作るので呼ばない
        self.path = Path(path)
        self.embedder = embedder
        self.model = getattr(embedder, "model", semantic.EMBED_MODEL)
        self.log = note
        self.enabled = self.path.exists()
        self.lock = threading.Lock()
        self.check_lock = threading.Lock()
        self.ok = False
        self.checked = 0.0
        self.pulling = False
        self.pull_failed = 0.0
        self.error = None
        self._cache = None
        self._stamp = None

    def connect(self):  # type: ignore[override]
        import contextlib

        @contextlib.contextmanager
        def opened():
            # PC が動いているあいだは -wal があるので、読むだけで開く。無ければ、変わらないものとして開く
            # （どちらも、ファイルを作ったり書いたりしない）
            wal = Path(str(self.path) + "-wal")
            uri = self.path.resolve().as_uri() + ("?mode=ro" if wal.exists() else "?immutable=1")
            db = sqlite3.connect(uri, uri=True, timeout=30)
            try:
                yield db
            finally:
                db.close()

        return opened()

    def available(self, force: bool = False) -> bool:  # type: ignore[override]
        """Ollama が答え、埋め込みのモデルが入っているか（取ってこさせない）"""
        if not self.enabled:
            return False
        if force or time.time() - self.checked >= semantic.CHECK_EVERY:
            try:
                self.ok = semantic.model_listed(self.embedder.models(), self.model)
            except Exception:  # noqa: BLE001 — Ollama が無ければ使わないだけ
                self.ok = False
            self.checked = time.time()
        return self.ok

    def search(self, request: dict) -> list[dict]:  # type: ignore[override]
        # PC が索引を書き足したら、写しを作り直す
        try:
            stat = self.path.stat()
            wal = Path(str(self.path) + "-wal")
            stamp = (stat.st_mtime_ns, stat.st_size, wal.stat().st_mtime_ns if wal.exists() else 0)
        except OSError:
            stamp = None
        if stamp != self._stamp:
            self._cache = None
            self._stamp = stamp
        return super().search(request)


# MARK: - 道具


def _text(args: dict, key: str, required: bool = False, limit: int = TEXT_LIMIT) -> str | None:
    value = args.get(key)
    if value is None or (isinstance(value, str) and not value.strip()):
        if required:
            raise ValueError(f"{key} がありません")
        return None
    if not isinstance(value, str):
        raise ValueError(f"{key} は文字です")
    return value.strip()[:limit]


def _day(args: dict, key: str) -> str | None:
    value = _text(args, key)
    if value is not None and not records.valid_day(value):
        raise ValueError(f"{key} は YYYY-MM-DD（例 2026-11-07）です")
    return value


def _count(args: dict, key: str, default: int, top: int) -> int:
    value = args.get(key, default)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{key} は数です")
    return int(min(top, max(1, value)))


def _range(args: dict) -> tuple[str | None, str | None]:
    start, end = _day(args, "from"), _day(args, "to")
    if start and end and start > end:
        start, end = end, start
    return start, end


DIGEST_PROP = {"type": "boolean", "description": "仕事のまとめの行も digest_hits に付ける（既定 true。職場の話なので --exclude-work では出さない）"}

TOOLS = [
    {"name": "list_conversations",
     "description": "日付で会話の一覧を出す（1日なら day、何日かなら from と to。新しい日から）。"
                    "職場の会話と職場かどうか分からない会話は出さず、外した数を excluded_work に返す。",
     "inputSchema": {"type": "object", "properties": {
         "day": {"type": "string", "description": "日（YYYY-MM-DD）"},
         "from": {"type": "string", "description": "始めの日（YYYY-MM-DD）"},
         "to": {"type": "string", "description": "終わりの日（YYYY-MM-DD）"},
         "limit": {"type": "integer", "description": f"出す会話の数（{LIMIT_MAX} まで。既定 {LIMIT_DEFAULT}）"}}}},
    {"name": "search_text",
     "description": "言葉で探す（空白で区切った言葉が全部ある行。話し手の名前でも当たる。全角・半角と大文字・小文字は同じとみなす）。"
                    "新しい日から。職場の会話と分からない会話は探さない。",
     "inputSchema": {"type": "object", "required": ["query"], "properties": {
         "query": {"type": "string", "description": "探す言葉"},
         "from": {"type": "string"}, "to": {"type": "string"},
         "include_digest": DIGEST_PROP,
         "limit": {"type": "integer", "description": f"出す行の数（{LIMIT_MAX} まで。既定 {LIMIT_DEFAULT}）"}}}},
    {"name": "search_meaning",
     "description": "意味で探す（言葉が同じでなくても意味の近い行。この PC の Ollama の bge-m3 を使う）。前後の行も付ける。"
                    "職場の会話と分からない会話は出さない。",
     "inputSchema": {"type": "object", "required": ["query"], "properties": {
         "query": {"type": "string", "description": "探したいこと"},
         "from": {"type": "string"}, "to": {"type": "string"},
         "include_digest": DIGEST_PROP,
         "k": {"type": "integer", "description": f"出す数（{K_MAX} まで。既定 {K_DEFAULT}）"}}}},
    {"name": "conversations_with",
     "description": "人の名前で、その人と話した会話を探す（名前の一部でもよい。「自分」は探せない）。新しい日から。"
                    "職場の会話と分からない会話は出さない。",
     "inputSchema": {"type": "object", "required": ["name"], "properties": {
         "name": {"type": "string", "description": "人の名前"},
         "from": {"type": "string"}, "to": {"type": "string"},
         "limit": {"type": "integer", "description": f"出す会話の数（{LIMIT_MAX} まで。既定 {LIMIT_DEFAULT}）"}}}},
    {"name": "get_conversation",
     "description": "1つの会話の中身（行ごとの時刻・話し手・文）。id はほかの道具が返す \"日|始まりのミリ秒\"。"
                    "職場の会話と分からない会話は出さない。",
     "inputSchema": {"type": "object", "required": ["id"], "properties": {
         "id": {"type": "string", "description": "会話の id（例 2026-11-07|1762498800000）"}}}},
    {"name": "search_digest",
     "description": "仕事のまとめ（取り込んだ会議などの、決まったこと・自分の宿題など）の行を、言葉で探す"
                    "（空白で区切った言葉が全部ある行。全角・半角と大文字・小文字は同じとみなす）。新しい日から。"
                    "各行は {kind: \"work-digest\", day, heading, text}（時刻は無い）。",
     "inputSchema": {"type": "object", "required": ["query"], "properties": {
         "query": {"type": "string", "description": "探す言葉"},
         "from": {"type": "string"}, "to": {"type": "string"},
         "limit": {"type": "integer", "description": f"出す行の数（{LIMIT_MAX} まで。既定 {LIMIT_DEFAULT}）"}}}},
    {"name": "get_digest",
     "description": "1日の仕事のまとめを、見出し（決まったこと・自分の宿題など）ごとに読む。",
     "inputSchema": {"type": "object", "required": ["day"], "properties": {
         "day": {"type": "string", "description": "日（YYYY-MM-DD）"}}}},
]
for _tool in TOOLS:
    _tool["annotations"] = {"readOnlyHint": True, "openWorldHint": False}


class Tools:
    def __init__(self, home: Path, embedder=None, config: dict | None = None) -> None:
        self.home = Path(home)
        self.config = config if config is not None else load_config(self.home)
        self.digest_cache: tuple | None = None
        self.reader = Reader(self.home)
        self.index = ReadOnlyIndex(self.home / "semantic.db", embedder) if embedder is not None else None

    def call(self, name: str, args: dict) -> dict:
        if not isinstance(args, dict):
            raise ValueError("引数は JSON のまとまりです")
        method = {"list_conversations": self.list_conversations, "search_text": self.search_text,
                  "search_meaning": self.search_meaning, "conversations_with": self.conversations_with,
                  "get_conversation": self.get_conversation, "search_digest": self.search_digest,
                  "get_digest": self.get_digest}.get(name)
        if method is None:
            raise LookupError(f"知らない道具です: {name}")
        return method(args)

    def _digests(self) -> list[dict]:
        """仕事のまとめの行（日の新しい順）。読むだけ。ファイルが無い・--exclude-work のときは空"""
        if not INCLUDE_WORK:
            return []
        path = mothership.digest_file(self.config)
        try:
            stat = path.stat() if path is not None else None
        except OSError:
            stat = None
        if stat is None:
            return []
        key = (str(path), stat.st_mtime_ns, stat.st_size)
        if self.digest_cache is not None and self.digest_cache[0] == key:
            return self.digest_cache[1]
        found = mothership.read_digests(path)
        lines = found["lines"] if found else []
        self.digest_cache = (key, lines)
        return lines

    @staticmethod
    def _digest_out(line: dict) -> dict:
        return {"kind": "work-digest", "day": line["day"], "heading": line["heading"], "text": line["text"]}

    def _digest_words(self, query: str, start: str | None, end: str | None, limit: int) -> tuple[list[dict], bool]:
        terms = [records.fold(t) for t in query.split() if t.strip()]
        hits, more = [], False
        for line in self._digests():
            if (start and line["day"] < start) or (end and line["day"] > end):
                continue
            folded = records.fold(f"{line['heading']} {line['text']}")
            if all(term in folded for term in terms):
                if len(hits) >= limit:
                    more = True
                    break
                hits.append(self._digest_out(line))
        return hits, more

    def search_digest(self, args: dict) -> dict:
        query = _text(args, "query", required=True)
        start, end = _range(args)
        limit = _count(args, "limit", LIMIT_DEFAULT, LIMIT_MAX)
        if not INCLUDE_WORK:
            return {"hits": [], "message": "仕事のまとめは職場の話なので、この起動（--exclude-work）では出せません"}
        hits, more = self._digest_words(query, start, end, limit)
        out = {"hits": hits}
        if more:
            out["more"] = True
        return out

    def get_digest(self, args: dict) -> dict:
        day = _day(args, "day")
        if day is None:
            raise ValueError("day がありません")
        if not INCLUDE_WORK:
            return {"day": day, "sections": [], "lines": 0,
                    "message": "仕事のまとめは職場の話なので、この起動（--exclude-work）では出せません"}
        sections: list[dict] = []
        for line in self._digests():
            if line["day"] != day:
                continue
            if not sections or sections[-1]["heading"] != line["heading"]:
                sections.append({"heading": line["heading"], "lines": []})
            sections[-1]["lines"].append(line["text"])
        return {"day": day, "sections": sections, "lines": sum(len(x["lines"]) for x in sections)}

    def _scan(self, start: str | None, end: str | None):
        """(日, 会話) を新しい日から（日の中は時刻の順）。返してよい会話と、外した数"""
        excluded = 0
        out = []
        for day in self.reader.days(start, end):
            parsed = self.reader.day(day)
            if parsed is None:
                continue
            for c in parsed["conversations"]:
                if is_open(c):
                    out.append((day, c))
                else:
                    excluded += 1
        return out, excluded

    def list_conversations(self, args: dict) -> dict:
        day = _day(args, "day")
        start, end = (day, day) if day else _range(args)
        limit = _count(args, "limit", LIMIT_DEFAULT, LIMIT_MAX)
        found, excluded = self._scan(start, end)
        items = [brief(d, c) for d, c in found[:limit]]
        out = {"conversations": items, "count": len(found), "excluded_work": excluded}
        if len(found) > limit:
            out["more"] = len(found) - limit
        if day:
            parsed = self.reader.day(day)
            if parsed is not None:
                summary = day_summary(parsed)
                if summary:
                    out["day_summary"] = summary
        return out

    def search_text(self, args: dict) -> dict:
        query = _text(args, "query", required=True)
        start, end = _range(args)
        limit = _count(args, "limit", LIMIT_DEFAULT, LIMIT_MAX)
        terms = [records.fold(t) for t in query.split() if t.strip()]
        found, excluded = self._scan(start, end)
        hits = []
        more = False
        for day, c in found:
            for line in c["lines"]:
                folded = records.fold(f"{line.get('speaker') or ''} {line['text']}")
                if all(term in folded for term in terms):
                    if len(hits) >= limit:
                        more = True
                        break
                    hits.append(dict(line_out(line), day=day, conversation=conversation_id(day, c), title=c.get("title")))
            if more:
                break
        out = {"hits": hits, "excluded_work": excluded}
        if more:
            out["more"] = True
        if args.get("include_digest", True) is not False and INCLUDE_WORK:
            digest, digest_more = self._digest_words(query, start, end, limit)
            out["digest_hits"] = digest
            if digest_more:
                out["digest_more"] = True
        return out

    def conversations_with(self, args: dict) -> dict:
        name = _text(args, "name", required=True)
        wanted = records.fold(name)
        if wanted == records.fold(records.SELF_NAME):
            raise ValueError("「自分」では探せません。相手の名前を入れてください")
        start, end = _range(args)
        limit = _count(args, "limit", LIMIT_DEFAULT, LIMIT_MAX)
        found, excluded = self._scan(start, end)
        items = []
        total = 0
        for day, c in found:
            matched = [p for p in records.people(c) if wanted in records.fold(p)]
            if not matched:
                continue
            total += 1
            if len(items) < limit:
                said = sum(1 for line in c["lines"] if line.get("speaker") in matched)
                items.append(dict(brief(day, c), matched=matched, their_lines=said))
        out = {"conversations": items, "count": total, "excluded_work": excluded}
        if total > len(items):
            out["more"] = total - len(items)
        return out

    def _find(self, ident: str):
        """会話の id（"日|ミリ秒"）→ (日, 会話, その日の記録)。無ければ (日, None, 記録)"""
        match = re.fullmatch(r"(\d{4}-\d{2}-\d{2})\|(-?\d{1,15})", ident.strip())
        if not match:
            raise ValueError("id は \"日|始まりのミリ秒\"（例 2026-11-07|1762498800000）です")
        day, start = match.group(1), int(match.group(2))
        parsed = self.reader.day(day)
        if parsed is None:
            return day, None, None
        for c in parsed["conversations"]:
            if abs(c["start"] - start) <= records.WORK_SLACK:
                return day, c, parsed
        return day, None, parsed

    def get_conversation(self, args: dict) -> dict:
        ident = _text(args, "id", required=True)
        day, c, _ = self._find(ident)
        if c is None:
            raise LookupError("その会話は PC の記録にありません")
        if not is_open(c):
            # 職場の会話かどうかも言わずに断る（中身・見出し・相手は返さない）
            return {"conversation": None, "excluded_work": 1,
                    "message": "この会話は出せません（職場の会話か、職場かどうか分からない会話です）"}
        return {"conversation": dict(brief(day, c), lines=[line_out(line) for line in c["lines"]]), "excluded_work": 0}

    def search_meaning(self, args: dict) -> dict:
        query = _text(args, "query", required=True, limit=semantic.TEXT_MAX)
        start, end = _range(args)
        k = _count(args, "k", K_DEFAULT, K_MAX)
        if self.index is None or not self.index.enabled:
            raise RuntimeError("意味で探す索引（semantic.db）がこの PC にありません。search_text を使ってください")
        if not self.index.available(force=not self.index.ok):
            raise RuntimeError("この PC の Ollama が動いていないか、bge-m3 がありません。search_text を使ってください")
        # 職場の行（iPhone の work の印）を除いて、多めに探してから、記録の職場の印でも外す
        request = {"query": query, "k": min(semantic.K_MAX, k * 4), "from": start, "to": end, "speaker": None,
                   "include_work": INCLUDE_WORK}
        raw = self.index.search(request)
        hits = []
        excluded = 0
        seen = set()
        for hit in raw:
            day = hit.get("day") or ""
            conversation = hit.get("conversation") or ""
            match = re.fullmatch(r"(\d{4}-\d{2}-\d{2})\|(-?\d{1,15})", conversation)
            c = None
            if match and match.group(1) == day:
                _, c, _ = self._find(conversation)
            if c is None or not is_open(c) or (hit.get("work") and not INCLUDE_WORK):
                excluded += 1
                continue
            if len(hits) >= k:
                continue
            ms = int(round(float(hit.get("time") or 0) * 1000))
            index = next((i for i, line in enumerate(c["lines"]) if abs(line["time"] - ms) <= 1), None)
            if index is None:
                excluded += 1   # 記録に無い行（記録が変わった）は、念のため出さない
                continue
            key = (day, c["lines"][index]["time"])
            if key in seen:
                continue
            seen.add(key)
            lines = c["lines"]
            item = dict(line_out(lines[index]), day=day, conversation=conversation_id(day, c), title=c.get("title"),
                        score=round(float(hit.get("score") or 0), 4))
            item["before"] = [line_out(line) for line in lines[max(0, index - CONTEXT):index]]
            item["after"] = [line_out(line) for line in lines[index + 1:index + 1 + CONTEXT]]
            hits.append(item)
        out = {"hits": hits, "excluded_work": excluded}
        if args.get("include_digest", True) is not False and INCLUDE_WORK:
            # 仕事のまとめの行は、会話の行と競わないよう別に探す（行ごとに kind は work-digest。時刻・前後の行は無い）
            request.update({"k": k, "include_digest": True, "only_digest": True})
            out["digest_hits"] = [dict(h, score=round(float(h.get("score") or 0), 4)) for h in self.index.search(request)
                                  if h.get("kind") == "work-digest"]
        return out


# MARK: - MCP（JSON-RPC 2.0、1行に1つ）


class Server:
    def __init__(self, tools: Tools, write) -> None:
        self.tools = tools
        self.write = write

    def reply(self, ident, result=None, error=None) -> None:
        body = {"jsonrpc": "2.0", "id": ident}
        if error is not None:
            body["error"] = error
        else:
            body["result"] = result
        self.write(body)

    def handle(self, message) -> None:
        if not isinstance(message, dict):
            self.reply(None, error={"code": -32600, "message": "JSON-RPC のまとまりではありません"})
            return
        method = message.get("method")
        ident = message.get("id")
        notification = "id" not in message
        params = message.get("params") if isinstance(message.get("params"), dict) else {}
        if not isinstance(method, str):
            if not notification and ("result" not in message and "error" not in message):
                self.reply(ident, error={"code": -32600, "message": "method がありません"})
            return
        if notification:
            return  # notifications/initialized など。答えない
        if method == "initialize":
            asked = params.get("protocolVersion")
            self.reply(ident, {"protocolVersion": asked if asked in PROTOCOLS else PROTOCOLS[0],
                               "capabilities": {"tools": {"listChanged": False}},
                               "serverInfo": {"name": NAME, "title": "LifeLog の記録（家の PC・読むだけ）",
                                              "version": SERVER_VERSION},
                               "instructions": INSTRUCTIONS})
        elif method == "ping":
            self.reply(ident, {})
        elif method == "tools/list":
            self.reply(ident, {"tools": TOOLS})
        elif method == "tools/call":
            name = params.get("name")
            args = params.get("arguments") or {}
            started = time.time()
            try:
                result = self.tools.call(name, args)
            except LookupError as error:
                if str(error).startswith("知らない道具"):
                    self.reply(ident, error={"code": -32602, "message": str(error)})
                    return
                self.reply(ident, {"content": [{"type": "text", "text": str(error)}], "isError": True})
                return
            except (ValueError, RuntimeError) as error:
                self.reply(ident, {"content": [{"type": "text", "text": str(error)}], "isError": True})
                return
            except Exception as error:  # noqa: BLE001 — 何があっても受け付けは続ける
                note(f"{name} でつまずきました: {type(error).__name__}")
                self.reply(ident, {"content": [{"type": "text", "text": f"うまくいきませんでした（{type(error).__name__}）"}],
                                   "isError": True})
                return
            # 問い・文・名前は書かない（道具の名前と数だけ）
            note(f"{name}: 外した職場の会話 {result.get('excluded_work', 0)}・{time.time() - started:.2f} 秒")
            self.reply(ident, {"content": [{"type": "text", "text": json.dumps(result, ensure_ascii=False, indent=1)}],
                               "isError": False})
        else:
            self.reply(ident, error={"code": -32601, "message": f"知らない method です: {method}"})

    def serve(self, stream) -> None:
        for raw in stream:
            raw = raw.strip()
            if not raw:
                continue
            try:
                # 頭に BOM が付いていても読む（PowerShell から流し込んだとき）
                message = json.loads((raw.decode("utf-8") if isinstance(raw, bytes) else raw).lstrip("﻿"))
            except (UnicodeDecodeError, ValueError):
                self.reply(None, error={"code": -32700, "message": "JSON が読めません"})
                continue
            if isinstance(message, list):
                for item in message:
                    self.handle(item)
            else:
                self.handle(message)


def stdout_writer():
    out = sys.stdout.buffer
    lock = threading.Lock()

    def write(body: dict) -> None:
        data = json.dumps(body, ensure_ascii=False).encode("utf-8") + b"\n"
        with lock:
            out.write(data)
            out.flush()

    return write


def load_config(home: Path) -> dict:
    try:
        body = json.loads((home / "config.json").read_text(encoding="utf-8"))
        return body if isinstance(body, dict) else {}
    except (OSError, ValueError):
        return {}


def make_tools(home: Path, ollama_url: str | None = None) -> Tools:
    config = load_config(home)
    embedder = None
    if config.get("semantic") is not False:
        url = ollama_url or str(config.get("ollama_url") or OLLAMA_URL)
        try:
            # LifeLog PC が GPU に文字起こしのモデルを載せているあいだ（<home>/gpu-state.json を読むだけ）は、
            # bge-m3 も CPU だけで動かす（options に num_gpu 0。2026-11-07）
            embedder = semantic.OllamaEmbedder(url, options=lambda: gpu.state_options(home, config))
        except ValueError as error:
            note(f"意味で探すは使いません: {error}")
    return Tools(home, embedder, config)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="LifeLog の記録を読む MCP サーバー（stdio・読むだけ）")
    parser.add_argument("--exclude-work", action="store_true",
                        help="職場の会話と、職場かどうか分からない会話を返さない（既定は全部返す。2026-11-07 本人の決定）")
    parser.add_argument("--home", default=None, help="LifeLog PC の置き場所（既定 %%LOCALAPPDATA%%\\LifeLogPC）")
    parser.add_argument("--ollama-url", default=None, help="この PC の中の Ollama（既定 config.json の ollama_url か 127.0.0.1:11434）")
    args = parser.parse_args(argv)
    global INCLUDE_WORK
    INCLUDE_WORK = not args.exclude_work
    home = Path(args.home) if args.home else default_home()
    tools = make_tools(home, args.ollama_url)
    note(f"始めました（記録のある日 {len(tools.reader.days())}）")
    try:
        Server(tools, stdout_writer()).serve(sys.stdin.buffer)
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
