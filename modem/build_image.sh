#!/bin/bash
# =============================================================================
# build_image.sh -- build the SINGLE deployable BOOT.BIN (sp3) from the Simulink
# model, end to end.  There is no --role and no fix chain any more: the W1 / R4B
# / R4D+R1 / BS / PAD / F3 fixes are MODEL overlays (modem/dev/simulink/rxfix/, phase 2.21),
# so one regeneration produces one image that carries all of them and runs on
# both boards.  The banked base tree is no longer an input.
#
#   Usage: build_image.sh [--tag T] [--work DIR] [--regen-parent DIR]
#                         [--from STAGE] [--stop-after STAGE]
#                         [--remote-base DIR] [--concurrent] [--dry] [--oneway tx|rx]
#
#   Stages, in order:  hdl  gates  vivado
#     hdl     modem/build_hdl.sh --kit-name jupiter_byte_<tag>_build --complete-bd
#             -> MATLAB regen (QPSK_LEAN/BEATFIX/BEATOBS/FRAMESTAT/RXFIX/TXFIX=1
#             at the f1536 sps=4 rung), the rxfifo/txcap/ddrcap/ddrcap2
#             instrument injections, then the BD completion and the two BD
#             instruments in one local Vivado session, then kit assembly.
#             Post-checks: BUILD_HDL_BD_OK, BUILD_HDL_KIT_OK, MODEL_OVERLAYS_OK.
#     gates   modem/rtl_sim/make_sro_trees.sh --from-regen <kit>  (the model gate
#             tree s1_rtl_model + its wrappers), modem/rtl_sim/tree_marker.sh on
#             that tree for W1 R4B R4DR1 BS PAD F3 -- every one must read `model`
#             -- then modem/gates/run_gates.sh --legs modem/gates/model_matrix.legs.
#     vivado  <kit>/build_txfix.sh -> remote synth/impl/bootgen on the Vivado
#             host, then GATE 2: the authoritative post-route modem-clock WNS
#             (modem/gates/modem_wns.py --min 0.005).
#
#   WHY THERE IS NO `seqbist` STAGE.  The plan lists `hdl seqbist gates vivado`.
#   SEQ-BIST is a BLOCK-DESIGN instrument: its Tcl edits the same system.bd that
#   complete_byte_bd.tcl has just created TxRxCompo_ip_0 in, and the controller's
#   ruling orders the three BD scripts complete_byte_bd -> ddrcap_bd -> seqbist_bd
#   INSIDE one Vivado session.  A separate stage would mean re-opening and
#   re-saving the block design a second time for no benefit, so step 3 of that
#   ruling lives inside `hdl`.  `--from seqbist` / `--stop-after seqbist` are
#   still RECOGNISED and rejected with BUILD_IMAGE_STAGE_MERGED (exit 2) rather
#   than the generic bad-stage error, so a caller working from the plan is told
#   where the work went instead of being told the name is a typo.
#
#   --tag T (default sp3) names the kit jupiter_byte_<T>_build and the image.
#   modem/vivado/txfix_build.sh.tmpl's kit-name guard accepts jupiter_byte_sp3*_build
#   and jupiter_byte_sp4*_build (and refuses any *_build_ref), so T must begin with
#   `sp3` or `sp4`. Default sp4 since 2026-09-18 (the 2-sps rung); an sp3 rebuild
#   is `--tag sp3... ` with QPSK_FRAME=f1536 QPSK_SPS=4 in the environment.
#
#   --regen-parent DIR (default /mnt/onetb/scratch/qpsk-build-trees/regen11) is
#   the PARENT the regenerated kit is written into; --work DIR (default
#   .../work_sp3) holds the stamps, the logs and the fetched BOOT.BIN.  They are
#   separate so that a concurrent task's regen parent (regen/, regen8/) is never
#   shared: a regen starts with `rm -rf` of its own kit dir.
#
#   --stop-after must not be strictly EARLIER than --from in stage order (equal
#   is fine, a one-stage run; later is fine); the earlier case would silently run
#   nothing and exits 2 with BUILD_IMAGE_BAD_RANGE instead.
#
#   --remote-base DIR puts the remote build tree at DIR/<kit> instead of the
#   default ~/qpsk-builds/<kit>: it is exported as REMOTE_BASE to build_txfix.sh
#   (which refuses anything but an absolute path or that default) AND used for
#   every fetch back out of the host -- the vivado log, boot/BOOT.BIN and the
#   impl_1 timing reports -- so the two can never point at different trees.
#   hdl-dev-2's / is nearly full and holds the AS-BUILT reference kits; its
#   second disk /mnt/disk2/scratch/qpsk-builds has room.  Recorded in STAMP.vivado.
#
#   --dry short-circuits the two stages that touch a remote host or take hours:
#   `hdl` prints what it would run and stamps hdl.dry; `vivado` stops at the
#   remote launch (build_txfix.sh prints the exact ssh command and nothing is
#   synced or launched) and stamps vivado.dry.  Belt and braces, --dry ALSO
#   forces rsync to -n inside that call via a PATH shim: older instantiated
#   copies of build_txfix.sh have the `rsync -a --delete` ABOVE their own --dry
#   gate (measured: 3,722 files would have been deleted from a remote reference
#   kit).  A .dry stamp is deliberately NOT the real stamp, so a later stage can
#   never mistake a preview for a run.  `gates` previews too
#   (BUILD_IMAGE_DRY_GATES) but does NOT exit: it sits in the middle of the
#   range, so a dry full run must still reach the vivado preview.  Under --dry
#   no stage enforces `need <prev>`: printing what WOULD run needs no stamp.
#
#   CONCURRENCY.  The gates stage refuses to start while any `sp2-gate-*` user
#   unit is running (BUILD_IMAGE_GATES_BUSY, exit 2).  It shares ONE gate tree
#   (modem/rtl_sim/s1_rtl_model) and ONE set of Verilator object directories
#   with every other run on the host, and SP2_WORK separates neither.
#
#   STAMPS.  Every stage writes <work>/STAMP.<stage>:
#     stage=<s> tag=<t> model_tree_sha=<16hex> git=<sha> when=<iso> result=<line>
#   model_tree_sha replaces sp2's manifest_sha (there is no manifest any more):
#   it is sha256 over the sorted list of generated .v files in the regen kit --
#   the Task 9 MODEL_TREE_SHA recipe -- so a stale kit can never be handed to
#   Vivado.  It does not exist until `hdl` has run, so it is computed LAZILY from
#   the tree on disk, and env MODEL_TREE_SHA overrides it (that override is what
#   makes --dry and the shell tests runnable without a 1 h regen).
#
#   GATE 2 (spec Gate 2, controller ruling 8).  The post-route modem-clock WNS
#   must be >= 0.005 ns.  Reference points printed beside it: the rxfixpad
#   netlist-fix image 0.105, sp2A 0.447, sp2B 0.785.  BELOW THE FLOOR IS A STOP,
#   not a tuning prompt: record it in docs/evidence/sp3/GATE2_TIMING.md and the
#   runtime select is dropped (sp2 stays shipped).  NOTE the number scored here
#   is NOT the `wns=` in the build's own TXFIX_BUILD_DONE line -- that is
#   timing_gate.tcl's PRE-IMPL estimate.  Gate 2 reads the fetched impl_1
#   timing summary, intra-clock post-route row, via modem_wns.py.
#
#   Terminal lines:
#     BUILD_IMAGE_WNS_OK wns=<f> floor=0.005 ref_pad=0.105 ref_sp2A=0.447 ref_sp2B=0.785
#     BUILD_IMAGE_DONE tag=<t> image=<path> md5=<32hex> modem_wns=<f>
#     BUILD_IMAGE_DRY tag=<t>
#     BUILD_IMAGE_NO_ROLE / BUILD_IMAGE_STAGE_MERGED / BUILD_IMAGE_BAD_RANGE (exit 2)
#     BUILD_IMAGE_NEED_STAGE <s> / BUILD_IMAGE_GATE2_FAIL / BUILD_IMAGE_VIVADO_FAIL
#
#   The vivado stage is LONG (~2 h 15 on hdl-dev-2 at IMPL_STRATEGY=explore) and
#   so is hdl (~1 h).  Launch detached, e.g.
#     systemd-run --user --collect --same-dir --unit sp3-build-$(date +%s) \
#       bash -c 'modem/build_image.sh --tag sp3 --remote-base /mnt/disk2/scratch/qpsk-builds > <work>/build.out 2>&1'
# =============================================================================
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
GATESDIR="$HERE/gates"

