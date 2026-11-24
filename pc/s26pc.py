"""LifeLog PC: s26（2026-11-25。担当 P）の家の PC の分をまとめてつなぐ所。名前の頭は s26p。

lifelog_pc.py から呼ぶのは start(main)（start_v6 の中。s25pc.start のあと）と features()・GETS・POSTS・http_get・http_post。
summary.md の「## s26 の数」の節は ops.write_summary が summary_lines(...) で足す。

担当の案と、初めはオンかオフか（config.json。書かなければ下の既定。中身は s26p*.py）:
- K4 GET /machine-actions・K5 GET /waiting・K6 GET /gap-task・K8 GET /events?since=（s26pfeeds.py。読むだけ。オン）
- K4 POST /feedback の kind "undo"（appfeeds.FEEDBACK）・K7 1 日の上限を月の残りから（claude.py の today_cap。
  claude-config.json の "auto_caps": false で止める。オン）と GET /costs の "cap_today"・"effect"
- 結9 LINE の Bot の返事に lifelog:// のリンク（s25pline.py。オン）・結7 記録を引く口の道具（lifelog_mcp.py）
- 夜 00:00〜05:00（新しい区切りが待っていないとき・1 晩 1 回・合わせて NIGHT_BUDGET まで。s26pnight.py ほか）:
    聞7 機械の正解 "s26p_machine_gold"（オン）・聞1/聞2 場面ごとのマイク "s26p_mic_scenes"（オン・切り替えない）・
    聞3 全部聞く "s26p_full_listen"（オン・影）・聞15 小さい声を持ち上げる "s26p_boost"（オン・影）・
    聞6 重なりを分ける "s26p_separate"（オフ。数えるのはいつも）・集3 せき・いびき "s26p_sounds"（オン・数だけ）・
    結1 場面の見込みを声で "s26p_talk_guess"（オン・たぶんだけ）・聞5 予定の相手の声 "s26p_calendar_voice"（オン・問いは 3 問の中）・
    聞4 1 日まるごとの話し手分け "s26p_day_diar"（オフ）・聞11 毎週の学び直しを候補に（"s26p_weekly_swap"・"s26p_promote"・
    "s26p_auto_rollback" はどれもオフ）・結4 顔のまとまり "s26p_faces"（オフ）
"""

from __future__ import annotations

import datetime
import json
import threading
import time
from pathlib import Path

import jobfirst
import s26pface
import s26pfeeds
import s26pnight
import s26ptrain
import s26pvoice

GETS = s26pfeeds.GETS
POSTS = s26pface.POSTS
TICK = 60.0
FIRST_WAIT = 240.0
NIGHT_BUDGET = 3000.0        # 仮: 1 晩 50 分まで
NIGHT_START_HOUR = 0
NIGHT_END_HOUR = 5
NIGHT_FILE = "night.json"

# 書かなければの既定（安全な側: モデルを替える・新しいモデルを使う所はオフ、数える・影で比べる所はオン）
DEFAULTS = {"s26p_machine_gold": True, "s26p_mic_scenes": True, "s26p_full_listen": True, "s26p_boost": True,
            "s26p_separate": False, "s26p_sounds": True, "s26p_talk_guess": True, "s26p_calendar_voice": True,
            "s26p_day_diar": False, "s26p_faces": False}


class S:
    main = None
    home: Path | None = None
    thread: threading.Thread | None = None
    night_day: str | None = None
    last: dict = {}


def _config() -> dict:
    try:
        return (S.main.load_config() if S.main is not None else {}) or {}
    except Exception:  # noqa: BLE001
        return {}


def on(config: dict, name: str) -> bool:
    value = (config or {}).get(name)
    return value if isinstance(value, bool) else bool(DEFAULTS.get(name, False))


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
    return list(s26pfeeds.FEATURES)


def _trainer():
    try:
        import ops

        return ops.O.trainer if ops.O.started else None
    except Exception:  # noqa: BLE001
        return None


# MARK: - つなぐ


