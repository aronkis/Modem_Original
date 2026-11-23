#!/usr/bin/env python3
"""apply_fixes.py -- manifest-driven driver for the netlist fix chain.

Reads fixes.toml and runs txfix_kit.sh -> seqbist_kit.sh -> rxfix_kit.sh
(in that order) for a given role, then stamps the resulting kit with
FIXES_MANIFEST. See fixes.toml and task-3-brief.md for the schema.
"""
import argparse
import hashlib
import os
import shlex
import shutil
import subprocess
import sys
import tomllib
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent


class ManifestError(ValueError):
    pass


def load_manifest(path):
    with open(path, "rb") as f:
        m = tomllib.load(f)
    schema = m.get("meta", {}).get("schema")
    if schema != 1:
        raise ManifestError(f"unsupported meta.schema: {schema!r}")
    fixes = m.get("fixes", {})
    for role, rd in m.get("roles", {}).items():
        for v in rd.get("variants", []):
            if v not in fixes:
                raise ManifestError(f"role {role}: variant '{v}' not found in [fixes]")
    for name, fd in fixes.items():
        for req in fd.get("requires", []):
            if req not in fixes:
                raise ManifestError(f"fix '{name}': requires '{req}' not found in [fixes]")
        for con in fd.get("conflicts", []):
            if con not in fixes:
                raise ManifestError(f"fix '{name}': conflicts '{con}' not found in [fixes]")
    return m


def role_variants(manifest, role):
    role_d = manifest["roles"][role]
    variants = list(role_d["variants"])
    fixes = manifest["fixes"]
    orders = [fixes[v]["order"] for v in variants]
    for i in range(1, len(variants)):
        if orders[i] < orders[i - 1]:
            raise ManifestError(
                f"role {role}: '{variants[i]}' (order {orders[i]}) is out of order, "
                f"appears after '{variants[i - 1]}' (order {orders[i - 1]})"
            )
    for i, v in enumerate(variants):
        f = fixes[v]
        for req in f.get("requires", []):
            if req not in variants[:i]:
                raise ManifestError(
                    f"role {role}: '{v}' requires '{req}' which does not appear earlier in {variants}"
                )
        for con in f.get("conflicts", []):
            if con in variants:
                raise ManifestError(
                    f"role {role}: '{v}' conflicts with '{con}' which is also in {variants}"
                )
    return variants


def manifest_sha(path):
    data = Path(path).read_bytes()
    return hashlib.sha256(data).hexdigest()[:16]


def plan(manifest, role, base, work, instruments=None, kit_tag=""):
    """List of (cwd, argv, env) triples for the chain, in order.

    `kit_tag` is appended to the FINAL (rxfix) kit's directory name:
    jupiter_byte_rxfix<suffix><tag>_build.  build_txfix.sh derives its remote
    build dir (~/qpsk-builds/<kit>) from that basename, so a tag is what keeps a
    rebuild from overwriting the as-built reference kit of the same suffix, both
    locally and on the Vivado host.  The tag must keep the name matching
    build_txfix.sh's kit guard `jupiter_byte_rxfix*_build`.
    """
    instruments = instruments or []
    role_d = manifest["roles"][role]
    variants = role_variants(manifest, role)
    chain = manifest["chain"]
    base = Path(base)
    work = Path(work)
    steps = []

    txfix_variant = chain["txfix"]["variant"]
    txfix_kit = work / f"jupiter_byte_txfix{txfix_variant}_build"
    steps.append((str(ROOT), [str(HERE / "txfix_kit.sh"), txfix_variant, str(base), str(work)], {}))

    seqbist_lineage = chain["seqbist"]["lineage"]
    seqbist_kit = work / "jupiter_byte_seqbist_build"
    steps.append((str(ROOT), [str(HERE / "seqbist_kit.sh"), seqbist_lineage, str(txfix_kit), str(work)], {}))

    rxfix_lineage = chain["rxfix"]["lineage"]
    kit_suffix = role_d["kit_suffix"]
    rxfix_kit = work / f"jupiter_byte_rxfix{kit_suffix}{kit_tag}_build"
    rxfix_env = {"RXFIX_VARIANTS": " ".join(variants)}
    if kit_tag:
        rxfix_env["RXFIX_KIT_TAG"] = kit_tag
    steps.append((str(ROOT), [str(HERE / "rxfix_kit.sh"), rxfix_lineage, str(seqbist_kit), str(work)], rxfix_env))

    for name in instruments:
        inject_path = ROOT / "modem" / "instruments" / name / f"{name}_inject.py"
        if not inject_path.is_file():
            raise ManifestError(f"APPLY_FIXES_NO_INSTRUMENT {name}")
        steps.append((str(ROOT), ["python3", str(inject_path.relative_to(ROOT)), str(rxfix_kit)], {}))

    return steps


