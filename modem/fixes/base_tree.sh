#!/bin/bash
# base_tree.sh -- fetch/verify the banked base Vivado tree the fix chain starts from.
# The base tree (jupiter_byte_ddrcap2_build, ~1.5GB without runs) cannot live in git;
# it is banked locally and on hdl-dev-2 and pinned by sha256 in fixes.toml.
#
# fetch: if the local bank (/mnt/onetb/scratch/qpsk-build-trees/base) has the tree,
#   copy it AS-IS (no excludes -- apply_fixes.py prunes vivado_prj.gen/ from its own
#   WORK copy later, and the bank's manifest already covers everything in the bank,
#   so an exclude here would make the copy stop matching the manifest) into
#   <dest_parent>/<base_tree>, plus BASE_MANIFEST.txt, then verify.
#   Otherwise fetch fresh from hdl-dev-2 with the txfix_build.sh.tmpl:66-78 exclude
#   list (runs/cache/sim/hw/logs), generate a new BASE_MANIFEST.txt -- this cannot
#   match the pinned sha (different fetch date), so print BASE_TREE_NEW_FETCH and
#   exit 3 rather than silently passing; a fresh pin is a controlled re-pin in
#   fixes.toml, not something this script decides on its own.
# verify: (1) sha256 the *whole* BASE_MANIFEST.txt file (header line included) and
#   compare to meta.base_manifest_sha256; (2) recompute the sha256 body over
#   <dest_parent>/<base_tree> and diff it against `tail -n +2` of the manifest
#   (the header line is fetch-time/host-specific and excluded from the body diff).
# verify-bank: pure off-repo-input check, no <dest_parent> -- confirms the LOCAL_BANK
#   base tree tarball, its BASE_MANIFEST.txt and the SRO sim listing still match the
#   pins in bank.sha256 (BANK_SHA256_FILE overrides the pin file). This is a sha256sum
#   -c pass over the first two lines plus a recomputed listing digest for the third;
#   it does not touch <dest_parent> and is meant to run before fetch/verify or a gate.
# Usage: base_tree.sh fetch <dest_parent> | verify <dest_parent> | verify-bank
set -euo pipefail
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  echo "usage: $0 fetch|verify <dest_parent> | verify-bank"
  exit 2
fi
if [ "${1:-}" = "verify-bank" ]; then
  HERE=$(cd "$(dirname "$0")" && pwd)
  BANKFILE="${BANK_SHA256_FILE:-$HERE/../gates/bank.sha256}"   # moved to modem/gates/ by sp3 Task 11
  [ -f "$BANKFILE" ] || { echo "BANK_MISMATCH no bank.sha256 at $BANKFILE"; exit 1; }
  LOCAL_BANK=/mnt/onetb/scratch/qpsk-build-trees
  # Select pins by filename, not line position: bank.sha256 is an integrity file, so
  # a reordered or fourth line silently mis-binding a hash to the wrong file is the
  # failure mode that matters here.
  TARLINE=$(grep -v '^#' "$BANKFILE" | grep -E '  s1_rtl_pristine\.tar\.gz$')
  MANLINE=$(grep -v '^#' "$BANKFILE" | grep -E '  base/BASE_MANIFEST\.txt$')
  SROLINE=$(grep -v '^#' "$BANKFILE" | grep -E '  sro_sim\.listing$')
  [ -n "$TARLINE" ] && [ -n "$MANLINE" ] && [ -n "$SROLINE" ] \
    || { echo "BANK_MISMATCH bank.sha256 missing an expected pin line (tarball/manifest/listing)"; exit 1; }
  if ! ( cd "$LOCAL_BANK" && printf '%s\n' "$TARLINE" "$MANLINE" | sha256sum -c - ); then
    echo "BANK_MISMATCH file hash check failed (tarball or BASE_MANIFEST.txt)"
    exit 1
  fi
  WANT_SRO=$(echo "$SROLINE" | cut -d' ' -f1)
  SRODIR="$LOCAL_BANK/sro_sim"
  [ -d "$SRODIR" ] || { echo "BANK_MISMATCH no sro_sim dir at $SRODIR"; exit 1; }
  HAVE_SRO=$( ( cd "$SRODIR" && find . -type f -print0 | sort -z | xargs -0 sha256sum ) | sha256sum | cut -d' ' -f1)
  [ "$HAVE_SRO" = "$WANT_SRO" ] || { echo "BANK_MISMATCH sro_sim listing digest $HAVE_SRO != $WANT_SRO"; exit 1; }
  echo "BANK_OK $BANKFILE"
  exit 0
