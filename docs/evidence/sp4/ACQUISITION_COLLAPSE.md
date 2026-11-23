# Why acquisition collapses while the carrier loop keeps running

Follow-on to `WEDGE_CLASS.md` sec 3a, which established *what* stops (frame detection, with the byte
plane starved in lockstep) and left *why* open. Desk analysis of the three r4 wedges of 2026-09-26
plus the r4 LO cells of 2026-09-22. No board contact.

## 1. There is no precursor -- it stops dead

Per-frame telemetry for the final five seconds before delivery stops, on all three wedged legs:

| | delivery | CRC-bad | CFC median | carrier resets | ADC forensic |
|---|---|---|---|---|---|
| t−5 s .. t−1 s | 1219-1253 f/s (full rate) | 8.5-16.1 %, flat | −593 .. −877, flat | **0** | constant 0 |

No ramp, no drift, no level excursion, no reset activity. The link runs at full frame rate and a
steady error floor and then produces nothing, within one poll interval.

## 2. The CFC estimate is sitting on the dead zone

`bringup_r2r3.sh`'s own header states the mechanism: *"the fabric demod has a DEAD ZONE at residual
CFO ~= 0 (CFC near-zero dither; 0x154 sign-flips, sync collapses to ~40 %)"*. The distribution of
`reg_cfc` over the leg says how close each run sat to it -- in particular what fraction of frames the
estimator put on the **wrong side of zero**:

| forward leg (148 RX governs it) | CRC ok | CFC p5 / median / p95 | frames with CFC > 0 |
|---|---|---|---|
| 2026-09-22, LO +60 kHz (`losweep` cell) | **99.84 %** | −5700 / −4743 / −3746 | **0.0 %** |
| 2026-09-22, LO +20 kHz (default) | 99.96 % | −2426 / −1369 / +137 | 6.6 % |
| 2026-09-24, LO +20 kHz | 97.83 % | −3946 / −2466 / −884 | 2.5 % |
| **2026-09-26, LO +20 kHz (wedged)** | **88.13 %** | −3152 / −653 / **+3195** | **41.1 %** |

On the legs that wedged, the estimator was flipping sign on **41 % of frames**. On the one cell taken
with a larger offset it never crossed zero at all.

## 3. Which is exactly the documented latch

The same file records what a demod does in that state: a reset taken while the peer is mid-recovery
*"LATCHES a false FTS state (sync ~40 %, **cfc dither, rstcs calm**) that 0x110 cannot clear"* -- only
a full `0x000` soft reset does, which is why the bring-up uses a double tap.

The measured signature of a wedge matches that description field for field:

* frame detection stops (`pkts` frozen) -- the Frequency and Time Synchronizer is not producing,
* `rstcs` calm (0 through the whole freeze on `fwd300_1`) -- the carrier loop never declares a reset,
* `cfc` still updating and `r4_wit` still advancing -- the loop is running, on an ambiguous estimate,
* nothing short of a `0x000` recovers it, which is why the capture's stall watchdog cannot and the
  leg has to be aborted.

So the answer to "why does acquisition collapse while the carrier loop runs" is that **the carrier
loop running is the problem, not the counter-evidence**: it is tracking a residual sitting on the
dead zone, its sign dithers, and the FTS latches a false state that its own reset path cannot clear.

## 4. Why r4 is where this bites

The rung arithmetic. r3 is 15.36 Msym/s at 4 samples per symbol; r4 is 30.72 Msym/s at 2. A residual
CFO of a given number of Hz is therefore **half the normalised offset at r4 that it was at r3**. The
r4 LO plan was inherited from r3 unchanged -- 148 RX at +20 kHz, 146 RX at +40 kHz -- so both legs run
at half their intended margin from a dead zone whose width is set in normalised terms. That is
consistent with everything observed: r4 legs sit closer to zero than r3 legs on the same LO, and they
cross it when RF conditions move, which they did on 2026-09-26 (forward 10-12 % PER before each wedge,
reverse down at 24-37 % all evening).

