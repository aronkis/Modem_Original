#!/bin/bash
# =============================================================================
# decay_watch.sh -- arm the pair, then watch BOTH receivers at 1 Hz. DECAY WATCH: arm the pair, then watch BOTH receivers at 1 Hz for DWELL seconds.
#
# Why: six independent arms today read 146 at 1237-1247 f/s at the gate, on BOTH bands, and the
# same board read 25-31 f/s twenty minutes later. An interleaved ROM-vs-byte test that controlled
# for time-since-pulse gave 1241 / 976 / 715 in cell order -- tracking the CLOCK, not the source.
# So the variable is TIME SINCE THE ARM, and nothing has ever measured its shape: every previous
# poll started after the leg had already collapsed.
#
# 148 is the simultaneous control: it is armed by the same bring-up, from the same host, in the
# same seconds. If 146 decays and 148 does not, the decay is on 148-TX or 146-RX, not shared.
#
# Usage:  OUT=<dir> [DWELL=1500] ops/launch_rig_unit.sh decaywatch ops/decay_watch.sh OUT=... 
# Always as a rig unit: it arms boards. Stop anything else that arms (the degraded trigger) first.
#
# Reading the output: score CFC against the CONTROL leg, never in isolation. On 2026-09-28 the
# control held median -3577 with p5..p95 only 476 units wide and 0.3 % of samples inside the
# dead zone, while the subject sat at +460 with a 21,798-unit spread and 26.0 % in the dead zone.
# Calibrating Hz/unit on the control (its deliberate offset divided by its median) is what turns
# the subject's displacement into a transmit-side frequency error in kHz.
# Filter torn reads before scoring: |0x154| > 2^20 and 0x104 rates above 3000 f/s are DRA read
# tears, not data (ops/rate_probe.sh carries the same ceiling and the reason for it).
# =============================================================================
set -u
D=/mnt/onetb/scratch/qpsk-jupiter-modem/ops
A=10.0.0.148; B=10.0.0.146
OUT=${OUT:?OUT=<dir>}; DWELL=${DWELL:-1500}
mkdir -p "$OUT"; L=$OUT/decay.log
say(){ echo "$(date -Is) $*" | tee -a "$L"; }

say "=== stage 1: r3 bring-up (default LO plan) ==="
"$D/bringup_r2r3.sh" r3 >>"$L" 2>&1 && say "BRINGUP_OK" || { say "BRINGUP_FAILED"; exit 1; }
say "  gate: $(grep '^gate try' "$L" | tail -1)"

. "$D/sim_repro/riglock.sh"
rig_lock "decaywatch-$$"
trap 'rig_unlock' EXIT

poll(){ # $1 ip  $2 outfile -- one persistent reader per board (single-reader rule is per board)
  "$D/anyssh.sh" "$1" "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
   echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
   end=\$(( \$(date +%s) + $DWELL ))
   while [ \$(date +%s) -lt \$end ]; do
     echo 0x104 > \$DRA; p=\$(cat \$DRA)
     echo 0x154 > \$DRA; c=\$(cat \$DRA)
     echo 0x150 > \$DRA; r=\$(cat \$DRA)
     echo \"\$(date +%s),\$p,\$c,\$r\"
     sleep 1
   done" 2>/dev/null > "$2"
}
say "=== stage 2: 1 Hz poll of BOTH boards for ${DWELL}s (146 = subject, 148 = control) ==="
poll $B "$OUT/rev_146.csv" &
pb=$!
poll $A "$OUT/fwd_148.csv" &
pa=$!
wait $pb $pa
say "POLL_DONE 146 rows=$(wc -l < "$OUT/rev_146.csv")  148 rows=$(wc -l < "$OUT/fwd_148.csv")"
