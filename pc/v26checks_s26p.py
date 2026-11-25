"""2026-11-25（s26。担当 P）: 家の PC の s26 の分を確かめる（K4〜K8・軽2・結1・結4・結7・結9・聞1〜7・聞11・聞15・集3）。

    python pc/v26checks_s26p.py          （v25checks_s25p.py の最後にも呼ばれる。CI の手順を増やさずに動かすため）

本物の HOME・母艦・iPhone・LINE・Claude・モデルは使わない（一時フォルダに作り物を作る。人の名前は「甲」「乙」「丙」の記号だけ。
文字にするモデル・周りの音のモデル・顔のモデルは、決まった答えを返す作り物）。
"""

from __future__ import annotations

import datetime
import io
import json
import os
import sys
import tempfile
import time
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent))

if "v25s" not in os.environ.get("LOCALAPPDATA", "") and "v26s" not in os.environ.get("LOCALAPPDATA", ""):
    os.environ["LOCALAPPDATA"] = str(Path(tempfile.mkdtemp(prefix="v26s-local-")))

import numpy as np  # noqa: E402

import appfeeds  # noqa: E402
import claude  # noqa: E402
import jobqueue  # noqa: E402
import lifelog_mcp  # noqa: E402
import plaudmatch  # noqa: E402
import s25pline  # noqa: E402
import s26pc  # noqa: E402
import s26pface  # noqa: E402
import s26pfeeds  # noqa: E402
import s26pnight  # noqa: E402
import s26ptrain  # noqa: E402
import s26pvoice  # noqa: E402
import voices  # noqa: E402
from v6checks import say  # noqa: E402

TMP = Path(tempfile.mkdtemp(prefix="v26s-"))
TODAY = datetime.date(2026, 11, 25)
NOW = datetime.datetime(2026, 11, 25, 12, 0).astimezone()


class Fake:
    def __init__(self, body=b"", headers: dict | None = None, client=("127.0.0.1", 0)) -> None:
        data = json.dumps(body, ensure_ascii=False).encode() if not isinstance(body, bytes) else body
        self.rfile = io.BytesIO(data)
        self.headers = {"Content-Length": str(len(data)), **(headers or {})}
        self.client_address = client
        self.sent: list = []

    def send_json(self, status: int, body) -> None:
        self.sent = [status, body]


class Store:
    def __init__(self, days: dict) -> None:
        self.days_ = days

    def day(self, day: str):
        return self.days_.get(day)


def write(path: Path, body) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(body, ensure_ascii=False) if not isinstance(body, str) else body, encoding="utf-8")


def ms(day: str, hh: int, mm: int, ss: int = 0) -> int:
    return int(datetime.datetime.strptime(f"{day} {hh:02d}:{mm:02d}:{ss:02d}", "%Y-%m-%d %H:%M:%S").timestamp() * 1000)


def fake_recs(day: str, hh: int, mm: int, texts: list[tuple[float, float, str]], length: float = 3600.0) -> list[dict]:
    """plaudmatch._timed の作り物（t0 と blocks）"""
    import judgecheck

    t0 = ms(day, hh, mm) / 1000
    blocks = [{"t": a, "end": b, "n": judgecheck.norm(t), "text": t} for a, b, t in texts]
    blocks.append({"t": length - 1, "end": length, "n": "おわり", "text": "おわり"})
    return [{"t0": t0, "blocks": blocks}]


# MARK: - K4・K5・K6・K8


