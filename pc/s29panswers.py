"""LifeLog PC: s29（2026-11-27。担当 P）声22 の受ける側。本人の名前付けの答えを「答えた組」（同じ人／違う人の組）にためる。

調べて分かったこと（2026-11-27。数だけ）:
- 「答えた組」の出どころは 2 つだけだった（s23voice.answers）: 母艦 inbox/app_feedback.jsonl の kind "same_person"
  （value merged／different。id は GET /same-person の組の id）と、確かめ待ちの kind "review" の id "vp-…"（yes／no）。
- そのうえで、組の見本（声の区間）が HOME/same-person/<日>.json（7 日で消える）・voices.json（作り直すたびに置き換え）に
  まだ残っている組だけを数えていた（s24night.answer_pairs）。
- 母艦の same_person の答えは 25 個あったが、どれも 11/17 のもので、その組のファイルはもう消えていた → 0 組。
- 11/24 からは「同じ人か」の問いそのものを止めている（s24 当1・"same_person_ask": false）ので、新しい same_person の答えが来ない。
- アプリの名前付けの入口 4 つ（声を聞いて直す・○× でまとめて・今日の人物 N を整理・直す）は POST /feedback を送らず、
  記録の話し手を直す（fixSpeaker・mergePerson・renamePerson）だけ。その直しは、iPhone が POST /records/<日> で送り直す記録に出る。

直したこと（PC 側。記録の話し手は書き換えない・人をまとめない）:
1. 答えの見本を HOME/s29p/answers.json に写して残す（組のファイルが消えても、答えた組は消えない）。
2. 記録の話し手の直しから組を作る: 30 分ごとに直近 7 日の記録の話し手を HOME/s29p/snap/<日>.json と比べ、
   「行の話し手が、名前のある人か自分に変わった」所だけを本人の答えとみなす（機械のまとめは名前の無い人どうしなので入れない）。
   - 移した行 と 移した先の人のほかの行 → 同じ人（"same": true）
   - 移した行 と もとの人に残った行（同じ日）→ 違う人（"same": false）
   - 名前を付けただけ（番号はそのまま）は組を作らない（相手が無い）。1 度に 300 行より多く変わったら番号の付け替えとみなして入れない。
2b. 母艦の「いちばん多く話す人」の問い（kind review・id "spt-<番号>"）に名前を打った答えも、その名前が記録の名前のある人と
   同じなら「人物<番号> と その人 は同じ人」の組にする（import_spt。答えはあっても記録は人物N のまま＝届いていなかった所）。
3. 新しい形（アプリの S29N が送る）: POST /feedback の kind "same_person" に省ける欄 s29_* を足せる（下）。見本があれば、
   組のファイルが無くても組になる。前の形（s29_* なし）は今までどおり。

POST /feedback（kind "same_person"）の省ける欄（どれも無くてよい。形の違う欄は落として、答えそのものは受ける。docs/s29-pc.md）:
  "s29_kind":   "move" | "keep" | "named" | "merged" | "unknown" | "split"（アプリ S29N が送る）。"merge"・"quick_yes"・"quick_no"・
                "pair" も受ける。ほかの文字は "pair" にする
  "s29_pairs":  [{"same": bool, "ids": [話し手の番号…]?, "people": [[見本…], [見本…]]}]（20 組まで。両側に見本が要る。
                組の id は "<id>#<番号>"）
  "s29_ids":    [話し手の番号…]・"s29_group": s29_groups の id・"s29_at": ISO 8601
  "s29_a", "s29_b": 見本 {"audio", "start"（"offset" も可）, "end"} かその並び（8 個まで）。s29_b が無いときは夜にその日の記録の
                "s29_to"（同じ人）・"s29_from"（違う人）の行から探す
  "s29_screen": 入口（24 字まで）・"s29_scope": "line" | "same_voice" | "everywhere"
  id が s29_groups の id（"s29g-…"）で s29_pairs が無いとき: merged・named は「1 人目と k 人目は同じ人」の組を全部。
  split（まとまりに別の人がいた）は、だれとだれが違うかが分からないので組にしない。

記録（log.txt）には数だけを書く（名前・文・音声の名前は書かない）。
"""

from __future__ import annotations

import datetime
import hashlib
import json
import os
import re
import threading
import time
from pathlib import Path

import voices

