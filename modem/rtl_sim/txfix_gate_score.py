#!/usr/bin/env python3
"""txfix_gate_score.py -- score the TXFIX sim gate matrix runs (G0-G14) against the
approved plan's pass criteria, using the UNMODIFIED kick_seq.py + tap3 map for offset
scoring and grep of the harness SUMMARY/READBACK/CEN lines for the RTL witnesses.
Host-only. Writes beat_runs/txfix_gate_summary.txt (TXFIX_GATE <id> <variant> PASS|FAIL
<evidence> lines) -- one call per already-completed run directory.
"""
import os as _os, sys as _sys; _sys.path.insert(0, _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "sro_score"))
from geometry import PAYLOAD_BITS   # geometry.py (f3072 49216; f1536 24640)
import os, re, subprocess, sys, hashlib

HERE = os.path.dirname(os.path.abspath(__file__))
BR = os.path.join(HERE, 'beat_runs')

# CRITICAL (2026-09-03, self-correction): a run's .bin and _frames.txt files exist and
# grow WHILE the sim is still in flight (fwrite/fprintf are not atomic-at-completion), so
# scoring them without checking for actual process exit silently scores partial data as
# final -- this genuinely happened here (G0/G3 F1/F2/F3 were scored PASS while their
# Vtxkick processes were still running, ~74 min CPU in). The only reliable per-run
# completion signal is the `TXFIX_GATE_RUN_EXIT=<code>` trailer that txfix_gate_launch.sh's
# wrapper prints AFTER the binary returns (independent of ledger UNITEXIT, which lags by
# up to the watcher's 30 s poll). Build gid+pfx -> expected wrapper-log path from the run
# manifest and require that trailer before treating ANY evidence from that run as final.
_RUN_LOG = {}
# The manifest's tracked home is rtl_sim/evidence/ (`modem/rtl_sim/*.txt` is
# gitignored, and `!modem/rtl_sim/evidence/**` is what un-ignores it there). Looking
# only beside this script meant that on any checkout without a hand-made copy EVERY
# row scored "incomplete -- no TXFIX_GATE_RUN_EXIT trailer yet" with the trailers
# present: an untracked file silently disabling the completion check. A local copy
# beside the script still wins, so an ad-hoc manifest can still be used.
_manifest = os.path.join(HERE, 'txfix_gate_runs.txt')
if not os.path.exists(_manifest):
    _manifest = os.path.join(HERE, 'evidence', 'txfix_gate_runs.txt')
if os.path.exists(_manifest):
    with open(_manifest) as f:
        for _l in f:
            _l = _l.strip()
            if not _l or _l.startswith('#'):
                continue
            _parts = _l.split('|')
            if len(_parts) < 7:
                continue
            _gid, _variant, _bin, _nf, _k, _sel, _pfx = _parts[:7]
            _log = os.path.join(BR, f"txfix_gate_{_gid}_{os.path.basename(_pfx)}.log")
            _RUN_LOG[(_gid, _pfx)] = _log

def run_exit_code(gid, pfx):
    """None if the run's wrapper log doesn't exist or has no RUN_EXIT trailer yet (i.e.
    NOT confirmed complete -- still running or never launched); else the exit code."""
    log = _RUN_LOG.get((gid, pfx))
    if not log or not os.path.exists(log):
        return None
    with open(log) as f:
        txt = f.read()
    m = re.search(r'TXFIX_GATE_RUN_EXIT=(-?\d+)', txt)
    return int(m.group(1)) if m else None

_PFX_TO_GID = {}
for (_g, _p), _l in _RUN_LOG.items():
    _PFX_TO_GID.setdefault(_p, _g)

def pfx_done(pfx):
    """True only if the run at this pfx has a confirmed TXFIX_GATE_RUN_EXIT trailer."""
    gid = _PFX_TO_GID.get(pfx)
    if gid is None:
        return False
    return run_exit_code(gid, pfx) is not None

def sh(cmd):
    return subprocess.run(cmd, shell=True, cwd=HERE, capture_output=True, text=True).stdout

_LAYOUT = {}

def kick_seq(binpath):
    if not os.path.exists(binpath):
        return None
    out = sh(f"python3 kick_seq.py {binpath}")
    rows = []
    for l in out.splitlines():
        m = re.match(r'# LAYOUT (v\d)', l)
        if m:
            _LAYOUT[binpath] = m.group(1)
            continue
        parts = l.split()
        if len(parts) == 2:
            fi, off = parts
            rows.append((int(fi), None if off == 'None' else int(off)))
    return rows


