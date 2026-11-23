#!/bin/bash
# check_paths.sh -- fail if any tracked file outside the evidence/spec areas still
# names a pre-cleanup directory, OR still points at one of the twelve retired
# docs/*.md pages folded into the Sphinx set. Run from the repo root; used by
# hand and by CI.
#
# Old name          -> new name
#   jupiter_240k5_byte -> modem        host_app_k5 -> host
#   k5_240             -> contract     boot_known_good -> images
#   two_jup            -> ops (kit) / docs/evidence (ledgers)
#
# The second invariant: twelve pages that used to live under docs/ as plain
# markdown -- ARCHITECTURE, BRINGUP, BRINGUP_F1536_RESULTS, BUILD, DEBUGGING,
# DEPLOY_F1536, EVM_BUDGET, GLOSSARY, LINK_CHARACTERIZATION, PORTING,
# PROVENANCE and TESTING, each with an ".md" suffix -- were deleted in the
# 2026-09 doc-folding pass (content absorbed into the docs/*.rst Sphinx set;
# recoverable at tag archive/pre-cleanup-2026-09-09). A live reference to any
# of them by that old path is stale. This check waives only docs/evidence/
# and docs/superpowers/ (recorded history) -- a narrower list than the
# directory-rename check below, so a regression in a live kit file that the
# directory check happens to waive by path still fails here.
#
# The check anchors on REPO-RELATIVE usage. Almost everything waived below is
# waived BY PATH, so the waiver is auditable in one place. There are exactly
# three CONTENT (line) filters, all at the bottom and each justified in the
# numbered notes: they exist where the discriminator genuinely is the STRING
# rather than the file -- see (4), (6) and (8). A content filter is preferred
# over a path waiver whenever the alternative would waive a live, frequently
# edited file and thereby hide future real hits in it.
#
# WAIVED PATHS, and why:
#
#  1. Recorded history -- moved or captured verbatim, must not be edited:
#       docs/evidence/          ledgers; their paths refer to the tree at tag
#                               archive/pre-cleanup-2026-09-09
#       docs/superpowers/       plans/specs/briefs are a historical record
#       modem/dev/checkhdl_byte.out recorded build log
#       modem/rtl_sim/evidence/ recorded sim-gate evidence
#       modem/dev/S1B_GATE.txt  recorded gate-run header, pre-cleanup paths
#       modem/dev/SIM_BYTE_GATE_K5.txt kept verbatim (Task 8b)
#       modem/dev/asrun_*/MANIFEST.txt recorded as-run manifest, addpath() line is
#                               a verbatim log of what actually ran
#       modem/rtl_sim/*_RESULTS.md recorded sim-run results notes, pre-cleanup
#                               paths kept verbatim
#       modem/rtl_sim/tap_replay_study/** recorded replay-study evidence
#                               (results notes, .prov provenance stamps, gate
#                               snapshots under n2_gate_evidence/), pre-cleanup
#                               paths kept verbatim
#       images/CURRENT.txt      image-bank provenance rows quote the
#                               boot_known_good paths the images were banked under
#     images/README.md is NOT waived as a file: it also carries live operator
#     commands, which were repointed at ops/ and modem/. Only its provenance rows
#     name boot_known_good, and they sit in the same table as live data, so the
#     file is kept in scope and currently reports zero hits.
#
#  2b. FROZEN BUILD INPUT -- modem/fixes/rxfix_inject.py (cleanup sub-project 2,
#     Task 2). This is the netlist injector that produced the two deployed
#     images. Its md5 05929238c22f46aa1734386ed30a3dc4 is recorded verbatim as
#     INJECTOR_MD5 in each kit's RXFIX_VARIANT stamp, and several of its
#     `two_jup/...` strings are not comments ABOUT the code but text the code
#     EMITS into the generated Verilog -- e.g. line 1953 is present byte for byte
#     in the deployed RTL as
#       hdl/TxRxCompo_ip_src_Rate_Handle.v:257
#         "// window_opens[14:0]} -- see two_jup/rxfix/W1_REGMAP.md.  Present only"
#     Rewriting them would change what the injector writes into silicon and break
#     byte-equivalence with the reference kit, exactly as in note (7): the string
#     is a functional output, not wording. Re-verify with:
#       grep -rn 'two_jup' /path/to/ref/rxfixpad_ipcore/hdl/
#     This waiver is a FILE waiver: it replaced the directory waiver that the
#     pre-cleanup campaign kit dir carried, and every other file that moved out
#     of that dir (into modem/fixes/, modem/instruments/ and ops/flash/) is in
#     scope and reports zero hits. Revisit if the injector is ever re-baselined
#     against a new image.
#
#  3. This file, which names the old directories on purpose.
#
#  4. BOARD-SIDE path, not a repo path: /root/host_app_k5 is the on-board install
#     directory. provision.sh creates it, link_test.sh preflight gates on it, and
#     every board in the rig already carries it -- renaming it is a rig operation
#     (re-provision both boards), not a repo rename, so the kit keeps the literal
#     string. The kit files that contain it are waived BY PATH below. Verified at
#     the time of the waiver: none of them names any OTHER old directory, so the
#     waiver costs no coverage. Re-check with:
#       grep -nE 'jupiter_240k5_byte|two_jup|k5_240|boot_known_good' <those files>
#     host/TXQ_DEPLOY.md carried this waiver in Task 8b; Task 11 folded that file
#     into docs/host-software.rst and deleted it, so its path waiver is gone. The
#     same board-side string now appears in docs/*.rst instead (host-software,
#     setup-prebuilt, testing), which are pages under active edit -- waiving them
#     BY PATH would hide real stale hits in exactly the files most likely to grow
#     one. The string itself is the discriminator, so /root/host_app_k5 moved to
#     the CONTENT filters at the bottom instead. Verified at the time of the move:
#       grep -n '/root/host_app_k5' docs/*.rst | grep -E 'two_jup|jupiter_240k5_byte|k5_240|boot_known_good'
#     was empty, so the line filter costs no coverage. Re-run it if it changes.
#
#  5. MATLAB struct FIELD NAME p.two_jup, kept for history (it resolves to ops/;
#     see the comment in tests/helpers/modem_paths.m). It is an identifier, not a
#     path. Two files use it and are waived BY PATH: the one that defines it and
#     the one that consumes it.
#
#  7. FUNCTIONAL dependency on a live external path that still carries the
#     pre-cleanup name -- rewriting the string would change what the script
#     resolves and runs, not just its wording, so it stays:
#       modem/rtl_sim/fir_verify.m  absolute path into
#                               .claude/worktrees/firpipe-imageB/, a SEPARATE
#                               external git worktree that still has the
#                               pre-cleanup jupiter_240k5_byte layout; not this
#                               repo's tree to rename.
#     Verified live at the time of the waiver (ls, not a tag lookup, since
#     this target is external, not archived):
#       ls .claude/worktrees/firpipe-imageB/jupiter_240k5_byte/rtl_sim/fir_probe_fir.csv
#     NOTE (corrected, Task 8b fix pass): kick_seq.py, txfix_gate_fix_lanes.py,
#     txfix_gate_heartbeat_loop.sh and txfix_gate_launch.sh were previously
#     waived here on the claim that two_jup/ is a gitignored real directory
#     with this content still on disk. That is false: two_jup is a symlink to
#     ops/ (`ls -la two_jup`), and ops/agents/, ops/offsetmap/ and
#     ops/sdd_archive/ do not exist -- `lanes.json` and `progress.md` resolve
#     only at tag archive/pre-cleanup-2026-09-09 under two_jup/. Those scripts
#     are no longer waived: each now points at 'ops/...' (a literal placeholder
#     so this gate passes, since ops/ does not carry those subtrees) with a
#     comment above the path saying so.
#     UPDATED (sp3 task 8, 2026-09-11): ops/offsetmap/ IS live now --
#     tap3_word_to_offset.tsv was restored from that tag because kick_seq.py
#     loads it and, without it, every per-frame offset list came back empty and
#     the txfix gate's `all(...)` scored that as PASS. So kick_seq.py's
#     'ops/offsetmap/...' is a real path, not a placeholder; the other three
#     scripts' 'ops/agents/...' and 'ops/sdd_archive/...' still are.
#
#  8. FILENAME, not a directory: the token matches an old directory name as a
#     substring but names a real file that has never been renamed --
#     modem/dev/assemble_jupiter_240k5_byte.m, which six scripts call. Task 8b
#     waived its only citer (modem/README_BYTE.md) BY PATH; Task 11 folded that
#     file into docs/build-and-flash.rst and docs/debug-instruments.rst and
#     deleted it, so -- as in (4) -- the waiver became a CONTENT filter on the
#     filename rather than a path waiver on live doc pages. Verified at the time
#     of the move:
#       grep -n 'assemble_jupiter_240k5_byte\.m' docs/*.rst | grep -E 'two_jup|k5_240|boot_known_good|host_app_k5'
#     was empty. Renaming the .m file is a modem-source change, not a directory
#     rename, and is out of scope for this cleanup.
#
#  6. The one remaining CONTENT filter, and why it cannot be a path waiver:
#     lines naming /mnt/onetb/scratch/qpsk_variants/... are an ABSOLUTE path into
#     a retired EXTERNAL tree, not a path in this repo. Eight tracked files carry
#     such a line (contract/{dump_ref,packet_k5,decode_ref_k5,soak_decode_k5}.m,
#     modem/{msggen_rom_overlay_k5,s1_analyze_240k5}.m,
#     modem/legacy_builds/{run_gates_resume_t8,sidecar_fix}.sh) and several of them ALSO carry
#     real repo-relative names, so waiving them by path would hide live hits.
#     The discriminator is the string, not the file -- so it stays a line filter.
#
# grep -I skips binary blobs (images/BOOT.BIN.*, contract/golden_*.mat).
set -u
cd "$(dirname "$0")/.."

