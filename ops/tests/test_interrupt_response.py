"""test_interrupt_response.py -- ops/interrupt_response.sh and its scorer.

The experiment pauses the PEER's daemon (SIGSTOP/SIGCONT) and watches the receiver; it must never
write a modem register, must never run without an output directory, must alternate pause lengths,
and its cleanup must relaunch the watchdogs WITH DAEMON_CMD -- a bare relaunch cannot recover a
byte-plane wedge and loops 0x000 re-arms (2026-09-29). The scorer treats both boards' epoch stamps
as one clock: the first version 'aligned' them and scored every window in the wrong place.
"""
import os
import pathlib
import re
import subprocess
import sys

OPS = pathlib.Path(__file__).resolve().parents[1]
TOOL = OPS / "interrupt_response.sh"
SCORE = OPS / "interrupt_response_score.py"


def test_dry_run_alternates_lengths_and_touches_nothing(tmp_path):
    env = dict(os.environ, DRY="1", OUT=str(tmp_path / "o"), LENS_MS="20 500", REPS="2")
    r = subprocess.run(["bash", str(TOOL)], capture_output=True, text=True, env=env)
    assert r.returncode == 0, r.stderr
    lens = re.findall(r"len (\d+)ms", r.stdout)
    assert lens == ["20", "500", "20", "500"], lens
    assert "INTERRUPT_RESPONSE_DRY_OK" in r.stdout


def test_out_is_mandatory():
    env = {k: v for k, v in os.environ.items() if k != "OUT"}
    r = subprocess.run(["bash", str(TOOL)], capture_output=True, text=True, env=env)
    assert r.returncode != 0 and "OUT" in r.stderr


def test_no_register_writes_and_cleanup_carries_daemon_cmd():
    src = TOOL.read_text()
    code = "\n".join(l for l in src.splitlines() if not l.lstrip().startswith("#"))
    # the only DRA use is the read-only poller: no 'echo "0x... 0x..." >' write form anywhere
    assert not re.search(r'echo\s+"0x[0-9A-Fa-f]+\s+0x[0-9A-Fa-f]+"\s*>', code), "a register WRITE crept in"
    assert "DAEMON_CMD=" in code and "lock_watchdog.sh" in code, "cleanup must relaunch watchdogs with DAEMON_CMD"


def test_scorer_uses_epoch_stamps_without_alignment(tmp_path):
    run = tmp_path / "r"; run.mkdir()
    t0 = 1790000000.0
    rows = []
    # 40 s locked at 1245 f/s, then a pause at t0+40 followed by a storm: half rate, 1200 resets/s
    p = r = 0
    for i in range(100):
        t = t0 + i
        if i < 40:
            p += 1245
        else:
            p += 630; r += 1200
        rows.append(f"{t:.3f},{p:#x},{r:#x},{(-4400 if i < 40 else 90000) & 0xFFFFFFFF:#x}")
    (run / "rx_poll.csv").write_text("\n".join(rows) + "\n")
    (run / "reps.tsv").write_text("rep\tlen_ms\tt_stop_epoch\tt_cont_epoch\tcsv\n" f"1\t20\t{t0+40:.3f}\t{t0+40.02:.3f}\trx_poll.csv\n")
    out = subprocess.run([sys.executable, str(SCORE), str(run)], capture_output=True, text=True)
    assert out.returncode == 0, out.stderr
    assert "offset applied: +0.0 s" in out.stdout
    line = [l for l in out.stdout.splitlines() if l.strip().startswith("1 ")][0]
    f = line.split()
    assert f[2] == "1245", line          # detection BEFORE the pause read at the right place
    assert f[5] == "nan", line           # never recovered
