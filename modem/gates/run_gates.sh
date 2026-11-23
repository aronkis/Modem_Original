#!/bin/bash
# run_gates.sh -- Stage 4: run every sim gate the manifest lists for a role and
# collect the logs under modem/rtl_sim/evidence/sp2/<role>/.
#
# Usage: run_gates.sh --role A|B [--only GATE] [--work DIR] [--force] [--list]
#                      [--jobs N] | --legs FILE [--role R] [--jobs N]
#   exit 1 if any gate fails.
#
# --jobs N (default 1, today's serial behaviour): within one legs table, up to N
# legs may have their own systemd-run unit active at once. SCHEDULING RULE: legs
# are considered in table order; a pending leg may START (take a free slot) when
# no CURRENTLY-RUNNING leg's NAME is referenced by this leg's own command or
# criterion text. TOKEN RULE: the leg's command+criterion text is split into
# WORDS on whitespace AND on `/`, `.`, `|`, `=` (path separators, extensions,
# the leg-table field separator, and `KEY=val` args are common in this text and
# must not be treated as part of a name) -- but NOT on `_`, because leg names
# themselves contain meaningful underscores (`r4dr1_n_p10`). "Referenced" is
# then checked two ways against each such WORD w: (1) w equals the running
# leg's name exactly (a whole-token match, not a raw substring test -- an
# earlier version used `case "$hay" in *"$kname"*)`, an unbounded substring
# check, which OVER-blocked: a running leg named `r4b_n_p1` would spuriously
# block a pending leg whose text only mentions the unrelated, longer name
# `r4b_n_p10`, because "r4b_n_p1" is a literal substring of "r4b_n_p10"); or
# (2) the running leg's name EXTENDS w with a trailing "_..." (so `collect`,
# whose command lists the bare prefix `r4dr1_n_p10`, is still held while
# `r4dr1_n_p10_t7` -- a longer name that extends that prefix -- is running,
# even though check (1)'s whole-token match alone would miss it). `foo_t7`,
# whose command names `foo` as its own word, waits for `foo` under check (1);
# `collect` waits for every _t7 leg under check (2); a `-` (criterion-only) leg
# is likewise held until every leg its criterion names has stopped running.
# Because pending legs are offered free slots in table order every scheduling
# pass, an earlier leg always gets first claim on a slot over a later one that
# depends on it -- so as long as a table lists a dependency's leg before the
# leg that names it (true of every .legs file in this repo), a dependent leg
# is never started while the leg it names is still merely queued, only while
# it is genuinely running. Reuse (a valid .ok) resolves instantly and without
# a slot, exactly as it did serially.
#
# WHAT A "GATE" IS HERE.  fixes.toml's per-fix `gates = [...]` name the
# build_sro_*.sh scripts, but those scripts only COMPILE a Verilator binary; the
# gate proper is a set of LEGS (a sim run plus a pass criterion) that lives in the
# evidence ledgers under docs/evidence/comb/.  Those ledgers record leg tables and
# criteria, NOT command lines, so each leg's command and criterion are transcribed
# here into modem/gates/<gate>.legs -- one line per leg,
#
#     name|command|criterion
#
# with a `#` comment above each naming the ledger section it came from.  The
# criteria are data, not code, so they are reviewable against the ledger.  Both
# fields are run through `bash -c` with the leg's work directory as cwd and with
# RTL / SCORE / SRO / BANK / WORK exported (see below).  A leg passes when its
# command exits 0 AND its criterion exits 0.  `-` as a command means a
# criterion-only row (a comparison between two earlier legs' outputs).
#
# NOT EVERY LEDGER LEG IS RUN.  The full R4B (G1-G17) and R4D (J1-J11) matrices are
# nine 21.1 M-sample legs each at ~1 h a leg.  The legs transcribed here are the
# structural ones -- byte-identity and content-identity against banked artifacts --
# which are re-runnable claims about the RTL text rather than fresh measurements.
# Each .legs file lists the ledger rows it does NOT cover, with the banked number,
# in its header.  See the Stage 4 report.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)
export HERE
# fixes.toml stays in modem/fixes/ (the fix layer); only the gate machinery moved
# to modem/gates/ in sp3 Task 11, so $HERE no longer contains it.
MAN="$ROOT/modem/fixes/fixes.toml"
export ROOT
export RTL="$ROOT/modem/rtl_sim"
export SCORE="$ROOT/modem/rtl_sim/sro_score"
# Stimuli and banked leg outputs.  Large, non-reproducible artefacts that live OUTSIDE
# the repo: the .iq stimuli (gen_sro_stim.py, 32-85 MB each) and the banked b_/r4b_/
# r4d_/bs1_/pad_ leg outputs every identity criterion below compares against.  The
# ledgers refer to this directory by its pre-cleanup name; override with SRO_SIM_DIR.
# /mnt/onetb/scratch/qpsk-build-trees/sro_sim is the CANONICAL home of that bank
# (rsync -a of the pre-cleanup sro_sim/, 1.5 GB, same filenames); the directory the
# ledgers name is slated for deletion.
# RUNG (2026-10-01): the harness geometry (rtl_sim/geometry.h + sro_score/geometry.py), the stimulus
# bank and its digest are per rate rung. --rung r4 (default; f3072, bank sro_sim_f3072) or --rung r3|r2
# (f1536, bank sro_sim) renders the geometry twins for the rung BEFORE anything is built or scored, and
# the r4 render -- the committed pair -- is put back on exit. An explicit SRO_SIM_DIR still wins.
# Before this knob an f1536 tree was scored with f3072 constants (every T7 row LOSS=100 %), and an f3072
# tree launched without SRO_SIM_DIR was scored against the f1536 bank.
RUNG=${GATES_RUNG:-r4}; prev_a=""
for a in "$@"; do [ "$prev_a" = --rung ] && RUNG=$a; prev_a=$a; done
case "$RUNG" in r4) RUNG_SRO=/mnt/onetb/scratch/qpsk-build-trees/sro_sim_f3072 ;; r3|r2) RUNG_SRO=/mnt/onetb/scratch/qpsk-build-trees/sro_sim ;; *) echo "GATES_BAD_RUNG $RUNG (r2|r3|r4)"; exit 2 ;; esac
export SRO="${SRO_SIM_DIR:-$RUNG_SRO}"
export BANK="${SRO_BANK_DIR:-$SRO}"

