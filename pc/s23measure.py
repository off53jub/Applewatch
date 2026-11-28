"""LifeLog PC: s23 続1・続2 の夜の測り（2026-11-23）。動いている LifeLog PC には触らない（HOME と母艦は読むだけ）。CPU 2 スレッド。

重いので **00:00〜04:50 だけ**動く（外の時間は何もせずに終わる。--wait で 00:00 まで待つ）。結果は --out のフォルダに数だけ（文・名前は出さない）。

    （s22 の測りの venv。sherpa-onnx 2.0.1・numpy・av が入っている。-I なので、この台本は自分で pc/ を読みに行く）
    D:\\aw-s22-pc\\_measure\\civenv\\Scripts\\python.exe -I pc\\s23measure.py speakers --wait --models D:\\aw-s22-pc\\_measure\\dl --out D:\\aw-s23-pc\\_measure
    D:\\aw-s22-pc\\_measure\\civenv\\Scripts\\python.exe -I pc\\s23measure.py asr --wait --models D:\\aw-s22-pc\\_measure\\dl --out D:\\aw-s23-pc\\_measure

- speakers（続1）: 本人が答えた組のうち、見本が全部時計の声の組（s23voice.watch_pairs。30 組まで）で、今の CAM++ と wespeaker34
  （ほかに eres2netv2・titanet があれば）の AUC（日の平均を引いた真ん中の近さ・s-norm）。30 組に足りなければ、その数で出して「足りない」と書く。
- asr（続2）: 正解集（goldset.items。続3 の騒がしい場面の分は scene ごとにも）を haas・reazon・parakeet（・whisper は --whisper のとき）で
  1 回ずつ文字にし、組み合わせごとに PC と同じ多数決（lifelog_pc.vote）で選んだ文の CER（文字の誤りの割合。小さいほど良い）。
  「今の組（haas＋whisper か haas だけ）」と「＋parakeet」を並べる。
"""

from __future__ import annotations

import argparse
import datetime
import io
import itertools
import json
import os
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
REAL_LOCAL = Path(os.environ.get("LOCALAPPDATA", r"C:\Users\USER\AppData\Local"))
HOME = REAL_LOCAL / "LifeLogPC"
BASE = Path(r"D:\Lifelog")
RATE = 16000
THREADS = 2
STOP = datetime.time(4, 50)
SPEAKER_FILES = {"campplus（今）": ("speaker", "3dspeaker_speech_campplus_sv_en_voxceleb_16k.onnx"),
                 "wespeaker34": ("spk-wespeaker", "wespeaker_en_voxceleb_resnet34_LM.onnx"),
                 "eres2netv2": ("spk-eres2netv2", "3dspeaker_speech_eres2netv2_sv_zh-cn_16k-common.onnx"),
                 "titanet": ("spk-titanet", "nemo_en_titanet_large.onnx")}


def say(text: str) -> None:
    # 画面の文字の形（cp932）で出せない記号（⚠ など）があっても止まらない（2026-11-24。夜の測りが最後の 1 行で落ちた）
    line = f"{time.strftime('%H:%M:%S')} {text}"
    enc = getattr(sys.stdout, "encoding", None) or "utf-8"
    print(line.encode(enc, "replace").decode(enc, "replace"), flush=True)


def window_ok(moment: datetime.datetime | None = None) -> bool:
    moment = moment or datetime.datetime.now()
    return moment.hour < 5 and moment.time() < STOP


def low_priority() -> None:
    try:
        import ctypes

        ctypes.windll.kernel32.SetPriorityClass(ctypes.windll.kernel32.GetCurrentProcess(), 0x00004000)  # 通常以下
    except Exception:  # noqa: BLE001
        pass


def load_audio(data: bytes):
    import av
    import numpy as np

    chunks = []
    with av.open(io.BytesIO(data)) as container:
        resampler = av.AudioResampler(format="flt", layout="mono", rate=RATE)
        for frame in container.decode(container.streams.audio[0]):
            for out in resampler.resample(frame):
                chunks.append(out.to_ndarray().reshape(-1))
        for out in resampler.resample(None):
            chunks.append(out.to_ndarray().reshape(-1))
    return np.concatenate(chunks).astype(np.float32) if chunks else np.zeros(0, np.float32)


