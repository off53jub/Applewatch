"""s26 の 絵1（2026-11-25）: 部品表の外で、色と字の大きさを「直に」書いた所を数える。報告だけで、落とさない（必須にしない）。

使い方: python3 s26c_design_count.py <リポジトリの根> <書き出す所>

- 数えるのは LifeLog・LifeLogWatch・LifeLogWatchWidgets・LifeLogWidgets・Shared の .swift（試しの LifeLogTests・LifeLogUITests は数えない）
- 数えないファイル（決まりの側）:
  - 名前が S26D で始まるファイル（s26 の A3 が作る部品表）
  - Shared/Design/ の下（前からの色と数の決まり。LLTheme.swift など）
- 数える 4 種類（どれも仮の決め方。文字列とコメントの中は見ない）:
  - color_rgb   … 色を数で書いた所（Color(red:…)・Color(hue:…)・Color(white:…)・UIColor(red:…)・Color(llHex:…)・#colorLiteral など）
  - color_named … 色の名前を直に書いた所（.red・Color.orange・UIColor.systemBlue など。.primary・.secondary・.accentColor は数えない）
  - font_size   … 字の大きさを数で書いた所（.system(size:…)・UIFont.systemFont(ofSize:…)・.custom(…)）
  - font_style  … 字の種類を直に書いた所（.font(.headline) など。文字の大きさの設定には付いていくので、害は小さい）
- 1 行の印「S26C_DESIGN: …」を出す（母艦や次の回が探せる）
"""
import json
import os
import re
import sys

ROOTS = ("LifeLog", "LifeLogWatch", "LifeLogWatchWidgets", "LifeLogWidgets", "Shared")
KINDS = ("color_rgb", "color_named", "font_size", "font_style")
LABEL = {
    "color_rgb": "色を数で（RGB など）",
    "color_named": "色の名前を直に（.red など）",
    "font_size": "字の大きさを数で（size: など）",
    "font_style": "字の種類を直に（.font(.headline) など）",
}
COLOR_NAMES = r"red|orange|yellow|green|mint|teal|cyan|blue|indigo|purple|pink|brown|gray|grey|black|white"
FONT_STYLES = r"largeTitle|extraLargeTitle2|extraLargeTitle|title3|title2|title|headline|subheadline|body|callout|footnote|caption2|caption"

PATTERNS = {
    "color_rgb": re.compile(
        r"\b(?:UI|NS|CG)?Color\s*\(\s*(?:red|hue|white|\.sRGB|\.displayP3|\.sRGBLinear|(?:ll)?[hH]ex|srgbRed|displayP3Red)\b"
        r"|#colorLiteral\s*\(|\bCGColor\s*\(\s*(?:red|gray|srgbRed)\b"),
    "color_named": re.compile(
        r"\b(?:UI|NS)?Color\s*\.\s*(?:" + COLOR_NAMES + r")\b(?!\s*\()"
        r"|\bUIColor\s*\.\s*system(?:Red|Orange|Yellow|Green|Mint|Teal|Cyan|Blue|Indigo|Purple|Pink|Brown|Gray)\b"
        r"|(?<![\w.\])])\.(?:" + COLOR_NAMES + r")\b(?!\s*[(:])"),
    "font_size": re.compile(
        r"\.system\s*\(\s*size\s*:|\bUIFont\s*\.\s*(?:systemFont|boldSystemFont|monospacedSystemFont|monospacedDigitSystemFont)\s*\(\s*ofSize"
        r"|\bUIFont\s*\(\s*name\s*:|(?:\bFont|(?<![\w.]))\.custom\s*\("),
    "font_style": re.compile(
        r"\.font\s*\(\s*(?:Font\s*)?\.(?:" + FONT_STYLES + r")\b"),
}

STRING = re.compile(r'"(?:\\.|[^"\\\n])*"')
BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)


def strip_code(text: str) -> list:
    """文字列とコメントを空白にして、行ごとに返す（行番号は元のまま）"""
    text = BLOCK_COMMENT.sub(lambda m: "\n" * m.group(0).count("\n"), text)
    lines = []
    in_multi = False
    for raw in text.split("\n"):
        line = raw
        if in_multi:
            if '"""' in line:
                line = line.split('"""', 1)[1]
                in_multi = False
            else:
                lines.append("")
                continue
        if '"""' in line:
            head, _, tail = line.partition('"""')
            if '"""' not in tail:
                in_multi = True
                line = head
            else:
                line = head + tail.split('"""', 1)[1]
        line = STRING.sub('""', line)
        i = line.find("//")
        if i >= 0:
            line = line[:i]
        lines.append(line)
    return lines


