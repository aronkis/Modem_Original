#!/usr/bin/env python3
"""Regression test for ddrcap2_inject.py's shape-dispatch fixes: patch_fts's
pdWitB/fs_runmax generalisation, and patch_preamble_detector's ufix14/ufix11
timingOffset/p1c_tref width dispatch.

Controller ruling (2026-09-11, sub-project 3 ledger): the pdWitA/pdWitB/
enSlack ports are the dead "slack FIFO" witness lineage the bank inherited
from an abandoned experiment (docs/evidence/RXFIX_STATE.md records enSlack
as a null result and pdWitA/pdWitB as dead nets) -- no .m in the bank or
repo produces them, and they are NOT to be reproduced. patch_fts's
u_Preamble_Detector anchor was hardcoded to the bank's pdWitB tail, so it
failed against the current (11.334) model's regenerated RTL, which has no
pdWit*/enSlack anywhere and terminates the same instantiation (and the
FTS module's own port list) on fs_runmax, Preamble_Detector's real output.

This locks down that patch_fts recognises BOTH shapes: the legacy bank
pdWitB tail (so it stays idempotent-safe against any already-committed bank
tree, without adding new pdWit*/enSlack wiring) and the regen fs_runmax
tail (the shape that actually needs the fix), and that both splices land
the same dc_* connections.

Run: python3 modem/instruments/ddrcap2/test_ddrcap2_inject_fts_shapes.py
"""
import importlib.util, os, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('inj', os.path.join(HERE, 'ddrcap2_inject.py'))
inj = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inj)

# Same literal ddrcap2_inject.py's patch_fts uses for the Symbol_Synchronizer
# instantiation tail -- unaffected by this fix, common to both shapes.
SS_TAIL = (".beatobsPop(Symbol_Synchronizer_beatobsPop)  // ufix5\n"
           "                                                              );")

COMMON_BODY = """
  output  signed [31:0] fs_runmax;  // sfix32_En26

  wire signed [31:0] Preamble_Detector_fs_runmax;  // sfix32_En26
  wire [7:0] Symbol_Synchronizer_beatobsRhCtr;  // uint8

  Symbol_Synchronizer u_Symbol_Synchronizer (.clk(clk),
                                                              .beatobsPop(Symbol_Synchronizer_beatobsPop)  // ufix5
                                                              );

  assign p1c_telQ = Preamble_Detector_p1c_telQ;
"""

# Bank shape: module port list AND u_Preamble_Detector instantiation both
# terminate on the dead pdWitA/pdWitB/enSlack lineage (real indentation
# taken from rtl_sim/s1_rtl_txmark/.../Frequency_and_Time_Synchronizer.v).
BANK_FTS = """module Frequency_and_Time_Synchronizer
          (clk,
           reset,
           p1c_telI,
           p1c_telQ,
           fs_runmax,
           beatobsRhCtr,
           beatobsPush,
           beatobsPop,
           enSlack,
           pdWitA,
           pdWitB);

""" + COMMON_BODY + """
  Preamble_Detector u_Preamble_Detector (.clk(clk),
                                                          .reset(reset),
                                                          .fs_runmax(Preamble_Detector_fs_runmax),  // sfix32_En26
                                        .enSlack(enSlack),
                                        .pdWitA(pdWitA),
                                        .pdWitB(pdWitB));

endmodule
"""

# Regen shape (current 11.334 model): no pdWit*/enSlack anywhere; both the
# module's own port list and the instantiation terminate on fs_runmax
# (real indentation taken from hdl_prj_jupiter_composite/hdlsrc/.../
# TxRxCompo_ip_src_Frequency_and_Time_Synchronizer.v).
REGEN_FTS = """module Frequency_and_Time_Synchronizer
          (clk,
           reset,
           p1c_telI,
           p1c_telQ,
           fs_runmax,
           beatobsRhCtr,
           beatobsPush,
           beatobsPop);

""" + COMMON_BODY + """
  TxRxCompo_ip_src_Preamble_Detector u_Preamble_Detector (.clk(clk),
                                                          .reset(reset),
                                                          .fs_runmax(Preamble_Detector_fs_runmax)  // sfix32_En26
                                                          );

endmodule
"""

