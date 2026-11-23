# sp4 Task 12: silicon -- the f3072 / 2 sps pair on air (Gate 3 attempt 1, 2026-09-22)

Plan `docs/superpowers/plans/2026-09-13-2sps-rung.md` Task 12, run on the operator's explicit go
("go ahead with Task 12", 2026-09-22 18:2x) as ONE rig unit:

    ops/launch_rig_unit.sh gate3-sp4-20260922_182559 ops/gate3_pair.sh GATE3_TAG=sp4 GATE3_MD5=5108cdb77aeb GATE3_SOAK=3

Candidate `images/BOOT.BIN.jupiter.sp4.5108cdb77aebb0989c53c65f4a0eac75` (Gate 1 53/53 dev+prod,
Gate 2 WNS 0.794 ns). Rig before the run: both boards on sp3prod `b68dbf1d9321` (roles A/B), 2 MB
dtbs, daemons and watchdogs up, sentinel + keeper units running, no `SENTINEL_STOP`. Rail log and
every capture: `ops/r3cap/gate3_sp4_20260922_182559/` (parked data, not committed). The 146 antenna
was NOT replaced before this run (plan prerequisite for crediting the reverse gate; operator item).

## 1. Deploy chain (steps [1]-[5] of `gate3_pair.sh`), 18:25 .. 18:40

| step | board | result |
|---|---|---|
| [2] dtb `system-qpsk.146.dtb.72d4028d5cbe` | 146 | backup `/boot/system.dtb.preqpsk`, FLASHED, reboot, POST-REBOOT VERIFY PASS, live carve read back **4 MB** |
| [2] dtb `system-qpsk.148.dtb.4c63f54656dc` | 148 | same, VERIFY PASS, live carve **4 MB** |
| [3] `flash_148_txfix.sh` (FLASH_BAK b68dbf1d9321, GOLD=any) | 148 | readback 5108cdb77aeb; **two-pass mode-1 loopback gate ARM_OK x2: fps 1250 / 1249** (floor 1120), capTAP 0x17A5D / 0x17A5A (not constant -> golden stays `any`); ddrcap2 witness sel6: 524288 records, 21 demod marks / 21 tx marks, toff 40 (1.000), slot histogram flat |
| [4] `flash_146_txfix.sh` (FLASH_BAK b68dbf1d9321, RUNG=r4) | 146 | on-board `.bak` verified, readback 5108cdb77aeb; **r4 pair bring-up: both daemons rebuilt `-DQPSK_CARVE_4MB`, pre-flight BIN_OK / carve 4 MB on both, ARM GATE PASS (try 1: 148 rx 1248 f/s, 146 rx 1184 f/s), BRING-UP COMPLETE, watchdogs up; 148 health gate pass 1: fsync 1264, wcnt 2530, 0 resets / 12** |
| [5] | both | `md5sum /boot/BOOT.BIN` = 5108cdb77aeb on 146 and 148 |

So the whole sp4 stack -- 4 MB carve, f3072 host mode (`qpsk_tun -G3 -r 30720`), the 2-sps fabric --
comes up on air and passes every arm-time gate the rails have. The mode-1 loopback rate is the
predicted 1247 f/s (+/-3), i.e. the fabric runs 24634 slots per frame at 61.44 MSPS.

## 2. Gate 3 captures (step [6], `capture_r3.sh` at RUNG=r4, `accept_analyze.py` live-window PER,
lost frames in the denominator; LO plan = the shipped r3 values, 146 RX +40 kHz, 148 RX +20 kHz)

