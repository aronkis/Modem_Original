#!/bin/bash
# run_tb.sh -- xsim run of tb_tx_cdc_fifo on a Vivado host (needs xvlog/xelab/xsim + the xpm library).
# Usage: run_tb.sh [workdir]   -> prints TB_PASS / TB_FAIL, exit 0 only on TB_PASS.
set -eu
D=$(cd "$(dirname "$0")" && pwd); W=${1:-$(mktemp -d)}; mkdir -p "$W"; cd "$W"
for s in /opt/Xilinx/2025.1/Vivado/settings64.sh /tools/Xilinx/2025.1/Vivado/settings64.sh; do [ -f $s ] && { set +u; source $s; set -u; break; }; done
command -v xvlog >/dev/null || { echo "TB_NO_XSIM"; exit 2; }
G=$(dirname "$(command -v xvlog)")/../data/verilog/src/glbl.v
xvlog -sv "$D/tx_cdc_fifo.v" "$D/tb_tx_cdc_fifo.sv" "$G" > xvlog.log 2>&1 || { tail -20 xvlog.log; echo TB_FAIL_COMPILE; exit 1; }
xelab -L xpm -debug typical tb_tx_cdc_fifo glbl -s tb_snap > xelab.log 2>&1 || { tail -20 xelab.log; echo TB_FAIL_ELAB; exit 1; }
xsim tb_snap -R > xsim.log 2>&1 || true
grep -E "TB_PHASE|TB_PASS|TB_FAIL" xsim.log | tail -40
grep -q "^TB_PASS" xsim.log
