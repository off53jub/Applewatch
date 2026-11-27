"""LifeLog PC: s33（2026-11-27。担当 p）の口。取り決め K33-1・K33-2（名前と形を変えない）。

- GET /s33（オーナーの Bearer）: 母艦の state/s33_for_app.json をそのまま返す（K33-1）。
  覚え（更新時刻と大きさが同じなら読み直さない）・大きすぎ・壊れ・無い・止めてある・母艦が無い → {"available": false, "reason": …}
  features "s33"（ファイルがあって、止めていないとき）。止める切り替え: state/s27_work_config.json の "s33p": {"s33": false}
- POST /feedback の kind（K33-2。appfeeds.parse_feedback から parse_feedback を呼ぶ。母艦の inbox/app_feedback.jsonl に 1 行）:
  ramen_mark（強22。at・place・lat・lon）・feature_seen（強5。day・counts）・device_ok（強8。build・screens・crash）
  ramen_mark の at は食べた時刻なので上書きしない（届いた時刻は received_at）。中身は記録（log.txt）に書かない。
- GET /s33/ports（強30 の PC 側。オーナーの Bearer）: 開いている口の一覧・どれが鍵つきか・外から届くか（Funnel）。
  分かる範囲だけ。鍵・合言葉・Funnel の名前は返さない。閉じない・変えない（点検だけ）。
"""

from __future__ import annotations

import datetime
import importlib
import re
import sys
from pathlib import Path

import appfeeds
import s27pwork

S33 = Path("state") / "s33_for_app.json"
GETS = ("/s33", "/s33/ports")
KINDS = ("ramen_mark", "feature_seen", "device_ok")
KEEP_AT = ("ramen_mark",)          # 本人の時刻（at）を上書きしない種類
S33_READ_MAX = 12 * 1024 * 1024    # これより大きければ読まない（仮）
PLACE_MAX = 80
COUNTS_MAX = 200
SCREENS_MAX = 100
COUNT_LIMIT = 1_000_000
BUILD = re.compile(r"[A-Za-z0-9.]{1,20}")
NAME = re.compile(r"[A-Za-z0-9_.:\- ]{1,64}")
CONTROL = re.compile(r"[\x00-\x1f\x7f]")


# MARK: - 切り替え・features


def _switch(base: Path | None) -> bool:
    """state/s27_work_config.json の "s33p" の "s33"（書かなければオン）"""
    if base is None:
        return True
    data, _ = s27pwork._load(base, s27pwork.CONFIG, 64 * 1024)
    mine = data.get("s33p") if isinstance(data, dict) else None
    value = mine.get("s33") if isinstance(mine, dict) else None
    return value if isinstance(value, bool) else True


def features(base: Path | None) -> list[str]:
    if base is None or not Path(base).is_dir() or not _switch(base):
        return []
    return ["s33"] if (Path(base) / S33).is_file() else []


# MARK: - POST /feedback


def _iso(value) -> str:
    if not isinstance(value, str) or not 10 <= len(value) <= 40 or CONTROL.search(value):
        raise ValueError("at は ISO の日時です")
    try:
        datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        raise ValueError("at は ISO の日時です") from None
    return value


def _coord(value, low: float, high: float, name: str):
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value != value or not low <= value <= high:
        raise ValueError(f"{name} は {low:g}〜{high:g} の数か null です")
    return value


def _name(value) -> str:
    if not isinstance(value, str) or NAME.fullmatch(value) is None:
        raise ValueError("画面の名前は英数字と _ . : - と空白で 64 文字までです")
    return value


def parse_feedback(body: dict) -> dict:
    """K33-2 の kind。おかしければ ValueError"""
    kind = body.get("kind")
    if kind not in KINDS:
        raise ValueError("kind は " + "・".join(KINDS) + " のどれかです")
    if kind == "ramen_mark":
        place = body.get("place")
        if place is not None and (not isinstance(place, str) or len(place) > PLACE_MAX or CONTROL.search(place)):
            raise ValueError(f"place は {PLACE_MAX} 文字までの文か null です")
        return {"kind": kind, "at": _iso(body.get("at")), "place": place,
                "lat": _coord(body.get("lat"), -90, 90, "lat"), "lon": _coord(body.get("lon"), -180, 180, "lon")}
    if kind == "feature_seen":
        day = appfeeds._day(body.get("day"))
        if day is None:
            raise ValueError("day は YYYY-MM-DD です")
        counts = body.get("counts")
        if not isinstance(counts, dict) or len(counts) > COUNTS_MAX:
            raise ValueError(f"counts は名前→回数で {COUNTS_MAX} 個までです")
        clean = {}
        for key, n in counts.items():
            if isinstance(n, bool) or not isinstance(n, int) or not 0 <= n <= COUNT_LIMIT:
                raise ValueError("counts の回数は 0 以上の整数です")
            clean[_name(key)] = n
        return {"kind": kind, "day": day, "counts": clean}
    build = body.get("build")
    if not isinstance(build, str) or BUILD.fullmatch(build) is None:
        raise ValueError("build は英数字と . で 20 字までです")
    screens = body.get("screens")
    if not isinstance(screens, list) or len(screens) > SCREENS_MAX:
        raise ValueError(f"screens は名前の並びで {SCREENS_MAX} 個までです")
    if not isinstance(body.get("crash"), bool):
        raise ValueError("crash は true か false です")
    return {"kind": kind, "build": build, "screens": [_name(x) for x in screens], "crash": body["crash"]}


