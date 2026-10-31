"""LifeLog PC — 家の PC で Haas-ja を動かし、iPhone から送られた音声を文字にする。

使うモデルは Haas-ja-v1.0（Third Intelligence、Apache-2.0）の ONNX 版
oboroge0/Haas-ja-v1.0-onnx（非公式の変換、Apache-2.0）。sherpa-onnx で CPU で動く。
初回にモデル（約2.4GB）を取ってきて、%LOCALAPPDATA%\\LifeLogPC に置く。

iPhone のアプリは、声のある区間（端末内の文字起こしで決めたもの）と 5 分の録音（AAC）を送ってくる。
区間ごとに文字にして返す。合言葉（起動したときに表示される）が合わない相手には何も返さない。

    LifeLogPC.exe                 普通に起動する（受け付けを始める）
    LifeLogPC.exe --test 音声     その音声を文字にして、かかった時間を表示する
    LifeLogPC.exe --startup       Windows の起動時に自動で始まるようにする（--no-startup でやめる）
"""

from __future__ import annotations

import argparse
import io
import json
import os
import secrets
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import numpy as np

VERSION = 1
PORT = 8765
RATE = 16000
REPO = "oboroge0/Haas-ja-v1.0-onnx"
# モデルの版を固定する（CI で確かめた版）
REVISION = os.environ.get("LIFELOG_HAAS_REVISION", "main")
# 1つの区間の長さの上限（モデルの説明で試されているのは約29秒まで）
MAX_SEGMENT = 20.0

HOME = Path(os.environ.get("LOCALAPPDATA") or Path.home() / ".local" / "share") / "LifeLogPC"
MODEL_DIR = HOME / "model"
CONFIG = HOME / "config.json"
LOG = HOME / "log.txt"


