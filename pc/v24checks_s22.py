"""2026-11-22（s22。担当 P）: 家の PC の分を確かめる。決まりは docs/s22-pc.md。

    python pc/v24checks_s22.py          （v24checks_s21.py の最後にも呼ばれる。CI の手順を増やさずに動かすため）

本物の HOME・母艦・iPhone は使わない（一時フォルダに作り物を作る。人の名前は「甲」「乙」などの記号だけ）。確かめること（check_*）:
- 楽5・楽20 s22feeds: 報告の棚（許した名前だけ・.. や / を断る・一覧が無ければ空・本文は text/markdown）・録れない表をそのまま
- 確12・確18・確19・確20・確21・確11 s22text: 決まり文句の票・確かさ・数字の割れ・そろえた文・言葉の時刻・区切りの境目
- 確18・確20・確10 records: 置く前に行へ conf・norm・mediaNearby を足す（元の文は残す・読めること）
- 確24・確4・確22 jobqueue: recExp・levels・scene を読む（おかしい値は捨てる）
- 確1 s22voice: s-norm（同じ人が高い・短い声は点なし）・低い組を隠す・母艦向けの写し
- 確3・確6 s22voice: 続いた区切りの組（同じ区切りの 2 人はつながない）・人数の分かる会話の組
- 確7〜確10 s22voice: 通りすがり・重なり・遠い声・動画の声かもの札と GET /speaker-tags
- 確10 s22media: 再生中のアプリの名前だけを読む・続いた見本をまとめる・時刻が重なるか
- 確19・確27 s22review: 数字の割れた行の問い・答えで文を直す・同じ声のかたまりに広げる・done の changed・/review-queue に足す
- 確5 voices・s22voice: いそうな人の重み（予定・LINE）
- 確24 s22pc: 組ごとの数（区切り・人物N・時間・電池）を rec-exp.json と quality-daily.json に
- 確2・確13・確15・確22 s22models: 初めは今のまま・切り替えたものだけ・00:00〜05:00 だけ取る・大きさが違えば消す
- 確30・確16 s22pc: 職場かどうか分からない数・PLAUD と合う行を材料に（作り物の母艦と仕事）
- summary.md の「s22 の数」の節が書けること
"""

from __future__ import annotations

import datetime
import io
import json
import os
import sys
import tempfile
import wave
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent))

if "v24s" not in os.environ.get("LOCALAPPDATA", ""):  # 単独で動かすときも、本物の HOME に触れない
    os.environ["LOCALAPPDATA"] = str(Path(tempfile.mkdtemp(prefix="v24s22-local-")))

import numpy as np  # noqa: E402

import appfeeds  # noqa: E402
import jobqueue  # noqa: E402
import quality  # noqa: E402
import records  # noqa: E402
import s20feeds  # noqa: E402
import s22feeds  # noqa: E402
import s22media  # noqa: E402
import s22models  # noqa: E402
import s22pc  # noqa: E402
import s22review  # noqa: E402
import s22text  # noqa: E402
import s22voice  # noqa: E402
import voices  # noqa: E402
from v6checks import say  # noqa: E402

TMP = Path(tempfile.mkdtemp(prefix="v24s22-"))
RNG = np.random.default_rng(22)
LOGS: list[str] = []


class Fake:
    """作り物の受け口（Handler の代わり）"""
    client_address = ("127.0.0.1", 0)

    def __init__(self, body=b"") -> None:
        self.rfile = io.BytesIO(json.dumps(body).encode() if not isinstance(body, bytes) else body)
        self.wfile = io.BytesIO()
        self.sent: list = []
        self.headers_out: dict = {}

    def send_json(self, status: int, body: dict) -> None:
        self.sent = [status, body]

    def send_response(self, status: int) -> None:
        self.sent = [status, None]

    def send_header(self, key: str, value: str) -> None:
        self.headers_out[key] = value

    def end_headers(self) -> None:
        pass


def iso(ms: int) -> str:
    return records.iso_ms(ms)


def local_ms(y, mo, d, h=0, mi=0, s=0) -> int:
    return int(datetime.datetime(y, mo, d, h, mi, s).timestamp() * 1000)


# MARK: - 楽5・楽20


def check_feeds() -> int:
    failed = 0
    base = TMP / "mother-feeds"
    (base / "reports").mkdir(parents=True)
    (base / "state").mkdir()
    (base / "reports" / "recording-experiment.md").write_text("# 録り方の実験\n\n本文\n", encoding="utf-8")
    (base / "reports" / "secret.md").write_text("# 出さない\n", encoding="utf-8")
    none = s22feeds.list_reports(base)
    failed += say(none["reports"] == [] and s22feeds.read_report(base, "recording-experiment.md") is None,
                  "楽5: 母艦の許す一覧が無ければ、報告は 1 つも出さない")
    (base / "state" / "reports_for_app.json").write_text(json.dumps(
        {"allow": ["recording-experiment.md", "../secret.md", "a/b.md", "missing.md", "x.txt"]}), encoding="utf-8")
    got = s22feeds.list_reports(base)
    names = [r["name"] for r in got["reports"]]
    failed += say(names == ["recording-experiment.md"] and got["reports"][0]["title"] == "録り方の実験"
                  and got["reports"][0]["bytes"] > 0 and got["reports"][0]["updated_at"] and got.get("generated_at"),
                  f"楽5: GET /reports は許した名前でファイルのあるものだけ（{names}）・title は最初の # の行")
    failed += say(s22feeds.read_report(base, "secret.md") is None and s22feeds.read_report(base, "../secret.md") is None
                  and not s22feeds.safe_name("..md") and not s22feeds.safe_name("a/b.md") and not s22feeds.safe_name("a\\b.md"),
                  "楽5: 許していない名前・.. や / の入った名前は返さない")
    f = Fake()
    s22feeds.http_get(f, "/reports/recording-experiment.md", "", base, TMP, LOGS.append)
    failed += say(f.sent[0] == 200 and f.headers_out.get("Content-Type", "").startswith("text/markdown")
                  and "本文" in f.wfile.getvalue().decode("utf-8") and "本文" not in " ".join(LOGS),
                  "楽5: GET /reports/<名前> は md の本文を text/markdown で（本文は記録に書かない）")
    f = Fake()
    s22feeds.http_get(f, "/reports/secret.md", "", base, TMP, LOGS.append)
    failed += say(f.sent[0] == 404, "楽5: 許していない報告は 404")
    f = Fake()
    s22feeds.http_get(f, "/capture-gap-patterns", "", base, TMP, LOGS.append)
    missing = f.sent[1]
    (base / "state" / "capture_gap_patterns.json").write_text(json.dumps({"version": 1, "weekday_hour": [[0, 1]]}),
                                                               encoding="utf-8")
    f = Fake()
    s22feeds.http_get(f, "/capture-gap-patterns", "", base, TMP, LOGS.append)
    failed += say(missing.get("available") is False and f.sent[1] == {"version": 1, "weekday_hour": [[0, 1]]},
                  "楽20: GET /capture-gap-patterns は母艦のファイルをそのまま（無ければ available false）")
    failed += say(all(n in s22pc.FEATURES for n in ("reports", "gappatterns", "speakertags"))
                  and s22feeds.handles("/reports/x.md") and s22feeds.handles("/reports") and not s22feeds.handles("/report"),
                  "楽5・楽20: features に reports・gappatterns（受け口の道も）")
    return failed


