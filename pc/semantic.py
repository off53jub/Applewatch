"""LifeLog PC 版 6: 意味で探す（POST /index・POST /search・POST /forget・GET /index/status）。

iPhone が送ってきた文字起こしの行を、この PC の中で動く Ollama の埋め込みのモデル（bge-m3）で数の並びにし、
<home>/semantic.db（SQLite、float16）に置く。探すときは、問いの数の並びとの近さ（cos）の高い順に返し、
同じ会話の前後 2 行ずつを "context" に付ける（iPhone が前後も見せて、どの行から言ったかを示せるように）。
文も数の並びも、この PC の外には送らない（Ollama はこの PC の中の宛先だけ）。

仕事のまとめ（2026-11-10）: ドライブの「仕事のまとめ.json」（mothership.read_digests で読むだけ）の行も同じ索引に置く。
id が "digest|" で始まる行がそれ（見出しは speaker の欄、時刻は 0、会話は無し、work は true）。表は変えない。
探すときは include_digest が true のときだけ出し（古い iPhone には今までと同じ答え）、出す行は
{"id", "kind": "work-digest", "day", "heading", "text", "work": true, "score"}（時刻・話し手・前後の行は無し）。
索引への置き直しは、ファイルの更新が変わったときだけ、5 分ごとの裏の仕事で（文が同じ行は作り直さない）。
"""

from __future__ import annotations

import contextlib
import hashlib
import json
import re
import sqlite3
import threading
import time
from pathlib import Path
from typing import Callable
from urllib.parse import urlparse

import numpy as np

EMBED_MODEL = "bge-m3"
INDEX_LIMIT = 500        # 1回の /index で受ける行の数の上限
TEXT_MAX = 8000          # 1行の文の長さの上限（文字）
ID_MAX = 200
BATCH = 32               # 一度に Ollama に頼む数
EMBED_TIMEOUT = 600.0
PULL_TIMEOUT = 7200.0    # 約1.2GB を取ってくる
PULL_RETRY = 3600.0      # 取ってこられなかったら、これだけ待ってからやり直す
CHECK_EVERY = 60.0
K_DEFAULT = 20
K_MAX = 200
CONTEXT = 2              # 前後に付ける行の数
DIGEST_PREFIX = "digest|"  # 仕事のまとめの行の id の頭
DIGEST_EVERY = 300.0     # 仕事のまとめのファイルが変わったか見る間（秒）
DAY = re.compile(r"\d{4}-\d{2}-\d{2}")


def is_local_url(url: str) -> bool:
    parsed = urlparse(url)
    return parsed.scheme == "http" and (parsed.hostname or "") in ("127.0.0.1", "localhost", "::1")


def model_listed(names: list[str], wanted: str) -> bool:
    """Ollama のモデルの一覧に wanted があるか（"bge-m3" は "bge-m3:latest" と同じ）"""
    def plain(name: str) -> str:
        return name if ":" in name else name + ":latest"

    return plain(wanted) in {plain(n) for n in names}


# MARK: - 中身の読み方（おかしければ ValueError）


def _json_object(data: bytes) -> dict:
    try:
        body = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as error:
        raise ValueError("中身が JSON ではありません") from error
    if not isinstance(body, dict):
        raise ValueError("中身が JSON ではありません")
    return body


def _optional_text(value, what: str, limit: int = 200) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise ValueError(f"{what} は文字か null です")
    return value[:limit]


def parse_index(data: bytes) -> list[dict]:
    """POST /index の {"items": [{"id", "day", "time", "speaker", "text", "work", "conversation"}…]}"""
    body = _json_object(data)
    items = body.get("items")
    if not isinstance(items, list):
        raise ValueError("items がありません")
    if len(items) > INDEX_LIMIT:
        raise ValueError(f"items が多すぎます（{INDEX_LIMIT} 個まで）")
    out = []
    for i, item in enumerate(items):
        if not isinstance(item, dict):
            raise ValueError(f"items[{i}] が JSON のまとまりではありません")
        ident = item.get("id")
        if not isinstance(ident, str) or not ident or len(ident) > ID_MAX:
            raise ValueError(f"items[{i}].id は 1〜{ID_MAX} 文字の文字です")
        day = item.get("day")
        if not isinstance(day, str) or not DAY.fullmatch(day):
            raise ValueError(f"items[{i}].day は YYYY-MM-DD です")
        moment = item.get("time")
        if isinstance(moment, bool) or not isinstance(moment, (int, float)) or moment != moment:
            raise ValueError(f"items[{i}].time は数（秒）です")
        text = item.get("text")
        if not isinstance(text, str):
            raise ValueError(f"items[{i}].text は文字です")
        work = item.get("work", False)
        if not isinstance(work, bool):
            raise ValueError(f"items[{i}].work は true か false です")
        out.append({"id": ident, "day": day, "time": float(moment),
                    "speaker": _optional_text(item.get("speaker"), f"items[{i}].speaker"),
                    "text": text.strip()[:TEXT_MAX], "work": work,
                    "conversation": _optional_text(item.get("conversation"), f"items[{i}].conversation")})
    return out


