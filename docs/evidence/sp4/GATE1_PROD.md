# sp4 Task 7b: prod re-derived at f3072 / 2 sps, prod Gate 1 against the dev bank

Plan `docs/superpowers/plans/2026-09-13-2sps-rung.md` Task 7b (decision B: the shipped chain is
`modem/prod`, re-derived from `modem/dev` and proven equal on the same gates). Dev side:
`GATE1.md` (Gate 1 PASS 53/53 on `regen_sp4d`). Branch `2sps-rung-7b-prod-2026-09-22`.

## 1. Derivation

`QPSK_FRAME=f3072 QPSK_SPS=2 modem/prod/derive/derive.sh /mnt/onetb/scratch/qpsk-build-trees/derive_sp4`
(env recorded in `modem/prod/DERIVATION.txt`: LEAN RXFIX TXFIX BEATFIX BEATOBS FRAMESTAT, dev git
`0c995b7b`). Three attempts were needed; the first two exposed derivation-TOOL defects, fixed in the
tools (never in the prod model by hand):

| attempt | outcome | cause / fix |
|---|---|---|
| 1 (06:18) | `FATAL: checkhdl gate patch did not apply` | `patch_gates_for_flat.sh` anchored on `run('simulink/assemble_...')`; the stage-folder layout (2026-09-17) spells it `run('assemble_...')`. The patcher now normalises the spelling first. |
| 2 (06:23) | `DERIVE_DONE`, model md5 `4e3bd281a8fe`; prod Simulink gate then failed `RxAlign +41 latency constant not found` | `flat_rename_reg_ports` and `flat_simfix` rewrote `sim_byte_gate_k5.m` at the kit ROOT ("(missing, skipped)"), so the derived gate kept the un-renamed ports and the dev latency retune. Both tools now target `simgate/` and assert the file exists. |
| 3 (07:12) | `DERIVE_DONE`, model md5 `7609b47320dc`, **structural diff vs attempt 2: equal** (blocks -0 +0, changed 0, connections -0 +0) | -- |

