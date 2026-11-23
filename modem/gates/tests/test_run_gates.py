"""run_gates.sh --jobs N: the parallel-with-dependency scheduling rule.

test_run_gates_jobs.sh exercises the real run_gates.sh (not a
re-implementation) on a fake 4-leg table of sleep commands, so the test
cannot drift from what ships. See that script's header for the scheduling
rule under test and why the fake legs are shaped the way they are.
"""
import subprocess, pathlib

HERE = pathlib.Path(__file__).resolve().parent


def test_jobs_overlaps_independent_legs_and_waits_on_named_dependency():
    # test_run_gates_jobs.sh's own inner budget is `timeout 220` (see its
    # header) against the scheduler's 30s poll granularity; this outer pytest
    # timeout must stay comfortably larger than that inner number, or a slow
    # CI host can make pytest kill a script that was still legitimately
    # running -- not a real test failure. Keep this > the inner 220.
    out = subprocess.run(["bash", str(HERE / "test_run_gates_jobs.sh")],
                         capture_output=True, text=True, timeout=300)
    assert out.returncode == 0, out.stdout + out.stderr
    assert "JOBS_TEST_OK" in out.stdout, out.stdout + out.stderr


def test_run_gates_is_syntactically_valid():
    rg = HERE.parent / "run_gates.sh"
    assert rg.is_file()
    assert subprocess.run(["bash", "-n", str(rg)]).returncode == 0
