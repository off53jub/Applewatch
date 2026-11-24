"""LifeLog PC: 毎晩の通し試験（s25 の 大6。2026-11-24）。

見本の 1 日（作り物の音声・LINE のトーク履歴・位置）を、録音 → 文字 → 人 → タスク → 便り の順に通して、どこまで届いたかを並べる。
公開リポジトリなので、中身は全部作り物（人の名前は「見本 …」、会話も作文）。本物の記録・鍵・LINE には触らない。
Claude などの言語モデルは呼ばない（タスクを拾う所は、言語モデルの答えの見本を渡して、その先の「接地・重ねない・知らせの文」を通す）。

段（どれも ok・ng・skip のどれか。skip は「この環境では通せない」で、失敗ではない）:
  録音   試す音声（pc/testdata/sample.m4a）があり、空でない
  文字   lifelog_pc.py --test の出力（--asr）から、見本の文との文字の違い（CER）をモデルごとに。いちばん良い CER が 0.15 以下で ok（仮）
  位置   見本の年表（digests/timeline の「位置」の行）から、その時刻の場所の名前が出るか（placehints.words_at）
  LINE   見本のトーク履歴（.txt）を行に分けられるか（日付・時刻・話し手・文）
  人     声の特徴が出るか（lifelog_pc.py --check-extras の出力 --extras）と、行の話し手の扱い（自分・人物 N を名前にしない）
  タスク 文字の段の文・LINE の行に、言語モデルの答えの見本を当てて、文に無い引用を捨て、文にあるものだけ残るか（promises.ground）
  便り   残ったものから知らせの文ができ、「中身を出さない」では中身が出ないか（promises.push_text）

使い方:
  python pc/s25c_nightly.py [--asr test.txt] [--extras extras.txt] [--out result.json]
                            [--history-in old.jsonl] [--history-out history.jsonl] [--summary summary.md]
いつも 0 で終わる（落ちたかは結果の中に書く。毎晩の実行が赤になって知らせが増えないように）。
1 行の印: 「S25C_NIGHTLY: version=… commit=… ok=… ng=… skip=…」（母艦が探す）。
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import sys
import tempfile
import traceback
import unicodedata
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

REFERENCE = "今日の会議では、来月の予算と、新しいシステムの導入について話し合いました。"
CER_OK = 0.15  # 仮
HISTORY_KEEP = 60

# 見本の LINE のトーク履歴（LINE の「トーク履歴を送信」の形。作り物）
SAMPLE_LINE = """[LINE] 見本のグループのトーク履歴
保存日時：2026/11/24 23:00

