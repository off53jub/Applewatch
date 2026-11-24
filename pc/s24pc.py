"""LifeLog PC: s24（2026-11-24）の家の PC の分をまとめてつなぐ所。担当の案は 急3・急7・当1・減3・減5・当2・当5・当7・当8・当11・当12。

lifelog_pc.py から呼ぶのは start(main)（start_v6 の中。s23pc.start のあと）と FEATURES・POSTS・http_post。
summary.md の「## s24 の数」の節は ops.write_summary が summary_lines(...) で足す。0 円・言語モデルの呼び出しは足さない。
設定の決まり（same_person_ask・promise_push・pc_question_days）は s24rules.py、夜の測りの中身は s24night.py。

- 急3（取り決め C1）: POST /notify/urgent。見出し X-LifeLog-Local が HOME/local-notify-token.txt（起動のときに無ければ
  32 桁の 16 進で作る。記録にも画面にも出さない）と同じときだけ受ける（比べるのは定数時間）。ふだんの合言葉は要らない
  （母艦がこの PC の中から呼ぶため）。体は {"key": str, "title": str, "body": str}（4KB まで）。
  APNs の見える知らせ（kind "urgent"・lifelog.kind "urgent"・lifelog.key）で、使える端末の全部に送る。
  同じ key は 24 時間に 1 回（送れたときだけ覚える。HOME/s24/urgent.json）・1 端末 1 日 8 回まで（apns.LIMITS）。
  アプリの「通知に中身を出さない」（約束の設定の hide_body）がオンなら、文を出さない。
  返事は {"ok": bool, "sent": int, "suppressed": bool, "reason": str}。
    ok … 送れた（sent ≥ 1）か、同じ key をもう 24 時間以内に送ってある（suppressed）。母艦は ok が false なら別の道（LINE）へ
    suppressed … 同じ key の 24 時間・1 日 8 回のどちらかで送らなかった（reason に日本語で）
- 急7（取り決め C2）: GET /watch-route の "watchDirectLast" は watchroute.py。
- 当1（C4）・減5（C5）: s24rules.py の決まりを、quality.py（GET /same-person）・knowme.py と splitcand.py（GET /speaker-split・
  母艦への写し）・promises.py（APNs の kind promise）が読む。確かめ待ち（GET /review-queue）の kind voice_pair・speaker_split は
  ここで抜く（same_person_ask が true なら出す）。
- 減3（C3）: GET /review-queue に家の PC が足した問い（母艦の列に無い id）は、初めて出した日から pc_question_days 日（初めは 3・仮）
  出して閉じる（機械の見立てのまま。答えは要らない）。"expires" はその日（YYYY-MM-DD）より後にしない。
  初めて出した日は HOME/s24/asked.json。閉じた数は quality-daily.json のその日の "pc_questions_closed"（答えのあったものは数えない）。
- 当12: 確かめ待ちの「この声は ○○ さんですか」（kind speaker_line。名前の無い人物N）は、その日の行の多い人物N 上位 5 人のぶんだけ出す
  （行の多い順）。上位は 30 分ごとに記録から数える（HOME/s24/top-people.json）。
- 当2: 同じ人かの点を s-norm に切り替える決まり（仮）: quality-daily.json の "snorm_auc"・"raw_auc"（s23 続10）が 7 晩たまり、
  その 7 晩が毎晩 s-norm ≥ 今 + 0.1、いちばん新しい晩の答えのある組（snorm_pairs）が 20 以上なら、summary.md に「切り替えの候補」の 1 行。
  自動では切り替えない（初めはオフ。切り替えの口は作っていない）。
- 夜（01:00〜05:00 に 1 回・新しい区切りが待っていないとき）: 当7 場面ごとの PLAUD との合い方（3 日前まで）・当5 答えのある組での
  話し手のモデルの測り直し・当8 しきい値を下げた影・当11 言葉の登録の候補（週 1 回）。どれも config.json の "s24_night": false で止まる。

config.json（どれも書かなければ下の既定）:
- "same_person_ask": false・"promise_push": false・"pc_question_days": 3・"s24_night": true（夜の測り）
- "speaker_top": 5（当12 の人数）
"""

from __future__ import annotations

