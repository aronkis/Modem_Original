#!/bin/bash
# run_bp_padsweep.sh -- map the byte FIFO's tolerated ready-pad depth under BACKPRESSURE.
#
# WHY THIS EXISTS. Gate 1's driver (sim_sro.cpp) sets byte_rx_ready=1 once and never lowers it, so
# the drop-in's pop logic (valid && ready_1, ready_1 = delayMatch_reg[N-1]) is only ever exercised
# with ready high -- and a constant through an N-deep shift register is the same constant for every
# N. No Gate 1 leg can therefore detect a wrong ready-pad depth; see
# docs/evidence/oneway/RXO_PAD_SIM_2026-09-27.md. sim_sro_bp.cpp is a COPY of that driver with a
# deterministic square wave on byte_rx_ready; the gate driver is not modified.
#
#   ops? no -- desk only:  modem/rtl_sim/run_bp_padsweep.sh [DEPTHS="2 3 4 5"] [OFF=p000] [BP_LOW=3]
#     STEER=4b|4dr1  BP_PERIOD=16  SRO=<bank>  OUT=<dir>
#
# Deterministic, not random: every depth sees bit-identical stimulus, so a difference in the
# delivered-byte md5 is the device's and nothing else.
set -u
KIT=/mnt/onetb/scratch/qpsk-jupiter-modem/modem; cd "$KIT/rtl_sim"
DEPTHS=${DEPTHS:-"2 3 4 5"}; OFF=${OFF:-p000}; STEER=${STEER:-4b}
BP_PERIOD=${BP_PERIOD:-16}; BP_LOW=${BP_LOW:-3}
SRO=${SRO:-/mnt/onetb/scratch/qpsk-build-trees/sro_sim_f3072}
OUT=${OUT:-/mnt/onetb/scratch/qpsk-build-trees/bp_padsweep}; mkdir -p "$OUT"
case "$STEER" in
  4b)   WRAP=wrap_byte_sro4b_model.v; DEF=+define+RXFIX_R4B; FC=0  ;;
  4dr1) WRAP=wrap_byte_sro4d_model.v; DEF=+define+RXFIX_R4D; FC=20 ;;
  *) echo "STEER must be 4b or 4dr1" >&2; exit 2 ;;
esac
echo "=== ready-pad sweep: steer=$STEER offset=$OFF backpressure=${BP_LOW}/${BP_PERIOD} depths='$DEPTHS' ==="
for N in $DEPTHS; do
  T=/mnt/onetb/scratch/qpsk-build-trees/padsim_pad$N/s1_rtl_model
  if [ ! -d "$T" ]; then
    mkdir -p "$(dirname "$T")"; cp -a s1_rtl_model "$T"
    python3 - "$T/ByteRxFifo.v" "$N" <<'PYEOF'
import sys, pathlib
p=pathlib.Path(sys.argv[1]); n=int(sys.argv[2]); s=p.read_text(); top=n-1
for a,b in [("  reg [3:0] delayMatch_reg;    // ready pipeline",
             f"  reg [{top}:0] delayMatch_reg;    // ready pipeline -- PAD{n}"),
            ("  wire ready_1        = delayMatch_reg[3];",
             f"  wire ready_1        = delayMatch_reg[{top}];"),
            ("    if (reset) delayMatch_reg <= 4'b0;", f"    if (reset) delayMatch_reg <= {n}'b0;"),
            ("    else if (enb) delayMatch_reg <= {delayMatch_reg[2:0], ready};",
             f"    else if (enb) delayMatch_reg <= {{delayMatch_reg[{top-1}:0], ready}};")]:
    assert s.count(a)==1, a
    s=s.replace(a,b,1)
p.write_text(s)
PYEOF
  fi
  OBJ=obj_bp_${STEER}_pad$N
  if [ ! -x "$OBJ/Vwrap_byte_sro_model" ]; then
    verilator -O2 -Wno-fatal --cc "$WRAP" -y "$T" -y . $DEF "-GFIXCTL_INIT=32'h$FC" \
      -CFLAGS -DSRO_MODEL --exe sim_sro_bp.cpp -Mdir "$OBJ" --top-module wrap_byte_sro_model \
      > "${OBJ}_verilate.log" 2>&1 || { echo "VERILATE_FAIL depth=$N"; exit 1; }
    make -s -j"$(nproc)" -C "$OBJ" -f Vwrap_byte_sro_model.mk Vwrap_byte_sro_model \
      > "${OBJ}_make.log" 2>&1 || { echo "MAKE_FAIL depth=$N"; exit 1; }
  fi
  tag=bp_${STEER}_pad${N}_${OFF}
  ( cd "$OUT" && BP_PERIOD=$BP_PERIOD BP_LOW=$BP_LOW \
      "$KIT/rtl_sim/$OBJ/Vwrap_byte_sro_model" rx "$SRO/n_${OFF}.iq" 21086704 8400 "$tag" 2 0 \
      "+r4bwin=${tag}_skipwin.txt" > "$tag.log" 2>&1 )
  loss=$(cd "$OUT" && T7_NAIR=428 python3 "$KIT/rtl_sim/sro_score/score_t7.py" "$tag" 2>/dev/null \
         | grep -oE 'LOSS=[0-9.]+%' | tail -1)
  md5=$(md5sum "$OUT/${tag}_deliv.txt" 2>/dev/null | cut -c1-8)
  printf "  depth %-2s  %-12s deliv_md5=%s\n" "$N" "${loss:-LOSS=?}" "${md5:-none}"
done
echo "BP_PADSWEEP_DONE out=$OUT"
