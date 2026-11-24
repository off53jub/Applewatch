"""LifeLog PC: s25（2026-11-24。担当 P）の家の PC の分をまとめてつなぐ所。名前の頭は s25p。

lifelog_pc.py から呼ぶのは start(main)（start_v6 の中。s24pc.start のあと）と FEATURES・GETS・POSTS・http_get・http_post。
summary.md の「## s25 の数」の節は ops.write_summary が summary_lines(...) で足す。watchroute.py は POST /line/hook を s25pline へ。

担当の案と、初めはオンかオフか（config.json。書かなければ下の既定）:
- K1 GET /line-tasks・K2 GET /drafts・K3 POST /line/share・K7 GET /whisper-now（s25pfeeds.py）。K7 は "whisper_now": true で（初めはオフ）
- K4 POST /line/hook（s25pline.py。返信だけ。初めはオン＝URL が入るまで何も来ない）
- K6 1 日 1 回の静かな試し（s25pnight.ping_tick。"s25p_ping"。初めはオン）
- 連16・早1・早2・早3・大3・大9 の材料（s25pnight.py。数と候補だけ。早2 の間引きは "s25p_night_thin"。初めはオン・仮）
- 早4: 下書き（GET /jobs/<名前> の "draft"）はもう返している。会話のまとめはアプリが作るので、PC は下書きまでの時間を早1 の表に出すだけ
- 大4（s25ptrain.py）: PLAUD を先生にした材料（"s25p_teacher"。初めはオン）と、1 回だけの学び直し（"s25p_train_once"。初めはオン・
  入れ替えはしない＝候補として置くだけ）
- 大9: 同じ人かの点を s-norm に切り替える口（"s25p_snorm_switch": true で、s24 当2 の決まりで候補になったときだけ。
  "s25p_snorm_force": true なら候補でなくても。初めはオフ）
- 活1（s25pcheck.py）: "s25p_precheck": true で（初めはオフ）
"""

from __future__ import annotations

import datetime
import json
import threading
import time
from pathlib import Path

import jobfirst
import s25pcheck
import s25pfeeds
import s25pline
import s25pnight
import s25ptrain

GETS = ("/line-tasks", "/drafts", "/whisper-now")
POSTS = ("/line/share", "/mother-search")
LIGHT_EVERY = 1800.0
TICK = 60.0
FIRST_WAIT = 180.0


class S:
    main = None
    home: Path | None = None
    thread: threading.Thread | None = None
    next_light = 0.0
    night_day: str | None = None
    teacher_day: str | None = None
    last: dict = {}
    wrapped: list = []


def _config() -> dict:
    try:
        return (S.main.load_config() if S.main is not None else {}) or {}
    except Exception:  # noqa: BLE001
        return {}


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


def features(config: dict | None = None) -> list[str]:
    config = _config() if config is None else config
    out = ["linetasks", "drafts", "lineshare", "linehook", "ping", "mothersearch"]
    if config.get("whisper_now") is True:
        out.append("whispernow")
    return out


FEATURES = ["linetasks", "drafts", "lineshare", "linehook", "ping", "mothersearch"]


# MARK: - つなぐ


def start(main) -> None:
    S.main = main
    S.home = Path(main.HOME)
    S.wrapped = s25pnight.install(S.home, _config)
    try:
        import s20feeds

        before = s20feeds.REVIEW_EXTRA

        def merged(body, base, before=before):
            out = before(body, base) if before is not None else body
            return s25pcheck.drop_closed(out, S.home)

        s20feeds.REVIEW_EXTRA = merged
    except Exception:  # noqa: BLE001
        pass
    try:  # 大9: s-norm に切り替える口（初めはオフ）
        import s22voice

        original = s22voice.adjust_same_person
        if not getattr(original, "s25p_wrapped", False):
            def adjusted(home, body, config=None, original=original):
                return snorm_switch(original(home, body, config), _config())

            adjusted.s25p_wrapped = True  # type: ignore[attr-defined]
            s22voice.adjust_same_person = adjusted
    except Exception:  # noqa: BLE001
        pass
    if S.thread is None:
        S.thread = threading.Thread(target=_loop, name="s25p", daemon=True)
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
                _log(f"s25 の見回りでつまずきました: {type(error).__name__}")
        time.sleep(TICK)