def log(message: str) -> None:
    line = time.strftime("%Y-%m-%d %H:%M:%S ") + message
    print(line, flush=True)
    try:
        HOME.mkdir(parents=True, exist_ok=True)
        with LOG.open("a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


# MARK: - 設定（合言葉）


def load_config() -> dict:
    try:
        return json.loads(CONFIG.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def save_config(config: dict) -> None:
    HOME.mkdir(parents=True, exist_ok=True)
    CONFIG.write_text(json.dumps(config, ensure_ascii=False, indent=2), encoding="utf-8")


def passphrase() -> str:
    config = load_config()
    if not config.get("key"):
        # 打ちやすいよう、紛らわしい文字を除いた 12 文字
        alphabet = "abcdefghjkmnpqrstuvwxyz23456789"
        config["key"] = "".join(secrets.choice(alphabet) for _ in range(12))
        save_config(config)
    return config["key"]


# MARK: - モデル


def model_files() -> dict[str, Path] | None:
    """取ってきたモデルのファイル。揃っていなければ None。"""

    def find(prefix: str, suffix: str) -> Path | None:
        found = sorted(p for p in MODEL_DIR.rglob(f"{prefix}*{suffix}") if p.is_file())
        # int8 などの別の版が混ざっていたら、そうでないものを選ぶ
        plain = [p for p in found if "int8" not in p.name]
        return (plain or found or [None])[0]

    files = {
        "encoder": find("encoder", ".onnx"),
        "decoder": find("decoder", ".onnx"),
        "joiner": find("joiner", ".onnx"),
        "tokens": find("tokens", ".txt"),
    }
    if any(v is None for v in files.values()):
        return None
    return files  # type: ignore[return-value]


def download_model() -> dict[str, Path]:
    files = model_files()
    if files:
        return files
    log(f"Haas-ja のモデル（約2.4GB）を取ってきます。初回だけです。置き場所: {MODEL_DIR}")
    from huggingface_hub import snapshot_download

    snapshot_download(repo_id=REPO, revision=REVISION, local_dir=str(MODEL_DIR),
                      allow_patterns=["*.onnx", "*.data", "*.txt", "LICENSE*", "NOTICE*", "*.md"])
    files = model_files()
    if not files:
        raise RuntimeError("モデルのファイルが揃いませんでした（encoder/decoder/joiner/tokens）")
    return files


class Engine:
    """sherpa-onnx で Haas-ja を動かす。一度に1つずつ。"""

    def __init__(self, threads: int, provider: str) -> None:
        import sherpa_onnx

        files = download_model()
        log("モデルを読み込んでいます…")
        started = time.time()
        self.recognizer = sherpa_onnx.OfflineRecognizer.from_transducer(
            encoder=str(files["encoder"]),
            decoder=str(files["decoder"]),
            joiner=str(files["joiner"]),
            tokens=str(files["tokens"]),
            num_threads=threads,
            sample_rate=RATE,
            feature_dim=128,
            decoding_method="greedy_search",
            model_type="nemo_transducer",
            provider=provider,
        )
        self.lock = threading.Lock()
        self.provider = provider
        log(f"読み込みました（{time.time() - started:.1f} 秒、{provider}、{threads} スレッド）")

    def transcribe(self, audio: np.ndarray, segments: list[tuple[float, float]]) -> list[dict]:
        lines = []
        with self.lock:
            for start, end in segments:
                a = max(0, int(start * RATE))
                b = min(len(audio), int(end * RATE))
                if b - a < int(0.3 * RATE):
                    continue
                stream = self.recognizer.create_stream()
                stream.accept_waveform(RATE, audio[a:b])
                self.recognizer.decode_stream(stream)
                text = stream.result.text.strip()
                if text:
                    lines.append({"start": round(start, 2), "end": round(end, 2), "text": text})
        return lines


# MARK: - 音声


def load_audio(data: bytes) -> np.ndarray:
    """m4a（AAC）や wav などを 16kHz モノラルの float32 にする。"""
    import av

    chunks = []
    with av.open(io.BytesIO(data)) as container:
        stream = container.streams.audio[0]
        resampler = av.AudioResampler(format="flt", layout="mono", rate=RATE)
        for frame in container.decode(stream):
            for out in resampler.resample(frame):
                chunks.append(out.to_ndarray().reshape(-1))
        for out in resampler.resample(None):
            chunks.append(out.to_ndarray().reshape(-1))
    if not chunks:
        return np.zeros(0, dtype=np.float32)
    return np.concatenate(chunks).astype(np.float32)


def parse_segments(text: str | None, duration: float) -> list[tuple[float, float]]:
    """"0.0-3.2,5.1-9.0" の形。無ければ全体を区切る。長すぎる区間は分ける。"""
    raw: list[tuple[float, float]] = []
    if text:
        for part in text.split(","):
            try:
                a, b = part.split("-")
                raw.append((float(a), float(b)))
            except ValueError:
                continue
    else:
        raw = [(0.0, duration)]
    result = []
    for start, end in raw:
        start, end = max(0.0, start), min(duration, end)
        while end - start > MAX_SEGMENT:
            result.append((start, start + MAX_SEGMENT))
            start += MAX_SEGMENT
        if end > start:
            result.append((start, end))
    return result


# MARK: - 受け付け


class Handler(BaseHTTPRequestHandler):
    engine: Engine
    key: str
    server_version = "LifeLogPC"

    def log_message(self, format: str, *args) -> None:  # 標準の出力は使わない
        pass

    def send_json(self, status: int, body: dict) -> None:
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorized(self) -> bool:
        given = self.headers.get("Authorization", "").removeprefix("Bearer ").strip()
        if secrets.compare_digest(given, self.key):
            return True
        log(f"合言葉の違う接続を断りました: {self.client_address[0]}")
        self.send_json(401, {"error": "合言葉が違います"})
        return False

    def do_GET(self) -> None:
        if urlparse(self.path).path != "/hello":
            self.send_json(404, {"error": "not found"})
            return
        if not self.authorized():
            return
        self.send_json(200, {"app": "LifeLogPC", "version": VERSION, "model": "Haas-ja-v1.0",
                             "provider": self.engine.provider})

    def do_POST(self) -> None:
        url = urlparse(self.path)
        if url.path != "/transcribe":
            self.send_json(404, {"error": "not found"})
            return
        if not self.authorized():
            return
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > 200_000_000:
            self.send_json(400, {"error": "音声がありません"})
            return
        data = self.rfile.read(length)
        started = time.time()
        try:
            audio = load_audio(data)
            duration = len(audio) / RATE
            query = parse_qs(url.query)
            segments = parse_segments((query.get("segments") or [None])[0], duration)
            lines = self.engine.transcribe(audio, segments)
        except Exception as error:  # noqa: BLE001 — 何があっても受け付けは続ける
            log(f"文字にできませんでした: {error!r}")
            self.send_json(500, {"error": str(error)})
            return
        took = time.time() - started
        voiced = sum(b - a for a, b in segments)
        log(f"{self.client_address[0]} から {duration:.0f} 秒（声 {voiced:.0f} 秒）→ {len(lines)} 行、{took:.1f} 秒")
        self.send_json(200, {"lines": lines, "seconds": round(took, 2)})


def addresses() -> list[str]:
    """iPhone に入れる宛先の候補。Tailscale（100.x）を先に。"""
    found = set()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            found.add(info[4][0])
    except OSError:
        pass
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("192.0.2.1", 80))  # 実際には送らない。外向きの宛先を知るだけ
            found.add(s.getsockname()[0])
    except OSError:
        pass
    found.discard("127.0.0.1")

    def order(ip: str) -> tuple[int, str]:
        first, second = (int(x) for x in ip.split(".")[:2])
        tailscale = first == 100 and 64 <= second <= 127
        return (0 if tailscale else 1, ip)

    return sorted(found, key=order)


def serve(threads: int, provider: str) -> None:
    key = passphrase()
    engine = Engine(threads, provider)
    Handler.engine = engine
    Handler.key = key
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print()
    print("=" * 60)
    print(" LifeLog PC を始めました。この画面は閉じずに置いておいてください。")
    print()
    print(" iPhone の LifeLog → 設定 → 家の PC に、次の2つを入れます。")
    for ip in addresses():
        tag = "（Tailscale・外からも使える）" if ip.startswith("100.") else "（家の Wi-Fi の中だけ）"
        print(f"   宛先: {ip}  {tag}")
    print(f"   合言葉: {key}")
    print("=" * 60)
    print(flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


# MARK: - 起動時に始める


def startup_file() -> Path:
    appdata = Path(os.environ.get("APPDATA", Path.home()))
    return appdata / "Microsoft" / "Windows" / "Start Menu" / "Programs" / "Startup" / "LifeLogPC.bat"


def set_startup(on: bool) -> None:
    path = startup_file()
    if on:
        exe = Path(sys.executable if getattr(sys, "frozen", False) else sys.argv[0]).resolve()
        command = f'"{exe}"' if getattr(sys, "frozen", False) else f'"{sys.executable}" "{exe}"'
        path.write_text(f'@echo off\r\nstart "LifeLog PC" /min {command}\r\n', encoding="utf-8")
        print(f"Windows の起動時に LifeLog PC が始まるようにしました（{path}）")
    else:
        path.unlink(missing_ok=True)
        print("Windows の起動時に始めるのをやめました")


# MARK: - 試す


def test(path: str, threads: int, provider: str, segments: str | None) -> None:
    engine = Engine(threads, provider)
    audio = load_audio(Path(path).read_bytes())
    duration = len(audio) / RATE
    started = time.time()
    lines = engine.transcribe(audio, parse_segments(segments, duration))
    took = time.time() - started
    for line in lines:
        print(f"[{line['start']:.1f}-{line['end']:.1f}] {line['text']}")
    print(f"音声 {duration:.1f} 秒を {took:.1f} 秒で文字にしました（実時間の {took / max(duration, 0.01):.3f} 倍）")
    if not lines:
        sys.exit(1)


def main() -> None:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")  # type: ignore[union-attr]
    parser = argparse.ArgumentParser(description="LifeLog PC（家の PC で Haas-ja を動かす）")
    parser.add_argument("--test", metavar="音声", help="音声を文字にして、かかった時間を表示する")
    parser.add_argument("--segments", help="--test で使う区間（例 0-3.5,4-9）")
    parser.add_argument("--download", action="store_true", help="モデルを取ってくるだけ")
    parser.add_argument("--startup", action="store_true", help="Windows の起動時に自動で始める")
    parser.add_argument("--no-startup", action="store_true", help="起動時に始めるのをやめる")
    parser.add_argument("--threads", type=int, default=max(1, min(8, (os.cpu_count() or 4) // 2)))
    parser.add_argument("--provider", default="cpu", help="cpu（既定）または cuda")
    args = parser.parse_args()

    if args.startup or args.no_startup:
        set_startup(args.startup)
        return
    if args.download:
        print(download_model())
        return
    if args.test:
        test(args.test, args.threads, args.provider, args.segments)
        return
    try:
        serve(args.threads, args.provider)
    except Exception as error:  # noqa: BLE001
        log(f"始められませんでした: {error!r}")
        if getattr(sys, "frozen", False):
            input("Enter を押すと閉じます")
        raise


if __name__ == "__main__":
    main()
