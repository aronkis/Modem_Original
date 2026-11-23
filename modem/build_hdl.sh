#!/bin/bash
# build_hdl.sh <dest_parent> [--kit-name NAME] [--complete-bd] [--diff-bank DIR]
#   -- the `hdl` stage: regenerate the Vivado tree from the Simulink model.
#
# (was modem/fixes/build_base_tree.sh; git mv'd here by sp3 Task 11, with a
# compatibility symlink left at the old path -- Task 15, which would have
# deleted it, is cancelled.  Invoked with ONLY a dest_parent it keeps
# build_base_tree.sh's SHAPE -- same tree name, same ddrcap_bd WARN, and the
# BASE_RTL_EQUIV diff against the bank still runs.
#
# It does NOT produce build_base_tree.sh's OUTPUT any more, and the legacy
# invocation is not a way to get it back.  Since sp3 Tasks 4 and 8 this script
# exports QPSK_RXFIX=1 (UNCONDITIONALLY -- a caller cannot turn it off) and
# QPSK_TXFIX="${QPSK_TXFIX-1}" (the `-` form, so an EMPTY value from the caller
# does survive) -- see the export block below.  The RX and TX model overlays in
# modem/dev/simulink/rxfix/ are therefore ON BY DEFAULT on every path, dest_parent-only
# included.  The banked base tree carries none of them, so the BASE_RTL_EQUIV
# diff against it is EXPECTED TO BE LARGE: that is the overlays, not a
# regression, and a small diff would be the surprising result.  The only
# overlay a caller can drop is the TX one:
#     QPSK_TXFIX= modem/build_hdl.sh <dest_parent>
# which is the baseline the TX gate matrix is built from, and half of
# modem/dev/simulink/rxfix/README.md's discriminating rebuild.)
#
# --kit-name NAME    name the regenerated tree NAME instead of
#                    jupiter_byte_ddrcap2_build.regen.  The sp3 single image
#                    passes jupiter_byte_sp3_build, because modem/vivado/
#                    txfix_build.sh.tmpl derives both the remote build dir and
#                    the systemd unit name from the kit BASENAME.
# --complete-bd      finish the block design locally and assemble the tree AS a
#                    build kit (steps [5] and [6] below).  See the ruling.
# --diff-bank DIR    run step [7], the RTL diff against the banked base tree in
#                    DIR, and print BASE_RTL_EQUIV.  DEFAULT: on (at
#                    $BASE_TREE_BANK) for a legacy invocation, OFF once
#                    --kit-name or --complete-bd is given -- the diff is
#                    EVIDENCE about the regen recipe, and the sp3 pipeline does
#                    not consult the bank at all.
#
# THE RULING THIS SCRIPT NOW IMPLEMENTS (sp3 Task 11, controller 2026-09-12).
# HDL Coder's Create Project task fails on this kit, so the regenerated
# vivado_prj has the byte reference design but NO TxRxCompo_ip_0 cell in
# system.bd -- the modem DUT is not in the block design.  That is why
# modem/instruments/ddrcap/ddrcap_bd.tcl aborted on EVERY regen ("TxRxCompo_ip_0
# missing pins") and was tolerated as a WARN: the cell did not exist.  The BD
# completion has never been part of the regen recipe; it lived only in
# modem/complete_byte_t8.tcl, which build_byte_image.sh step 4 runs for every
# byte image ever built.  --complete-bd runs the BD half of that file
# (modem/complete_byte_bd.tcl, lines 1-137 verbatim) here, then the two BD
# instruments, in ONE Vivado session:
#   [5a] complete_byte_bd.tcl        -> BYTE_WIRE_OK, WIRE_OK, VALIDATE_OK,
#                                       DDS_DIET_OK, COMPLETE_BYTE_BD_DONE
#   [5b] instruments/ddrcap/ddrcap_bd.tcl -> DDRCAP_BD_WIRE_OK  (HARD gate now)
#   [5c] instruments/seqbist/seqbist_bd.tcl -> SEQBIST_WIRE_OK  (SEQ-BIST is a
#        BD instrument, not a kit derivation; the three Task-1 .v are installed
#        at the tree root first, as apply_seqbist.sh does for a kit).
#        Env SP3_SKIP_SEQBIST=1 SKIPS this step: nothing is copied, the run
#        script does not source seqbist_bd.tcl, SEQBIST_WIRE_OK is not required
#        and no SEQBIST_VARIANT is written; the script prints SEQBIST_SKIPPED.
#        That is the "without the SEQ-BIST stage" half of the discriminating
#        rebuild in modem/dev/simulink/rxfix/README.md (suspect 2 for the sp3 TX wedge).
# and then [6] installs modem/vivado/txfix_build.{sh,tcl}.tmpl + TXFIX_VARIANT
# so the tree IS a build kit and the sp3 `vivado` stage runs the template
# UNCHANGED (open, generate, synth, timing gate, impl, bootgen).
#
# MOVSUM TMR (tmr_attr_inject.sh) is deliberately NOT applied: the sp3 single
# image is the 148 lineage, like sp2A.
#
# The recipe is LIFTED, not re-authored. Every step below cites the recorded
# script and line it came from:
#
#   [1] fresh kit copy          modem/build_byte_image.sh:17-20
#   [2] KITDIR repoint          modem/build_byte_image.sh:21-22
#   [3] MATLAB build_variant_byte + artifact gates
#                               modem/build_byte_image.sh:24-34
#       QPSK_LEAN=1             modem/build_lean_image.sh:5
#   [4] instrument injections
#         txcap_inject.py <tree>             modem/instruments/txcap/txcap_inject.py
#           (precondition for TXMARK=1: it creates the txFrameStart port on
#           QPSK_Tx/Transmitter/TxRxComposite that ddrcap_inject.py's TXMARK
#           path wires into. Every previously-recorded TXMARK=1 ddrcap_inject.py
#           run (modem/rtl_sim/build_ddrcap2_sim.sh:9) started from s1_rtl_final,
#           which already carries this patch via the s1_rtl_txcap intermediate
#           tree upstream in modem/rtl_sim/ -- a fresh MATLAB regen does not, so
#           this stage must run it explicitly first.)
#         TXMARK=1 ddrcap_inject.py <tree>   then   ddrcap2_inject.py <tree>
#                               modem/rtl_sim/build_ddrcap2_sim.sh:9-10
#       BD ports (ddrcap_bd.tcl) docs/superpowers/plans/2026-08-31-ddr-raw-capture.md:147-163
#   [5] RTL diff vs the bank    (this stage's gate)
#
# The Vivado step [4c] only rewires the block design (util_adc_2_pack -> the
# five capture ports); it touches no .v, so it is bounded and NON-FATAL here --
# the deliverable is the RTL comparison.
#
# Prints BASE_REGEN_DONE, then BASE_RTL_EQUIV files=<n> diff=<m>.
#
# An injector that cannot find its anchor is RECORDED, not fatal: it prints
# BASE_REGEN_INJECT_FAILED and the run continues to the diff, because the RTL
# comparison is the deliverable and a missing anchor is itself a finding about
# the chain. BASE_RTL_EQUIV must never be read without that token.
#
# Standing ruling (cleanup sub-project 2, Task 12): the banked base tree stays
# canonical no matter what. This script produces a SEPARATE tree and diffs it.
set -u

