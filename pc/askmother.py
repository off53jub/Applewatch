"""LifeLog PC: 「記録に質問する」を母艦まで（施策 15。2026-11-13）。

POST /ask-mothership {"question": "…"（500 文字まで）} → 母艦（D:\\Lifelog）の全文検索で探して、Claude が答える。
1. Claude（軽いモデル）が、質問から探し方を 1〜4 個作る（言葉・系統・期間。お金の質問なら money）。
2. 母艦の scripts/Search-Lifelog.py を、この PC の Python 3.11 で動かす（言葉は正規表現の文字として扱う）。
   系統は Search-Lifelog.py の決まりのまま: 話した言葉（limitless・plaud・app・line・claude・digest）と記録
   （calendar・health・photos・location・work-digest）。明示したときだけの系統（state・browser など）は使わない。
   お金は Search-Lifelog.py に系統が無いので、母艦の reports/spending/（カードの利用速報と月の支出のまとめ）の行を、
   ここで言葉で探す（系統の名前は money）。
3. Claude（標準のモデル）が、見つかった抜き出しだけをもとに日本語で答え、使った抜き出しの番号を返す。
   何も見つからなければ Claude には頼まず「見つかりませんでした」と返す。
決まり: 全部で DEADLINE（約 60 秒）まで。抜き出しは 1 件 SNIPPET_MAX 文字・全部で TOTAL_MAX 文字・SNIPPETS 件まで。
答え: {"available": true, "found": bool, "answer": str,
       "sources": [{"n", "day"（YYYY-MM-DD。月のまとめは YYYY-MM）, "time", "source", "label", "text"}],
       "searched": {"queries": int, "snippets": int, "by_source": {系統: 件数}}, "seconds": float}
Claude に頼めなければ、claude.py と同じ番号（402・403・429・502・503）と {"error"}。
記録（log.txt）には数だけを書く（質問・答え・抜き出しの中身は書かない）。母艦の中身は職場のものも含むので work=True で頼む
（家の PC の claude-config.json の "work": false なら 403）。

2026-11-15（強化案 42・48）:
- 言葉で探す（Search-Lifelog.py）のと同時に、母艦の文の意味の索引（mothersearch.py。LINE・PLAUD・家の PC の会話のまとめ・
  1日と週のまとめ）も、質問の文そのもので探す。言葉で探した行が、意味で見つけたまとまりの中に入っていれば、行のほうは落とす
  （同じものを 2 回渡さない）。抜き出しの長さの上限はそのまま（意味のまとまりは 1 件 SEMANTIC_SNIPPET_MAX 文字まで）。
- 探し方の Claude が、質問が人・欲しい物・決めごと・本人のことについてかを topics で返す。そのときは、
  state/WISHLIST.md・state/DECISIONS.md・state/profile.md・people/*.md のうち**質問に意味の近い節だけ**を足す
  （意味の索引が使えないときは、探し方の言葉を含む節だけ）。ファイルを丸ごと渡すことはしない。
- 答えの sources の 1 件に、省略できる "path"（母艦の中の場所）が付くことがある。searched に "semantic"（意味で見つけて
  渡した数）と "topics" が付く。
"""

from __future__ import annotations

import concurrent.futures
import datetime
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Callable, Iterable

import claude
import mothersearch
import mothership

POSTS = ("/ask-mothership",)
FEATURE = "askmother"
BODY_LIMIT = 8192
QUESTION_MAX = 500
DEADLINE = 60.0
PLAN_TIMEOUT = 15.0
SEARCH_TIMEOUT = 25.0
ANSWER_MIN = 10.0               # 答えを作るのに残しておく秒
QUERIES = 4
WORDS = 3
SEARCH_LIMIT = 30               # 1 つの探し方で受け取る数（Search-Lifelog.py の --limit）
SNIPPET_MAX = 240
CONTEXT_MAX = 120
SNIPPETS = 60
TOTAL_MAX = 14_000
MONEY_LIMIT = 30
DEFAULT_DAYS = 90
SOURCES = ("limitless", "plaud", "app", "line", "claude", "digest",
           "calendar", "health", "photos", "location", "work-digest")
