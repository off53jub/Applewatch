"""LifeLog PC: 母艦の文も意味で探す（強化案 42・48。2026-11-15）。

いままで意味で探せたのは、アプリが送ってきた記録（semantic.py の items の表）と仕事のまとめだけだった。
ここでは、母艦（mothership.home。ふだんは D:\\Lifelog）の次のファイルを**読むだけ**で、段落・発言のまとまりごとに
この PC の Ollama の bge-m3 で数の並びにし、同じ semantic.db の**別の表**（mother_chunks・mother_files）に置く。
アプリの記録の表（items）には触らないので、POST /search の答えには混ざらない。

  系統（source）  場所（母艦の中）                         まとめ方
  line          archive/line/YYYY/MM/DD.md               相手（## の見出し）ごとに、続く発言を CHUNK_CHARS まで
  plaud         archive/plaud/YYYY/MM/DD_<題>.md          録音の文（audio/・whisper/ は読まない）を CHUNK_CHARS まで
  lifelog-pc    archive/lifelog-pc/YYYY/MM/DD.md         見出しの節ごとに、箇条書き・段落を CHUNK_CHARS まで
  digest        digests/daily/YYYY-MM-DD.md              同上（頭の --- の間は読まない）
  weekly        digests/weekly/YYYY-Www.md               同上（日はその週の月曜）
  wishlist      state/WISHLIST.md                        同上（日はファイルの更新日）
  decisions     state/DECISIONS.md                       同上
  profile       state/profile.md                         同上
  people        people/*.md                              同上（日はファイルの更新日）

決まり:
- 置き直すのは、ファイルの更新時刻か大きさが変わったものだけ。文が同じまとまりは数の並びを作り直さない（hash で使い回す）。
  無くなったファイルのまとまりは消す。
- 重い仕事をしてよい時間（00:00〜05:00 と 08:30〜18:00）は続けて置き、それ以外は TICK_IDLE 秒ごとに SMALL_BUDGET 個まで。
- GPU の使い方は、渡された埋め込みの係（semantic.OllamaEmbedder の options）のまま（文字起こしのモデルが載っていれば CPU）。
- 文の中身は記録（log.txt）に書かない（数と秒だけ）。母艦には何も書かない。
- 探す: search(問い, k, sources, from, to) → [{"id", "source", "day", "time", "label", "path", "text", "score"}]。
  askmother.py が、言葉で探した結果といっしょに使う（同じものは1つにしてから Claude へ。ファイルの丸ごとは渡さない）。

測るとき（中身は出さない。数と秒と大きさだけ）:
    python pc/mothersearch.py --measure --days 2026-11-11,2026-11-12,2026-11-13 [--with-state] [--db 一時のファイル]
"""

from __future__ import annotations

import contextlib
import datetime
import os
import re
import sqlite3
import threading
import time
from pathlib import Path
from typing import Callable, Iterable

import numpy as np

import semantic

CHUNK_CHARS = 600           # 1 つのまとまりの長さの上限（文字）
CHUNK_MIN = 6               # これより短い文は置かない
UNIT_MAX = 2000             # 1 つの段落がこれより長ければ、CHUNK_CHARS ごとに切る（それでも 1 まとまりは CHUNK_CHARS まで）
LABEL_MAX = 40
SMALL_BUDGET = 48           # 重い仕事をしない時間に、1 回で置くまとまりの数
HEAVY_BUDGET = 512          # 重い仕事をしてよい時間に、1 回で置くまとまりの数（続けて回す）
TICK_HEAVY = 5.0            # 重い時間で、まだ残っているときの間（秒）
TICK_IDLE = 600.0           # それ以外の間（秒）
SCAN_EVERY = 600.0          # ファイルの一覧を作り直す間（秒）
FIRST_WAIT = 90.0           # 起動してから始めるまで
K_MAX = 50
HEAVY_WINDOWS = ((0, 0, 5, 0), (8, 30, 18, 0))   # (始め時, 分, 終わり時, 分)。終わりは含まない
SOURCES = ("line", "plaud", "lifelog-pc", "digest", "weekly", "wishlist", "decisions", "profile", "people")
STATE_FILES = {"wishlist": "WISHLIST.md", "decisions": "DECISIONS.md", "profile": "profile.md"}
LABELS = {"line": "LINE", "plaud": "PLAUD", "lifelog-pc": "家の PC の会話のまとめ", "digest": "1日のまとめ",
          "weekly": "週のまとめ", "wishlist": "欲しい物リスト", "decisions": "決めごと", "profile": "本人のこと",
          "people": "人のノート"}

