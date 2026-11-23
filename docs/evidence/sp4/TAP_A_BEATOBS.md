# Tap-A ("pair.iq") has carried the beat-observer state vector, not IQ, since 2026-08-20

Chased 2026-09-23 after the sp4 Gate 3 run (`SILICON.md` section 6 item 4) found every capture's
`pair.iq` DEGENERATE. Desk work plus two 65k-sample reads on 148; no arm, no register write.

## 1. The symptom, and why the old label was wrong

`ops/capture_r3.sh` reads Tap-A with
`iio_readdev ... axi-adrv9002-rx-lpc voltage0_i voltage0_q` (the rx1 IIO DMA, 0x84A30000) and scores
it with `ops/check_capture_health.py`. Every banked capture since the sp2 silicon run (2026-09-10,
`SP2_SILICON.md`) -- and every one on 2026-09-16 and 2026-09-22 -- scored *occupied BW 2.4-5.8 MHz,
envelope autocorrelation 0.999 at lag 256/512*, which the scorer labelled the **#48 stale-DDR-replay
class, "REBOOT-ONLY"**. The label does not survive inspection:

* Two 65 536-sample reads on 148 two seconds apart (2026-09-23 00:1x) **differ**, and the rx1 DMA
  controller's interrupt count advances (10 IRQs for the two reads): the DMA is delivering fresh data.
* Every capture shares the same word structure: `Q` ≈ 5662/5919/5888 (near-constant), `I` a small set
  of structured integers repeating every 256 samples; the healthy Aug-12 reference
  (`two_jup_untracked_20260909/r3cap/singles_reread/pair.iq`) is zero-mean IQ with std ≈ 1750 on both rails.
* Several reboots on 2026-09-22 (dtb deploys, two flashes, the rollback) changed nothing.

## 2. What the tap carries

`modem/dev/simulink/beatila/beatobs_overlay.m` (BEATOBS build kit, commit `5d156154`, 2026-08-20):

> repurpose the debugI1/debugQ1 pair (composite outports -> rx DMA voltage0 ...) as a packed
> cycle-resolved internal-state vector for the 119.75 s beat hunt ... WHY debugI1/Q1: during
> BIST/digital-loopback beat captures the receiver input IQ they normally carry is redundant

