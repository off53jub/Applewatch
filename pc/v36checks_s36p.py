"""2026-11-28（s36。担当 p）: 家の PC の s36 の分を確かめる。

    python pc/v36checks_s36p.py          （v35checks_s35p.py の最後にも呼ばれる。CI の手順を増やさずに動かすため）

- K36-1 GET /s36（features "s36"）
- K36-2 POST /work/photo の kind と 30 枚（features "workphoto30"）
- K36-3 POST /s36/stop（features "s36stop"）
- K36-4 /ask-mothership の scope（features "askwork"）

本物の HOME・母艦・iPhone・Claude は使わない（一時フォルダに作りものの母艦。見本は「見本の案件 A」「見本さん」「W-001」だけ）。
"""

from __future__ import annotations

import base64
import datetime
import io
import json
import os
import sys
import tempfile
import threading
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent))

if not any(mark in os.environ.get("LOCALAPPDATA", "")
           for mark in ("v25s", "v26s", "v27s", "v30s", "v31s", "v32s", "v33s", "v34s", "v35s", "v36s")):
    os.environ["LOCALAPPDATA"] = str(Path(tempfile.mkdtemp(prefix="v36s-local-")))

import askmother  # noqa: E402
import claude  # noqa: E402
import s30pwork  # noqa: E402
import s35pwork  # noqa: E402
import s36pwork  # noqa: E402
from v6checks import say  # noqa: E402

TMP = Path(tempfile.mkdtemp(prefix="v36s-"))
KEY = "check-key"


class Fake:
    """受け口の作り物"""

    def __init__(self, body=b"") -> None:
        data = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.rfile = io.BytesIO(data)
        self.headers = {"Content-Length": str(len(data))}
        self.sent: list = []
        self.discarded = False
        self.client_address = ("127.0.0.1", 0)

    def send_json(self, status: int, body) -> None:
        self.sent = [status, body]

    def discard_body(self) -> None:
        self.discarded = True


class Spawns:
    def __init__(self) -> None:
        self.calls: list = []

    def __call__(self, script, python, base) -> None:
        self.calls.append((Path(script), Path(python), Path(base)))


def reset(spawns: Spawns | None) -> None:
    s30pwork.SPAWN = spawns
    s30pwork._last_kick[0] = float("-inf")


def mother(name: str) -> Path:
    base = TMP / name
    (base / "scripts").mkdir(parents=True)
    (base / "state").mkdir()
    (base / "scripts" / "Run-WorkNow.py").write_text("# 見本\n", encoding="utf-8")
    (base / "scripts" / "Search-Lifelog.py").write_text("# 見本\n", encoding="utf-8")
    return base


def put(base: Path, rel: str, data) -> None:
    path = base / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")


S36_SAMPLE = {
    "version": 1, "generated_at": "2026-11-28T08:00:00+09:00",
    "prompt": {"setup": "見本の頼み方", "setup_version": "20261128-1", "daily": "まとめ W-001",
               "open_refs": [{"ref": "W-001", "text": "見本の案件 A の見本の宿題"}]},
    "cases": {"as_of": "2026-11-28", "total": 120, "done": 80, "ng": 5, "waiting": 3, "left": 32, "per_day": 8.0,
              "eta": "2026-12-03", "eta_note": "見込みは仮", "evidence_missing": [{"ref": "W-001", "text": "見本のケースの画面の写し"}],
              "by_area": [{"area": "見本の範囲", "total": 40, "done": 30}]},
    "bugs": {"as_of": "2026-11-28", "open": 2, "closed": 7,
             "items": [{"ref": "W-001", "text": "見本の不具合の画面が出ない", "state": "対応中", "who": "見本さん", "day": "2026-11-27"}]},
    "ledger": {"open": 3, "closed_7d": 1, "folded": 0, "closed_by_reply_7d": 0},
    "stop": None, "nav": None,
}


# MARK: - K36-1 GET /s36


