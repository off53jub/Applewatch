"""LifeLog PC: 声の調子の数字（速さ・高さ・間・笑い・雑音）と、毎日の気分の見立て（s18 の 45・78。2026-11-19）。

会話ごとの数（この PC の記録 records/<日>.json と、残っている音声 audio/<日>/ から。読むだけ）:
- self_rate_cps   自分の行の 1 秒あたりの文字数（句読点・空白を除く。行の長さ end−offset が 0.3〜30 秒の行だけ）
- pause_median_s  となりの行の間（前の行の終わり→次の行の始まり。30 秒より長い間は数えない）の中央値
- reply_median_s  ほかの人の行のすぐあとに自分が話し始めるまでの間の中央値
- laugh_per_min   笑いの数（周りの音の「拍手・笑い」の行と、文の「笑」「ハハ」など）を会話の分で割ったもの
- noisy_share     iPhone が「騒がしい」と印を付けた行の割合。sounds＝周りの音の名前ごとの行の数（笑いを除く）
- talk_share      会話の文字のうち自分の文字の割合
- pitch_hz・pitch_spread_st  自分の行の声の高さの中央値（Hz）と幅（半音。上下 1/4 の差）。音声があるときだけ（重い）
- snr_db          会話の音の大きい所と静かな所の差（dB。上から 1 割と下から 1 割）。音声があるときだけ（重い）
- trust           "low"＝信用が低い（78）: 騒がしい行が NOISY_LOW 以上・または snr_db が SNR_LOW 未満・またはテレビなどの会話。
                  low の会話から立てた見立ては確定にしない（"tier_cap": "tentative"。母艦の tierlib の段より上げない）。
重い所（声の高さと snr）は voices.heavy_ok() の時間（00:00〜05:00・08:30〜18:00）だけ、1 回の見回りの秒に上限をつけて。
軽い所（文字と時刻だけ）はいつでも。

毎日の気分の見立て（45）: その日の自分の数を、前の BASE_DAYS 日の自分の数の平均・ばらつきと比べた z と、
母艦の archive/health/YYYY/MM/DD.md の睡眠の長さ・安静の心拍（前の日々と比べた z）を足し合わせる。
「見立て（仮）」の印・layer "hypothesis"・kind "mood"・tier は最高でも "tentative"・根拠の会話（conversation_start）を付ける。
信用が低い会話は気分の数に入れない（入れた会話が 1 つも無い日は声の数を使わない）。

置き場所（どれも作り直すたびに置き換え。文は入れない。名前は相手ごとの表のキーだけ）:
- HOME/voice-tone/<日>.json        その日の会話ごとの数と、自分の 1 日の数と、気分の見立て
- HOME/voice-tone-daily.json        日ごとの自分の数と気分（60 日）。母艦の Build-Accuracy が quality-daily.json を読むのと同じ読み方
- HOME/voice-tone-partners.json     相手ごとの自分の数（直近 PARTNER_DAYS 日。母艦 M1 の Build-KnowSpeech が読む "partners" の形）
- 母艦 inbox/voice-tone/ に同じ 3 種類の写し（家の PC が書く・母艦は読むだけ。形は母艦 docs/_incoming/s18-P.md）
"""

from __future__ import annotations

import datetime
import json
import math
import re
import statistics
import time
from pathlib import Path
from typing import Callable

import numpy as np

FOLDER = "voice-tone"
DAILY_FILE = "voice-tone-daily.json"
PARTNER_FILE = "voice-tone-partners.json"
MOTHER_DIR = Path("inbox") / "voice-tone"
VERSION = 1
RATE = 16000

