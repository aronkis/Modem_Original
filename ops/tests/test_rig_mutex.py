#!/usr/bin/env python3
"""test_rig_mutex.py -- plan 2026-09-25-rig-instability Task 1: ONE rig mutex, enforced at the
chokepoint every board access flows through (ops/anyssh.sh).

The 2026-09-25 incident: a settle-timer's direct_reg_access reads collided with the sentinel's own
recovery chain (which arms both boards) and board 148 hung, needing a physical power cycle. The
mutex already existed (ops/sim_repro/riglock.sh) and nothing enforced it.

NO BOARD CONTACT: `ssh` is a fake on PATH that records that it was called.
"""
import os
import pathlib
import subprocess
import stat

import pytest

OPS = pathlib.Path(__file__).resolve().parents[1]
ANYSSH = OPS / "anyssh.sh"
RIGLOCK = OPS / "sim_repro" / "riglock.sh"
RIGPROBE = OPS / "rigprobe.sh"


def _fake_ssh(tmp_path):
    """A PATH shim: records invocation, never reaches a board."""
    marker = tmp_path / "ssh_was_called"
    d = tmp_path / "bin"; d.mkdir(exist_ok=True)
    f = d / "ssh"
    f.write_text(f"#!/bin/sh\ntouch {marker}\nexit 0\n")
    f.chmod(f.stat().st_mode | stat.S_IEXEC)
    return d, marker


def run_anyssh(tmp_path, lock_text=None, owner=None, bypass=False, cmd="echo up"):
    d, marker = _fake_ssh(tmp_path)
    lock = tmp_path / "RIG_LOCK"
    if lock_text is not None:
        lock.write_text(lock_text)
    env = dict(os.environ, PATH=f"{d}:{os.environ['PATH']}", RIG_LOCK=str(lock))
    if owner is not None:
        env["RIG_LOCK_OWNER"] = owner
    if bypass:
        env["RIG_LOCK_BYPASS"] = "1"
    r = subprocess.run([str(ANYSSH), "10.0.0.148", cmd], capture_output=True, text=True, env=env)
    return r, marker


def test_foreign_lock_refuses_before_any_ssh(tmp_path):
    r, marker = run_anyssh(tmp_path, lock_text="owner=gate3-sp4 pid=999 since=2026-09-25_17:00:00\n")
    assert r.returncode == 3, (r.returncode, r.stdout, r.stderr)
    assert "RIG_LOCKED" in (r.stdout + r.stderr)
    assert not marker.exists(), "ssh must not be reached while a foreign lock is held"


def test_own_lock_passes(tmp_path):
    r, marker = run_anyssh(tmp_path, lock_text="owner=my-rail pid=999 since=x\n", owner="my-rail")
    assert r.returncode == 0, (r.returncode, r.stdout, r.stderr)
    assert marker.exists(), "the lock holder's own calls must pass"


def test_no_lock_passes(tmp_path):
    r, marker = run_anyssh(tmp_path)
    assert r.returncode == 0 and marker.exists()


def test_bypass_is_honoured_and_announced(tmp_path):
    r, marker = run_anyssh(tmp_path, lock_text="owner=someone pid=1 since=x\n", bypass=True)
    assert r.returncode == 0 and marker.exists()
    assert "RIG_LOCK_BYPASS" in (r.stdout + r.stderr), "an emergency bypass must be loud"


def test_rig_lock_exports_owner_for_children():
    """rig_lock must export RIG_LOCK_OWNER so the holder's child processes pass the guard."""
    s = RIGLOCK.read_text()
    assert "export RIG_LOCK_OWNER" in s


def test_rig_lock_still_refuses_a_foreign_lock_and_owns_sentinel(tmp_path):
    """Env MUST be passed via env=, never as inline `VAR=v . file` assignments: those do not reach
    the sourced file's parameter expansion here, so the helper falls back to the REAL
    /home/tcollins/modem-status paths and the test would take a live rig lock and sentinel hold."""
    lock = tmp_path / "RIG_LOCK"; ss = tmp_path / "SENTINEL_STOP"
    env = dict(os.environ, RIG_LOCK=str(lock), SENTINEL_STOP_FILE=str(ss))
    lock.write_text("owner=other pid=1 since=x\n")
    r = subprocess.run(["bash", "-c", f'. {RIGLOCK}; rig_lock mine; echo TOOK'],
                       capture_output=True, text=True, env=env)
    assert r.returncode == 3 and "RIG_LOCKED" in r.stdout and "TOOK" not in r.stdout, r.stdout
    assert lock.read_text().startswith("owner=other"), "must not steal a foreign lock"
    # with no foreign lock it takes both and releases only what it created
    lock.unlink()
    r = subprocess.run(["bash", "-c",
                        f'. {RIGLOCK}; rig_lock mine; test -e "$RIG_LOCK" && test -e "$RIG_SS" && echo HELD; '
                        f'echo "owner=$RIG_LOCK_OWNER"; rig_unlock; '
                        f'{{ test -e "$RIG_LOCK" || test -e "$RIG_SS"; }} || echo RELEASED'],
                       capture_output=True, text=True, env=env)
    assert "HELD" in r.stdout and "RELEASED" in r.stdout, r.stdout
    assert "owner=mine" in r.stdout, "rig_lock must export RIG_LOCK_OWNER"
    assert not lock.exists() and not ss.exists()


