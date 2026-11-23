#!/bin/bash
# =============================================================================
# rom_air_ber.sh -- over-the-air BER from the fabric's own counters, BOTH directions.
# Ported 2026-09-27 onto the current rails from the pre-cleanup archive, where it lived under the
# old two-board ops directory that the 2026-09-09 rename retired. To read the original:
#   git show archive/pre-cleanup-2026-09-09 -- '*/comb/rom_air_ber.sh' Logic is the archived instrument's; the rails, the restore
# and the control gate are new.
#
# THE QUESTION THE OTHER INSTRUMENTS CANNOT ASK. capture_r3.sh scores the WHOLE stack: RF -> RX SSI
# -> fabric demod -> byte plane -> DMA -> host. This scores the PHY ALONE. With 0x158=0 both
# modulators run the Message_Generator ROM, each board radiates it, and each board's own post-Viterbi
# comparator scores the recovered bits against its local copy into 0x108 while 0x104 counts detected
# frames. No byte plane, no DMA, no host data path -- two AXI counters.
#
#   air BER ~ 0 while host PER is 13-18 %  =>  the loss lives ABOVE the demodulator (delivery plane)
#   air BER high                           =>  the defect is in the PHY: RF margin, peer TX, local RX
#
# DIRECTION MAPPING (get this backwards and the conclusion inverts): each board's 0x108 scores what
# THAT BOARD RECEIVED. So 10.0.0.146's row is the REVERSE leg (148 transmitting) and 10.0.0.148's row
# is the FORWARD leg. Both are measured in the same dwell, so each is the other's simultaneous
# control -- which is the point, since the reverse leg is the one under suspicion.
#
# 0x108 SCORES ONLY THE FIRST 120 OF 2240 BITS PER FRAME ([[bist-120bit-window]]). Every number here
# is FRAME-START damage, not a frame-wide BER. The TSV column is named accordingly; do not quote it
# as a link BER.
#
# POSITIVE CONTROL IS MANDATORY, NOT OPTIONAL. A floor reading proves nothing unless the same
# comparator can be made to read high: with 0x158=1 and no feeder the modulator underruns and
# radiates garbage against the receiver's ROM expectation, so the comparator MUST read high. Four
# collapsed legs once read the floor on the control side because the byte source was live. If the
# control does not read high this script reports VOID and no BER.
#
#   ops/rom_air_ber.sh                     # DRY=1 by default: prints the sequence, touches nothing
#   DRY=0 ops/rom_air_ber.sh OUT=<dir>
#   ops/launch_rig_unit.sh romber ops/rom_air_ber.sh OUT=<dir> DRY=0
#
# Env: DWELL=10 REPS=3 WINBITS=120 RUNG=r3 CTRL_MIN_EPF=5 OUT=<dir> DRY=1
#
# SAFETY. This is heavier than a capture: it kills the lock watchdog and the daemons, leaves both
# boards armed to ROM with no host feeder, and only a bring-up puts the rig back in service. The
# restore trap is installed BEFORE the quiesce step, retries, and falls back to
# restore_known_good.sh; the bring-up runs with GATE_DIR=A because a both-direction arm gate cannot
# pass during the very reverse-leg episode this instrument is for. A SIGKILL cannot be trapped, which
# is why DWELL and REPS are kept small -- total runtime is minutes, not tens of minutes.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd)
W=$D/anyssh.sh
A=10.0.0.148; B=10.0.0.146
OUT=${OUT:?OUT=<dir>}; DRY=${DRY:-1}
DWELL=${DWELL:-10}; REPS=${REPS:-3}; WINBITS=${WINBITS:-120}
RUNG=${RUNG:-r3}; CTRL_MIN_EPF=${CTRL_MIN_EPF:-5}
SS_FILE=${SENTINEL_STOP_FILE:-$HOME/modem-status/SENTINEL_STOP}
mkdir -p "$OUT"; L=$OUT/rom_air_ber.log; R=$OUT/rom_air_ber.tsv
log(){ echo "[$(date +%F_%T)] $*" | tee -a "$L"; }

