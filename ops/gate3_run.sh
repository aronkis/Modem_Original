#!/bin/bash
# gate3_run.sh -- Gate 3 (silicon, the PAIR) for a candidate image already flashed on BOTH
# boards, in the shape the sp3txclk gate used (docs/evidence/sp3/SP3_GATE3_RETEST.md 9.4,
# "0 bad arms of 11"): 6 reverse arms x 180 s, 3 forward arms x 180 s, then one 600 s window
# per direction, every capture scored by accept_analyze.py (live-link window, lost frames in
# the denominator). Then ROLLBACK both boards to their images/CURRENT.txt roles (default on).
#
#   ops/gate3_run.sh <md5-12> <tag>          e.g. gate3_run.sh b68dbf1d9321 sp3prod
#   (as a rig unit: launch_rig_unit.sh <unit> ops/gate3_run.sh GATE3_MD5=<md5-12> GATE3_TAG=<tag> OUT=<dir>)
#
# Env: REV_ARMS=6 FWD_ARMS=3 ARM_S=180 LONG_S=600 ROLLBACK=1 ROLLBACK_ROLES="10.0.0.148:A 10.0.0.146:B"
#      OUT (default ops/r3cap/gate3_<tag>_<ts>) DRY=1 (print the plan; touches nothing)
# Exit: 0 all captures scored and rollback done; 1 otherwise. The verdict itself is in the
# summary (bad arms / PER), never inferred from the exit code.
set -u
D=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$D/.." && pwd)
EXP=${1:-${GATE3_MD5:-}}; TAG=${2:-${GATE3_TAG:-}}   # args, or GATE3_MD5/GATE3_TAG env (launch_rig_unit.sh passes env only)
[ -n "$EXP" ] && [ -n "$TAG" ] || { echo "usage: gate3_run.sh <md5-12> <tag>   (or GATE3_MD5= GATE3_TAG= env)"; exit 2; }
REV_ARMS=${REV_ARMS:-6}; FWD_ARMS=${FWD_ARMS:-3}; ARM_S=${ARM_S:-180}; LONG_S=${LONG_S:-600}
ROLLBACK=${ROLLBACK:-1}; ROLLBACK_ROLES=${ROLLBACK_ROLES:-"10.0.0.148:A 10.0.0.146:B"}; DRY=${DRY:-0}
OUT=${OUT:-$D/r3cap/gate3_${TAG}_$(date +%Y%m%d_%H%M%S)}; mkdir -p "$OUT"; LOG=$OUT/gate3.log
SS_FILE=${SENTINEL_STOP_FILE:-$HOME/modem-status/SENTINEL_STOP}
say(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
run(){ if [ "$DRY" = 1 ]; then say "[DRY] $*"; return 0; fi; say "+ $*"; "$@" 2>&1 | tee -a "$LOG"; return ${PIPESTATUS[0]}; }
board_md5(){ timeout 60 "$D/anyssh.sh" "$1" 'md5sum /boot/BOOT.BIN | cut -c1-12' 2>/dev/null | tail -1; }
role_md5(){ grep -E "^$1 " "$ROOT/images/CURRENT.txt" | head -1 | awk '{print substr($3,1,12)}'; }

say "=== GATE 3 $TAG $EXP: ${REV_ARMS}x rev ${ARM_S}s, ${FWD_ARMS}x fwd ${ARM_S}s, rev+fwd ${LONG_S}s; rollback=$ROLLBACK  out=$OUT ==="
# rig mutex (plan 2026-09-25 Task 2): hold it for the whole run so ad-hoc board access is
# refused at ops/anyssh.sh while this rail owns the rig. Nesting-safe.
. "$D/sim_repro/riglock.sh"
[ "$DRY" = 1 ] || rig_lock_only "gate3_run-$TAG"
if [ "$DRY" != 1 ]; then
  for ip in 10.0.0.146 10.0.0.148; do
    m=$(board_md5 $ip); [ "$m" = "$EXP" ] || { say "FATAL: $ip is on $m, not the candidate $EXP -- flash both boards first (ops/flash rails)"; exit 1; }
  done
  SS_MINE=0
  if [ -e "$SS_FILE" ]; then say "SENTINEL_STOP pre-exists (external hold) -- left alone"; else echo "gate3_run $TAG $(date -Is)" > "$SS_FILE"; SS_MINE=1; say "SENTINEL_STOP taken"; fi
else SS_MINE=0; fi
release(){ rig_unlock_only; [ "$SS_MINE" = 1 ] && rm -f "$SS_FILE" && say "SENTINEL_STOP released"; return 0; }

declare -a ROWS=()
capture(){ # $1 A|B  $2 secs  $3 label
  local dir="$OUT/$3"; mkdir -p "$dir"
  say "--- capture $3: $1 -d $2 ---"
  if [ "$DRY" = 1 ]; then say "[DRY] $D/capture_r3.sh $1 -d $2 -k -o $dir"; ROWS+=("$3|dry|dry"); return 0; fi
  "$D/capture_r3.sh" "$1" -d "$2" -k -o "$dir" > "$dir/capture.out" 2>&1; local rc=$?
  local verdict="rc=$rc"
  grep -q "CAPTURE_ABORTED" "$dir/capture.out" && verdict="$verdict $(grep -o 'CAPTURE_ABORTED[A-Z_]*' "$dir/capture.out" | head -1)"
  local score="(no frames.bin)"
  if [ -f "$dir/frames.bin" ]; then
    python3 "$D/accept_analyze.py" "$dir/frames.bin" > "$dir/accept.txt" 2>&1
    score=$(grep -E "live [0-9]+s/|UNUSABLE|PERTURBED" "$dir/accept.txt" | head -1 | sed 's/^ *//')
  fi
  say "  $3: $verdict | $score"
  ROWS+=("$3|$verdict|$score")
}

for i in $(seq 1 "$REV_ARMS"); do capture B "$ARM_S" "rev${ARM_S}_$i"; done
for i in $(seq 1 "$FWD_ARMS"); do capture A "$ARM_S" "fwd${ARM_S}_$i"; done
capture B "$LONG_S" "rev${LONG_S}"
capture A "$LONG_S" "fwd${LONG_S}"

say "=== GATE 3 SUMMARY $TAG $EXP ==="
bad=0; n=0
for r in "${ROWS[@]}"; do
  n=$((n+1)); label=${r%%|*}; rest=${r#*|}; v=${rest%%|*}; s=${rest#*|}
  case "$v$s" in *dry*) ;; *"rc=0"*) case "$s" in *UNUSABLE*|*PERTURBED*|"(no frames.bin)") bad=$((bad+1));; esac ;; *) bad=$((bad+1));; esac
  say "  $label  $v  $s"