FOLDER = "s29p"
STORE = "answers.json"
SNAP = "snap"
WINDOW = 7                # 記録の直しを見る日数（今日を入れて）
KEEP_DAYS = 90            # 答えた組を残す日数
STORE_MAX = 3000
BULK_MAX = 300            # 仮: 1 度にこれより多く変わったら、番号の付け替えとみなす
SAMPLES = 3
SAMPLE_MAX = 8
SAMPLE_LEN = (1.5, 20.0)
KINDS = ("move", "keep", "named", "merged", "merge", "unknown", "split", "quick_yes", "quick_no", "pair")
PAIRS_MAX = 20
IDS_MAX = 20
ISO = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?")
SCREENS = re.compile(r"[a-z_]{1,24}")
SCOPES = ("line", "same_voice", "everywhere")
SPEAKER_ID = re.compile(r"[\w.:-]{1,40}")
AUDIO = re.compile(r"[\w.\-]{1,120}")
UNNAMED = re.compile(r"人物\d+")

_lock = threading.Lock()


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
    part.write_text(json.dumps(body, ensure_ascii=False), encoding="utf-8")
    os.replace(part, path)


def _hash(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:12]


def _num(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and value == value


# MARK: - 新しい形の受け口（POST /feedback の s29_*）


def sample(item) -> dict | None:
    """{"audio","start","end"}（"offset" も start として受ける）。形が違えば None"""
    if not isinstance(item, dict) or not isinstance(item.get("audio"), str) or not AUDIO.fullmatch(item["audio"]):
        return None
    start = item.get("start", item.get("offset"))
    end = item.get("end")
    if not _num(start) or not _num(end) or not 0 <= float(start) < float(end) or float(end) - float(start) > 60:
        return None
    return {"audio": item["audio"], "start": round(float(start), 2), "end": round(float(end), 2)}


def _samples(value) -> list[dict] | None:
    items = value if isinstance(value, list) else [value] if isinstance(value, dict) else None
    if items is None:
        return None
    got = [s for s in (sample(x) for x in items[:SAMPLE_MAX]) if s]
    return got or None


def _pair(item) -> dict | None:
    """s29_pairs の 1 つ {"same": bool, "ids": [..]?, "people": [[見本…], [見本…]]}（両側に見本が要る）"""
    if not isinstance(item, dict) or not isinstance(item.get("same"), bool) or not isinstance(item.get("people"), list):
        return None
    people = [_samples(p) for p in item["people"][:2]]
    if len(people) < 2 or not all(people):
        return None
    out = {"same": item["same"], "people": people}
    ids = item.get("ids")
    if isinstance(ids, list):
        out["ids"] = [x for x in ids[:IDS_MAX] if isinstance(x, str) and SPEAKER_ID.fullmatch(x)]
    return out


def parse_extra(body: dict) -> tuple[dict, int]:
    """POST /feedback の中身から s29_* の欄だけ（形の違う欄は落とす）。(欄, 落とした数)"""
    out: dict = {}
    dropped = 0
    if not isinstance(body, dict):
        return out, 0
    kind = body.get("s29_kind")
    if kind is not None:
        if isinstance(kind, str) and kind:
            out["s29_kind"] = kind if kind in KINDS else "pair"
        else:
            dropped += 1
    for key, ok in (("s29_screen", lambda v: isinstance(v, str) and SCREENS.fullmatch(v)),
                    ("s29_scope", lambda v: v in SCOPES),
                    ("s29_from", lambda v: isinstance(v, str) and SPEAKER_ID.fullmatch(v)),
                    ("s29_to", lambda v: isinstance(v, str) and SPEAKER_ID.fullmatch(v))):
        value = body.get(key)
        if value is None:
            continue
        if ok(value):
            out[key] = value
        else:
            dropped += 1
    for key, ok in (("s29_group", lambda v: isinstance(v, str) and SPEAKER_ID.fullmatch(v)),
                    ("s29_at", lambda v: isinstance(v, str) and ISO.fullmatch(v))):
        value = body.get(key)
        if value is None:
            continue
        if ok(value):
            out[key] = value
        else:
            dropped += 1
    ids = body.get("s29_ids")
    if ids is not None:
        got = [x for x in ids[:IDS_MAX] if isinstance(x, str) and SPEAKER_ID.fullmatch(x)] if isinstance(ids, list) else []
        if got:
            out["s29_ids"] = got
        else:
            dropped += 1
    raw_pairs = body.get("s29_pairs")
    if raw_pairs is not None:
        got = []
        for item in raw_pairs[:PAIRS_MAX] if isinstance(raw_pairs, list) else []:
            pair = _pair(item)
            if pair is None:
                dropped += 1
            else:
                got.append(pair)
        if got:
            out["s29_pairs"] = got
        elif not isinstance(raw_pairs, list):
            dropped += 1
    for key in ("s29_a", "s29_b"):
        if body.get(key) is None:
            continue
        got = _samples(body.get(key))
        if got:
            out[key] = got
        else:
            dropped += 1
    return out, dropped


def wrap_parse(original, home_of):
    """appfeeds.parse_feedback の包み: kind "same_person" なら s29_* の欄を足す（前の形は前のまま）"""

    def parse(data: bytes) -> dict:
        row = original(data)
        if isinstance(row, dict) and row.get("kind") == "same_person":
            try:
                body = json.loads(data.decode("utf-8"))
            except (UnicodeDecodeError, ValueError):
                body = {}
            extra, dropped = parse_extra(body)
            row.update(extra)
            if extra or dropped:
                _count(home_of(), "app_s29" if extra else "app_old", dropped)
            else:
                _count(home_of(), "app_old", 0)
        return row

    parse.s29p_wrapped = True  # type: ignore[attr-defined]
    return parse


def _count(home: Path | None, key: str, dropped: int) -> None:
    if home is None:
        return
    with _lock:
        path = folder(home) / "received.json"
        body = _read(path, {}) or {}
        day = datetime.date.today().isoformat()
        entry = body.setdefault(day, {})
        entry[key] = int(entry.get(key, 0)) + 1
        if dropped:
            entry["dropped_fields"] = int(entry.get("dropped_fields", 0)) + dropped
        limit = (datetime.date.today() - datetime.timedelta(days=30)).isoformat()
        body = {d: v for d, v in body.items() if d >= limit}
        try:
            _write(path, body)
        except OSError:
            pass


# MARK: - 置き場（HOME/s29p/answers.json）


def load(home: Path) -> dict:
    body = _read(folder(home) / STORE, {}) or {}
    pairs = body.get("pairs") if isinstance(body.get("pairs"), dict) else {}
    return {"version": 1, "pairs": pairs}


def save(home: Path, body: dict, today: datetime.date | None = None) -> None:
    limit = ((today or datetime.date.today()) - datetime.timedelta(days=KEEP_DAYS)).isoformat()
    pairs = {k: v for k, v in body["pairs"].items() if str(v.get("at") or "9999") >= limit}
    if len(pairs) > STORE_MAX:
        keep = sorted(pairs, key=lambda k: str(pairs[k].get("at")))[-STORE_MAX:]
        pairs = {k: pairs[k] for k in keep}
    with _lock:
        _write(folder(home) / STORE, {"version": 1, "pairs": pairs,
                                       "generated_at": datetime.datetime.now().isoformat(timespec="seconds")})


def add(store: dict, pid: str, same: bool, people: list[list[dict]], day: str, source: str,
        kind: str | None = None, orig_same: bool | None = None, at: str | None = None) -> bool:
    """組を 1 つ足す（同じ id は、あとの答えが勝つ）。見本の無い側があれば足さない"""
    people = [[s for s in p if s] for p in people[:2]]
    if len(people) < 2 or not all(people):
        return False
    old = store["pairs"].get(pid)
    row = {"same": bool(same), "people": people, "day": day, "source": source,
           "at": at or datetime.datetime.now().isoformat(timespec="seconds")}
    if kind:
        row["kind"] = kind
    if orig_same is not None:
        row["orig_same"] = bool(orig_same)
    store["pairs"][pid] = row
    return old != row


def pairs(home: Path) -> dict[str, dict]:
    """s23voice.groups_with_samples と同じ形 {id: {"people","score","day"}}（answers.json の全部）"""
    return {k: {"people": v["people"], "score": None, "day": v.get("day")} for k, v in load(home)["pairs"].items()
            if isinstance(v, dict) and isinstance(v.get("people"), list)}


def known(home: Path) -> dict[str, bool]:
    return {k: bool(v.get("same")) for k, v in load(home)["pairs"].items() if isinstance(v, dict)}


# MARK: - 1. 前の形の答えを写して残す・2. 新しい形の答えを組に


def _feedback_rows(base: Path | None) -> list[dict]:
    if base is None:
        return []
    try:
        raw = (Path(base) / "inbox" / "app_feedback.jsonl").read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    out = []
    for line in raw:
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict) and row.get("kind") == "same_person" and row.get("value") in ("merged", "different") \
                and isinstance(row.get("id"), str):
            out.append(row)
    return out


