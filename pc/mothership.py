"""LifeLog PC（版 10 の足し）: 母艦（D:\\Lifelog）のやることを iPhone に渡し、iPhone で済みにしたものを母艦に返す（2026-11-09）。

やることが「アプリのタスク」「母艦の TODO」「Teams」の3か所に分かれていて、本人がどこを見ればよいか分からなかった。
アプリのタスクを見る場所に決め、母艦の TODO もそこに出す。母艦の TODO.md を書くのは母艦だけ（ここは読むのと、済みの知らせを置くだけ）。
- 母艦の場所は config.json の "lifelog_home"（無ければ D:\\Lifelog）。
- GET /todo → 母艦の state/todo_for_app.json（母艦が15分ごとと朝に作る）をそのまま返す。無ければ {"available": false}。
  中身（やることの文）は記録（log.txt）に書かない。
- POST /todo/done {"id": "<12文字の16進>", "text": "…"} → 母艦の inbox/app-todo-done/<日>.jsonl に1行足す
  （{"id", "text", "done_at"}）。母艦が15分ごとに TODO.md に「アプリで済み」として反映する。
- どちらも iPhone の合言葉（Bearer）が要る。時計の外の道（Funnel）からは届かない。
"""

from __future__ import annotations

import json
import re
import threading
import time
from pathlib import Path
from typing import Callable

GETS = ("/todo",)
POSTS = ("/todo/done",)
BODY_LIMIT = 16 * 1024
DEFAULT_HOME = Path(r"D:\Lifelog")
EXPORT = Path("state") / "todo_for_app.json"
DONE_DIR = Path("inbox") / "app-todo-done"
ID = re.compile(r"[0-9a-f]{12}")
_lock = threading.Lock()


def home(config: dict) -> Path:
    """母艦の場所（config.json の "lifelog_home"。無ければ D:\\Lifelog）"""
    value = str(config.get("lifelog_home") or "").strip()
    return Path(value) if value else DEFAULT_HOME


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
    return {"id": item_id, "text": text}


def append_done(base: Path, item: dict, now: float | None = None) -> Path:
    """済みの知らせを inbox/app-todo-done/<日>.jsonl に1行足す（同じ日の同じ id は1回だけ）"""
    when = time.localtime(now if now is not None else time.time())
    folder = base / DONE_DIR
    path = folder / (time.strftime("%Y-%m-%d", when) + ".jsonl")
    line = {"id": item["id"], "text": item.get("text", ""),
            "done_at": time.strftime("%Y-%m-%dT%H:%M:%S", when) + _offset(when)}
    with _lock:
        folder.mkdir(parents=True, exist_ok=True)
        if path.exists():
            for old in path.read_text(encoding="utf-8").splitlines():
                try:
                    if json.loads(old).get("id") == item["id"]:
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
    log(f"{handler.client_address[0]} から母艦のやることを済みに: {item['id']}")
    handler.send_json(200, {"ok": True})