ROLE=""; ONLY=""; WORK="${SP2_WORK:-/mnt/onetb/scratch/sp2_gates/work}"; FORCE=0; LIST=0; LEGSFILE=""; JOBS=1
while [ $# -gt 0 ]; do case "$1" in
  --rung)  shift 2 ;;
  --role)  ROLE=$2; shift 2 ;;
  --only)  ONLY=$2; shift 2 ;;
  --work)  WORK=$2; shift 2 ;;
  --force) FORCE=1; shift ;;
  --list)  LIST=1; shift ;;
  --legs)  LEGSFILE=$2; shift 2 ;;
  --jobs)  JOBS=$2; shift 2 ;;
  *) echo "bad arg $1"; exit 2 ;;
esac; done
case "$JOBS" in ''|*[!0-9]*|0) echo "GATES_BAD_JOBS $JOBS (must be a positive integer)"; exit 2 ;; esac
# --legs FILE: run a single named table OUTSIDE the fixes.toml manifest (sp3 task 3).
# --role becomes optional; GATES is just FILE's basename (minus .legs) and the loop
# below finds the table at exactly the path given, not under $HERE/<key>.legs.
if [ -n "$LEGSFILE" ]; then
  [ -f "$LEGSFILE" ] || { echo "GATES_LEGS_NOT_FOUND $LEGSFILE"; exit 2; }
  GATES=$(basename "$LEGSFILE" .legs)
  ROLE="${ROLE:-legs}"
else
  [ -n "$ROLE" ] || { echo "usage: run_gates.sh --role A|B [--only GATE] [--work DIR] [--force] | --legs FILE [--role R]"; exit 2; }
