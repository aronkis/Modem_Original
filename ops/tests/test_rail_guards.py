#!/usr/bin/env python3
"""test_rail_guards.py -- the four rail defects closed on 2026-09-11, EXECUTED at
the desk with NO BOARD CONTACT.

  1. arm148_mode1.sh refuses B != 10.0.0.148 (exit 2, ARM_FATAL) BEFORE any ssh
     -- it hung 146 on 2026-09-10.
  2. riglock.sh: rig_unlock removes SENTINEL_STOP only when rig_lock created it;
     an operator hold that pre-existed survives the unlock.
  3. flash_146_txfix.sh takes SENTINEL_STOP ownership like the 148 rail (SS_MINE)
     and never touches it under DRY=1 (checked by a DRY run against a
     temp SENTINEL_STOP_FILE that must stay exactly as it was).
  4. capture_r3.sh -k relaunches the watchdogs it killed at step 3 (static:
     the -k branch carries the lock_watchdog relaunch; a board-free run of
     capture_r3 is not possible).
"""
import os, re, subprocess, tempfile, pathlib

OPS = pathlib.Path(__file__).resolve().parents[1]
ROOT = OPS.parent


def run(cmd, env=None, cwd=None):
    e = dict(os.environ); e.update(env or {})
    return subprocess.run(cmd, cwd=cwd or ROOT, env=e, text=True,
                          capture_output=True)


def test_arm148_refuses_146_before_any_ssh(tmp_path):
    # W is derived from ROOT; if the guard ever moved after the ssh the fake
    # anyssh below would be executed and leave a marker.
    marker = tmp_path / "ssh_was_called"
    fake = tmp_path / "anyssh.sh"
    fake.write_text(f"#!/bin/bash\ntouch {marker}\necho x\n"); fake.chmod(0o755)
    r = run(["bash", "-c", f'W={fake} B=10.0.0.146 bash {OPS}/flash/arm148_mode1.sh'])
    assert r.returncode == 2, r.stdout + r.stderr
    assert "ARM_FATAL" in r.stdout and "148-ONLY" in r.stdout
    assert not marker.exists()


def test_arm148_accepts_148_past_the_guard(tmp_path):
    # With B=148 the guard passes and the script goes on to the profile
    # discovery, which uses $W from ROOT -- stub ROOT's anyssh by running from a
    # copied tree so no board is touched: the discovery's "ls" returns nothing and
    # the script exits 2 with the PROFILE fatal, not the 148-only fatal.
    tree = tmp_path / "t"; (tree / "ops" / "flash").mkdir(parents=True)
    (tree / "ops" / "anyssh.sh").write_text("#!/bin/bash\nexit 0\n")
    (tree / "ops" / "anyssh.sh").chmod(0o755)
    dst = tree / "ops" / "flash" / "arm148_mode1.sh"
    dst.write_text((OPS / "flash" / "arm148_mode1.sh").read_text()); dst.chmod(0o755)
    r = run(["bash", str(dst)], env={"B": "10.0.0.148"})
    assert r.returncode == 2
    assert "148-ONLY" not in r.stdout and "refusing to arm with an unknown profile" in r.stdout


def _riglock(tmp_path, pre_hold):
    lock = tmp_path / "RIG_LOCK"; ss = tmp_path / "SENTINEL_STOP"
    if pre_hold: ss.write_text("operator hold\n")
    script = f'''set -e
RIG_LOCK={lock}; SENTINEL_STOP_FILE={ss}
source {OPS}/sim_repro/riglock.sh
rig_lock desk_test
[ -e {ss} ] || {{ echo NO_SS_AFTER_LOCK; exit 9; }}
echo "mine=$RIG_SS_MINE"
rig_unlock
[ -e {lock} ] && {{ echo LOCK_LEFT; exit 9; }}
[ -e {ss} ] && echo SS_PRESENT || echo SS_ABSENT
'''
    r = run(["bash", "-c", script])
    assert r.returncode == 0, r.stdout + r.stderr
    return r.stdout


