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

おまけの機能（版 3 から。古い iPhone のアプリは使わないので、今までどおり動く）:
- POST /transcribe?vad=union  iPhone が聞き逃した声を、音の大きさだけで PC でも探して一緒に文字にする（"extra": true の行）
- POST /speakers?segments=…   区間ごとの話し手の声の特徴（3D-Speaker の ERes2Net、初回に約40MB を取ってくる）
- POST /scene?segments=…      区間ごとの周りの音の上位 5 つ（Zipformer の音の聞き分け、初回に約110MB を取ってくる）

    LifeLogPC.exe                 普通に起動する（受け付けを始める）
    LifeLogPC.exe --test 音声     その音声を文字にして、モデルごとの文とかかった時間を表示する
    LifeLogPC.exe --check-extras 音声  おまけの機能を、その音声で試す
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

VERSION = 3
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


# 登録語（ホットワード）の効かせ方。sherpa-onnx は modified_beam_search のときだけ効く。
HOTWORD_SCORE = 1.5
HOTWORD_LIMIT = 60
USE_HOTWORDS = True


def token_chars(tokens: Path) -> set[str]:
    """tokens.txt にある1文字のトークン。sherpa-onnx は登録語を1文字ずつのトークンにするので、
    ここに無い文字を含む登録語を渡すと、その回の登録語がまるごと捨てられる。"""
    chars: set[str] = set()
    for row in tokens.read_text(encoding="utf-8").splitlines():
        # 「トークン 番号」。空白でもタブでも区切られている（ReazonSpeech はタブ）
        parts = row.rsplit(None, 1)
        token = parts[0] if len(parts) == 2 else row
        if len(token) == 1 and not token.isspace():
            chars.add(token)
    return chars


def hotword_string(hints: list[str], chars: set[str]) -> str:
    """sherpa-onnx に渡す登録語（"/" 区切り）。どの文字もモデルが知っているもの・2〜15文字のものだけ。"""
    words: list[str] = []
    for hint in hints:
        word = re.sub(r"\s+", "", unicodedata.normalize("NFKC", hint))
        if not 2 <= len(word) <= 15 or "/" in word or ":" in word or word in words:
            continue
        if all(c in chars for c in word):
            words.append(word)
        if len(words) >= HOTWORD_LIMIT:
            break
    return "/".join(words)


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
            decoding_method="modified_beam_search" if USE_HOTWORDS else "greedy_search",
            max_active_paths=4,
            hotwords_score=HOTWORD_SCORE,
            modeling_unit="cjkchar",
            model_type="nemo_transducer",
            provider=provider,
        )
        self.chars = token_chars(files["tokens"])
        self.tokens_path = files["tokens"]
        self.lock = threading.Lock()
        self.provider = provider
        log(f"Haas-ja を読み込みました（{time.time() - started:.1f} 秒、{provider}、{threads} スレッド）")

    def run(self, audio: np.ndarray, segments: list[tuple[float, float]], hints: list[str],
            prompt: str | None) -> list[str]:
        """区間ごとの文（聞き取れなければ空）。"""
        texts = []
        hotwords = hotword_string(hints, self.chars) if USE_HOTWORDS else ""
        with self.lock:
            for start, end in segments:
                a = max(0, int(start * RATE))
                b = min(len(audio), int(end * RATE))
                if b - a < int(0.3 * RATE):
                    texts.append("")
                    continue
                stream = self.recognizer.create_stream(hotwords=hotwords) if hotwords else self.recognizer.create_stream()
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
            decoding_method="modified_beam_search" if USE_HOTWORDS else "greedy_search",
            max_active_paths=4,
            hotwords_score=HOTWORD_SCORE,
            modeling_unit="cjkchar",
            provider=provider,
        )
        self.chars = token_chars(files["tokens"])
        self.tokens_path = files["tokens"]
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


KOTOBA_REPO = "kotoba-tech/kotoba-whisper-v2.0-faster"


class WhisperEngine:
    """faster-whisper で Whisper を動かす。登録した言葉をヒントとして渡せる（ほかの2つにはできない）。"""

    name = "whisper"

    def __init__(self, model: str, device: str, threads: int) -> None:
        from faster_whisper import WhisperModel

        use_gpu = device == "cuda" or (device == "auto" and has_nvidia_gpu())
        if self.name == "kotoba" and not use_gpu:
            # 日本語で学び直した Whisper は4票目。CPU では遅すぎるので GPU のときだけ使う
            raise RuntimeError("GPU が無いので使いません")
        if use_gpu:
            try:
                prepare_cuda()
            except Exception as error:  # noqa: BLE001 — GPU が使えなければ CPU で続ける
                log(f"GPU の部品を用意できませんでした。CPU で動かします: {error!r}")
                use_gpu = False
        if self.name == "kotoba":
            model = KOTOBA_REPO
        elif model == "auto":
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
        self.label = "kotoba-whisper" if self.name == "kotoba" else f"Whisper {model}"
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


class KotobaEngine(WhisperEngine):
    """日本語の話し言葉で学び直した Whisper（kotoba-whisper v2.0、MIT）。GPU があるときの4票目。"""

    name = "kotoba"


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


