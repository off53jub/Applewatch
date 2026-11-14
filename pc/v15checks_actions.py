"""強化案 58・60・62（2026-11-15。中身は drafts.py・relay/relay_watch.py）を確かめる。

    python pc/v15checks_actions.py

本物の鍵・ネット・母艦は使わない（一時のフォルダ）。本物の HOME に書かない（isolate_home）。確かめること:
- GET /replies: 形を確かめ、おかしな行（id・トーク・下書き・時刻の無いもの）を落とす・数の上限・無ければ available false
- GET /time-ledger: 種類（key の形・同じ key）と週（形・時間の範囲）を確かめ、新しい週から・無ければ available false
- /hello の features に replies・timeledger。合言葉が違えば 401。記録（log.txt）に下書きの文・名前を書かない
- relay/relay_watch.py: 作り物の家の PC で、401 でも生きている・一度もつながらないうちは鳴らさない・6 時間で 1 通・
  12 時間は繰り返さない・戻ったら 1 通（selftest）。鍵と宛先は環境変数だけ（ファイルに書かない）
- アプリ: カレンダーに書くだけの許可の文がある・下書きの画面に「送る」仕組みが無い（写す・開くだけ）
"""

from __future__ import annotations

import importlib.util
import json
import re
import sys
import tempfile
import threading
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import drafts  # noqa: E402
import ops  # noqa: E402
from v6checks import KEY, Client, say  # noqa: E402
from v11checks import reset_files  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
SECRET_DRAFT = "見本の秘密の下書き"
SECRET_CHAT = "見本の秘密のトーク"


def write(base: Path, rel: Path, value) -> None:
    (base / rel).parent.mkdir(parents=True, exist_ok=True)
    text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
    (base / rel).write_text(text, encoding="utf-8-sig")


def reply(i: int, **over) -> dict:
    row = {"id": f"r-{i}", "chat": f"見本 {i}", "who": "見本", "last_at": "2026-11-15T10:00:00+09:00",
           "waiting_hours": 5, "ask": "何時にする？", "draft": "〇〇時でどう？", "note": ""}
    row.update(over)
    return row


def check_replies() -> int:
    failed = 0
    with tempfile.TemporaryDirectory() as folder:
        base = Path(folder)
        got = drafts.read_replies(base)
        failed += say(got.get("available") is False and "reason" in got, "GET /replies: 写しが無ければ available false")
        write(base, drafts.REPLIES, "{壊れた")
        failed += say(drafts.read_replies(base).get("available") is False, "GET /replies: 読めなければ available false")
        items = [reply(1), reply(2, id="壊れた id"), reply(3, draft=""), reply(4, last_at="きのう"), reply(1),
                 reply(5, chat="あ" * 80, draft="い" * 500), "行ではない"]
        items += [reply(10 + k) for k in range(20)]
        mails = [{"id": "m-1", "to": "見本 さま", "subject": "件名", "body": "本文\n二行目", "why": "約束", "day": "2026-11-15"},
                 {"id": "m-2", "subject": "", "body": "本文"}, {"id": "m-3", "subject": "件名", "body": "x", "day": "きのう"}]
        write(base, drafts.REPLIES, {"version": 1, "generated_at": "2026-11-15T12:00:00+09:00", "items": items,
                                     "mails": mails})
        got = drafts.read_replies(base)
        ids = [x["id"] for x in got.get("items", [])]
        failed += say(got.get("available") is True and ids[:2] == ["r-1", "r-5"] and len(ids) == drafts.REPLY_ITEMS,
                      f"GET /replies: おかしな行・同じ id を落とし、{drafts.REPLY_ITEMS} まで（{ids[:3]}…{len(ids)}）")
        five = next((x for x in got.get("items", []) if x["id"] == "r-5"), {})
        failed += say(len(five.get("chat", "")) == 40 and len(five.get("draft", "")) == 300,
                      "GET /replies: トークは 40 字・下書きは 300 字まで")
        mids = [m["id"] for m in got.get("mails", [])]
        failed += say(mids == ["m-1", "m-3"] and got["mails"][0]["body"] == "本文\n二行目" and got["mails"][1]["day"] is None,
                      f"GET /replies: メールは件名と本文のあるものだけ・改行を残す・日の形を確かめる（{mids}）")
    return failed


