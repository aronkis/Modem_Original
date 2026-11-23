#!/bin/bash
# test_build_image_remotebase.sh -- REMOTE_BASE must reach the remote tree AND
# every fetch path, or a build silently splits across two filesystems.
#
# Why this test exists: hdl-dev-2's / has ~45 GB free and holds the AS-BUILT
# reference kits, while its second disk /mnt/disk2/scratch has 136 GB.  Task 10b
# moves the role-B build there with `build_image.sh --remote-base DIR`, which
# only works if BOTH halves land:
#   1. txfix_build.sh.tmpl must build REMOTE_DIR *and* REMOTE_DIR_EXPANDED from
#      it.  The two are not interchangeable: REMOTE_DIR is expanded by the REMOTE
#      shell (rsync destination / inside a double-quoted ssh), REMOTE_DIR_EXPANDED
#      is handed to `systemd-run --working-directory=`, which expands NOTHING.
#      A `~` that reaches --working-directory costs a 2 h build.
#   2. build_image.sh must use the same value for the three fetches (vivado log,
#      boot/BOOT.BIN, impl_1 timing reports).  If it kept the hard-coded
#      "qpsk-builds/<kit>", the build would run on disk2 and the fetch would look
#      on / -- rsync would fail, or worse, find a STALE tree of the same name.
#
# The template is exercised for real (with a stub ssh, so nothing remote is
# touched); build_image.sh is checked by the "no second hard-coded root" invariant.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TMPL="$HERE/../vivado/txfix_build.sh.tmpl"
BI="$HERE/../build_image.sh"
[ -f "$TMPL" ] || { echo "REMOTEBASE_FAIL no txfix_build.sh.tmpl at $TMPL"; exit 1; }
[ -f "$BI" ]   || { echo "REMOTEBASE_FAIL no build_image.sh at $BI"; exit 1; }

fails=0
ok()   { echo "  ok   $1"; }
bad()  { echo "  FAIL $1"; fails=$((fails+1)); }
has()  { # has <name> <needle> <haystack-file>
  if grep -qF -- "$2" "$3"; then ok "$1"; else bad "$1: [$2] not in output:"; sed 's/^/       | /' "$3"; fi
}
hasnt() {
  if grep -qF -- "$2" "$3"; then bad "$1: [$2] MUST NOT be in output"; else ok "$1"; fi
}

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
KITNAME=jupiter_byte_sp3_build
KIT="$T/$KITNAME"
mkdir -p "$KIT" "$T/bin"

# The kit copy as modem/build_hdl.sh step [6] installs it: the template VERBATIM.
# sp3 needs no guard-widening sed -- the template's own case guard accepts
# jupiter_byte_sp3*_build (and refuses any *_build_ref before that).
cp "$TMPL" "$KIT/build_txfix.sh"
chmod +x "$KIT/build_txfix.sh"
echo SP3 > "$KIT/TXFIX_VARIANT"
grep -q 'jupiter_byte_sp3\*_build' "$KIT/build_txfix.sh" \
  || { echo "REMOTEBASE_FAIL the template no longer accepts the sp3 kit name"; exit 1; }

# A *_build_ref kit must be refused OUTRIGHT: those are the AS-BUILT reference
# kits on the Vivado host and this script rsyncs --delete into its kit dir.
REFKIT="$T/jupiter_byte_sp3_build_ref"; mkdir -p "$REFKIT"
cp "$TMPL" "$REFKIT/build_txfix.sh"; echo SP3 > "$REFKIT/TXFIX_VARIANT"
refout=$(bash "$REFKIT/build_txfix.sh" --dry 2>&1); refrc=$?
if [ $refrc = 1 ] && printf '%s' "$refout" | grep -q 'TXFIX_BUILD_REFUSE_REF_KIT'; then
  ok "a *_build_ref kit is refused (TXFIX_BUILD_REFUSE_REF_KIT)"
else
  bad "a *_build_ref kit was NOT refused (rc=$refrc): $refout"
fi

# Stub ssh: the --dry path makes exactly two ssh calls (df, and the active-unit
# list).  Nothing remote is touched by this test.
cat > "$T/bin/ssh" <<'STUB'
#!/bin/sh
case "$*" in
  *df*) echo "/dev/stub 400000000 100000000 300000000 25% /stub" ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$T/bin/ssh"
export PATH="$T/bin:$PATH"

