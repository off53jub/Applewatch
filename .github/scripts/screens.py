"""画面の自動確認で撮った写真を、名前の付いた PNG と、スマホで見やすい一覧の画像（sheet-NN.jpg）にする。

使い方: python screens.py <xcresulttool export attachments の出力> <書き出す所>
一覧の画像は Pillow があるときだけ作る（無ければ PNG だけ）。
"""
import json
import os
import re
import shutil
import sys

src, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)

with open(os.path.join(src, "manifest.json"), encoding="utf-8") as f:
    manifest = json.load(f)

shots = []
for test in manifest:
    for a in test.get("attachments", []):
        name = a.get("suggestedHumanReadableName") or a["exportedFileName"]
        # 「001 今日_0_XXXXXXXX-....png」→「001 今日」
        name = re.sub(r"(_\d+)?_[0-9A-Fa-f-]{36}(\.\w+)?$", "", name)
        name = re.sub(r"\.png$", "", name)
        safe = re.sub(r'[\\/:*?"<>|›]', "-", name).strip()
        dest = os.path.join(out, safe + ".png")
        shutil.copyfile(os.path.join(src, a["exportedFileName"]), dest)
        shots.append((name, dest))

shots.sort()
print(f"写真 {len(shots)} 枚")

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    print("Pillow が無いので一覧の画像は作らない")
    sys.exit(0)

font = None
for path in ["/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc", "/System/Library/Fonts/Hiragino Sans GB.ttc"]:
    if os.path.exists(path):
        font = ImageFont.truetype(path, 26)
        break
font = font or ImageFont.load_default()

cols, rows, width = 3, 3, 390
per = cols * rows
for n in range(0, len(shots), per):
    group = shots[n:n + per]
    tiles = []
    for name, path in group:
        im = Image.open(path).convert("RGB")
        h = int(im.height * width / im.width)
        tiles.append((name, im.resize((width, h))))
    tile_h = max(t[1].height for t in tiles) + 70
    sheet = Image.new("RGB", (cols * (width + 20) + 20, ((len(tiles) + cols - 1) // cols) * tile_h + 20), "white")
    draw = ImageDraw.Draw(sheet)
    for i, (name, im) in enumerate(tiles):
        x = 20 + (i % cols) * (width + 20)
        y = 20 + (i // cols) * tile_h
        draw.text((x, y), name[:22], fill="black", font=font)
        sheet.paste(im, (x, y + 50))
        draw.rectangle([x - 1, y + 49, x + width, y + 50 + im.height], outline="#999999")
    sheet.save(os.path.join(out, f"sheet-{n // per + 1:02d}.jpg"), quality=70)
print("一覧の画像を作った")
