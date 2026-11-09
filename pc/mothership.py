"""LifeLog PC（版 10 の足し）: 母艦（D:\\Lifelog）のやることを iPhone に渡し、iPhone で済みにしたものを母艦に返す（2026-11-09）。

やることが「アプリのタスク」「母艦の TODO」「Teams」の3か所に分かれていて、本人がどこを見ればよいか分からなかった。
アプリのタスクを見る場所に決め、母艦の TODO もそこに出す。母艦の TODO.md を書くのは母艦だけ（ここは読むのと、済みの知らせを置くだけ）。
- 母艦の場所は config.json の "lifelog_home"（無ければ D:\\Lifelog）。
- GET /todo → 母艦の state/todo_for_app.json（母艦が15分ごとと朝に作る）をそのまま返す。無ければ {"available": false}。
  中身（やることの文）は記録（log.txt）に書かない。
- POST /todo/done {"id": "<12文字の16進>", "text": "…"} → 母艦の inbox/app-todo-done/<日>.jsonl に1行足す
  （{"id", "text", "done_at"}）。母艦が15分ごとに TODO.md に「アプリで済み」として反映する。
  "kind" も受ける（2026-11-09。features の "todokind"）: "done"（済み・既定）・"wrong"（タスクではない）・
  "notyet"（母艦の「済みかも」に、まだと答えた）。done 以外は jsonl の行に "kind" を足す（done は前と同じ形）。
- GET /card → ドライブの「LifeLog/カード利用/card-mail.json」（Google の Apps Script が PayPay カードの利用速報メールから作る。
  2026-11-09。docs/card-payments.md）の支払いを返す。無ければ {"available": false}。中身は記録（log.txt）に書かない。
  場所は config.json の "card_mail_file"（無ければ、どのドライブ文字でも「マイドライブ/LifeLog/カード利用/card-mail.json」を探す）。
- どれも iPhone の合言葉（Bearer）が要る。時計の外の道（Funnel）からは届かない。
"""

from __future__ import annotations

import json
import re
import threading
import time
from pathlib import Path
from typing import Callable
from urllib.parse import urlparse

GETS = ("/todo", "/card")
POSTS = ("/todo/done",)
BODY_LIMIT = 16 * 1024
DEFAULT_HOME = Path(r"D:\Lifelog")
EXPORT = Path("state") / "todo_for_app.json"
DONE_DIR = Path("inbox") / "app-todo-done"
ID = re.compile(r"[0-9a-f]{12}")
KINDS = ("done", "wrong", "notyet")
CARD_FILE = Path("マイドライブ") / "LifeLog" / "カード利用" / "card-mail.json"
CARD_ID = re.compile(r"[0-9A-Za-z_-]{1,64}")
CARD_TIME = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?(Z|[+-]\d{2}:\d{2})")
CARD_LIMIT = 2000
_lock = threading.Lock()


def home(config: dict) -> Path:
    """母艦の場所（config.json の "lifelog_home"。無ければ D:\\Lifelog）"""
    value = str(config.get("lifelog_home") or "").strip()
    return Path(value) if value else DEFAULT_HOME


def card_file(config: dict) -> Path | None:
    """カードの利用速報の支払いのファイル（config.json の "card_mail_file"。無ければドライブ文字を順に探す）"""
    value = str(config.get("card_mail_file") or "").strip()
    if value:
        return Path(value)
    for letter in "GHIJKLMNOPQRSTUVWXYZDEF":
        path = Path(f"{letter}:\\") / CARD_FILE
        try:
            if path.is_file():
                return path
        except OSError:
            continue
    return None


def read_card(path: Path | None) -> dict:
    """card-mail.json を確かめて返す。おかしな行は落とす。無い・読めないときは {"available": false}"""
    if path is None:
        return {"available": False, "reason": "ドライブにカードの利用速報がまだありません"}
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
    except FileNotFoundError:
        return {"available": False, "reason": "ドライブにカードの利用速報がまだありません"}
    except (OSError, ValueError) as error:
        return {"available": False, "reason": f"カードの利用速報を読めませんでした: {type(error).__name__}"}
    if not isinstance(data, dict) or not isinstance(data.get("items"), list):
        return {"available": False, "reason": "カードの利用速報の形が違います"}
    items = []
    for item in data["items"][-CARD_LIMIT:]:
        if not isinstance(item, dict):
            continue
        item_id, when, amount = str(item.get("id") or ""), str(item.get("time") or ""), item.get("amount")
        if not CARD_ID.fullmatch(item_id) or not CARD_TIME.fullmatch(when):
            continue
        if not isinstance(amount, int) or isinstance(amount, bool) or not 0 < amount < 100_000_000:
            continue
        items.append({"id": item_id, "time": when, "amount": amount,
                      "shop": str(item.get("shop") or "").strip()[:100],
                      "card": str(item.get("card") or "").strip()[:40]})
    return {"available": True, "generated_at": str(data.get("generated_at") or ""), "items": items}


