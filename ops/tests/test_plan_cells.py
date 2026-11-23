"""test_plan_cells.py -- ops/plan_cells.sh, plan_cells_score.py and overnight_campaign.sh.

The lesson these encode (2026-09-28): on the reverse leg, anything measured ONCE after an arm is
measuring time-since-the-arm, and four hand-run experiments that day found the fault absent when
it mattered. So: every cell HOLDS and is scored in windows; cells ALTERNATE; both boards are polled
so 148 is a simultaneous control; and the campaign runs unattended off a deadline.

Traps pinned:
  1. OUT is mandatory on anything that arms boards.
  2. Cells alternate A/B by index, never in blocks.
  3. The watchdogs are killed before the hold (a re-arm mid-hold corrupts the trace and reads
     registers during an arm).
  4. The scorer drops torn reads and reset intervals before averaging; a single 2^31 sample must
     not move a median.
  5. The campaign takes SENTINEL_STOP only if absent and releases only what it took.
  6. Every campaign hook touches an iio attribute, never a modem register (no direct_reg_access).
"""
import os
import pathlib
import re
import subprocess
import sys

OPS = pathlib.Path(__file__).resolve().parents[1]
CELLS = OPS / "plan_cells.sh"
SCORE = OPS / "plan_cells_score.py"
CAMP = OPS / "overnight_campaign.sh"


def _run(tool, env, *args):
    e = dict(os.environ); e.update(env)
    return subprocess.run(["bash", str(tool), *args], capture_output=True, text=True, env=e)


def test_scripts_parse_and_are_executable():
    for t in (CELLS, CAMP):
        assert os.access(t, os.X_OK), t
        r = subprocess.run(["bash", "-n", str(t)], capture_output=True, text=True)
        assert r.returncode == 0, r.stderr


def test_out_is_mandatory_for_both():
    for t in (CELLS, CAMP):
        env = {k: v for k, v in os.environ.items() if k != "OUT"}
        env["DEADLINE"] = "2030-01-01 00:00"
        r = subprocess.run(["bash", str(t)], capture_output=True, text=True, env=env)
        assert r.returncode != 0 and "OUT" in r.stderr, t.name


def test_dry_run_alternates_plans_and_touches_nothing(tmp_path):
    marker = tmp_path / "HOOK_RAN"
    r = _run(CELLS, dict(OUT=str(tmp_path / "o"), DRY="1", CELLS="5",
                         A_NAME="alpha", B_NAME="beta", B_HOOK=f"touch {marker}"))
    assert r.returncode == 0, r.stderr
    order = re.findall(r"cell \d+: plan=(\w+)", r.stdout)
    assert order == ["alpha", "beta", "alpha", "beta", "alpha"], order
    assert not marker.exists(), "a dry run must not execute hooks"
    assert "[dry]" in r.stdout


def test_watchdogs_are_killed_before_the_hold():
    src = CELLS.read_text()
    assert src.index("kill_watchdogs\n") < src.index("poll $B"), "hold must follow the watchdog kill"
    assert "ock_watchdog" in src   # the pkill pattern is [l]ock_watchdog, so it cannot match itself


def test_scorer_ignores_torn_reads_and_resets(tmp_path):
    sys.path.insert(0, str(OPS))
    import plan_cells_score as pcs
    rows = [(t, 1000 * t, -4000 + (t % 3), 0, 33.0, 26.0, 34.0) for t in range(100, 200)]
    rows[50] = (150, 150000, 0x7FFFFFFF, 0, 33.0, 26.0, 34.0)     # torn CFC
    rows[60] = (160, 5, -4000, 0, 33.0, 26.0, 34.0)                # 0x104 reset mid-run
    s = pcs.score(rows)
    assert abs(s["cfc_med"] + 4000) <= 2, s
    assert 900 <= s["det_60_end"] <= 1100, s                       # one bad interval, not a crater
    assert s["dead_pct"] == 0.0


def test_scorer_flags_the_dead_zone(tmp_path):
    sys.path.insert(0, str(OPS))
    import plan_cells_score as pcs
    rows = [(t, 10 * t, 200 if t % 2 else -300, 0, None, None, None) for t in range(100, 200)]
    s = pcs.score(rows)
    assert s["dead_pct"] == 100.0


