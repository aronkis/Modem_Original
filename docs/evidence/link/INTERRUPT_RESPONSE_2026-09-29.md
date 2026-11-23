# A 20 ms interruption of the transmit feed latches the receiver until a soft reset

Live rig, 2026-09-29 19:06-19:22, shipped image at the 1850 plan, no arms, no register writes.
`ops/interrupt_response.sh`: pause the peer's (148's) daemon with SIGSTOP for X ms -- which starves
its transmit feeder exactly as `WEDGE_ROOT_CAUSE.md` describes -- resume it with SIGCONT, and poll the
receiver (146) at 1 Hz throughout: `0x104` detected frames, `0x150` carrier-sync resets, `0x154`
carrier estimate. Pause lengths 20 / 100 / 500 / 2000 ms, three reps each, interleaved, 30 s settle
before and 40 s after each. Both watchdogs were killed for the run so nothing could re-arm.

## 1. Result: a step, not a curve

| receiver clock (10 s bin) | detected f/s | fabric resets / 10 s | carrier estimate (median) | event |
|---|---|---|---|---|
| 19:06:00 | 1245 | 0 | -4408 |  |
| 19:06:10 | 1246 | 0 | -4382 |  |
| 19:06:20 | 1245 | 0 | -4528 |  |
| 19:06:30 | 1148 | 1705 | -4312 | pause 20 ms |
| 19:06:40 | 632 | 11997 | +77292 |  |
| 19:06:50 | 636 | 12028 | +76832 |  |
| 19:07:40 | 624 | 11619 | +32912 | pause 100 ms |
| 19:08:00 | 627 | 11869 | +53188 |  |
| 19:08:50 | 630 | 12000 | +99192 | pause 500 ms |
| 19:10:00 | 644 | 12020 | +56328 |  |
| 19:10:10 | 494 | 9347 | -6327 | pause 2000 ms |
| 19:11:20 | 632 | 12053 | +23644 | pause 20 ms |
| 19:12:00 | 635 | 11879 | +36308 |  |
| 19:12:30 | 631 | 10417 | +8959 | pause 100 ms |
| 19:13:40 | 620 | 11738 | +58825 | pause 500 ms |
| 19:14:00 | 671 | 12581 | -62259 |  |
| 19:14:50 | 539 | 10003 | +7102 | pause 2000 ms |
| 19:16:00 | 655 | 11147 | +22479 |  |
| 19:16:10 | 657 | 12583 | +60784 | pause 20 ms |
| 19:17:20 | 640 | 10958 | +17469 | pause 100 ms |
| 19:18:00 | 661 | 11267 | +59166 |  |
| 19:18:30 | 614 | 11689 | +1270 | pause 500 ms |
| 19:19:40 | 510 | 9706 | -6044 | pause 2000 ms |
| 19:20:00 | 664 | 11207 | +23453 |  |
| 19:22:00 | 666 | 11368 | -54236 |  |
| 19:22:30 | 653 | 2749 | -102099 |  |

Storm window 19:06:50-19:22:30: 95 bins, detected f/s median 652, resets per 10 s median 12027, bins that returned to >= 1100 f/s with 0 resets: 0

The receiver ran at 1245 f/s with **zero** resets and a carrier estimate of -4400 for the 30 s
before the first pause. The first pause was **20 ms**. From that bin on, for the remaining
**16 minutes**, through eleven further pauses and every ~70 s gap between them, the receiver
detected at half rate, reset its carrier sync ~1,200 times per second (the storm signature: ~2 resets
per framesync, `0x104` counting CRC-failing syncs) and its carrier estimate swung over ±250,000
units. It **never re-locked on its own**. Scored per rep (`ops/interrupt_response_score.py`): every
rep after the first shows "detection before the pause" of 630-665 f/s -- the storm was already
running -- so the 100 / 500 / 2000 ms pauses measured nothing new. The response to an interruption
is not a recovery time; it is a **latch**.

## 2. The receiver was the latched party, not the transmitter

When the run ended and the watchdogs were relaunched, **146's own watchdog** saw the storm (NOT-LOCKED,
`drstcs=6861` and `6886` per 5 s) and issued its `0x000` double-tap at 00:22:47 board time; the leg
was at 6,248 frames per 5 s (1,250 f/s) with **zero** resets 20 s later and stayed there. 148's daemon
was the same process throughout (pid 3258157, up since the 13:53 bring-up), so the transmitter had
resumed normally after each SIGCONT and the receiver simply did not follow it. This is the "false FTS
state that `0x110` cannot clear and only a full `0x000` does" of `ACQUISITION_COLLAPSE.md` sec 3 --
now shown to be reachable by the most ordinary event a link can see: a 20 ms hiccup on the peer's host.

Consequences for the record so far:
* it explains the watchdog's 4,341 re-arms on 146 (`RESET_LEDGER_2026-09-29.md`) -- the system limps
  along on `0x000` because the receiver cannot recover otherwise;
* it explains the end-of-leg storms in every banked capture (the rail's flush stalls the peer's feed
  for 4-246 ms), and why they never recovered inside the log;
* it makes the peer-coupling mechanism concrete: any re-arm, restart or stall on one board's host
  latches the other board's receiver.

## 3. Side finding: the paused daemon came back with its byte plane wedged

After twelve SIGSTOP/SIGCONT cycles 148's daemon was alive but its byte plane was frozen (`0x1C0`
stuck while the fabric detected at rate). My cleanup relaunched its watchdog **bare**, the
`capture_r3.sh -k` idiom -- no `DAEMON_CMD` -- so the watchdog could not take its proven "restart
qpsk_tun" path for a BYTE-PLANE WEDGE and fell through to FULL RE-ARM, which does not clear one, and
looped a `0x000` double-tap every ~30 s (7 re-arms in 4 minutes), each blipping the peer. A default
bring-up cleared it. Two fixes landed with this document: the experiment's cleanup relaunches with
`DAEMON_CMD` (the `restore_known_good.sh` idiom), and the watchdog-relaunch idiom is flagged for
Phase 4. The scorer's clock alignment is also corrected: both stamps are epoch seconds and need no
offset (the boards' 5 h difference is a timezone setting).

## 4. What this changes in the plan

The modem-side fix is no longer "re-lock faster". The receiver must **not latch**: on loss of
signal it must hold or coast its carrier state and re-acquire automatically when the signal returns,
so that the `0x000` soft reset becomes an operator tool and not the link's heartbeat. That is Phase 3's
acceptance test, and `interrupt_response.sh` is the instrument that credits it: the same 20 ms pause
must return to 1245 f/s and zero resets within a bounded time, with no re-arm.

Reproduce: `ops/launch_rig_unit.sh <unit> ops/interrupt_response.sh OUT=<dir> RX=10.0.0.146 TX=10.0.0.148 "LENS_MS=20 100 500 2000" REPS=3`
then `python3 ops/interrupt_response_score.py <dir>`. Stop the degraded trigger first.
