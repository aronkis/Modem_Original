#!/usr/bin/env python3
"""cfc_cells.py -- score an interleaved LO sweep (gate3_pair.sh GATE3_CELLS) on the statistic the
experiment actually turns on: the fraction of frames whose carrier-frequency estimate (reg_cfc,
0x154, sign-extended) sits on the WRONG side of zero.

Why this and not accept_analyze.py: the demod has a dead zone at residual CFO ~= 0, where the
estimate dithers across the null and the Frequency and Time Synchronizer latches a false state that
only a full 0x000 soft reset clears (docs/evidence/sp4/ACQUISITION_COLLAPSE.md). PER and CRC are
consequences; the sign fraction is the direct measure of proximity to the null. accept_analyze.py
reports the former and not the latter.

Reading the table: the mechanism predicts the CFC>0 column tracks the LO CELL. If instead it tracks
the CLOCK -- both +20k cells resembling whichever neighbour they sit beside -- the driver is drift
or RF conditions, and the LO story is not supported. That is the whole point of interleaving, and
it is why a single clean leg on the new value proves nothing.

  ops/cfc_cells.py <campaign-dir>            # every cell*/ subdir, in cell order
  ops/cfc_cells.py <leg-dir> [<leg-dir> ...] # explicit dirs
"""
import os
import re
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from frame_taxonomy import read_frames, sx21  # noqa: E402


def cell_dirs(argv):
    if len(argv) == 1 and os.path.isdir(os.path.join(argv[0], "gate3.log")) is False:
        kids = sorted(
            (d for d in os.listdir(argv[0]) if re.match(r"^cell\d+_", d)),
            key=lambda d: int(re.match(r"^cell(\d+)_", d).group(1)),
        )
        if kids:
            return [os.path.join(argv[0], d) for d in kids]
    return argv


def score(d):
    f = os.path.join(d, "frames.bin")
    row = {"cell": os.path.basename(d)}
    if not os.path.exists(f):
        row["note"] = "no frames.bin (the cell never delivered -- itself a result)"
        return row
    a = read_frames(f)
    cfc = sx21(a["reg_cfc"])
    n = len(a)
    row.update(
        frames=n,
        pos_pct=100.0 * float(np.count_nonzero(cfc > 0)) / n,
        p5=int(np.percentile(cfc, 5)),
        med=int(np.median(cfc)),
        p95=int(np.percentile(cfc, 95)),
        crc_pct=100.0 * float(np.count_nonzero(a["crc_ok"] != 0)) / n,
    )
    # wall-clock span from the host timestamps, so f/s is delivered rate with losses included
    span = (int(a["t_mono_ns"][-1]) - int(a["t_mono_ns"][0])) / 1e9
    row["span_s"] = round(span, 1)
    row["fps"] = int(n / span) if span > 0 else 0
    cap = os.path.join(d, "capture.out")
    row["wedged"] = bool(
        os.path.exists(cap) and "CAPTURE_ABORTED_WEDGED" in open(cap, errors="replace").read()
    )
    return row


def main(argv):
    dirs = cell_dirs(argv)
    if not dirs:
        print(__doc__)
        return 2
    print(f"{'cell':<26} {'frames':>7} {'span':>6} {'f/s':>5} {'CRC ok':>7} "
          f"{'CFC>0':>7} {'p5':>7} {'med':>7} {'p95':>7}  wedged")
    for d in dirs:
        r = score(d)
        if "note" in r:
            print(f"{r['cell']:<26} {r['note']}")
            continue
        print(f"{r['cell']:<26} {r['frames']:>7} {r['span_s']:>6} {r['fps']:>5} "
              f"{r['crc_pct']:>6.2f}% {r['pos_pct']:>6.2f}% {r['p5']:>7} {r['med']:>7} "
              f"{r['p95']:>7}  {'YES' if r['wedged'] else '-'}")
    print("\nEvery number counts delivered frames only; a wedged cell's span ends at the wedge.")
    print("Read the CFC>0 column against the cell ORDER, not just the cell value: if it tracks the")
    print("LO the mechanism is supported, if it tracks the clock it is conditions.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