def parse_search(data: bytes) -> dict:
    """POST /search の {"query", "k", "from", "to", "speaker", "include_work"}"""
    body = _json_object(data)
    query = body.get("query")
    if not isinstance(query, str) or not query.strip():
        raise ValueError("query がありません")
    k = body.get("k", K_DEFAULT)
    if isinstance(k, bool) or not isinstance(k, (int, float)):
        raise ValueError("k は数です")
    out = {"query": query.strip()[:TEXT_MAX], "k": int(min(K_MAX, max(1, k)))}
    for key in ("from", "to"):
        value = body.get(key)
        if value is not None and (not isinstance(value, str) or not DAY.fullmatch(value)):
            raise ValueError(f"{key} は YYYY-MM-DD です")
        out[key] = value
    speaker = body.get("speaker")
    if speaker is not None and not isinstance(speaker, str):
        raise ValueError("speaker は文字です")
    out["speaker"] = speaker.strip() if speaker and speaker.strip() else None
    include = body.get("include_work", True)
    if not isinstance(include, bool):
        raise ValueError("include_work は true か false です")
    out["include_work"] = include
    for key in ("include_digest", "only_digest"):  # 仕事のまとめの行（既定は出さない）
        value = body.get(key, False)
        if not isinstance(value, bool):
            raise ValueError(f"{key} は true か false です")
        out[key] = value
    return out


def parse_forget(data: bytes) -> list[str]:
    body = _json_object(data)
    ids = body.get("ids")
    if not isinstance(ids, list) or not all(isinstance(i, str) for i in ids):
        raise ValueError("ids は文字の並びです")
    if len(ids) > 10_000:
        raise ValueError("ids が多すぎます（10000 個まで）")
    return ids


# MARK: - 数の並び


def normalize(vectors: np.ndarray) -> np.ndarray:
    vectors = np.asarray(vectors, dtype=np.float32)
    if vectors.ndim == 1:
        vectors = vectors[None, :]
    norms = np.linalg.norm(vectors, axis=1, keepdims=True)
    norms[~np.isfinite(norms) | (norms <= 0)] = 1.0
    return vectors / norms


def to_blob(vector: np.ndarray) -> bytes:
    return np.asarray(vector, dtype="<f2").tobytes()


def from_blob(blob: bytes) -> np.ndarray:
    return np.frombuffer(blob, dtype="<f2")


def text_hash(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:32]