def test_riglock_keeps_an_external_hold(tmp_path):
    out = _riglock(tmp_path, pre_hold=True)
    assert "mine=0" in out and "SS_PRESENT" in out
    assert (tmp_path / "SENTINEL_STOP").read_text() == "operator hold\n"


def test_riglock_releases_its_own_hold(tmp_path):
    out = _riglock(tmp_path, pre_hold=False)
    assert "mine=1" in out and "SS_ABSENT" in out


def test_riglock_refuses_foreign_lock(tmp_path):
    lock = tmp_path / "RIG_LOCK"; lock.write_text("owner=other pid=1 since=x\n")
    r = run(["bash", "-c", f"RIG_LOCK={lock}; SENTINEL_STOP_FILE={tmp_path}/SS; "
                           f"source {OPS}/sim_repro/riglock.sh; rig_lock me"])
    assert r.returncode == 3 and "RIG_LOCKED" in r.stdout


def test_flash146_dry_never_touches_sentinel_stop(tmp_path):
    ss = tmp_path / "SENTINEL_STOP"; ss.write_text("hold\n")
    # A real image + rollback bank are required by the [1/6] file gates even under
    # DRY; use the deployed pair from images/ (read only).
    r = run(["bash", str(OPS / "flash" / "flash_146_txfix.sh")], env={
        "DRY": "1", "FLASH_MD5": "d94b4df391a1", "FLASH_TAG": "sp2B",
        "FLASH_BAK": "9acbe2ebe1db",
        "ROLLBACK_BANK": str(ROOT / "images" / "BOOT.BIN.146.rxfixr4dr1.9acbe2ebe1db"),
        "SENTINEL_STOP_FILE": str(ss)})
    assert "[dry] would touch/remove SENTINEL_STOP" in r.stdout, r.stdout + r.stderr
    assert ss.read_text() == "hold\n"


def test_flash146_owns_sentinel_stop_like_the_148_rail():
    s = (OPS / "flash" / "flash_146_txfix.sh").read_text()
    assert "SS_MINE=1" in s and "trap '[ \"${SS_MINE:-0}\" = 1 ] && rm -f \"$SS_FILE\"' EXIT" in s
    # ownership is taken inside [1/6], before the first board contact (CUR= read)
    assert s.index("SS_MINE=1") < s.index("CUR=$(brd 'md5sum /boot/BOOT.BIN")


def test_capture_r3_keep_relaunches_watchdogs():
    s = (OPS / "capture_r3.sh").read_text()
    m = re.search(r'if \[ "\$KEEP" = 0 \]; then(.*?)\nfi\n', s, re.S)
    assert m, "quiesce block not found"
    else_branch = m.group(1).split("\nelse\n", 1)[1]
    assert "setsid /root/lock_watchdog.sh" in else_branch


def _arm148_with_fake_board(tmp_path, cap_word, env_extra):
    # A fake anyssh that answers the profile discovery and the post-arm read
    # (fps=1248 errps=0 capTAP=<cap_word>) so the script reaches its golden check.
    tree = tmp_path / "t"; (tree / "ops" / "flash").mkdir(parents=True)
    (tree / "ops" / "anyssh.sh").write_text(
        '#!/bin/bash\ncase "$*" in\n'
        '  *"ls /root/"*) echo "/root/lvds_61p44_fdd_jupiter.bin /root/lvds_61p44_fdd_jupiter.json";;\n'
        f'  *"rd 0x104"*) echo "1248 0 {cap_word}";;\n'
        'esac\nexit 0\n')
    (tree / "ops" / "anyssh.sh").chmod(0o755)
    dst = tree / "ops" / "flash" / "arm148_mode1.sh"
    dst.write_text((OPS / "flash" / "arm148_mode1.sh").read_text()); dst.chmod(0o755)
    return run(["bash", str(dst)], env={"B": "10.0.0.148", "ARM_SETTLE": "0", **env_extra})


