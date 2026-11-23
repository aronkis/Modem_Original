"""run_gates.sh --rung / build_image.sh rung wiring (2026-10-01): the gate harness geometry, bank and legs
table follow the kit's rate rung. --rung r3 renders the f1536 twins for the run and puts the committed r4
render back on exit; a bad rung is refused; build_image picks r3 + model_matrix_f1536.legs for QPSK_FRAME=f1536.
No board, no stimulus bank: --list only."""
import os
import pathlib
import re
import subprocess

MODEM = pathlib.Path(__file__).resolve().parents[1]
RTL = MODEM / "rtl_sim"
GATES = MODEM / "gates"


def _h(path):
    return {m.group(1): int(m.group(2)) for m in re.finditer(r"#define\s+GEOM_(\w+)\s+(\d+)L?", path.read_text())}


def test_rung_r3_list_renders_and_restores(tmp_path):
    sro = tmp_path / "sro_sim"; sro.mkdir()
    env = dict(os.environ, SRO_SIM_DIR=str(sro), SP2_WORK=str(tmp_path / "work"))
    before = (RTL / "geometry.h").read_text()
    r = subprocess.run(["bash", str(GATES / "run_gates.sh"), "--rung", "r3", "--legs", str(GATES / "model_matrix_f1536.legs"), "--list"],
                       capture_output=True, text=True, env=env)
    assert "GATES_RUNG r3" in r.stdout, r.stdout + r.stderr
    assert "GEOMETRY rung=r3 frame=f1536" in r.stdout and "GATES_GEOMETRY_RESTORED r4" in r.stdout
    assert (RTL / "geometry.h").read_text() == before and _h(RTL / "geometry.h")["SLOTS"] == 24634


def test_rung_default_is_r4_with_the_f3072_bank(tmp_path):
    env = dict(os.environ, SP2_WORK=str(tmp_path / "work")); env.pop("SRO_SIM_DIR", None)
    r = subprocess.run(["bash", str(GATES / "run_gates.sh"), "--legs", str(GATES / "model_matrix.legs"), "--list"], capture_output=True, text=True, env=env)
    assert "GATES_RUNG r4 SRO=/mnt/onetb/scratch/qpsk-build-trees/sro_sim_f3072" in r.stdout or "GATES_MISSING_STIMULI SRO_SIM_DIR=/mnt/onetb/scratch/qpsk-build-trees/sro_sim_f3072" in r.stdout


def test_bad_rung_is_refused(tmp_path):
    r = subprocess.run(["bash", str(GATES / "run_gates.sh"), "--rung", "r9", "--list"], capture_output=True, text=True)
    assert r.returncode == 2 and "GATES_BAD_RUNG r9" in r.stdout


def test_build_image_gates_stage_follows_the_kit_rung():
    s = (MODEM / "build_image.sh").read_text()
    assert 'f1536) G_RUNG=r3; LEGS="$GATESDIR/model_matrix_f1536.legs"' in s
    assert '*) G_RUNG=r4; LEGS="$GATESDIR/model_matrix.legs"' in s
    assert 'geometry_gen.py" --rung "$G_RUNG"' in s and '"$GATESDIR/run_gates.sh" --rung "$G_RUNG" --legs "$LEGS"' in s
