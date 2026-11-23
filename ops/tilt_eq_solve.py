#!/usr/bin/env python3
"""tilt_eq_solve.py -- in-band tilt (dB across +-8 MHz) -> the three TiltEq corrector coefficients and the
0x260/0x264 register words.

Same stage model and bisection as modem/rtl_sim/sim_sro_perturb.cpp PERT_TILT_DB: one channel stage
y = x + a*j*x[n-1] has |H(f)|^2 = 1 + a^2 + 2a sin(2 pi f/FS). The fabric's TiltEq stage is the INVERSE
one-pole y[n] = x[n] - a*j*y[n-1] with the SAME a, so the value written is the channel's a (channel sign):
a > 0 for a spectrum rising towards +8 MHz, a < 0 for the "upper half down" slope seen on the rig.

Spec: docs/superpowers/specs/2026-10-03-rx-tilt-equaliser-design.md

  tilt_eq_solve.py <tilt_db>          one line: stages, a1..a3, 0x260=.. 0x264=..
  tilt_eq_solve.py --env <tilt_db>    PERT_EQ_A1=.. PERT_EQ_A2=.. PERT_EQ_A3=..   (for the sim legs)
"""
import math
import sys

FS = 61.44e6
F_EDGE = 8e6
A_MAX = 0.95
FRAC = 15


def stages_for(tilt_db):
    t = abs(tilt_db)
    return 3 if t > 14.0 else 2 if t > 7.0 else 1


def _stage_tilt(a, fs=FS, f_edge=F_EDGE):
    s = math.sin(2 * math.pi * f_edge / fs)
    return 10 * math.log10((1 + a * a + 2 * a * s) / (1 + a * a - 2 * a * s))


def solve_a(tilt_db, fs=FS, f_edge=F_EDGE):
    """Three coefficients; unused stages 0.0; each clamped to +-A_MAX; channel sign."""
    if tilt_db == 0.0:
        return [0.0, 0.0, 0.0]
    k = stages_for(tilt_db)
    want = abs(tilt_db) / k
    lo, hi = 0.0, 0.999
    for _ in range(60):
        a = 0.5 * (lo + hi)
        if _stage_tilt(a, fs, f_edge) < want:
            lo = a
        else:
            hi = a
    a = min(0.5 * (lo + hi), A_MAX)
    a = a if tilt_db > 0 else -a
    return [a] * k + [0.0] * (3 - k)


def encode(a):
    """sfix16_En15 two's complement in 16 bits."""
    q = int(round(a * (1 << FRAC)))
    q = max(-(1 << 15), min((1 << 15) - 1, q))
    return q & 0xFFFF


def decode(w):
    w &= 0xFFFF
    return (w - (1 << 16) if w & 0x8000 else w) / (1 << FRAC)


def to_regs(a):
    a1, a2, a3 = a
    en = 1 if any(x != 0.0 for x in a) else 0
    return (encode(a2) << 16) | encode(a1), (en << 31) | encode(a3)


def from_regs(w260, w264):
    return [decode(w260), decode(w260 >> 16), decode(w264)]


def main(argv):
    if len(argv) >= 3 and argv[1] == "--env":
        a = solve_a(float(argv[2]))
        print(f"PERT_EQ_A1={a[0]:.6f} PERT_EQ_A2={a[1]:.6f} PERT_EQ_A3={a[2]:.6f}")
        return 0
    if len(argv) != 2:
        print(__doc__)
        return 2
    t = float(argv[1])
    a = solve_a(t)
    w260, w264 = to_regs(a)
    print(f"tilt_db={t:+.2f} stages={stages_for(t)} a1={a[0]:+.5f} a2={a[1]:+.5f} a3={a[2]:+.5f} "
          f"0x260=0x{w260:08X} 0x264=0x{w264:08X}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
