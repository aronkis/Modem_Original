# Reset ledger: who resets the modem, how often, and what a reset costs

Desk analysis, 2026-09-29 evening, files only: `ops/reset_ledger.py` over every watchdog snapshot the
sentinel banked (`~/modem-status/wdlog_*.txt`, 225 h of on-board record per board), `sentinel.log`,
the two boards' live `/dev/shm/watchdog.log` pulled under the rig lock at 18:59, and the per-frame
`frames.bin` of the seven banked reverse legs that reset while decoding. Plan:
`stop the carrier-sync resets`, Phases 0-1.

## 1. "Constant resetting" is four layers, and the modem is the smallest

| layer | mechanism | 225 h record, 146 (reverse RX) | 148 (forward RX) |
|---|---|---|---|
| **fabric `rstCS`** (`0x150`) | `CFO_step_change_detector.v`: consecutive coarse estimates differ by > `CFOChangeDetectThreshold` (0.0125 En21 = 26214 units ≈ 5.6 kHz) → fine `Carrier_Synchronizer` integrator reset. Bare compare, no confirmation, no lock state. | **22.5 %** of LOCKED 5 s windows still carried resets (6,355 of 28,259); 159,583 resets while "locked"; 8,460 storm windows | 0.0 % (16 of 45,661); 456; 414 storms |
| **watchdog FULL RE-ARM** (`ops/lock_watchdog.sh`) | two NOT-LOCKED 5 s windows (0x104 Δ < 50 or 0x150 Δ ≥ 100) → **two `0x000` soft resets** + re-select + `0x110` | **4,341 re-arms = 19.3 / h**; 616 in 5 h on 09-28 | 216 = 1.0 / h |
| sentinel recovery | full bring-up when 148 `idle_rx` < 100/s | 11 wedge + 5 post-reboot in the window | |
| bring-up double-tap | two `0x000` per arm, by design | per arm | |

The host daemon never writes a control register (its mmap is read-only bar the `0x1DC` log-FIFO pop
token), so there is no fifth layer.

## 2. The re-arms couple across the boards

148's re-arms are storm-driven: **165 of 167** examined were preceded by a fabric storm. And they
follow 146's: on the 09-27/28/29 snapshots **60 %, 73 %, 94 % and 100 % of 148's re-arms fell within
60 s of a 146 re-arm** (the reverse fraction is 1-12 % only because 146 re-arms so much more often). The
watchdog's own comment names the mechanism: a `0x000` re-arm blips that board's transmitter; the
peer's coarse estimator storms on empty air; the peer's watchdog re-arms it. **The failing board drives
the healthy one.**

| snapshot | 148 re-arms | 146 re-arms | 148 within 60 s of a 146 re-arm |
|---|---|---|---|
| 09-27 08:10 | 96 | 209 | 58 (60 %) |
| 09-28 07:45 | 30 | 616 | 22 (73 %) |
| 09-29 07:34 | 34 | 67 | 32 (94 %) |
| 09-29 08:59 | 1 | 119 | 1 (100 %) |

## 3. On the 1850 plan the link has not reset at all

Live watchdog logs pulled at 18:59, anchored to pull time, covering the shipped-default bring-up at
13:53 onwards (`ops/reset_ledger.py --no-snapshots --live ... --since 2026-09-29`):

| board | hours | LOCKED windows | with resets | fabric resets | storms | re-arms | daemon restarts |
|---|---|---|---|---|---|---|---|
| 146 | 5.1 | 2,738 | **0** | **0** | 0 | **0** | 0 |
| 148 | 5.1 | 2,755 | **0** | **0** | 0 | **0** | 0 |