def find_audio(name: str) -> Path | None:
    for path in (HOME / "audio" / f"{name[:4]}-{name[4:6]}-{name[6:8]}" / name, HOME / "jobs" / f"{name}.audio"):
        if path.is_file():
            return path
    return None


# MARK: - 続1


def model_path(models: Path, name: str) -> Path | None:
    sub, file = SPEAKER_FILES[name]
    for path in ((HOME / "speaker" / file) if sub == "speaker" else (models / sub / file), HOME / "speaker" / file):
        if path.is_file():
            return path
    return None


def measure_speakers(models: Path, out_dir: Path) -> dict:
    import numpy as np
    import sherpa_onnx

    import records
    import s23voice

    pairs = s23voice.watch_pairs(HOME, BASE)
    days = sorted({p["day"] for p in pairs if p["day"]})[-7:] or [(datetime.date.today() - datetime.timedelta(days=i)).isoformat()
                                                                   for i in range(1, 4)]
    parsed_days = []
    for day in days:
        try:
            parsed_days.append(records.parse_record(json.loads((HOME / "records" / f"{day}.json").read_text(encoding="utf-8"))))
        except (OSError, ValueError):
            continue
    cohort = s23voice.cohort_from(parsed_days)
    say(f"時計の声だけの答えのある組 {len(pairs)}（同じ人 {sum(p['same'] for p in pairs)}）・ならし用 {len(cohort)}")
    audio_cache: dict = {}
    result: dict = {"pairs": len(pairs), "wanted": s23voice.WANTED, "enough": len(pairs) >= s23voice.WANTED, "models": {}}
    for name in SPEAKER_FILES:
        if not window_ok():
            say("時間切れ（04:50）")
            break
        path = model_path(models, name)
        if path is None:
            result["models"][name] = {"error": "ファイルが無い"}
            continue
        started = time.time()
        import speakerfix  # s39: 平均の切れ端の割り方を直した型で測る（作れなければ元の型）

        fixed = speakerfix.ensure(path)
        extractor = sherpa_onnx.SpeakerEmbeddingExtractor(
            sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(fixed or path), num_threads=THREADS, provider="cpu"))
        cache: dict = {}

        def vec(sample, extractor=extractor, cache=cache):
            key = (sample["audio"], round(sample["start"], 2), round(sample["end"], 2))
            if key not in cache:
                cache[key] = None
                if sample["audio"] not in audio_cache:
                    found = find_audio(sample["audio"])
                    audio_cache[sample["audio"]] = load_audio(found.read_bytes()) if found else None
                    if len(audio_cache) > 300:
                        audio_cache.pop(next(iter(audio_cache)))
                audio = audio_cache.get(sample["audio"])
                if audio is not None:
                    piece = audio[int(sample["start"] * RATE):int(sample["end"] * RATE)]
                    if len(piece) > RATE // 2:
                        stream = extractor.create_stream()
                        stream.accept_waveform(RATE, piece)
                        stream.input_finished()
                        if extractor.is_ready(stream):
                            v = np.asarray(extractor.compute(stream), np.float64)
                            n = float(np.linalg.norm(v))
                            cache[key] = v / n if n > 0 else None
            return cache[key]

        got = s23voice.pair_scores(vec, pairs, cohort)
        got.pop("scored", None)
        got["seconds"] = round(time.time() - started, 1)
        result["models"][name] = got
        say(f"話し手 {name}: {got}")
        (out_dir / "s23-speakers.json").write_text(json.dumps(result, ensure_ascii=False, indent=1), encoding="utf-8")
    if not result["enough"]:
        say(f"⚠ 答えのある組が {len(pairs)} 組で、{s23voice.WANTED} 組に足りません（数は参考。家の PC の「2 つの声」の問いに答えると増えます）")
    return result


# MARK: - 続2


def cer_of(pairs: list[tuple[str, str]]) -> float | None:
    import goldset

    return goldset.cer(pairs)