import datetime
import hmac
import json
import os
import re
import secrets
import threading
import time
from pathlib import Path

import jobfirst
import quality
import s24night
import s24rules

FEATURES = ["urgent", "pcqclose"]
POSTS = ("/notify/urgent",)
TOKEN_FILE = "local-notify-token.txt"
TOKEN_HEADER = "X-LifeLog-Local"
TOKEN_RE = re.compile(r"[0-9a-f]{32}")
URGENT_KEY_WINDOW = 86400
URGENT_PER_DAY = 8          # apns.LIMITS の urgent と同じ（1 端末 1 日）
URGENT_BODY_LIMIT = 4096
KEY_MAX, TITLE_MAX, BODY_MAX = 64, 60, 120
HIDDEN_BODY = "開くと中身を見られます"
SPEAKER_TOP = 5
TOP_DAYS = 7
LIGHT_EVERY = 1800.0
TICK = 60.0
FIRST_WAIT = 240.0
SNORM_NIGHTS, SNORM_MARGIN, SNORM_ANSWERS = 7, 0.1, 20    # 当2（仮）
ASKED_KEEP_DAYS = 60
UNNAMED = re.compile(r"人物\d+")


class S:
    main = None
    home: Path | None = None
    thread: threading.Thread | None = None
    lock = threading.Lock()
    next_light = 0.0
    night_day: str | None = None
    token: str | None = None
    last: dict = {}


def _config() -> dict:
    return s24rules.current_config()


def _base() -> Path | None:
    try:
        base = S.main.mothership.home(_config())
        return Path(base) if base is not None and Path(base).is_dir() else None
    except Exception:  # noqa: BLE001
        return None


def _store():
    return getattr(getattr(S.main, "App", None), "records", None)


def _log(text: str) -> None:
    try:
        S.main.log(text)
    except Exception:  # noqa: BLE001
        pass