Sentinel recoveries since 13:53: 0 (the day's two were 07:34 and 08:59). **Moving the reverse
carrier off the 1.9 GHz notch removed every reset layer on this link.** This is the baseline the
rest of the plan is measured against; it will be re-pulled after 12 h and 24 h.

## 4. What the resets-while-decoding actually were

Five reverse legs from 09-12/13 decoded at **99.6 % CRC while resetting ~8/s** (≈5,000 per 615 s).
Per-frame analysis (`reg_rstcs`, `crc_ok`, `reg_cfc`, `t_real_ns`):

* They are **not periodic**: 2-6 % of inter-event gaps sit near the 33-frame TX comb, 0 % near the
  1.57 s device tick. They cluster: median gap = one frame.
* They are **a handful of episodes**, not a rate. Each leg has 2-4 episodes of 0.04-11 s. In every
  leg, **one episode at t = 607-609 s of a 615 s log holds 82-89 % of the resets and of the leg's CRC
  failures** -- the moment the capture rail's 600 s traffic window ends and it flushes the daemons
  (`pkill -USR1`, a documented 4-246 ms transmit-feed stall on the peer). Frames were arriving at
  1236-1246/s with 99.9-100 % CRC two seconds earlier; then delivery halves, CRC is **0 %**, and the
  fabric resets ~900/s until the log ends 5-8 s later. **A brief host-side interruption of the peer's
  transmit feed puts the receiver into a reset storm from which it does not recover within 5 s.**
* The remaining episodes (6-289 resets, 14-181 CRC-fail frames, 2-6 % of failures each; 2-3 per
  10 min) are genuine short acquisition losses at the 1.9 GHz carrier -- consistent with a bursty
  interferer in the notch.
* At a reset frame the carrier estimate is **±200,000 units** (no signal; healthy is -4750 ± 15) and
  CRC is 1-8 %. **60 % of these legs' entire CRC loss sat at a reset.**
* On the two 09-27 degraded legs (89-93 % CRC) resets carried only 6-8 % of the loss: there the
  damage was the notch's corruption, not resets.

So: a working link does not reset (sec 3). When the signal is interrupted -- by the notch, or by the
peer's own host -- the coarse estimator storms and the receiver takes seconds to re-lock, and every
reset in a storm costs the frames around it. The modem-side fix is worth exactly that: not storming,
and re-locking in milliseconds instead of seconds.

## 5. The boards run a watchdog the repo already fixed

`/root/lock_watchdog.sh` on both boards is 212 lines, md5 `aaf6908a90af`; the repo's is 227 lines,
`1d5a2fb36361`. The difference is `restore_fixctl()` (commit `0a9c3f11`): after a `0x000` re-arm the
repo version rewrites `0x208` from `/dev/shm/fixctl.word`; the deployed one does not. **Every
watchdog re-arm on 146 therefore clears its configured R4D+R1 steering and nothing restores it** --
which is the `0x25C = 0x0` discrepancy recorded on 09-28 (`REVERSE_ERROR_SOURCES_2026-09-28.md`
sec 7). `provision.sh` is the deploy path (`scpput lock_watchdog.sh root@<ip>:/root/`); it has not
been run since the fix. Deploy with the Phase 4 watchdog change.

## 6. What this changes in the plan

* The **baseline is zero**, so the acceptance target (hours with no resets) is already met by the
  carrier move on a quiet band; the plan's job is to make the receiver *robust* when the band is not
  quiet, and to stop the software from making it worse.
* Phase 2's key stimulus is a **transmit-feed interruption of 20-2000 ms followed by resumption**,
  measured as resets and time-to-relock -- the exact event that produced 82-89 % of the historical
  resets. Reproduce on the rig first (a paused peer daemon, no arms) to get the true curve, then in
  RTL where the fix is judged.
* Phase 4's first step is simply to **provision the watchdog the repo already has**.

Tool: `ops/reset_ledger.py [--daily] [--coupling] [--live FILE --ip IP]`; tests
`ops/tests/test_reset_ledger.py`. Board clocks are not nemo's (146 read +2..+5 h across snapshots);
every line is anchored to the snapshot's wall time by its distance from the last `[wd]` line.
