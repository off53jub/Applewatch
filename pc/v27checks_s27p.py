"""2026-11-25（s27。担当 P）: 家の PC の s27 の分を確かめる（K4 の答えの受け口・K5 の口 4 つ・場5・場7）。

    python pc/v27checks_s27p.py          （v26checks_s26p.py の最後にも呼ばれる。CI の手順を増やさずに動かすため）

本物の HOME・母艦・iPhone は使わない（一時フォルダに作り物の母艦を作る。案件は「見本の案件 A」、人は「見本さん」の記号だけ）。
"""

from __future__ import annotations

import io
import json
import os
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

if not any(mark in os.environ.get("LOCALAPPDATA", "") for mark in ("v25s", "v26s", "v27s")):
    os.environ["LOCALAPPDATA"] = str(Path(tempfile.mkdtemp(prefix="v27s-local-")))

import appfeeds  # noqa: E402
import s27pwork  # noqa: E402
from v6checks import say  # noqa: E402

TMP = Path(tempfile.mkdtemp(prefix="v27s-"))


class Fake:
    """受け口の作り物（send_json と、HTML を返すときの send_response など）"""

    def __init__(self, body=b"", client=("127.0.0.1", 0)) -> None:
        self.data = json.dumps(body, ensure_ascii=False).encode() if not isinstance(body, bytes) else body
        self.client_address = client
        self.sent: list = []
        self.status = None
        self.head: list = []
        self.wfile = io.BytesIO()

    def send_json(self, status: int, body) -> None:
        self.sent = [status, body]

    def send_response(self, status: int) -> None:
        self.status = status

    def send_header(self, name: str, value: str) -> None:
        self.head.append((name, value))

    def end_headers(self) -> None:
        pass


def write(path: Path, body) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(body, ensure_ascii=False) if not isinstance(body, str) else body, encoding="utf-8")


def item(ident: str, kind: str, text: str, day: str, project: str | None = "wp-0000000a", state: str = "open") -> dict:
    return {"id": ident, "kind": kind, "text": text, "project_id": project, "who": "見本さん", "day": day, "time": "10:00",
            "due": None, "due_guess": False, "ball": "me", "age_days": 1, "state": state, "certainty": "maybe",
            "src": "見本の会話", "link": None}


def sample_k2() -> dict:
    a = {"id": "wp-0000000a", "name": "見本の案件 A", "client": "見本の顧客 Ｘ", "kind": "mine", "signal": "red",
         "status_line": "受入テストの 2 回目を進めている（たぶん）", "last_moved": "2026-11-25",
         "counts": {"homework": 2, "open": 1, "issue": 0, "decided": 2}, "people": [], "milestone": None, "risk": [],
         "conflicts": [], "progress": [],
         "items": [item("i1", "homework", "見本の表を直す（#212 の件）", "2026-11-24"),
                   item("i2", "open", "見本の画面の文言をどうするか", "2026-11-25"),
                   item("i3", "homework", "済んだ見本の宿題", "2026-11-20", state="done")],
         "timeline": [item("d1", "decided", "見本の進め方を決めた", "2026-11-20"),
                      item("d2", "decided", "#212 は来週に回すと決めた", "2026-11-22"),
                      item("d3", "decided", "#2120 は別の話", "2026-11-23")],
         "heard": [], "stale": False}
    b = {"id": "wp-0000000b", "name": "ミホンノアンケン B", "client": None, "kind": "other", "signal": "gray",
         "status_line": "聞いた話だけ", "last_moved": "2026-11-10", "counts": {}, "people": [], "items": [],
         "timeline": [], "heard": [], "stale": True}
    person = {"id": "wm-0000000c", "name": "見本さん", "org": "client", "team": None, "role": "見本の係", "projects": ["wp-0000000b"],
              "recent": [], "their_homework": [item("h1", "homework", "見本さんの宿題", "2026-11-24", None)],
              "ball": {"me": 0, "them": 1}, "promises": {"mine": [], "theirs": []}, "last_talk": "2026-11-24",
              "quiet": False, "expert_in": []}
    return {"version": 1, "generated_at": "2026-11-25T23:00:00+09:00", "as_of": "2026-11-25",
            "counts": {"homework_today": 1, "open_mine": 2, "next_meeting_at": None},
            "today": {"homework": [], "waiting_on_me": [], "waiting_on_others": [], "stuck_by_me": [], "standup": [],
                      "meetings": []},
            "diff": {"since": "2026-11-24", "added": [], "closed": [], "decided": []},
            "projects": [a, b], "people": [person], "side": None, "monthly_other": None}