2026/11/24(火)
9:05\t見本 太郎\t明日の見本の資料、昼までに送ってもらえますか
9:06\t自分\tわかりました、明日の昼までに送ります
9:07\t人物12\tスタンプ
12:30\t見本 太郎\tありがとうございます
"""

LINE_ROW = re.compile(r"^(\d{1,2}):(\d{2})\t([^\t]+)\t(.*)$")
LINE_DAY = re.compile(r"^(\d{4})/(\d{1,2})/(\d{1,2})\(.\)$")


def norm(text: str) -> str:
    """句読点・空白を除いて比べる"""
    t = unicodedata.normalize("NFKC", text or "")
    return "".join(ch for ch in t if not unicodedata.category(ch).startswith(("P", "Z", "S")))


def cer(ref: str, hyp: str) -> float:
    a, b = norm(ref), norm(hyp)
    if not a:
        return 0.0 if not b else 1.0
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i] + [0] * len(b)
        for j, cb in enumerate(b, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb))
        prev = cur
    return round(prev[-1] / len(a), 4)


def parse_asr(text: str) -> dict:
    """--test の出力から {"best": 文, "engines": {名前: 文}}"""
    best, engines = "", {}
    for line in text.splitlines():
        m = re.match(r"^\[[\d.]+-[\d.]+\]\s*(.*?)\s*（確からしさ", line)
        if m and not best:
            best = m[1]
            continue
        m = re.match(r"^\s{2,}([a-z_]+):\s*(.*)$", line)
        if m and m[1] not in engines:
            engines[m[1]] = m[2].strip()
    return {"best": best, "engines": engines}


def parse_line_export(text: str) -> list[dict]:
    """LINE のトーク履歴（.txt）を行に [{"time": ms, "speaker", "speakerID", "text"}]（自分は speakerID "me"）"""
    day = None
    rows = []
    for raw in text.splitlines():
        raw = raw.rstrip("\r")
        m = LINE_DAY.match(raw)
        if m:
            day = datetime.date(int(m[1]), int(m[2]), int(m[3]))
            continue
        m = LINE_ROW.match(raw)
        if not m or day is None:
            continue
        when = datetime.datetime(day.year, day.month, day.day, int(m[1]), int(m[2]))
        speaker = m[3].strip()
        rows.append({"time": int(when.timestamp() * 1000), "speaker": speaker,
                     "speakerID": "me" if speaker == "自分" else "", "text": m[4].strip()})
    return rows


class Run:
    def __init__(self) -> None:
        self.stages: list[dict] = []

    def add(self, name: str, status: str, detail: str, **extra) -> dict:
        row = {"name": name, "status": status, "detail": detail}
        row.update(extra)
        self.stages.append(row)
        print(f"{status.upper():4} {name}: {detail}")
        return row

    def guard(self, name: str, fn) -> None:
        try:
            fn()
        except Exception as e:  # 1 つの段が壊れても、ほかの段は続ける
            self.add(name, "ng", f"{type(e).__name__}: {e}"[:300])
            traceback.print_exc()


def version_of() -> str:
    try:
        text = (HERE / "lifelog_pc.py").read_text(encoding="utf-8")
        m = re.search(r"^VERSION = (\d+)", text, re.M)
        return m[1] if m else "?"
    except OSError:
        return "?"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="毎晩の通し試験（見本の 1 日）")
    ap.add_argument("--sample", default=str(HERE / "testdata" / "sample.m4a"))
    ap.add_argument("--asr", help="lifelog_pc.py --test の出力")
    ap.add_argument("--extras", help="lifelog_pc.py --check-extras の出力")
    ap.add_argument("--out", help="結果の JSON")
    ap.add_argument("--history-in", help="前までの結果（jsonl）")
    ap.add_argument("--history-out", help="今回を足した結果（jsonl）")
    ap.add_argument("--summary", help="版ごとの表（markdown）を足すファイル")
    args = ap.parse_args(argv)

    run = Run()
    asr: dict = {"best": "", "engines": {}}
    line_rows: list[dict] = []

    # 録音
    def record() -> None:
        p = Path(args.sample)
        if p.is_file() and p.stat().st_size > 1000:
            run.add("録音", "ok", f"試す音声 {p.stat().st_size} バイト")
        else:
            run.add("録音", "ng", "試す音声が無い・空")
    run.guard("録音", record)

    # 文字
    def text() -> None:
        nonlocal asr
        if not args.asr or not Path(args.asr).is_file():
            run.add("文字", "skip", "文字起こしの出力が無い（モデルを動かさない実行）")
            return
        asr = parse_asr(Path(args.asr).read_text(encoding="utf-8", errors="replace"))
        if not asr["best"]:
            run.add("文字", "ng", "文字起こしの出力に文が無い")
            return
        scores = {name: cer(REFERENCE, t) for name, t in asr["engines"].items()}
        best = cer(REFERENCE, asr["best"])
        run.add("文字", "ok" if best <= CER_OK else "ng", f"選んだ文の CER {best}（{CER_OK} 以下で ok・仮）",
                cer=best, engines=scores)
    run.guard("文字", text)

    # 位置
    def place() -> None:
        import placehints
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            now = datetime.datetime.now().replace(hour=9, minute=30, second=0, microsecond=0)
            day = now.strftime("%Y-%m-%d")
            (base / "digests" / "timeline").mkdir(parents=True)
            rows = [{"lane": "位置", "time": "9:00", "end": "10:00", "place": "見本の駅前"},
                    {"lane": "位置", "time": "13:00", "end": "14:00", "place": "見本の公園"}]
            (base / "digests" / "timeline" / f"{day}.json").write_text(json.dumps({"rows": rows}, ensure_ascii=False),
                                                                        encoding="utf-8")
            if hasattr(placehints, "clear_cache"):
                placehints.clear_cache()
            words = placehints.words_at(base, now.timestamp())
            ok = "見本の駅前" in words and "見本の公園" not in words[:1]
            run.add("位置", "ok" if ok else "ng", f"9:30 の場所の名前: {words[:3]}")
    run.guard("位置", place)

    # LINE
    def line() -> None:
        nonlocal line_rows
        line_rows = parse_line_export(SAMPLE_LINE)
        ok = len(line_rows) == 4 and line_rows[1]["speakerID"] == "me"
        run.add("LINE", "ok" if ok else "ng", f"見本のトーク履歴から {len(line_rows)} 行（4 行のはず）")
    run.guard("LINE", line)

    # 人
    def person() -> None:
        import promises
        notes = []
        status = "ok"
        if args.extras and Path(args.extras).is_file():
            extras = Path(args.extras).read_text(encoding="utf-8", errors="replace")
            if re.search(r"^OK 区間ごとに声の特徴が出る", extras, re.M):
                notes.append("声の特徴 ok")
            else:
                status = "ng"
                notes.append("声の特徴が出ていない")
        else:
            notes.append("声の特徴は見ていない（モデルを動かさない実行）")
        rows = promises.transcript(line_rows) if line_rows else []
        speakers = [r["speaker"] for r in rows]
        if promises.SELF_NAME not in speakers:
            status = "ng"
            notes.append("自分の行が「自分」にならない")
        answer = {"items": [{"line": 0, "quote": "昼までに送って", "kind": "asked", "who": "人物12", "what": "見本の資料を送る"}]}
        kept = promises.ground(answer, line_rows)
        if kept and kept[0]["who"]:
            status = "ng"
            notes.append("人物 N を名前にした")
        else:
            notes.append("人物 N は名前にしない ok")
        run.add("人", status, "・".join(notes))
    run.guard("人", person)

    kept_all: list[dict] = []

    # タスク
    def task() -> None:
        import promises
        notes = []
        status = "ok"
        # LINE の行: 文にある引用は残り、文に無い引用は捨てる
        answer = {"items": [
            {"line": 1, "quote": "明日の昼までに送ります", "kind": "promised", "who": "", "what": "見本の資料を送る", "due": "明日の昼"},
            {"line": 3, "quote": "請求書を今日中に", "kind": "asked", "who": "見本 太郎", "what": "見本の請求書を出す"},
        ]}
        kept = promises.ground(answer, line_rows)
        if [k["what"] for k in kept] != ["見本の資料を送る"]:
            status = "ng"
        notes.append(f"LINE: 2 件のうち {len(kept)} 件が残った（1 件のはず）")
        kept_all.extend(kept)
        # 録音の文: 文字の段の文に引用があれば残る（文字が崩れると、ここで消える＝通しで見る所）
        if asr["best"]:
            lines = [{"time": 0, "speaker": "自分", "speakerID": "me", "text": asr["best"]}]
            got = promises.ground({"items": [{"line": 0, "quote": "来月の予算", "kind": "promised", "who": "",
                                              "what": "来月の予算を見直す"}]}, lines)
            if not got:
                status = "ng"
            notes.append("録音の文から " + ("拾えた" if got else "拾えない（文字が崩れた）"))
            kept_all.extend(got)
        else:
            notes.append("録音の文は無し（文字の段を通していない）")
        run.add("タスク", status, "・".join(notes))
    run.guard("タスク", task)

    # 便り
    def letter() -> None:
        import promises
        if not kept_all:
            run.add("便り", "ng", "タスクの段で何も残らなかった")
            return
        title, body = promises.push_text(kept_all, hide=False)
        _, hidden = promises.push_text(kept_all, hide=True)
        ok = bool(title) and kept_all[0]["what"] in body and kept_all[0]["what"] not in hidden
        run.add("便り", "ok" if ok else "ng", f"知らせの文 {len(body)} 字・中身を出さない文に中身が無い: {kept_all[0]['what'] not in hidden}")
    run.guard("便り", letter)

    counts = {s: sum(1 for r in run.stages if r["status"] == s) for s in ("ok", "ng", "skip")}
    result = {
        "at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "version": version_of(),
        "commit": (os.environ.get("GITHUB_SHA") or "")[:10],
        "run": os.environ.get("GITHUB_RUN_ID") or "",
        "counts": counts,
        "stages": run.stages,
    }
    line_mark = (f"S25C_NIGHTLY: version={result['version']} commit={result['commit'] or '-'} "
                 f"ok={counts['ok']} ng={counts['ng']} skip={counts['skip']}")
    print(line_mark)
    if args.out:
        Path(args.out).write_text(json.dumps(result, ensure_ascii=False, indent=1), encoding="utf-8")

    history: list[dict] = []
    if args.history_in and Path(args.history_in).is_file():
        for raw in Path(args.history_in).read_text(encoding="utf-8", errors="replace").splitlines():
            try:
                row = json.loads(raw)
            except ValueError:
                continue
            if isinstance(row, dict) and "stages" in row:
                history.append(row)
    history.append(result)
    history = history[-HISTORY_KEEP:]
    if args.history_out:
        Path(args.history_out).write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in history), encoding="utf-8")
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as f:
            f.write(table(history, line_mark))
    return 0


MARK = {"ok": "○", "ng": "×", "skip": "－"}
NAMES = ["録音", "文字", "位置", "LINE", "人", "タスク", "便り"]


def table(history: list[dict], line_mark: str) -> str:
    """版ごとの表（新しい順に 14 回まで）"""
    out = ["### 毎晩の通し試験（s25 の 大6・見本の 1 日）", "", f"`{line_mark}`", "",
           "| 日時（UTC） | 版 | コミット | " + " | ".join(NAMES) + " | 文字の CER |",
           "|---|---|---|" + "---|" * len(NAMES) + "---|"]
    for r in reversed(history[-14:]):
        by = {s["name"]: s for s in r.get("stages", [])}
        marks = [MARK.get(by.get(n, {}).get("status", ""), "") for n in NAMES]
        c = by.get("文字", {}).get("cer")
        out.append(f"| {r.get('at', '')[:16]} | {r.get('version', '')} | {r.get('commit', '')} | " + " | ".join(marks)
                   + f" | {'' if c is None else c} |")
    latest = history[-1]
    out += ["", "今回の段:"]
    for s in latest.get("stages", []):
        out.append(f"- {MARK.get(s['status'], '')} {s['name']}: {s['detail']}")
    out.append("")
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # 結果が出せなくても、毎晩の実行は赤にしない
        traceback.print_exc()
        print("S25C_NIGHTLY: version=? commit=- ok=0 ng=1 skip=0")
        sys.exit(0)
