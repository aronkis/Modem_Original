#!/usr/bin/env python3
"""test_gate3_pair.py -- sp4 Task 12's repo rail ops/gate3_pair.sh, exercised at the desk with
DRY=1 and NO BOARD CONTACT (the ssh wrapper is pointed at a script that fails loudly; the two
flash rails run their own DRY=1 paths, which print "[dry] ..." for every board action).

Pins: argument gates (md5 shape, banked image, CURRENT.txt roles and DTB rows); the sequence
order dtb 146 -> dtb 148 -> flash 148 (FLASH_BAK = role A) -> flash 146 (FLASH_BAK = role B,
RUNG=r4 for its bring-up) -> 6 rev + 3 fwd x ARM_S -> rev/fwd LONG_S -> soak rounds -> verdict
-> rollback (deploy_image roles, restore_known_good at r3) or --keep; every capture journaled
as "CAPTURE <label> rc=.. accept: ..."; the sentinel hold is never touched under DRY."""
import os
import pathlib
import re
import subprocess

OPS = pathlib.Path(__file__).resolve().parents[1]
ROOT = OPS.parent
RAIL = OPS / "gate3_pair.sh"
SP4 = "5108cdb77aeb"


def run(args, tmp_path, extra_env=None):
    fake = tmp_path / "anyssh.sh"
    fake.write_text("#!/bin/sh\necho BOARD_CONTACT >&2; exit 97\n"); fake.chmod(0o755)
    ss = tmp_path / "SENTINEL_STOP"; ss.write_text("hold\n")
    env = dict(os.environ, DRY="1", ANYSSH=str(fake), SENTINEL_STOP_FILE=str(ss),
               OUT=str(tmp_path / "out"), HOME=str(tmp_path))   # HOME: the 148 rail's ~/modem-status path
    env.update(extra_env or {})
    r = subprocess.run([str(RAIL), *args], capture_output=True, text=True, env=env)
    return r, ss


def test_argument_gates(tmp_path):
    r, _ = run(["--tag", "sp4"], tmp_path)
    assert r.returncode == 2 and "usage" in r.stderr
    r, _ = run(["--tag", "sp4", "--md5", "xyz"], tmp_path)
    assert r.returncode == 2 and "12 lowercase hex" in r.stderr
    r, _ = run(["--tag", "sp4", "--md5", "0123456789ab"], tmp_path)
    assert r.returncode == 1 and "no banked image" in r.stdout
    r, _ = run(["--tag", "sp4", "--md5", SP4, "--rung", "r9"], tmp_path)
    assert r.returncode == 2 and "unknown rung" in r.stderr


