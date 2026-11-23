#!/bin/bash
# test_build_hdl_skipseqbist.sh -- SP3_SKIP_SEQBIST=1 really removes step [5c]
# from modem/build_hdl.sh's --complete-bd path.
#
# `modem/rxfix/README.md` names a discriminating rebuild for the sp3 TX-side
# wedge: rebuild "without the SEQ-BIST stage" to drop suspect 2 (the SEQ-BIST
# BD instrument emitted with the `vendh` variant onto the 148-lineage BD). Until
# this knob existed there was no way to express that -- the seqbist copy, the
# `source seqbist_bd.tcl` line and the hard SEQBIST_WIRE_OK log gate were all
# unconditional, so the named experiment was not runnable.
#
# This is a TEXT test, like its siblings: it EXTRACTS the two decisions the knob
# makes out of the real build_hdl.sh (the SEQBIST_SRC_LINE / SEQBIST_TOK
# assignment block) and runs them at both settings, so what is tested cannot
# drift from what ships. It never invokes MATLAB or Vivado.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
BH="$HERE/../build_hdl.sh"
[ -f "$BH" ] || { echo "SKIPSEQBIST_FAIL no build_hdl.sh at $BH"; exit 1; }

fail(){ echo "SKIPSEQBIST_FAIL $*"; exit 1; }

# (a) the knob is documented in the header, with the token it prints
grep -q 'SP3_SKIP_SEQBIST=1' "$BH" || fail "SP3_SKIP_SEQBIST not mentioned in build_hdl.sh"
grep -q 'SEQBIST_SKIPPED' "$BH"    || fail "build_hdl.sh never prints SEQBIST_SKIPPED"

# (b) the hard log gate and the saved-BD cell check are no longer unconditional
grep -q '\$DDRCAP_TOK \$SEQBIST_TOK COMPLETE_BD_RUN_DONE' "$BH" \
  || fail "the BD token list still hard-codes SEQBIST_WIRE_OK"
grep -q 'if \[ -n "\$SEQBIST_TOK" \]; then' "$BH" \
  || fail "the saved-system.bd seqbist cell check is still unconditional"

# (c) run the extracted decision block at both settings. The block is delimited
#     by the SEQBIST_SRC_LINE assignment and the `fi` that closes its if.
BLOCK=$(awk '/^  SEQBIST_SRC_LINE=/{p=1} p{print} p&&/^  fi$/{exit}' "$BH")
[ -n "$BLOCK" ] || fail "could not extract the SEQBIST_SRC_LINE block from build_hdl.sh"
case "$BLOCK" in
  *SP3_SKIP_SEQBIST*) ;;
  *) fail "extracted block does not test SP3_SKIP_SEQBIST" ;;
esac

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/instr/seqbist" "$TMP/repo/modem/rtl_sim" "$TMP/fresh"
touch "$TMP/instr/seqbist/seqbist_bd.tcl"
for f in qpsk_traffic_gen_v2.v rx_seq_checker.v cnt_mux32.v; do
  echo "// $f" > "$TMP/repo/modem/rtl_sim/$f"
done

run_block(){ # $1 = value of SP3_SKIP_SEQBIST ("" means unset)
  env -u SP3_SKIP_SEQBIST ${1:+SP3_SKIP_SEQBIST="$1"} \
    INSTR="$TMP/instr" REPO="$TMP/repo" FRESH="$TMP/fresh" \
    bash -c "set -u
      SEQBIST_DIR=\"\$INSTR/seqbist\"
$BLOCK
      echo \"TOK=[\$SEQBIST_TOK]\"
      echo \"SRC=[\$SEQBIST_SRC_LINE]\"" 2>&1
}

ON=$(run_block "") || fail "default (knob unset) path errored: $ON"
case "$ON" in
  *"TOK=[SEQBIST_WIRE_OK]"*) ;;
  *) fail "default path did not require SEQBIST_WIRE_OK: $ON" ;;
esac
case "$ON" in
  *"SRC=[source $TMP/fresh/seqbist_bd.tcl]"*) ;;
  *) fail "default path does not source seqbist_bd.tcl: $ON" ;;
esac
case "$ON" in *SEQBIST_SKIPPED*) fail "default path printed SEQBIST_SKIPPED: $ON" ;; esac
[ -f "$TMP/fresh/seqbist_bd.tcl" ] || fail "default path did not install seqbist_bd.tcl"
[ -f "$TMP/fresh/rx_seq_checker.v" ] || fail "default path did not install the Task-1 RTL"

rm -f "$TMP/fresh"/*.tcl "$TMP/fresh"/*.v
OFF=$(run_block 1) || fail "SP3_SKIP_SEQBIST=1 path errored: $OFF"
case "$OFF" in
  *"SEQBIST_SKIPPED reason=SP3_SKIP_SEQBIST=1"*) ;;
  *) fail "SP3_SKIP_SEQBIST=1 did not print SEQBIST_SKIPPED: $OFF" ;;
esac
case "$OFF" in
  *"TOK=[]"*) ;;
  *) fail "SP3_SKIP_SEQBIST=1 still requires a SEQ-BIST token: $OFF" ;;
esac
case "$OFF" in
  *"SRC=[# seqbist_bd.tcl SKIPPED (SP3_SKIP_SEQBIST=1)]"*) ;;
  *) fail "SP3_SKIP_SEQBIST=1 still sources seqbist_bd.tcl: $OFF" ;;
esac
[ -f "$TMP/fresh/seqbist_bd.tcl" ] && fail "SP3_SKIP_SEQBIST=1 still installed seqbist_bd.tcl"
[ -f "$TMP/fresh/rx_seq_checker.v" ] && fail "SP3_SKIP_SEQBIST=1 still installed the Task-1 RTL"

# (d) a missing seqbist_bd.tcl is STILL a hard failure on the default path --
#     the knob must not have turned that gate into a silent skip.
rm -f "$TMP/instr/seqbist/seqbist_bd.tcl"
MISS=$(run_block "" 2>&1)
case "$MISS" in
  *BUILD_HDL_FAIL*seqbist_bd.tcl*) ;;
  *) fail "a missing seqbist_bd.tcl no longer fails the default path: $MISS" ;;
esac

echo "SKIPSEQBIST_OK"
