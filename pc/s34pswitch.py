"""LifeLog PC: s34（2026-11-27。担当 p）自8・自9 — 影のものを機械の物差しで本番にする／仮の数を毎週合わせ直す。0 円・言語モデルなし。

物差し（本人の答えは待たない。どちらも機械どうしの答え合わせ）:
- 時計と iPhone の 2 本のマイクが合った所: 同じ時に両方が書いた同じ発話（時刻 MIC_DT 秒・文の近さ MIC_TEXT・仮）で、
  話し手の印も同じだった行は「確か」。確かな行どうしで、同じ印なら同じ人・同じ会話で違う印なら違う人の組にする。
- PLAUD と合った所: 母艦 digests/canonical/<日>.json の PLAUD の行と結べたアプリの行（s34pvoice.plaud_rows）。
  同じ録音の中で、PLAUD の話し手が同じなら同じ人・違えば違う人。PLAUD の分けも正解ではない（11/27 の測りで 48.5% 食い違い）ので、
  「PLAUD と合う割合が上がったか」を見るだけ（仮）。声の点の組（AUC）には、PLAUD とアプリの向きが互いに合った行だけを使う。

自8 自動で本番・自動で戻す（"s34p_auto_switch"。既定オン。false なら数えるだけで切り替えない）:
  SWITCHES の各々を毎晩測り（HOME/s34p/measures.jsonl）、7 日ごとに 7 日ぶんを合わせて決める（HOME/s34p/switch.json）。
  - 影（shadow・rolled_back から COOL_DAYS 日たったもの）: 数が need 以上で、新しいやり方 ≥ 今のやり方 + margin → on
  - on: 次の週に、新しいやり方 < 今のやり方、または 前の週の値 − DROP より下 → rolled_back（戻す）
  切り替えは HOME/s34p/switch-log.jsonl に 1 行（いつ・何を・どの数で）。本人が config.json にその名前を書いていれば、
  本人の値がいつも上（自動では動かさない・"by": "本人"）。
  本番の中身は今ある口だけ: snorm＝GET /same-person の並びを s-norm に・canonical＝GET /s29/canonical に付け直し案を出す・
  day_diar＝夜に 1 日まるごとの分けを毎晩作る。boost・denoise_embed・two_mic は本番の口がまだ無いので測るだけ。
  separate は speechbrain を入れるかの判断が要る（入れない）。
自9 仮の数を毎週合わせ直す（"s34p_tune"。既定オン。false なら元の値に戻す）:
  TUNABLES を 7 日ごとに、決めた幅（range）の中・1 回に max_move まで動かす。元の値（コードの値）は "old" に控える。
  加点は PLAUD と結べた「名前の無い声 × 名前のある人」の組（手がかりのある時間だけ）で、点＋加点 ≥ voices.NAMED_MIN の当たりがいちばん
  良い値。近さのしきいは機械の組の当たり（同じ人・違う人のつり合いをとった割合）がいちばん良い値。材料が足りなければ動かさない。
  HOME/s34p/tuned.json・tuned-log.jsonl。本人が config.json に同じ数（"s22_voice" の prior_bonus・chain_link）を書いていれば本人の値が上。
重い計算（記録と声の特徴を読む）は voices.heavy_ok の時間（00:00〜05:00・08:30〜18:00）だけ。呼ぶ側が時刻を見て切り上げる。
"""

from __future__ import annotations

import bisect
import datetime
import difflib
import json
import os
import re
import threading
from pathlib import Path

import voices

FOLDER = "s34p"
WEEK = 7
COOL_DAYS = 14         # 仮: 戻したものを、もう一度本番にしてよいまでの日数
DROP = 0.03            # 仮: 前の週の値からこれだけ落ちたら戻す
MIN_DAYS = 3           # 仮: 本番にするのに要る、測れた日の数（7 日のうち）
MIC_DT, MIC_TEXT = 1.5, 0.6
PAIRS_PER_DAY = 200
PLAUD_PAIRS_PER_REC = 150
TUNE_NEED_BONUS = 20   # 仮
TUNE_NEED_LINK = 30    # 仮
WATCH = re.compile(r"-w\.m4a$")

