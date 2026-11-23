"""The RX LO plan is per-rung and must never arm the radio on a bad value.

Background: the demod has a dead zone at residual CFO ~= 0 (CFC dither, 0x154 sign flips,
acquisition collapse), so both receivers are deliberately offset from the null. The offsets
moved into ops/rung_table.sh on 2026-09-26 because r4 (2 sps) needs a bigger offset in Hz than
r2/r3 (4 sps) for the same normalised margin -- docs/evidence/sp4/ACQUISITION_COLLAPSE.md.

These tests slice the LO block out of bringup_r2r3.sh and run it alone, so nothing here can
reach a board. Pass env through subprocess.run(env=...), never an inline VAR=x assignment in
front of a sourced file: the assignment does not reach the sourced script and the real rig
paths get used instead (that trap cost a live rig lock once).
"""
import os
import re
import subprocess
import unittest

OPS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRINGUP = os.path.join(OPS, "bringup_r2r3.sh")


def lo_block():
    """The LO assignment + guard region of bringup_r2r3.sh, as standalone shell."""
    src = open(BRINGUP).read()
    m = re.search(r"^# CFO policy.*?^echo \"LO_PLAN .*?$", src, re.S | re.M)
    assert m, "LO plan block not found in bringup_r2r3.sh"
    return m.group(0)


def run_block(pre, env=None):
    script = "set -u\n" + pre + "\n" + lo_block() + "\n"
    e = dict(os.environ)
    for _v in ("LO_A_RX", "LO_B_RX", "LO_A_TX", "LO_B_TX"):
        e.pop(_v, None)
    if env:
        e.update(env)
    return subprocess.run(["bash", "-c", script], capture_output=True, text=True, env=e)


class TestLoPlanPerRung(unittest.TestCase):
    def _for_rung(self, rung, env=None):
        pre = '. "%s/rung_table.sh"; rung_set %s >/dev/null' % (OPS, rung)
        return run_block(pre, env)

    def test_r3_ships_the_1850_reverse_plan(self):
        # 2026-09-29: the reverse carrier moved 1.9 -> 1.85 GHz (a notch at 1.9 GHz; see the
        # rung table header). The RX offset stays +40 kHz and the forward leg is untouched.
        r = self._for_rung("r3")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("LO_PLAN rung=r3 148_rx=2100020000 146_rx=1850040000 148_tx=1850000000 146_tx=2100000000", r.stdout)

    def test_r2_ships_the_same_plan_as_r3(self):
        r = self._for_rung("r2")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("LO_PLAN rung=r2 148_rx=2100020000 146_rx=1850040000 148_tx=1850000000 146_tx=2100000000", r.stdout)

    def test_r4_uses_the_bigger_offsets_and_keeps_its_carrier(self):
        # r4 has not been measured at 1.85 GHz; its plan is unchanged by the r2/r3 move.
        r = self._for_rung("r4")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("LO_PLAN rung=r4 148_rx=2100060000 146_rx=1900080000 148_tx=1900000000 146_tx=2100000000", r.stdout)

    def test_shipped_r3_plan_pairs_each_receiver_with_its_peer_at_plus_40_khz(self):
        r = self._for_rung("r3")
        self.assertEqual(r.returncode, 0, r.stderr)
        m = re.search(r"148_rx=(\d+) 146_rx=(\d+) 148_tx=(\d+) 146_tx=(\d+)", r.stdout)
        a_rx, b_rx, a_tx, b_tx = (int(x) for x in m.groups())
        self.assertEqual(b_rx - a_tx, 40000)   # reverse: 146 RX vs 148 TX
        self.assertEqual(a_rx - b_tx, 20000)   # forward: 148 RX vs 146 TX

    def test_env_override_still_wins(self):
        r = self._for_rung("r4", env={"LO_A_RX": "2100123000"})   # within 1 MHz of the 2.1 GHz r4 forward carrier
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("148_rx=2100123000", r.stdout)


