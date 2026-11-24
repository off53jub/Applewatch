"""LifeLog PC: s25（2026-11-24。担当 P）のアプリ向けの口。取り決め K1・K2・K3・K7（名前と形を変えない）。

- K1（連2・仕5）: GET /line-tasks ← 母艦の state/line_tasks_for_app.json（母艦 M1 が作る）。
  {"available": true, "version", "generated_at", "items": [{"id","text","who","due","day","work","evidence","expires"}]}
  期限（expires）の過ぎたものは返さない。職場の候補（work: true）は who と due が両方あるものだけ（仕5。抜いた数は "held_work"）。
- K2（大8）: GET /drafts ← 母艦の state/drafts_for_app.json（M1 が reply・calendar、M2 が settle・report を書く）。
  {"available": true, "version", "generated_at", "items": [{"id","kind","title","body","to","when","evidence","expires","source"}]}
  外へ送るのは本人の指（ここは読むだけ）。
- K3（連6）: POST /line/share {"name": str, "text": str}（今の端末の合言葉と同じ）→ HOME/line-share/<時刻>-<名前>.txt。
  text は 1 MB（UTF-8）まで。名前はファイル名に使えない字を除き 40 字まで。返事は {"ok": true, "saved": ファイル名, "bytes": n}。
  母艦 M1 の Process-LineInbox.py がこのフォルダを読む（読むだけ）。ここでは消さない。
- K7（大10・初めはオフ）: GET /whisper-now。config.json の "whisper_now": true のときだけ、今日の記録の直近 10 分の会話に
  名前の付いた相手がいれば {"person": 名前, "last_talk": str|null, "promises": [str]}、無ければ {}（オフのときも {}）。
  last_talk は前の日までで、その人と最後に話した会話の「MM-DD 見出し」。promises はその人との約束の台帳（promises.py）の新しい 3 件。
どれも中身（文・名前）は記録（log.txt）に書かない（数だけ）。0 円・言語モデルは呼ばない。
"""

from __future__ import annotations

import datetime
import json
import os
import re
import time
from pathlib import Path

import appfeeds

LINE_TASKS = Path("state") / "line_tasks_for_app.json"
DRAFTS = Path("state") / "drafts_for_app.json"
SHARE_DIR = "line-share"
SHARE_TEXT_MAX = 1024 * 1024            # K3: 1 MB まで
SHARE_BODY_MAX = SHARE_TEXT_MAX * 2 + 4096   # JSON の \uXXXX の分の余裕
NAME_MAX = 40
TASK_ITEMS = 60
DRAFT_ITEMS = 40
DRAFT_KINDS = ("reply", "calendar", "settle", "report", "other")
WHISPER_WINDOW = 600                    # K7: 直近 10 分
WHISPER_PROMISES = 3
UNNAMED = re.compile(r"人物\d+")
SELF_NAME = "自分"
BAD_NAME = re.compile(r'[\\/:*?"<>|\x00-\x1f\x7f]')


def _id(value) -> str | None:
    """id は空でない 80 字までの文（改行などの制御文字は無し）"""
    if not isinstance(value, str) or not value or len(value) > 80 or re.search(r"[\x00-\x1f\x7f]", value):
        return None
    return value


def _opt_text(value, n: int) -> str | None:
    if value is None:
        return None
    text = appfeeds._text(value, n) if isinstance(value, str) else ""
    return text or None


def _expired(expires: str | None, today: datetime.date) -> bool:
    return expires is not None and expires < today.isoformat()


# MARK: - K1 GET /line-tasks


