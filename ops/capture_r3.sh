#!/bin/bash
# =============================================================================
# capture_r3.sh {A|B} [opts] -- THE PAIRED CAPTURE (rungs r3/f1536 and r4/f3072): per-frame
# telemetry (QPSK_FRAMELOG frames.bin) + a concurrent Tap-A raw ADC I/Q window on the RX
# target, over a live 61.44 MSPS link (15.36 Msym/s f1536 at r3; 30.72 Msym/s f3072 at r4,
# sp4 2026-09-22), for the PER<1%
# reproduction campaign (Workstream R at R3 -- the open 148-RX-tick vs 146-TX-EVM
# question the 240k taxonomy never settled).
#
#   A : capture on 148, forward  146 TX -> 148 RX   (the ~6.7% forward loss dir)
#   B : capture on 146, reverse  148 TX -> 146 RX
#
# Reuses the PROVEN R3 bring-up verbatim (bringup_r2r3.sh r3: CFO offset policy,
# safe SSI overrides, ROM arm-quality gate + double-tap) via a QPSK_FRAMELOG
# passthrough, so the daemons it starts log per-frame telemetry. Sequence:
#   deploy+build qpsk_tun (logger + the rung's carve flag, ops/rung_table.sh) -> bringup_r2r3.sh $RUNG ->
#   (RUNG env: r3 | r4; unset = read back from the RX board's running daemon (-r 15360 -> r3,
#    -r 30720 -> r4); FATAL if no daemon runs and RUNG is unset. The board's live dtb carve
#    must be >= the rung's carve, else FATAL before the build.) ->
#   KILL WATCHDOGS (a mid-capture re-arm corrupts both records) -> verify lock ->
#   drive saturating traffic (peer -> target tun) -> Tap-A iio_readdev on target
#   with pkts=0x104 anchor -> pull frames.bin + pair.iq + regs -> quiesce.
#
# Correlate offline: ops/frame_taxonomy.py frames.bin (fresh R3 taxonomy);
#   ops/align_frames.py frames.bin regs_cap.txt --spf 49332  (errored frames
#   -> pair.iq windows); reproduce via modem/rtl_sim (obj_byte_f1536)
#   + evm_ideal_ref(evm_config_1536k).
#
# Options: -d DUR (traffic secs, def 60)  -n NSAMP (Tap complex samp, def 4000000
#          ~65 ms @61.44 Msps)  -o OUTDIR (def r3cap/<ts>_<dir>)  -k (keep link up,
#          watchdogs relaunched -- default quiesces both boards at the end to the known state)
#          -P (ping payload bytes, def 1400)
# Output:  pair.iq (int16 I,Q @61.44 Msps), frames.bin (+frames_peer.bin), 48 B/
#          frame, correlate to pair.iq via CAP_START pkts=0x104), regs_{pre,cap,
#          post}.txt, meta.txt, qpsk_tun.log(+peer), recovery.txt (only if a
#          mid-window recovery happened -- see below)
#
# -----------------------------------------------------------------------------
# MID_RECOVER  -- KNOB NAME AND DEFAULT: MID_RECOVER=0 (OFF).  RXFIX Task 44.
# -----------------------------------------------------------------------------
# MID_RECOVER=0 (the default, and what happens if the variable is never set) is
# EXACTLY today's behaviour: a mid-window delivery flatline of >= STALL_MAX s
# aborts the leg with CAPTURE_ABORTED_WEDGED / exit 3, and no recovery.txt is
# written.  Every line below that changes anything is inside a `MID_RECOVER=1`
# test.  Roughly 3 legs in 10 die that way today.
#
# MID_RECOVER=1: the same detector, instead of aborting, issues ONE RX-ONLY
# double-tap re-arm, waits a BOUNDED RECOVER_WAIT s for delivery to come back,
# and (if it does) carries on with the window -- recording the perturbed
# interval in $OUT/recovery.txt so the scoring tools drop it from BOTH the
# numerator and the denominator (ops/recovery_windows.py; honoured by
# accept_analyze.py and comb/comb_period_ms.py).  If delivery does NOT come
# back the leg still fails, with its OWN marker: CAPTURE_ABORTED_RECOVERY_FAILED
# and wedge_verdict=MID_CAPTURE_RECOVERY_FAILED ... "NOT usable data", exit 3.
#   RECOVER_MAX=1      recoveries allowed per leg (then it aborts as above)
#   RECOVER_WAIT=30    seconds to wait for delivery after the re-arm.  Task 43
#                      measured the same latch clearing in 6.4 s and 8.5 s.
#   RECOVER_SETTLE=15  seconds AFTER delivery returns that are excluded from
#                      scoring but NOT waited for -- the re-arm restarts
#                      acquisition, and 15 s is accept_analyze.py's own
#                      post-arm settle.
#   RECOVER_GUARD_PRE=2  seconds before the last healthy poll to start the
#                      exclusion (accept_analyze's own degradation-ramp guard).
#   RECOVER_CONFIRM=2  consecutive healthy polls needed to call it recovered.
#   RECOVER_EXTEND=1   extend the traffic window by the perturbed wall time, so
#                      a recovered leg still yields DUR seconds of scored data.
# WALL-CLOCK BOUND, so a unit timeout can be sized: the leg can run at most
#   RECOVER_MAX * (STALL_MAX + RECOVER_WAIT + 20) s longer than today
#   = 1 * (12 + 30 + 20) = 62 s at the defaults, always inside qpsk_perf's
#   PERF_T = DUR + 400 headroom.
# MID_RECOVER IS INERT if a wrapper raises STALL_MAX out of reach: e.g.
# rxfix/ladder146_go.sh exports STALL_MAX=DUR+120 so its deliberate collapse is
# never aborted -- with that export the detector never fires and nothing is
# recovered.
#
# WHY capture_r3.sh AND NOT "LET lock_watchdog.sh RUN" (the other candidate).
# The on-board watchdog does clear this latch -- Task 43 measured 2 of 2, 8.5 s
# and 6.4 s, acting 2.1 s after onset, against 0 of 4 recovering in >= 150 s
# with it killed (Task 42).  It is still the wrong instrument INSIDE a capture:
#  1. bringup_r2r3.sh:210-214 launches it with DAEMON_CMD set, so its
#     BYTE-PLANE and DELIVERY-WEDGE paths RESTART qpsk_tun.  A daemon restart
#     re-opens /dev/shm/frames.bin and destroys the pre-collapse record -- the
#     scored artefact itself -- and legrun_go.sh:115-128 already zeroes
#     GATE_PASS on any watchdog relaunch.  Leaving it running is therefore not
#     one knob but a three-file change (comb/keeper_hold.sh, bringup_r2r3.sh
#     and step 3 here all kill it) whose blast radius includes frames.bin.
#  2. It is a SECOND direct_reg_access user for the WHOLE window.  The modem
#     register file is read through one shared address-select register
#     (w1leg_go.sh's header): two readers interleave and each `cat`s the
#     other's selected address, silently, with a plausible value.  The
#     watchdog reads 0x150/0x104/0x108/0x15C/0x1C0 every ~5-9 s all leg long;
#     a W1 sweep is 16-18 addresses.  The re-arm here is ONE bounded event at a
#     RECORDED instant, so the affected sweep is identifiable instead of the
#     whole census being suspect.
#  3. The recovery must be BOUNDED and the leg must fail honestly if it does
#     not work.  That decision belongs to the process that owns the abort.
# The watchdog remains the right answer in normal service, where it already runs.
#
# WHY THE RE-ARM IS RX-ONLY, AND A DOUBLE TAP.  Task 42's ladder cleared this
# latch with a 146-only modem re-arm (S3, 4 of 4) and lock_watchdog's
# full_rearm is also one-sided; the double tap is full_rearm's own DOUBLETAP
# (a reset taken while the peer's TX is mid-recovery latches a false FTS state
# that only a second 0x000 clears).  Re-arming the PEER would (a) stall its
# transmit feed, which is the 7 ms dose that collapses a far receiver in 38/38
# cases, and (b) put a discontinuity in host_seq -- a TX-side header quantity,
# and the very axis the leg is scored on.  RX-only keeps the slot axis provably
# continuous across the perturbation, which is what makes per-segment scoring
# valid.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
SRC=$(cd "$D/.." && pwd)/host
A_IP=10.0.0.148; B_IP=10.0.0.146
TA=10.66.0.2; TB=10.66.0.1          # tun endpoints (148 / 146), per bringup_r2r3.sh
. "$D/rung_table.sh"                # rung_set -> PROF FS KSYM SPS FRAME SPF FPS TUN_GFLAG CARVE_MB CARVE_CFLAG PERF_BPS

