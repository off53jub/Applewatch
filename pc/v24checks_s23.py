"""2026-11-23（s23。担当 P）: 家の PC の分を確かめる（続1〜続4・続8・続10・試4・届7・止1/続5 の受け口）。

    python pc/v24checks_s23.py          （v24checks_s22.py の最後にも呼ばれる。CI の手順を増やさずに動かすため）

本物の HOME・母艦・iPhone は使わない（一時フォルダに作り物を作る。人の名前は「甲」「乙」などの記号だけ）。確かめること（check_*）:
- 続8 s23text・diag: 生の英語のエラーを日本語の 1 行に・英語の日付・12792 分のような数・改行の JSON をつぶす・日本語はそのまま
- 続1 s23voice: 時計の声だけの答えのある組・2 つの声の問い（同じ人物N／違う話し手・clips）・点と AUC
- 続10 s23voice: s-norm の答え合わせ（組が少なければ null）
- 続4 s23gaps: 抜けの段（録れていない・声が無い（見立て）・文字にならなかった・記録で落とした・分からない）
- 届7 s23gaps・s23pc: 版ごとの録れた時間・3 割以上減ったら気になる所に 1 行
- 止1 s23gaps: phoneResume*・watchResume* の 3 日の並び（名前が決まっていなくても出す）
- 続3 s23gold: 騒がしさ・場面の印・20 個までの候補・答えを正解集の材料に（origin pc-noisy-gold）
- 続5 s23pc: POST /headcount の形・s22 確6 の人数に足す（母艦が無くても）
- 試4 s23pc: 新しい版で 1 回だけ 7 つを確かめる（記録は変えない）・GET /s23/checks
- 続2 s23measure: 多数決の組み合わせと CER（作り物の vote）・夜の枠の外では何もしない
- summary.md の「s23 の数」の節が書けること
"""

from __future__ import annotations

import datetime
import io
import json
import os
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent))

if "v24s" not in os.environ.get("LOCALAPPDATA", ""):  # 単独で動かすときも、本物の HOME に触れない
    os.environ["LOCALAPPDATA"] = str(Path(tempfile.mkdtemp(prefix="v24s23-local-")))

import numpy as np  # noqa: E402

import appfeeds  # noqa: E402
import diag  # noqa: E402
import quality  # noqa: E402
import s20feeds  # noqa: E402
import s22voice  # noqa: E402
import s23gaps  # noqa: E402
import s23gold  # noqa: E402
import s23measure  # noqa: E402
import s23pc  # noqa: E402
import s23text  # noqa: E402
import s23voice  # noqa: E402
from v6checks import say  # noqa: E402

TMP = Path(tempfile.mkdtemp(prefix="v24s23-"))
LOGS: list[str] = []


class Fake:
    client_address = ("127.0.0.1", 0)

    def __init__(self, body=b"") -> None:
        data = json.dumps(body).encode() if not isinstance(body, bytes) else body
        self.rfile = io.BytesIO(data)
        self.headers = {"Content-Length": str(len(data))}
        self.wfile = io.BytesIO()
        self.sent: list = []

    def send_json(self, status: int, body) -> None:
        self.sent = [status, body]

    def discard_body(self) -> None:
        pass


def ms(y, mo, d, h=0, mi=0, s=0) -> int:
    return int(datetime.datetime(y, mo, d, h, mi, s).timestamp() * 1000)


def write(path: Path, body) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(body, ensure_ascii=False), encoding="utf-8")


# MARK: - 続8


