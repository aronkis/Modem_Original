#!/usr/bin/env python3
"""sentinel_stats.py -- availability statistics for both legs from the delivery sentinel's log.

The sentinel (~/modem-status/delivery_sentinel.sh, relaunched by the keeper unit) samples both
boards' daemon stats lines every ~5 minutes and costs nothing extra to run, so its log is the only
continuous record of how the link behaves between campaigns. This reads it; it never writes to it
and never touches a board.

WHAT THE FIELDS ACTUALLY ARE (read from the sentinel, 2026-09-26 -- getting this wrong invents a
defect or hides one):

    rate = 148 idle_rx   FORWARD leg receive       tx  = 148 dma_tx   REVERSE leg source
    rev  = 146 idle_rx   REVERSE leg receive       rtx = 146 dma_tx   FORWARD leg source

So a true delivery ratio is CROSS-board: reverse = rev/tx, forward = rate/rtx. But the two boards
are not always sampled over the same window -- the known 'high mode' is exactly 1.5x -- and a
cross-board ratio taken across two different windows is wrong by that factor. This tool therefore
reports two constructions and expects them to agree:

  * cross   -- the true delivery ratio, computed ONLY on samples where both boards are in the same
               window mode (tx ~= rtx). Correct, but throws most samples away.
  * proxy   -- each board's receive over its OWN transmit, same board and same window, so the mode
               cancels. Not a delivery ratio; valid as a proxy only while the local transmitter is
               at nominal, which the tool checks and prints.

Samples within QUIET_S of any non-"ok" line (wedge, recovery, rig work, restart) are dropped: the
log is contaminated whenever the rig is being worked on.

  ops/sentinel_stats.py [--log PATH] [--since YYYY-MM-DD] [--bad 0.75] [--quiet-s 1200]
"""
import argparse
import bisect
import collections
import datetime
import re
import sys

FIELDS = ("rate", "tx", "rev", "rtx")


def parse(path):
    rows, marks = [], []
    for ln in open(path, errors="replace"):
        m = re.match(r"^(\d{4}-\d{2}-\d{2})_(\d{1,2}):(\d{1,2}):(\d{1,2}) (.*)$", ln.rstrip())
        if not m:
            continue
        d, hh, mm, ss, rest = m.groups()
        try:
            t = datetime.datetime.strptime(
                f"{d} {int(hh):02d}:{int(mm):02d}:{int(ss):02d}", "%Y-%m-%d %H:%M:%S")
        except ValueError:
            continue
        if not rest.startswith("ok "):
            marks.append(t)
            continue
        r = {"t": t}
        for k in FIELDS:
            o = re.search(rf"\b{k}=([0-9.]+)", rest)
            r[k] = float(o.group(1)) if o else None
        rows.append(r)
    return rows, sorted(marks)


def quiet_filter(rows, marks, quiet_s):
    out = []
    for r in rows:
        i = bisect.bisect_left(marks, r["t"])
        near = any(0 <= j < len(marks) and abs((r["t"] - marks[j]).total_seconds()) < quiet_s
                   for j in (i - 1, i))
        if not near:
            out.append(r)
    return out


def stats(vals, bad):
    v = sorted(vals)
    if not v:
        return None
    q = lambda p: v[min(int(len(v) * p), len(v) - 1)]
    return dict(n=len(v), med=q(.5), p5=q(.05), p1=q(.01),
                bad_pct=100.0 * sum(1 for x in v if x < bad) / len(v))


def show(label, s):
    if s is None:
        print(f"  {label:32s} (no samples)")
        return
    print(f"  {label:32s} n={s['n']:5d} med={s['med']:.3f} p5={s['p5']:.3f} "
          f"p1={s['p1']:.3f} below-threshold {s['bad_pct']:5.2f}%")


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", default="/home/tcollins/modem-status/sentinel.log")
    ap.add_argument("--since", default=None, help="YYYY-MM-DD (default: all)")
    ap.add_argument("--bad", type=float, default=0.75, help="degraded threshold (default 0.75)")
    ap.add_argument("--quiet-s", type=int, default=1200,
                    help="drop samples within N s of any non-ok line (default 1200)")
    a = ap.parse_args(argv)

    rows, marks = parse(a.log)
    if not rows:
        print(f"{a.log}: no parsable samples", file=sys.stderr)
        return 1
    if a.since:
        cut = datetime.datetime.strptime(a.since, "%Y-%m-%d")
        rows = [r for r in rows if r["t"] >= cut]
    # `all(r[k] ...)` would be a silent optimism bug: a leg delivering EXACTLY zero frames is
    # falsy, so the worst samples in the log would be dropped from every statistic below.
    full = [r for r in rows if all(r[k] is not None for k in FIELDS)]
    rec = quiet_filter(full, marks, a.quiet_s)
    print(f"log {a.log}")
    print(f"samples with all four counters: {len(full)}  "
          f"({rows[0]['t']:%Y-%m-%d} .. {rows[-1]['t']:%Y-%m-%d})")
    print(f"after dropping those within {a.quiet_s}s of rig work / wedge / restart: {len(rec)}")
    if not rec:
        return 1

    rec = [r for r in rec if r["tx"] and r["rtx"]]   # a zero DENOMINATOR is a dead transmitter,
    # a different fault from a dead receiver; it cannot be expressed as a delivery ratio at all
    same = [r for r in rec if abs(r["tx"] - r["rtx"]) / max(r["tx"], r["rtx"]) < 0.02]
    print(f"\nTRUE cross-board delivery (both boards in one window mode: {len(same)} samples, "
          f"{100*len(same)/len(rec):.1f}%)")
    show("reverse  146 rx / 148 tx", stats([r["rev"] / r["tx"] for r in same], a.bad))
    show("forward  148 rx / 146 tx", stats([r["rate"] / r["rtx"] for r in same], a.bad))
    print("\nproxy, each board's rx over its OWN tx (mode-free, all quiet samples)")
    show("reverse  146 rx / 146 tx", stats([r["rev"] / r["rtx"] for r in rec], a.bad))
    show("forward  148 rx / 148 tx", stats([r["rate"] / r["tx"] for r in rec], a.bad))

    worst = [r for r in rec if r["rev"] / r["rtx"] < 0.5]
    if worst:
        f = lambda k: sorted(r[k] for r in worst)[len(worst) // 2]
        print(f"\nduring the {len(worst)} worst reverse samples (proxy < 0.5): "
              f"146 own tx median {f('rtx'):.0f}/s, 148 tx median {f('tx'):.0f}/s")
        print("  -- if those hold at nominal the collapse is RECEIVE-side, not a starved transmitter")

    deg = collections.Counter(); tot = collections.Counter()
    for r in rec:
        tot[r["t"].hour] += 1
        if r["rev"] / r["rtx"] < a.bad:
            deg[r["t"].hour] += 1
    hrs = [h for h in range(24) if tot[h]]
    print(f"\nreverse degraded (< {a.bad}) by hour of day:")
    print("  " + " ".join(f"{h:02d}h:{100*deg[h]/tot[h]:4.0f}%" for h in hrs))
    v = [100 * deg[h] / tot[h] for h in hrs]
    print(f"  spread {min(v):.0f}%..{max(v):.0f}%, overall {100*sum(deg.values())/sum(tot.values()):.1f}%"
          f"  (n per hour ~{sum(tot.values())//len(hrs)}; small counts, do not read a diurnal"
          f" pattern into this without more data)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
