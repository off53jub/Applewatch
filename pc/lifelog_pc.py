"""LifeLog PC — 家の PC で3つの音声モデルを動かし、iPhone から送られた音声を多数決で文字にする。

使うモデル（どれも初回に取ってきて、%LOCALAPPDATA%\\LifeLogPC に置く）:
- Haas-ja-v1.0（Third Intelligence、Apache-2.0）の ONNX 版 oboroge0/Haas-ja-v1.0-onnx
  （非公式の変換、Apache-2.0）。sherpa-onnx で CPU で動く（約2.4GB）。
- ReazonSpeech k2 v2（reazon-research/reazonspeech-k2-v2、Apache-2.0）。sherpa-onnx で CPU で動く（約600MB）。
- Whisper large-v3（OpenAI、MIT）の CTranslate2 版。faster-whisper で、NVIDIA の GPU があれば GPU で動く。
  GPU の部品（cuBLAS・cuDNN、約1.3GB）は、初回に PyPI から取ってくる。GPU が無ければ CPU で large-v3-turbo を使う。

iPhone のアプリは、声のある区間（端末内の文字起こしで決めたもの）と 5 分の録音（AAC）を送ってくる。
区間ごとに3つのモデルで文字にし、読みがほかのモデルといちばん合う文を選んで返す（多数決）。
選んだ文の合い方を「確からしさ」、ほかのモデルの違う文を「候補」として一緒に返す。
合言葉（起動したときに表示される）が合わない相手には何も返さない。

    LifeLogPC.exe                 普通に起動する（受け付けを始める）
    LifeLogPC.exe --test 音声     その音声を文字にして、モデルごとの文とかかった時間を表示する
    LifeLogPC.exe --startup       Windows の起動時に自動で始まるようにする（--no-startup でやめる）
"""

from __future__ import annotations

import argparse
import difflib
import io
import json
import os
import re
import secrets
import socket
import sys
import threading
import time
import unicodedata
import zipfile
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import numpy as np

VERSION = 2
# 待ち受ける番号。8765 はほかのソフトとよくぶつかるので、使われにくい番号にする
PORT = 47615
RATE = 16000
REPO = "oboroge0/Haas-ja-v1.0-onnx"
# モデルの版を固定する（CI で確かめた版）
REVISION = os.environ.get("LIFELOG_HAAS_REVISION", "2c2133a4279fca8ee408dd33b5701690a0bd4f3f")
# 1つの区間の長さの上限（モデルの説明で試されているのは約29秒まで）
MAX_SEGMENT = 20.0

REAZON_REPO = "reazon-research/reazonspeech-k2-v2"
REAZON_REVISION = os.environ.get("LIFELOG_REAZON_REVISION", "main")

HOME = Path(os.environ.get("LOCALAPPDATA") or Path.home() / ".local" / "share") / "LifeLogPC"
MODEL_DIR = HOME / "model"
REAZON_DIR = HOME / "reazon"
WHISPER_DIR = HOME / "whisper"
CUDA_DIR = HOME / "cuda"
# GPU で Whisper を動かすための NVIDIA の部品（PyPI の Windows 用 wheel から DLL だけを取り出す）
CUDA_WHEELS = {
    "nvidia-cublas-cu12": "12.9.1.4",
    "nvidia-cudnn-cu12": "9.26.1.1",
    "nvidia-cuda-nvrtc-cu12": "12.9.86",
}
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


def find_transducer(folder: Path) -> dict[str, Path] | None:
    """folder の中の encoder/decoder/joiner/tokens。揃っていなければ None。"""

    def find(prefix: str, suffix: str) -> Path | None:
        found = sorted(p for p in folder.rglob(f"{prefix}*{suffix}") if p.is_file())
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


def model_files() -> dict[str, Path] | None:
    """Haas-ja のファイル。揃っていなければ None。"""
    return find_transducer(MODEL_DIR)


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


