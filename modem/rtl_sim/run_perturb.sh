#!/bin/bash
# run_perturb.sh -- build sim_sro_perturb against the model tree and run a scenario sweep. Desk only.
#   modem/rtl_sim/run_perturb.sh [SCEN="baseline drop_zero_25 ..."] [STEER=4b] [SRO=<bank>] [OUT=<dir>] [NF=300]
# Scenarios (frame = 0.80 ms at f3072):
#   baseline            clean stream, NF frames (the wrap at 428 frames is inside it -- must be silent)
#   cfo0                alias of baseline: the bank stimulus is the model's OWN transmitter output, so
#                       its residual carrier offset is EXACTLY zero by construction -- baseline IS the
#                       documented dead-zone operating point; cfoP40k is the shipped off-null plan
#   cfo[PM]<n>k         constant +/-n kHz offset (cfoM40k = the shipped +40 kHz RX-LO plan seen at
#                       baseband, cfc reads NEGATIVE like silicon; cfoP40k = the other sign)
#   step[PM]<n>k        a +/-n kHz offset STEP at frame 100 (on top of any cfo). The detector's
#                       threshold, CFOChangeDetectThreshold = 0.0125 NORMALISED TO THE SYMBOL RATE, is
#                       0.0125 * 30.72 Msym/s = ~384 kHz at this rung (192 kHz at r3) -- so a 3 or 8
#                       kHz step is far BELOW it (sweep 1: no reset), and a storm means the estimate
#                       is jumping by hundreds of kHz between consecutive estimates, i.e. garbage.
#   drop_zero_N         zeros for N frames from frame 100 (signal GONE for N*0.8 ms)
#   drop[PM]<n>_N       the same 20 ms-class gap on top of a constant +/-n kHz offset
#   drop_noise_N        noise at the signal's RMS for N frames (signal SWAMPED)
#   fade10_N            -10 dB for N frames (signal WEAK)
#   snr10 / snr5        AWGN at 10 / 5 dB below the stream RMS throughout
set -u
KIT=/mnt/onetb/scratch/qpsk-jupiter-modem/modem; cd "$KIT/rtl_sim"
STEER=${STEER:-4b}; SRO=${SRO:-/mnt/onetb/scratch/qpsk-build-trees/sro_sim_f3072}
OUT=${OUT:-/mnt/onetb/scratch/qpsk-build-trees/perturb}; mkdir -p "$OUT"
NF=${NF:-300}; FRSAMP=49268
SCEN=${SCEN:-"baseline cfo0 cfoP40k step3k step8k drop_zero_5 drop_zero_25 drop_zero_125 drop_noise_25 drop_noise_125 fade10_125 snr10"}
case "$STEER" in
  4b)   WRAP=wrap_byte_sro4b_model.v; DEF=+define+RXFIX_R4B; FC=0  ;;
  4dr1) WRAP=wrap_byte_sro4d_model.v; DEF=+define+RXFIX_R4D; FC=20 ;;
  *) echo "STEER must be 4b or 4dr1" >&2; exit 2 ;;
esac
OBJ=obj_perturb_${STEER}
if [ ! -x "$OBJ/Vwrap_byte_sro_model" ]; then
  echo "=== building $OBJ ==="
  verilator -O2 -Wno-fatal --cc "$WRAP" -y s1_rtl_model -y . $DEF "-GFIXCTL_INIT=32'h$FC" \
    -CFLAGS -DSRO_MODEL --exe sim_sro_perturb.cpp -Mdir "$OBJ" --top-module wrap_byte_sro_model >"$OUT/build_$OBJ.log" 2>&1 || { echo "VERILATOR FAILED (see $OUT/build_$OBJ.log)"; tail -20 "$OUT/build_$OBJ.log"; exit 1; }
  make -s -j"$(nproc)" -C "$OBJ" -f Vwrap_byte_sro_model.mk Vwrap_byte_sro_model >>"$OUT/build_$OBJ.log" 2>&1 || { echo "MAKE FAILED"; tail -20 "$OUT/build_$OBJ.log"; exit 1; }
  echo "BUILD_OK $OBJ"
fi
run(){ # name env...
  local name=$1; shift
  local nf=$NF; case "$name" in drop_*_125|drop_noise_125|fade10_125) nf=$(( NF + 125 ));; drop_zero_600) nf=$(( NF + 600 ));; esac
  local ns=$(( nf * FRSAMP ))
  echo "--- $name (${nf} frames, $*) ---"
  env "$@" "$OBJ/Vwrap_byte_sro_model" rx "$SRO/n_p000.iq" $ns 8400 "$OUT/${STEER}_$name" 2 0 | tail -1
}
for s in $SCEN; do
  case "$s" in
    baseline)      run $s PERT_LOOP=1 ;;
    cfo0)          run $s PERT_LOOP=1 ;;
    cfoP*k)        n=${s#cfoP}; run $s PERT_LOOP=1 PERT_CFO_HZ=$(( ${n%k} * 1000 )) ;;
    cfoM*k)        n=${s#cfoM}; run $s PERT_LOOP=1 PERT_CFO_HZ=$(( -${n%k} * 1000 )) ;;
    stepP*k)       n=${s#stepP}; run $s PERT_LOOP=1 PERT_CFO_HZ=${BASE_CFO:--40000} PERT_STEP_HZ=$(( ${n%k} * 1000 )) PERT_STEP_FRAME=100 ;;
    stepM*k)       n=${s#stepM}; run $s PERT_LOOP=1 PERT_CFO_HZ=${BASE_CFO:--40000} PERT_STEP_HZ=$(( -${n%k} * 1000 )) PERT_STEP_FRAME=100 ;;
    step3k)        run $s PERT_LOOP=1 PERT_STEP_HZ=3000 PERT_STEP_FRAME=100 ;;
    step8k)        run $s PERT_LOOP=1 PERT_STEP_HZ=8000 PERT_STEP_FRAME=100 ;;
    dropP*_*)      n=${s#dropP}; k=${n%%_*}; run $s PERT_LOOP=1 PERT_CFO_HZ=$(( k * 1000 )) PERT_DROP_FRAME=100 PERT_DROP_N=${s##*_} PERT_DROP_MODE=zero ;;
    dropM*_*)      n=${s#dropM}; k=${n%%_*}; run $s PERT_LOOP=1 PERT_CFO_HZ=$(( -k * 1000 )) PERT_DROP_FRAME=100 PERT_DROP_N=${s##*_} PERT_DROP_MODE=zero ;;
    drop_zero_*)   run $s PERT_LOOP=1 PERT_DROP_FRAME=100 PERT_DROP_N=${s##*_} PERT_DROP_MODE=zero ;;
    drop_noise_*)  run $s PERT_LOOP=1 PERT_DROP_FRAME=100 PERT_DROP_N=${s##*_} PERT_DROP_MODE=noise ;;
    fade10_*)      run $s PERT_LOOP=1 PERT_FADE_DB=10 PERT_FADE_FRAME=100 PERT_FADE_N=${s##*_} ;;
    snr10)         run $s PERT_LOOP=1 PERT_SNR_DB=10 ;;
    snr5)          run $s PERT_LOOP=1 PERT_SNR_DB=5 ;;
    *) echo "unknown scenario $s" ;;
  esac
done
echo "=== scores ==="; python3 perturb_score.py "$OUT"/${STEER}_*_pert.txt
echo "PERTURB_SWEEP_DONE $OUT"
