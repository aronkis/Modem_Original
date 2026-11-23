#!/bin/bash
# test_verify_bank.sh -- base_tree.sh verify-bank must:
#   1. pass (BANK_OK) against the real modem/fixes/bank.sha256 and the real
#      LOCAL_BANK, proving the untampered path actually works (not vacuous);
#   2. fail (BANK_MISMATCH, rc!=0) when a file-hash LINE in the pin file is
#      tampered, without needing a full 910-file sro_sim recompute to notice.
#
# The LOCAL_BANK this exercises (/mnt/onetb/scratch/qpsk-build-trees/) is a
# lab-host-only off-repo bank and does not exist on CI runners. When it is
# absent, both checks would fail for the wrong reason (missing files, not a
# bad hash) -- so this script detects that case up front and exits 0 with an
# explicit SKIP marker instead of a false BANK_MISMATCH.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
BT="$HERE/../base_tree.sh"
BANKFILE="$HERE/../bank.sha256"
LOCAL_BANK=/mnt/onetb/scratch/qpsk-build-trees
[ -f "$BT" ] || { echo "VERIFYBANK_FAIL no base_tree.sh at $BT"; exit 1; }
[ -f "$BANKFILE" ] || { echo "VERIFYBANK_FAIL no bank.sha256 at $BANKFILE"; exit 1; }

if [ ! -d "$LOCAL_BANK" ]; then
  echo "VERIFYBANK_SKIP no bank at $LOCAL_BANK"
  exit 0
fi

fails=0

# 1. Untampered: must yield BANK_OK, or the rest of this test is vacuous.
OUT=$(bash "$BT" verify-bank 2>&1); RC=$?
if [ $RC -eq 0 ] && echo "$OUT" | grep -q '^BANK_OK'; then
  echo "  ok   untampered bank.sha256 verifies (BANK_OK)"
else
  echo "  FAIL untampered verify-bank did not report BANK_OK (rc=$RC): $OUT"; fails=$((fails+1))
fi

# 2. Tampered: flip a character in the tarball hash line (line 19, the first
#    non-comment sha256 line) and confirm sha256sum -c catches it WITHOUT a
#    910-file sro_sim recompute -- tamper only the file-hash half of the pin.
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
TARLINE_NO=$(grep -n -v '^#' "$BANKFILE" | grep -m1 -E '^[0-9]+:[0-9a-f]{64}  s1_rtl_pristine\.tar\.gz$' | cut -d: -f1)
if [ -z "$TARLINE_NO" ]; then
  echo "  FAIL could not locate the tarball hash line in $BANKFILE"; fails=$((fails+1))
else
  sed "${TARLINE_NO}s/^./f/" "$BANKFILE" > "$T/tampered.sha256"
  TOUT=$(BANK_SHA256_FILE="$T/tampered.sha256" bash "$BT" verify-bank 2>&1); TRC=$?
  if [ $TRC -ne 0 ] && echo "$TOUT" | grep -q '^BANK_MISMATCH'; then
    echo "  ok   tampered tarball-hash line is caught (BANK_MISMATCH, rc=$TRC)"
  else
    echo "  FAIL tampered bank.sha256 was NOT caught (rc=$TRC): $TOUT"; fails=$((fails+1))
  fi
fi

if [ $fails -eq 0 ]; then echo "VERIFYBANK_OK all checks, 0 failures"; exit 0; fi
echo "VERIFYBANK_FAIL $fails failure(s)"; exit 1
