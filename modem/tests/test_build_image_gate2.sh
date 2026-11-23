#!/bin/bash
# test_build_image_gate2.sh -- GATE 2 (spec Gate 2 / controller ruling 8): the
# post-route modem-clock WNS floor in modem/build_image.sh.
#
# This test replaces test_build_image_wnsdrift.sh, whose subject is gone.  sp2
# had a per-role `reference_modem_wns_ns` in fixes.toml and a ONE-SIDED drift
# gate around it (a build with MORE slack than the reference is not a defect --
# the two-sided version discarded the first sp2 role-A build at wns=0.548 vs
# ref=0.105).  sp3 has no roles and no manifest: there is one image and one
# ABSOLUTE floor, wns >= 0.005 ns, enforced by modem/gates/modem_wns.py --min.
# The three sp2/sp2-era numbers survive only as REFERENCE POINTS printed beside
# the measurement (rxfixpad 0.105, sp2A 0.447, sp2B 0.785), never as a gate.
#
# Below the floor is a STOP, not a tuning prompt: the plan drops the runtime
# select and sp2 stays shipped.  So this test asserts (a) the floor value that
# ships, (b) that it is handed to modem_wns.py rather than re-implemented, (c)
# that the failure path names GATE2 and does not suggest a retry, and (d) that
# the one-sided drift machinery really is gone -- a leftover `reference_modem_
# wns_ns` comparison would silently re-introduce a second, softer gate.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
BI="$HERE/../build_image.sh"
MW="$HERE/../gates/modem_wns.py"
[ -f "$BI" ] || { echo "GATE2_FAIL no build_image.sh at $BI"; exit 1; }
[ -f "$MW" ] || { echo "GATE2_FAIL no modem_wns.py at $MW"; exit 1; }

fails=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fails=$((fails+1)); }

# (a) the floor and the three reference points, read out of the script.
for kv in "WNS_FLOOR=0.005" "REF_PAD=0.105" "REF_SP2A=0.447" "REF_SP2B=0.785"; do
  k=${kv%%=*}; want=${kv#*=}
  got=$(sed -n "s/^$k=\([0-9.]*\).*/\1/p" "$BI")
  if [ "$got" = "$want" ]; then ok "$k is $want"; else bad "$k is '$got' (want $want)"; fi
done

# (b) the floor must be enforced by modem_wns.py --min, not re-implemented in
#     shell: a shell float comparison here would be a second source of truth.
if grep -q 'modem_wns.py" "\$WORK/impl1_reports_\$TAG" --clock "\$CLK" --min "\$WNS_FLOOR"' "$BI"; then
  ok "the floor is passed to modem_wns.py --min"
else
  bad "modem_wns.py is not invoked with --min \"\$WNS_FLOOR\""
fi

# (c) the pass and fail lines.
grep -q 'BUILD_IMAGE_WNS_OK wns=\$WNS floor=\$WNS_FLOOR ref_pad=\$REF_PAD ref_sp2A=\$REF_SP2A ref_sp2B=\$REF_SP2B' "$BI" \
  && ok "the pass line carries wns, floor and all three reference points" \
  || bad "the BUILD_IMAGE_WNS_OK line does not carry floor + the three references"
grep -q 'BUILD_IMAGE_GATE2_FAIL' "$BI" \
  && ok "the failure token is BUILD_IMAGE_GATE2_FAIL" \
  || bad "no BUILD_IMAGE_GATE2_FAIL token"
grep -q 'GATE2_TIMING.md' "$BI" \
  && ok "the failure message points at docs/evidence/sp3/GATE2_TIMING.md" \
  || bad "the failure message does not name GATE2_TIMING.md"

# (d) the sp2 drift gate must be GONE -- no reference_modem_wns_ns, no
#     BUILD_IMAGE_WNS_DRIFT, no `ref - 0.1` predicate.
for gone in reference_modem_wns_ns BUILD_IMAGE_WNS_DRIFT REFWNS; do
  if grep -q "$gone" "$BI"; then bad "the retired sp2 drift gate is still present: $gone"
  else ok "no $gone (the sp2 drift gate is gone)"; fi
done

# (e) modem_wns.py really does fail below --min and pass at/above it. The
#     predicate is exercised for real against a fixture timing summary so the
#     floor is not merely a string in the script.
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkfix() { # mkfix <wns>
  mkdir -p "$T/rpt"
  cat > "$T/rpt/impl_1_timing_summary_routed.rpt" <<RPT
Intra Clock Table
-----------------

Clock             WNS(ns)      TNS(ns)  TNS Failing Endpoints  TNS Total Endpoints      WHS(ns)
-----             -------      -------  ---------------------  -------------------      -------
axi_adrv9001_adc_1_clk   $1        0.000                      0               123456        0.021
RPT
}
probe() { # probe <wns> -> rc
  mkfix "$1"
  python3 "$MW" "$T/rpt" --clock axi_adrv9001_adc_1_clk --min 0.005 >/dev/null 2>&1
  echo $?
}
for c in "0.500 0" "0.005 0" "0.004 1" "-0.010 1"; do
  set -- $c
  got=$(probe "$1")
  if [ "$got" = "$2" ]; then ok "modem_wns.py --min 0.005 at wns=$1 -> rc=$2"
  else bad "modem_wns.py --min 0.005 at wns=$1 gave rc=$got (want $2)"; fi
done

if [ $fails -eq 0 ]; then echo "GATE2_OK all checks, 0 failures"; exit 0; fi
echo "GATE2_FAIL $fails failure(s)"; exit 1