done
say "GATE3_VERDICT $TAG $EXP bad_arms=$bad of $n  (pass = 0 bad arms; PERs above are live-window, lost frames in the denominator)"
{ echo "GATE3 $TAG $EXP $(date -Is) bad_arms=$bad of $n"; for r in "${ROWS[@]}"; do echo "  $r"; done; } > "$OUT/GATE3_SUMMARY.txt"

if [ "$ROLLBACK" = 1 ]; then
  say "--- ROLLBACK to CURRENT.txt roles: $ROLLBACK_ROLES ---"
  for pr in $ROLLBACK_ROLES; do ip=${pr%%:*}; role=${pr##*:}
    run env SUFFIX=.gate3 "$D/deploy_image.sh" "$ip" "$role" || say "ROLLBACK_WARN deploy $ip $role non-zero"
    [ "$DRY" = 1 ] || [ "$(board_md5 $ip)" = "$(role_md5 $role)" ] || { say "ROLLBACK_FAIL $ip on $(board_md5 $ip), role $role is $(role_md5 $role) -- PHYSICAL ATTENTION"; release; exit 1; }
  done
  run "$D/bringup_r2r3.sh" r3 || say "ROLLBACK_WARN bringup_r2r3 r3 non-zero"
  if [ "$DRY" = 1 ]; then say "[DRY] health probes"; else
    say "rollback health: 146 $($D/health_probe_reset_aware.sh 10.0.0.146 12 2>/dev/null | tail -1)  148 $($D/health_probe_reset_aware.sh 10.0.0.148 12 2>/dev/null | tail -1)"; fi
fi
release
say "GATE3_RUN_DONE $TAG (summary $OUT/GATE3_SUMMARY.txt)"
