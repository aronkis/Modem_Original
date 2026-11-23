#!/usr/bin/env python3
"""ddrcap2_inject.py <netlist_dir> -- DDRCAP-v2 second-pass injector (spec
docs/superpowers/specs/2026-09-02-ddrcap2-joint-timing-capture-design.md).
Run AFTER `TXMARK=1 ddrcap_inject.py <dir>`. Threads the timing/correlator/
interpolator signals up to TxRxComposite, repacks the two marker ports as
ch2 = {mark_demod, mark_fec, timingOffset[13:0]} and ch3 = {slot, side[13:0]},
and adds selectors 12-15. Top-level IP ports, packer, DMA and BD are UNCHANGED.
Idempotent: every patcher returns 'already' on a patched file.
"""
import sys, os, io, re, zipfile

# ---------------------------------------------------------------- record layout per frame
# f1536 / k5 (the shipped layout, spec sec 2): timingOffset and tref are 14-bit and the
# record is ch2 = {mark_demod, mark_fec, toff[13:0]}, ch3 = {slot[1:0], side[13:0]}.
# f3072 (the sp4 rung, 2026-09-19): the search window is 24634 slots, so Peak_Search emits
# ufix15 timingOffset / p1c_tref and the 14-bit fields cannot hold them. The WIDE layout
# moves mark_fec into ch3 and narrows the sidecar to 13 bits:
#   ch2 = {mark_demod, toff[14:0]}
#   ch3 = {mark_fec, slot[1:0], side[12:0]}   side: heldts[12:0], tref[14:2], runmax[31:19], corrthr[31:19]
# (tref at 4-slot resolution -- monotone-mod checks and frame-phase forensics keep working).
# Selected by QPSK_FRAME (the hdl stage exports it); ops/flash/ddrcap2_decode.py takes --frame.
WIDE = os.environ.get('QPSK_FRAME', '') == 'f3072'
TOFF_W = 15 if WIDE else 14

# (name, width-string ('' = 1 bit), tag)
PD_PORTS = [
    ("dc_toff", f"[{TOFF_W-1}:0]", f"ufix{TOFF_W}"),
    ("dc_tref", f"[{TOFF_W-1}:0]", f"ufix{TOFF_W}"),
    ("dc_heldts", "[31:0]", "uint32"),
    ("dc_corr", "signed [31:0]", "sfix32_En26"),
    ("dc_corrthr", "signed [31:0]", "sfix32_En28"),
    ("dc_corrvalid", "", ""),
]
SS_PORTS = [
    ("dc_countreg", "signed [10:0]", "sfix11"),
    ("dc_mu", "signed [10:0]", "sfix11_En10"),
    ("dc_underflow", "", ""),
    ("dc_interp_re", "signed [18:0]", "sfix19_En12"),
    ("dc_interp_im", "signed [18:0]", "sfix19_En12"),
]


def add_ports(s, after, names):
    """Insert port names into a module header after port `after` (handles both
    '           after,' and the terminal '           after);')."""
    a1 = f"           {after},\n"
    a2 = f"           {after});"
    ins = "".join(f"           {n},\n" for n in names)
    if a1 in s:
        return s.replace(a1, a1 + ins, 1)
    assert a2 in s, f"port anchor '{after}' not found"
    return s.replace(a2, f"           {after},\n" + ins.rstrip().rstrip(',') + ");", 1)


def decl_lines(ports, kind, prefix=''):
    """kind='output' -> port decls; kind='wire' -> local wires named prefix+name."""
    out = ""
    for n, w, tag in ports:
        nm = prefix + n
        if kind == 'output':
            out += f"  output  {w} {nm};  // {tag}\n" if w else f"  output  {nm};\n"
        else:
            out += f"  wire {w} {nm};  // {tag}\n" if w else f"  wire {nm};\n"
    return out


def _insert_after(s, anchor, text):
    assert anchor in s, f"anchor missing: {anchor[:60]!r}"
    return s.replace(anchor, anchor + text, 1)


def _insert_before_endmodule(s, text):
    assert '\nendmodule' in s
    j = s.rindex('\nendmodule')
    return s[:j] + '\n' + text.rstrip('\n') + '\n' + s[j:]


# ---------------------------------------------------------------- Interpolation_Control.v
def patch_interpolation_control(path):
    s = open(path).read()
    if 'countRegOut' in s:
        return 'already'
    assert 'reg signed [10:0] countReg;  // sfix11' in s, 'countReg decl anchor missing'
    s = add_ports(s, 'Underflow', ['countRegOut'])
    s = _insert_after(s, "  output  Underflow;\n", "  output  signed [10:0] countRegOut;  // sfix11\n")
    s = _insert_before_endmodule(s, "  assign countRegOut = countReg;  // DDRCAP2: raw NCO phase accumulator\n")
    assert s.count('countRegOut') == 3
    open(path, 'w').write(s)
    return 'patched'