def combos(names: list[str]) -> list[tuple[str, ...]]:
    """多数決の組み合わせ（2 つ以上。parakeet の有る無しが並ぶように）"""
    out = []
    for size in range(1, len(names) + 1):
        for combo in itertools.combinations(names, size):
            out.append(combo)
    return out


def vote_cer(hyps: list[dict[str, str]], refs: list[str], combo: tuple[str, ...], vote) -> float | None:
    """組み合わせ combo の多数決の文の CER（vote は lifelog_pc.vote。1 つだけならそのモデルの文）"""
    pairs = []
    for hyp, ref in zip(hyps, refs):
        chosen = {k: hyp.get(k, "") for k in combo}
        if len(combo) == 1:
            text = chosen[combo[0]]
        else:
            picked = vote(chosen)
            text = picked["text"] if picked else ""
        pairs.append((ref, text))
    return cer_of(pairs)


def measure_asr(models: Path, out_dir: Path, with_whisper: bool) -> dict:
    import numpy as np
    import sherpa_onnx

    import goldset

    # lifelog_pc は読み込むときに HOME を決めるので、一時フォルダを HOME にして読む（本物の HOME に書かないため）
    os.environ["LOCALAPPDATA"] = tempfile.mkdtemp(prefix="s23measure-")
    import lifelog_pc

    data = HOME / "personal" / "data"
    found = goldset.items(data)
    scenes = {}
    try:
        for raw in (data / "samples.jsonl").read_text(encoding="utf-8").splitlines():
            row = json.loads(raw)
            source = row.get("source") if isinstance(row.get("source"), dict) else {}
            if source.get("scene"):
                scenes[str(data / str(row.get("audio") or ""))] = source["scene"]
    except (OSError, ValueError):
        pass
    items = []
    for item in found:   # PC と同じく、音をそろえてから
        wav = goldset.read_wav(item["audio"])
        items.append((lifelog_pc.clean_audio(wav, [(0.0, len(wav) / RATE)]), item["text"], scenes.get(str(item["audio"]))))
    say(f"正解集 {len(items)} 個（騒がしい場面の印つき {sum(1 for _, _, s in items if s)} 個）")
    recognizers = {
        "haas": lambda: sherpa_onnx.OfflineRecognizer.from_transducer(
            encoder=str(HOME / "model" / "encoder.onnx"), decoder=str(HOME / "model" / "decoder.onnx"),
            joiner=str(HOME / "model" / "joiner.onnx"), tokens=str(HOME / "model" / "tokens.txt"), num_threads=THREADS,
            sample_rate=RATE, feature_dim=128, decoding_method="greedy_search", modeling_unit="cjkchar",
            model_type="nemo_transducer", provider="cpu"),
        "reazon": lambda: sherpa_onnx.OfflineRecognizer.from_transducer(
            encoder=str(HOME / "reazon" / "encoder-epoch-99-avg-1.int8.onnx"),
            decoder=str(HOME / "reazon" / "decoder-epoch-99-avg-1.onnx"),
            joiner=str(HOME / "reazon" / "joiner-epoch-99-avg-1.int8.onnx"), tokens=str(HOME / "reazon" / "tokens.txt"),
            num_threads=THREADS, sample_rate=RATE, feature_dim=80, decoding_method="greedy_search", provider="cpu"),
        "parakeet": lambda: sherpa_onnx.OfflineRecognizer.from_nemo_ctc(
            model=str(_parakeet(models) / "model.int8.onnx"), tokens=str(_parakeet(models) / "tokens.txt"),
            num_threads=THREADS, sample_rate=RATE, feature_dim=80, decoding_method="greedy_search", provider="cpu"),
    }
    hyps: list[dict[str, str]] = [{} for _ in items]
    result: dict = {"items": len(items), "engines": {}, "combos": {}, "by_scene": {}}
    for name, make in recognizers.items():
        if not window_ok():
            say("時間切れ（04:50）")
            break
        started = time.time()
        try:
            rec = make()
        except Exception as error:  # noqa: BLE001
            result["engines"][name] = {"error": f"{type(error).__name__}: {str(error)[:100]}"}
            continue
        for i, (audio, _, _) in enumerate(items):
            stream = rec.create_stream()
            stream.accept_waveform(RATE, np.asarray(audio, np.float32))
            rec.decode_stream(stream)
            hyps[i][name] = stream.result.text.strip()
        result["engines"][name] = {"cer": cer_of([(ref, h.get(name, "")) for h, (_, ref, _) in zip(hyps, items)]),
                                   "seconds": round(time.time() - started, 1)}
        say(f"文字起こし {name}: {result['engines'][name]}")
        del rec
    if with_whisper and window_ok():
        started = time.time()
        try:
            lifelog_pc.WHISPER_DIR = HOME / "whisper"
            engine = lifelog_pc.WhisperEngine(lifelog_pc.load_config().get("whisper") or "large-v3-turbo", "auto", THREADS)
            for i, (audio, _, _) in enumerate(items):
                got = engine.run_timed(np.asarray(audio, np.float32), [(0.0, len(audio) / RATE)], [], None)
                hyps[i]["whisper"] = (got[0][0] if got else "").strip()
            result["engines"]["whisper"] = {"cer": cer_of([(ref, h.get("whisper", "")) for h, (_, ref, _) in zip(hyps, items)]),
                                            "seconds": round(time.time() - started, 1)}
        except Exception as error:  # noqa: BLE001
            result["engines"]["whisper"] = {"error": f"{type(error).__name__}: {str(error)[:100]}"}
    names = [n for n in ("haas", "whisper", "reazon", "parakeet") if all(n in h for h in hyps) and hyps]
    refs = [ref for _, ref, _ in items]
    for combo in combos(names):
        result["combos"]["+".join(combo)] = vote_cer(hyps, refs, combo, lifelog_pc.vote)
    for scene in sorted({s for _, _, s in items if s}):
        idx = [i for i, (_, _, s) in enumerate(items) if s == scene]
        result["by_scene"][scene] = {"items": len(idx), **{"+".join(c): vote_cer([hyps[i] for i in idx], [refs[i] for i in idx], c,
                                                                              lifelog_pc.vote) for c in combos(names)}}
    now = "haas+whisper" if "whisper" in names else "haas"
    plus = now + "+parakeet" if "parakeet" in names else None
    if plus and result["combos"].get(now) is not None and result["combos"].get(plus) is not None:
        result["verdict"] = {"now": now, "now_cer": result["combos"][now], "plus": plus, "plus_cer": result["combos"][plus],
                             "better": result["combos"][plus] < result["combos"][now]}
        say(f"今の組 {now} {result['combos'][now]:.3f} → ＋parakeet {result['combos'][plus]:.3f}")
    (out_dir / "s23-asr.json").write_text(json.dumps(result, ensure_ascii=False, indent=1), encoding="utf-8")
    return result