def check_s36_get() -> int:
    failed = 0
    base = mother("s36get")
    f = Fake()
    s36pwork.http_get(f, "/s36", "", base)
    failed += say(f.sent[0] == 200 and f.sent[1].get("available") is False and "まだ" in f.sent[1].get("reason", ""),
                  f"GET /s36: ファイルが無ければ「まだ」の返事 {f.sent}")
    failed += say(s36pwork.FEATURE not in s36pwork.features(base), "ファイルが無ければ features に s36 を出さない")
    put(base, "state/s36_for_app.json", S36_SAMPLE)
    f = Fake()
    s36pwork.http_get(f, "/s36", "", base)
    failed += say(f.sent == [200, S36_SAMPLE], "GET /s36: 母艦の s36_for_app.json をそのまま返す")
    failed += say(s36pwork.features(base) == ["s36", "s36stop"], f"features に s36・s36stop {s36pwork.features(base)}")
    (base / "state" / "s36_for_app.json").write_text("{壊れ", encoding="utf-8")
    f = Fake()
    s36pwork.http_get(f, "/s36", "", base)
    failed += say(f.sent[1].get("available") is False and "形" in f.sent[1].get("reason", ""), "壊れていれば available false")
    put(base, "state/s36_for_app.json", S36_SAMPLE)
    put(base, "state/s27_work_config.json", {"s36p": {"s36": False}})
    f = Fake()
    s36pwork.http_get(f, "/s36", "", base)
    failed += say(f.sent[1] == {"available": False, "reason": "止めてあります"} and s36pwork.features(base) == ["s36stop"],
                  "止める切り替え（s36p の s36 false）: 返さず features から外す（s36stop は別）")
    f = Fake()
    s36pwork.http_get(f, "/s36", "", None)
    failed += say(f.sent[1].get("available") is False and s36pwork.features(None) == []
                  and s36pwork.features(TMP / "nowhere") == [], "母艦が無ければ available false・features なし")
    return failed


# MARK: - K36-2 POST /work/photo の kind と 30 枚


def jpeg(n: int = 0) -> bytes:
    return b"\xff\xd8\xff\xe0" + bytes([n % 256]) * 32 + b"\xff\xd9"


def photo(ident: str, index: int, count: int, **more) -> dict:
    row = {"id": ident, "day": "2026-11-28", "index": index, "count": count,
           "jpeg_b64": base64.b64encode(jpeg(index)).decode("ascii")}
    row.update(more)
    return row


def post_photo(base: Path, body) -> tuple:
    f = Fake(body)
    s35pwork.http_post(f, "/work/photo", {"mothership_python": str(Path(sys.executable))}, base, None)
    return f.sent


def check_photo_kind() -> int:
    failed = 0
    base = mother("photokind")
    spawns = Spawns()
    reset(spawns)
    plain = str(uuid.uuid4())
    st, reply = post_photo(base, photo(plain, 0, 1))
    meta = json.loads((base / s35pwork.INBOX / plain / "meta.json").read_text(encoding="utf-8"))
    failed += say(st == 200 and reply["run"] == "started" and meta.get("kind") == "digest",
                  f"kind を省けば digest として meta.json に残す {meta}")
    reset(spawns)
    table = str(uuid.uuid4())
    for i in range(30):
        st, reply = post_photo(base, photo(table, i, 30, kind="cases"))
        if st != 200:
            break
    meta = json.loads((base / s35pwork.INBOX / table / "meta.json").read_text(encoding="utf-8"))
    failed += say(st == 200 and reply == {"ok": True, "have": 30, "count": 30, "run": "started"}
                  and meta.get("kind") == "cases" and meta.get("received") == list(range(30)),
                  f"cases の表 30 枚: 受けて、そろったら同じ起こし方 {reply}")
    failed += say(len(spawns.calls) == 2 and spawns.calls[-1][0] == base / s30pwork.SCRIPT,
                  "cases でも Run-WorkNow.py を起こす（--kick は s30pwork の起こし方のまま）")
    reset(spawns)
    bugs = str(uuid.uuid4())
    st, reply = post_photo(base, photo(bugs, 0, 2, kind="bugs"))
    failed += say(st == 200 and reply["run"] == "waiting", "bugs の一覧も受ける（そろうまで waiting）")
    st, reply = post_photo(base, photo(bugs, 0, 2, kind="cases"))
    meta = json.loads((base / s35pwork.INBOX / bugs / "meta.json").read_text(encoding="utf-8"))
    failed += say(reply["have"] == 1 and meta.get("kind") == "cases", "同じ id で kind が変われば新しい組として数え直す")
    for label, body in {"count が 31": photo(str(uuid.uuid4()), 0, 31), "kind が違う": photo(str(uuid.uuid4()), 0, 1, kind="memo"),
                        "kind が数": photo(str(uuid.uuid4()), 0, 1, kind=1)}.items():
        st, reply = post_photo(base, body)
        failed += say(st == 400 and "error" in reply, f"検め: {label} は 400")
    st, reply = post_photo(base, photo(str(uuid.uuid4()), 29, 30, kind="digest"))
    failed += say(st == 200 and reply["count"] == 30, "検め: index 29（count 30）は受ける")
    failed += say(s35pwork.features(base) == ["workphoto", "workphoto30"], "features に workphoto30（workphoto と同じ決まり）")
    return failed


