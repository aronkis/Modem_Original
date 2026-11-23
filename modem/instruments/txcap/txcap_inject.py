#!/usr/bin/env python3
"""txcap_inject.py <netlist_dir> -- TX-side capture, anchored on the TRANSMITTER's
own frame start. Apply AFTER dbgcap_inject.py; the two combine into one image.

This is the instrument the TX-vs-RX fork actually needs. Every previous attempt
anchored the window on QPSK_Demodulator_startOut -- a RECEIVER, symbol-domain
event -- while observing the transmitter's SAMPLE-domain output. Nothing in the
design forces those two to keep a constant relative phase, and on hardware they
do not: stage 0 failed its clean-link gate twice (11.15 then 9.76 mismatches/s)
and bounding the window length did not help, because length was never the problem.

Here the anchor is `Bit_Packetizer_dataStart` inside QPSK_Tx -- the transmitter's
own per-frame marker. The capture is therefore phase-locked to the thing it
observes, with no receiver involvement at all.

Wiring (all internal; the IP's top-level ports are unchanged, so the BD is
untouched and a source-only resynth suffices):
  QPSK_Tx.v        : new output txFrameStart = Bit_Packetizer_dataStart
  Transmitter.v    : new output txFrameStart, passed through from u_QPSK_Tx
  TxRxComposite.v  : capture the first 16 TX samples after each txFrameStart as
                     32 bits of hard decisions {sign(I),sign(Q)}, plus a mismatch
                     counter vs the frame-8 reference.

Readout: fixctl bit 12 selects which witness drives the two beatfix_viol registers
  fixctl[12]=0 -> DBGCAP (RX stage capture, selected by iq_debug_mux @0x10C)
  fixctl[12]=1 -> TXCAP  (0x20C = TX decision capture, 0x210 = TX mismatches)
Bits 0-4 remain the fix arms and are untouched by either selector.

PRE-REGISTERED: on a clean run TXCAP mismatches must be 0. On hardware, if TXCAP
mismatches are 0 through a full-magnitude burst while 0x108 accumulates errors,
the transmitter's output is bit-identical every frame and the TX is EXONERATED on
silicon. If TXCAP climbs during bursts, the TX is the source.
"""
import sys, os, re, io, zipfile

REFN = 8
NSMP = 16


# --------------------------------------------------------------------------
# Generic module-port-list append: insert new_ports just before the closing
# `);` of the FILE'S OWN module port list (the first `module ... ( ... );`
# block), whatever the current last port happens to be.
#
# 2026-09-11 (sp3 Task 1, round 1): the literal anchor "           extWordPop);"
# broke silently on the current-model (11.334) regen shape of Transmitter.v,
# whose port list ends "..., extWordPop, fs_txur);" (FrameStat's fs_txur
# lands after extWordPop) -- txFrameStart never made it into the port list,
# only the I/O declaration (a separately-anchored, already-safe append), so
# ddrcap_inject.py's downstream patch_transmitter also silently missed its
# own port-list append and the module compiled with declared-but-unlisted
# outputs. Same fix shape as the pdWitB / timingOffset-width dispatches
# elsewhere in this chain: match the CURRENT model's RTL, not a frozen
# literal string.
# --------------------------------------------------------------------------

def _append_top_ports(s, new_ports):
    m = re.search(r'module\s+\w+\s*\(.*?\);', s, re.DOTALL)
    assert m, 'module port list not found'
    block = m.group(0)
    pm = re.search(r'\n([ \t]*)(\w+)\);\Z', block)
    assert pm, f'module port list has unexpected tail: {block[-80:]!r}'
    indent, last = pm.group(1), pm.group(2)
    ins = ''.join(f',\n{indent}{p}' for p in new_ports)
    new_block = block[:pm.start()] + f'\n{indent}{last}' + ins + ');'
    new_s = s[:m.start()] + new_block + s[m.end():]
    for p in new_ports:
        assert p in new_s, f'_append_top_ports: {p} missing after splice'
    return new_s

