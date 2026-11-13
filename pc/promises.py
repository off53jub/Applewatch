"""LifeLog PC: 会話の直後に約束だけ知らせる（施策 13。2026-11-13）。

夜のまとめを待たず、会話が終わって 10 分たったら、その会話から「約束・頼まれごと」だけを Claude（軽いモデル）に
拾ってもらい、目に見える通知（APNs の kind "promise"）で iPhone に知らせる。
- 会話の区切りは iPhone が送る記録（POST /records/<日>。閉じた会話だけ）のまま。会話の最後の行から QUIET（10 分）
  たち、FRESH（3 時間）より古くないものだけを見る（初めて動いた日に、前の会話をまとめて知らせない）。
  あとから同じ会話に行が増えたら、増えた会話をもう一度見る（前に知らせたものとは重ねない）。
- Claude には、その会話の行（番号・時刻・話し手・文）だけを渡す。答えは JSON の形（SCHEMA）で、行の番号と
  その行の言葉そのまま（quote）を必ず付けさせる。quote がその行（と前後1行）に無いものは捨てる（接地）。
- 重ねない: 前に拾ったもの（7 日）・アプリの頼まれごと帳（ドライブの「同期/頼まれごと帳.json」。同じ日のもの）・
  その日の 1 日のまとめの「やること」（記録の summary.todos）とよく似たもの（TaskBook.similar と同じ比べ方）は足さない。
- アプリの設定（POST /promises/settings）を守る: 「会話のあとに約束を知らせる」（on）・「Claude を使う」（claude）・
  「職場の会話も Claude で」（work。オフなら職場の会話と、職場か分からない会話は送らない）・「通知に中身を出さない」
  （hide_body）。アプリから一度も設定が届いていなければ何もしない（古いアプリには知らせない）。
  家の PC の claude-config.json の "work": false も効く（claude.call が 403 にする）。
- 通知は 1 日 6 回・10 分に 1 回まで（apns.LIMITS の "promise"）。上限で送れなかったものは、1 時間以内なら次に
  まとめて送る。届かなくても GET /promises-now（36 時間ぶん）でアプリが開いたときに見られる。
- 1 日に Claude に頼む回数は DAILY_CALLS まで。
- HOME/quality-daily.json の days.<日>.promise_alerts に、その日に送れた（APNs が 200 を返した）通知の数を足す
  （読んでから書く。ほかの担当の項目は消さない）。
記録（log.txt）には、数と理由だけを書く（会話の文・人の名前・約束の中身は書かない）。
"""

from __future__ import annotations

import datetime
import hashlib
import json
import os
import re
import threading
import time
import unicodedata
from pathlib import Path
from typing import Callable

import claude

PURPOSE = "promises"
QUIET = 10 * 60                 # 最後の行からこれだけたった会話を見る（秒）
FRESH = 3 * 3600                # これより前に終わった会話は見ない（秒）
MIN_LINES = 3                   # これより行の少ない会話は見ない
TICK = 60.0                     # 見回りの間（秒）
PER_TICK = 3                    # 1 回の見回りで Claude に頼む会話の数
DAILY_CALLS = 80                # 1 日に頼む回数の上限
RETRIES = 3                     # 頼めなかった会話をやり直す回数
TEXT_MAX = 16_000               # 1 つの会話で渡す文字の数（長ければ終わりの方を渡す）
LINE_MAX = 400                  # 1 行の長さ（文字）
KEEP_ITEMS = 7 * 86400          # 拾ったものを覚えておく長さ（重ねないため）
NOW_WINDOW = 36 * 3600          # GET /promises-now に出す長さ
NOW_LIMIT = 20
PENDING_WINDOW = 3600           # 送れなかった通知をまとめて送り直す長さ（apns の EXPIRE と同じ）
PROCESSED_KEEP = 3 * 86400
BODY_MAX = 60                   # 通知の文の長さ
SETTINGS_LIMIT = 4096
KINDS = ("asked", "promised", "delegated")
KIND_LABELS = {"asked": "頼まれた", "promised": "約束", "delegated": "頼んだ"}
SELF_NAME = "自分"
SELF_ID = "me"
TASK_BOOK_FILE = Path("マイドライブ") / "LifeLog" / "同期" / "頼まれごと帳.json"
TASK_BOOK_MAX_BYTES = 20_000_000
DEVICE = re.compile(r"[0-9A-Za-z-]{8,64}")
GETS = ("/promises-now",)
POSTS = ("/promises/settings",)
FEATURE = "promisesnow"