# MARK: - K36-3 POST /s36/stop


def post_stop(base: Path | None, body, logs: list | None = None) -> tuple:
    f = Fake(body)
    s36pwork.http_post(f, "/s36/stop", base, (logs.append if logs is not None else None))
    return f.sent


def check_stop() -> int:
    failed = 0
    base = mother("stop")
    logs: list = []
    st, reply = post_stop(base, {"id": "build:見本の作り直し", "choice": "stop"}, logs)
    files = sorted((base / s36pwork.STOP_INBOX).glob("*.json"))
    failed += say(st == 200 and reply == {"ok": True} and len(files) == 1, f"stop を 1 件置く {reply}")
    data = json.loads(files[0].read_text(encoding="utf-8")) if files else {}
    failed += say(data.get("id") == "build:見本の作り直し" and data.get("choice") == "stop" and isinstance(data.get("at"), str),
                  f"中身は id・choice・at {data}")
    name = files[0].name if files else ""
    failed += say(name.endswith("-build.json") and name[:8].isdigit(), f"名前は <時刻>-<id の安全な形>.json（{name}）")
    st, reply = post_stop(base, {"id": "../../見本", "choice": "keep"})
    files = sorted((base / s36pwork.STOP_INBOX).glob("*.json"))
    failed += say(st == 200 and len(files) == 2 and all(f.parent == base / s36pwork.STOP_INBOX for f in files)
                  and not list(base.glob("*.json")), "../ を含む id でも inbox/s36_stop の中にだけ置く")
    failed += say(s36pwork.safe_id("../../x") == "x" and s36pwork.safe_id("見本") == "x" and s36pwork.safe_id("a b/c") == "a_b_c",
                  "安全な形: 英数字・_・- だけ（無ければ x）")
    for _ in range(2):
        post_stop(base, {"id": "same", "choice": "stop"})
    failed += say(len(list((base / s36pwork.STOP_INBOX).glob("*.json"))) == 4, "同じ時刻・同じ id でも上書きしない")
    failed += say(not list((base / s36pwork.STOP_INBOX).glob(".*")), "一時ファイルが残らない")
    bad = {"並び": [{"id": "x", "choice": "stop"}], "id が無い": {"choice": "stop"}, "id が空": {"id": " ", "choice": "stop"},
           "id が 81 字": {"id": "a" * 81, "choice": "stop"}, "id が数": {"id": 3, "choice": "stop"},
           "id に改行": {"id": "a\nb", "choice": "stop"}, "choice が違う": {"id": "x", "choice": "delete"},
           "choice が無い": {"id": "x"}}
    before = len(list((base / s36pwork.STOP_INBOX).glob("*.json")))
    for label, body in bad.items():
        st, reply = post_stop(base, body)
        failed += say(st == 400 and "error" in reply, f"検め: {label} は 400")
    st, reply = post_stop(base, {"id": "a" * 80, "choice": "keep"})
    failed += say(st == 200, "検め: id はちょうど 80 字まで受ける")
    failed += say(len(list((base / s36pwork.STOP_INBOX).glob("*.json"))) == before + 1, "断ったときは何も書かない")
    f = Fake(b"x")
    f.headers["Content-Length"] = str(s36pwork.STOP_BODY_MAX + 1)
    s36pwork.http_post(f, "/s36/stop", base)
    failed += say(f.sent[0] == 413 and f.discarded, "体が大きすぎれば 413（読まずに断る）")
    f = Fake(b"{broken")
    s36pwork.http_post(f, "/s36/stop", base)
    failed += say(f.sent[0] == 400, "壊れた JSON は 400")
    joined = "\n".join(logs)
    failed += say(bool(logs) and "見本の作り直し" not in joined and "build" not in joined, "記録に id を書かない（choice と数だけ）")
    off = mother("stopoff")
    put(off, "state/s27_work_config.json", {"s36p": {"stop": False}})
    st, reply = post_stop(off, {"id": "x", "choice": "stop"})
    failed += say(st == 200 and reply.get("ok") is False and not (off / s36pwork.STOP_INBOX).exists()
                  and "s36stop" not in s36pwork.features(off), "止める切り替え（s36p の stop false）: 書かず ok false")
    st, reply = post_stop(None, {"id": "x", "choice": "stop"})
    failed += say(st == 200 and reply.get("ok") is False, "母艦が無ければ ok false")
    return failed


