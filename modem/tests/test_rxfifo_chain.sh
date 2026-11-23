#!/bin/bash
# test_rxfifo_chain.sh -- rxfifo_inject.sh mirrors the GENERATED delayMatch chain depth
# (a delay-balancing artefact: 4 on the full image, different on a one-way image).
# Synthetic generated copies of depth 2 and 4; the drop-in must come out with the
# same depth, and the historical 4 must be byte-identical to the template chain.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); INJ="$HERE/../common/rxfifo/rxfifo_inject.sh"
fail(){ echo "RXFIFO_CHAIN_FAIL $*"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
for n in 1 3; do
  d="$T/$n/hdlsrc/x"; mkdir -p "$d"
  printf "module TxRxCompo_ip_src_ByteRxFifo;\n  reg  [%d:0] delayMatch_reg;  // ufix1\nendmodule\n" "$n" > "$d/TxRxCompo_ip_src_ByteRxFifo.v"
  out=$(bash "$INJ" "$T/$n" 4096 2>&1) || fail "injector rc on depth $((n+1)): $out"
  echo "$out" | grep -q "RXFIFO_INJECT_OK depth=4096 chain=$((n+1)) " || fail "chain not reported as $((n+1)): $out"
  f="$d/TxRxCompo_ip_src_ByteRxFifo.v"
  grep -q "reg \[$n:0\] delayMatch_reg;" "$f"  || fail "ready chain width wrong at depth $((n+1))"
  grep -q "reg \[$n:0\] delayMatch1_reg;" "$f" || fail "stateControl chain width wrong at depth $((n+1))"
  grep -q "wire ready_1        = delayMatch_reg\[$n\];" "$f" || fail "ready_1 tap wrong at depth $((n+1))"
  grep -q "delayMatch_reg <= {delayMatch_reg\[$((n-1)):0\], ready};" "$f" || fail "ready shift wrong at depth $((n+1))"
  grep -q "injected by rxfifo_inject.sh" "$f" || fail "marker missing"
done
# an already-injected copy is not "measured" (idempotent re-run keeps 4)
out=$(bash "$INJ" "$T/3" 4096 2>&1); echo "$out" | grep -q "chain=4 " || fail "re-run on the drop-in did not fall back to 4: $out"
echo "RXFIFO_CHAIN_OK"
