"""LifeLog PC: 混ざる音に「印」を付ける（s19「休日のライフログ」の 休12・13・14・15。2026-11-21）。

行を消さない・記録を書き換えない。会話ごとの「印」を HOME/holiday-marks/<日>.json に置き、下流（母艦のまとめ・
本人の話の判定・声の調子）がそれを見て外す。印は省略可能なフィールドだけ。無くても今まで通り動く。

印の種類（kind）と、下流がすること（effect）:
- loud_venue    休12 騒がしい場（居酒屋・カラオケ・ライブ・イベント）。会話の言葉（場所・場面・予定・題）か母艦の滞在の名前に
                場の言葉があり、かつ iPhone の「騒がしい」(78)・周りの音（音楽・拍手・笑い）が多い会話。
                effect "speaker_caution"＝話し手の判定を控えめに（○を勝手に付けない・本人の声と決めない）。声の調子は信用 low にする
- in_car_media  休13 車内のナビ・カーステレオらしい声。会話の「車内」の印（iPhone が付ける inCar・vehicle）があるとき、
                テレビ印の行・ナビらしい言い回しの行・音楽の中の自分でない行。印が無くても、乗り物の動き＋車の音で「車内（仮）」と見て同じ印を付ける
                effect "not_self"＝本人の発話にしない（行ごと。line_times）
- media_suspect 休14 動画・配信・ゲームの音（仮）。休日（母艦 state/holiday/days.json か土日）に家で、本人の行が 1 つも無く・
                名前のある人もいない会話で、同じ声が一方的に続く（いちばん多い声が 8 割以上）。effect "not_self"（会話ごと）
- couple_topic  休15 3 人以上の会話で「彼女」「同棲」「家事」「喧嘩」が出た行。effect "needs_check"＝本人の話と決めず、確かめ待ち
                （profile の決まり。人名はまとめない・付け替えない）。確かめの文 question と pending を付ける

どの印にも "label"（「見立て（仮）」）・"why"・"evidence" を付ける。しきい値は DEFAULTS（すべて仮。config.json の "holiday_marks" で上書き）。
置き場所: HOME/holiday-marks/<日>.json（作り直すたびに置き換え）。母艦 inbox/holiday-marks/days/<日>.json に同じ写し・
inbox/holiday-marks/needs_check.json（確かめ待ちの束）。GET /holiday-marks?day=（knowme の口）。
文（会話の中身）は印に入れない。記録（log.txt）には数だけ。重い計算は無い（文字と時刻だけ）。
"""

from __future__ import annotations

import datetime
import json
import re
from pathlib import Path
from typing import Callable

FOLDER = "holiday-marks"
MOTHER_DIR = Path("inbox") / "holiday-marks"
DAYS_FILE = Path("state") / "holiday" / "days.json"       # 母艦 M1 が作る {"YYYY-MM-DD": {"off": true, "why": …}}
STAYS_FILE = Path("state") / "stays_labeled.json"          # 母艦の滞在 {"days": {日: {"stays": [{s, e, label, where}]}}}
VERSION = 1
JST = datetime.timezone(datetime.timedelta(hours=9))
SELF_ID = "me"
SELF_NAME = "自分"
LABEL = "見立て（仮）"

# しきい値（すべて仮。測った数は docs/s19-holiday-pc.md）
DEFAULTS = {
    "_note": "仮（2026-11-21・P）。直すのは本人かまとめ役",
    "venue_noisy_share": 0.25,     # 仮: 場の言葉がある会話で、騒がしい行がこの割合以上なら騒がしい場
    "venue_sound_share": 0.35,     # 仮: または周りの音（音楽・拍手・笑い）の行がこの割合以上
    "venue_min_lines": 6,          # 仮: 行が少ない会話は印を付けない
    "car_sound_share": 0.1,        # 仮: 印が無いとき、車の音の行がこの割合以上なら「車内（仮）」の候補
    "car_navi_min_lines": 2,       # 仮: 印が無いとき、ナビらしい言い回しの行がこれ以上
    "media_min_lines": 8,          # 仮: 動画・配信の疑いに要る行の数
    "media_top_share": 0.8,        # 仮: いちばん多い声の行の割合
    "media_holiday_only": True,    # 仮: 休日だけ（休日でない日の動きは変えない）
    "couple_min_speakers": 3,      # 仮: 3 人以上の会話だけ
    "pending_days": 14,            # 確かめ待ちの束に入れる日数
}

