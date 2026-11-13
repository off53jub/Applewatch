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
from typing import Callable

import claude
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
          "photos": "写真", "location": "場所", "work-digest": "仕事のまとめ", "money": "お金"}
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
    },
    "required": ["queries", "money", "money_words"], "additionalProperties": False,
}
ANSWER_SYSTEM = (
    "あなたは、本人の記録から見つかった抜き出しだけをもとに、質問に日本語で答える係です。\n"
    "入力は JSON で、question（質問）・today（今日）・snippets（抜き出し。番号 n・日 day・時刻 time・系統 source・"
    "文 text・前後の文 context）があります。\n"
    "決まり:\n"
    "- 抜き出しに書いてあることだけで答えます。書いていないことは推測で足しません。分からなければ、分からないと書きます。\n"
    "- 答えの文の中で、もとにした抜き出しを [番号] で示します。日付と、どこの記録か（LINE・予定・写真・お金 など）も添えます。\n"
    "- 時刻の前に + が付いたものは、録音を始めてからの時間で、時刻ではありません。\n"
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


def gather(groups: list[list[dict]]) -> list[dict]:
    """探し方ごとの結果を、新しい日から代わる代わる取り、同じものは1つにして、長さの上限まで"""
    ordered = [sorted(g, key=lambda h: (h["day"], h["time"]), reverse=True) for g in groups]
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
            text = hit["text"][:SNIPPET_MAX]
            context = [c[:CONTEXT_MAX] for c in hit.get("context") or []][:2]
            size = len(text) + sum(len(c) for c in context) + 40
            if total + size > TOTAL_MAX:
                return picked
            total += size
            picked.append({"n": len(picked) + 1, "day": hit["day"], "time": hit["time"], "source": hit["source"],
                           "text": text, "context": context})
            if len(picked) >= SNIPPETS:
                break
        index += 1
    return picked


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
    groups: list[list[dict]] = []
    budget = min(SEARCH_TIMEOUT, left() - ANSWER_MIN)
    if plan["queries"] and budget > 1:
        with concurrent.futures.ThreadPoolExecutor(max_workers=QUERIES) as pool:
            futures = [pool.submit(run_search, config, q, budget) for q in plan["queries"]]
            for future in futures:
                try:
                    groups.append(future.result(timeout=budget + 5))
                except Exception:  # noqa: BLE001 — 1 つが動かなくても、ほかで答える
                    groups.append([])
    if plan["money"]:
        frm = min([q["from"] for q in plan["queries"]] or [(day - datetime.timedelta(days=DEFAULT_DAYS)).isoformat()])
        to = max([q["to"] for q in plan["queries"]] or [day.isoformat()])
        groups.append(money_lines(mothership.home(config), frm, to, plan["money_words"]))
    snippets = gather(groups)
    by_source: dict[str, int] = {}
    for s in snippets:
        by_source[s["source"]] = by_source.get(s["source"], 0) + 1
    searched = {"queries": len(plan["queries"]) + (1 if plan["money"] else 0), "snippets": len(snippets),
                "by_source": by_source}
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
                "label": LABELS.get(s["source"], s["source"]), "text": s["text"][:160]} for s in chosen]
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
        f"抜き出し {reply['searched']['snippets']} 件・{'答えた' if reply['found'] else '見つからない'}・{reply['seconds']} 秒")
    handler.send_json(200, reply)
