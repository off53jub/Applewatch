"""1日の流れを1つに・PayPay の写真・位置を当日のうちに・反映の見張り（2026-11-14。強化案 25・28・30・34）。

番号は母艦の docs/system-proposal-2026-11-13.md の「追記（2026-11-14）」。決まりは担当どうしの約束（contract-2026-11-14）。
- GET /timeline?day=YYYY-MM-DD（features の "timeline"）← 母艦の digests/timeline/YYYY-MM-DD.json（母艦が md の隣に作る）。
  直近 14 日だけ。無い・読めない・形が違うときは {"available": false, "reason"}。行の型・長さ・lane を確かめ、おかしな行は落とす。
- POST /pay/paypay-shot（"paypayshot"。Claude が使えるときだけ）: PayPay の取引履歴の画面のスクリーンショット 1 枚（JPEG・4MB まで）。
  pc/claude.py の light（画像つき）で読み、{"rows": [{"time": ISO|null, "day", "shop", "amount", "method"}]} を返す。
  画像はどこにも保存しない（読んだら捨てる）。PayPay の画面でなければ 422（やさしい文で断る）。
- POST /pay/paypay-rows {"rows": [...]}（"paypayrows"。Claude が無くても受ける）: 本人が「取り込む」を押した行 → 母艦の inbox/paypay_shots.jsonl に
  1 行ずつ {…, "at"}（同じ行は 2 回足さない）。
- POST /location/stays {"stays": [...]}（"livestays"）: アプリが送る滞在 → 母艦の inbox/location_live.jsonl（start で重ねない。
  同じ start が来たら新しい方に置き換える）。
- GET /reflection（"reflection"）← 母艦の state/reflection.json（要素 × 反映先の「最後に反映された日」。形は母艦が決めるので、
  いくつかの形を読めるようにし、知らない要素・反映先も文のまま通す）。
中身（店の名前・金額・場所の名前・座標）は記録（log.txt）に書かない（件数だけ）。
"""

from __future__ import annotations

import datetime
import json
import re
import threading
from pathlib import Path
from urllib.parse import parse_qs, urlparse

TIMELINE_DIR = Path("digests") / "timeline"
PAYPAY_SHOTS = Path("inbox") / "paypay_shots.jsonl"
LOCATION_LIVE = Path("inbox") / "location_live.jsonl"
REFLECTION = Path("state") / "reflection.json"

LANES = ("会話", "位置", "決済", "LINE", "予定", "写真", "閲覧", "PC", "iPhone", "体調", "天気", "注文")
TIMELINE_DAYS = 14
TIMELINE_ROWS = 600
SHOT_LIMIT = 4 * 1024 * 1024
SHOT_ROWS = 60
SHOT_PURPOSE = "paypay-shot"
SHOT_TOKENS = 4096
SHOT_TIMEOUT = 90.0
ROWS_LIMIT = 200
STAYS_LIMIT = 300
STAY_KINDS = ("home", "work", "shop", "other")
REFLECTION_ELEMENTS = 40
REFLECTION_DESTINATIONS = ("取り込み", "年表", "朝のまとめ", "アプリへの配り", "ノート")
REFLECTION_MORE = 8

GETS = ("/timeline", "/reflection")
LIMITS = {"/pay/paypay-shot": SHOT_LIMIT, "/pay/paypay-rows": 256 * 1024, "/location/stays": 512 * 1024}

DAY = re.compile(r"\d{4}-\d{2}-\d{2}")
CLOCK = re.compile(r"([01]\d|2[0-3]):[0-5]\d")
ISO = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?(\.\d+)?(Z|[+-]\d{2}:?\d{2})?")
_lock = threading.Lock()


def features() -> list[str]:
    """/hello の features に足す名前。PayPay の写真は Claude が使えるときだけ"""
    # "paypayrows": 確かめた行を母艦へ（Claude が今月の上限に届いても、読み終えた行は送れるように別の名前にした）
    found = ["timeline", "paypayrows", "livestays", "reflection"]
    try:
        import claude

        if claude.available():
            found.append("paypayshot")
    except Exception:  # noqa: BLE001 — Claude の部品が読めなくても、ほかは出す
        pass
    return found