def test_dry_sequence_and_no_board_contact(tmp_path):
    r, ss = run(["--tag", "sp4", "--md5", SP4, "--soak", "1"], tmp_path)
    out = r.stdout
    assert r.returncode == 0, out + r.stderr
    assert "BOARD_CONTACT" not in r.stderr and "BOARD_CONTACT" not in out
    assert ss.read_text() == "hold\n", "DRY must never touch the sentinel hold"
    assert "DRY never touches it" in out
    # preconditions resolved from the bank / CURRENT.txt
    assert "candidate: images/BOOT.BIN.jupiter.sp4.5108cdb77aebb0989c53c65f4a0eac75" in out
    assert "rollback role A:" in out and "rollback role B:" in out
    assert "dtb 146: system-qpsk.146.dtb." in out and "dtb 148: system-qpsk.148.dtb." in out
    # order
    def at(s):
        i = out.find(s); assert i >= 0, s; return i
    seq = [
        "[2] dtb -> 10.0.0.146", "[2] dtb -> 10.0.0.148",
        "[3] flash 148 <- 5108cdb77aeb (sp4), FLASH_BAK=8503f226395c (role A)",
        "=== [1/5] preconditions ===",           # the 148 rail's own DRY path ran
        "[4] flash 146 <- 5108cdb77aeb (sp4), FLASH_BAK=8503f226395c (role B), pair bring-up at RUNG=r4",
        "=== [1/6] preconditions ===",           # the 146 rail's own DRY path ran
        "CAPTURE rev180_1 rc=dry accept: dry", "CAPTURE rev180_6 rc=dry accept: dry",
        "CAPTURE fwd180_1 rc=dry accept: dry", "CAPTURE fwd180_3 rc=dry accept: dry",
        "CAPTURE rev600 rc=dry accept: dry", "CAPTURE fwd600 rc=dry accept: dry",
        "CAPTURE soak1_rev600 rc=dry accept: dry", "CAPTURE soak1_fwd600 rc=dry accept: dry",
        "GATE3_VERDICT sp4 5108cdb77aeb rung=r4 bad_arms=0 of 13 long_legs_over_limit=0 -> DRY",
        "[9] ROLLBACK to CURRENT.txt roles: 10.0.0.148:A 10.0.0.146:B, then restore_known_good.sh at r3",
        "GATE3_PAIR_DONE sp4 DRY",
    ]
    idx = [at(s) for s in seq]
    assert idx == sorted(idx), "sequence out of order"
    # the flash rails were handed the rung and the frame for their bring-up / witness decode
    assert re.search(r"env DRY=1 FLASH_MD5=5108cdb77aeb FLASH_TAG=sp4 FLASH_BAK=8503f226395c ROLLBACK_BANK=\S+sp3clamp004\S+ RUNG=r4 QPSK_FRAME=f3072", out)
    assert "[DRY] RUNG=r4 " in out and "capture_r3.sh B -d 180 -k -o" in out
    assert "[DRY] env SUFFIX=.gate3 " in out and "deploy_image.sh 10.0.0.148 A" in out
    assert "[DRY] env -u SRO_SIGN_CONF RUNG=r3 " in out and "restore_known_good.sh" in out
    assert (tmp_path / "out" / "GATE3_SUMMARY.txt").read_text().startswith("GATE3 sp4 5108cdb77aeb rung=r4")


def test_keep_and_skips(tmp_path):
    r, _ = run(["--tag", "sp4", "--md5", SP4, "--keep", "--no-dtb", "--no-flash"], tmp_path,
               {"REV_ARMS": "1", "FWD_ARMS": "1"})
    _check_keep_and_skips(r)


def test_keep_and_skips_via_env(tmp_path):
    """launch_rig_unit.sh passes env only: the same run through GATE3_NO_DTB / GATE3_NO_FLASH / GATE3_KEEP."""
    r, _ = run([], tmp_path, {"GATE3_TAG": "sp4", "GATE3_MD5": SP4, "GATE3_KEEP": "1", "GATE3_NO_DTB": "1",
                               "GATE3_NO_FLASH": "1", "REV_ARMS": "1", "FWD_ARMS": "1"})
    _check_keep_and_skips(r)


def _check_keep_and_skips(r):
    out = r.stdout
    assert r.returncode == 0, out + r.stderr
    assert "[2] dtb ->" not in out and "[3] flash 148" not in out and "[4] flash 146" not in out
    assert "[9] KEEP: pair left on 5108cdb77aeb at rung r4" in out and "deploy_image.sh" not in out
    assert "CURRENT.txt roles are the operator's edit" in out
    assert "bad_arms=0 of 4" in out


def test_rails_discipline_static():
    s = RAIL.read_text()
    # sentinel ownership like gate3_run.sh / the flash rails; released on every exit
    assert 'SS_MINE=1' in s and "trap release EXIT" in s
    # no board contact helper without a DRY branch
    assert 'brd(){ if [ "$DRY" = 1 ]; then echo "dry"' in s
    # the candidate is run at its rung, the rollback at the rollback rung
    assert 'RUNG=$RUNG_C "$D/capture_r3.sh"' in s and 'run env -u SRO_SIGN_CONF RUNG="$RB_RUNG" "$D/restore_known_good.sh"' in s
    # CURRENT.txt roles are never edited by the rail
    assert "CURRENT.txt" in s and not re.search(r">\s*\S*CURRENT\.txt", s)


