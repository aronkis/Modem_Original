# The latched receiver is the symbol-timing loop pinned on its integrator clamp

RTL simulation, desk, 2026-09-29 19:30-22:00. Verilator, the f3072 (r4, 2 sps) model tree
`modem/rtl_sim/s1_rtl_model`, stimulus bank `sro_sim_f3072/n_p000.iq` (428 clean frames of 49,268
samples, looped), driver `modem/rtl_sim/sim_sro_perturb.cpp` (env-driven perturbations: carrier
offset, offset step, N-frame dropout, fade, AWGN, input gain, rstCS / soft reset at a frame), wrappers
`wrap_byte_sro4b_agc.v` (AGC complex gain tap) and `wrap_byte_sro4b_ss.v` (adds the symbol
synchronizer's loop-filter integrator `u_Loop_Filter.Delay4_out1` and output `Loop_Filter_v`).
Scorer `modem/rtl_sim/perturb_score.py`; runners `run_perturb.sh`, `run_perturb_stages.sh`.

Question from `INTERRUPT_RESPONSE_2026-09-29.md`: a 20 ms pause of the peer's transmit feed left the
live receiver at half detection rate with ~1,200 carrier-sync resets/s for 16 minutes, until a
`0x000`. What state is the receiver in, and why does only a soft reset clear it?

## 1. The failed state, by tap

Healthy frame: 24,634 symbols. Frames 3-8 from cold, and frames after a gap:

| run | frame sync | strobes/frame | SS integrator (sfix30_En23) mean [min,max] | SS `v` (En10) | CFC estimate | correlator peak |
|---|---|---|---|---|---|---|
| baseline, frames 3-8 | 1/frame | 24,190-24,245 | +4,060 [-3,800, +11,000] | 0 [-27, +15] | -140..-180, sd ~60 | 33.6 M |
| +40 kHz from cold, frame 3 | 1 | 23,535 | -182,317 [-436,906, -38,838] | -22.8 | +511 | |
| +40 kHz, frame 4 | 1 | 21,687 | -496,195 [**-503,316**, -417,926] | -61.2 | -1,550 | |
| +40 kHz, frames 5-120 | **0** | 21,678-21,688 | -497,000 [**-503,316**, -470,000] | **-61.4** | ±3,000 two-cluster garbage | 10-12 M |
| 1-frame gap at frame 100, frame 101 | 1 | 22,216 | -401,044 [**-503,316**, +13,398] | -49.6 | -3,661 | |
| 1-frame gap, frames 102-199 | **0** | 21,670-21,697 | -498,500 [**-503,316**, -475,000] | -61.5 | garbage | |
| 5-frame gap, frames 100-104 (silence) | - | 24,634 | 3,722 [3,722, 3,722] (frozen, TED silent) | 0 | 0 | |
| 5-frame gap, frames 124-199 | 1/frame | 24,170-24,230 | +4,050 | 0 | -150..-220 | 33.6 M |

`-503,316 / 2^23 = -0.0600` is exactly the T8.4 `IntegClamp` rail (`timing_hardening_overlay.m`,
2026-07: Saturation ±0.06 inserted between the integrator's Add2 and its delays). With the loop-filter
output at -0.06 the Rice mod-1 counter decrements by 0.5 - 0.06 per sample instead of 0.5, so it
strobes at (0.5 - 0.06)/0.5 = **88.0 %** of the symbol rate: 21,680 of 24,634 (88.0 %). Measured and
predicted agree to four digits. The receiver is resampling the waveform 12 % slow; every downstream
symptom recorded on the rig follows from that -- the preamble correlator peak falls 3x (33.6 M → 11 M)
and never clears its threshold (`ps_rmax` 0), the power-4 coarse estimator sees ISI instead of QPSK
and dithers ±3,000 units, the step detector fires ~10/frame (the storm), CRC is 0 %, and 0x104 still
counts "detections" from noise at roughly half rate.

**Why only `0x000` clears it.** `rstCS` (0x150's detector, and the manual 0x110) resets the *carrier*
synchronizer's loop filter. The symbol synchronizer's integrator is reset by `reset` alone. Sim: the
same 25-frame gap followed by `PERT_RSTCS_AT_FRAME=140` stayed latched for 160 frames;
`PERT_RESET_AT_FRAME=140` re-locked at frame 141 (`run_perturb_stages.sh`). That is the live
finding -- 16 minutes of storm through 11 more pauses, cured by the watchdog's double-tap -- in RTL.

**AGC exonerated.** Tap on `u_Automatic_Gain_Control.Loop_Filter_gain_re/im` (sfix34_En28): magnitude
189.96 M (0.708) in both the healthy and the failed state, angle 0.0°, rotation 0.0°/frame. The AGC
is real-valued and steady; it neither causes nor marks the latch.

## 2. It is an acquisition lottery, not a frequency threshold

Fine offset ladder from cold, 300 frames each (`sweep1-3`), frame syncs in frames 20-300 of 280:

| offset kHz | -200 | -120 | -80 | -60 | -50 | -45 | -42 | -40 | -38 | -35 | -30 | -20 | -10 | -2 | +2 | +10 | +40 | +45 | +80 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| syncs/280 | 280 | 280 | 280 | **0** | **0** | 280 | **0** | **0** | **0** | **0** | 280 | 280 | 280 | 280 | 280 | 280 | **0** | 280 | 280 |

-45 locks between -42 and -50 that do not; +45 locks while +40 does not. Input level at +40 kHz
(`perturb_gain`): ×0.70 fails, ×0.80 **locks** (130/130), ×0.90 fails, ×1.00 fails. Dropout length
after a locked run: 1 frame **latches**, 5 frames recovers, 25 frames latches; with the carrier at
-80 kHz the 25-frame gap recovers, at 0/-10/-40/-200 kHz it does not. Whether the timing loop's
transient after any disturbance (cold start, a gap, a level change) carries the integrator past the
point where the Gardner detector's S-curve still pulls back decides the outcome; past it, the
integrator winds to the rail and the rail is absorbing. The rig's "arm lottery" and the reverse
leg's re-arm ping-pong are this coin.

Interesting but secondary: when the coin lands right the coarse estimator is exact at every offset
(-200 kHz → -13,842 units ≈ -13,653 expected, sd 60), so there is no carrier-frequency limit inside
±200 kHz -- the LO plan's off-null offsets are not fighting a frequency problem.

## 3. What the T8.4 belts did and did not do

`timing_hardening_overlay.m` (three belts, 2026-07): (1) `Interpolation_Control` Delta clamp
±(1/sps - 1 LSB) so the counter always underflows, (2) `IntegClamp` ±0.06 on the integrator,
(3) the P+I → sfix11_En10 conversion saturates. They ended the *permanent strobe stop* (Class-4
wedge). They left an absorbing state one notch inside: strobes 88 % of rate, forever. The overlay's
own comment sizes the steady-state I-term at "~1e-6 -- 60,000x margin"; measured here it is
4.8e-4 (the bank's clock offset), still **125x** below the clamp. A clamp that far from the operating
point protects nothing between the two.

## 4. Live corroboration the same evening (rig, 1850 plan)

Since 13:53 the pair had run the 1850 plan with **zero** fabric resets, watchdog re-arms and
sentinel recoveries for 5.1 h (`RESET_LEDGER_2026-09-29.md`). At 20:10 148's watchdog restarted its
daemon (`BYTE-PLANE WEDGE`/`DELIVERY-WEDGE` path) from `DAEMON_CMD` -- a string that lacked
`chrt -f 50` and `QPSK_RX_QUEUED=1` (bring-up's own `WCMD`, and my `interrupt_response.sh` cleanup,
composed it that way). On the default scheduler that daemon logged `txgap ... gt200us=3-8 max_us=2349
p99_us=3071` per report -- 2-3 ms holes in the transmit feed -- and its RX ran the RXQ=0 host-rate
deficit (sentinel `rate=1172/s` at `crc=100 %`, 94 % of 1245). 146, receiving that feed, then
re-armed **14 times in 1.5 h** (20:10-21:00; `wdlog_10.0.0.146_20260929_2100.txt`), every one from the
latch signature: two windows of `dpkts≈2,600/5 s` (42 % detection) with `drstcs≈5,850/5 s`, never
silence. 146's own daemon (bring-up-launched, `chrt -f 50`) logged `txgap max_us=0`. Command,
sample count: `ops/reset_ledger.py --no-snapshots --live ~/modem-status/wdlog_10.0.0.146_20260929_2100.txt --ip 10.0.0.146`
→ 734 locked windows, 28 storms, 14 re-arms; 148: 772 locked, 0 storms, 2 re-arms (19:56 `dpkts=0`,
20:10 wedge restart).

Fix shipped with this study (`ops/bringup_r2r3.sh`, `ops/lock_watchdog.sh`, `ops/restore_known_good.sh`,
`ops/interrupt_response.sh`, `ops/tests/test_daemon_cmd.py`): bring-up records its exact daemon launch
line on the board (`/dev/shm/qpsk_tun.cmd`, with `chrt -f 50 QPSK_RX_QUEUED QPSK_RX_CYCLIC`) and every
relaunch path -- the watchdog's default `DAEMON_CMD`, its three restart sites (now one
`relaunch_daemon`; the wedge path's bare `eval` ran from the watchdog's cwd where `./qpsk_tun` does not
exist), restore, interrupt_response -- uses it. The bare `setsid lock_watchdog.sh` relaunches in the
capture rails become correct by the same default.

## 5. What this says about the design fix (plan Phase 3)

The carrier-sync reset storm is a *symptom*; the *defect* is a timing loop with an absorbing false
state and no way home. Two changes, both in the symbol synchronizer, both bit-identical in lock:

1. **Bring the integrator clamp down to the physical sample-rate-offset bound.** The integrator holds
   the normalized clock offset; the two Jupiters' 61.44 MHz references are tens of ppm apart, the sim
   bank sits at 480 ppm. A clamp at ±0.002-0.008 (4-16x the bank's offset, 8-30x below today's) bounds
   the strobe deficit at 0.4-1.6 % where the Gardner detector still has a valid S-curve, so the rail is
   no longer absorbing. Section 6 measures this.
2. **Re-centre the timing integrator on frame-sync loss** (the lock state machine): M consecutive
   missed frames → integrator := its last locked value (not zero -- the clock offset is real), one
   `rstCS`. That is the "auto re-acquire" the receiver lacks, and it costs no logic in the locked path.

Widening or narrowing `CFOChangeDetectThreshold` cannot help: the estimator is being fed ISI.

## 6. The clamp experiment: three model trees, five disturbances each

`s1_rtl_model` copied three times with only `Loop_Filter_block.v`'s two `IntegClamp` literals changed
(0.06 → 0.002 / 0.004 / 0.008 = 16,777 / 33,554 / 67,109 En23), same wrapper, driver and stimulus
(`/mnt/onetb/scratch/qpsk-build-trees/perturb_clamp/run_clamp.sh`). Frame syncs counted from frame 8,
excluding the dropout frames; "relock" = frames from the end of the gap to the first of three
consecutive synced frames.

| clamp | baseline identity (cols frame..cfc vs 0.06 tree) | +40 kHz | -38 kHz | -200 kHz | 1-frame gap | 25-frame gap | integrator excursion |
|---|---|---|---|---|---|---|---|
| **0.06** (shipped) | - | **0/112** | 0/280 (ladder) | 280/280 | **93/191, never** | **92/167, never** | pinned at ±503,316 |
| 0.008 | IDENTICAL | 112/112 | 107/112 | 112/112 | 190/191, relock 3 | 165/167, relock 3 | ±67,109 (touches the rail, returns) |
| **0.004** | **IDENTICAL** | **112/112** | **112/112** | **112/112** | **190/191, relock 3** | **165/167, relock 3** | ±33,554 (touches the rail, returns) |
| 0.002 | **DIFFERS from frame 48** | 112/112 | 112/112 | 112/112 | 190/191, relock 3 | 165/167, relock 3 | ±16,777 |

Reading. With the rail at 0.004-0.008 the loop still hits it during the disturbance (the min/max
columns show the clamp value), but a rail at 0.8 % strobe deficit is **not absorbing**: the Gardner
detector still sees a valid S-curve there, pulls the integrator back, and the receiver re-locks
**3 frames (2.4 ms) after a 1- or 25-frame gap** where the shipped design never does. The same +40
and -38 kHz starts that latch the shipped tree lock at every smaller clamp. At 0.008 the -38 kHz
start loses 5 frames during acquisition -- the wider the rail, the longer the excursion. At 0.002
the clamp is inside the locked loop's own excursion (baseline max 17,509 En23 at frame 3-4):
the baseline decode diverges from frame 48 -- the "bit-identical in lock" gate fails. **0.004 is the
choice**: identical baseline, every disturbance survived, 1.9x above the largest in-lock excursion
seen on this bank (a 480 ppm clock offset; silicon's is tens of ppm).

Carrier-sync resets in these runs: 0 in the CFO cases, 2-3 per gap (the estimator steps when the
signal returns) and 0 afterwards -- the storm is gone with the timing latch.

## 6b. The shipped rung (f1536, r3, 4 sps) latches the same way and is cured the same way

Same driver and taps on the sp3prod f1536 RTL tree (`layout2/jupiter_byte_sp3stagesprod_build`,
bank `sro_sim/n_p000.iq`, 49,332 samples/frame, 12,333 symbols), shipped clamp vs a copy with
`IntegClamp` 0.004 (`perturb_f1536/run_ss.sh`, 2026-09-30 00:00-01:50). From cold no offset in
-80..+20 kHz latches at 4 sps; the gaps do:

| run (gap at frame 100) | shipped 0.06 | 0.004 |
|---|---|---|
| baseline | 112/112 | 112/112, **IDENTICAL** (cols 1-10) |
| gap-1, 0 kHz | **LATCHED** (47 syncs after, never 3 in a row) | 189/189, relock 3 |
| gap-1, -40 kHz | **LATCHED** | 189/189, relock 3 |
| gap-25, -40 kHz | **LATCHED**, 149 rstCS after | 215/215, relock 3 |
| gap-25, -80 kHz | **LATCHED** | 213/214, relock 4 |
| gap-25, +40 kHz | 214/214, relock 4 | 215/215, relock 3 |

Trajectory, gap-25 at -40 kHz, shipped: integrator +4,000 → -185,512 one frame after the gap →
**-483,072 [-503,316 pinned]** by frame 160; strobes 12,333 → **9,452 = 76.6 %** =
(0.25 - 0.06)/0.25 at 4 sps; coarse estimate -5,473 → **-209,112** -- the ±200k carrier readings the
live receiver shows in every storm (`INTERRUPT_RESPONSE_2026-09-29.md`) are the estimator on
76 %-timed symbols, not a frequency. With 0.004 the same frame reads integrator 2,562 [-33,554,
+33,554] (touched the rail, came back), 12,324 strobes, estimate -5,470, and frame sync is back two
frames later. **The r3 latch is the same defect, with a wider timing error (24 % vs 12 %) because the
same 0.06 buys twice the fraction of a 0.25 decrement.** The gate table `carrier_lock.legs` targets
the f3072 model tree; for the shipped rung the same rows run with `TREE=<f1536 tree>` and the f1536
geometry (`perturb_f1536/src5/geometry.h`), bank `sro_sim`.

## 7. Phase 3 design, as it stands

1. **`IntegClamp` 0.06 → 0.004** in `modem/dev/simulink/timing_hardening_overlay.m` -- DONE in the
   overlay source (`integClampLim`, convergent: an existing block at another limit is corrected;
   `ops/tests/test_carrier_lock_overlay.py`). Not yet regenerated: HDL Coder is not licensed on this
   desk in batch, the regen runs on the lab hosts. The gate that credits the regenerated tree is
   `modem/gates/carrier_lock.legs` (`modem/rtl_sim/build_carrier_lock.sh` + `perturb_score.py --gate`):
   `cl_identity` (first ten CSV columns of the clean run bit-identical to the shipped-tree baseline kept
   in `qpsk-build-trees/carrier_lock_bank/` -- NOT inside `sro_sim*/`, whose listings are digest-checked
   by every gate run) and `cl_nolatch` (+40 kHz, -38 kHz, -200 kHz, 1- and 25-frame gaps: syncs ≥ 99 % outside
   the window, re-lock ≤ 5 frames). On the 0.004 tree all rows pass; on the shipped tree
   `cl_cfoP40k`, `cl_gap1`, `cl_gap25` fail as LATCHED -- the gate is falsifiable. Run:
   `SRO_SIM_DIR=/mnt/onetb/scratch/qpsk-build-trees/sro_sim_f3072 modem/gates/run_gates.sh --legs modem/gates/carrier_lock.legs`.
2. **Re-centre on frame-sync loss** stays on the list as the second belt for states the sweep did not
   visit (level steps, long fades): M consecutive missed frames → timing integrator := last locked
   value, one `rstCS`. Not needed for anything measured here; design only until the soak says otherwise.
3. **Phase 4 (watchdog policy) is REVISED by the mechanism.** The plan proposed "never re-arm while
   the fabric is still detecting". In the latched state the fabric *is* detecting -- `dpkts ≈ 2,600/5 s`
   (42 %) -- and nothing but a `0x000` gets it back; that rule would have left 146 latched
   indefinitely. The watchdog's current test (`dpkt ≥ 50 AND drst < 100`, two consecutive windows)
   already separates the latch (storm) from a marginal-but-decoding link (small `rstcs` cycling, no
   storm) and is the right cure on the shipped image. Tonight's 14 re-arms were all correct cures
   of real latches whose *cause* was upstream (148's 2-3 ms transmit holes, §4). What remains for
   Phase 4 is a register snapshot (`0x104/0x150/0x154/0x1C0/0x25C`) in the re-arm log line so a
   re-arm can be classified from the log alone; no debounce or backoff change is warranted.

## 8. Open observation, same night (files only)

After the 21:09 restore both watchdogs read 0 NOT-LOCKED / 0 re-arms for the first hour, 148's
`txgap` all zero. From 21:48 148's fabric detection fell from 6,242/5 s to 3,100-4,800/5 s (the
forward leg at 50-77 %, sentinel `rate=688-814/s`) with **0 carrier resets and CRC 100 %** on what it
delivered, recovering slowly (4,800 by 22:13). 146's `txgap` in that window: `empty=44 gt20us=3 max_us=68`
-- microsecond holes, not the millisecond class. Not the latch (no storm, not pinned at 42 %); it is
the forward leg's own plan-independent condition from `GATE3_REVERSE_PLAN_2026-09-29.md`, still open.

Through 01:53 (4.7 h since the restore, `wdlog_10.0.0.14x_20260930_0153.txt`): 146 **0** NOT-LOCKED /
**0** re-arms in 2,573 windows; 148 **1** re-arm at 01:25 -- two windows `drstcs=436 dpkts=5987` then
`drstcs=4194 dpkts=3489` (a storm setting in at 56 % detection: the latch beginning) cured by the
double-tap, 0 wedges, `txgap` all zero on both daemons, both SCHED_FIFO 50. Sentinel 42 samples since
22:21, 5 degraded (all the 21:48-22:3x forward dip), the last 3 h clean. One latch in 4.7 h with the
feed clean is the shipped receiver's own coin (§2); the 0.004 image is what removes it.

## 9. Handoff: from the merged source to a gated image

Everything below the model regen is merged (PRs #77-#81). Not run unattended because the regen's
BD step needs the Vivado host and the desk's batch MATLAB reports no HDL Coder licence, and because
`timing_hardening_overlay.m` saves the shared source model (one writer at a time vs the desktop).

1. **Regen at the shipped rung** (the overlay is convergent, so the existing 0.06 block is corrected):
   `QPSK_FRAME=f1536 QPSK_SPS=4 modem/build_image.sh --tag sp3clamp004 --stop-after gates`
   -- expect `timing_hardening_overlay: IntegClamp limit 0.06 -> +-0.004` in the assemble log, then
   Gate 1 (`model_matrix.legs`) unchanged: the sim says the clean decode is bit-identical.
2. **The no-latch gate on the regenerated tree**: build the f1536 perturbation object against the
   kit's `s1_rtl_model` with the f1536 geometry (`perturb_f1536/src5/geometry.h` beside a copy of
   `sim_sro_perturb.cpp`), then
   `SRO_SIM_DIR=/mnt/onetb/scratch/qpsk-build-trees/sro_sim modem/gates/run_gates.sh --legs modem/gates/carrier_lock.legs`
   with `cl_gap1`/`cl_gap25` at `PERT_CFO_HZ=-40000` added for the r3 rows (§6b) -- every row must
   PASS; the shipped tree fails four of them.
3. **Gate 2 / image**: `modem/build_image.sh --tag sp3clamp004 --from vivado` on the Vivado host;
   WNS gate as usual; bank with an MD5SUMS row.
4. **Gate 3 + soak** on the 1850 plan: `ops/gate3_pair.sh` as for PR #74, then ≥ 4 h with both
   watchdogs (they now log a register snapshot per re-arm) and
   `ops/soak_score.py --since '<start>' --wd 10.0.0.146=<pulled wdlog> --wd 10.0.0.148=<pulled wdlog>`
   -- acceptance is `SOAK_VERDICT PASS` (0 fabric resets in locked windows, 0 storms, 0 re-arms, 0
   recoveries, ≥ 4 h). The shipped image's first soak (21:10-01:56, 4.77 h) reads 146 clean and 148
   one re-arm: FAIL, as the mechanism predicts.
5. Then `docs/bringup.rst`'s dead-zone / off-null note (§165) can be re-tested: with a non-absorbing
   timing rail the +20/+40 kHz plan offsets are no longer load-bearing for lock -- keep them until a
   cell run on the new image says otherwise.

## 10. Silicon: sp3clamp004 (`8503f226395c`) on the pair, 2026-09-30 evening

Both boards flashed from the shipped `b68dbf1d9321` by `ops/gate3_pair.sh` (hwchain unit, log
`ops/r3cap/hwchain_clamp004_20260930_1913/`), 1850 plan, `r3`, KEEP.

**The latch test -- PASS.** `ops/interrupt_response.sh` (RX 146, peer 148's daemon SIGSTOPped
20/100/500/2000 ms, three reps each, interleaved, both watchdogs killed for the run), 21:08-21:25:

| pause | reps | resets during | resets +30 s | seconds to full rate | carrier estimate after |
|---|---|---|---|---|---|
| 20 ms | 3 | 0 / 0 / 0 | 0 / 0 / 0 | 0.2 / 0.2 / 0.3 | -4880..-4617 |
| 100 ms | 3 | 0 / 0 / 0 | 0 / 0 / 0 | 0.8 / 0.8 / 0.9 | -4856..-4637 |
| 500 ms | 3 | 0 / 0 / 0 | 0 / 0 / 0 | 0.9 / 0.9 / 0.1 | -4896..-4612 |
| 2000 ms | 3 | 0 / 0 / 0 | 0 / 0 / 0 | 0.6 / 0.7 / 0.8 | -4855..-4689 |

Shipped image, same instrument, the evening before (`INTERRUPT_RESPONSE_2026-09-29.md`): the first 20 ms
pause latched the receiver -- ~1,200 resets/s, half-rate detection, estimate ±250k -- for 16 minutes
through eleven more pauses, until a `0x000`. On `8503f226395c` twelve of twelve pauses recover in under a
second with zero carrier resets. The defect this document is about is gone on hardware.

**Gate 3 pair -- FAIL on the forward leg, reverse clean.** `gate3_pair.sh` legs (`capture_r3.sh -k`,
`accept_analyze.py`, live window, lost frames in the denominator), 0 bad arms of 11:

| leg | PER | n |
|---|---|---|
| rev180 ×6 | 0.002-0.006 % | 216,708-223,663 each |
| rev600 | **0.006 %** | 46 / 741,812 |
| fwd180 ×3 | 0.820 / 1.257 / 0.853 % | 219,196 / 212,968 / 213,311 |
| fwd600 | **0.933 %** | 6,873 / 736,614 |

Limits fwd ≤ 0.01 % / rev ≤ 1 %. The forward losses are frames the fabric **never detected** (`0x104`
advance == host records on every leg; at each sequence gap `0x104` advanced by 1 while the sequence jumped
2), singles (`'1': 5631, '2': 495, '3-4': 77` of 6,873), one every ~19 frames with no tick structure,
**0 carrier resets** throughout, 148's coarse estimate median −4919 with IQR 1,272 wide (reverse: IQR 62;
the shipped pair's 09-29 Gate 3 forward cells: median −3480, IQR ~170). CRC-bad frames are only 1,047 of
the 6,873 -- the rest are missing. Re-check an hour later on the same pair: fwd **1.082 % (2,304/212,970)**
and **0.855 % (1,825/213,346)**, rev **0.010 % (22/223,459)**.

**Image A/B, step A -- 148 on the shipped image, 146 on the candidate** (`ops/r3cap/fwd_ab_20260930_2142`):
fwd **0.990 % (2,046/206,742)** (second leg wedge-truncated at 1.005 %, 563/56,044), rev **0.003 %
(7/223,560)**. The forward loss does not follow the receiver's image: 148 running the shipped
`b68dbf1d9321` loses the same ~1 % of frames from 146's candidate transmitter as it did on the
candidate. Remaining candidates: 146's transmit path on the new image, or a rig/RF condition on the
forward path (the forward carrier estimate had already moved to −4841 on the **shipped** pair the night
before, during the 21:48-22:35 detection dip, from −3444 at the 13:53 bring-up). Steps B and C
(`ops/r3cap/fwd_ab2_20261001_0018`, sentinel held across the flashes -- the first attempt was voided
by a flash without the hold; the sentinel ran its own recovery bring-up, recorded as a trap):

| pair (148 RX image / 146 TX image) | fwd leg 1 | fwd leg 2 | rev leg | 148 carrier est. median / IQR |
|---|---|---|---|---|
| candidate / candidate (Gate 3, 19:30-21:08) | 0.820 % (1,797/219,196) | 1.257 % (2,678/212,968) | 0.006 % (46/741,812) | -4919 / 1,272 |
| candidate / candidate (re-check 21:33) | 1.082 % (2,304/212,970) | 0.855 % (1,825/213,346) | 0.010 % (22/223,459) | -5056 / 1,292 |
| **shipped** / candidate (A, 22:00) | 0.990 % (2,046/206,742) | 1.005 % (563/56,044, wedge-truncated) | 0.003 % (7/223,560) | -5054 / 1,320 |
| **shipped / shipped** (B, 00:19 -- the control) | **1.250 % (2,677/214,208)** | **1.510 % (3,233/214,090)** | 0.008 % (18/223,776) | -5012 / 1,403 |
| candidate / candidate (C, 00:48) | 1.206 % (2,578/213,782) | 1.039 % (2,217/213,456) | 0.004 % (8/216,705) | -5154 / 1,305 |
| shipped / shipped, 2026-09-29 11:50 (Gate 3 cells) | 0.019-0.022 % ×5, 0.159 % ×1 | | | -3480 / ~170 |

**Conclusion: the forward-leg loss is a rig condition, not the image.** The shipped pair reads 1.25-1.51 %
tonight on the same plan where it read 0.02 % yesterday morning; the candidate pair reads the same ~1 %;
swapping the receiver's image changes nothing. What did change on the forward path is the carrier
residual at 148 -- median -3480 → -5000 (≈ -11 kHz at 7.3 Hz/unit, so 146's transmit carrier moved) and
its dither IQR 170 → 1,300 -- while the reverse residual sits at -4770 ± 35 as it did yesterday. The
loss is undetected single frames with 0 carrier resets on either image; it is the forward leg's own
plan-independent condition from `GATE3_REVERSE_PLAN_2026-09-29.md` (0.02 % with host stalls then,
1 % tonight), and it needs its own study (146 TX carrier / 148 RX antenna -- the element the 09-08
swap identified as bad is on this leg). It does not bear on the carrier-lock fix, whose own test
(the latch) passes and whose reverse leg is 0.003-0.010 % on every row.

Carrier resets and re-arms through all of this: watchdog logs 21:25-00:15 (candidate pair until 22:24,
then shipped): 146 **0** NOT-LOCKED / 0 re-arms in 973 windows; 148 **0** / 0 in 983 windows. The 4 h
soak on the candidate pair (`fwd_ab2_20261001_0018/soak/status.txt`, from 01:14) is scored in §11.

## 11. Silicon: the 4 h soak on the candidate pair -- PASS

`ops/soak_pair.sh HOURS=4 INTERVAL_S=600` (`ops/r3cap/fwd_ab2_20261001_0018/soak/status.txt`), both boards
on `8503f226395c` from 00:48, watchdogs up (recorded-launch daemons, `chrt -f 50`), degraded trigger
armed, 1850 plan, idle byte traffic. Window 2026-10-01 01:14 → 05:15 = 4.03 h, 25 ticks, every tick
clean:

| board | 5 s windows | locked | locked windows with resets | fabric resets in locked windows | NOT-LOCKED | storms | FULL RE-ARMs | daemon relaunch / wedge |
|---|---|---|---|---|---|---|---|---|
| 146 | 2,188 | 2,188 | 0 | 0 | 0 | 0 | 0 | 0 |
| 148 | 2,175 | 2,175 | 0 | 0 | 0 | 0 | 0 | 0 |

Sentinel 48 samples, 0 zero-rate, 0 recoveries. `SOAK_VERDICT PASS` -- the plan's acceptance target
(0 fabric resets outside arms, 0 re-arms, 0 recoveries, ≥ 4 h) met on the candidate image. The shipped
image's own soak the night before (§8, 9.55 h) carried one latch/re-arm on 148; the candidate's two
soaks (22:25-00:15 on the mixed/shipped pair, 01:14-05:15 on the candidate pair) carry none, and the
latch instrument (§10) is the direct evidence that the mechanism is removed.

**Status of the carrier-lock fix.** Design proven (RTL, both rungs), gated (Gate 1 identical set on the
f1536 harness, no-latch gate 7/7, Gate 2 WNS 1.187), on hardware: latch test 12/12, reverse leg
0.003-0.010 %, soak PASS. The forward leg's ~1 % is a separate, image-independent rig condition (§10).
`images/CURRENT.txt` is the operator's edit; the pair is left on the candidate.
