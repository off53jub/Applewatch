"""2026-11-27（s33。担当 p）: 家の PC の s33 の分を確かめる（K33-1 の GET /s33・K33-2 の POST /feedback 3 種・GET /s33/ports）。

    python pc/v33checks_s33p.py          （v32checks_s32p.py の最後にも呼ばれる。CI の手順を増やさずに動かすため）

本物の HOME・母艦・iPhone は使わない（一時フォルダに作り物の母艦を作る）。名前・場所・文はすべて作りもの。
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import threading
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

if not any(mark in os.environ.get("LOCALAPPDATA", "") for mark in ("v25s", "v26s", "v27s", "v30s", "v31s", "v32s", "v33s")):
    os.environ["LOCALAPPDATA"] = str(Path(tempfile.mkdtemp(prefix="v33s-local-")))

import s33pwork  # noqa: E402
from v6checks import say  # noqa: E402

TMP = Path(tempfile.mkdtemp(prefix="v33s-"))
KEY = "check-key"
SECRET_WORD = "見本のひみつの鍵（作りもの）"
SAMPLE = {"version": 1, "stopped": [{"source": "見本ソース", "last_ok": "2026-11-26", "missing": 1, "why": "見本"}],
          "ramen": {"year": 2026, "bowls": 3}}


class Fake:
    def __init__(self) -> None:
        self.sent: list = []

    def send_json(self, status: int, body) -> None:
        self.sent = [status, body]


def mother(name: str, body=SAMPLE, config=None) -> Path:
    base = TMP / name
    (base / "state").mkdir(parents=True, exist_ok=True)
    if body is not None:
        (base / s33pwork.S33).write_text(json.dumps(body, ensure_ascii=False) if not isinstance(body, str) else body, encoding="utf-8")
    if config is not None:
        (base / "state" / "s27_work_config.json").write_text(json.dumps(config), encoding="utf-8")
    return base


def get(base, path="/s33") -> tuple:
    f = Fake()
    s33pwork.http_get(f, path, "", base)
    return f.sent


def check_get() -> int:
    failed = 0
    st, r = get(mother("ok"))
    failed += say(st == 200 and r == SAMPLE, "GET /s33: 母艦のファイルをそのまま返す")
    st, r = get(TMP / "none")
    failed += say(st == 200 and r.get("available") is False, "母艦が無い → available false")
    st, r = get(mother("nofile", body=None))
    failed += say(r.get("available") is False and "まだありません" in r.get("reason", ""), "ファイルが無い → available false")
    st, r = get(mother("broken", body="{こわれた"))
    failed += say(r.get("available") is False, "壊れている → available false")
    st, r = get(mother("list", body="[1,2]"))
    failed += say(r.get("available") is False, "オブジェクトでない → available false")
    saved = s33pwork.S33_READ_MAX
    try:
        s33pwork.S33_READ_MAX = 10
        st, r = get(mother("big"))
        failed += say(r.get("available") is False and "大きすぎ" in r.get("reason", ""), "大きすぎ → available false")
    finally:
        s33pwork.S33_READ_MAX = saved
    off = mother("off", config={"s33p": {"s33": False}})
    st, r = get(off)
    failed += say(r.get("available") is False and "止めて" in r.get("reason", ""), "止める切り替え（s33: false）")
    failed += say(s33pwork.features(off) == [] and s33pwork.features(mother("on")) == ["s33"]
                  and s33pwork.features(mother("nof", body=None)) == [] and s33pwork.features(None) == [],
                  "features: ファイルがあって止めていないときだけ s33")
    # 覚え: 同じ更新時刻・大きさなら読み直さない（中身を同じ大きさで差し替えても、時刻を戻せば古いまま）
    base = mother("cache")
    get(base)
    path = base / s33pwork.S33
    stamp = path.stat()
    path.write_text(json.dumps(SAMPLE, ensure_ascii=False).replace("見本ソース", "別のソース"), encoding="utf-8")
    os.utime(path, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
    if path.stat().st_size == stamp.st_size:
        st, r = get(base)
        failed += say(r["stopped"][0]["source"] == "見本ソース", "覚え: 同じ時刻・大きさなら読み直さない")
    return failed


def post(row: dict) -> str | None:
    """parse_feedback（appfeeds 経由）。おかしければ理由、よければ None"""
    import appfeeds

    try:
        appfeeds.parse_feedback(json.dumps(row).encode("utf-8"))
    except ValueError as error:
        return str(error)
    return None


RAMEN = {"kind": "ramen_mark", "at": "2026-11-27T12:30:00+09:00", "place": "見本らーめん店", "lat": 35.68, "lon": 139.76}
SEEN = {"kind": "feature_seen", "day": "2026-11-27", "counts": {"Work": 3, "Ramen": 0}}
DEVICE = {"kind": "device_ok", "build": "450.1", "screens": ["Work", "Ramen"], "crash": False}


def check_feedback() -> int:
    failed = 0
    for row, label in ((RAMEN, "ramen_mark"), (SEEN, "feature_seen"), (DEVICE, "device_ok")):
        failed += say(post(row) is None, f"{label}: 正しい形は受ける")
    failed += say(post({"kind": "ramen_mark", "at": "2026-11-27T12:30:00Z", "place": None, "lat": None, "lon": None}) is None
                  and post({"kind": "ramen_mark", "at": "2026-11-27T12:30:00"}) is None, "ramen_mark: 場所なし・Z・省略も受ける")
    bad = [
        ({**RAMEN, "at": "きのう"}, "ramen at が ISO でない"),
        ({**RAMEN, "at": None}, "ramen at が無い"),
        ({**RAMEN, "place": "あ" * 81}, "ramen place が 81 字"),
        ({**RAMEN, "place": 5}, "ramen place が文字でない"),
        ({**RAMEN, "lat": "35"}, "ramen lat が文字"),
        ({**RAMEN, "lat": True}, "ramen lat が bool"),
        ({**RAMEN, "lat": 91}, "ramen lat が範囲の外"),
        ({**RAMEN, "lon": 181}, "ramen lon が範囲の外"),
        ({**SEEN, "day": "2026-13-40"}, "seen day が変"),
        ({**SEEN, "counts": {"Work": -1}}, "seen 回数が負"),
        ({**SEEN, "counts": {"Work": 1.5}}, "seen 回数が小数"),
        ({**SEEN, "counts": {"Work": True}}, "seen 回数が bool"),
        ({**SEEN, "counts": {"Work": "3"}}, "seen 回数が文字"),
        ({**SEEN, "counts": {f"S{i}": 1 for i in range(201)}}, "seen counts が 201 個"),
        ({**SEEN, "counts": {"": 1}}, "seen 名前が空"),
        ({**SEEN, "counts": {"あ" * 3: 1}}, "seen 名前に日本語（画面の名前は英数字）"),
        ({**SEEN, "counts": [1]}, "seen counts が配列"),
        ({**DEVICE, "build": "a" * 21}, "device build が 21 字"),
        ({**DEVICE, "build": "4 50"}, "device build に空白"),
        ({**DEVICE, "screens": [f"S{i}" for i in range(101)]}, "device screens が 101 個"),
        ({**DEVICE, "screens": ["a/b"]}, "device screens の名前に /"),
        ({**DEVICE, "screens": "Work"}, "device screens が文字"),
        ({**DEVICE, "crash": "no"}, "device crash が bool でない"),
        ({k: v for k, v in DEVICE.items() if k != "crash"}, "device crash が無い"),
        ({"kind": "ramen_markX"}, "知らない kind"),
    ]
    for row, label in bad:
        failed += say(post(row) is not None, f"おかしな形は断る: {label}")
    ok200 = {"kind": "feature_seen", "day": "2026-11-27", "counts": {f"S{i}": 1 for i in range(200)}}
    failed += say(post(ok200) is None and post({**DEVICE, "screens": [f"S{i}" for i in range(100)]}) is None
                  and post({**RAMEN, "place": "あ" * 80}) is None, "上限ちょうど（200 個・100 個・80 字）は受ける")
    return failed


def check_ports_unit() -> int:
    failed = 0
    f = Fake()
    f.server = type("S", (), {"server_address": ("127.0.0.1", 47615)})()
    r = s33pwork.read_ports(f)
    failed += say(r["available"] is True and r["ports"][0]["port"] == 47615, "ports: 口の番号")
    failed += say(r["bearer_count"] > 50 and any(x["path"] == "/s33" and x["auth"] == "bearer" for x in r["routes"]),
                  "ports: 道の一覧に /s33（鍵つき）")
    failed += say(any(x["path"] == "/dash" for x in r["other_auth"]), "ports: 鍵が Bearer でない道（/dash）も分かる")
    failed += say(isinstance(r["funnel"], dict) and "on" in r["funnel"] and "host" not in r["funnel"], "ports: Funnel は on/off だけ（名前は返さない）")
    failed += say(any(x["auth"] == "signature" for x in r["via_funnel_if_on"]), "ports: 外の道（署名で守る道）が分かる")
    return failed


def check_http() -> int:
    failed = 0
    try:
        import lifelog_pc as main
    except Exception as error:  # noqa: BLE001
        print(f"SKIP  lifelog_pc を読み込めないので HTTP の確かめを飛ばす: {type(error).__name__}: {error}", flush=True)
        return failed
    base = mother("http")
    saved = (getattr(main.Handler, "key", None), main.log, main.load_config)
    had_engine = hasattr(main.Handler, "engine")
    server = None
    try:
        main.Handler.key = KEY
        if not had_engine:
            main.Handler.engine = type("FakeEngine", (), {"label": "check", "provider": "check", "engines": []})()
        main.log = lambda message: None
        main.load_config = lambda: {"lifelog_home": str(base)}
        server = main.Server(("127.0.0.1", 0), main.Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        port = server.server_address[1]

        def call(path: str, key: str | None = KEY, body: dict | None = None) -> tuple[int, dict]:
            data = None if body is None else json.dumps(body).encode("utf-8")
            req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data, method="GET" if body is None else "POST")
            if body is not None:
                req.add_header("Content-Type", "application/json")
            if key is not None:
                req.add_header("Authorization", f"Bearer {key}")
            try:
                with urllib.request.urlopen(req, timeout=10) as r:
                    return r.status, json.loads(r.read().decode("utf-8"))
            except urllib.error.HTTPError as error:
                return error.code, json.loads(error.read().decode("utf-8") or "{}")

        for path in ("/s33", "/s33/ports"):
            for key in (None, "wrong"):
                st, r = call(path, key)
                failed += say(st == 401 and "stopped" not in r and "ports" not in r,
                              f"GET {path}: 鍵が{'無い' if key is None else '違う'}と 401")
        st, r = call("/s33")
        failed += say(st == 200 and r == SAMPLE, "GET /s33: 鍵が合えば返す")
        st, r = call("/hello")
        failed += say(st == 200 and "s33" in (r.get("features") or []), "features に s33")
        st, r = call("/s33/ports")
        text = json.dumps(r, ensure_ascii=False)
        failed += say(st == 200 and r.get("available") is True and KEY not in text and "Bearer" not in text
                      and any(x["path"] == "/s33/ports" for x in r["routes"]), "GET /s33/ports: 返る・鍵の値は入らない")
        # 止める
        cfg = base / "state" / "s27_work_config.json"
        cfg.write_text(json.dumps({"s33p": {"s33": False}}), encoding="utf-8")
        st, r = call("/s33")
        st2, h = call("/hello")
        failed += say(r.get("available") is False and "s33" not in (h.get("features") or []), "止める切り替えで /s33 も features も止まる")
        cfg.unlink()
        # POST /feedback → 母艦の inbox
        inbox = base / "inbox" / "app_feedback.jsonl"
        for row in (RAMEN, SEEN, DEVICE):
            st, r = call("/feedback", body=row)
            failed += say(st == 200 and r.get("ok") is True, f"POST /feedback {row['kind']}: 受ける")
        lines = [json.loads(x) for x in inbox.read_text(encoding="utf-8").splitlines()] if inbox.is_file() else []
        failed += say([x.get("kind") for x in lines] == ["ramen_mark", "feature_seen", "device_ok"], "母艦の inbox/app_feedback.jsonl に 1 行ずつ")
        if len(lines) == 3:
            failed += say(lines[0]["at"] == RAMEN["at"] and "received_at" in lines[0], "ramen_mark の at は本人の時刻のまま")
            failed += say(lines[1]["counts"] == SEEN["counts"] and lines[2]["screens"] == DEVICE["screens"] and lines[2]["crash"] is False,
                          "feature_seen・device_ok の中身がそのまま入る")
        for row in ({**RAMEN, "at": "きのう"}, {**SEEN, "counts": {"Work": -1}}, {**DEVICE, "crash": "x"}):
            st, r = call("/feedback", body=row)
            failed += say(st == 400, f"POST /feedback {row['kind']}: おかしな形は 400")
        st, r = call("/feedback", key=None, body=RAMEN)
        failed += say(st == 401, "POST /feedback: 鍵が無いと 401")
        failed += say(len(inbox.read_text(encoding="utf-8").splitlines()) == 3, "断った分は母艦に入らない")
    finally:
        if server is not None:
            server.shutdown()
            server.server_close()
        main.Handler.key, main.log, main.load_config = saved
        if not had_engine and hasattr(main.Handler, "engine"):
            del main.Handler.engine
    return failed


def check_hub() -> int:
    failed = 0
    root = Path(__file__).resolve().parent
    hub = (root / "lifelog_pc.py").read_text(encoding="utf-8")
    failed += say("import s33pwork" in hub and "s33pwork.http_get(" in hub and "s33pwork.features(" in hub, "lifelog_pc.py: s33 につないである")
    failed += say("s33pwork" in (root / "appfeeds.py").read_text(encoding="utf-8"), "appfeeds.py: 3 種の kind をつないである")
    return failed


CHECKS = [check_get, check_feedback, check_ports_unit, check_http, check_hub]


def run_all() -> int:
    failed = 0
    for check in CHECKS:
        try:
            failed += check()
        except Exception as error:  # noqa: BLE001
            import traceback

            traceback.print_exc()
            failed += say(False, f"{check.__name__} が途中で落ちました: {error!r}")
    return failed


def main() -> int:
    failed = run_all()
    print("ぜんぶ OK" if not failed else f"NG の数: {failed}", flush=True)
    return failed


if __name__ == "__main__":
    sys.exit(main())
