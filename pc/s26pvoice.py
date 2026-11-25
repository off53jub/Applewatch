"""LifeLog PC: s26（2026-11-25。担当 P）の人と声の分。0 円・言語モデルなし。声の特徴は voices/<日>.npz の今までのもの（新しく測らない）。

どれも「たぶん」「候補」を付けるだけ。記録の話し手は変えない・人をまとめない・名前を確定しない（本人の答えが上）。

- 結1（取り決め K9）場面の見込みを声で確かめる（"s26p_talk_guess"。初めはオン＝「たぶん」を付けるだけ）:
  母艦 M2 の state/talk_guess_for_pc.json（{"items": [{"talk_id","day","start","end","candidates": [{"name","score","why"}]}]}）の
  会話ごとに、その会話の名前の無い声（人物N）の真ん中と、候補の人の声の真ん中（直近 7 日の、その名前の行）の近さを出す。
  いちばん近い候補が VOICE_OK 以上・2 番目との差が VOICE_MARGIN 以上（どちらも仮）なら「たぶん◯◯さん」（status "voice_ok"）。
  候補の人の声がまだ無ければ status "no_voice"（場面の見込みだけ）。会話にもう名前のある相手がいれば "named"（本人の付けた名前が上）。
  HOME/s26p/talk-guess.json と母艦 inbox/pc-talk-guess/s26p_talk_guess.json（文・声の数字は入れない）に置く。
  記録を読む口（lifelog_mcp.py の get_conversation）は "maybe_person" として返す。
  合わせて、「名前のある人かも」（voices.PRIOR_BONUS）の近さに、その会話の候補の人へ score × GUESS_BONUS（仮）を足す。
- 聞5 予定の相手の声の見本の候補（"s26p_calendar_voice"。初めはオン＝問いは今の 1 日 3 問の中）:
  予定（archive/calendar）の「相手」が 1 人だけの時間に録れた、自分でない名前の無い声を、その人の見本の候補にする。
  違う予定 3 回ぶんの声の真ん中どうしが互いに CAL_SIMILAR 以上（仮）でそろったら、問いを 1 つだけ（GET /know/questions の
  3 番目に入れる。アプリは 1 日 3 問だけ見せる＝問いは増えない）。「はい」なら GET /voice-samples にその人の見本の候補として足す
  （足すのはアプリ＝本人の端末）。その人がもう声の見本を REF_ENOUGH 個以上持っていれば聞かない。記録にもう出てくる名前だけ。
- 聞4 1 日まるごとの話し手分け（"s26p_day_diar"。初めはオフ＝影で比べるだけ）:
  その日の全部の区間の声（日の平均を引いた特徴）を、長い区間から順に近い束へ（DIAR_LINK 以上・仮）入れてかたまりにし、
  名前のある行が DIAR_PURE 以上を占めるかたまりに、その名前を付ける。そのかたまりの中の人物N を「たぶん◯◯さん」の候補に。
  今の名前との合い方（名前のある行が、かたまりの名前と同じだった割合）と、名前が付きそうな人物N の行の数を
  HOME/s26p/day-diar/<日>.json に（記録には付けない）。
"""

from __future__ import annotations

import datetime
import hashlib
import json
import os
import re
from pathlib import Path

import numpy as np

import appfeeds
import voices

TALK_GUESS = Path("state") / "talk_guess_for_pc.json"
GUESS_FILE = "talk-guess.json"
VOICE_OK = 0.55            # 仮
VOICE_MARGIN = 0.05        # 仮
GUESS_BONUS = 0.05         # 仮: 「名前のある人かも」に足す近さ × score
CAL_SIMILAR = 0.6          # 仮
CAL_DAYS = 14
CAL_NEED = 3
REF_ENOUGH = 8             # 仮: その人の声の行がこれだけあれば、見本は足りている
DIAR_LINK = 0.6            # 仮
DIAR_PURE = 0.6
DIAR_MIN = 3
CAL_TIME = re.compile(r"^\s*-\s+(\d{1,2}):(\d{2})\s*-\s*(\d{1,2}):(\d{2})\s+(.*)$")
CAL_PARTNER = re.compile(r"^\s+-\s+相手[:：]\s*(.+)$")
UNNAMED = re.compile(r"人物\d+")
QUESTION_PREFIX = "s26v-"


