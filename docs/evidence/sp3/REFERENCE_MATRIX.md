# REFERENCE_MATRIX — sp3 Task 3 (model-backport, SRO select sub-project, "the reference matrix")

Recorded 2026-09-11 on nemo.

Sub-project: `.superpowers/sdd/2026-09-11-model-backport-sro-select/task-3-brief.md`,
amended by controller rulings (a)-(e) on the same task, and by a controller
instruction mid-task to add `--jobs N` parallelism to `run_gates.sh` and
re-run under it.

## Verdict

**Done.** `modem/fixes/gates/reference_loss.toml` (12 rows: R4B x5 ppm
stimuli, R4DR1 x5, W1 x2) was produced by a real Verilator run of the
INJECTED trees (no `TREE=`/`FIXCTL=` override) and passes every sanity check
against previously-banked numbers, several exactly. Gate 1 (a later task)
compares the model-tree's simulated loss against these rows using
`modem/fixes/score_matrix.py`'s tolerance rule.

## 1. What was built

- `modem/fixes/score_matrix.py` -- scores a run directory's per-leg loss
  (from `<prefix>_t7.log`'s `LOSS=x.xx%`, NOT from `<prefix>_res.txt` --
  ruling (a)) and counts (`<prefix>_res.txt` token=value pairs) against
  `reference_loss.toml`, using the tolerance rule (ruling 2, verbatim):
  `loss_tol(ref) = max(0.10, 0.10*ref)` percentage points,
  `count_tol(ref) = max(2, ceil(0.10*ref))`. TDD: `modem/fixes/tests/test_score_matrix.py`
  (3 tests, RED before `score_matrix.py` existed -- `ModuleNotFoundError` --
  GREEN after).
- `modem/fixes/collect_reference.py` -- reads each run leg's `<prefix>_res.txt`
  and (for R4B/R4DR1) `<prefix>_t7.log`, classifies variant/stimulus from the
  prefix, computes `tree_sha` from each variant's `Rate_Handle.v`, and renders
  `reference_loss.toml`. `extras` (`r3_extras`) is recorded only for R4DR1 --
  on R4B trees that token is a lock-sentinel, not a count (confirmed via a
  sample value of 2779054082). Exits non-zero (`COLLECT_REFERENCE_NO_LOSS
  <prefix>`) if any non-W1 prefix's `_t7.log` produced no parseable `LOSS=`
  -- a missing `loss_pct` would otherwise silently disable loss-gating for
  that row in Gate 1 without any visible failure, since `score_matrix.py`
  only compares loss `if "loss_pct" in ref`.
- `modem/fixes/gates/reference_matrix.legs` -- 12 run legs (R4B x5 with
  `+r4bwin=<prefix>_skipwin.txt`; R4DR1 x5 without the plusarg, per ruling
  (c)'s literal reading -- confirmed behaviourally inert:
  `wrap_byte_sro4d.v:268` shows the plusarg only supplies an `$fopen`
  filename, defaulting to `r4d_skipwin.txt` when omitted, so the five R4DR1
  legs write the same default file in one work dir, unread by any scorer),
  10 paired `score_t7.py` legs for R4B/R4DR1 (W1 has no `_seq.txt`, so no
  paired scorer leg), and 1 final `collect` leg.
- `modem/fixes/bank.sha256` -- re-pinned the `sro_sim.listing` line after
  adding the missing `+2.5 ppm` stimulus `n_p2p5.iq` (`gen_sro_stim.py
  tx432.iq n_p2p5.iq --ppm 2.5 --no-tile --frames 428`) to the bank; verified
  `BANK_OK`.
