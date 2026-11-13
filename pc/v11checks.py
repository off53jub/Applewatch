"""LifeLog PC（2026-11-13: Claude の API）を確かめる（--check-v11 から呼ぶ。本物の鍵・ネット・モデルは使わない）。

- 鍵: 環境変数・claude-key.txt（BOM・空行）・無いとき。鍵は答え・エラー・記録・帳簿・/hello のどこにも出ない
- 値段と帳簿: 値段の表（覚えた分を読む 0.1 倍・覚えさせる 1.25 倍・Batches 0.5 倍・haiku の 10 万トークン越え・web 検索）・
  帳簿の月の合計（母艦の行も数える・ほかの月は数えない・壊れた行は飛ばす・増えた所だけ読む）
- 上限: 今月の合計が上限以上なら頼まずに 402。鍵が無ければ 503。職場を送らない設定なら 403
- 頼み方: haiku は messages.create（thinking・temperature を付けない）、sonnet・opus は beta の server-side fallback。
  system は cache_control 付き。JSON の形を渡せば output_config。断られた（refusal）→ 422、途中で切れた JSON → 502
- POST /claude・GET /claude/usage の受け口（中身の確かめ・合言葉）と features の "claude"
- 母艦の写し: /proposals（おかしな行・期限切れを落とす）・/proposals/answer（1行足す・kind を引く）・/plaud-fill・/speaker-doubts
- 割れた行の審判（精6）: 正しい番号だけを使う・新しい文は書かない・前の文を残す・1日の回数・設定・職場の扱い
- 自動の材料（精7・仮）: 既定は使わない・そろった 2 秒以上の行だけ・1日の上限・印（pc-auto）・試験に使わない
番号はどれも空いているもの（127.0.0.1 の 0 番）を使う。確かめるときは、本物の HOME に書かない（isolate_home）。
"""

from __future__ import annotations

import json
import os
import tempfile
import threading
import time
from pathlib import Path
from types import SimpleNamespace

import numpy as np

import claude
import appfeeds
import feedschecks  # 2026-11-13 の施策の口（weekly・prep・feedback・mood など）
import mothership
import ops
from v6checks import KEY, Client, say

# 確かめ用の作り物の鍵（本物の鍵の形ではない）
SECRET = "sk-ant-checkonly-0123456789abcdefSECRET"


def run(main) -> int:
    main.isolate_home()
    saved_env = os.environ.pop("ANTHROPIC_API_KEY", None)
    saved_factory = claude.CLIENT_FACTORY
    failed = 0
    try:
        failed += check_isolated(main)
        failed += check_key()
        failed += check_prices()
        failed += check_ledger()
        failed += check_call()
        failed += check_real_sdk()
        failed += check_feeds()
        failed += check_judge()
        failed += check_auto_samples(main)
        failed += check_http(main)
        failed += feedschecks.run(main)
    finally:
        claude.CLIENT_FACTORY = saved_factory
        os.environ.pop("ANTHROPIC_API_KEY", None)
        if saved_env is not None:
            os.environ["ANTHROPIC_API_KEY"] = saved_env
    print(("NG の数: " + str(failed)) if failed else "Claude（2026-11-13）: 全部 OK", flush=True)
    return failed


def check_isolated(main) -> int:
    home = claude.home()
    ok = main._isolated is not None and home.is_relative_to(main._isolated) and home == Path(main.HOME)
    return say(ok, f"確かめるときは、Claude の鍵・設定・帳簿も一時のフォルダ（{home.name}）")


def reset_files() -> None:
    for path in (claude.key_path(), claude.config_path(), claude.ledger_path()):
        try:
            path.unlink()
        except OSError:
            pass
    claude.LEDGER.reset(None)


def put_key(text: str = SECRET) -> None:
    claude.home().mkdir(parents=True, exist_ok=True)
    claude.key_path().write_text(text, encoding="utf-8")


def put_config(config: dict) -> None:
    claude.home().mkdir(parents=True, exist_ok=True)
    claude.config_path().write_text(json.dumps(config), encoding="utf-8")


# MARK: - 作り物の Claude


class FakeClaude:
    """anthropic.Anthropic の代わり。頼まれた中身を残し、決めた答えを返す（ネットは使わない）"""

    def __init__(self) -> None:
        self.calls: list[tuple[bool, dict]] = []
        self.keys: list[str] = []
        self.text = "答えです"
        self.stop = "end_turn"
        self.model: str | None = None
        self.usage = {"input_tokens": 1000, "output_tokens": 200, "cache_read_input_tokens": 0,
                      "cache_creation_input_tokens": 0}
        self.error: Exception | None = None
        self.reply = None   # 関数を入れると、頼まれた中身から答えの文を作る

    def factory(self, key: str):
        self.keys.append(key)
        owner = self

        class Messages:
            def __init__(self, beta: bool) -> None:
                self.beta = beta

            def create(self, **kwargs):
                owner.calls.append((self.beta, kwargs))
                if owner.error is not None:
                    raise owner.error
                text = owner.reply(kwargs) if owner.reply else owner.text
                return SimpleNamespace(
                    content=[SimpleNamespace(type="thinking", thinking="x"), SimpleNamespace(type="text", text=text)],
                    stop_reason=owner.stop, model=owner.model or kwargs["model"],
                    usage=SimpleNamespace(**owner.usage, server_tool_use=None))

        return SimpleNamespace(messages=Messages(False), beta=SimpleNamespace(messages=Messages(True)))


class LeakyError(Exception):
    """鍵を文に含むエラー（SDK のエラーが鍵を含んでも外に出ないことを確かめる）"""

    status_code = 500


# MARK: - 鍵


