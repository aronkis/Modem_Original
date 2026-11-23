"""sp3 task 9: the RELATIVE offset rule in modem/rtl_sim/txfix_gate_score.py.

Controller ruling (2026-09-12): the offset criterion for a model-lineage pair is that
the FIXED run's per-frame offset sequence equals the UNFIXED same-receiver baseline's,
not that every offset is absolutely zero -- the offsets are `RxSteer`'s lock walk, a
property of the receiver, while these rows exist to score the transmitter.

On the injected v1 lineage every unfixed offset IS zero, so the relative rule reduces
to the absolute one -- **on the rows where every frame decodes**. That qualifier is
load-bearing and is pinned below both ways: the reduction, and the measured case where
the two rules differ (`g7_latchforce_pre` is 5 mapped / 53 unmapped even on the
injected v1 lineage, so `offsets_clean()` passes it by SKIPPING the unmapped frames
while the relative rule fails it for having no evidence).

`txfix_gate_score.py` scores at IMPORT time (its body is module-level, by design: one
invocation per completed run directory), so the function under test is lifted out by
AST rather than imported -- importing would run the whole matrix scorer.
"""
import ast
import pathlib

import pytest

SCORE = pathlib.Path(__file__).resolve().parents[1] / "rtl_sim" / "txfix_gate_score.py"


def _lift(*names):
    """exec ONLY the named top-level functions of the scorer, in a private namespace."""
    src = SCORE.read_text()
    tree = ast.parse(src, str(SCORE))
    body = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in names]
    missing = set(names) - {n.name for n in body}
    assert not missing, f"{SCORE} has no top-level function(s) {sorted(missing)}"
    ns = {}
    exec(compile(ast.Module(body=body, type_ignores=[]), str(SCORE), "exec"), ns)
    return ns


@pytest.fixture(scope="module")
def omb():
    return _lift("offsets_match_baseline")["offsets_match_baseline"]


def _seq(offsets, first=0):
    return [(first + i, o) for i, o in enumerate(offsets)]


def test_equal_sequences_pass(omb):
    """The ruling's PASS case: F3 and U agree frame for frame (a non-zero model walk)."""
    u = _seq([12264, 12264, 12272, 12264, 12272, 12272, 12264, 12264, 12272, 12264])
    ok, detail = omb(list(u), u, "beat_runs/g0_none_U")
    assert ok, detail
    assert "rule=relative" in detail
    assert "equals_unfixed=True" in detail
    assert "common=10" in detail


def test_differing_sequences_fail(omb):
    """The ruling's FAIL case: one frame departs from the unfixed baseline."""
    u = _seq([12264] * 10)
    f3 = _seq([12264] * 4 + [7] + [12264] * 5)
    ok, detail = omb(f3, u, "beat_runs/g0_none_U")
    assert not ok
    assert "equals_unfixed=False" in detail
    assert "(4, 7, 12264)" in detail  # frame, fixed, unfixed


def test_v1_lineage_reduces_to_all_offsets_zero_WHEN_EVERY_FRAME_DECODES(omb):
    """On the injected v1 lineage the unfixed offsets are all 0, so -- for a capture in
    which every frame decodes -- the relative rule accepts exactly the all-zero fixed
    sequences the absolute rule accepted, and rejects the same ones."""
    u = _seq([0] * 12)
    assert omb(_seq([0] * 12), u, "beat_runs/g0_none_U")[0]
    assert not omb(_seq([0] * 6 + [3] + [0] * 5), u, "beat_runs/g0_none_U")[0]


def test_v1_lineage_rules_DIFFER_when_frames_do_not_decode(omb):
    """The reduction above does NOT hold for an undecodable capture, and the claim must
    not be made unqualified. Shape of the real injected-v1 g7_latchforce_pre capture:
    5 of 58 frames mapped, the rest None, against a fully-mapped all-zero baseline.

    offsets_clean() SKIPS None offsets (`if o is not None`), so it sees 5 zeros and
    passes. The relative rule sees 53 frames whose baseline is mapped and whose fixed
    value is not, and fails -- which is the point: a row with no offset evidence must
    not score PASS.
    """
    u = _seq([0] * 58)
    g7 = _seq([0] * 5 + [None] * 53)
    ok, detail = omb(g7, u, "beat_runs/g0_none_U")
    assert not ok, detail
    # it fails as VACUOUS (too few frames mapped on both sides), not as a content
    # mismatch -- the honest reason
    assert "vacuous" in detail and "mapped on BOTH sides" in detail
    # and the old absolute rule really would have passed it: 5 known offsets, all 0
    known = [o for _, o in g7 if o is not None]
    assert known == [0] * 5


