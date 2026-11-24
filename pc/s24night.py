"""LifeLog PC: s24（2026-11-24）の夜の測り。家の PC のデータと母艦を読んで数えるだけ（記録・答え・設定は変えない）。0 円・言語モデルなし。

s24pc.py が夜（01:00〜05:00・新しい区切りが待っていないとき）に呼ぶ。手で動かすときは下の台本（本物の HOME と母艦は読むだけ。
結果は --out のフォルダにだけ書く。重い speakers・vad は 00:00〜05:00 と 08:30〜18:00 だけ動く）:

    （s22 の測りの venv。sherpa-onnx・numpy・av が入っている。-I なので、この台本は自分で pc/ を読みに行く）
    D:\\aw-s22-pc\\_measure\\civenv\\Scripts\\python.exe -I pc\\s24night.py scenes   --out <フォルダ>
    D:\\aw-s22-pc\\_measure\\civenv\\Scripts\\python.exe -I pc\\s24night.py speakers --out <フォルダ>
    D:\\aw-s22-pc\\_measure\\civenv\\Scripts\\python.exe -I pc\\s24night.py vad      --out <フォルダ>
    D:\\aw-s22-pc\\_measure\\civenv\\Scripts\\python.exe -I pc\\s24night.py vocab    --out <フォルダ>

- 当5 speakers: 話し手のモデルの測り直しを、新しく聞かずに。本人がもう答えた「同じ人か」の組（母艦 inbox/app_feedback.jsonl の
  same_person と vp- の答え）を、時計の声に限らず全部使う（s23 続1 は時計の声だけで 2 組しかなかった）。音声が PC に残っている見本だけ。
  自分の声の登録の声（HOME/knowme/self-voice/<場面>/ に本人が置いた録音。s18 の 71）があれば、録音どうしを「同じ」、
  名前のある人の行を「違う」として足す。登録の声そのものはアプリの中にあり、PC には無い（置かれていなければ 0 組）。
  今のモデル（CAM++）と、HOME/speaker にある別のモデル（config の "speaker_shadow" ほか）の AUC と s-norm の AUC。
- 当7 scenes: 騒がしい場面の物差しを PLAUD の文字で（本人に打たせない）。記録の行を場面に分け（POST /jobs の scene →
  母艦の年表の会話の「歩きながら」「電車・車で」→ 年表の位置の店・自宅・速い移動）、場面ごとに PLAUD と合った文字の割合
  （s21 精1 と同じ数え方）。
- 当8 vad: 「声なしと判定」で落ちた区切り（log.txt の「N 秒（声 X 秒）」で声が 5% 未満のもの）を、Silero VAD のしきい値を下げた影で
  探し直す（0.5 → 0.35・0.2。仮）。拾える字数＝新しく見つけた声の時間にある PLAUD の字数（上限・仮）、
  ごみ＝新しく見つけた声のうち PLAUD に話の無い秒（PLAUD が録っている時間だけ）。文字にはしない（モデルは回さない）。切り替えない。
  声のある区切り（声 20% 以上）も少し測り、ふだんの区切りでごみがどれだけ増えるかを見る。
- 当11 vocab: 固有名詞の食い違いを言葉の登録の候補に。母艦 state/misheard_pairs.json（PLAUD と合わない行の組）を asrlearn と
  同じ比べ方（入れ替わった所 2〜12 文字）で語にし、多く出る順に 5 語まで（2 回以上・仮）。今の辞書（母艦の vocab_for_app.json・
  asr-learned）にある語は外す。週 1 回。HOME/s24/vocab-candidates.json と母艦 inbox/asr-learned/plaud_vocab_candidates.json。
文・名前は記録（log.txt）に書かない（数だけ）。
"""

from __future__ import annotations

import argparse
import datetime
import gzip
import io
import json
import os
import re
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

RATE = 16000
SCENES = ("shop", "train", "vehicle", "outside", "home", "other")
SCENE_LABEL = {"shop": "店", "train": "電車", "vehicle": "電車・車", "outside": "外（歩き）", "home": "家", "other": "ほか"}
SHOP = re.compile(r"店|屋|カフェ|喫茶|ラーメン|レストラン|居酒屋|バー|食堂|コンビニ|スーパー|モール|百貨店|ファミリーマート|セブン|ローソン|"
                  r"マクドナルド|スタバ|スターバックス|ドトール|パーキングエリア|サービスエリア|道の駅")
