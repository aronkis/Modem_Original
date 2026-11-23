# SP3 Gate 3 re-test (2026-09-12 afternoon): the sp3 "transmitter wedge" is 148's TX SSI eye, not the fabric

Follows `SP3_SILICON.md` (Task 13, Gate 3 FAILED: every leg with an sp3 transmitter wedged
within 18-61 s). This session re-opened that verdict with the systematic-debugging process:
evidence first, then a working reference, then one variable at a time on silicon. Images:
sp3 candidate `c5ec53bc610c`, shipped sp2A `3e7f4232a3b5` (148), shipped sp2B `d94b4df391a1`
(146). Every capture below is `ops/capture_r3.sh {A|B} -d <s> -k`, scored on `frames.bin`
with lost frames in the denominator (`ops/accept_analyze.py`; the row-sweep scorer is the
CRC-pass fraction over all logged frames plus the carrier-reset counter delta).

## 1. What the Task 13 captures actually recorded

Re-reading the three wedged reverse legs (`ops/r3cap/sp3_rev_*`):

* the transmitter's host kept feeding its TX DMA at the full 1245 frames/s with `tx_stall=0`
  throughout; the receiver saw either (a) a sudden carrier-reset storm (~1000 `rstcs`/s, CFC
  estimate swinging by ±250 k) with ~500 detected frames/s all failing CRC, or (b) 3-27 s
  windows of 16-32 detected frames/s with the carrier loop still locked (`rstcs` 0, CFC
  steady at -4750). Both are a transmitter whose emitted signal went bad while its host feed
  did not.
* The one forward reading with 146 on sp3 (`sentinel 07:44:43 rate=219/s crc=40.6%`) was
  taken 4 s after the third wedged capture ended, i.e. in a wedged aftermath, not a
  steady-state sample.
* Whitening is host-side (`host/qpsk_frame.c`, `QPSK_WHITEN`), so it cannot differ between
  images. Historical base rate: 0 of 9 banked sp2 captures wedged; 3 of 3 sp3 reverse legs did.

## 2. Static differential: the sp3 transmit path is identical to sp2A

Read-only agent report `sp3_tx_diff.md` (kits on hdl-dev-2: sp3
`/mnt/disk2/scratch/qpsk-builds/jupiter_byte_sp3_build`, sp2A
`~/qpsk-builds/jupiter_byte_rxfixpadsp2_build`):

* block design: whole-design pin-to-net diff; `tx_byte_dma -> byte_breakout -> traffic_gen ->
  TxRxCompo_ip_0` identical pin for pin, same `qpsk_traffic_gen_v2.v` md5, same GPIO reset
  defaults, address map unshifted. The only BD changes are receive-side (146-lineage shape:
  no `traffic_gen_rx`, `dut_byte_ready_in` from the DMA back-pressure, as sp2B already runs).
* DUT RTL (synthesised `ipshared` copies): of the 31 modules in the Transmitter and
  ByteWordBuffer cone, 24 byte-identical; the 7 differences are the F1/F3 overlay-vs-injector
  forms (Boolean-identical, source-agnostic, so equal on the `extWord` path) and additive
  `txur` observation ports. Net drivers of `enb*`, `WordRT/AvailRT/FirstRT`, `PopRT`, `PopDly`
  character-identical. All instantiations use named association.
* write register map identical in address and reset value; the receive-side `FixCtlDec`
  bit map changes (bit 3 `enSlack` removed, bit 4 `w1Freeze`, bit 5 `sroSign`) are documented
  ABI changes, not TX.
* routed timing: setup and hold met in both (sp3 WNS 0.207/WHS 0.009 over 181,904 endpoints;
  sp2A 0.098/0.009 over 344,082 - sp2A carries ~57 k more flops of instrumentation);
  `report_methodology` critical warnings identical (TIMING-6/7/54: 7/7/18); the same 16 output
  ports carry no output delay in both (the ADRV9001 SSI outputs are unconstrained by design and
  rely on the chip-side delay calibration).

## 3. Silicon discrimination (one variable at a time, both boards rolled back after each)

