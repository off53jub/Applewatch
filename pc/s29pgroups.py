"""LifeLog PC: s29（2026-11-27。担当 P）声19 作る側。7 日ぶんの名前の無い声（人物N）を、かたまりにまとめる。0 円。

- 声の特徴は HOME/voices/<日>.npz の今までのもの（voices.gather。新しく測らない）。まとめるだけで、記録・名前は書き換えない。
- まとめ方: 名前の無い人物N ごとの真ん中（区間 MIN_CLIPS 個以上）を、平均の近さが GROUP_LINK（0.60・仮）以上なら近い順に
  まとめる（voices.cluster と同じ。同じ区切りに出た 2 人は同じかたまりにしない・GROUP_MAX 人まで）。2 人以上のかたまりだけ出す。
- GET /same-person に省ける "s29_groups": [{"id": str, "labels": ["人物12", …], "score": float, "seconds": float, "days": int}]
  （アプリの S29N が読む約束。labels は既存の項目の people[].name と同じ「人物N」の文字。多く話した順。score はかたまりの中の
  近さの平均・seconds は合わせて話した秒・days は出てきた日の数）。「同じ人か」の問いを止めていても（"same_person_ask": false）出す
  （名前付けの 1 問にまとめるためのもので、問いを増やさない）。
- 当たりの測り（仮の数を決めるため）: 既存の across（日をまたぐ組）の人がみな同じかたまりに入った割合と、答えた組（両側が人物N の行）で
  「同じかたまり＝同じ人」が当たった割合を HOME/s29p/groups.json の "measure" に。しきい値を変えた表（LINKS）も一緒に。
"""

from __future__ import annotations

import datetime
import hashlib
import json
import os
import time
from pathlib import Path

import numpy as np

import voices

GROUP_LINK = 0.60        # 仮
LINKS = (0.50, 0.55, 0.60, 0.65, 0.70)
GROUP_MAX = 12
MIN_CLIPS = voices.MIN_CLIPS
GROUPS_MAX = 40
FILE = "groups.json"
SEEN = "groups-seen.json"   # 出したかたまりの見本（答えが来たときに組にするため。SEEN_DAYS 日）
SEEN_DAYS = 14
SERVE_STALE_DAYS = 3


def folder(home: Path) -> Path:
    return Path(home) / "s29p"


def _hash(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:12]


def _write(path: Path, body) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    part = path.with_name(path.name + ".part")
    part.write_text(json.dumps(body, ensure_ascii=False), encoding="utf-8")
    os.replace(part, path)


def make_groups(labels: dict[str, dict], link: float = GROUP_LINK) -> list[dict]:
    """voices.gather の labels から、名前の無い人物N のかたまり（2 人以上）"""
    centers = {k: voices.center(e["items"]) for k, e in labels.items() if k.startswith("u:") and len(e["items"]) >= MIN_CLIPS}
    centers = {k: v for k, v in centers.items() if v is not None}
    ids = sorted(centers)
    if len(ids) < 2:
        return []
    apart = voices.apart_pairs(labels)
    out = []
    for members, score in voices.cluster(ids, np.stack([centers[i] for i in ids]), apart, link, GROUP_MAX):
        members = sorted(members, key=lambda g: (-labels[g]["seconds"], g))
        out.append({"id": "s29g-" + _hash("|".join(sorted(members))), "labels": [f"人物{m[2:]}" for m in members],
                    "score": round(float(score), 3), "seconds": round(sum(labels[m]["seconds"] for m in members), 1),
                    "days": len(set().union(*[labels[m]["days"] for m in members]))})
    out.sort(key=lambda g: (-g["seconds"], g["id"]))
    return out[:GROUPS_MAX]


def _where(groups: list[dict]) -> dict[str, str]:
    return {label: g["id"] for g in groups for label in g["labels"]}


def measure(groups: list[dict], across: list[dict], answered: list[dict], line_label) -> dict:
    """{"across","across_kept","answers","answers_right"}。line_label(見本) は見本の行の「人物N」の文字か None"""
    where = _where(groups)
    kept = 0
    for g in across:
        names = [str(p.get("name")) for p in g.get("people") or [] if isinstance(p, dict)]
        spots = {where.get(n) for n in names}
        kept += len(names) >= 2 and len(spots) == 1 and None not in spots
    n = right = 0
    for p in answered:
        sides = []
        for side in p["people"][:2]:
            got = {line_label(s) for s in side} - {None}
            sides.append(got.pop() if len(got) == 1 else None)
        if None in sides or len(sides) < 2 or sides[0] == sides[1]:
            continue
        a, b = where.get(sides[0]), where.get(sides[1])
        n += 1
        right += ((a is not None and a == b) == p["same"])
    return {"across": len(across), "across_kept": kept, "answers": n, "answers_right": right}


def label_index(store, days: list[str]) -> dict[str, str]:
    """見本の鍵 → 「人物N」（名前の無い行だけ）"""
    out = {}
    for day in days:
        parsed = store.day(day) if store is not None else None
        for s in voices.segments(parsed or {}):
            if s["label"] and s["label"].startswith("u:"):
                out[s["key"]] = f"人物{s['label'][2:]}"
    return out


