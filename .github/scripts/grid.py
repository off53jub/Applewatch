"""主な 20 画面（明・暗・文字最大）の写真を 1 枚に並べ、文字最大ではみ出した所の報告をまとめる（s22 見1・見2）。

使い方: python grid.py <xcresulttool export attachments の出力> <書き出す所>
作るもの（書き出す所に）:
  grid.png        … 20 画面 × 3 通りを 1 枚に（上の段が 1〜10・下の段が 11〜20。各段で 明 → 暗 → 最大 の順）
  grid.html       … 同じ内容を 1 つの HTML に（画像を埋め込み。スマホで見やすい）
  overflow.json   … 見2 の報告（はみ出し・つぶれ・省略の印）
  summary.md      … ジョブの要約に貼る文
  shots/          … 1 枚ずつの PNG
画面の写真は撮れた分だけ並べる（無い所は空き）。落とさず、数だけ出す。
"""
import base64
import io
import json
import os
import re
import shutil
import sys
from collections import Counter

srcs, out = sys.argv[1:-1], sys.argv[-1]
os.makedirs(os.path.join(out, "shots"), exist_ok=True)

MODES = ["明", "暗", "最大"]
MODE_LABEL = {"明": "明るい", "暗": "暗い", "最大": "文字最大"}

manifests = []
for src in srcs:
    with open(os.path.join(src, "manifest.json"), encoding="utf-8") as f:
        manifests.append((src, json.load(f)))

shots = {}  # (mode, index) -> (name, path, reached)
findings = []
entries = [(src, a) for src, manifest in manifests for test in manifest for a in test.get("attachments", [])]
for src, a in entries:
    if True:
        name = a.get("suggestedHumanReadableName") or a["exportedFileName"]
        name = re.sub(r"(_\d+)?_[0-9A-Fa-f-]{36}(\.\w+)?$", "", name)
        path = os.path.join(src, a["exportedFileName"])
        parts = name.split("|")
        if parts[0] == "報告":
            try:
                with open(path, encoding="utf-8") as g:
                    findings += json.load(g)
            except Exception as e:  # 報告が読めなくても、写真の一覧は作る
                print("報告が読めない:", path, e)
            continue
        if len(parts) < 4:
            continue
        mode = parts[0].split(" ", 1)[-1]
        try:
            idx = int(parts[1])
        except ValueError:
            continue
        shots[(mode, idx)] = (parts[2], path, parts[3].split(".")[0] == "1")
        safe = re.sub(r'[\\/:*?"<>|›]', "-", f"{mode}-{idx:02d}-{parts[2]}")
        shutil.copyfile(path, os.path.join(out, "shots", safe + ".png"))

print(f"写真 {len(shots)} 枚・報告 {len(findings)} 件")

# 見2 の報告
with open(os.path.join(out, "overflow.json"), "w", encoding="utf-8") as f:
    json.dump(findings, f, ensure_ascii=False, indent=1)

kinds = Counter(x["kind"] for x in findings)
by_mode = Counter((x["mode"], x["kind"]) for x in findings)
lines = ["## 画面の一覧（s22 見1・見2）", ""]
lines.append(f"- 撮れた写真: {len(shots)} 枚（20 画面 × 3 通り = 60 枚が満点）")
missing = sorted((m, i) for m in MODES for i in range(1, 21) if (m, i) not in shots)
unreached = sorted((m, i, shots[(m, i)][0]) for (m, i) in shots if not shots[(m, i)][2])
lines.append(f"- 撮れなかった: {len(missing)} 枚 / 開けなかった（行が見つからない）: {len(unreached)} 枚")
lines.append(f"- 文字最大などで見つけた報告: {len(findings)} 件（" + "・".join(f"{k} {v}" for k, v in kinds.items()) + "）" if findings
             else "- 見つけた報告: 0 件")
# s23 続9: 文字最大のはみ出しを、前の測り（見2。10 件・全部「今日」の画面）と並べる。母艦は「OVERFLOW_LARGE:」の行を読める
large_over = [x for x in findings if x["mode"] == "最大" and x["kind"] == "はみ出し"]
by_screen = Counter(x["screen"] for x in large_over)
BASELINE = 10
lines.append("")
lines.append(f"- 文字最大のはみ出し（続9）: **{len(large_over)} 件**（見2 の測りは {BASELINE} 件・全部「今日」の画面。画面ごと: "
             + ("・".join(f"{k} {v}" for k, v in by_screen.most_common()) if by_screen else "なし") + "）")
