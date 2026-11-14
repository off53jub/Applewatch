"""強化案 42・45・48（2026-11-15）を確かめる。

    python pc/v14checks_search.py

本物の母艦・Ollama・Claude の鍵・ネットは使わない（一時のフォルダに作り物の母艦・作り物の埋め込み・作り物の Claude）。
本物の HOME に書かない（isolate_home）。確かめること:
- 母艦の文の意味の索引（mothersearch.py）: 置く対象（audio・whisper・ほかの state は読まない）・まとめ方（LINE は相手ごと・
  PLAUD は頭の項目を読まない・まとめは頭の --- を読まない・長さの上限）・日の決め方・変わったファイルだけ置き直す
  （同じ文は数の並びを作り直さない・無くなったファイルは消す）・重い時間の決まり・アプリの記録の表（items）と混ざらない・
  系統と期間でしぼる・母艦のファイルを書き換えない・記録に中身を書かない
- askmother.py: 意味で探した結果と言葉で探した結果をいっしょに使う・同じものは 1 つ・長さの上限・人・欲しい物・決めごとの
  質問だけ state と人のノートの節を足す（意味の索引が無ければ言葉を含む節だけ）・ファイルを丸ごと渡さない・出どころに path
- 組み立ての前の Swift の検査（.github/scripts/swift_precheck.py）: 生の改行・長いクロージャを見つけ、ふつうの書き方は通す
"""

from __future__ import annotations

import datetime
import hashlib
import importlib.util
import json
import os
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent))

import numpy as np  # noqa: E402

import askmother  # noqa: E402
import claude  # noqa: E402
import mothersearch  # noqa: E402
import semantic  # noqa: E402
from v6checks import say  # noqa: E402
from v11checks import FakeClaude, put_key, reset_files  # noqa: E402

SECRET = "見本の秘密の話"
DIM = 96


class FakeEmbedder:
    """文字の 2 つ組の数を数の並びにする（同じ言葉を含む文ほど近い）"""

    model = semantic.EMBED_MODEL

    def __init__(self) -> None:
        self.calls = 0
        self.texts = 0

    def embed(self, texts: list[str]) -> np.ndarray:
        self.calls += 1
        self.texts += len(texts)
        out = np.zeros((len(texts), DIM), dtype=np.float32)
        for row, text in enumerate(texts):
            for a, b in zip(text, text[1:]):
                h = int(hashlib.md5((a + b).encode("utf-8")).hexdigest()[:8], 16)
                out[row, h % DIM] += 1.0
        return semantic.normalize(out)

    def models(self) -> list[str]:
        return [self.model]


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def make_base(base: Path) -> None:
    write(base / "archive/line/2026/11/12.md",
          "# 2026-11-12 LINE\n\n## 見本の友だち\n\n- **12:00** 見本の友だち: 来週の餃子の店は駅前の見本亭にしよう\n"
          "- **12:05** 自分: いいね、7時でどう\n  続きの行\n\n## 見本の家族\n\n- **20:00** 見本の家族: 週末は雨らしい\n")
    write(base / "archive/line/2026/11/13.md", "# 2026-11-13 LINE\n\n## 見本の友だち\n\n- **09:00** 自分: 傘を忘れた\n")
    write(base / "archive/plaud/2026/11/13_見本の打ち合わせ.md",
          "# 見本の打ち合わせ\n\n- source: plaud\n- date: 2026-11-13\n- original: x\n\n話者1 00:00:05\n"
          "見本の資料は金曜までに送ります。\n話者2 00:01:10\n" + "長い話の見本です。" * 120 + "\n")
    write(base / "archive/plaud/audio/2026/11/13_x.md", f"# 音声の置き場所 {SECRET}\n")
    write(base / "archive/plaud/whisper/2026/11/13_x.md", f"# whisper {SECRET}\n")
    write(base / "archive/lifelog-pc/2026/11/13.md",
          "# 2026-11-13 家の PC\n\n> 注意の行\n\n## 1件目\n\n- 話題: 10:00〜10:30 見本の歯医者の予約を変える話\n")
    write(base / "digests/daily/2026-11-13.md",
          "---\ntype: daily\ndate: 2026-11-13\n---\n# 2026-11-13 まとめ\n\n## できごと\n\n[[見本の友だち]]と餃子の店を決めた。\n")
    write(base / "digests/weekly/2026-W46.md", "# 週のまとめ 2026-W46\n\n## 1. 見本の週\n\n雨の多い週だった。\n")
    write(base / "state/WISHLIST.md", "# WISHLIST\n\n> 説明の行\n\n## 在庫\n\n- [ ] 見本の電気毛布（2026-11-01 / きっかけ: 寒い）\n"
                                      "\n## 済み\n\n- [x] 見本の水筒\n")
    write(base / "state/DECISIONS.md", "# DECISIONS\n\n## 決まったこと\n\n### 見本の決め事\n\n- 朝のまとめは見本の形にする\n")
    write(base / "state/profile.md", "# profile\n\n## 好み\n\n- 見本の食べ物: 餃子が好き\n")
    write(base / "state/TODO.md", f"# TODO\n\n- {SECRET}\n")
    write(base / "people/見本の友だち.md", "---\nname: x\n---\n# 見本の友だち\n\n## 関係\n\n学生のころからの見本の友だち。餃子が好き。\n")
    write(base / "people/sub/ignored.md", f"# {SECRET}\n")


