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

    # s33 の 強7（2026-11-27）: 頭に「この版で見る 3 つ」（その日 main に入った PR の題から 3 つまで）
    def test_picks_newest_three_and_ci_later(self):
        prs = [
            {"number": 1, "title": "CI: 夜に 1 回", "mergedAt": "2026-11-27T13:00:00Z"},
            {"number": 2, "title": "見本の画面を足す", "mergedAt": "2026-11-27T10:00:00Z"},
            {"number": 3, "title": "見本の直し", "mergedAt": "2026-11-27T12:00:00Z"},
            {"number": 4, "title": "見本の直し", "mergedAt": "2026-11-27T11:00:00Z"},
            {"number": 5, "title": "", "mergedAt": "2026-11-27T14:00:00Z"},
            "壊れた行",
        ]
        self.assertEqual(whatsnew.picks(prs), ["見本の直し", "見本の画面を足す", "CI: 夜に 1 回"])

    def test_picks_block_at_head(self):
        text = whatsnew.build([commit("A")], "compare", [{"title": "見本の画面", "mergedAt": "2026-11-27T10:00:00Z"}])
        self.assertTrue(text.startswith("この版で見る 3 つ\n1. 見本の画面"))
        self.assertIn("前の版から", text)
        self.assertLessEqual(len(text), whatsnew.LIMIT)
        # PR が無ければ前のまま
        self.assertEqual(whatsnew.build([commit("A")], "compare", []), whatsnew.build([commit("A")], "compare"))


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


class ScreensDiffTests(unittest.TestCase):
    def run_diff(self, cur, prev):
        out = os.path.join(os.path.dirname(cur), "o")
        r = subprocess.run([sys.executable, os.path.join(HERE, "screens_diff.py"), cur, prev, out],
                           capture_output=True, text=True, encoding="utf-8",
                           env={**os.environ, "PYTHONIOENCODING": "utf-8"})
        return r, out

    def test_no_previous_is_green(self):
        with tempfile.TemporaryDirectory() as d:
            cur = os.path.join(d, "cur")
            os.makedirs(cur)
            r, _ = self.run_diff(cur, os.path.join(d, "nothing"))
            self.assertEqual(r.returncode, 0)

    def test_changed_screen_is_listed(self):
        try:
            from PIL import Image
        except ImportError:
            self.skipTest("Pillow が無い")
        with tempfile.TemporaryDirectory() as d:
            cur, prev = os.path.join(d, "cur"), os.path.join(d, "prev")
            os.makedirs(cur)
            os.makedirs(prev)
            Image.new("RGB", (100, 200), "white").save(os.path.join(prev, "001 今日.png"))
            Image.new("RGB", (100, 200), "white").save(os.path.join(prev, "002 同じ.png"))
            Image.new("RGB", (100, 200), "black").save(os.path.join(cur, "001 今日.png"))
            Image.new("RGB", (100, 200), "white").save(os.path.join(cur, "002 同じ.png"))
            r, out = self.run_diff(cur, prev)
            self.assertEqual(r.returncode, 0)
            self.assertIn("変わった 1 枚", r.stdout)
            self.assertIn("変わった: 001 今日", r.stdout)
            self.assertNotIn("変わった: 002", r.stdout)
            self.assertTrue(os.path.exists(os.path.join(out, "diff-sheet-01.jpg")))


if __name__ == "__main__":
    unittest.main()