# MARK: - 文字


def check_text() -> int:
    failed = 0
    cases = {"明日の会議は三時です": "明日の会議は3時です", "午後三時に": "15時に", "十五時三十分集合": "15:30集合",
             "二千五百円でした": "2500円でした", "一人で行った": "一人で行った", "１２月２５日": "12月25日",
             "十分です": "十分です", "千葉に行く": "千葉に行く", "1,500円": "1500円"}
    bad = {k: s22text.normalize(k) for k, v in cases.items() if s22text.normalize(k) != v}
    failed += say(not bad, f"確20: 漢数字・全角・時刻・桁区切りをそろえる（数でない語は替えない）{bad or ''}")
    failed += say(s22text.number_split({"haas": "三時に集合", "whisper": "四時に集合", "reazon": "三時に集合"})
                  == ["三時に集合", "四時に集合"] and s22text.number_split({"haas": "三時に集合", "whisper": "3時に集合"}) is None
                  and s22text.number_split({"haas": "こんにちは", "whisper": "こんばんは"}) is None,
                  "確19: 数字の並びが票で割れたときだけ候補（書き方の違いだけなら割れていない）")
    conf = s22text.line_conf({"confidence": 0.9, "votes": {"a": "こんにちは", "b": "こんにちわ"}})
    failed += say(conf == 0.8 and s22text.line_conf({"text": "x"}) is None and s22text.line_conf({"confidence": 0.7}) == 0.7,
                  f"確18: 確かさは confidence と票の割れの小さいほう・どちらも無ければ付けない（{conf}）")
    failed += say(s22text.drop_junk({"haas": "えーと次は", "whisper": "ご協力ありがとうございました。"})["whisper"] == ""
                  and s22text.drop_junk({"haas": "ありがとうございました", "whisper": "ありがとうございました。"})["whisper"]
                  and s22text.drop_junk({"haas": "以上です", "whisper": "以上です"})["whisper"] == "以上です"
                  and s22text.drop_junk({"haas": "えーと", "whisper": "今日はいい天気"})["whisper"] == "今日はいい天気",
                  "確12: Whisper の票が決まり文句だけでほかと似ていなければ数えない（似ていれば残す・ふつうの文は触らない）")
    lines = [{"start": 1.0, "end": 5.0, "text": "あ", "words": [[1.4, 1.6, "あ"], [3.0, 4.2, "い"]]},
             {"start": 1.0, "end": 5.0, "text": "う", "words": [[0.2, 0.5, "う"]]},
             {"start": 1.0, "end": 9.0, "text": "え"}]
    moved = s22text.refine_times(lines)
    failed += say(moved == 1 and lines[0]["start"] == 1.4 and lines[0]["end"] == 4.2 and lines[0]["segStart"] == 1.0
                  and lines[1]["start"] == 1.0 and lines[2]["start"] == 1.0,
                  "確21: 言葉の時刻が区間の中にあるときだけ、行の始まり・終わりを寄せる（元は segStart・segEnd）")
    failed += say(s22text.boundary_cut([{"start": 30.0, "end": 44.9}], 45.0, [{"start": 0.1, "end": 3.0}])
                  and not s22text.boundary_cut([{"start": 30.0, "end": 40.0}], 45.0, [{"start": 0.1, "end": 3.0}])
                  and not s22text.boundary_cut([{"start": 30.0, "end": 44.9}], 45.0, [{"start": 2.0, "end": 3.0}]),
                  "確11: 前の区切りの終わりまで続き、この区切りの頭から始まるときだけ境目で切れた印")
    line = s22text.annotate_line({"text": "三時に集合", "confidence": 0.5})
    plain = s22text.annotate_line({"text": "こんにちは"})
    failed += say(line["text"] == "三時に集合" and line["norm"] == "3時に集合" and line["conf"] == 0.5
                  and "norm" not in plain and "conf" not in plain,
                  "確18・確20: 行に conf と norm を足す（元の文は残す・変わらなければ norm を付けない）")
    return failed


def write_record(home: Path, day: str, conversations: list[dict]) -> None:
    (home / "records").mkdir(parents=True, exist_ok=True)
    (home / "records" / f"{day}.json").write_text(json.dumps({"conversations": conversations}, ensure_ascii=False),
                                                   encoding="utf-8")