def check_key() -> int:
    failed = 0
    reset_files()
    failed += say(claude.load_key() is None and not claude.available(), "鍵が無いときは None・features に出さない")
    put_key("﻿\n\n  " + SECRET + "  \nほかの行\n")
    failed += say(claude.load_key() == SECRET, "claude-key.txt の最初の空でない1行（BOM・前後の空白は除く）")
    os.environ["ANTHROPIC_API_KEY"] = "sk-ant-from-env-0123456789"
    failed += say(claude.load_key() == "sk-ant-from-env-0123456789", "環境変数 ANTHROPIC_API_KEY を先に使う")
    os.environ.pop("ANTHROPIC_API_KEY")
    scrubbed = claude.scrub(f"error with {SECRET} and sk-ant-other-abcdef123456")
    failed += say(SECRET not in scrubbed and "sk-ant-" not in scrubbed, "scrub: 鍵と鍵に見える並びを消す")
    reset_files()
    return failed


# MARK: - 値段と帳簿


def check_prices() -> int:
    near = lambda a, b: abs(a - b) < 1e-9  # noqa: E731
    cases = [
        ("haiku 入力 10 万（ちょうどは安いまま）", claude.cost("claude-haiku-5-5", 100_000, 0), 0.01),
        ("haiku 出力 100 万", claude.cost("claude-haiku-5-5", 0, 1_000_000), 0.50),
        ("haiku 10 万トークン越えは 0.50/2.50", claude.cost("claude-haiku-5-5", 100_001, 1_000_000), 0.0500005 + 2.50),
        ("sonnet 入出力", claude.cost("claude-sonnet-5-5", 1_000_000, 1_000_000), 12.0),
        ("opus 入出力", claude.cost("claude-opus-5-5", 1_000_000, 1_000_000), 24.0),
        ("覚えた分を読む 0.1 倍", claude.cost("claude-sonnet-5-5", 0, 0, cache_read=1_000_000), 0.2),
        ("覚えさせる 1.25 倍", claude.cost("claude-sonnet-5-5", 0, 0, cache_write=1_000_000), 2.5),
        ("Batches 0.5 倍", claude.cost("claude-opus-5-5", 1_000_000, 1_000_000, batch=True), 12.0),
        ("web 検索 1000 回で $10", claude.cost("claude-haiku-5-5", 0, 0, searches=1000), 10.0),
        ("表に無いモデルは opus の値段", claude.cost("claude-unknown", 1_000_000, 0), 4.0),
        ("合わせて", claude.cost("claude-haiku-5-5", 1000, 200, cache_read=5000, cache_write=2000),
         round((1000 * 0.10 + 5000 * 0.01 + 2000 * 0.125 + 200 * 0.50) / 1_000_000, 6)),
    ]
    wrong = [(label, got, want) for label, got, want in cases if not near(got, round(want, 6))]
    return say(not wrong, f"値段の表（{len(cases)} 通り）" + (f": 違う {wrong}" if wrong else ""))


def check_ledger() -> int:
    failed = 0
    reset_files()
    month = claude.this_month()
    claude.append_ledger({"who": "pc", "purpose": "asr-judge", "model": "claude-haiku-5-5", "in": 10, "out": 5,
                          "usd": 0.25})
    path = claude.ledger_path()
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps({"at": f"{month}-01T09:00:00+09:00", "who": "mothership", "purpose": "proposals",
                            "model": "claude-sonnet-5-5", "in": 1, "out": 1, "cache_read": 0, "cache_write": 0,
                            "batch": True, "searches": 0, "usd": 1.5}) + "\n")
        f.write("壊れた行\n")
        f.write(json.dumps({"at": "2001-01-01T00:00:00+09:00", "who": "pc", "purpose": "old", "usd": 50}) + "\n")
    report = claude.usage_report()
    failed += say(abs(report["month_usd"] - 1.75) < 1e-9 and report["calls"] == 2 and report["month"] == month
                  and abs(report["by_who"]["pc"] - 0.25) < 1e-9 and abs(report["by_who"]["mothership"] - 1.5) < 1e-9
                  and set(report["by_purpose"]) == {"asr-judge", "proposals"} and report["cap_usd"] == 100.0,
                  f"帳簿の今月の合計（母艦の行も・ほかの月と壊れた行は数えない）: {report}")
    first = json.loads(path.read_text(encoding="utf-8").splitlines()[0])
    keys = {"at", "who", "purpose", "model", "in", "out", "cache_read", "cache_write", "batch", "searches", "usd"}
    failed += say(set(first) == keys and not path.read_bytes().startswith(b"\xef\xbb\xbf"),
                  "帳簿の1行の形（決めた項目だけ・BOM なし）")
    claude.append_ledger({"who": "pc", "purpose": "asr-judge", "model": "claude-haiku-5-5", "usd": 0.5})
    failed += say(abs(claude.month_usd() - 2.25) < 1e-9 and claude.LEDGER.day_calls(claude.today(), "asr-judge") == 2,
                  "増えた所だけ読み足す（今日の審判の回数も）")
    put_config({"monthly_usd": 2.0})
    put_key()
    failed += say(not claude.available() and claude.usage_report()["available"] is False,
                  "上限に届いたら features にも usage にも出さない")
    put_config({"monthly_usd": "たくさん", "work": "yes", "judge_daily": -1})
    failed += say(claude.load_config() == claude.DEFAULTS, "設定のおかしな値は既定に（100 ドル・職場も送る・審判あり・400 回）")
    reset_files()
    return failed


# MARK: - 頼む


