#!/usr/bin/env python3
"""test_rung_table.py -- sp4 Task 11: rung r4 (f3072 at 2 sps, 30720 ksym, 4 MB carve) in the
ONE rung table ops/rung_table.sh, and the rails that take their rate/geometry from it.
NO BOARD CONTACT: the table is evaluated with bash; the rails are checked statically
(their launch strings are rendered by substituting the table's values)."""
import os
import pathlib
import re
import subprocess

OPS = pathlib.Path(__file__).resolve().parents[1]
TABLE = OPS / "rung_table.sh"


def rung(name):
    r = subprocess.run(["bash", str(TABLE), name], capture_output=True, text=True)
    return r.returncode, dict(l.split("=", 1) for l in r.stdout.split() if "=" in l), r.stderr


def test_r4_values():
    rc, v, _ = rung("r4")
    assert rc == 0
    assert v["KSYM"] == "30720" and v["FPS"] == "1247" and v["GATE_FPS_DEFAULT"] == "1122"
    assert v["PROF"] == "lvds_61p44_fdd_jupiter" and v["FS"] == "61440000"
    assert v["SPS"] == "2" and v["FRAME"] == "f3072" and v["SPF"] == "49268"
    assert v["TUN_GFLAG"] == "-G3" and v["CARVE_MB"] == "4" and v["CARVE_CFLAG"] == "-DQPSK_CARVE_4MB"
    assert v["MTU"] == "3044" and v["ADVMSS"] == "3004" and v["PERF_BPS"] == "30000000"
    # geometry consistency: 24634 slots x 2 sps, ~1247 f/s, MTU = 3056 - 12 header, advmss = MTU - 40
    assert int(v["SPF"]) == 24634 * 2 and round(61.44e6 / int(v["SPF"])) == 1247
    assert int(v["ADVMSS"]) == int(v["MTU"]) - 40


def test_r3_unchanged():
    rc, v, _ = rung("r3")
    assert rc == 0
    assert (v["KSYM"], v["FPS"], v["GATE_FPS_DEFAULT"], v["SPS"], v["FRAME"], v["SPF"]) == \
        ("15360", "1245", "1120", "4", "f1536", "49332")
    assert (v["TUN_GFLAG"], v["CARVE_CFLAG"], v["MTU"], v["ADVMSS"], v["PERF_BPS"]) == \
        ("-G", "-DQPSK_CARVE_2MB", "1516", "1476", "15000000")


def test_unknown_rung_is_fatal():
    rc, v, err = rung("r9")
    assert rc == 2 and "unknown rung" in err and not v


def test_rung_from_ksym():
    out = subprocess.run(["bash", "-c", f". {TABLE}; rung_from_ksym 30720; rung_from_ksym 15360; rung_from_ksym 1 || echo NONE"],
                         capture_output=True, text=True).stdout.split()
    assert out == ["r4", "r3", "NONE"]


def test_bringup_uses_the_table_and_r3_launch_string_is_historic():
    s = (OPS / "bringup_r2r3.sh").read_text()
    assert 'rung_set "$RUNG" || exit 2' in s and '. "$D/rung_table.sh"' in s
    # no rung literal left in the daemon launch / watchdog / tun setup
    launch = re.search(r'\./qpsk_tun \$TUN_GFLAG -M \$\{RXM_EFF\} -r \$KSYM -i tun0 -s 5', s)
    assert launch, "daemon launch must take -G/-G3 and -r from the rung table"
    assert "mtu $MTU" in s and "advmss $ADVMSS" in s
    wcmd = re.search(r'WCMD="QPSK_WHITEN=\$WHITEN QPSK_RX_CYCLIC=\$WCYC QPSK_RX_QUEUED=\$\{RXQ:-1\} \$\{WDENV:\+\$WDENV \}chrt -f 50 (\./qpsk_tun \$TUN_GFLAG -M \$WRXM -r \$KSYM -i tun0 -s 5)"', s)
    assert wcmd
    # rendered at r3 the daemon part of the watchdog relaunch string is the historic one
    _, v, _ = rung("r3")
    rendered = wcmd.group(1).replace("$TUN_GFLAG", v["TUN_GFLAG"]).replace("$WRXM", "16").replace("$KSYM", v["KSYM"])
    assert rendered == "./qpsk_tun -G -M 16 -r 15360 -i tun0 -s 5"
    _, v4, _ = rung("r4")
    rendered4 = wcmd.group(1).replace("$TUN_GFLAG", v4["TUN_GFLAG"]).replace("$WRXM", "16").replace("$KSYM", v4["KSYM"])
    assert rendered4 == "./qpsk_tun -G3 -M 16 -r 30720 -i tun0 -s 5"
    # r4 pre-flight is strict (FATAL) and runs before the arm
    assert "rung_preflight $B; rung_preflight $A" in s
    assert s.index("rung_preflight $B") < s.index("arm_rom $B $LO_B_TX $LO_B_RX &")
    assert 'usage: bringup_r2r3.sh r2|r3|r4' in s