def _pusher():
    try:
        import ops

        return ops.O.pusher if ops.O.started else None
    except Exception:  # noqa: BLE001
        return None


def hook_trainer() -> bool:
    """大4: 学び直しの見回りに「この版で 1 回だけの時間帯」を渡す"""
    try:
        import ops

        trainer = ops.O.trainer if ops.O.started else None
    except Exception:  # noqa: BLE001
        trainer = None
    if trainer is None or getattr(trainer, "once", "x") is not None:
        return False
    home = S.home
    build = str(getattr(S.main, "BUILD", "0"))
    trainer.once = lambda now: s25ptrain.once_window(home, _config(), now, build)
    trainer.on_once = lambda result: s25ptrain.once_finished(home, result)
    return True


def tick(moment: datetime.datetime | None = None) -> dict:
    moment = moment or datetime.datetime.now()
    now = time.time()
    home, config = S.home, _config()
    done: dict = {}
    if home is None:
        return done
    hook_trainer()
    try:
        got = s25pnight.ping_tick(home, _pusher(), config, moment)
        if got:
            done["ping"] = got
            _log("静かな試し（ping）: " + "・".join(f"{k} {v}" for k, v in got.items()))
    except Exception as error:  # noqa: BLE001
        done["ping"] = type(error).__name__
    if now >= S.next_light:
        S.next_light = now + LIGHT_EVERY
        done["light"] = light(home, _store(), _base(), config, moment.date())
    day = moment.date().isoformat()
    busy = jobfirst.busy()
    if 0 <= moment.hour < 5 and S.teacher_day != day and not busy:
        S.teacher_day = day
        done["teacher"] = teacher_night(home, _base(), config, moment.date())
    if 1 <= moment.hour < 5 and S.night_day != day and not busy:
        S.night_day = day
        done["night"] = s25p_night(home, _store(), _base(), config, moment.date())
    return done


def light(home: Path, store, base: Path | None, config: dict, today: datetime.date) -> dict:
    out: dict = {}
    for name, work in (("stages", lambda: s25pnight.update_stages(home, today)),
                       ("partner", lambda: len(s25pnight.partner_update(home, store, today))),
                       ("precheck", lambda: s25pcheck.run(home, store, config, today))):
        try:
            out[name] = work()
        except Exception as error:  # noqa: BLE001
            out[name] = type(error).__name__
    S.last["light"] = out
    return out


def teacher_night(home: Path, base: Path | None, config: dict, today: datetime.date) -> dict:
    started = time.time()
    try:
        got = s25ptrain.teacher_samples(S.main, home, base, today, config, deadline=started + 3600)
    except Exception as error:  # noqa: BLE001
        got = {"error": type(error).__name__}
    try:
        s25pnight.record_time(home, "s25p_train", time.time() - started, time.time())
    except OSError:
        pass
    _log("PLAUD を先生にした材料（大4・仮）: " + "・".join(f"{k} {v}" for k, v in got.items()))
    S.last["teacher"] = got
    return got


def _s25p_night_body(home: Path, store, base: Path | None, config: dict, today: datetime.date) -> dict:
    out: dict = {}
    if base is None:
        return {"base": "母艦が見つかりません"}
    for name, work in (("mic", lambda: s25pnight.mic_nightly(home, base, today)),
                       ("calls", lambda: s25pnight.calls_nightly(home, base, store, today))):
        try:
            out[name] = work()
        except Exception as error:  # noqa: BLE001
            out[name] = type(error).__name__
    _log("s25 の夜の数: " + "・".join(f"{k} {v}" for k, v in out.items()))
    return out


s25p_night = s25pnight.timed("s25p_mic", _s25p_night_body)


# MARK: - 大9 s-norm の口