def check_text() -> int:
    failed = 0
    tls = s23text.tidy("ドキュメントに書けませんでした（あとで再試行します）: Connection error making token request to "
                       "'https://example.invalid/token': A TLS error caused the secure connection to fail..")
    failed += say(tls.startswith("ドキュメントに書けませんでした") and "TLS" in tls and "Connection error" not in tls
                  and "https" not in tls, f"続8: TLS の英語のエラーは日本語の 1 行に（{tls}）")
    quota = s23text.tidy('名前を直せませんでした: Google API エラー 429: {\n  "error": {\n    "code": 429,\n    "message": "Quota exceeded for x')
    failed += say("\n" not in quota and "上限" in quota and "Quota" not in quota and "{" not in quota,
                  f"続8: 429 の JSON は改行をつぶして「上限」の 1 行に（{quota}）")
    failed += say(s23text.tidy("頼まれごと帳を書けませんでした: cancelled").endswith("途中で取りやめになりました（アプリが閉じたなど）"),
                  "続8: 短い英語（cancelled）も日本語に")
    failed += say(s23text.tidy("ドキュメントの名前を直せませんでした: The network connection was lost.").endswith("通信がつながりませんでした"),
                  "続8: つながらない英語を日本語に")
    failed += say(s23text.tidy("書き込みが多すぎた 2 回（最後は Nov 22, 2026 at 3:32 PM）") == "書き込みが多すぎた 2 回（最後は 11/22 15:32）",
                  "続8: 英語の日付を 11/22 15:32 に")
    nums = s23text.tidy("録れた 12792 分・合計 1536 秒・待ち 0.0 秒・ふつう 3.7 分・行 123456 行・版 386・16.0MB・11/23 21:33")
    failed += say(nums == "録れた 約 8.9 日・合計 約 26 分・待ち 0 秒・ふつう 3.7 分・行 123,456 行・版 386・16.0MB・11/23 21:33",
                  f"続8: 読みにくい数だけを直す（版・大きさ・時刻はそのまま）（{nums}）")
    failed += say(s23text.tidy("groq に接続できませんでした") == "groq に接続できませんでした" and s23text.tidy(None) == "—",
                  "続8: 日本語の文はそのまま")
    odd = s23text.friendly_error("失敗: Something strange happened inside the widget factory")
    failed += say(odd.startswith("失敗: 英語のエラー") and len(odd) < 90, f"続8: 知らない英語は「英語のエラー」と頭だけ（{odd}）")
    failed += say(diag._secs(0.0) == "0 秒" and diag._secs(5.1) == "5.1 秒" and diag._secs(700) == "11.7 分"
                  and diag._secs(46094) == "約 12.8 時間" and diag._secs(12792 * 60) == "約 8.9 日",
                  "続8: diag の長さ（0 秒・分・約 X 時間・約 X 日）")
    record = {"receivedAt": diag.iso(1_800_000_000.0), "rows": [{"ok": False, "group": "最近のエラー", "name": "11/23",
                                                                  "value": "書けませんでした: The network connection was lost."}]}
    got = diag.concerns(record, 1_800_000_000.0)
    failed += say(any(line.endswith("通信がつながりませんでした") for line in got),
                  "続8: summary.md の「気になる所」の自己点検の行も日本語に（元の latest.json は変えない）")
    return failed


# MARK: - 続1・続10


def sample(audio, start, end):
    return {"audio": audio, "start": start, "end": end, "time": "2026-11-20T01:00:00.000Z", "text": "見本"}


def make_home_with_groups(home: Path, base: Path) -> None:
    write(home / "same-person" / "2026-11-20.json", {"groups": [
        {"id": "sp-a", "score": 0.8, "people": [{"samples": [sample("20261120-100000-w.m4a", 1, 4)]},
                                                {"samples": [sample("20261120-101000-w.m4a", 2, 6)]}]},
        {"id": "sp-b", "score": 0.2, "people": [{"samples": [sample("20261120-100000-w.m4a", 5, 8)]},
                                                {"samples": [sample("20261120-102000.m4a", 2, 6)]}]},   # iPhone の声が混ざる
        {"id": "sp-c", "score": 0.1, "people": [{"samples": [sample("20261120-103000-w.m4a", 1, 4)]},
                                                {"samples": [sample("20261120-104000-w.m4a", 1, 5)]}]}]})
    write(home / "same-person" / "voices.json", {"across": [], "maybe": [
        {"id": "sx-m", "day": "2026-11-21", "score": 0.6, "person": {"samples": [sample("20261121-100000-w.m4a", 1, 4)]},
         "named": {"samples": [sample("20261121-110000-w.m4a", 1, 4)]}}]})
    rows = [{"kind": "same_person", "id": "sp-a", "value": "merged"}, {"kind": "same_person", "id": "sp-b", "value": "different"},
            {"kind": "same_person", "id": "sp-c", "value": "different"}, {"kind": "same_person", "id": "sx-m", "value": "merged"},
            {"kind": "review", "id": "h-other", "answer": "yes"}]
    (base / "inbox").mkdir(parents=True, exist_ok=True)
    (base / "inbox" / "app_feedback.jsonl").write_text("\n".join(json.dumps(r) for r in rows) + "\n", encoding="utf-8")