LABELS = {"limitless": "録音（Limitless）", "plaud": "PLAUD", "plaud-whisper": "PLAUD", "app": "アプリの記録",
          "line": "LINE", "claude": "Claude との会話", "digest": "1日のまとめ", "calendar": "予定", "health": "体調",
          "photos": "写真", "location": "場所", "work-digest": "仕事のまとめ", "money": "お金",
          **{k: v for k, v in mothersearch.LABELS.items() if k not in ("line", "plaud", "digest")}}
# 2026-11-15（強化案 42・48）: 意味で探す
SEMANTIC_K = 12                 # 会話・まとめから意味で取る数
SEMANTIC_SOURCES = ("line", "plaud", "lifelog-pc", "digest", "weekly")
TOPIC_K = 6                     # 人・欲しい物・決めごと・本人のことから取る数
SEMANTIC_SNIPPET_MAX = 400
TOPICS = ("person", "wish", "decision", "self")
TOPIC_SOURCES = {"person": ("people", "profile"), "wish": ("wishlist",), "decision": ("decisions",), "self": ("profile",)}
TOPIC_FILES = {"wishlist": "state/WISHLIST.md", "decisions": "state/DECISIONS.md", "profile": "state/profile.md"}
# 試すとき（v14checks_search）は、ここを作り物に替える。None なら mothersearch.INDEX（lifelog_pc.py が始めたもの）
SEMANTIC: Callable | None = None
PLAN_PURPOSE = "askmother.plan"
ANSWER_PURPOSE = "askmother.answer"
NOT_FOUND = "母艦の記録（LINE・写真・予定・お金など）には、合うものが見つかりませんでした。"

DAY = re.compile(r"\d{4}-\d{2}-\d{2}")
ANSI = re.compile(r"\x1b\[[0-9;]*m")
HEADER = re.compile(r"^(\d{4}-\d{2}-\d{2}) (\S+)\s+\(([A-Za-z0-9_-]+)\)$")
CARD_ROW = re.compile(r"^\|\s*(\d{2})-(\d{2})\s+(\d{2}:\d{2})\s*\|(.*)\|\s*$")

# 試すとき（v12checks_promises）は、ここを作り物に替える（本物の母艦・Python を動かさない）
RUN: Callable | None = None

