# GATE0_REGEN — sp3 Task 1 (model-backport sub-project, "Gate 0")

Recorded 2026-09-11 on nemo. Sub-project: `.superpowers/sdd/2026-09-11-model-backport-sro-select/task-1-brief.md`.

## Verdict (updated 2026-09-11, post-pdWitB/timingOffset fixes)

**Gate 0 is satisfied.** The full instrument-injection chain (`txcap_inject.py` ->
`TXMARK=1 ddrcap_inject.py` -> `ddrcap2_inject.py`) now completes end-to-end (RC=0 at
every stage) against the tracked-recipe regen tree, and `BASE_REGEN_NOT_INSTRUMENT_COMPLETE`
is **absent** from a real `[5/5]`-equivalent diff run against that tree. Two ddrcap2
anchor defects were found and fixed in sequence this session (see §6 for the first,
§7 for the second); both are shape dispatches inside `ddrcap2_inject.py`, not spec
changes, and both are covered by the 2026-09-11 controller ruling recorded in
`progress.md`: ddrcap/ddrcap2 anchors must match the CURRENT model's RTL (11.334), not
the bank's. Full report: `.superpowers/sdd/2026-09-11-model-backport-sro-select/task-1-report.md`.

```
BASE_RTL_CLASSES header_only=142 bank_only_instrument=8 logic=178 only_in_regen=6 only_in_bank=167
BASE_RTL_EQUIV files=328 diff=328
```

(No `BASE_REGEN_NOT_INSTRUMENT_COMPLETE` line — the gate token. `files=328 diff=328`
is the same expected shape noted throughout this document; see §1 below.)

### Historical verdict (superseded, kept for the record)

The paragraph and numbers below were the verdict as of the first pass this session,
before the `patch_fts` pdWitB fix (§6) and the `patch_preamble_detector` timingOffset
width fix (§7):

**The tracked recipe fix (this task) is confirmed correct and effective. The regenerated
tree is still NOT instrument-complete overall — a second, pre-existing, out-of-scope defect
in the ddrcap injection chain is now exposed for the first time.**

```
BASE_RTL_EQUIV files=328 diff=328
BASE_RTL_CLASSES header_only=140 bank_only_instrument=8 logic=180 only_in_regen=6 only_in_bank=167
BASE_REGEN_NOT_INSTRUMENT_COMPLETE stages=ddrcap ddrcap2
```

`files=328 diff=328` is expected and not itself a failure signal: `[3/5]` (MATLAB
`build_variant_byte`) exits nonzero at Create Project by design (documented, gated
on the three artifact checks), so `vivado_ip_prj/**` never materialises in the regen
tree and every file under it reports `ONLY_BANK` — that accounts for the bulk of
`only_in_bank=167`. `BASE_RTL_EQUIV` must never be read without the
`BASE_REGEN_NOT_INSTRUMENT_COMPLETE` line directly above it.

## 1. What this task fixed (confirmed working)

Before this task, `beatobs_overlay`/`beatfix_overlay` and the `hdlworkflow_beatfix` patch
were applied only by a build-time Python `sed` inside
`modem/instruments/beatila/run_beatfix_build.sh` — never by the tracked
`modem/assemble_jupiter_240k5_byte.m` recipe itself. `docs/evidence/sp2/BASE_REGEN_DIVERGENCE.md`
§3-§6 root-caused this as the reason the sp2 regen attempt could never reach an
instrument-complete tree: `ddrcap_inject.py`'s `patch_receiver` step anchors on
`beatfix_viol_latch`, which only the bank (not a from-recipe regen) carried.

Fix: promoted the overlay calls into `assemble_jupiter_240k5_byte.m` as an
env-gated phase 2.20 (`QPSK_BEATOBS`/`QPSK_BEATFIX`, no-op unless set — byte-identical
HDL when unset), added the missing `beatila` addpath entry to `build_variant_byte.m`,
retired the build-time sed in `run_beatfix_build.sh`, and exported
`QPSK_BEATFIX=1 QPSK_BEATOBS=1 QPSK_FRAMESTAT=1` from `build_base_tree.sh` (the bank
is LEAN + BEATFIX + BEATOBS + FRAMESTAT per `BASE_REGEN_DIVERGENCE.md` §4; verified via
`grep -l FrameStatFifo` on the bank tree before adding the FRAMESTAT export).

Static tests (`modem/tests/test_assemble_phases.py`, 4 tests) went RED before the edit,
GREEN after (`python3 -m pytest -p no:libiio modem/tests -q` -> `4 passed`).
`tools/check_paths.sh` -> `CHECK_PATHS_OK`.

### Post-check evidence (regenerated tree, literal per brief Step 5)

