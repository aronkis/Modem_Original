#!/bin/bash
# derive.sh -- derive modem/prod from modem/dev.
#
#   modem/prod/derive/derive.sh [dest_parent]
#
# 1. fresh kit copy of modem/dev (symlinks dereferenced) + prod's derive/ and edit/ dirs
# 2. one MATLAB session: assemble every overlay, arrange, then the scripted
#    cleanup chain (derive_prod.m) -> the kit's commhdlQPSKTxRxLoopback.slx
# 3. gate scripts patched for a flattened model (patch_gates_for_flat.sh)
# 4. results copied into modem/prod: the model, hdlworkflow_loopback.m,
#    sim_byte_gate_k5.m, checkhdl_gate_240k5_byte.m, run_netlist_gates.sh,
#    rtl_sim_overrides/{wrap_byte.v,sim_byte.cpp}
# 5. structural diff of the new prod model against the previous one
#    (prod/DERIVATION.txt), so the change record travels with the binary
#
# Long (~15 min of MATLAB). Launch under systemd-run --user, e.g.
#   systemd-run --user --collect --same-dir --unit derive-$(date +%s) \
#     bash -c 'modem/prod/derive/derive.sh > /mnt/onetb/scratch/qpsk-build-trees/derive/run.out 2>&1'
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
DEV="$REPO/modem/dev"
PROD="$REPO/modem/prod"
DEST_PARENT=${1:-/mnt/onetb/scratch/qpsk-build-trees/derive}
FRESH="$DEST_PARENT/jupiter_byte_derive_build"
MATLAB_BIN=/mnt/onetb/MATLAB/R2025b/bin
[ -x "$MATLAB_BIN/matlab" ] || { echo "FATAL: matlab not found at $MATLAB_BIN"; exit 1; }
[ -d /home/tcollins/dev/qpsk_ai/TransceiverToolbox ] || { echo "FATAL: TransceiverToolbox donor missing"; exit 1; }

# production image environment (build_hdl.sh:156-182)
# the rung the derivation runs at = the rung prod ships (sp4: f3072 / 2 since 2026-09-18);
# override both in the environment to derive an sps-4 prod (QPSK_FRAME=f1536 QPSK_SPS=4)
export QPSK_LEAN=1 QPSK_FRAME=${QPSK_FRAME:-f3072} QPSK_SPS=${QPSK_SPS:-2} QPSK_BEATFIX=1 QPSK_BEATOBS=1 QPSK_FRAMESTAT=1
export QPSK_RXFIX=1
export QPSK_TXFIX="${QPSK_TXFIX-1}"
export FLAT_OUT_NAME=commhdlQPSKTxRxLoopback_flat
export FLAT_GIT_SHA=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)

