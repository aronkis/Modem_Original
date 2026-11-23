"""ops/release_vivado_archives.sh -- refresh the rolling `development` release assets (images + packaged Vivado projects)."""
import os, subprocess
H = os.path.join(os.path.dirname(__file__), '..', '..')
S = os.path.join(H, 'ops', 'release_vivado_archives.sh')


def test_dry_runs_nothing_and_names_every_asset_class():
    r = subprocess.run(["bash", S], env={**os.environ, "DRY": "1"}, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    out = r.stdout
    assert "[DRY] ssh" in out and "archive sp3tilteq2" in out and "archive sp3clamp004rxo" in out
    up = [l for l in out.splitlines() if "gh release upload development" in l][0]
    for a in ("sp3tilteq2", "sp3clamp004.", "sp3clamp004txo", "sp3clamp004rxo", "Image.6.12", "system-qpsk.148", "system-qpsk.146", "MD5SUMS", "jupiter_qpsk_sp3tilteq2.vivado.zip"):
        assert a in up, a
    assert "--clobber" in up


def test_archive_contents_and_gitignore():
    s = open(S).read()
    for part in ("archive_project", "-exclude_run_results", "ipcore hdlsrc", "system_top.bit", "vivado_prj.xpr"):
        assert part in s, part
    assert "images/release/" in open(os.path.join(H, ".gitignore")).read()
