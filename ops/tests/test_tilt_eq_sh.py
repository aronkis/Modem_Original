"""ops/tilt_eq.sh -- measure the in-band tilt on the receiving board, solve, write 0x260/0x264, verify
(plan 2026-10-03-rx-tilt-equaliser Task 5)."""
import os
import subprocess

H = os.path.join(os.path.dirname(__file__), '..')
S = os.path.join(H, 'tilt_eq.sh')
B = os.path.join(H, 'bringup_r2r3.sh')


def test_dry_touches_no_board():
    r = subprocess.run(["bash", S, "10.0.0.148", "--dry"], capture_output=True, text=True)
    assert r.returncode == 0 and "TILT_EQ_DRY" in r.stdout and "0x260" in r.stdout and "iio_readdev" in r.stdout


def test_script_uses_anyssh_dra_and_the_solver():
    s = open(S).read()
    assert "anyssh.sh" in s and "direct_reg_access" in s and "tilt_eq_solve.py" in s and "tilt_score.py" in s
    assert "echo '0x260 $1' > $DRA" in s and "echo '0x264 $2' > $DRA" in s and "--off" in s
    assert "TILT_EQ_MIN_DB" in s          # flat channel -> bypass written
    assert '"--set"' in s and "set=$T" in s   # forced coefficients for A/B verification


def test_bringup_hook_is_opt_in():
    s = "\n".join(l for l in open(B).read().splitlines() if not l.lstrip().startswith('#'))
    assert 'QPSK_TILT_EQ' in s and 'tilt_eq.sh' in s
    i = s.find('sro_sign.sh" --check'); j = s.find('tilt_eq.sh')
    assert 0 < i < j, "the tilt-eq hook runs after the sro_sign hooks"
    assert '"${QPSK_TILT_EQ:-0}" = 1' in s


def test_capture_rail_writes_the_words_after_its_own_bringup():
    """The rail's bring-up ends with 0x000 resets that clear the write-only words, so TILT_EQ_SET runs at the
    post-arm poke position (after RX_ATTR_POKE, before the traffic window), never before the leg (10-04)."""
    s = "\n".join(l for l in open(os.path.join(H, 'capture_r3.sh')).read().splitlines() if not l.lstrip().startswith('#'))
    i = s.find('RX_ATTR_POKE on $RX_IP'); j = s.find('TILT_EQ_SET'); k = s.find('PEER_ATTR_POKE on $PEER_IP'); w = s.find('CAP_START')
    assert 0 < i < j < k < w
    assert 'tilt_eq.sh" "$RX_IP" --set "$TILT_EQ_SET"' in s and '--off' in s
