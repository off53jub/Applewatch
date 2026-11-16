"""LifeLog PC: 地名を聞き取りと聞き間違いの直しに使うための、地名の集め場（強化案 85・99・100。2026-11-16）。

番号は母艦の docs/system-proposal-2026-11-13.md の「追記 7」。ここは**読むだけ**（母艦にも書かない）。
どの入り口も、ファイルが無ければ「地名なし」として何もしない（今のまま動く）。

地名の出どころ（母艦 = mothership.home。ふだんは D:\\Lifelog）:
  1. state/places-index.json（母艦の場所の担当が作る台帳。形はゆるく読む:
       {"places": [...]} か {"items": [...]} か 配列。1 件は name（または canonical）・aliases/names（別名）・
       reading（よみ）・kind・tier・days/visits・last_seen を持てる。無い項目は飛ばす。kind が mentioned・tier が none の
       「話に出ただけの地名」は使わない（ノイズが多い。2026-11-16 の実データ）。2026-11-16 に場所の担当が作った形に合わせた）
  2. 無ければ state/places_for_app.json（items: name・sure・visit_days・last_day）
  3. digests/timeline/<日>.json の「位置」の行（place）= その日いた所（時刻つき）
  4. archive/calendar/YYYY/MM/DD.md の「場所:」= 予定の場所
  5. この PC の records/<日>.json の会話の place（アプリが付けた、その時間にいた所）
  6. 地名の辞書（任意。HOME/gazetteer/*.tsv。1 行 = 名前<TAB>よみ（かな）<TAB>種類。無くてよい。ダウンロードはしない）

使い方:
  words_at(base, epoch)  その時刻にいた所・最寄り駅・今日の予定の場所・よく行く所の名前（近い順・数に上限）
  known_names(base, day)  その日に使える名前の一覧（聞き間違いの照合用。名前・よみ・どこから）
  gazetteer_names()       辞書の名前（無ければ空）
自宅・職場のような一般の呼び名は、聞き取りの手がかりにならないので入れない（GENERIC）。
文・人名は記録（log.txt）に書かない。
"""

from __future__ import annotations

import datetime
import json
import os
import re
import threading
import time
import unicodedata
from pathlib import Path

PLACE_WORDS_MAX = 6            # 1 つの区切りに足す地名の数
GENERIC = {"自宅", "職場", "家", "会社", "名前なし", "不明", "どこか", "移動中", "移動", "場所なし"}
HOME_DIR = Path(os.environ.get("LOCALAPPDATA") or Path.home() / ".local" / "share") / "LifeLogPC"
GAZETTEER_DIR = HOME_DIR / "gazetteer"
LOOKBACK_DAYS = 14             # よく行く所を数える日数の目安（台帳の last_day で見る）
FREQUENT_MIN_VISITS = 2        # 「よく行く」の目安（来た日数）
NAME_MIN, NAME_MAX = 2, 24
STAY_CACHE_SEC = 120.0

MAYBE = re.compile(r"^(?:たぶん|多分|おそらく)[\s　]*")
NEAR = re.compile(r"(?:付近|近く|周辺)$")
STATION = re.compile(r"^(.{1,12}?駅)")
CAL_TIME = re.compile(r"^\s*-\s+(\d{1,2}):(\d{2})(?:\s*-\s*(\d{1,2}):(\d{2}))?\s+(.*)$")
CAL_PLACE = re.compile(r"^\s+-\s+場所:\s*(.+)$")

_lock = threading.Lock()
_cache: dict = {}


def clean_name(raw: str) -> str:
    """「たぶん◯◯」「◯◯付近」「◯◯駅近く」を、名前だけにする。一般の呼び名・短すぎ・長すぎは空"""
    name = unicodedata.normalize("NFKC", str(raw or "")).strip()
    name = MAYBE.sub("", name)
    name = NEAR.sub("", name).strip()
    name = re.sub(r"[（(].*?[）)]", "", name).strip()
    if name in GENERIC or not (NAME_MIN <= len(name) <= NAME_MAX):
        return ""
    return name


def _read_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return None


def _cached(key, loader, ttl: float = STAY_CACHE_SEC):
    now = time.time()
    with _lock:
        hit = _cache.get(key)
        if hit and now - hit[0] < ttl:
            return hit[1]
    value = loader()
    with _lock:
        _cache[key] = (now, value)
    return value


def clear_cache() -> None:
    with _lock:
        _cache.clear()


# MARK: - 台帳


