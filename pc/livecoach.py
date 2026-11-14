"""強化案 50・51・52 の家の PC の口（2026-11-15。番号は D:\\Lifelog\\docs\\system-proposal-2026-11-13.md の「追記 3」）。

50 会議の相棒（その場版）:
- POST /meeting-live/state（features の "meetinglive"）
  {"on": bool, "start": ISO?, "title": str(≤60)?, "claude": bool, "work": bool, "work_ok": bool,
   "mine": [{"at": ISO, "text": str(≤400)}](≤40)?}
  アプリが会議モードを始めた・終えたとき（と、会議モードのあいだ 60 秒ごと）に送る。on が false→true で新しい会議にする。
  "mine" はアプリが「自分」と分けた行（会議の中のもの）。家の PC の区切りの文と同じ文の行を「自分」にする。
  claude（Claude を使う）が false、または work（職場の時間）が true で work_ok（職場の会話も Claude で）が false なら、
  Claude には送らない（文はためるが、更新しない。reason に出す）。15 分 届かなければ、会議モードは終わったものとする。
- 区切りの文: /transcribe と後で受け取る文字起こし（/jobs・時計の /w/jobs）の答えの行を、会議モードのあいだだけためる
  （lifelog_pc.transcribe_reply が feed を呼ぶ）。区切りの録音の始まりが会議の始まりより前のものはためない。
- 更新: 新しい行があり、前の更新から MIN_GAP（60 秒）たったら、Claude（軽いモデル・purpose "meeting-live"）に、
  前の答えと会議の行（終わりの方を TEXT_MAX 文字まで）を渡して「決まったこと・自分の宿題・聞き忘れ」を作り直してもらう。
  答えは JSON の形（SCHEMA）で、行の番号と、その行の言葉そのまま（quote）を必ず付けさせる。quote が会議の行に無いものは捨てる。
  1 日 DAILY_CALLS 回まで（claude-config.json の daily_caps "meeting-live" も効く）。
- GET /meeting-live?since=<版>  {"available": true, "on", "started_at", "title", "version", "changed", "updated_at",
  "decided"/"homework"/"unasked": [{"id", "text", "quote", "at"}], "counts", "latest": [str](≤2), "lines", "reason",
  "delay": {"last", "median", "claude", "n"}}。delay は「区切りを受け取ってから、その行を入れて更新し終えるまで」の秒。
- 会議モードの始まりと終わりを HOME/meetinglive/sessions.json に残す（話し方コーチの「会議で話した割合」に使う。30 日）。
51 話し方コーチ・52 緊張した場面（母艦の scripts が作る写しを読む）:
- GET /coach（"coach"）← state/coach_for_app.json  GET /tension（"tension"）← state/tension_for_app.json
- POST /health/hr（"hrsamples"）{"samples": [{"t": 秒, "bpm"}](≤3000), "steps": [{"t": 秒, "n"}](≤3000)}
  時計の心拍（1 分ごと）と歩数（1 分ごと）を、母艦の archive/health-hr/YYYY/MM/DD.json に分ごとに足す（同じ分は新しい値）。
  8 日より前・先の時刻・おかしな値は落とす。アプリの「ヘルスケア」がオンのときだけ送られてくる。
どれも型・長さ・形を確かめ、おかしな行は落とす。無い・読めないときは {"available": false, "reason": …}。
記録（log.txt）には数だけを書く（会議の文・宿題・人の名前・心拍の値は書かない）。
"""

from __future__ import annotations

import datetime
import hashlib
import json
import os
import re
import statistics
import threading
import time
import unicodedata
from pathlib import Path
from typing import Callable

import appfeeds
import claude

PURPOSE = "meeting-live"
FEATURE = "meetinglive"
FEATURES = ("coach", "tension", "hrsamples")
GETS = ("/meeting-live", "/coach", "/tension")
POSTS = ("/meeting-live/state", "/health/hr")
STATE_LIMIT = 64 * 1024
HR_LIMIT = 512 * 1024

