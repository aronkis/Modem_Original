#!/bin/bash
# =============================================================================
# gate3_pair.sh -- Gate 3 (silicon, the PAIR) for a banked candidate image, as ONE repo rail:
# hold the sentinel, deploy the rung's dtb, flash 148 then 146 under the standing rails
# (rollback banks = the images/CURRENT.txt roles), bring the pair up at the candidate's
# rung, run the sp3-shaped lottery gate (REV_ARMS reverse + FWD_ARMS forward arms x ARM_S,
# then LONG_S per direction), optional soak rounds, then ROLL BACK (default) or KEEP.
# Every capture is scored by accept_analyze.py (live-link window, lost frames in the
# denominator) and journaled as "CAPTURE <label> rc=<n> accept: <line>".
#
#   ops/gate3_pair.sh --tag sp4 --md5 5108cdb77aeb [--rung r4] [--soak 3] [--keep]
#
# GATE3_CELLS turns step [6] into an INTERLEAVED sweep and the verdict into CELLS (no pass mark):
#   GATE3_CELLS="A:LO_A_RX=2000020000 A:LO_A_RX=2000060000 A:LO_A_RX=2000020000 A:LO_A_RX=2000060000"
#   (a cell may carry several variables, comma-separated: "A:LO_A_TX=1850000000,LO_B_RX=1850040000")
#   CELL_S=300 CAMPAIGN_MAX_CONSEC_FAIL=0
# Set CAMPAIGN_MAX_CONSEC_FAIL=0 for a sweep whose hypothesis PREDICTS some cells wedge: on
# 2026-09-26 three wedged legs in a row tripped the default fail-fast and skipped the rest of the
# campaign, which for a sweep would destroy the balance of the design. A wedged cell is data.
#                     [--rollback-roles "10.0.0.148:A 10.0.0.146:B"] [--rollback-rung r3]
#                     [--no-dtb] [--no-flash] [--rollback-only] [--out DIR]
#   --rollback-only: skip [2]-[8] and run ONLY step [9] (deploy_image roles + restore_known_good at
#                    --rollback-rung); for putting the pair back after a paused / killed run.
#   as a rig unit:  ops/launch_rig_unit.sh gate3-sp4 ops/gate3_pair.sh GATE3_TAG=sp4 GATE3_MD5=5108cdb77aeb
#                   [GATE3_SOAK=3 GATE3_NO_DTB=1 GATE3_NO_FLASH=1 GATE3_KEEP=1 GATE3_ROLLBACK_ONLY=1 GATE3_RUNG=r4]
#
# Env: DRY=1 (print the whole sequence, touch NOTHING -- the flash rails run under their own
#      DRY=1), REV_ARMS=6 FWD_ARMS=3 ARM_S=180 LONG_S=600 FWD_LIMIT_PCT=0.01 REV_LIMIT_PCT=1
#      GOLD=any (arm148_mode1 BIST golden for the 148 flash gate; pin a value only once it
#      is constant across arms) SENTINEL_STOP_FILE OUT
#
# ORDER, and why (sp4 = f3072: the two rungs do not interoperate, so no pair gate can run
# with one board on the candidate and the other on the shipped image):
#   [1] preconditions (bank, md5, roles, rung table, dtb rows), sentinel ownership (SS_MINE:
#       never removes a hold it did not create; DRY never touches it)
#   [2] dtb: deploy_dtb.sh <ip> for 146 then 148 (each reboots + verifies; the 4 MB carve
#       contains the 2 MB one, so the shipped image keeps working on it); read the live
#       carve back from /sys/firmware and require >= the rung's
#   [3] flash 148 with the candidate: flash_148_txfix.sh (148-only mode-1 loopback gate,
#       needs no peer)  FLASH_BAK = CURRENT.txt role A
#   [4] flash 146: flash_146_txfix.sh (its [4/6] restore_known_good.sh runs at RUNG=<rung>,
#       which rebuilds BOTH daemons for the rung's carve and brings the pair up; its health
#       gate reads 148)  FLASH_BAK = role B, ROLLBACK_BANK = role B's file
#   [5] both boards read back on the candidate md5
#   [6] the lottery gate + long legs  (capture_r3.sh at RUNG=<rung>, -k)
#   [7] soak rounds (each = LONG_S rev + LONG_S fwd)
#   [8] verdict: bad_arms (rc!=0 / UNUSABLE / PERTURBED / no frames.bin) must be 0 AND every
#       LONG_S / soak leg within FWD_LIMIT_PCT / REV_LIMIT_PCT
#   [9] rollback (default): deploy_image.sh <ip> <role> both boards (SUFFIX=.gate3), verify
#       md5, restore_known_good.sh at --rollback-rung (rebuilds the 2 MB daemons, bring-up),
#       health probes. --keep leaves the pair on the candidate; CURRENT.txt roles are then the
#       OPERATOR's edit (never automatic).
# Rails: no health probe or register read while an arm is in flight (the captures own the
# boards for their duration); every board-touching line is [DRY]-guarded.
# Exit 0 = sequence completed (rollback done, or kept); the verdict is the GATE3_VERDICT line.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$D/.." && pwd); W=${ANYSSH:-$D/anyssh.sh}
. "$D/rung_table.sh"
TAG=${GATE3_TAG:-}; EXP=${GATE3_MD5:-}; RUNG_C=${GATE3_RUNG:-r4}; SOAK=${GATE3_SOAK:-0}; KEEP=${GATE3_KEEP:-0}
ROLLBACK_ROLES=${ROLLBACK_ROLES:-"10.0.0.148:A 10.0.0.146:B"}; RB_RUNG=${ROLLBACK_RUNG:-r3}
# env equivalents for the rig-unit launcher (launch_rig_unit.sh passes env only): GATE3_NO_DTB=1,
# GATE3_NO_FLASH=1, GATE3_ROLLBACK_ONLY=1, GATE3_KEEP=1, GATE3_SOAK=N, GATE3_RUNG=rN
DO_DTB=$([ "${GATE3_NO_DTB:-0}" = 1 ] && echo 0 || echo 1); DO_FLASH=$([ "${GATE3_NO_FLASH:-0}" = 1 ] && echo 0 || echo 1)
ROLLBACK_ONLY=${GATE3_ROLLBACK_ONLY:-0}; OUT=${OUT:-}
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG=$2; shift 2 ;;  --md5) EXP=$2; shift 2 ;;  --rung) RUNG_C=$2; shift 2 ;;
    --soak) SOAK=$2; shift 2 ;;  --keep) KEEP=1; shift ;;  --out) OUT=$2; shift 2 ;;
    --rollback-roles) ROLLBACK_ROLES=$2; shift 2 ;;  --rollback-rung) RB_RUNG=$2; shift 2 ;;
    --no-dtb) DO_DTB=0; shift ;;  --no-flash) DO_FLASH=0; shift ;;  --rollback-only) ROLLBACK_ONLY=1; shift ;;
    -h|--help) sed -n '2,42p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$TAG" ] && [ -n "$EXP" ] || { echo "usage: gate3_pair.sh --tag <tag> --md5 <md5-12> [...]  (see --help)" >&2; exit 2; }
