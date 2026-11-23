# 2-sps rung: double the data rate at the fixed 61.44 MSPS sample rate

Date: 2026-09-13. Status: design approved in conversation; execution started 2026-09-18 (plan revised for the dev/prod split and the no-symlink layout, two decisions added below).
Author: Travis Collins (design dialogue), written up by Claude.

## 1. Goal

Replace the deployed 4-samples-per-symbol rung with a 2-samples-per-symbol rung at the unchanged
61.44 MSPS ADRV9001 interface, so the symbol rate doubles from 15.36 to 30.72 Msym/s and the
delivered data rate doubles (about 15.3 to about 30.6 Mbit/s raw QPSK, rate-1/2 FEC). The frame
doubles in payload so the frame rate, and with it the host, DMA and ops cadence, stays at 1,245 f/s.

Decisions taken in the design dialogue (binding):

| decision | choice |
|---|---|
| rung type | replacement of sps 4, not a selectable rung; the sps-4 paths may be dropped |
| framing | B: double the frame (3,072-byte class payload) at the same 1,245 f/s |
| acceptance | A: both legs gated at today's targets (forward <= 0.01 %, reverse <= 1 % documented arm) |
| approach | 1: the 2-sps rung in the model with an in-model re-time; fallback 16-QAM at 4 sps |
| shipped chain (09-18) | B: develop and gate in `modem/dev`, re-derive `modem/prod`, prod Gate 1 must equal dev, the `sp4` image is built and flashed from prod |
| one-way images (09-18) | A: the banked TX-only/RX-only f1536 images and their overlay stay untouched; sps 4 / f1536 remains accepted so they stay rebuildable |

## 2. Rate structure

| | today (sps 4) | new (sps 2) |
|---|---|---|
| fabric clock | 122.88 MHz | 122.88 MHz |
| sample enable | clk/2 = 61.44 MSPS | clk/2 = 61.44 MSPS |
| symbol enable | clk/8 = 15.36 Msym/s | clk/4 = 30.72 Msym/s |
| cycles per symbol for symbol-rate DSP | 8 | 4 |
| frame | 13 + 12,320 = 12,333 slots, 0.803 ms | 26 + 24,608 = 24,634 slots, 0.802 ms |
| frame rate | 1,245 f/s | 1,247 f/s |
| delivered words per frame | 191 x 64 bit | 382 x 64 bit |
| TX air transfer per frame | 385 words (3,080 B) | 769 words (6,152 B) |

The f3072 row is derived by the contract generator (`contract/packet_f3072.m`, Task 1 of the plan); the
earlier 24,640 / 24,666 figures were rounded. Info 24,580 = 384 x 64 + 4, coded 49,168 = 3,073 x 16,
payload 49,216 = 769 x 64, samples per frame 49,268 at 2 sps.

Unchanged: the ADRV9001 profile (`lvds_61p44_fdd_jupiter`, 40 MHz primary signal bandwidth), the
SSI delay rows, the one-clock DAC path (`modem/instruments/txclk`, `USE_RX_CLK_FOR_TX1 = 1`), the
byte-plane DMA cadence, the sentinel and watchdog rate thresholds, `sro_sign` per board.

Blocks that move from 8 to 4 cycles per symbol: symbol synchroniser (interpolator, TED, loop
filter), carrier synchroniser and loop filter, rate handle and R4B/R4D pop steering, Viterbi
decoder (16 states, one ACS step per symbol), FEC framing, ByteSerializer. Blocks at sample rate,
unaffected in rate: RRC filters, preamble correlator, AGC, coarse frequency estimator, ByteRxFifo,
instruments.

### 2.1 Re-time plan

1. Set the rung: `QPSK_SPS=2`, `QPSK_FRAME=f3072`; the model's rail gate becomes
   `Rsym x 2 = 15.36e6` on the model bus. Regenerate. The model's own pre-synthesis gates (rung
   assertions, native look-back at the new sps, frame geometry, RRC parameters) report what no
   longer holds; fix those in the assemble/overlay layer, where the sps-4 rung was introduced.
2. Build once with the existing explore strategy; read Gate 2 (post-route intra-clock modem WNS,
   floor 0.005 ns) and the hold report. The symbol-rate loops and the Viterbi ACS are the expected
   first negative paths.
3. Pipeline in the model, not in the netlist: one overlay per failing block (the `modem/rxfix`
   overlay pattern), each with a Verilator equivalence check against the pre-overlay tree, so the
   fixes live in the model source and the kit flow (pre_synth hook, one-clock DAC) applies unchanged.
4. Stop rule: two pipeline rounds. If the modem clock does not close at 122.88 MHz after two
   rounds, the fallback is 16-QAM at 4 sps (a separate design), not a third round.

## 3. Pulse shaping and RF fit

Today: RRC rolloff 0.5, span 4 symbols at 4 sps (17 taps), occupied 23 MHz. At 30.72 Msym/s the
same pulse would occupy 46 MHz and exceed the profile's 40 MHz. New pulse: **rolloff 0.25, span 8
symbols at 2 sps (17 taps)**, occupied 38.4 MHz, 1.6 MHz inside the profile edge; TX and matched
filter cost unchanged. Parameters live in `modem/commhdlQPSKTxRxParameters.m` and are asserted by
the same pre-synthesis gate that pins `Rsym x sps`; coefficients quantised as today (16-bit).

Consequences carried by the design:

* Timing recovery: Gardner gain falls with the smaller excess bandwidth and 2 sps is its minimum;
  `ss_prop`/`ss_integ` (0x178/0x17C) defaults are re-derived for the new detector gain and symbol
  rate and re-verified on the 2-sps SRO stimulus bank.
