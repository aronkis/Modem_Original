# Gate 1 — the full equivalence matrix on ONE model tree, both `sro_sign` settings

sp3 (cleanup sub-project 3, model back-port) task 9. **STATUS: COMPLETE** — verdict in §8.

Tasks 4-8 each gated their own overlay on a tree that lacked the later ones (task 8's
`regen8` tree had no BS/PAD; task 7's had no F3), so the COMBINED tree had never been
gated. Every per-task gate reproduced the injected-tree reference EXACTLY, so any
deviation scored here is an INTERACTION between overlays.

## 1. The tree

| | |
|---|---|
| git sha | `df674056` (`per-under-1pct-2026-07`) |
| regen unit | `sp3-gate1-012729` (systemd-run --user), 2026-09-12 01:27:29 -> 01:57:17, wall **29 m 48 s** |
| regen log | `/mnt/onetb/scratch/qpsk-build-trees/regen/gate1.log` |
| tree | `/mnt/onetb/scratch/qpsk-build-trees/regen/jupiter_byte_sp3_build` |
| MODEL_TREE_SHA | `e615c4a49009eed348b0790951515ab6b11237fade7a761537c4c6f33f629bba` |
| | sha256 over the sorted `(name, sha256)` list of all **172** `.v` under `hdl_prj_jupiter_composite/hdlsrc/commhdlQPSKTxRxLoopback`; exact recipe in §1.2 |
| gate tree | `modem/rtl_sim/s1_rtl_model` (172 `.v`), `modem/rtl_sim/s1_rtl_model_tx9` for the TX rows |

### 1.0 The MODEL_TREE_SHA recipe, verbatim

```bash
H=/mnt/onetb/scratch/qpsk-build-trees/regen/jupiter_byte_sp3_build/hdl_prj_jupiter_composite/hdlsrc/commhdlQPSKTxRxLoopback
( cd "$H" && find . -maxdepth 1 -name '*.v' -printf '%f\n' | LC_ALL=C sort \
  | while read -r f; do printf '%s %s\n' "$f" "$(sha256sum "$f" | cut -d' ' -f1)"; done \
  | sha256sum | cut -d' ' -f1 )
# -> e615c4a49009eed348b0790951515ab6b11237fade7a761537c4c6f33f629bba   (172 files)
```

`LC_ALL=C sort` is load-bearing: a locale-dependent sort would reorder the list and
change the digest for an unchanged tree.

### 1.1 The regen was run from a SNAPSHOT of HEAD, not from the live checkout

Task 8 fix round 2 was editing the shared checkout while this regen was prepared
(`modem/tests/test_rxfix_overlays.py` mtime 01:18:15, `date` 01:20:55), so a regen
from the working tree could have baked in a half-written `.m`. The kit was therefore
hard-linked to `/mnt/onetb/scratch/qpsk-build-trees/t9` and every tracked file under
`modem/` pinned to `git show HEAD:<path>`, so `MODEL_TREE_SHA` corresponds to a
nameable commit.

The uncommitted delta at that moment, and why it is expected to be RTL-neutral:

* `modem/assemble_jupiter_240k5_byte.m` moves `txfix_f3_overlay` from BEFORE
  `rxfix_bs_overlay`/`rxfix_pad_overlay` to AFTER them. `txfix_f3_overlay.m` adds
  blocks only inside `Bit Packetizer` and its `Data Bits FIFO` and adds **no ports and
  no registers** at the composite level (verified by reading every `add_block` /
  `add_line` / `delete_line` in the overlay); BS/PAD touch only `ByteSerializer`. The
  two edit disjoint subsystems, so the order between them does not move a port tail —
  which is the failure mode `BASE_REGEN_INJECT_FAILED` exists to catch, and that token
  is absent from this run's log.
* `modem/fixes/build_base_tree.sh` adds `export QPSK_TXFIX="${QPSK_TXFIX-1}"`; the
  default keeps the TX overlay ON, i.e. a normal regen is unchanged.
* The rest is comments, `modem/rxfix/README.md` and `modem/tests/`.

**Concern for the controller, not a defect in this run:** if that reorder does land,
Gate 1 was measured on the other order.

### 1.2 HEAD advanced DURING this task; the regenerated tree is unaffected

`df674056` was `HEAD` at 01:27 when the regen started. By 02:05 the branch had
advanced to `ba4e056c` (task 11's `modem/{gates,vivado,instruments/seqbist}/` layout
move, `build_image.sh`, `ops/sro_sign.sh`). Of the inputs that determine the generated
RTL --- `modem/assemble_jupiter_240k5_byte.m`, `modem/rxfix/*.m`,
`modem/instruments/{beatila,txcap,ddrcap,ddrcap2}/`, `modem/rxfifo_inject.sh`,
`modem/rxfifo_bram/`, `modem/build_variant_byte.m`, `modem/frame_config_k5.m` ---
`git diff df674056..ba4e056c` touches **none** (only `modem/rxfix/README.md`, the new
`modem/instruments/seqbist/` kit, and `modem/fixes/build_base_tree.sh`, whose 276-line
delta is the comment reflow plus the `QPSK_TXFIX` export that defaults to `1`).
So the tree gated here is the tree either commit would have produced, modulo §1.1's
still-uncommitted overlay reorder.

The task-11 move also relocated the gate harness mid-run:
`modem/fixes/gates/model_matrix.legs` is now `modem/gates/model_matrix.legs`
(`modem/fixes/gates` is a compatibility symlink), `$HERE` is `modem/gates`, and the
scorer row reads `$HERE/reference_loss.toml`, not the pre-move `$HERE/gates/...`.

## 2. Post-check

### 2.1 The regen log

```
BASE_REGEN matlab=25.2.0.3177638 (R2025b) Update 5
RXFIFO_INJECT_OK depth=4096 files+zips=5 verified_loose=3
TXCAP_INJECT    files=6 zip_members_patched=6 zips_found=2
DDRCAP_INJECT   loose_files=9 logical_groups_satisfied=8/8 zip_members_patched=18 zips_verified=2/2
DDRCAP2_INJECT  loose=7 missing=[] zips=2 zips_verified=2
BASE_REGEN_DONE
BASE_RTL_CLASSES header_only=200 bank_only_instrument=6 logic=124 only_in_regen=14 only_in_bank=165
BASE_RTL_EQUIV  files=330 diff=330
GATE1_REGEN_EXIT=0
```

`BASE_REGEN_INJECT_FAILED` and `BASE_REGEN_NOT_INSTRUMENT_COMPLETE`: **ABSENT**. The
only WARN is the Vivado BD step (`DDRCAP_BD_WIRE_OK` not reported); it touches no `.v`
and the script states it is non-fatal for that reason.

### 2.2 All seven overlays reported OK, in the HEAD order (F3 BEFORE BS/PAD)

```
BEATOBS_OVERLAY_OK            debugI1/Q1 carry the packed beat state vector
BEATFIX_OVERLAY_OK            v3-edgequal-selfcal (fixctl 0x208, 0x20C, 0x210)
RXFIX_W1_OVERLAY_OK           RxW1Census in FTS (0x214-0x230), freeze = fixctl bit 4
RXFIX_STEER_OVERLAY_OK        RxSteer in Rate Handle; extra armed by fixctl bit 5 (0x234/0x238/0x25C)
RXFIX_R1_OVERLAY_OK           PdPopIndex in Preamble Detector; the 49332-deep tick delay deleted
TXFIX_F3_OVERLAY_OK           F1+F2+F3 (variant F3; F3b margin NOT applied)
RXFIX_BS_OVERLAY_OK           BsSerCensus + BsSeamCensus (0x23C-0x258)
RXFIX_PAD_OVERLAY_OK          ByteSerializer pads a truncated frame to 191 words
```

### 2.3 `tree_marker.sh` on `s1_rtl_model`, run for real (no `SKIP_MARKER`)

`W1 R4B R4D R4DR1 BS PAD F3` -> all seven print `TREE_MARKER ... model`. The four
overlay module files are present: `RxW1Census.v`, `RxSteer.v`, `PdPopIndex.v`,
`BsSeamCensus.v`.

### 2.4 SEMANTIC post-checks, because `tree_marker.sh` is weak on the model path

`tree_marker.sh F3` only greps `fullRAM` in `Bit_Packetizer.v`, which the UNPATCHED
file nearly satisfies (task 8 recorded this). The real witnesses, read off the
generated RTL:

| witness | file | present |
|---|---|---|
| `assign Logical_Operator2_out1 =  ~ Data_Bits_FIFO_fullRAM;` | `Bit_Packetizer.v` | yes |
| `assign dataReady = TxF3ReadyGate_out1;` | `Bit_Packetizer.v` | yes |
| `TxF1BoundaryGuard_out1` (F1 boundary-guarded pop latch) | `Bit_Packetizer.v` | yes |
| `full_1 = count_temp > 16'b1100000001111111;` (49279 = **F3**, not F3b) | `MATLAB_Function1.v` | yes |
| `padCount` (the PAD counter `tree_marker.sh PAD` requires) | `ByteSerializer.v` | 15 hits |

No F3b threshold form is present: `depth - 16` and `49263` are both absent. A literal
`grep -F 1100000001101111` DOES hit once, at
`Function_Impl.v:7420  assign LUT1_table_data[3065] = 26'sb11111111111100000001101111;`
-- a coincidental substring of an unrelated 26-bit LUT constant, not an F3b compare.
`RXFIX_PAD` / `RXFIX_BS` as literal tokens are ABSENT by design: they are the
*injector* markers, and a model tree is identified by `RXFIX_ORIGIN` + the module file
(`tree_marker.sh:21-26`).

### 2.5 `make_sro_trees.sh --from-regen`

```
SRO_TREE_MODEL modem/rtl_sim/s1_rtl_model files=172
MAKE_SRO_MODEL_WRAP_W1TAPS    wrap_byte_w1_model.v   (8 composite-port taps)
MAKE_SRO_MODEL_WRAP_POPTAP    wrap_byte_sro4b/sro4d/bs_model.v (rhPop -> RxSteerPopOr_out1)
MAKE_SRO_MODEL_WRAP_PDTAP     wrap_byte_sro4b/sro4d/bs_model.v (pdPopReq -> u_PdPopIndex.pop)
MAKE_SRO_MODEL_WRAP_STEERTAPS wrap_byte_sro4b (6) / wrap_byte_sro4d (7) u_RxSteer taps
MAKE_SRO_MODEL_WRAP_BSTAPS    wrap_byte_bs_model.v   (8 BsSeamCensus word taps + ovfCnt witness)
MAKE_SRO_FROM_REGEN_DONE
```

### 2.6 Binaries (all built rc=0, all `TREE_MARKER ... model` inside the build script)

| obj dir | binary | FIXCTL |
|---|---|---|
| `obj_byte_w1_w1_model_0` | `Vwrap_byte_w1_model` | 0 |
| `obj_byte_w1_base_model_0` | `Vwrap_byte_w1_model` | 0 |
| `obj_byte_sro_rxfix4b_model_0` | `Vwrap_byte_sro_model` | 0 |
| `obj_byte_sro_rxfix4dr1_model_20` | `Vwrap_byte_sro_model` | 0x20 |
| `obj_byte_sro_bs_model_0` | `Vwrap_byte_sro_model` | 0 |
| `obj_byte_sro_pad_model_0` | `Vwrap_byte_sro_model` | 0 |
| `obj_txkick_m9` | `Vtxkick` (`HARNESS=sim_txfix_force.cpp`) | runtime |
| `obj_txrate_m9` | `Vtxrate` | runtime |

## 3. The leg run

| | |
|---|---|
| table | `modem/gates/model_matrix.legs` — 51 legs, of which **17** are Verilator sims |
| command | `bash modem/gates/run_gates.sh --legs modem/gates/model_matrix.legs --jobs 4 --force --work /mnt/onetb/scratch/sp2_gates/work_t9` |
| unit | `sp3-gate1legs-025816` (run 2; run 1 `sp3-gate1legs-020812` was abandoned, §3.1) |
| log | `/mnt/onetb/scratch/qpsk-build-trees/regen/gate1_legs2.log` |
| bank | `BANK_OK` (`modem/fixes/base_tree.sh verify-bank`, 910 files / 1.5 GB) before the first leg |

### 3.1 Run 1 was abandoned: a SECOND `run_gates.sh` was started on the same table

At 02:48:59 a second process appeared —

```
PID 2097566  /bin/bash .../modem/gates/run_gates.sh --legs .../modem/gates/model_matrix.legs
             (serial: no --jobs, no --force; unit stamp 1789195747)
```

— i.e. another agent launched THIS task's table while run 1 (unit stamp `1789193299`)
was 40 minutes into it. `run_gates.sh` derives its work directory from
`SP2_WORK` (default `/mnt/onetb/scratch/sp2_gates/work/<key>`), so both runs wrote the
same leg artefacts. The collision is measured, not inferred:

```
m0_n_p000_seq.txt   size=9889  nulls=8192  first_nonzero=8192   (71 of 424 rows survive)
m0_n_p000_deliv.txt size=9964  nulls=8192  first_nonzero=8192   (74 rows)
m0_n_p000_ep.txt    size=69472 nulls=45056
m0_n_p000_frames.txt / _res.txt  clean
```

A NUL run of exactly 8192 bytes at offset 0 with the correct final size is two writers
on one file: the second run re-opened and re-extended a file the first had already
written. The three rows that read that prefix (`m0_n_p000_t7`, `G1_ident`,
`G4_prearm`) failed on `ValueError: invalid literal for int()` over NUL bytes — an
I/O fault, not a modem result. The five legs that had completed before the second
runner reached them (`m0_n_p2p5`, `m0_n_m2p5`, `m0_n_p10` and their `_t7` scorers) were
undamaged.

**Response:** run 1 and its four in-flight leg units were stopped (only the ones
carrying run 1's own `1789193299` stamp; the other agent's run was left untouched) and
the whole table was restarted from scratch with `--force` into a PRIVATE work directory
`/mnt/onetb/scratch/sp2_gates/work_t9`. Nothing from run 1 is reused. Evidence kept at
`/mnt/onetb/scratch/sp2_gates/collision_evidence_t9/`.

**This did NOT consume the plan's one diagnosis attempt**: no matrix row missed its
tolerance: three rows could not be scored at all because their input files had been
overwritten by another process.

**Concern for the controller:** `run_gates.sh` has no lock on its work directory. Two
runs of one table silently corrupt each other's artefacts and the damage surfaces as a
scorer crash several legs later. A `flock` on `$wd` (or a PID/stamp file that the
second runner refuses to start against) would turn this into a loud refusal.

### 3.2 The one diagnosis attempt, spent on `G4_prearm` — cause localised, benign

`G4_prearm` is the only row of the whole table that did not pass as written. Its
criterion (`build_sro_rxfix4b.legs:42`) is "every frame delivered before the first skip
is identical to the baseline **including `sidx`**". Measured:

```
first skip: air frame 13
common seq delivered before the first skip: 6
  identical content (nwords,hash,user): 6/6      <-- the data path
  identical INCLUDING sidx            : 0/6      <-- the sample index
  seq 2: new=(345358, 191, '9d21f9f6', 1)  base=(345357, 191, '9d21f9f6', 1)
```

Every pre-arm frame is **+1 input sample** late and byte-identical in content. The
same shift is visible in `G1_ident`'s own distribution, which is the whole story of
this leg in one line:

```
sidx delta over 423 common seq: min=0 max=33 mode=33 (407/423)
  distribution: 0:2  1:7  5:1  9:1  13:1  17:1  21:1  25:1  29:1  33:407
```

`1 + 8 skips x 4 samples/symbol (sps=4) = 33`, and the intermediate values step by
exactly 4 as each of the `r3_skips=8` skips lands. So the delta decomposes exactly
into R4B's own skips (which are the point of the fix) plus **one constant sample of
pipeline latency**.

**Where the constant +1 enters — measured on this session's own per-task legs, same
harness, same stimulus, same `m0_n_p000` prefix:**

| tree | overlays | first delivered `sidx` | vs bank |
|---|---|---|---|
| `$BANK/b_p000` (injected) | — | 296025 | — |
| task 5 `t5/m0_n_p000` | W1 + STEER | 296025 | **0** |
| task 6 `t6/m0_n_p000` | + R1 | 296025 | **0** |
| task 7 `t7/m_bs_p000`, `t7/m_x4b_p000` | + BS + PAD + BRAM `ByteRxFifo` drop-in | 296026 | **+1** |
| task 9 `work_t9/m0_n_p000` | + TX F3 (this tree) | 296026 | **+1** |

The shift enters with the byte-plane stage (the 4096-deep BRAM `ByteRxFifo` drop-in,
whose own header records "+2 clk latency at the empty->non-empty edge", and/or the PAD
arbiter's balancing register — task 7 §5.3 measured the same "+1 clk on 422 of 424
frames" and could not separate the two without another build), and the TX F3 overlay
does **not** move it. It is therefore:

* **not an overlay interaction** — it is present on a tree that has no F3 at all;
* **not a data-path change** — content is bit-identical on 6/6 pre-arm frames and on
  423/423 common frames (`G1_ident` **PASS**, `content_equal=True`);
* **cross-lineage by construction** — `$BANK/b_p000` was produced on a tree with the
  generated 64-deep register FIFO, which the shipped design no longer has.

**Verdict recorded, not repaired.** The criterion is NOT relaxed to make the row pass:
`G4_prearm` stands as **FAIL as written / content clause PASS 6/6**, in the same class
as the `build_sro_bs.legs` / `build_sro_pad.legs` rows task 7 adjudicated as
cross-lineage. The controller decides whether the `sidx` clause should become a
same-lineage comparison. This was the plan's single diagnosis attempt and it is
closed: the cause is localised to a named design change with a same-harness control on
both sides of it.

### 3.3 Run 2 result

```
GATE_LEGS model_matrix pass=47 fail=4 wall=03:12:51        (02:58:16 -> 06:11)
GATE1_LEGS_EXIT=1        (run_gates.sh exits non-zero if ANY leg fails)
LEG_FAIL G4_prearm  gateA_p000  gateA_m10  edge_m10        <- and only these four
```

All four are cross-lineage banked CONSTANTS, analysed in §3.2 and §6.1. **Every row
that compares this tree against `reference_loss.toml` passed, and every structural row
passed.**

## 4. The equivalence matrix — BOTH `sro_sign` settings, vs `reference_loss.toml`

`score_matrix.py --ref modem/gates/reference_loss.toml --run .` with the ten
`<variant>/<stim>=<prefix>` maps. Tolerance rule: loss `max(0.10, 10 %)`, counts
`max(2, ceil(10 %))`. Final line: **`MATRIX_EXIT 0`**.

### 4.1 FIXCTL=0 — `sro_sign` CLEAR (`obj_byte_sro_rxfix4b_model_0`)

| row | loss / ref (tol) | skips / ref | pop_on_empty / ref | push_on_full / ref | pd_pof / ref | pd_poe / ref | opens / ref | verdict |
|---|---|---|---|---|---|---|---|---|
| `R4B/n_p000` | 0.00 / 0.00 (0.100) | 8 / 8 | 34 / 34 | 0 / 0 | 0 / 0 | 0 / 0 | 9 / 9 | **PASS** |
| `R4B/n_p2p5` | 0.71 / 0.71 (0.100) | 7 / 7 | 110 / 110 | 0 / 0 | 0 / 0 | 0 / 0 | 21 / 21 | **PASS** |
| `R4B/n_m2p5` | 0.00 / 0.00 (0.100) | 0 / 0 | 34 / 34 | 18 / 18 | 0 / 0 | 0 / 0 | 18 / 18 | **PASS** |
| `R4B/n_p10` | 6.65 / 6.65 (0.665) | 7 / 7 | 178 / 178 | 28 / 28 | 0 / 0 | 0 / 0 | 32 / 32 | **PASS** |
| `R4B/n_m10` | 0.48 / 0.48 (0.100) | 30 / 30 | 34 / 34 | 17 / 17 | 0 / 0 | 0 / 0 | 9 / 9 | **PASS** |

### 4.2 FIXCTL=0x20 — `sro_sign` SET (`obj_byte_sro_rxfix4dr1_model_20`)

| row | loss / ref (tol) | skips / ref | extras / ref | pop_on_empty / ref | push_on_full / ref | pd_pof / ref | pd_poe / ref | opens / ref | verdict |
|---|---|---|---|---|---|---|---|---|---|
| `R4DR1/n_p000` | 0.00 / 0.00 (0.100) | 8 / 8 | 0 / 0 | 34 / 34 | 0 / 0 | 0 / 0 | 0 / 0 | 9 / 9 | **PASS** |
| `R4DR1/n_p2p5` | 0.71 / 0.71 (0.100) | 7 / 7 | 0 / 0 | 110 / 110 | 0 / 0 | 0 / 0 | 0 / 0 | 21 / 21 | **PASS** |
| `R4DR1/n_m2p5` | 0.00 / 0.00 (0.100) | 0 / 0 | 8 / 8 | 34 / 34 | 18 / 18 | 0 / 0 | 0 / 0 | 10 / 10 | **PASS** |
| `R4DR1/n_p10` | 0.00 / 0.00 (0.100) | 7 / 7 | 37 / 37 | 178 / 178 | 0 / 0 | 0 / 0 | 0 / 0 | 23 / 23 | **PASS** |
| `R4DR1/n_m10` | 0.48 / 0.48 (0.100) | 37 / 37 | 7 / 7 | 34 / 34 | 17 / 17 | 0 / 0 | 0 / 0 | 9 / 9 | **PASS** |

**Every field on all ten rows is EXACTLY the injected-tree reference, not merely inside
tolerance** — 80 scored quantities, zero deviations, on a tree carrying six overlays
that had never been combined. That is the result Gate 1 exists to produce.


## 5. The structural rows, both settings

### 5.1 FIXCTL=0 — R4B (`build_sro_rxfix4b.legs` G1-G4)

| leg | criterion | measured | verdict |
|---|---|---|---|
| `G1_ident` | `T12_IDENT PASS content_equal=True`, >= 420 common seq | `content_equal=True same_seq_set=True`, **423** common, 423/423 content equal | **PASS** |
| `G2_skips` | 4 <= skips <= 14, all in window slots [1,13] on both counters, first skip >= lock, last <= lock+11 | skips **8**, `WINDOW OK`, lock/first/last within bounds | **PASS** |
| `G3_ring` | after the last skip: `occTmin/occTmax in [8,12]` and `rhPopEmpty = 0` on every air frame, n > 100 | bad = **0** over n > 100 frames | **PASS** |
| `G4_prearm` | pre-arm identity vs `$BANK/b_p000` **including `sidx`** | content **6/6**, sidx **0/6** (constant +1) | **FAIL as written** — §3.2 |

### 5.4 `repro_p000` — kept, pre-declared, and measured

`build_sro_rxfix4b.legs:33` is the strict reproduction row
(`cmp -s <pfx>_deliv.txt $BANK/r4b_p000_deliv.txt && cmp -s <pfx>_frames.txt
$BANK/r4b_p000_frames.txt`). The first version of `model_matrix.legs` simply omitted it
while its header pre-declared "expected non-pass rows: (none)" — a row dropped without
being named. It is now IN the table and pre-declared under the **drop-in +1** class,
with a companion that carries the part of its claim that is still live:

| leg | criterion | measured (evaluated against run 2's artefacts; criterion-only, no sim) | verdict |
|---|---|---|---|
| `repro_p000` | strict `cmp` of `_deliv` **and** `_frames` vs `$BANK/r4b_p000` | both DIFFER | **FAIL, pre-declared** |
| `repro_p000_content` | `_deliv` columns 2.. (`nwords,hash,user`) vs the bank, and equal line counts | **IDENTICAL on all 424 frames**, 424 == 424 | **PASS** |

`sidx` delta vs the bank: `{0:2, 1:414, 5:8}` — the same `+1` constant, plus 4 samples
for each R4B skip that has fired by that frame. So `repro_p000` fails for exactly the
reason §3.2 localises and nothing else: **every delivered byte reproduces the bank; only
the sample index at which it is delivered moves.**

### 5.2 FIXCTL=0x20 — R4D+R1 (`build_sro_rxfix4dr1.legs` S1-S5)

| leg | criterion | measured | verdict |
|---|---|---|---|
| `S1_p000_D1` | `LOSS=0.00%` | 0.00 % | **PASS** |
| `S1_p000_D2` | `t7_ok = 423`, `r3_extras=0`, `r3_skips=8` | 423 / 0 / 8 | **PASS** |
| `S2_p10_D1` | `LOSS <= 1.00 %` | **0.00 %** | **PASS** |
| `S2_p10_D2` | `t7_ok >= 420` | **424** | **PASS** |
| `S3_p10_pof` | `rh_push_on_full = 0` | 0 (R4B on the same stimulus: 28) | **PASS** |
| `S4_p10_pdocc` | `pdOcc_end = 12333` and cols 29/30 = 12333 on every row > 25 | 12333, bad rows 0 | **PASS** |
| `S5_p10_ring` | extras 30-45, `occTrue_end` 21-25 | extras **37**, occTrue_end **23** | **PASS** |

### 5.3 The runtime-selection row (not a ledger row)

`sign_identity_p000`: on `n_p000` the ring never reaches `occ >= 24`, so arming
`fixctl` bit 5 must change nothing at all. `cmp m20_n_p000_deliv.txt
m0_n_p000_deliv.txt` -> **byte-identical**. Together with §4.2's `n_p10` row (0.00 %
with `extras=37`, where the same tree at bit 5 CLEAR loses 6.65 % with `extras` inert)
this is the behavioural half of task 5's concern 1: bit 5 is a live runtime selector on
ONE netlist, inert where the FULL edge never fires and decisive where it does.


## 6. W1 rows — Gate B PASS; the three banked-CONSTANT clauses are pre-fix values

| leg | clause | measured | verdict |
|---|---|---|---|
| `w1_p000` | `sim_w1.cpp` exit-gates Gate B: the eight W1 words vs the driver's independent reference on EVERY enb beat | `compared_beats=8,239,781 mismatches=0 lag=3 mismatches_lag0=8,239,758 bigdiff_lag0=0 PASS` | **PASS** |
| `w1_m10` | same | `compared_beats=10,459,721 mismatches=0 lag=3 mismatches_lag0=10,459,698 bigdiff_lag0=0 PASS` | **PASS** |
| `base_p000`, `base_m10` | `mode=baseline` (SKIP by design), file non-empty | ok | **PASS** |
| `gateA_p000` | (a) `cmp w1_p000_deliv base_p000_deliv` (b) 164 lines (c) md5 `555fbb25…` | (a) **byte-identical** (b) **164** (c) `75bfc96a…` | **FAIL as written** (a+b pass, md5 fails) |
| `gateA_m10` | (a) `cmp` (b) 209 lines (c) md5 `91680b59…` | (a) **byte-identical** (b) **209** (c) `733f2768…` | **FAIL as written** (a+b pass, md5 fails) |
| `edge_m10` | end-of-leg `poe_ref == poe_w1 == 21` | `0 == 0` | **FAIL as written / NOT APPLICABLE** |

Gate B — the property the W1 overlay exists for — passes on both stimuli with **zero**
mismatches on all eleven fields (`occ push pop poe pof cSS cRH cCFC cCS cPD cPC`), and
falsifiably so: at lag 0 essentially every beat disagrees (8.24 M / 10.46 M) and at
lag 3 none does.

### 6.1 Why the three banked constants cannot hold here — and why that is the FIX

Control: task 4's own `W1_LAG=3` legs (`scratchpad/w1_model_sps4/l3_*`), the run that
reproduced the banked md5s exactly, on a model tree carrying **W1 only** — no STEER,
no R1, no BS/PAD/drop-in.

**0 ppm (`p000`) — content identical, md5 moved by `sidx` alone:**

```
delivered (nwords,hash,user) vs task 4's l3_p000_deliv.txt : 0 of 164 frames differ
sidx delta distribution                                     : 0:2 1:8 5:1 9:1 13:1 17:151
```
`1 + 4 skips x 4 samples/symbol = 17` — the §3.2 constant plus R4B's own skips. The
md5 is taken over a file whose first column is `sidx`, so it changes; nothing the gate
is about changes.

**-10 ppm (`m10`) — the combined tree decodes the leg CLEANLY and the banked stream
does not.** `s_m10.iq` is a TILED stimulus, so a correct decode repeats one payload:

| tree | delivered | distinct payload hashes | frames carrying the tiled payload |
|---|---|---|---|
| task 4, W1 only (the banked md5 `91680b59…`) | 209 | **44** | 160 / 209 |
| task 9, combined (this tree) | 209 | **2** | **208 / 209** (+ the acquisition frame) |

48 frames that the W1-only tree delivered corrupted are delivered correctly here. The
same measurement from the ring's side: that tree ended the leg at `poe = 21` (21
pop-on-empty underruns, which is what `edge_m10` pins), and this tree ends at
**`poe = 0`** — no underrun at all. Suppressing the EMPTY-edge underrun at negative SRO
is precisely what R4B + R1 are for.

So `gateA_m10`'s md5 and `edge_m10`'s `21` are **pre-fix constants**: they encode a
stream with 48 corrupted frames and 21 ring underruns. A tree that reproduced them
would be a tree on which the RX fixes did not work. They are recorded as FAIL-as-written
with the cause named, **not** relaxed.

`edge_m10`'s stated *purpose* — "prove the -10 ppm leg reaches the EMPTY edge so Gate B
is not vacuous" — is met by other evidence on this tree: 10,459,721 compared beats with
10,459,698 lag-0 disagreements is not a vacuous comparison.

## 6b. BS / PAD rows — every runnable ledger row reproduces the banked figure

| leg | criterion | measured | verdict |
|---|---|---|---|
| `census_clean` | `ck_short=0 ck_orphan=0 bs_drop=0 0<=bs_trunc<=4 h_push=h_acc=bs_words ck_frames=bs_starts bs_push=bs_pop ck_frames>400` | short 0, orphan 0, drop 0, trunc **0**, `h_push=h_acc=bs_words=`**79,760**, `ck_frames=bs_starts=`**418**, `bs_push=bs_pop=79,760` | **PASS** |
| `census_grid` | >= 3 on-grid records, all common records byte-identical to `$BANK/bs1_p000_census.txt` | want >= 3, bad 0 | **PASS** |
| `words191_k1536` | `h_push=79760 ck_frames=418 bs_starts=418 ck_short=0 ck_orphan=0 bs_lasts=417 bs_trunc=312 bs_q24=255` | 79,760 / 418 / 418 / 0 / 0 / 417 / **312** / **255** | **PASS** |
| `control_k1536` | model `t7_ok=104`, `t7_nomagic=319`; bank `t7_ok=104`, `t7_nomagic=1` | 104 / 319 ; 104 / 1 | **PASS** |
| `nrxw_k1536` | model `nrxw=80960`; bank `nrxw=73328` | 80,960 ; 73,328 | **PASS** |
| `merge_control` | bank `bs1_k1536`: `ck_frames=106`, `ck_orphan=52520` | 106 / 52,520 | **PASS** |
| `I5_sub` (substitute for `I5_wrapper`) | BS wrapper vs the already-gated R4B wrapper, same DUT/driver/stimulus: `_frames` `_deliv` `_seq` | **byte-identical** on all three | **PASS** |
| `bs_vs_pad` | the BS and PAD obj dirs on one netlist (PAD is unconditional): `_frames` `_deliv` `_seq` `_census` | **byte-identical** on all four | **PASS** |

Drop witness: `BS_FIFO_WITNESS live at_clk=20000000 ovfcnt=0` on all three BS-wrapper
legs with no `first_drop` line, from a hierarchical tap of the drop-in's own saturating
`ovfCnt` — a witnessed zero, not a silent one; and `h_push == h_acc == 79,760` counted
at the DUT pins outside the DUT.


## 7. TX F3 rows — 8 of the 10 scored `|F3|` rows PASS, including all three RX-capture rows

Harness: **not** `txfix_gate_launch.sh` (it needs `ops/agents/`, removed by the 2026-09
cleanup). The eight rows were launched as individual `systemd-run --user` units
(`txfix-t9-*`, MAXCONC=2) reproducing that script's wrapper line and its
`TXFIX_GATE_RUN_EXIT` trailer, then scored by `modem/rtl_sim/txfix_gate_score.py`.
Manifest `modem/rtl_sim/txfix_gate_runs.txt`; all eleven rows report
`TXFIX_GATE_RUN_EXIT=0`. Unit `sp3-t9tx-032041`, 03:20:41 -> 05:23:31, wall **2 h 03 m**.

* **F3 binaries** `obj_txkick_m9` / `obj_txrate_m9` <- `s1_rtl_model_tx9` = THIS tree.
* **U baselines** `obj_txkick_mu` / `obj_txrate_mu` <- task 8 round 2's model-lineage
  unfixed tree; `g0/g1/g2_*_U` were NOT re-run, they are reused as-is.

| row | rule applied | verdict | evidence |
|---|---|---|---|
| G3 `none` | golden digest + **relative** (`g0_none_U`) | **PASS** | `aligned_identical=True`, 1,305,851 common records, **0 differing**; offsets equal on **106/106** |
| G4/G5 `popabort` k=0 | **relative** (`g0_none_U`) | **PASS** | `d3_post=0 saw_armed_zero=0 max_pop_quiet=2`; offsets equal on **58/58** |
| G4/G5 `popabort` k=6 | **relative** (`g0_none_U`) | **PASS** | `d3_post=0 saw_armed_zero=0 max_pop_quiet=2`; offsets equal on **58/58** |
| G6 `latchforce` | absolute (own `sustained` clause, no offset rule) | **FAIL** | pre-declared: FAILs on the injected tree too and matches the banked 2026-09-03 summary. `saw_armed_one=1 armed_one_clk=690750 clk_to_reload=49410` are bit-identical to the injected reference |
| G7 `latchforce_pre` | **relative** (`g0_none_U`) | **FAIL / not decidable** | `saw_armed_one=1 clk_to_reload=1 max_pop_quiet=107`; **52 of 58 frames have no decodable offset** (§7.2) |
| G9 `fcbase3` (txrate) | witness | **PASS** | `zeroEvents=0 maxPopQuietClk=0 pushWraps=54 popWraps=52` |
| G10 `frcwrap` | witness | **PASS** | `pre=2 saw_self_wrap=0` |
| G11 `nearfull` | witness | **PASS** | `saw_full=1 full_clk=493426 saw_pop_abort=0`, `count in [49279,49280]`, `fullRAM_stuck_at_end=False` |
| G13 (derived from G11) | derived | **PASS** | `doubled_push_rate_seen=False` |
| G14 lint | lint | **PASS** | 10 `TXFIX_LINT_OK_F3_*` tags, exit 0 |

### 7.1 The RELATIVE offset rule, and why its baseline is `g0_none_U`

Implemented per the controller's 2026-09-12 ruling in `offsets_match_baseline()` /
`offsets_ok()`; unit test `modem/tests/test_txfix_gate_offsets.py` (7 tests, incl. the
reduction to the absolute rule on the injected v1 lineage, where every unfixed offset
is 0). Every scored line now names the rule it used (`rule=relative baseline=...` or
`rule=absolute (<why>)`).

The baseline is `g0_none_U` for ALL offset-scored rows — **not** `g1_popabort_U_k0`.
`g1`/`g2` are the rows that DEMONSTRATE the unfixed defect, so scoring a fixed run
against one inverts the test. Measured per-frame offset sequences on this tree:

| run | transmitter | forcing | offsets |
|---|---|---|---|
| `g0_none_U` | unfixed | none | 12264 x90, 12272 x8 — the receiver's lock walk |
| `g1_popabort_U_k0` | unfixed | popabort | **6088 x42, 6096 x2** — the TX slip |
| `g3_none_F3` | **fixed** | none | 12264 x90, 12272 x8 — **= g0 on 106/106** |
| `g4_popabort_F3_k0` | **fixed** | popabort | 12264 x42, 12272 x8 — **= g0 on 58/58** |
| `g4_popabort_F3_k6` | **fixed** | popabort | 12264 x42, 12272 x8 — **= g0 on 58/58** |

The fixed transmitter under `popabort` walks exactly as the unfixed one does with no
forcing; the unfixed one under `popabort` halves its offset. That is the property
G4/G5 exists to score, and it is now scored.

### 7.2 G7: the capture carries no offset evidence, on EVERY lineage

`kick_seq.py` cannot map 52 of 58 frames of the `latchforce_pre` capture — and that is
not a property of this tree:

| capture | mapped | unmapped |
|---|---|---|
| `_passA_injected/g7_latchforce_pre_F3.bin` (injected v1) | 5 | 53 |
| `_round1_model/…` (task 8 round 1, model) | 6 | 52 |
| `_passB_model_v1scorer/…` (task 8 round 2, model) | 6 | 52 |
| this tree | 6 | 52 |

Under the historical absolute rule G7 scored PASS because `offsets_clean()` SKIPS
`None` offsets, so the verdict rested on 5-6 mapped frames — the vacuity that
function's own docstring warns about. The relative rule does not skip them: an
unmapped frame where the baseline has 12272 is a difference, so G7 now reports FAIL
rather than a vacuous PASS. **Recorded, not repaired**: the honest statement is that
this row is not decidable until `kick_seq.py` can decode the `latchforce_pre` capture
(or G7's offset clause is dropped in favour of its `saw_armed_one` / `clk_to_reload`
witnesses, which are present and correct here).

### 7.3 The U baseline's lineage delta — measured, and it does not matter

Task 8 round 2's unfixed tree (`s1_rtl_model_tx_u`, from `regen8u`) carries **W1 +
STEER + R1 only**. Header-stripped RTL comparison:

```
s1_rtl_model_tx   vs s1_rtl_model_tx_u  ->  5 files   (task 8's pair: the four TX files + TxRxCompo_ip)
s1_rtl_model_tx9  vs s1_rtl_model_tx_u  -> 14 files   (THIS pair: + BsSeamCensus.v, BsSerCensus.v,
                                                       ByteSerializer.v, ByteRxFifo.v, TxInterleaveK5.v,
                                                       TxRxCompo_ip_{addr_decoder,axi_lite,dut}.v,
                                                       TxRxComposite.v)
```

So the U row is a same-receiver baseline for task 8's pair but **not** for this
combined tree: it lacks BS, PAD and the 4096-deep BRAM `ByteRxFifo`. Rather than
assume that away, it was measured — and the `SEL=6` capture is untouched by those nine
files:

* `g3_none_F3` (this tree) vs `g0_none_U` (their tree): `aligned_identical=True`,
  **0 of 1,305,851** records differ, offsets equal on 106/106.

The BS/PAD/FIFO overlays are all in the BYTE plane, downstream of the FEC decode that
`SEL=6`'s `iq_debug_mux` taps upstream of, which is why. The lineage delta is therefore
a recorded caveat with a measured bound, not an open risk.

### 7.4 A snapshot mistake, recorded

`beat_runs/_task9_prep/` was made with `ln -f` (hard links). The F3 runs then
`fopen(..,"wb")` the same inodes, so that directory's `g3/g4/g6/g7_*_F3*` entries were
truncated with the originals rather than preserving them. **Nothing was lost**: task 8's
own `_passA_injected/`, `_round1_model/` and `_passB_model_v1scorer/` snapshots were made
with `mv`/`cp`, are intact, and are what §7.2 reads. The U rows in `_task9_prep/` are
also intact (they were never re-run). Use `cp`, not `ln`, for a snapshot of files a
later run will reopen.

### 7.4b Scorer hardening (fix round 1) and the re-score

Two holes in the relative rule as first written, both closed without re-running a sim:

1. **`None == None` was scoring as agreement.** `dict(base_seq)` stores an unmapped
   baseline frame as `None`, and `o != base[fi]` is False when both are `None` — so a
   row whose whole overlap was undecodable on BOTH sides would have reported
   `equals_unfixed=True` on zero evidence, the same trap `offsets_clean()` documents.
   The rule now counts frames MAPPED ON BOTH SIDES and requires
   `max(8, 0.25 x min(len(seq), len(base_seq)))` of them; the detail line prints
   `mapped_both=`.
2. **The "changes no injected verdict" claim was too broad.** It holds only where every
   frame decodes. On the injected v1 `g7_latchforce_pre` capture (5 mapped / 53
   unmapped, §7.2) the two rules genuinely differ: `offsets_clean()` skips the unmapped
   frames and passes on 5, the relative rule fails for want of evidence. The comment,
   the docstring and the test name now say "where every frame decodes", and a test pins
   the differing case.

Also: the fallback label no longer says `absent/incomplete` when the baseline RAN to
completion and `kick_seq` simply decoded nothing from it — that is
`completed but kick_seq decoded 0 frames`, which is the difference between "re-run the
baseline" and "fix the decoder".

Re-scored from the SAME `beat_runs` artefacts with the amended scorer — **no verdict
moved**, and G7's reason became the honest one:

```
G3 F3        PASS  rule=relative baseline=beat_runs/g0_none_U common=106 mapped_both=106 equals_unfixed=True
G4/G5 F3_k0  PASS  rule=relative baseline=beat_runs/g0_none_U common=58  mapped_both=58  equals_unfixed=True
G4/G5 F3_k6  PASS  rule=relative baseline=beat_runs/g0_none_U common=58  mapped_both=58  equals_unfixed=True
G7 F3        FAIL  vacuous -- only 6 of 58 common frame(s) are mapped on BOTH sides
                   vs beat_runs/g0_none_U (need >= 14; decoded 58 / 106)
G9/G10/G11/G13/G14 F3  PASS (unchanged)
```

`modem/tests/test_txfix_gate_offsets.py` is now **11 tests**.

### 7.5 Reading `beat_runs/txfix_gate_summary.txt`

The scorer always emits all of G0-G14 x F1/F2/F3 — **30 lines**. This task's manifest
(`modem/rtl_sim/txfix_gate_runs.txt`) contains only the three U rows and the eight
`|F3|` rows, so every F1 and F2 row in that summary reads
`FAIL incomplete -- no TXFIX_GATE_RUN_EXIT trailer yet`. **Those are "not run here",
not failures on this tree** (F1/F2 are alternative TX variants; F3 is the deployed one).
The rows this gate ran and scored are exactly the ten listed in the table above.

## 8. Verdict

**GATE 1 PASSES on its own subject.** On ONE model tree carrying W1 + STEER + R1 + BS +
PAD + TX F3 plus the rxfifo / txcap / ddrcap(TXMARK=1) / ddrcap2 stages, at BOTH
`sro_sign` settings, all ten `(variant, stimulus)` rows reproduce
`reference_loss.toml` **exactly** — 80 scored quantities, zero deviations,
`MATRIX_EXIT 0` — and every structural ledger row that is runnable on a model tree
passes. **No overlay interaction was found.**

| group | PASS / total | note |
|---|---|---|
| ppm matrix, FIXCTL=0 (`R4B/*`) | **5 / 5** | every field exactly the reference |
| ppm matrix, FIXCTL=0x20 (`R4DR1/*`) | **5 / 5** | every field exactly the reference |
| R4B structural G1-G4 | **3 / 4** | `G4_prearm` FAILs on its `sidx` clause only (§3.2) |
| R4D+R1 structural S1-S5 | **7 / 7** | incl. `n_p10` at 0.00 % |
| runtime-selection row | **1 / 1** | bit 5 inert at 0 ppm, decisive at +10 ppm |
| W1 | **4 / 7** | Gate B PASS both stimuli, 0 mismatches; 3 banked-constant clauses are pre-fix values (§6.1) |
| BS / PAD | **8 / 8** | every banked figure to the digit |
| legs total | **47 / 51** (the table now has 53 rows; `repro_p000` + `repro_p000_content` were added in fix round 1, §5.4) | wall 03:12:51 at `--jobs 4` |
| TX `\|F3\|` rows | **8 / 10** scored | G6 pre-declared FAIL on both lineages; G7 not decidable (§7.2) |

### 8.1 The four leg failures, in one line each

| leg | why it is not a Gate 1 finding |
|---|---|
| `G4_prearm` | content identical 6/6; `sidx` is +1, a constant introduced by the BRAM `ByteRxFifo` drop-in / PAD arbiter and present on a tree with no F3 at all (§3.2) |
| `gateA_p000` | `cmp` and the 164-line count pass; only the md5 moves, and only through the `sidx` column (§6.1) |
| `gateA_m10` | `cmp` and the 209-line count pass; the md5 differs because this tree decodes 208/209 tiled frames correctly where the banked W1-only stream decoded 160/209 (§6.1) |
| `edge_m10` | pins `poe == 21`, i.e. 21 ring underruns; this tree has `poe = 0` because R4B + R1 suppress them (§6.1) |

**The honest split is two and two**, and the earlier "three of the four" in this file
was wrong: `gateA_p000` moves ONLY through the `sidx` column (§6.1 measures its
delivered content as identical on 0 of 164 differing frames), so it belongs with
`G4_prearm` in the drop-in-latency class, not with the fixes.

| class | rows | what the row is actually measuring |
|---|---|---|
| **drop-in +1** (a byte-plane latency constant, content bit-identical) | `G4_prearm`, `gateA_p000`, and `repro_p000` (§5.4) | the shipped BRAM `ByteRxFifo` drop-in / PAD arbiter costs one input sample that `$BANK`'s 64-deep register FIFO does not |
| **pre-fix constant** (the fixes working) | `gateA_m10`, `edge_m10` | the banked value encodes a stream with 48 corrupted frames and 21 ring underruns |

None was repaired to make the row pass.

### 8.2 The plan's stop rule

One diagnosis attempt was available and it was spent on `G4_prearm` (§3.2), where the
cause was localised exactly — to a named design change, with a same-harness control on
both sides of it. The `--force` re-run after the concurrent-runner collision (§3.1) was
an I/O fault, not a row missing tolerance, and did not consume it. No second iteration
was needed: no row of the equivalence matrix missed its tolerance.

### 8.3 Concerns for the controller

1. **The still-uncommitted overlay reorder** (§1.1) — this tree was gated with
   `txfix_f3_overlay` BEFORE BS/PAD.
2. **`run_gates.sh` has no work-directory lock** (§3.1). Two runs of one table silently
   corrupt each other's artefacts; the damage surfaces as a scorer crash several legs
   later. A `flock` on `$wd` would make it a loud refusal.
3. **Criteria that pin s1-lineage CONSTANTS should become same-lineage comparisons**:
   `G4_prearm`'s `sidx` clause, `gateA_*`'s md5 clause, `edge_m10`'s `21`. All three are
   now measuring the byte-plane design change or the RX fixes rather than the property
   they name.
4. **`kick_seq.py` cannot decode the `latchforce_pre` capture** on any lineage (§7.2),
   so G7's offset clause has never carried evidence. Under the old absolute rule that
   was a vacuous PASS; under the relative rule it is an honest FAIL.
5. **No model-lineage unfixed tree matches THIS tree** (§7.3). The measurement says the
   nine extra files do not touch the `SEL=6` capture, so the reused baseline is sound
   here — but a future TX gate on a combined tree should build its U baseline from the
   same assemble.
6. **`--jobs > 1` needs the `: depends` idiom** in any legs table with criterion-only
   rows (see `model_matrix.legs`'s header); `run_gates.sh`'s token rule does not see a
   dependency written as `<prefix>_deliv.txt`.