def _units(text: str) -> list[tuple[str, str]]:
    """文を「書き方・読み」の小さなまとまりに分ける。漢字の語は1つ、かなは1文字ずつ。読みの無い記号は前に付ける。"""
    global _kakasi
    text = unicodedata.normalize("NFKC", text)
    try:
        with _kakasi_lock:
            if _kakasi is None:
                import pykakasi

                _kakasi = pykakasi.kakasi()
            parts = [(p["orig"], p["hira"]) for p in _kakasi.convert(text)]
    except Exception:  # noqa: BLE001
        parts = [(ch, ch) for ch in text]
    units: list[tuple[str, str]] = []
    for orig, hira in parts:
        kana = all("\u3040" <= ch <= "\u30ff" for ch in orig)
        pieces = list(zip(orig, hira)) if kana and len(orig) == len(hira) else [(orig, hira)]
        for o, h in pieces:
            r = "".join(ch for ch in h.replace("ー", "").replace("～", "").lower() if ch.isalnum())
            if not r and units:
                units[-1] = (units[-1][0] + o, units[-1][1])
            else:
                units.append((o, r))
    return units


def _bounds(units: list[tuple[str, str]]) -> list[int]:
    """読みの文字位置で、まとまりの切れ目（0 と末尾を含む）"""
    edges = [0]
    for _, r in units:
        edges.append(edges[-1] + len(r))
    return edges


def _surface(units: list[tuple[str, str]], edges: list[int], j1: int, j2: int) -> str | None:
    """読みの j1〜j2 にちょうど重なるまとまりの書き方（切れ目が合わなければ None）"""
    if j1 not in edges or j2 not in edges:
        return None
    a, b = edges.index(j1), edges.index(j2)
    # 読みの無いまとまりで同じ位置が続くときは、いちばん外側を取る
    while b + 1 < len(edges) and edges[b + 1] == j2 and b < len(units) and not units[b][1]:
        b += 1
    return "".join(o for o, _ in units[a:b])


def rover(text: str, others: dict[str, str]) -> str:
    """選んだ文のうち、ほかの2つ以上のモデルが同じ読みで違うと言った所だけを、そちらに置き換える（言葉ごとの多数決）。

    置き換えるのは、選んだ文のまとまりの切れ目にちょうど重なる所だけ。書き方は Whisper があれば Whisper のものを使う。
    """
    heard = {k: v.strip() for k, v in others.items() if v.strip()}
    if len(heard) < 2:
        return text
    pu = _units(text)
    pr = "".join(r for _, r in pu)
    pe = _bounds(pu)
    if not pr:
        return text
    found: dict[tuple[int, int, str], list[tuple[str, str | None]]] = {}
    for name, other in heard.items():
        ou = _units(other)
        orr = "".join(r for _, r in ou)
        oe = _bounds(ou)
        matcher = difflib.SequenceMatcher(None, pr, orr, autojunk=False)
        for tag, i1, i2, j1, j2 in matcher.get_opcodes():
            if tag == "equal":
                continue
            # 違う所を、選んだ文のまとまりの切れ目まで広げる（前後は同じ読みなので、ほかの文も同じだけ広げる）
            left = max(e for e in pe if e <= i1)
            right = min(e for e in pe if e >= i2)
            if left == right:
                # 足すだけの所は、前（無ければ後ろ）のまとまりごと置き換える形にする
                if left > 0:
                    left = max(e for e in pe if e < left)
                elif any(e > right for e in pe):
                    right = min(e for e in pe if e > right)
            j1 -= i1 - left
            j2 += right - i2
            i1, i2 = left, right
            j1, j2 = max(0, j1), min(len(orr), j2)
            found.setdefault((i1, i2, orr[j1:j2]), []).append((name, _surface(ou, oe, j1, j2)))
    changes = []
    for (i1, i2, rep), voters in found.items():
        if len(voters) < 2 or i1 not in pe or i2 not in pe:
            continue
        surfaces = [s for n, s in sorted(voters, key=lambda v: v[0] != "whisper") if s is not None]
        if not surfaces:
            continue
        changes.append((i1, i2, surfaces[0]))
    if not changes:
        return text
    # 重なるものは、先に見つけたものだけ。後ろから置き換える
    changes.sort()
    kept = []
    for c in changes:
        if not kept or c[0] >= kept[-1][1]:
            kept.append(c)
    out = text_units = [o for o, _ in pu]
    for i1, i2, surface in reversed(kept):
        a, b = pe.index(i1), pe.index(i2)
        if i1 == i2:
            out = text_units[:a] + [surface] + text_units[a:]
        else:
            out = text_units[:a] + [surface] + text_units[b:]
        text_units = out
    return "".join(out)


# 同じくらい合っているときに先に選ぶ順（日本語の話し言葉に強く、作り話をしにくいものから）
PRIORITY = ["haas", "reazon", "whisper", "kotoba", "cloud"]
# Whisper の書き方を使ってよい近さ（読みがほぼ同じなら、ヒントを渡した Whisper の漢字の書き方のほうが名前に強い）
SURFACE_SIMILAR = 0.85
# Whisper だけが書いた文は、ほかが何も聞き取っていなければ作り話とみなす
INVENTING = {"whisper", "kotoba", "cloud"}


def parse_weights(text: str | None) -> dict[str, float]:
    """"haas:1.1,reazon:0.8" の形（答え合わせから iPhone が学んだ、モデルごとの当たりやすさ）。0.5〜2.0 に収める。"""
    weights: dict[str, float] = {}
    for part in (text or "").split(","):
        name, _, value = part.partition(":")
        try:
            weights[name.strip()] = min(2.0, max(0.5, float(value)))
        except ValueError:
            continue
    return weights


