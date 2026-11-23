# TXFIX_F3_GATE — sp3 Task 8 (TX F1+F2+F3 as a model overlay)

Recorded 2026-09-11 on nemo. Sub-project:
`.superpowers/sdd/2026-09-11-model-backport-sro-select/task-8-brief.md`.
Overlay: `modem/rxfix/txfix_f3_overlay.m` (phase 2.21, env `QPSK_RXFIX`), replacing
`modem/fixes/txfix_inject.py` variant `F3` (F1+F2+F3; F3b margin NOT applied).

## 1. REGEN8 — the model tree

```
unit          sp3-f3-204116.service          (systemd-run --user)
cmd           modem/fixes/build_base_tree.sh /mnt/onetb/scratch/qpsk-build-trees/regen8
tree          /mnt/onetb/scratch/qpsk-build-trees/regen8/jupiter_byte_ddrcap2_build.regen
log           /mnt/onetb/scratch/qpsk-build-trees/regen8/f3.log
wall          20:41:16 -> 21:06  (~25 min; MATLAB stage 1500 s)
BASE_RTL_CLASSES header_only=200 bank_only_instrument=6 logic=124 only_in_regen=10 only_in_bank=165
BASE_RTL_EQUIV   files=330 diff=330
BASE_REGEN_INJECT_FAILED / BASE_REGEN_NOT_INSTRUMENT_COMPLETE : ABSENT
```

The overlay's own trace in `build_byte_matlab.log`:

```
txfix_f3: F1 latch reset gated by the sampleCount==0 boundary
txfix_f3: F2 frameCount saturates (no 3->0 wrap, no 0->3 underflow)
txfix_f3: F3 dataReady gated by ~fullRAM
txfix_f3: F3 occupancy count saturates (no 65535->0 wrap, no 0->65535 underflow)
TXFIX_F3_OVERLAY_OK: ... (variant F3; F3b margin NOT applied)
```

