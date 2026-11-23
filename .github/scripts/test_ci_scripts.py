"""CI の手伝いの script（whatsnew.py・notice_hints.py）の確かめ（2026-11-23。s23 の 届6・知8）。

    python3 -m unittest discover -s .github/scripts -p "test_*.py"
"""
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import whatsnew  # noqa: E402


def commit(msg: str) -> dict:
    return {"commit": {"message": msg}}


class WhatsNewTests(unittest.TestCase):
    def test_merge_uses_pr_title(self):
        t = whatsnew.titles([commit("Merge pull request #100 from x/y\n\n中断のあと録音を戻す"), commit("見本を直す\n\n本文")])
        self.assertEqual(t, ["中断のあと録音を戻す", "見本を直す"])

    def test_duplicates_and_branch_merges_dropped(self):
        t = whatsnew.titles([commit("A"), commit("A"), commit("Merge branch 'main' into x"), commit("Merge abc123 into def456")])
        self.assertEqual(t, ["A"])

    def test_empty_has_fallback_line(self):
        self.assertIn("読み取れませんでした", whatsnew.build([], "compare"))

    def test_length_limit(self):
        commits = [commit("あ" * 190 + str(i)) for i in range(100)]
        text = whatsnew.build(commits, "compare")
        self.assertLessEqual(len(text), whatsnew.LIMIT)
        self.assertIn("…ほか", text)

    def test_compare_header(self):
        self.assertIn("前の版から", whatsnew.build([commit("A")], "compare"))
        self.assertIn("直近", whatsnew.build([commit("A")], "recent"))


class NoticeHintsTests(unittest.TestCase):
    def test_counts(self):
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, "LifeLog"))
            with open(os.path.join(d, "LifeLog", "A.swift"), "w", encoding="utf-8") as f:
                f.write('content.body = "押すと、取り込む画面を開きます。"\n'
                        'content.body = "今日のまとめです。"\n'
                        'content.body = rows.joined(separator: "\n")\n')
            out = subprocess.run([sys.executable, os.path.join(HERE, "notice_hints.py"), d, os.path.join(d, "o")],
                                 capture_output=True, text=True, encoding="utf-8", check=True,
                                 env={**os.environ, "PYTHONIOENCODING": "utf-8"}).stdout
            self.assertIn("NOTICE_HINTS: total=3 with=1 without=1 indirect_without=1", out)


if __name__ == "__main__":
    unittest.main()
