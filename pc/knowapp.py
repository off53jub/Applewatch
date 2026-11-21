"""s18「自分を知ってもらう」の家の PC の口（2026-11-19。番号は母艦に出した 84 案の番号。担当 A）。

母艦（D:\\Lifelog）の作り手（M1 見立て・M3 自信の段）が state/ に置く写しを確かめて返し、アプリの答えを inbox/ に 1 行ずつ足す。
形の決まりは docs/s18-know-me.md（母艦の docs/_incoming/s18-M1.md・s18-M3.md に合わせた）。features の名前は "knowme"。

読む（GET。無い・読めないときは {"available": false, "reason": …}。アプリは空の表示のまま動く）:
- /know/hypotheses ← state/know/hypotheses_for_app.json  AI が記録から立てた見立て（1）。印「見立て（仮）」と根拠つきのものだけ。
  status が expired・confirmed・weakened のものは出さない（答えたものはアプリが隠す）。tier・confidence は省ける（M3）。
- /know/questions  1 日 1 問の束（2。4・8・10・12・13・30 を含む）・見立ての下書き（46）・プロフィールの聞き直し（41 の受け口）・
  自信の低い見立ての確かめ（61）を、聞く順に QUESTION_LIMIT 個まで。答えたもの（inbox/know_answers.jsonl・
  inbox/profile_recheck_answers.jsonl・inbox/app_feedback.jsonl の hypothesis）は二度と出さない（65）。
  飛ばしたもの（skip）はうしろへ回す。アプリは 1 日 1 回、上から 3 問だけ見せる（65）。
- /know/spot-checks ← state/spot_checks_for_app.json  黙って入れたもの（tier auto）の抜き打ち検査（81。M3 が週 5 件選ぶ）。
  答えは POST /feedback の kind "spot"（appfeeds.FEEDBACK。母艦の inbox/app_feedback.jsonl）。
- /know/tiers ← state/tiers_for_app.json  自信の段の表（66。"<出力名>:<item の鍵>" → {tier, confidence, kind, final}）。
送る（POST。母艦の inbox に 1 行足すだけ。"at" はこの PC が付ける。中身の文は記録（log.txt）に書かない）:
- /know/answer      {"id","kind":"question"|"draft"|"hypothesis","value","text"?,"day","by"?} → inbox/know_answers.jsonl（2・46・65）
- /know/recheck     {"id","value":"still"|"changed"|"outdated","note"?} → inbox/profile_recheck_answers.jsonl（41 の聞き直し。M3 の形）
- /know/note        {"day","conversation_start","line_time"?,"text"} → inbox/conversation_notes.jsonl（7「実はこう思ってた」）
- /know/person-goal {"person","pe"?,"text","day"} → inbox/person_goals.jsonl（9「この人とどうなりたいか」。名前は本人が選んだもの）
- /know/why-wrong   {"target","ref"?,"head"?,"reason","why"?,"day"} → inbox/why_wrong.jsonl（42「違う、なぜなら」）
- /know/mark        {"kind","start","end"?,"day","note"?} → inbox/recording_marks.jsonl（4・11・30 の録音の印）
- /know/voice-fix   {"text","said_at","by","near"?} → inbox/voice_fixes.jsonl（63 時計の「違う、〇〇さん」。解釈は P）
- /mood/tap         {"day","at","slot":"morning"|"night","mood"} → inbox/mood_taps.jsonl（6 朝と夜の 1 タップ。夜の 10 秒は前のまま）
"""

from __future__ import annotations

import datetime
import json
import re
from pathlib import Path

import appfeeds

FEATURES = ("knowme",)

HYPOTHESES = Path("state") / "know" / "hypotheses_for_app.json"
DRAFTS = Path("state") / "know" / "drafts_for_app.json"
EXTRA_QUESTIONS = Path("state") / "know" / "questions_for_app.json"
RECHECK = Path("state") / "profile_recheck_for_app.json"  # M3（Build-ProfileFreshness.py）
SPOTS = Path("state") / "spot_checks_for_app.json"  # M3（Build-AutoAudit.py）
TIERS = Path("state") / "tiers_for_app.json"
APP_CONFIG = Path("state") / "know" / "app_config.json"