* Carrier recovery: `cs_prop`/`cs_integ` scale with symbol rate; the deliberate LO offsets
  (+20 kHz forward, +40 kHz reverse) and the coarse frequency estimator's 4096-sample window keep
  their Hz meaning and need no change.
* TX: the outer 1.6 MHz sits on the profile's TX filter shoulder; TX EVM is checked in the mode-1
  loopback BIST before any air test.
* Link budget: doubling the symbol rate costs 3 dB. The reverse leg is 5 to 6 dB short today
  (146's antenna); the reverse-leg gate (section 6) has the antenna replacement as a prerequisite.

## 4. Frame geometry and byte plane (`f3072`)

Frame: 26 preamble slots (52 samples at 2 sps, the same correlator length and false-peak margin
as today) + 24,608 data symbols = 24,634 slots. Rate-1/2 K=5 code: 24,580 information bits
(24,576 usable + 4 zero pad) -> 49,168 coded + 48 filler = 49,216 payload bits = 6,152 bytes on
air; delivered as 382 words of 64 bits (3,056 bytes, 87-bit margin under the RxAlign bound); PAD target 382.

One constant in the frame contract (`contract/`, `f3072` beside `f1536`) drives all of:

* Model: frame-geometry parameters (slots, data symbols, preamble length and sequence),
  End_Generator counter (ufix15 for 24,634 slots; ufix14 no longer fits), ByteSerializer word count, PAD, BS census, RxAlign
  and FEC wrapper per-frame counters, frame-status word counter, the ROM message generator (the
  mode-1 BIST frame) and hence the BIST golden digests.
* Byte plane: ByteRxFifo from 4,096 to **8,192 words** (it would otherwise hold 10 frames instead
  of 21, halving the margin against the S2MM transfer-boundary overflow class); DMA transfer size
  382 words per frame.
* Host: frame size constants (payload, CRC position, 3,056-byte frame records), frame log record
  unchanged (48 bytes), `qpsk_tun -r 30720`, tun MTU 3,044 so a 1,400-byte ping
  no longer spans two frames; ARQ/NAK sequencing per frame unchanged.
* Ops: bring-up rung `r4` (profile unchanged, `KSYM=30720`, `FPS` 1,247), capture scorers
  and taxonomy key on the frame constant, sentinel thresholds unchanged, `qpsk_perf` traffic
  profile 30 Mbit in the capture rail.

## 5. Images and rails

One image for both boards, tag `sp4`, built by the sp3 kit flow (`build_hdl.sh` with the txclk
hook, `build_image.sh --tag sp4`). The 148 rail's mode-1 golden digest is re-measured on the new
BIST frame and pinned in `arm148_mode1.sh` (until then `GOLD=any`). `images/CURRENT.txt` moves
roles A and B to `sp4` only after the silicon gate; `sp3txclk` stays banked as the rollback.

## 6. Verification

* **Gate 0 (regen):** the model's pre-synthesis gates pass at sps 2 / `f3072`; the RTL diff
  against the sps-4 tree is banked as the change census.
* **Gate 1 (simulation):** no injected reference exists for this rung, so Gate 1 is a functional
  matrix on a new stimulus bank generated at 2 sps by the existing IQ harness (SRO 0 and
  +/-2.5 ppm, same seeds), scored by the existing scorers against a fresh `reference_loss.toml`
  taken from the first regen that meets the functional floors (no frame loss at 0 ppm; loss at
  +/-2.5 ppm not above the sps-4 rung's measured values), plus every fix's witness gate (W1, R4B/R4D,
  BS, PAD, F3) on the new bank. Verilator trees via `make_sro_trees.sh --from-regen`.
* **Gate 2 (timing):** post-route intra-clock modem WNS >= 0.005 ns, hold >= 0, zero adc-to-dac
  crossing paths, plus a `report_timing` row on the symbol-rate loop and Viterbi paths.
* **Mode-1 loopback:** the ROM BIST frame decodes with zero errors on 148 across 8 arms before any
  air test; its digest becomes the rail golden.
* **Gate 3 (silicon, choice A):** both boards on `sp4`; 6 reverse + 3 forward arms x 180 s all
  healthy (CRC >= 99 %, no wedge); 600 s per leg with lost frames in the denominator: forward
  <= 0.01 %, reverse <= 1 %; then a 3-round soak with the sentinel between rounds. The reverse-leg
  gate cannot be credited until 146's antenna is replaced.
* **Regression:** ops and modem pytest suites, host check binary, `tools/check_paths.sh`,
  `gen_regmap.py --check`, sphinx `-W`, as CI reproduces them.

## 7. Out of scope

16-QAM (the fallback, its own design if triggered), a wider ADRV9001 profile, the 51 GB parked
data, the antenna replacement itself (hardware), changes to the SP2 injected chain (retired with
the sps-4 rung).

## 8. Risks

| risk | mitigation |
|---|---|
| symbol-rate DSP does not close at 4 cycles/symbol | in-model pipelining overlays, two rounds, then the 16-QAM fallback |
| Gardner gain too low at rolloff 0.25 / 2 sps | loop constants re-derived and verified on the 2-sps SRO bank before silicon |
| reverse leg 3 dB shorter on a leg already 5-6 dB short | antenna replacement is a prerequisite of the reverse gate; forward gate proves the design |
| new ROM/BIST frame invalidates rail goldens | `GOLD=any` until the digest is measured, then pinned |
| host frame constants scattered | one contract constant, tests that grep for stale literals |
