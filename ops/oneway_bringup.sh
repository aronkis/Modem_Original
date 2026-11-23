#!/bin/bash
# oneway_bringup.sh <tx_ip> <rx_ip> [rom|byte|tun] -- bring up a ONE-DIRECTIONAL test
# link: <tx_ip> carries the TX-only image (role TXO), <rx_ip> the RX-only image
# (role RXO); see images/CURRENT.txt and ops/deploy_image.sh.
#
# Derived from bringup_r2r3.sh (rung r3, one profile, same regfile arm), minus
# everything that assumes two full modems:
#   * ONE direction: only the RX board is probed for the arm-quality gate
#     (GATE_DIR=A|B semantics of bringup_r2r3.sh, here always "the rx board").
#   * NO internal-loopback BIST gate (arm148_mode1.sh, flash_*_txfix.sh rails):
#     a half image cannot pass it. The RX board's 0x104/0x108/0x144 counters
#     against the radiating TX board ARE the gate (oneway_measure.sh).
#   * The TX board keeps its RX SSI + profile ENABLED: TX pacing (DS_TxValid)
#     is driven by adc_validIn even when the Receiver is a stub.
#   * Traffic source: rom (default; 0x158=0, BIST ROM frame, no host process),
#     byte (qpsk_tun -B on the TX board radiates the reference frame, 0x158=1;
#     score it on the RX board with `oneway_measure.sh <rx_ip> <s> byte`), or
#     tun (a ONE-WAY IP link: qpsk_tun -G with QPSK_TUN_TXONLY=1 on the TX board
#     and QPSK_TUN_RXONLY=1 on the RX board, tun0 = 10.66.0.1 on 146 / 10.66.0.2 on
#     148 as in the pair; only unidirectional traffic works -- UDP, e.g.
#     `oneway_measure.sh <rx_ip> <s> tun` runs qpsk_perf TX -> RX; no ping/TCP).
#   * No tun link / no watchdog daemon pair: nothing echoes back. An optional
#     lock_watchdog on the RX board only (WATCHDOG=1; default 0 -- it would
#     re-launch qpsk_tun -G which is a bidirectional daemon).
#
# LO plan (today's forward leg, HOSTS.md 146/148): tx board 146 -> TX LO 2.000 GHz,
# rx board 148 -> RX LO 2.000020 GHz (+20 k off the CFO null). Swapped roles use
# the reverse-leg pair 1.900 / 1.900040 GHz. Override with LO_TX / LO_RX (Hz).
#
# Env: PROF (lvds_61p44_fdd_jupiter), GATE_FPS (default 90 % of 1245),
#      GATE_TRIES=6, WHITEN=1, SSI_TX ("clk dat" tx0 SSI row; default = tx_ssi_row.sh),
#      WATCHDOG=0, LO_TX, LO_RX, DRY=1 (print the plan, touch no board).
# Exit: 0 gate passed, 1 gate failed / board unreachable, 2 usage.
set -u
D=$(cd "$(dirname "$0")" && pwd); W="timeout ${SSH_T:-60} $D/anyssh.sh"
TX=${1:-}; RX=${2:-}; SRC=${3:-rom}
[ -n "$TX" ] && [ -n "$RX" ] || { echo "usage: oneway_bringup.sh <tx_ip> <rx_ip> [rom|byte|tun]"; exit 2; }
[ "$TX" != "$RX" ] || { echo "usage: tx_ip and rx_ip must differ"; exit 2; }
case "$SRC" in rom|byte|tun) ;; *) echo "usage: source is rom|byte|tun (got $SRC)"; exit 2 ;; esac
PROF=${PROF:-lvds_61p44_fdd_jupiter}; KSYM=15360; FPS=1245
GATE_FPS=${GATE_FPS:-$(( FPS * 90 / 100 ))}; GATE_TRIES=${GATE_TRIES:-6}; WHITEN=${WHITEN:-1}
case "$TX" in
  10.0.0.146) LO_TX=${LO_TX:-2100000000}; LO_RX=${LO_RX:-2100020000} ;;   # forward leg 146 -> 148
  10.0.0.148) LO_TX=${LO_TX:-1850000000}; LO_RX=${LO_RX:-1850040000} ;;   # reverse leg 148 -> 146 (1.85 GHz since 2026-09-29, = ops/rung_table.sh r3)
  *) [ -n "${LO_TX:-}" ] && [ -n "${LO_RX:-}" ] || { echo "FATAL: unknown tx board $TX -- set LO_TX and LO_RX (Hz)"; exit 2; } ;;
