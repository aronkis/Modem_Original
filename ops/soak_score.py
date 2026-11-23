#!/usr/bin/env python3
"""soak_score.py -- score a long soak of the pair from files alone (plan Phase 5, 2026-09-30).

  soak_score.py --since 'YYYY-MM-DD HH:MM' [--until ...] --wd IP=WDLOG [--wd IP=WDLOG]
                [--sentinel ~/modem-status/sentinel.log] [--hours 4]

Inputs are a freshly pulled /dev/shm/watchdog.log per board (a FILE read; the board's own clock
runs the [wd HH:MM:SS] stamps, so each log is anchored by its LAST line to the pull time = the
file's mtime, exactly as reset_ledger.py --live does) and the nemo sentinel log.

Acceptance (the carrier-reset plan's target), per board over the window:
  fabric resets in LOCKED windows = 0, storms (NOT-LOCKED with >= 100 resets) = 0,
  FULL RE-ARMs = 0, daemon relaunches / host wedges = 0, sentinel recoveries = 0,
  and the window is at least --hours long.
Sentinel samples are reported, not gated: rate/rev are per-board counters with a 1.5x window
artefact (sentinel-stats), so the ratio-free "rev == 0 / rate == 0" count is what is shown.
Every count states its denominator (windows, samples) -- nothing here is a PER.
"""
import argparse
import datetime as dt
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import reset_ledger  # noqa: E402

STORM = 100


def score_board(ip, events, t0, t1):
    ev = [e for e in events if t0 <= e[0] <= t1]
    locked = [e for e in ev if e[1] == "locked"]
    notl = [e for e in ev if e[1] == "notlocked"]
    r = dict(ip=ip, windows=len(locked) + len(notl), locked=len(locked),
             locked_with_resets=sum(1 for e in locked if (e[2] or 0) > 0),
             fabric_resets_locked=sum((e[2] or 0) for e in locked),
             notlocked=len(notl), storms=sum(1 for e in notl if (e[2] or 0) >= STORM),
             rearms=sum(1 for e in ev if e[1] == "rearm"),
             daemon=sum(1 for e in ev if e[1] in ("daemon_dead", "host_wedge")),
             first=min((e[0] for e in ev), default=None), last=max((e[0] for e in ev), default=None))
    r["ok"] = (r["fabric_resets_locked"] == 0 and r["storms"] == 0 and r["rearms"] == 0
               and r["daemon"] == 0 and r["windows"] > 0)
    return r


def sentinel_counts(path, t0, t1):
    n = zero = rec = 0
    for ln in open(path, errors="replace"):
        m = re.match(r"^(\d{4}-\d\d-\d\d)_(\d\d:\d\d:\d\d) (.*)$", ln.rstrip("\n"))
        if not m:
            continue
        t = dt.datetime.strptime(m[1] + " " + m[2], "%Y-%m-%d %H:%M:%S")
        if not (t0 <= t <= t1):
            continue
        rest = m[3]
        if rest.startswith("WEDGE detected") or "recovering (post-reboot" in rest:
            rec += 1
        if rest.startswith("ok "):
            n += 1
            rate = re.search(r"\brate=(\d+)", rest)
            rev = re.search(r"\brev=(\d+)", rest)
            if (rate and int(rate[1]) == 0) or (rev and int(rev[1]) == 0):
                zero += 1
    return dict(samples=n, zero_rate_or_rev=zero, recoveries=rec)


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--since", required=True)
    ap.add_argument("--until", default=None)
    ap.add_argument("--wd", action="append", default=[], help="IP=path to a pulled watchdog.log")
    ap.add_argument("--sentinel", default=os.path.expanduser("~/modem-status/sentinel.log"))
    ap.add_argument("--hours", type=float, default=4.0)
    a = ap.parse_args(argv)
    t0 = dt.datetime.strptime(a.since, "%Y-%m-%d %H:%M")
    t1 = dt.datetime.strptime(a.until, "%Y-%m-%d %H:%M") if a.until else dt.datetime.now()
    span_h = (t1 - t0).total_seconds() / 3600
    print(f"SOAK window {t0:%Y-%m-%d %H:%M} .. {t1:%Y-%m-%d %H:%M} = {span_h:.2f} h (need >= {a.hours} h)")
    allok = span_h >= a.hours
    for spec in a.wd:
        ip, path = spec.split("=", 1)
        _, end, events, _ = reset_ledger.load_live(path, ip)
        r = score_board(ip, events, t0, t1)
        allok &= r["ok"]
        print(f"  {ip}: windows={r['windows']} locked={r['locked']} locked_with_resets={r['locked_with_resets']} "
              f"fabric_resets_locked={r['fabric_resets_locked']} notlocked={r['notlocked']} storms={r['storms']} "
              f"rearms={r['rearms']} daemon_or_wedge={r['daemon']} -> {'OK' if r['ok'] else 'FAIL'}")
    if os.path.exists(a.sentinel):
        s = sentinel_counts(a.sentinel, t0, t1)
        allok &= s["recoveries"] == 0
        print(f"  sentinel: samples={s['samples']} zero_rate_or_rev={s['zero_rate_or_rev']} recoveries={s['recoveries']}")
    print(f"SOAK_VERDICT {'PASS' if allok else 'FAIL'}")
    return 0 if allok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
