#!/bin/bash
# run_perturb_stages.sh -- driver v2 (per-stage levels + rstCS/reset knobs) built into its OWN object
# so a running run_perturb.sh sweep is untouched. Asks: after a 20 ms gap, which stage is stuck, and
# does a rstCS pulse (0x110) fail to clear it while a full reset (0x000) succeeds, as on silicon?
#   modem/rtl_sim/run_perturb_stages.sh [SCEN="..."] [STEER=4b] [SRO=<bank>] [OUT=<dir>] [NF=300]
set -u
KIT=/mnt/onetb/scratch/qpsk-jupiter-modem/modem; cd "$KIT/rtl_sim"
STEER=${STEER:-4b}; SRO=${SRO:-/mnt/onetb/scratch/qpsk-build-trees/sro_sim_f3072}
OUT=${OUT:-/mnt/onetb/scratch/qpsk-build-trees/perturb_stages}; mkdir -p "$OUT"
NF=${NF:-300}; FRSAMP=49268
SCEN=${SCEN:-"baseline gap25 gap25_rstcs140 gap25_reset140 cfoP40k cfoM40k gap25_M40k"}
case "$STEER" in
  4b)   WRAP=wrap_byte_sro4b_model.v; DEF=+define+RXFIX_R4B; FC=0  ;;
  4dr1) WRAP=wrap_byte_sro4d_model.v; DEF=+define+RXFIX_R4D; FC=20 ;;
esac
OBJ=obj_perturb2_${STEER}
if [ ! -x "$OBJ/Vwrap_byte_sro_model" ]; then
  echo "=== building $OBJ (driver v2) ==="
  verilator -O2 -Wno-fatal --cc "$WRAP" -y s1_rtl_model -y . $DEF "-GFIXCTL_INIT=32'h$FC" \
    -CFLAGS -DSRO_MODEL --exe sim_sro_perturb.cpp -Mdir "$OBJ" --top-module wrap_byte_sro_model >"$OUT/build_$OBJ.log" 2>&1 || { echo "VERILATOR FAILED"; tail -20 "$OUT/build_$OBJ.log"; exit 1; }
  make -s -j"$(nproc)" -C "$OBJ" -f Vwrap_byte_sro_model.mk Vwrap_byte_sro_model >>"$OUT/build_$OBJ.log" 2>&1 || { echo "MAKE FAILED"; tail -20 "$OUT/build_$OBJ.log"; exit 1; }
  echo "BUILD_OK $OBJ"
fi
run(){ local name=$1; shift; local ns=$(( NF * FRSAMP )); echo "--- $name ($*) ---"; env "$@" "$OBJ/Vwrap_byte_sro_model" rx "$SRO/n_p000.iq" $ns 8400 "$OUT/${STEER}_$name" 2 0 | tail -1; }
for s in $SCEN; do
  case "$s" in
    baseline)        run $s PERT_LOOP=1 ;;
    gap25)           run $s PERT_LOOP=1 PERT_DROP_FRAME=100 PERT_DROP_N=25 ;;
    gap25_rstcs140)  run $s PERT_LOOP=1 PERT_DROP_FRAME=100 PERT_DROP_N=25 PERT_RSTCS_AT_FRAME=140 ;;
    gap25_reset140)  run $s PERT_LOOP=1 PERT_DROP_FRAME=100 PERT_DROP_N=25 PERT_RESET_AT_FRAME=140 ;;
    gap25_M40k)      run $s PERT_LOOP=1 PERT_CFO_HZ=-40000 PERT_DROP_FRAME=100 PERT_DROP_N=25 ;;
    gap25_M*k)       n=${s#gap25_M}; run $s PERT_LOOP=1 PERT_CFO_HZ=$(( -${n%k} * 1000 )) PERT_DROP_FRAME=100 PERT_DROP_N=25 ;;
    gap25_P*k)       n=${s#gap25_P}; run $s PERT_LOOP=1 PERT_CFO_HZ=$(( ${n%k} * 1000 )) PERT_DROP_FRAME=100 PERT_DROP_N=25 ;;
    gap5)            run $s PERT_LOOP=1 PERT_DROP_FRAME=100 PERT_DROP_N=5 ;;
    gap1)            run $s PERT_LOOP=1 PERT_DROP_FRAME=100 PERT_DROP_N=1 ;;
    gap25_reset140_M40k) run $s PERT_LOOP=1 PERT_CFO_HZ=-40000 PERT_DROP_FRAME=100 PERT_DROP_N=25 PERT_RESET_AT_FRAME=140 ;;
    cfoP40k)         run $s PERT_LOOP=1 PERT_CFO_HZ=40000 ;;
    cfoM40k)         run $s PERT_LOOP=1 PERT_CFO_HZ=-40000 ;;
    *) echo "unknown scenario $s" ;;
  esac
done
echo "STAGES_SWEEP_DONE $OUT"
