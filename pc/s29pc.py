"""LifeLog PC: s29（2026-11-27。担当 P）「声を分ける・当てる」の家の PC の分をまとめてつなぐ所。名前の頭は s29p。

lifelog_pc.py から呼ぶのは start(main)（start_v6 の中。s26pc.start のあと）と features()・GETS・http_get。
summary.md の「## s29 の数」の節は ops.write_summary が summary_lines(...) で足す。0 円・言語モデルなし・ダウンロードなし。

担当の案と既定（config.json に書かなければ DEFAULTS。中身は s29p*.py）:
- 声22 答えの受け（s29panswers.py。オン）: POST /feedback の same_person に省ける s29_*・記録の話し手の直しから組・答えの見本を残す
- 声19 名前の無い声のかたまり（s29pgroups.py。オン）: GET /same-person の省ける "s29_groups"
- 声9 s-norm の切り替えの判断（s29pgate.py。毎晩記録。"s29p_snorm_score": "candidate"＝候補に出すだけ）
- 声25 分け間違い（quality-daily.json の speaker_split_wrong）・声26 本番入りの条件（s29pgate.GATES・GET /s29/gates）
- 声5・声7・声12・声13 正本の候補（s29pvoice.py。"s29p_canonical": false＝口に出さない・"s29p_canonical_shadow": true＝数える）
- 声2 2 本のマイク（"s29p_two_mic": true＝影）・声3 雑音を消してから声の特徴（"s29p_denoise_embed": false）・
  声6 重なり（s26pnight.separate・"s26p_separate": false のまま）・声17 モデルの比べ（python pc/s29pvoice.py models）
"""

from __future__ import annotations

import datetime
import threading
import time
from pathlib import Path

import jobfirst
import quality
import s29panswers
import s29pgate
import s29pgroups
import s29pvoice

FEATURES = ["s29groups", "s29answers", "s29gates", "s29canonical"]
GETS = ("/s29/gates", "/s29/canonical")
TICK = 60.0
FIRST_WAIT = 300.0
LIGHT_EVERY = 1800.0
NIGHT_START_HOUR, NIGHT_END_HOUR = 0, 5
NIGHT_BUDGET = 1200.0        # 仮: 1 晩 20 分まで
DENOISE_PAIRS = 60

DEFAULTS = {"s29p_answers": True, "s29p_groups": True, "s29p_canonical": False, "s29p_canonical_shadow": True,
            "s29p_two_mic": True, "s29p_denoise_embed": False}


class S:
    main = None
    home: Path | None = None
    thread: threading.Thread | None = None
    next_light = 0.0
    night_day: str | None = None
    last: dict = {}


def on(config: dict, name: str) -> bool:
    value = (config or {}).get(name)
    return value if isinstance(value, bool) else bool(DEFAULTS.get(name, False))


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
    return list(FEATURES)


def install(home_of) -> None:
    """包みを入れる（何度呼んでも 1 回だけ）。appfeeds.parse_feedback・s23voice.answers/groups_with_samples・
    s24rules.hold_same_person"""
    import appfeeds
    import s23voice
    import s24rules

    if not getattr(appfeeds.parse_feedback, "s29p_wrapped", False):
        appfeeds.parse_feedback = s29panswers.wrap_parse(appfeeds.parse_feedback, home_of)
    if not getattr(s23voice.answers, "s29p_wrapped", False):
        s23voice.answers = s29panswers.wrap_answers(s23voice.answers, home_of)
    if not getattr(s23voice.groups_with_samples, "s29p_wrapped", False):
        s23voice.groups_with_samples = s29panswers.wrap_groups(s23voice.groups_with_samples)
    if not getattr(s24rules.hold_same_person, "s29p_wrapped", False):
        s24rules.hold_same_person = s29pgroups.wrap_hold(s24rules.hold_same_person, home_of)


def start(main) -> None:
    S.main = main
    S.home = Path(main.HOME)
    try:
        install(lambda: S.home)
    except Exception as error:  # noqa: BLE001
        _log(f"s29 の包みを入れられませんでした: {type(error).__name__}")
    if S.thread is None:
        S.thread = threading.Thread(target=_loop, name="s29p", daemon=True)
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
                _log(f"s29 の見回りでつまずきました: {type(error).__name__}")
        time.sleep(TICK)


def _read_day(store):
    return (lambda d: store.day(d)) if store is not None else (lambda d: None)


