"""LifeLog PC: 「自分を知ってもらう」s18 の家の PC の分をまとめて動かす口（2026-11-19）。

中身はそれぞれのモジュール（lifelog_pc.py には呼び出しの数行だけを足す）:
- 45・78 voicetone.py   声の調子の数字（速さ・高さ・間・笑い・雑音）・信用が低い会話の印・毎日の気分の見立て
- 47     honne.py       時計に話した独り言を「本音メモ」に分ける
- 63     voicefix.py    声で直す（「違う、〇〇さん」の読み解き → 今までの PC から直すと同じ edits）
- 69     llmroute.py    安い AI → 自信が低いものだけ高い AI（47 が使う）
- 70     voicesamples.py 本人が ○ を付けた会話から、よく会う人の声の見本の候補
- 71     selfvoice.py   自分の声の見本を 3 通りで取り直す流れと、場面ごとの数
- 72     asrlearn.py    本人が直した言葉を、聞き取りの後の直しの辞書に足す（黙って当てるのは段が auto のものだけ）
- 73     plauddoubt.py  PLAUD と食い違った行だけを「聞いて直す」に出す（母艦の比べの結果を使うだけ）

見回り: LOOP_S ごとに軽い所（今日と昨日）。重い所（声の高さ・自分の声の置き場所の音声）は voices.heavy_ok の時間だけ、
1 回 HEAVY_BUDGET_S 秒まで。初めの 1 回だけ、記録のある日を全部（軽い所だけ）作る（気分の見立ての比べる前の日のため）。
config.json の "knowme": false で全部止める。"knowme_mother_copy": false で母艦への写しだけ止める。
GET: /voice-tone?day=・/honne?days=・/voice-samples・/self-voice・/plaud-doubts
POST: /voice-fix・/conversation-ok（どれも iPhone の合言葉が要る）
"""

from __future__ import annotations

import datetime
import threading
import time
from pathlib import Path
from typing import Callable
from urllib.parse import parse_qs

import asrlearn
import honne
import plauddoubt
import selfvoice
import voicefix
import voices
import voicesamples
import voicetone

GETS = ("/voice-tone", "/honne", "/voice-samples", "/self-voice", "/plaud-doubts")
POSTS = (*voicefix.POSTS, *voicesamples.POSTS)
FEATURES = ("voicetone", "honne", "voicefix", "voicesamples", "selfvoice", "plauddoubt")
LOOP_S = 1800.0
HEAVY_BUDGET_S = 120.0     # 仮: 1 回の見回りで音声を読む秒の上限
HEAVY_DAYS = 7
FIRST_DAYS = 60


class State:
    home: Path | None = None
    store = None
    mother: Callable[[], Path] | None = None
    config: Callable[[], dict] = staticmethod(lambda: {})
    find_audio: Callable | None = None
    load_audio: Callable | None = None
    embed: Callable | None = None
    log: Callable[[str], None] = staticmethod(lambda _t: None)
    thread: threading.Thread | None = None
    first_done = False


def enabled() -> bool:
    return State.home is not None and State.store is not None and State.config().get("knowme") is not False


def extra_doubts(day: str, parsed: dict) -> tuple[dict[int, list[str]], set[int]]:
    """records.RecordStore.extra_doubts に入れる（73 の PLAUD・72 の辞書の仮の組）"""
    if not enabled():
        return {}, set()
    base = State.mother() if State.mother else None
    add, quiet = plauddoubt.doubts(base, day, parsed)
    for moment, reasons in asrlearn.tentative_doubts(State.home, parsed).items():
        add[moment] = add.get(moment, []) + [r for r in reasons if r not in add.get(moment, [])]
    return add, quiet


def _days(count: int, today: datetime.date) -> list[str]:
    return [(today - datetime.timedelta(days=i)).isoformat() for i in range(count)][::-1]


