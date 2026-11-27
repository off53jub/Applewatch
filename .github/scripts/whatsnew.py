"""TestFlight の「テストする内容」（What to Test）に入れる文を作る（2026-11-23。s23 の 届6）。

    python whatsnew.py <GitHub API の JSON> <書き出す文> <compare|recent> [PR の一覧の JSON]

JSON は、`gh api repos/R/compare/前...今` の答え（commits の列を持つ）か、`gh api repos/R/commits?sha=今` の答え（列そのもの）。
各コミットの題を「・題」の一覧にする。マージのコミット（Merge pull request ...）は、本文の 1 行目（PR の題）を使う。
長さは Apple の上限（4000 文字）より少し短い 3800 文字まで。超えたら最後に「…ほか N 件」を付ける。
秘密は出さない（コミットの題と本文の 1 行目だけ。リポジトリは公開）。

（2026-11-27。s33 の 強7）4 つ目に `gh pr list --json number,title,mergedAt` の答え（前の版のあとに main に入った PR）があれば、
頭に「この版で見る 3 つ」を付ける。PR の題から 3 つまで（新しく入った順。CI・文書・家の PC だけらしい題は後回し）。
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


PICKS = 3
# CI・文書・家の PC だけらしい題（実機で見るものが少ない）は後回しにする（仮）
LATER = ("ci", "ci:", "docs", "docs:", "pc:", "pc ", "家の pc", "文書")


def picks(prs: list, limit: int = PICKS) -> list[str]:
    """PR の一覧から「この版で見る」題を limit 個まで（新しく入った順・同じ題は 1 つ・後回しの題は足りないときだけ）"""
    rows = [p for p in prs if isinstance(p, dict) and str(p.get("title") or "").strip()]
    rows.sort(key=lambda p: str(p.get("mergedAt") or ""), reverse=True)
    first: list[str] = []
    later: list[str] = []
    seen: set[str] = set()
    for p in rows:
        t = str(p["title"]).strip()[:MAX_TITLE]
        if t in seen:
            continue
        seen.add(t)
        (later if t.lower().startswith(LATER) else first).append(t)
    return (first + later)[:limit]


def picks_block(prs: list) -> str:
    ps = picks(prs)
    if not ps:
        return ""
    return "この版で見る 3 つ\n" + "\n".join(f"{i + 1}. {t}" for i, t in enumerate(ps))


def build(commits: list, mode: str, prs=None) -> str:
    head_block = picks_block(prs or [])
    if head_block:
        rest = build(commits, mode)
        text = head_block + "\n\n" + rest
        return text if len(text) <= LIMIT else text[:LIMIT]
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
    prs: list = []
    if len(sys.argv) > 4:
        try:
            loaded = json.load(open(sys.argv[4], encoding="utf-8"))
            prs = loaded if isinstance(loaded, list) else []
        except (OSError, ValueError):
            prs = []
    text = build(commits, mode, prs)
    with open(dst, "w", encoding="utf-8") as f:
        f.write(text)
    print(text)


if __name__ == "__main__":
    main()
