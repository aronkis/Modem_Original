#!/bin/bash
# [sim] Task 9: build the RXFIX_W1 instrument gate harness.
#   $1 = w1   -> patched tree s1_rtl_rxfix_W1, +define+RXFIX_W1, obj_byte_w1
#   $1 = base -> unpatched s1_rtl,             no define,         obj_byte_w1_base
# NEVER touches obj_byte_sro (Task 7's live legs run out of it).
#
# sp3 task 2 (model-backport): TREE=<dir> overrides the tree the "w1"/"base" defaults
# would pick (default behaviour unchanged); when TREE ends in s1_rtl_model the harness
# switches to the fixctl-forcing model wrapper (wrap_byte_w1_model.v, FIXCTL=<hex> via
# -GFIXCTL_INIT), a separate obj dir, and provenance via tree_marker.sh. SKIP_MARKER=1
# bypasses the tree_marker.sh check entirely (prints TREE_MARKER_SKIPPED) -- for proving
# the model tree verilates before any W1 overlay exists on it; not for routine use.
set -e -o pipefail
export PATH=/usr/local/bin:/usr/bin:/bin
KIT=/mnt/onetb/scratch/qpsk-jupiter-modem/modem
WHICH="${1:-w1}"
FIXCTL=${FIXCTL:-0}
case "$WHICH" in
  w1)   DEF="+define+RXFIX_W1" ;;
  base) DEF="" ;;
  *) echo "BUILD_W1_BAD_ARG '$WHICH' (want w1|base)"; exit 1 ;;
esac
case "$WHICH" in
  w1)   DEFAULT_TREE=$KIT/rtl_sim/s1_rtl_rxfix_W1 ;;
  base) DEFAULT_TREE=$KIT/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback ;;
esac
TREE=${TREE:-$DEFAULT_TREE}; VD=$TREE
if [ "$(basename "$TREE")" = s1_rtl_model ]; then
  MODEL=1; WRAP=wrap_byte_w1_model.v; TOP=wrap_byte_w1_model
  OBJ=obj_byte_w1_${WHICH}_model_$FIXCTL; GPARAM="-GFIXCTL_INIT=32'h$FIXCTL"
  # sp3 task 4: sim_w1.cpp includes Vwrap_byte_w1.h / uses the Vwrap_byte_w1 class;
  # on this path the top module (and so the generated class) is wrap_byte_w1_model.
  CFLAGS_EXTRA="-CFLAGS -DW1_MODEL"
else
  MODEL=0; WRAP=wrap_byte_w1.v; TOP=wrap_byte_w1
  OBJ=$([ "$WHICH" = w1 ] && echo obj_byte_w1 || echo obj_byte_w1_base); GPARAM=""
  CFLAGS_EXTRA=""
fi
cd "$KIT/rtl_sim"
if [ "${SKIP_MARKER:-0}" = 1 ]; then
  echo "TREE_MARKER_SKIPPED $VD W1"
elif [ "$WHICH" = w1 ]; then
  "$KIT/rtl_sim/tree_marker.sh" "$VD" W1 || exit 1
fi
rm -rf "$OBJ"
verilator -O2 -Wno-fatal --cc "$WRAP" -y "$VD" -y "$KIT/rtl_sim" $DEF $GPARAM $CFLAGS_EXTRA \
  --exe sim_w1.cpp -Mdir "$OBJ" --top-module "$TOP" > "${OBJ}_verilate.log" 2>&1
make -s -j4 -C "$OBJ" -f "V$TOP.mk" "V$TOP" > "${OBJ}_make.log" 2>&1
echo "BUILD_W1_DONE $WHICH $KIT/rtl_sim/$OBJ/V$TOP"