def download_reazon() -> dict[str, Path]:
    files = find_transducer(REAZON_DIR)
    if files:
        return files
    log(f"ReazonSpeech のモデル（約600MB）を取ってきます。初回だけです。置き場所: {REAZON_DIR}")
    from huggingface_hub import snapshot_download

    snapshot_download(repo_id=REAZON_REPO, revision=REAZON_REVISION, local_dir=str(REAZON_DIR),
                      allow_patterns=["*.onnx", "*.txt", "LICENSE*", "*.md"])
    files = find_transducer(REAZON_DIR)
    if not files:
        raise RuntimeError("ReazonSpeech のファイルが揃いませんでした（encoder/decoder/joiner/tokens）")
    return files


class Engine:
    """sherpa-onnx で Haas-ja を動かす。一度に1つずつ。"""

    name = "haas"
    label = "Haas-ja"

    def __init__(self, threads: int, provider: str) -> None:
        import sherpa_onnx

        files = download_model()
        log("Haas-ja を読み込んでいます…")
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
        log(f"Haas-ja を読み込みました（{time.time() - started:.1f} 秒、{provider}、{threads} スレッド）")

    def run(self, audio: np.ndarray, segments: list[tuple[float, float]], hints: list[str],
            prompt: str | None) -> list[str]:
        """区間ごとの文（聞き取れなければ空）。"""
        texts = []
        with self.lock:
            for start, end in segments:
                a = max(0, int(start * RATE))
                b = min(len(audio), int(end * RATE))
                if b - a < int(0.3 * RATE):
                    texts.append("")
                    continue
                stream = self.recognizer.create_stream()
                stream.accept_waveform(RATE, audio[a:b])
                self.recognizer.decode_stream(stream)
                texts.append(stream.result.text.strip())
        return texts

    def transcribe(self, audio: np.ndarray, segments: list[tuple[float, float]]) -> list[dict]:
        lines = []
        for (start, end), text in zip(segments, self.run(audio, segments, [], None)):
            if text:
                lines.append({"start": round(start, 2), "end": round(end, 2), "text": text})
        return lines


class ReazonEngine(Engine):
    """sherpa-onnx で ReazonSpeech k2 v2（Zipformer）を動かす。"""

    name = "reazon"
    label = "ReazonSpeech"

    def __init__(self, threads: int, provider: str) -> None:  # noqa: D107 — 親とは読み込むものが違う
        import sherpa_onnx

        files = download_reazon()
        log("ReazonSpeech を読み込んでいます…")
        started = time.time()
        self.recognizer = sherpa_onnx.OfflineRecognizer.from_transducer(
            encoder=str(files["encoder"]),
            decoder=str(files["decoder"]),
            joiner=str(files["joiner"]),
            tokens=str(files["tokens"]),
            num_threads=threads,
            sample_rate=RATE,
            feature_dim=80,
            decoding_method="greedy_search",
            provider=provider,
        )
        self.lock = threading.Lock()
        self.provider = provider
        log(f"ReazonSpeech を読み込みました（{time.time() - started:.1f} 秒、{provider}）")


# MARK: - Whisper（GPU があれば GPU で）


def has_nvidia_gpu() -> bool:
    import shutil

    if shutil.which("nvidia-smi"):
        return True
    return Path(os.environ.get("SystemRoot", r"C:\Windows"), "System32", "nvidia-smi.exe").exists()