def _text(value, n: int) -> str:
    return " ".join(str(value).split())[:n] if isinstance(value, str) else ""


def _day(value) -> str | None:
    if not isinstance(value, str) or not DAY.fullmatch(value):
        return None
    try:
        datetime.date.fromisoformat(value)
    except ValueError:
        return None
    return value


def _moment(value) -> datetime.datetime | None:
    if not isinstance(value, str) or not ISO.fullmatch(value):
        return None
    try:
        when = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return when if when.tzinfo is not None else when.astimezone()


def _int(value, low: int, high: int) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    return value if low <= value <= high else None


def _float(value, low: float, high: float) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value != value:
        return None
    return float(value) if low <= value <= high else None


def _today() -> datetime.date:
    return datetime.datetime.now().astimezone().date()


def _now_iso() -> str:
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def _offset() -> str:
    """この PC の時差（"+09:00"）"""
    text = datetime.datetime.now().astimezone().strftime("%z")
    return text[:3] + ":" + text[3:] if len(text) == 5 else "+09:00"


def _json_body(data: bytes, label: str) -> dict:
    try:
        body = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise ValueError(f"{label}が JSON ではありません") from None
    if not isinstance(body, dict):
        raise ValueError(f"{label}が JSON ではありません")
    return body


# MARK: - 1日の年表（25）


def read_timeline(base: Path, day: str | None, today: datetime.date | None = None) -> dict:
    """母艦の digests/timeline/<day>.json を確かめて返す。day が直近 14 日の外なら available false"""
    today = today or _today()
    if _day(day) is None:
        return {"available": False, "reason": "日付は YYYY-MM-DD です"}
    asked = datetime.date.fromisoformat(day)
    if not today - datetime.timedelta(days=TIMELINE_DAYS - 1) <= asked <= today:
        return {"available": False, "reason": f"年表は直近 {TIMELINE_DAYS} 日の分だけです"}
    try:
        data = json.loads((base / TIMELINE_DIR / f"{day}.json").read_text(encoding="utf-8-sig"))
    except FileNotFoundError:
        return {"available": False, "reason": "母艦のこの日の年表がまだありません"}
    except (OSError, ValueError) as error:
        return {"available": False, "reason": f"母艦の年表を読めませんでした: {type(error).__name__}"}
    if not isinstance(data, dict) or not isinstance(data.get("rows"), list):
        return {"available": False, "reason": "母艦の年表の形が違います"}
    if data.get("day") is not None and data.get("day") != day:
        return {"available": False, "reason": "母艦の年表の日付が違います"}
    rows = []
    for x in data["rows"][:TIMELINE_ROWS * 2]:
        if not isinstance(x, dict) or not isinstance(x.get("time"), str) or not CLOCK.fullmatch(x["time"]):
            continue
        lane, text, end = x.get("lane"), _text(x.get("text"), 80), x.get("end")
        if lane not in LANES or not text:
            continue
        if end is not None and not (isinstance(end, str) and CLOCK.fullmatch(end)):
            continue
        amount = x.get("amount")
        place = x.get("place")
        rows.append({"time": x["time"], "end": end, "lane": lane, "text": text,
                     "amount": _int(amount, 0, 999_999_999) if amount is not None else None,
                     "place": (_text(place, 40) or None) if place is not None else None})
        if len(rows) >= TIMELINE_ROWS:
            break
    rows.sort(key=lambda r: r["time"])  # 同じ時刻は母艦の並びのまま（並べ直しは安定）
    version = _int(data.get("version"), 1, 1000) or 1
    generated = data.get("generated_at") if isinstance(data.get("generated_at"), str) and _moment(data["generated_at"]) else None
    return {"available": True, "version": version, "day": day, "generated_at": generated, "rows": rows}


def timeline_day(handler) -> str | None:
    """GET /timeline?day= の day（無ければ今日）"""
    query = parse_qs(urlparse(handler.path).query)
    values = query.get("day") or []
    return values[0] if values else _today().isoformat()


