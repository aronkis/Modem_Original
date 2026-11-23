"""Static tests for the sp3 RXFIX model overlays (modem/rxfix/).

Sub-project 3 rebuilds each netlist-injected receiver fix (modem/fixes/rxfix_inject.py)
as a Simulink overlay of modem/assemble_jupiter_240k5_byte.m. This file grows one
block per task: W1 (task 4) first, then R4B/R4D/R1/BS in tasks 5-8.

These are TEXT tests: they pin the contract points a reviewer can check without
MATLAB (env gating, idempotency, the register map, phase ordering), not behaviour.
Behaviour is gated by the Verilator legs in modem/gates/build_sro_w1.legs.
"""
import pathlib

MODEM = pathlib.Path(__file__).resolve().parents[1]
M = MODEM / "dev"   # the overlay-driven kit root; shared files stay at MODEM


def src(p):
    # kit stage folders first (simulink/ holds the overlays, beatila/ and rxfix/), then
    # the kit root, then modem/ (shared: build_hdl.sh, fixes/, ...)
    for base in (M / "simulink", M, MODEM):
        q = base / p
        if q.exists():
            return q.read_text()
    raise FileNotFoundError(p)


def test_w1_overlay_is_env_gated_and_idempotent():
    s = src("rxfix/rxfix_w1_overlay.m")
    assert "getenv('QPSK_RXFIX')" in s and "return" in s.split("getenv('QPSK_RXFIX')")[1][:200]
    assert "RxW1Census" in s and "find_system" in s          # idempotency probe by block name


def test_w1_addresses_match_regmap():
    s = src("rxfix/patch_hdlworkflow_rxfix.m")
    for a in ("214", "218", "21C", "220", "224", "228", "22C", "230"):
        assert f'x"{a}"' in s


def test_assemble_calls_rxfix_phase_after_beatfix():
    s = src("assemble_jupiter_240k5_byte.m")
    assert s.index("beatfix_overlay(sys, loop);") < s.index("rxfix_w1_overlay(sys, loop);")
    assert "getenv('QPSK_RXFIX')" in s


def test_fixctldec_extension_is_rxfix_gated():
    """G0: a build with QPSK_RXFIX unset must stay byte-identical HDL, so the two
    extra FixCtlDec outputs (and their Terminators) may only be emitted when the
    variable is set -- beatfix_overlay.m runs at phase 2.20, before the RXFIX
    overlays, so it has to read the variable itself."""
    s = src("beatila/beatfix_overlay.m")
    assert "rxfixOn = ~isempty(getenv('QPSK_RXFIX'));" in s
    # both the decode lines and the Terminators sit behind the guard
    for frag in ("w1Freeze", "sroSign", "FixCtlDecW1FreezeTerm", "FixCtlDecSroSignTerm"):
        assert frag in s.split("rxfixOn = ~isempty(getenv('QPSK_RXFIX'));")[1]
    head = s.split("rxfixOn = ~isempty(getenv('QPSK_RXFIX'));")[0]
    assert "w1Freeze    = bitand" not in head and "FixCtlDecSroSignTerm'" not in head
    # the bit positions are the contract (W1_REGMAP.md): bit 4 freeze, bit 5 SRO sign
    assert "w1Freeze    = bitand(uint32(ctl), uint32(16))" in s
    assert "sroSign     = bitand(uint32(ctl), uint32(32))" in s
    # and the overlay's anchor assert names the requirement rather than just failing
    o = src("rxfix/rxfix_w1_overlay.m")
    assert "QPSK_RXFIX must be set" in o


def test_build_base_tree_exports_rxfix():
    """The sp3 regen path must set QPSK_RXFIX for the whole assemble, else the
    FixCtlDec extension above is absent and rxfix_w1_overlay.m cannot anchor."""
    assert "export QPSK_RXFIX=1" in src("build_hdl.sh")


# --- task 5: the Rate Handle steering overlay (R4B/R4D as one runtime-selected
# --- netlist), fixctl bit 5 = sro_sign ---------------------------------------


def test_steer_overlay_is_env_gated_and_idempotent():
    s = src("rxfix/rxfix_steer_overlay.m")
    assert "getenv('QPSK_RXFIX')" in s and "return" in s.split("getenv('QPSK_RXFIX')")[1][:200]
    # idempotency probe by block name; RxSteer is also the name tree_marker.sh
    # checks for on a model tree (modem/rtl_sim/tree_marker.sh: R4B/R4D -> RxSteer.v)
    assert "RxSteer" in s and "find_system" in s