fi
if [ $# -lt 2 ]; then
  echo "usage: $0 fetch|verify <dest_parent> | verify-bank"
  exit 2
fi
HERE=$(cd "$(dirname "$0")" && pwd)
MAN="$HERE/fixes.toml"
NAME=$(python3 -c "import tomllib,sys;print(tomllib.load(open(sys.argv[1],'rb'))['meta']['base_tree'])" "$MAN")
WANT=$(python3 -c "import tomllib,sys;print(tomllib.load(open(sys.argv[1],'rb'))['meta']['base_manifest_sha256'])" "$MAN")
HOST=$(python3 -c "import tomllib,sys;print(tomllib.load(open(sys.argv[1],'rb'))['meta']['vivado_host'])" "$MAN")
LOCAL_BANK=/mnt/onetb/scratch/qpsk-build-trees/base
CMD=$1; DEST=$2
EXCL=(--exclude 'vivado_prj.runs/synth_1/' --exclude 'vivado_prj.runs/impl_1/' --exclude 'vivado_prj.runs/v_*/' --exclude 'vivado_prj.cache/' --exclude 'vivado_prj.sim/' --exclude 'vivado_prj.hw/' --exclude '*.log' --exclude '*.jou')
manifest_body() { ( cd "$1" && find . -type f -print0 | sort -z | xargs -0 sha256sum ); }
case "$CMD" in
  fetch)
    mkdir -p "$DEST"
    if [ -d "$LOCAL_BANK/$NAME" ]; then
      rsync -a "$LOCAL_BANK/$NAME/" "$DEST/$NAME/"; cp "$LOCAL_BANK/BASE_MANIFEST.txt" "$DEST/"
      exec "$0" verify "$DEST"
    else
      rsync -a "${EXCL[@]}" "$HOST:qpsk-builds/$NAME/" "$DEST/$NAME/"
      { echo "base=$NAME source=$HOST:~/qpsk-builds fetched=$(date -Is)"; manifest_body "$DEST/$NAME"; } > "$DEST/BASE_MANIFEST.txt"
      NEWSHA=$(sha256sum "$DEST/BASE_MANIFEST.txt" | cut -d' ' -f1)
      echo "BASE_TREE_NEW_FETCH sha=$NEWSHA -- fresh fetch from $HOST cannot match the pinned meta.base_manifest_sha256 (different fetch date); if this is expected, re-pin base_manifest_sha256=$NEWSHA in fixes.toml deliberately, then re-run verify"
      exit 3
    fi ;;
  verify)
    [ -f "$DEST/BASE_MANIFEST.txt" ] || { echo "BASE_TREE_MISMATCH no BASE_MANIFEST.txt in $DEST"; exit 1; }
    HAVE=$(sha256sum "$DEST/BASE_MANIFEST.txt" | cut -d' ' -f1)
    [ "$HAVE" = "$WANT" ] || { echo "BASE_TREE_MISMATCH manifest sha $HAVE != $WANT"; exit 1; }
    manifest_body "$DEST/$NAME" > "$DEST/.verify.body"
    if ! diff -q <(tail -n +2 "$DEST/BASE_MANIFEST.txt") "$DEST/.verify.body" >/dev/null; then
      echo "BASE_TREE_MISMATCH $(diff <(tail -n +2 "$DEST/BASE_MANIFEST.txt") "$DEST/.verify.body" | grep '^[<>]' | head -1)"
      rm -f "$DEST/.verify.body"; exit 1
    fi
    echo "BASE_TREE_OK files=$(wc -l < "$DEST/.verify.body")"
    rm -f "$DEST/.verify.body" ;;
  *) echo "usage: $0 fetch|verify <dest_parent> | verify-bank"; exit 2 ;;
esac