ANSWERS = Path("inbox") / "know_answers.jsonl"
RECHECK_ANSWERS = Path("inbox") / "profile_recheck_answers.jsonl"
NOTES = Path("inbox") / "conversation_notes.jsonl"
GOALS = Path("inbox") / "person_goals.jsonl"
WHY_WRONG = Path("inbox") / "why_wrong.jsonl"
MARKS = Path("inbox") / "recording_marks.jsonl"
VOICE_FIXES = Path("inbox") / "voice_fixes.jsonl"
MOOD_TAPS = Path("inbox") / "mood_taps.jsonl"

# しきい値（すべて仮。母艦の state/know/app_config.json の同じ名前で上書きできる。docs/s18-know-me.md）
DEFAULTS = {
    "_note": "仮（2026-11-19・A）。直すのは本人かまとめ役",
    # tier が無い見立てを「聞く」にする自信の境目（M3 の tier があればそちらが勝つ）
    "ask_below": 0.6,
    # /know/questions で返す数（アプリが見せるのは 1 日 3 問まで）
    "question_limit": 10,
    # 見立ての画面に出す数（週 3 つ見せる。答えていないものから）
    "hypothesis_limit": 30,
    # 抜き打ち検査の数（週 5 件）
    "spot_limit": 5,
}
HYP_STATUS_SHOWN = ("alive", "unknown", None)
MAKER_SKIP = ("h_names",)
TIERS_ALLOWED = ("auto", "tentative", "ask")
EVIDENCE_LIMIT = 5
ANSWER_KINDS = {"question": ("answered", "skip"), "draft": ("ok", "fixed", "skip"),
                "hypothesis": ("right", "wrong", "unsure")}
RECHECK_VALUES = ("still", "changed", "outdated")
WHY_TARGETS = ("ask", "mother", "hypothesis", "proposal", "brief", "question", "other")
WHY_REASONS = ("fact", "person", "old", "offtopic", "tone", "other")
MARK_KINDS = ("ask_friend", "weekly_talk", "family_childhood", "other")
FIX_BY = ("watch", "app", "notice")
MOOD_SLOTS = ("morning", "night")
ANSWER_BY = ("app", "notice", "watch")
REF = re.compile(r"[0-9A-Za-z_.:|/ -]{1,160}")

# 1 日 1 問の束（2）。記録からは取れないことだけ。id は変えない（答えた印の鍵）。
# group: general（2）・notdo（8）・dislike（10）・respect（12）・adult（13 の 5 場面）・ask_friend（4。録る）・family（30。録る）
# answer: text（文で答える）・record（録って印を付ける）
BUNDLE = (
    ("q-notdo-1", "notdo", "text", "最近「これはもうやらない」と決めたことは何ですか？"),
    ("q-notdo-2", "notdo", "text", "頼まれても断ると決めていることはありますか？"),
    ("q-dislike-1", "dislike", "text", "苦手な食べ物・苦手なものは何ですか？"),
    ("q-dislike-2", "dislike", "text", "言われると嫌な言葉は何ですか？"),
    ("q-dislike-3", "dislike", "text", "苦手なタイプの人は、どんな人ですか？"),
    ("q-respect-1", "respect", "text", "尊敬する人はだれですか？ どこを尊敬していますか？"),
    ("q-respect-2", "respect", "text", "「こうはなりたくない」と思う人はどんな人ですか？ なぜですか？"),
    ("q-adult-1", "adult", "text", "「下から舐められない大人」だと思った場面を 1 つ教えてください（1 つ目）"),
    ("q-adult-2", "adult", "text", "「下から舐められない大人」だと思った場面（2 つ目）"),
    ("q-adult-3", "adult", "text", "「下から舐められない大人」だと思った場面（3 つ目）"),
    ("q-adult-4", "adult", "text", "「下から舐められない大人」だと思った場面（4 つ目）"),
    ("q-adult-5", "adult", "text", "「下から舐められない大人」だと思った場面（5 つ目）"),
    ("q-friend-1", "ask_friend", "record", "親しい人に「俺ってどんな人？」と聞いて、その答えを録ってみませんか"),
    ("q-family-1", "family", "record", "家族に子どもの頃の話を聞いて、録ってみませんか"),
    ("q-general-1", "general", "text", "子どもの頃、何になりたかったですか？"),
    ("q-general-2", "general", "text", "いちばん落ち着くのは、どんな時間ですか？"),
    ("q-general-3", "general", "text", "人に言われていちばんうれしい言葉は何ですか？"),
    ("q-general-4", "general", "text", "お金を使って後悔しなかったものは何ですか？"),
    ("q-general-5", "general", "text", "休みの日、本当はやりたいのにできていないことは？"),
    ("q-general-6", "general", "text", "つい怒ってしまうのは、どんな場面ですか？"),
    ("q-general-7", "general", "text", "迷ったとき、最後は何で決めていますか？"),
    ("q-general-8", "general", "text", "今年いちばん「自分らしかった」と思う日は？"),
)
GROUPS = ("general", "notdo", "dislike", "respect", "adult", "ask_friend", "family", "draft", "recheck", "hypothesis",
          "with_people", "speaker_split")  # s20 次13: 「一緒にいた人」（yesno・根拠つき）・次5: 声が集まりすぎた話し手の確かめ
