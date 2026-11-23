"""test_decay_and_margin.py -- ops/decay_watch.sh and ops/margin_cells.sh.

Both tools exist because of one 2026-09-28 lesson: on this leg, every statistic that is measured
ONCE after an arm is measuring time-since-the-arm, not the thing you changed. An interleaved
ROM-vs-byte test read 1241 / 976 / 715 f/s in cell order and looked like source dependence; it was
the clock. So these tools (a) always carry a simultaneous control, and (b) always alternate plans.

The traps pinned here:
  1. A tool that arms boards must never be runnable without an output directory -- an unattended
     arm whose data lands nowhere is pure risk.
  2. margin_cells must ALTERNATE, not run the default cells then the corrected ones.
  3. Both LO plans must stay inside the band the bring-up will accept (1.8-2.2 GHz), or the run
     burns arms and exits.
  4. Scoring must filter torn direct_reg_access reads, or one 2^31 value destroys a median.
"""
import os
import pathlib
import re
import subprocess

OPS = pathlib.Path(__file__).resolve().parents[1]
DECAY = OPS / "decay_watch.sh"
MARGIN = OPS / "margin_cells.sh"


def test_both_tools_are_executable_shell():
    for t in (DECAY, MARGIN):
        assert t.exists(), t
        assert os.access(t, os.X_OK), f"{t} not executable"
        r = subprocess.run(["bash", "-n", str(t)], capture_output=True, text=True)
        assert r.returncode == 0, r.stderr


def test_neither_tool_runs_without_an_output_directory():
    """Trap 1: OUT is mandatory -- an arm whose data lands nowhere is risk with no return."""
    for t in (DECAY, MARGIN):
        env = {k: v for k, v in os.environ.items() if k != "OUT"}
        r = subprocess.run(["bash", str(t)], capture_output=True, text=True, env=env)
        assert r.returncode != 0, f"{t.name} ran without OUT"
        assert "OUT" in r.stderr


def test_margin_cells_alternates_its_two_plans():
    """Trap 2: the plan must be chosen from the cell index, not run in blocks."""
    src = MARGIN.read_text()
    m = re.search(r"case \$\(\( i % 2 \)\) in(.+?)esac", src, re.S)
    assert m, "margin_cells.sh no longer selects its plan from the cell index"
    body = m.group(1)
    assert "default" in body and "corrected" in body


def test_both_margin_plans_are_inside_the_bringup_band():
    """Trap 3: the bring-up refuses anything outside 1.8-2.2 GHz, after burning nothing."""
    src = MARGIN.read_text()
    los = [int(v) for v in re.findall(r"_LO:-(\d+)\}", src)]
    assert len(los) == 2, f"expected two default LO values, found {los}"
    for lo in los:
        assert 1_800_000_000 <= lo <= 2_200_000_000, lo
    assert los[0] != los[1], "the two plans must differ"


def test_corrected_plan_moves_the_receiver_up_not_down():
    """The measured transmit offset is POSITIVE (+42.6 kHz), so the correction raises the RX LO."""
    src = MARGIN.read_text()
    los = [int(v) for v in re.findall(r"_LO:-(\d+)\}", src)]
    default, corrected = los
    assert corrected > default, "correcting a positive TX offset must RAISE the receiver LO"
    assert 20_000 <= corrected - default <= 80_000, corrected - default


def test_scoring_filters_torn_register_reads():
    """Trap 4: one 2^31 sample destroys a median; both tools document and apply a ceiling."""
    for t in (DECAY, MARGIN):
        src = t.read_text()
        assert "3000" in src or "1<<20" in src or "2^20" in src, f"{t.name} has no read ceiling"


def test_decay_watch_polls_both_boards():
    """The control leg is the whole design; a single-board poll cannot attribute a decay."""
    src = DECAY.read_text()
    assert "10.0.0.148" in src and "10.0.0.146" in src
    assert src.count("poll ") >= 2, "decay_watch must poll both boards"
