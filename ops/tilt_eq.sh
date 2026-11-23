#!/bin/bash
# =============================================================================
# tilt_eq.sh -- write the receiver in-band TILT CORRECTOR (tilt_eq_overlay.m, AXI 0x260/0x264) on one board
# from a live measurement of the slope it is receiving.
#
#   tilt_eq.sh <ip>                measure -> solve -> write -> read back -> re-measure, one TILT_EQ line
#   tilt_eq.sh <ip> --bringup      same, meant for the bring-up hook (QPSK_TILT_EQ=1 in bringup_r2r3.sh); a
#                                  0x000 soft reset clears the words, so every arm needs this again
#   tilt_eq.sh <ip> --off          write zeros (bypass) and read back
#   tilt_eq.sh <ip> --set <dB>     FORCE the corrector for a <dB> slope without measuring (A/B and silicon
#                                  verification: on a flat channel this APPLIES a -<dB> tilt to the signal)
#   tilt_eq.sh <ip> --dry          print the plan, touch no board (TILT_EQ_DRY)
#
# Measurement: NSAMP Tap-A receiver-input samples (iio_readdev axi-adrv9002-rx-lpc, the capture_r3/carrier_probe
# path), scored by ops/tilt_score.py (dB across +-8 MHz); ops/tilt_eq_solve.py turns the tilt into a1..a3 and the
# two words (channel sign; the fabric applies the inverse). Writes go through direct_reg_access like every other
# rail; reads of the two words verify the write. Uses anyssh.sh, so it REFUSES under a foreign RIG_LOCK; it takes no
# lock itself (bring-up / the capture rails hold it). Never run while an arm is in flight.
#
# Output line (grep-able witness, also when the measurement is CLEAN and nothing is written):
#   TILT_EQ <ip> t_before=<dB> verdict=<CLEAN|MARGINAL|FADED> a1=.. a2=.. a3=.. w260=0x.. w264=0x.. readback=OK|MISMATCH t_after=<dB>
# With |t_before| < TILT_EQ_MIN_DB (default 3) the words are written as ZERO (bypass) -- a flat channel needs no
# correction and the bit-identical decode is preferred.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
IP=${1:?usage: tilt_eq.sh <ip> [--bringup|--off|--dry]}; MODE=${2:-}
NSAMP=${TILT_EQ_NSAMP:-262144}; MIN_DB=${TILT_EQ_MIN_DB:-3}
DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
TMP=${TILT_EQ_TMP:-$(mktemp -d /tmp/tilteq.XXXXXX)}
if [ "$MODE" = "--dry" ]; then
  echo "TILT_EQ_DRY $IP: iio_readdev -u local: -b 32768 -s $NSAMP axi-adrv9002-rx-lpc voltage0_i voltage0_q -> tilt_score.py --json -> tilt_eq_solve.py -> echo 0x260 <w> / 0x264 <w> > $DRA -> read back -> re-measure"
  exit 0
fi
measure(){ # -> tilt_db verdict
  $W "$IP" "iio_readdev -u local: -b 32768 -s $NSAMP axi-adrv9002-rx-lpc voltage0_i voltage0_q 2>/dev/null" > "$TMP/m.iq" || { echo "0 READ_FAIL"; return; }
  python3 "$D/tilt_score.py" --json "$TMP/m.iq" 2>/dev/null | tail -1 | python3 -c 'import sys,json
try: j=json.loads(sys.stdin.read()); print(j["tilt_db"], j["verdict"])
except Exception: print("0 SCORE_FAIL")'
}
write_words(){ # $1 w260 $2 w264 -> readback OK|MISMATCH
  $W "$IP" "echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
    echo '0x260 $1' > $DRA; echo '0x264 $2' > $DRA
    echo 0x260 > $DRA; r1=\$(cat $DRA); echo 0x264 > $DRA; r2=\$(cat $DRA); echo \"\$r1 \$r2\"" 2>/dev/null | tail -1 | python3 -c "import sys
f=sys.stdin.read().split()
try: ok = int(f[0],16)==int('$1',16) and int(f[1],16)==int('$2',16)
except Exception: ok=False
print('OK' if ok else 'MISMATCH '+' '.join(f))"
}
if [ "$MODE" = "--set" ]; then
  T=${3:?--set needs a tilt in dB}; line=$(python3 "$D/tilt_eq_solve.py" "$T"); A=$(echo "$line" | grep -oE 'a1=[^ ]+ a2=[^ ]+ a3=[^ ]+'); W260=$(echo "$line" | grep -oE '0x260=0x[0-9A-F]+' | cut -d= -f2); W264=$(echo "$line" | grep -oE '0x264=0x[0-9A-F]+' | cut -d= -f2)
  rb=$(write_words "$W260" "$W264")
  echo "TILT_EQ $IP set=$T $A w260=$W260 w264=$W264 readback=$rb"
  [ "$rb" = OK ]; exit $?
fi
if [ "$MODE" = "--off" ]; then
  rb=$(write_words 0x00000000 0x00000000)
  echo "TILT_EQ $IP off a1=0 a2=0 a3=0 w260=0x00000000 w264=0x00000000 readback=$rb"
  [ "$rb" = OK ]; exit $?
fi
set -- $(measure); T=$1; V=$2
if [ "$V" = READ_FAIL ] || [ "$V" = SCORE_FAIL ]; then echo "TILT_EQ $IP t_before=n/a verdict=$V -- not written"; exit 2; fi
if python3 -c "import sys; sys.exit(0 if abs(float('$T')) < float('$MIN_DB') else 1)"; then
  A="a1=+0.00000 a2=+0.00000 a3=+0.00000"; W260=0x00000000; W264=0x00000000
else
  line=$(python3 "$D/tilt_eq_solve.py" "$T"); A=$(echo "$line" | grep -oE 'a1=[^ ]+ a2=[^ ]+ a3=[^ ]+'); W260=$(echo "$line" | grep -oE '0x260=0x[0-9A-F]+' | cut -d= -f2); W264=$(echo "$line" | grep -oE '0x264=0x[0-9A-F]+' | cut -d= -f2)
fi
rb=$(write_words "$W260" "$W264")
set -- $(measure); T2=$1
echo "TILT_EQ $IP t_before=$T verdict=$V $A w260=$W260 w264=$W264 readback=$rb t_after=$T2"
[ "$rb" = OK ]
