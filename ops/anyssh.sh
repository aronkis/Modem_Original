#!/bin/sh
# usage: anyssh.sh <ip> '<remote cmd>'
#
# RIG MUTEX GUARD (2026-09-25, plan docs/superpowers/plans/2026-09-25-rig-instability.md Task 1).
# Every board access in this repo goes through this script, so this is where the single-actor rule
# is enforced. ops/sim_repro/riglock.sh has implemented the mutex since 2026-08-27 and nothing made
# anyone take it: on 2026-09-25 a settle-timer's direct_reg_access reads collided with the delivery
# sentinel's own recovery chain (which arms both boards) and 148 hung -- no software recovery,
# Jupiter has no remote power, it took a physical power cycle.
#
# Rule: if a rig lock is held by SOMEONE ELSE, refuse before reaching ssh. The holder's own children
# pass because rig_lock exports RIG_LOCK_OWNER and the file records the same owner name.
# RIG_LOCK_BYPASS=1 is the documented emergency escape and announces itself.
IP="$1"; shift
RIG_LOCK=${RIG_LOCK:-/home/tcollins/modem-status/RIG_LOCK}
if [ -e "$RIG_LOCK" ]; then
  _rl_owner=$(sed -n 's/^owner=\([^ ]*\).*/\1/p' "$RIG_LOCK" 2>/dev/null)
  if [ "${RIG_LOCK_BYPASS:-0}" = 1 ]; then
    echo "RIG_LOCK_BYPASS=1 -- proceeding despite: $(cat "$RIG_LOCK" 2>/dev/null)" >&2
  elif [ "$_rl_owner" != "${RIG_LOCK_OWNER:-}" ]; then
    echo "RIG_LOCKED by: $(cat "$RIG_LOCK" 2>/dev/null) -- refusing $IP '$*'" >&2
    exit 3
  fi
fi
# Resolve the askpass helper next to THIS script (portable across sessions).
D=$(cd "$(dirname "$0")" && pwd)
SSH_ASKPASS="$D/askpass.sh" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
  setsid -w ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
  -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  root@"$IP" "$@" < /dev/null