SYSTEM = (
    "あなたは、会話の文字起こしから、本人（話し手が「自分」の人）にかかわる約束と頼まれごとだけを拾う係です。\n"
    "入力は JSON で、lines の各行に番号 n・時刻 time・話し手 speaker・文 text があります。"
    "話し手の名前は音声から推定したもので、間違っていることがあります。\n"
    "拾うのは次の3つだけです:\n"
    "- asked: ほかの人が本人に頼んだこと・本人が引き受けたこと\n"
    "- promised: 本人がほかの人にすると言ったこと（会う・連絡する・送る・確かめる など、あとで実際にすること）\n"
    "- delegated: 本人がほかの人に頼んだこと\n"
    "決まり:\n"
    "- 会話の中ではっきり言われた、あとでする具体的なことだけ。話題・感想・あいさつ・その場で済んだこと・"
    "テレビや機械（音声アシスタントなど）に向けた言葉・本人のかかわらない人どうしの約束は拾いません。\n"
    "- 迷ったら拾いません。無ければ items を空にします。\n"
    "- line はその約束がいちばんはっきり言われた行の番号、quote はその行の文から、そのまま抜き出した言葉"
    "（言い換えない・40 文字まで）です。\n"
    "- who は相手（頼んだ人・頼まれた人・約束した相手）の呼び名で、行の話し手か文にある名前だけ。"
    "分からなければ空にします。「人物」と数字の名前は書きません。\n"
    "- what は、することを短く（30 文字まで）。due は、言われた期限を言われたとおりに（無ければ空）。\n"
    "- 答えは JSON だけです。"
)
SCHEMA = {
    "type": "object",
    "properties": {"items": {"type": "array", "items": {
        "type": "object",
        "properties": {"line": {"type": "integer"}, "quote": {"type": "string"},
                       "kind": {"type": "string", "enum": list(KINDS)}, "who": {"type": "string"},
                       "what": {"type": "string"}, "due": {"type": "string"}},
        "required": ["line", "quote", "kind", "who", "what", "due"], "additionalProperties": False}}},
    "required": ["items"], "additionalProperties": False,
}
TOKENS = 1500
TIMEOUT = 60.0

_quality_lock = threading.Lock()


# MARK: - 比べ方


_DROP = re.compile(r"[\s　、。，．,.!！?？「」『』（）()［］\[\]【】・…ー〜~\-—:：;；\"'’”“]")
_TAILS = ("しておきます", "しておく", "ておきます", "ておく", "します", "ました", "ます", "する")


def norm(text: str) -> str:
    """接地で比べる形（全角半角をそろえ、空白・句読点・長音を除く）"""
    return _DROP.sub("", unicodedata.normalize("NFKC", text or "")).casefold()


def task_key(text: str) -> str:
    """アプリの TaskBook.key と同じ（空白・句読点を除き、「〜します」などの終わりを1つ落とす）"""
    s = "".join(ch for ch in (text or "") if not (ch.isspace() or unicodedata.category(ch)[0] in "PS"))
    for tail in _TAILS:
        if s.endswith(tail) and len(s) > len(tail) + 1:
            s = s[: -len(tail)]
            break
    return s


def similar(a: str, b: str) -> bool:
    """アプリの TaskBook.similar と同じ（片方がもう片方を含むか、2文字ずつの重なりが6割以上）"""
    x, y = task_key(a), task_key(b)
    if not x or not y:
        return False
    if x == y:
        return True
    if min(len(x), len(y)) >= 4 and (x in y or y in x):
        return True

    def grams(s: str) -> set[str]:
        return {s} if len(s) < 2 else {s[i:i + 2] for i in range(len(s) - 1)}

    g, h = grams(x), grams(y)
    return len(g & h) / len(g | h) >= 0.6


