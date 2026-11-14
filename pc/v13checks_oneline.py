"""強化案 25・28・30・32・34（2026-11-14。中身は oneline.py・claude.py の画像・appfeeds.py の profile）を確かめる。

    python pc/v13checks_oneline.py

本物の鍵・ネット・母艦は使わない（作り物の Claude・一時のフォルダ）。本物の HOME に書かない（isolate_home）。確かめること:
- GET /timeline?day=: 直近 14 日だけ・無い／形が違う／日付が違うときは available false・lane と時刻と長さを確かめ、おかしな行は落とす・
  時刻の順・day の形が違えば 400
- POST /pay/paypay-shot: JPEG だけ・4MB まで（413）・Claude に画像（base64）と決まった頭の文（例文なし）を light で渡す・
  PayPay の画面でなければ 422・未来の日や金額のおかしな行を落とす・画像をどこにも書かない・上限なら 402・features は Claude が使えるときだけ
- POST /pay/paypay-rows: 決めた形だけ受け、母艦の inbox/paypay_shots.jsonl に 1 行ずつ（at 付き・同じ行は 2 回足さない）
- POST /location/stays: おかしな滞在を落とし、母艦の inbox/location_live.jsonl に start で重ねずに置く（新しい方に置き換え）
- GET /reflection: いくつかの形を読み、知らない要素・反映先も通す・読めない値は null
- 提案の kind "profile"（action none・根拠つきだけ）
- 記録（log.txt）に店の名前・金額・場所の名前を書かない
"""

from __future__ import annotations

import base64
import datetime
import json
import sys
import tempfile
import threading
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import appfeeds  # noqa: E402
import claude  # noqa: E402
import mothership  # noqa: E402
import oneline  # noqa: E402
import ops  # noqa: E402
from v6checks import KEY, Client, say  # noqa: E402
from v11checks import FakeClaude, put_config, put_key, reset_files  # noqa: E402

SECRET_SHOP = "見本の秘密の店"
SECRET_PLACE = "見本の秘密の場所"
# 小さな JPEG の見本（頭の印だけ本物。中身は作り物。Claude は作り物なので画像としては読まない）
JPEG = b"\xff\xd8\xff\xe0" + b"\x00\x10JFIF\x00" + bytes(range(256)) * 4 + b"\xff\xd9"


def run(main) -> int:
    main.isolate_home()
    saved_factory = claude.CLIENT_FACTORY
    failed = 0
    try:
        failed += check_timeline()
        failed += check_reflection()
        failed += check_shot()
        failed += check_rows_and_stays()
        failed += check_profile()
        failed += check_http(main)
    finally:
        claude.CLIENT_FACTORY = saved_factory
        reset_files()
    print(("NG の数: " + str(failed)) if failed else "1日の流れ・PayPay の写真・位置・反映の見張り（2026-11-14）: 全部 OK", flush=True)
    return failed


def write(base: Path, rel: Path, value) -> None:
    (base / rel).parent.mkdir(parents=True, exist_ok=True)
    text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
    (base / rel).write_text(text, encoding="utf-8-sig")


TODAY = datetime.date(2026, 11, 14)