def light(home: Path, base: Path | None, store, config: dict, today: datetime.date) -> dict:
    """30 分ごと（軽い）: 声22 記録の直し・答えの取り込み、声19 かたまり"""
    out: dict = {}
    if on(config, "s29p_answers"):
        out["records"] = s29panswers.scan_records(home, _read_day(store), today)
        import s23voice

        groups = {**s29pgroups.seen_groups(home), **s23voice.groups_with_samples(home)}
        out["feedback"] = s29panswers.import_feedback(home, base, groups, _read_day(store))
        out["spt"] = s29panswers.import_spt(home, base, _read_day(store), today)
    if on(config, "s29p_groups"):
        body = s29pgroups.build(home, store, today, s29pgate.answered_pairs(home, base))
        out["groups"] = len(body["groups"])
    return out


def tick(moment: datetime.datetime | None = None) -> dict:
    moment = moment or datetime.datetime.now()
    done: dict = {}
    if S.home is None:
        return done
    config, base, store = _config(), _base(), _store()
    if time.time() >= S.next_light and not jobfirst.busy():
        S.next_light = time.time() + LIGHT_EVERY
        done["light"] = light(S.home, base, store, config, moment.date())
        S.last["light"] = done["light"]
    day = moment.date().isoformat()
    if NIGHT_START_HOUR <= moment.hour < NIGHT_END_HOUR and S.night_day != day and not jobfirst.busy():
        S.night_day = day
        done["night"] = night(S.home, base, store, config, moment.date(), deadline=time.time() + NIGHT_BUDGET)
    return done


def _find(home: Path):
    import s24night

    return lambda name: s24night.find_audio(home, name)


def _denoise_parts():
    """声3: 手元にあるモデルだけで（取ってこない）。無ければ None"""
    main = S.main
    if main is None:
        return None
    enhance = Path(main.ENHANCE_DIR) / main.ENHANCE_MODEL
    speaker = Path(main.HOME) / "speaker"
    if not enhance.is_file() or not any(speaker.glob("*.onnx")):
        return None
    sp, dn = main.extra_model("speaker", 1), main.extra_model("enhance", 1)
    return sp.embed, dn.denoise