def vote(hypotheses: dict[str, str], weights: dict[str, float] | None = None) -> dict | None:
    """モデルごとの文から1つを選ぶ。選んだ文・確からしさ（0〜1）・候補（ほかの違う文）を返す。何も選べなければ None。

    選ぶのは、読みがほかのモデルといちばん近い文（何も書かなかったモデルは 0 として数える）。
    確からしさは、選んだ文とほぼ同じ読みのモデルの割合（違うモデルは近さの半分を足す）。
    """
    names = sorted(hypotheses, key=lambda k: PRIORITY.index(k) if k in PRIORITY else len(PRIORITY))
    heard = [k for k in names if hypotheses[k].strip()]
    if not heard:
        return None
    # Whisper の仲間（Whisper・kotoba・クラウド）だけが書き、ほかのモデルが何も聞いていなければ作り話とみなす
    if all(k in INVENTING for k in heard) and any(k not in INVENTING for k in names):
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
    # 答え合わせでよく当たるモデルの票は重く数える（重みが無ければ、どれも 1）
    w = {k: (weights or {}).get(k, 1.0) for k in names}
    scores = {k: (w[k] * 0.01 + sum(w[o] * sims.get((k, o), 0.0) for o in names if o != k))
              / sum(w[o] for o in names if o != k) for k in heard}
    best = max(heard, key=lambda k: (scores[k], -names.index(k)))
    text = hypotheses[best].strip()
    chosen = best
    if best != "whisper" and hypotheses.get("whisper", "").strip() \
            and sims.get((best, "whisper"), 0.0) >= SURFACE_SIMILAR:
        text = hypotheses["whisper"].strip()
        chosen = "whisper"
    # 言葉ごとの多数決：選んだ文の一部だけが違っていて、ほかの2つが同じことを言っていれば、そこを直す
    merged = rover(text, {k: hypotheses[k] for k in heard if k != chosen})
    if merged != text:
        text = merged
        chosen = chosen + "+rover"
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
                   prompt: str | None = None, votes: bool = False,
                   weights: dict[str, float] | None = None, extra_from: int | None = None) -> list[dict]:
        """extra_from を渡すと、その番号から後ろの区間（PC が見つけた、iPhone が聞き逃した声）の行に "extra": true を付け、
        全部の行を時間の順に並べ直す。"""
        if CLEAN_AUDIO:
            audio = clean_audio(audio, segments)
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
            picked = vote(hypotheses, weights)
            if not picked:
                continue
            line = {"start": round(start, 2), "end": round(end, 2), "text": picked["text"]}
            if picked["confidence"] is not None:
                line["confidence"] = picked["confidence"]
            if picked["alternatives"]:
                line["alternatives"] = picked["alternatives"]
            if votes or len(results) > 1:
                line["votes"] = hypotheses
            if extra_from is not None and i >= extra_from:
                line["extra"] = True
            lines.append(line)
        if extra_from is not None:
            lines.sort(key=lambda line: (line["start"], line["end"]))
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
            elif name == "kotoba" and whisper != "off":
                engines.append(KotobaEngine(whisper, device, threads))
        except Exception as error:  # noqa: BLE001
            log(f"{name} を読み込めませんでした（このモデル抜きで続けます）: {error!r}")
    return Ensemble(engines)


# MARK: - 音声


# 聞く前に音をそろえる（低いうなり・服のこすれを削り、小さい声を持ち上げる）
CLEAN_AUDIO = True
TARGET_RMS = 0.05  # おおよそ -26 dBFS
MAX_GAIN = 8.0     # 持ち上げすぎて雑音まで大きくしない（+18 dB まで）


def clean_audio(audio: np.ndarray, segments: list[tuple[float, float]]) -> np.ndarray:
    """80Hz より下を削り、声の区間ごとに音量をそろえる。大きすぎる声は下げない。"""
    if len(audio) == 0:
        return audio
    # 12.5ms の移動平均（80Hz より下の、ゆっくりした揺れ）を引く。numpy だけで速く動く
    width = RATE // 80
    if len(audio) > width:
        kernel = np.ones(width, dtype=np.float32) / width
        out = (audio - np.convolve(audio, kernel, mode="same")).astype(np.float32)
    else:
        out = audio.copy()
    for start, end in segments:
        a = max(0, int(start * RATE))
        b = min(len(out), int(end * RATE))
        if b - a < int(0.3 * RATE):
            continue
        piece = out[a:b]
        rms = float(np.sqrt(np.mean(piece * piece))) if len(piece) else 0.0
        if rms <= 1e-5 or rms >= TARGET_RMS:
            continue
        peak = float(np.max(np.abs(piece)))
        gain = min(TARGET_RMS / rms, MAX_GAIN, 0.95 / peak if peak > 0 else MAX_GAIN)
        if gain > 1.05:
            out[a:b] = piece * np.float32(gain)
    return out


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


def parse_ranges(text: str | None, duration: float) -> list[tuple[float, float]]:
    """"0.0-3.2,5.1-9.0" の形。parse_segments と違い、長い区間も分けない（送られた区間と1つずつ対応させる）。
    読めない区間は (0, 0) にして、答えを null にする。無ければ全体を1つの区間にする。"""
    if not text:
        return [(0.0, duration)]
    result = []
    for part in text.split(","):
        try:
            a, b = part.split("-")
            start, end = max(0.0, float(a)), min(duration, float(b))
        except ValueError:
            start, end = 0.0, 0.0
        result.append((start, max(start, end)))
    return result


# MARK: - iPhone が聞き逃した声を探す（vad=union）