def test_steer_addresses_match_regmap():
    s = src("rxfix/patch_hdlworkflow_rxfix.m")
    for a in ("234", "238", "25C"):
        assert f'x"{a}"' in s
    for port in ("r4_wit", "r4_extras", "sro_mode"):
        assert port in s


def test_assemble_calls_steer_after_w1():
    s = src("assemble_jupiter_240k5_byte.m")
    assert s.index("rxfix_w1_overlay(sys, loop);") < s.index("rxfix_steer_overlay(sys, loop);")


def test_steer_extra_branch_is_gated_on_sro_sign():
    """The FULL-edge (extra pop) branch is PRESENT in every build and armed only
    by fixctl bit 5 -- that is the whole point of task 5. `doExtra` must carry
    sroSign; at sroSign=0 the netlist must reduce to R4B exactly."""
    s = src("rxfix/rxfix_steer_overlay.m")
    line = s.split("doExtra = ")[1].split("\\n")[0]
    assert "sroSign" in line, line


def test_steer_decision_is_registered_not_combinational():
    """rxfix_inject.py registers the skip/extra DECISION (r4b_skip_en) so the only
    combinational path into the pop is the baseline's own guard. The overlay must
    assign skipEn from the window state, never from popNom in the same expression."""
    s = src("rxfix/rxfix_steer_overlay.m")
    dec = [ln for ln in s.splitlines() if "nSkipArm = locked" in ln]
    assert dec, "no registered skipEn decision line"
    assert "popNom" not in dec[0]
    # the injector's slot guard and once-per-window latch, both missing from the
    # plan's transcription (see the task-5 report's transcription-diff section)
    assert "wslot <= uint8(12)" in s and "~skipDone" in s


# --- task 6: R1 -- the Preamble Detector realignment FIFO's pop indexed by
# --- occupancy instead of by enb ticks (unconditional, no fixctl bit) ---------


def test_r1_overlay_is_env_gated_and_idempotent():
    s = src("rxfix/rxfix_r1_overlay.m")
    assert "getenv('QPSK_RXFIX')" in s and "return" in s.split("getenv('QPSK_RXFIX')")[1][:200]
    # idempotency probe by block name; PdPopIndex is also the module name
    # tree_marker.sh requires on a model tree (R4DR1 -> PdPopIndex.v)
    assert "PdPopIndex" in s and "find_system" in s


def test_r1_pops_on_the_full_occupancy_code():
    """rxfix_inject.py's R1 section is the truth:
        Delay10_full = FIFO_numEntries == 14'd12333;
        Delay10_out1 = Delay8_out1 & Delay10_full;
    12333 is the FIFO depth (searchSamples) at f1536; the 49,332-tick delay it
    replaces is 4x that. Since the sp4 rung (f3072: 24634 slots) the constant
    comes from frame_config_k5().SlotsPerFrame and is spliced into the MLFB
    script by sprintf -- no geometry literal may remain in a code line."""
    s = src("rxfix/rxfix_r1_overlay.m")
    code = "\n".join(ln for ln in s.splitlines() if not ln.lstrip().startswith("%"))
    assert "cfg = frame_config_k5();" in code and "SLOTS = cfg.SlotsPerFrame;" in code
    assert "12333" in s and "49332" in s          # documented in the header (the f1536 truth)
    for lit in ("uint16(12333)", "~= 49332", "== 12333"):
        assert lit not in code, f"geometry literal {lit!r} survives in a code line"
    body = s.split("ch.Script")[1]
    assert "numEntries == uint16(%d)" in body and "SLOTS, SLOTS, SLOTS, SLOTS" in body, \
        "the full compare must take SlotsPerFrame from the contract"


def test_r1_is_unconditional_no_fixctl_bit():
    """R1 has no runtime arming bit (unlike task 5's sroSign): the EMPTY-edge
    role carries it too. A fixctl tap in this overlay would be a fifth variant."""
    s = src("rxfix/rxfix_r1_overlay.m")
    code = "\n".join(ln for ln in s.splitlines() if not ln.lstrip().startswith("%"))
    assert "FixCtlDec" not in code and "sroSign" not in code


