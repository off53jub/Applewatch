"""LifeLog PC: s22 確2・確13・確15・確22 のモデルの切り替えの口（2026-11-22）。測った数は docs/s22-pc.md。

どれも**初めは今のまま**（config.json に書かなければ何も変わらない）。測って良かったものだけ、本人が config.json で切り替える。
切り替えたモデルのファイルが無ければ、**00:00〜05:00 の枠でだけ**取ってくる（s22pc の見回り）。取れるまでは今のモデルのまま。
取る所は、名の知れた公式の置き場だけ（Hugging Face。下の URL。決めておいた大きさと SHA-256 が合うものだけ使う）。

config.json の名前:
- "speaker_model": "campplus"（今・既定）| "wespeaker34" | "eres2netv2" | "titanet"   話し手の声の特徴（確2）。
  変えると /hello の speaker_model も変わり、iPhone は登録した声を測り直す。voices/<日>.npz も測り直しになる。
- "enhance_model": "gtcrn"（今・既定）| "dpdfnet2"   雑音を除くモデル（確13）
- "enhance_scenes": {"train": true, "car": true, "shop": true, "outside": true}   場面ごとに雑音を除いた票を足す（確22。
  POST /jobs の省ける scene=train|car|shop|outside|home。既定は {}＝今のまま「騒がしい区切りだけ」）
- "asr_extra": ["parakeet"] | ["sensevoice"]   多数決に足すモデル（確15。CPU で動く。既定は []）
"""

from __future__ import annotations

import datetime
import hashlib
import threading
from pathlib import Path

HF = "https://huggingface.co"
SPEAKER_REPO = f"{HF}/csukuangfj/speaker-embedding-models/resolve/main"
SPEAKERS = {
    # 今のもの（k2-fsa の GitHub の置き場。lifelog_pc.SPEAKER_URL）。ここでは取らない
    "campplus": {"file": "3dspeaker_speech_campplus_sv_en_voxceleb_16k.onnx", "url": None},
    "wespeaker34": {"file": "wespeaker_en_voxceleb_resnet34_LM.onnx", "url": f"{SPEAKER_REPO}/wespeaker_en_voxceleb_resnet34_LM.onnx",
                    "size": 26530550, "sha256": "e9848563da86f263117134dfd7ad63c92355b37de492b55e325400c9d9c39012"},
    "eres2netv2": {"file": "3dspeaker_speech_eres2netv2_sv_zh-cn_16k-common.onnx",
                   "url": f"{SPEAKER_REPO}/3dspeaker_speech_eres2netv2_sv_zh-cn_16k-common.onnx",
                   "size": 71441527, "sha256": "eda0bf86422a9725a3523d5a1d3d75dedf340664e0ba65cfc1c7b2a78b6cf0b5"},
    "titanet": {"file": "nemo_en_titanet_large.onnx", "url": f"{SPEAKER_REPO}/nemo_en_titanet_large.onnx",
                "size": 101405493, "sha256": "d51abcf31717ef28162f26acb9d44dd4127c3d44c9b8624f699f3425daca8e77"},
}
ENHANCERS = {
    "gtcrn": {"file": "gtcrn_simple.onnx", "url": None},
    "dpdfnet2": {"file": "dpdfnet2.onnx", "url": f"{HF}/Ceva-IP/DPDFNet/resolve/main/onnx/dpdfnet2.onnx",
                 "size": 10178747, "sha256": "4f0ee28935b4a32abecc717d745416976565834d839601acf43031094b4dc94c"},
}
PARAKEET = f"{HF}/csukuangfj/sherpa-onnx-nemo-parakeet-tdt_ctc-0.6b-ja-35000-int8/resolve/main"
SENSEVOICE = f"{HF}/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09/resolve/main"
ASR = {
    "parakeet": {"dir": "parakeet-ja", "files": {
        "model.int8.onnx": (f"{PARAKEET}/model.int8.onnx", 655542604,
                            "3addd00ef5bd1742078389e540b77394e4a508bdf2f4c9ad1b4a76d93e76598e"),
        "tokens.txt": (f"{PARAKEET}/tokens.txt", 28557, "732f64c53909f2620c713f4106b487d92e6f54a6915b3cd3d1dbd32f9f4f392a")}},
    "sensevoice": {"dir": "sensevoice", "files": {
        "model.int8.onnx": (f"{SENSEVOICE}/model.int8.onnx", 237115547,
                            "12ca1a2ae7ecf3e0019ef2822307ee0b5cadc9196569e379b4c4026f8205276d"),
        "tokens.txt": (f"{SENSEVOICE}/tokens.txt", 315894, "f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc")}},
}
SCENES = ("train", "car", "shop", "outside", "home")
WINDOW = (0, 5)   # 取ってよい時間（時）

_lock = threading.Lock()


def speaker_choice(config: dict | None) -> str:
    name = (config or {}).get("speaker_model")
    return name if isinstance(name, str) and name in SPEAKERS else "campplus"


def enhance_choice(config: dict | None) -> str:
    name = (config or {}).get("enhance_model")
    return name if isinstance(name, str) and name in ENHANCERS else "gtcrn"


def asr_extra(config: dict | None) -> list[str]:
    names = (config or {}).get("asr_extra")
    return [n for n in names if isinstance(n, str) and n in ASR] if isinstance(names, list) else []


def enhance_for_scene(config: dict | None, scene: str | None) -> bool:
    scenes = (config or {}).get("enhance_scenes")
    return bool(isinstance(scenes, dict) and scene in SCENES and scenes.get(scene) is True)