EXTRA_ANSWERS = ("text", "record", "yesno")


def config(base: Path) -> dict:
    """しきい値（母艦の state/know/app_config.json があれば、その数で上書き。おかしな値は使わない）"""
    out = dict(DEFAULTS)
    try:
        data = json.loads((Path(base) / APP_CONFIG).read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return out
    if isinstance(data, dict):
        for key, value in DEFAULTS.items():
            if key.startswith("_"):
                continue
            got = data.get(key)
            if isinstance(value, float) and appfeeds._num(got, 0, 1) is not None:
                out[key] = float(got)
            elif isinstance(value, int) and appfeeds._int(got, 1, 100) is not None:
                out[key] = got
    return out


def _jsonl(path: Path) -> list[dict]:
    try:
        lines = path.read_text(encoding="utf-8-sig").splitlines()
    except OSError:
        return []
    rows = []
    for line in lines:
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict):
            rows.append(row)
    return rows


def _evidence(value) -> list[dict]:
    """根拠（M1 の {text, when, source, ref} と M3 の {quote, day, conversation_start, line_time, …} のどちらも受ける）"""
    out = []
    for e in (value if isinstance(value, list) else [])[:EVIDENCE_LIMIT * 2]:
        if not isinstance(e, dict):
            continue
        ref = e.get("ref") if isinstance(e.get("ref"), dict) else {}
        text = appfeeds._text(e.get("quote") or e.get("text") or ref.get("quote"), 120)
        if not text:
            continue
        item = {"text": text, "source": appfeeds._text(e.get("source") or ref.get("source"), 20)}
        day = appfeeds._day(e.get("day") or ref.get("day")) or appfeeds._day(str(e.get("when") or "")[:10])
        if day:
            item["day"] = day
        for key in ("conversation_start", "line_time"):
            when = appfeeds._when(e.get(key) or ref.get(key))
            if when:
                item[key] = when
        if isinstance(e.get("ref"), str) and REF.fullmatch(e["ref"]):
            item["ref"] = e["ref"]
        out.append(item)
        if len(out) >= EVIDENCE_LIMIT:
            break
    return out


def _tier(x: dict) -> dict:
    """M3 の自信の段（省ける）"""
    out = {}
    conf = appfeeds._num(x.get("confidence"), 0, 1)
    if conf is not None:
        out["confidence"] = conf
    if x.get("tier") in TIERS_ALLOWED:
        out["tier"] = x["tier"]
    why = appfeeds._text(x.get("tier_why"), 40)
    if why:
        out["tier_why"] = why
    return out


# MARK: - 見立て（1）


