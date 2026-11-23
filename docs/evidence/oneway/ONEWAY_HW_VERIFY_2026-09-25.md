# One-way (TX-only / RX-only) silicon re-verification, 2026-09-25 -- forward PASS, reverse CONFOUNDED

Question asked: do the banked single-sided builds still work with good PER on the rig?
Run: `ops/launch_rig_unit.sh oneway-verify-20260925_164240 ops/oneway_hw_verify.sh MODE=both DWELL=120
BYTE=1 TUN=1`, 16:42-17:08. Log `/mnt/onetb/scratch/qpsk-build-trees/oneway/hw_verify_20260925_164240.log`.
Images md5-verified against `images/MD5SUMS` before the run and **byte-identical** to the ones that
passed on 2026-09-15: TXO `8126659ac9c6`, RXO `8affa3e59582`.

**Short answer: the forward direction reproduces the 2026-09-15 baseline exactly. The reverse
direction measured badly, but board 148 -- the transmitter on that leg -- was failing during the
measurement and hung outright ~20 minutes later, so the reverse number is NOT a verdict on the
images. After a power cycle both legs are clean.**

## 1. Results against the 09-15 baseline (same metrics, same script)

| phase | forward 146 TX -> 148 RX | 09-15 fwd | reverse 148 TX -> 146 RX | 09-15 rev |
|---|---|---|---|---|
| arm gate | PASS try 1, 1246 f/s | try 1, 1247 | PASS try 1, 1248 f/s | try 2, 1248 |
| ROM 120 s frames / lost | 151758 / **0** (PER_est 0.000 %) | 151756 / 0 | 152208 / **0** (PER_est 0.000 %) | 152276 / 0 |
| ROM window BER (first 120 bits) | **0.00000 %** | 0.00000 % | **15.42088 %** | 0.00491 % / 0 |
| byte 60 s frames scored / lost | 74709 / **0** | 74712 / 0 | 54095 / **20605 (27.6 %)** | 74714 / 0 |
| byte bit errors (BER) | 873 (1.143e-05) | 0-3 (3.9e-08) | 27921 (1.178e-03) | 0-3 |
| tun 60 s lost / sent (PER) | 80 / 34091 (0.235 %) | 13 / 34091 (0.038 %), 09-17 | 22940 / 34091 (67.3 %) | -- |

Denominators are the script's own: ROM = 1245 f/s x reset-free seconds with lost frames counted
(0 reset seconds on both legs); byte = `frames_scored` against 1245 f/s x 60 s with lost counted;
tun = client `tx_pkts` minus server `rx_pkts`.

Per-leg steering, from the run log: forward RX was 148 on R4B (`wrote=0 readback_mode=0x0`), reverse
RX was 146 on R4D (`wrote=1 readback_mode=0x1 edge=FULL`) -- the configured values for each board.

## 2. Why the reverse leg does not count

Timeline:

| time | event |
|---|---|
| 16:55-17:02 | reverse leg measured (148 transmitting) |
| 17:07 | restore bring-up: **`SRO_SIGN 10.0.0.148: FIXCTL_WRITE_FAILED`** and `SRO_SIGN_CHECK 10.0.0.148 UNKNOWN reason=reads_failed valid=0 wanted=10` -- 0 of 10 register reads on 148 returned a value |
| 17:08 | restore health: 148 fsync 1263 (its own RX fine), **146 fsync 478** (i.e. 148's transmit into 146 already collapsing) |
| ~17:2x | 148 stopped answering ping entirely |
| 17:31 | confirmed hung, no recovery; `SENTINEL_STOP` placed |
| ~20:05 | operator power-cycled 148 |

So the board transmitting on the reverse leg was already failing its own register interface five
minutes after that leg was measured, and was gone twenty minutes later. The transmit-side daemon
counters during the leg looked normal (`tunA_rx=34096`, `dma_tx=105872`, `crc_drop=0`, `tx_stall=0`),
which is consistent with a fabric/PHY-side degradation the host could not see.

**The reverse leg therefore needs re-measuring on healthy hardware before any conclusion is drawn
about the RX-only image or about 146's receive path.**

## 3. Post-reboot state (the control)

`ops/bringup_r2r3.sh r3` with the sentinel held, 20:07-20:09: arm gate PASS try 1 (148 rx 1246 f/s,
146 rx 1248 f/s), watchdogs alive both, and the steering write landed on **both** boards
(146 `readback 0x1`, 148 `readback 0x0`) where it had failed on 148 before the reboot.
`health_probe_reset_aware.sh`, 12 s each:

    10.0.0.148: fsync=1263 wcnt=1263 resets_s=0/12 clean=12/12
    10.0.0.146: fsync=1266 wcnt=1266 resets_s=0/12 clean=12/12

Both legs at full rate with zero reset seconds -- including 146 receiving at 1266 f/s while running
R4D. That is the cleanest reading of this pair in the recent record.

## 4. Two claims from earlier the same day that this run RETRACTS

* **"146 running R4B in production is a degradation contributor"** (`docs/evidence/sp4/SILICON.md`
  sec 7.5) -- not supported. 146 sat at 96-97 % CRC on R4B for days, and is now at 1266 f/s clean on
  R4D. Neither branch is implicated at r3. The 7.5 observation that a `0x000` re-arm clears `0x208`
  unnoticed still stands as a mechanism; the performance claim attached to it does not. **Do not act
  on the "restore R4D on 146" suggestion in 7.5 on the strength of that section.**
* **"R4D on 146 is harmful"** -- the opposite suspicion, raised mid-run when the reverse leg was bad
  and 146 was the R4D board. Also not supported: 146 is on R4D and clean now. Both readings were
  confounded by 148's failure.

## 5. Operational note -- how 148 was hung (self-inflicted)

At 17:10:26 the delivery sentinel independently detected a wedge and started its own recovery chain,
which arms both boards. At the same moment a scheduled settle-measurement issued
`direct_reg_access` reads on both boards. That is the documented hazard verbatim (register traffic
racing board state, arms being the worst instance) and 148 hung. No software path recovers a board
that does not answer ping -- Jupiter has no remote power -- so it took a physical power cycle.

**Rule reinforced:** take `SENTINEL_STOP` *before* any measurement that reads registers, not just
before flashing, and never leave a timer that can fire register reads while an automatic recovery
may be running. The post-reboot bring-up in section 3 was done under a held sentinel and was clean.

## 6. Second run, on healthy hardware (20:17-20:43, unit `oneway-rev-20260925_201732`)

Same command, `MODE=both` so the forward leg serves as an in-run control. Boards power-cycled and
re-armed clean beforehand (sec 3).

| phase | forward 146 TX -> 148 RX | reverse 148 TX -> 146 RX | 09-15 baseline |
|---|---|---|---|
| arm gate | PASS try 1, 1246 f/s | PASS try 1, 1246 f/s | try 1-3 |
| **ROM** 120 s frames / lost | 151759 / **0** (PER 0.000 %) | 149654 / **0** (PER 0.000 %) | 0 lost both legs |
| ROM window BER, reset s | 0.00000 %, 0 | 0.25438 %, 2 | 0.00491 % / 0, resets 4 / 0 |
| **byte** 60 s scored / lost | 74718 / **0** | 22973 / **51727 (69.2 %)** | 74712-74720 / 0 |
| byte aligned, bit errors | 74653, 82 (1.07e-06) | **0 aligned**, 0 bits compared | 74708-74710, 0-3 |
| **tun** 60 s lost / sent | 86 / 34091 (**0.252 %**) | 2253 / 34091 (**6.609 %**) | 13 / 34091 (0.038 %) |

### 6.1 The RF path is fine; the byte plane on 146 is not

The reverse leg's ROM phase -- the fabric's own source, same RF path, same demodulator, 120 s --
delivered **149,654 frames with zero lost**. Minutes later on the same leg the byte-source phase lost
69 % and aligned nothing. ROM and byte differ only in where the payload comes from (fabric ROM vs the
host byte plane over DMA), so this isolates the fault to the **byte plane**, not to RF, not to the
antenna, and not to the demodulator. It also retires the reading from run 1 that "the loss is on
146's receive path" in the RF sense.

The mode dependence points the same way. The tun phase forces the RX-only daemon to legacy
per-packet capture (`-M 0`) because of the 2026-09-17 finding recorded above -- on the RXO image the
queued 16-packet mode "decoded idle frames but failed every DATA frame's CRC", never root-caused.
The byte phase carries no such mitigation. On 146: byte 69 % lost, tun (with the mitigation) 6.6 %.
On 148 the same byte phase is clean (0 lost). So the defect is **board-asymmetric and mode-sensitive,
and it is not fixed by `-M 0` -- only reduced** (6.6 % on 146 against 0.25 % on 148).

This is the same not-root-caused interaction the 09-17 note describes (the RXO image's byte-plane pad
is 2 deep where the full image's is 4, and the multi-packet path locates frames by scanning the
landing buffer), now with two new facts: it is far worse on 146 than on 148, and legacy mode only
mitigates it.

### 6.2 An instrument that reported a confident number from no data

The reverse byte phase printed `bit_errors=0 BER=0.000e+00` while `aligned(clean+noisy)=0` and
`total_bits=0` -- zero bits were compared. A reader skimming the BER column would record a perfect
result for the worst leg of the run. This is exactly the failure class in
`docs/superpowers/plans/2026-09-25-rig-instability.md` Task 7: a scorer must be able to say it does
not know. `oneway_measure.sh` should emit `BER=UNKNOWN (0 frames aligned)` when the denominator is
zero.

### 6.3 Verdict on the question asked

**Do the banked single-sided builds still work with good PER on the rig?**

* **Forward 146 TX -> 148 RX: YES.** Reproduces the 09-15 baseline on both runs today -- ROM
  151,758/151,759 frames with 0 lost and 0.00000 % window BER, byte 74,709/74,718 scored with 0 lost.
  Residual differences from September are small and stable: byte bit errors 82-873 against 0-3, tun
  0.235-0.252 % against 0.038 %.
* **Reverse 148 TX -> 146 RX: PHY yes, byte plane no.** The air path carries 120 s of ROM frames with
  zero loss, but the host byte plane loses 69 % (default mode) or 6.6 % (legacy mode) on this board.
  That is a real, reproducible defect in the RX-only image's byte plane on 146 -- not RF, and not the
  transient 148 failure that contaminated run 1.

## 7. What would finish the job

* Root-cause the RXO byte-plane interaction (the open 09-17 item), now with the extra constraints
  from 6.1: board-asymmetric, present in legacy mode, absent on the ROM source. The RXO image's
  2-deep byte-plane pad versus the full image's 4 is the documented suspect and is checkable in
  simulation without a board.
* Fix `oneway_measure.sh` to report `UNKNOWN` rather than `BER=0` on a zero denominator (6.2).
* Both are desk work. Neither needs the rig.