def read_line_tasks(base: Path, today: datetime.date | None = None) -> dict:
    today = today or datetime.date.today()
    data, failure = appfeeds._load(Path(base), LINE_TASKS, "LINE のタスク候補")
    if failure or data is None or not isinstance(data.get("items"), list):
        return failure or {"available": False, "reason": "母艦の LINE のタスク候補の形が違います"}
    items, seen, held = [], set(), 0
    for x in data["items"][:TASK_ITEMS * 4]:
        if not isinstance(x, dict):
            continue
        ident, text, day = _id(x.get("id")), appfeeds._text(x.get("text"), 200), appfeeds._day(x.get("day"))
        due = x.get("due")
        expires = appfeeds._day(x.get("expires"))
        if ident is None or ident in seen or not text or day is None or expires is None \
                or (due is not None and appfeeds._day(due) is None) or not isinstance(x.get("work"), bool):
            continue
        if _expired(expires, today):
            continue
        who = _opt_text(x.get("who"), 40)
        if x["work"] and (who is None or due is None):   # 仕5: 職場は「だれから・いつまで」の両方があるものだけ
            held += 1
            continue
        seen.add(ident)
        items.append({"id": ident, "text": text, "who": who, "due": due, "day": day, "work": x["work"],
                      "evidence": appfeeds._text(x.get("evidence"), 60), "expires": expires})
        if len(items) >= TASK_ITEMS:
            break
    out = {"available": True, "version": appfeeds._version(data), "generated_at": appfeeds._iso(data.get("generated_at")),
           "items": items}
    if held:
        out["held_work"] = held
    return out


# MARK: - K2 GET /drafts


def read_drafts(base: Path, today: datetime.date | None = None) -> dict:
    today = today or datetime.date.today()
    data, failure = appfeeds._load(Path(base), DRAFTS, "下書き")
    if failure or data is None or not isinstance(data.get("items"), list):
        return failure or {"available": False, "reason": "母艦の下書きの形が違います"}
    items, seen = [], set()
    for x in data["items"][:DRAFT_ITEMS * 4]:
        if not isinstance(x, dict):
            continue
        ident, kind = _id(x.get("id")), x.get("kind")
        title, body = appfeeds._text(x.get("title"), 80), appfeeds._long(x.get("body"), 4000)
        expires, source = appfeeds._day(x.get("expires")), appfeeds._text(x.get("source"), 40)
        when = x.get("when")
        if ident is None or ident in seen or kind not in DRAFT_KINDS or not title or not body or expires is None \
                or not source or (when is not None and appfeeds._when(when) is None):
            continue
        if _expired(expires, today):
            continue
        seen.add(ident)
        items.append({"id": ident, "kind": kind, "title": title, "body": body, "to": _opt_text(x.get("to"), 80),
                      "when": appfeeds._when(when) if when is not None else None,
                      "evidence": _opt_text(x.get("evidence"), 200), "expires": expires, "source": source})
        if len(items) >= DRAFT_ITEMS:
            break
    return {"available": True, "version": appfeeds._version(data), "generated_at": appfeeds._iso(data.get("generated_at")),
            "items": items}


# MARK: - K3 POST /line/share


def safe_name(name) -> str:
    text = BAD_NAME.sub("", str(name or "")).strip().strip(".")
    text = re.sub(r"\s+", "_", text)[:NAME_MAX]
    return text or "line"


def parse_share(data: bytes) -> dict:
    try:
        body = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as error:
        raise ValueError("JSON ではありません") from error
    if not isinstance(body, dict) or not isinstance(body.get("name"), str) or not isinstance(body.get("text"), str):
        raise ValueError("name と text は文字です")
    text = body["text"]
    if not text.strip():
        raise ValueError("text が空です")
    if len(text.encode("utf-8")) > SHARE_TEXT_MAX:
        raise ValueError("text は 1 MB までです")
    return {"name": body["name"], "text": text}


def save_share(home: Path, request: dict, now: float | None = None) -> Path:
    now = time.time() if now is None else now
    folder = Path(home) / SHARE_DIR
    folder.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S", time.localtime(now))
    name = safe_name(request["name"])
    path = folder / f"{stamp}-{name}.txt"
    count = 2
    while path.exists():
        path = folder / f"{stamp}-{name}-{count}.txt"
        count += 1
    part = path.with_name(path.name + ".part")
    part.write_text(request["text"], encoding="utf-8", newline="")
    os.replace(part, path)
    return path


