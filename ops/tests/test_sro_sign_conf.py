#!/usr/bin/env python3
"""test_sro_sign_conf.py -- Task 12 (cleanup sub-project 3, model back-port):
ops/sro_sign.sh writes fixctl (0x208) bit 5, sro_sign, per board from
ops/profiles/sro_sign.conf, through the new fixctl.word shadow convention,
and cross-checks the choice against the measured CFC sign.

NO BOARD CONTACT. `W` is pointed at a fake anyssh.sh + fake-board script (the
ops/tests/test_capture_r3_recovery.py pattern) that serves /dev/shm/fixctl.word
out of a temp directory and answers 0x25C / 0x154 reads from small scripted
state files.

What is pinned:
  * ops/profiles/sro_sign.conf parses to {"10.0.0.148": 0, "10.0.0.146": 1};
  * a write that lands (fake answers 0x25C with the bit set) prints
    "wrote=1 ... edge=FULL" and exits 0;
  * a write that does NOT land (fake answers 0x25C with the bit clear) exits 1;
  * --force <v> writes the given value regardless of the conf and prints
    SRO_SIGN_FORCED;
  * the shadow convention: fixctl_write's word lands verbatim in
    /dev/shm/fixctl.word on the board, and a later write preserves whatever
    other bits that shadow carried;
  * --check derives implies=0/1 from the sign of the scripted CFC mean and
    prints AGREE or DISAGREE against the conf, without writing anything, in
    the contract shape "residual=<n> units=reg cfc_mean=<n> lo_offset_hz=<n>
    implies=<0|1> conf=<0|1> AGREE|DISAGREE";
  * a 0x208 register write that FAILS (the fake board's echo would have
    failed) leaves the shadow UNCHANGED and the script exits non-zero --
    fix round 1 (a false shadow after a failed write would corrupt the next
    read-modify-write's "other bits").
"""
import os
import re
import stat
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
OPS = os.path.dirname(HERE)
SCRIPT = os.path.join(OPS, "sro_sign.sh")
CONF = os.path.join(OPS, "profiles", "sro_sign.conf")

A = "10.0.0.148"
B = "10.0.0.146"


def parse_conf(path):
    """Independent, minimal re-implementation of the conf grammar (comments
    with '#', blank lines, "<ip> <0|1>" rows) -- deliberately NOT sharing code
    with sro_sign.sh's awk parser, so this test does not just check that the
    script agrees with itself."""
    out = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            ip, val = line.split()
            out[ip] = int(val)
    return out


# The fake board: $1 is the ip, $2 the remote command string (anyssh.sh's own
# calling convention). Keeps a fixctl.word file and answers 0x25C / 0x154
# reads from small scripted state files under $FAKE_STATE.
FAKE_BOARD = r"""#!/bin/bash
ip=$1; shift
cmd="$*"
D=$FAKE_STATE
SHADOW=$D/fixctl.word
case "$cmd" in
  *"cat /dev/shm/fixctl.word"*)
      cat "$SHADOW" 2>/dev/null
      exit 0 ;;
  *"0x208 "*"/dev/shm/fixctl.word"*)
      # one fixctl_write call carries both the register write (guarded by an
      # "if echo ... > $DRA; then ... else FIXCTL_WRITE_FAILED; exit 1; fi")
      # and, only on success, the shadow update. FAKE_WRITE_FAILS simulates
      # the register write itself failing: no last_write record, no shadow
      # update, FIXCTL_WRITE_FAILED on stdout, nonzero exit -- exactly what
      # the real remote script's else-branch would do.
      if [ "${FAKE_WRITE_FAILS:-0}" = 1 ]; then
        echo FIXCTL_WRITE_FAILED
        exit 1
      fi
      word=$(printf '%s\n' "$cmd" | grep -oE "0x208 0x[0-9A-Fa-f]+" | tail -1 | cut -d' ' -f2)
      echo "$word" > "$D/last_write_$ip"
      shword=$(printf '%s\n' "$cmd" | grep -oE "printf '%s\\\\n' '0x[0-9A-Fa-f]+'" | tail -1 | grep -oE "0x[0-9A-Fa-f]+")
      echo "$shword" > "$SHADOW"
      exit 0 ;;
  *"echo 0x25C"*)
      cat "$D/mode_$ip" 2>/dev/null || echo 0
      exit 0 ;;
  *"echo 0x154"*)
      # FAKE_CFC_FAILS=1: the DRA read produces NOTHING and exits nonzero --
      # what read_cfc() sees when ssh or the register read fails. FAKE_CFC_
      # FAILS=n (n>1) fails only the first n-1 reads, so a PARTIAL failure
      # (some reads land) can be exercised too.
      if [ "${FAKE_CFC_FAILS:-0}" != 0 ]; then
        seen=$(cat "$D/cfcreads_$ip" 2>/dev/null || echo 0)
        seen=$(( seen + 1 )); echo "$seen" > "$D/cfcreads_$ip"
        if [ "$seen" -lt "$FAKE_CFC_FAILS" ] || [ "$FAKE_CFC_FAILS" = 1 ]; then
          exit 1
        fi
      fi
      cat "$D/cfc_$ip" 2>/dev/null || echo 0
      exit 0 ;;
esac
exit 0
"""


class SroSignBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="t12sro_")
        self.state = os.path.join(self.tmp, "state")
        os.makedirs(self.state)
        self.fake = os.path.join(self.tmp, "fakeboard")
        with open(self.fake, "w") as f:
            f.write(FAKE_BOARD)
        os.chmod(self.fake, os.stat(self.fake).st_mode | stat.S_IEXEC)

    def run_sro(self, args, mode_148=None, mode_146=None, cfc_148=None,
                cfc_146=None, extra_env=None):
        if mode_148 is not None:
            with open(os.path.join(self.state, f"mode_{A}"), "w") as f:
                f.write(str(mode_148) + "\n")
        if mode_146 is not None:
            with open(os.path.join(self.state, f"mode_{B}"), "w") as f:
                f.write(str(mode_146) + "\n")
        if cfc_148 is not None:
            with open(os.path.join(self.state, f"cfc_{A}"), "w") as f:
                f.write(str(cfc_148) + "\n")
        if cfc_146 is not None:
            with open(os.path.join(self.state, f"cfc_{B}"), "w") as f:
                f.write(str(cfc_146) + "\n")
        env = dict(os.environ, W=self.fake, FAKE_STATE=self.state,
                    SRO_CHECK_SAMPLES="2", SRO_CHECK_SLEEP="0")
        if extra_env:
            env.update(extra_env)
        return subprocess.run(["bash", SCRIPT] + args, capture_output=True,
                               text=True, env=env, timeout=60)


class TestConfParses(SroSignBase):
    def test_conf_parses_to_the_expected_map(self):
        self.assertEqual(parse_conf(CONF), {A: 0, B: 1})


class TestWrite(SroSignBase):
    def test_write_from_conf_lands_and_reports_full(self):
        # conf says 146 -> 1; the fake answers 0x25C with bit 5 set (1)
        p = self.run_sro([B], mode_146=1)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn(f"SRO_SIGN {B} wrote=1", p.stdout)
        self.assertIn("edge=FULL", p.stdout)

    def test_write_from_conf_lands_and_reports_empty(self):
        # conf says 148 -> 0; the fake answers 0x25C with bit 5 clear (0)
        p = self.run_sro([A], mode_148=0)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn(f"SRO_SIGN {A} wrote=0", p.stdout)
        self.assertIn("edge=EMPTY", p.stdout)

    def test_write_that_does_not_land_exits_1(self):
        # conf says 146 -> 1, but the fake keeps answering 0 (readback disagrees)
        p = self.run_sro([B], mode_146=0)
        self.assertEqual(p.returncode, 1, p.stdout)
        self.assertIn(f"SRO_SIGN {B} wrote=1", p.stdout)
        self.assertIn("edge=EMPTY", p.stdout)

    def test_unknown_ip_is_rejected_without_a_write(self):
        p = self.run_sro(["10.0.0.99"])
        self.assertNotEqual(p.returncode, 0)
        self.assertFalse(os.path.exists(os.path.join(self.state, "last_write_10.0.0.99")))