TXBLOCK = """
  // ==================================================================
  // 2026-08-30 TXCAP -- transmitter-anchored decision capture (txcap_inject.py).
  // Anchor is the TX's OWN frame start, so the window is phase-locked to the
  // signal it observes. First %d TX samples after each start, as hard decisions.
  // ==================================================================
  reg  [31:0] txcap;
  reg  [31:0] txcapl;
  reg  [31:0] txcref;
  reg  [31:0] txcmm;
  reg  [7:0]  txcidx;
  reg  [15:0] txcfc;

  always @(posedge clk or posedge reset)
    begin : txcap_process
      if (reset == 1'b1) begin
        txcap  <= 32'd0;
        txcapl <= 32'd0;
        txcref <= 32'd0;
        txcmm  <= 32'd0;
        txcidx <= 8'd0;
        txcfc  <= 16'd0;
      end
      else if (enb_1_2_0) begin
        if (Transmitter_txFrameStart) begin
          txcapl <= txcap;
          if (txcfc == 16'd%d) begin
            txcref <= txcap;
          end
          else if (txcfc > 16'd%d) begin
            if (txcap != txcref && txcmm != 32'hFFFFFFFF) begin
              txcmm <= txcmm + 32'd1;
            end
          end
          txcap  <= 32'd0;
          txcidx <= 8'd0;
          txcfc  <= (txcfc == 16'hFFFF) ? txcfc : (txcfc + 16'd1);
        end
        else if (txcidx < 8'd%d) begin
          txcap  <= {txcap[29:0], Transmitter_dataOutI[15], Transmitter_dataOutQ[15]};
          txcidx <= txcidx + 8'd1;
        end
      end
    end
""" % (NSMP, REFN, REFN, NSMP)


def patch_qpsktx(path):
    s = open(path).read()
    if 'txFrameStart' in s:
        return 'already'
    s = _append_top_ports(s, ['txFrameStart'])
    s = s.replace("  output  signed [15:0] dataOut_im;",
                  "  output  signed [15:0] dataOut_im;\n  output  txFrameStart;", 1)
    if '  output  txFrameStart;' not in s:   # port decl style differs between generations
        m = re.search(r"\n  output [^\n]*dataOut_im[^\n]*\n", s)
        assert m, 'QPSK_Tx dataOut_im output decl not found'
        s = s[:m.end()] + "  output  txFrameStart;\n" + s[m.end():]
    s = s.rstrip()
    assert s.endswith('endmodule') or 'endmodule' in s
    i = s.rindex('endmodule')
    s = s[:i] + "  assign txFrameStart = Bit_Packetizer_dataStart;\n\n" + s[i:] + "\n"
    assert s.count('txFrameStart') >= 3, 'QPSK_Tx patch failed'
    open(path, 'w').write(s)
    return 'patched'


def patch_transmitter(path):
    s = open(path).read()
    if 'txFrameStart' in s:
        return 'already'
    s = _append_top_ports(s, ['txFrameStart'])
    s = s.replace("  output  extWordPop;", "  output  extWordPop;\n  output  txFrameStart;", 1)
    s = s.replace(".dataOut_im(QPSK_Tx_dataOut_im)  // sfix16_En14",
                  ".dataOut_im(QPSK_Tx_dataOut_im),  // sfix16_En14\n"
                  "                                      .txFrameStart(txFrameStart)", 1)
    assert s.count('txFrameStart') >= 3, 'Transmitter patch failed'
    open(path, 'w').write(s)
    return 'patched'


def patch_composite(path):
    s = open(path).read()
    if 'txcap_process' in s:
        return 'already'
    # new wire + Transmitter port
    s = s.replace("  wire signed [15:0] Transmitter_dataOutI;  // int16",
                  "  wire Transmitter_txFrameStart;\n"
                  "  wire signed [15:0] Transmitter_dataOutI;  // int16", 1)
    s = s.replace(".extWordPop(Transmitter_extWordPop)",
                  ".extWordPop(Transmitter_extWordPop),\n"
                  "                                              .txFrameStart(Transmitter_txFrameStart)", 1)
    assert '.txFrameStart(Transmitter_txFrameStart)' in s, 'Transmitter instantiation not patched'
    # capture block + fixctl[12] readout mux
    # prod (modem/prod, flattened model) prefixes the composite's register ports
    # with reg_; dev does not.  The internal nets (Receiver_*) are the same.
    P = 'reg_' if 'reg_fixctl' in s else ''
    a = f"  assign {P}beatfix_viol_count = Receiver_beatfix_viol_count_1;"
    b = f"  assign {P}beatfix_viol_latch = Receiver_beatfix_viol_latch_1;"
    assert a in s and b in s, 'composite beatfix_viol assigns not found'
    s = s.replace(a, TXBLOCK + f"\n  assign {P}beatfix_viol_count = {P}fixctl[12] ? txcapl : Receiver_beatfix_viol_count_1;", 1)
    s = s.replace(b, f"  assign {P}beatfix_viol_latch = {P}fixctl[12] ? txcmm : Receiver_beatfix_viol_latch_1;", 1)
    assert 'txcap_process' in s and f'{P}fixctl[12] ? txcapl' in s, 'composite patch failed'
    open(path, 'w').write(s)
    return 'patched'


