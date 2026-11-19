"""2026-11-19（s18「自分を知ってもらう」の家の PC の分。docs/s18-know-me-pc.md）を確かめる。

    python pc/v21checks_knowme.py

本物の HOME・母艦・Claude・iPhone は使わない（一時フォルダに作り物の記録と母艦を作る。Claude は作り物の相手）。
例に使う名前は全部作り物（話し手は「甲」「乙」「丙」）。確かめること:
- voicetone（45・78）: 速さ・間・返事の間・笑い・騒がしさ・話す割合／声の高さ（作り物の 150Hz の音）と snr／騒がしい会話は信用が低い
  （tier_cap）／気分の見立ては前の日と比べ、印（見立て（仮）・hypothesis・mood）と根拠を付ける／相手ごとの表／母艦の inbox に写す／
  出力に会話の文が入らない
- llmroute（69）: 自信が高ければ安い方だけ・低ければ高い方で見直す（用途 .review）・1 日の上限で頼まない（409）・帳簿は共有の 1 本
- honne（47）: 時計の独り言だけを拾う（相手がいる・iPhone の音声・短い・テレビは拾わない）・分け方は見立て・同じものは二度頼まない
- voicefix（63）: 「違う、〇〇さん」「違う、俺」「〇〇じゃなくて△△」を読み解く・記録にある名前だけ（決まらなければ聞く）・
  今までの直し（edits）になる・言った時刻の前の行を探す
- asrlearn（72）: 本人の直しだけから組を作る（機械の直しは入れない）・段（auto／tentative／ask）・auto だけ当てる・
  自分で当てた直しは学ばない・同じ行に二度当てない・tentative は「聞いて直す」に理由 dict で出す
- plauddoubt（73）: 母艦の misheard_pairs の行を「聞いて直す」に理由 plaud で出す・合った行は低い自信だけなら聞かない
- voicesamples（70）: 本人の ○（合っている・話し手の直し・会話の ○）の行だけ・よく会う人だけ・× の会話は使わない・
  騒がしい行は使わない・名前は変えない
- selfvoice（71）: 手順と読む文・場面ごとの近さ・前と後の history
- knowme: GET の受け口・features・config の "knowme": false で止まる・lifelog_pc.py の呼び出し
"""

from __future__ import annotations

import datetime
import json
import math
import os
import sqlite3
import sys
import tempfile
import wave
from pathlib import Path
from types import SimpleNamespace

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

from v6checks import say  # noqa: E402

TMP = Path(tempfile.mkdtemp(prefix="v21knowme-"))
os.environ["LOCALAPPDATA"] = str(TMP / "local")      # claude.home() を一時フォルダに
os.environ.pop("ANTHROPIC_API_KEY", None)

import asrlearn  # noqa: E402
import claude  # noqa: E402
import honne  # noqa: E402
import knowme  # noqa: E402
import llmroute  # noqa: E402
import plauddoubt  # noqa: E402
import records  # noqa: E402
import selfvoice  # noqa: E402
import voicefix  # noqa: E402
import voices  # noqa: E402
import voicesamples  # noqa: E402
import voicetone  # noqa: E402

TODAY = datetime.date(2026, 11, 18)
DAY = TODAY.isoformat()
SECRET_TEXT = "ひみつのはなし"


def iso(day: str, h: int, m: int, s: float) -> str:
    """日本の時刻 → UTC の ISO（iPhone の書き方）"""
    t = datetime.datetime.fromisoformat(day) + datetime.timedelta(hours=h - 9, minutes=m, seconds=s)
    return t.strftime("%Y-%m-%dT%H:%M:%S.") + f"{int(t.microsecond / 1000):03d}Z"


