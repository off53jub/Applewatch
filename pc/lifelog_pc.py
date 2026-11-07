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
- POST /transcribe?vad=union  iPhone が聞き逃した声を PC でも探して一緒に文字にする（"extra": true の行）
- POST /speakers?segments=…   区間ごとの話し手の声の特徴（版 5 から 3D-Speaker の CAM++、初回に約30MB を取ってくる）
- POST /scene?segments=…      区間ごとの周りの音の上位 5 つ（Zipformer の音の聞き分け、初回に約110MB を取ってくる）

版 4 で足したもの（どれも、うまく動かなければ前と同じに動く）:
- 行ごとの "words": [[始まり, 終わり, "言葉"], …]  選んだ文を書いたモデルが言葉ごとの時刻を出せるときだけ付ける
  （秒は送られた音声の頭から。言葉をつなげると、空白を除いて行の "text" と同じになる）
- POST /transcribe?enhance=1  雑音を除いた音（GTCRN、初回に約0.5MB を取ってくる）を Haas-ja・ReazonSpeech で
  もう一度聞き、"haas_e"・"reazon_e" の票として多数決に加える（weights にもこの名前を使える）
- POST /train-sample?start=S&end=E&text=…  音声の S〜E 秒と直した文を、あなた向けのモデルの材料として PC に保存する
- GET  /train-status         材料の数・あなた向けのモデルがあるか・作った日
- あなた向けのモデル（train_personal.py で作る）があれば、"mine"（あなた向け Whisper）の票も加える

版 5 で足したもの（どれも、うまく動かなければ前と同じに動く）:
- 多数決で文どうしを比べるとき、言いよどみ（えーと・えっと・あのー・うーん など）を除き、数字と漢数字をそろえる
  （「えーと、明日の会議は三時です」と「明日の会議は3時です」は同じとみなす。返す文はモデルが書いたまま）
- 合言葉が違うときは、送られた音声を読み捨ててから 401 {"error": "合言葉が違います"} を返す（200MB まで）
- POST /speakers の既定のモデルを、いろいろな国の人の声（VoxCeleb）で学んだ 3D-Speaker の CAM++ にする
  （GET /hello の "speaker_model" にファイルの名前。変わったら iPhone は登録した声を測り直す）
- POST /transcribe?vad=union  聞き逃した声を Silero VAD（初回に約0.6MB を取ってくる）で探す
  （読み込めなければ前と同じ音の大きさで探す。features に "silero"）
- "qwen"（Qwen3-ASR 0.6B）の票  --qwen のときだけ。NVIDIA の GPU と、別に入れる torch・qwen-asr の部品が要る
- POST /llm {"prompt": "…", "json": true|false, "max_tokens": N} → {"text": "…"}
  この PC の中で動く Ollama（http://127.0.0.1:11434）に取り次ぐ。動いていてモデルがあるときだけ features に "llm"

版 6 で足したもの（どれも、うまく動かなければ前と同じに動く。中身は jobqueue.py・dashboard.py・updater.py・semantic.py）:
- POST /jobs?name=区切りの名前&hints=…&noisy=0|1&enhance=0|1&weights=…  音声を預けて、後で答えを受け取る
  （PC が声のある区間を自分で探し、/transcribe と同じ多数決で文字にする。同じ名前は2回文字にしない。失敗したものだけやり直す）
  → {"id": 名前, "status": "queued"|"working"|"done"|"failed"}
- GET /jobs/名前 → {"id", "status", "queued_at", "done_at", "error"?, "result": /transcribe と同じ答え（でき上がったときだけ）}
- GET /jobs → {"jobs": [{"id", "status", "queued_at", "done_at"}…]}（新しい順、500 まで）　DELETE /jobs/名前 → 全部消す
  （時刻は 1970 年からの秒。音声は文字にし終えたらすぐ消し、答えは 7 日で消す。起動し直しても続きから文字にする）
- GET /dash  iPhone のブラウザで見る見守りの画面（合言葉で守る。再起動・更新を確かめるボタン）
- 自分で新しい版に入れ替える（GitHub の pc-v6-番号 のリリース。config.json の "auto_update": false か --no-auto-update でやめる）
- POST /index・POST /search・POST /forget・GET /index/status  意味で探す（この PC の Ollama の bge-m3。features に "semantic"）

    LifeLogPC.exe                 普通に起動する（受け付けを始める）
    LifeLogPC.exe --test 音声     その音声を文字にして、モデルごとの文とかかった時間を表示する（--enhance で雑音を除いた票も）
    LifeLogPC.exe --check-extras 音声  おまけの機能を、その音声で試す
    LifeLogPC.exe --startup       Windows の起動時に自動で始まるようにする（--no-startup でやめる）
    python lifelog_pc.py --qwen   Qwen3-ASR の票も加えて起動する（exe には部品が入っていないので Python で動かす）
    LifeLogPC.exe --llm-model 名前  /llm に使う Ollama のモデルを変える（--no-llm で使わない）
    LifeLogPC.exe --no-auto-update  自分で新しい版に入れ替えない（--no-semantic で意味で探す機能を使わない）
    LifeLogPC.exe --check-semantic  この PC の Ollama で、意味で探す機能を本物のモデルで試す

版 7（ops）で足したもの（中身は ops.py・diag.py・apns.py・ascfeedback.py・trainer.py・gpu.py。決まりは docs/v7-plan.md）:
- POST /diag  iPhone の実機の様子を端末ごとに置き、HOME/diag/summary.md に今の様子と気になる所を書く（features に "diag"）
- TestFlight の報告（HOME/asc に App Store Connect のキーがあるときだけ、1日に4回読んで HOME/feedback に置く）
- 見えない通知（HOME/apns に APNs の鍵があり、チームが分かるとき。features に "push"）
- 自動の学び直しと GPU の時間割（/train-status の "auto"。features に "autotrain"）
    LifeLogPC.exe --check-v7-ops   版 7 の見守りを、一時フォルダと作り物の相手で確かめる
    python lifelog_pc.py --fake-models --port 47715  モデルを読み込まずに起動して、受け口と画面を試す

版 8 で足したもの（中身は jobqueue.py。決まりは docs/v8-latency.md。features に "jobwait"・"draft"・"timing"）:
- POST /jobs の chunk_start・chunk_end・arrived・sent（iPhone の時刻）を残し、GET /jobs/名前 に "timing" を付ける
- POST /jobs?wait=1  でき上がりまで答えを待たせ（15 秒ごとに空白）、GET と同じ形で返す。25 分・閉じるときは pending
- 待ち合わせで渡した仕事には「できた」の見えない通知を送らない
- 下書き: 先に haas・reazon だけで文字にして残す（GET はまだのとき "draft"）。その文は多数決でもそのまま使う
- 待っているものが2つ以上なら、新しく受けたものから文字にする
    LifeLogPC.exe --check-v8   版 8 を、一時フォルダと作り物のモデルで確かめる
確かめ（--check-vote・--check-v7-ops・--check-v7-records・--check-v8・--check-v9）は、本物の HOME に書かない（isolate_home）。

版 9 で足したもの（VERSION は 8 のまま。中身は records.py・recordsui.py・lifelog_mcp.py）:
- 職場の会話の印（POST /records/<日> の省ける項目 "work"）。印の無い日は「分からない」
- 記録の画面の「聞いて直す」（/dash/records/review）。直した行・「合っている」行は、PC の音声から材料を作って足す
- この PC の Claude Code から記録を読む MCP サーバー（LifeLogPC.exe --mcp。職場の会話と分からない会話は返さない）
    LifeLogPC.exe --check-v9   版 9 を、一時フォルダと作り物の記録で確かめる
