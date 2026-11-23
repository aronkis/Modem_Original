# sp4 Task 8: the Vivado build from prod, Gate 2 (timing) and the symbol-rate path rows

Plan `docs/superpowers/plans/2026-09-13-2sps-rung.md` Task 8. Built from the `modem/prod` tree that
passed Gate 1 (`GATE1_PROD.md`), on hdl-dev-2 (Vivado 2025.1, `/mnt/disk2/scratch/qpsk-builds`),
`build_image.sh --tag sp4 --tree prod --from vivado`. Gate 2 = post-route (physopt) WNS >= 0.005 ns
on `axi_adrv9001_adc_1_clk` (`modem_wns.py`); the new `--paths` rows report the worst slack per
symbol-rate block (`Symbol_Synchronizer`, `Carrier_Synchronizer`, `Viterbi`) from
`system_top_timing_paths_modem.rpt`, written by the template after implementation (non-fatal).

## 1. Build attempt 1 (2026-09-22 12:35): Vivado segfault in synthesis, not a timing result

`synth_1` died with `Segmentation fault (core dumped)` about 9 minutes in, during RTL elaboration
(`runme.log` line 1193; no timing report, `rsync` of `boot/` then failed with code 23). Reproduced
twice (a second full build, and an out-of-context `synth_design` of the modem IP alone in
`/mnt/disk2/scratch/qpsk-builds/ooc_sp4_modem`). Bisect by out-of-context synthesis of sub-tops
(`ooc_top.sh <module>`):

| top | result |
|---|---|
| `TxRxCompo_ip` (whole modem IP) | segfault |
| `Transmitter` | **segfault** |
| `Receiver` | OK |
| `Filter` (RRC), `RxDeint`, `TxInterleaveK5`, `Preamble_Detector`, `ByteRxFifo` | OK |
| `MATLAB_Function_block3` (Message Generator ROM) | **segfault** (module alone) |

Cause: the Message Generator's ROM overlay (`msggen_rom_overlay_k5.m`) stored the pre-coded packet
as 1538 packed 32-bit words and, every step, unpacked them into a 49216-element logical array
(`msgbits`) indexed by `indexCount` -- HDL Coder emits the 1538 x 32 unpack loop plus a 49216:1
constant mux in one combinational block. At f1536 (24640 bits, 770 words) Vivado survived it; at
f3072 it crashes in elaboration. Fix (f3072 only, k5/f1536 HDL byte-identical): read the bit from
the packed word directly, `word = indexCount >> 5`, `bit = 32 - (indexCount & 31)`, the same bit
order as the unpack. Functionally checked by the Simulink byte gate run D (ROM path, air golden) and
S1B on the regenerated dev kit, and by the RTL delta of the regen (only `MATLAB_Function_block3.v`
changes), below.

## 2. Regen 5 (dev, packed ROM) and its gates

* RTL delta vs regen 4 (`regen_sp4e` vs `regen_sp4d`, headers ignored): `MATLAB_Function_block3.v`
  (98 lines) and the interleaver's wire-name renumbering noise (`p58tmp`/`p59tmp`, no logic) only.
* Out-of-context `synth_design` of the new `MATLAB_Function_block3` on hdl-dev-2: **OK** (rc=0; the
  old one segfaulted in the same harness).
* Dev S1B (pristine RTL, f3072 goldens): PASS rot=0 / rot=17.
* Dev Simulink byte gate (regen-5 kit): runs A, C and **D (ROM path: air golden from frame 1 of 7,
  BIST 0x04922282, byte-rx golden)** PASS -- the packed read emits the same bit stream as the unpack.

## 3. Prod re-derived from regen 5 (`derive.sh`, attempt 4; model md5 `49603333eb27`, structural diff
vs the previous prod: equal -- the change is inside the Message Generator chart script). Prod S1B
PASS rot=0 / rot=17 on the derived kit.

Prod Simulink byte gate (production env, `jupiter_byte_sp4prod_gates5`): runs A, C, D PASS.

