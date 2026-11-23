import pathlib, subprocess

ROOT = pathlib.Path(__file__).resolve().parents[2]

# Basenames of scripts that modem/build_image.sh, the hdl-regen script (formerly
# modem/fixes/build_base_tree.sh, renamed by sp3 Task 11 to modem/build_hdl.sh)
# or the gates invoke DIRECTLY (as `"$SOME_PATH/name.sh" ...`, not `bash name.sh`),
# so a dropped exec bit (100755 -> 100644, as commits 81ddcc6f/df674056 did) is a
# silent "Permission denied" at run time rather than a syntax error.
#
# Some of these have been renamed by other in-flight cleanup tasks (the sp3 dir
# reshuffle). We resolve by basename against the CURRENT index rather than a
# fixed path, and accept either the old or new name where a rename is known, so
# this test tracks the live tree instead of one snapshot of it. build_base_tree.sh
# / build_hdl.sh is handled separately below (see test_build_hdl_is_executable).
#
# The set was widened after the whole-branch review: the survey
#   grep -rE '\$(RTL|D|FX|ROOT/modem)[^ ]*\.sh' modem/build_image.sh \
#        modem/build_hdl.sh modem/gates/run_gates.sh ops/*.sh
# turned up direct invocations this test was blind to -- modem/rtl_sim/
# tree_marker.sh (build_image.sh:285) and, under ops/, anyssh.sh, askpass.sh
# (handed to ssh as SSH_ASKPASS, which execs it), capture_r3.sh and
# bringup_r2r3.sh. modem/rtl_sim/build_iq_instruments.sh is here because it is
# a directly-run entry point that HAS already lost its exec bit once (restored
# by 1743c521), which is exactly the regression this file exists to catch.
REQUIRED = {
    "make_sro_trees.sh": ["make_sro_trees.sh"],
    "build_sro_pad.sh": ["build_sro_pad.sh"],
    "run_gates.sh": ["run_gates.sh"],
    "rxfifo_inject.sh": ["rxfifo_inject.sh"],
    "seqbist_kit.sh": ["seqbist_kit.sh", "apply_seqbist.sh"],
    "txfix_kit.sh": ["txfix_kit.sh"],
    "rxfix_kit.sh": ["rxfix_kit.sh"],
    "base_tree.sh": ["base_tree.sh"],
    "txfix_gate_launch.sh": ["txfix_gate_launch.sh"],
    "tree_marker.sh": ["tree_marker.sh"],
    "build_iq_instruments.sh": ["build_iq_instruments.sh"],
    # ops/ entry points invoked as "$D/name.sh" (or handed to ssh to exec)
    "anyssh.sh": ["anyssh.sh"],
    "askpass.sh": ["askpass.sh"],
    "capture_r3.sh": ["capture_r3.sh"],
    "bringup_r2r3.sh": ["bringup_r2r3.sh"],
}

BUILD_HDL_ALIASES = ["build_base_tree.sh", "build_hdl.sh"]


def _indexed_sh_under_modem(dirs=("modem", "ops")):
    """(path, mode) for every *.sh git has indexed under the given directories,
    from `git ls-files -s` -- this is the index's recorded mode, independent of
    whatever the working-tree permission bits happen to be on this checkout.

    ops/ was added alongside modem/ when REQUIRED grew its ops entry points; the
    build_sro_*/build_hdl helpers below still scope themselves to modem/ by
    passing dirs=("modem",)."""
    out = subprocess.run(
        ["git", "ls-files", "-s", "--", *dirs],
        cwd=ROOT, capture_output=True, text=True, check=True,
    ).stdout
    rows = []
    for line in out.splitlines():
        mode, _rest = line.split(" ", 1)
        path = line.split("\t", 1)[1]
        if path.endswith(".sh"):
            rows.append((path, mode))
    return rows


