#!/bin/bash
# rxfifo_inject.sh <BUILD_DIR> [DEPTH] -- inject the BRAM drop-in ByteRxFifo
# (modem/rxfifo/ByteRxFifo.v, module renamed to the packaged-IP name
# TxRxCompo_ip_src_ByteRxFifo) into EVERY copy of the generated module in a
# byte-image build tree: loose hdlsrc, ipcore dirs, the packaged IP zips, and
# the already-extracted BD ipshared copies (the tmr_attr_inject.sh lesson:
# Vivado synthesizes the zip/ipshared copy, not the loose file). Hard-verifies.
set -u
B=${1:?build dir}; DEPTH=${2:-4096}
SRC=$(cd "$(dirname "$0")" && pwd)/ByteRxFifo.v
MOD=TxRxCompo_ip_src_ByteRxFifo.v
AW=$(python3 -c "import math;print(int(math.log2($DEPTH)))")
# CHAIN DEPTH of the two delayMatch pipelines (ready, stateControl): the drop-in
# mirrors the GENERATED module "verbatim", and the generated depth is a delay-
# balancing artefact of the whole model (4 on the full TX+RX image; a ONE-WAY
# image with one half stubbed balances differently). Measure it on the first
# loose generated copy BEFORE overwriting, so the mirror stays exact; fall back
# to the historical 4 (loudly) if no generated copy is readable.
GEN=$(find "$B" -name "$MOD" -path "*hdlsrc*" 2>/dev/null | head -1)
CHAIN=$(python3 - "$GEN" <<'PY'
import re, sys
p = sys.argv[1]
try:
    t = open(p).read()
except Exception:
    print(""); sys.exit(0)
if "injected by rxfifo_inject.sh" in t:
    print(""); sys.exit(0)          # already the drop-in: nothing to measure
m = re.search(r"reg\s*\[(\d+):0\]\s*delayMatch_reg\s*;", t)
if m: print(int(m.group(1)) + 1)
elif re.search(r"reg\s+delayMatch_reg\s*;", t): print(1)
else: print("")
PY
)
if [ -z "$CHAIN" ]; then CHAIN=4; echo "RXFIFO_CHAIN_UNMEASURED (no generated copy at ${GEN:-none}; using the historical 4)"; else echo "  generated ready/stateControl chain depth = $CHAIN (from $GEN)"; fi
TMP=$(mktemp); sed -e "s/^module ByteRxFifo #(parameter DEPTH = 4096, parameter AW = 12)/module TxRxCompo_ip_src_ByteRxFifo #(parameter DEPTH = $DEPTH, parameter AW = $AW)/" -e 's/^endmodule  \/\/ ByteRxFifo (BRAM drop-in v5, injected by rxfifo_inject.sh)/endmodule  \/\/ TxRxCompo_ip_src_ByteRxFifo (BRAM drop-in v5, injected by rxfifo_inject.sh)/' "$SRC" > "$TMP"
grep -q "^module TxRxCompo_ip_src_ByteRxFifo" "$TMP" || { echo "RXFIFO_FATAL rename failed"; exit 1; }
if [ "$CHAIN" != 4 ]; then
  python3 - "$TMP" "$CHAIN" <<'PY'
import sys
p, n = sys.argv[1], int(sys.argv[2])
t = open(p).read()
top = n - 1
if n == 1:
    decl1 = "  reg delayMatch1_reg;   // stateControl pipeline (depth 1, measured)"
    decl  = "  reg delayMatch_reg;    // ready pipeline (depth 1, measured)"
    sc = "  wire stateControl_2 = delayMatch1_reg;"
    rd = "  wire ready_1        = delayMatch_reg;"
    a1 = "    if (reset) delayMatch1_reg <= 1'b0;\n    else if (enb) delayMatch1_reg <= 1'b1;"
    a2 = "    if (reset) delayMatch_reg <= 1'b0;\n    else if (enb) delayMatch_reg <= ready;"
else:
    decl1 = f"  reg [{top}:0] delayMatch1_reg;   // stateControl pipeline (depth {n}, measured)"
    decl  = f"  reg [{top}:0] delayMatch_reg;    // ready pipeline (depth {n}, measured)"
    sc = f"  wire stateControl_2 = delayMatch1_reg[{top}];"
    rd = f"  wire ready_1        = delayMatch_reg[{top}];"
    a1 = f"    if (reset) delayMatch1_reg <= {n}'b0;\n    else if (enb) delayMatch1_reg <= {{delayMatch1_reg[{top-1}:0], 1'b1}};"
    a2 = f"    if (reset) delayMatch_reg <= {n}'b0;\n    else if (enb) delayMatch_reg <= {{delayMatch_reg[{top-1}:0], ready}};"
pairs = [
 ("  reg [3:0] delayMatch1_reg;   // stateControl pipeline", decl1),
 ("  reg [3:0] delayMatch_reg;    // ready pipeline", decl),
 ("  wire stateControl_2 = delayMatch1_reg[3];", sc),
 ("  wire ready_1        = delayMatch_reg[3];", rd),
 ("    if (reset) delayMatch1_reg <= 4'b0;\n    else if (enb) delayMatch1_reg <= {delayMatch1_reg[2:0], 1'b1};", a1),
 ("    if (reset) delayMatch_reg <= 4'b0;\n    else if (enb) delayMatch_reg <= {delayMatch_reg[2:0], ready};", a2),
]
for a, b in pairs:
    assert t.count(a) == 1, a
    t = t.replace(a, b)
open(p, "w").write(t)
PY
  [ $? -eq 0 ] || { echo "RXFIFO_FATAL chain rewrite to depth $CHAIN failed"; exit 1; }
fi
N=0
for f in $(find "$B" -name "$MOD" 2>/dev/null); do cp "$TMP" "$f"; N=$((N+1)); echo "  replaced: $f"; done
for z in $(find "$B" -name "TxRxCompo_ip_v1_0.zip" 2>/dev/null); do
  TD=$(mktemp -d); mkdir -p "$TD/hdl"; cp "$TMP" "$TD/hdl/$MOD"
  ( cd "$TD" && zip -q "$z" "hdl/$MOD" ) || { echo "RXFIFO_FATAL rezip $z"; exit 1; }
  ( cd "$TD" && unzip -o -q "$z" "hdl/$MOD" && grep -q "BRAM drop-in" "hdl/$MOD" ) || { echo "RXFIFO_FATAL zip verify $z"; exit 1; }
  rm -rf "$TD"; N=$((N+1)); echo "  zip patched: $z"
done
rm -f "$TMP"
C=$(grep -rl "injected by rxfifo_inject.sh" "$B" --include="$MOD" | wc -l)
echo "RXFIFO_INJECT_OK depth=$DEPTH chain=$CHAIN files+zips=$N verified_loose=$C"
