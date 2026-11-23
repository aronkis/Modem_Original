#!/usr/bin/env python3
"""test_tx_ssi_row.py -- ops/tx_ssi_row.sh picks the tx0 SSI delay row per board AND per image
from ops/profiles/tx_ssi.conf, and is never fatal (docs/evidence/sp3/SP3_GATE3_RETEST.md).
No board contact: W is a fake anyssh that answers md5sum with a scripted image, or fails."""
import os, subprocess, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__)); OPS = os.path.dirname(HERE)
SCRIPT = os.path.join(OPS, "tx_ssi_row.sh")

CONF = """# comment
10.0.0.148  default       5  3
10.0.0.148  c5ec53bc610c  4  3
10.0.0.146  default       3  4
"""


def run(args, env):
    return subprocess.run(["bash", SCRIPT, *args], text=True, capture_output=True,
                          env={**os.environ, **env}).stdout.strip()


class TxSsiRow(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(); self.conf = os.path.join(self.d, "tx_ssi.conf")
        open(self.conf, "w").write(CONF)
        self.fake = os.path.join(self.d, "anyssh.sh")
        open(self.fake, "w").write("#!/bin/bash\necho 'c5ec53bc610c5eff837a62b439466660  /boot/BOOT.BIN'\n")
        os.chmod(self.fake, 0o755)
        self.env = {"TX_SSI_CONF": self.conf, "W": self.fake}

    def test_image_row_beats_default(self):
        self.assertEqual(run(["10.0.0.148", "5 3"], self.env), "4 3")           # md5 read from the (fake) board
        self.assertEqual(run(["10.0.0.148", "5 3", "c5ec53bc610c"], self.env), "4 3")

    def test_unlisted_image_uses_the_board_default(self):
        self.assertEqual(run(["10.0.0.148", "9 9", "3e7f4232a3b5"], self.env), "5 3")
        self.assertEqual(run(["10.0.0.146", "9 9", "c5ec53bc610c"], self.env), "3 4")

    def test_unknown_board_missing_conf_or_ssh_failure_fall_back(self):
        self.assertEqual(run(["10.0.0.9", "1 1", "x"], self.env), "1 1")
        self.assertEqual(run(["10.0.0.148", "7 7"], {**self.env, "TX_SSI_CONF": "/nonexistent"}), "7 7")
        self.assertEqual(run(["10.0.0.148", "5 3"], {**self.env, "W": "/bin/false"}), "5 3")  # ssh fails -> default row for the board

    def test_shipped_conf_parses_with_the_historical_defaults(self):
        env = {"W": "/bin/false"}
        self.assertEqual(run(["10.0.0.148", "0 0", "3e7f4232a3b5"], env), "5 3")
        self.assertEqual(run(["10.0.0.146", "0 0", "d94b4df391a1"], env), "3 4")
        self.assertEqual(run(["10.0.0.148", "0 0", "c5ec53bc610c"], env), "4 3")   # the sp3 row of SP3_GATE3_RETEST.md


if __name__ == "__main__":
    unittest.main()