def night(home: Path, base: Path | None, store, config: dict, today: datetime.date, deadline: float | None = None,
          load_audio=None, denoise_parts=None) -> dict:
    """夜（00:00〜05:00 に 1 回）。1 つが落ちても次へ。数は HOME/s29p/night.json と quality-daily.json の昨日に"""
    out: dict = {}
    yesterday = (today - datetime.timedelta(days=1)).isoformat()
    read_day = _read_day(store)
    load_audio = load_audio or (lambda data: S.main.load_audio(data))
    measures: dict = {}
    daily: dict = {}

    def step(name: str, work, enabled: bool = True) -> None:
        if not enabled:
            out[name] = "off"
            return
        if deadline is not None and time.time() > deadline:
            out[name] = "時間切れ"
            return
        try:
            out[name] = work()
        except Exception as error:  # noqa: BLE001
            out[name] = {"error": type(error).__name__}

    step("light", lambda: light(home, base, store, config, today))
    pairs = s29pgate.answered_pairs(home, base)
    scored: dict = {}

    def snorm():
        scored.update(s29pgate.score_pairs(home, pairs))
        gate = s29pgate.gate_settings(config)["snorm"]
        decision = s29pgate.snorm_decide(scored, gate["need"], gate["margin"])
        s29pgate.record_decision(home, decision, yesterday)
        daily["s29_snorm"] = {k: decision[k] for k in ("pairs", "same", "auc_raw", "auc_snorm", "decision")}
        measures["snorm"] = {"n": decision["pairs"], "now": decision["auc_raw"], "new": decision["auc_snorm"]}
        return {k: decision[k] for k in ("pairs", "decision")}

    step("snorm", snorm)

    def split():
        got = s29pgate.split_wrong(home, base, pairs, read_day, yesterday, scored)
        if got["speaker_split_wrong"] is not None:
            daily["speaker_split_wrong"] = got["speaker_split_wrong"]
        daily["s29_split_detail"] = got["s29_split_detail"]
        return got["speaker_split_wrong"] or "材料なし"

    step("split", split)

    def canon():
        import s26pvoice

        days = [(today - datetime.timedelta(days=k)).isoformat() for k in range(1, 8)]
        refs = s26pvoice.name_refs(home, store, days)
        body = s29pvoice.canonical(home, base, store, yesterday, refs)
        if body is None:
            return "記録なし"
        bodies = [body] + [b for b in (_read_canon(home, d) for d in days[1:]) if b]
        iphone = s29pgate.accuracy(pairs, lambda p: p.get("orig_same"))
        for gate, key in (("canonical", "where"), ("day_diar", "base_where")):
            guesses = [s29pvoice.same_of(b, key) for b in bodies]

            def guess(p, guesses=guesses):
                for g in guesses:
                    got = g(p)
                    if got is not None:
                        return got
                return None

            mine = s29pgate.accuracy(pairs, guess)
            both = [p for p in pairs if guess(p) is not None and isinstance(p.get("orig_same"), bool)]
            base_acc = s29pgate.accuracy(both, lambda p: p.get("orig_same"))
            measures[gate] = {"n": len(both), "now": base_acc["rate"], "new": s29pgate.accuracy(both, guess)["rate"]}
            out.setdefault("canon_acc", {})[gate] = mine["rate"]
        out["iphone_acc"] = iphone["rate"]
        return body["counts"]

    step("canonical", canon, on(config, "s29p_canonical") or on(config, "s29p_canonical_shadow"))

    def mic2():
        days = [(today - datetime.timedelta(days=k)).isoformat() for k in range(1, 4)]
        got = s29pvoice.two_mic(home, store, days, load_audio, _find(home), deadline)
        s29pvoice._write(s29pvoice.folder(home) / "two-mic.json", {"generated_at": datetime.datetime.now().isoformat(timespec="seconds"),
                                                                   **got})
        if got["status"] == "測った":
            measures["two_mic"] = {"n": got["lines"], "now": got["auc_one"], "new": got["auc_two"]}
        return got["status"]

    step("two_mic", mic2, on(config, "s29p_two_mic"))

    def denoise():
        parts = denoise_parts() if denoise_parts is not None else _denoise_parts()
        if parts is None:
            return "モデルが手元に無い（取ってこない）"
        embed, clean = parts
        find = _find(home)
        plain = s29pvoice.audio_vec(load_audio, find, lambda a, r: embed(a, r))
        cleaned = s29pvoice.audio_vec(load_audio, find, lambda a, r: embed(a, r), clean)
        got = s29pvoice.denoise_compare(pairs[-DENOISE_PAIRS:], plain, cleaned)
        s29pvoice._write(s29pvoice.folder(home) / "denoise-embed.json",
                         {"generated_at": datetime.datetime.now().isoformat(timespec="seconds"), **got})
        measures["denoise_embed"] = {"n": got["pairs"], "now": got["plain"]["auc_raw"], "new": got["denoised"]["auc_raw"]}
        return {"pairs": got["pairs"]}

    step("denoise", denoise, on(config, "s29p_denoise_embed"))

    def others():
        import s26pnight

        b = s26pnight.boost_total(home, today)
        if b["lines"]:
            measures["boost"] = {"n": b["lines"], "now": 1.0, "new": round(b["after"] / max(1, b["before"]), 3)}
        sep = (s26pnight._read(s26pnight.folder(home) / "separate.json", {}) or {}).get("pairs") or {}
        before = sum(int((r or {}).get("before") or 0) for r in sep.values())
        after = sum(int((r or {}).get("after") or 0) for r in sep.values())
        if sep:
            measures["separate"] = {"n": len(sep), "now": 1.0, "new": round(after / max(1, before), 3)}
        return {"boost": b["lines"], "separate": len(sep), "parts": s29pvoice.separate_parts()}

    step("others", others)

    def gates():
        import s26pc

        states = {}
        for name, gate in s29pgate.GATES.items():
            key = gate["config"]
            if key == "s29p_snorm_score":
                states[name] = s29pgate.snorm_mode(config)
            elif key.startswith("s26p_"):
                states[name] = "on" if s26pc.on(config, key) else "off"
            else:
                states[name] = "on" if on(config, key) else "off"
        body = s29pgate.gates_status(config, measures, states)
        s29pgate.write_gates(home, body)
        return [k for k, v in body["gates"].items() if v["candidate"]]

    step("gates", gates)
    try:
        daily["s29_answers"] = s29panswers.counts(home)
        quality.update_day(home, yesterday, daily)
    except OSError:
        pass
    S.last["night"] = out
    try:
        s29pgate._write(s29pgate.folder(home) / "night.json",
                        {"day": today.isoformat(), "at": datetime.datetime.now().isoformat(timespec="seconds"), "steps": out})
    except OSError:
        pass
    _log("s29 の夜の数: " + "・".join(f"{k} {_short(v)}" for k, v in out.items()))
    return out


def _read_canon(home: Path, day: str) -> dict | None:
    body = s29pvoice._read(s29pvoice.folder(home) / "canonical" / f"{day}.json", None)
    return body if isinstance(body, dict) else None


def _short(value) -> str:
    if isinstance(value, dict):
        if "error" in value:
            return f"つまずき（{value['error']}）"
        nums = [f"{k}={v}" for k, v in value.items() if isinstance(v, (int, float, str)) and not isinstance(v, bool)][:4]
        return "{" + ",".join(nums) + "}"
    if isinstance(value, list):
        return "[" + ",".join(map(str, value)) + "]"
    return str(value)


# MARK: - 受け口


