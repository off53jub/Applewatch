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
- GET /vocab → 母艦の state/vocab_for_app.json（母艦の辞書から作った「登録の候補」。2026-11-10）を確かめて返す。
  無ければ {"available": false}。iPhone は候補として見せるだけで、本人が押した言葉だけを登録する。中身は記録（log.txt）に書かない。
- どれも iPhone の合言葉（Bearer）が要る。時計の外の道（Funnel）からは届かない。
- 仕事のまとめ（2026-11-10）: iPhone がドライブの「LifeLog/同期/仕事のまとめ.json」に書く、仕事のまとめを読むだけ
  （read_digests。書かない。書くとアプリの同期が壊れる）。意味で探す（semantic.py）と MCP サーバー（lifelog_mcp.py）が使う。
  場所は config.json の "work_digest_file"（無ければ、どのドライブ文字でも「マイドライブ/LifeLog/同期/仕事のまとめ.json」を探す）。
- GET /good → 母艦の state/good_for_app.json（いいこと帳。記録にあったお礼・ほめ言葉・済ませた頼まれごと・
  ウケたかもの場面。2026-11-12）を確かめて返す。無ければ {"available": false}。中身は記録（log.txt）に書かない。
- POST /pay/taps {"items": [...]}（2026-11-11。features の "pay"）→ ウォレットでかざした記録の全部を
  母艦の inbox/card-taps/card-taps.json に置き換えで書く（iPhone の card-taps.jsonl が正。PC 側は写し）。
- POST /pay/paypay（PayPay の明細 CSV そのまま。2026-11-11）→ 母艦の inbox/paypay/app-<中身の16進8文字>.csv。
  同じ中身のファイルがすでにあれば書かない。どちらも中身は記録（log.txt）に書かない（件数だけ）。
- POST /good/feedback {"items": [...]}（2026-11-12。features の "goodfb"）→ いいこと帳で本人が付けた
  「違う」「当たり」「外れ」の全部を、母艦の inbox/good-feedback/feedback.json に置き換えで書く（iPhone の good-feedback.json が正）。
  1件は {"id","day","time","kind":"word"|"laugh","verdict":"wrong"|"right"}。2000 件まで。中身は記録に書かない（件数だけ）。
- 2026-11-14（強化案 25・28・30・34。中身は oneline.py）: GET /timeline?day=・GET /reflection・POST /pay/paypay-shot・
  POST /pay/paypay-rows・POST /location/stays。
