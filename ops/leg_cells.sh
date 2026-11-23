#!/bin/bash
# leg_cells.sh -- one capture_r3.sh leg per CELL with one env knob changed, scored by score_leg.py
# (sp4 Task 12: the r4 LO / sro_sign discriminating cells). The pair must already be up on the image
# under test; each cell does a full bring-up (an arm), so keep the cell list short.
#   CELLS="B:LO_B_RX=1900080000 A:LO_A_RX=2000060000" OUT=<dir> [RUNG=r4] [DUR=60] [SRO_SIGN_CONF=<conf>]
#   as a rig unit: ops/launch_rig_unit.sh cells-<ts> ops/leg_cells.sh CELLS=... OUT=... RUNG=r4
set -u
D=$(cd "$(dirname "$0")" && pwd)
S=$D
OUT=${OUT:?}; mkdir -p "$OUT"; LOG=$OUT/sweep.log
say(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
say "=== leg cells (RUNG=${RUNG:-r4}, ${DUR:-60}s): $CELLS ==="
for cell in $CELLS; do
  leg=${cell%%:*}; kv=${cell#*:}; k=${kv%%=*}; v=${kv#*=}
  dir=$OUT/${leg}_${k}_${v}; mkdir -p "$dir"
  say "--- cell $leg $k=$v ---"
  env RUNG="${RUNG:-r4}" "$k=$v" "$D/capture_r3.sh" "$leg" -d "${DUR:-60}" -k -o "$dir" > "$dir/capture.out" 2>&1; rc=$?
  line=$(python3 "$S/score_leg.py" "$dir" 2>&1 | tail -1)
  say "CELL $leg $k=$v rc=$rc $line"
done
say "SWEEP_DONE"
