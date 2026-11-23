# How much of the time is each leg actually working? (delivery sentinel, 2026-09-16 .. 09-26)

Desk analysis of the delivery sentinel's log by `ops/sentinel_stats.py`. No board contact, no new
instrumentation: the sentinel already samples both boards' daemon stats lines every ~5 minutes and
its log is the only continuous record of the link between campaigns. Window: since the sp3prod pair
was deployed on both boards (2026-09-16 15:00), so one image throughout.

2689 samples carry all four counters; 2591 remain after dropping everything within 20 minutes of a
wedge, a recovery, a restart or any rig-work line, because the log is contaminated whenever the rig
is being worked on.

## 1. Read the sentinel's fields correctly or you invent a defect

    rate = 148 idle_rx   FORWARD receive      tx  = 148 dma_tx   REVERSE source
    rev  = 146 idle_rx   REVERSE receive      rtx = 146 dma_tx   FORWARD source

A delivery ratio is therefore CROSS-board (reverse = `rev/tx`). My first pass paired each board's
receive with its own transmit and called it delivery; it is not. But a cross-board ratio has its own
trap: the boards are not always sampled over the same window -- the known "high mode" is exactly
1.5x -- so a cross-board ratio spanning two different windows is wrong by that factor. Both
constructions are reported below, and they agree on the finding:

| construction | reverse | forward |
|---|---|---|
| **cross-board delivery**, same-mode samples only (n=651) | med 0.900, p5 0.041, **22.27 %** below 0.75 | med 1.000, p5 0.899, **0.15 %** |
| **proxy** rx / own tx, mode-free (n=2591) | med 0.961, p5 0.091, **15.36 %** below 0.75 | med 1.000, p5 0.933, **0.08 %** |

## 2. The finding

**The reverse leg is degraded 15-22 % of the time. The forward leg, on the same samples, 0.08-0.15 %
of the time.** Two orders of magnitude apart, and the gap is robust to which construction is used --
the two disagree on the exact percentage (they are different quantities) but not on the conclusion.

The median reverse sample is fine (0.90-0.96). This is not a link that is uniformly poor; it is a
link that falls into deep holes, and they are deeper than the median suggests: the 5th percentile is
**0.04-0.09**, and the 1st percentile is 0.000 -- in the worst 1 sample in 100 the reverse leg
delivers nothing at all.

**It is receive-side.** Through the 283 worst reverse samples (proxy below 0.5), both transmitters
held at a nominal 1245/s median. The transmitters are being fed; the frames are
not arriving. That is consistent with the RF cause already recorded for this leg
(`docs/evidence/sp3/`, the 146 antenna, unreplaced) and rules out a starved transmitter.

## 3. What this does NOT show

* **No diurnal pattern was detected, which is not the same as none existing.** Degraded fraction by
  hour ranges 4 % to 28 % around an overall 15.4 %, on about 107 samples per hour. That spread is
  consistent with uniform and also with a modest daily effect; this sample size cannot separate them.
  Do not conclude the cause is non-environmental from this table.
* Nothing here identifies the mechanism. It measures duty, not cause, and the attribution to the
  antenna comes from the earlier swap experiment, not from this log.
* The sentinel's own rates are 10-second windows sampled every ~5 minutes: about 3 % of wall clock.
  Episodes shorter than a few minutes are undersampled and the true hole count is a lower bound.

## 4. Why it matters, and the one thing it changes

The reverse leg's antenna is a known, diagnosed, physical defect awaiting an operator swap. This
quantifies the cost of waiting: **the link is running at roughly 78-85 % availability in one direction
against 99.9 % in the other.** No software change addresses it.

It does change one thing, cheaply. The open question from
`docs/evidence/sp4/ACQUISITION_COLLAPSE.md` sec 7 is that reproducing the r4 wedge needs a DEGRADED
session, and waiting for one at random is expensive. These episodes are detectable live from the
sentinel's own log with no extra board traffic. **Built: `ops/degraded_trigger.sh`** (sec 6).

## 5. A measurement bug found while writing this, and what it cost

