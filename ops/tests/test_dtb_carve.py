#!/usr/bin/env python3
"""test_dtb_carve.py -- sp4 Task 10: the banked 4 MB-carve qpsk dtbs (f3072 rung).

NO BOARD CONTACT. Pins, for each board row `DTB<board>` in images/CURRENT.txt:
  * the file exists, its name carries its md5-12, the md5 matches the row and MD5SUMS;
  * fdtget /reserved-memory/qpsk_byte_buf@7ff00000 reg == "0 2143289344 0 4194304"
    (<0 0x7fc00000 0 0x400000>) with no-map, and it is the ONLY carve node;
  * the three UIO nodes are present with the board's SPI cells (110/111);
  * the dts text differs from the banked 2 MB dtb of the same board in the reg line only;
  * ops/deploy_dtb.sh check <file> -> CHECK_OK and deploy_dtb.sh --dry <ip> resolves the
    CURRENT.txt row and touches no board (the ssh wrapper is pointed at a script that fails);
  * ops/dtb/build_dtb_4mb.sh --out-dir <tmp> reproduces the banked file byte for byte.
"""
import hashlib
import os
import pathlib
import re
import subprocess
import shutil

import pytest

OPS = pathlib.Path(__file__).resolve().parents[1]
ROOT = OPS.parent
IMG = ROOT / "images"
CARVE_NODE = "/reserved-memory/qpsk_byte_buf@7ff00000"
WANT_REG_4MB = "0 2143289344 0 4194304"
WANT_REG_2MB = "0 2145386496 0 2097152"
BOARDS = {"148": "10.0.0.148", "146": "10.0.0.146"}

pytestmark = pytest.mark.skipif(shutil.which("fdtget") is None or shutil.which("dtc") is None,
                                reason="dtc/fdtget not installed")


def current_rows():
    rows = {}
    for line in (IMG / "CURRENT.txt").read_text().splitlines():
        if line.startswith("DTB"):
            role, fname, md5 = line.split()[:3]
            rows[role[3:]] = (fname, md5)
    return rows


def fdtget(dtb, node, prop):
    return subprocess.run(["fdtget", str(dtb), node, prop], capture_output=True, text=True)


def dts(dtb):
    return subprocess.run(["dtc", "-q", "-I", "dtb", "-O", "dts", str(dtb)],
                          capture_output=True, text=True, check=True).stdout.splitlines()


def banked_2mb(board):
    hits = [f for f in IMG.glob(f"system-qpsk.{board}.dtb.*")
            if fdtget(f, CARVE_NODE, "reg").stdout.strip() == WANT_REG_2MB]
    assert len(hits) == 1, f"expected one banked 2 MB dtb for {board}, got {hits}"
    return hits[0]


@pytest.mark.parametrize("board", sorted(BOARDS))
def test_current_row_and_md5(board):
    rows = current_rows()
    assert board in rows, f"images/CURRENT.txt has no DTB{board} row"
    fname, md5 = rows[board]
    f = IMG / fname
    assert f.is_file(), f
    got = hashlib.md5(f.read_bytes()).hexdigest()
    assert got == md5, f"{fname}: md5 {got} != CURRENT.txt {md5}"
    assert fname.endswith(md5[:12]), "file name must carry the md5-12"
    assert re.search(rf"^{md5}  {re.escape(fname)}$", (IMG / "MD5SUMS").read_text(), re.M), "MD5SUMS row missing"


@pytest.mark.parametrize("board", sorted(BOARDS))
def test_carve_is_4mb_at_7fc00000(board):
    f = IMG / current_rows()[board][0]
    r = fdtget(f, CARVE_NODE, "reg")
    assert r.returncode == 0 and r.stdout.strip() == WANT_REG_4MB, r
    assert fdtget(f, CARVE_NODE, "no-map").returncode == 0, "no-map missing"
    nodes = subprocess.run(["fdtget", "-l", str(f), "/reserved-memory"], capture_output=True, text=True).stdout.split()
    assert [n for n in nodes if n.startswith("qpsk_byte_buf")] == ["qpsk_byte_buf@7ff00000"], nodes
    # the carve ends exactly at the top of the 2 GB DDR
    mem = fdtget(f, "/memory@0", "reg").stdout.split()
    assert mem == ["0", "0", "0", "-2147483648"], mem     # <0 0 0 0x80000000>
    assert 0x7FC00000 + 0x400000 == 0x80000000


