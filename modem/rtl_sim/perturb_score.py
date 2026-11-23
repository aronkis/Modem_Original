#!/usr/bin/env python3
"""perturb_score.py <prefix>_pert.txt [...] -- score sim_sro_perturb runs.

Per run: resets before / during / after the perturbation window, frame syncs per frame (1 expected),
the coarse-estimate median before and after, and FRAMES TO RE-LOCK after the window ends: the first
frame from which three consecutive frames each carry a frame sync and the coarse estimate sits within
3000 units of its pre-perturbation median. 'pert' column: bit 1 = fade, bit 2 = dropout.
"""
import statistics
import sys


def load(p):
    rows = []
    for ln in open(p):
        if ln.startswith("#"):
            continue
        f = ln.strip().split(",")
        if len(f) < 11:
            continue
        rows.append(dict(frame=int(f[0]), dp=int(f[3]), db=int(f[5]), drst=int(f[8]), cfc=int(f[9]), pert=int(f[10])))
    return rows


def score(p):
    r = load(p)
    if not r:
        return f"{p}: no rows"
    pert = [x for x in r if x["pert"]]
    if pert:
        p0, p1 = pert[0]["frame"], pert[-1]["frame"]
    else:
        p0 = p1 = None
    lock_from = 8   # ignore acquisition
    pre = [x for x in r if x["frame"] >= lock_from and (p0 is None or x["frame"] < p0)]
    dur = [x for x in r if p0 is not None and p0 <= x["frame"] <= p1]
    post = [x for x in r if p1 is not None and x["frame"] > p1]
    cm = statistics.median([x["cfc"] for x in pre]) if pre else float("nan")
    relock = None
    if post:
        for i in range(len(post) - 2):
            w = post[i:i + 3]
            if all(x["dp"] >= 1 and abs(x["cfc"] - cm) < 3000 for x in w):
                relock = post[i]["frame"] - p1; break
    def rs(seg): return sum(x["drst"] for x in seg)
    def sync(seg): return sum(1 for x in seg if x["dp"] >= 1)
    post30 = post[:40]
    out = (f"{p.split('/')[-1].replace('_pert.txt',''):28s} frames={len(r):4d} "
           f"resets pre={rs(pre):4d} during={rs(dur):5d} post={rs(post):5d} | syncs pre={sync(pre)}/{len(pre)} post40={sync(post30)}/{len(post30)} "
           f"| cfc pre={cm:+.0f} post={statistics.median([x['cfc'] for x in post[-20:]]) if len(post)>=5 else float('nan'):+.0f} "
           f"| relock_frames={'never' if post and relock is None else relock}")
    return out


def gate(p, min_sync=0.99, max_relock=5):
    """Gate verdict for one run: (ok, reason). Frame syncs outside the perturbation window >= min_sync
    of frames (from frame 8), and -- if there was a window -- re-lock within max_relock frames. A run
    that never re-locks (the latch) fails."""
    r = load(p)
    if not r:
        return False, "no rows"
    pert = [x for x in r if x["pert"]]
    p0 = pert[0]["frame"] if pert else None
    p1 = pert[-1]["frame"] if pert else None
    outside = [x for x in r if x["frame"] >= 8 and (p0 is None or x["frame"] < p0 or x["frame"] > p1)]
    cm = statistics.median([x["cfc"] for x in r if x["frame"] >= 8 and (p0 is None or x["frame"] < p0)])
    relock = None
    if p1 is not None:
        post = [x for x in r if x["frame"] > p1]
        for i in range(len(post) - 2):
            if all(x["dp"] >= 1 and abs(x["cfc"] - cm) < 3000 for x in post[i:i + 3]):
                relock = post[i]["frame"] - p1; break
        # frames lost to the re-lock itself are expected; judge the sync ratio after it
        if relock is not None:
            outside = [x for x in outside if x["frame"] < p0 or x["frame"] >= p1 + relock]
    syncs = sum(1 for x in outside if x["dp"] >= 1)
    ratio = syncs / len(outside) if outside else 0.0
    if p1 is not None and relock is None:
        return False, f"LATCHED: never re-locked after the window ending at frame {p1} (syncs after={sum(1 for x in r if x['frame']>p1 and x['dp']>=1)})"
    if ratio < min_sync:
        return False, f"syncs {syncs}/{len(outside)} = {ratio:.3f} < {min_sync}"
    if relock is not None and relock > max_relock:
        return False, f"relock {relock} frames > {max_relock}"
    return True, f"syncs {syncs}/{len(outside)} relock={'-' if relock is None else relock}"


def tilt_budget(p, max_bias=30.0, max_noise=200.0, min_syncs=1.0, first=8, bias_center=0.0):
    """Tilt-corrector budget (spec 2026-10-03-rx-tilt-equaliser-design.md sec. 5): from frame `first`, frame
    syncs >= min_syncs of frames, |median coarse estimate - bias_center| < max_bias units, median |delta cfc| <
    max_noise. The clean-air regime of FORWARD_LINK_2026-10-01.md sec. 9/11 (bias ~ -10..-30, noise 2..200).
    bias_center is 0 for bank stimulus (no frequency offset) and the LO plan's healthy estimate for LIVE captures
    (forward +20 kHz plan ~ -3400 units: cfc-median-is-a-leg-health-indicator), where a nonzero median is the
    plan, not a bias."""
    import os
    rows = [l.split(",") for l in open(p) if not l.startswith("#")]
    sel = [(int(r[3]), int(r[9])) for r in rows if int(r[0]) >= first]
    n = len(sel); syncs = sum(1 for dp, _ in sel if dp >= 1)
    cfc = [c for _, c in sel]
    bias = statistics.median(cfc) if n else float("nan")
    noise = statistics.median(abs(b - a) for a, b in zip(cfc, cfc[1:])) if n > 1 else float("nan")
    ok = n > 0 and syncs >= min_syncs * n and abs(bias - bias_center) < max_bias and noise < max_noise
    return ok, f"{'PASS' if ok else 'FAIL'} {os.path.basename(p).replace('_pert.txt','')} syncs={syncs}/{n} bias={bias:+.0f} (center {bias_center:+.0f}, tol {max_bias:.0f}) noise={noise:.0f}"


if __name__ == "__main__":
    args = sys.argv[1:]
    if args and args[0] == "--tilt-budget":
        rc = 0; min_syncs = 1.0; center = 0.0; max_bias = 30.0; files = []
        it = iter(args[1:])
        for a in it:
            if a == "--min-syncs": min_syncs = float(next(it))
            elif a == "--bias-center": center = float(next(it))
            elif a == "--max-bias": max_bias = float(next(it))
            else: files.append(a)
        for p in files:
            ok, line = tilt_budget(p, min_syncs=min_syncs, bias_center=center, max_bias=max_bias)
            print(line); rc |= 0 if ok else 1
        sys.exit(rc)
    if args and args[0] == "--gate":
        rc = 0
        for p in args[1:]:
            ok, why = gate(p)
            print(f"{'PASS' if ok else 'FAIL'} {p.split('/')[-1].replace('_pert.txt','')}: {why}")
            rc |= 0 if ok else 1
        sys.exit(rc)
    for p in args:
        print(score(p))