Because attempts 2 and 3 produce structurally identical models, the prod hdl stage and Gate 1
below (started from attempt 2's model) stand for the committed prod tree.

`modem/prod` after derivation 3: `commhdlQPSKTxRxLoopback.slx`, `DERIVATION.txt`,
`DERIVATION_DIFF.txt`, `hdlsim/checkhdl_gate_240k5_byte.m`, `hdlsim/run_netlist_gates.sh` (S1
skipped at f3072, k5-only analyser), `hdlsim/rtl_sim_overrides/sim_byte.cpp` (same-cycle
handshake), `simgate/sim_byte_gate_k5.m` (`reg_` ports, `rxAlignLat`, full-preamble oracle).

## 2. Prod netlist and Simulink gates (plain `make_kit.sh prod` kit, production env)

Kit `/mnt/onetb/scratch/qpsk-build-trees/regen_sp4p/jupiter_byte_sp4prod_gates2`, env
`QPSK_LEAN=1 QPSK_FRAME=f3072 QPSK_SPS=2 QPSK_BEATFIX=1 QPSK_BEATOBS=1 QPSK_FRAMESTAT=1 QPSK_RXFIX=1
QPSK_TXFIX=1` (the checkhdl gate is env-gated: without `QPSK_LEAN` it asserts the forensic register
port that LEAN strips -- a first run without the env failed on exactly that; not a derivation
defect).

* `hdlsim/run_netlist_gates.sh` (derivation 2 kit, 06:46 .. 07:06): checkhdl errors=0 warnings=2
  (unconnected ports inside `No HDL` subsystems), makehdl 166 Verilog files, `PI_GATE: PASS`,
  S1 skipped (k5-only analyser), **S1B PASS rot=0 and rot=17** (`cap_out 0x04922282`, 19 rx packets,
  no free-run slip).
* `hdlsim/run_netlist_gates.sh` again on the derivation-3 kit (07:21 .. 07:41): same result, S1B PASS rot=0 / rot=17.
* **Simulink byte gate** on the derivation-3 kit (`simgate/sim_byte_gate_k5.m`, `reg_` ports, `rxAlignLat`
  workspace parameter, full-preamble oracle; 07:41 .. 10:34 on a shared CPU): runs A, C, D **PASS** --
  air golden from frame 3 / 3 / 1 of 7, BIST `cap 0x04922282` with no late errors, byte-rx 6 complete
  382-word packets golden (`SIM_BYTE_GATE_K5.txt` in the kit).

## 3. Prod hdl stage and Gate 1 (`build_image.sh --tag sp4 --tree prod --stop-after gates`)

`GATES_JOBS=4 SRO_SIM_DIR=SRO_BANK_DIR=/mnt/onetb/scratch/qpsk-build-trees/sro_sim_f3072`, parent
`regen_sp4p`. The gates stage regenerates `modem/rtl_sim/s1_rtl_model` from the PROD kit and runs
the model matrix against the DEV bank (`GATE1.md` section 5), so the identity rows (`G1_ident`,
`G4_prearm`, `repro_p000*`, `census_grid`, the `k1536` bank rows) are the equivalence proof: they
pass only if the prod tree's streams equal the dev tree's, sample for sample.

**hdl stage** (06:43 .. 07:1x, `regen_sp4p/work/hdl.log`): `RXFIFO_INJECT_OK depth=8192`, `BUILD_HDL_BD_OK`
(BYTE_WIRE, WIRE, VALIDATE, DDS_DIET, COMPLETE_BYTE_BD, DDRCAP_BD_WIRE, SEQBIST_WIRE), `BUILD_HDL_KIT_OK`,
`MODEL_OVERLAYS_OK W1 R4B/R4D R4DR1 BS PAD F3`, `BS_READY_PAD_OK depth=4`, `BUILD_HDL_DONE`.

**gates stage** (`BUILD_IMAGE_TREE_MARKER_OK W1 R4B R4DR1 BS PAD F3 all model`, model tree
`7058e836650bd125`, six objects rebuilt, matrix 07:1x .. 12:26, wall 5:18:54, `STAMP.gates`):

    GATE_LEGS model_matrix pass=53 fail=0
    GATE_PASS model_matrix

**Prod Gate 1 PASS 53 of 53 -- the same set as dev, and the streams are the same.** Every run leg
reproduces the dev number exactly (`score_t7.py`, T7_NAIR=428, lost frames in the denominator):

| leg | dev (GATE1.md run 4) | prod | skips / extras / ring end (prod) |
|---|---|---|---|
| m0_n_p000 (R4B) | 0.00 % (421/421) | 0.00 % (421/421) | 8 / -- / 2 |
| m0_n_p2p5 | 0.24 % (420/421) | 0.24 % (420/421) | 5 / -- / 31, overflow x2 |
| m0_n_m2p5 | 0.00 % (420/420) | 0.00 % (420/420) | 32 / -- / 9 |
| m0_n_p10 | 22.75 % (330/422) | 22.75 % (330/422) | 3 / -- / 31, overflow x79 |
| m0_n_m10 | 0.00 % (420/420) | 0.00 % (420/420) | 110 / -- / 2 |
| m20_n_p000 (R4DR1) | 0.00 % (421/421) | 0.00 % (421/421) | 8 / 0 / 2 |
| m20_n_p2p5 | 0.00 % (421/421) | 0.00 % (421/421) | 5 / 10 / 23 |
| m20_n_m2p5 | 0.00 % (420/420) | 0.00 % (420/420) | 32 / 0 / 9 |
| m20_n_p10 | 0.00 % (422/422) | 0.00 % (422/422) | 3 / 87 / 23 |
| m20_n_m10 | 0.00 % (420/420) | 0.00 % (420/420) | 110 / 0 / 2 |

Identity, not just equal counts: `m0_n_p000_deliv.txt` of the prod run is byte-identical (`cmp`) to
the dev bank's `r4b_p000_deliv.txt`, and `m0_n_p000_frames.txt` has the same md5 (`ed74a5979544`);
`G1_ident`, `G4_prearm` (pre-arm identity including sidx), `repro_p000` / `repro_p000_content`,
`census_grid` and the three `k1536` bank rows all pass against the dev bank. Logs:
`modem/rtl_sim/evidence/sp4prod/legs/{model_matrix.log,gates_stage.log}`, stamp
`modem/rtl_sim/evidence/sp4prod/STAMP.gates`.

## 4. Verdict

`modem/prod` re-derived at f3072 / 2 sps reproduces the dev tree on every gate: netlist (checkhdl,
PI, S1B rot 0/17), Simulink byte gate (A/C/D), and Gate 1 53/53 with sample-identical streams. This
is the tree Task 8 builds the sp4 image from (`build_image.sh --tag sp4 --tree prod --from vivado`,
`STAMP.gates` present with fail=0, so no hand-written stamp is needed at this rung). No board was
touched.

## 5. Addendum (2026-09-22 17:00): re-derived after the Message Generator ROM rewrite

Task 8 found that Vivado 2025.1 segfaults on the f3072 Message Generator ROM (`GATE2_TIMING.md`
section 1); the overlay fix changed the dev tree, so prod was re-derived (attempt 4, model md5
`49603333eb27`, structurally equal to attempt 3 -- the change is inside the chart script) and the whole
prod gate set re-run on it: netlist gates PASS (S1B rot 0/17), Simulink byte gate A/C/D PASS, and
`build_image.sh --tree prod --stop-after gates` **Gate 1 53 of 53** again on model tree
`eaa3cf8631886a09` (`regen_sp4q`), identity rows against the unchanged dev bank included. That tree is
the one the sp4 image is built from.