Gate tree: `modem/rtl_sim/s1_rtl_model_tx` — a FLAT, prefix-stripped copy of the
regen's `hdlsrc/commhdlQPSKTxRxLoopback` (170 `.v` files) plus `RXFIX_ORIGIN`,
the same shape `make_sro_trees.sh --from-regen` writes for `s1_rtl_model` (Task
6's tree, untouched). Flat because `tree_marker.sh` reads `<tree>/Bit_Packetizer.v`
and `build_txkick_sim.sh` accepts either shape.

```
TREE_MARKER s1_rtl_model_tx F3 model
TREE_MARKER s1_rtl_txfix_F3/hdlsrc/commhdlQPSKTxRxLoopback F3 injector
```

## 2. Post-check on the generated RTL (all four patches), POSTCHECK_RC=0

```verilog
// Bit_Packetizer.v            (injector: assign dataReady = DataReadyPaceCmp_out1 & Logical_Operator2_out1;)
assign Logical_Operator2_out1 =  ~ Data_Bits_FIFO_fullRAM;
assign TxF3ReadyGate_out1 = DataReadyPaceCmp_out1 & Logical_Operator2_out1;
assign dataReady = TxF3ReadyGate_out1;

// Data_Bits_FIFO.v
assign TxF1BoundaryGuard_out1 = Compare_To_Constant1_out1 & Compare_To_Constant3_out1;
  if (enb_1_2_0) begin
    if (TxF1BoundaryGuard_out1 == 1'b1) begin
      Unit_Delay_Enabled_Resettable_Synchronous_out1 <= 1'b0;
    end else begin
      if (Compare_To_Constant3_out1) begin
        Unit_Delay_Enabled_Resettable_Synchronous_out1 <= Compare_To_Constant2_out1;

// RAM_Frame_Status_Indicator.v          reg [1:0] frameCount;  // ufix2
if ((fcInc && ( ! fcDec)) && (frameCount != 2'b11)) ...  else if ((fcDec && ( ! fcInc)) && (frameCount != 2'b00)) ...

// MATLAB_Function1.v                    reg [15:0] count;  // ufix16
if ((wr && ( ! rd)) && (count != 16'b1111111111111111)) ... else if ((rd && ( ! wr)) && (count != 16'b0000000000000000)) ...
full_1 = count_temp > 16'b1100000001111111;             // 49279 -- F3, NOT the F3b 49263
```

Harness-tap census (all present on the model tree, so `sim_txfix_force.cpp` and
`txrate_probe.cpp` see what they force):
`Unit_Delay_Enabled_Resettable_Synchronous_out1`, `Logical_Operator_out1`,
`Delay3/5/6/7_out1`, `HDL_Counter{,1,2}_out1`, `u_MATLAB_Function1.count`,
`u_RAM_Frame_Status_Indicator.frameCount`, and on the composite
`Transmitter_txFrameStart`, `ddrcap_fec_mark_now`, `ddrcap_fec_mark_latch`,
`fixctl`.

Note on `tree_marker.sh <tree> F3`: its model-path check is only
`grep -q fullRAM Bit_Packetizer.v`, which the **unpatched** file already satisfies
(`wire Data_Bits_FIFO_fullRAM`). It is reported because the brief asks for it; the
`dataReady` assign above is the evidence.

## 3. Gate matrix — injected reference vs model, side by side

There is no banked model reference, so the reference is the **injected**
`s1_rtl_txfix_F3` tree, rebuilt and re-run here; the 2026-09-03 banked summary
(`modem/rtl_sim/evidence/txfix_gate_summary.txt`) is a cross-check only.

```
reference  TREE=s1_rtl_txfix_F3  OBJ=obj_txkick_ref / obj_txrate_ref
model      TREE=s1_rtl_model_tx  OBJ=obj_txkick_m8  / obj_txrate_m8
harness    sim_txfix_force.cpp (kick), txrate_probe.cpp (rate)
rows       the eight |F3| rows of modem/rtl_sim/evidence/txfix_gate_runs.txt,
           + G13 (derived from G11's log) + G14 (lint), 4 concurrent
score      modem/rtl_sim/txfix_gate_score.py (unmodified)
```

| row | injected `s1_rtl_txfix_F3` | model `s1_rtl_model_tx` | evidence fields (identical unless noted) |
|---|---|---|---|
| G3 (none, golden digest) | **PASS** `aligned_identical=True` 1,305,860 records, 106 markers | **FAIL** `no marker found` 1,305,852 records | see §3.1 — record-layout mismatch, not a TX difference |
| G4/G5 F3_k0 (popabort) | PASS | PASS | `d3_post=0 armed=1 pop=1 saw_armed_zero=0 max_pop_quiet=2`; `all_offsets_zero=True` over **58 frames on the reference, 0 frames on the model** — see §3.3 |
| G4/G5 F3_k6 (popabort) | PASS | PASS | as above |
| G6 (latchforce) | **FAIL** | **FAIL** | `saw_armed_one=1 armed_one_clk=690750 clk_to_reload=49410 max_pop_quiet=49516` — the banked 2026-09-03 summary also has `G6 F3 FAIL` |
| G7 (latchforce_pre) | PASS | PASS | `saw_armed_one=1 armed_one_clk=592086 clk_to_reload=1 max_pop_quiet=107`; its verdict is **`all_offsets_zero` ALONE**, which on the model tree is over an empty list — see §3.3 |
| G9 (fcbase3, txrate) | PASS | PASS | `zeroEvents=0 armedDropClk=-1 maxPopQuietClk=0 pushWraps=54 popWraps=52 frames=53 count in [24665, 26018]` |
| G10 (frcwrap) | PASS | PASS | `pre=2 saw_self_wrap=0 wrap_clk=-1` |
| G11 (nearfull) | PASS | PASS | `saw_full=1 full_clk=493426 saw_pop_abort=0 overshoot_past_49279=1 changes=38 fullRAM_stuck_at_end=False count in [49279, 49280] near_65536=False wrap_step=False` |
| G13 (derived from G11) | PASS | PASS | `doubled_push_rate_seen=False` |
| G14 (lint, all variants) | PASS | PASS | `exit=0`, 10 `TXFIX_LINT_OK_F3_*` tags |

**Verdict: 8 of the 9 rows that PASS on the injected tree PASS on the model tree; G3
does not.** Every TX witness on every other row is not merely equal in verdict but
**bit-identical, including the forced-event clock stamps** (`armed_one_clk=690750`,
`full_clk=493426`, `clk_to_reload=49410`) — the transmitter's timeline is
cycle-identical between the netlist injection and the model overlay. So are the
harness banners on all eight rows, including the deliberately-corrupted BIST counts
(`biterr=51` nominal, `3320` on G6, `2391` on G7) and `packets=106 / txFrameStartPulses=108`.

### 3.1 Why G3 FAILs on the model tree (and what it does and does not show)

`txfix_gate_score.py`'s golden digest aligns the two `.bin` files on a `0x7FFF`
word in record lane 2. Measured on the two files:

```
injected  lane2: {0: 1305754, 0x7FFF: 106}      lane3: {0: 1305754, 0x7FFF: 106}   <- DDRCAP v1 marker
model     lane2: {0x3023: 1305639, 0x7023: 106, 0xB023: 106}   lane3: dense data   <- DDRCAP-v2 packing
```

The model tree carries **DDRCAP-v2**, which repacks lanes 2/3 (the frame mark is now
bits 14/15 above a 12-bit payload); the injected txfix lineage descends from
`s1_rtl_txmark`, which is DDRCAP v1. The scorer finds no `0x7FFF` and returns
`no marker found` — a *record-layout* mismatch between two lineages, before any
comparison of content happens.

Comparing what G3 is actually about — the delivered I/Q (lanes 0/1) — with each
file aligned on its own marker convention:

```
injected F3  vs  unfixed U : 1,305,860 records, differing I/Q records = 0   (IDENTICAL)
model    F3  vs  unfixed U : 1,305,852 records, differing I/Q records = 255
model    F3  vs  injected F3 :                  differing I/Q records = 255
```

The 255 differing records are 47 small clusters confined to records 110,908-199,074
(frames ~9-16 of 106) and are **not** a time shift (a +/-1 record shift makes the
match worse, 88,199 of 88,200); the values differ by ~0.3 % of full scale. Every
other record of the 1.3 M is identical.

Three things place that delta outside this overlay:

1. **The capture is a RECEIVER tap.** `SEL=6` drives `iq_debug_mux`, the QPSK Rx
   diagnostic mux (`iq_debug_tap_overlay.m`: 0 = AGC out, 1 = post symbol sync,
   2 = post carrier sync, 3 = constellation; 6 = the tap3 symbol domain). There is
   **no TX-side selector in this instrument**, so on a model tree G3 compares an RX
   symbol-domain stream that also carries W1, STEER (R4B skip live at `fixctl=0`),
   R1, BS and PAD against a baseline from the pre-RX-overlay `s1` lineage. It cannot
   isolate a transmitter change.
2. **The decoded bits are identical.** `biterr=51` and `packets=106` on both trees
   for G3 — and the same on every other row, including the two forced-corruption
   rows. A transmitter difference would move those.
3. **Every TX witness is bit-identical**, clock stamps included (table above).

So G3 is recorded as **not met on the model tree, cause localised, not attributable
to `txfix_f3_overlay.m`**. Making it meaningful again needs a TX-domain capture
selector or a DDRCAP-v2-aware marker in `txfix_gate_score.py` — neither is in this
task's scope (the scorer is shared with the injected-tree chain).

### 3.2 The same v1 marker makes three more model rows' offset evidence vacuous

`kick_seq.py` finds frames with the same `MARK = 0x7FFF` on lane 2, so on a DDRCAP-v2
model tree it returns **zero rows for every bin**, and `all_offsets_zero` over an empty
list is `True`. Measured:

```
                      model   reference
g3_none_F3            0       106
g4_popabort_F3_k0     0        58
g4_popabort_F3_k6     0        58
g7_latchforce_pre_F3  0        58      <- G7's verdict is all_offsets_zero ALONE
```

So the v1-marker dependency costs **four** rows, not one: G3 fails outright, G7's model
PASS carries no information from the scorer, and the offset component of both G4/G5 rows
is empty (their `d3_post` / `armed` / `pop` / `saw_armed_zero` / `max_pop_quiet` evidence
is real and bit-identical). Restoring `tap3_word_to_offset.tsv` fixed the map *lookup*;
it cannot conjure a marker that is not in the file.

**Supplement (a scratch copy of `kick_seq.py` with a lane2-bit-14 fallback; the shared
scorer was NOT touched).** With a v2-aware marker the model bins decode 106 / 58 / 58 /
58 frames, and the per-frame offset sequence for `g3_none_F3` is:

```
frame  0      : 12319                      (partial first frame)
frames 1-8    : 12272  (constant)
frames 9-16   : 12271 12270 ... 12264      (monotone, exactly -1 per frame)
frames 17-105 : 12264  (constant)
```

The absolute value is a fixed decode-window phase (it tracks `skew` 1:1 and is not
comparable across the two record layouts); what matters is that the offset is **constant
except for eight consecutive one-symbol retimings in frames 9-16** — the same window as
the 255-record I/Q delta above. Eight is `RxSteer`'s lock threshold (`frames == uint8(8)`
pcEnd pulses before the steering arms, `rxfix_steer_overlay.m`). The model tree's receiver
re-times by one symbol per frame while the steering settles, then holds. That is the RX
steering overlay behaving as specified, on a capture that is an RX tap — and it is
constant across every frame before and after, which is what a TX-invariance argument
needs.

