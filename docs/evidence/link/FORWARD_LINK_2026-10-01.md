# The forward link's 1 % is the 2.0 GHz carrier, not the image, not the receiver

Forward link = 146 transmitter → 148 receiver (plan: 146 TX 2000.000 MHz, 148 RX 2000.020 MHz; the
reverse link runs 148 TX 1850.000 → 146 RX 1850.040). 2026-10-01 07:00-10:30, both boards on
`sp3clamp004 8503f226395c` (`CARRIER_LOCK_LATCH_2026-09-29.md` §10-11). Every PER below is
`capture_r3.sh A -d 180 -k` + `accept_analyze.py` over the live window with lost frames in the
denominator; "det" is the fabric's own detection counter (`0x104`) in frames per second (nominal
61.44e6/49332 = 1245.4).

## 0. The question

On 09-29 the forward link read 0.019-0.022 % on six interleaved cells. From the evening of 09-29 it
reads ~1 % (undetected single frames, 0 carrier resets) on every image combination -- candidate pair,
shipped pair, shipped receiver with candidate transmitter (`CARRIER_LOCK_LATCH_2026-09-29.md` §10) --
so it is not the receiver's image. What is it?

## 1. Desk: what changed between 09-29 11:50 and 09-30 19:30

Across all forward captures (`frames.bin`, `reg_cfc` = 148's coarse carrier estimate, units ≈ 7.3 Hz):

| when | 148 cfc median | IQR | frame-to-frame \|Δ\| median | within-second sd | PER |
|---|---|---|---|---|---|
| 09-29 10:19-11:49 (8 captures) | −3456…−3494 | 38-167 | 102 | 126 | 0.019-0.048 % (one 0.159 %) |
| 09-30 20:17 → 10-01 01:11 (12 captures) | −4917…−5253 | 1,160-1,432 | 754-795 | 862-949 | 0.82-1.51 % |
| reverse link, same nights | −4760…−4810 | 61-100 | 40 | 50 | 0.002-0.010 % |

The forward estimate moved −1,500 units (≈ −11 kHz) and its **per-frame noise grew 7×**; the slow
wander stayed small (sd of per-second medians 11 → 101). Lost frames do not sit on estimate outliers
(|dev| at a lost frame ≈ |dev| overall). Levels did not change: 148 `rx_rssi` 29.8 → 30.3 dBFS,
`decimated_power` 29.5 → 30.0, gain 34 dB automatic; 146 27.6 → 28.0; TX gains 0 dB; LOs on plan;
148 61 °C, 146 57 °C. The reverse link is unchanged in every metric. A per-frame estimator noise jump
at constant level is an SNR or signal-quality change on the forward path.

## 2. Rig: the loss follows the carrier

`gate3_pair.sh` cells (`GATE3_CELLS`, no flash), 146 TX LO and 148 RX LO moved together, +20 kHz RX
offset kept, interleaved, 180 s each (`ops/r3cap/fwdcells_20261001_0826`):

| cell | forward carrier | PER | 148 cfc median / IQR / \|Δ\| | CRC-bad | rstCS |
|---|---|---|---|---|---|
| 1 | **2.000 GHz** (plan) | **2.366 % (5,021/212,258)** | −5513 / 1,517 / 827 | 2,230 | 0 |
| 2 | 2.100 GHz | **0.030 % (66/219,541)** | −3456 / 102 / 64 | 62 | 0 |
| 3 | 2.000 GHz | **2.264 % (4,822/212,969)** | −5521 / 1,504 / 831 | 2,169 | 0 |
| 4 | 2.100 GHz | **0.055 % (117/212,968)** | −3449 / 100 / 63 | 101 | 0 |
| 5 | 2.050 GHz | **17.868 % (38,051/212,962)** | −2999 / 2,144 / 656 | 14,175 | 0 |
| 6 | 2.000 GHz | 2.2 % (summary row) | −5503 / 1,490 / 843 | 2,071 | 0 |

At 2.1 GHz the link is exactly its 09-29 self: estimate −3456, IQR 100, PER 0.03-0.055 %. At 2.0 GHz
the estimate is pulled −2,000 units with 8× the dither; at 2.05 GHz it is pulled the other way with
20× the dither and 18 % loss. Duplex spacing to 148's own transmitter is 150 / 200 / 250 MHz at 2.00 /
2.05 / 2.10 GHz -- the loss is not monotonic in spacing, so it is not self-leakage.

Where the frames go, from the same captures (`0x104` vs records vs sequence):

| cell | sent (records + seq-lost)/s | 148 fabric det/s | undetected/s | CRC-bad/s |
|---|---|---|---|---|
| 2.0 GHz | 1246.5 | **1228.4** | 18.1 | 12.0 |
| 2.1 GHz | 1246.4 | 1245.4 | 1.1 | 0.3 |
| 2.05 GHz | 1225.2 | 1097.3 | 127.8 | 74.8 |

Every detected frame is delivered; the loss is frames 148 never detects plus a smaller CRC-bad share.

## 3. Rig: what it is not

`plan_cells.sh` on the forward receiver, 4 × 240 s interleaved cells, idle link, scored on 148's
detection rate from 1 Hz `0x104` polls (`ops/r3cap/fwdmute_20261001_0828`):

| experiment | cells (148 det f/s, 60 s → end) | 148 cfc sd |
|---|---|---|
| 148's own TX live / MUTED / live / MUTED (self-desense) | 1246.03 / 1246.39 / 1246.10 / 1246.30 | 816-916 throughout |
| 146 TX power 0 / −6 / 0 / −6 dB | 1246.08 / 1246.20 / 1246.28 / 1246.47 | 814-916 throughout |

Neither knob moves anything: not self-desense, not transmit level. Two further facts from the same
cells: the estimate dither (sd ~850) is present at 2.0 GHz **without traffic**, and the detection rate is
**full** without traffic -- the impairment costs frames only once payload traffic flows (§2's cells
carry saturating traffic; the plan_cells link is idle).

Receive-noise-floor scan (`ops/r3cap/fwdnoise_20261001_0915`): 146's transmitter muted (−40 dB), 148's RX
LO stepped 1.90 → 2.20 GHz in 10 MHz steps, three `rssi` / `decimated_power` readings each (dBFS, larger
= weaker):

| 148 RX LO | rssi dBFS | decimated power dBFS | reading |
|---|---|---|---|
| 1.90-1.95 GHz | 31-48 | 13.5-31 | 148's own 1.85 GHz transmitter skirt (50-100 MHz away) |
| 1.96-1.99 GHz | 53-57 | 39-55 | skirt tailing into the floor |
| 2.00-2.05 GHz | 55-62 | 54-59 | floor |
| 2.06-2.20 GHz | 53-62 | 50-59 | floor |

No bump at 2.00-2.05 GHz within the ±3 dB spread of the floor. An interferer strong enough to show here
is excluded; a weak or narrow one is not, but the scan does not support "external interference".

## 4. Conclusion

The forward link's loss since 09-29 evening is a **carrier-specific impairment at 2.00-2.05 GHz on
the forward path**: 148's coarse estimate is biased (−15 kHz at 2.0, the other way at 2.05) and 7-20×
noisier there, the link loses 1.5-2.4 % (2.0) to 18 % (2.05) of frames under traffic, and at 2.1 GHz
every number returns to the 09-29 baseline. It is independent of the receiver's image, of 148's own
transmitter and of transmit level; the muted-receiver scan shows no interferer. The remaining
candidate is **146's transmitter at that band** (a carrier-specific LO offset of −15 kHz appearing on
09-29 points at the TX PLL/calibration) -- it cannot be separated from a weak external source without a
spectrum capture or swapping the transmitting board, neither of which this study did.