def offsets_clean(seq, binpath):
    """Does this run's per-frame offset sequence show NO slip?

    An offset that is the same on every frame means no frame slipped; a frame that
    departs from its neighbours is the slip these gates (G3/G4/G5/G7) exist to catch.

    v1 capture -> the historical rule verbatim: EVERY offset must be 0.
    v2 capture -> the DDRCAP-v2 mark sits at a different record relative to the
      payload, so the whole run is offset by a constant that is a property of the
      record layout and not of the modem (measured on s1_rtl_model_tx: a steady
      12264/12272 against a 12321-record frame, and it tracks kick_seq.py's `skew`
      argument 1:1).  So the baseline there is the run's own MODAL offset and the
      test is that no frame departs from it.  The rule is not relaxed for v1, where
      a uniformly non-zero offset would still fail.

    An EMPTY sequence is NEVER clean.  Before this, `all(...)` over an empty list
    returned True, so a capture kick_seq.py could not decode at all (every v2 one,
    until the fallback above) scored these rows PASS on no evidence -- G7's verdict
    was that boolean alone.  Returns (ok, detail).
    """
    if not seq:
        return False, 'vacuous -- kick_seq decoded 0 frames (no offset evidence)'
    offs = [o for _, o in seq]
    known = [o for o in offs if o is not None]
    if not known:
        return False, f'vacuous -- {len(offs)} frames, every offset unmapped (None)'
    layout = _LAYOUT.get(binpath, 'v1')
    if layout == 'v1':
        bad = [(fi, o) for fi, o in seq if o not in (0, None)]
        return (not bad), (f'layout=v1 frames={len(offs)} all_offsets_zero={not bad}'
                           + (f' departing={bad[:6]}' if bad else ''))
    base = max(set(known), key=known.count)
    bad = [(fi, o) for fi, o in seq if o is not None and o != base]
    return (not bad), (f'layout=v2 frames={len(offs)} modal_offset={base} '
                       f'no_frame_departs={not bad}'
                       + (f' departing={bad[:8]}{"..." if len(bad) > 8 else ""}' if bad else ''))

# sp3 task 9 (controller ruling, 2026-09-12): the UNFIXED, SAME-RECEIVER baseline run
# that each offset-scored row is measured against.  Task 8 round 2 established the
# fact this map encodes: with a model-lineage unfixed tree (same receiver, stock
# transmitter) the per-frame offset sequence is byte-identical between U and F3 --
# the offsets are RxSteer's lock walk, i.e. a property of the RECEIVER, not of the
# transmitter this gate is about.  The historical `all offsets zero` criterion was
# therefore measuring the wrong block on any model tree; it only looked right on the
# injected v1 lineage because THERE the unfixed offsets happen to be all zero -- and
# only on the rows where every frame DECODES.  Where kick_seq.py cannot map a frame the
# two rules differ even on the injected lineage (measured: the injected v1
# g7_latchforce_pre capture is 5 mapped / 53 unmapped, which offsets_clean() passed by
# skipping the unmapped frames and this rule fails for having no evidence).
#
# WHICH U ROW IS THE BASELINE: g0_none_U, FOR EVERY OFFSET-SCORED ROW.  The baseline
# has to be the unfixed run whose offsets are the RECEIVER's lock walk and nothing
# else -- i.e. the unfixed run with NO forcing.  g1_popabort_U_k0 and g2_fcbase3_U are
# not candidates: they are the rows that DEMONSTRATE the unfixed defect, so scoring a
# fixed run against one of them inverts the test.  Measured on this tree (sp3 task 9),
# per-frame offset sequences from kick_seq.py:
#
#   g0_none_U           (unfixed, no forcing)  12264 x90, 12272 x8   <- the lock walk
#   g1_popabort_U_k0    (unfixed, popabort)     6088 x42,  6096 x2   <- the TX SLIP
#   g3_none_F3          (fixed,   no forcing)  12264 x90, 12272 x8   = g0 on 106/106
#   g4_popabort_F3_k0   (fixed,   popabort)    12264 x42, 12272 x8   = g0 on  58/58
#   g4_popabort_F3_k6   (fixed,   popabort)    12264 x42, 12272 x8   = g0 on  58/58
#
# The fixed transmitter under popabort walks exactly as the unfixed transmitter does
# with no forcing, and the unfixed transmitter under popabort halves its offset. That
# is the property G4/G5 is about, and g0_none_U is the sequence that expresses it.
OFFSET_BASELINE = {}
for _v in ('F1', 'F2', 'F3'):
    OFFSET_BASELINE[f'beat_runs/g3_none_{_v}'] = 'beat_runs/g0_none_U'
    for _k in ('0', '6'):
        OFFSET_BASELINE[f'beat_runs/g4_popabort_{_v}_k{_k}'] = 'beat_runs/g0_none_U'
    OFFSET_BASELINE[f'beat_runs/g7_latchforce_pre_{_v}'] = 'beat_runs/g0_none_U'