def L(day, h, m, s, text, who=None, audio="a1-w.m4a", off=0.0, dur=2.0, **extra):
    line = {"time": iso(day, h, m, s), "text": text, "audio": audio, "offset": off, "end": off + dur, "confidence": 0.9}
    if who == "me":
        line.update({"speaker": "自分", "speakerID": "me"})
    elif who:
        line.update({"speaker": who, "speakerID": {"甲": "11", "乙": "12", "丙さん": "13"}.get(who, "99")})
    line.update(extra)
    return line


def conv(day, h, m, lines, **extra):
    return {"start": lines[0]["time"], "end": iso(day, h, m + 3, 0), "lines": lines, **extra}


def day_record(day: str, rate_scale: float = 1.0) -> dict:
    d = rate_scale
    return {"conversations": [
        # 会話 1: 自分と甲（静か・笑いあり）
        conv(day, 10, 0, [L(day, 10, 0, 0, "おはようございます" * 1, "me", off=0, dur=2.0 / d),
                          L(day, 10, 0, 3, "おはよう、今日は寒いね", "甲", off=3, dur=2.5),
                          L(day, 10, 0, 6, "ほんとに寒いですね、はは", "me", off=6, dur=2.0 / d, sound="拍手・笑い"),
                          L(day, 10, 0, 9, SECRET_TEXT + "をしよう", "甲", off=9, dur=3.0)]),
        # 会話 2: 騒がしい（信用が低い）
        conv(day, 12, 0, [L(day, 12, 0, 0, "ここうるさいね", "me", audio="a2.m4a", noisy=True),
                          L(day, 12, 0, 1, "ほんとだ", "丙さん", audio="a2.m4a", off=1, dur=1.0, noisy=True),
                          L(day, 12, 0, 3, "そうだね", "乙", audio="a2.m4a", off=3, noisy=True),
                          L(day, 12, 0, 6, "出ようか", "me", audio="a2.m4a", off=6, noisy=True)]),
        # 会話 3: 時計の独り言
        conv(day, 20, 0, [L(day, 20, 0, 0, "今日はちょっと疲れたけど、明日はもう少しがんばろう", "me", audio="a3-w.m4a", dur=4.0),
                          L(day, 20, 0, 5, "あと洗濯もしないと", "me", audio="a3-w.m4a", off=5, dur=2.0)]),
        # 会話 4: テレビ
        conv(day, 21, 0, [L(day, 21, 0, 0, "ニュースです", None, audio="a4.m4a"), L(day, 21, 0, 3, "天気です", None, audio="a4.m4a", off=3)],
             media="テレビ"),
    ], "work": []}


def make_store() -> tuple[records.RecordStore, Path]:
    home = TMP / "home"
    store = records.RecordStore(home, lambda _t: None)
    for i in range(7, 0, -1):
        d = (TODAY - datetime.timedelta(days=i)).isoformat()
        store.put(d, json.dumps(day_record(d, 1.0 + 0.05 * (i % 3))).encode())
    store.put(DAY, json.dumps(day_record(DAY, 2.0)).encode())
    return store, home


def sine_wav(path: Path, hz: float, seconds: float) -> None:
    t = np.arange(int(16000 * seconds)) / 16000
    x = (0.3 * np.sin(2 * math.pi * hz * t) * (1 + 0.5 * np.sin(2 * math.pi * 3 * t))).astype(np.float32)
    x[:: 4000] = 0  # 静かな所も少し
    pcm = (x * 32767).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(pcm.tobytes())


def wav_load(data: bytes) -> np.ndarray:
    import io
    with wave.open(io.BytesIO(data)) as w:
        raw = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2")
    out = raw.astype(np.float32) / 32767
    # 静かな所を作る（snr を測れるように）
    out[: 16000] *= 0.01
    return out


# MARK: - 45・78