ORIG_BY_KIND = {"keep": "same", "move": "not", "merge": "not", "merged": "not", "named": "not", "split": "not"}


def _orig(row: dict, same: bool) -> bool | None:
    """iPhone の分けが、答える前に同じ人としていたか（分け間違いの数に使う）。分からなければ None"""
    how = ORIG_BY_KIND.get(str(row.get("s29_kind") or ""))
    if how == "same":
        return same
    if how == "not":
        return not same
    pid = str(row.get("id") or "")
    if pid.startswith(("sp-", "sx-", "pm-")):   # 前の形の組は、どれも iPhone が別の人に分けていた 2 人
        return False
    return None


def _lines_of(parsed: dict | None, ident: str, skip: set[str]) -> list[dict]:
    out = []
    for s in voices.segments(parsed or {}):
        line = s["line"]
        if line.get("speakerID") == ident and s["key"] not in skip:
            out.append({"audio": s["audio"], "start": round(s["start"], 2), "end": round(s["end"], 2),
                        "length": s["end"] - s["start"]})
    out.sort(key=lambda x: -x["length"])
    return [{k: x[k] for k in ("audio", "start", "end")} for x in out[:SAMPLES]]


def import_feedback(home: Path, base: Path | None, groups: dict[str, dict] | None = None, read_day=None) -> dict:
    """母艦の same_person の答えを answers.json へ。順に:
    s29_pairs（S29N の形。組ごとに id "<id>#<番号>"）→ s29_a/s29_b（見本・無い側は記録から）→
    id が組の id（前の形の sp-/sx-/pm-・s29_groups の s29g-。見本を写す。まとまりの merged は 1 人目と k 人目の組を全部）"""
    store = load(home)
    got = {"old": 0, "app": 0, "group": 0, "unresolved": 0, "changed": 0}
    for row in _feedback_rows(base):
        same = row["value"] == "merged"
        pid = str(row["id"])
        day = str(row.get("day") or "")
        at = str(row.get("s29_at") or row.get("at") or "") or None
        kind = row.get("s29_kind")
        found: list[tuple[str, bool, list, str]] = []
        for i, item in enumerate(row.get("s29_pairs") or []):
            pair = _pair(item)
            if pair is not None:
                found.append((f"{pid}#{i}", pair["same"], pair["people"], "app"))
        if not found and row.get("s29_a"):
            a = [s for s in map(sample, row.get("s29_a") or []) if s]
            b = [s for s in map(sample, row.get("s29_b") or []) if s]
            if not b and read_day is not None and day:
                parsed = read_day(day)
                skip = {voices.seg_key(s["audio"], s["start"], s["end"]) for s in a}
                ident = row.get("s29_to") if same else row.get("s29_from")
                if isinstance(ident, str):
                    b = _lines_of(parsed, ident, skip)
            if a and b:
                found.append((pid, same, [a, b], "app"))
        group = (groups or {}).get(pid) or (groups or {}).get(str(row.get("s29_group") or ""))
        if not found and group is not None:
            people = [list(p) for p in group.get("people") or [] if p]
            source = "group" if str(group.get("source") or "") == "s29_groups" or pid.startswith("s29g-") else "old"
            if source == "group":
                if same and kind != "split":   # まとまり全体が同じ人: 1 人目と k 人目
                    found += [(f"{pid}#{k}", True, [people[0], people[k]], source) for k in range(1, len(people))]
                # split（まとまりに別の人がいた）は、だれとだれが違うかが分からないので組にしない
            elif len(people) >= 2:
                found.append((pid, same, people[:2], source))
            if not day:
                day = str(group.get("day") or "")
        if not found:
            if pid not in store["pairs"] and not any(k.startswith(pid + "#") for k in store["pairs"]):
                got["unresolved"] += 1
            continue
        for key, pair_same, people, source in found:
            if add(store, key, pair_same, people, day, source, kind, _orig(row, pair_same), at):
                got["changed"] += 1
            got[source] += 1
    if got["changed"]:
        save(home, store)
    return got


