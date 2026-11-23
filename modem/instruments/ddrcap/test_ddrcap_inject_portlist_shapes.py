#!/usr/bin/env python3
"""Regression test for ddrcap_inject.py's _append_top_ports generalisation.

Companion to modem/instruments/txcap/test_txcap_inject_portlist_shapes.py --
same 2026-09-11 (sp3 Task 1, round 1) finding, the ddrcap-side half of it.
patch_qpsk_tx/patch_transmitter's port-list appends anchored on the literal
"           txFrameStart);" tail. That tail only exists at all once
txcap_inject.py has already run; on the current-model (11.334) regen shape,
txcap_inject.py's own fix (see the txcap-side test) lands txFrameStart AFTER
fs_txur -- so ddrcap_inject.py must also generalise off the CURRENT last
port, not assume txFrameStart is always the module's final port either.

Fix: patch_qpsk_tx/patch_transmitter now use the same _append_top_ports
helper as txcap_inject.py.

Run: python3 modem/instruments/ddrcap/test_ddrcap_inject_portlist_shapes.py
"""
import importlib.util, os, re, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('inj', os.path.join(HERE, 'ddrcap_inject.py'))
inj = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inj)


def declared_but_unlisted(body):
    m = re.search(r'module\s+\w+\s*\((.*?)\);', body, re.DOTALL)
    assert m, 'no module port list in fixture'
    port_list = set(p.strip() for p in m.group(1).split(',') if p.strip())
    declared = set(re.findall(r'output\s+(?:signed\s+)?(?:\[[^\]]+\]\s+)?(\w+);', body))
    return declared - port_list


# Bank shape: txFrameStart is the module's last port (txcap_inject.py's own
# bank-shape output, pre-existing before this fix).
TRANSMITTER_BANK_POST_TXCAP = """module Transmitter
          (
           extWordPop,
           txFrameStart);
  output  extWordPop;
  output  txFrameStart;  // sfix16_En14
  QPSK_Tx u_QPSK_Tx
      (.dataOut_im(QPSK_Tx_dataOut_im),  // sfix16_En14
                                      .txFrameStart(txFrameStart)
                                      );
endmodule
"""

# Regen shape: txcap_inject.py's own fixed _append_top_ports lands
# txFrameStart AFTER fs_txur (fs_txur is FrameStat's, unrelated to and
# untouched by either capture instrument).
TRANSMITTER_REGEN_POST_TXCAP = """module TxRxCompo_ip_src_Transmitter
          (
           extWordPop,
           fs_txur,
           txFrameStart);
  output  extWordPop;
  output  fs_txur;
  output  txFrameStart;  // sfix16_En14
  QPSK_Tx u_QPSK_Tx
      (.dataOut_im(QPSK_Tx_dataOut_im),  // sfix16_En14
                                      .txFrameStart(txFrameStart)
                                      );
endmodule
"""


def _run(body):
    d = tempfile.mkdtemp(prefix='ddrcap_pl_')
    try:
        p = os.path.join(d, 'Transmitter.v')
        open(p, 'w').write(body)
        status = inj.patch_transmitter(p)
        out = open(p).read()
        return status, out
    finally:
        shutil.rmtree(d, ignore_errors=True)


def test_patch_transmitter_bank_shape_lands_in_port_list():
    status, out = _run(TRANSMITTER_BANK_POST_TXCAP)
    assert status == 'patched', status
    m = re.search(r'module\s+\w+\s*\((.*?)\);', out, re.DOTALL)
    for p in ('modOut_re', 'modOut_im', 'modValid', 'scramBit', 'scramValid'):
        assert p in m.group(1), f'{p} not in bank-shape port list'
    assert not declared_but_unlisted(out), declared_but_unlisted(out)


def test_patch_transmitter_regen_shape_lands_in_port_list():
    status, out = _run(TRANSMITTER_REGEN_POST_TXCAP)
    assert status == 'patched', status
    m = re.search(r'module\s+\w+\s*\((.*?)\);', out, re.DOTALL)
    for p in ('modOut_re', 'modOut_im', 'modValid', 'scramBit', 'scramValid'):
        assert p in m.group(1), \
            f'{p} not in regen-shape (fs_txur before txFrameStart) port list -- the 2026-09-11 defect'
    assert 'fs_txur' in m.group(1)
    assert not declared_but_unlisted(out), declared_but_unlisted(out)


