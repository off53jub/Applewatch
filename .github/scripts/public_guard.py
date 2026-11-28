"""公開リポジトリの見張り（s38 土9・2026-11-28）。

このリポジトリは公開なので、本名・鍵・メール・仕事や会話の中身が混ざらないかを push と PR のたびに確かめる。
- 鍵らしい形（秘密鍵の頭・Anthropic・GitHub・AWS・Google・Slack・Apple の .p8 の中身）
- メールの宛先（example.com・noreply など、見本と決まった宛先は除く）
- 混ぜてはいけない言葉（本名・顧客名など）: 言葉そのものは公開できないので、リポジトリの Secret
  PUBLIC_GUARD_WORDS（1 行に 1 語）から読む。無ければこの段は飛ばす（::notice:: で知らせる）。
  手元では --words-file で同じことができる（ファイルはリポジトリに入れない）
見つけた値は出さない（場所と種類だけ）。前からあって問題の無い行は .github/public-guard-allow.txt に
「パス<TAB>行の sha1 の頭 12 字」で書けば通る。

使い方:
  python .github/scripts/public_guard.py                 # git ls-files の全部
  python .github/scripts/public_guard.py --words-file F  # 手元で言葉も
  python .github/scripts/public_guard.py --selftest
"""
from __future__ import annotations

import argparse
import hashlib
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ALLOW = os.path.join(ROOT, ".github", "public-guard-allow.txt")
MAX_BYTES = 2_000_000
SKIP_EXT = {".png", ".jpg", ".jpeg", ".gif", ".m4a", ".wav", ".mp3", ".mp4", ".mov", ".onnx", ".bin", ".pt",
            ".zip", ".gz", ".ico", ".icns", ".pdf", ".ttf", ".otf", ".woff", ".woff2", ".car", ".a", ".dylib"}

KEYS = [
    ("private-key", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----")),
    ("anthropic-key", re.compile(r"sk-ant-[A-Za-z0-9_\-]{20,}")),
    ("openai-key", re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9]{32,}")),
    ("github-token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{30,}|\bgithub_pat_[A-Za-z0-9_]{40,}")),
    ("aws-key", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("google-key", re.compile(r"\bAIza[0-9A-Za-z_\-]{35}\b")),
    ("slack-token", re.compile(r"\bxox[baprs]-[0-9A-Za-z\-]{10,}")),
    ("line-token", re.compile(r"(?i)channel_?access_?token\s*[=:]\s*['\"][A-Za-z0-9+/=]{100,}")),
]
EMAIL = re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}")
EMAIL_OK = re.compile(r"(?i)@(?:[a-z0-9\-]+\.)*(?:example\.(?:com|org|net|jp)|anthropic\.com|users\.noreply\.github\.com|"
                      r"noreply\.github\.com|localhost|test|invalid|local|apple\.com|github\.com|icloud\.example)$|"
                      r"^(?:noreply|no-reply|git|user|someone|name|you|me|test|sample|mihon)@")


def tracked_files() -> list[str]:
    out = subprocess.run(["git", "ls-files", "-z"], cwd=ROOT, capture_output=True, check=True).stdout
    return [p for p in out.decode("utf-8", "replace").split("\0") if p]


def load_allow() -> set[str]:
    try:
        with open(ALLOW, encoding="utf-8") as f:
            return {ln.strip() for ln in f if ln.strip() and not ln.startswith("#")}
    except OSError:
        return set()


def line_id(path: str, line: str) -> str:
    return f"{path}\t{hashlib.sha1(line.strip().encode('utf-8')).hexdigest()[:12]}"


def normalize(s: str) -> str:
    return re.sub(r"\s+", "", s).lower()


def scan_text(path: str, text: str, words: list[str], allow: set[str]) -> list[tuple[str, int, str]]:
    hits = []
    for no, line in enumerate(text.splitlines(), 1):
        if line_id(path, line) in allow:
            continue
        for kind, rx in KEYS:
            if rx.search(line):
                hits.append((path, no, kind))
        for m in EMAIL.finditer(line):
            addr = m.group(0)
            if not EMAIL_OK.search(addr) and not addr.lower().endswith((".png", ".jpg", ".swift", ".py")):
                hits.append((path, no, "email"))
                break
        if words:
            flat = normalize(line)
            for i, w in enumerate(words):
                if w and w in flat:
                    hits.append((path, no, f"word#{i + 1}"))   # 言葉は出さない（何番目かだけ）
    return hits


def read_words(path: str | None) -> list[str]:
    raw = ""
    if path:
        with open(path, encoding="utf-8") as f:
            raw = f.read()
    else:
        raw = os.environ.get("PUBLIC_GUARD_WORDS", "")
    words = []
    for w in re.split(r"[\n,]", raw):
        w = normalize(w)
        if len(w) >= 2:
            words.append(w)
    return words


def selftest() -> int:
    allow: set[str] = set()
    t = "\n".join([
        "let a = 1",
        "-----BEGIN PRIVATE KEY-----",
        "key = 'sk-ant-api03-" + "x" * 30 + "'",
        "mail: someone@example.com と noreply@anthropic.com",
        "mail: taro.real@gmail" + ".com",
        "見本さん と 見本の案件 A",
        "ここに 秘密 の 名前 がある",
    ])
    hits = scan_text("a.swift", t, [normalize("秘密の名前")], allow)
    kinds = sorted((h[1], h[2]) for h in hits)
    assert kinds == [(2, "private-key"), (3, "anthropic-key"), (5, "email"), (7, "word#1")], kinds
    allow = {line_id("a.swift", "mail: taro.real@gmail" + ".com")}
    assert all(h[2] != "email" for h in scan_text("a.swift", t, [], allow))
    assert read_words.__name__ and normalize(" A b ") == "ab"
    print("selftest PASS")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--words-file")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass
    if a.selftest:
        return selftest()
    words = read_words(a.words_file)
    allow = load_allow()
    hits: list[tuple[str, int, str]] = []
    n = 0
    for path in tracked_files():
        if os.path.splitext(path)[1].lower() in SKIP_EXT or path == ".github/public-guard-allow.txt":
            continue
        full = os.path.join(ROOT, path)
        try:
            if os.path.getsize(full) > MAX_BYTES:
                continue
            with open(full, "rb") as f:
                data = f.read()
        except OSError:
            continue
        if b"\0" in data[:4096]:
            continue
        n += 1
        hits += scan_text(path, data.decode("utf-8", "replace"), words, allow)
    if not words:
        print("::notice::PUBLIC_GUARD_WORDS が無いので、混ぜてはいけない言葉の段は飛ばした（鍵とメールだけ見た）")
    for path, no, kind in hits:
        print(f"::error file={path},line={no}::公開リポジトリに入れてはいけない形（{kind}）")
    print(f"public-guard: files={n} words={len(words)} hits={len(hits)}")
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
