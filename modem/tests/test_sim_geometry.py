"""The live simulation benches take their air-frame geometry from ONE place (sp4 plan Task 6),
and since 2026-10-01 that place is RENDERED per rung by modem/rtl_sim/geometry_gen.py: the committed
geometry.h / geometry.py are the r4 render (byte-identical), the r3 render carries the f1536 contract
(12333 slots, 49332 samples, 191 words, 1528 B) so run_gates.sh --rung r3 can gate the shipped rung.

`modem/rtl_sim/geometry.h` (C++ drivers) and `modem/rtl_sim/sro_score/geometry.py` (scorers,
stimulus generator) carry the f3072 numbers and must agree with `contract/f3072_ref_bits.m`
(SLOTS 24634, FRSAMP 49268, WPP 382, PKT 3056, payload 49216). No live bench, scorer or leg
table may carry the retired f1536 literals (12333, 12320, 49332, 191-word frames, 1528/1516
bytes, 14-bit tref) in a code line; `rtl_sim/studies/`, `tap_replay_study/`, `evidence/`,
`RESULTS/`, `dmac_src/`, `seqbist_unit/` are provenance and are not checked.
"""
import pathlib
import re

MODEM = pathlib.Path(__file__).resolve().parents[1]
RTL = MODEM / "rtl_sim"
EXPECT = dict(SLOTS=24634, FRSAMP=49268, WPP=382, PKT_BYTES=3056, PAYLOAD_BITS=49216, SPS=2,
              DATA_SYMS=24608, PREAMBLE_SYMS=26, MAX_FILL=3044)


def _h_defines():
    d = {}
    for m in re.finditer(r"#define\s+GEOM_(\w+)\s+(\d+)L?", (RTL / "geometry.h").read_text()):
        d[m.group(1)] = int(m.group(2))
    return d


def _py_values():
    ns = {}
    exec((RTL / "sro_score" / "geometry.py").read_text(), ns)
    return {k: v for k, v in ns.items() if k.isupper()}


def test_geometry_h_matches_the_contract():
    d = _h_defines()
    for k, v in EXPECT.items():
        assert d[k] == v, (k, d.get(k), v)
    assert d["STROBE_INTERVAL"] == d["SPS"]
    assert d["S1B_FRAME_CLKS"] == d["SLOTS"] * 2 * d["SPS"] * 2
    assert d["DDRCAP2_WIDE"] == 1


def test_geometry_py_matches_geometry_h():
    d = _h_defines()
    p = _py_values()
    for k in ("SLOTS", "FRSAMP", "WPP", "PKT_BYTES", "PAYLOAD_BITS", "SPS", "DATA_SYMS", "PREAMBLE_SYMS", "MAX_FILL"):
        assert p[k] == d[k], (k, p[k], d[k])


RETIRED = re.compile(r"(?<![\w.])(12333|12332|12320|49332|49280|24640|1600|1528|1516|1524)(?![\w.])|14'd12333|\[13:0\]\s+tref\b")
# geometry_gen.py is the DATA table for both rungs and model_matrix_f1536.legs IS the f1536 table
EXEMPT_FILES = ("geometry_gen.py", "model_matrix_f1536.legs")
SKIP_DIRS = ("studies", "tap_replay_study", "evidence", "RESULTS", "dmac_src", "seqbist_unit", "beat_runs", "golden_taps", "replay", "txplane_runs", "tests")


def _live_files():
    """git-TRACKED files only: obj_*/, s1_rtl_*/ and the *_model.v wrappers are generated."""
    import subprocess
    out = subprocess.run(["git", "ls-files", "--", "modem/rtl_sim", "modem/gates"], cwd=MODEM.parent,
                         capture_output=True, text=True, check=True).stdout.split()
    for rel in out:
        p = MODEM.parent / rel
        if p.suffix not in (".v", ".cpp", ".py", ".sh", ".legs"):
            continue
        parts = p.relative_to(RTL).parts if p.is_relative_to(RTL) else ()
        if any(part in SKIP_DIRS for part in parts[:-1]) or p.name.endswith("_model.v") or p.name in EXEMPT_FILES:
            continue
        yield p