# MARK: - 反映の見張り（34）


def _last_day(value) -> str | None:
    """「最後に反映された日」の値（"YYYY-MM-DD"・ISO の日時・{"day": …}・{"last": …}）。読めなければ None"""
    if isinstance(value, dict):
        for name in ("day", "last", "date", "at"):
            if name in value:
                return _last_day(value[name])
        return None
    if not isinstance(value, str):
        return None
    head = value[:10]
    if _day(head) is None:
        return None
    if len(value) > 10 and _moment(value) is None:
        return None
    return head


def _element_rows(data: dict) -> list[tuple[str, dict]]:
    """要素ごとの（名前, {反映先: 値}）。要素の並びは母艦のまま"""
    raw = None
    for name in ("elements", "rows", "items", "matrix"):
        if name in data:
            raw = data[name]
            break
    out: list[tuple[str, dict]] = []
    if isinstance(raw, dict):
        for element, cells in raw.items():
            if isinstance(element, str) and isinstance(cells, dict):
                out.append((element, cells))
    elif isinstance(raw, list):
        for x in raw:
            if not isinstance(x, dict):
                continue
            element = next((x[k] for k in ("element", "name", "label", "key") if isinstance(x.get(k), str)), None)
            if element is None:
                continue
            cells = None
            for name in ("last", "destinations", "cells", "days", "reflected"):
                if isinstance(x.get(name), dict):
                    cells = x[name]
                    break
            if cells is None:
                cells = {k: v for k, v in x.items() if k not in ("element", "name", "label", "key")}
            out.append((element, cells))
    return out


def read_reflection(base: Path) -> dict:
    """母艦の state/reflection.json を確かめて、{"destinations": [...], "elements": [{"element", "cells": [日|None]}]} で返す"""
    try:
        data = json.loads((base / REFLECTION).read_text(encoding="utf-8-sig"))
    except FileNotFoundError:
        return {"available": False, "reason": "母艦の反映の見張りがまだありません"}
    except (OSError, ValueError) as error:
        return {"available": False, "reason": f"母艦の反映の見張りを読めませんでした: {type(error).__name__}"}
    if not isinstance(data, dict):
        return {"available": False, "reason": "母艦の反映の見張りの形が違います"}
    rows = _element_rows(data)
    if not rows and not any(k in data for k in ("elements", "rows", "items", "matrix")):
        return {"available": False, "reason": "母艦の反映の見張りの形が違います"}
    listed = data.get("destinations") if isinstance(data.get("destinations"), list) else []
    destinations: list[str] = []
    for d in list(listed) + list(REFLECTION_DESTINATIONS):
        name = _text(d, 20) if isinstance(d, str) else ""
        if name and name not in destinations:
            destinations.append(name)
    for _, cells in rows:
        for key in cells:
            name = _text(key, 20) if isinstance(key, str) else ""
            if (name and name not in destinations and _last_day(cells[key]) is not None
                    and len(destinations) < len(REFLECTION_DESTINATIONS) + REFLECTION_MORE):
                destinations.append(name)
    elements, seen = [], set()
    for element, cells in rows:
        name = _text(element, 20)
        if not name or name in seen:
            continue
        seen.add(name)
        clean = {_text(k, 20): v for k, v in cells.items() if isinstance(k, str)}
        elements.append({"element": name, "cells": [_last_day(clean.get(d)) for d in destinations]})
        if len(elements) >= REFLECTION_ELEMENTS:
            break
    generated = data.get("generated_at") if isinstance(data.get("generated_at"), str) and _moment(data["generated_at"]) else None
    return {"available": True, "version": _int(data.get("version"), 1, 1000) or 1, "generated_at": generated,
            "today": _today().isoformat(), "destinations": destinations, "elements": elements}


def http_get(handler, base: Path) -> None:
    path = urlparse(handler.path).path
    if path == "/timeline":
        day = timeline_day(handler)
        if _day(day) is None:
            handler.send_json(400, {"error": "day は YYYY-MM-DD です"})
            return
        handler.send_json(200, read_timeline(base, day))
        return
    handler.send_json(200, read_reflection(base))


