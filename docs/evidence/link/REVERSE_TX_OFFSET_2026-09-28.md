# 148's transmit carrier is ~42.6 kHz off, and correcting for it does NOT fix the reverse leg

Three experiments on 2026-09-28 afternoon, all on the shipped image `b68dbf1d9321` at r3, no flash
and no image change. Tools: `ops/band_swap_probe.sh`, `ops/decay_watch.sh`, `ops/margin_cells.sh`.
The degraded-episode trigger was stopped for each run and the rig was left in service.

**Summary: a large, specific, transmit-side frequency error was found and quantified on 148. It is
real and worth fixing on its own. It is NOT the cause of the reverse leg's collapse -- correcting
for it moves the carrier statistic exactly as predicted and leaves delivery dead.**

## 1. Band swap: no discrimination, because the fault was absent

Six interleaved arms alternating which direction owns which frequency (`band_swap_probe.sh`).

| cells | plan | 148 rx | 146 rx |
|---|---|---|---|
| 1, 3, 5 | normal -- reverse at 1.9 GHz | 1246, 1246, 1246 | 1237, 1240, 1241 |
| 2, 4, 6 | swap -- reverse at 2.0 GHz | 1246, 1246, 1247 | **1247, 1247, 1247** |

All six passed the arm gate on the first try. **There is no contrast to follow, so this run cannot
separate band from chain.** What it does establish: immediately after an arm the reverse leg's PHY
is nominal on BOTH bands, so nothing frequency-selective prevents it reaching full rate. Re-run it
during a degraded window; the tool and the swapped plan are in the repo for exactly that.

Enabling change: `bringup_r2r3.sh`'s TX LOs became env-overridable. Defaults are unchanged, and a
half-applied swap (moving two of the four LOs, which would leave each receiver 100 MHz from its
peer and look exactly like the defect under investigation) is now refused before arming.

## 2. Decay watch: the subject sits on the null, the control does not

`decay_watch.sh`: one bring-up, then both receivers polled at 1 Hz for 25 minutes. 148 is armed by
the same bring-up in the same seconds, so it is a true simultaneous control.

| | 148 FORWARD (control) | 146 REVERSE (subject) |
|---|---|---|
| CFC median | **−3577** | **+460** |
| p5 .. p95 | −3799 .. −3323 (476 wide) | −8838 .. +12960 (**21798** wide) |
| samples within ±1000 of zero | **0.3 %** | **26.0 %** |
| detected f/s, 0-60 s | 1248 | 177 |
| detected f/s, 60-480 s | 1245 | **29** |
| detected f/s, 480-1500 s | 1244 | 901 |

Torn `direct_reg_access` reads (|0x154| > 2^20, or 0x104 rates above 3000 f/s) are filtered; they
were 0.4 % of the control's samples and 0 % of the subject's.

**The subject's carrier residual is centred on zero -- the demodulator's dead zone -- while the
control sits comfortably off it.** The subject's detection collapses inside 60 s of the arm and
partially recovers later; the control never moves.

### The arithmetic, and an independent cross-check

Calibrate on the control: 148's receiver runs a deliberate **+20 kHz** offset and reads −3577, so
**5.59 Hz/unit** (two independent sweeps the same day gave 6.0 and 6.1; the documented figure
is 7.1). 146 runs a deliberate **+40 kHz** offset, so it should read **−7154**. It reads **+460**.

    discrepancy  +7614 units  x 5.59 Hz/unit  =  +42.6 kHz of transmit-side offset on 148

which almost exactly cancels the reverse leg's designed margin and parks it on the null.

**Cross-checked against data taken hours earlier for a different purpose.** At `LO_B_RX=1900100000`
the effective offset would be 57.4 kHz, predicting CFC **−10271**. `REVERSE_LO_CELLS_2026-09-28.md`
measured **−10804** and **−10306** -- within 5 %, from a run that predates this hypothesis.

**It is transmit-specific, not a reference fault.** 148's own receiver reads exactly what its plan
calls for. A drifted reference or bad TCXO moves a board's transmit and receive together; this
moves only transmit.

**It also wanders.** Per-minute medians over the 25 minutes range −1557 to +1683 units =
**18.1 kHz peak to peak**, centred near zero. A residual parked on the null with that much wander
crosses it constantly, which is what the 26.0 % dead-zone fraction is.

## 3. Margin cells: the prediction was half right, and the half that failed is the finding

`margin_cells.sh`: four interleaved cells alternating 146's RX LO between the shipped
`1900040000` and a corrected `1900082500`, each held 240 s. **Predictions were recorded in the
tool's header before the run**: corrected cells should show CFC near −7150, a dead-zone fraction
near zero, and detection HOLDING near 1245 f/s.

| cell | plan | CFC median | dead-zone % | det 0-60 s | det after 60 s |
|---|---|---|---|---|---|
| 1 | default | +711 | 25.1 | 205 | **16** |
| 2 | **corrected** | **−5950** | **6.4** | 66 | **21** |
| 3 | default | +131 | 20.9 | 63 | **15** |
| 4 | **corrected** | **−5040** | **7.6** | 39 | **81** |

**The carrier half was confirmed.** CFC moved to −5950 and −5040 against +711 and +131, and the
dead-zone fraction fell roughly threefold, alternating cleanly with the plan and not the order.

**The delivery half was falsified.** Detection stayed collapsed in every cell, corrected or not.
Restoring the designed margin does not restore the link.

This is the **third** independent replication of one pattern: the LO moves the carrier statistic
and does not move delivery. The first was `REVERSE_LO_CELLS_2026-09-28.md` (tenfold on the
statistic, 1.8 points on PER); the second was an interleaved source A/B whose apparent effect was
time-since-arm; this is the third, with the prediction registered in advance.

Note also the gate values falling across the run -- 1241, 1192, 304, 207 -- and `det 0-60 s`
falling 205, 66, 63, 39. Both track cell ORDER, not plan. Conditions dominate delivery here, again.

## 4. Where this leaves the diagnosis

**Ruled out by measurement today**, each with its own experiment: received level (peer-mute A/B,
and `level_excursion` 0.0 per frame); frequency-selective band effects (both bands nominal at the
arm gate); carrier offset and the dead zone **as a cause** (two corrections, three replications);
transmit source, ROM versus byte (the apparent effect was time-since-arm); a shared reference
(0.6 % co-degradation, and 148's receiver is exactly on plan); a starved transmitter (148's byte
plane pumping 211,930 words/s while 146 received nothing); the delivery plane (0x104 detection
itself collapses, upstream of it).

**Established and unexplained:** a **+42.6 kHz static transmit offset on 148 with ~18 kHz of
wander**, transmit-only on a board whose receiver is correct. That is a synthesiser not sitting
where it is commanded. It does not by itself explain the collapse -- but a transmitter whose
carrier is 42 kHz off and wandering is a transmitter whose signal quality has not been measured,
and **modulation quality, not frequency, is the obvious next thing to look at.** A receiver cannot
be retuned around poor phase noise, which fits every negative result above.

**Next, in order:**
1. **Measure 148's transmitted signal quality** -- EVM and phase noise, not just carrier frequency.
   The banked one-way TXO/RXO pair is the clean way to isolate it; that needs a flash chain.
2. **Explain the +42.6 kHz transmit offset** regardless of whether it causes the collapse. It is a
   real defect in a shipped configuration and nothing in the tree predicts it.
3. **Replace the 146 antenna.** Still unreplaced, still consistent with everything measured.
4. **Re-run the band swap during a degraded window** -- today's was taken while the fault was away.
