#!/bin/bash
# make_sro_trees.sh -- regenerate the per-variant Verilator RTL trees that the
# build_sro_*.sh sim gates read.  The trees are gitignored (.gitignore:71
# modem/rtl_sim/s1_rtl_*/**); this script is how they are rebuilt.
#
# Usage: make_sro_trees.sh [--out DIR] [--src DIR] [W1 R4B R4D R4DR1 BS PAD ...]
#        make_sro_trees.sh --from-regen <REGEN_BASE>
#   --out DIR   where the trees are written        (default: this script's dir)
#   --src DIR   the PRISTINE sim lineage hdlsrc    (default: modem/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback)
#   variants    default: W1 R4B R4D R4DR1 BS PAD
#   --from-regen REGEN_BASE
#     model-backport (cleanup sub-project 3, task 2): instead of injecting overlays
#     onto the pristine s1 lineage, populate s1_rtl_model/ from a model-generated
#     build tree (REGEN_BASE/hdl_prj_jupiter_composite/hdlsrc/commhdlQPSKTxRxLoopback),
#     stripping HDL Coder's TxRxCompo_ip_src_ IP-kit prefix from file and module
#     names, and generate the *_model.v gate wrappers (fixctl-forcing copies of the
#     wrappers the six build_sro_*.sh scripts use). Mutually exclusive with the
#     overlay-variant flow above.
#
# THE PRISTINE TREE IS AN INPUT, NOT AN OUTPUT.  Read this before assuming the
# brief's shape.  `modem/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback` is the "s1"
# HDL-Coder lineage the whole Verilator gate chain was built on.  It is NOT the
# same artefact as a current Vivado build tree's
# `hdl_prj_jupiter_composite/hdlsrc/commhdlQPSKTxRxLoopback`:
#   * the build tree's files carry the IP-kit prefix (TxRxCompo_ip_src_ACS.v,
#     `module TxRxCompo_ip_src_ACS`), so `verilator -y` cannot resolve a single
#     module name out of it;
#   * the s1 lineage PREDATES the fixctl port -- RXFIX_W1_SIM_GATE.md §2 records
#     that `QPSK_Rx` there has no `fixctl` at all, which is why the injector ties
#     w1_freeze to 1'b0 on a --sim-tree and the freeze semantics are gated on the
#     extracted `rh_w1_census` module instead.
# So this script does not synthesise the pristine tree from a build tree; it
# asserts the lineage it was given and derives the variants from it.  Concern
# carried forward: that lineage lives only on disk (untracked, gitignored, and
# absent from tag archive/pre-cleanup-2026-09-09), so a fresh clone cannot
# recreate it -- see the report for Stage 4.
#
# WHAT EACH TREE CARRIES.  Measured off the trees the banked gate legs ran on,
# not off the brief: each rxfix variant tree carries ONLY ITS OWN marker (the R4B
# tree has no RXFIX_W1 in it), and the BS/PAD trees carry the BRAM drop-in
# ByteRxFifo.  build_sro_bs.sh:mk_tree is the source of truth for the BS trees and
# rebuilds them itself on every run; the BS branch here reproduces it so that
# `build_sro_pad.sh` (which only consumes s1_rtl_pad) has an input.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
INJ="$ROOT/modem/fixes/rxfix_inject.py"
PAD="$ROOT/modem/fixes/pad_patch.py"
FIFO="$ROOT/modem/common/rxfifo/ByteRxFifo.v"

OUT="$HERE"
SRC="$ROOT/modem/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback"
DEPTH=${DEPTH:-4096}
FROM_REGEN=""
VARS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT=$2; shift 2 ;;
    --src) SRC=$2; shift 2 ;;
    --from-regen) FROM_REGEN=$2; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    -*) echo "MAKE_SRO_BAD_ARG $1"; exit 2 ;;
    *) VARS+=("$1"); shift ;;
  esac
done

