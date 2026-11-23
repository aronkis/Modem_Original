#!/bin/bash
# [sim] RXFIX_PAD gate: build the SRO/census harness against s1_rtl_pad (= s1_rtl_bs + pad_patch.py).
# Same wrapper (wrap_byte_bs.v), same driver (sim_sro.cpp), same define (RXFIX_BS) as obj_byte_sro_bs,
# so a leg on this binary differs from bs1_* legs ONLY by the ByteSerializer padding.
#
# sp3 task 2 (model-backport): TREE=<dir> selects the tree (default s1_rtl_pad,
# unchanged); when TREE ends in s1_rtl_model the harness switches to the
# fixctl-forcing model wrapper (wrap_byte_bs_model.v, FIXCTL=<hex> via -GFIXCTL_INIT),
# a separate obj dir, and provenance via tree_marker.sh PAD (RXFIX_ORIGIN + the
# ByteSerializer.v padCount overlay, per ruling 3 -- there is no BsPad.v). The
# injector-only preamble guards below (s1_rtl_pad existence, RXFIX_PAD in
# ByteSerializer.v, the s1_rtl_bs*/ negative asserts) are skipped on the model path;
# tree_marker.sh is the provenance check there. SKIP_MARKER=1 bypasses the
# tree_marker.sh check entirely (prints TREE_MARKER_SKIPPED) -- for proving the model
# tree verilates before any PAD overlay exists on it; not for routine use.
set -u
KIT=/mnt/onetb/scratch/qpsk-jupiter-modem/modem; cd "$KIT/rtl_sim"
TREE=${TREE:-s1_rtl_pad}; FIXCTL=${FIXCTL:-0}
if [ "$(basename "$TREE")" = s1_rtl_model ]; then
  MODEL=1; WRAP=wrap_byte_bs_model.v; TOP=wrap_byte_sro_model
  O=obj_byte_sro_pad_model_$FIXCTL; GPARAM="-GFIXCTL_INIT=32'h$FIXCTL"
else
  MODEL=0; WRAP=wrap_byte_bs.v; TOP=wrap_byte_sro
  O=obj_byte_sro_pad; GPARAM=""
  test -d "$TREE" || { echo "BUILD_SRO_PAD_FAIL no $TREE"; exit 1; }
  grep -q RXFIX_PAD "$TREE/ByteSerializer.v" || { echo "BUILD_SRO_PAD_FAIL tree lacks RXFIX_PAD"; exit 1; }
fi
if [ "${SKIP_MARKER:-0}" = 1 ]; then
  echo "TREE_MARKER_SKIPPED $TREE PAD"
else
  "$KIT/rtl_sim/tree_marker.sh" "$TREE" PAD || exit 1
fi
rm -rf "$O"
# sp3 task 7: the model branch needs -DSRO_MODEL for the same reason build_sro_bs.sh
# does (task 5) -- the model wrapper's module is wrap_byte_sro_model, so Verilator's
# class is Vwrap_byte_sro_model and sim_sro.cpp selects it under that define.  Without
# it the model build dies at `fatal error: Vwrap_byte_sro.h: No such file or directory`,
# exactly as build_sro_rxfix4b.sh and build_sro_bs.sh did before their fixes.  The
# INJECTED path is unchanged (CFLAGS empty), so its binary is bit-for-bit what it was.
CFL=""; [ "$MODEL" = 1 ] && CFL="-CFLAGS -DSRO_MODEL"
verilator -O2 -Wno-fatal --cc "$WRAP" -y "$TREE" -y "$KIT/rtl_sim" +define+RXFIX_BS $GPARAM $CFL \
  --exe sim_sro.cpp -Mdir "$O" --top-module "$TOP" > "${O}_verilate.log" 2>&1 || { echo BUILD_SRO_PAD_FAIL verilate; tail -5 ${O}_verilate.log; exit 1; }
grep -qF "$WRAP" "${O}_verilate.log" || { echo "BUILD_SRO_PAD_FAIL wrapper not read"; exit 1; }
if [ "$MODEL" = 0 ]; then
  grep -q 's1_rtl_pad/' "${O}_verilate.log" || { echo "BUILD_SRO_PAD_FAIL tree not read"; exit 1; }
  for other in s1_rtl_bs s1_rtl_bs_base s1_rtl_bs_gen; do grep -q "$other/" "${O}_verilate.log" && { echo "BUILD_SRO_PAD_FAIL $other read"; exit 1; }; done
fi
make -s -j"$(nproc)" -C "$O" -f "V$TOP.mk" "V$TOP" > "${O}_make.log" 2>&1 || { echo BUILD_SRO_PAD_FAIL make; tail -5 ${O}_make.log; exit 1; }
echo "BUILD_SRO_PAD_OK $O $(md5sum "$O/V$TOP" | cut -d' ' -f1)"