lines.append(f"- `OVERFLOW_LARGE: count={len(large_over)} baseline={BASELINE} shots={len(shots)}`")
print(f"OVERFLOW_LARGE: count={len(large_over)} baseline={BASELINE} shots={len(shots)}")
lines.append("")
lines.append("| 通り | はみ出し | 省略の印 | つぶれ |")
lines.append("|---|---:|---:|---:|")
for m in MODES:
    lines.append(f"| {MODE_LABEL[m]} | {by_mode[(m, 'はみ出し')]} | {by_mode[(m, '省略の印')]} | {by_mode[(m, 'つぶれ')]} |")
if findings:
    lines += ["", "<details><summary>報告の中身（先頭 60 件）</summary>", "", "| 種類 | 通り | 画面 | 文字 | 位置 |", "|---|---|---|---|---|"]
    for x in findings[:60]:
        lab = x["label"].replace("|", "/")
        lines.append(f"| {x['kind']} | {MODE_LABEL.get(x['mode'], x['mode'])} | {x['screen']} | {lab} | {x['frame']} |")
    lines += ["", "</details>"]
if unreached:
    lines += ["", "開けなかった画面: " + "、".join(f"{MODE_LABEL.get(m, m)}の{n}" for m, _, n in unreached[:20])]
lines += ["", "注: SwiftUI が自動で「…」に縮めた文字は、読める文字が変わらないので数えられない（仮説）。数えるのは、枠が画面の横にはみ出す・幅がほぼ無い・文字そのものが「…」で終わる、の 3 つだけ。"]
with open(os.path.join(out, "summary.md"), "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    print("Pillow が無いので並べた画像は作らない")
    sys.exit(0)

font = None
for p in ["/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc", "/System/Library/Fonts/Hiragino Sans GB.ttc"]:
    if os.path.exists(p):
        font = ImageFont.truetype(p, 22)
        break
font = font or ImageFont.load_default()

TW = 190  # 1 枚の幅
PAD = 12
head = 34
label_w = 90
blocks = [range(1, 11), range(11, 21)]
tile_h = 0
for (mode, idx), (_, path, _) in shots.items():
    with Image.open(path) as im:
        tile_h = max(tile_h, int(im.height * TW / im.width))
tile_h = tile_h or 400
row_h = tile_h + PAD
block_h = head + len(MODES) * row_h + PAD
W = label_w + 10 * (TW + PAD) + PAD
H = len(blocks) * block_h + PAD
sheet = Image.new("RGB", (W, H), "white")
d = ImageDraw.Draw(sheet)
for b, rng in enumerate(blocks):
    y0 = PAD + b * block_h
    for c, idx in enumerate(rng):
        name = next((shots[(m, idx)][0] for m in MODES if (m, idx) in shots), f"{idx}")
        d.text((label_w + c * (TW + PAD), y0), f"{idx} {name}"[:11], fill="black", font=font)
    for r, mode in enumerate(MODES):
        y = y0 + head + r * row_h
        d.text((6, y + tile_h // 2), MODE_LABEL[mode], fill="black", font=font)
        for c, idx in enumerate(rng):
            x = label_w + c * (TW + PAD)
            t = shots.get((mode, idx))
            if not t:
                d.rectangle([x, y, x + TW, y + tile_h], outline="#cc0000")
                d.text((x + 8, y + 8), "無い", fill="#cc0000", font=font)
                continue
            with Image.open(t[1]) as im:
                im = im.convert("RGB").resize((TW, int(im.height * TW / im.width)))
            sheet.paste(im, (x, y))
            d.rectangle([x - 1, y - 1, x + TW, y + im.height], outline="#cc0000" if not t[2] else "#999999", width=2 if not t[2] else 1)
sheet.save(os.path.join(out, "grid.png"))
buf = io.BytesIO()
sheet.convert("RGB").save(buf, "JPEG", quality=80)
b64 = base64.b64encode(buf.getvalue()).decode()
with open(os.path.join(out, "grid.html"), "w", encoding="utf-8") as f:
    f.write("<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>"
            "<title>画面の一覧</title><body style='margin:0;font-family:sans-serif'>"
            f"<p style='padding:8px'>主な 20 画面 × 明・暗・文字最大（赤い枠は、その画面を開けなかった所）</p><img style='max-width:none' src='data:image/jpeg;base64,{b64}'></body>")
print("並べた画像を作った", sheet.size)