VENUE_WORDS = {
    "飲み会": re.compile("居酒屋|飲み会|飲み|酒場|宴会|打ち上げ|ビアガーデン|バル"),
    "カラオケ": re.compile("カラオケ"),
    "ライブ": re.compile("ライブ|コンサート|フェス"),
    "イベント": re.compile("クラブ|ダンス|イベント|パーティ"),
}
LOUD_SOUNDS = {"音楽", "拍手・笑い"}
CAR_SOUND = "車"
CAR_VEHICLES = ("car", "車", "自動車", "carplay", "drive")
NAVI = re.compile("まもなく|方向です|目的地|ルートを|案内を(開始|終了)|渋滞|メートル先|キロ先|制限速度|を右折|を左折|直進(です|して)|ETC|高速道路(です|に)")
COUPLE = re.compile("彼女|同棲|家事|喧嘩|ケンカ")
UNNAMED = re.compile(r"人物\d+")
QUESTION = "この会話は、あなたの話ではないかもしれません。あなたの話ですか？（はい・いいえ・わからない）"


CONFIG: dict = {}   # knowme の見回りが config.json を入れる（voicetone から呼ぶときに使う）


def settings(config: dict | None) -> dict:
    out = dict(DEFAULTS)
    mine = (CONFIG if config is None else config).get("holiday_marks")
    if isinstance(mine, dict):
        out.update({k: v for k, v in mine.items() if k in DEFAULTS and not k.startswith("_")})
    return out


def _is_self(line: dict) -> bool:
    return line.get("speakerID") == SELF_ID or line.get("speaker") == SELF_NAME


def _read(path: Path) -> dict | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


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


# MARK: - 今日が休日か・その時刻にどこにいたか（母艦があれば使う。無くても動く）


def is_holiday(day: str, mother: Path | None) -> tuple[bool, str]:
    """(休日か, なぜ)。母艦の state/holiday/days.json があればそれ。無ければ土日だけ（祝日は分からない）"""
    if mother is not None:
        data = _read(mother / DAYS_FILE)
        entry = (data or {}).get(day) if data else None
        if isinstance(entry, dict) and "off" in entry:
            return bool(entry.get("off")), str(entry.get("why") or "母艦の休日の印")
    try:
        weekday = datetime.date.fromisoformat(day).weekday()
    except ValueError:
        return False, ""
    return weekday >= 5, "土日" if weekday >= 5 else ""


def stays_of(day: str, mother: Path | None) -> list[dict]:
    if mother is None:
        return []
    data = _read(mother / STAYS_FILE)
    entry = ((data or {}).get("days") or {}).get(day) or {}
    return [s for s in entry.get("stays") or [] if isinstance(s, dict)]


def stay_at(stays: list[dict], ms: int) -> dict | None:
    t = datetime.datetime.fromtimestamp(ms / 1000, JST)
    hm = f"{t.hour:02d}:{t.minute:02d}"
    for s in stays:
        a, b = s.get("s"), s.get("e")
        if isinstance(a, str) and isinstance(b, str) and a <= hm < b:
            return s
    return None


def _text(conversation: dict) -> str:
    return " ".join(str(conversation.get(k) or "") for k in ("place", "scene", "event", "title"))


def is_home(conversation: dict, stay: dict | None) -> bool:
    return "自宅" in (conversation.get("place") or "") or bool(stay and stay.get("label") == "自宅")


# MARK: - 印を付ける


def _share(count: int, total: int) -> float:
    return count / total if total else 0.0


def loud_venue(conversation: dict, stay: dict | None, cfg: dict) -> dict | None:
    lines = [l for l in conversation["lines"] if (l.get("text") or "").strip()]
    if len(lines) < cfg["venue_min_lines"]:
        return None
    words = _text(conversation) + (" " + " ".join(str(stay.get(k) or "") for k in ("label", "where")) if stay else "")
    venue = next((name for name, pattern in VENUE_WORDS.items() if pattern.search(words)), None)
    if venue is None:
        return None
    noisy = _share(sum(1 for l in lines if l.get("noisy")), len(lines))
    loud = _share(sum(1 for l in lines if l.get("sound") in LOUD_SOUNDS), len(lines))
    if noisy < cfg["venue_noisy_share"] and loud < cfg["venue_sound_share"]:
        return None
    return {"kind": "loud_venue", "effect": "speaker_caution", "scope": "conversation", "label": LABEL,
            "venue": venue, "line_count": len(lines),
            "why": f"{venue}の場で騒がしい（騒がしい行 {noisy:.0%}・周りの音 {loud:.0%}）",
            "evidence": [{"noisy_share": round(noisy, 3), "sound_share": round(loud, 3)}]}


