#!/bin/bash
# [sim] Task 20: build the SRO harness against the RXFIX_R4D + RXFIX_R1 variant tree.
# Pre-registration RXFIX_S1_SIM_GATE.md (tag archive/pre-cleanup-2026-09-09;
# committed before this file existed).
#
# This is build_sro_rxfix4d.sh with a new VD and a new -Mdir.  EVERYTHING ELSE IS THE SAME
# BY DESIGN: task 7's sim_sro.cpp UNMODIFIED, the task 14 wrapper wrap_byte_sro4d.v
# UNMODIFIED, and the same +define+RXFIX_R4D.  That is what makes the p000 comparison a
# test of the RTL and not of a re-typed driver -- but it also means the wrapper's runtime
# banner (WRAP4D_FILE / WRAP4D_DEFINE) is IDENTICAL on an R4D leg and an R4DR1 leg, so the
# provenance has to be established here and at launch time instead.  See section 2 of the
# pre-registration; runall_t20.sh echoes the binary path + md5 into every leg log and
# asserts the md5 differs from the banked R4D binary's.
#
# sp3 task 2 (model-backport): TREE=<dir> selects the tree (default unchanged); when
# TREE ends in s1_rtl_model the harness reuses wrap_byte_sro4d_model.v (there is no
# separate R4DR1 model wrapper -- the R4D wrapper is unmodified across the R4D/R4DR1
# distinction on the injector side too), a separate obj dir, and FIXCTL=<hex> via
# -GFIXCTL_INIT. The TREE-provenance and RTL-content asserts below are injector-only
# (there is no R4D model tree to distinguish from, and the overlay content checks name
# injector-only signals); tree_marker.sh covers provenance on both paths.
set -e -o pipefail
export PATH=/usr/local/bin:/usr/bin:/bin
KIT=/mnt/onetb/scratch/qpsk-jupiter-modem/modem
TREE=${TREE:-$KIT/rtl_sim/s1_rtl_rxfix_R4DR1}; VD=$TREE; FIXCTL=${FIXCTL:-0}
if [ "$(basename "$TREE")" = s1_rtl_model ]; then
  MODEL=1; WRAP=wrap_byte_sro4d_model.v; TOP=wrap_byte_sro_model
  OBJ=obj_byte_sro_rxfix4dr1_model_$FIXCTL; GPARAM="-GFIXCTL_INIT=32'h$FIXCTL"
  # sp3 task 5: the model wrapper's module is wrap_byte_sro_model, so Verilator's
  # class is Vwrap_byte_sro_model; sim_sro.cpp selects it under -DSRO_MODEL.  The
  # DRIVER IS UNCHANGED.  (Untested on this script: the R4DR1 model tree needs
  # Task 6's R1 overlay before tree_marker.sh R4DR1 can pass -- but without this
  # line the build fails at `fatal error: Vwrap_byte_sro.h: No such file`, which
  # is exactly what cost this task a debug cycle on build_sro_rxfix4b.sh.)
  CFLAGS_EXTRA="-CFLAGS -DSRO_MODEL"
else
  MODEL=0; WRAP=wrap_byte_sro4d.v; TOP=wrap_byte_sro
  OBJ=obj_byte_sro_rxfix4dr1; GPARAM=""; CFLAGS_EXTRA=""
fi
cd "$KIT/rtl_sim"
rm -rf "$OBJ"
verilator -O2 -Wno-fatal --cc "$WRAP" -y "$VD" -y "$KIT/rtl_sim" +define+RXFIX_R4D $GPARAM $CFLAGS_EXTRA --exe sim_sro.cpp \
  -Mdir "$OBJ" --top-module "$TOP" > "${OBJ}_verilate.log" 2>&1
L="${OBJ}_verilate.log"
# --- wrapper provenance: the verilate log must name the task 14 wrapper (or its model
# --- copy) and none of the others that declare `module wrap_byte_sro`(_model).
if grep -qE '(^|[^34bd])wrap_byte_sro\.v' "$L"; then
  echo "BUILD_SRO_RXFIX4DR1_FAIL wrap_byte_sro.v (task 7 wrapper) was read"; exit 1; fi