```
$ grep -c beatfix_viol_latch $R/TxRxCompo_ip_src_Receiver.v
5
$ grep -c "14'b00000010000010" $R/TxRxCompo_ip_addr_decoder.v
1
$ ls $R | wc -l
182
```
where `$R = .../jupiter_byte_ddrcap2_build.regen/hdl_prj_jupiter_composite/hdlsrc/commhdlQPSKTxRxLoopback`.

Both counts are >=1: `patch_receiver` in `ddrcap_inject.py` now SUCCEEDS against the
tracked-recipe regen (`ddrcap_inject.out` line 1: `... patch_receiver -> patched ...`).
Before this fix, every regen attempt (including sp2's) failed at this exact anchor.
This is the specific defect Task 1 exists to fix, and it is fixed.

Comparing to the sp2 baseline (`BASE_RTL_EQUIV files=308 diff=308`,
`bank_only_instrument=26`) against this run's `bank_only_instrument=8`: the
`bank_only_instrument` class — diffs where only the bank carries BEATFIX/BEATOBS/instrument
content — dropped from 26 to 8, which is the expected fingerprint of promoting the overlay
into the tracked recipe. (`only_in_bank` also dropped 187 -> 167 for the same reason: fewer
files are bank-exclusive once the overlay-touched files exist in both trees.)

## 2. What is still broken (NOT this task's fix, exposed for the first time by it)

`ddrcap_inject.out`:

```
  TxRxCompo_ip_src_Receiver.v                   patch_receiver       -> patched ...
  TxRxCompo_ip_src_TxRxComposite.v              patch_composite      -> Traceback (most recent call last):
  ...
  File ".../modem/instruments/ddrcap/ddrcap_inject.py", line 631, in patch_composite
    assert '.modOut_re(Transmitter_modOut_re)' in s, 'u_Transmitter ddrcap wiring failed'
AssertionError: u_Transmitter ddrcap wiring failed
```

`ddrcap2_inject.out` fails downstream of this (`anchor missing ... 'wire Receiver_ddrcap_fecstart;'`),
a cascade of `patch_composite` never running — one root cause, not two.

### Root cause, isolated (no regen needed to re-check)

`ddrcap_inject.py`'s `patch_composite` (and `patch_transmitter`) require the model-generated
`u_Transmitter` instantiation inside `TxRxCompo_ip_src_TxRxComposite.v` to carry a
`.txFrameStart(Transmitter_txFrameStart)` port, and `patch_transmitter`'s own precondition
(line 123) is `assert 'txFrameStart' in s, f'Transmitter.v: txFrameStart missing in {path}'`.
`patch_qpsk_tx`'s precondition (line 72) spells out the actual dependency:
`assert 'txFrameStart' in s, f'QPSK_Tx.v: txFrameStart missing (apply txcap_inject.py first) in {path}'`.

Checked directly:

```
$ grep -n txFrameStart $R/TxRxCompo_ip_src_Transmitter.v   # regen, pre-patch
(no hits)
$ grep -rn txFrameStart modem/*.m modem/instruments/*/*.m
(no hits)
```

No tracked `.m` overlay creates `txFrameStart` — it is not a BEATFIX/BEATOBS-style
env-gated-phase omission (that class of bug is exactly what this task fixed). It is
created by `modem/instruments/txcap/txcap_inject.py`, a *separate* injector that
`modem/fixes/build_base_tree.sh`'s `[4/5] instrument injections` stage never invokes —
only `TXMARK=1 ddrcap_inject.py` then `ddrcap2_inject.py` are called there. The one
recorded reference build that reaches `TXMARK=1 ddrcap_inject.py` successfully,
`modem/rtl_sim/build_ddrcap2_sim.sh`, does not start from a fresh MATLAB regen either —
it starts from `s1_rtl_final`, the end of a long chain of `s1_rtl_txcap` / `s1_rtl_txfix*` /
`s1_rtl_txint` / `s1_rtl_txmark` intermediate sim trees (visible under
`modem/rtl_sim/`) that apply `txcap_inject.py` and the txfix/txmark injectors upstream of
`s1_rtl_final`. `build_base_tree.sh`'s regen path has no equivalent of that chain — it
goes straight from a fresh `build_variant_byte` MATLAB output to `TXMARK=1 ddrcap_inject.py`,
which is only safe once `txcap_inject.py` (at minimum) has already run.

This is a missing stage in `build_base_tree.sh`'s tracked recipe (or an unsafe `TXMARK=1`
without its precondition), not a BEATFIX/BEATOBS-class env-gate omission, and it touches
files (`modem/instruments/ddrcap/ddrcap_inject.py`, `modem/fixes/build_base_tree.sh`'s
`[4/5]` stage, `modem/instruments/txcap/txcap_inject.py` wiring) outside Task 1's
authorized file list. Per the brief's own escalation clause, this is being surfaced as
**NEEDS_CONTEXT**, not fixed in this task.

