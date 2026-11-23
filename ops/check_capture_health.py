#!/usr/bin/env python3
"""check_capture_health.py <pair.iq> -- is this IQ capture the modem signal, or garbage?

WHY THIS EXISTS (2026-08-24). An entire investigation -- three offline instruments, two of
them wrongly retired, one real bug found and fixed -- was spent debugging receivers that
were being fed captures which did not contain the modem signal at all. The IQ capture DMA
was in the #48 stale-DDR-replay state: it returned a stale ~256-sample buffer on every
read while the modem's own datapath ran normally at 1243 f/s framesync, so every
board-side health check passed.

The decisive tell needed no receiver and no new run: two captures taken FOUR HOURS APART,
in DIFFERENT transmit modes, cross-correlated at 0.9986. Live RX data cannot do that.

Two checks, both cheap, both against a reference that was sitting in the repo the whole
time (ops/r3cap/singles_reread/pair.iq, Aug-12, decoded 12/12 CRC-good):

  1. OCCUPIED BANDWIDTH. QPSK with sqrt-RRC beta=0.5 at Rsym=15.36 Msym/s occupies
     ~23 MHz. Measured on the good reference: 22.16 MHz. Measured on every wedged
     capture: 2.88 MHz -- exactly 1/8, and not a subtle difference.
  2. ENVELOPE PERIODICITY. A real signal's envelope autocorrelation at lag>200 sits
     around 0.5. A replayed buffer spikes to ~0.999 at its replay period (256 samples
     observed). This is what catches stale replay specifically.

Run this on EVERY capture before drawing any conclusion from it. Exit 0 = healthy,
1 = degenerate, 2 = usage/read error.

BEATOBS (2026-09-23, the "what broke the tap" finding): since the BEATOBS build kit (commit 5d156154,
2026-08-20) every production image is assembled with QPSK_BEATOBS=1 (modem/build_hdl.sh exports it),
and beatobs_overlay.m REPURPOSES the composite debugI1/debugQ1 outports -- 'IP Data 0/1 OUT', i.e. the
rx1 IIO DMA channel voltage0 that this tap reads -- as a packed Rate-Handle state vector
(I[0] demod dataOut, I[1] startOut, I[2] validOut, I[4:3] decision, I[6:5] RH counter phase,
I[15:8] FIFO fill = push-pop, Q[7:0] push counter, Q[15:8] pop counter). So the tap is NOT stale
DMA replay: it is a live, cycle-resolved telemetry stream, and it has looked "degenerate" to the two
checks above on every capture since then (last HEALTHY tap: image e49c011b of 2026-08-13,
SINGLES_CAMPAIGN.md). This tool now DETECTS the vector (fill == push-pop consistency, ~70 % on a
real beatobs stream vs < 1 % on IQ) and names it, with a one-line decode, before the IQ checks.

RUNG-AWARE (sp4, 2026-09-22): the bandwidth window scales with the symbol rate. The expected
occupied bandwidth is (1 + beta) * Rsym with beta = 0.5 (sqrt-RRC), and the window is
0.65x .. 1.3x of that, capped at the tap's sample rate: 15.36 Msym/s (r3, f1536) -> 23 MHz,
window [15.0, 30.0] (exactly the historical window); 30.72 Msym/s (r4, f3072) -> 46 MHz,
window [30.0, 60.0]. Pass `--ksym 30720` (capture_r3.sh passes the rung's KSYM), or
`--frame f3072` / QPSK_FRAME=f3072; default = 15360 (f1536). The envelope-periodicity check
is rung-independent (a replayed buffer repeats at its DMA period, not the frame).
"""
import argparse
import os
import sys
import numpy as np

FS_HZ = 61.44e6          # tap sample rate
RRC_BETA = 0.5
KSYM_BY_FRAME = {"f1536": 15360, "f3072": 30720}
ENV_CORR_MAX = 0.90      # good reference 0.52; wedged 0.9994
MIN_LAG = 200            # ignore the pulse-shaping correlation at small lags


def bw_window_mhz(ksym):
    """[min, max] occupied-bandwidth window for a symbol rate in ksym/s (see the header)."""
    exp = (1.0 + RRC_BETA) * ksym * 1e3 / 1e6
    return round(0.65 * exp, 1), round(min(1.3 * exp, FS_HZ / 1e6), 1), round(exp, 2)


def load(path, nmax=4_000_000):
    raw = np.fromfile(path, dtype=np.int16, count=2 * nmax)
    if raw.size < 4:
        raise ValueError(f"{path}: too few samples ({raw.size})")
    iq = raw[0::2].astype(np.float64) + 1j * raw[1::2].astype(np.float64)
    r = np.sqrt(np.mean(np.abs(iq) ** 2))
    return iq / r if r > 0 else iq


