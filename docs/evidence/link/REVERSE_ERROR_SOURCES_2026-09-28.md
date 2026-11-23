# Reverse-leg error sources: what was measured on 2026-09-28, and what it rules in and out

Live rig session plus desk analysis, 08:15 .. 09:30 on 2026-09-28, while the reverse leg
(148 TX -> 146 RX) was in a deep episode. Companion to `REVERSE_OCCURRENCE_2026-09-28.md`
(how often) -- this one is about cause.

Every board read went through `ops/rigprobe.sh`, `ops/rate_probe.sh` or a lock-holding probe, so
the rig mutex was held throughout and the sentinel stood down. `degtrig-pair-20260927.service` was
stopped for the whole session. Three bring-ups were run; the rig was left in service.

## 1. Headline

**The reverse leg's errors are in the carrier / frequency-estimation domain, not the signal level,
not the delivery plane, and not a shared-reference fault.** Four independent measurements agree,
one of which is an assumption-free classifier that was not told what to look for.

The leg also does something not previously recorded: after a clean bring-up restores it to
~1050-1110 f/s, **it re-degrades within minutes**, and while degraded it flaps between 0 and
~850 f/s on a timescale of tens of seconds.

## 2. State when the session opened

| | 148 (forward RX) | 146 (reverse RX) |
|---|---|---|
| detected f/s, `ops/rate_probe.sh <ip> 30` | 1131 | **40** (nominal 1245) |
| rstcs/s | 20.0 | **0.0** |
| 0x104 across three reads 5 s apart | 0xBB2D, 0x89D, 0x24FA (resetting) | 0x274, 0x274, 0x4B0 (frozen) |
| 0x154 CFC | −3449 (healthy) | **+3058, +2360, +391** |
| rssi / decimated power | 32.149 / 26.750 dBFS | 33.565 / 26.00 dBFS |
| RX LO / peer TX LO | 2000020000 / 1900000000 | 1900040000 / 2000000000 |
| RX gain (mode) / TX gain | 34 dB (automatic) / 0 dB | 34 dB (automatic) / 0 dB |

The LO plan is correct on both boards (+20 kHz forward, +40 kHz reverse) and the gains are nominal.
**146 was detecting 3.2 % of nominal while its received power was normal.**

## 3. Ruled OUT by measurement

### 3.1 Signal level, and "146 cannot hear 148"

Peer-mute A/B, the established technique for this rig (readbacks are dBFS: larger = weaker):

| | peer live (3 samples) | peer muted (4 samples) | change |
|---|---|---|---|
| 146 rssi (reverse) | 33.504, 33.742, 33.611 | 56.247, 56.420, 56.445, 56.327 | **22.7 dB** |
| 148 rssi (forward) | 31.745, 31.897, 31.914 | 57.421, 57.793, 57.239, **53.186** | ~25.6 dB |

**Note the fourth muted sample on 148: 53.186, about 4 dB louder than the three before it, with the
peer still muted.** That is a step in the floor partway through the dwell, not scatter -- 146's four
muted samples span 0.2 dB. It is a single sample and proves nothing on its own, but it is the only
hint of a time-varying noise floor anywhere in this session, and it is recorded rather than averaged
away. A floor that moves would be worth a longer muted dwell on both boards.

**146 hears 148 plainly.** With the peer live 146's CFC stayed bounded (driven by a real signal);
with the peer muted it read six-figure garbage and exact `0x0` (the documented fully-unlocked
signature). Frame detection was ~0 in both states.

*What this does not support:* the AGC is in `automatic` mode, so it re-gains when the peer goes
silent. The two numbers therefore **cannot** be converted into an SNR, and the 2.9 dB difference
between the legs is not a link-budget measurement. Do not quote it as one.

### 3.2 Received level as an error driver, per frame

`ops/frame_taxonomy.py` scores `level_excursion` at **0.0 (confidence low)** on both degraded
captures. Level does not track the errors at the frame level either.