def test_assemble_calls_r1_after_steer():
    s = src("assemble_jupiter_240k5_byte.m")
    assert s.index("rxfix_steer_overlay(sys, loop);") < s.index("rxfix_r1_overlay(sys, loop);")


def test_r1_rewires_every_consumer_of_the_retired_delay():
    """Delay10_out1 drives TWO loads in the generated RTL: the FIFO's pop AND
    Delay14 (Timing_Adjust.validIn). The injector redefines the net, so both see
    the new pop; deleting the Delay block in the model must reconnect both or
    Timing_Adjust loses its valid."""
    s = src("rxfix/rxfix_r1_overlay.m")
    assert "DstPortHandle" in s, "the overlay does not re-drive the retired Delay's loads"
    assert "delete_block" in s


def test_model_wrappers_retap_the_pd_pop_request():
    """`pdPopReq` taps Preamble_Detector.Delay10_out1, which no longer exists on a
    model tree carrying R1. make_sro_trees.sh must re-point it, and assert it did
    (verilator runs -Wno-fatal, so a missed tap would not fail the build)."""
    s = src("rtl_sim/make_sro_trees.sh")
    # measured net name on the regenerated tree: HDL Coder names an MLFB output
    # net after the script variable, so it is `pop` (`.pop(pop)`), not
    # `PdPopIndex_out1`; the tap goes through the instance to stay anchorable.
    assert "u_PdPopIndex.pop" in s
    assert "MAKE_SRO_MODEL_WRAP_PDTAP" in s


# --- task 8: TX F1+F2+F3 -- the 120.2 s transmit stall fix, formerly the netlist
# --- injector modem/fixes/txfix_inject.py variant F3 (no ports, no registers) ---


def test_txf3_overlay_is_env_gated_and_idempotent():
    s = src("rxfix/txfix_f3_overlay.m")
    assert "getenv('QPSK_RXFIX')" in s and "return" in s.split("getenv('QPSK_RXFIX')")[1][:200]
    # sp3 task 8 fix round 2: a SECOND gate, QPSK_TXFIX, so that a model-lineage
    # UNFIXED baseline (same receiver, stock transmitter) can be built for the
    # gate's four RX-capture rows. BOTH must be set for any edit to happen.
    assert "getenv('QPSK_TXFIX')" in s and "return" in s.split("getenv('QPSK_TXFIX')")[1][:200]
    # idempotency is probed on ALL FOUR edits (two blocks + two chart markers);
    # a half-applied overlay must be an error, not a silent "already applied"
    assert "TxF1BoundaryGuard" in s and "TxF3ReadyGate" in s
    assert "TXFIX_F2" in s and "TXFIX_F3" in s
    assert "HALF-APPLIED" in s


def test_txf3_f1_gates_the_latch_reset_with_the_frame_boundary():
    """txfix_inject.py:patch_data_bits_fifo moves the pop-enable latch's clear
    INSIDE the Compare_To_Constant3 (sampleCount==0) branch. In the model the
    same thing is ANDing the latch's RESET input with that enable compare -- so
    the overlay must add an AND and re-drive input 3 of the Unit Delay Enabled
    Resettable Synchronous block."""
    s = src("rxfix/txfix_f3_overlay.m")
    assert "Unit Delay Enabled Resettable Synchronous" in s
    assert "delete_line" in s and "ih(uders, 3)" in s
    # the injector's two polarity asserts, kept as structural anchors
    assert "assert_cmp(bRst,  '==', '0'" in s
    assert "assert_cmp(bData, '~=', '0'" in s
    assert "assert_cmp(bEn,   '==', '0'" in s


def test_txf3_f2_and_f3_counters_are_script_edits_not_new_blocks():
    """`RAM Frame Status Indicator` and `MATLAB Function1` are ALREADY MATLAB
    Function blocks. Replacing either with a new block (the brief's
    `FrameCountSat`) renames the module and the instance, and both TX gate
    harnesses read AND FORCE `FSI frameCount` / `u_MATLAB_Function1.count` by
    hierarchical path. Those are C++ member paths, so the failure is LOUD -- the
    harness stops compiling and G9/G10/G11/G12 become unrunnable until the paths
    are re-derived -- but it costs a rebuild of the gate chain for no gain."""
    s = src("rxfix/txfix_f3_overlay.m")
    code = "\n".join(ln for ln in s.splitlines() if not ln.lstrip().startswith("%"))
    assert "FrameCountSat" not in code          # named only in the header's rationale
    assert "chart(fsi)" in s and "chart(mf1)" in s
    assert "persistent pushCount popCount frameCount;" in s   # tap-name anchor
    assert "persistent count;" in s


