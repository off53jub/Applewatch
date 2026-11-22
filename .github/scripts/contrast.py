"""色の読みやすさを数える（s22 見3）。Shared/Design/LLTheme.swift の色の組から WCAG のコントラスト比を計算し、
基準に届かない組を報告する。落とさない（常に 0 で終わる）。

    python3 contrast.py [LLTheme.swift] [書き出す所]

基準: 文字は 4.5 以上（大きい文字は 3 でよいが、ここでは使う大きさを知らないので 4.5 で数える）。
線（line）と地・面の差は文字ではないので、参考として 3 を基準に別に出す。
出力: contrast.json と、標準出力に Markdown（ジョブの要約に貼る）。
"""
import json
import os
import re
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "Shared/Design/LLTheme.swift"
out = sys.argv[2] if len(sys.argv) > 2 else "."
os.makedirs(out, exist_ok=True)

src = open(path, encoding="utf-8").read()
colors = {}
for m in re.finditer(r"static let (\w+) = Color\.ll\(light: 0x([0-9A-Fa-f]{6}), dark: 0x([0-9A-Fa-f]{6})\)", src):
    colors[m.group(1)] = {"light": int(m.group(2), 16), "dark": int(m.group(3), 16)}


def lum(rgb):
    def ch(v):
        v /= 255
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    return 0.2126 * ch((rgb >> 16) & 255) + 0.7152 * ch((rgb >> 8) & 255) + 0.0722 * ch(rgb & 255)


def ratio(a, b):
    la, lb = lum(a), lum(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


NAMES = {"bg": "地", "surface": "面", "surface2": "面2", "line": "線", "text": "文字", "dim": "薄い文字",
         "accent": "差し色", "warn": "注意", "danger": "危ない", "good": "よかった"}
TEXTS = ["text", "dim", "accent", "warn", "danger", "good"]
GROUNDS = ["bg", "surface", "surface2"]

rows = []
for t in TEXTS:
    for g in GROUNDS:
        for mode in ("light", "dark"):
            if t in colors and g in colors:
                r = ratio(colors[t][mode], colors[g][mode])
                rows.append({"kind": "文字", "mode": mode, "fg": t, "bg": g, "ratio": round(r, 2), "need": 4.5, "ok": r >= 4.5})
for g in GROUNDS:
    for mode in ("light", "dark"):
        if "line" in colors and g in colors:
            r = ratio(colors["line"][mode], colors[g][mode])
            rows.append({"kind": "線（参考）", "mode": mode, "fg": "line", "bg": g, "ratio": round(r, 2), "need": 3.0, "ok": r >= 3.0})

text_rows = [r for r in rows if r["kind"] == "文字"]
bad = [r for r in text_rows if not r["ok"]]
bad_line = [r for r in rows if r["kind"] != "文字" and not r["ok"]]
with open(os.path.join(out, "contrast.json"), "w", encoding="utf-8") as f:
    json.dump({"colors": len(colors), "pairs": len(text_rows), "below": bad, "line_below": bad_line, "all": rows}, f, ensure_ascii=False, indent=1)

L = {"light": "明", "dark": "暗"}
print("## 色の読みやすさ（s22 見3）")
print()
print(f"- 読んだ色: {len(colors)} 個（LLTheme.swift）。文字と地の組: {len(text_rows)} 組。**4.5 未満: {len(bad)} 組**")
print(f"- 線と地の組（参考・3 を基準）: 3 未満 {len(bad_line)} 組（文字ではないので、数だけ）")
print()
if bad:
    print("| 通り | 文字の色 | 地 | 比 |")
    print("|---|---|---|---:|")
    for r in sorted(bad, key=lambda x: x["ratio"]):
        print(f"| {L[r['mode']]} | {NAMES[r['fg']]}（{r['fg']}） | {NAMES[r['bg']]}（{r['bg']}） | {r['ratio']:.2f} |")
else:
    print("4.5 未満の組はありません。")
print()
print("注: 計算は LLTheme.swift の色の組だけ。画面ごとに .opacity() で薄くした文字や、写真・グラフの上の文字は数えていない（仮説: 実際はもっと低い所がある）。")