class OllamaEmbedder:
    """この PC の中の Ollama で、文を数の並びにする。
    options を渡すと、頼むたびにその答え（GPU の文字起こしのモデルが載っているあいだは {"num_gpu": 0}）を options に付ける。"""

    def __init__(self, url: str, model: str = EMBED_MODEL, options: Callable[[], dict] | None = None) -> None:
        if not is_local_url(url):
            raise ValueError(f"Ollama の宛先はこの PC の中（http://127.0.0.1:…）にしてください: {url}")
        import urllib.request

        self.url = url.rstrip("/")
        self.model = model
        self.options = options
        # プロキシの設定があっても使わない（この PC の中にだけつなぐ）
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def call(self, path: str, body: dict | None = None, timeout: float = 5.0) -> dict:
        import urllib.request

        data = None if body is None else json.dumps(body, ensure_ascii=False).encode("utf-8")
        request = urllib.request.Request(self.url + path, data=data, method="GET" if body is None else "POST",
                                         headers={"Content-Type": "application/json"})
        with self.opener.open(request, timeout=timeout) as response:
            return json.loads(response.read() or b"{}")

    def models(self) -> list[str]:
        tags = self.call("/api/tags", timeout=3.0)
        return [str(m.get("name") or m.get("model") or "") for m in tags.get("models") or []]

    def pull(self) -> None:
        answer = self.call("/api/pull", {"model": self.model, "stream": False}, timeout=PULL_TIMEOUT)
        if answer.get("error"):
            raise RuntimeError(str(answer["error"]))

    def extra_options(self) -> dict:
        if self.options is None:
            return {}
        try:
            return dict(self.options() or {})
        except Exception:  # noqa: BLE001 — 決められなくても、頼むのはやめない
            return {}

    def embed(self, texts: list[str]) -> np.ndarray:
        out = []
        for i in range(0, len(texts), BATCH):
            part = texts[i:i + BATCH]
            body = {"model": self.model, "input": part, "truncate": True}
            extra = self.extra_options()
            if extra:
                body["options"] = extra
            answer = self.call("/api/embed", body, timeout=EMBED_TIMEOUT)
            if answer.get("error"):
                raise RuntimeError(str(answer["error"]))
            vectors = answer.get("embeddings")
            if not isinstance(vectors, list) or len(vectors) != len(part):
                raise RuntimeError("Ollama から数の並びが返りませんでした")
            out.append(normalize(np.asarray(vectors, dtype=np.float32)))
        if not out:
            return np.zeros((0, 0), dtype=np.float32)
        return np.concatenate(out, axis=0)


# MARK: - 置き場所と探し方