def check_ledger() -> int:
    failed = 0
    with tempfile.TemporaryDirectory() as folder:
        base = Path(folder)
        failed += say(drafts.read_time_ledger(base).get("available") is False, "GET /time-ledger: 写しが無ければ available false")
        cats = [{"key": "meeting", "label": "仕事の会議", "overlay": False}, {"key": "pc", "label": "PC", "overlay": True},
                {"key": "BAD KEY", "label": "x"}, {"key": "meeting", "label": "二つ目"}, {"key": "home", "label": ""}]
        weeks = [{"week": "2026-W45", "from": "2026-11-02", "to": "2026-11-08", "days": 7, "covered": 0.8,
                  "hours": {"meeting": 20.04, "pc": -3, "home": 5}},
                 {"week": "2026-W46", "from": "2026-11-09", "to": "2026-11-15", "days": 9, "covered": 2,
                  "hours": {"meeting": 999}},
                 {"week": "壊れた", "hours": {}}, {"week": "2026-W44", "hours": "x"}]
        write(base, drafts.TIME_LEDGER, {"version": 1, "generated_at": "2026-11-15T12:00:00+09:00", "method": "数え方",
                                         "categories": cats, "weeks": weeks})
        got = drafts.read_time_ledger(base)
        keys = [c["key"] for c in got.get("categories", [])]
        failed += say(keys == ["meeting", "pc"] and got["categories"][1]["overlay"] is True,
                      f"GET /time-ledger: 種類は key の形・同じ key・名前を確かめる（{keys}）")
        ws = got.get("weeks", [])
        failed += say([w["week"] for w in ws] == ["2026-W46", "2026-W45"], "GET /time-ledger: 形の違う週を落とし、新しい週から")
        w45 = ws[1] if len(ws) > 1 else {}
        failed += say(w45.get("hours") == {"meeting": 20.0, "pc": 0.0}, f"GET /time-ledger: 時間は 0〜168・種類の key だけ（{w45.get('hours')}）")
        w46 = ws[0] if ws else {}
        failed += say(w46.get("days") == 0 and w46.get("covered") == 0.0 and w46.get("hours", {}).get("meeting") == 0.0,
                      "GET /time-ledger: 日数・割合・時間が範囲の外なら 0")
    return failed


def check_relay() -> int:
    failed = 0
    path = ROOT / "pc" / "relay" / "relay_watch.py"
    spec = importlib.util.spec_from_file_location("relay_watch", path)
    relay = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(relay)
    failed += say(relay.selftest() == 0, "relay: 作り物の家の PC で見張りの決まりを確かめた（selftest）")
    text = path.read_text(encoding="utf-8")
    failed += say(not re.search(r"ts\.net|tail[0-9a-f]{6}|Bearer [A-Za-z0-9]{20,}", text),
                  "relay: tailnet の名前・鍵をファイルに書いていない")
    readme = (ROOT / "pc" / "relay" / "README.md").read_text(encoding="utf-8")
    failed += say("まだどこにも置いていません" in readme and "Raspberry Pi" in readme and "VM" in readme,
                  "relay: README に置き場所の候補と、まだ置いていないこと")
    return failed


