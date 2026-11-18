"""2026-11-19（s18「自分を知ってもらう」。担当 A。docs/s18-know-me.md）: 家の PC の口 knowme.py を確かめる。

    python pc/v21checks_knowme.py

本物の母艦・iPhone は使わない（一時フォルダに作り物の母艦を作る）。例の名前・文は全部作り物。確かめること:
- 写しが無いときは available false（アプリは空の表示で動く）
- 見立て: 根拠の無いもの・private・事実・expired は出さない。印「見立て（仮）」を付ける。M1 と M3 の根拠の形のどちらも読む
- 1 日 1 問: 自信の低い見立て（tier ask か、tier が無くて confidence が境目より下）→ 聞き直し → 母艦の問い → 束の順。
  答えたものは二度と出さない・飛ばしたものはうしろ・下書きが付く・数の上限
- 抜き打ち・自信の段の表を読む（おかしな行は落とす）
- POST: 正しい形だけ inbox に 1 行足す（at は PC が付ける。気分の 1 タップは送った時刻のまま）。おかしな形は 400 で、何も足さない
- /feedback の kind に hypothesis・spot が足されている。mothership の GETS・POSTS に入っている。features に knowme
"""

from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import appfeeds  # noqa: E402
import knowme  # noqa: E402
from v6checks import say  # noqa: E402


class FakeHandler:
    client_address = ("127.0.0.1", 0)

    def __init__(self) -> None:
        self.status = None
        self.body = None

    def send_json(self, status: int, body: dict) -> None:
        self.status, self.body = status, body


def post(base: Path, path: str, body) -> tuple[int, dict]:
    handler = FakeHandler()
    data = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode("utf-8")
    knowme.POSTS[path](handler, base, data, lambda _: None)
    return handler.status, handler.body


def lines(base: Path, rel: Path) -> list[dict]:
    try:
        return [json.loads(x) for x in (base / rel).read_text(encoding="utf-8").splitlines() if x.strip()]
    except OSError:
        return []


def write(base: Path, rel: Path, data) -> None:
    path = base / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")


def check_empty(base: Path) -> int:
    failed = 0
    for path, reader in knowme.READERS.items():
        got = reader(base)
        if path == "/know/questions":
            failed += say(got["available"] and len(got["items"]) == knowme.DEFAULTS["question_limit"]
                          and got["items"][0]["id"] == knowme.BUNDLE[0][0],
                          f"写しが無くても 1 日 1 問は束から出す（{len(got['items'])} 個）")
        else:
            failed += say(got.get("available") is False and bool(got.get("reason")), f"{path} は写しが無ければ available false")
    return failed