def check_timeline() -> int:
    failed = 0
    with tempfile.TemporaryDirectory() as folder:
        base = Path(folder)
        rel = oneline.TIMELINE_DIR / "2026-11-14.json"
        got = oneline.read_timeline(base, "2026-11-14", TODAY)
        failed += say(got.get("available") is False and "まだありません" in got.get("reason", ""),
                      "年表: 無ければ available false")
        out = [oneline.read_timeline(base, d, TODAY).get("reason", "") for d in ("2026-10-31", "2026-11-15", "2026-02-30")]
        failed += say("直近 14 日" in out[0] and "直近 14 日" in out[1] and "YYYY-MM-DD" in out[2],
                      f"年表: 直近 14 日の外・あり得ない日は available false（{out}）")
        write(base, rel, "[1]")
        failed += say("形が違います" in oneline.read_timeline(base, "2026-11-14", TODAY).get("reason", ""),
                      "年表: 形が違えば available false")
        write(base, rel, "{壊れた")
        failed += say("読めませんでした" in oneline.read_timeline(base, "2026-11-14", TODAY).get("reason", ""),
                      "年表: 読めなければ理由つきで available false")
        write(base, rel, {"version": 1, "day": "2026-11-13", "rows": []})
        failed += say("日付が違います" in oneline.read_timeline(base, "2026-11-14", TODAY).get("reason", ""),
                      "年表: 中の day が違えば available false")
        rows = [
            {"time": "12:10", "end": "12:45", "lane": "位置", "text": "見本の店に滞在", "amount": None, "place": "場" * 60},
            {"time": "08:05", "end": None, "lane": "決済", "text": "見本のパン屋" * 20, "amount": 480, "place": None},
            {"time": "09:00", "end": None, "lane": "LINE", "text": "見本 花子 と 3 件"},
            {"time": "25:00", "lane": "予定", "text": "時刻が変"},
            {"time": "10:00", "lane": "知らない", "text": "lane が変"},
            {"time": "10:30", "lane": "PC", "text": ""},
            {"time": "11:00", "end": "あとで", "lane": "PC", "text": "終わりが変"},
            {"time": "11:30", "lane": "決済", "text": "金額が変", "amount": -5},
            {"time": "11:40", "lane": "決済", "text": "金額が文", "amount": "500"},
            "行ではない",
        ]
        write(base, rel, {"version": 1, "day": "2026-11-14", "generated_at": "2026-11-14T07:00:00+09:00", "rows": rows})
        got = oneline.read_timeline(base, "2026-11-14", TODAY)
        listed = got.get("rows") or []
        failed += say(got.get("available") is True and [r["time"] for r in listed] == ["08:05", "09:00", "11:30", "11:40", "12:10"]
                      and len(listed[0]["text"]) == 80 and listed[0]["amount"] == 480 and listed[1]["amount"] is None
                      and listed[1]["place"] is None and len(listed[-1]["place"]) == 40 and listed[-1]["end"] == "12:45"
                      and listed[2]["amount"] is None and listed[3]["amount"] is None
                      and got.get("generated_at") == "2026-11-14T07:00:00+09:00",
                      f"年表: おかしな時刻・lane・空の文・終わりを落とし、80/40 文字・金額は整数だけ・時刻の順（{[r['time'] for r in listed]}）")
        failed += say(set(listed[0]) == {"time", "end", "lane", "text", "amount", "place"},
                      "年表: 行の形は time・end・lane・text・amount・place")
        write(base, rel, {"day": "2026-11-14", "rows": [{"time": "07:00", "lane": "天気", "text": "晴れ"}] * 700})
        failed += say(len(oneline.read_timeline(base, "2026-11-14", TODAY)["rows"]) == oneline.TIMELINE_ROWS,
                      f"年表: {oneline.TIMELINE_ROWS} 行まで")
    return failed


def check_reflection() -> int:
    failed = 0
    with tempfile.TemporaryDirectory() as folder:
        base = Path(folder)
        failed += say(oneline.read_reflection(base).get("available") is False, "反映の見張り: 無ければ available false")
        write(base, oneline.REFLECTION, {"x": 1})
        failed += say(oneline.read_reflection(base).get("available") is False, "反映の見張り: 形が違えば available false")
        # 形 1: 要素の並び（last の中に反映先）
        shape1 = {"version": 1, "generated_at": "2026-11-14T08:00:00+09:00",
                  "destinations": ["取り込み", "年表", "朝のまとめ", "アプリへの配り", "ノート"],
                  "elements": [{"element": "LINE", "last": {"取り込み": "2026-11-14", "年表": None, "朝のまとめ": "2026-11-13",
                                                            "アプリへの配り": "きのう", "ノート": "2026-11-10T21:00:00+09:00"}},
                               {"element": "新しい要素", "last": {"取り込み": "2026-11-12", "見張り先X": "2026-11-11"}},
                               {"element": "LINE", "last": {"取り込み": "2026-11-01"}},
                               {"name": "決済", "取り込み": {"day": "2026-11-14"}, "年表": "2026-02-30"},
                               "文", {"last": {}}]}
        write(base, oneline.REFLECTION, shape1)
        got = oneline.read_reflection(base)
        names = [e["element"] for e in got.get("elements") or []]
        dests = got.get("destinations") or []
        line = (got.get("elements") or [{}])[0].get("cells")
        pay = next((e["cells"] for e in got.get("elements") or [] if e["element"] == "決済"), None)
        failed += say(got.get("available") is True and names == ["LINE", "新しい要素", "決済"]
                      and dests[:5] == list(oneline.REFLECTION_DESTINATIONS) and "見張り先X" in dests
                      and line[:5] == ["2026-11-14", None, "2026-11-13", None, "2026-11-10"]
                      and pay is not None and pay[0] == "2026-11-14" and pay[1] is None,
                      f"反映の見張り（並び）: 知らない要素・反映先も通し、読めない値は null（{names} {dests} {line}）")
        # 形 2: 要素 → 反映先 → 日 の辞書
        write(base, oneline.REFLECTION, {"elements": {"会話": {"取り込み": "2026-11-14", "年表": "2026-11-14"},
                                                      "天気": {"取り込み": None}}})
        got = oneline.read_reflection(base)
        failed += say(got.get("available") is True and [e["element"] for e in got["elements"]] == ["会話", "天気"]
                      and got["elements"][0]["cells"][:2] == ["2026-11-14", "2026-11-14"]
                      and got["elements"][1]["cells"] == [None] * len(got["destinations"])
                      and len(got.get("today", "")) == 10,
                      "反映の見張り（辞書）: 要素 → 反映先 → 日 も読む・今日の日を添える")
        write(base, oneline.REFLECTION, {"elements": [{"element": f"要素{i}", "last": {"取り込み": "2026-11-14"}} for i in range(60)]})
        failed += say(len(oneline.read_reflection(base)["elements"]) == oneline.REFLECTION_ELEMENTS,
                      f"反映の見張り: 要素は {oneline.REFLECTION_ELEMENTS} まで")
    return failed


