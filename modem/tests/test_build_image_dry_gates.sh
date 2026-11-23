#!/bin/bash
# test_build_image_dry_gates.sh -- two rails on the `gates` stage of
# modem/build_image.sh, both found in review round 1 of sp3 Task 11.
#
# (A) --dry MUST be honoured by `gates`.  It was honoured by hdl and vivado and
#     silently IGNORED here, so `build_image.sh --dry` over the default range
#     would have started the real multi-hour Verilator leg sweep -- the exact
#     opposite of what the flag promises.  `gates` must print
#     BUILD_IMAGE_DRY_GATES, run nothing, write NO STAMP.gates, and -- unlike
#     hdl and vivado -- NOT exit, because it sits in the middle of the stage
#     order and a dry full run has to fall through to the vivado preview.
#
# (B) The gates stage must REFUSE to start while another sim-gate run is live.
#     make_sro_trees.sh --from-regen writes one fixed tree
#     (modem/rtl_sim/s1_rtl_model) and run_gates.sh builds one fixed set of
#     Verilator object dirs; SP2_WORK separates the leg work dirs and neither of
#     those.  Measured 2026-09-12: two concurrent runs of the same table each
#     scored the other's binaries.  The guard is a `systemctl --user list-units
#     'sp2-gate-*'` probe -> BUILD_IMAGE_GATES_BUSY, exit 2.  It is exercised
#     here with a FAKE systemctl on PATH, so the test needs no real units and
#     can prove BOTH the busy and the idle answer.
#
# Nothing real is run: every case either short-circuits on --dry or exits at the
# busy guard, both of which sit above make_sro_trees.sh.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
BI="$HERE/../build_image.sh"
[ -f "$BI" ] || { echo "DRYGATES_FAIL no build_image.sh at $BI"; exit 1; }

fails=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fails=$((fails+1)); }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

# --- (A) --dry on the gates stage -------------------------------------------
W="$T/w_dry"
OUT=$(bash "$BI" --dry --tag sp3 --work "$W" --from gates --stop-after gates 2>&1); RC=$?
if [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q '^BUILD_IMAGE_DRY_GATES'; then
  ok "--dry --from gates prints BUILD_IMAGE_DRY_GATES and exits 0"
else
  bad "--dry --from gates (rc=$RC): $OUT"
fi
# It must name all three things it would have run, so the preview is useful.
for needle in 'make_sro_trees.sh --from-regen' 'tree_marker.sh' 'run_gates.sh --legs'; do
  printf '%s' "$OUT" | grep -qF -- "$needle" \
    && ok "the preview names $needle" || bad "the preview does not name $needle"
done
# NO STAMP.gates: a dry run has no GATES_DONE to record, and the vivado stage's
# "building UNGATED" warning must still fire behind it.
if [ ! -f "$W/STAMP.gates" ]; then ok "--dry writes no STAMP.gates"
else bad "--dry wrote $W/STAMP.gates"; fi
# ...and no dry stamp either: unlike hdl/vivado there is no STAMP.gates.dry
# convention, because gates never short-circuits the run.
if [ ! -f "$W/STAMP.gates.dry" ]; then ok "--dry writes no STAMP.gates.dry"
else bad "--dry wrote $W/STAMP.gates.dry"; fi

# A dry run that STARTS at gates must fall through to the vivado preview rather
# than exiting at gates the way hdl does.
W2="$T/w_through"
OUT2=$(bash "$BI" --dry --tag sp3 --work "$W2" --from gates 2>&1); RC2=$?
if printf '%s' "$OUT2" | grep -q '^BUILD_IMAGE_DRY_GATES' \
   && printf '%s' "$OUT2" | grep -q '== stage vivado'; then
  ok "a dry run starting at gates falls through to the vivado stage"
else
  bad "dry gates did not fall through to vivado (rc=$RC2): $OUT2"
fi

# --- (B) the concurrency guard, with a fake systemctl ------------------------
mkfake() { # mkfake <lines-to-print-for-list-units>
  cat > "$T/bin/systemctl" <<FAKE
#!/bin/sh
# fake systemctl for test_build_image_dry_gates.sh
case "\$*" in
  *list-units*sp2-gate-*) printf '%s' "\$FAKE_UNITS" ;;
  *) : ;;
esac
exit 0
FAKE
  chmod +x "$T/bin/systemctl"
}
mkfake

# BUSY: one running leg unit -> refuse, exit 2, name the unit.
W3="$T/w_busy"; mkdir -p "$W3"
# The guard sits below `need hdl`, so give it a stamp to get past. MODEL_TREE_SHA
# is the documented env override for exactly this (a stamp chain without a 1 h regen).
export MODEL_TREE_SHA=0123456789abcdef0123456789abcdef
printf 'stage=hdl tag=sp3 model_tree_sha=0123456789abcdef git=deadbeef when=now result=x\n' > "$W3/STAMP.hdl"
OUT3=$(PATH="$T/bin:$PATH" FAKE_UNITS='sp2-gate-model_matrix-m0_n_p000-1789196302.service loaded active running x
' bash "$BI" --tag sp3 --work "$W3" --from gates --stop-after gates 2>&1); RC3=$?
if [ $RC3 -eq 2 ] && printf '%s' "$OUT3" | grep -q '^BUILD_IMAGE_GATES_BUSY'; then
  ok "a running sp2-gate-* unit gives BUILD_IMAGE_GATES_BUSY, exit 2"
else
  bad "the busy guard did not fire (rc=$RC3): $OUT3"
fi
printf '%s' "$OUT3" | grep -q 'sp2-gate-model_matrix-m0_n_p000-1789196302.service' \
  && ok "the refusal names the unit that is holding the gates" \
  || bad "the refusal does not name the blocking unit"
printf '%s' "$OUT3" | grep -q 's1_rtl_model' \
  && ok "the refusal says WHY (the shared s1_rtl_model tree)" \
  || bad "the refusal does not explain the shared-path reason"

# IDLE: no units -> the guard must NOT fire.  The run then proceeds into
# make_sro_trees.sh, which fails on a kit that does not exist -- that is the
# proof the guard let it through, so any outcome EXCEPT _GATES_BUSY passes.
W4="$T/w_idle"; mkdir -p "$W4"
printf 'stage=hdl tag=sp3 model_tree_sha=0123456789abcdef git=deadbeef when=now result=x\n' > "$W4/STAMP.hdl"
OUT4=$(PATH="$T/bin:$PATH" FAKE_UNITS='' bash "$BI" --tag sp3 --work "$W4" \
         --regen-parent "$T/no-such-parent" --from gates --stop-after gates 2>&1); RC4=$?
if printf '%s' "$OUT4" | grep -q '^BUILD_IMAGE_GATES_BUSY'; then
  bad "the busy guard fired with NO units running (over-blocking): $OUT4"
else
  ok "no units running -> the guard does not fire (got as far as make_sro_trees)"
fi
# ...and it really did get past the guard, or the check above is vacuous.
printf '%s' "$OUT4" | grep -qE 'MAKE_SRO|BUILD_IMAGE_GATES_FAIL' \
  && ok "the idle case is non-vacuous (make_sro_trees was reached)" \
  || bad "the idle case never reached make_sro_trees: $OUT4"
unset MODEL_TREE_SHA

if [ $fails -eq 0 ]; then echo "DRYGATES_OK all checks, 0 failures"; exit 0; fi
echo "DRYGATES_FAIL $fails failure(s)"; exit 1