**Proposed fix (operator's call): move the forward carrier to 2.1 GHz**, the way the reverse went to
1.85 on 09-29: `ops/rung_table.sh` r2/r3 `_LOA=2100020000` (148 RX) and `_LOBT=2100000000` (146 TX),
then `ops/gate3_pair.sh` on the new plan (traffic Gate 3) and a `soak_pair.sh` run; duplex spacing
becomes 250 MHz on both boards (more than today's 150). Until then the forward link stays at ~1-2 %.

Rig left as found: both boards on `8503f226395c`, plan 2.0/1.85, watchdogs up, trigger
`degtrig-pair-20261001d` armed, lock clear.

## 5. Silicon: the 2.1 GHz plan as the default (`ops/rung_table.sh` r2/r3, PR #90)

Traffic Gate 3 on the new table (`gate3_pair.sh`, no flash, KEEP; `ops/r3cap/fwd2100_20261001_1110`),
2026-10-01 11:10-12:52, both boards `8503f226395c`, 0 bad arms of 11:

| leg | PER (live window, lost in denominator) |
|---|---|
| rev180 ×6 | 0.009 / 0.002 / 0.002 / 0.001 / 0.004 / 0.005 % (21/223,513 · 4/217,114 · 4/217,018 · 3/223,689 · 9/222,932 · 10/217,190) |
| rev600 | **0.007 % (52/747,631)** |
| fwd180 ×3 | **0.049 / 0.042 / 0.039 %** (104/213,416 · 91/219,196 · 83/212,969) |
| fwd600 | **0.048 % (355/736,447)** |

Formal verdict FAIL (forward limit 0.01 %), as every forward 600 s leg on this rig has read except the
single 0.009 % leg of 09-16 -- but against the same plan at 2.0 GHz the day before (fwd600 0.933 %,
6,873/736,614) this is a **20× improvement**, and the receiver statistics are the 09-29 baseline again:

| | 2.0 GHz, 09-30 fwd600 | **2.1 GHz, 10-01 fwd600** | 09-29 baseline (2.0 GHz, before the condition) |
|---|---|---|---|
| 148 coarse estimate median | −4919 | **−3437** | −3480 |
| IQR | 1,272 | **120** | ~170 |
| frame-to-frame \|Δ\| median | 754 | **77** | 102 |
| fabric detections/s vs sent | 1228.4 of 1246.5 | **1245.3 of 1245.4** | full |
| carrier resets | 0 | 0 | 0 |
| CRC-bad/s · missing/s | 1.7 · 9.6 | **0.47 · 0.07** | |

What is left of the forward loss is a CRC-error class (0.47/s bad frames, runs of 1-4, essentially no
missing frames) -- the pre-existing plan-independent 0.02-0.05 % item of `GATE3_REVERSE_PLAN_2026-09-29.md`,
a separate study. The 4 h soak on the 2.1/1.85 plan started 12:52 (`fwd2100_20261001_1110/soak/status.txt`);
its verdict: **PASS** (12:52 → 16:53, 4.03 h, 25 ticks) --

| board | 5 s windows | locked | locked with resets | fabric resets (locked) | NOT-LOCKED | storms | FULL RE-ARMs | daemon/wedge |
|---|---|---|---|---|---|---|---|---|
| 146 | 2186 | 2186 | 0 | 0 | 0 | 0 | 0 | 0 |
| 148 | 2192 | 2192 | 0 | 0 | 0 | 0 | 0 | 0 |

Sentinel 48 samples, 0 zero-rate, 0 recoveries. **12 h soak, same plan** (`ops/r3cap/evening_20261001_1652/soak12/status.txt`, 2026-10-01 18:09 → 10-02 06:12, 12.06 h,
73 ticks): 146 **6,545** windows, 148 **6,503** windows -- 0 fabric resets in locked windows, 0 NOT-LOCKED, 0 storms,
0 re-arms, 0 daemon/wedge on both; sentinel 143 samples, 0 zero-rate, 0 recoveries → **PASS**. Three consecutive
clean soaks on `8503f226395c` (the
2.0/1.85 plan overnight, the 2.1/1.85 plan today) with every counter at zero.

## 6. Who owns the 2.0 GHz impairment: the reverse link at 2.0 GHz is clean

Interleaved 180 s cells (`gate3_pair.sh`, no flash, `ops/r3cap/evening_20261001_1654/cells7`), 17:21-18:09: the
reverse link (148 TX → 146 RX) moved to 2.0 GHz vs its 1.85 plan, with a forward 2.0 GHz cell as the same-time
reference. Both boards `8503f226395c`.

| cell | link / carrier | PER | RX cfc median / IQR / \|Δ\| | det/s vs sent/s | CRC-bad/s |
|---|---|---|---|---|---|
| 1 | reverse @ **2.000** (148 TX → 146 RX) | **0.005 % (11/222,523)** | −4740 / 98 / 59 | 1245.4 / 1245.9 | 0.05 |
| 2 | reverse @ 1.850 (plan) | 0.002 % (5/221,686) | −4764 / 70 / 43 | 1245.4 / 1245.4 | 0.01 |
| 3 | reverse @ **2.000** | **0.005 % (10/222,160)** | −4735 / 100 / 60 | 1245.4 / 1245.5 | 0.03 |
| 4 | forward @ **2.000** (146 TX → 148 RX) | **2.109 % (4,538/215,196)** | −5582 / 1,475 / 822 | **1228.4** / 1249.2 | 8.84 |
| 5 | reverse @ 1.850 | 0.009 % (21/223,507) | −4778 / 72 / 44 | 1245.4 / 1245.4 | 0.07 |
| 6 | reverse @ **2.000** | **0.004 % (9/237,299)** | −4761 / 94 / 59 | 1245.4 / 1245.5 | 0.03 |

The 2.0 GHz band is fine when 148 transmits and 146 receives on it -- estimate IQR ~100, every sent frame detected,
PER at the plan's level -- while at the same hour the forward direction on the same carrier loses 2.1 % with the
IQR 1,475 signature. So it is not the band or the environment: **the impairment lives in the 146-transmit → 148-receive
chain at 2.00-2.05 GHz** (146's TX or 148's RX at that carrier; a two-board pair cannot split those further without
a spectrum capture or an external reference). With the plan at 2.1 GHz it is out of the way; it stays on the list.

## 7. The residual forward CRC class on the 2.1 GHz plan (desk)

From the 2.1 GHz Gate 3 legs (§5): forward CRC-bad frames 0.40-0.51 per second (reverse 0.058), runs of 1-2 (112
singles, 54 pairs, 15 triples of 184 runs in fwd600), inter-event median 1.1-1.5 s, **flat against the 1.57 s tick
and the 0.611 s period**, not on carrier-estimate excursions (|cfc − median| at a bad frame 15 vs 0 overall), ~70 %
with first-120-bit damage (`0x108`), 0 carrier resets. The forward receiver's estimator noise (frame-to-frame |Δ|
77 vs 46 on the reverse) puts its SNR **~4.5 dB below** the reverse link's at the same gain and ~2 dB weaker rssi
-- the pattern of a noise-limited link, i.e. 148's receive side (the antenna identified on 09-08 is on this leg).
**Hardware test (2026-10-02 08:14-09:03, `ops/r3cap/fwdtxpower2_20261002_0814`): the slope is steep -- noise-limited.**
Interleaved 180 s forward legs on the 2.1 plan, 146 transmit gain written AFTER the arm through `capture_r3.sh`'s
`PEER_ATTR_POKE` (witness `before='0.000000 dB' want='-3' write=ok after='-3.000000 dB'` in every leg; a first
attempt that set the gain before the capture was void -- the arm resets `out_voltage0_hardwaregain` to 0 dB):

| 146 TX gain | leg 1 PER | leg 2 PER | CRC-bad/s | undetected/s | 148 cfc \|Δ\| / IQR |
|---|---|---|---|---|---|
| 0 dB | 0.048 % (105/217,047) | 0.055 % (120/217,179) | 0.51 / 0.56 | 0.03 / 0.03 | 110-132 / 175-211 |
| −3 dB | 0.067 % (145/217,299) | 0.075 % (163/217,311) | 0.68 / 0.77 | 0.04 / 0.03 | 132-133 / 207-208 |
| −6 dB | **0.284 % (617/217,314)** | **0.295 % (641/217,077)** | 2.92 / 2.97 | 0.73 / 0.18 | 137-140 / 213-220 |

PER ×1.4 at −3 dB and ×5.5 at −6 dB, still dominated by CRC-bad singles/pairs with detection intact until −6 dB. A
loss that multiplies five-fold for 6 dB less signal is thermal-noise-limited decoding, not a modem defect: the forward
link sits a few dB above its CRC cliff. The remedy is link budget on the 146 → 148 path (148's receive antenna --
the element the 09-08 swap identified as bad is on this leg -- or TX/RX gain), not firmware; with it the forward
leg's 0.04 % would follow the reverse leg's 0.005 %. This closes the "plan-independent 0.02-0.05 %" item as explained.

## 8. The impairment is in the signal 148 receives: IQ replay through the receiver model

Every `capture_r3.sh` leg also records a 4 M-sample Tap-A window of the receiver's input I/Q (`pair.iq`, int16 at
61.44 MS/s; on sp3clamp004 Tap-A carries the receiver input). Replaying those windows through the Verilator
receiver model (the regenerated f1536 tree with the 0.004 clamp and the SS/CFC taps, `clamp004/obj_nolatch_f1536`,
`Vwrap_byte_sro_model rx <pair.iq> 4000000 8400 <out> 2 0`; ~81 frames each, `qpsk-build-trees/iq_replay/`):

