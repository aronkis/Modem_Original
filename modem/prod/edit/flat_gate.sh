#!/bin/bash
# flat_gate.sh -- run the checks against the EDITED model in the flat edit kit.
#
#   flat_gate.sh diff         flat_diff.m: structural diff vs flat_ref.slx + checksum (minutes)
#   flat_gate.sh candidates   flat_debug_candidates.m: what looks like removable debug (minutes)
#   flat_gate.sh rename [apply]  flat_rename_reg_ports.m: reg_ prefix on register ports (dry run unless apply)
#   flat_gate.sh order [apply]   flat_order_ports.m: DATA / CONTROL / DEBUG port numbering (dry run unless apply)
#   flat_gate.sh layout [apply] [Subsystem]
#                             flat_layout_lanes.m: lanes for TxRxComposite (default) or a preset subsystem
#                             (TxRxComposite/Receiver); TX / RX / DMA / DEBUG at the composite
#   flat_gate.sh snap [apply] [all|Subsystem]
#                             flat_snap_ports.m: ports beside their pins + colour code (composite, or all levels)
#   flat_gate.sh reroute [all|<subsystem>]
#                             flat_reroute.m: rebuild wires with the smart router (composite by default)
#   flat_gate.sh harness [apply] [remove-legacy]
#                             flat_root_harness.m: wire the model root around TxRxComposite for Play-button sims
#   flat_gate.sh simfix [apply]  flat_simfix.m: remove the BIST print branch, parameterise RxAlign latency
#   flat_gate.sh tidy [subsystem ...]
#                             flat_tidy.m: re-arrange + re-annotate + uniform ports, then save
#   flat_gate.sh sim          sim_byte_gate_k5.m -> SIM_BYTE_GATE_K5.txt  (inner loop, ~10-30 min)
#   flat_gate.sh hdl          run_netlist_gates.sh: checkhdl + makehdl + S1/S1B (outer loop, ~30-60 min)
#   flat_gate.sh all          diff, sim, hdl in sequence; stops at the first failure
#   flat_gate.sh status       last result line of every gate file in the kit
#
# Long gates (sim, hdl, all) run as a transient user unit and this script waits
# on it, so they survive a closed terminal; FG=1 runs in the foreground instead.
# KIT overrides the kit dir (default the one make_edit_kit.sh creates).
set -u
KIT=${KIT:-/mnt/onetb/scratch/qpsk-build-trees/flat_edit/jupiter_byte_flatedit_build}
[ -f "$KIT/env.sh" ] || { echo "FATAL: no flat edit kit at $KIT (run make_edit_kit.sh)"; exit 1; }
# shellcheck disable=SC1091
source "$KIT/env.sh"
cd "$KIT" || exit 1
mkdir -p "$KIT/flat_edit_logs"
STAMP=$(date +%Y%m%d-%H%M%S)

ml() {  # ml <name> <matlab statement>
  local name=$1; shift
  local log="$KIT/flat_edit_logs/$name-$STAMP.log"
  echo "=== $name -> $log ==="
  timeout 7200 matlab -batch "cd('$KIT'); kitpath('$KIT'); $*" > "$log" 2>&1
  local rc=$?
  grep -v "Trial License" "$log" | tail -8
  echo "$name rc=$rc log=$log"
  return $rc
}

run_unit() {  # run_unit <name> <command...>  -- transient unit, waited on
  local name=$1; shift
  if [ "${FG:-0}" = "1" ]; then bash -c "$*"; return $?; fi
  local unit="flat-$name-$STAMP"
  systemd-run --user --collect --same-dir --unit "$unit" \
    --setenv=QPSK_LEAN --setenv=QPSK_FRAME --setenv=QPSK_SPS --setenv=QPSK_BEATFIX --setenv=QPSK_BEATOBS \
    --setenv=QPSK_FRAMESTAT --setenv=QPSK_RXFIX --setenv=QPSK_TXFIX --setenv=PATH \
    bash -c "$* > '$KIT/flat_edit_logs/$name-$STAMP.unit.log' 2>&1" >/dev/null || return 1
  echo "launched unit $unit (log $KIT/flat_edit_logs/$name-$STAMP.unit.log)"
  while systemctl --user is-active --quiet "$unit"; do sleep 20; done
  tail -6 "$KIT/flat_edit_logs/$name-$STAMP.unit.log"
}