class TestWriteFailure(SroSignBase):
    def test_failed_register_write_leaves_shadow_unchanged_and_exits_nonzero(self):
        # pre-seed a known-good shadow so we can prove it survives untouched
        with open(os.path.join(self.state, "fixctl.word"), "w") as f:
            f.write("0x10\n")
        p = self.run_sro([B], mode_146=1, extra_env={"FAKE_WRITE_FAILS": "1"})
        self.assertNotEqual(p.returncode, 0, p.stdout)
        self.assertIn("FIXCTL_WRITE_FAILED", p.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.state, f"last_write_{B}")))
        with open(os.path.join(self.state, "fixctl.word")) as f:
            self.assertEqual(f.read().strip(), "0x10",
                              "a failed 0x208 write must never update the shadow")

    def test_failed_register_write_on_force_also_leaves_shadow_unchanged(self):
        with open(os.path.join(self.state, "fixctl.word"), "w") as f:
            f.write("0x00\n")
        p = self.run_sro([A, "--force", "1"], extra_env={"FAKE_WRITE_FAILS": "1"})
        self.assertNotEqual(p.returncode, 0, p.stdout)
        with open(os.path.join(self.state, "fixctl.word")) as f:
            self.assertEqual(f.read().strip(), "0x00")


class TestForce(SroSignBase):
    def test_force_writes_the_given_value_regardless_of_conf(self):
        # conf says 148 -> 0; force 1, and the fake agrees (readback bit set)
        p = self.run_sro([A, "--force", "1"], mode_148=1)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("SRO_SIGN_FORCED", p.stdout)
        self.assertIn(f"SRO_SIGN_FORCED {A} wrote=1", p.stdout)
        self.assertIn("edge=FULL", p.stdout)
        self.assertNotIn(f"SRO_SIGN {A} wrote", p.stdout)  # not the plain tag

    def test_force_bad_value_is_rejected(self):
        p = self.run_sro([A, "--force", "7"])
        self.assertNotEqual(p.returncode, 0)


class TestShadowPreservesOtherBits(SroSignBase):
    def test_write_preserves_a_pre_existing_w1_freeze_bit(self):
        # pre-seed the shadow with w1_freeze (bit 4, 0x10) already set
        with open(os.path.join(self.state, "fixctl.word"), "w") as f:
            f.write("0x10\n")
        p = self.run_sro([B], mode_146=1)  # conf: 146 -> sro_sign=1 (bit 5, 0x20)
        self.assertEqual(p.returncode, 0, p.stderr)
        with open(os.path.join(self.state, f"last_write_{B}")) as f:
            written = f.read().strip()
        self.assertEqual(int(written, 16), 0x30,  # 0x10 (w1_freeze) | 0x20 (sro_sign)
                          f"expected w1_freeze bit preserved alongside sro_sign, got {written}")
        with open(os.path.join(self.state, "fixctl.word")) as f:
            self.assertEqual(f.read().strip(), "0x30")


class TestRead(SroSignBase):
    def test_read_does_not_write(self):
        p = self.run_sro([A, "--read"], mode_148=0)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("SRO_SIGN_READ", p.stdout)
        self.assertIn("edge=EMPTY", p.stdout)
        self.assertFalse(os.path.exists(os.path.join(self.state, f"last_write_{A}")),
                          "--read must not write 0x208")