alive(){ timeout 40 $W "$1" 'echo ok' 2>/dev/null | grep -q ok; }

rearm_common='DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA; echo "0x158 SRC">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x1">$DRA
TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done); T=/sys/kernel/debug/iio/$TXD/direct_reg_access
echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA'
rearm_rom(){  $W "$1" "${rearm_common/SRC/0x0}" >/dev/null 2>&1; }
rearm_byte(){ $W "$1" "${rearm_common/SRC/0x1}" >/dev/null 2>&1; }

# One board-side dwell, entirely inside a SINGLE ssh so the host never polls a board while it is
# armed (the no-ping-hang rule): read the counters, sleep, read again, print both.
dwell(){ timeout 120 $W "$1" "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
p1=\$(rd 0x104); e1=\$(rd 0x108); c1=\$(rd 0x154); r1=\$(rd 0x150); t1=\$(date +%s)
sleep $DWELL
p2=\$(rd 0x104); e2=\$(rd 0x108); c2=\$(rd 0x154); r2=\$(rd 0x150); t2=\$(date +%s)
echo \"p1=\$p1 p2=\$p2 e1=\$e1 e2=\$e2 c1=\$c1 c2=\$c2 r1=\$r1 r2=\$r2 dt=\$(( t2 - t1 ))\"" 2>/dev/null | tail -1; }

# wrap-aware 32-bit deltas -> frames/s, errors per frame, damage rate over the SCORED WINDOW
# score <raw-dwell-line> -> frames, errs, fps, err_per_frame, damage_rate, cfc1, cfc2, rstcs
score(){ python3 -c "
import re
s='''$1'''
g=dict(re.findall(r'(\w+)=(\S+)',s))
def v(k):
    x=g.get(k,'0')
    return int(x,16) if x.lower().startswith('0x') else int(x)
M=1<<32
dp=(v('p2')-v('p1'))%M; de=(v('e2')-v('e1'))%M; dt=max(1,v('dt'))
fps=dp/dt; epf=de/dp if dp else float('nan'); ber=epf/$WINBITS if dp else float('nan')
def sgn(x): return x-M if x>=(1<<31) else x
# metrics only: the caller prepends board, leg and stage, so nothing is duplicated and the
# column positions below are the ones the control gate and the header agree on
print('%d\t%d\t%.1f\t%.3f\t%.4g\t%d\t%d\t%d' % (dp,de,fps,epf,ber,sgn(v('c1')),sgn(v('c2')),(v('r2')-v('r1'))%M))
" 2>/dev/null; }

leg(){ case "$1" in "$A") echo forward ;; "$B") echo reverse ;; *) echo "?" ;; esac; }

log "=== rom_air_ber (ported) dry=$DRY out=$OUT dwell=${DWELL}s reps=$REPS window=${WINBITS}b rung=$RUNG ==="
log "    each board's 0x108 scores what IT received: $B = reverse leg, $A = forward leg"
if [ "$DRY" = 1 ]; then
  log "[dry] would: take rig mutex + SENTINEL_STOP, quiesce watchdog+daemons on both boards,"
  log "[dry]        CONTROL-HIGH (0x158=1, no feeder -> comparator must read >= ${CTRL_MIN_EPF} err/frame),"
  log "[dry]        $REPS ROM dwells of ${DWELL}s (0x158=0, both ends), then restore via"
  log "[dry]        bringup_r2r3.sh $RUNG with GATE_DIR=A, retried, falling back to restore_known_good.sh"
  log "ROM_AIR_BER_DRY_OK"; exit 0
fi

. "$D/sim_repro/riglock.sh"
rig_lock_only "romber-$(date +%H%M%S)"
SS_MINE=0
if [ ! -e "$SS_FILE" ]; then echo "rom_air_ber $(date -Is)" > "$SS_FILE"; SS_MINE=1
  log "SENTINEL_STOP taken (ours)"
else log "SENTINEL_STOP already present -- NOT ours, leaving it"; fi