EXTRA_FRAME = 0.03       # 30ms ずつ音の大きさを測る
EXTRA_NOISE_PCT = 20     # 小さいほうから 20% の大きさを「周りの音の大きさ」とみなす
EXTRA_MARGIN_DB = 10.0   # それより 10dB 大きければ声かもしれない
EXTRA_MIN_DB = -60.0     # 無音の録音でも、これより小さい音は声とみなさない
EXTRA_MIN = 0.4          # 0.4 秒より短いものは捨てる
EXTRA_GAP = 0.3          # 0.3 秒より短い切れ目はつなぐ
EXTRA_OVERLAP = 0.5      # iPhone の区間と半分より多く重なるものは、もう聞いているので捨てる
EXTRA_PAD = 0.1          # 言い始め・言い終わりが切れないよう、前後を少し広げる


def extra_speech(audio: np.ndarray, segments: list[tuple[float, float]]) -> list[tuple[float, float]]:
    """iPhone の区間の外にある、声らしい大きな音の区間（モデルは使わない、音の大きさだけで決める）。

    30ms ごとの大きさ（dB）を測り、周りの音（小さいほうから 20%）より 10dB 大きい所を拾う。
    0.3 秒より短い切れ目はつなぎ、0.4 秒より短いものは捨てる。iPhone の区間と半分より多く重なるものも捨てる。
    少しだけ重なるものは、重なった所を除いた残りを返す（同じ所を2回文字にしないため）。
    """
    frame = int(EXTRA_FRAME * RATE)
    count = len(audio) // frame
    if count < 2:
        return []
    duration = len(audio) / RATE
    frames = np.asarray(audio[:count * frame], dtype=np.float64).reshape(count, frame)
    db = 20.0 * np.log10(np.sqrt(np.mean(frames * frames, axis=1)) + 1e-10)
    threshold = max(float(np.percentile(db, EXTRA_NOISE_PCT)) + EXTRA_MARGIN_DB, EXTRA_MIN_DB)
    loud = (db > threshold).astype(np.int8)
    edges = np.flatnonzero(np.diff(np.concatenate([[0], loud, [0]])))
    merged: list[list[float]] = []
    for a, b in zip(edges[0::2], edges[1::2]):
        start, end = a * EXTRA_FRAME, b * EXTRA_FRAME
        if merged and start - merged[-1][1] < EXTRA_GAP:
            merged[-1][1] = end
        else:
            merged.append([start, end])
    given = sorted((a, b) for a, b in segments if b > a)
    found: list[tuple[float, float]] = []
    for start, end in merged:
        if end - start < EXTRA_MIN:
            continue
        start, end = max(0.0, start - EXTRA_PAD), min(duration, end + EXTRA_PAD)
        covered = sum(max(0.0, min(end, b) - max(start, a)) for a, b in given)
        if covered > EXTRA_OVERLAP * (end - start):
            continue
        # 重なった所を除いた残り
        pieces = [(start, end)]
        for a, b in given:
            rest = []
            for s, e in pieces:
                if b <= s or a >= e:
                    rest.append((s, e))
                    continue
                if a > s:
                    rest.append((s, a))
                if b < e:
                    rest.append((b, e))
            pieces = rest
        for s, e in pieces:
            if e - s < EXTRA_MIN:
                continue
            # 長すぎるものは分ける（文字にするときと同じ上限）
            s, e = float(s), float(e)
            while e - s > MAX_SEGMENT:
                found.append((round(s, 2), round(s + MAX_SEGMENT, 2)))
                s += MAX_SEGMENT
            found.append((round(s, 2), round(e, 2)))
    return found


# MARK: - 話し手の声の特徴（/speakers）・周りの音（/scene）
# どちらも初回に頼まれたときにモデルを取ってきて、1回だけ読み込む。失敗しても文字にする処理には響かない。


RELEASES = "https://github.com/k2-fsa/sherpa-onnx/releases/download"
# 3D-Speaker の ERes2Net（iPhone の WeSpeaker 型とは違う作りのモデル、Apache-2.0）。
# 置き場所の名前 "speaker-recongition-models" の綴りの誤りは、元のまま（直すと取ってこられない）
SPEAKER_MODEL = os.environ.get("LIFELOG_SPEAKER_MODEL", "3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx")
SPEAKER_URL = f"{RELEASES}/speaker-recongition-models/{SPEAKER_MODEL}"
SPEAKER_DIR = HOME / "speaker"
SPEAKER_MIN = 0.5  # これより短い区間は声の特徴を出さない（null）
# AudioSet の 527 種類の音を聞き分ける Zipformer（small、Apache-2.0）
TAGGING_NAME = "sherpa-onnx-zipformer-small-audio-tagging-2024-04-15"
TAGGING_URL = f"{RELEASES}/audio-tagging-models/{TAGGING_NAME}.tar.bz2"
TAGGING_DIR = HOME / "tagging"
TAGGING_TOP = 5
TAGGING_MIN = 0.3   # これより短い区間は空にする
TAGGING_MAX = 30.0  # 長い区間は真ん中の 30 秒だけを聞く（時間がかかりすぎないように）


def fetch(url: str, path: Path) -> None:
    """url を path に保存する。途中で止まっても壊れたファイルが残らないよう、別の名前で受けてから置き換える。"""
    import urllib.request

    path.parent.mkdir(parents=True, exist_ok=True)
    part = path.with_name(path.name + ".part")
    with urllib.request.urlopen(url, timeout=120) as response, part.open("wb") as f:
        while True:
            chunk = response.read(1 << 20)
            if not chunk:
                break
            f.write(chunk)
    part.replace(path)


