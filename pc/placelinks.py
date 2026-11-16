"""LifeLog PC: アプリの「場所の名前直し」と「1日1分の答え合わせ」の受け口（強化案 89・90・136・137。2026-11-16）。

アプリの docs/s16-place-links.md が求める口を、母艦（mothership.home。ふだんは D:\\Lifelog）のファイルにつなぐ。
母艦は**読む**か**inbox/ の下に 1 行ずつ足すだけ**（state/ と archive/ と people-index.md は書かない。人を勝手にまとめない）。
読んで確かめてから足す（中身が決まりに合わなければ何も書かず 400）。ファイルが無ければ空の列。

  POST /place-names                features "placenames"。アプリで直した場所の名前 → inbox/place_answers.jsonl に 1 行
  GET  /checkups                   features "checkups"。母艦の state/place_quiz_for_app.json（場所）と state/name_candidates.json（人）を、
                                   アプリの列の形にして返す
  GET  /link-candidates            features "linkfind"。母艦の夜の繋がり探し（state/link_night_candidates.json。Find-NightLinks.py の出力）
  POST /checkups/answer            答え → 場所は inbox/place_answers.jsonl・人は inbox/name_answers.jsonl・繋がりは inbox/link_feedback.jsonl

形（アプリの文との対応は docs/s16-pc-place-search-2026-11-16.md の §8）:
  GET の答え  {"available": bool, "generated_at": ISO, "items": [{"id", "kind", "title", "detail", "weight", "day", "pl", "pe", "text",
               "options": [{"id", "label"}]（4 つまで）, "source"?: "night"}]}
  POST /place-names の本文   {"name", "lat", "lon", "pl", "from", "day", "at"}（lat・lon・pl・day・at は省ける）→ {"ok": true, "id", "matched": bool, "duplicate"?: true}
  POST /checkups/answer の本文 {"id", "kind", "value", "text", "day", "pl", "pe", "source"} → {"ok": true, "recorded": 母艦のどのファイルか（名前だけ）|"skipped"}
職場の会話の扱いは今のまま（繋がりの題は母艦の出来事の表の題＝先頭 40 字ほど）。名前・文は記録（log.txt）に書かない（数だけ）。
"""

from __future__ import annotations

import datetime
import hashlib
import json
import math
import re
import threading
from pathlib import Path
from typing import Callable

import mothership

GETS = ("/checkups", "/link-candidates")
POSTS = ("/place-names", "/checkups/answer")
BODY_LIMIT = 8192
ITEMS_MAX = 60
OPTIONS_MAX = 4
NAME_MAX = 60
LATLON_NEAR_M = 150.0
START_NEAR_MIN = 5
FROMS = ("conversation", "page", "registered", "watch", "visit", "checkup")
PLACE_ANSWERS = "place_answers.jsonl"
NAME_ANSWERS = "name_answers.jsonl"
LINK_FEEDBACK = "link_feedback.jsonl"
KINDS_POST = ("place", "place_unnamed", "person", "link")
DAY = re.compile(r"^\d{4}-\d{2}-\d{2}$")
OPTION_ID = re.compile(r"^[A-Za-z0-9_.:\-]{1,64}$")
EV = re.compile(r"^ev_[0-9a-f]{6,20}$")
PE = re.compile(r"^pe_\d{1,8}$")
PL = re.compile(r"^pl_[A-Za-z0-9_]{1,40}$")
NC = re.compile(r"^nc_[0-9a-f]{4,20}$")
PQ = re.compile(r"^pq_\d{8}_\d{4}$")
_lock = threading.Lock()


def features() -> list[str]:
    return ["placenames", "checkups", "linkfind"]


class Bad(Exception):
    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.message = message


# MARK: - 読む・足す


def _json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return None


def _lines(path: Path) -> list[dict]:
    out = []
    try:
        for line in path.read_text(encoding="utf-8-sig").splitlines():
            try:
                data = json.loads(line)
            except ValueError:
                continue
            if isinstance(data, dict):
                out.append(data)
    except OSError:
        pass
    return out


def inbox(base: Path) -> Path:
    return Path(base) / "inbox"