@pytest.mark.parametrize("board", sorted(BOARDS))
def test_uio_nodes_and_spi_cells(board):
    f = IMG / current_rows()[board][0]
    assert fdtget(f, "/axi_pl/qpsk_tx_dma@9d100000", "interrupts").stdout.split() == ["0", "110", "4"]
    assert fdtget(f, "/axi_pl/qpsk_rx_dma@9d200000", "interrupts").stdout.split() == ["0", "111", "4"]
    assert fdtget(f, "/axi_pl/qpsk_byte_gpio@9d300000", "reg").returncode == 0
    assert fdtget(f, "/axi_pl", "interrupt-parent").returncode == 0


@pytest.mark.parametrize("board", sorted(BOARDS))
def test_differs_from_2mb_in_reg_only(board):
    new = dts(IMG / current_rows()[board][0])
    old = dts(banked_2mb(board))
    assert len(new) == len(old)
    changed = [(a, b) for a, b in zip(old, new) if a != b]
    assert len(changed) == 1, changed
    assert "0x7fe00000 0x00 0x200000" in changed[0][0] and "0x7fc00000 0x00 0x400000" in changed[0][1], changed


@pytest.mark.parametrize("board", sorted(BOARDS))
def test_deploy_dtb_check_and_dry(board, tmp_path):
    f = IMG / current_rows()[board][0]
    r = subprocess.run([str(OPS / "deploy_dtb.sh"), "check", str(f)], capture_output=True, text=True)
    assert r.returncode == 0 and "CHECK_OK" in r.stdout, r.stdout + r.stderr
    assert "4MB carve" in r.stdout, r.stdout
    # --dry resolves the CURRENT.txt row and never reaches a board: point the ssh
    # wrapper at a script that fails loudly if invoked.
    fake = tmp_path / "anyssh.sh"
    fake.write_text("#!/bin/sh\necho BOARD_CONTACT >&2; exit 97\n"); fake.chmod(0o755)
    env = dict(os.environ, ANYSSH=str(fake))
    r = subprocess.run([str(OPS / "deploy_dtb.sh"), "--dry", BOARDS[board]], capture_output=True, text=True, env=env)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "BOARD_CONTACT" not in r.stderr
    assert f.name in r.stdout and "DRY" in r.stdout, r.stdout


def test_2mb_dtb_still_checks():
    """The rollback (2 MB) dtbs remain deployable through the same gate."""
    for board in BOARDS:
        r = subprocess.run([str(OPS / "deploy_dtb.sh"), "check", str(banked_2mb(board))], capture_output=True, text=True)
        assert r.returncode == 0 and "2MB carve" in r.stdout, r.stdout + r.stderr


@pytest.mark.skipif(shutil.which("fdtoverlay") is None, reason="fdtoverlay not installed")
def test_build_reproduces_banked(tmp_path):
    md5sums_before = (IMG / "MD5SUMS").read_bytes()
    r = subprocess.run([str(OPS / "dtb" / "build_dtb_4mb.sh"), "--out-dir", str(tmp_path)],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    for board, (fname, md5) in current_rows().items():
        assert f"DTB4MB_OK board={board} " in r.stdout and f"md5={md5[:12]}" in r.stdout, r.stdout
        assert "xcheck: pristine+uio == banked 2 MB tree" in r.stdout, r.stdout
        assert (tmp_path / fname).read_bytes() == (IMG / fname).read_bytes()
    assert (IMG / "MD5SUMS").read_bytes() == md5sums_before, "MD5SUMS must be untouched by --out-dir"