def check_feeds() -> int:
    failed = 0
    base = TMP / "mother-feeds"
    write(base / "state" / "machine_actions_for_app.json", {"version": 1, "generated_at": "2026-11-25T06:00:00+09:00", "items": [
        {"id": "ma-1", "at": "2026-11-24T10:00:00+09:00", "kind": "task_closed", "what": "タスクを閉じた", "undo": True},
        {"id": "ma-2", "at": "2026-11-25T05:00:00+09:00", "kind": "name", "what": "名前を付けた", "undo": True},
        {"id": "長い id は戻せない", "at": "2026-11-23T05:00:00+09:00", "kind": "fix", "what": "直した", "undo": True},
        {"id": "ma-4", "at": "x", "kind": "fix", "what": "形が違う", "undo": True},
        {"id": "ma-5", "at": "2026-11-23T05:00:00+09:00", "kind": "spam", "what": "kind が違う", "undo": False}]})
    got = s26pfeeds.read_machine_actions(base)
    ids = [i["id"] for i in got.get("items") or []]
    failed += say(got.get("available") and ids == ["ma-2", "ma-1", "長い id は戻せない"] and got["items"][2]["undo"] is False
                  and got["items"][0]["undo"] is True, f"K4: GET /machine-actions（新しい順・形の違いを落とす・戻せない id は undo false: {ids}）")
    write(base / "state" / "waiting_for_app.json", {"version": 1, "generated_at": "2026-11-25T06:00:00+09:00", "items": [
        {"id": "w-1", "title": "済んだ", "steps": ["a"], "link": None, "copy": None, "done": True},
        {"id": "w-2", "title": "LINE の Webhook", "steps": ["開く", "貼る"], "link": "https://developers.line.biz/console/",
         "copy": "https://example.ts.net/line/hook", "done": False},
        {"id": "w-3", "title": "秘密", "steps": ["x"], "link": "javascript:alert(1)", "copy": "token=" + "A" * 40, "done": False}]})
    got = s26pfeeds.read_waiting(base)
    rows = got.get("items") or []
    failed += say(got.get("available") and [r["id"] for r in rows] == ["w-2", "w-3", "w-1"] and rows[0]["copy"].startswith("https://")
                  and rows[1]["copy"] is None and rows[1].get("copy_hidden") is True and rows[1]["link"] is None,
                  "K5: GET /waiting（済んでいないものが先・秘密らしい copy と変なリンクは出さない）")
    write(base / "state" / "gap_task_for_app.json", {"version": 1, "generated_at": "2026-11-25T06:00:00+09:00", "items": [
        {"from": "2026-11-25T08:00:00+09:00", "to": "2026-11-25T09:00:00+09:00", "task_id": "t1", "text": "終わった", "minutes": 15},
        {"from": "2026-11-25T11:50:00+09:00", "to": "2026-11-25T12:20:00+09:00", "task_id": "t2", "text": "今の", "minutes": 15},
        {"from": "2026-11-25T15:00:00+09:00", "to": "2026-11-25T15:30:00+09:00", "task_id": None, "text": "あと", "minutes": 20}]})
    got = s26pfeeds.read_gap_task(base, datetime.datetime(2026, 11, 25, 12, 0, tzinfo=datetime.timezone(datetime.timedelta(hours=9))))
    failed += say(got.get("available") and [r["text"] for r in got["items"]] == ["今の", "あと"] and got["now"]["task_id"] == "t2",
                  "K6: GET /gap-task（終わったものは出さない・今の 1 件）")
    stream = base / "state" / "events_stream.jsonl"
    stream.write_text("\n".join(json.dumps(x, ensure_ascii=False) for x in [
        {"at": "2026-11-24T10:00:00+09:00", "kind": "promise", "text": "古い", "link": None},
        {"at": "2026-11-25T09:00:00+09:00", "kind": "promise", "text": "新しい約束", "link": "lifelog://talk/2026-11-25|1"},
        {"at": "2026-11-25T10:00:00+09:00", "kind": "ship", "text": "版の出荷", "link": "ftp://x"},
        {"at": "2026-11-25T11:00:00+09:00", "kind": "bad kind!", "text": "落ちる"}]) + "\nこわれた行\n", encoding="utf-8")
    got = s26pfeeds.read_events(base, "2026-11-25T00:00:00+09:00")
    failed += say(got.get("available") and [r["text"] for r in got["items"]] == ["新しい約束", "版の出荷"]
                  and got["items"][1]["link"] is None and got["more"] is False, "K8: GET /events?since=（since より新しい・形の違いを落とす）")
    got = s26pfeeds.read_events(base, "2026-11-24T00:00:00+09:00", limit=1)
    failed += say(got["items"][0]["text"] == "版の出荷" and got["more"] is True, "K8: limit を超えたら新しい側を残して more")
    failed += say(s26pfeeds.read_events(base, "きのう").get("available") is False, "K8: since が ISO でなければ断る")
    f = Fake()
    s26pfeeds.http_get(f, "/events", "since=2026-11-25T00%3A00%3A00%2B09%3A00", base)
    failed += say(f.sent[0] == 200 and len(f.sent[1]["items"]) == 2, "K8: GET /events の since を URL から読む")
    f = Fake()
    s26pfeeds.http_get(f, "/waiting", "", None)
    failed += say(f.sent[1].get("available") is False, "母艦が無ければ available false")
    row = appfeeds.parse_feedback(json.dumps({"kind": "undo", "id": "ma-1", "value": "undo", "day": "2026-11-25"}).encode())
    failed += say(row == {"kind": "undo", "id": "ma-1", "value": "undo", "day": "2026-11-25"}, "K4: POST /feedback の kind undo を受ける")
    return failed


# MARK: - 軽2（K7）


def check_caps() -> int:
    failed = 0
    saved = os.environ.get("LOCALAPPDATA")
    local = Path(tempfile.mkdtemp(prefix="v26s-claude-"))
    os.environ["LOCALAPPDATA"] = str(local)
    try:
        home = local / "LifeLogPC"
        home.mkdir(parents=True)
        write(home / "claude-config.json", {"monthly_usd": 100, "daily_caps": {"today-plan": 0.1, "night-review": 0.25, "x": 0.05,
                                                                                "y": 0.05}})
        rows = []
        for back in range(1, 8):   # 7 日: today-plan 3 割・night-review 7 割
            day = (TODAY - datetime.timedelta(days=back)).isoformat()
            rows.append({"at": f"{day}T08:00:00+09:00", "purpose": "today-plan", "usd": 0.3})
            rows.append({"at": f"{day}T08:00:00+09:00", "purpose": "night-review.a", "usd": 0.7})
        rows.append({"at": "2026-11-01T08:00:00+09:00", "purpose": "other", "usd": 30.0})
        (home / "claude-usage.jsonl").write_text("\n".join(json.dumps(r) for r in rows) + "\n", encoding="utf-8")
        claude.LEDGER.reset(None)
        config = claude.load_config()
        left = 100 - (30 + 7.0)              # 月の残り
        days_left = 6                         # 11/25〜11/30
        want_plan = min(0.1 * 4, max(0.1, left * 0.8 / days_left * 0.3))
        want_night = min(0.25 * 4, max(0.25, left * 0.8 / days_left * 0.7))
        got_plan = claude.today_cap("today-plan", config, day=TODAY.isoformat())
        got_night = claude.today_cap("night-review.b", config, day=TODAY.isoformat())
        got_x = claude.today_cap("x", config, day=TODAY.isoformat())
        failed += say(abs(got_plan - round(want_plan, 4)) < 1e-6 and abs(got_night - round(want_night, 4)) < 1e-6
                      and abs(got_x - min(0.2, max(0.05, left * 0.8 / days_left / 4))) < 1e-4,
                      f"K7: 今日の上限 = min(基×4, max(基, 残り×0.8÷残りの日×割合))（{got_plan}・{got_night}・{got_x}）")
        failed += say(claude.today_cap("nothing", config) is None and claude.month_days_left("2026-11-25") == 6
                      and claude.month_days_left("2026-02-01") == 28, "K7: 基の上限が無い用途は上限なし・月の残りの日")
        write(home / "claude-config.json", {"monthly_usd": 100, "auto_caps": False, "daily_caps": {"today-plan": 0.1}})
        failed += say(claude.today_cap("today-plan", claude.load_config(), day=TODAY.isoformat()) == 0.1,
                      "K7: \"auto_caps\": false で今までの上限")
        write(home / "claude-config.json", {"monthly_usd": 100, "daily_caps": {"today-plan": 0.1}})
        (home / "claude-usage.jsonl").open("a", encoding="utf-8").write(
            json.dumps({"at": f"{TODAY.isoformat()}T07:00:00+09:00", "purpose": "today-plan", "usd": 0.15}) + "\n")
        gate = claude.purpose_gate("today-plan", claude.load_config(), day=TODAY.isoformat())
        failed += say(gate is None, "K7: 基の上限（0.1）を越えても、今日の上限の中なら頼める")
        report = claude.costs_report(time.mktime(datetime.datetime(2026, 11, 25, 12).timetuple()))
        row = next((r for r in report["today"] if r["purpose"] == "today-plan"), {})
        failed += say(row.get("cap") == 0.1 and isinstance(row.get("cap_today"), float) and row["cap_today"] > 0.1
                      and "今日の三つ" in str(row.get("effect")), f"K7: GET /costs の行に cap_today と effect（{row}）")
    finally:
        if saved is not None:
            os.environ["LOCALAPPDATA"] = saved
        claude.LEDGER.reset(None)
    return failed