# ---------------------------------------------------------------- Symbol_Synchronizer shapes
# - beatobs (2026-08-20 .. 2026-09-23): the BEATOBS overlay's Rate-Handle taps are the LAST
#   ports of Symbol_Synchronizer (beatobsRhCtr/beatobsPush/beatobsPop; rxfix_w1/steer keep
#   them last by design) and ddrcap2 reads them as its sel-15 channels.
# - nobeatobs (2026-09-24, docs/evidence/sp4/TAP_A_BEATOBS.md): the observer is gone (HDL
#   Coder prunes it once its packer output is not consumed), so the last port is the RXFIX
#   steering witness `sro_mode` and the sel-15 Rate-Handle channels read as ZERO.
SS_SHAPES = (  # (last port, its output decl line, its assign line, present-if)
    ('beatobsPop', "  output  [4:0] beatobsPop;  // ufix5\n", "  assign beatobsPop = Rate_Handle_beatobsPop;\n"),
    ('sro_mode',   "  output  [31:0] sro_mode;  // uint32\n",  "  assign sro_mode = Rate_Handle_sro_mode;\n"),
)


def _ss_last_port(s):
    """(last_port, decl_line, assign_line) of the Symbol_Synchronizer shape present in s."""
    for name, decl, assign in SS_SHAPES:
        if decl in s and assign in s:
            return name, decl, assign
    raise AssertionError("anchor missing: Symbol_Synchronizer last-port shape not recognised "
                         "(neither beatobsPop nor sro_mode decl+assign present)")


def _ss_inst_shape(s):
    """Symbol_Synchronizer instantiation tail inside FTS: (tail literal, last-pin name,
    wire-decl anchor line, has_beatobs)."""
    ind = " " * 62
    for name, wire_anchor, tag, has_bo in (
        ('beatobsPop', "  wire [7:0] Symbol_Synchronizer_beatobsRhCtr;  // uint8\n", "ufix5", True),
        ('sro_mode',   "  wire [31:0] Symbol_Synchronizer_sro_mode;  // uint32\n", "uint32", False),
    ):
        tail = f".{name}(Symbol_Synchronizer_{name})  // {tag}\n{ind});"
        if tail in s and wire_anchor in s:
            return tail, name, wire_anchor, tag, has_bo
    raise AssertionError("anchor missing: u_Symbol_Synchronizer instantiation tail not recognised "
                         "(neither .beatobsPop(...) // ufix5 nor .sro_mode(...) // uint32 shape)")

# ---------------------------------------------------------------- Symbol_Synchronizer.v
def patch_symbol_synchronizer(path):
    s = open(path).read()
    if 'dc_countreg' in s:
        return 'already'
    ss_last, ss_last_decl, ss_last_assign = _ss_last_port(s)
    for need in ("  wire signed [10:0] mu;  // sfix11_En10\n", "  wire Underflow;\n",
                 "  reg signed [18:0] Delay8_out1_re;  // sfix19_En12\n",
                 ss_last_assign,
                 ".Underflow(Underflow)\n                                                                  );"):
        assert need in s, f'anchor missing in {path}: {need[:50]!r}'
    s = add_ports(s, ss_last, [n for n, _, _ in SS_PORTS])
    s = _insert_after(s, ss_last_decl, decl_lines(SS_PORTS, 'output'))
    s = _insert_after(s, "  wire signed [10:0] mu;  // sfix11_En10\n",
                      "  wire signed [10:0] Interpolation_Control_countRegOut;  // sfix11\n")
    s = s.replace(".Underflow(Underflow)\n                                                                  );",
                  ".Underflow(Underflow),\n"
                  "                                                                  .countRegOut(Interpolation_Control_countRegOut)\n"
                  "                                                                  );", 1)
    s = _insert_after(s, ss_last_assign,
                      "\n  // DDRCAP2 interpolator phase/buffer exposure\n"
                      "  assign dc_countreg = Interpolation_Control_countRegOut;\n"
                      "  assign dc_mu = mu;\n"
                      "  assign dc_underflow = Underflow;\n"
                      "  assign dc_interp_re = Delay8_out1_re;\n"
                      "  assign dc_interp_im = Delay8_out1_im;\n")
    assert '.countRegOut(Interpolation_Control_countRegOut)' in s
    open(path, 'w').write(s)
    return 'patched'