def prepare_cuda() -> bool:
    """Windows で、CTranslate2 が GPU で動くのに要る cuBLAS・cuDNN の DLL を用意する。用意できたら True。"""
    if os.name != "nt":
        return True
    needed = ["cublas64_12.dll", "cudnn64_9.dll"]
    if not all((CUDA_DIR / name).exists() for name in needed):
        import urllib.request

        CUDA_DIR.mkdir(parents=True, exist_ok=True)
        log("GPU で Whisper を動かす部品（NVIDIA の cuBLAS・cuDNN、約1.3GB）を取ってきます。初回だけです。")
        for package, version in CUDA_WHEELS.items():
            with urllib.request.urlopen(f"https://pypi.org/pypi/{package}/{version}/json", timeout=60) as response:
                info = json.load(response)
            url = next((f["url"] for f in info["urls"] if f["filename"].endswith("win_amd64.whl")), None)
            if not url:
                raise RuntimeError(f"{package} {version} の Windows 用が見つかりません")
            wheel = CUDA_DIR / f"{package}.whl"
            log(f"  {package} {version} を取ってきています…")
            urllib.request.urlretrieve(url, wheel)
            with zipfile.ZipFile(wheel) as archive:
                for member in archive.namelist():
                    if member.lower().endswith(".dll") and "/bin/" in member:
                        (CUDA_DIR / Path(member).name).write_bytes(archive.read(member))
            wheel.unlink(missing_ok=True)
        if not all((CUDA_DIR / name).exists() for name in needed):
            raise RuntimeError("GPU の部品の DLL が揃いませんでした")
    os.add_dll_directory(str(CUDA_DIR))
    os.environ["PATH"] = str(CUDA_DIR) + os.pathsep + os.environ.get("PATH", "")
    return True


# Whisper が雑音や無音に作りがちな決まり文句（これだけの文は捨てる）
WHISPER_JUNK = re.compile(
    r"^(ご視聴ありがとうございました|ご清聴ありがとうございました|チャンネル登録(よろしくお願いします|をお願いします)?|"
    r"お疲れ様でした|字幕.*|ありがとうございました)[。！!]*$")


class WhisperEngine:
    """faster-whisper で Whisper を動かす。登録した言葉をヒントとして渡せる（ほかの2つにはできない）。"""

    name = "whisper"

    def __init__(self, model: str, device: str, threads: int) -> None:
        from faster_whisper import WhisperModel

        use_gpu = device == "cuda" or (device == "auto" and has_nvidia_gpu())
        if use_gpu:
            try:
                prepare_cuda()
            except Exception as error:  # noqa: BLE001 — GPU が使えなければ CPU で続ける
                log(f"GPU の部品を用意できませんでした。CPU で動かします: {error!r}")
                use_gpu = False
        if model == "auto":
            model = "large-v3" if use_gpu else "large-v3-turbo"
        log(f"Whisper（{model}）を読み込んでいます…（初回は 1.5〜3GB を取ってきます）")
        started = time.time()
        WHISPER_DIR.mkdir(parents=True, exist_ok=True)
        self.model = None
        if use_gpu:
            try:
                self.model = WhisperModel(model, device="cuda", compute_type="float16",
                                          download_root=str(WHISPER_DIR))
                self.provider = "cuda"
            except Exception as error:  # noqa: BLE001
                log(f"GPU で読み込めませんでした。CPU で動かします: {error!r}")
                if model == "large-v3":
                    model = "large-v3-turbo"
        if self.model is None:
            self.model = WhisperModel(model, device="cpu", compute_type="int8", cpu_threads=threads,
                                      download_root=str(WHISPER_DIR))
            self.provider = "cpu"
        self.label = f"Whisper {model}"
        self.lock = threading.Lock()
        log(f"Whisper を読み込みました（{time.time() - started:.1f} 秒、{self.provider}）")

    def run(self, audio: np.ndarray, segments: list[tuple[float, float]], hints: list[str],
            prompt: str | None) -> list[str]:
        # ヒント（名前・専門用語）は先頭ほど効くので、前の区切りの文より先に置く
        initial = "、".join(hints[:40])
        if prompt:
            initial = (initial + "。" if initial else "") + prompt[-120:]
        texts = []
        with self.lock:
            for start, end in segments:
                a = max(0, int(start * RATE))
                b = min(len(audio), int(end * RATE))
                if b - a < int(0.3 * RATE):
                    texts.append("")
                    continue
                pieces, _ = self.model.transcribe(
                    audio[a:b], language="ja", beam_size=5, initial_prompt=initial or None,
                    condition_on_previous_text=False, without_timestamps=True, vad_filter=False,
                    temperature=0.0)
                kept = []
                for piece in pieces:
                    text = piece.text.strip()
                    # 声が無いのに作った文（無音らしさが高く、自信が低い）と決まり文句は捨てる
                    if piece.no_speech_prob > 0.6 and piece.avg_logprob < -1.0:
                        continue
                    if WHISPER_JUNK.match(text):
                        continue
                    kept.append(text)
                texts.append("".join(kept))
        return texts


