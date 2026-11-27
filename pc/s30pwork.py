"""LifeLog PC: s30（2026-11-27。担当 p）の「仕事のまとめを共有したらすぐ作り直す」ための口。取り決め K30-2（名前と形を変えない）。

- POST /work/digest（オーナーの Bearer）
  体: {"entries": [{id, day, text, sections, source, addedAt}, ...]}（work-digests.json の 1 件と同じ形）
  返事: {"accepted": n, "run": "started"|"already"|"off", "available": true}
  母艦の inbox/work_digest_push/<id>.json に 1 件 1 ファイルで書く（一時ファイル→rename の原子的な書き方）。
  そのあと母艦の scripts/Run-WorkNow.py --kick を、窓なし・低い優先度・切り離しで起こす（作業フォルダは母艦）。
  - state/s30_worknow_state.json が running で、始まりが 10 分以内なら起こさず "already"
  - Run-WorkNow.py か Python が見つからなければ "off"（ファイルは書く）
  - 止める切り替え: 母艦の state/s27_work_config.json の "s30p": {"push": false}（無ければオン）。止めているときは書かず
    {"accepted": 0, "run": "off", "available": false}
- GET /work/run（オーナーの Bearer）← state/s30_worknow_state.json を読むだけ。無ければ idle。
  {"state": "idle"|"running", "started_at": ISO|null, "finished_at": ISO|null, "ok": bool|null, "available": true}
- features "workpush"（口が使えるとき＝母艦のフォルダがあって止めていないとき）

検め（仮）: 1 回 50 件まで・1 件の text は 200 KB まで・id は UUID・day は YYYY-MM-DD の本当にある日・text は文字列。
1 件でも違えば全部 400（半端に書かない）。仕事のまとめの文は記録（log）に出さない。数と id の先頭だけ。
"""

from __future__ import annotations

import datetime
import json
import os
import re
import subprocess
import sys
import threading
import time
from pathlib import Path

import s27pwork

INBOX = Path("inbox") / "work_digest_push"
STATE = Path("state") / "s30_worknow_state.json"
SCRIPT = Path("scripts") / "Run-WorkNow.py"

GETS = ("/work/run",)
POSTS = ("/work/digest",)