def test_all_unmapped_overlap_is_vacuous_not_a_pass(omb):
    """`dict(base_seq)` stores an unmapped baseline frame as None, and `None != None` is
    False -- so without a mapped-frame guard a row whose whole overlap is undecodable on
    BOTH sides would score equals_unfixed=True on ZERO evidence. It must fail."""
    u = _seq([None] * 20)
    f3 = _seq([None] * 20)
    ok, detail = omb(f3, u, "beat_runs/g0_none_U")
    assert not ok, detail
    assert "vacuous" in detail and "0 of 20 common" in detail


def test_mapped_frame_mismatch_still_fails_with_unmapped_frames_present(omb):
    """A real departure on a MAPPED frame is reported even when other frames are
    unmapped -- the guard must not swallow evidence it does have."""
    u = _seq([12264] * 40)
    f3 = _seq([12264] * 19 + [7] + [12264] * 20)
    ok, detail = omb(f3, u, "beat_runs/g0_none_U")
    assert not ok
    assert "equals_unfixed=False" in detail and "(19, 7, 12264)" in detail


def test_mapped_fraction_scales_with_the_shorter_run(omb):
    """The floor is a FRACTION of the shorter decoded sequence, not a flat 8: a 200-frame
    pair with only 10 mapped frames is not evidence even though 10 > 8."""
    u = _seq([5] * 200)
    f3 = _seq([5] * 10 + [None] * 190)
    ok, detail = omb(f3, u, "beat_runs/g0_none_U")
    assert not ok and "vacuous" in detail
    assert "need >= 50" in detail          # 0.25 * min(200, 200)


def test_empty_and_short_overlaps_are_never_clean(omb):
    """The trap offsets_clean() documents: `all(...)` over an empty list is True, so an
    undecodable capture must not score PASS on no evidence."""
    u = _seq([0] * 10)
    ok, detail = omb([], u, "beat_runs/g0_none_U")
    assert not ok and "vacuous" in detail
    ok, detail = omb(_seq([0] * 10), [], "beat_runs/g0_none_U")
    assert not ok and "vacuous" in detail
    # a fixed run whose frame indices barely overlap the baseline's is not evidence
    ok, detail = omb(_seq([0] * 3, first=100), u, "beat_runs/g0_none_U")
    assert not ok and "vacuous" in detail and "common frame" in detail


def test_only_common_frame_indices_are_compared(omb):
    """Runs of different length still compare, on the frames they share."""
    u = _seq([5] * 50)
    ok, detail = omb(_seq([5] * 26), u, "beat_runs/g0_none_U")
    assert ok, detail
    assert "common=26" in detail and "mapped_both=26" in detail


def test_scorer_wires_the_relative_rule_into_the_three_offset_rows():
    """G3, G4/G5 and G7 must score through offsets_ok (which selects the rule), not
    through offsets_clean directly -- otherwise the ruling is dead code."""
    src = SCORE.read_text()
    calls = [l for l in src.splitlines()
             if "offsets_ok(seq" in l and not l.lstrip().startswith("def ")]
    assert len(calls) == 3, f"expected G3, G4/G5 and G7 to call offsets_ok, got {calls}"
    tree = ast.parse(src, str(SCORE))
    top = {n.name for n in tree.body if isinstance(n, ast.FunctionDef)}
    assert {"offsets_ok", "offsets_match_baseline", "offsets_clean"} <= top
    # offsets_clean survives as the documented fallback, and only offsets_ok calls it
    assert "offsets_clean(seq, bpath)" in src


def test_every_offset_scored_row_has_a_configured_baseline():
    """The map must cover all three variants of the three offset-scored row families."""
    ns = {}
    src = SCORE.read_text()
    tree = ast.parse(src, str(SCORE))
    for node in tree.body:
        if isinstance(node, (ast.Assign, ast.For)) and "OFFSET_BASELINE" in ast.dump(node):
            exec(compile(ast.Module(body=[node], type_ignores=[]), str(SCORE), "exec"), ns)
    m = ns["OFFSET_BASELINE"]
    for v in ("F1", "F2", "F3"):
        assert m[f"beat_runs/g3_none_{v}"] == "beat_runs/g0_none_U"
        # every offset-scored row is measured against the UNFORCED unfixed run: the
        # forced U rows (g1, g2) are the ones that DEMONSTRATE the defect, so using one
        # as a baseline would invert the test.  Measured: g1_popabort_U_k0's offsets
        # halve to 6088 while g4_popabort_F3_* hold the 12264 lock walk.
        assert m[f"beat_runs/g4_popabort_{v}_k0"] == "beat_runs/g0_none_U"
        assert m[f"beat_runs/g4_popabort_{v}_k6"] == "beat_runs/g0_none_U"
        assert m[f"beat_runs/g7_latchforce_pre_{v}"] == "beat_runs/g0_none_U"
    assert set(m.values()) == {"beat_runs/g0_none_U"}
    assert len(m) == 12
