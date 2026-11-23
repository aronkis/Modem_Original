# The first triggered capture of a reverse-leg episode (2026-09-27 09:15)

`ops/degraded_trigger.sh` fired unattended at 09:15:56 and `ops/degraded_capture.sh` captured the
reverse leg for 300 s while the episode was still running. This is the mechanism proposed in
`REVERSE_LEG_AVAILABILITY.md` sec 6 doing its job on real data for the first time.

Record: `ops/r3cap/degraded/episode_20260927_091556/`. Both boards were on the shipped sp3prod image
at r3 throughout; no flash, no image change.

## 1. It caught the episode rather than its aftermath

    episode_state=STILL DEGRADED (reverse PER 13.594% >= 5%) -- the episode was captured

That was the open worry: the capture's own bring-up re-arms both boards and could have cleared what
it was sent to observe. It did not. Reverse leg over the live window, lost frames in the
denominator (`accept_analyze.py`):

    PER = 13.594 % (49099 / 361169)   CP95UL = 13.707 %   live 305 s of 314 s [WEDGE truncated]
    bins = {1: 18377, 2: 6453, 3-4: 2457, 5-20: 1204, 21-100: 28, >100: 0}
    delivered 1138 f/s against a 1245 f/s nominal;  CRC ok 92.63 %;  1 wedge during the capture

## 2. What the episode is NOT

**Not the CFO dead zone.** `reg_cfc` median −3688 with 9.35 % of frames above zero (`cfc_cells.py`)
-- a normal reverse-leg band, nowhere near the null. Whatever this is, it is not the acquisition
mechanism of `sp4/ACQUISITION_COLLAPSE.md`.

**Not a collapse in received signal level.** `meta.txt` records rssi 32.893 dB on the receiving board
and 32.429 dB on the peer, with gain 34 dB on both. These readbacks are dB BELOW full scale, so
larger is weaker, and 32-33 dB is the ordinary healthy level for this rig -- the same 32.9 dB read at
14:15 the previous day on a link delivering 100 % CRC. The receiver was hearing its peer at normal
strength while dropping one packet in seven.

## 3. The onset is a RATE deficit that precedes the CRC damage

From the 20 samples the trigger recorded before firing (reverse rate, reverse CRC):

| time | rev f/s | rcrc |
|---|---|---|
| 08:29 .. 08:49 | 1245-1868 | 100.0 % |
| **08:54** | **696** | **100.0 %** |
| 08:59 | 713 | 100.0 % |
| 09:04 | 722 | 100.0 % |
| 09:09 | 844 | 100.0 % |
| 09:15 (fired) | 706 | 96.8 % |

The delivered rate halves at 08:54 and stays halved for about twenty minutes **while every received
frame still passes CRC**. CRC only starts failing at 09:15. An RF degradation would be expected to
corrupt frames first; here frames stop arriving first and corruption follows.

## 4. What that does and does not license

The loss structure in section 1 is singles-and-doubles dominated (18377 singles, 6453 doubles, 28
events of 21-100), which is the shape this project has previously localised to the DELIVERY plane
rather than to the air -- the forward comb of 2026-08-27 was `ByteRxFifo` overflow at transfer
boundaries, not RF. Sections 2 and 3 are consistent with that reading for this episode.

**This does NOT exonerate the 146 antenna, and it is not a retraction of that diagnosis.** Three
reasons to hold back: rssi is an average level and an antenna fault can wreck pattern or match
without moving it; the antenna attribution came from a swap experiment, which is stronger evidence
than any single capture; and 7.4 % of received frames DID fail CRC here, which is air or PHY damage,
not delivery loss. The honest statement is that **this episode has a rate-deficit onset and a
delivery-plane loss shape, with normal signal level and normal carrier estimate**, and that does not
fit a simple "weak antenna" story on its own.

**The discriminator that would settle it** is a PHY-only measurement, scoring the fabric's own
counters and bypassing the byte plane, DMA and host entirely. **CORRECTION (2026-09-27): I described
this as "already in the toolbox" and it is not.** `rom_air_ber.sh` was retired in the 2026-09-09
cleanup and survives only at `archive/pre-cleanup-2026-09-09:two_jup/comb/rom_air_ber.sh`; nothing of
that name exists in the current tree or on disk. The claim came from a memory citation I did not
verify against the repo. It needs porting to the current rails before it can be run. If air BER is clean while host PER is
13 %, the loss is downstream of the demodulator and the antenna is not the agent for this episode.
If air BER is bad, it is the air. Wiring that as a second action is the obvious next step and is not
built.

## 5. Trigger behaviour, and one thing tuned

