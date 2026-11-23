# riglock.sh -- single-actor rig mutex (2026-08-27, after the self-arming reverse sweep
# overlapped a flash). Source it; call rig_lock <name> before touching either board and
# rig_unlock at exit. A runner that finds a foreign lock MUST refuse to start.
#
# SENTINEL_STOP ownership (2026-09-11): rig_unlock used to delete SENTINEL_STOP
# unconditionally, so a runner that took the lock while an OPERATOR hold was already in
# place removed that hold on exit. rig_lock now records whether it created the file
# (RIG_SS_MINE=1) and rig_unlock removes it only in that case. Paths are overridable
# for the desk test (ops/tests/test_rail_guards.py).
RIG_LOCK=${RIG_LOCK:-/home/tcollins/modem-status/RIG_LOCK}
RIG_SS=${SENTINEL_STOP_FILE:-/home/tcollins/modem-status/SENTINEL_STOP}
# RIG_LOCK_OWNER (2026-09-25): exported so the holder's CHILD processes pass ops/anyssh.sh's guard
# (Task 1 of docs/superpowers/plans/2026-09-25-rig-instability.md). The guard compares the lock
# file's owner= against this variable, not against a pid, because every rail runs its board calls
# from subshells and helper scripts whose $$ differs from the holder's.
rig_lock(){ if [ -e "$RIG_LOCK" ] && ! grep -q "pid=$$ " "$RIG_LOCK" 2>/dev/null; then
              echo "RIG_LOCKED by: $(cat "$RIG_LOCK") -- refusing to start ($1)"; exit 3; fi
            echo "owner=$1 pid=$$ since=$(date +%F_%T)" > "$RIG_LOCK"
            RIG_LOCK_OWNER=$1; export RIG_LOCK_OWNER
            if [ -e "$RIG_SS" ]; then RIG_SS_MINE=0; else touch "$RIG_SS"; RIG_SS_MINE=1; fi; }
rig_unlock(){ if grep -q "pid=$$ " "$RIG_LOCK" 2>/dev/null; then
                rm -f "$RIG_LOCK"; [ "${RIG_SS_MINE:-0}" = 1 ] && rm -f "$RIG_SS"; fi; return 0; }

# ---- lock-only API (2026-09-25, plan Task 2) --------------------------------------------------
# The campaign rails (gate3_pair, gate3_run, oneway_hw_verify, capture_r3) already implement the
# SENTINEL_STOP ownership rule themselves, shaped by several field incidents -- so they take the
# RIG_LOCK through these two and keep their own sentinel handling untouched.
#
# NESTING is required: gate3_pair holds the lock and then calls capture_r3.sh, which takes it again.
# A pid comparison cannot express that (the child is a different process), so ownership is by NAME:
# if the lock is already ours (owner matches the exported RIG_LOCK_OWNER) this is a no-op and the
# matching unlock does NOT release the parent's lock.
rig_lock_only(){ # $1 owner-name
  if [ -e "$RIG_LOCK" ]; then
    _rl_o=$(sed -n 's/^owner=\([^ ]*\).*/\1/p' "$RIG_LOCK" 2>/dev/null)
    if [ -n "${RIG_LOCK_OWNER:-}" ] && [ "$_rl_o" = "${RIG_LOCK_OWNER:-}" ]; then
      RIG_LOCK_NESTED=1; return 0
    fi
    echo "RIG_LOCKED by: $(cat "$RIG_LOCK") -- refusing to start ($1)"; exit 3
  fi
  echo "owner=$1 pid=$$ since=$(date +%F_%T)" > "$RIG_LOCK"
  RIG_LOCK_OWNER=$1; export RIG_LOCK_OWNER; RIG_LOCK_NESTED=0; return 0; }
rig_unlock_only(){ [ "${RIG_LOCK_NESTED:-0}" = 1 ] && return 0
                   if grep -q "pid=$$ " "$RIG_LOCK" 2>/dev/null; then rm -f "$RIG_LOCK"; fi; return 0; }