SPT = re.compile(r"spt-([\w.:-]{1,40})")
NOT_NAME = {"yes", "no", "unsure", "はい", "いいえ", "わからない", "分からない", "あとで", "later", "skip"}


def import_spt(home: Path, base: Path | None, read_day, today: datetime.date | None = None, window: int = WINDOW) -> dict:
    """母艦の「いちばん多く話す人」の問い（確かめ待ちの kind review・id "spt-<番号>"）に名前を打った答えを組に。
    打った名前が直近 window 日の記録の名前のある人と同じなら「人物<番号> と その人 は同じ人」。新しい名前なら組にしない
    （相手の声が無い）。記録の名前は書き換えない（名前を付けるのは本人の端末）"""
    got = {"answers": 0, "pairs": 0, "no_match": 0}
    if base is None or read_day is None:
        return got
    try:
        raw = (Path(base) / "inbox" / "app_feedback.jsonl").read_text(encoding="utf-8").splitlines()
    except OSError:
        return got
    named: dict[str, tuple[str, str]] = {}   # 名前 → (speakerID, 日)
    today = today or datetime.date.today()
    days = [(today - datetime.timedelta(days=k)).isoformat() for k in range(window)]
    parsed_days = {d: read_day(d) for d in days}
    for d, parsed in parsed_days.items():
        for s in voices.segments(parsed or {}):
            line = s["line"]
            if s["label"] and s["label"].startswith("n:"):
                named.setdefault(" ".join(str(line.get("speaker") or "").split()), (str(line.get("speakerID")), d))
    store = load(home)
    changed = False
    for line in raw:
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if not isinstance(row, dict) or row.get("kind") != "review":
            continue
        m = SPT.fullmatch(str(row.get("id") or ""))
        answer = " ".join(str(row.get("answer") or "").split())
        if not m or not answer or answer.lower() in NOT_NAME or UNNAMED.fullmatch(answer):
            continue
        got["answers"] += 1
        hit = named.get(answer)
        if hit is None or hit[0] == m.group(1):
            got["no_match"] += 1
            continue
        ident, other = m.group(1), hit[0]
        a, b = [], []
        for parsed in parsed_days.values():
            a += _lines_of(parsed, ident, set())
            b += _lines_of(parsed, other, set())
        a, b = a[:SAMPLES], b[:SAMPLES]
        if a and b:
            pid = f"s29t-{_hash(ident + '>' + other)}"
            if add(store, pid, True, [a, b], hit[1], "spt", "named", False, str(row.get("at") or row.get("sent_at") or "") or None):
                changed = True
            got["pairs"] += 1
    if changed:
        save(home, store, today)
    return got