| leg | window | PER (lost/frames) | CP95 UL | loss bins 1 / 2 / 3-4 / 5-20 | wedge |
|---|---|---|---|---|---|
| rev180_1 (148 TX -> 146 RX) | 7 s | UNUSABLE | -- | -- | **collapsed at t+7 s** (before the tap; both receivers silent at the same instant) |
| rev180_2 | 195 s | **20.651 %** (46202/223731) | 20.819 % | 13211 / 10285 / 3336 / 176 | no |
| rev180_3 | 47 s | 21.648 % (8640/39911) | 22.056 % | 2346 / 1902 / 655 / 44 | collapsed at 47 s |
| rev180_4 | 47 s | 21.511 % (8582/39896) | 21.917 % | 2424 / 1901 / 619 / 38 | collapsed at 47 s |
| rev180_5 | 195 s | 21.009 % (47056/223983) | 21.178 % | 13188 / 10622 / 3461 / 165 | no |
| rev180_6 | 184 s | 21.182 % (44641/210754) | 21.357 % | 12471 / 10090 / 3242 / 173 | no |
| fwd180_1 (146 TX -> 148 RX) | 185 s | **0.042 %** (89/211133) | 0.052 % | 51 / 19 / 0 / 0 | no |
| fwd180_2 | 188 s | 0.049 % (106/215325) | 0.060 % | 70 / 18 / 0 / 0 | no |
| fwd180_3 | 188 s | 0.037 % (79/215294) | 0.046 % | 53 / 13 / 0 / 0 | no |
| rev600 | 272 s | 20.968 % (67043/319732) | 21.110 % | 18871 / 15205 / 4793 / 248 | collapsed at 272 s |
| fwd600 | 602 s | **0.047 %** (343/732021) | 0.052 % | 201 / 65 / 4 / 0 | no |

**Verdict of attempt 1: FAIL** -- 4 bad arms of 11 (every one on the reverse leg), reverse PER ~21 %
against the 1 % limit, forward 0.047 % against the 0.01 % limit (r3 sp3prod reference: forward
0.004-0.009 %, reverse 0.008-0.057 %). The soak rounds were not credited (see section 4).

## 3. What the captures say (per-frame telemetry in `frames.bin`: `reg_cfc` 0x154, `reg_rstcs` 0x150)

| leg | detected f/s | crc_ok | carrier resets / s | CFC median | CFC IQR |
|---|---|---|---|---|---|
| rev180_2 | 1198 | 82.60 % | **248** | −772 | [−2433, +2094] |
| rev180_5 | 1198 | 82.17 % | 259 | −769 | [−2436, +2095] |
| rev180_6 | 1198 | 82.08 % | 259 | −838 | [−2489, +2050] |
| rev600 | 1198 | 82.28 % | 259 | −816 | [−2476, +2017] |
| fwd180_1 | 1247 | 99.96 % | **0** | −1369 | [−1841, −809] |
| fwd180_3 | 1247 | 99.96 % | 0 | −1479 | [−1942, −925] |
| fwd600 | 1247 | 99.96 % | 0 | −1500 | [−1964, −950] |