| capture (10-01) | model syncs | coarse estimate median | frame-to-frame \|Δ\| (model) | live \|Δ\| | SS integrator | strobes |
|---|---|---|---|---|---|---|
| forward 2.0 GHz, 148 RX (cell 1) | 78/78 | −5159 | **704** | 827 | 4045 [3996, 4092] | 12,333 |
| forward 2.05 GHz, 148 RX (cell 5) | 78/78 | −2510 | **693** | 656 | 4032 [3977, 4089] | 12,333 |
| forward 2.1 GHz, 148 RX (cell 2) | 78/78 | −3440 | **76** | 63 | 4029 [3966, 4087] | 12,333 |
| reverse 2.0 GHz, 146 RX (cells7 cell 1) | 78/78 | −4779 | **100** | 59 | 4091 [3830, 4164] | 12,333 |

The model reproduces the live estimator noise from the recorded samples alone -- 9× at 2.0/2.05 GHz, baseline at
2.1 and on the reverse link at 2.0 -- with the timing loop healthy in every case (integrator ~4040, nowhere near
the ±33,554 rail, 12,333 strobes). So the impairment is **in the analog signal that reaches 148's ADC on the
2.00-2.05 GHz forward carrier**, not in the digital receiver, the steering or the host. The Welch spectra of the
same windows show no interferer: at 2.0 GHz the in-band level is 2 dB lower and the out-of-band floor the same as
at 2.1 (SNR proxy 30.6 vs 32.3 dB), with the same weak (12-14 dB) spurs either way. A carrier estimate that
dithers ±5 kHz frame to frame at an unchanged level is **carrier-frequency jitter** -- an LO/PLL on one of the
two radios that make the forward link at that carrier: 146's TX LO or 148's RX LO at 2.00-2.05 GHz (the reverse
link at 2.0 GHz exonerates 148's TX LO and 146's RX LO there). A two-board pair cannot split these two; the
separating test is a cabled single-radio RF loopback on 148 at 2.0 GHz (`ops/rf_loopback.sh 10.0.0.148 2000`,
Tx1 → attenuator → Rx1; the board's own TX LO is known clean at 2.0 from the reverse cells, so a dirty loopback
names 148's RX PLL and a clean one names 146's TX PLL) -- it needs a cable and an attenuator on the bench.