`debugI1`/`debugQ1` are mapped by `hdlworkflow_loopback.m` to **'IP Data 0/1 OUT'**, which the ADI
reference design packs into the rx1 IIO channel `voltage0` -- exactly what Tap-A reads. The generated
RTL of the sp4 dev kit confirms it (`TxRxCompo_ip_src_TxRxComposite.v`: `assign debugI1 =
Receiver_beatobsI1_1; assign debugQ1 = Receiver_beatobsQ1_1;`, sourced from `TxRxCompo_ip_src_BeatObs.v`).
Packing (the overlay's header): `I[0]` demod dataOut, `I[1]` startOut, `I[2]` validOut, `I[4:3]` decision
pair, `I[6:5]` Rate-Handle counter phase, `I[15:8]` FIFO fill = push − pop (low 8), `Q[7:0]` push counter,
`Q[15:8]` pop counter.

Decoding the banked captures with that packing:

| capture | image / rung | fill == push−pop | RH phases used | demod valid duty | start pulses/s |
|---|---|---|---|---|---|
| `gate3_sp4_.../fwd600` | sp4 / r4 (2 sps) | 72.7 % | 2 | 0.999 | 1406 |
| `gate3_sp4_.../rev180_2` | sp4 / r4 | 74.2 % | 2 | 0.999 | 1172 |
| `gate3_sp3prod_20260916/fwd600` | sp3prod / r3 (4 sps) | 72.6 % | 4 | 0.499 | 1406 |
| `restore_205149` (2026-09-22 rollback) | sp3prod / r3 | 36.5 % | 4 | 0.500 | 1172 |
| Aug-12 reference (pre-BEATOBS image e49c011b) | -- | **0.4 %** | random | 0.501 | random |

The counter phases (2 at 2 sps, 4 at 4 sps), the valid duty (1/1 vs 1/2) and the fill/push/pop
consistency (chance level 1/256) leave no doubt. The 256-sample "replay period" is the 8-bit counters
wrapping; the "constant Q offset" is the push/pop counter pair. **Nothing is wrong with the DMA.**

## 3. Why it went unnoticed

* `modem/build_hdl.sh` exports `QPSK_BEATOBS=1` for every build ("the bank is LEAN + BEATFIX + BEATOBS +
  FRAMESTAT", 2026-09-11), so every image since the sp2 chain carries the observer, including the
  shipped sp3prod and the sp4 candidate; the Gate 1 bank and reference streams are pinned on that tree.
* `check_capture_health.py` was written 2026-08-24 against the #48 DMA fault it had just found; its two
  checks cannot tell a low-rate integer stream from a replayed buffer, and its REBOOT-ONLY advice was
  followed several times. `SINGLES_CAMPAIGN.md` already carried the tell: the only HEALTHY tap verdict
  after 08-20 was on the **pre-beat-overlay** rollback image e49c011b.
* The capture rail treats the verdict as non-fatal, so the runs kept their frames.bin value and the
  IQ side was quietly written off as "the tap wedge again".

## 4. What changed

* `ops/check_capture_health.py` detects the packing first (fill == push−pop consistency ≥ 30 %; IQ is
  < 1 %), prints `VERDICT: BEATOBS` with a one-line decode (phases → sps, valid duty, start pulses/s,
  fill range) and no longer calls it stale replay or advises a reboot. Rung-aware bandwidth window kept.
  Test: synthetic beatobs streams at sps 2 and 4 are named; synthetic RRC QPSK is not.
* `SILICON.md` item 4 corrected (it said the rx2 DMA was returning a stale buffer).

## 5. The fix (2026-09-24, operator: "drop QPSK_BEATOBS and rebuild sp4")

Dropping the overlay outright is not possible without rewriting the ddrcap2 injector
(`modem/instruments/ddrcap2/ddrcap2_inject.py` anchors on the Symbol Synchronizer beatobs ports --
the `.beatobsPop(...)` last-pin anchor in the FTS instantiation -- and reads `beatobsRhCtr/Push/Pop`
as its sel-15 channels). So `beatobs_overlay.m` gained a second mode: `QPSK_BEATOBS=1` (every build)
now builds the taps and the packer but **terminates the packer and leaves the composite debugI1/Q1 on
the receiver-input IQ**; the 2026-08-20 rewire is behind `QPSK_BEATOBS_TAP=1`, which `build_hdl.sh`
does not export. Everything the injectors and the Gate 1 wrappers anchor on is unchanged; the model
tree changes (a Terminator pair instead of two outports), so prod is re-derived and Gates 1-2 re-run
as `sp4b` (chain `regen_sp4r/chain_sp4b.sh`; the identity rows of Gate 1 against the unchanged dev bank
are the proof that the receiver streams did not move). Result: section 6.

## 6. sp4b rebuild result (2026-09-24, chain `regen_sp4r/chain_sp4b.sh`, units `sp4b-chain-094306` / `sp4b-chain2-130221`)

| step | result |
|---|---|
| derive prod (dev git `00bde48c`, f3072 / 2 sps) | `DERIVE_DONE`, model md5 `c0a25b6b7623`; structural diff vs the previous prod: blocks −8 +4, changed 26 (the observer's packer, DTCs and outports gone) |
| prod netlist gates | checkhdl errors 0 / warnings 2, `PI_GATE: PASS`, **S1B PASS rot 0 / 17** |
| tap assertion on the generated composite | `assign debugI1 = Receiver_debugI1_1; assign debugQ1 = Receiver_debugQ1_1;` -- the receiver-input tap, no observer |
| prod Simulink byte gate | runs A, C, D **PASS** |
| hdl stage, attempt 1 | `BASE_REGEN_INJECT_FAILED stage=ddrcap2`: HDL Coder pruned the terminated observer, so `Symbol_Synchronizer` no longer ends on `beatobsPop`; the ddrcap2 injector now dispatches on the shape (`fee03c30`, sel-15 channels zero) |
| hdl stage, attempt 2 | `BUILD_HDL_DONE`, `DDRCAP2_INJECT loose=7 zips_verified=2`, model tree `7b9bc484b8727b8e` |
| **Gate 1** (`build_image.sh --tag sp4b --tree prod --stop-after gates`, dev bank `sro_sim_f3072` unchanged) | **`GATE_LEGS model_matrix pass=53 fail=0`** in 26 min -- identity rows included: the receiver streams are sample-identical to the observer-bearing sp4 tree |
| **Gate 2** (hdl-dev-2, `IMPL_STRATEGY=explore`) | **WNS 0.928 ns** on `axi_adrv9001_adc_1_clk` (sp4: 0.794; floor 0.005), TNS 0, 0 failing of 96100; Carrier_Synchronizer worst slack 2.368 ns |
| image | `images/BOOT.BIN.jupiter.sp4b.bc9ac1e6b736ddb401701b652ef26bf3` (7203552 B), MD5SUMS row; **not deployed** |

So `sp4b` = sp4 with Tap-A back on receiver-input IQ and the beat observer gone from the netlist; the
ddrcap2 record keeps its layout (sel 15 reads zero). It supersedes `5108cdb77aeb` as the sp4 candidate
for the next Gate 3 (`gate3_pair.sh --tag sp4b --md5 bc9ac1e6b736`, `GATE3_NO_DTB=1`). No board touched.

## 7. Earlier note (superseded by sections 5-6)

The tap comes back as receiver-input IQ by building **without** `QPSK_BEATOBS` (one line in
`modem/build_hdl.sh`); the beat it was built for is closed (`beat-120s-status`: FIXED on both boards).
That is a model-tree change, so Gate 1 must be re-run and the bank identity rows re-pinned, and the
shipped r3 image keeps the observer until it is rebuilt. The right moment is the next sp4 build (after
the 146 antenna), when Gate 1-3 run anyway. Until then the Tap-A stream is usable as what it is: a
cycle-resolved Rate-Handle FIFO / demod-valid trace (the decode line above), not IQ.
