#!/bin/bash
# test_build_image_unitparse.sh -- the systemd unit name build_image.sh waits on
# must come from the template's OWN launch line, never from the first
# txfix-build-* token in the log.
#
# Why this test exists: under ALLOW_CONCURRENT=1 (two builds sharing the Vivado
# host) modem/vivado/txfix_build.sh.tmpl's preflight prints
#   TXFIX_BUILD preflight NOTE: proceeding alongside active unit(s) [<OTHER>] ...
# naming the OTHER role's unit, and it is printed BEFORE this build's own
# TXFIX_BUILD launched ... as unit <MINE> ; line. A `grep -oE 'txfix-build-[...]+'
# | head -1` therefore harvests the peer's unit: build_image.sh would poll the
# wrong unit, return when the PEER finished, and rsync a BOOT.BIN that is either
# missing or from the other role.
#
# The parser under test is extracted from modem/build_image.sh so the two cannot
# drift: this script greps the sed line out of build_image.sh and runs it.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
BI="$HERE/../build_image.sh"
[ -f "$BI" ] || { echo "UNITPARSE_FAIL no build_image.sh at $BI"; exit 1; }

# The one-liner form of build_image.sh's two-line UNIT= assignment.
SEDPROG=$(sed -n "s/^ *UNIT=\$(sed -n '\(.*\)' \\\\$/\1/p" "$BI")
[ -n "$SEDPROG" ] || { echo "UNITPARSE_FAIL could not extract the UNIT sed program from build_image.sh"; exit 1; }
parse() { sed -n "$SEDPROG" "$1" | tail -1; }

fails=0
check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: expected [$2] got [$3]"; fails=$((fails+1)); fi
}

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# 1. The ALLOW_CONCURRENT case: a NOTE naming ANOTHER unit comes FIRST.
cat > "$T/concurrent.log" <<'LOG'
TXFIX_BUILD preflight start 2026-09-10T09:00:00-04:00 kit=jupiter_byte_rxfixr4dr1sp2_build variant=F3 jobs=3
TXFIX_BUILD preflight disk free=46GB
TXFIX_BUILD preflight NOTE: proceeding alongside active unit(s) [txfix-build-rxfixpadsp2_build-1111111111.service] under ALLOW_CONCURRENT=1
TXFIX_BUILD sync start 2026-09-10T09:00:01-04:00
TXFIX_BUILD sync done 2026-09-10T09:00:40-04:00
TXFIX_UNIT txfix-build-rxfixr4dr1sp2_build-2222222222 started 2026-09-10T09:00:41-04:00
TXFIX_BUILD launched on hdl-dev-2 as unit txfix-build-rxfixr4dr1sp2_build-2222222222 ; remote tree: /home/tcollins/qpsk-builds/jupiter_byte_rxfixr4dr1sp2_build
  check with: ssh hdl-dev-2 systemctl --user status txfix-build-rxfixr4dr1sp2_build-2222222222
  log at:     ssh hdl-dev-2 tail -f /home/tcollins/qpsk-builds/jupiter_byte_rxfixr4dr1sp2_build/build_txfix_vivado.log
LOG
check "concurrent log yields THIS build's unit, not the peer named first" \
  "txfix-build-rxfixr4dr1sp2_build-2222222222" "$(parse "$T/concurrent.log")"

# The naive parser must genuinely have been wrong on that log, or this test is vacuous.
naive=$(grep -oE 'txfix-build-[A-Za-z0-9_.@-]+' "$T/concurrent.log" | head -1)
if [ "$naive" = "txfix-build-rxfixr4dr1sp2_build-2222222222" ]; then
  echo "  FAIL fixture is vacuous: the naive head -1 parser already gets it right"; fails=$((fails+1))
else
  echo "  ok   fixture is non-vacuous (naive parser returns [$naive])"
fi

# 2. The ordinary single-build log still parses.
cat > "$T/solo.log" <<'LOG'
TXFIX_BUILD preflight start 2026-09-10T09:00:00-04:00 kit=jupiter_byte_rxfixpadsp2_build variant=F3 jobs=6
TXFIX_BUILD sync done 2026-09-10T09:00:40-04:00
TXFIX_BUILD launched on hdl-dev-2 as unit txfix-build-rxfixpadsp2_build-3333333333 ; remote tree: /home/tcollins/qpsk-builds/jupiter_byte_rxfixpadsp2_build
  check with: ssh hdl-dev-2 systemctl --user status txfix-build-rxfixpadsp2_build-3333333333