def check_work() -> int:
    failed = 0
    base = TMP / "work"
    failed += say(s27pwork.read_work(base).get("available") is False, "GET /work: 無ければ available false")
    write(base / s27pwork.WORK, "{壊れた")
    failed += say(s27pwork.read_work(base).get("available") is False, "GET /work: 壊れていれば available false")
    write(base / s27pwork.WORK, [1, 2])
    failed += say(s27pwork.read_work(base).get("available") is False, "GET /work: 形が違えば available false")
    data = sample_k2()
    write(base / s27pwork.WORK, data)
    got = s27pwork.read_work(base)
    failed += say(got.get("available") is True and got["projects"][0]["name"] == "見本の案件 A" and got["counts"] == data["counts"],
                  "GET /work: K2 のファイルそのまま（＋available true）")
    # 更新時刻と大きさが同じあいだは読み直さない
    path = base / s27pwork.WORK
    stat = path.stat()
    raw = path.read_text(encoding="utf-8")
    path.write_text(raw.replace("見本の案件 A", "見本の案件 Z"), encoding="utf-8")
    os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns))
    failed += say(s27pwork.read_work(base)["projects"][0]["name"] == "見本の案件 A", "GET /work: 更新時刻が同じなら覚えた中身")
    os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns + 5_000_000_000))
    failed += say(s27pwork.read_work(base)["projects"][0]["name"] == "見本の案件 Z", "GET /work: 更新されたら読み直す")
    big = base / "state" / "big.json"
    big.write_bytes(b" " * (s27pwork.WORK_READ_MAX + 1))
    failed += say(s27pwork._load(base, Path("state") / "big.json", s27pwork.WORK_READ_MAX)[1] == "too_big",
                  "大きすぎるファイルは読まない")
    f = Fake()
    s27pwork.http_get(f, "/work", "", TMP / "nowhere")
    failed += say(f.sent[0] == 200 and f.sent[1].get("available") is False, "GET /work: 母艦が無ければ available false")
    write(base / s27pwork.CONFIG, {"s27p": {"work": False}})
    f = Fake()
    s27pwork.http_get(f, "/work", "", base)
    failed += say(f.sent[1].get("available") is False and "止め" in f.sent[1].get("reason", ""), "切り替えで止められる")
    (base / s27pwork.CONFIG).unlink()
    f = Fake()
    s27pwork.http_get(f, "/work", "", base)
    failed += say(f.sent[1].get("available") is True, "切り替えを消せば戻る")
    return failed


def check_confirm() -> int:
    failed = 0
    base = TMP / "confirm"
    base.mkdir(parents=True, exist_ok=True)
    f = Fake()
    s27pwork.http_get(f, "/work/confirm", "", base)
    failed += say(f.sent[0] == 200 and f.sent[1] == {"items": []}, "GET /work/confirm: 無ければ {\"items\": []}")
    good = {"id": "c1", "kind": "project_merge", "title": "見本の案件 A と B", "question": "同じ案件ですか",
            "choices": [{"value": "merge", "label": "同じ"}, {"value": "keep", "label": "別"}], "evidence": ["見本の会話"],
            "default": "keep"}
    items = [good, {**good, "id": "c2", "default": "ほか"}, {**good, "id": "c3", "kind": "nope"}, {**good, "id": "bad id"},
             {**good, "id": "c4", "choices": []}, {**good, "id": "c5"}, {**good, "id": "c1"}]
    items += [{**good, "id": f"m{n}"} for n in range(80)]
    write(base / s27pwork.CONFIRM, {"version": 1, "generated_at": "2026-11-25T23:00:00+09:00", "items": items})
    write(base / appfeeds.FEEDBACK_FILE, json.dumps({"kind": "work_confirm", "id": "c5", "value": "merge"}) + "\n")
    got = s27pwork.read_confirm(base)
    ids = [x["id"] for x in got["items"]]
    failed += say(ids[:2] == ["c1", "c2"] and "c3" not in ids and "c4" not in ids and "bad id" not in ids
                  and ids.count("c1") == 1, "GET /work/confirm: 形の違うもの・同じ id は落とす")
    failed += say("c5" not in ids, "GET /work/confirm: もう答えた id は出さない")
    failed += say(len(ids) == s27pwork.CONFIRM_MAX and got["items"][1]["default"] is None and got["items"][0]["default"] == "keep",
                  f"GET /work/confirm: {s27pwork.CONFIRM_MAX} 件まで・default は choices の中だけ")
    write(base / s27pwork.CONFIRM, "{壊れた")
    got = s27pwork.read_confirm(base)
    failed += say(got["items"] == [] and "reason" in got, "GET /work/confirm: 壊れていれば items は空")
    return failed