# MARK: - 多数決


_kakasi = None
_kakasi_lock = threading.Lock()


def reading(text: str) -> str:
    """文の読み（ひらがな）。漢字とかなの書き方の違いで食い違いにしないため。句読点・空白は除く。"""
    global _kakasi
    text = unicodedata.normalize("NFKC", text)
    try:
        with _kakasi_lock:
            if _kakasi is None:
                import pykakasi

                _kakasi = pykakasi.kakasi()
            parts = _kakasi.convert(text)
        text = "".join(p["hira"] for p in parts)
    except Exception:  # noqa: BLE001 — 読めなければ書いたままで比べる
        pass
    # 長音・小さい字の揺れを少しそろえる
    text = text.replace("ー", "").replace("～", "")
    return "".join(ch for ch in text.lower() if ch.isalnum())


def similarity(a: str, b: str) -> float:
    """2つの文の読みがどれだけ同じか（0〜1）。"""
    ra, rb = reading(a), reading(b)
    if not ra or not rb:
        return 0.0
    if ra == rb:
        return 1.0
    return difflib.SequenceMatcher(None, ra, rb, autojunk=False).ratio()


# 同じくらい合っているときに先に選ぶ順（日本語の話し言葉に強く、作り話をしにくいものから）
PRIORITY = ["haas", "reazon", "whisper", "cloud"]
# Whisper の書き方を使ってよい近さ（読みがほぼ同じなら、ヒントを渡した Whisper の漢字の書き方のほうが名前に強い）
SURFACE_SIMILAR = 0.85
# Whisper だけが書いた文は、ほかが何も聞き取っていなければ作り話とみなす
INVENTING = {"whisper", "cloud"}


def vote(hypotheses: dict[str, str]) -> dict | None:
    """モデルごとの文から1つを選ぶ。選んだ文・確からしさ（0〜1）・候補（ほかの違う文）を返す。何も選べなければ None。

    選ぶのは、読みがほかのモデルといちばん近い文（何も書かなかったモデルは 0 として数える）。
    確からしさは、選んだ文とほぼ同じ読みのモデルの割合（違うモデルは近さの半分を足す）。
    """
    names = sorted(hypotheses, key=lambda k: PRIORITY.index(k) if k in PRIORITY else len(PRIORITY))
    heard = [k for k in names if hypotheses[k].strip()]
    if not heard:
        return None
    if len(heard) == 1:
        only = heard[0]
        if only in INVENTING and len(names) > 1:
            return None
        return {"text": hypotheses[only].strip(), "engine": only,
                "confidence": 0.4 if len(names) > 1 else None, "alternatives": []}
    sims: dict[tuple[str, str], float] = {}
    for i, a in enumerate(heard):
        for b in heard[i + 1:]:
            sims[(a, b)] = sims[(b, a)] = similarity(hypotheses[a], hypotheses[b])
    scores = {k: sum(sims.get((k, o), 0.0) for o in names if o != k) / (len(names) - 1) for k in heard}
    best = max(heard, key=lambda k: (scores[k], -names.index(k)))
    text = hypotheses[best].strip()
    chosen = best
    if best != "whisper" and hypotheses.get("whisper", "").strip() \
            and sims.get((best, "whisper"), 0.0) >= SURFACE_SIMILAR:
        text = hypotheses["whisper"].strip()
        chosen = "whisper"
    alternatives = []
    for k in heard:
        other = hypotheses[k].strip()
        if other != text and other not in alternatives and similarity(other, text) < SURFACE_SIMILAR:
            alternatives.append(other)
    # 確からしさ：ほぼ同じ読み（0.85 以上）のモデルは1票、そうでないモデルは近さの半分だけ数える
    # （「明日の予算の話」と「あしたの洋服の話」のように、助詞や「の話」が同じなだけで高くならないように）
    agree = [1.0 if sims.get((best, o), 0.0) >= SURFACE_SIMILAR else sims.get((best, o), 0.0) * 0.5
             for o in names if o != best]
    confidence = sum(agree) / len(agree)
    return {"text": text, "engine": chosen, "confidence": round(confidence, 2), "alternatives": alternatives}