def _maker_files(base: Path) -> list[dict]:
    """M1 の作り手ごとのファイル（state/know/h_<種類>.json）の見立て。まとめ（hypotheses_for_app.json）が無いときだけ使う。
    人の評価（private）と、名前の候補（h_names。名前の確定は本人）は読まない"""
    rows = []
    for path in sorted((Path(base) / "state" / "know").glob("h_*.json")):
        if path.stem in MAKER_SKIP:
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8-sig"))
        except (OSError, ValueError):
            continue
        if not isinstance(data, dict) or data.get("private") is True or data.get("stopped") is True \
                or not isinstance(data.get("items"), list):
            continue
        for x in data["items"][:200]:
            if isinstance(x, dict):
                rows.append({**x, "_source": path.stem})
    return rows


def _tier_index(base: Path) -> dict[str, dict]:
    """tiers_for_app.json の見立ての段（"h_<種類>:<id>"・"know_hypotheses:<id>" など → id ごと）"""
    data, failure = appfeeds._load(base, TIERS, "自信の段")
    table = (data or {}).get("items") if not failure else None
    out = {}
    for key, x in (table.items() if isinstance(table, dict) else []):
        if not isinstance(key, str) or ":" not in key or not isinstance(x, dict):
            continue
        source, item_id = key.split(":", 1)
        if (source.startswith("h_") or source.startswith("know")) and x.get("tier") in TIERS_ALLOWED:
            out[item_id] = x
    return out


def _hypotheses(base: Path) -> tuple[list[dict], dict | None]:
    data, failure = appfeeds._load(base, HYPOTHESES, "見立て")
    if failure or data is None or not isinstance(data.get("items"), list):
        listed = _maker_files(base)
        if not listed:
            return [], failure or {"available": False, "reason": "母艦の見立ての形が違います"}
    else:
        listed = data["items"]
    tiers = _tier_index(base)
    items, seen = [], set()
    for x in listed[:400]:
        if not isinstance(x, dict) or x.get("private") is True or x.get("layer") == "fact":
            continue
        hid, text = appfeeds._id(x.get("id")), appfeeds._text(x.get("text"), 200)
        evidence = _evidence(x.get("evidence"))
        status = x.get("status") if isinstance(x.get("status"), str) else None
        if hid is None or hid in seen or not text or not evidence or status not in HYP_STATUS_SHOWN:
            continue  # 根拠の無い見立ては見せない（決まり: 見立てには印と根拠）
        seen.add(hid)
        if "tier" not in x and hid in tiers:
            x = {**x, **{k: tiers[hid][k] for k in ("tier", "confidence", "tier_why") if k in tiers[hid]}}
        item = {"id": hid, "kind": appfeeds._text(x.get("kind") or x.get("tier_kind"), 40), "label": "見立て（仮）",
                "text": text, "why": appfeeds._text(x.get("why"), 200), "evidence": evidence,
                "made_on": appfeeds._day(x.get("made_on")) or appfeeds._day(str(x.get("created") or "")[:10]),
                "recheck_by": appfeeds._day(x.get("recheck_by") or x.get("review_by")), **_tier(x)}
        draft = appfeeds._text(x.get("draft"), 400)
        if draft:
            item["draft"] = draft
        items.append(item)
    return items, None


def read_hypotheses(base: Path) -> dict:
    items, failure = _hypotheses(base)
    if failure:
        return failure
    limit = config(base)["hypothesis_limit"]
    return {"available": True, "items": items[:limit]}


# MARK: - 1 日 1 問（2・46・61・65）


def answered_ids(base: Path) -> tuple[set[str], set[str]]:
    """(答えたもの, 飛ばしたもの)。同じ id は at の新しい 1 行で決める"""
    latest: dict[str, tuple[str, str]] = {}
    for row in _jsonl(Path(base) / ANSWERS):
        rid = appfeeds._id(row.get("id"))
        if rid is None:
            continue
        at = str(row.get("at") or "")
        if rid not in latest or at >= latest[rid][0]:
            latest[rid] = (at, str(row.get("value") or ""))
    done = {rid for rid, (_, value) in latest.items() if value != "skip"}
    skipped = {rid for rid, (_, value) in latest.items() if value == "skip"}
    for row in _jsonl(Path(base) / RECHECK_ANSWERS):
        rid = appfeeds._id(row.get("id"))
        if rid is not None and row.get("value") in RECHECK_VALUES:
            done.add(rid)
    for row in _jsonl(Path(base) / appfeeds.FEEDBACK_FILE):
        rid = appfeeds._id(row.get("id"))
        if rid is not None and row.get("kind") == "hypothesis":
            done.add(rid)
    return done, skipped - done


