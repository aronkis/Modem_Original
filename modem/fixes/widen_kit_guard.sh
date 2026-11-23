#!/bin/bash
# widen_kit_guard.sh <build_txfix.sh> <glob>  -- add <glob> (e.g. jupiter_byte_seqbist*_build) to the
# kit-name case guard of an instantiated modem/vivado/txfix_build.sh.tmpl, idempotently, whatever
# alternatives the guard already carries. The guard line has the shape
#   `  jupiter_byte_txfix*_build[|other*_build...]) ;;`
# and gained `|jupiter_byte_sp3*_build` in sp3 Task 11, which broke the literal seds the kit scripts
# used (SEQBIST_KIT_GUARD_FAILED on every sp2 rebuild after 2026-09-11). Exit 0 iff the glob is in the
# guard afterwards.
F=$1; G=$2
[ -f "$F" ] && [ -n "$G" ] || { echo "widen_kit_guard: usage <build_txfix.sh> <glob>"; exit 2; }
esc=$(printf '%s' "$G" | sed 's/[*]/\\*/g')
if ! grep -q "^  jupiter_byte_txfix\*_build[^)]*$esc[^)]*) ;;" "$F"; then
  sed -i "s|^\(  jupiter_byte_txfix\*_build[^)]*\)) ;;|\1\|$G) ;;|" "$F"
fi
grep -q "^  jupiter_byte_txfix\*_build[^)]*$esc[^)]*) ;;" "$F"