### 3.3 Two scoring inputs the 2026-09 cleanup had left dangling

Found while scoring, fixed here, and both *degrade the score silently* rather than
failing it:

* `modem/rtl_sim/txfix_gate_runs.txt` — the scorer builds its
  `(gid, prefix) -> wrapper log` map from this path, but the cleanup left the
  manifest only under `evidence/`. Result: **every row scored "incomplete -- no
  TXFIX_GATE_RUN_EXIT trailer yet"** with the trailers present. Fixed in the scorer
  rather than with an untracked copy: `txfix_gate_score.py` now falls back to the
  **tracked** `rtl_sim/evidence/txfix_gate_runs.txt` (`modem/rtl_sim/*.txt` is
  gitignored and `!modem/rtl_sim/evidence/**` is what un-ignores it there), so there is
  one manifest and no file a fresh checkout lacks. A copy beside the script still wins,
  for ad-hoc row sets.
* `ops/offsetmap/tap3_word_to_offset.tsv` — `kick_seq.py` loads it; without it every
  per-frame offset list is empty, so `frames_scored=0` and G3/G4/G7's
  `all_offsets_zero=True` passes **vacuously**. Restored from
  the pre-cleanup tag (12,321 rows); the reference pass was re-scored with it and G3
  then reported `frames_scored=106`. **This is a scope deviation** — `ops/` is not among
  this task's files — taken because the gate cannot be scored without it;
  `tools/check_paths.sh`'s waiver text, which recorded `ops/offsetmap/` as absent, is
  updated to match.