# 仮のしきい値（今あるデータで測った数は docs/s18-know-me-pc.md）
NOISY_LOW = 0.5           # 仮: 騒がしい行がこの割合以上の会話は信用が低い
SNR_LOW = 10.0            # 仮: 大きい所と静かな所の差がこれ未満（dB）の会話は信用が低い
MOOD_UP = 0.5             # 仮: 合わせた z がこれ以上なら「元気」
MOOD_DOWN = -0.5          # 仮: これ以下なら「しんどい」
BASE_DAYS = 28            # 比べる前の日数
BASE_MIN = 5              # 比べるのに要る前の日の数
PARTNER_DAYS = 28
PARTNER_MIN = 2           # 相手ごとの表に要る会話の数
DAILY_KEEP = 60
GAP_MAX = 30.0
LINE_MIN, LINE_MAX = 0.3, 30.0
PITCH_MIN_HZ, PITCH_MAX_HZ = 70.0, 400.0
PITCH_SECONDS = 12.0      # 1 行から高さを測る長さの上限
LAUGH_SOUND = "笑い"
LAUGH_TEXT = re.compile(r"笑|[ハは][ハは]+|[フふ][フふ]+|ｗｗ|ww")
PLAIN = re.compile(r"[\s、。，．,.!！?？・「」『』（）()〜~ー\-…]")
UNNAMED = re.compile(r"人物\d+")
SELF_ID = "me"
SELF_NAME = "自分"
JST = datetime.timezone(datetime.timedelta(hours=9))


def _iso(ms: int) -> str:
    return datetime.datetime.fromtimestamp(ms / 1000, JST).isoformat(timespec="seconds")


def _median(values: list[float]) -> float | None:
    return round(statistics.median(values), 3) if values else None


def _dur(line: dict) -> float | None:
    off, end = line.get("offset"), line.get("end")
    if off is None or end is None:
        return None
    d = end - off
    return d if LINE_MIN <= d <= LINE_MAX else None


def is_self(line: dict) -> bool:
    return line.get("speakerID") == SELF_ID or line.get("speaker") == SELF_NAME


def partner_names(conversation: dict) -> list[str]:
    """名前のある相手（自分・人物N を除く）"""
    names = set()
    for line in conversation["lines"]:
        name = line.get("speaker")
        if name and not is_self(line) and not UNNAMED.fullmatch(name):
            names.add(name)
    return sorted(names)


# MARK: - 音（重い所）


def pitch_track(samples: np.ndarray) -> np.ndarray:
    """声の高さ（Hz）の並び（声の無い所は入れない）。40ms の窓・10ms ずつ、正規化した自己相関の山"""
    win, hop = int(0.04 * RATE), int(0.01 * RATE)
    if samples.size < win * 2:
        return np.zeros(0)
    count = 1 + (samples.size - win) // hop
    frames = np.lib.stride_tricks.as_strided(samples, shape=(count, win),
                                             strides=(samples.strides[0] * hop, samples.strides[0])).astype(np.float64)
    frames = frames - frames.mean(axis=1, keepdims=True)
    energy = (frames ** 2).sum(axis=1)
    keep = energy > max(np.percentile(energy, 50), 1e-8)
    frames, energy = frames[keep], energy[keep]
    if not len(frames):
        return np.zeros(0)
    spec = np.fft.rfft(frames, n=win * 2, axis=1)
    ac = np.fft.irfft(np.abs(spec) ** 2, axis=1)[:, :win]
    ac = ac / np.maximum(ac[:, :1], 1e-12)
    lo, hi = int(RATE / PITCH_MAX_HZ), int(RATE / PITCH_MIN_HZ)
    part = ac[:, lo:hi]
    best = part.argmax(axis=1)
    peak = part[np.arange(len(part)), best]
    voiced = peak > 0.5
    return RATE / (best[voiced] + lo)


def frame_db(samples: np.ndarray) -> np.ndarray:
    win = int(0.05 * RATE)
    if samples.size < win:
        return np.zeros(0)
    count = samples.size // win
    frames = samples[:count * win].reshape(count, win).astype(np.float64)
    rms = np.sqrt((frames ** 2).mean(axis=1))
    return 20 * np.log10(np.maximum(rms, 1e-6))