def check_records_annotate() -> int:
    failed = 0
    home = TMP / "home-annotate"
    home.mkdir()
    s22pc.S.home = home
    s22pc.S.main = SimpleNamespace(load_config=lambda: {}, log=LOGS.append, mothership=SimpleNamespace(home=lambda c: None))
    t = local_ms(2026, 11, 22, 10, 0, 0)
    s22media.note(home, ["chrome.exe"], 10, now=t / 1000 - 10)
    s22media.note(home, ["chrome.exe"], 10, now=t / 1000 + 50)
    store = records.RecordStore(home, LOGS.append)
    store.annotate = s22pc.annotate_record
    body = {"conversations": [{"start": iso(t), "lines": [
        {"time": iso(t), "text": "三時に集合", "speaker": "甲", "confidence": 0.6, "votes": {"haas": "三時に集合", "whisper": "四時に集合"}},
        {"time": iso(t + 3 * 3600_000), "text": "こんにちは", "speaker": "自分", "speakerID": "me"}]}]}
    day = datetime.datetime.fromtimestamp(t / 1000).date().isoformat()
    store.put(day, json.dumps(body, ensure_ascii=False).encode("utf-8"))
    saved = json.loads(store.path(day).read_text(encoding="utf-8"))
    first, second = saved["conversations"][0]["lines"]
    failed += say(first["text"] == "三時に集合" and first["norm"] == "3時に集合" and isinstance(first["conf"], float)
                  and first.get("mediaNearby") is True and "mediaNearby" not in second and "norm" not in second,
                  "確18・確20・確10: 記録を置く前に行へ conf・norm・mediaNearby を足す（再生の時間に重ならない行には付けない）")
    failed += say(store.day(day) is not None and store.day(day)["lines"] == 2, "記録は足したあとも今までどおり読める")
    store.annotate = lambda d, b: 1 / 0
    store.put(day, json.dumps(body, ensure_ascii=False).encode("utf-8"))
    failed += say(json.loads(store.path(day).read_text(encoding="utf-8"))["conversations"][0]["lines"][0].get("norm") is None,
                  "印を足せなくても、届いたまま置く")
    return failed


def check_params() -> int:
    failed = 0
    got = jobqueue.parse_params({"recExp": ["48k300"], "levels": ['{"p10":-60,"p50":-45.04,"p90":-30,"voicedP50":-33}'],
                                 "scene": ["train"]})
    csv = jobqueue.parse_params({"levels": ["-60,-45,-30,-33"], "recExp": ["64k10"], "scene": ["moon"]})
    failed += say(got.get("rec_exp") == "48k300" and got.get("levels") == {"p10": -60.0, "p50": -45.0, "p90": -30.0,
                                                                          "voicedP50": -33.0} and got.get("scene") == "train"
                  and csv.get("levels", {}).get("voicedP50") == -33.0 and "rec_exp" not in csv and "scene" not in csv,
                  "確24・確4・確22: POST /jobs の recExp・levels（JSON か並び）・scene を読む（決まった値だけ）")
    import urllib.parse

    raw = "name=20261122-120000-w.m4a&recExp=32k45&levels=" + urllib.parse.quote('{"p10":-62.5,"p50":-48,"p90":-31,"voicedP50":-35}')
    watch = jobqueue.parse_params(urllib.parse.parse_qs(raw))
    failed += say(watch.get("rec_exp") == "32k45" and watch.get("levels", {}).get("p10") == -62.5,
                  "確24・確4: /jobs と /w/jobs（時計の外の道）の query の levels（JSON の文字）・recExp をどちらも読む（同じ parse_params）")
    failed += say(s22pc.parse_levels("x") is None and s22pc.parse_levels('{"p10": "a"}') is None
                  and s22pc.parse_levels({"p50": 999}) is None, "確4: おかしい levels は捨てる")
    return failed


# MARK: - 声


def unit(v):
    return v / np.linalg.norm(v)


def make_voice_world(home: Path, day: str) -> dict:
    """3 人の声（甲＝人物1 と人物2 は同じ人・人物3 は別の人）と、ほかの人たちの声"""
    dim = 32
    base_a, base_b = unit(RNG.normal(size=dim)), unit(RNG.normal(size=dim))
    ds = voices.DayStore(home, day)
    stamp = day.replace("-", "")
    samples: dict[str, list] = {}
    for label, center, audio in (("1", base_a, f"{stamp}-100000-w.m4a"), ("2", base_a, f"{stamp}-100100-w.m4a"),
                                 ("3", base_b, f"{stamp}-100100-w.m4a")):
        rows = []
        for k in range(3):
            shift = 5.0 if label == "3" else 0.0   # 人物2 と人物3 は同じ区切りなので、区間をずらす
            start, end = 1.0 + k * 10 + shift, 4.0 + k * 10 + shift
            ds.vectors[voices.seg_key(audio, start, end)] = (unit(center + 0.15 * RNG.normal(size=dim))).astype(np.float32)
            rows.append({"audio": audio, "start": start, "end": end, "time": None, "text": "x"})
        samples[label] = rows
    for k in range(60):
        ds.vectors[voices.seg_key(f"{stamp}-120000.m4a", float(k), float(k) + 2)] = unit(RNG.normal(size=dim)).astype(np.float32)
    ds.save()
    return samples


