# Gate 3 on the moved reverse carrier: 1950 fails under traffic, 1850 fixes the reverse leg and exposes a forward-leg problem

Follows `OVERNIGHT_CAMPAIGN_2026-09-29.md`, which mapped the reverse leg's defect to a notch at
1.9 GHz in idle hold-cells and recommended 1950 MHz (fallback 1850). Both were credited the same
morning with the standard Gate 3 pair rail on the shipped image `b68dbf1d9321` at r3 -- no flash,
no dtb, `KEEP` -- with the LO plan in the environment. Every PER below is `accept_analyze.py`'s
live-window figure with **lost frames in the denominator**; every leg's `LO_PLAN` line was
checked against the intended plan. Run artefacts and per-run readings:
`ops/r3cap/gate3_rev1950_20260929_090514/READING.md`, `ops/r3cap/gate3_rev1850_20260929_092432/READING.md`.

    ops/launch_rig_unit.sh gate3-rev1950 ops/gate3_pair.sh LO_A_TX=1950000000 LO_B_RX=1950040000 GATE3_TAG=rev1950 GATE3_MD5=b68dbf1d9321 GATE3_RUNG=r3 GATE3_NO_DTB=1 GATE3_NO_FLASH=1 GATE3_KEEP=1
    ops/launch_rig_unit.sh gate3-rev1850 ops/gate3_pair.sh LO_A_TX=1850000000 LO_B_RX=1850040000 GATE3_TAG=rev1850 ...same...

## 1. 1950 MHz: FAIL -- every reverse arm wedged 13-52 s into traffic

| leg | arm gate (ROM) | first 15 s of traffic | wedge onset | at the wedge |
|---|---|---|---|---|
| rev180_1 | 1246 / 1247 PASS, settle OK | crc 99.8 %, cfc -4792 tight, 0 rstcs | 45 s | crc 0 %, **6,099 then 17,631 rstcs / 15 s**, cfc +/-180k |
| rev180_2 | 1246 / 1247 PASS, settle OK | crc 99.8 %, cfc -4794, 0 rstcs | 18 s | same |
| rev180_3 | 1246 / 1248 PASS, settle OK | already storming | 7 s | same |

Fail-fast skipped the remaining eight legs; `bad_arms=11 of 11 FAIL`. The mode is the
reset-storm unlock (|cfc| < 1000 stayed under 1 %), not the dead zone.

**Why the idle cells did not predict it.** Received in-band power on each board tracks its own
TX-RX (duplex) separation, not the carrier -- it is the board's own transmitter leaking in:

| reverse carrier | separation | 148 decpow / gain | 146 decpow / gain | idle detection 148 / 146 |
|---|---|---|---|---|
| 1800 | 200 MHz | 32.0 / 34 | 29.2 / 34 | 1246 / 1247 |
| 1850 | 150 MHz | 32.0 / 34 | 28.5 / 34 | 1246 / 1247 |
| 1900 (shipped) | 100 MHz | 26.8 / 34 | 26.0 / 34 | 1245 / **471** (the notch) |
| **1950** | **50 MHz** | **13.5 / 30** | **11.5 / 31** | 1246 / 1244 |
| 2050 | 50 MHz | 14.0 / 33 | 11.8 / 31 | 1244 / 1244 |
| 2150 | 150 MHz | 32.0 / 34 | 26.0 / 34 | 1246 / 1248 |

(dBFS, larger = weaker; medians over all overnight passes.) At 50 MHz spacing both receivers take
~13-15 dB more self-leakage and the AGC backs off 3-4 dB. Idle cells still decode at full rate;
the capture rail -- qpsk_perf UDP traffic, a re-arm, a DMA tap on the target -- tips the receiver
within seconds. The end-of-leg RF under traffic matched the idle numbers exactly, so traffic did
not change the RF. **The idle map does not predict traffic behaviour at 50 MHz spacing; 1950 and
2050 are withdrawn.**

## 2. 1850 MHz: the reverse leg is CLEAN, 7 of 7, and the 600 s leg beats the pass baseline

| leg | live | PER | CP95UL | crc_ok | rstcs/s | cfc median |
|---|---|---|---|---|---|---|
| rev180_1..6 | 190-196 s | 0.012 / 0.006 / 0.008 / 0.007 / 0.002 / 0.004 % | <= 0.017 % | 99.99-100 % | 0 | -4758..-4771 |
| **rev600** | **613 s** | **0.004 % (31 / 744,231)** | **0.006 %** | **100.00 %** | **0** | **-4757** |