A secondary, independent finding: `ddrcap_inject.py`'s `main()` has no per-file
try/except around `fn(p)` (line ~1018), so a single anchor assertion aborts the entire
`os.walk` immediately — files not yet visited (here, `Transmitter.v` and `QPSK_Tx.v`,
whose visit order within a directory is filesystem-`readdir` order, not sorted) are never
attempted. This contradicts the script's own stated design intent
(`build_base_tree.sh`'s header: "An injector that cannot find its anchor is RECORDED, not
fatal"), which is true at the `build_base_tree.sh` level (it catches the nonzero exit and
continues to the diff) but not inside `ddrcap_inject.py` itself. Also out of Task 1's scope;
noted for whoever picks up the `txcap_inject.py` gap, since fixing that gap will likely also
want this robustness fix to avoid a similar one-shot masking of later files.

## 3. Recipe run record

```
systemd-run --user --collect --unit sp3-gate0-080618 --same-dir bash -c \
  'modem/fixes/build_base_tree.sh /mnt/onetb/scratch/qpsk-build-trees/regen \
   > /mnt/onetb/scratch/qpsk-build-trees/regen/gate0.log 2>&1'
```

Unit `sp3-gate0-080618.service`, started 08:06:18, consumed 25m50s CPU
(`journalctl --user -u sp3-gate0-080618`), `BASE_REGEN_DONE` at completion. MATLAB
`build_variant_byte` step elapsed 1151s with the expected nonzero exit at Create Project;
all three artifact gates (`vivado_prj.xpr`, `ipcore/TxRxCompo_ip_v1_0.zip`, `byte_breakout`
in the BD) passed.

Full log: `/mnt/onetb/scratch/qpsk-build-trees/regen/gate0.log`.
RTL diff report: `/mnt/onetb/scratch/qpsk-build-trees/regen/jupiter_byte_ddrcap2_build.regen/base_rtl_diff.txt`
(6436 lines).

## 4. Residual LOGIC-class diffs (not investigated here)