# MARK: - 結9 Bot のリンク


def check_links() -> int:
    failed = 0
    home, mother = TMP / "bot-home", TMP / "bot-mother"
    write(mother / "state" / "line_bot_feed.json", {"people": {"甲": "甲さんの 1 行"},
                                                    "letters": [{"id": "l1", "text": "便り", "at": "2026-11-25T07:00:00+09:00",
                                                                 "link": "lifelog://day/2026-11-25"},
                                                                {"id": "l2", "text": "変なリンク", "at": "2026-11-25T06:00:00+09:00",
                                                                 "link": "https://x"}]})
    kind, text = s25pline.answer("甲さん", home, mother, TODAY)
    failed += say(kind == "person" and text.endswith("\nlifelog://person/%E7%94%B2"), "結9: 人の返事に lifelog://person/<URL エンコード>")
    kind, text = s25pline.answer("きのう", home, mother, TODAY)
    failed += say(kind == "day" and text.endswith("\nlifelog://day/2026-11-24"), "結9: 日のまとめに lifelog://day/YYYY-MM-DD")
    kind, text = s25pline.answer("便り", home, mother, TODAY)
    failed += say("lifelog://day/2026-11-25" in text and "https://x" not in text, "結9: 便りに link（K3 の形だけ）")
    failed += say(len(s25pline.with_link("あ" * 6000, "lifelog://drafts")) <= s25pline.REPLY_MAX, "結9: 5,000 字に収める")
    failed += say(jobqueue.parse_params({"mic": ["external"]}).get("mic") == "external"
                  and "mic" not in jobqueue.parse_params({"mic": ["../x"]}), "聞2: POST /jobs の mic（外付けのマイクの受け口）")
    return failed


# MARK: - 結7 MCP


def check_mcp() -> int:
    failed = 0
    base = TMP / "mcp-mother"
    write(base / "archive" / "health" / "2026" / "11" / "24.md", "# Health 2026-11-24\n\n## 睡眠\n- 就寝 00:06\n")
    write(base / "archive" / "photos" / "2026" / "11" / "24.md", "# Photos 2026-11-24\n\n## Up\\x\n- 07:17:29 📷 a b.png\n")
    write(base / "archive" / "line" / "2026" / "11" / "24.md", "## 部屋A\n- **10:00** 甲: 駅で待ち合わせ\n## 部屋B\n- **11:00** 乙: 駅に着いた\n")
    write(base / "reports" / "line-rooms.md", "- [ ] `部屋A` — 1 対 1\n- [x] `部屋B` — グループ\n")
    write(base / "digests" / "timeline" / "2026-11-24.json", {"rows": [
        {"time": "10:00", "end": "11:00", "lane": "予定", "text": "打ち合わせ"},
        {"time": "09:50", "end": "11:30", "lane": "位置", "text": "図書館", "place": "図書館"}]})
    home = TMP / "mcp-home"
    write(home / "records" / "2026-11-24.json", {"conversations": []})
    tools = lifelog_mcp.Tools(home, None, {"lifelog_home": str(base)})
    body = tools.call("get_body", {"day": "2026-11-24"})
    photos = tools.call("list_photos", {"day": "2026-11-24"})
    line = tools.call("search_line", {"query": "駅"})
    plan = tools.call("day_actuals", {"day": "2026-11-24"})
    failed += say(body["found"] and "睡眠" in body["text"] and photos["found"] and "a b.png" in photos["text"],
                  "結7: get_body・list_photos（母艦を読むだけ）")
    failed += say([h["room"] for h in line["hits"]] == ["部屋A"] and line["excluded_rooms"] == 1,
                  "結7: search_line（外すにした部屋は出さない）")
    failed += say(plan["plans"][0]["where"] == ["図書館"] and plan["plans"][0]["conversations"] == 0, "結7: day_actuals（予定の時刻にいた所）")
    write(base / "state" / "events_stream.jsonl", json.dumps({"at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
                                                              "kind": "ship", "text": "版の出荷", "link": None}) + "\n")
    failed += say([r["text"] for r in tools.call("events_since", {})["items"]] == ["版の出荷"], "結7: events_since（K8 と同じ読み方）")
    tools.call("add_note", {"text": "傘を買う"})
    tools.call("add_person_fact", {"name": "甲", "fact": "犬を飼っている", "evidence": "2026-11-24|1"})
    rows = [json.loads(x) for x in (base / "inbox" / "mcp_candidates.jsonl").read_text(encoding="utf-8").splitlines()]
    failed += say([r["kind"] for r in rows] == ["note", "person_fact"] and all(r["status"] == "candidate" for r in rows)
                  and not (home / "inbox").exists(), "結7: 書く道具は母艦の inbox に候補を置くだけ（HOME には書かない）")
    flags = {t["name"]: t["annotations"]["readOnlyHint"] for t in lifelog_mcp.TOOLS}
    failed += say(flags["add_note"] is False and flags["add_person_fact"] is False and flags["get_body"] is True,
                  "結7: 書く道具だけ readOnlyHint false")
    saved = lifelog_mcp.INCLUDE_WORK
    lifelog_mcp.INCLUDE_WORK = False
    try:
        failed += say(tools.call("search_line", {"query": "駅"})["hits"] == [], "結7: --exclude-work のときは LINE を出さない")
    finally:
        lifelog_mcp.INCLUDE_WORK = saved
    return failed


