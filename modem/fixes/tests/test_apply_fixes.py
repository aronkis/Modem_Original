import subprocess, sys, pathlib, tomllib
HERE = pathlib.Path(__file__).resolve().parent
FIXES = HERE.parent
sys.path.insert(0, str(FIXES))
import apply_fixes as af

def test_manifest_loads_and_roles_ordered():
    m = af.load_manifest(FIXES / "fixes.toml")
    assert af.role_variants(m, "A") == ["W1", "R4B", "BS", "PAD"]
    assert af.role_variants(m, "B") == ["W1", "R4D", "R1"]

def test_role_order_respects_requires_and_conflicts():
    m = af.load_manifest(FIXES / "fixes.toml")
    bad = dict(m); bad["roles"] = {"X": {"variants": ["PAD", "W1"], "kit_suffix": "x", "board": "148"}}
    try:
        af.role_variants(bad, "X"); assert False, "PAD before BS/W1 must fail"
    except af.ManifestError as e:
        assert "PAD" in str(e)
    bad["roles"] = {"Y": {"variants": ["W1", "R4B", "R4D"], "kit_suffix": "y", "board": "148"}}
    try:
        af.role_variants(bad, "Y"); assert False
    except af.ManifestError as e:
        assert "conflicts" in str(e)

def test_plan_prints_chain_without_touching_disk(tmp_path):
    out = subprocess.run([sys.executable, str(FIXES / "apply_fixes.py"), "--manifest", str(FIXES / "fixes.toml"),
                          "--role", "A", "--base", str(tmp_path / "nobase"), "--work", str(tmp_path / "w"), "--plan"],
                         capture_output=True, text=True)
    assert out.returncode == 0, out.stderr
    lines = out.stdout.splitlines()
    assert any("txfix_kit.sh F3" in l for l in lines)
    assert any("seqbist_kit.sh 148" in l for l in lines)
    assert any("RXFIX_VARIANTS='W1 R4B BS PAD'" in l and "rxfix_kit.sh 148" in l for l in lines)
    assert not (tmp_path / "w").exists()

def test_plan_kit_tag_names_the_final_kit(tmp_path):
    """--kit-tag renames ONLY the final rxfix kit, and the tagged name must still
    match build_txfix.sh's `jupiter_byte_rxfix*_build` guard -- that basename is
    what becomes ~/qpsk-builds/<kit> on the Vivado host."""
    out = subprocess.run([sys.executable, str(FIXES / "apply_fixes.py"), "--manifest", str(FIXES / "fixes.toml"),
                          "--role", "A", "--base", str(tmp_path / "nobase"), "--work", str(tmp_path / "w"),
                          "--plan", "--kit-tag", "sp2"],
                         capture_output=True, text=True)
    assert out.returncode == 0, out.stderr
    lines = out.stdout.splitlines()
    rx = [l for l in lines if "rxfix_kit.sh" in l]
    assert len(rx) == 1, lines
    assert "RXFIX_KIT_TAG=sp2" in rx[0], rx[0]
    assert f"APPLY_FIXES_PLAN_KIT {tmp_path / 'w' / 'jupiter_byte_rxfixpadsp2_build'}" in lines, lines
    # the intermediate kits are NOT tagged: they are inputs, never built remotely
    assert any("jupiter_byte_txfixF3_build" in l and "seqbist_kit.sh" in l for l in lines), lines
    # and without the flag the name is untagged
    plain = subprocess.run([sys.executable, str(FIXES / "apply_fixes.py"), "--manifest", str(FIXES / "fixes.toml"),
                            "--role", "B", "--base", str(tmp_path / "nobase"), "--work", str(tmp_path / "w"), "--plan"],
                           capture_output=True, text=True)
    assert f"APPLY_FIXES_PLAN_KIT {tmp_path / 'w' / 'jupiter_byte_rxfixr4dr1_build'}" in plain.stdout.splitlines()
    assert "RXFIX_KIT_TAG" not in plain.stdout


def test_plan_kit_tag_still_matches_the_build_txfix_guard():
    import fnmatch
    for suffix in ("pad", "r4dr1"):
        name = f"jupiter_byte_rxfix{suffix}sp2_build"
        assert fnmatch.fnmatch(name, "jupiter_byte_rxfix*_build"), name
        # and the guard build_txfix.sh actually carries after rxfix_kit.sh widens it
        assert fnmatch.fnmatch(name, "jupiter_byte_txfix*_build") is False