class TestLoPlanRefusesBadValues(unittest.TestCase):
    """A typo in the table must stop the bring-up, not arm the radio somewhere else."""

    def test_empty_default_refuses(self):
        r = run_block('RUNG=rX; LO_A_TX_DEFAULT=1900000000; LO_B_TX_DEFAULT=2000000000; LO_A_RX_DEFAULT=""; LO_B_RX_DEFAULT=1900080000')
        self.assertEqual(r.returncode, 2)
        self.assertIn("BAD LO PLAN", r.stderr)
        self.assertNotIn("LO_PLAN rung", r.stdout)

    def test_non_numeric_refuses(self):
        r = run_block("RUNG=rX; LO_A_TX_DEFAULT=1900000000; LO_B_TX_DEFAULT=2000000000; LO_A_RX_DEFAULT=2000060000; LO_B_RX_DEFAULT=1.9e9")
        self.assertEqual(r.returncode, 2)
        self.assertIn("BAD LO PLAN", r.stderr)

    def test_out_of_band_refuses(self):
        # a dropped digit: 200006000 Hz = 200 MHz, not 2.00006 GHz
        r = run_block("RUNG=rX; LO_A_TX_DEFAULT=1900000000; LO_B_TX_DEFAULT=2000000000; LO_A_RX_DEFAULT=200006000; LO_B_RX_DEFAULT=1900080000")
        self.assertEqual(r.returncode, 2)
        self.assertIn("outside 1.8-2.2 GHz", r.stderr)

    def test_unset_default_refuses_via_set_u(self):
        r = run_block("RUNG=rX; LO_A_TX_DEFAULT=1900000000; LO_B_TX_DEFAULT=2000000000; unset LO_A_RX_DEFAULT LO_B_RX_DEFAULT || true")
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn("LO_PLAN rung", r.stdout)


if __name__ == "__main__":
    unittest.main()


class TestBandSwapPlan(unittest.TestCase):
    """The TX LOs became env-overridable on 2026-09-28 for the band-vs-chain experiment.

    With two boards and no loopback cable, swapping which DIRECTION uses which frequency is the
    only way to ask whether a one-sided defect follows the BAND (antenna, interference, anything
    frequency-selective) or the CHAIN (a given board's transmit or receive hardware). The risk it
    introduces is a HALF-APPLIED swap: set two of the four variables and the bring-up arms two
    radios that cannot hear each other, burning an arm and looking exactly like the defect under
    investigation. The guard must catch that before arming.
    """

    def _r3(self, env=None):
        pre = '. "%s/rung_table.sh"; rung_set r3 >/dev/null' % OPS
        return run_block(pre, env)

    def test_defaults_come_from_the_rung_table(self):
        r = self._r3()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("148_tx=1850000000", r.stdout)
        self.assertIn("146_tx=2100000000", r.stdout)
        self.assertIn("148_rx=2100020000", r.stdout)
        self.assertIn("146_rx=1850040000", r.stdout)

    def test_a_fully_swapped_plan_is_accepted(self):
        """Both legs still have rx within 1 MHz of the peer tx, so the pair can hear itself."""
        r = self._r3({"LO_A_TX": "2000000000", "LO_A_RX": "1900020000",
                      "LO_B_TX": "1900000000", "LO_B_RX": "2000040000"})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("148_tx=2000000000", r.stdout)
        self.assertIn("146_rx=2000040000", r.stdout)

    def test_half_applied_swap_is_refused_before_arming(self):
        """Swap only the transmitters and each receiver is 100 MHz from its peer."""
        r = self._r3({"LO_A_TX": "2000000000", "LO_B_TX": "1900000000"})
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("BAD LO PLAN", r.stderr)
        self.assertIn("half-applied swap", r.stderr)

    def test_swapping_only_the_receivers_is_also_refused(self):
        r = self._r3({"LO_A_RX": "1900020000", "LO_B_RX": "2000040000"})
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("BAD LO PLAN", r.stderr)

    def test_a_tx_lo_outside_the_band_is_refused(self):
        r = self._r3({"LO_A_TX": "900000000"})
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("outside 1.8-2.2 GHz", r.stderr)

    def test_a_non_numeric_tx_lo_is_refused(self):
        r = self._r3({"LO_B_TX": "2e9"})
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("BAD LO PLAN", r.stderr)