def test_patch_transmitter_idempotent_both_shapes():
    for body in (TRANSMITTER_BANK_POST_TXCAP, TRANSMITTER_REGEN_POST_TXCAP):
        status1, out1 = _run(body)
        assert status1 == 'patched'
        d = tempfile.mkdtemp(prefix='ddrcap_pl_')
        try:
            p = os.path.join(d, 'Transmitter.v')
            open(p, 'w').write(out1)
            assert inj.patch_transmitter(p) == 'already'
        finally:
            shutil.rmtree(d, ignore_errors=True)


# QPSK_Tx.v -- patch_qpsk_tx (ddrcap's own, runs after txcap_inject.py has
# already landed txFrameStart) also uses _append_top_ports; round 1 only
# fixed the Transmitter.v side. Requires the anchors patch_qpsk_tx checks for
# (QPSKConstellationPoints_re/Valid, HDL_Data_Scrambler_dataOut/validOut) to
# be present anywhere in the fixture, not necessarily as real logic.
QPSKTX_BANK_POST_TXCAP = """module QPSK_Tx
          (
           dataOut_re,
           dataOut_im,
           txFrameStart);
  output  signed [15:0] dataOut_re;  // sfix16_En14
  output  signed [15:0] dataOut_im;  // sfix16_En14
  output  txFrameStart;  // sfix16_En14
  wire QPSKConstellationPoints_re;
  wire QPSKConstellationValid;
  wire HDL_Data_Scrambler_dataOut;
  wire HDL_Data_Scrambler_validOut;
endmodule
"""

# Synthetic regen-shape fixture: a port trails txFrameStart (no live
# divergence is known here -- txFrameStart is genuinely last in the real
# 11.334 tree once txcap_inject.py has run -- this proves the splice does
# not silently depend on that being true).
QPSKTX_REGEN_POST_TXCAP = """module TxRxCompo_ip_src_QPSK_Tx
          (
           dataOut_re,
           dataOut_im,
           txFrameStart,
           dataReady);
  output  signed [15:0] dataOut_re;  // sfix16_En14
  output  signed [15:0] dataOut_im;  // sfix16_En14
  output  txFrameStart;  // sfix16_En14
  output  dataReady;
  wire QPSKConstellationPoints_re;
  wire QPSKConstellationValid;
  wire HDL_Data_Scrambler_dataOut;
  wire HDL_Data_Scrambler_validOut;
endmodule
"""


def _run_qpsktx(body):
    d = tempfile.mkdtemp(prefix='ddrcap_pl_')
    try:
        p = os.path.join(d, 'QPSK_Tx.v')
        open(p, 'w').write(body)
        status = inj.patch_qpsk_tx(p)
        out = open(p).read()
        return status, out
    finally:
        shutil.rmtree(d, ignore_errors=True)


def test_patch_qpsk_tx_bank_shape_lands_in_port_list():
    status, out = _run_qpsktx(QPSKTX_BANK_POST_TXCAP)
    assert status == 'patched', status
    m = re.search(r'module\s+\w+\s*\((.*?)\);', out, re.DOTALL)
    for p in ('modOut_re', 'modOut_im', 'modValid', 'scramBit', 'scramValid'):
        assert p in m.group(1), f'{p} not in bank-shape port list'
    assert not declared_but_unlisted(out), declared_but_unlisted(out)


def test_patch_qpsk_tx_regen_shape_lands_in_port_list():
    status, out = _run_qpsktx(QPSKTX_REGEN_POST_TXCAP)
    assert status == 'patched', status
    m = re.search(r'module\s+\w+\s*\((.*?)\);', out, re.DOTALL)
    for p in ('modOut_re', 'modOut_im', 'modValid', 'scramBit', 'scramValid'):
        assert p in m.group(1), \
            f'{p} not in regen-shape (dataReady-tail) port list'
    assert 'dataReady' in m.group(1)
    assert not declared_but_unlisted(out), declared_but_unlisted(out)


def test_patch_qpsk_tx_idempotent_both_shapes():
    for body in (QPSKTX_BANK_POST_TXCAP, QPSKTX_REGEN_POST_TXCAP):
        status1, out1 = _run_qpsktx(body)
        assert status1 == 'patched'
        d = tempfile.mkdtemp(prefix='ddrcap_pl_')
        try:
            p = os.path.join(d, 'QPSK_Tx.v')
            open(p, 'w').write(out1)
            assert inj.patch_qpsk_tx(p) == 'already'
        finally:
            shutil.rmtree(d, ignore_errors=True)


