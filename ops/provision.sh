#!/bin/bash
# =============================================================================
# provision.sh <board-ip> -- install the on-board files that link_test.sh
# preflight REQUIRES, onto ONE Jupiter that is ALREADY flashed with a byte-modem
# BOOT.BIN. This is the piece deploy_rxfix.sh does NOT do (it flashes /boot only):
#
#   /root/host_app_k5/qpsk_tun      built on-board from the host/ sources
#   /root/host_app_k5/qpsk_perf     UDP perf tool (built on-board)
#   /root/lvds_61p44_fdd_jupiter.{bin,json}  ADRV9002 profile, rung r3 (61.44 MSPS FDD LVDS,
#                                   15.36 Msym/s) -- what bringup_r2r3.sh r3 loads (the deployed rung)
#   /root/lvds_30p72_fdd_jupiter.{bin,json}  rung r2 (30.72 MSPS / 7.68 Msym/s), for bringup_r2r3.sh r2
#   /root/lvds_1p92_mhz.{bin,json}  legacy 1.92 MSPS profile (link_test.sh, old 240 ksym tooling)
#   /root/lock_watchdog.sh          on-board acquisition watchdog
#
# Host-app build flags: -DQPSK_CARVE_2MB -DQPSK_ARQ_NAKSTAT (the flags capture_r3.sh /
# the rig use) when the board exposes the qpsk UIO nodes (= the qpsk system.dtb from
# images/ is live); otherwise the 1 MB-carve build. Override: QPSK_CARVE_2MB=0|1.
#
# Board access via anyssh.sh; sources via scp+askpass (never cat). Compiling on
# the board is safe: it never arms the radio, touches a DMA, or writes /boot.
# Run once per board:  ./provision.sh 10.0.0.148   &&   ./provision.sh 10.0.0.146
# then verify:         ./link_test.sh preflight
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd)
# bounded board calls: SSH_T s per anyssh call (default 60; the on-board gcc build sets 300), SCP_T s per scp (default 300)
wssh(){ timeout "${SSH_T:-60}" "$D/anyssh.sh" "$@"; local rc=$?; [ $rc -eq 124 ] && echo "  [TIMEOUT] anyssh $1 exceeded ${SSH_T:-60}s" >&2; return $rc; }
W=wssh
SRC=$D/../host
IP=${1:-}
[ -n "$IP" ] || { echo "usage: provision.sh <board-ip>   (e.g. 10.0.0.148)   [QPSK_CARVE_2MB=1 | QPSK_CARVE_4MB=1 to force the build; default = the board's live dtb carve]"; exit 2; }
# QPSK_CARVE_2MB=1 provisions the 2 MB-carve host build for 1536 B frames (-G /
# f1536). SAFE by construction: the binary's startup guard (qpsk_tun.c) refuses
# to run until the 2 MB qpsk dtb is deployed, so a 2 MB build on a 1 MB-carve
# board cannot scribble kernel RAM -- it just exits. Deploy the qpsk dtb first
# (docs/setup-prebuilt.rst Step 0). Default (unset) keeps the 1 MB-carve build.
CARVE_DEF=""
scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
  timeout "${SCP_T:-300}" setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password \
  -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }

echo "=== PROVISION $IP  $(date -Is) ==="
$W "$IP" 'echo up' 2>/dev/null | grep -q up || { echo "FATAL: $IP unreachable via anyssh.sh"; exit 1; }

# sanity: the master files must exist on the host
PROFILES="lvds_61p44_fdd_jupiter lvds_30p72_fdd_jupiter lvds_1p92_mhz"
for f in "$SRC/qpsk_tun.c" "$SRC/qpsk_frame.c" "$SRC/qpsk_ber.c" \
         "$SRC/qpsk_seq.c" "$SRC/qpsk_uio.c" "$SRC/qpsk_perf.c" "$D/lock_watchdog.sh" \
         $(for pr in $PROFILES; do echo "$D/profiles/$pr.bin $D/profiles/$pr.json"; done); do
  [ -f "$f" ] || { echo "FATAL: master file missing on host: $f"; exit 1; }
done

# 0) carve size: the 2 MB (f1536) / 4 MB (f3072, sp4) builds need the matching qpsk dtb
#    (images/system-qpsk.<board>.dtb.*, CURRENT.txt DTB rows) live on the board -- read the
#    reserved carve size straight from the live device tree (and the three qpsk UIO nodes).
#    QPSK_CARVE_2MB=1 / QPSK_CARVE_4MB=1 force a build; a forced build larger than the live
#    carve is refused (the daemon would DMA past the reservation).
UIO=$($W "$IP" 'cat /sys/class/uio/*/name 2>/dev/null | grep -c "^qpsk_"' 2>/dev/null | tail -1)
CMB=$($W "$IP" 'R=/sys/firmware/devicetree/base/reserved-memory/qpsk_byte_buf@7ff00000/reg; [ -f $R ] && echo $(( 0x$(od -An -tx1 -j12 -N4 $R | tr -d " \n") / 1048576 )) || echo 0' 2>/dev/null | tail -1)
CMB=${CMB:-0}
if [ "${QPSK_CARVE_4MB:-}" = 1 ]; then WANT=4; elif [ "${QPSK_CARVE_2MB:-}" = 1 ]; then WANT=2
elif [ "${UIO:-0}" -ge 3 ] && [ "$CMB" -ge 4 ]; then WANT=4
elif [ "${UIO:-0}" -ge 3 ] && [ "$CMB" -ge 2 ]; then WANT=2
else WANT=1; fi
[ "$WANT" -le "$CMB" ] || [ "$WANT" -eq 1 ] || { echo "FATAL: a ${WANT} MB-carve build was requested but the live dtb reserves ${CMB} MB -- deploy the dtb first (ops/deploy_dtb.sh $IP)"; exit 3; }
case "$WANT" in
  4) CARVE_DEF="-DQPSK_CARVE_4MB -DQPSK_ARQ_NAKSTAT"; echo "-- qpsk UIO nodes: ${UIO:-0}/3, live carve ${CMB} MB -> 4 MB-carve build ($CARVE_DEF; f3072 / rung r4) --" ;;
  2) CARVE_DEF="-DQPSK_CARVE_2MB -DQPSK_ARQ_NAKSTAT"; echo "-- qpsk UIO nodes: ${UIO:-0}/3, live carve ${CMB} MB -> 2 MB-carve build ($CARVE_DEF; f1536 / rung r3) --" ;;
  *) CARVE_DEF=""; echo "-- qpsk UIO nodes: ${UIO:-0}/3, live carve ${CMB} MB -> 1 MB-carve build (deploy the qpsk dtb + UIO kernel first: docs/setup-prebuilt.rst Step 0) --" ;;
