#!/bin/bash
# make_flat_model.sh -- build a readable, fully-overlaid reference copy of the
# DUT model (see make_flat_model.m) in a scratch kit, then bank the result as
#   modem/<OUT_NAME>.slx          (default commhdlQPSKTxRxLoopback_flat.slx)
#   modem/<OUT_NAME>_report.txt   (per-subsystem arrange results)
#
# Mirrors build_hdl.sh steps [1] (kit copy + sibling contract/) and [2] (KITDIR
# repoint) and exports the SAME production QPSK_* environment, so the flat model
# carries exactly the overlays the deployed image gets. No Vivado, no HDL Coder.
#
# Usage:  modem/make_flat_model.sh [dest_parent]      (default below)
#         QPSK_TXFIX= modem/make_flat_model.sh         -> no-TX-fix variant
# Long (~10-20 min of MATLAB): launch under systemd-run --user, e.g.
#   systemd-run --user --collect --same-dir --unit flat-model-$(date +%s) \
#     bash -c 'modem/make_flat_model.sh > /mnt/onetb/scratch/qpsk-build-trees/flat_model/run.out 2>&1'
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
KIT="$REPO/modem/dev"                 # the overlay-driven kit root (shared files are symlinks)
DEST_PARENT=${1:-/mnt/onetb/scratch/qpsk-build-trees/flat_model}
FRESH="$DEST_PARENT/jupiter_byte_flat_build"
OUT_NAME=${FLAT_OUT_NAME:-commhdlQPSKTxRxLoopback_flat}
MATLAB_BIN=/mnt/onetb/MATLAB/R2025b/bin
[ -x "$MATLAB_BIN/matlab" ] || { echo "FATAL: matlab not found at $MATLAB_BIN"; exit 1; }
[ -d /home/tcollins/dev/qpsk_ai/TransceiverToolbox ] || { echo "FATAL: TransceiverToolbox donor missing"; exit 1; }

# production image environment (build_hdl.sh:156-182)
export QPSK_LEAN=1 QPSK_FRAME=f1536 QPSK_SPS=4 QPSK_BEATFIX=1 QPSK_BEATOBS=1 QPSK_FRAMESTAT=1
export QPSK_RXFIX=1
export QPSK_TXFIX="${QPSK_TXFIX-1}"
export FLAT_OUT_NAME="$OUT_NAME"
export FLAT_GIT_SHA=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)

echo "=== [1/4] fresh kit copy -> $FRESH ==="
MK_OUT=$(bash "$REPO/modem/common/tools/make_kit.sh" dev "$FRESH" --with-tools) || { echo "$MK_OUT"; echo "FATAL: make_kit failed"; exit 1; }
echo "$MK_OUT" | tail -1
echo "=== [2/4] KITDIR repoint (done by make_kit) ==="
mkdir -p "$FRESH/derive" "$FRESH/edit" && rsync -a --exclude '*.slx' --exclude '*.png' --exclude '*_report.txt' "$REPO/modem/prod/derive/" "$FRESH/derive/" && rsync -a "$REPO/modem/prod/edit/" "$FRESH/edit/"
for f in "$FRESH"/derive/*.m "$FRESH"/edit/*.m; do [ -f "$f" ] && sed -i "s#$REPO/modem/prod#$FRESH#g" "$f"; done

echo "=== [3/4] MATLAB make_flat_model (env: QPSK_FRAME=$QPSK_FRAME QPSK_SPS=$QPSK_SPS QPSK_TXFIX='$QPSK_TXFIX') ==="
T0=$(date +%s)
( cd "$FRESH" && timeout 3600 "$MATLAB_BIN/matlab" -batch "cd('$FRESH'); kitpath('$FRESH'); make_flat_model" ) \
  > "$FRESH/make_flat_model.log" 2>&1
MRC=$?; echo "matlab rc=$MRC elapsed=$(( $(date +%s) - T0 ))s"
tail -5 "$FRESH/make_flat_model.log"
DONE=$(grep -m1 '^FLAT_MODEL_DONE' "$FRESH/make_flat_model.log" || true)
[ -n "$DONE" ] && [ -f "$FRESH/$OUT_NAME.slx" ] \
  || { echo "FLAT_MODEL_FAIL (see $FRESH/make_flat_model.log)"; exit 1; }

echo "=== [4/4] bank -> $REPO/modem/prod/derive/$OUT_NAME.slx (RAW flat model, pre-cleanup; derive.sh continues from here) ==="
cp -f "$FRESH/$OUT_NAME.slx" "$REPO/modem/prod/derive/$OUT_NAME.slx"
cp -f "$FRESH/flat_model_report.txt" "$REPO/modem/prod/derive/${OUT_NAME}_report.txt"
for p in "$FRESH"/flat_0*.png; do [ -f "$p" ] && cp -f "$p" "$REPO/modem/prod/derive/${OUT_NAME}_$(basename "$p")"; done
echo "$DONE"
echo "FLAT_MODEL_BANKED $REPO/modem/prod/derive/$OUT_NAME.slx"