def test_capture_rail_takes_the_rung():
    s = (OPS / "capture_r3.sh").read_text()
    code = "\n".join(l for l in s.splitlines() if not l.lstrip().startswith("#"))
    assert "-DQPSK_CARVE_2MB" not in code and "SPF_F1536" not in code and "15000000" not in code
    assert 'rung_set "$RUNG" || exit 2' in code
    assert 'RUNG=$(rung_from_ksym "${KS:-}")' in code and "set RUNG=r3|r4" in code
    assert '"$D/bringup_r2r3.sh" "$RUNG"' in code
    assert "gcc -O2 -Wall $CARVE_CFLAG" in code and "-b $PERF_BPS" in code
    assert "rung=$RUNG profile=$PROF" in code and "ksym=$KSYM sps=$SPS fs=$FS spf=$SPF frame=$FRAME carve_mb=$CARVE_MB" in code
    assert "--spf $SPF --pair" in code
    # the live dtb carve is checked before the on-board build
    assert code.index("live dtb carve is") < code.index("gcc -O2 -Wall $CARVE_CFLAG")


def test_restore_and_provision_take_the_rung():
    s = (OPS / "restore_known_good.sh").read_text()
    assert 'rung_set "${RUNG:-r3}" || exit 2' in s
    assert "-r 15360" not in "\n".join(l for l in s.splitlines() if not l.lstrip().startswith("#"))
    assert "./qpsk_tun '\"$TUN_GFLAG\"' -M 16 -r '\"$KSYM\"' -i tun0 -s 5" in s
    # and no LO literal: the plan is the rung table's. A LO_B_RX=1900020000 here used to run the
    # reverse receiver at +20 kHz and, after the 1.85 GHz move, would have tripped the pairing guard.
    code = "\n".join(l for l in s.splitlines() if not l.lstrip().startswith("#"))
    assert not re.search(r"\bLO_[AB]_[RT]X=\d", code), "restore must not hard-code an LO into the bring-up"
    p = (OPS / "provision.sh").read_text()
    assert "-DQPSK_CARVE_4MB" in p and "QPSK_CARVE_4MB:-" in p
    assert "live dtb reserves" in p


def test_comb_period_frame_option(tmp_path):
    r = subprocess.run(["python3", str(OPS / "comb" / "comb_period_ms.py"), "--help"], capture_output=True, text=True)
    assert r.returncode == 0 and "--frame" in r.stdout and "f3072" in r.stdout
    src = (OPS / "comb" / "comb_period_ms.py").read_text()
    assert '"f3072": 24634.0 / 30.72e6' in src
    led = (OPS / "loss_ledger.py").read_text()
    assert '"f3072": 49268 / 61.44e6' in led


def test_flash_rail_passes_the_frame_to_ddrcap2_decode():
    s = (OPS / "flash" / "flash_148_txfix.sh").read_text()
    assert '--summary --frame "${QPSK_FRAME:-f1536}"' in s


def test_r4_runs_both_boards_on_the_R4D_steering_branch():
    """docs/evidence/sp4/GATE1.md sec 3a: 'The image must run the R4D branch (sro_sign=1) on both
    boards at this rung'. R4B has no full-edge branch, so at a positive sample-rate offset it goes
    0.00 % / 0.24 % / 22.75 % at 0 / +2.5 / +10 ppm while R4D+R1 stays 0.00 % throughout. The note
    was never carried into plan Task 11, so 148 ran R4B through both sp4 Gate 3 attempts."""
    rc, v, _ = rung("r4")
    assert rc == 0 and v["SRO_SIGN_CONF"].endswith("/profiles/sro_sign.r4.conf")
    conf = pathlib.Path(v["SRO_SIGN_CONF"]).read_text()
    rows = dict(l.split()[:2] for l in conf.splitlines() if l.strip() and not l.startswith("#"))
    assert rows == {"10.0.0.148": "1", "10.0.0.146": "1"}, rows