# ---------------------------------------------------------------- Preamble_Detector.v
#   Peak_Search_timingOffset / Peak_Search_p1c_tref width shapes:
#   - bank (pre-2026-09 / model <=11.331 lineage): both ufix14 ([13:0]).
#   - regen (current 11.334 model): both narrowed to ufix11 ([10:0]) --
#     Peak_Search itself no longer produces the extra 3 bits. Controller
#     ruling (2026-09-11, sub-project 3 ledger): ddrcap/ddrcap2 anchors must
#     match the CURRENT model's RTL, not the bank's -- so this is handled as
#     a shape dispatch (zero-extend at the source assign), not a hard
#     14-bit-only anchor. dc_toff/dc_tref STAY 14-bit ports (PD_PORTS is
#     unchanged) so every downstream consumer -- the ch2/ch3 packing in
#     patch_composite ([13:0] part-selects), ops/flash/ddrcap2_decode.py's
#     record layout, and ops/tests/test_ddrcap2_inject.py (which runs
#     against the 14-bit s1_rtl_txmark bank shape) -- is unaffected. Under
#     11.334 the top 3 bits of dc_toff/dc_tref simply read zero (Peak_Search
#     doesn't produce them); if a future SRO need requires offsets >2047 that
#     is a model-side search-window question, not an injector one.
PD_TOFF_TREF_BANK = ("  wire [13:0] Peak_Search_timingOffset;  // ufix14\n",
                      "  wire [13:0] Peak_Search_p1c_tref;  // ufix14\n")
PD_TOFF_TREF_REGEN = ("  wire [10:0] Peak_Search_timingOffset;  // ufix11\n",
                      "  wire [10:0] Peak_Search_p1c_tref;  // ufix11\n")
PD_TOFF_TREF_F3072 = ("  wire [14:0] Peak_Search_timingOffset;  // ufix15\n",
                      "  wire [14:0] Peak_Search_p1c_tref;  // ufix15\n")


def patch_preamble_detector(path):
    s = open(path).read()
    if 'dc_toff' in s:
        return 'already'
    if PD_TOFF_TREF_BANK[0] in s and PD_TOFF_TREF_BANK[1] in s:
        toff_assign = "  assign dc_toff = Peak_Search_timingOffset;\n"
        tref_assign = "  assign dc_tref = Peak_Search_p1c_tref;\n"
    elif PD_TOFF_TREF_REGEN[0] in s and PD_TOFF_TREF_REGEN[1] in s:
        toff_assign = "  assign dc_toff = {3'b0, Peak_Search_timingOffset};\n"
        tref_assign = "  assign dc_tref = {3'b0, Peak_Search_p1c_tref};\n"
    elif PD_TOFF_TREF_F3072[0] in s and PD_TOFF_TREF_F3072[1] in s:
        assert WIDE, f'{path}: ufix15 Peak_Search_timingOffset/p1c_tref (the f3072 search window) but QPSK_FRAME is not f3072 -- the 14-bit record layout cannot hold it'
        toff_assign = "  assign dc_toff = Peak_Search_timingOffset;\n"
        tref_assign = "  assign dc_tref = Peak_Search_p1c_tref;\n"
    else:
        assert False, f'anchor missing in {path}: Peak_Search_timingOffset/p1c_tref (neither ufix14, ufix11 nor ufix15 shape found)'
    if WIDE:
        assert PD_TOFF_TREF_F3072[0] in s, f'{path}: QPSK_FRAME=f3072 (15-bit record layout) but Peak_Search_timingOffset is not ufix15'
    for need in ("  wire [31:0] Peak_Search_p1c_heldts;  // uint32\n",
                 "  wire signed [31:0] Correlator_dataOut;  // sfix32_En26\n",
                 "  wire signed [31:0] Correlator_threshold;  // sfix32_En28\n",
                 "  wire Correlator_validOut;\n",
                 "  assign fs_runmax = Peak_Search_p1c_runmax;\n",
                 "  output  signed [31:0] fs_runmax;  // sfix32_En26\n"):
        assert need in s, f'anchor missing in {path}: {need[:50]!r}'
    s = add_ports(s, 'fs_runmax', [n for n, _, _ in PD_PORTS])
    s = _insert_after(s, "  output  signed [31:0] fs_runmax;  // sfix32_En26\n", decl_lines(PD_PORTS, 'output'))
    s = _insert_after(s, "  assign fs_runmax = Peak_Search_p1c_runmax;\n",
                      "\n  // DDRCAP2 timing/correlator-plane exposure (full 14-bit timingOffset,\n"
                      "  // NOT PdTelemetry's 11-bit tOff)\n"
                      + toff_assign
                      + tref_assign
                      + "  assign dc_heldts = Peak_Search_p1c_heldts;\n"
                      "  assign dc_corr = Correlator_dataOut;\n"
                      "  assign dc_corrthr = Correlator_threshold;\n"
                      "  assign dc_corrvalid = Correlator_validOut;\n")
    assert s.count('dc_corrvalid') == 3
    open(path, 'w').write(s)
    return 'patched'


