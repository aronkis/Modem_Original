"""test_degraded_trigger.py -- ops/degraded_trigger.sh.

This thing runs unattended. Everything below is about it NOT firing on its own blind spot: a stale
log looks exactly like a dead link, and a dead keeper looks exactly like a quiet one. It must also
never touch a board, which is why every test points it at temp files and asserts no ssh happened.

Env is passed via subprocess env=, never as an inline VAR=x in front of the script: an inline
assignment does not reach a sourced file and the real rig paths get used instead. That trap once
took a live rig lock.
"""
import datetime
import os
import pathlib
import subprocess

OPS = pathlib.Path(__file__).resolve().parents[1]
TRIG = OPS / "degraded_trigger.sh"


def sample(dt, rev, rtx=1245, rate=1245, tx=1245, crc=100.0, rcrc=100.0):
    return (f"{dt:%Y-%m-%d_%H:%M:%S} ok rate={rate}/s crc={crc}% tx={tx}/s "
            f"rev={rev}/s rcrc={rcrc}% rtx={rtx}/s")


def make_log(p, revs, newest_age_s=60, step_s=300):
    """Write len(revs) samples ending newest_age_s ago, oldest first."""
    now = datetime.datetime.now()
    lines = []
    for i, rv in enumerate(revs):
        age = newest_age_s + (len(revs) - 1 - i) * step_s
        lines.append(sample(now - datetime.timedelta(seconds=age), rv))
    p.write_text("\n".join(lines) + "\n")
    return p


def run(tmp_path, log, **env):
    fake_ssh = tmp_path / "anyssh.sh"
    fake_ssh.write_text("#!/bin/sh\necho BOARD_CONTACT >&2; exit 97\n"); fake_ssh.chmod(0o755)
    out = tmp_path / "out"
    e = dict(os.environ, ONESHOT="1", LOG=str(log), OUT=str(out), KEEPER_CHECK="0",
             RIG_LOCK=str(tmp_path / "nolock"), SS_FILE=str(tmp_path / "nostop"),
             ANYSSH=str(fake_ssh), HOME=str(tmp_path))
    e.update({k: str(v) for k, v in env.items()})
    r = subprocess.run(["bash", str(TRIG)], capture_output=True, text=True, env=e)
    assert "BOARD_CONTACT" not in r.stdout + r.stderr, "the trigger must never touch a board"
    return r, out


def fired(out):
    return sorted(out.glob("episode_*/EPISODE.txt"))


def test_fires_on_a_sustained_episode(tmp_path):
    log = make_log(tmp_path / "s.log", [100] * 5)      # 5 consecutive samples at 100/1245 = 0.08
    r, out = run(tmp_path, log)
    assert "DEGRADED_EPISODE" in r.stdout, r.stdout
    got = fired(out)
    assert len(got) == 1
    body = got[0].read_text()
    assert "ratio_now=0.080" in body
    assert "record-only" in r.stdout        # no ACTION set -> nothing is run


def test_does_not_fire_on_a_single_sample_blip(tmp_path):
    # 68 of 93 measured episodes were a single sample; those must not fire
    log = make_log(tmp_path / "s.log", [1245, 1245, 100, 1245, 1245])
    r, out = run(tmp_path, log)
    assert not fired(out)
    assert "DEGRADED_EPISODE" not in r.stdout


def test_fires_on_a_fluctuating_episode_with_one_good_sample(tmp_path):
    """Retuned 2026-09-27: real episodes fluctuate. Demanding all five below threshold missed the
    09-27 13:10 stretch (ratios 0.91 0.90 0.94 0.40 0.89 0.81 0.58 0.60 0.21 0.66) while reverse CRC
    was at 48 %. The rule is now 4 of the last 5 below 0.75."""
    log = make_log(tmp_path / "s.log", [700, 700, 1245, 700, 700])   # 4 of 5 at 0.562, one at 1.0
    r, out = run(tmp_path, log)
    assert fired(out), r.stdout


def test_does_not_fire_when_fewer_than_min_bad(tmp_path):
    log = make_log(tmp_path / "s.log", [700, 1245, 1245, 700, 700])  # only 3 of 5 below
    r, out = run(tmp_path, log)
    assert not fired(out)


def test_samples_between_the_two_thresholds_still_count(tmp_path):
    """0.75 is the threshold the availability measurement uses for "degraded"; samples at 0.6 are
    degraded even though they are above the old 0.5 trigger point."""
    log = make_log(tmp_path / "s.log", [747] * 5)   # 747/1245 = 0.600
    r, out = run(tmp_path, log)
    assert fired(out)
    # a SEPARATE output dir: reusing the first run's would find its episode and pass vacuously
    out2 = tmp_path / "out_old_setting"
    r2, _ = run(tmp_path, log, THRESH=0.5, OUT=str(out2))
    assert not fired(out2), "THRESH=0.5 must ignore a 0.60 sample"


def test_stale_log_stands_down_instead_of_firing(tmp_path):
    """A dead sentinel leaves a last line that looks like a dead link. This is the failure mode."""
    log = make_log(tmp_path / "s.log", [0] * 5, newest_age_s=2400)
    r, out = run(tmp_path, log, CONSEC=5, FRESH_S=700)
    assert not fired(out)
    assert "stale log, not a dead link" in r.stdout, r.stdout