MOVE = re.compile(r"^(\S+?)（(歩きながら|電車・車で|電車で|車で)）")
KM = re.compile(r"約([\d.]+)km")
FAST_KMH = 15.0            # 仮: 位置の「移動中」がこれより速ければ乗り物
SCENE_MIN_LINES = 10       # 仮: 場面ごとの割合を出すのに要る行の数
LOG_JOB = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) .*?(\d{8}-\d{6}(?:-[a-z])?\.m4a): (\d+) 秒（声 (\d+) 秒）→ (\d+) 行")
LOW_SHARE = 0.05           # 当8: 声がこれより少ない区切りを「声なしと判定」の側として測る（仮）
NORMAL_SHARE = 0.2
THRESHOLDS = (0.5, 0.35, 0.2)   # 当8: 今（0.5）と、下げた影（仮）
VAD_GAP, VAD_MIN, VAD_PAD = 0.3, 0.4, 0.1   # lifelog_pc の EXTRA_GAP・EXTRA_MIN・EXTRA_PAD と同じ
VAD_LOW_PER_RUN, VAD_NORMAL_PER_RUN = 30, 10
VAD_DAYS = 14
VOCAB_LIMIT, VOCAB_MIN = 5, 2   # 当11: 週の候補の数・要る回数（仮）
VOCAB_EVERY = 7 * 86400
WORDY = re.compile(r"[\u30a0-\u30ff\u4e00-\u9fff]")   # カタカナか漢字を含む
HIRA_ONLY = re.compile(r"^[\u3040-\u309f\u30fc]+$")
SPEAKER_BUDGET = 300.0