**Prod hdl stage + Gate 1 on the packed-ROM tree** (`build_image.sh --tag sp4 --tree prod --stop-after
gates`, parent `regen_sp4q`, model tree `eaa3cf8631886a09`, git `00ee9f3c`, f3072 bank): all hdl tokens,
`BUILD_IMAGE_TREE_MARKER_OK W1 R4B R4DR1 BS PAD F3`, then

    GATE_LEGS model_matrix pass=53 fail=0 wall=00:26:04
    GATE_PASS model_matrix

-- again 53 of 53 with the identity rows (G1/G4/repro/census_grid/k1536) passing against the dev bank,
i.e. the ROM rewrite did not move a single receiver sample (the TX ROM feeds only the internal BIST
source; the bank stimuli are traffic-generator captures). `STAMP.gates` fail=0 -> the vivado stage runs
gated. (Wall 26 min for the whole matrix versus ~5 h in earlier runs: the earlier runs shared the
machine with MATLAB simulations; the outputs are identical.)

## 4. Build attempt 2 (2026-09-22 16:59, unit `txfix-build-sp4_build-1790110785`)

Same driver command, same kit (`regen_sp4q/jupiter_byte_sp4_build`, model tree `eaa3cf8631886a09`,
git `00ee9f3c`), `IMPL_STRATEGY=explore`, 6 jobs. Synthesis: RTL elaboration finished in 48 s (where
attempt 1 died), `synth_design completed successfully` after 9 min 12 s; implementation through
bitstream, fetch and gate done at 17:34 (35 min wall for the whole stage). `TXFIX_BUILD_DONE`.

**Gate 2 (`modem_wns.py`, post-route physopt timing summary, Intra Clock Table):**

| clock | WNS | TNS | failing / endpoints | WHS | THS |
|---|---|---|---|---|---|
| `axi_adrv9001_adc_1_clk` (modem) | **0.794 ns** | 0.000 | 0 / 96125 | 0.010 ns | 0.000 |
| design overall (all clocks) | 0.086 ns | 0.000 | 0 / 190153 | 0.010 ns | 0.000 |

    MODEM_CLK_WNS clock=axi_adrv9001_adc_1_clk wns=0.794 tns=0.0 failing=0 total=96125
    BUILD_IMAGE_WNS_OK wns=0.794 floor=0.005 ref_pad=0.105 ref_sp2A=0.447 ref_sp2B=0.785

**PASS**, with more margin than any banked image (rxfixpad 0.105, sp2A 0.447, sp2B 0.785, sp3prod
1.126 on the f1536 rung). No re-time round was needed (plan Task 8 step 3 not entered).

**Symbol-rate path rows** (`modem_wns.py --paths` on `system_top_timing_paths_modem.rpt`, the 50
worst endpoints among `*Symbol_Synchronizer* | *Carrier_Synchronizer* | *Viterbi*`, all MET):

    MODEM_PATHS block=Symbol_Synchronizer worst_slack=2.907 n=5   (Frequency and Time Synchronizer / Symbol Synchronizer)
    MODEM_PATHS block=Carrier_Synchronizer worst_slack=2.791 n=45 (Frequency and Time Synchronizer / Carrier Synchronizer)

No Viterbi endpoint is among the 50 worst of that set, i.e. every Viterbi path has more than 2.79 ns
of slack; the 2-sps symbol-rate loop is not near the clock's critical path (the 0.794 ns WNS
endpoint is elsewhere in the modem clock domain).

## 5. The image

`BOOT.BIN.jupiter.sp4.5108cdb77aebb0989c53c65f4a0eac75` (7203552 bytes, md5
`5108cdb77aebb0989c53c65f4a0eac75`), banked in `images/` as the one canonical file with its `MD5SUMS`
row and `images/README.md` row (no board-named aliases -- repo rule since 2026-09-17; the flash rails
resolve `FLASH_MD5=5108cdb77aeb` through `MD5SUMS`). Built from `modem/prod` at f3072 / 2 sps
(`STAMP.hdl`, `STAMP.gates` fail=0, `STAMP.vivado` in `regen_sp4q/work`). **Not deployed; no board
was touched** -- Task 12 (silicon) needs the operator's explicit go, and Tasks 9-11 (host f3072 mode
with the 4 MB carve, dtb, ops rung r4) come first.