def car_state(conversation: dict, cfg: dict) -> tuple[str | None, list[str]]:
    """("strong"＝iPhone の車内の印・"maybe"＝動きと音から・None, 根拠)"""
    if conversation.get("inCar") is True:
        return "strong", ["inCar"]
    vehicle = (conversation.get("vehicle") or "").lower()
    if vehicle and any(word in vehicle for word in CAR_VEHICLES):
        return "strong", ["vehicle"]
    lines = [l for l in conversation["lines"] if (l.get("text") or "").strip()]
    if "車" in (conversation.get("movement") or "") and lines:
        car = _share(sum(1 for l in lines if l.get("sound") == CAR_SOUND), len(lines))
        navi = sum(1 for l in lines if NAVI.search(l["text"]))
        if car >= cfg["car_sound_share"] or navi >= cfg["car_navi_min_lines"]:
            return "maybe", ["movement", "car_sound" if car >= cfg["car_sound_share"] else "navi_text"]
    return None, []


def in_car_media(conversation: dict, cfg: dict) -> dict | None:
    state, evidence = car_state(conversation, cfg)
    if state is None:
        return None
    times = []
    for line in conversation["lines"]:
        if _is_self(line) or not (line.get("text") or "").strip():
            continue
        if line.get("media") is not None or NAVI.search(line["text"]) or line.get("sound") == "音楽":
            times.append(line["time"])
    if not times:
        return None
    return {"kind": "in_car_media", "effect": "not_self", "scope": "lines", "label": LABEL, "line_times": times,
            "line_count": len(times), "car": state,
            "why": "車内のナビ・カーステレオらしい声" + ("" if state == "strong" else "（車内は動きと音からの推し量り）"),
            "evidence": [{"car_evidence": evidence}]}


def media_suspect(conversation: dict, home: bool, holiday: bool, cfg: dict) -> dict | None:
    if conversation.get("media") or not home or (cfg["media_holiday_only"] and not holiday):
        return None
    lines = [l for l in conversation["lines"] if (l.get("text") or "").strip()]
    if len(lines) < cfg["media_min_lines"] or any(_is_self(l) for l in lines):
        return None
    names = [l.get("speaker") for l in lines]
    if any(n and not UNNAMED.fullmatch(n) for n in names):
        return None
    counts: dict = {}
    for n in names:
        counts[n] = counts.get(n, 0) + 1
    top = max(counts.values()) / len(lines)
    if top < cfg["media_top_share"]:
        return None
    return {"kind": "media_suspect", "effect": "not_self", "scope": "conversation", "label": LABEL,
            "line_count": len(lines),
            "why": f"家で本人の声が無く、同じ声が {top:.0%} を占める（メディアの音（仮））",
            "evidence": [{"top_share": round(top, 3), "voices": len(counts)}]}


def couple_topic(conversation: dict, cfg: dict) -> dict | None:
    if conversation.get("media"):
        return None
    lines = [l for l in conversation["lines"] if (l.get("text") or "").strip() and l.get("media") is None]
    speakers = {l.get("speakerID") or l.get("speaker") for l in lines if l.get("speakerID") or l.get("speaker")}
    if len(speakers) < cfg["couple_min_speakers"]:
        return None
    hits = [l for l in lines if COUPLE.search(l["text"])]
    if not hits:
        return None
    words = sorted({m for l in hits for m in COUPLE.findall(l["text"])})
    return {"kind": "couple_topic", "effect": "needs_check", "scope": "lines", "label": LABEL,
            "line_times": [l["time"] for l in hits], "line_count": len(hits), "words": words, "speakers": len(speakers),
            "pending": True, "question": QUESTION,
            "why": f"{len(speakers)} 人以上の会話で「{'・'.join(words)}」が出た。友人の話が混ざることがあるので、本人の話と決めない",
            "evidence": [{"speakers": len(speakers), "lines": len(hits)}]}


def conversation_marks(conversation: dict, holiday: bool, stays: list[dict], cfg: dict) -> list[dict]:
    stay = stay_at(stays, conversation["start"]) if stays else None
    home = is_home(conversation, stay)
    found = (loud_venue(conversation, stay, cfg), in_car_media(conversation, cfg),
             media_suspect(conversation, home, holiday, cfg), couple_topic(conversation, cfg))
    return [m for m in found if m]


# MARK: - 日ごとに作る・置く・下流が読む