usage() { echo "usage: $0 <dest_parent> [--tree dev|prod] [--kit-name NAME] [--complete-bd] [--diff-bank DIR]"; }

DEST_ARG=""; KIT_NAME=""; COMPLETE_BD=0; DIFF_BANK=""; DIFF_BANK_SET=0
while [ $# -gt 0 ]; do
  case $1 in
    --kit-name)    KIT_NAME=$2; shift 2 ;;
    --tree)        TREE=$2; shift 2 ;;
    --complete-bd) COMPLETE_BD=1; shift ;;
    --diff-bank)   DIFF_BANK=$2; DIFF_BANK_SET=1; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    -*)            echo "BUILD_HDL_BAD_ARG $1"; usage; exit 2 ;;
    *)             [ -z "$DEST_ARG" ] || { echo "BUILD_HDL_BAD_ARG extra positional $1"; usage; exit 2; }
                   DEST_ARG=$1; shift ;;
  esac
done
[ -n "$DEST_ARG" ] || { usage; exit 2; }

# readlink -f so the compatibility symlink modem/fixes/build_base_tree.sh
# resolves to this file's REAL directory (modem/) -- without it $HERE would be
# modem/fixes when invoked through the symlink and $REPO would be modem/.
HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)   # <repo>/modem
REPO=$(cd "$HERE/.." && pwd)                   # repo root
TREE=${TREE:-dev}                              # dev = overlay-driven source (assemble); prod = flattened model (load)
case "$TREE" in dev|prod) ;; *) echo "BUILD_HDL_BAD_TREE $TREE (dev|prod)"; exit 2 ;; esac
KIT="$REPO/modem/$TREE"                        # the kit the recipe copies FROM (a kit root; shared files are symlinks)
INSTR="$REPO/modem/instruments"

mkdir -p "$DEST_ARG" || { echo "FATAL: cannot create dest parent $DEST_ARG"; exit 1; }
DEST_PARENT=$(cd "$DEST_ARG" && pwd)
FRESH="$DEST_PARENT/${KIT_NAME:-jupiter_byte_ddrcap2_build.regen}"

# The banked base tree. Overridable for a dry inspection, never written to.
BANK=${BASE_TREE_BANK:-/mnt/onetb/scratch/qpsk-build-trees/base/jupiter_byte_ddrcap2_build}
# Legacy invocation (no --kit-name, no --complete-bd) keeps the bank diff on, so
# nothing that calls this script the old way loses its BASE_RTL_EQUIV line.
if [ $DIFF_BANK_SET -eq 0 ] && [ -z "$KIT_NAME" ] && [ $COMPLETE_BD -eq 0 ]; then
  DIFF_BANK="$BANK"
fi