## 5. Change made

`ops/rung_table.sh` now carries the RX LO plan per rung, and `bringup_r2r3.sh` takes its defaults
from there (an explicit `LO_A_RX` / `LO_B_RX` in the environment still wins):

| rung | 148 RX (forward leg) | 146 RX (reverse leg) |
|---|---|---|
| r2, r3 | 2000020000 (+20 kHz) -- **unchanged** | 1900040000 (+40 kHz) -- **unchanged** |
| r4 | 2000060000 (**+60 kHz**) | 1900080000 (**+80 kHz**) |

Both r4 values are the ones already measured on silicon at r4 on 2026-09-22: +60 kHz on 148 gave
99.84 % CRC with the CFC locked entirely on one side of zero (the best forward number recorded at
this rung), and +80 kHz on 146 locked its CFC at −5512 with a tight spread. r2 and r3 are untouched.

## 6. What this does not prove, and the experiment that would

This is an evidence-backed mechanism, not a controlled result. Three reasons to hold it loosely:

**a. The CFC-sign statistic may be downstream of the thing it is meant to explain.** A leg with
poor SNR produces both a low CRC rate and a noisier, more biased CFC estimate, so "41 % of frames
with CFC > 0" is equally consistent with *the receiver was hearing badly that evening* as with
*the LO sat too close to the null*. The rig has exactly such a confound outstanding: the 146
antenna is known bad and not yet replaced (`forward-collapse-follows-the-band`). CRC and CFC-sign
moving together across the four legs is what BOTH stories predict.

**b. The 2026-09-24 wedges do not fit.** Those legs had CFC only 2.5 % over zero and still wedged.
Either the dead zone is narrower than that fraction suggests and something else stopped those
legs, or there is a second cause. Do not fold them into this explanation.

**c. No r4 run has yet been done with the new plan.** The +60 kHz cell was 66 s on a different
evening. The change replaces an unvalidated inherited value with the best-measured one, which is
strictly better supported, but "better supported" is not "confirmed".

**The confirming experiment.** A single clean leg on the new default would NOT settle it: a good
result is also what better RF conditions look like. It has to be interleaved, so the LO is the
only thing that varies:

* Four forward r4 cells in ONE session, same hour, same antennas, no reseat between them:
  `+20k / +60k / +20k / +60k` (`LO_A_RX` env override, which the bring-up still honours).
* Per cell record: fraction of frames with `CFC > 0`, CFC median and p5/p95, CRC-ok %, delivered
  f/s, and whether the leg reached `MID_CAPTURE_WEDGE`.
* The mechanism predicts the CFC>0 fraction tracks the LO cell and not the clock. If instead both
  +20k cells look like whichever neighbour they sit next to, the driver is drift or conditions,
  not the LO.
* Run it with the 146 antenna replaced if at all possible; on the bad antenna a negative result is
  uninterpretable.

If the wedges persist with the CFC firmly off zero, the mechanism is wrong and the search moves to
the Preamble Detector itself (the ddrcap2 instrument already exposes `dc_runmax`).

Rig-safety note: this needs both boards flashed off the shipped sp3prod image, so it is a
campaign, not a spot check. Deliberately not started unattended.

## 7. The interleaved sweep was run (2026-09-26 14:15-15:20): the LO link is confirmed, the wedge link is not

`gate3_pair.sh` in `GATE3_CELLS` mode on sp4b (`bc9ac1e6b736`), rung r4, four forward captures of
300 s alternating `LO_A_RX`, all in one 65-minute session on the same antennas, `GATE_DIR=A`
(the reverse leg was in a degraded episode at 70 f/s), `CAMPAIGN_MAX_CONSEC_FAIL=0`.
Run dir `ops/r3cap/locells_20260926_141506`, scored by `ops/cfc_cells.py` and `accept_analyze.py`.

