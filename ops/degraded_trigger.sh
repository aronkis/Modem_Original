#!/bin/bash
# =============================================================================
# degraded_trigger.sh -- watch the delivery sentinel's log and record when the REVERSE leg falls
# into a sustained degraded episode, so a degraded session can be worked deliberately instead of
# waited for. Proposed in docs/evidence/link/REVERSE_LEG_AVAILABILITY.md sec 4.
#
# IT READS LOCAL FILES ONLY. No ssh, no register access, no arm -- nothing it does can hang a
# board. That is deliberate: this runs unattended, possibly at 03:00 with nobody to power-cycle.
#
#   ops/degraded_trigger.sh                       # watch, record on a sustained episode
#   ops/launch_rig_unit.sh degtrig ops/degraded_trigger.sh OUT=/path
#   ONESHOT=1 ops/degraded_trigger.sh             # evaluate once and exit (what the tests use)
#
# Env: THRESH=0.75 CONSEC=5 MIN_BAD=4 POLL_S=60 FRESH_S=900 COOLDOWN_S=21600 OUT=<dir> ACTION="<command>"
#      LOG=<sentinel log> RIG_LOCK=<path> SS_FILE=<path> KEEPER_UNIT=<glob> KEEPER_CHECK=1
#
# THE RATIO. The sentinel's four counters are TWO PER BOARD (see sec 1 of the evidence file, and
# ops/sentinel_stats.py):
#     rate = 148 idle_rx  FORWARD receive      tx  = 148 dma_tx  REVERSE source
#     rev  = 146 idle_rx  REVERSE receive      rtx = 146 dma_tx  FORWARD source
# so rev/rtx is 146's receive over its OWN transmit: mode-free (the 1.5x "high mode" cancels) but
# NOT a delivery ratio. It is the trigger quantity because it is computable on every sample. The
# true cross-board delivery rev/tx is recorded alongside whenever both boards share a window mode.
#
# WHY 4 OF THE LAST 5, BELOW 0.75. The sentinel samples about every 5 minutes, so N samples span
# (N-1) intervals: 5 samples is roughly 20 minutes of wall clock. A short debounce fires mostly on
# blips that are over before anything can be done -- of 93 episodes below 0.5 measured over
# 2026-09-16..09-26, 68 were a single sample, while the 6 that lasted >= 30 min held 81 % of all
# observed degraded time.
#
# The first version demanded ALL FIVE below 0.5 and that is the wrong SHAPE. Real episodes fluctuate:
# on 2026-09-27 13:10-13:46 the ratio ran 0.91 0.90 0.94 0.40 0.89 0.81 0.58 0.60 0.21 0.66 -- plainly
# degraded (reverse CRC hit 48 %) yet never five in a row below 0.5, so the trigger correctly did
# nothing while a usable window went by. Two changes, both measured by simulating rules over 2719
# quiet samples spanning 10.9 days (the same 6 h cooldown applied):
#
#     rule                fires    per day
#     < 0.50, 5 of 5          7       0.64   <- the original
#     < 0.75, 5 of 5         10       0.91
#     < 0.75, 4 of 5         11       1.01   <- now the default; catches the 09-27 stretch
#     < 0.75, 3 of 5         15       1.37
#     < 0.75, 2 of 3         19       1.74
#
# 0.75 is also the threshold the availability measurement itself used to define "degraded"
# (REVERSE_LEG_AVAILABILITY.md sec 2), so the trigger and the measurement now agree on the word.
# NOTE THE COST: about one unattended board arm per day instead of one every day and a half. Revert
# with THRESH=0.5 MIN_BAD=5 in the unit's environment if that is too much.
#
# WHY IT STANDS DOWN. Three ways this could fire on its own blind spot rather than on the link:
#   * a STALE log -- the sentinel exits on SENTINEL_STOP and stays dead until the keeper's 120 s
#     loop relaunches it, so the last line can be 40 minutes old and look like a dead link. The
#     newest sample must be younger than FRESH_S.
#   * the KEEPER not running -- then nothing is refreshing the log at all, and freshness can still
#     pass on a recent-but-final sample.
#   * RIG_LOCK or SENTINEL_STOP present -- the rig is being worked on and the log is contaminated.
#
# COOLDOWN. After firing it waits COOLDOWN_S (6 h) before it can fire again. The last fire time is
# PERSISTED to $OUT/.last_fire, because an in-memory-only cooldown resets whenever the unit is
# restarted -- on 2026-09-27 two restarts each produced an immediate extra capture while the link
# happened to be degraded, which is exactly the unattended arming the cooldown exists to bound. The long episodes
# CLUSTER (4 of the 6 were on 09-22, 2 on 09-26), so this deliberately suppresses later episodes
# on a bad day: it means the trigger UNDERCOUNTS episodes, which is the right trade for something
# that runs unattended.
#
# ACTION is empty by default and the unit only records. Wiring it to a capture arms boards; wiring
# it to a flash campaign takes the production link down. Both are the operator's explicit choice,
# not a default, and neither is shipped here.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd)
LOG=${LOG:-$HOME/modem-status/sentinel.log}
OUT=${OUT:-$D/r3cap/degraded}
# THRESH / CONSEC / MIN_BAD: fire when at least MIN_BAD of the last CONSEC samples are below
# THRESH. Retuned 2026-09-27 against 2719 quiet samples over 10.9 days -- see the block below.
THRESH=${THRESH:-0.75}; CONSEC=${CONSEC:-5}; MIN_BAD=${MIN_BAD:-4}; POLL_S=${POLL_S:-60}
# FRESH_S: the sentinel's measured cadence is median 305 s, p99 318 s (3059 intervals, 09-16..09-27),
# so 900 s is nearly 3x nominal and still far below the ~2400 s a keeper-restart gap produces. At the
# original 700 s, 0.52 % of samples read as stale against 0.16 % at 900 s.
FRESH_S=${FRESH_S:-900}; COOLDOWN_S=${COOLDOWN_S:-21600}
RIG_LOCK=${RIG_LOCK:-$HOME/modem-status/RIG_LOCK}
SS_FILE=${SS_FILE:-$HOME/modem-status/SENTINEL_STOP}
KEEPER_UNIT=${KEEPER_UNIT:-sentinelkeeper*}; KEEPER_CHECK=${KEEPER_CHECK:-1}
ACTION=${ACTION:-}
mkdir -p "$OUT"
JLOG=$OUT/trigger.log
say(){ echo "[$(date +%F_%T)] $*" | tee -a "$JLOG"; }

