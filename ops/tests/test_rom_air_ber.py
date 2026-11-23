"""test_rom_air_ber.py -- ops/rom_air_ber.sh, the PHY-only air measurement ported from the
pre-cleanup archive on 2026-09-27.

Every test runs against stub boards. The three things that decide whether a result means anything:

  * DIRECTION MAPPING. Each board's 0x108 scores what THAT BOARD received, so 146 is the reverse leg
    and 148 the forward one. Getting this backwards inverts the conclusion.
  * THE POSITIVE CONTROL. A floor reading is not evidence unless the same comparator can be driven
    high. If the control stage reads the floor the run must report VOID and not a clean PHY.
  * THE RESTORE. It kills the watchdogs and the daemons, so the trap has to be installed before the
    quiesce and has to fall back to restore_known_good.sh.
"""
import os
import pathlib
import subprocess

OPS = pathlib.Path(__file__).resolve().parents[1]
SRC = OPS / "rom_air_ber.sh"


def make_tree(tmp_path, ctrl_epf=60.0, rom_epf=0.0, bringup_rc=0):
    """A fake ops/ dir: the stub board returns counters chosen per stage."""
    d = tmp_path / "ops"; (d / "sim_repro").mkdir(parents=True)
    (d / "rom_air_ber.sh").write_text(SRC.read_text()); (d / "rom_air_ber.sh").chmod(0o755)
    (d / "sim_repro" / "riglock.sh").write_text(
        "rig_lock_only(){ echo LOCKED >> \"$RL_WITNESS\"; }\n"
        "rig_unlock_only(){ echo UNLOCKED >> \"$RL_WITNESS\"; }\n")
    # stub board: 'echo ok' for alive; a counters line for a dwell; silence otherwise.
    # frames=1000 per dwell, errs = epf*1000, stage decided by a call counter (2 control dwells first)
    (d / "anyssh.sh").write_text(f"""#!/bin/bash
cmd="$*"
case "$cmd" in
  *"echo ok"*) echo ok; exit 0 ;;
esac
if [[ "$cmd" == *0x104* ]]; then
  n=$(cat "$DWELL_COUNT" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$DWELL_COUNT"
  if [ $n -le 2 ]; then epf={ctrl_epf}; else epf={rom_epf}; fi
  errs=$(awk -v e="$epf" 'BEGIN{{printf "%d", e*1000}}')
  echo "p1=0 p2=1000 e1=0 e2=$errs c1=0xFFFFEE00 c2=0xFFFFEE00 r1=0 r2=0 dt=10"
  exit 0
fi
echo quiesced
""")
    (d / "anyssh.sh").chmod(0o755)
    (d / "bringup_r2r3.sh").write_text(
        f'#!/bin/bash\necho "BRINGUP rung=$1 GATE_DIR=${{GATE_DIR:-unset}}" >> "$BU_WITNESS"\nexit {bringup_rc}\n')
    (d / "bringup_r2r3.sh").chmod(0o755)
    (d / "restore_known_good.sh").write_text('#!/bin/bash\necho RKG >> "$BU_WITNESS"\nexit 0\n')
    (d / "restore_known_good.sh").chmod(0o755)
    return d


def run(tmp_path, **kw):
    d = make_tree(tmp_path, **{k: v for k, v in kw.items()
                              if k in ("ctrl_epf", "rom_epf", "bringup_rc")})
    out = tmp_path / "out"
    env = dict(os.environ, DRY="0", OUT=str(out), DWELL="0", REPS="2",
               SENTINEL_STOP_FILE=str(tmp_path / "SS"), RIG_LOCK=str(tmp_path / "LOCK"),
               RL_WITNESS=str(tmp_path / "rl"), BU_WITNESS=str(tmp_path / "bu"),
               DWELL_COUNT=str(tmp_path / "n"), HOME=str(tmp_path))
    r = subprocess.run(["bash", str(d / "rom_air_ber.sh")], capture_output=True, text=True, env=env)
    tsv = (out / "rom_air_ber.tsv")
    return r, (tsv.read_text() if tsv.exists() else ""), tmp_path


def test_direction_mapping_146_is_reverse_148_is_forward(tmp_path):
    r, tsv, _ = run(tmp_path)
    rows = [l.split("\t") for l in tsv.splitlines()[1:]]
    for row in rows:
        board, legname = row[0], row[1]
        assert (board, legname) in (("10.0.0.146", "reverse"), ("10.0.0.148", "forward")), row
    assert "10.0.0.146 = reverse leg" in r.stdout


def test_control_high_then_clean_rom_is_reported_ok(tmp_path):
    r, tsv, _ = run(tmp_path, ctrl_epf=60.0, rom_epf=0.0)
    assert "ROM_AIR_BER_OK" in r.stdout, r.stdout
    assert "control read high" in r.stdout
    assert "ctrl_high" in tsv and "rom_r1" in tsv