def test_txf3_saturation_guards_match_the_injector():
    """FSI_BODY_NEW / MF1_BODY_NEW: fcInc & ~fcDec & (frameCount != 3) and
    cntInc & ~cntDec & (count != 65535); simultaneous inc+dec stays a no-op."""
    s = src("rxfix/txfix_f3_overlay.m")
    assert "fcInc && ~fcDec && (frameCount ~= 3)" in s
    assert "fcDec && ~fcInc && (frameCount ~= 0)" in s
    # the saturation literal is the full range of count's ufix type, derived from
    # the same depth expression (65535 at f1536, 131071 at f3072)
    assert "cntInc && ~cntDec && (count ~= %d)" in s and "SATMAX = 2^SATW - 1" in s
    assert "cntDec && ~cntInc && (count ~= 0)" in s


def test_txf3_dataready_is_gated_by_not_fullram():
    """patch_bit_packetizer: dataReady = DataReadyPaceCmp_out1 &
    Logical_Operator2_out1 (= ~Data_Bits_FIFO_fullRAM). The overlay must tap the
    existing NOT block and assert it really is the fullRAM inverter."""
    s = src("rxfix/txfix_f3_overlay.m")
    assert "DataReadyPaceCmp" in s
    assert "'fullRAM'" in s          # the tapped Data Bits FIFO outport is asserted by name
    assert "'NOT'" in s


def test_txf3b_margin_is_not_applied():
    """The shipped variant is F3, not F3b: the fullRAM threshold stays 49279.

    F3b's only other change is the threshold, and in the CHART that is the
    `full = (count > depth);` line -- an F3b variant compares against `depth - 16`.
    An earlier revision guarded with `contains(s, '1100000001101111')`, the
    injector's Verilog binary literal, which can never appear in a MATLAB script:
    dead code that read as a refusal. So this test asserts the BEHAVIOUR -- the
    stock threshold expression is required, and no F3b threshold form is written.
    """
    s = src("rxfix/txfix_f3_overlay.m")
    code = "\n".join(ln for ln in s.splitlines() if not ln.lstrip().startswith("%"))
    assert "full = (count > depth);" in code        # the stock threshold is asserted
    assert "1100000001101111" not in code           # the dead Verilog-literal guard is gone
    # and no F3b threshold form is WRITTEN into the chart: scan the replacement text
    # this overlay substitutes into MATLAB Function1, not the refusal message (which
    # names 49263/depth-16 on purpose).
    # (the sprintf now takes the saturation width/limit as arguments, so the format
    #  block ends at the argument list, not at `]);`)
    written = s.split("F3_NEW = sprintf([")[1].split("], SATMAX")[0]
    for f3b in ("49263", "depth - 16", "depth-16", "> depth"):
        assert f3b not in written, f3b


def test_txf3_idempotency_tests_the_F3B_marker_before_its_own_prefix():
    """`TXFIX_F3` is a PREFIX of `TXFIX_F3B`, the hazard
    txfix_inject.py:patch_matlab_function1's docstring is written about. The F3b
    marker must be tested first, or an F3b chart reads as "already applied" F3."""
    s = src("rxfix/txfix_f3_overlay.m")
    code = "\n".join(ln for ln in s.splitlines() if not ln.lstrip().startswith("%"))
    assert code.index("'TXFIX_F3B'") < code.index("'TXFIX_F3'")
    assert "error(" in code[code.index("'TXFIX_F3B'"):code.index("'TXFIX_F3'")]


def test_txf3_adds_no_ports_so_no_keep_last():
    """This overlay surfaces nothing, so it must NOT carry the keep_last dance
    the RX overlays need (and a BASE_REGEN_INJECT_FAILED is never its fault)."""
    s = src("rxfix/txfix_f3_overlay.m")
    code = "\n".join(ln for ln in s.splitlines() if not ln.lstrip().startswith("%"))
    assert "keep_last" not in code
    assert "built-in/Outport" not in code and "built-in/Inport" not in code


def test_assemble_calls_txf3_last_in_the_rxfix_phase():
    s = src("assemble_jupiter_240k5_byte.m")
    assert s.index("rxfix_r1_overlay(sys, loop);") < s.index("txfix_f3_overlay(sys, loop);")