def _read(path: Path, default=None):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def _write(path: Path, body) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    part = path.with_name(path.name + ".part")
    part.write_text(json.dumps(body, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(part, path)


def _epoch(text) -> float | None:
    try:
        return datetime.datetime.fromisoformat(str(text).replace("Z", "+00:00")).timestamp()
    except (TypeError, ValueError):
        return None


def chunk_epoch(name: str) -> float | None:
    """区切りの名前（20261119-120411-w.m4a。この PC の時刻）→ 録り始めの UNIX 秒"""
    m = re.match(r"(\d{8})-(\d{6})", str(name))
    if not m:
        return None
    try:
        return datetime.datetime.strptime(m.group(1) + m.group(2), "%Y%m%d%H%M%S").timestamp()
    except ValueError:
        return None


def find_audio(home: Path, name: str) -> Path | None:
    for path in (Path(home) / "audio" / f"{name[:4]}-{name[4:6]}-{name[6:8]}" / name, Path(home) / "jobs" / f"{name}.audio"):
        if path.is_file():
            return path
    return None


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


def heavy_window(moment: datetime.datetime | None = None) -> bool:
    """重い測りをしてよい時間（00:00〜05:00・08:30〜18:00）"""
    moment = moment or datetime.datetime.now()
    t = moment.time()
    return t < datetime.time(5, 0) or datetime.time(8, 30) <= t < datetime.time(18, 0)


# MARK: - 当7 場面ごとの PLAUD との合い方


def _clock(day: str, hhmm) -> float | None:
    if not isinstance(hhmm, str) or not re.fullmatch(r"\d\d:\d\d", hhmm):
        return None
    h, m = int(hhmm[:2]), int(hhmm[3:])
    base = datetime.datetime.strptime(day, "%Y-%m-%d") + datetime.timedelta(hours=h, minutes=m)
    return base.timestamp()


def timeline_spans(base: Path | None, day: str) -> list[tuple[float, float, str]]:
    """母艦の年表（digests/timeline/<日>.json）から [(始まり, 終わり, 場面)]。会話の動き方を先に、位置をあとに"""
    if base is None:
        return []
    body = _read(Path(base) / "digests" / "timeline" / f"{day}.json", {}) or {}
    talk, place = [], []
    for row in body.get("rows") or []:
        if not isinstance(row, dict):
            continue
        start, end = _clock(day, row.get("time")), _clock(day, row.get("end"))
        if start is None:
            continue
        end = end if end is not None and end > start else start + 60
        text = str(row.get("text") or "")
        if row.get("lane") == "会話":
            m = MOVE.match(text)
            if m:
                how = m.group(2)
                scene = "outside" if how == "歩きながら" else "train" if how == "電車で" else "vehicle"
                talk.append((start, end, scene))
            elif SHOP.search(text.split("（")[0].split(" ")[0]):
                talk.append((start, end, "shop"))
        elif row.get("lane") == "位置":
            name = str(row.get("place") or text.split("（")[0])
            if text.startswith("移動中"):
                km = KM.search(text)
                hours = (end - start) / 3600
                if km and hours > 0 and float(km.group(1)) / hours >= FAST_KMH:
                    place.append((start, end, "vehicle"))
                else:
                    place.append((start, end, "outside"))
            elif "自宅" in name:
                place.append((start, end, "home"))
            elif SHOP.search(name):
                place.append((start, end, "shop"))
    return talk + place


def job_scenes(home: Path, day: str) -> dict[str, str]:
    out = {}
    stamp = day.replace("-", "")
    for path in (Path(home) / "jobs").glob(f"{stamp}*.json"):
        meta = _read(path, {}) or {}
        scene = (meta.get("params") or {}).get("scene") if isinstance(meta.get("params"), dict) else None
        if isinstance(scene, str):
            out[str(meta.get("id") or path.stem)] = scene
    return out


def scene_of(t: float, audio, spans: list[tuple[float, float, str]], jobs: dict[str, str]) -> str:
    scene = jobs.get(str(audio or ""))
    if scene in ("train", "shop", "outside"):
        return scene
    if scene == "car":
        return "vehicle"
    for start, end, name in spans:   # 会話の動き方が先・位置があと（timeline_spans の並び）
        if start - 30 <= t <= end + 30:
            return name
    return "other"


def scene_match(home: Path, base: Path, day: str) -> dict | None:
    """その日の場面ごとの {"lines","chars","matched","match"}（PLAUD の時刻が合わない日は None）"""
    import judgecheck
    import plaudmatch

    recs, _ = plaudmatch._timed(Path(home), Path(base), day)
    if not recs:
        return None
    body = _read(Path(home) / "records" / f"{day}.json", {}) or {}
    spans = timeline_spans(base, day)
    jobs = job_scenes(home, day)
    out = {s: {"lines": 0, "chars": 0, "matched": 0} for s in SCENES}
    for conversation in body.get("conversations") or []:
        if not isinstance(conversation, dict):
            continue
        for line in conversation.get("lines") or []:
            if not isinstance(line, dict) or line.get("media"):
                continue
            t = _epoch(line.get("time"))
            n = judgecheck.norm(str(line.get("text") or ""))
            if t is None or len(n) < plaudmatch.MIN_CHARS:
                continue
            ref = judgecheck.reference(recs, t)
            if ref is None:
                continue
            entry = out[scene_of(t, line.get("audio"), spans, jobs)]
            entry["lines"] += 1
            entry["chars"] += len(n)
            entry["matched"] += plaudmatch.matched(n, ref)
    for entry in out.values():
        entry["match"] = round(entry["matched"] / entry["chars"], 3) if entry["lines"] >= SCENE_MIN_LINES and entry["chars"] else None
    return {k: v for k, v in out.items() if v["lines"]}


def scene_total(by_day: dict[str, dict]) -> dict:
    """日ごとの場面の数を合わせる（{場面: {"lines","chars","matched","match","days"}}）"""
    total: dict = {}
    for entry in by_day.values():
        for scene, v in (entry or {}).items():
            t = total.setdefault(scene, {"lines": 0, "chars": 0, "matched": 0, "days": 0})
            t["lines"] += int(v.get("lines") or 0)
            t["chars"] += int(v.get("chars") or 0)
            t["matched"] += int(v.get("matched") or 0)
            t["days"] += 1
    for t in total.values():
        t["match"] = round(t["matched"] / t["chars"], 3) if t["lines"] >= SCENE_MIN_LINES and t["chars"] else None
    return total


# MARK: - 当5 答えのある組で話し手のモデルを測り直す


def answer_pairs(home: Path, base: Path | None, exists=None) -> list[dict]:
    """本人の答えのある組（時計の声に限らない）。音声が残っている見本だけ。[{"id","same","people","day"}]"""
    import s23voice

    exists = exists or (lambda name: find_audio(home, name) is not None)
    known = s23voice.answers(base)
    out = []
    for gid, group in s23voice.groups_with_samples(home).items():
        if gid not in known:
            continue
        people = [[s for s in p if exists(s["audio"])] for p in group["people"]]
        people = [p for p in people if p]
        if len(people) < 2:
            continue
        out.append({"id": gid, "same": known[gid], "people": people, "day": str(group.get("day") or "")})
    out.sort(key=lambda g: g["day"], reverse=True)
    return out


def self_recordings(home: Path) -> list[Path]:
    """自分の声の登録の録音（本人が HOME/knowme/self-voice/<場面>/ に置いたもの）"""
    folder = Path(home) / "knowme" / "self-voice"
    return sorted(p for p in folder.glob("*/*") if p.suffix.lower() in (".m4a", ".wav")) if folder.is_dir() else []


def self_pairs(home: Path, parsed_days: list[dict], limit: int = 10) -> list[dict]:
    """登録の録音どうし＝同じ・録音と名前のある人の行＝違う（録音が無ければ []）"""
    recs = self_recordings(home)
    if not recs:
        return []
    samples = [{"path": str(p), "audio": p.name, "start": 0.0, "end": 20.0} for p in recs]
    out = []
    for i in range(len(samples)):
        for j in range(i + 1, len(samples)):
            out.append({"id": f"self-{i}-{j}", "same": True, "people": [[samples[i]], [samples[j]]], "day": ""})
    named = []
    for parsed in parsed_days:
        for conversation in (parsed or {}).get("conversations") or []:
            for line in conversation.get("lines") or []:
                name, ident = str(line.get("speaker") or ""), line.get("speakerID")
                if line.get("media") is not None or ident in (None, "me") or re.fullmatch(r"人物\d+", name):
                    continue
                try:
                    start, end = float(line.get("offset")), float(line.get("end"))
                except (TypeError, ValueError):
                    continue
                if 2.0 <= end - start <= 10.0 and isinstance(line.get("audio"), str) and find_audio(home, line["audio"]):
                    named.append({"audio": line["audio"], "start": start, "end": end})
    for k, other in enumerate(named[:limit]):
        out.append({"id": f"self-x-{k}", "same": False, "people": [[samples[k % len(samples)]], [other]], "day": ""})
    return out


def speaker_models(home: Path, config: dict | None = None) -> dict[str, Path]:
    """測るモデル: 今の CAM++ と、HOME/speaker にある別のモデル（s22models の名前）"""
    import s22models

    out = {}
    for name, entry in s22models.SPEAKERS.items():
        path = Path(home) / "speaker" / str(entry.get("file") or "")
        if path.is_file():
            out[name] = path
    return out


def measure_speakers(home: Path, base: Path | None, read_day, config: dict | None = None, budget: float = SPEAKER_BUDGET,
                     threads: int = 1) -> dict:
    """当5: {"pairs","same","self_pairs","self_recordings","models": {名前: {"pairs","auc_raw","auc_snorm",…}}}"""
    import numpy as np
    import sherpa_onnx

    import s23voice

    pairs = answer_pairs(home, base)
    days = sorted({p["day"] for p in pairs if p["day"]})[-7:] or [
        (datetime.date.today() - datetime.timedelta(days=i)).isoformat() for i in range(1, 4)]
    parsed_days = [p for p in (read_day(d) for d in days) if p]
    extra = self_pairs(home, parsed_days)
    every = pairs + extra
    cohort = s23voice.cohort_from(parsed_days, 150)
    result = {"pairs": len(pairs), "same": sum(1 for p in pairs if p["same"]), "self_pairs": len(extra),
              "self_recordings": len(self_recordings(home)), "watch_only": sum(1 for p in pairs if all(
                  s23voice.is_watch(s["audio"]) for g in p["people"] for s in g)), "models": {}}
    deadline = time.time() + budget
    audio_cache: dict = {}
    for name, path in speaker_models(home, config).items():
        if time.time() > deadline:
            result["models"][name] = {"error": "時間切れ"}
            continue
        extractor = sherpa_onnx.SpeakerEmbeddingExtractor(
            sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(path), num_threads=threads, provider="cpu"))
        cache: dict = {}

        def vec(sample, extractor=extractor, cache=cache):
            key = (sample.get("path") or sample["audio"], round(float(sample["start"]), 2), round(float(sample["end"]), 2))
            if key in cache:
                return cache[key]
            cache[key] = None
            if time.time() > deadline:
                return None
            source = key[0]
            if source not in audio_cache:
                found = Path(sample["path"]) if sample.get("path") else find_audio(home, sample["audio"])
                try:
                    audio_cache[source] = load_audio(found.read_bytes()) if found else None
                except Exception:  # noqa: BLE001
                    audio_cache[source] = None
                if len(audio_cache) > 200:
                    audio_cache.pop(next(iter(audio_cache)))
            audio = audio_cache.get(source)
            if audio is None:
                return None
            piece = audio[int(float(sample["start"]) * RATE):int(float(sample["end"]) * RATE)]
            if len(piece) <= RATE // 2:
                return None
            stream = extractor.create_stream()
            stream.accept_waveform(RATE, piece)
            stream.input_finished()
            if not extractor.is_ready(stream):
                return None
            v = np.asarray(extractor.compute(stream), np.float64)
            n = float(np.linalg.norm(v))
            cache[key] = v / n if n > 0 else None
            return cache[key]

        started = time.time()
        got = s23voice.pair_scores(vec, every, cohort)
        got.pop("scored", None)
        got["seconds"] = round(time.time() - started, 1)
        result["models"][name] = got
    return result


# MARK: - 当8 しきい値を下げた影（Silero VAD）


def read_log_jobs(home: Path, since: str) -> dict[str, dict]:
    """log.txt（と logs/*.gz）の「N 秒（声 X 秒）→ K 行」から {区切り: {"dur","voice","lines"}}（あとの行が勝つ）"""
    key = since.replace("-", "")
    out: dict[str, dict] = {}
    files = sorted((Path(home) / "logs").glob("log-*.txt.gz")) + [Path(home) / "log.txt"]
    for path in files:
        try:
            raw = gzip.open(path, "rt", encoding="utf-8", errors="replace") if path.suffix == ".gz" \
                else open(path, encoding="utf-8", errors="replace")
        except OSError:
            continue
        with raw:
            for line in raw:
                if "秒（声" not in line:
                    continue
                m = LOG_JOB.match(line)
                if m and m.group(2)[:8] >= key:
                    out[m.group(2)] = {"dur": int(m.group(3)), "voice": int(m.group(4)), "lines": int(m.group(5))}
    return out


def merge_regions(regions: list[tuple[float, float]], duration: float) -> list[tuple[float, float]]:
    """lifelog_pc の extra_speech と同じ決まり（0.3 秒より短い切れ目はつなぐ・0.4 秒より短いものは捨てる・前後 0.1 秒広げる）"""
    merged: list[list[float]] = []
    for start, end in sorted((float(a), float(b)) for a, b in regions if b > a):
        if merged and start - merged[-1][1] < VAD_GAP:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])
    return [(max(0.0, a - VAD_PAD), min(duration, b + VAD_PAD)) for a, b in merged if b - a >= VAD_MIN]