def make_mother(base: Path) -> None:
    ev = [{"text": "あの店はもう行かないって言ってた", "when": "2026-11-17T12:00:00+09:00", "source": "conversation",
           "ref": "conv:2026-11-17T12:00"}]
    ev3 = [{"quote": "朝は静かなほうがいい", "day": "2026-11-18", "conversation_start": "2026-11-18T07:34:10+09:00",
            "line_time": "2026-11-18T07:35:02+09:00", "source": "app"}]
    write(base, knowme.HYPOTHESES, {"version": 1, "items": [
        {"id": "h-a1", "kind": "hypothesis.taste", "text": "朝は人と話すより一人で準備したい人", "evidence": ev3,
         "made_on": "2026-11-18", "recheck_by": "2027-02-16", "status": "alive", "tier": "tentative", "confidence": 0.7},
        {"id": "h-a2", "kind": "hypothesis.notdo", "text": "同じ店に二度行かないと決めることがある", "evidence": ev,
         "created": "2026-11-17", "review_by": "2027-02-15", "confidence": 0.4},
        {"id": "h-a3", "text": "根拠の無い見立て", "evidence": []},
        {"id": "h-a4", "text": "人の評価の見立て", "evidence": ev, "private": True},
        {"id": "h-a5", "text": "期限の過ぎた見立て", "evidence": ev, "status": "expired"},
        {"id": "h-a6", "text": "本人が聞かれるべき見立て", "evidence": ev, "tier": "ask"},
        {"id": "h-a7", "text": "事実", "evidence": ev, "layer": "fact"},
        {"id": "h-a1", "text": "同じ id の二つ目", "evidence": ev},
        "壊れた行"]})
    write(base, knowme.DRAFTS, {"items": [{"question_id": "q-dislike-1", "draft": "辛すぎるもの（たぶん）",
                                           "evidence": ev, "confidence": 0.5}]})
    write(base, knowme.RECHECK, {"items": [{"id": "pr-1", "question": "いまも朝型ですか？", "current": "朝型",
                                            "checked_on": "2026-08-01"}]})
    write(base, knowme.EXTRA_QUESTIONS, {"items": [{"id": "mq-1", "group": "notdo", "text": "会話で断っていた〇〇は、やらないと決めたこと？",
                                                    "draft": "はい（仮）"}]})
    write(base, knowme.SPOTS, {"week": "2026-W47", "items": [
        {"id": "sp-1", "kind": "place", "claim": "11/18 の昼はさくら食堂にいた", "day": "2026-11-18", "evidence": ev3},
        {"id": "sp-2", "claim": ""}, {"id": "sp-1", "claim": "重なり"}]})
    write(base, knowme.TIERS, {"speaker_doubts_for_app.json:abc": {"tier": "auto", "confidence": 0.95, "final": True},
                               "x:y": {"tier": "maybe"}})


def check_reads(base: Path) -> int:
    failed = 0
    got = knowme.read_hypotheses(base)
    ids = [i["id"] for i in got["items"]]
    failed += say(ids == ["h-a1", "h-a2", "h-a6"], f"見せる見立ては根拠つき・private と事実と期限切れは出さない: {ids}")
    first = got["items"][0]
    failed += say(first["label"] == "見立て（仮）" and first["evidence"][0].get("conversation_start") and first["tier"] == "tentative",
                  "見立てに印・根拠の会話の鍵・段が付く（M3 の形）")
    second = got["items"][1]
    failed += say(second["made_on"] == "2026-11-17" and second["recheck_by"] == "2027-02-15"
                  and second["evidence"][0]["day"] == "2026-11-17" and second["evidence"][0]["ref"] == "conv:2026-11-17T12:00",
                  "M1 の形（created・review_by・when・ref）も読む")
    q = knowme.read_questions(base)
    order = [i["id"] for i in q["items"]]
    failed += say(order[:5] == ["h-a2", "pr-1", "mq-1", "q-notdo-1", "h-a6"],
                  f"4 列（自信の低い見立て・聞き直し・母艦の問い・束）から順に 1 つずつ: {order[:5]}")
    failed += say("h-a1" not in order, "仮の段（tentative）の見立ては聞かない（61）")
    dislike = next(i for i in q["items"] if i["id"] == "q-dislike-1") if "q-dislike-1" in order else None
    failed += say(dislike is None or dislike.get("draft") == "辛すぎるもの（たぶん）", "束の問いに下書きが付く（46）")
    failed += say(len(order) == knowme.DEFAULTS["question_limit"] and q["per_day"] == 3, "返す数は上限まで・1 日 3 問")
    spots = knowme.read_spot_checks(base)
    failed += say([i["id"] for i in spots["items"]] == ["sp-1"] and spots["week"] == "2026-W47", "抜き打ちを読む（空・重なりは落とす）")
    tiers = knowme.read_tiers(base)
    failed += say(list(tiers["items"]) == ["speaker_doubts_for_app.json:abc"] and tiers["items"]["speaker_doubts_for_app.json:abc"]["final"],
                  "自信の段の表を読む（おかしな段は落とす）")
    return failed