DAY_PATH = re.compile(r"^(\d{4})/(\d{2})/(\d{2})(?:_.*)?\.md$")
DIGEST_NAME = re.compile(r"^(\d{4}-\d{2}-\d{2})\.md$")
WEEK_NAME = re.compile(r"^(\d{4})-W(\d{2})\.md$")
LINE_MSG = re.compile(r"^-\s+\*\*(\d{2}:\d{2})\*\*\s*(.+)$")
CLOCK = re.compile(r"^(?:-\s+)?(\d{1,2}:\d{2})(?!\d)")
PLAUD_STAMP = re.compile(r"^(?:.{0,20}?\s)?(\d{2}:\d{2}:\d{2})$")
PLAUD_META = re.compile(r"^-\s+[A-Za-z_]+:\s")
WIKI = re.compile(r"\[\[([^\]|]+)(?:\|([^\]]+))?\]\]")


def heavy_now(now: datetime.datetime | None = None) -> bool:
    """重い仕事をしてよい時間か（00:00〜05:00・08:30〜18:00。この PC の時刻）"""
    now = now or datetime.datetime.now()
    minute = now.hour * 60 + now.minute
    return any(h1 * 60 + m1 <= minute < h2 * 60 + m2 for h1, m1, h2, m2 in HEAVY_WINDOWS)


# MARK: - ファイルの見つけ方


def _rel(base: Path, path: Path) -> str:
    return path.relative_to(base).as_posix()


def _day_files(folder: Path, plaud: bool = False) -> Iterable[Path]:
    """folder/YYYY/MM/ の .md（plaud なら DD_<題>.md、ほかは DD.md）。audio・whisper などの別のフォルダは見ない"""
    if not folder.is_dir():
        return
    for year in sorted(p for p in folder.iterdir() if p.is_dir() and re.fullmatch(r"\d{4}", p.name)):
        for month in sorted(p for p in year.iterdir() if p.is_dir() and re.fullmatch(r"\d{2}", p.name)):
            for f in sorted(month.iterdir()):
                if not f.is_file() or f.suffix != ".md":
                    continue
                if plaud and re.match(r"^\d{2}_.+\.md$", f.name):
                    yield f
                elif not plaud and re.fullmatch(r"\d{2}\.md", f.name):
                    yield f


def discover(base: Path, days: set[str] | None = None, with_state: bool = True) -> list[tuple[str, Path]]:
    """置く対象のファイル [(系統, パス)]。days があれば、その日のファイルだけ（日の無いものは with_state のときだけ）"""
    base = Path(base)
    found: list[tuple[str, Path]] = []
    for source, sub, plaud in (("line", "archive/line", False), ("plaud", "archive/plaud", True),
                               ("lifelog-pc", "archive/lifelog-pc", False)):
        for f in _day_files(base / sub, plaud):
            if days is None or day_of(source, base, f) in days:
                found.append((source, f))
    for f in sorted((base / "digests" / "daily").glob("*.md")) if (base / "digests" / "daily").is_dir() else []:
        if DIGEST_NAME.match(f.name) and (days is None or f.name[:10] in days):
            found.append(("digest", f))
    if days is None or with_state:
        weekly = base / "digests" / "weekly"
        for f in sorted(weekly.glob("*.md")) if weekly.is_dir() else []:
            if WEEK_NAME.match(f.name):
                found.append(("weekly", f))
        for source, name in STATE_FILES.items():
            f = base / "state" / name
            if f.is_file():
                found.append((source, f))
        people = base / "people"
        for f in sorted(people.glob("*.md")) if people.is_dir() else []:
            if f.is_file():
                found.append(("people", f))
    return found