Both are pinned by `test_txfix_gate_inputs_the_2026_09_cleanup_dropped_are_present`.


## 4. Traps recorded

* `txfix_gate_launch.sh` **cannot be used**: it calls `ops/agents/watch_unit.sh`
  and writes `ops/agents/lanes.json`, neither of which survived the 2026-09
  cleanup. The rows were launched with the same `systemd-run --user` wrapper line
  and the same `TXFIX_GATE_RUN_EXIT` trailer, which is what
  `txfix_gate_score.py:pfx_done()` keys completion on.
* The scorer resolves a run by the **manifest's** out-prefix, so both passes must
  write the same `beat_runs/g*_F3*` prefixes. Every pass-A artefact (`.bin`,
  `_frames.txt`, wrapper log, summary) is therefore moved aside before pass B —
  otherwise a pass-B run that failed to start would score pass A's data as a
  model-tree PASS. The pre-existing 2026-09-03 artefacts were moved to
  `beat_runs/_pre_sp3_2026-09-03/` for the same reason.
* `beat_runs/g0_none_U.bin` (the unfixed baseline G3 aligns against) is the
  2026-09-03 artefact, reused unchanged with its recorded
  `TXFIX_GATE_RUN_EXIT=0` wrapper log: it is the *injected unfixed* tree and is
  not a function of either pass.
* `build_txkick_sim.sh` only forced `HARNESS=sim_txfix_force.cpp` for
  `s1_rtl_txfix_*`; `s1_rtl_model_tx` would have silently built against
  `sim_burst_force_tx.cpp`. The guard now covers it.


## 4. Fix round 1 — the DDRCAP-v2 fallback, and the four rows re-run on both trees

Controller ruling: the v2-aware scorer fallback is in scope (gate-harness work). Done,
then G3, G4/G5 k0 and k6, and G7 were **re-run from scratch on both trees**, four at a
time (`obj_txkick_ref` → `obj_txkick_m8`), not re-scored from the old captures.

### 4.1 What changed in the scorer

