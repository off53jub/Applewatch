"""LifeLog PC: s25（2026-11-24。担当 P）の LINE の Bot の受け口。取り決め K4（連7・連8・連9・大17。名前と形を変えない）。

POST /line/hook（外の道＝Tailscale Funnel の受け口 watchroute.py から呼ぶ。s20 の POST /line/webhook と同じ守り方）:
- 署名 X-Line-Signature をチャネルシークレット（HOME/line-secret.txt か環境変数 LIFELOG_LINE_CHANNEL_SECRET）で必ず確かめる。
  合わない・無いものは 401（本文は読まない）。シークレットが置かれていなければ 503。
- 受けるのは本人（linehook の userId の決まり）の文字のメッセージだけ。同じ webhookEventId は 2 回答えない。
- 答えは **返信（reply token）だけ**。push はしない（LINE の決まりで、返信は月の無料の通数に数えない。
  https://developers.line.biz/en/docs/messaging-api/pricing/ の「Sending methods that are not counted as message count」に
  Reply messages がある。2026-11-24 に確かめた）。
- 言葉（前後の空白・句読点は見ない）:
    「メモ …」「めも …」→ HOME/line-memo.jsonl に {"at": ISO, "text": str} を 1 行足して「入れました」
    「◯◯さん」→ 母艦 state/line_bot_feed.json の people[◯◯] の 1 行（無ければ「まだありません」）
    「まとめ」→ 同じファイルの summary
    「今日」「きのう」など → s20/s21 の日のまとめ（linehook.day_summary。今までどおり）
    「便り」かそのほか → 同じファイルの letters のうち、まだ返していないもの（新しい順に 5 件まで）。返したら印
    （HOME/s25p/line-letters.json。母艦のファイルは書かない）
- 返事の鍵は環境変数 LINE_CHANNEL_ACCESS_TOKEN（linehook.access_token。表示も記録もしない）。鍵が無ければ答えない。
記録（log.txt）には数だけ（文・名前・userId は書かない）。初めはオン（LINE の管理画面で Webhook の URL を入れるまでは何も来ない）。
2026-11-25（s26 結9・取り決め K3）: 返事の終わりに、押すとアプリのその所が開くリンクを 1 行足す（link_line）。
  「◯◯さん」→ lifelog://person/<名前を URL エンコード>・日のまとめ → lifelog://day/YYYY-MM-DD・
  便り → その便りに "link"（lifelog:// の形）があればそれ、無ければ lifelog://drafts は付けない（付けるのは link があるものだけ）。
  LINE が lifelog:// を押せる字にするかは確かめていない（仮。押せなければ、長押しで写して Safari に貼る）。
"""

from __future__ import annotations

import datetime
import json
import os
import re
import threading
import unicodedata
from pathlib import Path
from typing import Callable

import linehook

PATH = "/line/hook"
FEED = Path("state") / "line_bot_feed.json"
MEMO_FILE = "line-memo.jsonl"
LETTERS_FILE = Path("s25p") / "line-letters.json"
LETTERS_PER_REPLY = 5
REPLY_MAX = 4800                 # LINE の文字のメッセージは 5,000 字まで
MEMO_MAX = 1000
MEMO_WORDS = re.compile(r"^(メモ|めも|memo)[\s:：、,]*(.*)$", re.IGNORECASE | re.DOTALL)
PERSON = re.compile(r"^(.{1,20}?)(さん|くん|ちゃん|様|さま)$")
SUMMARY_WORDS = ("まとめ",)
LETTER_WORDS = ("便り", "たより")
_lock = threading.Lock()
LINK = re.compile(r"lifelog://(person/[^\s]{1,300}|day/\d{4}-\d{2}-\d{2}|talk/[^\s]{1,120}|task/[^\s]{1,120}|drafts|waiting)")


def person_link(name: str) -> str:
    """K3: lifelog://person/<名前を URL エンコード>"""
    import urllib.parse

    return "lifelog://person/" + urllib.parse.quote(name, safe="")


def day_link(day: str) -> str:
    return f"lifelog://day/{day}"


def with_link(text: str, link: str | None) -> str:
    """返事の終わりにリンクを 1 行（形が K3 に合わないものは足さない。5,000 字に収める）"""
    if not link or not LINK.fullmatch(link):
        return text[:REPLY_MAX]
    tail = "\n" + link
    return text[:REPLY_MAX - len(tail)] + tail


def _bare(text: str) -> str:
    return re.sub(r"[\s。、！？!?.]+$", "", unicodedata.normalize("NFKC", text or "").strip())


