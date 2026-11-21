"""アプリと時計のアイコン（s20 の 追1・夜の青。2026-11-21）を描いて PNG に書き出す。

    python .github/scripts/make_icons.py

LifeLog/Assets.xcassets/AppIcon.appiconset/icon-1024.png と LifeLogWatch/Assets.xcassets/AppIcon.appiconset/icon-1024.png を
書き直す（前のアイコンは AppIconClassic.appiconset に残し、設定の「見た目」から選べる）。Pillow が要る。
色は Shared/Design/LLTheme.swift と同じ: 地 #0B1220・面 #121A2B・線 #22304A・薄い文字 #8A9BB8・差し色 #5BC8F5。
"""
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

S = 1024
K = 4  # なめらかにするため 4 倍で描いて縮める
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def hexrgb(h):
    return tuple(int(h[i:i + 2], 16) for i in (1, 3, 5))


BG, SURFACE, LINE, DIM, ACCENT = map(hexrgb, ["#0B1220", "#121A2B", "#22304A", "#8A9BB8", "#5BC8F5"])


def draw(watch=False):
    n = S * K
    img = Image.new("RGB", (n, n), BG)
    # 地: 下から上へ、ごく薄く明るくなる紺（夜明け前の空）
    grad = Image.new("RGB", (1, n))
    for y in range(n):
        t = y / (n - 1)
        c = tuple(int(BG[i] + (SURFACE[i] - BG[i]) * (t ** 1.4) * 1.6) for i in range(3))
        grad.putpixel((0, y), tuple(min(255, v) for v in c))
    img = grad.resize((n, n))
    # 差し色の光（中央のやや下に、ぼかした丸）
    glow = Image.new("RGB", (n, n), (0, 0, 0))
    gd = ImageDraw.Draw(glow)
    r = int(n * 0.30)
    cx, cy = n // 2, int(n * 0.56)
    gd.ellipse([cx - r, cy - r, cx + r, cy + r], fill=tuple(int(v * 0.22) for v in ACCENT))
    glow = glow.filter(ImageFilter.GaussianBlur(n * 0.09))
    img = add(img, glow)
    d = ImageDraw.Draw(img)
    # 地平線（細い線）
    hy = int(n * 0.69)
    d.rounded_rectangle([int(n * 0.16), hy, int(n * 0.84), hy + int(n * 0.006)], radius=n, fill=LINE)
    # 声の波（薄い文字の色。まん中の 1 本だけ差し色）
    heights = [0.07, 0.13, 0.22, 0.17, 0.40, 0.25, 0.15, 0.20, 0.09]
    count = len(heights)
    bw = int(n * 0.052)
    gap = int(n * 0.028)
    total = count * bw + (count - 1) * gap
    x0 = (n - total) // 2
    for i, h in enumerate(heights):
        x = x0 + i * (bw + gap)
        top = hy - int(n * h) - int(n * 0.03)
        color = ACCENT if i == 4 else DIM
        d.rounded_rectangle([x, top, x + bw, hy - int(n * 0.03)], radius=bw // 2, fill=color)
        # 水面の映り（薄く短く）
        refl = tuple(int(BG[j] + (color[j] - BG[j]) * 0.22) for j in range(3))
        d.rounded_rectangle([x, hy + int(n * 0.03), x + bw, hy + int(n * 0.03) + int(n * h * 0.35)], radius=bw // 2, fill=refl)
    # 録音の丸（右上の月のような差し色の輪）
    mr = int(n * (0.075 if not watch else 0.07))
    mx, my = int(n * 0.74), int(n * 0.24)
    d.ellipse([mx - mr, my - mr, mx + mr, my + mr], outline=ACCENT, width=int(n * 0.018))
    d.ellipse([mx - mr // 3, my - mr // 3, mx + mr // 3, my + mr // 3], fill=ACCENT)
    return img.resize((S, S), Image.LANCZOS)


def add(a, b):
    from PIL import ImageChops
    return ImageChops.add(a, b)


def main():
    out = [
        os.path.join(ROOT, "LifeLog", "Assets.xcassets", "AppIcon.appiconset", "icon-1024.png"),
        os.path.join(ROOT, "LifeLogWatch", "Assets.xcassets", "AppIcon.appiconset", "icon-1024.png"),
    ]
    draw(False).save(out[0], optimize=True)
    draw(True).save(out[1], optimize=True)
    for p in out:
        print("書いた:", p)


if __name__ == "__main__":
    sys.exit(main())