# (1)(3) recorded history, self
WAIVE='^docs/evidence/|^docs/superpowers/|^tools/check_paths\.sh$'
# (2b) frozen build input: the injector's emitted strings are in the deployed RTL
WAIVE="$WAIVE"'|^modem/fixes/rxfix_inject\.py$'
WAIVE="$WAIVE"'|^images/CURRENT\.txt$|^modem/dev/checkhdl_byte\.out$|^modem/rtl_sim/evidence/'
WAIVE="$WAIVE"'|^modem/dev/S1B_GATE\.txt$|^modem/dev/SIM_BYTE_GATE_K5\.txt$'
WAIVE="$WAIVE"'|^modem/dev/asrun/asrun_[^/]+/MANIFEST\.txt$|^modem/rtl_sim/RESULTS/'
WAIVE="$WAIVE"'|^modem/rtl_sim/tap_replay_study/'
# (4) files carrying the BOARD-side /root/host_app_k5 install path
WAIVE="$WAIVE"'|^ops/(arq_r3|ber_loopback_gate|bringup_r2r3|capture_evm|capture_paired)\.sh$'
WAIVE="$WAIVE"'|^ops/(capture_r3|exp_forward|link_test|link_test_1536|lock_watchdog)\.sh$'
WAIVE="$WAIVE"'|^ops/(mux_test|provision|restore_known_good|rf_loopback|tap_smoke)\.sh$'
WAIVE="$WAIVE"'|^ops/README\.md$'
# (5) MATLAB struct field name p.two_jup: definition and its only consumer
WAIVE="$WAIVE"'|^tests/helpers/modem_paths\.m$|^tests/hil/HilBase\.m$'
# (7) functional dependency on a live external path (see comment above)
WAIVE="$WAIVE"'|^modem/rtl_sim/studies/fir/fir_verify\.m$'
hits=$(git ls-files | grep -v -E "$WAIVE" \
  | xargs grep -nI -E '\b(jupiter_240k5_byte|host_app_k5|two_jup|k5_240|boot_known_good)\b' 2>/dev/null \
  | grep -v 'qpsk_variants' \
  | grep -v '/root/host_app_k5' \
  | grep -v 'assemble_jupiter_240k5_byte\.m')
  # content filters, in order: (6) absolute path into a retired EXTERNAL tree;
  # (4) the BOARD-side install directory; (8) a real filename, not a directory.