def start(main) -> None:
    S.main = main
    S.home = Path(main.HOME)
    try:  # 結1: 「名前のある人かも」の近さに、場面の見込みの候補を足す（s22 の確5 のあとに重ねる）
        import voices

        if not getattr(voices.PRIOR_BONUS, "s26p_wrapped", False):
            wrapped = s26pvoice.chain_bonus(voices.PRIOR_BONUS, lambda: S.home, _base, _store, _config)
            wrapped.s26p_wrapped = True  # type: ignore[attr-defined]
            voices.PRIOR_BONUS = wrapped
    except Exception:  # noqa: BLE001
        pass
    try:  # 聞5: 問いは今の 1 日 3 問の中に 1 つだけ・「はい」の見本は GET /voice-samples に
        import knowapp

        reader = knowapp.READERS.get("/know/questions")
        if reader is not None and not getattr(reader, "s26p_wrapped", False):
            knowapp.READERS["/know/questions"] = s26pvoice.wrap_questions(reader, lambda: S.home, _config)
        import voicesamples

        if not getattr(voicesamples.read, "s26p_wrapped", False):
            voicesamples.read = s26pvoice.wrap_samples(voicesamples.read, lambda: S.home, _config)
    except Exception:  # noqa: BLE001
        pass
    if S.thread is None:
        S.thread = threading.Thread(target=_loop, name="s26p", daemon=True)
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
                _log(f"s26 の見回りでつまずきました: {type(error).__name__}")
        time.sleep(TICK)


def tick(moment: datetime.datetime | None = None) -> dict:
    moment = moment or datetime.datetime.now()
    done: dict = {}
    if S.home is None:
        return done
    s26ptrain.hook_weekly(_trainer(), _config)   # 聞11: 毎週の学び直しは候補に（"s26p_weekly_swap": true で前のまま）
    day = moment.date().isoformat()
    if NIGHT_START_HOUR <= moment.hour < NIGHT_END_HOUR and S.night_day != day and not jobfirst.busy():
        S.night_day = day
        started = time.time()
        done["night"] = night(S.home, _base(), _store(), _config(), moment.date(), deadline=started + NIGHT_BUDGET)
        try:
            import s25pnight

            s25pnight.record_time(S.home, "s26p", time.time() - started, time.time())
        except Exception:  # noqa: BLE001
            pass
    return done


def _asr(audio, segments):
    engine = getattr(getattr(S.main, "Handler", None), "engine", None)
    if engine is None:
        raise RuntimeError("文字にするモデルがまだ読み込まれていません")
    return engine.transcribe(audio, segments, hints=[])


def _tagger(audio, ranges):
    return S.main.extra_model("scene", 2).tag(audio, ranges)


def _reload_mine() -> None:
    trainer = _trainer()
    if trainer is not None and getattr(trainer, "on_improved", None) is not None:
        trainer.on_improved()


def night(home: Path, base: Path | None, store, config: dict, today: datetime.date, deadline: float | None = None,
          asr=None, tagger=None, load_audio=None) -> dict:
    """夜の分を順に（1 つが落ちても次へ）。結果は HOME/s26p/night.json に（数だけ）"""
    asr = asr or _asr
    tagger = tagger or _tagger
    load_audio = load_audio or (lambda data: S.main.load_audio(data))
    out: dict = {}

    def step(name: str, work, *, enabled: bool = True, needs_asr: bool = False) -> None:
        if not enabled:
            out[name] = "off"
            return
        if deadline is not None and time.time() > deadline:
            out[name] = "時間切れ"
            return
        if needs_asr:
            trainer = _trainer()
            if (trainer is not None and getattr(trainer, "running", False)) or jobfirst.busy():
                out[name] = "譲った"
                return
        try:
            out[name] = work()
        except Exception as error:  # noqa: BLE001
            out[name] = {"error": type(error).__name__}

    step("gold", lambda: s26pnight.machine_gold(home, base, today, load_audio, deadline), enabled=on(config, "s26p_machine_gold"))
    step("mic", lambda: s26pnight.mic_scenes_nightly(home, base, today) if base is not None else {},
         enabled=on(config, "s26p_mic_scenes"))
    step("talk_guess", lambda: s26pvoice.check_guesses(home, base, store, today)["counts"], enabled=on(config, "s26p_talk_guess"))
    step("calendar_voice", lambda: s26pvoice.calendar_update(home, base, store, today), enabled=on(config, "s26p_calendar_voice"))
    step("day_diar", lambda: {d: (s26pvoice.day_diar(home, store, d) or {}).get("agree")
                              for d in [(today - datetime.timedelta(days=1)).isoformat()]},
         enabled=on(config, "s26p_day_diar"))
    step("train", lambda: s26ptrain.nightly(home, base, config, today, reload=_reload_mine))
    step("full_listen", lambda: s26pnight.full_listen(home, base, today, asr, load_audio, deadline),
         enabled=on(config, "s26p_full_listen"), needs_asr=True)
    step("boost", lambda: s26pnight.boost(home, base, store, today, asr, load_audio, deadline),
         enabled=on(config, "s26p_boost"), needs_asr=True)
    step("overlap", lambda: s26pnight.overlap_count(home, today))
    step("separate", lambda: s26pnight.separate(home, base, store, today, asr, load_audio, deadline=deadline),
         enabled=on(config, "s26p_separate"), needs_asr=True)
    step("sounds", lambda: {k: {"cough": v["cough_count"], "snore_minutes": v["snore_minutes"]}
                            for k, v in s26pnight.sounds(home, base, today, tagger, load_audio, deadline)["days"].items()},
         enabled=on(config, "s26p_sounds"))
    step("faces", lambda: {**s26pface.embed_night(home, base, config, today, deadline=deadline),
                           **s26pface.build_clusters(home, base)}, enabled=s26pface.on(config))
    S.last["night"] = out
    try:
        s26pnight._write(s26pnight.folder(home) / NIGHT_FILE,
                         {"day": today.isoformat(), "at": datetime.datetime.now().isoformat(timespec="seconds"), "steps": out})
    except OSError:
        pass
    _log("s26 の夜の数: " + "・".join(f"{k} {_short(v)}" for k, v in out.items()))
    return out