def tree_stamp(base: Path) -> dict:
    return {p.relative_to(base).as_posix(): (p.stat().st_mtime_ns, hashlib.sha256(p.read_bytes()).hexdigest())
            for p in base.rglob("*") if p.is_file()}


def run(main=None) -> int:
    if main is not None:
        main.isolate_home()
    failed = 0
    saved = (askmother.SEMANTIC, askmother.RUN, mothersearch.INDEX, claude.CLIENT_FACTORY)
    try:
        failed += check_index()
        failed += check_ask()
        failed += check_precheck()
    finally:
        askmother.SEMANTIC, askmother.RUN, mothersearch.INDEX, claude.CLIENT_FACTORY = saved
        reset_files()
    print(("NG の数: " + str(failed)) if failed else "母艦の意味の索引・質問・組み立ての前の検査（2026-11-15）: 全部 OK", flush=True)
    return failed


# MARK: - 意味の索引


def check_index() -> int:
    failed = 0
    with tempfile.TemporaryDirectory() as folder:
        base = Path(folder) / "Lifelog"
        make_base(base)
        before = tree_stamp(base)
        files = mothersearch.discover(base)
        rels = sorted((s, p.relative_to(base).as_posix()) for s, p in files)
        want = {"line": 2, "plaud": 1, "lifelog-pc": 1, "digest": 1, "weekly": 1, "wishlist": 1, "decisions": 1,
                "profile": 1, "people": 1}
        got = {}
        for s, _ in rels:
            got[s] = got.get(s, 0) + 1
        failed += say(got == want and not any("audio" in r or "whisper" in r or "TODO" in r or "sub/" in r for _, r in rels),
                      f"置く対象: 決めた 9 系統だけ（audio・whisper・ほかの state・下のフォルダは読まない） {got}")
        only = mothersearch.discover(base, {"2026-11-12"}, with_state=False)
        failed += say([p.name for _, p in only] == ["12.md"], "日でしぼれる（日の無いものは with_state のときだけ）")

        line = mothersearch.chunks_for("line", base / "archive/line/2026/11/12.md",
                                       (base / "archive/line/2026/11/12.md").read_text(encoding="utf-8"))
        failed += say(len(line) == 2 and line[0]["label"] == "見本の友だち" and line[0]["time"] == "12:00"
                      and "続きの行" in line[0]["text"] and "7時" in line[0]["text"] and line[1]["label"] == "見本の家族",
                      "LINE: 相手ごとに、続く発言をまとめる（字下げの行は前の発言の続き）")
        plaud_path = base / "archive/plaud/2026/11/13_見本の打ち合わせ.md"
        plaud = mothersearch.chunks_for("plaud", plaud_path, plaud_path.read_text(encoding="utf-8"))
        failed += say(len(plaud) >= 2 and plaud[0]["label"] == "見本の打ち合わせ" and plaud[0]["time"] == "+00:00:05"
                      and not any("source:" in c["text"] for c in plaud)
                      and all(len(c["text"]) <= mothersearch.CHUNK_CHARS for c in plaud),
                      f"PLAUD: 頭の項目は読まない・経過時間・長い文は {mothersearch.CHUNK_CHARS} 文字ごと（{len(plaud)} まとまり）")
        digest_path = base / "digests/daily/2026-11-13.md"
        digest = mothersearch.chunks_for("digest", digest_path, digest_path.read_text(encoding="utf-8"))
        failed += say(len(digest) == 1 and "type:" not in digest[0]["text"] and "[[" not in digest[0]["text"]
                      and digest[0]["label"] == "できごと",
                      "まとめ: 頭の --- の間は読まない・[[ ]] は外す・見出しの節")
        people_path = base / "people/見本の友だち.md"
        people = mothersearch.chunks_for("people", people_path, people_path.read_text(encoding="utf-8"))
        failed += say(people and people[0]["label"].startswith("見本の友だち"), "人のノート: 見出しにファイルの名前")
        failed += say(mothersearch.day_of("weekly", base, base / "digests/weekly/2026-W46.md") == "2026-11-09"
                      and mothersearch.day_of("plaud", base, plaud_path) == "2026-11-13",
                      "日: 週のまとめはその週の月曜・PLAUD はファイルの名前の日")

        hours = [(0, 0, True), (4, 59, True), (5, 0, False), (8, 29, False), (8, 30, True), (17, 59, True), (18, 0, False),
                 (23, 59, False)]
        wrong = [(h, m) for h, m, want_heavy in hours
                 if mothersearch.heavy_now(datetime.datetime(2026, 11, 15, h, m)) != want_heavy]
        failed += say(not wrong, f"重い仕事をしてよい時間: 00:00〜05:00・08:30〜18:00（{len(hours)} 通り）")

        db = Path(folder) / "home" / "semantic.db"
        embedder = FakeEmbedder()
        app_index = semantic.SemanticIndex(db, embedder, lambda _m: None)
        app_index.index([{"id": "app-1", "day": "2026-11-13", "time": 1.0, "speaker": "自分",
                          "text": "アプリの記録の見本の餃子", "work": False, "conversation": "c1"}])
        logged: list[str] = []
        evening = datetime.datetime(2026, 11, 15, 21, 0)
        index = mothersearch.MotherIndex(db, embedder, lambda: base, logged.append, clock=lambda: evening)
        saved_budget = mothersearch.SMALL_BUDGET
        mothersearch.SMALL_BUDGET = 3
        try:
            small = index.step()
        finally:
            mothersearch.SMALL_BUDGET = saved_budget
        failed += say(3 <= small["embedded"] and small["pending"] > 0 and small["files"] < len(files),
                      f"重くない時間は少しずつ（{small['files']} ファイル・{small['embedded']} 個・残り {small['pending']}）")
        index.clock = lambda: datetime.datetime(2026, 11, 15, 10, 0)
        heavy = index.step()
        total = index.status()
        failed += say(heavy["pending"] == 0 and total["files"] == len(files) and set(total["by_source"]) == set(want),
                      f"重い時間は続けて置く（{total['files']} ファイル・{total['chunks']} まとまり）")
        failed += say(tree_stamp(base) == before, "母艦のファイルは書き換えない（読むだけ）")
        texts_before = embedder.texts
        index._scanned = 0.0
        again = index.step()
        failed += say(again["files"] == 0 and embedder.texts == texts_before, "変わっていなければ、何もしない")

        wish = base / "state/WISHLIST.md"
        wish.write_text(wish.read_text(encoding="utf-8") + "\n- [ ] 見本の手袋（2026-11-14 / きっかけ: 寒い）\n", encoding="utf-8")
        os.utime(wish, (wish.stat().st_atime, wish.stat().st_mtime + 5))
        (base / "archive/line/2026/11/13.md").unlink()
        index._scanned = 0.0
        texts_before = embedder.texts
        changed = index.step()
        with index.connect() as con:
            gone = con.execute("SELECT COUNT(*) FROM mother_chunks WHERE path=?", ("archive/line/2026/11/13.md",)).fetchone()[0]
            gone_file = con.execute("SELECT COUNT(*) FROM mother_files WHERE path=?", ("archive/line/2026/11/13.md",)).fetchone()[0]
        failed += say(changed["files"] == 1 and 0 < embedder.texts - texts_before < changed["chunks"] + 1
                      and gone == 0 and gone_file == 0,
                      f"変わったファイルだけ置き直し、同じ文は作り直さない（新しく {embedder.texts - texts_before} 個）・"
                      "無くなったファイルは消す")

        hits = index.search("餃子の店", k=5)
        failed += say(hits and all(h["id"].startswith("m|") for h in hits) and {"source", "day", "path", "label", "text"} <= set(hits[0]),
                      f"探す: 母艦のまとまりだけ（{len(hits)} 件・path と系統と日つき）")
        app_hits = app_index.search({"query": "餃子", "k": 50, "include_work": True})
        failed += say([h["id"] for h in app_hits] == ["app-1"], "アプリの記録の POST /search には、母艦のまとまりが混ざらない")
        only_wish = index.search("手袋", k=5, sources=["wishlist"])
        failed += say(only_wish and all(h["source"] == "wishlist" for h in only_wish), "系統でしぼる")
        dated = index.search("餃子", k=50, frm="2026-11-13", to="2026-11-13")
        failed += say(dated and not any(h["day"] == "2026-11-12" for h in dated)
                      and any(h["source"] in ("people", "profile") for h in dated),
                      "期間でしぼる（日の無い state・人のノートは期間でしぼらない）")
        status = index.status()
        failed += say(status["chunks"] > 0 and "heavy_now" in status, "数の様子（/index/status の mother）")
        failed += say(not any(SECRET in line or "餃子" in line for line in logged), "記録に中身を書かない")
    return failed


