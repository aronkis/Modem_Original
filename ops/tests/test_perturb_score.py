"""Unit tests for modem/rtl_sim/perturb_score.py (carrier-lock perturbation study, 2026-09-29).

The scorer reads the per-frame CSV written by sim_sro_perturb.cpp. Pin the three verdicts the
evidence doc rests on: a run that re-locks after a dropout reports the frame count, a run that
never re-locks says 'never' (the latch), and resets are bucketed pre/during/post the window.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'modem', 'rtl_sim'))
import perturb_score  # noqa: E402


def _row(frame, dp, drst, cfc, pert):
    # frame,sidx,packets,d_packets,biterr,d_biterr,frame_start,rstcs,d_rstcs,cfc_est,pert
    return f"{frame},{frame*49268},{frame},{dp},0,0,1,0,{drst},{cfc},{pert}\n"


def _write(tmp_path, name, rows):
    p = tmp_path / f"{name}_pert.txt"
    p.write_text("# header\n# rms=1\n" + "".join(rows))
    return str(p)


def test_relock_after_dropout_counts_frames_from_window_end(tmp_path):
    rows = [_row(f, 1, 0, -150, 0) for f in range(0, 100)]
    rows += [_row(f, 0, 1 if f == 100 else 0, 0, 2) for f in range(100, 125)]      # dropout window
    rows += [_row(f, 0, 0, 3000, 0) for f in range(125, 130)]                      # re-acquiring
    rows += [_row(f, 1, 0, -160, 0) for f in range(130, 200)]                      # locked again
    out = perturb_score.score(_write(tmp_path, "gap", rows))
    assert "relock_frames=6" in out   # first locked frame 130 minus window end 124
    assert "resets pre=   0 during=    1 post=    0" in out


def test_latched_receiver_reports_never(tmp_path):
    rows = [_row(f, 1, 0, -150, 0) for f in range(0, 100)]
    rows += [_row(f, 0, 0, 0, 2) for f in range(100, 125)]
    # after the window: no frame syncs, estimator wandering +/-3000 -- the silicon latch
    rows += [_row(f, 0, 0, (3000 if f % 2 else -3000), 0) for f in range(125, 300)]
    out = perturb_score.score(_write(tmp_path, "latch", rows))
    assert "relock_frames=never" in out
    assert "post40=0/40" in out


def test_no_perturbation_has_no_relock_column_value(tmp_path):
    rows = [_row(f, 1, 0, -150, 0) for f in range(0, 50)]
    out = perturb_score.score(_write(tmp_path, "base", rows))
    assert "syncs pre=42/42" in out          # frames 8..49
    assert "relock_frames=None" in out


def test_gate_passes_a_relock_and_fails_the_latch(tmp_path):
    rows = [_row(f, 1, 0, -150, 0) for f in range(0, 100)]
    rows += [_row(f, 0, 0, 0, 2) for f in range(100, 125)]
    rows += [_row(f, 0, 0, 3000, 0) for f in range(125, 128)]
    rows += [_row(f, 1, 0, -160, 0) for f in range(128, 200)]
    ok, why = perturb_score.gate(_write(tmp_path, "relock", rows))
    assert ok and "relock=4" in why
    rows = [_row(f, 1, 0, -150, 0) for f in range(0, 100)]
    rows += [_row(f, 0, 0, 0, 2) for f in range(100, 101)]
    rows += [_row(f, 0, 0, (3000 if f % 2 else -3000), 0) for f in range(101, 200)]
    ok, why = perturb_score.gate(_write(tmp_path, "latch", rows))
    assert not ok and why.startswith("LATCHED")


def test_gate_fails_a_slow_relock_and_a_lossy_lock(tmp_path):
    rows = [_row(f, 1, 0, -150, 0) for f in range(0, 100)]
    rows += [_row(f, 0, 0, 0, 2) for f in range(100, 101)]
    rows += [_row(f, 0, 0, 3000, 0) for f in range(101, 110)]      # 9 frames to re-lock
    rows += [_row(f, 1, 0, -150, 0) for f in range(110, 200)]
    ok, why = perturb_score.gate(_write(tmp_path, "slow", rows))
    assert not ok and "relock 10 frames" in why
    rows = [_row(f, (0 if f % 10 == 0 else 1), 0, -150, 0) for f in range(0, 120)]   # 10 % frames lost, no window
    ok, why = perturb_score.gate(_write(tmp_path, "lossy", rows))
    assert not ok and "< 0.99" in why


def test_gate_cli_exit_code(tmp_path):
    import subprocess, sys as _sys
    rows = [_row(f, 1, 0, -150, 0) for f in range(0, 60)]
    good = _write(tmp_path, "good", rows)
    r = subprocess.run([_sys.executable, perturb_score.__file__, "--gate", good], capture_output=True, text=True)
    assert r.returncode == 0 and r.stdout.startswith("PASS good")


def test_tilt_budget_verdict(tmp_path):
    """--tilt-budget: PASS iff every frame from 8 syncs, |median cfc| < 30 and median |delta cfc| < 200."""
    import subprocess, sys, os
    here = os.path.dirname(__file__)
    script = os.path.join(here, "..", "..", "modem", "rtl_sim", "perturb_score.py")
    hdr = "# frame,a,b,dp,c,biterr,d,e,rstcs,cfc," + ",".join(f"c{i}" for i in range(10, 40)) + "\n"
    def write(name, cfc_fn, dp_fn=lambda f: 1):
        p = tmp_path / f"{name}_pert.txt"
        p.write_text(hdr + "".join(",".join([str(f), "0", "0", str(dp_fn(f)), "0", "0", "0", "0", "0", str(cfc_fn(f))] + ["0"] * 30) + "\n" for f in range(120)))
        return str(p)
    good = write("good", lambda f: -12 + (f % 3))
    biased = write("biased", lambda f: -500 + (f % 3))
    noisy = write("noisy", lambda f: 300 * (-1) ** f)
    missed = write("missed", lambda f: -12, lambda f: 0 if f == 50 else 1)
    r = subprocess.run([sys.executable, script, "--tilt-budget", good], capture_output=True, text=True)
    assert r.returncode == 0 and r.stdout.startswith("PASS good syncs=112/112"), r.stdout
    for bad in (biased, noisy, missed):
        r = subprocess.run([sys.executable, script, "--tilt-budget", bad], capture_output=True, text=True)
        assert r.returncode == 1 and r.stdout.startswith("FAIL"), (bad, r.stdout)
    r = subprocess.run([sys.executable, script, "--tilt-budget", "--min-syncs", "0.95", missed], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout
    live = write("live", lambda f: -3450 + (f % 3))        # a live capture on the +20 kHz plan: the median IS the plan
    r = subprocess.run([sys.executable, script, "--tilt-budget", live], capture_output=True, text=True)
    assert r.returncode == 1
    r = subprocess.run([sys.executable, script, "--tilt-budget", "--bias-center", "-3400", "--max-bias", "300", live], capture_output=True, text=True)
    assert r.returncode == 0 and "center -3400" in r.stdout, r.stdout