def check_answers(base: Path) -> int:
    failed = 0
    status, _ = post(base, "/know/answer", {"id": "h-a2", "kind": "hypothesis", "value": "right", "day": "2026-11-19"})
    failed += say(status == 200, "見立ての確かめに答える")
    status, _ = post(base, "/know/answer", {"id": "q-notdo-1", "kind": "question", "value": "answered", "day": "2026-11-19",
                                            "text": "夜ふかしはもうしない", "group": "notdo", "question": "最近やらないと決めたことは？"})
    failed += say(status == 200, "束の問いに文で答える")
    status, _ = post(base, "/know/answer", {"id": "q-dislike-1", "kind": "draft", "value": "ok", "day": "2026-11-19"})
    failed += say(status == 200, "下書きのままで良いと答える（46）")
    status, _ = post(base, "/know/answer", {"id": "q-notdo-2", "kind": "question", "value": "skip", "day": "2026-11-19"})
    failed += say(status == 200, "今日は飛ばす")
    status, _ = post(base, "/know/recheck", {"id": "mq-1", "value": "still"})
    failed += say(status == 200, "聞き直しに答える（M3 の inbox/profile_recheck_answers.jsonl）")
    for bad in ({"id": "q-1", "kind": "question", "value": "answered", "day": "2026-11-19"},  # 文が空
                {"id": "q 1", "kind": "question", "value": "skip", "day": "2026-11-19"},
                {"id": "q-1", "kind": "nope", "value": "skip", "day": "2026-11-19"},
                {"id": "q-1", "kind": "hypothesis", "value": "yes", "day": "2026-11-19"},
                {"id": "q-1", "kind": "question", "value": "skip", "day": "2026-13-40"}, b"not json"):
        status, body = post(base, "/know/answer", bad)
        failed += say(status == 400 and body.get("error"), f"おかしな答えは断る: {body.get('error')}")
    rows = lines(base, knowme.ANSWERS)
    failed += say(len(rows) == 4 and all(r.get("at") for r in rows) and rows[1]["text"] == "夜ふかしはもうしない"
                  and rows[1]["by"] == "app" and rows[1]["question"], f"答えは 4 行だけ・at が付く（{len(rows)} 行）")
    q = knowme.read_questions(base)
    order = [i["id"] for i in q["items"]]
    failed += say("h-a2" not in order and "q-notdo-1" not in order and "q-dislike-1" not in order and "mq-1" not in order,
                  "答えたものは二度と聞かない（65）")
    bundle_order = [i for i in order if i.startswith("q-")]
    failed += say(bundle_order[:2] == ["q-dislike-2", "q-dislike-3"] and "q-notdo-2" not in bundle_order[:5],
                  f"飛ばしたものは、その列のうしろへ: {order}")
    failed += say(q["answered"] == 4, f"答えた数を返す（{q['answered']}）")
    # /feedback の kind hypothesis で答えた見立ても聞かない
    appfeeds.append_inbox(base, appfeeds.FEEDBACK_FILE, {"kind": "hypothesis", "id": "h-a6", "value": "wrong",
                                                         "day": "2026-11-19", "at": "2026-11-19T10:00:00+09:00"})
    failed += say("h-a6" not in [i["id"] for i in knowme.read_questions(base)["items"]], "○× の答え（/feedback）も答えた印にする")
    return failed