def subtract(found: list[tuple[float, float]], base: list[tuple[float, float]]) -> list[tuple[float, float]]:
    """found のうち base に入っていない所"""
    out = []
    for s, e in found:
        pieces = [(s, e)]
        for a, b in base:
            rest = []
            for ps, pe in pieces:
                if b <= ps or a >= pe:
                    rest.append((ps, pe))
                    continue
                if ps < a:
                    rest.append((ps, a))
                if b < pe:
                    rest.append((b, pe))
            pieces = rest
        out.extend(p for p in pieces if p[1] - p[0] > 0.05)
    return out


def plaud_in(blocks: list[tuple[float, float, str]], a: float, b: float) -> float:
    """[a, b]（UNIX 秒）にかかる PLAUD の字数（発話の長さに対する重なりの割合で分ける）"""
    chars = 0.0
    for start, end, text in blocks:
        overlap = min(b, end) - max(a, start)
        if overlap > 0:
            chars += len(text) * overlap / max(end - start, 0.5)
    return chars


def make_vad(model: Path, threshold: float):
    import sherpa_onnx

    config = sherpa_onnx.VadModelConfig()
    config.silero_vad.model = str(model)
    config.silero_vad.threshold = threshold
    config.silero_vad.min_silence_duration = 0.3
    config.silero_vad.min_speech_duration = 0.25
    config.silero_vad.max_speech_duration = 30.0
    config.sample_rate = RATE
    config.num_threads = 1
    config.provider = "cpu"
    vad = sherpa_onnx.VoiceActivityDetector(config, buffer_size_in_seconds=60)
    window = int(config.silero_vad.window_size) or 512

    def regions(audio) -> list[tuple[float, float]]:
        import numpy as np

        samples = np.ascontiguousarray(audio, dtype=np.float32)
        found = []
        vad.reset()

        def take():
            while not vad.empty():
                segment = vad.front
                start = int(segment.start) / RATE
                found.append((start, start + len(segment.samples) / RATE))
                vad.pop()

        for i in range(0, len(samples) - window + 1, window):
            vad.accept_waveform(samples[i:i + window])
            take()
        vad.flush()
        take()
        vad.reset()
        return sorted(found)

    return regions