esac
tunaddr(){ case "$1" in 10.0.0.146) echo 10.66.0.1;; 10.0.0.148) echo 10.66.0.2;; *) echo "${TUN_ADDR:-10.66.0.9}";; esac; }
DRY=${DRY:-0}
run(){ if [ "$DRY" = 1 ]; then echo "  [DRY] $*"; else "$@"; fi; }

echo "=== ONE-WAY bring-up: TX=$TX (LO $LO_TX) -> RX=$RX (LO $LO_RX)  src=$SRC prof=$PROF gate>=${GATE_FPS} f/s  $(date -Is) ==="

# ---- [0] rig ownership: stop the sentinel/keeper and anything polling the boards ----
SS_FILE=${SENTINEL_STOP_FILE:-$HOME/modem-status/SENTINEL_STOP}
if [ "$DRY" != 1 ]; then
  mkdir -p "$(dirname "$SS_FILE")"; echo "oneway_bringup $TX->$RX $(date -Is)" > "$SS_FILE"
  for ip in $TX $RX; do
    $W $ip 'echo up' 2>/dev/null | grep -q up || { echo "FATAL: $ip unreachable via anyssh.sh"; exit 1; }
  done
fi

# ---- [1] radio arm: profile, LOs, regfile (ROM source), per board -------------
# The remote string is ONE line-set with no comments (anyssh flattens newlines).
# Mirrors bringup_r2r3.sh arm_rom; both boards get the full arm so the TX board's
# RX SSI runs (pacing) and the RX board's TX SSI runs (harmless, Transmitter stub).
arm(){ # $1 ip $2 txlo $3 rxlo
  run $W $1 "P=/sys/bus/iio/devices/iio:device2; DB=/sys/kernel/debug/iio/iio:device2
 pkill -x qpsk_tun 2>/dev/null
 PF=/dev/shm/watchdog.pid; [ -f \$PF ] && kill \$(cat \$PF) 2>/dev/null; pkill -f \"[s]tallpoll\" 2>/dev/null; sleep 1
 cat /root/$PROF.bin > \$P/stream_config 2>/dev/null; cat /root/$PROF.json > \$P/profile_config 2>/dev/null; sleep 2
 echo calibrated > \$P/out_voltage1_ensm_mode 2>/dev/null; echo calibrated > \$P/in_voltage1_ensm_mode 2>/dev/null
 for g in 4 5 6 7; do echo 1 > \$DB/agpio\${g}_direction; echo 1 > \$DB/agpio\${g}_value; done; echo tx_a > \$P/out_voltage0_port_select
 echo $2 > \$P/out_altvoltage2_TX1_LO_frequency 2>&1; echo 0 > \$P/out_voltage0_hardwaregain; echo rf_enabled > \$P/out_voltage0_ensm_mode
 echo calibrated > \$P/in_voltage0_ensm_mode 2>/dev/null; echo $3 > \$P/out_altvoltage0_RX1_LO_frequency 2>&1
 echo rf_enabled > \$P/in_voltage0_ensm_mode; echo automatic > \$P/in_voltage0_gain_control_mode
 DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo '0x000 0x1'>\$DRA;sleep 0.5;echo '0x000 0x0'>\$DRA;echo '0x158 0x0'>\$DRA;echo '0x118 0x0'>\$DRA;echo '0x114 0x1'>\$DRA
 TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done);T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
 echo '0x418 0x2'>\$T;echo '0x458 0x2'>\$T;echo '0x044 0x1'>\$T;echo '0x110 0x1'>\$DRA;sleep 0.3;echo '0x110 0x0'>\$DRA
 echo '$1 armed ROM ($PROF)'"
}
rearm_rom(){ run $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA; echo "0x158 0x0">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x1">$DRA
 TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done); T=/sys/kernel/debug/iio/$TXD/direct_reg_access
 echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA'; }