def check_ask() -> int:
    failed = 0
    base = TMP / "ask"
    base.mkdir(parents=True, exist_ok=True)
    got = s27pwork.ask(base, "見本")
    failed += say(got.get("available") is False and got["answers"] == [], "GET /work/ask: K2 が無ければ available false")
    write(base / s27pwork.WORK, sample_k2())
    write(base / s27pwork.PROJECTS, {"version": 1, "projects": [{"id": "wp-0000000a", "name": "見本の案件 A",
                                                                "aliases": ["サンプルプロジェクト"]}]})
    write(base / s27pwork.PEOPLE, {"version": 1, "people": [{"id": "wm-0000000c", "name": "見本さん", "reading": "みほんさん",
                                                            "aliases": ["見本氏"], "projects": ["wp-0000000a"]}]})
    write(base / s27pwork.TALK_TAGS, {"version": 1, "items": [{"talk_key": "2026-11-24|10:00", "tickets": ["#345"],
                                                              "project_ids": ["wp-0000000b"]}]})

    def first(q: str):
        answers = s27pwork.ask(base, q)["answers"]
        return answers[0] if answers else None

    a = first("見本の案件 A")
    failed += say(a is not None and a["project_id"] == "wp-0000000a" and a["link"] == "lifelog://work/project/wp-0000000a"
                  and a["status_line"].startswith("受入テスト"), "GET /work/ask: 名前で引ける・リンクつき")
    failed += say(a is not None and a["last_decided"]["id"] == "d3" and [i["id"] for i in a["open"]] == ["i2", "i1"],
                  "GET /work/ask: 最後に決まったこと・開いているもの（済みは出さない）")
    failed += say(first("見本の案件Ａ")["project_id"] == "wp-0000000a"
                  and first("みほんのあんけん b")["project_id"] == "wp-0000000b"
                  and first("ﾐﾎﾝﾉｱﾝｹﾝ B")["project_id"] == "wp-0000000b",
                  "GET /work/ask: 全角半角・かなカナ・大文字小文字・空白をそろえる")
    failed += say(first("さんぷるぷろじぇくと")["project_id"] == "wp-0000000a", "GET /work/ask: K1 の別名で引ける")
    t = s27pwork.ask(base, "＃２１２")["answers"]
    failed += say(t and t[0]["project_id"] == "wp-0000000a" and t[0]["last_decided"]["id"] == "d2"
                  and t[0]["open"][0]["id"] == "i1", "GET /work/ask: チケット番号（項目の文の中・#2120 とは分ける）")
    failed += say(first("#345")["project_id"] == "wp-0000000b", "GET /work/ask: チケット番号（K1 の会話の札）")
    p = s27pwork.ask(base, "みほんさん")["answers"]
    failed += say(p and p[0]["project_id"] is None and p[0]["link"] == "lifelog://work/person/wm-0000000c"
                  and p[0]["open"][0]["id"] == "h1" and {x["project_id"] for x in p[1:]} == {"wp-0000000a", "wp-0000000b"},
                  "GET /work/ask: 人の読みで引ける（その人の宿題と、その人の案件）")
    failed += say(first("見本氏") is not None and first("見本氏")["project_id"] is None, "GET /work/ask: 人の別名で引ける")
    failed += say(first("文言")["project_id"] == "wp-0000000a", "GET /work/ask: 項目の文でも引ける")
    failed += say(s27pwork.ask(base, "  ")["answers"] == [] and s27pwork.ask(base, "まったく無い言葉")["answers"] == [],
                  "GET /work/ask: 空・当たらなければ answers は空")
    failed += say(len(s27pwork.ask(base, "見本")["answers"]) <= s27pwork.ASK_MAX, f"GET /work/ask: {s27pwork.ASK_MAX} 件まで")
    f = Fake()
    s27pwork.http_get(f, "/work/ask", "q=%E8%A6%8B%E6%9C%AC%E3%81%AE%E6%A1%88%E4%BB%B6%20A", base)
    failed += say(f.sent[0] == 200 and f.sent[1]["answers"][0]["project_id"] == "wp-0000000a", "GET /work/ask?q=: 受け口")
    started = time.perf_counter()
    for _ in range(50):
        s27pwork.ask(base, "見本")
    took = (time.perf_counter() - started) / 50
    failed += say(took < 0.05, f"GET /work/ask: 引くための表を覚えておく（1 回 {took * 1000:.1f} ms）")
    return failed