def _short(value) -> str:
    if isinstance(value, dict):
        if "error" in value:
            return f"つまずき（{value['error']}）"
        nums = [f"{k}={v}" for k, v in value.items() if isinstance(v, (int, float)) and not isinstance(v, bool)][:4]
        return "{" + ",".join(nums) + "}"
    return str(value)


# MARK: - 受け口


def http_get(handler, path: str, query: str = "") -> None:
    s26pfeeds.http_get(handler, path, query, _base())


def http_post(handler, path: str) -> None:
    if path == "/face-name":
        s26pface.http_post(handler, S.home, _base())
        return
    handler.send_json(404, {"error": "not found"})


# MARK: - summary.md


def summary_lines(diag_store=None, now: float | None = None) -> tuple[list[str], list[str]]:
    """(気になる所の行, 「## s26 の数」の節の行)"""
    home = S.home
    if home is None:
        return [], []
    today = datetime.date.fromtimestamp(now or time.time())
    config = _config()
    base = _base()
    lines: list[str] = []
    worries: list[str] = []

    def feeds_line():
        if base is None:
            return "機械がしたこと（K4）・操作待ち（K5）・すきまの 1 件（K6）・出来事の流れ（K8）: 母艦が見つかりません"
        parts = []
        for label, body in (("機械がしたこと K4", s26pfeeds.read_machine_actions(base)), ("操作待ち K5", s26pfeeds.read_waiting(base)),
                            ("すきま K6", s26pfeeds.read_gap_task(base)), ("出来事 K8（24 時間）", s26pfeeds.read_events(base))):
            parts.append(f"{label} " + (f"{len(body['items'])} 件" if body.get("available") else str(body.get("reason"))))
        return "母艦から配る口: " + "・".join(parts)

    def cost_line():
        import claude

        cfg = claude.load_config()
        state = "オフ（\"auto_caps\": false）" if cfg.get("auto_caps") is False else "オン"
        rows = claude.costs_report()["today"]
        raised = [r for r in rows if r.get("cap_today") is not None and r.get("cap") and r["cap_today"] > r["cap"]]
        return (f"1 日の上限を月の残りから（軽2・K7）: {state}・今日 {len(rows)} 用途のうち、上限を上げた {len(raised)}"
                "（基の上限の 4 倍まで・月の上限は変えない）")

    def gold_line():
        rows = s26pnight.gold_index(home)
        scenes: dict[str, int] = {}
        for r in rows:
            scenes[str(r.get("scene"))] = scenes.get(str(r.get("scene")), 0) + 1
        state = "オン" if on(config, "s26p_machine_gold") else "止めている"
        return (f"機械の正解（聞7・K10・{state}）: {len(rows)} / {s26pnight.GOLD_TOTAL} 個（"
                + ("・".join(f"{k} {v}" for k, v in sorted(scenes.items())) or "まだ") + f"）。置き場 {home / s26pnight.GOLD_DIR}")

    def mic_line():
        got = s26pnight.mic_scene_pick(home, today)
        picks = [f"{s} → {v['pick']}" for s, v in sorted(got["scenes"].items()) if v["pick"]]
        ext = sum(int((v["devices"].get("external") or {}).get("chars") or 0) for v in got["scenes"].values())
        text = f"場面ごとのマイク（聞1・{got['days']} 日測れた・切り替えない）: " + ("・".join(picks) if picks else
                                                                         f"候補はまだ（{s26pnight.MIC_DAYS} 日から・仮）")
        return text + "。外付けのマイク（聞2）: " + (f"{ext} 字" if ext else "まだ届いていない（POST /jobs の mic=external で数える）")

    def listen_line():
        t = s26pnight.full_listen_total(home, today)
        b = s26pnight.boost_total(home, today)
        o = s26pnight.overlap_count(home, today)
        text = (f"全部聞く（聞3・影・7 日）: {t['chunks']} 区切り・拾えた字 {t['matched']}・ごみ {t['junk']}・決まり文句で落とした {t['dropped']} 行"
                f"。小さい声を持ち上げる（聞15・影）: {b['lines']} 行・PLAUD と合った字 {b['before']} → {b['after']}"
                f"（良くなった {b['better']}・悪くなった {b['worse']}）。重なり（聞6）: 札 {o['tags']} 行（{o['days']} 日）・分けるのは "
                + ("オン" if on(config, "s26p_separate") else "オフ（\"s26p_separate\": true・speechbrain が要る）"))
        return text

    def sounds_line():
        days = (s26pnight._read(s26pnight.folder(home) / "sounds.json", {}) or {}).get("days") or {}
        last = sorted(days)[-1] if days else None
        if not last:
            return "せき・いびき（集3・数だけ）: まだ数えていません（夜の録音が要る）"
        e = days[last]
        return f"せき・いびき（集3・{last[5:]}の夜・仮）: せき {e['cough']} 回・いびき {round(e['snore_seconds'] / 60, 1)} 分（聞いた {round(e['seconds'] / 60)} 分）"

    def guess_line():
        body = s26pvoice._read(s26pvoice.folder(home) / s26pvoice.GUESS_FILE, {}) or {}
        counts = body.get("counts") or {}
        cal = s26pvoice._read(s26pvoice.folder(home) / "calendar-voice.json", {}) or {}
        return (f"場面の見込みを声で（結1・K9）: 「たぶん」{counts.get('voice_ok', 0)}・声が合わない {counts.get('voice_no', 0)}・"
                f"声がまだ無い {counts.get('no_voice', 0)}・名前あり {counts.get('named', 0)}"
                f"。予定の相手の声（聞5）: 候補 {len(cal.get('ready') or [])} 人・本人が「はい」{len(cal.get('confirmed') or {})} 人"
                f"。1 日まるごとの話し手分け（聞4）: " + ("オン" if on(config, "s26p_day_diar") else "オフ（\"s26p_day_diar\": true）"))

    def train_line():
        return s26ptrain.summary(home, config)

    def face_line():
        if not s26pface.on(config):
            return "写真の顔のまとまり（結4）: オフ（\"s26p_faces\": true・opencv-python が要る。顔の数字はこの PC の中だけ）"
        body = s26pnight._read(home / s26pface.FACES / "clusters.json", {}) or {}
        clusters = body.get("clusters") or []
        return f"写真の顔のまとまり（結4）: {len(clusters)} まとまり・名前あり {sum(1 for c in clusters if c.get('name'))}"

    def night_line():
        body = s26pnight._read(s26pnight.folder(home) / NIGHT_FILE, {}) or {}
        steps = body.get("steps") or {}
        if not steps:
            return "s26 の夜の分: まだ動いていません（00:00〜05:00）"
        bad = [k for k, v in steps.items() if isinstance(v, dict) and "error" in v]
        return f"s26 の夜の分（{str(body.get('day'))[5:]}）: " + "・".join(f"{k} {_short(v)}" for k, v in steps.items()) + \
            (f"。つまずき: {'・'.join(bad)}" if bad else "")

    for name, make in (("feeds", feeds_line), ("cost", cost_line), ("gold", gold_line), ("mic", mic_line),
                       ("listen", listen_line), ("sounds", sounds_line), ("guess", guess_line), ("train", train_line),
                       ("face", face_line), ("night", night_line)):
        try:
            text = make()
            if text:
                lines.append(f"- {text}")
        except Exception as error:  # noqa: BLE001 — 1 つ書けなくても、ほかは書く
            lines.append(f"- （{name} を数えられませんでした: {type(error).__name__}）")
    try:
        state = json.loads((Path(home) / s26ptrain.STATE).read_text(encoding="utf-8"))
        swap = state.get("swap") or {}
        if swap.get("worse") and not swap.get("rolled_back"):
            worries.append(f"- 自分専用モデルを {str(swap.get('at'))[5:]} に入れ替えてから当たり率が下がっています（聞11。戻す候補・"
                           "\"s26p_auto_rollback\": true で自動で戻す）")
    except (OSError, ValueError, AttributeError):
        pass
    return worries, lines