def check_voicetone(store, home) -> int:
    failed = 0
    mother = TMP / "mother"
    (mother / "archive" / "health" / "2026" / "11").mkdir(parents=True)
    for i in range(8):
        d = TODAY - datetime.timedelta(days=i)
        (mother / "archive" / "health" / "2026" / "11" / f"{d.day:02d}.md").write_text(
            f"# Health\n\n## 睡眠\n- 就寝 → 起床 （睡眠 {6 + (i % 2)}h {10 * i}m）\n\n## 心拍\n- 安静: {60 + i % 3} bpm\n",
            encoding="utf-8")
    days = [(TODAY - datetime.timedelta(days=i)).isoformat() for i in range(7, -1, -1)]
    got = voicetone.run(home, store, mother, lambda _t: None, days)
    today = got["days"][-1]
    c1, c2 = today["conversations"][0], today["conversations"][1]
    failed += say(len(today["conversations"]) == 4 and c1["self_lines"] == 2 and c1["partners"] == ["甲"],
                  "会話ごとの数（自分の行・名前のある相手）")
    failed += say(c1["self_rate_cps"] is not None and c1["self_rate_cps"] > 4 and c1["laugh"] == 1
                  and c1["pause_median_s"] is not None and c1["reply_median_s"] is not None and 0 < c1["talk_share"] < 1,
                  f"速さ {c1['self_rate_cps']}・笑い・間・返事の間・話す割合")
    failed += say(c1["trust"] == "normal" and c2["trust"] == "low" and c2["tier_cap"] == "tentative"
                  and today["conversations"][3]["trust"] == "low", "騒がしい会話・テレビは信用が低い（確定にしない印）")
    mood = today["mood"]
    failed += say(mood["label"] == "見立て（仮）" and mood["layer"] == "hypothesis" and mood["kind"] == "mood"
                  and mood["tier"] in ("tentative", "ask") and mood["mood"] in ("元気", "ふつう", "しんどい")
                  and any(s["signal"] == "sleep_h" for s in mood["signals"])
                  and mood["evidence"] and all(e["conversation_start"] for e in mood["evidence"]),
                  f"気分の見立て（{mood['mood']}・{mood['score']}）は前の日と比べ、印と根拠を付け、確定にしない")
    failed += say(today["self"]["low_trust"] == 2 and today["self"]["used"] == 2 and today["self"]["sleep_h"] == 6.0,
                  "その日の自分の数に、信用が低い会話は入れない・睡眠を読む")
    first = got["days"][0]["mood"]
    failed += say(first["mood"] is None and first["tier"] == "ask", "前の日が足りない日は気分を付けない")
    partners = voicetone.read_json(home / voicetone.PARTNER_FILE)
    failed += say("甲" in partners["partners"] and "乙" not in partners["partners"]
                  and partners["partners"]["甲"]["conversations"] >= 2, "相手ごとの表（信用が低い会話の相手は数えない）")
    inbox = mother / "inbox" / "voice-tone"
    failed += say((inbox / "voice_tone_daily.json").is_file() and (inbox / "voice_tone_by_partner.json").is_file()
                  and (inbox / "days" / f"{DAY}.json").is_file(), "母艦の inbox/voice-tone に写す")
    texts = "".join(p.read_text(encoding="utf-8") for p in (home / voicetone.FOLDER).glob("*.json"))
    failed += say(SECRET_TEXT not in texts and "寒い" not in texts, "出力に会話の文を入れない")
    # 声の高さと snr（作り物の 150Hz の音）
    audio = TMP / "audio"
    audio.mkdir(exist_ok=True)
    sine_wav(audio / "a1-w.m4a", 150, 14)
    got = voicetone.run(home, store, None, lambda _t: None, [DAY], lambda n: audio / n if (audio / n).exists() else None,
                        wav_load, 60.0, mother_copy=False)
    c1 = got["days"][0]["conversations"][0]
    failed += say(c1.get("pitch_hz") is not None and abs(c1["pitch_hz"] - 150) < 8 and c1.get("snr_db") is not None,
                  f"声の高さ（{c1.get('pitch_hz')} Hz）と snr（{c1.get('snr_db')} dB）")
    again = voicetone.run(home, store, None, lambda _t: None, [DAY], mother_copy=False)
    failed += say(again["days"][0]["conversations"][0].get("pitch_hz") == c1["pitch_hz"],
                  "軽い見回りで、前に測った高さを消さない")
    return failed


