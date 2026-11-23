"""soak_pair.sh: incremental soak verdicts from files (plan Phase 5). DRY=1 touches no board and scores
the newest snapshots; every tick appends a SOAK_VERDICT block to status.txt; a FAIL does not stop it."""
import os
import subprocess
import time

OPS = os.path.join(os.path.dirname(__file__), '..')


def test_dry_run_scores_existing_snapshots_and_writes_status(tmp_path):
    home = tmp_path / "home"; ms = home / "modem-status"; ms.mkdir(parents=True)
    end = time.mktime(time.strptime("2026-09-30 06:00", "%Y-%m-%d %H:%M"))
    for ip in ("10.0.0.146", "10.0.0.148"):
        p = ms / f"wdlog_{ip}_20260930_0600.txt"
        lines = ["[wd] === STARTING 01:00:00 pid=1 ==="] + [f"[wd {1 + i // 720:02d}:{(i // 12) % 60:02d}:{(i % 12) * 5:02d}] LOCKED (drstcs=0 dpkts=6240 lvl=0)" for i in range(720 * 5)]
        if ip == "10.0.0.148":
            lines[2001] = "[wd 03:46:45] FULL RE-ARM (0x000 soft reset + re-select + rstCS, double-tap)"
        p.write_text("\n".join(lines) + "\n"); os.utime(p, (end, end))
    (ms / "sentinel.log").write_text("2026-09-30_03:00:00 ok rate=1245/s crc=100.0% tx=1245/s rev=1868/s rcrc=100.0% rtx=1868/s\n")
    out = tmp_path / "soak"
    r = subprocess.run(["bash", os.path.join(OPS, "soak_pair.sh")], capture_output=True, text=True,
                       env=dict(os.environ, HOME=str(home), DRY="1", HOURS="4", SINCE="2026-09-30 01:00", OUT=str(out)))
    assert r.returncode == 0, r.stderr
    st = (out / "status.txt").read_text()
    assert "SOAK_PAIR start" in st and "--- tick 1" in st and "SOAK_PAIR_DONE ticks=1 verdict=FAIL" in st
    assert "10.0.0.146: windows=3600" in st and "-> OK" in st
    assert "10.0.0.148:" in st and "rearms=1" in st and "-> FAIL" in st


def test_script_never_reads_a_register():
    s = open(os.path.join(OPS, "soak_pair.sh")).read()
    code = "\n".join(l for l in s.splitlines() if not l.lstrip().startswith("#"))
    assert "direct_reg_access" not in code and "0x1" not in code and "rigprobe" not in code
    assert "cat /dev/shm/watchdog.log" in code