| file | change |
|---|---|
| `kick_seq.py` | `frame_marks(a)` — v1 `lane2 == 0x7FFF` **first**, then the v2 rule `lane2 & 0x4000`. Prints `# LAYOUT v1\|v2 marks=<n>`. The ordering is load-bearing: `0x7FFF` also has bit 14 set, so an unguarded v2 rule would relabel every v1 capture. |
| `txfix_gate_score.py` | `aligned_content_check` resolves marks the same way; a **cross-layout** pair compares lanes 0/1 only (lanes 2/3 are the instrument's own mark/slot fields, packed differently) and resolves the layouts' constant record phase with a bounded ±4 search, reporting it as `cross_layout_shift`. Same-layout pairs still compare the whole record. |
| `txfix_gate_score.py` | new `offsets_clean(seq, bin)` replaces three inline `all(o in (0, None) …)` expressions (G3, G4/G5, G7). **An empty list is never clean.** v1 keeps the strict every-offset-is-0 rule; v2 tests that no frame departs from the run's own modal offset, because the v2 mark sits at a different record relative to the payload and the whole run carries a constant layout phase. |
| `txfix_gate_score.py` | the run manifest falls back to the tracked `evidence/txfix_gate_runs.txt`. |

Unit-tested on synthetic records in `modem/tests/test_txfix_gate_marker.py` (13 tests,
no Verilator, no MATLAB): v1 marks found through the historical path; v2 marks found by
bit 14; v1 tested first (with the 0x7FFF-has-bit-14 trap asserted explicitly); empty and
all-`None` offset lists are not clean; v1 keeps the strict rule (a uniformly non-zero v1
run still fails); v2 accepts a constant modal offset but still catches a departing frame;
and `aligned_content_check` — same-layout identical/differing, and a v2-vs-v1 pair with
identical I/Q now aligning where it used to return `no marker found`, while a v2-vs-v1
pair with one perturbed I/Q sample still fails at the right record.

### 4.2 The four rows, re-run on both trees

```
reference  TREE=s1_rtl_txfix_F3  obj_txkick_ref   (2026-09-11 23:00-23:56)
model      TREE=s1_rtl_model_tx  obj_txkick_m8    (2026-09-12 00:00-00:38)
```

| row | injected | model | TX witnesses | offsets |
|---|---|---|---|---|
| G3 none | **PASS** `all4` lanes, `aligned_identical=True`, 0 differing | **FAIL** | — | ref `layout=v1 frames=106 all_offsets_zero=True` · model `layout=v2 frames=106 modal_offset=12264 no_frame_departs=False` |
| G4/G5 k0 | **PASS** | **FAIL** | identical: `d3_post=0 armed=1 pop=1 saw_armed_zero=0 max_pop_quiet=2` | ref `v1 58 frames all-zero` · model `v2 58 frames modal 12264`, departing `[(0,12319),(1..8,12272)]` |
| G4/G5 k6 | **PASS** | **FAIL** | identical: `d3_post=0 armed=1 pop=1 saw_armed_zero=0 max_pop_quiet=2` | as k0 |
| G7 latchforce_pre | **PASS** | **FAIL** | identical: `saw_armed_one=1 armed_one_clk=592086 clk_to_reload=1 max_pop_quiet=107` | ref `v1 58 frames all-zero` · model `v2 58 frames modal 12272`, departing **`[(0, 12319)]` — the partial first frame, and nothing else** |

**Gate (PASS parity per row with non-vacuous offsets): NOT met for these four rows —
reported BLOCKED.** What the fallback bought is that the failures are now *measurements*
rather than absences: every row decodes 58 or 106 frames on both trees, and G3's digest
compares content instead of returning `no marker found`.

First differing record / offset, as required:

* **G3** — `cross_layout_shift=-1`, `differing_records_in_overlap=255`,
  `first_differing_record=110906`, `last_differing_record=199072` (of 1,305,850
  compared). Outside that window every record is identical.
* **G4/G5 k0 and k6** — first departing frame is **frame 0** (offset 12319 vs modal
  12264), then frames 1-8 sit at 12272 and frames 17+ at 12264: the offset walks
  12272 → 12264 one step per frame across frames 9-16.
* **G7** — first and ONLY departing frame is **frame 0**, offset 12319 vs modal 12272.
  Its 58-frame run ends before the 9-16 walk, so its capture is otherwise constant.

Frame 0 departs on every v2 row because the v2 mark lands one record earlier
(`first_marker` 1 vs 2), so the first frame's 16-symbol decode word straddles the start
of the capture. It is not excluded: excluding a frame to turn a FAIL into a PASS is
exactly the vacuity this fix round removed.

The eight-step walk across frames 9-16 is `RxSteer`'s lock (`frames == uint8(8)` pcEnd
pulses) — §3.2 — and the TX witnesses above are bit-identical on every row, so the
transmitter is not implicated. The two remaining ways to make these rows meaningful on a
model tree are unchanged and both sit outside this overlay: a TX-domain capture selector
(`SEL` is an RX mux today), or a model-lineage unfixed baseline to replace `g0_none_U`.