# MARK: - 聞7・聞1・聞2・聞3・聞15・聞6・集3


def make_job(home: Path, ident: str, name: str, meta: dict, result: dict | None = None, audio: bool = True) -> None:
    write(home / "jobs" / f"{ident}.json", {"id": name, "status": "done", **meta})
    if result is not None:
        write(home / "jobs" / f"{ident}.result", result)
    if audio:
        (home / "jobs" / f"{ident}.audio").write_bytes(b"fake")


def check_gold_mic() -> int:
    failed = 0
    home, base = TMP / "gold-home", TMP / "gold-mother"
    base.mkdir(parents=True)
    day = "2026-11-24"
    failed += say(s26pnight.agreed({"haas": "今日は駅で会いましょう", "reazon": "今日は駅で会いましょう。", "whisper": "きょう"})
                  == ("今日は駅で会いましょう", ["haas", "reazon"])
                  and s26pnight.agreed({"haas": "あいう", "reazon": "あいう"}) is None
                  and s26pnight.agreed({"haas": "今日は駅で会いましょう", "haas_e": "今日は駅で会いましょう"}) is None,
                  "聞7: モデル 2 つが同じ文（短い文・雑音を除いた票は数えない）")
    make_job(home, "j1", "20261124-100000.m4a", {}, {"lines": [
        {"start": 1.0, "end": 4.0, "text": "x", "votes": {"haas": "今日は駅で会いましょう", "reazon": "今日は駅で会いましょう"}},
        {"start": 5.0, "end": 8.0, "text": "y", "votes": {"haas": "明日は雨が降りそうです", "reazon": "明日は雨がふりそうです"}},
        {"start": 9.0, "end": 12.0, "text": "z", "votes": {"haas": "全然ちがう文になった", "reazon": "全然ちがう文になった"}}]})
    saved = plaudmatch._timed
    plaudmatch._timed = lambda h, b, d: ((fake_recs(day, 10, 0, [(0.5, 4.5, "今日は駅で会いましょう"), (9.0, 12.0, "まったく別の話")]), [])
                                         if d == day else ([], []))
    try:
        got = s26pnight.machine_gold(home, base, TODAY, lambda data: np.full(16000 * 20, 0.01, dtype=np.float32))
        index = s26pnight.gold_index(home)
        wav = home / s26pnight.GOLD_DIR / index[0]["file"] if index else None
        failed += say(got["added"] == 1 and len(index) == 1 and index[0]["text"] == "今日は駅で会いましょう" and wav and wav.is_file()
                      and wav.stat().st_size > 16000 * 2, f"聞7・K10: PLAUD とモデル 2 つが合った行だけ機械の正解に（{got}）")
        again = s26pnight.machine_gold(home, base, TODAY, lambda data: np.zeros(16000 * 20, dtype=np.float32))
        failed += say(again["added"] == 0 and again["total"] == 1, "聞7: 同じ行は 2 回足さない")
        # 聞1・聞2: 場面 × マイク
        parsed = {"conversations": [{"start": ms(day, 10, 0), "lines": [
            {"time": ms(day, 10, 0, 1), "audio": "20261124-100000-w.m4a", "text": "今日は駅で会いましょう"},
            {"time": ms(day, 10, 0, 1), "audio": "20261124-100000.m4a", "text": "今日は駅で会いま"},
            {"time": ms(day, 10, 0, 1), "audio": "20261124-100001.m4a", "text": "今日は駅で会いましょう"}]}]}
        got = s26pnight.mic_scene_day(home, base, day, parsed, {"20261124-100001.m4a": {"params": {"mic": "external"}}})
        devices = got.get("other") or {}
        failed += say(set(devices) == {"watch", "iphone", "external"} and devices["watch"]["matched"] > devices["iphone"]["matched"],
                      f"聞1・聞2: 場面ごと・マイクごと（時計・iPhone・外付け）に PLAUD と合った字（{sorted(devices)}）")
        days = {(TODAY - datetime.timedelta(days=i)).isoformat(): {"shop": {"watch": {"lines": 30, "chars": 300, "matched": 270},
                                                                             "iphone": {"lines": 30, "chars": 300, "matched": 150}}}
                for i in range(1, 8)}
        write(s26pnight.folder(home) / "mic-scenes.json", {"days": days})
        pick = s26pnight.mic_scene_pick(home, TODAY)
        failed += say(pick["days"] == 7 and pick["scenes"]["shop"]["pick"] == "watch", "聞1: 7 日測れた場面だけ、良いほうのマイクを候補に")
        failed += say(s26pnight.mic_scene_pick(home, TODAY, need_days=8)["scenes"]["shop"]["pick"] is None, "聞1: 日が足りなければ候補なし")
    finally:
        plaudmatch._timed = saved
    return failed