# MARK: - GET /s33


def _off(reason: str) -> dict:
    return {"available": False, "reason": reason}


def read_s33(base: Path) -> dict:
    """母艦のファイルをそのまま返す（available は足さない。K33-1）"""
    data, failure = s27pwork._load(base, S33, S33_READ_MAX)
    if data is None:
        return _off(s27pwork._reason("s33 のまとめ", failure))
    return data


# MARK: - GET /s33/ports（強30 の PC 側。読むだけ）

_ROUTE = re.compile(r'(?:url\.)?path\s+(?:in|==)\s+(?:(\w+)\.(GETS|POSTS)|"(/[^"]*)")')


def _source() -> str:
    try:
        return (Path(__file__).resolve().parent / "lifelog_pc.py").read_text(encoding="utf-8")
    except OSError:
        return ""


def _routes() -> list[dict]:
    """lifelog_pc.py の do_GET・do_POST を読んで道を拾う（分かる範囲。直後の数行に authorized() があれば Bearer）"""
    lines = _source().splitlines()
    out: dict[tuple[str, str], str] = {}
    method = None
    gated = False   # 「if not self.authorized(): return」より後ろの道は、みな Bearer
    for i, line in enumerate(lines):
        head = re.match(r"\s+def (\w+)\(", line)
        if head:
            name = head.group(1)
            method = name[3:] if name in ("do_GET", "do_POST", "do_DELETE") else None
            gated = False
            continue
        if method is not None and re.match(r"\s{8}if not self\.authorized\(\):", line):
            gated = True
            continue
        if method is None:
            continue
        found = _ROUTE.search(line)
        if not found:
            continue
        module, attr, literal = found.groups()
        paths: list[str] = []
        if literal:
            paths = [literal]
        elif module:
            mod = sys.modules.get(module)
            if mod is None:
                try:
                    mod = importlib.import_module(module)
                except Exception:  # noqa: BLE001
                    mod = None
            paths = [p for p in (getattr(mod, attr, ()) or ()) if isinstance(p, str)]
        auth = "bearer" if gated or "self.authorized()" in "\n".join(lines[i:i + 4]) else "other"
        for p in paths:
            out.setdefault((method, p), auth)
    return [{"method": m, "path": p, "auth": a} for (m, p), a in sorted(out.items())]


def _funnel() -> dict:
    try:
        import watchroute

        if not watchroute.W.port:
            return {"known": True, "on": False}
        return {"known": True, "on": bool(watchroute.funnel())}
    except Exception:  # noqa: BLE001
        return {"known": False, "on": None}


def read_ports(handler=None) -> dict:
    ports = []
    try:
        address = handler.server.server_address
        ports.append({"name": "main", "port": int(address[1]), "bind": str(address[0])})
    except Exception:  # noqa: BLE001
        pass
    external: list[dict] = []
    try:
        import linehook
        import s25pline
        import watchroute

        if watchroute.W.port:
            ports.append({"name": "watch", "port": int(watchroute.W.port), "bind": "127.0.0.1"})
        external = [{"method": m, "path": p, "auth": "watch_token"} for m, p in sorted(watchroute.PATHS)]
        external += [{"method": "POST", "path": p, "auth": "signature"} for p in (linehook.PATH, s25pline.PATH)]
    except Exception:  # noqa: BLE001
        pass
    funnel = _funnel()
    routes = _routes()
    return {"available": True, "generated_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
            "ports": ports, "funnel": funnel, "routes": routes,
            "bearer_count": sum(1 for r in routes if r["auth"] == "bearer"),
            "other_auth": [r for r in routes if r["auth"] != "bearer"],
            "reachable_from_outside": external if funnel.get("on") else [],
            "via_funnel_if_on": external,
            "note": "分かる範囲です（ソースの道を読んだ一覧）。鍵・Funnel の名前は返しません。閉じる・変えるのは本人です"}


# MARK: - 受け口


def http_get(handler, path: str, query: str, base: Path | None) -> None:
    """GET /s33・/s33/ports（合言葉は lifelog_pc.py が確かめてから）"""
    if base is not None and not Path(base).is_dir():
        base = None
    try:
        if path == "/s33/ports":
            handler.send_json(200, read_ports(handler))
        elif base is None:
            handler.send_json(200, _off("母艦が見つかりません"))
        elif not _switch(base):
            handler.send_json(200, _off("止めてあります"))
        else:
            handler.send_json(200, read_s33(base))
    except Exception as error:  # noqa: BLE001
        handler.send_json(200, _off(f"読めませんでした: {type(error).__name__}"))