---

## 5. Fix round 2 — the model-lineage unfixed baseline (§ baseline lineage)

Ruling: *both sides of every row must share the same receiver*. Rounds 0-1 compared the
model F3 tree against `beat_runs/g0_none_U`, a 2026-09-03 capture from the **injected**
lineage (`s1_rtl_txmark`, DDRCAP-v1, no RX overlays at all). This round rebuilds that
baseline from the model lineage: same receiver, stock transmitter.

### 5.1 The second env gate

`modem/rxfix/txfix_f3_overlay.m` now returns early unless **both** `QPSK_RXFIX` and
`QPSK_TXFIX` are set, and `modem/fixes/build_base_tree.sh` exports
`QPSK_TXFIX="${QPSK_TXFIX-1}"` beside `QPSK_RXFIX=1`. **Path note:** as of task 11 that
script lives at `modem/build_hdl.sh` (line 163); `modem/fixes/build_base_tree.sh` is a
symlink onto it, and task 11's `[7] MODEL_OVERLAYS` post-check already keys its
`F3/fullRAM` check off the same variable (`build_hdl.sh:424`). The `-` form (not `:-`) is the
load-bearing detail: it lets a caller's **empty** value survive, which is how the
baseline is built. `QPSK_RXFIX=1` + empty `QPSK_TXFIX` = the RX overlays, no TX fix.
Three static tests in `modem/tests/test_rxfix_overlays.py` pin the gate, the
independence of the two early returns, and the `${VAR-default}` form.

### 5.2 WHICH SOURCE THE BASELINE WAS BUILT FROM — read this before trusting §5.4

The brief's recipe (`QPSK_TXFIX= modem/fixes/build_base_tree.sh …/regen8` from the
current checkout) would **not** have produced a like-with-like pair, and the reason was
measured before the regen was launched:

```
$ diff -rq regen8/jupiter_byte_ddrcap2_build.regen/rxfix  modem/rxfix
Only in modem/rxfix: rxfix_bs_overlay.m
Only in modem/rxfix: rxfix_pad_overlay.m
```

`build_base_tree.sh` step [1] rsyncs the whole kit into the tree it builds, so the F3
tree (`regen8`, 2026-09-11 20:41) **contains the source snapshot it was built from**.
That snapshot has no BS and no PAD overlay, no `[4a]` BRAM-`ByteRxFifo` stage in its
`build_base_tree.sh`, and its RTL confirms it: `RxW1Census.v`, `RxSteer.v`,
`PdPopIndex.v` present, **no** `BsSeamCensus.v`, generated 64-deep FIFO. A baseline
regenerated from today's checkout would have carried BS + PAD + the BRAM drop-in and
re-created the very mismatch this round exists to remove.

So the baseline was built **from that preserved snapshot**, which is the original input,
not a reconstruction:

* kit = `/mnt/onetb/scratch/qpsk-build-trees/t8u/modem`, an rsync of the F3 tree with the
  build's own outputs excluded (`hdl_prj_*`, `slprj`, `*.log`, `*.out`, `*.slxc`,
  `asrun_*`, `*_asrun_*.slx`, `rtl_sim/obj_*`, `s1_rtl*`);
* the six inputs the build **mutates in place** — `commhdlQPSKTxRxLoopback.slx`,
  `commhdlQPSKTxRx.slx` (assembly saves the model), `hdlworkflow_loopback.m`
  (`patch_hdlworkflow_rxfix.m` adds the AXI ports), `init_data.mat`, `end_gen.mat`,
  `reset.mat` — were restored from the repo, whose copies are byte-for-byte the
  pre-build originals (tracked + clean, or untracked with mtimes 2026-08-12/18, i.e.
  all older than the 20:41 build);
* the KITDIR repoint is a no-op here: no `.m` in the kit carries an absolute kit path;
* the snapshot's own `build_base_tree.sh` was used (it has no `[4a]` stage — that is
  *why* the U tree matches), plus exactly two added lines: the `QPSK_TXFIX` export and
  the overlay's second gate.