def test_manifest_sha_is_stable():
    m1 = af.manifest_sha(FIXES / "fixes.toml"); m2 = af.manifest_sha(FIXES / "fixes.toml")
    assert m1 == m2 and len(m1) == 16

def test_instrument_step_path():
    m = af.load_manifest(FIXES / "fixes.toml")
    steps = af.plan(m, "A", "/x", "/y", instruments=["txcap"])
    cwd, argv, env = steps[-1]
    assert argv[0] == "python3"
    assert argv[1] == "modem/instruments/txcap/txcap_inject.py"
    assert (af.ROOT / argv[1]).is_file()
    try:
        af.plan(m, "A", "/x", "/y", instruments=["bogus_nonexistent"])
        assert False, "missing instrument must raise ManifestError"
    except af.ManifestError as e:
        assert "APPLY_FIXES_NO_INSTRUMENT bogus_nonexistent" in str(e)

def test_witness_addresses_unique_per_role():
    m = af.load_manifest(FIXES / "fixes.toml")
    for role in ("A", "B"):
        addrs = [w["addr"] for v in af.role_variants(m, role) for w in m["fixes"][v].get("witness", [])]
        assert len(addrs) == len(set(addrs)), role


def test_every_planned_executable_exists_and_is_executable(tmp_path):
    """Every argv[0] the plan emits must be a real, executable file.

    This is the assertion that was missing when commit 7e269357 renamed
    modem/fixes/seqbist_kit.sh -> modem/instruments/seqbist/apply_seqbist.sh
    without leaving a compatibility symlink: fixes.toml still names
    `seqbist_kit.sh` (and its sha is stamped into every sp2 kit, so it may not
    be edited), apply_fixes.py still builds `HERE / "seqbist_kit.sh"`, and the
    old tests only asserted the STRING appeared in --plan's output -- so the
    shipped sp2 rebuild chain died with FileNotFoundError at step 2 and no test
    saw it. Checking existence + X_OK on the structured plan catches the whole
    class, for both roles, and for the `python3 <injector>` instrument steps.
    """
    import os
    m = af.load_manifest(FIXES / "fixes.toml")
    for role in ("A", "B"):
        steps = af.plan(m, role, str(tmp_path / "nobase"), str(tmp_path / "w"),
                        instruments=["txcap"], kit_tag="sp2")
        assert steps, role
        for cwd, argv, _env in steps:
            assert pathlib.Path(cwd).is_dir(), (role, cwd)
            exe = argv[0]
            if exe == "python3":
                # instrument steps: argv[1] is repo-relative, run from ROOT
                script = af.ROOT / argv[1]
                assert script.is_file(), (role, argv)
                continue
            p = pathlib.Path(exe)
            assert p.is_file(), f"{role}: planned argv[0] does not exist: {exe}"
            assert os.access(p, os.X_OK), f"{role}: planned argv[0] is not executable: {exe}"
    assert not (tmp_path / "w").exists()


def test_plan_subprocess_runs_for_both_roles_against_a_fake_base(tmp_path):
    """The same check through the real CLI (`--plan` against a base dir that
    does not exist): both roles print a chain whose every command is present."""
    import os, shlex
    for role, suffix in (("A", "pad"), ("B", "r4dr1")):
        out = subprocess.run(
            [sys.executable, str(FIXES / "apply_fixes.py"), "--manifest", str(FIXES / "fixes.toml"),
             "--role", role, "--base", str(tmp_path / "nobase"), "--work", str(tmp_path / "w"),
             "--kit-tag", "sp2", "--plan"],
            capture_output=True, text=True)
        assert out.returncode == 0, out.stderr
        lines = [l for l in out.stdout.splitlines() if not l.startswith("APPLY_FIXES_PLAN_KIT")]
        assert lines, role
        for line in lines:
            toks = shlex.split(line)
            argv0 = next(t for t in toks if "=" not in t.split("/")[-1] or t.startswith("/"))
            if argv0 == "python3":
                continue
            assert os.path.isfile(argv0) and os.access(argv0, os.X_OK), f"{role}: {argv0}"
        assert f"APPLY_FIXES_PLAN_KIT {tmp_path / 'w' / f'jupiter_byte_rxfix{suffix}sp2_build'}" \
            in out.stdout.splitlines()
