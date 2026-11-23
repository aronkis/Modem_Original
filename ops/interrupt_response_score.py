#!/usr/bin/env python3
"""interrupt_response_score.py <run-dir> -- score ops/interrupt_response.sh: for each pause, the
resets during it, the resets in the 30 s after resumption, seconds to recover full detection, and
the carrier estimate's excursion. Board clock (pause stamps) and the poller are on the SAME board
pair; the poller runs on the receiver, the stamps come from the peer -- both boards' clocks are
compared via the run's own stamps, so a fixed offset is removed by aligning the first pause to the
first detection dip."""
import os
import sys

FULL = 1100    # f/s: back at rate


def sx(x):
    n = int(x, 16) if x.lower().startswith("0x") else int(x)
    return n - (1 << 32) if n >= (1 << 31) else n


def load(p):
    rows = []
    for ln in open(p):
        f = ln.strip().split(",")
        if len(f) < 4:
            continue
        try:
            rows.append((float(f[0]), sx(f[1]), sx(f[2]), sx(f[3])))
        except ValueError:
            pass
    return rows


def rate(rows, t0, t1):
    seg = [r for r in rows if t0 <= r[0] < t1]
    tot = span = 0.0
    for a, b in zip(seg, seg[1:]):
        dt, d = b[0] - a[0], b[1] - a[1]
        if dt <= 0 or d < 0 or d / dt > 3000:
            continue
        tot += d; span += dt
    return tot / span if span else float("nan")


def resets(rows, t0, t1):
    seg = [r for r in rows if t0 <= r[0] < t1]
    return max(0, seg[-1][2] - seg[0][2]) if len(seg) > 1 else 0


def main(argv):
    run = argv[0]
    rows = load(os.path.join(run, "rx_poll.csv"))
    reps = [l.rstrip("\n").split("\t") for l in open(os.path.join(run, "reps.tsv"))][1:]
    # Both stamps are `date +%s.%N` EPOCH seconds, which are timezone-free -- the boards' +5 h
    # difference is a TZ setting, not a clock offset -- so no alignment is applied. (The first
    # version of this scorer "aligned" on a detection dip and, on a run where the receiver stormed
    # continuously, picked a random dip 54.7 s away and scored every window in the wrong place.)
    off = float(os.environ.get("IR_CLOCK_OFFSET_S", "0"))
    print(f"receiver-clock minus peer-clock offset applied: {off:+.1f} s (epoch stamps; override with IR_CLOCK_OFFSET_S)")
    print(f"{'rep':>3s} {'pause ms':>8s} {'det before':>10s} {'resets during':>13s} {'resets +30s':>11s} {'s to full rate':>14s} {'cfc min..max after':>20s}")
    by = {}
    for n, ms, ts, tc, _ in reps:
        ts, tc = float(ts) + off, float(tc) + off
        before = rate(rows, ts - 10, ts - 1)
        during = resets(rows, ts - 1, tc + 1)
        after = resets(rows, tc, tc + 30)
        rec = float("nan")
        for a, b in zip(rows, rows[1:]):
            if a[0] >= tc and (b[1] - a[1]) >= 0 and (b[1] - a[1]) / max(b[0] - a[0], 1e-9) >= FULL:
                rec = a[0] - tc; break
        cs = [r[3] for r in rows if tc <= r[0] < tc + 30]
        print(f"{n:>3s} {ms:>8s} {before:10.0f} {during:13d} {after:11d} {rec:14.1f} {min(cs) if cs else 0:+9d}..{max(cs) if cs else 0:+9d}")
        by.setdefault(ms, []).append((during + after, rec))
    print("\nby pause length (median over reps): total resets, seconds to full rate")
    import statistics
    for ms in sorted(by, key=int):
        v = by[ms]
        print(f"  {ms:>5s} ms: resets {statistics.median([x for x, _ in v]):6.0f}   recover {statistics.median([y for _, y in v if y == y] or [float('nan')]):5.1f} s   (n={len(v)})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