# standdown: prints a reason and returns 0 when the trigger must NOT act
standdown(){
  [ -e "$RIG_LOCK" ] && { echo "RIG_LOCK present ($(cat "$RIG_LOCK" 2>/dev/null | head -1))"; return 0; }
  [ -e "$SS_FILE" ]  && { echo "SENTINEL_STOP present -- rig work in progress"; return 0; }
  if [ "$KEEPER_CHECK" = 1 ]; then
    systemctl --user list-units --state=active "$KEEPER_UNIT" 2>/dev/null | grep -q sentinelkeeper \
      || { echo "sentinel keeper unit not active -- the log is not being refreshed"; return 0; }
  fi
  return 1
}

# tail_samples <n>: the last n "ok" sample lines, oldest first
tail_samples(){ grep ' ok rate=' "$LOG" 2>/dev/null | tail -n "$1"; }

# sample_age_s: seconds since the newest sample's timestamp ("" if unparsable)
sample_age_s(){
  local l ts
  l=$(tail_samples 1); [ -n "$l" ] || return 1
  ts=${l%% *}; ts=${ts/_/ }
  local e; e=$(date -d "$ts" +%s 2>/dev/null) || return 1
  echo $(( $(date +%s) - e ))
}

# field <line> <key>
field(){ echo "$1" | grep -oE "\b$2=[0-9.]+" | head -1 | cut -d= -f2; }

# ratio <line>: rev/rtx to three decimals, "" when it cannot be computed
ratio(){
  local rev rtx; rev=$(field "$1" rev); rtx=$(field "$1" rtx)
  [ -n "$rev" ] && [ -n "$rtx" ] || return 1
  awk -v a="$rev" -v b="$rtx" 'BEGIN{ if (b+0==0) exit 1; printf "%.3f", a/b }'
}

# cross <line>: the TRUE delivery ratio rev/tx, only when both boards share a window mode
cross(){
  local rev tx rtx; rev=$(field "$1" rev); tx=$(field "$1" tx); rtx=$(field "$1" rtx)
  [ -n "$rev" ] && [ -n "$tx" ] && [ -n "$rtx" ] || return 1
  awk -v r="$rev" -v t="$tx" -v x="$rtx" 'BEGIN{
    if (t+0==0 || x+0==0) exit 1
    m = (t>x ? t : x); if ((t>x ? t-x : x-t)/m >= 0.02) exit 1   # different window modes
    printf "%.3f", r/t }'
}

# how many of the last CONSEC samples are below THRESH, and are they ALL below
evaluate(){
  local n=0 tot=0 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    local rr; rr=$(ratio "$line") || continue
    tot=$(( tot + 1 ))
    awk -v a="$rr" -v t="$THRESH" 'BEGIN{exit !(a<t)}' && n=$(( n + 1 ))
  done <<< "$(tail_samples "$CONSEC")"
  echo "$n $tot"
}