PLAN_SYSTEM = (
    "あなたは、本人の記録（会話・LINE・予定・写真・体調・場所・お金）を探す係です。質問から、全文検索の探し方を作ります。\n"
    "入力は JSON で、question（質問）と today（今日の日付）があります。\n"
    "決まり:\n"
    "- queries は 1〜4 個。words は、その行に全部が含まれているはずの短い言葉（1〜3 個。名前・物・場所・できごとの言葉）。"
    "同じ意味の別の言い方は、別の query にします。\n"
    "- sources は探す系統で、次の中から選びます（空なら全部）: limitless・plaud・app（アプリの会話の記録）・line・"
    "claude（Claude との会話）・digest（1日のまとめ）・calendar（予定）・health（体調）・photos（写真）・"
    "location（場所）・work-digest（仕事のまとめ）。\n"
    "- from・to は探す期間（YYYY-MM-DD）。質問に期間が無ければ空にします。\n"
    "- お金（買い物・支払い・使った額）の質問なら money を true にし、money_words にお店や品物の言葉を入れます"
    "（言葉が無ければ空）。\n"
    "- topics は、質問が次のどれについてか（当てはまるものだけ。無ければ空）: person（特定の人のこと・人との関係）・"
    "wish（欲しい物・買いたい物）・decision（決めたこと・方針）・self（本人の好み・暮らし・体のこと）。\n"
    "- 答えは JSON だけです。"
)
PLAN_SCHEMA = {
    "type": "object",
    "properties": {
        "queries": {"type": "array", "items": {
            "type": "object",
            "properties": {"words": {"type": "array", "items": {"type": "string"}},
                           "sources": {"type": "array", "items": {"type": "string", "enum": list(SOURCES)}},
                           "from": {"type": "string"}, "to": {"type": "string"}},
            "required": ["words", "sources", "from", "to"], "additionalProperties": False}},
        "money": {"type": "boolean"},
        "money_words": {"type": "array", "items": {"type": "string"}},
        "topics": {"type": "array", "items": {"type": "string", "enum": list(TOPICS)}},
    },
    "required": ["queries", "money", "money_words", "topics"], "additionalProperties": False,
}
ANSWER_SYSTEM = (
    "あなたは、本人の記録から見つかった抜き出しだけをもとに、質問に日本語で答える係です。\n"
    "入力は JSON で、question（質問）・today（今日）・snippets（抜き出し。番号 n・日 day・時刻 time・系統 source・"
    "文 text・前後の文 context）があります。\n"
    "決まり:\n"
    "- 抜き出しに書いてあることだけで答えます。書いていないことは推測で足しません。分からなければ、分からないと書きます。\n"
    "- 答えの文の中で、もとにした抜き出しを [番号] で示します。日付と、どこの記録か（LINE・予定・写真・お金 など）も添えます。\n"
    "- 時刻の前に + が付いたものは、録音を始めてからの時間で、時刻ではありません。\n"
    "- source が wishlist（欲しい物リスト）・decisions（決めごと）・profile（本人のこと）・people（人のノート）のものは、"
    "今の状態をまとめた覚え書きで、day はファイルを直した日です（その日に起きたことではありません）。\n"
    "- 話し手の名前は推定で、間違っていることがあります。\n"
    "- 答えは 600 文字まで。used は答えに使った抜き出しの番号、found は質問に答えられる抜き出しがあったか。\n"
    "- 答えは JSON だけです。"
)
ANSWER_SCHEMA = {
    "type": "object",
    "properties": {"answer": {"type": "string"}, "used": {"type": "array", "items": {"type": "integer"}},
                   "found": {"type": "boolean"}},
    "required": ["answer", "used", "found"], "additionalProperties": False,
}


# MARK: - 場所


def script_path(config: dict) -> Path:
    return mothership.home(config) / "scripts" / "Search-Lifelog.py"


def python_path(config: dict) -> Path:
    """母艦のスクリプトを動かす Python（config.json の "mothership_python"。無ければこの利用者の Python 3.11）。
    LifeLogPC.exe 自身（sys.executable）は Python ではないので使わない"""
    value = str(config.get("mothership_python") or os.environ.get("LIFELOG_MOTHERSHIP_PYTHON") or "").strip()
    if value:
        return Path(value)
    return Path.home() / "AppData" / "Local" / "Programs" / "Python" / "Python311" / "python.exe"


def available(config: dict) -> bool:
    try:
        return claude.available() and script_path(config).is_file() and (RUN is not None or python_path(config).is_file())
    except OSError:
        return False


def features(config: dict) -> list[str]:
    return [FEATURE] if available(config) else []


# MARK: - 探し方


def valid_day(text) -> str | None:
    if not isinstance(text, str) or not DAY.fullmatch(text.strip()):
        return None
    try:
        datetime.date.fromisoformat(text.strip())
    except ValueError:
        return None
    return text.strip()


def clean_words(words) -> list[str]:
    out: list[str] = []
    for word in words if isinstance(words, list) else []:
        word = re.sub(r"\s+", "", str(word or ""))[:30]
        if word and word not in out:
            out.append(word)
    return out[:WORDS]


