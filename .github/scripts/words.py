"""画面に出る Swift の文字列に、内輪の言葉や英語の日付の書き方が残っていないかを数える（s22 見4）。落とさず、数だけ報告する。

    python3 words.py [リポジトリの根] [書き出す所]

1. 内輪の言葉: docs/s20-design.md の「5. 言葉をそろえる」の表の左の列（区切り・様子・札・母艦 …）。
   画面に出る文字列（Text・Label・Button・navigationTitle などの最初の文字列）に入っていたら数える。
   「言葉の一覧」の画面そのもの（GlossaryView など、わざと内輪の言葉を説明する所）は数えない。
2. 英語の日付: DateFormatter の dateFormat に MMM・EEE（英語の月・曜日の名前が出る形）があり、日本語の locale を付けていない所（要確認）。
   画面の文字列に Today・Yesterday・Mon などの英語の語があるもの。
3. 英語だけの表示: 画面に出る文字列が、英字だけ（記号・数字は除く）で 2 語以上のもの。
出力: words.json と、標準出力に Markdown（ジョブの要約に貼る）。
"""
import json
import os
import re
import sys

root = sys.argv[1] if len(sys.argv) > 1 else "."
out = sys.argv[2] if len(sys.argv) > 2 else "."
os.makedirs(out, exist_ok=True)

# 1. 内輪の言葉（文書の表の左の列から読む。読めなければ、決め打ちの一覧）
terms = []
try:
    text = open(os.path.join(root, "docs/s20-design.md"), encoding="utf-8").read()
    sec = text.split("## 5.", 1)[1].split("\n## ", 1)[0]
    for line in sec.splitlines():
        m = re.match(r"\|\s*([^|]+?)\s*\|", line)
        if m and m.group(1) not in ("内輪の言葉",) and not set(m.group(1)) <= set("-: "):
            terms.append(re.sub(r"[（(].*$", "", m.group(1)).strip())
except Exception:
    pass
if not terms:
    terms = ["区切り", "様子", "札", "母艦", "見立て", "確かめ待ち", "便り", "帯", "多数決", "写し", "休む場所", "場面のセット"]

# 短い語が、別の語の一部として出る所は数えない（時間帯・名札・書き写し など）
NOT_AFTER = {"帯": "時間年世携", "札": "名改入お表立", "写し": "書"}
NOT_BEFORE = {"帯": "域", "札": "", "写し": "", "様子": ""}

UI_CALL = re.compile(
    r'\b(?:Text|Label|Button|Section|Toggle|Picker|NavigationLink|LabeledContent|Link|TextField|SecureField|Stepper|'
    r'DisclosureGroup|ContentUnavailableView|Menu|GroupBox|navigationTitle|help|accessibilityLabel|accessibilityHint|'
    r'accessibilityValue|alert|confirmationDialog|badge|caption|headline)\(\s*(?:verbatim:\s*)?"((?:[^"\\]|\\.)*)"')
SKIP_DIRS = {".git", "build", "DerivedData", "Vendor", ".build", "Pods", "LifeLogTests", "LifeLogUITests"}
# 内輪の言葉を説明するための画面（言葉の一覧）。わざと出す
EXEMPT_FILES = {"S20SettingsViews.swift": ("GlossaryView", "Glossary")}

dates_fmt = re.compile(r'dateFormat\s*=\s*"([^"]*)"')
eng_words = re.compile(r"\b(Today|Yesterday|Tomorrow|Mon|Tue|Wed|Thu|Fri|Sat|Sun|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Oct|Nov|Dec|AM|PM)\b")

term_hits, date_hits, english_hits = [], [], []
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
        exempt_from = None
        if f in EXEMPT_FILES:
            for i, l in enumerate(lines):
                if any(re.search(r"struct\s+" + n, l) for n in EXEMPT_FILES[f]):
                    exempt_from = i
                    break
        for i, line in enumerate(lines):
            s = line.strip()
            if s.startswith("//") or s.startswith("///"):
                continue
            # 一覧の画面そのものは数えない（その struct の中。ファイルの最後まで）
            exempt = exempt_from is not None and i >= exempt_from
            # 2. 英語の日付
            for m in dates_fmt.finditer(line):
                fmt = m.group(1)
                if re.search(r"MMM|EEE", fmt):
                    window = "\n".join(lines[max(0, i - 6): i + 6])
                    if not re.search(r"ja_JP|\bLL\.ja\b|Locale\(identifier: \"ja", window):
                        date_hits.append({"kind": "英語の日付（要確認）", "file": rel, "line": i + 1, "text": fmt})
            for m in UI_CALL.finditer(line):
                lit = m.group(1)
                # 3. 英語の日付の語・英語だけの表示
                if eng_words.search(lit) and not re.search(r"[ぁ-んァ-ヶ一-龠]", lit):
                    date_hits.append({"kind": "英語の日付の語", "file": rel, "line": i + 1, "text": lit})
                words = re.findall(r"[A-Za-z]{2,}", lit)
                if len(words) >= 2 and not re.search(r"[ぁ-んァ-ヶ一-龠]", lit) and not re.search(r"\\\(", lit):
                    english_hits.append({"kind": "英語だけの表示", "file": rel, "line": i + 1, "text": lit})
                # 1. 内輪の言葉
                if exempt:
                    continue
                for t in terms:
                    for mm in re.finditer(re.escape(t), lit):
                        a, b = mm.start(), mm.end()
                        if a > 0 and lit[a - 1] in NOT_AFTER.get(t, ""):
                            continue
                        if b < len(lit) and lit[b] in NOT_BEFORE.get(t, ""):
                            continue
                        term_hits.append({"kind": "内輪の言葉", "term": t, "file": rel, "line": i + 1, "text": lit[:60]})
                        break

with open(os.path.join(out, "words.json"), "w", encoding="utf-8") as fh:
    json.dump({"terms": terms, "files": files, "inner": term_hits, "dates": date_hits, "english": english_hits},
              fh, ensure_ascii=False, indent=1)

from collections import Counter
c = Counter(h["term"] for h in term_hits)
print("## 画面の言葉（s22 見4）")
print()
print(f"- 走査: Swift {files} ファイル（アプリ・時計・ウィジェット・共有。テストは除く）")
print(f"- 内輪の言葉（{'・'.join(terms)}）が画面の文字に残っている: **{len(term_hits)} 件**"
      + ("（" + "・".join(f"{t} {n}" for t, n in c.most_common()) + "）" if c else ""))
print(f"- 英語の日付の書き方（要確認）: **{len(date_hits)} 件**")
print(f"- 英語だけの表示文字: **{len(english_hits)} 件**")
for title, hits in (("内輪の言葉", term_hits), ("英語の日付", date_hits), ("英語だけの表示", english_hits)):
    if hits:
        print()
        print(f"<details><summary>{title}（先頭 40 件）</summary>")
        print()
        print("| 場所 | 文字 |")
        print("|---|---|")
        for h in hits[:40]:
            print(f"| {h['file']}:{h['line']} | {h['text'].replace('|', '/')} |")
        print()
        print("</details>")
print()
print("注: 画面に出る文字列は、Text・Label・Button・navigationTitle などの呼び出しの最初の文字列だけを見ている。変数を通って出る文字は数えていない（仮説: 実際はもっと多い）。")