# --- guard: step [1] is `rm -rf "$FRESH"`. Refuse to aim it at the bank. -----
case "$FRESH/" in
  "$BANK"/*|/mnt/onetb/scratch/qpsk-build-trees/base/*)
    echo "FATAL: refusing to regenerate into the banked base tree area ($FRESH)"; exit 1;;
esac
[ -d "$BANK" ] || { echo "FATAL: banked base tree not found: $BANK"; exit 1; }

# --- vendor roots: the recipe's PATH, but probed rather than assumed ---------
MATLAB_BIN=/mnt/onetb/MATLAB/R2025b/bin
VIVADO_BIN=/tools/Xilinx/2025.1/Vivado/bin
[ -x "$MATLAB_BIN/matlab" ] || { echo "FATAL: no MATLAB at $MATLAB_BIN/matlab"; exit 1; }
HAVE_VIVADO=1
[ -x "$VIVADO_BIN/vivado" ] || { HAVE_VIVADO=0; echo "NOTE: no Vivado at $VIVADO_BIN/vivado -- the BD step needs the Vivado host"; }
export PATH=$MATLAB_BIN:$VIVADO_BIN:/usr/bin:/bin:$PATH

export QPSK_LEAN=1                             # build_lean_image.sh:5
# RATE RUNG. sp4 (2026-09-18, docs/superpowers/specs/2026-09-13-2sps-rung-design.md):
# 2 samples per symbol at the unchanged 61.44 MSPS interface with the doubled f3072
# frame (24,634 slots = 49,268 samples per frame, 382 delivered words). The
# previous shipped rung was sps=4 / f1536 (sp2/sp3; 12,333 slots = 49,332 samples);
# it stays selectable (QPSK_FRAME=f1536 QPSK_SPS=4 in the environment overrides
# these two lines -- the one-way images are built that way, decision A) and
# modem/common/model/frame_config_k5.m defaults to sps=8, so the exports are
# load-bearing: omitting them silently regenerates a DIFFERENT rate rung. Proof in
# the generated RTL: TxRxCompo_ip_src_Rate_Handle.v carries
#   reg HDL_Counter_out1;        // ufix1   (mod-2 = sps 2)
#   reg [1:0] HDL_Counter_out1;  // ufix2   (mod-4 = sps 4)
#   reg [2:0] HDL_Counter_out1;  // ufix3   (mod-8 = sps 8)
export QPSK_FRAME=${QPSK_FRAME:-f3072}
export QPSK_SPS=${QPSK_SPS:-2}
# the bank is LEAN + BEATFIX + BEATOBS + FRAMESTAT (docs/evidence/sp2/BASE_REGEN_DIVERGENCE.md §4);
# assemble carries these as env-gated phase 2.19/2.20 since 2026-09-11 (sp3 Task 1, Gate 0).
# QPSK_BEATOBS=1 is TAPS ONLY since 2026-09-24 (docs/evidence/sp4/TAP_A_BEATOBS.md): the
# ddrcap2 injector needs the Symbol Synchronizer beatobs ports, but the composite debugI1/Q1
# (Tap-A, rx1 IIO voltage0) keep the receiver-input IQ. QPSK_BEATOBS_TAP is deliberately NOT
# exported here -- set it only for a beat-hunt build that wants the packed state vector on Tap-A.
export QPSK_BEATFIX=1
export QPSK_BEATOBS=1
export QPSK_FRAMESTAT=1
# sp3 task 4: the RXFIX model overlays (modem/dev/simulink/rxfix/, phase 2.21) -- W1's census
# is the first; the netlist injectors they replace are modem/fixes/rxfix_inject.py
export QPSK_RXFIX=1
# sp3 task 8 fix round 2: the TX overlay (modem/dev/simulink/rxfix/txfix_f3_overlay.m) rides a
# SECOND gate so that a model-lineage UNFIXED baseline -- same receiver, stock
# transmitter -- is expressible for the four RX-capture rows of the TX gate
# matrix.  The normal regen is unchanged (both vars set).  `${QPSK_TXFIX-1}` (the
# `-` form, not `:-`) honours an override from the caller's environment even when
# it is set to the EMPTY string, which is how the baseline is built:
#     QPSK_TXFIX= modem/fixes/build_base_tree.sh <dest_parent>
export QPSK_TXFIX="${QPSK_TXFIX-1}"
# ONE-WAY test images (oneway_overlay.m): tx = Receiver stubbed, rx = Transmitter
# stubbed; empty = the full bidirectional modem.  Forwarded as-is.
ONEWAY=${QPSK_ONEWAY:-}
case "$ONEWAY" in ""|tx|rx) ;; *) echo "BUILD_HDL_BAD_ONEWAY $ONEWAY (tx|rx|unset)"; exit 2 ;; esac
export QPSK_ONEWAY="$ONEWAY"

echo "BASE_REGEN kit=$KIT dest=$FRESH bank=$BANK  $(date -Is)"
echo "BASE_REGEN matlab=$("$MATLAB_BIN/matlab" -batch "disp(version)" 2>/dev/null | tail -1)"

# === [1/5] fresh kit copy  (build_byte_image.sh:17-20) ======================
echo "=== [1/5] fresh kit copy -> $FRESH ==="
# One assembler for every kit (modem/common/tools/make_kit.sh): the tree, the shared
# common/{bd,model,rxfifo,tools}, gates/instruments/vivado/rtl_sim, a COPY of contract/
# as the kit sibling (the K5 overlays read it via kit_contract_dir.m), the KITDIR
# repoint of every shipped .m, and a no-symlink assertion.
MK_OUT=$(bash "$REPO/modem/common/tools/make_kit.sh" "$TREE" "$FRESH") || { echo "$MK_OUT"; echo "FATAL: make_kit failed"; exit 1; }
echo "$MK_OUT" | tail -1
[ -f "$DEST_PARENT/contract/rom_words_70_k5.txt" ] \
  || { echo "FATAL: sibling contract/ has no rom_words_70_k5.txt"; exit 1; }
echo "=== [2/5] KITDIR repoint (done by make_kit) ==="

# === [3/5] MATLAB build_variant_byte  (build_byte_image.sh:24-34) ==========
# NOTE: no `set -e`. MATLAB is EXPECTED to exit nonzero at HDL Coder's Create
# Project task (the insert-path bug, build_byte_image.sh:24,26). The gate is
# the artifact set, not the exit code.
echo "=== [3/5] MATLAB build_variant_byte (QPSK_LEAN=1; CreateProject fail EXPECTED) ==="
T0=$(date +%s)
( cd "$FRESH" && timeout 5400 matlab -batch "cd('$FRESH'); build_variant_byte" ) \
  > "$FRESH/build_byte_matlab.log" 2>&1
MRC=$?; T1=$(date +%s)
echo "  matlab exit=$MRC (nonzero at Create Project is expected)  elapsed=$((T1-T0))s"
Z="$FRESH/hdl_prj_jupiter_composite/vivado_ip_prj"
[ -f "$Z/vivado_prj.xpr" ] || { echo "FATAL: no vivado project produced"; tail -20 "$FRESH/build_byte_matlab.log"; exit 1; }
[ -f "$Z/ipcore/TxRxCompo_ip_v1_0.zip" ] || { echo "FATAL: no ipcore zip"; exit 1; }
if ! grep -q 'byte_breakout' "$Z/vivado_prj.srcs/sources_1/bd/system/system.bd" 2>/dev/null; then
  echo "FATAL: BD has no byte_breakout -- wrong reference design (byte maps not applied)"; exit 1
fi
echo "  byte reference-design BD confirmed (byte_breakout present)"

# === [4/5] instrument injections ===========================================
# txcap_inject.py FIRST: it creates the txFrameStart port that TXMARK=1
# ddrcap_inject.py's patch_transmitter/patch_composite anchor on. Every
# previously-recorded TXMARK=1 run started from s1_rtl_final, which already
# carries this patch via the s1_rtl_txcap intermediate tree
# (modem/rtl_sim/build_ddrcap2_sim.sh:9); a fresh MATLAB regen does not, so it
# is applied explicitly here. Then TXMARK=1 ddrcap_inject.py, then
# ddrcap2_inject.py, per modem/rtl_sim/build_ddrcap2_sim.sh:9-10. The BD step
# sits between the ddrcap and ddrcap2 injectors per the DDRCAP plan (Task 3 ->
# Task 4).
echo "=== [4/5] TXCAP -> DDRCAP (TXMARK=1) -> BD ports -> DDRCAP-v2 ==="
INJECT_FAILED=""

# === [4a/5] rxfifo: the BRAM drop-in ByteRxFifo (4096 words; 8192 at f3072) ===
# The SHIPPED design's ByteRxFifo is NOT HDL Coder's output: it is the
# hand-authored v5 BRAM drop-in modem/common/rxfifo/ByteRxFifo.v (true simple
# dual-port RAM, drop-oldest on full, handshake state on 0x1B0), installed over
# every loose/ipcore/zip copy of the generated module by modem/common/rxfifo/rxfifo_inject.sh.
# HDL Coder emits a 64-deep REGISTER fifo from modem/byte_rxfifo_overlay.m, which
# covers ~0.25 ms at f1536 and is overflowed by the axi_dmac S2MM inter-transfer
# backpressure (the forward "boundary comb").  A regen without this stage is
# therefore NOT the shipped netlist, and modem/fixes/rxfix_inject.py's BS section
# refuses the generated form by name.  Ruling (sp3 task 7): the drop-in is a
# TRACKED DESIGN SOURCE, not an instrument -- rebuilding it in Simulink is a
# follow-up, recorded in docs/evidence/sp3/BYTERXFIFO_DROPIN.md.  It runs FIRST,
# before txcap/ddrcap/ddrcap2, because it REPLACES a whole file and would
# otherwise discard their edits (those injectors do not touch ByteRxFifo.v today,
# but the ordering makes that independent of their future contents).
# DEPTH 4096 is the shipped depth (rxfifo_inject.sh's own default, and the depth
# build_sro_bs.sh's gate trees are built at); rxfix_bs_overlay.m's occupancy
# shadow hard-codes the same number.
echo "=== [4a/5] rxfifo: BRAM drop-in ByteRxFifo (modem/common/rxfifo/rxfifo_inject.sh) ==="
# depth follows the frame (frame_config_k5.m cfg.RxFifoDepth): 4096 words hold ~21 f1536
# frames; the doubled f3072 frame keeps that margin at 8192 (the BS census mirrors it).
RXFIFO_DEPTH=4096; [ "$QPSK_FRAME" = f3072 ] && RXFIFO_DEPTH=8192
"$REPO/modem/common/rxfifo/rxfifo_inject.sh" "$FRESH" "$RXFIFO_DEPTH" > "$FRESH/rxfifo_inject.out" 2>&1
RC=$?; tail -2 "$FRESH/rxfifo_inject.out"
# files+zips=0 means the finder matched nothing -- rxfifo_inject.sh still prints
# RXFIFO_INJECT_OK in that case (it is reporting "the replace loop ran without
# error", not "something was replaced"), so the token alone is not sufficient:
# require at least one file or zip actually replaced.
if [ $RC -ne 0 ] || ! grep -Eq '^RXFIFO_INJECT_OK .*files\+zips=[1-9][0-9]*' "$FRESH/rxfifo_inject.out"; then
  echo "BASE_REGEN_INJECT_FAILED stage=rxfifo rc=$RC"
  INJECT_FAILED="$INJECT_FAILED rxfifo"
fi
if [ -n "$ONEWAY" ]; then
  # the three netlist instruments anchor on the internals of BOTH halves; a
  # one-way image has one half stubbed, so they are not applied (and the ddrcap
  # block-design step below is skipped with them)
  echo "INJECT_SKIPPED_ONEWAY txcap ddrcap ddrcap2 (QPSK_ONEWAY=$ONEWAY)"
else
python3 "$INSTR/txcap/txcap_inject.py" "$FRESH" > "$FRESH/txcap_inject.out" 2>&1
RC=$?; tail -2 "$FRESH/txcap_inject.out"
if [ $RC -ne 0 ]; then
  # RECORDED, NOT FATAL -- same policy as the ddrcap/ddrcap2 stages below: an
  # injector that cannot find its anchor is a finding about the chain, not a
  # reason to forfeit the RTL diff. If txcap fails, the downstream TXMARK=1
  # ddrcap_inject.py failure this stage exists to prevent will likely recur
  # and both will show up as BASE_REGEN_INJECT_FAILED tokens.
  AN=$(grep -o 'anchor missing in [^:]*: .*' "$FRESH/txcap_inject.out" | tail -1 | sed 's/.*: //')
  echo "BASE_REGEN_INJECT_FAILED stage=txcap rc=$RC anchor=${AN:-unknown}"
  INJECT_FAILED="$INJECT_FAILED txcap"
fi

TXMARK=1 python3 "$INSTR/ddrcap/ddrcap_inject.py" "$FRESH" > "$FRESH/ddrcap_inject.out" 2>&1
RC=$?; tail -2 "$FRESH/ddrcap_inject.out"
if [ $RC -ne 0 ]; then
  # RECORDED, NOT FATAL. The RTL comparison is this stage's deliverable, and an
  # injector that cannot find its anchor is itself a finding about the chain --
  # so it must not forfeit the diff. The token below is the signal that the
  # regenerated tree is NOT instrument-complete; never read BASE_RTL_EQUIV
  # without it.
  AN=$(grep -o 'anchor missing in [^:]*: .*' "$FRESH/ddrcap_inject.out" | tail -1 | sed 's/.*: //')
  echo "BASE_REGEN_INJECT_FAILED stage=ddrcap rc=$RC anchor=${AN:-unknown}"
  INJECT_FAILED="$INJECT_FAILED ddrcap"
fi

# --complete-bd moves this BD edit into step [5], where it runs in ONE Vivado
# session after complete_byte_bd.tcl has actually created TxRxCompo_ip_0 -- and
# is a HARD gate there. Without --complete-bd (the legacy invocation) it stays
# exactly where it was, and stays a WARN, because on an uncompleted project the
# cell it needs does not exist and never did.
if [ "$COMPLETE_BD" = 1 ]; then
  echo "  BD step deferred to [5] (--complete-bd)"
elif [ "$HAVE_VIVADO" = 1 ]; then
  cat > "$FRESH/ddrcap_bd_run.tcl" <<TEOF
open_project $Z/vivado_prj.xpr
source $INSTR/ddrcap/ddrcap_bd.tcl
validate_bd_design
puts "DDRCAP_BD_RUN_DONE"
TEOF
  ( cd "$Z" && timeout 3600 vivado -mode batch -notrace -nolog -nojournal \
      -source "$FRESH/ddrcap_bd_run.tcl" ) > "$FRESH/ddrcap_bd.log" 2>&1
  if grep -q 'DDRCAP_BD_WIRE_OK' "$FRESH/ddrcap_bd.log"; then
    echo "  BD step: DDRCAP_BD_WIRE_OK"
  else
    echo "  WARN: BD step did not report DDRCAP_BD_WIRE_OK (see $FRESH/ddrcap_bd.log)"
    echo "  WARN: the BD edit touches no .v -- continuing to the DDRCAP-v2 injection and the RTL diff"
  fi
else
  echo "  SKIP: BD step requires the Vivado host; RTL is unaffected by it"
fi

python3 "$INSTR/ddrcap2/ddrcap2_inject.py" "$FRESH" > "$FRESH/ddrcap2_inject.out" 2>&1
RC=$?; tail -2 "$FRESH/ddrcap2_inject.out"
if [ $RC -ne 0 ]; then
  echo "BASE_REGEN_INJECT_FAILED stage=ddrcap2 rc=$RC"
  INJECT_FAILED="$INJECT_FAILED ddrcap2"
fi

fi

echo "BASE_REGEN_DONE tree=$FRESH"

# === [5] BD completion + BD instruments (ONE Vivado session) ================
# Order is the controller ruling: complete_byte_bd -> ddrcap_bd -> seqbist_bd.
# All three edit the SAME open block design; a separate session per step would
# mean re-opening and re-saving system.bd three times for no benefit.
if [ "$COMPLETE_BD" = 1 ]; then
  echo "=== [5] BD completion: complete_byte_bd -> ddrcap_bd -> seqbist_bd ==="
  [ "$HAVE_VIVADO" = 1 ] || { echo "BUILD_HDL_FAIL --complete-bd needs Vivado at $VIVADO_BIN"; exit 1; }
  [ -f "$FRESH/bd/complete_byte_bd.tcl" ] \
    || { echo "BUILD_HDL_FAIL $FRESH/bd/complete_byte_bd.tcl missing (step [1] should have copied it from $KIT)"; exit 1; }
  # SEQ-BIST RTL + the emitted BD script, installed at the TREE ROOT so that
  # seqbist_bd.tcl's `[file dirname [info script]]` finds the three .v beside
  # it -- the same placement modem/instruments/seqbist/apply_seqbist.sh uses for
  # a kit.  The .v stay canonical in modem/rtl_sim/ (Task 9's gate trees consume
  # them there); these are copies, and their md5s are printed for provenance.
  SEQBIST_DIR="$INSTR/seqbist"
  # SP3_SKIP_SEQBIST=1 drops step [5c] entirely: no seqbist_bd.tcl, no Task-1
  # .v at the tree root, no `source seqbist_bd.tcl` in the run script, and
  # SEQBIST_WIRE_OK is NOT required of the log.  This exists for the
  # discriminating rebuild modem/dev/simulink/rxfix/README.md names -- suspect 2 for the sp3
  # TX-side wedge is the SEQ-BIST BD instrument emitted with the `vendh` variant
  # onto the 148-lineage BD, and the only way to drop it from the image is to
  # not run it.  Combine with `QPSK_TXFIX=` to drop suspect 1 as well.
  SEQBIST_SRC_LINE="source $FRESH/seqbist_bd.tcl"
  SEQBIST_TOK="SEQBIST_WIRE_OK"
  if [ "${SP3_SKIP_SEQBIST:-0}" = 1 ]; then
    SEQBIST_SRC_LINE="# seqbist_bd.tcl SKIPPED (SP3_SKIP_SEQBIST=1)"
    SEQBIST_TOK=""
    echo "SEQBIST_SKIPPED reason=SP3_SKIP_SEQBIST=1 (no SEQ-BIST BD instrument in this tree)"
  else
    [ -f "$SEQBIST_DIR/seqbist_bd.tcl" ] \
      || { echo "BUILD_HDL_FAIL $SEQBIST_DIR/seqbist_bd.tcl missing (regenerate with patch_seqbist_tcl.py --emit-tcl)"; exit 1; }
    cp "$SEQBIST_DIR/seqbist_bd.tcl" "$FRESH/seqbist_bd.tcl" || exit 1
    for f in qpsk_traffic_gen_v2.v rx_seq_checker.v cnt_mux32.v; do
      [ -f "$REPO/modem/rtl_sim/$f" ] || { echo "BUILD_HDL_FAIL seqbist RTL missing: modem/rtl_sim/$f"; exit 1; }
      cp "$REPO/modem/rtl_sim/$f" "$FRESH/$f" || exit 1
      echo "  seqbist rtl $f md5=$(md5sum "$FRESH/$f" | awk '{print $1}')"
    done
  fi
  DDRCAP_SRC_LINE="source $INSTR/ddrcap/ddrcap_bd.tcl"; DDRCAP_TOK="DDRCAP_BD_WIRE_OK"
  if [ -n "$ONEWAY" ]; then
    DDRCAP_SRC_LINE="# ddrcap_bd.tcl SKIPPED (QPSK_ONEWAY=$ONEWAY: ddrcap injector not applied)"; DDRCAP_TOK=""
    echo "DDRCAP_BD_SKIPPED reason=QPSK_ONEWAY=$ONEWAY"
  fi
  cat > "$FRESH/complete_bd_run.tcl" <<TEOF
# generated by modem/build_hdl.sh --complete-bd
source $FRESH/bd/complete_byte_bd.tcl
$DDRCAP_SRC_LINE
validate_bd_design
save_bd_design
$SEQBIST_SRC_LINE
puts "COMPLETE_BD_RUN_DONE"
TEOF
  ( cd "$Z" && timeout 10800 vivado -mode batch -notrace -nolog -nojournal \
      -source "$FRESH/complete_bd_run.tcl" ) > "$FRESH/complete_bd.log" 2>&1
  BDRC=$?
  # Hard gates. Every one of these is a line the sourced scripts print exactly
  # once on success; a missing one means the BD is not what the vivado stage
  # expects, and a 2 h 15 remote build on a half-wired BD is the failure mode
  # this gate exists to prevent.
  BD_MISSING=""
  for tok in BYTE_WIRE_OK WIRE_OK VALIDATE_OK DDS_DIET_OK COMPLETE_BYTE_BD_DONE \
             $DDRCAP_TOK $SEQBIST_TOK COMPLETE_BD_RUN_DONE; do
    grep -q "$tok" "$FRESH/complete_bd.log" || BD_MISSING="$BD_MISSING $tok"
  done
  if [ -n "$BD_MISSING" ]; then
    echo "BUILD_HDL_BD_FAIL rc=$BDRC missing:$BD_MISSING (see $FRESH/complete_bd.log)"
    grep -E 'ERROR|_FAIL|FAILED|ABORT' "$FRESH/complete_bd.log" | tail -20
    exit 1
  fi
  # Independent re-verification: the cell the whole ruling is about must be in
  # the SAVED system.bd, not merely in the log.
  SBD="$Z/vivado_prj.srcs/sources_1/bd/system/system.bd"
  grep -q 'TxRxCompo_ip_0' "$SBD" || { echo "BUILD_HDL_BD_FAIL no TxRxCompo_ip_0 in $SBD"; exit 1; }
  if [ -n "$SEQBIST_TOK" ]; then
    for c in rx_seq cnt_mux traffic_gen tgen_ctrl_gpio tgen_rx_ctrl_gpio tgen_rx_wit_gpio; do
      grep -q "\"$c\"" "$SBD" || { echo "BUILD_HDL_BD_FAIL seqbist cell $c not in the saved system.bd"; exit 1; }
    done
  fi
  # Absolute source paths in the .xpr do not survive the rsync to the Vivado
  # host: the remote tree is at a different absolute path, and Vivado would fail
  # to find the file two hours into the run. Vivado writes $PPRDIR-relative refs
  # for files inside the tree, which is why the seqbist .v are installed at the
  # tree root rather than referenced in place under modem/rtl_sim/.
  # Only <File Path=...> entries: the <Project ...> header's own Path IS absolute
  # (it is the .xpr's own location, which Vivado rewrites on open) and matching it
  # was a false positive, measured 2026-09-12. Vivado writes $PPRDIR/$PSRCDIR
  # relative refs for everything inside the tree -- including
  # $PPRDIR/../../{qpsk_traffic_gen_v2,rx_seq_checker,cnt_mux32}.v at the kit
  # root, which is why the seqbist sources are installed there rather than
  # referenced in place under modem/rtl_sim/.
  ABSPATH=$(grep -o '<File Path="[^"]*"' "$Z/vivado_prj.xpr" | grep '<File Path="/' | sort -u)
  if [ -n "$ABSPATH" ]; then
    echo "BUILD_HDL_BD_FAIL vivado_prj.xpr carries ABSOLUTE source paths (they will not resolve on the Vivado host):"
    echo "$ABSPATH"; exit 1
  fi
  echo "BUILD_HDL_BD_OK tokens=BYTE_WIRE_OK,WIRE_OK,VALIDATE_OK,DDS_DIET_OK,COMPLETE_BYTE_BD_DONE${DDRCAP_TOK:+,$DDRCAP_TOK}${SEQBIST_TOK:+,$SEQBIST_TOK}"

  # === [6] assemble the tree AS a build kit ================================
  # The sp3 `vivado` stage runs modem/vivado/txfix_build.sh.tmpl UNCHANGED, and
  # that template needs four things at the kit root: build_txfix.sh,
  # build_txfix.tcl, timing_gate.tcl (build_txfix.tcl sources it via
  # [file dirname [info script]]) and TXFIX_VARIANT (build_txfix.sh exits 1
  # without it). timing_gate.tcl arrived with the step-[1] kit copy.
  echo "=== [6] kit assembly (modem/vivado templates) ==="
  cp "$REPO/modem/vivado/txfix_build.sh.tmpl"  "$FRESH/build_txfix.sh"  || exit 1
  cp "$REPO/modem/vivado/txfix_build.tcl.tmpl" "$FRESH/build_txfix.tcl" || exit 1
  chmod +x "$FRESH/build_txfix.sh"
  # ONE clock for modem + DAC (2026-09-13, docs/evidence/sp3/SP3_GATE3_RETEST.md sections 7-9): the
  # kit carries pre_synth.tcl + txclk_bd.tcl at its root; build_txfix.tcl sources pre_synth.tcl with
  # the project open, before generate_target, and the script sets axi_adrv9001 USE_RX_CLK_FOR_TX1=1
  # (gates in the vivado log: PRE_SYNTH_HOOK_OK, TXCLK_PARAM_OK, TXCLK_WIRE_OK, TXCLK_VALIDATE_OK).
  # SP3_SKIP_TXCLK=1 leaves the files out (the discriminating rebuild on two clocks).
  rm -f "$FRESH/txcdc_bd.tcl" "$FRESH/tx_cdc_fifo.v"     # the superseded FIFO attempt never ships in a kit
  if [ "${SP3_SKIP_TXCLK:-0}" = 1 ]; then
    rm -f "$FRESH/pre_synth.tcl" "$FRESH/txclk_bd.tcl"; echo "TXCLK_KIT_SKIPPED (SP3_SKIP_TXCLK=1)"
  else
    for f in pre_synth.tcl txclk_bd.tcl; do cp "$REPO/modem/instruments/txclk/$f" "$FRESH/$f" || exit 1; done
    echo "TXCLK_KIT_OK pre_synth.tcl txclk_bd.tcl"
  fi
  [ -f "$FRESH/bd/timing_gate.tcl" ] || { echo "BUILD_HDL_FAIL no bd/timing_gate.tcl in the kit"; exit 1; }
  # VARIANT is echoed into the build log and the TXFIX_BUILD_DONE line; SP3 is
  # not a txfix fix-variant letter, and the non-vendh template does not gate on
  # the value (only the vendh one does, which sp3 does not use).
  { echo "SP3"; echo "$(cd "$REPO" && git rev-parse --short HEAD)"; echo "SRC_KIT=model-regen"; [ -n "$ONEWAY" ] && echo "ONEWAY=$ONEWAY"; } > "$FRESH/TXFIX_VARIANT"
  if [ -n "$SEQBIST_TOK" ]; then
    SB_MD5=$(cd "$FRESH" && md5sum qpsk_traffic_gen_v2.v rx_seq_checker.v cnt_mux32.v | awk '{printf "%s=%s ", $2, $1}')
    { echo "vendh"; echo "$(cd "$REPO" && git log -1 --format=%H -- modem/instruments/seqbist/patch_seqbist_tcl.py 2>/dev/null)";
      echo "SRC_KIT=model-regen"; echo "RTL: $SB_MD5"; echo "WITH_CRC=1"; } > "$FRESH/SEQBIST_VARIANT"
  else
    rm -f "$FRESH/SEQBIST_VARIANT"
  fi
  grep -q 'jupiter_byte_sp3\*_build' "$FRESH/build_txfix.sh" \
    || { echo "BUILD_HDL_FAIL installed build_txfix.sh does not accept the sp3 kit name"; exit 1; }
  echo "BUILD_HDL_KIT_OK kit=$FRESH variant=SP3"
fi

# === [7] MODEL OVERLAY post-check ==========================================
# The six model-backported overlays must actually be in the generated RTL. This
# is the hdl-stage half of the plan's `tree_marker.sh ... all model` post-check:
# tree_marker.sh scores a gate TREE (it needs the RXFIX_ORIGIN stamp that
# make_sro_trees.sh --from-regen writes), which does not exist until the gates
# stage, so here the same evidence is read straight out of hdlsrc.
HS="$FRESH/hdl_prj_jupiter_composite/hdlsrc/commhdlQPSKTxRxLoopback"
OV_MISSING=""
if [ "$ONEWAY" != tx ]; then   # ONE-WAY: the stubbed half's markers are absent by construction
  for m in RxW1Census RxSteer PdPopIndex BsSeamCensus FixCtlDec; do
    ls "$HS"/*"$m"*.v >/dev/null 2>&1 || OV_MISSING="$OV_MISSING $m"
  done
  grep -lq padCount "$HS"/*ByteSerializer.v 2>/dev/null || OV_MISSING="$OV_MISSING PAD/padCount"
fi
if [ "${QPSK_TXFIX:-}" != "" ] && [ "$ONEWAY" != rx ]; then
  grep -lq fullRAM "$HS"/*Bit_Packetizer.v 2>/dev/null || OV_MISSING="$OV_MISSING F3/fullRAM"
fi
if [ -n "$OV_MISSING" ]; then
  echo "MODEL_OVERLAYS_MISSING$OV_MISSING (hdlsrc=$HS)"
else
  echo "MODEL_OVERLAYS_OK W1 R4B/R4D R4DR1 BS PAD F3 all present in the generated RTL${ONEWAY:+ (QPSK_ONEWAY=$ONEWAY: stubbed half exempt)}"
fi

# === [7b] BS_READY_PAD post-check ===========================================
# Task 7 fix round 1, finding 4: nothing previously checked that HDL Coder's
# delay balancer pads `ready` by exactly 4 registers in the generated
# BsSeamCensus RTL. The round-1 defect was a hand-built 4-deep `readyD4` Delay
# block feeding an ALREADY-delayed signal into the census MLFB; the balancer
# then padded the block's OTHER raw inputs (e.g. `fixctl`) to match that path,
# but does not recognise a hand-built design Delay as pipeline of its own, so
# `readyD4` itself got balanced too -- landing an extra 4 beats on top of the
# deliberate 4 and computing `pop = valid(k) && ready(k-8)` where the drop-in
# pops on `valid(k) && ready(k-4)`. No gate leg caught it (task-7-report.md
# S4.1/S6). The round-2 fix removes the overlay's `Delay` block and feeds
# `byte_rx_ready` into the MLFB RAW, so the balancer supplies the missing 4
# beats itself -- width-for-width, enable-for-enable the same chain the
# drop-in's OWN ByteRxFifo.v carries:
#   reg [3:0] delayMatch_reg;  delayMatch_reg[0] <= ready  (if (enb));
#   assign ready_1 = delayMatch_reg[3];   pop = valid && ready_1;
# Checked across every generated copy (hdlsrc + any loose ipcore copy), not
# just the hdlsrc one, since a stale ipcore copy would ship a different netlist
# than the one just verified above.
BS_FILES=$(find "$FRESH/hdl_prj_jupiter_composite" -name '*BsSeamCensus*.v' 2>/dev/null)
BS_PAD_MISMATCH=0
# The pad depth is what the delay balancer chose for THIS generation. On the full
# image that is 4 and the drop-in ByteRxFifo carries the same 4 verbatim. On a
# ONE-WAY image the balancer solves a different model (one half is a stub) and
# lands on a different depth (measured 2 on the RX-only image); rxfifo_inject.sh
# now MEASURES the generated depth and mirrors it (chain=N in rxfifo_inject.out),
# so the contract to check is census depth == drop-in depth, with the full image
# still pinned to the historical 4.
PAD_N=4
if [ -n "$ONEWAY" ]; then
  PAD_N=$(sed -n 's/.*RXFIFO_INJECT_OK .*chain=\([0-9]*\).*/\1/p' "$FRESH/rxfifo_inject.out" 2>/dev/null | tail -1)
  [ -n "$PAD_N" ] || { PAD_N=4; echo "BS_READY_PAD_WARN oneway: no chain= in rxfifo_inject.out, assuming 4"; }