def parse_plan(data, today: datetime.date) -> dict:
    """Claude の探し方を確かめる。{"queries": [{"pattern", "words", "sources", "from", "to"}], "money", "money_words"}"""
    plan = {"queries": [], "money": False, "money_words": []}
    if not isinstance(data, dict):
        return plan
    default_from = (today - datetime.timedelta(days=DEFAULT_DAYS)).isoformat()
    seen = set()
    for query in data.get("queries") or []:
        if not isinstance(query, dict):
            continue
        words = clean_words(query.get("words"))
        if not words:
            continue
        sources = [s for s in query.get("sources") or [] if s in SOURCES]
        frm = valid_day(query.get("from")) or default_from
        to = valid_day(query.get("to")) or today.isoformat()
        if frm > to:
            frm, to = to, frm
        pattern = " ".join(re.escape(w) for w in words)
        key = (pattern, tuple(sources), frm, to)
        if key in seen:
            continue
        seen.add(key)
        plan["queries"].append({"pattern": pattern, "words": words, "sources": list(dict.fromkeys(sources)),
                                "from": frm, "to": to})
        if len(plan["queries"]) >= QUERIES:
            break
    plan["money"] = data.get("money") is True
    plan["money_words"] = clean_words(data.get("money_words"))
    return plan


def parse_topics(data) -> list[str]:
    """探し方の答えの topics（知らないものは落とす）"""
    if not isinstance(data, dict) or not isinstance(data.get("topics"), list):
        return []
    return [t for t in dict.fromkeys(data["topics"]) if t in TOPICS]


def explicit_range(data) -> tuple[str | None, str | None]:
    """Claude が期間を書いたときだけ、その期間（意味で探すのは、期間が無ければ全部の日から）"""
    days_from, days_to = [], []
    for query in (data.get("queries") or []) if isinstance(data, dict) else []:
        if isinstance(query, dict):
            if valid_day(query.get("from")):
                days_from.append(valid_day(query.get("from")))
            if valid_day(query.get("to")):
                days_to.append(valid_day(query.get("to")))
    frm = min(days_from) if days_from else None
    to = max(days_to) if days_to else None
    if frm and to and frm > to:
        frm, to = to, frm
    return frm, to


# MARK: - 母艦の全文検索


def parse_output(text: str) -> list[dict]:
    """Search-Lifelog.py の出力を {"day", "time", "source", "text", "context"} にする"""
    hits: list[dict] = []
    current: dict | None = None
    for raw in ANSI.sub("", text or "").splitlines():
        line = raw.rstrip()
        header = HEADER.match(line.strip())
        if header:
            current = {"day": header.group(1), "time": "" if header.group(2) == "--:--" else header.group(2),
                       "source": header.group(3), "text": "", "context": []}
            hits.append(current)
            continue
        if current is None:
            continue
        if line.startswith("  ★ "):
            current["text"] = line[4:].strip()
        elif line.startswith("    ") and line.strip():
            current["context"].append(line.strip())
        elif line.startswith("---"):
            current = None
    return [h for h in hits if h["text"]]


def run_search(config: dict, query: dict, timeout: float) -> list[dict]:
    """1 つの探し方で Search-Lifelog.py を動かす。動かせなければ空"""
    args = [str(python_path(config)), "-X", "utf8", str(script_path(config)), query["pattern"],
            "--from", query["from"], "--to", query["to"], "--source", ",".join(query["sources"]) or "all",
            "--limit", str(SEARCH_LIMIT), "--context", "1"]
    runner = RUN or subprocess.run
    env = dict(os.environ, PYTHONIOENCODING="utf-8")
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0) if sys.platform == "win32" else 0
    try:
        done = runner(args, capture_output=True, timeout=max(1.0, timeout), env=env, creationflags=flags)
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return []
    out = done.stdout
    if isinstance(out, bytes):
        out = out.decode("utf-8", errors="replace")
    return parse_output(out or "")