# MARK: - 3. 記録の話し手の直しから組を作る


def _key(line: dict) -> str | None:
    audio, start, end = line.get("audio"), line.get("offset"), line.get("end")
    if not isinstance(audio, str) or not audio or not _num(start) or not _num(end):
        return None
    return voices.seg_key(audio, start, end)


def snapshot(parsed: dict | None) -> dict[str, list]:
    """{行の鍵: [speakerID, 話し手の名前]}（テレビなどの声は入れない）"""
    out: dict[str, list] = {}
    for conversation in (parsed or {}).get("conversations") or []:
        if conversation.get("media"):
            continue
        for line in conversation.get("lines") or []:
            if line.get("media") is not None:
                continue
            key = _key(line)
            if key is not None:
                out[key] = [line.get("speakerID"), str(line.get("speaker") or "")]
    return out


def _label(ident, name: str) -> str | None:
    return voices.label_of({"speakerID": ident, "speaker": name})


def _sample_of(key: str) -> dict | None:
    audio, start, end = key.rsplit("|", 2)
    s = {"audio": audio, "start": float(start), "end": float(end)}
    return s if SAMPLE_LEN[0] <= s["end"] - s["start"] <= SAMPLE_LEN[1] else None


def _pick(keys) -> list[dict]:
    got = [s for s in (_sample_of(k) for k in keys) if s]
    got.sort(key=lambda s: -(s["end"] - s["start"]))
    return got[:SAMPLES]