[[ "$EXP" =~ ^[0-9a-f]{12}$ ]] || { echo "FATAL: --md5 must be 12 lowercase hex (got '$EXP')" >&2; exit 2; }
DRY=${DRY:-0}; REV_ARMS=${REV_ARMS:-6}; FWD_ARMS=${FWD_ARMS:-3}; ARM_S=${ARM_S:-180}; LONG_S=${LONG_S:-600}
# CELLS: an interleaved discriminating sweep instead of the lottery gate (see [6]). Space-separated
# "A|B:VAR=value" cells, run in the order given, repeats allowed (labels are indexed, so they do not
# collide). CELL_S is the per-cell capture length. A cells run never prints PASS or FAIL.
CELLS=${GATE3_CELLS:-}; CELL_S=${CELL_S:-300}
FWD_LIMIT_PCT=${FWD_LIMIT_PCT:-0.01}; REV_LIMIT_PCT=${REV_LIMIT_PCT:-1}; GOLD=${GOLD:-any}
OUT=${OUT:-$D/r3cap/gate3_${TAG}_$(date +%Y%m%d_%H%M%S)}; mkdir -p "$OUT"; LOG=$OUT/gate3.log
SS_FILE=${SENTINEL_STOP_FILE:-$HOME/modem-status/SENTINEL_STOP}
say(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
run(){ if [ "$DRY" = 1 ]; then say "[DRY] $*"; return 0; fi; say "+ $*"; "$@" 2>&1 | tee -a "$LOG"; return "${PIPESTATUS[0]}"; }
# rollback_pair -- step [9] as a function, so the 146-flash-failure branch can call it too (2026-10-02).
# restore_known_good runs with the CANDIDATE rung's SRO_SIGN_CONF removed from the environment: rung_set
# honours an exported SRO_SIGN_CONF, and the r4 gate's sro_sign.r4.conf (both boards 1) leaked into the r3
# restore on 2026-10-02 and wrote R4D steering on 148. The rollback rung must pick its own conf.
rollback_pair(){
  say "--- [9] ROLLBACK to CURRENT.txt roles: $ROLLBACK_ROLES, then restore_known_good.sh at $RB_RUNG ---"
  for pr in $ROLLBACK_ROLES; do ip=${pr%%:*}; role=${pr##*:}
    run env SUFFIX=.gate3 "$D/deploy_image.sh" "$ip" "$role" || say "ROLLBACK_WARN deploy $ip $role non-zero"
    [ "$DRY" = 1 ] || [ "$(board_md5 "$ip")" = "$(role_md5 "$role")" ] || { say "ROLLBACK_FAIL $ip on $(board_md5 "$ip"), role $role is $(role_md5 "$role") -- PHYSICAL ATTENTION"; exit 1; }
  done
  run env -u SRO_SIGN_CONF RUNG="$RB_RUNG" "$D/restore_known_good.sh" || say "ROLLBACK_WARN restore_known_good at $RB_RUNG non-zero"
  if [ "$DRY" = 1 ]; then say "[DRY] health probes"; else
    say "rollback health: 146 $("$D/health_probe_reset_aware.sh" 10.0.0.146 12 2>/dev/null | tail -1)  148 $("$D/health_probe_reset_aware.sh" 10.0.0.148 12 2>/dev/null | tail -1)"; fi
}
brd(){ if [ "$DRY" = 1 ]; then echo "dry"; else timeout 60 "$W" "$1" "$2" 2>/dev/null | tail -1; fi; }
# rail: the flash rails have their own complete DRY=1 paths (every board action prints "[dry] ..."),
# so they are EXECUTED under DRY too -- the dry run exercises their preconditions and sequence.
rail(){ say "+ $*"; "$@" 2>&1 | tee -a "$LOG"; return "${PIPESTATUS[0]}"; }
board_md5(){ brd "$1" 'md5sum /boot/BOOT.BIN | cut -c1-12'; }
role_row(){ grep -E "^$1 " "$ROOT/images/CURRENT.txt" | head -1; }
role_md5(){ role_row "$1" | awk '{print substr($3,1,12)}'; }
role_file(){ role_row "$1" | awk '{print $2}'; }
# after a reboot sshd comes back ~60 s after ping does (flash-rail finding): poll, bounded, until a value
board_carve_mb(){ local v="" t=0
  while :; do v=$(brd "$1" 'R=/sys/firmware/devicetree/base/reserved-memory/qpsk_byte_buf@7ff00000/reg; [ -f $R ] && echo $(( 0x$(od -An -tx1 -j12 -N4 $R | tr -d " \n") / 1048576 )) || echo 0')
    [ -n "$v" ] && break; t=$((t+15)); [ "$t" -ge 300 ] && break; sleep 15; done
  echo "${v:-0}"; }

# ---- [1] preconditions --------------------------------------------------------------------
rung_set "$RUNG_C" || exit 2
C_PROF=$PROF; C_KSYM=$KSYM; C_CARVE=$CARVE_MB; C_FRAME=$FRAME
rung_set "$RB_RUNG" || exit 2
say "=== GATE 3 PAIR $TAG $EXP: rung $RUNG_C ($C_FRAME, -r $C_KSYM, ${C_CARVE} MB carve); ${REV_ARMS}x rev ${ARM_S}s, ${FWD_ARMS}x fwd ${ARM_S}s, rev+fwd ${LONG_S}s, soak=$SOAK; limits fwd<=${FWD_LIMIT_PCT}% rev<=${REV_LIMIT_PCT}%; keep=$KEEP rollback=$ROLLBACK_ROLES@$RB_RUNG; dry=$DRY; out=$OUT ==="
BBN=$(awk -v p="$EXP" 'index($1,p)==1{print $2; exit}' "$ROOT/images/MD5SUMS")
[ -n "$BBN" ] && [ -f "$ROOT/images/$BBN" ] || { say "FATAL: no banked image with md5 prefix $EXP in images/MD5SUMS"; exit 1; }
[ "$(md5sum "$ROOT/images/$BBN" | cut -c1-12)" = "$EXP" ] || { say "FATAL: $BBN md5 != $EXP"; exit 1; }
say "  candidate: images/$BBN"
for pr in $ROLLBACK_ROLES; do role=${pr##*:}
  [ -n "$(role_md5 "$role")" ] && [ -f "$ROOT/images/$(role_file "$role")" ] || { say "FATAL: CURRENT.txt role $role missing or its file absent"; exit 1; }
  say "  rollback role $role: $(role_file "$role") ($(role_md5 "$role"))"
done
A_BAK=$(role_md5 A); B_BAK=$(role_md5 B); B_BANK=$ROOT/images/$(role_file B)
[ "$ROLLBACK_ONLY" = 1 ] && { DO_DTB=0; DO_FLASH=0; }
if [ "$DO_DTB" = 1 ]; then
  for b in 146 148; do
    [ -n "$(role_row "DTB$b")" ] || { say "FATAL: images/CURRENT.txt has no DTB$b row (the ${C_CARVE} MB dtb for rung $RUNG_C; ops/dtb/build_dtb_4mb.sh)"; exit 1; }
    "$D/deploy_dtb.sh" check "10.0.0.$b" >/dev/null 2>&1 || { say "FATAL: deploy_dtb.sh check failed for the DTB$b row"; exit 1; }
    say "  dtb $b: $(role_file "DTB$b")"
  done
fi
# rig mutex (plan 2026-09-25 Task 2): hold it for the whole run so ad-hoc board access is
# refused at ops/anyssh.sh while this rail owns the rig. Nesting-safe.
. "$D/sim_repro/riglock.sh"
[ "$DRY" = 1 ] || rig_lock_only "gate3_pair-$TAG"
# env_snapshot -- the campaign-level control (plan Task 6). A full control LEG (flash the shipped
# image back mid-campaign, measure, flash the candidate again) was considered and rejected: two
# extra flash cycles per campaign for information this captures at no board-time cost. What
# confounded the week of 2026-09-22 was the RF environment moving BETWEEN runs, and a before/after
# snapshot on the same rig shows that inside one table.
env_snapshot(){ # $1 label
  [ "$DRY" = 1 ] && { say "[DRY] env_snapshot $1"; return 0; }
  for ip in 10.0.0.148 10.0.0.146; do
    say "ENV_$1 $ip $(brd "$ip" 'P=/sys/bus/iio/devices/iio:device2; echo rssi=$(cat $P/in_voltage0_rssi 2>/dev/null) decpow=$(cat $P/in_voltage0_decimated_power 2>/dev/null) md5=$(md5sum /boot/BOOT.BIN | cut -c1-12)')"
  done
  say "ENV_$1 sentinel $(grep -E '^[0-9]{4}-' "$HOME/modem-status/sentinel.log" 2>/dev/null | tail -1)"
}
SS_MINE=0
if [ "$DRY" = 1 ]; then say "[DRY] would take SENTINEL_STOP ($SS_FILE) if absent (DRY never touches it)"
elif [ -e "$SS_FILE" ]; then say "SENTINEL_STOP pre-exists (external hold) -- left alone"
else echo "gate3_pair $TAG $(date -Is)" > "$SS_FILE"; SS_MINE=1; say "SENTINEL_STOP taken"; fi
release(){ rig_unlock_only; [ "$SS_MINE" = 1 ] && rm -f "$SS_FILE" && say "SENTINEL_STOP released"; return 0; }
trap release EXIT

env_snapshot BEFORE
# ---- [2] dtb -------------------------------------------------------------------------------
declare -a ROWS=(); bad=0; n=0; over=0; VERDICT=ROLLBACK_ONLY
if [ "$ROLLBACK_ONLY" = 1 ]; then say "--- rollback-only: skipping [2]-[8] ---"; fi
if [ "$DO_DTB" = 1 ]; then
  for ip in 10.0.0.146 10.0.0.148; do
    say "--- [2] dtb -> $ip (deploy_dtb.sh backs up /boot/system.dtb, reboots, verifies) ---"
    run "$D/deploy_dtb.sh" "$ip" || { say "FATAL: dtb deploy failed on $ip (rollback: deploy_dtb.sh rollback $ip)"; exit 1; }
    cm=$(board_carve_mb "$ip"); say "  $ip live carve: $cm MB (need >= $C_CARVE)"
    [ "$DRY" = 1 ] || [ "${cm:-0}" -ge "$C_CARVE" ] || { say "FATAL: $ip carve $cm MB < $C_CARVE MB after the dtb deploy"; exit 1; }
  done
fi

# ---- [3]/[4] flash 148 then 146 under the rails ---------------------------------------------
if [ "$DO_FLASH" = 1 ]; then
  say "--- [3] flash 148 <- $EXP ($TAG), FLASH_BAK=$A_BAK (role A), GOLD=$GOLD ---"
  rail env DRY="$DRY" FLASH_MD5="$EXP" FLASH_TAG="$TAG" FLASH_BAK="$A_BAK" GOLD="$GOLD" QPSK_FRAME="$C_FRAME" SENTINEL_STOP_FILE="$SS_FILE" \
      bash "$D/flash/flash_148_txfix.sh" || { say "FATAL: 148 flash rail failed (the rail rolled 148 back itself)"; exit 1; }
  say "--- [4] flash 146 <- $EXP ($TAG), FLASH_BAK=$B_BAK (role B), pair bring-up at RUNG=$RUNG_C ---"
  rail env DRY="$DRY" FLASH_MD5="$EXP" FLASH_TAG="$TAG" FLASH_BAK="$B_BAK" ROLLBACK_BANK="$B_BANK" RUNG="$RUNG_C" QPSK_FRAME="$C_FRAME" SENTINEL_STOP_FILE="$SS_FILE" \
      bash "$D/flash/flash_146_txfix.sh" || { say "FATAL: 146 flash rail failed (the rail rolled 146 back itself; 148 is STILL on $EXP) -- rolling 148 back now (2026-10-02: a chain that stopped here left mixed rungs for 2.5 h)"; rollback_pair; exit 1; }
fi
# ---- [5] both on the candidate ---------------------------------------------------------------
if [ "$ROLLBACK_ONLY" != 1 ]; then
for ip in 10.0.0.146 10.0.0.148; do
  m=$(board_md5 "$ip"); say "  [5] $ip on $m (want $EXP)"
  [ "$DRY" = 1 ] || [ "$m" = "$EXP" ] || { say "FATAL: $ip is on $m, not the candidate"; exit 1; }
done

# ---- [6]/[7] captures ---------------------------------------------------------------------------
# FAIL FAST (2026-09-26). On 2026-09-25 the reverse leg was in a degraded episode (146 RX ~250 f/s
# against a 1122 f/s gate), so every capture's bring-up burned its six arm re-rolls and failed, and
# the campaign ground through all six captures -- about 36 arms and 40 minutes -- to produce a table
# of "(no frames.bin)". A campaign that cannot bring the link up is not going to start producing
# data three captures later; stop and roll back so the rig is released. CAMPAIGN_MAX_CONSEC_FAIL=0
# disables. The verdict still prints, and the skipped captures are recorded as such rather than
# silently missing.
CONSEC_FAIL=0; CAMPAIGN_ABORTED=0
MAX_CONSEC=${CAMPAIGN_MAX_CONSEC_FAIL:-3}
capture(){ # $1 A|B  $2 secs  $3 label  [$4 one VAR=value passed to capture_r3.sh's environment]
  local dir="$OUT/$3"; mkdir -p "$dir"
  local kv="${4:-}"
  # A plan may need MORE than one variable (2026-09-29: an LO plan is LO_A_TX AND LO_B_RX, and the
  # bring-up refuses a half-applied one). Comma-separate them in the cell -- "A:LO_A_TX=x,LO_B_RX=y"
  # -- and they are split into separate env assignments here. A single VAR=value is unchanged.
  local kvs=${kv//,/ }
  if [ "$CAMPAIGN_ABORTED" = 1 ]; then
    say "CAPTURE $3 SKIPPED (campaign aborted early after $CONSEC_FAIL consecutive failures)"
    ROWS+=("$3|skipped|campaign aborted early"); return 0
  fi
  say "--- capture $3: $1 -d $2 (RUNG=$RUNG_C${kv:+, $kv}) ---"
  if [ "$DRY" = 1 ]; then say "[DRY] ${kv:+env }RUNG=$RUNG_C${kv:+ $kvs} $D/capture_r3.sh $1 -d $2 -k -o $dir"; say "CAPTURE $3 rc=dry accept: dry"; ROWS+=("$3|dry|dry"); return 0; fi
  if [ -n "$kv" ]; then
    # shellcheck disable=SC2086  -- $kvs is split on purpose (one env assignment per plan variable)
    env RUNG="$RUNG_C" $kvs "$D/capture_r3.sh" "$1" -d "$2" -k -o "$dir" > "$dir/capture.out" 2>&1
  else
    RUNG=$RUNG_C "$D/capture_r3.sh" "$1" -d "$2" -k -o "$dir" > "$dir/capture.out" 2>&1
  fi
  local rc=$?
  local verdict="rc=$rc"
  grep -q "CAPTURE_ABORTED" "$dir/capture.out" && verdict="$verdict $(grep -o 'CAPTURE_ABORTED[A-Z_]*' "$dir/capture.out" | head -1)"
  local score="(no frames.bin)"
  if [ -f "$dir/frames.bin" ]; then
    python3 "$D/accept_analyze.py" "$dir/frames.bin" > "$dir/accept.txt" 2>&1
    score=$(grep -E "live [0-9]+s/|UNUSABLE|PERTURBED" "$dir/accept.txt" | head -1 | sed 's/^ *//')
  fi
  say "CAPTURE $3 $verdict accept: $score"
  ROWS+=("$3|$verdict|$score")
  # a capture that produced no frames at all, or returned non-zero, counts as a failure
  case "$verdict" in
    "rc=0") case "$score" in "(no frames.bin)"*) CONSEC_FAIL=$(( CONSEC_FAIL + 1 ));; *) CONSEC_FAIL=0;; esac ;;
    *)      CONSEC_FAIL=$(( CONSEC_FAIL + 1 )) ;;
  esac
  if [ "$MAX_CONSEC" -gt 0 ] 2>/dev/null && [ "$CONSEC_FAIL" -ge "$MAX_CONSEC" ]; then
    CAMPAIGN_ABORTED=1
    say "CAMPAIGN_ABORT_EARLY after $CONSEC_FAIL consecutive failed captures -- the link is not coming up; skipping the rest and rolling back"
  fi
}
if [ -n "$CELLS" ]; then
  # CELLS mode: an INTERLEAVED discriminating sweep instead of the lottery gate. One capture per
  # cell, one env knob changed, every cell in the same session so RF conditions are held as nearly
  # constant as a rig allows. The point is that a single clean leg on a new value is indistinguishable
  # from better conditions, so the cells alternate and the question becomes whether the statistic
  # tracks the KNOB or the CLOCK (docs/evidence/sp4/ACQUISITION_COLLAPSE.md sec 6).
  ci=0
  for cell in $CELLS; do
    ci=$(( ci + 1 ))
    cleg=${cell%%:*}; ckv=${cell#*:}
    capture "$cleg" "$CELL_S" "cell${ci}_${cleg}_${ckv##*=}" "$ckv"
  done
else
  for i in $(seq 1 "$REV_ARMS"); do capture B "$ARM_S" "rev${ARM_S}_$i"; done
  for i in $(seq 1 "$FWD_ARMS"); do capture A "$ARM_S" "fwd${ARM_S}_$i"; done
  capture B "$LONG_S" "rev${LONG_S}"
  capture A "$LONG_S" "fwd${LONG_S}"
  for k in $(seq 1 "$SOAK"); do capture B "$LONG_S" "soak${k}_rev${LONG_S}"; capture A "$LONG_S" "soak${k}_fwd${LONG_S}"; done
fi

# ---- [8] verdict -------------------------------------------------------------------------------
env_snapshot AFTER
say "=== GATE 3 SUMMARY $TAG $EXP (rung $RUNG_C) ==="
bad=0; n=0; over=0
for r in "${ROWS[@]}"; do
  n=$((n+1)); label=${r%%|*}; rest=${r#*|}; v=${rest%%|*}; s=${rest#*|}
  case "$v$s" in *dry*) ;; *"rc=0"*) case "$s" in *UNUSABLE*|*PERTURBED*|"(no frames.bin)") bad=$((bad+1));; esac ;; *) bad=$((bad+1));; esac
  # long legs against the plan's limits (fwd = A captures, rev = B captures). A CELLS run has no
  # LONG_S leg, so this loop would leave over=0 and print PASS for what is an exploratory sweep --
  # skip it outright and let the verdict say CELLS.
  [ -n "$CELLS" ] || case "$label" in *"${LONG_S}"*)
    per=$(echo "$s" | grep -o 'PER=[0-9.]*%' | head -1 | tr -dc '0-9.')
    if [ -n "$per" ]; then
      case "$label" in *fwd*) lim=$FWD_LIMIT_PCT ;; *) lim=$REV_LIMIT_PCT ;; esac
      awk -v p="$per" -v l="$lim" 'BEGIN{exit !(p<=l)}' || { over=$((over+1)); s="$s  OVER_LIMIT(${lim}%)"; }
    fi ;;
  esac
  say "  $label  $v  $s"