def pick_chunks(home: Path, jobs: dict[str, dict], done: set[str], today: datetime.date,
                covered=None) -> tuple[list[str], list[str]]:
    """(声なし側の区切り, ふだんの区切り)。音声が残っていて、まだ測っていないもの（古い順）。
    covered(名前) を渡したら、PLAUD が録っている時間の区切りだけ（拾える字数とごみは PLAUD でしか測れないため）"""
    since = (today - datetime.timedelta(days=VAD_DAYS)).isoformat().replace("-", "")
    low, normal = [], []
    for name, j in sorted(jobs.items()):
        if name[:8] < since or name in done or j["dur"] < 30:
            continue
        share = j["voice"] / max(j["dur"], 1)
        kind = "low" if share < LOW_SHARE else "normal" if share >= NORMAL_SHARE else None
        if kind is None or (kind == "low" and len(low) >= VAD_LOW_PER_RUN) or (kind == "normal" and len(normal) >= VAD_NORMAL_PER_RUN):
            continue
        if find_audio(home, name) is None or (covered is not None and not covered(name)):
            continue
        (low if kind == "low" else normal).append(name)
    return low, normal


def plaud_day(home: Path, base: Path | None, day: str, cache: dict) -> tuple[list, list]:
    """(PLAUD の発話 [(始, 終, 文)], 録音の時間 [(始, 終)])"""
    if day in cache:
        return cache[day]
    blocks, spans = [], []
    if base is not None:
        try:
            import plaudmatch

            recs, _ = plaudmatch._timed(Path(home), Path(base), day)
            for rec in recs:
                bl = rec.get("blocks") or []
                if not bl:
                    continue
                spans.append((rec["t0"], rec["t0"] + float(bl[-1]["end"])))
                for b in bl:
                    blocks.append((rec["t0"] + float(b["t"]), rec["t0"] + float(b["end"]), str(b.get("n") or "")))
        except Exception:  # noqa: BLE001
            pass
    cache[day] = (blocks, spans)
    return cache[day]


