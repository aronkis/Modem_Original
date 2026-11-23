#!/bin/bash
# make_edit_kit.sh -- set up a scratch kit for CLEANING UP the flat model.
#
# The kit is a copy of modem/ in which the flat reference model is installed
# under the name every gate binds to (commhdlQPSKTxRxLoopback.slx), plus:
#   flat_ref.slx            read-only snapshot of the model as installed (for flat_diff.m)
#   (the kit is a copy of modem/prod, whose gate scripts are already the flattened-model variants)
#   env.sh                  the production QPSK_* exports; `source` it before MATLAB
#   checkhdl_gate_240k5_byte.m  already the load-only variant (prod carries it)
#                           by load_system (gates the EDITED model, never rebuilds it)
#   sim_byte_gate_k5.m      patched so a stale-description check ERRORS instead of
#                           silently re-assembling over your edits
#   run_netlist_gates.sh    already skips the k5-only S1 stage at f1536
#   edit/*.m                the helper scripts, on the MATLAB path via the kit
#
# Usage:  modem/prod/edit/make_edit_kit.sh [dest_parent] [source_model.slx]
#   dest_parent    default /mnt/onetb/scratch/qpsk-build-trees/flat_edit
#   source_model   default modem/commhdlQPSKTxRxLoopback_flat.slx
# Refuses to overwrite an existing kit unless FORCE=1 (your edits live there).
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)   # <repo>/modem/prod/edit/
KIT="$REPO/modem/prod"                # the flattened-model tree (a kit root; shared files are symlinks)
DEST_PARENT=${1:-/mnt/onetb/scratch/qpsk-build-trees/flat_edit}
SRC_MODEL=${2:-$KIT/commhdlQPSKTxRxLoopback.slx}
FRESH="$DEST_PARENT/jupiter_byte_flatedit_build"

[ -f "$SRC_MODEL" ] || { echo "FATAL: source model not found: $SRC_MODEL"; exit 1; }
if [ -d "$FRESH" ] && [ "${FORCE:-0}" != "1" ]; then
  echo "REFUSING: $FRESH exists (it may hold your edits). FORCE=1 to recreate."; exit 2
fi

echo "=== [1/5] kit copy -> $FRESH ==="
MK_OUT=$(bash "$REPO/modem/common/tools/make_kit.sh" prod "$FRESH" --with-tools) || { echo "$MK_OUT"; echo "FATAL: make_kit failed"; exit 1; }
echo "$MK_OUT" | tail -1
echo "=== [2/5] KITDIR repoint (done by make_kit) ==="

echo "=== [3/5] install the flat model as the gate-bound name ==="
cp -f "$SRC_MODEL" "$FRESH/commhdlQPSKTxRxLoopback.slx"
cp -f "$SRC_MODEL" "$FRESH/flat_ref.slx"; chmod a-w "$FRESH/flat_ref.slx"
rm -f "$FRESH/commhdlQPSKTxRx.slx.bak" 2>/dev/null
md5sum "$FRESH/commhdlQPSKTxRxLoopback.slx" | cut -c1-12 > "$FRESH/FLAT_EDIT_ORIGIN"
echo "src=$SRC_MODEL git=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null) when=$(date -Is)" >> "$FRESH/FLAT_EDIT_ORIGIN"

echo "=== [4/5] gate scripts: prod already carries the flattened-model variants (patch_gates_for_flat.sh in derive.sh) ==="
bash "$FRESH/derive/patch_gates_for_flat.sh" "$FRESH" || exit 1   # idempotent; a no-op on a prod tree

echo "=== [5/5] env.sh ==="
cat > "$FRESH/env.sh" <<'EOF'
# source this before running MATLAB or any gate in the flat edit kit
export QPSK_LEAN=1 QPSK_FRAME=f1536 QPSK_SPS=4 QPSK_BEATFIX=1 QPSK_BEATOBS=1 QPSK_FRAMESTAT=1
export QPSK_RXFIX=1 QPSK_TXFIX=1
export PATH=/mnt/onetb/MATLAB/R2025b/bin:/usr/local/bin:/usr/bin:/bin
EOF
echo "FLAT_EDIT_KIT_OK $FRESH"
echo
echo "next:"
echo "  source $FRESH/env.sh && cd $FRESH && matlab   # open commhdlQPSKTxRxLoopback.slx and edit"
echo "  $REPO/modem/prod/edit/flat_gate.sh diff        # what changed vs flat_ref.slx (fast)"
echo "  $REPO/modem/prod/edit/flat_gate.sh sim         # model-level byte gate (inner loop)"
echo "  $REPO/modem/prod/edit/flat_gate.sh hdl         # checkhdl + makehdl + netlist gates (outer loop)"