It fired once and then held its 6-hour cooldown, as designed. The stand-down lines in
`trigger.log` immediately after the capture are correct, not a fault: `capture_r3.sh` holds
SENTINEL_STOP, so the sentinel legitimately stops logging and its last sample ages past the
freshness bound.

`FRESH_S` raised 700 s -> 900 s on measurement: the sentinel's inter-sample interval is median 305 s
and p99 318 s over 3059 intervals since 09-16, so 900 s is nearly 3x nominal while remaining far
below the roughly 2400 s gap a dead sentinel plus keeper restart produces. At 700 s, 0.52 % of
samples read as stale; at 900 s, 0.16 %.

## 6. Retuned the same afternoon: the rule had the wrong SHAPE

At 13:10-13:46 the link was plainly degraded -- reverse CRC down to 48 %, the reverse rate bouncing
between 257 and 1104 f/s -- and the trigger correctly did nothing, because the ratio ran

    0.91  0.90  0.94  0.40  0.89  0.81  0.58  0.60  0.21  0.66

and never gave five consecutive samples below 0.5. The debounce was right in spirit and wrong in
shape: real episodes fluctuate, and one good sample reset the count.

Rules simulated over 2719 quiet samples spanning 10.9 days, with the same 6-hour cooldown applied:

| rule | fires | per day |
|---|---|---|
| below 0.50, 5 of 5 | 7 | 0.64 (the original) |
| below 0.75, 5 of 5 | 10 | 0.91 |
| **below 0.75, 4 of 5** | **11** | **1.01** (now the default) |
| below 0.75, 3 of 5 | 15 | 1.37 |
| below 0.75, 2 of 3 | 19 | 1.74 |

Now `MIN_BAD=4` of `CONSEC=5` below `THRESH=0.75`. Two reasons for 0.75 rather than 0.5: it catches
the 09-27 stretch above, and it is the threshold the availability measurement itself uses to define
"degraded" (`REVERSE_LEG_AVAILABILITY.md` sec 2), so the trigger and the measurement now agree on
what the word means.

**The cost is explicit: about one unattended board arm per day, up from one every day and a half.**
That is a real increase in the risk the record-only default originally existed to avoid. It reverts
to the old behaviour with `THRESH=0.5 MIN_BAD=5` in the unit's environment, no code change.

## 7. A second triggered capture the same afternoon, and it decouples the carrier loop entirely

The retuned rule fired at 13:55:56 and captured again. Two independent triggered captures of reverse
episodes on the same image and the same day:

| capture | PER (live) | CRC ok | delivered | CFC median | CFC > 0 | receiver rssi | wedges |
|---|---|---|---|---|---|---|---|
| 09:15 | 13.594 % (49099/361169) | 92.63 % | 1138 f/s | −3688 | 9.35 % | 32.893 dB | 1 |
| 13:55 | **18.331 % (66892/364913)** | 89.38 % | 1119 f/s | **−4780** | **0.51 %** | 32.432 dB | 1 |

Loss shape, both singles-and-doubles dominated, with a heavier tail the second time:
09:15 `{1: 18377, 2: 6453, 3-4: 2457, 5-20: 1204, 21-100: 28}`,
13:55 `{1: 22096, 2: 7988, 3-4: 4830, 5-20: 1877, 21-100: 6}`.

**The second capture had a textbook-healthy carrier estimate and the WORSE packet error rate.** A
median of −4780 with 0.51 % of frames above zero is the healthy reverse-leg signature this project
recorded long ago (healthy reverse median about −4730 to −4760); the estimator was not dithering, not
near the null, not drifting. And PER was 18.3 %, five points worse than the 09:15 capture whose CFC
was less tidy. Whatever drives these episodes, **it is not carrier tracking** -- the two move in
opposite directions.

Received level was normal in both (32.4 and 32.9 dB below full scale, gain 34 dB, against a healthy
rig norm of 32-33), so it is not a level collapse either. Both captures hit exactly one wedge, which
looks like a separate event class rather than the degradation itself.

**Where that leaves the reverse leg.** Two things are now measured rather than argued: the episodes
are not explained by the carrier loop, and they are not explained by received signal level. What
remains is either damage on the air that does not show up as level (interference, pattern or match
problems from the known-bad antenna) or loss downstream of the demodulator in the delivery plane.
10.6 % of received frames failed CRC in the second capture, which is real frame corruption and does
point at the air side; the singles-and-doubles shape points at the delivery plane. Those can both be
true at once, and the split is exactly what a PHY-only measurement resolves. See the correction in
sec 4: the instrument that does this is NOT in the tree, only in the pre-cleanup archive tag, and
has to be ported first. It needs a degraded window, which this trigger now supplies roughly once a
day. That is the next experiment.
