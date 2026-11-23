"""Unit tests for the DDRCAP record-layout handling in the TXFIX gate scorer
(sp3 task 8, fix round 1).

The gate's two offset/digest tools both hardcoded the DDRCAP **v1** frame mark
(`lane 2 == 0x7FFF`). Every MODEL-generated tree carries DDRCAP-**v2**, which
repacks that lane (nominal `0x3023`, mark = bit 14 above a 12-bit payload), so on
a model tree `aligned_content_check` returned `no marker found` without comparing
any content and `kick_seq.py` decoded **zero** frames -- which `all(...)` over an
empty list then scored as PASS. These tests pin both halves: v1 still scores
through the identical path, v2 aligns, and an empty offset list is never clean.

Synthetic records only -- no .bin from a run, no Verilator, no MATLAB.
"""
import importlib.util
import pathlib
import sys

import numpy as np
import pytest

RTL = pathlib.Path(__file__).resolve().parents[1] / "rtl_sim"


def _load(name):
    spec = importlib.util.spec_from_file_location(name, RTL / f"{name}.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


kick_seq = _load("kick_seq")


def _records(n, mark_at, layout):
    """n records of (i, q, lane2, lane3) with a frame mark at each `mark_at`."""
    a = np.zeros((n, 4), dtype="<i2")
    a[:, 0] = np.arange(n, dtype="<i2")          # deterministic, sign-varying I/Q
    a[:, 1] = -np.arange(n, dtype="<i2")
    if layout == "v1":
        a[:, 2] = 0
        a[mark_at, 2] = 0x7FFF
    else:                                         # v2: payload 0x3023, mark = bit 14
        a[:, 2] = np.int16(0x3023)
        a[mark_at, 2] = np.int16(np.uint16(0x7023).astype(np.int16))
    return a


def test_v1_marks_are_found_through_the_historical_path():
    a = _records(400, [10, 110, 210], "v1")
    idx, layout = kick_seq.frame_marks(a)
    assert layout == "v1"
    assert idx.tolist() == [10, 110, 210]


def test_v2_marks_are_found_by_lane2_bit14():
    a = _records(400, [7, 107, 207], "v2")
    idx, layout = kick_seq.frame_marks(a)
    assert layout == "v2"
    assert idx.tolist() == [7, 107, 207]


def test_v1_is_tested_first_so_a_v1_capture_never_takes_the_v2_path():
    """0x7FFF has bit 14 set, so an unguarded v2 rule matches v1 records too. The
    v1 test must run first or a v1 capture would be relabelled v2 and scored with
    the modal-offset rule instead of the strict all-zero one."""
    a = _records(400, [10, 110], "v1")
    assert (np.asarray(a[:, 2]).astype(np.uint16) & 0x4000).any()   # the trap
    assert kick_seq.frame_marks(a)[1] == "v1"


def test_v2_capture_with_no_mark_at_all_returns_empty():
    a = _records(100, [], "v2")
    a[:, 2] = np.int16(0x3023)
    idx, layout = kick_seq.frame_marks(a)
    assert layout == "v2" and len(idx) == 0


# --- the scorer half: an empty offset list must never be "clean" -----------------

score = _load("txfix_gate_score") if False else None


@pytest.fixture(scope="module")
def offsets_clean():
    """txfix_gate_score.py runs its whole matrix at import time, so the function
    under test is read out of the source and exec'd on its own."""
    src = (RTL / "txfix_gate_score.py").read_text()
    start = src.index("_LAYOUT = {}")
    end = src.index("def aligned_content_check")
    ns = {}
    exec(compile(src[start:end], "txfix_gate_score.py", "exec"), ns)
    return ns["offsets_clean"], ns["_LAYOUT"]


def test_empty_offset_list_is_not_clean(offsets_clean):
    fn, _ = offsets_clean
    ok, detail = fn([], "beat_runs/whatever.bin")
    assert ok is False and "vacuous" in detail


def test_all_unmapped_offsets_are_not_clean(offsets_clean):
    fn, _ = offsets_clean
    ok, detail = fn([(0, None), (1, None)], "beat_runs/whatever.bin")
    assert ok is False and "vacuous" in detail


def test_v1_keeps_the_strict_all_zero_rule(offsets_clean):
    fn, lay = offsets_clean
    p = "beat_runs/v1.bin"; lay[p] = "v1"
    assert fn([(i, 0) for i in range(58)], p)[0] is True
    assert fn([(0, 0), (1, 7), (2, 0)], p)[0] is False
    # a uniformly NON-zero v1 run is still a failure -- the rule is not relaxed
    assert fn([(i, 12264) for i in range(58)], p)[0] is False


def test_v2_uses_the_runs_own_modal_offset_as_the_baseline(offsets_clean):
    fn, lay = offsets_clean
    p = "beat_runs/v2.bin"; lay[p] = "v2"
    ok, detail = fn([(i, 12264) for i in range(58)], p)
    assert ok is True and "modal_offset=12264" in detail


def test_v2_still_catches_a_frame_that_departs(offsets_clean):
    fn, lay = offsets_clean
    p = "beat_runs/v2.bin"; lay[p] = "v2"
    seq = [(i, 12264) for i in range(58)]
    seq[9] = (9, 12263)
    ok, detail = fn(seq, p)
    assert ok is False and "departing=[(9, 12263)]" in detail


# --- aligned_content_check: v1 vs v1 as before, v1 vs v2 now aligns -------------


@pytest.fixture(scope="module")
def aligned_check():
    src = (RTL / "txfix_gate_score.py").read_text()
    start = src.index("def aligned_content_check")
    end = src.index("def grep(path, pat):")
    ns = {"os": __import__("os")}
    exec(compile(src[start:end], "txfix_gate_score.py", "exec"), ns)
    return ns["aligned_content_check"]


def _write(tmp_path, name, a):
    p = tmp_path / name
    a.astype("<i2").tofile(p)
    return str(p)


def test_same_layout_pair_compares_the_whole_record_and_matches(tmp_path, aligned_check):
    a = _records(400, [10, 110, 210], "v1")
    pa = _write(tmp_path, "a.bin", a); pb = _write(tmp_path, "b.bin", a.copy())
    r = aligned_check(pa, pb)
    assert r["ok"] is True and r["layout_a"] == r["layout_b"] == "v1"
    assert r["compared_lanes"] == "all4" and r["markers_a"] == 3


def test_same_layout_pair_still_fails_on_a_real_content_difference(tmp_path, aligned_check):
    a = _records(400, [10, 110, 210], "v1")
    b = a.copy(); b[250, 0] += 1
    r = aligned_check(_write(tmp_path, "a.bin", a), _write(tmp_path, "b.bin", b))
    assert r["ok"] is False and r["differing_records_in_overlap"] == 1
    assert r["first_differing_record"] == 250 - 10          # relative to the first mark


def test_v2_against_a_v1_baseline_aligns_and_compares_the_IQ_lanes(tmp_path, aligned_check):
    """The regression this fix is for: identical I/Q, different lane-2/3 packing.
    Before, this returned 'no marker found' and never looked at the samples."""
    v1 = _records(400, [10, 110, 210], "v1")
    v2 = _records(400, [10, 110, 210], "v2")
    r = aligned_check(_write(tmp_path, "m.bin", v2), _write(tmp_path, "u.bin", v1))
    assert "reason" not in r
    assert r["layout_a"] == "v2" and r["layout_b"] == "v1"
    assert r["compared_lanes"] == "IQ01(layouts differ)"
    assert r["ok"] is True and r["differing_records_in_overlap"] == 0


def test_v2_against_v1_still_fails_on_an_IQ_difference(tmp_path, aligned_check):
    v1 = _records(400, [10, 110, 210], "v1")
    v2 = _records(400, [10, 110, 210], "v2"); v2[300, 1] += 3
    r = aligned_check(_write(tmp_path, "m.bin", v2), _write(tmp_path, "u.bin", v1))
    assert r["ok"] is False and r["differing_records_in_overlap"] == 1
    assert r["first_differing_record"] == 290