The 09-16 sp3prod PASS baseline's rev600 was 0.008 % (59 / 747,971). Every reverse leg had zero
carrier resets and the carrier parked in the healthy band. The sentinel's first sample after
`KEEP` read `rev=1245/s rcrc=100.0%` -- the first full-rate, 100 % reverse sample in days.

## 3. ...and the forward leg, whose LOs did not change, wedged 2 of 4

| leg | ended | live | PER | crc_ok | rstcs | note |
|---|---|---|---|---|---|---|
| fwd180_1 | 10:19 | 186 s | 0.031 % (65 / 212,226) | 99.98 % | 0 | 3 host-side stalls of 4-5 s |
| fwd180_2 | 10:27 | 186 s | 0.048 % (101 / 212,120) | 99.97 % | 0 | 3 host-side stalls; gate took 2 tries |
| **fwd180_3** | 10:34 | 30 of 61 s | WEDGED | 68.2 % | 330/s | **settle failed first: 148 rx=0 f/s**; storm at 34 s |
| rev600 | 10:49 | 613 s | 0.004 % | 100 % | 0 | clean, between the two forward wedges |
| **fwd600** | 10:57 | 56 of 85 s | WEDGED | 82.8 % | 82/s | clean 50 s at 1246/s, storm at 59 s |

Verdict line `bad_arms=2 of 11, long_legs_over_limit=1 -> FAIL`. Read it as **reverse solved,
forward now the open question**, not as "1850 failed":

* it is forward-specific, not a bad hour -- the reverse leg ran 613 s perfectly between the two
  forward wedges;
* it is not a level problem -- at the 1850 plan 148's own decpow is 30.5 dBFS against 26.8 at 1900
  (its TX-RX separation grew from 100 to 150 MHz), gain 34;
* the two clean forward legs are 3-7x the 09-16 baseline (0.006-0.009 %);
* the periodic host-side stalls on 148 (rstcs 0, cfc healthy, 0x104 at 1245/s, delivery pausing
  4-5 s) are **not new** -- 09-16 had one per 180 s leg -- but were **three times as frequent**;
* fwd180_3's settle failure read `148 rx=0 f/s 146 rx=560 f/s`: 148 detected nothing during a
  settle, before any traffic.

## 4. Discriminator: forward captures alternating the 1900 and 1850 plans under traffic

    ops/launch_rig_unit.sh gate3-fwdplan ops/gate3_pair.sh GATE_DIR=A GATE3_TAG=fwdplan ... CELL_S=180 CAMPAIGN_MAX_CONSEC_FAIL=0 \
      "GATE3_CELLS=A:LO_A_TX=1900000000,LO_B_RX=1900040000 A:LO_A_TX=1850000000,LO_B_RX=1850040000 ...x3"