FTS_PORTS = PD_PORTS + [("dc_runmax", "signed [31:0]", "sfix32_En26")] + SS_PORTS + [
    ("dc_rhctr", "[7:0]", "uint8"), ("dc_rhpush", "[4:0]", "ufix5"), ("dc_rhpop", "[4:0]", "ufix5")]
RX_PORTS = [("ddrcap_" + n, w, t) for n, w, t in FTS_PORTS]


# ---------------------------------------------------------------- Frequency_and_Time_Synchronizer.v
#   - bank (pre-2026-09 experiments; still present in banked/archived trees):
#     the module's own port list AND the u_Preamble_Detector instantiation
#     both terminate on the pdWitA/pdWitB/enSlack "slack FIFO" witness
#     lineage. Controller ruling (2026-09-11, sub-project 3 ledger): those
#     ports are dead nets from an abandoned experiment (docs/evidence/
#     RXFIX_STATE.md records enSlack as a null result, pdWitA/pdWitB as dead
#     nets) -- they are NOT reproduced by any .m in the bank or repo, and are
#     NOT to be reproduced here. The bank shape is still handled below purely
#     so this injector stays a no-op ('already'/idempotent-safe) against any
#     already-committed bank tree; it does not add new pdWit*/enSlack wiring.
#   - regen (current 11.334 model; no pdWit*/enSlack anywhere): both
#     terminate on fs_runmax, Preamble_Detector's own real output port.
# If a third shape appears, extend this pair rather than loosening either
# anchor to a substring match -- same policy as every other assert in this
# file (see the note this replaced, 2026-09-02).
BANK_PD_TAIL = "                                        .pdWitB(pdWitB));"
REGEN_PD_TAIL = ("                                                          .fs_runmax(Preamble_Detector_fs_runmax)  // sfix32_En26\n"
                 "                                                          );")


def _pd_tail_shape(s):
    """Return ('bank', BANK_PD_TAIL, 'pdWitB') or ('regen', REGEN_PD_TAIL,
    'fs_runmax') depending on which u_Preamble_Detector instantiation tail
    (and matching FTS-own port-list anchor name) is present. Raises if
    neither is found -- same fail-loud policy as every other anchor here."""
    if BANK_PD_TAIL in s:
        return 'bank', BANK_PD_TAIL, 'pdWitB'
    if REGEN_PD_TAIL in s:
        return 'regen', REGEN_PD_TAIL, 'fs_runmax'
    raise AssertionError(
        "anchor missing: u_Preamble_Detector instantiation tail not recognised "
        "(neither bank .pdWitB(pdWitB)); nor regen .fs_runmax(...) // sfix32_En26 shape)")


def patch_fts(path):
    s = open(path).read()
    if 'dc_toff' in s:
        return 'already'
    # NOTE: brief anchors pd_tail/ss_tail had one extra leading space vs the
    # real s1_rtl_txmark netlist (verified 2026-09-02); corrected here to the
    # real file's indentation (40 sp / 62 sp) rather than loosening the assert.
    shape, pd_tail, pd_port_anchor = _pd_tail_shape(s)
    ss_tail, ss_last, ss_wire_anchor, ss_tag, has_bo = _ss_inst_shape(s)
    for need in (ss_tail, "  assign p1c_telQ = Preamble_Detector_p1c_telQ;\n",
                 "  output  signed [31:0] fs_runmax;  // sfix32_En26\n",
                 "  wire signed [31:0] Preamble_Detector_fs_runmax;  // sfix32_En26\n",
                 ss_wire_anchor):
        assert need in s, f'anchor missing in {path}: {need[:50]!r}'
    s = add_ports(s, pd_port_anchor, [n for n, _, _ in FTS_PORTS])
    s = _insert_after(s, "  output  signed [31:0] fs_runmax;  // sfix32_En26\n", decl_lines(FTS_PORTS, 'output'))
    # local wires for the two child instances
    s = _insert_after(s, "  wire signed [31:0] Preamble_Detector_fs_runmax;  // sfix32_En26\n",
                      decl_lines(PD_PORTS, 'wire', 'Preamble_Detector_'))
    s = _insert_after(s, ss_wire_anchor, decl_lines(SS_PORTS, 'wire', 'Symbol_Synchronizer_'))
    pd_conn = "".join(f"                                         .{n}(Preamble_Detector_{n}),\n" for n, _, _ in PD_PORTS)
    if shape == 'bank':
        new_pd_tail = "                                         .pdWitB(pdWitB),\n" + pd_conn.rstrip().rstrip(',') + ");"
    else:
        new_pd_tail = ("                                                          .fs_runmax(Preamble_Detector_fs_runmax),  // sfix32_En26\n"
                       + pd_conn.rstrip().rstrip(',') + "\n"
                       "                                                          );")
    s = s.replace(pd_tail, new_pd_tail, 1)
    ss_conn = "".join(f"                                                               .{n}(Symbol_Synchronizer_{n}),\n" for n, _, _ in SS_PORTS)
    s = s.replace(ss_tail, f".{ss_last}(Symbol_Synchronizer_{ss_last}),  // {ss_tag}\n" + ss_conn.rstrip().rstrip(',') +
                  "\n                                                               );", 1)
    assigns = "\n  // DDRCAP2 pass-through\n"
    for n, _, _ in PD_PORTS:
        assigns += f"  assign {n} = Preamble_Detector_{n};\n"
    assigns += "  assign dc_runmax = Preamble_Detector_fs_runmax;\n"
    for n, _, _ in SS_PORTS:
        assigns += f"  assign {n} = Symbol_Synchronizer_{n};\n"
    if has_bo:
        assigns += ("  assign dc_rhctr = Symbol_Synchronizer_beatobsRhCtr;\n"
                    "  assign dc_rhpush = Symbol_Synchronizer_beatobsPush;\n"
                    "  assign dc_rhpop = Symbol_Synchronizer_beatobsPop;\n")
    else:
        assigns += ("  // no BEATOBS observer in this tree (2026-09-24): sel-15 Rate-Handle channels read zero\n"
                    "  assign dc_rhctr = 8'd0;\n"
                    "  assign dc_rhpush = 5'd0;\n"
                    "  assign dc_rhpop = 5'd0;\n")
    s = _insert_after(s, "  assign p1c_telQ = Preamble_Detector_p1c_telQ;\n", assigns)
    assert '.dc_toff(Preamble_Detector_dc_toff)' in s and '.dc_mu(Symbol_Synchronizer_dc_mu)' in s
    open(path, 'w').write(s)
    return 'patched'