def http_post_share(handler, home: Path, log) -> None:
    try:
        length = int(handler.headers.get("Content-Length") or 0)
    except ValueError:
        length = 0
    if length <= 0 or length > SHARE_BODY_MAX:
        handler.discard_body()
        handler.send_json(400 if length <= 0 else 413, {"ok": False, "error": "中身がありません" if length <= 0 else "長すぎます（1 MB まで）"})
        return
    try:
        request = parse_share(handler.rfile.read(length))
        path = save_share(home, request)
    except ValueError as error:
        handler.send_json(400, {"ok": False, "error": str(error)})
        return
    except OSError as error:
        log(f"LINE の共有を置けませんでした: {type(error).__name__}")
        handler.send_json(503, {"ok": False, "error": "置けませんでした"})
        return
    size = path.stat().st_size
    log(f"LINE の共有を受けました（{size} バイト）")   # 名前と中身は書かない
    handler.send_json(200, {"ok": True, "saved": path.name, "bytes": size})


# MARK: - K7 GET /whisper-now


def _epoch(value) -> float | None:
    """ISO 8601 の文か、記録の読み込み（records.parse_record）のミリ秒 → 1970 年からの秒"""
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return float(value) / 1000.0 if value > 1e11 else float(value)
    try:
        return datetime.datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
    except (TypeError, ValueError):
        return None


def _named(name) -> bool:
    return isinstance(name, str) and bool(name) and name != SELF_NAME and not UNNAMED.fullmatch(name)


def recent_person(parsed: dict | None, now: float, window: float = WHISPER_WINDOW) -> str | None:
    """直近 window 秒の行で、いちばん多く話した名前の付いた相手（テレビなどの声・自分・人物N は数えない）"""
    counts: dict[str, int] = {}
    last: dict[str, float] = {}
    for conversation in (parsed or {}).get("conversations") or []:
        if not isinstance(conversation, dict) or conversation.get("media"):
            continue
        for line in conversation.get("lines") or []:
            if not isinstance(line, dict) or line.get("media") is not None:
                continue
            t = _epoch(line.get("time"))
            name = line.get("speaker")
            if t is None or not (now - window <= t <= now + 60) or not _named(name):
                continue
            counts[name] = counts.get(name, 0) + 1
            last[name] = max(last.get(name, 0.0), t)
    if not counts:
        return None
    return sorted(counts, key=lambda k: (-counts[k], -last[k]))[0]


def last_talk(store, person: str, today: datetime.date, back: int = 60) -> str | None:
    """前の日まででその人と最後に話した会話の「MM-DD 見出し」（見出しが無ければ「MM-DD」）"""
    if store is None:
        return None
    for i in range(1, back + 1):
        day = (today - datetime.timedelta(days=i)).isoformat()
        try:
            parsed = store.day(day)
        except Exception:  # noqa: BLE001
            parsed = None
        for conversation in reversed((parsed or {}).get("conversations") or []):
            if not isinstance(conversation, dict) or conversation.get("media"):
                continue
            names = {line.get("speaker") for line in conversation.get("lines") or [] if isinstance(line, dict)}
            if person in names:
                title = appfeeds._text(conversation.get("title"), 60)
                return f"{day[5:]} {title}".strip()
    return None


def person_promises(person: str) -> list[str]:
    try:
        import promises

        if promises.W is None:
            return []
        items = promises.W.now_items().get("items") or []
    except Exception:  # noqa: BLE001
        return []
    out = []
    for item in items:
        if isinstance(item, dict) and item.get("who") == person and item.get("what"):
            out.append(appfeeds._text(item["what"], 80))
        if len(out) >= WHISPER_PROMISES:
            break
    return out


def whisper_now(store, config: dict, now: float | None = None) -> dict:
    if (config or {}).get("whisper_now") is not True or store is None:
        return {}
    now = time.time() if now is None else now
    today = datetime.date.fromtimestamp(now)
    person = None
    for day in (today, today - datetime.timedelta(days=1)):   # 0 時をまたぐ会話
        try:
            person = recent_person(store.day(day.isoformat()), now)
        except Exception:  # noqa: BLE001
            person = None
        if person:
            break
    if not person:
        return {}
    return {"person": person, "last_talk": last_talk(store, person, today), "promises": person_promises(person)}
