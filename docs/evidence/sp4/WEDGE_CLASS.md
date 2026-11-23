# The r4 wedge class: the radio never stops, the delivery path does

Plan `docs/superpowers/plans/2026-09-25-rig-instability.md` Task 5 (I2) -- the blocker for the sp4
rung. Desk work only, from logs already on disk
(`ops/r3cap/gate3_sp4b_20260924_190553/<leg>/`, 17 legs). Tool: `ops/wedge_forensics.py`.

## 1. What a "wedge" is here

`capture_r3.sh` aborts a leg when delivery to the host flatlines for 12+ s (`MID_CAPTURE_WEDGE`).
**6 of 17 legs aborted on 2026-09-24** (3 of 7 forward, 3 of 10 reverse); 4 of 12 on 2026-09-22;
**0 of 11** for sp3prod at r3 on 2026-09-16. It is the single thing blocking the rung: a campaign
whose windows abort a third of the time cannot produce a credible PER table.

## 2. The measurement

`regs_pre.txt` and `regs_post.txt` bracket each leg with the fabric's own counters -- 0x104 detected
frames and 0x150 carrier resets -- so the detection rate ACROSS the flatline is recoverable without
any new instrumentation.

| leg | wedged | fabric detections/s | carrier resets (whole leg) | host delivery stopped | stall onset | Tap-A window | TX pumping |
|---|---|---|---|---|---|---|---|
| fwd180_1 | no | 1234 | 1 | 174 s | 69 s | 1 s | yes |
| fwd180_2 | no | 1246 | 0 | 182 s | 73 s | 1 s | yes |
| fwd180_3 | no | 1089 | 2 | 154 s | 88 s | 1 s | yes |
| **fwd600** | **YES** | 1102 | 2 | 170 s | 84 s | 1 s | yes |
| rev180_1 | no | 1246 | 0 | 182 s | -- | 1 s | yes |
| rev180_2 | no | 1247 | 0 | 188 s | -- | 1 s | yes |
| rev180_3 | no | 1246 | 0 | 188 s | -- | 1 s | yes |
| rev180_4 | no | 1247 | 0 | 188 s | -- | 1 s | yes |
| **rev180_5** | **YES** | 1017 | 7 | 100 s | 109 s | 1 s | yes |
| **rev180_6** | **YES** | 975 | 0 | 88 s | 98 s | 1 s | yes |
| **rev600** | **YES** | 1181 | 0 | 428 s | 438 s | 1 s | yes |
| soak1_fwd600 | no | 1246 | 0 | 596 s | 88 s | 1 s | yes |
| soak1_rev600 | no | 1247 | 0 | 598 s | -- | 1 s | yes |
| **soak2_fwd600** | **YES** | 1157 | 1 | 219 s | 74 s | 1 s | yes |
| soak2_rev600 | no | 1246 | 0 | 598 s | -- | 1 s | yes |
| **soak3_fwd600** | **YES** | 1194 | 0 | 501 s | 84 s | 1 s | yes |
| soak3_rev600 | no | 1247 | 0 | 598 s | -- | 1 s | yes |

## 3. RETRACTED: "the radio never stops" -- the measurement below refutes it

**This section originally concluded, from the table above, that the fabric keeps detecting frames
through the flatline and therefore the failure is the byte plane. That conclusion was unsound and is
now refuted by direct measurement (sec 3a).** The detection rate in the table is a whole-leg average
between `regs_pre` and `regs_post`, i.e. over 170-600 s of which the flatline is 16 s. An average
dominated by the healthy minutes cannot say what happens during the stall; it was never evidence
about the stall at all. The parts of the table that DO stand, because they are whole-leg facts:
carrier resets total 0-7 per wedged leg, the transmitter's `dma_tx` was still advancing on all 17,
Tap-A coincidence is 0 of 6, and the framelog rotate precedes every leg.

## 3a. Measured INSIDE the flatline (2026-09-26, three wedges)

`capture_r3.sh`'s stall poll now samples the fabric counters at each stalled poll (`STALL_REGS`).
Three forward legs at r4 wedged; every sample is taken while the host is receiving nothing:

