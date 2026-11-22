"""LifeLog PC: s22（2026-11-22）の、アプリが読む道（担当 A1 のアプリが features の名前で使う）。0 円・読むだけ。

- 楽5「報告の棚」（features "reports"）:
  GET /reports → {"generated_at", "reports": [{"name", "title", "updated_at", "bytes"}]}
  GET /reports/<name> → 母艦 reports/<name> の md の本文（text/markdown; charset=utf-8）
  出すのは、母艦の state/reports_for_app.json（担当 M が作る。{"allow": ["recording-experiment.md", …]}）にある名前だけ。
  そのファイルが無い・読めないときは何も出さない（一覧は空・本文は 404）。名前は英数字と . _ - だけで .md で終わるもの
  （"..""/""\\" は許さない）。reports/ の直下にあるものだけ。1 つ 2MB まで。title は本文の最初の「# 」の行（無ければ名前）。
- 楽20（features "gappatterns"）: GET /capture-gap-patterns → 母艦 state/capture_gap_patterns.json をそのまま（JSON のまとまり）。
  無い・読めないときは {"available": false, "reason"}。
- 確7〜確10（features "speakertags"）: GET /speaker-tags?day=YYYY-MM-DD → 話し手の札（s22voice.read_tags。HOME の中）。
- 確19・確27: GET /review-queue（s20feeds）の items の後ろに、家の PC が作った確かめ待ち（HOME/s22/review/items.json）を
  足す（答えのあったもの・同じ id は足さない・PC_LIMIT 件まで）。母艦にも inbox/pc-review/candidates.json として写す。
中身（報告の文）は記録（log.txt）に書かない（名前と大きさだけ）。
"""

from __future__ import annotations

import datetime
import json
import re
from pathlib import Path
from urllib.parse import parse_qs, unquote

ALLOW = Path("state") / "reports_for_app.json"
REPORTS = Path("reports")
GAP_PATTERNS = Path("state") / "capture_gap_patterns.json"
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,120}\.md")
REPORT_MAX = 2 * 1024 * 1024
FEATURES = ["reports", "gappatterns", "speakertags"]
GETS = ("/reports", "/capture-gap-patterns", "/speaker-tags")
PREFIX = "/reports/"
PC_LIMIT = 8


def handles(path: str) -> bool:
    return path in GETS or path.startswith(PREFIX)


def safe_name(name: str) -> bool:
    return bool(NAME.fullmatch(name or "")) and ".." not in name and "/" not in name and "\\" not in name


def allowed(base: Path | None) -> list[str]:
    """母艦の state/reports_for_app.json の allow（安全な名前だけ・順はそのまま）。無ければ空"""
    if base is None:
        return []
    try:
        body = json.loads((Path(base) / ALLOW).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    names = body.get("allow") if isinstance(body, dict) else None
    out = []
    for name in names if isinstance(names, list) else []:
        if isinstance(name, str) and safe_name(name) and name not in out:
            out.append(name)
    return out


def _title(text: str, name: str) -> str:
    for raw in text.splitlines()[:40]:
        if raw.startswith("# "):
            return raw[2:].strip()[:120] or name
    return name


def list_reports(base: Path | None) -> dict:
    out = []
    for name in allowed(base):
        path = Path(base) / REPORTS / name
        try:
            stat = path.stat()
            if not path.is_file() or stat.st_size > REPORT_MAX:
                continue
            head = path.read_text(encoding="utf-8", errors="replace")[:20000]
        except OSError:
            continue
        out.append({"name": name, "title": _title(head, name),
                    "updated_at": datetime.datetime.fromtimestamp(stat.st_mtime).astimezone().isoformat(timespec="seconds"),
                    "bytes": stat.st_size})
    return {"generated_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"), "reports": out}


def read_report(base: Path | None, name: str) -> bytes | None:
    if not safe_name(name) or name not in allowed(base):
        return None
    path = Path(base) / REPORTS / name
    try:
        if path.resolve().parent != (Path(base) / REPORTS).resolve() or not path.is_file():
            return None
        data = path.read_bytes()
    except OSError:
        return None
    return data if len(data) <= REPORT_MAX else None


def read_gap_patterns(base: Path | None) -> dict:
    if base is None:
        return {"available": False, "reason": "母艦が見つかりません"}
    try:
        body = json.loads((Path(base) / GAP_PATTERNS).read_text(encoding="utf-8"))
    except OSError:
        return {"available": False, "reason": "母艦の録れない場所・時間の表がまだありません"}
    except ValueError:
        return {"available": False, "reason": "母艦の録れない場所・時間の表が読めません"}
    if not isinstance(body, dict):
        return {"available": False, "reason": "母艦の録れない場所・時間の表の形が違います"}
    return body


def http_get(handler, path: str, query: str, base: Path | None, home: Path | None, log) -> None:
    """認証は呼ぶ側が済ませてから"""
    if path == "/reports":
        handler.send_json(200, list_reports(base))
        return
    if path == "/capture-gap-patterns":
        handler.send_json(200, read_gap_patterns(base))
        return
    if path == "/speaker-tags":
        import s22voice

        day = (parse_qs(query or "").get("day") or [None])[0]
        handler.send_json(200, s22voice.read_tags(home, day) if home is not None else {"available": False})
        return
    name = unquote(path[len(PREFIX):])
    data = read_report(base, name)
    if data is None:
        handler.send_json(404, {"available": False, "reason": "その報告は出していません"})
        return
    log(f"{handler.client_address[0]} に報告 {name} を渡しました（{len(data)} バイト）")
    handler.send_response(200)
    handler.send_header("Content-Type", "text/markdown; charset=utf-8")
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)


# MARK: - 確19・確27 家の PC の確かめ待ち


def pc_items(home: Path | None) -> list[dict]:
    if home is None:
        return []
    try:
        body = json.loads((Path(home) / "s22" / "review" / "items.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    items = body.get("items") if isinstance(body, dict) else None
    return [i for i in items if isinstance(i, dict)] if isinstance(items, list) else []


def answered_ids(base: Path | None) -> set[str]:
    if base is None:
        return set()
    try:
        rows = (Path(base) / "inbox" / "app_feedback.jsonl").read_text(encoding="utf-8").splitlines()
    except OSError:
        return set()
    out = set()
    for raw in rows[-20000:]:
        try:
            row = json.loads(raw)
        except ValueError:
            continue
        if isinstance(row, dict) and row.get("kind") == "review" and isinstance(row.get("id"), str):
            out.add(row["id"])
    return out


def merge_review(body: dict, base: Path | None, home: Path | None) -> dict:
    """GET /review-queue の答えに、家の PC の確かめ待ちを足す（母艦の列が無いときも、PC の分だけで出す）"""
    extra = pc_items(home)
    if not extra:
        return body
    if not body.get("available"):
        body = {"available": True, "version": 1, "items": []}
    items = list(body.get("items") or [])
    seen = {i.get("id") for i in items if isinstance(i, dict)} | answered_ids(base)
    added = 0
    for item in extra:
        if added >= PC_LIMIT or item.get("id") in seen:
            continue
        items.append(item)
        seen.add(item.get("id"))
        added += 1
    body["items"] = items
    return body
