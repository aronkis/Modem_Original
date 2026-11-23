#!/bin/bash
# patch_gates_for_flat.sh <kit> -- turn a dev-derived kit's gate scripts into the
# flat/prod variants (idempotent):
#   hdlsim/checkhdl_gate_240k5_byte.m  assemble call -> load_system (gate the model as-is)
#   simgate/sim_byte_gate_k5.m          stale-description branch -> error (never re-assemble)
#   hdlsim/run_netlist_gates.sh        S1 stage skipped at QPSK_FRAME != k5 (k5-only analyser)
#   simulink/assemble_jupiter_240k5_byte.m  disabled (errors on line 1)
# Used by derive.sh (dev kit -> prod files) and kept for reference by the edit kit.
set -u
FRESH=${1:?kit dir}
cd "$FRESH" || exit 1

# the kitpath / stage-folder layout (2026-09-17) spells the assemble call without the
# simulink/ prefix; normalise both gate scripts first so the anchors below keep matching
sed -i "s#^run('assemble_jupiter_240k5_byte.m');#run('simulink/assemble_jupiter_240k5_byte.m');#" hdlsim/checkhdl_gate_240k5_byte.m
sed -i "s#^    run('assemble_jupiter_240k5_byte.m');#    run('simulink/assemble_jupiter_240k5_byte.m');#" simgate/sim_byte_gate_k5.m

if grep -q "^run('simulink/assemble_jupiter_240k5_byte.m');" hdlsim/checkhdl_gate_240k5_byte.m; then
  sed -i "s#^run('simulink/assemble_jupiter_240k5_byte.m');#load_system(sys); set_param(0,'CurrentSystem',sys); evalin('base', get_param(sys,'InitFcn')); fprintf('PROD: gating the flattened model, no assemble\\\\n');#" hdlsim/checkhdl_gate_240k5_byte.m
fi
grep -q "no assemble" hdlsim/checkhdl_gate_240k5_byte.m || { echo "FATAL: checkhdl gate patch did not apply"; exit 1; }

if grep -q "^    run('simulink/assemble_jupiter_240k5_byte.m');" simgate/sim_byte_gate_k5.m; then
  sed -i "s#^    run('simulink/assemble_jupiter_240k5_byte.m');#    error('PROD: model description does not match the byte variant (frame/sps) -- refusing to re-assemble the flattened model');#" simgate/sim_byte_gate_k5.m
fi
grep -q "refusing to re-assemble" simgate/sim_byte_gate_k5.m || { echo "FATAL: sim gate patch did not apply"; exit 1; }

if ! grep -q "k5-only analyser" hdlsim/run_netlist_gates.sh; then
python3 - hdlsim/run_netlist_gates.sh <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
a=s.index('echo "=== [3/4] S1 ROM-path iverilog regression ==="'); b=s.index('echo "=== [4/4]')
block=s[a:b]
guard='if [ "${QPSK_FRAME:-k5}" = k5 ]; then\n'+block+'else\n  echo "=== [3/4] S1 ROM-path: SKIPPED at QPSK_FRAME=$QPSK_FRAME (k5-only analyser) ==="\n  cd "$KIT/rtl_sim"\nfi\n'
open(p,'w').write(s[:a]+guard+s[b:])
PY
fi
grep -q "k5-only analyser" hdlsim/run_netlist_gates.sh || { echo "FATAL: runner S1 guard did not apply"; exit 1; }

if [ -f simulink/assemble_jupiter_240k5_byte.m ] && ! head -1 simulink/assemble_jupiter_240k5_byte.m | grep -q "disabled"; then
  sed -i "1i error('PROD/FLAT KIT: assemble is disabled here -- this kit carries the flattened model directly');" simulink/assemble_jupiter_240k5_byte.m
fi
echo "GATES_PATCHED_FOR_FLAT $FRESH"