| chain | 148 | 146 | leg | result |
|---|---|---|---|---|
| 1 | sp2A | **sp3** | fwd 146 TX -> 148 RX, 610 s | healthy, PER 0.002 % (18/740,864) |
| 1 | sp2A | **sp3** | rev 148 TX -> 146 RX, 607 s | healthy, PER 0.045 % (331/737,298) |
| 4 | **sp3** | sp2B | 10 mode-1 loopback arms | all clean: 1258 f/s, 0 bit errors, 0 resets, `txurcnt`/`stallcnt` 0 |
| 4 | **sp3** | sp2B | rev 148 TX -> 146 RX | **WEDGE at 114 s**; 74 % CRC pass from t=0, then reset storm |
| 5 | **sp3** | sp2B | rev, tx0 pin released (auto-tune landed on the same 5/3) | healthy 615 s, CRC 99.96 %, PER 0.053 %, 0 resets |
| 6 | **sp3** | sp2B | rev, tx0 row sweep 90 s each | see section 4 |

So: the sp3 transmitter on **146** is fine, the sp3 receiver on **146** is fine, the sp3
image on **148** is clean in internal loopback (which bypasses the ADRV9001 SSI and the host
DMA path) but its on-air transmit is bad on some arms and not others. Combined with section 2
this leaves the board-specific, arm-specific, transmit-only element that the loopback does not
exercise: 148's ADRV9001 TX SSI (LVDS) interface and its delay row.

Rail note: the 148 flash rail's two-pass mode-1 gate compares `0x20C` to a golden digest;
on sp3 that register is the beatfix violation count (read `0x1` and `0x0` on different
boots), so no constant golden exists. `arm148_mode1.sh` gained `GOLD=any` (digest logged,
fps/errps still gate) and a test-only `ARM_SETTLE` override; `ops/tests/test_rail_guards.py`
covers both. One of 16 sp3 mode-1 arms today read `fps=0` (link not running) two minutes
after a fresh boot; the sp2-lineage rail history has 0 such arms in ~40.

## 4. tx0 SSI delay row sweep on 148 with sp3 (chain 6; `SSI148="<clk> <strobe/data>"`)

Bring-up pins 148's tx0 row to clock 5 / data 3 (`bringup_r2r3.sh`, chosen on the sp2
bitstreams). Reverse leg into 146 on sp2B, 90 s traffic per row:

| tx0 clk/data | CRC pass | resets | verdict |
|---|---|---|---|
| 5/3 (pinned default) | 99.99 % | 0 | healthy |
| 4/3 | 99.99 % | 0 | healthy |
| 6/3 | 99.99 % | 0 | healthy |
| 5/2 | 99.98 % | 0 | healthy |
| **5/4** | **46.3 %** | 26,005 | **WEDGE at 17 s** |
| 4/4 | 99.99 % | 0 | healthy |
| 3/4 | 99.98 % | 0 | healthy |
| **6/4** | **0.00 %** | 33,606 | **WEDGE at 17 s** |

The driver's PRBS auto-tune on the same board and image produced 5/3 on one boot and 5/4 on
another (live `ssi_delays` reads), and during bring-ups the transient rows included 6/4. The
pinned 5/3 is one data step from the dead 5/4 row. The chain-4 bad arm (74 % from t=0 at the
pinned 5/3) is consistent with an arm whose SSI phase landed on the bad side of that edge.

The ADRV9001 `tx0_ssi_test_mode_status` flags (`dataError`, `strobeAlignError`; sticky,
cleared on every read per `adi_adrv9001_ssi.c`) were sampled every 30 s on both boards
through the sweep: they read set on the healthy 146 transmitter as often as on 148 and did
not separate the bad rows - not usable as an indicator in normal data mode.

## 5. Confirmation, control eye map and repeated rows (chains 6 and 9)

* chain 6 confirmation, 600 s at the pinned 5/3 on sp3: **WEDGE at 93 s** (CRC 88.6 % before it,
  28,585 resets). Tally at 5/3 on 148/sp3: Task 13 x3 + chain 4 + this = 5 wedges, chain 5 (615 s)
  and the chain 6 row (90 s) clean.
* chain 9 phase A, the same 8 rows with 148 on **sp2A** (control): every row healthy
  (CRC 99.92-99.99 %, 0 resets), including 5/4 and 6/4. The eye moves with the bitstream.