"""

from __future__ import annotations

import argparse
import difflib
import hashlib
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
import wave
import zipfile
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import numpy as np

# 版 6 の機能（lifelog_pc.py と同じフォルダの部品）
import dashboard
import jobqueue
import ops  # 版 7（ops）: 実機の様子・見えない通知・TestFlight の報告・学び直しと GPU の時間割（中身は ops.py）
import semantic
import updater
# 版 7（records）: 記録・音声の保存・直し（records.py）と、その画面（recordsui.py）
import records
import recordsui

VERSION = 8
# 作った回の番号（GitHub Actions が exe の隣の BUILD.txt に書く。Python のままなら 0）
INSTALL_DIR = Path(sys.executable).parent if getattr(sys, "frozen", False) else Path(__file__).resolve().parent
BUILD = updater.read_build(INSTALL_DIR)
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
# あなた向けのモデルの材料（data）と、train_personal.py が作ったモデル（model）。どちらも PC の外には出さない
PERSONAL_DIR = HOME / "personal"
PERSONAL_DATA = PERSONAL_DIR / "data"
PERSONAL_MODEL = PERSONAL_DIR / "model"
# 後で受け取る文字起こしの音声と答え・意味で探すための行と数の並び（版 6）。どちらも PC の外には出さない
JOBS_DIR = HOME / "jobs"
SEMANTIC_DB = HOME / "semantic.db"


# 版 8: HOME の下の置き場所（確かめるときに、まとめて一時のフォルダに替える）
HOME_PATHS = (("MODEL_DIR", "model"), ("REAZON_DIR", "reazon"), ("WHISPER_DIR", "whisper"), ("CUDA_DIR", "cuda"),
              ("CONFIG", "config.json"), ("LOG", "log.txt"), ("PERSONAL_DIR", "personal"),
              ("PERSONAL_DATA", "personal/data"), ("PERSONAL_MODEL", "personal/model"), ("JOBS_DIR", "jobs"),
              ("SEMANTIC_DB", "semantic.db"), ("QWEN_DIR", "qwen"), ("SPEAKER_DIR", "speaker"),
              ("TAGGING_DIR", "tagging"), ("ENHANCE_DIR", "enhance"), ("VAD_DIR", "vad"))
_isolated: Path | None = None
_START_HOME = HOME  # 起動したときの HOME（確かめで、替えたことを確かめる）


def use_home(folder: Path) -> None:
    """HOME と、その下の置き場所を全部 folder に替える（確かめ・試しのとき用）"""
    global HOME
    HOME = Path(folder)
    module = sys.modules[__name__]
    for name, sub in HOME_PATHS:
        setattr(module, name, HOME / sub)


def isolate_home() -> Path:
    """確かめるときは、本物の HOME（%LOCALAPPDATA%\\LifeLogPC）の記録（log.txt）やデータに書かないよう、
    環境変数 LOCALAPPDATA と HOME の置き場所を、終わると消える一時のフォルダに替える。2回目からは何もしない。"""
    global _isolated
    if _isolated is not None:
        return _isolated
    import atexit
    import shutil
    import tempfile

    root = Path(tempfile.mkdtemp(prefix="lifelog-check-"))
    os.environ["LOCALAPPDATA"] = str(root)
    use_home(root / "LifeLogPC")
    _isolated = root
    atexit.register(shutil.rmtree, root, True)
    return root


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


# MARK: - 言葉ごとの時刻（"words"）

# 言葉ごとの時刻を付ける（--no-words でやめる。Whisper は時刻を出す分だけ少し遅くなる）
WORD_TIMES = True
WORD_MAX = 1.0  # 次の言葉までが長くても、1つの言葉はこれより長くしない（間の無音を含めない）


def token_pieces(tokens, timestamps, durations, offset: float, end: float) -> list[tuple[float, float, str]] | None:
    """sherpa-onnx の結果のトークンと始まりの時刻（区間の頭からの秒）を、音声の頭からの [始まり, 終わり, 字] にする。
    長さ（durations）が無いモデルは、次のトークンの始まりを終わりにする。数が合わなければ None。"""
    tokens = [str(t) for t in (tokens or [])]
    starts = [float(t) for t in (timestamps or [])]
    if not tokens or len(starts) != len(tokens):
        return None
    lengths = [float(d) for d in (durations or [])]
    use_lengths = len(lengths) == len(tokens) and any(d > 0 for d in lengths)
    pieces = []
    for i, token in enumerate(tokens):
        s = min(offset + starts[i], end)
        if use_lengths:
            e = s + lengths[i]
        elif i + 1 < len(starts):
            e = offset + starts[i + 1]
        else:
            e = end
        pieces.append((s, max(s, min(e, s + WORD_MAX, end)), token))
    return pieces


def _bare(text: str) -> str:
    return re.sub(r"\s+", "", text)


def group_words(pieces: list[tuple[float, float, str]] | None, text: str) -> list[list] | None:
    """[始まり, 終わり, 字] の並びを、行の文に合う [[始まり, 終わり, "言葉"], …] にする。
    句読点・記号だけのものは前の言葉に付ける。"▁"（sentencepiece の区切り）が途中にあれば、それを言葉の切れ目にする。
    つなげた言葉が文と（空白を除いて）同じにならなければ、当て推量はせず None。"""
    if not pieces or not _bare(text):
        return None
    spaced = any("▁" in p for _, _, p in pieces[1:])
    words: list[list] = []
    for s, e, piece in pieces:
        piece = piece.replace("▁", " ")
        bare = _bare(piece)
        if not bare:
            continue
        mark = not any(ch.isalnum() for ch in bare)
        if words and (mark or (spaced and not piece[:1].isspace())):
            words[-1][1] = max(words[-1][1], e)
            words[-1][2] += bare
        else:
            words.append([s, e, bare])
    if "".join(w[2] for w in words) != _bare(text):
        return None
    # 前から順に、重ならないようにそろえる
    out: list[list] = []
    last = 0.0
    for s, e, word in words:
        s = max(float(s), last)
        e = max(float(e), s)
        out.append([round(s, 2), round(e, 2), word])
        last = e
    return out


def words_fit(words: list[list] | None, text: str) -> bool:
    """words をつなげると、空白を除いて text と同じになるか"""
    return bool(words) and "".join(w[2] for w in words) == _bare(text)


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
        return [text for text, _ in self.run_timed(audio, segments, hints, prompt)]

    def run_timed(self, audio: np.ndarray, segments: list[tuple[float, float]], hints: list[str],
                  prompt: str | None) -> list[tuple[str, list | None]]:
        """区間ごとの (文, 言葉ごとの時刻)。時刻が出せなければ None。"""
        out: list[tuple[str, list | None]] = []
        hotwords = hotword_string(hints, self.chars) if USE_HOTWORDS else ""
        with self.lock:
            for start, end in segments:
                a = max(0, int(start * RATE))
                b = min(len(audio), int(end * RATE))
                if b - a < int(0.3 * RATE):
                    out.append(("", None))
                    continue
                stream = self.recognizer.create_stream(hotwords=hotwords) if hotwords else self.recognizer.create_stream()
                stream.accept_waveform(RATE, audio[a:b])
                self.recognizer.decode_stream(stream)
                result = stream.result
                text = result.text.strip()
                words = None
                if WORD_TIMES and text:
                    try:
                        pieces = token_pieces(getattr(result, "tokens", None), getattr(result, "timestamps", None),
                                              getattr(result, "durations", None), a / RATE, b / RATE)
                        words = group_words(pieces, text)
                    except Exception:  # noqa: BLE001 — 時刻が読めなくても文は使う
                        words = None
                out.append((text, words))
        return out

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
        if self.name in ("kotoba", "mine") and not use_gpu:
            # 日本語で学び直した Whisper（kotoba・あなた向け）は追加の票。CPU では遅すぎるので GPU のときだけ使う
            raise RuntimeError("GPU が無いので使いません")
        if self.name == "mine" and not personal_model_ready():
            raise RuntimeError(f"あなた向けのモデルがまだありません（{PERSONAL_MODEL}）")
        if use_gpu:
            try:
                prepare_cuda()
            except Exception as error:  # noqa: BLE001 — GPU が使えなければ CPU で続ける
                if self.name in ("kotoba", "mine"):
                    raise RuntimeError(f"GPU の部品を用意できないので使いません: {error!r}") from error
                log(f"GPU の部品を用意できませんでした。CPU で動かします: {error!r}")
                use_gpu = False
        if self.name == "kotoba":
            model = KOTOBA_REPO
        elif self.name == "mine":
            model = str(PERSONAL_MODEL)
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
                if self.name in ("kotoba", "mine"):
                    # 追加の票は GPU のときだけ。CPU で動かすと録音に追いつかなくなる（2026-11-06。5分の区切りに816秒かかっていた）
                    raise RuntimeError(f"GPU で読み込めないので使いません: {error!r}") from error
                log(f"GPU で読み込めませんでした。CPU で動かします: {error!r}")
                if model == "large-v3":
                    model = "large-v3-turbo"
        if self.model is None:
            self.model = WhisperModel(model, device="cpu", compute_type="int8", cpu_threads=threads,
                                      download_root=str(WHISPER_DIR))
            self.provider = "cpu"
        self.label = {"kotoba": "kotoba-whisper", "mine": "あなた向け Whisper"}.get(self.name, f"Whisper {model}")
        self.lock = threading.Lock()
        log(f"Whisper を読み込みました（{self.label}、{time.time() - started:.1f} 秒、{self.provider}）")

    def run(self, audio: np.ndarray, segments: list[tuple[float, float]], hints: list[str],
            prompt: str | None) -> list[str]:
        return [text for text, _ in self.run_timed(audio, segments, hints, prompt)]

    def run_timed(self, audio: np.ndarray, segments: list[tuple[float, float]], hints: list[str],
                  prompt: str | None) -> list[tuple[str, list | None]]:
        """区間ごとの (文, 言葉ごとの時刻)。時刻が出せなければ None。"""
        # ヒント（名前・専門用語）は先頭ほど効くので、前の区切りの文より先に置く
        initial = "、".join(hints[:40])
        if prompt:
            initial = (initial + "。" if initial else "") + prompt[-120:]
        out: list[tuple[str, list | None]] = []
        with self.lock:
            for start, end in segments:
                a = max(0, int(start * RATE))
                b = min(len(audio), int(end * RATE))
                if b - a < int(0.3 * RATE):
                    out.append(("", None))
                    continue
                pieces, _ = self.model.transcribe(
                    audio[a:b], language="ja", beam_size=5, initial_prompt=initial or None,
                    condition_on_previous_text=False, without_timestamps=True, vad_filter=False,
                    temperature=0.0, word_timestamps=WORD_TIMES)
                kept = []
                timed: list[tuple[float, float, str]] = []
                timed_ok = WORD_TIMES
                for piece in pieces:
                    # 言葉の時刻を付けると、faster-whisper は最後の言葉の後ろをもう一度聞き直すことがある。
                    # 区間は 30 秒の窓1つに収まるので、最初の窓（seek 0）だけを使えば、時刻を付けないときと同じ文になる
                    if WORD_TIMES and getattr(piece, "seek", 0) > 0:
                        break
                    text = piece.text.strip()
                    # 声が無いのに作った文（無音らしさが高く、自信が低い）と決まり文句は捨てる
                    if piece.no_speech_prob > 0.6 and piece.avg_logprob < -1.0:
                        continue
                    if WHISPER_JUNK.match(text):
                        continue
                    kept.append(text)
                    if not piece.words:
                        timed_ok = False
                        continue
                    for word in piece.words:
                        s = min(a / RATE + float(word.start), b / RATE)
                        timed.append((s, max(s, min(a / RATE + float(word.end), b / RATE)), word.word))
                text = "".join(kept)
                out.append((text, group_words(timed, text) if timed_ok and text else None))
        return out


class KotobaEngine(WhisperEngine):
    """日本語の話し言葉で学び直した Whisper（kotoba-whisper v2.0、MIT）。GPU があるときの4票目。"""

    name = "kotoba"


def personal_model_ready() -> bool:
    """train_personal.py が作った、あなた向けのモデル（CTranslate2 の形）があるか"""
    return (PERSONAL_MODEL / "model.bin").exists()


class MineEngine(WhisperEngine):
    """あなたの声と直した文で学び直した Whisper（train_personal.py で作る）。GPU があるときの追加の票。"""

    name = "mine"


# MARK: - Qwen3-ASR（使う設定にしたときだけの追加の票 "qwen"）
# torch・transformers・qwen-asr（公式の部品）が要る。exe には入れない（大きすぎるため）。
# NVIDIA の GPU が使え、部品が入っていて、--qwen か config.json の "qwen": true のときだけ読み込む。

QWEN_MODEL = "Qwen/Qwen3-ASR-0.6B"   # 1.7B にするときは --qwen-model Qwen/Qwen3-ASR-1.7B
QWEN_DIR = HOME / "qwen"
QWEN_BATCH = 8          # 一度に聞く区間の数（GPU のメモリが足りないときは小さく）
QWEN_MAX_TOKENS = 256   # 1つの区間（20 秒まで）で書く長さの上限
QWEN_LANGUAGE = "Japanese"


class Unavailable(RuntimeError):
    """この PC では使えない（部品が無い・GPU が無いなど）。"""


def optional_module(name: str):
    """入っていれば読み込む部品（exe を作るときに、勝手に中に入れられないよう名前で読み込む）。"""
    import importlib

    return importlib.import_module(name)


class QwenEngine:
    """公式の qwen-asr の部品（transformers を使う版）で Qwen3-ASR を動かす。"""

    name = "qwen"

    def __init__(self, repo: str) -> None:
        try:
            torch = optional_module("torch")
            qwen_asr = optional_module("qwen_asr")
        except Exception as error:  # noqa: BLE001
            raise Unavailable(f"torch・qwen-asr の部品が入っていません（{error}）") from error
        if not torch.cuda.is_available():
            raise Unavailable("NVIDIA の GPU を使えません（GPU が無いか、ドライバーが古い）")
        # すでに取ってきたフォルダを渡されたらそれを使う。名前（Qwen/…）なら初回に QWEN_DIR に取ってくる
        local = Path(repo) if (Path(repo) / "config.json").exists() else QWEN_DIR / repo.replace("/", "--")
        if not (local / "config.json").exists():
            log(f"Qwen3-ASR（{repo}）を取ってきます。初回だけです。置き場所: {local}")
            from huggingface_hub import snapshot_download

            snapshot_download(repo_id=repo, local_dir=str(local))
        # bfloat16 は Ampere（RTX 30 の世代）から。それより前の GPU は float16 にする
        major = torch.cuda.get_device_capability(0)[0]
        dtype = torch.bfloat16 if major >= 8 else torch.float16
        log(f"Qwen3-ASR を読み込んでいます…（{repo}、{dtype}）")
        started = time.time()
        self.model = qwen_asr.Qwen3ASRModel.from_pretrained(
            str(local), dtype=dtype, device_map="cuda:0",
            max_inference_batch_size=QWEN_BATCH, max_new_tokens=QWEN_MAX_TOKENS)
        self.provider = "cuda"
        self.label = f"Qwen3-ASR {repo.rsplit('/', 1)[-1].removeprefix('Qwen3-ASR-')}"
        self.lock = threading.Lock()
        log(f"Qwen3-ASR を読み込みました（{self.label}、{time.time() - started:.1f} 秒）")

    def run(self, audio: np.ndarray, segments: list[tuple[float, float]], hints: list[str],
            prompt: str | None) -> list[str]:
        """区間ごとの文（聞き取れなければ空）。登録した言葉は context（手がかりの文）として渡す。"""
        clips, index = [], []
        for i, (start, end) in enumerate(segments):
            samples = clip(audio, start, end)
            if len(samples) >= int(0.3 * RATE):
                clips.append((samples, RATE))
                index.append(i)
        out = [""] * len(segments)
        if not clips:
            return out
        with self.lock:
            results = self.model.transcribe(audio=clips, context="、".join(hints[:40]), language=QWEN_LANGUAGE)
        for i, result in zip(index, results):
            out[i] = str(getattr(result, "text", "") or "").strip()
        return out


# MARK: - 多数決


_kakasi = None
_kakasi_lock = threading.Lock()


_KANJI_DIGITS = "零一二三四五六七八九"


def kanji_number(digits: str) -> str:
    """"2026" → "二千二十六" のように、数字（0〜9 だけの並び）を漢数字にする。
    0 で始まるもの（電話番号など）と 17 桁以上のものは、1 文字ずつ置き換える（「零九零」）。"""
    if not digits.isdigit() or not digits.isascii():
        return digits
    if (len(digits) > 1 and digits[0] == "0") or len(digits) > 16:
        return "".join(_KANJI_DIGITS[int(d)] for d in digits)
    number = int(digits)
    if number == 0:
        return "零"
    out = ""
    for unit, big in ((10 ** 12, "兆"), (10 ** 8, "億"), (10 ** 4, "万"), (1, "")):
        group, number = divmod(number, unit)
        if not group:
            continue
        part = ""
        for value, name in ((1000, "千"), (100, "百"), (10, "十")):
            d, group = divmod(group, value)
            if d:
                part += ("" if d == 1 else _KANJI_DIGITS[d]) + name
        if group:
            part += _KANJI_DIGITS[group]
        out += part + big
    return out


def kanji_numbers(text: str) -> str:
    """文の中の数字を漢数字にする（「3時」と「三時」、「1人」と「一人」を同じ読みにするため）。
    「1,000」の区切りの点は外し、「3.5」は「三点五」にする。比べるときだけに使い、返す文は変えない。"""
    text = re.sub(r"(?<![0-9])[0-9]{1,3}(?:,[0-9]{3})+(?![0-9])", lambda m: m.group(0).replace(",", ""), text)
    text = re.sub(r"([0-9]+)\.([0-9]+)", lambda m: kanji_number(m.group(1)) + "点"
                  + "".join(_KANJI_DIGITS[int(d)] for d in m.group(2)), text)
    return re.sub(r"[0-9]+", lambda m: kanji_number(m.group(0)), text)


# MARK: - 言いよどみ（えーと・あのー など）
# 多数決で文どうしを比べるときだけ、はっきりした言いよどみを除く（返す文はそのまま）。
# 「あのー」と書くモデルと書かないモデルがあるだけで、同じ文が「食い違い」に見えないようにするため。
# 「あの」（あの人）・「その」・「うん」（はい の意味）・「ええ」（はい の意味）・「ううん」（いいえ の意味）・
# 「なんか」は、中身のある言葉のことが多いので除かない。

_LONG = "ー〜～~"
# 言葉の切れ目（文の頭・句読点・空白・かっこ）
_EDGE = r"\s、。，．,.!?！？…‥・「」『』()（）"
_BEFORE = rf"(?<![^{_EDGE}])"          # 前が文の頭か切れ目
_AFTER = rf"(?=[{_EDGE}]|$)"           # 後ろが切れ目か文の終わり
_TAIL = rf"[{_EDGE}]*"                 # 言いよどみの後ろの句読点も一緒に除く
_FILLER_PATTERNS = [
    # どこにあっても言いよどみとしか読めないもの（えーと・えーっと・えっと・ええっと・あのー・うーん）
    re.compile(rf"(?:え[{_LONG}]+っ?と[{_LONG}]*|ええっと[{_LONG}]*|えっと[{_LONG}]*|あの[{_LONG}]+|う[{_LONG}]+ん){_TAIL}"),
    # 言葉の頭にあるときだけ（えー・そのー・んー・んーと）
    re.compile(rf"{_BEFORE}(?:え[{_LONG}]+|その[{_LONG}]+|ん[{_LONG}]+と?){_TAIL}"),
    # 前後が切れ目のときだけ（「まあ、」「あー、」「えと、」。「まあまあ」「あーいう」「えとう」は除かない）
    re.compile(rf"{_BEFORE}(?:まあ|まぁ|ま[{_LONG}]+|あ[{_LONG}]+|えと){_AFTER}{_TAIL}"),
]


def strip_fillers(text: str) -> str:
    """はっきりした言いよどみ（えーと・えっと・あのー・うーん・んー・文の頭の「えー」・切れ目にある「まあ」など）を除いた文。"""
    text = unicodedata.normalize("NFKC", text)
    for _ in range(4):  # 「えーと、あのー、」のように続くものも除く
        before = text
        for pattern in _FILLER_PATTERNS:
            text = pattern.sub("", text)
        if text == before:
            break
    return text


def vote_reading(text: str) -> str:
    """多数決で比べるための読み。言いよどみを除き、数字は漢数字にそろえる。
    言いよどみしか無い文（「えーと」だけ）は、除かずに比べる。"""
    stripped = reading(strip_fillers(text))
    return stripped or reading(text)


def reading(text: str) -> str:
    """文の読み（ひらがな）。漢字とかなの書き方の違いで食い違いにしないため。句読点・空白は除く。
    数字は漢数字にしてから読む（「3時」も「三時」も「さんじ」）。"""
    global _kakasi
    text = kanji_numbers(unicodedata.normalize("NFKC", text))
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
    """2つの文の読みがどれだけ同じか（0〜1）。言いよどみの有り無しと、数字と漢数字の違いは数えない。"""
    ra, rb = vote_reading(a), vote_reading(b)
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
# （"_e" は雑音を除いた音でもう一度聞いた票。同じモデルなので、もとの票より後にする）
PRIORITY = ["haas", "reazon", "whisper", "kotoba", "mine", "qwen", "haas_e", "reazon_e", "cloud"]
# Whisper の書き方を使ってよい近さ（読みがほぼ同じなら、ヒントを渡した Whisper の漢字の書き方のほうが名前に強い）
SURFACE_SIMILAR = 0.85
# Whisper だけが書いた文は、ほかが何も聞き取っていなければ作り話とみなす
# （Qwen3-ASR も言語モデルで文を作るので同じに扱う）
INVENTING = {"whisper", "kotoba", "mine", "qwen", "cloud"}


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


def vote(hypotheses: dict[str, str], weights: dict[str, float] | None = None,
         sims_out: dict | None = None) -> dict | None:
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
    # 測った近さを、モデルの組ごとの見立て（pair_stats）でもう一度測らずに使えるよう渡す
    if sims_out is not None:
        sims_out.update(sims)
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


def _voter_order(name: str) -> tuple[int, str]:
    return (PRIORITY.index(name) if name in PRIORITY else len(PRIORITY), name)


def pair_stats(rows: list[tuple[dict[str, str], dict | None]]) -> dict:
    """区間ごとの (モデルごとの文, vote() が測った近さ) から、食い違いの見立てを作る（文の中身は入れない）。

    pairs:      モデルの組ごとの、言いよどみを除いた読みの近さの平均（両方が何か書いた区間だけ）
    pair_lines: その平均に使った区間の数
    silent:     ほかのモデルは何か書いたのに、そのモデルは何も書かなかった区間の数（1 以上のものだけ）
    heard_lines: どれかのモデルが何か書いた区間の数
    組の名前は PRIORITY の順に "haas-reazon" の形。近さは vote() が測ったものを使い、無い組だけ測る。"""
    totals: dict[tuple[str, str], list[float]] = {}
    silent: dict[str, int] = {}
    heard_lines = 0
    for hypotheses, known in rows:
        names = sorted(hypotheses, key=_voter_order)
        heard = [k for k in names if (hypotheses[k] or "").strip()]
        if not heard:
            continue
        heard_lines += 1
        for k in names:
            if k not in heard:
                silent[k] = silent.get(k, 0) + 1
        for i, a in enumerate(heard):
            for b in heard[i + 1:]:
                sim = (known or {}).get((a, b))
                if sim is None:
                    sim = similarity(hypotheses[a], hypotheses[b])
                entry = totals.setdefault((a, b), [0.0, 0])
                entry[0] += float(sim)
                entry[1] += 1
    keys = sorted(totals, key=lambda p: (_voter_order(p[0]), _voter_order(p[1])))
    return {"pairs": {f"{a}-{b}": round(totals[(a, b)][0] / totals[(a, b)][1], 2) for a, b in keys},
            "pair_lines": {f"{a}-{b}": int(totals[(a, b)][1]) for a, b in keys},
            "silent": {k: silent[k] for k in sorted(silent, key=_voter_order)},
            "heard_lines": heard_lines}


def pair_stats_line(stats: dict) -> str:
    """記録に書く1行（数だけ。文の中身は書かない）"""
    pairs = "・".join(f"{k} {v:.2f}" for k, v in stats.get("pairs", {}).items()) or "（なし）"
    silent = "・".join(f"{k} {v}" for k, v in stats.get("silent", {}).items()) or "なし"
    return f"  モデルの組の近さ: {pairs}／何も書かなかった: {silent}（声のある区間 {stats.get('heard_lines', 0)}）"


# 版 8: 下書きに使う速いモデル（後で受け取る文字起こしで、先にこれだけで文字にして「仮」として見せる）
DRAFT_ENGINES = ("haas", "reazon")


class Ensemble:
    """読み込めたモデルを全部動かし、区間ごとに多数決する。"""

    def __init__(self, engines: list) -> None:
        if not engines:
            raise RuntimeError("動かせるモデルがありません")
        self.engines = engines
        # 雑音を除いた音でもう一度聞く分（haas_e・reazon_e）も並べられるよう、多めにしておく
        self.pool = ThreadPoolExecutor(max_workers=len(engines) * 2)
        gpu = any(getattr(e, "provider", "") == "cuda" for e in engines)
        self.provider = "cuda" if gpu else "cpu"
        self.label = "＋".join(e.label for e in engines)

    def transcribe(self, audio: np.ndarray, segments: list[tuple[float, float]], hints: list[str] | None = None,
                   prompt: str | None = None, votes: bool = False,
                   weights: dict[str, float] | None = None, extra_from: int | None = None,
                   enhance: bool = False, stats: dict | None = None, on_draft=None) -> list[dict]:
        """extra_from を渡すと、その番号から後ろの区間（PC が見つけた、iPhone が聞き逃した声）の行に "extra": true を付け、
        全部の行を時間の順に並べ直す。enhance なら、雑音を除いた音を Haas-ja・ReazonSpeech でもう一度聞いた票も加える。
        stats に dict を渡すと、モデルの組ごとの近さ（pair_stats）を入れて返す。
        版 8: on_draft(行, モデルの名前) を渡すと、速いモデル（DRAFT_ENGINES）が書き終えたところで、それだけの多数決を
        下書きとして渡す。そのモデルの文は、あとの多数決でもそのまま使う（同じ音声を2回読まない）。
        下書きを作れなくても、多数決は続ける。"""
        source = audio
        if CLEAN_AUDIO:
            audio = clean_audio(audio, segments)
        # 版 8: いつもの票を先に始める（雑音を除くのを待たずに、速いモデルが書き始められる。答えは前と同じ）
        jobs = {e.name: self.pool.submit(self._run, e, audio, segments, hints or [], prompt) for e in self.engines}
        denoised = None
        if enhance and any(isinstance(e, Engine) for e in self.engines):
            try:
                denoised = extra_model("enhance", ENHANCE_THREADS).denoise_segments(source, segments)
                if CLEAN_AUDIO:
                    denoised = clean_audio(denoised, segments)
            except Exception as error:  # noqa: BLE001 — 雑音を除けなくても、いつもの票だけで決める
                log(f"雑音を除けませんでした（いつもの票だけで決めます）: {error!r}")
                denoised = None
        if denoised is not None:
            for e in self.engines:
                if isinstance(e, Engine):
                    jobs[e.name + "_e"] = self.pool.submit(self._run, e, denoised, segments, hints or [], prompt)
        results: dict[str, list[tuple[str, list | None]]] = {}

        def collect(name: str) -> None:
            if name in results:
                return
            try:
                results[name] = jobs[name].result()
            except Exception as error:  # noqa: BLE001 — 1つが失敗しても、残りで決める
                log(f"{name} で文字にできませんでした: {error!r}")
                results[name] = None  # type: ignore[assignment]

        if on_draft is not None:
            fast = [name for name in DRAFT_ENGINES if name in jobs]
            if fast and len(fast) < len(jobs):
                for name in fast:
                    collect(name)
                got = {name: results[name] for name in fast if results.get(name) is not None}
                try:
                    if got:
                        on_draft(self._lines(got, segments, weights, votes, extra_from, []), list(got))
                except Exception as error:  # noqa: BLE001 — 下書きを作れなくても、多数決は続ける
                    log(f"下書きを作れませんでした（このまま多数決をします）: {error!r}")
        for name in jobs:
            collect(name)
        results = {name: results[name] for name in jobs if results.get(name) is not None}  # 前と同じ並び
        if not results:
            raise RuntimeError("どのモデルでも文字にできませんでした")
        rows: list[tuple[dict[str, str], dict]] = []
        lines = self._lines(results, segments, weights, votes, extra_from, rows)
        if stats is not None:
            try:
                stats.update(pair_stats(rows))
            except Exception as error:  # noqa: BLE001 — 見立てが作れなくても、文字にした行は返す
                log(f"モデルの組の近さを測れませんでした: {error!r}")
        return lines

    @staticmethod
    def _lines(results: dict[str, list[tuple[str, list | None]]], segments: list[tuple[float, float]],
               weights: dict[str, float] | None, votes: bool, extra_from: int | None,
               rows: list[tuple[dict[str, str], dict]]) -> list[dict]:
        """モデルごとの区間の文から、区間ごとに多数決した行（rows に区間ごとの票と近さを足す）"""
        lines = []
        for i, (start, end) in enumerate(segments):
            hypotheses = {name: got[i][0] if i < len(got) else "" for name, got in results.items()}
            known: dict = {}
            picked = vote(hypotheses, weights, known)
            rows.append((hypotheses, known))
            if not picked:
                continue
            line = {"start": round(start, 2), "end": round(end, 2), "text": picked["text"]}
            # 言葉ごとの時刻は、選んだ文を書いたモデルのものをそのまま使う（ほかの票で直した文 "+rover" には付けない）
            chosen = picked["engine"]
            if WORD_TIMES and chosen in results and i < len(results[chosen]):
                words = results[chosen][i][1]
                if words_fit(words, picked["text"]):
                    line["words"] = words
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

    @staticmethod
    def _run(engine, audio: np.ndarray, segments: list[tuple[float, float]], hints: list[str],
             prompt: str | None) -> list[tuple[str, list | None]]:
        """区間ごとの (文, 言葉ごとの時刻)。時刻を出せないモデルは None にする。"""
        if hasattr(engine, "run_timed"):
            return engine.run_timed(audio, segments, hints, prompt)
        return [(text, None) for text in engine.run(audio, segments, hints, prompt)]


def load_engines(names: list[str], threads: int, provider: str, whisper: str, device: str,
                 qwen: str | None = None) -> Ensemble:
    """頼まれたモデルを読み込む。読み込めなかったモデルは飛ばす（Haas-ja だけでも動く）。
    qwen に Qwen3-ASR のモデルの名前を渡したときだけ、"qwen" も読み込む（使えなければ一言だけ記録して飛ばす）。"""
    engines = []
    for name in names:
        if name == "qwen":
            if qwen:
                try:
                    engines.append(QwenEngine(qwen))
                except Unavailable as error:
                    log(f"Qwen3-ASR は使いません: {error}")
                except Exception as error:  # noqa: BLE001
                    log(f"Qwen3-ASR を読み込めませんでした（このモデル抜きで続けます）: {error!r}")
            continue
        try:
            if name == "haas":
                engines.append(Engine(threads, provider))
            elif name == "reazon":
                engines.append(ReazonEngine(max(1, threads // 2), provider))
            elif name == "whisper" and whisper != "off":
                engines.append(WhisperEngine(whisper, device, threads))
            elif name == "kotoba" and whisper != "off":
                engines.append(KotobaEngine(whisper, device, threads))
            elif name == "mine" and whisper != "off" and personal_model_ready():
                # あなた向けのモデルは、train_personal.py で作ったあとだけ（無ければ何も言わずに飛ばす）
                engines.append(MineEngine(whisper, device, threads))
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


def loud_regions(audio: np.ndarray) -> list[tuple[float, float]]:
    """声らしい大きな音の区間（モデルは使わない、音の大きさだけで決める。Silero VAD が使えないときの代わり）。
    30ms ごとの大きさ（dB）を測り、周りの音（小さいほうから 20%）より 10dB 大きい所を拾う。"""
    frame = int(EXTRA_FRAME * RATE)
    count = len(audio) // frame
    if count < 2:
        return []
    frames = np.asarray(audio[:count * frame], dtype=np.float64).reshape(count, frame)
    db = 20.0 * np.log10(np.sqrt(np.mean(frames * frames, axis=1)) + 1e-10)
    threshold = max(float(np.percentile(db, EXTRA_NOISE_PCT)) + EXTRA_MARGIN_DB, EXTRA_MIN_DB)
    loud = (db > threshold).astype(np.int8)
    edges = np.flatnonzero(np.diff(np.concatenate([[0], loud, [0]])))
    return [(float(a * EXTRA_FRAME), float(b * EXTRA_FRAME)) for a, b in zip(edges[0::2], edges[1::2])]


def extra_speech(audio: np.ndarray, segments: list[tuple[float, float]],
                 regions: list[tuple[float, float]] | None = None) -> list[tuple[float, float]]:
    """iPhone の区間の外にある、声らしい区間。

    regions（声の区間。Silero VAD などで見つけたもの）を渡さなければ、音の大きさだけで探す（loud_regions）。
    0.3 秒より短い切れ目はつなぎ、0.4 秒より短いものは捨てる。iPhone の区間と半分より多く重なるものも捨てる。
    少しだけ重なるものは、重なった所を除いた残りを返す（同じ所を2回文字にしないため）。
    """
    duration = len(audio) / RATE
    if regions is None:
        regions = loud_regions(audio)
    merged: list[list[float]] = []
    for start, end in sorted((float(a), float(b)) for a, b in regions if b > a):
        if merged and start - merged[-1][1] < EXTRA_GAP:
            merged[-1][1] = max(merged[-1][1], end)
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
# 3D-Speaker の CAM++（iPhone の WeSpeaker ResNet34 とは違う作りのモデル、Apache-2.0）。
# 版 4 までは中国語の声だけで学んだ ERes2Net（3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx）だった。
# 版 5 からは、いろいろな国の人の声（VoxCeleb）で学んだものにする。LIFELOG_SPEAKER_MODEL で前のものにも戻せる。
# 置き場所の名前 "speaker-recongition-models" の綴りの誤りは、元のまま（直すと取ってこられない）
SPEAKER_MODEL = os.environ.get("LIFELOG_SPEAKER_MODEL", "3dspeaker_speech_campplus_sv_en_voxceleb_16k.onnx")
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
    log(f"話し手の声の特徴を出すモデル（{SPEAKER_MODEL}、約30MB）を取ってきます。初回だけです。置き場所: {SPEAKER_DIR}")
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


# MARK: - 雑音を除いてもう一度聞く（enhance=1）
# GTCRN（とても小さい雑音除去のモデル、MIT）。sherpa-onnx の OfflineSpeechDenoiser で動かす。

ENHANCE_MODEL = "gtcrn_simple.onnx"
ENHANCE_URL = f"{RELEASES}/speech-enhancement-models/{ENHANCE_MODEL}"
ENHANCE_DIR = HOME / "enhance"
ENHANCE_THREADS = 2
ENHANCE_MIN = 0.3  # これより短い区間は除かずにそのまま（文字にもしない長さ）
# 雑音除去は 256 サンプルずつ進むので、終わりが切れないよう後ろに無音を足してから、もとの長さに切る。
# 長さが 0 の音を渡すと sherpa-onnx 2.0.1 は落ちるので、短い音は渡さない
ENHANCE_PAD = 512


def download_enhance() -> Path:
    path = ENHANCE_DIR / ENHANCE_MODEL
    if path.exists() and path.stat().st_size > 100_000:
        return path
    log(f"雑音を除くモデル（{ENHANCE_MODEL}、約0.5MB）を取ってきます。初回だけです。置き場所: {ENHANCE_DIR}")
    fetch(ENHANCE_URL, path)
    return path


class Denoiser:
    """声の区間ごとに雑音を除いた音を作る（時刻はずれない）。"""

    def __init__(self, threads: int) -> None:
        import sherpa_onnx

        path = download_enhance()
        # 設定の部品は、C++ 側が使い終わるまで消えないよう持っておく
        self.gtcrn = sherpa_onnx.OfflineSpeechDenoiserGtcrnModelConfig(model=str(path))
        self.model_config = sherpa_onnx.OfflineSpeechDenoiserModelConfig(gtcrn=self.gtcrn, num_threads=threads,
                                                                          provider="cpu")
        self.config = sherpa_onnx.OfflineSpeechDenoiserConfig(model=self.model_config)
        if not self.config.validate():
            raise RuntimeError(f"雑音を除くモデルの設定が正しくありません: {self.config}")
        self.denoiser = sherpa_onnx.OfflineSpeechDenoiser(self.config)
        if int(self.denoiser.sample_rate) != RATE:
            raise RuntimeError(f"雑音を除くモデルの音の細かさが {self.denoiser.sample_rate} Hz です（{RATE} Hz が要ります）")
        self.name = path.stem
        self.lock = threading.Lock()
        log(f"雑音を除くモデルを読み込みました（{self.name}）")

    def denoise(self, samples: np.ndarray) -> np.ndarray:
        """同じ長さの、雑音を除いた音。短すぎる音・うまくいかなかった音は、もとのまま返す。"""
        samples = np.ascontiguousarray(samples, dtype=np.float32)
        if len(samples) < int(ENHANCE_MIN * RATE):
            return samples.copy()
        padded = np.concatenate([samples, np.zeros(ENHANCE_PAD, dtype=np.float32)])
        with self.lock:
            result = self.denoiser.run(padded, RATE)
        out = np.asarray(result.samples, dtype=np.float32)
        if len(out) < len(samples) or not np.all(np.isfinite(out[:len(samples)])):
            return samples.copy()
        return np.ascontiguousarray(out[:len(samples)])

    def denoise_segments(self, audio: np.ndarray, segments: list[tuple[float, float]]) -> np.ndarray:
        """声の区間だけ雑音を除いた、audio と同じ長さの音（区間の外は無音。モデルは区間の中しか聞かない）。"""
        out = np.zeros_like(audio, dtype=np.float32)
        for start, end in segments:
            a = max(0, int(start * RATE))
            b = min(len(audio), int(end * RATE))
            if b > a:
                out[a:b] = self.denoise(audio[a:b])
        return out


# MARK: - 声のある所を探す（vad=union の Silero VAD）
# Silero VAD（MIT、約0.6MB）を sherpa-onnx の VoiceActivityDetector で動かす。読み込めなければ音の大きさで探す。

VAD_MODEL = "silero_vad.onnx"
VAD_URL = f"{RELEASES}/asr-models/{VAD_MODEL}"
VAD_DIR = HOME / "vad"
VAD_THRESHOLD = 0.5       # これより声らしければ声とみなす
VAD_MIN_SILENCE = 0.3     # これより短い切れ目はつなぐ（EXTRA_GAP と同じ）
VAD_MIN_SPEECH = 0.25     # これより短い声は捨てる（あとで EXTRA_MIN でもう一度ふるう）
VAD_MAX_SPEECH = MAX_SEGMENT


def download_vad() -> Path:
    path = VAD_DIR / VAD_MODEL
    if path.exists() and path.stat().st_size > 100_000:
        return path
    log(f"声のある所を探すモデル（{VAD_MODEL}、約0.6MB）を取ってきます。初回だけです。置き場所: {VAD_DIR}")
    fetch(VAD_URL, path)
    return path


class SileroVad:
    """音声全体から、声のある区間（秒）を探す。"""

    def __init__(self, threads: int) -> None:
        import sherpa_onnx

        path = download_vad()
        self.config = sherpa_onnx.VadModelConfig()
        self.config.silero_vad.model = str(path)
        self.config.silero_vad.threshold = VAD_THRESHOLD
        self.config.silero_vad.min_silence_duration = VAD_MIN_SILENCE
        self.config.silero_vad.min_speech_duration = VAD_MIN_SPEECH
        self.config.silero_vad.max_speech_duration = VAD_MAX_SPEECH
        self.config.sample_rate = RATE
        self.config.num_threads = max(1, min(threads, 2))
        self.config.provider = "cpu"
        if not self.config.validate():
            raise RuntimeError(f"声のある所を探すモデルの設定が正しくありません: {self.config}")
        self.window = int(self.config.silero_vad.window_size) or 512
        self.vad = sherpa_onnx.VoiceActivityDetector(self.config, buffer_size_in_seconds=60)
        self.name = path.stem
        self.lock = threading.Lock()
        log(f"声のある所を探すモデルを読み込みました（{self.name}）")

    def regions(self, audio: np.ndarray) -> list[tuple[float, float]]:
        """声のある区間 [(始まり, 終わり), …]（秒、音声の頭から）"""
        samples = np.ascontiguousarray(audio, dtype=np.float32)
        found: list[tuple[float, float]] = []
        with self.lock:
            self.vad.reset()

            def take() -> None:
                while not self.vad.empty():
                    segment = self.vad.front
                    start = int(segment.start) / RATE
                    found.append((start, start + len(segment.samples) / RATE))
                    self.vad.pop()

            for i in range(0, len(samples) - self.window + 1, self.window):
                self.vad.accept_waveform(samples[i:i + self.window])
                take()
            self.vad.flush()
            take()
            self.vad.reset()
        return sorted(found)


def find_extra(audio: np.ndarray, segments: list[tuple[float, float]], threads: int = 1) -> list[tuple[float, float]]:
    """vad=union の、iPhone が聞き逃した声の区間。Silero VAD で探し、使えなければ音の大きさで探す。"""
    global _vad_failed
    regions = None
    # 読み込めなかったら、しばらくは取ってこようとしない（毎回待たせないため）
    if "vad" in _extras or time.time() - _vad_failed > VAD_RETRY:
        try:
            regions = extra_model("vad", threads).regions(audio)
        except Exception as error:  # noqa: BLE001 — モデルが無くても、音の大きさで探す
            _vad_failed = time.time()
            log(f"Silero VAD を使えませんでした（音の大きさで探します）: {error!r}")
            regions = None
    return extra_speech(audio, segments, regions)


VAD_RETRY = 600.0
_vad_failed = 0.0


# MARK: - あなた向けのモデルの材料（/train-sample・/train-status）
# 直した文と、その声を PC の中だけに貯める。train_personal.py がこれで Whisper を学び直す。

SAMPLE_LIMIT = 5000      # これより多くは貯めない（古いものを勝手に消さない）
SAMPLE_MIN = 0.3         # これより短い声は材料にしない
SAMPLE_MAX = 30.0        # Whisper が一度に聞ける長さまで
SAMPLE_TEXT_MAX = 500
_samples_lock = threading.Lock()


def now_iso(when: float | None = None) -> str:
    """"2026-11-06T18:30:00+09:00" の形の日時"""
    import datetime

    moment = datetime.datetime.fromtimestamp(time.time() if when is None else when)
    return moment.astimezone().isoformat(timespec="seconds")


def read_samples(folder: Path) -> list[dict]:
    """samples.jsonl の中身（読めない行は飛ばす）"""
    rows = []
    try:
        lines = (folder / "samples.jsonl").read_text(encoding="utf-8").splitlines()
    except OSError:
        return rows
    for row in lines:
        try:
            item = json.loads(row)
        except ValueError:
            continue
        if isinstance(item, dict) and item.get("audio") and item.get("text"):
            rows.append(item)
    return rows


SAME_SECONDS = 0.6   # 版 9: PC の「聞いて直す」と iPhone から届いた材料を同じ行とみなす、長さの違い（秒）


def _from_pc(row: dict) -> bool:
    return isinstance(row.get("source"), dict) and row["source"].get("origin") == "pc-review"


def same_line_sample(rows: list[dict], text: str, seconds: float, source: dict | None) -> bool:
    """版 9: 同じ行の材料が、もう片方（PC の「聞いて直す」と iPhone）から入っているか。
    - PC の「聞いて直す」どうし: 同じ日・同じ行の時刻
    - iPhone から届いたものと「聞いて直す」: 文が同じで、長さの違いが SAME_SECONDS 秒まで
      （iPhone は区切りの名前を送ってこないので。iPhone が "audio"・"offset" を送ってきたときは、それも合えば同じ）"""
    mine = isinstance(source, dict) and source.get("origin") == "pc-review"
    for row in rows:
        other = row.get("source") if isinstance(row.get("source"), dict) else {}
        if mine and _from_pc(row):
            if other.get("day") == source.get("day") and other.get("time") == source.get("time"):
                return True
            continue
        if mine == _from_pc(row):
            continue  # iPhone どうしは、今までどおりハッシュで見分ける
        if row.get("text") != text:
            continue
        hint = source if not mine else other
        pc = other if not mine else source
        if hint and hint.get("audio") and hint.get("offset") is not None:
            try:
                near = abs(float(hint["offset"]) - float(pc.get("offset"))) <= 0.5
            except (TypeError, ValueError):
                near = False
            if near and hint["audio"] in (pc.get("audio"), pc.get("line")):
                return True
        try:
            if abs(float(row.get("seconds") or 0) - seconds) <= SAME_SECONDS:
                return True
        except (TypeError, ValueError):
            continue
    return False


def save_sample(folder: Path, audio: np.ndarray, start: float, end: float, text: str,
                source: dict | None = None) -> tuple[int, bool]:
    """audio の start〜end 秒を 16kHz モノラルの wav にし、文と一緒に folder に足す。(材料の数, 足したか) を返す。
    同じ声と文（ハッシュが同じ）は足さない。SAMPLE_LIMIT に達したら足さない。
    版 9: source は出どころ（「聞いて直す」なら {"origin": "pc-review", "day", "time", "audio", "line", "offset"}。
    iPhone からなら None か {"audio", "offset"}）。同じ行の材料が両方から2重に入らないようにする（same_line_sample）。"""
    text = unicodedata.normalize("NFC", text or "").strip()
    if not text:
        raise ValueError("文がありません")
    if len(text) > SAMPLE_TEXT_MAX:
        raise ValueError(f"文が長すぎます（{SAMPLE_TEXT_MAX} 文字まで）")
    if not (np.isfinite(start) and np.isfinite(end)) or end <= start:
        raise ValueError("start と end の秒が正しくありません")
    samples = clip(audio, start, end)
    seconds = len(samples) / RATE
    if seconds < SAMPLE_MIN:
        raise ValueError(f"声が短すぎます（{SAMPLE_MIN} 秒より長くしてください）")
    if seconds > SAMPLE_MAX + 0.01:
        raise ValueError(f"声が長すぎます（{SAMPLE_MAX:.0f} 秒まで）")
    pcm = (np.clip(samples, -1.0, 1.0) * 32767.0).astype("<i2").tobytes()
    digest = hashlib.sha256(text.encode("utf-8") + b"\0" + pcm).hexdigest()
    with _samples_lock:
        rows = read_samples(folder)
        if any(row.get("hash") == digest for row in rows) or len(rows) >= SAMPLE_LIMIT \
                or same_line_sample(rows, text, seconds, source):
            return len(rows), False
        folder.mkdir(parents=True, exist_ok=True)
        name = f"{digest[:24]}.wav"
        part = folder / (name + ".part")
        with wave.open(str(part), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(RATE)
            w.writeframes(pcm)
        part.replace(folder / name)
        row = {"audio": name, "text": text, "seconds": round(seconds, 2), "hash": digest,
               "added": now_iso()}
        if source:
            row["source"] = source
        with (folder / "samples.jsonl").open("a", encoding="utf-8") as f:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
        return len(rows) + 1, True


MIN_SAMPLES = 300   # 版 9: train_personal.py の MIN_SAMPLES と同じ（学び直しに要る材料の数）


def review_sample(path: Path, start: float, end: float, text: str, source: dict) -> tuple[int, bool]:
    """版 9: 「聞いて直す」で答えた行の音声（PC にある区切りの音声）から、材料を作って足す"""
    return save_sample(PERSONAL_DATA, load_audio(Path(path).read_bytes()), start, end, text, source)


def train_status() -> dict:
    """材料の数・あなた向けのモデルがあるか・作った日時（train_personal.py が trained.json に書く）"""
    trained = None
    if personal_model_ready():
        try:
            trained = json.loads((PERSONAL_MODEL / "trained.json").read_text(encoding="utf-8")).get("trained")
        except (OSError, ValueError, AttributeError):
            trained = None
        if not trained:
            trained = now_iso((PERSONAL_MODEL / "model.bin").stat().st_mtime)
    status = {"count": len(read_samples(PERSONAL_DATA)), "model": personal_model_ready(), "trained": trained}
    # 版 7（ops）: 自動の学び直しの様子（次の予定・前回の結果）。版 7 の見守りが動いているときだけ
    auto = ops.train_auto()
    if auto is not None:
        status["auto"] = auto
    return status


_extras: dict[str, object] = {}
_extras_lock = threading.Lock()
EXTRA_KINDS = {"speaker": SpeakerModel, "scene": SceneModel, "enhance": Denoiser, "vad": SileroVad}


def extra_model(kind: str, threads: int):
    """"speaker"・"scene"・"enhance"・"vad" のモデル。初回だけ取ってきて読み込む（失敗したら次に頼まれたときにやり直す）。"""
    with _extras_lock:
        if kind not in _extras:
            _extras[kind] = EXTRA_KINDS[kind](threads)
        return _extras[kind]


def prepare_enhance() -> None:
    """起動したときに、雑音を除くモデルと Silero VAD を裏で用意しておく（/hello の features に出すため）。"""
    try:
        extra_model("enhance", ENHANCE_THREADS)
    except Exception as error:  # noqa: BLE001 — 用意できなくても、ほかはいつもどおり動く
        log(f"雑音を除くモデルを用意できませんでした（enhance=1 は使えません）: {error!r}")
    global _vad_failed
    try:
        extra_model("vad", 1)
    except Exception as error:  # noqa: BLE001 — 用意できなくても、vad=union は音の大きさで探す
        _vad_failed = time.time()
        log(f"Silero VAD を用意できませんでした（vad=union は音の大きさで探します）: {error!r}")
    # この PC の中の Ollama（/llm）があるか、ここで一度確かめておく
    LLM.available(force=True)


def features(engines: list | None = None) -> list[str]:
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
    # vad=union を Silero VAD で探すとき（読み込めていなければ、音の大きさで探す）
    if "vad" in _extras:
        found.append("silero")
    # /train-sample・/train-status（あなた向けのモデルの材料を貯める）
    found.append("train")
    if WORD_TIMES:
        found.append("words")
    # 雑音除去は、読み込めたときだけ（起動したときに裏で用意する）
    if "enhance" in _extras:
        found.append("enhance")
    if any(getattr(e, "name", "") == "mine" for e in engines or []):
        found.append("personal")
    # POST /llm（この PC の中の Ollama が答え、モデルが入っているときだけ）
    if LLM.available():
        found.append("llm")
    # 版 6: POST /jobs（後で受け取る文字起こし）と、意味で探す（Ollama と bge-m3 が使えるときだけ）
    if App.jobs is not None:
        found.append("jobs")
        # 版 8: 待ち合わせ（POST /jobs?wait=1）・時間（timing）・下書き（速いモデルがあり、ほかにも票があるとき）
        found += ["jobwait", "timing"]
        names = [getattr(e, "name", "") for e in engines or getattr(getattr(Handler, "engine", None), "engines", None) or []]
        if any(n in DRAFT_ENGINES for n in names) and any(n not in DRAFT_ENGINES for n in names):
            found.append("draft")
    if App.semantic is not None and App.semantic.available():
        found.append("semantic")
    # 版 7（records）: POST /records/<日>（記録を受ける）・GET /edits と POST /edits/ack（PC で直した分を返す）
    if App.records is not None:
        found += ["records", "edits"]
    # 版 7（ops）: diag（POST /diag）・push（見えない通知を送れるとき）・autotrain（自動の学び直しができるとき）
    found.extend(ops.features())
    return found


# MARK: - 版 6 の部品をまとめておく所

# 起動し直すときに使うタスク スケジューラのタスク（試すときは環境変数 LIFELOG_TASK で、無いタスクの名前にできる）
_TASK = os.environ.get("LIFELOG_TASK", updater.TASK)


class App:
    jobs: jobqueue.JobQueue | None = None
    semantic: semantic.SemanticIndex | None = None
    updater: updater.Updater | None = None
    records: records.RecordStore | None = None   # 版 7（records）
    recent = dashboard.Recent()      # 直近の文字起こしの速さ・モデルの組の近さ（見守りの画面）
    transcribing = 0                 # 今動いている /transcribe の数
    closing = False                  # 入れ替え・再起動の前（新しい /transcribe を断る）
    lock = threading.Lock()
    started = time.time()
    # main() が決める設定
    auto_update = True
    use_semantic = True
    task = _TASK


def busy() -> bool:
    """文字にしている最中のもの（/transcribe・後で受け取る文字起こし）があるか。
    版 7（ops）: 学び直している最中も（自分で入れ替えるのは、学び直しが終わるまで待つ）"""
    return App.transcribing > 0 or (App.jobs is not None and App.jobs.busy()) or ops.busy()


def pause_work() -> None:
    App.closing = True
    if App.jobs is not None:
        App.jobs.pause()
        # 版 8: 待ち合わせで待っている iPhone に pending を返し終わるまで、少しだけ待つ
        App.jobs.wait_waiters(3.0)


def resume_work() -> None:
    App.closing = False
    if App.jobs is not None:
        App.jobs.resume()


def transcribe_reply(engine: Ensemble, audio: np.ndarray, segments: list[tuple[float, float]], hints: list[str],
                     prompt: str | None, weights: dict[str, float], enhance: bool, union: bool, who: str, kind: str,
                     started: float, on_draft=None) -> tuple[dict, dict]:
    """/transcribe と後で受け取る文字起こしの共通の中身。(/transcribe の答え, 数の見立て) を返す。
    who は記録の行の頭（「100.x.x.x から 」など）。文の中身は記録に書かない。
    版 8: on_draft(下書き) を渡すと、速いモデルだけの下書き（答えと同じ形に "draft": true）を先に渡す。"""
    duration = len(audio) / RATE
    def give_draft(lines: list[dict], names: list[str]) -> None:
        took = time.time() - started
        on_draft({"lines": lines, "seconds": round(took, 2), "engines": names, "draft": True})
        log(f"{who}下書き {len(lines)} 行（{'・'.join(names)}）、{took:.1f} 秒")

    draft_hook = give_draft if on_draft is not None else None
    extra: list[tuple[float, float]] = []
    stats: dict = {}
    # vad=union: iPhone が聞き逃した声も PC で探して、一緒に文字にする
    if union:
        try:
            extra = find_extra(audio, segments)
        except Exception as error:  # noqa: BLE001 — 探せなくても、iPhone の区間だけで続ける
            log(f"聞き逃した声を探せませんでした（iPhone の区間だけで続けます）: {error!r}")
            extra = []
    if extra:
        lines = engine.transcribe(audio, segments + extra, hints=hints, prompt=prompt, weights=weights,
                                  extra_from=len(segments), enhance=enhance, stats=stats, on_draft=draft_hook)
    else:
        lines = engine.transcribe(audio, segments, hints=hints, prompt=prompt, weights=weights,
                                  enhance=enhance, stats=stats, on_draft=draft_hook)
    took = time.time() - started
    voiced = sum(b - a for a, b in segments)
    log(f"{who}{duration:.0f} 秒（声 {voiced:.0f} 秒）→ {len(lines)} 行、{took:.1f} 秒")
    if extra:
        found = sum(1 for line in lines if line.get("extra"))
        log(f"  iPhone が聞き逃した声: {len(extra)} 区間（{sum(b - a for a, b in extra):.0f} 秒）→ {found} 行")
    unsure = sum(1 for line in lines if line.get("confidence", 1) < 0.5)
    timed = sum(1 for line in lines if line.get("words"))
    log(f"  多数決: {len(engine.engines)} モデル" + ("（雑音を除いた票も）" if enhance else "")
        + f"、食い違いの大きい行 {unsure}、言葉の時刻のある行 {timed}")
    reply: dict = {"lines": lines, "seconds": round(took, 2), "engines": [e.name for e in engine.engines]}
    if stats:
        # モデルの組ごとの近さと、何も書かなかった区間の数（数だけ。文の中身は記録に書かない）
        log(pair_stats_line(stats))
        reply.update(stats)
    App.recent.record(kind, took, voiced, duration, stats)
    return reply, {"audio_seconds": round(duration, 2), "voiced_seconds": round(voiced, 2), "lines": len(lines)}


def find_voice(audio: np.ndarray, threads: int = 1) -> list[tuple[float, float]]:
    """音声全体の、声のある区間（Silero VAD で探し、使えなければ音の大きさで探す。vad=union と同じ決まり）"""
    return find_extra(audio, [], threads)


def run_job(path: Path, params: dict, name: str, draft=None) -> tuple[dict, dict]:
    """後で受け取る文字起こしの1つ分。区間は PC が探す。答えは /transcribe と同じ形。
    版 8: draft（jobqueue の下書きの口）があれば、速いモデルだけの下書きを先に残す。"""
    started = time.time()
    audio = load_audio(path.read_bytes())
    segments = find_voice(audio)
    enhance = params.get("enhance")
    if enhance is None:
        # enhance を指定しなかったら、iPhone と同じく、騒がしい区切りだけ雑音を除いた票も加える
        enhance = bool(params.get("noisy"))
    return transcribe_reply(Handler.engine, audio, segments, list(params.get("hints") or []), None,
                            parse_weights(params.get("weights")), bool(enhance), False,
                            f"後で受け取る文字起こし {name}: ", "job", started, on_draft=draft)


def dash_info() -> dict:
    """見守りの画面に出すもの（文字起こしの文の中身は入れない）"""
    import shutil

    engine = getattr(Handler, "engine", None)
    engines = [{"name": e.name, "label": getattr(e, "label", e.name), "provider": getattr(e, "provider", "cpu")}
               for e in (engine.engines if engine else [])]
    lines = dashboard.log_tail(LOG)
    try:
        nvidia = has_nvidia_gpu()
    except Exception:  # noqa: BLE001
        nvidia = False
    models, running = [], False
    try:
        tags = LLM.call("/api/tags", timeout=2.0)
        models = [str(m.get("name") or m.get("model") or "") for m in tags.get("models") or []]
        running = True
    except Exception:  # noqa: BLE001 — Ollama が無いだけ
        pass
    index = App.semantic
    if index is None or not index.enabled:
        state = "使わない設定です"
    elif index.pulling:
        state = "モデルを取ってきてもらっています"
    elif index.available():
        state = "使えます"
    else:
        state = index.error or "使えません（Ollama が動いていないか、モデルがありません）"
    disk_path = MODEL_DIR if MODEL_DIR.exists() else HOME
    try:
        free = shutil.disk_usage(disk_path).free
    except OSError:
        free = None
    return {"version": VERSION, "build": BUILD, "frozen": bool(getattr(sys, "frozen", False)),
            "uptime": time.time() - App.started, "disk_free": free, "disk_path": str(disk_path),
            "engines": engines,
            "gpu": {"nvidia": nvidia, "used": any(e["provider"] == "cuda" for e in engines),
                    "last_error": dashboard.last_cuda_error(lines)},
            "ollama": {"running": running, "models": models, "llm": LLM.available(), "llm_model": LLM.model,
                       "semantic_model": semantic.EMBED_MODEL, "semantic_state": state,
                       "semantic_count": index.status()["count"] if index is not None and index.enabled else 0},
            "job_counts": App.jobs.counts() if App.jobs else {}, "jobs": App.jobs.recent(20) if App.jobs else [],
            # 版 8: 直近のでき上がった仕事の、PC の待ち・作業の時間
            "job_latency": App.jobs.latency() if App.jobs else None,
            "speed": App.recent.speed("transcribe", 20), "pairs": App.recent.pairs(),
            "update": App.updater.status() if App.updater else {"auto": App.auto_update, "state": "—"},
            "problems": dashboard.problems(lines, 15),
            # 版 9: 学び直しの材料の数（見守りの画面の「学び直し」と「聞いて直す」への入口）
            "personal": personal_info(),
            # 版 7（ops）: 実機の様子・見えない通知・TestFlight の報告・学び直しと GPU の時間割（動いていなければ空）
            "ops": ops.dash_info()}


def personal_info() -> dict:
    """版 9: 材料の数と、学び直しに要る数（自動の学び直しの設定があれば、その数）"""
    need = MIN_SAMPLES
    auto = ops.train_auto()
    if isinstance(auto, dict) and isinstance(auto.get("min_samples"), int):
        need = auto["min_samples"]
    try:
        count = len(read_samples(PERSONAL_DATA))
    except Exception:  # noqa: BLE001
        count = 0
    return {"count": count, "need": need, "records": App.records is not None}


def start_v6(threads: int) -> None:
    """版 6 の裏の仕事を始める（後で受け取る文字起こし・意味で探す・自分で入れ替える）。どれも失敗しても受け付けは続ける。"""
    try:
        # 版 7（records）: 記録の機能があれば、iPhone が消した区切りの音声を消さずに移す
        App.jobs = jobqueue.JobQueue(JOBS_DIR, run_job, log,
                                     keep_audio=App.records.keep_audio if App.records is not None else None)
        App.jobs.start()
        counts = App.jobs.counts()
        if counts["queued"]:
            log(f"後で受け取る文字起こし: 待っているものが {counts['queued']} 個あります。続きから文字にします")
    except Exception as error:  # noqa: BLE001
        App.jobs = None
        log(f"後で受け取る文字起こしを始められませんでした: {error!r}")
    if App.use_semantic:
        try:
            App.semantic = semantic.SemanticIndex(SEMANTIC_DB, semantic.OllamaEmbedder(LLM.url), log)
            threading.Thread(target=App.semantic.available, kwargs={"force": True}, daemon=True).start()
        except Exception as error:  # noqa: BLE001
            App.semantic = None
            log(f"意味で探す機能を始められませんでした: {error!r}")
    try:
        # 試すときだけ、環境変数 LIFELOG_UPDATE_API で問い合わせ先を作り物にできる（ふだんは GitHub）
        App.updater = updater.Updater(HOME, BUILD, bool(getattr(sys, "frozen", False)), INSTALL_DIR, App.auto_update,
                                      busy, pause_work, resume_work, log, task=App.task,
                                      api=os.environ.get("LIFELOG_UPDATE_API") or updater.API)
        App.updater.start()
    except Exception as error:  # noqa: BLE001
        App.updater = None
        log(f"自分で入れ替える仕組みを始められませんでした: {error!r}")


# 版 7（records）: 記録の置き場所（HOME/records・HOME/audio・HOME/edits.db）。start_v6 より前に始める
def start_records() -> None:
    try:
        App.records = records.RecordStore(HOME, log, load_config)
        App.records.sampler = review_sample   # 版 9: 「聞いて直す」で材料を作る
        App.records.start()
    except Exception as error:  # noqa: BLE001 — 始められなくても、ほかの受け付けは続ける
        App.records = None
        log(f"記録の機能を始められませんでした: {error!r}")


def restart_later() -> None:
    """見守りの画面の「再起動」。文字にしている最中のものを（60 秒まで）待ってから、終わって起動し直す。"""
    def run() -> None:
        pause_work()
        deadline = time.time() + 60
        while busy() and time.time() < deadline:
            time.sleep(1)
        try:
            updater.restart(HOME, App.task, log)
        except Exception as error:  # noqa: BLE001
            log(f"再起動できませんでした: {error!r}")
            resume_work()

    threading.Thread(target=run, name="restart", daemon=True).start()


# MARK: - この PC の中の言語モデル（POST /llm、Ollama に取り次ぐ）
# iPhone の「仕事の文脈」の文を、この PC の中で動く Ollama に作ってもらう。この PC の外には送らない。

OLLAMA_URL = "http://127.0.0.1:11434"
# 日本語の読み書きができる 8B のモデル（Ollama の qwen3:8b、約5.2GB、Apache-2.0）。--llm-model で変えられる
LLM_MODEL = "qwen3:8b"
LLM_BODY_LIMIT = 1_000_000   # /llm に送ってよい大きさ（1MB まで）
LLM_PROMPT_MAX = 200_000     # 頼む文の長さの上限（文字）
LLM_DEFAULT_TOKENS = 1024
LLM_MAX_TOKENS = 8192
LLM_TIMEOUT = 600.0          # CPU で動かすと遅いので長めに待つ
LLM_CHECK_EVERY = 60.0       # Ollama があるかを確かめ直す間（秒）
# 合言葉が違うときなどに読み捨てる中身の上限。これより大きいものは読まずに接続を閉じる
DRAIN_LIMIT = 200_000_000
DRAIN_TIMEOUT = 30.0


def is_local_url(url: str) -> bool:
    """この PC の中（127.0.0.1・localhost・::1）を指す http の宛先か"""
    parsed = urlparse(url)
    return parsed.scheme == "http" and (parsed.hostname or "") in ("127.0.0.1", "localhost", "::1")


def parse_llm_request(data: bytes) -> dict:
    """/llm の中身 {"prompt": "…", "json": true|false, "max_tokens": N} を読む。おかしければ ValueError。"""
    try:
        body = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as error:
        raise ValueError("中身が JSON ではありません") from error
    if not isinstance(body, dict):
        raise ValueError("中身が JSON ではありません")
    prompt = body.get("prompt")
    if not isinstance(prompt, str) or not prompt.strip():
        raise ValueError("prompt がありません")
    if len(prompt) > LLM_PROMPT_MAX:
        raise ValueError(f"prompt が長すぎます（{LLM_PROMPT_MAX} 文字まで）")
    as_json = body.get("json", False)
    if not isinstance(as_json, bool):
        raise ValueError("json は true か false です")
    tokens = body.get("max_tokens", LLM_DEFAULT_TOKENS)
    if isinstance(tokens, bool) or not isinstance(tokens, (int, float)):
        raise ValueError("max_tokens は数です")
    return {"prompt": prompt, "json": as_json, "max_tokens": int(min(LLM_MAX_TOKENS, max(1, tokens)))}


def ollama_chat_body(model: str, prompt: str, as_json: bool, max_tokens: int, think: bool = True) -> dict:
    """Ollama の /api/chat に送る中身。考える過程（thinking）は書かせない。json なら "format": "json"。"""
    body: dict = {"model": model, "messages": [{"role": "user", "content": prompt}], "stream": False,
                  "options": {"num_predict": max_tokens}}
    if think:
        body["think"] = False
    if as_json:
        body["format"] = "json"
    return body


def strip_think(text: str) -> str:
    """答えの頭に付くことのある <think>…</think>（考える過程）を除く"""
    return re.sub(r"^\s*<think>.*?</think>\s*", "", text or "", flags=re.S).strip()


def model_listed(names: list[str], wanted: str) -> bool:
    """Ollama に入っているモデルの名前の一覧に、wanted があるか（"qwen3" は "qwen3:latest" と同じ）"""
    def plain(name: str) -> str:
        return name if ":" in name else name + ":latest"

    return plain(wanted) in {plain(n) for n in names}


class LocalLLM:
    """この PC の中の Ollama に取り次ぐ。宛先はこの PC の中だけ（それ以外は受け付けない）。"""

    def __init__(self, url: str = OLLAMA_URL, model: str = LLM_MODEL, enabled: bool = True) -> None:
        if not is_local_url(url):
            raise ValueError(f"Ollama の宛先はこの PC の中（http://127.0.0.1:…）にしてください: {url}")
        import urllib.request

        self.url = url.rstrip("/")
        self.model = model
        self.enabled = enabled
        # プロキシの設定があっても使わない（この PC の中にだけつなぐ）
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        self.ok = False
        self.checked = 0.0
        self.warned = False
        self.lock = threading.Lock()
        self.supports_think = True

    def call(self, path: str, body: dict | None = None, timeout: float = 5.0) -> dict:
        import urllib.request

        data = None if body is None else json.dumps(body, ensure_ascii=False).encode("utf-8")
        request = urllib.request.Request(self.url + path, data=data, method="GET" if body is None else "POST",
                                         headers={"Content-Type": "application/json"})
        with self.opener.open(request, timeout=timeout) as response:
            return json.loads(response.read() or b"{}")

    def available(self, force: bool = False) -> bool:
        """Ollama が答え、モデルが入っているか。force でなければ前に確かめた答えをすぐ返し、
        LLM_CHECK_EVERY 秒より古ければ裏で確かめ直す（/hello を待たせないため）。"""
        if not self.enabled:
            return False
        if not force:
            if time.time() - self.checked >= LLM_CHECK_EVERY and not self.lock.locked():
                threading.Thread(target=self.available, kwargs={"force": True}, daemon=True).start()
            return self.ok
        with self.lock:
            return self.check()

    def check(self) -> bool:
        """Ollama に、入っているモデルの一覧を聞く（self.lock を持って呼ぶ）"""
        before = self.ok
        try:
            tags = self.call("/api/tags", timeout=2.0)
            names = [str(m.get("name") or m.get("model") or "") for m in tags.get("models") or []]
            self.ok = model_listed(names, self.model)
            if not self.ok and not self.warned:
                # Ollama はあるのにモデルが無いときだけ、一度言う（Ollama が無いのは普通なので黙っている）
                self.warned = True
                log(f"Ollama に {self.model} が入っていません（/llm は使えません。ollama pull {self.model} で入れます）")
        except Exception:  # noqa: BLE001 — Ollama が無ければ使わないだけ
            self.ok = False
        self.checked = time.time()
        if self.ok and not before:
            log(f"この PC の言語モデルを使えます（Ollama の {self.model}）")
        return self.ok

    def generate(self, prompt: str, as_json: bool, max_tokens: int) -> str:
        """頼んだ文への答え。Ollama が無い・モデルが無いときは RuntimeError。"""
        if not self.enabled:
            raise RuntimeError("この PC の言語モデルは使わない設定です")
        if not self.available(force=time.time() - self.checked >= LLM_CHECK_EVERY):
            raise RuntimeError(f"Ollama が動いていないか、{self.model} が入っていません")
        import urllib.error

        try:
            answer = self.call("/api/chat", ollama_chat_body(self.model, prompt, as_json, max_tokens,
                                                             self.supports_think), timeout=LLM_TIMEOUT)
        except urllib.error.HTTPError as error:
            # 古い Ollama・考える過程を持たないモデルが "think" を断ったときは、付けずにもう一度
            if error.code != 400 or not self.supports_think:
                raise
            self.supports_think = False
            answer = self.call("/api/chat", ollama_chat_body(self.model, prompt, as_json, max_tokens, False),
                               timeout=LLM_TIMEOUT)
        except OSError:
            self.ok = False
            self.checked = time.time()
            raise
        if answer.get("error"):
            raise RuntimeError(str(answer["error"]))
        return strip_think(str((answer.get("message") or {}).get("content") or answer.get("response") or ""))


LLM = LocalLLM(enabled=False)


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
        if status >= 400:
            self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def authorized(self) -> bool:
        given = self.headers.get("Authorization", "").removeprefix("Bearer ").strip()
        if secrets.compare_digest(given, self.key):
            ops.seen(self)  # 版 7（ops）: iPhone から最後に来た時刻と、仕事が来たこと（通知の見回り・GPU の時間割）
            return True
        log(f"合言葉の違う接続を断りました: {self.client_address[0]}")
        # 送られてくる音声を読み捨ててから断る。読まずに断ると、iPhone には 401 ではなく「接続が切れた」と見える
        self.discard_body()
        self.send_json(401, {"error": "合言葉が違います"})
        return False

    def discard_body(self) -> None:
        """送られてきた中身を読み捨てる（DRAIN_LIMIT まで）。読み切れないもの・長さの分からないものは、答えたあと接続を閉じる。"""
        self.close_connection = True
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return
        if length <= 0 or length > DRAIN_LIMIT:
            return
        try:
            self.connection.settimeout(DRAIN_TIMEOUT)
            while length > 0:
                chunk = self.rfile.read(min(length, 1 << 20))
                if not chunk:
                    break
                length -= len(chunk)
        except OSError:
            pass

    def do_GET(self) -> None:
        url = urlparse(self.path)
        path = url.path
        if path == "/dash":
            self.dash(url, "GET")
            return
        # 版 7（records）: 記録の画面・保存した音声（合言葉は見守りの画面と同じ）と、GET /edits（Bearer）
        if recordsui.handles(path):
            recordsui.http(self, url, "GET", App.records, App.semantic, log, personal_info)
            return
        if path == "/edits":
            records.http_get_edits(self, App.records, url.query, log)
            return
        if path.startswith("/dash/ops/"):  # 版 7（ops）: TestFlight の報告の詳しい画面・鍵を入れる画面
            ops.dash_get(self, url)
            return
        if path not in ("/hello", "/train-status", "/jobs", "/index/status") and not path.startswith("/jobs/"):
            self.send_json(404, {"error": "not found"})
            return
        if not self.authorized():
            return
        if path == "/jobs" or path.startswith("/jobs/"):
            jobqueue.http_get(self, App.jobs, path)
            return
        if path == "/index/status":
            semantic.http_status(self, App.semantic)
            return
        if path == "/train-status":
            try:
                self.send_json(200, train_status())
            except Exception as error:  # noqa: BLE001
                log(f"材料の数を数えられませんでした: {error!r}")
                self.send_json(500, {"error": f"材料の数を数えられませんでした: {error}"})
            return
        self.send_json(200, {"app": "LifeLogPC", "version": VERSION, "build": BUILD, "model": self.engine.label,
                             "provider": self.engine.provider,
                             "engines": [e.name for e in self.engine.engines],
                             # 話し手のモデルのファイルの名前。変わったら、iPhone は登録した声を測り直す
                             "speaker_model": SPEAKER_MODEL,
                             "features": features(self.engine.engines)})

    def llm(self, data: bytes) -> None:
        """POST /llm  {"prompt": "…", "json": true|false, "max_tokens": N} → {"text": "…"}。
        この PC の中で動く Ollama にだけ取り次ぐ（ほかの所には送らない）。"""
        try:
            request = parse_llm_request(data)
        except ValueError as error:
            self.send_json(400, {"error": str(error)})
            return
        started = time.time()
        try:
            text = LLM.generate(request["prompt"], request["json"], request["max_tokens"])
        except Exception as error:  # noqa: BLE001 — 何があっても受け付けは続ける
            log(f"言語モデルで答えを作れませんでした: {error!r}")
            self.send_json(503, {"error": f"言語モデルで答えを作れませんでした: {error}"})
            return
        # 頼まれた文と答えの中身は記録に書かない
        log(f"{self.client_address[0]} から /llm: {len(request['prompt'])} 文字 → {len(text)} 文字、"
            f"{time.time() - started:.1f} 秒（{LLM.model}）")
        self.send_json(200, {"text": text})

    def do_POST(self) -> None:
        url = urlparse(self.path)
        if url.path in ("/dash/restart", "/dash/update"):
            self.dash(url, "POST")
            return
        # 版 7（records）: 記録の画面のボタン（合言葉は見守りの画面と同じ）と、POST /records/<日>・/edits/ack（Bearer）
        if recordsui.handles(url.path):
            recordsui.http(self, url, "POST", App.records, App.semantic, log)
            return
        if url.path.startswith("/records/") or url.path == "/edits/ack":
            records.http_post(self, App.records, url.path, log)
            return
        if url.path.startswith("/dash/ops/"):  # 版 7（ops）: 見守りの画面のボタン（鍵を入れる・テスト通知など）
            ops.dash_post(self, url)
            return
        if url.path not in ("/transcribe", "/speakers", "/scene", "/train-sample", "/llm", "/jobs") \
                and url.path not in semantic.POSTS and url.path not in ops.POSTS:  # 版 7（ops）: /diag
            self.discard_body()
            self.send_json(404, {"error": "not found"})
            return
        if not self.authorized():
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if url.path == "/jobs":
            # 音声は読みながらファイルに書く（200MB まで）
            jobqueue.http_post(self, App.jobs, url.query, length)
            return
        if url.path in ops.POSTS:  # 版 7（ops）: POST /diag（実機の様子。2MB まで）
            ops.http_diag(self, length)
            return
        small = url.path == "/llm" or url.path in semantic.POSTS
        limit = LLM_BODY_LIMIT if url.path == "/llm" else semantic.BODY_LIMIT if small else DRAIN_LIMIT
        if length <= 0 or length > limit:
            self.discard_body()
            if small:
                self.send_json(400 if length <= 0 else 413, {"error": "中身がありません" if length <= 0 else "長すぎます"})
            else:
                self.send_json(400, {"error": "音声がありません"})  # 前の版と同じ答え
            return
        data = self.rfile.read(length)
        if url.path in semantic.POSTS:
            semantic.http_post(self, App.semantic, url.path, data, log)
        elif url.path == "/llm":
            self.llm(data)
        elif url.path == "/transcribe":
            self.transcribe(data, url.query)
        elif url.path == "/train-sample":
            self.train_sample(data, url.query)
        else:
            self.extras(url.path, data, url.query)

    def train_sample(self, data: bytes, query_text: str) -> None:
        """直した文とその声を、あなた向けのモデルの材料として PC に保存する（外には送らない）。"""
        query = parse_qs(query_text)
        try:
            start = float((query.get("start") or [""])[0])
            end = float((query.get("end") or [""])[0])
        except ValueError:
            self.send_json(400, {"error": "start と end（秒）が要ります"})
            return
        text = (query.get("text") or [""])[0]
        # 版 9: 省ける "audio"（Line.audio）・"offset"（行の位置の秒）。PC の「聞いて直す」と同じ行かを見分けるのに使う
        source = None
        hint = (query.get("audio") or [""])[0]
        try:
            offset = float((query.get("offset") or [""])[0])
        except ValueError:
            offset = None
        if hint and offset is not None and np.isfinite(offset):
            source = {"audio": hint[:200], "offset": round(offset, 2)}
        try:
            audio = load_audio(data)
            count, added = save_sample(PERSONAL_DATA, audio, start, end, text, source)
        except ValueError as error:
            self.send_json(400, {"error": str(error)})
            return
        except Exception as error:  # noqa: BLE001 — 何があっても受け付けは続ける
            log(f"材料を保存できませんでした: {error!r}")
            self.send_json(500, {"error": f"材料を保存できませんでした: {error}"})
            return
        # 文の中身は記録に書かない
        log(f"{self.client_address[0]} から材料: {end - start:.1f} 秒、" + ("足しました" if added else "足しませんでした")
            + f"（全部で {count}）")
        self.send_json(200, {"count": count, "added": added})

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

    def do_DELETE(self) -> None:
        path = urlparse(self.path).path
        if not path.startswith("/jobs/"):
            self.discard_body()
            self.send_json(404, {"error": "not found"})
            return
        if not self.authorized():
            return
        jobqueue.http_delete(self, App.jobs, path)

    def dash(self, url, method: str) -> None:
        """見守りの画面（GET /dash）と、そのボタン（POST /dash/restart・/dash/update）。合言葉は Basic 認証かクッキー。"""
        ok, set_cookie = dashboard.check(self.headers, url.query, self.key)
        if not ok:
            if self.headers.get("Authorization") or "key=" in url.query:
                log(f"見守りの画面で合言葉の違う接続を断りました: {self.client_address[0]}")
            self.discard_body()
            dashboard.send(self, 401, dashboard.login_page(),
                           extra={"WWW-Authenticate": 'Basic realm="LifeLog PC", charset="UTF-8"'})
            return
        if method == "GET":
            if set_cookie:
                # 合言葉の入った宛先を残さないよう、クッキーを渡して /dash に移る
                dashboard.send(self, 303, "", extra={"Location": "/dash", "Set-Cookie": dashboard.cookie_header(self.key)})
                return
            try:
                page = dashboard.render(dash_info())
            except Exception as error:  # noqa: BLE001 — 画面が作れなくても受け付けは続ける
                log(f"見守りの画面を作れませんでした: {error!r}")
                dashboard.send_json(self, 500, {"error": f"見守りの画面を作れませんでした: {error}"})
                return
            dashboard.send(self, 200, page)
            return
        self.discard_body()
        # ほかのサイトから押させられないよう、画面の中のボタンだけが付ける印を確かめる
        if self.headers.get(dashboard.HEADER) != "1":
            dashboard.send_json(self, 403, {"error": "この画面のボタンから押してください"})
            return
        if url.path == "/dash/restart":
            restart_later()
            dashboard.send_json(self, 200, {"message": "起動し直します。1〜2分たってから、この画面を開き直してください。"})
        elif App.updater is None:
            dashboard.send_json(self, 503, {"error": "自分で入れ替える仕組みが動いていません"})
        elif App.updater.trigger():
            dashboard.send_json(self, 200, {"message": "新しい版があるか確かめています。あれば入れ替えて起動し直します"
                                                       "（数分かかります。この画面の「更新」で様子が分かります）。"})
        else:
            dashboard.send_json(self, 200, {"message": "いま確かめている最中です。少し待ってから画面を開き直してください。"})

    def transcribe(self, data: bytes, query_text: str) -> None:
        if App.closing:
            self.send_json(503, {"error": "PC を起動し直すところです。少し待ってから送ってください"})
            return
        started = time.time()
        with App.lock:
            App.transcribing += 1
        try:
            try:
                audio = load_audio(data)
                duration = len(audio) / RATE
                query = parse_qs(query_text)
                segments = parse_segments((query.get("segments") or [None])[0], duration)
                # 聞き取ってほしい言葉（改行区切り）と、前の区切りの終わりの文。Whisper のヒントにする
                hints = [w.strip() for w in (query.get("hints") or [""])[0].split("\n") if w.strip()][:80]
                prompt = (query.get("prompt") or [None])[0]
                weights = parse_weights((query.get("weights") or [None])[0])
                # enhance=1: 雑音を除いた音でも Haas-ja・ReazonSpeech にもう一度聞いてもらい、票を増やす
                enhance = (query.get("enhance") or [""])[0] in ("1", "true", "yes")
                # vad=union: iPhone が聞き逃した声も PC で探して、一緒に文字にする
                union = (query.get("vad") or [""])[0] == "union"
                reply, _ = transcribe_reply(self.engine, audio, segments, hints, prompt, weights, enhance, union,
                                            f"{self.client_address[0]} から ", "transcribe", started)
            except Exception as error:  # noqa: BLE001 — 何があっても受け付けは続ける
                log(f"文字にできませんでした: {error!r}")
                self.send_json(500, {"error": str(error)})
                return
            self.send_json(200, reply)
        finally:
            with App.lock:
                App.transcribing -= 1


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


def home_addresses() -> list[str]:
    """時計に入れる、家の中の住所の候補（10.・172.16〜31.・192.168. の番号。2026-11-07）"""
    import ipaddress

    ranges = [ipaddress.IPv4Network(n) for n in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")]
    out = []
    for ip in addresses():
        try:
            value = ipaddress.IPv4Address(ip)
        except ValueError:
            continue
        if any(value in r for r in ranges):
            out.append(ip)
    return out


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
    # 雑音を除くモデル（約0.5MB）は裏で用意する。用意できなくても受け付けは始める
    threading.Thread(target=prepare_enhance, daemon=True).start()
    # 版 7（records）: 記録の置き場所（後で受け取る文字起こしが音声を移す先なので、先に始める）
    start_records()
    # 版 6: 後で受け取る文字起こし・意味で探す・自分で入れ替える
    start_v6(threads)
    # 版 7（ops）: 実機の様子・見えない通知・TestFlight の報告・学び直しと GPU の時間割。失敗しても受け付けは始める
    try:
        ops.start(sys.modules[__name__])
    except Exception as error:  # noqa: BLE001
        log(f"版 7 の見守りを始められませんでした: {error!r}")
    log(f"LifeLog PC 版 {VERSION}（番号 {BUILD}）を始めます")
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
    print(f" 見守りの画面: http://{name or 'この PC の名前'}:{port}/dash（パスワードの欄に合言葉）")
    print()
    print(" （iPhone のアプリは、番号の宛先 " + ", ".join(addresses()) + " には送れません。上の名前を使います）")
    # 時計から家の PC に直接送るときの、家の中の住所（2026-11-07。時計には Tailscale が無い）
    home = home_addresses()
    if home:
        print(" 時計から直接送るとき（iPhone の 家の PC →「時計から直接」）は、家の中の住所 " + " か ".join(home) + " を入れます")
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


def test(path: str, engine: Ensemble, segments: str | None, hints: list[str], enhance: bool = False) -> None:
    audio = load_audio(Path(path).read_bytes())
    duration = len(audio) / RATE
    started = time.time()
    lines = engine.transcribe(audio, parse_segments(segments, duration), hints=hints, votes=True, enhance=enhance)
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
        words = line.get("words")
        if words:
            print(f"    言葉の時刻（{len(words)} 個）: " + " ".join(f"{w[2]}[{w[0]:.2f}-{w[1]:.2f}]" for w in words[:12])
                  + (" …" if len(words) > 12 else ""))
        else:
            print("    言葉の時刻: （なし）")
    print(f"音声 {duration:.1f} 秒を {took:.1f} 秒で文字にしました（実時間の {took / max(duration, 0.01):.3f} 倍）")
    if not lines:
        sys.exit(1)


def check_vote() -> None:
    """多数決の決まりを確かめる（モデル無しで動く。CI で使う）。"""
    isolate_home()  # 版 8: 本物の HOME の log.txt やデータに書かない
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
    # 雑音を除いた票（haas_e・reazon_e）も、ほかの票と同じように数える
    enhanced = vote({"haas": "明日の予算", "reazon": "あしたの洋服", "haas_e": "明日の予算", "reazon_e": "明日の予算"},
                    parse_weights("haas_e:1.5,reazon_e:0.8"))
    ok = bool(enhanced) and enhanced["text"] == "明日の予算" and enhanced["engine"] in ("haas", "haas_e", "reazon_e") \
        and parse_weights("haas_e:1.5,reazon_e:0.8") == {"haas_e": 1.5, "reazon_e": 0.8}
    print(("OK " if ok else "NG ") + json.dumps({"enhanced": enhanced}, ensure_ascii=False))
    failed += 0 if ok else 1
    # 言いよどみ・数字の書き方の違いは食い違いに数えない（版 5）
    failed += check_fillers()
    # モデルの組ごとの近さ・何も書かなかった数（食い違いの多さの見立て）
    failed += check_pairs()
    # 聞き逃した声の探し方（vad=union）もモデル無しで確かめられる
    failed += check_extra_speech()
    # 言葉ごとの時刻と、あなた向けのモデルの材料の保存もモデル無しで確かめる
    failed += check_words()
    failed += check_train_sample()
    # /llm（Ollama への取り次ぎ）を、作り物の Ollama で確かめる
    failed += check_llm()
    # 版 6: 後で受け取る文字起こし・見守りの画面・自分で入れ替える・意味で探す（作り物のモデルと Ollama で）
    import v6checks

    failed += v6checks.run(sys.modules[__name__])
    if failed:
        sys.exit(1)


def check_fillers() -> int:
    """言いよどみを除く・数字をそろえる決まりを確かめる（モデル無し）。NG の数を返す。"""
    failed = 0
    cases = [
        ("えーと、明日の会議は三時です", "明日の会議は三時です"),
        ("えーっと明日", "明日"),
        ("えっと、あのー、来週の件ですが", "来週の件ですが"),
        ("明日のえーと会議", "明日の会議"),
        ("うーん、まあ、いいと思います", "いいと思います"),
        ("んーと、それは", "それは"),
        ("えー、本日は", "本日は"),
        ("そのー、つまり", "つまり"),
        ("あー、そうか", "そうか"),
        # 中身のある言葉は除かない（あの人・その件・まあまあ・あーいう・うん・ううん・ええ・えとう）
        ("あの人が来た", "あの人が来た"),
        ("その件は", "その件は"),
        ("まあまあです", "まあまあです"),
        ("あーいうのは", "あーいうのは"),
        ("うん、そうだね", "うん、そうだね"),
        ("ううん、違う", "ううん、違う"),
        ("ええ、そうです", "ええ、そうです"),
        ("えとうさんが来た", "えとうさんが来た"),
    ]
    for text, want in cases:
        got = strip_fillers(text)
        ok = got == want
        print(("OK " if ok else "NG ") + f"言いよどみを除く: {text} → {got}")
        failed += 0 if ok else 1
    numbers = {"3": "三", "10": "十", "15": "十五", "300": "三百", "1000": "千", "2026": "二千二十六",
               "12000": "一万二千", "100000000": "一億", "0": "零", "090": "零九零"}
    got_numbers = {k: kanji_number(k) for k in numbers}
    ok = got_numbers == numbers and kanji_numbers("1,000円と3.5キロ") == "千円と三点五キロ"
    print(("OK " if ok else "NG ") + f"数字を漢数字に: {got_numbers}、{kanji_numbers('1,000円と3.5キロ')}")
    failed += 0 if ok else 1
    # 言いよどみ・数字の違いだけなら、ほぼ同じとみなす。言いよどみしか無い文は、除かずに比べる
    same = [("えーと、明日の会議は三時です", "明日の会議は3時です"), ("あのー、来週の資料ですが", "来週の資料ですが"),
            ("えっと1人で行きます", "一人で行きます"), ("えーと", "えーと")]
    # 本当に違う文は、言いよどみを除いても違うまま
    different = [("明日の予算の話", "あしたの洋服の話"), ("えーと、明日の予算の話", "あしたの洋服の話"),
                 ("今日は晴れ", "今日は雨"), ("三時に行く", "四時に行く"), ("えーと", "あのー")]
    sims = {f"{a}／{b}": round(similarity(a, b), 2) for a, b in same + different}
    ok = all(similarity(a, b) >= 0.95 for a, b in same) \
        and all(similarity(a, b) < SURFACE_SIMILAR for a, b in different)
    print(("OK " if ok else "NG ") + "近さ: " + json.dumps(sims, ensure_ascii=False))
    failed += 0 if ok else 1
    # 多数決：言いよどみの有り無しだけが違う 4 つのモデルは、確からしさが高くなる（版 4 では 0.5 より低かった）
    picked = vote({"haas": "えーと、明日の会議は三時です", "reazon": "明日の会議は3時です",
                   "whisper": "明日の会議は三時です", "kotoba": "あのー、明日の会議は三時です"})
    ok = bool(picked) and picked["confidence"] >= 0.9 and not picked["alternatives"] \
        and picked["text"] in ("明日の会議は三時です", "えーと、明日の会議は三時です")
    print(("OK " if ok else "NG ") + "言いよどみだけ違う多数決: " + json.dumps(picked, ensure_ascii=False))
    failed += 0 if ok else 1
    return failed


def check_pairs() -> int:
    """モデルの組ごとの近さ（pair_stats）を確かめる（モデル無し）。NG の数を返す。"""
    failed = 0
    rows = [
        # vote() が測った近さがあれば、それを使う（ここでは、わざと 0.5 を渡して測り直していないことを見る）
        ({"whisper": "今日は会議です", "haas": "今日は会議です", "reazon": "今日は会議です"},
         {("haas", "reazon"): 0.5, ("reazon", "haas"): 0.5}),
        # 言いよどみだけ違えば 1。whisper は何も書かなかった
        ({"haas": "えーと、明日の会議は三時です", "reazon": "明日の会議は3時です", "whisper": ""}, None),
        # 誰も書かなかった区間は数えない
        ({"haas": "", "reazon": "", "whisper": ""}, None),
        # whisper だけが書いた（haas・reazon が何も書かなかった）
        ({"haas": "", "reazon": "", "whisper": "ご視聴ありがとうございました"}, None),
    ]
    got = pair_stats(rows)
    want = {"pairs": {"haas-reazon": 0.75, "haas-whisper": 1.0, "reazon-whisper": 1.0},
            "pair_lines": {"haas-reazon": 2, "haas-whisper": 1, "reazon-whisper": 1},
            "silent": {"haas": 1, "reazon": 1, "whisper": 1}, "heard_lines": 3}
    line = pair_stats_line(got)
    ok = got == want and "えーと" not in line and "会議" not in line and "haas-reazon 0.75" in line \
        and pair_stats([]) == {"pairs": {}, "pair_lines": {}, "silent": {}, "heard_lines": 0}
    print(("OK " if ok else "NG ") + f"モデルの組の近さ: {json.dumps(got, ensure_ascii=False)}／記録: {line.strip()}")
    failed += 0 if ok else 1

    # 多数決と一緒に測る：vote() が測った近さをそのまま使い、transcribe の stats に入る
    class Fake:
        provider = "cpu"

        def __init__(self, name: str, texts: list[str]) -> None:
            self.name = self.label = name
            self.texts = texts

        def run(self, audio, segments, hints, prompt):
            return self.texts[:len(segments)]

    ensemble = Ensemble([Fake("haas", ["今日は会議です", "明日の予算の話"]),
                         Fake("reazon", ["今日は会議です", "あしたの洋服の話"]),
                         Fake("whisper", ["", "飛鳥の羊羹の話"])])
    stats: dict = {}
    lines = ensemble.transcribe(np.zeros(4 * RATE, dtype=np.float32), [(0.0, 2.0), (2.0, 4.0)], stats=stats)
    ensemble.pool.shutdown(wait=False)
    sims = {}
    vote({"haas": "明日の予算の話", "reazon": "あしたの洋服の話", "whisper": "飛鳥の羊羹の話"}, None, sims)
    ok = len(lines) == 2 and stats["silent"] == {"whisper": 1} and stats["heard_lines"] == 2 \
        and stats["pair_lines"] == {"haas-reazon": 2, "haas-whisper": 1, "reazon-whisper": 1} \
        and stats["pairs"]["haas-reazon"] == round((1.0 + sims[("haas", "reazon")]) / 2, 2) \
        and stats["pairs"]["haas-whisper"] == round(sims[("haas", "whisper")], 2)
    print(("OK " if ok else "NG ") + f"多数決と一緒に測った組の近さ: {json.dumps(stats, ensure_ascii=False)}")
    failed += 0 if ok else 1
    return failed


def check_llm() -> int:
    """/llm を、作り物の Ollama（この PC の中、空いた番号）で確かめる（本物の Ollama は使わない）。NG の数を返す。"""
    import http.client

    global LLM
    failed = 0
    # 中身の読み方
    good = parse_llm_request(json.dumps({"prompt": "こんにちは", "json": True, "max_tokens": 99999}).encode())
    bad = []
    for raw in (b"not json", b"[]", json.dumps({"prompt": ""}).encode(), json.dumps({"prompt": "a", "json": "yes"}).encode(),
                json.dumps({"prompt": "a", "max_tokens": "x"}).encode()):
        try:
            parse_llm_request(raw)
            bad.append(False)
        except ValueError:
            bad.append(True)
    body = ollama_chat_body("m", "p", True, 10)
    ok = good == {"prompt": "こんにちは", "json": True, "max_tokens": LLM_MAX_TOKENS} and all(bad) \
        and body["format"] == "json" and body["think"] is False and body["stream"] is False \
        and body["options"] == {"num_predict": 10} and "format" not in ollama_chat_body("m", "p", False, 10) \
        and strip_think("<think>考え中</think>\n答え") == "答え" and strip_think("答え") == "答え" \
        and model_listed(["qwen3:8b", "llama3:latest"], "qwen3:8b") and model_listed(["llama3:latest"], "llama3") \
        and not model_listed(["qwen3:4b"], "qwen3:8b") \
        and is_local_url("http://127.0.0.1:11434") and is_local_url("http://localhost:11434") \
        and not is_local_url("http://192.168.1.2:11434") and not is_local_url("https://example.com")
    try:
        LocalLLM(url="http://example.com:11434")
        ok = False
    except ValueError:
        pass
    print(("OK " if ok else "NG ") + f"/llm の中身の読み方・Ollama に送る中身: {good}")
    failed += 0 if ok else 1

    # 作り物の Ollama
    seen: list[dict] = []

    class FakeOllama(BaseHTTPRequestHandler):
        def log_message(self, format: str, *args) -> None:
            pass

        def reply(self, body: dict) -> None:
            data = json.dumps(body, ensure_ascii=False).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self) -> None:
            self.reply({"models": [{"name": "qwen3:8b"}]})

        def do_POST(self) -> None:
            request = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)))
            seen.append(request)
            content = '{"answer": 1}' if request.get("format") == "json" else "<think>…</think>はい、" + request["model"]
            self.reply({"message": {"role": "assistant", "content": content}, "done": True})

    fake = ThreadingHTTPServer(("127.0.0.1", 0), FakeOllama)
    threading.Thread(target=fake.serve_forever, daemon=True).start()
    saved = (LLM, getattr(Handler, "key", None))
    server = Server(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()

    def call(payload: dict | bytes, key: str = "check-key") -> tuple[int, dict]:
        connection = http.client.HTTPConnection("127.0.0.1", server.server_address[1], timeout=30)
        try:
            data = payload if isinstance(payload, bytes) else json.dumps(payload, ensure_ascii=False).encode("utf-8")
            connection.request("POST", "/llm", body=data, headers={"Authorization": f"Bearer {key}",
                                                                   "Content-Type": "application/json"})
            response = connection.getresponse()
            return response.status, json.loads(response.read() or b"{}")
        finally:
            connection.close()

    try:
        Handler.key = "check-key"
        LLM = LocalLLM(url=f"http://127.0.0.1:{fake.server_address[1]}", model="qwen3:8b", enabled=True)
        plain = call({"prompt": "こんにちは"})
        as_json = call({"prompt": "JSON で", "json": True, "max_tokens": 50})
        wrong = call({"prompt": "こんにちは"}, key="wrong")
        broken = call(b"{")
        listed = "llm" in features()
        LLM = LocalLLM(url=f"http://127.0.0.1:{fake.server_address[1]}", model="gemma3:12b", enabled=True)
        missing = call({"prompt": "こんにちは"})
        unlisted = "llm" not in features()
        LLM = LocalLLM(enabled=False)
        off = "llm" not in features()
        ok = plain == (200, {"text": "はい、qwen3:8b"}) and as_json == (200, {"text": '{"answer": 1}'}) \
            and wrong[0] == 401 and broken[0] == 400 and missing[0] == 503 and listed and unlisted and off \
            and len(seen) == 2 and seen[1]["format"] == "json" and seen[1]["options"] == {"num_predict": 50} \
            and "format" not in seen[0] and seen[0]["options"] == {"num_predict": LLM_DEFAULT_TOKENS}
        print(("OK " if ok else "NG ") + f"/llm を作り物の Ollama で: {plain} {as_json} 合言葉違い {wrong[0]} "
              f"壊れた中身 {broken[0]} モデルなし {missing[0]} features に llm: {listed}／{not unlisted}／{not off}")
        failed += 0 if ok else 1
    finally:
        server.shutdown()
        server.server_close()
        fake.shutdown()
        fake.server_close()
        LLM, Handler.key = saved
    return failed


def check_words() -> int:
    """言葉ごとの時刻のまとめ方を確かめる（モデル無し）。NG の数を返す。"""
    cases = [
        # 1文字ずつのトークン。句読点は前の言葉に付ける
        ([(0.0, 0.1, "今"), (0.1, 0.2, "日"), (0.2, 0.3, "は"), (0.3, 0.35, "。")], "今日は。",
         [[0.0, 0.1, "今"], [0.1, 0.2, "日"], [0.2, 0.35, "は。"]]),
        # sentencepiece の "▁" が途中にあれば、そこで言葉を切る
        ([(0.0, 0.2, "▁Apple"), (0.2, 0.4, "▁Wat"), (0.4, 0.5, "ch")], "Apple Watch",
         [[0.0, 0.2, "Apple"], [0.2, 0.5, "Watch"]]),
        # Whisper の言葉（前に空白が付くことがある）はそのまま1つずつ
        ([(0.0, 0.3, " 今日"), (0.3, 0.5, "は"), (0.5, 0.9, " Apple")], "今日は Apple",
         [[0.0, 0.3, "今日"], [0.3, 0.5, "は"], [0.5, 0.9, "Apple"]]),
        # 重なった時刻は、前から順に重ならないようにそろえる
        ([(0.0, 0.5, "あ"), (0.3, 0.6, "い")], "あい", [[0.0, 0.5, "あ"], [0.5, 0.6, "い"]]),
        # 文と合わなければ（ほかの票で直した文など）、当て推量はしない
        ([(0.0, 0.1, "今"), (0.1, 0.2, "日")], "今日は", None),
        ([], "今日は", None),
        # 読めないトークン（バイトのかけら）が混ざっていても合わないので付けない
        ([(0.0, 0.1, "<0xE4>"), (0.1, 0.2, "日")], "今日", None),
    ]
    failed = 0
    for pieces, text, want in cases:
        got = group_words(pieces, text)
        ok = got == want
        print(("OK " if ok else "NG ") + f"言葉の時刻: {text} → {got}")
        failed += 0 if ok else 1
    # sherpa-onnx の時刻（区間の頭から）を、音声の頭からの秒にする。最後の言葉は WORD_MAX まで
    got = token_pieces(["今", "日"], [0.0, 0.4], [], 10.0, 12.0)
    ok = got == [(10.0, 10.4, "今"), (10.4, 11.4, "日")] and token_pieces(["今"], [0.0, 0.4], [], 0, 1) is None \
        and token_pieces(["今", "日"], [0.0, 0.4], [0.2, 0.3], 1.0, 2.0) == [(1.0, 1.2, "今"), (1.4, 1.7, "日")]
    print(("OK " if ok else "NG ") + f"トークンの時刻: {got}")
    failed += 0 if ok else 1

    # 多数決で選んだ文を書いたモデルの時刻だけを付ける（ほかの票で直した文には付けない）
    class Fake:
        provider = "cpu"

        def __init__(self, name: str, texts: list[str]) -> None:
            self.name = self.label = name
            self.texts = texts

        def run_timed(self, audio, segments, hints, prompt):
            out = []
            for (start, end), text in zip(segments, self.texts):
                step = (end - start) / max(1, len(text))
                pieces = [(start + k * step, start + (k + 1) * step, ch) for k, ch in enumerate(text)]
                out.append((text, group_words(pieces, text)))
            return out

    ensemble = Ensemble([Fake("haas", ["今日は会議です", "明日の洋服の件で田中さんと話す"]),
                         Fake("reazon", ["今日は会議です", "明日の予算の件で中田さんと話す"]),
                         Fake("whisper", ["", "明日の予算の件で田中さんと話した"])])
    lines = ensemble.transcribe(np.zeros(4 * RATE, dtype=np.float32), [(0.0, 2.0), (2.0, 4.0)])
    first = lines[0].get("words") if lines else None
    ok = len(lines) == 2 and words_fit(first, lines[0]["text"]) and first[0][0] == 0.0 \
        and all(a[0] <= b[0] for a, b in zip(first, first[1:])) and "words" not in lines[1]
    print(("OK " if ok else "NG ") + "選んだ文に言葉の時刻が付き、直した文には付かない: "
          + json.dumps([{k: v for k, v in line.items() if k != "votes"} for line in lines], ensure_ascii=False))
    failed += 0 if ok else 1
    ensemble.pool.shutdown(wait=False)
    return failed


def check_train_sample() -> int:
    """/train-sample・/train-status を、作った音と一時フォルダで確かめる（モデル無し）。NG の数を返す。"""
    import http.client
    import tempfile
    import urllib.parse

    global PERSONAL_DATA, PERSONAL_MODEL, SAMPLE_LIMIT
    saved = (PERSONAL_DATA, PERSONAL_MODEL, SAMPLE_LIMIT, getattr(Handler, "key", None))
    failed = 0
    t = np.arange(3 * RATE) / RATE
    tone = (0.2 * np.sin(2 * np.pi * 220 * t)).astype(np.float32)
    body = io.BytesIO()
    with wave.open(body, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes((tone * 32767).astype("<i2").tobytes())
    data = body.getvalue()
    with tempfile.TemporaryDirectory() as folder:
        PERSONAL_DATA = Path(folder) / "personal" / "data"
        PERSONAL_MODEL = Path(folder) / "personal" / "model"
        Handler.key = "check-key"
        server = Server(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        port = server.server_address[1]

        def call(path: str, payload: bytes | None = None, key: str = "check-key") -> tuple[int, dict]:
            # 暗号の部品（ssl）を使わない、ただの http で PC の中だけに送る
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
            try:
                connection.request("POST" if payload else "GET", path, body=payload,
                                   headers={"Authorization": f"Bearer {key}"})
                response = connection.getresponse()
                return response.status, json.loads(response.read() or b"{}")
            except OSError as error:  # 接続が切られたとき（前の版の、合言葉違いの大きな音声）
                return 0, {"error": repr(error)}
            finally:
                connection.close()

        try:
            words = urllib.parse.quote("今日は会議です")
            first = call(f"/train-sample?start=0.5&end=2.0&text={words}", data)
            again = call(f"/train-sample?start=0.5&end=2.0&text={words}", data)
            other = call(f"/train-sample?start=0.5&end=2.0&text={urllib.parse.quote('今日も会議です')}", data)
            bad = call(f"/train-sample?start=2.0&end=1.0&text={words}", data)
            empty = call("/train-sample?start=0.5&end=2.0&text=", data)
            # 合言葉が違うと断る。送られた音声（ここでは約 3MB）を読み捨ててから答えるので、送り途中で切られず 401 が届く
            stranger = call("/train-status", key="wrong")
            big = data * 30
            stranger_post = call(f"/train-sample?start=0.5&end=2.0&text={words}", big, key="wrong")
            no_key = call(f"/transcribe?segments=0-1", big, key="")
            print(("OK " if stranger_post == (401, {"error": "合言葉が違います"}) and no_key[0] == 401 else "NG ")
                  + f"合言葉違いで {len(big) // 1_000_000}MB を送ると: {stranger_post}、合言葉なし: {no_key[0]}")
            failed += 0 if stranger_post == (401, {"error": "合言葉が違います"}) and no_key[0] == 401 else 1
            status = call("/train-status")
            rows = read_samples(PERSONAL_DATA)
            frames = 0
            if rows:
                with wave.open(str(PERSONAL_DATA / rows[0]["audio"]), "rb") as w:
                    frames = w.getnframes() if w.getframerate() == RATE and w.getnchannels() == 1 else -1
            ok = first == (200, {"count": 1, "added": True}) and again == (200, {"count": 1, "added": False}) \
                and other == (200, {"count": 2, "added": True}) and bad[0] == 400 and empty[0] == 400 \
                and stranger[0] == 401 and status == (200, {"count": 2, "model": False, "trained": None}) \
                and len(rows) == 2 and rows[0]["text"] == "今日は会議です" and abs(frames - int(1.5 * RATE)) <= 1
            print(("OK " if ok else "NG ") + f"材料の保存: {first} {again} {other} 範囲違い {bad[0]} 文なし {empty[0]} "
                  f"合言葉違い {stranger[0]} 状態 {status} wav {frames} サンプル")
            failed += 0 if ok else 1
            # 上限に達したら足さない（古いものは消さない）
            SAMPLE_LIMIT = 2
            full = save_sample(PERSONAL_DATA, tone, 0.0, 1.0, "上限の確かめ")
            ok = full == (2, False) and len(read_samples(PERSONAL_DATA)) == 2
            print(("OK " if ok else "NG ") + f"材料の上限: {full}")
            failed += 0 if ok else 1
        finally:
            server.shutdown()
            server.server_close()
            PERSONAL_DATA, PERSONAL_MODEL, SAMPLE_LIMIT, Handler.key = saved
    return failed


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
    failed += 0 if ok else 1
    # Silero VAD などで見つけた声の区間を渡したときも、同じ決まり（つなぐ・短いものを捨てる・iPhone の区間を除く）
    regions = [(2.0, 3.0), (6.0, 6.5), (6.7, 7.2), (5.0, 5.15), (8.0, 9.0)]
    got = extra_speech(np.zeros(10 * RATE, dtype=np.float32), [(8.0, 9.0)], regions)
    ok = near(got, [(2.0, 3.0), (6.0, 7.2)]) and extra_speech(np.zeros(10 * RATE, np.float32), [], []) == []
    print(("OK " if ok else "NG ") + f"見つけた声の区間を渡すと: {got}")
    return failed + (0 if ok else 1)


def check_extras(path: str, threads: int) -> None:
    """聞き逃した声の探し方・/speakers・/scene を、その音声で試す（モデルを取ってくる。CI で使う）。"""
    failed = check_extra_speech()
    audio = load_audio(Path(path).read_bytes())
    duration = len(audio) / RATE
    found = extra_speech(audio, [])
    print(f"音声 {duration:.1f} 秒。iPhone の区間が無いとき、声らしい所（音の大きさ）: {found}")
    if found:
        print(f"  最初の区間を iPhone の区間にすると: {extra_speech(audio, found[:1])}")
    # Silero VAD（vad=union の声の探し方）を取ってきて、その音声と無音で試す
    started = time.time()
    vad = extra_model("vad", threads)
    regions = vad.regions(audio)
    silero = find_extra(audio, [])
    print(f"Silero VAD: {vad.name}（{time.time() - started:.1f} 秒）声の区間 {[(round(a, 2), round(b, 2)) for a, b in regions]}"
          f" → 聞き逃した声 {silero}")
    ok = len(regions) >= 1 and all(0 <= a < b <= duration + 0.05 for a, b in regions) and len(silero) >= 1 \
        and vad.regions(np.zeros(3 * RATE, dtype=np.float32)) == [] and find_extra(audio, [(0.0, duration)]) == [] \
        and vad.regions(audio) == regions
    print(("OK " if ok else "NG ") + "Silero VAD で声の区間が見つかる（無音では見つからない・何度やっても同じ）")
    failed += 0 if ok else 1
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
        and len(embeddings[-1]) == speaker.dim and abs(np.linalg.norm(embeddings[-1]) - 1) < 1e-3 \
        and speaker.name == Path(SPEAKER_MODEL).stem
    print(("OK " if ok else "NG ") + f"区間ごとに声の特徴が出る（短い区間は null、長さは 1、モデルは {SPEAKER_MODEL}）")
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
    failed += check_enhance(audio, ranges, threads)
    print("この PC で使える機能: " + ", ".join(features()))
    if failed:
        sys.exit(1)


def check_enhance(audio: np.ndarray, ranges: list[tuple[float, float]], threads: int) -> int:
    """雑音を除くモデルを取ってきて、その音声と作った音で試す。NG の数を返す。"""
    failed = 0
    started = time.time()
    denoiser = extra_model("enhance", threads)
    cleaned = denoiser.denoise_segments(audio, ranges)
    print(f"雑音を除くモデル: {denoiser.name}（{time.time() - started:.1f} 秒）")

    def db(x: np.ndarray) -> float:
        return 20.0 * float(np.log10(np.sqrt(np.mean(np.asarray(x, dtype=np.float64) ** 2)) + 1e-10))

    for a, b in ranges:
        print(f"  [{a:.1f}-{b:.1f}] {db(clip(audio, a, b)):.1f} dB → {db(clip(cleaned, a, b)):.1f} dB")
    # 長さが同じ・数として正しい・短すぎる音と空の音でも落ちない
    ok = len(cleaned) == len(audio) and bool(np.all(np.isfinite(cleaned))) \
        and len(denoiser.denoise(audio[:int(0.1 * RATE)])) == int(0.1 * RATE) \
        and len(denoiser.denoise(np.zeros(0, dtype=np.float32))) == 0
    print(("OK " if ok else "NG ") + "雑音を除いた音が、もとと同じ長さで出る（短い音はそのまま）")
    failed += 0 if ok else 1
    # 作った音：周りの音（約 -40dBFS）の中に 1〜1.5 秒だけ声のような音。周りの音が小さくなり、声の位置はずれない
    rng = np.random.default_rng(0)
    t = np.arange(3 * RATE) / RATE
    noisy = (rng.standard_normal(3 * RATE) * 0.01).astype(np.float32)
    voice = sum(np.sin(2 * np.pi * 150 * k * t) / k for k in range(1, 10)) * 0.1 * (0.5 + 0.5 * np.sin(2 * np.pi * 4 * t))
    noisy[RATE:int(1.5 * RATE)] += voice[RATE:int(1.5 * RATE)].astype(np.float32)
    out = denoiser.denoise(noisy)

    def loud(x: np.ndarray) -> tuple[float, float]:
        """10ms ごとに測って、-25dB より大きい所の始まりと終わり（秒）"""
        frames = np.asarray(x[:len(x) // 160 * 160], dtype=np.float64).reshape(-1, 160)
        found = np.flatnonzero(20 * np.log10(np.sqrt(np.mean(frames ** 2, axis=1)) + 1e-10) > -25)
        return (found[0] / 100, (found[-1] + 1) / 100) if len(found) else (-1.0, -1.0)

    before, after = loud(noisy), loud(out)
    ok = len(out) == len(noisy) and db(out[:int(0.8 * RATE)]) < db(noisy[:int(0.8 * RATE)]) - 10 \
        and after[0] >= 0 and abs(after[0] - before[0]) <= 0.03 and abs(after[1] - before[1]) <= 0.05
    print(("OK " if ok else "NG ") + f"作った音: 周りの音 {db(noisy[:int(0.8 * RATE)]):.1f} → {db(out[:int(0.8 * RATE)]):.1f} dB、"
          f"声の位置 {before[0]:.2f}〜{before[1]:.2f} 秒 → {after[0]:.2f}〜{after[1]:.2f} 秒（ずれないはず）")
    failed += 0 if ok else 1
    return failed


def main() -> None:
    # 版 9: MCP サーバー（stdio）。答えの通り道（標準出力）に何も混ぜないよう、ほかの何よりも先に分ける
    if "--mcp" in sys.argv[1:]:
        import lifelog_mcp

        sys.exit(lifelog_mcp.main([a for a in sys.argv[1:] if a != "--mcp"]))
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
    parser.add_argument("--no-words", action="store_true",
                        help="言葉ごとの時刻（words）を付けない（Whisper が少し速くなる）")
    parser.add_argument("--enhance", action="store_true",
                        help="--test で、雑音を除いた音を Haas-ja・ReazonSpeech でもう一度聞いた票も加える")
    parser.add_argument("--download", action="store_true", help="モデルを取ってくるだけ")
    parser.add_argument("--check-vote", action="store_true", help="多数決の決まりを確かめる")
    parser.add_argument("--check-extras", metavar="音声",
                        help="聞き逃した声の探し方・話し手の声の特徴・周りの音を、その音声で試す（モデルを取ってくる）")
    parser.add_argument("--startup", action="store_true", help="Windows の起動時に自動で始める")
    parser.add_argument("--no-startup", action="store_true", help="起動時に始めるのをやめる")
    parser.add_argument("--threads", type=int, default=max(1, min(8, (os.cpu_count() or 4) // 2)))
    parser.add_argument("--port", type=int, default=PORT, help=f"待ち受ける番号（既定 {PORT}）")
    parser.add_argument("--provider", default="cpu", help="Haas-ja・ReazonSpeech を動かす場所: cpu（既定）または cuda")
    parser.add_argument("--engines", default="haas,reazon,whisper,kotoba,mine,qwen",
                        help="使うモデル（haas,reazon,whisper,kotoba,mine,qwen のうち。kotoba・mine は GPU のときだけ、"
                             "mine は train_personal.py で作ったあとだけ、qwen は --qwen のときだけ動く）")
    parser.add_argument("--qwen", action="store_true",
                        help="Qwen3-ASR の票も加える（NVIDIA の GPU と、別に入れる torch・qwen-asr の部品が要る。"
                             "config.json の \"qwen\": true でも同じ）")
    parser.add_argument("--qwen-model", default=None,
                        help=f"Qwen3-ASR のモデル（既定 {QWEN_MODEL}。Qwen/Qwen3-ASR-1.7B も使える）")
    parser.add_argument("--llm-model", default=None,
                        help=f"/llm に使う Ollama のモデル（既定 {LLM_MODEL}。config.json の \"llm_model\" でも同じ）")
    parser.add_argument("--no-llm", action="store_true", help="/llm（この PC の中の Ollama への取り次ぎ）を使わない")
    parser.add_argument("--no-auto-update", action="store_true",
                        help="自分で新しい版に入れ替えない（config.json の \"auto_update\": false でも同じ）")
    parser.add_argument("--no-semantic", action="store_true",
                        help="意味で探す機能（/index・/search、Ollama の bge-m3）を使わない（config.json の \"semantic\": false でも同じ）")
    parser.add_argument("--check-semantic", action="store_true",
                        help="この PC の Ollama で、意味で探す機能を本物のモデル（bge-m3）で試す")
    # 版 7（records）
    parser.add_argument("--check-v7-records", action="store_true",
                        help="記録・音声の保存・直し（/records・/edits・記録の画面）を、一時のフォルダと作り物で確かめる")
    parser.add_argument("--try-records", action="store_true",
                        help="モデルを読み込まずに、一時のフォルダ（--try-home）と作り物の記録で起動して、記録の画面を試す"
                             "（この PC の中 127.0.0.1 だけで受ける。文字起こしはできない）")
    parser.add_argument("--try-home", default=None, help="--try-records で使うフォルダ（既定は新しい一時のフォルダ）")
    parser.add_argument("--whisper", default="auto",
                        help="Whisper の大きさ: auto（GPU なら large-v3、無ければ large-v3-turbo）・large-v3・large-v3-turbo・small・off")
    parser.add_argument("--device", default="auto", help="Whisper を動かす場所: auto（既定）・cuda・cpu")
    # 版 7（ops）
    parser.add_argument("--check-v7-ops", action="store_true",
                        help="版 7 の見守り（実機の様子・見えない通知・TestFlight の報告・学び直しと GPU の時間割）を、"
                             "一時フォルダと作り物の相手で確かめる（ネットも GPU も使わない）")
    # 版 8
    parser.add_argument("--check-v8", action="store_true",
                        help="版 8（時間・待ち合わせ・通知・下書き・新しい区切りから）を、一時フォルダと作り物のモデルで確かめる")
    # 版 9
    parser.add_argument("--check-v9", action="store_true",
                        help="版 9（職場の会話の印・聞いて直す・記録を読む MCP サーバー）を、一時フォルダと作り物の記録で確かめる")
    parser.add_argument("--mcp", action="store_true",
                        help="この PC の Claude Code から記録を読む MCP サーバー（stdio）として動く。読むだけで、"
                             "職場の会話は返さない（ほかに --home・--ollama-url を付けられる。くわしくは README.txt）")
    parser.add_argument("--fake-models", action="store_true",
                        help="モデルを読み込まず、作り物のモデルで起動する（受け口・見守りの画面・GPU の時間割を試すとき用。"
                             "文字起こしの答えは作り物）")
    args = parser.parse_args()

    if args.startup or args.no_startup:
        set_startup(args.startup)
        return
    if args.check_vote or args.check_v7_ops or args.check_v7_records or args.check_v8 or args.check_v9:
        # 版 8: 確かめるときは、本物の HOME（log.txt・データ）に書かない
        isolate_home()
    if args.check_vote:
        check_vote()
        return
    if args.check_v7_ops:  # 版 7（ops）
        import v7checks_ops

        sys.exit(1 if v7checks_ops.run(sys.modules[__name__]) else 0)
    if args.check_v8:  # 版 8: 時間・待ち合わせ・通知・下書き・新しい順
        import v8checks

        sys.exit(1 if v8checks.run(sys.modules[__name__]) else 0)
    if args.check_v9:  # 版 9: 職場の会話の印・聞いて直す・記録を読む MCP サーバー
        import v9checks

        sys.exit(1 if v9checks.run(sys.modules[__name__]) else 0)
    if args.check_extras:
        check_extras(args.check_extras, max(1, args.threads // 2))
        return
    # 版 7（records）: 確かめる・試す（どちらも本物のモデルと、ふだんの置き場所は使わない）
    if args.check_v7_records or args.try_records:
        import v7checks_records

        if args.check_v7_records:
            sys.exit(1 if v7checks_records.run(sys.modules[__name__]) else 0)
        v7checks_records.try_serve(sys.modules[__name__], args.port, args.try_home)
        return
    global USE_HOTWORDS, CLEAN_AUDIO, WORD_TIMES
    if args.no_hotwords:
        USE_HOTWORDS = False
    if args.no_clean:
        CLEAN_AUDIO = False
    if args.no_words:
        WORD_TIMES = False
    names = [n.strip() for n in args.engines.split(",") if n.strip()]
    config = load_config()
    # Qwen3-ASR は、--qwen か config.json の "qwen": true のときだけ（モデルは --qwen-model か "qwen_model"）
    qwen = None
    if args.qwen or config.get("qwen") is True:
        qwen = args.qwen_model or str(config.get("qwen_model") or QWEN_MODEL)
    global LLM
    try:
        LLM = LocalLLM(url=str(config.get("ollama_url") or OLLAMA_URL),
                       model=args.llm_model or str(config.get("llm_model") or LLM_MODEL),
                       enabled=not args.no_llm and config.get("llm") is not False)
    except ValueError as error:
        log(f"/llm は使いません: {error}")
        LLM = LocalLLM(enabled=False)
    # 版 6 の設定
    App.auto_update = not args.no_auto_update and config.get("auto_update") is not False
    App.use_semantic = not args.no_semantic and config.get("semantic") is not False
    if config.get("task"):
        App.task = str(config["task"])
    if args.check_semantic:
        import v6checks

        v6checks.check_semantic_real(sys.modules[__name__])
        return

    # 版 7（ops）: GPU の時間割で、下ろしたモデルを同じ設定で作り直すため
    ops.configure(names=names, whisper=args.whisper, device=args.device, threads=args.threads, fake=args.fake_models)

    def factory() -> Ensemble:
        if args.fake_models:  # 版 7（ops）: 試すとき用の作り物のモデル
            return Ensemble(ops.fake_engines())
        return load_engines(names, args.threads, args.provider, args.whisper, args.device, qwen)

    if args.download:
        engine = factory()
        print(f"用意できたモデル: {engine.label}（{engine.provider}）")
        wanted = [n for n in names if n not in ("kotoba", "mine", "qwen")
                  and not (n == "whisper" and args.whisper == "off")]
        if len([e for e in engine.engines if e.name in wanted]) < len(wanted):
            sys.exit(1)
        return
    if args.test:
        test(args.test, factory(), args.segments, [w for w in re.split("[、,]", args.hints) if w], args.enhance)
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