TGT=${1:?usage: capture_r3.sh A-or-B [-d dur] [-n nsamp] [-o out] [-k] [-P payload]}
shift
DUR=60; NSAMP=4000000; OUT=""; KEEP=0; PAY=1400
while [ $# -gt 0 ]; do
  case "$1" in
    -d) DUR=$2; shift 2;;
    -n) NSAMP=$2; shift 2;;
    -o) OUT=$2; shift 2;;
    -k) KEEP=1; shift;;
    -P) PAY=$2; shift 2;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done
case "$TGT" in
  A) RX_IP=$A_IP; PEER_IP=$B_IP; TUN_TGT=$TA; DIRN=fwd;;
  B) RX_IP=$B_IP; PEER_IP=$A_IP; TUN_TGT=$TB; DIRN=rev;;
  *) echo "target must be A (capture on 148, fwd) or B (capture on 146, rev)" >&2; exit 2;;
esac
[ -n "$OUT" ] || OUT=$D/r3cap/$(date +%Y%m%d_%H%M%S)_${DIRN}
mkdir -p "$OUT"
# A recovery.txt in the output directory must describe THIS capture: it is the
# file every scoring tool silently keys on (ops/recovery_windows.py), and a
# re-run into an existing -o dir overwrites frames.bin, so a leftover record
# from the previous run would mark the NEW leg as perturbed over an interval
# that has nothing to do with it. Removed before the leg starts; MID_RECOVER=1
# recreates it only if a recovery actually happens, and with the knob off (the
# default) there is never one to recreate.
#
# 2026-09-06 (review BLOCKING 1): this used to run UNCONDITIONALLY, i.e. also on the
# MID_RECOVER=0 default path, where it is not merely inert -- it DELETES the record of
# a perturbation written by a previous run into the same $OUT, silently converting a
# perturbed leg into one that scores as clean. It is now inside the knob, so the
# default path touches nothing, and a stale file on the default path is left in place
# to be seen rather than removed.
[ "${MID_RECOVER:-0}" = 1 ] && rm -f "$OUT/recovery.txt"

