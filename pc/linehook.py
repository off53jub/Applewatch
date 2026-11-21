"""LifeLog PC: LINE の Messaging API の webhook の受け口（s20 の追10。2026-11-21）。LINE で自分のボットに送った文字を、母艦の記録に入れる。

POST /line/webhook（外の道＝Tailscale Funnel の URL に載る。watchroute.py の受け口から呼ぶ。ふだんの合言葉は要らない代わりに署名で守る）
- 署名: X-Line-Signature（本文を、チャネルシークレットで HMAC-SHA256 → base64）を必ず確かめる。合わない・無いものは捨てる（401。本文は読まない）。
- 受けるのは、本人（送り主の userId）の「文字のメッセージ」だけ。ほかの人・スタンプ・画像・グループは捨てる（返事もしない）。
  本人の userId は config.json の "line_webhook": {"user_id": "U…"} で 1 人だけ許す。無ければ、最初に届いた 1 通の送り主を
  HOME/line-owner.txt に覚える（"line_webhook": {"learn_first": false} で止められる。使う前に user_id を置けば、最初の人に決まらない）。
- 本人の文字は、母艦の inbox/line_notes.jsonl に {"at": 受けた時刻（ISO 8601）, "text": 文字} を 1 行足す（母艦がこれを読む部分は別の担当）。
  足せたときだけ、reply token で「記録しました」と返す（push は使わない＝送る数の枠を使わない）。足せなければ返事をしない。
- 同じ webhookEventId（LINE の再送）は 2 回足さない（覚えているのは直近 EVENTS_KEEP 件）。
- チャネルシークレットの置き場所（どれも中身を表示・記録・コミットしない。母艦の Send-LineMessage.ps1 が使うのは送る側の
  アクセストークンだけで、シークレットはどこにも置いていなかったので、ここに口だけ作る）:
    環境変数 LIFELOG_LINE_CHANNEL_SECRET か、HOME/line-secret.txt（1 行）。無ければ、webhook は 503（始めない）。
  返事に使うアクセストークンは母艦と同じ LINE_CHANNEL_ACCESS_TOKEN（環境変数・Windows のユーザー環境変数）か HOME/line-token.txt。
  無ければ記録だけして返事はしない。
記録（log.txt）には数だけ（文字・userId は書かない）。
"""

from __future__ import annotations

import base64
import collections
import datetime
import hashlib
import hmac
import json
import os
import re
import threading
import urllib.request
from pathlib import Path
from typing import Callable

PATH = "/line/webhook"
BODY_LIMIT = 64 * 1024
TEXT_MAX = 2000
SECRET_FILE = "line-secret.txt"
TOKEN_FILE = "line-token.txt"
OWNER_FILE = "line-owner.txt"
NOTES = Path("inbox") / "line_notes.jsonl"
REPLY_URL = "https://api.line.me/v2/bot/message/reply"
REPLY_TEXT = "記録しました"
EVENTS_KEEP = 500
USER_ID = re.compile(r"U[0-9a-f]{32}")

_lock = threading.Lock()
_seen: "collections.OrderedDict[str, bool]" = collections.OrderedDict()