def _drafts(base: Path) -> dict[str, dict]:
    """問いの id → 下書き（46）。下書きの無い問いは本人が書く"""
    data, failure = appfeeds._load(base, DRAFTS, "答えの下書き")
    if failure or data is None or not isinstance(data.get("items"), list):
        return {}
    out = {}
    for x in data["items"][:400]:
        if not isinstance(x, dict):
            continue
        qid = appfeeds._id(x.get("question_id") or x.get("id"))
        draft = appfeeds._text(x.get("draft"), 400)
        if qid and draft and qid not in out:
            out[qid] = {"draft": draft, "draft_evidence": _evidence(x.get("evidence")), **_tier(x)}
    return out


def _extra_questions(base: Path) -> list[dict]:
    """母艦が足す問い（state/know/questions_for_app.json。M1 の下書きつきの問いなど。無ければ空）"""
    data, failure = appfeeds._load(base, EXTRA_QUESTIONS, "問い")
    if failure or data is None or not isinstance(data.get("items"), list):
        return []
    out = []
    for x in data["items"][:200]:
        if not isinstance(x, dict):
            continue
        qid, text = appfeeds._id(x.get("id")), appfeeds._text(x.get("text") or x.get("question"), 160)
        group = x.get("group") if x.get("group") in GROUPS else "general"
        expires = appfeeds._day(x.get("expires"))
        if expires and expires < datetime.date.today().isoformat():
            continue  # 14 日で流れる（s20 次3・体15。期限を過ぎた問いは出さない）
        answer = x.get("answer") if x.get("answer") in EXTRA_ANSWERS else "text"
        if qid and text:
            item = {"id": qid, "group": group, "answer": answer, "text": text,
                    "draft": appfeeds._text(x.get("draft"), 400), "draft_evidence": _evidence(x.get("evidence")),
                    **_tier(x)}
            if answer == "yesno":
                # s20 次13: はい・いいえで答える問い（「一緒にいた人」など）は、根拠を evidence のまま通す（アプリが 1 タップで見せる）
                item["evidence"] = item.pop("draft_evidence")
                item["label"] = "見立て（仮）"
            if expires:
                item["expires"] = expires
            out.append(item)
    return out


def _rechecks(base: Path) -> list[dict]:
    """プロフィールの古い項目の聞き直し（41。M3 が作る。無ければ空）。答えは POST /know/recheck"""
    data, failure = appfeeds._load(base, RECHECK, "プロフィールの聞き直し")
    if failure or data is None or not isinstance(data.get("items"), list):
        return []
    out = []
    for x in data["items"][:50]:
        if not isinstance(x, dict):
            continue
        if x.get("answered") is True:
            continue
        qid = appfeeds._id(x.get("id"))
        text = appfeeds._text(x.get("question") or x.get("text"), 160)
        current = appfeeds._text(x.get("current") or (x.get("text") if x.get("question") else None), 200)
        if qid and text:
            out.append({"id": qid, "group": "recheck", "answer": "recheck", "text": text, "current": current,
                        "checked_on": appfeeds._day(x.get("checked_on") or x.get("confirmed_on") or x.get("last_checked"))})
    return out