def check_call() -> int:
    failed = 0
    reset_files()
    fake = FakeClaude()
    claude.CLIENT_FACTORY = fake.factory
    logged: list[str] = []
    try:
        claude.call(None, "こんにちは", log=logged.append)
        failed += say(False, "鍵が無ければ 503")
    except claude.ClaudeError as error:
        failed += say(error.status == 503 and error.body == {"error": "Claude の鍵がありません"} and not fake.calls,
                      "鍵が無ければ頼まずに 503")
    put_key()
    got = claude.call("決まった前置き", "秘密の会話の本文", purpose="check", log=logged.append)
    beta, sent = fake.calls[-1]
    failed += say(not beta and sent["model"] == "claude-haiku-5-5" and "thinking" not in sent
                  and "temperature" not in sent and "betas" not in sent
                  and sent["system"] == [{"type": "text", "text": "決まった前置き", "cache_control": {"type": "ephemeral"}}]
                  and sent["messages"] == [{"role": "user", "content": "秘密の会話の本文"}] and sent["max_tokens"] == 1024,
                  "light は haiku を messages.create で（thinking・temperature なし・system は覚えておく印つき）")
    failed += say(got["text"] == "答えです" and got["model"] == "claude-haiku-5-5"
                  and abs(got["usd"] - claude.cost("claude-haiku-5-5", 1000, 200)) < 1e-12
                  and abs(got["month_usd"] - got["usd"]) < 1e-12 and got["cap_usd"] == 100.0,
                  "答えは text だけを合わせ、値段を帳簿に足す")
    for tier, model in (("standard", "claude-sonnet-5-5"), ("deep", "claude-opus-5-5")):
        claude.call(None, "x", tier=tier, purpose="check")
        beta, sent = fake.calls[-1]
        failed += say(beta and sent["model"] == model and sent["betas"] == [claude.FALLBACK_BETA]
                      and sent["fallbacks"] == "default" and "thinking" not in sent,
                      f"{tier} は {model} を beta の server-side fallback で（thinking を付けない）")
    fake.model = "claude-sonnet-5-5"
    got = claude.call(None, "x", tier="deep", purpose="check")
    failed += say(got["model"] == "claude-sonnet-5-5"
                  and abs(got["usd"] - claude.cost("claude-sonnet-5-5", 1000, 200)) < 1e-12,
                  "替わりのモデルが答えたら、そのモデルの値段で数える")
    fake.model = None
    fake.text = '```json\n{"a": 1}\n```'
    got = claude.call(None, "x", json=True, schema={"type": "object"}, purpose="check")
    failed += say(got["data"] == {"a": 1}
                  and fake.calls[-1][1]["output_config"] == {"format": {"type": "json_schema", "schema": {"type": "object"}}},
                  "JSON: 形を渡せば output_config、囲みがあっても読む")
    fake.stop = "refusal"
    try:
        claude.call(None, "x", purpose="check")
        failed += say(False, "断られたら 422")
    except claude.ClaudeError as error:
        failed += say(error.status == 422 and error.body == {"error": "断られました", "refusal": True}, "断られたら 422")
    fake.stop = "max_tokens"
    try:
        claude.call(None, "x", json=True, purpose="check")
        failed += say(False, "JSON が途中で切れたら失敗")
    except claude.ClaudeError as error:
        failed += say(error.status == 502, "JSON が途中で切れたら失敗（max_tokens）")
    fake.stop = "end_turn"
    fake.text = "答えです"
    fake.error = LeakyError(f"boom {SECRET}")
    try:
        claude.call(None, "x", purpose="check")
        failed += say(False, "SDK のエラー")
    except claude.ClaudeError as error:
        text = repr(error) + json.dumps(error.body, ensure_ascii=False) + str(error.__cause__) + str(error.__context__)
        failed += say(error.status == 502 and SECRET not in text and error.__cause__ is None
                      and error.__context__ is None,
                      "SDK のエラーに鍵が入っていても、外に出すエラーには入れない")
    fake.error = None
    put_config({"work": False})
    try:
        claude.call(None, "x", purpose="check", work=True)
        failed += say(False, "職場を送らない設定なら 403")
    except claude.ClaudeError as error:
        failed += say(error.status == 403, "職場を送らない設定で work なら頼まずに 403")
    put_config({"monthly_usd": 0.0001})
    before = len(fake.calls)
    try:
        claude.call(None, "x", purpose="check")
        failed += say(False, "上限なら 402")
    except claude.ClaudeError as error:
        failed += say(error.status == 402 and error.body["error"] == "今月の上限に達しました"
                      and error.body["cap_usd"] == 0.0001 and error.body["month_usd"] > 0 and len(fake.calls) == before,
                      "今月の合計が上限以上なら頼まずに 402（month_usd・cap_usd 付き）")
    for bad in ({"tier": "huge"}, {"purpose": "日本語"}, {"purpose": "x" * 41}):
        try:
            claude.call(None, "x", **bad)
            failed += say(False, f"おかしな頼み方 {bad}")
        except ValueError:
            pass
    ledger = claude.ledger_path().read_text(encoding="utf-8")
    failed += say(SECRET not in "\n".join(logged) and "秘密の会話の本文" not in "\n".join(logged)
                  and SECRET not in ledger and "秘密の会話の本文" not in ledger and "決まった前置き" not in ledger,
                  "記録と帳簿に、鍵も頼んだ文も書かない（長さ・モデル・値段だけ）")
    reset_files()
    return failed


