#!/usr/bin/env python3
"""test_score_leg.py -- ops/score_leg.py on a synthetic frames.bin (frame_taxonomy.DTYPE records)."""
import pathlib, subprocess, sys
import numpy as np

OPS = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OPS))
from frame_taxonomy import DTYPE  # noqa: E402


def test_score_leg_line(tmp_path):
    n = 2000
    fr = np.zeros(n, dtype=DTYPE)
    fr["t_mono_ns"] = (np.arange(n) * 801_888).astype(np.uint64)       # 0.8 ms frames
    fr["host_seq"] = np.arange(n)
    fr["crc_ok"] = (np.arange(n) % 10 != 0).astype(fr["crc_ok"].dtype)  # 90 % ok
    fr["reg_packets"] = 1000 + np.arange(n)
    fr["reg_rstcs"] = 500 + np.arange(n) // 5                          # one reset per 5 frames
    fr["reg_cfc"] = np.uint32((-5000) & 0xFFFFFFFF)                     # negative, sign-extended
    d = tmp_path / "leg"; d.mkdir(); fr.tofile(d / "frames.bin")
    (d / "meta.txt").write_text("wedge_verdict=MID_CAPTURE_WEDGE after 9s\n")
    r = subprocess.run([sys.executable, str(OPS / "score_leg.py"), str(d)], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    line = r.stdout.strip()
    assert line.startswith("leg: n=2000 ") and "crc_ok=90.00%" in line and "cfc_med=-5000" in line, line
    assert "rstcs/s=249" in line and "detected/s=1247" in line and line.endswith("WEDGED"), line


def test_score_leg_no_frames(tmp_path):
    r = subprocess.run([sys.executable, str(OPS / "score_leg.py"), str(tmp_path)], capture_output=True, text=True)
    assert r.returncode == 0 and "NO frames.bin" in r.stdout