def audio_numbers(conversation: dict, find_audio: Callable[[str], Path | None],
                  load_audio: Callable[[bytes], np.ndarray], cache: dict, names: dict | None = None) -> dict:
    """自分の行の声の高さと、会話の snr（音声が無ければ空）"""
    pitches: list[np.ndarray] = []
    dbs: list[np.ndarray] = []
    for line in conversation["lines"]:
        name = line.get("audio")
        dur = _dur(line)
        if not name or dur is None:
            continue
        name = (names or {}).get(name, name)   # iPhone の音声の名前 → PC の仕事の名前（records の audioNames）
        if name not in cache:
            path = find_audio(name)
            try:
                cache[name] = load_audio(path.read_bytes()) if path is not None else None
            except Exception:  # noqa: BLE001 — 読めない音声は飛ばす
                cache[name] = None
        samples = cache[name]
        if samples is None:
            continue
        a = int(max(0.0, line["offset"]) * RATE)
        b = int(min(line["offset"] + min(dur, PITCH_SECONDS), samples.size / RATE) * RATE)
        if b - a < int(0.3 * RATE):
            continue
        piece = samples[a:b]
        dbs.append(frame_db(piece))
        if is_self(line) and not line.get("noisy"):
            pitches.append(pitch_track(piece))
    out: dict = {}
    allp = np.concatenate(pitches) if pitches else np.zeros(0)
    if allp.size >= 20:
        q1, q3 = np.percentile(allp, [25, 75])
        out["pitch_hz"] = round(float(np.median(allp)), 1)
        out["pitch_spread_st"] = round(float(12 * math.log2(q3 / q1)), 2) if q1 > 0 else None
    alld = np.concatenate(dbs) if dbs else np.zeros(0)
    if alld.size >= 20:
        lo, hi = np.percentile(alld, [10, 90])
        out["snr_db"] = round(float(hi - lo), 1)
    return out


# MARK: - 会話ごと（軽い所）


def conversation_numbers(conversation: dict) -> dict | None:
    lines = [l for l in conversation["lines"] if (l.get("text") or "").strip()]
    if len(lines) < 2:
        return None
    minutes = max((conversation["end"] - conversation["start"]) / 60000, 0.25)
    self_chars = self_secs = 0.0
    all_chars = 0
    gaps, replies = [], []
    laughs = noisy = 0
    sounds: dict[str, int] = {}
    for i, line in enumerate(lines):
        chars = len(PLAIN.sub("", line["text"]))
        all_chars += chars
        dur = _dur(line)
        if is_self(line):
            if dur is not None and chars:
                self_chars += chars
                self_secs += dur
        sound = line.get("sound") or ""
        if LAUGH_SOUND in sound or LAUGH_TEXT.search(line["text"]):
            laughs += 1
        if sound and LAUGH_SOUND not in sound:
            sounds[sound] = sounds.get(sound, 0) + 1
        if line.get("noisy"):
            noisy += 1
        if i:
            prev = lines[i - 1]
            pdur = _dur(prev)
            if pdur is not None:
                gap = (line["time"] - prev["time"]) / 1000 - pdur
                if 0 <= gap <= GAP_MAX:
                    gaps.append(gap)
                    if is_self(line) and not is_self(prev):
                        replies.append(gap)
    self_text = sum(len(PLAIN.sub("", l["text"])) for l in lines if is_self(l))
    out = {
        "conversation_start": _iso(conversation["start"]), "start_ms": conversation["start"],
        "minutes": round(minutes, 1), "lines": len(lines), "self_lines": sum(1 for l in lines if is_self(l)),
        "partners": partner_names(conversation), "work": conversation.get("work"),
        "self_rate_cps": round(self_chars / self_secs, 2) if self_secs >= 2 else None,
        "pause_median_s": _median(gaps), "reply_median_s": _median(replies),
        "laugh": laughs, "laugh_per_min": round(laughs / minutes, 3),
        "noisy_share": round(noisy / len(lines), 3), "sounds": sounds,
        "talk_share": round(self_text / all_chars, 3) if all_chars else None,
        "media": bool(conversation.get("media")),
    }
    return out


