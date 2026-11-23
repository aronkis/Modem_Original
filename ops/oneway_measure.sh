#!/bin/bash
# oneway_measure.sh <rx_ip> [dwell_s] [rom|byte|tun] -- score a ONE-DIRECTIONAL link on the
# RX-only board (after oneway_bringup.sh).
#
# rom  (default) -- the TX board radiates the BIST ROM frame. One remote reader samples
#        0x104 (detected frames), 0x108 (BIST bit errors, 120-bit window per frame,
#        see memory "BIST 0x108 sees only the first 120 of 2240 bits"), 0x144 (BIST
#        digest; golden 0x04922282) and 0x150 (rstCS count) every 1 s for DWELL s.
#        Scoring (measure_ber.sh idiom, made reset-aware like health_probe_reset_aware.sh):
#          frames    = sum of POSITIVE 0x104 deltas over clean intervals
#          bits      = frames * 120                       (the BIST window, NOT the 2240-bit frame)
#          biterr    = sum of positive 0x108 deltas
#          lost      = expected - frames, expected = 1245 f/s * clean_s  (fps deficit; wrap/reset
#                      intervals are excluded from BOTH numerator and denominator and counted
#                      as resets_s)
#          PER_est   = lost / expected      golden_frac = fraction of samples with 0x144 golden
#        plus health_probe_reset_aware.sh for the byte-plane word counter.
# byte -- the TX board runs qpsk_tun -B (reference frame); on the RX board run the -B
#        scorer for DWELL s and print its frames_scored= line (denominator = frames_scored,
#        lost = the deficit vs 1245 f/s * DWELL).
# tun  -- after `oneway_bringup.sh ... tun`: qpsk_perf -s (UDP sink) on the RX board's tun,
#        qpsk_perf -c from the TX board for DWELL s at BPS (default 400000 b/s, 88-byte
#        datagrams = one frame each); denominator = client tx_pkts, lost = tx_pkts - rx_pkts.
#
# Prints ONE summary line starting with ONEWAY_MEASURE that carries the command, the
# sample count and the denominator definition (docs/measurement-discipline.rst).
set -u
D=$(cd "$(dirname "$0")" && pwd); W="timeout $(( ${2:-60} + 60 )) $D/anyssh.sh"
RX=${1:?usage: oneway_measure.sh <rx_ip> [dwell_s] [rom|byte]}; DWELL=${2:-60}; SRC=${3:-rom}
FPS=1245
case "$SRC" in
rom)
  echo "=== ONE-WAY measure (rom): $RX dwell=${DWELL}s  $(date -Is) ==="
  RAW=$($W $RX 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 for i in $(seq 0 '"$DWELL"'); do
   echo 0x104 > $DRA; a=$(cat $DRA); echo 0x108 > $DRA; b=$(cat $DRA); echo 0x144 > $DRA; c=$(cat $DRA); echo 0x150 > $DRA; d=$(cat $DRA)
   echo "$a $b $c $d"; [ $i -lt '"$DWELL"' ] && sleep 1
 done' 2>/dev/null)
  echo "$RAW" | python3 -c '
import sys
fps=int(sys.argv[1]); rx=sys.argv[2]; dwell=int(sys.argv[3])
def h(x):
    try: return int(x,16)
    except: return None
S=[]
for ln in sys.stdin:
    a=ln.split()
    if len(a)==4 and None not in (h(a[0]),h(a[1]),h(a[3])):
        S.append((h(a[0]),h(a[1]),a[2].strip().lower(),h(a[3])))
frames=biterr=0; clean=0; resets=0
for i in range(1,len(S)):
    dp=S[i][0]-S[i-1][0]; de=S[i][1]-S[i-1][1]; dr=S[i][3]-S[i-1][3]
    if dp<0 or dr!=0 or de<0:
        resets+=1; continue          # a reset landed in this interval: excluded from both sides
    clean+=1; frames+=dp; biterr+=de
gold=sum(1 for s in S if s[2]=="0x04922282")
expected=fps*clean
lost=max(0,expected-frames)
per=100*lost/expected if expected else -1
ber=100*biterr/(frames*120) if frames else -1
print(f"rom: samples={len(S)} clean_s={clean} resets_s={resets} frames={frames} expected={expected} lost={lost} PER_est={per:.3f}% "
      f"biterr={biterr} bits={frames*120} BER_120win={ber:.5f}% golden_frac={gold/len(S) if S else 0:.3f} fps_mean={frames/clean if clean else 0:.0f}")
print(f"ONEWAY_MEASURE rx={rx} src=rom cmd=\"oneway_measure.sh {rx} {dwell} rom\" samples={len(S)} frames={frames} "
      f"denominator=\"expected={fps}f/s*clean_s({clean}); lost frames counted; reset intervals({resets}) excluded\" "
      f"PER_est={per:.3f}% BER_120win={ber:.5f}% golden_frac={gold/len(S) if S else 0:.3f}")
' "$FPS" "$RX" "$DWELL"
  echo "health: $(bash "$D/health_probe_reset_aware.sh" $RX 12 2>/dev/null | tail -1)"
  ;;
byte)
  echo "=== ONE-WAY measure (byte, qpsk_tun -B scorer): $RX dwell=${DWELL}s  $(date -Is) ==="
  OUT=$($W $RX "cd /root/host_app_k5; pkill -x qpsk_tun 2>/dev/null; sleep 1; QPSK_WHITEN=${WHITEN:-1} QPSK_SEQ_RXONLY=1 timeout $(( DWELL + 30 )) ./qpsk_tun -B -r 15360 -d $DWELL -i tun0 2>&1 | grep -E 'frames_scored=|BER|PER' | tail -3" 2>/dev/null)
  echo "$OUT"
  FS=$(echo "$OUT" | grep -o 'frames_scored=[0-9]*' | tail -1 | cut -d= -f2)
  EXP=$(( FPS * DWELL )); LOST=$(( EXP - ${FS:-0} )); [ $LOST -lt 0 ] && LOST=0
  # ZERO-DENOMINATOR GUARD (2026-09-25, plan 2026-09-25-rig-instability Task 7). The on-board -B
  # scorer prints "bit_errors=0 BER=0.000e+00" when it aligned NOTHING, because zero errors out of
  # zero compared bits is arithmetically true and completely misleading. It happened on the worst
  # leg of the 2026-09-25 run: aligned=0, total_bits=0, BER=0.000e+00 -- a reader skimming the BER
  # column would have recorded a perfect result. An instrument must be able to say it does not know.
  ALIGNED=$(echo "$OUT" | grep -o 'aligned([^)]*)=[0-9]*' | tail -1 | cut -d= -f2)
  BITS=$(echo "$OUT" | grep -o 'total_bits=[0-9]*' | tail -1 | cut -d= -f2)
  BERF=$(echo "$OUT" | grep -o 'BER=[^ ]*' | tail -1)
  if [ "${BITS:-0}" -le 0 ] 2>/dev/null || [ "${ALIGNED:-0}" -le 0 ] 2>/dev/null; then
    BERF="BER=UNKNOWN(aligned=${ALIGNED:-0},bits=${BITS:-0})"
  fi
  echo "ONEWAY_MEASURE rx=$RX src=byte cmd=\"oneway_measure.sh $RX $DWELL byte\" samples=${FS:-0} denominator=\"expected=${FPS}f/s*${DWELL}s=$EXP; lost=$LOST counted\" $BERF"
  ;;