fi
PAD_TOP=$((PAD_N-1))
if [ "$PAD_N" -eq 1 ]; then PAD_DECL='reg[[:space:]]+delayMatch_reg'; PAD_ASSIGN='assign[[:space:]]+ready_1[[:space:]]*=[[:space:]]*delayMatch_reg[[:space:];]';
else PAD_DECL="reg[[:space:]]*\\[$PAD_TOP:0\\][[:space:]]*delayMatch_reg"; PAD_ASSIGN="assign[[:space:]]+ready_1[[:space:]]*=[[:space:]]*delayMatch_reg\\[$PAD_TOP\\]"; fi
if [ "$ONEWAY" = tx ]; then
  # TX-only image: the byte serializer is constant-driven (Receiver stub) and HDL
  # Coder is free to fold its ready pipeline; the PAD proof belongs to the RX half
  echo "BS_READY_PAD_SKIPPED_ONEWAY (QPSK_ONEWAY=tx: byte serializer is dead logic here)"
  BS_PAD_MISMATCH=-1
elif [ -z "$BS_FILES" ]; then
  BS_PAD_MISMATCH=1
else
  while IFS= read -r f; do
    if ! grep -Eq "$PAD_DECL" "$f" || ! grep -Eq "$PAD_ASSIGN" "$f"; then
      BS_PAD_MISMATCH=$((BS_PAD_MISMATCH+1))
    fi
  done <<< "$BS_FILES"