def test_a_preexisting_sentinel_hold_survives_rig_unlock(tmp_path):
    """The 2026-09-11 rule: never remove a hold you did not create."""
    lock = tmp_path / "RIG_LOCK"; ss = tmp_path / "SENTINEL_STOP"; ss.write_text("operator hold\n")
    env = dict(os.environ, RIG_LOCK=str(lock), SENTINEL_STOP_FILE=str(ss))
    r = subprocess.run(["bash", "-c", f'. {RIGLOCK}; rig_lock mine; rig_unlock; echo DONE'],
                       capture_output=True, text=True, env=env)
    assert "DONE" in r.stdout
    assert ss.read_text() == "operator hold\n", "a pre-existing hold must survive"
    assert not lock.exists()


@pytest.mark.skipif(not RIGPROBE.exists(), reason="rigprobe.sh not implemented yet")
def test_rigprobe_takes_the_lock_and_releases_it(tmp_path):
    d, marker = _fake_ssh(tmp_path)
    lock = tmp_path / "RIG_LOCK"; ss = tmp_path / "SENTINEL_STOP"
    env = dict(os.environ, PATH=f"{d}:{os.environ['PATH']}", RIG_LOCK=str(lock),
               SENTINEL_STOP_FILE=str(ss))
    r = subprocess.run([str(RIGPROBE), "10.0.0.148", "0x104", "0x25C"],
                       capture_output=True, text=True, env=env)
    assert r.returncode == 0, r.stdout + r.stderr
    assert marker.exists(), "rigprobe must actually read"
    assert not lock.exists() and not ss.exists(), "rigprobe must release what it took"
    assert "RIGPROBE" in r.stdout


def test_rigprobe_refuses_under_a_foreign_lock(tmp_path):
    if not RIGPROBE.exists():
        pytest.skip("rigprobe.sh not implemented yet")
    d, marker = _fake_ssh(tmp_path)
    lock = tmp_path / "RIG_LOCK"; lock.write_text("owner=gate3 pid=1 since=x\n")
    env = dict(os.environ, PATH=f"{d}:{os.environ['PATH']}", RIG_LOCK=str(lock))
    r = subprocess.run([str(RIGPROBE), "10.0.0.148", "0x104"], capture_output=True, text=True, env=env)
    assert r.returncode == 3 and not marker.exists()
    assert lock.read_text().startswith("owner=gate3"), "must not steal a foreign lock"


RAILS = ["gate3_pair.sh", "gate3_run.sh", "oneway_hw_verify.sh", "capture_r3.sh"]


@pytest.mark.parametrize("rail", RAILS)
def test_rail_takes_and_releases_the_rig_lock(rail):
    """Task 2: every campaign rail holds the mutex for its whole run, so ad-hoc board access is
    refused at anyssh while it owns the rig. Their own SENTINEL_STOP handling is left untouched."""
    s = (OPS / rail).read_text()
    assert "sim_repro/riglock.sh" in s, f"{rail} must source the mutex"
    assert "rig_lock_only" in s and "rig_unlock_only" in s, rail
    # the release must be reachable: no `return` before it on the same line
    for line in s.splitlines():
        if "rig_unlock_only" in line and "release(){" in line:
            assert line.index("rig_unlock_only") < line.find("return 0"), f"{rail}: unlock unreachable"


def test_nesting_a_rail_inside_a_rail_does_not_release_the_parents_lock(tmp_path):
    """gate3_pair holds the lock and calls capture_r3.sh, which takes it again. The inner unlock
    must NOT release the outer lock -- ownership is by name, not pid."""
    lock = tmp_path / "RIG_LOCK"
    env = dict(os.environ, RIG_LOCK=str(lock))
    script = (f'. {RIGLOCK}\n'
              'rig_lock_only outer; echo "outer_nested=${RIG_LOCK_NESTED}"\n'
              '( . ' + str(RIGLOCK) + '; rig_lock_only outer; echo "inner_nested=${RIG_LOCK_NESTED}"; rig_unlock_only )\n'
              'test -e "$RIG_LOCK" && echo OUTER_STILL_HELD\n'
              'rig_unlock_only; test -e "$RIG_LOCK" || echo OUTER_RELEASED\n')
    r = subprocess.run(["bash", "-c", script], capture_output=True, text=True, env=env)
    assert "outer_nested=0" in r.stdout and "inner_nested=1" in r.stdout, r.stdout
    assert "OUTER_STILL_HELD" in r.stdout, "the nested unlock released the parent's lock"
    assert "OUTER_RELEASED" in r.stdout, r.stdout


def test_a_foreign_rail_is_refused(tmp_path):
    lock = tmp_path / "RIG_LOCK"; lock.write_text("owner=someone-else pid=1 since=x\n")
    r = subprocess.run(["bash", "-c", f'. {RIGLOCK}; rig_lock_only mine; echo TOOK'],
                       capture_output=True, text=True, env=dict(os.environ, RIG_LOCK=str(lock)))
    assert r.returncode == 3 and "TOOK" not in r.stdout and "RIG_LOCKED" in r.stdout


def test_capture_r3_standalone_also_holds_the_sentinel():
    """Task 8 validation finding: the lock alone left the sentinel probing, its probes refused, and
    it escalated to a recovery that was also refused -- churn and spurious failures in its log.
    Holding SENTINEL_STOP makes it exit cleanly, and a hold we did not create is never removed."""
    s = (OPS / "capture_r3.sh").read_text()
    assert "CR3_SS_MINE" in s and "SENTINEL_STOP pre-exists" in s
    assert "trap cr3_release EXIT" in s
    rel = s[s.index("cr3_release(){"):]
    rel = rel[:rel.index("\n")]
    assert "rig_unlock_only" in rel and 'CR3_SS_MINE" = 1' in rel, rel