def set_trust(numbers: dict) -> None:
    why = []
    if numbers.get("media"):
        why.append("テレビなどの会話")
    if numbers["noisy_share"] >= NOISY_LOW:
        why.append(f"騒がしい行が {numbers['noisy_share']:.0%}")
    if numbers.get("snr_db") is not None and numbers["snr_db"] < SNR_LOW:
        why.append(f"声と周りの音の差が {numbers['snr_db']} dB")
    numbers["trust"] = "low" if why else "normal"
    numbers["trust_why"] = "・".join(why)[:40] if why else None
    if why:
        numbers["tier_cap"] = "tentative"


def day_numbers(parsed: dict, find_audio=None, load_audio=None, deadline: float | None = None) -> tuple[list[dict], bool]:
    """(会話ごとの数, 音も測り終えたか)"""
    out = []
    cache: dict = {}
    heavy_done = find_audio is not None and load_audio is not None
    for conversation in parsed.get("conversations", []):
        numbers = conversation_numbers(conversation)
        if numbers is None:
            continue
        if find_audio is not None and load_audio is not None:
            if deadline is not None and time.time() > deadline:
                heavy_done = False
            else:
                numbers.update(audio_numbers(conversation, find_audio, load_audio, cache, parsed.get("audio_names")))
        set_trust(numbers)
        out.append(numbers)
    return out, heavy_done


def self_summary(conversations: list[dict]) -> dict:
    """その日の自分の数（信用が低い会話・自分の行が無い会話は入れない。会話の分で重み）"""
    use = [c for c in conversations if c["trust"] != "low" and c["self_lines"]]
    out: dict = {"conversations": len(conversations), "used": len(use),
                 "low_trust": sum(1 for c in conversations if c["trust"] == "low")}
    for key in ("self_rate_cps", "pause_median_s", "reply_median_s", "laugh_per_min", "pitch_hz", "pitch_spread_st",
                "talk_share", "snr_db"):
        pairs = [(c[key], c["minutes"]) for c in use if c.get(key) is not None]
        weight = sum(w for _, w in pairs)
        out[key] = round(sum(v * w for v, w in pairs) / weight, 3) if weight else None
    out["noisy_share"] = round(sum(c["noisy_share"] * c["minutes"] for c in conversations)
                               / max(sum(c["minutes"] for c in conversations), 1e-9), 3) if conversations else None
    out["minutes_talked"] = round(sum(c["minutes"] for c in use), 1)
    return out


# MARK: - 睡眠と心拍（母艦の archive/health。読むだけ）

SLEEP = re.compile(r"睡眠\s*(\d+)h\s*(\d+)m")
REST = re.compile(r"安静[:：]\s*(\d+)\s*bpm")


def health(mother: Path | None, day: str) -> dict:
    if mother is None:
        return {}
    y, m, d = day.split("-")
    try:
        text = (mother / "archive" / "health" / y / m / f"{d}.md").read_text(encoding="utf-8-sig")
    except OSError:
        return {}
    out = {}
    s = SLEEP.search(text)
    if s:
        out["sleep_h"] = round(int(s.group(1)) + int(s.group(2)) / 60, 2)
    r = REST.search(text)
    if r:
        out["rest_hr"] = int(r.group(1))
    return out


# MARK: - 気分の見立て


SIGNALS = (("self_rate_cps", 1, "話す速さ"), ("laugh_per_min", 1, "笑い"), ("pause_median_s", -1, "間"),
           ("pitch_spread_st", 1, "声の高さの幅"), ("sleep_h", 1, "睡眠"), ("rest_hr", -1, "安静の心拍"))