def check_board() -> int:
    failed = 0
    base = TMP / "board"
    base.mkdir(parents=True, exist_ok=True)
    f = Fake()
    s27pwork.http_get(f, "/work-board", "", base)
    failed += say(f.status == 404 and ("Content-Type", "text/html; charset=utf-8") in f.head, "GET /work-board: 無ければ 404 の HTML")
    write(base / s27pwork.BOARD, "<!doctype html><title>仕事</title><p>見本の案件 A</p>")
    f = Fake()
    s27pwork.http_get(f, "/work-board", "", base)
    heads = dict(f.head)
    failed += say(f.status == 200 and "見本の案件 A" in f.wfile.getvalue().decode("utf-8")
                  and heads.get("Cache-Control") == "no-store" and "default-src 'none'" in heads.get("Content-Security-Policy", ""),
                  "GET /work-board: 母艦の HTML をそのまま（外を読みに行かない印つき）")
    write(base / s27pwork.CONFIG, {"s27p": {"board": False}})
    f = Fake()
    s27pwork.http_get(f, "/work-board", "", base)
    failed += say(f.status == 404, "GET /work-board: 切り替えで止められる")
    return failed


def check_feedback() -> int:
    failed = 0
    base = TMP / "feedback"
    base.mkdir(parents=True, exist_ok=True)
    logs: list[str] = []
    secret_text = "見本の数 消化 120 件 NG 3 件"
    good = [{"kind": "work_confirm", "id": "c1", "value": "merge"},
            {"kind": "work_edit", "id": "wm-0000000c", "value": json.dumps({"team": "見本の係", "org": "client"})},
            {"kind": "work_edit", "id": "wp-0000000a", "value": json.dumps({"kind": "other", "client": None})},
            {"kind": "work_numbers", "id": "wp-0000000a", "value": secret_text, "day": "2026-11-25"},
            {"kind": "work_numbers", "id": "", "value": "見本の数\n2 行目", "day": "2026-11-25"},
            {"kind": "work_notice", "id": "", "value": "見本のお知らせ", "day": "2026-11-25"},
            {"kind": "work_done", "id": "i1", "value": "done"},
            {"kind": "work_done", "id": "i1", "value": "undo", "day": "2026-11-25"}]
    for body in good:
        f = Fake(body)
        appfeeds.http_post_feedback(f, base, f.data, logs.append)
        failed += say(f.sent and f.sent[0] == 200, f"POST /feedback {body['kind']}: 受ける")
    rows = [json.loads(x) for x in (base / appfeeds.FEEDBACK_FILE).read_text(encoding="utf-8").splitlines()]
    failed += say(len(rows) == len(good) and all(r.get("at") and r.get("day") for r in rows)
                  and rows[3]["value"] == secret_text and rows[4]["value"] == "見本の数\n2 行目",
                  "POST /feedback: inbox/app_feedback.jsonl に 1 行ずつ（day は省けば今日）")
    failed += say(json.loads(rows[1]["value"]) == {"team": "見本の係", "org": "client"}, "work_edit: 直した欄だけの JSON の文字列")
    failed += say(not any("見本" in line or "merge" in line for line in logs) and all("work_" in line for line in logs),
                  "POST /feedback: 記録には kind だけ（中身は書かない）")
    bad = [{"kind": "work_confirm", "id": "bad id", "value": "merge"},
           {"kind": "work_confirm", "id": "c1", "value": ""},
           {"kind": "work_edit", "id": "wm-0000000c", "value": json.dumps({"client": "見本"})},
           {"kind": "work_edit", "id": "wp-0000000a", "value": json.dumps({"kind": "boss"})},
           {"kind": "work_edit", "id": "wm-0000000c", "value": json.dumps({"org": "friend"})},
           {"kind": "work_edit", "id": "wm-0000000c", "value": json.dumps({"name": None})},
           {"kind": "work_edit", "id": "x-1", "value": json.dumps({"name": "見本"})},
           {"kind": "work_edit", "id": "wm-0000000c", "value": "{壊れた"},
           {"kind": "work_edit", "id": "wm-0000000c", "value": "{}"},
           {"kind": "work_numbers", "id": "", "value": "x" * (s27pwork.VALUE_MAX["work_numbers"] + 1)},
           {"kind": "work_numbers", "id": "bad id", "value": "見本"},
           {"kind": "work_notice", "id": "wp-0000000a", "value": "見本"},
           {"kind": "work_notice", "id": "", "value": ""},
           {"kind": "work_done", "id": "i1", "value": "maybe"},
           {"kind": "work_done", "id": "i1", "value": "done", "day": "2026-13-40"},
           {"kind": "work_other", "id": "i1", "value": "done"}]
    before = len(rows)
    for body in bad:
        f = Fake(body)
        appfeeds.http_post_feedback(f, base, f.data, logs.append)
        failed += say(f.sent and f.sent[0] == 400, f"POST /feedback: おかしな答えは 400（{body['kind']} {str(body.get('value'))[:20]}）")
    after = len((base / appfeeds.FEEDBACK_FILE).read_text(encoding="utf-8").splitlines())
    failed += say(after == before, "POST /feedback: おかしな答えは置かない")
    # 今の kind は前と同じに受ける
    f = Fake({"kind": "undo", "id": "a1", "value": "undo", "day": "2026-11-25"})
    appfeeds.http_post_feedback(f, base, f.data, logs.append)
    failed += say(f.sent[0] == 200 and any(line.endswith("undo undo") for line in logs), "POST /feedback: 前からの kind は今のまま")
    return failed


