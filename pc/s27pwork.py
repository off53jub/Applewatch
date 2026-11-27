"""LifeLog PC: s27（2026-11-25。担当 P）の仕事の画面のための口。取り決め K4・K5（名前と形を変えない）。

母艦（M1・M2）が state/ と reports/ に置くファイルを確かめて返すだけ（0 円・言語モデルなし）。どれもオーナーの鍵（Bearer）で守る。
- K5 GET /work ← state/work_for_app.json（K2・M2 が作る）。中身はそのまま＋"available": true。
  無い・壊れている・大きすぎるときは {"available": false, "reason": …}。features "work"
- K5 GET /work/confirm ← state/work_confirm_for_app.json（K3・M1 が作る）。{"version","generated_at","items":[…]}。
  無ければ {"items": []}。items は形を確かめ、CONFIRM_MAX 件まで（仮 60）。もう答えた id（inbox/app_feedback.jsonl の
  kind work_confirm）は、M1 が作り直すまでのあいだも出さない。features "workconfirm"
- K5 GET /work/ask?q=<文字>（場7）→ {"available": true, "answers": [{"project_id","name","status_line","last_decided","open","link"}]}。
  K2 の案件の名前・顧客、K1（state/work_projects.json）の別名、K2/K1（state/work_people.json）の人の名前・読み・別名、
  チケット番号（K1 state/work_talk_tags.json の tickets と、項目の文の中の番号）、項目の文で引く。言語モデルは使わない。
  全角半角・ひらがなとカタカナ・大文字小文字・空白と区切りの記号をそろえて比べる。答えは ASK_MAX 件まで（仮 5）。
  人に当たったときは、その人の答え（project_id null・その人の宿題・lifelog://work/person/<id>）も 1 件。features "workask"
- K5 GET /work-board（場5）← reports/work-board.html（M2 が作る・家の PC のブラウザ用）。text/html のまま返す。
  外の物を読みに行かないよう Content-Security-Policy を付ける（同じ PC の中の文字と data: の絵だけ）。features "workboard"
- K4 POST /feedback の kind work_confirm・work_edit・work_numbers・work_notice・work_done（appfeeds.parse_feedback から
  parse_feedback を呼ぶ）。母艦の inbox/app_feedback.jsonl に 1 行（今の道）。中身（文）は記録（log.txt）に書かない。
  work_notice（他3・社内のお知らせ）は、アプリの設定で入れるまでアプリが送らない（初めはオフはアプリの側）。家の PC は受けるだけ。

大きいファイル（K2 は 1.5MB まで）を毎回読まないよう、ファイルの更新時刻と大きさで覚えておく（同じなら読み直さない）。
止める切り替えは母艦の state/s27_work_config.json の "s27p"（無くてよい）: {"s27p": {"work": true, "confirm": true,
"ask": true, "board": true}}。書かなければどれもオン（読んで配るだけ・外へは送らない）。
"""

from __future__ import annotations

import datetime
import json
import re
import threading
import unicodedata
import urllib.parse
from pathlib import Path

import appfeeds

WORK = Path("state") / "work_for_app.json"                     # K2
CONFIRM = Path("state") / "work_confirm_for_app.json"          # K3
PROJECTS = Path("state") / "work_projects.json"                # K1
PEOPLE = Path("state") / "work_people.json"                    # K1
TALK_TAGS = Path("state") / "work_talk_tags.json"              # K1
BOARD = Path("reports") / "work-board.html"                    # 場5
CONFIG = Path("state") / "s27_work_config.json"
FEEDBACK_FILE = appfeeds.FEEDBACK_FILE

GETS = ("/work", "/work/confirm", "/work/ask", "/work-board")
FEATURES = ("work", "workconfirm", "workask", "workboard")
SWITCH = {"/work": "work", "/work/confirm": "confirm", "/work/ask": "ask", "/work-board": "board"}