# MARK: - PayPay の取引履歴のスクリーンショット（28）

SHOT_SYSTEM = (
    "あなたはスマートフォンの画面の写真から、決済の記録を読み取る係です。\n"
    "入力は1枚の画像です。PayPay のアプリの「取引履歴」（支払いの一覧や、1件の支払いの詳しい画面）かどうかを、まず見分けます。\n"
    "決まり:\n"
    "- PayPay の取引履歴の画面でなければ is_paypay を false にし、rows は空にします。\n"
    "- PayPay の取引履歴なら is_paypay を true にし、画面に写っている「支払い」だけを rows に入れます。"
    "受け取り・送る・チャージ・返金・ポイントの付与は入れません。\n"
    "- date は支払いの日付を YYYY-MM-DD で書きます。画面に年が無いときは、入力の文にある今日の日付より後にならない、いちばん近い年にします。\n"
    "- clock は支払いの時刻を HH:MM（24時間）で書きます。画面に時刻が無ければ空の文字にします。\n"
    "- shop は画面に出ている支払い先の名前を、そのまま書きます。分からなければ空の文字にします。\n"
    "- amount は支払った金額を、円の整数で書きます（記号やカンマは付けません）。\n"
    "- method は画面に出ている支払いの手段（残高・クレジットなど）を短く書きます。分からなければ空の文字にします。\n"
    "- 画面に無いことを作ってはいけません。読めない行は入れません。\n"
    "- 答えは JSON だけにします。"
)
SHOT_SCHEMA = {
    "type": "object",
    "properties": {
        "is_paypay": {"type": "boolean"},
        "rows": {"type": "array", "items": {
            "type": "object",
            "properties": {"date": {"type": "string"}, "clock": {"type": "string"}, "shop": {"type": "string"},
                           "amount": {"type": "integer"}, "method": {"type": "string"}},
            "required": ["date", "clock", "shop", "amount", "method"], "additionalProperties": False}},
    },
    "required": ["is_paypay", "rows"], "additionalProperties": False,
}
NOT_PAYPAY = "PayPay の取引履歴の画面ではないようです。PayPay のアプリの「取引履歴」を写したものを選んでください"


class ShotRefused(Exception):
    """PayPay の画面ではなかった（422）"""


def check_jpeg(data: bytes) -> None:
    if len(data) < 64 or not data.startswith(b"\xff\xd8\xff"):
        raise ValueError("JPEG の画像ではありません")
    if len(data) > SHOT_LIMIT:
        raise ValueError("画像が大きすぎます（4MB まで）")


def clean_shot_rows(answer, today: datetime.date | None = None) -> list[dict]:
    """Claude の答えから、正しい行だけを取り出す（未来の日・1年より前の日・金額のおかしな行は捨てる）"""
    today = today or _today()
    if not isinstance(answer, dict):
        raise ValueError("答えの形が違います")
    if answer.get("is_paypay") is not True:
        raise ShotRefused(NOT_PAYPAY)
    rows = []
    for x in answer.get("rows") if isinstance(answer.get("rows"), list) else []:
        if not isinstance(x, dict):
            continue
        day = _day(x.get("date"))
        amount = _int(x.get("amount"), 1, 9_999_999)
        if day is None or amount is None:
            continue
        when = datetime.date.fromisoformat(day)
        if when > today + datetime.timedelta(days=1) or when < today - datetime.timedelta(days=400):
            continue
        clock = x.get("clock") if isinstance(x.get("clock"), str) and CLOCK.fullmatch(x["clock"]) else None
        rows.append({"time": f"{day}T{clock}:00{_offset()}" if clock else None, "day": day,
                     "shop": _text(x.get("shop"), 40), "amount": amount, "method": _text(x.get("method"), 20)})
        if len(rows) >= SHOT_ROWS:
            break
    return rows


