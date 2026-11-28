"""LifeLog PC: 時間を選んで、家の PC の記録と音声のその時間だけを消す口（s20 の次11。2026-11-21。アプリの「時間を選んで消す」の PC 側）。

POST /records/<日>/forget  {"from": "ISO 8601（時差つき）", "to": "…"}   （合言葉は Bearer。24 時間まで）
  その時間（from 以上・to 未満）の
  - 記録（records/<日>.json と <日>.prev.json）の行を消す。行がなくなった会話は会話ごと消す。一部だけ消えた会話は、
    題・要点・議事録の文（消した行の中身が混ざっているかもしれない）を空にする。ほかの項目・形は変えない（iPhone の形のまま。省略可能な欄だけ動く）。
  - 音声（audio/<日>/・仕事の置き場 jobs/ の .audio・答え）のうち、その時間にすっぽり入る区切りを消す。
    一部だけ重なる区切りは音声を切れないので残し、数（audio_partial）を返す。
  - 意味で探す索引（semantic.db）のその時間の行・その音声の声の特徴（voices/<日>.npz）。
  消す前に、消すものの控えを HOME/forget-backup/<id>/ に 7 日だけ残す（BACKUP_DAYS。そのあと自動で消える）。
  答え: {"ok", "id", "day", "removed_lines", "removed_conversations", "touched_conversations", "audio_removed", "audio_partial",
        "backup_until"}。何も消すものが無くても 200（数は 0。控えは作らない）。
POST /records/<日>/forget/undo {"id": "<答えの id>"}   取り消し（控えがある 7 日のあいだ）
  記録を控えに戻す（消したあとに記録が変わっていたら上書きしないので 409）・音声を戻す。索引・jobs の答えは戻さない
  （記録を置き直すと意味の索引は iPhone が作り直す）。
消した中身は記録（log.txt）に書かない（日と数だけ）。母艦・ドライブ・iPhone の分はここでは消さない（アプリが iPhone の分、母艦は別）。
"""

from __future__ import annotations

import datetime
import hashlib
import json
import os
import re
import shutil
import time
from pathlib import Path
from typing import Callable

import records
import voices

BACKUP_FOLDER = "forget-backup"
BACKUP_DAYS = 7                      # 控えを残す日数（本人の指定）
MAX_SPAN_MS = 24 * 3600 * 1000       # 仮: 1 回に消せる長さ（1 日分）
BODY_LIMIT = 4096
PATH = re.compile(r"/records/(\d{4}-\d{2}-\d{2})/forget(/undo)?")
NAME_TIME = re.compile(r"(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})")
ID = re.compile(r"\d{8}-\d{6}(-\d+)?-\d{4}-\d{2}-\d{2}")
DEFAULT_CHUNK_S = 300.0              # 仮: 行から長さが分からない区切りの長さ
SLACK_S = 2.0
EMPTY_KEYS = ("title", "minutes")    # 一部だけ消えた会話で空にする項目（points は空の並びにする）


def handles(path: str) -> bool:
    return PATH.fullmatch(path) is not None


# MARK: - 読む・切る


def parse_range(data: bytes) -> tuple[int, int]:
    try:
        body = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as error:
        raise ValueError("中身が JSON ではありません") from error
    if not isinstance(body, dict):
        raise ValueError("中身が JSON のまとまりではありません")
    start, end = records.parse_time(body.get("from"), "from"), records.parse_time(body.get("to"), "to")
    if end <= start:
        raise ValueError("to は from より後です")
    if end - start > MAX_SPAN_MS:
        raise ValueError("1 回に消せるのは 24 時間までです")
    return start, end


def _line_ms(line) -> int | None:
    try:
        return records.parse_time(line.get("time"), "time") if isinstance(line, dict) else None
    except ValueError:
        return None


def filter_record(raw: dict, start: int, end: int) -> tuple[dict, dict]:
    """記録の元の JSON から、[start, end) の行を除く（形は変えない）。(新しい JSON, 数) を返す"""
    stats = {"removed_lines": 0, "removed_conversations": 0, "touched_conversations": 0}
    out = []
    for conversation in raw.get("conversations") or []:
        if not isinstance(conversation, dict):
            out.append(conversation)
            continue
        lines = conversation.get("lines") if isinstance(conversation.get("lines"), list) else []
        kept = [x for x in lines if not ((m := _line_ms(x)) is not None and start <= m < end)]
        gone = len(lines) - len(kept)
        if not lines:
            try:
                begun = records.parse_time(conversation.get("start"), "start")
            except ValueError:
                begun = None
            if begun is not None and start <= begun < end:
                stats["removed_conversations"] += 1
                continue
            out.append(conversation)
        elif gone == 0:
            out.append(conversation)
        elif not kept:
            stats["removed_lines"] += gone
            stats["removed_conversations"] += 1
        else:
            stats["removed_lines"] += gone
            stats["touched_conversations"] += 1
            changed = dict(conversation)
            changed["lines"] = kept
            for key in EMPTY_KEYS:
                changed.pop(key, None)
            changed["points"] = []
            out.append(changed)
    new = dict(raw)
    new["conversations"] = out
    return new, stats