esac

# 1) host app: scp the sources qpsk_tun needs, build on-board with plain gcc
#    (the board-proven recipe from ber_loopback_gate.sh -- no dependence on make).
#    qpsk_uio.c is the UIO/IRQ event-loop module (Task B2); qpsk_seq.c is needed
#    by the gcc line below (previously referenced but not scp'd).
echo "-- host/ sources -> board; build qpsk_tun (on-board gcc) --"
$W "$IP" 'mkdir -p /root/host_app_k5' 2>/dev/null
#    qpsk_join.h and the GENERATED qpsk_fixregs.h (written by modem/fixes/gen_regmap.py
#    from modem/fixes/fixes.toml, #include'd by qpsk_hw.h since acd1e746) are both in
#    qpsk_tun.c's local #include closure and were both missing here; without them the
#    on-board gcc line below fails with "No such file or directory" on a clean board.
scpput "$SRC/qpsk_tun.c" "$SRC/qpsk_frame.c" "$SRC/qpsk_ber.c" "$SRC/qpsk_seq.c" \
       "$SRC/qpsk_uio.c" "$SRC/qpsk_frame.h" "$SRC/qpsk_ber.h" "$SRC/qpsk_seq.h" \
       "$SRC/qpsk_uio.h" "$SRC/qpsk_hw.h" "$SRC/qpsk_join.h" "$SRC/qpsk_fixregs.h" \
       "$SRC/qpsk_perf.c" root@"$IP":/root/host_app_k5/
[ -n "$CARVE_DEF" ] && echo "   (${WANT} MB carve build: $CARVE_DEF -- needs the ${WANT} MB qpsk dtb deployed, verified above)"
SSH_T=300 $W "$IP" "cd /root/host_app_k5 && gcc -O2 -Wall $CARVE_DEF -o qpsk_tun qpsk_tun.c qpsk_frame.c qpsk_ber.c qpsk_seq.c qpsk_uio.c 2>&1 | tail -3
  [ -x qpsk_tun ] && echo \"  qpsk_tun built OK\" || echo \"  qpsk_tun BUILD FAILED\"
  gcc -O2 -o qpsk_perf qpsk_perf.c 2>&1 | tail -2; [ -x qpsk_perf ] && echo \"  qpsk_perf built OK\" || echo \"  qpsk_perf BUILD FAILED\"" 2>/dev/null

# 2) ADRV9002 profiles: r3 (deployed rung), r2, and the legacy 1.92 MSPS one. bringup_r2r3.sh
#    cats /root/$PROF.bin then .json into the driver; a MISSING file there fails silently and
#    leaves the previous profile running, so every rung it can name must be present.
echo "-- profiles ($PROFILES) -> /root --"
scpput $(for pr in $PROFILES; do echo "$D/profiles/$pr.bin $D/profiles/$pr.json"; done) root@"$IP":/root/

# 3) on-board acquisition watchdog
echo "-- lock_watchdog.sh -> /root --"
scpput "$D/lock_watchdog.sh" root@"$IP":/root/
$W "$IP" 'chmod +x /root/lock_watchdog.sh' 2>/dev/null

# verify EXACTLY what link_test.sh preflight checks
echo "-- verify (mirrors link_test.sh preflight) --"
$W "$IP" '
  [ -x /root/host_app_k5/qpsk_tun ]  && echo "  [ ok ] qpsk_tun"  || echo "  [FAIL] qpsk_tun"
  [ -x /root/host_app_k5/qpsk_perf ] && echo "  [ ok ] qpsk_perf" || echo "  [FAIL] qpsk_perf"
  for pr in lvds_61p44_fdd_jupiter lvds_30p72_fdd_jupiter lvds_1p92_mhz; do
    [ -f /root/$pr.bin ] && [ -f /root/$pr.json ] && echo "  [ ok ] $pr.{bin,json}" || echo "  [FAIL] $pr.{bin,json}"
  done
  [ -f /root/lock_watchdog.sh ]      && echo "  [ ok ] watchdog"  || echo "  [FAIL] watchdog"
  uname -r | grep -q 6.12.77 && echo "  [ ok ] kernel 6.12.77 (UIO)" || echo "  [WARN] kernel $(uname -r) is not the banked UIO kernel (images/Image.6.12.77-uio.*)"
' 2>/dev/null
echo "=== PROVISION $IP done -- next: ./bringup_r2r3.sh r3 (both boards), then health_probe_reset_aware.sh <ip> 12 ==="