# 大きさ・数の上限（どれも仮）
WORK_READ_MAX = 3 * 1024 * 1024        # K2 は M2 が 1.5MB までに削る。余裕を見て 3MB を超えたら読まない
SMALL_READ_MAX = 2 * 1024 * 1024       # K1・K3
BOARD_READ_MAX = 8 * 1024 * 1024
FEEDBACK_READ_MAX = 4 * 1024 * 1024    # 答えた id を見るのは inbox の後ろの 4MB まで
CONFIRM_MAX = 60
CHOICES_MAX = 12
EVIDENCE_MAX = 8
ASK_MAX = 5
ASK_OPEN_MAX = 5
QUERY_MAX = 100

WORK_KINDS = ("work_confirm", "work_edit", "work_numbers", "work_notice", "work_done")
CONFIRM_KINDS = ("project_merge", "project_kind", "person", "person_org", "team")
ITEM_KINDS = ("homework", "open", "issue", "decided")
EDIT_PROJECT = {"name", "client", "kind"}
EDIT_PERSON = {"name", "team", "role", "org"}
PROJECT_KINDS = ("mine", "other", "side")
ORGS = ("self_company", "client", "vendor", "unknown")
EDIT_ID = re.compile(r"(wp|wm)-[0-9A-Za-z]{1,32}")
VALUE_MAX = {"work_confirm": 200, "work_edit": 2000, "work_numbers": 2000, "work_notice": 4000}  # /feedback は 16KB まで
EDIT_FIELD_MAX = 120
CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
TICKET = re.compile(r"[a-z]{0,10}-?\d{1,8}")
CSP = ("default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:; font-src data:; "
       "base-uri 'none'; form-action 'none'; frame-ancestors 'none'")

_lock = threading.Lock()
_cache: dict = {}   # 道 → (更新時刻 ns, 大きさ, 中身)


# MARK: - 読む（更新時刻で覚えておく）


def _stamp(path: Path) -> tuple[int, int] | None:
    try:
        st = path.stat()
    except OSError:
        return None
    return st.st_mtime_ns, st.st_size


def _cached(path: Path, limit: int, parse):
    """(中身, 失敗の理由)。同じ更新時刻・大きさのあいだは読み直さない。無いときは (None, "missing")"""
    stamp = _stamp(path)
    if stamp is None:
        return None, "missing"
    if stamp[1] > limit:
        return None, "too_big"
    key = str(path)
    # 2026-11-27: 設定（s27_work_config.json）は毎回読む。更新時刻の刻みが粗い所（CI の機械）で、同じ大きさに
    # 書き直すと前の中身が返っていた（s30p の切り替え）。数百バイトなので覚えなくてよい
    if path.name != CONFIG.name:
        with _lock:
            hit = _cache.get(key)
            if hit is not None and hit[0] == stamp:
                return hit[1], hit[2]
    try:
        raw = path.read_bytes()
    except OSError as error:
        return None, f"read:{type(error).__name__}"
    try:
        value, failure = parse(raw), None
    except (UnicodeDecodeError, ValueError) as error:
        value, failure = None, f"parse:{type(error).__name__}"
    with _lock:
        _cache[key] = (stamp, value, failure)
        if len(_cache) > 32:
            _cache.pop(next(iter(_cache)))
    return value, failure


def _json(raw: bytes):
    data = json.loads(raw.decode("utf-8-sig"))
    if not isinstance(data, dict):
        raise ValueError("not an object")
    return data


def _load(base: Path, rel: Path, limit: int = SMALL_READ_MAX) -> tuple[dict | None, str | None]:
    return _cached(Path(base) / rel, limit, _json)


def _reason(label: str, failure: str | None) -> str:
    if failure == "missing":
        return f"母艦の{label}がまだありません"
    if failure == "too_big":
        return f"母艦の{label}が大きすぎます"
    if failure and failure.startswith("read:"):
        return f"母艦の{label}を読めませんでした: {failure[5:]}"
    return f"母艦の{label}の形が違います"


