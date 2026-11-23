#!/usr/bin/env python3
"""Regression test for txcap_inject.py's _append_top_ports generalisation.

Found 2026-09-11 (sp3 Task 1, round 1, downstream Verilator probe of the
regen tree): patch_transmitter's port-list append anchored on the literal
"           extWordPop);" tail. On the current-model (11.334) regen shape,
Transmitter.v's port list ends "..., extWordPop, fs_txur);" (FrameStat's
fs_txur lands after extWordPop) -- the anchor missed, so txFrameStart never
reached the port list, even though the separately-anchored I/O declaration
append DID succeed. Verilator: txFrameStart (and, downstream, ddrcap's
modOut_re/modOut_im/modValid/scramBit/scramValid) ended up declared but
absent from the port list -- a silent compile-breaking defect that
`assert s.count('txFrameStart') >= 3` did not catch (it counted the
declaration and the instantiation-tail edits, not port-list membership).

Fix: patch_qpsktx/patch_transmitter now use _append_top_ports, which finds
the module's OWN port list (first `module ... ( ... );` block) and splices
new ports in after whatever the CURRENT last port is, instead of a frozen
literal. This locks down both shapes for both patchers, and asserts zero
declared-but-unlisted outputs (the exact defect class Verilator caught).

Run: python3 modem/instruments/txcap/test_txcap_inject_portlist_shapes.py
"""
import importlib.util, os, re, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('inj', os.path.join(HERE, 'txcap_inject.py'))
inj = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inj)


def declared_but_unlisted(body):
    """Outputs declared via 'output ... name;' whose name does not appear
    inside the module's own port list. Mirrors the exact Verilator defect
    class (declared, unlisted -> port-count mismatch at instantiation)."""
    m = re.search(r'module\s+\w+\s*\((.*?)\);', body, re.DOTALL)
    assert m, 'no module port list in fixture'
    port_list = set(p.strip() for p in m.group(1).split(',') if p.strip())
    declared = set(re.findall(r'output\s+(?:signed\s+)?(?:\[[^\]]+\]\s+)?(\w+);', body))
    return declared - port_list


TRANSMITTER_BANK = """module Transmitter
          (
           extWordPop);
  output  extWordPop;
  QPSK_Tx u_QPSK_Tx
      (.dataOut_im(QPSK_Tx_dataOut_im)  // sfix16_En14
      );
endmodule
"""

# Regen shape (current 11.334 model): FrameStat's fs_txur lands AFTER
# extWordPop on both the port list and the I/O declarations -- the shape
# that broke the literal "extWordPop);" anchor.
TRANSMITTER_REGEN = """module TxRxCompo_ip_src_Transmitter
          (
           extWordPop,
           fs_txur);
  output  extWordPop;
  output  fs_txur;
  QPSK_Tx u_QPSK_Tx
      (.dataOut_im(QPSK_Tx_dataOut_im)  // sfix16_En14
      );
endmodule
"""


def _run(body):
    d = tempfile.mkdtemp(prefix='txcap_pl_')
    try:
        p = os.path.join(d, 'Transmitter.v')
        open(p, 'w').write(body)
        status = inj.patch_transmitter(p)
        out = open(p).read()
        return status, out
    finally:
        shutil.rmtree(d, ignore_errors=True)


# QPSK_Tx.v -- patch_qpsktx's own port-list append (also went through
# _append_top_ports in this fix; round 1 only re-anchored Transmitter.v).
# No live current-model divergence is known for QPSK_Tx.v's own port list
# (dataOut_im is genuinely last in both the bank and the 11.334 regen tree),
# so REGEN here is a synthetic "something new trails the expected last port"
# fixture -- it exercises the same generalisation, proving it is not
# accidentally still anchored to a literal 'dataOut_im);' string.
QPSKTX_BANK = """module QPSK_Tx
          (
           dataOut_re,
           dataOut_im);
  output  signed [15:0] dataOut_re;  // sfix16_En14
  output  signed [15:0] dataOut_im;  // sfix16_En14
endmodule
"""

QPSKTX_REGEN = """module TxRxCompo_ip_src_QPSK_Tx
          (
           dataOut_re,
           dataOut_im,
           dataReady);
  output  signed [15:0] dataOut_re;  // sfix16_En14
  output  signed [15:0] dataOut_im;  // sfix16_En14
  output  dataReady;
endmodule
"""