def http_get(handler, path: str, query: str = "") -> None:
    """認証は呼ぶ側（lifelog_pc.py）が済ませてから"""
    from urllib.parse import parse_qs

    if S.home is None:
        handler.send_json(200, {"available": False, "reason": "まだ動いていません"})
        return
    if path == "/s29/gates":
        handler.send_json(200, s29pgate.read_gates(S.home))
        return
    if path == "/s29/canonical":
        day = (parse_qs(query or "").get("day") or [None])[0]
        gates = s29pgate.read_gates(S.home).get("gates") or {}
        handler.send_json(200, s29pvoice.read_canonical(S.home, day, on(_config(), "s29p_canonical"), gates.get("canonical")))
        return
    handler.send_json(404, {"error": "not found"})


# MARK: - summary.md


def summary_lines(diag_store=None, now: float | None = None) -> tuple[list[str], list[str]]:
    home = S.home
    if home is None:
        return [], []
    config = _config()
    lines: list[str] = []
    worries: list[str] = []

    def answers_line():
        c = s29panswers.counts(home)
        r = s29panswers.received(home)
        by = "・".join(f"{k} {v}" for k, v in sorted(c["by_source"].items())) or "まだ"
        return (f"答えた組（声22）: {c['total']} 組（同じ人 {c['same']}・出どころ {by}）。7 日に受けた same_person: "
                f"前の形 {r['app_old']}・s29 の欄つき {r['app_s29']}（落とした欄 {r['dropped_fields']}）")

    def snorm_line():
        d = s29pgate.latest_decision(home)
        mode = s29pgate.snorm_mode(config)
        if not d:
            return f"同じ人かの点の切り替え（声9・\"s29p_snorm_score\": {mode}）: まだ判断していません（00:00〜05:00）"
        fmt = lambda v: "—" if v is None else f"{v:.2f}"  # noqa: E731
        return (f"同じ人かの点の切り替え（声9・{str(d.get('day'))[5:]}・\"s29p_snorm_score\": {mode}）: {d.get('decision')}"
                f"（答えた組 {d.get('pairs')}/{d.get('need')}・AUC 今 {fmt(d.get('auc_raw'))} → s-norm {fmt(d.get('auc_snorm'))}）")

    def split_line():
        daily = quality.read_daily(home)["days"]
        rows = [(k, v.get("speaker_split_wrong")) for k, v in sorted(daily.items()) if isinstance(v, dict)]
        rows = [(k, v) for k, v in rows if isinstance(v, dict)][-7:]
        if not rows:
            return "分け間違い（声25）: まだ材料がありません（答えた組・iPhone と時計の同じ発話）"
        return "分け間違い（声25・答えた組とマイク）: " + "・".join(f"{k[5:]} {v['wrong']}/{v['pairs']}" for k, v in rows)

    def gates_line():
        body = s29pgate.read_gates(home)
        if not body.get("available"):
            return "本番入りの条件（声26）: " + str(body.get("reason"))
        parts = [f"{k} {'候補' if v['candidate'] else v['why']}" for k, v in (body.get("gates") or {}).items()]
        return "本番入りの条件（声26・自動では切り替えない）: " + "・".join(parts)

    def groups_line():
        body = s29pvoice._read(s29pgroups.folder(home) / s29pgroups.FILE, {}) or {}
        m = body.get("measure") or {}
        return (f"名前の無い声のかたまり（声19・{s29pgroups.GROUP_LINK}・仮）: {len(body.get('groups') or [])} かたまり"
                f"（人物N {body.get('unnamed', 0)} 人から）。across がまとまった {m.get('across_kept', 0)}/{m.get('across', 0)}・"
                f"答えた組の当たり {m.get('answers_right', 0)}/{m.get('answers', 0)}")

    def mic_line():
        body = s29pvoice._read(s29pvoice.folder(home) / "two-mic.json", {}) or {}
        if not body:
            return "iPhone と時計の 2 本（声2）: まだ数えていません"
        return (f"iPhone と時計の 2 本（声2・影）: {body.get('status')}（組 {body.get('pairs', 0)}/{body.get('candidates', 0)}・"
                f"行 {body.get('lines', 0)}・AUC 2 本 {body.get('auc_two')} 対 1 本 {body.get('auc_one')}）")

    for name, make in (("answers", answers_line), ("snorm", snorm_line), ("split", split_line), ("gates", gates_line),
                       ("groups", groups_line), ("mic", mic_line)):
        try:
            text = make()
            if text:
                lines.append(f"- {text}")
        except Exception as error:  # noqa: BLE001
            lines.append(f"- （{name} を数えられませんでした: {type(error).__name__}）")
    try:
        body = s29pgate.read_gates(home)
        cands = [v["label"] for v in (body.get("gates") or {}).values() if v.get("candidate")]
        if cands:
            worries.append("- 答えた組で良くなった影の機能があります（声26・本番にするかは本人。自動では切り替えません）: " + "・".join(cands))
    except Exception:  # noqa: BLE001
        pass
    return worries, lines
