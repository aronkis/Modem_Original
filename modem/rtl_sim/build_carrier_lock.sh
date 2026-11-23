#!/bin/bash
# build_carrier_lock.sh -- Verilate the f3072 model tree with the symbol-synchronizer taps
# (wrap_byte_sro4b_ss.v) and the perturbation driver (sim_sro_perturb.cpp) for the carrier-lock
# gate legs (modem/gates/carrier_lock.legs). TREE (env, default s1_rtl_model) is the tree under test.
set -u
D=$(cd "$(dirname "$0")" && pwd); cd "$D"
TREE=${TREE:-s1_rtl_model}; OBJ=${OBJ:-obj_carrier_lock_model}
[ -d "$TREE" ] || { echo "BUILD_CARRIER_LOCK_FAILED no tree $TREE"; exit 1; }
verilator -O2 -Wno-fatal --cc "${WRAP:-wrap_byte_sro4b_ss.v}" -y "$TREE" -y . +define+RXFIX_R4B "-GFIXCTL_INIT=32'h0" \
  -CFLAGS "-DSRO_MODEL -DHAVE_AGC_TAP -DHAVE_SS_TAP ${CFLAGS_EXTRA:-}" ${VDEFINES_EXTRA:-} --exe "$D/sim_sro_perturb.cpp" -Mdir "$OBJ" \
  --top-module wrap_byte_sro_model >"${OBJ}_verilate.log" 2>&1 || { echo "BUILD_CARRIER_LOCK_FAILED verilator"; grep -E '%Error' "${OBJ}_verilate.log" | head -5; exit 1; }
make -s -j"${GATES_JOBS:-4}" -C "$OBJ" -f Vwrap_byte_sro_model.mk Vwrap_byte_sro_model >"${OBJ}_make.log" 2>&1 || { echo "BUILD_CARRIER_LOCK_FAILED make"; exit 1; }
echo "BUILD_CARRIER_LOCK_DONE $OBJ tree=$TREE"