* chain 9 phase B, 148 on **sp3**, candidate rows repeated (90 s each, order 4/3 5/2 4/4 3/4 5/4
  4/3 5/2 4/4 3/4): 4/3 99.92/99.97 %; 5/2 97.5 % with 6,928 resets, then 99.95 %; 4/4
  **WEDGE (0 %)** then 99.96 %; 3/4 99.95/99.90 %; 5/4 (control) 99.92 % with 10 resets.

Per-row tally on 148/sp3, reverse leg, bad = wedge or CRC < 99 %:

| tx0 clk/data | arms | bad |
|---|---|---|
| 5/3 (sp2-era pin) | 8 | 5 |
| 5/4 | 2 | 1 |
| 6/4 | 1 | 1 |
| 4/4 | 3 | 1 |
| 5/2 | 2 | 1 (marginal, resets) |
| 6/3 | 1 | 0 |
| 3/4 | 3 | 0 |
| **4/3** | **3** | **0** |

On 148/sp2A: 9 arms today (8 rows + chain 1), 0 bad; the banked history has none either.

Reading: the failure is per arm, not per row, and the sp3 bitstream makes 148's on-air transmit
marginal enough that a large fraction of arms come up bad (bursty in-frame bit errors, CRC 46-88 %,
then a carrier-reset storm on the peer) while the same fabric logic in internal loopback is clean.
The delay row modulates the odds; 4/3 (also clean on sp2A) is the row with no bad arm in three and
is recorded for the sp3 image in `ops/profiles/tx_ssi.conf`. The SSI TX outputs being unconstrained
in the build is the structural reason a bitstream can move the eye; constraining them (or a
build-level fix in the axi_adrv9001 TX interface timing) is the durable remedy and is not done here.

## 6. Gate 3 re-run on the sp3 pair at 148 tx0 4/3 (chain 10, both boards on sp3)

| window | result |
|---|---|
| reverse 1, 615 s | healthy: PER 0.033 % (246/746,993), CRC 99.97 %, 0 resets; bring-up applied `tx0=c4d3` from the table on its own |
| reverse 2 | **WEDGE at 17 s**, CRC 40 %, reset storm (same arm state class as before) |
| forward 1 | clean for 99 s (PER 0.007 %, 7/99,634), then detected frames fell to 32-48/s with the carrier loop still locked and the 146 host feed at full rate; **WEDGE at 112 s** |

So the delay row is a mitigation, not the cause: 4/3 is now 1 bad in 4 arms, and the forward leg
(146 sp3 TX into 148 sp3 RX) also fails in the pair even though each half passed 600 s in a mixed
pair. Both boards rolled back to the shipped sp2 pair at the end of the chain.

## 7. Root-cause class: the modem-to-DAC clock-domain crossing

The DUT runs entirely on `axi_adrv9001_adc_1_clk` (the ADRV9001 RX SSI clock). Its transmit
samples reach the ADI core on `axi_adrv9001_dac_1_clk` (the ADRV9001 TX reference clock) through
the MathWorks reference-design cell `sync_output/sync_fast_to_slow` (block design nets:
`TxRxCompo_ip_0/dut_data_out_*_tx -> sync_output/data_in_tx_* -> axi_adrv9001/dac_1_data_i0/q0`).
Both clocks are 8.000 ns, frequency-locked, with a phase relationship that is re-established at
every ADRV9001 profile load (every arm). The crossing is constrained only by
`set_max_delay -datapath_only 8.000` (`modem/cdc_exceptions.xdc`), i.e. no setup/hold check and
no synchroniser or FIFO: the dac-side registers sample a 32-bit bus whose per-bit datapath delays
spread over a window that the placement decides.

Measured on the routed checkpoints (`report_timing -from adc_1_clk -to dac_1_clk`, 37 paths each):

| build | crossing datapath delays, 12 longest |
|---|---|
| sp3 | 1.408 (into `i_tx1/core_enabled.dac_valid_int_re`), 0.912, 0.799, 0.749, 0.748, 0.742, 0.724, 0.713, 0.700, 0.694, 0.687, 0.677 ns |
| sp2A | 1.709, 1.318, 1.214, 1.170, 1.118, 1.045, 1.031, 0.989, 0.880, 0.879, 0.880, 0.908 ns |