# TxRxComposite.v -- patch_composite's own top-level port-list append.
# Round 1 left this on the literal 'beatfix_viol_count,\n beatfix_viol_latch);'
# anchor (the SAME defect class caught in Transmitter.v: nothing currently
# trails beatfix_viol_latch in the 11.334 regen tree, so it happened not to
# manifest, but the ruling ("for every module the injectors extend ... check
# ... TxRxComposite.v") calls it in scope). Fixed here to use
# _append_top_ports too. patch_composite() itself has many other anchors
# (wire decls, instantiation tails) unrelated to the port-list defect class,
# so this test exercises the exact _append_top_ports splice patch_composite
# now uses, directly -- the same helper already proven against Transmitter.v
# and QPSK_Tx.v above.
COMPOSITE_TAIL_BANK = """module TxRxComposite
          (
           clk,
           reset,
           beatfix_viol_count,
           beatfix_viol_latch);
  output  [31:0] beatfix_viol_count;  // uint32
  output  [31:0] beatfix_viol_latch;  // uint32
endmodule
"""

# Synthetic regen-shape fixture: a port trails beatfix_viol_latch.
COMPOSITE_TAIL_REGEN = """module TxRxCompo_ip_src_TxRxComposite
          (
           clk,
           reset,
           beatfix_viol_count,
           beatfix_viol_latch,
           framestat_wordcnt);
  output  [31:0] beatfix_viol_count;  // uint32
  output  [31:0] beatfix_viol_latch;  // uint32
  output  [15:0] framestat_wordcnt;
endmodule
"""


def test_composite_portlist_append_bank_shape():
    out = inj._append_top_ports(COMPOSITE_TAIL_BANK,
                                 ['ddrcap_i', 'ddrcap_q', 'ddrcap_mark_demod',
                                  'ddrcap_mark_fec', 'ddrcap_valid'])
    m = re.search(r'module\s+\w+\s*\((.*?)\);', out, re.DOTALL)
    for p in ('ddrcap_i', 'ddrcap_q', 'ddrcap_mark_demod', 'ddrcap_mark_fec', 'ddrcap_valid'):
        assert p in m.group(1), f'{p} not in bank-shape composite port list'
    assert m.group(1).strip().endswith('ddrcap_valid')


def test_composite_portlist_append_regen_shape():
    out = inj._append_top_ports(COMPOSITE_TAIL_REGEN,
                                 ['ddrcap_i', 'ddrcap_q', 'ddrcap_mark_demod',
                                  'ddrcap_mark_fec', 'ddrcap_valid'])
    m = re.search(r'module\s+\w+\s*\((.*?)\);', out, re.DOTALL)
    for p in ('ddrcap_i', 'ddrcap_q', 'ddrcap_mark_demod', 'ddrcap_mark_fec', 'ddrcap_valid'):
        assert p in m.group(1), \
            f'{p} not in regen-shape (framestat_wordcnt-tail) composite port list -- the ' \
            'same-class defect the ruling flagged TxRxComposite.v for'
    assert 'framestat_wordcnt' in m.group(1)
    assert m.group(1).strip().endswith('ddrcap_valid')


def run():
    fails = 0
    for fn in (test_patch_transmitter_bank_shape_lands_in_port_list,
               test_patch_transmitter_regen_shape_lands_in_port_list,
               test_patch_transmitter_idempotent_both_shapes,
               test_patch_qpsk_tx_bank_shape_lands_in_port_list,
               test_patch_qpsk_tx_regen_shape_lands_in_port_list,
               test_patch_qpsk_tx_idempotent_both_shapes,
               test_composite_portlist_append_bank_shape,
               test_composite_portlist_append_regen_shape):
        try:
            fn()
            print(f"  [PASS] {fn.__name__}")
        except AssertionError as e:
            fails += 1
            print(f"  [FAIL] {fn.__name__}: {e}")
    print(f"\nTEST_DDRCAP_INJECT_PORTLIST {'ALL PASS' if not fails else f'{fails} FAILED'}")
    return fails


if __name__ == "__main__":
    sys.exit(1 if run() else 0)
