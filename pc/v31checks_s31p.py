"""2026-11-27（s31。担当 p）: 家の PC の s31 の分を確かめる（K31-2 の GET /links・features "links"）。

    python pc/v31checks_s31p.py          （v30checks_s30p.py の最後にも呼ばれる。CI の手順を増やさずに動かすため）

本物の HOME・母艦・iPhone は使わない（一時フォルダに作り物の母艦を作る）。見本の名前・文はすべて作りもの。
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import threading
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

if not any(mark in os.environ.get("LOCALAPPDATA", "") for mark in ("v25s", "v26s", "v27s", "v30s", "v31s")):
    os.environ["LOCALAPPDATA"] = str(Path(tempfile.mkdtemp(prefix="v31s-local-")))

import s31plinks  # noqa: E402
from v6checks import say  # noqa: E402

TMP = Path(tempfile.mkdtemp(prefix="v31s-"))
SECRET = "見本のひみつの文（作りもの）"


class Fake:
    def __init__(self) -> None:
        self.sent: list = []

    def send_json(self, status: int, body) -> None:
        self.sent = [status, body]


def write(path: Path, body) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(body, ensure_ascii=False) if not isinstance(body, str) else body, encoding="utf-8")


def link(ident: str, day: str, who: list, speakers: list, **more) -> dict:
    row = {"id": ident, "day": day,
           "text": {"src": "line", "ref": f"{day}#部屋#10:00#1", "kind": "message", "who": who, "at": "10:00", "room": "見本の部屋", "quote": SECRET},
           "voice": {"conv": "c-" + ident, "start": f"{day}T10:05:00+09:00", "end": f"{day}T10:06:00+09:00", "speakers": speakers,
                     "lines": [{"t": f"{day}T10:05:00+09:00", "who": speakers[0] if speakers else "", "say": "見本の声"}]},
           "score": 0.6, "by": "rules", "why": "見本", "work": False, "item_ids": []}
    row.update(more)
    return row


SAMPLE = {"version": 1, "generated_at": "2026-11-27T12:00:00+09:00", "days": ["2026-11-26", "2026-11-27"],
          "links": [link("ln-1", "2026-11-27", ["見本アキ"], ["見本アキ", "自分"]),
                    link("ln-2", "2026-11-27", ["見本ベン"], ["人物3"]),
                    link("ln-3", "2026-11-26", ["見本アキ"], ["人物4"]),
                    link("ln-4", "2026-11-26", [], ["見本ベン"], work=True)],
          "people": [{"name": "見本アキ", "person_id": "p-aki", "days": ["2026-11-26", "2026-11-27"], "text_n": 2, "voice_n": 2,
                      "summary": "見本の要約。", "link_ids": ["ln-1", "ln-3"]},
                     {"name": "見本ベン", "person_id": None, "days": ["2026-11-26", "2026-11-27"], "text_n": 1, "voice_n": 2,
                      "summary": "見本の要約。", "link_ids": ["ln-2"]}]}


def mother(name: str, body=SAMPLE) -> Path:
    base = TMP / name
    base.mkdir(parents=True)
    if body is not None:
        write(base / s31plinks.LINKS, body)
    return base


def get(base, query: str) -> tuple:
    f = Fake()
    s31plinks.http_get(f, "/links", query, base)
    return f.sent


def ids(reply) -> list:
    return sorted(x["id"] for x in reply["links"])


def q(text: str) -> str:
    return urllib.parse.quote(text)


def check_filter() -> int:
    failed = 0
    base = mother("filter")
    st, r = get(base, "day=2026-11-27")
    failed += say(st == 200 and r["available"] is True and ids(r) == ["ln-1", "ln-2"] and r["version"] == 1, f"day: その日の links だけ {ids(r)}")
    failed += say(sorted(x["name"] for x in r["people"]) == ["見本アキ", "見本ベン"], "day: その日に出る人")
    st, r = get(base, "day=2026-11-25")
    failed += say(st == 200 and r["available"] is True and r["links"] == [] and r["people"] == [], "day: 無い日は空（available true）")
    st, r = get(base, "person=" + q("見本アキ"))
    failed += say(ids(r) == ["ln-1", "ln-3"] and [x["name"] for x in r["people"]] == ["見本アキ"], f"person: 名前でその人だけ {ids(r)}")
    st, r = get(base, "person=p-aki")
    failed += say(ids(r) == ["ln-1", "ln-3"] and len(r["people"]) == 1, "person: id でも引ける")
    st, r = get(base, "person=" + q("見本ベン"))
    failed += say(ids(r) == ["ln-2", "ln-4"] and len(r["people"]) == 1, f"person: link_ids に無くても話し手にあれば {ids(r)}")
    st, r = get(base, "person=" + q("見本アキ") + "&day=2026-11-26")
    failed += say(ids(r) == ["ln-3"] and len(r["people"]) == 1, "day と person の両方で絞る")
    st, r = get(base, "person=" + q("知らない人"))
    failed += say(st == 200 and r["links"] == [] and r["people"] == [] and r["available"] is True, "person: 知らない人は空")
    for query, label in (("", "day も person も無い"), ("day=2026-02-30", "day が無い日"), ("day=x", "day の形が違う"),
                         ("person=", "person が空"), ("person=" + "a" * 101, "person が長すぎ")):
        st, r = get(base, query)
        failed += say(st == 400 and "error" in r, f"形: {label}は 400")
    return failed


def check_missing() -> int:
    failed = 0
    day = "day=2026-11-27"
    st, r = get(mother("none", None), day)
    failed += say(st == 200 and r["available"] is False and "reason" in r and "links" not in r, "無い: available false")
    big = mother("big")
    write(big / s31plinks.LINKS, {"links": [], "pad": "a" * 2000})
    original = s31plinks.LINKS_READ_MAX
    s31plinks.LINKS_READ_MAX = 1000
    try:
        st, r = get(big, day)
    finally:
        s31plinks.LINKS_READ_MAX = original
    failed += say(r["available"] is False and "大きすぎ" in r["reason"], "大きすぎ: available false")
    st, r = get(mother("broken", "{壊れた"), day)
    failed += say(r["available"] is False and "形が違" in r["reason"], "壊れ: available false")
    st, r = get(mother("array", "[1,2]"), day)
    failed += say(r["available"] is False, "形が配列: available false")
    st, r = get(mother("shape", {"links": "x", "people": []}), day)
    failed += say(r["available"] is False, "links が並びでない: available false")
    st, r = get(TMP / "nowhere", day)
    failed += say(r["available"] is False and "母艦" in r["reason"], "母艦が無い: available false")
    st, r = get(None, day)
    failed += say(r["available"] is False, "母艦が None: available false")
    base = mother("cache")
    get(base, day)
    calls: list = []
    original_read = Path.read_bytes
    Path.read_bytes = lambda self: (calls.append(1), original_read(self))[1]  # type: ignore[assignment]
    try:
        get(base, day)
        get(base, "person=p-aki")
        same = not calls
        write(base / s31plinks.LINKS, {**SAMPLE, "links": SAMPLE["links"][:1], "pad": "x" * 10})
        st, r = get(base, day)
    finally:
        Path.read_bytes = original_read  # type: ignore[assignment]
    failed += say(same, "覚え: 変わっていなければ読み直さない")
    failed += say(ids(r) == ["ln-1"] and bool(calls), "覚え: 変わったら読み直す")
    return failed


def check_switch() -> int:
    failed = 0
    base = mother("switch")
    failed += say(s31plinks.features(base) == ["links"], "features: ファイルがあれば links")
    write(base / s31plinks.s27pwork.CONFIG, {"s31p": {"links": False}})
    failed += say(s31plinks.features(base) == [], "止める切り替え: features に出さない")
    st, r = get(base, "day=2026-11-27")
    failed += say(st == 200 and r["available"] is False and "止め" in r["reason"], "止める切り替え: available false")
    write(base / s31plinks.s27pwork.CONFIG, {"s30p": {"push": False}, "s27p": {"work": False}})
    failed += say(s31plinks.features(base) == ["links"], "ほかの切り替えには引きずられない")
    failed += say(s31plinks.features(mother("nofile", None)) == [] and s31plinks.features(None) == []
                  and s31plinks.features(TMP / "nowhere") == [], "ファイルや母艦が無ければ features に出さない")
    return failed


def check_log() -> int:
    """口は記録に何も出さない（log を持たない）。ソースに print・log が無いことを確かめる"""
    text = (Path(__file__).resolve().parent / "s31plinks.py").read_text(encoding="utf-8")
    return say("print(" not in text and "log(" not in text and "logging" not in text, "中身を記録に出さない（出す道そのものが無い）")


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
        main.Handler.key = "check-key"
        if not had_engine:
            main.Handler.engine = type("FakeEngine", (), {"label": "check", "provider": "check", "engines": []})()
        main.log = lambda message: None
        main.load_config = lambda: {"lifelog_home": str(base)}
        server = main.Server(("127.0.0.1", 0), main.Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        port = server.server_address[1]

        def call(path: str, key: str | None = "check-key") -> tuple[int, dict]:
            req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", method="GET")
            if key is not None:
                req.add_header("Authorization", f"Bearer {key}")
            try:
                with urllib.request.urlopen(req, timeout=10) as r:
                    return r.status, json.loads(r.read().decode("utf-8"))
            except urllib.error.HTTPError as error:
                return error.code, json.loads(error.read().decode("utf-8") or "{}")

        for key in (None, "wrong"):
            label = "無い" if key is None else "違う"
            st, r = call("/links?day=2026-11-27", key)
            failed += say(st == 401 and "links" not in r, f"GET /links: 鍵が{label}と 401")
        st, r = call("/links?day=2026-11-27")
        failed += say(st == 200 and ids(r) == ["ln-1", "ln-2"], "GET /links?day: 鍵が合えば返す")
        st, r = call("/links?person=" + q("見本アキ"))
        failed += say(st == 200 and ids(r) == ["ln-1", "ln-3"], "GET /links?person: 鍵が合えば返す")
        st, r = call("/links")
        failed += say(st == 400, "GET /links: 条件が無ければ 400")
        st, r = call("/hello")
        failed += say(st == 200 and "links" in (r.get("features") or []), "features に links")
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
    text = (Path(__file__).resolve().parent / "lifelog_pc.py").read_text(encoding="utf-8")
    failed += say("import s31plinks" in text and "s31plinks.features(mothership.home(load_config()))" in text
                  and "path in s31plinks.GETS" in text, "lifelog_pc.py: features・GET につないである")
    failed += say("self.authorized()" in text[text.index("path in s31plinks.GETS"):][:200], "lifelog_pc.py: GET /links はオーナーの鍵の後ろ")
    import mothership
    import s27pwork
    import s30pwork

    failed += say(not set(s31plinks.GETS) & (set(mothership.GETS) | set(s27pwork.GETS) | set(s30pwork.GETS)),
                  "ほかの口と道の名前がぶつからない")
    return failed


CHECKS = [check_filter, check_missing, check_switch, check_log, check_http, check_hub]


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
