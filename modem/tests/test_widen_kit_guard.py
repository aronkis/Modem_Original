#!/usr/bin/env python3
"""test_widen_kit_guard.py -- modem/fixes/widen_kit_guard.sh adds a kit-name glob to the case guard of an
instantiated txfix_build.sh whatever alternatives the guard already carries (the literal seds the sp2 kit
scripts used broke when the guard gained |jupiter_byte_sp3*_build in sp3 Task 11: SEQBIST_KIT_GUARD_FAILED
on every sp2 rebuild). Runs against the LIVE template so a future guard change is caught here."""
import os, re, shutil, subprocess, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__)); MODEM = os.path.dirname(HERE)
W = os.path.join(MODEM, "fixes", "widen_kit_guard.sh"); TMPL = os.path.join(MODEM, "vivado", "txfix_build.sh.tmpl")


def guard(path):
    for l in open(path):
        if l.startswith("  jupiter_byte_txfix*_build"):
            return l.rstrip("\n")
    return None


class WidenKitGuard(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(); self.f = os.path.join(self.d, "build_txfix.sh"); shutil.copy(TMPL, self.f)

    def run_w(self, glob):
        return subprocess.run(["bash", W, self.f, glob], capture_output=True, text=True).returncode

    def test_seqbist_then_rxfix_on_the_live_template_is_idempotent(self):
        self.assertEqual(self.run_w("jupiter_byte_seqbist*_build"), 0)
        self.assertEqual(self.run_w("jupiter_byte_seqbist*_build"), 0)
        self.assertEqual(self.run_w("jupiter_byte_rxfix*_build"), 0)
        g = guard(self.f)
        self.assertRegex(g, r"^  jupiter_byte_txfix\*_build(\|[a-z0-9_*]+)+\) ;;$")
        self.assertEqual(g.count("jupiter_byte_seqbist*_build"), 1); self.assertIn("jupiter_byte_rxfix*_build", g)
        self.assertIn("jupiter_byte_sp3*_build", g)          # what was there before stays
        self.assertEqual(subprocess.run(["bash", "-n", self.f]).returncode, 0)

    def test_kit_scripts_use_it(self):
        for rel in ("instruments/seqbist/apply_seqbist.sh", "fixes/rxfix_kit.sh"):
            self.assertIn("widen_kit_guard.sh", open(os.path.join(MODEM, rel)).read(), rel)

    def test_missing_file_or_glob_is_an_error(self):
        self.assertEqual(subprocess.run(["bash", W, "/nonexistent", "x*"], capture_output=True).returncode, 2)


if __name__ == "__main__":
    unittest.main()