**Receive gain has no headroom** (10-02, `ops/r3cap/fwdrxgain_20261002_1031`): pinning 148's RX gain to 36 dB in
`spi` mode reads back **34.000000 dB** (`ATTR_POKE … want='36' write=ok after='34.000000 dB'`) -- 34 dB is the top of
the gain table on this profile, and the automatic AGC has sat there in every capture this week; the pinned leg read
0.067 % (142/212,969) vs 0.055 % (117/212,969) automatic. The forward link budget can only be improved outside
the radios (antenna, path), as §7 says.

## 9. 2026-10-02: the impaired carrier MOVED, and the received spectrum says why -- a frequency-selective fade

After the morning's r4 excursion the forward link at the 2.1 plan read 148 528-676 f/s at CRC 42-66 %, estimate
−12310, rssi 34.4 dBFS (4 dB weaker than the morning), 0 steering faults. Interleaved diagnostic cells
(`ops/r3cap/fwddiag_20261002_1604`, 16:05-16:52, `capture_r3.sh -k` 180 s, lost in denominator):

| cell | link / carrier | PER | 148 cfc med / IQR / \|Δ\| | det/s of sent/s |
|---|---|---|---|---|
| 1 | forward **2.100** (plan) | **46.581 % (99,204/212,972)** | −11817 / 4,034 / — | 1073 of 1217 |
| 2 | forward 2.150 | 0.428 % (911/212,969) | −3334 / 433 / 222 | 1243.5 of 1244.9 |
| 3 | reverse @ 2.100 | **WEDGED** (146 could not arm) | | |
| 4 | forward **2.000** | **0.024 % (52/219,196)** | −3427 / 100 / 65 | 1245.4 of 1245.6 |
| 5 | forward 2.150 | 0.406 % (867/213,428) | −3340 / 427 / 218 | 1243.7 of 1245.0 |
| 6 | forward 2.100 | WEDGED | | |

