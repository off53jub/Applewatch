"""TestFlight の「テストする内容」（What to Test）に入れる文を作る（2026-11-23。s23 の 届6）。

    python whatsnew.py <GitHub API の JSON> <書き出す文> <compare|recent>

JSON は、`gh api repos/R/compare/前...今` の答え（commits の列を持つ）か、`gh api repos/R/commits?sha=今` の答え（列そのもの）。
各コミットの題を「・題」の一覧にする。マージのコミット（Merge pull request ...）は、本文の 1 行目（PR の題）を使う。
長さは Apple の上限（4000 文字）より少し短い 3800 文字まで。超えたら最後に「…ほか N 件」を付ける。
秘密は出さない（コミットの題と本文の 1 行目だけ。リポジトリは公開）。
"""
import json
import sys

LIMIT = 3800
MAX_LINES = 30
MAX_TITLE = 200


def titles(commits: list) -> list[str]:
    """コミットの一覧（新しい順でも古い順でもよい）から、重ならない題の一覧を作る"""
    out: list[str] = []
    seen: set[str] = set()
    for c in commits:
        msg = ((c.get("commit") or {}).get("message") or c.get("message") or "").strip()
        if not msg:
            continue
        lines = [l.strip() for l in msg.splitlines()]
        first = lines[0] if lines else ""
        if first.startswith("Merge pull request"):
            rest = [l for l in lines[1:] if l]
            first = rest[0] if rest else ""
        elif first.startswith("Merge "):  # Merge branch ... と、PR の実行で GitHub が作る「Merge <sha> into <sha>」
            first = ""
        if not first or first in seen:
            continue
        seen.add(first)
        out.append(first[:MAX_TITLE])
    return out


def build(commits: list, mode: str) -> str:
    ts = titles(commits)
    head = "この版で変わったこと（" + ("前の版からのコミットの題" if mode == "compare" else "直近のコミットの題") + "）"
    if not ts:
        return head + "\n（変わった点を読み取れませんでした）"
    shown = ts[:MAX_LINES]
    text = head + "\n" + "\n".join("・" + t for t in shown)
    more = len(ts) - len(shown)
    tail = f"\n…ほか {more} 件" if more > 0 else ""
    if len(text) + len(tail) > LIMIT:
        # 上限を超えるときは、行ごとに削って「…ほか N 件」に回す
        kept = list(shown)
        while kept and len("\n".join([head] + ["・" + t for t in kept])) + len(f"\n…ほか {len(ts) - len(kept)} 件") > LIMIT:
            kept.pop()
        text = head + "\n" + "\n".join("・" + t for t in kept)
        tail = f"\n…ほか {len(ts) - len(kept)} 件"
    return text + tail


def main() -> None:
    src, dst, mode = sys.argv[1], sys.argv[2], (sys.argv[3] if len(sys.argv) > 3 else "recent")
    try:
        data = json.load(open(src, encoding="utf-8"))
    except (OSError, ValueError):
        data = []
    commits = data.get("commits", []) if isinstance(data, dict) else data
    text = build(commits, mode)
    with open(dst, "w", encoding="utf-8") as f:
        f.write(text)
    print(text)


if __name__ == "__main__":
    main()
