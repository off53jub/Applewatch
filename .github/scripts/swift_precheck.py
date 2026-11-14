"""組み立ての前の Swift の検査（強化案 45。2026-11-15）。macOS の組み立てを待たずに、すぐ落とす。

    python3 .github/scripts/swift_precheck.py [フォルダ…]   （既定はリポジトリの Swift の全部）

見るもの（どちらも、11/13 に CI の組み立てで実際に止まった形）:
1. 1 行の文字列（"…"・#"…"#）の中に、生の改行がある（引用符 3 つの複数行の文字列は別。\\n と書けばよい）
2. DemoData.swift の、式が 1 つだけで長いクロージャ（型を書いていないもの）。型推論が時間切れになる。
   明示的なループにするか、型を書く（-> 型 in）。長さの目安は CLOSURE_CHARS 文字・CLOSURE_LINES 行。
見つかれば「ファイル:行: わけ」を出して 1 で終わる（GitHub Actions では ::error の印も付ける）。
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

CLOSURE_CHARS = 180
CLOSURE_LINES = 3
DEMO_NAMES = ("DemoData.swift",)
SKIP_DIRS = {".git", "build", "DerivedData", "Vendor", ".build", "Pods"}
STATEMENT = re.compile(r"^(let|var|for|if|guard|return|switch|while|repeat|do|defer|throw|func)\b")
CONTINUES = (",", "(", "[", "{", "+", "-", "*", "/", "?", ":", "&&", "||", "=", ".", "??", "->")
LEADING = (".", "?", ":", "+", "-", "*", "/", "&&", "||", ")", "]", "}", "??")


def lex(text: str) -> tuple[str, list[tuple[int, str]]]:
    """文字列とコメントを空白に替えた文（改行と長さは同じ）と、見つけた問題 [(行, わけ)] を返す"""
    out = list(text)
    problems: list[tuple[int, str]] = []
    i, n, line = 0, len(text), 1
    # 文字列の中の \( … ) を追うための積み重ね: ("code", 括弧の深さ) か ("str", 終わりの印, 複数行か, # の数, 始めた行)
    stack: list[tuple] = [("code", 0)]

    def blank(a: int, b: int) -> None:
        for k in range(a, b):
            if out[k] != "\n":
                out[k] = " "

    while i < n:
        top = stack[-1]
        ch = text[i]
        if top[0] == "code":
            if text.startswith("//", i):
                j = text.find("\n", i)
                j = n if j < 0 else j
                blank(i, j)
                i = j
                continue
            if text.startswith("/*", i):
                depth, j = 1, i + 2
                while j < n and depth:
                    if text.startswith("/*", j):
                        depth, j = depth + 1, j + 2
                    elif text.startswith("*/", j):
                        depth, j = depth - 1, j + 2
                    else:
                        if text[j] == "\n":
                            line += 1
                        j += 1
                blank(i, j)
                i = j
                continue
            m = re.match(r'(#*)("""|")', text[i:i + 12]) if ch in '"#' else None
            if m:
                hashes = len(m.group(1))
                quote = m.group(2)
                multi = quote == '"""'
                start = i
                i += hashes + len(quote)
                stack.append(("str", quote + "#" * hashes, multi, hashes, line, start))
                continue
            if ch == "(":
                stack[-1] = ("code", top[1] + 1)
            elif ch == ")":
                if top[1] == 0 and len(stack) > 1:
                    stack.pop()  # 文字列の中の \( … ) が終わった。文字列に戻る（この ) から先を、文字列として消す）
                    stack[-1] = stack[-1][:5] + (i,)
                    i += 1
                    continue
                stack[-1] = ("code", top[1] - 1)
            elif ch == "\n":
                line += 1
            i += 1
            continue
        # 文字列の中
        _, end, multi, hashes, began, start = top
        if text.startswith(end, i):
            blank(start, i + len(end))
            stack.pop()
            i += len(end)
            continue
        escape = "\\" + "#" * hashes
        if text.startswith(escape, i):
            k = i + len(escape)
            if k < n and text[k] == "(":
                blank(start, k + 1)
                stack.append(("code", 0))
                i = k + 1
                continue
            if k < n and text[k] == "\n":
                line += 1
            i = k + 1
            continue
        if ch == "\n":
            if not multi:
                # 1 回だけ知らせ、書いた人のつもりどおり次の " までを文字列として読み続ける（あとの行で知らせが続かないように）
                problems.append((began, "1 行の文字列の中に生の改行があります（\\n と書くか、\"\"\" の複数行の文字列にする）"))
                stack[-1] = ("str", end, True, hashes, began, start)
            line += 1
        i += 1
    if len(stack) > 1 and stack[-1][0] == "str":
        problems.append((stack[-1][4], "文字列が閉じていません"))
    return "".join(out), problems