def check_listen() -> int:
    failed = 0
    home, base = TMP / "listen-home", TMP / "listen-mother"
    base.mkdir(parents=True)
    day = "2026-11-24"
    make_job(home, "a", "20261124-100000.m4a", {"audio_seconds": 120, "voiced_seconds": 2, "lines": 0})
    make_job(home, "b", "20261124-100200.m4a", {"audio_seconds": 120, "voiced_seconds": 60, "lines": 5})
    make_job(home, "c", "20261124-140000.m4a", {"audio_seconds": 120, "voiced_seconds": 1, "lines": 0})   # 前後に会話が無い
    picked = s26pnight.full_listen_pick(home, TODAY, set())
    failed += say([p["name"] for p in picked] == ["20261124-100000.m4a"], "聞3: 声なしの区切りのうち、前後に会話があるものだけ")
    saved = plaudmatch._timed
    plaudmatch._timed = lambda h, b, d: ((fake_recs(day, 9, 59, [(90.0, 96.0, "駅で会いましょう")]), []) if d == day else ([], []))

    def asr(audio, segments):
        assert segments[0] == (0.0, 25.0)
        return [{"start": 0.0, "end": 3.0, "text": "ご視聴ありがとうございました"},
                {"start": 30.0, "end": 34.0, "text": "駅で会いましょう"}, {"start": 70.0, "end": 72.0, "text": "空耳の文"}]

    try:
        got = s26pnight.full_listen(home, base, TODAY, asr, lambda data: np.zeros(16000 * 120, dtype=np.float32))
        shadow = json.loads((s26pnight.folder(home) / "full-listen" / f"{day}.json").read_text(encoding="utf-8"))
        failed += say(got["chunks"] == 1 and got["dropped"] == 1 and got["matched"] > 0 and got["junk"] > 0
                      and len(shadow["chunks"]["20261124-100000.m4a"]) == 2,
                      f"聞3: 全部聞いて、決まり文句を落とし、拾えた字とごみを数える（記録には足さない。{got}）")
        failed += say(s26pnight.full_listen(home, base, TODAY, asr, lambda d: np.zeros(1))["chunks"] == 0, "聞3: 済んだ区切りは聞き直さない")
        # 聞15
        parsed = {"conversations": [{"start": ms(day, 11, 0), "lines": [
            {"time": ms(day, 11, 0, 0), "speaker": "自分", "speakerID": "me", "audio": "20261124-110000.m4a", "offset": 0.0, "end": 2.0,
             "text": "どう思う"},
            {"time": ms(day, 11, 0, 3), "speaker": "人物4", "audio": "20261124-110000.m4a", "offset": 3.0, "end": 6.0, "text": "いいと"},
            {"time": ms(day, 11, 0, 40), "speaker": "人物9", "audio": "20261124-110000.m4a", "offset": 40.0, "end": 43.0,
             "text": "隣の席の声"}]}]}
        far = {ms(day, 11, 0, 3), ms(day, 11, 0, 40)}
        lines = s26pnight.boost_lines(parsed, far)
        failed += say([x["speaker"] for x in lines] == ["人物4"], "聞15: 自分と交互の小さい声だけ（隣の客の声は触らない）")
        quiet = (0.002 * np.sin(np.arange(16000 * 60) / 5)).astype(np.float32)
        failed += say(s26pnight.gain_for(quiet[:16000]) == s26pnight.BOOST_MAX_DB and s26pnight.gain_for(np.zeros(0)) == 0.0,
                      "聞15: 上げる dB は上限まで")
        write(home / "s22" / "speaker-tags" / f"{day}.json", {"tags": [{"ms": m, "kind": "far"} for m in far]})
        (home / "audio" / day).mkdir(parents=True)
        (home / "audio" / day / "20261124-110000.m4a").write_bytes(b"x")
        plaudmatch._timed = lambda h, b, d: ((fake_recs(day, 10, 59, [(62.0, 67.0, "いいと思うよ本当に")]), []) if d == day else ([], []))
        got = s26pnight.boost(home, base, Store({day: parsed}), TODAY, lambda a, s: [{"start": 0, "end": 3, "text": "いいと思うよ本当に"}],
                              lambda data: quiet)
        total = s26pnight.boost_total(home, TODAY)
        failed += say(got["lines"] == 1 and got["after"] > got["before"] and total["better"] == 1,
                      f"聞15: 持ち上げた文と前の文を PLAUD で比べる（影。{got}）")
        # 聞6
        write(home / "s22" / "speaker-tags" / "2026-11-23.json", {"tags": [{"ms": 1, "kind": "overlap"}, {"ms": 2, "kind": "overlap"}]})
        failed += say(s26pnight.overlap_count(home, TODAY)["tags"] == 2, "聞6: 重なりの札を数える（分けるのはオンのときだけ）")

        class Sep:
            def split(self, samples):
                return [samples, samples]

        write(home / "s22" / "speaker-tags" / f"{day}.json", {"tags": [{"ms": ms(day, 11, 0, 0), "kind": "overlap"},
                                                                     {"ms": ms(day, 11, 0, 3), "kind": "overlap"}]})
        got = s26pnight.separate(home, base, Store({day: parsed}), TODAY, lambda a, s: [{"text": "いいと思うよ"}], lambda d: quiet,
                                 separator=Sep())
        failed += say(got["pairs"] == 1, "聞6: 作り物の分ける部品で、重なりの組を分けて比べる")
    finally:
        plaudmatch._timed = saved
    return failed


def check_sounds() -> int:
    failed = 0
    home, base = TMP / "sound-home", TMP / "sound-mother"
    base.mkdir(parents=True)
    failed += say(s26pnight.night_chunk(datetime.datetime(2026, 11, 24, 23, 0).timestamp()) == "2026-11-25"
                  and s26pnight.night_chunk(datetime.datetime(2026, 11, 25, 3, 0).timestamp()) == "2026-11-25"
                  and s26pnight.night_chunk(datetime.datetime(2026, 11, 25, 12, 0).timestamp()) is None, "集3: 夜の区切りの日")
    tags = [[{"name": "Cough", "prob": 0.6}], [{"name": "Cough", "prob": 0.5}], [{"name": "Speech", "prob": 0.9}],
            [{"name": "Cough", "prob": 0.4}], [{"name": "Snoring", "prob": 0.7}], [{"name": "Snoring", "prob": 0.1}]]
    failed += say(s26pnight.count_sounds(tags) == {"cough": 2, "snore_seconds": 2.0}, "集3: 続いたせきは 1 回・いびきは秒")
    folder = home / "audio" / "2026-11-25"
    folder.mkdir(parents=True)
    (folder / "20261125-020000.m4a").write_bytes(b"x")
    (folder / "20261125-130000.m4a").write_bytes(b"x")
    got = s26pnight.sounds(home, base, TODAY, lambda audio, ranges: [[{"name": "Snoring", "prob": 0.8}] for _ in ranges],
                           lambda data: np.zeros(16000 * 60, dtype=np.float32))
    row = got["days"].get("2026-11-25") or {}
    mother = json.loads((base / "inbox" / "pc-sounds" / "2026-11-25.json").read_text(encoding="utf-8"))
    failed += say(got["chunks"] == 1 and row.get("snore_minutes") == 1.0 and mother["cough_count"] == 0
                  and "text" not in json.dumps(mother), f"集3: 夜の区切りだけ数え、母艦には数だけ（{row}）")
    return failed