def switch(base: Path | None, name: str) -> bool:
    """state/s27_work_config.json の "s27p" の切り替え（書かなければオン）"""
    if base is None:
        return True
    data, _ = _load(base, CONFIG, 64 * 1024)
    mine = data.get("s27p") if isinstance(data, dict) else None
    value = mine.get(name) if isinstance(mine, dict) else None
    return value if isinstance(value, bool) else True


# MARK: - K5 GET /work


def read_work(base: Path) -> dict:
    data, failure = _load(base, WORK, WORK_READ_MAX)
    if data is None:
        return {"available": False, "reason": _reason("仕事の材料", failure)}
    if appfeeds._int(data.get("version"), 1, 1000) is None or not isinstance(data.get("projects", []), list) \
            or not isinstance(data.get("people", []), list):
        return {"available": False, "reason": _reason("仕事の材料", "shape")}
    return {**data, "available": True}


# MARK: - K5 GET /work/confirm


def _answered(base: Path) -> set[str]:
    """inbox に答えが届いている K3 の id（M1 が作り直すまでのあいだ、出し直さないため）"""
    def parse(raw: bytes) -> set[str]:
        if len(raw) > FEEDBACK_READ_MAX:
            raw = raw[-FEEDBACK_READ_MAX:]
            raw = raw[raw.find(b"\n") + 1:]
        found = set()
        for line in raw.decode("utf-8", errors="replace").splitlines():
            if '"work_confirm"' not in line:
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if isinstance(row, dict) and row.get("kind") == "work_confirm" and isinstance(row.get("id"), str):
                found.add(row["id"])
        return found

    value, _ = _cached(Path(base) / FEEDBACK_FILE, 1 << 40, parse)
    return value or set()


def read_confirm(base: Path) -> dict:
    data, failure = _load(base, CONFIRM)
    if data is None or not isinstance(data.get("items"), list):
        body = {"items": []}
        if failure != "missing":
            body["reason"] = _reason("まとめて 1 回の確かめ", failure or "shape")
        return body
    done = _answered(base)
    items, seen = [], set()
    for x in data["items"]:
        if not isinstance(x, dict):
            continue
        ident = appfeeds._id(x.get("id"))
        title, question = appfeeds._text(x.get("title"), 200), appfeeds._text(x.get("question"), 400)
        if ident is None or ident in seen or ident in done or x.get("kind") not in CONFIRM_KINDS or not title or not question \
                or not isinstance(x.get("choices"), list):
            continue
        choices = []
        for c in x["choices"][:CHOICES_MAX]:
            if isinstance(c, dict) and isinstance(c.get("value"), str) and c["value"].strip() \
                    and len(c["value"]) <= VALUE_MAX["work_confirm"] and appfeeds._text(c.get("label"), 120):
                choices.append({"value": c["value"], "label": appfeeds._text(c.get("label"), 120)})
        if not choices:
            continue
        values = {c["value"] for c in choices}
        default = x.get("default") if x.get("default") in values else None
        seen.add(ident)
        items.append({"id": ident, "kind": x["kind"], "title": title, "question": question, "choices": choices,
                      "evidence": appfeeds._strings(x.get("evidence"), 300, EVIDENCE_MAX), "default": default})
        if len(items) >= CONFIRM_MAX:
            break
    return {"version": appfeeds._version(data), "generated_at": appfeeds._iso(data.get("generated_at")), "items": items}


# MARK: - K5 GET /work/ask（場7）


def norm(value) -> str:
    """全角半角・カタカナ→ひらがな・大文字小文字・空白と区切りの記号をそろえる"""
    if not isinstance(value, str):
        return ""
    text = unicodedata.normalize("NFKC", value).casefold()
    text = "".join(chr(ord(c) - 0x60) if "ァ" <= c <= "ヶ" else c for c in text)
    return re.sub(r"[\s・･/\\\-‐‑–—_()\[\]{}「」『』【】〔〕、。,.:;!?#'\"＃]+", "", text)