def _by_basename(rows):
    by_basename = {}
    for path, mode in rows:
        by_basename.setdefault(pathlib.Path(path).name, []).append((path, mode))
    return by_basename


def _resolve(by_basename, aliases):
    """Regular-file (mode != 120000) matches for any of the given basenames.
    A rename in flight can leave a plain symlink sitting at the old path
    while the real file lands at the new one; a symlink carries no
    meaningful exec bit of its own, so it is excluded here rather than
    counted as either a pass or a failure."""
    matches = []
    for alias in aliases:
        matches.extend(by_basename.get(alias, []))
    return [(p, m) for (p, m) in matches if m != "120000"], matches


def test_required_direct_invoked_scripts_are_executable_in_the_index():
    by_basename = _by_basename(_indexed_sh_under_modem())

    missing = []
    not_executable = []
    for canonical, aliases in REQUIRED.items():
        regular, matches = _resolve(by_basename, aliases)
        if not regular:
            if matches:
                continue  # only a symlink found; an in-flight rename, not a failure
            missing.append(canonical)
            continue
        for path, mode in regular:
            if mode != "100755":
                not_executable.append((canonical, path, mode))

    assert not missing, (
        f"required script(s) not found under modem/ (checked basenames "
        f"{REQUIRED}): {missing}"
    )
    assert not not_executable, (
        "script(s) invoked directly (not via `bash foo.sh`) must be mode "
        f"100755 in the git index -- found: {not_executable}"
    )


def test_build_sro_star_scripts_are_executable_in_the_index():
    """build_sro_*.sh (build_sro_pad.sh, build_sro_bs.sh, build_sro_w1.sh, ...)
    are run directly by the gates; catch a dropped +x on any of them, not just
    the one (build_sro_pad.sh) named explicitly in REQUIRED."""
    rows = _indexed_sh_under_modem(dirs=("modem",))
    star = [(p, m) for (p, m) in rows if pathlib.Path(p).name.startswith("build_sro_")]
    assert star, "expected at least one build_sro_*.sh under modem/"
    not_executable = [(p, m) for (p, m) in star if m != "100755"]
    assert not not_executable, (
        f"build_sro_*.sh script(s) not mode 100755 in the git index: {not_executable}"
    )


def test_build_hdl_is_executable():
    """The hdl-regen script (modem/fixes/build_base_tree.sh, renamed by sp3
    Task 11 to modem/build_hdl.sh) is invoked directly by build_image.sh.

    This used to be XFAIL: at the time it was written Task 11's rename was
    staged but not committed and the committed mode was still 100644. Task 11
    landed, `git ls-files -s modem/build_hdl.sh` reports 100755, and
    modem/fixes/build_base_tree.sh is now a regular wrapper script (the repo
    carries no symlinks since 2026-09-17), so both aliases must be 100755.
    The marker is gone: a dropped exec bit here must fail, not xpass.
    """
    by_basename = _by_basename(_indexed_sh_under_modem(dirs=("modem",)))
    regular, matches = _resolve(by_basename, BUILD_HDL_ALIASES)
    assert regular, (
        "build_base_tree.sh/build_hdl.sh resolves to no regular file under "
        f"modem/ (only {matches})"
    )
    not_executable = [(p, m) for (p, m) in regular if m != "100755"]
    assert not not_executable, (
        "the hdl-regen script is invoked directly by build_image.sh and must be "
        f"mode 100755 in the git index -- found: {not_executable}"
    )


def test_build_image_invokes_scripts_directly_not_via_bash():
    """Sanity check that the premise holds: build_image.sh really does exec
    these paths directly (`"$X/foo.sh" ...`), which is why a dropped +x bit
    is a silent runtime failure rather than caught by any syntax check."""
    s = (ROOT / "modem/build_image.sh").read_text()
    assert '/build_hdl.sh" ' in s or '/build_base_tree.sh" ' in s
    assert '/make_sro_trees.sh" ' in s