- `modem/fixes/run_gates.sh` -- added `--legs FILE` (bypasses the fixes.toml
  manifest for a single named table outside any role) and, per a mid-task
  controller instruction, `--jobs N` (default 1, unchanged serial behaviour).
  Scheduling rule: legs are considered in table order; a pending leg may
  start (take a free slot) when no CURRENTLY-RUNNING leg's name appears
  anywhere in its own command or criterion text -- a substring check. Each
  leg keeps its own `systemd-run` unit, log and content-keyed `.ok` exactly
  as before; reuse (a valid `.ok`) resolves instantly, without a slot or a
  dependency wait, since it does no work. TDD: `modem/fixes/tests/test_run_gates_jobs.sh`
  (a fake 4-leg sleep table -- two independent legs proven to overlap in
  wall-clock time under `--jobs 2`; a leg naming a running leg proven to wait
  until that leg's marker file shows it finished), wrapped for pytest in
  `modem/fixes/tests/test_run_gates.py`.

## 2. Run

Command (after a stopped first attempt under `--jobs 1`; see §3):

```
systemd-run --user --unit sp3-refmatrix2 \
  --working-directory=/mnt/onetb/scratch/qpsk-jupiter-modem \
  --setenv=SP2_WORK=/mnt/onetb/scratch/sp2_gates/refmatrix_work \
  --setenv=PATH="$PATH" --setenv=XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
  --setenv=DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
  bash -c "modem/fixes/run_gates.sh --legs modem/fixes/gates/reference_matrix.legs \
           --jobs 4 > /mnt/onetb/scratch/sp2_gates/refmatrix_work/console2.log 2>&1"
```

Launched as a genuine `systemd-run --user` transient unit (not a harness
background task) so a ~1-2 h run survives independently of the interactive
session; a watcher polled `systemctl --user is-active` at 60 s intervals.

Wall time: **01:13:35** for the full 23-leg table (`GATE_LEGS
reference_matrix pass=23 fail=0`), well inside the controller's ~1.5-2 h
estimate for the remaining 7 sim legs under 4-way parallelism. The 4 R4B
legs from the earlier (stopped) `--jobs 1` attempt reused instantly via
their content-keyed `.ok` files (banked wall times 00:39:31-00:40:01 each,
visible in the `LEG_REUSE ... (from <timestamp>)` lines below); the 7
remaining sim legs (`r4b_n_m10`, `r4dr1_n_p000/p2p5/m2p5/p10/m10`,
`w1_p000`, `w1_m10`) ran under `--jobs 4`, 4 concurrent at a time (confirmed
via `ps`/`systemctl --user list-units` mid-run showing exactly 4
`Vwrap_byte_sro`/`Vwrap_byte_w1` processes at once).

```
LEG_REUSE r4b_n_p000 (from 2026-09-11T11:54:47-04:00)
LEG_REUSE r4b_n_p000_t7 (from 2026-09-11T11:55:17-04:00)
LEG_REUSE r4b_n_p2p5 (from 2026-09-11T12:35:17-04:00)
LEG_REUSE r4b_n_p2p5_t7 (from 2026-09-11T12:35:47-04:00)
LEG_REUSE r4b_n_m2p5 (from 2026-09-11T13:15:48-04:00)
LEG_REUSE r4b_n_m2p5_t7 (from 2026-09-11T13:16:18-04:00)
LEG_REUSE r4b_n_p10 (from 2026-09-11T13:55:49-04:00)
LEG_REUSE r4b_n_p10_t7 (from 2026-09-11T13:56:19-04:00)
LEG_PASS r4dr1_n_p000  00:37:33
LEG_PASS r4dr1_n_p2p5  00:37:33
LEG_PASS r4dr1_n_m2p5  00:37:33
LEG_PASS r4dr1_n_p000_t7  00:00:00
LEG_PASS r4dr1_n_p2p5_t7  00:00:00
LEG_PASS r4dr1_n_m2p5_t7  00:00:00
LEG_PASS r4b_n_m10  00:40:03
LEG_PASS r4b_n_m10_t7  00:00:30
LEG_PASS w1_p000  00:15:01
LEG_PASS w1_m10  00:19:01
LEG_PASS r4dr1_n_p10  00:35:32
LEG_PASS r4dr1_n_m10  00:35:32
LEG_PASS r4dr1_n_p10_t7  00:00:00
LEG_PASS r4dr1_n_m10_t7  00:00:00
LEG_PASS collect  00:00:30
GATE_LEGS reference_matrix pass=23 fail=0 wall=01:13:35
GATE_PASS reference_matrix wall=01:13:35
GATES_DONE role=legs pass=1 fail=0
```

## 3. Mid-run pivot to `--jobs 4` (controller-directed)

The matrix was first launched serially (`--jobs 1`, the only mode that
existed at that point) under `systemd-run --unit sp3-refmatrix`. After the
4 R4B legs (and their paired `_t7` legs) had completed and the 5th
(`r4b_n_m10`) was in flight, the controller directed adding `--jobs N` to
`run_gates.sh` and re-running under `--jobs 4` (nemo has 9 idle cores; each
Verilator leg is single-threaded, ~40 min). The in-flight `sp3-refmatrix`
unit and its currently-running leg unit
(`sp2-gate-reference_matrix-r4b_n_m10-...`) were stopped cleanly
(`systemctl --user stop`); that leg's partial output was discarded (no
`.ok` was written for it, confirmed before relaunch) and it re-ran to
completion under the `--jobs 4` table. The 4 already-`.ok`'d R4B legs were
NOT touched and were reused, per their content-keyed sigs.

## 4. Sanity checks against banked numbers