def read_shot(data: bytes, log=None, today: datetime.date | None = None) -> list[dict]:
    """スクリーンショット 1 枚を Claude（light・画像）で読む。画像はどこにも書かない"""
    import claude

    check_jpeg(data)
    today = today or _today()
    prompt = f"今日の日付: {today.isoformat()}\nこの画像の支払いを読み取ってください。"
    got = claude.call(SHOT_SYSTEM, prompt, json=True, max_tokens=SHOT_TOKENS, tier="light", purpose=SHOT_PURPOSE,
                      work=False, schema=SHOT_SCHEMA, timeout=SHOT_TIMEOUT, log=log,
                      images=[("image/jpeg", data)])
    return clean_shot_rows(got.get("data"), today)


def http_post_shot(handler, base: Path, data: bytes, log) -> None:
    import claude

    try:
        rows = read_shot(data, log=log)
    except ValueError as error:
        handler.send_json(400, {"error": str(error)})
        return
    except ShotRefused as error:
        log(f"{handler.client_address[0]} から PayPay の写真: PayPay の画面ではないので断りました")
        handler.send_json(422, {"error": str(error)})
        return
    except claude.ClaudeError as error:
        log(f"{handler.client_address[0]} から PayPay の写真: {error.status} {claude.scrub(error.body.get('error', ''))}")
        handler.send_json(error.status, {"error": claude.scrub(str(error.body.get("error", "")))})
        return
    except Exception as error:  # noqa: BLE001 — 何があっても受け付けは続ける（画像は残さない）
        log(f"PayPay の写真を読めませんでした: {type(error).__name__}")
        handler.send_json(500, {"error": "PayPay の写真を読めませんでした"})
        return
    # 店の名前・金額は書かない（件数だけ）
    log(f"{handler.client_address[0]} から PayPay の写真を読みました: {len(rows)} 行")
    handler.send_json(200, {"rows": rows})


def parse_rows(data: bytes) -> list[dict]:
    """POST /pay/paypay-rows の中身。行が 1 つも正しくなければ ValueError"""
    body = _json_body(data, "PayPay の行")
    listed = body.get("rows")
    if not isinstance(listed, list) or not listed:
        raise ValueError("rows がありません")
    if len(listed) > ROWS_LIMIT:
        raise ValueError(f"rows は {ROWS_LIMIT} 行までです")
    rows = []
    for x in listed:
        if not isinstance(x, dict):
            raise ValueError("rows の行の形が違います")
        day, amount, shop = _day(x.get("day")), _int(x.get("amount"), 1, 9_999_999), x.get("shop")
        when, method = x.get("time"), x.get("method", "")
        if day is None or amount is None or not isinstance(shop, str) or len(shop.strip()) > 40:
            raise ValueError("rows の行は day・shop（40 文字まで）・amount（1 円以上）が要ります")
        if when is not None and (_moment(when) is None or str(when)[:10] != day):
            raise ValueError("time は ISO 8601 の日時で、day と同じ日です")
        if not isinstance(method, str) or len(method.strip()) > 20:
            raise ValueError("method は 20 文字までの文です")
        rows.append({"time": when, "day": day, "shop": _text(shop, 40), "amount": amount, "method": _text(method, 20)})
    return rows


def append_rows(base: Path, rows: list[dict]) -> int:
    """母艦の inbox/paypay_shots.jsonl に足す（同じ行＝time・day・shop・amount・method が同じものは足さない）。足した数"""
    path = base / PAYPAY_SHOTS
    at = _now_iso()
    with _lock:
        seen = set()
        try:
            for line in path.read_text(encoding="utf-8").splitlines():
                try:
                    old = json.loads(line)
                except ValueError:
                    continue
                if isinstance(old, dict):
                    seen.add(json.dumps({k: old.get(k) for k in ("time", "day", "shop", "amount", "method")},
                                        ensure_ascii=False, sort_keys=True))
        except FileNotFoundError:
            pass
        added = []
        for row in rows:
            key = json.dumps(row, ensure_ascii=False, sort_keys=True)
            if key in seen:
                continue
            seen.add(key)
            added.append(dict(row, at=at))
        if added:
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open("a", encoding="utf-8", newline="\n") as f:
                for row in added:
                    f.write(json.dumps(row, ensure_ascii=False) + "\n")
    return len(added)


