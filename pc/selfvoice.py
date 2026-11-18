"""LifeLog PC: 本人の声の見本を「静か・騒がしい・電話」の 3 通りで取り直す流れ（s18 の 71。2026-11-19）。

録るのは本人（アプリの今ある画面。新しい録音の仕組みは作らない）:
  アプリ →「直す」→「自分の声」→「もう一度録って足す（20秒）」を、下の 3 つの場面で 1 回ずつ（録り直すと前の登録に足す）。
  何を言えばよいか: SCRIPTS の文を声に出して読む（20 秒ほど。ふだんの話し方で）。
PC がすること（測るだけ。声の登録はアプリの中にあり、PC からは変えない）:
- 場面ごとに、自分の行の声の特徴（voices/<日>.npz に置いてあるもの。新しくは測らない）が、静かな所の自分の声の真ん中に
  どれだけ近いか（cos の中央値・FAR（仮）未満の割合）を毎日測り、history に残す。録り直しの前と後で比べられる。
  静か＝騒がしい印も周りの音も無い行／騒がしい＝騒がしい印か周りの音のある行／電話＝記録に電話の印が無いので、
  下の置き場所に本人が置いた電話の録音だけ（置かなければ "測れない"）。
- 置き場所（任意）: HOME/knowme/self-voice/quiet・noisy・phone/ に本人が録った音声（m4a・wav）を置くと、
  その声と自分の声の真ん中の近さも測る（embed は PC の CAM++。重いので voices.heavy_ok の時間だけ）。
- GET /self-voice → 手順（steps・scripts）と、場面ごとの数（features の "selfvoice"）。HOME/knowme/self-voice.json。
記録（log.txt）には数だけ。
"""

from __future__ import annotations

import datetime
import statistics
from pathlib import Path
from typing import Callable

import numpy as np

import voices
import voicetone

OUT = Path("knowme") / "self-voice.json"
DROP = Path("knowme") / "self-voice"
CONDITIONS = ("quiet", "noisy", "phone")
FAR = 0.5            # 仮: 真ん中との近さがこれ未満の自分の行は「遠い」（見分けを外しやすい）
SCAN_DAYS = 14
HISTORY_KEEP = 90
STEPS = [
    "アプリの「直す」→「自分の声」を開く",
    "静かな部屋で「もう一度録って足す（20秒）」を押し、下の文を読む",
    "テレビをつけた部屋・お店など、周りの音がある所で、もう一度録って足す",
    "電話をスピーカーにして話しているときの声で（電話の相手に断ってから、自分の声だけ）、もう一度録って足す",
    "数日たってから、この画面の「遠い行の割合」が下がったかを見る",
]
SCRIPTS = {
    "quiet": "今日は朝から天気がよくて、駅まで歩いて行きました。途中でパン屋に寄って、いつものパンを二つ買いました。",
    "noisy": "このあと何時に集まるか決めよう。先に席を取っておくから、着いたら連絡してね。",
    "phone": "もしもし、いま大丈夫？さっきの件だけど、来週の水曜日で進めようと思ってる。",
}


def condition(line: dict) -> str:
    return "noisy" if line.get("noisy") or line.get("sound") else "quiet"


def gather(home: Path, store, today: datetime.date) -> dict[str, list[np.ndarray]]:
    out: dict[str, list[np.ndarray]] = {"quiet": [], "noisy": []}
    for i in range(SCAN_DAYS):
        day = (today - datetime.timedelta(days=i)).isoformat()
        parsed = store.day(day)
        if parsed is None:
            continue
        ds = voices.DayStore(home, day).load()
        if not ds.vectors:
            continue
        for seg in voices.segments(parsed):
            if seg["label"] != voices.SELF_LABEL:
                continue
            vec = ds.vectors.get(seg["key"])
            unit = voices._unit(np.asarray(vec, dtype=np.float32)) if vec is not None else None
            if unit is not None:
                out[condition(seg["line"])].append(unit)
    return out


def measure(units: list[np.ndarray], center: np.ndarray | None) -> dict:
    if center is None or not units:
        return {"lines": len(units), "median": None, "far_share": None}
    sims = [float(u @ center) for u in units]
    return {"lines": len(units), "median": round(statistics.median(sims), 3),
            "far_share": round(sum(1 for s in sims if s < FAR) / len(sims), 3)}


def dropped(home: Path, center: np.ndarray | None, embed: Callable | None, deadline_ok: bool) -> dict:
    out = {}
    for cond in CONDITIONS:
        files = sorted(p for p in (home / DROP / cond).glob("*") if p.suffix.lower() in (".m4a", ".wav", ".mp3", ".aac"))
        entry: dict = {"files": len(files)}
        if files and center is not None and embed is not None and deadline_ok:
            sims = []
            for path in files[:10]:
                try:
                    got = embed(path, [(0.0, 20.0)])
                except Exception:  # noqa: BLE001
                    continue
                unit = voices._unit(np.asarray(got[0], dtype=np.float32)) if got and got[0] is not None else None
                if unit is not None:
                    sims.append(float(unit @ center))
            entry["similarity"] = [round(s, 3) for s in sims]
        out[cond] = entry
    return out


def build(home: Path, store, embed: Callable | None = None, today: datetime.date | None = None,
          heavy: bool = False) -> dict:
    today = today or datetime.date.today()
    units = gather(home, store, today)
    center = voices._unit(np.mean(units["quiet"], axis=0)) if len(units["quiet"]) >= 5 else None
    numbers = {"quiet": measure(units["quiet"], center), "noisy": measure(units["noisy"], center),
               "phone": {"lines": None, "median": None, "far_share": None, "note": "記録に電話の印が無いので測れない"}}
    old = voicetone.read_json(home / OUT) or {}
    history = [h for h in old.get("history") or [] if h.get("day") != today.isoformat()]
    history.append({"day": today.isoformat(), **{c: {k: v for k, v in numbers[c].items() if k != "note"}
                                                 for c in ("quiet", "noisy")}})
    out = {"version": 1, "made_on": today.isoformat(), "steps": STEPS, "scripts": SCRIPTS, "numbers": numbers,
           "dropped": dropped(home, center, embed, heavy) if embed is not None else
           {c: {"files": len(list((home / DROP / c).glob("*")))} for c in CONDITIONS},
           "history": history[-HISTORY_KEEP:], "thresholds": {"far": FAR, "仮": True}}
    voicetone._write(home / OUT, out)
    return out


def read(home: Path) -> dict:
    data = voicetone.read_json(home / OUT)
    return {"available": True, **data} if data else {"available": True, "steps": STEPS, "scripts": SCRIPTS}