# MARK: - 会話を選ぶ


def iso_ms(ms: int) -> str:
    moment = datetime.datetime.fromtimestamp(ms / 1000, datetime.timezone.utc)
    return moment.strftime("%Y-%m-%dT%H:%M:%S.") + f"{int(ms) % 1000:03d}Z"


def local_day(when: float) -> str:
    return time.strftime("%Y-%m-%d", time.localtime(when))


def clock(ms: int) -> str:
    return time.strftime("%H:%M", time.localtime(ms / 1000))


def talk_lines(conversation: dict) -> list[dict]:
    """テレビ・動画の行を除いた行（時刻の順）"""
    return sorted((line for line in conversation.get("lines") or [] if not line.get("media")),
                  key=lambda line: line["time"])


def quiet_conversations(store, now: float) -> list[tuple[str, dict, list[dict], int]]:
    """最後の行から QUIET たち、FRESH より古くない会話。(日, 会話, 行, 最後の行の時刻 ms)。新しく終わったものから"""
    found = []
    now_ms = int(now * 1000)
    for day in sorted({local_day(now), local_day(now - 86400)}):
        parsed = store.day(day) if store is not None else None
        for conversation in (parsed or {}).get("conversations", []):
            if conversation.get("media"):
                continue
            lines = talk_lines(conversation)
            if len(lines) < MIN_LINES:
                continue
            last = max(line["time"] for line in lines)
            if QUIET * 1000 <= now_ms - last <= FRESH * 1000:
                found.append((day, conversation, lines, last))
    found.sort(key=lambda item: -item[3])
    return found


def conversation_key(day: str, conversation: dict) -> str:
    return f"{day}|{conversation['start']}"


def transcript(lines: list[dict]) -> list[dict]:
    """Claude に渡す行（番号は lines の位置）。長い会話は終わりの方を TEXT_MAX まで"""
    rows: list[dict] = []
    total = 0
    for n in range(len(lines) - 1, -1, -1):
        line = lines[n]
        speaker = line.get("speaker") or ""
        if line.get("speakerID") == SELF_ID:
            speaker = SELF_NAME
        text = str(line.get("text") or "")[:LINE_MAX]
        total += len(text) + len(speaker) + 12
        if rows and total > TEXT_MAX:
            break
        rows.append({"n": n, "time": clock(line["time"]), "speaker": speaker, "text": text})
    rows.reverse()
    return rows


# MARK: - 接地・重ねない


def _clip(value, limit: int) -> str:
    return re.sub(r"\s+", " ", str(value or "")).strip()[:limit]


def ground(data, lines: list[dict]) -> list[dict]:
    """Claude の答えから、その行（と前後1行）に quote がそのままあるものだけを残す。おかしなものは捨てる"""
    items = data.get("items") if isinstance(data, dict) else None
    kept: list[dict] = []
    if not isinstance(items, list):
        return kept
    for item in items[:20]:
        if not isinstance(item, dict):
            continue
        n, quote, kind = item.get("line"), _clip(item.get("quote"), 80), item.get("kind")
        what = _clip(item.get("what"), 60)
        if isinstance(n, bool) or not isinstance(n, int) or not 0 <= n < len(lines) or kind not in KINDS or not what:
            continue
        wanted = norm(quote)
        if len(wanted) < 4:
            continue
        near = "".join(norm(str(lines[i].get("text") or "")) for i in range(max(0, n - 1), min(len(lines), n + 2)))
        if wanted not in near:
            continue
        who = _clip(item.get("who"), 20)
        if re.fullmatch(r"人物\s*\d+", who) or who == SELF_NAME:
            who = ""
        kept.append({"line": n, "quote": quote, "kind": kind, "who": who, "what": what, "due": _clip(item.get("due"), 20)})
    return kept