rearm_byte(){ run $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA; echo "0x158 0x1">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x1">$DRA
 TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done); T=/sys/kernel/debug/iio/$TXD/direct_reg_access
 echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA'; }
# RX frames/s on the rx board over 5 s (0x104 = detected frames; wrap/reset -> re-probe)
probe(){ $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo 0x104 > $DRA; p0=$(cat $DRA); sleep 5; echo 0x104 > $DRA; p1=$(cat $DRA); d=$(( (p1 - p0) / 5 )); [ $d -lt 0 ] && d=0; echo $d' 2>/dev/null; }

arm $TX $LO_TX $LO_RX &
arm $RX $LO_TX $LO_RX &
wait

# ---- [2] TX board SSI row (the TX eye moves per image; ops/profiles/tx_ssi.conf) ----
if [ "${SSI_TX:-}" = skip ]; then
  echo "$TX ssi: SKIPPED (auto-tune delays stand)"
else
  ROW=${SSI_TX:-$($D/tx_ssi_row.sh $TX "$([ "$TX" = 10.0.0.146 ] && echo "3 4" || echo "5 3")")}
  set -- $ROW
  if [ "$DRY" = 1 ]; then echo "  [DRY] FORCE=1 $D/apply_146_ssi_fix.sh $TX $1 $2"
  else echo "$TX ssi: $(FORCE=1 $D/apply_146_ssi_fix.sh $TX $1 $2 2>&1 | tail -1)"; fi
fi
# the SSI fix re-arms byte; back to ROM, double-tap (ARMCAUSE: the RX demod's
# 0x000 must land while the TX stream is already clean)
rearm_rom $TX; sleep 1; rearm_rom $RX
sleep 3
rearm_rom $TX; sleep 1; rearm_rom $RX

# ---- [3] arm-quality gate: RX board only ---------------------------------------
if [ "$DRY" = 1 ]; then echo "  [DRY] gate: probe $RX 0x104 >= $GATE_FPS f/s, up to $GATE_TRIES tries"; F=0; PASS=1
else
  try=1; PASS=0
  while [ $try -le $GATE_TRIES ]; do
    sleep 4
    F=$(probe $RX)
    echo "gate try $try: $RX rx=${F:-0} f/s (need >= $GATE_FPS)"
    [ "${F:-0}" -ge "$GATE_FPS" ] && { PASS=1; break; }
    rearm_rom $TX; sleep 1; rearm_rom $RX; sleep 3; rearm_rom $TX; sleep 1; rearm_rom $RX
    try=$(( try + 1 ))
  done
  [ $PASS = 1 ] || { echo "ONEWAY ARM GATE FAILED after $GATE_TRIES tries (rx=${F:-0} f/s on $RX)"; exit 1; }
  echo "ONEWAY ARM GATE PASS (try $try, ${F} f/s)"
fi

# ---- [4] optional byte source: qpsk_tun -B on the TX board radiates the reference frame ----
if [ "$SRC" = byte ]; then
  run $W $TX "cd /root/host_app_k5; pkill -x qpsk_tun 2>/dev/null; QPSK_WHITEN=$WHITEN setsid chrt -f 50 ./qpsk_tun -B -r $KSYM -d ${BYTE_SECS:-86400} -i tun0 </dev/null >/dev/shm/qpsk_tun.log 2>&1 &
 sleep 3; pgrep -x qpsk_tun >/dev/null && echo '$TX byte source up (qpsk_tun -B)' || echo '$TX BYTE SOURCE FAILED: '\$(tail -2 /dev/shm/qpsk_tun.log | tr '\n' '|')"
  sleep 2
  rearm_byte $TX; sleep 3; rearm_byte $TX          # source flip, double-tap
  rearm_rom $RX                                     # RX board: 0x158 is irrelevant (stub TX) but keep the demod re-rolled against the byte stream
fi

# ---- [4b] optional tun source: a ONE-WAY IP link (qpsk_tun -G, one half of the daemon on each board) ----
if [ "$SRC" = tun ]; then
  TXA=$(tunaddr $TX); RXA=$(tunaddr $RX); KSYMV=$KSYM
  # RX-only daemon: LEGACY per-packet capture (-M 0, TLAST bounds every transfer). Measured
  # 2026-09-17 on the RXO image: the queued 16-packet mode (-M 16, QPSK_RX_QUEUED=1) decoded
  # idle frames but CRC-dropped every DATA frame (dma_rx_ok=1, crc_drop=50k/60 s); legacy
  # delivered 34,078 of 34,091 UDP packets. Suspect: the RXO image's 2-deep byte-plane pad
  # (vs 4 on the full image) and the multi-packet boundary scan. Override with RXM / RXQ.
  TUN_RXM=${RXM:-0}; TUN_RXQ=${RXQ:-0}
  # RX board first (stream-first order does not apply: the RX daemon never transmits),
  # then the TX board, whose keepalive fill feeds the modulator continuously.
  run $W $RX "cd /root/host_app_k5; pkill -x qpsk_tun 2>/dev/null; QPSK_WHITEN=$WHITEN QPSK_TUN_RXONLY=1 QPSK_RX_QUEUED=$TUN_RXQ setsid chrt -f 50 ./qpsk_tun -G -M $TUN_RXM -r $KSYMV -i tun0 -s 5 </dev/null >/dev/shm/qpsk_tun.log 2>&1 &
 n=0; while [ \$n -lt 15 ]; do ip link show tun0 >/dev/null 2>&1 && break; sleep 1; n=\$((n+1)); done
 ip addr replace $RXA peer $TXA dev tun0; ip link set tun0 up mtu 1516
 pgrep -x qpsk_tun >/dev/null && echo '$RX RX-only tun daemon up ($RXA)' || echo '$RX TUN DAEMON FAILED: '\$(tail -2 /dev/shm/qpsk_tun.log | tr '\n' '|')"
  run $W $TX "cd /root/host_app_k5; pkill -x qpsk_tun 2>/dev/null; QPSK_WHITEN=$WHITEN QPSK_TUN_TXONLY=1 setsid chrt -f 50 ./qpsk_tun -G -M ${RXM:-16} -r $KSYMV -i tun0 -s 5 </dev/null >/dev/shm/qpsk_tun.log 2>&1 &
 n=0; while [ \$n -lt 15 ]; do ip link show tun0 >/dev/null 2>&1 && break; sleep 1; n=\$((n+1)); done
 ip addr replace $TXA peer $RXA dev tun0; ip link set tun0 up mtu 1516
 pgrep -x qpsk_tun >/dev/null && echo '$TX TX-only tun daemon up ($TXA)' || echo '$TX TUN DAEMON FAILED: '\$(tail -2 /dev/shm/qpsk_tun.log | tr '\n' '|')"
  sleep 4                                           # let the TX keepalive stream pump before the source flip
  rearm_byte $TX; sleep 3; rearm_byte $TX           # source flip to the byte plane, double-tap
  rearm_rom $RX                                     # re-roll the RX demod against the continuous byte stream
fi

# ---- [5] RX-side sro_sign (fixctl 0x208 bit 5) LAST, after the final 0x000 pulse ----
if [ "$DRY" != 1 ]; then
  bash "$D/sro_sign.sh" $RX --bringup || echo "SRO_SIGN_HOOK_FAILED $RX"
fi
# optional RX-board watchdog (relaunches a -G daemon: only meaningful with a byte source you want kept alive)
if [ "${WATCHDOG:-0}" = 1 ] && [ "$DRY" != 1 ]; then
  echo "WARNING: WATCHDOG=1 launches lock_watchdog.sh on $RX (bidirectional daemon semantics) -- not the default for a one-way test"
fi
echo "=== ONE-WAY BRING-UP COMPLETE: $TX radiating ($SRC) -> $RX decoding; measure with: ops/oneway_measure.sh $RX 60 $SRC ==="
echo "    restore the pair with: ops/deploy_image.sh $TX A|B ; ops/deploy_image.sh $RX A|B ; ops/restore_known_good.sh ; rm $SS_FILE"