def _dump(raw: dict) -> bytes:
    return json.dumps(raw, ensure_ascii=False).encode("utf-8")


def name_start_ms(name: str) -> int | None:
    """音声の名前の頭（20261120-050419。この PC の時刻）→ 1970 年からのミリ秒"""
    match = NAME_TIME.match(name)
    if not match:
        return None
    try:
        moment = datetime.datetime(*(int(match.group(i)) for i in range(1, 7))).astimezone()
    except ValueError:
        return None
    return int(moment.timestamp() * 1000)


def _local_dates(start: int, end: int) -> list[str]:
    first = datetime.datetime.fromtimestamp(start / 1000).date()
    last = datetime.datetime.fromtimestamp((end - 1) / 1000).date()
    return [(first + datetime.timedelta(days=i)).strftime("%Y%m%d") for i in range((last - first).days + 1)]


def plan_audio(store, raw: dict, start: int, end: int, jobs) -> dict:
    """音声の区切りを「すっぽり入る（消す）」「一部だけ重なる（残す）」に分ける。{"inside": [名前], "partial": [名前]}"""
    dates = _local_dates(start, end)
    names: set[str] = set()
    longest: dict[str, float] = {}
    for conversation in raw.get("conversations") or []:
        for line in (conversation.get("lines") or []) if isinstance(conversation, dict) else []:
            if isinstance(line, dict) and isinstance(line.get("audio"), str):
                names.add(line["audio"])
                tail = line.get("end")
                if isinstance(tail, (int, float)) and not isinstance(tail, bool):
                    longest[line["audio"]] = max(longest.get(line["audio"], 0.0), float(tail))
    for compact in dates:
        day = f"{compact[:4]}-{compact[4:6]}-{compact[6:]}"
        try:
            names.update(p.name for p in (store.audio / day).glob("*") if p.is_file())
        except OSError:
            pass
    if jobs is not None:
        with jobs.lock:
            names.update(n for n in jobs.jobs if isinstance(n, str))
    starts = {n: name_start_ms(n) for n in names if records.safe_audio_name(n)}
    starts = {n: s for n, s in starts.items() if s is not None and any(n.startswith(d) for d in dates)}
    order = sorted(starts.values())
    inside, partial = [], []
    for name, begun in starts.items():
        later = [s for s in order if s > begun]
        if name in longest:
            finish = begun + (longest[name] + SLACK_S) * 1000
            if later:
                finish = min(finish, later[0])
        else:
            finish = min(later[0], begun + DEFAULT_CHUNK_S * 1000) if later else begun + DEFAULT_CHUNK_S * 1000
        if begun >= start and finish <= end:
            inside.append(name)
        elif begun < end and finish > start:
            partial.append(name)
    return {"inside": sorted(inside), "partial": sorted(partial)}


# MARK: - 控え


def backup_root(home: Path) -> Path:
    return Path(home) / BACKUP_FOLDER


def purge(home: Path, now: float | None = None) -> int:
    """7 日より古い控えを消す。消した数を返す"""
    now = time.time() if now is None else now
    removed = 0
    try:
        folders = [p for p in backup_root(home).iterdir() if p.is_dir()]
    except OSError:
        return 0
    for folder in folders:
        try:
            meta = json.loads((folder / "meta.json").read_text(encoding="utf-8"))
            until = float(meta["until_ts"])
        except (OSError, ValueError, KeyError, TypeError):
            until = folder.stat().st_mtime + BACKUP_DAYS * 86400
        if until <= now:
            shutil.rmtree(folder, ignore_errors=True)
            removed += 1
    return removed


def _new_id(home: Path, day: str, now: float) -> str:
    base = time.strftime("%Y%m%d-%H%M%S", time.localtime(now))
    n = 0
    while True:
        ident = f"{base}-{day}" if n == 0 else f"{base}-{n}-{day}"
        if not (backup_root(home) / ident).exists():
            return ident
        n += 1