def diff_pairs(day: str, before: dict[str, list], after: dict[str, list], others: dict[str, dict[str, list]] | None = None
               ) -> list[dict]:
    """1 日の記録の話し手の直しから組を作る。others は同じ窓のほかの日の今の記録（移した先の人の行を探す）"""
    moves: dict[tuple, list[str]] = {}
    for key, old in before.items():
        new = after.get(key)
        if new is None or new[0] == old[0] or old[0] in (None, ""):
            continue
        to_label = _label(new[0], new[1])
        if to_label is None or not (to_label == voices.SELF_LABEL or to_label.startswith("n:")):
            continue   # 名前の無い人どうしの付け替えは、機械のまとめのことがあるので答えにしない
        if _label(old[0], old[1]) is None:
            continue
        moves.setdefault((str(old[0]), str(new[0])), []).append(key)
    out = []
    for (old_id, new_id), keys in sorted(moves.items()):
        if len(keys) > BULK_MAX:
            continue
        moved = _pick(keys)
        if not moved:
            continue
        keyset = set(keys)
        to_before = [k for k, v in before.items() if str(v[0]) == new_id and k not in keyset]
        if not to_before and others:
            for other in others.values():
                to_before += [k for k, v in other.items() if str(v[0]) == new_id]
        left = [k for k, v in after.items() if str(v[0]) == old_id]
        sig = _hash(f"{day}|{old_id}|{new_id}|" + "|".join(sorted(keys)))
        same_side = _pick(to_before)
        if same_side:
            out.append({"id": f"s29r-{sig}-s", "same": True, "people": [moved, same_side], "day": day, "orig_same": False})
        diff_side = _pick(left)
        if diff_side:
            out.append({"id": f"s29r-{sig}-d", "same": False, "people": [moved, diff_side], "day": day, "orig_same": True})
    return out


def scan_records(home: Path, read_day, today: datetime.date | None = None, window: int = WINDOW) -> dict:
    """直近 window 日の記録を前の写しと比べ、直しから組を作って answers.json に足す。{"days","pairs","new"}"""
    today = today or datetime.date.today()
    days = [(today - datetime.timedelta(days=k)).isoformat() for k in range(window - 1, -1, -1)]
    now_snaps = {}
    for day in days:
        parsed = read_day(day)
        if parsed is not None:
            now_snaps[day] = snapshot(parsed)
    store = load(home)
    got = {"days": len(now_snaps), "pairs": 0, "new": 0}
    changed = False
    for day, after in now_snaps.items():
        path = folder(home) / SNAP / f"{day}.json"
        before = _read(path, None)
        if isinstance(before, dict):
            others = {d: s for d, s in now_snaps.items() if d != day}
            for pair in diff_pairs(day, before, after, others):
                got["pairs"] += 1
                if pair["id"] not in store["pairs"]:
                    got["new"] += 1
                if add(store, pair["id"], pair["same"], pair["people"], day, "records", "records", pair["orig_same"]):
                    changed = True
        if before != after:
            try:
                _write(path, after)
            except OSError:
                pass
    for path in (folder(home) / SNAP).glob("????-??-??.json"):
        if path.stem < days[0]:
            try:
                path.unlink()
            except OSError:
                pass
    if changed:
        save(home, store, today)
    return got


def counts(home: Path) -> dict:
    """{"total","same","by_source": {...}}"""
    rows = load(home)["pairs"].values()
    by: dict[str, int] = {}
    for r in rows:
        by[str(r.get("source"))] = by.get(str(r.get("source")), 0) + 1
    return {"total": len(rows), "same": sum(1 for r in rows if r.get("same")), "by_source": by}


# MARK: - s23voice への足し（s29pc.start が入れる）


def wrap_answers(original, home_of):
    def answers(base):
        out = dict(original(base))
        home = home_of()
        if home is not None:
            mine = known(home)
            # まとまり全体の答え（s29g-）と s29_pairs のある答えは "<id>#<番号>" の組で数える（split を「違う 2 人」にしない）
            for k in [k for k in out if k.startswith("s29g-") or any(x.startswith(k + "#") for x in mine)]:
                out.pop(k, None)
            for k, v in mine.items():
                out.setdefault(k, v)
        return out

    answers.s29p_wrapped = True  # type: ignore[attr-defined]
    return answers


def wrap_groups(original):
    def groups_with_samples(home):
        out = dict(original(home))
        try:  # s29_groups のかたまり（アプリがまとまり全体に答えたとき、id がかたまりの id になる）
            import s29pgroups

            for k, v in s29pgroups.seen_groups(home).items():
                out.setdefault(k, v)
        except Exception:  # noqa: BLE001
            pass
        for k, v in pairs(home).items():
            out.setdefault(k, v)
        return out

    groups_with_samples.s29p_wrapped = True  # type: ignore[attr-defined]
    return groups_with_samples


def received(home: Path, days: int = 7, today: datetime.date | None = None) -> dict:
    body = _read(folder(home) / "received.json", {}) or {}
    today = today or datetime.date.today()
    limit = (today - datetime.timedelta(days=days - 1)).isoformat()
    out = {"app_old": 0, "app_s29": 0, "dropped_fields": 0}
    for d, entry in body.items():
        if d >= limit and isinstance(entry, dict):
            for k in out:
                out[k] += int(entry.get(k, 0) or 0)
    return out


def _now() -> float:
    return time.time()