Yesterday 2.0 GHz lost 2.4 % and 2.1 GHz was the baseline; today 2.0 GHz **is** the baseline and 2.1 GHz is
unusable, and the reverse link at 2.1 GHz wedges too. A single radio's PLL does not do that. The receiver-input
spectra do -- fitting a straight line to the in-band PSD (±8 MHz) of every sp3clamp004 capture (the 09-28/29
`pair.iq` files are BEATOBS state, not IQ, and are excluded):

| capture | PER | in-band **tilt** (dB across 16 MHz) | deepest 1 MHz dip (dB) |
|---|---|---|---|
| 10-02 fwd 2.10 (cell 1) | 46.6 % | **−14.6** | **−10.0** |
| 10-01 fwd 2.00 (cell 1) | 2.4 % | **−10.5** | **−8.2** |
| 10-01 fwd 2.05 (cell 5) | 17.9 % | −6.8 (plus ripple) | −3.9 |
| 10-01 fwd 2.10 (cell 2 / fwd600) | 0.03 / 0.05 % | −4.3 / −4.7 | −5.7 |
| 10-02 fwd 2.00 (cell 4) | 0.02 % | −2.5 | −3.7 |
| 10-02 fwd 2.15 (cells 2/5) | 0.4 % | −1.2 / 0.0 | −1.7 / −2.0 |
| 10-01 reverse 2.00 / 1.85, 09-30 rev600 | 0.002-0.006 % | −1.5 / +3.6 / +4.4 | −3.6 / −5.0 / −5.4 |

The loss follows the **slope of the channel across the signal's own bandwidth**: a tilt beyond ~8-10 dB across
the 15.36 Msym/s band (one side of the spectrum 5-10 dB down) breaks the receiver -- the power-4 coarse estimator
is biased by the asymmetric spectrum (the −15 kHz / −90 kHz "LO shifts" of the two bad days were that bias) and
noisy, the preamble correlator misses, CRCs fail -- and the modem has **no equaliser** to flatten it. Difference
spectra between the bad and the clean day at the same LO (same signal, so only the channel differs) show the same
picture at both carriers: the lower half of the band +2…+5 dB and the upper half −4…−5 dB.