def check_voice() -> int:
    failed = 0
    home, base = TMP / "voice-home", TMP / "voice-base"
    make_home_with_groups(home, base)
    failed += say(s23voice.is_watch("20261120-100000-w.m4a") and not s23voice.is_watch("20261120-100000.m4a"),
                  "続1: 時計の声は名前が -w.m4a")
    failed += say(s23voice.auc([0.9, 0.8], [0.1, 0.2]) == 1.0 and s23voice.auc([0.1], [0.9]) == 0.0
                  and s23voice.auc([0.5], [0.5]) == 0.5 and s23voice.auc([], [1]) is None, "続1: AUC（同点は半分・空は None）")
    known = s23voice.answers(base)
    failed += say(known == {"sp-a": True, "sp-b": False, "sp-c": False, "sx-m": True}, f"続1: 本人の答え（{known}）")
    pairs = s23voice.watch_pairs(home, base)
    ids = sorted(p["id"] for p in pairs)
    failed += say(ids == ["sp-a", "sp-c", "sx-m"] and pairs[0]["id"] == "sx-m",
                  f"続1: 時計の声だけの答えのある組（iPhone の声が混ざる組は入れない・新しい順）（{ids}）")
    # 2 つの声の問い
    me = {"speaker": "自分", "speakerID": "me"}
    p12 = {"speaker": "人物12", "speakerID": "12"}
    conv = lambda start, lines: {"start": start, "lines": lines}  # noqa: E731
    line = lambda who, audio, a, b, t, text="こんにちは": {**who, "audio": audio, "offset": a, "end": b, "time": t, "text": text}  # noqa: E731
    parsed = {"conversations": [
        conv(1, [line(me, "20261122-100000-w.m4a", 1, 5, 1001), line(p12, "20261122-100000-w.m4a", 6, 10, 1002)]),
        conv(2, [line(p12, "20261122-101000-w.m4a", 1, 6, 2001), line(p12, "20261122-101000.m4a", 1, 6, 2002),
                 line(me, "20261122-101000-w.m4a", 20, 21, 2003)])]}
    cands = s23voice.pair_candidates(parsed, "2026-11-22")
    kinds = [c[0] for c in cands]
    failed += say(kinds[:2] == ["same", "different"] and all(s23voice.is_watch(c[1]["audio"]) and s23voice.is_watch(c[2]["audio"])
                                                             for c in cands)
                  and cands[0][1]["audio"] != cands[0][2]["audio"],
                  f"続1: 同じ人物N の別の区切りの 2 行と、話し手の違う 2 行（時計の声だけ・短い行は使わない）（{kinds}）")
    items = s23voice.make_pair_items(home, parsed, "2026-11-22", base, {}, datetime.date(2026, 11, 23))
    failed += say(len(items) == 2 and items[0]["id"].startswith("vp-") and items[0]["answer"] == "yesno"
                  and len(items[0]["clips"]) == 2 and items[0]["clips"][0]["path"].startswith("audio-clip?audio=")
                  and (home / "s23" / "review" / "voice-pairs.json").is_file(),
                  "続1: 問いは 1 日 2 つまで・はい/いいえ・声を 2 つ聞ける（/audio-clip）")
    again = s23voice.make_pair_items(home, parsed, "2026-11-22", base, {}, datetime.date(2026, 11, 23))
    failed += say([i["id"] for i in again] == [i["id"] for i in items], "続1: 同じ日の問いは作り直さない")
    off = s23voice.make_pair_items(home, parsed, "2026-11-22", base, {"voice_pairs": False}, datetime.date(2026, 11, 23))
    failed += say(off == [], "続1: \"voice_pairs\": false なら出さない")
    with (base / "inbox" / "app_feedback.jsonl").open("a", encoding="utf-8") as handle:
        handle.write(json.dumps({"kind": "review", "id": items[0]["id"], "answer": "no"}) + "\n")
    failed += say(items[0]["id"] in s23voice.answers(base) and s23voice.answers(base)[items[0]["id"]] is False
                  and any(p["id"] == items[0]["id"] for p in s23voice.watch_pairs(home, base))
                  and items[0]["id"] not in [i["id"] for i in s23voice.make_pair_items(home, parsed, "2026-11-22", base, {},
                                                                                         datetime.date(2026, 11, 23))],
                  "続1: 答えた問いは答えのある組に入り、もう出さない")
    # 点と AUC（作り物の声の特徴: 同じ人は近い）
    rng = np.random.default_rng(23)
    people = {k: rng.standard_normal(16) for k in "ABCDEFGH"}
    owner = {"a1": "A", "a2": "A", "b1": "B", "c1": "C", "d1": "D", "d2": "D", "e1": "E", "f1": "F"}

    def vec(s):
        v = people[owner[s["audio"]]] + 0.05 * rng.standard_normal(16)
        return v / np.linalg.norm(v)

    fake_pairs = [{"id": "1", "same": True, "people": [[{"audio": "a1"}], [{"audio": "a2"}]]},
                  {"id": "2", "same": True, "people": [[{"audio": "d1"}], [{"audio": "d2"}]]},
                  {"id": "3", "same": False, "people": [[{"audio": "a1"}], [{"audio": "b1"}]]},
                  {"id": "4", "same": False, "people": [[{"audio": "c1"}], [{"audio": "e1"}]]}]
    cohort = [{"audio": k} for k in owner] * 2
    got = s23voice.pair_scores(vec, fake_pairs, cohort)
    failed += say(got["pairs"] == 4 and got["auc_raw"] == 1.0 and got["auc_snorm"] == 1.0,
                  f"続1: 同じ人の組の点が高い（AUC {got['auc_raw']}・s-norm {got['auc_snorm']}）")
    # 続10
    write(home / "same-person" / "snorm.json", {"items": {"sp-a": {"snorm": 2.5}, "sp-b": {"snorm": 0.4}, "sp-c": {"snorm": 1.0},
                                                          "sx-m": {"snorm": None, "short": True}}})
    check = s23voice.snorm_check(home, base)
    failed += say(check["snorm_pairs"] == 3 and check["snorm_same"] == 1 and check["snorm_auc"] is None and check["raw_pairs"] == 4,
                  f"続10: 答えのある組が少なければ AUC は null（数は出す）（{check}）")
    old = s23voice.MIN_PAIRS_AUC
    s23voice.MIN_PAIRS_AUC = 1
    check = s23voice.snorm_check(home, base)
    s23voice.MIN_PAIRS_AUC = old
    failed += say(check["snorm_auc"] == 1.0 and check["raw_auc"] == 1.0, f"続10: 組がそろえば s-norm と今の点の AUC（{check}）")
    return failed