def read_export(base: Path) -> dict:
    """母艦の todo_for_app.json。無い・読めないときは {"available": false}"""
    path = base / EXPORT
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
    except FileNotFoundError:
        return {"available": False, "reason": "母艦のやることがまだありません"}
    except (OSError, ValueError) as error:
        return {"available": False, "reason": f"母艦のやることを読めませんでした: {type(error).__name__}"}
    if not isinstance(data, dict) or not isinstance(data.get("items"), list):
        return {"available": False, "reason": "母艦のやることの形が違います"}
    data["available"] = True
    return data


def parse_done(data: bytes) -> dict:
    """POST /todo/done の中身を確かめる。おかしければ ValueError"""
    try:
        body = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as error:
        raise ValueError("JSON ではありません") from error
    if not isinstance(body, dict):
        raise ValueError("JSON のオブジェクトではありません")
    item_id = str(body.get("id") or "").strip().lower()
    if not ID.fullmatch(item_id):
        raise ValueError("id は12文字の16進です")
    text = str(body.get("text") or "").strip()[:500]
    kind = str(body.get("kind") or "done").strip().lower()
    if kind not in KINDS:
        raise ValueError("kind は done・wrong・notyet のどれかです")
    return {"id": item_id, "text": text, "kind": kind}


def append_done(base: Path, item: dict, now: float | None = None) -> Path:
    """済みの知らせを inbox/app-todo-done/<日>.jsonl に1行足す（同じ日の同じ id は1回だけ）"""
    when = time.localtime(now if now is not None else time.time())
    folder = base / DONE_DIR
    path = folder / (time.strftime("%Y-%m-%d", when) + ".jsonl")
    kind = item.get("kind") or "done"
    line = {"id": item["id"], "text": item.get("text", ""),
            "done_at": time.strftime("%Y-%m-%dT%H:%M:%S", when) + _offset(when)}
    if kind != "done":
        line["kind"] = kind
    with _lock:
        folder.mkdir(parents=True, exist_ok=True)
        if path.exists():
            for old in path.read_text(encoding="utf-8").splitlines():
                try:
                    seen = json.loads(old)
                    if seen.get("id") == item["id"] and (seen.get("kind") or "done") == kind:
                        return path
                except ValueError:
                    continue
        with path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(line, ensure_ascii=False) + "\n")
    return path


def _offset(when: time.struct_time) -> str:
    seconds = when.tm_gmtoff if when.tm_gmtoff is not None else 0
    sign = "+" if seconds >= 0 else "-"
    seconds = abs(seconds)
    return f"{sign}{seconds // 3600:02d}:{seconds % 3600 // 60:02d}"


def http_get(handler, config: dict) -> None:
    if urlparse(handler.path).path == "/card":
        handler.send_json(200, read_card(card_file(config)))
        return
    handler.send_json(200, read_export(home(config)))


def http_post(handler, config: dict, data: bytes, log: Callable[[str], None]) -> None:
    try:
        item = parse_done(data)
    except ValueError as error:
        handler.send_json(400, {"error": str(error)})
        return
    try:
        append_done(home(config), item)
    except OSError as error:
        log(f"母艦のやることの済みを置けませんでした: {error!r}")
        handler.send_json(503, {"error": "母艦に置けませんでした"})
        return
    # やることの文は書かない（id だけ）
    words = {"done": "済みに", "wrong": "「タスクではない」に", "notyet": "「まだ」に"}
    log(f"{handler.client_address[0]} から母艦のやることを{words.get(item['kind'], '済みに')}: {item['id']}")
    handler.send_json(200, {"ok": True})