# MARK: - 質問


SAMPLE_OUTPUT = (
    "\x1b[1m2026-11-12 12:00  (line)\x1b[0m\n"
    "  ★ [見本の友だち] 見本の友だち: 来週の餃子の店は駅前の見本亭にしよう\n"
    "---\n"
    "2026-11-10 08:00  (line)\n"
    "  ★ [見本の相手] 言葉だけで見つかった行\n"
    "---\n"
)


def check_ask() -> int:
    failed = 0
    reset_files()
    put_key()
    fake = FakeClaude()
    claude.CLIENT_FACTORY = fake.factory
    plan_box = {"topics": [], "from": "", "to": ""}

    def reply(kwargs):
        if kwargs["model"] == claude.TIERS["light"]:
            return json.dumps({"queries": [{"words": ["餃子"], "sources": ["line"], "from": plan_box["from"],
                                            "to": plan_box["to"]}],
                               "money": False, "money_words": [], "topics": plan_box["topics"]}, ensure_ascii=False)
        return json.dumps({"answer": "見本の答え [1]", "used": [1, 2], "found": True}, ensure_ascii=False)

    fake.reply = reply
    askmother.RUN = lambda args, **kwargs: SimpleNamespace(stdout=SAMPLE_OUTPUT.encode("utf-8"), returncode=0)
    calls: list[dict] = []

    def search(query, k=12, sources=None, frm=None, to=None):
        calls.append({"query": query, "k": k, "sources": list(sources or []), "frm": frm, "to": to})
        if sources and set(sources) <= {"people", "profile", "wishlist", "decisions"}:
            return [{"id": "m|people/x.md|0", "source": sources[0], "day": "2026-11-01", "time": "", "label": "見本の友だち / 関係",
                     "path": "people/見本の友だち.md", "text": "学生のころからの見本の友だち。", "score": 0.8}]
        return [{"id": "m|archive/line/2026/11/12.md|0", "source": "line", "day": "2026-11-12", "time": "12:00",
                 "label": "見本の友だち", "path": "archive/line/2026/11/12.md",
                 "text": "見本の友だち: 来週の餃子の店は駅前の見本亭にしよう\n自分: いいね、7時でどう", "score": 0.9},
                {"id": "m|archive/plaud/2026/11/13_x.md|0", "source": "plaud", "day": "2026-11-13", "time": "+00:00:05",
                 "label": "見本の打ち合わせ", "path": "archive/plaud/2026/11/13_見本の打ち合わせ.md",
                 "text": "長い話の見本です。" * 200, "score": 0.5}]

    with tempfile.TemporaryDirectory() as folder:
        base = Path(folder)
        make_base(base)
        (base / "scripts").mkdir()
        (base / "scripts" / "Search-Lifelog.py").write_text("# 見本\n", encoding="utf-8")
        config = {"lifelog_home": folder, "mothership_python": "py.exe"}
        askmother.SEMANTIC = search
        got = askmother.ask("餃子の店はどこ？", config, today=datetime.date(2026, 11, 14))
        prompt = json.loads(fake.calls[-1][1]["messages"][0]["content"])
        snippets = prompt["snippets"]
        texts = [s["text"] for s in snippets]
        failed += say(any(s["source"] == "plaud" and s.get("path") for s in snippets)
                      and sum("駅前の見本亭" in t for t in texts) == 1
                      and any("言葉だけで見つかった行" in t for t in texts),
                      f"言葉で探した行と意味のまとまりをいっしょに渡し、同じものは 1 つ（{len(snippets)} 件）")
        failed += say(all(len(s["text"]) <= askmother.SEMANTIC_SNIPPET_MAX for s in snippets)
                      and sum(len(s["text"]) for s in snippets) <= askmother.TOTAL_MAX
                      and not any("長い話の見本です。" * 60 in t for t in texts),
                      f"意味のまとまりも長さの上限まで（ファイルを丸ごと渡さない。{askmother.SEMANTIC_SNIPPET_MAX} 文字）")
        failed += say(got["found"] and got["searched"]["semantic"] >= 1 and got["searched"]["topics"] == []
                      and all(c["sources"] and set(c["sources"]) <= set(askmother.SEMANTIC_SOURCES) for c in calls)
                      and calls[0]["frm"] is None and calls[0]["query"] == "餃子の店はどこ？"
                      and any(s.get("path") for s in got["sources"]),
                      f"人・欲しい物の質問でなければ state は読まない・期間が無ければ全部の日・出どころに path {got['searched']}")
        failed += say(not any("学生のころ" in t for t in texts), "人の質問でなければ、人のノートは渡さない")

        calls.clear()
        plan_box.update(topics=["person", "wish", "nonsense"], **{"from": "2026-11-01", "to": "2026-11-14"})
        got = askmother.ask("見本の友だちってどんな人？", config, today=datetime.date(2026, 11, 14))
        prompt = json.loads(fake.calls[-1][1]["messages"][0]["content"])
        topic_calls = [c for c in calls if set(c["sources"]) & {"people", "wishlist"}]
        failed += say(got["searched"]["topics"] == ["person", "wish"] and len(topic_calls) == 1
                      and set(topic_calls[0]["sources"]) == {"people", "profile", "wishlist"}
                      and topic_calls[0]["frm"] is None and prompt["snippets"][0]["source"] in ("people", "profile", "wishlist")
                      and any(c["frm"] == "2026-11-01" for c in calls if c not in topic_calls),
                      "人・欲しい物の質問なら、人のノート・本人のこと・欲しい物リストの意味の近い節を先に足す（期間でしぼらない）")
        failed += say(got["sources"] and got["sources"][0]["label"] in ("人のノート", "本人のこと", "欲しい物リスト"),
                      f"出どころの名前（{got['sources'][0]['label'] if got['sources'] else '-'}）")

        # 意味の索引が使えないとき: 言葉を含む節だけ
        askmother.SEMANTIC = None
        mothersearch.INDEX = None
        plan_box.update(topics=["wish", "self"], **{"from": "", "to": ""})
        got = askmother.ask("欲しい物は？", config, today=datetime.date(2026, 11, 14))
        prompt = json.loads(fake.calls[-1][1]["messages"][0]["content"])
        state_snips = [s for s in prompt["snippets"] if s["source"] in ("wishlist", "profile", "decisions", "people")]
        failed += say(state_snips and all("餃子" in s["text"] for s in state_snips)
                      and not any("水筒" in s["text"] or "電気毛布" in s["text"] for s in state_snips)
                      and got["searched"]["semantic"] == 0,
                      f"意味の索引が無ければ、探し方の言葉を含む節だけ（{len(state_snips)} 件・ファイルの丸ごとではない）")
        failed += say(askmother.parse_topics({"topics": ["wish", "x", "wish"]}) == ["wish"] and askmother.parse_topics("x") == []
                      and askmother.explicit_range({"queries": [{"from": "bad", "to": ""}]}) == (None, None),
                      "topics と期間の読み方（知らないものは落とす）")
        # 意味の索引が落ちても、言葉で答える
        askmother.SEMANTIC = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("x"))
        got = askmother.ask("餃子？", config, today=datetime.date(2026, 11, 14))
        failed += say(got["found"] and got["searched"]["snippets"] >= 1, "意味の索引でつまずいても、言葉で探した結果で答える")
        askmother.SEMANTIC = None
    reset_files()
    return failed