# MARK: - K36-4 /ask-mothership の scope


def work_mother() -> Path:
    base = mother("askwork")
    put(base, "state/s25l_work_ledger.json", {"version": 1, "items": [
        {"id": "a1", "ref": "W-001", "day": "2026-11-26", "kind": "homework", "case": "見本の案件 A",
         "text": "見本の資料を見本さんに送る", "who": "見本さん", "source": "仕事のまとめ（見本）"},
        {"id": "a2", "day": "2026-11-25", "kind": "decided", "case": "見本の案件 A", "text": "見本の定例で見本の手順に決まった",
         "who": None, "source": "PLAUD「見本の定例」"},
        {"id": "a3", "day": "2026-11-24", "kind": "open", "text": "見本の重なった話", "merged_into": "a1",
         "source": "仕事のまとめ（見本）"},
    ]})
    put(base, "state/work_for_app.json", {"version": 1, "today": {"waiting_on_others": [
        {"id": "w-1", "kind": "open", "text": "見本の確認の返事を待っている", "project_id": "wp-a", "day": "2026-11-27",
         "time": "10:05", "who": None, "who_guess": "見本さん", "src": "lifelog-pc 2026-11-27 10:05"}]},
        "projects": [{"id": "wp-a", "name": "見本の案件 A", "items": [
            {"id": "w-2", "kind": "homework", "text": "見本の資料を見本さんに送る", "day": "2026-11-26", "src": "仕事のまとめ（見本）"}]}],
        "decisions": [{"id": "d-1", "day": "2026-11-25", "text": "見本の手順は来週から", "who": "見本さん"}]})
    put(base, "state/s32_work_items.json", {"version": 1, "days": {"2026-11-26": [
        {"text": "見本の資料を見本さんに送る", "at": "11:30", "who": "見本さん"}]}})
    put(base, "state/s36_for_app.json", S36_SAMPLE)
    return base


class FakeLedger:
    def __init__(self, n: int) -> None:
        self.n = n

    def day_calls(self, day: str, purpose: str) -> int:
        return self.n if purpose == askmother.WORK_ANSWER_PURPOSE else 0


