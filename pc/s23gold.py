"""LifeLog PC: s23 続3（2026-11-23）。騒がしい場面（店・電車・外）の正解集の候補を 20 個選び、本人が直せる確かめ待ちの形に出す。

- なぜ: s22 確13 で「雑音を消してから文字にすると悪くなる」と出たのは、正解集（本人が直した 46 個）に騒がしい場面が少ないせいかも（仮説）。
- 騒がしさの測り（noise_score）: 区切りの音の大きさの要約（s22 levels の chunks。p10＝下の 1 割の dB＝周りの音の床）と、
  声の大きさとの差（voicedP50 − p10。小さいほど声が埋もれている）。行の "noisy"（iPhone の印）も 1 つの手がかり。
- 場面の印（scene_of）: 会話の "movement"（電車・歩きながら）・"scene"（車・道路など）・"place"（店らしい言葉）・
  POST /jobs の scene（train・shop・outside・car）から、train・shop・outside のどれか（どれでもなければ選ばない）。
- 候補: 2〜12 秒・文のある行・音声が PC に残っている行から、場面ごとに騒がしい順に、合わせて WANTED 個まで（1 日 PER_DAY 個ずつ出す）。
  HOME/s23/review/noisy-gold.json に残す。確かめ待ちの形: kind "gold_noisy"・answer "text"（正しい文を打つ。合っていれば「そのまま」）・
  clips 1 つ（/audio-clip）・evidence に今の文。
- 答え（POST /feedback の kind review・id "gn-…"）を受けたら、その行の音を正解集の材料に足す（origin "pc-noisy-gold"・scene つき。
  goldset.items が拾うので、正解集の点に入る）。答えは本人が付ける（PC は文を作らない）。config.json の "noisy_gold": false で出さない。
"""

from __future__ import annotations

import datetime
import hashlib
import json
import os
import re
from pathlib import Path

WANTED = 20
PER_DAY = 2
LINE_MIN, LINE_MAX = 2.0, 12.0
EXPIRE_DAYS = 14
TEXT_MAX = 80
SCENES = ("shop", "train", "outside")
SCENE_LABEL = {"shop": "店", "train": "電車", "outside": "外"}
KEEP_WORDS = ("そのまま", "合ってる", "あってる", "ok", "OK", "はい")
ORIGIN = "pc-noisy-gold"
SHOP = re.compile(r"店|屋|カフェ|喫茶|ラーメン|レストラン|居酒屋|バー|食堂|コンビニ|スーパー|モール|百貨店|駅ナカ")
TRAIN = re.compile(r"電車|地下鉄|線|駅|ホーム|新幹線|バス")
OUTSIDE = re.compile(r"歩き|外|道|路|公園|屋外|車|信号|交差点")


def folder(home: Path) -> Path:
    return Path(home) / "s23" / "review"


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


def noise_score(levels: dict | None, noisy_flag: bool = False) -> float | None:
    """騒がしさ（大きいほど騒がしい）: 周りの音の床 p10 と、声との差の小ささ。要約が無ければ印だけ（印も無ければ None）"""
    if isinstance(levels, dict) and isinstance(levels.get("p10"), (int, float)):
        floor = float(levels["p10"])
        voiced = levels.get("voicedP50")
        gap = float(voiced) - floor if isinstance(voiced, (int, float)) else 20.0
        return round((floor + 60.0) + max(0.0, 25.0 - gap) + (5.0 if noisy_flag else 0.0), 1)
    return 5.0 if noisy_flag else None


def scene_of(conversation: dict, job_scene: str | None = None) -> str | None:
    """train・shop・outside のどれか（分からなければ None）"""
    if job_scene in ("train", "shop", "outside"):
        return job_scene
    if job_scene == "car":
        return "outside"
    movement = str(conversation.get("movement") or "")
    scene = str(conversation.get("scene") or "")
    place = str(conversation.get("place") or "")
    if "電車" in movement or TRAIN.search(scene):
        return "train"
    if SHOP.search(place) or SHOP.search(scene):
        return "shop"
    if "歩" in movement or OUTSIDE.search(scene):
        return "outside"
    return None


def candidates(parsed: dict, day: str, chunk_levels: dict, job_scenes: dict[str, str] | None = None,
               has_audio=lambda name: True) -> list[dict]:
    """その日の候補（騒がしい順）。[{"scene","audio","start","end","time","text","noise"}]"""
    out = []
    for conversation in parsed.get("conversations") or []:
        if conversation.get("media"):
            continue
        for line in conversation.get("lines") or []:
            audio, text = line.get("audio"), " ".join(str(line.get("text") or "").split())
            try:
                start, end = float(line.get("offset")), float(line.get("end"))
            except (TypeError, ValueError):
                continue
            if not isinstance(audio, str) or not text or not isinstance(line.get("time"), int) or line.get("media") is not None:
                continue
            if not LINE_MIN <= end - start <= LINE_MAX:
                continue
            scene = scene_of(conversation, (job_scenes or {}).get(audio))
            noise = noise_score(chunk_levels.get(audio), line.get("noisy") is True)
            if scene is None or noise is None or not has_audio(audio):
                continue
            out.append({"scene": scene, "audio": audio, "start": round(start, 2), "end": round(end, 2), "time": line["time"],
                        "text": text[:TEXT_MAX], "noise": noise, "day": day})
    out.sort(key=lambda c: -c["noise"])
    return out


