# BASE_REGEN_DIVERGENCE — regenerating the base tree from the Simulink model

Cleanup sub-project 2, Task 12a. Recorded 2026-09-10 on nemo.

**Verdict — `modem/fixes/build_base_tree.sh` reproduces the design, not the
bit-identical base tree.** Stronger than the anticipated wording: the tracked
model→netlist recipe is *not the recipe that produced the banked base tree*, and
cannot be, because the step that adds the BEATFIX/BEATOBS content the bank
carries exists only in an instrument-lineage script that rewrites the assemble
source at build time. The banked tree
`/mnt/onetb/scratch/qpsk-build-trees/base/jupiter_byte_ddrcap2_build/`
remains canonical. Per the standing ruling this was one *recorded* run and one verdict; no
attempt was made to iterate the model toward equivalence.

```
BASE_RTL_EQUIV files=308 diff=308
BASE_RTL_CLASSES header_only=134 bank_only_instrument=26 logic=148 only_in_regen=2 only_in_bank=187
BASE_REGEN_NOT_INSTRUMENT_COMPLETE stages=ddrcap ddrcap2
```

`BASE_RTL_EQUIV` must never be read without the
`BASE_REGEN_NOT_INSTRUMENT_COMPLETE` line above it: both instrument injections
failed (see §3), so the regenerated tree is not instrument-complete.

## 1. Recipe used

`modem/fixes/build_base_tree.sh <dest_parent>` — every step lifted verbatim,
only the output directory and `QPSK_LEAN=1` parameterised:

| step | lifted from |
|---|---|
| [1] fresh kit copy (rsync, same excludes) | `modem/build_byte_image.sh:17-20` |
| [2] KITDIR repoint (`sed` over `*.m`) | `modem/build_byte_image.sh:21-22` |
| [3] `timeout 5400 matlab -batch "cd('$FRESH'); build_variant_byte"` + the three artifact gates (`vivado_prj.xpr`, `ipcore/TxRxCompo_ip_v1_0.zip`, `byte_breakout` in `system.bd`) | `modem/build_byte_image.sh:24-34` |
| `QPSK_LEAN=1` | `modem/build_lean_image.sh:5` |
| [4a] `TXMARK=1 ddrcap_inject.py <tree>` then [4c] `ddrcap2_inject.py <tree>` | `modem/rtl_sim/build_ddrcap2_sim.sh:9-10` (settles the two READMEs, which disagree on order) |
| [4b] `ddrcap_bd.tcl` sourced against the opened project | `docs/superpowers/plans/2026-08-31-ddr-raw-capture.md:147-163`; `modem/instruments/ddrcap/ddrcap_bd.tcl:6` ("run against an ALREADY-OPENED project") |

HDL Coder's own workflow creates `hdl_prj_jupiter_composite/vivado_ip_prj/vivado_prj.xpr`
inside step [3]; there is no separate project-creation step.

One environment prerequisite had to be added, and is documented in the script:
the K5 overlays resolve their ROM words and golden payload from a **sibling**
`contract/` directory (`modem/msggen_rom_overlay_k5.m:20`,
`modem/fec_tx_encoder_overlay_k5.m:67`). The recorded recipe gets that for free
because `build_byte_image.sh:14` defaults the build dir to a sibling of the kit;
a regen tree written elsewhere must be given the same neighbour. The first run
died on exactly this (`Could not open file .../contract/rom_words_70_k5.txt`).

Launch (transient unit, `PATH=/usr/bin:/bin` first, 3 h cap):

```bash
systemd-run --user --collect --unit sp2-regen-$(date +%s) --same-dir bash -c \
  'PATH=/usr/bin:/bin:$PATH timeout 10800 modem/fixes/build_base_tree.sh \
   /mnt/onetb/scratch/qpsk-build-trees/regen > /mnt/onetb/scratch/qpsk-build-trees/regen.out 2>&1'
```

Three `sp2-regen-*` transient units ran before the recorded run succeeded, plainly
stated here since it is not visible anywhere else: `1789074644` failed in
2 m 39 s on the `contract/` symlink miss described above; `1789074913` ran
17:15–17:34 and failed for a reason that is no longer recoverable, because
`regen.out` was overwritten by the next attempt before anyone read it; and
`1789076373` (17:39–18:01) is the recorded run whose output is quoted
throughout this document.