class TestCheck(SroSignBase):
    def test_agree_when_sign_matches_conf(self):
        # 146's conf value is 1 (FULL); a positive CFC mean implies 1 -> AGREE
        p = self.run_sro(["--check", B], cfc_146=500)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn(f"SRO_SIGN_CHECK {B}", p.stdout)
        self.assertIn("residual=500 units=reg", p.stdout)
        self.assertIn("cfc_mean=500", p.stdout)
        self.assertIn("implies=1 conf=1 AGREE", p.stdout)
        self.assertIn("lo_offset_hz=", p.stdout)

    def test_disagree_when_sign_contradicts_conf(self):
        # 146's conf value is 1 (FULL); a negative CFC mean implies 0 -> DISAGREE
        p = self.run_sro(["--check", B], cfc_146=-500)
        self.assertEqual(p.returncode, 0, p.stderr)  # a WARNING, not a failure
        self.assertIn("residual=-500 units=reg", p.stdout)
        self.assertIn("implies=0 conf=1 DISAGREE", p.stdout)
        self.assertIn("DISAGREE", p.stderr)  # the warning also lands on stderr

    def test_check_is_read_only(self):
        p = self.run_sro(["--check", A], cfc_148=-100)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.state, f"last_write_{A}")))

    def test_unknown_board_message(self):
        p = self.run_sro(["--check", "10.0.0.99"])
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("unknown board (no LO_*_RX for 10.0.0.99)", p.stderr)


class TestCfcSignExtension(SroSignBase):
    """Task 14 (re-scoped): cfc_mean() read the 32-bit 0x154 value as
    unsigned -- $(( v )) never wraps in 64-bit bash -- so every negative
    CFC reading was averaged and sign-tested as a huge positive number,
    inverting implies=/AGREE|DISAGREE. Values below are the actual raw
    reads quoted in docs/evidence/sp3/SP3_SILICON.md section 10 (a real
    silicon session, both directions inverted there); decimal, because
    that is the form $(( v )) receives whether the fake or the real board
    prints hex or decimal text."""

    def test_negative_reading_on_146_now_sign_extends_and_disagrees(self):
        # conf: 146 -> 1. Raw read 4294962551 (0xFFFFED77) is -4745 as
        # int32 -- negative implies sro_sign=0, which now DISAGREEs with
        # conf=1 (the session's unfixed tool printed AGREE here).
        p = self.run_sro(["--check", B], cfc_146="4294962551",
                          extra_env={"SRO_CHECK_SAMPLES": "1"})
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("residual=-4745 units=reg", p.stdout)
        self.assertIn("cfc_mean=-4745", p.stdout)
        self.assertIn("implies=0 conf=1 DISAGREE", p.stdout)

    def test_negative_reading_on_148_now_sign_extends_and_agrees(self):
        # conf: 148 -> 0. Raw read 4294963838 (0xFFFFF27E) is -3458 as
        # int32 -- negative implies sro_sign=0, which now AGREEs with
        # conf=0 (the session's unfixed tool printed DISAGREE here).
        p = self.run_sro(["--check", A], cfc_148="4294963838",
                          extra_env={"SRO_CHECK_SAMPLES": "1"})
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("residual=-3458 units=reg", p.stdout)
        self.assertIn("cfc_mean=-3458", p.stdout)
        self.assertIn("implies=0 conf=0 AGREE", p.stdout)

    def test_a_genuinely_small_positive_reading_is_unaffected(self):
        # below 2**31, no sign extension applies -- guards against an
        # off-by-one in the >= 2**31 threshold breaking the ordinary case.
        p = self.run_sro(["--check", B], cfc_146="500",
                          extra_env={"SRO_CHECK_SAMPLES": "1"})
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("residual=500 units=reg", p.stdout)
        self.assertIn("implies=1 conf=1 AGREE", p.stdout)


if __name__ == "__main__":
    unittest.main()


