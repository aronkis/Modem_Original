#!/bin/bash
# carrier_probe.sh -- choose the forward carrier that is NOT in a multipath fade today.
#
#   ops/carrier_probe.sh [RUNG=r3] [CANDIDATES="2100 2000 2150"] [HOLD_S=20] [OUT=<dir>] [DRY=1] [APPLY=1]
#
# For each candidate (MHz): bring the pair up with the forward plan at that carrier (146 TX = c, 148 RX = c +
# the rung's RX offset; the reverse plan untouched), read 148's fabric detection rate over HOLD_S s, grab a
# 1 M-sample Tap-A receiver-input window on 148 and score its in-band tilt (ops/tilt_score.py). Print one line per
# candidate and CARRIER_PROBE_CHOICE = the candidate with the smallest |tilt| among those with full detection
# (ties -> the table default first). With APPLY=1 the pair is left armed on the choice (one more bring-up);
# otherwise it is left on the LAST candidate probed and the caller re-arms. The rig mutex is held by each
# bring-up; the caller stops the degraded trigger around a probe. DRY=1 prints the plan and touches nothing.
#
# Why (docs/evidence/link/FORWARD_LINK_2026-10-01.md sec. 9): the forward air path has a frequency-selective
# slope that drifts ~100 MHz a day; the receiver has no equaliser, and a tilt > ~9 dB across its band costs 2-46 %.
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh; A=10.0.0.148
RUNG=${RUNG:-r3}; . "$D/rung_table.sh"; rung_set "$RUNG" || exit 2
CANDS=${CANDIDATES:-"2100 2000 2150"}; HOLD_S=${HOLD_S:-20}; OUT=${OUT:-$D/r3cap/carrier_probe_$(date +%Y%m%d_%H%M)}; DRY=${DRY:-0}; APPLY=${APPLY:-0}
RXOFF=$(( LO_A_RX_DEFAULT - LO_B_TX_DEFAULT ))       # the rung's forward RX offset (+20 kHz at r3, +60 kHz at r4)
mkdir -p "$OUT"; L=$OUT/probe.log
say(){ echo "[$(date '+%T')] $*" | tee -a "$L"; }
say "carrier_probe rung=$RUNG candidates=[$CANDS] MHz rx_offset=${RXOFF} Hz hold=${HOLD_S}s dry=$DRY apply=$APPLY out=$OUT"
best=""; bestt=""; rows=()
for c in $CANDS; do
  tx=$(( c * 1000000 )); rx=$(( tx + RXOFF ))
  if [ "$DRY" = 1 ]; then say "[DRY] bring-up fwd $tx/$rx; hold ${HOLD_S}s; iio_readdev 1M on $A; tilt_score"; rows+=("$c|dry|dry|dry"); continue; fi
  env -u SRO_SIGN_CONF LO_B_TX=$tx LO_A_RX=$rx "$D/bringup_r2r3.sh" "$RUNG" > "$OUT/bringup_$c.log" 2>&1; rc=$?
  grep -qE "BRING-UP COMPLETE" "$OUT/bringup_$c.log" || { say "cand $c MHz: bring-up rc=$rc ($(grep -m1 -oE 'ARM GATE FAILED.*|BAD LO PLAN.*|RIG_LOCKED.*' "$OUT/bringup_$c.log" | cut -c1-80)) -> excluded"; rows+=("$c|nolink|-|-"); continue; }
  p0=$($D/rigprobe.sh $A 0x104 2>/dev/null | grep -oE '0x104=0x[0-9A-Fa-f]+' | cut -d= -f2); sleep "$HOLD_S"; p1=$($D/rigprobe.sh $A 0x104 2>/dev/null | grep -oE '0x104=0x[0-9A-Fa-f]+' | cut -d= -f2)
  det=$(( ( $(( p1 )) - $(( p0 )) ) / HOLD_S ))
  $W $A 'iio_readdev -u local: -b 32768 -s 1000000 axi-adrv9002-rx-lpc voltage0_i voltage0_q > /dev/shm/probe.iq 2>/dev/null; cat /dev/shm/probe.iq' > "$OUT/probe_$c.iq" 2>/dev/null
  t=$(python3 "$D/tilt_score.py" --json "$OUT/probe_$c.iq" 2>/dev/null | tail -1)
  tilt=$(echo "$t" | python3 -c 'import sys,json; j=json.loads(sys.stdin.read()); print(j.get("tilt_db","n/a"))'); verdict=$(echo "$t" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("verdict","n/a"))')
  say "cand $c MHz: det=${det} f/s tilt=${tilt} dB/16MHz -> $verdict"; rows+=("$c|$det|$tilt|$verdict")
  if [ "$det" -ge "$GATE_FPS_DEFAULT" ] && [ "$tilt" != "n/a" ]; then
    at=$(python3 -c "print(abs(float('$tilt')))"); if [ -z "$best" ] || python3 -c "import sys; sys.exit(0 if $at < $bestt else 1)"; then best=$c; bestt=$at; fi
  fi
done
[ "$DRY" = 1 ] && { say "CARRIER_PROBE_CHOICE dry"; exit 0; }
[ -n "$best" ] || { say "CARRIER_PROBE_CHOICE none (no candidate had full detection) -- leaving the pair as probed"; exit 1; }
say "CARRIER_PROBE_CHOICE ${best} MHz (|tilt| ${bestt} dB) rows: ${rows[*]}"
if [ "$APPLY" = 1 ]; then tx=$(( best * 1000000 )); env -u SRO_SIGN_CONF LO_B_TX=$tx LO_A_RX=$(( tx + RXOFF )) "$D/bringup_r2r3.sh" "$RUNG" > "$OUT/bringup_apply.log" 2>&1 && say "CARRIER_PROBE_APPLIED fwd ${best} MHz" || say "CARRIER_PROBE_APPLY_FAILED (see $OUT/bringup_apply.log)"; fi
