"""tilt_score.py: a flat band-limited signal scores CLEAN with ~0 tilt; a synthetic one-sided slope of known size
is measured within 1.5 dB and scores FADED past 9 dB; directories resolve to pair.iq; --json."""
import json
import os
import subprocess
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
import tilt_score  # noqa: E402


def _signal(n=2_000_000, seed=1):
    rng = np.random.default_rng(seed)
    # band-limited complex noise: QPSK-like occupancy +-9.6 MHz at 61.44 MS/s
    X = np.zeros(n, dtype=complex)
    f = np.fft.fftfreq(n, 1 / tilt_score.FS)
    m = np.abs(f) < 9.6e6
    X[m] = rng.standard_normal(m.sum()) + 1j * rng.standard_normal(m.sum())
    return np.fft.ifft(X) * 2000, f


def _apply_tilt(x, f, tilt_db):
    X = np.fft.fft(x)
    g = 10 ** ((tilt_db / 16.0) * (f / 1e6) / 20.0)   # amplitude slope: tilt_db across 16 MHz
    return np.fft.ifft(X * g)


def test_flat_is_clean():
    x, _ = _signal()
    r = tilt_score.score_iq(x)
    assert abs(r["tilt_db"]) < 1.0 and r["verdict"] == "CLEAN", r


def test_known_slopes_are_measured():
    x, f = _signal()
    for t in (-5.0, -10.0, -14.0, +8.0):
        r = tilt_score.score_iq(_apply_tilt(x, f, t))
        assert abs(r["tilt_db"] - t) < 1.5, (t, r)
    assert tilt_score.score_iq(_apply_tilt(x, f, -14.0))["verdict"] == "FADED"
    assert tilt_score.score_iq(_apply_tilt(x, f, -5.0))["verdict"] == "CLEAN"


def test_cli_reads_a_capture_dir_and_json(tmp_path):
    x, f = _signal(400_000)
    y = _apply_tilt(x, f, -12.0)
    raw = np.empty(2 * len(y), dtype=np.int16); raw[0::2] = np.real(y); raw[1::2] = np.imag(y)
    (tmp_path / "pair.iq").write_bytes(raw.tobytes())
    r = subprocess.run([sys.executable, os.path.join(os.path.dirname(__file__), "..", "tilt_score.py"), "--json", str(tmp_path)], capture_output=True, text=True)
    j = json.loads(r.stdout.strip().splitlines()[-1])
    assert j["verdict"] == "FADED" and -14 < j["tilt_db"] < -10, j
