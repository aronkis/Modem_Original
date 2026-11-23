#!/bin/bash
# soak_pair.sh -- plan Phase 5: a long soak of the pair with INCREMENTAL verdicts, files only.
#
#   soak_pair.sh [HOURS=4] [INTERVAL_S=600] [OUT=ops/r3cap/soak_<stamp>] [SINCE='YYYY-MM-DD HH:MM']
#   DRY=1 pulls nothing and scores the newest wdlog snapshots already in ~/modem-status.
#
# Every INTERVAL_S it pulls /dev/shm/watchdog.log from both boards (a FILE read over anyssh --
# no register traffic, refused under a foreign RIG_LOCK like every board access), snapshots
# them to ~/modem-status/wdlog_10.0.0.<ip>_<stamp>.txt, runs ops/soak_score.py over the window
# SINCE..now and appends the verdict lines to $OUT/status.txt (one block per tick; tail it).
# Acceptance is soak_score's: 0 fabric resets in LOCKED windows, 0 storms, 0 FULL RE-ARMs,
# 0 daemon relaunches / wedges, 0 sentinel recoveries, window >= HOURS. A FAIL is recorded and the
# soak KEEPS RUNNING (the failing board's count is the finding); SOAK_PAIR_DONE at the end.
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
HOURS=${HOURS:-4}; INTERVAL_S=${INTERVAL_S:-600}; SINCE=${SINCE:-$(date '+%Y-%m-%d %H:%M')}
OUT=${OUT:-$D/r3cap/soak_$(date +%Y%m%d_%H%M)}; mkdir -p "$OUT"; ST=$OUT/status.txt
A=10.0.0.148; B=10.0.0.146
say(){ echo "[$(date '+%F %T')] $*" | tee -a "$ST"; }
pull(){ # -> path of a fresh snapshot for $1 (or the newest existing one in DRY)
  local ip=$1 s; s=$(date +%Y%m%d_%H%M%S)
  if [ "${DRY:-0}" = 1 ]; then ls -t ~/modem-status/wdlog_${ip}_*.txt 2>/dev/null | head -1; return; fi
  $W "$ip" 'cat /dev/shm/watchdog.log' > ~/modem-status/wdlog_${ip}_$s.txt 2>/dev/null && echo ~/modem-status/wdlog_${ip}_$s.txt
}
say "SOAK_PAIR start since='$SINCE' hours=$HOURS interval=${INTERVAL_S}s out=$OUT dry=${DRY:-0}"
END=$(( $(date +%s) + HOURS * 3600 )); n=0
while :; do
  n=$((n+1)); fa=$(pull $A); fb=$(pull $B)
  { echo "--- tick $n $(date '+%F %T') wd148=$(basename "${fa:-none}") wd146=$(basename "${fb:-none}")"
    python3 "$D/soak_score.py" --since "$SINCE" --hours "$HOURS" ${fb:+--wd $B=$fb} ${fa:+--wd $A=$fa}
    echo "  sentinel tail: $(tail -n 1 ~/modem-status/sentinel.log 2>/dev/null | cut -c1-100)"
  } | tee -a "$ST"
  [ "${DRY:-0}" = 1 ] && break
  [ "$(date +%s)" -ge "$END" ] && break
  sleep "$INTERVAL_S"
done
say "SOAK_PAIR_DONE ticks=$n verdict=$(grep -oE 'SOAK_VERDICT (PASS|FAIL)' "$ST" | tail -1 | awk '{print $2}')"