def read_questions(base: Path, today: datetime.date | None = None) -> dict:
    """聞く順: 自信の低い見立ての確かめ（61）・聞き直し（41）・母艦の問い・束（2）の 4 列から順に 1 つずつ。答えたものは出さない（65）"""
    cfg = config(base)
    done, skipped = answered_ids(base)
    drafts = _drafts(base)
    hyps, _ = _hypotheses(base)
    asks = []
    for h in hyps:
        tier = h.get("tier")
        conf = h.get("confidence")
        ask = tier == "ask" or (tier is None and conf is not None and conf < cfg["ask_below"])
        if ask:
            asks.append({"id": h["id"], "group": "hypothesis", "answer": "yesno", "text": h["text"],
                         "label": "見立て（仮）", "evidence": h["evidence"],
                         **{k: h[k] for k in ("confidence", "tier", "tier_why") if k in h}})
    bundle = [{"id": qid, "group": group, "answer": answer, "text": text} for qid, group, answer, text in BUNDLE]
    # 4 つの列（見立ての確かめ・聞き直し・母艦の問い・束）から 1 つずつ順に取る（見立てだけで 1 日の 3 問が埋まらないように）
    lanes, seen = [], set()
    for lane in (asks, _rechecks(base), _extra_questions(base), bundle):
        kept = []
        for q in lane:
            if q["id"] in seen or q["id"] in done:
                continue
            seen.add(q["id"])
            if q["id"] in drafts and not q.get("draft"):
                q.update(drafts[q["id"]])
            kept.append({k: v for k, v in q.items() if v not in ("", None, [])})
        # 飛ばしたものは、その列のうしろへ（順番は保つ）
        lanes.append([q for q in kept if q["id"] not in skipped] + [q for q in kept if q["id"] in skipped])
    out = []
    while any(lanes):
        for lane in lanes:
            if lane:
                out.append(lane.pop(0))
    return {"available": True, "day": (today or datetime.date.today()).isoformat(), "per_day": 3,
            "answered": len(done), "items": out[:cfg["question_limit"]]}


# MARK: - 抜き打ち検査（81）と自信の段（66）


def read_spot_checks(base: Path) -> dict:
    """M3 の形 {"weeks": [{"week", "items": [{id, kind, day, question, before, after, ref}]}]}（いちばん新しい週）か、
    {"week", "items": [{id, kind, claim, day, evidence, note}]}"""
    data, failure = appfeeds._load(base, SPOTS, "抜き打ち検査")
    week, listed = None, None
    if data is not None and isinstance(data.get("weeks"), list):
        weeks = [w for w in data["weeks"] if isinstance(w, dict) and isinstance(w.get("items"), list)
                 and isinstance(w.get("week"), str) and appfeeds.WEEK.fullmatch(w["week"])]
        if weeks:
            latest = max(weeks, key=lambda w: w["week"])
            week, listed = latest["week"], latest["items"]
    elif data is not None and isinstance(data.get("items"), list):
        week, listed = data.get("week"), data["items"]
    if failure or listed is None:
        return failure or {"available": False, "reason": "母艦の抜き打ち検査の形が違います"}
    items, seen = [], set()
    for x in listed[:100]:
        if not isinstance(x, dict):
            continue
        sid = appfeeds._id(x.get("id"))
        claim = appfeeds._text(x.get("question") or x.get("claim") or x.get("text"), 160)
        if sid is None or sid in seen or not claim:
            continue
        seen.add(sid)
        evidence = _evidence(x.get("evidence"))
        if not evidence and isinstance(x.get("ref"), dict):
            evidence = _evidence([{**x["ref"], "quote": x.get("after") or x.get("before") or claim}])
        note = appfeeds._text(x.get("note") or x.get("why"), 120)
        if not note and isinstance(x.get("before"), str) and x.get("before") != x.get("after"):
            note = "直す前: " + appfeeds._text(x["before"], 100)
        items.append({"id": sid, "kind": appfeeds._text(x.get("kind") or x.get("tier_kind"), 40), "claim": claim,
                      "day": appfeeds._day(x.get("day")), "evidence": evidence, "note": note})
    return {"available": True, "week": appfeeds._text(week, 10), "items": items[:config(base)["spot_limit"]]}


