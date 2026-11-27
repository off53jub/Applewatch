"""LifeLog PC: s29（2026-11-27。担当 P）声9・声25・声26。答えた組で測り、影のものを本番にする条件を 1 か所に書く。0 円。

声の特徴は HOME/voices/<日>.npz の今までのもの（新しく測らない・モデルを動かさない）。記録の話し手は変えない。

声9 同じ人かの点を s-norm に切り替える条件（"7 晩" をやめた）:
  答えた組（s23voice の答え・s29panswers の答え）のうち、両側の声の特徴が置いてある組で、今の点（日の平均を引いた真ん中の近さ）と
  s-norm の AUC を毎晩出す。組が SNORM_NEED 組（12・仮）以上・同じ人と違う人がそれぞれ SIDE_MIN 組（4・仮）以上で、
  s-norm の AUC ≥ 今の AUC + SNORM_MARGIN（0.05・仮）なら「s-norm のほうが良い」。足りないうちは "raw"（今の点のまま）。
  判断は毎晩 HOME/s29p/snorm-decisions.jsonl に 1 行・quality-daily.json の昨日に省ける "s29_snorm"。
  使うかどうかは config.json の "s29p_snorm_score": "candidate"（既定。候補に出すだけ）| "on"（判断が s-norm の晩だけ
  GET /same-person の組を s-norm の高い順に並べる。"score" は前のまま）| "off"。
声25 分け間違い（毎晩 1 つの数）: quality-daily.json の days[<日>].speaker_split_wrong = {"wrong": 数, "pairs": 数}
  （母艦の Build-Accuracy.py が読む名前。数が 1 つも無い晩は書かない）。数えるのは
  - 答えた組: 答える前に iPhone の分けが同じ人としていたか（orig_same）と、本人の答えが違った組
  - 3 つのマイクが合った所: 同じ時に iPhone と時計の両方が書いた同じ発話（時刻 1.5 秒・文の近さ 0.6・仮）で、話し手の印が違った所
  内訳は省ける "s29_split_detail"（PLAUD の話し手との食い違いは内訳だけ。PLAUD の分けも正解ではないので数には入れない）。
声26 本番入りの条件（GATES。ここ 1 か所）: どれも「答えた組で良くなったら」。条件を満たしても自動で本番にしない（"candidate" に
  出すだけ）。数は config.json の "s29p_gates": {"<名前>": {"need": 数, "margin": 数}} で上書きできる（どれも仮）。
  結果は毎晩 HOME/s29p/gates.json（GET /s29/gates）。
"""

from __future__ import annotations

import bisect
import datetime
import difflib
import json
import os
import re
import time
from pathlib import Path

import numpy as np

import voices

SNORM_NEED, SIDE_MIN, SNORM_MARGIN = 12, 4, 0.05     # 声9（仮）
LINK = 0.60          # 今の点で「同じ人かも」にする近さ（sameperson.LINK と同じ）
COHORT = 300
MIC_DT, MIC_TEXT = 1.5, 0.6                          # 声25（仮）
WATCH = re.compile(r"-w\.m4a$")

