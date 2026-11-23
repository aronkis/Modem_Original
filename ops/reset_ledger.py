#!/usr/bin/env python3
"""reset_ledger.py -- who resets the modem, how often, and did the peer make them do it.

"The link keeps resetting" is FOUR different things, and only one of them is the modem:
  1. fabric rstCS       0x150: the CFO step-change detector resetting the fine carrier loop
  2. watchdog re-arm    ops/lock_watchdog.sh FULL RE-ARM = two 0x000 soft resets + 0x110 pulse
  3. sentinel recovery  ~/modem-status/delivery_sentinel.sh running a full bring-up
  4. bring-up double-tap two 0x000 per arm, by design
This reads the records those layers already leave behind -- no board contact -- and lays them out
per hour per board so the layers can be told apart and the cross-board COUPLING can be measured
(a re-arm silences that board's TX; the peer's coarse estimator storms on empty air; the peer's
watchdog re-arms it: measured 60-94 % of 148's re-arms within 60 s of a 146 re-arm, 2026-09-29).

INPUTS
  ~/modem-status/wdlog_<ip>_<YYYYMMDD>_<HHMMSS>.txt   the sentinel's snapshot of a board's
        /dev/shm/watchdog.log, taken just before a recovery. Lines are BOARD-LOCAL time of day:
            [wd HH:MM:SS] LOCKED (drstcs=N dpkts=N lvl=N)          one per 5 s window
            [wd HH:MM:SS] NOT-LOCKED #k/N (drstcs=N dpkts=N lvl=N)
            [wd HH:MM:SS] FULL RE-ARM (...)
            [wd HH:MM:SS] qpsk_tun dead -> relaunch: ...
            [wd HH:MM:SS] DELIVERY-WEDGE / BYTE-PLANE WEDGE / BIST-WEDGE (...)
            [wd] === STARTING HH:MM:SS pid=N ===
        The boards' clocks are not nemo's (146 reads +5 h). The LAST [wd] line was written at the
        snapshot instant, so every line is anchored to the filename's wall time by its distance
        from that last line (day wraps handled). --live FILE --ip IP anchors a freshly pulled
        watchdog.log at its mtime instead.
  ~/modem-status/sentinel.log   'WEDGE detected' / 'recovering (post-reboot' / 'recovery chain done'

  ops/reset_ledger.py [--wdlog-dir D] [--sentinel F] [--since YYYY-MM-DD] [--daily]
                      [--coupling] [--live FILE --ip IP [--live FILE --ip IP]]
"""
import argparse
import collections
import datetime as dt
import glob
import os
import re
import sys

WD_RE = re.compile(r"^\[wd (\d\d):(\d\d):(\d\d)\] (.*)$")
FN_RE = re.compile(r"wdlog_(\d+\.\d+\.\d+\.\d+)_(\d{8})_(\d{6})\.txt$")
STORM = 100        # lock_watchdog.sh STORM_THRESH: drstcs/5 s at or above this is a reset storm
COUPLE_S = 60      # a re-arm within this many seconds of the PEER's re-arm counts as coupled


def kind_of(rest):
    if rest.startswith("FULL RE-ARM"):
        return "rearm"
    if rest.startswith("NOT-LOCKED"):
        return "notlocked"
    if rest.startswith("LOCKED"):
        return "locked"
    if rest.startswith("qpsk_tun dead"):
        return "daemon_dead"
    if "WEDGE" in rest.split("(")[0]:
        return "host_wedge"
    return "other"


def parse_wd_lines(lines):
    """-> list of (t_rel_s, kind, drst, dpkt). t_rel is seconds since the first [wd] line, with
    board-local day wraps folded in (a backwards jump of more than an hour is a new day)."""
    out, day, prev = [], 0, None
    for ln in lines:
        m = WD_RE.match(ln.rstrip("\n"))
        if not m:
            continue
        tod = int(m[1]) * 3600 + int(m[2]) * 60 + int(m[3])
        if prev is not None and tod < prev - 3600:
            day += 1
        prev = tod
        rest = m[4]
        d = re.search(r"drstcs=(\d+)", rest)
        p = re.search(r"dpkts=(\d+)", rest)
        out.append((day * 86400 + tod, kind_of(rest), int(d[1]) if d else None, int(p[1]) if p else None))
    if not out:
        return []
    t0 = out[0][0]
    return [(t - t0, k, d, p) for t, k, d, p in out]


def anchor(events, end_wall):
    """Anchor relative events so the LAST one lands at end_wall (a datetime)."""
    if not events:
        return []
    last = events[-1][0]
    return [(end_wall - dt.timedelta(seconds=last - t), k, d, p) for t, k, d, p in events]