| Check | Banked target | Measured | Verdict |
|---|---|---|---|
| R4B/n_m10 loss | ~0.48 % | 0.48 % | exact match |
| R4B/n_m10 skips | ~30 | 30 | exact match |
| R4B/n_p10 loss | ~6.65 % | 6.65 % | exact match |
| R4DR1/n_p10 loss | <= 1.00 % | 0.00 % | within bound |
| R4DR1/n_p000 loss | <= 0.10 % | 0.00 % | within bound |
| W1/p000 delivered | 164 | 164 | exact match |
| W1/m10 delivered | 209 | 209 | exact match |
| W1 mismatches (both) | 0 | 0 | exact match |

No mismatch beyond tolerance; nothing here triggered the BLOCKED path.

## 5. The 12-row table (`modem/fixes/gates/reference_loss.toml`)

| key | loss_pct | skips | extras | opens | pop_on_empty | push_on_full | delivered | mismatches |
|---|---|---|---|---|---|---|---|---|
| R4B/n_p000 | 0.00 | 8 | -- | 9 | 34 | 0 | -- | -- |
| R4B/n_p2p5 | 0.71 | 7 | -- | 21 | 110 | 0 | -- | -- |
| R4B/n_m2p5 | 0.00 | 0 | -- | 18 | 34 | 18 | -- | -- |
| R4B/n_p10 | 6.65 | 7 | -- | 32 | 178 | 28 | -- | -- |
| R4B/n_m10 | 0.48 | 30 | -- | 9 | 34 | 17 | -- | -- |
| R4DR1/n_p000 | 0.00 | 8 | 0 | 9 | 34 | 0 | -- | -- |
| R4DR1/n_p2p5 | 0.71 | 7 | 0 | 21 | 110 | 0 | -- | -- |
| R4DR1/n_m2p5 | 0.00 | 0 | 8 | 10 | 34 | 18 | -- | -- |
| R4DR1/n_p10 | 0.00 | 7 | 37 | 23 | 178 | 0 | -- | -- |
| R4DR1/n_m10 | 0.48 | 37 | 7 | 9 | 34 | 17 | -- | -- |
| W1/p000 | -- | -- | -- | -- | -- | -- | 164 | 0 |
| W1/m10 | -- | -- | -- | -- | -- | -- | 209 | 0 |

`extras` (`r3_extras`) is a real skip-lock count only on R4DR1; on R4B trees
it is a lock-sentinel and is correctly absent from the R4B rows (`collect_reference.py`).
Every non-W1 row carries `loss_pct` (`grep -c loss_pct reference_loss.toml`
= 10, asserted both in the `collect` leg's own criterion and by
`collect_reference.py` failing loud otherwise).

## 6. Files changed

- `modem/fixes/score_matrix.py` (new; post-review: `mismatches`/`delivered`
  added to `COUNT_KEYS`, see §8)
- `modem/fixes/collect_reference.py` (new)
- `modem/fixes/gates/reference_matrix.legs` (new)
- `modem/fixes/gates/reference_loss.toml` (new -- the deliverable)
- `modem/fixes/run_gates.sh` (`--legs`, `--jobs`; post-review: prefix-extension
  dependency check, see §8)
- `modem/fixes/bank.sha256` (re-pinned for `n_p2p5.iq`)
- `modem/fixes/tests/test_score_matrix.py` (new; +2 W1-shape tests, §8)
- `modem/fixes/tests/test_run_gates_jobs.sh` (new; +legA_x/legE case, §8)
- `modem/fixes/tests/test_run_gates.py` (new)
- `docs/evidence/sp3/REFERENCE_MATRIX.md` (this file)

## 7. Self-review

- `pytest modem/fixes/tests -q`: 28 passed (26 from the first pass + 2 added
  in the post-review fix pass, §8).
- `tools/check_paths.sh`: `CHECK_PATHS_OK`.
- No board, hdl-dev-2, MATLAB, model-tree, or instrument touched. No injected
  tree modified or deleted. `n_p2p5.iq` is the only write made into
  `$SRO_SIM_DIR` (permitted, off-repo, bank re-pinned to cover it).
- Nothing was written to `progress.md`.
- `--jobs`'s dependency rule is a table-order-scheduled name/prefix match
  (see §8 for the prefix-extension fix), not a real parser; it is documented
  in `run_gates.sh` as relying on pending legs always being offered a free
  slot in table order before a later dependent leg is considered, which
  holds for every `.legs` file in this repo (a dependency's leg line always
  precedes the leg that names it).

## 8. Post-review fix pass (two defects, neither corrupted the committed table)