def _parakeet(models: Path) -> Path:
    for path in (models / "asr-parakeet", HOME / "s22" / "models" / "parakeet-ja"):
        if (path / "model.int8.onnx").is_file():
            return path
    return models / "asr-parakeet"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="s23 続1・続2 の夜の測り（00:00〜04:50 だけ）")
    ap.add_argument("what", choices=["speakers", "asr"])
    ap.add_argument("--wait", action="store_true", help="00:00 まで待ってから始める")
    ap.add_argument("--models", default=r"D:\aw-s22-pc\_measure\dl", help="取ってきたモデルの置き場（s22 の _measure\\dl）")
    ap.add_argument("--out", default=str(HERE.parent / "_measure"), help="結果を置くフォルダ（コミットしない）")
    ap.add_argument("--whisper", action="store_true", help="whisper も測る（GPU を使う。動いている PC の GPU の空きに気を付ける）")
    args = ap.parse_args(argv)
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    if args.wait:
        while not window_ok():
            time.sleep(30)
    if not window_ok():
        say("00:00〜04:50 の外なので始めません（重い測りは夜だけ）")
        return 0
    low_priority()
    if args.what == "speakers":
        measure_speakers(Path(args.models), out_dir)
    else:
        measure_asr(Path(args.models), out_dir, args.whisper)
    say("おわり")
    return 0


if __name__ == "__main__":
    sys.exit(main())