RESTORED=0
restore(){
  [ "$RESTORED" = 1 ] && return 0
  RESTORED=1
  log "--- restore: bringup_r2r3.sh $RUNG (byte source, daemons, watchdogs), GATE_DIR=A ---"
  for try in 1 2; do
    if RUNG=$RUNG GATE_DIR=A "$D/bringup_r2r3.sh" "$RUNG" >>"$L" 2>&1; then
      log "restore: BRING-UP OK (attempt $try)"
      [ "$SS_MINE" = 1 ] && { rm -f "$SS_FILE"; log "SENTINEL_STOP released"; }
      rig_unlock_only; return 0
    fi
    log "restore: bring-up attempt $try FAILED"
  done
  log "--- restore: falling back to restore_known_good.sh ---"
  if "$D/restore_known_good.sh" >>"$L" 2>&1; then
    log "restore: restore_known_good OK"
  else
    log "ROM_AIR_BER_RESTORE_FAILED -- THE RIG IS NOT IN SERVICE, PHYSICAL/OPERATOR ATTENTION"
    { echo "rom_air_ber restore failed $(date -Is)"; echo "see $L"; } > "$OUT/RESTORE_FAILED"
  fi
  [ "$SS_MINE" = 1 ] && { rm -f "$SS_FILE"; log "SENTINEL_STOP released"; }
  rig_unlock_only
}
trap 'restore' EXIT INT TERM      # installed BEFORE the quiesce, so any exit path restores

for ip in $A $B; do alive $ip || { log "ROM_AIR_BER_FAIL $ip unreachable -- PHYSICAL ATTENTION"; exit 3; }; done

log "--- quiesce watchdog + daemons on both boards (single DRA writer from here on) ---"
for ip in $A $B; do
  $W $ip 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null
    pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; pkill -x qpsk_perf 2>/dev/null; sleep 1; echo quiesced' 2>/dev/null | tail -1 | sed "s/^/  $ip /" | tee -a "$L"
done

printf 'board\tleg\tstage\tframes\terrs\tfps\terr_per_frame\tframestart_damage_%sb\tcfc1\tcfc2\trstcs\n' "$WINBITS" > "$R"
# emit <ip> <stage> <score-row>; err_per_frame is field 4 OF THE SCORE ROW (fps is field 3)
emit(){ printf '%s\t%s\t%s\t%s\n' "$1" "$(leg "$1")" "$2" "$3" >> "$R"; }

log "--- CONTROL-HIGH: 0x158=1 with no feeder (modulator underruns -> garbage vs ROM expectation) ---"
rearm_byte $B; rearm_byte $A; sleep 3; rearm_byte $B; rearm_byte $A; sleep 4
CTRL_OK=1
for ip in $A $B; do
  S=$(dwell $ip); log "  $ip ctrl-high raw: $S"
  row=$(score "$S"); emit "$ip" ctrl_high "$row"
  epf=$(echo "$row" | cut -f4)
  awk -v e="${epf:-0}" -v m="$CTRL_MIN_EPF" 'BEGIN{exit !(e>=m)}' \
    || { log "  CONTROL FLOOR on $ip (err/frame ${epf:-none} < $CTRL_MIN_EPF) -- the comparator cannot be made to read high"; CTRL_OK=0; }
done

log "--- MEASURE: 0x158=0, ROM source both ends, over the air ---"
rearm_rom $B; rearm_rom $A; sleep 3; rearm_rom $B; rearm_rom $A; sleep 4
i=0
while [ $i -lt "$REPS" ]; do
  i=$(( i + 1 ))
  for ip in $A $B; do S=$(dwell $ip); log "  $ip rom rep$i raw: $S"; emit "$ip" "rom_r$i" "$(score "$S")"; done
  for ip in $A $B; do alive $ip || { log "ROM_AIR_BER_FAIL $ip unreachable after rep$i -- PHYSICAL ATTENTION"; exit 3; }; done
done

if [ "$CTRL_OK" = 1 ]; then log "ROM_AIR_BER_OK results=$R (control read high, so a floor in the ROM rows is evidence)"
else log "ROM_AIR_BER_VOID results=$R -- CONTROL DID NOT READ HIGH; the ROM rows are NOT evidence of a clean PHY"; fi
column -t "$R" 2>/dev/null | tee -a "$L"