def check_snorm() -> int:
    failed = 0
    home = TMP / "home-snorm"
    day = "2026-11-20"
    samples = make_voice_world(home, day)
    cfg = s22voice.settings({})
    same, _ = s22voice.snorm(home, [samples["1"], samples["2"]], cfg)
    other, _ = s22voice.snorm(home, [samples["1"], samples["3"]], cfg)
    short_value, short = s22voice.snorm(home, [samples["1"][:1], samples["2"]], cfg)
    failed += say(isinstance(same, float) and isinstance(other, float) and same > other and short_value is None and short,
                  f"確1: s-norm は同じ人の組が高い（{same} > {other}）・短い声（{cfg['short_seconds']} 秒より短い）は点を付けない")
    people = lambda ids: [{"id": i, "name": f"人物{i}", "samples": samples[i]} for i in ids]  # noqa: E731
    body = {"available": True, "days": [{"day": day, "groups": [{"id": "sp-a", "score": 0.7, "people": people(["1", "2"])},
                                                                {"id": "sp-b", "score": 0.7, "people": people(["1", "3"])}]}]}
    out = s22voice.adjust_same_person(home, json.loads(json.dumps(body)), {"s22_voice": {"snorm_min": (same + other) / 2}})
    ids = [g["id"] for g in out["days"][0]["groups"]]
    failed += say(ids == ["sp-a"] and out["s22"]["hidden"] == 1 and "snorm" in out["days"][0]["groups"][0]
                  and out["days"][0]["groups"][0]["score"] == 0.7,
                  f"確1: 点の低い組は出さない（隠した数は s22.hidden）・今の score は残す（{ids}）")
    keep = s22voice.adjust_same_person(home, json.loads(json.dumps(body)), {"s22_voice": {"snorm_min": None}})
    failed += say(len(keep["days"][0]["groups"]) == 2, "確1: snorm_min を null にすれば全部出す")
    (home / "same-person").mkdir(exist_ok=True)
    (home / "same-person" / f"{day}.json").write_text(json.dumps({"day": day, "groups": body["days"][0]["groups"]}),
                                                      encoding="utf-8")
    count = s22voice.export_snorm(home, {})
    written = json.loads((home / "same-person" / "snorm.json").read_text(encoding="utf-8"))["items"]
    failed += say(count == 2 and set(written) == {"sp-a", "sp-b"} and isinstance(written["sp-a"]["snorm"], float),
                  "確1: 母艦の答え合わせ用に same-person/snorm.json へ {id: {snorm}}")
    return failed


def voice_record(day: str, people_lines: list[tuple[str, str, float, float, int]]) -> dict:
    """[(話し手, 音声, 始まり, 終わり, 時刻ミリ秒)] から parse_record の形"""
    lines = [{"time": ms, "text": "文", "speaker": spk, "speakerID": spk.removeprefix("人物") if spk.startswith("人物") else spk,
              "audio": audio, "offset": a, "end": b, "media": None} for spk, audio, a, b, ms in people_lines]
    start = min(x[4] for x in people_lines)
    return {"conversations": [{"start": start, "end": max(x[4] for x in people_lines), "media": None, "place": "店",
                               "lines": lines}]}


def check_chain_and_count() -> int:
    failed = 0
    home = TMP / "home-chain"
    day = "2026-11-21"
    samples = make_voice_world(home, day)
    stamp = day.replace("-", "")
    t = local_ms(2026, 11, 21, 10, 0, 0)
    rows = [("人物1", f"{stamp}-100000-w.m4a", s["start"], s["end"], t + i * 1000) for i, s in enumerate(samples["1"])]
    rows += [("人物2", f"{stamp}-100100-w.m4a", s["start"], s["end"], t + 60_000 + i * 1000) for i, s in enumerate(samples["2"])]
    rows += [("人物3", f"{stamp}-100100-w.m4a", s["start"], s["end"], t + 70_000 + i * 1000) for i, s in enumerate(samples["3"])]
    parsed = voice_record(day, rows)
    got = s22voice.chain_day(home, parsed, day, s22voice.settings({}))
    members = [sorted(p["id"] for p in g["people"]) for g in got["groups"]]
    failed += say(members == [["1", "2"]] and got["people"] == 3 and got["after"] == 2 and got["groups"][0]["id"].startswith("sc-")
                  and got["groups"][0]["why"] == "chain",
                  f"確3: 続いた区切りの声の近い人物N をつなぐ候補（同じ区切りの 2 人はつながない）{members}")
    base = TMP / "mother-count"
    (base / "archive" / "calendar" / "2026" / "11").mkdir(parents=True)
    (base / "archive" / "calendar" / "2026" / "11" / "21.md").write_text("# 予定\n\n- 09:30-12:00 2人で打ち合わせ\n",
                                                                         encoding="utf-8")
    counted = s22voice.count_day(home, parsed, day, base, s22voice.settings({}))
    failed += say(len(counted) == 1 and counted[0]["why"] == "count" and counted[0]["headcount"] == 2
                  and len(counted[0]["people"]) == 2,
                  "確6: 予定に「2人」とある会話で話し手が多すぎれば、近い人物N からつなぐ候補（自分を除いて 1 人になるまで）")
    s22voice.write_chain(home, parsed, day, base, {})
    extra = s22voice.extra_groups(home, day)
    body = {"available": True, "days": [{"day": day, "groups": []}]}
    out = s22voice.adjust_same_person(home, body, {"s22_voice": {"snorm_min": None}})
    failed += say(len(extra) >= 1 and len(out["days"][0]["groups"]) >= 1,
                  "確3・確6: GET /same-person のその日の groups に足す（同じ顔ぶれは 1 つ）")
    return failed


def check_tags() -> int:
    failed = 0
    day = "2026-11-21"
    t = local_ms(2026, 11, 21, 12, 0, 0)
    lines = [
        {"time": t, "text": "a", "speaker": "自分", "speakerID": "me", "audio": "20261121-120000.m4a", "offset": 0.0, "end": 5.0},
        {"time": t + 4000, "text": "b", "speaker": "人物7", "speakerID": "7", "audio": "20261121-120000.m4a", "offset": 4.0, "end": 6.0},
        {"time": t + 20_000, "text": "c", "speaker": "甲", "speakerID": "12", "audio": "20261121-120000.m4a", "offset": 20.0, "end": 24.0},
    ]
    parsed = {"conversations": [{"start": t, "end": t + 30_000, "lines": lines}]}
    key = s22voice.line_key(lines[2])
    levels = {"lines": {key: -60.0}, "chunks": {"20261121-120000.m4a": {"voicedP50": -35.0}}}
    tags = s22voice.tags_day(parsed, day, s22voice.settings({}), levels, media=lambda ms: ms == t + 20_000)
    kinds = sorted({(x["kind"], x["ms"]) for x in tags["tags"]})
    failed += say(("overlap", t) in kinds and ("overlap", t + 4000) in kinds and ("passerby", t + 4000) in kinds
                  and ("far", t + 20_000) in kinds and ("media", t + 20_000) in kinds and ("far", t) not in kinds
                  and tags["passerby_people"] == 1 and all("text" not in x for x in tags["tags"]),
                  f"確7〜確10: 重なり・通りすがり・遠い声（自分の行には付けない）・動画の声かもの札（文は入れない）{tags['counts']}")
    home = TMP / "home-tags"
    s22voice.write_tags(home, None, parsed, day, {})
    f = Fake()
    s22feeds.http_get(f, "/speaker-tags", f"day={day}", None, home, LOGS.append)
    failed += say(f.sent[0] == 200 and f.sent[1]["available"] and f.sent[1]["day"] == day
                  and s22voice.read_tags(home, "2020-01-01")["available"] is False,
                  "確7〜確10: GET /speaker-tags?day= で札（無い日は available false）")
    audio = np.concatenate([np.zeros(16000, np.float32) + 0.001, 0.1 * np.sin(np.arange(32000) / 5).astype(np.float32)])
    got = s22voice.chunk_levels(audio, 16000, [(1.0, 3.0)])
    failed += say(set(got) == {"p10", "p50", "p90", "voicedP50"} and got["voicedP50"] > got["p10"],
                  "確9・確4: 区切りの音の大きさの要約（アプリの levels と同じ名前）")
    return failed


