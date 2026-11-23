"""carrier_probe.sh: DRY touches nothing and plans one bring-up + tilt score per candidate with the rung's RX
offset; the choice rule is smallest |tilt| among candidates with full detection; APPLY re-arms on the choice."""
import os
import subprocess

OPS = os.path.join(os.path.dirname(__file__), '..')


def test_dry_plans_each_candidate_with_the_rung_offset(tmp_path):
    r = subprocess.run(["bash", os.path.join(OPS, "carrier_probe.sh")], capture_output=True, text=True,
                       env=dict(os.environ, DRY="1", OUT=str(tmp_path), CANDIDATES="2100 2000 2150", RUNG="r3"))
    assert r.returncode == 0, r.stdout + r.stderr
    assert "rx_offset=20000 Hz" in r.stdout
    assert "[DRY] bring-up fwd 2100000000/2100020000" in r.stdout and "[DRY] bring-up fwd 2000000000/2000020000" in r.stdout
    assert "CARRIER_PROBE_CHOICE dry" in r.stdout and "iio_readdev" in r.stdout
    assert not any(p.suffix == ".iq" for p in tmp_path.iterdir())


def test_r4_offset_and_script_discipline():
    r = subprocess.run(["bash", os.path.join(OPS, "carrier_probe.sh")], capture_output=True, text=True,
                       env=dict(os.environ, DRY="1", OUT="/tmp/claude-1000/cp-r4-dry", CANDIDATES="2100", RUNG="r4"))
    assert "rx_offset=60000 Hz" in r.stdout and "fwd 2100000000/2100060000" in r.stdout
    s = open(os.path.join(OPS, "carrier_probe.sh")).read()
    code = "\n".join(l for l in s.splitlines() if not l.lstrip().startswith("#"))
    assert 'env -u SRO_SIGN_CONF' in code                       # the rung's own steering conf, never an inherited one
    assert 'rigprobe.sh $A 0x104' in code and 'tilt_score.py' in code
    assert 'CARRIER_PROBE_CHOICE' in code and 'GATE_FPS_DEFAULT' in code