A frequency-selective slope that is **different for the two directions** (different antennas and positions),
**drifts by ~100 MHz from one day to the next** (something in the room moving: a notch spacing of ~100 MHz is a
~3 m path difference) and **does not show with the transmitter muted** is a **multipath fade on the forward air
path**. It also re-reads the earlier findings: the 1.9 GHz "notch" on the reverse path (09-28), the 09-30 forward
detection dip, the "LO offset wander" readings -- one physical cause.

What follows from it:
* **Nothing in the radios or the modem fabric is broken.** The receiver's weakness is that it has no equaliser
  and its coarse carrier estimate assumes a symmetric spectrum; that is a design limit, not a defect introduced
  this week (the clamp fix stands: 0 latches, 0 re-arms across all of this).
* **Carrier choice is a moving target** on this bench; a fixed default will be in a fade some days. The cheap
  mitigations, in order: move/reposition the forward-path antennas (the bench step already pending), a bring-up
  probe that measures the in-band tilt (or just PER) on two or three candidate carriers and picks the flattest, and
  for a permanent fix an equaliser in the receiver model (plan item) or the r2 rung (half the bandwidth sees half
  the slope).
* For tonight the forward default stays 2.1 GHz in `rung_table.sh`; today it reads 46 % there and 0.02 % at 2.0.

## 10. 2026-10-02 17:15: the antennas were moved -- the spectrum is flat, and a NEW loss class appears (periodic waves)

The operator repositioned the antennas at 17:15. Chain `ops/r3cap/postmove_20261002_1715` (same image
sp3clamp004 on both boards, `capture_r3.sh -k` 180 s cells, lost frames in the denominator), then the r2 hedge,
then back to r3:

| cell | link / carrier | PER | in-band tilt (dB / 16 MHz) | dip | 148 cfc IQR | resets |
|---|---|---|---|---|---|---|
| 1 | forward 2.100 (plan) | **2.245 % (4,776/212,745)** | **−0.1** | −3.9 | 33 | 0 |
| 2 | forward 2.000 | 1.244 % (2,665/214,153) | +5.6 | −5.5 | — | 0 |
| 3 | forward 2.150 | 2.480 % (5,308/213,996) | +4.1 | −4.1 | — | 0 |
| 4 | reverse 1.850 | **WEDGED** (146 detects frames, CRC garbage) | | | | |
| 5 | forward 2.100 | 1.777 % (3,802/213,980) | −0.4 | −4.1 | 33 | 0 |

The move did what §9 predicted for the channel: the 2.1 GHz spectrum went from −14.6 dB to **−0.1 dB** across the
band and the signal at 148 is ~8 dB stronger (rssi 22.4 dBFS vs 30.4 before; AGC still parked at its 34 dB
ceiling). The 46 % multipath class is gone. But the forward link did **not** return to its 0.02 % baseline: it
lost 1.2-2.5 % at **every** carrier, with a flat spectrum, a tight carrier estimate and zero resets -- and the
reverse link, clean at 1.85 GHz for three days, is now in acquisition collapse (146's watchdog FULL RE-ARMs every
26-30 s: `drstcs` ≈ 700 per 5 s window with `dpkts` ≈ 6200, i.e. frames detected, carrier step-detector storming).

**The new class is periodic WAVES, not a comb.** Per-second bad-frame counts over each 180-240 s leg:

```
observe (240 s, 2.1 GHz): 0 4 2 3 2 50 101 87 86 88 101 96 91 80 87 75 64 70 63 57 46 31 31 25 15 8 4 9 5 8 2 2 6 0 3 3 0 2 0 0 ... 0 0 9 84 89 83 98 93 92 94 83 82 85 76 68 59 56 53 32 26 20 20 12 12 8 5 0 6 1 2 ...
```

A burst rises within 1-2 s to a crest of 90-107 bad frames/s (8 % of the 1245 f/s), holds ~15 s, decays over
~20 s, and the pattern repeats with a period of **70-85 s** (observe leg onsets at 148 uptime 11546 / 11627 /
11707; gain-24 leg 18:53:24 / 18:54:35 / 18:55:44; cell 1 autocorrelation r = 0.97 at 74 s, cell 5 r = 0.99 at
84 s, cell 3 106 s, cell 2 ~130 s). Inside a wave the bad frames are spaced 33 / 25 frames apart (`lag33`
0.135-0.165 -- the SRO deletion cadence); outside a wave the same deletions are harmless. During a crest
0x104 still detects 1216 f/s (1244 clean), the cfc spread is unchanged (sd 31 vs 24 units), rstcs stays 0, and
**80 % of the bad frames carry 0x108 frame-start bit errors** (median 435-586 per host frame) -- the demodulator is
producing garbage symbols for the first part of the frame, not losing acquisition and not losing delivery.

