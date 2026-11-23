#!/bin/bash
# =============================================================================
# plan_cells.sh -- interleaved A/B cells with a HOLD: arm on a plan, apply an optional post-arm
# hook, kill the watchdogs, then poll BOTH receivers at 1 Hz for HOLD seconds. Score with
# ops/plan_cells_score.py.
#
# WHY THIS SHAPE (2026-09-28, the day that produced it):
#   * Anything on the reverse leg measured ONCE after an arm measures time-since-the-arm. Two
#     experiments that day read a clean A/B contrast that was actually the clock. So every cell
#     HOLDS and the trace is scored in windows, and cells ALTERNATE so the question is whether
#     the statistic tracks the PLAN or the ORDER.
#   * The forward receiver (148) is armed by the same bring-up in the same seconds, so it is a
#     simultaneous control: a decay on 146 that 148 does not share is on 148-TX or 146-RX.
#   * Four experiments that day found the fault ABSENT when run by hand. A hold samples the
#     minutes after the arm where the decay lives, instead of the one instant the gate reads.
#   * The watchdogs MUST die before the poll: a watchdog re-arm mid-hold corrupts the trace and
#     breaks the standing rule that nothing reads registers while an arm is in flight. The
#     closing restore bring-up relaunches them.
#
# A plan is: NAME, an ENV string handed to bringup_r2r3.sh (LO overrides etc, may be empty), and
# a HOOK -- a host-side shell snippet run after the arm and before the hold (e.g. mute a
# transmitter, pin an AGC). Hooks touch only IIO sysfs attributes; they never write modem
# registers. The re-arm of the next cell undoes a hook's effect, and UNHOOK is run anyway.
#
# Env (all required unless defaulted):
#   OUT=<dir>  CELLS=4  HOLD=240  RUNG=r3  GATE_DIR=both|A|B  GATE_TRIES=3
#   A_NAME= A_ENV= A_HOOK= A_UNHOOK=      B_NAME= B_ENV= B_HOOK= B_UNHOOK=
#   RESTORE=1  (closing default bring-up; 0 leaves the pair on the last cell -- campaign use)
#   DRY=1      (print the sequence, touch nothing)
# Always under launch_rig_unit.sh: it arms boards.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
A=10.0.0.148; B=10.0.0.146
OUT=${OUT:?OUT=<dir>}; CELLS=${CELLS:-4}; HOLD=${HOLD:-240}; RUNG=${RUNG:-r3}
GATE_DIR=${GATE_DIR:-both}; GATE_TRIES=${GATE_TRIES:-3}; RESTORE=${RESTORE:-1}; DRY=${DRY:-0}
A_NAME=${A_NAME:-A}; A_ENV=${A_ENV:-}; A_HOOK=${A_HOOK:-}; A_UNHOOK=${A_UNHOOK:-}
B_NAME=${B_NAME:-B}; B_ENV=${B_ENV:-}; B_HOOK=${B_HOOK:-}; B_UNHOOK=${B_UNHOOK:-}
mkdir -p "$OUT"; L=$OUT/plan_cells.log; T=$OUT/cells.tsv
say(){ echo "$(date -Is) $*" | tee -a "$L"; }
say "=== plan_cells: $CELLS cells x ${HOLD}s hold, rung $RUNG, gate_dir=$GATE_DIR, dry=$DRY, out=$OUT ==="
say "    A=$A_NAME env=[$A_ENV] hook=[$A_HOOK]"
say "    B=$B_NAME env=[$B_ENV] hook=[$B_HOOK]"
printf 'cell\tplan\tgate_148\tgate_146\tbringup_rc\tcsv_148\tcsv_146\n' > "$T"

kill_watchdogs(){ for ip in $A $B; do
  $W $ip 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null
   pkill -9 -f "[l]ock_watchdog" 2>/dev/null; echo wd-stopped' 2>/dev/null | tail -1 | sed "s/^/  $ip /" | tee -a "$L"
done; }