# MARK: - 続4・届7・止1


def check_gaps() -> int:
    failed = 0
    t = datetime.datetime(2026, 11, 20, 10, 0).timestamp()
    chunks = [{"name": "c1", "start": t, "end": t + 300, "watch": True, "result": "r"},
              {"name": "c2", "start": t + 300, "end": t + 600, "watch": True, "result": "r"},
              # 600〜900 は穴（区切り 1 つぶん）
              {"name": "c3", "start": t + 900, "end": t + 1200, "watch": True, "result": "r"},
              {"name": "c4", "start": t + 1200, "end": t + 1500, "watch": True, "result": None},
              {"name": "c5", "start": t + 5000, "end": t + 5300, "watch": True, "result": "r"}]
    blocks = [(t + 10, t + 14, "きょうはいいてんきですね"),          # 記録にある
              (t + 100, t + 104, "あしたのかいぎはなんじから"),        # 記録に無い・PC にも無い → 文字にならなかった
              (t + 400, t + 404, "らーめんをたべにいこうよ"),          # 記録に無い・PC にある → 記録で落とした
              (t + 750, t + 754, "でんしゃがとまっているらしい"),       # 穴が区切り 1 つぶん → 声が無い（見立て）
              (t + 1300, t + 1304, "けっかがもうきえているぶん"),       # 結果が無い → 分からない
              (t + 3000, t + 3004, "ずっとろくおんしていないじかん"),    # 長い穴 → 録れていない
              (t + 3100, t + 3101, "みじかい")]                         # 8 字より短いので数えない
    record = [(t + 11, "きょうはいいてんきですね")]
    pc = [(t + 11, "きょうはいいてんきですね"), (t + 401, "らーめんをたべにいこうよ")]
    got = s23gaps.classify_misses(blocks, record, chunks, pc, dropped_novoice=3)
    failed += say(got["all_blocks"] == 6 and got["blocks"] == 5 and got["no_text"] == 13 and got["dropped_after"] == 12
                  and got["novoice"] == 14 and got["unknown"] == 13 and got["not_recorded"] == 15,
                  f"続4: 抜けを段に分ける（文字数）（{got}）")
    none = s23gaps.classify_misses(blocks, record, chunks, pc, dropped_novoice=0)
    failed += say(none["novoice"] == 0 and none["not_recorded"] == 29, "続4: 時計が捨てていない日は、穴は「録れていない」")
    line = s23gaps.stage_line({"2026-11-20": got})
    failed += say(line is not None and "録れていない" in line and "11-20" in line, "続4: summary.md の 1 行")
    # jobs から区切りの時間
    home = TMP / "gaps-home"
    write(home / "jobs" / "j1.json", {"id": "20261120-100000-w.m4a", "status": "done", "audio_seconds": 290.0,
                                      "times": {"chunk_start": t}})
    (home / "jobs" / "j1.result").write_text(json.dumps({"lines": [{"start": 1.0, "end": 3.0, "text": "テスト です"}]}), encoding="utf-8")
    write(home / "jobs" / "j2.json", {"id": "20261120-110000.m4a", "status": "done", "audio_seconds": 60.0})
    write(home / "jobs" / "j3.json", {"id": "20261121-110000.m4a", "status": "done", "audio_seconds": 60.0})
    spans = s23gaps.chunk_spans(home / "jobs", "2026-11-20")
    failed += say(len(spans) == 2 and spans[0]["end"] - spans[0]["start"] == 290.0 and spans[0]["result"] is not None
                  and spans[1]["watch"] is False, "続4: jobs の区切りの時間（chunk_start が無ければ名前の時刻）")
    failed += say(s23gaps.job_lines(spans) == [(t + 1.0, "テストです")], "続4: PC の文字起こしの行の時刻")
    failed += say(s23gaps.recorded_minutes(spans, None) == {"watch": 4.8, "phone": 1.0}
                  and s23gaps.recorded_minutes(spans, 3600) == {"watch": 60.0, "phone": 1.0},
                  "届7: 録れた時間（時計が数えた秒があればそれ）")
    # diag の日ごと
    device = home / "diag" / "DEV1"
    device.mkdir(parents=True)
    rows = [{"build": "385", "state": {"watchBuild": "380", "watchRecordedToday": 1000, "watchNoVoiceDropped": 2,
                                       "phoneResumeSeconds": 4.5}},
            {"build": "386", "state": {"watchBuild": "382", "watchRecordedToday": 3000, "watchNoVoiceDropped": 5,
                                       "phoneResumeSeconds": 2.0, "watchResumeFailed": 1, "watchResumeAttempts": {"median": 2}}}]
    (device / "2026-11-20.jsonl").write_text("\n".join(json.dumps(r) for r in rows) + "\n", encoding="utf-8")
    day = s23gaps.diag_day(home / "diag", "2026-11-20")
    failed += say(day["app"] == "386" and day["watch"] == "382" and day["watch_recorded_s"] == 3000 and day["novoice"] == 5
                  and day["resume"] == {"phoneResumeSeconds": 2.0, "watchResumeFailed": 1, "watchResumeAttempts": {"median": 2}},
                  f"届7・止1: diag の日ごとの版・録れた秒・捨てた数・中断から戻る数（最後の値）（{day}）")
    text = s23gaps.resume_line({"2026-11-19": {}, "2026-11-20": day["resume"], "2026-11-21": {"phoneResumeSeconds": 3}})
    failed += say(text is not None and "iPhone 戻るまでの秒（phoneResumeSeconds）: 11-19 —・11-20 2・11-21 3" in text
                  and "時計 戻れなかった（watchResumeFailed）" in text and "median 2" in text,
                  f"止1: 3 日の並び（名前が決まっていなくても出す）（{text}）")
    failed += say(s23gaps.resume_line({"2026-11-20": {}}) is None, "止1: 来ていなければ書かない")
    # 届7 版ごとの比べ
    days = {f"2026-11-{d:02d}": {"recorded_min": {"watch": w, "phone": 0}, "builds": {"app": a, "watch": "382", "pc": "200"}}
            for d, w, a in ((15, 600, "380"), (16, 640, "380"), (17, 620, "380"), (18, 300, "386"), (19, 320, "386"))}
    drops = s23gaps.build_drops(days, "2026-11-20")
    failed += say(len(drops) == 1 and drops[0]["part"] == "app" and drops[0]["old"] == "380" and drops[0]["new"] == "386"
                  and drops[0]["old_min"] == 620 and drops[0]["new_min"] == 310,
                  f"届7: アプリの版を上げたあと 3 割以上減ったら知らせる（{drops}）")
    days["2026-11-19"]["recorded_min"]["watch"] = 700
    days["2026-11-18"]["recorded_min"]["watch"] = 600
    failed += say(s23gaps.build_drops(days, "2026-11-20") == [], "届7: 減っていなければ何も言わない")
    days["2026-11-20"] = {"recorded_min": {"watch": 10, "phone": 0}, "builds": {"app": "387"}}
    failed += say(s23gaps.build_drops(days, "2026-11-20") == [], "届7: 今日（終わっていない日）は比べない")
    failed += say("アプリの版を 380 から 386 に上げたあと" in s23gaps.drop_lines(drops)[0], "届7: 気になる所の 1 行")
    return failed