run() { # run <outfile> [REMOTE_BASE]
  local out=$1; shift
  if [ $# -gt 0 ]; then REMOTE_BASE="$1" bash "$KIT/build_txfix.sh" --dry > "$out" 2>&1
  else                  bash "$KIT/build_txfix.sh" --dry > "$out" 2>&1; fi
  echo $?
}

# 1. Absolute REMOTE_BASE -> BOTH forms are that base.  The uppercase quoted
#    REMOTE_DIR='...' is the one actually shipped to the remote in LAUNCH_CMD.
rc=$(run "$T/abs.out" /x)
[ "$rc" = 0 ] && ok "absolute REMOTE_BASE exits 0" || bad "absolute REMOTE_BASE exit $rc"
has  "absolute: LAUNCH_CMD carries REMOTE_DIR='/x/$KITNAME'" "REMOTE_DIR='/x/$KITNAME'" "$T/abs.out"
has  "absolute: dry summary remote_dir=/x/$KITNAME"          "remote_dir=/x/$KITNAME"   "$T/abs.out"
has  "absolute: log path is under /x"  "log would be at: /x/$KITNAME/build_txfix_vivado.log" "$T/abs.out"
hasnt "absolute: no /home/tcollins root leaks through" "/home/tcollins/qpsk-builds/$KITNAME" "$T/abs.out"

# 1b. The real value Task 10b uses.
rc=$(run "$T/disk2.out" /mnt/disk2/scratch/qpsk-builds)
has "disk2: REMOTE_DIR='/mnt/disk2/scratch/qpsk-builds/$KITNAME'" \
    "REMOTE_DIR='/mnt/disk2/scratch/qpsk-builds/$KITNAME'" "$T/disk2.out"

# 2. Unset REMOTE_BASE -> byte-identical to the historical behaviour.
rc=$(run "$T/def.out")
[ "$rc" = 0 ] && ok "default exits 0" || bad "default exit $rc"
has "default: expanded form is /home/tcollins/qpsk-builds/$KITNAME" \
    "REMOTE_DIR='/home/tcollins/qpsk-builds/$KITNAME'" "$T/def.out"
has "default: unexpanded ~ still used for the rsync destination" \
    "the rsync to hdl-dev-2:~/qpsk-builds/$KITNAME is BELOW this gate" "$T/def.out"

# 2b. An EMPTY REMOTE_BASE (build_image.sh exports it unconditionally) must fall
#     back to the default, not become "/$KIT".  This is why the template uses the
#     ${REMOTE_BASE:-...} colon form.
rc=$(run "$T/empty.out" "")
[ "$rc" = 0 ] && ok "empty REMOTE_BASE exits 0 (colon-form fallback)" || bad "empty REMOTE_BASE exit $rc"
has "empty: falls back to the default root" \
    "REMOTE_DIR='/home/tcollins/qpsk-builds/$KITNAME'" "$T/empty.out"

# 3. A relative base is REFUSED, never hand-expanded.
rc=$(run "$T/rel.out" some/where)
[ "$rc" = 1 ] && ok "relative REMOTE_BASE is refused (exit 1)" || bad "relative REMOTE_BASE exit $rc (want 1)"
has "relative: names the defect" "TXFIX_BUILD_BAD_REMOTE_BASE" "$T/rel.out"
# and build_image.sh refuses it before it ever gets there
# NB: capture, don't pipe -- `set -o pipefail` + `grep -q` exiting early makes a
# pipeline report build_image.sh's own exit 2 even when the match succeeded.
bi_rel=$(bash "$BI" --remote-base some/where --dry 2>&1); bi_rc=$?
if [ $bi_rc = 2 ] && printf '%s' "$bi_rel" | grep -q 'must be an absolute path'; then
  ok "build_image.sh --remote-base rejects a relative path"
else
  bad "build_image.sh --remote-base accepted a relative path (rc=$bi_rc)"
fi

# 4. build_image.sh must have NO second hard-coded remote root: exactly one
#    executable (non-comment) line may mention qpsk-builds, and it must be the
#    ${RBASE:-...} fetch root.
code_hits=$(grep -n 'qpsk-builds' "$BI" | grep -v '^[0-9]*: *#' | wc -l)
if [ "$code_hits" = 1 ]; then ok "build_image.sh has exactly one qpsk-builds code line"
else bad "build_image.sh has $code_hits qpsk-builds code lines (want 1):"; grep -n 'qpsk-builds' "$BI" | grep -v '^[0-9]*: *#' | sed 's/^/       | /'; fi
if grep -q 'REMOTE="\${RBASE:-\$RB_DEFAULT}/\$(basename "\$KIT")"' "$BI"; then
  ok "the fetch root is derived from RBASE"
else bad "the fetch root is not derived from RBASE"; fi
# every fetch must hang off that one variable
for f in 'build_txfix_vivado.log' 'boot/BOOT.BIN' 'impl_1/'; do
  if grep -q "HOST:\$REMOTE.*$f\|HOST:\$Z.*$f" "$BI"; then ok "fetch of $f uses \$REMOTE/\$Z"
  else bad "fetch of $f does not use \$REMOTE/\$Z"; fi
done
grep -q 'Z="\$REMOTE/hdl_prj_jupiter_composite/vivado_ip_prj"' "$BI" \
  && ok "\$Z is derived from \$REMOTE" || bad "\$Z is not derived from \$REMOTE"

if [ $fails -eq 0 ]; then echo "REMOTEBASE_OK all checks, 0 failures"; exit 0; fi
echo "REMOTEBASE_FAIL $fails failure(s)"; exit 1
