"""LifeLog PC: s34（2026-11-27。担当 p）をまとめてつなぐ所。取り決め K34-1・K34-2（名前と形を変えない）。

lifelog_pc.py から呼ぶのは start(main)（s29pc.start のあと）・features(base)・GETS・http_get。
- GET /s34（オーナーの Bearer）: 母艦の state/s34_for_app.json をそのまま返す（K34-1）。
  大きすぎ・壊れ・無い・止めてある・母艦が無い → {"available": false, "reason": …}
  features "s34"（ファイルがあって止めていないとき）。止める切り替え: 母艦の state/s27_work_config.json の "s34p": {"s34": false}
- K34-2: HOME/s34p_status.json（HOME＝LifeLog PC の置き場。quality-daily.json と同じ所）に
  {auto_switch:[…], self_samples:{added, scenes:{home,work,out}}, people_samples:{added, waiting}} と省ける tuned を書く。
  self_samples.added＝この回に新しく入った自分の見本の数・scenes＝今ある場面ごとの数。
  people_samples.added＝採用した人の数（今まで）・waiting＝2 回目の日を待っている人の数。
- 裏の仕事（1 日 1 回。01:00〜05:00 か 08:30〜18:00 の、新しい区切りが待っていないとき。中で時刻を見て、時間外になったら切り上げる）:
  自6 自分の見本・自7 よく会う人の見本（s34pvoice.py）・自8 昨日の物差しと 7 日ごとの切り替え・自9 7 日ごとの合わせ直し（s34pswitch.py）。
  夜のほかの仕事（s29 の夜の正本の候補など）のあとに回すため、00 時台はしない。
- 円1 の受け口: 写真から読んだ文字は、今の POST /work/digest（s30pwork.py）がそのまま受ける（source "photo" など。形は変えない）。
config.json（書かなければオン）: "s34p_self_samples"・"s34p_people_samples"・"s34p_auto_switch"・"s34p_tune"・"s34p_daily"（裏の仕事ごと）。
記録（log.txt）には数だけ。名前・文は書かない。
"""

from __future__ import annotations

import datetime
import json
import os
import threading
import time
from pathlib import Path

import s27pwork
import s34pswitch
import s34pvoice
import voices

S34 = Path("state") / "s34_for_app.json"
GETS = ("/s34",)
STATUS = "s34p_status.json"
S34_READ_MAX = 12 * 1024 * 1024
TICK = 60.0
FIRST_WAIT = 420.0
BUDGET = 1500.0         # 仮: 1 回 25 分まで
START_HOUR = 1          # 00 時台は s26・s29 の夜に譲る


class S:
    main = None
    home: Path | None = None
    thread: threading.Thread | None = None
    done_day: str | None = None
    last: dict = {}


# MARK: - 切り替え・features・GET /s34


def _switch(base: Path | None) -> bool:
    if base is None:
        return True
    data, _ = s27pwork._load(base, s27pwork.CONFIG, 64 * 1024)
    mine = data.get("s34p") if isinstance(data, dict) else None
    value = mine.get("s34") if isinstance(mine, dict) else None
    return value if isinstance(value, bool) else True


def features(base: Path | None) -> list[str]:
    if base is None or not Path(base).is_dir() or not _switch(base):
        return []
    return ["s34"] if (Path(base) / S34).is_file() else []


def _off(reason: str) -> dict:
    return {"available": False, "reason": reason}


def read_s34(base: Path) -> dict:
    data, failure = s27pwork._load(base, S34, S34_READ_MAX)
    if data is None:
        return _off(s27pwork._reason("s34 のまとめ", failure))
    return data


def http_get(handler, path: str, query: str, base: Path | None) -> None:
    """GET /s34（合言葉は lifelog_pc.py が確かめてから）"""
    if base is not None and not Path(base).is_dir():
        base = None
    try:
        if base is None:
            handler.send_json(200, _off("母艦が見つかりません"))
        elif not _switch(base):
            handler.send_json(200, _off("止めてあります"))
        else:
            handler.send_json(200, read_s34(base))
    except Exception as error:  # noqa: BLE001
        handler.send_json(200, _off(f"読めませんでした: {type(error).__name__}"))


# MARK: - K34-2


def status(home: Path) -> dict:
    return {"version": 1, "generated_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
            "auto_switch": s34pswitch.for_app(home), "self_samples": s34pvoice.self_counts(home),
            "people_samples": s34pvoice.people_counts(home), "tuned": s34pswitch.tuned_for_app(home)}


