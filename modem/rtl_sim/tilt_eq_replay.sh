#!/bin/bash
# tilt_eq_replay.sh <pair.iq> <obj dir> <out prefix> -- replay a RECORDED receiver-input capture through the
# TiltEq-equipped receiver model with the corrector set from the file's own measured slope (the host path:
# ops/tilt_score.py -> ops/tilt_eq_solve.py --env). Used by modem/gates/tilt_eq.legs te_replay_* rows.
set -u; D=$(cd "$(dirname "$0")" && pwd); OPS=$D/../../ops
IQ=${1:?pair.iq}; OBJ=${2:?obj dir}; OUT=${3:?out prefix}
T=$(python3 "$OPS/tilt_score.py" --json "$IQ" | tail -1 | python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["tilt_db"])')
EQ=$(python3 "$OPS/tilt_eq_solve.py" --env "$T")
echo "TILT_EQ_REPLAY iq=$IQ tilt_db=$T $EQ"
env PERT_LOOP=0 $EQ "$OBJ/Vwrap_byte_sro_model" rx "$IQ" 4000000 8400 "$OUT" 2 0
