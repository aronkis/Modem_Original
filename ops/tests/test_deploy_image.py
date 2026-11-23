"""deploy_image.sh (2026-10-02): DRY=1 resolves the image and touches nothing; a real run holds
SENTINEL_STOP for the flash+reboot and releases only the hold it created. No board contact: the DRY path
exits before any ssh, and the hold logic is pinned by text (the real path cannot run on the desk)."""
import os
import subprocess

OPS = os.path.join(os.path.dirname(__file__), '..')


def test_dry_resolves_role_and_touches_nothing(tmp_path):
    ss = tmp_path / "SENTINEL_STOP"
    r = subprocess.run(["bash", os.path.join(OPS, "deploy_image.sh"), "10.0.0.148", "A"], capture_output=True, text=True,
                       env=dict(os.environ, DRY="1", SENTINEL_STOP_FILE=str(ss), HOME=str(tmp_path)))
    assert r.returncode == 0, r.stdout + r.stderr
    assert "DEPLOY_IMAGE_DRY ip=10.0.0.148" in r.stdout and "nothing touched" in r.stdout
    assert "role A:" in r.stdout and "size=7203552" in r.stdout
    assert not ss.exists(), "DRY must not take the sentinel hold"
    assert "FLASHED" not in r.stdout and "rebooting" not in r.stdout


def test_dry_rejects_a_missing_image(tmp_path):
    r = subprocess.run(["bash", os.path.join(OPS, "deploy_image.sh"), "10.0.0.148", str(tmp_path / "nope.bin")], capture_output=True, text=True,
                       env=dict(os.environ, DRY="1"))
    assert r.returncode == 0 and "size=0" in r.stdout and "nothing touched" in r.stdout


def test_real_path_holds_the_sentinel_and_releases_only_its_own():
    s = open(os.path.join(OPS, "deploy_image.sh")).read()
    code = "\n".join(l for l in s.splitlines() if not l.lstrip().startswith("#"))
    assert 'SS_FILE=${SENTINEL_STOP_FILE:-$HOME/modem-status/SENTINEL_STOP}; SS_MINE=0' in code
    assert 'SENTINEL_STOP pre-exists' in code and 'SS_MINE=1' in code
    assert '[ "$SS_MINE" = 1 ] && rm -f "$SS_FILE"' in code and 'trap release_hold EXIT' in code
    # the hold is taken before the first board write and after the DRY exit
    assert code.index('DEPLOY_IMAGE_DRY') < code.index('SS_MINE=1') < code.index('scpput "$BOOT"')
