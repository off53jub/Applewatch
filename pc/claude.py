"""LifeLog PC: Claude（Anthropic の API）に頼む部品（2026-11-13。本人の決定で、鍵はこの PC にだけ置く）。

- 鍵: 環境変数 ANTHROPIC_API_KEY、無ければ %LOCALAPPDATA%\\LifeLogPC\\claude-key.txt の最初の空でない1行。
  鍵は記録（log.txt）・答え・エラー・/hello・見守りの画面のどこにも出さない（scrub で消してから外に出す）。
- 設定（無くてよい）: %LOCALAPPDATA%\\LifeLogPC\\claude-config.json
  {"monthly_usd": 100, "work": true, "judge": true, "judge_daily": 400}
- 帳簿: %LOCALAPPDATA%\\LifeLogPC\\claude-usage.jsonl に、1回ごとに1行足す（母艦の scripts も同じ帳簿に足す）。
  会話の文は書かない（数と値段だけ）。月は "at" の YYYY-MM。
- 上限: 頼む前に、今月の値段の合計が monthly_usd 以上なら断る（1回分だけ少し越えるのはよい）。
- POST /claude・GET /claude/usage（lifelog_pc.py から呼ぶ。http_post・http_usage）
- 割れた行の審判（精6。judge）: 多数決の食い違いの大きい行で、候補の番号だけを Claude に選んでもらう。
  新しい文は書かせない。番号が正しくなければ、多数決の選んだ文のまま。
anthropic の部品（anthropic==2.8.0）は、頼むときに初めて読み込む（無くても PC はいつもどおり動く）。
"""

from __future__ import annotations

import datetime
import json as _json
import os
import re
import threading
import time
from pathlib import Path
from typing import Callable

# MARK: - 値段（100 万トークンあたりのドル。入力・出力。claude-api の 2026-10 の表）

PRICES = {
    "claude-opus-5-5": (4.0, 20.0),
    "claude-sonnet-5-5": (2.0, 10.0),
    "claude-haiku-5-5": (0.10, 0.50),
}
HAIKU = "claude-haiku-5-5"
HAIKU_LONG = (0.50, 2.50)        # 頼む文が 10 万トークンを越えたときの haiku の値段
HAIKU_LONG_OVER = 100_000
CACHE_READ = 0.1                 # 覚えておいた分を読む: 入力の 0.1 倍
CACHE_WRITE = 1.25               # 覚えさせる（5 分）: 入力の 1.25 倍
BATCH = 0.5                      # Message Batches: 全部 0.5 倍
SEARCH_USD = 10.0 / 1000         # web 検索 1 回
UNKNOWN_PRICE = PRICES["claude-opus-5-5"]  # 表に無いモデルは、いちばん高い値段で数える

TIERS = {"light": "claude-haiku-5-5", "standard": "claude-sonnet-5-5", "deep": "claude-opus-5-5"}
# opus・sonnet は、混んでいるときに Anthropic の側で別のモデルに替えてもらう（Batches では使わない）
FALLBACK_BETA = "server-side-fallback-2026-07-01"
FALLBACK_MODELS = ("claude-opus-5-5", "claude-sonnet-5-5")

DEFAULTS = {"monthly_usd": 100.0, "work": True, "judge": True, "judge_daily": 400}

PURPOSE = re.compile(r"[0-9A-Za-z_.:-]{1,40}")
PROMPT_MAX = 200_000
BODY_LIMIT = 1_000_000
DEFAULT_TOKENS = 1024
MAX_TOKENS = 8192
TIMEOUT = 120.0

# 試すとき（v11checks）は、ここを作り物の相手に替える（本物の鍵・ネットは使わない）
CLIENT_FACTORY: Callable | None = None

_ledger_lock = threading.Lock()


def home() -> Path:
    """%LOCALAPPDATA%\\LifeLogPC（確かめるときは、isolate_home が替えた LOCALAPPDATA の下）"""
    return Path(os.environ.get("LOCALAPPDATA") or Path.home() / ".local" / "share") / "LifeLogPC"


def key_path() -> Path:
    return home() / "claude-key.txt"


def config_path() -> Path:
    return home() / "claude-config.json"


