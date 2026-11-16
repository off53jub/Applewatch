"""LifeLog PC: 答えの出どころから、元の音声の該当の所へ（強化案 130。2026-11-16）。

- locate(store, 日, 時刻, 文, 系統): 「聞く」の答えの出どころ 1 件に付ける "audio"。
  この PC の記録（records/<日>.json）から、時刻（HH:MM）が同じで文が近い行を探し、その行の音声の名前と位置を返す。
    見つかって音声が残っている → {"available": true, "audio": 名前, "offset": 秒, "length": 秒, "conversation": "日|始まりのミリ秒",
                                 "path": "/audio-clip?audio=名前&offset=秒&length=秒"}
    見つかったが音声がもう無い → {"available": false, "message": "音声はもう残っていません"}（音声の保存期間は本人の未決事項。無ければ無いと返すだけ）
    行が見つからない・会話の出どころでない → None（audio を付けない）
- GET /audio-clip?audio=名前&offset=秒&length=秒（合言葉は ほかの GET と同じ）→ 16kHz・モノラルの WAV（MAX_SECONDS 秒まで）。
  音声が無ければ 404 {"error": "gone", "message": "音声はもう残っていません"}。名前は records.safe_audio_name の決まりだけ。
読むだけ（音声・記録は変えない）。文・名前・音声の中身は記録（log.txt）に書かない（秒数だけ）。
"""

from __future__ import annotations

import difflib
import io
import re
import time
import unicodedata
import wave
from urllib.parse import parse_qs

GETS = ("/audio-clip",)
MAX_SECONDS = 60.0
MIN_LENGTH = 3.0
PAD = 1.0                 # 行の前後に足す秒
CPS = 4.0                 # 1 秒あたりの文字数の見込み（行の長さが分からないとき）
FILE_MAX = 200 * 1024 * 1024
CONVERSATION_SOURCES = ("app", "limitless", "plaud", "plaud-whisper", "lifelog-pc")
GONE = {"available": False, "message": "音声はもう残っていません"}


def _norm(text: str) -> str:
    text = unicodedata.normalize("NFKC", str(text or "")).casefold()
    text = re.sub(r"^(\[[^\]]*\]\s*)+", "", text)
    text = re.sub(r"\[[^\]]*\]|\s+|[、。,.!?！？「」]", "", text)
    return text


def _clock(ms: int) -> str:
    return time.strftime("%H:%M", time.localtime(ms / 1000))


def locate(store, day: str, moment: str, text: str, source: str = "app") -> dict | None:
    if source not in CONVERSATION_SOURCES or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", day or "") \
            or not re.match(r"^\d{1,2}:\d{2}", moment or ""):
        return None
    parsed = store.day(day)
    if not parsed:
        return None
    hh_mm = ("0" + moment[:5])[-5:] if len(moment.split(":")[0]) == 1 else moment[:5]
    want = _norm(text)[:40]
    best, best_score = None, 0.0
    for conversation in parsed.get("conversations") or []:
        for line in conversation.get("lines") or []:
            if not line.get("audio") or line.get("offset") is None:
                continue
            if _clock(int(line["time"])) != hh_mm:
                continue
            got = _norm(line.get("text"))
            if not got or not want:
                continue
            score = 1.0 if (want[:12] in got or got[:12] in want) else difflib.SequenceMatcher(None, want, got[:60]).ratio()
            if score > best_score:
                best, best_score = (conversation, line), score
    if best is None or best_score < 0.6:
        return None
    conversation, line = best
    name = (parsed.get("audio_names") or {}).get(line["audio"], line["audio"])
    offset = max(0.0, float(line["offset"]) - PAD)
    span = (float(line["end"]) - float(line["offset"])) if line.get("end") is not None else len(_norm(line.get("text"))) / CPS
    length = min(MAX_SECONDS, max(MIN_LENGTH, span + 2 * PAD))
    out_conversation = f"{day}|{conversation['start']}"
    if store.audio_file(line["audio"]) is None and store.audio_file(name) is None:
        return dict(GONE, conversation=out_conversation)
    return {"available": True, "audio": name, "offset": round(offset, 2), "length": round(length, 2),
            "conversation": out_conversation,
            "path": f"/audio-clip?audio={name}&offset={offset:.2f}&length={length:.2f}"}


def clip_wav(path, offset: float, length: float) -> bytes:
    """音声のファイルの offset 秒から length 秒を、16kHz・モノラルの WAV にする"""
    import av
    import numpy as np

    rate = 16000
    first = int(offset * rate)
    last = first + int(min(length, MAX_SECONDS) * rate)
    chunks, total = [], 0
    with av.open(str(path)) as container:
        stream = container.streams.audio[0]
        resampler = av.AudioResampler(format="s16", layout="mono", rate=rate)
        for frame in container.decode(stream):
            for out in resampler.resample(frame):
                data = out.to_ndarray().reshape(-1)
                chunks.append(data)
                total += len(data)
            if total >= last:
                break
    audio = np.concatenate(chunks) if chunks else np.zeros(0, dtype=np.int16)
    audio = audio[first:last]
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(audio.astype("<i2").tobytes())
    return buffer.getvalue()


def _number(query: dict, key: str, default: float) -> float:
    try:
        value = float((query.get(key) or [str(default)])[0])
    except ValueError:
        return default
    return value if value == value and abs(value) < 1e6 else default


def http_get(handler, query_text: str, store, log) -> None:
    query = parse_qs(query_text)
    name = (query.get("audio") or [""])[0]
    offset = max(0.0, _number(query, "offset", 0.0))
    length = min(MAX_SECONDS, max(0.5, _number(query, "length", 10.0)))
    path = None
    try:
        import records

        if store is not None and records.safe_audio_name(name):
            path = store.audio_file(name)
    except Exception:  # noqa: BLE001
        path = None
    if path is None:
        handler.send_json(404, dict(GONE, error="gone"))
        return
    try:
        if path.stat().st_size > FILE_MAX:
            handler.send_json(413, {"error": "音声が大きすぎます"})
            return
        body = clip_wav(path, offset, length)
    except Exception as error:  # noqa: BLE001
        log(f"/audio-clip: 切り出せませんでした（{type(error).__name__}）")
        handler.send_json(500, {"error": "音声を切り出せませんでした"})
        return
    try:
        handler.send_response(200)
        handler.send_header("Content-Type", "audio/wav")
        handler.send_header("Content-Length", str(len(body)))
        handler.end_headers()
        handler.wfile.write(body)
    except OSError:
        handler.close_connection = True
        return
    log(f"{getattr(handler, 'client_address', ('?',))[0]} へ音声の一部を渡しました: {length:.0f} 秒")
