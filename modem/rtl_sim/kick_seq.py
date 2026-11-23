#!/usr/bin/env python3
"""Per-frame offset sequence (frame_index offset) for a kick .bin, tap3 map, skew 1.
load_map()/MARK copied verbatim from t6_score_large.py (NOT imported: that module's
bottom-level `sys.exit(main())` runs on import). Usage: kick_seq.py FILE.bin [skew=1]"""
import os, sys
import numpy as np

# offsetmap/ is LIVE again at ops/offsetmap/ (sp3 task 8, 2026-09-11): the 2026-09
# cleanup dropped it while this script still loaded it, and without the map every
# offset list comes back empty -- which the gate's `all(...)` scored as PASS. It was
# restored from tag archive/pre-cleanup-2026-09-09 (the offsetmap/ dir under the
# pre-cleanup kit's now-renamed top-level dir; `git show <tag>:<path>`).
TWOJUP = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'ops')
MARK = 0x7FFF          # DDRCAP v1: the whole of record lane 2 at a frame mark
MARK_V2 = 0x4000       # DDRCAP-v2: the mark is BIT 14 of lane 2, above a 12-bit payload


def frame_marks(a):
    """Record indices of the frame marks, for EITHER DDRCAP record layout.

    v1 (the s1 sim lineage, s1_rtl_txmark and every s1_rtl_txfix_* tree derived
    from it) writes lanes 2 and 3 as {0, 0x7FFF} -- 0x7FFF IS the mark.  DDRCAP-v2,
    which every MODEL-generated tree carries (modem/fixes/build_base_tree.sh runs
    ddrcap2_inject.py), repacks those lanes: lane 2 reads 0x3023 nominally and
    0x7023 / 0xB023 at a mark, i.e. the mark is bit 14 over a 12-bit payload and
    0x7FFF never appears.  Measured on modem/rtl_sim/s1_rtl_model_tx's g3 capture:
    `0x7FFF in lane2: 0`, 106 records with bit 14 set -- exactly the frame count.

    The v1 test runs FIRST and the v2 rule is only consulted when it finds nothing,
    so a v1 capture scores through the identical path it always did (0x7FFF has bit
    14 set, so an unguarded v2 rule would also match it -- hence the ordering).
    Returns (indices, 'v1'|'v2').
    """
    m = np.flatnonzero(a[:, 2] == MARK)
    if len(m):
        return m, 'v1'
    return np.flatnonzero((a[:, 2].astype(np.uint16) & MARK_V2) != 0), 'v2'

def load_map(name):
    m = {}
    for l in open(os.path.join(TWOJUP, 'offsetmap', name)):
        if l.startswith('#'):
            continue
        w, o = l.split()
        m[int(w, 16)] = int(o)
    return m

def main():
    path = sys.argv[1]; skew = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    a = np.fromfile(path, dtype='<i2')
    a = a[:(len(a)//4)*4].reshape(-1, 4)
    m = load_map('tap3_word_to_offset.tsv')
    mk, layout = frame_marks(a)
    # The layout line is the scorer's cue: on a v2 capture the mark sits at a
    # different record relative to the payload, so the whole run carries a CONSTANT
    # offset phase that is an artefact of the layout, not a slip (txfix_gate_score.py
    # :offsets_clean normalises against the run's own baseline there, and keeps the
    # strict "every offset is 0" rule for v1).
    print(f"# LAYOUT {layout} marks={len(mk)}")
    sign = ((a[:, 0] < 0).astype(np.uint32) << 1) | (a[:, 1] < 0).astype(np.uint32)
    for fi, i in enumerate(mk):
        s = i + skew
        if s + 16 > len(a):
            break
        w = 0
        for k in range(16):
            w |= int(sign[s+k]) << (30 - 2*k)
        print(fi, m.get(w, None))

if __name__ == '__main__':
    main()