def build(home: Path, store, today: datetime.date | None = None, answered: list[dict] | None = None,
          window: int = voices.WINDOW) -> dict:
    today = today or datetime.date.today()
    days = [(today - datetime.timedelta(days=k)).isoformat() for k in range(window - 1, -1, -1)]
    got = voices.gather(home, store, days)
    labels = got["labels"]
    groups = make_groups(labels, GROUP_LINK)
    across = []
    try:
        across = (json.loads((Path(home) / voices.OUT_FOLDER / voices.OUT_FILE).read_text(encoding="utf-8")) or {}).get("across") or []
    except (OSError, ValueError):
        pass
    index = label_index(store, days)

    def line_label(sample: dict):
        return index.get(voices.seg_key(sample["audio"], sample["start"], sample["end"]))

    table = {}
    for link in LINKS:
        table[f"{link:.2f}"] = {"groups": len(found := make_groups(labels, link)),
                                "people": sum(len(g["labels"]) for g in found),
                                **measure(found, across, answered or [], line_label)}
    unnamed = sum(1 for k, e in labels.items() if k.startswith("u:") and len(e["items"]) >= MIN_CLIPS)
    body = {"version": 1, "generated_at": datetime.datetime.now().isoformat(timespec="seconds"), "link": GROUP_LINK,
            "window": got["days"], "unnamed": unnamed, "groups": groups,
            "measure": measure(groups, across, answered or [], line_label), "table": table,
            "note": "s29 声19（仮）。まとめるだけで、記録・名前は書き換えない"}
    _write(folder(home) / FILE, body)
    remember(home, groups, labels, today)
    return body


def _samples(entry: dict) -> list[dict]:
    return [{"audio": i["audio"], "start": round(float(i["start"]), 2), "end": round(float(i["end"]), 2)}
            for i in voices.pick(entry["items"], 3)]


def remember(home: Path, groups: list[dict], labels: dict[str, dict], today: datetime.date) -> None:
    """出したかたまりの人ごとの見本を HOME/s29p/groups-seen.json に（同じ id は新しいほう）"""
    path = folder(home) / SEEN
    try:
        seen = json.loads(path.read_text(encoding="utf-8"))
        seen = seen if isinstance(seen, dict) else {}
    except (OSError, ValueError):
        seen = {}
    for g in groups:
        people = [_samples(labels["u:" + name[2:]]) for name in g["labels"] if "u:" + name[2:] in labels]
        people = [p for p in people if p]
        if len(people) >= 2:
            seen[g["id"]] = {"people": people, "labels": g["labels"], "day": today.isoformat(), "source": "s29_groups"}
    limit = (today - datetime.timedelta(days=SEEN_DAYS)).isoformat()
    seen = {k: v for k, v in seen.items() if isinstance(v, dict) and str(v.get("day")) >= limit}
    _write(path, seen)


def seen_groups(home: Path) -> dict[str, dict]:
    """s23voice.groups_with_samples に足す形 {id: {"people","score","day","source"}}"""
    try:
        seen = json.loads((folder(home) / SEEN).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return {k: {"people": v["people"], "score": None, "day": v.get("day"), "source": "s29_groups"}
            for k, v in (seen or {}).items() if isinstance(v, dict) and isinstance(v.get("people"), list)}


def read(home: Path, now: float | None = None) -> list[dict]:
    """GET /same-person の "s29_groups"（古い・読めない・形の違うものは出さない）"""
    path = folder(home) / FILE
    try:
        if (now or time.time()) - path.stat().st_mtime > SERVE_STALE_DAYS * 86400:
            return []
        body = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    out = []
    for g in (body or {}).get("groups") or []:
        if not isinstance(g, dict) or not isinstance(g.get("id"), str) or not isinstance(g.get("labels"), list):
            continue
        labels = [x for x in g["labels"] if isinstance(x, str) and voices.UNNAMED.fullmatch(x)]
        if len(labels) < 2:
            continue
        out.append({"id": g["id"], "labels": labels, "score": float(g.get("score") or 0.0),
                    "seconds": float(g.get("seconds") or 0.0), "days": int(g.get("days") or 0)})
    return out[:GROUPS_MAX]


def wrap_hold(original, home_of):
    """s24rules.hold_same_person の包み: 抜いたあとに "s29_groups" を足す（問いを止めていても出す）。声9 の並べ替えもここ"""

    def hold(body: dict, config: dict | None = None) -> dict:
        out = original(body, config) if config is not None else original(body)
        home = home_of()
        if home is None or not isinstance(out, dict):
            return out
        try:
            import s29pgate
            import s24rules

            out = s29pgate.apply_snorm(out, home, config if config is not None else s24rules._config(None))
        except Exception:  # noqa: BLE001 — 並べられなくても前の答えのまま
            pass
        groups = read(home)
        if groups:
            out = {**out, "s29_groups": groups}
        return out

    hold.s29p_wrapped = True  # type: ignore[attr-defined]
    return hold
