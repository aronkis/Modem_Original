"""test_degraded_capture.py -- ops/degraded_capture.sh, the trigger's ACTION.

It arms both boards unattended, so the tests replace capture_r3.sh with a stub and assert on the
two things that decide whether the run is worth anything:

  * GATE_DIR=A must reach the bring-up. The arm gate requires BOTH receivers at the floor, and
    during a reverse episode 146 is exactly the side that cannot make it; without this the capture
    burns six arm re-rolls and yields nothing (measured 2026-09-25/26).
  * the verdict must say whether the leg was STILL degraded while we watched, because the capture's
    own bring-up re-arms both boards and could have cleared the episode it was sent to observe.
"""
import os
import pathlib
import subprocess

OPS = pathlib.Path(__file__).resolve().parents[1]
ACT = OPS / "degraded_capture.sh"


def stub_env(tmp_path, accept_line=None, rc=0):
    """A fake ops/ tree: capture_r3.sh and accept_analyze.py are stubs, nothing touches a board."""
    d = tmp_path / "ops"; d.mkdir()
    (d / "degraded_capture.sh").write_text(ACT.read_text()); (d / "degraded_capture.sh").chmod(0o755)
    cap = d / "capture_r3.sh"
    cap.write_text(
        "#!/bin/bash\n"
        'echo "CAPTURE_R3_CALLED args=$* RUNG=${RUNG:-unset} GATE_DIR=${GATE_DIR:-unset}" '
        '>> "$CAPTURE_WITNESS"\n'
        # -o <dir> is the last pair; drop a frames.bin there when asked to
        'while [ $# -gt 0 ]; do [ "$1" = "-o" ] && out=$2; shift; done\n'
        '[ -n "${MAKE_FRAMES:-}" ] && { mkdir -p "$out"; printf x > "$out/frames.bin"; }\n'
        f"exit {rc}\n")
    cap.chmod(0o755)
    acc = d / "accept_analyze.py"
    acc.write_text("#!/usr/bin/env python3\nimport os\nprint(os.environ.get('ACCEPT_LINE',''))\n")
    acc.chmod(0o755)
    env = dict(os.environ, CAPTURE_WITNESS=str(tmp_path / "witness"), DUR="60")
    if accept_line is not None:
        env["ACCEPT_LINE"] = accept_line
        env["MAKE_FRAMES"] = "1"
    return d, env


def run(tmp_path, accept_line=None, rc=0, **extra):
    d, env = stub_env(tmp_path, accept_line, rc)
    env.update({k: str(v) for k, v in extra.items()})
    ep = tmp_path / "episode"
    r = subprocess.run(["bash", str(d / "degraded_capture.sh"), str(ep)],
                       capture_output=True, text=True, env=env)
    verdict = ep / "CAPTURE_VERDICT.txt"
    return r, (verdict.read_text() if verdict.exists() else ""), tmp_path / "witness"


def test_gate_dir_is_scoped_to_the_forward_direction(tmp_path):
    r, _, wit = run(tmp_path, accept_line="live 60s/60s  PER=9.000% (100/1111)")
    line = wit.read_text()
    assert "GATE_DIR=A" in line, line     # without this the bring-up cannot complete
    assert "RUNG=r3" in line
    assert "args=B " in line and "-d 60" in line and "-k" in line


def test_still_degraded_is_recognised(tmp_path):
    r, v, _ = run(tmp_path, accept_line="live 60s/60s  PER=9.000% (100/1111)")
    assert "STILL DEGRADED" in v and "the episode was captured" in v


def test_recovered_is_called_out_as_the_aftermath_not_the_event(tmp_path):
    """The bring-up re-arms both boards; if that cleared the episode the data is not of the event."""
    r, v, _ = run(tmp_path, accept_line="live 60s/60s  PER=0.100% (1/1111)")
    assert "RECOVERED" in v and "aftermath, not the event" in v


def test_marginal_is_neither(tmp_path):
    r, v, _ = run(tmp_path, accept_line="live 60s/60s  PER=3.000% (30/1111)")
    assert "MARGINAL" in v


def test_no_frames_is_unknown_not_recovered(tmp_path):
    """A capture that produced nothing must never be scored as a healthy link."""
    r, v, _ = run(tmp_path, rc=3)
    # check the episode_state LINE, not the whole file: the explanatory note mentions RECOVERED
    state = [l for l in v.splitlines() if l.startswith("episode_state=")][0]
    assert "UNKNOWN" in state and "RECOVERED" not in state, state
    assert "capture_r3_rc=3" in v
    assert r.returncode == 3


def test_capture_dir_exists_before_the_redirect(tmp_path):
    """Regression: redirecting through "$DIR/capture/.." before that dir existed meant the redirect
    failed and capture_r3.sh never ran."""
    r, _, wit = run(tmp_path, accept_line="live 60s/60s  PER=9.000% (100/1111)")
    assert wit.exists() and "CAPTURE_R3_CALLED" in wit.read_text()
    assert (tmp_path / "episode" / "capture_r3.out").exists()


