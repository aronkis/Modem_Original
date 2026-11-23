#!/usr/bin/env python3
"""test_wedge_forensics.py -- plan Task 5: the wedge classifier runs on a synthetic capture tree
and reports the fabric's behaviour across the flatline. NO BOARD CONTACT."""
import pathlib
import subprocess
import sys

import numpy as np

OPS = pathlib.Path(__file__).resolve().parents[1]
TOOL = OPS / "wedge_forensics.py"
sys.path.insert(0, str(OPS))
from frame_taxonomy import DTYPE  # noqa: E402


def _leg(root, name, wedged, pkts_pre, pkts_post, rst_pre, rst_post, t0=1790295572.0, span=450.0):
    d = root / name; d.mkdir(parents=True)
    (d / "regs_pre.txt").write_text(
        f"t={t0:.6f} pkts={pkts_pre:#x} biterr=0x1 rstcs={rst_pre:#x} cfc=0x0 fx=0x0\n")
    (d / "regs_post.txt").write_text(
        f"t={t0 + span:.6f} pkts={pkts_post:#x} biterr=0x2 rstcs={rst_post:#x} cfc=0x0 fx=0x0\n")
    n = 1000
    fr = np.zeros(n, dtype=DTYPE)
    fr["t_real_ns"] = ((t0 + np.linspace(0, span - 20, n)) * 1e9).astype(np.uint64)
    fr["t_mono_ns"] = (np.arange(n) * 801888).astype(np.uint64)
    fr.tofile(d / "frames.bin")
    out = [f"CAP_START t={t0 + 5:.6f} pkts=0x1 biterr=0x1 rstcs=0x0 cfc=0x0",
           f"  ROTATE_RX ip=10.0.0.146 board_t={t0 - 3:.6f} host_t={t0 - 3:.6f} iso=x"]
    if wedged:
        out += ["    !! delivery stalled 5s (+0 frames in 5s) at 430s",
                "CAPTURE_ABORTED_WEDGED: MID_CAPTURE_WEDGE after 449s wall"]
    (d / "capture.out").write_text("\n".join(out) + "\n")
    (d / "qpsk_tun_peer.log").write_text("qpsk_tun stats: dma_tx=100\nqpsk_tun stats: dma_tx=200\n")


def test_reports_fabric_still_detecting_through_a_wedge(tmp_path):
    # 450 s at ~1200 detections/s with no new carrier resets, host delivery stops 20 s early
    _leg(tmp_path, "rev600", True, 0x1000, 0x1000 + 540000, 0, 0)
    _leg(tmp_path, "rev180_2", False, 0x1000, 0x1000 + 540000, 0, 0)
    r = subprocess.run([sys.executable, str(TOOL), str(tmp_path)], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "rev600" in r.stdout and "YES" in r.stdout
    assert "1200" in r.stdout, "must report the detection rate across the flatline"
    assert "WEDGED" in r.stdout and "clean" in r.stdout
    assert "wedge onset within 20 s of the Tap-A window: 0 of 1" in r.stdout


def test_tap_coincidence_is_counted_when_it_does_coincide(tmp_path):
    d = tmp_path / "legX"
    _leg(tmp_path, "legX", True, 0x1000, 0x1000 + 100, 0, 0)
    # move the stall onset next to the tap window (tap is at +5 s of a 450 s leg)
    c = (d / "capture.out").read_text().replace("at 430s", "at 6s")
    (d / "capture.out").write_text(c)
    r = subprocess.run([sys.executable, str(TOOL), str(tmp_path)], capture_output=True, text=True)
    assert "wedge onset within 20 s of the Tap-A window: 1 of 1" in r.stdout, r.stdout


def test_capture_rail_now_snapshots_the_byte_word_counter():
    """0x1C0 is the discriminator between a fabric-ring stall and a host-drain stall, and it was
    the one register the 2026-09-24 snapshots lacked."""
    s = (OPS / "capture_r3.sh").read_text()
    assert "bytewords=$(rd 0x1C0)" in s


def test_stall_poll_samples_the_byte_word_counter_during_the_flatline():
    """WEDGE_CLASS.md sec 4: fabric-ring vs host-drain cannot be settled by bracketing snapshots,
    because a pre/post delta mixes the healthy minutes with the 16 s stall. The stall poll itself
    must carry 0x1C0 and 0x104."""
    s = (OPS / "capture_r3.sh").read_text()
    blk = s[s.index("delivery stalled ${STALL}s") - 1200:s.index("delivery stalled ${STALL}s") + 200]
    assert "STALL_REGS" in blk and "0x1C0" in blk and "0x104" in blk, blk[-400:]