def _entries(data) -> list:
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        for key in ("places", "items", "entries"):
            if isinstance(data.get(key), list):
                return data[key]
        if data and all(isinstance(v, dict) for v in data.values()):
            return list(data.values())
    return []


def load_places(base: Path) -> list[dict]:
    """台帳の場所 [{"name", "names": [別名...], "reading", "kind", "sure", "visits", "last_day"}]。無ければ空"""
    def load() -> list[dict]:
        out: list[dict] = []
        for rel in ("state/places-index.json", "state/places_for_app.json"):
            data = _read_json(Path(base) / rel)
            rows = _entries(data)
            if not rows:
                continue
            for row in rows:
                if not isinstance(row, dict):
                    continue
                name = clean_name(row.get("name") or row.get("canonical") or "")
                # 話に出ただけの地名（kind mentioned・tier none）は、行った所の証拠ではなくノイズが多いので使わない
                if not name or row.get("kind") == "mentioned" or row.get("tier") == "none":
                    continue
                aliases = row.get("aliases") or row.get("names") or []
                names = [name] + [a for a in (clean_name(x) for x in aliases if isinstance(x, str)) if a and a != name]
                visits = row.get("visit_days") if row.get("visit_days") is not None else (row.get("days") if row.get("days") is not None else row.get("visits"))
                out.append({"name": name, "names": names, "reading": str(row.get("reading") or row.get("yomi") or ""),
                            "kind": str(row.get("kind") or ""), "tier": str(row.get("tier") or ""), "sure": bool(row.get("sure", row.get("confidence", 0) in (1, True))),
                            "visits": int(visits) if isinstance(visits, (int, float)) and not isinstance(visits, bool) else 0,
                            "last_day": str(row.get("last_day") or row.get("last_seen") or "")})
            if out:
                break
        return out

    return _cached(("places", str(base)), load, ttl=600.0)


def frequent(base: Path, limit: int = 8) -> list[str]:
    places = [p for p in load_places(base) if p["visits"] >= FREQUENT_MIN_VISITS]
    places.sort(key=lambda p: (p["visits"], p["last_day"]), reverse=True)
    return [p["name"] for p in places[:limit]]


# MARK: - その日いた所・予定の場所


def stays(base: Path, day: str) -> list[dict]:
    """digests/timeline/<日>.json の位置の行 [{"start": 分, "end": 分, "place": 名前}]（名前が使えない行は除く）"""
    def load() -> list[dict]:
        data = _read_json(Path(base) / "digests" / "timeline" / f"{day}.json")
        out = []
        for row in (data.get("rows") if isinstance(data, dict) else None) or []:
            if not isinstance(row, dict) or row.get("lane") != "位置":
                continue
            name = clean_name(row.get("place") or "")
            start = _minutes(row.get("time"))
            if not name or start is None:
                continue
            end = _minutes(row.get("end"))
            out.append({"start": start, "end": end if end is not None else start, "place": name})
        return out

    return _cached(("stays", str(base), day), load)


def _minutes(text) -> int | None:
    m = re.fullmatch(r"(\d{1,2}):(\d{2})", str(text or "").strip())
    return int(m[1]) * 60 + int(m[2]) if m else None


def calendar_places(base: Path, day: str) -> list[dict]:
    """その日の予定の場所 [{"start": 分 or None, "place": 名前}]"""
    def load() -> list[dict]:
        path = Path(base) / "archive" / "calendar" / day[:4] / day[5:7] / f"{day[8:10]}.md"
        try:
            lines = path.read_text(encoding="utf-8-sig").splitlines()
        except OSError:
            return []
        out, start = [], None
        for line in lines:
            m = CAL_TIME.match(line)
            if m and not line.lstrip().startswith("- 場所"):
                start = int(m[1]) * 60 + int(m[2])
                continue
            m = CAL_PLACE.match(line)
            if m:
                # 「名前（住所）」の名前だけ。住所・URL は聞き取りの手がかりにならない
                head = re.split(r"[（(]", m[1])[0].strip()
                name = clean_name(head)
                if name and not name.startswith("http"):
                    out.append({"start": start, "place": name})
        return out

    return _cached(("cal", str(base), day), load)