# MARK: - 結1・聞5・聞4（声）


DIM = 16
RNG = np.random.default_rng(7)
DIRS = {k: v / np.linalg.norm(v) for k, v in ((k, RNG.normal(size=DIM)) for k in ("甲", "乙", "丙", "me", "x"))}


def vec(who: str) -> np.ndarray:
    v = DIRS[who] + 0.12 * RNG.normal(size=DIM)
    return (v / np.linalg.norm(v)).astype(np.float32)


def make_day(home: Path, day: str, convs: list[tuple[int, list[tuple[str, str | None, str]]]]) -> dict:
    """convs: [(始まりの ms, [(話し手, speakerID, 声の向き)])]"""
    ds = voices.DayStore(home, day)
    conversations = []
    for ci, (start, people) in enumerate(convs):
        audio = f"{day.replace('-', '')}-{100000 + ci:06d}.m4a"
        lines = []
        for i, (speaker, ident, who) in enumerate(people):
            line = {"time": start + i * 3000, "speaker": speaker, "speakerID": ident, "audio": audio,
                    "offset": float(i * 3), "end": float(i * 3) + 2.5, "text": f"行{i}"}
            lines.append(line)
            ds.vectors[voices.seg_key(audio, line["offset"], line["end"])] = vec(who)
        conversations.append({"start": start, "end": start + len(people) * 3000, "lines": lines})
    ds.save()
    return {"conversations": conversations}


def filler() -> list[tuple[str, str | None, str]]:
    return [("甲", "1", "甲")] * 7 + [("乙", "2", "乙")] * 7 + [("自分", "me", "me")] * 6


def check_voice() -> int:
    failed = 0
    home, base = TMP / "voice-home", TMP / "voice-mother"
    base.mkdir(parents=True)
    d1 = "2026-11-24"
    days = {d1: make_day(home, d1, [(ms(d1, 10, 0), filler()),
                                     (ms(d1, 14, 0), [("自分", "me", "me")] * 3 + [("人物5", None, "甲")] * 4),
                                     (ms(d1, 16, 0), [("自分", "me", "me")] * 2 + [("乙", "2", "乙")] * 2)])}
    write(base / "state" / "talk_guess_for_pc.json", {"version": 1, "generated_at": "2026-11-25T06:00:00+09:00", "items": [
        {"talk_id": "", "day": d1, "start": "2026-11-24T14:00:00", "end": "2026-11-24T14:01:00",
         "candidates": [{"name": "乙", "score": 0.7, "why": ["予定"]}, {"name": "甲", "score": 0.6, "why": ["LINE"]}]},
        {"talk_id": f"{d1}|{ms(d1, 16, 0)}", "day": d1, "start": ms(d1, 16, 0), "end": ms(d1, 16, 1),
         "candidates": [{"name": "乙", "score": 0.9, "why": []}]},
        {"talk_id": "", "day": d1, "start": "2026-11-24T20:00:00", "end": "2026-11-24T20:01:00",
         "candidates": [{"name": "甲", "score": 0.9, "why": []}]},
        {"talk_id": "", "day": d1, "start": "x", "end": "y", "candidates": [{"name": "甲", "score": 1}]}]})
    store = Store(days)
    body = s26pvoice.check_guesses(home, base, store, TODAY)
    statuses = [r["status"] for r in body["items"]]
    first = body["items"][0]
    failed += say(statuses == ["voice_ok", "named", "no_talk"] and first["maybe"] == "甲" and first["voice"] >= s26pvoice.VOICE_OK,
                  f"結1・K9: 場面の見込みより声が近い人を「たぶん」に・名前のある会話は触らない（{statuses}・{first.get('maybe')}）")
    mother = json.loads((base / "inbox" / "pc-talk-guess" / "s26p_talk_guess.json").read_text(encoding="utf-8"))
    failed += say(mother["counts"].get("voice_ok") == 1 and "vec" not in json.dumps(mother),
                  "結1: 母艦に置く（声の数字は入れない）")
    failed += say(s26pvoice.read_maybe(home) == {f"{d1}|{ms(d1, 14, 0)}": "甲"}, "結1: 記録を読む口に返す「たぶん」")
    labels = {"u:5": {"name": "人物5", "items": [{"time": ms(d1, 14, 0, 10)}]}, "n:1": {"name": "甲", "items": []},
              "n:2": {"name": "乙", "items": []}}
    bonus = s26pvoice.chain_bonus(lambda l, d: (lambda a, b: 0.01), lambda: home, lambda: base, lambda: store, lambda: {})(labels, [d1])
    failed += say(abs(bonus("u:5", "n:2") - (0.01 + 0.05 * 0.7)) < 1e-9 and abs(bonus("u:5", "n:1") - (0.01 + 0.05 * 0.6)) < 1e-9,
                  "結1: 「名前のある人かも」の近さに、場面の候補の点を足す（前の足し分に重ねる）")
    # 聞5
    for i, d in enumerate(("2026-11-21", "2026-11-22", "2026-11-23")):
        write(base / "archive" / "calendar" / "2026" / "11" / f"{d[8:]}.md",
              f"# Calendar {d}\n\n## 時間指定\n\n- 18:00-19:00 ごはん\n  - 相手: 丙\n  - source: x\n- 20:00-21:00 会\n  - 相手: 甲、乙\n")
        people = [("自分", "me", "me")] * 3 + [("人物7", None, "丙")] * 3
        convs = [(ms(d, 10, 0), filler()), (ms(d, 18, 10), people)]
        if i == 0:
            convs.append((ms(d, 12, 0), [("丙", "3", "丙")] * 2))
        days[d] = make_day(home, d, convs)
    events = s26pvoice.single_partner_events(base, "2026-11-21")
    failed += say([e["name"] for e in events] == ["丙"], "聞5: 相手が 1 人だけの予定")
    got = s26pvoice.calendar_update(home, base, store, TODAY)
    question = s26pvoice.pending_question(home, base)
    failed += say(got["ready"] == 1 and question is not None and question["answer"] == "yesno" and "丙" in question["text"],
                  f"聞5: 違う予定 3 回の声がそろったら問いを 1 つ（{got}）")
    original = lambda b, today=None: {"available": True, "items": [{"id": f"q{i}"} for i in range(5)]}  # noqa: E731
    wrapped = s26pvoice.wrap_questions(original, lambda: home, lambda: {})
    items = wrapped(base)["items"]
    failed += say(len(items) == 5 and items[2]["id"] == question["id"], "聞5: 問いは 3 番目に入れ、数は増やさない")
    write(base / "inbox" / "know_answers.jsonl", json.dumps({"id": question["id"], "kind": "question", "value": "answered",
                                                            "text": "はい", "at": "2026-11-25T08:00:00+09:00"}) + "\n")
    s26pvoice.calendar_update(home, base, store, TODAY)
    samples = s26pvoice.wrap_samples(lambda h: {"available": False}, lambda: home, lambda: {})(home)
    failed += say(s26pvoice.pending_question(home, base) is None and samples.get("available")
                  and [p["speaker"] for p in samples["people"]] == ["丙"] and samples["people"][0]["speakerID"] == "3"
                  and len(samples["people"][0]["samples"]) == 3, "聞5: 「はい」なら声の見本の候補に（足すのは本人の端末）")
    # 聞4
    diar = s26pvoice.day_diar(home, store, d1)
    named = [c["name"] for c in diar["clusters"] if c["name"]]
    failed += say(diar["agree"] == 1.0 and "甲" in named and diar["maybe_lines"] == 4,
                  f"聞4: 1 日まるごとのかたまりに名前（影。合い方 {diar['agree']}・名前が付きそうな行 {diar['maybe_lines']}）")
    return failed