`logic=180` (up from sp2's `logic=148`) is expected to include diffs from the model
version move 11.331 -> 11.334 noted in `BASE_REGEN_DIVERGENCE.md`, unrelated to Gate 0 or
to the BEATFIX/BEATOBS/ddrcap defects above. Not classified further in this task; out of
scope for Task 1.

## 5. Disposition (updated 2026-09-11)

- The regenerated tree was **left at** `jupiter_byte_ddrcap2_build.regen` and was
  **NOT** renamed/promoted to `jupiter_byte_sp3_build`, even though the injection chain
  now completes end-to-end on it (§6, §7). Re-running `[1/5]-[3/5]` of
  `modem/fixes/build_base_tree.sh` from scratch (its own `rm -rf "$FRESH"` first step)
  would cost another ~26 minutes of MATLAB to reproduce the identical result already
  demonstrated by applying the three injectors directly to the already-regenerated tree.
  Whoever picks up Task 2 should either re-run `build_base_tree.sh` fresh (now expected
  to reach `BASE_REGEN_NOT_INSTRUMENT_COMPLETE`-absent on the first try, since both
  ddrcap2 anchor defects below are fixed) or take this already-verified tree as
  `REGEN_BASE` directly and rename it.
- This task's own deliverable (assemble carries the BEATOBS/BEATFIX phase itself) is
  complete, tested, and evidenced above; it was committed on its own merits.
  Full instrument-completeness of the regen no longer depends on adding a missing
  `txcap_inject.py` stage — see §6: the stage was already present and was
  fixed for its zip-repack gap. The `ddrcap2_inject.py` `patch_fts` `pdWitB`
  witness-identity anchor (§6) and the `patch_preamble_detector` `timingOffset`/
  `p1c_tref` width anchor (§7) were both found and fixed this session — both covered
  by the standing controller ruling that ddrcap/ddrcap2 anchors must track the CURRENT
  model's RTL (11.334), not the bank's. Gate 0 is now satisfied; see the Verdict above.

## 6. Follow-up (2026-09-11): txcap zip-repack gap found and fixed

`build_base_tree.sh`'s `[4/5]` stage already calls `txcap_inject.py "$FRESH"` before
`TXMARK=1 ddrcap_inject.py` (§2's "missing stage" framing was written before this was
confirmed) — but `txcap_inject.py` itself had **no zip-handling code at all**: it only
walked and patched the three loose files (`QPSK_Tx.v`, `Transmitter.v`,
`TxRxComposite.v`). `ddrcap_inject.py`'s own `patch_zip` extracts each matching member
from `TxRxCompo_ip_v1_0.zip` independently and re-runs the loose-file patchers against
that extracted copy — it does not inherit whatever `txcap_inject.py` already did to the
loose tree, because the zip's internal copy of e.g. `TxRxCompo_ip_src_QPSK_Tx.v` was
never touched by `txcap_inject.py` in the first place. Result: `TXMARK=1
ddrcap_inject.py`'s `patch_zip` step hit `ddrcap_inject.py`'s own `patch_transmitter`/
`patch_composite` preconditions (`assert 'txFrameStart' in s`) against a still-pristine
zip member, producing the `AssertionError: u_Transmitter ddrcap wiring failed` recorded
in §2 above — a distinct, third defect, not the same root cause as §2's ddrcap anchor
work (which was already confirmed fixed for the loose tree).

Fix: added a `patch_zip`/`PATCHERS`/`_patcher_for` triplet to
`modem/instruments/txcap/txcap_inject.py`, mirroring `ddrcap_inject.py`'s existing
`patch_zip` shape (same zip, txcap's own 3 members: `QPSK_Tx.v`, `Transmitter.v`,
`TxRxComposite.v`), and had `main()` walk for `TxRxCompo_ip_v1_0.zip` the same way
`ddrcap_inject.py`'s `main()` does. Deliberately NOT added inside `ddrcap_inject.py`'s
`patch_zip` (would make `EXPECTED_ZIP_MEMBERS` verify work it performed itself, and
would break `ddrcap_inject.py` run standalone against an already-txcap'd sim tree like
`s1_rtl_final`); deliberately NOT touching `ddrcap2_inject.py`'s separate `patch_zip`
(out of scope here, see below).

### Verification (scratch copy, no full regen needed)

Ran against a copy of the `txcap_verify` scratch tree (loose files already
txcap-patched from an earlier partial run; zip still pristine — 6 loose `txFrameStart`
hits, 0 in either `TxRxCompo_ip_v1_0.zip`):

```
$ python3 modem/instruments/txcap/txcap_inject.py <tree>
...
TXCAP_INJECT files=6 zip_members_patched=6 zips_found=2
$ TXMARK=1 python3 modem/instruments/ddrcap/ddrcap_inject.py <tree>
...
DDRCAP_INJECT loose_files=9 logical_groups_satisfied=8/8 zip_members_patched=18 zips_verified=2/2
RC=0
```

Both zip copies (`ipcore/TxRxCompo_ip_v1_0/TxRxCompo_ip_v1_0.zip` and
`vivado_ip_prj/ipcore/TxRxCompo_ip_v1_0.zip`) now hit `VERIFY_OK` against
`EXPECTED_ZIP_MEMBERS`; `ddrcap_inject.py`'s previous `u_Transmitter ddrcap wiring
failed` traceback no longer occurs. This closes the specific gap this section
documents.

### Still blocked: `ddrcap2_inject.py`'s `pdWitB` anchor (pre-existing, separate, NOT fixed here)

Continuing the chain, `python3 modem/instruments/ddrcap2/ddrcap2_inject.py <tree>`
exits 1 at `patch_fts` (`ddrcap2_inject.py:159`):

```
AssertionError: anchor missing in .../TxRxCompo_ip_src_Frequency_and_Time_Synchronizer.v:
'                                        .pdWitB(pd'
```

This is the pre-existing `pdWitB` gap already flagged (alongside `dbgcap_inject.py`'s
`pdWitA`) as needing a controller decision about what the current-generation (11.334)
witness signal actually is — not a mechanical anchor-text rename like the
`debugMuxCtrl_1` -> `debugMuxCtrl` fix elsewhere in this chain, because there is no
sighting of an equivalent old-register/new-source pair to confirm the substitution.
**`BASE_REGEN_NOT_INSTRUMENT_COMPLETE` therefore still stands; Gate 0 remains blocked**
on this one remaining anchor, now isolated as the sole blocker in the ddrcap/ddrcap2
chain (the txcap zip gap and the original ddrcap loose-file anchor from §1/§2 are both
confirmed fixed).

## 7. Follow-up (2026-09-11, cont'd): patch_preamble_detector timingOffset width found and fixed

Continuing the chain past the §6 `pdWitB`/`fs_runmax` fix, `ddrcap2_inject.py` advanced
to a later, different anchor failure inside `patch_preamble_detector`:

```
AssertionError: anchor missing in .../TxRxCompo_ip_src_Preamble_Detector.v:
'  wire [13:0] Peak_Search_timingOffset;  // ufix14\n'
```

### Root cause, isolated

Checked directly, not assumed:

- Bank (`modem/rtl_sim/s1_rtl_txmark/.../Preamble_Detector.v`) and every `rtl_sim/s1_rtl_*`
  intermediate stage through `s1_rtl_final`, including `s1_rtl_ddrcap2` itself
  (mtime 2026-09-02): `Peak_Search_timingOffset` / `Peak_Search_p1c_tref` are
  `[13:0] // ufix14`.
- The regen tree's `hdl_prj_jupiter_composite` (both the `hdlsrc` copy and the
  `ipcore/TxRxCompo_ip_v1_0` zip-extracted copy, mtime 2026-09-11 -- i.e. generated by
  *this* run's composite-build step): both are `[10:0] // ufix11`, 3 bits narrower.
- No other `Preamble_Detector` port width differs (`p1c_heldts`, `Correlator_dataOut`/
  `threshold`/`validOut`, `fs_runmax` all match the bank), and `Symbol_Synchronizer`'s
  `dc_countreg`/`dc_mu` widths are unaffected (checked directly).
- A real downstream consumer exists: `ops/flash/ddrcap2_decode.py` decodes the
  DDRCAP-v2 record as `ch2 = {mark_demod, mark_fec, timingOffset[13:0]}` -- a 14-bit
  field is part of the on-disk record-layout contract, not just the injector's internal
  bookkeeping.

This is the current (11.334) model's HDL Coder codegen genuinely producing a narrower
`Peak_Search_timingOffset`/`p1c_tref` -- not an anchor-text typo, and not a stale/
uncommitted composite directory (mtimes and a build-script cross-check both rule that
out). It is covered by the same standing controller ruling as §6: ddrcap/ddrcap2 anchors
must match the CURRENT model's RTL, not the bank's -- and here, unlike `pdWitB`, there is
a real 14-bit-vs-11-bit equivalent (not a dead net), so this was implemented as an
in-scope shape dispatch.

### Fix

`patch_preamble_detector` now dispatches on the width shape of
`Peak_Search_timingOffset`/`Peak_Search_p1c_tref`: bank shape (`ufix14`) keeps the
direct `assign dc_toff = Peak_Search_timingOffset;`; regen shape (`ufix11`) zero-extends
at the source assign (`assign dc_toff = {3'b0, Peak_Search_timingOffset};`). `PD_PORTS`
-- and therefore `dc_toff`/`dc_tref`'s own port width -- stays `[13:0]` in both cases, so
every downstream consumer (`patch_composite`'s `[13:0]` part-selects,
`ops/flash/ddrcap2_decode.py`'s record layout, and the pre-existing bank-shape test
`ops/tests/test_ddrcap2_inject.py:40`) is unaffected. Under 11.334, DDRCAP-v2
`dc_toff`/`dc_tref` now carry only 11 significant bits (top 3 read zero) because
`Peak_Search` doesn't produce them; a future SRO/timing need for offsets >2047 is a
model-side search-window question, not an injector one.

Tests: `modem/instruments/ddrcap2/test_ddrcap2_inject_fts_shapes.py` gained 3 cases
(bank-shape, regen-shape zero-extend, idempotency), folded into the module's `run()`
list; all 6 cases in that file pass. Full suite
(`modem/fixes/tests modem/instruments ops/tests modem/tests`): `146 passed in 220.71s`
(up from the 143-test baseline recorded for §6, +3 for these cases) --
`ops/tests/test_ddrcap2_inject.py`'s verilator-gated bank-shape tests pass unchanged.

### End-to-end verification on the live regen tree

Ran the three injectors directly against the live tree at
`.../jupiter_byte_ddrcap2_build.regen/hdl_prj_jupiter_composite` (not a scratch copy):

```
$ python3 modem/instruments/txcap/txcap_inject.py "$T"             ; RC=0
TXCAP_INJECT files=6 zip_members_patched=6 zips_found=2
$ TXMARK=1 python3 modem/instruments/ddrcap/ddrcap_inject.py "$T"  ; RC=0
DDRCAP_INJECT loose_files=9 logical_groups_satisfied=8/8 zip_members_patched=18 zips_verified=2/2
$ python3 modem/instruments/ddrcap2/ddrcap2_inject.py "$T"         ; RC=0
DDRCAP2_INJECT loose=7 missing=[] zips=2 zips_verified=2
```

Then ran the `[5/5]` RTL-diff logic from `build_base_tree.sh` (lines 193-237)
standalone against this tree -- no re-run of `[1/5]-[3/5]` (the ~26-minute MATLAB
regen) needed, since the injectors were applied directly to the already-regenerated
tree:

```
BASE_RTL_CLASSES header_only=142 bank_only_instrument=8 logic=178 only_in_regen=6 only_in_bank=167
BASE_RTL_EQUIV files=328 diff=328
```

No `BASE_REGEN_NOT_INSTRUMENT_COMPLETE` line. **Gate 0 is satisfied** as of this run;
see the Verdict at the top of this document. Full narrative:

## 8. Fix round 1-2 (2026-09-11): Transmitter.v port-list defect, fresh regen, compile proof

Task 2's Verilator probe (downstream of §7's Gate-0-satisfied regen) found that
`modem/rtl_sim/s1_rtl_model/Transmitter.v` (the prefix-stripped copy of the regen's
`TxRxCompo_ip_src_Transmitter.v`) declared `output txFrameStart;` and
`modOut_re`/`modOut_im`/`modValid`/`scramBit`/`scramValid` as I/O, but its module PORT
LIST still ended `..., extWordPop, fs_txur);` -- under the current (11.334) model,
FrameStat's `fs_txur` lands AFTER `extWordPop`, so `txcap_inject.py`'s
`"           extWordPop);"` anchor and `ddrcap_inject.py`'s `"           txFrameStart);"`
anchor (chained off txcap's own literal) both silently missed the port-list splice
while their separately-anchored I/O-declaration edits still landed -- a
declared-but-unlisted-port defect that compiles right up to Verilator's port-count
check.

**Fix (round 1, carried into this round):** `modem/instruments/txcap/txcap_inject.py`
and `modem/instruments/ddrcap/ddrcap_inject.py` both gained an `_append_top_ports(s,
new_ports)` helper that finds the module's own `module ... ( ... );` port-list block via
regex and splices new ports in after whatever its CURRENT last port is, instead of a
frozen literal. `patch_qpsktx`/`patch_transmitter` (txcap) and `patch_qpsk_tx`/
`patch_transmitter` (ddrcap) were switched to use it.

**Fix (round 2, this pass):** auditing every module both injectors extend
(the ruling's instruction: "check QPSK_Tx.v, Transmitter.v, TxRxComposite.v and the
`TxRxCompo_ip_src_` prefixed variants") found `ddrcap_inject.py`'s `patch_composite`
(TxRxComposite.v's own top-level port-list append, for the five `ddrcap_*` ports) was
still left on the same literal-anchor pattern
(`"           beatfix_viol_count,\n           beatfix_viol_latch);"`). It had not yet
manifested as a live defect -- nothing currently trails `beatfix_viol_latch` in the
11.334 regen tree -- but it is the identical defect class the ruling flagged this file
for, so it was switched to `_append_top_ports` too. `QPSK_Rx.v`/`Receiver.v`'s own
port-list appends (`patch_qpsk_rx`/`patch_receiver`) and the IP-wrapper files
(`TxRxCompo_ip_dut.v`/`TxRxCompo_ip.v`) use the same brittle literal-anchor shape and
are out of this round's named scope (not listed in the ruling); flagged as a residual
risk for whoever next touches those files.

`modem/fixes/build_base_tree.sh`'s `[1/5]` rsync exclude was also widened from
`s1_rtl` to `s1_rtl*` (round 1) -- a fresh kit copy otherwise carried 30+
`rtl_sim/s1_rtl_*` sim-variant trees that the injectors then walked into and mis-patched.

### Test coverage

`modem/instruments/txcap/test_txcap_inject_portlist_shapes.py` and
`modem/instruments/ddrcap/test_ddrcap_inject_portlist_shapes.py`: each now carries a
bank-shape and a regen-shape fixture (asserting zero declared-but-unlisted outputs) for
every top-level-port-list-extending patcher in its file --
`patch_transmitter`/`patch_qpsktx` (txcap), `patch_transmitter`/`patch_qpsk_tx` (ddrcap),
plus two direct `_append_top_ports` splice tests standing in for `patch_composite`
(TxRxComposite.v's own patcher pulls in many unrelated wire/instantiation anchors that
are outside the port-list defect class this fix addresses; the splice itself is proven
against both a bank-shape and a synthetic regen-shape-with-a-trailing-port tail).
14 cases total, all pass:

```
$ python3 modem/instruments/txcap/test_txcap_inject_portlist_shapes.py
TEST_TXCAP_INJECT_PORTLIST ALL PASS   (6 cases)
$ python3 modem/instruments/ddrcap/test_ddrcap_inject_portlist_shapes.py
TEST_DDRCAP_INJECT_PORTLIST ALL PASS  (8 cases)
```

### Fresh regen rerun (`gate0_t1r1_rerun.log`)

A clean `build_base_tree.sh` regen under the round-1 fix (widened rsync exclude +
generalised port-list splice) ran to completion:

```
TXCAP_INJECT files=6 zip_members_patched=6 zips_found=2
DDRCAP_INJECT loose_files=9 logical_groups_satisfied=8/8 zip_members_patched=18 zips_verified=2/2
DDRCAP2_INJECT loose=7 missing=[] zips=2 zips_verified=2
BASE_REGEN_DONE tree=/mnt/onetb/scratch/qpsk-build-trees/regen/jupiter_byte_ddrcap2_build.regen
BASE_RTL_CLASSES header_only=142 bank_only_instrument=8 logic=178 only_in_regen=6 only_in_bank=167
BASE_RTL_EQUIV files=328 diff=328
```

All three injectors `RC=0`; `BASE_REGEN_INJECT_FAILED`, `DDRCAP_BD_ABORT`, and
`BASE_REGEN_NOT_INSTRUMENT_COMPLETE` are all absent. The class histogram is the same
shape as §7's (`only_in_bank=167` is dominated by `vivado_ip_prj/**`, which never
materialises because MATLAB's Create Project stage exits nonzero by design -- not a
regression). The tree was promoted:
`/mnt/onetb/scratch/qpsk-build-trees/regen/jupiter_byte_ddrcap2_build.regen` ->
`/mnt/onetb/scratch/qpsk-build-trees/regen/jupiter_byte_sp3_build` (this IS `REGEN_BASE`
as of this round; the earlier broken pre-round-1 tree is banked alongside it as
`jupiter_byte_sp3_build.t1r0`).

### Port-list audit (step 2)

A short script walked every `module ... ( ... );` block in every `.v` file under
`jupiter_byte_sp3_build/hdl_prj_jupiter_composite/hdlsrc/commhdlQPSKTxRxLoopback/` and
checked that every `output`/`input name;` declaration inside that module's body also
appears in its own port list:

```
PORTLIST_AUDIT files_checked=168 violations=0
```

(168 module blocks across the tree's `.v` files; `files_checked` counts module blocks,
not files -- several files carry more than one `module ... endmodule`.) Zero
declared-but-unlisted violations -- the exact defect class Task 2's probe found is
confirmed absent from the promoted `REGEN_BASE` tree.

### Compile proof (step 3)

```
$ cd modem/rtl_sim && bash make_sro_trees.sh --from-regen /mnt/onetb/scratch/qpsk-build-trees/regen/jupiter_byte_sp3_build
SRO_TREE_MODEL /mnt/onetb/scratch/qpsk-jupiter-modem/modem/rtl_sim/s1_rtl_model files=167
MAKE_SRO_MODEL_WRAP .../wrap_byte_w1_model.v
MAKE_SRO_MODEL_WRAP .../wrap_byte_sro4b_model.v
MAKE_SRO_MODEL_WRAP .../wrap_byte_sro4d_model.v
MAKE_SRO_MODEL_WRAP .../wrap_byte_bs_model.v
MAKE_SRO_FROM_REGEN_DONE /mnt/onetb/scratch/qpsk-jupiter-modem/modem/rtl_sim/s1_rtl_model

$ TREE=$PWD/s1_rtl_model FIXCTL=0 SKIP_MARKER=1 bash build_sro_w1.sh
TREE_MARKER_SKIPPED /mnt/onetb/scratch/qpsk-jupiter-modem/modem/rtl_sim/s1_rtl_model W1
```

`s1_rtl_model` regenerated cleanly (167 files, the prefix-stripped copy of the
now-Gate-0-satisfied `REGEN_BASE` tree). `build_sro_w1.sh` DID surface a `%Error`, but
not in an injector-touched module's own port-list shape -- verbatim from
`obj_byte_w1_w1_model_0_verilate.log`:

```
%Error: .../wrap_byte_w1_model.v:83:44: Can't find definition of 'w1Bus' in dotted
variable: 'dut.u_Receiver.u_QPSK_Rx.w1Bus' (repeats for w1A/w1B/w1cSS/w1cRH/w1cCFC/
w1cCS/w1cPD, lines 83-90)
```

`wrap_byte_w1_model.v` is `make_sro_trees.sh`'s auto-generated model variant of
`wrap_byte_w1.v` (the RXFIX_W1 sim wrapper) -- it references `w1Bus`, a wire the
**RXFIX_W1 overlay** injects into `QPSK_Rx`, a completely different instrument chain
from txcap/ddrcap/ddrcap2 and never applied to `s1_rtl_model` at all (confirmed:
`grep -rl w1Bus s1_rtl_model/` returns nothing). This is not a port-list shape defect in
a txcap/ddrcap/ddrcap2-touched module -- it is the RXFIX_W1 overlay not yet being
ported onto the model tree, a model-side instrumentation gap outside this task's chain.
**Reported verbatim as a concern per the brief's step 3 disposition; no fix attempted
here** (Task 4 owns model-side issues). The PINMISSING warnings earlier in the same log
(`framestat_stat`, `beatfix_viol_count`, `ddrcap_i`, etc. on the `TxRxComposite dut(`
instantiation inside `wrap_byte_w1_model.v`) are Warnings, not Errors, and are the same
class of "wrapper doesn't yet wire the composite's newer ports" gap -- also not this
task's chain.

### Tests + path check (step 4)

```
$ python3 -m pytest -p no:libiio modem/instruments modem/tests -q
28 passed in 0.17s
$ bash tools/check_paths.sh
CHECK_PATHS_OK
```

Full narrative:
`.superpowers/sdd/2026-09-11-model-backport-sro-select/task-1-report.md`.

## Fix round 3: the rate rung

Rounds 1-2 regenerated at the **wrong rate rung**. `modem/fixes/build_base_tree.sh`
exported `QPSK_LEAN/BEATFIX/BEATOBS/FRAMESTAT/RXFIX=1` but not `QPSK_FRAME` or
`QPSK_SPS`, and `modem/frame_config_k5.m:21` defaults `sps = 8`. The deployed
lineage sets both next to `QPSK_LEAN` --
`modem/instruments/beatila/run_beatfix_build.sh:20-21`:

```
export QPSK_FRAME=f1536
export QPSK_SPS=4
```

### Proof that the round-2 tree was sps=8

| evidence | sps=4 (bank / harness) | round-2 regen |
|---|---|---|
| `TxRxCompo_ip_src_Rate_Handle.v` mod-N counter | `reg [1:0] HDL_Counter_out1;  // ufix2` | `reg [2:0] HDL_Counter_out1;  // ufix3` |
| `build_byte_matlab.log` | — | `240k5_byte params ACTIVE: sps=8`, `rate_240k_overlay: Input Data Rsym 3.84e6 -> 1.92e6 (rail 15.36e6, sps=8)`, `ss8_fix_overlay: ... (sps=8)` |
| gate stimuli | `sim_w1.cpp:47  FRSAMP = 49332` = 12,333 sym x **4** sps | same file, unchanged |

Bank path
`/mnt/onetb/scratch/qpsk-build-trees/base/jupiter_byte_ddrcap2_build/hdl_prj_jupiter_composite/hdlsrc/commhdlQPSKTxRxLoopback/TxRxCompo_ip_src_Rate_Handle.v:58`;
round-2 regen path the same file under
`/mnt/onetb/scratch/qpsk-build-trees/regen/jupiter_byte_sp3_build.sps8/...:70`.

### Fix

The two exports were added to `build_base_tree.sh` with the citation and the
HDL_Counter width proof in a comment, and
`modem/tests/test_assemble_phases.py::test_build_base_tree_exports_instrument_env`
now asserts both (`export QPSK_FRAME=f1536`, `export QPSK_SPS=4`).

### Regen at the corrected rung

```
BASE_REGEN_DONE tree=.../jupiter_byte_ddrcap2_build.regen        (moved to jupiter_byte_sp3_build)
BASE_RTL_CLASSES header_only=288 bank_only_instrument=6 logic=36 only_in_regen=6 only_in_bank=165
BASE_RTL_EQUIV files=330 diff=330
```

No `BASE_REGEN_INJECT_FAILED`, no `BASE_REGEN_NOT_INSTRUMENT_COMPLETE` (one run,
unit `sp3-rung-144018`, 14:40:18 -> 14:51, MATLAB ~11 min).

Post-checks, all held:

| check | result |
|---|---|
| MATLAB log rung | `240k5_byte params ACTIVE: sps=4 thr=0.0125`; `rate_240k_overlay: DONE (... Rsym*sps rail = 1.536e+07, sps = 4)`; `MSGGEN ROM OVERLAY (K5) APPLIED (packed 770xuint32, frame=f1536)`; `f1536 span=12320 symbols` |
| `TxRxCompo_ip_src_Rate_Handle.v` | `reg [1:0] HDL_Counter_out1;  // ufix2` (was `[2:0]`) |
| `TxRxCompo_ip_src_RxW1Census.v` | present |
| 0x214 decode | `grep -c "8'b10000101" TxRxCompo_ip_addr_decoder.v` -> 1 |
| `BASE_RTL_CLASSES` **logic** | **180 -> 36** (`header_only` 142 -> 288, `only_in_regen` 8 -> 6, `only_in_bank` 167 -> 165) |

The `logic` class is the load-bearing number: 144 of the 180 logic-level RTL
differences against the banked base tree were the rate rung. What remains (36)
is the residual regen-vs-bank delta this sub-project is measuring.

Sim-tree refresh (`modem/rtl_sim`):

```
bash make_sro_trees.sh --from-regen .../jupiter_byte_sp3_build
  SRO_TREE_MODEL ... s1_rtl_model files=168
  MAKE_SRO_MODEL_WRAP_W1TAPS wrap_byte_w1_model.v (8 composite-port taps)
bash tree_marker.sh $PWD/s1_rtl_model W1   ->  TREE_MARKER ... W1 model
grep -n "HDL_Counter_out1;" s1_rtl_model/Rate_Handle.v -> 70:  reg [1:0] ...  // ufix2
```

i.e. the tree the W1 legs run on is confirmed sps=4 by content, not by the
refresh command's exit code.