def mood(day: str, today: dict, history: dict) -> dict:
    """today＝その日の自分の数＋睡眠・心拍。history＝{日: 同じ形}（前の日々）"""
    before = sorted(d for d in history if d < day)[-BASE_DAYS:]
    parts = []
    for key, sign, word in SIGNALS:
        value = today.get(key)
        past = [history[d].get(key) for d in before if history[d].get(key) is not None]
        if value is None or len(past) < BASE_MIN:
            continue
        mean = statistics.fmean(past)
        sd = statistics.pstdev(past) or 1e-9
        z = max(-3.0, min(3.0, (value - mean) / sd))
        parts.append({"signal": key, "word": word, "z": round(sign * z, 2), "value": value, "base": round(mean, 3)})
    out = {"layer": "hypothesis", "label": "見立て（仮）", "kind": "mood", "made_on": day,
           "recheck_by": (datetime.date.fromisoformat(day) + datetime.timedelta(days=90)).isoformat(),
           "status": "alive", "signals": parts, "evidence_kinds": sorted({"voice" if p["signal"] not in ("sleep_h", "rest_hr")
                                                                          else "health" for p in parts})}
    if not parts:
        out.update({"mood": None, "score": None, "confidence": 0.0, "tier": "ask",
                    "tier_why": "比べる前の日が足りない"})
        return out
    score = round(statistics.fmean(p["z"] for p in parts), 2)
    word = "元気" if score >= MOOD_UP else "しんどい" if score <= MOOD_DOWN else "ふつう"
    conf = min(0.8, 0.15 + 0.1 * len(parts) + 0.1 * min(abs(score), 1.5))
    if not today.get("used"):
        conf *= 0.5
    out.update({"mood": word, "score": score, "confidence": round(conf, 2), "tier": "tentative" if conf >= 0.4 else "ask",
                "tier_why": "見立ては黙って事実にしない" if conf >= 0.4 else "数がそろっていない"})
    return out


# MARK: - 作る・置く


def _write(path: Path, data: dict) -> bool:
    text = json.dumps(data, ensure_ascii=False, indent=1)
    try:
        if path.read_text(encoding="utf-8") == text:
            return False
    except OSError:
        pass
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(path)
    return True


def read_json(path: Path) -> dict | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def build_day(home: Path, store, day: str, mother: Path | None, find_audio=None, load_audio=None,
              deadline: float | None = None) -> dict | None:
    parsed = store.day(day)
    if parsed is None:
        return None
    old = read_json(home / FOLDER / f"{day}.json") or {}
    convs, heavy = day_numbers(parsed, find_audio, load_audio, deadline)
    if not heavy and old.get("heavy_done"):
        # 前に音まで測った数を残す（軽い見回りで消さない）
        before = {c.get("start_ms"): c for c in old.get("conversations") or []}
        for c in convs:
            prev = before.get(c["start_ms"]) or {}
            for key in ("pitch_hz", "pitch_spread_st", "snr_db"):
                if key in prev and key not in c:
                    c[key] = prev[key]
            set_trust(c)
        heavy = all(c["start_ms"] in before for c in convs)
    summary = self_summary(convs)
    summary.update(health(mother, day))
    history = {d: v.get("self") or {} for d, v in ((read_json(home / DAILY_FILE) or {}).get("days") or {}).items()}
    feeling = mood(day, summary, history)
    feeling["evidence"] = [{"day": day, "conversation_start": c["conversation_start"], "source": "app"}
                           for c in sorted(convs, key=lambda c: -c["minutes"]) if c["trust"] != "low"][:5]
    built = {"version": VERSION, "day": day, "heavy_done": bool(heavy), "conversations": convs, "self": summary,
             "mood": feeling, "thresholds": {"noisy_low": NOISY_LOW, "snr_low": SNR_LOW, "mood_up": MOOD_UP,
                                             "mood_down": MOOD_DOWN, "仮": True}}
    _write(home / FOLDER / f"{day}.json", built)
    daily = read_json(home / DAILY_FILE) or {"version": VERSION, "days": {}}
    days = daily.setdefault("days", {})
    days[day] = {"self": summary, "mood": {k: feeling.get(k) for k in ("mood", "score", "confidence", "tier", "label")}}
    for old_day in sorted(days)[:-DAILY_KEEP]:
        days.pop(old_day, None)
    _write(home / DAILY_FILE, daily)
    return built