done
if [ "$DRY" = 1 ]; then VERDICT=DRY
elif [ -n "$CELLS" ]; then VERDICT=CELLS   # a discriminating sweep is not a gate: it has no pass mark
elif [ "$bad" -eq 0 ] && [ "$over" -eq 0 ]; then VERDICT=PASS; else VERDICT=FAIL; fi
[ -z "$CELLS" ] || say "GATE3_CELLS_NOTE this run was an interleaved sweep ($CELLS): no pass/fail mark, and a wedged cell is DATA. The discriminating statistic (fraction of frames with reg_cfc > 0) is NOT in the accept lines above -- compute it per cell from <label>/frames.bin."
say "GATE3_VERDICT $TAG $EXP rung=$RUNG_C bad_arms=$bad of $n long_legs_over_limit=$over -> $VERDICT  (pass = 0 bad arms and every ${LONG_S}s leg within fwd<=${FWD_LIMIT_PCT}% / rev<=${REV_LIMIT_PCT}%; PERs are live-window, lost frames in the denominator)"
{ echo "GATE3 $TAG $EXP rung=$RUNG_C $(date -Is) bad_arms=$bad of $n over=$over verdict=$VERDICT"; for r in "${ROWS[@]}"; do echo "  $r"; done; } > "$OUT/GATE3_SUMMARY.txt"
fi   # ROLLBACK_ONLY

# ---- [9] rollback or keep ------------------------------------------------------------------------
if [ "$KEEP" = 1 ]; then
  say "--- [9] KEEP: pair left on $EXP at rung $RUNG_C. images/CURRENT.txt roles are the operator's edit (only on a PASS and on their word). ---"
else
  rollback_pair
fi
say "GATE3_PAIR_DONE $TAG $VERDICT (summary $OUT/GATE3_SUMMARY.txt)"