def _ticket(value: str) -> str | None:
    """チケット番号らしい問い（#212・212・ABC-12）→ そろえた形（"212"・"abc-12"）"""
    text = unicodedata.normalize("NFKC", value).casefold().strip().lstrip("#").strip()
    return text if TICKET.fullmatch(text) and any(c.isdigit() for c in text) else None


def _ticket_in(text: str, ticket: str) -> bool:
    body = unicodedata.normalize("NFKC", text or "").casefold()
    return re.search(r"(?<![0-9a-z])#?" + re.escape(ticket) + r"(?![0-9])", body) is not None


def _item(x) -> dict | None:
    """K2 の Item の形だけを残す（文の無いものは落とす）"""
    if not isinstance(x, dict) or not isinstance(x.get("text"), str) or not x["text"].strip():
        return None
    keys = ("id", "kind", "text", "project_id", "who", "day", "time", "due", "due_guess", "ball", "age_days", "state",
            "certainty", "src", "link")
    return {k: x.get(k) for k in keys}


def _stamp_key(base: Path) -> tuple:
    return tuple(_stamp(Path(base) / rel) for rel in (WORK, PROJECTS, PEOPLE, TALK_TAGS))


def _index(base: Path) -> dict | None:
    """引くための表（K2・K1 の更新時刻が同じあいだは作り直さない）"""
    key = ("ask-index", str(base))
    stamp = _stamp_key(base)
    with _lock:
        hit = _cache.get(key)
        if hit is not None and hit[0] == stamp:
            return hit[1]
    work = read_work(base)
    if not work.get("available"):
        index = None
    else:
        k1p, _ = _load(base, PROJECTS)
        k1m, _ = _load(base, PEOPLE)
        tags, _ = _load(base, TALK_TAGS, WORK_READ_MAX)
        aliases = {}
        for p in (k1p or {}).get("projects", []) if isinstance((k1p or {}).get("projects"), list) else []:
            if isinstance(p, dict) and isinstance(p.get("id"), str):
                aliases[p["id"]] = [a for a in p.get("aliases", []) if isinstance(a, str)] \
                    if isinstance(p.get("aliases"), list) else []
        projects = []
        for p in work.get("projects") or []:
            if not isinstance(p, dict) or not isinstance(p.get("id"), str) or not isinstance(p.get("name"), str):
                continue
            items, marks = [], set()
            for part in ("items", "timeline"):
                for i in map(_item, p.get(part) if isinstance(p.get(part), list) else []):
                    mark = (i or {}).get("id") or (i or {}).get("text")
                    if i and mark not in marks:
                        marks.add(mark)
                        items.append(i)
            projects.append({"raw": p, "id": p["id"], "name": norm(p["name"]), "client": norm(p.get("client")),
                             "aliases": [norm(a) for a in aliases.get(p["id"], []) if norm(a)], "items": items,
                             "texts": [norm(i["text"]) for i in items]})
        extra = {}
        for m in (k1m or {}).get("people", []) if isinstance((k1m or {}).get("people"), list) else []:
            if isinstance(m, dict) and isinstance(m.get("id"), str):
                names = [m.get("reading")] + (m.get("aliases") if isinstance(m.get("aliases"), list) else [])
                extra[m["id"]] = {"names": [norm(n) for n in names if norm(n)],
                                  "projects": [x for x in m.get("projects", []) if isinstance(x, str)]
                                  if isinstance(m.get("projects"), list) else []}
        people = []
        for m in work.get("people") or []:
            if not isinstance(m, dict) or not isinstance(m.get("id"), str) or not isinstance(m.get("name"), str):
                continue
            more = extra.get(m["id"], {"names": [], "projects": []})
            own = [x for x in m.get("projects", []) if isinstance(x, str)] if isinstance(m.get("projects"), list) else []
            people.append({"raw": m, "id": m["id"], "name": norm(m["name"]), "names": more["names"],
                           "projects": list(dict.fromkeys(own + more["projects"]))})
        tickets = {}
        for t in (tags or {}).get("items", []) if isinstance((tags or {}).get("items"), list) else []:
            if not isinstance(t, dict) or not isinstance(t.get("tickets"), list):
                continue
            for number in t["tickets"]:
                key_ = _ticket(number) if isinstance(number, str) else None
                if key_:
                    tickets.setdefault(key_, set()).update(x for x in t.get("project_ids") or [] if isinstance(x, str))
        index = {"projects": projects, "people": people, "tickets": tickets}
    with _lock:
        _cache[key] = (stamp, index, None)
    return index