# MARK: - 69・47


class Fake:
    def __init__(self) -> None:
        self.calls: list[dict] = []
        self.answers: list[dict] = []

    def factory(self, key):
        owner = self

        class Messages:
            def create(self, **kwargs):
                owner.calls.append(kwargs)
                data = owner.answers.pop(0) if owner.answers else {"kind": "honne", "confidence": 0.9}
                return SimpleNamespace(content=[SimpleNamespace(type="text", text=json.dumps(data))], stop_reason="end_turn",
                                       model=kwargs["model"], usage=SimpleNamespace(
                                           input_tokens=300, output_tokens=20, cache_read_input_tokens=0,
                                           cache_creation_input_tokens=0, server_tool_use=None))

        return SimpleNamespace(messages=Messages(), beta=SimpleNamespace(messages=Messages()))


def check_llm(store, home) -> int:
    failed = 0
    fake = Fake()
    claude.CLIENT_FACTORY = fake.factory
    claude.home().mkdir(parents=True, exist_ok=True)
    claude.key_path().write_text("sk-ant-checkonly-0000", encoding="utf-8")
    claude.LEDGER.reset(None)
    schema = {"type": "object", "properties": {"kind": {"type": "string"}}, "required": ["kind"]}
    fake.answers = [{"kind": "memo", "confidence": 0.95}]
    got = llmroute.judge("honne", "前置き", "本文", schema)
    failed += say(not got["reviewed"] and len(fake.calls) == 1 and fake.calls[0]["model"] == claude.TIERS["light"]
                  and "confidence" in fake.calls[0]["output_config"]["format"]["schema"]["required"],
                  "自信が高ければ安い方（Haiku）だけ。答えの形に confidence を足す")
    fake.answers = [{"kind": "memo", "confidence": 0.3}, {"kind": "honne", "confidence": 0.8}]
    got = llmroute.judge("honne", "前置き", "本文", schema)
    failed += say(got["reviewed"] and got["data"]["kind"] == "honne" and fake.calls[-1]["model"] == claude.TIERS["standard"]
                  and got["first_confidence"] == 0.3, "自信が低ければ高い方（Sonnet）で見直す")
    rows = [json.loads(r) for r in claude.ledger_path().read_text(encoding="utf-8").splitlines()]
    failed += say([r["purpose"] for r in rows] == ["honne", "honne", "honne.review"],
                  "帳簿は共有の claude-usage.jsonl に、安い方と見直しを分けて足す")
    # 1 日の上限
    claude.append_ledger({"purpose": "honne", "model": claude.HAIKU, "usd": 1.0})
    before = len(fake.calls)
    try:
        llmroute.judge("honne", "前置き", "本文", schema)
        failed += say(False, "1 日の上限に届いたら頼まない")
    except claude.ClaudeError as error:
        failed += say(error.status == 409 and len(fake.calls) == before, "1 日の上限（仮 $0.10）に届いたら頼まない（409）")
    claude.config_path().write_text(json.dumps({"daily_caps": {"honne": 5.0}}), encoding="utf-8")
    failed += say(llmroute.cap_for("honne") == 5.0 and llmroute.cap_for("honne.review") == 5.0,
                  "claude-config.json の daily_caps が既定より先")
    claude.config_path().unlink()
    claude.LEDGER.reset(None)
    claude.ledger_path().unlink()
    # 47
    mono = honne.monologues(store.day(DAY), DAY)
    failed += say(len(mono) == 1 and "疲れた" in mono[0]["text"] and mono[0]["conversation_start"],
                  "時計の独り言だけを拾う（相手がいる・iPhone の音声・テレビは拾わない）")
    fake.answers = [{"kind": "honne", "confidence": 0.9}]
    built = honne.build_day(home, store, DAY, {}, lambda _t: None)
    item = built["items"][0]
    failed += say(item["kind"] == "honne" and item["label"] == "見立て（仮）" and item["layer"] == "hypothesis"
                  and item["tier"] == "tentative" and built["counts"]["honne"] == 1, "本音メモに分け、見立ての印を付ける")
    sent = fake.calls[-1]
    failed += say("例" not in sent["system"][0]["text"] and "疲れた" in sent["messages"][0]["content"],
                  "頼む文に見本の文を入れない（本人の言葉だけ）")
    n = len(fake.calls)
    honne.build_day(home, store, DAY, {}, lambda _t: None)
    failed += say(len(fake.calls) == n, "同じ独り言は二度頼まない")
    claude.key_path().unlink()
    (home / honne.FOLDER / f"{DAY}.json").unlink()
    built = honne.build_day(home, store, DAY, {}, lambda _t: None)
    failed += say(built["items"][0]["kind"] is None and built["items"][0]["tier"] == "ask",
                  "鍵が無ければ分けずに「聞く」のまま")
    claude.CLIENT_FACTORY = None
    return failed


