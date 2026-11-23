#!/bin/bash
# =============================================================================
# degraded_capture.sh -- the ACTION for ops/degraded_trigger.sh: capture the REVERSE leg while it is
# in a degraded episode, so the failure is recorded with per-frame data instead of only as a rate in
# the sentinel log.
#
#   ops/degraded_trigger.sh with ACTION="bash $PWD/ops/degraded_capture.sh <episode-dir>"
#   DRY=1 ops/degraded_capture.sh <dir>      # print the plan, touch nothing
#
# Env: DUR=300 RUNG=r3 GATE_DIR=A (see below) -- plus anything capture_r3.sh honours.
#      AIR_BER=1 adds a second stage: ops/rom_air_ber.sh in the SAME window (default 0).
#
# THIS ARMS BOTH BOARDS, UNATTENDED. That is a deliberate operator decision (2026-09-26), not a
# default: an arm is the worst instance of the register-traffic-racing-board-state class that hung
# 148 on 2026-09-25 with nobody present. It runs under capture_r3.sh, which takes the rig mutex and
# SENTINEL_STOP itself, so nothing else can touch the boards while it works.
#
# WHY GATE_DIR=A IS NOT OPTIONAL HERE. bringup_r2r3.sh's arm gate requires BOTH receivers to decode
# at >= GATE_FPS. During a reverse-leg episode 146 is exactly the side that cannot, so a plain
# capture burns all six arm re-rolls and produces nothing -- measured on 2026-09-25/26, where six
# captures ground through about 36 arms and 40 minutes to yield a table of "(no frames.bin)"
# (gate3_pair.sh's fail-fast comment). GATE_DIR=A scopes the gate to the forward direction, which is
# healthy, so the bring-up completes and the capture can observe the degraded reverse leg.
#
# THE PERTURBATION TO KEEP IN MIND. The capture's own bring-up re-arms both boards, and an arm could
# in principle clear the episode -- in which case we record its aftermath, not the episode. The
# evidence says episodes survive arms (the 09-22 episode ran 381 minutes across the board
# watchdog's own re-arms), but it is not guaranteed, so the verdict below states plainly whether the
# reverse leg was still degraded DURING the capture rather than assuming it.
#
# There is no external timeout on purpose: killing a restore mid-arm is itself a way to hang a
# board. capture_r3.sh is bounded by GATE_TRIES and its own -k watchdogs.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd)
DIR=${1:?usage: degraded_capture.sh <episode-dir>}
DUR=${DUR:-300}; RUNG=${RUNG:-r3}
mkdir -p "$DIR"
V=$DIR/CAPTURE_VERDICT.txt
say(){ echo "[$(date +%F_%T)] $*" | tee -a "$DIR/capture_action.log"; }

say "degraded capture: reverse leg (B), ${DUR}s at RUNG=$RUNG, arm gate scoped to the forward direction"
if [ "${DRY:-0}" = 1 ]; then
  say "[DRY] RUNG=$RUNG GATE_DIR=A $D/capture_r3.sh B -d $DUR -k -o $DIR/capture"
  [ "${AIR_BER:-0}" = 1 ] && say "[DRY] then second stage: OUT=$DIR/airber DRY=0 $D/rom_air_ber.sh"
  say "[DRY] then tilt snapshot: 262144 Tap-A samples from ${TILT_IP:-10.0.0.146} -> tilt_score.py -> $DIR/tilt.json"
  { echo "dry=1"; echo "would_run=capture_r3.sh B -d $DUR -k (RUNG=$RUNG GATE_DIR=A)"; } > "$V"
  say "DEGRADED_CAPTURE_DONE dry"
  exit 0
fi

# create the capture dir FIRST: redirecting through "$DIR/capture/.." fails while that directory
# does not exist, and a failed redirect means capture_r3.sh never runs at all
mkdir -p "$DIR/capture"
RUNG=$RUNG GATE_DIR=A "$D/capture_r3.sh" B -d "$DUR" -k -o "$DIR/capture" \
  > "$DIR/capture_r3.out" 2>&1