def _months(frm: str, to: str) -> list[str]:
    a, b = datetime.date.fromisoformat(frm), datetime.date.fromisoformat(to)
    months, y, m = [], a.year, a.month
    while (y, m) <= (b.year, b.month) and len(months) < 24:
        months.append(f"{y:04d}-{m:02d}")
        y, m = (y + 1, 1) if m == 12 else (y, m + 1)
    return months


def money_lines(base: Path, frm: str, to: str, words: list[str]) -> list[dict]:
    """母艦の reports/spending/ の行（カードの利用速報の明細と、月の支出のまとめ）。words があれば、どれかを含む行だけ"""
    found: list[dict] = []
    for month in _months(frm, to):
        card = base / "reports" / "spending" / "card" / f"{month}.md"
        try:
            text = card.read_text(encoding="utf-8-sig", errors="replace")
        except OSError:
            text = ""
        for line in text.splitlines():
            row = CARD_ROW.match(line.strip())
            if not row:
                continue
            day = f"{month[:4]}-{row.group(1)}-{row.group(2)}"
            if not (frm <= day <= to):
                continue
            cells = [c.strip() for c in row.group(4).split("|")]
            body = " / ".join(c for c in cells if c and c not in ("—", "-"))
            if words and not any(w in body for w in words):
                continue
            found.append({"day": day, "time": row.group(3), "source": "money", "text": "カード: " + body, "context": []})
        report = base / "reports" / "spending" / f"{month}.md"
        try:
            text = report.read_text(encoding="utf-8-sig", errors="replace")
        except OSError:
            text = ""
        section = ""
        for line in text.splitlines():
            s = line.strip()
            if s.startswith("#"):
                section = s.lstrip("# ").strip()
                continue
            if not s or set(s) <= set("|-: ") or s.startswith(">"):
                continue
            if words and not any(w in s for w in words):
                continue
            if not words and section not in ("サマリ", "カテゴリ別"):
                continue
            body = " / ".join(c.strip() for c in s.strip("|").split("|") if c.strip()) if s.startswith("|") else s.lstrip("- ")
            found.append({"day": month, "time": "", "source": "money", "text": f"支出のまとめ（{section}）: {body}",
                          "context": []})
        if len(found) >= MONEY_LIMIT:
            break
    return found[:MONEY_LIMIT]


def gather(groups: list[list[dict]], ranked: Iterable[int] = ()) -> list[dict]:
    """探し方ごとの結果を、新しい日から代わる代わる取り、同じものは1つにして、長さの上限まで。
    ranked の番号の組は、並べ替えない（意味で探した結果は近い順のまま）。1 件の長さは hit の "limit"（無ければ SNIPPET_MAX）"""
    keep_order = set(ranked)
    ordered = [list(g) if i in keep_order else sorted(g, key=lambda h: (h["day"], h["time"]), reverse=True)
               for i, g in enumerate(groups)]
    picked: list[dict] = []
    seen: set[tuple] = set()
    total = 0
    index = 0
    while len(picked) < SNIPPETS and any(index < len(g) for g in ordered):
        for group in ordered:
            if index >= len(group):
                continue
            hit = group[index]
            key = (hit["day"], hit["time"], hit["text"][:80])
            if key in seen:
                continue
            seen.add(key)
            text = hit["text"][:min(int(hit.get("limit") or SNIPPET_MAX), SEMANTIC_SNIPPET_MAX)]
            context = [c[:CONTEXT_MAX] for c in hit.get("context") or []][:2]
            size = len(text) + sum(len(c) for c in context) + 40
            if total + size > TOTAL_MAX:
                return picked
            total += size
            snippet = {"n": len(picked) + 1, "day": hit["day"], "time": hit["time"], "source": hit["source"],
                       "text": text, "context": context}
            if hit.get("path"):
                snippet["path"] = str(hit["path"])[:200]
            picked.append(snippet)
            if len(picked) >= SNIPPETS:
                break
        index += 1
    return picked


# MARK: - 意味で探す（2026-11-15。強化案 42・48）