def measure_vad(home: Path, base: Path | None, model: Path, state: dict, today: datetime.date | None = None,
                budget: float = 300.0, jobs: dict | None = None) -> dict:
    """当8: state["chunks"] に区切りごとの数を足す（測ったものは測り直さない）。足した数を返す"""
    today = today or datetime.date.today()
    jobs = jobs if jobs is not None else read_log_jobs(home, (today - datetime.timedelta(days=VAD_DAYS + 1)).isoformat())
    chunks = state.setdefault("chunks", {})
    cache: dict = {}

    def covered(name: str) -> bool:
        start, info = chunk_epoch(name), jobs.get(name) or {}
        if start is None:
            return False
        _, spans = plaud_day(home, base, datetime.date.fromtimestamp(start).isoformat(), cache)
        return any(a <= start and start + float(info.get("dur") or 0) <= b for a, b in spans)

    low, normal = pick_chunks(home, jobs, set(chunks), today, covered if base is not None else None)
    finders = {t: make_vad(model, t) for t in THRESHOLDS}
    deadline = time.time() + budget
    added = 0
    for name, kind in [(n, "low") for n in low] + [(n, "normal") for n in normal]:
        if time.time() > deadline:
            break
        path = find_audio(home, name)
        start = chunk_epoch(name)
        if path is None or start is None:
            continue
        try:
            audio = load_audio(path.read_bytes())
        except Exception:  # noqa: BLE001
            continue
        duration = len(audio) / RATE
        found = {t: merge_regions(f(audio), duration) for t, f in finders.items()}
        day = datetime.date.fromtimestamp(start).isoformat()
        blocks, spans = plaud_day(home, base, day, cache)
        covered = any(a <= start and start + duration <= b for a, b in spans)
        now = found[THRESHOLDS[0]]
        entry = {"day": day, "kind": kind, "dur": round(duration, 1), "voice_log": jobs.get(name, {}).get("voice"),
                 "plaud": covered, "by": {}}
        for t in THRESHOLDS:
            new = subtract(found[t], now) if t != THRESHOLDS[0] else []
            row = {"voiced": round(sum(b - a for a, b in found[t]), 1), "new_s": round(sum(b - a for a, b in new), 1)}
            if covered:
                row["new_plaud_chars"] = round(sum(plaud_in(blocks, start + a, start + b) for a, b in new))
                row["new_empty_s"] = round(sum(b - a for a, b in new if plaud_in(blocks, start + a - 1, start + b + 1) < 1), 1)
                row["plaud_chars"] = round(plaud_in(blocks, start, start + duration))
            entry["by"][str(t)] = row
        chunks[name] = entry
        added += 1
    limit = (today - datetime.timedelta(days=VAD_DAYS)).isoformat()
    state["chunks"] = {k: v for k, v in chunks.items() if str(v.get("day")) >= limit}
    return {"added": added, "left_low": max(0, len(low) - added)}