def check_shot() -> int:
    failed = 0
    reset_files()
    put_key()
    fake = FakeClaude()
    claude.CLIENT_FACTORY = fake.factory
    answer = {"is_paypay": True, "rows": [
        {"date": "2026-11-14", "clock": "12:34", "shop": SECRET_SHOP, "amount": 680, "method": "PayPay残高"},
        {"date": "2026-11-13", "clock": "", "shop": "店" * 60, "amount": 1200, "method": "クレジット" * 10},
        {"date": "2026-11-20", "clock": "10:00", "shop": "未来", "amount": 100, "method": ""},
        {"date": "2024-01-01", "clock": "10:00", "shop": "古い", "amount": 100, "method": ""},
        {"date": "2026-11-12", "clock": "25:99", "shop": "時刻が変", "amount": 300, "method": ""},
        {"date": "2026-11-12", "clock": "09:00", "shop": "金額が変", "amount": 0, "method": ""},
    ]}
    fake.text = json.dumps(answer, ensure_ascii=False)
    rows = oneline.read_shot(JPEG, today=TODAY)
    offset = oneline._offset()
    failed += say([r["shop"][:4] for r in rows] == [SECRET_SHOP[:4], "店店店店", "時刻が変"]
                  and rows[0]["time"] == "2026-11-14T12:34:00" + offset and rows[1]["time"] is None
                  and rows[2]["time"] is None and len(rows[1]["shop"]) == 40 and len(rows[1]["method"]) == 20
                  and set(rows[0]) == {"time", "day", "shop", "amount", "method"},
                  f"PayPay の写真: 未来・古い・金額のおかしな行を落とし、時刻が無ければ null・40/20 文字（{len(rows)} 行）")
    kwargs = fake.calls[-1][1] if fake.calls else {}
    content = (kwargs.get("messages") or [{}])[0].get("content")
    image = content[0] if isinstance(content, list) and content else {}
    failed += say(kwargs.get("model") == claude.TIERS["light"] and isinstance(content, list) and len(content) == 2
                  and image.get("type") == "image" and image["source"]["media_type"] == "image/jpeg"
                  and base64.b64decode(image["source"]["data"]) == JPEG and content[1]["type"] == "text"
                  and kwargs.get("output_config", {}).get("format", {}).get("type") == "json_schema",
                  "PayPay の写真: light のモデルに画像（base64）と文を渡し、形を決めた答え（json_schema）")
    system = kwargs.get("system", [{}])[0].get("text", "")
    failed += say(system == oneline.SHOT_SYSTEM and "例" not in system and "たとえば" not in system
                  and SECRET_SHOP not in system and "円の整数" in system,
                  "PayPay の写真: 頭の文は決まったもので、例文（例・たとえば・見本の店）を入れていない")
    ledger = claude.ledger_path().read_text(encoding="utf-8")
    failed += say('"purpose": "paypay-shot"' in ledger and SECRET_SHOP not in ledger and "base64" not in ledger,
                  "PayPay の写真: 帳簿に1行（店の名前・画像は書かない）")
    fake.text = json.dumps({"is_paypay": False, "rows": [{"date": "2026-11-14", "clock": "", "shop": "x", "amount": 5,
                                                          "method": ""}]})
    try:
        oneline.read_shot(JPEG, today=TODAY)
        failed += say(False, "PayPay の写真: PayPay の画面でなければ断る")
    except oneline.ShotRefused as error:
        failed += say("PayPay" in str(error), "PayPay の写真: PayPay の画面でなければ断る（やさしい文）")
    bad = 0
    for data in (b"\x89PNG\r\n" + b"x" * 100, b"", JPEG[:10], b"\xff\xd8\xff" + b"x" * (oneline.SHOT_LIMIT + 1)):
        try:
            oneline.check_jpeg(data)
        except ValueError:
            bad += 1
    failed += say(bad == 4, f"PayPay の写真: JPEG でない・短い・4MB を越えるものは受けない（{bad}/4）")
    bad_images = 0
    for images in ([("image/bmp", b"x")], [("image/jpeg", b"")], [("image/jpeg", b"x" * (claude.IMAGE_MAX + 1))],
                   [("image/jpeg", b"x")] * 5, ["x"]):
        try:
            claude.image_blocks(images)
        except ValueError:
            bad_images += 1
    failed += say(bad_images == 5, f"claude.py の画像: 種類・大きさ・枚数がおかしければ頼まない（{bad_images}/5）")
    calls = len(fake.calls)
    fake.text = "答えです"
    claude.call(None, "文だけ", purpose="check")
    failed += say(len(fake.calls) == calls + 1 and fake.calls[-1][1]["messages"][0]["content"] == "文だけ",
                  "claude.py: 画像が無いときは前と同じ形（文だけ）で頼む")
    reset_files()
    return failed