def day_of(source: str, base: Path, path: Path, mtime: float | None = None) -> str:
    """そのファイルの日（YYYY-MM-DD）。日の無いもの（state・people）は更新日"""
    if source in ("line", "plaud", "lifelog-pc"):
        rel = _rel(base / {"line": "archive/line", "plaud": "archive/plaud", "lifelog-pc": "archive/lifelog-pc"}[source],
                   path)
        m = DAY_PATH.match(rel)
        if m:
            return f"{m.group(1)}-{m.group(2)}-{m.group(3)}"
    if source == "digest":
        return path.name[:10]
    if source == "weekly":
        m = WEEK_NAME.match(path.name)
        if m:
            try:
                return datetime.date.fromisocalendar(int(m.group(1)), int(m.group(2)), 1).isoformat()
            except ValueError:
                pass
    stamp = mtime if mtime is not None else path.stat().st_mtime
    return datetime.date.fromtimestamp(stamp).isoformat()


# MARK: - まとめ方（ファイルの文 → [{"label", "time", "text"}]）


def _clean(text: str) -> str:
    text = WIKI.sub(lambda m: m.group(2) or m.group(1), text)
    text = text.replace("**", "")
    return re.sub(r"[ \t\u3000]+", " ", text).strip()


def _pack(units: list[tuple[str, str, str]]) -> list[dict]:
    """[(見出し, 時刻, 文)] を、同じ見出しの続きを CHUNK_CHARS までまとめる。長すぎる文は切る"""
    chunks: list[dict] = []
    cur: dict | None = None
    for label, moment, text in units:
        text = _clean(text)
        if len(text) < 2:
            continue
        pieces = [text[i:i + CHUNK_CHARS] for i in range(0, min(len(text), UNIT_MAX * 50), CHUNK_CHARS)]
        for piece in pieces:
            if cur is not None and cur["label"] == label and len(cur["text"]) + 1 + len(piece) <= CHUNK_CHARS:
                cur["text"] += "\n" + piece
                continue
            if cur is not None:
                chunks.append(cur)
            cur = {"label": label[:LABEL_MAX], "time": moment, "text": piece}
    if cur is not None:
        chunks.append(cur)
    return [c for c in chunks if len(c["text"]) >= CHUNK_MIN]


def chunk_line(text: str) -> list[dict]:
    """LINE: ## 相手 の下の `- **HH:MM** 名前: 本文`。続く行（字下げ）は前の発言の続き"""
    units: list[list[str]] = []
    section = ""
    for raw in text.splitlines():
        s = raw.replace("\r", "")
        stripped = s.strip()
        if not stripped or stripped.startswith(("# ", "> ")):
            continue
        if stripped.startswith("## "):
            section = stripped[3:].strip()
            continue
        m = LINE_MSG.match(stripped)
        if m:
            units.append([section, m.group(1), m.group(2)])
        elif units and units[-1][0] == section and (s.startswith((" ", "\t")) or not stripped.startswith("- ")):
            units[-1][2] += " " + stripped
        else:
            units.append([section, "", stripped[2:] if stripped.startswith("- ") else stripped])
    return _pack([(a, b, c) for a, b, c in units])


def chunk_plaud(text: str, title: str) -> list[dict]:
    """PLAUD のテキスト: 頭の `- key: value` は読まない。`話者 00:00:00` の行は経過時間（+hh:mm:ss）"""
    units: list[tuple[str, str, str]] = []
    moment = ""
    for raw in text.splitlines():
        s = raw.replace("\r", "").strip()
        if not s or s.startswith("#") or PLAUD_META.match(s):
            continue
        stamp = PLAUD_STAMP.match(s)
        if stamp and len(s) <= 40:
            moment = "+" + stamp.group(1)
            continue
        units.append((title, moment, s))
    # 同じ録音の中は見出しが同じなので、続けてまとめる（最初の発言の経過時間を残す）
    return _pack(units)