What it is **not** (each measured on the live pair, same leg structure, `ops/r3cap/fwdwave_20261002_1815`):

| test | result |
|---|---|
| RF level / spectrum through a wave: 2 s sampler on 148 (rssi, decimated power, gain) + 4.3 ms IQ every 10 s | through a 101 bad/s crest: rssi 22.39, decpow 22.25 dBFS, gain 34, tilt −0.3 dB, dip −3.9 -- **identical to the clean seconds** (corr(bad/s, rssi) = −0.05) |
| ADC overdrive / AGC: RX gain pinned 24 dB (spi), 10 dB less than the AGC ceiling | **1.445 % (3,507/242,711)**, lag33 0.165, waves every 69-71 s -- unchanged |
| symbol-timing clamp (sim, regenerated f1536 tree): integrator vs amplitude 0.25-4× and vs bank SRO −40…+10 ppm | integrator 3667-4096 En23 (≤ 0.0005 of the ±0.004 clamp), 32/32 syncs everywhere -- the clamp is not binding and amplitude does not move the loop |
| 146 transmit gaps (`txgap` > 200 µs) | 90 / 182 in cells 1-2 but 1 / 3 in cells 3 / 5, which have the same waves -- not the cause |
| host delivery stalls (4-5 s "delivery stalled" lines every ~25 s) | present identically on the 09-29 0.02 % cells -- pre-existing rail artefact |
| 146 watchdog re-arm cadence (27 s) vs wave period (70-85 s) | not 1:1 |
| 146 watchdog **stopped** for a forward leg (no FULL RE-ARMs, so no 0x000 restarts of 146's transmitter) | **1.081 % (2,583/238,856)**, lag33 0.110 -- the waves do not come from 146's re-arms |

The link's **noise margin** came out of the same experiment: with the RX gain pinned 14 dB (20 dB below the AGC
ceiling, signal ≈ 42 dBFS) the leg lost **72.205 % (173,243/239,933)** -- the forward link at 2.1 GHz after the
move has between 10 and 20 dB of margin, so a −10 dB in-band slope (§9, §11) is a large fraction of it.

## 11. Desk: how much in-band tilt the receiver tolerates (sim, `PERT_TILT_DB`)

`modem/rtl_sim/sim_sro_perturb.cpp` gained `PERT_TILT_DB=t`: a frequency-selective channel modelled as K cascaded
one-tap filters `y = x + a·j·x[n−1]` (|H(f)|² = 1 + a² + 2a·sin(2πf/FS), an antisymmetric slope; t is the dB
difference between +8 and −8 MHz, negative = upper half down as on the rig; one stage spans ~8 dB, |t| > 7 uses
two, > 14 three). Run on the regenerated f1536 tree (sp3clamp004: IntegClamp 0.004, SS taps) with the noise-free
bank stimulus `n_p000.iq`, 120 frames per point, scored on frames 8-119
(`/mnt/onetb/scratch/qpsk-build-trees/tilt_f1536/run_tilt.sh`):

| tilt (dB / 16 MHz) | frame syncs | coarse-estimate bias (cfc median, units) | estimate noise (median \|Δcfc\|) | preamble corr. peak |
|---|---|---|---|---|
| 0 | 112/112 | −10 | 2 | 6.74e7 |
| −4 | 112/112 | −14 | 93 | 6.64e7 |
| −6 | 112/112 | −23 | 173 | 6.62e7 |
| −8 | 112/112 | −472 | 418 | 6.37e7 |
| −10 | 112/112 | −1,141 | 670 | 6.26e7 |
| +10 | 112/112 | +1,331 | 684 | 6.28e7 |
| −12 | 112/112 | −2,401 | 927 | 6.17e7 |
| −14 | 111/112 | −3,781 | 1,009 | 6.06e7 |
| −16 | **106/112** | **−11,321** | 1,769 | 5.70e7 |

(The `biterr` column is constant 6092 at every point -- the BIST reference is not this stimulus -- so the
tolerance is read from syncs and the estimator.) Two things line up with the rig:

* **The coarse-estimate bias is the "LO shift".** At −16 dB the model's estimate sits at −11,321 units with no
  frequency offset at all; the live 46 % day at −14.6 dB read −11,817 / −12,310 (§9). The −90 kHz "148 residual"
  of 16:00 was the asymmetric spectrum biasing the power-4 estimator, exactly as §9 argued.
