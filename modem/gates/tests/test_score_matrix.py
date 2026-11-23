import subprocess, sys, pathlib
H = pathlib.Path(__file__).resolve().parents[1]

def run(tmp, ref, res, t7log):
    (tmp/"ref.toml").write_text(ref)
    (tmp/"x_res.txt").write_text(res)
    (tmp/"x_t7.log").write_text(t7log)
    return subprocess.run([sys.executable, str(H/"score_matrix.py"), "--ref", str(tmp/"ref.toml"),
                           "--run", str(tmp), "--map", "R4B/n_m10=x"], text=True, capture_output=True)

REF = 'ref = { "R4B/n_m10" = { loss_pct = 0.48, skips = 30, extras = 0 } }\n'
RES_OK = "r3_skips=32 r3_extras=0\n"

def test_within_tolerance_passes(tmp_path):
    r = run(tmp_path, REF, RES_OK, "x: seq 1..433 expect=433 OK=430 CORRUPT=0 MISSING=3 nomagic_frames=1 LOSS=0.55%\n")
    assert "MATRIX R4B/n_m10 PASS" in r.stdout and "MATRIX_EXIT 0" in r.stdout

def test_loss_outside_tolerance_fails(tmp_path):
    RES = "r3_skips=30 r3_extras=0\n"   # 0.22 pp > max(0.10, 0.048)
    r = run(tmp_path, REF, RES, "x: seq 1..433 expect=433 OK=427 CORRUPT=0 MISSING=6 nomagic_frames=1 LOSS=0.70%\n")
    assert "MATRIX R4B/n_m10 FAIL" in r.stdout and "MATRIX_EXIT 1" in r.stdout

def test_count_tolerance_floor_is_two():
    from score_matrix import count_tol, loss_tol
    assert count_tol(0) == 2 and count_tol(30) == 3 and count_tol(412) == 42
    assert abs(loss_tol(0.48) - 0.10) < 1e-9 and abs(loss_tol(4.99) - 0.499) < 1e-9


# W1 rows carry no loss_pct (module docstring) -- score() must still score
# something (mismatches/delivered) for them, or a W1 row is vacuously PASS
# regardless of what its _res.txt says (the bug fixed alongside --jobs).
W1_REF = 'ref = { "W1/p000" = { mismatches = 0, delivered = 164 } }\n'

def run_w1(tmp, res):
    (tmp/"ref.toml").write_text(W1_REF)
    (tmp/"w1_p000_res.txt").write_text(res)
    (tmp/"w1_p000_t7.log").write_text("")  # W1 has no score_t7 leg/log
    return subprocess.run([sys.executable, str(H/"score_matrix.py"), "--ref", str(tmp/"ref.toml"),
                           "--run", str(tmp), "--map", "W1/p000=w1_p000"], text=True, capture_output=True)

def test_w1_row_scores_delivered_and_mismatches(tmp_path):
    r = run_w1(tmp_path, "W1GATE prefix=w1_p000 frames=166 delivered=164\nW1GATE mode=w1 mismatches=0 verdict=PASS\n")
    assert "MATRIX W1/p000 PASS" in r.stdout and "MATRIX_EXIT 0" in r.stdout
    assert "delivered=164" in r.stdout and "mismatches=0" in r.stdout  # not a vacuous empty detail

def test_w1_row_with_real_mismatches_fails(tmp_path):
    r = run_w1(tmp_path, "W1GATE prefix=w1_p000 frames=166 delivered=140\nW1GATE mode=w1 mismatches=9 verdict=FAIL\n")
    assert "MATRIX W1/p000 FAIL" in r.stdout and "MATRIX_EXIT 1" in r.stdout


# --- a row that scores NOTHING must FAIL, not vacuously pass -----------------
# Two distinct ways a row scored nothing and still printed PASS with an empty
# detail string: the reference keys never intersected the observed keys, and
# the `<prefix>_res.txt` file was absent altogether.

VACUOUS_REF = 'ref = { "X/none" = { unknown_metric = 3 } }\n'

def run_map(tmp, ref, prefix, key, res=None, t7=None):
    (tmp/"ref.toml").write_text(ref)
    if res is not None:
        (tmp/f"{prefix}_res.txt").write_text(res)
    if t7 is not None:
        (tmp/f"{prefix}_t7.log").write_text(t7)
    return subprocess.run([sys.executable, str(H/"score_matrix.py"), "--ref", str(tmp/"ref.toml"),
                           "--run", str(tmp), "--map", f"{key}={prefix}"], text=True, capture_output=True)

def test_row_whose_reference_keys_never_intersect_fails(tmp_path):
    """No loss_pct, and `unknown_metric` is in no COUNT_KEYS -- nothing is
    compared, so the row must not report PASS on an empty detail."""
    r = run_map(tmp_path, VACUOUS_REF, "v", "X/none", res="something=1\n", t7="")
    assert "MATRIX X/none FAIL" in r.stdout, r.stdout
    assert "vacuous -- no scored keys" in r.stdout, r.stdout
    assert "MATRIX_EXIT 1" in r.stdout

def test_row_whose_res_keys_are_all_absent_fails(tmp_path):
    """The reference keys ARE scorable names, but the run's _res.txt carries
    none of them -- today's `missing key: skipped, not failed` path. Nothing
    intersected, so the row is vacuous."""
    ref = 'ref = { "W1/p000" = { mismatches = 0, delivered = 164 } }\n'
    r = run_map(tmp_path, ref, "w1x", "W1/p000", res="W1GATE prefix=w1x verdict=SKIP\n", t7="")
    assert "MATRIX W1/p000 FAIL" in r.stdout, r.stdout
    assert "vacuous -- no scored keys" in r.stdout, r.stdout

def test_missing_res_file_fails(tmp_path):
    """`<prefix>_res.txt` absent: parse_res returns {} and every count key is
    skipped, so the row used to pass on a file that was never written."""
    ref = 'ref = { "W1/p000" = { mismatches = 0, delivered = 164 } }\n'
    r = run_map(tmp_path, ref, "gone", "W1/p000", res=None, t7="")
    assert "MATRIX W1/p000 FAIL" in r.stdout, r.stdout
    assert "res=MISSING" in r.stdout, r.stdout
    assert "MATRIX_EXIT 1" in r.stdout

def test_missing_res_file_fails_even_when_the_loss_leg_is_fine(tmp_path):
    """A loss-only row with a good t7 log still fails if its _res.txt is gone:
    the counts it was meant to carry are unverified, not absent-by-design."""
    ref = 'ref = { "R4B/n_m10" = { loss_pct = 0.48, skips = 30 } }\n'
    r = run_map(tmp_path, ref, "lonly", "R4B/n_m10", res=None,
                t7="x: seq 1..433 expect=433 OK=430 CORRUPT=0 MISSING=3 LOSS=0.48%\n")
    assert "MATRIX R4B/n_m10 FAIL" in r.stdout, r.stdout
    assert "res=MISSING" in r.stdout and "loss=0.48" in r.stdout, r.stdout

def test_a_row_that_does_score_is_not_marked_vacuous(tmp_path):
    r = run_w1(tmp_path, "W1GATE prefix=w1_p000 frames=166 delivered=164\nW1GATE mismatches=0 verdict=PASS\n")
    assert "MATRIX W1/p000 PASS" in r.stdout
    assert "vacuous" not in r.stdout and "res=MISSING" not in r.stdout