class TestCheckUnknown(SroSignBase):
    """Final fix wave, item 5. cfc_mean() folded a FAILED read (read_cfc prints
    the empty string) into the average as a genuine 0 sample -- so a board that
    answered nothing at all averaged to exactly 0 and, because 0 is not < 0,
    was reported as a confident `implies=1`. And a mean of exactly 0 is not a
    sign in the first place: it is the documented CFO dead zone.

    Both now print UNKNOWN with a reason and return 1. The hooks in
    bringup_r2r3.sh / restore_known_good.sh call --check additively and
    non-fatally, so this shows up as one SRO_SIGN_CHECK_HOOK_FAILED log line
    and touches nothing on the board."""

    def test_all_reads_failing_is_unknown_not_a_sign(self):
        p = self.run_sro(["--check", B], cfc_146=500,
                         extra_env={"FAKE_CFC_FAILS": "1", "SRO_CHECK_SAMPLES": "3"})
        self.assertEqual(p.returncode, 1, p.stdout)
        self.assertIn(f"SRO_SIGN_CHECK {B} UNKNOWN reason=reads_failed", p.stdout)
        self.assertIn("valid=0 wanted=3", p.stdout)
        self.assertNotIn("implies=", p.stdout)
        self.assertNotIn("AGREE", p.stdout)

    def test_partially_failing_reads_are_unknown_too(self):
        """Fewer than SRO_CHECK_SAMPLES valid reads is not a sample the verdict
        may rest on, even though the ones that landed were fine."""
        p = self.run_sro(["--check", B], cfc_146=500,
                         extra_env={"FAKE_CFC_FAILS": "3", "SRO_CHECK_SAMPLES": "3"})
        self.assertEqual(p.returncode, 1, p.stdout)
        self.assertIn("reason=reads_failed", p.stdout)
        self.assertIn("valid=1 wanted=3", p.stdout)

    def test_mean_of_exactly_zero_is_the_cfo_dead_zone_not_a_positive_sign(self):
        p = self.run_sro(["--check", B], cfc_146=0,
                         extra_env={"SRO_CHECK_SAMPLES": "2"})
        self.assertEqual(p.returncode, 1, p.stdout)
        self.assertIn(f"SRO_SIGN_CHECK {B} UNKNOWN reason=cfo_dead_zone", p.stdout)
        self.assertIn("cfc_mean=0", p.stdout)
        self.assertNotIn("implies=1", p.stdout)

    def test_a_real_reading_still_produces_a_verdict(self):
        """Guard: the UNKNOWN paths must not have eaten the ordinary one."""
        p = self.run_sro(["--check", B], cfc_146=500, extra_env={"SRO_CHECK_SAMPLES": "2"})
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("implies=1 conf=1 AGREE", p.stdout)
        self.assertNotIn("UNKNOWN", p.stdout)

    def test_check_stays_read_only_on_the_unknown_paths(self):
        p = self.run_sro(["--check", A], cfc_148=0, extra_env={"SRO_CHECK_SAMPLES": "2"})
        self.assertEqual(p.returncode, 1)
        self.assertFalse(os.path.exists(os.path.join(self.state, f"last_write_{A}")))


class TestBringupReseedsTheShadow(SroSignBase):
    """Final fix wave, item 6. /dev/shm is tmpfs and survives a fabric soft
    reset that CLEARS 0x208, so after a reset the shadow over-states the
    register and the read-modify-write would silently re-assert bits the
    hardware has forgotten. Bring-up and restore always follow a reset, so
    --bringup re-seeds the shadow to 0 first. The plain path still trusts it
    (TestShadowPreservesOtherBits is the unchanged half of this contract)."""

    def test_bringup_discards_a_stale_w1_freeze_bit(self):
        with open(os.path.join(self.state, "fixctl.word"), "w") as f:
            f.write("0x10\n")           # w1_freeze remembered from before the reset
        p = self.run_sro([B, "--bringup"], mode_146=1)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn(f"SRO_SIGN_RESEED {B} was=0x10 now=0x0", p.stdout)
        with open(os.path.join(self.state, f"last_write_{B}")) as f:
            written = f.read().strip()
        self.assertEqual(int(written, 16), 0x20,
                         "with --bringup only sro_sign (0x20) may be written, "
                         f"not the stale 0x10 alongside it -- got {written}")
        with open(os.path.join(self.state, "fixctl.word")) as f:
            self.assertEqual(f.read().strip(), "0x20")

    def test_plain_path_is_unchanged_and_still_preserves_other_bits(self):
        with open(os.path.join(self.state, "fixctl.word"), "w") as f:
            f.write("0x10\n")
        p = self.run_sro([B], mode_146=1)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertNotIn("SRO_SIGN_RESEED", p.stdout)
        with open(os.path.join(self.state, f"last_write_{B}")) as f:
            self.assertEqual(int(f.read().strip(), 16), 0x30)

    def test_bringup_with_no_shadow_at_all_is_fine(self):
        p = self.run_sro([A, "--bringup"], mode_148=0)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("SRO_SIGN_RESEED", p.stdout)
        self.assertIn(f"SRO_SIGN {A} wrote=0", p.stdout)

    def test_the_bringup_hooks_actually_pass_the_flag(self):
        """The knob is worthless if the two callers that always follow a reset
        do not use it."""
        for name in ("bringup_r2r3.sh", "restore_known_good.sh"):
            src = open(os.path.join(OPS, name)).read()
            lines = [l for l in src.splitlines()
                     if "sro_sign.sh" in l and "--check" not in l and l.strip().startswith("bash")]
            self.assertTrue(lines, f"{name}: no sro_sign.sh write hook found")
            for l in lines:
                self.assertIn("--bringup", l, f"{name}: write hook does not pass --bringup: {l}")