| leg | at | bytewords 0x1C0 | pkts 0x104 | rstcs 0x150 |
|---|---|---|---|---|
| fwd300_1 | 11 s | 0x27B746C | 0x1A9DB | 0 |
| fwd300_1 | 17 s | 0x27B746C | 0x1A9DB | 0 |
| fwd300_1 | 22 s | 0x27B746C | 0x1A9DB | 0 |
| fwd300_2 | 40 s | 0x1C65A0E | 0x1307D | 4 |
| fwd300_2 | 45 s | 0x1C65A0E | 0x1307D | 4 |
| fwd300_2 | 51 s | 0x1C65A0E | 0x1307D | **6** |
| fwd300_3 | 21 s | 0x1536B02 | 0xE377 | 0 |
| fwd300_3 | 27 s | **0x1536C80** | **0xE378** | 0 |
| fwd300_3 | 32 s | 0x1536C80 | 0xE378 | **2** |

**The frame detector stops, and the byte plane tracks it exactly.** `pkts` -- the fabric's own
detected-frame counter -- freezes together with `bytewords`. It is not a stale read: `rstcs`
increments during two of the three stalls (4 -> 6, 0 -> 2), and `cfc`/`r4_wit` moved across the same
windows in `regs_pre`/`regs_post`, so the register interface is live throughout.

`fwd300_3` is decisive about the byte plane. Between the 21 s and 27 s samples the counters advanced
by **exactly one frame**: `bytewords` +0x17E = **382**, `pkts` +1. 382 is precisely
`cfg.WordsPerPacketRx`, the f3072 delivered word count per frame. The byte plane forwarded exactly
what the demodulator produced -- one frame in six seconds instead of ~1247 per second. **It is
starved, not blocked.** A backpressured ring would hold `bytewords` still while `pkts` kept climbing;
the opposite of what is measured.

So a wedge is an **acquisition collapse on the receive side**: frame detection falls to ~0.2/s from
1247/s, the carrier loop cycles (`rstcs` ticking), and the byte plane faithfully delivers the nothing
it is given. The host-side symptom -- `dma_rx_ok`, `crc_drop` and `idle_rx` all frozen while the
peer's `dma_tx` advances -- follows from that and needs no separate explanation.

### 3b. What this does NOT settle

The rig was in a poor RF state for these three legs and that must be stated: the forward leg was
delivering 10.3-12.5 % PER *before* each wedge (against 2.0-5.0 % on 2026-09-24), the reverse leg was
down at 24-37 % CRC at r3 all evening, and each capture's own health check needed two or three tries.
So these three wedges are a severe regime, and it does not follow that the 6 of 17 on 2026-09-24 --
taken on a healthier rig -- share the same proximate cause. What transfers unconditionally is the
METHOD correction in sec 3 and the instrument: any future flatline is now characterised from inside
itself rather than from an average around it.

## 4. ANSWERED: fabric ring vs host drain

This section asked which side stopped, and named 0x1C0 as the discriminator. It is now recorded and
sampled inside the flatline (sec 3a): **neither** -- the ring is not blocked and the host is not
failing to drain. Both counters move in lockstep at one frame per six seconds because the
demodulator has stopped detecting. The remaining question is upstream of everything this section
considered: why acquisition collapses while the carrier loop still runs.

## 4a. A second wedge cause, found during the Task 8 validation (2026-09-25)

A standalone `capture_r3.sh` on the shipped r3 pair wedged after 23 s; the identical capture re-run
minutes later was `healthy crc=99%`. The only change: the capture now also holds `SENTINEL_STOP`.
The sentinel had been probing mid-capture, having its probes refused by the new rig-lock guard, and
escalating to a recovery (`docs/evidence/RIG_MUTEX_VALIDATION_2026-09-25.md` sec 3).

**This does not explain the 6 of 17 above.** `gate3_pair.sh` has always held `SENTINEL_STOP` for its
whole run, so the 2026-09-24 campaign legs were never exposed to it. It does mean any STANDALONE
one-off capture taken before 2026-09-25 could have been, which is worth remembering when reading
older single captures -- and it is a second, independent reason a delivery flatline is not
automatically the byte-plane class.

## 5. Next

1. Re-run any r4 capture with the new 0x1C0 in the snapshot -- one leg is enough to split
   fabric-side from host-side, and it needs no campaign.
2. Only then choose a lever. The RXM / RXQ / `QPSK_RX_DRAIN_BUDGET` framing was withdrawn on
   2026-09-25 (`SILICON.md` sec 7.2) because peer engine re-arms run at ~0.37/s on clean and wedged
   legs alike; nothing since has re-established it, and section 3 above rules out the radio, so the
   candidate set is now "fabric byte ring" vs "host drain", which 0x1C0 decides.
