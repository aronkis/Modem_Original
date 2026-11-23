# The RX-only "byte-plane defect" is confounded by the reverse leg's air damage

`ONEWAY_HW_VERIFY_2026-09-25.md` sec 6.1 concluded: *"The RF path is fine; the byte plane on 146 is
not."* Re-reading that run's own numbers against today's PHY measurement, **that conclusion is not
supported, and the reverse leg's air was already damaged during it.** Desk work, no board touched.

## 1. The two numbers from the same run that were not compared

Both legs, same session, same images, ROM phase (fabric source, 120 s):

| leg | frames | lost | bits scored | bit errors | BER (120-bit window) |
|---|---|---|---|---|---|
| forward, 148 receiving | 151759 | 0 | 18,211,080 | **0** | **0.00000 %** |
| reverse, 146 receiving | 149654 | 0 | 17,958,480 | **45,683** | **0.25438 %** |

The conclusion rested on `lost=0` for the reverse leg. But **`lost` counts DETECTED frames, not
correct ones** -- detection needs the preamble, not an intact payload. The BER column in the same
table says the reverse air was carrying 45,683 bit errors while the forward carried exactly zero.

## 2. That BER is sufficient, on its own, to fail every frame

0.25438 % per bit over the scored window. An f1536 payload is 1528 B = 12,224 bits, so a uniform
error rate of 0.0025 gives of order 31 bit errors per frame. **Essentially no frame can pass CRC.**
The byte phase on that leg is exactly what that predicts:

    forward byte phase:  frames_scored=74718   aligned=74653   bit_errors=82
    reverse byte phase:  frames_scored=22973   aligned=0       total_bits=0

Zero frames aligned out of 22,973 that arrived. The 69 % "lost" is the scorer's denominator
(`expected=1245 f/s x 60 s = 74700`) against frames it could not align -- a consequence of damaged
bits, not evidence of a byte plane that drops them.

## 3. Today's measurement corroborates it, at much larger magnitude

`AIR_BER_2026-09-27.md`: in a degraded window the reverse leg produced **~32 bit errors per frame**
in the same 120-bit window (damage 0.26-0.27) while the forward leg produced **exactly zero** across
about 37,400 frames, with the positive control validated. Same asymmetry, same direction, 100x the
rate. The reverse leg has real air damage; it is episodic, and `REVERSE_LEG_AVAILABILITY.md` puts it
at 15-22 % of the time.

## 4. Which also explains the "mode dependence" that motivated the pad hypothesis

The 09-25 report read 69 % loss in the byte phase against 6.6 % in the tun phase as a mode effect
(queued 16-packet against legacy per-packet) and built the pad suspicion on it. But the two phases
ran at DIFFERENT TIMES in the same session -- byte at 20:34:45, tun a couple of minutes later -- and
the reverse leg's damage is episodic. At a uniform 0.25 % BER the legacy phase could not have
delivered 31,838 of 34,091 packets (93.4 %); that it did means **the air was better by then**. The
difference is plausibly time, not mode.

The same applies to the 2026-09-15 queued-mode observation (`dma_rx_ok=1`, `crc_drop=50,318`, "decodes
idle frames but fails every DATA frame's CRC"). That is also what a damaged air path looks like to a
CRC-gated consumer, and `qpsk_tun.c` separately documents a host-side queued-ring stall with the same
signature (ring stops re-submitting, `byte_rx_ready` held low, `0x1C0` frozen, crc_drop climbing,
`dma_rx_ok=2`) which has its own watchdog. Neither reading needs a pad defect.

## 5. Status of the pad hypothesis

Falsified independently in simulation (`RXO_PAD_SIM_2026-09-27.md`): the shipped gate driver holds
`byte_rx_ready` high so the pad depth is unobservable there, and under real backpressure the one-way
depth of 2 is on the GOOD side of a cliff between 3 and 4. Nothing supports "2 is a defect".

## 6. What this changes, and the experiment that would settle it

**It redirects the work.** The RX-only image may have no byte-plane defect at all, and the reverse
leg's dominant defect is the one already diagnosed physically: the 146 antenna, unreplaced.

**The decisive test is cheap and needs the rig, not simulation.** Re-run the one-way reverse byte
phase in a window known to be CLEAN, instead of at an arbitrary moment. The degraded trigger
(`ops/degraded_trigger.sh`) now identifies degraded windows about once a day, so its inverse
identifies clean ones: require several consecutive samples with reverse delivery at full rate and
reverse CRC above, say, 95 %. If the byte phase aligns its frames in a clean window, the byte plane
is exonerated and the 09-15/09-25 readings were both the air. If it still loses 69 % with the air
measured clean in the same window, there is a real byte-plane defect and the pad is not it.

Until that is run, the honest status of the RX-only image is **unverified on the reverse leg, cause
not established** -- not "byte plane broken".