def check_media() -> int:
    failed = 0
    failed += say(s22media.parse_sessions("Chrome\tPlaying\nSpotify.exe\tPaused\nC:\\x\\vlc.exe\tPlaying\n") == ["Chrome", "vlc.exe"]
                  and s22media.app_name("Microsoft.ZuneMusic_8wekyb3d8bbwe!Microsoft.ZuneMusic") == "Microsoft.ZuneMusic",
                  "確10: 再生中（Playing）のアプリの名前だけを読む（曲名・題は読まない）")
    home = TMP / "home-media"
    t0 = datetime.datetime(2026, 11, 21, 20, 0).timestamp()
    s22media.note(home, ["chrome.exe"], 5, now=t0)
    s22media.note(home, ["chrome.exe"], 500, now=t0 + 60)
    s22media.note(home, [], 5, now=t0 + 3600)
    body = s22media.read_day(home, "2026-11-21")
    failed += say(len(body["playing"]) == 1 and body["playing"][0][1] - body["playing"][0][0] == 60 and len(body["active"]) == 2
                  and s22media.near(home, int((t0 + 30) * 1000)) and not s22media.near(home, int((t0 + 600) * 1000)),
                  "確10: 続いた見本は 1 つにまとめる・行の時刻が再生の時間（前後 30 秒）に入るか")
    failed += say(s22media.day_counts(home, "2026-11-21")["apps"] == {"chrome.exe": 1}, "確10: 日ごとの再生の分（アプリごと）")
    return failed


# MARK: - 確19・確27


def check_review() -> int:
    failed = 0
    home = TMP / "home-review"
    base = TMP / "mother-review"
    (base / "inbox").mkdir(parents=True)
    day = "2026-11-21"
    samples = make_voice_world(home, day)
    stamp = day.replace("-", "")
    t = local_ms(2026, 11, 21, 15, 0, 0)
    lines = [{"time": iso(t), "text": "三時に集合", "speaker": "甲", "speakerID": "20",
              "votes": {"haas": "三時に集合", "whisper": "四時に集合"}}]
    for i, s in enumerate(samples["1"]):
        lines.append({"time": iso(t + 10_000 + i * 1000), "text": "声", "speaker": "人物1", "speakerID": "1",
                      "audio": s["audio"], "offset": s["start"], "end": s["end"]})
    for i, s in enumerate(samples["3"]):
        lines.append({"time": iso(t + 20_000 + i * 1000), "text": "別の声", "speaker": "人物1", "speakerID": "1",
                      "audio": f"{stamp}-110000.m4a", "offset": s["start"], "end": s["end"]})
    store = records.RecordStore(home, LOGS.append)
    store.put(day, json.dumps({"conversations": [{"start": iso(t), "lines": lines}]}, ensure_ascii=False).encode("utf-8"))
    (home / "same-person").mkdir(exist_ok=True)
    sample = dict(samples["1"][0], time=iso(t + 10_000), text="声")
    (home / "same-person" / "voices.json").write_text(json.dumps({"maybe": [
        {"id": "pm-x", "day": day, "score": 0.8, "person": {"id": "1", "samples": [sample]}, "named": {"id": "20", "name": "甲"}}]},
        ensure_ascii=False), encoding="utf-8")
    counts = s22review.build(home, store, base, [day])
    items = json.loads((home / "s22" / "review" / "items.json").read_text(encoding="utf-8"))["items"]
    number = next((i for i in items if i["kind"] == "number"), None)
    speaker = next((i for i in items if i["kind"] == "speaker_line"), None)
    failed += say(counts.get("number") == 1 and number is not None and number["choices"] == ["三時に集合", "四時に集合"]
                  and number["answer"] == "pick" and number["evidence"][0]["ref"] == f"{day}|{t}"
                  and (base / "inbox" / "pc-review" / "candidates.json").is_file(),
                  "確19: 数字が票で割れた行を kind number の問いに（choices＝票の文・母艦にも写す）")
    failed += say(speaker is not None and speaker["spread"] == 3 and speaker["answer"] == "yesno",
                  f"確27: 「この声は 甲 さんですか」の問い・広げる行は同じ区切りか声の近い行だけ（{speaker and speaker['spread']}）")
    hook_main = SimpleNamespace(load_config=lambda: {}, log=LOGS.append,
                                mothership=SimpleNamespace(home=lambda c: base), App=SimpleNamespace(records=store))
    s22pc.S.home, s22pc.S.main = home, hook_main
    appfeeds.REVIEW_HOOK = s22pc.review_hook
    f = Fake({"kind": "review", "id": number["id"], "answer": "四時に集合", "at": "2026-11-21T16:00:00+09:00"})
    appfeeds.http_post_feedback(f, base, f.rfile.getvalue(), LOGS.append)
    pending = store.edits.pending(0)
    failed += say(f.sent[0] == 200 and f.sent[1].get("done") == {"changed": 1} and len(pending) == 1
                  and pending[0]["kind"] == "text",
                  f"確19・確27: 数字の答えで行の文を直し（PC から直すと同じ）、答えに done.changed（{f.sent[1]}）")
    f = Fake({"kind": "review", "id": speaker["id"], "answer": "yes", "at": "2026-11-21T16:01:00+09:00"})
    appfeeds.http_post_feedback(f, base, f.rfile.getvalue(), LOGS.append)
    expanded = [json.loads(x) for x in (base / "inbox" / "review_expanded.jsonl").read_text(encoding="utf-8").splitlines()]
    failed += say(f.sent[1].get("done") == {"changed": 3} and expanded[-1] == {**expanded[-1], "id": speaker["id"], "lines": 3}
                  and len(store.edits.pending(0)) == 4,
                  "確27: 「はい」で同じ声のかたまりの 3 行の話し手を直し、母艦 inbox/review_expanded.jsonl に {id, lines}")
    f = Fake({"kind": "review", "id": "other-1", "answer": "yes"})
    appfeeds.http_post_feedback(f, base, f.rfile.getvalue(), LOGS.append)
    failed += say(f.sent == [200, {"ok": True}], "確27: 家の PC の問いでない答えは今までどおり {ok: true}")
    appfeeds.REVIEW_HOOK = None
    (base / "state").mkdir(exist_ok=True)
    (base / "state" / "review_queue_for_app.json").write_text(json.dumps({"items": [
        {"id": "m-1", "kind": "place", "question": "q", "answer": "yesno", "evidence": []}]}), encoding="utf-8")
    s20feeds.REVIEW_EXTRA = lambda body, b: s22feeds.merge_review(body, b, home)
    f = Fake()
    s20feeds.http_get(f, base, "/review-queue")
    ids = [i["id"] for i in f.sent[1]["items"]]
    s20feeds.REVIEW_EXTRA = None
    failed += say(ids[0] == "m-1" and speaker["id"] not in ids and number["id"] not in ids,
                  f"確19・確27: GET /review-queue の後ろに家の PC の問いを足す（答えたものは足さない）{ids}")
    return failed