When an arm's clock phase lands inside that spread, bits of the same sample are captured from
different cycles: data-dependent, bursty in-frame corruption on idle-clean links (CRC 40-88 %),
or total loss when the valid is mis-sampled (0 %, carrier-reset storm on the peer). That
matches every observation: per-arm, transmit-only on air, clean in the internal loopback (which
never crosses into the dac domain), image-dependent (placement), board-dependent (each chip's
adc/dac phase distribution), modulated but not fixed by the tx0 SSI row, and present at a low rate
on the shipped sp2 pair (the sentinel's reverse-leg CRC dips since 09-08). The sp3 intra-dac hold
paths (worst 0.010 ns with 0.249 ns clock skew into `tx1_data_q_A_d_reg[5]`, vs 0.021 ns in sp2A)
are the same placement luck seen from the other side.

## 8. What resolves it, and what was done today

* **Durable fix (build), IMPLEMENTED 2026-09-12 evening as `modem/instruments/txcdc/`** (see its
  README; results in section 9): replace the `sync_output` register crossing on the TX samples with a
  real asynchronous FIFO (e.g. `xpm_fifo_async`, 16 deep, {I,Q,valid}) written on `adc_1_clk` with
  the DUT valid and read on `dac_1_clk` by `dac_1_valid_i0`; the two clocks are the same frequency
  so a primed FIFO never runs dry. That is a `modem/complete_byte_bd.tcl` change, a Vivado rebuild
  (~2 h 15 on hdl-dev-2) and a silicon re-gate with repeated arms (>= 8 arms per leg, 600 s windows,
  the arm lottery makes single windows meaningless). Not done in this session.
* **Mitigation (ops, done):** `ops/profiles/tx_ssi.conf` + `ops/tx_ssi_row.sh` give 148 a
  per-image tx0 row (sp3: 4/3) through `bringup_r2r3.sh`; `SSI148`/`SSI146` env overrides; the
  148 rail's `GOLD=any`. These do not remove the lottery.
* **Rig:** both boards are back on the shipped sp2 pair (146 sp2B d94b4df391a1, 148 sp2A
  3e7f4232a3b5); the `two_jup` symlink the live sentinel depends on was restored (it vanished with
  the 13:09 checkout to master and had silenced the sentinel for an hour).

Capture directories: `ops/r3cap/sp3d_*`, `sp3d4_*`, `sp3d5_*`, `sp3d6_*`, `sp3d8_*`, `sp3d9_*`,
`sp3pair_*`. Vivado reports: hdl-dev-2 `/mnt/disk2/scratch/qpsk-builds/cdc/`.

## 9. The fix builds and their gates

### 9.1 sp3cdc v1 (FIFO, DUT still paced by the crossed DAC valid) -- image c43239d8dd96

Built from the sp3 kit with `pre_synth.tcl` (hook + `TXCDC_WIRE_OK` + `TXCDC_VALIDATE_OK` in the
build log), Gate 2 modem-clock WNS 1.451 ns (0 failing of 86,062), routed WNS 0.048 / WHS 0.010 ns.
`report_timing` adc_1_clk -> dac_1_clk: 35 of the 40 crossing paths now end inside the XPM
asynchronous FIFO (Gray-pointer protected). On silicon, both boards on v1, 148 at the default tx0
row 5/3 (chain 11):

| capture | result |
|---|---|
| 6 reverse arms x 180 s | all healthy: CRC 99.93-99.98 %, PER 0.026-0.088 % |
| 3 forward arms x 180 s | all healthy: CRC 100 %, PER 0.003-0.008 % |
| reverse 600 s | clean for 595 s (PER 0.017 %, 125/721,111), then a reset storm to the end |
| forward 600 s | clean for 604 s (PER 0.005 %, 34/733,561), then a short reset burst in the last 6 s |

Before the fix 4 of 6 arms at this row wedged within two minutes; after it 0 of 9 arms did, and the
two long windows both ran clean for ~600 s and then failed IN THE SAME WAY AT THE SAME AGE on both
boards. That is the FIFO draining: the modem was still paced by the DAC valid crossed back through
`sync_input` (the same unsafe structure), which loses a request now and then; each lost request costs
one FIFO entry, 8 entries in ~600 s (a 13 ppb rate deficit), and an empty FIFO with equal average rates
stutters on every request -- a permanent storm until the next arm.

### 9.2 sp3cdc v2 (FIFO paces the DUT; re-prime on underflow; depth 64)

`tx_cdc_fifo` v2 drives `TxRxCompo_ip_0/dut_data_valid_in_tx` itself (`dut_req`: one request per
two adc clocks, paused while the FIFO holds more than 48 of 64 entries), so the write rate follows the
read rate by construction; an empty FIFO drops `primed` and re-primes to 32 entries (one 32-sample
insertion, i.e. one RX resync, about once per 40 minutes at the v1 drift, instead of a permanent
storm). xsim testbench: equal clocks perfect at 32 phases; DAC 2.5 % fast re-primes with bounded slips;
DAC 2.5 % slow loses nothing.

### 9.3 sp3cdc v2 on silicon (image be8c5e30a342) -- the pacing does not govern the DUT

Gate 2 WNS 1.061 ns. Lottery gate 8 of 9 arms healthy (reverse PER 0.008-0.053 %, forward
0.002-0.004 %); the ninth (reverse arm 2) ran at CRC 95.85 %, PER 4.18 %, with a bad frame every
30 frames (25.6 ms period, no wedge). Reading the DUT wrapper (`TxRxCompo_ip.v`):
`dut_data_valid_in_tx` only feeds `host_txValid` (the host-sample input path); the modem's transmit
cadence is `enb = clk_enable` (adc clock / 2) and `dut_data_valid_out_tx` follows the input valid.
So a paused request does not slow the modem, it deletes a computed sample -- the FIFO cannot pace
this DUT, and the 25.6 ms comb in arm 2 is one deletion per drift sample at ~0.6 ppm. That the drift
differs per arm (v1: ~13 ppb on both boards; v2 arm 2: ~0.6 ppm; other arms: none measurable in
194 s) means the two clocks are not frequency-locked at the level a sample buffer needs, and it is
also the long-known reverse-leg "comb" (memory: lag-25, 20.4 ms). No buffer fixes a rate mismatch;
the modem and the DAC must share one clock.

### 9.4 sp3txclk (v3): axi_adrv9001 USE_RX_CLK_FOR_TX1 = 1 -- one clock

`modem/instruments/txclk/txclk_bd.tcl` sets the ADI core parameter (the TX1 PHY is then clocked from
the RX1 clock: `axi_adrv9001_if.v` `ext_tx1_clk = adc_1_clk`), removes the FIFO and restores the
reference-design nets; every modem-to-DAC path becomes a same-clock path Vivado times. ADI's
precondition (TX and RX at the same sample rate) holds for every profile on this rig. Kit files are
installed by `build_hdl.sh` step [6] (`SP3_SKIP_TXCLK=1` to leave them out). Build: gates
`TXCLK_PARAM_OK` / `TXCLK_WIRE_OK` / `TXCLK_VALIDATE_OK` / `PRE_SYNTH_HOOK_OK`, routed WNS 0.174 ns,
image md5 `cae8c4fdac09`.

On silicon (chain 11, both boards on v3, 148 at the default tx0 row 5/3, 2026-09-13 02:01-03:29):

| capture | result |
|---|---|
| 6 reverse arms x 180 s | all healthy: CRC 99.97-100.00 %, 0-87 resets, PER 0.001-0.061 % |
| 3 forward arms x 180 s | all healthy: CRC 99.99-100.00 %, 0 resets, PER 0.002-0.011 % |
| reverse 600 s | healthy, 608 s live, **PER 0.057 % (422/738,544)**, CRC 99.6 % over the whole log |
| forward 600 s | healthy, 604 s live, **PER 0.004 % (31/733,563)** |

**0 bad arms of 11 captures.** Commands: `ops/capture_r3.sh B|A -d 180|600 -k`, scored by
`ops/accept_analyze.py` (lost frames in the denominator). Both long windows show a reset burst in
their last ~6 s that is the capture's own teardown (t=609 s: identical in the chain-1 window whose
transmitter was 148 on sp2A) and is excluded from the live window by the scorer. Routed design:
no `axi_adrv9001_dac_1_clk` clock exists any more, zero adc->dac crossing paths, the ADI TX core's
data paths are ordinary timed paths (setup >= 5.4 ns, hold >= 0.059 ns); Gate 2 modem-clock WNS
1.392 ns (0 failing of 87,962). Both boards were rolled back to the shipped sp2 pair at the end.