def snorm_switch(body, config: dict, today: datetime.date | None = None):
    """"s25p_snorm_switch" が true で、s24 当2 の決まりで候補（か "s25p_snorm_force"）なら、組の score を s-norm にする
    （今までの点は score_raw に残す。s-norm が無い組はそのまま）"""
    if not isinstance(body, dict) or config.get("s25p_snorm_switch") is not True:
        return body
    if config.get("s25p_snorm_force") is not True:
        try:
            import quality
            import s24pc

            if not s24pc.snorm_rule(quality.read_daily(S.home)["days"], today or datetime.date.today())["candidate"]:
                return body
        except Exception:  # noqa: BLE001
            return body

    def swap(group):
        if isinstance(group, dict) and isinstance(group.get("snorm"), (int, float)):
            return {**group, "score_raw": group.get("score"), "score": group["snorm"], "score_kind": "snorm"}
        return group

    for entry in body.get("days") or []:
        if isinstance(entry, dict) and isinstance(entry.get("groups"), list):
            entry["groups"] = [swap(g) for g in entry["groups"]]
    for key in ("across", "maybe"):
        if isinstance(body.get(key), list):
            body[key] = [swap(g) for g in body[key]]
    body["score_kind"] = "snorm"
    return body


# MARK: - 受け口


def http_get(handler, path: str) -> None:
    """GET /line-tasks・/drafts・/whisper-now（合言葉は lifelog_pc.py が確かめてから）"""
    try:
        if path == "/whisper-now":
            handler.send_json(200, s25pfeeds.whisper_now(_store(), _config()))
            return
        base = _base()
        if base is None:
            handler.send_json(200, {"available": False, "reason": "母艦が見つかりません"})
            return
        reader = s25pfeeds.read_line_tasks if path == "/line-tasks" else s25pfeeds.read_drafts
        handler.send_json(200, reader(base))
    except Exception as error:  # noqa: BLE001
        handler.send_json(200, {"available": False, "reason": f"読めませんでした: {type(error).__name__}"})


def http_post(handler, path: str) -> None:
    """POST /line/share・/mother-search（合言葉は lifelog_pc.py が確かめてから）"""
    if path == "/mother-search":
        http_post_search(handler)
        return
    s25pfeeds.http_post_share(handler, S.home, _log)


# MARK: - K8（活5・活7）: POST /mother-search（Claude を通さない、母艦の文の意味の検索。まとめ役が 2026-11-25 に足した）

SEARCH_K_MAX = 30


def search_request(data: bytes, today: datetime.date | None = None) -> dict:
    """{"query", "k"?, "person"?, "sources"?, "days"?} を確かめる。おかしければ ValueError"""
    try:
        body = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise ValueError("中身が JSON ではありません") from None
    if not isinstance(body, dict):
        raise ValueError("中身が JSON ではありません")
    query = str(body.get("query") or "").strip()[:200]
    if not query:
        raise ValueError("query が空です")
    try:
        k = max(1, min(int(body.get("k") or 12), SEARCH_K_MAX))
    except (TypeError, ValueError):
        k = 12
    person = str(body.get("person") or "").strip()[:40] or None
    sources = [str(x) for x in body.get("sources") or [] if isinstance(x, str)][:10] or None
    frm = None
    try:
        days = int(body.get("days")) if body.get("days") is not None else None
    except (TypeError, ValueError):
        days = None
    if days and days > 0:
        frm = ((today or datetime.date.today()) - datetime.timedelta(days=min(days, 3650))).isoformat()
    return {"query": query, "k": k, "person": person, "sources": sources, "frm": frm}


def search_hits(raw: list[dict], person: str | None, k: int) -> list[dict]:
    """返す形にそろえる（path と点は出さない）。person があれば、その名前が文か見出しに出るものだけ"""
    out = []
    for hit in raw or []:
        text = str(hit.get("text") or "")
        label = str(hit.get("label") or "")
        if person and person not in text and person not in label:
            continue
        row = {"source": str(hit.get("source") or ""), "day": str(hit.get("day") or ""),
               "time": str(hit.get("time") or ""), "text": text[:600]}
        if label:
            row["label"] = label
        out.append(row)
        if len(out) >= k:
            break
    return out


