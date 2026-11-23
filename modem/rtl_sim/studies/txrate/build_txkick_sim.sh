#!/bin/bash
# build_txkick_sim.sh -- build the TX kick/force harness against a netlist tree, the
# same --public-flat-rw recipe used for obj_kick/Vkick (KICK_EXPERIMENT_BRIEF.md,
# tag archive/pre-cleanup-2026-09-09
# step 2). Host-only, no board.
#
# Env params (TXFIX T0a; defaults reproduce the pre-2026-09-03 behaviour exactly):
#   TREE     netlist tree           (default s1_rtl_txmark)
#   OBJ      Verilator -Mdir        (default obj_txkick)
#   HARNESS  harness source         (default sim_burst_force_tx.cpp)
# A txfix variant tree MUST be built with sim_txfix_force.cpp (the readback and
# latchforce controls the gate depends on live there), enforced below.
#
# sp3 task 2 (model-backport): wrap_byte_ddrcap.v already declares a top-level
# `fixctl` port wired straight to TxRxComposite.fixctl (runtime-driven by the
# harness, not a Verilator parameter) -- so no *_model wrapper or FIXCTL_INIT is
# needed here. The one gap for a model tree is layout: TREE is normally a full
# HDL-Coder project (TREE/hdlsrc/commhdlQPSKTxRxLoopback/*.v) but
# make_sro_trees.sh --from-regen writes a FLAT tree (TREE/*.v, matching the
# build_sro_*.sh convention). Accept either shape.
set -e
cd "$(dirname "$0")"

TREE="${TREE:-s1_rtl_txmark}"
OBJ="${OBJ:-obj_txkick}"
HARNESS="${HARNESS:-sim_burst_force_tx.cpp}"

if [ -d "$TREE/hdlsrc/commhdlQPSKTxRxLoopback" ]; then
  SRCDIR="$TREE/hdlsrc/commhdlQPSKTxRxLoopback"
elif ls "$TREE"/*.v >/dev/null 2>&1; then
  SRCDIR="$TREE"
else
  echo "TXKICK_BUILD_FAIL: no tree $TREE"; exit 2
fi
[ -f "$HARNESS" ] || { echo "TXKICK_BUILD_FAIL: no harness $HARNESS"; exit 2; }
case "$TREE" in
  # sp3 task 8: the model tree carrying the F1+F2+F3 overlay
  # (modem/rxfix/txfix_f3_overlay.m) is gated by the SAME matrix as the injected
  # txfix trees, so it needs the same harness -- and its name does not match the
  # s1_rtl_txfix_* pattern below, so without this arm it would silently build
  # against the default sim_burst_force_tx.cpp and every gate row would score
  # against a harness with no readback/latchforce controls.
  # The `*` after s1_rtl_model_tx also catches s1_rtl_model_tx_u, the MODEL-LINEAGE
  # UNFIXED baseline tree (sp3 task 8 fix round 2: same receiver, stock transmitter,
  # built with QPSK_TXFIX empty). It runs the G0/G1 baseline rows the four RX-capture
  # rows compare against, so it needs the same harness -- without this arm it builds
  # against sim_burst_force_tx.cpp and the baseline is scored from a harness with no
  # readback/latchforce controls.
  s1_rtl_model_tx*|*/s1_rtl_model_tx*|s1_rtl_txfix_*)
    [ "$HARNESS" = "sim_txfix_force.cpp" ] || {
      echo "TXKICK_BUILD_FAIL: TREE=$TREE requires HARNESS=sim_txfix_force.cpp (got $HARNESS)"; exit 2; }
  ;;
esac

echo "TXKICK_BUILD TREE=$TREE OBJ=$OBJ HARNESS=$HARNESS SRCDIR=$SRCDIR"
rm -rf "$OBJ"
verilator -O2 -Wno-fatal --cc --exe --build --public-flat-rw --top-module wrap_byte_ddrcap \
  -y "$SRCDIR" -y . \
  wrap_byte_ddrcap.v "$HARNESS" \
  -Mdir "$OBJ" -o Vtxkick
echo "TXKICK_BUILD_EXIT $?"
