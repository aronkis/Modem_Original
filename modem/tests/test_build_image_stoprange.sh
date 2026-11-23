#!/bin/bash
# test_build_image_stoprange.sh -- build_image.sh's stage-range and stage-name
# rails.  All four cases exercise the REAL script's arg-parse path: every check
# below sits above WORK-dir creation and above the first stage, so nothing is
# built and no directory is written.
#
#   1. --stop-after strictly EARLIER than --from must exit 2 with
#      BUILD_IMAGE_BAD_RANGE (it would otherwise silently run nothing);
#   2. an equal-stage run and a later-stage run must NOT be caught by that check;
#   3. --role must exit 2 with BUILD_IMAGE_NO_ROLE -- sp3 is ONE image from the
#      model overlays, so a caller still passing --role A believes in two images
#      and must be told, not silently handed the single one;
#   4. `seqbist` must exit 2 with BUILD_IMAGE_STAGE_MERGED rather than the
#      generic bad-stage message: the plan lists it as a stage, and its work is
#      really inside `hdl` (seqbist_bd.tcl is sourced into the same Vivado
#      session as complete_byte_bd.tcl and ddrcap_bd.tcl).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
BI="$HERE/../build_image.sh"
[ -f "$BI" ] || { echo "STOPRANGE_FAIL no build_image.sh at $BI"; exit 1; }

fails=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fails=$((fails+1)); }

# 1. Strictly earlier --stop-after: rejected, exit 2, both stages named.
OUT=$(bash "$BI" --from gates --stop-after hdl 2>&1); RC=$?
if [ $RC -eq 2 ] && printf '%s' "$OUT" | grep -q "^BUILD_IMAGE_BAD_RANGE --stop-after 'hdl' is earlier than --from 'gates'"; then
  ok "--from gates --stop-after hdl is rejected (rc=2)"
else
  bad "--from gates --stop-after hdl was not rejected as expected (rc=$RC): $OUT"
fi

# 2. Equal-stage and later-stage runs must not trip the range check. They may
#    fail later (no kit at the default regen parent), but not with this message.
for pair in "vivado vivado" "hdl vivado"; do
  set -- $pair
  OUT=$(bash "$BI" --from "$1" --stop-after "$2" --work /nonexistent-stoprange-probe 2>&1) || true
  if printf '%s' "$OUT" | grep -q "is earlier than --from"; then
    bad "--from $1 --stop-after $2 was wrongly rejected by the range check"
  else
    ok "--from $1 --stop-after $2 is not rejected by the range check"
  fi
done

# 3. --role is gone and must say so.
OUT=$(bash "$BI" --role A 2>&1); RC=$?
if [ $RC -eq 2 ] && printf '%s' "$OUT" | grep -q '^BUILD_IMAGE_NO_ROLE'; then
  ok "--role A exits 2 with BUILD_IMAGE_NO_ROLE"
else
  bad "--role A did not produce BUILD_IMAGE_NO_ROLE (rc=$RC): $OUT"
fi
# ...and it must be caught wherever it appears, not only as the first argument.
OUT=$(bash "$BI" --tag sp3 --role B --dry 2>&1); RC=$?
if [ $RC -eq 2 ] && printf '%s' "$OUT" | grep -q '^BUILD_IMAGE_NO_ROLE'; then
  ok "--role after --tag still exits 2 with BUILD_IMAGE_NO_ROLE"
else
  bad "--role B after --tag was not rejected (rc=$RC): $OUT"
fi

# 4. `seqbist` is recognised-but-merged, in BOTH range options.
for opt in --from --stop-after; do
  OUT=$(bash "$BI" $opt seqbist 2>&1); RC=$?
  if [ $RC -eq 2 ] && printf '%s' "$OUT" | grep -q '^BUILD_IMAGE_STAGE_MERGED'; then
    ok "$opt seqbist exits 2 with BUILD_IMAGE_STAGE_MERGED"
  else
    bad "$opt seqbist did not produce BUILD_IMAGE_STAGE_MERGED (rc=$RC): $OUT"
  fi
done
# A genuinely unknown stage must still get the generic message, or the merged
# token would be hiding typos.
OUT=$(bash "$BI" --from fixes 2>&1); RC=$?
if [ $RC -eq 2 ] && printf '%s' "$OUT" | grep -q "is not one of: hdl gates vivado"; then
  ok "--from fixes (a retired sp2 stage) gets the generic bad-stage message"
else
  bad "--from fixes did not get the generic bad-stage message (rc=$RC): $OUT"
fi

# 5. The stage order itself, read out of the script.
STAGES=$(sed -n 's/^STAGES=(\(.*\))$/\1/p' "$BI")
if [ "$STAGES" = "hdl gates vivado" ]; then ok "stage order is 'hdl gates vivado'"
else bad "stage order is '$STAGES' (want 'hdl gates vivado')"; fi

if [ $fails -eq 0 ]; then echo "STOPRANGE_OK all checks, 0 failures"; exit 0; fi
echo "STOPRANGE_FAIL $fails failure(s)"; exit 1
