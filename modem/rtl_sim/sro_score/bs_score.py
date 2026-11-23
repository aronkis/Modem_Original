#!/usr/bin/env python3
"""bs_score.py -- score the RXFIX_BS sim gate against its pre-registration.

Pre-registration: docs/evidence/comb/RXFIX_BS1_SIM_GATE.md sections 3-6.  Every row below
names the prediction id, the predicted value and the measured one; nothing here decides
what the prediction *was*.

FAIL CLOSED, three ways:
  * a missing leg is a FAIL, never a skip;
  * BS_CNT[7:0] (the `bs_rsv` column) must be 0 in every record and the three order
    statistics must be <= 191, or the leg is DECODE_FAIL and no other row from it is
    quoted -- the rule that caught the R4D word swap (W1_REGMAP sec 6-R4D.2);
  * a census with fewer than 2 records is a FAIL (the leg died before it could count).

Usage: bs_score.py [dir]      (default: this file's directory)
"""
from geometry import WPP   # delivered words per frame (f3072 382; f1536 191)
import os, sys

COLS = None
ORDER_STATS = ('bs_trunc_last', 'bs_trunc_min', 'bs_trunc_max')


def load(d, pfx):
    """Return (records, err).  records is a list of dicts of ints."""
    p = os.path.join(d, pfx + '_census.txt')
    if not os.path.exists(p):
        return None, 'no %s_census.txt' % pfx
    recs, cols = [], None
    for line in open(p):
        line = line.strip()
        if not line:
            continue
        if line.startswith('#'):
            cols = line[1:].strip().split(',')
            continue
        if cols is None:
            return None, 'census has no header'
        v = line.split(',')
        if len(v) != len(cols):
            continue                     # a torn last line from a killed leg
        recs.append({c: int(x) for c, x in zip(cols, v)})
    if len(recs) < 2:
        return None, 'census has %d records (need >= 2)' % len(recs)
    return recs, None


def decode_check(recs):
    for i, r in enumerate(recs):
        if r['bs_rsv'] != 0:
            return 'DECODE_FAIL: BS_CNT[7:0] = %d (must be hard 0) in record %d' % (r['bs_rsv'], i)
        for c in ORDER_STATS:
            if r[c] > WPP:
                return 'DECODE_FAIL: %s = %d > WPP in record %d' % (c, r[c], i)
    return None


def read_file(d, name):
    p = os.path.join(d, name)
    return open(p, 'rb').read() if os.path.exists(p) else None


class Score:
    def __init__(self):
        self.rows = []

    def add(self, tag, ok, pred, meas):
        self.rows.append((tag, bool(ok), pred, meas))

    def report(self):
        w = max(len(t) for t, _, _, _ in self.rows)
        npass = 0
        for t, ok, pred, meas in self.rows:
            npass += ok
            print('%-4s %-*s  predicted %-34s measured %s'
                  % ('PASS' if ok else 'FAIL', w, t, pred, meas))
        print('\nBS_GATE %d/%d PASS' % (npass, len(self.rows)))
        return npass == len(self.rows)


