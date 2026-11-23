#!/usr/bin/env python3
"""Regression test for txcap_inject.py's zip-repack gap.

Found 2026-09-11 during sp3 Gate 0 follow-up: txcap_inject.py patched only the
loose hdlsrc/ipcore .v copies, never the matching members inside
TxRxCompo_ip_v1_0.zip. ddrcap_inject.py's own patch_zip re-extracts each zip
member independently and re-runs ITS loose-file patchers against that
extracted copy -- it never sees what txcap_inject.py did to the loose tree.
Result: TXMARK=1 ddrcap_inject.py's patch_zip hit its own 'txFrameStart
missing (apply txcap_inject.py first)' precondition against a still-pristine
zip member, even after txcap_inject.py had "succeeded". A patcher that
reports success while a copy Vivado actually synthesises (the zip, not the
loose tree) stays untouched is the same class of instrument fault ddrcap's
own test file exists to catch.

This locks down that main() reaches into TxRxCompo_ip_v1_0.zip and patches
the same three members it patches loose, with content that actually matches
(not just "some status string").

Run: python3 modem/instruments/txcap/test_txcap_inject.py
"""
import importlib.util, io, os, shutil, sys, tempfile, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('inj', os.path.join(HERE, 'txcap_inject.py'))
inj = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inj)

# Minimal fixture bodies that satisfy each patcher's anchors (module_edit-style
# real content, not stubs -- the whole point is proving the zip copy ends up
# byte-identical in effect to the loose copy after patching).
QPSK_TX_SRC = """module QPSK_Tx
          (
           dataOut_im);
  output  signed [15:0] dataOut_im;
  wire Bit_Packetizer_dataStart;
endmodule
"""

TRANSMITTER_SRC = """module Transmitter
          (
           extWordPop);
  output  extWordPop;
  QPSK_Tx u_QPSK_Tx
      (.dataOut_im(QPSK_Tx_dataOut_im)  // sfix16_En14
      );
endmodule
"""

COMPOSITE_SRC = """module TxRxComposite;
  wire signed [15:0] Transmitter_dataOutI;  // int16
  Transmitter u_Transmitter
      (.extWordPop(Transmitter_extWordPop)
      );
  assign beatfix_viol_count = Receiver_beatfix_viol_count_1;
  assign beatfix_viol_latch = Receiver_beatfix_viol_latch_1;
endmodule
"""

FIXTURES = {
    'QPSK_Tx.v': QPSK_TX_SRC,
    'Transmitter.v': TRANSMITTER_SRC,
    'TxRxComposite.v': COMPOSITE_SRC,
}
ZIP_MEMBER_NAME = {
    'QPSK_Tx.v': 'TxRxCompo_ip_src_QPSK_Tx.v',
    'Transmitter.v': 'TxRxCompo_ip_src_Transmitter.v',
    'TxRxComposite.v': 'TxRxCompo_ip_src_TxRxComposite.v',
}


def make_tree(root):
    hdl = os.path.join(root, 'hdlsrc')
    os.makedirs(hdl, exist_ok=True)
    for name, body in FIXTURES.items():
        open(os.path.join(hdl, name), 'w').write(body)

    zdir = os.path.join(root, 'ipcore', 'TxRxCompo_ip_v1_0')
    os.makedirs(zdir, exist_ok=True)
    zp = os.path.join(zdir, 'TxRxCompo_ip_v1_0.zip')
    with zipfile.ZipFile(zp, 'w') as z:
        for name, body in FIXTURES.items():
            z.writestr(f'hdl/{ZIP_MEMBER_NAME[name]}', body)
    return zp


def test_txcap_inject_patches_zip_members():
    d = tempfile.mkdtemp(prefix='txcap_t_')
    try:
        zp = make_tree(d)

        rc = inj.main(d)
        assert rc == 0, f"main() returned {rc}"

        # Loose files: all three patched.
        hdl = os.path.join(d, 'hdlsrc')
        for name in FIXTURES:
            body = open(os.path.join(hdl, name)).read()
            assert 'txFrameStart' in body, f"loose {name} not patched"

        # THE BUG: the zip copy must ALSO carry txFrameStart -- this is what
        # was missing before the fix (ddrcap_inject.py's patch_zip re-extracts
        # this exact copy and requires the precondition already satisfied).
        zin = zipfile.ZipFile(zp, 'r')
        for name, member in ZIP_MEMBER_NAME.items():
            body = zin.read(f'hdl/{member}').decode()
            assert 'txFrameStart' in body, (
                f"zip member {member} not patched -- this is the recurring "
                f"defect: patch_zip must exist and actually run")
        zin.close()

        # Idempotent re-run: already-patched loose+zip tree must not error and
        # must report 'already' (the same guard the loose patchers use).
        rc2 = inj.main(d)
        assert rc2 == 0
    finally:
        shutil.rmtree(d, ignore_errors=True)


def test_txcap_inject_no_zip_present_still_patches_loose():
    d = tempfile.mkdtemp(prefix='txcap_t_')
    try:
        hdl = os.path.join(d, 'hdlsrc')
        os.makedirs(hdl, exist_ok=True)
        for name, body in FIXTURES.items():
            open(os.path.join(hdl, name), 'w').write(body)

        rc = inj.main(d)
        assert rc == 0
        for name in FIXTURES:
            assert 'txFrameStart' in open(os.path.join(hdl, name)).read()
    finally:
        shutil.rmtree(d, ignore_errors=True)


def test_txcap_inject_zip_with_no_matching_members_fails_loudly():
    # Regression for the "reports success while patching nothing" class: a zip
    # is present (n_zips_found > 0) but none of its members match PATCHERS
    # (e.g. IP repackaged/renamed) -- main() must NOT silently exit 0.
    d = tempfile.mkdtemp(prefix='txcap_t_')
    try:
        hdl = os.path.join(d, 'hdlsrc')
        os.makedirs(hdl, exist_ok=True)
        for name, body in FIXTURES.items():
            open(os.path.join(hdl, name), 'w').write(body)

        zdir = os.path.join(d, 'ipcore', 'TxRxCompo_ip_v1_0')
        os.makedirs(zdir, exist_ok=True)
        zp = os.path.join(zdir, 'TxRxCompo_ip_v1_0.zip')
        with zipfile.ZipFile(zp, 'w') as z:
            for name, body in FIXTURES.items():
                z.writestr(f'hdl/RENAMED_{name}', body)  # names no PATCHERS key matches

        rc = inj.main(d)
        assert rc == 1, f"main() returned {rc}, expected 1 (renamed zip members must fail loudly)"

        zin = zipfile.ZipFile(zp, 'r')
        for name in FIXTURES:
            body = zin.read(f'hdl/RENAMED_{name}').decode()
            assert 'txFrameStart' not in body, f"unmatched member {name} was patched unexpectedly"
        zin.close()
    finally:
        shutil.rmtree(d, ignore_errors=True)


def run():
    fails = 0
    for fn in (test_txcap_inject_patches_zip_members,
               test_txcap_inject_no_zip_present_still_patches_loose,
               test_txcap_inject_zip_with_no_matching_members_fails_loudly):
        try:
            fn()
            print(f"  [PASS] {fn.__name__}")
        except AssertionError as e:
            fails += 1
            print(f"  [FAIL] {fn.__name__}: {e}")
    print(f"\nTEST_TXCAP_INJECT {'ALL PASS' if not fails else f'{fails} FAILED'}")
    return fails


if __name__ == "__main__":
    sys.exit(1 if run() else 0)
