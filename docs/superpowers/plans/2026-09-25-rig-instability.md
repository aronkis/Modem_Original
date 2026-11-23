# Rig instability: plan

> **For agentic workers:** implement task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** stop the rig producing (a) boards that need a human to power-cycle them, (b) silently
wrong measurements, and (c) campaign results that have to be retracted.

**Architecture:** three of the six instabilities below are *contention and state* problems with
cheap, enforceable fixes at existing chokepoints (`ops/anyssh.sh`, `ops/sim_repro/riglock.sh`,
`ops/bringup_r2r3.sh`). One is a real unexplained defect (the r4 wedge class) that must be
characterised from logs already on disk before any more silicon time is spent on it. Two are
discipline problems that get tests rather than code.

**Evidence:** `docs/evidence/oneway/ONEWAY_HW_VERIFY_2026-09-25.md`,
`docs/evidence/sp4/SILICON.md` sec 7, `docs/evidence/HANDOFF_20260925.md`.

## Global constraints

* No task here needs a flash or a rebuild. Tasks 1-4, 6, 7 are desk-only; task 5 is desk-only.
  Only task 8 touches boards, and only after 1 and 3 are in place.
* Every board-touching change keeps the existing rails' behaviour byte-identical when the new
  guard is satisfied -- a guard that changes the happy path is a regression.
* `SENTINEL_STOP` semantics are unchanged: a hold that was already there is never removed.

## The instabilities, with evidence

| # | class | evidence | cost when it bites |
|---|---|---|---|
| I1 | **Contention hang** -- register traffic racing an arm | 148 hung 2026-09-25 ~17:2x (a settle-timer's `direct_reg_access` reads collided with the sentinel's own recovery); memory `rig-noping-hang-dra-during-arm`: a 0.25 s poll once hung a board with no arm in flight | board dead, **no software recovery**, needs a physical power cycle |
| I2 | **r4 wedge class** | 6 of 17 windows 2026-09-24, 4 of 12 on 09-22, **0 of 11** for sp3prod at r3; peer engine stalls chronic (~0.37/s) on clean and wedged legs alike, so the first reading was withdrawn | blocks the sp4 rung; every Gate 3 table is ambiguous |
| I3 | **Arm lottery** -- gate passes, link collapses seconds later | 2026-09-25 restore: `ARM GATE PASS (try 1)` at 1247 f/s, health one minute later 478 f/s; 09-22 and 09-24 runs both show arms that pass then degrade | silent bad data; a whole campaign scored against a link that was never up |
| I4 | **Silent state reversion of latched controls** | `sro_sign` (0x208) cleared by any `0x000` on three separate paths; `FIXCTL_WRITE_FAILED` on 148 went unnoticed until the log was read by hand | a leg runs on the wrong configuration and the log still claims the right one |
| I5 | **Confounded campaigns** | the weak leg flipped between 09-22 (reverse), 09-24 (forward) and 09-25 (reverse); three separate conclusions had to be retracted | days of work producing retractions instead of findings |
| I6 | **Instruments that mislead** | Tap-A read as "stale DMA replay, REBOOT-ONLY" for five weeks while carrying live telemetry; a blind SNR proxy ranked the bad arms above the good ones; whole-run counts used where at-the-event timing was needed | wrong root causes pursued for weeks |

---

### Task 1: One rig mutex, enforced at the chokepoint (I1)

`ops/sim_repro/riglock.sh` already implements exactly the right thing (`rig_lock <name>` /
`rig_unlock`, refuses a foreign lock, `SENTINEL_STOP` ownership). Nothing enforces it: the campaign
rails take `SENTINEL_STOP` directly and one-off diagnostics take neither. `ops/anyssh.sh` is 9 lines
and every board access in the repo goes through it.

**Files:** Modify `ops/anyssh.sh`, `ops/sim_repro/riglock.sh`; Create `ops/rigprobe.sh`,
`ops/tests/test_rig_mutex.py`

- [ ] **Step 1: Write the failing test.** `ops/tests/test_rig_mutex.py`: with a `RIG_LOCK` file
      naming owner `someone-else`, `anyssh.sh <ip> 'echo hi'` exits 3 and prints `RIG_LOCKED`
      **without** invoking ssh (point `SSH` at a marker script, assert the marker is absent); with
      `RIG_LOCK_OWNER` matching the file's owner it runs normally; with no lock file it runs
      normally.