# MARK: - 続3


def check_gold() -> int:
    failed = 0
    loud = {"p10": -30.0, "p50": -25.0, "p90": -15.0, "voicedP50": -22.0}
    quiet = {"p10": -60.0, "p50": -55.0, "p90": -40.0, "voicedP50": -30.0}
    failed += say(s23gold.noise_score(loud) > s23gold.noise_score(quiet) and s23gold.noise_score(None) is None
                  and s23gold.noise_score(None, True) == 5.0, "続3: 騒がしさ（周りの音の床が高く、声との差が小さいほど高い）")
    failed += say(s23gold.scene_of({"movement": "電車・車で"}) == "train" and s23gold.scene_of({"place": "見本ラーメン店"}) == "shop"
                  and s23gold.scene_of({"movement": "歩きながら"}) == "outside" and s23gold.scene_of({}) is None
                  and s23gold.scene_of({}, "car") == "outside" and s23gold.scene_of({"place": "家"}, "shop") == "shop",
                  "続3: 場面の印（電車・店・外。POST /jobs の scene が先）")
    line = lambda audio, a, b, t, noisy=False: {"audio": audio, "offset": a, "end": b, "time": t, "text": "注文はこれで", "noisy": noisy}  # noqa: E731
    parsed = {"conversations": [
        {"movement": "電車・車で", "lines": [line("tr-1.m4a", 1, 5, 11), line("tr-1.m4a", 6, 9, 12), line("tr-2.m4a", 1, 30, 13)]},
        {"place": "見本カフェ", "lines": [line("sh-1.m4a", 1, 4, 21, True)]},
        {"place": "家", "lines": [line("home-1.m4a", 1, 4, 31, True)]},
        {"movement": "歩きながら", "lines": [line("out-1.m4a", 1, 4, 41)]}]}
    levels = {"tr-1.m4a": loud, "tr-2.m4a": loud, "sh-1.m4a": quiet, "out-1.m4a": quiet, "home-1.m4a": loud}
    found = s23gold.candidates(parsed, "2026-11-22", levels)
    failed += say({c["audio"] for c in found} == {"tr-1.m4a", "sh-1.m4a", "out-1.m4a"} and found[0]["audio"] == "tr-1.m4a",
                  "続3: 場面の分かる行だけ・長すぎる行は使わない・騒がしい順")
    picked = s23gold.pick(found, {}, 2)
    failed += say(len(picked) == 2 and len({c["scene"] for c in picked}) == 2, "続3: 場面が偏らないように 1 つずつ")
    home = TMP / "gold-home"
    items = s23gold.update(home, parsed, "2026-11-22", levels, {}, set(), today=datetime.date(2026, 11, 23))
    failed += say(len(items) == 2 and items[0]["answer"] == "text" and items[0]["id"].startswith("gn-")
                  and items[0]["clips"][0]["path"].startswith("audio-clip?audio=") and items[0]["evidence"][0]["text"] == "注文はこれで",
                  "続3: 確かめ待ちの形（打って答える・聞ける・今の文）")
    failed += say(s23gold.update(home, parsed, "2026-11-22", levels, {"noisy_gold": False}, set()) == [],
                  "続3: \"noisy_gold\": false なら出さない")
    saved = []

    def save_sample(folder, audio, start, end, text, source):
        saved.append((text, source))
        return 1, True

    fake_audio = TMP / "a.m4a"
    fake_audio.write_bytes(b"x")
    got = s23gold.take_answer(home, {"id": items[0]["id"], "answer": "そのまま"}, lambda n: fake_audio,
                              lambda b: np.zeros(16000 * 10, np.float32), save_sample, TMP, LOGS.append)
    failed += say(got == {"changed": 1} and saved and saved[0][0] == "注文はこれで" and saved[0][1]["origin"] == "pc-noisy-gold"
                  and saved[0][1]["scene"] in s23gold.SCENES and "注文" not in " ".join(LOGS),
                  "続3: 「そのまま」は今の文を正解集の材料に（origin pc-noisy-gold・場面つき・文は記録に書かない）")
    got = s23gold.take_answer(home, {"id": items[1]["id"], "answer": "わからない"}, lambda n: fake_audio,
                              lambda b: np.zeros(16000, np.float32), save_sample, TMP, LOGS.append)
    failed += say(got == {"changed": 0} and len(saved) == 1 and s23gold.progress(home)["answered"] == 2,
                  "続3: 「わからない」は材料にしない（答えたことは残す）")
    failed += say(s23gold.take_answer(home, {"id": "spk-x", "answer": "yes"}, None, None, None, TMP, LOGS.append) is None,
                  "続3: ほかの問いの答えには手を出さない")
    import goldset

    data = TMP / "gold-data"
    data.mkdir()
    (data / "x.wav").write_bytes(b"RIFF")
    (data / "samples.jsonl").write_text(json.dumps({"audio": "x.wav", "text": "正しい文", "source": {"origin": "pc-noisy-gold",
                                                                                                   "scene": "train"}}) + "\n",
                                        encoding="utf-8")
    failed += say(len(goldset.items(data)) == 1, "続3: 騒がしい場面の材料は正解集（goldset.items）に入る")
    return failed