ENTRIES_MAX = 50                      # 1 回に受ける件数（仮）
TEXT_MAX_BYTES = 200 * 1024           # 1 件の text（仮）
BODY_MAX = 12 * 1024 * 1024           # 体の全部（50 件 × 200KB を JSON に包んだ余裕。仮）
RUNNING_FRESH_SECONDS = 10 * 60       # running がこの時間以内なら起こさない
KICK_GUARD_SECONDS = 20               # 起こした直後（状態のファイルがまだ無いあいだ）の二重起こしを抑える
UUID = re.compile(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
DAY = re.compile(r"\d{4}-\d{2}-\d{2}")

_lock = threading.Lock()
_last_kick = [0.0]
# 試しで差し替える（実際には起こさない）。(スクリプト, Python, 母艦) → None（起こした）。失敗は OSError
SPAWN = None


def features(base: Path | None) -> list[str]:
    """口が使えるとき（母艦のフォルダがあって、止めていないとき）だけ workpush"""
    return ["workpush"] if _open(base) else []


def _switch(base: Path | None) -> bool:
    """state/s27_work_config.json の "s30p" の "push"（書かなければオン）"""
    if base is None:
        return True
    data, _ = s27pwork._load(base, s27pwork.CONFIG, 64 * 1024)
    mine = data.get("s30p") if isinstance(data, dict) else None
    value = mine.get("push") if isinstance(mine, dict) else None
    return value if isinstance(value, bool) else True


def _open(base: Path | None) -> bool:
    return base is not None and Path(base).is_dir() and _switch(base)


# MARK: - 体を検める


def _valid_day(value) -> bool:
    if not isinstance(value, str) or not DAY.fullmatch(value):
        return False
    try:
        datetime.date.fromisoformat(value)
    except ValueError:
        return False
    return True


def check_entries(body) -> tuple[list[dict] | None, str | None]:
    """(残す形の並び, 断る理由)。1 件でも違えば全部断る"""
    entries = body.get("entries") if isinstance(body, dict) else None
    if not isinstance(entries, list) or not entries:
        return None, "entries は 1 件以上の並びです"
    if len(entries) > ENTRIES_MAX:
        return None, f"entries は 1 回 {ENTRIES_MAX} 件までです"
    clean, seen = [], set()
    for n, x in enumerate(entries):
        if not isinstance(x, dict):
            return None, f"{n + 1} 件目の形が違います"
        ident, text = x.get("id"), x.get("text")
        if not isinstance(ident, str) or not UUID.fullmatch(ident):
            return None, f"{n + 1} 件目の id は UUID です"
        if not _valid_day(x.get("day")):
            return None, f"{n + 1} 件目の day は YYYY-MM-DD です"
        if not isinstance(text, str):
            return None, f"{n + 1} 件目の text は文字です"
        try:
            size = len(text.encode("utf-8"))
        except UnicodeEncodeError:
            return None, f"{n + 1} 件目の text を文字にできません"
        if size > TEXT_MAX_BYTES:
            return None, f"{n + 1} 件目の text は {TEXT_MAX_BYTES // 1024} KB までです"
        source = x.get("source")
        if source is not None and not isinstance(source, str):
            return None, f"{n + 1} 件目の source は文字です"
        if ident.lower() in seen:
            continue  # 同じ id が 2 回あれば 1 回だけ
        seen.add(ident.lower())
        row = {"id": ident.lower(), "day": x["day"], "text": text}
        for key in ("sections", "source", "addedAt"):
            if x.get(key) is not None:
                row[key] = x[key]
        clean.append(row)
    return clean, None


# MARK: - 母艦の inbox に置く


def write_entries(base: Path, entries: list[dict]) -> int:
    """1 件 1 ファイル。一時ファイル（.tmp）に書いてから rename。同じ id は置き換え（二重に送られても 1 件）"""
    folder = Path(base) / INBOX
    folder.mkdir(parents=True, exist_ok=True)
    count = 0
    for row in entries:
        final = folder / f"{row['id']}.json"
        tmp = folder / f".{row['id']}.{os.getpid()}.{threading.get_ident()}.tmp"
        try:
            with open(tmp, "w", encoding="utf-8", newline="\n") as handle:
                json.dump(row, handle, ensure_ascii=False)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(tmp, final)
        finally:
            try:
                tmp.unlink()
            except OSError:
                pass
        count += 1
    return count


# MARK: - 状態・起こす


def _parse_time(value) -> datetime.datetime | None:
    if not isinstance(value, str) or not value or len(value) > 40:
        return None
    try:
        parsed = datetime.datetime.fromisoformat(value)
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.astimezone()  # 時刻帯が無ければこの PC の時刻


def read_run(base: Path) -> dict:
    # 小さいファイルで、走っている間に書き換わる。更新時刻と大きさの覚え（s27pwork._load）を通すと、
    # 同じ大きさで同じ時刻の刻みの中に書き直されたとき前の中身が返る（2026-11-27 CI で見つけた）ので、毎回読む
    try:
        raw = (Path(base) / STATE).read_bytes()
        data = json.loads(raw.decode("utf-8")) if len(raw) <= 256 * 1024 else {}
    except (OSError, ValueError, UnicodeDecodeError):
        data = {}
    data = data if isinstance(data, dict) else {}
    started, finished = data.get("started_at"), data.get("finished_at")
    ok = data.get("ok")
    return {"state": "running" if data.get("state") == "running" else "idle",
            "started_at": started if _parse_time(started) else None,
            "finished_at": finished if _parse_time(finished) else None,
            "ok": ok if isinstance(ok, bool) else None, "available": True}


def _running_now(base: Path, now: datetime.datetime) -> bool:
    got = read_run(base)
    started = _parse_time(got["started_at"])
    return got["state"] == "running" and started is not None \
        and abs((now - started).total_seconds()) <= RUNNING_FRESH_SECONDS


def python_path(config: dict) -> Path:
    """母艦のスクリプトを動かす Python（askmother.py と同じ決まり方: config の "mothership_python"・環境変数・Python311）"""
    value = str(config.get("mothership_python") or os.environ.get("LIFELOG_MOTHERSHIP_PYTHON") or "").strip()
    if value:
        return Path(value)
    return Path.home() / "AppData" / "Local" / "Programs" / "Python" / "Python311" / "python.exe"


def _spawn(script: Path, python: Path, base: Path) -> None:
    flags = 0
    if sys.platform == "win32":
        flags = (getattr(subprocess, "CREATE_NO_WINDOW", 0) | getattr(subprocess, "BELOW_NORMAL_PRIORITY_CLASS", 0)
                 | getattr(subprocess, "DETACHED_PROCESS", 0))
    subprocess.Popen([str(python), str(script), "--kick"], cwd=str(base), creationflags=flags, close_fds=True,
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def kick(base: Path, config: dict, now: datetime.datetime | None = None, mono: float | None = None) -> str:
    """"started"・"already"・"off"。呼ぶ側（POST /work/digest）は、ファイルを置いたあとに呼ぶ"""
    base = Path(base)
    script = base / SCRIPT
    if not script.is_file():
        return "off"
    python = python_path(config)
    if SPAWN is None and not python.is_file():
        return "off"
    now = now or datetime.datetime.now().astimezone()
    stamp = time.monotonic() if mono is None else mono
    with _lock:
        # 時計が戻ったように見える（stamp が前より小さい）ときは、抑えない（試しで本物の時刻と作りものの時刻が混ざったとき・2026-11-27 CI）
        if 0 <= stamp - _last_kick[0] < KICK_GUARD_SECONDS or _running_now(base, now):
            return "already"
        try:
            (SPAWN or _spawn)(script, python, base)
        except OSError:
            return "off"
        _last_kick[0] = stamp
    return "started"


# MARK: - 受け口


def http_get(handler, path: str, base: Path | None) -> None:
    """GET /work/run（合言葉は lifelog_pc.py が確かめてから）"""
    if base is None or not Path(base).is_dir():
        handler.send_json(200, {"state": "idle", "started_at": None, "finished_at": None, "ok": None, "available": False,
                                "reason": "母艦が見つかりません"})
        return
    try:
        handler.send_json(200, read_run(base))
    except Exception as error:  # noqa: BLE001
        handler.send_json(200, {"state": "idle", "started_at": None, "finished_at": None, "ok": None, "available": False,
                                "reason": f"読めませんでした: {type(error).__name__}"})


def _read_body(handler) -> tuple[bytes | None, int]:
    """(体, 状態の番号)。体が None のときは状態の番号の答えを返す"""
    try:
        length = int(handler.headers.get("Content-Length") or 0)
    except ValueError:
        length = 0
    if length <= 0:
        return None, 400
    if length > BODY_MAX:
        return None, 413
    return handler.rfile.read(length), 200


def http_post(handler, path: str, config: dict, base: Path | None, log=None) -> None:
    """POST /work/digest（合言葉は lifelog_pc.py が確かめてから）。log は文字 1 つを受ける（中身は渡さない）"""
    say = log or (lambda message: None)
    if base is not None and not Path(base).is_dir():
        base = None
    if base is None or not _switch(base):
        discard = getattr(handler, "discard_body", None)
        if discard:
            discard()
        reason = "母艦が見つかりません" if base is None else "止めてあります"
        handler.send_json(200, {"accepted": 0, "run": "off", "available": False, "reason": reason})
        return
    raw, status = _read_body(handler)
    if raw is None:
        discard = getattr(handler, "discard_body", None)
        if discard:
            discard()
        handler.send_json(status, {"error": "中身がありません" if status == 400 else "長すぎます"})
        return
    try:
        body = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        handler.send_json(400, {"error": "JSON ではありません"})
        return
    entries, problem = check_entries(body)
    if entries is None:
        say("POST /work/digest: 形が違うので断りました")
        handler.send_json(400, {"error": problem})
        return
    try:
        written = write_entries(base, entries)
    except OSError as error:
        say(f"POST /work/digest: 母艦に書けませんでした: {type(error).__name__}")
        handler.send_json(500, {"error": "母艦に書けませんでした"})
        return
    run = kick(base, config)
    say(f"POST /work/digest: {written} 件を受け取り・起こし {run}（id {entries[0]['id'][:8]}…）")
    handler.send_json(200, {"accepted": written, "run": run, "available": True})