def test_dry_touches_nothing(tmp_path):
    r, v, wit = run(tmp_path, DRY=1)
    assert "dry=1" in v
    assert not wit.exists(), "DRY must not invoke capture_r3.sh"


# ---- second stage: the PHY-only measurement in the same window (2026-09-27) ---------------------
def stub_air(d, verdict="ROM_AIR_BER_OK", rc=0):
    """Stand in for rom_air_ber.sh: writes the log line and a TSV the caller has to pick up."""
    p = d / "rom_air_ber.sh"
    p.write_text(
        "#!/bin/bash\n"
        'mkdir -p "$OUT"\n'
        f'echo "{verdict} results=$OUT/rom_air_ber.tsv" >> "$OUT/rom_air_ber.log"\n'
        'printf "board\\tleg\\tstage\\terrs\\n10.0.0.148\\tforward\\trom_r1\\t0\\n'
        '10.0.0.146\\treverse\\trom_r1\\t394331\\n" > "$OUT/rom_air_ber.tsv"\n'
        f"exit {rc}\n")
    p.chmod(0o755)
    return p


def test_air_ber_stage_is_off_by_default(tmp_path):
    d, env = stub_env(tmp_path, accept_line="live 60s/60s  PER=9.000% (100/1111)")
    stub_air(d)
    ep = tmp_path / "episode"
    r = subprocess.run(["bash", str(d / "degraded_capture.sh"), str(ep)],
                       capture_output=True, text=True, env=env)
    assert "AIR_BER_DONE" not in r.stdout
    assert not (ep / "PAIR_SUMMARY.txt").exists()


def test_air_ber_stage_runs_and_pairs_the_two_measurements(tmp_path):
    d, env = stub_env(tmp_path, accept_line="live 60s/60s  PER=9.000% (100/1111)")
    stub_air(d)
    env["AIR_BER"] = "1"
    ep = tmp_path / "episode"
    r = subprocess.run(["bash", str(d / "degraded_capture.sh"), str(ep)],
                       capture_output=True, text=True, env=env)
    assert "AIR_BER_DONE rc=0 ROM_AIR_BER_OK" in r.stdout, r.stdout
    body = (ep / "PAIR_SUMMARY.txt").read_text()
    assert "host-visible (whole stack): live 60s/60s  PER=9.000%" in body
    assert "PHY-only verdict: ROM_AIR_BER_OK" in body
    assert "STILL DEGRADED" in body                      # the capture's verdict travels with it
    assert "10.0.0.146" in body and "reverse" in body     # the TSV is included
    # the caveats that stop the numbers being misread
    assert "FRAME-START damage" in body and "never a link BER" in body
    assert "146 = reverse leg" in body


def test_a_void_air_run_is_not_reported_as_a_clean_phy(tmp_path):
    d, env = stub_env(tmp_path, accept_line="live 60s/60s  PER=9.000% (100/1111)")
    stub_air(d, verdict="ROM_AIR_BER_VOID")
    env["AIR_BER"] = "1"
    ep = tmp_path / "episode"
    r = subprocess.run(["bash", str(d / "degraded_capture.sh"), str(ep)],
                       capture_output=True, text=True, env=env)
    body = (ep / "PAIR_SUMMARY.txt").read_text()
    assert "PHY-only verdict: ROM_AIR_BER_VOID" in body
    assert "NOT evidence of a clean PHY" in body


def test_capture_exit_code_still_reflects_the_capture_not_the_air_stage(tmp_path):
    d, env = stub_env(tmp_path, accept_line="live 60s/60s  PER=9.000% (100/1111)", rc=0)
    stub_air(d, rc=3)
    env["AIR_BER"] = "1"
    ep = tmp_path / "episode"
    r = subprocess.run(["bash", str(d / "degraded_capture.sh"), str(ep)],
                       capture_output=True, text=True, env=env)
    assert r.returncode == 0
    assert "AIR_BER_DONE rc=3" in r.stdout


def test_episode_records_the_receiver_tilt(tmp_path):
    """2026-10-07: every episode scores the degraded receiver's in-band tilt (tilt.json + tilt= line) so a FADED
    day -- the day the tilt corrector's on-air benefit can be measured -- is recognised when it happens."""
    import os, subprocess
    here = os.path.dirname(__file__); script = os.path.join(here, '..', 'degraded_capture.sh')
    s = "\n".join(l for l in open(script).read().splitlines() if not l.lstrip().startswith('#'))
    assert 'tilt_score.py' in s and '"$DIR/tilt.json"' in s and 'echo "tilt=$tilt_line"' in s
    assert 'iio_readdev -u local: -b 32768 -s 262144' in s
    out = subprocess.run(["bash", script, str(tmp_path / "ep")], env={**os.environ, "DRY": "1"}, capture_output=True, text=True).stdout
    assert "tilt snapshot" in out and "tilt.json" in out