def vad_total(state: dict) -> dict:
    """{kind: {"chunks","plaud_chunks", しきい値: {"voiced","new_s","new_plaud_chars","new_empty_s"}}}"""
    out: dict = {}
    for entry in (state.get("chunks") or {}).values():
        kind = entry.get("kind")
        t = out.setdefault(kind, {"chunks": 0, "plaud_chunks": 0, "plaud_chars": 0})
        t["chunks"] += 1
        if entry.get("plaud"):
            t["plaud_chunks"] += 1
            t["plaud_chars"] += int((entry["by"].get(str(THRESHOLDS[0])) or {}).get("plaud_chars") or 0)
        for th, row in (entry.get("by") or {}).items():
            agg = t.setdefault(th, {"voiced": 0.0, "new_s": 0.0, "new_plaud_chars": 0, "new_empty_s": 0.0})
            agg["voiced"] = round(agg["voiced"] + float(row.get("voiced") or 0), 1)
            agg["new_s"] = round(agg["new_s"] + float(row.get("new_s") or 0), 1)
            if entry.get("plaud"):
                agg["new_plaud_chars"] += int(row.get("new_plaud_chars") or 0)
                agg["new_empty_s"] = round(agg["new_empty_s"] + float(row.get("new_empty_s") or 0), 1)
    return out


# MARK: - 当11 言葉の登録の候補


def known_words(home: Path, base: Path | None) -> set[str]:
    import asrlearn

    words: set[str] = set()
    if base is not None:
        for item in (_read(Path(base) / "state" / "vocab_for_app.json", {}) or {}).get("items") or []:
            if isinstance(item, dict):
                words.add(asrlearn._norm(str(item.get("word") or "")))
                words.update(asrlearn._norm(str(v)) for v in item.get("variants") or [] if isinstance(v, str))
    for pair in (_read(Path(home) / asrlearn.OUT, {}) or {}).get("items") or []:
        if isinstance(pair, dict):
            words.add(asrlearn._norm(str(pair.get("right") or "")))
    words.discard("")
    return words