def check_ask_work() -> int:
    failed = 0
    base = work_mother()
    failed += say(askmother.parse_scope(b'{"question":"x"}') == "all" and askmother.parse_scope(b'{"scope":"work"}') == "work",
                  "scope を省けば all・work は work")
    try:
        askmother.parse_scope(b'{"scope":"home"}')
        failed += say(False, "scope が違えば ValueError")
    except ValueError:
        failed += say(True, "scope が違えば ValueError（400）")
    hits = askmother.work_hits(base, "見本の資料は誰待ち？", ["見本の資料"])  # 探し方の言葉（ask では Claude が作る）
    failed += say(hits and hits[0]["text"].endswith("見本の資料を見本さんに送る") and hits[0]["who"] == "見本さん",
                  f"言葉の重なりで仕事の材料を選ぶ（台帳と K2 の同じ文は 1 つ）{[h['source'] for h in hits]}")
    texts = [h["text"] for h in hits]
    failed += say(sum(t.endswith("見本の資料を見本さんに送る") for t in texts) == 1 and not any("重なった話" in t for t in texts),
                  "同じ文は 1 つ・merged_into の項目は渡さない")
    first = hits[0] if hits else {}
    failed += say(first.get("via") == "summary" and first.get("ref") == "W-001" and first.get("day") == "2026-11-26"
                  and first.get("time") == "11:30", f"出どころ: 日・時刻（s32 の項目から）・だれ・まとめ・番号 {first}")
    waiting = [h for h in hits if "返事を待って" in h["text"]]
    failed += say(waiting and waiting[0]["via"] == "voice" and waiting[0]["who_guess"] == "見本さん" and not waiting[0]["who"],
                  "「待ち」の質問で待っている項目を拾う・声の出どころは voice・推定の人は who_guess（who にしない）")
    tests = askmother.work_hits(base, "テストの残りと見込みは？")
    failed += say(tests and tests[0]["source"] == "work-cases" and "残り 32" in tests[0]["text"] and tests[0]["via"] == "table",
                  f"テストの質問で cases の進みを先に {tests[:1]}")
    bugs = askmother.work_hits(base, "不具合はいくつ？")
    failed += say(any(h["source"] == "work-bugs" and h.get("who") == "見本さん" for h in bugs), "不具合の質問で bugs の項目")
    ranged = askmother.work_hits(base, "見本の資料", frm="2026-11-27", to="2026-11-28")
    failed += say(all(not h["day"] or h["day"] >= "2026-11-27" for h in ranged), "期間があれば期間の外の項目は渡さない")
    failed += say(askmother.work_hits(TMP / "nowhere", "見本") == [], "母艦の材料が無ければ空")
    failed += say(askmother.via_of("lifelog-pc 2026-11-27 10:05") == "voice" and askmother.via_of("仕事のまとめ（x）") == "summary"
                  and askmother.via_of("頼まれごと帳（議事録から）") == "voice" and askmother.via_of(None) == "other",
                  "まとめか声か の見分け")

    # ask の流れ（Claude は作り物）
    calls: list[dict] = []

    def fake_call(system, prompt, **kwargs):
        calls.append({"system": system, "prompt": prompt, **kwargs})
        if kwargs.get("tier") == "light":
            return {"data": {"queries": [{"words": ["見本の資料"], "sources": [], "from": "", "to": ""}], "money": False,
                             "money_words": [], "topics": [], "lookups": []}}
        return {"data": {"answer": "11/26 に見本さんへ（仕事のまとめ）[1]", "used": [1], "found": True}}

    saved = (askmother.claude.call, askmother.RUN, askmother.SEMANTIC, askmother.claude.LEDGER)
    try:
        askmother.claude.call = fake_call
        askmother.RUN = lambda args, **kwargs: SimpleNamespace(stdout=b"", returncode=0)
        askmother.SEMANTIC = None
        askmother.claude.LEDGER = FakeLedger(0)
        config = {"lifelog_home": str(base), "mothership_python": "py.exe"}
        got = askmother.ask("見本の資料は誰待ち？", config, today=datetime.date(2026, 11, 28), scope="work")
        prompt = json.loads(calls[-1]["prompt"])
        failed += say([c["purpose"] for c in calls] == [askmother.WORK_PLAN_PURPOSE, askmother.WORK_ANSWER_PURPOSE]
                      and all(c["purpose"].startswith("askmother") for c in calls),
                      "仕事の質問の purpose は askmother の前方一致の中（askmother.s36-work.*）")
        failed += say(prompt["snippets"] and prompt["snippets"][0]["source"].startswith("work-")
                      and prompt["snippets"][0].get("who") == "見本さん" and prompt["snippets"][0].get("via") == "summary",
                      "仕事の材料を先に（いちばん前に）Claude へ・だれと出どころも渡す")
        failed += say("まとめか声か" in calls[-1]["system"] and "まとめか声か" not in askmother.ANSWER_SYSTEM,
                      "仕事のときだけ、答えに 日・だれ・まとめか声か を添える決まりを足す")
        src = got["sources"][0] if got.get("sources") else {}
        failed += say(set(src) >= {"n", "day", "time", "source", "label", "text"} and src.get("who") == "見本さん"
                      and src.get("via") == "summary" and src.get("ref") == "W-001" and src.get("label") == "仕事の台帳",
                      f"返事の形は今のまま・who・via・ref を足すだけ {src}")
        failed += say(got["searched"].get("scope") == "work" and got["searched"].get("work", 0) >= 1, "searched に scope と work の数")
        calls.clear()
        got = askmother.ask("見本の資料は誰待ち？", config, today=datetime.date(2026, 11, 28))
        prompt = json.loads(calls[-1]["prompt"]) if len(calls) > 1 else {"snippets": []}
        failed += say([c["purpose"] for c in calls] in ([askmother.PLAN_PURPOSE], [askmother.PLAN_PURPOSE, askmother.ANSWER_PURPOSE])
                      and not any(s["source"].startswith("work-") for s in prompt["snippets"])
                      and "scope" not in got["searched"], "scope を省けば今のまま（仕事の材料は引かない・purpose も今のまま）")
        askmother.claude.LEDGER = FakeLedger(askmother.WORK_DAILY_MAX)
        calls.clear()
        try:
            askmother.ask("見本", config, scope="work")
            failed += say(False, "1 日の上限に届いたら 409")
        except claude.ClaudeError as error:
            failed += say(error.status == claude.PURPOSE_OFF and error.body.get("purpose_off") == "daily_cap" and not calls,
                          f"仕事の質問は 1 日 {askmother.WORK_DAILY_MAX} 回（仮）まで・超えたら頼まずに 409")
        # 受け口: 記録には数だけ
        askmother.claude.LEDGER = FakeLedger(0)
        logs: list = []
        f = Fake({"question": "見本の資料は誰待ち？", "scope": "work"})
        askmother.http_post(f, config, logs.append)
        joined = "\n".join(logs)
        failed += say(f.sent[0] == 200 and "（仕事）" in joined and "見本" not in joined, f"記録には数だけ（中身を書かない）{logs}")
        f = Fake({"question": "見本", "scope": "office"})
        askmother.http_post(f, config, logs.append)
        failed += say(f.sent[0] == 400, "scope が違えば 400")
    finally:
        askmother.claude.call, askmother.RUN, askmother.SEMANTIC, askmother.claude.LEDGER = saved
    saved_available = askmother.available
    try:
        askmother.available = lambda config: True
        on = askmother.features({})
        askmother.available = lambda config: False
        off = askmother.features({})
    finally:
        askmother.available = saved_available
    failed += say(on == ["askmother", "askwork"] and off == [], "features に askwork（askmother と同じ決まり）")
    return failed