def test_txf3_newline_block_names_are_matched_by_regexp():
    """`Compare\\nTo Constant3`, `Logical\\nOperator2` and `Unit Delay Enabled
    Resettable\\nSynchronous` carry NEWLINES in their block names -- an exact-Name
    find_system cannot express them and would report a missing anchor."""
    s = src("rxfix/txfix_f3_overlay.m")
    assert "'regexp','on'" in s
    assert "function b = one(ss, pat)" in s


def test_txfix_gate_inputs_the_2026_09_cleanup_dropped_are_present():
    """Two inputs the TX gate needs were left dangling by the 2026-09 repo
    cleanup and each silently DEGRADES the score rather than failing it:

    * `txfix_gate_score.py` builds its (gid, prefix) -> wrapper-log map from
      `modem/rtl_sim/txfix_gate_runs.txt`; with the manifest only under
      `evidence/`, every row scores "incomplete -- no TXFIX_GATE_RUN_EXIT
      trailer yet" even when the trailer is right there.
    * `kick_seq.py` loads `ops/offsetmap/tap3_word_to_offset.tsv`; without it
      every per-frame offset list is EMPTY, so G3/G4/G7's `all_offsets_zero`
      passes vacuously.
    """
    # The manifest's TRACKED home is rtl_sim/evidence/ (`modem/rtl_sim/*.txt` is
    # gitignored; `!modem/rtl_sim/evidence/**` un-ignores it there), so the scorer
    # falls back to it rather than depending on an untracked copy beside itself.
    tracked = MODEM / "rtl_sim" / "evidence" / "txfix_gate_runs.txt"
    assert tracked.exists() and len(tracked.read_text().splitlines()) > 20
    score = (MODEM / "rtl_sim" / "txfix_gate_score.py").read_text()
    assert "os.path.join(HERE, 'evidence', 'txfix_gate_runs.txt')" in score
    m = MODEM.parent / "ops" / "offsetmap" / "tap3_word_to_offset.tsv"
    assert m.exists() and len(m.read_text().splitlines()) > 12000


# ---------------------------------------------------------------- BS + PAD (task 7)

def test_bs_overlay_is_env_gated_and_idempotent():
    s = src("rxfix/rxfix_bs_overlay.m")
    assert "getenv('QPSK_RXFIX')" in s and "return" in s.split("getenv('QPSK_RXFIX')")[1][:200]
    # idempotency probe by the block name tree_marker.sh looks for on a model tree
    assert "BsSeamCensus" in s and "find_system" in s


def test_pad_overlay_is_env_gated_and_idempotent_on_padcount():
    s = src("rxfix/rxfix_pad_overlay.m")
    assert "getenv('QPSK_RXFIX')" in s and "return" in s.split("getenv('QPSK_RXFIX')")[1][:200]
    # the chart-script edit's idempotency check is the literal the brief names
    assert "'padCount'" in s and "contains(" in s


def test_bs_addresses_and_port_names_match_fixes_toml():
    """fixes.toml [fixes.BS] is the register layout of record: eight read words
    0x23C..0x258 in this exact order."""
    s = src("rxfix/patch_hdlworkflow_rxfix.m")
    want = [("bs_words", "23C"), ("bs_starts", "240"), ("bs_push", "244"),
            ("bs_pop", "248"), ("bs_drop", "24C"), ("bs_marks", "250"),
            ("bs_evt", "254"), ("bs_cnt", "258")]
    for nm, a in want:
        assert f"'{nm}','{a}'" in s.replace(" ", "") or f'"{nm}","{a}"' in s.replace(" ", "")
        assert f'x"{a}"' in s
    t = (MODEM / "fixes/fixes.toml").read_text()
    for nm, a in want:
        assert f'addr = 0x{a}, name = "{nm}"' in t.replace("{ ", "").replace("  ", " ") or \
               (f'0x{a}' in t and f'"{nm}"' in t)