def download_speaker() -> Path:
    path = SPEAKER_DIR / SPEAKER_MODEL
    if path.exists() and path.stat().st_size > 1_000_000:
        return path
    log(f"話し手の声の特徴を出すモデル（{SPEAKER_MODEL}、約40MB）を取ってきます。初回だけです。置き場所: {SPEAKER_DIR}")
    fetch(SPEAKER_URL, path)
    return path


def tagging_files() -> dict[str, Path] | None:
    """周りの音を聞き分けるモデルと、音の名前の一覧。揃っていなければ None。"""
    models = sorted(TAGGING_DIR.rglob("*.onnx"))
    labels = sorted(TAGGING_DIR.rglob("class_labels_indices.csv"))
    if not models or not labels:
        return None
    # 軽い int8 の版があればそれを使う（説明書の例も int8）
    small = [p for p in models if "int8" in p.name]
    return {"model": (small or models)[0], "labels": labels[0]}


def download_tagging() -> dict[str, Path]:
    files = tagging_files()
    if files:
        return files
    import bz2  # noqa: F401 — exe にしたとき tar.bz2 を開く部品が入るように
    import tarfile

    log(f"周りの音を聞き分けるモデル（{TAGGING_NAME}、約110MB）を取ってきます。初回だけです。置き場所: {TAGGING_DIR}")
    archive = TAGGING_DIR / f"{TAGGING_NAME}.tar.bz2"
    fetch(TAGGING_URL, archive)
    with tarfile.open(archive, "r:bz2") as tar:
        try:
            tar.extractall(TAGGING_DIR, filter="data")
        except TypeError:  # 古い Python には filter が無い
            members = [m for m in tar.getmembers()
                       if not (m.name.startswith(("/", "\\")) or ".." in Path(m.name).parts)]
            tar.extractall(TAGGING_DIR, members=members)
    archive.unlink(missing_ok=True)
    files = tagging_files()
    if not files:
        raise RuntimeError("周りの音のモデルのファイルが揃いませんでした（*.onnx・class_labels_indices.csv）")
    return files


def clip(audio: np.ndarray, start: float, end: float) -> np.ndarray:
    a = max(0, int(start * RATE))
    b = min(len(audio), int(end * RATE))
    return np.ascontiguousarray(audio[a:b], dtype=np.float32) if b > a else np.zeros(0, dtype=np.float32)


class SpeakerModel:
    """区間ごとの話し手の声の特徴（長さ 1 にそろえた数の並び）。同じ人なら向きが近くなる。"""

    def __init__(self, threads: int) -> None:
        import sherpa_onnx

        path = download_speaker()
        config = sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(path), num_threads=threads, provider="cpu")
        if not config.validate():
            raise RuntimeError(f"話し手のモデルの設定が正しくありません: {config}")
        self.extractor = sherpa_onnx.SpeakerEmbeddingExtractor(config)
        self.dim = int(self.extractor.dim)
        self.name = path.stem
        self.lock = threading.Lock()
        log(f"話し手のモデルを読み込みました（{self.name}、{self.dim} 次元）")

    def embed(self, audio: np.ndarray, ranges: list[tuple[float, float]]) -> list[list[float] | None]:
        out: list[list[float] | None] = []
        with self.lock:
            for start, end in ranges:
                samples = clip(audio, start, end)
                if len(samples) < int(SPEAKER_MIN * RATE):
                    out.append(None)
                    continue
                stream = self.extractor.create_stream()
                stream.accept_waveform(RATE, samples)
                stream.input_finished()
                if not self.extractor.is_ready(stream):
                    out.append(None)
                    continue
                vector = np.asarray(self.extractor.compute(stream), dtype=np.float64)
                norm = float(np.linalg.norm(vector))
                if not np.isfinite(norm) or norm <= 0:
                    out.append(None)
                    continue
                out.append([round(float(x), 6) for x in vector / norm])
        return out


class SceneModel:
    """区間ごとの周りの音（話し声・音楽・車・雨など）の上位 5 つと、その確からしさ。"""

    def __init__(self, threads: int) -> None:
        import sherpa_onnx

        files = download_tagging()
        config = sherpa_onnx.AudioTaggingConfig(
            model=sherpa_onnx.AudioTaggingModelConfig(
                zipformer=sherpa_onnx.OfflineZipformerAudioTaggingModelConfig(model=str(files["model"])),
                num_threads=threads,
                provider="cpu",
            ),
            labels=str(files["labels"]),
            top_k=TAGGING_TOP,
        )
        if not config.validate():
            raise RuntimeError(f"周りの音のモデルの設定が正しくありません: {config}")
        self.tagger = sherpa_onnx.AudioTagging(config)
        self.name = TAGGING_NAME
        self.lock = threading.Lock()
        log(f"周りの音のモデルを読み込みました（{self.name}、{files['model'].name}）")

    def tag(self, audio: np.ndarray, ranges: list[tuple[float, float]]) -> list[list[dict]]:
        out: list[list[dict]] = []
        with self.lock:
            for start, end in ranges:
                if end - start > TAGGING_MAX:
                    middle = (start + end) / 2
                    start, end = middle - TAGGING_MAX / 2, middle + TAGGING_MAX / 2
                samples = clip(audio, start, end)
                if len(samples) < int(TAGGING_MIN * RATE):
                    out.append([])
                    continue
                stream = self.tagger.create_stream()
                stream.accept_waveform(RATE, samples)
                events = self.tagger.compute(stream, TAGGING_TOP)
                out.append([{"name": e.name, "prob": round(min(1.0, max(0.0, float(e.prob))), 4)}
                            for e in list(events)[:TAGGING_TOP]])
        return out