def read_tiers(base: Path) -> dict:
    data, failure = appfeeds._load(base, TIERS, "自信の段")
    if failure or data is None:
        return failure or {"available": False, "reason": "母艦の自信の段の形が違います"}
    table = data.get("items") if isinstance(data.get("items"), dict) else data
    out = {}
    for key, x in list(table.items())[:20000] if isinstance(table, dict) else []:
        if not isinstance(key, str) or len(key) > 200 or not isinstance(x, dict) or x.get("tier") not in TIERS_ALLOWED:
            continue
        row = {"tier": x["tier"]}
        conf = appfeeds._num(x.get("confidence"), 0, 1)
        if conf is not None:
            row["confidence"] = conf
        if isinstance(x.get("final"), bool):
            row["final"] = x["final"]
        kind = appfeeds._text(x.get("kind"), 40)
        if kind:
            row["kind"] = kind
        out[key] = row
    return {"available": True, "items": out}


# MARK: - 送る（1 行足すだけ）


def _need_day(body: dict) -> str:
    day = appfeeds._day(body.get("day"))
    if day is None:
        raise ValueError("day は YYYY-MM-DD です")
    return day


def _need_text(body: dict, key: str, n: int, required: bool = True) -> str:
    value = body.get(key)
    if value is None and not required:
        return ""
    if not isinstance(value, str) or len(value) > n * 2:
        raise ValueError(f"{key} は {n} 文字までの文です")
    text = appfeeds._text(value, n)
    if required and not text:
        raise ValueError(f"{key} が空です")
    return text


def _need_when(body: dict, key: str, required: bool = True) -> str | None:
    value = body.get(key)
    if value is None and not required:
        return None
    when = appfeeds._when(value)
    if when is None:
        raise ValueError(f"{key} は ISO 8601 の日時です")
    return when


def parse_answer(data: bytes) -> dict:
    body = appfeeds._json_body(data)
    rid, kind = appfeeds._id(body.get("id")), body.get("kind")
    if rid is None:
        raise ValueError("id は英数字と _ . : - で 64 文字までです")
    if kind not in ANSWER_KINDS:
        raise ValueError("kind は " + "・".join(ANSWER_KINDS) + " のどれかです")
    if body.get("value") not in ANSWER_KINDS[kind]:
        raise ValueError(f"{kind} の value は " + "・".join(ANSWER_KINDS[kind]) + " のどれかです")
    row = {"id": rid, "kind": kind, "value": body["value"], "day": _need_day(body)}
    text = _need_text(body, "text", 1000, required=False)
    if body["value"] in ("answered", "fixed") and not text:
        raise ValueError("答えの文が空です")
    if text:
        row["text"] = text
    group = body.get("group")
    if group in GROUPS:
        row["group"] = group
    question = _need_text(body, "question", 160, required=False)
    if question:
        row["question"] = question  # 束の問いの文が後で変わっても、何に答えたか分かるように
    row["by"] = body.get("by") if body.get("by") in ANSWER_BY else "app"
    return row


def parse_recheck(data: bytes) -> dict:
    body = appfeeds._json_body(data)
    rid = appfeeds._id(body.get("id"))
    if rid is None:
        raise ValueError("id は英数字と _ . : - で 64 文字までです")
    if body.get("value") not in RECHECK_VALUES:
        raise ValueError("value は " + "・".join(RECHECK_VALUES) + " のどれかです")
    return {"id": rid, "value": body["value"], "note": _need_text(body, "note", 400, required=False)}


def parse_note(data: bytes) -> dict:
    body = appfeeds._json_body(data)
    row = {"day": _need_day(body), "conversation_start": _need_when(body, "conversation_start"),
           "text": _need_text(body, "text", 400)}
    line = _need_when(body, "line_time", required=False)
    if line:
        row["line_time"] = line
    return row


def parse_goal(data: bytes) -> dict:
    body = appfeeds._json_body(data)
    row = {"day": _need_day(body), "person": _need_text(body, "person", 40), "text": _need_text(body, "text", 200)}
    pe = appfeeds._id(body.get("pe"))
    if pe:
        row["pe"] = pe
    return row