## 2. Versions and wall clock

| item | value |
|---|---|
| MATLAB (`matlab -batch "disp(version)"`) | `25.2.0.3177638 (R2025b) Update 5` |
| Vivado | `/tools/Xilinx/2025.1/Vivado/bin/vivado` (present on nemo — the BD step ran locally) |
| host | nemo; boards and hdl-dev-2 untouched; no sim gate run |
| run | 2026-09-10 17:39:33 → 18:01:45, **22 min** wall; MATLAB step 1266 s |
| regen tree | `/mnt/onetb/scratch/qpsk-build-trees/regen/jupiter_byte_ddrcap2_build.regen` |
| bank | `/mnt/onetb/scratch/qpsk-build-trees/base/jupiter_byte_ddrcap2_build` |

## 3. What did not run, and why — the root finding

Both injections aborted on a missing anchor:

```
BASE_REGEN_INJECT_FAILED stage=ddrcap  rc=1 anchor=beatfix_viol_latch
BASE_REGEN_INJECT_FAILED stage=ddrcap2 rc=1     (anchor '           ddrcap_fecstart);')
DDRCAP_BD_ABORT: TxRxCompo_ip_0 is missing pin(s): dut_ddrcap_i dut_ddrcap_q
                 dut_ddrcap_mark_demod dut_ddrcap_mark_fec dut_ddrcap_valid
```

`ddrcap_inject.py:344` requires `beatfix_viol_latch` in
`TxRxCompo_ip_src_Receiver.v`. That port comes from the BEATFIX overlay, and:

* `modem/assemble_jupiter_240k5_byte.m` (tracked) contains **no**
  `beatfix_overlay` / `beatobs_overlay` / `patch_hdlworkflow_beatfix` call.
* The bank ships **its own** `assemble_jupiter_240k5_byte.m` which does:
  `patch_hdlworkflow_beatfix('hdlworkflow_loopback.m')` at line 49 and
  `beatobs_overlay(sys, loop); beatfix_overlay(sys, loop);` at lines 299-302.
* Those lines are inserted at build time by
  `modem/instruments/beatila/run_beatfix_build.sh:24,39`, which exports
  `QPSK_BEATFIX=1` and **sed-patches the assemble script itself**.
* The bank's `TxRxCompo_ip_src_Receiver.v` carries `beatfix_viol_latch` (5 hits).

The DDRCAP-v2 injector then failed for the same reason (its anchor is a port the
DDRCAP injector would have added), and `ddrcap_bd.tcl` aborted on its documented
preflight — the five capture pins do not exist on the IP boundary. The BD abort
is a *consequence*, not an independent failure, and it touches no `.v`.

The injections and the BD step are recorded, not fatal, precisely so the RTL
comparison — this stage's deliverable — is never forfeited by them.

## 4. Recipe inputs: bank vs repo

| file | bank md5 | repo md5 |
|---|---|---|
| `commhdlQPSKTxRxLoopback.slx` | `ceb6041c55a1` | `275329acf81e` |
| `assemble_jupiter_240k5_byte.m` | `2ca2f05d10fd` | `4d8ab6d81c72` |
| `build_variant_byte.m` | `84201b901b72` | `dc1be8e9124e` |
| `hdlworkflow_loopback.m` | `a3eeff752437` | `2ecb5e15232a` |

The model itself has moved on: generated headers read **Model version 11.331**
in the bank and **11.334** in the regen. `diff` of the two assemble scripts is
38 lines: the BEATFIX/BEATOBS insertion above, the post-cleanup path renames,
and a framestat-aware port-count gate.

Confirmed match: the bank **is** a LEAN build — no `state_agc_in`, no
`AdcForensic`, no `canary` in its `hdlsrc` — so `QPSK_LEAN=1` was the correct
knob to lift.

## 5. Diff, classified

