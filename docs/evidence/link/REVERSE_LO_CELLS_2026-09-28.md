# Interleaved reverse RX-LO sweep at r3: the LO moves the carrier statistic and does NOT fix the link

Run 2026-09-28 11:49-12:14 as unit `lorev-114924`. Four interleaved 300 s reverse captures on the
shipped image `b68dbf1d9321` at r3, alternating 146's RX LO between the current plan (+40 kHz) and
+100 kHz. **No flash, no device-tree deploy**, `KEEP` at the end -- the pair never left the shipped
image. Sequence validated with `DRY=1` first. The degraded-episode trigger was stopped for the run.

    ops/launch_rig_unit.sh lorev-114924 ops/gate3_pair.sh \
      GATE3_TAG=lorev GATE3_MD5=b68dbf1d9321 GATE3_RUNG=r3 \
      GATE3_NO_DTB=1 GATE3_NO_FLASH=1 GATE3_KEEP=1 CELL_S=300 CAMPAIGN_MAX_CONSEC_FAIL=0 \
      "GATE3_CELLS=B:LO_B_RX=1900040000 B:LO_B_RX=1900100000 B:LO_B_RX=1900040000 B:LO_B_RX=1900100000"

This closes the question left open by `REVERSE_ERROR_SOURCES_2026-09-28.md` sec 3.4, where the same
sweep was run on a latched receiver and was void.

## 1. Results

`ops/cfc_cells.py` (carrier statistic) beside the rail's own `accept_analyze.py` (delivery):

| cell | RX LO | **CFC > 0** | CFC median | CFC p5 .. p95 | CRC ok | PER | span to wedge |
|---|---|---|---|---|---|---|---|
| 1 | +40 kHz | **36.28 %** | −35319 | −195328 .. +200623 | 3.00 % | UNUSABLE | 32 s |
| 2 | **+100 kHz** | **3.98 %** | −10804 | −66313 .. −768 | 46.18 % | 53.316 % | 92 s |
| 3 | +40 kHz | **41.54 %** | −693 | −114289 .. +108843 | 46.72 % | 54.337 % | 113 s |
| 4 | **+100 kHz** | **3.80 %** | −10306 | −56105 .. −760 | 52.94 % | 52.513 % | 130 s |

PERs are live-window with **lost frames in the denominator**; every cell wedged, so each span ends
at its wedge. Cell 1 is marked UNUSABLE by the scorer (live window 0 s of 32 s) and is **not used
for any delivery claim below**.

## 2. The carrier statistic tracks the KNOB

Read against the cell ORDER, which is the entire point of interleaving:

    +40 kHz -> 36.28 %      +100 kHz -> 3.98 %      +40 kHz -> 41.54 %      +100 kHz -> 3.80 %

An order of magnitude, alternating cleanly with the LO and not with the running clock. The spread
says the same thing more strongly than the fraction does: at +40 kHz the estimate ranges over
±200,000 units -- unlocked garbage -- while at +100 kHz it is **bounded and entirely negative**
(p95 of −768 and −760, i.e. essentially no frames on the wrong side).

**The CFO dead zone at r3 is real and the RX LO is a genuine lever on it.** This replicates at the
4-sps rung what `ACQUISITION_COLLAPSE.md` sec 6 established at 2 sps.

Internal consistency: raising the LO 60 kHz moved the median from −693 to about −10,500, i.e.
**6.1 Hz/unit**, against 6.0 Hz/unit from the independent 13-point sweep earlier the same day and a
documented 7.1. The three agree.

## 3. Delivery tracks the CLOCK -- the LO does not fix the link

**All four cells wedged. `bad_arms=4 of 4.`** And across the three scorable cells, delivery is flat
in the LO and rising with time:

| in cell order (2, 3, 4) | +100 k | +40 k | +100 k |
|---|---|---|---|
| PER | 53.316 % | 54.337 % | 52.513 % |
| CRC ok | 46.18 % | 46.72 % | 52.94 % |
| time to wedge | 92 s | 113 s | 130 s |

PER varies by 1.8 points across a knob that moves the carrier statistic tenfold. CRC and
time-to-wedge increase **monotonically with cell order regardless of the LO** -- the signature of
conditions, not of the knob.

**So this is the finding: the carrier estimate is a symptom that can be moved without moving the
disease.** I leaned toward the dead zone as the root cause this morning; the correct reading is
narrower -- the dead-zone dither is real, is LO-controlled, and is **downstream of whatever is
actually breaking this leg**. `REVERSE_ERROR_SOURCES_2026-09-28.md` sec 9 item 1 is now answered and
should be read with this file beside it.

*Honesty note on cell 1.* Including it would make the +40 kHz mean CRC 24.9 % against +100 kHz's
49.6 % and would look like a large LO effect on delivery. Cell 1 is the cell the scorer itself flags
UNUSABLE, its carrier estimate is ±200,000-unit garbage, and it wedged in 32 s. Scoring delivery on
a window the rail declares unusable is exactly the move that produces a wrong answer, so it is
excluded and the exclusion is stated rather than silent.

## 4. The leg is worse than it was yesterday

For scale against the same instrument: the two triggered captures of 09-27 ran 13.594 % and
18.331 % PER over 305-308 s live windows. Today every cell sat at **52-54 % PER and wedged inside
130 s**. Whatever is degrading this leg has continued to degrade it through the day.

## 5. What this changes

* **Do not deploy +100 kHz as a fix.** It buys no measured delivery. It is a real improvement to the
  carrier estimate and nothing more, and the r3 plan should not change on a statistic that does not
  move PER.
* **If the plan is ever revisited, +100 kHz is too far anyway.** The historical healthy reverse
  median is −4750; +100 kHz lands at −10,500. From cell 3's −693 at the current +40 kHz, the
  arithmetic at 6.1 Hz/unit puts the healthy median at about **+65 kHz** (`LO_B_RX=1900065000`).
  Recorded for whoever needs it; not a recommendation on today's evidence.
* **The 148 transmit-side hypothesis moves to the front.** It is the one candidate untouched by any
  measurement (`REVERSE_ERROR_SOURCES_2026-09-28.md` sec 3.3): 148's TX feeds only the reverse leg,
  so a transmit carrier or clock fault is invisible to every forward measurement ever taken here,
  and this rig's sp3 Gate 3 root cause was exactly that, with per-arm drift. Separate it with the
  banked one-way TXO/RXO pair or by scoring 148's transmit against a receiver other than 146.
* **The 146 antenna remains unreplaced** and is still consistent with everything measured.
