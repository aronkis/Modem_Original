#!/bin/bash
# oneway_hw_verify.sh -- the ONE-DIRECTIONAL images' silicon verification, end to end,
# unattended:  flash TXO/RXO, bring up, measure, (swap direction, repeat), RESTORE the pair.
#
#   ops/oneway_hw_verify.sh [fwd|both|restore]  default both  (fwd = 146 TX -> 148 RX only;
#                                                 restore = only put the pair back)
#
# Env: DWELL=120 (rom measure seconds), BYTE=1 (also run the qpsk_tun -B source phase,
#      non-fatal), TUN=1 (also run the one-way tun/UDP phase, non-fatal), RESTORE_ROLES="146:B 148:A" (images/CURRENT.txt roles to put back),
#      SENTINEL_STOP_FILE, DRY=1 (print the plan; touches nothing).
#
# Halt policy (docs/build-and-flash.rst "Flashing"): ANY failure after the first flash
# halts the experiment and rolls BOTH boards back to their CURRENT.txt roles, re-runs the
# pair bring-up, and exits non-zero. No retry variants. Every board write goes through
# ops/deploy_image.sh (size-checked, backed up as /boot/BOOT.BIN.oneway, md5 read back).
set -u
D=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$D/.." && pwd)
MODE=${1:-${MODE:-both}}; DWELL=${DWELL:-120}; BYTE=${BYTE:-1}; DRY=${DRY:-0}
B146=10.0.0.146; B148=10.0.0.148
RESTORE_ROLES=${RESTORE_ROLES:-"$B146:B $B148:A"}
SS_FILE=${SENTINEL_STOP_FILE:-$HOME/modem-status/SENTINEL_STOP}
LOG=${LOG:-/mnt/onetb/scratch/qpsk-build-trees/oneway/hw_verify.log}
say(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
run(){ if [ "$DRY" = 1 ]; then say "[DRY] $*"; return 0; fi; say "+ $*"; "$@" 2>&1 | tee -a "$LOG"; return ${PIPESTATUS[0]}; }
role_md5(){ grep -E "^$1 " "$ROOT/images/CURRENT.txt" | head -1 | awk '{print $3}'; }
board_md5(){ timeout 60 "$D/anyssh.sh" "$1" 'md5sum /boot/BOOT.BIN | cut -c1-32' 2>/dev/null | tail -1; }

mkdir -p "$(dirname "$LOG")"; : >> "$LOG"
say "=== ONE-WAY HW VERIFY mode=$MODE dwell=${DWELL}s byte=$BYTE dry=$DRY ==="
for r in TXO RXO; do [ -n "$(role_md5 $r)" ] || { say "FATAL: no role $r in images/CURRENT.txt"; exit 2; }; done
for ip in $B146 $B148; do
  [ "$DRY" = 1 ] || timeout 40 "$D/anyssh.sh" $ip 'echo up' 2>/dev/null | grep -q up || { say "FATAL: $ip unreachable"; exit 1; }
done
say "before: 146=$(board_md5 $B146) 148=$(board_md5 $B148)"

# ---- sentinel ownership (rail contract): only touch it if it is ours ----------
# rig mutex (plan 2026-09-25 Task 2): hold it for the whole run so ad-hoc board access is
# refused at ops/anyssh.sh while this rail owns the rig. Nesting-safe.
. "$D/sim_repro/riglock.sh"
[ "$DRY" = 1 ] || rig_lock_only "oneway_hw_verify"
SS_MINE=0
if [ "$DRY" != 1 ]; then
  if [ -e "$SS_FILE" ]; then say "SENTINEL_STOP pre-exists (external hold) -- left alone"; else echo "oneway_hw_verify $(date -Is)" > "$SS_FILE"; SS_MINE=1; say "SENTINEL_STOP taken"; fi
fi
release(){ rig_unlock_only; [ "$SS_MINE" = 1 ] && rm -f "$SS_FILE" && say "SENTINEL_STOP released"; return 0; }

FLASHED=0
restore_pair(){
  say "--- RESTORE the pair: $RESTORE_ROLES ---"
  for pr in $RESTORE_ROLES; do ip=${pr%%:*}; role=${pr##*:}
    if [ "$(board_md5 $ip)" = "$(role_md5 $role)" ] && [ "$DRY" != 1 ]; then say "$ip already on role $role"; continue; fi
    run env SUFFIX=.oneway "$D/deploy_image.sh" $ip $role || say "RESTORE_WARN deploy $ip $role returned non-zero"
    [ "$DRY" = 1 ] || [ "$(board_md5 $ip)" = "$(role_md5 $role)" ] || { say "RESTORE_FAIL $ip not on role $role md5=$(board_md5 $ip) -- PHYSICAL ATTENTION"; return 1; }
  done
  # the PAIR bring-up must not inherit one-way knobs (RXM/RXQ select the RX-only daemon mode;
  # 2026-09-17 they leaked into the restore and the pair came up in legacy -M 0 at half the
  # byte-plane rate, wcnt 660 vs 1267)
  run env -u RXM -u RXQ -u RXM_A -u RXM_B -u DAEMON_ENV "$D/bringup_r2r3.sh" r3 || { say "RESTORE_WARN bringup_r2r3 r3 non-zero"; return 1; }
  say "restore health: 146 $($D/health_probe_reset_aware.sh $B146 12 2>/dev/null | tail -1)  148 $($D/health_probe_reset_aware.sh $B148 12 2>/dev/null | tail -1)"
  return 0
}
halt(){ say "HALT: $*"; [ "$FLASHED" = 1 ] && restore_pair; release; say "ONEWAY_HW_VERIFY FAIL"; exit 1; }

flash(){ # $1 ip $2 role
  run env SUFFIX=.oneway "$D/deploy_image.sh" "$1" "$2" || halt "deploy $1 $2 failed"
  FLASHED=1
  [ "$DRY" = 1 ] || [ "$(board_md5 $1)" = "$(role_md5 $2)" ] || halt "$1 md5 after flash $(board_md5 $1) != role $2 $(role_md5 $2)"
  say "$1 now on $2"
}
leg(){ # $1 tx_ip $2 rx_ip $3 label
  say "--- LEG $3: TX=$1 -> RX=$2 ---"
  flash "$1" TXO; flash "$2" RXO
  run "$D/oneway_bringup.sh" "$1" "$2" rom || halt "leg $3: bring-up gate failed"
  run "$D/oneway_measure.sh" "$2" "$DWELL" rom || halt "leg $3: measure failed"
  if [ "$BYTE" = 1 ]; then
    run "$D/oneway_bringup.sh" "$1" "$2" byte || say "leg $3: byte-source bring-up non-zero (non-fatal)"
    run "$D/oneway_measure.sh" "$2" 60 byte || say "leg $3: byte measure non-zero (non-fatal)"
  fi
  if [ "${TUN:-1}" = 1 ]; then
    run "$D/oneway_bringup.sh" "$1" "$2" tun || say "leg $3: tun bring-up non-zero (non-fatal)"
    run "$D/oneway_measure.sh" "$2" 60 tun || say "leg $3: tun measure non-zero (non-fatal)"
  fi
  say "--- LEG $3 done ---"
}

if [ "$MODE" = restore ]; then
  say "restore-only run"
else
  leg $B146 $B148 fwd
  if [ "$MODE" = both ]; then leg $B148 $B146 rev; fi
fi

restore_pair || { release; say "ONEWAY_HW_VERIFY DONE-BUT-RESTORE-INCOMPLETE"; exit 1; }
release
say "after: 146=$(board_md5 $B146) 148=$(board_md5 $B148)"
say "ONEWAY_HW_VERIFY DONE mode=$MODE (see $LOG; grep ONEWAY_MEASURE for the numbers)"
