#!/usr/bin/env python3
"""gen_regmap.py -- generate host/qpsk_fixregs.h and
host/modem_status/ms_regmap_fixes.inc from modem/regmap/regmap.toml.

Single source of truth for the fixctl control bits and W1/STEER/BS witness
word addresses: both host consumers (qpsk_tun/qpsk_capture via qpsk_hw.h, and
modem_status via ms_regmap.c) build against generated output instead of
duplicating offsets by hand. Run with no args to (re)write both files in
place; run with --check to regenerate into a temp dir and diff against the
committed files (exits 1 with a unified diff on mismatch, for CI).

regmap.toml is a register-manifest-only TOML: just `[fixes.*]` `control`/
`witness`/`witness_section` tables, no `[meta]`/`[chain]`/`[roles]` chain-
execution schema (that lives in modem/fixes/fixes.toml, driven by
modem/fixes/apply_fixes.py until Task 15). This module therefore parses
regmap.toml itself instead of importing apply_fixes.

Witness dedup: two fixes may declare the same witness address -- that is not
a conflict, it is the same physical word documented from two fixes; the row
is emitted once and both fix names are recorded in its comment. A
same-address declaration under two DIFFERENT names is an error (ambiguous
which name wins).
"""
import argparse
import difflib
import hashlib
import sys
import tempfile
import tomllib
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent

MANIFEST_PATH = HERE / "regmap.toml"
HEADER_OUT = ROOT / "host" / "qpsk_fixregs.h"
INC_OUT = ROOT / "host" / "modem_status" / "ms_regmap_fixes.inc"

FIXCTL_ADDR = 0x208


class RegmapError(ValueError):
    pass


def manifest_sha(path=MANIFEST_PATH):
    data = Path(path).read_bytes()
    return hashlib.sha256(data).hexdigest()[:16]


def load(path=MANIFEST_PATH):
    with open(path, "rb") as f:
        return tomllib.load(f)


def _collect_controls(manifest):
    """{(reg, bit): name} in first-seen order, across all fixes. A
    (reg, bit) declared twice must agree on name (BS's w1_freeze control is
    declared `shared = true` for exactly this reason)."""
    controls = {}
    for name in sorted(manifest["fixes"]):
        fd = manifest["fixes"][name]
        for c in fd.get("control", []):
            key = (c["reg"], c["bit"])
            if key in controls and controls[key] != c["name"]:
                raise RegmapError(
                    f"control {key} declared as both {controls[key]!r} and {c['name']!r}"
                )
            controls[key] = c["name"]
    return controls


def _collect_witnesses(manifest):
    """{addr: {"name":..., "desc":..., "fields":..., "flags":[...], "section":..., "fixes":[...]}}

    `desc` (when present) is the exact row-description text to emit in the
    generated table (it wins over `fields`, which stays the bit-layout
    documentation carried for the header comment); `fields` is the fallback
    row description when no `desc` is given."""
    witnesses = {}
    for fix_name in sorted(manifest["fixes"]):
        fd = manifest["fixes"][fix_name]
        section = fd.get("witness_section")
        for w in fd.get("witness", []):
            addr = w["addr"]
            name = w["name"].lower()
            entry = witnesses.get(addr)
            if entry is None:
                witnesses[addr] = entry = {
                    "name": name,
                    "desc": w.get("desc", ""),
                    "fields": w.get("fields", ""),
                    "flags": list(w.get("flags", [])),
                    "section": section,
                    "fixes": [],
                }
            elif entry["name"] != name:
                raise RegmapError(
                    f"witness 0x{addr:X} declared as both {entry['name']!r} (by "
                    f"{'/'.join(entry['fixes'])}) and {name!r} (by {fix_name})"
                )
            entry["fixes"].append(fix_name)
    return witnesses


def _r4d_swapped_md5(manifest):
    for fd in manifest["fixes"].values():
        images = fd.get("witness_swapped_in_images")
        if images:
            return images[0]
    raise RegmapError("no fix declares witness_swapped_in_images")