def _when(item: dict) -> tuple:
    return (str(item.get("day") or ""), str(item.get("time") or ""))


def _answer(p: dict, matched: list[dict]) -> dict:
    raw = p["raw"]
    decided = [i for i in p["items"] if i.get("kind") == "decided"]
    hits = [i for i in matched if i.get("kind") == "decided"]
    last = max(hits or decided, key=_when) if (hits or decided) else None
    seen, opened = set(), []
    for i in matched + sorted(p["items"], key=_when, reverse=True):
        if i.get("kind") == "decided" or i.get("state") == "done":
            continue
        mark = i.get("id") or i.get("text")
        if mark in seen:
            continue
        seen.add(mark)
        opened.append(i)
        if len(opened) >= ASK_OPEN_MAX:
            break
    return {"project_id": p["id"], "name": appfeeds._text(raw.get("name"), 120),
            "status_line": appfeeds._text(raw.get("status_line"), 300), "last_decided": last, "open": opened,
            "link": "lifelog://work/project/" + urllib.parse.quote(p["id"], safe="-_.")}


def _person_answer(m: dict) -> dict:
    raw = m["raw"]
    last = raw.get("last_talk") if appfeeds._day(raw.get("last_talk")) else None
    status = f"最後に話した日 {last}" if last else "話した記録はまだありません"
    if appfeeds._text(raw.get("role"), 60):
        status = appfeeds._text(raw.get("role"), 60) + "・" + status
    homework = [i for i in map(_item, raw.get("their_homework") or [] if isinstance(raw.get("their_homework"), list)
                                else []) if i and i.get("state") != "done"]
    return {"project_id": None, "name": appfeeds._text(raw.get("name"), 120), "status_line": status, "last_decided": None,
            "open": homework[:ASK_OPEN_MAX], "link": "lifelog://work/person/" + urllib.parse.quote(m["id"], safe="-_.")}


def _score(q: str, name: str, others: list[str], exact: int, head: int, inside: int, other_exact: int,
           other_inside: int) -> int:
    if not q:
        return 0
    if name == q:
        return exact
    if any(o == q for o in others):
        return other_exact
    if len(q) < 2:
        return 0
    if name.startswith(q):
        return head
    if q in name:
        return inside
    if any(q in o for o in others if o):
        return other_inside
    return 0


