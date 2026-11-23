#!/usr/bin/env python3
"""test_check_capture_health.py -- ops/check_capture_health.py is rung-aware (sp4 Task 13 follow-up):
synthetic sqrt-RRC QPSK at 15.36 and 30.72 Msym/s sampled at 61.44 MSPS is HEALTHY when scored at its
own rung and FAILS the bandwidth check at the other; a 256-sample replayed buffer is DEGENERATE at
either rung (envelope periodicity); the r3 window is the historical [15.0, 30.0]."""
import pathlib, subprocess, sys
import numpy as np

OPS = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = OPS / "check_capture_health.py"
FS = 61.44e6


def rrc(beta, span_sym, sps):
    t = np.arange(-span_sym * sps, span_sym * sps + 1) / sps
    h = np.zeros_like(t)
    for i, x in enumerate(t):
        if abs(x) < 1e-9:
            h[i] = 1 - beta + 4 * beta / np.pi
        elif abs(abs(x) - 1 / (4 * beta)) < 1e-9:
            h[i] = beta / np.sqrt(2) * ((1 + 2 / np.pi) * np.sin(np.pi / (4 * beta)) + (1 - 2 / np.pi) * np.cos(np.pi / (4 * beta)))
        else:
            h[i] = (np.sin(np.pi * x * (1 - beta)) + 4 * beta * x * np.cos(np.pi * x * (1 + beta))) / (np.pi * x * (1 - (4 * beta * x) ** 2))
    return h / np.sqrt(np.sum(h ** 2))


def qpsk_iq(ksym, nsamp=1_200_000, seed=1):
    rng = np.random.default_rng(seed)
    sps = int(round(FS / (ksym * 1e3)))
    nsym = nsamp // sps + 16
    sym = (rng.choice([-1, 1], nsym) + 1j * rng.choice([-1, 1], nsym)) / np.sqrt(2)
    up = np.zeros(nsym * sps, complex); up[::sps] = sym
    x = np.convolve(up, rrc(0.5, 8, sps), "same")[:nsamp]
    x += 0.05 * (rng.standard_normal(nsamp) + 1j * rng.standard_normal(nsamp))
    x *= 6000 / np.max(np.abs(x))
    out = np.empty(2 * nsamp, np.int16); out[0::2] = x.real.round(); out[1::2] = x.imag.round()
    return out


def run(path, *args):
    r = subprocess.run([sys.executable, str(SCRIPT), str(path), *args], capture_output=True, text=True)
    return r.returncode, r.stdout


def test_r3_signal_and_window(tmp_path):
    f = tmp_path / "r3.iq"; qpsk_iq(15360).tofile(f)
    rc, out = run(f)                       # default = f1536 / 15360
    assert rc == 0 and "HEALTHY" in out and "[15.0..30.0]" in out, out
    rc, out = run(f, "--ksym", "30720")    # scored at the wrong rung -> bandwidth fails
    assert rc == 1 and "occupied BW" in out and "-> FAIL" in out and "[30.0..59.9]" in out, out


def test_r4_signal_and_window(tmp_path):
    f = tmp_path / "r4.iq"; qpsk_iq(30720).tofile(f)
    rc, out = run(f, "--ksym", "30720")
    assert rc == 0 and "HEALTHY" in out and "expected ~46.08 MHz" in out, out
    rc, out = run(f, "--frame", "f3072")
    assert rc == 0 and "HEALTHY" in out, out
    rc, out = run(f)                       # the r3 window rejects a 46 MHz signal
    assert rc == 1 and "-> FAIL" in out, out


def test_stale_replay_is_degenerate_at_both_rungs(tmp_path):
    rng = np.random.default_rng(3)
    blk = qpsk_iq(15360, nsamp=256, seed=5)
    rep = np.tile(blk, 4000)               # a 256-sample buffer replayed
    f = tmp_path / "stale.iq"; rep.tofile(f)
    for args in ((), ("--ksym", "30720")):
        rc, out = run(f, *args)
        assert rc == 1 and "env periodicity" in out and "stale-DDR-replay" in out, out


def beatobs_stream(nsamp=300_000, sps=4, seed=7):
    """A synthetic beatobs packing: push/pop counters advancing, fill = push - pop, RH phase mod sps."""
    rng = np.random.default_rng(seed)
    push = np.cumsum(rng.random(nsamp) < 1 / sps).astype(np.int64)
    pop = np.cumsum(np.roll(rng.random(nsamp) < 1 / sps, 8)).astype(np.int64)
    fill = (push - pop) & 0xFF
    rhc = np.arange(nsamp) % sps
    I = (fill << 8) | (rhc << 5) | (rng.integers(0, 2, nsamp) << 3) | (1 << 2) | (rng.integers(0, 2, nsamp))
    Q = ((pop & 0xFF) << 8) | (push & 0xFF)
    out = np.empty(2 * nsamp, np.uint16); out[0::2] = I & 0xFFFF; out[1::2] = Q & 0xFFFF
    return out


def test_beatobs_vector_is_named_not_called_stale_replay(tmp_path):
    f = tmp_path / "bo.iq"; beatobs_stream(sps=2).tofile(f)
    rc, out = run(f, "--ksym", "30720")
    assert rc == 1 and "VERDICT: BEATOBS" in out and "sps 2" in out, out
    assert "stale-DDR-replay" not in out
    f4 = tmp_path / "bo4.iq"; beatobs_stream(sps=4).tofile(f4)
    rc, out = run(f4)
    assert rc == 1 and "VERDICT: BEATOBS" in out and "sps 4" in out, out


def test_real_iq_is_not_flagged_as_beatobs(tmp_path):
    f = tmp_path / "r3.iq"; qpsk_iq(15360).tofile(f)
    rc, out = run(f)
    assert rc == 0 and "BEATOBS" not in out, out
