"""2026-11-16（強化案 75。docs/v19-pc-llm.md）: この PC の言語モデルまわりの直しを確かめる。

    python pc/v19checks_llm.py

本物の Ollama・GPU・Claude・iPhone は使わない（作り物の Ollama をこの PC の中に立て、一時フォルダを使う）。確かめること:
- 意味で探すの bge-m3 に keep_alive を付ける（config.json の "embed_keep_alive"。既定 "30m"・false で付けない＝前と同じ）。
  読み方（"1h"・秒の数・おかしな値は既定・ずっと載せたまま -1 にはしない）と、作り物の Ollama に届いた中身
- MCP サーバーも同じ config.json の値で頼む
- /llm で待つのは既定 175 秒（iPhone の 180 秒より短く）。"llm_timeout_seconds" は 30〜600 に収める
- 時間切れのあとも「Ollama が動いていない」にしない（すぐ次の頼みに答える）。つながらないときは今までどおり使えないにする
- 長すぎる頼み（既定 5,000 文字より長い。"llm_prompt_max_chars"）は Ollama に渡さず、すぐ 413 と上限を返す（2026-11-16）
"""

from __future__ import annotations

import inspect
import json
import socket
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import semantic  # noqa: E402
from v6checks import say  # noqa: E402


class FakeOllama(BaseHTTPRequestHandler):
    """作り物の Ollama。届いた中身を覚え、/api/chat は slow 秒待ってから答える"""

    bodies: list[dict] = []
    slow = 0.0

    def log_message(self, *args) -> None:  # noqa: D102 — 黙らせる
        pass

    def reply(self, body: dict) -> None:
        data = json.dumps(body).encode("utf-8")
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except OSError:
            pass  # 待ちきれずに閉じられた

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/api/tags":
            self.reply({"models": [{"name": "qwen3:8b"}, {"name": "bge-m3:latest"}]})
        else:
            self.reply({})

    def do_POST(self) -> None:  # noqa: N802
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        FakeOllama.bodies.append({"path": self.path, **body})
        if self.path == "/api/embed":
            self.reply({"embeddings": [[1.0, 0.0, 0.0] for _ in body.get("input") or []]})
        elif self.path == "/api/chat":
            if FakeOllama.slow:
                time.sleep(FakeOllama.slow)
            self.reply({"message": {"content": '{"ok": true}'}})
        else:
            self.reply({})


def start_fake() -> tuple[ThreadingHTTPServer, str]:
    server = ThreadingHTTPServer(("127.0.0.1", 0), FakeOllama)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_address[1]}"


def check_keep_alive(url: str) -> int:
    failed = 0
    read = semantic.embed_keep_alive
    values = [read({}), read(None), read({"embed_keep_alive": False}), read({"embed_keep_alive": 0}),
              read({"embed_keep_alive": "off"}), read({"embed_keep_alive": "1h"}), read({"embed_keep_alive": " 45M "}),
              read({"embed_keep_alive": 900}), read({"embed_keep_alive": -1}), read({"embed_keep_alive": "ずっと"}),
              read({"embed_keep_alive": True}), read({"embed_keep_alive": 999999})]
    failed += say(values == ["30m", "30m", None, None, None, "1h", "45m", 900, "30m", "30m", "30m", "30m"],
                  f"embed_keep_alive の読み方（既定 30m・false/0/off は付けない・-1 や変な値は既定。{values}）")

    FakeOllama.bodies.clear()
    kept = semantic.OllamaEmbedder(url, options=lambda: {"num_gpu": 0}, keep_alive="30m")
    vectors = kept.embed(["一つ目", "二つ目"])
    plain = semantic.OllamaEmbedder(url)
    plain.embed(["三つ目"])
    first, second = FakeOllama.bodies[0], FakeOllama.bodies[1]
    failed += say(vectors.shape == (2, 3) and first.get("keep_alive") == "30m"
                  and first.get("options") == {"num_gpu": 0} and "keep_alive" not in second,
                  f"bge-m3 への頼みに keep_alive を付ける・付けない設定なら前と同じ（{first.get('keep_alive')}・"
                  f"{'keep_alive' in second}）")

    import lifelog_mcp

    got = [_mcp_keep_alive(lifelog_mcp, url, {"embed_keep_alive": "45m"}),
           _mcp_keep_alive(lifelog_mcp, url, {"embed_keep_alive": False}), _mcp_keep_alive(lifelog_mcp, url, {})]
    failed += say(got == ["45m", None, "30m"], f"MCP サーバーも config.json の embed_keep_alive で頼む（{got}）")
    return failed