# 自8: 影のもの。config は今そのものを動かす名前。on は本番の値。prod は本番の中身（None は本番の口がまだ無い）
SWITCHES = {
    "snorm": {"label": "同じ人かの点を s-norm に（声9）", "config": "s29p_snorm_score", "on": "on",
              "metric": "機械の組（2 本のマイク・PLAUD が合った所）の AUC（s-norm 対 今の点）", "need": 30, "margin": 0.03,
              "prod": "GET /same-person の並びを s-norm の高い順に"},
    "canonical": {"label": "夜の分け直しを正本に（声5・1 日まるごとの分けに手がかりを重ねたもの）", "config": "s29p_canonical", "on": True,
                  "metric": "PLAUD と合った所の話し手の当たり（夜の分け直し 対 iPhone の分け）", "need": 40, "margin": 0.02,
                  "prod": "GET /s29/canonical に付け直し案を出す（付け直すのは本人の端末）"},
    "day_diar": {"label": "1 日まるごとの話し手分け（聞4）", "config": "s26p_day_diar", "on": True,
                 "metric": "PLAUD と合った所の話し手の当たり（1 日まるごとのかたまり 対 iPhone の分け）", "need": 40, "margin": 0.02,
                 "prod": "夜に 1 日まるごとの分けを毎晩作る（HOME/s26p/day-diar）"},
    "boost": {"label": "小さい相手の声を持ち上げる（聞15）", "config": "s26p_boost", "on": True,
              "metric": "持ち上げた行の PLAUD と合った字の割合（上げた 対 前）", "need": 30, "margin": 0.02, "prod": None,
              "why_not": "持ち上げた文を記録に入れる口がまだ無い（影で比べるだけ）"},
    "separate": {"label": "重なりを 2 本に分ける（聞6）", "config": "s26p_separate", "on": True,
                 "metric": "重なりの行の PLAUD と合った字の割合（分けた 対 分けない）", "need": 30, "margin": 0.02, "prod": None,
                 "why_not": "判断が要る（speechbrain を入れるか。入れない）", "decision": True},
    "denoise_embed": {"label": "雑音を消してから声の特徴（声3）", "config": "s29p_denoise_embed", "on": True,
                      "metric": "答えた組の AUC（消した音 対 消さない音）", "need": 12, "margin": 0.05, "prod": None,
                      "why_not": "雑音を消した声の特徴を照らしに使う口がまだ無い（モデルが手元にあるときだけ影で比べる）"},
    "two_mic": {"label": "iPhone と時計の 2 本で自分／相手（声2）", "config": "s29p_two_mic", "on": True,
                "metric": "自分の行を当てる AUC（2 本の大きさの差 対 1 本の大きさ）", "need": 30, "margin": 0.05, "prod": None,
                "why_not": "2 本の差で話し手の印を付ける口がまだ無い（影で数えるだけ）"},
}
AUTO = tuple(k for k, v in SWITCHES.items() if v["prod"])

# 自9: 家の PC の仮の数。range の中・1 回に max_move まで
TUNABLES = {
    "prior_bonus": {"label": "いそうな人の加点（s22 確5）", "range": [0.01, 0.05], "step": 0.005, "max_move": 0.01,
                    "kind": "bonus", "hint": "prior"},
    "guess_bonus": {"label": "場面の見込みの加点（s26 結1）", "range": [0.02, 0.08], "step": 0.005, "max_move": 0.01,
                    "kind": "bonus", "hint": "guess"},
    "meeting_bonus": {"label": "会議の出席者の加点（s32 知9）", "range": [0.02, 0.05], "step": 0.005, "max_move": 0.01,
                      "kind": "bonus", "hint": "meeting"},
    "group_link": {"label": "名前の無い声のかたまりの近さ（s29 声19）", "range": [0.50, 0.70], "step": 0.05, "max_move": 0.05,
                   "kind": "link"},
    "chain_link": {"label": "区切りをまたいで声をつなぐ近さ（s22 確3）", "range": [0.45, 0.65], "step": 0.05, "max_move": 0.05,
                   "kind": "link"},
}


def folder(home: Path) -> Path:
    return Path(home) / FOLDER


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
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")


def _jsonl(path: Path) -> list[dict]:
    try:
        rows = Path(path).read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    out = []
    for raw in rows:
        try:
            row = json.loads(raw)
        except ValueError:
            continue
        if isinstance(row, dict):
            out.append(row)
    return out


def _now() -> str:
    return datetime.datetime.now().isoformat(timespec="seconds")


# MARK: - 機械の組


def _norm_text(text) -> str:
    return re.sub(r"[\s、。！？!?,.・「」『』（）()ー〜…]", "", str(text or ""))


def _seg(line: dict) -> dict | None:
    if not isinstance(line.get("audio"), str) or not isinstance(line.get("offset"), (int, float)) \
            or not isinstance(line.get("end"), (int, float)):
        return None
    if not voices.CLIP_MIN <= float(line["end"]) - float(line["offset"]) <= voices.CLIP_MAX:
        return None
    return {"audio": line["audio"], "start": float(line["offset"]), "end": float(line["end"])}


