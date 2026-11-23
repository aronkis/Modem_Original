#!/bin/bash
# =============================================================================
# restore_known_good.sh -- put the rig back the way it should be found.
#
# End state (matches the pre-session state, not the overnight experiment state):
#   146: TMR image 433fd8dab393, PLAIN host app (no -DQPSK_RXQ_STAT), queued RX at the
#        DEFAULT -M 16, link up and ARM-GATED, lock_watchdog running.
#   148: completely untouched -- AXR/NAK counter intact, daemon + watchdog running.
#
# -M 16 IS NOW THE SHIPPED DEFAULT (owner approved 2026-08-11). It was held at 32 for
# several sessions on the principle that changing a production default is the owner's
# call and not a side effect of a measurement run. That was the right policy and the
# wrong outcome: -M 16 is the single change that meets the <1% delivered-PER goal
# (0.695%, CP95 UL 0.730% PASS vs 1.362% UL 1.405% NOT MET), free, at equal CPU and
# goodput. See RX_CONFIG_SWEEP_RESULTS.md.
#
# WHY A PLAIN REBUILD. The overnight runs built board B with -DQPSK_RXQ_STAT. With the
# flag off the object is byte-identical to the pre-session baseline (verified md5
# 9212aa2f), so a plain build leaves the deployed binary exactly as it was found, with
# the instrumentation living in the committed source, compiled out.
#
# WHY THE WATCHDOG STEP IS EXPLICIT. bring-up stops lock_watchdog for the capture and
# capture_r3.sh -k does NOT restart it -- it only leaves the daemons up. Last session
# this was missed and 148 was left without its watchdog.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd)
W=$D/anyssh.sh
A=10.0.0.148; B=10.0.0.146
# The rung the rig is "known good" at (ops/rung_table.sh). r3 = the shipped sp3prod pair /
# f1536; pass RUNG=r4 once the sp4 (f3072) pair is deployed and gated (plan Task 12).
. "$D/rung_table.sh"; rung_set "${RUNG:-r3}" || exit 2

echo "=== RESTORE: gated bring-up, plain app, default -M 16 (shipped) ==="
# NOTE: no HOST_CFLAGS_B -> board B rebuilds WITHOUT the instrumentation.
# No LO literal here (removed 2026-09-29): this used to pass LO_B_RX=1900020000, a +20 kHz reverse
# receiver the documented plan had already replaced with +40 kHz -- and once the reverse carrier
# moved to 1.85 GHz it would have tripped bringup_r2r3.sh's pairing guard (146 RX 50 MHz from
# 148 TX) and refused to arm, on the rail every other restore path falls back to. The plan is
# ops/rung_table.sh's, like every other bring-up.
RUNG=$RUNG RXM=16 RXQ=1 RXCYC=0 GATE_TRIES=12 \
  "$D/capture_r3.sh" B -k -d 15 -n 400000 -o "$D/r3cap/restore_$(date +%H%M%S)" \
  > /tmp/restore_bringup.log 2>&1
echo "  bring-up exit=$? (log /tmp/restore_bringup.log)"
grep -E "ARM GATE|BRING-UP COMPLETE|crc-health" /tmp/restore_bringup.log | tail -3

# sro_sign (Task 12, cleanup sub-project 3): same hook as bringup_r2r3.sh. The
# capture_r3.sh call above already runs bringup_r2r3.sh internally (which
# carries this hook itself), so this is normally redundant -- it is kept here
# too, additive and non-fatal, so restore's own log always shows the sro_sign
# state it left behind even if the nested bring-up's own log line is not
# grepped for above.
for ip in $B $A; do
  bash "$D/sro_sign.sh" $ip --bringup || echo "SRO_SIGN_HOOK_FAILED $ip"
  bash "$D/sro_sign.sh" --check $ip || echo "SRO_SIGN_CHECK_HOOK_FAILED $ip"
done

echo "=== restart lock_watchdog on BOTH boards ==="
# ISOLATED ssh calls, then VERIFY. A detached launch bundled with other commands in one
# ssh block does not survive -- this printed "watchdog launched" while both watchdogs were
# in fact DOWN. Same footgun already fixed in watchdog_efficacy.sh.
for ip in $B $A; do
  $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; exit 0' >/dev/null 2>&1
  $W $ip 'chmod +x /root/lock_watchdog.sh 2>/dev/null; : > /dev/shm/watchdog.log; exit 0' >/dev/null 2>&1
  # the recorded bring-up launch when present; otherwise the same line bring-up would record
  $W $ip 'C=$(cat /dev/shm/qpsk_tun.cmd 2>/dev/null); [ -n "$C" ] || C="QPSK_WHITEN=1 QPSK_RX_CYCLIC=0 QPSK_RX_QUEUED=1 chrt -f 50 ./qpsk_tun '"$TUN_GFLAG"' -M 16 -r '"$KSYM"' -i tun0 -s 5"; DAEMON_CMD="$C" DAEMON_LOG=/dev/shm/qpsk_tun.log nohup setsid /root/lock_watchdog.sh </dev/null >/dev/shm/watchdog.log 2>&1 & disown; exit 0' >/dev/null 2>&1
  sleep 2
  if $W $ip 'pgrep -f "[l]ock_watchdog" >/dev/null && echo UP || echo DOWN' 2>/dev/null | grep -q UP; then
    echo "  $ip watchdog VERIFIED up"
  else
    echo "  $ip watchdog FAILED TO START"
  fi
done
sleep 3

echo
echo "=== FINAL VERIFIED STATE ==="
for ip in $B $A; do
  echo "--- $ip ---"
  # image identity is the BOOT.BIN md5, same as modem_status.sh uses (146 must be
  # 433fd8dab393 = the T9.0 TMR + loop-tune image)
  $W $ip 'echo "  BOOT.BIN   : $(md5sum /boot/BOOT.BIN 2>/dev/null | cut -c1-12)"
    echo "  app md5    : $(md5sum /root/host_app_k5/qpsk_tun | cut -c1-8)"
    echo "  nakstat    : $(strings /root/host_app_k5/qpsk_tun | grep -c nakstat) (148 must be 4)"
    echo "  rxqstat    : $(strings /root/host_app_k5/qpsk_tun | grep -c rxqstat) (must be 0 -- plain build)"
    p=$(pgrep -x qpsk_tun | head -1)
    echo "  daemon     : ${p:+up pid=$p}${p:-DOWN}"
    [ -n "$p" ] && echo "  cmdline    : $(tr "\0" " " < /proc/$p/cmdline)"
    [ -n "$p" ] && echo "  rx mode    : $(tr "\0" "\n" < /proc/$p/environ | grep -E "QPSK_RX_(QUEUED|CYCLIC)" | tr "\n" " ")"
    pgrep -f "[l]ock_watchdog" >/dev/null && echo "  watchdog   : up" || echo "  watchdog   : DOWN"
    echo "  link stats : $(grep "qpsk_tun stats" /dev/shm/qpsk_tun.log 2>/dev/null | tail -1 | grep -oE "dma_rx_ok=[0-9]+ crc_drop=[0-9]+")"' 2>/dev/null
done
echo
echo "=== restore complete $(date -Is) ==="
