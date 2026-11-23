import pathlib, re
MODEM = pathlib.Path(__file__).resolve().parents[1]
M = MODEM / "dev"   # the overlay-driven kit root; shared files stay at MODEM

def test_assemble_calls_beat_overlays_as_env_gated_phase():
    s = (M / "simulink" / "assemble_jupiter_240k5_byte.m").read_text()
    i = s.index("framestat_overlay(sys, loop);")
    tail = s[i:]
    assert "beatobs_overlay(sys, loop);" in tail and "beatfix_overlay(sys, loop);" in tail
    # gated on the env var, not unconditional
    assert re.search(r"getenv\('QPSK_BEATOBS'\)", s) and re.search(r"getenv\('QPSK_BEATFIX'\)", s)

def test_assemble_patches_hdlworkflow_for_beatfix():
    s = (M / "simulink" / "assemble_jupiter_240k5_byte.m").read_text()
    assert "patch_hdlworkflow_beatfix('hdlworkflow_loopback.m');" in s

def test_run_beatfix_build_no_longer_seds_assemble():
    s = (M / "simulink/beatila/run_beatfix_build.sh").read_text()
    assert "assemble hooked" not in s and "s.replace(a, a+" not in s

def test_build_base_tree_exports_instrument_env():
    s = (MODEM / "build_hdl.sh").read_text()
    for v in ("QPSK_BEATFIX=1", "QPSK_BEATOBS=1", "QPSK_FRAMESTAT=1"):
        assert f"export {v}" in s
    # rate rung: sp4 builds at sps=2 / f3072 (2026-09-18), overridable from the
    # environment for an sps-4 rebuild; frame_config_k5.m defaults to sps=8, so
    # these exports are load-bearing.
    for v in ("QPSK_FRAME=${QPSK_FRAME:-f3072}", "QPSK_SPS=${QPSK_SPS:-2}"):
        assert f"export {v}" in s

def test_build_base_tree_installs_the_bram_rxfifo_dropin():
    """sp3 task 7 precondition.  The shipped ByteRxFifo is the hand-authored
    4096-deep BRAM drop-in (modem/common/rxfifo/ByteRxFifo.v), not HDL Coder's
    64-deep register FIFO -- so a regen that skips modem/common/rxfifo/rxfifo_inject.sh is not
    the shipped netlist (measured: the banked base tree's ByteRxFifo.v is the
    drop-in, and a pre-task-7 regen reported it as a LOGIC diff in
    base_rtl_diff.txt).  The stage runs BEFORE txcap/ddrcap/ddrcap2 (it replaces
    a whole file) and records its failure the same way they do."""
    s = (MODEM / "build_hdl.sh").read_text()
    # depth follows the frame: 4096 at f1536, 8192 at f3072 (cfg.RxFifoDepth)
    assert "rxfifo_inject.sh" in s and '"$FRESH" "$RXFIFO_DEPTH"' in s
    assert 'RXFIFO_DEPTH=4096; [ "$QPSK_FRAME" = f3072 ] && RXFIFO_DEPTH=8192' in s
    assert "BASE_REGEN_INJECT_FAILED stage=rxfifo" in s
    assert "RXFIFO_INJECT_OK" in s
    # ordering: the drop-in lands before the three instrument injectors
    assert s.index("rxfifo_inject.sh") < s.index('"$INSTR/txcap/txcap_inject.py"')
    assert s.index("rxfifo_inject.sh") < s.index('"$INSTR/ddrcap/ddrcap_inject.py"')
    # and the ruling that keeps it a design source rather than an instrument
    assert (MODEM.parent / "docs/evidence/sp3/BYTERXFIFO_DROPIN.md").exists()

def test_rxfifo_stage_requires_actual_replacements_and_runs_after_matlab():
    """Task 7 fix round 1, finding 3.  modem/common/rxfifo/rxfifo_inject.sh prints
    RXFIFO_INJECT_OK even when its finder matched files+zips=0 (nothing
    replaced) -- the hdl stage must not accept the bare token as success, it
    must require at least one file or zip actually replaced, and it must
    print a loud banner for the sub-stage rather than only a comment. Also
    pins ordering: rxfifo runs AFTER the MATLAB build_variant_byte stage (it
    operates on the tree that stage just produced) and BEFORE
    txcap/ddrcap/ddrcap2 (it replaces a whole file and must not land on top
    of their edits). The hdl-regen script was renamed from
    modem/fixes/build_base_tree.sh to modem/build_hdl.sh by sp3 Task 11; this
    test targets the renamed file."""
    s = (MODEM / "build_hdl.sh").read_text()
    assert r"files\+zips=[1-9]" in s, (
        "the RXFIFO_INJECT_OK check must require files+zips=[1-9] (grep -E), "
        "not just the bare token"
    )
    assert "[4a/5] rxfifo" in s, "expected an actual banner echo, not only a comment"
    i_matlab = s.index("build_variant_byte")
    i_rxfifo = s.index("rxfifo_inject.sh")
    i_txcap = s.index('"$INSTR/txcap/txcap_inject.py"')
    assert i_matlab < i_rxfifo < i_txcap

def test_bs_ready_pad_post_check_present():
    """Task 7 fix round 1, finding 4.  Nothing previously checked that HDL
    Coder's delay balancer pads `ready` by exactly 4 registers in the
    generated BsSeamCensus RTL (the round-1 defect -- a hand-built 4-deep
    `readyD4` Delay block that got balanced AGAIN -- was invisible to every
    gate leg; task-7-report.md S4.1/S6). The hdl stage must grep the
    generated RTL for the drop-in's own chain (`reg [3:0] delayMatch_reg`,
    `assign ready_1 = delayMatch_reg[3]`) and print a loud
    BS_READY_PAD_OK / BS_READY_PAD_MISMATCH=<n> token, recorded as a failed
    stage on mismatch like the injectors are."""
    s = (MODEM / "build_hdl.sh").read_text()
    assert "BS_READY_PAD_OK" in s and "BS_READY_PAD_MISMATCH=" in s
    assert "delayMatch_reg" in s and "ready_1" in s
    assert "INJECT_FAILED" in s.split("BS_READY_PAD_MISMATCH=")[1][:400]


def test_beatobs_tap_is_opt_in():
    """2026-09-24: QPSK_BEATOBS=1 builds the observer taps only; the composite debugI1/Q1 (Tap-A)
    keep the receiver-input IQ unless QPSK_BEATOBS_TAP is set (docs/evidence/sp4/TAP_A_BEATOBS.md)."""
    o = (M / "simulink" / "beatila" / "beatobs_overlay.m").read_text()
    i = o.index("if isempty(getenv('QPSK_BEATOBS_TAP'))")
    assert "BoTermI" in o[i:] and "return;" in o[i:i + 600]
    # the terminate-and-return comes BEFORE any composite debugI1/Q1 rewire
    assert i < o.index("for pair = {{'debugI1', pRv1}, {'debugQ1', pRv2}}")
    s = (MODEM / "build_hdl.sh").read_text()
    assert "export QPSK_BEATOBS_TAP" not in s
