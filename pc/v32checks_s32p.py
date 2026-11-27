"""2026-11-27（s32。担当 p）: 家の PC の s32 の分を確かめる（知7 ヒント・知8 番号・知9 会議の出席者）。

    python pc/v32checks_s32p.py          （v31checks_s31p.py の最後にも呼ばれる。CI の手順を増やさずに動かすため）

本物の HOME・母艦は使わない（一時フォルダに作り物の母艦を作る）。名前・言葉・文はすべて作りもの。
"""

from __future__ import annotations

import datetime
import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

if not any(mark in os.environ.get("LOCALAPPDATA", "") for mark in ("v25s", "v26s", "v27s", "v30s", "v31s", "v32s")):
    os.environ["LOCALAPPDATA"] = str(Path(tempfile.mkdtemp(prefix="v32s-local-")))

import s32pnumbers  # noqa: E402
import s32pwork  # noqa: E402
from v6checks import say  # noqa: E402

TMP = Path(tempfile.mkdtemp(prefix="v32s-"))
DAY = "2026-11-20"


def epoch(hhmm: str) -> float:
    h, m = hhmm.split(":")
    return datetime.datetime(2026, 11, 20, int(h), int(m)).timestamp()


def mother(name: str, meetings=None, vocab=None, work=None, config=None) -> Path:
    base = TMP / name
    (base / "state").mkdir(parents=True, exist_ok=True)
    for rel, body in (("s32_meeting_people_for_pc.json", meetings), ("vocab_for_app.json", vocab),
                      ("work_for_app.json", work), ("s27_work_config.json", config)):
        if body is not None:
            (base / "state" / rel).write_text(json.dumps(body, ensure_ascii=False), encoding="utf-8")
    return base


MEET = {"items": [{"day": DAY, "start": "10:00", "end": "11:00", "name": "見本の定例", "people": ["見本アリス", "見本ボブ"]},
                  {"day": DAY, "start": "10:30", "end": "11:30", "name": "重なる会議", "people": ["見本キャロル"]}]}


def labels() -> dict:
    def item(hhmm: str) -> dict:
        h, m = hhmm.split(":")
        return {"day": DAY, "audio": f"20261120-{int(h):02d}{m}00-a.m4a", "start": 30.0, "end": 40.0}
    return {"人物1": {"items": [item("10:15")], "days": {DAY}, "name": ""},
            "人物2": {"items": [item("12:00")], "days": {DAY}, "name": ""},
            "人物3": {"items": [item("10:40")], "days": {DAY}, "name": ""},
            "p:alice": {"items": [], "days": set(), "name": "見本アリス"},
            "p:bob": {"items": [], "days": set(), "name": "見本ボブ"},
            "p:carol": {"items": [], "days": set(), "name": "見本キャロル"},
            "p:dan": {"items": [], "days": set(), "name": "見本ダン"}}


def check_meeting() -> int:
    failed = 0
    base = mother("m1", meetings=MEET)
    score = s32pwork.meeting_score(base, labels())
    failed += say(score is not None, "会議があれば候補の関数が出る")
    failed += say(score("人物1", "p:alice") == s32pwork.MEETING_BONUS, "会議の窓の中の声は、出席者に寄る")
    failed += say(score("人物1", "p:dan") == 0.0, "出席者でない人には寄せない")
    failed += say(score("人物2", "p:alice") == 0.0, "窓の外（12:00）の声は寄せない")
    failed += say(score("人物1", "p:carol") == 0.0, "別の会議の出席者には、その時間でなければ寄せない")
    failed += say(score("人物3", "p:carol") > 0 and score("人物3", "p:alice") > 0, "会議が重なる時間は両方の出席者に寄る")
    failed += say(s32pwork.meeting_score(mother("m2"), labels()) is None, "ファイルが無ければ何もしない（None）")
    failed += say(s32pwork.meeting_score(None, labels()) is None, "母艦が無ければ何もしない")
    off = mother("m3", meetings=MEET, config={"s32p": {"meeting": False}})
    failed += say(s32pwork.meeting_score(off, labels()) is None, "止める切り替え（meeting: false）")
    bad = mother("m4", meetings={"items": [{"day": "x", "start": "10:00", "end": "09:00", "people": ["a"]}, "x", {"day": DAY}]})
    failed += say(s32pwork.read_meetings(bad) == [], "壊れた行・終わりが始まりより前の行は読まない")

    def old_fn(label, ref):
        return 0.02 if label == "人物2" else 0.0

    both = s32pwork.combine(old_fn, score)
    failed += say(both("人物2", "p:alice") == 0.02 and both("人物1", "p:alice") == s32pwork.MEETING_BONUS, "今の近さと大きいほうを取る")
    failed += say(s32pwork.combine(old_fn, None) is old_fn and s32pwork.combine(None, None) is None, "片方が None ならもう片方")
    lab = labels()
    names = json.dumps({k: v["name"] for k, v in lab.items()}, ensure_ascii=False)
    s32pwork.meeting_score(base, lab)("人物1", "p:alice")
    failed += say(json.dumps({k: v["name"] for k, v in lab.items()}, ensure_ascii=False) == names, "名前の印は書き換えない")
    return failed