def offsets_match_baseline(seq, base_seq, base_pfx, min_mapped=8, min_mapped_frac=0.25):
    """RELATIVE offset rule: the fixed run's per-frame offset sequence must EQUAL the
    unfixed same-receiver baseline's, frame index for frame index.

    WHERE EVERY FRAME DECODES, the injected v1 lineage's baseline offsets are all 0, so
    equality with the baseline is exactly `all offsets zero` and the rule reduces to the
    historical absolute one.  That reduction is NOT universal and the claim must not be
    made unqualified: on a capture kick_seq.py cannot decode, the two rules genuinely
    differ.  The measured case is `g7_latchforce_pre`, which is 5 mapped / 53 unmapped
    even on the injected v1 lineage -- `offsets_clean()` SKIPS `None` offsets and passed
    it on 5 frames, while this rule counts an unmapped frame whose baseline IS mapped as
    a difference and fails it.  That is deliberate: a row with no offset evidence must
    not score PASS.

    THREE WAYS TO BE VACUOUS, all of which FAIL rather than pass (the trap
    offsets_clean() documents: `all(...)` over an empty list is True):
      * either sequence decoded 0 frames;
      * too few common frames are MAPPED on both sides -- counting `common` alone is not
        enough, because `dict(base_seq)` stores unmapped frames as None and `None !=
        None` is False, so a row whose whole overlap is unmapped on BOTH sides would
        otherwise score equals_unfixed=True on zero evidence;
      * the mapped overlap is a negligible fraction of the shorter decoded run.

    Returns (ok, detail).
    """
    if not seq:
        return False, 'vacuous -- kick_seq decoded 0 frames (no offset evidence)'
    if not base_seq:
        return False, f'vacuous -- baseline {base_pfx} decoded 0 frames'
    base = dict(base_seq)
    common = [(fi, o) for fi, o in seq if fi in base]
    # frames that carry evidence on BOTH sides
    mapped = [(fi, o) for fi, o in common if o is not None and base[fi] is not None]
    need = max(min_mapped, int(min_mapped_frac * min(len(seq), len(base_seq))))
    if len(mapped) < need:
        return False, (f'vacuous -- only {len(mapped)} of {len(common)} common frame(s) '
                       f'are mapped on BOTH sides vs {base_pfx} (need >= {need}; '
                       f'decoded {len(seq)} / {len(base_seq)})')
    bad = [(fi, o, base[fi]) for fi, o in common if o != base[fi]]
    return (not bad), (f'rule=relative baseline={base_pfx} common={len(common)} '
                       f'mapped_both={len(mapped)} equals_unfixed={not bad}'
                       + (f' departing(frame,fixed,unfixed)={bad[:6]}'
                          f'{"..." if len(bad) > 6 else ""}' if bad else ''))


def offsets_ok(seq, bpath, pfx):
    """Score a row's offsets by the RELATIVE rule when its unfixed same-receiver
    baseline run is present and complete, else by the historical absolute/modal rule.
    The returned detail always names which rule was applied."""
    base_pfx = OFFSET_BASELINE.get(pfx)
    why = 'no baseline row configured'
    if base_pfx:
        if not pfx_done(base_pfx):
            why = f'{base_pfx} absent or has no TXFIX_GATE_RUN_EXIT trailer'
        else:
            bseq = kick_seq(binpath(base_pfx))
            if bseq:
                return offsets_match_baseline(seq, bseq, base_pfx)
            # the baseline RAN to completion but kick_seq decoded nothing from it --
            # a different fact from "absent/incomplete", and saying so is the
            # difference between "re-run the baseline" and "fix the decoder".
            why = f'{base_pfx} completed but kick_seq decoded 0 frames'
    ok, det = offsets_clean(seq, bpath)
    return ok, f'rule=absolute ({why}) {det}'


def md5(path):
    if not os.path.exists(path):
        return None
    h = hashlib.md5()
    with open(path, 'rb') as f:
        h.update(f.read())
    return h.hexdigest()