def ask(base: Path, query: str | None) -> dict:
    text = (query or "").strip()[:QUERY_MAX]
    index = _index(base)
    if index is None:
        return {"available": False, "reason": read_work(base).get("reason", "母艦の仕事の材料がまだありません"),
                "answers": []}
    q = norm(text)
    if not q:
        return {"available": True, "answers": []}
    ticket = _ticket(text)
    scores: dict[str, int] = {}
    matched: dict[str, list[dict]] = {}
    by_id = {p["id"]: p for p in index["projects"]}

    def bump(pid: str, score: int) -> None:
        if pid in by_id and score > scores.get(pid, 0):
            scores[pid] = score

    for p in index["projects"]:
        bump(p["id"], _score(q, p["name"], p["aliases"], 100, 80, 60, 90, 50))
        if p["client"] and (p["client"] == q or (len(q) >= 2 and q in p["client"])):
            bump(p["id"], 40)
        hits = []
        for item, body in zip(p["items"], p["texts"]):
            if _ticket_in(item["text"], ticket) if ticket else (len(q) >= 2 and q in body):
                hits.append(item)
        if hits:
            matched[p["id"]] = sorted(hits, key=_when, reverse=True)
            bump(p["id"], 75 if ticket else 20)
    if ticket:
        for pid in index["tickets"].get(ticket, ()):
            bump(pid, 70)
    persons = []
    for m in index["people"]:
        score = _score(q, m["name"], m["names"], 95, 85, 55, 92, 45)
        if score:
            persons.append((score, m))
            for pid in m["projects"]:
                bump(pid, score - 10)
    ranked = [(s, by_id[pid]["raw"].get("last_moved") or "", "p", pid) for pid, s in scores.items()]
    ranked += [(s, m["raw"].get("last_talk") or "", "m", m["id"]) for s, m in persons]
    ranked.sort(key=lambda r: (r[0], str(r[1])), reverse=True)
    people_by_id = {m["id"]: m for _, m in persons}
    answers = []
    for _, _, kind, ident in ranked[:ASK_MAX]:
        answers.append(_answer(by_id[ident], matched.get(ident, [])) if kind == "p" else _person_answer(people_by_id[ident]))
    return {"available": True, "answers": answers}


# MARK: - K5 GET /work-board（場5）


def _send_html(handler, status: int, data: bytes) -> None:
    handler.send_response(status)
    handler.send_header("Content-Type", "text/html; charset=utf-8")
    handler.send_header("Content-Length", str(len(data)))
    handler.send_header("Cache-Control", "no-store")
    handler.send_header("X-Content-Type-Options", "nosniff")
    handler.send_header("Referrer-Policy", "no-referrer")
    handler.send_header("X-Frame-Options", "DENY")
    handler.send_header("Content-Security-Policy", CSP)
    handler.end_headers()
    handler.wfile.write(data)


def read_board(base: Path) -> tuple[bytes | None, str | None]:
    return _cached(Path(base) / BOARD, BOARD_READ_MAX, lambda raw: raw if raw.strip() else None)


def http_board(handler, base: Path | None) -> None:
    data, failure = read_board(base) if base is not None else (None, "missing")
    if not data:
        reason = _reason("仕事の 1 枚", failure if failure else "missing")
        page = ("<!doctype html><meta charset=\"utf-8\"><title>仕事の 1 枚</title><p>" + reason + "</p>").encode("utf-8")
        _send_html(handler, 404, page)
        return
    _send_html(handler, 200, data)


# MARK: - K4 POST /feedback の kind work_*


def _plain(value, n: int, lines: bool) -> str:
    if not isinstance(value, str):
        return ""
    text = appfeeds._long(value, n + 1) if lines else appfeeds._text(value, n + 1)
    return "" if CONTROL.search(text) else text