def test_arm148_gold_any_skips_the_digest_but_keeps_fps(tmp_path):
    # sp3's 0x20C is a beatfix viol_count (0x0 or 0x1 by arm state), not a digest:
    # GOLD=any must accept it and still report ARM_OK on a running link.
    r = _arm148_with_fake_board(tmp_path, "0x0", {"GOLD": "any"})
    assert r.returncode == 0, r.stdout + r.stderr
    assert "not compared (GOLD=any)" in r.stdout and "ARM_OK" in r.stdout


def test_arm148_default_golden_still_rejects_a_foreign_digest(tmp_path):
    r = _arm148_with_fake_board(tmp_path, "0x0", {})
    assert r.returncode == 4 and "ARM_FAIL: capTAP [0] != golden [BCF94856]" in r.stdout


def test_capture_r3_reapplies_sro_sign_after_every_rearm():
    """2026-09-24 (sp4b Gate 3): rearm_byte's 0x000 soft reset clears fixctl 0x208 (sro_sign), which the
    bring-up writes LAST; every re-arm path in capture_r3.sh must re-apply it (else 146 falls back to
    R4B and the reverse leg runs at ~7.9 %)."""
    s = (OPS / "capture_r3.sh").read_text()
    code = [l for l in s.splitlines() if not l.lstrip().startswith("#")]
    rearms = [i for i, l in enumerate(code) if "rearm_byte" in l and "rearm_byte(){" not in l]
    assert len(rearms) >= 2
    assert "sro_reapply(){" in s and "--bringup" in s
    for i in rearms:
        window = "\n".join(code[i:i + 3])
        assert "sro_reapply" in window, code[i]


def test_lock_watchdog_restores_fixctl_after_its_own_rearm():
    """2026-09-25 (sp4b Gate 3): full_rearm's 0x000 clears fixctl 0x208 (sro_sign) from the board,
    with nothing in the host log -- the unlogged third path beside capture_r3.sh's two re-arms.
    It must re-write the shadow word (/dev/shm/fixctl.word, ops/sro_sign.sh's convention)."""
    s = (OPS / "lock_watchdog.sh").read_text()
    assert "restore_fixctl(){" in s and "/dev/shm/fixctl.word" in s
    assert 'echo "0x208 $w" > "$DRA"' in s
    body = s[s.index("full_rearm(){"):]
    body = body[:body.index("\n}")]
    assert "restore_fixctl" in body, "full_rearm must call restore_fixctl"
    # ... after the double-tap, not before the reset
    assert body.index("rearm_once") < body.index("restore_fixctl")


def test_capture_r3_snapshots_the_steering_witness():
    """Every capture's regs_{pre,cap,post} must carry the steering witness (0x25C sro_mode) and the
    fixctl shadow, so a leg's PER can be attributed to the branch that was actually in force."""
    s = (OPS / "capture_r3.sh").read_text()
    snap = s[s.index("snap(){"):]
    snap = snap[:snap.index("2>/dev/null; }") + 14]
    assert "sro_mode=$(rd 0x25C)" in snap and "fixctl.word" in snap



def test_self_mute_knob_and_watchdog_shipping_2026_10_07():
    """SELF_MUTE=1 mutes the receiving board's own TX for a leg (the test that solved the 10-02 forward waves),
    and the bring-up ships ops/lock_watchdog.sh to /root (it used to reach the boards only via provision.sh)."""
    import os
    ops = os.path.join(os.path.dirname(__file__), '..')
    c = "\n".join(l for l in open(os.path.join(ops, 'capture_r3.sh')).read().splitlines() if not l.lstrip().startswith('#'))
    i = c.find('SELF_MUTE'); j = c.find('RX_ATTR_POKE on $RX_IP')
    assert 0 < i < j and 'out_voltage0_hardwaregain=-40' in c[i:j]
    b = "\n".join(l for l in open(os.path.join(ops, 'bringup_r2r3.sh')).read().splitlines() if not l.lstrip().startswith('#'))
    k = b.find('root@$ip:/root/lock_watchdog.sh'); m = b.find('chmod +x /root/lock_watchdog.sh')
    assert 0 < k < m and 'lock_watchdog.sh shipped' in b
