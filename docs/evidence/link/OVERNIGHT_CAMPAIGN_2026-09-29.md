# Overnight campaign 2026-09-28/29: the reverse defect is a NOTCH at 1.9 GHz; moving the carrier clears it

Unattended, 18:09 to 06:43 (deadline 06:30, closing bring-up RESTORE_OK 06:43:25), on the shipped image `b68dbf1d9321` at r3. No flash, no image
change. Two units: `overnight-20260928` (`ops/overnight_campaign.sh`, rotation of four
hypotheses) handed off at a rest gap to `overnight-20260928b` (`ops/freq_map_campaign.sh`).
Every cell: arm on a plan, kill both watchdogs, poll BOTH receivers at 1 Hz for 240 s
(`ops/plan_cells.sh`), score in windows (`ops/plan_cells_score.py`). 148 is armed by the same
bring-up and is the simultaneous control. Interim readings as they landed:
`ops/r3cap/overnight_20260928/INTERIM_NOTES.md`.

**Why this design.** Four hand-run experiments on 09-28 found the fault absent when it mattered,
and two more read an A/B contrast that was time-since-the-arm. Holding each cell samples the
minutes after the arm where the decay lives; alternating plans makes the question whether a
statistic tracks the PLAN or the ORDER; polling both boards gives every cell a control.

## 1. Band swap with the fault LIVE: the defect follows the band

`python3 ops/plan_cells_score.py ops/r3cap/overnight_20260928/185059_bandswap`, 4 cells.

| cell | plan | reverse carrier | 146 det >60 s | 146 rstcs | 146 cfc sd | 148 det >60 s | 148 rstcs | 148 rssi |
|---|---|---|---|---|---|---|---|---|
| 1 | normal | 1.9 GHz | 828 | **299,111** | 130,317 | 1251 | 0 | 32.1 |
| 2 | swap | **2.0 GHz** | **1248** | **0** | 596 | 1069 | 0 | **38.1** |
| 3 | normal | 1.9 GHz | 837 | **351,585** | 128,776 | 1244 | 0 | 32.2 |
| 4 | swap | **2.0 GHz** | **1240** | **0** | 721 | **786** | **87,830** | **38.0** |

The reverse leg is still 148 TX -> 146 RX in both plans; only its frequency changes. At 1.9 GHz
it is degraded with a reset storm; at 2.0 GHz it is clean with zero resets. The forward leg, when
IT is moved onto 1.9 GHz, degrades -- 6 dB weaker rssi, a reset storm in cell 4. Alternates with
the plan, not the order.

**148's transmitter and 146's receiver are exonerated as hardware.** Both are perfect at 2.0 GHz,
and the 1.9 GHz impairment appears on the other board's receiver too. The +42.6 kHz transmit
offset on 148 (`REVERSE_TX_OFFSET_2026-09-28.md`) is real and is not this.

## 2. The other rotation experiments

| experiment | cells | verdict |
|---|---|---|
| **self-desense** (146 own TX live vs muted after the arm) | 4, fault present in all | **refuted** -- muted 178 / 0 f/s vs live 815 / 0; cells 3-4 collapsed either way |
| **TX power** (148 at 0 vs -10 dB) | 4, fault present in all | **inconclusive** -- 324 / 743 / 724 / 10 f/s, plan medians 524 vs 377, ranges overlap; the leg's variance dwarfs a 10 dB effect |
| AGC pin | -- | not run; rotation replaced by the frequency map after sec 1 |

## 3. Frequency map: a notch at 1.9 GHz, at most ~100 MHz wide

`ops/freq_map_campaign.sh`: reverse carrier candidates each run as a 2-cell `plan_cells` pair --
cell 1 the 1900 MHz reference, cell 2 the candidate -- with the forward leg held at 2.0 GHz and
the receiver's +40 kHz offset kept. Pooled by `ops/freqmap_pool.py`, which counts a clean
candidate as evidence ONLY when the reference cell beside it had the fault (146 det >60 s
< 900 f/s or rstcs > 1000); clean = det >= 1200 and rstcs < 100.

**Pooled over the whole night, six passes plus part of a seventh (38 pairs; the reference had the
fault in 37):**

| reverse carrier | pairs | ref with fault | candidate clean | candidate det median | candidate cfc medians (all pairs) |
|---|---|---|---|---|---|
| 1800 | 7 | 7 | **7** | 1247 | -4765 .. -4786 |
| 1850 | 6 | 6 | **6** | 1247 | -4716 .. -4746 |
| **1900 (shipped)** | -- | 37 of 38 reference cells degraded | -- | 0 .. 837 | unlocked |
| 1950 | 6 | 5 | **5** | 1244 | -4812 .. -4832 |
| 2050 | 6 | 6 | **6** | 1244 | **+7876 .. +10461** |
| 2100 | 7 | 7 | **0** | 288 | **-47,541 .. -51,835** |
| 2150 | 6 | 6 | **6** | 1248 | -4538 .. -4568 |