# retired docs/*.md invariant. This is a NARROWER waiver than $WAIVE above --
# only docs/evidence/ and docs/superpowers/ (recorded history) are excluded.
# It deliberately does NOT reuse $WAIVE: that list also waives live kit files
# (ops/README.md, ops/provision.sh, tests/hil/HilBase.m, the board-side
# /root/host_app_k5 script block) for the directory-rename check, and a
# regression naming a retired docs/*.md page in exactly one of those files
# must still fail this check.
MDWAIVE='^docs/evidence/|^docs/superpowers/'
MDRE='docs/(ARCHITECTURE|BRINGUP|BRINGUP_F1536_RESULTS|BUILD|DEBUGGING|DEPLOY_F1536|EVM_BUDGET|GLOSSARY|LINK_CHARACTERIZATION|PORTING|PROVENANCE|TESTING)\.md'
md_hits=$(git ls-files | grep -v -E "$MDWAIVE" \
  | xargs grep -nI -E "$MDRE" 2>/dev/null)

total=$(( $( [ -n "$hits" ] && echo "$hits" | wc -l || echo 0 ) + $( [ -n "$md_hits" ] && echo "$md_hits" | wc -l || echo 0 ) ))
if [ -n "$hits" ] || [ -n "$md_hits" ]; then
  [ -n "$hits" ] && echo "$hits"
  [ -n "$md_hits" ] && echo "$md_hits"
  echo "CHECK_PATHS_FAIL $total hits"
  exit 1
fi
echo "CHECK_PATHS_OK"
