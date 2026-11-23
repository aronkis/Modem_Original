#!/bin/bash
# =============================================================================
# margin_cells.sh -- MARGIN CELLS: does restoring the reverse leg's DESIGNED dead-zone margin stop the collapse?
#
# Measured 2026-09-28: calibrating on the control leg (148 RX, +20 kHz plan, CFC median -3577 ->
# 5.59 Hz/unit), 146 SHOULD read -7154 for its +40 kHz plan. It reads +460 -- centred on the null,
# 26.0 % of samples inside +/-1000 of zero, against the control's 0.3 %. The discrepancy is
# +42.6 kHz of transmit-side offset on 148, which almost exactly cancels the deliberate margin.
# Independently cross-checked: at LO_B_RX=1900100000 this predicts CFC -10271 and the LO cells
# run measured -10804 and -10306.
#
# PREDICTION, STATED BEFORE THE RUN. Raising 146's RX LO by that 42.6 kHz restores the intended
# +40 kHz effective offset:
#   corrected cells -> CFC near -7150, dead-zone fraction near 0, detection HOLDS near 1245 f/s
#   default cells   -> CFC near 0,     dead-zone fraction ~26 %,  detection COLLAPSES within ~60 s
# If the corrected cells collapse anyway, the null is not the whole story and this is falsified.
#
# Interleaved, because this leg's condition tracks the clock (REVERSE_LO_CELLS_2026-09-28.md).
#
# Usage: OUT=<dir> [CELLS=4] [HOLD=240] [DEFAULT_LO=] [CORRECTED_LO=] under launch_rig_unit.sh.
#
# RESULT 2026-09-28: the prediction was HALF right and that is the point. CFC and the dead-zone
# fraction tracked the PLAN exactly as predicted (-5950 / -5040 corrected against +711 / +131
# default; 6.4 / 7.6 % against 25.1 / 20.9 %). DETECTION DID NOT RECOVER in either plan
# (16 / 21 / 15 / 81 f/s). Restoring the designed margin does not restore the link, so the null
# is not the binding constraint. Keep this tool: it is the cheapest way to re-test that, and the
# falsification is the finding.
# =============================================================================
set -u
D=/mnt/onetb/scratch/qpsk-jupiter-modem/ops
A=10.0.0.148; B=10.0.0.146
OUT=${OUT:?OUT=<dir>}; CELLS=${CELLS:-4}; HOLD=${HOLD:-240}
DEFAULT_LO=${DEFAULT_LO:-1900040000}; CORRECTED_LO=${CORRECTED_LO:-1900082500}
mkdir -p "$OUT"; L=$OUT/margin.log; T=$OUT/cells.tsv
say(){ echo "$(date -Is) $*" | tee -a "$L"; }
printf 'cell\tplan\tlo_b_rx\tgate_146\tdet_first60\tdet_after60\tcfc_med\tcfc_sd\tdeadzone_pct\n' > "$T"

i=0
while [ "$i" -lt "$CELLS" ]; do
  i=$(( i + 1 ))
  case $(( i % 2 )) in 1) plan=default; lo=$DEFAULT_LO ;; 0) plan=corrected; lo=$CORRECTED_LO ;; esac
  say "--- cell $i: plan=$plan LO_B_RX=$lo ---"
  cl=$OUT/cell${i}_${plan}.log
  env LO_B_RX=$lo GATE_TRIES=3 GATE_DIR=A "$D/bringup_r2r3.sh" r3 > "$cl" 2>&1
  g=$(grep '^gate try' "$cl" | tail -1 | sed -n 's/.*146 rx=\([0-9]*\) f\/s.*/\1/p'); g=${g:-0}
  say "  gate: 146 rx=$g f/s"
  ( . "$D/sim_repro/riglock.sh"; rig_lock "margincell-$$" >/dev/null 2>&1
    trap 'rig_unlock' EXIT
    "$D/anyssh.sh" $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
     echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
     end=\$(( \$(date +%s) + $HOLD ))
     while [ \$(date +%s) -lt \$end ]; do
       echo 0x104 > \$DRA; p=\$(cat \$DRA); echo 0x154 > \$DRA; c=\$(cat \$DRA)
       echo \"\$(date +%s),\$p,\$c\"; sleep 1
     done" 2>/dev/null > "$OUT/cell${i}_${plan}.csv" )
  read d1 d2 cm cs dz <<< "$(python3 - "$OUT/cell${i}_${plan}.csv" <<'PY'
import sys, statistics
rows=[]
for ln in open(sys.argv[1]):
    f=ln.strip().split(',')
    if len(f)<3: continue
    def v(x):
        n=int(x,16) if x.lower().startswith('0x') else int(x)
        return n-(1<<32) if n>=(1<<31) else n
    try: rows.append((int(f[0]),v(f[1]),v(f[2])))
    except: pass
if not rows: print("0 0 0 0 0"); raise SystemExit
t0=rows[0][0]
def rate(g):
    tot=span=0.0
    for a,b in zip(g,g[1:]):
        dt=b[0]-a[0]; d=b[1]-a[1]
        if dt<=0 or d<0 or d/dt>3000: continue
        tot+=d; span+=dt
    return tot/span if span else float('nan')
cs=[r[2] for r in rows if abs(r[2])<(1<<20)]
print(f"{rate([r for r in rows if r[0]-t0<60]):.0f} {rate([r for r in rows if r[0]-t0>=60]):.0f} "
      f"{statistics.median(cs):.0f} {statistics.pstdev(cs):.0f} "
      f"{100*sum(1 for x in cs if abs(x)<1000)/len(cs):.1f}")
PY
)"
  say "  det first60=$d1 f/s  after60=$d2 f/s   CFC med=$cm sd=$cs  deadzone=${dz}%"
  printf '%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$i" "$plan" "$lo" "$g" "$d1" "$d2" "$cm" "$cs" "$dz" >> "$T"
done

say "--- restoring the shipped LO plan and putting the pair back in service ---"
"$D/bringup_r2r3.sh" r3 >>"$L" 2>&1 && say "RESTORE_OK" || say "RESTORE_FAILED -- rig NOT in service"
say "MARGIN_CELLS_DONE results=$T"
column -t "$T" 2>/dev/null | tee -a "$L"