def check_hints() -> int:
    failed = 0
    vocab = {"items": [{"word": "見本システム", "count": 30, "sure": True}, {"word": "見本さん", "count": 99, "sure": False},
                       {"word": "あ", "count": 50, "sure": True}, {"word": "見本テスト", "count": 10, "sure": True}]}
    work = {"glossary": [{"term": "見本略語", "days": ["d1", "d2", "d3"], "firm": True, "for_asr": True},
                         {"term": "見本ひかえ", "days": ["d1"], "firm": True, "asr": False},
                         {"term": "見本システム", "days": ["d1"], "for_asr": True}]}
    base = mother("h1", meetings=MEET, vocab=vocab, work=work)
    words = s32pwork.work_words(base)
    failed += say(words == ["見本略語", "見本システム", "見本テスト"], f"言葉は M2 の印つき→多い順・sure と for_asr だけ・1 字は外す・重複なし: {words}")
    failed += say(len(s32pwork.work_words(base, 2)) == 2, "足す数の上限")
    got, n = s32pwork.add_hints(["既存"], epoch("09:00"), base, True)
    failed += say(got == ["見本略語", "見本システム", "見本テスト", "既存"] and n == 3, "work の仕事は先頭に足す")
    got, n = s32pwork.add_hints(["既存"], epoch("10:20"), base, None)
    failed += say(n == 3 and got[-1] == "既存", "会議の窓に入る区切りも職場の時間")
    got, n = s32pwork.add_hints(["既存"], epoch("13:00"), base, None)
    failed += say(got == ["既存"] and n == 0, "職場の時間でなければ足さない")
    got, n = s32pwork.add_hints(["見本システム", "既存"], epoch("10:20"), base, None)
    failed += say(got[0] == "見本略語" and got[1] == "見本テスト" and got.count("見本システム") == 1, "もうあるヒントは重ねない")
    got, n = s32pwork.add_hints(["既存"], epoch("10:20"), mother("h2", config={"s32p": {"hints": False}}, vocab=vocab), True)
    failed += say(got == ["既存"] and n == 0, "止める切り替え（hints: false）")
    got, n = s32pwork.add_hints(["既存"], None, mother("h3"), True)
    failed += say(got == ["既存"] and n == 0, "言葉のファイルが無ければ前のまま")
    got, n = s32pwork.add_hints(["既存"], None, None, True)
    failed += say(got == ["既存"] and n == 0, "母艦が無ければ前のまま")
    return failed


# (読み上げの文, 期待する番号の並び)。[] は「候補にしない」
CASES = [
    ("さんのにーよんご", ["3-245"]),
    ("まるいちのごのご", ["①-5-5"]),
    ("サンノニーヨンゴ", ["3-245"]),
    ("3のにーよんご", ["3-245"]),
    ("ケースさんのにーよんごの件です", ["3-245"]),
    ("チケット番号はぜろいちさん", ["013"]),
    ("ごのご", []),
    ("さんのに", []),
    ("ケースのごのご", ["5-5"]),
    ("チケットはさんのに", ["3-2"]),
    ("いちばんいいですね", []),
    ("にがつさんじゅうにち", []),
    ("さんじにしましょう", []),
    ("ごひゃくえん", []),
    ("にほんのいちにち", []),
    ("まるさんのななのはち", ["③-7-8"]),
    ("ハイフンで、ごのろくのなな", ["5-6-7"]),
    ("三のにのよんごです", ["3-2-45"]),
    ("これはただの文です", []),
    ("", []),
    ("ごろくななはち", ["5678"]),
    ("案件ろくのなな", ["6-7"]),
    ("ケースといちとに", []),
    ("きゅうのぜろのぜろ", ["9-0-0"]),
    ("にーにーさん", ["223"]),
    ("じゅうにのさんのよん", []),
]