def check_prior() -> int:
    failed = 0
    centers = {"u:1": unit(np.array([1.0, 0.0, 0.0]))}
    refs = {"n:a": unit(np.array([0.8, 0.6, 0.0])), "n:b": unit(np.array([0.79, 0.0, 0.61]))}
    plain = voices.suggest_named(centers, refs, set(), 0.5, 0.0)
    pushed = voices.suggest_named(centers, refs, set(), 0.5, 0.0, bonus=lambda label, ref: 0.02 if ref == "n:b" else 0.0)
    failed += say(plain["u:1"][0] == "n:a" and pushed["u:1"][0] == "n:b",
                  "確5: いそうな人の近さに少しだけ足してから比べる（自分には足さない）")
    base = TMP / "mother-prior"
    (base / "archive" / "calendar" / "2026" / "11").mkdir(parents=True)
    (base / "archive" / "line" / "2026" / "11").mkdir(parents=True)
    (base / "archive" / "calendar" / "2026" / "11" / "21.md").write_text("- 19:00 甲野と食事\n", encoding="utf-8")
    (base / "archive" / "line" / "2026" / "11" / "21.md").write_text("## 乙川\n\n- **17:30** 乙川: 了解\n- **05:00** 丙: 朝\n",
                                                                     encoding="utf-8")
    t = local_ms(2026, 11, 21, 19, 0)
    parsed = {"conversations": [{"start": t, "place": "店", "lines": []}]}
    history = [{"conversations": [{"place": "店", "lines": [{"speaker": "丁"}]}]}]
    got = s22voice.likely_people(base, parsed, "2026-11-21", {"甲野", "乙川", "丙", "丁"}, history)
    failed += say(got == {"calendar": {"甲野"}, "place": {"丁"}, "line": {"乙川"}},
                  f"確5: いそうな人＝予定・同じ場所で前に話した人・直前 3 時間の LINE の相手（記録にある名前だけ）{got}")
    return failed


def check_recexp() -> int:
    failed = 0
    home = TMP / "home-recexp"
    s22pc.S.home = home
    s22pc.S.main = SimpleNamespace(load_config=lambda: {}, log=LOGS.append, mothership=SimpleNamespace(home=lambda c: None))
    day = "2026-11-21"
    start = datetime.datetime(2026, 11, 21, 9, 0).timestamp()
    for i, (exp, people) in enumerate((("32k45", "人物1"), ("32k45", "人物2"), ("48k300", "人物3"))):
        s22pc.note_result(f"20261121-09{i:02d}00-w.m4a", {"status": "done", "lines": 2, "audio_seconds": 45, "voiced_seconds": 30,
                                                          "times": {"chunk_start": start + i * 60},
                                                          "params": {"rec_exp": exp, "levels": {"voicedP50": -30.0}}})
    device = home / "diag" / "dev1"
    device.mkdir(parents=True)
    t9 = datetime.datetime(2026, 11, 21, 9, 0).timestamp()
    rows = [{"state": {"recExpHourly": {"9": "32k45", "10": "48k300"},
                       "watchBatteryAt": [[t9, 0.9], [t9 + 1800, 0.88], [t9 + 3600, 0.86], [t9 + 5400, 0.80]]}}]
    (device / f"{day}.jsonl").write_text("\n".join(json.dumps(r) for r in rows), encoding="utf-8")
    lines = [{"time": int((start + i * 60) * 1000), "text": "x", "speaker": p, "audio": f"20261121-09{i:02d}00-w.m4a"}
             for i, p in enumerate(("人物1", "人物2", "人物3"))]
    store = SimpleNamespace(day=lambda d: {"conversations": [{"lines": lines}]} if d == day else None)
    s22pc.rec_exp_days(home, store, datetime.date(2026, 11, 21), days=1)
    body = json.loads((home / "s22" / "rec-exp.json").read_text(encoding="utf-8"))
    combos = body["days"][day]
    daily = quality.read_daily(home)["days"][day]["rec_exp"]
    failed += say(combos["32k45"]["chunks"] == 2 and combos["32k45"]["people_kinds"] == 2 and combos["48k300"]["chunks"] == 1
                  and combos["32k45"]["hours"] == 1 and combos["48k300"]["battery_per_hour"] == 0.12
                  and abs(combos["32k45"]["battery_per_hour"] - 0.04) < 1e-6 and daily == combos,
                  f"確24: 組ごとの区切り・人物N の種類・時間・電池の減り（rec-exp.json と quality-daily.json の rec_exp）")
    failed += say(s22pc.app_levels(home, day).get("20261121-090000-w.m4a") == {"voicedP50": -30.0},
                  "確4: 区切りの levels を日ごとに残す（自分の声の見立てに使う）")
    return failed