* **The noise-free model is more tolerant than the air by ~4 dB.** Syncs hold to −12 dB in the model and start
  failing at −14/−16; on the air −10.5 dB cost 2.4 % and −14.6 dB cost 46 %, because the real signal also carries
  noise (10-20 dB margin, §10) and the tilted spectrum costs SNR on the attenuated half as well as estimator bias.

**Design budget for the equaliser note:** keep the in-band slope seen by the demodulator under ~6 dB (estimator
noise < 200 units, bias < 30 units -- the clean-air regime of §9's table) from channels of up to ±16 dB; a 3-5 tap
fractionally spaced linear equaliser (or a one-tap-per-stage inverse of this very model, which is what the sim's
`PERT_TILT_DB` makes testable) is sized by that. The r2 rung sees half the slope for the same channel.

What it **is** -- the A/B that settled it (`fwdwave_20261002_1815/mute148tx`, forward leg 200 s on the live pair,
`RX_ATTR_POKE="out_voltage0_hardwaregain=-40"` on 148, i.e. **148's own transmitter muted**, nothing else changed):

| forward leg | 148 TX | PER (lost in denominator) | lag33 |
|---|---|---|---|
| observe (18:20) | 0 dB (max) | 1.915 % (5,526/288,632) | 0.148 |
| gain 24 dB (18:52) | 0 dB | 1.445 % (3,507/242,711) | 0.165 |
| **148 TX muted (19:12)** | **−40 dB** | **0.013 % (32/238,570)** | −0.000 |

**The waves are 148's own 1.85 GHz transmitter leaking into its 2.1 GHz receiver** (250 MHz duplex spacing,
the antennas now placed so that TX and RX couple). With the transmitter silent the forward link is at its
pre-move baseline on the very carrier that read 46 % in the morning -- so the antenna move did cure the multipath
class (§9) and introduced a self-interference class in its place. The periodicity (70-85 s) is a TX-side process:
148's TX tracking calibrations are all disabled (`lo_leakage / quadrature / loopback_delay / pa_correction /
close_loop_gain _tracking_en = 0`), the known candidate is the wandering 148 TX carrier (+42.6 kHz, ±18 kHz,
`reverse-leg-148-tx-offset`) moving an intermodulation product across the receiver's band; it is not needed for
the fix. The reverse link's simultaneous collapse (146 detecting frames with CRC garbage, watchdog re-arming
every 27 s) is the mirror image to test (146's own TX into its RX).

**The reverse collapse is NOT the mirror image.** The capture rail cannot A/B a dead leg (its health gate runs before
the attribute pokes, and `-k` re-runs the pair-wide arm gate -- units C/E/F of the same directory all aborted), so
the test was a register-dwell probe with both watchdogs stopped (`selfmute146_nowd/probe.log`: eight interleaved
20 s cells, 146 TX 0 dB vs −40 dB, 0x104 detections per second on both boards):

| cell | 146 TX | 146 det/s (of 1245) | 146 cfc | 146 rssi (dBFS) | 148 det/s |
|---|---|---|---|---|---|
| 1 / 3 / 5 / 7 | live 0 dB | 426 / 714 / 747 / 709 | +147k / +115k / +141k / +148k (unlocked) | 42.9 / 41.8 / 42.3 / 42.3 | 1245 / 1240 / 1245 / 1245 |
| 2 / 4 / 6 / 8 | **muted −40 dB** | 445 / 709 / 717 / 731 | +82k / +134k / +147k / +128k | 41.9 / 42.2 / 42.4 / 42.4 | 153 / 65 / 62 / 63 (forward gone, as expected) |

146 detects the same ~35-60 % of frames whether or not it is transmitting, its coarse estimate is unlocked
either way, and it hears 148's 1.85 GHz transmitter at **42 dBFS -- 20 dB weaker than 148 hears 146 (22.6-23.0
dBFS)**. The reverse link's problem since the move is the reverse air path itself (148's TX antenna → 146's RX
antenna: weak and in acquisition collapse, `rstcs` ~400/s), not 146's own transmitter.

**Bench state and what to do (20:30):** both boards on sp3clamp004 at r3 on the 2.1 / 1.85 plan, daemons up via a
`GATE_FPS=400` bring-up (the default pair-wide gate of 1120 f/s cannot pass while 146 reads 450-580 f/s), trigger
`degtrig-pair-20261002k` armed, forward link carrying the 1-2 % self-interference waves at TX 0 dB. The fix is on
the bench, not in the design: **place 148's TX and RX antennas apart** (the forward link reads 0.013 % the moment
148's transmitter is silent) and **bring 148's TX antenna back toward 146's RX antenna** (reverse 20 dB down).
Then re-run `postmove`-style cells (forward 2.1 / reverse 1.85) to confirm both legs at baseline before any Gate 3.