def ledger_path() -> Path:
    return home() / "claude-usage.jsonl"


# MARK: - 鍵（どこにも出さない）


def load_key() -> str | None:
    """環境変数 ANTHROPIC_API_KEY、無ければ claude-key.txt の最初の空でない1行。無ければ None"""
    value = (os.environ.get("ANTHROPIC_API_KEY") or "").strip()
    if value:
        return value
    try:
        text = key_path().read_text(encoding="utf-8-sig")
    except (OSError, UnicodeDecodeError):
        return None
    for line in text.splitlines():
        line = line.strip()
        if line:
            return line
    return None


_KEYLIKE = re.compile(r"sk-ant-[0-9A-Za-z_\-]{4,}")


def scrub(text: object, key: str | None = None) -> str:
    """文から鍵（と、鍵に見える文字の並び）を消す。外に出す文は、全部これを通す"""
    out = str(text)
    for k in {key, load_key()}:
        if k and len(k) >= 8:
            out = out.replace(k, "[鍵]")
    return _KEYLIKE.sub("[鍵]", out)


class ClaudeError(Exception):
    """Claude に頼めなかった。status は HTTP の答えの番号、body は返す中身（鍵は入れない）"""

    def __init__(self, status: int, message: str, **extra) -> None:
        super().__init__(message)
        self.status = status
        self.body = {"error": message, **extra}


# MARK: - 設定


