"""soak_score.py: pass = zero of every reset layer over >= N h; one re-arm or storm fails; a short
window fails; sentinel recoveries fail; the ratio-free zero count is reported, not gated."""
import os
import subprocess
import sys
import time

OPS = os.path.join(os.path.dirname(__file__), '..')
SS = os.path.join(OPS, 'soak_score.py')


def _wd(tmp_path, name, lines, mtime):
    p = tmp_path / name
    p.write_text("[wd] === STARTING 10:00:00 pid=1 ===\n" + "\n".join(lines) + "\n")
    os.utime(p, (mtime, mtime))
    return str(p)


def _locked(h, m, s, drst=0, dpkt=6240):
    return f"[wd {h:02d}:{m:02d}:{s:02d}] LOCKED (drstcs={drst} dpkts={dpkt} lvl=0)"


def _run(args):
    return subprocess.run([sys.executable, SS] + args, capture_output=True, text=True)


def test_clean_soak_passes_and_reports_denominators(tmp_path):
    end = time.mktime(time.strptime("2026-09-30 06:00", "%Y-%m-%d %H:%M"))
    lines = [_locked(1 + i // 720, (i // 12) % 60, (i % 12) * 5) for i in range(720 * 5)]   # 5 h of 5 s windows
    wd = _wd(tmp_path, "wd146.txt", lines, end)
    sen = tmp_path / "sentinel.log"
    sen.write_text("2026-09-30_02:00:00 ok rate=1245/s crc=100.0% tx=1245/s rev=1868/s rcrc=100.0% rtx=1868/s\n"
                   "2026-09-30_03:00:00 ok rate=1245/s crc=100.0% tx=1245/s rev=1868/s rcrc=100.0% rtx=1868/s\n")
    r = _run(["--since", "2026-09-30 01:00", "--until", "2026-09-30 06:00", "--wd", f"10.0.0.146={wd}", "--sentinel", str(sen)])
    assert r.returncode == 0 and "SOAK_VERDICT PASS" in r.stdout
    assert "windows=3600" in r.stdout and "rearms=0" in r.stdout and "samples=2 zero_rate_or_rev=0 recoveries=0" in r.stdout


def test_one_rearm_or_one_storm_fails(tmp_path):
    end = time.mktime(time.strptime("2026-09-30 06:00", "%Y-%m-%d %H:%M"))
    lines = [_locked(1 + i // 720, (i // 12) % 60, (i % 12) * 5) for i in range(720 * 5)]
    lines[2000] = "[wd 03:46:40] NOT-LOCKED #1/2 (drstcs=5863 dpkts=2638 lvl=0)"
    lines[2001] = "[wd 03:46:45] FULL RE-ARM (0x000 soft reset + re-select + rstCS, double-tap)"
    wd = _wd(tmp_path, "wd146.txt", lines, end)
    r = _run(["--since", "2026-09-30 01:30", "--until", "2026-09-30 06:00", "--wd", f"10.0.0.146={wd}", "--sentinel", str(tmp_path / "none")])
    assert r.returncode == 1 and "storms=1 rearms=1" in r.stdout and "SOAK_VERDICT FAIL" in r.stdout


def test_short_window_fails_even_when_clean(tmp_path):
    end = time.mktime(time.strptime("2026-09-30 06:00", "%Y-%m-%d %H:%M"))
    lines = [_locked(5, (i // 12) % 60, (i % 12) * 5) for i in range(720)]
    wd = _wd(tmp_path, "wd148.txt", lines, end)
    r = _run(["--since", "2026-09-30 05:00", "--until", "2026-09-30 06:00", "--wd", f"10.0.0.148={wd}", "--sentinel", str(tmp_path / "none")])
    assert r.returncode == 1 and "= 1.00 h (need >= 4.0 h)" in r.stdout and "-> OK" in r.stdout
