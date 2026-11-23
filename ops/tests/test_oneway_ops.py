"""test_oneway_ops.py -- oneway_bringup.sh / oneway_measure.sh, desk-side, NO board contact."""
import os, pathlib, subprocess

OPS = pathlib.Path(__file__).resolve().parents[1]


def run(args, env=None):
    e = dict(os.environ); e.update(env or {})
    return subprocess.run(args, text=True, capture_output=True, env=e, cwd=OPS)


def test_bringup_usage_and_role_checks():
    r = run(["bash", str(OPS / "oneway_bringup.sh")])
    assert r.returncode == 2 and "usage" in r.stdout
    r = run(["bash", str(OPS / "oneway_bringup.sh"), "10.0.0.146", "10.0.0.146"])
    assert r.returncode == 2 and "must differ" in r.stdout
    r = run(["bash", str(OPS / "oneway_bringup.sh"), "10.0.0.146", "10.0.0.148", "pcm"])
    assert r.returncode == 2 and "rom|byte" in r.stdout


def test_bringup_dry_run_touches_no_board(tmp_path):
    """DRY=1 with a fake anyssh that would leave a marker: the LO plan is printed,
    only the RX board is gated, the TX board stays ROM-paced, no ssh happens."""
    marker = tmp_path / "ssh"
    fake = tmp_path / "anyssh.sh"; fake.write_text(f"#!/bin/bash\ntouch {marker}\necho up\n"); fake.chmod(0o755)
    ss = tmp_path / "SENTINEL_STOP"
    r = run(["bash", str(OPS / "oneway_bringup.sh"), "10.0.0.146", "10.0.0.148", "byte"],
            env={"DRY": "1", "SENTINEL_STOP_FILE": str(ss), "SSI_TX": "skip"})
    assert r.returncode == 0, r.stdout + r.stderr
    assert "TX=10.0.0.146 (LO 2100000000) -> RX=10.0.0.148 (LO 2100020000)" in r.stdout
    assert "[DRY] gate: probe 10.0.0.148" in r.stdout
    assert "qpsk_tun -B" in r.stdout            # byte source on the TX board
    assert "ONE-WAY BRING-UP COMPLETE" in r.stdout
    assert not marker.exists() and not ss.exists()
    # swapped roles pick the reverse-leg LO pair
    r = run(["bash", str(OPS / "oneway_bringup.sh"), "10.0.0.148", "10.0.0.146"],
            env={"DRY": "1", "SENTINEL_STOP_FILE": str(ss), "SSI_TX": "skip"})
    assert "TX=10.0.0.148 (LO 1850000000) -> RX=10.0.0.146 (LO 1850040000)" in r.stdout   # reverse leg = the pair's 1.85 GHz plan (2026-09-29)


def test_bringup_never_uses_mode1_or_flash_rails():
    s = (OPS / "oneway_bringup.sh").read_text()
    assert "arm148_mode1" not in s.replace("(arm148_mode1.sh, flash_*_txfix.sh rails)", "")
    assert "flash_148_txfix" not in s and "flash_146_txfix" not in s


def test_measure_scoring_math(tmp_path):
    """Feed the rom scorer a synthetic 0x104/0x108/0x144/0x150 trace through a fake anyssh:
    10 clean seconds at 1245 f/s with 3 bit errors, one reset interval excluded."""
    lines = []
    p = 1000; e = 5
    for i in range(12):
        if i == 6:
            p = 10; r = 1          # rstCS reset: 0x104 restarts, 0x150 steps
        else:
            r = 1 if i > 6 else 0
            p += 1245
            if i == 3: e += 3
        lines.append(f"0x{p:08x} 0x{e:08x} 0x04922282 0x{r:08x}")
    fake = tmp_path / "anyssh.sh"
    fake.write_text("#!/bin/bash\ncat <<'EOT'\n" + "\n".join(lines) + "\nEOT\n"); fake.chmod(0o755)
    # the script derives anyssh from its own dir: run a copy next to the fake
    script = tmp_path / "oneway_measure.sh"; script.write_text((OPS / "oneway_measure.sh").read_text()); script.chmod(0o755)
    (tmp_path / "health_probe_reset_aware.sh").write_text("#!/bin/bash\necho fsync=1245 wcnt=1245 resets_s=0 clean=12/12\n")
    r = run(["bash", str(script), "10.0.0.148", "11", "rom"])
    assert r.returncode == 0, r.stdout + r.stderr
    out = r.stdout
    assert "ONEWAY_MEASURE rx=10.0.0.148 src=rom" in out
    assert "clean_s=10 resets_s=1" in out        # 11 intervals, one excluded
    assert "frames=12450 expected=12450 lost=0 PER_est=0.000%" in out
    assert "biterr=3 bits=1494000" in out
    assert "golden_frac=1.000" in out
    assert "denominator=" in out and "lost frames counted" in out


def test_bringup_tun_source_dry_run(tmp_path):
    """The tun source starts the RX-only half first, then the TX-only half, with the
    pair's tun addresses, and flips the TX board to the byte plane (double-tap)."""
    ss = tmp_path / "SENTINEL_STOP"
    r = run(["bash", str(OPS / "oneway_bringup.sh"), "10.0.0.146", "10.0.0.148", "tun"],
            env={"DRY": "1", "SENTINEL_STOP_FILE": str(ss), "SSI_TX": "skip"})
    assert r.returncode == 0, r.stdout + r.stderr
    out = r.stdout
    assert "QPSK_TUN_RXONLY=1" in out and "QPSK_TUN_TXONLY=1" in out
    assert out.index("QPSK_TUN_RXONLY=1") < out.index("QPSK_TUN_TXONLY=1")
    assert "ip addr replace 10.66.0.2 peer 10.66.0.1 dev tun0" in out   # 148 = RX
    assert "ip addr replace 10.66.0.1 peer 10.66.0.2 dev tun0" in out   # 146 = TX
    assert "unbound variable" not in out + r.stderr
    assert "ONE-WAY BRING-UP COMPLETE" in out


def test_daemon_has_the_oneway_tun_knobs():
    """qpsk_tun.c: the two knobs exist, are mutually exclusive, and gate the right sides
    (RX-only never reads the tun / fills keepalives; TX-only never pumps the receiver)."""
    s = (OPS.parent / "host" / "qpsk_tun.c").read_text()
    assert 'getenv("QPSK_TUN_TXONLY")' in s and 'getenv("QPSK_TUN_RXONLY")' in s
    assert "mutually exclusive" in s
    assert "!tun_rxonly && tx_capacity() && tx_credit" in s          # irq loop tun gate
    assert "!tun_rxonly && tx_capacity() && now_s() >= tx_next" in s  # irq loop keepalive
    assert "!tun_txonly && (m = rx_pump_frame(out, &seq)) > 0" in s   # irq loop rx drain
    assert "!tun_txonly && (m = rx_pump_timed(out, &seq)) > 0" in s   # polled loop rx drain
    assert "if (k5_mode && !tun_rxonly)" in s                          # polled keepalive
    assert "tun_txonly ? -1 : rx_uio_fd" in s                          # never wake on RX


def test_measure_tun_usage():
    s = (OPS / "oneway_measure.sh").read_text()
    assert "tun)" in s and "qpsk_perf -s" in s and "qpsk_perf -c" in s
    assert 'src=tun' in s and "tx_pkts-rx_pkts" in s