def _code_lines(text, suffix):
    for i, ln in enumerate(text.splitlines(), 1):
        s = ln.strip()
        if not s:
            continue
        if suffix in (".py", ".sh", ".legs") and s.startswith("#"):
            continue
        if suffix in (".v", ".cpp") and s.startswith("//"):
            continue
        # strip trailing comments
        if suffix in (".v", ".cpp"):
            ln = ln.split("//")[0]
        elif suffix in (".py", ".sh", ".legs"):
            ln = ln.split(" #")[0]
        yield i, ln


def test_no_retired_f1536_literals_in_live_benches():
    hits = []
    for p in _live_files():
        suffix = ".legs" if p.suffix == ".legs" else p.suffix
        for i, ln in _code_lines(p.read_text(errors="replace"), suffix):
            if "words191_k1536" in ln or "f1536" in ln:
                continue   # named rows / explicit per-frame branches
            if RETIRED.search(ln):
                hits.append(f"{p.relative_to(MODEM)}:{i}: {ln.strip()[:100]}")
    assert not hits, "retired f1536 geometry literals in live code lines:\n" + "\n".join(hits)


def test_geometry_gen_r4_render_is_the_committed_pair():
    import subprocess, sys
    r = subprocess.run([sys.executable, str(RTL / "geometry_gen.py"), "--rung", "r4", "--check"], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    assert r.stdout.count("GEOMETRY_OK") == 2


def test_geometry_gen_r3_render_carries_the_f1536_contract(tmp_path):
    import subprocess, sys
    (tmp_path / "sro_score").mkdir()
    r = subprocess.run([sys.executable, str(RTL / "geometry_gen.py"), "--rung", "r3", "--out", str(tmp_path)], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    h = {m.group(1): int(m.group(2)) for m in re.finditer(r"#define\s+GEOM_(\w+)\s+(\d+)L?", (tmp_path / "geometry.h").read_text())}
    assert (h["SPS"], h["SLOTS"], h["FRSAMP"], h["WPP"], h["PKT_BYTES"], h["PAYLOAD_BITS"], h["PREAMBLE_SYMS"]) == (4, 12333, 49332, 191, 1528, 24640, 13)
    assert h["STEER_LEAD"] == 0 and h["STEER_TREF_OFF"] == 0 and h["DDRCAP2_WIDE"] == 0
    assert h["S1B_FRAME_CLKS"] == 12333 * 2 * 4 * 2
    ns = {}; exec((tmp_path / "sro_score" / "geometry.py").read_text(), ns)
    for k in ("SPS", "SLOTS", "FRSAMP", "WPP", "PKT_BYTES", "PAYLOAD_BITS", "STEER_LEAD", "STEER_TREF_OFF"):
        assert ns[k] == h[k], k
    # r2 is the same frame on the slower rail
    r2 = subprocess.run([sys.executable, str(RTL / "geometry_gen.py"), "--rung", "r2", "--out", str(tmp_path)], capture_output=True, text=True)
    assert "GEOMETRY_UNCHANGED" in r2.stdout and r2.returncode == 0


def test_f1536_legs_table_is_the_f1536_shape():
    legs = (MODEM / "gates" / "model_matrix_f1536.legs").read_text()
    rows = [l for l in legs.splitlines() if l.strip() and not l.startswith("#")]
    rows_r4 = [l for l in (MODEM / "gates" / "model_matrix.legs").read_text().splitlines() if l.strip() and not l.startswith("#")]
    assert [r.split("|", 1)[0] for r in rows] == [r.split("|", 1)[0] for r in rows_r4], "same leg names, same order"
    assert "n_p000.iq 21114096" in legs and "21086704" not in legs
    assert "reference_loss_f1536.toml" in legs and "$HERE/reference_loss.toml" not in legs
