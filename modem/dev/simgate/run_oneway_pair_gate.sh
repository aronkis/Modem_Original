#!/bin/bash
# run_oneway_pair_gate.sh [tx_kit] [rx_kit] -- run sim_oneway_pair_gate.m under the
# production geometry environment (the InitFcn derives every rate from QPSK_FRAME /
# QPSK_SPS; the gate also reads them from the kit Description, this wrapper just
# makes the run identical to the assembles'). Writes <tx_kit>/SIM_ONEWAY_PAIR_GATE.txt.
set -u
D=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TXK=${1:-/mnt/onetb/scratch/qpsk-build-trees/oneway/jupiter_byte_onewaytx_build}
RXK=${2:-/mnt/onetb/scratch/qpsk-build-trees/oneway/jupiter_byte_onewayrx_build}
MATLAB_BIN=/mnt/onetb/MATLAB/R2025b/bin
[ -x "$MATLAB_BIN/matlab" ] || { echo "FATAL: matlab not found at $MATLAB_BIN"; exit 1; }
export QPSK_LEAN=1 QPSK_FRAME=${QPSK_FRAME:-f1536} QPSK_SPS=${QPSK_SPS:-4} QPSK_BEATFIX=1 QPSK_BEATOBS=1 QPSK_FRAMESTAT=1
export QPSK_RXFIX=1 QPSK_TXFIX="${QPSK_TXFIX-1}"
export ONEWAY_TX_KIT="$TXK" ONEWAY_RX_KIT="$RXK"
mkdir -p "$TXK/simgate"; cp -f "$D/sim_oneway_pair_gate.m" "$TXK/simgate/"
T0=$(date +%s)
( cd "$TXK" && timeout 5400 "$MATLAB_BIN/matlab" -batch "cd('$TXK'); kitpath('$TXK'); sim_oneway_pair_gate" ) > "$TXK/sim_oneway_pair_gate.out" 2>&1
RC=$?; echo "matlab rc=$RC elapsed=$(( $(date +%s) - T0 ))s"
grep -E "geometry:|harness:|SIM_ONEWAY_PAIR_GATE|^\{|Caused|Inconsistent" "$TXK/sim_oneway_pair_gate.out" | grep -v '^\[> In' | cut -c1-200
grep -q '^SIM_ONEWAY_PAIR_GATE_DONE PASS' "$TXK/sim_oneway_pair_gate.out" && echo "RUN_ONEWAY_PAIR_GATE_DONE PASS stamp=$TXK/SIM_ONEWAY_PAIR_GATE.txt" || { echo "RUN_ONEWAY_PAIR_GATE_FAIL (see $TXK/sim_oneway_pair_gate.out)"; exit 1; }