def record_places(home: Path, day: str) -> list[dict]:
    """この PC の records/<日>.json の会話の place（アプリが付けた、その時間にいた所）[{"start_ms", "end_ms", "place"}]"""
    def load() -> list[dict]:
        data = _read_json(Path(home) / "records" / f"{day}.json")
        out = []
        for c in (data.get("conversations") if isinstance(data, dict) else None) or []:
            if not isinstance(c, dict):
                continue
            name = clean_name(c.get("place") or "")
            try:
                start = datetime.datetime.fromisoformat(str(c.get("start")).replace("Z", "+00:00")).timestamp()
                end = datetime.datetime.fromisoformat(str(c.get("end")).replace("Z", "+00:00")).timestamp()
            except (ValueError, TypeError):
                continue
            if name:
                out.append({"start": start, "end": end, "place": name})
        return out

    return _cached(("rec", str(home), day), load)


def nearest_stations(names: list[str]) -> list[str]:
    """名前の中から駅名（◯◯駅）を取り出す（「◯◯駅近く」は clean_name で駅名になっている）"""
    out = []
    for name in names:
        m = STATION.match(name)
        if m and m[1] not in out:
            out.append(m[1])
    return out


# MARK: - 聞き取りのヒント（99）


def words_at(base: Path, epoch: float, span: float = 300.0, home: Path | None = None,
             extra: list[str] | None = None, limit: int = PLACE_WORDS_MAX) -> list[str]:
    """その時刻（から span 秒）にいた所 → 最寄りの駅 → 今日の予定の場所 → よく行く所 の順に、重ならない名前を limit まで。
    どれも無ければ空（そのときは、渡すヒントは今のまま）"""
    when = datetime.datetime.fromtimestamp(epoch)
    day = when.strftime("%Y-%m-%d")
    minute = when.hour * 60 + when.minute
    end_minute = minute + int(span // 60)
    here: list[str] = [clean_name(x) for x in (extra or [])]
    for s in stays(base, day):
        if s["start"] <= end_minute and max(s["end"], s["start"]) >= minute - 5:
            here.append(s["place"])
    if home is not None:
        for r in record_places(home, day):
            if r["start"] - 300 <= epoch + span and r["end"] + 300 >= epoch:
                here.append(r["place"])
    ordered = [h for h in here if h]
    ordered += nearest_stations(ordered)
    ordered += [c["place"] for c in calendar_places(base, day)]
    ordered += frequent(base)
    out: list[str] = []
    for name in ordered:
        if name and name not in out:
            out.append(name)
        if len(out) >= limit:
            break
    return out


# MARK: - 聞き間違いの照合用（100）


def known_names(base: Path, day: str, home: Path | None = None) -> list[dict]:
    """その日の聞き間違いを照らす名前 [{"name", "reading", "origin"}]（origin: stay・calendar・record・ledger）"""
    seen: dict[str, dict] = {}

    def add(name: str, origin: str, reading: str = "") -> None:
        name = clean_name(name)
        if name and name not in seen:
            seen[name] = {"name": name, "reading": reading, "origin": origin}

    for s in stays(base, day):
        add(s["place"], "stay")
    for c in calendar_places(base, day):
        add(c["place"], "calendar")
    if home is not None:
        for r in record_places(home, day):
            add(r["place"], "record")
    for p in load_places(base):
        # アプリの推測（tier maybe の店など）は聞き間違いの照らし先にしない（推測が外れていると、ふつうの語を地名に直す候補が出る）。
        # 確かな名前（登録・本人の答え・証拠）と、駅・町の名前だけ。聞き取りのヒント（words_at）は推測の名前も使う
        if not (p["tier"] in ("registered", "user", "evidence") or p["kind"] in ("station", "town") or (not p["tier"] and p["sure"])):
            continue
        for n in p["names"]:
            add(n, "ledger", p["reading"] if n == p["name"] else "")
    return list(seen.values())


# MARK: - 地名の辞書（任意。ダウンロードはしない）


def gazetteer_names() -> list[dict]:
    """HOME/gazetteer/*.tsv の [{"name", "reading", "kind"}]。フォルダが無ければ空（今のまま動く）"""
    def load() -> list[dict]:
        out = []
        try:
            files = sorted(GAZETTEER_DIR.glob("*.tsv"))
        except OSError:
            return []
        for path in files:
            try:
                text = path.read_text(encoding="utf-8-sig")
            except OSError:
                continue
            for line in text.splitlines():
                parts = line.split("\t")
                if len(parts) < 2 or line.startswith("#"):
                    continue
                name = clean_name(parts[0])
                reading = parts[1].strip()
                if name and reading:
                    out.append({"name": name, "reading": reading, "kind": parts[2].strip() if len(parts) > 2 else ""})
        return out

    return _cached(("gaz", str(GAZETTEER_DIR)), load, ttl=3600.0)