# scp stderr goes to a logfile, not /dev/null: 6/6 fetches failed silently in
# sweep_130815 (completed captures lost) while the identical command succeeded
# by hand -- the next failure must leave its actual error behind.
scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>>/tmp/capture_scp_err.txt; }
snap(){ $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access; rd(){ echo "$1">$DRA;cat $DRA; }
   echo "t=$(date +%s.%N) pkts=$(rd 0x104) biterr=$(rd 0x108) rstcs=$(rd 0x150) cfc=$(rd 0x154) fx=$(rd 0x15C) bytewords=$(rd 0x1C0) sro_mode=$(rd 0x25C) r4_wit=$(rd 0x234) r4_extras=$(rd 0x238) fixshadow=$(tr -d " \r\n" < /dev/shm/fixctl.word 2>/dev/null)"' 2>/dev/null; }
# byte-source double-tap re-arm (mirrors bringup_r2r3.sh rearm_byte): clears a
# sync-but-CRC wedge. If the link is genuinely degraded (146 TX margin), this
# does NOT clear it -> the wedge check will exhaust its tries and flag it.
# sro_reapply -- rearm_byte's first act is a 0x000 fabric reset, which CLEARS fixctl 0x208; the
# bring-up writes sro_sign there as its deliberate LAST step, so without this every re-arm silently
# drops 146 to the R4B steering branch (measured 2026-09-24: reverse leg 0.05 % -> 7.9 %, three arms).
# Same hook bringup_r2r3.sh ends with. Guarded on $D so ops/tests/test_capture_r3_recovery.py, which
# sources recover_once as a standalone function slice and defines no $D, keeps working.
sro_reapply(){ [ -n "${D:-}" ] || return 0
  bash "$D/sro_sign.sh" "$1" --bringup || echo "  SRO_SIGN_REAPPLY_FAILED $1 (after a 0x000 re-arm)"; }
rearm_byte(){ $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA; echo "0x158 0x1">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x1">$DRA
 TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done); T=/sys/kernel/debug/iio/$TXD/direct_reg_access
 echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA' 2>/dev/null; }
# CRC pass-fraction over ~6 s from the daemon's own stats (needs traffic
# flowing). Echoes an integer percent, or -1 if no frames moved.
crc_health(){ $W $1 'L=/dev/shm/qpsk_tun.log; g(){ grep "stats:" $L 2>/dev/null | tail -1; }
 s1=$(g); ok1=$(echo "$s1"|grep -o "dma_rx_ok=[0-9]*"|cut -d= -f2); c1=$(echo "$s1"|grep -o "crc_drop=[0-9]*"|cut -d= -f2)
 sleep 6; s2=$(g); ok2=$(echo "$s2"|grep -o "dma_rx_ok=[0-9]*"|cut -d= -f2); c2=$(echo "$s2"|grep -o "crc_drop=[0-9]*"|cut -d= -f2)
 dok=$(( ${ok2:-0} - ${ok1:-0} )); dc=$(( ${c2:-0} - ${c1:-0} )); tot=$((dok+dc))
 [ $tot -gt 0 ] && echo $(( 100 * dok / tot )) || echo -1' 2>/dev/null; }

# DELIVERY RATE (frames/s of dma_rx_ok). This is the check crc_health cannot make: a
# ratio of good-to-total is ~100% in a wedge because the host decodes almost nothing and
# what little it decodes is clean. Only a rate distinguishes "healthy" from "flatlined".
# R3 nominal is ~1245 f/s (12333 sym/frame at 15.36 Msym/s).
deliver_rate(){ $W $1 'L=/dev/shm/qpsk_tun.log; g(){ grep "stats:" $L 2>/dev/null | tail -1; }
 o1=$(g|grep -o "dma_rx_ok=[0-9]*"|cut -d= -f2); t1=$(date +%s)
 sleep 6; o2=$(g|grep -o "dma_rx_ok=[0-9]*"|cut -d= -f2); t2=$(date +%s)
 dt=$(( t2 - t1 )); [ $dt -le 0 ] && dt=1
 echo $(( ( ${o2:-0} - ${o1:-0} ) / dt ))' 2>/dev/null; }

# forward-path health (peer side): counts idle_rx as OK (in a reverse capture the
# forward direction carries keepalives + ARQ NAKs, which land as idle_rx/rx_ok).
fwd_health(){ $W $1 'L=/dev/shm/qpsk_tun.log; g(){ grep "stats:" $L 2>/dev/null | tail -1; }
 s1=$(g); ok1=$(echo "$s1"|grep -o "dma_rx_ok=[0-9]*"|cut -d= -f2); i1=$(echo "$s1"|grep -o "idle_rx=[0-9]*"|cut -d= -f2); c1=$(echo "$s1"|grep -o "crc_drop=[0-9]*"|cut -d= -f2)
 sleep 6; s2=$(g); ok2=$(echo "$s2"|grep -o "dma_rx_ok=[0-9]*"|cut -d= -f2); i2=$(echo "$s2"|grep -o "idle_rx=[0-9]*"|cut -d= -f2); c2=$(echo "$s2"|grep -o "crc_drop=[0-9]*"|cut -d= -f2)
 dok=$(( ${ok2:-0} - ${ok1:-0} + ${i2:-0} - ${i1:-0} )); dc=$(( ${c2:-0} - ${c1:-0} )); tot=$((dok+dc))
 [ $tot -gt 0 ] && echo $(( 100 * dok / tot )) || echo -1' 2>/dev/null; }

# rig mutex (plan 2026-09-25 Task 2): hold it for the whole run so ad-hoc board access is
# refused at ops/anyssh.sh while this rail owns the rig. Nesting-safe.
. "$D/sim_repro/riglock.sh"
rig_lock_only "capture_r3-$TGT"
# SENTINEL HOLD (2026-09-25, Task 8 validation). The lock alone is not enough when this script is
# run STANDALONE: the delivery sentinel keeps probing, its probes are refused by the lock guard, it
# reads that as "probe failed (ssh?)", escalates to a recovery, and that recovery is refused too --
# churn, plus spurious failures in its log. Holding SENTINEL_STOP makes it exit cleanly on its next
# cycle, which is the mechanism it was built for. Ownership rule unchanged: a hold we did not create
# is never removed. Campaign rails that already hold it pass straight through.
CR3_SS_FILE=${SENTINEL_STOP_FILE:-$HOME/modem-status/SENTINEL_STOP}
CR3_SS_MINE=0
if [ -e "$CR3_SS_FILE" ]; then echo "  SENTINEL_STOP pre-exists (external hold or parent rail) -- left alone"
else echo "capture_r3 $TGT $(date -Is)" > "$CR3_SS_FILE"; CR3_SS_MINE=1; echo "  SENTINEL_STOP taken"; fi
cr3_release(){ rig_unlock_only; [ "$CR3_SS_MINE" = 1 ] && rm -f "$CR3_SS_FILE" && echo "  SENTINEL_STOP released"; return 0; }
trap cr3_release EXIT
# 0. the rung: RUNG env, else read back from the RX board's running daemon (never a
#    hardcoded default -- the shipped rig and the sp4 rig differ in carve and geometry).
if [ -z "${RUNG:-}" ]; then
  KS=$($W $RX_IP 'P=$(pgrep -x qpsk_tun 2>/dev/null | head -1); [ -n "$P" ] && tr "\0" " " < /proc/$P/cmdline | grep -o -- "-r [0-9]*" | cut -d" " -f2' 2>/dev/null | tail -1)
  RUNG=$(rung_from_ksym "${KS:-}") || { echo "FATAL: cannot infer the rung (no qpsk_tun running on $RX_IP, got -r '${KS:-}'); set RUNG=r3|r4" >&2; exit 2; }
  echo "  rung: $RUNG (read back from $RX_IP's daemon -r $KS)"
fi
rung_set "$RUNG" || exit 2
PERF_MBIT=$(( PERF_BPS / 1000000 ))
FRAME_PERIOD_S=$(awk "BEGIN{printf \"%.9f\", $SPF / $FS}")
echo "=== capture_r3 $TGT ($DIRN): $RUNG/$FRAME link ($KSYM ksym, $SPS sps, ${CARVE_MB} MB carve), ${DUR}s traffic, Tap-A ${NSAMP} samp on $RX_IP -> $OUT ==="

# 1. deploy qpsk_tun source (with the QPSK_FRAMELOG logger) + build on-board with
#    the rung's carve flag so bringup's daemons are the logger build. The board's live
#    dtb carve is checked first: a build for a bigger carve than the dtb reserves would
#    DMA into kernel memory.
for ip in $B_IP $A_IP; do
  $W $ip 'mkdir -p /root/host_app_k5' 2>/dev/null
  CMB=$($W $ip 'R=/sys/firmware/devicetree/base/reserved-memory/qpsk_byte_buf@7ff00000/reg; [ -f $R ] && echo $(( 0x$(od -An -tx1 -j12 -N4 $R | tr -d " \n") / 1048576 )) || echo 0' 2>/dev/null | tail -1)
  [ "${CMB:-0}" -ge "$CARVE_MB" ] || { echo "FATAL: $ip live dtb carve is ${CMB:-?} MB, rung $RUNG needs >= $CARVE_MB MB -- deploy the dtb first (ops/deploy_dtb.sh $ip, images/CURRENT.txt DTB rows)" >&2; exit 3; }
  echo "  $ip: dtb carve ${CMB} MB (rung needs $CARVE_MB) -> build $CARVE_CFLAG"
  # qpsk_fixregs.h is GENERATED (modem/fixes/gen_regmap.py from fixes.toml) and is
  # #include'd by qpsk_hw.h since commit acd1e746. It was missing from this list, so the
  # on-board rebuild died with "fatal error: qpsk_fixregs.h: No such file or directory"
  # on a board that had never had it staged by hand (Task 11a, 2026-09-10). Keep this
  # list == the local #include closure of qpsk_tun.c and friends.
  scpput "$SRC/qpsk_tun.c" "$SRC/qpsk_frame.c" "$SRC/qpsk_frame.h" "$SRC/qpsk_hw.h" \
         "$SRC/qpsk_fixregs.h" \
         "$SRC/qpsk_ber.c" "$SRC/qpsk_ber.h" "$SRC/qpsk_seq.c" "$SRC/qpsk_seq.h" \
         "$SRC/qpsk_uio.c" "$SRC/qpsk_uio.h" "$SRC/qpsk_join.h" "$SRC/qpsk_perf.c" root@$ip:/root/host_app_k5/ \
         || { echo "scp $ip FAIL"; exit 1; }
  # GUARD (2026-08-07): this rebuild used to SILENTLY STRIP deployed instrumentation.
  # The NAK-path counters are compile-time gated on -DQPSK_ARQ_NAKSTAT; rebuilding
  # with only -DQPSK_CARVE_2MB removes them, and nothing tells you -- the daemon just
  # stops emitting the nakstat line. Detect what the board is ALREADY running (the
  # counter's format string is in the binary) and preserve it, so the safe behaviour
  # is the default and needs no env var anyone has to remember.
  # HOST_CFLAGS appends extra flags explicitly; NAKSTAT=0 force-disables the carry-over.
  # NAKKEEP, not KEEP: KEEP is already the -k (keep-link-up) option variable, and the
  # first version of this guard clobbered it -- silently disabling -k for every caller.
  NAKKEEP=$($W $ip 'strings /root/host_app_k5/qpsk_tun 2>/dev/null | grep -q "nakstat:" \
         && echo "-DQPSK_ARQ_NAKSTAT" || echo ""' 2>/dev/null)
  [ "${NAKSTAT:-1}" = 0 ] && NAKKEEP=""
  [ -n "$NAKKEEP" ] && echo "  $ip: preserving deployed NAK-stat instrumentation ($NAKKEEP)"
  # HOST_CFLAGS_B: extra flags for board B (146) ONLY. The queued-RX instrumentation
  # (-DQPSK_RXQ_STAT) belongs on the RX board, and board A (148) must rebuild to a
  # functionally untouched binary -- with the flag off the source is byte-identical, so
  # scoping it here keeps 148's AXR-counter build exactly as deployed.
  BCF=""; [ "$ip" = "$B_IP" ] && BCF="${HOST_CFLAGS_B:-}"
  R=$($W $ip "cd /root/host_app_k5 && gcc -O2 -Wall $CARVE_CFLAG $NAKKEEP ${HOST_CFLAGS:-} $BCF -o qpsk_tun \
        qpsk_tun.c qpsk_frame.c qpsk_ber.c qpsk_seq.c qpsk_uio.c 2>/tmp/gcc.err \
        && gcc -O2 -Wall -o qpsk_perf qpsk_perf.c 2>>/tmp/gcc.err \
        && echo BUILD_OK || { echo BUILD_FAIL; cat /tmp/gcc.err; }" 2>/dev/null)
  echo "  $ip build: $(echo "$R" | tail -1)"; echo "$R" | grep -q BUILD_OK || exit 1
  # verify the instrumentation survived, rather than assuming the flag did its job
  if [ -n "$NAKKEEP" ]; then
    $W $ip 'strings /root/host_app_k5/qpsk_tun 2>/dev/null | grep -q "nakstat:" \
      && echo "  '"$ip"': NAK-stat counter VERIFIED present after rebuild" \
      || echo "  '"$ip"': WARNING NAK-stat counter LOST in rebuild"' 2>/dev/null
  fi
  # same discipline for the queued-RX instrumentation: verify, never assume the flag took
  case "$BCF" in *QPSK_RXQ_STAT*)
    $W $ip 'strings /root/host_app_k5/qpsk_tun 2>/dev/null | grep -q "rxqstat:" \
      && echo "  '"$ip"': RXQ-stat counter VERIFIED present after rebuild" \
      || echo "  '"$ip"': WARNING RXQ-stat counter MISSING after rebuild"' 2>/dev/null ;;
  esac
done

# 2. proven bring-up with per-frame logging (QPSK_FRAMELOG passthrough), at the rung.
echo "--- bringup_r2r3.sh $RUNG (logger on) ---"
QPSK_FRAMELOG=/dev/shm/frames.bin "$D/bringup_r2r3.sh" "$RUNG" || { echo "$RUNG BRINGUP FAILED"; exit 1; }

# 3. kill watchdogs BOTH (a mid-capture re-arm corrupts the record; the wedge
#    check below replaces the watchdog's role for the capture window)
for ip in $B_IP $A_IP; do
  $W $ip 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null
   pkill -9 -f "[l]ock_watchdog" 2>/dev/null; echo "'$ip' wd stopped"' 2>/dev/null
done
sleep 2

# 4. saturating traffic: qpsk_perf UDP, peer -> target tun (server sinks on the
#    target, client paces near the R3 ceiling). Runs long enough to cover the
#    wedge-check re-arms + settle + the Tap window + DUR.
# 2026-09-05 (RXFIX Task 32): was DUR+140. The stall loop below is wall-clock now and the
# health gate may retry; the client is pkill'ed at quiesce anyway, so a long -t is free.
PERF_T=$(( DUR + 400 ))
$W $RX_IP  "pkill -x qpsk_perf 2>/dev/null; cd /root/host_app_k5; setsid ./qpsk_perf -s -p 5001 </dev/null >/dev/shm/perf_srv.log 2>&1 &" 2>/dev/null
$W $PEER_IP "pkill -x qpsk_perf 2>/dev/null; cd /root/host_app_k5; setsid ./qpsk_perf -c $TUN_TGT -b $PERF_BPS -l $PAY -t $PERF_T -p 5001 </dev/null >/dev/shm/perf_cli.log 2>&1 &" 2>/dev/null
echo "  traffic: $PEER_IP -> $TUN_TGT (qpsk_perf -b ${PERF_MBIT}Mbit -l $PAY -t $PERF_T), settling 4s ..."
sleep 4

# 5. WEDGE CHECK: re-arm until CRC-healthy. A sync-but-CRC wedge clears on the
#    byte double-tap; genuine forward degradation (146 TX margin) does NOT ->
#    tries exhaust and we flag PERSISTENT (that IS the real PER, not a wedge).
WTRY=1; WMAX=${WMAX:-4}; WTHRESH=${WTHRESH:-50}; HLAST=-1
# RATE_MIN: minimum delivered frames/s to call the link live. ~25% of the R3 nominal
# 1245 f/s. A wedge delivers single digits, so this separates cleanly.
RATE_MIN=${RATE_MIN:-300}; RLAST=-1
while [ $WTRY -le $WMAX ]; do
  HLAST=$(crc_health $RX_IP)
  RLAST=$(deliver_rate $RX_IP)
  FH=100
  [ "${FWD_GATE:-0}" = 1 ] && FH=$(fwd_health $PEER_IP)
  echo "  health try $WTRY: rev ${HLAST}% fwd ${FH}% (need >= ${WTHRESH}%)  rate ${RLAST} f/s (need >= ${RATE_MIN})"
  if [ "${HLAST:--1}" -ge "$WTHRESH" ] 2>/dev/null && [ "${FH:--1}" -ge "$WTHRESH" ] 2>/dev/null \
     && [ "${RLAST:--1}" -ge "$RATE_MIN" ] 2>/dev/null; then
    echo "  link healthy: CRC $HLAST% AND delivering $RLAST f/s"; break
  fi
  [ "${RLAST:--1}" -lt "$RATE_MIN" ] 2>/dev/null && \
    echo "  !! DELIVERY FLATLINE (${RLAST} f/s) -- this is the wedge crc-health cannot see" 
  echo "  wedged/degraded -> byte double-tap re-arm (both boards)"
  rearm_byte $B_IP; rearm_byte $A_IP; sleep 3; rearm_byte $B_IP; rearm_byte $A_IP; sleep 4
  # 2026-09-24 (sp4b Gate 3, docs/evidence/sp4/SILICON.md): rearm_byte's 0x000 soft reset CLEARS
  # fixctl 0x208, i.e. the sro_sign the bring-up wrote as its LAST step. Without this re-apply
  # 146 silently falls back to sro_sign=0 (R4B) and the reverse leg runs at ~7.9 % (a pair of
  # frames lost every ~15) on any arm whose first health read needed a re-arm. Same hook as
  # bringup_r2r3.sh; non-fatal.
  for ip in $B_IP $A_IP; do sro_reapply $ip; done
  WTRY=$(( WTRY + 1 ))
done
if [ "${HLAST:--1}" -ge "$WTHRESH" ] 2>/dev/null && [ "${RLAST:--1}" -ge "$RATE_MIN" ] 2>/dev/null; then
  WEDGE_NOTE="healthy crc=${HLAST}% rate=${RLAST}f/s"
elif [ "${RLAST:--1}" -lt "$RATE_MIN" ] 2>/dev/null; then
  WEDGE_NOTE="WEDGED delivery=${RLAST}f/s (crc=${HLAST}%) after $WMAX re-arms -- NOT usable data"
else
  WEDGE_NOTE="PERSISTENT_DEGRADED ${HLAST}% after $WMAX re-arms (NOT a clearable wedge -- real PER)"
fi
echo "  wedge verdict: $WEDGE_NOTE"
# Refuse to spend a capture window on a wedged link. GATE_HARD=0 opts out (diagnostic
# runs that deliberately want the wedged data).
if [ "${GATE_HARD:-1}" = 1 ] && [ "${RLAST:--1}" -lt "$RATE_MIN" ] 2>/dev/null; then
  echo "CAPTURE_ABORTED_WEDGED: delivery ${RLAST} f/s < ${RATE_MIN} after $WMAX re-arms"
  echo "  (not banking empty data; re-run or clear the wedge first)"
  for ip in $B_IP $A_IP; do $W $ip 'pkill -x qpsk_perf 2>/dev/null' 2>/dev/null; done
  exit 3
fi

# 5b. optional carrier-loop tuning: poke receiver loop_gain regs (0x170-0x184)
#     AFTER the wedge re-arms (which soft-reset), so the tuned values are live for
#     the steady-state capture window. LOOP_POKE="0x184=0 0x170=49" (space-sep kv).
if [ -n "${LOOP_POKE:-}" ]; then
  echo "  LOOP_POKE on $RX_IP: $LOOP_POKE"
  $W $RX_IP "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access
    for kv in $LOOP_POKE; do echo \"\${kv%=*} \${kv#*=}\">\$DRA; done
    echo 'loop regs now:'; for r in 0x170 0x174 0x184; do echo \"\$r\">\$DRA; printf ' %s=%s' \"\$r\" \"\$(cat \$DRA)\"; done; echo" 2>/dev/null
fi

# 5c. optional ADRV9002 phy attribute poke on the RX board (SEQ-BIST Task 8a).
#     Same position and rationale as LOOP_POKE: AFTER the wedge re-arms (which
#     soft-reset the fabric and, via bringup, re-assert gain_control_mode=automatic)
#     and BEFORE the framelog rotate that starts the scored window, so the attribute
#     is live for the whole steady-state window and for nothing else. rearm_byte()
#     touches only the fabric device-0 DRA and the TX debugfs DRA -- it does not write
#     any phy gain/tracking attribute -- and the watchdogs were killed at step 3, so
#     nothing re-arms and clears the poke mid-window.
#     RX_ATTR_POKE="in_voltage0_gain_control_mode=spi in_voltage0_hardwaregain=34" (space-sep
#     k=v, values must not contain spaces). The phy is discovered by iio name, never
#     hardcoded. Before-values are echoed so capture_r3.log carries the witness even if
#     the caller's own restore never runs. RESTORE IS THE CALLER'S JOB (radioprobe_go.sh
#     does it under a trap); this hook only applies and reports.
# 5b2. SELF_MUTE=1 (2026-10-07): mute the RECEIVING board's OWN transmitter for the leg -- the one-cell test
#      that solved the post-move forward waves (FORWARD_LINK_2026-10-01.md sec. 10: 1.9 % -> 0.013 % with 148's
#      TX at -40 dB). Duplex self-interference looks like a demodulator defect (frame-start garbage, periodic),
#      so run this cell BEFORE blaming the modem. Composes with RX_ATTR_POKE; the next arm resets TX gain to 0.
if [ "${SELF_MUTE:-0}" = 1 ]; then
  RX_ATTR_POKE="${RX_ATTR_POKE:+$RX_ATTR_POKE }out_voltage0_hardwaregain=-40"
  echo "  SELF_MUTE: $RX_IP own TX -> -40 dB for this leg (via RX_ATTR_POKE)"
fi
if [ -n "${RX_ATTR_POKE:-}" ]; then
  echo "  RX_ATTR_POKE on $RX_IP: $RX_ATTR_POKE"
  $W $RX_IP "P=\$(for d in /sys/bus/iio/devices/iio:device*; do case \"\$(cat \$d/name 2>/dev/null)\" in *adrv9002*phy*) echo \$d;; esac; done)
    [ -n \"\$P\" ] || { echo 'RX_ATTR_POKE FATAL: no adrv9002 phy'; exit 9; }
    echo \"  phy=\$P\"
    for i in 1 2 3 4 5; do
      echo \"  ATTR_PRE_GAIN t\$i gain='\$(cat \$P/in_voltage0_hardwaregain 2>&1)' mode='\$(cat \$P/in_voltage0_gain_control_mode 2>&1)' rssi='\$(cat \$P/in_voltage0_rssi 2>&1)'\"
      sleep 1
    done
    for kv in $RX_ATTR_POKE; do a=\${kv%%=*}; v=\${kv#*=}
      b=\$(cat \$P/\$a 2>&1)
      if [ \"\$v\" = '@keep' ]; then v=\$(echo \$b | awk '{print \$1}'); fi
      echo \"\$v\" > \$P/\$a 2>&1 && w=ok || w=WRITE_FAIL
      n=\$(cat \$P/\$a 2>&1)
      echo \"  ATTR_POKE \$a before='\$b' want='\$v' write=\$w after='\$n'\"
    done
    for i in 1 2 3; do
      echo \"  ATTR_POST_GAIN t\$i gain='\$(cat \$P/in_voltage0_hardwaregain 2>&1)' mode='\$(cat \$P/in_voltage0_gain_control_mode 2>&1)' rssi='\$(cat \$P/in_voltage0_rssi 2>&1)'\"
      sleep 1
    done" 2>&1 | tee -a "$OUT/attr_poke.txt"
fi

# 5c2. receiver in-band tilt corrector words (tilt_eq_overlay.m, AXI 0x260/0x264; spec
#      docs/superpowers/specs/2026-10-03-rx-tilt-equaliser-design.md). The bring-up this rail just ran
#      ends with 0x000 soft resets, which CLEAR those write-only words -- a value written before the
#      leg is gone by now (2026-10-04: four forced cells ran with the corrector off, cfc unchanged). So
#      the write belongs HERE, after the arm and before the traffic window, like RX_ATTR_POKE.
#        TILT_EQ_SET=<dB>   force the words for a <dB> slope (ops/tilt_eq.sh --set; on a flat channel
#                           this APPLIES a -<dB> tilt -- the silicon A/B of the block)
#        TILT_EQ_SET=auto   measure the live slope and write the inverse (ops/tilt_eq.sh)
#        TILT_EQ_SET=off    write zeros (bypass) -- the explicit OFF cell of an A/B
#      The TILT_EQ line (grep-able) is the witness; unset = the rail does not touch the words.
if [ -n "${TILT_EQ_SET:-}" ]; then
  case "$TILT_EQ_SET" in
    auto) bash "$D/tilt_eq.sh" "$RX_IP" 2>&1 | tail -n 1 | tee -a "$OUT/attr_poke.txt" ;;
    off)  bash "$D/tilt_eq.sh" "$RX_IP" --off 2>&1 | tail -n 1 | tee -a "$OUT/attr_poke.txt" ;;
    *)    bash "$D/tilt_eq.sh" "$RX_IP" --set "$TILT_EQ_SET" 2>&1 | tail -n 1 | tee -a "$OUT/attr_poke.txt" ;;
  esac
fi

# 5d. the same poke, on the PEER (transmitting) board -- SEQ-BIST Task 8a probe P-D.
#     26.042 ms is 1e6 cycles of a 38.4 MHz device clock and BOTH boards have one, so a
#     periodic TX-side radio process on the transmitter imprints on the air exactly as an
#     RX-side one does. Same position, same rules, same witness format as RX_ATTR_POKE;
#     the only difference is the board it lands on. Restore is the caller's job.
if [ -n "${PEER_ATTR_POKE:-}" ]; then
  echo "  PEER_ATTR_POKE on $PEER_IP: $PEER_ATTR_POKE"
  $W $PEER_IP "P=\$(for d in /sys/bus/iio/devices/iio:device*; do case \"\$(cat \$d/name 2>/dev/null)\" in *adrv9002*phy*) echo \$d;; esac; done)
    [ -n \"\$P\" ] || { echo 'PEER_ATTR_POKE FATAL: no adrv9002 phy'; exit 9; }
    echo \"  phy=\$P\"
    for kv in $PEER_ATTR_POKE; do a=\${kv%%=*}; v=\${kv#*=}
      b=\$(cat \$P/\$a 2>&1)
      if [ \"\$v\" = '@keep' ]; then v=\$(echo \$b | awk '{print \$1}'); fi
      echo \"\$v\" > \$P/\$a 2>&1 && w=ok || w=WRITE_FAIL
      n=\$(cat \$P/\$a 2>&1)
      echo \"  ATTR_POKE \$a before='\$b' want='\$v' write=\$w after='\$n'\"
    done" 2>&1 | tee -a "$OUT/attr_poke_peer.txt"
fi

# rotate the framelog (SIGUSR2) so the PULLED frames.bin is the steady-state
# post-heal window only (drops the wedge + re-arm transient).
#
# ROTATE_RX / ROTATE_PEER (RXFIX Task 35, ATARM_CLASS.md sec 7.2). The rotate is
# the at-arm collapse trigger and it was never logged: sec 1 had to place BOTH
# instants by joining txlog_peer.bin record 0 back into the RX framelog by frame
# seq -- a reconstruction that fails outright on a whitened or collapsed leg.
# `date` runs INSIDE THE SAME ssh session as the pkill, so this adds no round
# trip and the RX->peer interval (0.82-1.72 s, the interval the whole class
# depends on) is unchanged; the order RX first, peer second is unchanged too.
# board_t is the board's CLOCK_REALTIME -- the same clock frames.bin's t_real_ns
# and the daemon's own "framelog: ROTATE ... t_real=" line are on. host_t is
# nemo's, for cross-checking the two boards against each other.
ROT_RX=$($W $RX_IP 'pkill -USR2 -x qpsk_tun 2>/dev/null; date +%s.%N' 2>/dev/null | tail -1)
echo "  ROTATE_RX ip=$RX_IP board_t=${ROT_RX:-NA} host_t=$(date +%s.%N) iso=$(date -Is)"
ROT_PEER=$($W $PEER_IP 'pkill -USR2 -x qpsk_tun 2>/dev/null; date +%s.%N' 2>/dev/null | tail -1)
echo "  ROTATE_PEER ip=$PEER_IP board_t=${ROT_PEER:-NA} host_t=$(date +%s.%N) iso=$(date -Is)"
sleep 1
S1=$(snap $RX_IP); sleep 2; S2=$(snap $RX_IP)

# CAP_SETTLE (2026-08-09): seconds to wait AFTER the framelog rotate before the Tap-A
# IQ grab. Default 0 preserves the historical behaviour exactly.
#
# WHY THIS EXISTS. Measured across 8 captures: the Tap-A window lands at t=8.0-8.1 s in
# the framelog timebase, EVERY TIME, and 160/160 of the frames inside it are errored --
# while the same captures run ~6% bad overall. The acceptance PER window deliberately
# starts at t>=15 s to exclude the post-rotate transient, so the IQ we grab for
# root-cause replay is taken from the exact region the PER metric throws away. Every
# errored frame we have IQ for is a transient artifact, not a steady-state error, which
# is very likely why Workstream R never produced an attribution.
# Set CAP_SETTLE=20 to grab IQ from the same steady-state window the PER number
# describes. Also lets us test whether the t~8 s error burst is caused BY the readdev
# (it moves with the capture) or is independent of it (it stays at 8 s).
if [ "${CAP_SETTLE:-0}" -gt 0 ] 2>/dev/null; then
  echo "  CAP_SETTLE: waiting ${CAP_SETTLE}s after rotate so the IQ window is steady-state"
  sleep "$CAP_SETTLE"
fi
{ echo "$S1"; echo "$S2"; echo "$WEDGE_NOTE"; } > "$OUT/regs_pre.txt"

# 6. THE PAIRED WINDOW: Tap-A capture during live traffic (single ssh session)
$W $RX_IP "rm -f /dev/shm/pair.iq
  DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; rd(){ echo \"\$1\">\$DRA;cat \$DRA; }
  echo \"CAP_START t=\$(date +%s.%N) pkts=\$(rd 0x104) biterr=\$(rd 0x108) rstcs=\$(rd 0x150) cfc=\$(rd 0x154)\"
  iio_readdev -u local: -b 32768 -s $NSAMP axi-adrv9002-rx-lpc voltage0_i voltage0_q > /dev/shm/pair.iq 2>/tmp/iio.err || cat /tmp/iio.err
  echo \"CAP_END   t=\$(date +%s.%N) pkts=\$(rd 0x104) biterr=\$(rd 0x108) rstcs=\$(rd 0x150) cfc=\$(rd 0x154)\"
  ls -la /dev/shm/pair.iq" 2>/dev/null | tee "$OUT/regs_cap.txt"

# 7. wait out the traffic window -- WITH a stall watchdog. Previously a blind sleep, so
#    a link that wedged mid-capture still produced a full-length, wholly empty frames.bin
#    that downstream tooling happily analysed. Now delivery is sampled and the run aborts
#    the moment it flatlines.
STALL_MAX=${STALL_MAX:-12}          # seconds of flatline before declaring a wedge
# ---- RXFIX Task 44: bounded, recorded mid-window recovery. DEFAULT OFF. ------
# With MID_RECOVER=0 (the default) not one line of the recovery path runs and
# the flatline aborts the leg exactly as it did before. See the header.
MID_RECOVER=${MID_RECOVER:-0}
RECOVER_MAX=${RECOVER_MAX:-1}
RECOVER_WAIT=${RECOVER_WAIT:-30}
RECOVER_SETTLE=${RECOVER_SETTLE:-15}
RECOVER_GUARD_PRE=${RECOVER_GUARD_PRE:-2}
RECOVER_CONFIRM=${RECOVER_CONFIRM:-2}
RECOVER_EXTEND=${RECOVER_EXTEND:-1}
RECOVER_N=0; RECOVER_EXCL_S=0; RECOVER_FAILED=0
RECFILE="$OUT/recovery.txt"

# dma_rx_ok AND the board's own epoch in ONE ssh round trip, on the board's own
# CLOCK_REALTIME -- the clock frames.bin's t_real_ns is on, which is what makes
# the recorded interval joinable to the framelog. `date +%s`, whole seconds: the
# boards DO print nanoseconds (both resolve date to coreutils -- checked on
# silicon, progress.md 2026-09-06 16:4x), but the bounds below are padded by a
# 2 s guard and a 15 s settle, so a 1 s truncation cannot move either bound out
# of the perturbed region, and integer seconds keep this arithmetic exact.
deliv_now(){ $W $RX_IP 'echo "T=$(date +%s) OK=$(grep "stats:" /dev/shm/qpsk_tun.log 2>/dev/null | tail -1 | grep -o "dma_rx_ok=[0-9]*" | cut -d= -f2)"' 2>/dev/null | tr -d '\r' | grep -E '^T=[0-9]+ OK=' | tail -1; }

# recover_once <seconds-of-flatline-observed> <attempt-index>
#   0 = delivery came back (a RECOVERY_EVENT line is appended to recovery.txt)
#   1 = it did not (a RECOVERY_EVENT ... outcome=failed line is appended too --
#       a leg that could not be recovered must still say WHEN it was perturbed)
recover_once(){
  local stalled=$1 idx=$2
  local s t_det t_rearm t_last t_ok excl_a excl_b p_prev tp_prev p_now tp_now dfr dt conf tstart waited
  s=$(deliv_now); t_det=$(printf '%s' "$s" | sed -n 's/^T=\([0-9]*\) .*/\1/p')
  [ -n "$t_det" ] || t_det=$(date +%s)   # ssh read failed: nemo's clock, ~aligned
  # EXCLUSION START.  STALL accumulates the REAL poll interval DT each stalled
  # poll (see the loop below), so the last poll that saw HEALTHY delivery was
  # exactly $stalled seconds before this instant.  RECOVER_GUARD_PRE backs off
  # a further 2 s for the degradation ramp -- the same guard accept_analyze.py's
  # live-window rule applies at a terminal wedge.
  excl_a=$(( t_det - stalled - RECOVER_GUARD_PRE ))
  echo "  MID_RECOVER: attempt $idx/$RECOVER_MAX after ${stalled}s flatline -- RX-ONLY double-tap re-arm on $RX_IP"
  t_rearm=$t_det
  rearm_byte "$RX_IP"; sleep 3; rearm_byte "$RX_IP"
  sro_reapply "$RX_IP"
  conf=0; tstart=$(date +%s); waited=0; t_ok=""; t_last=$t_det
  s=$(deliv_now)
  p_prev=$(printf '%s' "$s" | sed -n 's/.*OK=\([0-9]*\).*/\1/p'); tp_prev=$(date +%s)
  while [ "$waited" -lt "$RECOVER_WAIT" ]; do
    sleep 4
    s=$(deliv_now); tp_now=$(date +%s); waited=$(( tp_now - tstart ))
    p_now=$(printf '%s' "$s" | sed -n 's/.*OK=\([0-9]*\).*/\1/p')
    t_last=$(printf '%s' "$s" | sed -n 's/^T=\([0-9]*\) .*/\1/p'); [ -n "$t_last" ] || t_last=$tp_now
    if [ -z "$p_now" ]; then
      echo "    ?? recovery poll read failed (ssh) at ${waited}s -- not counted either way"
      continue
    fi
    dt=$(( tp_now - tp_prev )); [ "$dt" -lt 1 ] && dt=1
    dfr=$(( p_now - ${p_prev:-0} )); p_prev=$p_now; tp_prev=$tp_now
    if [ "$dfr" -ge $(( 50 * dt )) ] 2>/dev/null; then
      conf=$(( conf + 1 ))
      echo "    delivery back: +${dfr} frames in ${dt}s (confirm $conf/$RECOVER_CONFIRM) at ${waited}s"
      [ "$conf" -ge "$RECOVER_CONFIRM" ] && { t_ok=$t_last; break; }
    else
      [ "$conf" != 0 ] && echo "    ...delivery dropped again (+${dfr} in ${dt}s) -- confirm reset"
      conf=0
    fi
  done
  mkdir -p "$OUT"
  if [ ! -f "$RECFILE" ]; then
    { echo "# capture_r3.sh mid-window recovery record (RXFIX Task 44)."
      echo "# Times are the RX BOARD's CLOCK_REALTIME in whole seconds -- the same clock"
      echo "# frames.bin's t_real_ns is on. excl_start_s..excl_end_s is the PERTURBED"
      echo "# INTERVAL: scoring must drop it from BOTH numerator and denominator."
      echo "# Reader: ops/recovery_windows.py (accept_analyze.py, comb/comb_period_ms.py)."
      echo "RECOVERY_SCHEMA 1"; } > "$RECFILE"
  fi
  if [ -n "$t_ok" ]; then
    excl_b=$(( t_ok + RECOVER_SETTLE ))
    echo "RECOVERY_EVENT idx=$idx outcome=recovered rx=$RX_IP stall_s=$stalled detect_board_s=$t_det rearm_board_s=$t_rearm back_board_s=$t_ok wait_s=$waited settle_s=$RECOVER_SETTLE guard_pre_s=$RECOVER_GUARD_PRE excl_start_s=$excl_a excl_end_s=$excl_b" >> "$RECFILE"
    RECOVER_EXCL_S=$(( RECOVER_EXCL_S + excl_b - excl_a ))
    echo "  MID_RECOVER: RECOVERED in ${waited}s; perturbed interval [$excl_a, $excl_b] ($(( excl_b - excl_a ))s) recorded in $RECFILE"
    return 0
  fi
  excl_b=$(( t_last + RECOVER_SETTLE ))
  echo "RECOVERY_EVENT idx=$idx outcome=failed rx=$RX_IP stall_s=$stalled detect_board_s=$t_det rearm_board_s=$t_rearm back_board_s=NA wait_s=$waited settle_s=$RECOVER_SETTLE guard_pre_s=$RECOVER_GUARD_PRE excl_start_s=$excl_a excl_end_s=$excl_b" >> "$RECFILE"
  RECOVER_EXCL_S=$(( RECOVER_EXCL_S + excl_b - excl_a ))
  echo "  MID_RECOVER: delivery did NOT return within ${RECOVER_WAIT}s of the re-arm"
  return 1
}

LEFT=$((DUR - 20))
# BUGFIX: this used to gate the stall watchdog on LEFT>0, i.e. DUR>20. Every capture of
# 20 s or less -- exactly the short verification/recovery captures -- ran with NO
# mid-capture watchdog at all, so a link that wedged after the pre-capture gate still
# banked a full-length empty frames.bin. Observed: recover2 passed the rate gate at
# 1027 f/s and then scored "UNUSABLE (live window 0s of 15s, WEDGED)". A check that
# cannot fire is worse than no check, because it reads as coverage.
# Always sample; if there is no tail left, still watch the settle+capture window.
[ $LEFT -le 0 ] && LEFT=$(( DUR > 8 ? 8 : DUR ))
if [ $LEFT -gt 0 ]; then
  echo "  ${LEFT}s traffic remaining (stall watchdog: abort after ${STALL_MAX}s flatline) ..."
  MID_WEDGE=0; STALL=0; WAITED=0; POLLFAIL=0
  # Wall-clock loop (2026-09-05, RXFIX Task 32 / WEDGE_TIMER_AUDIT.md): WAITED used to
  # advance 4 s per poll while each poll took 4 s + one ssh RTT (~1.3 s), so a 600-s leg
  # needed ~780 s of wall clock, qpsk_perf's -t deadline expired first, and the resulting
  # flatline was flagged MID_CAPTURE_WEDGE in every long leg (WAITED 508-560 = wall
  # 729-739 s; 7/7 legs, no link event). WAITED is now wall seconds since the loop
  # started, the flat threshold scales with the real poll interval, and a failed ssh
  # read counts as unknown, never as a stall.
  T_LOOP0=$(date +%s)
  PREV=$($W $RX_IP 'grep "stats:" /dev/shm/qpsk_tun.log 2>/dev/null | tail -1 | grep -o "dma_rx_ok=[0-9]*" | cut -d= -f2' 2>/dev/null); PREV_T=$(date +%s)
  while [ $WAITED -lt $((LEFT + 4)) ]; do
    sleep 4
    NOW=$($W $RX_IP 'grep "stats:" /dev/shm/qpsk_tun.log 2>/dev/null | tail -1 | grep -o "dma_rx_ok=[0-9]*" | cut -d= -f2' 2>/dev/null); NOW_T=$(date +%s); WAITED=$((NOW_T - T_LOOP0))
    if [ -z "$NOW" ]; then
      POLLFAIL=$((POLLFAIL + 1))
      echo "    ?? delivery poll read failed (ssh) at ${WAITED}s -- not counted as a stall"
      continue
    fi
    DT=$((NOW_T - PREV_T)); [ "$DT" -lt 1 ] && DT=1
    # DFRAMES, not D: reusing D here clobbered the script-dir variable that
    # scpput builds its askpass path from (see git history).
    DFRAMES=$(( NOW - ${PREV:-0} )); PREV=$NOW; PREV_T=$NOW_T
    # a live link delivers ~1245 f/s; treat < 50 f/s over the real poll interval as flatlined
    if [ "$DFRAMES" -lt $((50 * DT)) ] 2>/dev/null; then
      STALL=$((STALL + DT))
      # 0x1C0 DURING THE FLATLINE (2026-09-25, docs/evidence/sp4/WEDGE_CLASS.md sec 4). The whole
      # open question is fabric-ring vs host-drain, and bracketing snapshots cannot answer it: a
      # pre/post delta mixes the healthy minutes with the 16 s stall. Sample the fabric byte-word
      # counter (0x1C0) and the detected-frame counter (0x104) AT each stalled poll instead --
      # bytewords still advancing while the host gets nothing means the fabric is forwarding and the
      # HOST stopped draining; bytewords frozen while 0x104 advances means the fabric RING stopped.
      # One read per 5 s poll, on a link that is already delivering nothing, and we hold the rig lock.
      SW=$($W $RX_IP 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
 echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
 rd(){ echo "$1">$DRA; cat $DRA; }; echo "bytewords=$(rd 0x1C0) pkts=$(rd 0x104) rstcs=$(rd 0x150) cfc=$(rd 0x154)"' 2>/dev/null | tail -1)
      echo "    !! delivery stalled ${STALL}s (+${DFRAMES} frames in ${DT}s) at ${WAITED}s  STALL_REGS $SW"
      if [ $STALL -ge $STALL_MAX ]; then
        # DEFAULT PATH (MID_RECOVER=0): identical to before -- flag and abort.
        if [ "$MID_RECOVER" != 1 ] || [ "$RECOVER_N" -ge "$RECOVER_MAX" ]; then
          [ "$MID_RECOVER" = 1 ] && echo "    MID_RECOVER: no attempts left ($RECOVER_N/$RECOVER_MAX) -- aborting"
          MID_WEDGE=1; break
        fi
        RECOVER_N=$(( RECOVER_N + 1 )); T_REC0=$(date +%s)
        if recover_once "$STALL" "$RECOVER_N"; then
          # Re-baseline AFTER the recovery, from a fresh read: the next poll's
          # delta must not span the collapse in either direction.
          if [ "$RECOVER_EXTEND" = 1 ]; then
            LEFT=$(( LEFT + STALL + $(date +%s) - T_REC0 ))
            echo "    MID_RECOVER: traffic window extended to ${LEFT}s of tail so the leg still yields its DUR of scored data"
          fi
          STALL=0
          PREV=$($W $RX_IP 'grep "stats:" /dev/shm/qpsk_tun.log 2>/dev/null | tail -1 | grep -o "dma_rx_ok=[0-9]*" | cut -d= -f2' 2>/dev/null); PREV_T=$(date +%s)
          continue
        fi
        MID_WEDGE=1; RECOVER_FAILED=1; break
      fi
    else
      STALL=0
    fi
  done
  echo "  stall watchdog done: wall ${WAITED}s of $((LEFT + 4)), poll_read_failures=${POLLFAIL}"
  if [ "$MID_WEDGE" = 1 ] && [ "$RECOVER_FAILED" = 1 ]; then
    # DISTINCT marker: the harness tried the bounded recovery and it did not work.
    # Still "NOT usable data", so legrun_go.sh's existing gate fails it unchanged.
    WEDGE_NOTE="MID_CAPTURE_RECOVERY_FAILED after ${WAITED}s wall (delivery flatlined ${STALL}s; $RECOVER_N of $RECOVER_MAX re-arms, ${RECOVER_WAIT}s wait each) -- NOT usable data"
    echo "CAPTURE_ABORTED_RECOVERY_FAILED: $WEDGE_NOTE"
  elif [ "$MID_WEDGE" = 1 ]; then
    WEDGE_NOTE="MID_CAPTURE_WEDGE after ${WAITED}s wall (delivery flatlined ${STALL}s) -- NOT usable data"
    echo "CAPTURE_ABORTED_WEDGED: $WEDGE_NOTE"
  else
    # Post-window deliver rate, a REAL measurement: legrun_go.sh used to copy the
    # pre-window "health try" line into deliver_rate_post (Task 32).
    P0=$($W $RX_IP 'grep "stats:" /dev/shm/qpsk_tun.log 2>/dev/null | tail -1 | grep -o "dma_rx_ok=[0-9]*" | cut -d= -f2' 2>/dev/null); sleep 6; P1=$($W $RX_IP 'grep "stats:" /dev/shm/qpsk_tun.log 2>/dev/null | tail -1 | grep -o "dma_rx_ok=[0-9]*" | cut -d= -f2' 2>/dev/null)
    if [ -n "$P0" ] && [ -n "$P1" ]; then
      echo "  post rate $(( (P1 - P0) / 6 )) f/s (6 s dma_rx_ok delta after the traffic window)"
    else
      echo "  post rate UNKNOWN (ssh read failed)"
    fi
  fi
fi
# A leg that was recovered is NEVER the same measurement as a clean one: say so
# in the verdict string every downstream reader already carries (legrun_go.sh
# copies wedge_verdict= into its own meta.txt). "RECOVERED_MIDWINDOW" contains
# no "WEDGE" substring, so the existing gates treat the leg as usable -- which
# it is, on its clean segments, and only because recovery.txt makes the
# perturbed interval excludable.
if [ "$RECOVER_N" -gt 0 ] && [ "$MID_WEDGE" != 1 ]; then
  WEDGE_NOTE="$WEDGE_NOTE RECOVERED_MIDWINDOW n=$RECOVER_N excl_s=$RECOVER_EXCL_S (PERTURBED leg: score on its clean segments only -- $RECFILE)"
  echo "  $WEDGE_NOTE"
fi
snap $RX_IP > "$OUT/regs_post.txt"; cat "$OUT/regs_post.txt"

# 8. pull artifacts (flush the loggers first: SIGUSR1)
# USR1_RX / USR1_PEER: same treatment as ROTATE_* above, and for the same reason.
# The step-8 ring dump is the SECOND transmit-feed stall of every leg (4-246 ms,
# ATARM_CLASS.md sec 4.2) and is the A/B's free per-arm dose point; timing it from
# the archive currently needs the same seq join. `date` is inside the existing
# session, before the unchanged `sleep 0.5`, so the RX->peer spacing is unchanged.
U1_RX=$($W $RX_IP 'pkill -USR1 -x qpsk_tun 2>/dev/null; date +%s.%N; sleep 0.5' 2>/dev/null | tail -1)
echo "  USR1_RX ip=$RX_IP board_t=${U1_RX:-NA} host_t=$(date +%s.%N)"
U1_PEER=$($W $PEER_IP 'pkill -USR1 -x qpsk_tun 2>/dev/null; date +%s.%N; sleep 0.5' 2>/dev/null | tail -1)
echo "  USR1_PEER ip=$PEER_IP board_t=${U1_PEER:-NA} host_t=$(date +%s.%N)"
scpput root@$RX_IP:/dev/shm/pair.iq   "$OUT/pair.iq"   || { echo "scp pair.iq FAIL"; exit 1; }

# CAPTURE-PATH HEALTH GATE (added 2026-08-24). The IQ DMA can sit in the #48
# stale-DDR-replay state and return a stale ~256-sample buffer on every read while
# every board-side check still passes (framesync 1243 f/s throughout). An entire
# investigation was spent debugging receivers fed by such captures. Two cheap checks
# -- occupied bandwidth and envelope periodicity -- catch it. Non-fatal here so the
# rest of the capture is still collected, but the verdict is LOUD.
if ! python3 "$D/check_capture_health.py" "$OUT/pair.iq" --ksym "$KSYM"; then
  echo "  *** CAPTURE HEALTH FAILED -- pair.iq is DEGENERATE. Do NOT draw IQ-based"
  echo "  *** conclusions from this run. frames.bin / host-side counters are unaffected."
fi
scpput root@$RX_IP:/dev/shm/frames.bin "$OUT/frames.bin" || echo "WARN: frames.bin fetch failed"
scpput root@$PEER_IP:/dev/shm/frames.bin "$OUT/frames_peer.bin" 2>/dev/null || true
scpput root@$RX_IP:/dev/shm/qpsk_tun.log "$OUT/qpsk_tun.log" 2>/dev/null || true
# The PEER's daemon log. The header of this script has promised "qpsk_tun.log(+peer)"
# since the file was written but only the RX's was ever fetched. The at-arm collapse
# is caused by the PEER's rotate (ATARM_CLASS.md sec 0), so the peer's log is where
# the "framelog: ROTATE ... work_us=" and "rotate mode =" lines have to be read.
scpput root@$PEER_IP:/dev/shm/qpsk_tun.log "$OUT/qpsk_tun_peer.log" 2>/dev/null || true
{ echo "target=$TGT dir=$DIRN rx=$RX_IP peer=$PEER_IP rung=$RUNG profile=$PROF"
  echo "ksym=$KSYM sps=$SPS fs=$FS spf=$SPF frame=$FRAME carve_mb=$CARVE_MB dur=$DUR nsamp=$NSAMP payload=$PAY traffic=qpsk_perf_${PERF_MBIT}Mbit"
  echo "wedge_verdict=$WEDGE_NOTE"
  echo "mid_recover=$MID_RECOVER recovery_events=$RECOVER_N recovery_excluded_s=$RECOVER_EXCL_S recovery_failed=$RECOVER_FAILED"
  echo "image_md5=$($W $RX_IP 'md5sum /boot/BOOT.BIN 2>/dev/null | cut -c1-32' 2>/dev/null)"
  echo "image_md5_peer=$($W $PEER_IP 'md5sum /boot/BOOT.BIN 2>/dev/null | cut -c1-32' 2>/dev/null)"
  # CONDITIONS (2026-09-25, plan 2026-09-25-rig-instability Task 6): every retraction of the week of
  # 2026-09-22 came from comparing two runs whose conditions differed in ways nothing recorded --
  # which leg was weak flipped across three runs and three conclusions had to be withdrawn. RF
  # levels are dBFS (larger = weaker), read from sysfs only. The steering witness is in
  # regs_{pre,cap,post} (sro_mode 0x25C, r4_wit 0x234, r4_extras 0x238, bytewords 0x1C0).
  echo "rf_rx=$($W $RX_IP 'P=/sys/bus/iio/devices/iio:device2; echo rssi=$(cat $P/in_voltage0_rssi 2>/dev/null) decpow=$(cat $P/in_voltage0_decimated_power 2>/dev/null) gain=$(cat $P/in_voltage0_hardwaregain 2>/dev/null)' 2>/dev/null | tail -1)"
  echo "rf_peer=$($W $PEER_IP 'P=/sys/bus/iio/devices/iio:device2; echo rssi=$(cat $P/in_voltage0_rssi 2>/dev/null) decpow=$(cat $P/in_voltage0_decimated_power 2>/dev/null) gain=$(cat $P/in_voltage0_hardwaregain 2>/dev/null)' 2>/dev/null | tail -1)"
  echo "sentinel_before=$(grep -E '^[0-9]{4}-' "$HOME/modem-status/sentinel.log" 2>/dev/null | tail -1)"
  echo "ts=$(date -Is)"; } > "$OUT/meta.txt"

# 9. stop traffic, then quiesce to the known state (unless -k)
for ip in $B_IP $A_IP; do $W $ip 'pkill -x qpsk_perf 2>/dev/null' 2>/dev/null; done
if [ "$KEEP" = 0 ]; then
  for ip in $B_IP $A_IP; do
    $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 0.4
     ip link del tun0 2>/dev/null
     busybox devmem 0x9D000000 32 0 2>/dev/null; busybox devmem 0x9D000114 32 0 2>/dev/null
     echo "'$ip' quiesced"' 2>/dev/null
  done
else
  # -k used to leave the link up but WITHOUT the watchdogs step 3 killed, so the
  # sentinel/health gate could not see a post-capture wedge (2026-09-11). Relaunch
  # them the way exp_forward.sh / rf_loopback.sh do, so "-k" means the normal
  # in-service state, not "up until the first latch".
  for ip in $B_IP $A_IP; do
    $W $ip 'rm -f /dev/shm/watchdog.log; setsid /root/lock_watchdog.sh </dev/null >/dev/null 2>&1 & echo "'$ip' wd relaunched"' 2>/dev/null
  done
  echo "  -k: $RUNG link left UP (both daemons running, watchdogs relaunched)"
fi

echo "--- frames.bin summary ---"
[ -f "$OUT/frames.bin" ] && echo "frames.bin: $(( $(stat -c%s "$OUT/frames.bin") / 48 )) records" || echo "(no frames.bin)"
echo "NEXT: python3 $D/frame_taxonomy.py $OUT/frames.bin --frame-period-s $FRAME_PERIOD_S"
echo "      python3 $D/align_frames.py $OUT/frames.bin $OUT/regs_cap.txt --spf $SPF --pair $OUT/pair.iq -o $OUT"
if [ "$RECOVER_N" -gt 0 ] && [ -f "$RECFILE" ]; then
  echo "PERTURBED LEG: $RECOVER_N mid-window recovery interval(s), ${RECOVER_EXCL_S}s excluded -> $RECFILE"
  echo "      python3 $D/recovery_windows.py $OUT/frames.bin      # what will be excluded"
  echo "      accept_analyze.py / comb/comb_period_ms.py exclude it automatically;"
  echo "      QPSK_RECOVERY_IGNORE=1 scores the same file WITHOUT the exclusion (the A/B)."
fi
case "${WEDGE_NOTE:-}" in
  MID_CAPTURE_RECOVERY_FAILED*)
    echo "CAPTURE_R3_RECOVERY_FAILED $OUT  -- $WEDGE_NOTE"
    echo "  the bounded recovery did not restore delivery; callers should discard it (exit 3)"
    exit 3 ;;
  MID_CAPTURE_WEDGE*|WEDGED*)
    echo "CAPTURE_R3_WEDGED $OUT  -- $WEDGE_NOTE"
    echo "  run flagged; callers should discard it (exit 3)"
    exit 3 ;;
esac
echo "CAPTURE_R3_DONE $OUT"