def chunk_markdown(text: str, prefix: str = "") -> list[dict]:
    """まとめ・state・人のノート: 頭の --- の間・引用（>）・横線は読まない。見出しの節ごとに、箇条書きと段落を"""
    lines = [r.replace("\r", "") for r in text.splitlines()]
    start = 0
    if lines and lines[0].strip() == "---":
        for i in range(1, len(lines)):
            if lines[i].strip() == "---":
                start = i + 1
                break
    units: list[tuple[str, str, str]] = []
    section = prefix
    para: list[str] = []

    def flush() -> None:
        if para:
            body = " ".join(para)
            clock = CLOCK.match(body)
            units.append((section, clock.group(1) if clock else "", body))
            para.clear()

    for raw in lines[start:]:
        s = raw.strip()
        if not s:
            flush()
            continue
        if s.startswith(">") or set(s) <= set("-—=*_ ") or set(s) <= set("|-: "):
            flush()
            continue
        if s.startswith("#"):
            flush()
            heading = s.lstrip("#").strip()
            section = (prefix + " / " + heading) if prefix else heading
            continue
        if s.startswith(("- ", "* ", "+ ")) or re.match(r"^\d+[.)]\s", s):
            flush()
            body = re.sub(r"^(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?", "", s)
            clock = CLOCK.match(body)
            units.append((section, clock.group(1) if clock else "", body))
            continue
        para.append(s)
    flush()
    return _pack(units)


def chunks_for(source: str, path: Path, text: str) -> list[dict]:
    if source == "line":
        return chunk_line(text)
    if source == "plaud":
        title = path.stem[3:] if re.match(r"^\d{2}_", path.stem) else path.stem
        return chunk_plaud(text, title[:LABEL_MAX])
    if source == "people":
        return chunk_markdown(text, prefix=path.stem[:20])
    return chunk_markdown(text)


# MARK: - 置き場所（semantic.db の別の表）