LOG
check "solo log" "txfix-build-rxfixpadsp2_build-3333333333" "$(parse "$T/solo.log")"

# 3. A --dry log has NO launch line, so the parse must come back EMPTY and let
#    build_image.sh raise BUILD_IMAGE_VIVADO_FAIL rather than wait on a phantom.
cat > "$T/dry.log" <<'LOG'
TXFIX_BUILD preflight start 2026-09-10T09:00:00-04:00 kit=jupiter_byte_rxfixpadsp2_build variant=F3 jobs=6
TXFIX_BUILD_DRY unit=txfix-build-rxfixpadsp2_build-4444444444 remote_dir=/home/tcollins/qpsk-builds/jupiter_byte_rxfixpadsp2_build jobs=6 variant=F3
TXFIX_BUILD_DRY would run: ssh hdl-dev-2 "REMOTE_DIR='...' UNIT='txfix-build-rxfixpadsp2_build-4444444444' ..."
LOG
check "dry log yields nothing (no launch happened)" "" "$(parse "$T/dry.log")"

# 4. A failed preflight yields nothing.
printf 'TXFIX_BUILD_PREFLIGHT_FAILED concurrent build unit(s) active on hdl-dev-2: txfix-build-rxfixpadsp2_build-5555555555\n' > "$T/refused.log"
check "refused-launch log yields nothing" "" "$(parse "$T/refused.log")"

# 5. The `hdl` stage.  --from hdl --dry must name build_hdl.sh without running
#    MATLAB, and -- unlike sp2, where the default start was `base` so that the
#    20-minute regen was never run unasked -- sp3's default --from IS `hdl`:
#    the model regen is now the pipeline's only source of RTL, not evidence
#    beside a banked tree, so a default that skipped it would have nothing to
#    build from.
HDLWORK=$(mktemp -d)
HDLDRY=$(bash "$BI" --work "$HDLWORK" --from hdl --dry --stop-after hdl 2>&1) || true
if printf '%s' "$HDLDRY" | grep -q 'build_hdl.sh'; then
  echo "  ok   --from hdl --dry names build_hdl.sh"
else
  echo "  FAIL --from hdl --dry did not name build_hdl.sh: [$HDLDRY]"; fails=$((fails+1))
fi
if printf '%s' "$HDLDRY" | grep -q -- '--complete-bd'; then
  echo "  ok   --from hdl --dry shows the --complete-bd BD completion"
else
  echo "  FAIL --from hdl --dry did not show --complete-bd: [$HDLDRY]"; fails=$((fails+1))
fi
# A dry hdl run stamps hdl.dry and NOT hdl: a real stage must never inherit a
# dry stamp (the same convention the vivado stage uses).
if [ -f "$HDLWORK/STAMP.hdl.dry" ] && [ ! -f "$HDLWORK/STAMP.hdl" ]; then
  echo "  ok   --dry writes STAMP.hdl.dry only"
else
  echo "  FAIL --dry stamping is wrong: $(ls "$HDLWORK")"; fails=$((fails+1))
fi
rm -rf "$HDLWORK"
DEFAULT_FROM=$(sed -n 's/^FROM=\(.*\)$/\1/p' "$BI")
check "default --from is hdl (the model regen is the pipeline's source)" "hdl" "$DEFAULT_FROM"
DEFAULT_TAG=$(sed -n 's/^TAG=\(.*\)$/\1/p' "$BI")
check "default --tag is sp4 (the 2-sps rung, 2026-09-18)" "sp4" "$DEFAULT_TAG"

# 6. The stamp contract: model_tree_sha, not sp2's manifest_sha.
# (the header comment says what model_tree_sha REPLACED, so only CODE lines are
# checked for the retired name.)
if grep -q 'model_tree_sha=%s' "$BI" && ! grep -n 'manifest_sha' "$BI" | grep -qv '^[0-9]*: *#'; then
  echo "  ok   STAMP lines carry model_tree_sha and no manifest_sha in code"
else
  echo "  FAIL the STAMP contract still uses manifest_sha"; fails=$((fails+1))
fi

if [ $fails -eq 0 ]; then echo "UNITPARSE_OK all checks, 0 failures"; exit 0; fi
echo "UNITPARSE_FAIL $fails failure(s)"; exit 1