# --- model-generated tree path (--from-regen): separate from the overlay-injection
# --- flow below; generates s1_rtl_model/ plus the fixctl-forcing *_model.v wrappers.
gen_model_wrapper () {  # gen_model_wrapper <src wrapper.v> <model module name>
  local src=$1 modmod=$2 out orig_mod
  out="$HERE/${src%.v}_model.v"
  cp "$HERE/$src" "$out"
  orig_mod=$(grep -m1 -oP '(?<=^module )\S+' "$out")
  [ -n "$orig_mod" ] || { echo "MAKE_SRO_MODEL_WRAP_FAIL no module line in $HERE/$src"; exit 1; }
  sed -i "0,/^module $orig_mod\$/s//module $modmod/" "$out"
  sed -i "0,/^module $modmod\$/s//module $modmod\n  #(parameter [31:0] FIXCTL_INIT = 32'h0)/" "$out"
  sed -i "0,/^  TxRxComposite dut($/s//&\n    .fixctl(FIXCTL_INIT),/" "$out"
  grep -q "^module $modmod\$" "$out" || { echo "MAKE_SRO_MODEL_WRAP_FAIL module rename failed in $out"; exit 1; }
  grep -q "parameter \[31:0\] FIXCTL_INIT = 32'h0" "$out" || { echo "MAKE_SRO_MODEL_WRAP_FAIL FIXCTL_INIT parameter missing in $out"; exit 1; }
  grep -qE '\.(reg_)?fixctl\(FIXCTL_INIT\),' "$out" || { echo "MAKE_SRO_MODEL_WRAP_FAIL fixctl port connection missing in $out"; exit 1; }
  # sp3 task 4 (W1 model overlay): wrap_byte_w1.v's eight register taps read the
  # INJECTED W1's internal bus, dut.u_Receiver.u_QPSK_Rx.w1Bus[...], which exists
  # only on an rxfix_inject.py tree.  The model overlay (modem/dev/simulink/rxfix/rxfix_w1_overlay.m)
  # surfaces the same eight words as TxRxComposite COMPOSITE PORTS (w1_wita ...
  # w1_pc, the ones patch_hdlworkflow_rxfix.m maps to 0x214-0x230), so on the model
  # tree those eight assigns become plain port taps.  The hierarchical ring taps
  # above them are untouched: HDL Coder names those instances identically, which is
  # why the model tree verilates against them unchanged.
  if [ "$src" = wrap_byte_w1.v ]; then
    sed -i -E "s#^(  assign w1A    = ).*\$#\1dut.w1_wita;#; \
               s#^(  assign w1B    = ).*\$#\1dut.w1_witb;#; \
               s#^(  assign w1cSS  = ).*\$#\1dut.w1_ss;#; \
               s#^(  assign w1cRH  = ).*\$#\1dut.w1_rh;#; \
               s#^(  assign w1cCFC = ).*\$#\1dut.w1_cfc;#; \
               s#^(  assign w1cCS  = ).*\$#\1dut.w1_cs;#; \
               s#^(  assign w1cPD  = ).*\$#\1dut.w1_pd;#; \
               s#^(  assign w1cPC  = ).*\$#\1dut.w1_pc;#" "$out"
    n=$(grep -cE '^  assign w1(A|B|cSS|cRH|cCFC|cCS|cPD|cPC) +=  *dut\.w1_[a-z]+;$' "$out")
    [ "$n" = 8 ] || { echo "MAKE_SRO_MODEL_WRAP_FAIL w1 composite-port tap rewrite hit $n/8 assigns in $out"; exit 1; }
    grep -qE '^\s*assign .*w1Bus' "$out" && { echo "MAKE_SRO_MODEL_WRAP_FAIL residual w1Bus tap in $out"; exit 1; }
    echo "MAKE_SRO_MODEL_WRAP_W1TAPS $out (8 composite-port taps)"
  fi
  # sp3 task 5 (STEER model overlay): the sro4b/sro4d wrappers tap the INJECTED
  # steering registers, `u_Rate_Handle.r4b_*` / `r4d_*`, which exist only on an
  # rxfix_inject.py tree.  On a model tree the same state lives inside the MLFB
  # instance `u_Rate_Handle.u_RxSteer` under its SCRIPT names (measured in the
  # generated TxRxCompo_ip_src_RxSteer.v: persistents `skips`/`opens`/`extras`/
  # `wslot` and the combinational locals `locked`/`doSkip`/`doExtra` all survive
  # as module-level regs).  Widths are narrower at the tap than in the model
  # (`wire [3:0] r4b_slot_rtl` vs uint8 wslot <= 13; `[14:0] r4b_opens_w` vs a
  # uint16 that wraps at 32767) -- both truncations are exact for the ranges the
  # MLFB produces.
  #
  # rhPop IS REWRITTEN IN EVERY sro-SHAPED WRAPPER, and that one is a correctness
  # fix, not plumbing: on an injected tree `Logical_Operator_out1` IS the steered
  # pop (the injector redefines that assign), but the overlay leaves it as the
  # NOMINAL pop and drives the FIFO from RxSteerPopOr_out1.  Left alone the tap
  # would verilate cleanly and silently report nominal pops.  wrap_byte_bs.v
  # carries the same tap (:227) and so is in this list too, even though it has no
  # r4b_/r4d_ taps of its own.  (Nothing in sim_sro.cpp reads rhPop today -- only
  # rhPopEmpty -- so this is pre-emptive.)  NB the `u_Rate_Handle.` prefix is
  # load-bearing: `u_Preamble_Detector.Logical_Operator_out1` is a different tap
  # in the same files and must NOT be rewritten.
  case "$src" in
    wrap_byte_sro4b.v|wrap_byte_sro4d.v|wrap_byte_bs.v)
      sed -i -E "s#u_Rate_Handle\.Logical_Operator_out1#u_Rate_Handle.RxSteerPopOr_out1#g" "$out"
      grep -q 'assign rhPop      = dut\..*RxSteerPopOr_out1;' "$out" || {
        echo "MAKE_SRO_MODEL_WRAP_FAIL rhPop not re-pointed at the steered pop in $out"; exit 1; }
      if grep -q 'u_Rate_Handle\.Logical_Operator_out1' "$out"; then
        echo "MAKE_SRO_MODEL_WRAP_FAIL residual nominal-pop tap in $out"; exit 1; fi
      echo "MAKE_SRO_MODEL_WRAP_POPTAP $out (rhPop -> RxSteerPopOr_out1)"
      ;;
  esac
  # sp3 task 6 (R1 model overlay): `pdPopReq` taps
  # u_Preamble_Detector.Delay10_out1 -- the tail of the 49,332-deep tick delay.
  # The injector REDEFINES that net and keeps the name; the overlay DELETES the
  # Delay block (a 49k-bit shift register is real fabric in the model) and drives
  # the FIFO's pop plus Timing_Adjust's valid from the MLFB instead, so on a model
  # tree that net is the MLFB's own output -- MEASURED in the regenerated
  # TxRxCompo_ip_src_Preamble_Detector.v, HDL Coder names it after the script's
  # output variable (`wire pop;`, `.pop(pop)`), NOT `PdPopIndex_out1` -- and
  # `Delay10_out1`/`Delay10_reg` do not exist at all (grep -c Delay10 = 0).
  # The tap goes through the instance (`u_PdPopIndex.pop`) rather than the
  # module-level wire, because a bare `pop` is too generic to be a safe anchor.
  # verilator runs -Wno-fatal here, so a stale hierarchical tap is NOT guaranteed
  # to fail the build -- this assert is what catches a rename.  All three wrappers
  # that carry the tap (bs too, for task 8's sake).
  case "$src" in
    wrap_byte_sro4b.v|wrap_byte_sro4d.v|wrap_byte_bs.v)
      sed -i -E "s#(u_Preamble_Detector\.)Delay10_out1#\1u_PdPopIndex.pop#g" "$out"
      if grep -q 'u_Preamble_Detector\.Delay10_out1' "$out"; then
        echo "MAKE_SRO_MODEL_WRAP_FAIL residual Delay10_out1 PD tap in $out"; exit 1; fi
      n=$(grep -c 'u_Preamble_Detector\.u_PdPopIndex\.pop' "$out")
      [ "$n" = 1 ] || { echo "MAKE_SRO_MODEL_WRAP_FAIL $src: $n/1 pdPopReq taps in $out"; exit 1; }
      echo "MAKE_SRO_MODEL_WRAP_PDTAP $out (pdPopReq -> u_PdPopIndex.pop)"
      ;;
  esac
  # sp3 task 7 (BS model overlay): wrap_byte_bs.v:340 reads the INJECTED census's
  # 256-bit bus, `dut.u_bs_seam_census.bus`, which exists only on an
  # rxfix_inject.py tree.  On a model tree the eight words are the OUTPUTS of the
  # BsSeamCensus MATLAB Function block (modem/dev/simulink/rxfix/rxfix_bs_overlay.m); HDL Coder
  # names an MLFB's nets after the script's output VARIABLES (task 6's measured
  # surprise: `wire pop;`, not `PdPopIndex_out1`), so they are cWords..cCnt, and
  # the tap goes THROUGH the instance because those names are generic.  The
  # composite outports bs_words..bs_cnt carry the same values but three enb beats
  # later -- HDL Coder delay-matches every new composite output (rxfix/README.md,
  # "THREE enb beats late") -- and census_clean scores equality rows between the
  # wrapper's own recount and the census at the dump instant, so the lagged port
  # is exactly the wrong tap here.
  # Bus order is the injector's: {s7..s0}, word 0 = bs_words.
  if [ "$src" = wrap_byte_bs.v ]; then
    sed -i -E "s#dut\.u_bs_seam_census\.bus#{dut.u_BsSeamCensus.cCnt, dut.u_BsSeamCensus.cEvt, dut.u_BsSeamCensus.cMarks, dut.u_BsSeamCensus.cDrop, dut.u_BsSeamCensus.cPop, dut.u_BsSeamCensus.cPush, dut.u_BsSeamCensus.cStarts, dut.u_BsSeamCensus.cWords}#" "$out"
    if grep -q 'u_bs_seam_census' "$out"; then
      echo "MAKE_SRO_MODEL_WRAP_FAIL residual u_bs_seam_census tap in $out"; exit 1; fi
    n=$(grep -o 'dut\.u_BsSeamCensus\.c[A-Za-z]*' "$out" | sort -u | wc -l)
    [ "$n" = 8 ] || { echo "MAKE_SRO_MODEL_WRAP_FAIL $n/8 BsSeamCensus word taps in $out"; exit 1; }
    # The model census DERIVES drop from an occupancy shadow of the BRAM drop-in
    # (docs/evidence/sp3/BYTERXFIFO_DROPIN.md), so `bs_drop == 0` on its own is a
    # shadow agreeing with itself.  The drop-in module IS in this tree, so its own
    # saturating ovfCnt is tapped as the independent witness and printed once at
    # end of run.  It is a $display, not a census column: the dump format is the
    # banked 25-column one and must stay comparable record for record.
    python3 - "$out" <<'PYEOF'