gate_diff()  { ml diff "flat_diff('$KIT');"; }
gate_cand()  { ml candidates "flat_debug_candidates('$KIT');"; }
gate_tidy()  { local args=""; for s in "$@"; do args="$args,'$s'"; done; ml tidy "flat_tidy('$KIT'$args);"; }
gate_rename() { if [ "${1:-}" = apply ]; then ml rename "flat_rename_reg_ports('$KIT','Apply',true);"; else ml rename "flat_rename_reg_ports('$KIT');"; fi; }
gate_order()  { if [ "${1:-}" = apply ]; then ml order "flat_order_ports('$KIT','Apply',true);"; else ml order "flat_order_ports('$KIT');"; fi; }
gate_layout() {
  local a="false" sub="TxRxComposite"; for x in "$@"; do [ "$x" = apply ] && a=true || sub="$x"; done
  ml layout "flat_layout_lanes('$KIT','$sub','Apply',$a);"
}
gate_snap() {
  local a="false" sc="composite" sub=""; for x in "$@"; do case "$x" in apply) a=true;; all) sc=all;; *) sub="$x";; esac; done
  ml snap "flat_snap_ports('$KIT','Apply',$a,'Scope','$sc','Subsystem','$sub');"
}
gate_reroute() {
  case "${1:-}" in
    "")  ml reroute "flat_reroute('$KIT');" ;;
    all) ml reroute "flat_reroute('$KIT','Scope','all');" ;;
    *)   ml reroute "flat_reroute('$KIT','Subsystem','$1');" ;;
  esac
}
gate_harness() {
  local a="false" rl="false"; for x in "$@"; do [ "$x" = apply ] && a=true; [ "$x" = remove-legacy ] && rl=true; done
  ml harness "flat_root_harness('$KIT','Apply',$a,'RemoveLegacy',$rl);"
}
gate_simfix() { if [ "${1:-}" = apply ]; then ml simfix "flat_simfix('$KIT','Apply',true);"; else ml simfix "flat_simfix('$KIT');"; fi; }
gate_sim() {
  run_unit sim "cd '$KIT' && matlab -batch \"cd('$KIT'); run('simgate/sim_byte_gate_k5.m')\""
  grep -q 'result: PASS' "$KIT/SIM_BYTE_GATE_K5.txt" 2>/dev/null \
    && { echo "SIM_GATE: PASS"; return 0; } || { echo "SIM_GATE: FAIL (see SIM_BYTE_GATE_K5.txt / sim_byte_gate_k5.log)"; return 1; }
}
gate_hdl() {
  local t0; t0=$(date +%s)
  run_unit hdl "cd '$KIT' && bash ./hdlsim/run_netlist_gates.sh"
  # a stamp only counts if it was (re)written by THIS run: the kit starts with
  # the repo's recorded stamps, which would otherwise read as a false PASS
  local ok=1
  fresh_pass() { [ -f "$1" ] && [ "$(date -r "$1" +%s)" -ge "$t0" ] && grep -q "$2" "$1"; }
  fresh_pass "$KIT/CHECKHDL_240K5_BYTE.txt" 'errors=0'    && echo "CHECKHDL: PASS" || { echo "CHECKHDL: FAIL (no fresh stamp)"; ok=0; }
  if [ "${QPSK_FRAME:-k5}" = k5 ]; then
    fresh_pass "$KIT/S1_GATE.txt" 'result: PASS'  && echo "S1_GATE: PASS"  || { echo "S1_GATE: FAIL (no fresh stamp)";  ok=0; }
  else
    echo "S1_GATE: SKIPPED (s1_analyze_240k5.m reads the k5 ROM file; the f1536 netlist gate is S1B + gates/run_gates.sh)"
  fi
  fresh_pass "$KIT/S1B_GATE.txt" 'result: PASS' && echo "S1B_GATE: PASS" || { echo "S1B_GATE: FAIL (no fresh stamp)"; ok=0; }
  [ $ok = 1 ]
}
status() {
  for f in FLAT_DIFF.txt SIM_BYTE_GATE_K5.txt CHECKHDL_240K5_BYTE.txt S1_GATE.txt S1B_GATE.txt; do
    if [ -f "$KIT/$f" ]; then
      printf '%-24s %s   (%s)\n' "$f" "$(grep -m1 -E 'result:|errors=|CHECKSUM' "$KIT/$f" || head -1 "$KIT/$f")" "$(date -r "$KIT/$f" +%F\ %T)"
    else printf '%-24s (not run)\n' "$f"; fi
  done
}

case "${1:-status}" in
  diff)        gate_diff ;;
  candidates)  gate_cand ;;
  rename)      gate_rename "${2:-}" ;;
  order)       gate_order "${2:-}" ;;
  layout)      shift; gate_layout "$@" ;;
  snap)        shift; gate_snap "$@" ;;
  reroute)     gate_reroute "${2:-}" ;;
  harness)     shift; gate_harness "$@" ;;
  simfix)      gate_simfix "${2:-}" ;;
  tidy)        shift; gate_tidy "$@" ;;
  sim)         gate_sim ;;
  hdl)         gate_hdl ;;
  all)         gate_diff && gate_sim && gate_hdl && echo "FLAT_GATES_ALL_PASS" ;;
  status)      status ;;
  *) echo "usage: $0 {diff|candidates|rename [apply]|order [apply]|layout [apply] [Subsystem]|snap [apply] [all|Subsystem]|reroute [all|subsystem]|harness [apply] [remove-legacy]|simfix [apply]|tidy [subsystem...]|sim|hdl|all|status}"; exit 2 ;;
esac