def test_r2_r3_keep_the_production_steering_profile_untouched():
    for r in ("r2", "r3"):
        rc, v, _ = rung(r)
        assert rc == 0 and v["SRO_SIGN_CONF"].endswith("/profiles/sro_sign.conf")
    rows = dict(l.split()[:2] for l in pathlib.Path(v["SRO_SIGN_CONF"]).read_text().splitlines()
                if l.strip() and not l.startswith("#"))
    assert rows == {"10.0.0.148": "0", "10.0.0.146": "1"}, rows


def test_explicit_sro_sign_conf_in_the_environment_wins():
    r = subprocess.run(["bash", str(TABLE), "r4"], capture_output=True, text=True,
                       env={**os.environ, "SRO_SIGN_CONF": "/tmp/forced.conf"})
    assert "SRO_SIGN_CONF=/tmp/forced.conf" in r.stdout, r.stdout


def test_r4_uses_a_larger_rx_lo_offset_than_r3():
    """The demod has a dead zone at residual CFO ~= 0. At 2 sps the symbol rate doubles, so a given
    Hz offset is HALF the normalised offset it was at 4 sps -- r4 needs a bigger one in Hz.
    Measured: docs/evidence/sp4/ACQUISITION_COLLAPSE.md."""
    _, r3, _ = rung("r3")
    _, r4, _ = rung("r4")
    assert r3["LO_A_RX_DEFAULT"] == "2100020000" and r3["LO_B_RX_DEFAULT"] == "1850040000", "r3: the 2026-10-01 plan"
    assert r4["LO_A_RX_DEFAULT"] == "2100060000", "148 RX: +60 kHz (the cell that measured 99.84 % CRC) on the 2.1 GHz forward carrier (2026-10-02)"
    assert r4["LO_B_RX_DEFAULT"] == "1900080000", "146 RX: +80 kHz, the cell whose CFC locked"
    # the nominal is the PEER's transmit carrier, read from the table (r3's reverse carrier is
    # 1.85 GHz since 2026-09-29, r4's is still 1.9 GHz): r4's offsets must be strictly larger in Hz
    assert int(r4["LO_A_RX_DEFAULT"]) - int(r4["LO_B_TX_DEFAULT"]) > int(r3["LO_A_RX_DEFAULT"]) - int(r3["LO_B_TX_DEFAULT"])
    assert int(r4["LO_B_RX_DEFAULT"]) - int(r4["LO_A_TX_DEFAULT"]) > int(r3["LO_B_RX_DEFAULT"]) - int(r3["LO_A_TX_DEFAULT"])


def test_bringup_takes_the_lo_plan_from_the_rung_with_env_override():
    s = (OPS / "bringup_r2r3.sh").read_text()
    assert "LO_A_RX=${LO_A_RX:-$LO_A_RX_DEFAULT}" in s
    assert "LO_B_RX=${LO_B_RX:-$LO_B_RX_DEFAULT}" in s
    assert "LO_A_RX:-2000020000" not in s, "the hardcoded r3 default must be gone"


def test_reverse_carrier_is_1850_at_r2_r3_and_r4_is_untouched():
    """2026-09-29: the r2/r3 reverse carrier moved 1.9 -> 1.85 GHz (notch at 1.9 GHz; the rung
    table header and docs/evidence/link/GATE3_REVERSE_PLAN_2026-09-29.md carry the numbers).
    The TX carriers live in the table beside the RX plan they pair with, so every rail that
    arms the pair reads one source. r4 has not been measured at 1.85 and keeps its plan."""
    for name in ("r2", "r3"):
        rc, v, _ = rung(name)
        assert rc == 0
        assert v["LO_A_TX_DEFAULT"] == "1850000000" and v["LO_B_RX_DEFAULT"] == "1850040000", name
        assert v["LO_B_TX_DEFAULT"] == "2100000000" and v["LO_A_RX_DEFAULT"] == "2100020000", name
        assert int(v["LO_B_RX_DEFAULT"]) - int(v["LO_A_TX_DEFAULT"]) == 40000
    rc, v, _ = rung("r4")
    assert rc == 0
    assert v["LO_A_TX_DEFAULT"] == "1900000000" and v["LO_B_RX_DEFAULT"] == "1900080000"
    assert v["LO_B_TX_DEFAULT"] == "2100000000" and v["LO_A_RX_DEFAULT"] == "2100060000"   # r4 forward carrier 2.1 GHz since 2026-10-02