def download_window(moment: datetime.datetime) -> bool:
    return WINDOW[0] <= moment.hour < WINDOW[1]


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def good_file(path: Path, size: int | None, sha: str | None) -> bool:
    try:
        if not path.is_file() or (size is not None and path.stat().st_size != size):
            return False
    except OSError:
        return False
    return sha is None or _sha256(path) == sha


def wanted(home: Path, config: dict | None) -> list[tuple[Path, str, int, str]]:
    """切り替えたのに、まだ無いファイル [(置き場所, URL, 大きさ, SHA-256)]"""
    home = Path(home)
    out = []
    speaker = SPEAKERS[speaker_choice(config)]
    if speaker["url"]:
        out.append((home / "speaker" / speaker["file"], speaker["url"], speaker["size"], speaker["sha256"]))
    enhancer = ENHANCERS[enhance_choice(config)]
    if enhancer["url"]:
        out.append((home / "enhance" / enhancer["file"], enhancer["url"], enhancer["size"], enhancer["sha256"]))
    for name in asr_extra(config):
        for file, (url, size, sha) in ASR[name]["files"].items():
            out.append((home / "s22" / "models" / ASR[name]["dir"] / file, url, size, sha))
    return [row for row in out if not (row[0].is_file() and row[0].stat().st_size == row[2])]


def fetch_missing(home: Path, config: dict | None, fetch, log, moment: datetime.datetime | None = None) -> int:
    """00:00〜05:00 だけ、切り替えたモデルの足りないファイルを取る（SHA-256 が合わなければ消す）。取った数"""
    moment = moment or datetime.datetime.now()
    if not download_window(moment):
        return 0
    got = 0
    with _lock:
        for path, url, size, sha in wanted(home, config):
            try:
                log(f"切り替えたモデルのファイル {path.name}（約 {size // 1_000_000} MB）を取ってきます（00:00〜05:00 の枠）")
                fetch(url, path)
                if not good_file(path, size, sha):
                    path.unlink(missing_ok=True)
                    log(f"{path.name} の大きさか SHA-256 が合わないので消しました（今のモデルのまま）")
                    continue
                got += 1
            except Exception as error:  # noqa: BLE001 — 取れなくても今のモデルのまま
                log(f"{path.name} を取れませんでした（今のモデルのまま）: {type(error).__name__}")
    return got


def speaker_ready(home: Path, config: dict | None) -> tuple[str, str | None] | None:
    """切り替えた話し手のモデルが手元にあれば (ファイルの名前, URL)。今のままなら None"""
    choice = speaker_choice(config)
    entry = SPEAKERS[choice]
    if entry["url"] is None:
        return None
    path = Path(home) / "speaker" / entry["file"]
    return (entry["file"], entry["url"]) if path.is_file() and path.stat().st_size == entry["size"] else None


def enhance_model_config(sherpa_onnx, home: Path, config: dict | None, threads: int):
    """切り替えた雑音除去のモデルの設定（手元に無い・今のままなら None）"""
    choice = enhance_choice(config)
    entry = ENHANCERS[choice]
    if entry["url"] is None:
        return None
    path = Path(home) / "enhance" / entry["file"]
    if not (path.is_file() and path.stat().st_size == entry["size"]):
        return None
    dpdf = sherpa_onnx.OfflineSpeechDenoiserDpdfNetModelConfig(model=str(path))
    return dpdf, sherpa_onnx.OfflineSpeechDenoiserModelConfig(dpdfnet=dpdf, num_threads=threads, provider="cpu"), path.stem


def make_asr_engines(base_class, home: Path, config: dict | None, threads: int, rate: int, log) -> list:
    """多数決に足すモデル（確15）。手元にファイルがあるものだけ"""
    out = []
    for name in asr_extra(config):
        folder = Path(home) / "s22" / "models" / ASR[name]["dir"]
        files = {f: folder / f for f in ASR[name]["files"]}
        if not all(p.is_file() for p in files.values()):
            log(f"{name} はまだ手元にありません（00:00〜05:00 に取ってきます。それまでは使いません）")
            continue
        try:
            out.append(_engine(base_class, name, files, threads, rate))
        except Exception as error:  # noqa: BLE001
            log(f"{name} を読み込めませんでした（このモデル抜きで続けます）: {type(error).__name__}")
    return out


def _engine(base_class, name: str, files: dict[str, Path], threads: int, rate: int):
    import sherpa_onnx

    class Extra(base_class):
        def __init__(self) -> None:  # noqa: D107 — 親とは読み込むものが違う
            if name == "parakeet":
                self.recognizer = sherpa_onnx.OfflineRecognizer.from_nemo_ctc(
                    model=str(files["model.int8.onnx"]), tokens=str(files["tokens.txt"]), num_threads=threads,
                    sample_rate=rate, feature_dim=80, decoding_method="greedy_search", provider="cpu")
            else:
                self.recognizer = sherpa_onnx.OfflineRecognizer.from_sense_voice(
                    model=str(files["model.int8.onnx"]), tokens=str(files["tokens.txt"]), num_threads=threads,
                    sample_rate=rate, feature_dim=80, language="ja", use_itn=True, provider="cpu")
            self.chars = set()
            self.lock = threading.Lock()
            self.provider = "cpu"
            self.name = name
            self.label = {"parakeet": "Parakeet-ja", "sensevoice": "SenseVoice"}[name]

        def run_timed(self, audio, segments, hints, prompt):
            out = []
            with self.lock:
                for start, end in segments:
                    a, b = max(0, int(start * rate)), min(len(audio), int(end * rate))
                    if b - a < int(0.3 * rate):
                        out.append(("", None))
                        continue
                    stream = self.recognizer.create_stream()
                    stream.accept_waveform(rate, audio[a:b])
                    self.recognizer.decode_stream(stream)
                    out.append((stream.result.text.strip(), None))
            return out

    return Extra()