# MARK: - 63


def check_voicefix(store) -> int:
    failed = 0
    failed += say(voicefix.interpret("違う、甲さん") == {"kind": "speaker", "name": "甲"}
                  and voicefix.interpret("ちがう、俺だよ") == {"kind": "speaker", "name": "自分"}
                  and voicefix.interpret("寒いじゃなくて暑い") == {"kind": "text", "wrong": "寒い", "right": "暑い"}
                  and voicefix.interpret("おなかすいた") is None, "読み解き（話し手・自分・言葉・分からない）")
    at = iso(DAY, 10, 0, 10)
    got = voicefix.handle(store, {"text": "違う、乙さん", "at": at})
    failed += say(got["status"] == "edited" and got["kind"] == "speaker" and got["line_time"] == iso(DAY, 10, 0, 9),
                  "言った時刻の前の「自分ではない」行の話し手を直す（今までの edits）")
    pending = store.edits.pending(0)
    failed += say(len(pending) == 1 and pending[0]["speaker"] == "乙", "iPhone が取りに来る直しになる")
    got = voicefix.handle(store, {"text": "違う、知らない人", "at": at})
    failed += say(got["status"] == "ask" and len(store.edits.pending(0)) == 1, "記録に無い名前は直さずに聞く（新しい名前を作らない）")
    got = voicefix.handle(store, {"text": "違う、丙", "at": at})
    failed += say(got["status"] == "edited", "「さん」付きで登録された名前も、言い方が違っても 1 つに決まれば直す")
    got = voicefix.handle(store, {"text": "寒いじゃなくて暑い", "at": iso(DAY, 10, 0, 4),
                                  "target_id": f"{DAY}|{records.parse_time(iso(DAY, 10, 0, 3), 't')}"})
    failed += say(got["status"] == "edited" and store.edits.pending(0)[-1]["text"] == "おはよう、今日は暑いね",
                  "target_id の行の言葉を直す")
    got = voicefix.handle(store, {"text": "違う、甲さん", "at": iso(DAY, 23, 59, 0)})
    failed += say(got["status"] == "no_target", "近くに行が無ければ直さない")
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        mother, home = Path(tmp) / "mother", Path(tmp) / "home"
        (mother / "inbox").mkdir(parents=True)
        row = {"text": "違う、乙さん", "said_at": at, "by": "watch", "near": {"line_time": iso(DAY, 10, 0, 9)}}
        (mother / voicefix.INBOX).write_text(json.dumps(row, ensure_ascii=False) + "\n", encoding="utf-8")
        before = len(store.edits.pending(0))
        first = voicefix.drain_inbox(home, mother, store, lambda _t: None)
        second = voicefix.drain_inbox(home, mother, store, lambda _t: None)
        failed += say(first == 1 and second == 0 and len(store.edits.pending(0)) >= before,
                      "時計からの「違う、〇〇さん」（母艦の inbox）を 1 回だけ当てる")
    return failed