def test_bs_derives_the_seam_events_from_PORTS_not_from_injected_taps():
    """The shipped ByteRxFifo is the BRAM drop-in, which the model does not
    generate (docs/evidence/sp3/BYTERXFIFO_DROPIN.md): a model overlay sees its
    PORTS only, so bsPush/bsPop/bsDrop -- the injector's internal taps -- must not
    appear as signals here, and `ovf` must not be treated as a drop event."""
    s = src("rxfix/rxfix_bs_overlay.m")
    code = "\n".join(ln for ln in s.splitlines() if not ln.lstrip().startswith("%"))
    for tap in ("bsPush", "bsPop", "bsDrop", "bsEnbG"):
        assert tap not in code
    # the three derivations, by their defining constants
    # the occupancy shadow's DEPTH and DEPTH-1 come from the contract (4096 / 8192)
    assert "FD = cfg.RxFifoDepth" in code and "FDM = FD - 1" in code
    assert "uint16(%d) - pN, uint16(%d)) == uint16(%d)" in code   # drop = push && (occ - pop == DEPTH-1)
    # `ready` is fed in RAW: HDL Coder's delay balancing supplies the drop-in's
    # ready_1 (it pads the GENERATED ByteRxFifo's own `ready` input by exactly the
    # same 4).  A design `Delay` block here is the MEASURED bug -- it is not
    # counted as latency, so the input got padded by four MORE and bs_pop became
    # valid(k) && ready(k-8).  rxfix_bs_overlay.m header note (3).
    assert "BsRdyD4" not in code and "DelayLength" not in code
    assert "delay balancing" in s.lower()
    # and the finding is recorded where the evidence lives
    d = (MODEM.parent / "docs/evidence/sp3/BYTERXFIFO_DROPIN.md").read_text()
    assert "ovf` is NOT a drop pulse" in d or "ovf` is NOT a drop" in d


def test_bs_chart_markers_avoid_the_tree_marker_tokens():
    """HDL Coder copies MATLAB comments into the generated ByteSerializer.v, and
    modem/rtl_sim/tree_marker.sh decides "injected tree" by grepping THAT FILE for
    RXFIX_BS / RXFIX_PAD.  Measured on the first regen: a MODEL tree reported as
    `BS injector` / `PAD injector`, i.e. a comment satisfied the provenance check.
    So the comments these overlays write into the ByteSerializer CHART carry no
    such token (the census MLFBs' own comments still do -- they land in
    BsSerCensus.v / BsSeamCensus.v, which tree_marker.sh does not grep)."""
    b = src("rxfix/rxfix_bs_overlay.m")
    assert "'% BS byte-seam taps on the EMITTED word" in b
    assert "% BS census: words this step" in b
    d = src("rxfix/rxfix_pad_overlay.m")
    assert "aBs  = '% BS byte-seam taps on the EMITTED word';" in d
    # the arbiter block is one bracketed string concatenation; none of it may
    # carry the PAD token
    arb = d[d.index("arb = ["):d.index("sc = strrep(sc, aBs")]
    assert "RXFIX_PAD" not in arb and "'% PAD (F4) -- frame-length padding" in arb
    # and both overlays say WHY, so the next editor does not put the token back
    assert "tree_marker.sh" in b and "tree_marker.sh" in d


def test_bs_census_is_split_across_the_two_clock_ENABLES():
    """rxfix_inject.py's bs_seam_census gates the serializer counters on enbSer
    (15.36 MHz) and the FIFO counters on enbFifo (30.72 MHz) inside ONE always
    block.  A Simulink block has one rate, and a base-rate block reading the
    half-rate serializer would count every word TWICE, so the census is two
    blocks: BsSerCensus at the serializer rate, BsSeamCensus at the base rate."""
    s = src("rxfix/rxfix_bs_overlay.m")
    assert "BsSerCensus" in s and "BsSeamCensus" in s
    # the five slow->fast crossings are explicit Rate Transition blocks
    assert "built-in/RateTransition" in s
    assert "1/30.72e6" in s


def test_bs_packs_the_eight_words_exactly_as_the_injector():
    s = src("rxfix/rxfix_bs_overlay.m")
    code = "\n".join(ln for ln in s.splitlines() if not ln.lstrip().startswith("%"))
    # w6 = {tLast, tMin, tMax, dropMax}; w7 = {trunc[31:16], q24[15:8], 8'b0}
    # tMin resets to WPP (191 at f1536, 382 at f3072) so the first event sets it;
    # the widths follow WPP (8-bit fields below 256, 9-bit above) and q24 SATURATES
    # at the low field's range -- everything is spliced from frame_config_k5.
    assert "WPP = cfg.WordsPerPacketRx" in code and "tMin = uint16(%d)" in code
    assert "q24 ~= uint16(%d)" in code and "LOWMAX = 2^LOWB - 1" in code
    assert "uint8(191)" not in code and "uint8(255)" not in code
    # the q24 ladder: every multiple of 24 that WPP-wcnt can be, generated
    assert "lad = 24:24:WPP-1;" in code and "(dfc == uint16(%d))" in code
    # the FIFO depth in the seam census is the drop-in's (4096 / 8192), not a literal
    assert "FD = cfg.RxFifoDepth" in code and "uint16(4096)" not in code and "uint16(4095)" not in code