### 3.3 A shared-reference or rig-wide cause -- and the half of it that is NOT ruled out

Of 469 degraded reverse samples, **3 (0.6 %)** had the forward leg degraded in the same sample, and
the forward leg has never delivered exactly zero in 3277 samples
(`REVERSE_OCCURRENCE_2026-09-28.md` sec 4). 146's own transmit feeds the forward leg and is fine,
which rules out a fault in **146's** frequency reference: that would move both directions.

**It does NOT rule out a fault on 148's transmit side.** 148's TX feeds *only* the reverse leg, so a
148 transmit-side carrier or clock fault is invisible to every forward measurement in this document
and in every prior one -- and it would produce exactly what was observed: one-sided, receive-looking,
normal received power, a strong peer-mute delta (the carrier is radiating), and 146's estimator
unable to settle. This rig has a precedent: the sp3 Gate 3 root cause was a transmit SSI/clock
defect with per-arm drift (`docs/evidence/sp3/`, `sp3-gate3-cause-tx-ssi`), and "per-arm" would also
fit a leg that recovers on a bring-up and re-degrades minutes later. **Untested.** See sec 9 item 2.

### 3.4 A carrier offset that could be tuned out

A 13-point RX-LO sweep on 146, −200 kHz to +400 kHz around the nominal 1900040000, with no arm and
no reset. CFC tracked the LO as expected (+33,930 at −200 kHz down to −66,305 at +400 kHz,
slope ≈ 6.0 Hz/unit against the documented 7.1), but **detection never exceeded 408 f/s at any LO.**

*This result is VOID as a test of the offset hypothesis* and is recorded only for the slope. It was
run while the receiver was in the collapsed state, and `ACQUISITION_COLLAPSE.md` sec 3 states that
state is cleared only by a full `0x000` -- so no LO value could have recovered it. The sweep tested
a latched receiver and proves nothing about tuning. It needs re-running on an unlatched leg.

### 3.5 Payload whitening mismatch

Both daemons were read directly from `/proc/<pid>/environ`: `QPSK_WHITEN=1` on both, identical
command lines (`./qpsk_tun -G -M 16 -r 15360 -i tun0 -s 5`). Not a mismatch.

## 4. Ruled IN: the carrier / frequency-estimation domain

### 4.1 An assumption-free classifier picks it, unprompted

`ops/frame_taxonomy.py` derives error sources from per-frame telemetry without presupposing a cause.
Run on two degraded reverse captures and two healthy reverse baselines from the same image family:

| capture | PER (errored / delivered) | **cfo_dither** | carrier_reset | level_exc | mean run |
|---|---|---|---|---|---|
| `soak_rev2_20260913_114619` | 0.061 % (465/765441) | **0.999 low** | 0.0 low | 0.0 low | 3.23 |
| `sp3cdc_rev2_20260912_213121` | 0.033 % (79/241976) | **1.008 low** | 0.0 low | 0.0 low | 2.82 |
| `episode_20260927_091556` | 7.374 % (26356/357394) | **9.54 HIGH** | 0.163 med | 0.0 low | 74.66 |
| `episode_20260927_135556` | 10.619 % (37319/351430) | **7.64 HIGH** | 0.147 med | 0.0 low | 25.39 |

`cfo_dither` is the ratio of CFC deviation on errored frames to CFC deviation on good ones. It is
**exactly 1.0 on both healthy legs** -- no association at all -- and **7.6 to 9.5 with the tool's
own "high" confidence** on both degraded ones. Level excursion is 0.0 everywhere.

**Denominator note:** these PERs are `errored / delivered` from the per-frame log, which is NOT the
same quantity as the capture rail's `accept.txt` PER (13.594 % and 18.331 % for these two runs),
which counts never-delivered frames in the denominator as well. Both are stated; do not mix them.

### 4.2 The CFC distribution, quantified

`ops/score_leg.py` on banked reverse captures, and a 1 Hz poll of the live board:

| leg state | CFC median | spread |
|---|---|---|
| healthy, 09-12/13 (four captures) | −4743 .. −4778 | **IQR width 26 .. 32 units** |
| degraded, 09-27 09:15 | −3688 | IQR width **2033** |
| degraded, 09-27 13:55 | −4780 | IQR width **2901** |
| **live, 09-28, 114 one-second samples** | **+5386** | **stdev 10092**, min −20765, max +36159 |

On the live board, **36 of 114 consecutive samples changed sign** (32 %) and **81.6 % sat above
zero**. Healthy is −4750 held to a band 30 units wide.

For calibration, `ACQUISITION_COLLAPSE.md` sec 2 records that r4 legs which wedged had **41.1 %** of
frames on the wrong side of zero, and the one cell taken with a larger LO offset had 0.0 %. The live
reverse leg is at **81.6 %**.

### 4.3 The collapse signature matches the documented latch, field for field

`ACQUISITION_COLLAPSE.md` sec 3 predicts four things for the false-FTS latch. All four held on 146:

| prediction | observed |
|---|---|
| frame detection stops | 0x104 frozen at 0x274 across reads 5 s apart; 26 f/s over 116 s |
| rstcs calm | 0x150 = 0x0 on all reads, rstcs/s = 0.0 (but see below) |
| cfc still updating on an ambiguous estimate | 0x154 swinging ±27,000, 32 % sign flips |
| only a full 0x000 clears it | a bring-up restored 1055-1107 f/s, three times out of three |

That class had only ever been recorded at r4 (2 sps). **This is the same signature at r3.**

**Do not read the "rstcs calm" row as a contrast with 148.** `ops/rate_probe.sh` reported
`rstcs_s=20.0` for 148 in the same session -- on a leg delivering 100 % CRC, where 20 carrier resets
per second would destroy delivery. That number is an artefact: the script guards its 0x104 rate
against mid-window resets (the whole reason it exists) but summed 0x150 with `max(0, rb-ra)` and no
such guard, so every climb after the reset counter is itself cleared was counted as fresh resets.
Direct reads caught it (0x150 = 0x656, 0x0, 0x0 across three reads 5 s apart). The field is now
printed as `rstcs_s<=` and documented as an upper bound that must not be compared between boards.
The latch match above is therefore scored on **146's own four fields**, where 0x150 read 0x0 on
every direct read -- not on a forward/reverse difference.

## 5. The new behaviour: it re-collapses within minutes

Three bring-ups were run (`GATE_DIR=A`, since the reverse receiver could not pass the two-sided arm
gate). Each restored the leg and each was followed by re-degradation:

| bring-up | 148 at the arm gate | 146 at the arm gate | 146 shortly after |
|---|---|---|---|
| 09:07 | 1247 f/s | 1084 -> 1107 f/s | **22 f/s** within ~15 min |
| 09:12 | 1247 f/s | 1080 f/s | **26 f/s** over the next 116 s |
| 09:23 | 1246 f/s | 1055 -> 1051 f/s | left in service |

Two things in that table are worth separating:

1. **A re-collapse within minutes.** The 09:12 run polled 146 at 1 Hz starting immediately after the
   bring-up reported complete, and the leg was already flat: 3047 detected frames in 116 s.
2. **A persistent ~15 % deficit even when "healthy".** Across all three arms 146 came up at
   1051-1107 f/s against 148's steady 1246-1247. The reverse leg does not reach nominal even
   immediately after a clean arm. That deficit is separate from the collapse and is not explained.

## 6. One reading I ran and am withdrawing

I ran an interleaved transmit-source A/B (ROM `0x158=0` vs byte `0x158=1`, with a `0x110` pulse
only -- no `0x000`, which the latch is known to require) and got 146 at 0, 136, 0, 818 f/s across
the four cells. That looked like source dependence. **It is not supported:** a following traffic
test measured the same leg at 292, 52, and 832 f/s within a few minutes with the source held
constant. The leg's own flapping spans the entire range of the A/B, so the experiment cannot
resolve a source effect. It would need many interleaved cells, not four.