def load_config() -> dict:
    """claude-config.json（無い・読めない・おかしな値は既定に）"""
    config = dict(DEFAULTS)
    try:
        data = _json.loads(config_path().read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return config
    if not isinstance(data, dict):
        return config
    usd = data.get("monthly_usd")
    if isinstance(usd, (int, float)) and not isinstance(usd, bool) and 0 <= usd <= 100_000:
        config["monthly_usd"] = float(usd)
    for name in ("work", "judge"):
        if isinstance(data.get(name), bool):
            config[name] = data[name]
    daily = data.get("judge_daily")
    if isinstance(daily, int) and not isinstance(daily, bool) and 0 <= daily <= 100_000:
        config["judge_daily"] = daily
    return config


# MARK: - 値段と帳簿


def cost(model: str, tokens_in: int, tokens_out: int, cache_read: int = 0, cache_write: int = 0,
         batch: bool = False, searches: int = 0) -> float:
    """1回分のドル。input_tokens は覚えておいた分を含まない（Anthropic の usage の数え方）"""
    price_in, price_out = PRICES.get(model, UNKNOWN_PRICE)
    if model == HAIKU and tokens_in + cache_read + cache_write > HAIKU_LONG_OVER:
        price_in, price_out = HAIKU_LONG
    usd = (tokens_in * price_in + cache_read * price_in * CACHE_READ + cache_write * price_in * CACHE_WRITE
           + tokens_out * price_out) / 1_000_000 + searches * SEARCH_USD
    if batch:
        usd *= BATCH
    return round(usd, 6)


def now_iso(when: float | None = None) -> str:
    moment = datetime.datetime.fromtimestamp(time.time() if when is None else when)
    return moment.astimezone().isoformat(timespec="seconds")


def append_ledger(entry: dict) -> None:
    """帳簿に1行足す（UTF-8・BOM なし）。会話の文は入れない"""
    row = {"at": entry.get("at") or now_iso(), "who": entry.get("who") or "pc",
           "purpose": str(entry.get("purpose") or "")[:40], "model": str(entry.get("model") or ""),
           "in": int(entry.get("in") or 0), "out": int(entry.get("out") or 0),
           "cache_read": int(entry.get("cache_read") or 0), "cache_write": int(entry.get("cache_write") or 0),
           "batch": bool(entry.get("batch")), "searches": int(entry.get("searches") or 0),
           "usd": float(entry.get("usd") or 0.0)}
    path = ledger_path()
    with _ledger_lock:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8", newline="\n") as f:
            f.write(_json.dumps(row, ensure_ascii=False) + "\n")


class _Ledger:
    """帳簿の合計（増えた所だけ読み足す。母艦が同じファイルに足しても数える）"""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.reset(None)

    def reset(self, path: Path | None) -> None:
        self.path = path
        self.pos = 0
        self.months: dict[str, dict] = {}
        self.days: dict[str, dict[str, int]] = {}

    def add(self, row: dict) -> None:
        at = row.get("at")
        if not isinstance(at, str) or not re.match(r"\d{4}-\d{2}-\d{2}", at):
            return
        usd = row.get("usd")
        usd = float(usd) if isinstance(usd, (int, float)) and not isinstance(usd, bool) and usd >= 0 else 0.0
        purpose = str(row.get("purpose") or "")[:40] or "?"
        who = str(row.get("who") or "")[:20] or "?"
        month = self.months.setdefault(at[:7], {"usd": 0.0, "calls": 0, "by_purpose": {}, "by_who": {}})
        month["usd"] += usd
        month["calls"] += 1
        month["by_purpose"][purpose] = month["by_purpose"].get(purpose, 0.0) + usd
        month["by_who"][who] = month["by_who"].get(who, 0.0) + usd
        day = self.days.setdefault(at[:10], {})
        day[purpose] = day.get(purpose, 0) + 1

    def refresh(self) -> None:
        path = ledger_path()
        with self.lock:
            if path != self.path:
                self.reset(path)
            try:
                size = path.stat().st_size
            except OSError:
                self.reset(path)
                return
            if size < self.pos:  # 作り直された
                self.reset(path)
            if size == self.pos:
                return
            try:
                with path.open("rb") as f:
                    f.seek(self.pos)
                    data = f.read(size - self.pos)
            except OSError:
                return
            end = data.rfind(b"\n")
            if end < 0:
                return
            for raw in data[:end].splitlines():
                try:
                    row = _json.loads(raw.decode("utf-8-sig"))
                except (UnicodeDecodeError, ValueError):
                    continue
                if isinstance(row, dict):
                    self.add(row)
            self.pos += end + 1

    def month(self, month: str) -> dict:
        self.refresh()
        with self.lock:
            got = self.months.get(month) or {"usd": 0.0, "calls": 0, "by_purpose": {}, "by_who": {}}
            return {"usd": got["usd"], "calls": got["calls"], "by_purpose": dict(got["by_purpose"]),
                    "by_who": dict(got["by_who"])}

    def day_calls(self, day: str, purpose: str) -> int:
        self.refresh()
        with self.lock:
            return int((self.days.get(day) or {}).get(purpose, 0))


LEDGER = _Ledger()


def this_month(when: float | None = None) -> str:
    return time.strftime("%Y-%m", time.localtime(time.time() if when is None else when))


def today(when: float | None = None) -> str:
    return time.strftime("%Y-%m-%d", time.localtime(time.time() if when is None else when))


def month_usd(month: str | None = None) -> float:
    return round(LEDGER.month(month or this_month())["usd"], 6)


def available() -> bool:
    """鍵があり、今月の上限に届いていないか（/hello の features の "claude"）"""
    try:
        return load_key() is not None and month_usd() < load_config()["monthly_usd"]
    except Exception:  # noqa: BLE001 — 分からなければ使えないことにする
        return False


def usage_report() -> dict:
    """GET /claude/usage の中身（鍵は入れない）"""
    month = this_month()
    got = LEDGER.month(month)
    cap = load_config()["monthly_usd"]
    by_who = {"pc": 0.0, "mothership": 0.0}
    by_who.update(got["by_who"])
    return {"available": load_key() is not None and got["usd"] < cap, "month": month,
            "month_usd": round(got["usd"], 6), "cap_usd": cap, "calls": got["calls"],
            "by_purpose": {k: round(v, 6) for k, v in sorted(got["by_purpose"].items())},
            "by_who": {k: round(v, 6) for k, v in sorted(by_who.items())}}


# MARK: - 頼む


def _client(key: str):
    if CLIENT_FACTORY is not None:
        return CLIENT_FACTORY(key)
    import anthropic  # 頼むときに初めて読み込む（無ければ ClaudeError）

    return anthropic.Anthropic(api_key=key, max_retries=2, timeout=TIMEOUT)


def _usage_numbers(response) -> dict:
    usage = getattr(response, "usage", None)

    def number(name: str) -> int:
        value = getattr(usage, name, 0) if usage is not None else 0
        return int(value) if isinstance(value, int) and not isinstance(value, bool) and value > 0 else 0

    tool = getattr(usage, "server_tool_use", None) if usage is not None else None
    searches = getattr(tool, "web_search_requests", 0) if tool is not None else 0
    return {"in": number("input_tokens"), "out": number("output_tokens"),
            "cache_read": number("cache_read_input_tokens"), "cache_write": number("cache_creation_input_tokens"),
            "searches": int(searches) if isinstance(searches, int) and not isinstance(searches, bool) else 0}


def parse_json_text(text: str):
    """JSON の答えを読む（```json の囲み・前後の文があっても）。読めなければ ValueError"""
    body = (text or "").strip()
    fenced = re.match(r"^```(?:json)?\s*(.*?)\s*```$", body, re.S)
    if fenced:
        body = fenced.group(1)
    try:
        return _json.loads(body)
    except ValueError:
        pass
    for opener, closer in (("{", "}"), ("[", "]")):
        a, b = body.find(opener), body.rfind(closer)
        if 0 <= a < b:
            try:
                return _json.loads(body[a:b + 1])
            except ValueError:
                continue
    raise ValueError("JSON を読めません")


def call(system: str | None, prompt: str, json: bool = False, max_tokens: int = DEFAULT_TOKENS,
         tier: str = "light", purpose: str = "pc", work: bool = False, schema: dict | None = None,
         who: str = "pc", timeout: float | None = None, log: Callable[[str], None] | None = None) -> dict:
    """Claude に1回頼む。{"text", "data"（json のとき）, "model", "usd", "month_usd", "cap_usd"} を返す。
    頼めなければ ClaudeError（status と body。鍵は入れない）。おかしな頼み方は ValueError。"""
    if tier not in TIERS:
        raise ValueError("tier は light・standard・deep のどれかです")
    if not isinstance(purpose, str) or not PURPOSE.fullmatch(purpose):
        raise ValueError("purpose は英数字と _ . : - で 40 文字までです")
    if not isinstance(prompt, str) or not prompt.strip():
        raise ValueError("prompt がありません")
    config = load_config()
    cap = config["monthly_usd"]
    if work and not config["work"]:
        raise ClaudeError(403, "職場の会話は Claude に送らない設定です")
    key = load_key()
    if key is None:
        raise ClaudeError(503, "Claude の鍵がありません")
    spent = month_usd()
    if spent >= cap:
        raise ClaudeError(402, "今月の上限に達しました", month_usd=round(spent, 6), cap_usd=cap)
    model = TIERS[tier]
    tokens = int(min(MAX_TOKENS, max(1, max_tokens)))
    kwargs: dict = {"model": model, "max_tokens": tokens, "messages": [{"role": "user", "content": prompt}]}
    if system:
        # 決まった長い頭の部分は覚えておいてもらう（毎回まったく同じ文にする）
        kwargs["system"] = [{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}]
    if json and schema:
        kwargs["output_config"] = {"format": {"type": "json_schema", "schema": schema}}
    if timeout is not None:
        kwargs["timeout"] = timeout
    started = time.time()
    failure: ClaudeError | None = None
    response = None
    try:
        client = _client(key)
        if model in FALLBACK_MODELS:
            response = client.beta.messages.create(betas=[FALLBACK_BETA], fallbacks="default", **kwargs)
        else:
            response = client.messages.create(**kwargs)
    except ClaudeError:
        raise
    except ImportError:
        failure = ClaudeError(503, "Claude の部品（anthropic）が入っていません")
    except Exception as error:  # noqa: BLE001 — 何があっても、鍵を出さずに断る
        status = getattr(error, "status_code", None)
        name = type(error).__name__
        if status == 401:
            failure = ClaudeError(503, "Claude の鍵が使えません（鍵を確かめてください）")
        elif status == 429:
            failure = ClaudeError(429, "Claude が混んでいます。少し待ってから頼んでください")
        else:
            failure = ClaudeError(502, scrub(f"Claude に頼めませんでした: {name}" + (f"（{status}）" if status else ""),
                                             key))
    if failure is not None:
        # except の外で投げる（元のエラー＝鍵を含むかもしれないものを __context__ に残さない）
        raise failure
    used = _usage_numbers(response)
    answered = str(getattr(response, "model", "") or model)
    priced = answered if answered in PRICES else model
    usd = cost(priced, used["in"], used["out"], used["cache_read"], used["cache_write"], False, used["searches"])
    try:
        append_ledger({"who": who, "purpose": purpose, "model": answered, **used, "batch": False, "usd": usd})
    except OSError as error:
        if log:
            log(f"Claude の帳簿に書けませんでした: {type(error).__name__}")
    total = month_usd()
    stop = getattr(response, "stop_reason", None)
    text = "".join(str(getattr(block, "text", "") or "") for block in getattr(response, "content", None) or []
                   if getattr(block, "type", None) == "text")
    if log:
        # 頼んだ文と答えの中身は書かない（長さ・モデル・値段だけ）
        log(f"Claude（{purpose}・{answered}）: 入 {used['in']}+{used['cache_read']}（覚えた分）・出 {used['out']} トークン、"
            f"{len(prompt)} 文字 → {len(text)} 文字、${usd:.4f}（今月 ${total:.2f}／${cap:.0f}）、"
            f"{time.time() - started:.1f} 秒" + (f"、{stop}" if stop not in (None, "end_turn") else ""))
    if stop == "refusal":
        raise ClaudeError(422, "断られました", refusal=True)
    if stop == "max_tokens" and json:
        raise ClaudeError(502, "答えが長すぎて途中で切れました（max_tokens を増やしてください）")
    result = {"text": text, "model": answered, "usd": usd, "month_usd": round(total, 6), "cap_usd": cap}
    if json:
        try:
            result["data"] = parse_json_text(text)
        except ValueError:
            raise ClaudeError(502, "答えが JSON ではありませんでした") from None
    return result


# MARK: - POST /claude・GET /claude/usage


def parse_request(data: bytes) -> dict:
    """POST /claude の中身。おかしければ ValueError"""
    try:
        body = _json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise ValueError("中身が JSON ではありません") from None
    if not isinstance(body, dict):
        raise ValueError("中身が JSON ではありません")
    prompt = body.get("prompt")
    if not isinstance(prompt, str) or not prompt.strip():
        raise ValueError("prompt がありません")
    if len(prompt) > PROMPT_MAX:
        raise ValueError(f"prompt が長すぎます（{PROMPT_MAX} 文字まで）")
    system = body.get("system")
    if system is not None and not isinstance(system, str):
        raise ValueError("system は文です")
    if system and len(system) > PROMPT_MAX:
        raise ValueError(f"system が長すぎます（{PROMPT_MAX} 文字まで）")
    as_json = body.get("json", False)
    if not isinstance(as_json, bool):
        raise ValueError("json は true か false です")
    tokens = body.get("max_tokens", DEFAULT_TOKENS)
    if isinstance(tokens, bool) or not isinstance(tokens, int) or not 1 <= tokens <= MAX_TOKENS:
        raise ValueError(f"max_tokens は 1〜{MAX_TOKENS} の数です")
    tier = body.get("tier", "light")
    if tier not in TIERS:
        raise ValueError("tier は light・standard・deep のどれかです")
    purpose = body.get("purpose", "app")
    if not isinstance(purpose, str) or not PURPOSE.fullmatch(purpose):
        raise ValueError("purpose は英数字と _ . : - で 40 文字までです")
    # work が無いときは「職場かもしれない」として扱う（職場を送らない設定のときに、うっかり送らない）
    work = body.get("work", True)
    if not isinstance(work, bool):
        raise ValueError("work は true か false です")
    return {"system": system or None, "prompt": prompt, "json": as_json, "max_tokens": tokens, "tier": tier,
            "purpose": purpose, "work": work}


def http_post(handler, data: bytes, log: Callable[[str], None]) -> None:
    try:
        request = parse_request(data)
    except ValueError as error:
        handler.send_json(400, {"error": str(error)})
        return
    try:
        got = call(request["system"], request["prompt"], json=request["json"], max_tokens=request["max_tokens"],
                   tier=request["tier"], purpose=request["purpose"], work=request["work"], who="pc", log=log)
    except ClaudeError as error:
        log(f"{handler.client_address[0]} から /claude（{request['purpose']}）: {error.status} "
            f"{scrub(error.body.get('error', ''))}")
        handler.send_json(error.status, {k: (scrub(v) if isinstance(v, str) else v) for k, v in error.body.items()})
        return
    except Exception as error:  # noqa: BLE001 — 何があっても受け付けは続ける（鍵は出さない）
        log(f"/claude で答えを作れませんでした: {type(error).__name__}")
        handler.send_json(500, {"error": "Claude の答えを作れませんでした"})
        return
    handler.send_json(200, {"text": got["text"], "model": got["model"], "usd": got["usd"],
                            "month_usd": got["month_usd"], "cap_usd": got["cap_usd"]})


def http_usage(handler) -> None:
    try:
        handler.send_json(200, usage_report())
    except Exception as error:  # noqa: BLE001
        handler.send_json(500, {"error": f"帳簿を読めませんでした: {type(error).__name__}"})


# MARK: - 割れた行の審判（精6）

JUDGE_PURPOSE = "asr-judge"
JUDGE_BELOW = 0.5          # 食い違いの大きい行（多数決の確からしさがこれより小さい。log.txt の「食い違いの大きい行」と同じ）
JUDGE_BATCH = 40           # 1回で見てもらう行の数
JUDGE_MAX_LINES = 160      # 1つの区切りで見てもらう行の数の上限
JUDGE_CANDIDATES = 8
JUDGE_TOKENS = 2048
JUDGE_TIMEOUT = 60.0
JUDGE_SYSTEM = (
    "あなたは日本語の音声認識の審判です。\n"
    "入力は JSON で、lines の各行に、いくつかの音声認識エンジンが同じ音声から書いた候補 candidates があります。\n"
    "各行について、実際に話されたとおりである見込みがいちばん高い候補を、candidates の番号（0 から）で1つ選びます。\n"
    "決まり:\n"
    "- 新しい文を書いてはいけません。候補を直す・混ぜる・言い換えることもしません。答えるのは番号だけです。\n"
    "- before と after はその行の前後の行で、文脈の手がかりです。選ぶ対象ではありません。\n"
    "- words は本人が登録した言葉（人や場所の名前など）です。候補の中にその言葉を正しく書いたものがあれば重んじます。\n"
    "- 日本語として意味の通る候補を選びます。同じくらいなら、小さい番号を選びます。\n"
    "- 答えは JSON だけで、{\"picks\": [{\"line\": 行の番号, \"index\": 候補の番号}]} の形にします。"
)
JUDGE_SCHEMA = {
    "type": "object",
    "properties": {"picks": {"type": "array", "items": {
        "type": "object", "properties": {"line": {"type": "integer"}, "index": {"type": "integer"}},
        "required": ["line", "index"], "additionalProperties": False}}},
    "required": ["picks"], "additionalProperties": False,
}


def judge_candidates(line: dict) -> list[str]:
    """審判に出す候補（0 番は多数決が選んだ文。ほかはモデルごとの違う文。同じ文は1つ）"""
    out = [str(line.get("text") or "").strip()]
    votes = line.get("votes") if isinstance(line.get("votes"), dict) else {}
    for text in list(votes.values()) + list(line.get("alternatives") or []):
        text = str(text or "").strip()
        if text and text not in out:
            out.append(text)
    return [t for t in out if t][:JUDGE_CANDIDATES]


def split_lines(lines: list[dict]) -> list[int]:
    """審判に出す行の番号（食い違いの大きい行で、違う候補が2つ以上あるもの）"""
    picked = []
    for i, line in enumerate(lines):
        confidence = line.get("confidence")
        if isinstance(confidence, bool) or not isinstance(confidence, (int, float)) or confidence >= JUDGE_BELOW:
            continue
        if len(judge_candidates(line)) >= 2:
            picked.append(i)
    return picked[:JUDGE_MAX_LINES]


def judge_gate(work: bool | None) -> str | None:
    """審判を使えるか。使えなければ理由（記録用の短い文）。work は区切りが職場の会話か（None は分からない）"""
    config = load_config()
    if not config["judge"]:
        return "使わない設定"
    if load_key() is None:
        return "鍵が無い"
    if not config["work"] and work is not False:
        return "職場（かもしれない）の会話は送らない設定"
    if month_usd() >= config["monthly_usd"]:
        return "今月の上限"
    if LEDGER.day_calls(today(), JUDGE_PURPOSE) >= config["judge_daily"]:
        return "今日の回数の上限"
    return None


def validate_picks(data, asked: dict[int, int]) -> dict[int, int]:
    """Claude の答えから、正しい番号だけを取り出す。asked は {行の番号: 候補の数}。おかしなものは捨てる"""
    picks: dict[int, int] = {}
    items = data.get("picks") if isinstance(data, dict) else None
    if not isinstance(items, list):
        return picks
    for item in items:
        if not isinstance(item, dict):
            continue
        line, index = item.get("line"), item.get("index")
        if isinstance(line, bool) or isinstance(index, bool) or not isinstance(line, int) or not isinstance(index, int):
            continue
        if line in asked and line not in picks and 0 <= index < asked[line]:
            picks[line] = index
    return picks


def judge(lines: list[dict], hints: list[str] | None = None, work: bool | None = None,
          log: Callable[[str], None] | None = None) -> dict:
    """食い違いの大きい行を Claude に番号で選んでもらい、lines をその場で直す。数だけを返す:
    {"split", "asked", "changed", "calls", "usd", "skipped"（使えなかった理由）}。
    審判が番号を返した行には "judge": {"picked", "model"} を付け、文を替えた行には "before"（前の文）も付ける
    （前の文は "alternatives" にも残す）。答えが無い行・番号がおかしい行は、多数決の文のまま（"judge" も付けない）。"""
    targets = split_lines(lines)
    result = {"split": len(targets), "asked": 0, "changed": 0, "calls": 0, "usd": 0.0, "skipped": None}
    if not targets:
        return result
    for begin in range(0, len(targets), JUDGE_BATCH):
        reason = judge_gate(work)
        if reason:
            result["skipped"] = reason
            break
        part = targets[begin:begin + JUDGE_BATCH]
        candidates = {i: judge_candidates(lines[i]) for i in part}
        rows = []
        for i in part:
            rows.append({"line": i, "candidates": candidates[i],
                         "before": str(lines[i - 1].get("text") or "") if i > 0 else "",
                         "after": str(lines[i + 1].get("text") or "") if i + 1 < len(lines) else ""})
        prompt = _json.dumps({"words": [str(w) for w in (hints or [])][:80], "lines": rows},
                             ensure_ascii=False, sort_keys=True)
        try:
            got = call(JUDGE_SYSTEM, prompt, json=True, max_tokens=JUDGE_TOKENS, tier="light", purpose=JUDGE_PURPOSE,
                       work=work is not False, schema=JUDGE_SCHEMA, timeout=JUDGE_TIMEOUT, log=log)
        except ClaudeError as error:
            result["skipped"] = scrub(error.body.get("error", ""))
            if error.status in (402, 403, 503):
                break
            continue
        except Exception as error:  # noqa: BLE001 — 審判が使えなくても、多数決の文で続ける
            result["skipped"] = type(error).__name__
            continue
        result["calls"] += 1
        result["usd"] = round(result["usd"] + got["usd"], 6)
        picks = validate_picks(got.get("data"), {i: len(c) for i, c in candidates.items()})
        result["asked"] += len(part)
        for i, index in picks.items():
            line = lines[i]
            chosen = candidates[i][index]
            line["judge"] = {"picked": index, "model": got["model"]}
            if chosen == str(line.get("text") or "").strip():
                continue
            before = str(line.get("text") or "")
            line["judge"]["before"] = before
            line["text"] = chosen
            # 言葉ごとの時刻は前の文を書いたモデルのものなので外す。前の文は候補に残す（あとで比べられるように）
            line.pop("words", None)
            line["alternatives"] = [t for t in candidates[i] if t != chosen]
            result["changed"] += 1
    return result
