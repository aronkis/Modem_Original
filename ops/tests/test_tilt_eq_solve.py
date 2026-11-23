"""tilt_eq_solve.py: in-band tilt (dB across +-8 MHz) -> the three TiltEq corrector coefficients and the
0x260/0x264 register words (spec docs/superpowers/specs/2026-10-03-rx-tilt-equaliser-design.md)."""
import math, subprocess, sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
import tilt_eq_solve as T


def _stage_tilt(a, fs=61.44e6, f=8e6):
    s = math.sin(2 * math.pi * f / fs)
    return 10 * math.log10((1 + a * a + 2 * a * s) / (1 + a * a - 2 * a * s))


def test_stage_count_matches_sim_driver():
    assert T.stages_for(4) == 1 and T.stages_for(-7) == 1 and T.stages_for(-8) == 2
    assert T.stages_for(14) == 2 and T.stages_for(-16) == 3


def test_corrector_cancels_the_channel_sign_and_magnitude():
    for t in (-4.0, -6.0, -8.0, -12.0, -16.0, 10.0):
        a = T.solve_a(t)
        k = T.stages_for(t)
        assert all(x == 0.0 for x in a[k:]) and all(x != 0.0 for x in a[:k])
        own = sum(_stage_tilt(x) for x in a[:k])
        assert abs(own - t) < 0.05, (t, a, own)   # a carries the CHANNEL's sign; the fabric applies the inverse


def test_zero_is_bypass_and_clamp_holds():
    assert T.solve_a(0.0) == [0.0, 0.0, 0.0]
    assert T.to_regs([0.0, 0.0, 0.0]) == (0, 0)
    a = T.solve_a(-40.0)
    assert all(abs(x) <= 0.95 + 1e-12 for x in a)


def test_register_pack_roundtrip():
    a = T.solve_a(-12.0)
    w260, w264 = T.to_regs(a)
    assert (w264 >> 31) & 1 == 1
    back = T.from_regs(w260, w264)
    assert all(abs(x - y) < 2 ** -15 + 1e-12 for x, y in zip(a, back))
    assert T.encode(-0.5) == 0xC000 and T.encode(0.5) == 0x4000


def test_cli_prints_regs_and_env_form():
    out = subprocess.run([sys.executable, T.__file__, "-8"], capture_output=True, text=True, check=True).stdout
    assert "0x260=0x" in out and "0x264=0x8" in out
    env = subprocess.run([sys.executable, T.__file__, "--env", "-8"], capture_output=True, text=True, check=True).stdout
    assert env.startswith("PERT_EQ_A1=") and "PERT_EQ_A3=" in env