def test_rig_lock_stands_down(tmp_path):
    log = make_log(tmp_path / "s.log", [0] * 5)
    lock = tmp_path / "LOCK"; lock.write_text("owner=someone-else pid=1\n")
    r, out = run(tmp_path, log, CONSEC=5, RIG_LOCK=str(lock))
    assert not fired(out)
    assert "RIG_LOCK present" in r.stdout


def test_sentinel_stop_stands_down(tmp_path):
    log = make_log(tmp_path / "s.log", [0] * 5)
    ss = tmp_path / "STOP"; ss.write_text("hold\n")
    r, out = run(tmp_path, log, CONSEC=5, SS_FILE=str(ss))
    assert not fired(out)
    assert "rig work in progress" in r.stdout


def test_missing_keeper_stands_down(tmp_path):
    log = make_log(tmp_path / "s.log", [0] * 5)
    r, out = run(tmp_path, log, CONSEC=5, KEEPER_CHECK=1, KEEPER_UNIT="no-such-unit-xyz*")
    assert not fired(out)
    assert "keeper unit not active" in r.stdout


def test_too_few_samples_stands_down(tmp_path):
    log = make_log(tmp_path / "s.log", [0, 0])
    r, out = run(tmp_path, log, CONSEC=5)
    assert not fired(out)
    assert "need 5" in r.stdout


def test_record_carries_the_context_a_human_needs(tmp_path):
    log = make_log(tmp_path / "s.log", [100] * 6)
    r, out = run(tmp_path, log, CONSEC=5)
    body = fired(out)[0].read_text()
    for k in ("fired_at=", "trigger=rev/rtx < 0.75", "ratio_now=", "cross_now=",
              "episode_observed_min=", "standdown_checks=passed", "sample_age_s=",
              "last 20 sentinel samples"):
        assert k in body, k
    # the record must not claim a check it did not make (these tests run with KEEPER_CHECK=0)
    assert "keeper NOT CHECKED" in body, body
    # and it says plainly that the trigger quantity is not a delivery ratio
    assert "NOT a delivery ratio" in body


def test_cross_board_ratio_is_only_reported_when_modes_match(tmp_path):
    """tx=1245 against rtx=1868 is the 1.5x window artefact; a cross-board ratio is invalid there."""
    now = datetime.datetime.now()
    lines = [f"{now - datetime.timedelta(seconds=60 + i*300):%Y-%m-%d_%H:%M:%S} ok rate=1868/s "
             f"crc=100.0% tx=1868/s rev=100/s rcrc=8.0% rtx=1245/s" for i in range(5)][::-1]
    log = tmp_path / "s.log"; log.write_text("\n".join(lines) + "\n")
    r, out = run(tmp_path, log, CONSEC=5)
    body = fired(out)[0].read_text()
    assert "different window modes" in body


def test_action_runs_only_when_configured(tmp_path):
    log = make_log(tmp_path / "s.log", [100] * 5)
    marker = tmp_path / "ran"
    r, out = run(tmp_path, log, CONSEC=5, ACTION=f"touch {marker}")
    assert marker.exists(), r.stdout
    assert "running ACTION" in r.stdout


# ---- the cooldown must survive a restart (2026-09-27) -------------------------------------------
# An in-memory-only cooldown resets on every unit restart; two restarts that afternoon each produced
# an immediate extra capture while the link happened to be degraded, which is precisely the
# unattended board arming the cooldown exists to bound.
def test_cooldown_survives_a_restart(tmp_path):
    log = make_log(tmp_path / "s.log", [100] * 5)
    r, out = run(tmp_path, log)
    assert len(fired(out)) == 1, r.stdout
    r2, out2 = run(tmp_path, log)          # a fresh process, same OUT: must NOT fire again
    assert len(fired(out2)) == 1, r2.stdout
    assert "cooldown carried over" in r2.stdout


def test_cooldown_expires_and_lets_it_fire_again(tmp_path):
    log = make_log(tmp_path / "s.log", [100] * 5)
    r, out = run(tmp_path, log)
    assert len(fired(out)) == 1
    r2, _ = run(tmp_path, log, COOLDOWN_S=0)
    # a same-second second firing gets an _N suffix rather than overwriting the first record
    assert len(fired(out)) == 2, r2.stdout + "\n" + str(sorted(p.name for p in out.iterdir()))


def test_a_corrupt_stamp_does_not_wedge_the_trigger(tmp_path):
    log = make_log(tmp_path / "s.log", [100] * 5)
    out = tmp_path / "out"; out.mkdir()
    (out / ".last_fire").write_text("not-a-number\n")
    r, _ = run(tmp_path, log)
    assert len(fired(out)) == 1, r.stdout


def test_record_warns_that_ratio_now_may_exceed_the_threshold(tmp_path):
    """Observed live: it fired with ratio_now=0.791 against a 0.75 threshold, because the newest
    sample is not the window the rule tested."""
    log = make_log(tmp_path / "s.log", [700, 700, 700, 700, 1245])
    r, out = run(tmp_path, log)
    body = fired(out)[0].read_text()
    assert "may sit ABOVE the threshold" in body