def load_snapshot(path):
    """-> (ip, snapshot_wall, events anchored to wall time, board_clock_offset_hours)."""
    m = FN_RE.search(os.path.basename(path))
    if not m:
        raise ValueError(f"not a wdlog snapshot name: {path}")
    ip = m[1]
    wall = dt.datetime.strptime(m[2] + m[3], "%Y%m%d%H%M%S")
    lines = open(path, errors="replace").read().splitlines()
    rel = parse_wd_lines(lines)
    # board clock offset, for the record: last [wd] time-of-day vs the snapshot's wall time-of-day
    off = None
    for ln in reversed(lines):
        mm = WD_RE.match(ln)
        if mm:
            tod = int(mm[1]) * 3600 + int(mm[2]) * 60 + int(mm[3])
            wtod = wall.hour * 3600 + wall.minute * 60 + wall.second
            off = round(((tod - wtod + 43200) % 86400 - 43200) / 3600.0)
            break
    return ip, wall, anchor(rel, wall), off


def load_live(path, ip, end_wall=None):
    lines = open(path, errors="replace").read().splitlines()
    if end_wall is None:
        end_wall = dt.datetime.fromtimestamp(os.path.getmtime(path))
    return ip, end_wall, anchor(parse_wd_lines(lines), end_wall), None


def parse_sentinel(path):
    """-> list of (wall datetime, 'wedge'|'postreboot'|'done')."""
    out = []
    for ln in open(path, errors="replace"):
        m = re.match(r"^(\d{4}-\d\d-\d\d)_(\d\d:\d\d:\d\d) (.*)$", ln.rstrip("\n"))
        if not m:
            continue
        t = dt.datetime.strptime(m[1] + " " + m[2], "%Y-%m-%d %H:%M:%S")
        rest = m[3]
        if rest.startswith("WEDGE detected"):
            out.append((t, "wedge"))
        elif "recovering (post-reboot" in rest:
            out.append((t, "postreboot"))
        elif rest.startswith("recovery chain done"):
            out.append((t, "done"))
    return out


def bucket(t, daily):
    return t.replace(minute=0, second=0, microsecond=0, **({"hour": 0} if daily else {}))


def ledger(events, daily=False):
    """events: anchored (wall, kind, drst, dpkt) -> {bucket: counters}."""
    L = collections.defaultdict(lambda: collections.Counter())
    for t, k, d, p in events:
        b = bucket(t, daily)
        c = L[b]
        if k == "locked":
            c["locked"] += 1
            if d:
                c["locked_with_resets"] += 1
                c["fabric_resets_locked"] += d
        elif k == "notlocked":
            c["notlocked"] += 1
            if d is not None:
                c["fabric_resets_notlocked"] += d
                if d >= STORM:
                    c["storms"] += 1
        elif k == "rearm":
            c["rearms"] += 1
        elif k == "daemon_dead":
            c["daemon_restarts"] += 1
        elif k == "host_wedge":
            c["host_wedges"] += 1
    return L


def coupling(rearms_a, rearms_b, win=COUPLE_S):
    """How many of A's re-arms fall within win seconds of any of B's."""
    b = sorted(rearms_b)
    n = 0
    for a in rearms_a:
        import bisect
        i = bisect.bisect_left(b, a)
        for j in (i - 1, i):
            if 0 <= j < len(b) and abs((a - b[j]).total_seconds()) <= win:
                n += 1
                break
    return n


