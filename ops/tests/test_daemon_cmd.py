"""Every relaunch of qpsk_tun must be the daemon bring-up started (2026-09-29).

148's daemon was relaunched by lock_watchdog from a DAEMON_CMD that lacked `chrt -f 50` and
QPSK_RX_QUEUED. On the default scheduler it left 2-3 ms transmit gaps on air (txgap p99 3071 us) and
the peer receiver latched every few minutes: 14 watchdog re-arms in 1.5 h on a carrier plan that had
just run 5 h at zero. Bring-up now records its launch line on the board (/dev/shm/qpsk_tun.cmd) and
every relaunch path -- the watchdog's default, restore, interrupt_response -- uses it, with a fallback
that carries the same scheduler and RX-mode knobs.
"""
import os
import re

OPS = os.path.join(os.path.dirname(__file__), '..')


def _code(name):
    s = open(os.path.join(OPS, name)).read()
    return "\n".join(l for l in s.splitlines() if not l.lstrip().startswith("#"))


def test_bringup_records_the_launch_and_hands_the_watchdog_the_same_knobs():
    s = _code("bringup_r2r3.sh")
    assert "/dev/shm/qpsk_tun.cmd" in s
    dcmd = re.search(r'DCMD="([^"]+)"', s).group(1)
    for k in ("QPSK_WHITEN=", "QPSK_RX_CYCLIC=", "QPSK_RX_QUEUED=${RXQ:-1}", "chrt -f 50 ./qpsk_tun"):
        assert k in dcmd, k
    wcmd = re.search(r'WCMD="([^"]+)"', s).group(1)
    for k in ("QPSK_WHITEN=", "QPSK_RX_CYCLIC=$WCYC", "QPSK_RX_QUEUED=${RXQ:-1}", "chrt -f 50 ./qpsk_tun"):
        assert k in wcmd, k
    # per-board cyclic mode mirrors start_daemon: B takes RXCYC, A takes RXCYC_A
    assert 'WCYC=0; [ "$ip" = "$B" ] && WCYC=${RXCYC:-0}; [ "$ip" = "$A" ] && WCYC=${RXCYC_A:-0}' in s


def test_watchdog_defaults_to_the_recorded_launch_and_has_one_relaunch_path():
    s = _code("lock_watchdog.sh")
    assert 'DAEMON_CMD=${DAEMON_CMD:-$(cat /dev/shm/qpsk_tun.cmd 2>/dev/null)}' in s
    assert 'eval "$DAEMON_CMD"' not in s, "a bare eval ran from the watchdog's cwd, where ./qpsk_tun does not exist"
    assert s.count("relaunch_daemon") >= 4          # the definition + dead-daemon + 2 wedge paths
    assert 'cd /root/host_app_k5 2>/dev/null; setsid nohup sh -c "$DAEMON_CMD"' in s


def test_restore_and_interrupt_response_prefer_the_recorded_launch():
    for name in ("restore_known_good.sh", "interrupt_response.sh"):
        s = _code(name)
        assert "cat /dev/shm/qpsk_tun.cmd" in s, name
        fb = re.search(r'C="(QPSK_WHITEN=1[^"]+)"', s).group(1)
        assert "QPSK_RX_QUEUED=1" in fb and "chrt -f 50 ./qpsk_tun" in fb, name


def test_rearm_log_line_carries_a_register_snapshot():
    s = _code("lock_watchdog.sh")
    line = [l for l in s.splitlines() if 'log "FULL RE-ARM' in l][0]
    for reg in ("0x104", "0x150", "0x154", "0x1C0", "0x25C"):
        assert f"{reg}=$(rd {reg})" in line, reg
    # the ledger still keys on the line's prefix
    assert line.strip().startswith('log "FULL RE-ARM (0x000 soft reset')


def test_relaunch_reapplies_the_tun_network_config():
    """2026-10-04: a watchdog relaunch (DELIVERY-WEDGE path on 146) created a fresh tun0 with no address;
    the capture rail's qpsk_perf had nowhere to send and every leg read 0 f/s on every image. Bring-up
    records the ip addr/link/route lines; relaunch_daemon re-applies them after the interface appears."""
    b = _code("bringup_r2r3.sh")
    assert "/dev/shm/qpsk_tun.net" in b and "ip addr replace $2 peer $3 dev tun0" in b
    w = _code("lock_watchdog.sh")
    assert 'DAEMON_NET=${DAEMON_NET:-/dev/shm/qpsk_tun.net}' in w
    body = w[w.find("relaunch_daemon(){"):]
    body = body[:body.find("rearm_once()")]
    assert 'ip link show tun0' in body and 'sh -c "$(cat "$DAEMON_NET")"' in body
    assert "tun0 net config re-applied" in body
