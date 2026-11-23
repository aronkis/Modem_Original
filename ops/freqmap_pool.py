#!/usr/bin/env python3
"""freqmap_pool.py <freqmap-dir> -- pool a freq_map_campaign.sh run by reverse-carrier candidate.

Each candidate directory holds one 2-cell plan_cells run: cell 1 = the 1900 MHz reference,
cell 2 = the candidate. The pairing is the point: a clean candidate cell is only evidence when the
reference cell BESIDE it had the fault, so every row prints the candidate against its own paired
reference, and the summary counts only pairs where the reference was degraded.

  fault present (reference)  : 146 detection after 60 s < 900 f/s, or rstcs > 1000
  candidate clean            : 146 detection after 60 s >= 1200 f/s and rstcs < 100

Notch vs slope: a NOTCH has clean candidates on BOTH sides of 1900 (1850 and 1950 clean says the
impairment is narrow); a SLOPE has candidates getting monotonically better in one direction.
"""
import os
import re
import statistics
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from plan_cells_score import load, score  # noqa: E402

FAULT_DET, FAULT_RST = 900, 1000
CLEAN_DET, CLEAN_RST = 1200, 100


def cells(run):
    tsv = os.path.join(run, "cells.tsv")
    if not os.path.exists(tsv):
        return {}
    out = {}
    for ln in open(tsv):
        f = ln.rstrip("\n").split("\t")
        if not f or f[0] == "cell" or len(f) < 7 or f[4] == "dry":
            continue
        s = score(load(os.path.join(run, f[6])))
        c = score(load(os.path.join(run, f[5])))
        if s is None:
            continue
        s["ctrl"] = c
        out[f[1]] = s
    return out


def fault_present(s):
    return s["det_60_end"] < FAULT_DET or s["rstcs"] > FAULT_RST


def clean(s):
    return s["det_60_end"] >= CLEAN_DET and s["rstcs"] < CLEAN_RST


def main(argv):
    root = argv[0]
    by = {}
    for d in sorted(os.listdir(root)):
        m = re.match(r"\d{6}_rev(\d+)$", d)
        if not m:
            continue
        c = cells(os.path.join(root, d))
        ref = c.get("ref1900")
        cand = c.get(f"rev{m.group(1)}")
        if ref is None or cand is None:
            continue
        by.setdefault(int(m.group(1)), []).append((d, ref, cand))

    print(f"{'MHz':>5s} {'run':>15s} | {'ref det>60s':>11s} {'ref rstcs':>9s} {'fault?':>6s} | "
          f"{'cand det>60s':>12s} {'cand rstcs':>10s} {'cand cfc':>9s} {'clean?':>6s} | {'148 ctrl':>8s}")
    verdict = {}
    for mhz in sorted(by):
        for d, ref, cand in by[mhz]:
            fp, cl = fault_present(ref), clean(cand)
            ctrl = cand["ctrl"]["det_60_end"] if cand["ctrl"] else float("nan")
            print(f"{mhz:5d} {d:>15s} | {ref['det_60_end']:11.0f} {ref['rstcs']:9d} {'YES' if fp else 'no':>6s} | "
                  f"{cand['det_60_end']:12.0f} {cand['rstcs']:10d} {cand['cfc_med']:+9.0f} {'YES' if cl else 'no':>6s} | {ctrl:8.0f}")
        paired = [(r, c) for _, r, c in by[mhz] if fault_present(r)]
        n_clean = sum(1 for _, c in paired if clean(c))
        verdict[mhz] = (len(by[mhz]), len(paired), n_clean,
                        statistics.median([c["det_60_end"] for _, _, c in by[mhz]]))
    print("\npooled (evidence = pairs whose REFERENCE cell had the fault):")
    print(f"{'MHz':>5s} {'pairs':>5s} {'w/fault':>7s} {'clean':>5s} {'cand det med':>12s}")
    for mhz in sorted(verdict):
        n, p, k, med = verdict[mhz]
        print(f"{mhz:5d} {n:5d} {p:7d} {k:5d} {med:12.0f}")
    below = [m for m in verdict if m < 1900 and verdict[m][1] and verdict[m][2] == verdict[m][1]]
    above = [m for m in verdict if m > 1900 and verdict[m][1] and verdict[m][2] == verdict[m][1]]
    if below and above:
        print(f"\nshape: NOTCH -- clean on both sides of 1900 ({min(below)}..{max(below)} and "
              f"{min(above)}..{max(above)} MHz, every fault-paired cell clean)")
    elif below or above:
        print(f"\nshape: one-sided so far (clean {'below' if below else 'above'} 1900 only) -- "
              f"a SLOPE is not excluded")
    else:
        print("\nshape: no candidate is clean in every fault-paired cell yet")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
