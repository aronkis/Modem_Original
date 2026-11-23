#!/usr/bin/env python3
"""episode_stats.py -- how OFTEN the reverse leg fails, and in what shape, from the delivery
sentinel's log. Companion to ops/sentinel_stats.py, which answers "what fraction of the time";
this one answers "in how many distinct events, how long, how deep, and is it getting worse".

WHY A SECOND TOOL, AND WHY IT LEADS WITH A COUNT AND NOT A RATIO
----------------------------------------------------------------
Every ratio built from this log carries the 1.5x 'high mode' window artefact (see
sentinel_stats.py's header), which is why that tool has to report two constructions and check
they agree. The statistic this tool leads with needs no ratio at all:

    rev == 0        146 delivered EXACTLY nothing in the sample

A dead leg is a dead leg in any window mode, so the zero count is immune to the artefact
entirely. It is also the statistic that moved: 0-1 % per day through 2026-09-19, 10 % on 09-27.

EPISODE, AND WHAT IT IS NOT
---------------------------
An "episode" here is a maximal run of CONSECUTIVE degraded samples. The sentinel samples every
~5 minutes, so:

  * onsets and durations are quantised at ~5 min, and
  * any episode shorter than the sample interval is INVISIBLE to this tool.

That makes a sentinel episode a different object from the per-frame holes inside a 300 s capture
(ops/frame_taxonomy.py). They live on different timescales; do not pool them or compare their
counts. A gap in the log (sentinel restarted, rig work) BREAKS an episode rather than bridging
it, because we cannot know what happened across the gap.

Usage:
  ops/episode_stats.py [--log PATH] [--since YYYY-MM-DD] [--bad 0.75] [--quiet-s 1200]
                       [--leg rev|fwd] [--no-quiet-filter]
"""
import argparse
import datetime
import os
import statistics
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sentinel_stats import parse, quiet_filter  # noqa: E402

# A gap longer than this ends an episode instead of continuing it: we have no evidence about the
# interval, and stitching across it would invent duration the log never recorded.
MAX_GAP_S = 900


def ratio(r, leg):
    """Mode-free proxy: each board's receive over its OWN transmit (see sentinel_stats.py).

    Returns None when the denominator is zero -- a dead TRANSMITTER is a different fault from a
    dead receiver and cannot be expressed as a delivery ratio at all.
    """
    rx, tx = (("rev", "rtx") if leg == "rev" else ("rate", "tx"))
    if r[rx] is None or r[tx] is None or r[tx] == 0:
        return None
    return r[rx] / r[tx]


def rx_value(r, leg):
    return r["rev"] if leg == "rev" else r["rate"]


def episodes(rows, leg, bad):
    """Maximal runs of consecutive degraded samples. Returns dicts with start/end/n/depth."""
    out, cur = [], None
    prev_t = None
    for r in rows:
        v = ratio(r, leg)
        gap = prev_t is not None and (r["t"] - prev_t).total_seconds() > MAX_GAP_S
        prev_t = r["t"]
        degraded = v is not None and v < bad
        if cur is not None and (gap or not degraded):
            out.append(cur)
            cur = None
        if degraded:
            if cur is None:
                cur = dict(start=r["t"], end=r["t"], n=0, vals=[], zeros=0)
            cur["end"] = r["t"]
            cur["n"] += 1
            cur["vals"].append(v)
            if rx_value(r, leg) == 0:
                cur["zeros"] += 1
    if cur is not None:
        out.append(cur)
    for e in out:
        e["dur_s"] = (e["end"] - e["start"]).total_seconds()
        e["min"] = min(e["vals"])
        e["med"] = statistics.median(e["vals"])
    return out