- 2026-11-15（強化案 36・37・41。中身は settle.py）: GET /rollout・GET /checks・GET /costs。
"""

from __future__ import annotations

import hashlib
import json
import re
import unicodedata
import threading
import time
from pathlib import Path
from typing import Callable
from urllib.parse import urlparse

import appfeeds  # 自分の声の候補・新しさ・PLAUD との差（2026-11-12）
import oneline  # 1日の年表・PayPay の写真・位置を当日のうちに・反映の見張り（2026-11-14。強化案 25・28・30・34）
import settle  # 施策の検品表・正しさの抜き取り・Claude の費用（2026-11-15。強化案 36・37・41）
import canonical  # 1日の正本（2026-11-15。強化案 57）

GETS = ("/todo", "/card", "/vocab", "/good", *appfeeds.READERS, *oneline.GETS, *settle.READERS, *canonical.GETS)
# POST /proposals/answer（母艦からの提案への答え。2026-11-13。中身は appfeeds.py）
POSTS = ("/todo/done", "/pay/taps", "/pay/paypay", "/good/feedback", *appfeeds.POSTS, *oneline.POSTS)
BODY_LIMIT = 16 * 1024
# 支払いの記録を母艦へ（2026-11-11）
TAPS_FILE = Path("inbox") / "card-taps" / "card-taps.json"
PAYPAY_DIR = Path("inbox") / "paypay"
# いいこと帳への本人の「当たり」「違う」（2026-11-12。features の "goodfb"）。2000 件で 1MB に収まる
GOOD_FEEDBACK_FILE = Path("inbox") / "good-feedback" / "feedback.json"
GOOD_FEEDBACK_MAX = 2000
PAY_LIMITS = {"/pay/taps": 1024 * 1024, "/pay/paypay": 8 * 1024 * 1024, "/good/feedback": 1024 * 1024}
DEFAULT_HOME = Path(r"D:\Lifelog")
EXPORT = Path("state") / "todo_for_app.json"
DONE_DIR = Path("inbox") / "app-todo-done"
ID = re.compile(r"[0-9a-f]{12}")
KINDS = ("done", "wrong", "notyet")
CARD_FILE = Path("マイドライブ") / "LifeLog" / "カード利用" / "card-mail.json"
CARD_ID = re.compile(r"[0-9A-Za-z_-]{1,64}")
CARD_TIME = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?(Z|[+-]\d{2}:\d{2})")
CARD_LIMIT = 2000
DIGEST_FILE = Path("マイドライブ") / "LifeLog" / "同期" / "仕事のまとめ.json"
DIGEST_MAX_BYTES = 20_000_000
DIGEST_TEXT_MAX = 4000
# 仕事のまとめの項目（アプリの WorkDigest.Sections の並び順と見出し）
DIGEST_HEADINGS = (("sources", "出どころ"), ("decided", "決まったこと"), ("homework", "自分の宿題"),
                   ("others", "ほかの人の動き"), ("topics", "気になる話題"), ("checks", "あとで確かめること"),
                   ("words", "よく出た言葉"))
DIGEST_DAY = re.compile(r"\d{4}-\d{2}-\d{2}")
DIGEST_HEADER_LINE = re.compile(r"\s*【[^】]*】\s*")
VOCAB = Path("state") / "vocab_for_app.json"
VOCAB_LIMIT = 300
# いいこと帳（2026-11-12。母艦の scripts/Build-GoodThings.py が作る）
GOOD = Path("state") / "good_for_app.json"
GOOD_DAYS = 31
GOOD_ITEMS = 200
GOOD_MONTH_KEYS = ("thanks", "praise", "done", "consulted", "own")
GOOD_FIRST_KINDS = ("初めて話した人", "初めての場所")
GOOD_TONIGHT_KINDS = ("お礼", "ほめ言葉", "済ませた", "頼られた")
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


def digest_file(config: dict) -> Path | None:
    """仕事のまとめのファイル（config.json の "work_digest_file"。無ければドライブ文字を順に探す）"""
    value = str(config.get("work_digest_file") or "").strip()
    if value:
        return Path(value)
    for letter in "GHIJKLMNOPQRSTUVWXYZDEF":
        path = Path(f"{letter}:\\") / DIGEST_FILE
        try:
            if path.is_file():
                return path
        except OSError:
            continue
    return None


def digest_key(text: str) -> str:
    """同じ行かの比べ方（空白を除く）"""
    return re.sub(r"\s+", "", unicodedata.normalize("NFC", text))


def digest_id(day: str, text: str) -> str:
    """意味で探すの行の id（日と文で決まる。見出しが変わっても同じ）"""
    return "digest|" + day + "|" + hashlib.sha1(digest_key(text).encode("utf-8")).hexdigest()[:16]


def digest_lines(entries) -> list[dict]:
    """[WorkDigest.Entry] を {day, heading, text} の行に開く。まとめが無い・空のときは取り込んだ文を行に分ける
    （見出しは空。【日付】だけの行は飛ばす）。同じ日の同じ文（空白を除いて）は1回だけ。日の新しい順、日の中は取り込んだ順。"""
    if not isinstance(entries, list):
        return []
    found: list[dict] = []
    seen: set[tuple[str, str]] = set()
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        day = entry.get("day")
        if not isinstance(day, str) or not DIGEST_DAY.fullmatch(day):
            continue
        pairs: list[tuple[str, str]] = []
        sections = entry.get("sections")
        if isinstance(sections, dict):
            for key, heading in DIGEST_HEADINGS:
                values = sections.get(key)
                if isinstance(values, list):
                    pairs += [(heading, v) for v in values if isinstance(v, str)]
        if not any(text.strip() for _, text in pairs):
            raw = entry.get("text")
            pairs = [("", line) for line in (raw.splitlines() if isinstance(raw, str) else [])
                     if not DIGEST_HEADER_LINE.fullmatch(line)]
        for heading, text in pairs:
            text = text.strip()[:DIGEST_TEXT_MAX]
            key = digest_key(text)
            if not key or (day, key) in seen:
                continue
            seen.add((day, key))
            found.append({"day": day, "heading": heading, "text": text})
    # 日は新しい順。同じ日の中は取り込んだ順のまま（並べ直しは安定）
    order = {d: i for i, d in enumerate(sorted({line["day"] for line in found}, reverse=True))}
    found.sort(key=lambda line: order[line["day"]])
    return found


def read_digests(path: Path | None) -> dict | None:
    """仕事のまとめを読む（読むだけ）。{"stamp": (更新のナノ秒, 大きさ), "lines": [{day, heading, text}…]}。
    ファイルが無い・読めない・形が違うときは None（静かに「まとめ無し」）。"""
    if path is None:
        return None
    try:
        stat = path.stat()
        if stat.st_size > DIGEST_MAX_BYTES:
            return None
        data = json.loads(path.read_bytes().decode("utf-8-sig"))
    except (OSError, ValueError):
        return None
    if not isinstance(data, list):
        return None
    return {"stamp": (stat.st_mtime_ns, stat.st_size), "lines": digest_lines(data)}


def read_vocab(base: Path) -> dict:
    """母艦の vocab_for_app.json（登録の候補）を確かめて返す。おかしな行は落とす。無い・読めないときは {"available": false}"""
    path = base / VOCAB
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
    except FileNotFoundError:
        return {"available": False, "reason": "母艦の言葉の候補がまだありません"}
    except (OSError, ValueError) as error:
        return {"available": False, "reason": f"母艦の言葉の候補を読めませんでした: {type(error).__name__}"}
    if not isinstance(data, dict) or not isinstance(data.get("items"), list):
        return {"available": False, "reason": "母艦の言葉の候補の形が違います"}
    items = []
    for item in data["items"]:
        if not isinstance(item, dict) or not isinstance(item.get("word"), str):
            continue
        word = item["word"].strip()
        if not 0 < len(word) <= 40 or "<" in word or ">" in word or "\n" in word:
            continue
        count = item.get("count")
        variants = item.get("variants") if isinstance(item.get("variants"), list) else []
        items.append({"word": word,
                      "category": str(item.get("category") or "").strip()[:20],
                      "count": count if isinstance(count, int) and not isinstance(count, bool) and count >= 0 else 0,
                      "last": str(item.get("last") or "").strip()[:10],
                      "variants": [v.strip()[:40] for v in variants if isinstance(v, str) and v.strip()][:6],
                      # 施策 14（2026-11-13）: 母艦の「まとめて OK」の印（省ける。true のときだけ付ける）
                      **appfeeds.sure(item)})
        if len(items) >= VOCAB_LIMIT:
            break
    return {"available": True, "generated_at": str(data.get("generated_at") or ""), "items": items}


def _text(value, n: int) -> str:
    return " ".join(str(value or "").split())[:n] if isinstance(value, (str, int)) and not isinstance(value, bool) else ""


def _count(value) -> int | None:
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else None


def read_good(base: Path) -> dict:
    """母艦の good_for_app.json（いいこと帳）を確かめて返す。おかしな行は落とす。無い・読めないときは {"available": false}"""
    try:
        data = json.loads((base / GOOD).read_text(encoding="utf-8-sig"))
    except FileNotFoundError:
        return {"available": False, "reason": "母艦のいいこと帳がまだありません"}
    except (OSError, ValueError) as error:
        return {"available": False, "reason": f"母艦のいいこと帳を読めませんでした: {type(error).__name__}"}
    if not isinstance(data, dict) or not isinstance(data.get("weeks"), list) or not isinstance(data.get("days"), list):
        return {"available": False, "reason": "母艦のいいこと帳の形が違います"}
    clock = re.compile(r"\d{2}:\d{2}")
    weeks = []
    for w in data["weeks"][:8]:
        if not isinstance(w, dict) or not DIGEST_DAY.fullmatch(str(w.get("start") or "")):
            continue
        weeks.append({"start": w["start"], **{k: _count(w.get(k)) or 0 for k in ("thanks", "praise", "done", "own")},
                      "laughs": _count(w.get("laughs")), "consulted": _count(w.get("consulted"))})
    days = []
    for d in data["days"][:GOOD_DAYS]:
        if not isinstance(d, dict) or not DIGEST_DAY.fullmatch(str(d.get("day") or "")):
            continue
        words = [{"time": x["time"], "kind": "お礼" if x.get("kind") == "お礼" else "ほめ言葉",
                  "who": _text(x.get("who"), 40), "text": _text(x.get("text"), 120), "place": _text(x.get("place"), 40)}
                 for x in d.get("words") or [] if isinstance(x, dict) and clock.fullmatch(str(x.get("time") or ""))]
        done = [{"time": x["time"], "what": _text(x.get("what"), 80)}
                for x in d.get("done") or [] if isinstance(x, dict) and clock.fullmatch(str(x.get("time") or ""))]
        laughs = [x for x in d.get("laughs") or [] if isinstance(x, str) and clock.fullmatch(x)]
        laughs_ok = [x for x in d.get("laughs_ok") or [] if isinstance(x, str) and clock.fullmatch(x)]
        days.append({"day": d["day"], "words": words[:GOOD_ITEMS], "done": done[:GOOD_ITEMS], "laughs": laughs[:GOOD_ITEMS],
                     "laughs_ok": laughs_ok[:GOOD_ITEMS]})
    result = {"available": True, "generated_at": _text(data.get("generated_at"), 30), "weeks": weeks, "days": days}
    # 先月との比べ・初めて・今夜の3つ（2026-11-12。どれも無くてよい）
    month = data.get("month")
    if isinstance(month, dict):
        result["month"] = {name: {k: _count(month[name].get(k)) for k in GOOD_MONTH_KEYS}
                           for name in ("this", "last") if isinstance(month.get(name), dict)}
    firsts = [{"day": x["day"], "kind": x["kind"], "text": _text(x.get("text"), 80)}
              for x in data.get("firsts") or []
              if isinstance(x, dict) and DIGEST_DAY.fullmatch(str(x.get("day") or "")) and x.get("kind") in GOOD_FIRST_KINDS]
    if firsts:
        result["firsts"] = firsts[:20]
    tonight = [{"kind": x["kind"], "text": _text(x.get("text"), 120), "time": x["time"]}
               for x in data.get("tonight") or []
               if isinstance(x, dict) and x.get("kind") in GOOD_TONIGHT_KINDS and clock.fullmatch(str(x.get("time") or ""))]
    if tonight:
        result["tonight"] = tonight[:3]
    return result


def parse_good_feedback(data: bytes) -> list[dict]:
    """いいこと帳への「違う」「当たり」を確かめる。おかしな行は落とす。形が違えば ValueError"""
    try:
        body = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise ValueError("いいこと帳の直しを読めません") from None
    if not isinstance(body, dict) or not isinstance(body.get("items"), list):
        raise ValueError("いいこと帳の直しの形が違います")
    items = []
    for item in body["items"][:GOOD_FEEDBACK_MAX]:
        if not isinstance(item, dict):
            continue
        fid, day, when = item.get("id"), item.get("day"), item.get("time")
        if not (isinstance(fid, str) and isinstance(day, str) and isinstance(when, str)):
            continue
        if not 1 <= len(fid) <= 200 or not DIGEST_DAY.fullmatch(day) or not re.fullmatch(r"\d{2}:\d{2}", when):
            continue
        if item.get("kind") not in ("word", "laugh") or item.get("verdict") not in ("wrong", "right"):
            continue
        items.append({"id": fid, "day": day, "time": when, "kind": item["kind"], "verdict": item["verdict"]})
    return items


def write_good_feedback(base: Path, items: list[dict], now: float | None = None) -> Path:
    path = base / GOOD_FEEDBACK_FILE
    body = {"generated_at": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(now if now is not None else time.time())),
            "items": items}
    with _lock:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(body, ensure_ascii=False, indent=1), encoding="utf-8")
        tmp.replace(path)
    return path


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
    path = urlparse(handler.path).path
    if path == "/card":
        handler.send_json(200, read_card(card_file(config)))
        return
    if path == "/vocab":
        handler.send_json(200, read_vocab(home(config)))
        return
    if path == "/good":
        handler.send_json(200, read_good(home(config)))
        return
    if path in appfeeds.READERS:
        handler.send_json(200, appfeeds.READERS[path](home(config)))
        return
    if path in oneline.GETS:  # GET /timeline?day=・/reflection（2026-11-14）
        oneline.http_get(handler, home(config))
        return
    if path in settle.READERS:  # GET /rollout・/checks・/costs（2026-11-15）
        handler.send_json(200, settle.READERS[path](home(config)))
        return
    if path in canonical.GETS:  # GET /canonical?day=（2026-11-15。強化案 57）
        canonical.http_get(handler, home(config))
        return
    handler.send_json(200, read_export(home(config)))


def body_limit(path: str) -> int:
    if path in oneline.LIMITS:  # PayPay の写真は 4MB まで（2026-11-14）
        return oneline.LIMITS[path]
    return PAY_LIMITS.get(path, BODY_LIMIT)


def parse_taps(data: bytes) -> list[dict]:
    """かざした記録を確かめる。おかしな行は落とす。形が違えば ValueError"""
    try:
        body = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise ValueError("かざした記録を読めません") from None
    if not isinstance(body, dict) or not isinstance(body.get("items"), list):
        raise ValueError("かざした記録の形が違います")
    items = []
    for item in body["items"][:20000]:
        if not isinstance(item, dict):
            continue
        tid, when, amount = str(item.get("id") or ""), str(item.get("time") or ""), item.get("amount")
        if not re.fullmatch(r"[0-9A-Za-z_-]{1,80}", tid) or not CARD_TIME.fullmatch(when):
            continue
        if not isinstance(amount, int) or isinstance(amount, bool) or not 0 <= amount < 10**9:
            continue
        items.append({"id": tid, "time": when, "amount": amount,
                      "shop": str(item.get("shop") or "").strip()[:100],
                      "card": str(item.get("card") or "").strip()[:40]})
    return items


def write_taps(base: Path, items: list[dict], now: float | None = None) -> Path:
    path = base / TAPS_FILE
    body = {"generated_at": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(now if now is not None else time.time())),
            "items": items}
    with _lock:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(body, ensure_ascii=False, indent=1), encoding="utf-8")
        tmp.replace(path)
    return path


def write_paypay(base: Path, data: bytes) -> Path | None:
    """明細 CSV を置く。同じ中身がすでにあれば None"""
    if b"," not in data[:4096]:
        raise ValueError("CSV ではありません")
    folder = base / PAYPAY_DIR
    digest = hashlib.sha256(data).hexdigest()
    with _lock:
        folder.mkdir(parents=True, exist_ok=True)
        for old in folder.glob("*.csv"):
            try:
                if old.stat().st_size == len(data) and hashlib.sha256(old.read_bytes()).hexdigest() == digest:
                    return None
            except OSError:
                continue
        path = folder / f"app-{digest[:8]}.csv"
        path.write_bytes(data)
    return path


def http_post_pay(handler, config: dict, path: str, data: bytes, log: Callable[[str], None]) -> None:
    try:
        if path == "/good/feedback":
            items = parse_good_feedback(data)
            write_good_feedback(home(config), items)
            log(f"{handler.client_address[0]} からいいこと帳の直しを母艦へ: {len(items)} 件")
            handler.send_json(200, {"ok": True, "count": len(items)})
        elif path == "/pay/taps":
            items = parse_taps(data)
            write_taps(home(config), items)
            log(f"{handler.client_address[0]} からかざした記録を母艦へ: {len(items)} 件")
            handler.send_json(200, {"ok": True, "count": len(items)})
        else:
            put = write_paypay(home(config), data)
            log(f"{handler.client_address[0]} から PayPay の明細を母艦へ: " + (put.name if put else "同じものがあるので置かない"))
            handler.send_json(200, {"ok": True, "new": put is not None})
    except ValueError as error:
        handler.send_json(400, {"error": str(error)})
    except OSError as error:
        log(f"支払いの記録を母艦に置けませんでした: {error!r}")
        handler.send_json(503, {"error": "母艦に置けませんでした"})


def http_post(handler, config: dict, data: bytes, log: Callable[[str], None]) -> None:
    if urlparse(handler.path).path in oneline.POSTS:  # 2026-11-14（強化案 28・30）
        oneline.POSTS[urlparse(handler.path).path](handler, home(config), data, log)
        return
    if urlparse(handler.path).path in appfeeds.POSTS:
        appfeeds.POSTS[urlparse(handler.path).path](handler, home(config), data, log)
        return
    if urlparse(handler.path).path in PAY_LIMITS:
        http_post_pay(handler, config, urlparse(handler.path).path, data, log)
        return
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
