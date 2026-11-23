"""test_sentinel_stats.py -- ops/sentinel_stats.py, the delivery-sentinel log reader.

The trap this pins: the sentinel's four counters are TWO per board, and pairing each board's
receive with its own transmit produces a number that looks like a delivery ratio and is not
(rate/tx is 148 rx over 148 tx, and 148's tx feeds the REVERSE leg). A true delivery ratio is
cross-board. Getting this backwards on 2026-09-26 nearly published a wrong comparison.

The second trap: cross-board ratios are only valid when both boards were sampled over the same
window, because the known 'high mode' is exactly 1.5x.
"""
import pathlib
import subprocess
import sys

OPS = pathlib.Path(__file__).resolve().parents[1]
TOOL = OPS / "sentinel_stats.py"


def write_log(p, lines):
    p.write_text("".join(l + "\n" for l in lines))
    return p


def ok(t, rate, crc, tx, rev, rcrc, rtx):
    return (f"2026-09-20_{t} ok rate={rate}/s crc={crc}% tx={tx}/s "
            f"rev={rev}/s rcrc={rcrc}% rtx={rtx}/s")


def run(log, *args):
    return subprocess.run([sys.executable, str(TOOL), "--log", str(log), *args],
                          capture_output=True, text=True)


def test_reverse_delivery_is_cross_board_not_same_board(tmp_path):
    """146 receiving nothing while BOTH transmitters run must show as a reverse collapse, and must
    not be masked by 146's own healthy transmit rate."""
    log = write_log(tmp_path / "s.log", [ok(f"{h:02d}:00:00", 1245, 100.0, 1245, 0, 0.0, 1245)
                                         for h in range(10)])
    r = run(log)
    assert r.returncode == 0, r.stderr
    rev = [l for l in r.stdout.splitlines() if "146 rx / 148 tx" in l][0]
    fwd = [l for l in r.stdout.splitlines() if "148 rx / 146 tx" in l][0]
    assert "med=0.000" in rev, rev          # reverse dead
    assert "med=1.000" in fwd, fwd          # forward untouched


def test_mismatched_window_modes_are_excluded_from_cross_board(tmp_path):
    """tx=1245 against rtx=1868 is the 1.5x window artefact, not a real 0.67 delivery ratio."""
    log = write_log(tmp_path / "s.log", [ok(f"{h:02d}:00:00", 1868, 100.0, 1868, 1245, 100.0, 1245)
                                         for h in range(10)])
    r = run(log)
    assert "both boards in one window mode: 0 samples" in r.stdout
    # the mode-free proxy still reports on all ten
    assert "n=   10" in r.stdout


def test_quiet_filter_drops_samples_near_rig_work(tmp_path):
    log = write_log(tmp_path / "s.log", [
        ok("01:00:00", 1245, 100.0, 1245, 1245, 100.0, 1245),
        "2026-09-20_01:05:00 WEDGE detected (rate=0/s) -- recovering",
        ok("01:10:00", 1245, 100.0, 1245, 0, 0.0, 1245),      # contaminated, must be dropped
        ok("09:00:00", 1245, 100.0, 1245, 1245, 100.0, 1245),
    ])
    r = run(log, "--quiet-s", "1200")
    assert "after dropping those within 1200s" in r.stdout
    line = [l for l in r.stdout.splitlines() if l.startswith("after dropping")][0]
    # 01:00 is only 300 s before the wedge line, so it is contaminated too: only 09:00 survives
    assert line.strip().endswith("1"), line


def test_transmitters_are_reported_during_a_reverse_collapse(tmp_path):
    """The receive-side conclusion rests on the transmitters holding; the tool must print them."""
    log = write_log(tmp_path / "s.log", [ok(f"{h:02d}:00:00", 1245, 100.0, 1245, 10, 5.0, 1245)
                                         for h in range(10)])
    r = run(log)
    assert "146 own tx median 1245/s" in r.stdout and "148 tx median 1245/s" in r.stdout
    assert "RECEIVE-side" in r.stdout


def test_hourly_table_carries_its_own_sample_size_caveat(tmp_path):
    log = write_log(tmp_path / "s.log", [ok(f"{h:02d}:00:00", 1245, 100.0, 1245, 1245, 100.0, 1245)
                                         for h in range(10)])
    r = run(log)
    assert "do not read a diurnal" in r.stdout and "n per hour" in r.stdout


def test_empty_or_unparsable_log_fails_loudly(tmp_path):
    log = write_log(tmp_path / "s.log", ["nonsense", ""])
    r = run(log)
    assert r.returncode == 1 and "no parsable samples" in r.stderr