MIN_GAP = 60.0                 # Claude に頼む間（秒）。1 分に 1 回まで
TICK = 3.0
DAILY_CALLS = 300              # 1 日に頼む回数（会議 5 時間ぶん）
TEXT_MAX = 9000                # 1 回に渡す会議の行の文字の数（終わりの方）
LINE_MAX = 300
BUFFER_LINES = 4000            # ためる行の数（4 時間の会議でも足りる）
KINDS = ("decided", "homework", "unasked")
KIND_LABELS = {"decided": "決", "homework": "宿", "unasked": "聞"}
ITEMS_PER_KIND = 5
ITEM_TEXT = 40
QUOTE_MAX = 40
TITLE_MAX = 60
MINE_MAX = 40
QUIET_OFF = 15 * 60            # これだけ届かなければ終わったものとする
LONGEST = 4 * 3600
KEEP_AFTER = 30 * 60           # 終わってから GET で見せる長さ
EARLY = 60.0                   # 会議の始まりより前に始まった区切りは、これより前ならためない
SESSIONS_KEEP = 30 * 86400
DELAYS_KEEP = 100
TOKENS = 1500
TIMEOUT = 75.0                 # 測ったら 18〜65 秒（2026-11-15・4 回）。切って頼み直すと 2 回ぶんになるので長めに
SELF_NAME = "自分"
UNKNOWN = "?"

SYSTEM = (
    "あなたは会議の最中に、本人（話し手が「自分」の人）のために「決まったこと・自分の宿題・聞き忘れ」を保つ係です。\n"
    "入力は JSON で、title は予定の題名（無いこともある）、state は前の答え、lines は会議の文字起こしの行（番号 n・時刻 time・"
    "話し手 speaker・文 text）、new_from はこの番号から後が新しく届いた行です。文字起こしは音声から作ったもので、"
    "聞き違いがあります。話し手が「?」の行は、誰が話したか分かりません。\n"
    "作るのは次の3つだけです:\n"
    "- decided: この会議で決まったこと・合意したこと\n"
    "- homework: 本人がこれからすること（本人が引き受けた・本人に頼まれたとはっきり分かるもの）\n"
    "- unasked: まだ結論の出ていない論点や、決めるのに要るのにまだ話に出ていない点のうち、本人が会議のうちに聞いておくと"
    "よいこと（短い問いの形）\n"
    "決まり:\n"
    "- 各項目は text（40 文字まで）・もとになった行の番号 line・その行の文からそのまま抜き出した quote（30 文字まで。"
    "言い換えない）です。\n"
    "- state にある項目は、新しい行で変わらなければそのまま残します。取り消された・済んだ・答えの出たものは外します。\n"
    "- 各 5 つまで。迷ったら入れません。会議と関係のない雑談からは作りません。\n"
    "- 答えは JSON だけです。"
)
_ITEM = {"type": "object",
         "properties": {"text": {"type": "string"}, "line": {"type": "integer"}, "quote": {"type": "string"}},
         "required": ["text", "line", "quote"], "additionalProperties": False}
SCHEMA = {"type": "object",
          "properties": {k: {"type": "array", "items": _ITEM} for k in KINDS},
          "required": list(KINDS), "additionalProperties": False}

_DROP = re.compile(r"[\s　、。，．,.!！?？「」『』（）()［］\[\]【】・…ー〜~\-—:：;；\"'’”“]")


def norm(text: str) -> str:
    """比べる形（全角半角をそろえ、空白・句読点・長音を除く。promises.norm と同じ）"""
    return _DROP.sub("", unicodedata.normalize("NFKC", text or "")).casefold()


def _clip(value, limit: int) -> str:
    return re.sub(r"\s+", " ", str(value or "")).strip()[:limit]


def iso(when: float | None) -> str | None:
    return claude.now_iso(when) if when else None


def parse_iso(value) -> float | None:
    if not isinstance(value, str) or not appfeeds.ISO.fullmatch(value):
        return None
    try:
        moment = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if moment.tzinfo is None:
        moment = moment.astimezone()
    return moment.timestamp()