def mic_confident(parsed: dict | None) -> list[tuple[dict, str, int]]:
    """2 本のマイクが同じ発話を同じ話し手の印で書いた所 [(区間, 印, 会話の番号)]（両方の区間）"""
    phone, watch = [], []
    for ci, conversation in enumerate((parsed or {}).get("conversations") or []):
        if not isinstance(conversation, dict) or conversation.get("media"):
            continue
        for line in conversation.get("lines") or []:
            if not isinstance(line, dict) or line.get("media") is not None or not isinstance(line.get("time"), (int, float)):
                continue
            label = voices.label_of(line)
            text = _norm_text(line.get("text"))
            seg = _seg(line)
            if label is None or len(text) < 4 or seg is None:
                continue
            (watch if WATCH.search(line["audio"]) else phone).append((float(line["time"]), text, label, seg, ci))
    phone.sort(key=lambda r: r[0])
    times = [p[0] for p in phone]
    out = []
    for t, text, label, seg, ci in watch:
        best = None
        for row in phone[bisect.bisect_left(times, t - MIC_DT * 1000):bisect.bisect_right(times, t + MIC_DT * 1000)]:
            ratio = difflib.SequenceMatcher(None, text, row[1]).ratio()
            if ratio >= MIC_TEXT and (best is None or ratio > best[0]):
                best = (ratio, row)
        if best is not None and best[1][2] == label:
            out.append((seg, label, ci))
            out.append((best[1][3], label, best[1][4]))
    return out