def _iso(ms: int) -> str:
    return datetime.datetime.fromtimestamp(ms / 1000, JST).isoformat(timespec="seconds")


def day_marks(parsed: dict, day: str, mother: Path | None, config: dict | None = None) -> list[dict]:
    """その日の会話ごとの印 [{"conversation_start", "start_ms", "marks": [...]}]（印の無い会話は入れない）"""
    cfg = settings(config)
    holiday, _why = is_holiday(day, mother)
    stays = stays_of(day, mother)
    out = []
    for conversation in parsed.get("conversations", []):
        marks = conversation_marks(conversation, holiday, stays, cfg)
        if marks:
            out.append({"conversation_start": _iso(conversation["start"]), "start_ms": conversation["start"], "marks": marks})
    return out


def hold(convs: list[dict], parsed: dict, day: str, mother: Path | None, config: dict | None = None) -> int:
    """voicetone の会話ごとの数（convs）に、信用 low と tier_cap を足す（騒がしい場・メディアの音の会話）。足した数"""
    held = {m["start_ms"]: [k["kind"] for k in m["marks"] if k["kind"] in ("loud_venue", "media_suspect")]
            for m in day_marks(parsed, day, mother, config)}
    n = 0
    for c in convs:
        kinds = held.get(c.get("start_ms")) or []
        if not kinds:
            continue
        why = "・".join(("騒がしい場" if k == "loud_venue" else "メディアの音（仮）") for k in kinds)
        c["trust"] = "low"
        c["tier_cap"] = "tentative"
        c["trust_why"] = "・".join(x for x in (c.get("trust_why"), why) if x)[:40]
        c["holiday_marks"] = kinds
        n += 1
    return n


def build_day(home: Path, store, day: str, mother: Path | None, config: dict | None = None) -> dict | None:
    parsed = store.day(day)
    if parsed is None:
        return None
    cfg = settings(config)
    holiday, why = is_holiday(day, mother)
    built = {"version": VERSION, "day": day, "holiday": holiday, "holiday_why": why or None,
             "conversations": day_marks(parsed, day, mother, config),
             "thresholds": {**{k: v for k, v in cfg.items() if not k.startswith("_")}, "仮": True}}
    _write(home / FOLDER / f"{day}.json", built)
    return built


def pending(home: Path, today: datetime.date, days: int) -> dict:
    """確かめ待ちの束（休15）。母艦が「自分を知る」の確かめの文に使う"""
    items = []
    for i in range(days):
        day = (today - datetime.timedelta(days=i)).isoformat()
        data = _read(home / FOLDER / f"{day}.json") or {}
        for c in data.get("conversations") or []:
            for m in c["marks"]:
                if m.get("kind") == "couple_topic" and m.get("pending"):
                    items.append({"day": day, "conversation_start": c["conversation_start"], "line_times": m["line_times"],
                                  "words": m["words"], "question": m["question"], "label": LABEL, "value_if_yes": "self",
                                  "kind": "couple_topic"})
    return {"version": VERSION, "made_on": today.isoformat(), "items": items}


def run(home: Path, store, mother: Path | None, config: dict, log: Callable[[str], None], days: list[str],
        mother_copy: bool = True) -> dict:
    made = []
    for day in days:
        try:
            built = build_day(home, store, day, mother, config)
        except Exception as error:  # noqa: BLE001 — 1 日が失敗しても続ける
            log(f"休日の印: {day} を作れませんでした: {type(error).__name__}")
            continue
        if built is not None:
            made.append(built)
    cfg = settings(config)
    queue = pending(home, datetime.date.today(), int(cfg["pending_days"]))
    copied = 0
    if mother_copy and mother is not None and mother.is_dir():
        dest = mother / MOTHER_DIR
        for built in made:
            copied += _write(dest / "days" / f"{built['day']}.json", built)
        copied += _write(dest / "needs_check.json", queue)
    counts: dict[str, int] = {}
    for built in made:
        for c in built["conversations"]:
            for m in c["marks"]:
                counts[m["kind"]] = counts.get(m["kind"], 0) + 1
    if made:
        log(f"休日の印: {len(made)} 日・印 {sum(counts.values())}（{counts}）・確かめ待ち {len(queue['items'])}・母艦へ {copied}")
    return {"days": len(made), "counts": counts, "pending": len(queue["items"]), "copied": copied}


def read_day(home: Path, day: str) -> dict:
    data = _read(home / FOLDER / f"{day}.json") if re.fullmatch(r"\d{4}-\d{2}-\d{2}", day) else None
    return {"available": True, **data} if data else {"available": False}
