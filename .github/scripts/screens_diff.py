"""画面の写真を、前の main の写真と比べて、変わった画面だけを 1 枚（diff-sheet.jpg）に並べる（2026-11-24。s24 形4）。

使い方: python screens_diff.py <今の写真の所> <前の写真の所（無くてもよい）> <書き出す所>
比べ方: 同じ名前の PNG を同じ大きさにそろえ、画素が目に見えて違う割合を出す。
しきい値 THRESHOLD は仮（初めは 1.0%）。時計やバッテリーなど細かい違いで変わった扱いにならないよう、画素ごとの差にも下限（PIXEL_TOL）を置く。
前の写真が無い・Pillow が無いときは「比べる相手なし」と出して、緑のまま（exit 0）で終わる。
"""
import os
import sys

THRESHOLD = 1.0   # 仮: 変わった画素の割合（%）がこれ以上なら「変わった画面」
PIXEL_TOL = 24    # 仮: 1 画素の 3 色の差の合計がこれを超えたら「違う画素」
TILE_W = 300


def shot_names(d):
    if not d or not os.path.isdir(d):
        return {}
    out = {}
    for root, _, files in os.walk(d):
        for f in files:
            if f.lower().endswith(".png"):
                out.setdefault(f, os.path.join(root, f))
    return out


def diff_ratio(a, b):
    """a, b は PIL.Image。違う画素の割合（%）を返す。大きさが違えば b を a にそろえる。"""
    from PIL import ImageChops
    a = a.convert("RGB")
    b = b.convert("RGB")
    if a.size != b.size:
        b = b.resize(a.size)
    d = ImageChops.difference(a, b).convert("L")  # ざっくり: 明るさの差（色の差の平均に近い）
    px = d.getdata()
    limit = max(1, PIXEL_TOL // 3)
    n = sum(1 for v in px if v > limit)
    return 100.0 * n / max(1, len(px))


def main(cur_dir, prev_dir, out):
    os.makedirs(out, exist_ok=True)
    summary = os.path.join(out, "diff.md")
    try:
        from PIL import Image, ImageDraw, ImageFont
    except ImportError:
        msg = "画面の差: Pillow が無いので比べない（緑のまま）"
        print(msg)
        open(summary, "w", encoding="utf-8").write(msg + "\n")
        return 0
    cur, prev = shot_names(cur_dir), shot_names(prev_dir)
    if not cur:
        msg = "画面の差: 今回の写真が無いので比べない（緑のまま）"
    elif not prev:
        msg = "画面の差: 比べる相手なし（前の main の写真が取れなかった）。緑のまま"
    else:
        msg = None
    if msg:
        print(msg)
        open(summary, "w", encoding="utf-8").write(msg + "\n")
        return 0

    changed, added = [], []
    for name in sorted(cur):
        if name not in prev:
            added.append(name)
            continue
        r = diff_ratio(Image.open(cur[name]), Image.open(prev[name]))
        if r >= THRESHOLD:
            changed.append((name, r))
    removed = sorted(n for n in prev if n not in cur)
    lines = [f"画面の差（しきい値 {THRESHOLD}% は仮）: 比べた {len(cur) - len(added)} 枚・変わった {len(changed)} 枚・増えた {len(added)} 枚・無くなった {len(removed)} 枚"]
    lines += [f"- 変わった: {n[:-4]} ({r:.1f}%)" for n, r in changed]
    lines += [f"- 増えた: {n[:-4]}" for n in added]
    lines += [f"- 無くなった: {n[:-4]}" for n in removed]
    text = "\n".join(lines)
    print(text)
    open(summary, "w", encoding="utf-8").write(text + "\n")

    if not changed:
        return 0
    font = None
    for p in ["/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc", "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
              "/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc"]:
        if os.path.exists(p):
            font = ImageFont.truetype(p, 20)
            break
    font = font or ImageFont.load_default()
    rows = []
    for name, r in changed:
        pair = []
        for path in (prev[name], cur[name]):
            im = Image.open(path).convert("RGB")
            pair.append(im.resize((TILE_W, max(1, int(im.height * TILE_W / im.width)))))
        rows.append((f"{name[:-4][:24]} ({r:.1f}%)", pair))
    # 1 枚が長くなりすぎないよう、8 行ごとに分ける（左が前・右が今）
    per = 8
    for k in range(0, len(rows), per):
        grp = rows[k:k + per]
        h = max(max(p.height for p in pair) for _, pair in grp) + 40
        sheet = Image.new("RGB", (2 * (TILE_W + 20) + 20, len(grp) * h + 20), "white")
        dr = ImageDraw.Draw(sheet)
        for i, (label, pair) in enumerate(grp):
            y = 20 + i * h
            dr.text((20, y), label + "　左: 前の main / 右: 今", fill="black", font=font)
            for j, im in enumerate(pair):
                sheet.paste(im, (20 + j * (TILE_W + 20), y + 30))
        sheet.save(os.path.join(out, f"diff-sheet-{k // per + 1:02d}.jpg"), quality=70)
    print("差の一覧の画像を作った")
    return 0


if __name__ == "__main__":
    a = sys.argv
    try:
        sys.exit(main(a[1], a[2] if len(a) > 2 else "", a[3] if len(a) > 3 else "diff-out"))
    except Exception as e:  # 報告だけ。落とさない
        print(f"画面の差: 失敗した（報告だけ・落とさない）: {e}")
        sys.exit(0)
