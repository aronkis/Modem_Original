#!/bin/bash
# =============================================================================
# freq_map_campaign.sh -- map the reverse leg's defect against CARRIER FREQUENCY, unattended.
#
# WHY (2026-09-28 19:27, overnight band-swap experiment with the fault LIVE): the defect FOLLOWS
# THE BAND. With the reverse leg (148 TX -> 146 RX) moved from 1.9 GHz to 2.0 GHz it ran clean
# (1248 / 1240 f/s, 0 resets) in both swapped cells, while the forward leg moved onto 1.9 GHz
# degraded in both (148 at 1069 / 786 f/s, 87,830 resets, rssi 6 dB weaker). Alternating with the
# plan, not the order. So 148's transmitter and 146's receiver are exonerated as hardware, and
# the problem is something at 1.9 GHz -- an antenna roll-off, or an interferer (1.9 GHz sits in
# a cellular uplink band).
#
# A NOTCH (bad at 1.9 only, fine at 1.85 and 1.95) says interference. A SLOPE (worse the lower
# you go) says antenna. Either way the cheapest fix is to move the reverse leg, and this run
# measures where to move it to. Each candidate is interleaved against the 1.9 GHz reference
# with plan_cells.sh (2 cells: ref, candidate), so a clean candidate cell next to a dirty
# reference cell is the knob and not the clock. The forward leg stays at 2.0 GHz throughout
# (its own health is the control). The reverse receiver keeps its +40 kHz offset.
#
# Env: OUT=<dir> DEADLINE="YYYY-MM-DD HH:MM" HOLD=240 REST_S=120 DRY=1
#      CANDS="2100 1800 2150 1850 2050 1950 1750" (MHz; the bring-up refuses outside 1.8-2.2 GHz
#      and that refusal is recorded as a failed cell, not a crash)
# Always under launch_rig_unit.sh. Sole rig actor: stop the trigger and any other campaign.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:?OUT=<dir>}; DEADLINE=${DEADLINE:?DEADLINE="YYYY-MM-DD HH:MM"}
HOLD=${HOLD:-240}; REST_S=${REST_S:-120}; DRY=${DRY:-0}
CANDS=${CANDS:-"2100 1800 2150 1850 2050 1950"}
SS_FILE=${SENTINEL_STOP_FILE:-$HOME/modem-status/SENTINEL_STOP}
mkdir -p "$OUT"; L=$OUT/freqmap.log
say(){ echo "$(date -Is) $*" | tee -a "$L"; }
dl=$(date -d "$DEADLINE" +%s) || { say "bad DEADLINE '$DEADLINE'"; exit 2; }
REF_ENV="LO_B_TX=2100000000 LO_A_RX=2100020000 LO_A_TX=1900000000 LO_B_RX=1900040000"
cand_env(){ local f=$(( $1 * 1000000 )); echo "LO_B_TX=2100000000 LO_A_RX=2100020000 LO_A_TX=$f LO_B_RX=$(( f + 40000 ))"; }

SS_MINE=0
if [ "$DRY" != 1 ]; then
  if [ ! -e "$SS_FILE" ]; then echo "freq_map_campaign $(date -Is)" > "$SS_FILE"; SS_MINE=1; say "SENTINEL_STOP taken (ours)"
  else say "SENTINEL_STOP already present -- NOT ours, leaving it"; fi
fi
finish(){
  say "--- closing: default bring-up (shipped plan) ---"
  if [ "$DRY" = 1 ]; then say "[dry] $D/bringup_r2r3.sh r3"
  else "$D/bringup_r2r3.sh" r3 >>"$L" 2>&1 && say "RESTORE_OK" || { sleep 30; "$D/bringup_r2r3.sh" r3 >>"$L" 2>&1 && say "RESTORE_OK (attempt 2)" || say "RESTORE_FAILED -- rig NOT in service"; }; fi
  [ "$SS_MINE" = 1 ] && { rm -f "$SS_FILE"; say "SENTINEL_STOP released"; }
  say "FREQMAP_DONE $OUT"
}
trap finish EXIT

say "=== freq map until $DEADLINE: reverse carrier candidates [$CANDS] MHz vs 1900 reference, hold ${HOLD}s, dry=$DRY ==="
consec=0; pass=0
while [ "$(date +%s)" -lt "$dl" ]; do
  pass=$(( pass + 1 )); say "--- pass $pass ---"
  for mhz in $CANDS; do
    [ "$(date +%s)" -lt "$dl" ] || break
    dir=$OUT/$(date +%H%M%S)_rev${mhz}
    say "=== candidate reverse @ ${mhz} MHz -> $dir ==="
    env OUT="$dir" CELLS=2 HOLD="$HOLD" RESTORE=0 DRY="$DRY" \
        A_NAME=ref1900 A_ENV="$REF_ENV" B_NAME="rev${mhz}" B_ENV="$(cand_env "$mhz")" \
        "$D/plan_cells.sh" >> "$L" 2>&1
    fails=$(awk -F'\t' 'NR>1 && $5!="0" && $5!="dry"' "$dir/cells.tsv" 2>/dev/null | wc -l)
    say "candidate ${mhz} done bringup_failures=$fails"
    if [ "$fails" -ge 2 ]; then consec=$(( consec + 1 )); else consec=0; fi
    [ "$consec" -ge 4 ] && { say "ABORT: 4 consecutive candidates with every bring-up failing"; exit 1; }
    [ "$DRY" = 1 ] || sleep "$REST_S"
  done
  [ "$DRY" = 1 ] && { say "[dry] one pass shown"; break; }
done
say "deadline reached"
