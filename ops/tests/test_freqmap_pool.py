"""test_freqmap_pool.py -- ops/freqmap_pool.py, the frequency-map pooler.

The rule it must enforce: a clean candidate cell is evidence ONLY when the reference cell beside
it had the fault. A night where the fault stayed away produces clean candidates everywhere and
proves nothing; the pooler must count those pairs as 'w/fault 0' and refuse to call a shape.
"""
import pathlib
import subprocess
import sys

OPS = pathlib.Path(__file__).resolve().parents[1]
TOOL = OPS / "freqmap_pool.py"


def csv(path, det_per_s, cfc, rstcs_total, n=240):
    """A synthetic 1 Hz poll: 0x104 climbing at det_per_s, constant cfc, rstcs ramping."""
    rows = []
    for t in range(n):
        rows.append(f"{1790000000 + t},{hex(det_per_s * t)},{hex(cfc & 0xFFFFFFFF)},"
                    f"{hex(rstcs_total * t // max(n - 1, 1))},33.0,26.0,34.0")
    path.write_text("\n".join(rows) + "\n")


def make_run(root, stamp, mhz, ref_det, ref_rst, cand_det, cand_rst, cand_cfc=-4750):
    d = root / f"{stamp}_rev{mhz}"; d.mkdir(parents=True)
    (d / "cells.tsv").write_text(
        "cell\tplan\tgate_148\tgate_146\tbringup_rc\tcsv_148\tcsv_146\n"
        f"1\tref1900\t1246\t1200\t0\tc1.148.csv\tc1.146.csv\n"
        f"2\trev{mhz}\t1246\t1240\t0\tc2.148.csv\tc2.146.csv\n")
    csv(d / "c1.148.csv", 1245, -3700, 0); csv(d / "c1.146.csv", ref_det, -4750 if ref_det > 900 else 500, ref_rst)
    csv(d / "c2.148.csv", 1245, -3700, 0); csv(d / "c2.146.csv", cand_det, cand_cfc, cand_rst)


def run(root):
    r = subprocess.run([sys.executable, str(TOOL), str(root)], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    return r.stdout


def test_notch_is_called_only_when_clean_on_both_sides_with_fault_paired_refs(tmp_path):
    make_run(tmp_path, "200000", 1850, 0, 0, 1247, 0)
    make_run(tmp_path, "201500", 2150, 800, 300000, 1247, 0)
    out = run(tmp_path)
    assert "shape: NOTCH" in out
    assert " 1850     1       1     1" in out and " 2150     1       1     1" in out


def test_fault_absent_night_is_a_null_not_a_shape(tmp_path):
    """Both references healthy -> the candidates' cleanliness is not evidence."""
    make_run(tmp_path, "200000", 1850, 1247, 0, 1247, 0)
    make_run(tmp_path, "201500", 2150, 1247, 0, 1247, 0)
    out = run(tmp_path)
    assert " 1850     1       0     0" in out and " 2150     1       0     0" in out
    assert "NOTCH" not in out


def test_partial_candidate_is_not_clean(tmp_path):
    make_run(tmp_path, "200000", 2100, 375, 107150, 778, 88, cand_cfc=-50237)
    out = run(tmp_path)
    assert "    no |" in out            # candidate clean? = no
    assert "NOTCH" not in out


def test_one_sided_cleanliness_does_not_exclude_a_slope(tmp_path):
    make_run(tmp_path, "200000", 1800, 0, 0, 1247, 0)
    make_run(tmp_path, "201500", 1850, 0, 0, 1247, 0)
    out = run(tmp_path)
    assert "one-sided" in out and "SLOPE is not excluded" in out