## 10. Conclusion

The sp3 Gate 3 failure was never a fabric-logic defect of the model back-port. It was the
reference design's modem-to-DAC clock-domain crossing: an unsynchronised ring buffer between the
ADRV9001 RX clock (the modem) and the TX reference clock (the ADI DAC core) under a datapath-only
constraint, with a per-arm phase and a per-arm frequency offset between those clocks. The sp3
placement moved 148 into the bad region of that lottery; the same crossing is the origin of the
rig's long-standing reverse-leg comb on sp2. The fix is `modem/instruments/txclk`
(`axi_adrv9001 USE_RX_CLK_FOR_TX1 = 1`): one clock for modem and DAC, in every future kit via
`build_hdl.sh` step [6]. The gated image is `images/BOOT.BIN.jupiter.sp3txclk.cae8c4fdac0983f6010898a9dcb822e8 (rail names BOOT.BIN.{148,146}.sp3txclk.cae8c4fdac09)`
(built from the sp3 kit `c5ec53bc610c` plus the hook; the modem RTL is unchanged). Shipping it is
the operator's call; the sp2 pair remains deployed.

Also delivered on the way: `arm148_mode1.sh GOLD=any` (the sp3 image's 0x20C is not a digest),
per-image tx0 SSI rows (`ops/profiles/tx_ssi.conf`, `ops/tx_ssi_row.sh`, `SSI148`/`SSI146` env in
`bringup_r2r3.sh`; the row only modulated the lottery and the sp3 entry 4/3 is left as measured),
the `pre_synth.tcl` kit hook in the Vivado template, the txcdc FIFO attempt (kept, never shipped),
and the restored `two_jup` symlink the live sentinel depends on.

## 11. Follow-ups on 2026-09-13 (deploy, soak, sp2 back-port, Gate 1 rerun)

* **Deployed.** `sp3txclk` cae8c4fdac09 on 146 (07:46) and 148 (07:51) under the rails;
  `images/CURRENT.txt` roles A and B point at it; the pre-fix sp3 image is retired (PR #3, master
  f2ad372d). Sentinel on the deployed pair: 1245 f/s, CRC 100 % both legs.
* **Gate 1 rerun on the sp3 model tree (unchanged RTL; the hook is block-design only):** `run_gates.sh
  --legs model_matrix.legs --jobs 4`, two passes because the 09-12 cache of leg `m0_n_p000` on disk had
  been damaged with NUL blocks (5 files; purged and regenerated). Result **48 pass / 5 fail of 53**:
  the four documented exceptions (`G4_prearm`, `gateA_p000`, `gateA_m10`, `edge_m10`, GATE1_EQUIVALENCE.md
  section 3.2) plus `repro_p000`, whose byte-identity clause fails on the same constant sidx +1 as
  `G4_prearm` while its content twin `repro_p000_content` passes. The regenerated `m0_n_p000` outputs
  are bit-identical to the 09-12 run's, so the model tree is unchanged.
* **sp2 chain repair.** Every sp2 rebuild had been broken since 09-11: the kit scripts widened the Vivado
  build script's kit-name guard with literal `sed` patterns that stopped matching when the guard gained
  `|jupiter_byte_sp3*_build`. `modem/fixes/widen_kit_guard.sh` (guard-shape agnostic, tested against the
  live template) replaces both seds; the SEQ-BIST kit script resolves it through its real path because it
  is also reached via the `modem/fixes/seqbist_kit.sh` symlink.
* **sp2 back-port.** Fresh role A and B kits from the banked base tree (`apply_fixes.py --kit-tag
  sp2txclk`) with the txclk hook: `sp2Atxclk` 9d4f8d24fc9e (Gate 2 modem-clock WNS 0.278 ns) banked;
  role B build and the silicon gate of the pair follow (chain 13), after which sp3txclk is redeployed.

* **Soak on the deployed sp3txclk pair (chain 12, 600 s windows, sentinel between rounds):**

| round | reverse (148 TX -> 146 RX) | forward (146 TX -> 148 RX) |
|---|---|---|
| 1 (09:31) | PER 0.042 % (310/743,367), 32 resets | PER 0.004 % (27/733,005) |
| 2 (11:46) | PER 0.065 % (482/746,774), 0 resets | PER 0.009 % (67/733,585) |
| 3 (13:58) | **WEDGE at 35 s**: 100 % CRC for 34 s, then a carrier-reset storm (~1000/s), TX host feed intact | (round continues) |

  The round-3 storm was preceded by 50 minutes in which the sentinel read the reverse leg at idle at
  CRC 96.3-97.4 % (13:07-13:53) after 100 % all morning; on the shipped sp2 pair the same idle statistic
  reads below 99 % in 4-7 % of samples (09-10/09-11) versus 39 % (22/57) on the deployed pair today.
  So one failure class remains on the reverse leg after the clock fix: an idle-time degradation of
  148's transmit into 146 that can end in a receiver reset storm. It is not the crossing (that failed
  per arm, from the arm, with bursty in-frame errors) and it is rarer (1 wedge in 15 reverse captures
  since the fix vs 4 of 6 arms before). The next discriminator is 148's tx0 SSI delay row: with
  `USE_RX_CLK_FOR_TX1` the TX SSI clock is now derived from the RX clock, so the row characterised for
  the two-clock design (5/3) may sit off-centre. Chain 14 sweeps the rows (and the driver auto-tune)
  on the deployed image and confirms the best one for 600 s; the result goes into
  `ops/profiles/tx_ssi.conf` keyed by the sp3txclk md5.