# MARK: - 本物の受け口


def check_http() -> int:
    failed = 0
    try:
        import lifelog_pc as main
    except Exception as error:  # noqa: BLE001
        print(f"SKIP  lifelog_pc を読み込めないので HTTP の確かめを飛ばす: {type(error).__name__}: {error}", flush=True)
        return failed
    base = mother("http")
    put(base, "state/s36_for_app.json", S36_SAMPLE)
    reset(Spawns())
    saved = (getattr(main.Handler, "key", None), main.log, main.load_config)
    had_engine = hasattr(main.Handler, "engine")
    server = None
    try:
        main.Handler.key = KEY
        if not had_engine:
            main.Handler.engine = type("FakeEngine", (), {"label": "check", "provider": "check", "engines": []})()
        main.log = lambda message: None
        main.load_config = lambda: {"lifelog_home": str(base), "mothership_python": str(Path(sys.executable))}
        server = main.Server(("127.0.0.1", 0), main.Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        port = server.server_address[1]

        def call(method: str, path: str, body=None, key: str | None = KEY) -> tuple[int, dict]:
            data = json.dumps(body).encode("utf-8") if body is not None else None
            req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data, method=method)
            if data is not None:
                req.add_header("Content-Type", "application/json")
            if key is not None:
                req.add_header("Authorization", f"Bearer {key}")
            try:
                with urllib.request.urlopen(req, timeout=10) as r:
                    return r.status, json.loads(r.read().decode("utf-8"))
            except urllib.error.HTTPError as error:
                return error.code, json.loads(error.read().decode("utf-8") or "{}")

        for key in (None, "wrong"):
            st, _ = call("GET", "/s36", key=key)
            failed += say(st == 401, f"GET /s36: 鍵が{'無い' if key is None else '違う'}と 401")
            st, _ = call("POST", "/s36/stop", {"id": "x", "choice": "stop"}, key)
            failed += say(st == 401, f"POST /s36/stop: 鍵が{'無い' if key is None else '違う'}と 401")
        failed += say(not (base / s36pwork.STOP_INBOX).exists(), "401 のときは書かない")
        st, reply = call("GET", "/s36")
        failed += say(st == 200 and reply == S36_SAMPLE, "GET /s36: 鍵が合えば返す")
        st, reply = call("POST", "/s36/stop", {"id": "notice:見本", "choice": "keep"})
        failed += say(st == 200 and reply == {"ok": True} and len(list((base / s36pwork.STOP_INBOX).glob("*.json"))) == 1,
                      "POST /s36/stop: 鍵が合えば置く")
        st, reply = call("POST", "/work/photo", photo(str(uuid.uuid4()), 0, 1, kind="bugs"))
        failed += say(st == 200 and reply.get("run") == "started", "POST /work/photo: kind bugs を受ける")
        st, reply = call("GET", "/hello")
        got = set(reply.get("features") or [])
        failed += say(st == 200 and {"s36", "s36stop", "workphoto30", "workphoto"} <= got, f"features に s36・s36stop・workphoto30")
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
    hub = (Path(__file__).resolve().parent / "lifelog_pc.py").read_text(encoding="utf-8")
    failed += say("import s36pwork" in hub and "s36pwork.features(mothership.home(load_config()))" in hub
                  and "path in s36pwork.GETS" in hub and "url.path in s36pwork.POSTS" in hub, "lifelog_pc.py: features・GET・POST につないである")
    for marker in ("path in s36pwork.GETS", "url.path in s36pwork.POSTS"):
        failed += say("self.authorized()" in hub[hub.index(marker):][:200], f"lifelog_pc.py: {marker} はオーナーの鍵の後ろ")
    import mothership
    import s34pwork

    paths = set(mothership.POSTS) | set(s30pwork.POSTS) | set(s35pwork.POSTS) | set(askmother.POSTS)
    failed += say(not set(s36pwork.POSTS) & paths and not set(s36pwork.GETS) & set(s34pwork.GETS), "ほかの口と道の名前がぶつからない")
    return failed


CHECKS = [check_s36_get, check_photo_kind, check_stop, check_ask_work, check_http, check_hub]


def run_all() -> int:
    failed = 0
    for check in CHECKS:
        try:
            failed += check()
        except Exception as error:  # noqa: BLE001 — 1 つが落ちても、ほかは確かめる
            import traceback

            traceback.print_exc()
            failed += say(False, f"{check.__name__} が途中で落ちました: {error!r}")
    # s37（2026-11-28。担当 v）の確かめも続けて（CI の手順を増やさないため）
    import v37checks_s37v

    failed += v37checks_s37v.run_all()
    return failed


def main() -> int:
    failed = run_all()
    print("ぜんぶ OK" if not failed else f"NG の数: {failed}", flush=True)
    return failed


if __name__ == "__main__":
    sys.exit(main())
