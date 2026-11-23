"""test_band_swap_probe.py -- ops/band_swap_probe.sh, the band-vs-chain discriminator.

What this experiment is for: the reverse leg (148 TX -> 146 RX) has failed for weeks while the
forward leg is untouched, and the pair is asymmetric -- forward at 2.0 GHz, reverse at 1.9 GHz. So
"1.9 GHz is bad" and "148's transmitter or 146's receiver is bad" predict exactly the same
observations. Swapping which DIRECTION owns which frequency separates them, and with two boards
and no loopback cable it is the only way to.

The traps pinned here are the ones that would make the run worthless or cost a wasted arm:

  1. A HALF-APPLIED swap. Four LOs must move together; move two and the receivers sit 100 MHz
     from their peers, which looks exactly like the defect under investigation.
  2. Losing the interleave. This leg's condition drifts within minutes -- the LO cells run showed
     delivery tracking the clock while the knob moved another statistic tenfold -- so a run that
     did all the normal cells then all the swapped ones could not attribute anything.
  3. Forgetting that the REVERSE LEG IS STILL 148 -> 146 after the swap. Only its frequency
     changes. If the swap also exchanged which board transmits, the experiment would answer a
     different question and nobody would notice.
"""
import os
import pathlib
import re
import subprocess

OPS = pathlib.Path(__file__).resolve().parents[1]
TOOL = OPS / "band_swap_probe.sh"


def plan(name):
    """The LO assignment a given plan hands to the bring-up, as a dict."""
    src = TOOL.read_text()
    m = re.search(rf"^\s*{name}\)\s*echo \"([^\"]+)\"", src, re.M)
    assert m, f"plan {name} not found in band_swap_probe.sh"
    return dict(kv.split("=") for kv in m.group(1).split())


def run_dry(tmp_path, *args):
    env = dict(os.environ, DRY="1")
    r = subprocess.run(["bash", str(TOOL), "-o", str(tmp_path / "out"), *args],
                       capture_output=True, text=True, env=env)
    assert r.returncode == 0, r.stderr
    return r.stdout


def test_both_plans_pair_each_receiver_with_its_peers_transmitter(tmp_path):
    """Trap 1: in EITHER plan, every receiver must sit within 1 MHz of its peer's transmitter."""
    for name in ("normal", "swap"):
        p = plan(name)
        fwd = abs(int(p["LO_A_RX"]) - int(p["LO_B_TX"]))   # 146 TX -> 148 RX
        rev = abs(int(p["LO_B_RX"]) - int(p["LO_A_TX"]))   # 148 TX -> 146 RX
        assert fwd <= 1_000_000, f"{name}: forward leg mispaired by {fwd} Hz"
        assert rev <= 1_000_000, f"{name}: reverse leg mispaired by {rev} Hz"


def test_the_swap_actually_exchanges_the_two_bands(tmp_path):
    n, s = plan("normal"), plan("swap")
    assert int(n["LO_A_TX"]) != int(s["LO_A_TX"]), "148 TX did not move"
    assert int(n["LO_B_TX"]) != int(s["LO_B_TX"]), "146 TX did not move"
    # the set of carriers in use is unchanged -- same two frequencies, opposite directions
    assert {int(n["LO_A_TX"]), int(n["LO_B_TX"])} == {int(s["LO_A_TX"]), int(s["LO_B_TX"])}


def test_reverse_leg_is_still_148_to_146_after_the_swap(tmp_path):
    """Trap 3: the swap changes FREQUENCY, never which board transmits."""
    n, s = plan("normal"), plan("swap")
    # in both plans 146's receiver is paired to 148's transmitter
    assert abs(int(n["LO_B_RX"]) - int(n["LO_A_TX"])) <= 1_000_000
    assert abs(int(s["LO_B_RX"]) - int(s["LO_A_TX"])) <= 1_000_000
    # and the reverse leg's frequency really did change
    assert int(n["LO_A_TX"]) != int(s["LO_A_TX"])


def test_each_receiver_keeps_a_deliberate_cfo_offset_in_both_plans(tmp_path):
    """The offsets exist to stay out of the demod dead zone; a swap must not zero them."""
    for name in ("normal", "swap"):
        p = plan(name)
        assert int(p["LO_A_RX"]) - int(p["LO_B_TX"]) == 20000, f"{name}: 148 RX offset lost"
        assert int(p["LO_B_RX"]) - int(p["LO_A_TX"]) == 40000, f"{name}: 146 RX offset lost"


def test_dry_run_alternates_the_plans_and_touches_nothing(tmp_path):
    """Trap 2: cells must alternate, not run in blocks."""
    out = run_dry(tmp_path, "-n", "4")
    order = re.findall(r"cell \d+: plan=(\w+)", out)
    assert order == ["normal", "swap", "normal", "swap"], order
    assert "[dry] would run" in out
    assert "BAND_SWAP_DONE" in out


def test_dry_run_restores_the_normal_plan_at_the_end(tmp_path):
    out = run_dry(tmp_path, "-n", "2")
    assert "restoring the NORMAL plan" in out


def test_odd_cell_count_still_starts_and_ends_sanely(tmp_path):
    out = run_dry(tmp_path, "-n", "3")
    assert re.findall(r"cell \d+: plan=(\w+)", out) == ["normal", "swap", "normal"]