def check_posts(base: Path) -> int:
    failed = 0
    cases = [
        ("/know/note", {"day": "2026-11-18", "conversation_start": "2026-11-18T07:34:10+09:00", "text": "実は早く帰りたかった"},
         knowme.NOTES),
        ("/know/person-goal", {"day": "2026-11-19", "person": "人物A", "pe": "pe_0001", "text": "月に一度は話したい"}, knowme.GOALS),
        ("/know/why-wrong", {"day": "2026-11-19", "target": "ask", "reason": "fact", "why": "その日は休みだった",
                             "head": "11/18 は会議に出ていました"}, knowme.WHY_WRONG),
        ("/know/mark", {"day": "2026-11-19", "kind": "weekly_talk", "start": "2026-11-19T20:00:00+09:00",
                        "end": "2026-11-19T20:05:30+09:00"}, knowme.MARKS),
        ("/know/voice-fix", {"text": "違う、人物Bさん", "said_at": "2026-11-19T10:02:00+09:00", "by": "watch",
                             "near": {"conversation_start": "2026-11-19T09:50:00+09:00", "speaker": "人物C",
                                      "text_head": "それでいいと思います"}}, knowme.VOICE_FIXES),
        ("/mood/tap", {"day": "2026-11-19", "at": "2026-11-19T07:10:00+09:00", "slot": "morning", "mood": 4}, knowme.MOOD_TAPS),
    ]
    for path, body, rel in cases:
        status, _ = post(base, path, body)
        rows = lines(base, rel)
        failed += say(status == 200 and len(rows) == 1, f"{path} は inbox/{rel.name} に 1 行足す")
    mood = lines(base, knowme.MOOD_TAPS)[0]
    failed += say(mood["at"] == "2026-11-19T07:10:00+09:00", "気分の 1 タップは押した時刻のまま")
    fix = lines(base, knowme.VOICE_FIXES)[0]
    failed += say(fix["text"] == "違う、人物Bさん" and fix["near"]["speaker"] == "人物C" and fix["at"], "声での直しは言葉をそのまま渡す（P が読む）")
    bads = [
        ("/know/note", {"day": "2026-11-18", "conversation_start": "きのう", "text": "x"}),
        ("/know/person-goal", {"day": "2026-11-19", "person": "", "text": "x"}),
        ("/know/why-wrong", {"day": "2026-11-19", "target": "ask", "reason": "なんとなく"}),
        ("/know/mark", {"day": "2026-11-19", "kind": "weekly_talk", "start": "2026-11-19T20:00:00+09:00",
                        "end": "2026-11-19T19:00:00+09:00"}),
        ("/know/voice-fix", {"text": "", "said_at": "2026-11-19T10:02:00+09:00"}),
        ("/mood/tap", {"day": "2026-11-19", "at": "2026-11-19T07:10:00+09:00", "slot": "noon", "mood": 4}),
        ("/mood/tap", {"day": "2026-11-19", "at": "2026-11-19T07:10:00+09:00", "slot": "morning", "mood": 6}),
    ]
    for path, body in bads:
        status, err = post(base, path, body)
        failed += say(status == 400, f"{path} のおかしな形は断る: {err.get('error')}")
    failed += say(len(lines(base, knowme.MARKS)) == 1 and len(lines(base, knowme.MOOD_TAPS)) == 1, "断ったものは足さない")
    return failed


def check_wiring() -> int:
    import mothership

    failed = 0
    failed += say(all(p in mothership.GETS for p in knowme.READERS) and all(p in mothership.POSTS for p in knowme.POSTS),
                  "mothership の GETS・POSTS に入っている")
    failed += say(appfeeds.FEEDBACK.get("spot") == ("right", "wrong", "unsure")
                  and appfeeds.FEEDBACK.get("hypothesis") == ("right", "wrong", "unsure"),
                  "/feedback の kind に spot（81）と hypothesis（1）")
    source = (Path(__file__).resolve().parent / "lifelog_pc.py").read_text(encoding="utf-8")
    failed += say("mothership.knowme.FEATURES" in source, "features に knowme を足している")
    return failed