def _mcp_keep_alive(lifelog_mcp, url: str, config: dict):
    """make_tools が作る embedder の keep_alive を見る（semantic.db が無くても見られるよう、作る所を一時的に差し替える）"""
    made: list = []
    real = semantic.OllamaEmbedder

    class Spy(real):  # type: ignore[misc, valid-type]
        def __init__(self, *args, **kwargs) -> None:
            super().__init__(*args, **kwargs)
            made.append(self)

    with tempfile.TemporaryDirectory() as tmp:
        home = Path(tmp)
        (home / "config.json").write_text(json.dumps(config), encoding="utf-8")
        semantic.OllamaEmbedder = Spy
        try:
            lifelog_mcp.make_tools(home, ollama_url=url)
        finally:
            semantic.OllamaEmbedder = real
    return made[0].keep_alive if made else "作られなかった"


def check_llm(url: str) -> int:
    failed = 0
    import lifelog_pc as main

    read = main.llm_timeout
    values = [read({}), read(None), read({"llm_timeout_seconds": 60}), read({"llm_timeout_seconds": 5}),
              read({"llm_timeout_seconds": 9999}), read({"llm_timeout_seconds": "長く"}),
              read({"llm_timeout_seconds": True})]
    failed += say(values == [175.0, 175.0, 60.0, 30.0, 600.0, 175.0, 175.0] and main.LLM_TIMEOUT < 180,
                  f"/llm で待つ秒の読み方（既定 175・30〜600・iPhone の 180 秒より短い。{values}）")
    default = inspect.signature(main.LocalLLM).parameters["timeout"].default
    failed += say(default == main.LLM_TIMEOUT, f"LocalLLM の待つ秒の既定は LLM_TIMEOUT（{default}）")

    llm = main.LocalLLM(url=url, model="qwen3:8b", enabled=True, timeout=0.5)
    first_ok = llm.available(force=True)
    FakeOllama.slow = 1.5
    timed_out = False
    try:
        llm.generate("作り物の頼み", True, 16)
    except TimeoutError:
        timed_out = True
    except Exception as error:  # noqa: BLE001
        print(f"   時間切れのかわりに {error!r}")
    FakeOllama.slow = 0.0
    still = llm.ok
    try:
        answer = llm.generate("作り物の頼み", True, 16)
    except Exception as error:  # noqa: BLE001
        answer = repr(error)
    failed += say(first_ok and timed_out and still and answer == '{"ok": true}',
                  f"時間切れのあとも Ollama を使えないにせず、すぐ次に答える（時間切れ {timed_out}・ok {still}・{answer}）")

    # つながらない宛先（空いている番号）は、今までどおり使えないにする
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    gone = main.LocalLLM(url=f"http://127.0.0.1:{port}", model="qwen3:8b", enabled=True, timeout=0.5)
    gone.ok = True
    gone.checked = time.time()
    try:
        gone.generate("作り物の頼み", True, 16)
        raised = False
    except OSError:
        raised = True
    failed += say(raised and gone.ok is False, f"つながらないときは今までどおり使えないにする（{raised}・ok {gone.ok}）")
    return failed


def check_too_long() -> int:
    """長すぎる頼みはすぐ断る（Ollama に渡さない）。上限の読み方と、/llm の答え"""
    failed = 0
    import lifelog_pc as main

    read = main.llm_prompt_max
    values = [read({}), read(None), read({"llm_prompt_max_chars": 8000}), read({"llm_prompt_max_chars": 10}),
              read({"llm_prompt_max_chars": 10**9}), read({"llm_prompt_max_chars": "長く"}),
              read({"llm_prompt_max_chars": True})]
    failed += say(values == [5000, 5000, 8000, 1000, main.LLM_PROMPT_MAX, 5000, 5000],
                  f"上限の読み方（{values}）")

    class Stub:
        calls = 0
        model = "stub"

        def generate(self, prompt, as_json, max_tokens):
            Stub.calls += 1
            return '{"ok": true}'

    class Fake:
        client_address = ("127.0.0.1", 0)

        def __init__(self):
            self.sent = None

        def send_json(self, status, body):
            self.sent = (status, body)

    saved = main.LLM
    try:
        main.LLM = Stub()
        long = Fake()
        main.Handler.llm(long, json.dumps({"prompt": "あ" * 5001, "json": True}).encode("utf-8"))
        short = Fake()
        main.Handler.llm(short, json.dumps({"prompt": "あ" * 4999, "json": True}).encode("utf-8"))
    finally:
        main.LLM = saved
    failed += say(long.sent is not None and long.sent[0] == 413 and long.sent[1].get("max_chars") == 5000,
                  f"5,001 文字は 413 と上限 5000（{long.sent and long.sent[0]}）")
    failed += say(short.sent is not None and short.sent[0] == 200 and Stub.calls == 1,
                  f"4,999 文字は今までどおり答える・長い頼みは Ollama に渡さない（呼んだ回数 {Stub.calls}）")
    return failed


def main() -> int:
    import lifelog_pc

    # 本物の %LOCALAPPDATA%\LifeLogPC（log.txt など）に書かないよう、先に一時フォルダへ替える
    lifelog_pc.isolate_home()
    server, url = start_fake()
    try:
        failed = check_keep_alive(url) + check_llm(url) + check_too_long()
    finally:
        server.shutdown()
    print("ぜんぶ OK" if not failed else f"NG が {failed} 個")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
