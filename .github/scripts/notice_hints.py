"""知らせの本文（content.body = ...）に「押すとどうなるか」の言葉があるかを数える（2026-11-23。s23 の 知8 の CI の側）。
落とさず、数だけ報告する（words.py と同じやり方）。

    python3 notice_hints.py [リポジトリの根] [書き出す所]

見るもの: Swift の `content.body = ...`（知らせの本文を決める行）。
  1. 右辺に文字列があれば、その文字列に「押すと」「長押し」「タップ」「開くと」「答えられ」などがあるか。
  2. 右辺が変数や関数（文字列が見えない）のときは、同じ行と、その上 25 行にある文字列を見る（間接。仮説: 見落としがある）。
出力: notice_hints.json と、標準出力に Markdown（ジョブの要約に貼る）。形（母艦が読む 1 行）:
  NOTICE_HINTS: total=N with=N without=N indirect_without=N
テスト・UI テスト・Vendor は数えない。
"""
import json
import os
import re
import sys

root = sys.argv[1] if len(sys.argv) > 1 else "."
out = sys.argv[2] if len(sys.argv) > 2 else "."
os.makedirs(out, exist_ok=True)

# 「押すとどうなるか」を言っている言葉
HINT = re.compile(r"押す|押し|タップ|開くと|開きます|開いて|開けば|答えると|答えられ|選べ|選んで|ここから|ボタン|→")
ASSIGN = re.compile(r"\bcontent\.body\s*=\s*(.+)$")
LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')
SKIP_DIRS = {".git", "build", "DerivedData", "Vendor", ".build", "Pods", "LifeLogTests", "LifeLogUITests"}

hits = []  # {"file","line","state","text"}  state: with / without / indirect_with / indirect_without
files = 0
for dp, dn, fn in os.walk(root):
    dn[:] = [d for d in dn if d not in SKIP_DIRS]
    for f in fn:
        if not f.endswith(".swift"):
            continue
        p = os.path.join(dp, f)
        rel = os.path.relpath(p, root).replace("\\", "/")
        files += 1
        lines = open(p, encoding="utf-8", errors="replace").read().splitlines()
        for i, line in enumerate(lines):
            s = line.strip()
            if s.startswith("//"):
                continue
            m = ASSIGN.search(line)
            if not m:
                continue
            rhs = m.group(1)
            # joined(separator: "\n") の "\n" のような、文章でない文字列は本文とは見なさない
            lits = [x for x in LITERAL.findall(rhs) if x.replace("\\n", "").strip()]
            if lits:
                text = "".join(lits)
                state = "with" if HINT.search(text) else "without"
            else:
                # 前の知らせの本文や関数の始まりより前は、別の知らせの文字列なので見ない
                start = max(0, i - 25)
                for k in range(i - 1, start - 1, -1):
                    if re.search(r"\bfunc\b|\bcontent\.body\s*=", lines[k]):
                        start = k + 1
                        break
                window = "\n".join(lines[start: i + 1])
                text = "".join(LITERAL.findall(window))
                state = "indirect_with" if HINT.search(text) else "indirect_without"
                text = rhs.strip()
            hits.append({"file": rel, "line": i + 1, "state": state, "text": text[:70]})

n = len(hits)
count = {k: sum(1 for h in hits if h["state"] == k) for k in ("with", "without", "indirect_with", "indirect_without")}
with open(os.path.join(out, "notice_hints.json"), "w", encoding="utf-8") as fh:
    json.dump({"files": files, "total": n, **count, "items": hits}, fh, ensure_ascii=False, indent=1)

print("## 知らせの本文に「押すとどうなるか」があるか（s23 知8）")
print()
print(f"- 走査: Swift {files} ファイル。`content.body = …` は **{n} か所**")
print(f"- 文字列が見えて、言葉がある: **{count['with']}** / 文字列が見えて、言葉が無い: **{count['without']}**")
print(f"- 文字列が見えない（変数・関数）。周りの文字列に言葉がある: {count['indirect_with']} / 無い: {count['indirect_without']}（間接。仮説: 見落としあり）")
print(f"- `NOTICE_HINTS: total={n} with={count['with']} without={count['without']} indirect_without={count['indirect_without']}`")
for title, state in (("言葉が無い（文字列が見える）", "without"), ("言葉が無い（間接）", "indirect_without")):
    rows = [h for h in hits if h["state"] == state]
    if rows:
        print()
        print(f"<details><summary>{title}（{len(rows)} 件。先頭 40 件）</summary>")
        print()
        print("| 場所 | 本文（または右辺） |")
        print("|---|---|")
        for h in rows[:40]:
            print(f"| {h['file']}:{h['line']} | {h['text'].replace('|', '/')} |")
        print()
        print("</details>")
print()
print("注: 報告だけで落とさない。「言葉」は 押す・タップ・開くと・答えると・選べ・ボタン・→ など（`HINT`）。本文が「今日のまとめを…」のように別の画面で読まれる文は、言葉が無くても押した先が分かることがある。")