class MotherIndex:
    def __init__(self, db_path: Path, embedder, base: Callable[[], Path], log: Callable[[str], None],
                 ready: Callable[[], bool] | None = None, clock: Callable[[], datetime.datetime] | None = None) -> None:
        self.path = Path(db_path)
        self.embedder = embedder
        self.model = getattr(embedder, "model", semantic.EMBED_MODEL)
        self.base = base
        self.log = log
        self.ready = ready or (lambda: True)
        self.clock = clock or datetime.datetime.now
        self.lock = threading.Lock()
        self._cache: dict | None = None
        self._pending: list[tuple[str, Path]] = []
        self._scanned = 0.0
        self.last = {"at": None, "files": 0, "chunks": 0, "embedded": 0, "seconds": 0.0}
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.connect() as db:
            db.execute("CREATE TABLE IF NOT EXISTS mother_chunks (id TEXT PRIMARY KEY, path TEXT NOT NULL,"
                       " source TEXT NOT NULL, day TEXT NOT NULL, time TEXT, label TEXT, ord INTEGER NOT NULL,"
                       " text TEXT NOT NULL, model TEXT NOT NULL, hash TEXT NOT NULL, vec BLOB NOT NULL)")
            db.execute("CREATE INDEX IF NOT EXISTS mother_chunks_path ON mother_chunks (path)")
            db.execute("CREATE TABLE IF NOT EXISTS mother_files (path TEXT PRIMARY KEY, source TEXT NOT NULL,"
                       " mtime REAL NOT NULL, size INTEGER NOT NULL, chunks INTEGER NOT NULL, indexed_at REAL NOT NULL)")

    @contextlib.contextmanager
    def connect(self):
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

    # MARK: 何が変わったか

    def changed(self, files: list[tuple[str, Path]]) -> tuple[list[tuple[str, Path]], list[str]]:
        """更新時刻か大きさが変わったファイルと、無くなったファイル（相対パス）"""
        base = Path(self.base())
        with self.lock, self.connect() as db:
            known = {p: (m, s) for p, m, s in db.execute("SELECT path, mtime, size FROM mother_files")}
        todo: list[tuple[str, Path]] = []
        seen: set[str] = set()
        for source, path in files:
            rel = _rel(base, path)
            seen.add(rel)
            try:
                st = path.stat()
            except OSError:
                continue
            old = known.get(rel)
            if old is None or abs(old[0] - st.st_mtime) > 1e-6 or old[1] != st.st_size:
                todo.append((source, path))
        gone = [p for p in known if p not in seen]
        return todo, gone

    def forget_paths(self, paths: list[str]) -> int:
        removed = 0
        with self.lock, self.connect() as db:
            for rel in paths:
                removed += db.execute("DELETE FROM mother_chunks WHERE path=?", (rel,)).rowcount
                db.execute("DELETE FROM mother_files WHERE path=?", (rel,))
            self._cache = None
        return removed

    # MARK: 置く

    def index_file(self, source: str, path: Path) -> tuple[int, int]:
        """1 つのファイルを置き直す。(まとまりの数, 新しく数の並びにした数)"""
        base = Path(self.base())
        rel = _rel(base, path)
        st = path.stat()
        raw = path.read_bytes()
        text = raw.decode("utf-8-sig", errors="replace").replace("\ufffd", "")
        chunks = chunks_for(source, path, text)
        day = day_of(source, base, path, st.st_mtime)
        with self.lock, self.connect() as db:
            reuse = {h: v for h, v in db.execute(
                "SELECT hash, vec FROM mother_chunks WHERE path=? AND model=?", (rel, self.model))}
        need = [c for c in chunks if semantic.text_hash(c["text"]) not in reuse]
        if need:
            vectors = self.embedder.embed([c["text"] for c in need])
            for c, v in zip(need, vectors):
                reuse[semantic.text_hash(c["text"])] = semantic.to_blob(v)
        with self.lock, self.connect() as db:
            db.execute("DELETE FROM mother_chunks WHERE path=?", (rel,))
            for n, c in enumerate(chunks):
                digest = semantic.text_hash(c["text"])
                db.execute("INSERT OR REPLACE INTO mother_chunks (id, path, source, day, time, label, ord, text, model, hash, vec)"
                           " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                           (f"m|{rel}|{n}", rel, source, day, c["time"], c["label"], n, c["text"], self.model, digest,
                            reuse[digest]))
            db.execute("INSERT OR REPLACE INTO mother_files (path, source, mtime, size, chunks, indexed_at)"
                       " VALUES (?, ?, ?, ?, ?, ?)", (rel, source, st.st_mtime, st.st_size, len(chunks), time.time()))
            self._cache = None
        return len(chunks), len(need)

    def step(self, budget: int | None = None, files: list[tuple[str, Path]] | None = None) -> dict:
        """変わったファイルを、まとまり budget 個ぶんまで置く（1 つのファイルは途中で切らない）。
        budget が None なら、いまの時刻で決める（重い時間は HEAVY_BUDGET、ほかは SMALL_BUDGET）。"""
        started = time.time()
        if budget is None:
            budget = HEAVY_BUDGET if heavy_now(self.clock()) else SMALL_BUDGET
        base = Path(self.base())
        if files is None:
            if not self._pending or time.time() - self._scanned > SCAN_EVERY:
                todo, gone = self.changed(discover(base))
                if gone:
                    self.forget_paths(gone)
                # 新しい日から先に（いま聞かれそうなもの）
                todo.sort(key=lambda sp: day_of(sp[0], base, sp[1]), reverse=True)
                self._pending = todo
                self._scanned = time.time()
            work = self._pending
        else:
            # 決めたファイルだけ（測るとき・試すとき）。一部なので、ほかのファイルを「無くなった」とは見なさない
            work, _ = self.changed(files)
        done_files, chunks, embedded = 0, 0, 0
        while work and embedded < budget:
            source, path = work.pop(0)
            try:
                count, fresh = self.index_file(source, path)
            except FileNotFoundError:
                continue
            done_files += 1
            chunks += count
            embedded += fresh
        self.last = {"at": round(time.time(), 1), "files": done_files, "chunks": chunks, "embedded": embedded,
                     "seconds": round(time.time() - started, 2), "pending": len(work)}
        return dict(self.last)

    def start(self) -> None:
        """裏で回す。Ollama が使えないあいだは何もしない"""
        def run() -> None:
            time.sleep(FIRST_WAIT)
            while True:
                wait = TICK_IDLE
                try:
                    if self.ready():
                        result = self.step()
                        if result["files"]:
                            self.log(f"意味で探す（母艦）: {result['files']} ファイル・{result['chunks']} まとまり"
                                     f"（新しく {result['embedded']}）を置きました（{result['seconds']} 秒・残り {result['pending']}）")
                        if result["pending"] and heavy_now(self.clock()):
                            wait = TICK_HEAVY
                except Exception as error:  # noqa: BLE001 — 何があっても受け付けは続ける
                    self.log(f"意味で探す（母艦）: 置けませんでした: {type(error).__name__}")
                time.sleep(wait)

        threading.Thread(target=run, name="mother-semantic", daemon=True).start()

    # MARK: 探す

    def _matrix(self) -> dict:
        if self._cache is not None:
            return self._cache
        ids, sources, days, blobs = [], [], [], []
        with self.connect() as db:
            for ident, source, day, vec in db.execute(
                    "SELECT id, source, day, vec FROM mother_chunks WHERE model=?", (self.model,)):
                ids.append(ident)
                sources.append(source)
                days.append(day)
                blobs.append(vec)
        dim = len(blobs[0]) // 2 if blobs else 0
        keep = [i for i, b in enumerate(blobs) if len(b) == dim * 2]
        matrix = np.frombuffer(b"".join(blobs[i] for i in keep), dtype="<f2").reshape(-1, dim) if keep \
            else np.zeros((0, 0), dtype="<f2")
        self._cache = {"ids": [ids[i] for i in keep], "sources": np.array([sources[i] for i in keep], dtype=object),
                       "days": np.array([days[i] for i in keep], dtype=object), "matrix": matrix, "dim": dim}
        return self._cache

    def search(self, query: str, k: int = 12, sources: Iterable[str] | None = None,
               frm: str | None = None, to: str | None = None) -> list[dict]:
        wanted = [s for s in (sources or []) if s in SOURCES]
        vector = semantic.normalize(self.embedder.embed([query]))[0]
        with self.lock:
            cache = self._matrix()
            if not cache["ids"] or cache["dim"] != len(vector):
                return []
            mask = np.ones(len(cache["ids"]), dtype=bool)
            if wanted:
                mask &= np.isin(cache["sources"], wanted)
            # 日の無いもの（state・people）は期間でしぼらない
            dated = ~np.isin(cache["sources"], ["wishlist", "decisions", "profile", "people"])
            if frm:
                mask &= ~dated | np.array([d >= frm for d in cache["days"]], dtype=bool)
            if to:
                mask &= ~dated | np.array([d <= to for d in cache["days"]], dtype=bool)
            rows = np.flatnonzero(mask)
            if not len(rows):
                return []
            scores = cache["matrix"][rows].astype(np.float32) @ vector
            k = max(1, min(int(k), K_MAX, len(rows)))
            top = np.argpartition(-scores, k - 1)[:k]
            top = top[np.argsort(-scores[top], kind="stable")]
            picked = [(cache["ids"][rows[i]], float(scores[i])) for i in top]
            hits = []
            with self.connect() as db:
                for ident, score in picked:
                    row = db.execute("SELECT id, source, day, time, label, path, text FROM mother_chunks WHERE id=?",
                                     (ident,)).fetchone()
                    if row is None:
                        continue
                    hits.append({"id": row[0], "source": row[1], "day": row[2], "time": row[3] or "",
                                 "label": row[4] or "", "path": row[5], "text": row[6], "score": round(score, 4)})
        return hits

    def status(self) -> dict:
        with self.lock, self.connect() as db:
            chunks = int(db.execute("SELECT COUNT(*) FROM mother_chunks").fetchone()[0])
            files = int(db.execute("SELECT COUNT(*) FROM mother_files").fetchone()[0])
            by_source = {s: n for s, n in db.execute("SELECT source, COUNT(*) FROM mother_chunks GROUP BY source")}
        return {"chunks": chunks, "files": files, "by_source": by_source, "last": dict(self.last),
                "heavy_now": heavy_now(self.clock())}