# MARK: - 聞11


def check_train() -> int:
    failed = 0

    class Trainer:
        def command(self):
            return ["py", "train_personal.py"]

    t = Trainer()
    config: dict = {}
    s26ptrain.hook_weekly(t, lambda: config)
    first = t.command()
    config["s26p_weekly_swap"] = True
    failed += say(first[-1] == "--candidate" and "--candidate" not in t.command() and not s26ptrain.hook_weekly(t, lambda: config),
                  "聞11: 毎週の学び直しは候補に（\"s26p_weekly_swap\": true で前のまま）")
    home = TMP / "train-home"
    d = s26ptrain.dirs(home)
    write(d["model"] / "trained.json", {"trained": "t1"})
    (d["model"] / "model.bin").write_bytes(b"1")
    rates = {"now": {"rate": 0.80, "lines": 500}}
    rate_of = lambda days: rates["now"]  # noqa: E731
    s26ptrain.nightly(home, None, {}, TODAY, rate_of=rate_of)
    write(d["old"] / "trained.json", {"trained": "t1"})
    (d["old"] / "model.bin").write_bytes(b"1")
    write(d["model"] / "trained.json", {"trained": "t2"})
    got = s26ptrain.nightly(home, None, {}, TODAY, rate_of=rate_of)
    failed += say(got.get("swapped") is True, "聞11: 入れ替わったことに気づく")
    rates["now"] = {"rate": 0.70, "lines": 300}
    got = s26ptrain.nightly(home, None, {}, TODAY + datetime.timedelta(days=3), rate_of=rate_of)
    failed += say(got.get("rollback_candidate") is True and not got.get("rolled_back")
                  and s26ptrain.trained(d["model"]).get("trained") == "t2", "聞11: 悪くなったら「戻す候補」（自動で戻すのはオフ）")
    state = json.loads((home / s26ptrain.STATE).read_text(encoding="utf-8"))
    state["swap"].pop("judged")
    (home / s26ptrain.STATE).write_text(json.dumps(state), encoding="utf-8")
    reloaded = []
    got = s26ptrain.nightly(home, None, {"s26p_auto_rollback": True}, TODAY + datetime.timedelta(days=3), reload=lambda: reloaded.append(1),
                            rate_of=rate_of)
    failed += say(got.get("rolled_back") is True and s26ptrain.trained(d["model"]).get("trained") == "t1" and reloaded,
                  "聞11: \"s26p_auto_rollback\": true なら前のモデルに戻して読み直す")
    write(d["candidate"] / "trained.json", {"trained": "t3", "cer_before": 0.30, "cer_after": 0.20})
    (d["candidate"] / "model.bin").write_bytes(b"3")
    got = s26ptrain.nightly(home, None, {}, TODAY + datetime.timedelta(days=4), rate_of=rate_of,
                            moment=datetime.datetime(2026, 11, 29, 2, 0))
    failed += say(not got.get("promoted") and got["gain"] == 0.1, "聞11: 入れ替えはオフ（候補の CER の下がりは数える）")
    got = s26ptrain.nightly(home, None, {"s26p_promote": True}, TODAY + datetime.timedelta(days=4), rate_of=rate_of,
                            moment=datetime.datetime(2026, 11, 29, 2, 0), reload=lambda: reloaded.append(2))
    failed += say(got.get("promoted") is True and s26ptrain.trained(d["model"]).get("trained") == "t3"
                  and s26ptrain.trained(d["old"]).get("trained") == "t1", "聞11: \"s26p_promote\": true で正解集の良い候補を入れ替える")
    failed += say("候補として置くだけ" in s26ptrain.summary(home, {}), "聞11: summary.md の 1 行")
    return failed


# MARK: - 結4