def check_rows_and_stays() -> int:
    failed = 0
    with tempfile.TemporaryDirectory() as folder:
        base = Path(folder)
        good = {"time": "2026-11-14T12:34:00+09:00", "day": "2026-11-14", "shop": " 見本の店 ", "amount": 680, "method": "残高"}
        rows = oneline.parse_rows(json.dumps({"rows": [good, dict(good, time=None, amount=100)]}, ensure_ascii=False).encode())
        failed += say(rows[0]["shop"] == "見本の店" and rows[1]["time"] is None, "PayPay の行: 決めた形を受ける（前後の空白を除く）")
        bad = [b"x", {"rows": []}, {"rows": "x"}, {"rows": [dict(good, amount=0)]}, {"rows": [dict(good, day="11/14")]},
               {"rows": [dict(good, time="2026-11-13T12:00:00+09:00")]}, {"rows": [dict(good, shop="店" * 41)]},
               {"rows": [dict(good, method=3)]}, {"rows": [good] * 201}, {"rows": ["x"]}]
        refused = 0
        for body in bad:
            data = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode()
            try:
                oneline.parse_rows(data)
            except ValueError:
                refused += 1
        failed += say(refused == len(bad), f"PayPay の行: おかしな中身は受けない（{refused}/{len(bad)}）")
        first = oneline.append_rows(base, rows)
        again = oneline.append_rows(base, rows)
        lines = [json.loads(x) for x in (base / oneline.PAYPAY_SHOTS).read_text(encoding="utf-8").splitlines()]
        failed += say(first == 2 and again == 0 and len(lines) == 2 and set(lines[0]) == {"time", "day", "shop", "amount", "method", "at"},
                      "PayPay の行: inbox/paypay_shots.jsonl に 1 行ずつ（at 付き・同じ行は 2 回足さない）")

        stay = {"start": "2026-11-14T12:10:00+09:00", "end": None, "lat": 35.6, "lon": 139.7, "name": SECRET_PLACE, "kind": "shop"}
        body = {"stays": [stay, dict(stay, start="2026-11-14T09:00:00+09:00", end="2026-11-14T08:00:00+09:00"),
                          dict(stay, start="朝"), dict(stay, lat=91), dict(stay, kind="park"), dict(stay, name=3), "x",
                          dict(stay, start="2026-11-14T08:00:00+09:00", end="2026-11-14T08:40:00+09:00", name=None, kind=None)]}
        stays = oneline.parse_stays(json.dumps(body, ensure_ascii=False).encode())
        failed += say([s["start"][11:16] for s in stays] == ["12:10", "08:00"],
                      f"滞在: 終わりが始まりより前・座標・種類・名前の型のおかしなものを落とす（{len(stays)} 件）")
        refused = 0
        for data in (b"[]", b"{}", json.dumps({"stays": [stay] * 301}).encode()):
            try:
                oneline.parse_stays(data)
            except ValueError:
                refused += 1
        failed += say(refused == 3, f"滞在: 形が違う・多すぎる中身は受けない（{refused}/3）")
        a = oneline.write_stays(base, stays)
        closed = dict(stays[0], end="2026-11-14T12:50:00+09:00")
        b = oneline.write_stays(base, [closed, stays[1]])
        lines = [json.loads(x) for x in (base / oneline.LOCATION_LIVE).read_text(encoding="utf-8").splitlines()]
        failed += say(a == (2, 0) and b == (0, 1) and len(lines) == 2 and lines[0]["end"] == "2026-11-14T12:50:00+09:00"
                      and "at" in lines[0],
                      f"滞在: inbox/location_live.jsonl に start で重ねず、閉じた滞在は新しい方に置き換える（{a} {b}）")
    return failed


