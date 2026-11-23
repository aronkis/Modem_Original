#!/usr/bin/env python3
"""plan_cells_score.py -- score a plan_cells.sh run: per cell, per board, detection in windows
after the arm plus the carrier statistic, then the A-vs-B contrast read against cell ORDER.

    ops/plan_cells_score.py <run-dir>                  # every cell in cells.tsv
    ops/plan_cells_score.py --one <148.csv> <146.csv>  # one cell, used by the runner

Rules carried over from the day this was built (2026-09-28):
  * torn direct_reg_access reads are dropped before anything is averaged: |0x154| > 2^20, and
    0x104 intervals above 3000 f/s (ops/rate_probe.sh's ceiling, same reason);
  * a 0x104 interval that goes backwards contains a counter reset and is unusable for rate;
  * "dead zone" = |CFC| < 1000, the null the demodulator cannot track across;
  * the detection windows are 0-60 s and 60 s-end, because that is where the decay lives.
"""
import os
import statistics
import sys

CFC_MAX = 1 << 20
PLAUS = 3000
DEAD = 1000


def sx(x):
    n = int(x, 16) if x.lower().startswith("0x") else int(x)
    return n - (1 << 32) if n >= (1 << 31) else n


def load(path):
    rows = []
    for ln in open(path, errors="replace"):
        f = ln.strip().split(",")
        if len(f) < 4:
            continue
        try:
            t, p, c, r = int(f[0]), sx(f[1]), sx(f[2]), sx(f[3])
        except ValueError:
            continue
        rssi = float(f[4]) if len(f) > 4 and f[4] not in ("", "-") else None
        dpow = float(f[5]) if len(f) > 5 and f[5] not in ("", "-") else None
        gain = float(f[6]) if len(f) > 6 and f[6] not in ("", "-") else None
        rows.append((t, p, c, r, rssi, dpow, gain))
    return rows


def rate(g):
    tot = span = 0.0
    for a, b in zip(g, g[1:]):
        dt = b[0] - a[0]
        d = b[1] - a[1]
        if dt <= 0 or d < 0 or d / dt > PLAUS:
            continue
        tot += d
        span += dt
    return tot / span if span else float("nan")


def score(rows):
    if len(rows) < 5:
        return None
    t0 = rows[0][0]
    cs = [r[2] for r in rows if abs(r[2]) < CFC_MAX]
    out = dict(
        n=len(rows), span=rows[-1][0] - t0,
        det_0_60=rate([r for r in rows if r[0] - t0 < 60]),
        det_60_end=rate([r for r in rows if r[0] - t0 >= 60]),
        cfc_med=statistics.median(cs) if cs else float("nan"),
        cfc_sd=statistics.pstdev(cs) if cs else float("nan"),
        dead_pct=100.0 * sum(1 for x in cs if abs(x) < DEAD) / len(cs) if cs else float("nan"),
        rstcs=max(0, rows[-1][3] - rows[0][3]),
    )
    for k, i in (("rssi", 4), ("dpow", 5), ("gain", 6)):
        v = [r[i] for r in rows if r[i] is not None]
        out[k] = statistics.median(v) if v else float("nan")
    return out


def fmt(s):
    if s is None:
        return "(no data)"
    return (f"det {s['det_0_60']:6.0f} -> {s['det_60_end']:6.0f} f/s   cfc med {s['cfc_med']:+7.0f} "
            f"sd {s['cfc_sd']:6.0f} dead {s['dead_pct']:5.1f}%   rstcs {s['rstcs']:6d}   "
            f"rssi {s['rssi']:5.1f} dpow {s['dpow']:5.1f} gain {s['gain']:4.1f}")


def one(ca, cb):
    sa, sb = score(load(ca)), score(load(cb))
    print(f"148 ctrl: {fmt(sa)}")
    print(f"146 subj: {fmt(sb)}")
    return sa, sb


def main(argv):
    if argv and argv[0] == "--one":
        one(argv[1], argv[2])
        return 0
    run = argv[0]
    tsv = os.path.join(run, "cells.tsv")
    cells = []
    for ln in open(tsv):
        f = ln.rstrip("\n").split("\t")
        if not f or f[0] == "cell" or f[4] == "dry":
            continue
        cells.append(f)
    print(f"{'cell':4s} {'plan':12s} {'gate146':>7s} | {'146 det 0-60':>12s} {'60-end':>7s} {'cfc':>7s} "
          f"{'dead%':>6s} {'rstcs':>6s} {'dpow':>5s} | {'148 det':>7s} {'cfc':>7s} {'dead%':>6s}")
    by = {}
    for f in cells:
        sa = score(load(os.path.join(run, f[5])))
        sb = score(load(os.path.join(run, f[6])))
        if sb is None:
            print(f"{f[0]:4s} {f[1]:12s} {f[3]:>7s} | (no data)")
            continue
        a = sa or dict(det_60_end=float("nan"), cfc_med=float("nan"), dead_pct=float("nan"))
        print(f"{f[0]:4s} {f[1]:12s} {f[3]:>7s} | {sb['det_0_60']:12.0f} {sb['det_60_end']:7.0f} "
              f"{sb['cfc_med']:+7.0f} {sb['dead_pct']:6.1f} {sb['rstcs']:6d} {sb['dpow']:5.1f} | "
              f"{a['det_60_end']:7.0f} {a['cfc_med']:+7.0f} {a['dead_pct']:6.1f}")
        by.setdefault(f[1], []).append(sb)
    print()
    for plan, ss in by.items():
        d = [s["det_60_end"] for s in ss if s["det_60_end"] == s["det_60_end"]]
        z = [s["dead_pct"] for s in ss if s["dead_pct"] == s["dead_pct"]]
        if d:
            print(f"plan {plan:12s}: 146 det after 60 s median {statistics.median(d):6.0f} f/s "
                  f"(cells {' '.join(f'{x:.0f}' for x in d)})   dead-zone median {statistics.median(z):5.1f}%")
    print("\nRead by PLAN against cell ORDER. A statistic that alternates with the plan is the knob;")
    print("one that climbs or falls monotonically with the cell number is conditions.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