fire(){
  local rr="$1" stamp dir last
  : "${bad_at_fire:=$CONSEC}"
  stamp=$(date +%Y%m%d_%H%M%S); dir=$OUT/episode_$stamp
  # the cooldown makes a same-second collision impossible in normal operation, but silently
  # overwriting an episode record would lose the only artefact of a firing
  _n=1; while [ -e "$dir" ]; do dir=$OUT/episode_${stamp}_$_n; _n=$(( _n + 1 )); done
  mkdir -p "$dir"
  last=$(tail_samples 1)
  {
    echo "fired_at=$(date -Is)"
    echo "trigger=rev/rtx < $THRESH on $bad_at_fire of the last $CONSEC samples (~$(( (CONSEC-1)*5 )) min of wall clock)"
    echo "ratio_now=$rr   (rev/rtx: 146 receive over its OWN transmit, mode-free, NOT a delivery ratio)"
    echo "note=ratio_now is the NEWEST sample and may sit ABOVE the threshold; the rule looks at a window"
    echo "cross_now=$(cross "$last" || echo 'n/a -- boards in different window modes this sample')"
    echo "episode_observed_min=$2"
    # report what was actually checked: KEEPER_CHECK=0 means the keeper was NOT verified, and a
    # record that claims otherwise is a false statement in the one artefact a human reads later
    echo "standdown_checks=passed: no RIG_LOCK, no SENTINEL_STOP, log fresh (< ${FRESH_S}s); keeper$([ "$KEEPER_CHECK" = 1 ] && echo " active" || echo " NOT CHECKED (KEEPER_CHECK=0)")"
    echo "sample_age_s=$(sample_age_s)"
    echo "action=${ACTION:-<none: record-only>}"
    echo
    echo "--- last 20 sentinel samples (oldest first) ---"
    tail_samples 20
  } > "$dir/EPISODE.txt"
  say "DEGRADED_EPISODE ratio=$rr observed=${2}min -> $dir/EPISODE.txt"
  if [ -n "$ACTION" ]; then
    say "running ACTION: $ACTION"
    ( cd "$D" && eval "$ACTION" ) >> "$dir/action.log" 2>&1
    say "ACTION finished rc=$?"
  else
    say "record-only (ACTION unset): a human decides whether this window is worth working"
  fi
}

say "degraded trigger watching $LOG: rev/rtx < $THRESH on $MIN_BAD of the last $CONSEC samples, poll ${POLL_S}s, cooldown ${COOLDOWN_S}s, action=${ACTION:-<none>}"
# survive a restart: a cooldown that lives only in this process resets every time the unit is
# relaunched, and the whole point of it is to bound how often the boards get armed
FIRE_STAMP=$OUT/.last_fire
LAST_FIRE=0
if [ -r "$FIRE_STAMP" ]; then
  _lf=$(tr -dc '0-9' < "$FIRE_STAMP")
  if [ -n "$_lf" ]; then
    LAST_FIRE=$_lf
    _left=$(( COOLDOWN_S - ($(date +%s) - LAST_FIRE) ))
    [ "$_left" -gt 0 ] && say "cooldown carried over from a previous run: ${_left}s left (last fire $(date -d @"$LAST_FIRE" +%F_%T))"
  fi
fi
while :; do
  while :; do   # one evaluation pass
    if reason=$(standdown); then say "standdown: $reason"; break; fi
    age=$(sample_age_s) || { say "standdown: cannot read a timestamp from $LOG"; break; }
    if [ "$age" -gt "$FRESH_S" ]; then
      say "standdown: newest sample is ${age}s old (> ${FRESH_S}s) -- stale log, not a dead link"; break
    fi
    now=$(date +%s)
    if [ $(( now - LAST_FIRE )) -lt "$COOLDOWN_S" ]; then
      break   # cooling down; stay quiet rather than journalling every poll
    fi
    set -- $(evaluate); bad=$1; tot=$2
    if [ "$tot" -lt "$CONSEC" ]; then say "standdown: only $tot usable samples, need $CONSEC"; break; fi
    if [ "$bad" -ge "$MIN_BAD" ]; then
      rr=$(ratio "$(tail_samples 1)")
      bad_at_fire=$bad
      fire "$rr" "$(( (CONSEC-1)*5 ))"
      LAST_FIRE=$(date +%s); echo "$LAST_FIRE" > "$FIRE_STAMP"
    fi
    break
  done
  [ "${ONESHOT:-0}" = 1 ] && break
  sleep "$POLL_S"
done