**Evidence-vs-artifact gap, stated plainly:** the committed repo
`modem/fixes/build_base_tree.sh` export is covered by a static test only. The artifact in
§5.4 was produced by the snapshot copy of that script carrying the same one line.

### 5.3 Baseline regen and post-check

```
unit    sp3-txbase-005536.service        log  /mnt/onetb/scratch/qpsk-build-trees/regen8u/txbase.log
cmd     QPSK_TXFIX= t8u/modem/fixes/build_base_tree.sh /mnt/onetb/scratch/qpsk-build-trees/regen8u
tree    /mnt/onetb/scratch/qpsk-build-trees/regen8u/jupiter_byte_ddrcap2_build.regen
wall    00:55 -> 01:24 (MATLAB stage 1560 s)                       ONE regen, as budgeted
BASE_RTL_CLASSES header_only=208 bank_only_instrument=6 logic=116 only_in_regen=10 only_in_bank=165
BASE_REGEN_INJECT_FAILED / BASE_REGEN_NOT_INSTRUMENT_COMPLETE : ABSENT     TXBASE_EXIT=0
```

The gate fired (both directions):

```
TXFIX_F3_OVERLAY_OK in build_byte_matlab.log : 0 hits          <- the TX fix did NOT run
RXFIX_W1_OVERLAY_OK / RXFIX_STEER_OVERLAY_OK / RXFIX_R1_OVERLAY_OK : all present
assign dataReady = DataReadyPaceCmp_out1;      (stock; the F3 tree has TxF3ReadyGate_out1)
TxF3ReadyGate 0 | TxF1BoundaryGuard 0 | "frameCount != 2'b11" 0 | "count != 16'hFFFF" 0
RxW1Census U:1 F3:1   RxSteer U:1 F3:1   PdPopIndex U:1 F3:1   BsSeamCensus U:0 F3:0
```

`BsSeamCensus` is **0 on BOTH trees** — the brief's four-item post-check is three passes
plus one expected absence, because the F3 tree predates the BS overlay (§5.2), not a
partial pass. `tree_marker.sh s1_rtl_model_tx_u F3` prints `model`, **not** the brief's
`MISSING`: that check is only `grep -q fullRAM Bit_Packetizer.v`, and the stock file
already declares `wire Data_Bits_FIFO_fullRAM` (§4 trap, unchanged). The `dataReady`
assign above is the real discriminator.

**The lineage diff is the whole argument** (170 `.v`, HDL Coder's generated-header lines
stripped with `build_base_tree.sh`'s own `HDR` regex, plus the two wall-clock build
stamps — the assemble banner's `build=<date>` in `TxRxComposite.v` and HDL Coder's
`ip_timestamp` constant in `TxRxCompo_ip.v`, both of which differ between *any* two
builds and are not logic):

```
U_VS_F3 files=170 identical=0 header_only=166 logic=4 only_in_U=0 only_in_F3=0
U_VS_F3_LOGIC_FILES: Bit_Packetizer.v Data_Bits_FIFO.v MATLAB_Function1.v RAM_Frame_Status_Indicator.v
LINEAGE_OK exactly the four TX files differ                                  POSTCHECK_RC=0
```

Gate tree `modem/rtl_sim/s1_rtl_model_tx_u` (flat, prefix-stripped, same 171-entry file
list as `s1_rtl_model_tx`); binaries `obj_txkick_mu/Vtxkick`, `obj_txrate_mu/Vtxrate`
built by `build_txkick_sim.sh` / `build_txrate_sim.sh`, whose `sim_txfix_force.cpp`
guard was widened to `s1_rtl_model_tx*` so the baseline cannot be built against the
wrong harness.

### 5.4 The rows, side by side: injected pair vs model pair

Injected column = the round-1 re-run (`beat_runs/_round1_injected/`), U side
`g0_none_U` 2026-09-03 injected lineage. Model column = this round, U side rebuilt from
the model lineage. All seven runs are fresh, `TXFIX_GATE_RUN_EXIT=0`, ≤4 concurrent.