def http_post_search(handler) -> None:
    length = int(handler.headers.get("Content-Length") or 0)
    if length <= 0 or length > 16_384:
        handler.send_json(400, {"ok": False, "error": "中身がありません" if length <= 0 else "長すぎます"})
        return
    try:
        request = search_request(handler.rfile.read(length))
    except ValueError as error:
        handler.send_json(400, {"ok": False, "error": str(error)})
        return
    try:
        import mothersearch

        index = getattr(mothersearch, "INDEX", None)
        if index is None:
            handler.send_json(503, {"ok": False, "error": "母艦の検索がまだ動いていません"})
            return
        wide = request["k"] * 4 if request["person"] else request["k"]
        raw = index.search(request["query"], k=wide, sources=request["sources"], frm=request["frm"])
    except Exception as error:  # noqa: BLE001
        _log(f"母艦の検索（/mother-search）に失敗しました: {type(error).__name__}")
        handler.send_json(503, {"ok": False, "error": "探せませんでした"})
        return
    handler.send_json(200, {"ok": True, "hits": search_hits(raw, request["person"], request["k"])})


# MARK: - summary.md


def _read(path: Path, default=None):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def _secs(value) -> str:
    try:
        import diag

        return diag._secs(float(value))
    except Exception:  # noqa: BLE001
        return f"{value} 秒"