def check_real_sdk() -> int:
    """本物の anthropic の部品を、この PC の中の作り物の API（127.0.0.1）に向けて、送る形を確かめる（ネットは使わない）"""
    try:
        import anthropic
    except ImportError:
        return say(False, "anthropic の部品が入っていません（requirements.txt の anthropic==2.8.0）")
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    seen: list[dict] = []
    status_box = {"status": 200}

    class FakeApi(BaseHTTPRequestHandler):
        def log_message(self, *args) -> None:
            pass

        def do_POST(self) -> None:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
            seen.append({"path": self.path, "headers": {k.lower(): v for k, v in self.headers.items()}, "body": body})
            if status_box["status"] != 200:
                data = json.dumps({"type": "error", "error": {"type": "api_error", "message": f"bad {SECRET}"}}).encode()
            else:
                data = json.dumps({"id": "msg_check", "type": "message", "role": "assistant", "model": body["model"],
                                   "content": [{"type": "text", "text": "はい"}], "stop_reason": "end_turn",
                                   "stop_sequence": None,
                                   "usage": {"input_tokens": 12, "output_tokens": 3, "cache_read_input_tokens": 0,
                                             "cache_creation_input_tokens": 40}}).encode()
            self.send_response(status_box["status"])
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    failed = 0
    reset_files()
    put_key()
    fake = ThreadingHTTPServer(("127.0.0.1", 0), FakeApi)
    threading.Thread(target=fake.serve_forever, daemon=True).start()
    import httpx2  # anthropic 2.8.0 が使う http の部品（プロキシの設定があっても、この PC の中にだけつなぐ）

    url = f"http://127.0.0.1:{fake.server_address[1]}"
    claude.CLIENT_FACTORY = lambda key: anthropic.Anthropic(api_key=key, base_url=url, max_retries=0, timeout=10,
                                                            http_client=httpx2.Client(trust_env=False))
    try:
        got = claude.call("前置き", "本文", purpose="check")
        light = seen[-1]
        failed += say(got["text"] == "はい" and light["path"].startswith("/v1/messages")
                      and SECRET in (light["headers"].get("x-api-key", "") + light["headers"].get("authorization", ""))
                      and "anthropic-beta" not in light["headers"]
                      and light["body"]["system"][0]["cache_control"] == {"type": "ephemeral"}
                      and "thinking" not in light["body"] and "fallbacks" not in light["body"]
                      and abs(got["usd"] - claude.cost("claude-haiku-5-5", 12, 3, 0, 40)) < 1e-12,
                      "本物の部品で light: /v1/messages・system に cache_control・覚えさせた分も値段に")
        claude.call(None, "本文", tier="deep", purpose="check")
        deep = seen[-1]
        failed += say(deep["body"]["model"] == "claude-opus-5-5" and deep["body"].get("fallbacks") == "default"
                      and claude.FALLBACK_BETA in deep["headers"].get("anthropic-beta", "")
                      and "thinking" not in deep["body"],
                      "本物の部品で deep: opus・anthropic-beta に server-side-fallback・fallbacks は default")
        seen.clear()
        try:
            claude.call(None, '{"x":1}', json=True, schema=claude.JUDGE_SCHEMA, purpose="check")
        except claude.ClaudeError:
            pass  # 作り物の答えは JSON ではないので失敗でよい（送る形だけを見る）
        failed += say(bool(seen) and seen[-1]["body"].get("output_config", {}).get("format", {}).get("type") == "json_schema",
                      "本物の部品で JSON の形: output_config.format が json_schema")
        for code, want in ((500, 502), (401, 503)):
            status_box["status"] = code
            try:
                claude.call(None, "本文", purpose="check")
                failed += say(False, f"本物の部品で {code}")
            except claude.ClaudeError as error:
                text = json.dumps(error.body, ensure_ascii=False) + repr(error) + str(error.__context__)
                failed += say(error.status == want and SECRET not in text,
                              f"本物の部品で API が {code} → {want}（鍵を出さない）")
    finally:
        fake.shutdown()
        fake.server_close()
        reset_files()
    return failed


# MARK: - 母艦の写し