fi
[ -d "$SRO" ] || { echo "GATES_MISSING_STIMULI SRO_SIM_DIR=$SRO"; exit 2; }
# render the rung's geometry twins; restore the committed (r4) render when this runner exits
python3 "$RTL/geometry_gen.py" --rung "$RUNG" | tail -1
if [ "$RUNG" != r4 ]; then trap 'python3 "$RTL/geometry_gen.py" --rung r4 >/dev/null; echo "GATES_GEOMETRY_RESTORED r4"' EXIT; fi
echo "GATES_RUNG $RUNG SRO=$SRO"
# verify-bank only checks the CANONICAL /mnt/onetb/scratch/qpsk-build-trees/ layout
# (base_tree.sh's LOCAL_BANK), so skip it when SRO_SIM_DIR/SRO_BANK_DIR points
# somewhere else -- a stray override is not a tamper signal here. Also skip it
# for --list: a listing is a manifest read, not a build, and verify-bank costs
# a full 910-file / 1.5 GB recompute that a `--list` caller does not expect.
if [ "$LIST" != 1 ] && [ "$SRO" = "/mnt/onetb/scratch/qpsk-build-trees/sro_sim" ]; then
  "$ROOT/modem/fixes/base_tree.sh" verify-bank || { echo "GATES_BANK_MISMATCH modem/gates/bank.sha256 did not verify -- see above"; exit 2; }
elif [ "$LIST" != 1 ] && [ "$SRO" = "/mnt/onetb/scratch/qpsk-build-trees/sro_sim_f3072" ]; then
  # the sp4 (f3072, 2 sps) bank: stimuli + the run-4 baseline + its reference table, pinned by
  # modem/gates/bank_f3072.sha256 (docs/evidence/sp4/GATE1.md section 1); 23 files, ~0.6 GB
  ( cd "$SRO" && sha256sum --quiet -c "$ROOT/modem/gates/bank_f3072.sha256" ) \
    || { echo "GATES_BANK_MISMATCH modem/gates/bank_f3072.sha256 did not verify against $SRO"; exit 2; }
fi

if [ -n "$LEGSFILE" ]; then
  # GATES is the single table named by --legs; the manifest read (which needs a
  # real fixes.toml role) is bypassed entirely, per ruling (d).
  :
else
GATES=$(python3 - "$MAN" "$ROLE" <<'EOF'
import sys, tomllib
m = tomllib.load(open(sys.argv[1], 'rb')); role = sys.argv[2]
seen = []
for v in m['roles'][role]['variants']:
    for g in m['fixes'].get(v, {}).get('gates', []):
        if g not in seen: seen.append(g)
for g in m['gates']['common']:
    if g not in seen: seen.append(g)
print(' '.join(seen))
EOF
) || { echo "GATES_MANIFEST_READ_FAIL"; exit 2; }
fi

if [ "$LIST" = 1 ]; then echo "$GATES" | tr ' ' '\n'; exit 0; fi

# --only naming a gate this role does not run is an operator error, not an empty pass
if [ -n "$ONLY" ]; then
  case " $GATES " in *" $ONLY "*) ;;
    *) echo "GATES_ONLY_NOT_IN_ROLE $ONLY (role $ROLE runs: $GATES)"; exit 2 ;;
  esac
fi

# GATES_EVIDENCE_DIR overrides the committed evidence root. The default is the
# repo tree, which is what a real gate run wants -- but the test harness runs
# the REAL run_gates.sh against a throwaway legs table, and without an override
# it drops modem/rtl_sim/evidence/sp2/legs/fake.log into the working tree on
# every pytest run (that file was found untracked in the tree and removed).
OUT="${GATES_EVIDENCE_DIR:-$ROOT/modem/rtl_sim/evidence/sp2}/$ROLE"; mkdir -p "$OUT"
TS=$(date +%s); pass=0; fail=0
export WORK

hms () { printf '%02d:%02d:%02d' $(($1/3600)) $((($1%3600)/60)) $(($1%60)); }