fi
if [ "$BS_PAD_MISMATCH" -lt 0 ]; then
  :   # skipped above (TX-only image)
elif [ "$BS_PAD_MISMATCH" -eq 0 ]; then
  echo "BS_READY_PAD_OK depth=$PAD_N${ONEWAY:+ (QPSK_ONEWAY=$ONEWAY: census depth == drop-in chain)}"
else
  echo "BS_READY_PAD_MISMATCH=$BS_PAD_MISMATCH"
  INJECT_FAILED="$INJECT_FAILED bspad"
fi

# === [8] RTL diff vs the banked base tree (optional evidence) ==============
if [ -z "$DIFF_BANK" ]; then
  echo "BASE_RTL_DIFF_SKIPPED (no --diff-bank; the sp3 pipeline does not consult the bank)"
  echo "BUILD_HDL_DONE tree=$FRESH"
  exit 0
fi
BANK="$DIFF_BANK"
# Every .v under hdl_prj_jupiter_composite/{hdlsrc,ipcore,vivado_ip_prj/ipcore}.
# Header-only = the difference vanishes once HDL Coder's generated-header lines
# (File Name / Created / Generated by / Model version) are stripped.
echo "=== [8] RTL diff vs $BANK ==="
# Every generated-header comment line HDL Coder stamps. No trailing ':' -- the
# 'Generated by' line has none, and 'Module'/'Source Path'/'Hierarchy Level' are
# stale in the bank (they predate the IP name prefixing) and are not logic.
HDR='^// (File Name|Created|Generated by|Module|Source Path|Hierarchy Level|Model version)'
# Content that exists ONLY in the bank because of a lineage step the tracked
# recipe does not carry: the BEATFIX/BEATOBS overlays (applied by
# modem/dev/simulink/beatila/run_beatfix_build.sh, which sed-patches the assemble
# script at build time), the fixctl/W1 witness ports, and the DDRCAP/DDRCAP-v2
# injections. A file whose only logic difference is one of these is CLASSIFIED,
# not unexplained.
MARK='beatfix_viol|beatobs_|BeatObs|BfContract|BfSerMux|BfGridPace|BfTagGen|FixCtlDec|FrameStat|framestat|enSlack|witA|witB|ddrcap_i|ddrcap_q|ddrcap_valid|ddrcap_mark|ddrcap2_slot_r|ddrcap_sel_r'
REPORT="$FRESH/base_rtl_diff.txt"
: > "$REPORT"
N=0; D=0; DH=0; DL=0; DM=0; ONLY_REGEN=0; ONLY_BANK=0
RB="$FRESH/hdl_prj_jupiter_composite"; BB="$BANK/hdl_prj_jupiter_composite"
for sub in hdlsrc ipcore vivado_ip_prj/ipcore; do
  [ -d "$RB/$sub" ] || [ -d "$BB/$sub" ] || continue
  while IFS= read -r rel; do
    a="$RB/$sub/$rel"; b="$BB/$sub/$rel"
    if [ ! -f "$b" ]; then ONLY_REGEN=$((ONLY_REGEN+1)); echo "ONLY_REGEN $sub/$rel" >> "$REPORT"; continue; fi
    N=$((N+1))
    cmp -s "$a" "$b" && continue
    D=$((D+1))
    if diff <(grep -Ev "$HDR" "$a") <(grep -Ev "$HDR" "$b") > /dev/null; then
      DH=$((DH+1)); echo "HEADER_ONLY  $sub/$rel" >> "$REPORT"
    elif grep -Eq "$MARK" "$b" && ! grep -Eq "$MARK" "$a"; then
      DM=$((DM+1)); echo "BANK_ONLY_INSTRUMENT $sub/$rel" >> "$REPORT"
    else
      DL=$((DL+1)); echo "LOGIC        $sub/$rel" >> "$REPORT"
      # stderr silenced: `head` closes the pipe and diff would print "Broken pipe"
      diff <(grep -Ev "$HDR" "$a") <(grep -Ev "$HDR" "$b") 2>/dev/null | head -40 >> "$REPORT"
    fi
  done < <(cd "$RB/$sub" 2>/dev/null && find . -name '*.v' -printf '%P\n' | sort)
  while IFS= read -r rel; do
    [ -f "$RB/$sub/$rel" ] || { ONLY_BANK=$((ONLY_BANK+1)); echo "ONLY_BANK  $sub/$rel" >> "$REPORT"; }
  done < <(cd "$BB/$sub" 2>/dev/null && find . -name '*.v' -printf '%P\n' | sort)
done
echo "BASE_RTL_CLASSES header_only=$DH bank_only_instrument=$DM logic=$DL only_in_regen=$ONLY_REGEN only_in_bank=$ONLY_BANK report=$REPORT"
[ -n "$INJECT_FAILED" ] && echo "BASE_REGEN_NOT_INSTRUMENT_COMPLETE stages=${INJECT_FAILED# }"
echo "BASE_RTL_EQUIV files=$N diff=$D"
echo "BUILD_HDL_DONE tree=$FRESH"