poll(){ # $1 ip $2 outfile -- one persistent reader per board, 1 s cadence (never faster)
  $W "$1" "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
   P=/sys/bus/iio/devices/iio:device2
   echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
   end=\$(( \$(date +%s) + $HOLD ))
   while [ \$(date +%s) -lt \$end ]; do
     echo 0x104 > \$DRA; p=\$(cat \$DRA)
     echo 0x154 > \$DRA; c=\$(cat \$DRA)
     echo 0x150 > \$DRA; r=\$(cat \$DRA)
     echo \"\$(date +%s),\$p,\$c,\$r,\$(cat \$P/in_voltage0_rssi 2>/dev/null | cut -d' ' -f1),\$(cat \$P/in_voltage0_decimated_power 2>/dev/null | cut -d' ' -f1),\$(cat \$P/in_voltage0_hardwaregain 2>/dev/null | cut -d' ' -f1)\"
     sleep 1
   done" 2>/dev/null > "$2"
}

i=0
while [ "$i" -lt "$CELLS" ]; do
  i=$(( i + 1 ))
  case $(( i % 2 )) in
    1) plan=$A_NAME; penv=$A_ENV; hook=$A_HOOK; unhook=$A_UNHOOK ;;
    0) plan=$B_NAME; penv=$B_ENV; hook=$B_HOOK; unhook=$B_UNHOOK ;;
  esac
  say "--- cell $i: plan=$plan env=[$penv] ---"
  if [ "$DRY" = 1 ]; then
    say "[dry] env $penv GATE_TRIES=$GATE_TRIES GATE_DIR=$GATE_DIR $D/bringup_r2r3.sh $RUNG"
    say "[dry] kill watchdogs; hook=[$hook]; poll both ${HOLD}s; unhook=[$unhook]"
    printf '%d\t%s\t-\t-\tdry\t-\t-\n' "$i" "$plan" >> "$T"; continue
  fi
  cl=$OUT/cell${i}_${plan}.bringup.log
  # shellcheck disable=SC2086
  env $penv GATE_TRIES=$GATE_TRIES GATE_DIR=$GATE_DIR "$D/bringup_r2r3.sh" "$RUNG" > "$cl" 2>&1; rc=$?
  last=$(grep '^gate try' "$cl" | tail -1)
  ga=$(echo "$last" | sed -n 's/.*148 rx=\([0-9]*\) f\/s.*/\1/p'); ga=${ga:-0}
  gb=$(echo "$last" | sed -n 's/.*146 rx=\([0-9]*\) f\/s.*/\1/p'); gb=${gb:-0}
  say "  bring-up rc=$rc  gate: 148 rx=$ga  146 rx=$gb"
  kill_watchdogs
  if [ -n "$hook" ]; then say "  hook: $hook"; eval "$hook" 2>&1 | sed 's/^/    /' | tee -a "$L"; sleep 3; fi
  ca=$OUT/cell${i}_${plan}.148.csv; cb=$OUT/cell${i}_${plan}.146.csv
  ( . "$D/sim_repro/riglock.sh"; rig_lock "plancell-$$" >/dev/null 2>&1 || exit 3
    trap 'rig_unlock' EXIT
    poll $B "$cb" & pb=$!; poll $A "$ca" & pa=$!; wait $pb $pa )
  say "  hold done: 148 rows=$(wc -l < "$ca")  146 rows=$(wc -l < "$cb")"
  if [ -n "$unhook" ]; then eval "$unhook" >/dev/null 2>&1; fi
  printf '%d\t%s\t%s\t%s\t%s\t%s\t%s\n' "$i" "$plan" "$ga" "$gb" "$rc" "$(basename "$ca")" "$(basename "$cb")" >> "$T"
  python3 "$D/plan_cells_score.py" --one "$ca" "$cb" 2>&1 | sed 's/^/  /' | tee -a "$L"
done

if [ "$RESTORE" = 1 ]; then
  say "--- restore: default bring-up (relaunches watchdogs, puts the pair back in service) ---"
  if [ "$DRY" = 1 ]; then say "[dry] $D/bringup_r2r3.sh $RUNG"
  else "$D/bringup_r2r3.sh" "$RUNG" >>"$L" 2>&1 && say "RESTORE_OK" || say "RESTORE_FAILED -- rig NOT in service"; fi
fi
say "PLAN_CELLS_DONE $OUT"
[ "$DRY" = 1 ] || python3 "$D/plan_cells_score.py" "$OUT" 2>&1 | tee -a "$L"
