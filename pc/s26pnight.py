"""LifeLog PC: s26（2026-11-25。担当 P）の夜の測り。夜 00:00〜05:00 に s26pc.py が呼ぶ。言語モデルは呼ばない（0 円）。

どれも「影で比べる」「材料を集める」だけで、記録の行・話し手・モデル・録り方は変えない。文・名前は記録（log.txt）に書かない（数だけ）。
config.json の名前（書かなければ下の既定）:

- 聞7（取り決め K10）機械の正解（"s26p_machine_gold"。初めはオン＝材料を残すだけ）:
  後で受け取る文字起こしの行で、**モデル 2 つの票が同じ文**（judgecheck.norm で同じ・6 字以上）になり、その文が時刻の合う
  **PLAUD の文と GOLD_MATCH 以上合う**（仮）行を「機械の正解」にする。音声を切り出して（16 kHz・1 ch の wav）
  HOME/goldset-machine/<場面>/<id>.wav に、文と数を HOME/goldset-machine/index.jsonl に 1 行足す
  （{"id","scene","day","audio","start","end","text","engines","plaud","file","at"}）。場面は s24night.scene_of
  （店・電車・電車と車・外・家・ほか）。合わせて GOLD_TOTAL 個（300・仮）・場面ごとに GOLD_PER_SCENE 個まで・1 晩 GOLD_NIGHT 個まで。
  本人は打たない。正解集（goldset.py の本人が直した 46 個）とは混ぜない（母艦 M2 の「3 つのうち 2 つ」の物差しとは別の置き場）。
- 聞1・聞2 場面ごとのマイクの比べ（"s26p_mic_scenes"。初めはオン＝数えるだけ。切り替えはしない）:
  記録の行を、場面（s24night の場面）× マイク（時計・iPhone・外付け＝POST /jobs の mic が external・airpods・bluetooth）に分け、
  PLAUD と合った字の割合を日ごとに HOME/s26p/mic-scenes.json へ（PLAUD は遅れて届くので 3 日前まで数え直す）。
  7 日（MIC_DAYS・仮）測れた場面だけ、良いほうのマイクを「正本の候補」として summary.md に出す。
  机の上・ポケット・袖の中は PC からは見えない（仮説）ので、場面は「どこにいたか」で分けた。外付けのマイクは届いてから数が出る。
- 聞3 声の判定を通さずに全部聞く（"s26p_full_listen"。初めはオン＝影で文字にするだけ）:
  声が 5% 未満と判定された区切り（60 秒以上）のうち、前か後の区切り（同じ端末・間 3 分まで）に会話の行が 3 行以上あるものを、
  声の判定を通さずに 25 秒ずつ全部文字にし、無音で出る決まり文句（s22text.EXTRA_JUNK）を落とす。PLAUD と合った字（拾えた字）と、
  PLAUD に話の無い所の字（ごみ）を数える。出た文は HOME/s26p/full-listen/<日>.json に置くだけ（記録には足さない）。1 晩 FULL_NIGHT 個まで。
- 聞15 小さい相手の声を持ち上げる（"s26p_boost"。初めはオン＝影で比べるだけ）:
  s22 の「遠い声（仮）」の札の行のうち、前か後の行（BOOST_TURN 秒以内）が自分の行＝自分と交互に話している相手だけを、音量を上げて
  （声の真ん中を -20 dBFS に。上げるのは BOOST_MAX_DB まで）もう一度文字にし、前の文と上げた文の PLAUD と合った字を比べる。
  自分と交互でない小さい声（隣の客など）は、今までどおり触らない。1 晩 BOOST_NIGHT 行まで。
- 聞6 重なって話す所（"s26p_separate"。初めはオフ＝モデルを使う所）:
  s22 の「重なり」の札の数と秒は毎晩数える（オンでなくても）。オンのときだけ、Hugging Face の SpeechBrain 公式の
  2 人の声を分けるモデル（SEPARATE_REPO）で重なりの所を 2 本に分けてから文字にし、分けない文と PLAUD と合った字を比べる
  （speechbrain の部品が入っていなければ動かない。入れ替えはしない）。
- 集3 せき・いびき（"s26p_sounds"。初めはオン＝数だけ）: 夜（22:00〜08:00）に録れた区切りを周りの音のモデル（今の /scene と同じ）で
  2 秒ずつ聞き、せき（Cough）の回数といびき（Snoring）の分を日ごとに HOME/s26p/sounds.json と母艦 inbox/pc-sounds/<日>.json へ。
  文は残さない。
"""

from __future__ import annotations

import datetime
import hashlib
import json
import os
import time
import wave
from pathlib import Path

import numpy as np