_extras: dict[str, object] = {}
_extras_lock = threading.Lock()


def extra_model(kind: str, threads: int):
    """"speaker" か "scene" のモデル。初回だけ取ってきて読み込む（失敗したら次に頼まれたときにやり直す）。"""
    with _extras_lock:
        if kind not in _extras:
            _extras[kind] = SpeakerModel(threads) if kind == "speaker" else SceneModel(threads)
        return _extras[kind]


def features() -> list[str]:
    """この PC が受け付けるおまけの機能。モデルは初回に頼まれたときに取ってくる。"""
    found = []
    try:
        import sherpa_onnx
    except Exception:  # noqa: BLE001
        sherpa_onnx = None
    if sherpa_onnx is not None:
        if all(hasattr(sherpa_onnx, n) for n in ("SpeakerEmbeddingExtractor", "SpeakerEmbeddingExtractorConfig")):
            found.append("speakers")
        if all(hasattr(sherpa_onnx, n) for n in ("AudioTagging", "AudioTaggingConfig", "AudioTaggingModelConfig",
                                                  "OfflineZipformerAudioTaggingModelConfig")):
            found.append("scene")
    found.append("vad")
    return found


# MARK: - 受け付け


class Handler(BaseHTTPRequestHandler):
    engine: Ensemble
    key: str
    extra_threads = 2  # /speakers・/scene のモデルに使うスレッドの数
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
                             "engines": [e.name for e in self.engine.engines],
                             "features": features()})

    def do_POST(self) -> None:
        url = urlparse(self.path)
        if url.path not in ("/transcribe", "/speakers", "/scene"):
            self.send_json(404, {"error": "not found"})
            return
        if not self.authorized():
            return
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > 200_000_000:
            self.send_json(400, {"error": "音声がありません"})
            return
        data = self.rfile.read(length)
        if url.path == "/transcribe":
            self.transcribe(data, url.query)
        else:
            self.extras(url.path, data, url.query)

    def extras(self, path: str, data: bytes, query_text: str) -> None:
        """/speakers（区間ごとの話し手の声の特徴）と /scene（区間ごとの周りの音）。失敗しても受け付けは続ける。"""
        what = "話し手の声の特徴を出せませんでした" if path == "/speakers" else "周りの音を聞き分けられませんでした"
        started = time.time()
        try:
            audio = load_audio(data)
            duration = len(audio) / RATE
            query = parse_qs(query_text)
            ranges = parse_ranges((query.get("segments") or [None])[0], duration)
            if path == "/speakers":
                model = extra_model("speaker", self.extra_threads)
                body: dict = {"embeddings": model.embed(audio, ranges), "model": model.name, "dim": model.dim}
            else:
                model = extra_model("scene", self.extra_threads)
                body = {"tags": model.tag(audio, ranges), "model": model.name}
        except Exception as error:  # noqa: BLE001 — 何があっても受け付けは続ける
            log(f"{what}: {error!r}")
            self.send_json(500, {"error": f"{what}: {error}"})
            return
        took = time.time() - started
        body["seconds"] = round(took, 2)
        log(f"{self.client_address[0]} から {path}: {duration:.0f} 秒・{len(ranges)} 区間、{took:.1f} 秒")
        self.send_json(200, body)

    def transcribe(self, data: bytes, query_text: str) -> None:
        started = time.time()
        extra: list[tuple[float, float]] = []
        try:
            audio = load_audio(data)
            duration = len(audio) / RATE
            query = parse_qs(query_text)
            segments = parse_segments((query.get("segments") or [None])[0], duration)
            # 聞き取ってほしい言葉（改行区切り）と、前の区切りの終わりの文。Whisper のヒントにする
            hints = [w.strip() for w in (query.get("hints") or [""])[0].split("\n") if w.strip()][:80]
            prompt = (query.get("prompt") or [None])[0]
            weights = parse_weights((query.get("weights") or [None])[0])
            # vad=union: iPhone が聞き逃した声も PC で探して、一緒に文字にする
            if (query.get("vad") or [""])[0] == "union":
                try:
                    extra = extra_speech(audio, segments)
                except Exception as error:  # noqa: BLE001 — 探せなくても、iPhone の区間だけで続ける
                    log(f"聞き逃した声を探せませんでした（iPhone の区間だけで続けます）: {error!r}")
                    extra = []
            if extra:
                lines = self.engine.transcribe(audio, segments + extra, hints=hints, prompt=prompt, weights=weights,
                                               extra_from=len(segments))
            else:
                lines = self.engine.transcribe(audio, segments, hints=hints, prompt=prompt, weights=weights)
        except Exception as error:  # noqa: BLE001 — 何があっても受け付けは続ける
            log(f"文字にできませんでした: {error!r}")
            self.send_json(500, {"error": str(error)})
            return
        took = time.time() - started
        voiced = sum(b - a for a, b in segments)
        log(f"{self.client_address[0]} から {duration:.0f} 秒（声 {voiced:.0f} 秒）→ {len(lines)} 行、{took:.1f} 秒")
        if extra:
            found = sum(1 for line in lines if line.get("extra"))
            log(f"  iPhone が聞き逃した声: {len(extra)} 区間（{sum(b - a for a, b in extra):.0f} 秒）→ {found} 行")
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