# --------------------------------------------------------------------------
# zip-aware pass: ddrcap_inject.py's own patch_zip re-extracts each matching
# member from TxRxCompo_ip_v1_0.zip and re-runs ITS loose-file patchers
# against that extracted copy -- it does not see whatever this script did to
# the loose hdlsrc/ipcore files, because the zip's internal copy is a
# separate blob that only ddrcap_inject.py's patch_zip ever touches. If this
# script only patches the loose tree, ddrcap_inject.py's patch_qpsk_tx then
# hits a pristine (pre-txcap) QPSK_Tx.v inside the zip and fails its own
# 'apply txcap_inject.py first' precondition -- the zip repack stage never
# actually carried txcap's txFrameStart signal. Mirrors
# ddrcap_inject.py's patch_zip (same shape, same zip, txcap's own 3 members).
# --------------------------------------------------------------------------

PATCHERS = {
    ('QPSK_Tx.v', 'TxRxCompo_ip_src_QPSK_Tx.v'): patch_qpsktx,
    ('Transmitter.v', 'TxRxCompo_ip_src_Transmitter.v'): patch_transmitter,
    ('TxRxComposite.v', 'TxRxCompo_ip_src_TxRxComposite.v'): patch_composite,
}


def _patcher_for(fname):
    for names, fn in PATCHERS.items():
        if fname in names:
            return fn
    return None


def patch_zip(zpath):
    """Patch the matching TxRxCompo_ip_src_*.v members in place, in the zip."""
    buf = io.BytesIO(open(zpath, 'rb').read())
    zin = zipfile.ZipFile(buf, 'r')
    entries = []
    n = 0
    for item in zin.infolist():
        data = zin.read(item.filename)
        base = os.path.basename(item.filename)
        fn = _patcher_for(base)
        if fn is not None:
            tmp_dir = zpath + '.txcap_tmp'
            os.makedirs(tmp_dir, exist_ok=True)
            tmp_path = os.path.join(tmp_dir, base)
            open(tmp_path, 'wb').write(data)
            status = fn(tmp_path)
            data = open(tmp_path, 'rb').read()
            os.remove(tmp_path)
            os.rmdir(tmp_dir)
            print(f"    zip member {base:45s} {status:8s} ({os.path.basename(zpath)})")
            n += 1
        entries.append((item, data))
    zin.close()

    out_buf = io.BytesIO()
    zout = zipfile.ZipFile(out_buf, 'w', zipfile.ZIP_DEFLATED)
    for item, data in entries:
        zout.writestr(item, data)
    zout.close()
    open(zpath, 'wb').write(out_buf.getvalue())
    return n


def main(d):
    n = 0
    for root, _, files in os.walk(d):
        if root.endswith('.txcap_tmp'):
            continue
        for f in files:
            p = os.path.join(root, f)
            if f in ('QPSK_Tx.v', 'TxRxCompo_ip_src_QPSK_Tx.v'):
                print(f"  QPSK_Tx        {patch_qpsktx(p):8s} {p}"); n += 1
            elif f in ('Transmitter.v', 'TxRxCompo_ip_src_Transmitter.v'):
                print(f"  Transmitter    {patch_transmitter(p):8s} {p}"); n += 1
            elif f in ('TxRxComposite.v', 'TxRxCompo_ip_src_TxRxComposite.v'):
                print(f"  TxRxComposite  {patch_composite(p):8s} {p}"); n += 1

    n_zip = 0
    n_zips_found = 0
    for root, _, files in os.walk(d):
        for f in files:
            if f == 'TxRxCompo_ip_v1_0.zip':
                n_zips_found += 1
                zp = os.path.join(root, f)
                print(f"  zip {zp}")
                n_zip += patch_zip(zp)

    print(f"TXCAP_INJECT files={n} zip_members_patched={n_zip} zips_found={n_zips_found}")

    if n_zips_found > 0 and n_zip == 0:
        wanted = sorted({x for names in PATCHERS for x in names})
        print(f"TXCAP_INJECT_FAIL: {n_zips_found} zip(s) found but no member matched "
              f"{wanted} -- likely a renamed/repackaged IP; check PATCHERS keys")
        return 1

    return 0 if n else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