import sys
p = sys.argv[1]; s = open(p).read()
# NOT in the `final` block: sim_sro.cpp never calls Verilator's ->final(), so
# nothing there runs.  (The last census record is a clk-tick dump landing off the
# 1 M grid because the push-grid trigger resets bs_tick -- build_sro_bs.legs'
# census_grid note says exactly that.)  Instead: one unconditional mid-run print,
# which proves the tap is LIVE, plus a one-shot on the first nonzero, which is the
# drop witness.  Silence on the second line is then a witnessed zero, not a dead tap.
a = "  // ---- which wrapper actually compiled."
assert a in s, "MAKE_SRO_MODEL_WRAP_FAIL wrapper-provenance anchor missing"
wit = """  // sp3 task 7: the model census DERIVES drop from an occupancy shadow of the BRAM
  // drop-in, so bs_drop == 0 would otherwise be a shadow agreeing with itself.  The
  // drop-in module IS in this tree, so its own saturating ovfCnt is the witness.
  reg bsw_seen;
  always @(posedge clk) begin
    if (reset) bsw_seen <= 1'b0;
    else begin
      if (h_clk == 32'd20000000)
        $display("BS_FIFO_WITNESS live at_clk=%0d ovfcnt=%0d", h_clk, dut.u_ByteRxFifo.ovfCnt);
      if (!bsw_seen && dut.u_ByteRxFifo.ovfCnt != 32'd0) begin
        bsw_seen <= 1'b1;
        $display("BS_FIFO_WITNESS first_drop at_clk=%0d ovfcnt=%0d", h_clk, dut.u_ByteRxFifo.ovfCnt);
      end
    end
  end

"""
s = s.replace(a, wit + a, 1)
open(p, "w").write(s)
PYEOF
    grep -q 'BS_FIFO_WITNESS' "$out" || { echo "MAKE_SRO_MODEL_WRAP_FAIL ovfCnt witness not inserted in $out"; exit 1; }
    echo "MAKE_SRO_MODEL_WRAP_BSTAPS $out (8 BsSeamCensus word taps + ovfCnt witness)"
  fi
  case "$src" in
    wrap_byte_sro4b.v|wrap_byte_sro4d.v)
      sed -i -E "s#u_Rate_Handle\.r4[bd]_do_skip#u_Rate_Handle.u_RxSteer.doSkip#g; \
                 s#u_Rate_Handle\.r4d_do_extra#u_Rate_Handle.u_RxSteer.doExtra#g; \
                 s#u_Rate_Handle\.r4[bd]_skips#u_Rate_Handle.u_RxSteer.skips#g; \
                 s#u_Rate_Handle\.r4d_extras#u_Rate_Handle.u_RxSteer.extras#g; \
                 s#u_Rate_Handle\.r4[bd]_locked#u_Rate_Handle.u_RxSteer.locked#g; \
                 s#u_Rate_Handle\.r4[bd]_opens#u_Rate_Handle.u_RxSteer.opens#g; \
                 s#u_Rate_Handle\.r4[bd]_wslot#u_Rate_Handle.u_RxSteer.wslot#g" "$out"
      if grep -q 'u_Rate_Handle\.r4[bd]_' "$out"; then
        echo "MAKE_SRO_MODEL_WRAP_FAIL residual r4b_/r4d_ Rate_Handle tap in $out"; exit 1; fi
      n=$(grep -c 'u_Rate_Handle\.u_RxSteer\.' "$out" || true)
      case "$src" in
        wrap_byte_sro4b.v) want=6 ;;
        wrap_byte_sro4d.v) want=7 ;;
      esac
      [ "$n" = "$want" ] || { echo "MAKE_SRO_MODEL_WRAP_FAIL $src: $n/$want u_RxSteer taps in $out"; exit 1; }
      echo "MAKE_SRO_MODEL_WRAP_STEERTAPS $out ($n u_RxSteer taps)"
      ;;
  esac
  echo "MAKE_SRO_MODEL_WRAP $out"
  # (LAST, after every wrapper edit above, so the w1/bs/pd tap rewrites cannot
  # re-introduce a dev name.)  modem/prod (flattened model) prefixes the composite's register ports with
  # reg_; the wrappers were written against the dev names.  Re-bind the dut
  # instance pins (.name( -> .reg_name() for every reg_ port the tree's top
  # declares; the wrapper's own ports keep their names so sim_*.cpp is unchanged.
  if grep -qE '^\s*(input|output)\s.*\breg_[A-Za-z0-9_]+' "$DST/TxRxComposite.v"; then
    local nre=0
    for rp in $(grep -oE '\breg_[A-Za-z0-9_]+' "$DST/TxRxComposite.v" | sort -u); do
      base=${rp#reg_}
      if grep -qE "\.${base}\(" "$out"; then
        sed -i -E "s/\.${base}\(/.${rp}(/g" "$out"; nre=$((nre+1))
      fi
      # hierarchical taps into the dut's top-level ports (e.g. `dut.w1_wita`)
      if grep -qE "\\bdut\\.${base}\\b" "$out"; then
        sed -i -E "s/\\bdut\\.${base}\\b/dut.${rp}/g" "$out"; nre=$((nre+1))
      fi
    done
    echo "MAKE_SRO_MODEL_WRAP_PRODPINS $out ($nre dut pins re-bound to reg_ names)"
  fi
}

