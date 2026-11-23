#!/usr/bin/env python3
"""test_bringup_settle.py -- plan 2026-09-25-rig-instability Task 3: the arm gate probes once and
declares success; on 2026-09-25 it passed at 1247 f/s and the link was at 478 f/s a minute later.
Static checks on ops/bringup_r2r3.sh (a live bring-up cannot be run at the desk)."""
import pathlib
import re

OPS = pathlib.Path(__file__).resolve().parents[1]
S = (OPS / "bringup_r2r3.sh").read_text()


def test_settle_recheck_exists_after_the_gate():
    assert S.index("ARM GATE PASS (try $try)") < S.index("ARM_SETTLE"), "settle must follow the gate"
    assert "SETTLE_S=${SETTLE_S:-60}" in S, "default 60 s"
    assert "ARM_SETTLE_OK" in S and "ARM_SETTLE_FAIL" in S


def test_settle_respects_gate_dir_and_the_same_threshold():
    blk = S[S.index("ARM_SETTLE" ) - 1400: S.index("ARM_SETTLE_OK")]
    assert "GATE_DIR" in blk, "one-direction runs must not be failed by the other leg"
    assert "$GATE_FPS" in blk, "the settle check must use the gate's own threshold"


def test_settle_rerolls_and_is_bounded_by_gate_tries():
    blk = S[S.index("SETTLE_S=${SETTLE_S:-60}"):]
    blk = blk[:blk.index("\n# ---- daemons")] if "\n# ---- daemons" in blk else blk
    assert "rearm_rom $B; rearm_rom $A" in blk, "a failed settle must re-roll the arm"
    assert 'stry" -gt "$GATE_TRIES' in blk, "the re-roll must be bounded by GATE_TRIES"
    assert "NOT starting daemons" in blk, "an arm that never holds must not start daemons"


def test_settle_can_be_disabled_by_a_caller_that_does_its_own():
    assert '[ "$SETTLE_S" -gt 0 ]' in S


def test_daemons_start_only_after_the_settle_block():
    assert S.index("ARM_SETTLE_OK") < S.index("start_daemon $B"), "daemons must follow the settle check"


def test_bringup_takes_the_rig_mutex():
    """The sentinel's recovery chain calls this script; so do the campaign rails. Taking the lock
    makes them mutually exclusive by construction (the 2026-09-25 collision that hung 148)."""
    assert "sim_repro/riglock.sh" in S and "rig_lock_only" in S
    assert "trap 'rig_unlock_only' EXIT" in S
    # taken before the first board contact (arm_rom) and before the gate
    assert S.index("rig_lock_only") < S.index("arm_rom $B $LO_B_TX")