def _print_plan(steps):
    for _cwd, argv, env in steps:
        prefix = " ".join(f"{k}={shlex.quote(v)}" for k, v in env.items())
        line = (prefix + " " if prefix else "") + shlex.join(argv)
        print(line)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--role", required=True)
    ap.add_argument("--base", required=True)
    ap.add_argument("--work", required=True)
    ap.add_argument("--plan", action="store_true")
    ap.add_argument("--instrument", action="append", default=[])
    ap.add_argument(
        "--kit-tag",
        default="",
        help="suffix appended to the final kit dir name "
        "(jupiter_byte_rxfix<suffix><TAG>_build), so a rebuild does not collide "
        "with the as-built reference kit locally or in ~/qpsk-builds on the "
        "Vivado host",
    )
    args = ap.parse_args(argv)
    if args.kit_tag and not args.kit_tag.isalnum():
        print(f"APPLY_FIXES_BAD_KIT_TAG {args.kit_tag!r} must be alphanumeric")
        return 2

    manifest = load_manifest(args.manifest)
    variants = role_variants(manifest, args.role)
    base_tree_name = manifest["meta"]["base_tree"]
    work = Path(args.work)
    chain_base = work / base_tree_name

    steps = plan(manifest, args.role, chain_base, work, args.instrument, args.kit_tag)

    kit_name = f"jupiter_byte_rxfix{manifest['roles'][args.role]['kit_suffix']}{args.kit_tag}_build"

    if args.plan:
        _print_plan(steps)
        # rxfix_kit.sh derives the kit dir from its DEST_PARENT arg + RXFIX_KIT_TAG,
        # so the final path is not visible in the argv above. Print it explicitly:
        # it is the name that becomes ~/qpsk-builds/<kit> on the Vivado host.
        print(f"APPLY_FIXES_PLAN_KIT {work / kit_name}")
        return 0

    base = Path(args.base)
    base_manifest_path = base.parent / "BASE_MANIFEST.txt"
    expected = manifest["meta"]["base_manifest_sha256"]
    if not base_manifest_path.exists():
        print(f"APPLY_FIXES_BASE_MISMATCH missing={base_manifest_path}")
        return 1
    actual = hashlib.sha256(base_manifest_path.read_bytes()).hexdigest()
    if actual != expected:
        print(f"APPLY_FIXES_BASE_MISMATCH expected={expected} actual={actual}")
        return 1

    work.mkdir(parents=True, exist_ok=True)
    subprocess.run(["rsync", "-a", f"{base}/", f"{chain_base}/"], check=True)
    gen_dir = chain_base / "hdl_prj_jupiter_composite" / "vivado_ip_prj" / "vivado_prj.gen"
    if not gen_dir.is_dir():
        print(f"APPLY_FIXES_BASE_COPY_MISSING expected={gen_dir}")
        return 1
    shutil.rmtree(gen_dir)
    print("APPLY_FIXES_BASE_COPY pruned=vivado_prj.gen")

    for cwd, cmdargv, env in steps:
        run_env = dict(os.environ)
        run_env.update(env)
        subprocess.run(cmdargv, cwd=cwd, env=run_env, check=True)

    role_d = manifest["roles"][args.role]
    kit = work / kit_name
    if not kit.is_dir():
        print(f"APPLY_FIXES_KIT_MISSING expected={kit} work_contents={sorted(p.name for p in work.iterdir())}")
        return 1
    sha = manifest_sha(args.manifest)
    git_head = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=str(ROOT), capture_output=True, text=True, check=True
    ).stdout.strip()
    (kit / "FIXES_MANIFEST").write_text(
        f"manifest_sha={sha}\nrole={args.role}\nvariants={' '.join(variants)}\n"
        f"kit_tag={args.kit_tag}\ngit={git_head}\n"
    )
    print(
        f"APPLY_FIXES_DONE kit={kit} variants={' '.join(variants)} "
        f"kit_tag={args.kit_tag} manifest_sha={sha}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
