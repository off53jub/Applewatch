"""LifeLog PC: 夜の読み直し（施策 9。2026-11-13）。

その日の記録の文（職場の会話も。本人の決定）を、夜（quality.py の夜の流れ。01:00〜05:00）に1回、区切って Claude
（claude.py の standard。Message Batches は claude.py に無いので、ふつうの頼み方）に読ませ、次の2つの「候補」を作る。
- 聞き間違い（misheard）: 行の文にそのまま含まれる言葉（wrong）と、たぶん正しい書き方（guess）。
  アプリの「聞き間違いかも」（MisheardBox）にそのまま入る形。GET /night-review で渡す。
- 話し手の取り違え（speaker）: 行を言ったのが今の話し手と違いそうなもの。GET /speaker-doubts の疑いに
  why "night"（アプリの表示は「夜の読み直しから」）として混ぜる（appfeeds.read_speaker_doubts）。
どれも候補だけで、記録は変えない（本人が押したときだけアプリが直す）。名前の付いた人を自動で変えない。
答えは必ず入力に当てて確かめる（wrong・quote が、その番号の行の文にそのまま無ければ捨てる）。
指示文には例文を入れない（データを書き換える言語モデルの約束）。

- 1日の上限: claude-config.json の "night_review_usd"（既定 0.50 ドル）。"night_review": false で使わない。
- 置き場所: HOME/night-review/<日>.json（作り直すたびに置き換え。14 日より古いものは消す）。
- 記録（log.txt）には数とドルだけを書く（文・名前は書かない）。

GET /night-review（features の "nightreview"）→
  {"available": true, "generated_at": ISO, "items": [{"id", "day", "line_time": ISO, "wrong", "guess", "reason"}](≤200)}
"""

from __future__ import annotations

import datetime
import hashlib
import json
import os
import re
import threading
import time
from pathlib import Path
from typing import Callable

import claude

PURPOSE = "night-review"
TIER = "standard"
FOLDER = "night-review"
CHUNK_CHARS = 12_000       # 1回で読ませる文の長さ（JSON にした長さ）
MAX_TOKENS = 4096
DEFAULT_USD = 0.50
KEEP_DAYS = 14
SERVE_DAYS = 3
SERVE_LIMIT = 200
WRONG_MIN, WRONG_MAX = 2, 12
GUESS_MAX = 20
QUOTE_MIN = 4
REASON_MAX = 60
DOUBT_SCORE = 0.55         # 母艦の疑いと並べるときの点（仮）
TIMEOUT = 180.0
SELF_NAME = "自分"         # records.SELF_NAME と同じ

SYSTEM = (
    "あなたは日本語の会話の文字起こしを読み直す係です。\n"
    "入力は JSON で、lines の各行に番号 n・時刻 t・話し手 who・文 text があります。"
    "文は音声認識が書いたもので、誤りを含みます。who が「自分」の行は、録音している本人の言葉です。\n"
    "前後の文脈から、次の2つを探します。\n"
    "1. misheard（聞き間違い）: 音の似た別の言葉に書かれてしまったと強く思われる所。"
    "wrong はその行の text にそのまま含まれる、2〜12 文字の続いた部分です。right はそこを正しく書いたものです（20 文字まで）。\n"
    "2. speaker（話し手の取り違え）: その行を言ったのが who とは別の人だと強く思われる所。"
    "quote はその行の text にそのまま含まれる、4 文字以上の続いた部分です。"
    "suggest は、本人の言葉なのに who が「自分」でないなら self、本人ではない人の言葉なのに who が「自分」なら other です。\n"
    "決まり:\n"
    "- 確かなものだけを出します。迷うものは出しません。無ければ空の並びにします。\n"
    "- wrong と quote は、入力の文から一字も変えずに写します。文を書き足したり言い換えたりしません。\n"
    "- why は短い理由です（30 文字まで）。\n"
    "- 答えは JSON だけです。"
)
SCHEMA = {
    "type": "object",
    "properties": {
        "misheard": {"type": "array", "items": {
            "type": "object",
            "properties": {"n": {"type": "integer"}, "wrong": {"type": "string"}, "right": {"type": "string"},
                           "why": {"type": "string"}},
            "required": ["n", "wrong", "right", "why"], "additionalProperties": False}},
        "speaker": {"type": "array", "items": {
            "type": "object",
            "properties": {"n": {"type": "integer"}, "quote": {"type": "string"},
                           "suggest": {"type": "string", "enum": ["self", "other"]}, "why": {"type": "string"}},
            "required": ["n", "quote", "suggest", "why"], "additionalProperties": False}},
    },
    "required": ["misheard", "speaker"], "additionalProperties": False,
}

_lock = threading.Lock()


def folder(home: Path) -> Path:
    return Path(home) / FOLDER


def iso_ms(ms: int) -> str:
    moment = datetime.datetime(1970, 1, 1, tzinfo=datetime.timezone.utc) + datetime.timedelta(milliseconds=int(ms))
    return moment.strftime("%Y-%m-%dT%H:%M:%S") + f".{int(ms) % 1000:03d}Z"