def _first_line(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8").strip().splitlines()[0].strip()
    except (OSError, IndexError):
        return ""


def secret(home: Path) -> str:
    return os.environ.get("LIFELOG_LINE_CHANNEL_SECRET", "").strip() or _first_line(Path(home) / SECRET_FILE)


def access_token(home: Path) -> str:
    value = os.environ.get("LINE_CHANNEL_ACCESS_TOKEN", "").strip() or _first_line(Path(home) / TOKEN_FILE)
    if value:
        return value
    try:  # 母艦の Send-LineMessage.ps1 と同じ、Windows のユーザー環境変数
        import winreg

        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as key:
            return str(winreg.QueryValueEx(key, "LINE_CHANNEL_ACCESS_TOKEN")[0]).strip()
    except (ImportError, OSError):
        return ""


def sign(body: bytes, channel_secret: str) -> str:
    return base64.b64encode(hmac.new(channel_secret.encode("utf-8"), body, hashlib.sha256).digest()).decode("ascii")


def verify(body: bytes, signature: str | None, channel_secret: str) -> bool:
    if not channel_secret or not signature:
        return False
    return hmac.compare_digest(sign(body, channel_secret).encode("ascii"), signature.strip().encode("utf-8", "replace"))


def _owner(home: Path, config: dict, user_id: str) -> bool:
    """本人の userId か。決まっていなければ、最初の 1 通の送り主を覚える（learn_first が false でなければ）"""
    mine = (config or {}).get("line_webhook")
    mine = mine if isinstance(mine, dict) else {}
    fixed = mine.get("user_id") if isinstance(mine.get("user_id"), str) else ""
    if fixed:
        return hmac.compare_digest(fixed.encode(), user_id.encode())
    learned = _first_line(Path(home) / OWNER_FILE)
    if learned:
        return hmac.compare_digest(learned.encode(), user_id.encode())
    if mine.get("learn_first") is False or not USER_ID.fullmatch(user_id):
        return False
    path = Path(home) / OWNER_FILE
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(user_id + "\n", encoding="utf-8")
    return True


def _fresh(event: dict) -> bool:
    """LINE の再送を 2 回足さない"""
    ident = event.get("webhookEventId")
    if not isinstance(ident, str) or not ident:
        return True
    with _lock:
        if ident in _seen:
            return False
        _seen[ident] = True
        while len(_seen) > EVENTS_KEEP:
            _seen.popitem(last=False)
    return True


def reply(token: str, reply_token: str, text: str = REPLY_TEXT, timeout: float = 5.0) -> bool:
    """reply token で返事を 1 言（push は使わない）。使い方は LINE の reply API"""
    data = json.dumps({"replyToken": reply_token, "messages": [{"type": "text", "text": text}]},
                      ensure_ascii=False).encode("utf-8")
    request = urllib.request.Request(REPLY_URL, data=data, method="POST", headers={
        "Content-Type": "application/json", "Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return 200 <= response.status < 300
    except Exception:  # noqa: BLE001 — 返事ができなくても、記録は残っている
        return False


def append_note(mother: Path, text: str, now: datetime.datetime | None = None) -> None:
    now = now or datetime.datetime.now().astimezone()
    path = Path(mother) / NOTES
    path.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps({"at": now.isoformat(timespec="seconds"), "text": text}, ensure_ascii=False)
    with open(path, "a", encoding="utf-8", newline="\n") as handle:
        handle.write(line + "\n")


def handle(body: bytes, signature: str | None, home: Path, config: dict, mother: Path | None,
           log: Callable[[str], None], sender: Callable[[str, str], bool] | None = None) -> tuple[int, dict]:
    """(HTTP の状態, 答え)。署名が合わなければ中身は見ない"""
    if not secret(home):
        return 503, {"error": "LINE のチャネルシークレットが置かれていません"}
    if len(body) > BODY_LIMIT:
        return 413, {"error": "too large"}
    if not verify(body, signature, secret(home)):
        log("LINE の webhook: 署名が合わないものを捨てました")
        return 401, {"error": "bad signature"}
    try:
        data = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return 400, {"error": "bad json"}
    events = data.get("events") if isinstance(data, dict) else None
    if not isinstance(events, list):
        return 200, {"ok": True}
    noted = ignored = replied = 0
    send = sender or (lambda tok, rt: reply(tok, rt))
    for event in events[:50]:
        message = event.get("message") if isinstance(event, dict) else None
        source = event.get("source") if isinstance(event, dict) else None
        if not (isinstance(event, dict) and event.get("type") == "message" and isinstance(message, dict)
                and message.get("type") == "text" and isinstance(message.get("text"), str)
                and isinstance(source, dict) and source.get("type") == "user" and isinstance(source.get("userId"), str)):
            ignored += 1
            continue
        if not _owner(home, config, source["userId"]):
            ignored += 1
            continue
        if not _fresh(event):
            continue
        text = message["text"].strip()[:TEXT_MAX]
        if not text or mother is None or not Path(mother).is_dir():
            ignored += 1
            continue
        try:
            append_note(mother, text)
        except OSError as error:
            log(f"LINE の webhook: 母艦に書けませんでした（{type(error).__name__}）")
            continue
        noted += 1
        token, reply_token = access_token(home), event.get("replyToken")
        if token and isinstance(reply_token, str) and reply_token and send(token, reply_token):
            replied += 1
    if noted or ignored:
        log(f"LINE の webhook: 記録 {noted}・返事 {replied}・捨てた {ignored}")
    return 200, {"ok": True}