def test_campaign_records_its_own_conditions_at_both_ends(tmp_path):
    """Plan Task 6 (I5): every retraction of the week of 2026-09-22 came from comparing runs whose
    conditions differed in ways nothing recorded. A campaign must bracket itself."""
    s = RAIL.read_text()
    assert "env_snapshot(){" in s
    assert s.index("env_snapshot BEFORE") < s.index("env_snapshot AFTER")
    # BEFORE comes before any flashing, AFTER before the verdict is printed
    assert s.index("env_snapshot BEFORE") < s.index("FLASH_BAK=\"$A_BAK\"")  # the real flash call, not the header
    assert s.index("env_snapshot AFTER") < s.index('say "GATE3_VERDICT')  # the emit, not the header
    # it is a no-op under DRY
    r, _ = run(["--tag", "sp4b", "--md5", SP4, "--rollback-only"], tmp_path)
    assert "[DRY] env_snapshot" in r.stdout, r.stdout


def test_capture_meta_records_conditions():
    s = (OPS / "capture_r3.sh").read_text()
    for key in ("image_md5_peer=", "rf_rx=", "rf_peer=", "sentinel_before="):
        assert key in s, key
    # and the steering/byte witnesses live in the register snapshots
    assert "bytewords=$(rd 0x1C0)" in s and "sro_mode=$(rd 0x25C)" in s


def test_campaign_aborts_early_after_consecutive_failures():
    """2026-09-25: a degraded reverse leg made every bring-up fail its arm gate, and the campaign
    ground through all six captures -- ~36 arms, 40 minutes -- to produce a table of
    '(no frames.bin)'. Stop and roll back instead."""
    s = RAIL.read_text()
    assert "CAMPAIGN_ABORT_EARLY" in s and "CAMPAIGN_MAX_CONSEC_FAIL" in s
    assert 'MAX_CONSEC=${CAMPAIGN_MAX_CONSEC_FAIL:-3}' in s, "default 3"
    # a no-frames capture counts as a failure even at rc=0; a good one resets the counter
    body = s[s.index('say "CAPTURE $3 $verdict accept: $score"'):]
    body = body[:body.index("CAMPAIGN_ABORT_EARLY")]
    assert "(no frames.bin)" in body and "CONSEC_FAIL=0" in body
    # skipped captures are recorded, not silently missing, and the rollback still runs
    assert 'ROWS+=("$3|skipped|campaign aborted early")' in s
    assert s.index("CAMPAIGN_ABORTED=1") < s.rindex("rollback_pair")   # the step-[9] call; the function body sits near the top since 2026-10-02



# ---- CELLS mode: the interleaved discriminating sweep (2026-09-26) ------------------------------
# Added for the LO confirming experiment of docs/evidence/sp4/ACQUISITION_COLLAPSE.md sec 6. The
# design only works if repeats are distinguishable and the run cannot claim a pass mark.
CELLS4 = ("A:LO_A_RX=2000020000 A:LO_A_RX=2000060000 "
          "A:LO_A_RX=2000020000 A:LO_A_RX=2000060000")


def test_cells_mode_runs_the_interleaved_plan(tmp_path):
    r, _ = run(["--tag", "sp4", "--md5", SP4], tmp_path,
               extra_env={"GATE3_CELLS": CELLS4, "CELL_S": "300"})
    out = r.stdout
    assert r.returncode == 0, out + r.stderr
    assert "BOARD_CONTACT" not in out and "BOARD_CONTACT" not in r.stderr
    # every cell ran, in order, and the two repeats did NOT collide on one label
    labels = re.findall(r"CAPTURE (cell\d+_A_\d+) ", out)
    assert labels == ["cell1_A_2000020000", "cell2_A_2000060000",
                      "cell3_A_2000020000", "cell4_A_2000060000"], labels
    # each cell's override reaches capture_r3.sh's environment, and the duration is CELL_S
    assert "env RUNG=r4 LO_A_RX=2000020000" in out
    assert "env RUNG=r4 LO_A_RX=2000060000" in out
    assert "capture_r3.sh A -d 300 -k -o" in out
    # the lottery plan is replaced, not added to
    assert "rev180_1" not in out and "fwd180_1" not in out and "rev600" not in out
    # and the sweep is labelled as not being a gate
    assert "GATE3_CELLS_NOTE" in out and "no pass/fail mark" in out
    assert "wedged cell is DATA" in out