def check_feeds() -> int:
    failed = 0
    with tempfile.TemporaryDirectory() as folder:
        base = Path(folder)
        failed += say(all(appfeeds.READERS[p](base).get("available") is False
                          for p in ("/proposals", "/plaud-fill", "/speaker-doubts")), "母艦の写し3つ: 無ければ available false")
        failed += say(all(p in mothership.GETS for p in ("/proposals", "/plaud-fill", "/speaker-doubts"))
                      and "/proposals/answer" in mothership.POSTS, "GETS・POSTS に入っている")
        (base / "state").mkdir()
        good = {"id": "p-20261113-1", "kind": "followup", "title": "あの件を確かめる", "body": "本文" * 10,
                "evidence": [{"text": "根拠", "when": "2026-11-12T10:00:00+09:00", "source": "conversation"},
                             {"text": "変な出どころ", "when": None, "source": "mail"},
                             {"text": "時刻が変", "when": "きのう", "source": "line"}],
                "action": {"type": "task", "text": "電話する", "reading": "でんわ"},
                "created": "2026-11-13T07:00:00+09:00", "expires": None}
        rows = [good,
                dict(good, id="p-2", kind="vocab", action={"type": "vocab", "text": "言葉", "reading": "ことば"},
                     title="t" * 100, expires="2099-01-01T00:00:00+09:00"),
                dict(good, id="p-1"),                                    # 前と同じ id ではない（別の id）
                dict(good, id="p-20261113-1"),                           # 同じ id は2つ目を落とす
                dict(good, id="p-3", kind="unknown"),                    # 知らない種類
                dict(good, id="bad id!"),                                # id の形
                dict(good, id="p-4", title=""),                          # 題が無い
                dict(good, id="p-5", action={"type": "task", "text": ""}),  # やることの文が無い
                dict(good, id="p-6", created="きょう"),                   # 作った日時の形
                dict(good, id="p-7", expires="2001-01-01T00:00:00+09:00"),  # 期限切れ
                "文", 3]
        (base / appfeeds.PROPOSALS).write_text(json.dumps({"generated_at": "2026-11-13T07:00:00+09:00", "items": rows},
                                                          ensure_ascii=False), encoding="utf-8-sig")
        got = appfeeds.read_proposals(base)
        ids = [i["id"] for i in got.get("items") or []]
        first = (got.get("items") or [{}])[0]
        failed += say(got.get("available") is True and ids == ["p-20261113-1", "p-2", "p-1"]
                      and len(first.get("evidence") or []) == 1 and first["action"] == {"type": "task", "text": "電話する",
                                                                                        "reading": None}
                      and len(got["items"][1]["title"]) == 60 and got["items"][1]["action"]["reading"] == "ことば",
                      f"提案: おかしな行・同じ id・期限切れを落とす（{ids}）")
        answers = [appfeeds.parse_answer(json.dumps({"id": "p-2", "answer": "accept"}).encode()),
                   appfeeds.parse_answer(json.dumps({"id": "p-7", "answer": "never"}).encode()),
                   appfeeds.parse_answer(json.dumps({"id": "p-unknown", "answer": "later"}).encode())]
        for a in answers:
            appfeeds.append_answer(base, a)
        lines = [json.loads(x) for x in (base / appfeeds.PROPOSAL_ANSWERS).read_text(encoding="utf-8").splitlines()]
        failed += say([(x["id"], x["kind"], x["answer"]) for x in lines]
                      == [("p-2", "vocab", "accept"), ("p-7", "followup", "never"), ("p-unknown", "", "later")]
                      and all(set(x) == {"id", "kind", "answer", "at"} and appfeeds._iso(x["at"]) for x in lines),
                      "提案への答え: inbox/proposal_answers.jsonl に1行ずつ（kind は一覧から・分からなければ \"\"）")
        bad = 0
        for body in (b"x", b"[]", b'{"id": "p-1"}', b'{"id": "p-1", "answer": "yes"}', b'{"id": "bad id!", "answer": "accept"}',
                     b'{"id": 3, "answer": "accept"}'):
            try:
                appfeeds.parse_answer(body)
            except ValueError:
                bad += 1
        failed += say(bad == 6, f"提案への答え: おかしな中身は受けない（{bad}/6）")
        fill = {"generated_at": "x", "days": [
            {"day": "2026-11-12", "ranges": [
                {"start": "2026-11-12T10:00:00+09:00", "end": "2026-11-12T10:30:00+09:00", "lines": [
                    {"time": "2026-11-12T10:01:00+09:00", "speaker": "話し手1", "text": "文" * 500},
                    {"time": "2026-11-12T10:02:00+09:00", "speaker": None, "text": "短い"},
                    {"time": "そのころ", "speaker": None, "text": "時刻が変"},
                    {"time": "2026-11-12T10:03:00+09:00", "speaker": 5, "text": "話し手が数"},
                    {"time": "2026-11-12T10:04:00+09:00", "text": ""}]},
                {"start": "2026-11-12T11:00:00+09:00", "end": "2026-11-12T10:00:00+09:00", "lines": [
                    {"time": "2026-11-12T11:01:00+09:00", "text": "終わりが前"}]}]},
            {"day": "きのう", "ranges": []}] + [{"day": f"2026-10-{d:02d}", "ranges": [
                {"start": "2026-10-01T10:00:00+09:00", "end": "2026-10-01T10:01:00+09:00",
                 "lines": [{"time": "2026-10-01T10:00:00+09:00", "text": "x"}]}]} for d in range(1, 20)]}
        (base / appfeeds.PLAUD_FILL).write_text(json.dumps(fill, ensure_ascii=False), encoding="utf-8")
        got = appfeeds.read_plaud_fill(base)
        day = (got.get("days") or [{}])[0]
        ranges = day.get("ranges") or []
        failed += say(got.get("available") is True and len(got["days"]) == 14 and day.get("day") == "2026-11-12"
                      and len(ranges) == 1 and [len(x["text"]) for x in ranges[0]["lines"]] == [400, 2]
                      and ranges[0]["lines"][1]["speaker"] is None,
                      "PLAUD の文の補い: おかしな日・区間・行を落とし、14 日・400 文字まで")
        doubts = {"items": [
            {"day": "2026-11-12", "conversation_start": "2026-11-12T10:00:00+09:00", "line_time": "2026-11-12T10:05:00+09:00",
             "text_head": "頭" * 50, "current": "自分", "suggest": "other", "why": "plaud-turn", "score": 0.8},
            {"day": "2026-11-12", "conversation_start": "2026-11-12T10:00:00+09:00", "line_time": "2026-11-12T10:05:00+09:00",
             "text_head": "x", "current": "自分", "suggest": "rename", "why": "text", "score": 0.5},
            {"day": "2026-11-12", "conversation_start": "x", "line_time": "2026-11-12T10:05:00+09:00",
             "text_head": "x", "current": "自分", "suggest": "self", "why": "text", "score": 0.5},
            {"day": "2026-11-12", "conversation_start": "2026-11-12T10:00:00+09:00", "line_time": "2026-11-12T10:05:00+09:00",
             "text_head": "x", "current": "自分", "suggest": "self", "why": "text", "score": 1.5}]
            + [{"day": "2026-11-12", "conversation_start": "2026-11-12T10:00:00+09:00",
                "line_time": "2026-11-12T10:05:00+09:00", "text_head": "x", "current": "a", "suggest": "self",
                "why": "text", "score": 0.1}] * 300}
        (base / appfeeds.SPEAKER_DOUBTS).write_text(json.dumps(doubts, ensure_ascii=False), encoding="utf-8")
        got = appfeeds.read_speaker_doubts(base)
        items = got.get("items") or []
        failed += say(got.get("available") is True and len(items) == 200 and len(items[0]["text_head"]) == 40
                      and items[0]["suggest"] == "other" and all(i["score"] <= 1 for i in items),
                      "話し手の疑い: おかしな行を落とし、200 件・40 文字まで")
    return failed