def _write(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    part = path.with_name(path.name + ".part")
    part.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(part, path)


# MARK: - 接地


def ground(data, lines: list[dict]) -> dict[str, list[dict]]:
    """Claude の答えから、quote が会議の行（番号の行と前後1行、無ければ全部）にそのままあるものだけを残す"""
    out: dict[str, list[dict]] = {k: [] for k in KINDS}
    if not isinstance(data, dict):
        return out
    whole = None
    by_n = {line["n"]: line for line in lines}
    for kind in KINDS:
        seen: set[str] = set()
        for item in (data.get(kind) if isinstance(data.get(kind), list) else [])[:ITEMS_PER_KIND * 2]:
            if not isinstance(item, dict):
                continue
            text, quote, n = _clip(item.get("text"), ITEM_TEXT), _clip(item.get("quote"), QUOTE_MAX), item.get("line")
            wanted = norm(quote)
            if not text or len(wanted) < 3 or isinstance(n, bool) or not isinstance(n, int):
                continue
            near = "".join(norm(by_n[i]["text"]) for i in (n - 1, n, n + 1) if i in by_n)
            if wanted not in near:
                if whole is None:
                    whole = "".join(norm(line["text"]) for line in lines)
                if wanted not in whole:
                    continue
            key = norm(text)
            if key in seen:
                continue
            seen.add(key)
            at = by_n[n]["t"] if n in by_n else None
            ident = hashlib.sha1(f"{kind}|{key}".encode("utf-8")).hexdigest()[:12]
            out[kind].append({"id": ident, "text": text, "quote": quote, "line": n, "at": at})
            if len(out[kind]) >= ITEMS_PER_KIND:
                break
    return out


# MARK: - 会議の相棒


class Live:
    def __init__(self, home: Path, log: Callable[[str], None], clock: Callable[[], float] = time.time) -> None:
        self.home = Path(home)
        self.folder = self.home / "meetinglive"
        self.log = log
        self.clock = clock
        self.lock = threading.RLock()
        self.stop = threading.Event()
        self.thread: threading.Thread | None = None
        self.busy = False
        self.s = self._load()

    # MARK: 状態

    @staticmethod
    def _empty() -> dict:
        return {"on": False, "start": None, "end": None, "heard": None, "title": None, "claude": True, "work": True,
                "work_ok": True, "lines": [], "seen": [], "items": {k: [] for k in KINDS}, "version": 0,
                "updated": None, "last_call": 0.0, "upto": 0, "next_n": 0, "latest": [], "delays": [], "reason": None,
                "tries": 0}

    def _load(self) -> dict:
        state = self._empty()
        try:
            data = json.loads((self.folder / "state.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return state
        if isinstance(data, dict):
            for key, value in data.items():
                if key in state and isinstance(value, type(state[key])) or (key in state and state[key] is None):
                    state[key] = value
        return state

    def save(self) -> None:
        with self.lock:
            try:
                _write(self.folder / "state.json", self.s)
            except OSError as error:
                self.log(f"会議の相棒: 状態を保存できませんでした: {type(error).__name__}")

    def _note_session(self, start: float, end: float | None, title: str | None) -> None:
        """HOME/meetinglive/sessions.json に会議モードの始まりと終わりを残す（30 日）"""
        path = self.folder / "sessions.json"
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            data = []
        rows = [r for r in data if isinstance(r, dict) and isinstance(r.get("start"), (int, float))] \
            if isinstance(data, list) else []
        rows = [r for r in rows if self.clock() - r["start"] < SESSIONS_KEEP and abs(r["start"] - start) > 1]
        rows.append({"start": round(start, 3), "end": round(end, 3) if end else None, "titled": bool(title)})
        rows.sort(key=lambda r: r["start"])
        try:
            _write(path, rows)
        except OSError as error:
            self.log(f"会議の相棒: 会議の時刻を残せませんでした: {type(error).__name__}")

    def active(self) -> bool:
        """会議モードの最中か（届かなくなって 15 分・始めて 4 時間で終わり）"""
        with self.lock:
            if not self.s["on"]:
                return False
            now = self.clock()
            heard = float(self.s.get("heard") or 0)
            start = float(self.s.get("start") or 0)
            if now - heard > QUIET_OFF or now - start > LONGEST:
                self._end(min(now, heard + 60 if heard else now))
                return False
            return True

    def _end(self, when: float) -> None:
        with self.lock:
            if not self.s["on"]:
                return
            self.s["on"] = False
            self.s["end"] = when
            start = float(self.s.get("start") or when)
            self._note_session(start, when, self.s.get("title"))
            self.save()
            self.log(f"会議の相棒: 会議モードが終わりました（行 {len(self.s['lines'])}・更新 {self.s['version']} 回）")

    # MARK: アプリから

    def set_state(self, body) -> dict:
        """POST /meeting-live/state の中身を確かめて置く。おかしければ ValueError"""
        if not isinstance(body, dict):
            raise ValueError("中身が JSON のまとまりではありません")
        on = body.get("on")
        if not isinstance(on, bool):
            raise ValueError("on は true か false です")
        flags = {}
        for name in ("claude", "work", "work_ok"):
            value = body.get(name, name != "work")
            if not isinstance(value, bool):
                raise ValueError(f"{name} は true か false です")
            flags[name] = value
        start = parse_iso(body.get("start")) if body.get("start") is not None else None
        if body.get("start") is not None and start is None:
            raise ValueError("start は ISO 8601 の時刻です")
        title = body.get("title")
        if title is not None and not isinstance(title, str):
            raise ValueError("title は文字です")
        mine = body.get("mine") or []
        if not isinstance(mine, list):
            raise ValueError("mine は並びです")
        now = self.clock()
        with self.lock:
            if not on:
                self._end(now)
                return {"ok": True, "on": False}
            start = start if start is not None and start <= now + 60 else now
            same = self.s["on"] and abs(float(self.s.get("start") or 0) - start) < 2
            if not same:
                if self.s["on"]:
                    self._end(now)
                fresh = self._empty()
                fresh.update(on=True, start=start, title=_clip(title, TITLE_MAX) or None)
                self.s = fresh
                self._note_session(start, None, self.s["title"])
                self.log("会議の相棒: 会議モードが始まりました")
            self.s.update(heard=now, **flags)
            if title and not self.s.get("title"):
                self.s["title"] = _clip(title, TITLE_MAX)
            marked = self._mark_mine(mine)
            self.save()
        return {"ok": True, "on": True, "marked": marked}

    def _mark_mine(self, mine: list) -> int:
        """アプリが「自分」と分けた行と同じ文の行を「自分」にする（数を返す）"""
        texts = set()
        for row in mine[:MINE_MAX]:
            if isinstance(row, dict) and isinstance(row.get("text"), str):
                key = norm(row["text"][:400])
                if len(key) >= 4:
                    texts.add(key)
        marked = 0
        for line in self.s["lines"]:
            if line.get("me"):
                continue
            key = norm(line["text"])
            if len(key) >= 4 and any(key in t or t in key for t in texts):
                line["me"] = True
                marked += 1
        return marked

    # MARK: 区切りの文

    def feed(self, lines: list, received: float | None = None, chunk_start: float | None = None,
             chunk_end: float | None = None, name: str | None = None) -> int:
        """文字起こしの答えの行をためる（会議モードのあいだだけ）。ためた行の数"""
        if not isinstance(lines, list) or not lines or not self.active():
            return 0
        received = received or self.clock()
        with self.lock:
            start = float(self.s.get("start") or 0)
            if chunk_start is not None and chunk_start < start - EARLY:
                return 0
            # 同じ区切りが /transcribe と /jobs の両方から来ることがあるので、名前ではなく文で見分ける
            key = hashlib.sha1("".join(str(x.get("text") or "") for x in lines if isinstance(x, dict))
                               .encode("utf-8")).hexdigest()[:16]
            if key in self.s["seen"]:
                return 0
            self.s["seen"] = (self.s["seen"] + [key])[-500:]
            added = 0
            base = chunk_start if chunk_start is not None else received
            for x in lines:
                if not isinstance(x, dict):
                    continue
                text = _clip(x.get("text"), LINE_MAX)
                if not text:
                    continue
                offset = x.get("start") if isinstance(x.get("start"), (int, float)) and not isinstance(x.get("start"), bool) else 0
                n = int(self.s.get("next_n") or 0)
                self.s["next_n"] = n + 1
                self.s["lines"].append({"n": n, "t": round(base + float(offset), 3), "text": text,
                                        "me": False, "received": round(received, 3),
                                        "chunk_end": round(chunk_end, 3) if chunk_end else None})
                added += 1
            if len(self.s["lines"]) > BUFFER_LINES:
                self.s["lines"] = self.s["lines"][-BUFFER_LINES:]
            if added:
                self.save()
        return added

    # MARK: 更新

    def gate(self) -> str | None:
        """今 Claude に頼んでよいか。だめなら理由（画面と記録に出す）"""
        with self.lock:
            if not self.s.get("claude"):
                return "アプリの設定で Claude を使わない"
            if self.s.get("work") and not self.s.get("work_ok"):
                return "職場の会話は Claude に送らない設定"
        if not claude.available():
            return "Claude が使えない"
        if claude.LEDGER.day_calls(claude.today(self.clock()), PURPOSE) >= DAILY_CALLS:
            return "今日の回数の上限"
        return None

    def due(self) -> bool:
        with self.lock:
            upto = int(self.s.get("upto") or 0)
            new = bool(self.s["lines"]) and self.s["lines"][-1]["n"] >= upto
            return new and self.clock() - float(self.s.get("last_call") or 0) >= MIN_GAP

    def window(self) -> tuple[list[dict], int]:
        """Claude に渡す行（終わりの方を TEXT_MAX 文字まで）と、新しい行の始まりの番号"""
        with self.lock:
            lines = list(self.s["lines"])
            upto = int(self.s.get("upto") or 0)
        rows: list[dict] = []
        total = 0
        for line in reversed(lines):
            total += len(line["text"]) + 16
            if rows and total > TEXT_MAX:
                break
            rows.append(line)
        rows.reverse()
        return rows, upto

    def update(self) -> dict:
        """1 回更新する。{"asked", "kept", "skipped"}（数だけ）"""
        result = {"asked": 0, "kept": 0, "skipped": None}
        if not self.active() or not self.due():
            return result
        reason = self.gate()
        with self.lock:
            self.s["reason"] = reason
        if reason is not None:
            result["skipped"] = reason
            with self.lock:
                self.s["last_call"] = self.clock()  # 1 分に 1 回だけ確かめ直す
            return result
        rows, upto = self.window()
        newest = rows[-1]["n"] if rows else upto
        with self.lock:
            previous = {k: [{"text": i["text"], "line": i["line"], "quote": i["quote"]} for i in self.s["items"][k]]
                        for k in KINDS}
            title = self.s.get("title")
            work = bool(self.s.get("work"))
            self.s["last_call"] = self.clock()
        sent = [{"n": r["n"], "time": time.strftime("%H:%M", time.localtime(r["t"])),
                 "speaker": SELF_NAME if r.get("me") else UNKNOWN, "text": r["text"]} for r in rows]
        prompt = json.dumps({"title": title or "", "state": previous, "new_from": upto, "lines": sent}, ensure_ascii=False)
        result["asked"] = 1
        began = self.clock()
        try:
            got = claude.call(SYSTEM, prompt, json=True, max_tokens=TOKENS, tier="light", purpose=PURPOSE, work=work,
                              schema=SCHEMA, timeout=TIMEOUT, log=self.log)
        except claude.ClaudeError as error:
            with self.lock:
                self.s["reason"] = f"Claude に頼めませんでした（{error.status}）"
                self.s["tries"] = int(self.s.get("tries") or 0) + 1
                if error.status in (403, 422) or self.s["tries"] >= 3:
                    self.s["upto"] = newest + 1  # この行は飛ばす
                    self.s["tries"] = 0
            self.log(f"会議の相棒: Claude に頼めませんでした（{error.status}）")
            self.save()
            return result
        except Exception as error:  # noqa: BLE001 — 見回りは止めない
            self.log(f"会議の相棒: 更新できませんでした: {type(error).__name__}")
            return result
        took = self.clock() - began
        with self.lock:
            kept = ground(got.get("data"), list(self.s["lines"]))
            before = {i["id"] for k in KINDS for i in self.s["items"][k]}
            self.s["items"] = kept
            done = self.clock()
            fresh = [r for r in self.s["lines"] if upto <= r["n"] <= newest]
            if fresh:
                waits = [done - r["received"] for r in fresh]
                ends = [done - r["chunk_end"] for r in fresh if r.get("chunk_end")]
                self.s["delays"] = (self.s["delays"] + [{"at": round(done, 3), "oldest": round(max(waits), 2),
                                                         "newest": round(min(waits), 2), "claude": round(took, 2),
                                                         "from_end": round(max(ends), 2) if ends else None}])[-DELAYS_KEEP:]
            latest = [f"{KIND_LABELS[k]} {i['text']}" for k in ("homework", "decided", "unasked")
                      for i in kept[k] if i["id"] not in before]
            self.s["latest"] = latest[:2] if latest else self.s.get("latest", [])[:2]
            self.s["upto"] = newest + 1
            self.s["tries"] = 0
            self.s["version"] = int(self.s.get("version") or 0) + 1
            self.s["updated"] = done
            self.s["reason"] = None
            result["kept"] = sum(len(v) for v in kept.values())
        self.save()
        counts = {k: len(kept[k]) for k in KINDS}
        self.log(f"会議の相棒: {len(rows)} 行を見て更新（決 {counts['decided']}・宿 {counts['homework']}・"
                 f"聞 {counts['unasked']}・{took:.1f} 秒）")
        return result

    # MARK: GET

    def view(self, since: str | None = None) -> dict:
        with self.lock:
            on = self.active()
            s = self.s
            end = s.get("end")
            if not on and (not s.get("start") or not end or self.clock() - float(end) > KEEP_AFTER):
                return {"available": True, "on": False, "version": int(s.get("version") or 0), "changed": False}
            version = int(s.get("version") or 0)
            try:
                old = int(since) if since not in (None, "") else -1
            except ValueError:
                old = -1
            items = {k: [{"id": i["id"], "text": i["text"], "quote": i["quote"], "at": iso(i.get("at"))}
                         for i in s["items"][k]] for k in KINDS}
            delays = s.get("delays") or []
            body = {"available": True, "on": on, "started_at": iso(s.get("start")), "ended_at": iso(end) if not on else None,
                    "title": s.get("title") or "", "version": version, "changed": version > old,
                    "updated_at": iso(s.get("updated")), "counts": {k: len(items[k]) for k in KINDS},
                    "latest": list(s.get("latest") or [])[:2], "lines": len(s["lines"]), "reason": s.get("reason")}
            if version > old:
                body.update(items)
            if delays:
                body["delay"] = {"last": delays[-1]["oldest"], "median": round(statistics.median(d["oldest"] for d in delays), 2),
                                 "claude": round(statistics.median(d["claude"] for d in delays), 2), "n": len(delays)}
            return body

    # MARK: 裏で回す

    def start(self) -> None:
        def loop() -> None:
            while not self.stop.wait(TICK):
                try:
                    self.update()
                except Exception as error:  # noqa: BLE001 — 何があっても見回りは続ける
                    self.log(f"会議の相棒の見回りで止まりかけました: {type(error).__name__}")

        self.thread = threading.Thread(target=loop, name="meetinglive", daemon=True)
        self.thread.start()


L: Live | None = None


def start(home: Path, log: Callable[[str], None], background: bool = True) -> Live:
    global L
    L = Live(home, log)
    if background:
        L.start()
    return L


def features() -> list[str]:
    return ([FEATURE] if L is not None else []) + list(FEATURES)


def feed(lines, received: float | None = None, times: dict | None = None, name: str | None = None) -> int:
    """lifelog_pc.transcribe_reply から呼ぶ（失敗しても文字起こしは止めない）"""
    if L is None:
        return 0
    times = times or {}
    try:
        return L.feed(lines, received, times.get("chunk_start"), times.get("chunk_end"), name)
    except Exception:  # noqa: BLE001
        return 0


# MARK: - 母艦の写し（51・52）

COACH = Path("state") / "coach_for_app.json"
TENSION = Path("state") / "tension_for_app.json"
COACH_TEXT = 120
COACH_WHY = 160
TENSION_ITEMS = 30
TENSION_GROUPS = 10


def _clipf(value, low: float, high: float, digits: int = 2) -> float | None:
    number = appfeeds._num(value, low, high)
    return round(number, digits) if number is not None else None


def _moment(x: dict) -> dict | None:
    """コーチの 1 つ（よかった一言・直すとよい一言）"""
    if not isinstance(x, dict):
        return None
    text = appfeeds._text(x.get("text"), COACH_TEXT)
    when = appfeeds._iso(x.get("time"))
    if not text or not when:
        return None
    audio = x.get("audio") if isinstance(x.get("audio"), str) and appfeeds.AUDIO.fullmatch(x["audio"]) else None
    offset, end = _clipf(x.get("offset"), 0, 7200), _clipf(x.get("end"), 0, 7200)
    if offset is not None and end is not None and end < offset:
        end = None
    return {"text": text, "why": appfeeds._text(x.get("why"), COACH_WHY), "better": appfeeds._text(x.get("better"), COACH_TEXT),
            "time": when, "audio": audio, "offset": offset if audio else None, "end": end if audio else None,
            "conversation": appfeeds._text(x.get("conversation"), 40) or None}


def read_coach(base: Path) -> dict:
    data, failure = appfeeds._load(base, COACH, "話し方コーチ")
    if failure or data is None:
        return failure
    day = appfeeds._day(data.get("day"))
    if day is None:
        return {"available": False, "reason": "母艦の話し方コーチの形が違います"}
    week = data.get("week") if isinstance(data.get("week"), dict) else {}
    out_week = {"from": appfeeds._day(week.get("from")), "to": appfeeds._day(week.get("to")),
                "lines": appfeeds._int(week.get("lines"), 0, 1_000_000) or 0,
                "conclusion_first": _clipf(week.get("conclusion_first"), 0, 1, 3),
                "judged": appfeeds._int(week.get("judged"), 0, 1_000_000) or 0,
                "filler_per_min": _clipf(week.get("filler_per_min"), 0, 1000),
                "questions": appfeeds._int(week.get("questions"), 0, 1_000_000) or 0,
                "talk_share_meetings": _clipf(week.get("talk_share_meetings"), 0, 1, 3),
                "meetings": appfeeds._int(week.get("meetings"), 0, 10_000) or 0,
                "meeting_source": week.get("meeting_source") if week.get("meeting_source") in ("mode", "guess", "none") else "none"}
    seeds = data.get("rehearse") if isinstance(data.get("rehearse"), dict) else {}
    return {"available": True, "version": appfeeds._version(data), "generated_at": appfeeds._iso(data.get("generated_at")),
            "day": day, "good": _moment(data.get("good")), "improve": _moment(data.get("improve")), "week": out_week,
            "rehearse": {"seeds": appfeeds._int(seeds.get("seeds"), 0, 1000) or 0,
                         "first": appfeeds._text(seeds.get("first"), 80) or None}}


def read_tension(base: Path) -> dict:
    data, failure = appfeeds._load(base, TENSION, "緊張した場面")
    if failure or data is None:
        return failure
    if not isinstance(data.get("items"), list):
        return {"available": False, "reason": "母艦の緊張した場面の形が違います"}
    items = []
    for x in data["items"][:TENSION_ITEMS * 3]:
        if not isinstance(x, dict):
            continue
        ident, day, start = appfeeds._id(x.get("id")), appfeeds._day(x.get("day")), appfeeds._iso(x.get("start"))
        peak, baseline = appfeeds._int(x.get("peak_bpm"), 30, 250), appfeeds._int(x.get("baseline_bpm"), 30, 200)
        if not ident or not day or not start or peak is None or baseline is None:
            continue
        talk = x.get("conversation") if isinstance(x.get("conversation"), dict) else None
        conversation = None
        if talk:
            conversation = {"title": appfeeds._text(talk.get("title"), 40),
                            "people": appfeeds._strings(talk.get("people"), 20, 5),
                            "place": appfeeds._text(talk.get("place"), 40)}
        items.append({"id": ident, "day": day, "start": start, "end": appfeeds._iso(x.get("end")), "peak_bpm": peak,
                      "baseline_bpm": baseline, "delta": peak - baseline, "conversation": conversation})
        if len(items) >= TENSION_ITEMS:
            break

    def groups(key: str, name: str) -> list[dict]:
        out = []
        for g in (data.get(key) if isinstance(data.get(key), list) else [])[:TENSION_GROUPS * 3]:
            if not isinstance(g, dict):
                continue
            label = appfeeds._text(g.get(name), 20)
            times = appfeeds._int(g.get("times"), 0, 100_000)
            if label and times is not None:
                out.append({name: label, "times": times, "of": appfeeds._int(g.get("of"), 0, 100_000) or times})
            if len(out) >= TENSION_GROUPS:
                break
        return out

    source = data.get("source") if data.get("source") in ("minute", "conversation") else "conversation"
    return {"available": True, "version": appfeeds._version(data), "generated_at": appfeeds._iso(data.get("generated_at")),
            "from": appfeeds._day(data.get("from")), "to": appfeeds._day(data.get("to")), "source": source,
            "items": items, "by_person": groups("by_person", "name"), "by_topic": groups("by_topic", "word")}


# MARK: - 心拍の分ごとの記録（52）

HR_DIR = Path("archive") / "health-hr"
HR_SAMPLES = 3000
HR_BACK = 8 * 86400
_hr_lock = threading.Lock()


def parse_hr(data: bytes, now: float | None = None) -> dict[str, dict]:
    """POST /health/hr の中身を、日 → {"hr": {HH:MM: bpm}, "steps": {HH:MM: n}} にする。おかしければ ValueError"""
    try:
        body = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise ValueError("中身が JSON ではありません") from None
    if not isinstance(body, dict):
        raise ValueError("中身が JSON のまとまりではありません")
    now = now if now is not None else time.time()
    days: dict[str, dict] = {}
    for field, key, low, high in (("samples", "bpm", 25, 250), ("steps", "n", 0, 1000)):
        rows = body.get(field) or []
        if not isinstance(rows, list) or len(rows) > HR_SAMPLES:
            raise ValueError(f"{field} は {HR_SAMPLES} 個までの並びです")
        for row in rows:
            if not isinstance(row, dict):
                continue
            t, value = row.get("t"), row.get(key)
            if isinstance(t, bool) or not isinstance(t, (int, float)) or not now - HR_BACK <= t <= now + 120:
                continue
            number = appfeeds._num(value, low, high)
            if number is None:
                continue
            moment = time.localtime(t)
            day = time.strftime("%Y-%m-%d", moment)
            slot = days.setdefault(day, {"hr": {}, "steps": {}})
            slot["hr" if field == "samples" else "steps"][time.strftime("%H:%M", moment)] = \
                round(number) if field == "samples" else int(number)
    return days


def store_hr(base: Path, days: dict[str, dict], now: float | None = None) -> int:
    """母艦の archive/health-hr/YYYY/MM/DD.json に分ごとに足す（読んでから書く・同じ分は新しい値）。足した日の数"""
    written = 0
    with _hr_lock:
        for day, slot in sorted(days.items()):
            if not slot["hr"] and not slot["steps"]:
                continue
            y, m, d = day.split("-")
            path = Path(base) / HR_DIR / y / m / f"{d}.json"
            try:
                old = json.loads(path.read_text(encoding="utf-8"))
            except FileNotFoundError:
                old = {}
            except (OSError, ValueError):
                continue  # 読めないものは上書きしない
            if not isinstance(old, dict):
                continue
            hr = old.get("hr") if isinstance(old.get("hr"), dict) else {}
            steps = old.get("steps") if isinstance(old.get("steps"), dict) else {}
            hr.update(slot["hr"])
            steps.update(slot["steps"])
            out = {"version": 1, "day": day, "source": "LifeLog", "updated_at": claude.now_iso(now),
                   "hr": dict(sorted(hr.items())), "steps": dict(sorted(steps.items()))}
            _write(path, out)
            written += 1
    return written


# MARK: - 受け口（合言葉は lifelog_pc.py が確かめてから呼ぶ）


def _read_body(handler, limit: int) -> bytes | None:
    try:
        length = int(handler.headers.get("Content-Length") or 0)
    except ValueError:
        length = 0
    if length <= 0 or length > limit:
        handler.discard_body()
        handler.send_json(400 if length <= 0 else 413, {"error": "中身がありません" if length <= 0 else "長すぎます"})
        return None
    return handler.rfile.read(length)


def http_get(handler, path: str, query: str, base: Path) -> None:
    from urllib.parse import parse_qs

    try:
        if path == "/coach":
            handler.send_json(200, read_coach(base))
        elif path == "/tension":
            handler.send_json(200, read_tension(base))
        elif L is None:
            handler.send_json(200, {"available": False, "reason": "会議の相棒が動いていません"})
        else:
            since = (parse_qs(query).get("since") or [None])[0]
            handler.send_json(200, L.view(since))
    except Exception as error:  # noqa: BLE001
        handler.send_json(200, {"available": False, "reason": f"読めませんでした: {type(error).__name__}"})


def http_post(handler, path: str, base: Path, log: Callable[[str], None]) -> None:
    data = _read_body(handler, HR_LIMIT if path == "/health/hr" else STATE_LIMIT)
    if data is None:
        return
    if path == "/health/hr":
        try:
            days = parse_hr(data)
            written = store_hr(base, days)
        except ValueError as error:
            handler.send_json(400, {"error": str(error)})
            return
        except OSError as error:
            handler.send_json(500, {"error": f"母艦に書けませんでした: {type(error).__name__}"})
            return
        count = sum(len(s["hr"]) for s in days.values())
        log(f"心拍の分ごとの記録: {count} 分ぶん（{written} 日）を母艦へ")
        handler.send_json(200, {"ok": True, "days": written, "minutes": count})
        return
    if L is None:
        handler.send_json(503, {"error": "会議の相棒が動いていません"})
        return
    try:
        body = json.loads(data.decode("utf-8"))
        handler.send_json(200, L.set_state(body))
    except (UnicodeDecodeError, ValueError) as error:
        message = str(error) if not isinstance(error, (UnicodeDecodeError, json.JSONDecodeError)) else "中身が JSON ではありません"
        handler.send_json(400, {"error": message})
