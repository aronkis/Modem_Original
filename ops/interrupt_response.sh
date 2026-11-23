#!/bin/bash
# =============================================================================
# interrupt_response.sh -- how does the receiver respond when the signal goes away for X ms and
# comes back? The operator's question, asked directly, on the live link, with NO arms.
#
# WHY THIS SHAPE (RESET_LEDGER_2026-09-29.md sec 4). 82-89 % of the historical "resets while
# decoding" were one event: the capture rail's end-of-traffic flush stalls the PEER's transmit feed
# for 4-246 ms, and the receiver falls into a reset storm (~900 rstCS/s, CRC 0 %) it has not left
# 5 s later. Nothing has measured that response curve on purpose. This does: it PAUSES the peer's
# daemon (SIGSTOP) for X ms -- the transmit feeder starves exactly as in WEDGE_ROOT_CAUSE.md --
# resumes it (SIGCONT), and polls the receiver's 0x104 / 0x150 / 0x154 at 1 Hz before, during and
# after. Interleaved lengths, several reps, so the result is a curve and not one anecdote.
#
# RESULT OF THE FIRST RUN (2026-09-29 19:06, ops/r3cap/interrupt_20260929): the receiver ran at
# 1245 f/s with zero resets for 30 s; the FIRST pause -- 20 ms -- put it into a reset storm
# (~1,200 rstCS/s, half-rate detection, carrier estimate +/-100k) that persisted through all twelve
# pauses and every 70 s gap between them, 16 minutes, and ended only when the relaunched watchdog
# issued its 0x000 double-tap. The peer's transmitter was fine throughout (same daemon process).
# So the response "curve" is a step: any interruption >= 20 ms latches the receiver until a soft
# reset. Side finding: the paused peer daemon came back with its byte plane wedged (see cleanup).
#
# Outputs per rep: resets during the pause, resets in the 30 s after resumption, seconds from
# resumption to the first window at full detection rate (>= 1100 f/s), and the carrier estimate's
# excursion. Score with ops/interrupt_response_score.py.
#
# RIG DISCIPLINE. Both watchdogs are killed for the run (148's would restart a stopped daemon on a
# DELIVERY-WEDGE verdict; 146's would 0x000 the receiver under test) and relaunched at the end the
# way capture_r3.sh -k does. The rig lock is held throughout. No register WRITE happens anywhere in
# this script; SIGSTOP/SIGCONT are process signals on the peer's host. Stop the degraded trigger first.
#
# Env: OUT=<dir> RX=10.0.0.146 (receiver under test) TX=10.0.0.148 (peer whose feed is paused)
#      LENS_MS="20 100 500 2000" REPS=3 SETTLE_S=30 POST_S=40 DRY=1
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
OUT=${OUT:?OUT=<dir>}; RX=${RX:-10.0.0.146}; TX=${TX:-10.0.0.148}
LENS_MS=${LENS_MS:-"20 100 500 2000"}; REPS=${REPS:-3}; SETTLE_S=${SETTLE_S:-30}; POST_S=${POST_S:-40}; DRY=${DRY:-0}
mkdir -p "$OUT"; L=$OUT/interrupt.log; T=$OUT/reps.tsv
say(){ echo "$(date -Is) $*" | tee -a "$L"; }
say "=== interrupt_response: pause $TX's daemon for [$LENS_MS] ms x$REPS (interleaved), poll $RX at 1 Hz; dry=$DRY ==="
printf 'rep\tlen_ms\tt_stop_epoch\tt_cont_epoch\tcsv\n' > "$T"

if [ "$DRY" = 1 ]; then
  for r in $(seq 1 "$REPS"); do for ms in $LENS_MS; do say "[dry] rep $r len ${ms}ms: SIGSTOP qpsk_tun on $TX, sleep ${ms}ms, SIGCONT; poll $RX ${SETTLE_S}s before + ${POST_S}s after"; done; done
  say "[dry] would kill both watchdogs first and relaunch them at the end; rig lock held; no register writes"
  say "INTERRUPT_RESPONSE_DRY_OK"; exit 0
fi

