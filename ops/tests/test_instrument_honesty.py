#!/usr/bin/env python3
"""test_instrument_honesty.py -- plan 2026-09-25-rig-instability Task 7 (I6).

An instrument must be able to say it does not know. Three failures this month came from scorers
that returned a confident answer for input they could not actually score:
  * check_capture_health.py called five weeks of live beat-observer telemetry a "stale DMA replay,
    REBOOT-ONLY" (fixed 2026-09-23; this test keeps it fixed),
  * the one-way byte scorer printed BER=0.000e+00 having aligned ZERO frames, on the worst leg of
    the 2026-09-25 run,
  * a blind spectral SNR proxy ranked the 7.9 % arms above the 0.05 % ones (discarded, never shipped).

Each scorer is fed (a) its intended input, (b) a DIFFERENT valid signal class, (c) noise.
"""
import os
import pathlib
import subprocess
import sys

import numpy as np
import pytest

OPS = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OPS))
from frame_taxonomy import DTYPE  # noqa: E402

HEALTH = OPS / "check_capture_health.py"
SCORE = OPS / "score_leg.py"
FS = 61.44e6


def _rrc_qpsk(ksym, nsamp=600_000, seed=1):
    rng = np.random.default_rng(seed)
    sps = int(round(FS / (ksym * 1e3)))
    sym = (rng.choice([-1, 1], nsamp // sps + 8) + 1j * rng.choice([-1, 1], nsamp // sps + 8))
    up = np.zeros((nsamp // sps + 8) * sps, complex); up[::sps] = sym
    h = np.ones(sps) / sps
    x = np.convolve(up, h, "same")[:nsamp] * 4000
    out = np.empty(2 * nsamp, np.int16); out[0::2] = x.real; out[1::2] = x.imag
    return out


def _frames(n=1000, monotonic=True, crc_binary=True, span_ns=801_888):
    fr = np.zeros(n, dtype=DTYPE)
    t = np.arange(n) * span_ns
    if not monotonic:
        t = t[::-1]
    fr["t_mono_ns"] = t.astype(np.uint64)
    fr["crc_ok"] = (np.arange(n) % 2) if crc_binary else np.arange(n) + 7
    fr["reg_packets"] = np.arange(n)
    fr["reg_rstcs"] = 0
    return fr


# ---------------------------------------------------------------- check_capture_health.py
def test_health_names_beatobs_rather_than_calling_it_a_dead_dma(tmp_path):
    """(b) a different VALID signal class: the beat-observer state vector."""
    n = 300_000
    rng = np.random.default_rng(3)
    push = np.cumsum(rng.random(n) < 0.5).astype(np.int64)
    pop = np.cumsum(np.roll(rng.random(n) < 0.5, 8)).astype(np.int64)
    I = (((push - pop) & 0xFF) << 8) | ((np.arange(n) % 4) << 5) | 4
    Q = ((pop & 0xFF) << 8) | (push & 0xFF)
    out = np.empty(2 * n, np.uint16); out[0::2] = I & 0xFFFF; out[1::2] = Q & 0xFFFF
    f = tmp_path / "bo.iq"; out.tofile(f)
    r = subprocess.run([sys.executable, str(HEALTH), str(f)], capture_output=True, text=True)
    assert "BEATOBS" in r.stdout, r.stdout
    assert "stale-DDR-replay" not in r.stdout, "must not assert a DMA fault for live telemetry"


def test_health_accepts_its_intended_input(tmp_path):
    f = tmp_path / "r3.iq"; _rrc_qpsk(15360).tofile(f)
    r = subprocess.run([sys.executable, str(HEALTH), str(f)], capture_output=True, text=True)
    assert "VERDICT:" in r.stdout


def test_health_on_noise_does_not_claim_the_modem_signal(tmp_path):
    rng = np.random.default_rng(5)
    f = tmp_path / "noise.iq"
    (rng.integers(-2000, 2000, 1_200_000)).astype(np.int16).tofile(f)
    r = subprocess.run([sys.executable, str(HEALTH), str(f)], capture_output=True, text=True)
    assert "HEALTHY -- capture contains the modem signal" not in r.stdout, r.stdout


# ---------------------------------------------------------------- score_leg.py
def test_score_leg_scores_its_intended_input(tmp_path):
    d = tmp_path / "leg"; d.mkdir(); _frames().tofile(d / "frames.bin")
    r = subprocess.run([sys.executable, str(SCORE), str(d)], capture_output=True, text=True)
    assert r.returncode == 0 and "crc_ok=" in r.stdout and "UNKNOWN" not in r.stdout


@pytest.mark.parametrize("bad,label", [
    (dict(monotonic=False), "non-monotonic time"),
    (dict(crc_binary=False), "crc_ok not 0/1"),
])
def test_score_leg_says_unknown_for_implausible_records(tmp_path, bad, label):
    d = tmp_path / "leg"; d.mkdir(); _frames(**bad).tofile(d / "frames.bin")
    r = subprocess.run([sys.executable, str(SCORE), str(d)], capture_output=True, text=True)
    assert r.returncode == 0 and "UNKNOWN" in r.stdout, f"{label}: {r.stdout}"


def test_score_leg_says_unknown_for_noise(tmp_path):
    """(c) noise: 48-byte records parse out of any file, so the scorer must not be fooled."""
    d = tmp_path / "leg"; d.mkdir()
    np.random.default_rng(9).integers(0, 255, 48 * 500, dtype=np.uint8).tofile(d / "frames.bin")
    r = subprocess.run([sys.executable, str(SCORE), str(d)], capture_output=True, text=True)
    assert "UNKNOWN" in r.stdout, r.stdout


# ---------------------------------------------------------------- one-way byte scorer
def test_oneway_measure_reports_unknown_on_a_zero_denominator():
    s = (OPS / "oneway_measure.sh").read_text()
    assert "BER=UNKNOWN(aligned=" in s
    blk = s[s.index("ZERO-DENOMINATOR GUARD"):]
    assert 'BITS:-0}" -le 0' in blk and 'ALIGNED:-0}" -le 0' in blk