# ---------------------------------------------------------------- QPSK_Rx.v
def patch_qpsk_rx(path):
    s = open(path).read()
    if 'ddrcap_dc_toff' in s:
        return 'already'
    fts_anchor = "                                                                                      .p1c_telQ(Frequency_and_Time_Synchronizer_p1c_telQ),  // int16\n"
    for need in ("           ddrcap_fecstart);", "  output  ddrcap_fecstart;\n", fts_anchor,
                 "  wire signed [15:0] Frequency_and_Time_Synchronizer_p1c_telQ;  // int16\n"):
        assert need in s, f'anchor missing in {path}: {need[:50]!r}'
    s = add_ports(s, 'ddrcap_fecstart', [n for n, _, _ in RX_PORTS])
    s = _insert_after(s, "  output  ddrcap_fecstart;\n", decl_lines(RX_PORTS, 'output'))
    s = _insert_after(s, "  wire signed [15:0] Frequency_and_Time_Synchronizer_p1c_telQ;  // int16\n",
                      decl_lines(FTS_PORTS, 'wire', 'Frequency_and_Time_Synchronizer_'))
    conn = "".join(f"                                                                                      .{n}(Frequency_and_Time_Synchronizer_{n}),\n"
                   for n, _, _ in FTS_PORTS)
    s = s.replace(fts_anchor, fts_anchor + conn, 1)
    assigns = "\n  // DDRCAP2 pass-through\n" + "".join(
        f"  assign ddrcap_{n} = Frequency_and_Time_Synchronizer_{n};\n" for n, _, _ in FTS_PORTS)
    s = _insert_before_endmodule(s, assigns)
    assert 'assign ddrcap_dc_rhpop = Frequency_and_Time_Synchronizer_dc_rhpop;' in s
    open(path, 'w').write(s)
    return 'patched'


# ---------------------------------------------------------------- Receiver.v
def patch_receiver(path):
    s = open(path).read()
    if 'ddrcap_dc_toff' in s:
        return 'already'
    inst_tail = ".ddrcap_fecstart(QPSK_Rx_ddrcap_fecstart)\n                                      );"
    for need in ("           ddrcap_fecstart);", "  output  ddrcap_fecstart;\n", "  wire QPSK_Rx_ddrcap_fecstart;\n", inst_tail):
        assert need in s, f'anchor missing in {path}: {need[:50]!r}'
    s = add_ports(s, 'ddrcap_fecstart', [n for n, _, _ in RX_PORTS])
    s = _insert_after(s, "  output  ddrcap_fecstart;\n", decl_lines(RX_PORTS, 'output'))
    s = _insert_after(s, "  wire QPSK_Rx_ddrcap_fecstart;\n", decl_lines(RX_PORTS, 'wire', 'QPSK_Rx_'))
    conn = "".join(f"                                      .{n}(QPSK_Rx_{n}),\n" for n, _, _ in RX_PORTS)
    s = s.replace(inst_tail, ".ddrcap_fecstart(QPSK_Rx_ddrcap_fecstart),\n" + conn.rstrip().rstrip(',') +
                  "\n                                      );", 1)
    s = _insert_before_endmodule(s, "".join(f"  assign {n} = QPSK_Rx_{n};\n" for n, _, _ in RX_PORTS))
    # brief said ==4; real construction yields 7 (port-list, output decl,
    # QPSK_Rx_-prefixed wire decl, 2x in the connection line, 2x in the
    # top-level assign line) -- corrected, not loosened: 7 is a tighter,
    # arithmetically-derived fact, not a relaxed check.
    assert s.count('ddrcap_dc_rhpop') == 7
    open(path, 'w').write(s)
    return 'patched'