def test_control_at_the_floor_makes_the_run_void(tmp_path):
    """The whole point: a clean ROM reading proves nothing if the comparator never reads high."""
    r, tsv, _ = run(tmp_path, ctrl_epf=0.0, rom_epf=0.0)
    assert "ROM_AIR_BER_VOID" in r.stdout, r.stdout
    assert "NOT evidence of a clean PHY" in r.stdout
    assert "ROM_AIR_BER_OK" not in r.stdout


def test_restore_runs_with_gate_dir_scoped_to_forward(tmp_path):
    """A both-direction arm gate cannot pass during the reverse episode this instrument runs in."""
    r, _, tp = run(tmp_path)
    bu = (tp / "bu").read_text()
    assert "BRINGUP rung=r3 GATE_DIR=A" in bu, bu


def test_restore_falls_back_to_restore_known_good(tmp_path):
    r, _, tp = run(tmp_path, bringup_rc=1)
    bu = (tp / "bu").read_text()
    assert bu.count("BRINGUP") == 2, bu       # retried once
    assert "RKG" in bu
    assert "restore_known_good OK" in r.stdout


def test_restore_failure_leaves_a_loud_marker(tmp_path):
    d = make_tree(tmp_path, bringup_rc=1)
    (d / "restore_known_good.sh").write_text('#!/bin/bash\nexit 1\n')
    (d / "restore_known_good.sh").chmod(0o755)
    out = tmp_path / "out"
    env = dict(os.environ, DRY="0", OUT=str(out), DWELL="0", REPS="1",
               SENTINEL_STOP_FILE=str(tmp_path / "SS"), RIG_LOCK=str(tmp_path / "LOCK"),
               RL_WITNESS=str(tmp_path / "rl"), BU_WITNESS=str(tmp_path / "bu"),
               DWELL_COUNT=str(tmp_path / "n"), HOME=str(tmp_path))
    r = subprocess.run(["bash", str(d / "rom_air_ber.sh")], capture_output=True, text=True, env=env)
    assert "THE RIG IS NOT IN SERVICE" in r.stdout
    assert (out / "RESTORE_FAILED").exists()


def test_the_lock_is_taken_and_released(tmp_path):
    r, _, tp = run(tmp_path)
    rl = (tp / "rl").read_text()
    assert "LOCKED" in rl and "UNLOCKED" in rl


def test_sentinel_hold_is_ours_and_released(tmp_path):
    r, _, tp = run(tmp_path)
    assert "SENTINEL_STOP taken (ours)" in r.stdout and "SENTINEL_STOP released" in r.stdout
    assert not (tp / "SS").exists()


def test_a_foreign_sentinel_hold_is_never_removed(tmp_path):
    ss = tmp_path / "SS"; ss.write_text("someone else\n")
    r, _, tp = run(tmp_path)
    assert "NOT ours, leaving it" in r.stdout
    assert ss.read_text() == "someone else\n", "a hold we did not create must survive"


def test_the_scored_column_is_labelled_frame_start_damage(tmp_path):
    """0x108 sees only the first 120 of 2240 bits; the column must not read as a link BER."""
    r, tsv, _ = run(tmp_path)
    head = tsv.splitlines()[0].split("\t")
    assert head[7] == "framestart_damage_120b", head


def test_every_data_row_has_exactly_the_header_columns(tmp_path):
    """Regression: score() used to print board and stage itself while emit() prepended them too, so
    each row carried a duplicate board column and the control gate read fps as err_per_frame."""
    r, tsv, _ = run(tmp_path)
    lines = tsv.splitlines()
    n = len(lines[0].split("\t"))
    for l in lines[1:]:
        assert len(l.split("\t")) == n, (n, l)
    # and the stage column really is the stage
    stages = {l.split("\t")[2] for l in lines[1:]}
    assert stages == {"ctrl_high", "rom_r1", "rom_r2"}, stages


def test_trap_is_installed_before_the_quiesce(tmp_path):
    src = SRC.read_text()
    assert src.index("trap 'restore' EXIT") < src.index("quiesce watchdog + daemons"), \
        "an exit between quiesce and trap would leave the rig down"


def test_dry_is_the_default_and_touches_nothing(tmp_path):
    d = make_tree(tmp_path)
    out = tmp_path / "out"
    env = dict(os.environ, OUT=str(out), BU_WITNESS=str(tmp_path / "bu"),
               RL_WITNESS=str(tmp_path / "rl"), HOME=str(tmp_path))
    env.pop("DRY", None)
    r = subprocess.run(["bash", str(d / "rom_air_ber.sh")], capture_output=True, text=True, env=env)
    assert "ROM_AIR_BER_DRY_OK" in r.stdout
    assert not (tmp_path / "bu").exists() and not (tmp_path / "rl").exists()