def check_app_text() -> int:
    failed = 0
    yml = (ROOT / "project.yml").read_text(encoding="utf-8")
    failed += say("NSCalendarsWriteOnlyAccessUsageDescription" in yml and "NSRemindersFullAccessUsageDescription" in yml,
                  "アプリ: カレンダーに書くだけの許可とリマインダーの許可の文がある")
    swift = (ROOT / "LifeLog" / "DraftActions.swift").read_text(encoding="utf-8")
    failed += say("requestWriteOnlyAccessToEvents" in swift and "UIPasteboard.general.string" in swift
                  and "line://" in swift and "MFMailCompose" not in swift and "sendMessage" not in swift,
                  "アプリ: 予定は書くだけの許可を初めて押したときに聞く・下書きは写す・開くだけ（送る仕組みが無い）")
    failed += say("DraftConfirmView" in swift and "「入れる」を押すまで、何も入りません" in swift,
                  "アプリ: 予定・リマインダーは確かめの画面で「入れる」を押すまで入れない")
    return failed


def check_http(main) -> int:
    failed = 0
    reset_files()
    logged: list[str] = []
    saved = (getattr(main.Handler, "engine", None), getattr(main.Handler, "key", None), main.log)
    old_config = main.load_config()
    with tempfile.TemporaryDirectory() as folder:
        base = Path(folder)
        server = None
        try:
            main.log = logged.append
            main.Handler.key = KEY
            main.Handler.engine = main.Ensemble(ops.fake_engines())
            config = dict(old_config)
            config["lifelog_home"] = folder
            main.save_config(config)
            server = main.Server(("127.0.0.1", 0), main.Handler)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            client = Client(server.server_address[1])
            hello = client.call("GET", "/hello")
            names = set(hello[1].get("features", [])) if hello[0] == 200 else set()
            failed += say({"replies", "timeledger"} <= names, "/hello の features に replies・timeledger")
            status, body, _ = client.call("GET", "/replies")
            failed += say(status == 200 and body.get("available") is False, f"GET /replies: 写しが無ければ available false（{status}）")
            write(base, drafts.REPLIES, {"version": 1, "generated_at": "2026-11-15T12:00:00+09:00",
                                         "items": [reply(1, chat=SECRET_CHAT, draft=SECRET_DRAFT)], "mails": []})
            write(base, drafts.TIME_LEDGER, {"version": 1, "generated_at": "2026-11-15T12:00:00+09:00", "method": "m",
                                             "categories": [{"key": "home", "label": "家", "overlay": False}],
                                             "weeks": [{"week": "2026-W46", "days": 7, "covered": 0.5, "hours": {"home": 30}}]})
            status, body, _ = client.call("GET", "/replies")
            failed += say(status == 200 and body.get("items", [{}])[0].get("draft") == SECRET_DRAFT,
                          f"GET /replies: 母艦の写しを返す（{status}）")
            status, body, _ = client.call("GET", "/time-ledger")
            failed += say(status == 200 and body.get("weeks", [{}])[0].get("hours") == {"home": 30.0},
                          f"GET /time-ledger: 母艦の写しを返す（{status}）")
            unauth = [client.call("GET", p, key="wrong")[0] for p in ("/replies", "/time-ledger")]
            failed += say(unauth == [401, 401], f"GET の2つ: 合言葉が違えば 401（{unauth}）")
            text = "\n".join(logged)
            failed += say(SECRET_DRAFT not in text and SECRET_CHAT not in text, "記録に下書きの文・トークの名前を書かない")
        finally:
            if server is not None:
                server.shutdown()
                server.server_close()
            main.save_config(old_config)
            main.Handler.engine, main.Handler.key, main.log = saved
            reset_files()
    return failed


def run(main) -> int:
    main.isolate_home()
    failed = 0
    try:
        failed += check_replies()
        failed += check_ledger()
        failed += check_relay()
        failed += check_app_text()
        failed += check_http(main)
    finally:
        reset_files()
    print(("NG の数: " + str(failed)) if failed else "返事の下書き・時間の家計簿・控えの見張り（2026-11-15）: 全部 OK", flush=True)
    return failed


if __name__ == "__main__":
    import lifelog_pc

    sys.exit(1 if run(lifelog_pc) else 0)