# MARK: - 72


def check_asrlearn(home) -> int:
    failed = 0
    failed += say(asrlearn.pairs_from("講座を開く", "口座を開く") == [("講座", "口座")]
                  and asrlearn.pairs_from("3時に", "三時に") == [] and asrlearn.pairs_from("あ、そう", "そう") == []
                  and asrlearn.pairs_from("田さん", "田中さん") == [], "組の取り方（数字だけ・消しただけ・増え続ける組は入れない）")
    h2 = TMP / "home2"
    store = records.RecordStore(h2, lambda _t: None)
    lines = []
    for i in range(9):
        lines.append(L(DAY, 9, 10 + i, 0, "ぺんぎん号の話", "me", history=[{"at": iso(DAY, 9, 30, 0), "by": "手で直した",
                                                                        "from": "ペンギン合の話"}]))
    lines.append(L(DAY, 9, 5, 0, "そらいろ駅に行く", "me", history=[{"at": iso(DAY, 9, 30, 0), "by": "手で直した",
                                                                    "from": "空色液に行く"}]))
    lines.append(L(DAY, 9, 6, 0, "機械が直した", "me", history=[{"at": iso(DAY, 9, 30, 0), "by": "言語モデルの直し",
                                                              "from": "きかいがなおした"}]))
    lines.append(L(DAY, 9, 7, 0, "空色液はどこ", "me"))
    lines.append(L(DAY, 9, 8, 0, "ペンギン合が来た", "me"))
    store.put(DAY, json.dumps({"conversations": [conv(DAY, 9, 0, lines)]}).encode())
    built = asrlearn.build(h2, store, TODAY)
    by = {(i["wrong"], i["right"]): i for i in built["items"]}
    p = by.get(("ペンギン合", "ぺんぎん号"))
    q = by.get(("空色液", "そらいろ駅"))
    failed += say(p is not None and p["corrected"] == 9 and p["remaining"] == 1 and p["tier"] == "auto"
                  and q is not None and q["tier"] == "tentative" and ("きかいがなおした", "機械が直した") not in by,
                  f"本人の直しだけから組（{len(built['items'])} 組）・段 auto／tentative")
    made = asrlearn.apply_auto(h2, store, built, TODAY)
    pend = store.edits.pending(0)
    failed += say(made == 1 and pend[-1]["text"] == "ぺんぎん号が来た", "auto の組だけを新しい行に当てる（今までの edits）")
    failed += say(asrlearn.apply_auto(h2, store, built, TODAY) == 0, "同じ行に二度当てない")
    # 自分で当てた直しは学ばない（iPhone が当てたあと history に「PC で直した」が付いても）
    lines[-1] = dict(lines[-1], text="ぺんぎん号が来た", history=[{"at": iso(DAY, 10, 0, 0), "by": "PC で直した",
                                                                  "from": "ペンギン合が来た"}])
    store.put(DAY, json.dumps({"conversations": [conv(DAY, 9, 0, lines)]}).encode())
    again = asrlearn.build(h2, store, TODAY)
    p2 = next(i for i in again["items"] if i["wrong"] == "ペンギン合")
    failed += say(p2["corrected"] == 9, "自分で当てた直しで辞書を育てない")
    doubts = asrlearn.tentative_doubts(h2, store.day(DAY))
    failed += say(list(doubts.values()) == [["dict"]], "tentative の組の言葉を含む行を「聞いて直す」に理由 dict で出す")
    return failed


# MARK: - 73