TAG=sp4
TREE=dev                                          # dev = overlay-driven source (assemble); prod = flattened model (load)
WORK=/mnt/onetb/scratch/qpsk-build-trees/work_sp3
REGEN_PARENT=/mnt/onetb/scratch/qpsk-build-trees/regen11
FROM=hdl
STOP=vivado
DRY=""
RBASE=""
# The ONE hard-coded remote root in this script: relative, so ssh/rsync resolve
# it against the remote HOME exactly as before --remote-base existed.
RB_DEFAULT=qpsk-builds
CONCURRENT=0
ONEWAY=""
STAGES=(hdl gates vivado)
# Recognised, rejected: see "WHY THERE IS NO `seqbist` STAGE" above.
MERGED_STAGES=(seqbist)

while [ $# -gt 0 ]; do
  case $1 in
    --tag)         TAG=$2; shift 2 ;;
    --tree)        TREE=$2; shift 2 ;;
    --work)        WORK=$2; shift 2 ;;
    --regen-parent) REGEN_PARENT=$2; shift 2 ;;
    --from)        FROM=$2; shift 2 ;;
    --stop-after)  STOP=$2; shift 2 ;;
    --remote-base) RBASE=$2; shift 2 ;;
    --concurrent)  CONCURRENT=1; shift ;;
    --dry)         DRY=--dry; shift ;;
    --oneway)
      # ONE-DIRECTIONAL test images (modem/dev/simulink/oneway_overlay.m): tx = TX-only
      # (Receiver stubbed), rx = RX-only (Transmitter stubbed). Forwarded to the
      # hdl stage as QPSK_ONEWAY. Gate 1 is an INTERNAL-LOOPBACK matrix and
      # cannot run on a half image; the gates stage records SKIPPED-ONEWAY and
      # requires the pair-simulation stamp (sim_oneway_pair_gate.m) instead.
      ONEWAY=$2; shift 2
      case "$ONEWAY" in tx|rx) ;; *) echo "build_image.sh: --oneway takes tx|rx (got '$ONEWAY')"; exit 2 ;; esac ;;
    --role)
      # sp2 built role A (148: W1 R4B BS PAD) and role B (146: W1 R4D R1) from
      # two fix sets. sp3 is ONE image carrying all of them, so a --role here is
      # not a stale flag to ignore -- it means the caller still believes in two
      # images and would otherwise get the wrong one silently.
      echo "BUILD_IMAGE_NO_ROLE --role is gone: sp3 builds ONE image from the model overlays (W1 R4B R4D+R1 BS PAD F3) for both boards. Drop --role; use --tag to name the build."
      exit 2 ;;
    -h|--help)     sed -n '2,/^[^#]/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "build_image.sh: bad arg $1"; exit 2 ;;
  esac