# No-observer shape (2026-09-24, TAP_A_BEATOBS.md): the BEATOBS overlay no longer reaches the
# netlist, so Symbol_Synchronizer's last port is the RXFIX witness sro_mode; sel-15 reads zero.
NOBO_FTS = """module Frequency_and_Time_Synchronizer
          (clk,
           reset,
           p1c_telI,
           p1c_telQ,
           fs_runmax,
           w1Strobe,
           r4_wit,
           r4_extras,
           sro_mode);

  output  signed [31:0] fs_runmax;  // sfix32_En26

  wire signed [31:0] Preamble_Detector_fs_runmax;  // sfix32_En26
  wire [31:0] Symbol_Synchronizer_sro_mode;  // uint32

  TxRxCompo_ip_src_Symbol_Synchronizer u_Symbol_Synchronizer (.clk(clk),
                                                              .sro_mode(Symbol_Synchronizer_sro_mode)  // uint32
                                                              );

  assign p1c_telQ = Preamble_Detector_p1c_telQ;

  TxRxCompo_ip_src_Preamble_Detector u_Preamble_Detector (.clk(clk),
                                                          .reset(reset),
                                                          .fs_runmax(Preamble_Detector_fs_runmax)  // sfix32_En26
                                                          );

endmodule
"""

assert inj.BANK_PD_TAIL in BANK_FTS, "fixture does not contain the module's own bank pd_tail literal"
assert inj.REGEN_PD_TAIL in REGEN_FTS, "fixture does not contain the module's own regen pd_tail literal"
assert SS_TAIL in BANK_FTS and SS_TAIL in REGEN_FTS


def _run_patch_fts(body):
    d = tempfile.mkdtemp(prefix='ddrcap2_t_')
    try:
        p = os.path.join(d, 'Frequency_and_Time_Synchronizer.v')
        open(p, 'w').write(body)
        status = inj.patch_fts(p)
        out = open(p).read()
        return status, out
    finally:
        shutil.rmtree(d, ignore_errors=True)


def test_patch_fts_bank_shape_splices_dc_ports():
    status, out = _run_patch_fts(BANK_FTS)
    assert status == 'patched', status
    assert '.pdWitB(pdWitB),' in out, "bank shape must keep the exact-match pdWitB tail (no new wiring, just splice after it)"
    assert '.dc_toff(Preamble_Detector_dc_toff)' in out
    assert '.dc_mu(Symbol_Synchronizer_dc_mu)' in out


def test_patch_fts_regen_shape_splices_dc_ports():
    status, out = _run_patch_fts(REGEN_FTS)
    assert status == 'patched', status
    assert '.fs_runmax(Preamble_Detector_fs_runmax),  // sfix32_En26' in out, \
        "regen shape must add a comma after fs_runmax's own closing paren, not invent a pdWitB port"
    assert 'pdWitB' not in out, "regen shape must NOT introduce pdWitB -- controller ruling: dead net, not reproduced"
    assert 'enSlack' not in out, "regen shape must NOT introduce enSlack -- controller ruling: dead net, not reproduced"
    assert '.dc_toff(Preamble_Detector_dc_toff)' in out
    assert '.dc_mu(Symbol_Synchronizer_dc_mu)' in out


def test_patch_fts_no_observer_shape_ties_rh_channels_to_zero():
    status, out = _run_patch_fts(NOBO_FTS)
    assert status == 'patched'
    assert ".sro_mode(Symbol_Synchronizer_sro_mode),  // uint32" in out
    assert ".dc_mu(Symbol_Synchronizer_dc_mu)" in out and ".dc_toff(Preamble_Detector_dc_toff)" in out
    assert "assign dc_rhctr = 8'd0;" in out and "assign dc_rhpop = 5'd0;" in out
    assert "Symbol_Synchronizer_beatobs" not in out and ".beatobsPop(" not in out
    # idempotent
    import tempfile, os
    d = tempfile.mkdtemp(); p = os.path.join(d, 'Frequency_and_Time_Synchronizer.v')
    open(p, 'w').write(NOBO_FTS); assert inj.patch_fts(p) == 'patched'; assert inj.patch_fts(p) == 'already'


def test_patch_fts_idempotent_both_shapes():
    for body in (BANK_FTS, REGEN_FTS):
        d = tempfile.mkdtemp(prefix='ddrcap2_t_')
        try:
            p = os.path.join(d, 'Frequency_and_Time_Synchronizer.v')
            open(p, 'w').write(body)
            assert inj.patch_fts(p) == 'patched'
            assert inj.patch_fts(p) == 'already'
        finally:
            shutil.rmtree(d, ignore_errors=True)


