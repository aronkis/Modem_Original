"""test_oneway_images.py -- ONE-DIRECTIONAL test images (TX-only / RX-only), desk-side
text tests, no MATLAB/Vivado/board contact.

  1. oneway_overlay.m is an env-gated no-op: without QPSK_ONEWAY it returns before
     touching the model (the G0 idiom every overlay follows).
  2. assemble calls it LAST (after the rxfix block) and guards the half-specific
     pre-synth gates on the mode.
  3. build_hdl.sh forwards QPSK_ONEWAY, skips the three netlist injectors, drops the
     ddrcap BD step + its token, and conditions the MODEL_OVERLAYS check.
  4. build_image.sh --oneway: gates stage is SKIPPED-ONEWAY behind the pair-sim stamp.
  5. deploy_image.sh accepts TXO/RXO roles.
"""
import pathlib, re, subprocess

MODEM = pathlib.Path(__file__).resolve().parents[1]
ROOT = MODEM.parent
M = MODEM / "dev"


def test_overlay_is_env_gated_noop():
    s = (M / "simulink" / "oneway_overlay.m").read_text()
    head = s[: s.index("victim")]
    assert "getenv('QPSK_ONEWAY')" in head and "if isempty(mode), return; end" in head
    assert "ONEWAY_STUB" in s and "ONEWAY_OVERLAY_OK" in s
    # both halves are stubbable, nothing else
    assert "case 'tx', victim = 'Receiver';" in s and "case 'rx', victim = 'Transmitter';" in s


def test_assemble_calls_overlay_last_and_guards_gates():
    s = (M / "simulink" / "assemble_jupiter_240k5_byte.m").read_text()
    i = s.index("oneway_overlay(sys, loop);")
    # after every overlay that edits Transmitter/Receiver internals
    for earlier in ("framestat_overlay(sys, loop);", "beatfix_overlay(sys, loop);", "rxfix"):
        assert s.index(earlier) < i, earlier
    assert "ONEWAY_TX" in s and "ONEWAY_RX" in s
    assert "if ~ONEWAY_RX" in s and "if ~ONEWAY_TX" in s
    assert "oneway=%s" in s   # Description token


def test_build_hdl_oneway_switches():
    s = (MODEM / "build_hdl.sh").read_text()
    assert 'ONEWAY=${QPSK_ONEWAY:-}' in s and 'export QPSK_ONEWAY="$ONEWAY"' in s
    assert "INJECT_SKIPPED_ONEWAY txcap ddrcap ddrcap2" in s
    assert "DDRCAP_BD_SKIPPED reason=QPSK_ONEWAY" in s
    assert '$DDRCAP_TOK $SEQBIST_TOK COMPLETE_BD_RUN_DONE' in s
    assert '$DDRCAP_SRC_LINE\nvalidate_bd_design' in s
    assert 'if [ "$ONEWAY" != tx ]; then' in s and '[ "$ONEWAY" != rx ]' in s
    assert 'echo "ONEWAY=$ONEWAY"' in s   # TXFIX_VARIANT


def test_build_hdl_ddrcap_block_executes():
    """Run the extracted DDRCAP decision block at both settings."""
    s = (MODEM / "build_hdl.sh").read_text()
    m = re.search(r'  DDRCAP_SRC_LINE="source.*?\n  fi\n', s, re.S)
    assert m, "ddrcap decision block not found"
    blk = m.group(0)
    for oneway, tok in (("", "DDRCAP_BD_WIRE_OK"), ("tx", ""), ("rx", "")):
        r = subprocess.run(["bash", "-c", f'set -u; INSTR=/i; ONEWAY="{oneway}"\n{blk}\necho "TOK=[$DDRCAP_TOK]"; echo "SRC=[$DDRCAP_SRC_LINE]"'],
                           text=True, capture_output=True)
        assert r.returncode == 0, r.stderr
        assert f"TOK=[{tok}]" in r.stdout, r.stdout
        if oneway:
            assert "DDRCAP_BD_SKIPPED" in r.stdout and "SRC=[#" in r.stdout
        else:
            assert "SRC=[source /i/ddrcap/ddrcap_bd.tcl]" in r.stdout


def test_build_image_oneway_option():
    s = (MODEM / "build_image.sh").read_text()
    assert "--oneway)" in s and 'QPSK_ONEWAY="$ONEWAY" "$HERE/build_hdl.sh"' in s
    assert "BUILD_IMAGE_GATES_SKIPPED_ONEWAY" in s and 'stamp gates "SKIPPED-ONEWAY' in s
    assert "SIM_ONEWAY_PAIR_GATE.txt" in s and "^result: PASS" in s
    r = subprocess.run(["bash", str(MODEM / "build_image.sh"), "--tag", "x", "--oneway", "sideways"],
                       text=True, capture_output=True)
    assert r.returncode == 2 and "--oneway takes tx|rx" in r.stdout


def test_deploy_image_roles():
    s = (ROOT / "ops/deploy_image.sh").read_text()
    assert "A|B|TXO|RXO)" in s
    assert "oneway_bringup.sh" in s


def test_checkhdl_gate_conditioned_per_half():
    s = (M / "hdlsim" / "checkhdl_gate_240k5_byte.m").read_text()
    assert "ONEWAY = lower(getenv('QPSK_ONEWAY'));" in s
    assert "if ~strcmp(ONEWAY,'tx')" in s and "if ~strcmp(ONEWAY,'rx')" in s
