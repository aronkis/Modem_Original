"""Every banked image is one real file that the rails and deploy_image.sh can reach.

WHY THIS TEST EXISTS. The bank used to carry rail-shaped symlinks
(`BOOT.BIN.<board>.<tag>.<md5-12>`) onto one canonical
`BOOT.BIN.jupiter.<tag>.<32-hex>` blob, because the rails built the path from
FLASH_TAG and FLASH_MD5. Since 2026-09-17 the repo carries no symlinks or
aliases at all: the rails resolve `FLASH_MD5` (12 hex) through `images/MD5SUMS`
(`awk 'index($1,p)==1{print $2}'`) and `deploy_image.sh` reads the file column
of `images/CURRENT.txt`. So the properties that keep a flash honest are now:

* every entry in MD5SUMS names a regular file (not a link) whose md5 is the one
  recorded -- what the rail lookup returns must be the image it says;
* every 12-hex prefix in MD5SUMS is unique -- the rail lookup takes the first
  match, so a collision would silently flash the wrong image;
* every CURRENT.txt role row names a file in MD5SUMS with a matching md5;
* no rail-shaped alias sneaks back in: a `BOOT.BIN.<board>.<tag>.<md5-12>` name
  is only acceptable as a distinct real image (the pre-single-image rows), and
  its md5 must still start with the 12 hex chars in its own name.

Board-free and network-free: it reads files under images/ and nothing else.
"""
import hashlib
import pathlib
import re

import pytest

REPO = pathlib.Path(__file__).resolve().parents[2]
IMAGES = REPO / "images"
RAIL_RE = re.compile(r"^BOOT\.BIN\.(?P<board>\d{3})\.(?P<tag>[^.]+)\.(?P<suffix>[0-9a-f]+)$")


def _md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _md5sums():
    rows = []
    for line in (IMAGES / "MD5SUMS").read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        md5, name = line.split(None, 1)
        rows.append((md5, name.strip()))
    return rows


def _boot_bins():
    return sorted(p for p in IMAGES.iterdir() if p.name.startswith("BOOT.BIN."))


def test_no_symlinks_in_images():
    links = [p.name for p in IMAGES.iterdir() if p.is_symlink()]
    assert not links, "images/ must carry real files only (no aliases): %s" % links


def test_every_boot_bin_is_in_md5sums_and_matches():
    listed = dict(_md5sums())
    by_name = {n: m for m, n in listed.items()}
    for p in _boot_bins():
        assert p.name in by_name, "%s is banked but not in MD5SUMS" % p.name
        assert p.is_file() and not p.is_symlink(), "%s is not a regular file" % p.name
        assert _md5(p) == by_name[p.name], "%s: md5 differs from MD5SUMS" % p.name


def test_md5sums_entries_exist():
    for md5, name in _md5sums():
        p = IMAGES / name
        assert p.is_file(), "MD5SUMS names %s which is not a file in images/" % name


def test_rail_lookup_prefixes_are_unique():
    """flash_{148,146}_txfix.sh take the FIRST MD5SUMS entry whose md5 starts with
    the 12-hex FLASH_MD5; two BOOT.BINs sharing a prefix would be a silent misflash."""
    prefixes = {}
    for md5, name in _md5sums():
        if not name.startswith("BOOT.BIN."):
            continue
        assert md5[:12] not in prefixes, "12-hex prefix %s shared by %s and %s" % (
            md5[:12], prefixes[md5[:12]], name)
        prefixes[md5[:12]] = name


def test_rail_shaped_names_are_real_distinct_images():
    by_name = {n: m for m, n in _md5sums()}
    for p in _boot_bins():
        m = RAIL_RE.match(p.name)
        if not m:
            continue
        suffix = m.group("suffix")
        assert len(suffix) == 12, "%s: a board-named image carries the 12-hex md5" % p.name
        assert by_name[p.name].startswith(suffix), "%s: md5 does not start with its own suffix" % p.name


def test_current_txt_rows_resolve():
    by_name = {n: m for m, n in _md5sums()}
    rows = [l.split() for l in (IMAGES / "CURRENT.txt").read_text().splitlines()
            if l.strip() and not l.startswith("#")]
    assert rows, "CURRENT.txt has no role rows"
    for role, name, md5, *_ in rows:
        assert name in by_name, "CURRENT.txt %s names %s, not in MD5SUMS" % (role, name)
        assert by_name[name] == md5, "CURRENT.txt %s md5 differs from MD5SUMS for %s" % (role, name)
        assert (IMAGES / name).is_file()


def test_rails_resolve_through_md5sums_not_rail_names():
    for rail in ("flash_148_txfix.sh", "flash_146_txfix.sh"):
        s = (REPO / "ops" / "flash" / rail).read_text()
        assert 'images/MD5SUMS' in s, "%s must resolve FLASH_MD5 through images/MD5SUMS" % rail
        assert not re.search(r"BB=\$ROOT/images/BOOT\.BIN\.\d{3}\.\$TAG", s), \
            "%s still builds a rail-shaped path" % rail