# MARK: - 続5・試4・届7・summary.md


def check_pc() -> int:
    failed = 0
    home, base = TMP / "pc-home", TMP / "pc-base"
    (base / "inbox").mkdir(parents=True)
    saved = (s23pc.S.home, s23pc.S.main)
    s23pc.S.home = home
    s23pc.S.main = SimpleNamespace(load_config=lambda: {}, log=LOGS.append, mothership=SimpleNamespace(home=lambda c: base),
                                   BUILD=212, App=SimpleNamespace(records=None))
    try:
        row = s23pc.parse_headcount(json.dumps({"start": "2026-11-22T12:00:00+09:00", "count": 3}).encode())
        failed += say(row["day"] == "2026-11-22" and row["count"] == 3 and "orMore" not in row, "続5: 人数の答えの形")
        bad = []
        for body in ({"start": "2026-11-22T12:00:00+09:00", "count": 0}, {"count": 2}, {"start": "x", "count": 2},
                     {"start": "2026-11-22T12:00:00+09:00", "count": True}, [1]):
            try:
                s23pc.parse_headcount(json.dumps(body).encode())
                bad.append(body)
            except ValueError:
                pass
        failed += say(not bad, f"続5: おかしな人数・時刻は断る（{bad}）")
        start = ms(2026, 11, 22, 12)
        for body in ({"start": start, "count": 3, "conversation": "c-1"}, {"start": start + 60_000, "count": 5, "orMore": True}):
            f = Fake(body)
            s23pc.http_post(f, "/headcount")
            failed += say(f.sent[0] == 200 and f.sent[1]["ok"], f"続5: POST /headcount を受ける（{f.sent}）")
        f = Fake(b"{}")
        s23pc.http_post(f, "/headcount")
        failed += say(f.sent[0] == 400, "続5: 中身が違えば 400")
        rows = s23pc.headcount_rows(home, "2026-11-22")
        failed += say(len(rows) == 1 and rows[0]["count"] == 3, "続5: 「5 人以上」は人数を決めないので確6 に渡さない")
        s22voice.EXTRA_HEADCOUNTS = lambda day: s23pc.headcount_rows(home, day)
        known = s22voice.headcounts(None, "2026-11-22")
        failed += say(len(known) == 1 and known[0][2] == 3 and known[0][0] == start - 600_000,
                      f"続5: 母艦が無くても、家の PC が受けた人数を確6 が読む（{known}）")
        # 確かめ待ちに足す
        write(home / "s23" / "review" / "items.json", {"items": [{"id": "vp-1", "kind": "voice_pair"}, {"id": "gn-1", "kind": "gold_noisy"}]})
        (base / "inbox" / "app_feedback.jsonl").write_text(json.dumps({"kind": "review", "id": "gn-1", "answer": "x"}) + "\n",
                                                          encoding="utf-8")
        merged = s23pc.merge_review({"available": True, "items": [{"id": "m-1"}]}, base, home)
        failed += say([i["id"] for i in merged["items"]] == ["m-1", "vp-1"], "続1・続3: 確かめ待ちに足す（答えたものは出さない）")
        failed += say(s23pc.review_hook({"id": "vp-1", "answer": "yes"}) == {"changed": 0}
                      and s23pc.review_hook({"id": "spk-1", "answer": "yes"}) is None, "続1: vp- の答えは受けるだけ・ほかは s22 へ")
        # 試4
        store = SimpleNamespace(path=lambda d: home / "records" / f"{d}.json", day=lambda d: None)
        today = datetime.date(2026, 11, 23)
        write(home / "records" / "2026-11-23.json", {"conversations": [{"lines": [{"text": "a", "conf": 0.9, "norm": "a"},
                                                                                {"text": "b"}]}]})
        write(home / "same-person" / "snorm.json", {"items": {"sp-1": {"snorm": 2.0}}})
        failed += say(s23pc.checks_due(home, "212") and not s23pc.checks_due(home, "0"), "試4: 新しい版（0 は Python のまま）")
        before = (home / "records" / "2026-11-23.json").read_bytes()
        body = s23pc.run_checks(home, store, base, {}, today)
        marks = {r["name"].split("（")[0]: r["ok"] for r in body["results"]}
        failed += say(len(body["results"]) == 7 and marks["報告の棚 /reports"] is True and marks["同じ人かの点 s-norm"] is True
                      and marks["行ごとの確かさ conf"] is True and marks["表記のゆれ norm"] is True
                      and marks["録り方の実験の数"] is None and (home / "records" / "2026-11-23.json").read_bytes() == before,
                      f"試4: 7 つを 1 回ずつ（記録は変えない）（{marks}）")
        failed += say(not s23pc.checks_due(home, "212") and s23pc.checks_due(home, "213"), "試4: 同じ版では 2 回しない")
        f = Fake()
        s23pc.http_get(f, "/s23/checks", "")
        failed += say(f.sent[0] == 200 and len(f.sent[1]["results"]) == 7 and f.sent[1]["build"] == "212", "試4: GET /s23/checks")
        # 届7
        t = datetime.datetime(2026, 11, 22, 9, 0).timestamp()
        write(home / "jobs" / "j.json", {"id": "20261122-090000-w.m4a", "audio_seconds": 300.0, "times": {"chunk_start": t}})
        dev = home / "diag" / "DEV1"
        dev.mkdir(parents=True)
        (dev / "2026-11-22.jsonl").write_text(json.dumps({"build": "386", "state": {"watchBuild": "382",
                                                                                     "watchRecordedToday": 7200}}) + "\n",
                                              encoding="utf-8")
        got = s23pc.recorded_days(home, today)
        entry = quality.read_daily(home)["days"]["2026-11-22"]
        failed += say(got == {"2026-11-22": {"watch": 120.0, "phone": 0.0}} and entry["builds"] == {"app": "386", "watch": "382", "pc": "212"},
                      f"届7: 日ごとの録れた時間と版を quality-daily.json に（{entry}）")
        s23pc.S.main.BUILD = 213
        s23pc.recorded_days(home, today)
        failed += say(quality.read_daily(home)["days"]["2026-11-22"]["builds"]["pc"] == "212",
                      "届7: 終わった日の PC の版は書き換えない")
        quality.update_day(home, "2026-11-21", {"snorm_auc": None, "snorm_pairs": 3, "snorm_same": 1, "raw_auc": None, "raw_pairs": 4,
                                                "plaud_miss_stages": {"blocks": 2, "chars": 20, "not_recorded": 10, "no_text": 10}})
        diag_store = SimpleNamespace(devices=lambda: [{"deviceID": "DEV1"}], folder=home / "diag")
        worries, lines = s23pc.summary_lines(diag_store, datetime.datetime(2026, 11, 23, 12).timestamp())
        text = "\n".join(lines)
        failed += say("試4" in text and "届7" in text and "続4" in text and "続10" in text and "続1" in text and "続5" in text
                      and "（" in text and not any("数えられませんでした" in x for x in lines),
                      "summary.md の「s23 の数」の節が書ける")
    finally:
        s23pc.S.home, s23pc.S.main = saved
        s22voice.EXTRA_HEADCOUNTS = None
    return failed