def check_models() -> int:
    failed = 0
    home = TMP / "home-models"
    failed += say(s22models.speaker_choice({}) == "campplus" and s22models.enhance_choice({}) == "gtcrn"
                  and s22models.asr_extra({}) == [] and s22models.wanted(home, {}) == []
                  and not s22models.enhance_for_scene({}, "train"),
                  "確2・確13・確15・確22: 何も書かなければ今のまま（取りに行くものも無い）")
    config = {"speaker_model": "wespeaker34", "enhance_model": "dpdfnet2", "asr_extra": ["parakeet", "nope"],
              "enhance_scenes": {"train": True}}
    wanted = s22models.wanted(home, config)
    failed += say(len(wanted) == 4 and all(u.startswith("https://huggingface.co/") for _, u, _, _ in wanted)
                  and s22models.enhance_for_scene(config, "train") and not s22models.enhance_for_scene(config, "car"),
                  "確2・確13・確15: 切り替えたものだけ、Hugging Face の決めた所から取る")
    calls = []

    def fetch(url, path):
        calls.append(url)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"x" * 10)

    day_time = datetime.datetime(2026, 11, 22, 12, 0)
    night_time = datetime.datetime(2026, 11, 22, 2, 0)
    none = s22models.fetch_missing(home, config, fetch, LOGS.append, day_time)
    got = s22models.fetch_missing(home, config, fetch, LOGS.append, night_time)
    failed += say(none == 0 and not calls[:0] and got == 0 and len(calls) == 4
                  and not any(p.exists() for p, _, _, _ in wanted),
                  "確2・確13・確15: 取るのは 00:00〜05:00 だけ・大きさか SHA-256 が合わなければ消して今のまま")
    failed += say(s22models.speaker_ready(home, config) is None and s22models.speaker_ready(home, {}) is None,
                  "確2: 手元に無ければ話し手のモデルは今のまま")
    return failed


def check_work_and_summary() -> int:
    failed = 0
    t = local_ms(2026, 11, 20, 10, 0)  # 金曜
    old = {"conversations": [{"start": t - 86_400_000 * 2, "work": True, "place": "事務所", "lines": []},
                             {"start": t - 86_400_000 * 3, "work": True, "place": "事務所", "lines": []}]}
    day = {"conversations": [{"start": t, "work": None, "place": "事務所", "lines": []},
                             {"start": t + 3600_000, "work": None, "place": "公園", "lines": []},
                             {"start": local_ms(2026, 11, 20, 22, 0), "work": None, "place": "家", "lines": []},
                             {"start": t, "work": False, "place": "家", "lines": []}]}
    store = SimpleNamespace(day=lambda d: old if d in ("2026-11-18", "2026-11-19") else None)
    got = s22pc.work_unknown(store, day, "2026-11-20", datetime.date(2026, 11, 21))
    failed += say(got == {"work_unknown": 3, "work_unknown_share": 0.75, "work_guess_place": 1, "work_guess_time": 1},
                  f"確30: 分からない数と割合・場所と時間で見当の付く数（数えるだけ）{got}")
    home = TMP / "home-summary"
    s22pc.S.home = home
    s22pc.S.main = SimpleNamespace(load_config=lambda: {}, log=LOGS.append, mothership=SimpleNamespace(home=lambda c: None),
                                   read_samples=lambda p: [{"source": {"origin": "pc-plaud"}}, {}], PERSONAL_DATA=home)
    worries, lines = s22pc.summary_lines(None, datetime.datetime(2026, 11, 22, 12).timestamp())
    store = SimpleNamespace(devices=lambda: [{"device": "iPhone", "state": {"launchToToday": {"last": 1.2, "median": 0.9, "n": 5},
                                                                             "ipadReader": False, "muffledToday": 2}}])
    _, with_device = s22pc.summary_lines(store, datetime.datetime(2026, 11, 22, 12).timestamp())
    failed += say(any("今日の画面まで 真ん中 0.9 秒" in x and "こもった音（今日） 2" in x for x in with_device),
                  "A1 の省ける様子（launchToToday・muffledToday など）を summary に出す（来ていなければ書かない）")
    failed += say(any("録り方の実験" in x for x in lines) and any("PLAUD と合う行から 1 個" in x for x in lines)
                  and not any("数えられませんでした" in x for x in lines),
                  "summary.md の「s22 の数」の節が書ける（まだ無い数は書かない・つまずかない）")
    return failed


def write_wav(path: Path, seconds: float) -> None:
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes((np.sin(np.arange(int(16000 * seconds)) / 7) * 3000).astype(np.int16).tobytes())
    path.write_bytes(buffer.getvalue())