RATE = 16000
GOLD_DIR = "goldset-machine"
GOLD_INDEX = "index.jsonl"
GOLD_MATCH = 0.9          # 仮: 合った字 ÷ 行の字
GOLD_MIN_CHARS = 6
GOLD_LEN = (1.5, 15.0)    # 仮: 行の長さ（秒）
GOLD_TOTAL = 300          # 仮（聞7 の 46 → 300）
GOLD_PER_SCENE = 100
GOLD_NIGHT = 120
GOLD_DAYS = 14
INVENTING = ("whisper", "kotoba", "mine", "qwen")   # 作り話をしがちな仲間（2 つともこの仲間なら、もう 1 つ別の仲間を求めない・仮）
MIC_DAYS = 7
MIC_BACK = 3
MIC_MIN_CHARS = 200       # 仮: 場面×マイクの割合を出すのに要る字
MIC_DEVICES = ("watch", "iphone", "external")
FULL_NIGHT = 8
FULL_WINDOW = 25.0
FULL_LOW_SHARE = 0.05
FULL_MIN_SECONDS = 60.0
FULL_NEIGHBOR_GAP = 180.0
FULL_NEIGHBOR_LINES = 3
FULL_DAYS = 3
BOOST_NIGHT = 40
BOOST_TURN = 8.0
BOOST_TARGET_DB = -20.0
BOOST_MAX_DB = 24.0
BOOST_DAYS = 3
SEPARATE_REPO = "speechbrain/sepformer-whamr16k"
SEPARATE_NIGHT = 20
SOUND_LABELS = {"cough": ("Cough", "Throat clearing"), "snore": ("Snoring", "Snort")}
SOUND_PROB = 0.3          # 仮
SOUND_WINDOW = 2.0
SOUND_HOURS = (22, 8)     # 22:00〜翌 08:00 の区切り
SOUND_NIGHT_SECONDS = 900.0
SELF_NAME = "自分"
SELF_ID = "me"


def folder(home: Path) -> Path:
    return Path(home) / "s26p"


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


def _epoch(value) -> float | None:
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return float(value) / 1000.0 if value > 1e11 else float(value)
    try:
        return datetime.datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
    except (TypeError, ValueError):
        return None


def _days(today: datetime.date, back: int) -> list[str]:
    return [(today - datetime.timedelta(days=i)).isoformat() for i in range(1, back + 1)]