if [ -n "$FROM_REGEN" ]; then
  [ ${#VARS[@]} -eq 0 ] || { echo "MAKE_SRO_BAD_ARG --from-regen takes no variant list"; exit 2; }
  REGEN_SRC="$FROM_REGEN/hdl_prj_jupiter_composite/hdlsrc/commhdlQPSKTxRxLoopback"
  [ -f "$REGEN_SRC/TxRxCompo_ip_src_TxRxComposite.v" ] || {
    echo "MAKE_SRO_FROM_REGEN_FAIL no TxRxCompo_ip_src_TxRxComposite.v in $REGEN_SRC"; exit 1; }
  DST="$OUT/s1_rtl_model"
  rm -rf "${DST:?}"
  mkdir -p "$DST"
  find "$REGEN_SRC" -maxdepth 1 -name '*.v' -exec cp -t "$DST" {} +
  ( cd "$DST" && for f in TxRxCompo_ip_src_*.v; do [ -e "$f" ] && mv "$f" "${f#TxRxCompo_ip_src_}"; done )
  # NOTE: no \b here -- some instance names carry the prefix directly after another
  # word char (e.g. `u_TxRxCompo_ip_src_TxRxComposite`, an instance name, not a module
  # name), where \b does not anchor between two word characters and the prefix would
  # survive. The literal string is unambiguous in this codebase (grep -c below), so a
  # plain global substitution is what "strip the prefix from module names/instantiations"
  # requires; the residual-prefix assert right after this is what actually enforces it.
  sed -i 's/TxRxCompo_ip_src_//g' "$DST"/*.v
  if grep -l "TxRxCompo_ip_src_" "$DST"/*.v >/dev/null 2>&1; then
    echo "MAKE_SRO_FROM_REGEN_FAIL residual TxRxCompo_ip_src_ prefix in $DST"; exit 1; fi
  REPO_SHA=$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null || echo no-git)
  echo "model $FROM_REGEN $REPO_SHA $(date -u +%Y-%m-%d)" > "$DST/RXFIX_ORIGIN"
  NFILES=$(ls "$DST"/*.v | wc -l)
  echo "SRO_TREE_MODEL $DST files=$NFILES"
  gen_model_wrapper wrap_byte_w1.v    wrap_byte_w1_model
  gen_model_wrapper wrap_byte_sro4b.v wrap_byte_sro_model
  gen_model_wrapper wrap_byte_sro4d.v wrap_byte_sro_model
  gen_model_wrapper wrap_byte_bs.v    wrap_byte_sro_model
  echo "MAKE_SRO_FROM_REGEN_DONE $DST"
  exit 0
fi

[ ${#VARS[@]} -gt 0 ] || VARS=(W1 R4B R4D R4DR1 BS PAD)

[ -d "$SRC" ] || { echo "MAKE_SRO_NO_HDLSRC $SRC"; exit 1; }
# lineage assertions: the bare (unprefixed) module names the gates' -y search needs,
# and the pre-fixctl QPSK_Rx that the --sim-tree injector expects.
[ -f "$SRC/Rate_Handle.v" ] && [ -f "$SRC/ByteSerializer.v" ] && [ -f "$SRC/QPSK_Rx.v" ] || {
  echo "MAKE_SRO_NOT_S1_LINEAGE $SRC (no bare Rate_Handle.v/ByteSerializer.v/QPSK_Rx.v)"; exit 1; }
if grep -rqE '^\s*module\s+TxRxCompo_ip_src_' "$SRC" 2>/dev/null; then
  echo "MAKE_SRO_KIT_SHAPED $SRC -- that is a Vivado build tree, not the s1 sim lineage"; exit 1; fi
mkdir -p "$OUT"
echo "MAKE_SRO_SRC $SRC ($(ls "$SRC" | grep -c '\.v$') .v files)"

inj () {  # inj <treedir> <variant...>
  local d=$1; shift
  local v
  for v in "$@"; do python3 "$INJ" "$d" "$v" --sim-tree | tail -1; done
}

mk_rxfix () {  # mk_rxfix <name> <variant...>
  local name=$1; shift
  rm -rf "${OUT:?}/$name"
  cp -r "$SRC" "$OUT/$name"
  inj "$OUT/$name" "$@"
  echo "MAKE_SRO_TREE $name <- $SRC + $*"
}

# --- reproduced from build_sro_bs.sh:mk_tree (that script is the source of truth
# --- and rebuilds s1_rtl_bs / s1_rtl_bs_base / s1_rtl_bs_gen on every gate run).
mk_bs_tree () {  # mk_bs_tree <name> <apply_bs:0|1>
  local d="$OUT/$1" bs=$2 aw
  rm -rf "${d:?}"
  cp -r "$SRC" "$d"
  aw=$(python3 -c "import math;print(int(math.log2($DEPTH)))")
  sed -e "s/^module ByteRxFifo #(parameter DEPTH = 4096, parameter AW = 12)/module ByteRxFifo #(parameter DEPTH = $DEPTH, parameter AW = $aw)/" \
      "$FIFO" > "$d/ByteRxFifo.v"
  grep -q "BRAM drop-in v5" "$d/ByteRxFifo.v" || { echo "MAKE_SRO_FAIL drop-in not installed in $d"; exit 1; }
  [ "$bs" = 1 ] && inj "$d" BS
  echo "MAKE_SRO_TREE $1 <- $SRC + BRAM drop-in(DEPTH=$DEPTH)$([ "$bs" = 1 ] && echo ' + BS')"
}

for want in "${VARS[@]}"; do
  case "$want" in
    W1)    mk_rxfix s1_rtl_rxfix_W1    W1 ;;
    R4B)   mk_rxfix s1_rtl_rxfix_R4B   R4B ;;
    R4D)   mk_rxfix s1_rtl_rxfix_R4D   R4D ;;
    R4DR1) mk_rxfix s1_rtl_rxfix_R4DR1 R4D R1 ;;
    BS)    mk_bs_tree s1_rtl_bs_base 0
           mk_bs_tree s1_rtl_bs      1
           # s1_rtl_bs_gen is s1_rtl VERBATIM: the GENERATED 64-deep ByteRxFifo,
           # no drop-in and no BS -- the wrapper-transparency tree (I5).
           rm -rf "${OUT:?}/s1_rtl_bs_gen"; cp -r "$SRC" "$OUT/s1_rtl_bs_gen"
           grep -q "reg \[63:0\] mem \[0:63\];" "$OUT/s1_rtl_bs_gen/ByteRxFifo.v" || {
             echo "MAKE_SRO_FAIL s1_rtl_bs_gen ByteRxFifo is not the generated 64-deep module"; exit 1; }
           echo "MAKE_SRO_TREE s1_rtl_bs_gen <- $SRC verbatim" ;;
    PAD)   [ -d "$OUT/s1_rtl_bs" ] || { echo "MAKE_SRO_FAIL PAD needs $OUT/s1_rtl_bs (run BS first)"; exit 1; }
           rm -rf "${OUT:?}/s1_rtl_pad"; cp -r "$OUT/s1_rtl_bs" "$OUT/s1_rtl_pad"
           python3 "$PAD" "$OUT/s1_rtl_pad/ByteSerializer.v"
           grep -q RXFIX_PAD "$OUT/s1_rtl_pad/ByteSerializer.v" || { echo "MAKE_SRO_FAIL pad marker missing"; exit 1; }
           echo "MAKE_SRO_TREE s1_rtl_pad <- s1_rtl_bs + pad_patch.py" ;;
    *) echo "MAKE_SRO_BAD_VARIANT $want"; exit 2 ;;
  esac
done
echo "MAKE_SRO_DONE out=$OUT variants=${VARS[*]}"