The first version of `sentinel_stats.py` selected usable samples with `all(r[k] for k in FIELDS)`.
A leg delivering **exactly zero** frames is falsy in Python, so every totally-dead reverse sample
was silently dropped from the statistics -- 79 of them in this window, and precisely the worst ones.
The effect was to understate the defect: reverse degradation read 12.8-19.3 % instead of
15.4-22.3 %, and the 5th percentile read 0.23-0.29 instead of 0.04-0.09, which changes the
description from "delivering under a third" to "delivering almost nothing". The numbers above are
the corrected ones. A test now pins the zero case (`test_reverse_delivery_is_cross_board_not_same_board`
uses a leg at zero precisely so the falsy path cannot come back), and the same test file pins the
field semantics of section 1.

Two other things the tests caught: a zero DENOMINATOR (a dead transmitter) is a different fault and
cannot be expressed as a delivery ratio at all, so those samples are now excluded explicitly rather
than dividing by zero; and the quiet filter is symmetric in time, so a sample five minutes BEFORE a
wedge line is contaminated too.

## 6. The trigger, and the episode-duration measurement that shaped it

Counting episodes below 0.5 on the proxy, with a gap of more than 15 minutes ending an episode
(we cannot claim the link was degraded through a window the sentinel did not observe):

| observed duration | episodes |
|---|---|
| a single sample (under 5 min observed) | 68 |
| 5-15 min | 15 |
| 15-30 min | 4 |
| 30-60 min | 2 |
| over 60 min | 4 |

93 episodes, 955 minutes of observed degraded time. **Six episodes lasted 30 minutes or more and
they hold 81 % of that time.** One starts about every 40 hours on average, and they CLUSTER: four
of the six were on 09-22 and two on 09-26.

That settles the design. Firing on one sample would fire 93 times in ten days, almost all on blips
that are over before anything can be done with them. `CONSEC=5` samples at the sentinel's ~5-minute
cadence spans about 20 minutes of wall clock (N samples span N-1 intervals), which selects the
episodes worth acting on. The 6-hour cooldown deliberately suppresses later episodes on a bad day,
so the trigger undercounts -- the right trade for something running unattended.

**It reads local files only.** No ssh, no register access, no arm. That is the whole safety
argument: it runs at 03:00 with nobody present, so nothing it does can hang a board. It stands down
on a stale log (a dead sentinel's last line looks exactly like a dead link), on the keeper unit not
running (then nothing is refreshing the log at all), and on `RIG_LOCK` or `SENTINEL_STOP`.

The record is the episode's context -- both ratio constructions, how long the episode has run,
which stand-down checks actually passed, and the last 20 samples. `ACTION` is an opt-in command
hook, empty by default; wiring it to a flash campaign would take the production link down and is
still not shipped.

**ACTION is now wired to a capture, by operator decision (2026-09-26): `ops/degraded_capture.sh`.**
It captures the REVERSE leg for 300 s at the shipped rung, so the failure gets recorded with
per-frame data instead of only as a rate in this log. Two things about it matter more than the rest:

* **`GATE_DIR=A` is not optional.** The bring-up's arm gate requires BOTH receivers at the floor,
  and during a reverse episode 146 is exactly the side that cannot make it. Without scoping the
  gate to the healthy forward direction, the capture burns all six arm re-rolls and yields nothing
  -- measured on 2026-09-25/26, where six captures ground through about 36 arms and 40 minutes to
  produce a table of "(no frames.bin)".
* **The measurement perturbs the thing it measures.** The capture's bring-up re-arms both boards,
  which could clear the episode it was sent to observe. The evidence says episodes survive arms (the
  09-22 episode ran 381 minutes across the board watchdog's own re-arms) but that is not a
  guarantee, so the verdict states which happened rather than assuming: STILL DEGRADED (reverse PER
  >= 5 %, the episode was captured), RECOVERED (< 1 %, the arm cleared it and the data is of the
  aftermath, not the event), MARGINAL, or UNKNOWN. A capture that produced no frames is never
  scored as a healthy link.

This arms both boards unattended, which is the risk the record-only default existed to avoid: an
arm is the worst instance of the class that hung 148 on 2026-09-25 with nobody present. It runs
under `capture_r3.sh`, which holds the rig mutex and SENTINEL_STOP, so nothing else can touch the
boards while it works, and the 6-hour cooldown means at most one such capture per bad day.

Validated two ways: against the live log with a healthy link it stays silent, and replaying the
real 09-22 06:44 episode (retimed so the freshness gate passes, content untouched) it fires at
ratio 0.022.