def write_status(home: Path) -> dict:
    body = status(home)
    path = Path(home) / STATUS
    part = path.with_name(path.name + ".part")
    path.parent.mkdir(parents=True, exist_ok=True)
    part.write_text(json.dumps(body, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(part, path)
    return body


# MARK: - 裏の仕事


def heavy_now(moment: datetime.datetime | None = None) -> bool:
    moment = moment or datetime.datetime.now()
    return voices.heavy_ok(moment) and moment.hour >= START_HOUR   # 01:00〜05:00・08:30〜18:00


def _on(config: dict, name: str) -> bool:
    value = (config or {}).get(name)
    return value if isinstance(value, bool) else True


def daily(home: Path, base: Path | None, store, config: dict, today: datetime.date, deadline: float | None = None,
          clock=None) -> dict:
    """1 日 1 回の分。1 つが落ちても次へ。clock は時刻を返す関数（試しで差し替える）"""
    clock = clock or datetime.datetime.now
    out: dict = {}

    def still_ok() -> bool:
        return (deadline is None or time.time() <= deadline) and heavy_now(clock())

    def step(name: str, work, enabled: bool = True) -> None:
        if not enabled:
            out[name] = "off"
            return
        if not still_ok():
            out[name] = "時間外・時間切れ"
            return
        try:
            out[name] = work()
        except Exception as error:  # noqa: BLE001
            out[name] = {"error": type(error).__name__}

    me = {}

    def selves():
        body = s34pvoice.collect_self(home, base, store, today, still_ok)
        return {"added": body["added"], **body["counts"]}

    step("self", selves, _on(config, "s34p_self_samples"))

    def people():
        me["center"] = s34pvoice.self_center_of(home, store, today)
        body = s34pvoice.collect_people(home, base, store, today, me=me["center"], still_ok=still_ok)
        return {"adopted": len(body["adopted"]), "added": body["added"], "waiting": len(body["waiting"])}

    step("people", people, _on(config, "s34p_people_samples"))

    def measure():
        day = (today - datetime.timedelta(days=1)).isoformat()
        got = s34pswitch.measure_day(home, base, store, day)
        s34pswitch.record_measures(home, day, got)
        return {k: v.get("n") for k, v in got.items()}

    step("measure", measure)
    step("switch", lambda: s34pswitch.decide(home, config, today)["changed"])
    step("tune", lambda: {"tuned": s34pswitch.tune(home, base, store, config, today, still_ok=still_ok)["tuned"]})
    try:
        write_status(home)
    except OSError:
        pass
    return out


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


def _log(text: str) -> None:
    try:
        S.main.log(text)
    except Exception:  # noqa: BLE001
        pass


def tick(moment: datetime.datetime | None = None) -> dict | None:
    import jobfirst

    moment = moment or datetime.datetime.now()
    if S.home is None or S.done_day == moment.date().isoformat() or not heavy_now(moment) or jobfirst.busy():
        return None
    config = _config()
    if config.get("s34p_daily") is False:
        return None
    S.done_day = moment.date().isoformat()
    store = getattr(getattr(S.main, "App", None), "records", None)
    out = daily(S.home, _base(), store, config, moment.date(), deadline=time.time() + BUDGET)
    S.last = out
    _log("s34 の数: " + "・".join(f"{k} {v if not isinstance(v, dict) else ','.join(f'{a}={b}' for a, b in list(v.items())[:4])}"
                                   for k, v in out.items()))
    return out


def _loop() -> None:
    time.sleep(FIRST_WAIT)
    failed_at = 0.0
    while True:
        try:
            tick()
        except Exception as error:  # noqa: BLE001 — 裏の仕事が止まっても受け付けは続ける
            if time.time() - failed_at > 3600:
                failed_at = time.time()
                _log(f"s34 の見回りでつまずきました: {type(error).__name__}")
        time.sleep(TICK)


def start(main) -> None:
    S.main = main
    S.home = Path(main.HOME)
    try:
        s34pswitch.install(lambda: S.home, _config)
        s34pvoice.install(lambda: S.home, _config)
        if _config().get("s34p_tune") is not False:
            s34pswitch.apply_values(s34pswitch.current_values(S.home))
    except Exception as error:  # noqa: BLE001
        _log(f"s34 の包みを入れられませんでした: {type(error).__name__}")
    if S.thread is None:
        S.thread = threading.Thread(target=_loop, name="s34p", daemon=True)
        S.thread.start()