(`gate3_pair.sh` CELLS gained a comma list of variables per cell for this, PR #72.) Prediction,
stated before the run: forward clean at 1900 and wedging at 1850 -> the 1850 plan couples into
148's receive path and is not shippable as-is; both plans wedge or degrade today -> the forward leg
has developed its own problem, independent of the reverse plan, and 1850 stands.

RESULT (11:02-11:50, `ops/r3cap/gate3_fwdplan_20260929_110235`, six cells, `LO_PLAN` checked on each):

| cell | reverse plan | 146 at the ROM arm gate / settle | 148 PER (lost in denominator) | crc_ok | rstcs | cfc median | host stalls |
|---|---|---|---|---|---|---|---|
| 1 | **1900** | **349 -> 382** (fault live) | 0.019 % (41 / 212,309) | 99.98 % | 0 | -3488 | 3 |
| 2 | 1850 | 1247 -> 1247 | 0.022 % (48 / 217,950) | 99.98 % | 0 | -3494 | 3 |
| 3 | **1900** | **460 -> 285** | 0.020 % (44 / 218,453) | 99.98 % | 0 | -3471 | 3 |
| 4 | 1850 | 1247 -> 1247 | 0.159 % (347 / 218,329) * | 99.90 % | 0 | -3463 | 3 |
| 5 | **1900** | **364 -> 335** | 0.022 % (49 / 219,196) | 99.98 % | 0 | -3456 | 4 |
| 6 | 1850 | 1247 -> 1247 | 0.020 % (44 / 218,325) | 99.98 % | 0 | -3465 | 3 |

**Neither predicted outcome: the forward leg wedged in NONE of the six cells at either plan**
(1245 f/s, zero carrier resets, carrier tight at -3456..-3494 throughout). Forward PER is
**plan-independent**: 0.019 / 0.020 / 0.022 % at 1900 against 0.022 / 0.020 % at 1850. The one
outlier (*cell 4: 282 singles, lag-33 0.063) coincided with a 7,561-reset burst logged by the
OTHER board in the same three minutes -- a shared disturbance in that window, not a plan effect;
the other two 1850 cells match the 1900 cells exactly. The periodic host-side stalls on 148 ran at
3-4 per cell at BOTH plans.

And the reverse leg at the arm gate -- the ROM-source detection the bring-up reads before any
traffic -- was **285-460 f/s in every 1900 cell and 1247 f/s in every 1850 cell**: three more
fault-paired pairs for 1850, interleaved against a live 1900 fault.

## 5. Position

**Reverse leg: solved by moving the carrier to 1850 MHz.** Ten of ten fault-paired reverse
measurements today are clean at 1850 -- seven Gate 3 legs including **613 s at 0.004 %
(31 / 744,231), zero resets**, and three interleaved arm gates at 1247 f/s -- beside a 1900 fault
that was live the whole time (285-837 f/s, reset storms). Better than the 09-16 pass baseline.

**The 1850 plan does not affect the forward leg.** Six interleaved cells, 0.020 % at both plans,
the same host-side stalls at both, no wedge at either.

**The forward leg has its own, plan-independent condition today**: ~0.020 % at both plans against
0.006-0.009 % on 09-16; host-side delivery stalls (rstcs 0, cfc healthy, 0x104 at 1245/s, 4-5 s
pauses) three times as frequent as on 09-16; and two reset-storm wedges at 10:34 and 10:57 that did
not recur in six later cells. A low-rate forward wedge class pre-exists -- 09-16's own fwd600 was
`[WEDGE truncated]` at 605 s. This is the next investigation, on 148's side, and it is separate
from the reverse fix.

**A formal Gate 3 pass is not achievable today on ANY plan**, because the forward 600 s limit is
0.01 % and the forward leg sits at 0.02 % at the shipped plan too. The 1850 run's `FAIL` is entirely
the forward criterion; the reverse limit (1 %) is met by 1850 with a 250x margin.

**APPLIED 2026-09-29 13:53, on the operator's instruction.** The TX carriers now live in
`ops/rung_table.sh` beside the RX plan (`LO_A_TX_DEFAULT` / `LO_B_TX_DEFAULT`; r2/r3 = 1850000000 /
2000000000, r4 unchanged), `bringup_r2r3.sh` reads them, `sro_sign.sh` takes its nominal from the
peer's table carrier (so the printed offset is `40000`, not the `-49960000` a hard-coded nominal would
give), `oneway_bringup.sh` and the older single-variable rails follow, and `restore_known_good.sh`
lost a stale `LO_B_RX=1900020000` that would otherwise have tripped the pairing guard on the rail
every restore falls back to. Acceptance: a plain bring-up with no LO variables in its environment
armed `LO_PLAN rung=r3 148_rx=2000020000 146_rx=1850040000 148_tx=1850000000 146_tx=2000000000`,
`ARM GATE PASS (try 1)` at 1247 / 1247 f/s, `ARM_SETTLE_OK`, `BRING-UP COMPLETE`; the boards read
`148 tx_lo=1850000000`, `146 rx_lo=1850040000` live. The paragraph below is the recommendation as it
stood before it was applied.

**Recommendation (as made):** adopt the 1850 reverse plan in the
r2/r3 row of `ops/rung_table.sh` and `bringup_r2r3.sh`'s defaults:
`LO_A_TX=1850000000`, `LO_B_RX_DEFAULT=1850040000`; forward unchanged (`LO_B_TX=2000000000`,
`LO_A_RX_DEFAULT=2000020000`). The +40 kHz receiver offset gives the healthy carrier band at 1850
as-is (-4716..-4771). Until the defaults change, **every default bring-up -- including the
sentinel's recovery chain -- returns the rig to 1900**; the rig was left on 1850 by `KEEP` and will
revert at the next recovery. 1950 and 2050 are withdrawn (50 MHz duplex spacing). Context, not
measurement: the US PCS uplink block spans 1850-1910 MHz and the notch sits inside it; 1850 is at its
lower edge. If the impairment widens, 1800 (7 / 7 idle-clean, 200 MHz spacing, carrier -4765..-4786)
is the next candidate and needs its own Gate 3. The 146 antenna is link-budget hygiene, not a fix.