def dedupe(snapshots):
    """Snapshots overlap (each is the log since the previous recovery restarted the watchdog, but a
    restart truncates, so overlap is rare). Merge by (ip) and drop exact duplicate timestamps."""
    by = collections.defaultdict(dict)
    for ip, wall, ev, off in snapshots:
        for e in ev:
            by[ip][(e[0], e[1])] = e
    return {ip: sorted(v.values()) for ip, v in by.items()}


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--wdlog-dir", default=os.path.expanduser("~/modem-status"))
    ap.add_argument("--sentinel", default=os.path.expanduser("~/modem-status/sentinel.log"))
    ap.add_argument("--since", default=None)
    ap.add_argument("--daily", action="store_true")
    ap.add_argument("--coupling", action="store_true", help="per-snapshot cross-board re-arm coincidence")
    ap.add_argument("--live", action="append", default=[], help="a freshly pulled watchdog.log (pair with --ip)")
    ap.add_argument("--ip", action="append", default=[])
    ap.add_argument("--no-snapshots", action="store_true")
    a = ap.parse_args(argv)
    since = dt.datetime.strptime(a.since, "%Y-%m-%d") if a.since else None

    snaps = []
    if not a.no_snapshots:
        for f in sorted(glob.glob(os.path.join(a.wdlog_dir, "wdlog_*.txt"))):
            try:
                snaps.append(load_snapshot(f))
            except ValueError:
                continue
    for f, ip in zip(a.live, a.ip):
        snaps.append(load_live(f, ip))
    if since:
        snaps = [(ip, w, [e for e in ev if e[0] >= since], off) for ip, w, ev, off in snaps]
    offs = sorted({(ip, off) for ip, _, _, off in snaps if off is not None})
    print("board clock offsets vs nemo (hours), from the snapshots:", ", ".join(f"{ip}:{off:+d}" for ip, off in offs) or "n/a")

    per_ip = dedupe(snaps)
    recov = [x for x in (parse_sentinel(a.sentinel) if os.path.exists(a.sentinel) else []) if not since or x[0] >= since]
    rec_b = collections.Counter(bucket(t, a.daily) for t, k in recov if k in ("wedge", "postreboot"))

    print(f"\nRESET LEDGER per {'day' if a.daily else 'hour'} per board (wall clock). fabric = 0x150 deltas summed over the "
          f"watchdog's 5 s windows; 'lockedR' = LOCKED windows that still carried resets; storms = NOT-LOCKED windows with >= {STORM}.")
    hdr = f"{'bucket':16s} {'ip':>5s} {'locked':>6s} {'lockedR':>7s} {'fabric(L)':>9s} {'notlock':>7s} {'fabric(NL)':>10s} {'storms':>6s} {'rearms':>6s} {'daemon':>6s} {'hostwdg':>7s} {'sentinel':>8s}"
    print(hdr)
    allb = set()
    ledgers = {ip: ledger(ev, a.daily) for ip, ev in per_ip.items()}
    for L in ledgers.values():
        allb |= set(L)
    allb |= set(rec_b)
    for b in sorted(allb):
        for ip in sorted(ledgers):
            c = ledgers[ip].get(b)
            if not c:
                continue
            print(f"{b:%Y-%m-%d %H:%M} {ip.split('.')[-1]:>5s} {c['locked']:6d} {c['locked_with_resets']:7d} {c['fabric_resets_locked']:9d} "
                  f"{c['notlocked']:7d} {c['fabric_resets_notlocked']:10d} {c['storms']:6d} {c['rearms']:6d} {c['daemon_restarts']:6d} {c['host_wedges']:7d} {rec_b.get(b, 0):8d}")

    # totals
    print("\nTOTALS")
    for ip, ev in sorted(per_ip.items()):
        c = collections.Counter()
        for L in [ledger(ev, daily=True)]:
            for v in L.values():
                c.update(v)
        span = (ev[-1][0] - ev[0][0]).total_seconds() / 3600 if len(ev) > 1 else 0
        print(f"  {ip}: {span:.1f} h of watchdog record; locked {c['locked']} windows, {c['locked_with_resets']} with resets "
              f"({100*c['locked_with_resets']/max(c['locked'],1):.1f} %), fabric resets while locked {c['fabric_resets_locked']}; "
              f"storms {c['storms']}; re-arms {c['rearms']} ({c['rearms']/max(span,1e-9):.1f}/h); daemon restarts {c['daemon_restarts']}; host wedges {c['host_wedges']}")
    print(f"  sentinel recoveries: {sum(1 for t,k in recov if k=='wedge')} wedge, {sum(1 for t,k in recov if k=='postreboot')} post-reboot")

    if a.coupling:
        print(f"\nCROSS-BOARD COUPLING: re-arms within {COUPLE_S} s of a re-arm on the PEER (per snapshot pair)")
        pairs = collections.defaultdict(dict)
        for ip, wall, ev, off in snaps:
            pairs[wall][ip] = [t for t, k, d, p in ev if k == "rearm"]
        print(f"{'snapshot':17s} {'148':>5s} {'146':>5s} {'148 near 146':>14s} {'146 near 148':>14s}")
        for wall in sorted(pairs):
            p = pairs[wall]
            A = p.get("10.0.0.148", []); B = p.get("10.0.0.146", [])
            if not A and not B:
                continue
            ca, cb = coupling(A, B), coupling(B, A)
            print(f"{wall:%Y-%m-%d %H:%M} {len(A):5d} {len(B):5d} {ca:6d} ({100*ca/max(len(A),1):3.0f}%) {cb:6d} ({100*cb/max(len(B),1):3.0f}%)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