def main(d):
    s = Score()
    leg = {}
    errs = {}
    for pfx in ('bsw_p000', 'bsb_p000', 'bsb_m10', 'bsb_p10',
                'bs1_p000', 'bs1_m10', 'bs1_p10',
                'bs1_k1536', 'bs1_k1024', 'bs1_dA', 'bs1_dB'):
        r, e = load(d, pfx)
        if r is not None:
            e = decode_check(r)
        leg[pfx], errs[pfx] = (None, e) if e else (r, None)

    # ---- section 3: identity -----------------------------------------------------
    for tag, base, bs in (('I1', 'bsb_p000', 'bs1_p000'),
                          ('I2', 'bsb_m10', 'bs1_m10'),
                          ('I3', 'bsb_p10', 'bs1_p10')):
        a = read_file(d, base + '_frames.txt'); b = read_file(d, bs + '_frames.txt')
        s.add('%s %s frames == %s frames' % (tag, bs, base),
              a is not None and a == b,
              'byte-identical', 'identical' if (a and a == b)
              else 'MISSING' if (a is None or b is None) else 'DIFFER')
    ok4 = True; d4 = []
    for base, bs in (('bsb_p000', 'bs1_p000'), ('bsb_m10', 'bs1_m10'), ('bsb_p10', 'bs1_p10')):
        a = read_file(d, base + '_res.txt'); b = read_file(d, bs + '_res.txt')
        # the first line names the iq/nsamp only; the rest are the measured quantities
        if a is None or b is None:
            ok4 = False; d4.append(bs + ':MISSING'); continue
        if a.split(b'\n', 1)[1] != b.split(b'\n', 1)[1]:
            ok4 = False; d4.append(bs + ':DIFFER')
    s.add('I4 all three _res.txt bodies equal', ok4, 'identical',
          'identical' if ok4 else ','.join(d4))
    a = read_file(d, 'bsw_p000_frames.txt'); b = read_file(d, 'b_p000_frames.txt')
    s.add('I5 bsw_p000 frames == banked b_p000 frames',
          a is not None and a == b, 'byte-identical',
          'identical' if (a and a == b) else 'MISSING' if (a is None or b is None) else 'DIFFER')
    logs = [f for f in os.listdir(d) if f.startswith('bs_') and f.endswith('.log')]
    banner = sum('WRAPBS_FILE wrap_byte_bs.v t46' in open(os.path.join(d, f)).read()
                 for f in logs)
    prereg = sum('BS_PREREG_MD5 ' in open(os.path.join(d, f)).read() for f in logs)
    s.add('I6 EVERY leg log carries the wrapper banner and a prereg md5',
          len(logs) >= 11 and banner == len(logs) and prereg == len(logs),
          'all of them', '%d/%d banner, %d/%d prereg' % (banner, len(logs), prereg, len(logs)))

    # ---- section 4: the counters vs the harness recount ---------------------------
    for pfx in ('bs1_p000', 'bs1_m10', 'bs1_p10'):
        r = leg[pfx]
        if r is None:
            for t in 'C1 C2 C3 C4 C5 C6 C7 C8 C9 C10'.split():
                s.add('%s %s' % (t, pfx), False, 'scored', errs[pfx])
            continue
        f = r[-1]
        s.add('C1 %s bs_words == h_push' % pfx, f['bs_words'] == f['h_push'],
              'equal', '%d vs %d' % (f['bs_words'], f['h_push']))
        s.add('C2 %s bs_push == bs_words' % pfx, f['bs_push'] == f['bs_words'],
              'equal', '%d vs %d' % (f['bs_push'], f['bs_words']))
        s.add('C3 %s bs_drop == 0, bs_dropmax == 0' % pfx,
              f['bs_drop'] == 0 and f['bs_dropmax'] == 0, '0, 0',
              '%d, %d' % (f['bs_drop'], f['bs_dropmax']))
        occ = f['bs_push'] - f['bs_pop'] - f['bs_drop']
        s.add('C4 %s occupancy in [0,4095]' % pfx, 0 <= occ <= 4095, '0..4095', occ)
        s.add('C5 %s |bs_pop - h_acc| <= 8' % pfx, abs(f['bs_pop'] - f['h_acc']) <= 8,
              '<= 8', f['bs_pop'] - f['h_acc'])
        s.add('C6 %s |bs_markpush - bs_lasts| <= 1' % pfx,
              abs(f['bs_markpush'] - f['bs_lasts']) <= 1, '<= 1',
              f['bs_markpush'] - f['bs_lasts'])
        s.add('C7 %s ck_frames == h_accmark' % pfx, f['ck_frames'] == f['h_accmark'],
              'equal', '%d vs %d' % (f['ck_frames'], f['h_accmark']))
        lo = WPP * f['bs_lasts']
        hi = lo + (WPP-1) * f['bs_trunc'] + (WPP-1)
        s.add('C8a %s bs_trunc == 0' % pfx, f['bs_trunc'] == 0, '0', f['bs_trunc'])
        s.add('C8b %s %d <= bs_words <= %d' % (pfx, lo, hi), lo <= f['bs_words'] <= hi,
              '%d..%d' % (lo, hi), f['bs_words'])
        s.add('C9 %s |bs_starts - bs_lasts - bs_trunc| <= 1' % pfx,
              abs(f['bs_starts'] - f['bs_lasts'] - f['bs_trunc']) <= 1, '<= 1',
              f['bs_starts'] - f['bs_lasts'] - f['bs_trunc'])
        s.add('C10 %s fail-closed fields' % pfx, True, 'rsv 0, stats <= WPP', 'ok')

    # ---- C11: the baseline binary's harness recount is the same run ---------------
    a11, b11 = leg['bsb_p000'], leg['bs1_p000']
    if a11 is None or b11 is None:
        s.add('C11 bsb_p000 harness recount == bs1_p000', False, 'scored',
              errs['bsb_p000'] or errs['bs1_p000'])
    else:
        fa, fb = a11[-1], b11[-1]
        cols = ('h_push', 'h_acc', 'h_accmark', 'ck_frames')
        eq = all(fa[c] == fb[c] for c in cols)
        s.add('C11 bsb_p000 h_push/h_acc/h_accmark/ck_frames == bs1_p000', eq,
              'equal', ' '.join('%s %d/%d' % (c, fa[c], fb[c]) for c in cols))

    # ---- section 5: the truncation control ----------------------------------------
    for tag, pfx, words, q24up in (('T1/T2', 'bs1_k1536', 167, True),
                                   ('T3', 'bs1_k1024', 175, False)):
        r = leg[pfx]
        if r is None:
            s.add('%s %s' % (tag, pfx), False, 'scored', errs[pfx]); continue
        f = r[-1]
        got = (f['bs_trunc_last'], f['bs_trunc_min'], f['bs_trunc_max'])
        s.add('%s %s trunc order stats == %d' % (tag, pfx, words),
              got == (words, words, words), '(%d,%d,%d)' % (words, words, words), str(got))
        s.add('%s %s bs_trunc advances' % (tag, pfx), f['bs_trunc'] > 0, '> 0', f['bs_trunc'])
        s.add('%s %s bs_q24 %s' % (tag, pfx, 'advances' if q24up else 'STAYS 0'),
              (f['bs_q24'] > 0) == q24up, '> 0' if q24up else '== 0', f['bs_q24'])
    for pfx in ('bs1_k1536', 'bs1_k1024'):
        r = leg[pfx]; p0 = leg['bs1_p000']
        if r is None or p0 is None:
            s.add('T4/T5/T6 %s' % pfx, False, 'scored', errs[pfx] or errs['bs1_p000'])
            continue
        f = r[-1]; g = p0[-1]
        # T4: marks stopped -- strictly fewer than the untouched leg
        s.add('T4 %s marks stop (lasts, markpush, ck_frames < p000)' % pfx,
              f['bs_lasts'] < g['bs_lasts'] and f['bs_markpush'] < g['bs_markpush']
              and f['ck_frames'] < g['ck_frames'], 'all three lower',
              'lasts %d/%d markpush %d/%d frames %d/%d'
              % (f['bs_lasts'], g['bs_lasts'], f['bs_markpush'], g['bs_markpush'],
                 f['ck_frames'], g['ck_frames']))
        s.add('T5 %s bs_starts unchanged (within 2)' % pfx,
              abs(f['bs_starts'] - g['bs_starts']) <= 2, '|d| <= 2',
              f['bs_starts'] - g['bs_starts'])
        s.add('T6 %s bs_drop == 0' % pfx, f['bs_drop'] == 0, '0', f['bs_drop'])

    # ---- section 6: the injected deletion -----------------------------------------
    a, b = leg['bs1_dA'], leg['bs1_dB']
    if a is None or b is None:
        for t in 'D1 D2 D3 D4 D5 D6 D7 D8'.split():
            s.add('%s' % t, False, 'scored', errs['bs1_dA'] or errs['bs1_dB'])
    else:
        fa, fb = a[-1], b[-1]
        s.add('D1 bs_drop(dA) > 0 and == bs_dropmax (or 255)',
              fa['bs_drop'] > 0 and (fa['bs_dropmax'] == fa['bs_drop']
                                     or fa['bs_dropmax'] == 255),
              'one contiguous run',
              'drop %d dropmax %d' % (fa['bs_drop'], fa['bs_dropmax']))
        s.add('D2 bs_drop(dB) - bs_drop(dA) == 240', fb['bs_drop'] - fa['bs_drop'] == 240,
              '240', fb['bs_drop'] - fa['bs_drop'])
        s.add('D3 bs_push(dA) == bs_push(dB)', fa['bs_push'] == fb['bs_push'],
              'equal', '%d vs %d' % (fa['bs_push'], fb['bs_push']))
        s.add('D4 bs_pop(dA) - bs_pop(dB) == 240', fa['bs_pop'] - fb['bs_pop'] == 240,
              '240', fa['bs_pop'] - fb['bs_pop'])
        s.add('D5 h_acc(dA) - h_acc(dB) == 240 +- 8',
              abs(fa['h_acc'] - fb['h_acc'] - 240) <= 8, '240 +- 8',
              fa['h_acc'] - fb['h_acc'])
        s.add('D6 markpush equal, ck_frames(dB) <= ck_frames(dA)',
              fa['bs_markpush'] == fb['bs_markpush']
              and fb['ck_frames'] <= fa['ck_frames'], 'chain broken at the FIFO hop',
              'markpush %d/%d frames %d/%d' % (fa['bs_markpush'], fb['bs_markpush'],
                                               fa['ck_frames'], fb['ck_frames']))
        p0 = leg['bs1_p000']
        if p0 is None:
            s.add('D7 pin anomaly on the stall legs', False, 'scored', errs['bs1_p000'])
        else:
            g = p0[-1]
            an_a = fa['ck_short'] + fa['ck_orphan']
            an_b = fb['ck_short'] + fb['ck_orphan']
            an_g = g['ck_short'] + g['ck_orphan']
            s.add('D7 ck_short+ck_orphan > the no-stall leg',
                  an_a > an_g and an_b > an_g, '> %d' % an_g,
                  'dA %d dB %d' % (an_a, an_b))
        wa = fa['h_acc'] - WPP * fa['ck_frames']
        wb = fb['h_acc'] - WPP * fb['ck_frames']
        s.add('D8 word budget moves by the deletion: (dA)-(dB) == 240 +- WPP',
              abs(wa - wb - 240) <= WPP, '240 +- WPP', '%d (%d - %d)' % (wa - wb, wa, wb))
        # D7': the SHARP form.  One contiguous deletion of D = bs_drop(dA) < 191 words
        # must give EITHER a surviving mark (short 1, orphan 0) OR a swallowed one
        # (short 0, orphan 191-D).  Nothing else.  bs1_p000 reads 0/0, so these are
        # absolutes, not deltas.
        D = fa['bs_drop']
        sh, orp = fa['ck_short'], fa['ck_orphan']
        okA = (sh, orp) == (1, 0) or (sh, orp) == (0, WPP - D)
        s.add("D7' dA (ck_short,ck_orphan) is (1,0) or (0,%d)" % (WPP - D),
              okA and D < WPP, '(1,0) or (0,%d)' % (WPP - D),
              '(%d,%d) with bs_drop %d' % (sh, orp, D))
        # D8': the identity that holds in BOTH cases and on BOTH legs
        for nm, fx in (('dA', fa), ('dB', fb)):
            Z = ((fx['h_acc'] - WPP * fx['ck_frames']) + fx['bs_drop']
                 - WPP * (fx['bs_markpush'] - fx['ck_frames']))
            s.add("D8' %s  Z = (h_acc-WPP*frames) + drop - WPP*(markpush-frames) == 0" % nm,
                  abs(Z) <= WPP, '0 +- WPP', Z)
        p0b = leg['bs1_p000']
        if p0b is not None:
            g = p0b[-1]
            Z = ((g['h_acc'] - WPP * g['ck_frames']) + g['bs_drop']
                 - WPP * (g['bs_markpush'] - g['ck_frames']))
            s.add("D8' p000 (no stall) Z == 0", abs(Z) <= WPP, '0 +- WPP', Z)

    # ---- section 6c: the SAME predictions D3/D4/D5/D6/D8, at a COMMON WINDOW -------
    # The first run could not score them: the clk dump grid is re-phased by the
    # stall-edge emits, so the two legs' last records sat ~124k clks apart and every
    # cumulative counter differed by the ~240 words that arrive in that extra window.
    # (D2 was immune -- bs_drop stops advancing when the stall ends -- and it passed
    # exactly.)  The p0002/dA2/dB2 legs are the SAME stimulus, the SAME RTL and the
    # SAME predicted numbers, run against a binary whose only difference is a record
    # every 4096 pushes.  Scored at the largest push index present in all three.
    r2 = {}
    for pfx in ('bs1_p0002', 'bs1_dA2', 'bs1_dB2'):
        rr, e = load(d, pfx)
        if rr is not None:
            e = decode_check(rr)
        r2[pfx] = None if e else rr
    if any(v is None for v in r2.values()):
        for t in ('D3', 'D4', 'D5', 'D6', 'D8'):
            s.add("%s' common-window re-run" % t, False, 'scored',
                  'a re-run leg is missing or DECODE_FAIL')
    else:
        # Do not ASSUME where the grid records land -- the wrapper emits on the beat
        # that CROSSES a multiple of BS_PUSH_GRID, so the recorded h_push is one less.
        # Intersect the three legs' actual h_push sets and take the largest non-zero
        # value they share; that is the common window whatever the phase.
        grids = [set(x['h_push'] for x in v) for v in r2.values()]
        common = sorted(h for h in (grids[0] & grids[1] & grids[2]) if h > 0)
        H = common[-1] if common else None
        if H is None:
            for t in ('D3', 'D4', 'D5', 'D6', 'D8'):
                s.add("%s' common-window re-run" % t, False, 'scored',
                      'no common push grid point')
        else:
            at = {k: [x for x in v if x['h_push'] == H][-1] for k, v in r2.items()}
            fa, fb = at['bs1_dA2'], at['bs1_dB2']
            s.add("D3' both legs: bs_push == h_push == %d at the common window" % H,
                  fa['bs_push'] == H and fb['bs_push'] == H, str(H),
                  '%d, %d' % (fa['bs_push'], fb['bs_push']))
            s.add("D4' bs_pop(dA2) - bs_pop(dB2) == 240",
                  fa['bs_pop'] - fb['bs_pop'] == 240, '240', fa['bs_pop'] - fb['bs_pop'])
            s.add("D5' h_acc(dA2) - h_acc(dB2) == 240 +- 8",
                  abs(fa['h_acc'] - fb['h_acc'] - 240) <= 8, '240 +- 8',
                  fa['h_acc'] - fb['h_acc'])
            s.add("D6' markpush equal, ck_frames(dB2) <= ck_frames(dA2)",
                  fa['bs_markpush'] == fb['bs_markpush']
                  and fb['ck_frames'] <= fa['ck_frames'], 'chain broken at the FIFO hop',
                  'markpush %d/%d frames %d/%d' % (fa['bs_markpush'], fb['bs_markpush'],
                                                   fa['ck_frames'], fb['ck_frames']))
            wa = fa['h_acc'] - WPP * fa['ck_frames']
            wb = fb['h_acc'] - WPP * fb['ck_frames']
            s.add("D8' word budget (dA2)-(dB2) == 240 +- WPP",
                  abs(wa - wb - 240) <= WPP, '240 +- WPP', '%d (%d - %d)' % (wa - wb, wa, wb))
            # POST-HOC, registered forward, NOT pre-registered: the orphan run is
            # M marks' worth of words minus everything that actually vanished at the
            # pins -- the FIFO's drops PLUS the one word the FIFO pops that the pin
            # never accepts at the stall edge (seam S6, the ready_1 skew).
            for nm in ('bs1_dA2', 'bs1_dB2'):
                f = at[nm]
                M = f['bs_markpush'] - f['ck_frames']
                skew = f['bs_pop'] - f['h_acc']
                want = M * WPP - (f['bs_drop'] + skew)
                s.add("POSTHOC %s orphan == %d*WPP - (drop %d + ready_1 skew %d)"
                      % (nm, M, f['bs_drop'], skew), f['ck_orphan'] == want,
                      str(want), f['ck_orphan'])

    # ---- section U: the bs_seam_census unit gate ----------------------------------
    # bs_census_tb.log sits in modem/rtl_sim/, one level up from this scorer's
    # directory; the 2026-09-09 repo-hygiene rename moved the harness under modem/.
    tb = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                      '..', 'bs_census_tb.log')
    t = open(tb).read() if os.path.exists(tb) else ''
    nfail = t.count('FAIL ')
    s.add('U1-U5 tb_bs_census (min/max direction, q24 both branches, FREEZE, dropmax run)',
          'TB_BS_CENSUS_PASS' in t and nfail == 0, '0 FAIL',
          '%d FAIL, %d PASS' % (nfail, t.count('PASS ')) if t else 'no bs_census_tb.log')

    return 0 if s.report() else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))))