# MARK: - 組み立ての前の Swift の検査


def check_precheck() -> int:
    failed = 0
    path = Path(__file__).resolve().parents[1] / ".github" / "scripts" / "swift_precheck.py"
    spec = importlib.util.spec_from_file_location("swift_precheck", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    q = '"'
    bad_string = f"let a: String = {q}一行目\n二行目{q}\n"
    good = (f"let a: String = {q}一行目\\n二行目{q}\nlet b = {q*3}\n複数行\n{q*3}\nlet c = #{q}生の \\(x) {q}#\n"
            f"let d = {q}中に \\(f({q}x{q})) です{q}\n// コメントの {q}\n/* {q} */\n")
    _, problems = module.lex(bad_string)
    _, none = module.lex(good)
    failed += say(len(problems) == 1 and problems[0][0] == 1 and not none,
                  f"Swift の検査: 1 行の文字列の生の改行を見つけ、複数行・生の文字列・\\( ) ・コメントは通す {none}")
    # 2026-11-13 に CI の組み立てを止めたのと同じ形（3e534a7 の前の DemoData.swift）
    long_one = ("let xs = (1...12).map { i in\n    SelfCandidate(id: \"demo-c\\(i)\", day: day, audio: \"demo.m4a\", start: Double(i * 20),"
                " end: Double(i * 20 + 6),\n                  text: \"職場の見本の発言 \\(i)\", score: 1 - Double(i) / 20,"
                " why: i % 3 == 0 ? \"plaud-most-talk\" : \"plaud-match\")\n}\n")
    loop = ("var xs: [Item] = []\nfor i in 1...12 {\n    let s: Double = Double(i * 20)\n    xs.append(Item(id: \"d\", start: s))\n}\n"
            "let ys = zs.map { $0.id }\nlet typed = (1...3).map { (i: Int) -> Item in Item(id: \"\\(i)\", day: day, start: Double(i), end: Double(i), text: \"見本の長い文の見本の長い文の見本の長い文\", score: 0.5, why: \"x\") }\n"
            "func f() {\n    let a = 1\n    let b = 2\n    print(a + b + a + b + a + b + a + b + a + b + a + b + a + b + a + b + a + b + a + b)\n}\n")
    code_long, _ = module.lex(long_one)
    code_loop, _ = module.lex(loop)
    flagged = module.long_closures(code_long, long_one)
    clean = module.long_closures(code_loop, loop)
    failed += say(len(flagged) == 1 and flagged[0][0] == 1 and not clean,
                  f"Swift の検査: 見本の長いクロージャ（式が 1 つ・型なし）を見つけ、ループ・短いもの・型を書いたものは通す {clean}")
    repo = Path(__file__).resolve().parents[1]
    found = [(p.name, line) for p in module.swift_files([repo / "LifeLog", repo / "LifeLogWatch", repo / "Shared"])
             for line, _ in module.check_file(p)] if (repo / "LifeLog").is_dir() else []
    failed += say(not found, f"Swift の検査: いまのアプリの Swift は通る {found[:5]}")
    return failed


if __name__ == "__main__":
    import lifelog_pc  # noqa: E402 — isolate_home のため（本物の HOME に書かない）

    sys.exit(1 if run(lifelog_pc) else 0)