def _run_qpsktx(body):
    d = tempfile.mkdtemp(prefix='txcap_pl_')
    try:
        p = os.path.join(d, 'QPSK_Tx.v')
        open(p, 'w').write(body)
        status = inj.patch_qpsktx(p)
        out = open(p).read()
        return status, out
    finally:
        shutil.rmtree(d, ignore_errors=True)


def test_patch_qpsktx_bank_shape_lands_in_port_list():
    status, out = _run_qpsktx(QPSKTX_BANK)
    assert status == 'patched', status
    m = re.search(r'module\s+\w+\s*\((.*?)\);', out, re.DOTALL)
    assert 'txFrameStart' in m.group(1), 'txFrameStart not in bank-shape port list'
    assert not declared_but_unlisted(out), declared_but_unlisted(out)


def test_patch_qpsktx_regen_shape_lands_in_port_list():
    status, out = _run_qpsktx(QPSKTX_REGEN)
    assert status == 'patched', status
    m = re.search(r'module\s+\w+\s*\((.*?)\);', out, re.DOTALL)
    assert 'txFrameStart' in m.group(1), \
        'txFrameStart not in regen-shape (dataReady-tail) port list'
    assert 'dataReady' in m.group(1), 'dataReady must survive the splice'
    assert not declared_but_unlisted(out), declared_but_unlisted(out)


def test_patch_qpsktx_idempotent_both_shapes():
    for body in (QPSKTX_BANK, QPSKTX_REGEN):
        status1, out1 = _run_qpsktx(body)
        assert status1 == 'patched'
        d = tempfile.mkdtemp(prefix='txcap_pl_')
        try:
            p = os.path.join(d, 'QPSK_Tx.v')
            open(p, 'w').write(out1)
            assert inj.patch_qpsktx(p) == 'already'
        finally:
            shutil.rmtree(d, ignore_errors=True)


def test_patch_transmitter_bank_shape_lands_in_port_list():
    status, out = _run(TRANSMITTER_BANK)
    assert status == 'patched', status
    m = re.search(r'module\s+\w+\s*\((.*?)\);', out, re.DOTALL)
    assert 'txFrameStart' in m.group(1), 'txFrameStart not in bank-shape port list'
    assert not declared_but_unlisted(out), declared_but_unlisted(out)


def test_patch_transmitter_regen_shape_lands_in_port_list():
    status, out = _run(TRANSMITTER_REGEN)
    assert status == 'patched', status
    m = re.search(r'module\s+\w+\s*\((.*?)\);', out, re.DOTALL)
    assert 'txFrameStart' in m.group(1), \
        'txFrameStart not in regen-shape (fs_txur-tail) port list -- the exact 2026-09-11 defect'
    assert 'fs_txur' in m.group(1), 'fs_txur must survive the splice'
    assert not declared_but_unlisted(out), declared_but_unlisted(out)


def test_patch_transmitter_idempotent_both_shapes():
    for body in (TRANSMITTER_BANK, TRANSMITTER_REGEN):
        status1, out1 = _run(body)
        assert status1 == 'patched'
        d = tempfile.mkdtemp(prefix='txcap_pl_')
        try:
            p = os.path.join(d, 'Transmitter.v')
            open(p, 'w').write(out1)
            assert inj.patch_transmitter(p) == 'already'
        finally:
            shutil.rmtree(d, ignore_errors=True)


def run():
    fails = 0
    for fn in (test_patch_transmitter_bank_shape_lands_in_port_list,
               test_patch_transmitter_regen_shape_lands_in_port_list,
               test_patch_transmitter_idempotent_both_shapes,
               test_patch_qpsktx_bank_shape_lands_in_port_list,
               test_patch_qpsktx_regen_shape_lands_in_port_list,
               test_patch_qpsktx_idempotent_both_shapes):
        try:
            fn()
            print(f"  [PASS] {fn.__name__}")
        except AssertionError as e:
            fails += 1
            print(f"  [FAIL] {fn.__name__}: {e}")
    print(f"\nTEST_TXCAP_INJECT_PORTLIST {'ALL PASS' if not fails else f'{fails} FAILED'}")
    return fails


if __name__ == "__main__":
    sys.exit(1 if run() else 0)