def check_plaud(store) -> int:
    failed = 0
    mother = TMP / "mother73"
    (mother / "state").mkdir(parents=True)
    (mother / "state" / "misheard_pairs.json").write_text(json.dumps({"items": [
        {"day": DAY, "app": "ほんとに寒いですね、はは", "plaud": "べつの文", "match": 0.1}]}, ensure_ascii=False), encoding="utf-8")
    plauddoubt._cache["at"] = 0
    add, quiet = plauddoubt.doubts(mother, DAY, store.day(DAY))
    failed += say(list(add.values()) == [["plaud"]] and not quiet, "PLAUD と食い違った行に理由 plaud")
    (TMP / "home" / "audio" / DAY).mkdir(parents=True, exist_ok=True)
    (TMP / "home" / "audio" / DAY / "a1-w.m4a").write_bytes(b"x")
    store.extra_doubts = lambda d, p: plauddoubt.doubts(mother, d, p)
    items, _ = store.review_queue(limit=100)
    failed += say(any("plaud" in i["reasons"] for i in items), "自信が低くない行でも「聞いて直す」に出す")
    rec = day_record(DAY, 2.0)
    rec["conversations"][0]["lines"][0]["confidence"] = 0.1
    store.put(DAY, json.dumps(rec).encode())
    first = store.day(DAY)["conversations"][0]["lines"][0]
    (mother / "state" / "plaud_line_match_for_pc.json").write_text(json.dumps({"days": {DAY: {"agree": [
        records.iso_ms(first["time"])]}}}), encoding="utf-8")
    plauddoubt._cache["at"] = 0
    failed += say(first["time"] in plauddoubt.doubts(mother, DAY, store.day(DAY))[1], "PLAUD と合った行は聞かない側に入る")
    store.extra_doubts = None
    before = [i for i in store.review_queue(limit=100)[0] if i["line"]["time"] == first["time"]]
    store.extra_doubts = lambda d, p: plauddoubt.doubts(mother, d, p)
    after = [i for i in store.review_queue(limit=100)[0] if i["line"]["time"] == first["time"]]
    failed += say(before and before[0]["reasons"] == ["low"] and not after,
                  "PLAUD と合った行は、自信が低いだけなら「聞いて直す」に出さない")
    store.put(DAY, json.dumps(day_record(DAY, 2.0)).encode())
    listing = plauddoubt.listing(mother, store)
    failed += say(listing["available"] and listing["days"][DAY][0]["line_time"] is not None, "GET /plaud-doubts の中身")
    store.extra_doubts = None
    return failed


# MARK: - 70・71