# MARK: - 割れた行の審判（精6）


def split_line(text: str, votes: dict, confidence: float = 0.3) -> dict:
    return {"start": 0.0, "end": 3.0, "text": text, "confidence": confidence, "votes": votes,
            "words": [[0.0, 1.0, text]], "alternatives": [v for v in votes.values() if v and v != text]}


def check_judge() -> int:
    failed = 0
    reset_files()
    fake = FakeClaude()
    claude.CLIENT_FACTORY = fake.factory

    def make_lines() -> list[dict]:
        return [
            {"start": 0.0, "end": 2.0, "text": "そろった行", "confidence": 1.0, "votes": {"haas": "そろった行"}},
            split_line("明日の予算の話", {"haas": "明日の予算の話", "reazon": "あしたの洋服の話", "whisper": "明日の予算の話"}),
            split_line("会議室Bで", {"haas": "会議室Bで", "reazon": "会議室ビーで", "whisper": "会議しつBで"}),
            split_line("三時に", {"haas": "三時に", "reazon": "散時に"}),
            split_line("ひとつだけ", {"haas": "ひとつだけ", "reazon": ""}),  # 候補が1つしか無い
        ]

    def picks(kwargs) -> str:
        return json.dumps({"picks": [
            {"line": 1, "index": 1},          # 替える
            {"line": 1, "index": 0},          # 同じ行の2つ目は使わない
            {"line": 2, "index": 9},          # 番号が無い
            {"line": 3, "index": True},       # 真偽は番号ではない
            {"line": 0, "index": 0},          # 頼んでいない行
            {"line": "3", "index": 0},        # 行の番号が文
            "x"]})

    lines = make_lines()
    result = claude.judge(lines, ["予算"], work=None)
    failed += say(result["calls"] == 0 and result["skipped"] == "鍵が無い" and not fake.calls and lines == make_lines(),
                  f"鍵が無ければ審判しない（多数決の文のまま）: {result}")
    put_key()
    fake.reply = picks
    lines = make_lines()
    logged: list[str] = []
    result = claude.judge(lines, ["予算"], work=None, log=logged.append)
    beta, sent = fake.calls[-1]
    asked = json.loads(sent["messages"][0]["content"])
    failed += say(result["split"] == 3 and result["asked"] == 3 and result["changed"] == 1 and result["calls"] == 1
                  and not beta and sent["model"] == "claude-haiku-5-5" and "output_config" in sent
                  and sent["system"][0]["text"] == claude.JUDGE_SYSTEM
                  and [r["line"] for r in asked["lines"]] == [1, 2, 3] and asked["words"] == ["予算"]
                  and asked["lines"][0]["candidates"] == ["明日の予算の話", "あしたの洋服の話"],
                  f"食い違いの大きい行だけを、候補つきで haiku に1回で頼む（{result}）")
    changed = lines[1]
    failed += say(changed["text"] == "あしたの洋服の話" and changed["judge"] == {"picked": 1, "model": "claude-haiku-5-5",
                                                                       "before": "明日の予算の話"}
                  and "明日の予算の話" in changed["alternatives"] and "words" not in changed
                  and changed["votes"]["haas"] == "明日の予算の話",
                  "正しい番号の行だけ替える（前の文は judge.before と候補に残す・票はそのまま・言葉の時刻は外す）")
    failed += say(lines[2]["text"] == "会議室Bで" and "judge" not in lines[2] and lines[3]["text"] == "三時に"
                  and "judge" not in lines[3] and lines[0] == make_lines()[0] and lines[4] == make_lines()[4],
                  "番号がおかしい・答えの無い行は、多数決の文のまま（新しい文は入らない）")
    texts = {line["text"] for line in lines}
    every = {t for line in make_lines() for t in [line["text"], *line["votes"].values()]}
    failed += say(texts <= every, "審判のあとの文は、どれもモデルが書いた候補のどれか")
    fake.reply = lambda kwargs: '{"picks": [{"line": 1, "index": 0}]}'
    lines = make_lines()
    claude.judge(lines, [], work=None)
    failed += say(lines[1]["text"] == "明日の予算の話" and lines[1]["judge"] == {"picked": 0, "model": "claude-haiku-5-5"}
                  and "words" in lines[1], "審判が同じ文を選んだら、文も言葉の時刻もそのまま")
    for text in ("答えではない", '{"picks": "x"}', "[]"):
        fake.reply = lambda kwargs, t=text: t
        lines = make_lines()
        claude.judge(lines, [], work=None)
        failed += say(lines == make_lines(), f"おかしな答え（{text[:12]}）なら、どの行も替えない")
    fake.reply = picks
    put_config({"judge": False})
    calls = len(fake.calls)
    result = claude.judge(make_lines(), [], work=None)
    failed += say(len(fake.calls) == calls and result["skipped"] == "使わない設定", "設定の \"judge\": false なら頼まない")
    put_config({"work": False})
    result = claude.judge(make_lines(), [], work=None)
    failed += say(len(fake.calls) == calls and result["skipped"], "職場を送らない設定なら、職場か分からない区切りは頼まない")
    claude.judge(make_lines(), [], work=False)
    failed += say(len(fake.calls) == calls + 1, "職場を送らない設定でも、職場でないと分かる区切りは頼む")
    put_config({"judge_daily": claude.LEDGER.day_calls(claude.today(), claude.JUDGE_PURPOSE)})
    calls = len(fake.calls)
    result = claude.judge(make_lines(), [], work=None)
    failed += say(len(fake.calls) == calls and result["skipped"] == "今日の回数の上限", "1日の審判の回数の上限（judge_daily）")
    put_config({})
    many = [split_line(f"行{i}", {"haas": f"行{i}", "reazon": f"ぎょう{i}"}) for i in range(90)]
    calls = len(fake.calls)
    fake.reply = lambda kwargs: '{"picks": []}'
    result = claude.judge(many, [], work=None)
    failed += say(len(fake.calls) - calls == 3 and result["asked"] == 90, f"多い行は {claude.JUDGE_BATCH} 行ずつに分けて頼む")
    failed += say(SECRET not in "\n".join(logged) and "明日の予算の話" not in "\n".join(logged), "審判の記録に鍵も文も書かない")
    reset_files()
    return failed