def check_m3_shapes(tmp: Path) -> int:
    """M3 が 2026-11-19 に置いた形（週ごとの抜き打ち・聞き直し・段の表）と、M1 の作り手ごとのファイル"""
    failed = 0
    base = tmp / "m3"
    ref = {"day": "2026-11-17", "conversation_start": "2026-11-17T21:17:21+09:00", "line_time": "2026-11-17T21:17:21+09:00",
           "audio": "20261117-211717-w.m4a", "offset": 4.8, "source": "app"}
    write(base, knowme.SPOTS, {"version": 1, "weeks": [
        {"week": "2026-W46", "items": [{"id": "sp-old", "question": "古い週"}]},
        {"week": "2026-W47", "items": [{"id": "sp-2026-W47-1", "kind": "text", "day": "2026-11-17",
                                        "question": "機械が直したこの文は合っていますか", "before": "直す前の文", "after": "直した文",
                                        "ref": ref}]}]})
    spots = knowme.read_spot_checks(base)
    first = spots["items"][0] if spots.get("items") else {}
    failed += say(spots.get("week") == "2026-W47" and first.get("id") == "sp-2026-W47-1"
                  and first["evidence"][0]["conversation_start"] == ref["conversation_start"] and first["note"].startswith("直す前"),
                  "M3 の週ごとの抜き打ち（いちばん新しい週・元の会話の鍵・直す前の文）")
    write(base, knowme.RECHECK, {"version": 1, "items": [
        {"id": "pf-1", "section": "1. 基本", "text": "- 朝型", "confirmed_on": "2026-09-05", "question": "「- 朝型」は今も合っていますか",
         "answered": False},
        {"id": "pf-2", "text": "- 答えた", "question": "答えた問い", "answered": True}]})
    write(base, Path("state") / "know" / "h_taste.json", {"kind": "taste", "private": False, "items": [
        {"id": "h-t1", "kind": "hypothesis.taste", "text": "作り物の食べ物が好き", "layer": "hypothesis", "status": "alive",
         "evidence": [{"quote": "おいしい", "day": "2026-11-17", "ref": "records:2026-11-17 19:20"}]}]})
    write(base, Path("state") / "know" / "h_names.json", {"items": [
        {"id": "h-n1", "text": "名前の候補（出さない）", "evidence": [{"quote": "x", "day": "2026-11-17"}]}]})
    write(base, Path("state") / "know" / "h_people.json", {"private": True, "items": [
        {"id": "h-p1", "text": "人の評価（出さない）", "evidence": [{"quote": "x", "day": "2026-11-17"}]}]})
    write(base, knowme.TIERS, {"items": {"h_taste:h-t1": {"kind": "hypothesis.taste", "confidence": 0.3, "tier": "ask"}}})
    hyps = knowme.read_hypotheses(base)
    failed += say([h["id"] for h in hyps.get("items", [])] == ["h-t1"] and hyps["items"][0]["tier"] == "ask"
                  and hyps["items"][0]["evidence"][0]["ref"] == "records:2026-11-17 19:20",
                  "まとめが無いときは M1 の作り手ごとのファイルを読む（名前の候補・人の評価は読まない）。段は表から補う")
    order = [q["id"] for q in knowme.read_questions(base)["items"]]
    failed += say(order[:2] == ["h-t1", "pf-1"] and "pf-2" not in order,
                  f"段が ask の見立て → 聞き直し（答えた印のものは出さない）: {order[:3]}")
    recheck = next(q for q in knowme.read_questions(base)["items"] if q["id"] == "pf-1")
    failed += say(recheck["current"] == "- 朝型" and recheck["checked_on"] == "2026-09-05", "聞き直しに今の書き方と確かめた日")
    return failed


def check_config(base: Path) -> int:
    write(base, knowme.APP_CONFIG, {"ask_below": 0.3, "question_limit": 5, "spot_limit": "多め"})
    cfg = knowme.config(base)
    return say(cfg["ask_below"] == 0.3 and cfg["question_limit"] == 5 and cfg["spot_limit"] == 5,
               "しきい値（仮）は母艦の app_config.json で上書きでき、おかしな値は使わない")


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        empty = Path(tmp) / "empty"
        empty.mkdir()
        base = Path(tmp) / "mother"
        base.mkdir()
        failed = check_empty(empty)
        make_mother(base)
        failed += check_reads(base) + check_answers(base) + check_posts(base) + check_wiring() + check_config(base)
        failed += check_m3_shapes(Path(tmp))
    print("ぜんぶ OK" if not failed else f"NG が {failed} 個")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
