#!/bin/bash
# run_netlist_gates.sh -- modem NETLIST gates (NO Vivado):
#   1) checkhdl + makehdl -> s1_rtl/hdlsrc  (checkhdl_gate_240k5_byte.m)
#   2) golden byte vectors                   (gen_byte_vectors_k5.m)
#   3) S1  ROM-path regression: iverilog tb_tx_240k5.v (ext ports tied off)
#      + s1_analyze_240k5.m  -> S1_GATE.txt
#   4) S1B byte-path gate: Verilator wrap_byte.v + sim_byte.cpp, aligned
#      (rot=0) + rotated (rot=17) runs + s1b_analyze_byte.m -> S1B_GATE.txt
set -e -o pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)   # this runner lives in <kit>/hdlsim/
# A scratch kit (make_kit.sh) carries rtl_sim/ and the analysers at its root; the in-repo
# tree does not (no symlinks in the repo), so fall back to modem/rtl_sim and modem/dev/.
RTL_SIM="$KIT/rtl_sim"; [ -d "$RTL_SIM" ] || RTL_SIM="$(cd "$KIT/.." && pwd)/rtl_sim"
GBV="$KIT/simgate/gen_byte_vectors_k5.m"; [ -f "$GBV" ] || GBV="$(cd "$KIT/.." && pwd)/dev/simgate/gen_byte_vectors_k5.m"
S1A="$KIT/hdlsim/s1_analyze_240k5.m";  [ -f "$S1A" ] || S1A="$(cd "$KIT/.." && pwd)/dev/hdlsim/s1_analyze_240k5.m"
S1BA="$KIT/hdlsim/s1b_analyze_byte.m"; [ -f "$S1BA" ] || S1BA="$(cd "$KIT/.." && pwd)/dev/hdlsim/s1b_analyze_byte.m"
export PATH=/mnt/onetb/MATLAB/R2025b/bin:/usr/local/bin:/usr/bin:/bin
cd "$KIT"

echo "=== [1/4] checkhdl + makehdl ==="
matlab -batch "run('$KIT/hdlsim/checkhdl_gate_240k5_byte.m')"

VD=$KIT/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback
test -f "$VD/TxRxComposite.v"

# pi-shadowing netlist regression gate (2026-07-11): see run_full_gates_t8.sh
if grep -q 'gain_mul_temp' "$VD/QPSK_Demodulator_Baseband.v"; then
  echo "PI_GATE FAIL: demod derotation multiply present" >&2; exit 1
fi
if grep -q "sb00000000100110011" "$VD/Loop_Filter_block.v"; then
  echo "PI_GATE FAIL: poisoned 307 CS gain" >&2; exit 1
fi
echo "PI_GATE: PASS"

echo "=== [2/4] golden byte vectors ==="
matlab -batch "run('$GBV')"

echo "=== [3/4] S1 ROM-path iverilog regression ==="
cd "$RTL_SIM"
if [ "${QPSK_FRAME:-k5}" = k5 ]; then
  iverilog -g2001 -o tb_tx_240k5.vvp tb_tx_240k5.v "$VD"/*.v
  vvp tb_tx_240k5.vvp | tail -2
  matlab -batch "run('$S1A')"
  grep -q 'result: PASS' "$KIT/S1_GATE.txt" && echo "S1_GATE: PASS"
else
  # s1_analyze_240k5.m is the K5 ROM-path analyser (it crashed after 6 h of Icarus at f1536); the
  # large-frame proof is S1B below plus the Gate 1 model matrix (docs/evidence/sp4/GATE1.md)
  echo "=== [3/4] S1 ROM-path: SKIPPED at QPSK_FRAME=$QPSK_FRAME (k5-only analyser; large-frame proof = S1B + gates/run_gates.sh) ==="
fi

echo "=== [4/4] S1B byte-path Verilator gate ==="
rm -rf obj_byte
verilator -O2 -Wno-fatal --cc wrap_byte.v -y "$VD" --exe sim_byte.cpp \
  -Mdir obj_byte --top-module wrap_byte
make -s -C obj_byte -f Vwrap_byte.mk Vwrap_byte
# Frame-aware clk budget (RXALIGN task 2026-07-25: was k5-locked at 38*18128).
# frame clks = (13 + PayloadBits/2 sym) * sps8 * 2 clks/rail-beat:
#   k5   : (13+1120)*8*2 = 18128, 38 frames
#   f1536: (13+12320)*8*2 = 197328, 12 frames (~11x longer -> fewer frames)
# sim_byte.cpp is frame-agnostic (reads NW=35/385 from tx_words_golden.hex).
# clocks per frame = slots x (2*sps bus samples per slot) x 2 clk per bus sample (adc_validIn toggles):
#   k5 1133x16, f1536 12333x16 (sps 4), f3072 24634x8 (sps 2) -- the frame count NF is what the graders need
case "${QPSK_FRAME:-k5}" in f3072) FRCLK=197072; NF=12 ;; f1536) FRCLK=197328; NF=12 ;; *) FRCLK=18128; NF=38 ;; esac
CLKS=$((100 + NF*FRCLK))
echo "S1B: frame=${QPSK_FRAME:-k5} FRCLK=$FRCLK NF=$NF CLKS=$CLKS"
./obj_byte/Vwrap_byte tx_words_golden.hex $CLKS 0  s1b_rot0
./obj_byte/Vwrap_byte tx_words_golden.hex $CLKS 17 s1b_rot17
matlab -batch "run('$S1BA')"
grep -q 'result: PASS' "$KIT/S1B_GATE.txt" && echo "S1B_GATE: PASS"

echo NETLIST_GATES_DONE
