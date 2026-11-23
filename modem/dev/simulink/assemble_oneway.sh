#!/bin/bash
# assemble_oneway.sh tx|rx [dest_parent] -- assemble a ONE-WAY test model in a
# scratch kit: fresh copy of modem/dev (symlinks dereferenced), the production
# QPSK_* environment plus QPSK_ONEWAY=<mode>, then run_assemble_byte.m (paths +
# assemble only, no HDL Coder).  Leaves <kit>/commhdlQPSKTxRxLoopback.slx with the
# unused half stubbed (oneway_overlay.m).  Used to prove the overlay and by
# sim_oneway_pair_gate.m, which needs one kit per half.
#
#   modem/dev/simulink/assemble_oneway.sh tx                       -> .../oneway/jupiter_byte_onewaytx_build
#   modem/dev/simulink/assemble_oneway.sh rx /some/parent
set -u
MODE=${1:?tx|rx}
case "$MODE" in tx|rx) ;; *) echo "usage: $0 tx|rx [dest_parent]"; exit 2 ;; esac
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)   # <repo>/modem/dev/simulink/
DEV="$REPO/modem/dev"
DEST_PARENT=${2:-/mnt/onetb/scratch/qpsk-build-trees/oneway}
FRESH="$DEST_PARENT/jupiter_byte_oneway${MODE}_build"
MATLAB_BIN=/mnt/onetb/MATLAB/R2025b/bin
[ -x "$MATLAB_BIN/matlab" ] || { echo "FATAL: matlab not found at $MATLAB_BIN"; exit 1; }

# production image environment (build_hdl.sh) + the one-way knob
export QPSK_LEAN=1 QPSK_FRAME=f1536 QPSK_SPS=4 QPSK_BEATFIX=1 QPSK_BEATOBS=1 QPSK_FRAMESTAT=1
export QPSK_RXFIX=1 QPSK_TXFIX="${QPSK_TXFIX-1}"
export QPSK_ONEWAY="$MODE"

echo "=== [1/3] fresh kit copy of dev -> $FRESH (QPSK_ONEWAY=$MODE) ==="
MK_OUT=$(bash "$REPO/modem/common/tools/make_kit.sh" dev "$FRESH" --with-tools) || { echo "$MK_OUT"; echo "FATAL: make_kit failed"; exit 1; }
echo "$MK_OUT" | tail -1

echo "=== [2/3] MATLAB run_assemble_byte (assemble + oneway_overlay) ==="
T0=$(date +%s)
( cd "$FRESH" && timeout 3600 "$MATLAB_BIN/matlab" -batch "cd('$FRESH'); kitpath('$FRESH'); run('simulink/run_assemble_byte.m')" ) \
  > "$FRESH/assemble_oneway.log" 2>&1
MRC=$?; echo "matlab rc=$MRC elapsed=$(( $(date +%s) - T0 ))s"
grep -E "ONEWAY_OVERLAY_OK|ASSEMBLE_240K5_BYTE PRE-SYNTH GATES OK|GATE FAIL|Error" "$FRESH/assemble_oneway.log" | cut -c1-160
grep -q "ONEWAY_OVERLAY_OK mode=$MODE" "$FRESH/assemble_oneway.log" && grep -q "PRE-SYNTH GATES OK" "$FRESH/assemble_oneway.log" \
  || { echo "ASSEMBLE_ONEWAY_FAIL (see $FRESH/assemble_oneway.log)"; exit 1; }

echo "=== [3/3] kit ready ==="
echo "ASSEMBLE_ONEWAY_DONE mode=$MODE kit=$FRESH model=$FRESH/commhdlQPSKTxRxLoopback.slx"
