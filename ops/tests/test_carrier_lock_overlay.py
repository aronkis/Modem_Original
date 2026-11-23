"""timing_hardening_overlay.m carries the symbol-sync integrator clamp at 0.004 and converges an
existing block to it (CARRIER_LOCK_LATCH_2026-09-29.md: the 0.06 rail is absorbing -- the latched
receiver -- 0.004 re-locks in 3 frames with the clean decode bit-identical; 0.002 changes the decode).
"""
import os
import re

M = os.path.join(os.path.dirname(__file__), '..', '..', 'modem', 'dev', 'simulink', 'timing_hardening_overlay.m')


def _code():
    s = open(M).read()
    return "\n".join(l for l in s.splitlines() if not l.lstrip().startswith('%'))


def test_clamp_limit_is_0p004_from_one_constant():
    s = _code()
    assert re.search(r"integClampLim\s*=\s*0\.004\s*;", s)
    assert "'UpperLimit', '0.06'" not in s and "0.06" not in s, "no hard-coded 0.06 left in code"
    assert "'UpperLimit', integClampStr, 'LowerLimit', ['-' integClampStr]" in s


def test_existing_block_at_another_limit_is_corrected_and_asserted():
    s = _code()
    assert "set_param(sat, 'UpperLimit', integClampStr, 'LowerLimit', ['-' integClampStr])" in s
    assert "IntegClamp limit != +-%s after apply" in s
    # carrier loop still untouched
    assert "carrier loop must stay untouched" in s


def test_carrier_lock_legs_table_is_well_formed():
    legs = os.path.join(os.path.dirname(__file__), '..', '..', 'modem', 'gates', 'carrier_lock.legs')
    rows = [l.rstrip("\n") for l in open(legs) if l.strip() and not l.startswith('#')]
    names = [r.split('|', 2)[0] for r in rows]
    assert len(set(names)) == len(names) and all(len(r.split('|', 2)) == 3 for r in rows)
    assert names[0] == 'cl_build' and {'cl_cfoP40k', 'cl_gap1', 'cl_gap25', 'cl_identity', 'cl_nolatch'} <= set(names)
    txt = "\n".join(rows)
    # the three rows the shipped tree fails are all scored by the --gate criterion
    assert 'perturb_score.py --gate' in txt and 'cl_cfoP40k_pert.txt' in txt and 'cl_gap1_pert.txt' in txt and 'cl_gap25_pert.txt' in txt
    # identity against the banked shipped-tree baseline, first ten columns
    assert "cut -d, -f1-10) ${CL_BANK:-/mnt/onetb/scratch/qpsk-build-trees/carrier_lock_bank}/carrier_lock_c060_baseline_cols1_10.txt" in txt
    assert "$BANK/carrier_lock" not in txt and "$SRO/carrier_lock" not in txt, "bank dirs are listing-hashed; never put a reference file in them"