def test_campaign_takes_sentinel_stop_only_if_absent_and_releases_only_its_own(tmp_path):
    ss = tmp_path / "SENTINEL_STOP"
    ss.write_text("operator hold\n")
    src = CAMP.read_text()
    assert 'if [ ! -e "$SS_FILE" ]' in src
    assert '[ "$SS_MINE" = 1 ] && { rm -f "$SS_FILE"' in src


def test_campaign_dry_rotation_covers_all_four_experiments(tmp_path):
    r = _run(CAMP, dict(OUT=str(tmp_path / "c"), DRY="1", CELLS="2", DEADLINE="2030-01-01 00:00"))
    assert r.returncode == 0, r.stderr
    for exp in ("selfdesense", "bandswap", "txpower", "agcpin"):
        assert f"experiment {exp} done" in r.stdout, exp
    assert "CAMPAIGN_DONE" in r.stdout


def test_campaign_hooks_never_write_modem_registers():
    src = CAMP.read_text()
    hooks = re.findall(r'^(mute146|unmute146|tx148_low|tx148_full|pin146|unpin146)="(.*)"$', src, re.M)
    assert len(hooks) == 6, [h[0] for h in hooks]
    for name, body in hooks:
        assert "direct_reg_access" not in body and "0x" not in body, name
        assert "$P/" in body, name   # $P is the iio sysfs root defined once above the hooks
    assert re.search(r'^P=/sys/bus/iio/devices/', src, re.M)


def test_bandswap_plan_in_campaign_keeps_receivers_paired_to_peers():
    src = CAMP.read_text()
    for plan in re.findall(r'_ENV="([^"]+)"', src):
        kv = dict(x.split("=") for x in plan.split())
        assert abs(int(kv["LO_A_RX"]) - int(kv["LO_B_TX"])) <= 1_000_000, plan
        assert abs(int(kv["LO_B_RX"]) - int(kv["LO_A_TX"])) <= 1_000_000, plan


FREQ = OPS / "freq_map_campaign.sh"


def test_freqmap_parses_needs_out_and_dry_runs_a_pass(tmp_path):
    assert os.access(FREQ, os.X_OK)
    env = {k: v for k, v in os.environ.items() if k != "OUT"}
    env["DEADLINE"] = "2030-01-01 00:00"
    r = subprocess.run(["bash", str(FREQ)], capture_output=True, text=True, env=env)
    assert r.returncode != 0 and "OUT" in r.stderr
    r = _run(FREQ, dict(OUT=str(tmp_path / "f"), DRY="1", DEADLINE="2030-01-01 00:00", CANDS="2100 1850"))
    assert r.returncode == 0, r.stderr
    assert "candidate 2100 done" in r.stdout and "candidate 1850 done" in r.stdout
    assert "FREQMAP_DONE" in r.stdout


def test_freqmap_candidates_keep_the_reverse_receiver_paired_and_offset(tmp_path):
    """Every candidate moves 148 TX and 146 RX TOGETHER, keeps the +40 kHz offset, and leaves the
    forward leg at 2.0 GHz as the control."""
    out = tmp_path / "f"
    r = _run(FREQ, dict(OUT=str(out), DRY="1", DEADLINE="2030-01-01 00:00", CANDS="2100 1800"))
    assert r.returncode == 0, r.stderr
    # plan_cells' own lines go to the campaign log, not the campaign's stdout
    logs = "".join(p.read_text() for p in out.rglob("plan_cells.log"))
    plans = re.findall(r"\[dry\] env (LO_B_TX=\S+ LO_A_RX=\S+ LO_A_TX=\S+ LO_B_RX=\S+)", logs)
    assert len(plans) >= 4, plans
    for plan in plans:
        kv = dict(x.split("=") for x in plan.split())
        assert int(kv["LO_B_RX"]) - int(kv["LO_A_TX"]) == 40000, plan
        assert kv["LO_B_TX"] == "2100000000" and kv["LO_A_RX"] == "2100020000", plan
    assert any("LO_A_TX=2100000000" in p for p in plans)
    assert any("LO_A_TX=1800000000" in p for p in plans)