Scope: every `.v` under `hdl_prj_jupiter_composite/{hdlsrc, ipcore,
vivado_ip_prj/ipcore}` of the regen vs the bank. `diff -rq`, then a per-file
`diff`. Header-only means the difference vanishes once HDL Coder's generated
header lines are stripped: `File Name`, `Created`, `Generated by`, `Module`,
`Source Path`, `Hierarchy Level`, `Model version`. The last three are stale in
the bank (they predate the IP name prefixing — the bank's `FIFO.v` says
`// Module: FIFO` while declaring `module TxRxCompo_ip_src_FIFO`); widening the
strip to include them moved no count. Full per-file report:
`<regen tree>/base_rtl_diff.txt`.

| class | count | reading |
|---|---:|---|
| compared (`files=`) | 308 | 154 shared names × 2 subtrees |
| differing (`diff=`) | 308 | **no file is byte-identical** |
| header-only | 134 | timestamp / path / model-version comment lines only |
| bank-only instrument content | 26 | bank carries a BEATFIX / BEATOBS / FrameStat / fixctl-W1 / DDRCAP marker the regen has not — incl. `TxRxCompo_ip.v`, `_dut.v`, `_axi_lite.v`, `_addr_decoder.v`, `Receiver`, `QPSK_Rx`, `TxRxComposite`, `Preamble_Detector`, `FIFO`, `Rate_Handle`, `Serializer`, `Validate_Input_Push_Pop`, `Frequency_and_Time_Synchronizer` |
| residual logic | 148 | design-content differences beyond a literal marker |
| only in regen | 2 | `TxRxCompo_ip_src_P1eArm.v` (×2 subtrees) |
| only in bank | 187 | 165 = the regen's `vivado_ip_prj/ipcore` carrying no loose `.v` (see below) + 11 modules × 2 subtrees |

The 11 bank-only modules name the missing lineage outright:
`BfContract`, `BfSerMux`, `BfGridPace`, `BfTagGen`, `FixCtlDec`,
`BeatObs`, `FrameStatProbe`, `FrameStatFifo`, `FrameStatChecksum`,
`FrameStatWordCnt`, `SimpleDualPortRAM_singlebit_block`.

The 148 residual diffs are real RTL, not cosmetics — the bank side adds
`always` blocks, `delayMatch*` pipeline registers, `uint32` status outputs and
wider types (e.g. `FIFO.numEntries` is `ufix14` in the bank, `ufix11` in the
regen). They are consistent with the bank being an older, differently-overlaid
model revision (11.331 vs 11.334) whose BEATFIX/FrameStat/fixctl fabric
perturbs shared modules without necessarily leaving a literal marker token in
each one. No claim is made here that any individual residual file is
functionally equivalent.

Two scoping notes a reader needs:

* `vivado_ip_prj/ipcore` holds **no loose `.v` in the regen** — and that is a
  SCOPE consequence, not a failure. The regen dir has `TxRxCompo_ip_v1_0.zip`,
  `prj_ip/` and `hdlwfbuildstatus.mat`; the bank additionally has the *unpacked*
  `TxRxCompo_ip_v1_0/` tree, which Vivado writes when the completion step
  (`update_ip_catalog -rebuild` inside `complete_byte_t8.tcl`) re-reads the IP.
  `build_base_tree.sh` deliberately stops before that step. It therefore
  contributed 165 to `only_in_bank` and 0 to `files`.
* The `TxRxCompo_ip_v1_0.zip` copies — which `ddrcap_inject.py` itself notes are
  what Vivado actually synthesises — were **not** byte-compared; the diff is
  scoped to loose `.v` per the task brief.

## 6. Consequences for the `hdl` stage (Task 12b)

1. `build_image.sh --from hdl` must be documented as "reproduces the design, not
   the bit-identical base tree", and the banked tree stays the default.
2. The stage cannot be gated on RTL equality. The usable gate is the artifact
   set of step [3] plus the `BASE_REGEN_INJECT_FAILED` / `BASE_RTL_EQUIV` pair
   recorded in the stamp.
3. The "fresh clone builds" story has a real hole: reproducing the base tree's
   ancestor content needs the BEATFIX/BEATOBS step, which today exists only as a
   build-time `sed` of `assemble_jupiter_240k5_byte.m` inside
   `modem/instruments/beatila/run_beatfix_build.sh`. Promoting that to a first-
   class, env-gated phase of the assemble script is the obvious follow-up — and
   is out of scope here, because doing it now would be chasing equivalence.