rc=$?
say "capture_r3.sh rc=$rc"
# 2026-10-07 (tilted-day watch, TILT_EQ_2026-10-03.md sec. 4): whatever the capture did, score the in-band tilt the
# degraded receiver sees RIGHT NOW from a fresh 262k-sample Tap-A window (ops/tilt_score.py). A FADED verdict here is
# the day the tilt corrector's on-air benefit can be measured (an on/off cell pair); the file is tilt.json.
TILT_IP=${TILT_IP:-10.0.0.146}
"$D/anyssh.sh" "$TILT_IP" 'iio_readdev -u local: -b 32768 -s 262144 axi-adrv9002-rx-lpc voltage0_i voltage0_q 2>/dev/null' > "$DIR/tilt.iq" 2>/dev/null
tilt=$(python3 "$D/tilt_score.py" --json "$DIR/tilt.iq" 2>/dev/null | tail -1); [ -n "$tilt" ] && echo "$tilt" > "$DIR/tilt.json" || tilt='{"tilt_db": null, "verdict": "UNREAD"}'
rm -f "$DIR/tilt.iq"
tilt_line=$(echo "$tilt" | python3 -c 'import sys,json
try: j=json.loads(sys.stdin.read()); print(f"tilt_db={j.get(\"tilt_db\")} dip_db={j.get(\"dip_db\")} verdict={j.get(\"verdict\")}")
except Exception: print("tilt_db=n/a verdict=UNREAD")')
say "receiver in-band tilt ($TILT_IP): $tilt_line"

score="(no frames.bin)"; frames=$DIR/capture/frames.bin
if [ -f "$frames" ]; then
  python3 "$D/accept_analyze.py" "$frames" > "$DIR/capture/accept.txt" 2>&1
  score=$(grep -E "live [0-9]+s/|UNUSABLE|PERTURBED" "$DIR/capture/accept.txt" | head -1 | sed 's/^ *//')
fi

# Was the leg STILL degraded while we watched? The sentinel is held down during a capture, so its
# log cannot answer; the capture's own delivery is the measurement. Anything at or above the
# healthy band means the arm cleared the episode and this capture is its aftermath, not the event.
per=$(echo "$score" | grep -oE 'PER=[0-9.]+%' | head -1 | tr -dc '0-9.')
state="UNKNOWN (no PER -- see capture_r3.out)"
if [ -n "$per" ]; then
  if awk -v p="$per" 'BEGIN{exit !(p>=5)}'; then state="STILL DEGRADED (reverse PER ${per}% >= 5%) -- the episode was captured"
  elif awk -v p="$per" 'BEGIN{exit !(p<1)}'; then state="RECOVERED (reverse PER ${per}% < 1%) -- the arm cleared it; this is the aftermath, not the event"
  else state="MARGINAL (reverse PER ${per}%) -- between the healthy band and the episode"; fi
fi
{
  echo "captured_at=$(date -Is)"
  echo "leg=B (reverse, 146 receiving) rung=$RUNG dur=${DUR}s gate_dir=A"
  echo "capture_r3_rc=$rc"
  echo "accept=$score"
  echo "episode_state=$state"
  echo "tilt=$tilt_line"
  echo "note=PER counts lost frames in the denominator (accept_analyze.py live window)."
  echo "note=the bring-up re-armed both boards, so a RECOVERED verdict means the episode was"
  echo "     perturbed by the measurement and the data is not of the event."
} > "$V"
say "DEGRADED_CAPTURE_DONE rc=$rc  $state"

# ---- optional second stage: the PHY-only measurement, in the SAME window --------------------------
# Pairing them is the whole point. The capture above scores the WHOLE stack (RF -> demod -> byte
# plane -> DMA -> host); rom_air_ber.sh scores the PHY alone from two AXI counters. Run back to back
# in one episode, the pair says whether the loss is in the air or above the demodulator, on the same
# degradation rather than on two different ones.
#
# Order: capture FIRST. Its verdict is what establishes the window was genuinely degraded, and the
# 2026-09-27 run showed an episode survives the bring-up in between (146 was still at 808 f/s when
# the rig went back into service).
#
# AIR_BER defaults to 0 here: this stage kills both watchdogs and both daemons and leaves the boards
# on ROM with no feeder until its restore runs, which is heavier than a capture. The deployed unit
# opts in through its ACTION string, so the repo default stays conservative.
if [ "${AIR_BER:-0}" = 1 ]; then
  say "--- second stage: PHY-only air BER in the same window ---"
  {
    OUT="$DIR/airber" DRY=0 "$D/rom_air_ber.sh" >> "$DIR/capture_action.log" 2>&1
    arc=$?
    tsv=$DIR/airber/rom_air_ber.tsv
    verdict=$(grep -oE 'ROM_AIR_BER_(OK|VOID|FAIL)' "$DIR/airber/rom_air_ber.log" 2>/dev/null | tail -1)
    say "AIR_BER_DONE rc=$arc ${verdict:-NO_VERDICT}"
    {
      echo "=== the pair, same window ==="
      echo "host-visible (whole stack): $score"
      echo "episode_state=$state"
      echo "PHY-only verdict: ${verdict:-NO_VERDICT} (rc=$arc)"
      echo "  a run that is not ROM_AIR_BER_OK is NOT evidence of a clean PHY -- the control must read high"
      echo "  every air number is FRAME-START damage over a 120-bit window, never a link BER"
      echo "  146 = reverse leg, 148 = forward leg (each board scores what IT received)"
      echo
      [ -f "$tsv" ] && column -t "$tsv" 2>/dev/null
    } > "$DIR/PAIR_SUMMARY.txt"
    say "pair summary -> $DIR/PAIR_SUMMARY.txt"
  }
fi
exit "$rc"