- [ ] **Step 2: Run** -> FAIL (no guard).
- [ ] **Step 3: Implement.** `riglock.sh` gains `rig_lock` exporting `RIG_LOCK_OWNER=<name>` so
      child processes of the holder pass the guard. `anyssh.sh` gains a 4-line preamble: if
      `$RIG_LOCK` exists and its `owner=` differs from `${RIG_LOCK_OWNER:-}`, print
      `RIG_LOCKED by: ...` and exit 3. Escape hatch `RIG_LOCK_BYPASS=1` for a documented emergency,
      which the guard logs.
- [ ] **Step 4: Run** -> PASS. Also run the full `ops/tests` suite: every existing rail must be
      unaffected (no lock file in the test environment).
- [ ] **Step 5: `ops/rigprobe.sh`** -- the sanctioned one-off register read, the thing that should
      have been used on 2026-09-25: takes the lock, reads the named registers once, releases, prints
      one line. `rigprobe.sh <ip> 0x104 0x25C ...`. This is what diagnostics call instead of
      hand-rolling `anyssh + direct_reg_access`.
- [ ] **Step 6: Commit.**

### Task 2: The rails take the mutex, not raw SENTINEL_STOP (I1)

**Files:** Modify `ops/gate3_pair.sh`, `ops/gate3_run.sh`, `ops/oneway_hw_verify.sh`,
`ops/capture_r3.sh`; Modify `ops/tests/test_rail_guards.py`

- [ ] **Step 1: Test** -- each rail sources `riglock.sh` and calls `rig_lock <rail-name>` before its
      first board contact, and `rig_unlock` on every exit path (trap), with the existing
      `SENTINEL_STOP` ownership assertions still passing unchanged.
- [ ] **Step 2: Run** -> FAIL. **Step 3:** implement (the rails' current `SS_MINE` blocks become
      `rig_lock`/`rig_unlock`, which already carry that semantic). **Step 4:** run -> PASS.
- [ ] **Step 5: Commit.**

### Task 3: A post-arm settle gate (I3)

Today the arm gate measures once and declares success. On 2026-09-25 it passed at 1247 f/s and the
link was at 478 f/s a minute later; nothing noticed.

**Files:** Modify `ops/bringup_r2r3.sh`; Modify `ops/tests/test_rung_table.py` (or a new
`ops/tests/test_bringup_settle.py`)

- [ ] **Step 1: Test** -- after `ARM GATE PASS`, the script re-probes both directions after
      `SETTLE_S` (default 60) and, if either side is below `GATE_FPS`, logs
      `ARM_SETTLE_FAIL rx=<n>` and re-rolls the arm (bounded by the existing `GATE_TRIES`); on a
      good settle it logs `ARM_SETTLE_OK`. Assert the strings and the loop bound statically.
- [ ] **Step 2: Run** -> FAIL. **Step 3:** implement. **Step 4:** run -> PASS.
- [ ] **Step 5: Commit.** Note: this makes every bring-up ~60 s longer and is worth it.

### Task 4: Verify-after-write for every latched control (I4)

`sro_sign` already reads back its witness. The failure on 148 (`FIXCTL_WRITE_FAILED`, 0 of 10 reads
returning) was printed and ignored because nothing treats it as fatal, and the arm sequence's other
latched writes have no readback at all.

**Files:** Modify `ops/sro_sign.sh`, `ops/bringup_r2r3.sh`; Create `ops/tests/test_latched_write.py`

- [ ] **Step 1: Test** -- a `latched_write <ip> <reg> <val> <witness-reg> <expect>` helper writes,
      reads the witness, retries once, and returns non-zero with `LATCHED_WRITE_FAIL` if the witness
      still disagrees. Fake board via the `ops/tests/test_sro_sign_conf.py` pattern; assert both the
      success and the disagree paths, and that a failed write leaves the shadow untouched.
- [ ] **Step 2: Run** -> FAIL. **Step 3:** implement and route `sro_sign`'s write through it.
      **Step 4:** run -> PASS.
- [ ] **Step 5:** make the bring-up's `sro_sign` hook **fatal on `LATCHED_WRITE_FAIL`** rather than
      the current advisory `SRO_SIGN_HOOK_FAILED` -- a board whose fixctl writes do not land is a
      board whose measurements cannot be attributed (and, on 2026-09-25, a board about to hang).
- [ ] **Step 6: Commit.**