def semantic_search() -> Callable | None:
    """意味で探す口（search(問い, k, sources, frm, to)）。使えなければ None"""
    if SEMANTIC is not None:
        return SEMANTIC
    index = mothersearch.INDEX
    try:
        if index is not None and index.ready():
            return index.search
    except Exception:  # noqa: BLE001 — 使えなければ、言葉だけで探す
        return None
    return None


def semantic_hits(search: Callable, question: str, sources: Iterable[str], k: int,
                  frm: str | None = None, to: str | None = None) -> list[dict]:
    """意味で探した結果を、抜き出しの形（day・time・source・text・path・limit）にする。動かなければ空"""
    try:
        found = search(question, k=k, sources=list(sources), frm=frm, to=to) or []
    except Exception:  # noqa: BLE001
        return []
    out = []
    for hit in found:
        if not isinstance(hit, dict) or not str(hit.get("text") or "").strip():
            continue
        label = str(hit.get("label") or "").strip()
        text = str(hit["text"]).strip()
        out.append({"day": str(hit.get("day") or ""), "time": str(hit.get("time") or ""),
                    "source": str(hit.get("source") or "semantic"),
                    "text": (f"[{label}] " if label else "") + text, "context": [],
                    "path": str(hit.get("path") or ""), "limit": SEMANTIC_SNIPPET_MAX, "semantic": True})
    return out


def topic_sections(base: Path, topics: list[str], words: list[str]) -> list[dict]:
    """意味の索引が使えないときの代わり: 欲しい物リスト・決めごと・本人のこと・人のノートのうち、
    探し方の言葉を含む節だけ（ファイルの丸ごとは渡さない）"""
    if not topics or not words:
        return []
    sources = {s for t in topics for s in TOPIC_SOURCES.get(t, ())}
    files: list[tuple[str, Path]] = [(s, base / TOPIC_FILES[s]) for s in sorted(sources) if s in TOPIC_FILES]
    if "people" in sources and (base / "people").is_dir():
        files += [("people", p) for p in sorted((base / "people").glob("*.md"))]
    out: list[dict] = []
    for source, path in files:
        try:
            text = path.read_text(encoding="utf-8-sig", errors="replace")
            day = datetime.date.fromtimestamp(path.stat().st_mtime).isoformat()
        except OSError:
            continue
        for chunk in mothersearch.chunks_for(source, path, text):
            if any(w in chunk["text"] or w in chunk["label"] for w in words):
                out.append({"day": day, "time": "", "source": source,
                            "text": (f"[{chunk['label']}] " if chunk["label"] else "") + chunk["text"], "context": [],
                            "path": path.relative_to(base).as_posix(), "limit": SEMANTIC_SNIPPET_MAX})
                if len(out) >= TOPIC_K:
                    return out
    return out


def _core(text: str) -> str:
    """比べるための文（頭の [見出し] と箇条書きの印と空白を落とす）"""
    text = re.sub(r"^(\[[^\]]*\]\s*)+", "", text.strip())
    text = re.sub(r"^[-*]\s+", "", text)
    text = mothersearch.WIKI.sub(lambda m: m.group(2) or m.group(1), text).replace("**", "")
    return re.sub(r"\s+", "", text)


def dedupe(groups: list[list[dict]], semantic_groups: list[list[dict]]) -> list[list[dict]]:
    """言葉で探した行のうち、同じ日の意味のまとまり（渡す長さに切ったもの）の中に入っているものは落とす"""
    covered: dict[str, list[str]] = {}
    for group in semantic_groups:
        for hit in group:
            covered.setdefault(hit["day"], []).append(_core(hit["text"][:SEMANTIC_SNIPPET_MAX]))
    out = []
    for group in groups:
        kept = []
        for hit in group:
            core = _core(hit["text"])[:60]
            if core and len(core) >= 6 and any(core in c for c in covered.get(hit["day"], [])):
                continue
            kept.append(hit)
        out.append(kept)
    return out