# ---------------------------------------------------------------- TxRxComposite.v
COMPOSITE_PRE = """
  // DDRCAP2 (ddrcap2_inject.py): sidecar slot counter + sticky interpolator-underflow
  // latch, declared BEFORE the mux that reads ddrcap2_uf_now (Verilog use-before-declare).
  reg  [1:0] ddrcap2_slot_r;
  reg        ddrcap2_uf_latch;
  wire       ddrcap2_uf_now = Receiver_ddrcap_dc_underflow | ddrcap2_uf_latch;
"""
COMPOSITE_POST = """
  // DDRCAP2 ch2/ch3 packing (spec sec 2). Sticky-latch marker semantics unchanged:
  // ddrcap_demod_mark_now / ddrcap_fec_mark_now are the same nets as before, now one bit each.
  always @(posedge clk or posedge reset)
    begin : ddrcap2_slot_process
      if (reset == 1'b1) begin
        ddrcap2_slot_r <= 2'd0;
        ddrcap2_uf_latch <= 1'b0;
      end
      else if (enb_1_2_0) begin
        if (ddrcap_valid_beat) begin
          ddrcap2_slot_r <= ddrcap2_slot_r + 2'd1;
        end
        ddrcap2_uf_latch <= ddrcap_valid_beat ? 1'b0 : ddrcap2_uf_now;
      end
    end

  wire [13:0] ddrcap2_side =
      (ddrcap2_slot_r == 2'd0) ? Receiver_ddrcap_dc_heldts[13:0] :
      (ddrcap2_slot_r == 2'd1) ? Receiver_ddrcap_dc_tref[13:0] :
      (ddrcap2_slot_r == 2'd2) ? Receiver_ddrcap_dc_runmax[31:18] :
                                 Receiver_ddrcap_dc_corrthr[31:18];

  assign ddrcap_mark_demod = {ddrcap_demod_mark_now, ddrcap_fec_mark_now, Receiver_ddrcap_dc_toff[13:0]};
  assign ddrcap_mark_fec   = {ddrcap2_slot_r, ddrcap2_side};
"""
# f3072: 15-bit toff, mark_fec moved to ch3, 13-bit sidecar (see the layout note at the top)
COMPOSITE_POST_WIDE = """
  // DDRCAP2 ch2/ch3 packing, f3072 WIDE layout (ddrcap2_inject.py header): 15-bit timingOffset,
  // mark_fec in ch3[15], 13-bit sidecar (tref at 4-slot resolution). Sticky-latch marker
  // semantics unchanged: ddrcap_demod_mark_now / ddrcap_fec_mark_now are one bit each.
  always @(posedge clk or posedge reset)
    begin : ddrcap2_slot_process
      if (reset == 1'b1) begin
        ddrcap2_slot_r <= 2'd0;
        ddrcap2_uf_latch <= 1'b0;
      end
      else if (enb_1_2_0) begin
        if (ddrcap_valid_beat) begin
          ddrcap2_slot_r <= ddrcap2_slot_r + 2'd1;
        end
        ddrcap2_uf_latch <= ddrcap_valid_beat ? 1'b0 : ddrcap2_uf_now;
      end
    end

  wire [12:0] ddrcap2_side =
      (ddrcap2_slot_r == 2'd0) ? Receiver_ddrcap_dc_heldts[12:0] :
      (ddrcap2_slot_r == 2'd1) ? Receiver_ddrcap_dc_tref[14:2] :
      (ddrcap2_slot_r == 2'd2) ? Receiver_ddrcap_dc_runmax[31:19] :
                                 Receiver_ddrcap_dc_corrthr[31:19];

  assign ddrcap_mark_demod = {ddrcap_demod_mark_now, Receiver_ddrcap_dc_toff[14:0]};
  assign ddrcap_mark_fec   = {ddrcap_fec_mark_now, ddrcap2_slot_r, ddrcap2_side};
"""
MUX_I_OLD = "      (ddrcap_sel_r == 4'd8) ? Transmitter_dataOutI :\n      16'sd0;"
MUX_I_NEW = ("      (ddrcap_sel_r == 4'd8) ? Transmitter_dataOutI :\n"
             "      (ddrcap_sel_r == 4'd12) ? Receiver_ddrcap_dc_corr[31:16] :\n"
             "      (ddrcap_sel_r == 4'd13) ? {ddrcap2_uf_now, 4'b0000, Receiver_ddrcap_dc_countreg[10:0]} :\n"
             "      (ddrcap_sel_r == 4'd14) ? Receiver_ddrcap_dc_interp_re[18:3] :\n"
             "      (ddrcap_sel_r == 4'd15) ? {Receiver_ddrcap_dc_rhctr[7:0], Receiver_ddrcap_dc_rhpush[4:0], 3'b000} :\n"
             "      16'sd0;")