class TestLoRxOffsetNominalIsPerBoard:
    """lo_rx_offset() must subtract EACH BOARD'S nominal carrier, not 2.0 GHz for both.

    The quiet pair is asymmetric: forward runs 146 TX -> 148 RX at 2.00 GHz, reverse runs
    148 TX -> 146 RX at 1.90 GHz. Until 2026-09-28 this function subtracted 2.0 GHz for both,
    so 146's deliberate +40 kHz was printed in every bring-up and restore log as
    lo_offset_hz=-99960000 (-99.96 MHz). The AGREE/DISAGREE verdict was never affected --
    do_check takes `implies` from the sign of CFC, not from this number -- but a human reading
    those logs to diagnose the reverse leg was handed a figure wrong by five orders of magnitude.
    """

    def _offset(self, ip, var, val, extra=""):
        import pathlib
        import re
        import subprocess
        ops = pathlib.Path(__file__).resolve().parents[1]
        src = (ops / "sro_sign.sh").read_text()
        fn = re.search(r"^lo_rx_offset\(\)\{.*?^\}", src, re.S | re.M).group(0)
        script = (f'A=10.0.0.148; B=10.0.0.146; D={ops}; BRINGUP={ops}/bringup_r2r3.sh\n'
                  f'{fn}\n{extra} {var}={val} lo_rx_offset {ip}\n')
        r = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
        assert r.returncode == 0, r.stderr
        return int(r.stdout.strip().splitlines()[-1])

    def test_board_a_offset_is_against_2ghz(self):
        assert self._offset("10.0.0.148", "LO_A_RX", 2100020000) == 20000   # forward carrier 2.1 GHz since 2026-10-01

    def test_board_b_offset_is_against_the_peers_carrier_from_the_table(self):
        """The regression class: a hard-coded nominal printed -99960000 (2.0 GHz for both) and
        would print -49960000 now that the reverse carrier is 1.85 GHz. The nominal is the
        peer's TX carrier from ops/rung_table.sh, so the shipped +40 kHz plan reads +40000."""
        got = self._offset("10.0.0.146", "LO_B_RX", 1850040000)
        assert got == 40000, f"146's +40 kHz plan must read +40000, got {got}"
        # and the OLD receive value against the NEW carrier is honestly +50.04 MHz, not +40 kHz
        assert self._offset("10.0.0.146", "LO_B_RX", 1900040000) == 50040000

    def test_an_env_override_of_the_carrier_moves_the_nominal_with_it(self):
        """The band-swap experiment overrides LO_A_TX; the offset must be taken against THAT."""
        got = self._offset("10.0.0.146", "LO_B_RX", 1900040000, extra="LO_A_TX=1900000000")
        assert got == 40000, got
        got = self._offset("10.0.0.148", "LO_A_RX", 1900020000, extra="LO_B_TX=1900000000")
        assert got == 20000, got