# MARK: - 質問に答える


class AskError(Exception):
    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.message = message


def ask(question: str, config: dict, log: Callable[[str], None] | None = None,
        today: datetime.date | None = None, clock: Callable[[], float] = time.monotonic) -> dict:
    started = clock()

    def left() -> float:
        return DEADLINE - (clock() - started)

    if not script_path(config).is_file():
        raise AskError(503, "母艦の検索の道具（Search-Lifelog.py）が見つかりません")
    day = today or datetime.date.today()
    got = claude.call(PLAN_SYSTEM, json.dumps({"question": question, "today": day.isoformat()}, ensure_ascii=False),
                      json=True, max_tokens=800, tier="light", purpose=PLAN_PURPOSE, work=True, schema=PLAN_SCHEMA,
                      timeout=min(PLAN_TIMEOUT, max(1.0, left())), log=log)
    plan = parse_plan(got.get("data"), day)
    topics = parse_topics(got.get("data"))
    sem_from, sem_to = explicit_range(got.get("data"))
    search = semantic_search()
    groups: list[list[dict]] = []
    meaning: list[dict] = []
    topical: list[dict] = []
    budget = min(SEARCH_TIMEOUT, left() - ANSWER_MIN)
    if (plan["queries"] or search is not None) and budget > 1:
        with concurrent.futures.ThreadPoolExecutor(max_workers=QUERIES + 2) as pool:
            futures = [pool.submit(run_search, config, q, budget) for q in plan["queries"]]
            sem_future = pool.submit(semantic_hits, search, question, SEMANTIC_SOURCES, SEMANTIC_K, sem_from, sem_to) \
                if search is not None else None
            topic_sources = [s for t in topics for s in TOPIC_SOURCES.get(t, ())]
            topic_future = pool.submit(semantic_hits, search, question, dict.fromkeys(topic_sources), TOPIC_K) \
                if search is not None and topic_sources else None
            for future in futures:
                try:
                    groups.append(future.result(timeout=budget + 5))
                except Exception:  # noqa: BLE001 — 1 つが動かなくても、ほかで答える
                    groups.append([])
            for future, box in ((sem_future, meaning), (topic_future, topical)):
                if future is None:
                    continue
                try:
                    box.extend(future.result(timeout=budget + 5))
                except Exception:  # noqa: BLE001
                    pass
    if topics and search is None:
        # 意味の索引が使えないときは、探し方の言葉を含む節だけ
        words = list(dict.fromkeys(w for q in plan["queries"] for w in q["words"]))
        topical = topic_sections(mothership.home(config), topics, words)
    groups = dedupe(groups, [meaning, topical])
    if plan["money"]:
        frm = min([q["from"] for q in plan["queries"]] or [(day - datetime.timedelta(days=DEFAULT_DAYS)).isoformat()])
        to = max([q["to"] for q in plan["queries"]] or [day.isoformat()])
        groups.append(money_lines(mothership.home(config), frm, to, plan["money_words"]))
    # 並べ方: 人・欲しい物・決めごと（あれば）→ 言葉で探した行 → 意味で探したまとまり → お金（代わる代わる取る）
    ordered = [topical] + groups[:len(plan["queries"])] + [meaning] + groups[len(plan["queries"]):]
    ranked = {0, len(plan["queries"]) + 1}
    snippets = gather(ordered, ranked=ranked)
    by_source: dict[str, int] = {}
    for s in snippets:
        by_source[s["source"]] = by_source.get(s["source"], 0) + 1
    semantic_keys = {(h["day"], h["text"][:80]) for h in meaning + topical if h.get("semantic")}
    semantic_used = sum(1 for s in snippets if (s["day"], s["text"][:80]) in semantic_keys)
    searched = {"queries": len(plan["queries"]) + (1 if plan["money"] else 0), "snippets": len(snippets),
                "by_source": by_source, "semantic": semantic_used, "topics": topics}
    if not snippets:
        return {"available": True, "found": False, "answer": NOT_FOUND, "sources": [], "searched": searched,
                "seconds": round(clock() - started, 1)}
    if left() < 3:
        raise AskError(504, "時間がかかりすぎました。言葉や期間をしぼって、もう一度聞いてください")
    prompt = json.dumps({"question": question, "today": day.isoformat(), "snippets": snippets}, ensure_ascii=False)
    got = claude.call(ANSWER_SYSTEM, prompt, json=True, max_tokens=1500, tier="standard", purpose=ANSWER_PURPOSE,
                      work=True, schema=ANSWER_SCHEMA, timeout=max(3.0, left()), log=log)
    data = got.get("data") if isinstance(got.get("data"), dict) else {}
    answer = str(data.get("answer") or "").strip()[:1200]
    used = [n for n in data.get("used") or [] if isinstance(n, int) and not isinstance(n, bool) and 1 <= n <= len(snippets)]
    found = data.get("found") is True and bool(answer)
    chosen = [snippets[n - 1] for n in dict.fromkeys(used)] if used else (snippets[:8] if found else [])
    sources = [{"n": s["n"], "day": s["day"], "time": s["time"], "source": s["source"],
                "label": LABELS.get(s["source"], s["source"]), "text": s["text"][:160],
                **({"path": s["path"]} if s.get("path") else {})} for s in chosen]
    return {"available": True, "found": found, "answer": answer or NOT_FOUND, "sources": sources,
            "searched": searched, "seconds": round(clock() - started, 1)}