class Ensemble:
    """読み込めたモデルを全部動かし、区間ごとに多数決する。"""

    def __init__(self, engines: list) -> None:
        if not engines:
            raise RuntimeError("動かせるモデルがありません")
        self.engines = engines
        self.pool = ThreadPoolExecutor(max_workers=len(engines))
        gpu = any(getattr(e, "provider", "") == "cuda" for e in engines)
        self.provider = "cuda" if gpu else "cpu"
        self.label = "＋".join(e.label for e in engines)

    def transcribe(self, audio: np.ndarray, segments: list[tuple[float, float]], hints: list[str] | None = None,
                   prompt: str | None = None, votes: bool = False) -> list[dict]:
        jobs = {e.name: self.pool.submit(e.run, audio, segments, hints or [], prompt) for e in self.engines}
        results: dict[str, list[str]] = {}
        for name, job in jobs.items():
            try:
                results[name] = job.result()
            except Exception as error:  # noqa: BLE001 — 1つが失敗しても、残りで決める
                log(f"{name} で文字にできませんでした: {error!r}")
        if not results:
            raise RuntimeError("どのモデルでも文字にできませんでした")
        lines = []
        for i, (start, end) in enumerate(segments):
            hypotheses = {name: texts[i] if i < len(texts) else "" for name, texts in results.items()}
            picked = vote(hypotheses)
            if not picked:
                continue
            line = {"start": round(start, 2), "end": round(end, 2), "text": picked["text"]}
            if picked["confidence"] is not None:
                line["confidence"] = picked["confidence"]
            if picked["alternatives"]:
                line["alternatives"] = picked["alternatives"]
            if votes or len(results) > 1:
                line["votes"] = hypotheses
            lines.append(line)
        return lines