tun)
  TXIP=${TX_IP:-$([ "$RX" = 10.0.0.148 ] && echo 10.0.0.146 || echo 10.0.0.148)}
  RXA=$([ "$RX" = 10.0.0.146 ] && echo 10.66.0.1 || echo 10.66.0.2); BPS=${BPS:-400000}; PORT=${PORT:-5001}
  echo "=== ONE-WAY measure (tun, qpsk_perf UDP $TXIP -> $RX/$RXA, ${BPS} b/s): dwell=${DWELL}s  $(date -Is) ==="
  $W $RX "cd /root/host_app_k5; pkill -x qpsk_perf 2>/dev/null; setsid ./qpsk_perf -s -p $PORT -t $(( DWELL + 10 )) </dev/null >/dev/shm/perf_srv.log 2>&1 &" 2>/dev/null
  sleep 2
  CLI=$($W $TXIP "cd /root/host_app_k5; pkill -x qpsk_perf 2>/dev/null; timeout $(( DWELL + 20 )) ./qpsk_perf -c $RXA -b $BPS -l 88 -t $DWELL -p $PORT 2>&1 | grep -E 'PERF_CLI_DONE'" 2>/dev/null)
  sleep 3
  # qpsk_perf -s ignores -t (run_server(..., 0)): it prints PERF_SRV_DONE only on SIGINT
  SRV=$($W $RX "pkill -INT -x qpsk_perf 2>/dev/null; sleep 1; grep -E 'PERF_SRV_DONE' /dev/shm/perf_srv.log | tail -1" 2>/dev/null)
  echo "client: $CLI"; echo "server: $SRV"
  # forensics (read BEFORE any restore reboots /dev/shm away): the perf server log and
  # the two daemons' last periodic stats lines (frames_tx/idle_tx on the TX board,
  # frames_rx_ok/tun_b_tx/crc_drop on the RX board)
  echo "rx perf log: $($W $RX "tail -3 /dev/shm/perf_srv.log 2>/dev/null; pgrep -x qpsk_perf >/dev/null && echo perf_running" 2>/dev/null | tr '\n' '|' | cut -c1-300)"
  echo "rx daemon:   $($W $RX "grep -E 'ONE-WAY|irq mode|polled|qpsk_tun stats' /dev/shm/qpsk_tun.log 2>/dev/null | tail -2" 2>/dev/null | tr '\n' '|' | cut -c1-400)"
  echo "tx daemon:   $($W $TXIP "grep -E 'ONE-WAY|irq mode|polled|qpsk_tun stats' /dev/shm/qpsk_tun.log 2>/dev/null | tail -2" 2>/dev/null | tr '\n' '|' | cut -c1-400)"
  TXP=$(echo "$CLI" | grep -o 'tx_pkts=[0-9]*' | cut -d= -f2); RXP=$(echo "$SRV" | grep -o 'rx_pkts=[0-9]*' | cut -d= -f2)
  LOST=$(( ${TXP:-0} - ${RXP:-0} )); [ $LOST -lt 0 ] && LOST=0
  PER=$(python3 -c "t=${TXP:-0}; print('%.3f' % (100.0*$LOST/t) if t else 'n/a')")
  echo "ONEWAY_MEASURE rx=$RX src=tun cmd=\"oneway_measure.sh $RX $DWELL tun\" samples=${TXP:-0} denominator=\"client tx_pkts=${TXP:-0}; lost=$LOST=tx_pkts-rx_pkts(${RXP:-0}) counted\" PER=${PER}% bps=$BPS"
  ;;
*) echo "usage: oneway_measure.sh <rx_ip> [dwell_s] [rom|byte|tun]"; exit 2 ;;
esac