class SemanticIndex:
    def __init__(self, path: Path, embedder, log: Callable[[str], None], enabled: bool = True) -> None:
        self.path = Path(path)
        self.embedder = embedder
        self.model = getattr(embedder, "model", EMBED_MODEL)
        self.log = log
        self.enabled = enabled
        self.lock = threading.Lock()          # SQLite と、数の並びの写し
        self.check_lock = threading.Lock()
        self.ok = False
        self.checked = 0.0
        self.pulling = False
        self.pull_failed = 0.0
        self.error: str | None = None
        self._cache: dict | None = None
        self._digest_stamp = None
        if enabled:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            with self.connect() as db:
                db.execute("CREATE TABLE IF NOT EXISTS items (id TEXT PRIMARY KEY, day TEXT NOT NULL, time REAL NOT NULL,"
                           " speaker TEXT, text TEXT NOT NULL, work INTEGER NOT NULL, conversation TEXT,"
                           " model TEXT NOT NULL, hash TEXT NOT NULL, vec BLOB NOT NULL)")
                db.execute("CREATE INDEX IF NOT EXISTS items_conversation ON items (conversation, time)")
                db.execute("CREATE INDEX IF NOT EXISTS items_day ON items (day)")

    @contextlib.contextmanager
    def connect(self):
        """SQLite につなぐ。うまくいけば書いたものを確定し、最後に必ず閉じる。"""
        db = sqlite3.connect(str(self.path), timeout=30)
        try:
            db.execute("PRAGMA journal_mode=WAL")
            yield db
            db.commit()
        except BaseException:
            db.rollback()
            raise
        finally:
            db.close()

    # MARK: 使えるか

    def available(self, force: bool = False) -> bool:
        """Ollama が答え、埋め込みのモデルが入っているか。force でなければ前の答えをすぐ返し、古ければ裏で確かめ直す。"""
        if not self.enabled:
            return False
        if not force:
            if time.time() - self.checked >= CHECK_EVERY and not self.check_lock.locked():
                threading.Thread(target=self.available, kwargs={"force": True}, daemon=True).start()
            return self.ok
        with self.check_lock:
            before = self.ok
            try:
                names = self.embedder.models()
                self.ok = model_listed(names, self.model)
                if not self.ok:
                    self.start_pull()
            except Exception:  # noqa: BLE001 — Ollama が無ければ使わないだけ
                self.ok = False
            self.checked = time.time()
            if self.ok and not before:
                self.log(f"意味で探す機能を使えます（Ollama の {self.model}）")
            return self.ok

    def start_pull(self) -> None:
        """Ollama はあるのに埋め込みのモデルが無ければ、裏で取ってきてもらう（約1.2GB、1回だけ）。
        取ってこられなかったら、PULL_RETRY 秒はやり直さない。"""
        if self.pulling or time.time() - self.pull_failed < PULL_RETRY:
            return
        self.pulling = True

        def run() -> None:
            started = time.time()
            self.log(f"意味で探すためのモデル（Ollama の {self.model}、約1.2GB）を取ってきてもらいます。初回だけです。")
            try:
                self.embedder.pull()
                self.log(f"{self.model} を取ってきました（{time.time() - started:.0f} 秒）")
                self.error = None
            except Exception as error:  # noqa: BLE001
                self.error = f"{self.model} を取ってこられませんでした: {error}"
                self.pull_failed = time.time()
                self.log(self.error)
            finally:
                self.pulling = False
                self.checked = 0.0
            self.available(force=True)

        threading.Thread(target=run, name="semantic-pull", daemon=True).start()

    def status(self) -> dict:
        count = 0
        if self.enabled:
            try:
                with self.lock, self.connect() as db:
                    count = int(db.execute("SELECT COUNT(*) FROM items").fetchone()[0])
            except sqlite3.Error:
                count = 0
        return {"count": count, "model": self.model, "ready": self.available()}

    # MARK: 置く・消す

    def index(self, items: list[dict]) -> int:
        """行を数の並びにして置く（同じ id は置き換える）。文が同じで数の並びがあれば、作り直さない。
        文が空の行は、置いてあれば消す。置いた数を返す。"""
        if not items:
            return 0
        latest: dict[str, dict] = {}
        for item in items:
            latest[item["id"]] = item  # 同じ id が2回来たら、後のもの
        empty = [i for i, item in latest.items() if not item["text"]]
        rows = [item for item in latest.values() if item["text"]]
        with self.lock, self.connect() as db:
            known = {}
            ids = [item["id"] for item in rows]
            for start in range(0, len(ids), 500):
                part = ids[start:start + 500]
                marks = ",".join("?" * len(part))
                for ident, model, digest in db.execute(
                        f"SELECT id, model, hash FROM items WHERE id IN ({marks})", part):
                    known[ident] = (model, digest)
        need = [item for item in rows if known.get(item["id"]) != (self.model, text_hash(item["text"]))]
        vectors = self.embedder.embed([item["text"] for item in need]) if need else None
        with self.lock, self.connect() as db:
            for n, item in enumerate(need):
                db.execute("INSERT OR REPLACE INTO items (id, day, time, speaker, text, work, conversation, model, hash, vec)"
                           " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                           (item["id"], item["day"], item["time"], item["speaker"], item["text"], int(item["work"]),
                            item["conversation"], self.model, text_hash(item["text"]), to_blob(vectors[n])))
            fresh = {item["id"] for item in need}
            for item in rows:
                if item["id"] in fresh:
                    continue
                db.execute("UPDATE items SET day=?, time=?, speaker=?, work=?, conversation=? WHERE id=?",
                           (item["day"], item["time"], item["speaker"], int(item["work"]), item["conversation"], item["id"]))
            for ident in empty:
                db.execute("DELETE FROM items WHERE id=?", (ident,))
            self._cache = None
        return len(rows)

    def sync_digests(self, lines: list[dict]) -> int:
        """仕事のまとめの行（mothership.digest_lines の形）を置き直す。無くなった行は消す。置いた数を返す。"""
        import mothership

        items = [{"id": mothership.digest_id(line["day"], line["text"]), "day": line["day"], "time": 0.0,
                  "speaker": line.get("heading") or None, "text": line["text"][:TEXT_MAX], "work": True,
                  "conversation": None} for line in lines]
        count = self.index(items)
        keep = {item["id"] for item in items}
        with self.lock, self.connect() as db:
            old = [r[0] for r in db.execute("SELECT id FROM items WHERE substr(id, 1, ?) = ?",
                                            (len(DIGEST_PREFIX), DIGEST_PREFIX))]
            for ident in old:
                if ident not in keep:
                    db.execute("DELETE FROM items WHERE id=?", (ident,))
            self._cache = None
        return count

    def digest_tick(self, read: Callable[[], dict | None]) -> int | None:
        """仕事のまとめのファイルが変わっていたら置き直す。何もしなかったら None。read は mothership.read_digests の形の答え"""
        if not self.enabled:
            return None
        found = read()
        if found is None or found["stamp"] == self._digest_stamp:
            return None
        if not self.available():
            return None  # Ollama が使えるようになったら、次の回でやる
        count = self.sync_digests(found["lines"])
        self._digest_stamp = found["stamp"]
        self.log(f"意味で探す: 仕事のまとめ {count} 行を置き直しました")  # 文の中身は書かない
        return count

    def start_digest_sync(self, read: Callable[[], dict | None]) -> None:
        """仕事のまとめを、裏で DIGEST_EVERY 秒ごとに見て置き直す（Ollama の GPU の使い方は、頼むたびの options のまま）"""
        def run() -> None:
            time.sleep(30.0)
            while True:
                try:
                    self.digest_tick(read)
                except Exception as error:  # noqa: BLE001 — 何があっても受け付けは続ける
                    self.log(f"仕事のまとめを索引にできませんでした: {type(error).__name__}")
                time.sleep(DIGEST_EVERY)

        threading.Thread(target=run, name="semantic-digest", daemon=True).start()

    def forget(self, ids: list[str]) -> int:
        removed = 0
        with self.lock, self.connect() as db:
            for start in range(0, len(ids), 500):
                part = ids[start:start + 500]
                marks = ",".join("?" * len(part))
                removed += db.execute(f"DELETE FROM items WHERE id IN ({marks})", part).rowcount
            self._cache = None
        return removed

    # MARK: 探す

    def _matrix(self) -> dict:
        """数の並びをまとめた写し（self.lock を持って呼ぶ）。置く・消すたびに作り直す。"""
        if self._cache is not None:
            return self._cache
        ids, days, speakers, works, blobs = [], [], [], [], []
        with self.connect() as db:
            for ident, day, speaker, work, vec in db.execute(
                    "SELECT id, day, speaker, work, vec FROM items WHERE model=?", (self.model,)):
                ids.append(ident)
                days.append(day)
                speakers.append("" if ident.startswith(DIGEST_PREFIX) else (speaker or "").casefold())
                works.append(bool(work))
                blobs.append(vec)
        dim = len(blobs[0]) // 2 if blobs else 0
        matrix = np.frombuffer(b"".join(b for b in blobs if len(b) == dim * 2), dtype="<f2").reshape(-1, dim) \
            if blobs else np.zeros((0, 0), dtype="<f2")
        keep = [i for i, b in enumerate(blobs) if len(b) == dim * 2]
        self._cache = {"ids": [ids[i] for i in keep], "days": np.array([days[i] for i in keep], dtype=object),
                       "speakers": [speakers[i] for i in keep],
                       "digests": np.array([ids[i].startswith(DIGEST_PREFIX) for i in keep], dtype=bool), "works": np.array([works[i] for i in keep], dtype=bool),
                       "matrix": matrix, "dim": dim}
        return self._cache

    def search(self, request: dict) -> list[dict]:
        query = normalize(self.embedder.embed([request["query"]]))[0]
        with self.lock:
            cache = self._matrix()
            if not cache["ids"] or cache["dim"] != len(query):
                return []
            mask = np.ones(len(cache["ids"]), dtype=bool)
            if request.get("from"):
                mask &= np.array([d >= request["from"] for d in cache["days"]], dtype=bool)
            if request.get("to"):
                mask &= np.array([d <= request["to"] for d in cache["days"]], dtype=bool)
            if not request.get("include_work", True):
                mask &= ~cache["works"]
            if request.get("only_digest"):
                mask &= cache["digests"]
            elif not request.get("include_digest", False):
                mask &= ~cache["digests"]
            if request.get("speaker"):
                wanted = request["speaker"].casefold()
                mask &= np.array([wanted in s for s in cache["speakers"]], dtype=bool) & ~cache["digests"]
            rows = np.flatnonzero(mask)
            if not len(rows):
                return []
            scores = np.empty(len(rows), dtype=np.float32)
            for start in range(0, len(rows), 20000):
                part = rows[start:start + 20000]
                scores[start:start + len(part)] = cache["matrix"][part].astype(np.float32) @ query
            k = min(request["k"], len(rows))
            top = np.argpartition(-scores, k - 1)[:k]
            top = top[np.argsort(-scores[top], kind="stable")]
            picked = [(cache["ids"][rows[i]], float(scores[i])) for i in top]
            with self.connect() as db:
                hits = []
                for ident, score in picked:
                    row = db.execute("SELECT id, day, time, speaker, text, work, conversation FROM items WHERE id=?",
                                     (ident,)).fetchone()
                    if row is None:
                        continue
                    hit = self._row(row)
                    hit["score"] = round(score, 4)
                    if hit.get("kind") != "work-digest":
                        hit["context"] = self._context(db, hit)
                    hits.append(hit)
        return hits

    @staticmethod
    def _row(row) -> dict:
        ident, day, moment, speaker, text, work, conversation = row
        if ident.startswith(DIGEST_PREFIX):  # 仕事のまとめの行（時刻・話し手・会話は無い）
            return {"id": ident, "kind": "work-digest", "day": day, "heading": speaker or "", "text": text, "work": True}
        return {"id": ident, "day": day, "time": moment, "speaker": speaker, "text": text, "work": bool(work),
                "conversation": conversation}

    def _context(self, db: sqlite3.Connection, hit: dict) -> list[dict]:
        """同じ会話の、前後 CONTEXT 行ずつ（時刻の順）。会話が分からなければ空。"""
        if not hit.get("conversation"):
            return []
        columns = "id, day, time, speaker, text, work, conversation"
        before = db.execute(f"SELECT {columns} FROM items WHERE conversation=? AND id<>? AND"
                            " (time<? OR (time=? AND id<?)) ORDER BY time DESC, id DESC LIMIT ?",
                            (hit["conversation"], hit["id"], hit["time"], hit["time"], hit["id"], CONTEXT)).fetchall()
        after = db.execute(f"SELECT {columns} FROM items WHERE conversation=? AND id<>? AND"
                           " (time>? OR (time=? AND id>?)) ORDER BY time, id LIMIT ?",
                           (hit["conversation"], hit["id"], hit["time"], hit["time"], hit["id"], CONTEXT)).fetchall()
        out = []
        for offset, row in zip(range(-len(before), 0), reversed(before)):
            item = self._row(row)
            item["offset"] = offset
            out.append(item)
        for offset, row in enumerate(after, start=1):
            item = self._row(row)
            item["offset"] = offset
            out.append(item)
        return out