def check_hooks() -> int:
    """start が s22 の受け口を包んで、s22 の分も今までどおり動くこと"""
    failed = 0
    saved = (appfeeds.REVIEW_HOOK, s20feeds.REVIEW_EXTRA, s22voice.EXTRA_HEADCOUNTS, s23pc.S.thread, s23pc.S.home, s23pc.S.main)
    try:
        seen = []
        appfeeds.REVIEW_HOOK = lambda row: seen.append(row["id"]) or {"changed": 7}
        s20feeds.REVIEW_EXTRA = lambda body, base: {**body, "s22": True}
        s23pc.S.thread = object()   # 見回りの糸は起こさない
        s23pc.start(SimpleNamespace(HOME=str(TMP / "hook-home"), load_config=lambda: {}, log=LOGS.append,
                                    mothership=SimpleNamespace(home=lambda c: None)))
        failed += say(appfeeds.REVIEW_HOOK({"id": "spk-1"}) == {"changed": 7} and seen == ["spk-1"]
                      and appfeeds.REVIEW_HOOK({"id": "vp-1"}) == {"changed": 0} and seen == ["spk-1"],
                      "s23 の答えは s23 が受け、ほかは s22 の受け口へ")
        failed += say(s20feeds.REVIEW_EXTRA({"available": True, "items": []}, None).get("s22") is True,
                      "確かめ待ちは s22 の分を足したあとに s23 の分")
        failed += say(callable(s22voice.EXTRA_HEADCOUNTS), "続5: 確6 の人数の口がつながる")
    finally:
        appfeeds.REVIEW_HOOK, s20feeds.REVIEW_EXTRA, s22voice.EXTRA_HEADCOUNTS, s23pc.S.thread, s23pc.S.home, s23pc.S.main = saved
    return failed