def pick(found: list[dict], have: dict, room: int) -> list[dict]:
    """場面の少ない順に 1 つずつ（同じ区切りからは 1 つ）。have は今までの候補（場面ごとの数を見る）"""
    counts = {s: sum(1 for c in have.values() if c.get("scene") == s) for s in SCENES}
    used = {c.get("audio") for c in have.values()}
    chosen: list[dict] = []
    pool = [c for c in found if c["audio"] not in used]
    while pool and len(chosen) < room:
        scene = min((s for s in SCENES if any(c["scene"] == s for c in pool)), key=lambda s: counts[s], default=None)
        if scene is None:
            break
        best = next(c for c in pool if c["scene"] == scene)
        chosen.append(best)
        counts[scene] += 1
        pool = [c for c in pool if c["audio"] != best["audio"]]
    return chosen


def gid(c: dict) -> str:
    return "gn-" + hashlib.sha1(f"{c['day']}|{c['time']}|{c['audio']}".encode("utf-8")).hexdigest()[:10]


def update(home: Path, parsed: dict | None, day: str, chunk_levels: dict, config: dict | None, answered: set[str],
           job_scenes: dict[str, str] | None = None, has_audio=lambda name: True,
           today: datetime.date | None = None) -> list[dict]:
    """候補を足して残し、まだ答えの無い問いを返す（確かめ待ちの形）"""
    today = today or datetime.date.today()
    if (config or {}).get("noisy_gold") is False:
        return []
    path = folder(home) / "noisy-gold.json"
    body = _read(path, {}) or {}
    have: dict = body.get("items") if isinstance(body.get("items"), dict) else {}
    if parsed is not None and len(have) < WANTED and not any(c.get("day") == day for c in have.values()):
        for c in pick(candidates(parsed, day, chunk_levels, job_scenes, has_audio), have, min(PER_DAY, WANTED - len(have))):
            have[gid(c)] = c
        _write(path, {"version": 1, "note": "s23 続3。騒がしい場面の正解集の候補（答えは本人が付ける）", "items": have})
    limit = (today - datetime.timedelta(days=EXPIRE_DAYS)).isoformat()
    items = []
    for key, c in sorted(have.items(), key=lambda kv: str(kv[1].get("day")), reverse=True):
        if key in answered or c.get("answered") or str(c.get("day") or "") < limit:
            continue
        length = round(c["end"] - c["start"], 2)
        expires = (datetime.date.fromisoformat(c["day"]) + datetime.timedelta(days=EXPIRE_DAYS)).isoformat()
        items.append({"id": key, "kind": "gold_noisy", "answer": "text", "group": "gold_noisy", "priority": 0.45,
                      "question": f"騒がしい所（{SCENE_LABEL[c['scene']]}）の声です。正しい文を打ってください（合っていれば「そのまま」）",
                      "clips": [{"label": "聞く", "path": f"audio-clip?audio={c['audio']}&offset={c['start']}&length={length}"}],
                      "evidence": [{"text": c["text"], "ref": f"{c['day']}|{c['time']}"}], "expires": expires, "today": False,
                      "scene": c["scene"]})
    return items


def answer_text(item: dict, answer: str) -> str | None:
    """答えから正解の文（「そのまま」なら今の文。空・「わからない」なら None）"""
    value = " ".join(str(answer or "").split())
    if not value or value in ("わからない", "分からない", "unsure", "no", "いいえ", "あとで"):
        return None
    return str(item.get("text") or "") if value in KEEP_WORDS else value


def take_answer(home: Path, row: dict, find_audio, load_audio, save_sample, data_folder: Path, log) -> dict | None:
    """id "gn-…" の答えを正解集の材料に足す。{"changed": 0|1}（家の PC の騒がしい場面の問いでなければ None）"""
    key = str(row.get("id") or "")
    if not key.startswith("gn-"):
        return None
    path = folder(home) / "noisy-gold.json"
    body = _read(path, {}) or {}
    item = (body.get("items") or {}).get(key)
    if not isinstance(item, dict):
        return None
    text = answer_text(item, str(row.get("answer") or ""))
    added = 0
    if text:
        found = find_audio(item["audio"])
        if found is not None:
            try:
                audio = load_audio(Path(found).read_bytes())
                _, put = save_sample(data_folder, audio, float(item["start"]), float(item["end"]), text,
                                     {"origin": ORIGIN, "scene": item["scene"], "day": item["day"], "audio": item["audio"],
                                      "offset": item["start"]})
                added = 1 if put else 0
            except (OSError, ValueError):
                added = 0
    item["answered"] = datetime.datetime.now().isoformat(timespec="seconds")
    item["added"] = bool(added)
    _write(path, body)
    log(f"騒がしい場面の正解集（続3）: 答えを受けました（材料に足した {added}）")
    return {"changed": added}


def progress(home: Path) -> dict:
    """{"items","answered","added","by_scene": {場面: 数}}"""
    have = (_read(folder(home) / "noisy-gold.json", {}) or {}).get("items") or {}
    by_scene: dict[str, int] = {}
    for c in have.values():
        by_scene[c.get("scene")] = by_scene.get(c.get("scene"), 0) + 1
    return {"items": len(have), "answered": sum(1 for c in have.values() if c.get("answered")),
            "added": sum(1 for c in have.values() if c.get("added")), "by_scene": by_scene}