# MARK: - 自動の材料（精7・仮）


def check_auto_samples(main) -> int:
    failed = 0
    rate = main.RATE
    audio = (np.sin(np.arange(rate * 20) / rate * 2 * np.pi * 220) * 0.2).astype(np.float32)
    logged: list[str] = []
    saved = (main.PERSONAL_DATA, main.log)
    with tempfile.TemporaryDirectory() as folder:
        try:
            main.PERSONAL_DATA = Path(folder) / "data"
            main.log = logged.append
            same = {"haas": "今日は会議があります", "reazon": "今日は会議があります", "whisper": "今日は会議があります",
                    "haas_e": "今日は会議があります"}
            lines = [
                {"start": 0.5, "end": 3.5, "text": "今日は会議があります", "confidence": 1.0, "votes": same},
                {"start": 4.0, "end": 5.0, "text": "今日は会議があります", "confidence": 1.0, "votes": same},  # 短い
                {"start": 6.0, "end": 9.0, "text": "明日は休みです", "confidence": 1.0,
                 "votes": {"haas": "明日は休みです", "reazon": "明日は休みです"}},                      # モデルが2つ
                {"start": 10.0, "end": 13.0, "text": "あさっては晴れ", "confidence": 0.6,
                 "votes": {"haas": "あさっては晴れ", "reazon": "あさっては雨", "whisper": "あさっては晴れ"}},  # 割れた
                {"start": 14.0, "end": 17.0, "text": "来週は出張です", "confidence": 0.7,
                 "votes": {"haas": "来週は出張です", "reazon": "来週は出張です", "whisper": ""}},          # 黙った
            ]
            failed += say(main.auto_samples(audio, lines, "job-1", {}) == 0 and not main.PERSONAL_DATA.exists(),
                          "自動の材料: 既定（config.json に auto_samples が無い）では足さない")
            added = main.auto_samples(audio, lines, "job-1", {"auto_samples": True})
            rows = main.read_samples(main.PERSONAL_DATA)
            source = rows[0].get("source") if rows else {}
            failed += say(added == 1 and len(rows) == 1 and rows[0]["text"] == "今日は会議があります"
                          and source.get("origin") == "pc-auto" and source.get("auto") is True
                          and source.get("job") == "job-1" and abs(rows[0]["seconds"] - 3.0) < 0.05,
                          f"自動の材料: 全部のモデルがそろった 2 秒以上の行だけを、pc-auto の印で足す（{added}）")
            old = main.AUTO_DAILY
            main.AUTO_DAILY = 1
            more = [dict(lines[0], start=s, end=s + 3.0) for s in (1.0, 2.0, 3.0)]
            failed += say(main.auto_samples(audio, more, "job-2", {"auto_samples": True}) == 0,
                          "自動の材料: 1日の上限（AUTO_DAILY）")
            main.AUTO_DAILY = old
            judged = dict(lines[0], start=7.0, end=10.0, judge={"picked": 0})
            failed += say(main.auto_samples(audio, [judged], "job-3", {"auto_samples": True}) == 0,
                          "自動の材料: 審判に回った行は使わない")
        finally:
            main.PERSONAL_DATA, main.log = saved
    import train_personal

    rows = [{"audio": f"h{i}.wav", "text": "x", "hash": f"h{i:04d}"} for i in range(40)] \
        + [{"audio": f"a{i}.wav", "text": "x", "hash": f"a{i:04d}", "source": {"origin": "pc-auto", "auto": True}}
           for i in range(100)]
    train, test = train_personal.split(rows, 1)
    failed += say(len(test) == 4 and all("source" not in r for r in test) and len(train) == 136,
                  "学び直しの試験には、自動の材料を使わない（学ぶほうにだけ入れる）")
    return failed


# MARK: - 受け口


