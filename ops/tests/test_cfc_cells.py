"""test_cfc_cells.py -- ops/cfc_cells.py, the scorer for an interleaved LO sweep.

The statistic it exists to produce is the fraction of frames whose carrier-frequency estimate sits
on the wrong side of zero. Two things must hold or the sweep cannot be read: the 21-bit field has
to be sign-extended (unsigned, every value looks positive and the fraction is meaninglessly 100 %),
and the cells have to come out in cell ORDER, because the design is read down the column.
"""
import pathlib
import re
import subprocess
import sys

import numpy as np

OPS = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OPS))
from frame_taxonomy import DTYPE  # noqa: E402

SCORER = OPS / "cfc_cells.py"


def make_leg(d, cfcs, crc_ok=True, wedged=False):
    """A frames.bin with one record per cfc value, 1 ms apart."""
    d.mkdir(parents=True, exist_ok=True)
    a = np.zeros(len(cfcs), dtype=DTYPE)
    a["t_mono_ns"] = np.arange(len(cfcs), dtype=np.uint64) * 1_000_000
    a["crc_ok"] = 1 if crc_ok else 0
    a["reg_cfc"] = [c & 0x1FFFFF for c in cfcs]   # stored as the raw 21-bit field
    a.tofile(d / "frames.bin")
    (d / "capture.out").write_text("CAPTURE_ABORTED_WEDGED\n" if wedged else "done\n")
    return d


def run(args):
    return subprocess.run([sys.executable, str(SCORER), *map(str, args)],
                          capture_output=True, text=True)


def test_negative_cfc_is_sign_extended(tmp_path):
    # all four values are negative; unsigned they would all read as large positives
    leg = make_leg(tmp_path / "cell1_A_2000060000", [-5000, -4000, -3000, -6000])
    r = run([leg])
    assert r.returncode == 0, r.stderr
    line = [l for l in r.stdout.splitlines() if "cell1" in l][0]
    assert "0.00%" in line, line          # CFC>0 fraction
    assert "-4500" in line or "-4000" in line   # median of the four


def test_sign_fraction_counts_only_strictly_positive(tmp_path):
    leg = make_leg(tmp_path / "cell1_A_2000020000", [-100, -100, 0, 5, 7, 9, -1, -1, -1, -1])
    r = run([leg])
    line = [l for l in r.stdout.splitlines() if "cell1" in l][0]
    assert "30.00%" in line, line   # 3 of 10 strictly > 0; zero does not count


def test_cells_come_out_in_cell_order_not_alphabetical(tmp_path):
    camp = tmp_path / "camp"
    for i, v in [(1, "2000020000"), (2, "2000060000"), (3, "2000020000"), (4, "2000060000")]:
        make_leg(camp / f"cell{i}_A_{v}", [-3000] * 5)
    # a 10th cell would sort before cell2 alphabetically
    make_leg(camp / "cell10_A_2000020000", [-3000] * 5)
    r = run([camp])
    # startswith("cell") alone would catch the header row, whose first column header is "cell"
    order = [l.split()[0] for l in r.stdout.splitlines() if re.match(r"^cell\d+_", l)]
    assert order == ["cell1_A_2000020000", "cell2_A_2000060000", "cell3_A_2000020000",
                     "cell4_A_2000060000", "cell10_A_2000020000"], order


def test_a_cell_with_no_frames_is_reported_not_skipped(tmp_path):
    d = tmp_path / "camp" / "cell1_A_2000020000"; d.mkdir(parents=True)
    r = run([tmp_path / "camp"])
    assert r.returncode == 0
    assert "no frames.bin" in r.stdout and "itself a result" in r.stdout


def test_wedged_cell_is_flagged(tmp_path):
    leg = make_leg(tmp_path / "cell1_A_2000020000", [-3000] * 5, wedged=True)
    r = run([leg])
    assert r.stdout.splitlines()[1].rstrip().endswith("YES")


def test_matches_the_published_numbers_for_the_2026_09_26_wedge():
    """Regression against the leg the evidence file quotes: 88.13 % CRC, 41.1 % CFC>0."""
    leg = OPS / "r3cap" / "wedge_r4fwd_20260926_003610" / "fwd300_2"
    if not (leg / "frames.bin").exists():
        return   # campaign data not on this machine
    r = run([leg])
    line = [l for l in r.stdout.splitlines() if "fwd300_2" in l][0]
    assert "88.13%" in line and "41.07%" in line, line
