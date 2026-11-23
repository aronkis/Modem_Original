"""modem/gates/tilt_eq.legs -- the receiver tilt-corrector gate rows (plan 2026-10-03-rx-tilt-equaliser Task 4)."""
import os
L = os.path.join(os.path.dirname(__file__), '..', '..', 'modem', 'gates', 'tilt_eq.legs')


def test_rows():
    rows = [l.rstrip() for l in open(L) if l.strip() and not l.startswith('#')]
    names = [r.split('|', 2)[0] for r in rows]
    assert names[0] == 'te_build' and len(set(names)) == len(names) and all(len(r.split('|', 2)) == 3 for r in rows)
    assert {'te_baseline', 'te_identity', 'te_tilt_m8', 'te_tilt_m12', 'te_tilt_m16', 'te_tilt_p10', 'te_misset_m12',
            'te_budget', 'te_replay_46', 'te_replay_2p4'} <= set(names)
    txt = "\n".join(rows)
    assert 'CFLAGS_EXTRA=-DHAVE_TILT_EQ' in txt and 'VDEFINES_EXTRA=+define+HAVE_TILT_EQ' in txt and 'WRAP=wrap_byte_sro4b_ss_model.v' in txt
    cmds = [r.split('|', 2)[1] for r in rows]
    assert 'tilt_eq_replay.sh' in txt and not any('$(' in c for c in cmds), 'leg COMMANDS run under bash -c in a unit: no command substitution there (criteria run in the parent shell)'
    assert 'PERT_EQ_AUTO=1' in txt and 'PERT_EQ_MISSET=0.2' in txt and '--tilt-budget' in txt
    assert 'fwddiag_20261002_1604/gate3/cell1_A_2100020000/pair.iq' in txt
    assert 'tilt_eq_c004_baseline_f1536_cols1_10.txt' in txt
    assert txt.count('--bias-center -3400 --max-bias 300') == 2   # live replays: the plan's offset is not a bias
    assert "$BANK/tilt_eq" not in txt and "$SRO/tilt_eq" not in txt, "bank dirs are listing-hashed; never put a reference file in them"
