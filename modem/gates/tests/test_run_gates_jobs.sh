#!/bin/bash
# test_run_gates_jobs.sh -- proves run_gates.sh --jobs N's scheduling rule on a
# fake 7-leg table with sleep commands, run against the REAL run_gates.sh (not
# a re-implementation), so the test cannot drift from what ships.
#
#   legA, legB, legF: independent, no real dependency on each other -- with
#     --jobs 3 all three must overlap (running at the same wall-clock instant).
#   legC: names legA in its command -- must not start until legA has stopped
#     running (checked by legC's start time being >= legA's own finish time).
#   legD: names legB, same shape as legC.
#   legA_x: names legA in its command, but its own NAME extends "legA".
#   legE: names the bare prefix "legA" -- must wait for legA_x (a longer name
#     that extends "legA"), not just legA itself (prefix-extension / UNDER-
#     blocking regression, see NOTE 3).
#   legF: names the decoy "legA10" -- must NOT wait for legA, since "legA10"
#     is an unrelated token that merely starts with "legA" (whole-token /
#     OVER-blocking regression, see NOTE 3).
#
# SRO_SIM_DIR is pointed at an existing-but-empty scratch dir so run_gates.sh's
# `[ -d "$SRO" ]` guard passes and its verify-bank step (which only fires when
# SRO equals the real canonical path) is skipped -- this test exercises the
# scheduler, not the bank pin.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
RG="$HERE/../run_gates.sh"
[ -f "$RG" ] || { echo "JOBS_TEST_FAIL no run_gates.sh at $RG"; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
WORK="$T/work"; mkdir -p "$WORK"
LEGS="$T/fake.legs"

# Each leg stamps a start marker (epoch seconds, nanosecond fraction) before
# sleeping and a finish marker after -- the test reads these back, it does not
# infer overlap from wall-clock guesses.
# NOTE 1: dependency is expressed by naming the depended-on leg literally in
# the .legs COMMAND FIELD itself -- the text run_gates.sh's scheduler actually
# reads into CMDS[]/CRITS[] to build "hay" -- NOT merely inside the script
# file a leg happens to run. An earlier version of this test put the marker
# inside the *.sh body only; the scheduler never sees a script's contents, so
# those "dependency honoured" assertions were passing by coincidence (slot
# contention from --jobs 2, not real name-based blocking). Each dependent leg
# below is therefore invoked as `bash NAME.sh <depended-on-leg-name>` -- an
# inert extra argument the script ignores, present purely so the leg's name
# appears literally in its own .legs command field.
# NOTE 2: each leg's real work is a small script file invoked as ONE simple
# command (`bash NAME.sh [arg]`). run_gates.sh runs every leg as `timeout 7200
# $cmd > log 2>&1`; a `$cmd` with its own embedded `;`-separated redirects (or
# even a `( ... )` group, which `timeout` cannot take directly) collides with
# that appended redirect. Every real leg in this repo is already a single
# simple command (a Verilator invocation, a python script) with no embedded
# redirects, so this is a property of writing a synthetic multi-statement test
# leg correctly, not a run_gates.sh bug to fix.
# NOTE 3: run_gates.sh's scheduler checks TWO directions and this table pins
# both, deliberately with a fake, unrelated pair of names ("legA" / "legA10")
# rather than real-world-shaped ones, so the two regressions are unambiguous:
#   UNDER-blocking (legA_x/legE): a pending leg's text names a bare PREFIX of
#     a longer, currently-running leg's name -- it must still wait.
#   OVER-blocking (legF): a pending leg's text names an unrelated, longer
#     token that merely happens to START WITH a currently-running leg's
#     (shorter) name -- it must NOT wait; a raw substring test would
#     incorrectly block it, since the shorter running name is a literal
#     substring of the longer decoy token.
cat > "$T/legA.sh" <<'SH'
date +%s.%N > legA_start; sleep 3; date +%s.%N > legA_end
SH
cat > "$T/legB.sh" <<'SH'
date +%s.%N > legB_start; sleep 3; date +%s.%N > legB_end
SH
cat > "$T/legC.sh" <<'SH'
date +%s.%N > legC_start; sleep 1; date +%s.%N > legC_end
SH
cat > "$T/legD.sh" <<'SH'
date +%s.%N > legD_start; sleep 1; date +%s.%N > legD_end
SH
# legA_x: a longer name that EXTENDS legA's name with a "_" suffix (mirrors the
# real bug: "r4dr1_n_p10_t7" running while "collect" names only the bare
# prefix "r4dr1_n_p10"). legE names the bare prefix "legA" in its command --
# it must wait for legA_x (not legA, which finishes long before legA_x starts)
# because legA_x's name is "legA" extended with "_x".
cat > "$T/legA_x.sh" <<'SH'
date +%s.%N > legA_x_start; sleep 2; date +%s.%N > legA_x_end
SH
cat > "$T/legE.sh" <<'SH'
date +%s.%N > legE_start; sleep 1; date +%s.%N > legE_end
SH
# legF: OVER-blocking regression. Names "legA10" -- an unrelated decoy token
# that merely starts with "legA" -- while legA is running. An earlier direct
# check (`case "$hay" in *"$kname"*)`, an unbounded substring test) would
# spuriously block legF, because the shorter running name "legA" IS a literal
# substring of the decoy text "legA10". The token rule fixes this: "legA10"
# tokenises to a single word that neither equals "legA" nor is extended BY
# "legA" with a "_" suffix, so legF must NOT be blocked, and must run
# concurrently with legA (--jobs 3 gives it a slot in the same wave as legA
# and legB, since it truly has no dependency).
cat > "$T/legF.sh" <<'SH'
date +%s.%N > legF_start; sleep 3; date +%s.%N > legF_end
SH
cat > "$LEGS" <<EOF
legA|bash $T/legA.sh|test -s legA_end
legB|bash $T/legB.sh|test -s legB_end
legC|bash $T/legC.sh legA|test -s legC_end
legD|bash $T/legD.sh legB|test -s legD_end
legA_x|bash $T/legA_x.sh legA|test -s legA_x_end
legE|bash $T/legE.sh legA|test -s legE_end
legF|bash $T/legF.sh legA10|test -s legF_end
EOF

# --jobs 3 (not 2): legA, legB, and legF are all independent of each other
# and must all start in the same wave -- proving both that independent legs
# still overlap under a higher --jobs, and (the point of legF) that a running
# "legA" does not block a pending leg that merely CONTAINS "legA" as a
# substring of an unrelated longer token.
#
# The scheduler's idle-poll interval is 30s (unchanged from the original
# serial code, where it is fine -- real legs run ~40 min). Against this test's
# few-second sleeps that granularity, not the work itself, dominates wall
# time: expect roughly one 30s poll to notice legA/legB/legF finished, another
# to notice legC/legD/legA_x finished, and a third to notice legE unblocked
# once legA_x (not legA) has stopped running. 220s gives comfortable margin
# for that third phase (referenced by test_run_gates.py's outer timeout,
# which must stay larger than this).
# GATES_EVIDENCE_DIR keeps this run's log out of the committed evidence tree:
# without it, run_gates.sh writes modem/rtl_sim/evidence/sp2/legs/fake.log into
# the working tree on every pytest run.
OUT=$(SRO_SIM_DIR="$T" SP2_WORK="$WORK" GATES_EVIDENCE_DIR="$T/evidence" timeout 220 bash "$RG" --legs "$LEGS" --jobs 3 2>&1)
RC=$?
WD="$WORK/fake"

fails=0
if [ $RC -ne 0 ]; then echo "  FAIL run_gates.sh --jobs 3 exited $RC:"; echo "$OUT"; fails=$((fails+1)); fi
if ! echo "$OUT" | grep -q "GATE_LEGS fake pass=7 fail=0"; then
  echo "  FAIL did not see 7 passing legs:"; echo "$OUT"; fails=$((fails+1))
fi

for f in legA_start legA_end legB_start legB_end legC_start legC_end legD_start legD_end \
         legA_x_start legA_x_end legE_start legE_end legF_start legF_end; do
  [ -s "$WD/$f" ] || { echo "  FAIL missing marker $WD/$f"; fails=$((fails+1)); }
done
[ $fails -eq 0 ] || { echo "JOBS_TEST_FAIL $fails failure(s) before timing checks"; exit 1; }

aStart=$(cat "$WD/legA_start"); aEnd=$(cat "$WD/legA_end")
bStart=$(cat "$WD/legB_start"); bEnd=$(cat "$WD/legB_end")
cStart=$(cat "$WD/legC_start")
dStart=$(cat "$WD/legD_start")
axStart=$(cat "$WD/legA_x_start"); axEnd=$(cat "$WD/legA_x_end")
eStart=$(cat "$WD/legE_start")
fStart=$(cat "$WD/legF_start"); fEnd=$(cat "$WD/legF_end")

# overlap: legA and legB's [start,end] intervals intersect -- both ran at once,
# proving --jobs 2 is not silently serial.
if awk -v as="$aStart" -v ae="$aEnd" -v bs="$bStart" -v be="$bEnd" \
    'BEGIN{exit !(as<be && bs<ae)}'; then
  echo "  ok   legA and legB overlap (independent legs ran concurrently)"
else
  echo "  FAIL legA [$aStart,$aEnd] and legB [$bStart,$bEnd] do not overlap"; fails=$((fails+1))
fi

# dependency: legC (names legA) must not start until legA stopped running.
if awk -v cs="$cStart" -v ae="$aEnd" 'BEGIN{exit !(cs>=ae)}'; then
  echo "  ok   legC waited for legA to finish (cStart=$cStart >= aEnd=$aEnd)"
else
  echo "  FAIL legC started ($cStart) before legA finished ($aEnd) -- dependency not honoured"; fails=$((fails+1))
fi

# dependency: legD (names legB) must not start until legB stopped running.
if awk -v ds="$dStart" -v be="$bEnd" 'BEGIN{exit !(ds>=be)}'; then
  echo "  ok   legD waited for legB to finish (dStart=$dStart >= bEnd=$bEnd)"
else
  echo "  FAIL legD started ($dStart) before legB finished ($bEnd) -- dependency not honoured"; fails=$((fails+1))
fi

# prefix-extension dependency: legE names the bare prefix "legA" in its
# command, so it must not start until legA_x (whose name EXTENDS "legA" with
# a "_x" suffix) has stopped running -- not merely until legA itself has
# stopped, which happens long before legA_x even starts. This pins the shape
# that bit the real reference_matrix.legs "collect" leg.
if awk -v es="$eStart" -v axe="$axEnd" 'BEGIN{exit !(es>=axe)}'; then
  echo "  ok   legE waited for legA_x to finish (eStart=$eStart >= axEnd=$axEnd)"
else
  echo "  FAIL legE started ($eStart) before legA_x finished ($axEnd) -- prefix-extension dependency not honoured"; fails=$((fails+1))
fi
if awk -v axs="$axStart" -v ae="$aEnd" 'BEGIN{exit !(axs>=ae)}'; then
  echo "  ok   legA_x waited for legA to finish (axStart=$axStart >= aEnd=$aEnd)"
else
  echo "  FAIL legA_x started ($axStart) before legA finished ($aEnd)"; fails=$((fails+1))
fi

# over-blocking regression: legF (names only the decoy "legA10") must overlap
# legA -- a running "legA" must not spuriously block it just because "legA"
# is a literal substring of the unrelated token "legA10".
if awk -v fs="$fStart" -v fe="$fEnd" -v as="$aStart" -v ae="$aEnd" \
    'BEGIN{exit !(fs<ae && as<fe)}'; then
  echo "  ok   legF and legA overlap (legA running did not spuriously block legF)"
else
  echo "  FAIL legF [$fStart,$fEnd] and legA [$aStart,$aEnd] do not overlap -- over-blocking regression"; fails=$((fails+1))
fi

if [ $fails -eq 0 ]; then echo "JOBS_TEST_OK all checks, 0 failures"; exit 0; fi
echo "JOBS_TEST_FAIL $fails failure(s)"; exit 1