def test_cells_run_never_claims_pass(tmp_path):
    """A sweep has no pass mark. The limit loop keys on LONG_S, which a cells run has none of, so
    without the guard every all-cells-produced-frames run would print PASS."""
    src = RAIL.read_text()
    assert 'elif [ -n "$CELLS" ]; then VERDICT=CELLS' in src
    # the per-label limit check is skipped outright for a cells run
    # guard idiom: -n succeeds when CELLS is set, so the || branch (the limit check) is skipped
    assert '[ -n "$CELLS" ] || case "$label" in *"${LONG_S}"*)' in src


def test_lottery_plan_is_unchanged_when_no_cells(tmp_path):
    """The default campaign must be exactly what it was: cells is an alternative, not a rewrite."""
    r, _ = run(["--tag", "sp4", "--md5", SP4, "--soak", "1"], tmp_path)
    out = r.stdout
    assert "rev180_1" in out and "fwd180_1" in out
    assert "rev600" in out and "fwd600" in out
    assert "soak1_rev600" in out and "soak1_fwd600" in out
    assert "cell1_" not in out
    assert "GATE3_CELLS_NOTE" not in out


# ---- CELLS with SEVERAL variables per cell (2026-09-29) ----------------------------------------
# An LO plan is two variables (LO_A_TX and LO_B_RX move together; bringup_r2r3.sh refuses a
# half-applied one), so a cell may carry a comma-separated list. It must reach capture_r3.sh as
# separate env assignments, and a plain single VAR=value cell must be byte-identical to before.
CELLS_2VAR = ("A:LO_A_TX=1900000000,LO_B_RX=1900040000 "
              "A:LO_A_TX=1850000000,LO_B_RX=1850040000")


def test_cells_accept_a_comma_list_of_variables(tmp_path):
    r, _ = run(["--tag", "sp4", "--md5", SP4], tmp_path,
               extra_env={"GATE3_CELLS": CELLS_2VAR, "CELL_S": "180", "GATE3_RUNG": "r3"})
    out = r.stdout
    assert r.returncode == 0, out + r.stderr
    assert "BOARD_CONTACT" not in out and "BOARD_CONTACT" not in r.stderr
    # both variables reach the capture's environment as SEPARATE assignments (no comma survives)
    assert "env RUNG=r3 LO_A_TX=1900000000 LO_B_RX=1900040000 " in out
    assert "env RUNG=r3 LO_A_TX=1850000000 LO_B_RX=1850040000 " in out
    assert "LO_A_TX=1900000000,LO_B_RX" not in out.split("--- capture")[1].split("\n")[1]
    # labels are distinct per plan (the LAST value names the cell)
    labels = re.findall(r"CAPTURE (cell\d+_A_\d+) ", out)
    assert labels == ["cell1_A_1900040000", "cell2_A_1850040000"], labels


def test_single_variable_cells_are_unchanged_by_the_comma_form(tmp_path):
    r, _ = run(["--tag", "sp4", "--md5", SP4], tmp_path,
               extra_env={"GATE3_CELLS": CELLS4, "CELL_S": "300"})
    out = r.stdout
    assert r.returncode == 0, out + r.stderr
    assert "env RUNG=r4 LO_A_RX=2000020000 /" in out or "env RUNG=r4 LO_A_RX=2000020000 " in out
    assert re.findall(r"CAPTURE (cell\d+_A_\d+) ", out)[:2] == ["cell1_A_2000020000", "cell2_A_2000060000"]


def test_rollback_drops_the_candidate_rungs_steering_conf_and_runs_on_146_failure():
    """2026-10-02: the r3 rollback after an r4 gate inherited sro_sign.r4.conf and wrote R4D steering on 148;
    and a 146 flash failure left 148 on the candidate for 2.5 h. The rail now owns both."""
    s = open(os.path.join(OPS, "gate3_pair.sh")).read()
    code = "\n".join(l for l in s.splitlines() if not l.lstrip().startswith("#"))
    assert 'run env -u SRO_SIGN_CONF RUNG="$RB_RUNG" "$D/restore_known_good.sh"' in code
    assert code.count("rollback_pair") >= 3            # definition, step [9], the 146-failure branch
    fail = [l for l in code.splitlines() if "146 flash rail failed" in l][0]
    assert "rollback_pair; exit 1" in fail