for w in wrap_byte_sro3s wrap_byte_sro4 wrap_byte_sro4b; do
  if grep -qE "$w\.v" "$L"; then
    echo "BUILD_SRO_RXFIX4DR1_FAIL $w.v was read"; exit 1; fi
done
grep -qF "$WRAP" "$L" || \
  { echo "BUILD_SRO_RXFIX4DR1_FAIL $WRAP not in the verilate log"; exit 1; }
if [ "${SKIP_MARKER:-0}" = 1 ]; then
  echo "TREE_MARKER_SKIPPED $VD R4DR1"
else
  "$KIT/rtl_sim/tree_marker.sh" "$VD" R4DR1 || exit 1
fi
if [ "$MODEL" = 0 ]; then
  # --- TREE provenance.  'R4D' is a strict PREFIX of 'R4DR1', so the trailing slash is
  # --- load-bearing: without it the R4D-tree test would match every R4DR1 path.
  grep -q 's1_rtl_rxfix_R4DR1/' "$L" || \
    { echo "BUILD_SRO_RXFIX4DR1_FAIL the R4DR1 tree is not in the verilate log"; exit 1; }
  if grep -q 's1_rtl_rxfix_R4D/' "$L"; then
    echo "BUILD_SRO_RXFIX4DR1_FAIL the R4D tree was read"; exit 1; fi
  # --- VARIANT provenance: BOTH markers present, in their own files, and the four mutually
  # --- exclusive Rate_Handle variants absent.
  grep -q 'RXFIX_R4D' "$VD/Rate_Handle.v" || \
    { echo "BUILD_SRO_RXFIX4DR1_FAIL Rate_Handle.v does not carry RXFIX_R4D"; exit 1; }
  grep -q 'RXFIX_R1' "$VD/Preamble_Detector.v" || \
    { echo "BUILD_SRO_RXFIX4DR1_FAIL Preamble_Detector.v does not carry RXFIX_R1"; exit 1; }
  # the SHARP one: R1 must have REPLACED the tick-indexed pop, not merely been mentioned.
  # (the R1 patch's own comment quotes Delay10_reg[49331], so the assign form is the test)
  if grep -q 'assign Delay10_out1 = Delay10_reg\[49331\];' "$VD/Preamble_Detector.v"; then
    echo "BUILD_SRO_RXFIX4DR1_FAIL the tick-indexed PD pop is still there"; exit 1; fi
  grep -q "assign Delay10_out1 = Delay8_out1 & Delay10_full;" "$VD/Preamble_Detector.v" || \
    { echo "BUILD_SRO_RXFIX4DR1_FAIL the occupancy-indexed PD pop is missing"; exit 1; }
  for m in RXFIX_R3 RXFIX_R3S RXFIX_R4 RXFIX_R4B; do
    if grep -qE "$m([^0-9A-Za-z_]|\$)" "$VD/Rate_Handle.v"; then
      echo "BUILD_SRO_RXFIX4DR1_FAIL variant tree also carries $m"; exit 1; fi
  done
fi
make -s -j"$(nproc)" -C "$OBJ" -f "V$TOP.mk" "V$TOP" > "${OBJ}_make.log" 2>&1
B=$KIT/rtl_sim/$OBJ/V$TOP
if [ "$MODEL" = 0 ]; then
  B4D=$KIT/rtl_sim/obj_byte_sro_rxfix4d/Vwrap_byte_sro
  M=$(md5sum "$B" | cut -d' ' -f1)
  if [ -x "$B4D" ]; then
    M4D=$(md5sum "$B4D" | cut -d' ' -f1)
    [ "$M" != "$M4D" ] || { echo "BUILD_SRO_RXFIX4DR1_FAIL binary is byte-identical to the R4D binary"; exit 1; }
    echo "BUILD_SRO_RXFIX4DR1_MD5 r4dr1=$M r4d=$M4D (differ: OK)"
  fi
fi
echo "BUILD_SRO_RXFIX4DR1_DONE $B"
