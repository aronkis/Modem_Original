#!/bin/bash
# make_kit.sh <dev|prod> <dest_kit_dir> [--with-tools] -- assemble a scratch KIT from a tree.
#
# The repo carries every shared file ONCE, as a real file (no symlinks): modem/common/
# {bd,model,rxfifo,tools} plus modem/{gates,instruments,vivado,rtl_sim}. A kit is the
# flat, self-contained copy the build, the gates and the derivation run in (cwd = kit
# root; Tcl finds its siblings in <kit>/bd via [info script]; MATLAB reaches <kit>/model
# and the stage folders via kitpath). This script is the ONE place that knows the shape:
#
#   <dest>/                       modem/<tree>/ (its own files: models, entry scripts, stage folders)
#   <dest>/bd  model  rxfifo  tools   modem/common/*
#   <dest>/kitpath.m, kit_contract_dir.m   copies of model/kitpath.m + helper (MATLAB bootstrap at cwd)
#   <dest>/gates  instruments  vivado  rtl_sim   modem/* (rtl_sim minus obj_* and s1_rtl*)
#   <dest>/simgate/gen_byte_vectors_k5.m, hdlsim/s1_analyze_240k5.m, hdlsim/s1b_analyze_byte.m
#                                 (prod only: the frame-generic analysers prod does not re-derive)
#   <dest>/../contract/           a copy of the repo's contract/ (the K5 overlays read it as
#                                 the kit's SIBLING; see kit_contract_dir.m)
#
# --with-tools additionally copies prod's derive/ and edit/ (the derivation and the
# edit kit need them; the image build does not). Excludes the generated/log material
# every copy site used to exclude by hand. Idempotent: <dest> is wiped first.
set -u
TREE=${1:?dev|prod}; DEST=${2:?dest kit dir}; WITH_TOOLS=0; [ "${3:-}" = --with-tools ] && WITH_TOOLS=1
case "$TREE" in dev|prod) ;; *) echo "make_kit: tree must be dev|prod (got $TREE)"; exit 2 ;; esac
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
M="$REPO/modem"
EX=(--exclude 'hdl_prj_*' --exclude 'slprj' --exclude '*.log' --exclude '*.out' --exclude '*.slxc' --exclude '__pycache__' --exclude '.pytest_cache')
rm -rf "$DEST"; mkdir -p "$DEST"
if [ "$WITH_TOOLS" = 1 ]; then TEX=(); else TEX=(--exclude 'derive' --exclude 'edit'); fi
rsync -a "${EX[@]}" "${TEX[@]}" "$M/$TREE/" "$DEST/" || { echo "MAKE_KIT_FAIL tree copy"; exit 1; }
for d in bd model rxfifo tools; do
  rsync -a "${EX[@]}" "$M/common/$d/" "$DEST/$d/" || { echo "MAKE_KIT_FAIL common/$d"; exit 1; }
done
# the MATLAB bootstrap: every entry script starts with `cd(KITDIR); kitpath(KITDIR)` before any
# path exists, so kitpath.m (and its helper) must sit at the kit ROOT as well (a copy, not a link)
cp -f "$DEST/model/kitpath.m" "$DEST/model/kit_contract_dir.m" "$DEST/" || { echo "MAKE_KIT_FAIL kitpath bootstrap"; exit 1; }
for d in gates instruments vivado; do
  rsync -a "${EX[@]}" "$M/$d/" "$DEST/$d/" || { echo "MAKE_KIT_FAIL $d"; exit 1; }
done
rsync -a "${EX[@]}" --exclude 'obj_*' --exclude 's1_rtl*' --exclude 'studies' --exclude 'evidence' --exclude 'tap_replay_study' \
  --exclude 'beat_runs' --exclude 'golden_taps' --exclude 'replay' --exclude 'txplane_runs' \
  "$M/rtl_sim/" "$DEST/rtl_sim/" || { echo "MAKE_KIT_FAIL rtl_sim"; exit 1; }
if [ "$TREE" = prod ]; then
  mkdir -p "$DEST/simgate" "$DEST/hdlsim"
  cp -f "$M/dev/simgate/gen_byte_vectors_k5.m" "$DEST/simgate/" || exit 1
  cp -f "$M/dev/hdlsim/s1_analyze_240k5.m" "$M/dev/hdlsim/s1b_analyze_byte.m" "$DEST/hdlsim/" || exit 1
  if [ -d "$DEST/hdlsim/rtl_sim_overrides" ]; then
    cp -f "$DEST"/hdlsim/rtl_sim_overrides/* "$DEST/rtl_sim/" || exit 1   # reg_ pin names for the netlist bench
  fi
fi
# the sibling contract/ (a COPY, not a link)
PARENT=$(cd "$DEST/.." && pwd)
if [ ! -d "$PARENT/contract" ] || [ ! -f "$PARENT/contract/rom_words_70_k5.txt" ]; then
  rsync -a "$REPO/contract/" "$PARENT/contract/" || { echo "MAKE_KIT_FAIL contract copy"; exit 1; }
fi
# every shipped .m carries the tree's absolute path in comments/defaults: repoint to the kit
find "$DEST" -maxdepth 3 -name '*.m' -type f -print0 | xargs -0 -r sed -i "s#$M/$TREE#$DEST#g"
for f in bd/complete_byte_bd.tcl bd/timing_gate.tcl model/frame_config_k5.m model/kitpath.m tools/tmr_attr_inject.sh \
         rxfifo/ByteRxFifo.v rtl_sim/wrap_byte.v rtl_sim/sim_byte.cpp gates/model_matrix.legs build_variant_byte.m hdlworkflow_loopback.m \
         simgate/gen_byte_vectors_k5.m hdlsim/s1b_analyze_byte.m; do
  [ -e "$DEST/$f" ] || { echo "MAKE_KIT_FAIL missing $f"; exit 1; }
done
[ -z "$(find "$DEST" -type l | head -1)" ] || { echo "MAKE_KIT_FAIL symlink inside the kit"; exit 1; }
echo "MAKE_KIT_OK tree=$TREE kit=$DEST contract=$PARENT/contract"