def pct(n, d):
    return (100.0 * n / d) if d else float("nan")


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", default="/home/tcollins/modem-status/sentinel.log")
    ap.add_argument("--since", default=None)
    ap.add_argument("--bad", type=float, default=0.75)
    ap.add_argument("--quiet-s", type=int, default=1200)
    ap.add_argument("--leg", default="rev", choices=("rev", "fwd"))
    ap.add_argument("--no-quiet-filter", action="store_true",
                    help="keep samples near rig work (shows how much of a trend is contamination)")
    a = ap.parse_args(argv)

    rows, marks = parse(a.log)
    if not rows:
        print(f"{a.log}: no parsable samples", file=sys.stderr)
        return 1
    if a.since:
        cut = datetime.datetime.strptime(a.since, "%Y-%m-%d")
        rows = [r for r in rows if r["t"] >= cut]
    rows = [r for r in rows if all(r[k] is not None for k in ("rate", "tx", "rev", "rtx"))]
    raw_n = len(rows)
    rec = rows if a.no_quiet_filter else quiet_filter(rows, marks, a.quiet_s)

    print(f"log {a.log}   leg={a.leg}   degraded threshold {a.bad} (mode-free proxy)")
    print(f"samples with all four counters: {raw_n}"
          f"   after quiet filter ({'OFF' if a.no_quiet_filter else str(a.quiet_s) + 's'}): {len(rec)}")
    print("sentinel period ~5 min: onsets/durations are quantised at 5 min and shorter events are "
          "invisible.\n")

    # ---- the ratio-free headline -------------------------------------------------------------
    print(f"{'day':12s} {'n':>5s} {'rx==0':>7s} {'zero%':>7s} {'deg%':>7s} {'med':>7s} {'p5':>7s}")
    by = {}
    for r in rec:
        by.setdefault(r["t"].date(), []).append(r)
    for d in sorted(by):
        v = by[d]
        vals = [x for x in (ratio(r, a.leg) for r in v) if x is not None]
        z = sum(1 for r in v if rx_value(r, a.leg) == 0)
        deg = sum(1 for x in vals if x < a.bad)
        sv = sorted(vals)
        p5 = sv[min(int(len(sv) * .05), len(sv) - 1)] if sv else float("nan")
        med = statistics.median(sv) if sv else float("nan")
        print(f"{str(d):12s} {len(v):5d} {z:7d} {pct(z, len(v)):7.1f} {pct(deg, len(vals)):7.1f} "
              f"{med:7.3f} {p5:7.3f}")

    # ---- episode shape -----------------------------------------------------------------------
    eps = episodes(rec, a.leg, a.bad)
    print(f"\nepisodes (maximal runs of consecutive degraded samples; a >{MAX_GAP_S}s log gap ends "
          f"one rather than bridging it): {len(eps)}")
    if eps:
        durs = sorted(e["dur_s"] for e in eps)
        ns = sorted(e["n"] for e in eps)
        print(f"  samples per episode: median {statistics.median(ns):.0f}  max {ns[-1]}")
        print(f"  duration: median {statistics.median(durs)/60:.0f} min  max {durs[-1]/60:.0f} min"
              f"   (single-sample episodes read as 0 min -- the event is shorter than the period)")
        deep = [e for e in eps if e["zeros"]]
        print(f"  episodes containing a ZERO-delivery sample: {len(deep)} of {len(eps)}")
        span_days = (rec[-1]["t"] - rec[0]["t"]).total_seconds() / 86400.0
        if span_days > 0:
            print(f"  rate: {len(eps)/span_days:.2f} episodes/day over {span_days:.1f} days")
        print("\n  10 longest:")
        for e in sorted(eps, key=lambda e: -e["dur_s"])[:10]:
            print(f"    {e['start']:%Y-%m-%d %H:%M} -> {e['end']:%H:%M}  "
                  f"{e['n']:3d} samples  {e['dur_s']/60:5.0f} min  "
                  f"min={e['min']:.3f} med={e['med']:.3f} zeros={e['zeros']}")

    # ---- simultaneous state of the OTHER leg -------------------------------------------------
    other = "fwd" if a.leg == "rev" else "rev"
    both = [r for r in rec if (ratio(r, a.leg) or 1) < a.bad]
    if both:
        co = sum(1 for r in both if (ratio(r, other) or 1) < a.bad)
        print(f"\nof the {len(both)} degraded {a.leg} samples, {co} ({pct(co, len(both)):.1f}%) had "
              f"{other} degraded in the SAME sample")
        print("  -- a shared cause (reference, host, RF floor) would degrade both together")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