| cell | 148 RX LO | frames | f/s | CRC ok | **CFC > 0** | CFC p5 / med / p95 | PER (live 306-307 s) | wedged |
|---|---|---|---|---|---|---|---|---|
| 1 | +20 kHz | 381445 | 1243 | 91.76 % | **48.86 %** | −2194 / −62 / +3549 | 8.495 % (30899/363713) | no |
| 2 | **+60 kHz** | 380317 | 1244 | 91.99 % | **5.18 %** | −5448 / −3362 / +30 | 7.723 % (27996/362511) | no |
| 3 | +20 kHz | 380305 | 1244 | 92.36 % | **41.58 %** | −2545 / −476 / +2940 | 7.937 % (28768/362468) | no |
| 4 | **+60 kHz** | 380629 | 1244 | 92.47 % | **6.18 %** | −5297 / −3221 / +188 | 7.569 % (27445/362604) | no |

Every number counts delivered frames with lost frames in the denominator; PER is the live window
from `accept_analyze.py`, CFC columns are from `cfc_cells.py` over the same `frames.bin`.

**a. The sign fraction tracks the LO, not the clock -- confirmed.** 48.9 / 5.2 / 41.6 / 6.2 %
alternates exactly with the cell. Between-treatment separation is about 8x (41-49 % against
5-6 %); within-treatment spread is 7.3 and 1.0 points. This is the result the interleaving was
built to produce, and it is not explainable by drift: a monotone trend cannot alternate.

**b. And in the same run, a different statistic DID track the clock.** CRC-ok rises monotonically
91.76 -> 91.99 -> 92.36 -> 92.47 % regardless of cell, alongside the radio getting stronger across
the session (148 rssi 32.9 -> 29.9 dBFS, i.e. about 3 dB more signal; these readbacks are dB BELOW
full scale). So conditions really were moving, the design really did separate the two, and the
CFC-sign result survives that separation. The confound named in section 6a is measured here, not
merely argued away.

**c. The wedge link is NOT confirmed, and this is the important negative.** No cell wedged --
including cell 1 at **48.9 %** of frames on the wrong side of zero, which ran the full 307 s
clean. On 2026-09-26 overnight, forward legs at 41.1 % wedged within 8-37 s. A high sign fraction
is therefore **not sufficient** to cause the collapse, and section 3's account of *why acquisition
stops* does not follow from this run. What differs between the two sessions is RF: 92 % CRC and
about 3 dB more signal tonight against 88 % CRC then. The live hypothesis is now that the dead zone
is a *predisposing* condition that needs poor SNR to latch, which this sweep cannot test because
nothing latched.

**d. PER: suggestive, not resolved.** The two +20 kHz cells averaged 8.22 % against 7.65 % for the
two +60 kHz cells, and the values do alternate with the cell. But the within-treatment spread at
+20 kHz is 0.56 points, the same size as the 0.57-point gap, so with two cells per arm this is not
a resolved difference. The CP95UL figures in the capture lines are binomial on one leg and do not
cover leg-to-leg variation -- do not quote them as error bars on the comparison.

**e. An open discrepancy worth a note.** Moving the LO by 40 kHz moved the CFC median by about
3000 units (−62 -> −3362, −476 -> −3221), i.e. ~13 Hz/unit, where the 13-point silicon staircase of
2026-09-07 gives 7.10 Hz/unit. Same leg, same session, so this is not the forward-vs-reverse
two-point trap. Unexplained; it does not affect the conclusions above, which turn on the sign.

**Verdict.** The per-rung LO change stands: it demonstrably moves the receiver off the null (a) and
PER is no worse and possibly slightly better (d), at no cost. But it should NOT be described as the
fix for the wedges. The cause of the acquisition collapse is still open, and the next experiment
has to reproduce a wedge, which means a session with the degraded RF the wedges appeared in --
not a clean one. These cells say nothing about the reverse leg.