MUX_Q_OLD = "      (ddrcap_sel_r == 4'd8) ? Transmitter_dataOutQ :\n      16'sd0;"
MUX_Q_NEW = ("      (ddrcap_sel_r == 4'd8) ? Transmitter_dataOutQ :\n"
             "      (ddrcap_sel_r == 4'd12) ? Receiver_ddrcap_dc_corr[15:0] :\n"
             "      (ddrcap_sel_r == 4'd13) ? {5'b00000, Receiver_ddrcap_dc_mu[10:0]} :\n"
             "      (ddrcap_sel_r == 4'd14) ? Receiver_ddrcap_dc_interp_im[18:3] :\n"
             "      (ddrcap_sel_r == 4'd15) ? {Receiver_ddrcap_dc_rhpop[4:0], 11'b00000000000} :\n"
             "      16'sd0;")
MUX_V_OLD = "      (ddrcap_sel_r == 4'd8) ? enb_1_2_0 :\n      1'b0;"
MUX_V_NEW = ("      (ddrcap_sel_r == 4'd8) ? enb_1_2_0 :\n"
             "      (ddrcap_sel_r == 4'd12) ? Receiver_ddrcap_dc_corrvalid :\n"
             "      (ddrcap_sel_r == 4'd13) ? enb_1_2_0 :\n"
             "      (ddrcap_sel_r == 4'd14) ? enb_1_2_0 :\n"
             "      (ddrcap_sel_r == 4'd15) ? enb_1_2_0 :\n"
             "      1'b0;")
OLD_MARKS = ("  assign ddrcap_mark_demod = ddrcap_demod_mark_now ? 16'h7FFF : 16'h0000;\n"
             "  assign ddrcap_mark_fec   = ddrcap_fec_mark_now   ? 16'h7FFF : 16'h0000;\n")


def patch_composite(path):
    s = open(path).read()
    if 'ddrcap2_slot_r' in s:
        return 'already'
    recv_tail = ".ddrcap_fecstart(Receiver_ddrcap_fecstart)\n                                        );"
    for need in ("  wire Receiver_ddrcap_fecstart;\n", recv_tail, MUX_I_OLD, MUX_Q_OLD, MUX_V_OLD, OLD_MARKS,
                 "  wire signed [15:0] ddrcap_mux_i =\n"):
        assert need in s, f'anchor missing in {path}: {need[:50]!r}'
    assert s.count("(ddrcap_sel_r <= 4'd8) ?") == 3, 'expected exactly 3 sel<=8 conditions'
    s = _insert_after(s, "  wire Receiver_ddrcap_fecstart;\n", decl_lines(RX_PORTS, 'wire', 'Receiver_'))
    conn = "".join(f"                                        .{n}(Receiver_{n}),\n" for n, _, _ in RX_PORTS)
    s = s.replace(recv_tail, ".ddrcap_fecstart(Receiver_ddrcap_fecstart),\n" + conn.rstrip().rstrip(',') +
                  "\n                                        );", 1)
    s = s.replace("  wire signed [15:0] ddrcap_mux_i =\n", COMPOSITE_PRE + "\n  wire signed [15:0] ddrcap_mux_i =\n", 1)
    s = s.replace(MUX_I_OLD, MUX_I_NEW, 1).replace(MUX_Q_OLD, MUX_Q_NEW, 1).replace(MUX_V_OLD, MUX_V_NEW, 1)
    s = s.replace("(ddrcap_sel_r <= 4'd8) ?", "(ddrcap_sel_r <= 4'd8 || ddrcap_sel_r >= 4'd12) ?")
    s = s.replace(OLD_MARKS, (COMPOSITE_POST_WIDE if WIDE else COMPOSITE_POST).lstrip('\n'), 1)
    if 'reg_iq_debug_mux' in s:   # prod: the composite's register ports carry a reg_ prefix
        s = re.sub(r'(?<![A-Za-z0-9_])iq_debug_mux\[', 'reg_iq_debug_mux[', s)
        s = re.sub(r'(?<![A-Za-z0-9_])fixctl\[', 'reg_fixctl[', s)
    assert s.count("ddrcap_sel_r <= 4'd8 || ddrcap_sel_r >= 4'd12") == 3
    assert '.ddrcap_dc_toff(Receiver_ddrcap_dc_toff)' in s and 'ddrcap2_slot_process' in s
    open(path, 'w').write(s)
    return 'patched'