# MARK: - 受け口


def parse_request(data: bytes) -> str:
    try:
        body = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise ValueError("中身が JSON ではありません") from None
    if not isinstance(body, dict):
        raise ValueError("中身が JSON ではありません")
    question = body.get("question")
    if not isinstance(question, str) or not question.strip():
        raise ValueError("question がありません")
    if len(question) > QUESTION_MAX:
        raise ValueError(f"question が長すぎます（{QUESTION_MAX} 文字まで）")
    return question.strip()


def http_post(handler, config: dict, log: Callable[[str], None]) -> None:
    """POST /ask-mothership（合言葉は lifelog_pc.py が確かめてから呼ぶ）"""
    try:
        length = int(handler.headers.get("Content-Length") or 0)
    except ValueError:
        length = 0
    if length <= 0 or length > BODY_LIMIT:
        handler.discard_body()
        handler.send_json(400 if length <= 0 else 413, {"error": "中身がありません" if length <= 0 else "長すぎます"})
        return
    data = handler.rfile.read(length)
    try:
        question = parse_request(data)
    except ValueError as error:
        handler.send_json(400, {"error": str(error)})
        return
    try:
        reply = ask(question, config, log)
    except claude.ClaudeError as error:
        log(f"{handler.client_address[0]} から /ask-mothership: Claude に頼めませんでした（{error.status}）")
        handler.send_json(error.status, {k: (claude.scrub(v) if isinstance(v, str) else v) for k, v in error.body.items()})
        return
    except AskError as error:
        log(f"{handler.client_address[0]} から /ask-mothership: {error.status}")
        handler.send_json(error.status, {"error": error.message})
        return
    except Exception as error:  # noqa: BLE001 — 何があっても受け付けは続ける
        log(f"/ask-mothership で答えを作れませんでした: {type(error).__name__}")
        handler.send_json(500, {"error": "母艦から答えを作れませんでした"})
        return
    log(f"{handler.client_address[0]} から /ask-mothership: 探し方 {reply['searched']['queries']}・"
        f"抜き出し {reply['searched']['snippets']} 件（意味で {reply['searched'].get('semantic', 0)}）・{'答えた' if reply['found'] else '見つからない'}・{reply['seconds']} 秒")
    handler.send_json(200, reply)