### Task 5: Characterise the r4 wedge from the logs already on disk (I2) -- THE BLOCKER

No board time. Inputs: `ops/r3cap/gate3_sp4b_20260924_190553/<leg>/qpsk_tun{,_peer}.log`,
`regs_{pre,cap,post}.txt`, `frames.bin`, for the 6 wedged and 11 clean legs.

**Files:** Create `ops/wedge_forensics.py`, `docs/evidence/sp4/WEDGE_CLASS.md`

- [ ] **Step 1:** for each wedged leg, extract the **time-ordered** sequence around the flatline:
      which side's delivery counter stops FIRST (daemon timestamps, not whole-run totals -- the
      whole-run counts were already shown not to discriminate).
- [ ] **Step 2:** the fabric byte counter `0x1C0` across the flatline -- frozen = fabric ring,
      advancing = host side. `regs_post.txt` carries it; the capture rail's stall poll carries the
      delivery series.
- [ ] **Step 3:** test coincidence with the two periodic events in the window -- the Tap-A IQ
      capture and the framelog rotate -- across all 17 legs (6 wedged, 11 not). A clean correlation
      either way is the answer; no correlation eliminates both.
- [ ] **Step 4:** write `WEDGE_CLASS.md` with the verdict, or with an explicit "not determined by
      these logs, the next capture must record X" -- which is itself a valid outcome and better than
      the withdrawn guess.
- [ ] **Step 5: Commit.**

### Task 6: Campaigns record their own conditions and carry a control (I5)

Every retraction this week came from comparing two runs whose conditions differed in ways nothing
recorded.

**Files:** Modify `ops/capture_r3.sh` (meta), `ops/gate3_pair.sh`; Modify `ops/tests/test_gate3_pair.py`

- [ ] **Step 1: Test** -- `meta.txt` gains, per capture: both boards' `rssi`/`decimated_power`, the
      steering witness (already added), the image md5 of BOTH boards, and the sentinel's last
      forward/reverse reading before the run. Assert the keys exist.
- [ ] **Step 2: Run** -> FAIL. **Step 3:** implement (read-only sysfs, via `rigprobe.sh` from Task
      1 so it is lock-safe). **Step 4:** run -> PASS.
- [ ] **Step 5:** `gate3_pair.sh` interleaves a **control leg** on the unchanged shipped image at the
      start and end of a campaign, so a mid-campaign RF change is visible in the same table rather
      than inferred across days.
- [ ] **Step 6: Commit.**

### Task 7: Instruments must be able to say "I don't know" (I6)

**Files:** Modify `ops/check_capture_health.py`, `ops/score_leg.py`; Create `ops/tests/test_instrument_honesty.py`

- [ ] **Step 1: Test** -- feed each scorer (a) its intended input, (b) a *different valid* signal
      class, (c) noise. Assert it never returns a confident verdict for (b) or (c): it must name the
      class or return `UNKNOWN`. The Tap-A scorer already does this after the BEATOBS fix; this task
      makes it a rule with a test, and applies it to `score_leg.py`.
- [ ] **Step 2: Run** -> expect (b) to fail for at least one scorer. **Step 3:** implement.
      **Step 4:** run -> PASS.
- [ ] **Step 5: Commit.**

### Task 8: Re-validate on silicon (needs Tasks 1 and 3 merged; operator's go)

- [ ] **Step 1:** one bring-up under the new mutex and settle gate; confirm `ARM_SETTLE_OK` and that
      a deliberate concurrent `anyssh` from a second shell is refused with `RIG_LOCKED`.
- [ ] **Step 2:** re-run whichever campaign is next (sp4 Gate 3, or the one-way reverse leg if still
      outstanding) and confirm the new `meta.txt` fields are populated and the control leg appears.
- [ ] **Step 3:** evidence + commit.

## Verification

Desk: `python3 -m pytest -q ops/tests modem/tests`; `tools/check_paths.sh`;
`modem/regmap/gen_regmap.py --check`; `sphinx-build -W`. Every existing rail test must still pass
unchanged -- these guards must be invisible when satisfied.

Silicon (task 8 only): one bring-up, one campaign, no board left needing a human.

## Out of scope

The 146 antenna question (operator, bench). Receiver margin at 2 sps (a separate modelling task;
`SILICON.md` sec 7.4 sizes it). Any steering-branch change -- both directions were measured this
week and neither is implicated at r3.