def test_pad_is_the_injector_state_machine():
    s = src("rxfix/rxfix_pad_overlay.m")
    code = "\n".join(ln for ln in s.splitlines() if not ln.lstrip().startswith("%"))
    # pad = WPP - wordCnt, armed on 1..WPP-1; WPP from the contract (191 / 382),
    # so the counter is uint16 and no 191/190 literal survives in a code line
    assert "WPP = cfg.WordsPerPacketRx" in code and "uint16(' WPPs ')" in code and "uint16(' WPPm1 ')" in code
    assert "uint8(191)" not in code and "uint16(190)" not in code and "padCount = uint16(0)" in code
    for q in ("pq0", "pq1", "pq2", "pl0", "pl1", "pl2", "pqn"):
        assert q in code                          # the 3-deep real-word queue
    assert "padCount" in code


def test_assemble_calls_bs_then_pad_after_r1():
    s = src("assemble_jupiter_240k5_byte.m")
    assert s.index("rxfix_r1_overlay(sys, loop);") < s.index("rxfix_bs_overlay(sys, loop);")
    assert s.index("rxfix_bs_overlay(sys, loop);") < s.index("rxfix_pad_overlay(sys, loop);")


def test_make_sro_trees_repoints_the_bs_census_tap():
    """wrap_byte_bs.v:340 reads dut.u_bs_seam_census.bus, an injected-only net.
    On a model tree the eight words are the BsSeamCensus MLFB's own outputs."""
    s = (MODEM / "rtl_sim/make_sro_trees.sh").read_text()
    assert "u_bs_seam_census" in s and "u_BsSeamCensus" in s
    assert "MAKE_SRO_MODEL_WRAP_BSTAPS" in s


# --- sp3 task 8 fix round 2: the model-lineage unfixed TX baseline ---


def test_txf3_second_gate_is_an_independent_early_return():
    """QPSK_TXFIX must be its own early return, not an `||`/`&&` folded into the
    QPSK_RXFIX line: the baseline build sets QPSK_RXFIX=1 (every RX overlay ON)
    and leaves QPSK_TXFIX EMPTY, and only a separate `isempty(getenv(...))`
    return expresses that combination."""
    s = src("rxfix/txfix_f3_overlay.m")
    rx = "if isempty(getenv('QPSK_RXFIX')), return; end"
    tx = "if isempty(getenv('QPSK_TXFIX')), return; end"
    assert rx in s and tx in s
    # adjacent, RXFIX first, and the TX gate is BEFORE the first edit: the overlay
    # must not have touched the model before deciding to bail out.
    assert s.index(rx) < s.index(tx)
    assert s.index(tx) < s.index("add_block")


def test_build_base_tree_exports_txfix_and_honours_an_empty_override():
    """modem/fixes/build_base_tree.sh must export QPSK_TXFIX beside QPSK_RXFIX so
    the normal regen is unchanged, and must use the `${VAR-default}` form -- NOT
    `${VAR:-default}` and not a bare assignment -- so that

        QPSK_TXFIX= modem/fixes/build_base_tree.sh <dest_parent>

    (set, but empty) reaches the MATLAB stage empty and produces the unfixed
    baseline. `:-` would substitute the default for the empty string and silently
    rebuild the FIXED tree, which is the failure this test exists to catch."""
    s = src("build_hdl.sh")
    assert 'export QPSK_TXFIX="${QPSK_TXFIX-1}"' in s
    assert 'export QPSK_TXFIX="${QPSK_TXFIX:-1}"' not in s
    assert "export QPSK_TXFIX=1\n" not in s
    # both gates travel together -- a regen that set only one would be a tree no
    # gate row is written for
    assert "export QPSK_RXFIX=1" in s
    assert s.index("export QPSK_RXFIX=1") < s.index('export QPSK_TXFIX="${QPSK_TXFIX-1}"')