# 声26: 影・既定オフのものの本番入りの条件（ここ 1 か所）。config は今そのものを動かす名前（既定は s26pc.DEFAULTS・s29pc.DEFAULTS）。
# metric は比べる物差し。need は要る数（組・行）・margin は「良くなった」とみなす差（どれも仮）
GATES = {
    "snorm": {"label": "同じ人かの点を s-norm に（声9）", "config": "s29p_snorm_score", "metric": "答えた組の AUC（s-norm 対 今の点）",
              "need": SNORM_NEED, "margin": SNORM_MARGIN},
    "day_diar": {"label": "1 日まるごとの話し手分け（聞4）", "config": "s26p_day_diar",
                 "metric": "答えた組の当たり（1 日まるごとのかたまり 対 iPhone の分け）", "need": SNORM_NEED, "margin": 0.05},
    "canonical": {"label": "夜の分け直しを正本に（声5・声7・声12・声13）", "config": "s29p_canonical",
                  "metric": "答えた組の当たり（正本の候補 対 iPhone の分け）", "need": SNORM_NEED, "margin": 0.05},
    "separate": {"label": "重なりを 2 本に分ける（聞6・声6）", "config": "s26p_separate",
                 "metric": "重なりの行の PLAUD と合った字の割合（分けた 対 分けない）", "need": 30, "margin": 0.02},
    "boost": {"label": "小さい相手の声を持ち上げる（聞15）", "config": "s26p_boost",
              "metric": "持ち上げた行の PLAUD と合った字の割合（上げた 対 前）", "need": 30, "margin": 0.02},
    "denoise_embed": {"label": "雑音を消してから声の特徴（声3）", "config": "s29p_denoise_embed",
                      "metric": "答えた組の AUC（消した音 対 消さない音）", "need": SNORM_NEED, "margin": 0.05},
    "two_mic": {"label": "iPhone と時計の 2 本で自分／相手（声2）", "config": "s29p_two_mic",
                "metric": "自分の行を当てる AUC（2 本の大きさの差 対 1 本の大きさ）", "need": 30, "margin": 0.05},
}


def folder(home: Path) -> Path:
    return Path(home) / "s29p"


def _read(path: Path, default=None):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return default