def _move(src: Path, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.replace(src, dest)
    except OSError:
        shutil.copy2(src, dest)
        src.unlink()


def _drop_voices(home: Path, names: list[str]) -> int:
    """消した音声の声の特徴（voices/<日>.npz の "<名前>|…"）を消す"""
    removed = 0
    wanted = tuple(n + "|" for n in names)
    if not wanted:
        return 0
    for path in voices.folder(home).glob("????-??-??.npz"):
        ds = voices.DayStore(home, path.stem).load()
        hit = [k for k in ds.vectors if k.startswith(wanted)]
        if not hit:
            continue
        for key in hit:
            del ds.vectors[key]
        ds.bad = {k for k in ds.bad if not k.startswith(wanted)}
        ds.save()
        removed += len(hit)
    return removed


def _drop_index(semantic, start: int, end: int) -> int:
    if semantic is None or not getattr(semantic, "enabled", False):
        return 0
    try:
        with semantic.lock, semantic.connect() as db:
            count = db.execute("DELETE FROM items WHERE time >= ? AND time < ?", (start / 1000.0, end / 1000.0)).rowcount
            semantic._cache = None
        return count
    except Exception:  # noqa: BLE001 — 索引が消せなくても、記録と音声は消す
        return 0


def forget(store, day: str, start: int, end: int, semantic=None, jobs=None, now: float | None = None) -> dict:
    """[start, end) の記録と音声を、控えを残して消す。数を返す（ValueError は日の形が違うときだけ）"""
    if not records.valid_day(day):
        raise ValueError("日の名前は YYYY-MM-DD です")
    now = time.time() if now is None else now
    home = store.home
    purge(home, now)
    path, prev_path = store.path(day), store.prev_path(day)
    with store.lock:
        try:
            current = path.read_bytes()
            raw = json.loads(current.decode("utf-8"))
            if not isinstance(raw, dict):
                raise ValueError
        except (OSError, ValueError):
            current, raw = None, {"conversations": []}
        try:
            prev_bytes = prev_path.read_bytes()
            prev_raw = json.loads(prev_bytes.decode("utf-8"))
            if not isinstance(prev_raw, dict):
                raise ValueError
        except (OSError, ValueError):
            prev_bytes, prev_raw = None, None
    new_raw, stats = filter_record(raw, start, end)
    plan = plan_audio(store, raw, start, end, jobs)
    result = {"ok": True, "id": None, "day": day, **stats, "audio_removed": len(plan["inside"]),
              "audio_partial": len(plan["partial"]), "backup_until": None}
    if not (stats["removed_lines"] or stats["removed_conversations"] or plan["inside"]):
        return result
    ident = _new_id(home, day, now)
    folder = backup_root(home) / ident
    until = now + BACKUP_DAYS * 86400
    folder.mkdir(parents=True, exist_ok=True)
    if current is not None:
        (folder / "record.json").write_bytes(current)
    if prev_bytes is not None:
        (folder / "record.prev.json").write_bytes(prev_bytes)
    # 音声: 控えへ移す（同じ音声が audio/ と jobs/ の両方にあれば、1 つを控えに・もう 1 つは消す）
    moved = []
    for name in plan["inside"]:
        sources = []
        kept = store.audio_file(name)
        if kept is not None:
            sources.append(kept)
        if jobs is not None:
            mine = jobs.audio_path(name)
            if mine.is_file():
                sources.append(mine)
            for extra_path in (jobs.meta_path(name), jobs.result_path(name)):
                if extra_path.is_file():
                    (folder / "jobs").mkdir(exist_ok=True)
                    shutil.copy2(extra_path, folder / "jobs" / extra_path.name)
        if sources:
            _move(sources[0], folder / "audio" / name)
            for extra in sources[1:]:
                try:
                    extra.unlink()
                except OSError:
                    pass
            moved.append(name)
        if jobs is not None:
            jobs.purge(name)
    # 記録を書き換える（put が前のものを .prev に回すので、そのあと .prev も同じ範囲を除いたものに置き直す）
    after_sha = None
    if stats["removed_lines"] or stats["removed_conversations"]:
        data = _dump(new_raw)
        store.put(day, data)
        after_sha = hashlib.sha256(data).hexdigest()
        with store.lock:
            if prev_raw is not None:
                prev_new, _ = filter_record(prev_raw, start, end)
                prev_path.write_bytes(_dump(prev_new))
            else:
                try:
                    prev_path.unlink()
                except OSError:
                    pass
    # s39: 端末ごとに置いた記録（records/devices/<端末>/<日>.json）からも同じ範囲を除く（控えは devices/ に）。
    # 除かないと、次に別の端末が送ったときの合わせで、消した行が戻ってしまう
    for device_path in getattr(store, "device_paths", lambda _d: [])(day):
        try:
            device_bytes = device_path.read_bytes()
            device_raw = json.loads(device_bytes.decode("utf-8"))
            if not isinstance(device_raw, dict):
                raise ValueError
        except (OSError, ValueError):
            continue
        device_new, device_stats = filter_record(device_raw, start, end)
        if not (device_stats["removed_lines"] or device_stats["removed_conversations"]):
            continue
        (folder / "devices").mkdir(exist_ok=True)
        (folder / "devices" / f"{device_path.parent.name}.json").write_bytes(device_bytes)
        with store.lock:
            device_path.write_bytes(_dump(device_new))
    _drop_index(semantic, start, end)
    _drop_voices(home, moved)
    meta = {"id": ident, "day": day, "from": records.iso_ms(start), "to": records.iso_ms(end), "at": now,
            "until_ts": until, "after_sha": after_sha, "audio": moved, "partial": plan["partial"], **stats}
    (folder / "meta.json").write_text(json.dumps(meta, ensure_ascii=False), encoding="utf-8")
    result["id"] = ident
    result["audio_removed"] = len(moved)
    result["backup_until"] = datetime.datetime.fromtimestamp(until).astimezone().isoformat(timespec="seconds")
    return result


def undo(store, day: str, ident: str, now: float | None = None) -> dict:
    """控えから戻す。記録が消したあとに変わっていたら上書きしない（KeyError＝控えが無い・RuntimeError＝記録が変わった）"""
    if not ID.fullmatch(ident or ""):
        raise ValueError("id の形が違います")
    folder = backup_root(store.home) / ident
    try:
        meta = json.loads((folder / "meta.json").read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise KeyError("控えがありません（7 日たつと消えます）") from error
    if meta.get("day") != day:
        raise KeyError("その日の控えではありません")
    restored_record = False
    if (folder / "record.json").is_file() and meta.get("after_sha"):
        with store.lock:
            try:
                now_sha = hashlib.sha256(store.path(day).read_bytes()).hexdigest()
            except OSError:
                now_sha = None
        if now_sha not in (None, meta["after_sha"]):
            raise RuntimeError("消したあとに記録が変わったので、戻せません")
        store.put(day, (folder / "record.json").read_bytes())
        restored_record = True
    # s39: 端末ごとの記録も戻す
    if (folder / "devices").is_dir() and hasattr(store, "device_path"):
        for saved in (folder / "devices").glob("*.json"):
            target = store.device_path(saved.stem, day)
            if target.parent.is_dir():
                target.write_bytes(saved.read_bytes())
    audio = 0
    for name in meta.get("audio") or []:
        src = folder / "audio" / name
        if src.is_file() and records.safe_audio_name(name):
            _move(src, store.audio / records.audio_day(name) / name)
            audio += 1
    shutil.rmtree(folder, ignore_errors=True)
    return {"ok": True, "id": ident, "day": day, "record": restored_record, "audio": audio}


# MARK: - 受け口


def http_post(handler, store, path: str, log: Callable[[str], None], semantic=None, jobs=None) -> None:
    """POST /records/<日>/forget・/forget/undo（lifelog_pc.py の do_POST から。合言葉は Bearer）"""
    if not handler.authorized():
        return
    match = PATH.fullmatch(path)
    if store is None or match is None:
        handler.discard_body()
        handler.send_json(503 if store is None else 404, {"error": "記録の機能は今は使えません"})
        return
    day, is_undo = match.group(1), match.group(2) is not None
    data = records._read(handler, BODY_LIMIT, "消す頼み")
    if data is None:
        return
    try:
        if is_undo:
            body = json.loads(data.decode("utf-8"))
            result = undo(store, day, body.get("id") if isinstance(body, dict) else None)
            log(f"消した記録を戻しました: {day}・音声 {result['audio']}")
        else:
            start, end = parse_range(data)
            result = forget(store, day, start, end, semantic, jobs)
            log(f"時間を選んで消しました: {day}・行 {result['removed_lines']}・会話 {result['removed_conversations']}"
                f"・音声 {result['audio_removed']}（一部だけ重なって残した音声 {result['audio_partial']}）")
    except KeyError as error:
        handler.send_json(404, {"error": error.args[0]})
        return
    except RuntimeError as error:
        handler.send_json(409, {"error": str(error)})
        return
    except (ValueError, UnicodeDecodeError) as error:
        handler.send_json(400, {"error": str(error)})
        return
    except Exception as error:  # noqa: BLE001 — 何があっても受け付けは続ける
        log(f"消す頼みでつまずきました: {type(error).__name__}")
        handler.send_json(500, {"error": f"消せませんでした（{type(error).__name__}）"})
        return
    handler.send_json(200, result)
