"""LifeLog PC — あなたの声と直した文で、Whisper（kotoba-whisper v2.0）を学び直す。

LifeLog PC が /train-sample で貯めた材料（%LOCALAPPDATA%\\LifeLogPC\\personal\\data）を使い、
kotoba-tech/kotoba-whisper-v2.0 を LoRA（peft）で少しだけ学び直す。学び直したものを元のモデルに混ぜて、
faster-whisper で動く形（CTranslate2、float16）にして %LOCALAPPDATA%\\LifeLogPC\\personal\\model に置く。
次に LifeLog PC を起動すると、"mine"（あなた向け Whisper）の票として多数決に加わる。

- NVIDIA の GPU が要る（無ければ、何もせずに終わる。終わりの番号 2）
- 材料が 300 より少なければ、何もせずに終わる（終わりの番号 2）
- 材料の 1 割を試験用に取り分け、学び直す前と後で文字の誤りの割合（CER）を測る。
  良くなったときだけ、モデルを入れ替える（良くならなければ、前のモデルのまま）
- 録音も文も PC の外には出さない（取ってくるのは元のモデルだけ）

使う部品は LifeLog PC とは別に入れる（README.txt の「あなた向けのモデル」を見てください）。

    python train_personal.py              学び直す
    python train_personal.py --epochs 5   学び直す回数を変える
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import random
import shutil
import subprocess
import sys
import time
import unicodedata
import wave
from pathlib import Path

HOME = Path(os.environ.get("LOCALAPPDATA") or Path.home() / ".local" / "share") / "LifeLogPC"
BASE = "kotoba-tech/kotoba-whisper-v2.0"
RATE = 16000
MIN_SAMPLES = 300
HOLDOUT = 0.1
# faster-whisper が読むのに要るファイル（モデルの変換のあとに写す）
NEEDED_FILES = ["tokenizer.json", "preprocessor_config.json"]
INSTALL_HINT = ("次の2行で入れてください（NVIDIA の GPU 用の torch です）:\n"
                "  pip install torch --index-url https://download.pytorch.org/whl/cu124\n"
                "  pip install transformers peft accelerate ctranslate2 numpy faster-whisper")


def refuse(message: str) -> None:
    """学び直せない理由を表示して、終わりの番号 2 で終わる"""
    print(message, file=sys.stderr, flush=True)
    sys.exit(2)


def say(message: str) -> None:
    print(time.strftime("%H:%M:%S ") + message, flush=True)


# MARK: - 材料


def read_samples(folder: Path) -> list[dict]:
    """samples.jsonl のうち、音声のファイルがあるもの"""
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
        if isinstance(item, dict) and item.get("audio") and item.get("text") and (folder / item["audio"]).exists():
            rows.append(item)
    return rows


def load_wav(path: Path):
    import numpy as np

    with wave.open(str(path), "rb") as w:
        if w.getframerate() != RATE or w.getnchannels() != 1 or w.getsampwidth() != 2:
            raise ValueError(f"16kHz モノラルの wav ではありません: {path.name}")
        data = w.readframes(w.getnframes())
    return np.frombuffer(data, dtype="<i2").astype(np.float32) / 32768.0


def split(rows: list[dict], seed: int) -> tuple[list[dict], list[dict]]:
    """1 割を試験用に取り分ける（毎回同じ分け方になるよう、ハッシュの順に並べてから混ぜる）。
    2026-11-13: 自動の材料（"source" の "origin" が "pc-auto"。正しい文はモデルが書いたもの）は試験には使わず、
    学ぶほうにだけ入れる（人が直した材料が 30 個より少ないときは、前と同じ分け方）"""
    rows = sorted(rows, key=lambda r: r.get("hash") or r["audio"])
    random.Random(seed).shuffle(rows)
    def is_auto(r: dict) -> bool:
        return isinstance(r.get("source"), dict) and r["source"].get("origin") == "pc-auto"

    auto = [r for r in rows if is_auto(r)]
    human = [r for r in rows if not is_auto(r)]
    if auto and len(human) >= 30:
        count = max(1, round(len(human) * HOLDOUT))
        return human[count:] + auto, human[:count]
    count = max(1, round(len(rows) * HOLDOUT))
    return rows[count:], rows[:count]


# MARK: - 文字の誤りの割合（CER）


def normalize(text: str) -> str:
    """比べる前に、全角・半角をそろえ、空白・句読点・記号を除く"""
    text = unicodedata.normalize("NFKC", text)
    return "".join(ch for ch in text if ch.isalnum())


def edit_distance(a: str, b: str) -> int:
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        current = [i]
        for j, cb in enumerate(b, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (ca != cb)))
        previous = current
    return previous[-1]


def cer(references: list[str], hypotheses: list[str]) -> float:
    errors = sum(edit_distance(normalize(r), normalize(h)) for r, h in zip(references, hypotheses))
    total = sum(len(normalize(r)) for r in references)
    return errors / max(1, total)


# MARK: - 学び直す


def main() -> None:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")  # type: ignore[union-attr]
        sys.stderr.reconfigure(encoding="utf-8")  # type: ignore[union-attr]
    parser = argparse.ArgumentParser(description="あなたの声と直した文で Whisper（kotoba-whisper v2.0）を学び直す")
    parser.add_argument("--home", default=str(HOME), help=f"LifeLog PC の置き場所（既定 {HOME}）")
    parser.add_argument("--epochs", type=int, default=3, help="材料を何周するか（既定 3）")
    parser.add_argument("--batch", type=int, default=4, help="一度に学ぶ材料の数（GPU のメモリが足りなければ減らす。既定 4）")
    parser.add_argument("--accumulate", type=int, default=2, help="何回分をまとめて反映するか（既定 2）")
    parser.add_argument("--lr", type=float, default=5e-4, help="学ぶ速さ（既定 0.0005）")
    parser.add_argument("--rank", type=int, default=32, help="LoRA の大きさ（既定 32）")
    parser.add_argument("--seed", type=int, default=0)
    args = parser.parse_args()

    home = Path(args.home)
    data_dir = home / "personal" / "data"
    model_dir = home / "personal" / "model"
    work_dir = home / "personal" / "work"

    rows = read_samples(data_dir)
    if len(rows) < MIN_SAMPLES:
        refuse(f"材料が {len(rows)} 個しかありません。{MIN_SAMPLES} 個以上たまってから、もう一度試してください。"
               f"（置き場所: {data_dir}）")
    try:
        import torch
    except ImportError:
        refuse("学び直す部品（torch など）が入っていません。\n" + INSTALL_HINT)
    if not torch.cuda.is_available():
        refuse("NVIDIA の GPU が見つからないので、学び直せません（CPU では何日もかかります）。\n"
               "GPU があるのにこう出るときは、GPU 用の torch が入っているか、NVIDIA のドライバーが新しいか"
               "（CUDA 12 には 528 以降が要ります。nvidia-smi で確かめられます）を確かめてください。\n" + INSTALL_HINT)
    try:
        from peft import LoraConfig, get_peft_model
        from transformers import WhisperForConditionalGeneration, WhisperProcessor, WhisperTokenizerFast
    except ImportError as error:
        refuse(f"学び直す部品が足りません（{error}）。\n" + INSTALL_HINT)

    torch.manual_seed(args.seed)
    train_rows, test_rows = split(rows, args.seed)
    say(f"材料 {len(rows)} 個（学ぶ {len(train_rows)} 個・試す {len(test_rows)} 個）。GPU: {torch.cuda.get_device_name(0)}")

    say(f"元のモデル {BASE} を読み込んでいます…（初回は約1.5GB を取ってきます）")
    processor = WhisperProcessor.from_pretrained(BASE)
    tokenizer = processor.tokenizer
    tokenizer.set_prefix_tokens(language="ja", task="transcribe")
    model = WhisperForConditionalGeneration.from_pretrained(BASE, torch_dtype=torch.float32).to("cuda")
    model.config.forced_decoder_ids = None
    if getattr(model, "generation_config", None) is not None:
        model.generation_config.forced_decoder_ids = None
    start_token = model.config.decoder_start_token_id

    def features(batch: list[dict]):
        audio = [load_wav(data_dir / r["audio"]) for r in batch]
        out = processor.feature_extractor(audio, sampling_rate=RATE, return_tensors="pt")
        return out.input_features.to("cuda")

    def labels(batch: list[dict]):
        ids = [tokenizer(r["text"]).input_ids[:440] for r in batch]
        longest = max(len(x) for x in ids)
        tensor = torch.full((len(ids), longest), -100, dtype=torch.long)
        for k, x in enumerate(ids):
            tensor[k, :len(x)] = torch.tensor(x)
        # モデルが自分で先頭に付ける印（<|startoftranscript|>）は除く
        if (tensor[:, 0] == start_token).all():
            tensor = tensor[:, 1:]
        return tensor.to("cuda")

    def transcribe(m, batch_rows: list[dict]) -> list[str]:
        m.eval()
        texts: list[str] = []
        with torch.no_grad(), torch.autocast("cuda", dtype=torch.float16):
            for i in range(0, len(batch_rows), 8):
                part = batch_rows[i:i + 8]
                generated = m.generate(input_features=features(part), language="ja", task="transcribe",
                                       max_new_tokens=225, use_cache=True)
                texts.extend(tokenizer.batch_decode(generated, skip_special_tokens=True))
        return [t.strip() for t in texts]

    references = [r["text"] for r in test_rows]
    say("学び直す前の誤りの割合を測っています…")
    before = cer(references, transcribe(model, test_rows))
    say(f"学び直す前の CER: {before:.2%}")

    lora = LoraConfig(r=args.rank, lora_alpha=args.rank * 2, lora_dropout=0.05, bias="none",
                      target_modules=["q_proj", "k_proj", "v_proj", "out_proj"])
    model = get_peft_model(model, lora)
    # 途中の計算を持たずに計算し直して、GPU のメモリを節約する（8GB の GPU でも動くように）
    model.config.use_cache = False
    model.base_model.model.gradient_checkpointing_enable(gradient_checkpointing_kwargs={"use_reentrant": False})
    trainable = [p for p in model.parameters() if p.requires_grad]
    say(f"学ぶ数: {sum(p.numel() for p in trainable):,}（全体の {sum(p.numel() for p in trainable) / sum(p.numel() for p in model.parameters()):.2%}）")
    optimizer = torch.optim.AdamW(trainable, lr=args.lr, weight_decay=0.01)
    steps = max(1, args.epochs * ((len(train_rows) + args.batch - 1) // args.batch) // args.accumulate)
    warmup = max(1, steps // 10)
    # 初めの 1 割で少しずつ速くし、あとはだんだん遅くする
    scheduler = torch.optim.lr_scheduler.LambdaLR(
        optimizer, lambda s: min(1.0, (s + 1) / warmup) * min(1.0, max(0.0, (steps - s) / max(1, steps - warmup))))
    scaler = torch.amp.GradScaler("cuda")

    say(f"学び直しています（{args.epochs} 周、{steps} 回反映）…")
    rng = random.Random(args.seed)
    try:
        for epoch in range(args.epochs):
            model.train()
            order = list(train_rows)
            rng.shuffle(order)
            total, count = 0.0, 0
            optimizer.zero_grad()
            for i in range(0, len(order), args.batch):
                batch = order[i:i + args.batch]
                with torch.autocast("cuda", dtype=torch.float16):
                    loss = model(input_features=features(batch), labels=labels(batch)).loss / args.accumulate
                scaler.scale(loss).backward()
                total += float(loss) * args.accumulate
                count += 1
                if count % args.accumulate == 0 or i + args.batch >= len(order):
                    scaler.unscale_(optimizer)
                    torch.nn.utils.clip_grad_norm_(trainable, 1.0)
                    scaler.step(optimizer)
                    scaler.update()
                    optimizer.zero_grad()
                    scheduler.step()
            say(f"  {epoch + 1} 周目: 損失 {total / max(1, count):.4f}")
    except torch.cuda.OutOfMemoryError:
        refuse("GPU のメモリが足りませんでした。--batch 2（それでも足りなければ --batch 1 --accumulate 8）で、"
               "もう一度試してください。モデルは入れ替えていません。")

    say("学び直した後の誤りの割合を測っています…")
    after = cer(references, transcribe(model, test_rows))
    say(f"学び直した後の CER: {after:.2%}（前 {before:.2%}）")
    if not after < before:
        say("良くならなかったので、モデルは入れ替えません（前のモデルのまま）。材料が増えてから、もう一度試してください。")
        return

    say("元のモデルに混ぜて、faster-whisper の形にしています…")
    if work_dir.exists():
        shutil.rmtree(work_dir)
    merged_dir = work_dir / "merged"
    merged = model.merge_and_unload()
    merged.save_pretrained(str(merged_dir), safe_serialization=True)
    processor.save_pretrained(str(merged_dir))
    # faster-whisper は tokenizer.json を読むので、速い版の分け方も置く
    WhisperTokenizerFast.from_pretrained(BASE).save_pretrained(str(merged_dir))
    del merged, model
    torch.cuda.empty_cache()

    new_dir = home / "personal" / "model.new"
    if new_dir.exists():
        shutil.rmtree(new_dir)
    converter = shutil.which("ct2-transformers-converter")
    command = [converter] if converter else [sys.executable, "-m", "ctranslate2.converters.transformers"]
    command += ["--model", str(merged_dir), "--output_dir", str(new_dir), "--quantization", "float16"]
    result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if result.returncode != 0 or not (new_dir / "model.bin").exists():
        print(result.stdout[-2000:], result.stderr[-3000:], sep="\n", file=sys.stderr)
        refuse("faster-whisper の形にできませんでした（ctranslate2 が入っているか確かめてください）。モデルは入れ替えていません。")
    for name in NEEDED_FILES:
        if not (merged_dir / name).exists():
            refuse(f"{name} が作られませんでした。モデルは入れ替えていません。")
        shutil.copy2(merged_dir / name, new_dir / name)

    # 入れる前に、faster-whisper で読めて文字にできるか確かめる（CPU で1つだけ）
    try:
        from faster_whisper import WhisperModel
    except ImportError:
        WhisperModel = None
    if WhisperModel is not None:
        check = WhisperModel(str(new_dir), device="cpu", compute_type="int8")
        pieces, _ = check.transcribe(load_wav(data_dir / test_rows[0]["audio"]), language="ja", beam_size=1,
                                     without_timestamps=True, vad_filter=False)
        say(f"faster-whisper で読めました: {''.join(p.text for p in pieces).strip()[:40]}")
        del check

    info = {"trained": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
            "base": BASE, "samples": len(rows), "train": len(train_rows), "test": len(test_rows),
            "cer_before": round(before, 4), "cer_after": round(after, 4), "epochs": args.epochs,
            "rank": args.rank, "lr": args.lr}
    (new_dir / "trained.json").write_text(json.dumps(info, ensure_ascii=False, indent=2), encoding="utf-8")

    # 入れ替える（前のモデルは model.old に1つだけ残す）
    old_dir = home / "personal" / "model.old"
    try:
        if old_dir.exists():
            shutil.rmtree(old_dir)
        if model_dir.exists():
            model_dir.rename(old_dir)
        new_dir.rename(model_dir)
    except OSError as error:
        refuse(f"モデルを入れ替えられませんでした（{error}）。LifeLog PC を止めてから、もう一度試してください。"
               f"新しいモデルは {new_dir} にあります。")
    shutil.rmtree(work_dir, ignore_errors=True)
    say(f"あなた向けのモデルを入れました（{model_dir}）。LifeLog PC を起動し直すと使い始めます。")


if __name__ == "__main__":
    main()