def task_book_file(config: dict) -> Path | None:
    """アプリの頼まれごと帳の写し（config.json の "task_book_file"。無ければドライブ文字を順に探す）"""
    value = str(config.get("task_book_file") or "").strip()
    if value:
        return Path(value)
    for letter in "GHIJKLMNOPQRSTUVWXYZDEF":
        path = Path(f"{letter}:\\") / TASK_BOOK_FILE
        try:
            if path.is_file():
                return path
        except OSError:
            continue
    return None


def read_task_book(path: Path | None) -> list[dict]:
    """頼まれごと帳の写し（[TaskBook.Item]）から {what, day, state}。無い・読めないときは空（読むだけ）"""
    if path is None:
        return []
    try:
        if path.stat().st_size > TASK_BOOK_MAX_BYTES:
            return []
        data = json.loads(path.read_bytes().decode("utf-8-sig"))
    except (OSError, ValueError):
        return []
    out = []
    for item in data if isinstance(data, list) else []:
        if isinstance(item, dict) and isinstance(item.get("what"), str):
            out.append({"what": item["what"], "day": item.get("day") if isinstance(item.get("day"), str) else None,
                        "state": str(item.get("state") or "")})
    return out


def is_duplicate(what: str, day: str, earlier: list[dict], tasks: list[dict], todos: list[str]) -> bool:
    """前に拾ったもの・頼まれごと帳（同じ日か、まだ済んでいないもの）・その日のまとめのやることと、よく似ているか"""
    if any(similar(what, old.get("what") or "") for old in earlier):
        return True
    for task in tasks:
        live = task.get("state") in ("candidate", "open", "rejected")
        if (live or task.get("day") == day) and similar(what, task.get("what") or ""):
            return True
    return any(similar(what, todo) for todo in todos)


# MARK: - 通知の文


def push_text(items: list[dict], hide: bool) -> tuple[str, str]:
    """(題, 文)。文は BODY_MAX 文字まで。hide なら中身を出さない"""
    title = "会話のあとの約束"
    if hide or not items:
        return title, f"約束・頼まれごとが {len(items)} 件ありました。開いて確かめてください。"[:BODY_MAX]
    first = items[0]
    head = (first["who"] + "と：" if first.get("who") else KIND_LABELS.get(first["kind"], "") + "：") + first["what"]
    if first.get("due"):
        head += "（" + first["due"] + "）"
    rest = f" ほか{len(items) - 1}件" if len(items) > 1 else ""
    if len(head) + len(rest) > BODY_MAX:
        head = head[: BODY_MAX - len(rest) - 1] + "…"
    return title, head + rest


# MARK: - 品質の記録（HOME/quality-daily.json）


def bump_quality(home: Path, day: str, key: str = "promise_alerts", by: int = 1) -> None:
    """quality-daily.json の days.<日>.<key> に by を足す（読んでから書く。ほかの項目はそのまま）"""
    path = Path(home) / "quality-daily.json"
    with _quality_lock:
        try:
            data = json.loads(path.read_text(encoding="utf-8-sig"))
        except FileNotFoundError:
            data = {}
        except (OSError, ValueError):
            return  # 読めないものは上書きしない（壊さない）
        if not isinstance(data, dict):
            return
        data.setdefault("version", 1)
        days = data.get("days")
        if not isinstance(days, dict):
            days = data["days"] = {}
        entry = days.get(day)
        if not isinstance(entry, dict):
            entry = days[day] = {}
        value = entry.get(key)
        entry[key] = (value if isinstance(value, int) and not isinstance(value, bool) else 0) + by
        part = path.with_name(path.name + ".promises.part")
        path.parent.mkdir(parents=True, exist_ok=True)
        part.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
        os.replace(part, path)


# MARK: - 見回り


