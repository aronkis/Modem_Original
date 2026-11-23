#!/bin/bash
# test_make_kit.sh -- modem/common/tools/make_kit.sh assembles a complete, symlink-free kit
# for both trees: the kit-root contract every build/gate/derivation script relies on
# (bd/ model/ rxfifo/ tools/ gates/ instruments/ vivado/ rtl_sim/ at the kit root, the
# stage folders, a COPIED sibling contract/, the KITDIR repoint, prod's borrowed analysers
# and rtl_sim_overrides, --with-tools for derive/ and edit/).
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd); MK="$REPO/modem/common/tools/make_kit.sh"
fail(){ echo "MAKE_KIT_TEST_FAIL $*"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
for tree in dev prod; do
  K="$T/$tree/kit"; mkdir -p "$T/$tree"
  out=$(bash "$MK" "$tree" "$K" 2>&1) || fail "$tree: $out"
  echo "$out" | grep -q "^MAKE_KIT_OK tree=$tree " || fail "$tree: no MAKE_KIT_OK ($out)"
  for f in bd/complete_byte_bd.tcl bd/complete_byte_t8.tcl bd/timing_gate.tcl bd/cdc_exceptions.xdc model/frame_config_k5.m \
           model/kitpath.m model/kit_contract_dir.m rxfifo/rxfifo_inject.sh rxfifo/ByteRxFifo.v tools/tmr_attr_inject.sh \
           gates/run_gates.sh gates/model_matrix.legs instruments/seqbist/apply_seqbist.sh vivado/txfix_build.tcl.tmpl \
           rtl_sim/wrap_byte.v rtl_sim/sim_byte.cpp rtl_sim/make_sro_trees.sh rtl_sim/sro_score \
           build_variant_byte.m hdlworkflow_loopback.m kitpath.m kit_contract_dir.m simgate/sim_byte_gate_k5.m simgate/gen_byte_vectors_k5.m \
           hdlsim/checkhdl_gate_240k5_byte.m hdlsim/s1_analyze_240k5.m hdlsim/s1b_analyze_byte.m; do
    [ -e "$K/$f" ] || fail "$tree: kit lacks $f"
  done
  [ "$tree" = prod ] || { for f in simulink/assemble_jupiter_240k5_byte.m hdlcoder; do [ -e "$K/$f" ] || fail "dev: kit lacks $f"; done; }
  [ -f "$T/$tree/contract/rom_words_70_k5.txt" ] || fail "$tree: sibling contract/ not copied"
  [ ! -L "$T/$tree/contract" ] || fail "$tree: contract is a link"
  [ -z "$(find "$K" "$T/$tree/contract" -type l | head -1)" ] || fail "$tree: symlink inside the kit"
  [ ! -e "$K/derive" ] && [ ! -e "$K/edit" ] || fail "$tree: derive/edit copied without --with-tools"
  [ -z "$(find "$K" -name '*.log' -o -name 'slprj' -o -name 'hdl_prj_*' -o -name 'obj_*' -o -name 'studies' | head -1)" ] || fail "$tree: generated material in the kit"
  # KITDIR repoint: no shipped .m still names the repo tree
  hits=$(grep -rl --include='*.m' "$REPO/modem/$tree" "$K" | head -3)
  [ -z "$hits" ] || fail "$tree: .m files still name the repo tree: $hits"
done
# prod: the netlist bench overrides are installed over the rtl_sim names
cmp -s "$REPO/modem/prod/hdlsim/rtl_sim_overrides/wrap_byte.v" "$T/prod/kit/rtl_sim/wrap_byte.v" || fail "prod: rtl_sim_overrides not installed"
# --with-tools carries prod's derive/ and edit/
K="$T/tools/kit"; mkdir -p "$T/tools"
bash "$MK" prod "$K" --with-tools >/dev/null 2>&1 || fail "prod --with-tools"
[ -f "$K/derive/derive.sh" ] && [ -f "$K/edit/make_edit_kit.sh" ] || fail "--with-tools: derive/ or edit/ missing"
[ -z "$(find "$K" -type l | head -1)" ] || fail "--with-tools: symlink inside the kit"
bash "$MK" other "$T/x" >/dev/null 2>&1 && fail "accepted a bad tree name"
echo "MAKE_KIT_TEST_OK"