def _write(path: Path, body) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    part = path.with_name(path.name + ".part")
    part.write_text(json.dumps(body, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(part, path)


def _append(path: Path, row: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")


# MARK: - 答えた組を集める


def answered_pairs(home: Path, base: Path | None) -> list[dict]:
    """[{"id","same","people","day","orig_same"?}]（s23voice の前の形の答え ＋ s29panswers の答え。あとの答えが勝つ）"""
    import s23voice
    import s29panswers

    out: dict[str, dict] = {}
    known = s23voice.answers(base)
    groups = s23voice.groups_with_samples(home)
    for gid, same in known.items():
        group = groups.get(gid)
        if group and len(group.get("people") or []) >= 2:
            out[gid] = {"id": gid, "same": same, "people": group["people"][:2], "day": str(group.get("day") or ""),
                        "orig_same": False if gid.startswith(("sp-", "sx-", "pm-")) else None}
    for gid, row in s29panswers.load(home)["pairs"].items():
        if isinstance(row, dict) and isinstance(row.get("people"), list) and len(row["people"]) >= 2:
            out[gid] = {"id": gid, "same": bool(row.get("same")), "people": row["people"][:2], "day": str(row.get("day") or ""),
                        "orig_same": row.get("orig_same")}
    return sorted(out.values(), key=lambda p: (p["day"], p["id"]))


def _days_of(sample: dict, day: str) -> list[str]:
    out = [day] if day else []
    m = re.match(r"(\d{4})(\d{2})(\d{2})", str(sample.get("audio") or ""))
    if m:
        d = datetime.date(int(m[1]), int(m[2]), int(m[3]))
        for x in (d, d - datetime.timedelta(days=1), d + datetime.timedelta(days=1)):
            if x.isoformat() not in out:
                out.append(x.isoformat())
    return out


class Vectors:
    """答えた組の見本 → 置いてある声の特徴（長さ 1。測っていなければ None）。日ごとの npz は 1 回だけ読む"""

    def __init__(self, home: Path) -> None:
        self.home = home
        self.days: dict[str, dict] = {}

    def day(self, day: str) -> dict:
        if day not in self.days:
            self.days[day] = voices.DayStore(self.home, day).load().vectors if re.fullmatch(r"\d{4}-\d{2}-\d{2}", day) else {}
        return self.days[day]

    def __call__(self, sample: dict, day: str = "") -> np.ndarray | None:
        key = voices.seg_key(sample["audio"], sample["start"], sample["end"])
        for d in ([sample["_day"]] if sample.get("_day") else _days_of(sample, day or sample.get("day") or "")):
            v = self.day(d).get(key)
            if v is not None:
                return voices._unit(np.asarray(v, np.float64))
        return None

    def cohort(self, days: list[str], limit: int = COHORT) -> list[dict]:
        keys = [(d, k) for d in sorted(set(days)) for k in sorted(self.day(d))]
        step = max(1, len(keys) // max(1, limit))
        rows = []
        for d, key in keys[::step][:limit]:
            audio, start, end = key.rsplit("|", 2)
            rows.append({"audio": audio, "start": float(start), "end": float(end), "_day": d})
        return rows


def score_pairs(home: Path, pairs: list[dict], vec=None) -> dict:
    """答えた組の今の点と s-norm（s23voice.pair_scores）。vec を渡せば作りものの声で試せる"""
    import s23voice

    vec = vec or Vectors(home)
    tagged = []
    days = []
    for p in pairs:
        people = [[dict(s, day=p["day"]) for s in side] for side in p["people"][:2]]
        tagged.append({**p, "people": people})
        for side in people:
            for s in side:
                days += _days_of(s, p["day"])[:1]
    cohort = vec.cohort(days) if hasattr(vec, "cohort") else []
    got = s23voice.pair_scores(lambda s: vec(s), tagged, cohort)
    got["different"] = got["pairs"] - got["same"]
    return got


# MARK: - 声9


def snorm_decide(got: dict, need: int = SNORM_NEED, margin: float = SNORM_MARGIN, side_min: int = SIDE_MIN) -> dict:
    pairs, same = int(got.get("pairs") or 0), int(got.get("same") or 0)
    raw, sn = got.get("auc_raw"), got.get("auc_snorm")
    out = {"pairs": pairs, "same": same, "different": pairs - same, "auc_raw": raw, "auc_snorm": sn,
           "need": need, "margin": margin, "side_min": side_min}
    if pairs < need or same < side_min or pairs - same < side_min:
        out.update(decision="raw", reason=f"答えた組が足りない（{pairs}/{need}・同じ {same}・違う {pairs - same}・それぞれ {side_min} から）")
    elif raw is None or sn is None:
        out.update(decision="raw", reason="AUC が出せない")
    elif sn >= raw + margin:
        out.update(decision="snorm", reason=f"s-norm {sn:.2f} ≥ 今 {raw:.2f} + {margin}")
    else:
        out.update(decision="raw", reason=f"s-norm {sn:.2f} が 今 {raw:.2f} + {margin} に届かない")
    return out


def latest_decision(home: Path) -> dict | None:
    try:
        rows = (folder(home) / "snorm-decisions.jsonl").read_text(encoding="utf-8").splitlines()
    except OSError:
        return None
    for raw in reversed(rows):
        try:
            row = json.loads(raw)
        except ValueError:
            continue
        if isinstance(row, dict):
            return row
    return None


def snorm_mode(config: dict | None) -> str:
    value = (config or {}).get("s29p_snorm_score")
    return value if value in ("candidate", "on", "off") else "candidate"


def apply_snorm(body: dict, home: Path, config: dict | None) -> dict:
    """GET /same-person: "on" で、いちばん新しい判断が s-norm の晩だけ、組を s-norm の高い順に（"score" は前のまま）。
    どの場合も省ける "s29_score": "raw" | "snorm" を足す"""
    if not isinstance(body, dict):
        return body
    decision = latest_decision(home) or {}
    use = snorm_mode(config) == "on" and decision.get("decision") == "snorm"
    out = dict(body)
    out["s29_score"] = "snorm" if use else "raw"
    if not use:
        return out

    def order(items):
        return sorted(items, key=lambda g: -(g.get("snorm") if isinstance(g.get("snorm"), (int, float)) else -1e9))

    out["days"] = [{**d, "groups": order(d.get("groups") or [])} if isinstance(d, dict) else d for d in body.get("days") or []]
    if isinstance(body.get("across"), list):
        out["across"] = order(body["across"])
    return out


# MARK: - 声25


def _norm_text(text) -> str:
    return re.sub(r"[\s、。！？!?,.・「」『』（）()ー〜…]", "", str(text or ""))


def _ms(value) -> float | None:
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return float(value)
    try:
        return datetime.datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp() * 1000
    except ValueError:
        return None


def mic_checks(parsed: dict | None, dt: float = MIC_DT, text_min: float = MIC_TEXT) -> dict:
    """同じ時に iPhone と時計の両方が書いた同じ発話で、話し手の印が違った所。{"checks","wrong"}"""
    phone, watch = [], []
    for conversation in (parsed or {}).get("conversations") or []:
        if conversation.get("media"):
            continue
        for line in conversation.get("lines") or []:
            audio = line.get("audio")
            t = _ms(line.get("time"))
            if not isinstance(audio, str) or t is None or line.get("media") is not None:
                continue
            label = voices.label_of(line)
            text = _norm_text(line.get("text"))
            if label is None or len(text) < 4:
                continue
            (watch if WATCH.search(audio) else phone).append((t, text, label))
    phone.sort()
    times = [p[0] for p in phone]
    out = {"checks": 0, "wrong": 0}
    for t, text, label in watch:
        best = None
        for pt, ptext, plabel in phone[bisect.bisect_left(times, t - dt * 1000):bisect.bisect_right(times, t + dt * 1000)]:
            ratio = difflib.SequenceMatcher(None, text, ptext).ratio()
            if ratio >= text_min and (best is None or ratio > best[0]):
                best = (ratio, plabel)
        if best is not None:
            out["checks"] += 1
            out["wrong"] += best[1] != label
    return out


def plaud_detail(base: Path | None, days: list[str]) -> dict:
    """母艦 digests/canonical/<日>.json の PLAUD の話し手と iPhone の話し手の食い違い（s29m と同じ数え方・内訳だけ）"""
    out = {"compared": 0, "either": 0}
    if base is None:
        return out
    for day in days:
        body = _read(Path(base) / "digests" / "canonical" / f"{day}.json", None)
        if not isinstance(body, dict):
            continue
        by_rec: dict[str, list[tuple[str, str]]] = {}
        for x in body.get("lines") or []:
            if not isinstance(x, dict) or x.get("source") != "plaud" or x.get("speaker_how") != "line":
                continue
            if x.get("plaud_speaker") and x.get("speaker_id"):
                by_rec.setdefault(str(x.get("rec")), []).append((str(x["plaud_speaker"]), str(x["speaker_id"])))
        for rows in by_rec.values():
            to_app: dict[str, dict] = {}
            to_plaud: dict[str, dict] = {}
            for p, a in rows:
                to_app.setdefault(p, {}).setdefault(a, 0)
                to_app[p][a] += 1
                to_plaud.setdefault(a, {}).setdefault(p, 0)
                to_plaud[a][p] += 1
            major_app = {p: max(c, key=c.get) for p, c in to_app.items()}
            major_plaud = {a: max(c, key=c.get) for a, c in to_plaud.items()}
            for p, a in rows:
                out["compared"] += 1
                out["either"] += a != major_app[p] or p != major_plaud[a]
    return out


def split_wrong(home: Path, base: Path | None, pairs: list[dict], read_day, day: str, scored: dict | None = None) -> dict:
    """{"speaker_split_wrong": {"wrong","pairs"} か None, "s29_split_detail": {...}}"""
    with_orig = [p for p in pairs if isinstance(p.get("orig_same"), bool)]
    answer_wrong = sum(1 for p in with_orig if p["orig_same"] != p["same"])
    mic = mic_checks(read_day(day) if read_day is not None else None)
    detail = {"answer_pairs": len(with_orig), "answer_wrong": answer_wrong, "mic_checks": mic["checks"], "mic_wrong": mic["wrong"]}
    if scored and scored.get("scored"):
        rows = scored["scored"]
        detail["point_pairs"] = len(rows)
        detail["point_wrong"] = sum(1 for r in rows if (r["raw"] >= LINK) != r["same"])
    plaud = plaud_detail(base, [day])
    detail["plaud_compared"], detail["plaud_either"] = plaud["compared"], plaud["either"]
    total = len(with_orig) + mic["checks"]
    main = {"wrong": answer_wrong + mic["wrong"], "pairs": total} if total else None
    return {"speaker_split_wrong": main, "s29_split_detail": detail}


# MARK: - 声26


def gate_settings(config: dict | None) -> dict[str, dict]:
    over = (config or {}).get("s29p_gates")
    over = over if isinstance(over, dict) else {}
    out = {}
    for name, gate in GATES.items():
        g = dict(gate)
        mine = over.get(name) if isinstance(over.get(name), dict) else {}
        if isinstance(mine.get("need"), int) and not isinstance(mine.get("need"), bool) and mine["need"] > 0:
            g["need"] = mine["need"]
        if isinstance(mine.get("margin"), (int, float)) and not isinstance(mine.get("margin"), bool) and mine["margin"] >= 0:
            g["margin"] = float(mine["margin"])
        out[name] = g
    return out


def judge(gate: dict, measure: dict | None) -> dict:
    """measure = {"n","now","new"}（大きいほど良い）。返すのは candidate（本番の候補か）と理由。自動では本番にしない"""
    row = {"need": gate["need"], "margin": gate["margin"], "n": None, "now": None, "new": None, "candidate": False}
    if not isinstance(measure, dict) or measure.get("n") is None:
        row["why"] = "材料なし"
        return row
    row.update(n=measure["n"], now=measure.get("now"), new=measure.get("new"))
    if measure["n"] < gate["need"]:
        row["why"] = f"数が足りない（{measure['n']}/{gate['need']}）"
    elif row["now"] is None or row["new"] is None:
        row["why"] = "比べられない"
    elif row["new"] >= row["now"] + gate["margin"]:
        row["candidate"] = True
        row["why"] = f"良くなった（{row['new']:.3f} ≥ {row['now']:.3f} + {gate['margin']}）。本人が config で切り替えるまで影のまま"
    else:
        row["why"] = f"良くなっていない（{row['new']:.3f} < {row['now']:.3f} + {gate['margin']}）"
    return row


def gates_status(config: dict | None, measures: dict[str, dict | None], states: dict[str, str]) -> dict:
    out = {}
    for name, gate in gate_settings(config).items():
        out[name] = {"label": gate["label"], "config": gate["config"], "metric": gate["metric"],
                     "state": states.get(name, "shadow"), **judge(gate, measures.get(name))}
    return {"generated_at": datetime.datetime.now().isoformat(timespec="seconds"), "auto_promote": False,
            "note": "条件を満たしても自動で本番にしない（candidate を出すだけ）。数はどれも仮", "gates": out}


def accuracy(pairs: list[dict], same_of) -> dict:
    """答えた組で、same_of(組) が返す「同じ人とみたか」（None は数えない）の当たり。{"n","right"}"""
    n = right = 0
    for p in pairs:
        guess = same_of(p)
        if guess is None:
            continue
        n += 1
        right += guess == p["same"]
    return {"n": n, "right": right, "rate": round(right / n, 3) if n else None}


def write_gates(home: Path, body: dict) -> None:
    _write(folder(home) / "gates.json", body)


def read_gates(home: Path) -> dict:
    body = _read(folder(home) / "gates.json", None)
    if not isinstance(body, dict):
        return {"available": False, "reason": "まだ測っていません（00:00〜05:00）"}
    return {"available": True, **body}


def record_decision(home: Path, decision: dict, day: str) -> None:
    _append(folder(home) / "snorm-decisions.jsonl", {"day": day, "at": datetime.datetime.now().isoformat(timespec="seconds"),
                                                     **{k: decision.get(k) for k in ("pairs", "same", "different", "auc_raw",
                                                                                     "auc_snorm", "need", "margin", "decision",
                                                                                     "reason")}})


def _now() -> float:
    return time.time()