def summary_lines(diag_store=None, now: float | None = None) -> tuple[list[str], list[str]]:
    """(気になる所の行, 「## s25 の数」の節の行)"""
    home = S.home
    if home is None:
        return [], []
    today = datetime.date.fromtimestamp(now or time.time())
    config = _config()
    base = _base()
    lines: list[str] = []
    worries: list[str] = []
    week = [(today - datetime.timedelta(days=i)).isoformat() for i in range(7)][::-1]
    try:
        import quality

        daily = quality.read_daily(home)["days"]
    except Exception:  # noqa: BLE001
        daily = {}

    def feeds_line():
        if base is None:
            return "LINE のタスク候補（K1）・下書き（K2）: 母艦が見つかりません"
        tasks = s25pfeeds.read_line_tasks(base, today)
        drafts = s25pfeeds.read_drafts(base, today)
        def part(body):
            return f"{len(body['items'])} 件" if body.get("available") else str(body.get("reason"))
        return f"GET /line-tasks（K1）: {part(tasks)}・GET /drafts（K2）: {part(drafts)}"

    def share_line():
        folder = Path(home) / s25pfeeds.SHARE_DIR
        files = [p for p in folder.glob("*.txt")] if folder.is_dir() else []
        limit = time.time() - 7 * 86400
        recent = sum(1 for p in files if p.stat().st_mtime >= limit)
        return f"LINE の共有（POST /line/share・K3）: 7 日で {recent} 件（置き場 {folder}・全部 {len(files)} 件。消さない）"

    def bot_line():
        got = sum(int((daily.get(d) or {}).get("s25p_line_bot", 0) or 0) for d in week)
        replied = sum(int((daily.get(d) or {}).get("s25p_line_bot_replied", 0) or 0) for d in week)
        secret = bool(s25pline.linehook.secret(home))
        memo = Path(home) / s25pline.MEMO_FILE
        memos = len(memo.read_text(encoding="utf-8").splitlines()) if memo.is_file() else 0
        text = (f"LINE の Bot（POST /line/hook・K4・返信だけ）: 7 日で受けた {got}・返した {replied}・メモ {memos} 行・"
                f"チャネルシークレット {'あり' if secret else 'まだ無い'}")
        if not got:
            text += "（LINE の管理画面で Webhook の URL を …/line/hook にするのは本人の操作）"
        return text

    def ping_line():
        days = ((_read(s25pnight.folder(home) / "ping.json", {}) or {}).get("days") or {})
        parts = []
        for d in week:
            e = days.get(d)
            if isinstance(e, dict) and e.get("sent_at"):
                parts.append(f"{d[5:]} {'返った' if e.get('got') else ('送った' if e.get('sent') else '送れず')}")
        state = "止めている" if config.get("s25p_ping") is False else f"毎日 {s25pnight.PING_HOUR} 時台（仮）"
        return f"知らせの道の静かな試し（K6・{state}）: " + ("・".join(parts) if parts else "まだ送っていません")

    def whisper_line():
        on = config.get("whisper_now") is True
        return "その場の耳打ち（GET /whisper-now・K7）: " + ("オン" if on else '止めている（"whisper_now": true でオン）')

    def stages_line():
        days = ((_read(s25pnight.folder(home) / "stages.json", {}) or {}).get("days") or {})
        if not days:
            return "段ごとの待ち（早1）: まだ数えていません"
        d = sorted(days)[-2] if len(days) >= 2 else sorted(days)[-1]   # 昨日（今日は途中）
        e = days[d]
        out = []
        for device, label in (("iphone", "iPhone"), ("watch", "時計")):
            row = e.get(device) or {}
            parts = [f"{name} {_secs(row[k]['median'])}" for k, name in s25pnight.STAGES if isinstance(row.get(k), dict)]
            if parts:
                total = row.get("total")
                out.append(f"{label}（{(total or {}).get('count', 0)} 区切り・合計 {_secs(total['median']) if total else '—'}）: "
                           + "・".join(parts))
        longest = dict(s25pnight.STAGES).get(e.get("longest"), e.get("longest"))
        return f"段ごとの待ち（早1・{d[5:]}・中央値）: " + "／".join(out) + (f"。いちばん長い段: {longest}" if longest else "")

    def to_pc_line():
        days = ((_read(s25pnight.folder(home) / "stages.json", {}) or {}).get("days") or {})
        rows = [(d, days[d]) for d in sorted(days)[-7:]]
        counts: dict[str, int] = {}
        batched, jobs = 0.0, 0
        for _, e in rows:
            for k, v in (e.get("to_pc_buckets") or {}).items():
                counts[k] = counts.get(k, 0) + int(v)
            if isinstance(e.get("batched"), (int, float)):
                batched += e["batched"] * int(e.get("phone_jobs") or 0)
                jobs += int(e.get("phone_jobs") or 0)
        if not jobs:
            return None
        return ("iPhone→PC の中身（早3・7 日）: " + "・".join(f"{k} {v}" for k, v in counts.items())
                + f"・60 秒以内に続けて届いた（まとめて送った）割合 {batched / jobs:.0%}（Wi-Fi 待ちかは PC からは見えない・仮説）")

    def night_line():
        info = s25pnight.night_summary(home, today)
        if not info["night"]:
            return "夜の測りの合計時間（早2）: まだ数えていません"
        rows = "・".join(f"{k} {_secs(v.get('seconds'))}" for k, v in sorted(info["rows"].items()))
        thin = "間引かない設定" if config.get("s25p_night_thin") is False else "収まらなければ軽いものから間引く（仮）"
        text = (f"夜の測りの合計時間（早2・{info['night'][5:]}）: 合計 {_secs(info['total'])}（4 時間に{'収まった' if info['total'] <= s25pnight.NIGHT_WINDOW else '収まらない'}）"
                f"・{rows}・最後に終わった {info['ended'] or '—'}。{thin}")
        if info["skipped"]:
            text += f"。この晩に間引いた: {'・'.join(info['skipped'])}"
        if info["plan"]:
            text += f"。次の晩に間引く見込み: {'・'.join(info['plan'])}"
        return text

    def mic_line():
        got = s25pnight.mic_candidate(home, today)
        def part(name, label):
            t = got[name]
            if not t["overlap_min"]:
                return f"{label} 重なり無し"
            match = "—" if t["match"] is None else f"{t['match']:.0%}"
            cover = "—" if t["cover"] is None else f"{t['cover']:.0%}"
            return f"{label} 重なり {t['overlap_min']} 分・PLAUD と合う {match}・PLAUD の字の {cover}・声 {t['voiced_s']:.0f} 秒"
        text = f"マイクの見直し（大3・14 日のうち測れた {got['days']} 日・仮）: " + "／".join((part("watch", "時計"), part("iphone", "iPhone")))
        if got["pick"]:
            label = {"watch": "時計", "iphone": "iPhone"}[got["pick"]]
            text += f"。主にする音の候補: {label}" + ("（ただし時計も iPhone も PLAUD の字の半分に届かない＝PLAUD を主にする候補）" if got["plaud_first"] else "")
            text += "（切り替えは自動ではしません）"
        else:
            text += f"。候補はまだ（{s25pnight.MIC_DAYS} 日・重なり {s25pnight.MIC_MIN_OVERLAP} 分から・仮）"
        return text

    def train_line():
        try:
            rows = S.main.read_samples(S.main.PERSONAL_DATA)
        except Exception:  # noqa: BLE001
            rows = []
        teacher = sum(1 for r in rows if isinstance(r.get("source"), dict) and r["source"].get("origin") == s25ptrain.ORIGIN)
        once = _read(Path(home) / s25ptrain.ONCE_FILE, {}) or {}
        cand = s25ptrain.candidate_info(home)
        if once.get("done"):
            r = once.get("result") or {}
            state = f"1 回だけの学び直し: {r.get('result')}（前 {r.get('cer_before')}・後 {r.get('cer_after')}）"
        elif config.get("s25p_train_once") is False:
            state = "1 回だけの学び直し: 止めている"
        else:
            state = f"1 回だけの学び直し: 待っています（00:00〜05:00・渡した晩 {len(once.get('nights') or [])}）"
        text = f"自分専用の文字起こしモデル（大4）: 材料 {len(rows)} 個のうち PLAUD を先生にした {teacher} 個・{state}"
        if cand:
            text += (f"。候補（入れ替えていない）: 正解集 {cand.get('test')} 個で CER {cand.get('cer_before')} → {cand.get('cer_after')}"
                     "（切り替えるかは本人）")
        return text

    def partner_line():
        days = ((_read(s25pnight.folder(home) / "partner.json", {}) or {}).get("days") or {})
        total = sum(int(e.get("conversations") or 0) for e in days.values())
        named = sum(int(e.get("named") or 0) for e in days.values())
        calls = sum(int(e.get("call_candidates") or 0) for e in days.values())
        maybe = sum(int(e.get("voice_maybe") or 0) for e in days.values())
        switch = "オン" if config.get("s25p_snorm_switch") is True else '止めている（"s25p_snorm_switch": true）'
        rate = f"{named / total:.0%}" if total else "—"
        return (f"会話の相手の付き方（大9・7 日）: 名前のある相手が付いた会話 {named}/{total}（{rate}）・付いていない会話の材料: "
                f"LINE の通話 {calls}（連16）・声の近い人 {maybe}。s-norm に切り替える口: {switch}")

    def precheck_line():
        if not s25pcheck.on(config):
            return '迷った問いを Claude が先に見る（活1）: 止めている（"s25p_precheck": true でオン・1 日 $0.05・5 問・仮）'
        items = s25pcheck.state(home)["items"]
        recent = [v for v in items.values() if isinstance(v, dict) and str(v.get("at", ""))[:10] in week]
        closed = sum(1 for v in recent if v.get("verdict") == "closed")
        return f"迷った問いを Claude が先に見る（活1）: 7 日で見た {len(recent)}・閉じた {closed}（機械の見立てのままでよいもの）"

    def draft_line():
        return "会話のまとめを下書きで先に（早4）: PC は GET /jobs/<名前> で下書きをもう返している。まとめはアプリが作る（アプリ側の分）"

    for name, make in (("feeds", feeds_line), ("share", share_line), ("bot", bot_line), ("ping", ping_line),
                       ("whisper", whisper_line), ("stages", stages_line), ("topc", to_pc_line), ("night", night_line),
                       ("draft", draft_line), ("mic", mic_line), ("train", train_line), ("partner", partner_line),
                       ("precheck", precheck_line)):
        try:
            text = make()
            if text:
                lines.append(f"- {text}")
        except Exception as error:  # noqa: BLE001 — 1 つ書けなくても、ほかは書く
            lines.append(f"- （{name} を数えられませんでした: {type(error).__name__}）")
    try:
        days = ((_read(s25pnight.folder(home) / "ping.json", {}) or {}).get("days") or {})
        yesterday = (today - datetime.timedelta(days=1)).isoformat()
        e = days.get(yesterday) or {}
        if e.get("sent") and not e.get("got"):
            worries.append(f"- 昨日（{yesterday[5:]}）の静かな試し（ping）が、アプリの様子に返っていません（K6。知らせの道が止まっているかも・仮）")
    except Exception:  # noqa: BLE001
        pass
    return worries, lines
