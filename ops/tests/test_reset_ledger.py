"""test_reset_ledger.py -- ops/reset_ledger.py, the who-resets-what ledger.

Traps pinned:
  1. Board clocks are not nemo's (146 reads +5 h). Every line must be anchored to the snapshot
     filename's wall time via its distance from the LAST [wd] line, never read as wall time.
  2. A board-local day wrap inside one snapshot must not send events a day into the future.
  3. LOCKED windows with drstcs>0 are 'resets while decoding' and must be counted separately from
     storms in NOT-LOCKED windows; a re-arm is a re-arm regardless of what preceded it.
  4. Coupling counts a re-arm at most once even if several peer re-arms are within the window.
"""
import datetime as dt
import pathlib
import subprocess
import sys

OPS = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OPS))
import reset_ledger as rl  # noqa: E402


def wd(hms, rest):
    return f"[wd {hms}] {rest}"


def test_anchoring_uses_the_snapshot_wall_time_not_the_board_clock(tmp_path):
    # board clock 5 h ahead: snapshot at 08:59:08 nemo, last wd line reads 13:59:05
    f = tmp_path / "wdlog_10.0.0.146_20260929_085908.txt"
    f.write_text("\n".join([
        "[wd] === STARTING 13:50:00 pid=1 ===",
        wd("13:50:05", "LOCKED (drstcs=0 dpkts=6200 lvl=0)"),
        wd("13:58:55", "NOT-LOCKED #1/2 (drstcs=0 dpkts=0 lvl=0)"),
        wd("13:59:00", "NOT-LOCKED #2/2 (drstcs=0 dpkts=0 lvl=0)"),
        wd("13:59:05", "FULL RE-ARM (0x000 soft reset + re-select + rstCS, double-tap)"),
    ]) + "\n")
    ip, wall, ev, off = rl.load_snapshot(str(f))
    assert ip == "10.0.0.146" and off == 5
    assert ev[-1][0] == dt.datetime(2026, 9, 29, 8, 59, 8)          # last line = snapshot instant
    assert ev[0][0] == dt.datetime(2026, 9, 29, 8, 50, 8)           # 9 min earlier, wall clock
    assert [k for _, k, _, _ in ev] == ["locked", "notlocked", "notlocked", "rearm"]


def test_day_wrap_inside_a_snapshot_is_folded(tmp_path):
    f = tmp_path / "wdlog_10.0.0.148_20260928_001000.txt"
    f.write_text("\n".join([wd("23:59:50", "LOCKED (drstcs=0 dpkts=6200 lvl=0)"),
                            wd("00:00:05", "LOCKED (drstcs=3 dpkts=6100 lvl=0)"),
                            wd("00:10:00", "LOCKED (drstcs=0 dpkts=6200 lvl=0)")]) + "\n")
    _, _, ev, _ = rl.load_snapshot(str(f))
    assert ev[0][0] < ev[1][0] < ev[2][0]
    assert (ev[2][0] - ev[0][0]).total_seconds() == 610


def test_ledger_separates_resets_while_decoding_from_storms():
    t0 = dt.datetime(2026, 9, 29, 10, 0, 0)
    ev = [(t0, "locked", 0, 6200), (t0 + dt.timedelta(seconds=5), "locked", 19, 5100),
          (t0 + dt.timedelta(seconds=10), "notlocked", 340, 12), (t0 + dt.timedelta(seconds=15), "notlocked", 0, 0),
          (t0 + dt.timedelta(seconds=16), "rearm", None, None), (t0 + dt.timedelta(seconds=40), "daemon_dead", None, None)]
    L = rl.ledger(ev)
    c = L[t0]
    assert c["locked"] == 2 and c["locked_with_resets"] == 1 and c["fabric_resets_locked"] == 19
    assert c["notlocked"] == 2 and c["storms"] == 1 and c["fabric_resets_notlocked"] == 340
    assert c["rearms"] == 1 and c["daemon_restarts"] == 1


def test_coupling_counts_each_rearm_once():
    t0 = dt.datetime(2026, 9, 29, 10, 0, 0)
    A = [t0, t0 + dt.timedelta(minutes=10)]
    B = [t0 + dt.timedelta(seconds=20), t0 + dt.timedelta(seconds=40), t0 + dt.timedelta(minutes=30)]
    assert rl.coupling(A, B) == 1      # first A has two B's nearby -> counts once; second A has none
    assert rl.coupling(B, A) == 2


def test_cli_runs_on_a_synthetic_directory(tmp_path):
    (tmp_path / "wdlog_10.0.0.148_20260929_120000.txt").write_text(
        wd("11:59:55", "LOCKED (drstcs=0 dpkts=6200 lvl=0)") + "\n" + wd("12:00:00", "LOCKED (drstcs=2 dpkts=6100 lvl=0)") + "\n")
    (tmp_path / "wdlog_10.0.0.146_20260929_120000.txt").write_text(
        wd("16:59:50", "NOT-LOCKED #2/2 (drstcs=0 dpkts=0 lvl=0)") + "\n" + wd("17:00:00", "FULL RE-ARM (x)") + "\n")
    (tmp_path / "sentinel.log").write_text("2026-09-29_11:30:00 WEDGE detected (rate=1/s) -- recovering\n2026-09-29_11:32:00 recovery chain done\n")
    r = subprocess.run([sys.executable, str(OPS / "reset_ledger.py"), "--wdlog-dir", str(tmp_path),
                        "--sentinel", str(tmp_path / "sentinel.log"), "--coupling"], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert "148:+0" in r.stdout and "146:+5" in r.stdout
    assert "sentinel recoveries: 1 wedge" in r.stdout
    assert "CROSS-BOARD COUPLING" in r.stdout