# lifelog_pc.py が始めたもの（askmother.py と /index/status が使う）。始めていなければ None
INDEX: MotherIndex | None = None


def start(db_path: Path, embedder, base: Callable[[], Path], log: Callable[[str], None],
          ready: Callable[[], bool] | None = None) -> MotherIndex:
    global INDEX
    INDEX = MotherIndex(db_path, embedder, base, log, ready)
    INDEX.start()
    return INDEX


# MARK: - 測る（中身は出さない）


def _measure(args) -> int:
    import tempfile

    base = Path(args.base)
    days = {d.strip() for d in args.days.split(",") if d.strip()} if args.days else None
    files = discover(base, days, with_state=args.with_state)
    db_path = Path(args.db) if args.db else Path(tempfile.mkdtemp()) / "mother-measure.db"
    embedder = semantic.OllamaEmbedder(args.ollama)
    index = MotherIndex(db_path, embedder, lambda: base, print)
    by_source: dict[str, int] = {}
    for source, _ in files:
        by_source[source] = by_source.get(source, 0) + 1
    started = time.time()
    first = index.step(budget=10**9, files=files)
    took = time.time() - started
    again = index.step(budget=10**9, files=files)
    with index.connect() as db:
        db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    size = db_path.stat().st_size
    status = index.status()
    text_bytes = sum(p.stat().st_size for _, p in files)
    print(f"ファイル {len(files)}（系統ごと {by_source}）・文 {text_bytes / 1e6:.2f} MB")
    print(f"1 回目: {first['chunks']} まとまり（新しく {first['embedded']}）・{took:.1f} 秒"
          f"（{first['embedded'] / took if took else 0:.1f} 個/秒）")
    print(f"2 回目（変わっていない）: 置き直したファイル {again['files']}・新しく {again['embedded']}・{again['seconds']} 秒")
    print(f"表の大きさ {size / 1e6:.2f} MB（まとまりごとの系統 {status['by_source']}）")
    if args.query:
        t = time.time()
        hits = index.search(args.query, k=10)
        print(f"探す: {len(hits)} 件・{time.time() - t:.2f} 秒（中身は出さない）")
    return 0


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(description="母艦の文を意味で探すための索引を、試しに作って測る（中身は出さない）")
    parser.add_argument("--measure", action="store_true")
    parser.add_argument("--base", default=r"D:\Lifelog")
    parser.add_argument("--days", default="", help="YYYY-MM-DD をカンマで。空なら全部")
    parser.add_argument("--with-state", action="store_true", help="日の無いもの（週のまとめ・state・人のノート）も入れる")
    parser.add_argument("--db", default="", help="測るときの一時のファイル（既定は新しい一時のフォルダ）")
    parser.add_argument("--ollama", default="http://127.0.0.1:11434")
    parser.add_argument("--query", default="", help="試しに探す問い（答えの中身は出さない）")
    args = parser.parse_args()
    if args.measure:
        return _measure(args)
    parser.print_help()
    return 2


if __name__ == "__main__":
    os.environ.setdefault("PYTHONIOENCODING", "utf-8")
    raise SystemExit(main())