def check_samples(store, home) -> int:
    failed = 0
    with sqlite3.connect(home / "edits.db") as db:
        for i in range(1, 8):
            d = (TODAY - datetime.timedelta(days=i)).isoformat()
            t = records.parse_time(iso(d, 10, 0, 3), "t")
            db.execute("INSERT OR REPLACE INTO reviews (day, time, answer, text, created) VALUES (?, ?, 'ok', NULL, 0)", (d, t))
    for i in range(1, 8):
        d = (TODAY - datetime.timedelta(days=i)).isoformat()
        (home / "audio" / d).mkdir(parents=True, exist_ok=True)
        (home / "audio" / d / "a1-w.m4a").write_bytes(b"x")
        (home / "audio" / d / "a2.m4a").write_bytes(b"x")
    # × の会話（乙の騒がしい会話は、もともと使わない）
    bad = (TODAY - datetime.timedelta(days=1)).isoformat()
    (home / voicesamples.OK_FILE).parent.mkdir(parents=True, exist_ok=True)
    (home / voicesamples.OK_FILE).write_text(json.dumps({"day": bad, "conversation_start": iso(bad, 10, 0, 0),
                                                         "verdict": "ng"}) + "\n", encoding="utf-8")
    with sqlite3.connect(home / "edits.db") as db:
        db.execute("INSERT OR REPLACE INTO reviews (day, time, answer, text, created) VALUES (?, ?, 'ok', NULL, 0)",
                   (bad, records.parse_time(iso(bad, 12, 0, 3), "t")))
    built = voicesamples.build(home, store, TODAY)
    people = {p["speaker"]: p for p in built["people"]}
    failed += say(list(people) == ["甲"] and 1 <= len(people["甲"]["samples"]) <= voicesamples.PER_PERSON
                  and all(s["why"] == "ok" and s["day"] != bad for s in people["甲"]["samples"])
                  and people["甲"]["speakerID"] == "11" and people["甲"]["samples"][0]["path"].startswith("/audio-clip?"),
                  "本人の ○ の行から、よく会う人の見本の候補（× の会話・騒がしい行は使わない・名前はそのまま）")
    # 71
    for i in range(0, 3):
        d = (TODAY - datetime.timedelta(days=i)).isoformat()
        ds = voices.DayStore(home, d)
        rng = np.random.default_rng(i)
        base = np.ones(8, np.float32)
        for seg in voices.segments(store.day(d)):
            if seg["label"] == "me":
                noise = rng.normal(0, 0.8 if seg["line"].get("noisy") else 0.1, 8).astype(np.float32)
                ds.vectors[seg["key"]] = base + noise
        ds.save()
    sv = selfvoice.build(home, store, None, TODAY)
    n = sv["numbers"]
    failed += say(len(sv["steps"]) >= 4 and set(sv["scripts"]) == {"quiet", "noisy", "phone"} and n["quiet"]["lines"] > 0
                  and n["noisy"]["lines"] > 0 and n["quiet"]["median"] > n["noisy"]["median"] and n["phone"]["lines"] is None
                  and sv["history"][-1]["day"] == DAY, "自分の声: 手順と読む文・場面ごとの近さ（騒がしい方が遠い）・history")
    return failed


# MARK: - knowme の口


class Handler:
    def __init__(self) -> None:
        self.sent = None

    def send_json(self, status, body):
        self.sent = (status, body)


def check_hub(store, home) -> int:
    failed = 0
    cfg = {"value": {}}
    knowme.State.home, knowme.State.store, knowme.State.config = home, store, lambda: cfg["value"]
    knowme.State.mother = None
    h = Handler()
    knowme.http_get(h, "/voice-tone", f"day={DAY}")
    failed += say(h.sent[0] == 200 and h.sent[1]["available"] and h.sent[1]["day"] == DAY, "GET /voice-tone?day=")
    for path in ("/honne", "/voice-samples", "/self-voice", "/plaud-doubts"):
        knowme.http_get(h, path, "")
        failed += say(h.sent[0] == 200 and "available" in h.sent[1], f"GET {path}")
    failed += say(set(knowme.features()) == set(knowme.FEATURES), "features")
    cfg["value"] = {"knowme": False}
    knowme.http_get(h, "/voice-tone", "")
    failed += say(h.sent[1] == {"available": False} and knowme.features() == [] and knowme.tick() == {},
                  "config.json の \"knowme\": false で止まる")
    src = (Path(__file__).resolve().parent / "lifelog_pc.py").read_text(encoding="utf-8")
    failed += say("knowme.start(HOME, App.records" in src and "knowme.http_get(self, path, url.query)" in src
                  and "knowme.http_post(self, url.path, log)" in src and "knowme.features()" in src,
                  "lifelog_pc.py は呼び出しの数行だけ")
    return failed


def main() -> int:
    store, home = make_store()
    failed = 0
    for check in (lambda: check_voicetone(store, home), lambda: check_llm(store, home), lambda: check_voicefix(store),
                  lambda: check_asrlearn(home), lambda: check_plaud(store), lambda: check_samples(store, home),
                  lambda: check_hub(store, home)):
        failed += check()
    print("ぜんぶ OK" if not failed else f"NG の数: {failed}", flush=True)
    return failed


if __name__ == "__main__":
    sys.exit(main())