def render_header(manifest):
    sha = manifest_sha(MANIFEST_PATH)
    controls = _collect_controls(manifest)
    witnesses = _collect_witnesses(manifest)
    md5 = _r4d_swapped_md5(manifest)

    lines = [
        f"/* generated from modem/regmap/regmap.toml sha {sha}; do not edit */",
        "#ifndef QPSK_FIXREGS_H",
        "#define QPSK_FIXREGS_H",
        "",
        f"#define QPSK_REG_FIXCTL 0x{FIXCTL_ADDR:03X}",
    ]
    for (reg, bit), name in sorted(controls.items()):
        lines.append(f"#define QPSK_FIXCTL_{name.upper()}_BIT {bit}")
    lines.append("")
    for addr, w in sorted(witnesses.items()):
        lines.append(f"#define QPSK_REG_{w['name'].upper()} 0x{addr:03X}")
    lines.append("")
    lines.append(f'#define QPSK_R4D_SWAPPED_MD5 "{md5}"')
    lines.append("")
    lines.append("#endif /* QPSK_FIXREGS_H */")
    return "\n".join(lines) + "\n"


def render_inc(manifest):
    """The 0x208 fixctl row and the 0x214-0x25C witness rows sit either side
    of the hand-written DBGCAP rows (0x20C/0x210) in ms_regmap.c's
    address-sorted table, so ms_regmap.c #includes this ONE file twice: once
    with MS_REGMAP_FIXES_FIXCTL_ONLY defined (emits just the 0x208 row) and
    once without (emits the witness rows) -- see ms_regmap.c."""
    sha = manifest_sha(MANIFEST_PATH)
    witnesses = _collect_witnesses(manifest)

    lines = [
        f"/* generated from modem/regmap/regmap.toml sha {sha}; do not edit */",
        "#ifdef MS_REGMAP_FIXES_FIXCTL_ONLY",
        f'{{ 0x{FIXCTL_ADDR:03X}, "fixctl", M, MS_F_WO, "fix control (write-only)" }},',
        "#else",
    ]
    for addr, w in sorted(witnesses.items()):
        section = w["section"]
        if not section:
            raise RegmapError(f"witness 0x{addr:X} ({w['name']}) has no witness_section")
        flags = "|".join(w["flags"]) if w["flags"] else "0"
        desc = w["desc"] or w["fields"] or "/".join(w["fixes"])
        by = "/".join(w["fixes"])
        lines.append(
            f'{{ 0x{addr:03X}, "{w["name"]}", {section}, {flags}, "{desc}" }}, '
            f"/* {by} */"
        )
    lines.append("#endif /* MS_REGMAP_FIXES_FIXCTL_ONLY */")
    return "\n".join(lines) + "\n"


def _write(check=False):
    manifest = load()
    header = render_header(manifest)
    inc = render_inc(manifest)

    if not check:
        HEADER_OUT.parent.mkdir(parents=True, exist_ok=True)
        INC_OUT.parent.mkdir(parents=True, exist_ok=True)
        HEADER_OUT.write_text(header)
        INC_OUT.write_text(inc)
        return 0

    with tempfile.TemporaryDirectory() as td:
        tmp_header = Path(td) / "qpsk_fixregs.h"
        tmp_inc = Path(td) / "ms_regmap_fixes.inc"
        tmp_header.write_text(header)
        tmp_inc.write_text(inc)

        ok = True
        for out, tmp, label in (
            (HEADER_OUT, tmp_header, str(HEADER_OUT.relative_to(ROOT))),
            (INC_OUT, tmp_inc, str(INC_OUT.relative_to(ROOT))),
        ):
            current = out.read_text() if out.exists() else ""
            new = tmp.read_text()
            if current != new:
                ok = False
                diff = difflib.unified_diff(
                    current.splitlines(keepends=True),
                    new.splitlines(keepends=True),
                    fromfile=f"a/{label}",
                    tofile=f"b/{label}",
                )
                sys.stdout.writelines(diff)
        if not ok:
            print(
                "\ngen_regmap.py --check: generated output is stale; "
                "run `python3 modem/regmap/gen_regmap.py` and commit the result.",
                file=sys.stderr,
            )
            return 1
        return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true", help="verify generated files are up to date; exit 1 with a diff if not")
    args = ap.parse_args(argv)
    return _write(check=args.check)


if __name__ == "__main__":
    sys.exit(main())