def folder(home: Path) -> Path:
    return Path(home) / "s26p"


def _read(path: Path, default=None):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return default


def _write(path: Path, body) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    part = path.with_name(path.name + ".part")
    part.write_text(json.dumps(body, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(part, path)


def _ms(value) -> int | None:
    if isinstance(value, int) and not isinstance(value, bool):
        return value
    try:
        moment = datetime.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None
    if moment.tzinfo is None:
        moment = moment.astimezone()
    return int(moment.timestamp() * 1000)


def _named(name) -> bool:
    return isinstance(name, str) and bool(name) and name != "自分" and not UNNAMED.fullmatch(name)


def day_vectors(home: Path, parsed: dict, day: str) -> dict[str, np.ndarray]:
    """その日の区間の鍵 → 日の平均を引いて長さ 1 にした声の特徴（区間が少ない日は {}）"""
    ds = voices.DayStore(home, day).load()
    segs = [s for s in voices.segments(parsed) if s["key"] in ds.vectors]
    if len(segs) < voices.MEAN_MIN:
        return {}
    mean = np.mean(np.stack([ds.vectors[s["key"]] for s in segs]), axis=0)
    out = {}
    for s in segs:
        vector = voices._unit(ds.vectors[s["key"]].astype(np.float64) - mean)
        if vector is not None:
            out[s["key"]] = vector
    return out


def name_refs(home: Path, store, days: list[str]) -> dict[str, tuple[np.ndarray, int]]:
    """名前 → (声の真ん中, 区間の数)（直近の日の、その名前の行から）"""
    got = voices.gather(home, store, days)
    out = {}
    for label, entry in got["labels"].items():
        if not label.startswith("n:") or not entry["items"]:
            continue
        center = voices.center(entry["items"], voices.CENTER_CLIPS * 3)
        name = str(entry.get("name") or "")
        if center is not None and _named(name):
            out[name] = (center, len(entry["items"]))
    return out


# MARK: - 結1（K9）場面の見込みを声で確かめる


def read_guess(base: Path | None) -> list[dict]:
    if base is None:
        return []
    data, failure = appfeeds._load(Path(base), TALK_GUESS, "場面の見込み")
    if failure or data is None or not isinstance(data.get("items"), list):
        return []
    out = []
    for x in data["items"][:500]:
        if not isinstance(x, dict) or appfeeds._day(x.get("day")) is None:
            continue
        start, end = _ms(x.get("start")), _ms(x.get("end"))
        cands = []
        for c in x.get("candidates") or []:
            if isinstance(c, dict) and _named(c.get("name")) and len(c["name"]) <= 40 \
                    and isinstance(c.get("score"), (int, float)) and not isinstance(c.get("score"), bool):
                cands.append({"name": c["name"], "score": float(c["score"]),
                              "why": appfeeds._strings(c.get("why"), 60, 5)})
        if start is None or end is None or end < start or not cands:
            continue
        out.append({"talk_id": str(x.get("talk_id") or "")[:80], "day": x["day"], "start": start, "end": end,
                    "candidates": sorted(cands, key=lambda c: -c["score"])[:6]})
    return out


def talk_of(parsed: dict, day: str, item: dict) -> dict | None:
    """talk_id（"日|始まりのミリ秒"）が合う会話、無ければ時間がいちばん重なる会話"""
    best, overlap = None, 0
    for c in parsed.get("conversations") or []:
        if not isinstance(c, dict) or not isinstance(c.get("start"), int):
            continue
        if item["talk_id"] and item["talk_id"] == f"{day}|{c['start']}":
            return c
        times = [x.get("time") for x in c.get("lines") or [] if isinstance(x, dict) and isinstance(x.get("time"), int)]
        end = c.get("end") if isinstance(c.get("end"), int) else (max(times) if times else c["start"])
        got = min(end, item["end"]) - max(c["start"], item["start"])
        if got > overlap:
            best, overlap = c, got
    return best


def unnamed_center(conversation: dict, vectors: dict[str, np.ndarray]) -> tuple[np.ndarray | None, int]:
    """会話の名前の無い声（人物N のうち、いちばん長く話した人）の真ん中"""
    by_label: dict[str, list[np.ndarray]] = {}
    seconds: dict[str, float] = {}
    for line in conversation.get("lines") or []:
        if not isinstance(line, dict) or line.get("media") is not None:
            continue
        label = voices.label_of(line)
        if not label or not label.startswith("u:"):
            continue
        key = voices.seg_key(line.get("audio") or "", line.get("offset") or 0, line.get("end") or 0) \
            if isinstance(line.get("offset"), (int, float)) and isinstance(line.get("end"), (int, float)) else None
        if key in vectors:
            by_label.setdefault(label, []).append(vectors[key])
            seconds[label] = seconds.get(label, 0.0) + float(line["end"]) - float(line["offset"])
    if not by_label:
        return None, 0
    label = max(by_label, key=lambda k: seconds.get(k, 0.0))
    return voices._unit(np.mean(np.stack(by_label[label]), axis=0)), len(by_label[label])


def check_guesses(home: Path, base: Path | None, store, today: datetime.date | None = None) -> dict:
    """{"items": [...], "counts": {status: n}}。置いて返す"""
    today = today or datetime.date.today()
    items = read_guess(base)
    refs_days = [(today - datetime.timedelta(days=k)).isoformat() for k in range(voices.WINDOW - 1, -1, -1)]
    refs = name_refs(home, store, refs_days) if items and store is not None else {}
    vec_cache: dict[str, dict] = {}
    out, counts = [], {}
    for item in items:
        parsed = store.day(item["day"]) if store is not None else None
        conversation = talk_of(parsed or {}, item["day"], item) if parsed else None
        row = {"talk_id": item["talk_id"] or (f"{item['day']}|{conversation['start']}" if conversation else ""),
               "day": item["day"], "start": item["start"], "end": item["end"], "maybe": None, "score": None, "voice": None}
        if conversation is None:
            row["status"] = "no_talk"
        elif any(_named(x.get("speaker")) for x in conversation.get("lines") or [] if isinstance(x, dict)):
            row["status"] = "named"
        else:
            if item["day"] not in vec_cache:
                vec_cache[item["day"]] = day_vectors(home, parsed, item["day"])
            center, clips = unnamed_center(conversation, vec_cache[item["day"]])
            scored = []
            for c in item["candidates"]:
                ref = refs.get(c["name"])
                if center is not None and ref is not None:
                    scored.append((float(center @ ref[0]), c))
            if center is None or not scored:
                top = item["candidates"][0]
                row.update(status="no_voice", maybe=None, score=round(top["score"], 3))
                row["scene_top"] = top["name"]
            else:
                scored.sort(key=lambda s: -s[0])
                best, cand = scored[0]
                second = scored[1][0] if len(scored) > 1 else -1.0
                row["voice"] = round(best, 3)
                row["score"] = round(cand["score"], 3)
                if best >= VOICE_OK and best - second >= VOICE_MARGIN:
                    row.update(status="voice_ok", maybe=cand["name"], why=cand["why"] + ["声が近い"])
                else:
                    row.update(status="voice_no")
            if conversation is not None:
                row["conversation_start"] = conversation["start"]
        counts[row["status"]] = counts.get(row["status"], 0) + 1
        out.append(row)
    body = {"version": 1, "generated_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
            "note": "s26 結1（仮）。「たぶん」だけ。名前は確定しない（本人の答えが上）", "items": out, "counts": counts}
    _write(folder(home) / GUESS_FILE, body)
    if base is not None and Path(base).is_dir():
        try:
            _write(Path(base) / "inbox" / "pc-talk-guess" / "s26p_talk_guess.json", body)
        except OSError:
            pass
    return body


def read_maybe(home: Path) -> dict[str, str]:
    """会話の id（"日|始まりのミリ秒"）→ たぶんの名前（"voice_ok" だけ）"""
    body = _read(folder(home) / GUESS_FILE, {}) or {}
    out = {}
    for row in body.get("items") or []:
        if isinstance(row, dict) and row.get("status") == "voice_ok" and row.get("maybe") and row.get("conversation_start"):
            out[f"{row['day']}|{row['conversation_start']}"] = str(row["maybe"])
    return out


def chain_bonus(before, home_of, base_of, store_of, config_of):
    """voices.PRIOR_BONUS を包む: 場面の見込みの候補の人に score × GUESS_BONUS を足す"""

    def bonus(labels: dict, days: list[str]):
        first = None
        if before is not None:
            try:
                first = before(labels, days)
            except Exception:  # noqa: BLE001
                first = None
        extra: dict[tuple[str, str], float] = {}
        try:
            if (config_of() or {}).get("s26p_talk_guess") is not False:
                items = [x for x in read_guess(base_of()) if x["day"] in days]
                name_of = {k: str(v.get("name") or "") for k, v in labels.items()}
                for label, entry in labels.items():
                    if not label.startswith("u:"):
                        continue
                    times = [i.get("time") for i in entry.get("items") or [] if isinstance(i.get("time"), int)]
                    for item in items:
                        if any(item["start"] <= t <= item["end"] for t in times):
                            for c in item["candidates"]:
                                for ref, name in name_of.items():
                                    if name == c["name"] and ref.startswith("n:"):
                                        extra[(label, ref)] = max(extra.get((label, ref), 0.0), GUESS_BONUS * max(0.0, min(1.0, c["score"])))
        except Exception:  # noqa: BLE001
            extra = {}
        if first is None and not extra:
            return None

        def score(label: str, ref: str) -> float:
            return (first(label, ref) if first is not None else 0.0) + extra.get((label, ref), 0.0)

        return score

    return bonus


# MARK: - 聞5 予定の相手の声の見本


def single_partner_events(base: Path | None, day: str) -> list[dict]:
    """その日の予定のうち、相手が 1 人だけのもの [{"name","start","end"}（ミリ秒）]"""
    if base is None:
        return []
    path = Path(base) / "archive" / "calendar" / day[:4] / day[5:7] / f"{day[8:10]}.md"
    try:
        lines = path.read_text(encoding="utf-8-sig").splitlines()
    except OSError:
        return []
    out, current = [], None
    for raw in lines:
        m = CAL_TIME.match(raw)
        if m and not raw.startswith("  "):
            h1, m1, h2, m2 = (int(m[i]) for i in range(1, 5))
            begin = datetime.datetime.fromisoformat(day).replace(hour=h1, minute=m1)
            finish = datetime.datetime.fromisoformat(day).replace(hour=h2, minute=m2)
            if finish <= begin:
                finish += datetime.timedelta(days=1)
            current = {"start": int(begin.timestamp() * 1000), "end": int(finish.timestamp() * 1000), "names": None}
            out.append(current)
            continue
        p = CAL_PARTNER.match(raw)
        if p and current is not None:
            names = [n.strip() for n in re.split(r"[、,・/／\s]+", p[1]) if n.strip()]
            current["names"] = names
    return [{"name": e["names"][0], "start": e["start"], "end": e["end"]} for e in out
            if e["names"] and len(e["names"]) == 1 and _named(e["names"][0])]


def calendar_voices(home: Path, base: Path | None, store, today: datetime.date) -> dict:
    """{名前: [{"day","start","label","vec","clips","audio","offset","length"}]}（予定ごとに 1 つ）"""
    out: dict[str, list[dict]] = {}
    for back in range(1, CAL_DAYS + 1):
        day = (today - datetime.timedelta(days=back)).isoformat()
        events = single_partner_events(base, day)
        if not events or store is None:
            continue
        parsed = store.day(day)
        if not parsed:
            continue
        vectors = None
        for event in events:
            by_label: dict[str, list] = {}
            for c in parsed.get("conversations") or []:
                if not isinstance(c, dict) or c.get("media"):
                    continue
                for line in c.get("lines") or []:
                    if not isinstance(line, dict) or not isinstance(line.get("time"), int) \
                            or not event["start"] <= line["time"] <= event["end"]:
                        continue
                    label = voices.label_of(line)
                    if label and label.startswith("u:"):
                        by_label.setdefault(label, []).append(line)
            if not by_label:
                continue
            if vectors is None:
                vectors = day_vectors(home, parsed, day)
            label = max(by_label, key=lambda k: len(by_label[k]))
            keyed = [(voices.seg_key(x["audio"], x["offset"], x["end"]), x) for x in by_label[label]
                     if isinstance(x.get("audio"), str) and isinstance(x.get("offset"), (int, float))
                     and isinstance(x.get("end"), (int, float))]
            vecs = [vectors[k] for k, _ in keyed if k in vectors]
            if len(vecs) < 2:
                continue
            longest = max((x for k, x in keyed if k in vectors), key=lambda x: float(x["end"]) - float(x["offset"]))
            out.setdefault(event["name"], []).append({
                "day": day, "start": event["start"], "label": label, "vec": voices._unit(np.mean(np.stack(vecs), axis=0)),
                "clips": len(vecs), "audio": longest["audio"], "offset": round(float(longest["offset"]), 2),
                "length": round(float(longest["end"]) - float(longest["offset"]), 2), "time": longest["time"]})
    return out


def agree_set(rows: list[dict], need: int = CAL_NEED, similar: float = CAL_SIMILAR) -> list[dict] | None:
    """違う予定 need 回ぶんで、互いに similar 以上の組（いちばん近さの合計が大きいもの）"""
    import itertools

    usable = [r for r in rows if r.get("vec") is not None]
    best, best_score = None, -1.0
    for combo in itertools.combinations(usable[:12], need):
        if len({(r["day"], r["start"]) for r in combo}) < need:
            continue
        sims = [float(a["vec"] @ b["vec"]) for a, b in itertools.combinations(combo, 2)]
        if min(sims) >= similar and sum(sims) > best_score:
            best, best_score = list(combo), sum(sims)
    return best


def question_id(name: str) -> str:
    return QUESTION_PREFIX + hashlib.sha256(name.encode("utf-8")).hexdigest()[:12]


def answers(base: Path | None) -> dict[str, str]:
    """問いの id → "yes"・"no"・"skip"（いちばん新しい答え）"""
    if base is None:
        return {}
    import knowapp

    latest: dict[str, tuple[str, str]] = {}
    for row in knowapp._jsonl(Path(base) / knowapp.ANSWERS):
        rid = str(row.get("id") or "")
        if not rid.startswith(QUESTION_PREFIX):
            continue
        text = str(row.get("text") or "").strip()
        value = str(row.get("value") or "")
        if value == "skip":
            verdict = "skip"
        elif text.startswith(("はい", "うん", "そう", "yes", "Yes", "YES", "合って")):
            verdict = "yes"
        elif text:
            verdict = "no"
        else:
            continue
        at = str(row.get("at") or "")
        if rid not in latest or at >= latest[rid][0]:
            latest[rid] = (at, verdict)
    return {k: v for k, (_, v) in latest.items()}


def calendar_update(home: Path, base: Path | None, store, today: datetime.date | None = None) -> dict:
    """候補を作り直して HOME/s26p/calendar-voice.json に置く。{"people","ready","asked","confirmed"}"""
    today = today or datetime.date.today()
    path = folder(home) / "calendar-voice.json"
    state = _read(path, {}) or {}
    confirmed = state.get("confirmed") if isinstance(state.get("confirmed"), dict) else {}
    found = calendar_voices(home, base, store, today)
    days = [(today - datetime.timedelta(days=k)).isoformat() for k in range(voices.WINDOW - 1, -1, -1)]
    refs = name_refs(home, store, days) if found and store is not None else {}
    ids = {}
    if store is not None:
        for back in range(0, CAL_DAYS + 1):
            parsed = store.day((today - datetime.timedelta(days=back)).isoformat()) or {}
            for c in parsed.get("conversations") or []:
                for x in c.get("lines") or [] if isinstance(c, dict) else []:
                    if isinstance(x, dict) and _named(x.get("speaker")) and isinstance(x.get("speakerID"), str):
                        ids.setdefault(x["speaker"], x["speakerID"])
    got = answers(base)
    ready = []
    for name, rows in sorted(found.items()):
        if name not in ids or (name in refs and refs[name][1] >= REF_ENOUGH):
            continue
        combo = agree_set(rows)
        if combo is None:
            continue
        qid = question_id(name)
        entry = {"name": name, "speakerID": ids[name], "id": qid,
                 "events": [{"day": r["day"], "start": r["start"]} for r in combo],
                 "samples": [{"day": r["day"], "line_time": voices._iso(r["time"]), "audio": r["audio"], "offset": r["offset"],
                              "length": r["length"], "path": f"/audio-clip?audio={r['audio']}&offset={r['offset']:.2f}"
                                                            f"&length={r['length']:.2f}", "why": "calendar"} for r in combo]}
        verdict = got.get(qid)
        if verdict == "yes":
            confirmed[name] = {**entry, "at": datetime.datetime.now().isoformat(timespec="seconds")}
        elif verdict == "no":
            continue
        else:
            ready.append(entry)
    body = {"version": 1, "generated_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
            "people": len(found), "ready": ready, "confirmed": confirmed,
            "thresholds": {"similar": CAL_SIMILAR, "need": CAL_NEED, "仮": True}}
    _write(path, body)
    return {"people": len(found), "ready": len(ready), "confirmed": len(confirmed)}


def pending_question(home: Path, base: Path | None) -> dict | None:
    """今出す問い（1 つだけ。答えたものは出さない）"""
    body = _read(folder(home) / "calendar-voice.json", {}) or {}
    got = answers(base)
    for entry in body.get("ready") or []:
        if not isinstance(entry, dict) or got.get(entry.get("id")) in ("yes", "no"):
            continue
        days = "・".join(sorted({e["day"][5:].replace("-", "/") for e in entry.get("events") or []}))
        return {"id": entry["id"], "group": "with_people", "answer": "yesno", "label": "声の見本（仮）",
                "text": f"{entry['name']}さんと 2 人の予定（{days}）で録れた、自分でない声は{entry['name']}さんの声ですか？",
                "evidence": [{"kind": "calendar", "text": f"予定の相手が{entry['name']}さんだけ・{len(entry.get('events') or [])} 回"}]}
    return None


def wrap_questions(original, home_of, config_of):
    """GET /know/questions に 1 問だけ足す（3 番目に。アプリは 1 日 3 問だけ見せる＝問いは増えない）"""

    def read(base: Path, today: datetime.date | None = None) -> dict:
        body = original(base, today) if today is not None else original(base)
        try:
            if (config_of() or {}).get("s26p_calendar_voice") is False or not body.get("available"):
                return body
            question = pending_question(home_of(), base)
            if question is None:
                return body
            items = [q for q in body.get("items") or [] if q.get("id") != question["id"]]
            items.insert(min(2, len(items)), question)
            limit = max(len(body.get("items") or []), 1)
            body = {**body, "items": items[:limit]}
        except Exception:  # noqa: BLE001 — 足せなくても、今の問いは返す
            pass
        return body

    read.s26p_wrapped = True  # type: ignore[attr-defined]
    return read


def wrap_samples(original, home_of, config_of):
    """GET /voice-samples に、本人が「はい」と答えた予定の相手の見本を足す"""

    def read(home: Path) -> dict:
        body = original(home)
        try:
            if (config_of() or {}).get("s26p_calendar_voice") is False:
                return body
            confirmed = (_read(folder(home_of()) / "calendar-voice.json", {}) or {}).get("confirmed") or {}
            extra = [{"speaker": e["name"], "speakerID": e["speakerID"], "conversations": len(e.get("events") or []),
                      "samples": e.get("samples") or [], "candidates": len(e.get("samples") or []),
                      "tier": "tentative", "tier_why": "予定の相手の声（本人が「はい」）。足すのは本人の端末",
                      "evidence_kinds": ["user", "calendar", "voice"]}
                     for e in confirmed.values() if isinstance(e, dict) and e.get("samples")]
            if extra:
                have = {p.get("speaker") for p in body.get("people") or []}
                body = {**body, "available": True, "people": list(body.get("people") or []) +
                        [p for p in extra if p["speaker"] not in have]}
        except Exception:  # noqa: BLE001
            pass
        return body

    read.s26p_wrapped = True  # type: ignore[attr-defined]
    return read


# MARK: - 聞4 1 日まるごとの話し手分け（初めはオフ）


def day_diar(home: Path, store, day: str) -> dict | None:
    parsed = store.day(day) if store is not None else None
    if not parsed:
        return None
    vectors = day_vectors(home, parsed, day)
    segs = [s for s in voices.segments(parsed) if s["key"] in vectors]
    if not segs:
        return None
    segs.sort(key=lambda s: -(s["end"] - s["start"]))
    centers: list[np.ndarray] = []
    sums: list[np.ndarray] = []
    members: list[list[dict]] = []
    for s in segs:
        v = vectors[s["key"]]
        if centers:
            sims = np.stack(centers) @ v
            k = int(np.argmax(sims))
            if sims[k] >= DIAR_LINK:
                sums[k] = sums[k] + v
                centers[k] = voices._unit(sums[k])
                members[k].append(s)
                continue
        centers.append(v)
        sums.append(v.copy())
        members.append([s])
    clusters, agree, named_lines, maybe_lines = [], 0, 0, 0
    for group in members:
        if len(group) < DIAR_MIN:
            continue
        named = {}
        for s in group:
            name = s["line"].get("speaker")
            if s["label"] == voices.SELF_LABEL:
                key = "自分"
            elif s["label"] and s["label"].startswith("n:") and _named(name):
                key = name
            else:
                continue
            named[key] = named.get(key, 0) + 1
        total_named = sum(named.values())
        top = max(named, key=named.get) if named else None
        label = top if top and named[top] / max(1, total_named) >= DIAR_PURE and named[top] >= 2 else None
        if label:
            agree += named[label]
            named_lines += total_named
        unnamed = [s for s in group if s["label"] and s["label"].startswith("u:")]
        if label and label != "自分":
            maybe_lines += len(unnamed)
        clusters.append({"size": len(group), "name": label, "named_lines": total_named, "unnamed_lines": len(unnamed),
                         "unnamed": sorted({s["label"] for s in unnamed})[:20]})
    body = {"version": 1, "day": day, "generated_at": datetime.datetime.now().isoformat(timespec="seconds"),
            "segments": len(segs), "clusters": clusters, "agree": round(agree / named_lines, 3) if named_lines else None,
            "maybe_lines": maybe_lines, "note": "s26 聞4（仮・影）。記録には付けない"}
    _write(folder(home) / "day-diar" / f"{day}.json", body)
    return body