# ---------------------------------------------------------------- dispatch / zip / main (mirrors ddrcap_inject.py)
PATCHERS = {
    'Interpolation_Control.v': patch_interpolation_control,
    'Symbol_Synchronizer.v': patch_symbol_synchronizer,
    'Preamble_Detector.v': patch_preamble_detector,
    'Frequency_and_Time_Synchronizer.v': patch_fts,
    'QPSK_Rx.v': patch_qpsk_rx,
    'Receiver.v': patch_receiver,
    'TxRxComposite.v': patch_composite,
}


def _patcher_for(base):
    if base in PATCHERS:
        return PATCHERS[base]
    if base.startswith('TxRxCompo_ip_src_') and base[len('TxRxCompo_ip_src_'):] in PATCHERS:
        return PATCHERS[base[len('TxRxCompo_ip_src_'):]]
    return None


EXPECTED_ZIP_MEMBERS = {
    'TxRxCompo_ip_src_Interpolation_Control.v': 'countRegOut',
    'TxRxCompo_ip_src_Symbol_Synchronizer.v': 'dc_countreg',
    'TxRxCompo_ip_src_Preamble_Detector.v': 'dc_toff',
    'TxRxCompo_ip_src_Frequency_and_Time_Synchronizer.v': 'dc_rhpop',
    'TxRxCompo_ip_src_QPSK_Rx.v': 'ddrcap_dc_toff',
    'TxRxCompo_ip_src_Receiver.v': 'ddrcap_dc_toff',
    'TxRxCompo_ip_src_TxRxComposite.v': 'ddrcap2_slot_r',
}


def patch_zip(zpath):
    buf = io.BytesIO(open(zpath, 'rb').read())
    zin = zipfile.ZipFile(buf, 'r'); entries = []; n = 0
    for item in zin.infolist():
        data = zin.read(item.filename)
        fn = _patcher_for(os.path.basename(item.filename))
        if fn is not None:
            tmp = zpath + '.ddrcap2_tmp'; os.makedirs(tmp, exist_ok=True)
            tp = os.path.join(tmp, os.path.basename(item.filename))
            open(tp, 'wb').write(data); status = fn(tp); data = open(tp, 'rb').read()
            os.remove(tp); os.rmdir(tmp); n += 1
            print(f"    zip member {os.path.basename(item.filename):50s} {status:8s}")
        entries.append((item, data))
    zin.close()
    out = io.BytesIO(); zout = zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED)
    for item, data in entries:
        zout.writestr(item, data)
    zout.close(); open(zpath, 'wb').write(out.getvalue())
    return n


def verify_zip(zpath):
    zin = zipfile.ZipFile(zpath, 'r'); found = {}
    for item in zin.infolist():
        b = os.path.basename(item.filename)
        if b in EXPECTED_ZIP_MEMBERS:
            found[b] = zin.read(item.filename).decode()
    zin.close()
    ok = True
    for b, marker in EXPECTED_ZIP_MEMBERS.items():
        if b not in found or marker not in found[b]:
            print(f"    VERIFY_FAIL {zpath}: {b} missing or lacks {marker}"); ok = False
    return ok


def main(d):
    found = set()
    for root, _, files in os.walk(d):
        if root.endswith('.ddrcap2_tmp'):
            continue
        for f in files:
            fn = _patcher_for(f)
            if fn is None:
                continue
            p = os.path.join(root, f)
            print(f"  {f:45s} {fn.__name__:28s} -> {fn(p):8s} {p}")
            found.add(f)
    nz = nv = 0
    for root, _, files in os.walk(d):
        for f in files:
            if f == 'TxRxCompo_ip_v1_0.zip':
                zp = os.path.join(root, f); nz += 1
                print(f"  zip {zp}"); patch_zip(zp)
                if verify_zip(zp):
                    nv += 1; print(f"    VERIFY_OK {zp}")
    logical = {'Interpolation_Control', 'Symbol_Synchronizer', 'Preamble_Detector',
               'Frequency_and_Time_Synchronizer', 'QPSK_Rx', 'Receiver', 'TxRxComposite'}
    got = {f.replace('TxRxCompo_ip_src_', '').replace('.v', '') for f in found}
    missing = sorted(logical - got)
    build_tree = any(os.path.basename(r) in ('ipcore', 'vivado_ip_prj') or any(x.endswith('.xpr') for x in fs)
                     for r, _, fs in os.walk(d))
    print(f"DDRCAP2_INJECT loose={len(found)} missing={missing} zips={nz} zips_verified={nv}")
    if missing or (build_tree and nz == 0) or (nz and nv != nz) or (nz not in (0, 2)):
        print("DDRCAP2_INJECT_FAIL"); return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
