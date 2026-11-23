"""test_episode_stats.py -- ops/episode_stats.py, the reverse-leg occurrence reader.

Traps this pins, all of which produced a wrong number during the 2026-09-28 study:

  1. The headline statistic must be RATIO-FREE. Every ratio from this log carries the 1.5x
     'high mode' window artefact; counting samples where the receiver delivered EXACTLY zero
     does not. A first pass that used a naive rev/tx ratio reported 40-50 % degraded on days
     the merged availability doc calls healthy.
  2. A leg delivering exactly zero is FALSY. Selecting samples with a truthiness test silently
     drops the worst samples in the log.
  3. A gap in the log must BREAK an episode, not bridge it -- we have no evidence about what
     happened across a sentinel restart, and stitching invents duration.
  4. A zero DENOMINATOR (dead transmitter) is a different fault from a dead receiver and has no
     delivery ratio at all; it must not be counted as a degraded receive sample.
"""
import pathlib
import subprocess
import sys

OPS = pathlib.Path(__file__).resolve().parents[1]
TOOL = OPS / "episode_stats.py"


def ok(t, rate, tx, rev, rtx, day="2026-09-20"):
    return (f"{day}_{t} ok rate={rate}/s crc=100.0% tx={tx}/s "
            f"rev={rev}/s rcrc=100.0% rtx={rtx}/s")


def write(p, lines):
    p.write_text("".join(l + "\n" for l in lines))
    return p


def run(log, *args):
    r = subprocess.run([sys.executable, str(TOOL), "--log", str(log), *args],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    return r.stdout


def test_zero_delivery_samples_are_counted_not_dropped(tmp_path):
    """A leg delivering exactly 0 is the WORST case and is falsy; it must appear in rx==0."""
    log = write(tmp_path / "s.log",
                [ok(f"{h:02d}:00:00", 1245, 1245, 0, 1245) for h in range(10)])
    out = run(log)
    assert " 10      10   100.0" in out or "100.0" in out
    # every sample had rev == 0, so the zero column must be the full count
    line = [l for l in out.splitlines() if l.startswith("2026-09-20")][0]
    assert line.split()[1] == "10" and line.split()[2] == "10"


def test_healthy_log_reports_no_episodes(tmp_path):
    log = write(tmp_path / "s.log",
                [ok(f"{h:02d}:00:00", 1245, 1245, 1245, 1245) for h in range(10)])
    out = run(log)
    seg = out.split("bridging it):")[1].split("\n")[0].strip()
    assert seg == "0", f"a fully healthy log must yield no episodes, got {seg}"


def test_log_gap_breaks_an_episode_rather_than_bridging_it(tmp_path):
    """Two degraded samples an hour apart are TWO events, not one 60-minute event."""
    log = write(tmp_path / "s.log", [ok("01:00:00", 1245, 1245, 0, 1245),
                                     ok("02:00:00", 1245, 1245, 0, 1245)])
    out = run(log)
    seg = out.split("bridging it):")[1].split("\n")[0].strip()
    assert seg == "2", f"expected 2 episodes across a 1 h gap, got {seg}"


def test_dead_transmitter_is_not_scored_as_a_degraded_receiver(tmp_path):
    """rtx == 0 has no delivery ratio; it must not be counted as a degraded reverse sample."""
    log = write(tmp_path / "s.log", [ok(f"{h:02d}:00:00", 1245, 1245, 0, 0) for h in range(5)])
    out = run(log)
    seg = out.split("bridging it):")[1].split("\n")[0].strip()
    assert seg == "0", f"a zero denominator must yield no episodes, got {seg}"


def test_forward_leg_is_selectable_and_independent(tmp_path):
    """--leg fwd must score rate/tx, so a dead REVERSE leg leaves the forward count clean."""
    log = write(tmp_path / "s.log",
                [ok(f"{h:02d}:00:00", 1245, 1245, 0, 1245) for h in range(10)])
    out = run(log, "--leg", "fwd")
    line = [l for l in out.splitlines() if l.startswith("2026-09-20")][0]
    assert line.split()[2] == "0", "forward leg must show no zero-delivery samples here"