def serve(engine_factory, port: int, threads: int = 4) -> None:
    key = passphrase()
    Handler.extra_threads = max(1, threads // 2)
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
    for e in engine.engines:
        if hasattr(e, "chars"):
            print(f"    {e.label} の登録語: {hotword_string(hints, e.chars) or '（なし）'}"
                  f"（知っている1文字のトークン {len(e.chars)} 個）")
            if not e.chars and getattr(e, "tokens_path", None):
                # 1文字のトークンが無いモデル（BPE など）の、トークンの形と同じフォルダのファイルを見る
                rows = e.tokens_path.read_text(encoding="utf-8").splitlines()
                print(f"      トークンの例: {rows[:3] + rows[200:205]}（全 {len(rows)} 個）")
                print(f"      同じフォルダ: {sorted(p.name for p in e.tokens_path.parent.iterdir())[:20]}")
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
        # 言葉ごとの多数決：3つとも少しずつ違えば、所ごとに2つが合っているほうを取る
        ({"haas": "明日の洋服の件で田中さんと話す", "reazon": "明日の予算の件で中田さんと話す",
          "whisper": "明日の予算の件で田中さんと話した"}, "明日の予算の件で田中さんと話す", None),
        # 選んだ文の書き足し・書き落としも、ほかの2つがそろっていれば直す
        ({"haas": "来週の会議の資料", "reazon": "来週の会議の資料ね", "whisper": "来週の会議の資料ね"}, "来週の会議の資料ね", 0.8),
        # Whisper の仲間だけが書いた文も同じ
        ({"haas": "", "reazon": "", "whisper": "ご視聴ありがとうございました", "kotoba": "ご視聴ありがとうございました"},
         None, None),
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
    # 重み：近さが同じなら、答え合わせで当たりやすいと分かったモデルの文を先に選ぶ
    tie = {"haas": "今日は晴れ", "reazon": "今日は雨", "whisper": "今日は雪"}
    weighted = vote(tie, {"reazon": 2.0})
    plain = vote(tie)
    ok = bool(weighted) and bool(plain) and weighted["engine"] == "reazon" and plain["engine"] == "haas" \
        and parse_weights("haas:9,reazon:x,whisper:0.7") == {"haas": 2.0, "whisper": 0.7}
    print(("OK " if ok else "NG ") + json.dumps({"weighted": weighted, "plain": plain}, ensure_ascii=False))
    failed += 0 if ok else 1
    # 3つとも食い違えば、確からしさを低くして候補を付ける（iPhone で言語モデルに見比べてもらう）
    low = vote({"haas": "明日の予算の話", "reazon": "あしたの洋服の話", "whisper": "飛鳥の羊羹の話"})
    ok = bool(low) and low["confidence"] < 0.5 and len(low["alternatives"]) == 2
    print(("OK " if ok else "NG ") + json.dumps(low, ensure_ascii=False))
    failed += 0 if ok else 1
    # 聞き逃した声の探し方（vad=union）もモデル無しで確かめられる
    failed += check_extra_speech()
    if failed:
        sys.exit(1)


def check_extra_speech() -> int:
    """聞き逃した声の探し方を、作った音で確かめる（モデル無し）。NG の数を返す。"""
    rng = np.random.default_rng(0)
    audio = (rng.standard_normal(10 * RATE) * 0.003).astype(np.float32)  # 周りの音（約 -50dBFS）
    t = np.arange(10 * RATE) / RATE
    tone = (0.2 * np.sin(2 * np.pi * 220 * t)).astype(np.float32)
    for a, b in [(2.0, 3.0), (5.0, 5.15), (6.0, 6.5), (6.7, 7.2), (8.0, 9.0)]:
        audio[int(a * RATE):int(b * RATE)] += tone[int(a * RATE):int(b * RATE)]

    def near(got: list[tuple[float, float]], want: list[tuple[float, float]]) -> bool:
        return len(got) == len(want) and all(abs(g[0] - w[0]) <= 0.15 and abs(g[1] - w[1]) <= 0.15
                                             for g, w in zip(got, want))

    cases = [
        # 短すぎる音（0.15 秒）は捨て、0.2 秒の切れ目はつなぎ、iPhone の区間と同じ所は捨てる
        ([(8.0, 9.0)], [(2.0, 3.0), (6.0, 7.2)]),
        # 半分より多く重なるものは捨てる
        ([(1.9, 2.8), (8.0, 9.0)], [(6.0, 7.2)]),
        # 少しだけ重なるものは、重なっていない所だけを返す
        ([(6.7, 7.4), (8.0, 9.0)], [(2.0, 3.0), (5.9, 6.7)]),
        # iPhone の区間が無ければ、声らしい所を全部返す
        ([], [(2.0, 3.0), (6.0, 7.2), (8.0, 9.0)]),
    ]
    failed = 0
    for given, want in cases:
        got = extra_speech(audio, given)
        ok = near(got, want)
        print(("OK " if ok else "NG ") + f"聞き逃した声: 区間 {given} → {got}（ほぼ {want} のはず）")
        failed += 0 if ok else 1
    # 無音だけ・短すぎる音声でも落ちない
    ok = extra_speech(np.zeros(5 * RATE, dtype=np.float32), []) == [] and extra_speech(np.zeros(10, np.float32), []) == []
    print(("OK " if ok else "NG ") + "無音・短い音声では何も返さない")
    return failed + (0 if ok else 1)


def check_extras(path: str, threads: int) -> None:
    """聞き逃した声の探し方・/speakers・/scene を、その音声で試す（モデルを取ってくる。CI で使う）。"""
    failed = check_extra_speech()
    audio = load_audio(Path(path).read_bytes())
    duration = len(audio) / RATE
    found = extra_speech(audio, [])
    print(f"音声 {duration:.1f} 秒。iPhone の区間が無いとき、声らしい所: {found}")
    if found:
        print(f"  最初の区間を iPhone の区間にすると: {extra_speech(audio, found[:1])}")
    # 区間ごとに1つずつ答えが返るか。短すぎる区間（0.2 秒）は null になるはず
    ranges = parse_ranges(",".join(f"{a}-{b}" for a, b in found[:3]) + f",0-0.2,0-{duration:.2f}" if found
                          else f"0-0.2,0-{duration:.2f}", duration)
    started = time.time()
    speaker = extra_model("speaker", threads)
    embeddings = speaker.embed(audio, ranges)
    print(f"話し手のモデル: {speaker.name}（{speaker.dim} 次元、{time.time() - started:.1f} 秒）")
    for (a, b), e in zip(ranges, embeddings):
        print(f"  [{a:.1f}-{b:.1f}] " + ("null" if e is None else f"{len(e)} 次元、長さ {np.linalg.norm(e):.3f}"))
    vectors = [np.array(e) for e in embeddings if e is not None]
    if len(vectors) >= 2:
        print(f"  最初の2つの近さ（cos）: {float(vectors[0] @ vectors[1]):.3f}")
    ok = len(embeddings) == len(ranges) and embeddings[-2] is None and embeddings[-1] is not None \
        and len(embeddings[-1]) == speaker.dim and abs(np.linalg.norm(embeddings[-1]) - 1) < 1e-3
    print(("OK " if ok else "NG ") + "区間ごとに声の特徴が出る（短い区間は null、長さは 1）")
    failed += 0 if ok else 1
    started = time.time()
    scene = extra_model("scene", threads)
    tags = scene.tag(audio, ranges)
    print(f"周りの音のモデル: {scene.name}（{time.time() - started:.1f} 秒）")
    for (a, b), t in zip(ranges, tags):
        print(f"  [{a:.1f}-{b:.1f}] " + ("、".join(f"{x['name']} {x['prob']:.2f}" for x in t) or "（なし）"))
    ok = len(tags) == len(ranges) and tags[-2] == [] and 1 <= len(tags[-1]) <= TAGGING_TOP \
        and all(0 <= x["prob"] <= 1 for x in tags[-1])
    print(("OK " if ok else "NG ") + "区間ごとに周りの音の上位が出る")
    failed += 0 if ok else 1
    print("この PC で使える機能: " + ", ".join(features()))
    if failed:
        sys.exit(1)


def main() -> None:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")  # type: ignore[union-attr]
    parser = argparse.ArgumentParser(description="LifeLog PC（家の PC で3つの音声モデルを動かして多数決で文字にする）")
    parser.add_argument("--test", metavar="音声", help="音声を文字にして、モデルごとの文とかかった時間を表示する")
    parser.add_argument("--segments", help="--test で使う区間（例 0-3.5,4-9）")
    parser.add_argument("--hints", default="", help="--test で Whisper に渡す言葉（、区切り）")
    parser.add_argument("--no-hotwords", action="store_true",
                        help="Haas-ja・ReazonSpeech に登録語を効かせない（前と同じ速い聞き方にする）")
    parser.add_argument("--no-clean", action="store_true",
                        help="聞く前に音をそろえない（低いうなりを削る・小さい声を持ち上げる処理をしない）")
    parser.add_argument("--download", action="store_true", help="モデルを取ってくるだけ")
    parser.add_argument("--check-vote", action="store_true", help="多数決の決まりを確かめる")
    parser.add_argument("--check-extras", metavar="音声",
                        help="聞き逃した声の探し方・話し手の声の特徴・周りの音を、その音声で試す（モデルを取ってくる）")
    parser.add_argument("--startup", action="store_true", help="Windows の起動時に自動で始める")
    parser.add_argument("--no-startup", action="store_true", help="起動時に始めるのをやめる")
    parser.add_argument("--threads", type=int, default=max(1, min(8, (os.cpu_count() or 4) // 2)))
    parser.add_argument("--port", type=int, default=PORT, help=f"待ち受ける番号（既定 {PORT}）")
    parser.add_argument("--provider", default="cpu", help="Haas-ja・ReazonSpeech を動かす場所: cpu（既定）または cuda")
    parser.add_argument("--engines", default="haas,reazon,whisper,kotoba",
                        help="使うモデル（haas,reazon,whisper,kotoba のうち。kotoba は GPU のときだけ動く）")
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
    if args.check_extras:
        check_extras(args.check_extras, max(1, args.threads // 2))
        return
    global USE_HOTWORDS, CLEAN_AUDIO
    if args.no_hotwords:
        USE_HOTWORDS = False
    if args.no_clean:
        CLEAN_AUDIO = False
    names = [n.strip() for n in args.engines.split(",") if n.strip()]

    def factory() -> Ensemble:
        return load_engines(names, args.threads, args.provider, args.whisper, args.device)

    if args.download:
        engine = factory()
        print(f"用意できたモデル: {engine.label}（{engine.provider}）")
        wanted = [n for n in names if n != "kotoba" and not (n == "whisper" and args.whisper == "off")]
        if len(engine.engines) < len(wanted):
            sys.exit(1)
        return
    if args.test:
        test(args.test, factory(), args.segments, [w for w in re.split("[、,]", args.hints) if w])
        return
    try:
        serve(factory, args.port, args.threads)
    except Exception as error:  # noqa: BLE001
        log(f"始められませんでした: {error!r}")
        if getattr(sys, "frozen", False):
            input("Enter を押すと閉じます")
        raise


if __name__ == "__main__":
    main()
