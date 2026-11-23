#!/bin/bash
# test_no_symlinks.sh -- the repo carries NO symlinks (operator rule, 2026-09-17: "I don't
# want to use any aliases"). Shared files live once under modem/common/ and are copied into
# scratch kits by modem/common/tools/make_kit.sh; images/ carries one canonical file per image.
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
links=$(git -C "$REPO" ls-files -s | awk '$1=="120000"{print $4}')
[ -z "$links" ] || { echo "NO_SYMLINKS_FAIL tracked symlinks:"; echo "$links"; exit 1; }
# the old link farm must not come back under another name
[ ! -e "$REPO/modem/common/tools/kit_links.sh" ] || { echo "NO_SYMLINKS_FAIL kit_links.sh is back"; exit 1; }
for d in bd model rxfifo tools; do
  [ -d "$REPO/modem/common/$d" ] || { echo "NO_SYMLINKS_FAIL modem/common/$d missing"; exit 1; }
  for t in dev prod; do [ ! -e "$REPO/modem/$t/$d" ] || { echo "NO_SYMLINKS_FAIL modem/$t/$d exists (kits get it from make_kit.sh)"; exit 1; }; done
done
echo "NO_SYMLINKS_OK"