def check_hub() -> int:
    """lifelog_pc.py へのつなぎ（/hello の features と GET の道）"""
    failed = 0
    text = (Path(__file__).resolve().parent / "lifelog_pc.py").read_text(encoding="utf-8")
    failed += say("import s27pwork" in text and "s27pwork.FEATURES" in text and "path in s27pwork.GETS" in text
                  and "s27pwork.http_get(self, path, url.query, mothership.home(load_config()))" in text,
                  "lifelog_pc.py: features と GET の道につないである（合言葉を確かめてから）")
    block = text[text.index("path in s27pwork.GETS"):][:300]
    failed += say("self.authorized()" in block, "lifelog_pc.py: /work の口はオーナーの鍵の後ろ")
    failed += say(set(s27pwork.FEATURES) == {"work", "workconfirm", "workask", "workboard"}
                  and set(s27pwork.GETS) == {"/work", "/work/confirm", "/work/ask", "/work-board"}, "K5 の名前")
    import mothership

    failed += say(not set(s27pwork.GETS) & set(mothership.GETS), "ほかの口と道の名前がぶつからない")
    return failed


CHECKS = [check_work, check_confirm, check_ask, check_board, check_feedback, check_hub]


def run_all() -> int:
    failed = 0
    for check in CHECKS:
        try:
            failed += check()
        except Exception as error:  # noqa: BLE001 — 1 つが落ちても、ほかは確かめる
            import traceback

            traceback.print_exc()
            failed += say(False, f"{check.__name__} が途中で落ちました: {error!r}")
    import v28checks_sub   # 2026-11-26 定額の枠（CI の手順は増やさない）
    failed += v28checks_sub.run_all()
    return failed


def main() -> int:
    failed = run_all()
    print("ぜんぶ OK" if not failed else f"NG の数: {failed}", flush=True)
    return failed


if __name__ == "__main__":
    sys.exit(main())