def _find_audio(name: str):
    if State.find_audio is not None:
        return State.find_audio(name)
    return State.store.audio_file(name)


def tick(now: datetime.datetime | None = None) -> dict:
    now = now or datetime.datetime.now()
    if not enabled():
        return {}
    config = State.config()
    base = State.mother() if State.mother else None
    copy = config.get("knowme_mother_copy") is not False
    today = now.date()
    out: dict = {}
    if not State.first_done:
        have = sorted(d["day"] for d in State.store.days())[-FIRST_DAYS:]
        voicetone.run(State.home, State.store, base, State.log, have, mother_copy=copy)
        State.first_done = True
    heavy = voices.heavy_ok(now) and State.load_audio is not None
    steps = (
        ("voicetone", lambda: voicetone.run(State.home, State.store, base, State.log,
                                            _days(HEAVY_DAYS if heavy else 2, today), _find_audio, State.load_audio,
                                            HEAVY_BUDGET_S if heavy else 0.0, mother_copy=copy)),
        ("honne", lambda: honne.run(State.home, State.store, base, config, State.log, _days(2, today), mother_copy=copy)),
        ("asrlearn", lambda: asrlearn.run(State.home, State.store, base, config, State.log, mother_copy=copy)),
        ("voicefix", lambda: voicefix.drain_inbox(State.home, base, State.store, State.log)),  # 時計から（母艦の inbox）
        ("voicesamples", lambda: voicesamples.build(State.home, State.store, today)),
        ("selfvoice", lambda: selfvoice.build(State.home, State.store, State.embed, today, heavy=heavy)),
    )
    for name, step in steps:
        try:
            step()
            out[name] = "ok"
        except Exception as error:  # noqa: BLE001 — 1 つが失敗しても、ほかは続ける
            out[name] = type(error).__name__
            State.log(f"自分を知る（{name}）: {type(error).__name__}")
    return out


def _loop() -> None:
    time.sleep(60)
    while True:
        tick()
        time.sleep(LOOP_S)


def start(home: Path, store, mother: Callable[[], Path] | None, config: Callable[[], dict],
          load_audio: Callable | None, embed: Callable | None, log: Callable[[str], None]) -> None:
    State.home, State.store, State.mother, State.config = Path(home), store, mother, config
    State.load_audio, State.embed, State.log = load_audio, embed, log
    if store is None or State.thread is not None:
        return
    store.extra_doubts = extra_doubts
    State.thread = threading.Thread(target=_loop, name="knowme", daemon=True)
    State.thread.start()


def features() -> list[str]:
    return list(FEATURES) if enabled() else []


def http_get(handler, path: str, query: str) -> None:
    if not enabled():
        handler.send_json(200, {"available": False})
        return
    q = parse_qs(query or "")
    if path == "/voice-tone":
        day = (q.get("day") or [datetime.date.today().isoformat()])[0]
        data = voicetone.read_json(State.home / voicetone.FOLDER / f"{day}.json") if len(day) == 10 else None
        handler.send_json(200, {"available": True, **data} if data else {"available": False})
    elif path == "/honne":
        try:
            days = int((q.get("days") or ["7"])[0])
        except ValueError:
            days = 7
        handler.send_json(200, honne.read_recent(State.home, days))
    elif path == "/voice-samples":
        handler.send_json(200, voicesamples.read(State.home))
    elif path == "/self-voice":
        handler.send_json(200, selfvoice.read(State.home))
    elif path == "/plaud-doubts":
        handler.send_json(200, plauddoubt.listing(State.mother() if State.mother else None, State.store))
    else:
        handler.send_json(404, {"error": "not found"})


def http_post(handler, path: str, log: Callable[[str], None]) -> None:
    if not enabled():
        handler.send_json(503, {"error": "使えません"})
        return
    if path in voicefix.POSTS:
        voicefix.http_post(handler, State.home, State.store, log)
    else:
        voicesamples.http_post(handler, State.home, log)