An advisor review of the completed matrix run found two latent defects in
code committed alongside it. Both are fixed here, with regression tests; the
already-committed `reference_loss.toml` was re-verified, not re-run.

**8a. `run_gates.sh`'s `--jobs` dependency check missed a prefix-extension
shape.** The actual matrix run's final burst shows `collect` starting while
`r4dr1_n_p10_t7` and `r4dr1_n_m10_t7` were still running:

```
Running as unit: ...-r4dr1_n_p10_t7-...
Running as unit: ...-r4dr1_n_m10_t7-...
Running as unit: ...-collect-...
LEG_PASS r4dr1_n_p10_t7  00:00:00
LEG_PASS r4dr1_n_m10_t7  00:00:00
LEG_PASS collect  00:00:30
```

`collect`'s command lists the bare prefixes (`r4dr1_n_p10`, not
`r4dr1_n_p10_t7`); the scheduler's substring check only blocked a pending
leg when a *running* leg's full name appeared verbatim in the pending leg's
text, so a leg whose name only EXTENDS a referenced prefix (`_t7` appended)
was invisible to the check. Fix: the scheduler now also tokenises the
pending leg's command/criterion text and blocks on a running leg whose name
equals a token or extends a token with a `_` suffix (`run_gates.sh`, the
`for w in $hay` loop). Regression: `test_run_gates_jobs.sh` gained `legA_x`
(a name that extends `legA` with `_x`) and `legE` (names only the bare
`legA`) -- `legE` must wait for `legA_x` specifically, not just `legA`; this
failed before the fix (`legE started before legA_x finished`) and passes
after. While building that case, a second, pre-existing defect was found and
fixed in the same test: the `: legA` dependency markers had been written
inside the leg's *script file*, invisible to the scheduler (which only reads
the `.legs` table's command field) -- so the original `legC`/`legD`
"dependency honoured" assertions had been passing by slot-contention
coincidence (`--jobs 2` with only 2 free slots), not real name-based
blocking. Fixed by moving the marker into the `.legs` command field itself
(`bash legC.sh legA`).

Was the committed `reference_loss.toml` corrupted by the race? No:
`collect_reference.py` reads `<prefix>_t7.log` files that had already
`LEG_PASS`ed (their `systemd-run` units had exited 0, `.rc`/`.log` fully
written) by the time `collect` started 30s later at the scheduler's own poll
granularity -- the overlap in the unit-launch log above is systemd unit
*creation*, not concurrent writing. Proven directly: re-running
`collect_reference.py` against the same run directory today reproduces
`reference_loss.toml` byte-for-byte (`diff` empty).

**8b. `score_matrix.py`'s `COUNT_KEYS` had no entry for `mismatches` or
`delivered`.** Both `W1/p000` and `W1/m10` rows in `reference_loss.toml`
carry only those two keys (W1 has no `loss_pct`, no paired `score_t7` leg).
With neither key in `COUNT_KEYS`, `score()` found zero intersecting count
keys for a W1 row, printed an empty detail string, and returned `ok=True`
unconditionally -- a W1 row could never fail regardless of its `_res.txt`
content. Fixed by adding both keys (they exist verbatim as `mismatches=` /
`delivered=` tokens in `w1_*_res.txt`, confirmed by direct read of the run
directory). Regression: two new tests in `test_score_matrix.py`
(`test_w1_row_scores_delivered_and_mismatches`,
`test_w1_row_with_real_mismatches_fails`) prove a W1-shaped row now scores
real content and can FAIL. Re-scoring the actual run directory against the
committed reference with the fixed `score_matrix.py` (`--map` for all 12
rows) confirms all 12 PASS with non-empty detail lines, including the two W1
rows (`mismatches=0 ref=0 ... OK delivered=164 ref=164 ... OK`, and `...209
...` for `W1/m10`).

## Concerns

- The `--jobs` dependency rule (now covering direct-name and
  prefix-extension references, §8a) still leans on the "dependency leg
  precedes dependent leg in table order" property of existing `.legs`
  files; that ordering is not independently enforced. A future `.legs`
  table that violates it would not get a loud error -- it could start a
  leg out of order silently. Worth a follow-up check in `run_gates.sh` if
  more `--jobs`-run tables are added.
- `R4DR1/n_p10` and `R4DR1/n_p000` both measured exactly 0.00 % loss, at
  or near the floor of what `score_t7.py` reports; the tolerance rule's
  0.10 pp floor means Gate 1 will accept any measurement in [-0.10, 0.10]
  for these two rows, which is a wide window in relative terms for a
  reference of 0.00. This is inherent to ruling 2's tolerance rule, not a
  defect introduced here.