def aligned_content_check(path_a, path_b):
    """Golden-digest check, aligned on the first tap3 marker (0x7FFF) rather than a raw
    whole-file md5. Why alignment instead of a plain md5 compare: mid-run (2026-09-03,
    before all 26 gate units had actually exited), scoring partial/still-growing .bin files
    from separately-compiled per-variant binaries showed different trailing record counts
    at the snapshot moment (a self-corrected mistake -- see the ledger FINDING and
    task-5-report.md; those files were not yet complete, so that difference was an
    artifact of catching each run mid-flight, not of the RTL). Once every run had actually
    finished (confirmed via the TXFIX_GATE_RUN_EXIT trailer), the four `none` .bin files
    for this same fixed clk budget are, in fact, byte-identical by plain md5 (reviewer
    check, this commit: U/F1/F2/F3 all md5 ef08af67e8ace9562de8c34a59c9f481, 10446880
    bytes). The marker-aligned compare is kept anyway as the gate's actual implementation
    because it is the more robust check in general (a raw md5 would false-fail on any
    future run where the trailing-record-count artifact above recurs, e.g. from a
    different NF or a re-run caught at a different clk phase) -- it degrades gracefully to
    an md5-equivalent result when, as here, the two files are already the same length; any
    REAL content divergence in the overlapping region still fails it."""
    import numpy as np
    if not (os.path.exists(path_a) and os.path.exists(path_b)):
        return {'ok': False, 'reason': 'missing .bin'}
    a = np.fromfile(path_a, dtype='<i2'); a = a[:(len(a)//4)*4].reshape(-1, 4)
    b = np.fromfile(path_b, dtype='<i2'); b = b[:(len(b)//4)*4].reshape(-1, 4)
    # Marks are resolved for EITHER DDRCAP record layout -- see kick_seq.frame_marks.
    # A v2 (model-generated) tree carries no 0x7FFF at all, so before this the check
    # returned 'no marker found' against the v1 baseline and never compared content.
    import kick_seq as _ks
    ma, la = _ks.frame_marks(a)
    mb, lb = _ks.frame_marks(b)
    if len(ma) == 0 or len(mb) == 0:
        return {'ok': False, 'reason': 'no marker found in one of the two files',
                'records_a': len(a), 'records_b': len(b),
                'layout_a': la, 'layout_b': lb}
    fa, fb = int(ma[0]), int(mb[0])
    minlen = min(len(a) - fa, len(b) - fb)
    seg_a = a[fa:fa+minlen]; seg_b = b[fb:fb+minlen]
    # Lanes 2/3 are the instrument's own frame-mark/slot fields and are packed
    # DIFFERENTLY by v1 and v2, so across layouts only lanes 0/1 -- the captured I/Q,
    # which is what this gate is about -- can be compared. Same-layout pairs (every
    # injected-tree comparison) still compare the whole record, as they always did.
    lanes = slice(0, 4) if la == lb else slice(0, 2)
    shift = 0
    if la != lb:
        # The two layouts do not place the mark at the same record relative to the
        # payload (measured: the v2 mark lands one record EARLIER), so aligning
        # first-mark-to-first-mark leaves a constant whole-record phase that makes
        # every record differ. For a cross-layout pair only, the phase is resolved
        # by taking the best of a BOUNDED +/-4 record search and REPORTING it. This
        # cannot hide a real difference: a content change is not removed by a
        # constant shift, and a slip is a shift that changes during the run, which
        # still leaves the records after it differing. Same-layout pairs never take
        # this path and are compared exactly as before.
        best = None
        for sh in range(-4, 5):
            ia = max(0, sh); ib = max(0, -sh)
            n = min(len(seg_a) - ia, len(seg_b) - ib)
            if n <= 0:
                continue
            nd = int(np.sum(np.any(seg_a[ia:ia+n, lanes] != seg_b[ib:ib+n, lanes], axis=1)))
            if best is None or nd < best[1]:
                best = (sh, nd)
        shift = best[0]
        ia = max(0, shift); ib = max(0, -shift)
        minlen = min(len(seg_a) - ia, len(seg_b) - ib)
        seg_a = seg_a[ia:ia+minlen]; seg_b = seg_b[ib:ib+minlen]
    ident = bool(np.array_equal(seg_a[:, lanes], seg_b[:, lanes]))
    d = np.flatnonzero(np.any(seg_a[:, lanes] != seg_b[:, lanes], axis=1))
    ndiff = int(len(d))
    out = {'ok': ident, 'records_a': len(a), 'records_b': len(b), 'markers_a': len(ma),
           'markers_b': len(mb), 'first_marker_a': fa, 'first_marker_b': fb,
           'layout_a': la, 'layout_b': lb,
           'compared_lanes': 'all4' if la == lb else 'IQ01(layouts differ)',
           'cross_layout_shift': shift,
           'aligned_common_records': minlen, 'aligned_identical': ident,
           'differing_records_in_overlap': ndiff}
    if ndiff:
        out['first_differing_record'] = int(d[0])
        out['last_differing_record'] = int(d[-1])
    return out

def grep(path, pat):
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return [l.rstrip('\n') for l in f if re.search(pat, l)]

# Coordinator addendum (this task, after G12-in-flight): F1/F2 remove the only pop-side
# underflow guard, so MATLAB_Function1.count can wrap 0 -> 65535 (UNDER, not just OVER
# 49279) once a producer/pop-side starvation lets rd continue past 0. Extract every
# sampled `count=<n>` value from a frames.txt (covers `# nearfull ... change ... count=`,
# the FORCE line's target/pre_count, and OCC `occ=<n>`), and report min/max plus whether
# any sample sits in the near-65536 band (>=65000) -- the wrap-from-below signature -- or
# a big single-step drop (uint16 wrap of the OTHER direction, count crossing 65535->0).
def count_samples(fp):
    """Bug fix (2026-09-03, this task): earlier version mixed the FORCE line's one-off
    `pre_count=`/`target=` annotations (not part of the real time-ordered walk -- e.g.
    pre_count=24718 followed by target=49227 in FILE order, a ~24.5k "jump" between two
    values that were never adjacent in time) into the SAME list as the genuine time-ordered
    `count=`/`occ=` occupancy trace, producing false wrap-step positives (verified on
    g11_nearfull_F3: the real trace oscillates cleanly depth-1<->depth (49279<->49280 at f1536), steady-state, but the
    FORCE-line artifacts made it look like a 20k+ jump occurred). Only `count=` (nearfull
    change-detection lines) and `occ=` (CEN/OCC lines) are genuine same-timeline samples;
    `pre_count=`/`target=` are returned separately as one-off reference values, never fed
    into the wrap/jump heuristics.
    """
    if not os.path.exists(fp):
        return [], {}
    vals = []
    refs = {}
    with open(fp) as f:
        for l in f:
            for pat in (r'\bcount=(\d+)', r'\bocc=(\d+)'):
                m = re.search(pat, l)
                if m:
                    vals.append(int(m.group(1)))
            for name, pat in (('pre_count', r'\bpre_count=(\d+)'), ('target', r'\btarget=(\d+)')):
                m = re.search(pat, l)
                if m:
                    refs.setdefault(name, []).append(int(m.group(1)))
    return vals, refs

def underflow_evidence(fp):
    vals, refs = count_samples(fp)
    if not vals:
        return {'min_count': None, 'max_count': None, 'near_65536_seen': False,
                 'wrap_step_seen': False, 'samples': 0, 'refs': refs}
    near = any(v >= 65000 for v in vals)
    wrap_step = any((a - b) > 20000 for a, b in zip(vals, vals[1:])) or \
                any((b - a) > 20000 and a < 5000 for a, b in zip(vals, vals[1:]))
    return {'min_count': min(vals), 'max_count': max(vals), 'near_65536_seen': near,
            'wrap_step_seen': wrap_step, 'samples': len(vals), 'refs': refs}

def fullram_stuck(fp):
    """True if the last `# nearfull fullRAM change ... N -> M` transition in the log left
    fullRAM=1 with no further change back to 0 before the run ended (pace/dataReady frozen,
    per the coordinator's F1/F2 mechanism read)."""
    lines = grep(fp, r'# nearfull fullRAM change')
    if not lines:
        return None  # no transition observed in this window -- not evidence either way
    m = re.search(r'-> (\d)', lines[-1])
    return bool(m and m.group(1) == '1')

def frames_path(pfx):
    return os.path.join(HERE, pfx + '_frames.txt')

def binpath(pfx):
    return os.path.join(HERE, pfx + '.bin')

results = []

def emit(gid, variant, passed, evidence):
    line = f"TXFIX_GATE {gid} {variant} {'PASS' if passed else 'FAIL'} {evidence}"
    results.append(line)
    print(line)

# ---- G0: unfixed none, all offsets 0 ----
seq = kick_seq(binpath('beat_runs/g0_none_U'))
if not pfx_done('beat_runs/g0_none_U'):
    emit('G0', 'U', False, 'incomplete -- run has no TXFIX_GATE_RUN_EXIT trailer yet '
         '(.bin/frames.txt may exist and look plausible but are still being written)')
elif seq is None:
    emit('G0', 'U', False, 'no .bin (run not complete)')
else:
    nonzero = [r for r in seq if r[1] not in (0,)]
    emit('G0', 'U', len(seq) > 0 and len(nonzero) == 0,
         f"frames={len(seq)} nonzero={len(nonzero)} offsets={set(o for _,o in seq)}")

# ---- G1: unfixed popabort k=0, sustained nonzero + saw_armed_zero=1 ----
fp = frames_path('beat_runs/g1_popabort_U_k0')
summ = grep(fp, r'popabort SUMMARY')
seq = kick_seq(binpath('beat_runs/g1_popabort_U_k0'))
if not pfx_done('beat_runs/g1_popabort_U_k0'):
    emit('G1', 'U', False, 'incomplete -- no TXFIX_GATE_RUN_EXIT trailer yet')
elif not summ or seq is None:
    emit('G1', 'U', False, 'incomplete (no SUMMARY line or .bin)')
else:
    saw_armed_zero = re.search(r'saw_armed_zero=(\d)', summ[-1])
    sustained = seq and all(o not in (0, None) for _, o in seq[-5:]) if seq else False
    ok = bool(saw_armed_zero and saw_armed_zero.group(1) == '1' and sustained)
    emit('G1', 'U', ok, f"{summ[-1]} | tail_offsets={[o for _,o in seq[-5:]]}")

# ---- G2: unfixed fcbase3 (txrate), natural (self-triggered) abort: base forced to 3, then
#      the NEXT natural push-wrap must do 3->0 with no further force -- zeroEvents>=1 and
#      armedDropClk set is the falsifiable witness.
fp = frames_path('beat_runs/g2_fcbase3_U')
force = grep(fp, r'FORCE fcbase3')
summ = grep(fp, r'^# SUMMARY sel=fcbase3')
if not pfx_done('beat_runs/g2_fcbase3_U'):
    emit('G2', 'U', False, 'incomplete -- no TXFIX_GATE_RUN_EXIT trailer yet')
elif not summ:
    emit('G2', 'U', False, 'incomplete (no SUMMARY line)')
else:
    ze = re.search(r'zeroEvents=(\d+)', summ[-1])
    ad = re.search(r'armedDropClk=(-?\d+)', summ[-1])
    zeroEvents = int(ze.group(1)) if ze else None
    armedDropClk = int(ad.group(1)) if ad else None
    ok = bool(force) and zeroEvents and zeroEvents >= 1 and armedDropClk is not None and armedDropClk >= 0
    emit('G2', 'U', ok, f"force={force[:1]} | {summ[-1]}")

# ---- G3: fixed none, byte-identical .bin to G0 (golden digest), all offsets 0 ----
g0path = binpath('beat_runs/g0_none_U')
g0_done = pfx_done('beat_runs/g0_none_U')
for v in ('F1', 'F2', 'F3'):
    pfx3 = f'beat_runs/g3_none_{v}'
    p = binpath(pfx3)
    seq = kick_seq(p)
    if not g0_done or not pfx_done(pfx3):
        emit('G3', v, False, 'incomplete -- unfixed baseline and/or this variant has no '
             'TXFIX_GATE_RUN_EXIT trailer yet (do not trust a .bin/frames.txt diff while '
             'either run is still in flight)')
        continue
    if not os.path.exists(p) or not os.path.exists(g0path) or seq is None:
        emit('G3', v, False, 'incomplete (.bin missing)')
        continue
    chk = aligned_content_check(g0path, p)
    nonzero = [r for r in seq if r[1] not in (0,)]
    # `none` sel does not instrument occupancy (harness only logs OCC for sel==t0), so this
    # is expected to read samples=0 here -- reported per the coordinator's addendum so the
    # absence is explicit rather than silently missing; the real underflow evidence for
    # F1/F2 is in G8/G9 (fcbase3, CEN occ=) and G12 (nearfull).
    uf = underflow_evidence(frames_path(f'beat_runs/g3_none_{v}'))
    offs_ok, offs_detail = offsets_ok(seq, p, pfx3)
    emit('G3', v, chk.get('ok', False) and offs_ok,
         f"aligned_golden_digest={chk} frames_scored={len(seq)} nonzero={len(nonzero)} "
         f"offsets[{offs_detail}] "
         f"| underflow_evidence(none sel, uninstrumented, expect samples=0)={uf}")

# ---- G4/G5: fixed popabort k=0,6: offset 0 throughout, d3_post=0, saw_armed_zero=0 ----
for v in ('F1', 'F2', 'F3'):
    for k in ('0', '6'):
        pfx = f'beat_runs/g4_popabort_{v}_k{k}'
        fp = frames_path(pfx)
        summ = grep(fp, r'popabort SUMMARY')
        rb = grep(fp, r'popabort READBACK')
        seq = kick_seq(binpath(pfx))
        if not pfx_done(pfx):
            emit('G4/G5', f'{v}_k{k}', False, 'incomplete -- no TXFIX_GATE_RUN_EXIT trailer yet')
            continue
        if not summ or not rb or seq is None:
            emit('G4/G5', f'{v}_k{k}', False, 'incomplete (no SUMMARY/READBACK/.bin)')
            continue
        force_rb = rb[0]
        d3_post = re.search(r'd3_post=(\d)', force_rb)
        saw_az = re.search(r'saw_armed_zero=(\d)', summ[-1])
        allzero, offs_detail = offsets_ok(seq, binpath(pfx), pfx)
        ok = bool(d3_post and d3_post.group(1) == '0' and saw_az and saw_az.group(1) == '0' and allzero)
        emit('G4/G5', f'{v}_k{k}', ok, f"{force_rb} | {summ[-1]} | offsets_clean={allzero} [{offs_detail}]")

# ---- G6: latchforce, sustained nonzero + armed 0->1 (saw_armed_one=1) ----
for v in ('F1', 'F2', 'F3'):
    pfx = f'beat_runs/g6_latchforce_{v}'
    fp = frames_path(pfx)
    summ = grep(fp, r'latchforce SUMMARY')
    seq = kick_seq(binpath(pfx))
    if not pfx_done(pfx):
        emit('G6', v, False, 'incomplete -- no TXFIX_GATE_RUN_EXIT trailer yet')
        continue
    if not summ or seq is None:
        emit('G6', v, False, 'incomplete')
        continue
    saw_one = re.search(r'saw_armed_one=(\d)', summ[-1])
    sustained = seq and all(o not in (0, None) for _, o in seq[-5:])
    ok = bool(saw_one and saw_one.group(1) == '1' and sustained)
    emit('G6', v, ok, f"{summ[-1]} | tail_offsets={[o for _,o in seq[-5:]]}")

# ---- G7: latchforce_pre, offset stays 0 ----
for v in ('F1', 'F2', 'F3'):
    pfx = f'beat_runs/g7_latchforce_pre_{v}'
    fp = frames_path(pfx)
    summ = grep(fp, r'latchforce_pre SUMMARY')
    seq = kick_seq(binpath(pfx))
    if not pfx_done(pfx):
        emit('G7', v, False, 'incomplete -- no TXFIX_GATE_RUN_EXIT trailer yet')
        continue
    if not summ or seq is None:
        emit('G7', v, False, 'incomplete')
        continue
    allzero, offs_detail = offsets_ok(seq, binpath(pfx), pfx)
    emit('G7', v, allzero, f"{summ[-1]} | offsets_clean={allzero} [{offs_detail}]")

# ---- G8: F1 fcbase3 -- maxPopQuietClk, zeroEvents, pops=24640 every (steady-state) CEN line.
#      This is the decision gate: F1 is the second Vivado build (with F3) iff clean; else F2.
fp = frames_path('beat_runs/g8_fcbase3_F1')
cen = grep(fp, r'^CEN ')
summ = grep(fp, r'^# SUMMARY sel=fcbase3')
if not pfx_done('beat_runs/g8_fcbase3_F1'):
    emit('G8', 'F1', False, 'incomplete -- no TXFIX_GATE_RUN_EXIT trailer yet')
elif not summ:
    emit('G8', 'F1', False, 'incomplete (no SUMMARY line)')
else:
    steady_cen = [l for l in cen if not re.search(r'\bframe=0\b', l)]
    pops_vals = set(re.search(r'pops=(\d+)', l).group(1) for l in steady_cen if re.search(r'pops=(\d+)', l))
    all_24640 = (pops_vals == {str(PAYLOAD_BITS)})   # Data Bits FIFO pops per frame (geometry.py)
    ze = re.search(r'zeroEvents=(\d+)', summ[-1])
    mpq = re.search(r'maxPopQuietClk=(\d+)', summ[-1])
    zeroEvents = int(ze.group(1)) if ze else None
    maxPopQuietClk = int(mpq.group(1)) if mpq else None
    ok = all_24640 and zeroEvents == 0
    uf = underflow_evidence(fp)
    emit('G8', 'F1', ok,
         f"{summ[-1]} | pops_values={sorted(pops_vals)} all_pops_24640={all_24640} "
         f"zeroEvents={zeroEvents} maxPopQuietClk={maxPopQuietClk} "
         f"| underflow_evidence(CEN occ=, min/max count, near-65536, wrap-step)={uf}")

# ---- G9: F2/F3 fcbase3, zeroEvents=0 (from the harness's own SUMMARY line) ----
for v in ('F2', 'F3'):
    pfx9 = f'beat_runs/g9_fcbase3_{v}'
    fp = frames_path(pfx9)
    summ = grep(fp, r'^# SUMMARY sel=fcbase3')
    if not pfx_done(pfx9):
        emit('G9', v, False, 'incomplete -- no TXFIX_GATE_RUN_EXIT trailer yet')
        continue
    if not summ:
        emit('G9', v, False, 'incomplete (no SUMMARY line)')
        continue
    ze = re.search(r'zeroEvents=(\d+)', summ[-1])
    zeroEvents = int(ze.group(1)) if ze else None
    uf = underflow_evidence(fp)
    emit('G9', v, zeroEvents == 0,
         f"{summ[-1]} | underflow_evidence(CEN occ=, min/max count, near-65536, wrap-step)={uf}")

# ---- G10: F2/F3 frcwrap, no self-wrap ----
for v in ('F2', 'F3'):
    pfx10 = f'beat_runs/g10_frcwrap_{v}'
    fp = frames_path(pfx10)
    summ = grep(fp, r'frcwrap SUMMARY')
    if not pfx_done(pfx10):
        emit('G10', v, False, 'incomplete -- no TXFIX_GATE_RUN_EXIT trailer yet')
        continue
    if not summ:
        emit('G10', v, False, 'incomplete (no SUMMARY)')
        continue
    saw_wrap = re.search(r'saw_self_wrap=(\d)', summ[-1])
    ok = bool(saw_wrap and saw_wrap.group(1) == '0')
    emit('G10', v, ok, summ[-1])

# ---- G11: F3 nearfull, count<=49283, no wrap in EITHER direction (F3 saturates: 0 and
#      65535 rails), dataReady low while full. Coordinator addendum: report min/max count
#      and the underflow-direction fields even though F3 is expected clean both ways.
fp = frames_path('beat_runs/g11_nearfull_F3')
summ = grep(fp, r'nearfull SUMMARY')
changes = grep(fp, r'nearfull (fullRAM|armed-latch|frameCount) change')
if not pfx_done('beat_runs/g11_nearfull_F3'):
    emit('G11', 'F3', False, 'incomplete -- no TXFIX_GATE_RUN_EXIT trailer yet')
elif not summ:
    emit('G11', 'F3', False, 'incomplete')
else:
    uf = underflow_evidence(fp)
    maxcount = uf['max_count']
    overshoot = (maxcount - 49279) if maxcount and maxcount > 49279 else 0
    stuck = fullram_stuck(fp)
    ok = (maxcount is not None and maxcount <= 49283 and not uf['near_65536_seen']
          and not uf['wrap_step_seen'])
    emit('G11', 'F3', ok,
         f"{summ[-1]} | overshoot_past_49279={overshoot} changes={len(changes)} "
         f"fullRAM_stuck_at_end={stuck} | underflow_evidence(min/max count, near-65536, "
         f"wrap-step; F3 saturates so both directions must be clean)={uf}")

# ---- G12: F1/F2 nearfull, OVERrun (>49279) is the already-known runaway; coordinator
#      addendum adds the UNDER-side: F1/F2 removed the only pop-side underflow guard, so
#      count can also wrap 0 -> 65535 once a pop-side/producer starvation lets rd continue
#      past 0 -- report min_count, whether any sample sits near 65536 (>=65000), whether a
#      wrap-magnitude step was seen, and whether fullRAM ends stuck (pace/dataReady frozen).
#      G12 PASSES if the (over or under) runaway is present -- this documents the KNOWN
#      unfixed-count-guard defect, it is not a fail of the harness.
for v in ('F1', 'F2'):
    pfx12 = f'beat_runs/g12_nearfull_{v}'
    fp = frames_path(pfx12)
    summ = grep(fp, r'nearfull SUMMARY')
    if not pfx_done(pfx12):
        emit('G12', v, False, 'incomplete -- no TXFIX_GATE_RUN_EXIT trailer yet')
        continue
    if not summ:
        emit('G12', v, False, 'incomplete')
        continue
    uf = underflow_evidence(fp)
    stuck = fullram_stuck(fp)
    overrun = bool(uf['max_count'] is not None and uf['max_count'] > 49279)
    underrun = bool(uf['near_65536_seen'] or uf['wrap_step_seen'])
    runaway = overrun or underrun
    emit('G12', v, runaway,
         f"{summ[-1]} | runaway_present={runaway} overrun_over_49279={overrun} "
         f"underrun_toward_65536={underrun} fullRAM_stuck_at_end={stuck} "
         f"| underflow_evidence(min/max count, near-65536, wrap-step)={uf}")

# ---- G13: F3 producer throttles -- derived from the G11 nearfull-F3 log (same run, no
#      separate sim needed): pushes/frame must NOT double while fullRAM is asserted, and
#      dataReady must go low while fullRAM (already checked structurally in G11's
#      `nearfull fullRAM change` lines -- this gate reports the push-rate side).
fp = frames_path('beat_runs/g11_nearfull_F3')
occ = grep(fp, r'^OCC ')
if not pfx_done('beat_runs/g11_nearfull_F3'):
    emit('G13', 'F3', False, 'incomplete -- derived from G11, which has no '
         'TXFIX_GATE_RUN_EXIT trailer yet')
elif not os.path.exists(fp):
    emit('G13', 'F3', False, 'incomplete (derived from G11 log, which is missing)')
else:
    pushes = [int(m.group(1)) for l in occ for m in [re.search(r'push=(\d+)', l)] if m]
    doubled = any(p2 - p1 > 30000 for p1, p2 in zip(pushes, pushes[1:])) if len(pushes) > 1 else False
    ok = not doubled
    emit('G13', 'F3', ok, f"push_pointer_seq={pushes} doubled_push_rate_seen={doubled}")

# ---- G14: lint, all variants clean (rerun of txfix_lint.sh, no sim) ----
for v in ('F1', 'F2', 'F3'):
    r = subprocess.run(f"bash txfix_lint.sh {v}", shell=True, cwd=HERE, capture_output=True, text=True)
    ok = (r.returncode == 0) and bool(re.search(rf'TXFIX_LINT_OK_{v}_', r.stdout + r.stderr))
    tag = re.findall(rf'TXFIX_LINT_OK_{v}_\S+', r.stdout + r.stderr)
    emit('G14', v, ok, f"exit={r.returncode} tags={tag}")

with open(os.path.join(BR, 'txfix_gate_summary.txt'), 'w') as f:
    f.write('\n'.join(results) + '\n')
print(f"\nwrote {len(results)} lines to beat_runs/txfix_gate_summary.txt")