* **sp2 back-port pair on silicon (chain 13; 146 `sp2Btxclk` e975e506e613, 148 `sp2Atxclk` 9d4f8d24fc9e,
  148's mode-1 digest unchanged at 0xBCF94856):** reverse arms 2-6 healthy (PER 0.031-0.070 %), forward
  arms 1-3 healthy (0.005-0.009 %), forward 600 s PER 0.014 % (101/740,877); reverse arm 1 wedged at 17 s
  (delivery flatline, no storm) and the reverse 600 s window wedged at 28 s (storm). 2 bad of 11.
  Both boards were then redeployed on sp3txclk.
* **tx0 row sweep on 148/sp3txclk (chain 14):** ran inside a degraded episode: auto-tune (5/4), 5/3,
  4/3, 6/3 and 5/2 all wedged or stormed in a row, then 5/4, 4/4, 3/4 and 6/4 were clean, and the 600 s
  confirmation at 5/4 wedged at 71 s. The rows do not separate anything; the arm/episode state does.
  The deployed row stays 5/3 (`ops/profiles/tx_ssi.conf` default; no entry for the sp3txclk md5).
* **Residual class, assessed.** After the clock fix one reverse-leg failure class remains on every
  single-clock pair: an episodic degradation of 148's transmit into 146 (idle CRC 96-97 % for tens of
  minutes) that under traffic ends in a receiver reset storm; forward is unaffected. The sentinel's
  hourly reverse CRC shows the same episodes on the shipped sp2 pair (09-11 12:00-13:00 at 82-91 %,
  09-11 23:00 at 83 %, 09-12 02:00 at 85 %), so it predates and is independent of the clock fix; it is
  the RF-marginal reverse leg (146's antenna, `[[forward-collapse-follows-the-band]]`) whose deep fades
  the receiver does not re-acquire from without a re-arm. In production the watchdog re-arms on a
  wedge; the durable remedy is the antenna replacement, after which the reverse leg should read like
  the forward one. Per-arm wedge rate since the fix on the reverse leg: 4 of 27 captures, all in the
  two degraded episodes (14:00 and 16:10-16:35), versus 4 of 6 arms before it.
* **Rig end state (16:58):** both boards on `sp3txclk` cae8c4fdac09, sentinel running.