echo "=== [1/5] fresh kit copy of dev -> $FRESH ==="
MK_OUT=$(bash "$REPO/modem/common/tools/make_kit.sh" dev "$FRESH" --with-tools) || { echo "$MK_OUT"; echo "FATAL: make_kit failed"; exit 1; }
echo "$MK_OUT" | tail -1
# the derivation runs from a DEV kit but needs prod's derive/ and edit/ stage folders
mkdir -p "$FRESH/derive" "$FRESH/edit" && rsync -a --exclude '*.slx' --exclude '*.png' --exclude '*_report.txt' "$PROD/derive/" "$FRESH/derive/" && rsync -a "$PROD/edit/" "$FRESH/edit/"
for f in "$FRESH"/derive/*.m "$FRESH"/edit/*.m; do [ -f "$f" ] && sed -i "s#$PROD#$FRESH#g" "$f"; done

echo "=== [2/5] MATLAB derive_prod (assemble + arrange + cleanup chain) ==="
T0=$(date +%s)
( cd "$FRESH" && timeout 5400 "$MATLAB_BIN/matlab" -batch "cd('$FRESH'); kitpath('$FRESH'); derive_prod" ) \
  > "$FRESH/derive_prod.log" 2>&1
MRC=$?; echo "matlab rc=$MRC elapsed=$(( $(date +%s) - T0 ))s"
grep -E "FLAT_MODEL_DONE|FLAT_RENAME_DONE|FLAT_ORDER_DONE|FLAT_LAYOUT_DONE|FLAT_SNAP_DONE|FLAT_SIMFIX_DONE|PROD_CLEANUP_DONE|FLAT_ROOT_HARNESS_DONE|DERIVE_PROD_DONE|Error" "$FRESH/derive_prod.log" | cut -c1-160
grep -q '^DERIVE_PROD_DONE' "$FRESH/derive_prod.log" || { echo "DERIVE_FAIL (see $FRESH/derive_prod.log)"; exit 1; }

echo "=== [3/5] gate scripts -> flattened-model variants ==="
bash "$FRESH/derive/patch_gates_for_flat.sh" "$FRESH" || exit 1

echo "=== [4/5] install into $PROD ==="
PREV="$DEST_PARENT/prod_previous.slx"
cp -f "$PROD/commhdlQPSKTxRxLoopback.slx" "$PREV" 2>/dev/null || true
cp -f "$FRESH/commhdlQPSKTxRxLoopback.slx" "$PROD/commhdlQPSKTxRxLoopback.slx"
cp -f "$FRESH/hdlworkflow_loopback.m"      "$PROD/hdlworkflow_loopback.m"
cp -f "$FRESH/simgate/sim_byte_gate_k5.m"  "$PROD/simgate/sim_byte_gate_k5.m"
cp -f "$FRESH/hdlsim/checkhdl_gate_240k5_byte.m"  "$PROD/hdlsim/checkhdl_gate_240k5_byte.m"
cp -f "$FRESH/hdlsim/run_netlist_gates.sh"  "$PROD/hdlsim/run_netlist_gates.sh"
mkdir -p "$PROD/hdlsim/rtl_sim_overrides"
cp -f "$FRESH/rtl_sim/wrap_byte.v" "$FRESH/rtl_sim/sim_byte.cpp" "$PROD/hdlsim/rtl_sim_overrides/"

echo "=== [5/5] change record ==="
DIFF="(no previous prod model)"
if [ -f "$PREV" ]; then
  ( cd "$FRESH" && timeout 1200 "$MATLAB_BIN/matlab" -batch "kitpath('$FRESH'); flat_diff('$FRESH','$PREV');" ) > "$FRESH/derive_diff.log" 2>&1
  DIFF=$(grep -E "^FLAT_DIFF_DONE" "$FRESH/derive_diff.log" | cut -c1-200)
  cp -f "$FRESH/FLAT_DIFF.txt" "$PROD/DERIVATION_DIFF.txt" 2>/dev/null || true
fi
{
  echo "DERIVATION $(date -Is)"
  echo "dev git: $FLAT_GIT_SHA"
  echo "env: QPSK_LEAN=$QPSK_LEAN QPSK_FRAME=$QPSK_FRAME QPSK_SPS=$QPSK_SPS QPSK_BEATFIX=$QPSK_BEATFIX QPSK_BEATOBS=$QPSK_BEATOBS QPSK_FRAMESTAT=$QPSK_FRAMESTAT QPSK_RXFIX=$QPSK_RXFIX QPSK_TXFIX=$QPSK_TXFIX"
  echo "model md5: $(md5sum "$PROD/commhdlQPSKTxRxLoopback.slx" | cut -c1-12)"
  echo "kit: $FRESH"
  echo "vs previous prod: $DIFF"
  echo "chain: make_flat_model -> rename reg_ -> order -> layout(composite, Receiver) -> snap -> simfix -> prod_cleanup -> root harness -> gates patched"
} > "$PROD/DERIVATION.txt"
cat "$PROD/DERIVATION.txt"
echo "DERIVE_DONE $PROD/commhdlQPSKTxRxLoopback.slx"
