#!/usr/bin/env python3
"""test_latched_write.py -- plan 2026-09-25-rig-instability Task 4 (I4).

0x208 is a latched control with a witness at 0x25C. On 2026-09-25 a write that did not land on
board 148 printed FIXCTL_WRITE_FAILED and the bring-up carried on; that board was minutes from
hanging, and every measurement taken after it was unattributable. A control write that cannot be
verified must retry once and then FAIL, and the bring-up must not declare success over it.

Static checks plus the behavioural ones the fake-board harness in test_sro_sign_conf.py covers.
"""
import pathlib
import re

OPS = pathlib.Path(__file__).resolve().parents[1]
SRO = (OPS / "sro_sign.sh").read_text()
BRINGUP = (OPS / "bringup_r2r3.sh").read_text()


def test_write_retries_once_before_failing():
    blk = SRO[SRO.index("_lw_attempt=1"):SRO.index("LATCHED_WRITE_FAIL")]
    assert "while :" in blk, "must loop rather than write once"
    assert '_lw_attempt" -ge 2' in blk, "exactly one retry"
    assert "sleep 1" in blk, "a retry with no settle is not a retry"


def test_failure_is_explicit_and_names_the_witness():
    assert "LATCHED_WRITE_FAIL" in SRO
    m = re.search(r'LATCHED_WRITE_FAIL \$ip reg=(\S+) want=\$val witness=(\S+)', SRO)
    assert m and m.group(1) == "0x208" and m.group(2) == "0x25C", "name the register and its witness"


def test_the_observed_readback_is_always_reported():
    """The disagreeing readback is the diagnostic; it must not be swallowed on a failed attempt."""
    blk = SRO[SRO.index("_lw_attempt=1"):SRO.index("LATCHED_WRITE_FAIL")]
    i_echo = blk.index('wrote=$val readback_mode=$hexrb edge=$edge"')
    i_ret = blk.index('[ "$bit" = "$val" ] && return 0')
    assert i_echo < i_ret, "report the readback before deciding on it"


def test_bringup_hook_is_fatal_not_advisory():
    """The 2026-09-25 hook was `|| echo SRO_SIGN_HOOK_FAILED` -- a note nobody read."""
    assert "SRO_SIGN_HOOK_FATAL" in BRINGUP
    assert "SRO_SIGN_HOOK_FAILED" not in BRINGUP, "the advisory form must be gone"
    hook = BRINGUP[BRINGUP.index("SRO_SIGN_HOOK_FATAL") - 400:BRINGUP.index("SRO_SIGN_HOOK_FATAL") + 200]
    assert "exit 4" in hook, "must stop the bring-up"
    assert "NOT declaring bring-up complete" in hook


def test_the_check_hook_stays_advisory():
    """--check is a cross-check against CFC sign and is explicitly 'a finding, not an automatic
    flip'; it must NOT become fatal."""
    assert "SRO_SIGN_CHECK_HOOK_FAILED" in BRINGUP