# MARK: - 続2


def check_measure() -> int:
    failed = 0
    combos = s23measure.combos(["haas", "whisper", "parakeet"])
    failed += say(("haas", "whisper") in combos and ("haas", "whisper", "parakeet") in combos and ("haas",) in combos
                  and len(combos) == 7, "続2: 組み合わせ（1 つずつと、2 つ以上の多数決）")

    def vote(hyps):   # 作り物の多数決: いちばん多い文
        texts = [v for v in hyps.values() if v]
        return {"text": max(set(texts), key=texts.count)} if texts else None

    hyps = [{"haas": "きょうははれ", "whisper": "きょうはあめ", "parakeet": "きょうははれ"},
            {"haas": "あしたはくもり", "whisper": "あしたはくもり", "parakeet": "あしたわくもり"}]
    refs = ["きょうははれ", "あしたはくもり"]
    failed += say(s23measure.vote_cer(hyps, refs, ("haas", "whisper", "parakeet"), vote) == 0.0
                  and s23measure.vote_cer(hyps, refs, ("whisper",), vote) > 0, "続2: 組み合わせごとの多数決の CER")
    failed += say(s23measure.window_ok(datetime.datetime(2026, 11, 24, 0, 30)) and not s23measure.window_ok(datetime.datetime(2026, 11, 23, 21, 40))
                  and not s23measure.window_ok(datetime.datetime(2026, 11, 24, 4, 55)), "続1・続2: 重い測りは 00:00〜04:50 だけ")
    return failed


CHECKS = [check_text, check_voice, check_gaps, check_gold, check_pc, check_hooks, check_measure]


def run_all() -> int:
    failed = 0
    for check in CHECKS:
        try:
            failed += check()
        except Exception as error:  # noqa: BLE001 — 1 つが落ちても、ほかは確かめる
            import traceback

            traceback.print_exc()
            failed += say(False, f"{check.__name__} が途中で落ちました: {error!r}")
    # s24（2026-11-24）: 急3・急7・当1・減3・減5・当2・当5・当7・当8・当11・当12（CI の手順を増やさずに動かす）
    import v24checks_s24

    failed += v24checks_s24.run_all()
    return failed


def main() -> int:
    failed = run_all()
    print("ぜんぶ OK" if not failed else f"NG の数: {failed}", flush=True)
    return failed


if __name__ == "__main__":
    sys.exit(main())
