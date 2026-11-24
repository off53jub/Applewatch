"""s26c_design_count.py（s26 の 絵1 の数え）の確かめ。

    python3 -m unittest discover -s .github/scripts -p "test_*.py"
"""
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import s26c_design_count as dc  # noqa: E402


def kinds(text):
    return [k for _, k, _ in dc.count_text(text)]


class DesignCountTests(unittest.TestCase):
    def test_rgb_and_hex(self):
        self.assertEqual(kinds('let c = Color(red: 0.1, green: 0.2, blue: 0.3)'), ["color_rgb"])
        self.assertEqual(kinds('.fill(Color(llHex: 0x1C5A9A))'), ["color_rgb"])
        self.assertEqual(kinds('let u = UIColor(white: 0.5, alpha: 1)'), ["color_rgb"])

    def test_named_colors(self):
        self.assertEqual(kinds('.foregroundStyle(.orange)'), ["color_named"])
        self.assertEqual(kinds('.background(Color.black.opacity(0.2))'), ["color_named"])
        self.assertEqual(kinds('x.foregroundColor = .red'), ["color_named"])

    def test_semantic_and_tokens_not_counted(self):
        self.assertEqual(kinds('.foregroundStyle(.secondary)'), [])
        self.assertEqual(kinds('.foregroundStyle(LL.accent)'), [])
        self.assertEqual(kinds('.tint(Color.accentColor)'), [])

    def test_fonts(self):
        self.assertEqual(kinds('.font(.system(size: 34, weight: .bold))'), ["font_size"])
        self.assertEqual(kinds('.font(.headline)'), ["font_style"])
        self.assertEqual(kinds('.font(Font.custom("A", size: 12))'), ["font_size"])
        self.assertEqual(kinds('let f = UIFont.systemFont(ofSize: 13)'), ["font_size"])

    def test_strings_and_comments_ignored(self):
        self.assertEqual(kinds('Text(".red は赤") // .font(.headline)'), [])
        self.assertEqual(kinds('/* Color(red: 1, green: 0, blue: 0) */ let a = 1'), [])
        self.assertEqual(kinds('let s = """\n.font(.system(size: 9))\n"""\n.font(.title)'), ["font_style"])

    def test_rule_files_skipped(self):
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, "LifeLog"))
            os.makedirs(os.path.join(root, "Shared", "Design"))
            for rel, body in ((("LifeLog", "S26DParts.swift"), ".foregroundStyle(.red)\n"),
                              (("Shared", "Design", "LLTheme.swift"), "Color(red: 1, green: 0, blue: 0)\n"),
                              (("LifeLog", "A.swift"), ".font(.system(size: 9))\n.foregroundStyle(.red)\n")):
                with open(os.path.join(root, *rel), "w", encoding="utf-8") as fh:
                    fh.write(body)
            res = dc.scan(root)
            self.assertEqual(res["files"], 1)
            self.assertEqual(res["total"]["font_size"], 1)
            self.assertEqual(res["total"]["color_named"], 1)
            self.assertEqual(res["total"]["color_rgb"], 0)
            self.assertIn("S26C_DESIGN: color_rgb=0 color_named=1 font_size=1 font_style=0 files=1", dc.report(res))


if __name__ == "__main__":
    unittest.main()