def build_partners(home: Path, today: datetime.date) -> dict:
    """相手ごとの自分の数（直近 PARTNER_DAYS 日・信用が低い会話は入れない）。全体の平均との差も付ける"""
    rows: list[dict] = []
    for i in range(PARTNER_DAYS):
        day = (today - datetime.timedelta(days=i)).isoformat()
        data = read_json(home / FOLDER / f"{day}.json")
        rows += [c for c in (data or {}).get("conversations") or [] if c.get("trust") != "low" and c.get("self_lines")]
    keys = ("self_rate_cps", "pause_median_s", "reply_median_s", "laugh_per_min", "pitch_hz", "pitch_spread_st", "talk_share")

    def avg(items: list[dict], key: str):
        vals = [c[key] for c in items if c.get(key) is not None]
        return round(statistics.fmean(vals), 3) if vals else None

    overall = {k: avg(rows, k) for k in keys}
    partners: dict = {}
    for name in sorted({p for c in rows for p in c.get("partners") or []}):
        mine = [c for c in rows if name in (c.get("partners") or [])]
        if len(mine) < PARTNER_MIN:
            continue
        entry = {"conversations": len(mine), "minutes": round(sum(c["minutes"] for c in mine), 1)}
        for k in keys:
            entry[k] = avg(mine, k)
            if entry[k] is not None and overall[k] is not None:
                entry[f"{k}_vs_all"] = round(entry[k] - overall[k], 3)
        entry["last_day"] = max(c["conversation_start"][:10] for c in mine)
        partners[name] = entry
    out = {"version": VERSION, "made_on": today.isoformat(), "window_days": PARTNER_DAYS, "overall": overall,
           "partners": partners, "rows": len(rows)}
    _write(home / PARTNER_FILE, out)
    return out


def copy_to_mother(home: Path, mother: Path | None, days: list[str]) -> int:
    """母艦の inbox/voice-tone/ に写す（家の PC が書く・母艦は読むだけ）。写したファイルの数"""
    if mother is None or not mother.is_dir():
        return 0
    dest = mother / MOTHER_DIR
    n = 0
    for name, target in ((DAILY_FILE, "voice_tone_daily.json"), (PARTNER_FILE, "voice_tone_by_partner.json")):
        data = read_json(home / name)
        if data is not None and _write(dest / target, data):
            n += 1
    for day in days:
        data = read_json(home / FOLDER / f"{day}.json")
        if data is not None and _write(dest / "days" / f"{day}.json", data):
            n += 1
    return n


def run(home: Path, store, mother: Path | None, log: Callable[[str], None], days: list[str], find_audio=None,
        load_audio=None, budget: float = 0.0, mother_copy: bool = True) -> dict:
    deadline = time.time() + budget if budget else None
    made = []
    for day in days:
        try:
            built = build_day(home, store, day, mother, find_audio if budget else None,
                              load_audio if budget else None, deadline)
        except Exception as error:  # noqa: BLE001 — 1 日が失敗しても続ける
            log(f"声の調子: {day} を作れませんでした: {type(error).__name__}")
            continue
        if built is not None:
            made.append(built)
    partners = build_partners(home, datetime.date.today())
    copied = copy_to_mother(home, mother, days) if mother_copy else 0
    if made:
        # 文・名前は書かない（数だけ）
        log(f"声の調子: {len(made)} 日・会話 {sum(len(b['conversations']) for b in made)}"
            f"（信用が低い {sum(b['self']['low_trust'] for b in made)}）・相手 {len(partners['partners'])}・母艦へ {copied}")
    return {"days": made, "partners": partners, "copied": copied}