| row | injected pair | model pair | the witness that moved |
|---|---|---|---|
| G0 `none` (U baseline) | PASS (2026-09-03 pre-sp3 summary; that run has no `_frames.txt`, so today's scorer reads it `incomplete`) | **FAIL** | its own offsets are `{12264…12272, 12319}`, not 0 — see below |
| G1 popabort k0 (U) | PASS (2026-09-03) | PASS (weak) | `saw_armed_zero=1 armed_zero_clk=641342 max_pop_quiet=63`; the offset half is degenerate |
| G2 fcbase3 (U, txrate) | PASS | PASS | `zeroEvents=2 firstZeroFrame=40 armedDropClk=4041064` — no capture involved |
| G3 `none` F3 | PASS | **FAIL (offsets only)** | **content now `aligned_identical=True`, `differing_records_in_overlap=0` of 1,305,851, `compared_lanes=all4`, `cross_layout_shift=0`** (round 1: 255 differing, `IQ01`, shift −1) |
| G4/G5 F3 k0 | PASS | **FAIL (offsets only)** | `d3_post=0 armed=1 pop=1 clk=641340 saw_armed_zero=0 max_pop_quiet=2` — bit-identical to the injected row |
| G4/G5 F3 k6 | PASS | **FAIL (offsets only)** | `d3_post=0 armed=1 pop=1 clk=638268 sc_at_arm=11546 max_pop_quiet=2` — bit-identical |
| G7 latchforce_pre F3 | PASS | **FAIL (offsets only)** | `saw_armed_one=1 armed_one_clk=592086 clk_to_reload=1 max_pop_quiet=107` — bit-identical |

### 5.5 What the like-with-like baseline proves, and why four rows still FAIL

**What it proves.** G3's content check — the golden digest, the row's actual subject —
is now an all-four-lane, zero-shift, whole-capture compare and it is **exact**: 0 of
1,305,851 records differ between the model F3 capture and the model U capture. Round 1's
255-record delta in frames 9-16 was the baseline's lineage, not the overlay, exactly as
that round argued but could not demonstrate.

**Why the four rows still FAIL.** Only `offsets_clean()` fails, and the offset sequence
it scores is **identical in the unfixed baseline**:

```
$ diff <(kick_seq.py beat_runs/g0_none_U.bin) <(kick_seq.py beat_runs/g3_none_F3.bin)
  (no output)                            # OFFSET_SEQ_IDENTICAL, 106 frames, layout v2
frame  0 -> 12319 ; frames 1-8 -> 12272 ; frames 9-16 walk 12271…12264 ; 17-105 -> 12264
```

So the departing frames the criterion rejects are a property of the **receiver** — frame
0's decode word straddling the capture start (v2 marks one record earlier), and
`RxSteer`'s eight-pcEnd lock walk — and they are present, frame for frame, with the
transmitter unfixed. `G0` itself fails the same criterion under either rule (the
hardcoded v1 "every offset 0", and `offsets_clean`'s v2 "no frame departs from the
modal"): **the baseline is not clean by the gate's own standard**, which is the sharpest
statement of the problem.

G1's model PASS is **weak** and is labelled so: `sustained = all(o not in (0, None))` is
satisfied for free by a constant non-zero v2 offset. Its real evidence is
`saw_armed_zero=1` (the unfixed transmitter does abort pops), and that is genuine. The
G1(U)-vs-G4k0(F3) offset pair is the one place the fix shows up in the offsets at all:
same stimulus, U walks 6096→6088 and F3 walks 12272→12264 — the same eight-step shape
displaced by ~6184 records, i.e. by the pop abort G4 exists to show is gone.

**Verdict: BLOCKED for G3, G4/G5 k0, G4/G5 k6, G7** (two-iteration rule — no third
iteration on the overlay). First departing frame/record, per row: G3 frame 0
(12319 vs modal 12264), content `first_differing_record` **none**; G4/G5 k0 and k6 frame
0 (12319 vs modal 12264) then the 9-16 walk; G7 frame 0 (12319 vs modal 12272), its only
departure.

The remaining fix is in the scorer, not the model: with a same-lineage baseline available
the criterion can become *relative* — "this run's per-frame offset sequence equals the
unfixed baseline's" — instead of "no frame departs from this run's own modal". That is a
gate-harness change (`txfix_gate_score.py`), it is falsifiable (the G1/G4 pair above
separates), and it is deliberately **not** made here.

**Scope, so the table is not read as broader than it is.** This pair proves the overlay
is TX-only *on the lineage the F3 binaries were built from* — W1 + RxSteer + R1,
generated 64-deep `ByteRxFifo`. It does not test it against today's receiver
(BS + PAD + the BRAM drop-in). Re-gating on that receiver needs **two** regens (F3 and U
from one source snapshot) and a rebuild of both binary sets.