def parse_feedback(body: dict) -> dict:
    """POST /feedback の kind work_*（K4）。おかしければ ValueError。day は省けば今日"""
    kind = body.get("kind")
    if kind not in WORK_KINDS:
        raise ValueError("kind は " + "・".join(WORK_KINDS) + " のどれかです")
    day = body.get("day")
    if day is None:
        day = datetime.date.today().isoformat()
    elif appfeeds._day(day) is None:
        raise ValueError("day は YYYY-MM-DD です")
    ident, value = body.get("id"), body.get("value")
    if kind in ("work_numbers", "work_notice"):
        ident = "" if ident is None else ident
        if ident != "" and (kind == "work_notice" or appfeeds._id(ident) is None):
            raise ValueError("id は空か、案件の id です" if kind == "work_numbers" else "id は空です")
        limit = VALUE_MAX[kind]
        text = _plain(value, limit, True)
        if not text or len(text) > limit:
            raise ValueError(f"value は 1〜{limit} 文字の文です")
        return {"kind": kind, "id": ident, "value": text, "day": day}
    if kind == "work_done":
        if appfeeds._id(ident) is None:
            raise ValueError("id は英数字と _ . : - で 64 文字までです")
        if value not in ("done", "undo"):
            raise ValueError("work_done の value は done・undo のどれかです")
        return {"kind": kind, "id": ident, "value": value, "day": day}
    if kind == "work_confirm":
        if appfeeds._id(ident) is None:
            raise ValueError("id は英数字と _ . : - で 64 文字までです")
        text = _plain(value, VALUE_MAX[kind], False)
        if not text or text != value or len(text) > VALUE_MAX[kind]:
            raise ValueError(f"value は 1〜{VALUE_MAX[kind]} 文字の選んだ値です")
        return {"kind": kind, "id": ident, "value": value, "day": day}
    # work_edit: id は wp-… か wm-…・value は直した欄だけの JSON の文字列
    if not isinstance(ident, str) or EDIT_ID.fullmatch(ident) is None:
        raise ValueError("id は wp-… か wm-… です")
    if not isinstance(value, str) or len(value) > VALUE_MAX[kind]:
        raise ValueError(f"value は {VALUE_MAX[kind]} 文字までの JSON の文字列です")
    try:
        fields = json.loads(value)
    except ValueError:
        raise ValueError("value は JSON の文字列です") from None
    allowed = EDIT_PROJECT if ident.startswith("wp-") else EDIT_PERSON
    if not isinstance(fields, dict) or not fields or not set(fields) <= allowed:
        raise ValueError("value で直せる欄は " + "・".join(sorted(allowed)) + " です")
    clean = {}
    for name, x in fields.items():
        if x is None and name in ("client", "team", "role"):
            clean[name] = None
            continue
        text = _plain(x, EDIT_FIELD_MAX, False)
        if not text or len(text) > EDIT_FIELD_MAX:
            raise ValueError(f"{name} は 1〜{EDIT_FIELD_MAX} 文字の文です")
        if (name == "kind" and text not in PROJECT_KINDS) or (name == "org" and text not in ORGS):
            raise ValueError(f"{name} は " + "・".join(PROJECT_KINDS if name == "kind" else ORGS) + " のどれかです")
        clean[name] = text
    return {"kind": kind, "id": ident, "value": json.dumps(clean, ensure_ascii=False, separators=(",", ":")), "day": day}



# MARK: - 受け口


def _empty(path: str, reason: str) -> dict:
    """読めないときの返事（K5 の形のまま）"""
    if path == "/work/confirm":
        return {"items": [], "reason": reason}
    if path == "/work/ask":
        return {"available": False, "reason": reason, "answers": []}
    return {"available": False, "reason": reason}


def http_get(handler, path: str, query: str, base: Path | None) -> None:
    """GET /work・/work/confirm・/work/ask・/work-board（合言葉は lifelog_pc.py が確かめてから）"""
    if base is not None and not Path(base).is_dir():
        base = None
    try:
        if base is not None and not switch(base, SWITCH[path]):
            if path == "/work-board":
                _send_html(handler, 404, "<!doctype html><meta charset=\"utf-8\"><p>止めてあります</p>".encode("utf-8"))
            else:
                handler.send_json(200, _empty(path, "止めてあります"))
            return
        if path == "/work-board":
            http_board(handler, base)
        elif base is None:
            handler.send_json(200, _empty(path, "母艦が見つかりません"))
        elif path == "/work":
            handler.send_json(200, read_work(base))
        elif path == "/work/confirm":
            handler.send_json(200, read_confirm(base))
        else:
            params = urllib.parse.parse_qs(query or "")
            handler.send_json(200, ask(base, (params.get("q") or [""])[0]))
    except Exception as error:  # noqa: BLE001
        handler.send_json(200, _empty(path, f"読めませんでした: {type(error).__name__}"))