def check_numbers() -> int:
    failed = 0
    for text, want in CASES:
        got = [x["value"] for x in s32pnumbers.find(text)]
        failed += say(got == want, f"番号: 「{text}」→ {want}（実際 {got}）")
    one = s32pnumbers.find("ケースさんのにーよんごです")[0]
    failed += say(one["text"] == "さんのにーよんご" and "ケースさんのにーよんごです"[one["start"]:one["end"]] == one["text"] and one["cue"] is True,
                  "候補に元の字・位置・手がかりが付く")
    lines = [{"text": "さんのにーよんごを見てください", "speaker": "見本アリス"}, {"text": "こんにちは", "speaker": "見本ボブ"}]
    copy = json.loads(json.dumps(lines))
    n = s32pnumbers.annotate(lines)
    failed += say(n == 1 and "numbers" in lines[0] and "numbers" not in lines[1], "候補のある行にだけ numbers")
    failed += say(lines[0]["text"] == copy[0]["text"] and lines[0]["speaker"] == copy[0]["speaker"], "文・話し手は変えない")
    failed += say(len(s32pnumbers.find("さんのにのよんのごのろくのなな" * 5)) <= s32pnumbers.MAX_FOUND, "候補の数の上限")
    return failed


def check_numbers_gate() -> int:
    failed = 0
    base = mother("n1", meetings=MEET)
    lines = [{"text": "さんのにーよんご"}]
    failed += say(s32pwork.add_numbers(lines, base, epoch("13:00"), None) == 0 and "numbers" not in lines[0], "職場の時間でなければ付けない")
    failed += say(s32pwork.add_numbers(lines, base, epoch("10:10"), None) == 1 and "numbers" in lines[0], "会議の窓の中は付ける")
    lines = [{"text": "さんのにーよんご"}]
    failed += say(s32pwork.add_numbers(lines, base, epoch("13:00"), True) == 1, "work の仕事は付ける")
    lines = [{"text": "さんのにーよんご"}]
    off = mother("n2", config={"s32p": {"numbers": False}})
    failed += say(s32pwork.add_numbers(lines, off, None, True) == 0 and "numbers" not in lines[0], "止める切り替え（numbers: false）")
    return failed


def check_hub() -> int:
    failed = 0
    root = Path(__file__).resolve().parent
    hub = (root / "lifelog_pc.py").read_text(encoding="utf-8")
    failed += say("import s32pwork" in hub and "s32pwork.add_hints(" in hub and "s32pwork.add_numbers(" in hub, "lifelog_pc.py: 知7・知8 につないである")
    failed += say("s32pwork.meeting_score" in (root / "s22pc.py").read_text(encoding="utf-8"), "s22pc.py: 知9 につないである")
    failed += say("import s32pwork" not in (root / "s32pnumbers.py").read_text(encoding="utf-8"), "s32pnumbers は純粋（母艦から単体で読める）")
    return failed


CHECKS = [check_meeting, check_hints, check_numbers, check_numbers_gate, check_hub]


def run_all() -> int:
    failed = 0
    for check in CHECKS:
        try:
            failed += check()
        except Exception as error:  # noqa: BLE001
            import traceback

            traceback.print_exc()
            failed += say(False, f"{check.__name__} が途中で落ちました: {error!r}")
    # s33（2026-11-27。担当 p）の確かめも続けて（CI の手順を増やさないため）
    import v33checks_s33p

    failed += v33checks_s33p.run_all()
    return failed


def main() -> int:
    failed = run_all()
    print("ぜんぶ OK" if not failed else f"NG の数: {failed}", flush=True)
    return failed


if __name__ == "__main__":
    sys.exit(main())