def _pairs_from(items: list[tuple[dict, str, object]], day: str, tag: str, limit: int, same_group: bool = True) -> list[dict]:
    """[(区間, 印, まとまり)] → 組。同じ印＝同じ人、同じまとまりで違う印＝違う人。決まった順で limit まで"""
    out = []
    for i in range(len(items)):
        for j in range(i + 1, len(items)):
            a, b = items[i], items[j]
            if a[0]["audio"] == b[0]["audio"] and abs(a[0]["start"] - b[0]["start"]) < 0.01:
                continue
            if a[1] == b[1]:
                same = True
            elif not same_group or a[2] == b[2]:
                same = False
            else:
                continue
            out.append({"id": f"{tag}-{day}-{i}-{j}", "day": day, "same": same, "people": [[a[0]], [b[0]]]})
    if len(out) <= limit:
        return out
    sames = [p for p in out if p["same"]]
    diffs = [p for p in out if not p["same"]]
    half = limit // 2
    take = sames[::max(1, len(sames) // half)][:half] + diffs[::max(1, len(diffs) // half)][:half]
    return take[:limit]


def machine_pairs(base: Path | None, parsed: dict | None, day: str) -> list[dict]:
    """その日の機械の組（2 本のマイク ＋ PLAUD とアプリの向きが互いに合った行）"""
    import s34pvoice

    out = _pairs_from(mic_confident(parsed), day, "mic", PAIRS_PER_DAY)
    rows = [r for r in s34pvoice.plaud_rows(base, day, parsed or {}) if r.get("consistent")]
    by_rec: dict[str, list] = {}
    for r in rows:
        seg = _seg(r["line"])
        if seg is not None:
            by_rec.setdefault(r["rec"], []).append((seg, r["plaud"], r["rec"]))
    for rec, items in sorted(by_rec.items()):
        out += _pairs_from(items, day, f"pl{rec}", PLAUD_PAIRS_PER_REC, same_group=False)
    return out


# MARK: - 物差し（毎晩）


def measure_snorm(home: Path, pairs: list[dict], vec=None) -> dict | None:
    import s29pgate

    if not pairs:
        return None
    got = s29pgate.score_pairs(home, pairs, vec)
    if got.get("auc_raw") is None or got.get("auc_snorm") is None:
        return {"n": int(got.get("pairs") or 0), "now": got.get("auc_raw"), "new": got.get("auc_snorm"), "_scored": got.get("scored")}
    return {"n": int(got["pairs"]), "now": round(float(got["auc_raw"]), 4), "new": round(float(got["auc_snorm"]), 4),
            "_scored": got.get("scored")}


def plaud_agreement(rows: list[dict], label_new, limit: int = PLAUD_PAIRS_PER_REC) -> dict | None:
    """PLAUD と合った所の組の当たり。now＝iPhone の印・new＝label_new(行)（None の行は数えない）"""
    by_rec: dict[str, list[dict]] = {}
    for r in rows:
        if voices.label_of(r["line"]) is not None and label_new(r["line"]) is not None:
            by_rec.setdefault(r["rec"], []).append(r)
    n = right_now = right_new = 0
    for rec, items in sorted(by_rec.items()):
        count = 0
        for i in range(len(items)):
            for j in range(i + 1, len(items)):
                if count >= limit:
                    break
                a, b = items[i], items[j]
                truth = a["plaud"] == b["plaud"]
                right_now += (voices.label_of(a["line"]) == voices.label_of(b["line"])) == truth
                right_new += (label_new(a["line"]) == label_new(b["line"])) == truth
                n += 1
                count += 1
    if not n:
        return None
    return {"n": n, "now": round(right_now / n, 4), "new": round(right_new / n, 4)}


def _canon(home: Path, day: str) -> dict | None:
    body = _read(Path(home) / "s29p" / "canonical" / f"{day}.json", None)
    return body if isinstance(body, dict) else None


def label_canonical(body: dict | None):
    """夜の分け直しの付け直し案を当てた印（案の無い行は iPhone の印のまま）"""
    moved = {}
    for item in (body or {}).get("items") or []:
        if isinstance(item, dict) and isinstance(item.get("to"), dict):
            key = voices.seg_key(str(item.get("audio")), float(item.get("start") or 0), float(item.get("end") or 0))
            ident, name = str(item["to"].get("id")), str(item["to"].get("name") or "")
            moved[key] = voices.SELF_LABEL if ident == voices.SELF_ID else ("u:" if voices.UNNAMED.fullmatch(name) else "n:") + ident

    def label(line: dict):
        seg = _seg(line)
        if seg is None:
            return None
        key = voices.seg_key(seg["audio"], seg["start"], seg["end"])
        return moved.get(key) or voices.label_of(line)

    return label


def label_diar(body: dict | None):
    """1 日まるごとのかたまりの番号（かたまりに入っていない行は None）"""
    where = (body or {}).get("base_where") or {}

    def label(line: dict):
        seg = _seg(line)
        if seg is None:
            return None
        k = where.get(voices.seg_key(seg["audio"], seg["start"], seg["end"]))
        return None if k is None else f"c:{k}"

    return label


def measure_day(home: Path, base: Path | None, store, day: str, vec=None) -> dict[str, dict]:
    """その日の物差し {名前: {"n","now","new"}}（材料の無いものは入れない）"""
    import s34pvoice

    out: dict[str, dict] = {}
    parsed = store.day(day) if store is not None else None
    if parsed:
        got = measure_snorm(home, machine_pairs(base, parsed, day), vec)
        if got and got["n"]:
            out["snorm"] = got
        rows = s34pvoice.plaud_rows(base, day, parsed)
        canon = _canon(home, day)
        if rows and canon:
            for name, labeler in (("canonical", label_canonical(canon)), ("day_diar", label_diar(canon))):
                got = plaud_agreement(rows, labeler)
                if got:
                    out[name] = got
    try:
        import s26pnight

        rows = (s26pnight._read(s26pnight.folder(home) / "boost.json", {}) or {}).get("lines") or {}
        today = [r for r in rows.values() if isinstance(r, dict) and r.get("day") == day]
        chars = sum(int(r.get("chars") or 0) for r in today)
        if today and chars:
            out["boost"] = {"n": len(today), "now": round(sum(int(r.get("before") or 0) for r in today) / chars, 4),
                            "new": round(sum(int(r.get("after") or 0) for r in today) / chars, 4)}
    except Exception:  # noqa: BLE001
        pass
    return out


def record_measures(home: Path, day: str, got: dict[str, dict]) -> None:
    path = folder(home) / "measures.jsonl"
    done = {(r.get("day"), r.get("name")) for r in _jsonl(path)}
    for name, m in got.items():
        if (day, name) in done:
            continue
        _append(path, {"day": day, "name": name, "n": m.get("n"), "now": m.get("now"), "new": m.get("new"), "at": _now()})


def week_of(home: Path, name: str, today: datetime.date, days: int = WEEK) -> dict | None:
    """その名前の直近 days 日の数を合わせる（n で重みをつけた平均）"""
    first = (today - datetime.timedelta(days=days)).isoformat()
    rows = [r for r in _jsonl(folder(home) / "measures.jsonl") if r.get("name") == name and first <= str(r.get("day") or "") < today.isoformat()
            and isinstance(r.get("n"), int) and r["n"] > 0 and isinstance(r.get("now"), (int, float)) and isinstance(r.get("new"), (int, float))]
    if not rows:
        return None
    n = sum(r["n"] for r in rows)
    return {"n": n, "now": round(sum(r["now"] * r["n"] for r in rows) / n, 4), "new": round(sum(r["new"] * r["n"] for r in rows) / n, 4),
            "days": len({r["day"] for r in rows})}


# MARK: - 自8 決める・当てる


_cache_lock = threading.Lock()
_cache: dict = {"path": None, "stamp": None, "body": {}}


def read_state(home: Path) -> dict:
    path = folder(home) / "switch.json"
    try:
        stamp = path.stat().st_mtime_ns
    except OSError:
        return {}
    with _cache_lock:
        if _cache["path"] == str(path) and _cache["stamp"] == stamp:
            return _cache["body"]
    body = _read(path, {}) or {}
    body = body if isinstance(body, dict) else {}
    with _cache_lock:
        _cache.update(path=str(path), stamp=stamp, body=body)
    return body


def decide(home: Path, config: dict | None, today: datetime.date, force: bool = False) -> dict:
    """7 日ごとに決める。{"decided": bool, "changed": [名前], "state": {...}}"""
    config = config or {}
    path = folder(home) / "switch.json"
    state = _read(path, {}) or {}
    state = state if isinstance(state, dict) else {}
    rows = state.get("switches") if isinstance(state.get("switches"), dict) else {}
    last = state.get("last_decided")
    if not force and isinstance(last, str):
        try:
            if (today - datetime.date.fromisoformat(last)).days < WEEK:
                return {"decided": False, "changed": [], "state": state}
        except ValueError:
            pass
    auto = config.get("s34p_auto_switch") is not False
    changed = []
    for name, spec in SWITCHES.items():
        row = dict(rows.get(name) or {"state": "shadow", "since": None, "prev": None})
        week = week_of(home, name, today)
        row["metric"] = spec["metric"]
        row["week"] = week
        if spec["config"] in config:
            row["by"] = "本人"
            row["state"] = "on" if config[spec["config"]] == spec["on"] else "shadow"
            row["why"] = "本人が config.json に書いた値（自動では動かさない）"
        elif not spec["prod"]:
            row["by"] = "auto"
            row["why"] = spec["why_not"]
            if spec.get("decision"):
                row["decision_needed"] = True
        elif not auto:
            row["by"] = "auto"
            row["why"] = "自動の切り替えを止めてあります（\"s34p_auto_switch\": false）"
        else:
            row["by"] = "auto"
            before = row.get("state", "shadow")
            cool = True
            if before == "rolled_back" and isinstance(row.get("since"), str):
                try:
                    cool = (today - datetime.date.fromisoformat(row["since"])).days >= COOL_DAYS
                except ValueError:
                    cool = True
            if week is None:
                row["why"] = "この 7 日の材料がありません"
            elif before == "on":
                prev_new = (row.get("last_week") or {}).get("new") if isinstance(row.get("last_week"), dict) else None
                if week["n"] >= max(1, spec["need"] // 2) and (week["new"] < week["now"]
                                                                or (isinstance(prev_new, (int, float)) and week["new"] < prev_new - DROP)):
                    row.update(state="rolled_back", since=today.isoformat(),
                               why=f"数が落ちたので戻した（{week['new']:.3f}・今のやり方 {week['now']:.3f}・前の週 {prev_new}）")
                else:
                    row["why"] = f"本番のまま（{week['new']:.3f} ≥ 今のやり方 {week['now']:.3f}）"
            elif not cool:
                row["why"] = f"戻してから {COOL_DAYS} 日たつまで待つ"
            elif week["n"] < spec["need"] or week.get("days", 0) < MIN_DAYS:
                row["why"] = f"数が足りない（{week['n']}/{spec['need']}・測れた日 {week.get('days', 0)}/{MIN_DAYS}）"
            elif week["new"] >= week["now"] + spec["margin"]:
                row.update(state="on", since=today.isoformat(),
                           why=f"良くなったので本番にした（{week['new']:.3f} ≥ {week['now']:.3f} + {spec['margin']}）")
            else:
                row["why"] = f"良くなっていない（{week['new']:.3f} < {week['now']:.3f} + {spec['margin']}）"
            if row.get("state") != before:
                changed.append(name)
                _append(folder(home) / "switch-log.jsonl", {"at": _now(), "day": today.isoformat(), "name": name, "from": before,
                                                            "to": row["state"], "metric": spec["metric"], "week": week,
                                                            "prev": row.get("prev"), "why": row["why"]})
        if week is not None:
            row["prev"], row["last_week"] = row.get("last_week"), week
        rows[name] = row
    body = {"version": 1, "last_decided": today.isoformat(), "generated_at": _now(), "auto": auto, "switches": rows,
            "note": "s34 自8（仮）。良くなったら自動で本番・次の週に落ちたら自動で戻す。本人が config.json に書いた値がいつも上"}
    _write(path, body)
    return {"decided": True, "changed": changed, "state": body}


def auto_state(home: Path | None, name: str) -> str:
    if home is None:
        return "shadow"
    row = (read_state(home).get("switches") or {}).get(name) or {}
    return row.get("state") if row.get("state") in ("shadow", "on", "rolled_back") else "shadow"


def effective(home: Path | None, config: dict | None, key: str):
    """config の名前 → 自動で本番にした値（本人が書いていない・自動を止めていない・本番のときだけ）。それ以外は None"""
    config = config or {}
    if key in config or config.get("s34p_auto_switch") is False or home is None:
        return None
    for name in AUTO:
        spec = SWITCHES[name]
        if spec["config"] == key and auto_state(home, name) == "on":
            return spec["on"]
    return None


def for_app(home: Path, config: dict | None = None) -> list[dict]:
    """K34-1 の auto_switch（[{name, state, since, metric, now, prev}]。now・prev は新しいやり方の週の値）"""
    rows = (read_state(home).get("switches") or {}) if home is not None else {}
    out = []
    for name, spec in SWITCHES.items():
        row = rows.get(name) or {}
        state = row.get("state") if row.get("state") in ("shadow", "on", "rolled_back") else "shadow"
        last, prev = row.get("last_week") or {}, row.get("prev") or {}
        item = {"name": name, "state": state, "since": row.get("since"), "metric": spec["metric"],
                "now": last.get("new") if isinstance(last, dict) else None, "prev": prev.get("new") if isinstance(prev, dict) else None}
        if row.get("by") == "本人":
            item["by"] = "本人"
        if not spec["prod"]:
            item["note"] = spec["why_not"]
        out.append(item)
    return out


def install(home_of, config_of) -> None:
    """s26pc.on・s29pc.on・s29pgate.snorm_mode・s29pgate.apply_snorm を包む（何度呼んでも 1 回だけ）"""
    import s26pc
    import s29pc
    import s29pgate

    def wrap_on(original):
        def on(config: dict, name: str) -> bool:
            try:
                got = effective(home_of(), config, name)
            except Exception:  # noqa: BLE001
                got = None
            return bool(got) if got is not None else original(config, name)

        on.s34p_wrapped = True  # type: ignore[attr-defined]
        return on

    for module in (s26pc, s29pc):
        if not getattr(module.on, "s34p_wrapped", False):
            module.on = wrap_on(module.on)
    if not getattr(s29pgate.snorm_mode, "s34p_wrapped", False):
        original_mode = s29pgate.snorm_mode

        def snorm_mode(config: dict | None) -> str:
            try:
                got = effective(home_of(), config, "s29p_snorm_score")
            except Exception:  # noqa: BLE001
                got = None
            return got if got is not None else original_mode(config)

        snorm_mode.s34p_wrapped = True  # type: ignore[attr-defined]
        s29pgate.snorm_mode = snorm_mode
    if not getattr(s29pgate.apply_snorm, "s34p_wrapped", False):
        original_apply = s29pgate.apply_snorm

        def apply_snorm(body: dict, home: Path, config: dict | None) -> dict:
            try:
                auto = effective(home_of() or home, config, "s29p_snorm_score") == "on"
            except Exception:  # noqa: BLE001
                auto = False
            if not auto or not isinstance(body, dict):
                return original_apply(body, home, config)

            def order(items):
                return sorted(items, key=lambda g: -(g.get("snorm") if isinstance(g.get("snorm"), (int, float)) else -1e9))

            out = dict(body)
            out["s29_score"] = "snorm"
            out["days"] = [{**d, "groups": order(d.get("groups") or [])} if isinstance(d, dict) else d for d in body.get("days") or []]
            if isinstance(body.get("across"), list):
                out["across"] = order(body["across"])
            return out

        apply_snorm.s34p_wrapped = True  # type: ignore[attr-defined]
        s29pgate.apply_snorm = apply_snorm


# MARK: - 自9 仮の数


def _originals() -> dict[str, float]:
    import s22voice
    import s26pvoice
    import s29pgroups
    import s32pwork

    if not hasattr(_originals, "values"):
        _originals.values = {  # type: ignore[attr-defined]
            "prior_bonus": float(s22voice.DEFAULTS["prior_bonus"]), "guess_bonus": float(s26pvoice.GUESS_BONUS),
            "meeting_bonus": float((s32pwork.meeting_score.__defaults__ or (s32pwork.MEETING_BONUS,))[0]),
            "group_link": float(s29pgroups.GROUP_LINK), "chain_link": float(s22voice.DEFAULTS["chain_link"])}
    return dict(_originals.values)  # type: ignore[attr-defined]


def apply_values(values: dict[str, float]) -> None:
    """数を当てる（本人の config の s22_voice は s22voice.settings が上に重ねるので、本人の値が上）"""
    import s22voice
    import s26pvoice
    import s29pgroups
    import s32pwork

    old = _originals()
    v = {**old, **{k: float(x) for k, x in values.items() if k in TUNABLES}}
    s22voice.DEFAULTS["prior_bonus"] = v["prior_bonus"]
    s22voice.DEFAULTS["chain_link"] = v["chain_link"]
    s26pvoice.GUESS_BONUS = v["guess_bonus"]
    s32pwork.meeting_score.__defaults__ = (v["meeting_bonus"],)
    s29pgroups.GROUP_LINK = v["group_link"]


def current_values(home: Path) -> dict[str, float]:
    body = _read(folder(home) / "tuned.json", {}) or {}
    out = _originals()
    for name, row in (body.get("values") or {}).items():
        if name in TUNABLES and isinstance(row, dict) and isinstance(row.get("new"), (int, float)):
            lo, hi = TUNABLES[name]["range"]
            out[name] = min(hi, max(lo, float(row["new"])))
    return out


def _grid(lo: float, hi: float, step: float) -> list[float]:
    out, x = [], lo
    while x <= hi + 1e-9:
        out.append(round(x, 4))
        x += step
    return out


def best_value(current: float, spec: dict, score_of) -> tuple[float, float | None, float | None]:
    """(選んだ値, その当たり, 今の値の当たり)。幅の中・1 回に max_move まで。同じなら今の値に近いほう"""
    lo, hi = spec["range"]
    lo2, hi2 = max(lo, current - spec["max_move"]), min(hi, current + spec["max_move"])
    candidates = sorted(set(_grid(lo, hi, spec["step"])) | {round(current, 4)})
    candidates = [c for c in candidates if lo2 - 1e-9 <= c <= hi2 + 1e-9]
    base = score_of(current)
    best, best_score = current, base
    for c in candidates:
        s = score_of(c)
        if s is None:
            continue
        if best_score is None or s > best_score + 1e-9 or (abs(s - best_score) <= 1e-9 and abs(c - current) < abs(best - current)):
            best, best_score = c, s
    return round(best, 4), best_score, base


def bonus_rows(home: Path, base: Path | None, store, days: list[str], still_ok=None) -> list[dict]:
    """PLAUD と結べた「名前の無い声 × 名前のある人」[{"score","same","hint":{prior,guess,meeting}}]"""
    import s26pvoice
    import s32pwork
    import s34pvoice

    refs = s26pvoice.name_refs(home, store, days) if store is not None else {}
    meetings = s32pwork.read_meetings(base)
    guesses = s26pvoice.read_guess(base)
    out = []
    for day in days:
        if still_ok is not None and not still_ok():
            break
        parsed = store.day(day) if store is not None else None
        if not parsed or not refs:
            continue
        rows = s34pvoice.plaud_rows(base, day, parsed)
        if not rows:
            continue
        vectors = s34pvoice._vectors(home, parsed, day)
        hints = s34pvoice.windows(base, day)
        by_rec: dict[str, list[dict]] = {}
        for r in rows:
            by_rec.setdefault(r["rec"], []).append(r)
        for rec_rows in by_rec.values():
            named_plaud: dict[str, set[str]] = {}
            for r in rec_rows:
                name = r["line"].get("speaker")
                if voices.label_of(r["line"]) and str(voices.label_of(r["line"])).startswith("n:") and name in refs:
                    named_plaud.setdefault(str(name), set()).add(r["plaud"])
            for r in rec_rows:
                label = voices.label_of(r["line"])
                seg = _seg(r["line"])
                if not label or not label.startswith("u:") or seg is None:
                    continue
                v = vectors.get(voices.seg_key(seg["audio"], seg["start"], seg["end"]))
                t = r["line"].get("time")
                if v is None or not isinstance(t, int):
                    continue
                for name, plauds in named_plaud.items():
                    hint = {"prior": any(w["source"] in ("calendar", "line") and name in w["names"] and w["start"] <= t <= w["end"] for w in hints),
                            "guess": any(g["day"] == day and g["start"] <= t <= g["end"] and any(c["name"] == name for c in g["candidates"])
                                         for g in guesses),
                            "meeting": name in s32pwork.people_at(meetings, t / 1000)}
                    if not any(hint.values()):
                        continue
                    out.append({"score": float(v @ refs[name][0]), "same": r["plaud"] in plauds and len(plauds) == 1, "hint": hint})
    return out


def _bonus_score(rows: list[dict], hint: str):
    use = [r for r in rows if r["hint"].get(hint)]

    def score(b: float):
        if len(use) < TUNE_NEED_BONUS:
            return None
        return sum((r["score"] + b >= voices.NAMED_MIN) == r["same"] for r in use) / len(use)

    return score, len(use)


def _link_score(scored: list[dict]):
    sames = [r["raw"] for r in scored if r.get("same")]
    diffs = [r["raw"] for r in scored if not r.get("same")]

    def score(t: float):
        if len(scored) < TUNE_NEED_LINK or not sames or not diffs:
            return None
        return 0.5 * (sum(x >= t for x in sames) / len(sames) + sum(x < t for x in diffs) / len(diffs))

    return score, len(scored)


def tune(home: Path, base: Path | None, store, config: dict | None, today: datetime.date, force: bool = False,
         still_ok=None, vec=None) -> dict:
    """7 日ごとに合わせ直す。{"tuned": bool, "values": {...}}"""
    config = config or {}
    path = folder(home) / "tuned.json"
    body = _read(path, {}) or {}
    last = body.get("last")
    if config.get("s34p_tune") is False:
        apply_values({})
        return {"tuned": False, "values": _originals(), "why": "止めてあります（元の値）"}
    if not force and isinstance(last, str):
        try:
            if (today - datetime.date.fromisoformat(last)).days < WEEK:
                values = current_values(home)
                apply_values(values)
                return {"tuned": False, "values": values}
        except ValueError:
            pass
    days = [(today - datetime.timedelta(days=k)).isoformat() for k in range(1, WEEK + 1)]
    rows = bonus_rows(home, base, store, days, still_ok)
    scored: list[dict] = []
    for day in days:
        if still_ok is not None and not still_ok():
            break
        parsed = store.day(day) if store is not None else None
        if parsed:
            got = measure_snorm(home, machine_pairs(base, parsed, day), vec)
            scored += (got or {}).get("_scored") or []
    old = _originals()
    current = current_values(home)
    values = dict(body.get("values") or {})
    for name, spec in TUNABLES.items():
        if spec["kind"] == "bonus":
            score, n = _bonus_score(rows, spec["hint"])
        else:
            score, n = _link_score(scored)
        new, got, base_score = best_value(current[name], spec, score)
        if got is None:
            why = f"材料が足りない（{n} 組）。動かさない"
            new = current[name]
        elif abs(new - current[name]) < 1e-9:
            why = f"今の値がいちばん良い（当たり {got:.3f}・{n} 組）"
        else:
            why = f"当たり {base_score if base_score is not None else 0:.3f} → {got:.3f}（{n} 組）"
        row = {"old": old[name], "before": current[name], "new": new, "range": spec["range"], "why": why, "n": n, "at": _now()}
        if abs(new - current[name]) >= 1e-9:
            _append(folder(home) / "tuned-log.jsonl", {"day": today.isoformat(), "name": name, **row})
        values[name] = row
    out = {"version": 1, "last": today.isoformat(), "generated_at": _now(), "values": values,
           "note": "s34 自9（仮）。決めた幅の中だけ・1 回に少しだけ動かす。old はコードの元の値。\"s34p_tune\": false で元に戻す"}
    _write(path, out)
    applied = {k: v["new"] for k, v in values.items() if isinstance(v, dict)}
    apply_values(applied)
    return {"tuned": True, "values": applied}


def tuned_for_app(home: Path) -> list[dict]:
    """K34-1 の tuned（[{name, old, new, range, why}]）"""
    body = _read(folder(home) / "tuned.json", {}) or {}
    out = []
    for name, row in (body.get("values") or {}).items():
        if name in TUNABLES and isinstance(row, dict):
            out.append({"name": name, "old": row.get("old"), "new": row.get("new"), "range": row.get("range"), "why": row.get("why")})
    return out