def http_post_rows(handler, base: Path, data: bytes, log) -> None:
    try:
        rows = parse_rows(data)
    except ValueError as error:
        handler.send_json(400, {"error": str(error)})
        return
    try:
        added = append_rows(base, rows)
    except OSError as error:
        log(f"PayPay の行を母艦に置けませんでした: {type(error).__name__}")
        handler.send_json(503, {"error": "母艦に置けませんでした"})
        return
    log(f"{handler.client_address[0]} から PayPay の写真の行を母艦へ: {added} 行（届いたのは {len(rows)} 行）")
    handler.send_json(200, {"ok": True, "added": added})


# MARK: - 位置を当日のうちに（30）


def parse_stays(data: bytes) -> list[dict]:
    """POST /location/stays の中身。おかしな滞在は落とす。形が違えば ValueError"""
    body = _json_body(data, "滞在")
    listed = body.get("stays")
    if not isinstance(listed, list):
        raise ValueError("stays がありません")
    if len(listed) > STAYS_LIMIT:
        raise ValueError(f"stays は {STAYS_LIMIT} 件までです")
    stays = []
    for x in listed:
        if not isinstance(x, dict):
            continue
        start, end = x.get("start"), x.get("end")
        a = _moment(start)
        lat, lon = _float(x.get("lat"), -90, 90), _float(x.get("lon"), -180, 180)
        if a is None or lat is None or lon is None:
            continue
        if end is not None:
            b = _moment(end)
            if b is None or b < a:
                continue
        name, kind = x.get("name"), x.get("kind")
        if name is not None and not isinstance(name, str):
            continue
        if kind is not None and kind not in STAY_KINDS:
            continue
        stays.append({"start": start, "end": end, "lat": lat, "lon": lon,
                      "name": (_text(name, 60) or None) if name is not None else None, "kind": kind})
    return stays


def write_stays(base: Path, stays: list[dict]) -> tuple[int, int]:
    """母艦の inbox/location_live.jsonl に置く。同じ start は 1 行（新しい方に置き換え）。(足した数, 置き換えた数)"""
    path = base / LOCATION_LIVE
    at = _now_iso()
    with _lock:
        rows: list[dict] = []
        try:
            for line in path.read_text(encoding="utf-8").splitlines():
                try:
                    old = json.loads(line)
                except ValueError:
                    continue
                if isinstance(old, dict) and isinstance(old.get("start"), str):
                    rows.append(old)
        except FileNotFoundError:
            pass
        index = {r["start"]: i for i, r in enumerate(rows)}
        added = replaced = 0
        for stay in stays:
            row = dict(stay, at=at)
            if stay["start"] in index:
                old = rows[index[stay["start"]]]
                if {k: old.get(k) for k in stay} != stay:
                    rows[index[stay["start"]]] = row
                    replaced += 1
            else:
                index[stay["start"]] = len(rows)
                rows.append(row)
                added += 1
        if added or replaced:
            path.parent.mkdir(parents=True, exist_ok=True)
            tmp = path.with_suffix(".tmp")
            with tmp.open("w", encoding="utf-8", newline="\n") as f:
                for row in rows:
                    f.write(json.dumps(row, ensure_ascii=False) + "\n")
            tmp.replace(path)
    return added, replaced


def http_post_stays(handler, base: Path, data: bytes, log) -> None:
    try:
        stays = parse_stays(data)
    except ValueError as error:
        handler.send_json(400, {"error": str(error)})
        return
    try:
        added, replaced = write_stays(base, stays)
    except OSError as error:
        log(f"滞在を母艦に置けませんでした: {type(error).__name__}")
        handler.send_json(503, {"error": "母艦に置けませんでした"})
        return
    # 場所の名前・座標は書かない（数だけ）
    log(f"{handler.client_address[0]} から滞在を母艦へ: 新しく {added} 件・置き換え {replaced} 件（届いたのは {len(stays)} 件）")
    handler.send_json(200, {"ok": True, "added": added, "replaced": replaced})


POSTS = {"/pay/paypay-shot": http_post_shot, "/pay/paypay-rows": http_post_rows, "/location/stays": http_post_stays}