done

case "$TAG" in
  sp3*|sp4*) ;;
  *) echo "build_image.sh: --tag must begin with 'sp3' or 'sp4' (the kit is jupiter_byte_<tag>_build and modem/vivado/txfix_build.sh.tmpl's guard accepts jupiter_byte_sp3*_build / jupiter_byte_sp4*_build); got '$TAG'"; exit 2 ;;
esac
# Refuse here as well as in build_txfix.sh: this value also drives the rsync
# FETCH paths below, where a relative value would resolve against the remote
# HOME and quietly fetch nothing (or the wrong tree).
case "$RBASE" in "" | /*) ;; *) echo "build_image.sh: --remote-base must be an absolute path (got '$RBASE')"; exit 2 ;; esac

in_stages() { local s; for s in "${STAGES[@]}"; do [ "$s" = "$1" ] && return 0; done; return 1; }
is_merged() { local s; for s in "${MERGED_STAGES[@]}"; do [ "$s" = "$1" ] && return 0; done; return 1; }
check_stage() {
  in_stages "$1" && return 0
  if is_merged "$1"; then
    echo "BUILD_IMAGE_STAGE_MERGED '$1' is not a stage: SEQ-BIST is a block-design instrument and its Tcl (modem/instruments/seqbist/seqbist_bd.tcl) is sourced inside the hdl stage, in the same Vivado session as complete_byte_bd.tcl and ddrcap_bd.tcl. Stages are: ${STAGES[*]}"
    exit 2
  fi
  echo "build_image.sh: --$2 '$1' is not one of: ${STAGES[*]}"; exit 2
}
check_stage "$FROM" from
check_stage "$STOP" stop-after
# --stop-after must not be strictly EARLIER than --from in stage order -- equal is
# fine (a one-stage run), later is fine, but e.g. --from gates --stop-after hdl
# would silently run nothing (the for-loop below never sets run=1).
stage_index() { local i s; for i in "${!STAGES[@]}"; do s=${STAGES[$i]}; [ "$s" = "$1" ] && { echo "$i"; return 0; }; done; }
FROM_IDX=$(stage_index "$FROM"); STOP_IDX=$(stage_index "$STOP")
if [ "$STOP_IDX" -lt "$FROM_IDX" ]; then
  echo "BUILD_IMAGE_BAD_RANGE --stop-after '$STOP' is earlier than --from '$FROM' in stage order (${STAGES[*]}) -- would run nothing"
  exit 2
fi

KIT="$REGEN_PARENT/jupiter_byte_${TAG}_build"
HOST=${VIVADO_HOST:-hdl-dev-2}
CLK=${TIMING_CLOCK:-axi_adrv9001_adc_1_clk}
GIT=$(git -C "$ROOT" rev-parse --short HEAD)
# Gate 2 floor and its reference points (spec Gate 2 / ruling 8).
WNS_FLOOR=0.005
REF_PAD=0.105
REF_SP2A=0.447
REF_SP2B=0.785

mkdir -p "$WORK"

# model_tree_sha -- sha256 over the SORTED list of generated .v in the regen kit
# (Task 9's MODEL_TREE_SHA recipe), computed lazily because it does not exist
# until hdl has run. `MODEL_TREE_SHA=<v>` in the environment wins, which is how
# the shell tests and a --dry preview exercise the stamp chain without a regen.
model_tree_sha() {
  if [ -n "${MODEL_TREE_SHA:-}" ]; then echo "${MODEL_TREE_SHA:0:16}"; return 0; fi
  local hs="$KIT/hdl_prj_jupiter_composite/hdlsrc/commhdlQPSKTxRxLoopback"
  if [ ! -d "$hs" ]; then echo "NO-TREE"; return 0; fi
  ( cd "$hs" && find . -name '*.v' -print0 | sort -z | xargs -0 sha256sum ) \
    | sha256sum | cut -c1-16
}

stamp() {
  printf 'stage=%s tag=%s model_tree_sha=%s git=%s when=%s result=%s\n' \
    "$1" "$TAG" "$(model_tree_sha)" "$GIT" "$(date -Is)" "$2" > "$WORK/STAMP.$1"
}
need() {
  local msha; msha=$(model_tree_sha)
  if [ -f "$WORK/STAMP.$1" ] && grep -q "model_tree_sha=$msha" "$WORK/STAMP.$1"; then return 0; fi
  echo "BUILD_IMAGE_NEED_STAGE $1 (no <work>/STAMP.$1 at model_tree_sha=$msha -- run --from $1 or earlier)"
  exit 1
}

run=0
for s in "${STAGES[@]}"; do
  if [ "$s" = "$FROM" ]; then run=1; fi
  [ $run = 1 ] || continue
  echo "== stage $s (tag $TAG, kit $(basename "$KIT"), git $GIT, work $WORK)"
  case $s in

    hdl)
      if [ -n "$DRY" ]; then
        echo "BUILD_IMAGE_DRY_HDL would run: $HERE/build_hdl.sh $REGEN_PARENT --tree $TREE --kit-name $(basename "$KIT") --complete-bd"
        stamp hdl.dry "dry"
        echo "BUILD_IMAGE_DRY tag=$TAG"
        exit 0
      fi
      QPSK_ONEWAY="$ONEWAY" "$HERE/build_hdl.sh" "$REGEN_PARENT" --tree "$TREE" --kit-name "$(basename "$KIT")" --complete-bd 2>&1 | tee "$WORK/hdl.log"
      # Three hard post-checks, each a line build_hdl.sh prints exactly once.
      for tok in BUILD_HDL_BD_OK BUILD_HDL_KIT_OK MODEL_OVERLAYS_OK; do
        grep -q "^$tok" "$WORK/hdl.log" \
          || { echo "BUILD_IMAGE_HDL_FAIL no $tok in $WORK/hdl.log"; exit 1; }
      done
      stamp hdl "$(grep '^BUILD_HDL_BD_OK' "$WORK/hdl.log" | tail -1)"
      ;;

    gates)
      # --dry means "touch nothing that takes hours or reaches another machine".
      # It was honoured by hdl and vivado but silently IGNORED here, so a --dry
      # run over the default range started the full multi-hour leg sweep for
      # real -- the opposite of what the flag promises. The preview comes FIRST,
      # above `need hdl`: printing what WOULD run needs no prerequisites, and a
      # dry preview that dies on a missing stamp is not a preview. Unlike hdl
      # and vivado this does NOT exit -- gates sits in the middle of the range,
      # so a dry full run must still fall through to the vivado preview. No
      # STAMP.gates is written either way: a dry run has no GATES_DONE to
      # record, and the vivado stage's "building UNGATED" warning must still
      # fire behind it.
      if [ -n "$DRY" ]; then
        echo "BUILD_IMAGE_DRY_GATES would run: $ROOT/modem/rtl_sim/make_sro_trees.sh --from-regen $KIT ; modem/rtl_sim/tree_marker.sh <tree> {W1,R4B,R4DR1,BS,PAD,F3} ; $GATESDIR/run_gates.sh --legs $GATESDIR/model_matrix.legs"
      elif [ -n "$ONEWAY" ]; then
      need hdl
      # Half image: the SRO matrix is TX -> internal loopback -> RX inside ONE
      # composite, which a one-way image cannot do. The model-level proof is
      # the TX-only -> RX-only PAIR simulation; its stamp must be fresh (this
      # calendar day) and PASS.
      PAIR_STAMP=/mnt/onetb/scratch/qpsk-build-trees/oneway/jupiter_byte_onewaytx_build/SIM_ONEWAY_PAIR_GATE.txt
      [ -f "$PAIR_STAMP" ] || { echo "BUILD_IMAGE_GATES_FAIL oneway: no pair-sim stamp $PAIR_STAMP (run modem/dev/simgate/run_oneway_pair_gate.sh)"; exit 1; }
      grep -q '^result: PASS' "$PAIR_STAMP" || { echo "BUILD_IMAGE_GATES_FAIL oneway: pair-sim stamp is not PASS"; exit 1; }
      [ "$(date -r "$PAIR_STAMP" +%F)" = "$(date +%F)" ] || echo "BUILD_IMAGE_GATES_WARN oneway: pair-sim stamp dated $(date -r "$PAIR_STAMP" +%F) (not today)"
      echo "BUILD_IMAGE_GATES_SKIPPED_ONEWAY mode=$ONEWAY pair_sim=$(grep -m1 "^link" "$PAIR_STAMP" | cut -c1-160)"
      stamp gates "SKIPPED-ONEWAY mode=$ONEWAY pair_sim=$(grep -m1 "^result" "$PAIR_STAMP") $(grep -m1 "^link" "$PAIR_STAMP" | cut -c1-160)"
      else
      need hdl
      # THE GATES STAGE IS NOT RE-ENTRANT ACROSS PROCESSES, and the failure is
      # SILENT. make_sro_trees.sh --from-regen writes ONE fixed path
      # (modem/rtl_sim/s1_rtl_model) and run_gates.sh builds ONE fixed set of
      # Verilator object directories (modem/rtl_sim/obj_byte_*_model_*).
      # SP2_WORK separates the per-leg WORK dirs and neither of those. Measured
      # 2026-09-12: this stage overwrote s1_rtl_model out from under a
      # concurrent run of the SAME table, and both runs then scored binaries
      # built from the other run's tree -- a green that means nothing. Refuse to
      # start rather than produce one.
      BUSY=$(systemctl --user list-units --state=running,active 'sp2-gate-*' --no-legend 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
      BUSY=${BUSY% }
      if [ -n "$BUSY" ]; then
        echo "BUILD_IMAGE_GATES_BUSY sim-gate unit(s) already running: $BUSY"
        echo "  The gates stage shares modem/rtl_sim/s1_rtl_model and the obj_byte_*_model_* directories with every other"
        echo "  run on this host; starting now would overwrite that tree and score the other run's binaries."
        echo "  Wait for those units to finish, or stop them, then re-run --from gates."
        exit 2
      fi
      # make_sro_trees.sh --from-regen builds the MODEL gate tree (s1_rtl_model)
      # and its wrappers out of the regen kit's hdlsrc; it takes no variant list.
      "$ROOT/modem/rtl_sim/make_sro_trees.sh" --from-regen "$KIT" 2>&1 | tee "$WORK/gates_trees.log"
      grep -q '^MAKE_SRO_FROM_REGEN_DONE' "$WORK/gates_trees.log" \
        || { echo "BUILD_IMAGE_GATES_FAIL no MAKE_SRO_FROM_REGEN_DONE"; exit 1; }
      MODELTREE=$(sed -n 's/^MAKE_SRO_FROM_REGEN_DONE //p' "$WORK/gates_trees.log" | tail -1)
      # The plan's post-check: every fix must read `model` (not `injector`) on
      # the tree the gates will actually run against.
      TM_FAIL=""
      for v in W1 R4B R4DR1 BS PAD F3; do
        line=$("$ROOT/modem/rtl_sim/tree_marker.sh" "$MODELTREE" "$v" 2>&1) || TM_FAIL="$TM_FAIL $v"
        echo "  $line"
        case "$line" in *" $v model") ;; *) TM_FAIL="$TM_FAIL $v" ;; esac
      done
      if [ -n "$TM_FAIL" ]; then
        echo "BUILD_IMAGE_TREE_MARKER_FAIL not 'model' for:$TM_FAIL (tree $MODELTREE)"; exit 1
      fi
      echo "BUILD_IMAGE_TREE_MARKER_OK W1 R4B R4DR1 BS PAD F3 all model ($MODELTREE)"
      # the rung this kit was regenerated at (build_hdl.sh exports QPSK_FRAME; default f3072 = r4)
      case "${QPSK_FRAME:-f3072}" in f1536) G_RUNG=r3; LEGS="$GATESDIR/model_matrix_f1536.legs" ;; *) G_RUNG=r4; LEGS="$GATESDIR/model_matrix.legs" ;; esac
      echo "BUILD_IMAGE_GATES_RUNG $G_RUNG legs=$(basename "$LEGS") (QPSK_FRAME=${QPSK_FRAME:-f3072})"
      # the six gate objects compile rtl_sim/geometry.h: render the rung's twins BEFORE they build;
      # run_gates.sh --rung renders again (idempotent) and restores the r4 pair when it exits
      python3 "$ROOT/modem/rtl_sim/geometry_gen.py" --rung "$G_RUNG" | tail -1
      if [ ! -f "$LEGS" ]; then
        # Task 9 owns this table (the Gate 1 equivalence matrix). Name the
        # missing dependency rather than silently substituting another table:
        # reference_matrix.legs scores the INJECTED references, a different
        # subject, and passing it here would look like a green Gate 1.
        echo "BUILD_IMAGE_NO_MODEL_MATRIX $LEGS not present (Task 9 delivers it) -- gates stage cannot run"
        exit 1
      fi
      # 2026-09-15: COMPILE THE TREE.  The matrix runs six Verilator binaries out of
      # modem/rtl_sim/obj_byte_*_model_*; until now nothing in this stage built
      # them, so they were whatever a previous hand-run had left (the last
      # ones dated 2026-09-12) and Gate 1 never actually simulated the
      # regenerated RTL.  Build all six from the model tree just written.
      echo "=== gates: build the six Verilator objects from $MODELTREE ==="
      OBJSTART="$WORK/gates_objs.start"; : > "$OBJSTART"
      OBJ_FAIL=""
      while read -r fix script arg obj top; do
        if [ "$arg" = - ]; then arg=""; fi
        ( cd "$ROOT/modem/rtl_sim" && TREE="$MODELTREE" FIXCTL="$fix" bash "./$script" $arg ) > "$WORK/gates_obj_${obj}.log" 2>&1 || true
        if [ ! -f "$ROOT/modem/rtl_sim/$obj/$top" ] || [ ! "$ROOT/modem/rtl_sim/$obj/$top" -nt "$OBJSTART" ]; then
          OBJ_FAIL="$OBJ_FAIL $obj"; tail -5 "$WORK/gates_obj_${obj}.log"
        else
          echo "GATES_OBJ_OK $obj/$top"
        fi
      done <<'OBJS'
0 build_sro_rxfix4b.sh - obj_byte_sro_rxfix4b_model_0 Vwrap_byte_sro_model
20 build_sro_rxfix4dr1.sh - obj_byte_sro_rxfix4dr1_model_20 Vwrap_byte_sro_model
0 build_sro_w1.sh w1 obj_byte_w1_w1_model_0 Vwrap_byte_w1_model
0 build_sro_w1.sh base obj_byte_w1_base_model_0 Vwrap_byte_w1_model
0 build_sro_bs.sh - obj_byte_sro_bs_model_0 Vwrap_byte_sro_model
0 build_sro_pad.sh - obj_byte_sro_pad_model_0 Vwrap_byte_sro_model
OBJS
      [ -z "$OBJ_FAIL" ] || { echo "BUILD_IMAGE_GATES_OBJ_FAIL not rebuilt from the tree:$OBJ_FAIL (see $WORK/gates_obj_*.log)"; exit 1; }
      # leg reuse is keyed on the kit's model_tree_sha (see run_gates.sh): a new
      # tree re-runs every leg; the same tree re-uses its own passes
      # GATES_JOBS=N runs up to N legs at once (run_gates.sh --jobs); default 1 = serial (~10 h)
      GATES_TREE_SHA="$(model_tree_sha)" "$GATESDIR/run_gates.sh" --rung "$G_RUNG" --legs "$LEGS" --jobs "${GATES_JOBS:-1}" 2>&1 | tee "$WORK/gates.log"
      [ "$G_RUNG" = r4 ] || python3 "$ROOT/modem/rtl_sim/geometry_gen.py" --rung r4 >/dev/null   # the committed render is r4
      grep -q 'GATES_DONE .* fail=0' "$WORK/gates.log" \
        || { echo "BUILD_IMAGE_GATES_FAIL see $WORK/gates.log"; exit 1; }
      stamp gates "$(grep GATES_DONE "$WORK/gates.log")"
      fi
      ;;

    vivado)
      # `need hdl` is skipped under --dry for the same reason as in the gates
      # stage: a preview of the launch command has no prerequisites, and
      # `--from vivado --dry` is exactly the command you run to inspect a rig
      # you have not built on yet.
      [ -n "$DRY" ] || need hdl
      if [ -f "$WORK/STAMP.gates" ] && grep -q "model_tree_sha=$(model_tree_sha)" "$WORK/STAMP.gates"; then :; else
        echo "BUILD_IMAGE_WARN gates stage not stamped at this model_tree_sha -- building UNGATED (explicit --from vivado)"
      fi
      [ -x "$KIT/build_txfix.sh" ] || [ -f "$KIT/build_txfix.sh" ] \
        || { echo "BUILD_IMAGE_NO_KIT $KIT/build_txfix.sh (run --from hdl)"; exit 1; }
      SHIMPATH="$PATH"
      if [ -n "$DRY" ]; then
        SHIM=$(mktemp -d); trap 'rm -rf "$SHIM"' EXIT
        printf '#!/bin/sh\nexec %s -n "$@"\n' "$(command -v rsync)" > "$SHIM/rsync"
        chmod +x "$SHIM/rsync"; SHIMPATH="$SHIM:$PATH"
        echo "BUILD_IMAGE_DRY_SHIM rsync forced to -n via $SHIM (build_txfix.sh rsyncs --delete BEFORE its own --dry gate)"
      fi
      # build_txfix.sh refuses to launch while another txfix/ddrcap unit is active
      # on the host unless ALLOW_CONCURRENT=1. That refusal is the default ON PURPOSE
      # (hdl-dev-2 is 8 cores); two builds at once is a deliberate act, so it needs
      # the explicit --concurrent flag and should be paired with a reduced JOBS.
      ( cd "$KIT" && PATH="$SHIMPATH" IMPL_STRATEGY=explore \
          REMOTE_BASE="$RBASE" \
          ALLOW_CONCURRENT="$CONCURRENT" bash ./build_txfix.sh $DRY ) 2>&1 | tee "$WORK/vivado_launch.log"
      if [ -n "$DRY" ]; then
        stamp vivado.dry "dry"          # NOT STAMP.vivado: a real build must not inherit a dry stamp
        echo "BUILD_IMAGE_DRY tag=$TAG"
        exit 0
      fi
      # Anchor on the template's OWN launch line, not on any txfix-build-* token:
      # under ALLOW_CONCURRENT=1 the preflight prints a NOTE naming SOMEONE ELSE'S
      # unit first, so `grep -o ... | head -1` would wait on the wrong build.
      UNIT=$(sed -n 's/^TXFIX_BUILD launched on .* as unit \([A-Za-z0-9_.@-]\{1,\}\) ;.*/\1/p' \
               "$WORK/vivado_launch.log" | tail -1)
      [ -n "$UNIT" ] || { echo "BUILD_IMAGE_VIVADO_FAIL no unit name in $WORK/vivado_launch.log"; exit 1; }
      echo "BUILD_IMAGE unit=$UNIT"
      # THE single root for all three fetches below (log, boot/BOOT.BIN, impl_1
      # reports).  Empty --remote-base keeps the historical RELATIVE path, which
      # ssh/rsync resolve against the remote HOME -- byte-identical behaviour.
      REMOTE="${RBASE:-$RB_DEFAULT}/$(basename "$KIT")"
      echo "BUILD_IMAGE waiting on $HOST unit $UNIT (poll 60 s, cap 4 h)"
      # `is-active --quiet` is non-zero for `activating` AND for any ssh hiccup, so a
      # bare `|| break` can leave the wait on its first poll and rsync a BOOT.BIN that
      # is still two hours away. Require the unit to have been SEEN active once, and
      # require two consecutive non-active polls before calling it finished.
      seen=0; gone=0
      for _ in $(seq 1 240); do
        sleep 60
        if ssh -o ConnectTimeout=20 "$HOST" systemctl --user is-active --quiet "$UNIT"; then
          seen=1; gone=0
        else
          gone=$((gone + 1))
          if [ $seen = 1 ] && [ $gone -ge 2 ]; then break; fi
          if [ $seen = 0 ] && [ $gone -ge 5 ]; then echo "BUILD_IMAGE_VIVADO_FAIL unit $UNIT never became active on $HOST"; exit 1; fi
        fi
      done
      # build_txfix.tcl `cd boot` before bootgen, so BOOT.BIN is in vivado_ip_prj/boot/.
      Z="$REMOTE/hdl_prj_jupiter_composite/vivado_ip_prj"
      rsync -a "$HOST:$REMOTE/build_txfix_vivado.log" "$WORK/"
      rsync -a "$HOST:$Z/boot/BOOT.BIN" "$WORK/BOOT.BIN.$TAG"
      rsync -a --include '*timing_summary*.rpt' --include '*timing_paths_modem*.rpt' --include '*/' --exclude '*' \
        "$HOST:$Z/vivado_prj.runs/impl_1/" "$WORK/impl1_reports_$TAG/"
      # Check the build's own DONE marker FIRST: a failed impl has no usable timing
      # report, and a missing-clock-row WNS error would hide the real cause.
      grep -q "TXFIX_BUILD_DONE" "$WORK/build_txfix_vivado.log" \
        || { echo "BUILD_IMAGE_VIVADO_FAIL no TXFIX_BUILD_DONE"; tail -20 "$WORK/build_txfix_vivado.log"; exit 1; }
      # GATE 2. modem_wns.py --min enforces the floor itself (non-zero exit), so
      # the `|| { ... }` is what turns that into the spec's STOP token. This is
      # the POST-ROUTE intra-clock row for $CLK, not the pre-impl estimate in the
      # build log's own TXFIX_BUILD_DONE wns= field.
      set +e
      WNSLINE=$(python3 "$GATESDIR/modem_wns.py" "$WORK/impl1_reports_$TAG" --clock "$CLK" --min "$WNS_FLOOR")
      WNSRC=$?
      set -e
      echo "$WNSLINE"
      WNS=$(echo "$WNSLINE" | sed -n 's/.*wns=\([-0-9.]*\).*/\1/p')
      if [ $WNSRC -ne 0 ]; then
        echo "BUILD_IMAGE_GATE2_FAIL wns=${WNS:-?} floor=$WNS_FLOOR ref_pad=$REF_PAD ref_sp2A=$REF_SP2A ref_sp2B=$REF_SP2B -- spec Gate 2 is a STOP: record it in docs/evidence/sp3/GATE2_TIMING.md, do not re-run with a different strategy"
        exit 1
      fi
      echo "BUILD_IMAGE_WNS_OK wns=$WNS floor=$WNS_FLOOR ref_pad=$REF_PAD ref_sp2A=$REF_SP2A ref_sp2B=$REF_SP2B"
      # sp4 Task 8: the symbol-rate blocks' worst endpoints (informational rows; the gate above is the verdict)
      python3 "$GATESDIR/modem_wns.py" "$WORK/impl1_reports_$TAG" --paths || echo "BUILD_IMAGE_PATHS_UNAVAILABLE (no timing_paths_modem report fetched)"
      MD5=$(md5sum "$WORK/BOOT.BIN.$TAG" | cut -d' ' -f1)
      OUT="$WORK/BOOT.BIN.jupiter.$TAG.${MD5:0:12}"
      cp "$WORK/BOOT.BIN.$TAG" "$OUT"
      stamp vivado "md5=$MD5 modem_wns=$WNS remote_base=${RBASE:-~/$RB_DEFAULT}"
      echo "BUILD_IMAGE_DONE tag=$TAG image=$OUT md5=$MD5 modem_wns=$WNS"
      ;;
  esac
  if [ "$s" = "$STOP" ]; then break; fi
done