# ---------------------------------------------------------------------------
# patch_preamble_detector: Peak_Search_timingOffset / Peak_Search_p1c_tref
# width shape dispatch (2026-09-11 follow-up).
#
# Bank (model <=11.331 lineage): both ufix14 ([13:0]). Regen (current 11.334
# model): both narrowed to ufix11 ([10:0]) -- Peak_Search itself no longer
# produces the top 3 bits. Controller ruling (2026-09-11, sub-project 3
# ledger): ddrcap/ddrcap2 anchors must match the CURRENT model's RTL, not
# the bank's, so this is a shape dispatch (zero-extend at the source
# assign), not a hard 14-bit-only anchor -- dc_toff/dc_tref STAY 14-bit
# ports so every downstream consumer (ch2/ch3 packing, the DDRCAP-v2 record
# layout in ops/flash/ddrcap2_decode.py, and the pre-existing bank-shape
# test in ops/tests/test_ddrcap2_inject.py) is unaffected.
# ---------------------------------------------------------------------------

_PD_COMMON_TAIL = """module Preamble_Detector
          (clk,
           reset,
           fs_runmax);

  output  signed [31:0] fs_runmax;  // sfix32_En26

  wire signed [31:0] Correlator_dataOut;  // sfix32_En26
  wire signed [31:0] Correlator_threshold;  // sfix32_En28
  wire Correlator_validOut;

{toff_decl}
{tref_decl}
  wire [31:0] Peak_Search_p1c_heldts;  // uint32

  assign fs_runmax = Peak_Search_p1c_runmax;

endmodule
"""

PD_BANK = _PD_COMMON_TAIL.format(
    toff_decl="  wire [13:0] Peak_Search_timingOffset;  // ufix14",
    tref_decl="  wire [13:0] Peak_Search_p1c_tref;  // ufix14",
)
PD_REGEN = _PD_COMMON_TAIL.format(
    toff_decl="  wire [10:0] Peak_Search_timingOffset;  // ufix11",
    tref_decl="  wire [10:0] Peak_Search_p1c_tref;  // ufix11",
)

assert inj.PD_TOFF_TREF_BANK[0] in PD_BANK and inj.PD_TOFF_TREF_BANK[1] in PD_BANK
assert inj.PD_TOFF_TREF_REGEN[0] in PD_REGEN and inj.PD_TOFF_TREF_REGEN[1] in PD_REGEN


def _run_patch_pd(body):
    d = tempfile.mkdtemp(prefix='ddrcap2_pd_')
    try:
        p = os.path.join(d, 'Preamble_Detector.v')
        open(p, 'w').write(body)
        status = inj.patch_preamble_detector(p)
        out = open(p).read()
        return status, out
    finally:
        shutil.rmtree(d, ignore_errors=True)


def test_patch_preamble_detector_bank_shape_keeps_direct_assign():
    status, out = _run_patch_pd(PD_BANK)
    assert status == 'patched', status
    assert "assign dc_toff = Peak_Search_timingOffset;" in out
    assert "assign dc_tref = Peak_Search_p1c_tref;" in out
    assert "output  [13:0] dc_toff;" in out


def test_patch_preamble_detector_regen_shape_zero_extends():
    status, out = _run_patch_pd(PD_REGEN)
    assert status == 'patched', status
    assert "assign dc_toff = {3'b0, Peak_Search_timingOffset};" in out
    assert "assign dc_tref = {3'b0, Peak_Search_p1c_tref};" in out
    # port stays 14-bit even though the model-side wire narrowed to 11
    assert "output  [13:0] dc_toff;" in out


def test_patch_preamble_detector_idempotent_both_shapes():
    for body in (PD_BANK, PD_REGEN):
        d = tempfile.mkdtemp(prefix='ddrcap2_pd_')
        try:
            p = os.path.join(d, 'Preamble_Detector.v')
            open(p, 'w').write(body)
            assert inj.patch_preamble_detector(p) == 'patched'
            assert inj.patch_preamble_detector(p) == 'already'
        finally:
            shutil.rmtree(d, ignore_errors=True)


def run():
    fails = 0
    for fn in (test_patch_fts_bank_shape_splices_dc_ports,
               test_patch_fts_no_observer_shape_ties_rh_channels_to_zero,
               test_patch_fts_regen_shape_splices_dc_ports,
               test_patch_fts_idempotent_both_shapes,
               test_patch_preamble_detector_bank_shape_keeps_direct_assign,
               test_patch_preamble_detector_regen_shape_zero_extends,
               test_patch_preamble_detector_idempotent_both_shapes):
        try:
            fn()
            print(f"  [PASS] {fn.__name__}")
        except AssertionError as e:
            fails += 1
            print(f"  [FAIL] {fn.__name__}: {e}")
    print(f"\nTEST_DDRCAP2_INJECT {'ALL PASS' if not fails else f'{fails} FAILED'}")
    return fails


if __name__ == "__main__":
    sys.exit(1 if run() else 0)