def vocab_candidates(home: Path, base: Path | None, today: datetime.date | None = None) -> dict:
    """当11: {"generated_at","week","note","items": [{"word","heard","count","days"}]}（多い順・VOCAB_LIMIT まで）"""
    import asrlearn

    today = today or datetime.date.today()
    body = (_read(Path(base) / "state" / "misheard_pairs.json", {}) or {}) if base is not None else {}
    known = known_words(home, base)
    counts: dict[str, dict] = {}
    for item in body.get("items") or []:
        if not isinstance(item, dict):
            continue
        for wrong, right in asrlearn.pairs_from(str(item.get("app") or ""), str(item.get("plaud") or "")):
            if not WORDY.search(right) or HIRA_ONLY.match(right) or right in known or any(right in k for k in known if len(k) > len(right)):
                continue
            entry = counts.setdefault(right, {"word": right, "heard": [], "count": 0, "days": set()})
            entry["count"] += 1
            entry["days"].add(str(item.get("day") or ""))
            if wrong not in entry["heard"] and len(entry["heard"]) < 3:
                entry["heard"].append(wrong)
    ranked = sorted((e for e in counts.values() if e["count"] >= VOCAB_MIN),
                    key=lambda e: (-e["count"], -len(e["days"]), e["word"]))[:VOCAB_LIMIT]
    iso = today.isocalendar()
    return {"version": 1, "generated_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
            "week": f"{iso[0]}-W{iso[1]:02d}",
            "note": "s24 当11（仮）。PLAUD と合わない行の組から、入れ替わった語（PLAUD の書き方）を多い順に。本人が ○× を付ける候補。"
                    "今の辞書にある語は外した。自動では登録しない",
            "pairs_seen": len(body.get("items") or []),
            "items": [{"word": e["word"], "heard": e["heard"], "count": e["count"], "days": len(e["days"])} for e in ranked]}


def vocab_due(home: Path, now: float | None = None) -> bool:
    try:
        return (now or time.time()) - (Path(home) / "s24" / "vocab-candidates.json").stat().st_mtime >= VOCAB_EVERY
    except OSError:
        return True


# MARK: - 手で動かす台本


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="s24 の夜の測り（読むだけ。結果は --out にだけ書く）")
    parser.add_argument("what", choices=("scenes", "speakers", "vad", "vocab"))
    parser.add_argument("--out", required=True)
    parser.add_argument("--home", default=str(Path(os.environ.get("LOCALAPPDATA", "")) / "LifeLogPC"))
    parser.add_argument("--base", default=r"D:\Lifelog")
    parser.add_argument("--days", type=int, default=14)
    parser.add_argument("--force", action="store_true", help="重い測りの時間の外でも動かす")
    args = parser.parse_args(argv)
    home, base, out = Path(args.home), Path(args.base), Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    today = datetime.date.today()
    if args.what in ("speakers", "vad") and not args.force and not heavy_window():
        print("重い測りの時間（00:00〜05:00・08:30〜18:00）の外なので何もしません", flush=True)
        return 0
    if args.what == "scenes":
        by_day = {}
        for back in range(1, args.days + 1):
            day = (today - datetime.timedelta(days=back)).isoformat()
            got = scene_match(home, base, day)
            if got:
                by_day[day] = got
        body = {"days": by_day, "total": scene_total(by_day)}
    elif args.what == "speakers":
        import records

        def read_day(day):
            try:
                return records.parse_record(json.loads((home / "records" / f"{day}.json").read_text(encoding="utf-8")))
            except (OSError, ValueError):
                return None

        body = measure_speakers(home, base, read_day, budget=1200.0, threads=2)
    elif args.what == "vad":
        state: dict = {}
        info = measure_vad(home, base, home / "vad" / "silero_vad.onnx", state, today, budget=1200.0)
        body = {"info": info, "total": vad_total(state), "chunks": state.get("chunks")}
    else:
        body = vocab_candidates(home, base, today)
        body = {k: v for k, v in body.items() if k != "items"} | {"count": len(body["items"]),
                                                                   "counts": [i["count"] for i in body["items"]]}
    (out / f"s24-{args.what}.json").write_text(json.dumps(body, ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps({k: v for k, v in body.items() if k not in ("chunks", "days")}, ensure_ascii=False)[:3000], flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