class Watcher:
    def __init__(self, home: Path, records: Callable[[], object], pusher: Callable[[], object],
                 log: Callable[[str], None], config: Callable[[], dict] | None = None,
                 clock: Callable[[], float] = time.time) -> None:
        self.home = Path(home)
        self.folder = self.home / "promises"
        self.records = records
        self.pusher = pusher
        self.log = log
        self.config = config or (lambda: {})
        self.clock = clock
        self.lock = threading.RLock()
        self.stop = threading.Event()
        self.thread: threading.Thread | None = None
        self.state = self._load()

    # MARK: 状態

    def _load(self) -> dict:
        try:
            data = json.loads((self.folder / "state.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            data = {}
        if not isinstance(data, dict):
            data = {}
        return {"settings": data.get("settings") if isinstance(data.get("settings"), dict) else None,
                "processed": data.get("processed") if isinstance(data.get("processed"), dict) else {},
                "tries": data.get("tries") if isinstance(data.get("tries"), dict) else {},
                "items": [i for i in data.get("items") or [] if isinstance(i, dict) and isinstance(i.get("id"), str)]}

    def save(self) -> None:
        with self.lock:
            now = self.clock()
            self.state["items"] = [i for i in self.state["items"] if now - float(i.get("created") or 0) < KEEP_ITEMS]
            cut = (now - PROCESSED_KEEP) * 1000
            self.state["processed"] = {k: v for k, v in self.state["processed"].items()
                                       if isinstance(v, (int, float)) and v >= cut}
            self.state["tries"] = {k: v for k, v in self.state["tries"].items() if k not in self.state["processed"]}
            try:
                self.folder.mkdir(parents=True, exist_ok=True)
                part = self.folder / "state.json.part"
                part.write_text(json.dumps(self.state, ensure_ascii=False, indent=1), encoding="utf-8")
                os.replace(part, self.folder / "state.json")
            except OSError as error:
                self.log(f"約束: 状態を保存できませんでした: {type(error).__name__}")

    def settings(self) -> dict | None:
        with self.lock:
            return dict(self.state["settings"]) if self.state["settings"] else None

    def set_settings(self, body: dict) -> dict:
        """POST /promises/settings の中身を確かめて置く。おかしければ ValueError"""
        if not isinstance(body, dict):
            raise ValueError("中身が JSON のまとまりではありません")
        out: dict = {}
        for name, default in (("on", True), ("claude", True), ("work", True), ("hide_body", False)):
            value = body.get(name, default)
            if not isinstance(value, bool):
                raise ValueError(f"{name} は true か false です")
            out[name] = value
        device = body.get("device")
        if device is not None and (not isinstance(device, str) or not DEVICE.fullmatch(device)):
            raise ValueError("device は英数字と - の 8〜64 文字です")
        out["device"] = device
        out["updated"] = self.clock()
        with self.lock:
            self.state["settings"] = out
            self.save()
        return out

    # MARK: 見回る

    def gate(self) -> str | None:
        """拾ってよいか。だめなら理由（記録用）"""
        settings = self.settings()
        if settings is None:
            return "アプリから設定がまだ届いていない"
        if not settings.get("on") or not settings.get("claude"):
            return "アプリの設定でオフ"
        if self.records() is None:
            return "記録の機能が動いていない"
        if not claude.available():
            return "Claude が使えない"
        if claude.LEDGER.day_calls(claude.today(self.clock()), PURPOSE) >= DAILY_CALLS:
            return "今日の回数の上限"
        return None

    def tick(self) -> dict:
        """1回の見回り。{"asked", "found", "kept", "pushed", "skipped"} を返す（数だけ）"""
        result = {"asked": 0, "found": 0, "kept": 0, "pushed": 0, "skipped": None}
        reason = self.gate()
        if reason is None:
            self._scan(result)
        else:
            result["skipped"] = reason
        result["pushed"] = self._push_pending()
        return result

    def _scan(self, result: dict) -> None:
        settings = self.settings() or {}
        store = self.records()
        now = self.clock()
        config = self.config()
        tasks: list[dict] | None = None
        for day, conversation, lines, last in quiet_conversations(store, now):
            if result["asked"] >= PER_TICK:
                break
            key = conversation_key(day, conversation)
            with self.lock:
                done = self.state["processed"].get(key)
                tries = int(self.state["tries"].get(key) or 0)
            if isinstance(done, (int, float)) and done >= last:
                continue
            work = conversation.get("work")
            if not settings.get("work") and work is not False:
                with self.lock:
                    self.state["processed"][key] = last
                continue
            if tries >= RETRIES:
                continue
            rows = transcript(lines)
            prompt = json.dumps({"lines": rows}, ensure_ascii=False)
            result["asked"] += 1
            try:
                got = claude.call(SYSTEM, prompt, json=True, max_tokens=TOKENS, tier="light", purpose=PURPOSE,
                                  work=work is not False, schema=SCHEMA, timeout=TIMEOUT, log=self.log)
            except claude.ClaudeError as error:
                with self.lock:
                    if error.status in (403, 422):
                        self.state["processed"][key] = last
                    else:
                        self.state["tries"][key] = tries + 1
                self.log(f"約束: Claude に頼めませんでした（{error.status}）")
                if error.status in (402, 503):
                    break
                continue
            except Exception as error:  # noqa: BLE001 — 見回りは止めない
                with self.lock:
                    self.state["tries"][key] = tries + 1
                self.log(f"約束: 拾えませんでした: {type(error).__name__}")
                continue
            raw = got.get("data")
            raw_items = raw.get("items") if isinstance(raw, dict) else None
            result["found"] += len(raw_items) if isinstance(raw_items, list) else 0
            found = ground(raw, lines)
            if tasks is None:
                tasks = read_task_book(task_book_file(config))
            todos = ((store.day(day) or {}).get("summary") or {}).get("todos") or []
            kept = self._add(day, conversation, lines, found, tasks, todos)
            result["kept"] += kept
            with self.lock:
                self.state["processed"][key] = last
                self.state["tries"].pop(key, None)
        if result["asked"]:
            self.save()
            self.log(f"約束: {result['asked']} の会話を見て、{result['found']} 件のうち {result['kept']} 件を残しました")

    def _add(self, day: str, conversation: dict, lines: list[dict], found: list[dict], tasks: list[dict],
             todos: list) -> int:
        now = self.clock()
        added = 0
        with self.lock:
            earlier = list(self.state["items"])
            for item in found:
                if is_duplicate(item["what"], day, earlier, tasks, [t for t in todos if isinstance(t, str)]):
                    continue
                line = lines[item["line"]]
                ident = hashlib.sha1(f"{day}|{conversation['start']}|{task_key(item['what'])}".encode("utf-8")).hexdigest()[:16]
                entry = {"id": ident, "day": day, "conversation_start": iso_ms(conversation["start"]),
                         "said_at": iso_ms(line["time"]), "kind": item["kind"], "who": item["who"],
                         "what": item["what"], "due": item["due"], "quote": item["quote"],
                         "work": conversation.get("work"), "created": now, "alerted": False}
                self.state["items"].append(entry)
                earlier.append(entry)
                added += 1
        return added

    def _push_pending(self) -> int:
        """まだ知らせていないもの（1時間以内）を1つの通知にまとめて送る。送れた数（0 か 1）"""
        now = self.clock()
        with self.lock:
            pending = [i for i in self.state["items"]
                       if not i.get("alerted") and now - float(i.get("created") or 0) < PENDING_WINDOW]
        settings = self.settings() or {}
        if not pending or not settings.get("on"):
            return 0
        pusher = self.pusher()
        if pusher is None or not pusher.ready():
            return 0
        device = settings.get("device")
        devices = [device] if device and pusher.usable(device) else None
        targets = devices if devices is not None else [d for d in list(pusher.devices) if pusher.usable(d)]
        if not targets or not any(pusher.allowed(d, "promise", now) for d in targets):
            return 0
        pending.sort(key=lambda i: -float(i.get("created") or 0))
        title, body = push_text(pending, bool(settings.get("hide_body")))
        alert = {"title": title, "body": body}
        extra = {"ids": [i["id"] for i in pending[:10]], "day": pending[0]["day"]}
        results = pusher.send("promise", targets, alert=alert, extra=extra)
        sent = sum(1 for r in results if r.get("ok"))
        if sent:
            with self.lock:
                for item in pending:
                    item["alerted"] = True
            self.save()
            try:
                bump_quality(self.home, local_day(now))
            except OSError as error:
                self.log(f"約束: 品質の記録に書けませんでした: {type(error).__name__}")
        return 1 if sent else 0

    # MARK: 裏で回す

    def start(self) -> None:
        def loop() -> None:
            while not self.stop.wait(TICK):
                try:
                    self.tick()
                except Exception as error:  # noqa: BLE001 — 何があっても見回りは続ける
                    self.log(f"約束の見回りで止まりかけました: {type(error).__name__}")

        self.thread = threading.Thread(target=loop, name="promises", daemon=True)
        self.thread.start()

    # MARK: GET /promises-now

    def now_items(self) -> dict:
        now = self.clock()
        settings = self.settings()
        with self.lock:
            items = [i for i in self.state["items"] if now - float(i.get("created") or 0) < NOW_WINDOW]
        items.sort(key=lambda i: -float(i.get("created") or 0))
        out = []
        for i in items[:NOW_LIMIT]:
            out.append({"id": i["id"], "day": i.get("day"), "conversation_start": i.get("conversation_start"),
                        "said_at": i.get("said_at"), "kind": i.get("kind"), "who": i.get("who") or "",
                        "what": i.get("what") or "", "due": i.get("due") or "", "quote": i.get("quote") or "",
                        "work": i.get("work"), "created_at": claude.now_iso(float(i.get("created") or 0)),
                        "alerted": bool(i.get("alerted"))})
        return {"available": True, "generated_at": claude.now_iso(now),
                "on": bool(settings and settings.get("on")), "items": out}


W: Watcher | None = None


def start(home: Path, records: Callable[[], object], pusher: Callable[[], object], log: Callable[[str], None],
          config: Callable[[], dict] | None = None, background: bool = True) -> Watcher:
    global W
    W = Watcher(home, records, pusher, log, config)
    if background:
        W.start()
    return W


def features() -> list[str]:
    return [FEATURE] if W is not None else []


# MARK: - 受け口


def http_get(handler) -> None:
    if W is None:
        handler.send_json(200, {"available": False, "reason": "約束の見回りが動いていません"})
        return
    try:
        handler.send_json(200, W.now_items())
    except Exception as error:  # noqa: BLE001
        handler.send_json(200, {"available": False, "reason": f"読めませんでした: {type(error).__name__}"})


def http_post(handler, log: Callable[[str], None]) -> None:
    """POST /promises/settings（合言葉は lifelog_pc.py が確かめてから呼ぶ）"""
    try:
        length = int(handler.headers.get("Content-Length") or 0)
    except ValueError:
        length = 0
    if length <= 0 or length > SETTINGS_LIMIT:
        handler.discard_body()
        handler.send_json(400 if length <= 0 else 413, {"error": "中身がありません" if length <= 0 else "長すぎます"})
        return
    data = handler.rfile.read(length)
    if W is None:
        handler.send_json(503, {"error": "約束の見回りが動いていません"})
        return
    try:
        body = json.loads(data.decode("utf-8"))
        saved = W.set_settings(body)
    except (UnicodeDecodeError, ValueError) as error:
        message = str(error) if not isinstance(error, (UnicodeDecodeError, json.JSONDecodeError)) else "中身が JSON ではありません"
        handler.send_json(400, {"error": message})
        return
    log(f"約束: アプリの設定を受け取りました（知らせる {'オン' if saved['on'] else 'オフ'}・"
        f"職場 {'送る' if saved['work'] else '送らない'}・中身 {'隠す' if saved['hide_body'] else '出す'}）")
    handler.send_json(200, {"ok": True})