for g in $GATES; do
  [ -z "$ONLY" ] || [ "$g" = "$ONLY" ] || continue
  key=$(echo "$g" | sed 's#/#_#g; s#\.sh$##')
  if [ -n "$LEGSFILE" ]; then legs="$LEGSFILE"; else legs="$HERE/$key.legs"; fi
  log="$OUT/$key.log"
  wd="$WORK/$key"; mkdir -p "$wd"
  gstart=$(date +%s)
  { echo "== GATE $g  key=$key  role=$ROLE  ts=$TS"
    echo "== legs $legs"
    echo "== work $wd   SRO=$SRO"
  } > "$log"
  if [ ! -f "$legs" ]; then
    echo "GATE_FAIL $g (no legs table $legs)" | tee -a "$log"; fail=$((fail+1)); continue
  fi
  gp=0; gf=0

  # ---- read the table into parallel arrays (order preserved) ----
  NAMES=(); CMDS=(); CRITS=(); SIGS=()
  while IFS= read -r raw; do
    case "$raw" in ''|'#'*) continue ;; esac
    # split on the FIRST two pipes only, so a criterion may contain pipes
    name=${raw%%|*}; rest=${raw#*|}; cmd=${rest%%|*}; crit=${rest#*|}
    name=$(echo "$name" | xargs); cmd=$(echo "$cmd" | sed 's/^ *//; s/ *$//'); crit=$(echo "$crit" | sed 's/^ *//; s/ *$//')
    NAMES+=("$name"); CMDS+=("$cmd"); CRITS+=("$crit")
    # REUSE IS CONTENT-KEYED, not marker-only: the .ok records the sha256 of the leg's
    # own 'name|command|criterion' line, so editing a command or a criterion invalidates
    # exactly that leg and nothing else.  (It still does NOT hash the binary, the tree or
    # the stimulus -- see the Stage 4 report's concern about --force.)
    # 2026-09-15: the signature also folds in GATES_TREE_SHA (the model_tree_sha
    # build_image.sh exports for the kit under test), so a leg's .ok from one
    # regenerated tree can never satisfy a different tree.  Unset = old behaviour.
    SIGS+=("$(printf '%s|tree=%s' "$raw" "${GATES_TREE_SHA:-}" | sha256sum | cut -d' ' -f1)")
  done < "$legs"
  n=${#NAMES[@]}
  STATUS=(); UNIT=(); STARTT=()
  for ((i=0; i<n; i++)); do STATUS[i]="pending"; done
  running=0

  finish_leg () {
    local i=$1 rc=$2 name=${NAMES[$1]}
    local lend=$(date +%s); local el=$(hms $((lend-STARTT[i])))
    if [ "$rc" = 0 ]; then
      echo "LEG_PASS $name  $el" | tee -a "$log"; gp=$((gp+1))
      printf 'sig=%s\nat=%s\n' "${SIGS[i]}" "$(date -Is)" > "$wd/$name.ok"
    else
      echo "LEG_FAIL $name  $el  rc=$rc" | tee -a "$log"; gf=$((gf+1))
      echo "---- tail $wd/$name.log ----" >> "$log"; tail -25 "$wd/$name.log" >> "$log" 2>/dev/null
    fi
    STATUS[i]="done"
  }

  # resolve reuse up front: no slot, no dependency wait -- it does no work
  for ((i=0; i<n; i++)); do
    name=${NAMES[i]}
    if [ "$FORCE" = 0 ] && [ -f "$wd/$name.ok" ] && grep -qx "sig=${SIGS[i]}" "$wd/$name.ok"; then
      echo "LEG_REUSE $name (from $(sed -n 's/^at=//p' "$wd/$name.ok"))" | tee -a "$log"; gp=$((gp+1))
      STATUS[i]="done"
    fi
  done

  while :; do
    progressed=0
    # (1) offer free slots to pending legs, in table order
    for ((i=0; i<n; i++)); do
      [ "${STATUS[i]}" = "pending" ] || continue
      [ "$running" -lt "$JOBS" ] || break
      blocked=0
      hay="${CMDS[i]} ${CRITS[i]}"
      # WORDS: hay split on whitespace plus /, ., |, = (see header TOKEN
      # RULE) -- NOT on _, which is meaningful inside leg names.
      haywords=$(printf '%s' "$hay" | tr '/.|=' '    ')
      for ((k=0; k<n; k++)); do
        [ "${STATUS[k]}" = "running" ] || continue
        kname="${NAMES[k]}"
        for w in $haywords; do
          # (1) whole-token match: w IS the running leg's name, not merely a
          # string containing it or contained in it (a raw substring test
          # over-blocks -- see header TOKEN RULE).
          # (2) prefix-extension: the running leg's name EXTENDS w with a
          # trailing "_..." (e.g. w="r4dr1_n_p10", kname="r4dr1_n_p10_t7").
          case "$kname" in "$w"|"$w"_*) blocked=1 ;; esac
          [ "$blocked" = 1 ] && break
        done
        [ "$blocked" = 1 ] && break
      done
      [ "$blocked" = 0 ] || continue
      name=${NAMES[i]}; cmd=${CMDS[i]}; crit=${CRITS[i]}
      STARTT[i]=$(date +%s)
      if [ "$cmd" = "-" ]; then
        rc=0
        if [ -n "$crit" ]; then ( cd "$wd" && eval "$crit" ) >> "$wd/$name.log" 2>&1; rc=$?; fi
        finish_leg "$i" "$rc"
      else
        unit="sp2-gate-$key-$name-$TS"
        UNIT[i]="$unit"
        systemd-run --user --collect --unit "$unit" --working-directory="$wd" \
          --setenv=RTL="$RTL" --setenv=SCORE="$SCORE" --setenv=SRO="$SRO" \
          --setenv=BANK="$BANK" --setenv=WORK="$WORK" --setenv=PATH="$PATH" \
          --setenv=HERE="$HERE" \
          bash -c "timeout 7200 $cmd > '$wd/$name.log' 2>&1; echo \$? > '$wd/$name.rc'" \
          >> "$log" 2>&1
        STATUS[i]="running"; running=$((running+1))
      fi
      progressed=1
    done
    # (2) reap finished units
    for ((i=0; i<n; i++)); do
      [ "${STATUS[i]}" = "running" ] || continue
      systemctl --user is-active --quiet "${UNIT[i]}" && continue
      name=${NAMES[i]}; crit=${CRITS[i]}
      rc=$(cat "$wd/$name.rc" 2>/dev/null || echo 99)
      if [ "$rc" = 0 ] && [ -n "$crit" ]; then
        ( cd "$wd" && eval "$crit" ) >> "$wd/$name.log" 2>&1; rc=$?
      fi
      finish_leg "$i" "$rc"
      running=$((running-1)); progressed=1
    done
    left=0
    for ((i=0; i<n; i++)); do [ "${STATUS[i]}" = "done" ] || left=$((left+1)); done
    [ "$left" = 0 ] && break
    [ "$progressed" = 1 ] || sleep 30
  done
  unset -f finish_leg
  gend=$(date +%s)
  echo "GATE_LEGS $g pass=$gp fail=$gf wall=$(hms $((gend-gstart)))" | tee -a "$log"
  if [ "$gf" = 0 ] && [ "$gp" -gt 0 ]; then
    echo "GATE_PASS $g wall=$(hms $((gend-gstart)))" | tee -a "$log"; pass=$((pass+1))
  else
    echo "GATE_FAIL $g (see $log)" | tee -a "$log"; fail=$((fail+1))
  fi
  # keep the committed evidence small; the full per-leg logs stay in $wd
  if [ "$(wc -l < "$log")" -gt 300 ]; then tail -300 "$log" > "$log.t" && mv "$log.t" "$log"; fi
done
echo "GATES_DONE role=$ROLE pass=$pass fail=$fail"
[ "$fail" = 0 ]