def read_feed(mother: Path | None) -> dict:
    if mother is None:
        return {}
    try:
        data = json.loads((Path(mother) / FEED).read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _letters_state(home: Path) -> dict:
    try:
        data = json.loads((Path(home) / LETTERS_FILE).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        data = {}
    sent = data.get("sent") if isinstance(data, dict) and isinstance(data.get("sent"), dict) else {}
    return {"sent": sent}


def _write(path: Path, body) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    part = path.with_name(path.name + ".part")
    part.write_text(json.dumps(body, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(part, path)


def letters_answer(home: Path, feed: dict, now: datetime.datetime | None = None) -> str:
    now = now or datetime.datetime.now().astimezone()
    letters = [x for x in feed.get("letters") or [] if isinstance(x, dict) and isinstance(x.get("id"), str)
               and isinstance(x.get("text"), str) and x["text"].strip()]
    with _lock:
        state = _letters_state(home)
        fresh = [x for x in letters if x["id"] not in state["sent"]]
        fresh.sort(key=lambda x: str(x.get("at") or ""), reverse=True)
        picked = fresh[:LETTERS_PER_REPLY]
        if not picked:
            return "溜まっている便りはありません"
        for x in picked:
            state["sent"][x["id"]] = now.isoformat(timespec="seconds")
        # 古い印は 60 日で落とす
        limit = (now - datetime.timedelta(days=60)).isoformat()
        state["sent"] = {k: v for k, v in state["sent"].items() if str(v) >= limit}
        _write(Path(home) / LETTERS_FILE, state)
    parts = []
    for x in picked:
        at = str(x.get("at") or "")[5:16].replace("T", " ")
        link = x.get("link") if isinstance(x.get("link"), str) and LINK.fullmatch(x["link"]) else None
        parts.append((f"［{at}］" if at else "") + x["text"].strip() + (f"\n{link}" if link else ""))
    rest = len(fresh) - len(picked)
    body = "\n\n".join(parts) + (f"\n\n（ほかに {rest} 件。もう一度送ると続きを返します）" if rest > 0 else "")
    return body[:REPLY_MAX]


def append_memo(home: Path, text: str, now: datetime.datetime | None = None) -> None:
    now = now or datetime.datetime.now().astimezone()
    path = Path(home) / MEMO_FILE
    path.parent.mkdir(parents=True, exist_ok=True)
    with _lock, open(path, "a", encoding="utf-8", newline="\n") as handle:
        handle.write(json.dumps({"at": now.isoformat(timespec="seconds"), "text": text[:MEMO_MAX]}, ensure_ascii=False) + "\n")


def answer(text: str, home: Path, mother: Path | None, today: datetime.date | None = None) -> tuple[str, str]:
    """(種類, 返す文)。種類は memo・person・summary・day・letters（記録には種類の数だけ書く）"""
    raw = (text or "").strip()
    memo = MEMO_WORDS.match(unicodedata.normalize("NFKC", raw))
    if memo:
        body = memo.group(2).strip()
        if not body:
            return "memo", "「メモ」のあとに入れたいことを書いてください"
        append_memo(home, body)
        return "memo", "入れました"
    bare = _bare(raw)
    feed = read_feed(mother)
    who = PERSON.match(bare)
    if who and bare not in LETTER_WORDS:
        name = who.group(1)
        people = feed.get("people") if isinstance(feed.get("people"), dict) else {}
        line = people.get(name) or people.get(bare)
        text = str(line) if isinstance(line, str) and line.strip() else f"{name}さんの 1 行はまだありません"
        return "person", with_link(text, person_link(name))
    if bare in SUMMARY_WORDS:
        summary = feed.get("summary")
        return "summary", (summary[:REPLY_MAX] if isinstance(summary, str) and summary.strip() else "まとめはまだありません")
    back = linehook.day_word(raw)
    if back is not None and mother is not None:
        day = ((today or datetime.date.today()) - datetime.timedelta(days=back)).isoformat()
        text = linehook.day_summary(mother, day) or f"{day} のまとめはまだありません（ふつうは次の朝にできます）"
        return "day", with_link(text, day_link(day))
    return "letters", letters_answer(home, feed)


def handle(body: bytes, signature: str | None, home: Path, config: dict, mother: Path | None,
           log: Callable[[str], None], sender: Callable[[str, str, str], bool] | None = None,
           today: datetime.date | None = None) -> tuple[int, dict]:
    """(HTTP の状態, 答え)。署名が合わなければ中身は見ない"""
    channel = linehook.secret(home)
    if not channel:
        return 503, {"error": "LINE のチャネルシークレットが置かれていません"}
    if len(body) > linehook.BODY_LIMIT:
        return 413, {"error": "too large"}
    if not linehook.verify(body, signature, channel):
        log("LINE の Bot: 署名が合わないものを捨てました")
        return 401, {"error": "bad signature"}
    try:
        data = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return 400, {"error": "bad json"}
    events = data.get("events") if isinstance(data, dict) else None
    if not isinstance(events, list):
        return 200, {"ok": True}
    send = sender or (lambda tok, rt, text: linehook.reply(tok, rt, text))
    kinds: dict[str, int] = {}
    ignored = replied = 0
    for event in events[:50]:
        message = event.get("message") if isinstance(event, dict) else None
        source = event.get("source") if isinstance(event, dict) else None
        if not (isinstance(event, dict) and event.get("type") == "message" and isinstance(message, dict)
                and message.get("type") == "text" and isinstance(message.get("text"), str)
                and isinstance(source, dict) and source.get("type") == "user" and isinstance(source.get("userId"), str)):
            ignored += 1
            continue
        if not linehook._owner(home, config, source["userId"]) or not linehook._fresh(event):
            ignored += 1
            continue
        try:
            kind, text = answer(message["text"][:linehook.TEXT_MAX], home, mother, today)
        except OSError as error:
            log(f"LINE の Bot: 書けませんでした（{type(error).__name__}）")
            continue
        kinds[kind] = kinds.get(kind, 0) + 1
        token, reply_token = linehook.access_token(home), event.get("replyToken")
        if token and isinstance(reply_token, str) and reply_token and send(token, reply_token, text):
            replied += 1
    if kinds or ignored:
        log("LINE の Bot: " + "・".join(f"{k} {v}" for k, v in sorted(kinds.items())) + f"・返事 {replied}・捨てた {ignored}")
        try:
            import quality

            quality.add_today({"s25p_line_bot": sum(kinds.values()), "s25p_line_bot_replied": replied}, Path(home))
        except Exception:  # noqa: BLE001
            pass
    return 200, {"ok": True}