For the record, the confound it was meant to close IS closed: 148's byte plane was pumping
throughout (0x1C0 advancing 224,013 words/s), so "148 had stopped transmitting" is not the
explanation for the reverse leg's zeros.

## 7. Side finding: 146 is off its configured steering branch

`ops/profiles/sro_sign.conf` sets 146 to `sro_sign=1`. The witness register **0x25C reads 0x0** on
146 -- three reads 5 s apart, and again after a bring-up that logged `SRO_SIGN wrote=1
readback_mode=0x1 edge=FULL`. So the register does report, it was set, and it does not stay set.

Note `0x208` reads `0x0` on **both** boards and is **not** the witness; 0x25C is. A check written
against 0x208 would report both boards off-branch and be wrong about 148.

Whether this contributes to the collapse is **not established** -- 0x104 counts detections upstream
of the byte-plane steering this bit selects. It is recorded as an open discrepancy.

## 8. Fixed in this session

`ops/sro_sign.sh:lo_rx_offset()` subtracted a hard-wired 2.0 GHz for **both** boards, but the quiet
pair is asymmetric (forward 2.00 GHz, reverse 1.90 GHz). Board B's deliberate +40 kHz was therefore
printed in every bring-up and restore log as `lo_offset_hz=-99960000` -- −99.96 MHz. The
AGREE/DISAGREE verdict was never affected (`do_check` takes `implies` from the sign of CFC, not from
this number), but anyone reading those logs to diagnose this leg was handed a figure wrong by five
orders of magnitude. Now per-board; pinned by
`ops/tests/test_sro_sign_conf.py::TestLoRxOffsetNominalIsPerBoard`.

## 9. What to do next, in order

> **ANSWERED 2026-09-28 12:14 -- see `REVERSE_LO_CELLS_2026-09-28.md`.** The interleaved sweep was
> run on an unlatched leg. The carrier statistic tracks the LO cleanly (36.3 / 4.0 / 41.5 / 3.8 %
> wrong-side, alternating), **but all four cells wedged and PER was 52-54 % at both LO values**.
> The dead-zone dither is real and LO-controlled, and it is **downstream** of whatever breaks this
> leg -- a symptom that moves without the disease moving. Item 1 below is closed; **item 2 is now
> the front-runner.**

1. ~~**Re-run the RX-LO sweep on an UNLATCHED leg.**~~ **DONE, see the note above.** Section 3.4 is void and the question it was
   meant to answer is the most promising one open: the live estimator sits 81.6 % above zero where
   healthy is −4750, and `ACQUISITION_COLLAPSE.md` sec 5 already fixed exactly this problem at r4 by
   enlarging the RX LO offset. The r3 reverse plan is +40 kHz and has never been re-examined.
   Interleave the cells (`gate3_pair.sh GATE3_CELLS`) -- this leg drifts far too fast for a
   monotonic sweep, as section 6 shows.
2. **Test 148's transmit side.** It is the one live hypothesis nothing here touches (sec 3.3):
   148's TX feeds only the reverse leg, so a transmit carrier/clock fault is invisible to every
   forward measurement, and the sp3 Gate 3 precedent on this rig was exactly that, with per-arm
   drift. A one-way TXO/RXO pair, or 148 TX scored against a receiver other than 146, would
   separate it from a 146 receive fault. Neither leg of that has been run since the one-way images
   were banked.
3. **Explain the persistent 15 % deficit at the arm gate** (sec 5 item 2). It is present on a leg
   that has just passed its own bring-up and is not the collapse.
4. **Resolve the 0x25C discrepancy** (sec 7): is the bit being cleared by the watchdog's re-arms,
   and does it matter?
5. **The 146 antenna is still unreplaced.** Nothing measured today contradicts it as a contributing
   cause -- it would explain a leg that sits closer to the margin than the forward one -- but today's
   dominant, measurable, one-sided signature is the carrier estimate, and that has a software lever
   (item 1) which has not been tried at this rung.