# MARK: - 受け付け（lifelog_pc.py の Handler から呼ぶ。合言葉は確かめてある）

POSTS = ("/index", "/search", "/forget")
BODY_LIMIT = 20_000_000


def http_status(handler, index: SemanticIndex | None) -> None:
    if index is None or not index.enabled:
        handler.send_json(200, {"count": 0, "model": EMBED_MODEL, "ready": False})
        return
    try:
        handler.send_json(200, index.status())
    except Exception as error:  # noqa: BLE001
        handler.send_json(500, {"error": f"数えられませんでした: {error}"})


def http_post(handler, index: SemanticIndex | None, path: str, data: bytes, log: Callable[[str], None]) -> None:
    if index is None or not index.enabled:
        handler.send_json(503, {"error": "意味で探す機能は使わない設定です"})
        return
    try:
        request = parse_forget(data) if path == "/forget" else parse_index(data) if path == "/index" \
            else parse_search(data)
    except ValueError as error:
        handler.send_json(400, {"error": str(error)})
        return
    started = time.time()
    try:
        if path == "/forget":
            removed = index.forget(request)
            log(f"意味で探す: {removed} 行を消しました")
            handler.send_json(200, {"forgotten": removed})
            return
        if not index.available(force=not index.ok):
            state = "取ってきてもらっている最中です" if index.pulling else "ありません"
            handler.send_json(503, {"error": f"Ollama が動いていないか、{index.model} が{state}"})
            return
        if path == "/index":
            count = index.index(request)
            # 文の中身は記録に書かない
            log(f"意味で探す: {len(request)} 行を受け、{count} 行を置きました（{time.time() - started:.1f} 秒）")
            handler.send_json(200, {"indexed": count})
        else:
            hits = index.search(request)
            log(f"意味で探す: {len(hits)} 件見つけました（{time.time() - started:.1f} 秒）")
            handler.send_json(200, {"hits": hits})
    except Exception as error:  # noqa: BLE001 — 何があっても受け付けは続ける
        log(f"意味で探す機能でつまずきました: {error!r}")
        handler.send_json(503, {"error": f"うまくいきませんでした: {error}"})