Every clean candidate replicated in every pass with **zero carrier resets** and full rate, beside
reference cells that were collapsed at 0 f/s or reset-storming at 200-330k per 4 minutes. The
148 control held 1244-1246 f/s in every cell all night.

**Shape.** 1850 and 1950 -- 50 MHz either side of the failing carrier -- are both clean. The
impairment does not fall off with frequency in either direction; it is a **notch centred at
1.9 GHz no more than ~100 MHz wide**. A frequency-selective antenna would produce a slope. This
is the signature of an interferer, and 1.9 GHz sits inside a cellular (PCS) uplink band, which
also fits a fault that comes and goes in multi-day waves (`REVERSE_OCCURRENCE_2026-09-28.md`)
with no diurnal pattern detectable.

**2100 is not a second notch.** Both times its carrier residual sat near -50,000 units
(~-280 kHz) where every clean candidate is in the healthy -4540..-4832 band: the inherited
+40 kHz receiver offset lands far off the null at that carrier. 2050's +7876..+10461 -- clean,
but on the wrong side of zero -- says the same thing more gently. **Any new carrier needs its own
CFC-checked LO plan**; the 1.9 GHz plan does not copy across.

## 4. What this closes, and what it changes

Closed by measurement overnight: band vs chain (band); self-desense (refuted); TX power
(inconclusive, recorded). Established since 09-28 morning and still standing: the damage is at or
below the demodulator (three PHY-only air-BER runs, forward exactly 0); received level, the dead
zone as a cause, transmit source, shared reference, starved transmitter and delivery plane are
each ruled out by their own experiment.

**The 146 antenna is no longer the leading explanation.** A frequency-selective element would give
a slope; the data give a notch, and the same notch appears on 148's receiver. Replacing it remains
reasonable link-budget hygiene, not a defect fix.

## 5. Recommendation: move the reverse leg to 1950 MHz (fallback 1850)

> **Superseded the same day.** 1950 FAILED Gate 3 under traffic (50 MHz duplex spacing raises each
> board's self-leakage ~13-15 dB; idle cells did not predict it) and the fallback, **1850, was
> credited and APPLIED as the shipped r2/r3 default on 2026-09-29** -- see
> `GATE3_REVERSE_PLAN_2026-09-29.md`. The section below is the recommendation as written that morning.

* **1950 MHz** is clean in 5 of 5 fault-paired pairs at 1240-1248 f/s with zero resets, its
  carrier residual (-4812..-4832) is the healthy band with the existing +40 kHz offset, and it is
  the smallest move that clears the notch on the high side. Exact plan for `ops/rung_table.sh`
  (r2/r3 row) and `bringup_r2r3.sh` defaults: `LO_A_TX=1950000000`, `LO_B_RX_DEFAULT=1950040000`;
  forward leg unchanged (`LO_B_TX=2000000000`, `LO_A_RX_DEFAULT=2000020000`).
* **1850 MHz** is the equivalent move on the low side (6 of 6 clean, residual -4716..-4746).
* Not recommended: 2050/2150 without a new LO plan; 2100 at all.
* **Not applied.** Shipped defaults are unchanged. The crediting run is a Gate 3 pair
  (`ops/gate3_pair.sh --no-flash --no-dtb`, r3, `LO_A_TX=1950000000 LO_B_RX=1950040000` in the
  environment) with the standard 6 reverse arms + 3 forward + the two 600 s legs, against the
  standing limits (rev <= 1 %, fwd <= 0.01 %), lost frames in the denominator.
* One caveat that is context, not measurement: 1950 MHz lies in the PCS base-station downlink
  band. Five clean pairs beside live faults say it is usable tonight; the Gate 3 run and a few
  days of sentinel duty are what say it is usable in general. The r4 (2 sps) rung has its own
  LO plan and is out of scope here.

## 6. Reproduce

    ops/launch_rig_unit.sh <unit> ops/overnight_campaign.sh OUT=<dir> "DEADLINE=<YYYY-MM-DD HH:MM>" CELLS=4 HOLD=240
    ops/launch_rig_unit.sh <unit> ops/freq_map_campaign.sh  OUT=<dir> "DEADLINE=..." HOLD=240 REST_S=120
    python3 ops/plan_cells_score.py <experiment-dir>
    python3 ops/freqmap_pool.py <freqmap-dir>

Every detection figure is 0x104 frames/s over the 60 s-to-end window of a 240 s hold; every rstcs
is the 0x150 delta over the hold; torn reads are dropped as documented in the scorer.