def check_plaud_samples() -> int:
    failed = 0
    home = TMP / "home-plaud"
    base = TMP / "mother-plaud"
    (home / "jobs").mkdir(parents=True)
    name = "20261121-100000-w.m4a"
    text = "明日の打ち合わせは駅前でやりましょう"
    (home / "jobs" / f"{name}.result").write_text(json.dumps({"lines": [{"start": 1.0, "end": 4.0, "text": text}]},
                                                             ensure_ascii=False), encoding="utf-8")
    (home / "jobs" / f"{name}.json").write_text(json.dumps({"id": name}), encoding="utf-8")
    write_wav(home / "jobs" / f"{name}.audio", 6.0)
    saved = []
    main = SimpleNamespace(read_samples=lambda p: [], PERSONAL_DATA=home, SAMPLE_MAX=15.0,
                           load_audio=lambda b: np.zeros(16000 * 6, np.float32), log=LOGS.append,
                           save_sample=lambda folder, audio, s, e, t, src: (saved.append((s, e, t, src)) or (1, True)))
    s22pc.S.main = main
    moment = datetime.datetime(2026, 11, 21, 10, 0, 1).timestamp()
    import judgecheck

    real = s22pc.plaudmatch._timed
    s22pc.plaudmatch._timed = lambda h, b, d: ([{"t0": moment - 1, "blocks": [{"t": 0, "end": 10, "n": judgecheck.norm(text)}]}], [])
    base.mkdir(exist_ok=True)
    try:
        got = s22pc.plaud_samples(home, base, datetime.date(2026, 11, 22), {})
        off = s22pc.plaud_samples(home, base, datetime.date(2026, 11, 22), {"plaud_samples": False})
    finally:
        s22pc.plaudmatch._timed = real
    failed += say(got == 1 and saved and saved[0][2] == text and saved[0][3]["origin"] == "pc-plaud" and saved[0][3]["auto"]
                  and off == 0,
                  "確16: PLAUD の文とよく合う行を、自動の材料（origin pc-plaud・auto）として足す（設定で止まる）")
    return failed


def check_place_words() -> int:
    import s22place

    failed = 0
    home = TMP / "home-place"
    base = TMP / "mother-place"
    (base / "digests" / "timeline").mkdir(parents=True)
    (base / "digests" / "timeline" / "2026-11-21.json").write_text(json.dumps({"rows": [
        {"lane": "位置", "place": "体育館", "time": "10:00", "end": "12:00"}]}, ensure_ascii=False), encoding="utf-8")
    convs = {"体育館": "スパイクの練習とブロック練習。スパイク良い。ブロックも。スパイク。ブロック",
             "会社": "会議の資料と会議の時間。資料。会議"}
    parsed = {"conversations": [{"place": p, "lines": [{"text": t, "speaker": "甲"}]} for p, t in convs.items()]}
    store = SimpleNamespace(day=lambda d: parsed if d == "2026-11-21" else None)
    s22place.build(home, store, datetime.date(2026, 11, 21))
    epoch = datetime.datetime(2026, 11, 21, 10, 30).timestamp()
    off = s22place.add(["登録語"], epoch, base, home, {})
    on = s22place.add(["登録語"], epoch, base, home, {"place_words": True})
    failed += say(off == (["登録語"], 0) and on[1] >= 1 and "スパイク" in on[0] and "会議" not in on[0],
                  f"確23: 場所ごとの言葉は既定で足さない・\"place_words\": true ならその時刻にいた所の言葉だけ（{on}）")
    return failed


def check_main_hooks() -> int:
    """lifelog_pc の中のつなぎ（決まり文句の票・前の区切り・場面の雑音除去）"""
    import lifelog_pc

    lifelog_pc.isolate_home()
    failed = 0

    class Engine:
        provider = "cpu"

        def __init__(self, name, text):
            self.name, self.label, self.text = name, name, text

        def run_timed(self, audio, segments, hints, prompt):
            return [(self.text, None) for _ in segments]

    audio = np.zeros(16000 * 5, dtype=np.float32)
    saved = lifelog_pc.CLEAN_AUDIO, lifelog_pc.load_config
    lifelog_pc.CLEAN_AUDIO = False
    lifelog_pc.load_config = lambda: {}
    try:
        lines = lifelog_pc.Ensemble([Engine("haas", "えーと次はこれ"), Engine("whisper", "ご協力ありがとうございました。")])             .transcribe(audio, [(0.0, 3.0)], votes=True)
        failed += say(len(lines) == 1 and lines[0]["text"] == "えーと次はこれ"
                      and lines[0]["votes"]["whisper"] == "ご協力ありがとうございました。",
                      "確12: 多数決で Whisper の決まり文句の票は数えない（票の文は残る）")
        import judgecheck

        now = judgecheck.chunk_epoch("20261121-100046-w.m4a")
        jobs = SimpleNamespace(jobs={"20261121-100000-w.m4a": {"status": "done", "audio_seconds": 45.0,
                                                               "times": {"chunk_start": now - 46.0}}},
                               get=lambda n: {"result": {"lines": [{"start": 30.0, "end": 44.9, "text": "x"}]}})
        saved_jobs = lifelog_pc.App.jobs
        lifelog_pc.App.jobs = jobs
        try:
            prev = lifelog_pc.previous_chunk("20261121-100046-w.m4a")
            other = lifelog_pc.previous_chunk("20261121-100046.m4a")
        finally:
            lifelog_pc.App.jobs = saved_jobs
        failed += say(prev[1] == 45.0 and prev[0][0]["end"] == 44.9 and other == (None, None),
                      "確11: 同じ端末のすぐ前の区切りの行と長さを見つける（iPhone の区切りとは混ぜない）")
        failed += say(set(s22pc.FEATURES) <= set(lifelog_pc.features([])), "s22 の features を /hello に出す")
    finally:
        lifelog_pc.CLEAN_AUDIO, lifelog_pc.load_config = saved
    return failed


CHECKS = (check_main_hooks, check_place_words, check_feeds, check_text, check_records_annotate, check_params, check_snorm, check_chain_and_count, check_tags,
          check_media, check_review, check_prior, check_recexp, check_models, check_work_and_summary, check_plaud_samples)


def run_all() -> int:
    failed = 0
    saved = (s22pc.S.home, s22pc.S.main)
    for check in CHECKS:
        try:
            failed += check()
        except Exception as error:  # noqa: BLE001 — 1 つが落ちても、ほかは確かめる
            import traceback

            traceback.print_exc()
            failed += say(False, f"{check.__name__} が途中で落ちました: {error!r}")
    s22pc.S.home, s22pc.S.main = saved
    appfeeds.REVIEW_HOOK = None
    s20feeds.REVIEW_EXTRA = None
    return failed


def main() -> int:
    failed = run_all()
    print("ぜんぶ OK" if not failed else f"NG の数: {failed}", flush=True)
    return failed


if __name__ == "__main__":
    sys.exit(main())