def parse_why_wrong(data: bytes) -> dict:
    body = appfeeds._json_body(data)
    if body.get("target") not in WHY_TARGETS:
        raise ValueError("target は " + "・".join(WHY_TARGETS) + " のどれかです")
    if body.get("reason") not in WHY_REASONS:
        raise ValueError("reason は " + "・".join(WHY_REASONS) + " のどれかです")
    row = {"day": _need_day(body), "target": body["target"], "reason": body["reason"],
           "why": _need_text(body, "why", 400, required=False), "head": _need_text(body, "head", 120, required=False),
           "question": _need_text(body, "question", 200, required=False)}
    ref = body.get("ref")
    if isinstance(ref, str) and REF.fullmatch(ref):
        row["ref"] = ref
    return {k: v for k, v in row.items() if v != ""}


def parse_mark(data: bytes) -> dict:
    body = appfeeds._json_body(data)
    if body.get("kind") not in MARK_KINDS:
        raise ValueError("kind は " + "・".join(MARK_KINDS) + " のどれかです")
    start = _need_when(body, "start")
    end = _need_when(body, "end", required=False)
    row = {"day": _need_day(body), "kind": body["kind"], "start": start}
    if end:
        a, b = appfeeds._moment(start), appfeeds._moment(end)
        if a is None or b is None or b <= a or (b - a).total_seconds() > 6 * 3600:
            raise ValueError("end は start のあと 6 時間までです")
        row["end"] = end
    note = _need_text(body, "note", 200, required=False)
    if note:
        row["note"] = note
    qid = appfeeds._id(body.get("question_id"))
    if qid:
        row["question_id"] = qid
    return row


def parse_voice_fix(data: bytes) -> dict:
    """時計の「違う、〇〇さん」。言葉はそのまま渡す（解釈は家の PC の担当 P）"""
    body = appfeeds._json_body(data)
    row = {"text": _need_text(body, "text", 200), "said_at": _need_when(body, "said_at"),
           "by": body.get("by") if body.get("by") in FIX_BY else "watch"}
    near = body.get("near")
    if isinstance(near, dict):
        got = {}
        for key in ("conversation_start", "line_time"):
            when = appfeeds._when(near.get(key))
            if when:
                got[key] = when
        for key, n in (("speaker", 40), ("text_head", 60), ("audio", 120)):
            text = appfeeds._text(near.get(key), n)
            if text:
                got[key] = text
        if got:
            row["near"] = got
    return row


def parse_mood_tap(data: bytes) -> dict:
    body = appfeeds._json_body(data)
    if body.get("slot") not in MOOD_SLOTS:
        raise ValueError("slot は morning・night のどちらかです")
    if appfeeds._int(body.get("mood"), 1, 5) is None:
        raise ValueError("mood は 1〜5 の整数です")
    return {"day": _need_day(body), "at": _need_when(body, "at"), "slot": body["slot"], "mood": body["mood"]}


def _post(parse, rel: Path, label: str, detail=None, add_at: bool = True):
    def handle(handler, base: Path, data: bytes, log) -> None:
        appfeeds._http_inbox(handler, base, data, log, parse, rel, label, add_at, detail)
    return handle


POSTS = {
    "/know/answer": _post(parse_answer, ANSWERS, "自分を知る問いの答え", lambda r: f"{r['kind']} {r['value']}"),
    "/know/recheck": _post(parse_recheck, RECHECK_ANSWERS, "プロフィールの聞き直しの答え", lambda r: r["value"]),
    "/know/note": _post(parse_note, NOTES, "会話への一言"),
    "/know/person-goal": _post(parse_goal, GOALS, "人ごとのなりたい形"),
    "/know/why-wrong": _post(parse_why_wrong, WHY_WRONG, "「違う、なぜなら」", lambda r: f"{r['target']} {r['reason']}"),
    "/know/mark": _post(parse_mark, MARKS, "録音の印", lambda r: r["kind"]),
    "/know/voice-fix": _post(parse_voice_fix, VOICE_FIXES, "声での直し", lambda r: r["by"]),
    "/mood/tap": _post(parse_mood_tap, MOOD_TAPS, "気分の 1 タップ", lambda r: r["slot"], add_at=False),
}
READERS = {"/know/hypotheses": read_hypotheses, "/know/questions": read_questions,
           "/know/spot-checks": read_spot_checks, "/know/tiers": read_tiers}
