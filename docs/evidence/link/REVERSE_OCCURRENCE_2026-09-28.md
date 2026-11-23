# How often the reverse leg fails, and in what shape (sentinel, 2026-09-15 .. 09-28)

Desk analysis by `ops/episode_stats.py` of `~/modem-status/sentinel.log`. No board contact. This
answers *occurrence*; `REVERSE_ERROR_SOURCES_2026-09-28.md` answers *cause*.

    ops/episode_stats.py --since 2026-09-15            # reverse
    ops/episode_stats.py --since 2026-09-15 --leg fwd  # forward, same samples

3435 samples carry all four counters; **3277** survive dropping everything within 1200 s of a
wedge, recovery, restart or rig-work line -- the same exclusion `REVERSE_LEG_AVAILABILITY.md`
used. All figures below are the **mode-free proxy** (each board's receive over its OWN transmit),
so the 1.5x window-mode artefact cancels.

## 1. Read the ratio-free column first

Every ratio built from this log carries the mode artefact. The count of samples where the receiver
delivered **exactly zero** does not, so it leads. A first pass of mine that used a naive `rev/tx`
ratio reported 40-50 % degraded on days this table calls healthy; that pass was wrong and is not
used here.

| day | n | rev==0 | zero % | degraded % | median | p5 |
|---|---|---|---|---|---|---|
| 09-15 | 269 | 0 | 0.0 | 1.1 | 0.965 | 0.959 |
| 09-16 | 222 | 3 | 1.4 | 1.8 | 0.965 | 0.957 |
| 09-17 | 262 | 0 | 0.0 | 2.3 | 0.965 | 0.956 |
| 09-18 | 276 | 0 | 0.0 | 3.6 | 0.964 | 0.953 |
| 09-19 | 284 | 2 | 0.7 | 6.7 | 0.961 | 0.645 |
| 09-20 | 283 | 3 | 1.1 | 13.1 | 0.910 | 0.260 |
| 09-21 | 276 | 9 | 3.3 | 33.0 | 0.817 | 0.056 |
| **09-22** | 240 | **58** | **24.2** | **58.3** | **0.224** | 0.000 |
| 09-23 | 237 | 0 | 0.0 | **0.4** | 0.882 | 0.798 |
| 09-24 | 157 | 0 | 0.0 | **0.6** | 0.966 | 0.959 |
| 09-25 | 208 | 0 | 0.0 | 4.8 | 0.965 | 0.775 |
| 09-26 | 243 | 0 | 0.0 | 37.9 | 0.946 | 0.353 |
| 09-27 | 237 | 20 | 8.4 | 38.8 | 0.905 | 0.000 |
| **09-28** | 83 | **25** | **30.1** | **100.0** | **0.109** | 0.000 |

## 2. The finding: waves, not a slope

**This is not a monotonic decline.** It deteriorates over three to four days, recovers completely,
and deteriorates again:

* 09-15 -> 09-22: 1.1 % climbing to 58.3 %, ending in a day where a quarter of all samples
  delivered nothing.
* 09-23 / 09-24: back to **0.4 % and 0.6 %** -- as healthy as this leg has ever been measured.
* 09-25 -> 09-28: 4.8 %, 37.9 %, 38.8 %, 100 %.

I had recorded the 09-15..09-28 span as a monotonic collapse earlier on 09-28. That reading came
from a script without these exclusions and without the mode-free construction; **it is withdrawn.**
The wave shape matters, because a part that is degrading monotonically and an intermittent that
recovers on its own imply different causes and different fixes.

## 3. Episode shape

An episode is a maximal run of consecutive degraded samples (< 0.75). A log gap over 900 s **ends**
an episode instead of bridging it: nothing is known about the interval, and stitching would invent
duration.

| | reverse | forward |
|---|---|---|
| episodes in 13.3 days | **156** | **5** |
| episodes per day | **11.69** | **0.37** |
| samples per episode, median / max | 1 / 111 | 1 / 5 |
| duration, median / max | 0 min / **559 min** | 0 min / 20 min |
| episodes containing a zero-delivery sample | **27** | **0** |

The distribution is heavily skewed: most episodes are a single sample, and a handful dominate the
duty. The five longest:

| start | end | samples | min | median | zeros |
|---|---|---|---|---|---|
| 09-22 06:39 | 15:57 | 111 | 0.000 | 0.022 | 46 |
| 09-27 21:33 | 02:07 | 55 | 0.000 | 0.096 | 19 |
| 09-28 03:01 | 07:25 | 53 | 0.000 | 0.100 | 15 |
| 09-26 08:31 | 11:39 | 38 | 0.235 | 0.516 | 0 |
| 09-22 16:08 | 18:10 | 25 | 0.000 | 0.040 | 10 |

**Resolution limit.** The sentinel samples every ~5 minutes, so onsets and durations are quantised
at 5 min and anything shorter is invisible -- a single-sample episode reads as 0 min duration, not
as an instantaneous event. A "sentinel episode" is therefore a different object from a per-frame
hole inside a 300 s capture (`ops/frame_taxonomy.py`); the two are on different timescales and must
not be pooled or their counts compared.

## 4. It is one-sided, per sample and not just in aggregate

Of the **469 degraded reverse samples, 3 (0.6 %)** had the forward leg degraded in the same sample.
The forward leg has **never** delivered exactly zero in 3277 samples; its median is 1.000 on every
one of the 14 days.

A shared cause -- a drifted reference, host scheduling, a rig-wide RF floor -- would degrade both
legs together. This rules that class out at the occurrence level, independently of any RF
measurement.

## 5. What this does NOT show

* **No mechanism.** It measures duty and shape only.
* **No diurnal claim, in either direction.** The long episodes start at 06:39, 21:33, 03:01, 08:31
  and 16:08; with 156 episodes over 13 days this sample cannot separate a modest daily effect from
  uniform, and the prior availability doc declined the same call on the same grounds.
* **Nothing about sub-5-minute behaviour**, which the live work on 09-28 shows is where this leg
  actually moves: it flaps between 0 and ~850 f/s on a timescale of tens of seconds.