def append_line(base: Path, name: str, row: dict) -> None:
    """inbox/<name> の最後に 1 行足す（足すだけ。前の行は触らない。最後が改行で終わっていなければ先に改行）"""
    folder = inbox(base)
    if not Path(base).is_dir():
        raise Bad(503, "母艦が見つかりません")
    folder.mkdir(exist_ok=True)
    path = folder / name
    text = json.dumps(row, ensure_ascii=False, separators=(",", ":"))
    with _lock:
        lead = ""
        try:
            with path.open("rb") as f:
                f.seek(0, 2)
                if f.tell() > 0:
                    f.seek(-1, 2)
                    lead = "" if f.read(1) == b"\n" else "\n"
        except OSError:
            lead = ""
        with path.open("a", encoding="utf-8", newline="\n") as f:
            f.write(lead + text + "\n")


def now_iso() -> str:
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def _meters(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    p1, p2 = math.radians(lat1), math.radians(lat2)
    a = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(math.radians(lon2 - lon1) / 2) ** 2
    return 2 * 6371000.0 * math.asin(min(1.0, math.sqrt(a)))


# MARK: - 答え合わせの列（GET /checkups・GET /link-candidates）


def _quiz(base: Path) -> tuple[dict | None, list[dict]]:
    data = _json(Path(base) / "state" / "place_quiz_for_app.json")
    items = [i for i in (data.get("items") if isinstance(data, dict) else None) or [] if isinstance(i, dict)]
    return (data if isinstance(data, dict) else None), items


def answered(base: Path) -> dict[str, set]:
    """もう答えた問（母艦が次の回で材料から外すまでの間、重ねて出さないため）"""
    place = {str(r.get("id")) for r in _lines(inbox(base) / PLACE_ANSWERS)}
    people = {str(r.get("id")) for r in _lines(inbox(base) / NAME_ANSWERS)}
    pairs: set = set()
    feedback = _json(Path(base) / "state" / "link_feedback.json")
    rows = [r for r in (feedback.get("items") if isinstance(feedback, dict) else None) or [] if isinstance(r, dict)]
    rows += _lines(inbox(base) / LINK_FEEDBACK)
    for r in rows:
        if r.get("a") and r.get("b"):
            pairs.add(frozenset((str(r["a"]), str(r["b"]))))
    return {"place": place, "people": people, "links": pairs}


def place_items(base: Path, done: set) -> list[dict]:
    _, items = _quiz(base)
    out = []
    for q in items:
        qid = str(q.get("id") or "")
        if not PQ.match(qid) or qid in done:
            continue
        candidates = [c for c in q.get("candidates") or [] if isinstance(c, dict) and str(c.get("name") or "").strip()]
        options = [{"id": f"c{i}", "label": str(c["name"]).strip()[:40]} for i, c in enumerate(candidates[:OPTIONS_MAX - 1])]
        options.append({"id": "not_place", "label": "場所ではない"})
        current = q.get("current") if isinstance(q.get("current"), dict) else {}
        unnamed = str(current.get("tier") or "") == "none"
        minutes = q.get("minutes") if isinstance(q.get("minutes"), (int, float)) and not isinstance(q.get("minutes"), bool) else 0
        where = str(q.get("where") or "")
        out.append({"id": qid, "kind": "place_unnamed" if unnamed else "place",
                    "title": str(q.get("question") or "ここはどこですか？")[:80],
                    "detail": f"{q.get('day', '')} {q.get('start', '')}〜{q.get('end', '')}・{int(minutes)} 分" + (f"・{where}" if where else ""),
                    "weight": float(max(0, min(1000, minutes / 2))), "day": str(q.get("day") or ""), "pl": None, "pe": None,
                    "text": True, "options": options[:OPTIONS_MAX]})
    return out


def person_items(base: Path, done: set) -> list[dict]:
    data = _json(Path(base) / "state" / "name_candidates.json")
    out = []
    for c in (data.get("candidates") if isinstance(data, dict) else None) or []:
        if not isinstance(c, dict):
            continue
        cid, raw = str(c.get("id") or ""), str(c.get("raw") or "").strip()
        if not NC.match(cid) or cid in done or not raw:
            continue
        options = []
        for s in c.get("suggest") or []:
            if isinstance(s, dict) and PE.match(str(s.get("pe") or "")) and str(s.get("name") or "").strip():
                options.append({"id": str(s["pe"]), "label": str(s["name"]).strip()[:40]})
        if not options:
            continue
        options = options[:OPTIONS_MAX - 1] + [{"id": "none", "label": "どれでもない"}]
        count = c.get("count") if isinstance(c.get("count"), (int, float)) and not isinstance(c.get("count"), bool) else 0
        out.append({"id": cid, "kind": "person", "title": f"「{raw[:30]}」は、この中のだれですか？",
                    "detail": f"{str(c.get('kind') or '').replace('_', ' ')}・{int(count)} 件", "weight": float(max(0, min(1000, count))),
                    "day": "", "pl": None, "pe": None, "text": False, "options": options[:OPTIONS_MAX]})
    return out


def checkups(base: Path) -> dict:
    done = answered(base)
    quiz, _ = _quiz(base)
    names = _json(Path(base) / "state" / "name_candidates.json")
    items = place_items(base, done["place"]) + person_items(base, done["people"])
    items.sort(key=lambda i: -i["weight"])
    stamp = ""
    for d in (quiz, names if isinstance(names, dict) else None):
        if d and str(d.get("generated_at") or d.get("to") or "") > stamp:
            stamp = str(d.get("generated_at") or d.get("to") or "")
    return {"available": quiz is not None or isinstance(names, dict), "generated_at": stamp, "items": items[:ITEMS_MAX]}


def _event_titles(base: Path, day: str, ids: set) -> dict[str, str]:
    out = {}
    for row in _lines(Path(base) / "digests" / "events" / f"{day}.jsonl"):
        if row.get("id") in ids:
            out[row["id"]] = re.sub(r"\s+", " ", str(row.get("title") or "")).strip()
    return out


def link_candidates(base: Path) -> dict:
    data = _json(Path(base) / "state" / "link_night_candidates.json")
    if not isinstance(data, dict):
        return {"available": False, "generated_at": "", "items": []}
    pairs = answered(base)["links"]
    out, stamp = [], ""
    for day in sorted((data.get("days") or {}), reverse=True)[:3]:
        entry = data["days"][day]
        if not isinstance(entry, dict):
            continue
        stamp = max(stamp, str(entry.get("at") or ""))
        rows = [c for c in entry.get("candidates") or [] if isinstance(c, dict) and c.get("status", "candidate") == "candidate"
                and EV.match(str(c.get("a") or "")) and EV.match(str(c.get("b") or ""))]
        titles = _event_titles(base, day, {c["a"] for c in rows} | {c["b"] for c in rows})
        for c in rows:
            if frozenset((c["a"], c["b"])) in pairs:
                continue
            conf = c.get("conf") if isinstance(c.get("conf"), (int, float)) and not isinstance(c.get("conf"), bool) else 0.5
            out.append({"id": f"lk:{c['a']}:{c['b']}", "kind": "link", "source": "night",
                        "title": f"「{titles.get(c['a'], '？')[:24]}」と「{titles.get(c['b'], '？')[:24]}」はつながっていますか？",
                        "detail": str(c.get("why") or "")[:100], "weight": float(max(0, min(1000, conf * 100))), "day": day,
                        "pl": None, "pe": None, "text": False,
                        "options": [{"id": "yes", "label": "つながっている"}, {"id": "no", "label": "ちがう"}]})
    out.sort(key=lambda i: -i["weight"])
    return {"available": True, "generated_at": stamp, "items": out[:ITEMS_MAX]}


# MARK: - 答えを足す


def _text(value, limit: int, what: str, required: bool = False) -> str | None:
    if value is None or (isinstance(value, str) and not value.strip()):
        if required:
            raise Bad(400, f"{what} がありません")
        return None
    if not isinstance(value, str):
        raise Bad(400, f"{what} は文字です")
    return " ".join(value.split())[:limit]


def _number(value, what: str, low: float, high: float) -> float | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not low <= float(value) <= high:
        raise Bad(400, f"{what} が決まりに合いません")
    return float(value)


def _object(data: bytes) -> dict:
    try:
        body = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise Bad(400, "中身が JSON ではありません") from None
    if not isinstance(body, dict):
        raise Bad(400, "中身が JSON ではありません")
    return body


def _day_start(day: str | None, at: str | None) -> tuple[str | None, str | None]:
    moment = None
    if at:
        try:
            moment = datetime.datetime.fromisoformat(at.replace("Z", "+00:00"))
        except ValueError:
            moment = None
    if day is not None and not DAY.match(day):
        raise Bad(400, "day は YYYY-MM-DD です")
    if day is None and moment is not None:
        day = moment.strftime("%Y-%m-%d")
    return day, (moment.strftime("%H:%M") if moment else None)


def place_name(base: Path, data: bytes) -> dict:
    """POST /place-names。アプリで直した名前 → inbox/place_answers.jsonl（答え合わせの答えの形に変える）"""
    body = _object(data)
    name = _text(body.get("name"), NAME_MAX, "name", required=True)
    lat = _number(body.get("lat"), "lat", -90, 90)
    lon = _number(body.get("lon"), "lon", -180, 180)
    if (lat is None) != (lon is None):
        raise Bad(400, "lat と lon は両方か、両方なしです")
    pl = _text(body.get("pl"), 48, "pl")
    if pl is not None and not PL.match(pl):
        raise Bad(400, "pl は pl_ で始まる番号です")
    origin = _text(body.get("from"), 20, "from") or "app"
    origin = origin if origin in FROMS else "app"
    day, at_clock = _day_start(_text(body.get("day"), 10, "day"), _text(body.get("at"), 40, "at"))
    # 答え合わせの材料（同じ日で 150 m 以内の問）に当たれば、その問の番号と始まりの時刻を使う（母艦が同じ滞在に戻せる）
    matched = None
    if lat is not None and day:
        best = None
        _, items = _quiz(base)
        for q in items:
            if q.get("day") != day or not isinstance(q.get("lat"), (int, float)) or not isinstance(q.get("lon"), (int, float)):
                continue
            d = _meters(lat, lon, float(q["lat"]), float(q["lon"]))
            if d <= LATLON_NEAR_M and PQ.match(str(q.get("id") or "")) and (best is None or d < best[0]):
                best = (d, q)
        matched = best[1] if best else None
    if matched:
        qid, start = str(matched["id"]), str(matched.get("start") or "")
    else:
        digest = hashlib.sha256(f"{name}|{lat}|{lon}|{pl}|{day}|{at_clock}".encode("utf-8")).hexdigest()[:10]
        qid, start = f"pn_{digest}", at_clock or ""
    if any(r.get("id") == qid and r.get("name") == name for r in _lines(inbox(base) / PLACE_ANSWERS)):
        return {"ok": True, "id": qid, "matched": bool(matched), "duplicate": True}
    row = {"id": qid, "day": day or "", "start": start, "name": name, "choice": "typed", "at": now_iso(), "from": origin}
    if lat is not None:
        row.update({"lat": round(lat, 5), "lon": round(lon, 5)})
    if pl:
        row["pl"] = pl
    append_line(base, PLACE_ANSWERS, row)
    return {"ok": True, "id": qid, "matched": bool(matched)}


def checkup_answer(base: Path, data: bytes) -> dict:
    """POST /checkups/answer。母艦の列の問の答え（人を勝手にまとめない。記録するだけ）"""
    body = _object(data)
    qid = _text(body.get("id"), 80, "id", required=True)
    kind = _text(body.get("kind"), 20, "kind", required=True)
    value = _text(body.get("value"), 64, "value", required=True)
    text = _text(body.get("text"), NAME_MAX, "text")
    if kind not in KINDS_POST:
        raise Bad(422, "この種類の答えは母艦には送りません")
    if value == "skip":
        return {"ok": True, "recorded": "skipped"}
    if kind in ("place", "place_unnamed"):
        if not PQ.match(qid):
            raise Bad(400, "id が決まりに合いません")
        _, items = _quiz(base)
        q = next((i for i in items if i.get("id") == qid), None)
        if value == "text":
            if not text:
                raise Bad(400, "text がありません")
            name, choice = text, "typed"
        elif value == "not_place":
            name, choice = "", "not_place"
        elif re.fullmatch(r"c\d", value):
            cands = [c for c in (q or {}).get("candidates") or [] if isinstance(c, dict) and str(c.get("name") or "").strip()]
            index = int(value[1])
            if q is None or index >= len(cands):
                raise Bad(409, "その問は、いまの答え合わせの材料にありません")
            name, choice = str(cands[index]["name"]).strip()[:NAME_MAX], "candidate"
        else:
            raise Bad(400, "value が決まりに合いません")
        day = (q or {}).get("day") or _text(body.get("day"), 10, "day") or ""
        if day and not DAY.match(str(day)):
            raise Bad(400, "day は YYYY-MM-DD です")
        if any(r.get("id") == qid for r in _lines(inbox(base) / PLACE_ANSWERS)):
            return {"ok": True, "recorded": PLACE_ANSWERS, "duplicate": True}
        row = {"id": qid, "day": day, "start": str((q or {}).get("start") or ""), "name": name, "choice": choice, "at": now_iso(),
               "from": "checkup"}
        pl = _text(body.get("pl"), 48, "pl")
        if pl and PL.match(pl):
            row["pl"] = pl
        append_line(base, PLACE_ANSWERS, row)
        return {"ok": True, "recorded": PLACE_ANSWERS}
    if kind == "person":
        if not NC.match(qid):
            raise Bad(400, "id が決まりに合いません")
        if value == "none":
            row = {"id": qid, "verdict": "no", "pe": None}
        elif PE.match(value):
            row = {"id": qid, "verdict": "yes", "pe": value}
        else:
            raise Bad(400, "value が決まりに合いません")
        if any(r.get("id") == qid for r in _lines(inbox(base) / NAME_ANSWERS)):
            return {"ok": True, "recorded": NAME_ANSWERS, "duplicate": True}
        append_line(base, NAME_ANSWERS, dict(row, at=now_iso(), by="app"))
        return {"ok": True, "recorded": NAME_ANSWERS}
    # link
    parts = qid.split(":")
    if len(parts) != 3 or parts[0] != "lk" or not EV.match(parts[1]) or not EV.match(parts[2]):
        raise Bad(400, "id が決まりに合いません")
    if value not in ("yes", "no"):
        raise Bad(400, "value が決まりに合いません")
    pair = frozenset((parts[1], parts[2]))
    if pair in answered(base)["links"]:
        return {"ok": True, "recorded": LINK_FEEDBACK, "duplicate": True}
    append_line(base, LINK_FEEDBACK, {"a": parts[1], "b": parts[2], "verdict": "sure" if value == "yes" else "cut", "at": now_iso(),
                                      "by": "app"})
    return {"ok": True, "recorded": LINK_FEEDBACK}


# MARK: - 受け口


def http_get(handler, path: str, config: dict, log: Callable[[str], None]) -> None:
    base = mothership.home(config)
    try:
        reply = checkups(base) if path == "/checkups" else link_candidates(base)
    except Exception as error:  # noqa: BLE001 — 読めなくても受け付けは続ける
        log(f"{path}: 読めませんでした（{type(error).__name__}）")
        handler.send_json(200, {"available": False, "generated_at": "", "items": []})
        return
    log(f"{handler.client_address[0]} から {path}: {len(reply['items'])} 件")
    handler.send_json(200, reply)


def http_post(handler, path: str, config: dict, log: Callable[[str], None]) -> None:
    try:
        length = int(handler.headers.get("Content-Length") or 0)
    except ValueError:
        length = 0
    if length <= 0 or length > BODY_LIMIT:
        handler.discard_body()
        handler.send_json(400 if length <= 0 else 413, {"error": "中身がありません" if length <= 0 else "長すぎます"})
        return
    data = handler.rfile.read(length)
    base = mothership.home(config)
    try:
        reply = place_name(base, data) if path == "/place-names" else checkup_answer(base, data)
    except Bad as error:
        log(f"{handler.client_address[0]} から {path}: {error.status}")
        handler.send_json(error.status, {"error": error.message})
        return
    except Exception as error:  # noqa: BLE001
        log(f"{path}: 足せませんでした（{type(error).__name__}）")
        handler.send_json(500, {"error": "母艦に足せませんでした"})
        return
    log(f"{handler.client_address[0]} から {path}: 受けました" + ("（もう受けていた）" if reply.get("duplicate") else ""))
    handler.send_json(200, reply)
