#!/bin/bash
# =============================================================================
# band_swap_probe.sh -- does the one-sided reverse-leg defect follow the BAND or the CHAIN?
#
# THE QUESTION. The quiet pair is asymmetric: the forward leg (146 TX -> 148 RX) runs at 2.0 GHz
# and the reverse leg (148 TX -> 146 RX) at 1.9 GHz. The reverse leg has been failing for weeks
# while the forward leg is untouched, and every measurement so far is consistent with BOTH of:
#
#   BAND   something frequency-selective at 1.9 GHz -- the 146 antenna, a mismatch, an interferer
#   CHAIN  a board's hardware -- 148's transmitter or 146's receiver -- independent of frequency
#
# With two boards and no loopback cable, swapping which DIRECTION uses which frequency is the only
# way to separate them. After the swap the reverse leg still runs 148 TX -> 146 RX, but at 2.0 GHz:
#
#   defect STAYS on 148->146 after the swap  ->  it is the CHAIN. Band, antenna and interference
#                                                are out; the suspect is 148 TX or 146 RX hardware.
#   defect MOVES to 146->148 after the swap  ->  it is the BAND. 1.9 GHz is the problem, which
#                                                points straight back at the unreplaced 146 antenna.
#
# This is the 2026-09-08 antenna-swap logic done in software: no flash, no image change, no
# physical access. It needs ops/bringup_r2r3.sh's TX LOs to be env-overridable (added 2026-09-28).
#
# WHAT IT MEASURES, AND WHY THAT IS ENOUGH. The bring-up's own arm gate probes BOTH boards'
# detected-frame rate (0x104) right after arming and prints it on every try. Both ends are on the
# ROM source at that point, so this is a PHY measurement with the byte plane, DMA and host data
# path entirely absent. The effect being tested is not subtle -- a working leg reads ~1245 f/s and
# a failed one reads tens -- so the gate line is the whole instrument and no 300 s capture is
# needed. Each cell costs one arm instead of one capture.
#
# INTERLEAVED, ALWAYS. This leg's condition drifts within minutes (REVERSE_LO_CELLS_2026-09-28.md
# showed delivery tracking the clock while the knob moved a different statistic tenfold), so the
# plans alternate and the question is whether the result tracks the PLAN or the ORDER. A single
# cell on the swapped plan would prove nothing.
#
# Usage:
#   ops/band_swap_probe.sh [-n CELLS] [-o OUTDIR]      # default 4 cells: normal, swap, normal, swap
#   DRY=1 ops/band_swap_probe.sh                       # print the plan, touch nothing
#
# Stop any unit that arms boards first (the degraded-episode trigger); each bring-up takes the rig
# lock and holds SENTINEL_STOP for its own duration, but nothing serialises the gaps between them.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd)
CELLS=${CELLS:-4}; DRY=${DRY:-0}; RUNG=${RUNG:-r3}
OUT=${OUT:-$D/r3cap/bandswap_$(date +%Y%m%d_%H%M%S)}
while [ $# -gt 0 ]; do
  case $1 in
    -n) CELLS=$2; shift 2 ;;
    -o) OUT=$2; shift 2 ;;
    *) echo "usage: band_swap_probe.sh [-n CELLS] [-o OUTDIR]" >&2; exit 2 ;;
  esac
done
mkdir -p "$OUT"; L=$OUT/band_swap.log; T=$OUT/cells.tsv
say(){ echo "$(date -Is) $*" | tee -a "$L"; }

# The two plans. NORMAL is the pre-2026-09-29 pairing (reverse at 1.9 GHz -- the notch), kept as
# the experimental reference; the SHIPPED plan is now ops/rung_table.sh's (reverse at 1.85 GHz).
# SWAP exchanges which direction owns which frequency, keeping each receiver's CFO offset.
#   normal: fwd 146tx 2.100 -> 148rx 2.10002   rev 148tx 1.900 -> 146rx 1.90004  (forward carrier 2.1 GHz since 2026-10-01)
#   swap:   fwd 146tx 1.900 -> 148rx 1.90002   rev 148tx 2.100 -> 146rx 2.10004
plan_env(){ case $1 in
  normal) echo "LO_B_TX=2100000000 LO_A_RX=2100020000 LO_A_TX=1900000000 LO_B_RX=1900040000" ;;
  swap)   echo "LO_B_TX=1900000000 LO_A_RX=1900020000 LO_A_TX=2100000000 LO_B_RX=2100040000" ;;
esac; }

say "=== band_swap_probe: $CELLS interleaved cells at rung $RUNG, dry=$DRY, out=$OUT ==="
say "    reverse leg is 148 TX -> 146 RX in BOTH plans; only its FREQUENCY changes."
printf 'cell\tplan\tfwd_148rx_fps\trev_146rx_fps\tgate\n' > "$T"

i=0
while [ "$i" -lt "$CELLS" ]; do
  i=$(( i + 1 ))
  case $(( i % 2 )) in 1) plan=normal ;; 0) plan=swap ;; esac
  env_kv=$(plan_env "$plan")
  say "--- cell $i: plan=$plan ($env_kv) ---"
  if [ "$DRY" = 1 ]; then
    say "[dry] would run: env $env_kv GATE_TRIES=3 $D/bringup_r2r3.sh $RUNG"
    printf '%d\t%s\t-\t-\tdry\n' "$i" "$plan" >> "$T"
    continue
  fi
  cl=$OUT/cell${i}_${plan}.log
  # GATE_DIR stays at its default "both": a gate that FAILS is data here, and the per-try line
  # carries both legs' rate either way. GATE_TRIES bounds a cell that will never pass.
  env $env_kv GATE_TRIES=3 "$D/bringup_r2r3.sh" "$RUNG" > "$cl" 2>&1
  rc=$?
  gate=$(grep -c "^gate try" "$cl" 2>/dev/null || echo 0)
  # score the LAST gate try: the arm has settled as far as it is going to by then
  last=$(grep "^gate try" "$cl" 2>/dev/null | tail -1)
  fa=$(echo "$last" | sed -n 's/.*148 rx=\([0-9]*\) f\/s.*/\1/p'); fa=${fa:-0}
  fb=$(echo "$last" | sed -n 's/.*146 rx=\([0-9]*\) f\/s.*/\1/p'); fb=${fb:-0}
  verdict=PASS; [ "$rc" = 0 ] || verdict=GATE_FAIL
  say "  cell $i $plan: 148 rx=$fa f/s  146 rx=$fb f/s  ($gate gate tries, rc=$rc $verdict)"
  say "  all gate tries: $(grep '^gate try' "$cl" | tr '\n' ' | ')"
  printf '%d\t%s\t%s\t%s\t%s\n' "$i" "$plan" "$fa" "$fb" "$verdict" >> "$T"
done

say "--- restoring the NORMAL plan and putting the pair back in service ---"
if [ "$DRY" = 1 ]; then say "[dry] would run: $D/bringup_r2r3.sh $RUNG (default LOs)"
else
  "$D/bringup_r2r3.sh" "$RUNG" >>"$L" 2>&1 && say "RESTORE_OK" || say "RESTORE_FAILED -- rig NOT in service"
fi
say "BAND_SWAP_DONE results=$T"
column -t "$T" 2>/dev/null | tee -a "$L"
say "READ IT BY PLAN, NOT BY CELL: if 146 rx stays low on BOTH plans the defect is the CHAIN"
say "(148 TX or 146 RX hardware); if it is low on normal and healthy on swap -- and 148 rx goes"
say "the other way -- the defect follows the BAND and the 146 antenna is back in the frame."