def occupied_bw_mhz(iq, nfft=65536, nblk=14):
    w = np.hanning(nfft)
    nblk = min(nblk, len(iq) // nfft)
    if nblk < 1:
        raise ValueError("capture too short for a spectrum estimate")
    p = np.zeros(nfft)
    for j in range(nblk):
        seg = iq[j * nfft:(j + 1) * nfft] * w
        p += np.abs(np.fft.fftshift(np.fft.fft(seg))) ** 2
    p /= p.max()
    f = (np.arange(nfft) - nfft // 2) * (FS_HZ / nfft)
    occ = f[p > 0.01]                       # -20 dB
    return (occ.max() - occ.min()) / 1e6


def env_periodicity(iq, nmax=500_000, maxlag=3000):
    e = np.abs(iq[:min(nmax, len(iq))])
    e = e - e.mean()
    n = len(e)
    # normalised autocorrelation via FFT
    nf = 1 << int(np.ceil(np.log2(2 * n)))
    E = np.fft.fft(e, nf)
    ac = np.real(np.fft.ifft(E * np.conj(E)))[:maxlag + 1]
    ac /= ac[0]
    lag = int(np.argmax(ac[MIN_LAG:])) + MIN_LAG
    return lag, float(ac[lag])


def beatobs_detect(path, nmax=1 << 18):
    """Return (consistency, summary) for the beatobs packing; consistency ~0.7 on a beatobs stream,
    ~0.004 on IQ. Uses the raw uint16 words (the packing is unsigned)."""
    x = np.fromfile(path, dtype=np.uint16, count=2 * nmax)
    if x.size < 4096:
        return 0.0, ""
    I = x[0::2].astype(np.int64); Q = x[1::2].astype(np.int64)
    fill = (I >> 8) & 0xFF; push = Q & 0xFF; pop = (Q >> 8) & 0xFF
    cons = float((((push - pop) & 0xFF) == fill).mean())
    rhc = np.bincount((I >> 5) & 3, minlength=4)
    phases = int((rhc > 0.01 * rhc.sum()).sum())
    valid = float(((I >> 2) & 1).mean()); start = int(((I >> 1) & 1).sum())
    span = I.size / FS_HZ
    summary = (f"RH counter phases used={phases} (=> sps {phases}), demod valid duty={valid:.3f}, "
               f"start pulses/s={start / span:.0f}, FIFO fill median={int(np.median(fill))} range [{fill.min()},{fill.max()}]")
    return cons, summary


BEATOBS_MIN_CONSISTENCY = 0.30


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("path")
    ap.add_argument("--ksym", type=int, default=None, help="symbol rate in ksym/s (15360 = f1536/r3, 30720 = f3072/r4)")
    ap.add_argument("--frame", default=None, choices=sorted(KSYM_BY_FRAME), help="frame geometry instead of --ksym (or QPSK_FRAME env)")
    a = ap.parse_args()
    path = a.path
    ksym = a.ksym or KSYM_BY_FRAME[a.frame or os.environ.get("QPSK_FRAME", "f1536")]
    BW_MIN_MHZ, BW_MAX_MHZ, bw_exp = bw_window_mhz(ksym)
    try:
        bo_cons, bo_summary = beatobs_detect(path)
        iq = load(path)
        bw = occupied_bw_mhz(iq)
        lag, corr = env_periodicity(iq)
    except Exception as exc:                       # noqa: BLE001 - report, do not mask
        print(f"CAPTURE_HEALTH ERROR {path}: {exc}")
        return 2
    if bo_cons >= BEATOBS_MIN_CONSISTENCY:
        print(f"CAPTURE_HEALTH {path}")
        print(f"  beatobs packing   = {bo_cons * 100:5.1f} % of samples satisfy fill == push - pop (IQ: < 1 %)")
        print(f"  VERDICT: BEATOBS -- Tap-A carries the beat-observer STATE VECTOR, not IQ (the image was built with "
              f"QPSK_BEATOBS=1, beatobs_overlay.m rewires debugI1/Q1 = IP Data 0/1 OUT = this DMA channel).")
        print(f"  decode: {bo_summary}")
        print("  This is a live telemetry stream, not stale DMA replay; the IQ checks below are meaningless for it. "
              "To get IQ back, build without QPSK_BEATOBS (modem/build_hdl.sh) and re-run the gates.")
        return 1

    bw_ok = BW_MIN_MHZ <= bw <= BW_MAX_MHZ
    env_ok = corr < ENV_CORR_MAX
    ok = bw_ok and env_ok

    print(f"CAPTURE_HEALTH {path}  (ksym={ksym}, expected ~{bw_exp} MHz)")
    print(f"  occupied BW      = {bw:6.2f} MHz   "
          f"[{BW_MIN_MHZ}..{BW_MAX_MHZ}] -> {'OK' if bw_ok else 'FAIL'}"
          f"   (r3 good ref 22.16, wedged 2.88)")
    print(f"  env periodicity  = {corr:6.4f} at lag {lag:5d}   "
          f"< {ENV_CORR_MAX} -> {'OK' if env_ok else 'FAIL'}"
          f"   (good ref 0.52, wedged 0.9994)")
    if ok:
        print("  VERDICT: HEALTHY -- capture contains the modem signal.")
        return 0
    print("  VERDICT: DEGENERATE -- DO NOT draw conclusions from this capture.")
    if not env_ok:
        print(f"  A near-unity envelope autocorrelation at lag {lag} is the #48 "
              "stale-DDR-replay signature: the DMA is returning a stale buffer.")
        print("  Recovery for that class is REBOOT-ONLY -- a full bring-up restore "
              "does not clear it (verified 2026-08-24).")
    if not bw_ok:
        print(f"  Bandwidth far from the expected ~{bw_exp} MHz at {ksym} ksym/s means the tap is "
              "not carrying the modem signal at all (or was scored at the wrong rung: --ksym).")
    return 1


if __name__ == "__main__":
    sys.exit(main())