def count_text(text: str) -> list:
    """(行番号, 種類, その行の元の文字) の一覧"""
    raw_lines = text.split("\n")
    hits = []
    for n, line in enumerate(strip_code(text), start=1):
        if not line.strip():
            continue
        for kind in KINDS:
            for _ in PATTERNS[kind].finditer(line):
                src = raw_lines[n - 1].strip() if n - 1 < len(raw_lines) else ""
                hits.append((n, kind, src[:90]))
    return hits


def is_rule_file(rel: str) -> bool:
    name = os.path.basename(rel)
    return name.startswith("S26D") or rel.replace("\\", "/").startswith("Shared/Design/")


def scan(root: str) -> dict:
    files = 0
    skipped = []
    per_file = {}
    items = []
    for top in ROOTS:
        base = os.path.join(root, top)
        if not os.path.isdir(base):
            continue
        for d, _, names in os.walk(base):
            for f in sorted(names):
                if not f.endswith(".swift"):
                    continue
                path = os.path.join(d, f)
                rel = os.path.relpath(path, root).replace("\\", "/")
                if is_rule_file(rel):
                    skipped.append(rel)
                    continue
                files += 1
                try:
                    with open(path, encoding="utf-8", errors="replace") as fh:
                        text = fh.read()
                except OSError:
                    continue
                for line, kind, src in count_text(text):
                    per_file.setdefault(rel, {k: 0 for k in KINDS})[kind] += 1
                    items.append({"file": rel, "line": line, "kind": kind, "text": src})
    total = {k: sum(v[k] for v in per_file.values()) for k in KINDS}
    return {"files": files, "rule_files": sorted(skipped), "total": total,
            "per_file": per_file, "items": items}


def report(res: dict) -> str:
    t = res["total"]
    out = ["## 部品表の外で、色と字を直に書いた所（s26 の 絵1・報告だけ）", ""]
    out.append(f"- 見た Swift: {res['files']} ファイル（決まりの側として数えないファイル: {len(res['rule_files'])}。"
               "名前が S26D で始まるものと Shared/Design/ の下）")
    s26d = [r for r in res["rule_files"] if os.path.basename(r).startswith("S26D")]
    out.append(f"- 部品表（S26D）のファイル: {len(s26d)}" + ("（まだ無い）" if not s26d else "・" + "・".join(s26d[:8])))
    out.append("")
    out.append("| 種類 | か所 |")
    out.append("|---|---:|")
    for k in KINDS:
        out.append(f"| {LABEL[k]} | {t[k]} |")
    marker = "S26C_DESIGN: " + " ".join(f"{k}={t[k]}" for k in KINDS) + f" files={len(res['per_file'])}"
    out.append("")
    out.append(f"- `{marker}`")
    rows = sorted(res["per_file"].items(), key=lambda kv: (-(kv[1]["color_rgb"] + kv[1]["color_named"] + kv[1]["font_size"]), kv[0]))
    if rows:
        out.append("")
        out.append("<details><summary>多いファイル（色と字の大きさの合計の多い順・先頭 25）</summary>")
        out.append("")
        out.append("| ファイル | 色(数) | 色(名前) | 字(数) | 字(種類) |")
        out.append("|---|---:|---:|---:|---:|")
        for rel, c in rows[:25]:
            out.append(f"| {rel} | {c['color_rgb']} | {c['color_named']} | {c['font_size']} | {c['font_style']} |")
        out.append("")
        out.append("</details>")
    out.append("")
    out.append("注: 落とさない（必須にしない）。数え方は文字の形で見ているだけ（仮）。`.white` のように色でない名前に当たることがある。"
               "字の種類（.headline など）は文字の大きさの設定に付いていくので、減らす順は 色(数)・字(数) が先（仮）。")
    return "\n".join(out)


def main(argv) -> int:
    root = argv[1] if len(argv) > 1 else "."
    out = argv[2] if len(argv) > 2 else "."
    os.makedirs(out, exist_ok=True)
    res = scan(root)
    with open(os.path.join(out, "s26c_design.json"), "w", encoding="utf-8") as fh:
        json.dump(res, fh, ensure_ascii=False, indent=1)
    print(report(res))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