def _line_of(text: str, pos: int) -> int:
    return text.count("\n", 0, pos) + 1


def _match(code: str, pos: int) -> int:
    """code[pos] の { に対応する } の位置（無ければ -1）"""
    depth = 0
    for k in range(pos, len(code)):
        c = code[k]
        if c in "{([":
            depth += 1
        elif c in "})]":
            depth -= 1
            if depth == 0:
                return k
    return -1


def count_statements(body: str) -> int:
    """括弧の外（深さ 0）で始まる行のうち、前の行の続きでないものを、文として数える"""
    depth, statements, prev = 0, 0, ""
    for raw in body.split("\n"):
        s = raw.strip()
        if not s:
            continue
        if depth == 0:
            continued = prev.endswith(CONTINUES) or s.startswith(LEADING)
            if statements == 0 or not continued:
                statements += 1
        for c in s:
            if c in "{([":
                depth += 1
            elif c in "})]":
                depth -= 1
        prev = s
    return statements


def long_closures(code: str, text: str | None = None) -> list[tuple[int, str]]:
    """式が 1 つだけで長い、型を書いていないクロージャ。code は lex の答え（文字列とコメントを消したもの）、
    text はもとの文（長さは文字列も入れて数える。無ければ code で数える）"""
    text = code if text is None else text
    found: list[tuple[int, str]] = []
    for m in re.finditer(r"\{", code):
        start = m.start()
        before = code[max(0, start - 60):start].rstrip()
        head = re.match(r"\{\s*((?:\(?[\w\s,]*\)?)\s+in)\b", code[start:start + 120])
        member_call = re.search(r"\.[A-Za-z_]\w*\s*(\([^()]*\))?$", before) is not None
        assigned = before.endswith(("=", "(", ",", ":", "return"))
        if not (head or member_call or assigned):
            continue
        end = _match(code, start)
        if end < 0:
            continue
        offset = start + 1
        body = code[offset:end]
        if head:
            header = head.group(1)
            if "->" in header:
                continue
            if " in" in body[:len(header) + 4]:
                offset += body.find(" in") + 3
                body = code[offset:end]
        if re.search(r"->[^{}]*\bin\b", code[start:start + 160].split("\n")[0]):
            continue  # 型を書いてある
        stripped = body.strip()
        if not stripped:
            continue
        if ";" in stripped or any(STATEMENT.match(l.strip()) for l in stripped.splitlines() if l.strip()):
            continue  # 文が 2 つ以上（let・for などがある）
        if count_statements(stripped) > 1:
            continue
        original = text[offset:end].strip()
        lines = original.count("\n") + 1
        chars = len(re.sub(r"\s+", " ", original))
        if chars > CLOSURE_CHARS or lines > CLOSURE_LINES:
            found.append((_line_of(code, start), f"式が 1 つだけの長いクロージャ（{chars} 文字・{lines} 行）。"
                                                 "型推論が時間切れになるので、明示的なループにするか型を書く"))
    return found


def check_file(path: Path) -> list[tuple[int, str]]:
    text = path.read_text(encoding="utf-8-sig", errors="replace").replace("\r\n", "\n")
    code, problems = lex(text)
    if path.name in DEMO_NAMES:
        problems += long_closures(code, text)
    return sorted(problems)


def swift_files(roots: list[Path]) -> list[Path]:
    files: list[Path] = []
    for root in roots:
        if root.is_file():
            files.append(root)
            continue
        for folder, dirs, names in os.walk(root):
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.endswith((".xcodeproj", ".xcassets"))]
            files += [Path(folder) / name for name in names if name.endswith(".swift")]
    return sorted(files)


def main(argv: list[str]) -> int:
    repo = Path(__file__).resolve().parents[2]
    roots = [Path(a) for a in argv] or [repo]
    files = swift_files(roots)
    bad = 0
    actions = os.environ.get("GITHUB_ACTIONS") == "true"
    for path in files:
        for line, why in check_file(path):
            bad += 1
            shown = path.relative_to(repo) if path.is_relative_to(repo) else path
            print(f"{shown}:{line}: {why}")
            if actions:
                print(f"::error file={shown},line={line}::{why}")
    print(f"Swift の組み立ての前の検査: {len(files)} ファイル・見つかったもの {bad}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
