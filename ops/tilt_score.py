#!/usr/bin/env python3
"""tilt_score.py <pair.iq | capture dir> [...] -- in-band spectral tilt of a receiver-input I/Q window.

The forward link's carrier-dependent loss is a drifting multipath fade (docs/evidence/link/
FORWARD_LINK_2026-10-01.md sec. 9): the receiver has no equaliser, and a slope of more than ~8-10 dB across the
15.36 Msym/s band breaks it (-14.6 dB = 46 % loss, -10.5 = 2.4 %, |tilt| <= 4.7 dB = clean). This scores any
pair.iq (int16 I,Q interleaved at 61.44 MS/s, the Tap-A receiver-input window every capture_r3.sh leg records):
  tilt_db   straight-line fit of the Welch PSD over |f| < 8 MHz, expressed as dB across 16 MHz (sign = slope)
  dip_db    deepest 1 MHz-smoothed point of the in-band PSD relative to the in-band mean
  verdict   CLEAN (|tilt| < 6 and dip > -6), MARGINAL, or FADED (|tilt| >= 9 or dip <= -8)
--json prints one JSON object per input. Exit 0 always; the verdict is the reading, not a gate.
"""
import json
import os
import sys

import numpy as np

FS = 61.44e6
NFFT = 16384
BAND_HZ = 8e6


def psd(x, nfft=NFFT, fs=FS):
    n = len(x) // nfft * nfft
    if n == 0:
        raise ValueError("window shorter than one FFT")
    X = x[:n].reshape(-1, nfft) * np.blackman(nfft)
    P = np.mean(np.abs(np.fft.fftshift(np.fft.fft(X, axis=1), axes=1)) ** 2, axis=0)
    f = np.fft.fftshift(np.fft.fftfreq(nfft, 1 / fs))
    return f, 10 * np.log10(P + 1e-30)


def score_iq(x, fs=FS):
    f, P = psd(x, fs=fs)
    m = np.abs(f) < BAND_HZ
    slope, _ = np.polyfit(f[m] / 1e6, P[m], 1)          # dB per MHz
    k = max(3, int(round(1e6 / (f[1] - f[0]))))             # 1 MHz smoothing
    sm = np.convolve(P[m], np.ones(k) / k, mode="same")
    core = sm[k // 2:-k // 2] if len(sm) > k else sm
    dip = float(core.min() - core.mean())
    tilt = float(slope * 16.0)
    if abs(tilt) >= 9 or dip <= -8:
        verdict = "FADED"
    elif abs(tilt) < 6 and dip > -6:
        verdict = "CLEAN"
    else:
        verdict = "MARGINAL"
    return dict(tilt_db=round(tilt, 2), dip_db=round(dip, 2), verdict=verdict, samples=int(len(x)))


def load(path):
    p = os.path.join(path, "pair.iq") if os.path.isdir(path) else path
    raw = np.fromfile(p, dtype=np.int16)
    return raw[0::2].astype(np.float64) + 1j * raw[1::2].astype(np.float64)


def main(argv):
    js = "--json" in argv
    paths = [a for a in argv if a != "--json"]
    if not paths:
        print(__doc__); return 2
    for p in paths:
        try:
            r = score_iq(load(p)); r["path"] = p
        except Exception as e:  # noqa: BLE001
            r = dict(path=p, error=str(e), verdict="n/a")
        if js:
            print(json.dumps(r))
        else:
            print(f"{p}: tilt={r.get('tilt_db', 'n/a'):+} dB/16MHz dip={r.get('dip_db', 'n/a')} dB -> {r['verdict']}" if "tilt_db" in r
                  else f"{p}: {r['error']} -> n/a")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