* **Forward leg: healthy.** Full detection rate, zero carrier resets, a CFC median that sits on one
  side of zero with a narrow spread (the r3 forward median was ≈ −3300 at the same +20 kHz; at
  2 sps the estimator's normalised unit halves, so ≈ −1400 is the same physical residual). The
  0.04-0.05 % residual is singles/doubles only, no bursts, 5x the r3 number -- a margin question
  for the 2-sps receiver, not a defect class.
* **Reverse leg: the CFO dead-zone collapse.** CFC median near zero with the IQR straddling it and
  carrier resets at ~250 / s -- exactly the "CFO ≈ 0 dead zone / 0x154 sign-flips / sync collapses"
  signature written into `bringup_r2r3.sh`'s header and the [[cfc-median]] health rule. At
  1198 detected f/s, 250 resets / s destroys ~21 % of frames, which is the measured PER. The
  detection rate itself is also 4 % low (1198 vs 1247: the preamble detector misses frames during
  resets). The full collapses (t+7 s, 47 s, 47 s, 272 s) are the same mechanism reaching the point
  where both receivers stop delivering (the peer's daemon logs `no ENGINE event` re-arms in lockstep).
* **Why r4 and not r3:** the shipped LO plan (+40 kHz on 146's RX) puts the reverse residual at
  −4750 CFC units on r3. The same Hz at twice the symbol rate is half the normalised offset, and
  146's leg lands inside the estimator's dead zone; 148's leg (+20 kHz, −1400 units) does not.
  This is an LO-plan re-characterisation for the rung (foreseen in the plan's "rung
  re-characterisation" items), not a fabric or host defect: the 2-sps model was swept at CFO
  0 / ±0.004 of the symbol rate (`GATE0_SWEEP_2026-09-19.md`), never in the near-zero band the
  silicon dead zone occupies.
* Not the cause: the framelog rotates (97-129 us each); the tap (`CAP_START`/`CAP_END` show frames
  still detected at 1247/s during the IQ window on the arms that did not collapse); the host
  (`tx_stall=0`, no `tun_drop`, the rxresync counters only reflect the CRC failures). The pair.iq
  health scorer's `occupied BW` and `env periodicity` verdicts are f1536-calibrated and were ignored.

## 4. The discriminating cells (20:30 .. 20:48, rig units `losweep-r4-*`, `capture_r3.sh <leg> -d 60 -k` at RUNG=r4)

After `fwd600` the rail's shell was paused (SIGSTOP, so the pair stayed on sp4 with the sentinel
held; the already-launched `soak1_rev600` ran to its end first: 605 s, PER 21.345 % (156979/735439),
same signature), and four 60 s cells were run with the LO plan / steering branch changed:

| cell | detected f/s | crc_ok | carrier resets / s | CFC median | CFC IQR |
|---|---|---|---|---|---|
| reverse, 146 RX LO +80 kHz (1900080000) | 1209 | 82.80 % | 249 | **−5512** | [−5713, −5315] |
| reverse, 146 RX LO +120 kHz (1900120000) | 1209 | 82.64 % | 248 | −8282 | [−8494, −8078] |
| reverse, +80 kHz **and 146 `sro_sign=0`** (R4B branch; `SRO_SIGN 10.0.0.146 wrote=0`) | 1210 | 82.81 % | 247 | −5510 | [−5715, −5307] |
| forward, 148 RX LO +60 kHz (2000060000) | 1247 | 99.84 % | 0 | −4743 | [−5144, −4333] |

* +40 kHz per 40 kHz step = **14.4 Hz per CFC unit at r4** (7.1 at r3): the estimator's unit is
  per symbol, as expected. At +80 kHz the reverse CFC loop is **locked** (tight IQR, one sign) --
  the dead zone is escaped -- and the loss and the reset rate do not move at all.
* The steering branch is not the reset source either: 146 on sro_sign=0 is identical.
* The forward leg does not improve with more offset (99.84 % vs 99.96 % at +20 kHz).

Reset structure on the reverse leg (`rev180_2`, 232906 records; the +80 kHz cell gives the same
numbers): frames carrying a reset fail CRC at **49.7 %**, the frame after at 30.0 %, the frame
before at 10.5 %, and **frames with no reset within ±1 fail at 12.6 %**; increments come 1-4 per
frame in bursts (spacings of 1-2 records and 11-15 records dominate), not on a regular tick.

**Conclusion.** The reverse leg at 2 sps is below the decoder's threshold: a 12.6 % raw CRC failure
floor with the carrier loop locked, and the carrier resets are a consequence (the loop is driven
by the same low-margin symbols), not a cause. The forward leg -- the same fabric, the same host,
the other antenna -- runs at 0.04-0.05 %. On r3 the same two legs run at 0.005 % / 0.05 %, so the
2-sps receiver has less link margin than the 4-sps one and the weaker leg (146's antenna, the plan's
unfulfilled prerequisite) is the one that falls off the cliff. Neither the LO plan nor the steering
branch nor the host is involved. RF readback at the end of the sweep (iio, dBFS: larger = weaker):
148 rssi 30.37 dB / decimated power 23.5 dB at 32 dB gain; 146 rssi 26.60 dB / 21.5 dB at 33 dB gain.

## 5. Rollback and the state of the rig (20:48 .. 21:00)

The paused rail was terminated (its exit trap released `SENTINEL_STOP`; the soak rounds were not
run -- the reverse outcome was already established on 8 arms and 1 200 s of long windows) and the
pair was put back with the new `gate3_pair.sh --rollback-only` (unit `gate3-sp4-rollback-20260922_204848`):
`deploy_image.sh 10.0.0.148 A` then `10.0.0.146 B` (`/boot/BOOT.BIN.gate3` backups, both read back
`b68dbf1d9321`), `restore_known_good.sh` at RUNG=r3 (daemons rebuilt `-DQPSK_CARVE_2MB`, r3 ARM GATE
try 1: 148 rx 1247 f/s, 146 rx 1228 f/s, BRING-UP COMPLETE, watchdogs up). **The 4 MB dtbs stay
deployed on both boards** (they contain the 2 MB carve; the shipped image and host run on them,
verified by this very restore) -- the next sp4 attempt needs `--no-dtb` only.

Rollback health (`health_probe_reset_aware.sh`, 12 s): 148 fsync 1262 / wcnt 1262 / 0 resets
(forward leg healthy); 146 fsync 0 / wcnt 0 / resets 12 of 12 (reverse leg in a reset storm on
sp3prod at r3). The restore's own capture read the reverse leg at 87.2 % crc_ok with 131 resets / s
and CFC −2058 locked (`ops/r3cap/restore_205149`), i.e. the reverse leg is degraded on the SHIPPED
image today, not only on sp4. The delivery sentinel's log settles the timeline: **before any board was
touched** it read at 18:20:10 `rate=1119/s crc=89.9% ... rev=138/s rcrc=15.2%` and at 18:25:15
`rate=1190/s crc=95.6% rev=85/s rcrc=10.4%` (healthy = 1245 / 100 % / rev ≈ 1245); after the rollback
(20:59:08) `rate=1245/s crc=100.0% rev=1091/s rcrc=89.0%`. The reverse leg (148 TX -> 146 RX, the 146
antenna) was already in its episodic RF-degraded class when the run started, and it is in that class
now, with the forward leg back at 100 %. The sentinel keeper relaunched the sentinel at 20:58:54; no
`SENTINEL_STOP` is left behind; `images/CURRENT.txt` roles are unchanged (sp3prod A/B).

## 6. Verdict and what it means

* **Gate 3 attempt 1: FAIL** (4 bad arms of 11, reverse ~21 % vs the 1 % limit, forward 0.047 % vs
  the 0.01 % limit). The sp4 image is NOT promoted; it stays banked.
* **What passed on silicon for the first time:** the f3072 / 2 sps fabric at 61.44 MSPS (mode-1
  loopback 1250 f/s, ddrcap2 witness clean), the 4 MB carve dtbs, the f3072 host mode
  (`-G3 -r 30720`, MTU 3044), the r4 rung rails (pre-flight, rebuild, bring-up, capture provenance),
  the forward leg at 0.04-0.05 % over 1 300 s of windows with zero carrier resets.
* **The reverse leg's ~21 % is a decode-margin floor on a leg that is RF-degraded today** (section 3-5):
  neither the LO plan nor the steering branch changes it; it fails on the shipped image too, though
  less (rcrc 10-15 % before the run, 11 % after). How much of the 21 % is the 2-sps receiver's smaller
  margin and how much the antenna cannot be separated on this rig state: the only clean 2-sps-vs-4-sps
  comparison is the forward leg, 0.047 % vs 0.004-0.009 %, i.e. the 2-sps receiver does cost margin.
* **Next:** (1) replace the 146 antenna (the plan's prerequisite, still open) and confirm the shipped
  reverse leg back at <= 0.06 % before re-gating; (2) then re-run
  `ops/launch_rig_unit.sh gate3-sp4 ops/gate3_pair.sh GATE3_TAG=sp4 GATE3_MD5=5108cdb77aeb GATE3_SOAK=3 GATE3_NO_DTB=1`
  (`--no-dtb --soak 3` at the desk); (3) if the reverse leg still
  fails with a healthy antenna, the margin work is in the model (RRC / Gardner / SSKp at sps 2) and
  needs an SNR-swept closed-loop sim, which the sp4 gates never had; (4) the pair.iq health scorer
  is now rung-aware (`check_capture_health.py --ksym`, window 0.65-1.3x of 1.5 x Rsym: r3 [15, 30] MHz
  unchanged, r4 [30, 59.9] MHz; `capture_r3.sh` passes the rung's KSYM) -- but note that **every
  banked capture since 2026-09-16 (sp3prod, r3) has a DEGENERATE tap**: 2.4-5.8 MHz occupied,
  envelope autocorrelation 0.999 at lag 256/512, the same constant Q offset (3983.5) in every file,
  which was read as a stale DMA buffer. **Chased 2026-09-23 (`TAP_A_BEATOBS.md`): the DMA is fine --
  since the BEATOBS build kit (2026-08-20) every image is built with `QPSK_BEATOBS=1`, and
  `beatobs_overlay.m` rewires debugI1/Q1 = 'IP Data 0/1 OUT' = this DMA channel to a packed
  Rate-Handle state vector.** The tap is a live telemetry stream, not IQ, on every image since sp2; the
  scorer now names it. IQ comes back by building without `QPSK_BEATOBS` (Gate 1 re-run); (5) do not tune the
  LO plan for this class again -- +80/+120 kHz were measured and are inert.

## 7. Gate 3 attempt 2: sp4b (Tap-A on IQ), 2026-09-24 19:05 .. 22:03 (unit `gate3-sp4b-20260924_190553`)

    ops/launch_rig_unit.sh gate3-sp4b ops/gate3_pair.sh GATE3_TAG=sp4b GATE3_MD5=bc9ac1e6b736 GATE3_SOAK=3 GATE3_NO_DTB=1

Rig before: sp3prod both boards, the 4 MB dtbs already live, sentinel reading forward 100 % /
reverse 96.7 % CRC (the reverse leg out of the RF episode it was in on the 22nd). Deploy chain:
148 mode-1 gate ARM_OK x2 at 1249 f/s; 146 rail with the r4 bring-up, ARM GATE PASS (try 2), 148
health gate pass 1 (fsync 1265, wcnt 2530); both boards read back `bc9ac1e6b736`.

**Tap-A carries IQ again** -- the first f3072 capture scores `HEALTHY` (occupied 37.8 MHz inside the
r4 window [30, 59.9], envelope autocorrelation 0.45). First healthy IQ tap since 2026-08-13
(`TAP_A_BEATOBS.md`). Every capture below has a usable `pair.iq`.

**`GATE3_VERDICT sp4b bc9ac1e6b736 rung=r4 bad_arms=6 of 17 long_legs_over_limit=5 -> FAIL`.**
Rolled back to the CURRENT.txt roles; post-rollback health 146 fsync 1268 / wcnt 1268 / 0 resets,
148 fsync 1263 / wcnt 1263 / 0 resets (both clean, unlike the 22nd).

| leg | window | PER (lost/frames) | wedge |
|---|---|---|---|
| rev180_1 | 189 s | **7.849 %** (17030/216980) | -- |
| rev180_2 | 194 s | 0.052 % (117/223693) | -- |
| rev180_3 | 195 s | **7.903 %** (17704/224008) | -- |
| rev180_4 | 194 s | 0.055 % (122/223555) | -- |
| rev180_5 | 107 s | 0.094 % (108/114411) | **aborted at 109 s** |
| rev180_6 | 95 s | 0.151 % (150/99207) | **aborted at 95 s** |
| fwd180_1 | 180 s | 2.448 % (5034/205635) | -- |
| fwd180_2 | 188 s | 3.021 % (6506/215390) | -- |
| fwd180_3 | 160 s | 2.060 % (3717/180423) | -- |
| rev600 | 434 s | 0.048 % (252/523029) | **aborted at 449 s** |
| fwd600 | 176 s | 4.932 % (9902/200766) | **aborted at 191 s** |
| soak1_rev600 | 605 s | 0.052 % (384/735722) | -- |
| soak1_fwd600 | 602 s | 2.310 % (16912/732020) | -- |
| soak2_rev600 | 605 s | **7.929 %** (58340/735762) | -- |
| soak2_fwd600 | 225 s | 5.027 % (13190/262371) | **aborted at 234 s** |
| soak3_rev600 | 605 s | 0.065 % (477/735763) | -- |
| soak3_fwd600 | 507 s | 1.959 % (12009/613116) | **aborted at 520 s** |

Telemetry is uniform across all 17: 1246-1247 f/s detected (the full f3072 frame rate), **zero
carrier resets**, CFC locked on one side of zero. None of the Monday failure modes (dead zone,
reset storms, collapse) appear. The reverse CFC IQR is ~400 units wide, the forward ~950-1050.

### 7.1 The 7.9 % reverse class: a fabric reset clears `sro_sign`, on three paths

Three arms ran at 7.85-7.93 % with one fingerprint: crc_ok 92.1-92.2 %, `lag33` −0.041/−0.042,
delivered-corrupt **pairs** every ~15 frames (spacing histogram 15/14/16 dominant plus 1 = the pair),
zero carrier resets, full detection rate, and `comb_period_ms.py --frame f3072` reporting
`COMB_LINE=absent`. That is the R4B (EMPTY-edge-only) steering signature, and 7.9 % sits between
Gate 1's two R4B points (0.24 % at 2.5 ppm, 22.75 % at 10 ppm), i.e. what R4B would give at a real
inter-board SRO of ~5-7 ppm -- while 146 is supposed to run R4D (`sro_sign=1`).

`bringup_r2r3.sh` writes `sro_sign` (fixctl 0x208 bit 5) as its deliberate LAST step so that no later
reset can clear it. **Any 0x000 fabric soft reset after that point clears 0x208 and nothing re-applies
it.** Three paths reach a 0x000 after the bring-up:

| path | status |
|---|---|
| `capture_r3.sh` wedge-recovery `rearm_byte` (health try 1 empty) | **fixed mid-run**, `f330c572` |
| `capture_r3.sh` `MID_RECOVER` `rearm_byte` | **fixed mid-run**, `f330c572` |
| `lock_watchdog.sh` `full_rearm` -- board-side, nothing in the host log | **fixed now** (`restore_fixctl`) |

The in-run fix is proven: `soak3_rev600` took the wedge-recovery path (health try 1 = 0 %), the
re-apply fired (`SRO_SIGN_RESEED` + `wrote=1`), and the leg scored 0.065 % where the two pre-fix
re-armed arms (`rev180_1`, `rev180_3`) scored 7.9 %.

**Correction to the first reading of this run:** it is NOT true that the 7.9 % arms are exactly the
ones whose health read came up empty. `soak2_rev600` passed health try 1 at 92 % with no
capture-side re-arm at all and still ran 7.929 % with the identical fingerprint -- it was already in
the degraded state when the capture started. The watchdog path above is the candidate (it is
relaunched by the bring-up and only killed at capture step 3, so it owns an unlogged window), but
**this run recorded no evidence either way**: nothing sampled the steering witness. `capture_r3.sh`
now carries `sro_mode` (0x25C) and the fixctl shadow in every `regs_{pre,cap,post}` snapshot, so the
next run either confirms the attribution or shows R4D in force at 7.9 %, which would be a new defect.

### 7.2 The wedge class is the blocker, and the first reading of it was wrong

**6 of 17 windows aborted** (2026-09-22: 4 of 12; sp3prod at r3 on 2026-09-16: 0 of 11), on both legs
and both images. Every one aborts the same way: `capture_r3.sh`'s stall watchdog sees delivery
flatline for 14-16 s and gives up. In every one the daemon flavour is
`rx_queued: no ENGINE event for 3.0s` (the S2MM engine produced no completion) rather than
`completions but NO DELIVERY`, and the counts are dominated by the **peer** board rather than the
captured one.

**But the counts do not discriminate.** Counting the same lines on the legs that did NOT wedge:

| leg | window | peer `no ENGINE event` | local |
|---|---|---|---|
| soak1_rev600 (0.052 %, clean) | 605 s | 224 | 2 |
| soak3_rev600 (0.065 %, clean) | 605 s | 220 | 7 |
| soak1_fwd600 (2.310 %, clean) | 602 s | 223 | 15 |
| rev180_2 (0.052 %, clean) | 195 s | 80 | 0 |
| rev600 (**wedged**) | 434 s | 172 | 11 |
| soak3_fwd600 (**wedged**) | 507 s | 199 | 24 |

That is ~0.37 peer re-arms per second on clean and wedged legs alike -- the peer's RX ring re-arms
continuously at r4 whatever the outcome, so it is a chronic condition of this configuration, not the
wedge trigger. (The peer only receives idle frames during a one-way capture, so a 3.0 s engine
timeout there may be an artefact of the traffic pattern rather than a fault at all.) **The earlier
reading of this section -- that the wedges are a byte-plane ring stall whose lever is RXM / RXQ /
`QPSK_RX_DRAIN_BUDGET` -- is withdrawn: it is not established by this data.**

What would discriminate, all from logs already captured: the time-ordered sequence at the wedge
instant (which side's delivery counter stops FIRST, from the daemons' own timestamps rather than
whole-run totals), the fabric byte counter 0x1C0 across the flatline (frozen = ring, advancing =
host), and whether the flatline coincides with a Tap-A capture or a framelog rotate. None of that
needs a board.

### 7.3 The forward leg: a configuration gap, not (yet) an RF or margin story

`sro_sign` (fixctl 0x208 bit 5) selects the RX steering branch, so the board that governs a leg is
the **receiving** one: forward (146 TX -> 148 RX) is governed by 148. `ops/profiles/sro_sign.conf`
has `148 -> 0`, i.e. **148 runs R4B, by configuration, permanently** -- including through both sp4
Gate 3 attempts. Gate 1 on this very model tree says not to
(`GATE1.md` sec 3a, verbatim): *"The image must run the R4D branch (`sro_sign=1`) on both boards at
this rung (Task 11 note)."* The note was never carried into plan Task 11, and Task 11 shipped without
it.

R4B is sign-asymmetric and steep -- 0.00 % at 0, −2.5 and −10 ppm; **0.24 % at +2.5 ppm; 22.75 % at
+10 ppm** -- while R4D+R1 is 0.00 % across the same sweep. The forward leg measured 0.047 % on
2026-09-22 and 2.0-5.0 % on 2026-09-24. That is one curve, not two stories: it needs only the
inter-board offset to have moved a few ppm positive between the nights (a thermal drift), with no RF
change and no image change -- and it is the same phenomenon as the 7.9 % reverse class in 7.1, on the
other board, arrived at by configuration instead of by a stray reset.

Fixed here without touching the r2/r3 production profile: `ops/profiles/sro_sign.r4.conf` sets BOTH
boards to 1 and `ops/rung_table.sh` selects it for r4 (`SRO_SIGN_CONF`; an explicit value in the
environment still wins). `snap()` now also records `r4_wit` (0x234, the skip/extra census) and
`r4_extras` (0x238) beside `sro_mode`, so the next run records what the steering DID, not only what
was configured.

**Still not established:** whether R4D on 148 actually moves the forward leg to ~0.05 % (the next run
answers it); per-leg SNR (a blind spectral proxy was tried and discarded -- it ranked the 7.9 % arms
*above* the 0.05 % ones, so it measures rolloff and AGC gain, not Es/N0; a real EVM needs matched
filter + timing + decisions on `pair.iq`, which Tap-A now makes possible); and which antenna is weak
(the weak leg flipped between the two runs -- the operator's to resolve on the bench).

### 7.5 Production finding: the shipped rig is running 146 on the wrong branch right now

Read-only on the rolled-back pair, 2026-09-25 15:5x, while both boards run sp3prod at r3:

| board | fixctl shadow (intended) | `sro_mode` 0x25C (in force) | watchdog `FULL RE-ARM`s |
|---|---|---|---|
| 10.0.0.148 | `0x0` | `0x0` | -- |
| 10.0.0.146 | **`0x20`** | **`0x0`** | **59** |

146 is configured for R4D, its shadow says R4D was written, and the register says R4B. The
`lock_watchdog.sh` path in 7.1 is the mechanism and it has fired 59 times on this board; the fix is
committed but **the boards still run the pre-fix copy** (`ops/provision.sh:99` is the only path that
installs it).

**RETRACTED 2026-09-25 -- the performance half of this finding
(`docs/evidence/oneway/ONEWAY_HW_VERIFY_2026-09-25.md` sec 4).** This section originally called the
R4B fallback "a candidate contributor to the shipped reverse leg's persistent `rcrc` ~96-97 %" and
suggested restoring R4D on 146. That is not supported: 146 sat at 96-97 % on R4B for days, and on
2026-09-25 after a power cycle it is at **1266 f/s with 0 reset seconds while running R4D**. Neither
branch is implicated at r3, and both the "R4B is hurting us" and the later "R4D is harmful" readings
were confounded by board 148 failing. **Do not act on a steering change on the strength of this
section.** What stands is the MECHANISM only: a `0x000` re-arm clears `0x208` unnoticed, so the
register and the configuration can silently disagree -- worth fixing (`restore_fixctl`, committed)
and worth recording per capture (`snap()`), independent of any performance claim.

### 7.4 What the two runs do establish

On a healthy arm with the right steering branch, **both legs reach ~0.05 % at r4**: forward 0.047 %
(343/732,021, 2026-09-22) and reverse 0.052 % / 0.065 % (384/735,722 and 477/735,763, 2026-09-24),
against the r3 reference of 0.004-0.009 % forward. Measured on two legs, two nights, two images,
lost frames in the denominator.

So the plan's reverse limit (<= 1 %) is met at r4 whenever the leg is healthy and the steering branch
is right; **the forward limit (<= 0.01 %) is not reachable at 2 sps** with this receiver -- the 2-sps
rung costs roughly an order of magnitude of PER, which is the receiver-margin work item, not a
regression. Gate 3 stays FAIL, `sp4b` stays banked, `images/CURRENT.txt` is unchanged, and no further
silicon run should be scheduled until the wedge class is characterised (7.2) and the steering witness
is on the record (7.1).