def check_profile() -> int:
    failed = 0
    with tempfile.TemporaryDirectory() as folder:
        base = Path(folder)
        item = {"id": "pf-1", "kind": "profile", "title": "台帳に足す候補（見本）", "body": "見本",
                "evidence": [{"text": "見本の根拠", "source": "conversation"}], "action": {"type": "none"},
                "created": "2026-11-14T08:00:00+09:00"}
        write(base, appfeeds.PROPOSALS, {"items": [item, dict(item, id="pf-2", action={"type": "task", "text": "足す"}),
                                                   dict(item, id="pf-3", evidence=[])]})
        got = appfeeds.read_proposals(base)
        failed += say([i["id"] for i in got.get("items") or []] == ["pf-1"] and "profile" in appfeeds.PROPOSAL_KINDS,
                      "提案の kind profile: action none で根拠のあるものだけ通す")
    return failed


def check_http(main) -> int:
    failed = 0
    reset_files()
    put_key()
    fake = FakeClaude()
    claude.CLIENT_FACTORY = fake.factory
    fake.text = json.dumps({"is_paypay": True, "rows": [{"date": datetime.date.today().isoformat(), "clock": "12:00",
                                                         "shop": SECRET_SHOP, "amount": 777, "method": ""}]},
                           ensure_ascii=False)
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

            def post(path: str, body, key=KEY, kind="application/json"):
                data = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode("utf-8")
                return client.call("POST", path, data, {"Content-Type": kind}, key=key)

            hello = client.call("GET", "/hello")
            names = set(hello[1].get("features", [])) if hello[0] == 200 else set()
            failed += say({"timeline", "paypayshot", "paypayrows", "livestays", "reflection"} <= names,
                          "/hello の features に timeline・paypayshot・paypayrows・livestays・reflection")
            today = datetime.date.today().isoformat()
            status, body, _ = client.call("GET", "/timeline?day=" + today)
            failed += say(status == 200 and body.get("available") is False, f"GET /timeline: 無ければ available false（{status}）")
            write(base, oneline.TIMELINE_DIR / f"{today}.json",
                  {"version": 1, "day": today, "rows": [{"time": "08:00", "lane": "決済", "text": "見本", "amount": 100}]})
            status, body, _ = client.call("GET", "/timeline?day=" + today)
            status2, body2, _ = client.call("GET", "/timeline")
            failed += say(status == 200 and body.get("available") is True and body["rows"][0]["amount"] == 100
                          and status2 == 200 and body2.get("day") == today,
                          "GET /timeline?day=: 母艦の年表を確かめて返す（day が無ければ今日）")
            bad = client.call("GET", "/timeline?day=11-14")[0]
            failed += say(bad == 400, f"GET /timeline: day の形が違えば 400（{bad}）")
            write(base, oneline.REFLECTION, {"elements": {"会話": {"取り込み": today}}})
            status, body, _ = client.call("GET", "/reflection")
            failed += say(status == 200 and body.get("available") is True and body["elements"][0]["element"] == "会話",
                          "GET /reflection: 母艦の反映の見張りを返す")
            unauth = [client.call("GET", p, key="wrong")[0] for p in ("/timeline", "/reflection")]
            failed += say(unauth == [401, 401], f"GET の2つ: 合言葉が違えば 401（{unauth}）")

            status, body, _ = post("/pay/paypay-shot", JPEG, kind="image/jpeg")
            failed += say(status == 200 and body.get("rows", [{}])[0].get("amount") == 777,
                          f"POST /pay/paypay-shot: 読めた行を返す（{status}）")
            stored = [p for p in base.rglob("*") if p.is_file() and p.read_bytes().find(JPEG[:64]) >= 0]
            home_files = [p for p in Path(main.HOME).rglob("*") if p.is_file() and p.read_bytes().find(JPEG[:64]) >= 0]
            failed += say(not stored and not home_files, "POST /pay/paypay-shot: 画像は母艦にも HOME にも残さない")
            fake.text = json.dumps({"is_paypay": False, "rows": []})
            status, body, _ = post("/pay/paypay-shot", JPEG, kind="image/jpeg")
            failed += say(status == 422 and "PayPay" in body.get("error", "") and set(body) == {"error"},
                          f"POST /pay/paypay-shot: PayPay の画面でなければ 422（{status}）")
            bad = [post("/pay/paypay-shot", b"not a jpeg" * 10, kind="image/jpeg")[0],
                   post("/pay/paypay-shot", b"\xff\xd8\xff" + b"x" * (oneline.SHOT_LIMIT + 10), kind="image/jpeg")[0],
                   post("/pay/paypay-shot", JPEG, key="wrong", kind="image/jpeg")[0]]
            failed += say(bad == [400, 413, 401], f"POST /pay/paypay-shot: JPEG でない 400・大きすぎ 413・合言葉 401（{bad}）")
            put_config({"monthly_usd": 0})
            capped = post("/pay/paypay-shot", JPEG, kind="image/jpeg")
            hello = client.call("GET", "/hello")
            failed += say(capped[0] == 402 and "paypayshot" not in hello[1].get("features", [])
                          and "paypayrows" in hello[1].get("features", []),
                          f"POST /pay/paypay-shot: 今月の上限なら 402・features から外す（行の送りは残す）（{capped[0]}）")
            put_config({})

            row = {"time": None, "day": today, "shop": SECRET_SHOP, "amount": 777, "method": ""}
            status, body, _ = post("/pay/paypay-rows", {"rows": [row]})
            again = post("/pay/paypay-rows", {"rows": [row]})[1]
            failed += say(status == 200 and body.get("added") == 1 and again.get("added") == 0
                          and (base / oneline.PAYPAY_SHOTS).is_file(),
                          "POST /pay/paypay-rows → 母艦の inbox/paypay_shots.jsonl（同じ行は 2 回足さない）")
            stay = {"start": today + "T12:00:00+09:00", "end": None, "lat": 35.0, "lon": 139.0, "name": SECRET_PLACE,
                    "kind": "shop"}
            status, body, _ = post("/location/stays", {"stays": [stay]})
            failed += say(status == 200 and body.get("added") == 1 and (base / oneline.LOCATION_LIVE).is_file(),
                          "POST /location/stays → 母艦の inbox/location_live.jsonl")
            bad = [post("/pay/paypay-rows", {"rows": []})[0], post("/location/stays", b"[]")[0],
                   post("/pay/paypay-rows", {"rows": [row]}, key="wrong")[0], post("/location/stays", {"stays": []}, key="wrong")[0]]
            failed += say(bad == [400, 400, 401, 401], f"POST の2つ: おかしな中身 400・合言葉 401（{bad}）")
            text = "\n".join(logged)
            failed += say(SECRET_SHOP not in text and SECRET_PLACE not in text and "777" not in text
                          and "PayPay の写真を読みました: 1 行" in text,
                          "記録に店の名前・金額・場所の名前を書かない（件数だけ）")
        finally:
            if server is not None:
                server.shutdown()
                server.server_close()
            main.save_config(old_config)
            main.Handler.engine, main.Handler.key, main.log = saved
            reset_files()
    return failed


if __name__ == "__main__":
    import lifelog_pc

    sys.exit(1 if run(lifelog_pc) else 0)
