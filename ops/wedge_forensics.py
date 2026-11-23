#!/usr/bin/env python3
"""wedge_forensics.py <capture-root> -- classify each leg's mid-capture wedge from logs already on
disk (plan 2026-09-25-rig-instability Task 5). NO BOARD CONTACT.

The question: when delivery flatlines, has the RADIO stopped or has the BYTE PLANE stopped?

The capture rail already records enough to answer it without new instrumentation:
  * regs_pre.txt / regs_post.txt bracket the whole leg with the fabric's own detected-frame counter
    (0x104) and carrier-reset counter (0x150). If 0x104 keeps advancing at line rate across the
    flatline with no new resets, the demodulator never stopped -- only delivery to the host did.
  * frames.bin's last record (t_real_ns) is when the host last received anything.
  * capture.out carries the stall-poll onsets, the Tap-A IQ window (CAP_START/CAP_END) and the
    framelog rotate (ROTATE_*), so coincidence with either periodic event is testable.
  * the peer's daemon log shows whether the transmitter kept pumping (dma_tx advancing).

Prints one row per leg and a summary; exit 0 always (a reporting tool).
"""
import os
import re
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from frame_taxonomy import read_frames  # noqa: E402


def _regs(path):
    """Last 'pkts=' line of a regs file -> (t, pkts, rstcs) or None."""
    if not os.path.exists(path):
        return None
    out = None
    for line in open(path):
        m = re.search(r"t=([\d.]+) pkts=(0x[0-9A-Fa-f]+) biterr=\S+ rstcs=(0x[0-9A-Fa-f]+)", line)
        if m:
            out = (float(m.group(1)), int(m.group(2), 16), int(m.group(3), 16))
    return out


def leg(d):
    name = os.path.basename(d)
    cap = os.path.join(d, "capture.out")
    txt = open(cap).read() if os.path.exists(cap) else ""
    wedged = "CAPTURE_ABORTED_WEDGED" in txt
    pre, post = _regs(os.path.join(d, "regs_pre.txt")), _regs(os.path.join(d, "regs_post.txt"))
    det_rate = resets = None
    if pre and post and post[0] > pre[0]:
        dt = post[0] - pre[0]
        det_rate = (post[1] - pre[1]) / dt
        resets = post[2] - pre[2]
    # host delivery: last frame record
    stop_rel = dur = None
    fb = os.path.join(d, "frames.bin")
    if os.path.exists(fb) and os.path.getsize(fb) >= 48:
        fr = read_frames(fb)
        tr = fr["t_real_ns"].astype(np.int64) / 1e9
        dur = tr[-1] - tr[0]
        if pre:
            stop_rel = tr[-1] - pre[0]
    # stall onset, tap window, rotate -- for the coincidence test
    onset = None
    m = re.search(r"delivery stalled \d+s \(\+0 frames in \d+s\) at (\d+)s", txt)
    if m:
        onset = int(m.group(1))
    caps = re.search(r"CAP_START t=([\d.]+)", txt)
    rot = re.search(r"ROTATE_RX ip=\S+ board_t=([\d.]+)", txt)
    tap_rel = (float(caps.group(1)) - pre[0]) if (caps and pre) else None
    rot_rel = (float(rot.group(1)) - pre[0]) if (rot and pre) else None
    # transmitter still pumping?
    tx_ok = None
    pl = os.path.join(d, "qpsk_tun_peer.log")
    if os.path.exists(pl):
        v = re.findall(r"dma_tx=(\d+)", open(pl).read())
        if len(v) >= 2:
            tx_ok = int(v[-1]) > int(v[-2])
    return dict(name=name, wedged=wedged, det_rate=det_rate, resets=resets, onset=onset,
                stop_rel=stop_rel, dur=dur, tap_rel=tap_rel, rot_rel=rot_rel, tx_ok=tx_ok)


def main(root):
    legs = sorted(os.path.join(root, x) for x in os.listdir(root)
                  if os.path.isdir(os.path.join(root, x)))
    rows = [leg(d) for d in legs]
    rows = [r for r in rows if r["det_rate"] is not None or r["dur"] is not None]
    print(f"{'leg':18s} {'wedge':6s} {'fabric det/s':>12s} {'resets':>7s} {'deliv stop':>11s} "
          f"{'stall@':>7s} {'tap@':>7s} {'rotate@':>8s} {'tx pumping':>11s}")
    for r in rows:
        print(f"{r['name']:18s} {'YES' if r['wedged'] else 'no':6s} "
              f"{(f'{r['det_rate']:.0f}' if r['det_rate'] is not None else '-'):>12s} "
              f"{(str(r['resets']) if r['resets'] is not None else '-'):>7s} "
              f"{(f'{r['stop_rel']:.0f}s' if r['stop_rel'] is not None else '-'):>11s} "
              f"{(f'{r['onset']}s' if r['onset'] is not None else '-'):>7s} "
              f"{(f'{r['tap_rel']:.0f}s' if r['tap_rel'] is not None else '-'):>7s} "
              f"{(f'{r['rot_rel']:.0f}s' if r['rot_rel'] is not None else '-'):>8s} "
              f"{({True: 'yes', False: 'NO', None: '-'}[r['tx_ok']]):>11s}")
    w = [r for r in rows if r["wedged"]]
    c = [r for r in rows if not r["wedged"]]
    print()
    for label, grp in (("WEDGED", w), ("clean", c)):
        dr = [r["det_rate"] for r in grp if r["det_rate"] is not None]
        rs = [r["resets"] for r in grp if r["resets"] is not None]
        if dr:
            print(f"{label:7s} n={len(grp):2d}  fabric detections/s min={min(dr):.0f} max={max(dr):.0f} "
                  f"mean={sum(dr)/len(dr):.0f}   carrier resets over the whole leg: "
                  f"min={min(rs)} max={max(rs)}")
    if w:
        near = [r for r in w if r["onset"] is not None and r["tap_rel"] is not None
                and abs(r["onset"] - r["tap_rel"]) < 20]
        print(f"\nwedge onset within 20 s of the Tap-A window: {len(near)} of "
              f"{len([r for r in w if r['onset'] is not None])}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