. "$D/sim_repro/riglock.sh"; rig_lock "interrupt-$$"; trap 'cleanup' EXIT
cleanup(){
  say "--- cleanup: SIGCONT the peer daemon (idempotent), relaunch both watchdogs WITH DAEMON_CMD ---"
  $W $TX 'pkill -CONT -x qpsk_tun 2>/dev/null; echo cont' 2>/dev/null | tail -1 | tee -a "$L" >/dev/null
  # RELAUNCH WITH DAEMON_CMD (2026-09-29). The first run relaunched the watchdogs bare (the
  # capture_r3.sh -k idiom). The paused daemon on the peer came back with its byte plane wedged
  # (0x1C0 frozen while the fabric detected at rate), and a watchdog without DAEMON_CMD cannot take
  # its proven "restart qpsk_tun" path for that -- it falls through to FULL RE-ARM, which does not
  # clear a byte-plane wedge, and loops a 0x000 double-tap every ~30 s, blipping the peer each time.
  # The restore_known_good.sh idiom carries DAEMON_CMD; use it.
  . "$D/rung_table.sh"; rung_set "${RUNG:-r3}" >/dev/null 2>&1
  for ip in $RX $TX; do
    $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; : > /dev/shm/watchdog.log; exit 0' >/dev/null 2>&1
    $W $ip 'C=$(cat /dev/shm/qpsk_tun.cmd 2>/dev/null); [ -n "$C" ] || C="QPSK_WHITEN=1 QPSK_RX_CYCLIC=0 QPSK_RX_QUEUED=1 chrt -f 50 ./qpsk_tun '"$TUN_GFLAG"' -M 16 -r '"$KSYM"' -i tun0 -s 5"; DAEMON_CMD="$C" DAEMON_LOG=/dev/shm/qpsk_tun.log nohup setsid /root/lock_watchdog.sh </dev/null >/dev/shm/watchdog.log 2>&1 & disown; echo "'$ip' wd relaunched (DAEMON_CMD set)"' 2>/dev/null | tail -1 | tee -a "$L"
  done
  rig_unlock
}
say "--- kill both watchdogs (a mid-run re-arm or daemon restart would destroy the measurement) ---"
for ip in $RX $TX; do
  $W $ip 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null; pkill -9 -f "[l]ock_watchdog" 2>/dev/null; echo wd-stopped' 2>/dev/null | tail -1 | sed "s/^/  $ip /" | tee -a "$L"
done
$W $TX 'pgrep -x qpsk_tun >/dev/null && echo "peer daemon up" || echo "PEER DAEMON NOT RUNNING"' 2>/dev/null | tail -1 | tee -a "$L" | grep -q "up" || { say "ABORT: no daemon to pause on $TX"; exit 1; }

# one persistent 1 Hz reader on the receiver for the whole run (single-reader rule; 1 s cadence)
TOTAL=$(( (SETTLE_S + POST_S + 10) * REPS * $(echo $LENS_MS | wc -w) + 30 ))
$W $RX "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
 echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
 end=\$(( \$(date +%s) + $TOTAL ))
 while [ \$(date +%s) -lt \$end ]; do
   echo 0x104 > \$DRA; p=\$(cat \$DRA); echo 0x150 > \$DRA; r=\$(cat \$DRA); echo 0x154 > \$DRA; c=\$(cat \$DRA)
   echo \"\$(date +%s.%N),\$p,\$r,\$c\"; sleep 1
 done" 2>/dev/null > "$OUT/rx_poll.csv" &
POLL=$!
sleep 5
n=0
for r in $(seq 1 "$REPS"); do
  for ms in $LENS_MS; do
    n=$(( n + 1 ))
    say "--- rep $r: pause ${ms} ms (settle ${SETTLE_S}s first) ---"
    sleep "$SETTLE_S"
    # STOP, sleep, CONT inside ONE ssh session so the pause length is the board's, not the network's
    TS=$($W $TX "pkill -STOP -x qpsk_tun; a=\$(date +%s.%N); sleep $(awk "BEGIN{print $ms/1000}"); pkill -CONT -x qpsk_tun; b=\$(date +%s.%N); echo \"\$a \$b\"" 2>/dev/null | tail -1)
    say "  stop=$(echo $TS | cut -d' ' -f1) cont=$(echo $TS | cut -d' ' -f2)"
    printf '%d\t%s\t%s\t%s\t%s\n' "$n" "$ms" "$(echo $TS | cut -d' ' -f1)" "$(echo $TS | cut -d' ' -f2)" rx_poll.csv >> "$T"
    sleep "$POST_S"
  done
done
say "--- waiting for the poller ---"; wait $POLL 2>/dev/null
say "INTERRUPT_RESPONSE_DONE $OUT"
python3 "$D/interrupt_response_score.py" "$OUT" 2>&1 | tee -a "$L"