def check_http(main) -> int:
    failed = 0
    reset_files()
    fake = FakeClaude()
    claude.CLIENT_FACTORY = fake.factory
    logged: list[str] = []
    saved = (getattr(main.Handler, "engine", None), getattr(main.Handler, "key", None), main.log)
    with tempfile.TemporaryDirectory() as folder:
        try:
            main.log = logged.append
            main.Handler.key = KEY
            main.Handler.engine = main.Ensemble(ops.fake_engines())
            config = main.load_config()
            config["lifelog_home"] = folder
            main.save_config(config)
            server = main.Server(("127.0.0.1", 0), main.Handler)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            client = Client(server.server_address[1])

            def post(body, key=KEY):
                data = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode("utf-8")
                return client.call("POST", "/claude", data, {"Content-Type": "application/json"}, key=key)

            status, body, _ = post({"prompt": "こんにちは", "purpose": "check"})
            failed += say(status == 503 and body == {"error": "Claude の鍵がありません"}, f"POST /claude: 鍵が無ければ 503 {status}")
            hello = client.call("GET", "/hello")
            failed += say(hello[0] == 200 and "claude" not in hello[1]["features"]
                          and all(f in hello[1]["features"] for f in ("proposals", "plaudfill", "spkdoubt")),
                          "/hello の features: 鍵が無ければ claude は無し・母艦の写し3つはいつも")
            put_key()
            status, body, _ = post({"system": "前置き", "prompt": "秘密の本文", "json": False, "max_tokens": 100,
                                    "tier": "light", "purpose": "check", "work": True})
            failed += say(status == 200 and set(body) == {"text", "model", "usd", "month_usd", "cap_usd"}
                          and body["text"] == "答えです" and fake.calls[-1][1]["max_tokens"] == 100,
                          f"POST /claude: 答えの形 {status} {sorted(body) if isinstance(body, dict) else body}")
            hello = client.call("GET", "/hello")
            failed += say("claude" in hello[1]["features"], "/hello の features: 鍵があり上限の前なら claude")
            bad_bodies = [b"x", b"[]", {"purpose": "check"}, {"prompt": " ", "purpose": "check"},
                          {"prompt": "x", "json": "yes"}, {"prompt": "x", "max_tokens": 9000},
                          {"prompt": "x", "max_tokens": True}, {"prompt": "x", "tier": "huge"},
                          {"prompt": "x", "purpose": "日本語"}, {"prompt": "x", "work": "no"}, {"prompt": "x", "system": 3}]
            got = [post(b)[0] for b in bad_bodies]
            failed += say(all(s == 400 for s in got), f"POST /claude: おかしな中身は 400（{got}）")
            wrong = post({"prompt": "x"}, key="wrong")
            failed += say(wrong[0] == 401, "POST /claude: 合言葉が違えば 401")
            fake.stop = "refusal"
            status, body, _ = post({"prompt": "x", "purpose": "check"})
            failed += say(status == 422 and body == {"error": "断られました", "refusal": True}, f"POST /claude: 断られたら 422 {status}")
            fake.stop = "end_turn"
            put_config({"work": False})
            failed += say(post({"prompt": "x", "purpose": "check", "work": True})[0] == 403
                          and post({"prompt": "x", "purpose": "check"})[0] == 403
                          and post({"prompt": "x", "purpose": "check", "work": False})[0] == 200,
                          "POST /claude: 職場を送らない設定なら work（省いたときも）は 403")
            fake.error = LeakyError(f"boom {SECRET}")
            status, body, _ = post({"prompt": "x", "purpose": "check", "work": False})
            failed += say(status == 502 and SECRET not in json.dumps(body), "POST /claude: SDK のエラーでも鍵を返さない")
            fake.error = None
            status, usage, _ = client.call("GET", "/claude/usage")
            failed += say(status == 200 and set(usage) == {"available", "month", "month_usd", "cap_usd", "calls",
                                                          "by_purpose", "by_who"}
                          and usage["available"] is True and usage["calls"] == 3 and "check" in usage["by_purpose"]
                          and set(usage["by_who"]) >= {"pc", "mothership"},
                          f"GET /claude/usage の形 {usage}")
            put_config({"monthly_usd": 0.000001})
            status, body, _ = post({"prompt": "x", "purpose": "check", "work": False})
            hello = client.call("GET", "/hello")
            failed += say(status == 402 and body.get("error") == "今月の上限に達しました" and "month_usd" in body
                          and "cap_usd" in body and "claude" not in hello[1]["features"],
                          f"POST /claude: 上限なら 402・features から claude を外す {status}")
            unauth = client.call("GET", "/claude/usage", key="wrong")
            failed += say(unauth[0] == 401, "GET /claude/usage も合言葉が要る")
            # 母艦の写しの受け口
            (Path(folder) / "state").mkdir(exist_ok=True)
            (Path(folder) / appfeeds.PROPOSALS).write_text(json.dumps({"items": [
                {"id": "p-1", "kind": "health", "title": "早く寝る", "body": "", "evidence": [],
                 "action": {"type": "none"}, "created": "2026-11-13T07:00:00+09:00", "expires": None}]},
                ensure_ascii=False), encoding="utf-8")
            status, body, _ = client.call("GET", "/proposals")
            failed += say(status == 200 and [i["id"] for i in body.get("items", [])] == ["p-1"], "GET /proposals")
            status, body, _ = client.call("POST", "/proposals/answer", json.dumps({"id": "p-1", "answer": "later"}).encode(),
                                          {"Content-Type": "application/json"})
            line = (Path(folder) / appfeeds.PROPOSAL_ANSWERS).read_text(encoding="utf-8").strip()
            failed += say(status == 200 and body == {"ok": True} and json.loads(line)["kind"] == "health",
                          "POST /proposals/answer → 母艦の inbox に1行")
            status, body, _ = client.call("POST", "/proposals/answer", b'{"id": "p-1", "answer": "maybe"}',
                                          {"Content-Type": "application/json"})
            failed += say(status == 400, "POST /proposals/answer: おかしな答えは 400")
            missing = [client.call("GET", p)[1].get("available") for p in ("/plaud-fill", "/speaker-doubts")]
            failed += say(missing == [False, False], "GET /plaud-fill・/speaker-doubts: 無ければ available false")
            everything = json.dumps([hello, usage], ensure_ascii=False) + "\n".join(logged) \
                + claude.ledger_path().read_text(encoding="utf-8")
            failed += say(SECRET not in everything and "秘密の本文" not in "\n".join(logged)
                          and "前置き" not in "\n".join(logged),
                          "鍵は /hello・/claude/usage・記録・帳簿のどこにも出ない（頼んだ文も記録に書かない）")
            server.shutdown()
            server.server_close()
        finally:
            main.Handler.engine, main.Handler.key, main.log = saved
            reset_files()
    return failed