def write_wav(path: Path, samples: np.ndarray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    pcm = (np.clip(np.asarray(samples, dtype=np.float32), -1.0, 1.0) * 32767).astype("<i2")
    part = path.with_name(path.name + ".part")
    with wave.open(str(part), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(RATE)
        handle.writeframes(pcm.tobytes())
    os.replace(part, path)


def clip(audio: np.ndarray, start: float, end: float) -> np.ndarray:
    a, b = max(0, int(start * RATE)), min(len(audio), int(end * RATE))
    return np.ascontiguousarray(audio[a:b], dtype=np.float32) if b > a else np.zeros(0, dtype=np.float32)


def job_results(home: Path, days: set[str]):
    """(区切りの名前, 始まりの UNIX 秒, 状態, 答え, 音声のファイル) を、days に入る区切りだけ（新しい順）"""
    import judgecheck

    for path in sorted((Path(home) / "jobs").glob("*.result"), reverse=True):
        meta = _read(path.with_suffix(".json"), None)
        result = _read(path, None)
        if not isinstance(meta, dict) or not isinstance(result, dict):
            continue
        name = str(meta.get("id") or "")
        begin = judgecheck.chunk_epoch(name)
        if begin is None or datetime.date.fromtimestamp(begin).isoformat() not in days:
            continue
        yield name, begin, meta, result, path.with_suffix(".audio")


def device_of(name: str, meta: dict | None = None) -> str:
    mic = ((meta or {}).get("params") or {}).get("mic") if isinstance((meta or {}).get("params"), dict) else None
    if mic in ("external", "airpods", "bluetooth"):
        return "external"
    return "watch" if str(name).endswith("-w.m4a") else "iphone"


# MARK: - 聞7（K10）機械の正解


def agreed(votes: dict) -> tuple[str, list[str]] | None:
    """モデル 2 つが同じ文（norm で同じ・GOLD_MIN_CHARS 字以上）。(元の文, [モデル, モデル])。雑音を除いた票（_e）は数えない"""
    import judgecheck

    seen: dict[str, list[tuple[str, str]]] = {}
    for engine, text in (votes or {}).items():
        if not isinstance(text, str) or str(engine).endswith("_e"):
            continue
        n = judgecheck.norm(text)
        if len(n) >= GOLD_MIN_CHARS:
            seen.setdefault(n, []).append((str(engine), text))
    best = None
    for n, rows in seen.items():
        if len(rows) < 2:
            continue
        rows.sort(key=lambda r: (r[0] in INVENTING, r[0]))   # 作り話をしにくいモデルの文を先に
        if best is None or len(n) > len(best[0]):
            best = (n, rows)
    if best is None:
        return None
    return best[1][0][1].strip(), [r[0] for r in best[1][:2]]


def gold_index(home: Path) -> list[dict]:
    path = Path(home) / GOLD_DIR / GOLD_INDEX
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    out = []
    for line in lines:
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict) and isinstance(row.get("id"), str):
            out.append(row)
    return out


def machine_gold(home: Path, base: Path | None, today: datetime.date, load_audio, deadline: float | None = None,
                 night_max: int = GOLD_NIGHT) -> dict:
    """機械の正解を足す。{"added","candidates","days","by_scene","total"}"""
    import judgecheck
    import plaudmatch
    import s24night

    out = {"added": 0, "candidates": 0, "days": 0, "by_scene": {}, "total": 0}
    have = gold_index(home)
    ids = {r["id"] for r in have}
    by_scene: dict[str, int] = {}
    for r in have:
        by_scene[str(r.get("scene"))] = by_scene.get(str(r.get("scene")), 0) + 1
    out["total"] = len(have)
    if base is None or len(have) >= GOLD_TOTAL:
        out["by_scene"] = by_scene
        return out
    wanted = set(_days(today, GOLD_DAYS))
    cache: dict = {}
    index_path = Path(home) / GOLD_DIR / GOLD_INDEX
    for name, begin, meta, result, audio_path in job_results(home, wanted):
        if out["added"] >= night_max or len(have) + out["added"] >= GOLD_TOTAL:
            break
        if deadline is not None and time.time() > deadline:
            break
        day = datetime.date.fromtimestamp(begin).isoformat()
        if day not in cache:
            recs, _ = plaudmatch._timed(Path(home), Path(base), day)
            cache[day] = (recs, s24night.timeline_spans(base, day), s24night.job_scenes(home, day))
            out["days"] += 1 if recs else 0
        recs, spans, scenes = cache[day]
        if not recs:
            continue
        audio = None
        for line in result.get("lines") or []:
            if not isinstance(line, dict):
                continue
            try:
                start, end = float(line["start"]), float(line["end"])
            except (KeyError, TypeError, ValueError):
                continue
            if not GOLD_LEN[0] <= end - start <= GOLD_LEN[1]:
                continue
            got = agreed(line.get("votes") or {})
            if got is None:
                continue
            text, engines = got
            n = judgecheck.norm(text)
            ref = judgecheck.reference(recs, begin + start)
            if ref is None:
                continue
            rate = plaudmatch.matched(n, ref) / max(1, len(n))
            if rate < GOLD_MATCH:
                continue
            out["candidates"] += 1
            ident = hashlib.sha1(f"{name}|{start:.2f}".encode()).hexdigest()[:16]
            scene = s24night.scene_of(begin + start, name, spans, scenes)
            if ident in ids or by_scene.get(scene, 0) >= GOLD_PER_SCENE:
                continue
            if audio is None:
                path = audio_path if audio_path.is_file() else s24night.find_audio(home, name)
                if path is None:
                    break
                try:
                    audio = load_audio(Path(path).read_bytes())
                except Exception:  # noqa: BLE001
                    break
            samples = clip(audio, start, end)
            if len(samples) < int(GOLD_LEN[0] * RATE):
                continue
            rel = f"{scene}/{ident}.wav"
            write_wav(Path(home) / GOLD_DIR / rel, samples)
            row = {"id": ident, "scene": scene, "day": day, "audio": name, "start": round(start, 2), "end": round(end, 2),
                   "text": text[:200], "engines": engines, "plaud": round(rate, 3), "file": rel,
                   "at": datetime.datetime.now().astimezone().isoformat(timespec="seconds")}
            index_path.parent.mkdir(parents=True, exist_ok=True)
            with index_path.open("a", encoding="utf-8", newline="\n") as handle:
                handle.write(json.dumps(row, ensure_ascii=False) + "\n")
            ids.add(ident)
            by_scene[scene] = by_scene.get(scene, 0) + 1
            out["added"] += 1
            if out["added"] >= night_max or len(have) + out["added"] >= GOLD_TOTAL:
                break
    out["by_scene"] = by_scene
    out["total"] = len(have) + out["added"]
    return out


# MARK: - 聞1・聞2 場面ごとのマイク


def mic_scene_day(home: Path, base: Path, day: str, parsed: dict | None = None, metas: dict | None = None) -> dict | None:
    """{場面: {マイク: {"lines","chars","matched"}}}（PLAUD の時刻が合わない日は None）"""
    import judgecheck
    import plaudmatch
    import s24night

    recs, _ = plaudmatch._timed(Path(home), Path(base), day)
    if not recs:
        return None
    if parsed is None:
        parsed = _read(Path(home) / "records" / f"{day}.json", {}) or {}
    if metas is None:
        metas = {}
        stamp = day.replace("-", "")
        for path in (Path(home) / "jobs").glob("*.json"):
            meta = _read(path, {}) or {}
            if str(meta.get("id") or "").startswith(stamp):
                metas[str(meta["id"])] = meta
    spans = s24night.timeline_spans(base, day)
    scenes = s24night.job_scenes(home, day)
    out: dict = {}
    for conversation in parsed.get("conversations") or []:
        if not isinstance(conversation, dict) or conversation.get("media"):
            continue
        for line in conversation.get("lines") or []:
            if not isinstance(line, dict) or line.get("media") or not isinstance(line.get("audio"), str):
                continue
            t = _epoch(line.get("time"))
            n = judgecheck.norm(str(line.get("text") or ""))
            if t is None or len(n) < plaudmatch.MIN_CHARS:
                continue
            ref = judgecheck.reference(recs, t)
            if ref is None:
                continue
            scene = s24night.scene_of(t, line["audio"], spans, scenes)
            device = device_of(line["audio"], metas.get(line["audio"]))
            entry = out.setdefault(scene, {}).setdefault(device, {"lines": 0, "chars": 0, "matched": 0})
            entry["lines"] += 1
            entry["chars"] += len(n)
            entry["matched"] += plaudmatch.matched(n, ref)
    return out


def mic_scenes_nightly(home: Path, base: Path, today: datetime.date) -> dict:
    path = folder(home) / "mic-scenes.json"
    body = _read(path, {}) or {}
    days = body.get("days") if isinstance(body.get("days"), dict) else {}
    done = {}
    for day in _days(today, MIC_BACK):
        got = mic_scene_day(home, base, day)
        if got is not None:
            days[day] = got
            done[day] = sum(v["lines"] for s in got.values() for v in s.values())
    limit = (today - datetime.timedelta(days=30)).isoformat()
    days = {k: v for k, v in days.items() if k >= limit}
    _write(path, {"generated_at": datetime.datetime.now().isoformat(timespec="seconds"),
                  "note": "s26 聞1・聞2（仮）。数だけ。切り替えはしない", "days": days})
    return done


def mic_scene_pick(home: Path, today: datetime.date, need_days: int = MIC_DAYS) -> dict:
    """直近 14 日の合計。{"days": 測れた日, "scenes": {場面: {"devices": {マイク: {...,"match"}}, "pick": マイク|None}}}"""
    days = (_read(folder(home) / "mic-scenes.json", {}) or {}).get("days") or {}
    limit = (today - datetime.timedelta(days=14)).isoformat()
    used = [d for d in days if d >= limit and isinstance(days[d], dict) and days[d]]
    scenes: dict = {}
    for day in used:
        for scene, devices in days[day].items():
            for device, row in (devices or {}).items():
                t = scenes.setdefault(scene, {}).setdefault(device, {"lines": 0, "chars": 0, "matched": 0, "days": 0})
                t["lines"] += int(row.get("lines") or 0)
                t["chars"] += int(row.get("chars") or 0)
                t["matched"] += int(row.get("matched") or 0)
                t["days"] += 1
    out = {}
    for scene, devices in scenes.items():
        for t in devices.values():
            t["match"] = round(t["matched"] / t["chars"], 3) if t["chars"] else None
        ok = {d: t for d, t in devices.items() if t["chars"] >= MIC_MIN_CHARS and t["match"] is not None}
        pick = None
        if len(used) >= need_days and len(ok) >= 2:
            pick = max(ok, key=lambda d: ok[d]["match"])
        out[scene] = {"devices": devices, "pick": pick}
    return {"days": len(used), "scenes": out}


# MARK: - 聞3 声の判定を通さずに全部聞く


def full_listen_pick(home: Path, today: datetime.date, done: set[str], limit: int = FULL_NIGHT) -> list[dict]:
    """[{name, meta, audio_path, begin}]（古い区切りから）"""
    import judgecheck
    import s24night

    wanted = set(_days(today, FULL_DAYS))
    metas = []
    for path in (Path(home) / "jobs").glob("*.json"):
        meta = _read(path, None)
        if not isinstance(meta, dict) or meta.get("status") != "done":
            continue
        name = str(meta.get("id") or "")
        begin = judgecheck.chunk_epoch(name)
        if begin is None or datetime.date.fromtimestamp(begin).isoformat() not in wanted:
            continue
        metas.append((begin, name, meta, path.with_suffix(".audio")))
    metas.sort()
    picked = []
    for i, (begin, name, meta, audio_path) in enumerate(metas):
        if name in done:
            continue
        seconds = float(meta.get("audio_seconds") or 0)
        voiced = float(meta.get("voiced_seconds") or 0)
        if seconds < FULL_MIN_SECONDS or voiced / max(seconds, 1.0) >= FULL_LOW_SHARE:
            continue
        device = device_of(name, meta)
        talk = False
        for j in (i - 1, i + 1):
            if 0 <= j < len(metas):
                b2, n2, m2, _ = metas[j]
                gap = abs(b2 - begin) - max(seconds, float(m2.get("audio_seconds") or 0))
                if device_of(n2, m2) == device and gap <= FULL_NEIGHBOR_GAP and int(m2.get("lines") or 0) >= FULL_NEIGHBOR_LINES:
                    talk = True
        if not talk:
            continue
        path = audio_path if audio_path.is_file() else s24night.find_audio(home, name)
        if path is None:
            continue
        picked.append({"name": name, "meta": meta, "audio_path": Path(path), "begin": begin})
        if len(picked) >= limit:
            break
    return picked


def is_junk(text: str) -> bool:
    import judgecheck
    import s22text

    return s22text.is_extra_junk(text) or len(judgecheck.norm(text)) < 2


def compare_plaud(lines: list[dict], begin: float, blocks: list, spans: list) -> dict:
    """影の行を PLAUD と比べる: 拾えた字（PLAUD の話と合った字）・ごみ（PLAUD が録っているのに話の無い所の字）"""
    import judgecheck
    import plaudmatch
    import s24night

    out = {"lines": 0, "chars": 0, "matched": 0, "junk": 0, "covered": 0}
    for line in lines:
        n = judgecheck.norm(str(line.get("text") or ""))
        if not n:
            continue
        a, b = begin + float(line["start"]), begin + float(line["end"])
        out["lines"] += 1
        out["chars"] += len(n)
        if not any(s - 5 <= a <= e + 5 for s, e in spans):
            continue
        out["covered"] += len(n)
        near = "".join(text for s, e, text in blocks if e >= a - 20 and s <= b + 20)
        if s24night.plaud_in(blocks, a - 2, b + 2) < 1:
            out["junk"] += len(n)
        elif near:
            out["matched"] += plaudmatch.matched(n, near)
    return out


def full_listen(home: Path, base: Path | None, today: datetime.date, asr, load_audio, deadline: float | None = None) -> dict:
    """{"chunks","lines","dropped","matched","junk","covered"}（この晩の分）。state は HOME/s26p/full-listen.json"""
    import s24night

    state_path = folder(home) / "full-listen.json"
    state = _read(state_path, {}) or {}
    chunks = state.get("chunks") if isinstance(state.get("chunks"), dict) else {}
    out = {"chunks": 0, "lines": 0, "dropped": 0, "matched": 0, "junk": 0, "covered": 0}
    cache: dict = {}
    for item in full_listen_pick(home, today, set(chunks)):
        if deadline is not None and time.time() > deadline:
            break
        try:
            audio = load_audio(item["audio_path"].read_bytes())
        except Exception:  # noqa: BLE001
            chunks[item["name"]] = {"error": "音声を読めませんでした"}
            continue
        duration = len(audio) / RATE
        windows = [(t, min(duration, t + FULL_WINDOW)) for t in np.arange(0.0, duration, FULL_WINDOW) if duration - t >= 1.0]
        try:
            lines = asr(audio, [(float(a), float(b)) for a, b in windows])
        except Exception as error:  # noqa: BLE001
            chunks[item["name"]] = {"error": type(error).__name__}
            continue
        kept = [x for x in lines if isinstance(x, dict) and not is_junk(str(x.get("text") or ""))]
        dropped = len(lines) - len(kept)
        day = datetime.date.fromtimestamp(item["begin"]).isoformat()
        blocks, spans = s24night.plaud_day(home, base, day, cache) if base is not None else ([], [])
        got = compare_plaud(kept, item["begin"], blocks, spans)
        chunks[item["name"]] = {**got, "dropped": dropped, "day": day, "at": datetime.datetime.now().isoformat(timespec="seconds")}
        shadow_path = folder(home) / "full-listen" / f"{day}.json"
        shadow = _read(shadow_path, {}) or {}
        shadow.setdefault("chunks", {})[item["name"]] = [
            {"start": round(float(x["start"]), 2), "end": round(float(x["end"]), 2), "text": str(x.get("text") or "")[:300]}
            for x in kept]
        _write(shadow_path, shadow)
        out["chunks"] += 1
        out["dropped"] += dropped
        for k in ("lines", "matched", "junk", "covered"):
            out[k] += got[k]
    limit = (today - datetime.timedelta(days=30)).isoformat().replace("-", "")
    chunks = {k: v for k, v in chunks.items() if k[:8] >= limit}
    _write(state_path, {"chunks": chunks})
    return out


def full_listen_total(home: Path, today: datetime.date, days: int = 7) -> dict:
    chunks = (_read(folder(home) / "full-listen.json", {}) or {}).get("chunks") or {}
    limit = (today - datetime.timedelta(days=days)).isoformat()
    total = {"chunks": 0, "lines": 0, "matched": 0, "junk": 0, "covered": 0, "dropped": 0}
    for row in chunks.values():
        if isinstance(row, dict) and "error" not in row and str(row.get("day") or "") >= limit:
            total["chunks"] += 1
            for k in ("lines", "matched", "junk", "covered", "dropped"):
                total[k] += int(row.get(k) or 0)
    return total


# MARK: - 聞15 小さい相手の声を持ち上げる


def _is_self(line: dict) -> bool:
    return line.get("speakerID") == SELF_ID or line.get("speaker") == SELF_NAME


def boost_lines(parsed: dict, far_ms: set[int]) -> list[dict]:
    """「遠い声」の札の行のうち、前か後の行（BOOST_TURN 秒以内）が自分の行のもの（自分と交互に話している相手）"""
    out = []
    for conversation in parsed.get("conversations") or []:
        if not isinstance(conversation, dict) or conversation.get("media"):
            continue
        lines = sorted([x for x in conversation.get("lines") or [] if isinstance(x, dict) and isinstance(x.get("time"), int)],
                       key=lambda x: x["time"])
        for i, line in enumerate(lines):
            if line["time"] not in far_ms or _is_self(line) or line.get("media") is not None:
                continue
            if not isinstance(line.get("audio"), str) or not isinstance(line.get("offset"), (int, float)) \
                    or not isinstance(line.get("end"), (int, float)):
                continue
            turn = False
            for j in (i - 1, i + 1):
                if 0 <= j < len(lines) and _is_self(lines[j]) and abs(lines[j]["time"] - line["time"]) <= BOOST_TURN * 1000 + \
                        (float(line["end"]) - float(line["offset"])) * 1000:
                    turn = True
            if turn:
                out.append(line)
    return out


def gain_for(samples: np.ndarray, target_db: float = BOOST_TARGET_DB, most: float = BOOST_MAX_DB) -> float:
    """声の真ん中（0.1 秒ごとの大きさの上半分の真ん中）を target_db にする dB（0〜most）"""
    if len(samples) == 0:
        return 0.0
    step = int(0.1 * RATE)
    frames = [samples[i:i + step] for i in range(0, len(samples) - step + 1, step)] or [samples]
    levels = sorted(20 * np.log10(max(float(np.sqrt(np.mean(np.square(f, dtype=np.float64)))), 1e-7)) for f in frames)
    voiced = levels[len(levels) // 2:] or levels
    middle = voiced[len(voiced) // 2]
    return float(max(0.0, min(most, target_db - middle)))


def boost(home: Path, base: Path | None, store, today: datetime.date, asr, load_audio, deadline: float | None = None) -> dict:
    """{"lines","gain_db","before","after","chars"}（この晩の分。before/after は PLAUD と合った字）"""
    import judgecheck
    import plaudmatch
    import s24night

    state_path = folder(home) / "boost.json"
    state = _read(state_path, {}) or {}
    rows = state.get("lines") if isinstance(state.get("lines"), dict) else {}
    out = {"lines": 0, "gain_db": 0.0, "before": 0, "after": 0, "chars": 0}
    if base is None or store is None:
        return out
    for day in _days(today, BOOST_DAYS):
        tags = _read(Path(home) / "s22" / "speaker-tags" / f"{day}.json", {}) or {}
        far = {int(t["ms"]) for t in tags.get("tags") or [] if isinstance(t, dict) and t.get("kind") == "far"
               and isinstance(t.get("ms"), int)}
        if not far:
            continue
        parsed = store.day(day) or {}
        recs, _ = plaudmatch._timed(Path(home), Path(base), day)
        if not recs:
            continue
        audios: dict = {}
        for line in boost_lines(parsed, far):
            if out["lines"] >= BOOST_NIGHT or (deadline is not None and time.time() > deadline):
                break
            key = f"{line['audio']}|{float(line['offset']):.2f}"
            if key in rows:
                continue
            ref = judgecheck.reference(recs, _epoch(line["time"]) or 0)
            if ref is None:
                continue
            if line["audio"] not in audios:
                path = s24night.find_audio(home, line["audio"])
                try:
                    audios[line["audio"]] = load_audio(Path(path).read_bytes()) if path is not None else None
                except Exception:  # noqa: BLE001
                    audios[line["audio"]] = None
            audio = audios[line["audio"]]
            if audio is None:
                continue
            start, end = max(0.0, float(line["offset"]) - 0.2), float(line["end"]) + 0.2
            samples = clip(audio, start, end)
            gain = gain_for(samples)
            if gain < 3.0 or len(samples) < RATE // 2:
                continue
            loud = np.clip(samples * (10 ** (gain / 20)), -1.0, 1.0).astype(np.float32)
            try:
                got = asr(loud, [(0.0, len(loud) / RATE)])
            except Exception:  # noqa: BLE001
                continue
            after_text = "".join(str(x.get("text") or "") for x in got if isinstance(x, dict))
            before_n, after_n = judgecheck.norm(str(line.get("text") or "")), judgecheck.norm(after_text)
            row = {"day": day, "gain_db": round(gain, 1), "chars": len(before_n),
                   "before": plaudmatch.matched(before_n, ref) if before_n else 0,
                   "after": plaudmatch.matched(after_n, ref) if after_n else 0, "after_chars": len(after_n)}
            rows[key] = row
            out["lines"] += 1
            out["gain_db"] += row["gain_db"]
            out["before"] += row["before"]
            out["after"] += row["after"]
            out["chars"] += row["chars"]
    limit = (today - datetime.timedelta(days=30)).isoformat()
    rows = {k: v for k, v in rows.items() if str(v.get("day") or "") >= limit}
    _write(state_path, {"lines": rows})
    if out["lines"]:
        out["gain_db"] = round(out["gain_db"] / out["lines"], 1)
    return out


def boost_total(home: Path, today: datetime.date, days: int = 7) -> dict:
    rows = (_read(folder(home) / "boost.json", {}) or {}).get("lines") or {}
    limit = (today - datetime.timedelta(days=days)).isoformat()
    total = {"lines": 0, "before": 0, "after": 0, "better": 0, "worse": 0}
    for row in rows.values():
        if isinstance(row, dict) and str(row.get("day") or "") >= limit:
            total["lines"] += 1
            total["before"] += int(row.get("before") or 0)
            total["after"] += int(row.get("after") or 0)
            total["better"] += int(row.get("after", 0) > row.get("before", 0))
            total["worse"] += int(row.get("after", 0) < row.get("before", 0))
    return total


# MARK: - 聞6 重なって話す所


def overlap_count(home: Path, today: datetime.date, days: int = 7) -> dict:
    """s22 の「重なり」の札の数（行）と日"""
    total = {"tags": 0, "days": 0}
    for day in _days(today, days):
        tags = _read(Path(home) / "s22" / "speaker-tags" / f"{day}.json", {}) or {}
        got = sum(1 for t in tags.get("tags") or [] if isinstance(t, dict) and t.get("kind") == "overlap")
        if got:
            total["tags"] += got
            total["days"] += 1
    return total


class Separator:
    """2 人の声を分けるモデル（SpeechBrain の公式・SEPARATE_REPO）。部品が無ければ作れない（RuntimeError）"""

    def __init__(self, home: Path) -> None:
        import importlib

        try:
            module = importlib.import_module("speechbrain.inference.separation")
        except Exception as error:  # noqa: BLE001
            raise RuntimeError(f"speechbrain の部品が入っていません（{type(error).__name__}）") from error
        self.model = module.SepformerSeparation.from_hparams(
            source=SEPARATE_REPO, savedir=str(folder(home) / "separate" / SEPARATE_REPO.replace("/", "--")))

    def split(self, samples: np.ndarray) -> list[np.ndarray]:
        import importlib

        torch = importlib.import_module("torch")
        with torch.no_grad():
            got = self.model.separate_batch(torch.from_numpy(samples[None, :].astype(np.float32)))
        return [got[0, :, i].cpu().numpy().astype(np.float32) for i in range(got.shape[-1])]


def separate(home: Path, base: Path | None, store, today: datetime.date, asr, load_audio, separator=None,
             deadline: float | None = None) -> dict:
    """オンのときだけ（s26pc が "s26p_separate" を見て呼ぶ）。重なりの組を分けて文字にし、PLAUD と合った字を比べる"""
    import judgecheck
    import plaudmatch
    import s24night

    out = {"pairs": 0, "before": 0, "after": 0}
    if base is None or store is None:
        return out
    separator = separator or Separator(home)
    state_path = folder(home) / "separate.json"
    rows = (_read(state_path, {}) or {}).get("pairs") or {}
    for day in _days(today, 3):
        tags = _read(Path(home) / "s22" / "speaker-tags" / f"{day}.json", {}) or {}
        ms = sorted({int(t["ms"]) for t in tags.get("tags") or [] if isinstance(t, dict) and t.get("kind") == "overlap"
                     and isinstance(t.get("ms"), int)})
        if not ms:
            continue
        recs, _ = plaudmatch._timed(Path(home), Path(base), day)
        if not recs:
            continue
        parsed = store.day(day) or {}
        by_ms = {x["time"]: x for c in parsed.get("conversations") or [] for x in c.get("lines") or []
                 if isinstance(x, dict) and isinstance(x.get("time"), int)}
        for a, b in zip(ms, ms[1:]):
            if out["pairs"] >= SEPARATE_NIGHT or (deadline is not None and time.time() > deadline):
                break
            la, lb = by_ms.get(a), by_ms.get(b)
            if not la or not lb or la.get("audio") != lb.get("audio") or f"{a}" in rows:
                continue
            path = s24night.find_audio(home, la["audio"])
            if path is None:
                continue
            try:
                audio = load_audio(Path(path).read_bytes())
            except Exception:  # noqa: BLE001
                continue
            start, end = float(la["offset"]), float(lb["end"])
            samples = clip(audio, start, end)
            ref = judgecheck.reference(recs, _epoch(a) or 0)
            if ref is None or len(samples) < RATE:
                continue
            before_n = judgecheck.norm(str(la.get("text") or "") + str(lb.get("text") or ""))
            texts = []
            for stream in separator.split(samples):
                texts += [str(x.get("text") or "") for x in asr(stream, [(0.0, len(stream) / RATE)]) if isinstance(x, dict)]
            after_n = judgecheck.norm("".join(texts))
            rows[f"{a}"] = {"day": day, "before": plaudmatch.matched(before_n, ref), "after": plaudmatch.matched(after_n, ref)}
            out["pairs"] += 1
            out["before"] += rows[f"{a}"]["before"]
            out["after"] += rows[f"{a}"]["after"]
    _write(state_path, {"pairs": rows})
    return out


# MARK: - 集3 せき・いびき


def night_chunk(begin: float, hours: tuple[int, int] = SOUND_HOURS) -> str | None:
    """夜の区切りなら、その夜の「起きた日」（22 時台・23 時台は次の日）。夜でなければ None"""
    moment = datetime.datetime.fromtimestamp(begin)
    if moment.hour >= hours[0]:
        return (moment.date() + datetime.timedelta(days=1)).isoformat()
    if moment.hour < hours[1]:
        return moment.date().isoformat()
    return None


def count_sounds(tags: list[list[dict]], window: float = SOUND_WINDOW, prob: float = SOUND_PROB) -> dict:
    """窓ごとの周りの音の上位から、せきの回数（続いた窓は 1 回）といびきの秒"""
    cough = snore = 0.0
    last_cough = False
    for row in tags:
        names = {str(x.get("name")): float(x.get("prob") or 0) for x in row or [] if isinstance(x, dict)}
        is_cough = any(names.get(label, 0) >= prob for label in SOUND_LABELS["cough"])
        if is_cough and not last_cough:
            cough += 1
        last_cough = is_cough
        if any(names.get(label, 0) >= prob for label in SOUND_LABELS["snore"]):
            snore += window
    return {"cough": int(cough), "snore_seconds": round(snore, 1)}


def sounds(home: Path, base: Path | None, today: datetime.date, tagger, load_audio, deadline: float | None = None,
           budget: float = SOUND_NIGHT_SECONDS) -> dict:
    """昨夜（と、その前の夜で数え残した分）の区切りを数える。{"chunks","days": {日: {"cough","snore_minutes","chunks","seconds"}}}"""
    import judgecheck
    import s24night

    started = time.time()
    path = folder(home) / "sounds.json"
    body = _read(path, {}) or {}
    days = body.get("days") if isinstance(body.get("days"), dict) else {}
    done = set(body.get("done") or [])
    out = {"chunks": 0, "days": {}}
    wanted = {today.isoformat(), (today - datetime.timedelta(days=1)).isoformat()}
    names = []
    for audio_dir in (Path(home) / "audio").glob("????-??-??"):
        names += [p.name for p in audio_dir.glob("*.m4a")]
    names += [str((_read(p, {}) or {}).get("id") or "") for p in (Path(home) / "jobs").glob("*.json")]
    for name in sorted(set(n for n in names if n)):
        begin = judgecheck.chunk_epoch(name)
        night = night_chunk(begin) if begin is not None else None
        if night not in wanted or name in done:
            continue
        if time.time() - started > budget or (deadline is not None and time.time() > deadline):
            break
        found = s24night.find_audio(home, name)
        if found is None:
            continue
        try:
            audio = load_audio(Path(found).read_bytes())
        except Exception:  # noqa: BLE001
            continue
        duration = len(audio) / RATE
        ranges = [(t, t + SOUND_WINDOW) for t in np.arange(0.0, max(0.0, duration - SOUND_WINDOW / 2), SOUND_WINDOW)]
        try:
            got = count_sounds(tagger(audio, [(float(a), float(b)) for a, b in ranges]))
        except Exception:  # noqa: BLE001
            continue
        entry = days.setdefault(night, {"cough": 0, "snore_seconds": 0.0, "chunks": 0, "seconds": 0.0})
        entry["cough"] += got["cough"]
        entry["snore_seconds"] = round(entry["snore_seconds"] + got["snore_seconds"], 1)
        entry["chunks"] += 1
        entry["seconds"] = round(entry["seconds"] + duration, 1)
        done.add(name)
        out["chunks"] += 1
    limit = (today - datetime.timedelta(days=60)).isoformat()
    days = {k: v for k, v in days.items() if k >= limit}
    keep = (today - datetime.timedelta(days=3)).isoformat().replace("-", "")
    _write(path, {"days": days, "done": sorted(n for n in done if n[:8] >= keep)})
    for night in sorted(wanted):
        entry = days.get(night)
        if not entry:
            continue
        row = {"version": 1, "day": night, "cough_count": entry["cough"], "snore_minutes": round(entry["snore_seconds"] / 60, 1),
               "chunks": entry["chunks"], "listened_minutes": round(entry["seconds"] / 60, 1),
               "note": "s26 集3（仮）。家の PC が夜の録音の周りの音から数えた数だけ（文は無い）"}
        out["days"][night] = row
        if base is not None and Path(base).is_dir():
            try:
                _write(Path(base) / "inbox" / "pc-sounds" / f"{night}.json", row)
            except OSError:
                pass
    return out
