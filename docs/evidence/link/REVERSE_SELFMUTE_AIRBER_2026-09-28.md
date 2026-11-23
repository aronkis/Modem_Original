# Duplex self-interference measured, and the reverse leg's bits are at chance

Two experiments on the evening of 2026-09-28, shipped image `b68dbf1d9321` at r3, no flash.
Follows `REVERSE_TX_OFFSET_2026-09-28.md`, which found a +42.6 kHz transmit offset on 148 and
showed that correcting for it does NOT restore the link.

## 1. The leg has TWO failure modes and they had been treated as one

| | morning (09:00-16:30) | evening (17:00) |
|---|---|---|
| detected f/s (0x104) | **25-40** of 1245 | **1243-1246** -- full rate |
| delivered | ~0 | 865/s |
| CRC ok | ~0 % | **46 %** |
| name | acquisition collapse | **corruption** |

In the morning mode the demodulator finds no frames. In the evening mode it finds every frame and
they arrive corrupt. A rate measurement cannot see the second mode at all -- which is also why the
degraded-episode trigger, which watches delivered RATE, does not fire on it.

## 2. Duplex self-interference: both boards leak, 146 is 3.6 dB worse

This rig is FDD -- each board transmits at full power while receiving the other band. If duplex
isolation is poor, a board's own transmitter raises its own receive floor, which would produce the
whole observed set: one-sided, normal `rssi`, immune to retuning, immune to transmit source,
varying with conditions. Untested until now. Earlier runs muted the PEER; this mutes the board
ITSELF and watches that same board. Six interleaved cells per board, identical 4 s settle.

| board | own TX live | own TX muted | self-leakage | implied leak-to-signal |
|---|---|---|---|---|
| **146** (failing leg's receiver) | 26.00 dBFS | 33.50 dBFS | **7.5 dB** | **+6.6 dB** |
| **148** (healthy leg's receiver) | 26.75 dBFS | 31.50 dBFS | **4.75 dB** | **+3.0 dB** |

Readings are dBFS (larger = weaker), medians of three cells each; both boards were rock steady
(146: 26.00/26.00/26.00 live, 33.75/33.25/33.50 muted).

**On both boards the self-leakage EXCEEDS the wanted signal**, and 146's is 3.6 dB worse than
148's. With the AGC in `automatic`, leakage that strong pulls the gain down and sinks the wanted
signal -- textbook FDD desense, and a mechanism that gets worse as the wanted signal fades.

**NOT established as causal.** Detection sat at 1243-1246 f/s in every cell on both boards, so
there was no headroom for muting to show an improvement. **Re-run during a degraded window** --
that is the test that would make or break this, and it is cheap. This is the third experiment today
to find the fault absent when it mattered.

Same test, incidental: 146's carrier estimate wandered **−12677 .. +8665** while 148's held
**−3171 .. −3837** in the same minutes, unrelated to mute state. The wander asymmetry again.

## 3. Air BER during the corruption mode: forward 0, reverse at chance

`ops/rom_air_ber.sh`, both ends on the BIST ROM, 3 reps x 15 s. This is a PHY-only measurement --
no byte plane, no DMA, no host data path -- and the forward leg is a simultaneous control. The
positive control (byte source with no feeder, so the modulator radiates garbage against the
receiver's ROM expectation) read **0.4549 damage**, so a floor in the ROM rows is evidence.

| leg | rep | frames | bit errors | f/s | err/frame | frame-start damage | rstcs |
|---|---|---|---|---|---|---|---|
| forward | 1 | 18704 | **0** | 1246.9 | 0.000 | **0** | 0 |
| forward | 2 | 18704 | **0** | 1246.9 | 0.000 | **0** | 0 |
| forward | 3 | 18705 | **0** | 1247.0 | 0.000 | **0** | 0 |
| reverse | 1 | 17719 | 820685 | 1181.3 | 46.317 | 0.386 | 1 |
| reverse | 2 | 12454 | 735794 | 830.3 | 59.081 | **0.4923** | **21226** |
| reverse | 3 | 12445 | 734832 | 829.7 | 59.046 | **0.4921** | **21458** |

**Forward: exactly zero bit errors across 56,113 frames.** Reverse: 46.3 err/frame in the first
dwell, then **chance level** in the next two -- 0.4921 and 0.4923 against the deliberately-garbage
control's 0.4549 -- with a reset storm of >21,000 per dwell and six-figure carrier estimates
(−60641, −157317, −94089, +75908) that are the documented fully-unlocked signature.

Every number is frame-START damage: 0x108 scores only the first 120 of 2240 bits per frame.

**This puts the corruption at or below the demodulator, with nothing above the PHY involved**, and
it replicates the 09-27 and 09-28 02:27 runs. Note the leg degraded *during* the measurement --
1181 f/s and partially working in rep 1, 830 f/s and unlocked by rep 2 -- the same decay-after-arm
shape as everything else today.

**What it does not do is separate 148's transmitter from 146's receiver.** With two boards and no
loopback cable those are the same leg; only a third radio, a cabled loopback, or the banked one-way
pair can split them.

## 4. Position after today

**Established:** the reverse leg's damage is at or below the demodulator (three independent air-BER
runs); the forward leg is perfect on the same air in the same seconds; 148's transmit carrier is
+42.6 kHz off with 18 kHz of wander, transmit-only; 146's duplex self-leakage is 3.6 dB worse than
148's and exceeds its wanted signal; the leg has two distinct failure modes.

**Ruled out, each by its own experiment:** received level; band; the dead zone as a cause (three
replications, one against a pre-registered prediction); transmit source; a shared reference; a
starved transmitter; the delivery plane.

**Still not identified:** what actually breaks the leg. Everything found so far is either a
correlate that does not move delivery when corrected, or a real defect whose causal role is
untested because the fault kept being absent when the experiment ran.

**Next, in order:**
1. **Re-run the self-mute during a degraded window.** Cheapest remaining test with a live
   hypothesis behind it, and the trigger already detects the rate mode.
2. **Add a corruption condition to the trigger.** It watches delivered rate and cannot see the
   evening mode at all. This is the operator's deferred call (it raises unattended arms) and it now
   has a concrete cost: today's corruption window was found by hand, not by the trigger.
3. **Isolate 148's transmitter** -- the banked one-way pair, needing a flash chain.
4. **Replace the 146 antenna.** A poor match both reduces the wanted signal and worsens duplex
   isolation, which is consistent with sec 2.
