#!/bin/bash
# =============================================================================
# overnight_campaign.sh -- rotate the reverse-leg discriminating experiments unattended until a
# deadline, each as an interleaved plan_cells.sh run with a hold, so the fault is sampled in the
# minutes after every arm instead of the one instant a hand-run experiment happened to pick.
#
# Built 2026-09-28 evening after four hand-run experiments that day found the fault ABSENT when
# it mattered. Every experiment here is one that has a live hypothesis behind it and that no
# measurement has yet closed:
#
#   selfdesense  146's OWN transmitter muted vs live after the arm. 146 leaks 7.5 dB into its own
#                receiver (3.6 dB worse than 148, above its wanted signal). If the decay/collapse
#                does not happen with 146 silent, FDD self-desense is the cause.
#   bandswap     which DIRECTION owns which frequency, with a hold this time. Defect follows the
#                band (1.9 GHz -> the 146 antenna) or the chain (148-TX / 146-RX hardware).
#   txpower      148 TX at 0 dB vs -10 dB. A distorting PA improves at lower drive; a link-budget
#                shortfall gets worse. Opposite predictions, never measured.
#   agcpin       146 AGC automatic vs pinned (spi) at the level it sits at when healthy. If the
#                leakage is pumping the AGC and sinking the wanted signal, pinning helps.
#
# Rig discipline: this unit is the ONLY rig actor for its duration. Stop the degraded trigger
# first. SENTINEL_STOP is taken here if absent and released only if taken here. Each cell's
# bring-up takes the rig lock itself; the poll takes it for the hold. Three consecutive failed
# bring-ups abort the campaign (a rig that will not arm must not be hammered all night). A final
# default bring-up puts the pair back in service whatever happened.
#
# Env: OUT=<dir> DEADLINE="YYYY-MM-DD HH:MM" (local) CELLS=4 HOLD=240 REST_S=300 DRY=1
# Always under launch_rig_unit.sh.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
A=10.0.0.148; B=10.0.0.146
OUT=${OUT:?OUT=<dir>}; DEADLINE=${DEADLINE:?DEADLINE="YYYY-MM-DD HH:MM"}
CELLS=${CELLS:-4}; HOLD=${HOLD:-240}; REST_S=${REST_S:-300}; DRY=${DRY:-0}
SS_FILE=${SENTINEL_STOP_FILE:-$HOME/modem-status/SENTINEL_STOP}
mkdir -p "$OUT"; L=$OUT/campaign.log
say(){ echo "$(date -Is) $*" | tee -a "$L"; }
dl=$(date -d "$DEADLINE" +%s) || { say "bad DEADLINE '$DEADLINE'"; exit 2; }

# hooks are host-side snippets that write ONE iio attribute on ONE board and echo the readback
P=/sys/bus/iio/devices/iio:device2
mute146="$W $B 'echo -40.0 > $P/out_voltage0_hardwaregain; echo 146 tx_gain=\$(cat $P/out_voltage0_hardwaregain)' 2>/dev/null | tail -1"
unmute146="$W $B 'echo 0.0 > $P/out_voltage0_hardwaregain' 2>/dev/null"
tx148_low="$W $A 'echo -10.0 > $P/out_voltage0_hardwaregain; echo 148 tx_gain=\$(cat $P/out_voltage0_hardwaregain)' 2>/dev/null | tail -1"
tx148_full="$W $A 'echo 0.0 > $P/out_voltage0_hardwaregain' 2>/dev/null"
pin146="$W $B 'echo spi > $P/in_voltage0_gain_control_mode; echo 34 > $P/in_voltage0_hardwaregain; echo 146 mode=\$(cat $P/in_voltage0_gain_control_mode) gain=\$(cat $P/in_voltage0_hardwaregain)' 2>/dev/null | tail -1"
unpin146="$W $B 'echo automatic > $P/in_voltage0_gain_control_mode' 2>/dev/null"

run_exp(){ # $1 name  $2.. env for plan_cells
  local name=$1; shift
  local dir=$OUT/$(date +%H%M%S)_$name
  say "=== experiment $name -> $dir ==="
  env OUT="$dir" CELLS="$CELLS" HOLD="$HOLD" RESTORE=0 DRY="$DRY" "$@" "$D/plan_cells.sh" >> "$L" 2>&1
  local rc=$?
  local fails
  fails=$(awk -F'\t' 'NR>1 && $5!="0" && $5!="dry"' "$dir/cells.tsv" 2>/dev/null | wc -l)
  say "experiment $name done rc=$rc bringup_failures=$fails"
  FAILS=$fails
}

SS_MINE=0
if [ "$DRY" != 1 ]; then
  if [ ! -e "$SS_FILE" ]; then echo "overnight_campaign $(date -Is)" > "$SS_FILE"; SS_MINE=1; say "SENTINEL_STOP taken (ours)"
  else say "SENTINEL_STOP already present -- NOT ours, leaving it"; fi
fi
finish(){
  say "--- closing: default bring-up to put the pair back in service ---"
  if [ "$DRY" = 1 ]; then say "[dry] $D/bringup_r2r3.sh r3"
  else
    "$D/bringup_r2r3.sh" r3 >>"$L" 2>&1 && say "RESTORE_OK" || {
      say "restore attempt 1 failed; retrying"; sleep 30
      "$D/bringup_r2r3.sh" r3 >>"$L" 2>&1 && say "RESTORE_OK (attempt 2)" || say "RESTORE_FAILED -- rig NOT in service, needs the operator"; }
  fi
  [ "$SS_MINE" = 1 ] && { rm -f "$SS_FILE"; say "SENTINEL_STOP released"; }
  say "CAMPAIGN_DONE $OUT"
}
trap finish EXIT

say "=== overnight campaign until $DEADLINE: $CELLS cells x ${HOLD}s per experiment, rest ${REST_S}s, dry=$DRY ==="
consec=0; round=0; FAILS=0
while [ "$(date +%s)" -lt "$dl" ]; do
  round=$(( round + 1 )); say "--- round $round ---"
  for exp in selfdesense bandswap txpower agcpin; do
    [ "$(date +%s)" -lt "$dl" ] || break
    case $exp in
      selfdesense) run_exp selfdesense A_NAME=tx146_live B_NAME=tx146_MUTED B_HOOK="$mute146" B_UNHOOK="$unmute146" ;;
      bandswap)    run_exp bandswap A_NAME=normal \
                        A_ENV="LO_B_TX=2100000000 LO_A_RX=2100020000 LO_A_TX=1900000000 LO_B_RX=1900040000" \
                        B_NAME=swap \
                        B_ENV="LO_B_TX=1900000000 LO_A_RX=1900020000 LO_A_TX=2100000000 LO_B_RX=2100040000" ;;
      txpower)     run_exp txpower A_NAME=tx148_0dB B_NAME=tx148_m10dB B_HOOK="$tx148_low" B_UNHOOK="$tx148_full" ;;
      agcpin)      run_exp agcpin A_NAME=agc_auto B_NAME=agc_pinned34 B_HOOK="$pin146" B_UNHOOK="$unpin146" ;;
    esac
    if [ "${FAILS:-0}" -ge "$CELLS" ] 2>/dev/null; then consec=$(( consec + 1 )); else consec=0; fi
    if [ "$consec" -ge 3 ]; then say "ABORT: 3 consecutive experiments with every bring-up failing -- rig will not arm, stopping"; exit 1; fi
    [ "$DRY" = 1 ] || sleep "$REST_S"
  done
  [ "$DRY" = 1 ] && { say "[dry] one rotation shown; stopping"; break; }
done
say "deadline reached"