def _clock(ms: int) -> str:
    return datetime.datetime.fromtimestamp(ms / 1000).strftime("%H:%M:%S")


def settings() -> dict:
    """claude-config.json の "night_review"（使うか）と "night_review_usd"（1日の上限）"""
    out = {"on": True, "usd": DEFAULT_USD}
    try:
        data = json.loads(claude.config_path().read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return out
    if isinstance(data, dict):
        if isinstance(data.get("night_review"), bool):
            out["on"] = data["night_review"]
        usd = data.get("night_review_usd")
        if isinstance(usd, (int, float)) and not isinstance(usd, bool) and 0 <= usd <= 20:
            out["usd"] = float(usd)
    return out


# MARK: - 読ませる行


def day_lines(parsed: dict) -> list[dict]:
    """その日の記録の、読ませる行（テレビなどの声は外す）。{"time", "who", "text", "conversation"}"""
    out = []
    for conversation in parsed.get("conversations") or []:
        if conversation.get("media"):
            continue
        for line in conversation.get("lines") or []:
            text = " ".join(str(line.get("text") or "").split())
            if line.get("media") is not None or not text:
                continue
            out.append({"time": int(line["time"]), "who": str(line.get("speaker") or ""), "text": text,
                        "conversation": int(conversation["start"])})
    out.sort(key=lambda x: x["time"])
    return out


def chunks(lines: list[dict], size: int = CHUNK_CHARS) -> list[list[int]]:
    """行の番号を、JSON にした長さで size ごとに区切る"""
    out: list[list[int]] = [[]]
    length = 0
    for i, line in enumerate(lines):
        cost = len(line["text"]) + len(line["who"]) + 40
        if length + cost > size and out[-1]:
            out.append([])
            length = 0
        out[-1].append(i)
        length += cost
    return [c for c in out if c]


def prompt_for(lines: list[dict], part: list[int]) -> str:
    rows = [{"n": i, "t": _clock(lines[i]["time"]), "who": lines[i]["who"] or "?", "text": lines[i]["text"]} for i in part]
    return json.dumps({"lines": rows}, ensure_ascii=False)


def estimate_usd(prompt: str) -> float:
    """頼む前の見積り（日本語は 1 文字 1 トークンほどとみなす。多めに見る）"""
    price_in, price_out = claude.PRICES[claude.TIERS[TIER]]
    return (len(SYSTEM) + len(prompt)) * price_in / 1_000_000 + MAX_TOKENS * price_out / 1_000_000


# MARK: - 答えを確かめる（入力に当てる）


def _item_id(day: str, kind: str, *parts) -> str:
    digest = hashlib.sha256("|".join([day, kind, *map(str, parts)]).encode("utf-8")).hexdigest()[:12]
    return f"nr-{day.replace('-', '')}-{kind[0]}{digest}"


def ground(data, lines: list[dict], part: list[int], day: str) -> tuple[list[dict], list[dict], int]:
    """Claude の答えから、入力に当たる候補だけを取り出す。(聞き間違い, 話し手の疑い, 捨てた数)"""
    allowed = set(part)
    misheard, speaker, dropped = [], [], 0
    seen: set = set()
    if not isinstance(data, dict):
        return [], [], 0
    for item in data.get("misheard") if isinstance(data.get("misheard"), list) else []:
        n = item.get("n") if isinstance(item, dict) else None
        if isinstance(n, bool) or not isinstance(n, int) or n not in allowed:
            dropped += 1
            continue
        wrong, right = str(item.get("wrong") or "").strip(), " ".join(str(item.get("right") or "").split())
        text = lines[n]["text"]
        if not (WRONG_MIN <= len(wrong) <= WRONG_MAX) or wrong not in text or not right or len(right) > GUESS_MAX \
                or right == wrong or ("m", n, wrong) in seen:
            dropped += 1
            continue
        seen.add(("m", n, wrong))
        misheard.append({"id": _item_id(day, "misheard", lines[n]["time"], wrong), "day": day,
                         "line_time": iso_ms(lines[n]["time"]), "wrong": wrong, "guess": right,
                         "reason": " ".join(str(item.get("why") or "").split())[:REASON_MAX]})
    for item in data.get("speaker") if isinstance(data.get("speaker"), list) else []:
        n = item.get("n") if isinstance(item, dict) else None
        if isinstance(n, bool) or not isinstance(n, int) or n not in allowed:
            dropped += 1
            continue
        quote, suggest = str(item.get("quote") or "").strip(), item.get("suggest")
        line = lines[n]
        if len(quote) < QUOTE_MIN or quote not in line["text"] or suggest not in ("self", "other") or not line["who"] \
                or (suggest == "self" and line["who"] == SELF_NAME) or ("s", n) in seen:
            dropped += 1
            continue
        seen.add(("s", n))
        speaker.append({"day": day, "conversation_start": iso_ms(line["conversation"]), "line_time": iso_ms(line["time"]),
                        "text_head": line["text"][:40], "current": line["who"][:20], "suggest": suggest, "why": "night",
                        "score": DOUBT_SCORE})
    return misheard, speaker, dropped


# MARK: - 1日分


def review_day(day: str, parsed: dict, call: Callable[..., dict] | None = None,
               log: Callable[[str], None] | None = None, cap_usd: float | None = None) -> dict:
    """その日を読み直す（置かない）。call は claude.call と同じ形（試すときに替える）"""
    call = call or claude.call
    cap = settings()["usd"] if cap_usd is None else cap_usd
    lines = day_lines(parsed)
    parts = chunks(lines)
    result = {"version": 1, "day": day, "generated_at": "", "lines": len(lines), "parts": len(parts), "read": 0,
              "calls": 0, "usd": 0.0, "dropped": 0, "stopped": None, "misheard": [], "speaker": []}
    for part in parts:
        prompt = prompt_for(lines, part)
        if result["usd"] + estimate_usd(prompt) > cap:
            result["stopped"] = "1日の上限"
            break
        try:
            got = call(SYSTEM, prompt, json=True, max_tokens=MAX_TOKENS, tier=TIER, purpose=PURPOSE, work=True,
                       schema=SCHEMA, timeout=TIMEOUT, log=log)
        except claude.ClaudeError as error:
            result["stopped"] = claude.scrub(error.body.get("error", ""))[:60]
            if error.status in (402, 403, 503, claude.PURPOSE_OFF):
                break
            continue
        except Exception as error:  # noqa: BLE001 — 読み直せなくても、記録はそのまま
            result["stopped"] = type(error).__name__
            continue
        result["calls"] += 1
        result["usd"] = round(result["usd"] + float(got.get("usd") or 0), 6)
        result["read"] += len(part)
        misheard, speaker, dropped = ground(got.get("data"), lines, part, day)
        result["misheard"] += misheard
        result["speaker"] += speaker
        result["dropped"] += dropped
    result["generated_at"] = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
    return result


def save_day(home: Path, built: dict) -> Path:
    target = folder(home) / f"{built['day']}.json"
    target.parent.mkdir(parents=True, exist_ok=True)
    part = target.with_name(target.name + ".part")
    with _lock:
        part.write_text(json.dumps(built, ensure_ascii=False), encoding="utf-8")
        os.replace(part, target)
    return target


def prune(home: Path, now: float | None = None) -> None:
    limit = (time.time() if now is None else now) - KEEP_DAYS * 86400
    for path in folder(home).glob("????-??-??.json"):
        try:
            if path.stat().st_mtime < limit:
                path.unlink()
        except OSError:
            pass


def run_day(home: Path, store, day: str, log: Callable[[str], None], call=None) -> int | None:
    """夜の流れから呼ぶ。候補の数を返す（使わない設定・鍵が無い・記録が無いときは None）"""
    if not settings()["on"]:
        return None
    if call is None and claude.load_key() is None:
        return None
    parsed = store.day(day) if store is not None else None
    if parsed is None:
        return None
    built = review_day(day, parsed, call=call, log=log)
    save_day(home, built)
    prune(home)
    log(f"夜の読み直し（{day}）: {built['lines']} 行のうち {built['read']} 行を {built['calls']} 回で読み、"
        f"聞き間違い {len(built['misheard'])}・話し手 {len(built['speaker'])}（捨てた {built['dropped']}）、"
        f"${built['usd']:.3f}" + (f"。止めた理由: {built['stopped']}" if built["stopped"] else ""))
    return len(built["misheard"]) + len(built["speaker"])


# MARK: - 読む


def _recent(home: Path) -> list[dict]:
    out = []
    for path in sorted(folder(home).glob("????-??-??.json"), reverse=True)[:SERVE_DAYS]:
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if isinstance(data, dict):
            out.append(data)
    return out


def doubt_items(home: Path) -> list[dict]:
    """GET /speaker-doubts に混ぜる、夜の読み直しの話し手の疑い（新しい日から）"""
    items = []
    for data in _recent(home):
        for x in data.get("speaker") or []:
            if isinstance(x, dict) and x.get("why") == "night":
                items.append(x)
    return items[:SERVE_LIMIT]


def read(home: Path) -> dict:
    found = _recent(home)
    if not found:
        return {"available": False, "reason": "まだ夜の読み直しをしていません"}
    items = []
    for data in found:
        for x in data.get("misheard") or []:
            if isinstance(x, dict) and all(isinstance(x.get(k), str) for k in ("id", "day", "line_time", "wrong", "guess")):
                items.append({k: x.get(k, "") for k in ("id", "day", "line_time", "wrong", "guess", "reason")})
    return {"available": True, "generated_at": max(str(d.get("generated_at") or "") for d in found),
            "items": items[:SERVE_LIMIT]}
