"""tilt_eq_overlay.m -- the receiver in-band tilt corrector (3 x complex one-pole before the AGC, AXI
0x260/0x264, exact bypass) and its assemble / hdlworkflow hooks (plan 2026-10-03-rx-tilt-equaliser Task 3)."""
import os
import re

H = os.path.join(os.path.dirname(__file__), '..', '..')
M = os.path.join(H, 'modem', 'dev', 'simulink', 'tilt_eq_overlay.m')
A = os.path.join(H, 'modem', 'dev', 'simulink', 'assemble_jupiter_240k5_byte.m')
P = os.path.join(H, 'modem', 'dev', 'hdlcoder', 'patch_hdlworkflow_tilteq.m')


def _code(p):
    return "\n".join(l for l in open(p).read().splitlines() if not l.lstrip().startswith('%'))


def test_overlay_inserts_before_agc_with_exact_bypass():
    s = _code(M)
    assert "Automatic Gain Control" in s and "/TiltEq" in s and "getSimulinkBlockHandle(agc)" in s
    assert "cT = numerictype(1,16,15)" in s      # coefficient type
    assert "sT = numerictype(1,18,14)" in s      # state type
    assert "fi(0.95, cT, F)" in s                # clamp
    assert s.count("F = fimath(") == 1 and "''RoundingMethod'',''Floor''" in s   # one fimath everywhere
    assert "tilt_eq_a12" in s and "tilt_eq_a3en" in s
    assert re.search(r"already present\s*--\s*skip", s)   # idempotent
    assert "LEAN-only" in s
    # exact pass-through on both off paths
    assert "y = fi(x, oT, F);" in s and "y = fi(y3, oT, F);" in s
    assert "persistent s1 s2 s3 c1 c2 c3 cen" in s and "a1 = c1; a2 = c2; a3 = c3; en = cen;" in s   # registered coefficients (WNS)
    # the inverse one-pole: yI = xI + a*yQp, yQ = xQ - a*yIp (feedback on the state, not the input)
    assert "real(xi) + a1*imag(s1), imag(xi) - a1*real(s1)" in s


def test_assemble_applies_after_loop_gain_lean_only_and_gates_it():
    s = _code(A)
    i = s.find("loop_gain_axi_overlay(sys, loop)")
    j = s.find("tilt_eq_overlay(sys, loop)")
    assert 0 < i < j
    assert "QPSK_TILT_EQ_OVERLAY" in s and "TILTEQ = LEAN &&" in s
    assert "gate(j): TILTEQ regs 0x260/0x264 present + mapped" in s
    assert "patch_hdlworkflow_tilteq('hdlworkflow_loopback.m')" in s


def test_hdlworkflow_patch_maps_260_264_after_loopgain():
    s = _code(P)
    assert "'tilt_eq_a12','260'" in s and "'tilt_eq_a3en','264'" in s and "IOInterfaceMapping" in s
    assert "end loop-gain tuning mappings" in s   # anchors after the loop-gain block