def load_engines(names: list[str], threads: int, provider: str, whisper: str, device: str) -> Ensemble:
    """頼まれたモデルを読み込む。読み込めなかったモデルは飛ばす（Haas-ja だけでも動く）。"""
    engines = []
    for name in names:
        try:
            if name == "haas":
                engines.append(Engine(threads, provider))
            elif name == "reazon":
                engines.append(ReazonEngine(max(1, threads // 2), provider))
            elif name == "whisper" and whisper != "off":
                engines.append(WhisperEngine(whisper, device, threads))
        except Exception as error:  # noqa: BLE001
            log(f"{name} を読み込めませんでした（このモデル抜きで続けます）: {error!r}")
    return Ensemble(engines)


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
    engine: Ensemble
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
        self.send_json(200, {"app": "LifeLogPC", "version": VERSION, "model": self.engine.label,
                             "provider": self.engine.provider,
                             "engines": [e.name for e in self.engine.engines]})

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
            # 聞き取ってほしい言葉（改行区切り）と、前の区切りの終わりの文。Whisper のヒントにする
            hints = [w.strip() for w in (query.get("hints") or [""])[0].split("\n") if w.strip()][:80]
            prompt = (query.get("prompt") or [None])[0]
            lines = self.engine.transcribe(audio, segments, hints=hints, prompt=prompt)
        except Exception as error:  # noqa: BLE001 — 何があっても受け付けは続ける
            log(f"文字にできませんでした: {error!r}")
            self.send_json(500, {"error": str(error)})
            return
        took = time.time() - started
        voiced = sum(b - a for a, b in segments)
        log(f"{self.client_address[0]} から {duration:.0f} 秒（声 {voiced:.0f} 秒）→ {len(lines)} 行、{took:.1f} 秒")
        unsure = sum(1 for line in lines if line.get("confidence", 1) < 0.5)
        log(f"  多数決: {len(self.engine.engines)} モデル、食い違いの大きい行 {unsure}")
        self.send_json(200, {"lines": lines, "seconds": round(took, 2),
                             "engines": [e.name for e in self.engine.engines]})


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


def tailscale_name() -> str | None:
    """この PC の Tailscale の名前（例: my-pc.tail1234.ts.net）。iPhone のアプリはこの名前で送る。"""
    import shutil
    import subprocess

    candidates = [shutil.which("tailscale"), r"C:\Program Files\Tailscale\tailscale.exe"]
    for exe in candidates:
        if not exe or not Path(exe).exists():
            continue
        try:
            out = subprocess.run([exe, "status", "--json"], capture_output=True, timeout=10,
                                 creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            name = (json.loads(out.stdout or b"{}").get("Self") or {}).get("DNSName", "")
        except (OSError, ValueError, subprocess.SubprocessError):
            continue
        name = name.rstrip(".")
        if name.endswith(".ts.net"):
            return name
    return None


class Server(ThreadingHTTPServer):
    # Windows では、同じ番号をほかのソフトと分け合ってしまわないよう、先に使われていたら始めない
    allow_reuse_address = False

    def server_bind(self) -> None:
        if hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        super().server_bind()


def serve(engine_factory, port: int) -> None:
    key = passphrase()
    # モデルを読み込む前に、番号が使えるか確かめる
    try:
        server = Server(("0.0.0.0", port), Handler)
    except OSError as error:
        raise RuntimeError(f"番号 {port} はほかのソフトが使っています。--port で別の番号を指定してください（{error}）") from error
    Handler.engine = engine_factory()
    Handler.key = key
    print()
    print("=" * 60)
    print(" LifeLog PC を始めました。この画面は閉じずに置いておいてください。")
    print(f" 使うモデル: {Handler.engine.label}（{'GPU' if Handler.engine.provider == 'cuda' else 'CPU'}）")
    print()
    print(" iPhone の LifeLog → 設定 → 家の PC に、次の2つを入れます。")
    name = tailscale_name()
    if name:
        print(f"   宛先: {name}:{port}")
    else:
        print("   宛先: （Tailscale の名前が見つかりません）")
        print("     Tailscale にログインしているか、Tailscale の管理画面（login.tailscale.com）の")
        print("     DNS で MagicDNS がオンになっているかを確かめて、起動し直してください。")
    print(f"   合言葉: {key}")
    print()
    print(" （iPhone のアプリは、番号の宛先 " + ", ".join(addresses()) + " には送れません。上の名前を使います）")
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


def test(path: str, engine: Ensemble, segments: str | None, hints: list[str]) -> None:
    audio = load_audio(Path(path).read_bytes())
    duration = len(audio) / RATE
    started = time.time()
    lines = engine.transcribe(audio, parse_segments(segments, duration), hints=hints, votes=True)
    took = time.time() - started
    print(f"使ったモデル: {engine.label}（{engine.provider}）")
    for line in lines:
        print(f"[{line['start']:.1f}-{line['end']:.1f}] {line['text']}"
              + (f"  （確からしさ {line['confidence']:.2f}）" if "confidence" in line else ""))
        for name, text in (line.get("votes") or {}).items():
            print(f"    {name}: {text or '（なし）'}")
    print(f"音声 {duration:.1f} 秒を {took:.1f} 秒で文字にしました（実時間の {took / max(duration, 0.01):.3f} 倍）")
    if not lines:
        sys.exit(1)


def check_vote() -> None:
    """多数決の決まりを確かめる（モデル無しで動く。CI で使う）。"""
    cases = [
        # 2つが同じなら、それを選ぶ
        ({"haas": "今日は会議です", "reazon": "今日は会議です", "whisper": "教は買いぎです"}, "今日は会議です", 0.5),
        # 読みが同じなら、ヒントを渡した Whisper の書き方を使う
        ({"haas": "さいとうさんと話した", "reazon": "斉藤さんと話した", "whisper": "齋藤さんと話した"}, "齋藤さんと話した", 0.8),
        # Whisper だけが書いた文は作り話とみなす
        ({"haas": "", "reazon": "", "whisper": "ご視聴ありがとうございました"}, None, None),
        # 1つだけ聞き取れた（Whisper 以外）は、確からしさを低くして残す
        ({"haas": "はい", "reazon": "", "whisper": ""}, "はい", None),
    ]
    failed = 0
    for hypotheses, want, minimum in cases:
        got = vote(hypotheses)
        text = got["text"] if got else None
        ok = text == want and (minimum is None or (got and got["confidence"] >= minimum))
        print(("OK " if ok else "NG ") + json.dumps({"in": hypotheses, "out": got}, ensure_ascii=False))
        failed += 0 if ok else 1
    # 3つとも食い違えば、確からしさを低くして候補を付ける（iPhone で言語モデルに見比べてもらう）
    low = vote({"haas": "明日の予算の話", "reazon": "あしたの洋服の話", "whisper": "飛鳥の羊羹の話"})
    ok = bool(low) and low["confidence"] < 0.5 and len(low["alternatives"]) == 2
    print(("OK " if ok else "NG ") + json.dumps(low, ensure_ascii=False))
    failed += 0 if ok else 1
    if failed:
        sys.exit(1)


def main() -> None:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")  # type: ignore[union-attr]
    parser = argparse.ArgumentParser(description="LifeLog PC（家の PC で3つの音声モデルを動かして多数決で文字にする）")
    parser.add_argument("--test", metavar="音声", help="音声を文字にして、モデルごとの文とかかった時間を表示する")
    parser.add_argument("--segments", help="--test で使う区間（例 0-3.5,4-9）")
    parser.add_argument("--hints", default="", help="--test で Whisper に渡す言葉（、区切り）")
    parser.add_argument("--download", action="store_true", help="モデルを取ってくるだけ")
    parser.add_argument("--check-vote", action="store_true", help="多数決の決まりを確かめる")
    parser.add_argument("--startup", action="store_true", help="Windows の起動時に自動で始める")
    parser.add_argument("--no-startup", action="store_true", help="起動時に始めるのをやめる")
    parser.add_argument("--threads", type=int, default=max(1, min(8, (os.cpu_count() or 4) // 2)))
    parser.add_argument("--port", type=int, default=PORT, help=f"待ち受ける番号（既定 {PORT}）")
    parser.add_argument("--provider", default="cpu", help="Haas-ja・ReazonSpeech を動かす場所: cpu（既定）または cuda")
    parser.add_argument("--engines", default="haas,reazon,whisper",
                        help="使うモデル（haas,reazon,whisper のうち。既定は3つとも）")
    parser.add_argument("--whisper", default="auto",
                        help="Whisper の大きさ: auto（GPU なら large-v3、無ければ large-v3-turbo）・large-v3・large-v3-turbo・small・off")
    parser.add_argument("--device", default="auto", help="Whisper を動かす場所: auto（既定）・cuda・cpu")
    args = parser.parse_args()

    if args.startup or args.no_startup:
        set_startup(args.startup)
        return
    if args.check_vote:
        check_vote()
        return
    names = [n.strip() for n in args.engines.split(",") if n.strip()]

    def factory() -> Ensemble:
        return load_engines(names, args.threads, args.provider, args.whisper, args.device)

    if args.download:
        engine = factory()
        print(f"用意できたモデル: {engine.label}（{engine.provider}）")
        if len(engine.engines) < len(names) - (1 if args.whisper == "off" else 0):
            sys.exit(1)
        return
    if args.test:
        test(args.test, factory(), args.segments, [w for w in re.split("[、,]", args.hints) if w])
        return
    try:
        serve(factory, args.port)
    except Exception as error:  # noqa: BLE001
        log(f"始められませんでした: {error!r}")
        if getattr(sys, "frozen", False):
            input("Enter を押すと閉じます")
        raise


if __name__ == "__main__":
    main()