def check_faces() -> int:
    failed = 0
    home, base, root = TMP / "face-home", TMP / "face-mother", TMP / "face-photos"
    write(base / "archive" / "photos" / "2026" / "11" / "24.md",
          "# Photos 2026-11-24\n\n## Up\\a\n- 07:17:29 📷 2026-11-24 07-17-29.jpg\n- 07:18:00 📷 b.png @ 35.6,139.7 [iPhone]\n"
          "- 07:19:00 📷 c.heic\n- 08:51:44-08:51:58 連写 3枚\n")
    photos = s26pface.photos_of(base, "2026-11-24", root)
    failed += say([n for n, _ in photos] == ["2026-11-24 07-17-29.jpg", "b.png", "c.heic"], "結4: 写真の索引を読む")
    for name, path in photos[:2]:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"x")
    face = DIRS["甲"]

    class Models:
        def faces(self, path):
            return [face, DIRS["乙"]] if path.name == "b.png" else [face]

    got = s26pface.embed_night(home, base, {"photo_root": str(root)}, TODAY, models=Models())
    failed += say(got == {"photos": 2, "faces": 3, "heic": 1, "missing": 0}, f"結4: 顔を数える（HEIC は数えるだけ。{got}）")
    built = s26pface.build_clusters(home, base)
    clusters = json.loads((home / s26pface.FACES / "clusters.json").read_text(encoding="utf-8"))["clusters"]
    failed += say(built["clusters"] == 1 and clusters[0]["photos"] == 2 and "vec" not in json.dumps(clusters),
                  "結4: 2 枚以上のまとまりだけ（数の並びは入れない）")
    f = Fake({"cluster": clusters[0]["id"], "name": "甲"}, client=("100.1.2.3", 0))
    s26pface.http_post(f, home, base)
    failed += say(f.sent[0] == 403, "結4: 名前を付けるのはこの PC の中からだけ")
    f = Fake({"cluster": clusters[0]["id"], "name": "甲"})
    s26pface.http_post(f, home, base)
    mother = json.loads((base / "inbox" / "pc-faces" / "s26p_faces.json").read_text(encoding="utf-8"))
    failed += say(f.sent[0] == 200 and list(mother["people"]) == ["甲"] and len(mother["people"]["甲"]) == 2
                  and "vec" not in json.dumps(mother), "結4: 名前の付いたまとまりを母艦へ（顔の数字は入れない）")
    failed += say(not s26pface.on({}) and s26pface.on({"s26p_faces": True}), "結4: 初めはオフ")
    return failed


# MARK: - つなぎ・summary.md


def check_hub() -> int:
    failed = 0
    home, base = TMP / "hub-home", TMP / "hub-mother"
    base.mkdir(parents=True)
    (home).mkdir(parents=True)
    main = SimpleNamespace(HOME=str(home), load_config=lambda: {}, log=lambda text: None,
                           mothership=SimpleNamespace(home=lambda config: base), App=SimpleNamespace(records=Store({})),
                           load_audio=lambda data: np.zeros(16000, dtype=np.float32))
    saved = (s26pc.S.main, s26pc.S.home, s26pc.S.thread)
    import knowapp
    import voicesamples

    saved_hooks = (voices.PRIOR_BONUS, knowapp.READERS.get("/know/questions"), voicesamples.read)
    try:
        s26pc.S.thread = object()   # 裏の糸は起こさない
        s26pc.start(main)
        failed += say(getattr(voices.PRIOR_BONUS, "s26p_wrapped", False) and getattr(knowapp.READERS["/know/questions"], "s26p_wrapped", False)
                      and getattr(voicesamples.read, "s26p_wrapped", False), "つなぎ: 声の足し分・問い・声の見本を包む")
        out = s26pc.night(home, base, Store({}), {}, TODAY, asr=lambda a, s: [], tagger=lambda a, r: [],
                          load_audio=lambda data: np.zeros(16000, dtype=np.float32))
        errors = [k for k, v in out.items() if isinstance(v, dict) and "error" in v]
        failed += say(not errors and out["separate"] == "off" and out["day_diar"] == "off" and out["faces"] == "off",
                      f"夜の分: どれもつまずかない・モデルを替える所はオフ（{errors}）")
        worries, lines = s26pc.summary_lines(None)
        text = "\n".join(lines)
        failed += say(not any("数えられませんでした" in line for line in lines) and "K4" in text and "聞7" in text and "聞11" in text
                      and "結4" in text, f"summary.md の「s26 の数」の節（{len(lines)} 行）")
        failed += say(set(s26pc.features()) == {"machineactions", "waiting", "gaptask", "events"}, "/hello の features")
        f = Fake()
        s26pc.http_get(f, "/gap-task", "")
        failed += say(f.sent[0] == 200 and f.sent[1].get("available") is False, "GET /gap-task: 母艦に無ければ available false")
    finally:
        s26pc.S.main, s26pc.S.home, s26pc.S.thread = saved
        voices.PRIOR_BONUS, voicesamples.read = saved_hooks[0], saved_hooks[2]
        if saved_hooks[1] is not None:
            knowapp.READERS["/know/questions"] = saved_hooks[1]
    return failed


CHECKS = [check_feeds, check_caps, check_links, check_mcp, check_gold_mic, check_listen, check_sounds, check_voice, check_train,
          check_faces, check_hub]


def run_all() -> int:
    failed = 0
    for check in CHECKS:
        try:
            failed += check()
        except Exception as error:  # noqa: BLE001 — 1 つが落ちても、ほかは確かめる
            import traceback

            traceback.print_exc()
            failed += say(False, f"{check.__name__} が途中で落ちました: {error!r}")
    # s27（2026-11-25。担当 P）の確かめも続けて（CI の手順を増やさないため）
    import v27checks_s27p

    failed += v27checks_s27p.run_all()
    return failed


def main() -> int:
    failed = run_all()
    print("ぜんぶ OK" if not failed else f"NG の数: {failed}", flush=True)
    return failed


if __name__ == "__main__":
    sys.exit(main())
