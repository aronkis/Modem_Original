# Where this link's PER and BER actually stand, and what would move them

Written after a day of measurement on 2026-09-27. Short version: **the forward leg is excellent and
the reverse leg is limited by its air path, which is a physical defect. No software lever was found
tonight, and three candidate software causes were ruled out.**

## 1. The two legs are not in the same condition

| | forward (146 TX -> 148 RX) | reverse (148 TX -> 146 RX) |
|---|---|---|
| shipped-image PER | 0.005-0.009 % | 0.008 % best, but see below |
| air bit errors, PHY only (120-bit window) | **0 of ~37,400 frames** | **~32 per frame** in a degraded window |
| one-way ROM phase, 09-25 | 0 bit errors of 18.2 M | 45,683 bit errors of 18.0 M |
| time below 0.75 delivery (10 days) | 0.08-0.15 % of samples | **15-22 %** |

Sources: `AIR_BER_2026-09-27.md`, `REVERSE_LEG_AVAILABILITY.md`,
`oneway/ONEWAY_HW_VERIFY_2026-09-25.md`. Every PER counts lost frames in the denominator.

The reverse leg's damage is EPISODIC, not constant: the median sample is fine (0.90-0.96 delivery)
and the link falls into deep holes, with the worst 1 % delivering nothing.

## 2. What has been ruled out as the cause

* **Carrier tracking.** Two triggered captures: the one with a textbook-healthy carrier estimate
  (median -4780, 0.51 % of frames on the wrong side of zero) had the WORSE PER at 18.3 %. They move
  in opposite directions.
* **Received signal level.** 32.4-32.9 dB below full scale in both captures, which is the ordinary
  healthy level for this rig. 0.27 damage is a partially working channel, not a weak one.
* **The delivery plane / byte plane.** The PHY-only measurement contains no byte plane, no DMA and no
  host data path, and it shows the damage. I had argued the opposite from the singles-and-doubles loss
  shape and withdrew it.
* **The RX-only image's byte-plane pad** (a separate but related suspicion): falsified in simulation,
  and the one-way reverse "byte-plane defect" is itself confounded by this same air damage
  (`oneway/RXO_BYTEPLANE_REREAD_2026-09-27.md`, `oneway/RXO_PAD_SIM_2026-09-27.md`).

## 3. What is left, and it is physical

The 146 antenna, diagnosed by a swap experiment on 2026-09-08 and still not replaced. Everything
measured since is consistent with it: one-sided damage, normal level, episodic, receive-side (both
transmitters hold nominal rate through the worst samples).

**The single largest available improvement to this link's PER and BER is replacing that antenna.** It
is not a software change and nothing in the repo can substitute for it.

## 4. Software levers considered tonight, and why none was pulled

* **LO plan.** Already corrected where it was wrong -- the 2-sps rung was running half its intended
  margin from the demodulator's dead zone and now has its own values. The shipped 4-sps rung's values
  were set by a measured sweep and are unchanged. The interleaved test showed the LO controls
  dead-zone proximity but does NOT cause the wedges.
* **Steering.** 146 is on R4D and 148 on R4B, which are the configured values for each board and were
  verified in the one-way run's own log.
* **Payload whitening.** Already on by default in both the normal and the one-way bring-up; checked,
  not assumed.
* **The byte FIFO's ready pad.** The one candidate that looked like a real defect. It is a harness
  artefact: the model harness has no tolerance at the production depth, while the product runs that
  depth at 0.005 % PER, so the harness's latency is not the product's. Changing the product on that
  basis would have been wrong.

## 5. What would genuinely help, in order

1. **Replace the 146 antenna.** Operator action. Everything else is second order.
2. **Reconcile the backpressure harness with the shipped image's latency**, then add a backpressure
   leg to Gate 1. Today no gate leg exercises the byte plane's handshake at all, so a wrong ready pad
   would ship undetected. This prevents a future PER regression rather than fixing today's.
3. **Re-run the one-way reverse byte phase in a window measured CLEAN** to close out the RX-only
   question honestly, rather than leaving a "byte plane broken" verdict that the data does not support.
4. **Find the wedge cause**, still open. It needs a degraded session, which the trigger now supplies
   about once a day, and it is a separate phenomenon from the air damage: both captures hit exactly
   one wedge each while delivering otherwise.