def _read(path: Path, default=None):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def _write(path: Path, body) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    part = path.with_name(path.name + ".part")
    part.write_text(json.dumps(body, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(part, path)


def folder(home: Path) -> Path:
    return Path(home) / "s24"


# MARK: - つなぐ


def start(main) -> None:
    S.main = main
    S.home = Path(main.HOME)
    s24rules.CONFIG = getattr(main, "load_config", None)
    try:
        S.token = local_token(S.home)
    except OSError as error:
        _log(f"急ぎの知らせの合言葉のファイルを作れませんでした: {type(error).__name__}")
    try:
        import s20feeds

        before = s20feeds.REVIEW_EXTRA

        def merged(body, base, before=before):
            mother_ids = _ids(body)
            out = before(body, base) if before is not None else body
            return shape_review(out, mother_ids, S.home, base, _config(), datetime.date.today())

        s20feeds.REVIEW_EXTRA = merged
    except Exception:  # noqa: BLE001
        pass
    if S.thread is None:
        S.thread = threading.Thread(target=_loop, name="s24", daemon=True)
        S.thread.start()


def _loop() -> None:
    time.sleep(FIRST_WAIT)
    failed_at = 0.0
    while True:
        try:
            tick()
        except Exception as error:  # noqa: BLE001 — 裏の仕事が止まっても、受け付けは続ける
            if time.time() - failed_at > 3600:
                failed_at = time.time()
                _log(f"s24 の見回りでつまずきました: {type(error).__name__}")
        time.sleep(TICK)


def tick(moment: datetime.datetime | None = None) -> dict:
    moment = moment or datetime.datetime.now()
    now = time.time()
    home, config = S.home, _config()
    done: dict = {}
    if home is None:
        return done
    if now >= S.next_light:
        S.next_light = now + LIGHT_EVERY
        done["light"] = light(home, _store(), _base(), config, moment.date())
    day = moment.date().isoformat()
    if 1 <= moment.hour < 5 and S.night_day != day and not jobfirst.busy() and config.get("s24_night") is not False:
        S.night_day = day
        done["night"] = night(home, _store(), _base(), config, moment.date())
    return done


def light(home: Path, store, base: Path | None, config: dict, today: datetime.date) -> dict:
    out: dict = {}
    try:
        out["top"] = update_top_people(home, store, today)
    except Exception as error:  # noqa: BLE001
        out["top"] = type(error).__name__
    try:
        out["closed"] = close_questions(home, base, config, today)
    except Exception as error:  # noqa: BLE001
        out["closed"] = type(error).__name__
    S.last["light"] = out
    return out


# MARK: - 急3 POST /notify/urgent


def local_token(home: Path) -> str:
    """HOME/local-notify-token.txt（32 桁の 16 進）。無い・形が違えば作る（記録には書かない）"""
    path = Path(home) / TOKEN_FILE
    try:
        value = path.read_text(encoding="utf-8").strip().lower()
        if TOKEN_RE.fullmatch(value):
            return value
    except OSError:
        pass
    value = secrets.token_hex(16)
    path.parent.mkdir(parents=True, exist_ok=True)
    part = path.with_name(path.name + ".part")
    part.write_text(value + "\n", encoding="utf-8")
    os.replace(part, path)
    return value


def token_ok(given) -> bool:
    """X-LifeLog-Local がファイルの中身と同じか（定数時間で比べる）"""
    if S.home is None:
        return False
    try:
        expected = S.token or local_token(S.home)
    except OSError:
        return False
    given = str(given or "").strip().lower().encode("utf-8")
    return hmac.compare_digest(given, expected.encode("utf-8"))


def parse_urgent(data: bytes) -> dict:
    """体 → {"key","title","body"}。おかしければ ValueError（文は日本語）"""
    try:
        body = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as error:
        raise ValueError("JSON ではありません") from error
    if not isinstance(body, dict):
        raise ValueError("JSON の形が違います")
    out = {}
    for name, limit in (("key", KEY_MAX), ("title", TITLE_MAX), ("body", BODY_MAX)):
        value = body.get(name)
        if not isinstance(value, str):
            raise ValueError(f"{name} は文字です")
        value = " ".join(value.split())
        if name in ("key", "title") and not value:
            raise ValueError(f"{name} が空です")
        out[name] = value[:limit]
    return out


def _urgent_state(home: Path) -> dict:
    data = _read(folder(home) / "urgent.json", {}) or {}
    keys = data.get("keys") if isinstance(data.get("keys"), dict) else {}
    days = data.get("days") if isinstance(data.get("days"), dict) else {}
    return {"keys": keys, "days": days}


def _hide_body() -> bool:
    try:
        import promises

        return bool(((promises.W.settings() if promises.W is not None else None) or {}).get("hide_body"))
    except Exception:  # noqa: BLE001
        return False


def send_urgent(request: dict, pusher, now: float | None = None) -> dict:
    """急ぎの知らせを送る（pusher は apns.Pusher か作り物）。返事の形は取り決め C1"""
    now = time.time() if now is None else now
    home = S.home
    key = request["key"]
    day = datetime.date.fromtimestamp(now).isoformat()
    with S.lock:
        state = _urgent_state(home)
        last = state["keys"].get(key)
        if isinstance(last, (int, float)) and now - float(last) < URGENT_KEY_WINDOW:
            _count(state, day, "suppressed")
            _write(folder(home) / "urgent.json", state)
            return {"ok": True, "sent": 0, "suppressed": True, "reason": "同じ key は 24 時間に 1 回までです（もう送ってあります）"}
    if pusher is None or not pusher.ready():
        return {"ok": False, "sent": 0, "suppressed": False, "reason": "知らせを送る用意がありません（鍵・チーム・端末）"}
    targets = [d for d in list(pusher.devices) if pusher.usable(d)]
    if not targets:
        return {"ok": False, "sent": 0, "suppressed": False, "reason": "知らせを受けられる端末がありません"}
    allowed = [d for d in targets if pusher.allowed(d, "urgent", now)]
    if not allowed:
        with S.lock:
            state = _urgent_state(home)
            _count(state, day, "suppressed")
            _write(folder(home) / "urgent.json", state)
        return {"ok": False, "sent": 0, "suppressed": True, "reason": f"1 端末 1 日 {URGENT_PER_DAY} 回までです"}
    alert = {"title": request["title"], "body": HIDDEN_BODY if _hide_body() else request["body"]}
    results = pusher.send("urgent", allowed, alert=alert, extra={"key": key})
    sent = sum(1 for r in results if r.get("ok"))
    with S.lock:
        state = _urgent_state(home)
        if sent:
            state["keys"][key] = now
        state["keys"] = {k: v for k, v in state["keys"].items()
                         if isinstance(v, (int, float)) and now - float(v) < 7 * 86400}
        _count(state, day, "sent" if sent else "failed")
        _write(folder(home) / "urgent.json", state)
    if sent:
        try:
            quality.add_today({"urgent_sent": sent}, home)
        except Exception:  # noqa: BLE001
            pass
    reason = "" if sent else next((str(r.get("reason") or r.get("status") or "") for r in results if not r.get("ok")), "送れませんでした")
    return {"ok": sent > 0, "sent": sent, "suppressed": False, "reason": reason}


def _count(state: dict, day: str, name: str) -> None:
    entry = state["days"].setdefault(day, {})
    entry[name] = int(entry.get(name, 0)) + 1
    for old in sorted(state["days"])[:-14]:
        state["days"].pop(old, None)


def _pusher():
    try:
        import ops

        return ops.O.pusher if ops.O.started else None
    except Exception:  # noqa: BLE001
        return None


def http_post(handler, path: str) -> None:
    """POST /notify/urgent（ふだんの合言葉は使わない。X-LifeLog-Local で確かめる）"""
    if not token_ok(handler.headers.get(TOKEN_HEADER)):
        _log(f"急ぎの知らせ: 合言葉の違う接続を断りました: {handler.client_address[0]}")
        if hasattr(handler, "discard_body"):
            handler.discard_body()
        handler.send_json(401, {"ok": False, "sent": 0, "suppressed": False, "reason": "合言葉が違います"})
        return
    try:
        length = int(handler.headers.get("Content-Length") or 0)
    except ValueError:
        length = 0
    if length <= 0 or length > URGENT_BODY_LIMIT:
        if hasattr(handler, "discard_body"):
            handler.discard_body()
        handler.send_json(400 if length <= 0 else 413, {"ok": False, "sent": 0, "suppressed": False,
                                                        "reason": "中身がありません" if length <= 0 else "長すぎます"})
        return
    try:
        request = parse_urgent(handler.rfile.read(length))
    except ValueError as error:
        handler.send_json(400, {"ok": False, "sent": 0, "suppressed": False, "reason": str(error)})
        return
    try:
        answer = send_urgent(request, _pusher())
    except Exception as error:  # noqa: BLE001 — 何があっても受け付けは続ける
        answer = {"ok": False, "sent": 0, "suppressed": False, "reason": f"送れませんでした: {type(error).__name__}"}
    # 記録には数だけ（題・文・key は書かない）
    _log(f"急ぎの知らせ（{handler.client_address[0]} から）: 送った {answer['sent']}"
         + ("・抑えた" if answer["suppressed"] else "") + ("" if answer["ok"] else "・送れず"))
    handler.send_json(200, answer)


# MARK: - 確かめ待ち（当1・減3・当12）


def _ids(body) -> set:
    if not isinstance(body, dict):
        return set()
    return {i.get("id") for i in body.get("items") or [] if isinstance(i, dict)}


def _asked(home: Path) -> dict:
    data = _read(folder(home) / "asked.json", {}) or {}
    return {"first": data.get("first") if isinstance(data.get("first"), dict) else {},
            "closed": data.get("closed") if isinstance(data.get("closed"), dict) else {}}


def _day(value) -> datetime.date | None:
    try:
        return datetime.date.fromisoformat(str(value)[:10])
    except ValueError:
        return None


def shape_review(body, mother_ids: set, home: Path | None, base, config: dict, today: datetime.date) -> dict:
    """GET /review-queue の答えのうち、家の PC が足した問い（mother_ids に無い id）を、当1・減3・当12 の決まりで並べ直す"""
    if home is None or not isinstance(body, dict) or not isinstance(body.get("items"), list):
        return body
    ask = s24rules.same_person_ask(config)
    days = s24rules.question_days(config)
    top = _read(folder(home) / "top-people.json", {}) or {}
    limit = config.get("speaker_top") if isinstance(config.get("speaker_top"), int) else SPEAKER_TOP
    kept, held = [], {"same": 0, "closed": 0, "top": 0}
    with S.lock:
        state = _asked(home)
        changed = False
        for item in body["items"]:
            if not isinstance(item, dict) or item.get("id") in mother_ids:
                kept.append(item)
                continue
            ident = str(item.get("id") or "")
            if item.get("kind") in s24rules.SAME_KINDS and not ask:
                held["same"] += 1
                continue
            if item.get("kind") == "speaker_line" and not _in_top(item, top, limit):
                held["top"] += 1
                continue
            first = _day(state["first"].get(ident))
            if first is None:
                first = today
                state["first"][ident] = today.isoformat()
                changed = True
            last_day = first + datetime.timedelta(days=days - 1)
            if today > last_day:
                held["closed"] += 1
                continue
            given = _day(item.get("expires"))
            item = {**item, "expires": min(given, last_day).isoformat() if given else last_day.isoformat()}
            kept.append(item)
        if changed:
            _write(folder(home) / "asked.json", state)
    # 当12: 名前の無い人の問いは行の多い順に
    pc = [i for i in kept if isinstance(i, dict) and i.get("id") not in mother_ids and i.get("kind") == "speaker_line"]
    if pc:
        order = {id(i): -_lines_of(i, top) for i in pc}
        ranked = iter(sorted(pc, key=lambda i: order[id(i)]))
        kept = [next(ranked) if (isinstance(i, dict) and id(i) in order) else i for i in kept]
    out = {**body, "items": kept}
    if any(held.values()):
        out["pc_held"] = held
    return out


def _person(item: dict) -> str | None:
    person = str(item.get("person") or "")
    return person if UNNAMED.fullmatch(person) else None


def _in_top(item: dict, top: dict, limit: int) -> bool:
    person = _person(item)
    if person is None:
        return True     # 名前の無い人の問いでなければ、ここでは絞らない
    ref = ((item.get("evidence") or [{}])[0] or {}).get("ref") if isinstance(item.get("evidence"), list) else None
    day = str(ref or "")[:10]
    entry = top.get(day)
    if not isinstance(entry, dict):
        return True     # まだ数えていない日は絞らない
    return person in (entry.get("top") or [])[:limit]


def _lines_of(item: dict, top: dict) -> int:
    person = _person(item)
    ref = ((item.get("evidence") or [{}])[0] or {}).get("ref") if isinstance(item.get("evidence"), list) else None
    entry = top.get(str(ref or "")[:10]) or {}
    return int((entry.get("counts") or {}).get(person or "", 0))


def top_people(parsed: dict | None) -> dict:
    """その日の名前の無い人物N の行の数（テレビなどの声は数えない）と、多い順の名前"""
    counts: dict[str, int] = {}
    for conversation in (parsed or {}).get("conversations") or []:
        if not isinstance(conversation, dict) or conversation.get("media"):
            continue
        for line in conversation.get("lines") or []:
            name = str(line.get("speaker") or "")
            if line.get("media") is None and UNNAMED.fullmatch(name):
                counts[name] = counts.get(name, 0) + 1
    ranked = sorted(counts, key=lambda k: (-counts[k], k))
    return {"top": ranked[:SPEAKER_TOP * 2], "counts": {k: counts[k] for k in ranked[:SPEAKER_TOP * 4]}}


def update_top_people(home: Path, store, today: datetime.date) -> int:
    """直近 TOP_DAYS 日の上位を HOME/s24/top-people.json に（記録のファイルが変わった日だけ数え直す）"""
    if store is None:
        return 0
    path = folder(home) / "top-people.json"
    body = _read(path, {}) or {}
    redone = 0
    for back in range(TOP_DAYS):
        day = (today - datetime.timedelta(days=back)).isoformat()
        try:
            stamp = store.path(day).stat().st_mtime
        except (OSError, AttributeError):
            continue
        if isinstance(body.get(day), dict) and body[day].get("stamp") == stamp:
            continue
        body[day] = {**top_people(store.day(day)), "stamp": stamp}
        redone += 1
    limit = (today - datetime.timedelta(days=TOP_DAYS)).isoformat()
    body = {k: v for k, v in body.items() if k >= limit}
    if redone:
        _write(path, body)
    return redone


def close_questions(home: Path, base: Path | None, config: dict, today: datetime.date) -> int:
    """減3: 出してから pc_question_days 日たった問いを閉じた数に数える（答えのあったものは数えない）。今日閉じた数"""
    days = s24rules.question_days(config)
    try:
        import s22feeds

        answered = s22feeds.answered_ids(base)
    except Exception:  # noqa: BLE001
        answered = set()
    with S.lock:
        state = _asked(home)
        closed_now = 0
        for ident, first in list(state["first"].items()):
            start = _day(first)
            if start is None:
                state["first"].pop(ident, None)
                continue
            if ident in state["closed"] or ident in answered:
                continue
            if today > start + datetime.timedelta(days=days - 1):
                state["closed"][ident] = today.isoformat()
                closed_now += 1
        limit = (today - datetime.timedelta(days=ASKED_KEEP_DAYS)).isoformat()
        state["first"] = {k: v for k, v in state["first"].items() if str(v) >= limit}
        state["closed"] = {k: v for k, v in state["closed"].items() if str(v) >= limit}
        if closed_now:
            _write(folder(home) / "asked.json", state)
    today_count = sum(1 for v in state["closed"].values() if v == today.isoformat())
    if closed_now:
        quality.update_day(home, today.isoformat(), {"pc_questions_closed": today_count})
    return closed_now


# MARK: - 夜


def night(home: Path, store, base: Path | None, config: dict, today: datetime.date) -> dict:
    out: dict = {}
    for back in (1, 2, 3):   # 当7: PLAUD は遅れて届くので 3 日前まで数え直す
        day = (today - datetime.timedelta(days=back)).isoformat()
        try:
            got = s24night.scene_match(home, base, day) if base is not None else None
            if got is not None:
                quality.update_day(home, day, {"plaud_match_scene": got})
            out[f"scene {day}"] = None if got is None else len(got)
        except Exception as error:  # noqa: BLE001
            out[f"scene {day}"] = type(error).__name__
    yesterday = (today - datetime.timedelta(days=1)).isoformat()
    try:
        got = s24night.measure_speakers(home, base, (lambda d: store.day(d)) if store is not None else (lambda d: None), config)
        quality.update_day(home, yesterday, {"speaker_answers": _speaker_summary(got)})
        _write(folder(home) / "speaker-answers.json", {"generated_at": datetime.datetime.now().isoformat(timespec="seconds"),
                                                      "note": "s24 当5（数だけ・切り替えていない）", **got})
        out["speakers"] = got.get("pairs")
    except Exception as error:  # noqa: BLE001
        out["speakers"] = type(error).__name__
    try:
        model = Path(home) / "vad" / "silero_vad.onnx"
        if model.is_file():
            path = folder(home) / "vad-shadow.json"
            state = _read(path, {}) or {}
            info = s24night.measure_vad(home, base, model, state, today)
            state["total"] = s24night.vad_total(state)
            state["generated_at"] = datetime.datetime.now().isoformat(timespec="seconds")
            state["note"] = "s24 当8（仮）。しきい値を下げた影。文字にはしていない・切り替えていない"
            _write(path, state)
            out["vad"] = info.get("added")
        else:
            out["vad"] = "Silero VAD のファイルが無い"
    except Exception as error:  # noqa: BLE001
        out["vad"] = type(error).__name__
    try:
        if s24night.vocab_due(home):
            body = s24night.vocab_candidates(home, base, today)
            _write(folder(home) / "vocab-candidates.json", body)
            if base is not None:
                _write(Path(base) / "inbox" / "asr-learned" / "plaud_vocab_candidates.json", body)
            out["vocab"] = len(body["items"])
    except Exception as error:  # noqa: BLE001
        out["vocab"] = type(error).__name__
    _log("s24 の夜の数: " + "・".join(f"{k} {v}" for k, v in out.items()))
    S.last["night"] = out
    return out


def _speaker_summary(got: dict) -> dict:
    models = got.get("models") or {}
    now = models.get("campplus") or {}
    return {"pairs": got.get("pairs"), "same": got.get("same"), "self_pairs": got.get("self_pairs"),
            "auc_now": now.get("auc_raw"), "auc_now_snorm": now.get("auc_snorm"),
            "others": {k: {"auc": v.get("auc_raw"), "auc_snorm": v.get("auc_snorm")} for k, v in models.items() if k != "campplus"}}


# MARK: - 当2


def snorm_rule(daily: dict, today: datetime.date) -> dict:
    """{"nights","good","answers","candidate"}（直近 14 日のうち、s-norm と今の点の AUC が両方ある晩の新しい 7 晩で見る）"""
    rows = []
    for back in range(14, 0, -1):
        day = (today - datetime.timedelta(days=back)).isoformat()
        entry = daily.get(day) or {}
        sn, raw = entry.get("snorm_auc"), entry.get("raw_auc")
        if isinstance(sn, (int, float)) and isinstance(raw, (int, float)):
            rows.append((day, float(sn), float(raw), int(entry.get("snorm_pairs") or 0)))
    last = rows[-SNORM_NIGHTS:]
    good = sum(1 for _, sn, raw, _ in last if sn >= raw + SNORM_MARGIN)
    answers = last[-1][3] if last else 0
    candidate = len(last) >= SNORM_NIGHTS and good == len(last) and answers >= SNORM_ANSWERS
    return {"nights": len(last), "good": good, "answers": answers, "candidate": candidate,
            "snorm": last[-1][1] if last else None, "raw": last[-1][2] if last else None}


# MARK: - summary.md


def summary_lines(diag_store=None, now: float | None = None) -> tuple[list[str], list[str]]:
    """(気になる所の行, 「## s24 の数」の節の行)。ops.write_summary が呼ぶ"""
    home = S.home
    if home is None:
        return [], []
    today = datetime.date.fromtimestamp(now or time.time())
    config = _config()
    daily = quality.read_daily(home)["days"]
    lines: list[str] = []
    worries: list[str] = []
    week = [(today - datetime.timedelta(days=i)).isoformat() for i in range(7)][::-1]

    def urgent_line():
        state = _urgent_state(home)
        sent = sum(int((state["days"].get(d) or {}).get("sent", 0)) for d in week)
        held = sum(int((state["days"].get(d) or {}).get("suppressed", 0)) for d in week)
        has = (Path(home) / TOKEN_FILE).is_file()
        return (f"急ぎの知らせ（POST /notify/urgent・急3）: 合言葉のファイル {'あり' if has else 'まだ無い'}・7 日で送った {sent} 回・"
                f"抑えた {held} 回（同じ key は 24 時間に 1 回・1 端末 1 日 {URGENT_PER_DAY} 回まで）")

    def direct_line():
        import watchroute

        last = watchroute.last_direct()
        if last is None:
            return "時計の外の道で最後に預かった時刻（watchDirectLast・急7）: まだありません"
        minutes = (time.time() - last) / 60
        return f"時計の外の道で最後に預かった時刻（watchDirectLast・急7）: {watchroute.iso_local(last)}（{minutes:.0f} 分前）"

    def switches_line():
        ask = s24rules.same_person_ask(config)
        push = s24rules.promise_push(config)
        ask_text = "出している" if ask else '止めている（"same_person_ask": true で戻す）'
        push_text = "送っている" if push else '止めている（"promise_push": true で戻す。台帳は続ける）'
        return f"「同じ人か」の問い（当1）: {ask_text}・約束の知らせ（減5）: {push_text}"

    def closed_line():
        days = s24rules.question_days(config)
        state = _asked(home)
        open_now = sum(1 for k, v in state["first"].items() if k not in state["closed"]
                       and (_day(v) or today) + datetime.timedelta(days=days - 1) >= today)
        per = [f"{d[5:]} {(daily.get(d) or {}).get('pc_questions_closed', 0)}" for d in week]
        return (f"家の PC の問いを {days} 日（仮）で閉じた数（減3。答えの無いまま機械の見立てのまま）: " + "・".join(per)
                + f"／いま出している {open_now}")

    def snorm_line():
        rule = snorm_rule(daily, today)
        if rule["candidate"]:
            return (f"同じ人かの点を s-norm に切り替える候補です（当2・仮の決まり: {SNORM_NIGHTS} 晩とも s-norm ≥ 今 + {SNORM_MARGIN}・"
                    f"答え {rule['answers']} ≥ {SNORM_ANSWERS}）。自動では切り替えません")
        return (f"同じ人かの点の切り替え（当2・仮の決まり）: まだ候補ではありません（AUC のそろった晩 {rule['nights']}/{SNORM_NIGHTS}・"
                f"s-norm ≥ 今 + {SNORM_MARGIN} の晩 {rule['good']}・答え {rule['answers']}/{SNORM_ANSWERS}）")

    def speaker_line():
        rows = [(d, (daily.get(d) or {}).get("speaker_answers")) for d in week]
        rows = [(d, e) for d, e in rows if isinstance(e, dict)]
        if not rows:
            return "答えのある組での話し手のモデルの測り直し（当5）: まだ（01:00〜05:00 に測ります）"
        d, e = rows[-1]
        fmt = lambda v: "—" if v is None else f"{v:.2f}"  # noqa: E731
        others = "・".join(f"{k} {fmt(v.get('auc'))}" for k, v in (e.get("others") or {}).items())
        return (f"答えのある組での話し手のモデルの測り直し（当5・{d[5:]}）: 組 {e.get('pairs')}（同じ {e.get('same')}）・"
                f"登録の声の組 {e.get('self_pairs')}・今の AUC {fmt(e.get('auc_now'))}（s-norm {fmt(e.get('auc_now_snorm'))}）"
                + (f"・ほかのモデル {others}" if others else ""))

    def scene_line():
        by_day = {d: e.get("plaud_match_scene") for d, e in daily.items()
                  if isinstance(e, dict) and isinstance(e.get("plaud_match_scene"), dict) and d >= (today - datetime.timedelta(days=14)).isoformat()}
        if not by_day:
            return None
        total = s24night.scene_total(by_day)
        order = lambda kv: s24night.SCENES.index(kv[0]) if kv[0] in s24night.SCENES else 99  # noqa: E731
        parts = []
        for k, v in sorted(total.items(), key=order):
            rate = "—" if v["match"] is None else format(v["match"], ".0%")
            parts.append(f"{s24night.SCENE_LABEL.get(k, k)} {rate}（{v['lines']} 行）")
        return "場面ごとの PLAUD との合い方（当7・14 日・仮）: " + "・".join(parts)

    def vad_line():
        body = _read(folder(home) / "vad-shadow.json", None)
        if not isinstance(body, dict) or not body.get("total"):
            return None
        low = (body["total"].get("low") or {})
        normal = (body["total"].get("normal") or {})
        def part(t, th):
            row = t.get(th) or {}
            return f"{th}: 声 +{row.get('new_s', 0):.0f} 秒・拾える字 {row.get('new_plaud_chars', 0)}・ごみ {row.get('new_empty_s', 0):.0f} 秒"
        return (f"声なしと判定の影（当8・仮・切り替えていない）: 声なし側 {low.get('chunks', 0)} 区切り（PLAUD あり {low.get('plaud_chunks', 0)}）"
                f" {part(low, '0.35')}／{part(low, '0.2')}。ふだんの区切り {normal.get('chunks', 0)}: {part(normal, '0.35')}")

    def vocab_line():
        body = _read(folder(home) / "vocab-candidates.json", None)
        if not isinstance(body, dict):
            return None
        return (f"言葉の登録の候補（当11・{body.get('week')}・仮）: {len(body.get('items') or [])} 語"
                f"（PLAUD と合わない組 {body.get('pairs_seen', 0)} から。母艦 inbox/asr-learned/plaud_vocab_candidates.json）")

    for name, make in (("urgent", urgent_line), ("direct", direct_line), ("switches", switches_line), ("closed", closed_line),
                       ("snorm", snorm_line), ("speaker", speaker_line), ("scene", scene_line), ("vad", vad_line),
                       ("vocab", vocab_line)):
        try:
            text = make()
            if text:
                lines.append(f"- {text}")
        except Exception as error:  # noqa: BLE001 — 1 つ書けなくても、ほかは書く
            lines.append(f"- （{name} を数えられませんでした: {type(error).__name__}）")
    try:
        if snorm_rule(daily, today)["candidate"]:
            worries.append("- 同じ人かの点を s-norm に切り替える候補になりました（当2。切り替えるかは本人。自動では切り替えません）")
    except Exception:  # noqa: BLE001
        pass
    return worries, lines
