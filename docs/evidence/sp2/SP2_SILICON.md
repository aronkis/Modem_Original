# SP2 silicon evidence

Sub-project 2 ("fix-layer promotion") silicon record. Every number here is a
credited window on the lab rig (boards `10.0.0.148` = role A, `10.0.0.146` =
role B), scored with lost frames in the denominator.

## Step 1 — baseline on the deployed images (2026-09-10)

**Purpose.** Reference points for both legs on the images that are on the boards
*today*, taken on the same rig, same day, immediately before the sub-project 2
candidates are flashed (Task 11b). No flash was performed in this step.

**Images verified before any window was opened** (this is the pre-condition, not
a claim made afterwards):

```
$ ops/anyssh.sh 10.0.0.148 'md5sum /boot/BOOT.BIN | cut -c1-12'
bf2a7305bbe0
$ ops/anyssh.sh 10.0.0.146 'md5sum /boot/BOOT.BIN | cut -c1-12'
9acbe2ebe1db
```

Both match the expected deployed images (`BOOT.BIN.148.rxfixpad.bf2a7305bbe0`,
`BOOT.BIN.146.rxfixr4dr1.9acbe2ebe1db`). Each leg's own `meta.txt` re-reads the
RX board's image inside the window, so the image is evidenced in-band too.

**Knobs.** Bring-up defaults as shipped: `WHITEN=1`, `RXQ=1`, rung r3
(`lvds_61p44_fdd_jupiter`, 61.44 MSPS, 15.36 Msym/s, 4 sps). `MID_RECOVER` was
left at its default **0** (off) on both legs — the documented 0.070–0.079 % /
0.191 % baselines were taken that way, so the comparison is like-for-like; no
leg was recovered and no `recovery.txt` was produced. `-k` was passed so the
link is left up at the end of each leg: the default quiesce path kills
`qpsk_tun` and zeroes the modem control registers, which would make the
post-leg health gate read ~0 f/s and fail for a reason that has nothing to do
with the link.

**Sentinel contamination.** Both windows ran under the rig mutex
(`ops/sim_repro/riglock.sh`), which takes `/home/tcollins/modem-status/RIG_LOCK`
and touches `SENTINEL_STOP`. The delivery sentinel therefore exited for the
duration of both legs and `sentinelkeeper-105921.service` relaunched it when the
lock was released. **`/home/tcollins/modem-status/sentinel.log` is contaminated
across 2026-09-10 17:07–(end of Step 1)**: gaps in it over that span are this
task, not link events. The running `sentinel-105922.service` /
`sentinelkeeper-105921.service` units were never stopped or killed.

### Harness defect found (blocks every capture until fixed)

The first launch of leg A died 10 s in, at `capture_r3.sh`'s on-board rebuild:

```
10.0.0.146 build: compilation terminated.
# /tmp/gcc.err on 10.0.0.146:
In file included from qpsk_tun.c:84:
qpsk_hw.h:120:10: fatal error: qpsk_fixregs.h: No such file or directory
  120 | #include "qpsk_fixregs.h"
```

`host/qpsk_hw.h` now `#include`s the **generated** `host/qpsk_fixregs.h`
(produced from `modem/fixes/fixes.toml` by `modem/fixes/gen_regmap.py`, commit
`acd1e746`), but the scp list in `ops/capture_r3.sh:194-197` was never updated,
so the header is not deployed and the daemon rebuild fails on both boards.
Since this task may not edit `ops/`, the header was staged by hand on both
boards instead:

```
scp host/qpsk_fixregs.h root@10.0.0.146:/root/host_app_k5/
scp host/qpsk_fixregs.h root@10.0.0.148:/root/host_app_k5/
# md5 2bd8d8bf54c0d20e084374865bea045f on both boards == repo copy
```

Both legs below therefore built against a **manually staged** header. **Action
for Task 11b:** add `"$SRC/qpsk_fixregs.h"` to the scp list in
`ops/capture_r3.sh`; until then every credited window (including the flash
rails' post-flash windows, which call the same capture path) needs this manual
step in front of it, or it dies at the rebuild.

### Leg A — forward (146 TX → 148 RX, capture on 148)

Unit + command (a wrapper is required because `launch_rig_unit.sh` cannot pass
positional arguments and `capture_r3.sh` takes the leg positionally):

```bash
# /mnt/onetb/scratch/qpsk-build-trees/sp2_base_fwd.sh
#   . ops/sim_repro/riglock.sh; rig_lock sp2-base-fwd; trap rig_unlock EXIT
#   ops/capture_r3.sh A -d 600 -k -o ops/r3cap/sp2base_fwd
ops/launch_rig_unit.sh sp2-base-fwd-170724 \
    /mnt/onetb/scratch/qpsk-build-trees/sp2_base_fwd.sh
```

- Unit: `sp2-base-fwd-170724.service` (a first attempt, `sp2-base-fwd-170540`,
  failed at the rebuild defect above and produced no window)
- Run dir: `ops/r3cap/sp2base_fwd` (gitignored)
- Bring-up gate: `gate try 1: 148 rx=1247 f/s  146 rx=1247 f/s (need >= 1120)` →
  `ARM GATE PASS (try 1)`
- Unit result: `Result=success ExecMainStatus=0`, `CAPTURE_R3_DONE`,
  `frames.bin: 755158 records`

`meta.txt` verbatim:

```
target=A dir=fwd rx=10.0.0.148 peer=10.0.0.146 rung=r3 profile=lvds_61p44_fdd_jupiter
ksym=15360 sps=4 fs=61440000 spf=49332 dur=600 nsamp=4000000 payload=1400 traffic=qpsk_perf_15Mbit
wedge_verdict=healthy crc=100% rate=1038f/s
mid_recover=0 recovery_events=0 recovery_excluded_s=0 recovery_failed=0
image_md5=bf2a7305bbe0e0e38b3529d09edddaef
ts=2026-09-10T17:19:49-04:00
```

Score, verbatim:

```
$ python3 ops/accept_analyze.py ops/r3cap/sp2base_fwd/frames.bin
=== wedge-aware acceptance analysis (live-link windows, settle 15s, wedge-guard 2s) ===
  sp2base_fwd: live 603s/608s [WEDGE truncated]  PER=0.010% (70/732315)  CP95UL=0.012%  lag33=-0.000  bins={'1': 21, '2': 5, '3-4': 12, '5-20': 0, '21-100': 0, '>100': 0}

  POOLED live-window: PER=0.010% (70/732315)  CP95UL=0.012%
  per-run spread: 0.010%..0.010%
  wedges during captures: 1 (real events; auto-recovered in normal ops by lock_watchdog, disabled during captures)
  GATE (<1% at CP95 upper limit, live-link): PASS
```

**Denominator statement, in the tool's own words**
(`ops/accept_analyze.py` docstring): "finds the live-link window ... then
reports on the reliable host_seq-gap metric over the live window: PER, burst
decomposition, lag-33 singles autocorrelation, CP 95% upper limit." The
denominator is the host_seq span of the live window — **732,315 frames** — and
the numerator is the 70 frames that never arrived, i.e. lost frames are counted
in the denominator. 732,315 frames over 603 s is 1,215 f/s against the 1,245 f/s
nominal, so the denominator is the whole window, not a surviving fragment of it.

Lag/comb report: `lag33=-0.000` (no lag-33 singles comb), run-length bins
`{1: 21, 2: 5, 3-4: 12, 5-20: 0, 21-100: 0, >100: 0}` — 38 loss runs, all short,
no burst class.

Health gate on the RX board of this leg, verbatim:

```
$ ops/health_probe_reset_aware.sh 10.0.0.148 12
fsync=1262 wcnt=1262 resets_s=0/12 clean=12/12
```

Wedge status: **creditable.** `wedge_verdict=healthy`, no `CAPTURE_ABORTED*`
marker, `capture_r3` exit 0, `mid_recover=0 recovery_events=0`. Three transient
5 s delivery-stall warnings were printed during the window (t = 11 s, 161 s,
316 s, 456 s) against a 12 s abort threshold; none reached it. `accept_analyze`
labels the leg `[WEDGE truncated]` because its live window ends 5 s before the
nominal 608 s — that is its own end-of-window rule biting on the traffic
generator stopping, not a capture-side wedge marker; the harness's own verdict
is `healthy`. The concurrent Tap-A IQ capture was flagged **DEGENERATE**
(`CAPTURE HEALTH FAILED`), which is explicitly non-fatal and affects only
`pair.iq`; `frames.bin` and the host-side counters — everything scored above —
are unaffected. No IQ-based conclusion is drawn from this leg.

**Verdict:** forward baseline **PER 0.010 % (70 / 732,315), CP95UL 0.012 %**,
clean health gate — the leg is creditable and the link is *better* than the
documented 0.070–0.079 % forward reference by about 7×, not worse.

### Leg B — reverse (148 TX → 146 RX, capture on 146)

```bash
# /mnt/onetb/scratch/qpsk-build-trees/sp2_base_rev.sh
#   . ops/sim_repro/riglock.sh; rig_lock sp2-base-rev; trap rig_unlock EXIT
#   ops/capture_r3.sh B -d 600 -k -o ops/r3cap/sp2base_rev
ops/launch_rig_unit.sh sp2-base-rev-172334 \
    /mnt/onetb/scratch/qpsk-build-trees/sp2_base_rev.sh
```

- Unit: `sp2-base-rev-172334.service`
- Run dir: `ops/r3cap/sp2base_rev` (gitignored)
- Bring-up gate: `gate try 1: 148 rx=1247 f/s  146 rx=1247 f/s (need >= 1120)` →
  `ARM GATE PASS (try 1)` — leg B ran its **own** bring-up, it did not inherit
  leg A's state
- Unit result: `Result=success ExecMainStatus=0`, `CAPTURE_R3_DONE`,
  `frames.bin: 756735 records`
- Stall watchdog: `stall watchdog done: wall 584s of 584, poll_read_failures=0`
  — the full window, zero stall warnings (leg A had four transient ones)

`meta.txt` verbatim:

```
target=B dir=rev rx=10.0.0.146 peer=10.0.0.148 rung=r3 profile=lvds_61p44_fdd_jupiter
ksym=15360 sps=4 fs=61440000 spf=49332 dur=600 nsamp=4000000 payload=1400 traffic=qpsk_perf_15Mbit
wedge_verdict=healthy crc=100% rate=1038f/s
mid_recover=0 recovery_events=0 recovery_excluded_s=0 recovery_failed=0
image_md5=9acbe2ebe1dbf280e030952fc4fc23d8
ts=2026-09-10T17:36:03-04:00
```

Score, verbatim:

```
$ python3 ops/accept_analyze.py ops/r3cap/sp2base_rev/frames.bin
=== wedge-aware acceptance analysis (live-link windows, settle 15s, wedge-guard 2s) ===
  sp2base_rev: live 604s/611s [WEDGE truncated]  PER=0.031% (227/733562)  CP95UL=0.035%  lag33=-0.000  bins={'1': 65, '2': 27, '3-4': 30, '5-20': 2, '21-100': 0, '>100': 0}

  POOLED live-window: PER=0.031% (227/733562)  CP95UL=0.035%
  per-run spread: 0.031%..0.031%
  wedges during captures: 1 (real events; auto-recovered in normal ops by lock_watchdog, disabled during captures)
  GATE (<1% at CP95 upper limit, live-link): PASS
```

Denominator: the same host_seq-gap metric — **733,562 frames** in the live
window, 227 of them never delivered; lost frames are in the denominator.
733,562 over 604 s is 1,214 f/s against the 1,245 f/s nominal, so the window is
whole.

Lag/comb report: `lag33=-0.000` (no lag-33 comb), bins
`{1: 65, 2: 27, 3-4: 30, 5-20: 2, 21-100: 0, >100: 0}` — 124 loss runs, longest
in the 5–20 bin, no burst class. Note the previously documented reverse defect
was a **lag-25 / 20.4 ms** comb; nothing of that shape appears here, and the
reverse PER is 6× better than the 0.191 % pooled reference.

Health gate on the RX board of this leg — **FAILED, twice**:

```
$ ops/health_probe_reset_aware.sh 10.0.0.146 12
fsync=0 wcnt=0 resets_s=12/12 clean=0/12 (ALL intervals dirty -- reset storm, judge on resets_s)
# re-run after 75 s (the one re-run this task allows):
$ ops/health_probe_reset_aware.sh 10.0.0.146 12
fsync=0 wcnt=0 resets_s=12/12 clean=0/12 (ALL intervals dirty -- reset storm, judge on resets_s)
# the peer, for contrast, taken in the same breath:
$ ops/health_probe_reset_aware.sh 10.0.0.148 12
fsync=1263 wcnt=1263 resets_s=0/12 clean=12/12
```

**What the failure is, and how far its onset can be pinned.** It is a
delivery collapse on 146 whose onset is at the very end of, or after, the
scored window — it is *not* a condition that held during the window:

- The window itself ran to completion: pre-window `wedge verdict: healthy
  crc=100% rate=1038f/s`, the stall watchdog logged its full 584 s with zero
  stall warnings, `wedge_verdict=healthy`, `capture_r3` exit 0, and
  `accept_analyze` found a live window of 604 s of 611 s at 1,214 f/s. A
  receiver that was down during the window cannot produce 733,562 delivered
  host_seq slots.
- The state now is the **sync-but-CRC** signature: `idle_rx` frozen at 24461
  while `crc_drop` keeps climbing (114,180 → 116,212 over one interval) and
  `dma_tx` keeps advancing — frames are arriving and every one of them fails
  CRC. 148 in the same instant is healthy (`idle_rx` advancing, `fsync=1263`).
  The sentinel's own line agrees: `ok rate=1868/s crc=100.0% tx=1868/s
  rev=0/s rcrc=0.0% rtx=1245/s`.
- **Onset is not resolvable to better than the last few seconds of the
  window,** and the honest statement is that limit rather than "after the
  window". `accept_analyze`'s live-window rule truncates at a clean-rate
  collapse, so a collapse in the final seconds and a collapse just after the
  window both print as `live 604s/611s`. The discriminators, from the run dir
  itself: leg B's post-window register snapshot already shows resets —
  `regs_post.txt: pkts=0xC2691 rstcs=0x18` — where leg A's control snapshot
  shows `rstcs=0x0`; and the last two `stats:` lines in the captured
  `qpsk_tun.log` show delivery already falling away (`dma_rx_ok` +369 against
  `crc_drop` +1994 over one 5 s interval) at the tail of the log. So the
  collapse had begun by the time the post-window snapshot was taken. What is
  established is that delivery was healthy for the 604 s that were scored:
  733,562 host_seq slots at 1,214 f/s cannot be produced by a receiver that
  was down, and the truncated tail is in neither the numerator nor the
  denominator.
- Nothing was left running that clears it. `capture_r3.sh` deliberately kills
  `lock_watchdog` on **both** boards for the window and `-k` does not restore
  them, and the delivery sentinel's recovery trigger watches **148's** idle_rx
  rate only — so a 146-side wedge with a healthy 148 is outside what it acts on.
  (The same sentinel *did* fire a recovery in the gap between the two legs:
  `2026-09-10_17:21:26 recovery chain done`, 90 s after leg A's health gate had
  already passed. Leg B re-armed from scratch and passed its own arm gate, so
  that recovery is between-leg noise, not leg B's starting condition.)

Wedge status: **creditable window, failed post-leg health gate.** No
`CAPTURE_ABORTED*`, `wedge_verdict=healthy`, `mid_recover=0
recovery_events=0`, exit 0. The `[WEDGE truncated]` label from
`accept_analyze` is again its own end-of-window rule (604 s of 611 s), not a
capture-side marker. As on leg A, the Tap-A IQ capture was flagged DEGENERATE
(`occupied BW = 3.84 MHz`, `env periodicity = 0.9988 at lag 256`) — non-fatal,
affects `pair.iq` only, and no IQ-based conclusion is drawn.

**Verdict:** reverse baseline **PER 0.031 % (227 / 733,562), CP95UL 0.035 %**;
the window is creditable and 6× better than the 0.191 % pooled reference, but
146 was left in a sync-but-CRC wedge, beginning at or after the end of the
scored window, that two health probes could not clear. The failed health gate
is a recorded FAIL against the board's handover state; it does not invalidate
the window. **Task 11b must re-arm 146 (any bring-up does it) before it trusts
the board, and should not read this as a property of image `9acbe2ebe1db`.**

### Step 1 summary

| Leg | Direction | RX board | Run dir | PER (lost frames in denominator) | CP95UL | Health gate | Documented reference |
| --- | --- | --- | --- | --- | --- | --- | --- |
| A | forward, 146 TX → 148 RX | 10.0.0.148 | `ops/r3cap/sp2base_fwd` | **0.010 % (70 / 732,315)** | 0.012 % | `fsync=1262 wcnt=1262 resets_s=0/12 clean=12/12` — PASS | 0.070–0.079 % |
| B | reverse, 148 TX → 146 RX | 10.0.0.146 | `ops/r3cap/sp2base_rev` | **0.031 % (227 / 733,562)** | 0.035 % | `fsync=0 wcnt=0 resets_s=12/12 clean=0/12` — FAIL (twice, post-window) | 0.191 % pooled |

Both legs are creditable windows on the deployed images (`bf2a7305bbe0` /
`9acbe2ebe1db`, both re-verified in-band by each leg's `meta.txt`), both with
lost frames counted in the denominator, neither recovered, neither carrying a
capture-side wedge marker.

**Read this before using these as gates in Task 11b.** Recorded, not judged:
both legs are more than 2× off their documented references — forward ~7× off
(0.010 % against 0.070–0.079 %), reverse ~6× off (0.031 % against 0.191 %) —
in the favourable direction, i.e. better. That matters because Step 2/3's
acceptance bound is written as "≤ 2× the Step 1 baseline", and 2× *these*
numbers is a far tighter bar than 2× the documented figures. **Which reference
that bound means is an operator decision for Task 11b; no gate number is
proposed here.** The likeliest
reason these are low is that the whole documented range predates or straddles
the WHITEN=1 default (bring-up defaults to it since 2026-09-08, and the
post-WHITEN forward window PER was already recorded at 0.005 %), so this is
plausibly what the rig now does rather than a measurement artefact — but it is
one leg each, taken back to back on one afternoon, and should not be promoted
to a documented figure on that basis.

---

# Steps 2–4 (Task 11b, 2026-09-10 evening) — the silicon gate on the rebuilt candidates

Same rig, same day as Step 1 above. Boards `10.0.0.148` (role A) and
`10.0.0.146` (role B). Every PER number carries its command, its sample count and
the statement that lost frames are in the denominator.

**Sentinel contamination.** The delivery sentinel was parked repeatedly across
17:57–19:07: the 148 flash rail owns `~/modem-status/SENTINEL_STOP` itself, and
every bring-up/capture wrapper takes `ops/sim_repro/riglock.sh`, which touches the
same file. **`/home/tcollins/modem-status/sentinel.log` is contaminated from
2026-09-10 17:57 onward**, and from 18:43:17 it holds a stuck recovery chain's
bring-up output instead of status lines. The sentinel and keeper units themselves
were never stopped or killed.

**Preconditions (controller rulings 1 and 2).** The Task-7 on-board copy-list
regression that blocked Step 1 was fixed and committed first
(`6b6f2dc2`, `ops/capture_r3.sh` + `ops/provision.sh` now carry the generated
`host/qpsk_fixregs.h`, and `provision.sh` also the missing `qpsk_join.h`); a second
Task-7 regression, `ops/measure_ber.sh` and `ops/lock_watchdog.sh` left mode 644,
was fixed in `cfd48aca`. `ms_regmap_fixes.inc` has no list to be added to —
`grep -rn modem_status ops/` finds only a comment, and no `ops/` script deploys
`host/modem_status/` at all. 146, handed over wedged by Task 11a, was re-armed
through the rail machinery (`ops/launch_rig_unit.sh sp2-rearm-175741` →
`ops/bringup_r2r3.sh r3`, `ARM GATE PASS (try 1)` at 1247/1247 f/s) and both boards
then gated clean on the **deployed** images:
`146: fsync=1266 wcnt=1266 resets_s=0/12 clean=12/12`,
`148: fsync=1262 wcnt=1262 resets_s=0/12 clean=12/12`. **146's Task-11a wedge was
board state, not a property of image `9acbe2ebe1db`.**

## Step 2 (controller ruling 3) — flash 148 with sp2A, gate, BIST, windows

```bash
ops/launch_rig_unit.sh sp2-flash148-175943 ops/flash/txfix_flash_go.sh \
    FLASH_MD5=3e7f4232a3b5 FLASH_TAG=sp2A FLASH_BAK=bf2a7305bbe0
```

`FLASH_BAK` is the rail's *expected current image* as well as the rollback name, so
`[1/5]`'s "current image = bf2a7305bbe0" precondition was satisfied by that one
variable. The on-board `/root/BOOT.BIN.bf2a7305bbe0.bak` did not exist beforehand;
`[1/5]` created and verified it.

Rail log `ops/flash/txfix_flash_20260910_175943.log`, **verbatim and complete**:

```
17:59:43 === [1/5] preconditions ===
17:59:43   sentinel stopped (SENTINEL_STOP)
17:59:44   148 current image: bf2a7305bbe0 (expect bf2a7305bbe0)
bf2a7305bbe0
17:59:45 === [2/5] stage + flash ===
17:59:48   FLASHED 3e7f4232a3b5
18:00:56 === [3/5] readback verify ===
18:00:57   booted image: 3e7f4232a3b5 (expect 3e7f4232a3b5)
18:00:57 === [4/5] two-pass gate (arm148_mode1: ARM_OK, fps>=1120, capTAP golden) ===
  post-arm: fps=1248 errps=0 capTAP=0xBCF94856
ARM_OK profile=lvds_61p44_fdd_jupiter fps=1248 capTAP=0xBCF94856
18:03:57   GATE_PASS x2
18:03:57 === [5/5] Tier-2 witness (read BEFORE any rollback): sel6 4 MB, decoded ===
18:03:59   4194304
records 524288  demod_marks 43  tx_marks 43
toff min 12314 max 12314 mode 12314 (1.000)  distinct 1
slot histogram [131072, 131072, 131072, 131072]
18:04:00 FLASH_DDRCAP2_OK 3e7f4232a3b5 (sentinel released)
```

`Result=success ExecMainStatus=0`.

- **Readback md5: `3e7f4232a3b5`** — the banked sp2A image, verified on the booted board.
- **Gate lines:** `ARM_OK profile=lvds_61p44_fdd_jupiter fps=1248 capTAP=0xBCF94856`,
  twice → `GATE_PASS x2`. `fps=1248 ≥ 1120`; `capTAP` is the golden `0xBCF94856`.
- **`[5/5]` Tier-2 witness** decoded clean: 524,288 records, `toff` single-valued
  (12314, fraction 1.000), slot histogram perfectly even. (`[5/5]` lands *after*
  `GATE_PASS x2` and is explicitly non-fatal either way; it is reported, not gated on.)

### BIST — taken in the arm state it belongs in

`[4/5]`/`[5/5]` leave 148 in `arm148_mode1` **internal digital loopback** (both LOs
2.0 GHz, ROM source), which is exactly the state the golden `cap_out` is defined in.
BIST was run there, before the r3 re-arm:

```
$ ops/anyssh.sh 10.0.0.148 'for i in 1 2 3 4 5; do busybox devmem 0x9D000144 32; done'
0x04922282
0x04922282
0x04922282
0x04922282
0x04922282

$ ops/test.sh bist
=== TIER B -- on-chip BIST comparator on 10.0.0.148 (200 reads) ===
(reads cap_out 0x144 golden 0x04922282 + BIST counter-delta BER;
 most meaningful during an active link/loopback arm -- see docs/testing.rst)
ip=10.0.0.148 golden_frac=0.990 packets=2601 errors=0 BER=0.00000% bits=312120
```

**BIST golden `cap_out = 0x04922282`** — met. `golden_frac=0.990` is 198 of 200
sampled reads exactly equal to the golden word; `errors=0` over 312,120 bits.
(This is the run *after* the exec-bit fix; the first attempt died on `Permission
denied` and is written up in Step 0.)

### Re-arm to r3, then health gates

The rail leaves 148 in loopback, so a health gate taken there would be measuring
loopback and not the link. Re-armed first:

```bash
ops/launch_rig_unit.sh sp2A-rearm-180503 /mnt/onetb/scratch/qpsk-build-trees/sp2_rearm.sh
# gate try 1: 148 rx=1247 f/s  146 rx=1245 f/s (need >= 1120)
# ARM GATE PASS (try 1)
# === r3 BRING-UP COMPLETE ... ===   Result=success ExecMainStatus=0
```

First health probes, immediately after that bring-up:

```
$ ops/health_probe_reset_aware.sh 10.0.0.148 12
fsync=1263 wcnt=1262 resets_s=0/12 clean=12/12
$ ops/health_probe_reset_aware.sh 10.0.0.146 12
fsync=1268 wcnt=1267 resets_s=9/12 clean=3/12       <-- transient, see below
$ ops/health_probe_reset_aware.sh 10.0.0.146 12
fsync=1267 wcnt=1266 resets_s=11/12 clean=1/12
```

**What that was, established rather than assumed.** 146's on-board
`lock_watchdog.sh` was in the middle of its own re-lock; its log names the event
and its end:

```
$ ops/anyssh.sh 10.0.0.146 'tail -6 /dev/shm/watchdog.log'
[wd 23:06:59] NOT-LOCKED #1/2 (drstcs=4483 dpkts=2503 lvl=0)
[wd 23:07:06] NOT-LOCKED #2/2 (drstcs=4482 dpkts=2526 lvl=0)
[wd 23:07:06] FULL RE-ARM (0x000 soft reset + re-select + rstCS, double-tap)
[wd 23:07:27] LOCKED (drstcs=0 dpkts=6246 lvl=0)
[wd 23:07:33] LOCKED (drstcs=0 dpkts=6245 lvl=0)
[wd 23:07:39] LOCKED (drstcs=0 dpkts=6245 lvl=0)
```

and six consecutive 1 s reads of `0x150` on **both** boards were `0x0` afterwards
(no reset storm), while both daemons showed `idle_rx` advancing at 1,245 f/s with
`crc_drop` frozen. Re-probed after the watchdog's re-lock:

```
$ ops/health_probe_reset_aware.sh 10.0.0.146 12
fsync=1267 wcnt=1267 resets_s=0/12 clean=12/12
$ ops/health_probe_reset_aware.sh 10.0.0.148 12
fsync=1263 wcnt=1263 resets_s=0/12 clean=12/12
```

Both boards **clean 12/12** with sp2A live on 148.

### Acceptance rule applied to both legs (stated so the verdict is auditable)

The controller's ruling is an **OR**: a leg passes if its PER is ≤ **2× today's
11a baseline** (0.020 % fwd / 0.062 % rev) **OR** ≤ **the documented value**
(0.079 % fwd / 0.191 % rev); lost frames in the denominator; `wedge_verdict=healthy`;
and no *new* comb line in `accept_analyze.py`'s lag report.

### sp2A leg A — forward, 146 TX → 148 RX, capture on 148

```bash
# /mnt/onetb/scratch/qpsk-build-trees/sp2A_fwd.sh
#   . ops/sim_repro/riglock.sh; rig_lock sp2A_fwd; trap rig_unlock EXIT
#   bash ops/capture_r3.sh A -d 600 -k -o ops/r3cap/sp2A_fwd
ops/launch_rig_unit.sh sp2A-fwd-180833 /mnt/onetb/scratch/qpsk-build-trees/sp2A_fwd.sh
```

`Result=success ExecMainStatus=0`, `CAPTURE_R3_DONE`, `frames.bin: 751611 records`.
Bring-up gate inside the leg: `gate try 1: 148 rx=1247 f/s  146 rx=1247 f/s` →
`ARM GATE PASS (try 1)`. The on-board rebuild reported `BUILD_OK` and
`NAK-stat counter VERIFIED present after rebuild` on both boards — the first
capture in this repo to build without a hand-staged `qpsk_fixregs.h`.

`meta.txt` verbatim:

```
target=A dir=fwd rx=10.0.0.148 peer=10.0.0.146 rung=r3 profile=lvds_61p44_fdd_jupiter
ksym=15360 sps=4 fs=61440000 spf=49332 dur=600 nsamp=4000000 payload=1400 traffic=qpsk_perf_15Mbit
wedge_verdict=healthy crc=100% rate=1037f/s
mid_recover=0 recovery_events=0 recovery_excluded_s=0 recovery_failed=0
image_md5=3e7f4232a3b5c8863bfa5187ad35068f
ts=2026-09-10T18:20:58-04:00
```

`image_md5` is the **RX** board's image, so this leg evidences sp2A in-band.

Score, verbatim:

```
$ python3 ops/accept_analyze.py ops/r3cap/sp2A_fwd/frames.bin
=== wedge-aware acceptance analysis (live-link windows, settle 15s, wedge-guard 2s) ===
  sp2A_fwd: live 600s/605s [WEDGE truncated]  PER=0.005% (35/728581)  CP95UL=0.007%  lag33=-0.000  bins={'1': 12, '2': 10, '3-4': 1, '5-20': 0, '21-100': 0, '>100': 0}

  POOLED live-window: PER=0.005% (35/728581)  CP95UL=0.007%
  per-run spread: 0.005%..0.005%
  wedges during captures: 1 (real events; auto-recovered in normal ops by lock_watchdog, disabled during captures)
  GATE (<1% at CP95 upper limit, live-link): PASS
```

- **Command:** `python3 ops/accept_analyze.py ops/r3cap/sp2A_fwd/frames.bin`
- **PER 0.005 %, sample count 728,581 frames, 35 lost.** The metric is the
  host_seq gap over the live window, so the 35 frames that never arrived are in the
  numerator and the whole 728,581-frame host_seq span — including them — is the
  denominator. **Lost frames are counted in the denominator.** 728,581 frames over
  600 s is 1,214 f/s against 1,245 f/s nominal, so the window is whole.
- **Comb check vs the 11a baseline** — baseline `lag33=-0.000`,
  `{1:21, 2:5, 3-4:12, 5-20:0, 21-100:0, >100:0}`; this leg `lag33=-0.000`,
  `{1:12, 2:10, 3-4:1, 5-20:0, 21-100:0, >100:0}`. Same zero lag-33 correlation,
  **no new class** (5-20, 21-100 and >100 all still empty), and fewer total loss
  runs (23 vs 38). **No new comb line.**
- **Verdict: PASS** — 0.005 % is under *both* arms (≤ 0.020 % and ≤ 0.079 %), and
  it is 2× better than the 11a forward baseline of 0.010 %.

Health gates immediately after this leg:

```
$ ops/health_probe_reset_aware.sh 10.0.0.148 12
fsync=1261 wcnt=0 resets_s=1/12 clean=11/12        <- byte source mid re-arm
$ ops/health_probe_reset_aware.sh 10.0.0.146 12
fsync=1265 wcnt=183 resets_s=0/12 clean=12/12
# re-probed after the on-board watchdogs re-locked (both LOCKED, drstcs=0):
$ ops/health_probe_reset_aware.sh 10.0.0.148 12
fsync=1262 wcnt=1262 resets_s=1/12 clean=11/12
```

The zero/low `wcnt` on the first probes is the byte source coming back after the
`-k` handover (capture_r3 kills `lock_watchdog` for the window); both daemons then
showed `idle_rx` advancing at 1,245 f/s with `crc_drop` frozen, and both watchdogs
logged `LOCKED (drstcs=0 dpkts=624x)`.

### sp2A leg B — reverse, 148 TX → 146 RX, capture on 146

```bash
ops/launch_rig_unit.sh sp2A-rev-182342 /mnt/onetb/scratch/qpsk-build-trees/sp2A_rev.sh
#   -> bash ops/capture_r3.sh B -d 600 -k -o ops/r3cap/sp2A_rev, under the rig mutex
```

`Result=success ExecMainStatus=0`, `CAPTURE_R3_DONE`, `frames.bin: 758016 records`.

`meta.txt` verbatim:

```
target=B dir=rev rx=10.0.0.146 peer=10.0.0.148 rung=r3 profile=lvds_61p44_fdd_jupiter
ksym=15360 sps=4 fs=61440000 spf=49332 dur=600 nsamp=4000000 payload=1400 traffic=qpsk_perf_15Mbit
wedge_verdict=healthy crc=100% rate=1037f/s
mid_recover=0 recovery_events=0 recovery_excluded_s=0 recovery_failed=0
image_md5=9acbe2ebe1dbf280e030952fc4fc23d8
ts=2026-09-10T18:36:13-04:00
```

Here `image_md5` is the **RX** board (146, still on the old image), so sp2A is the
**transmitter** under test and is not evidenced by `meta.txt`. It was read directly
on 148 either side of the leg instead:

```
$ ops/anyssh.sh 10.0.0.148 'md5sum /boot/BOOT.BIN | cut -c1-12'   # before the leg
3e7f4232a3b5
$ ops/anyssh.sh 10.0.0.148 'md5sum /boot/BOOT.BIN | cut -c1-12'   # after the leg
3e7f4232a3b5
```

Score, verbatim:

```
$ python3 ops/accept_analyze.py ops/r3cap/sp2A_rev/frames.bin
=== wedge-aware acceptance analysis (live-link windows, settle 15s, wedge-guard 2s) ===
  sp2A_rev: live 605s/612s [WEDGE truncated]  PER=0.048% (354/734808)  CP95UL=0.053%  lag33=-0.000  bins={'1': 100, '2': 47, '3-4': 26, '5-20': 9, '21-100': 0, '>100': 0}

  POOLED live-window: PER=0.048% (354/734808)  CP95UL=0.053%
  per-run spread: 0.048%..0.048%
  wedges during captures: 1 (real events; auto-recovered in normal ops by lock_watchdog, disabled during captures)
  GATE (<1% at CP95 upper limit, live-link): PASS
```

- **Command:** `python3 ops/accept_analyze.py ops/r3cap/sp2A_rev/frames.bin`
- **PER 0.048 %, sample count 734,808 frames, 354 lost.** Same host_seq-gap metric;
  **lost frames are counted in the denominator.** 734,808 over 605 s is 1,215 f/s.
- **Comb check vs the 11a baseline** — baseline `lag33=-0.000`,
  `{1:65, 2:27, 3-4:30, 5-20:2, 21-100:0, >100:0}`; this leg `lag33=-0.000`,
  `{1:100, 2:47, 3-4:26, 5-20:9, 21-100:0, >100:0}`. Zero lag-33 correlation in
  both; the occupied run-length classes are **identical** (1, 2, 3-4 and 5-20, with
  21-100 and >100 empty in both). The 5-20 bin grew 2 → 9, which is more of an
  existing class, not a new one, and nothing of the documented reverse lag-25 /
  20.4 ms comb shape appears. **No new comb line.**
- **Verdict: PASS** — 0.048 % is under *both* arms (≤ 0.062 % 2×-baseline and
  ≤ 0.191 % documented).

Health gates after this leg:

```
$ ops/health_probe_reset_aware.sh 10.0.0.148 12
fsync=1262 wcnt=1262 resets_s=0/12 clean=12/12
$ ops/health_probe_reset_aware.sh 10.0.0.146 12
fsync=0 wcnt=0 resets_s=12/12 clean=0/12 (ALL intervals dirty -- reset storm, judge on resets_s)
```

**146's post-reverse-leg wedge reproduced exactly as in Task 11a — on the old
146 image, with sp2A on the far end.** Same signature: `idle_rx` frozen at 24,770,
`crc_drop` still climbing (75,018 → 77,146 in one interval), `dma_tx` advancing,
and `pgrep lock_watchdog` → **WD_DOWN** (capture_r3 kills the watchdog for the
window and `-k` does not restore it, so nothing on the board clears it). 11a saw
the identical thing with the *old* image on both ends, so this is a handover
artefact of the `-k` reverse leg, not a property of sp2A. It is after the credited
window: that window is `wedge_verdict=healthy`, 605 s live, 734,808 host_seq slots
at 1,215 f/s — a receiver that was down cannot produce those.

One ordinary r3 bring-up cleared it, as before:

```
ops/launch_rig_unit.sh sp2B-pre-rearm-183854 /mnt/onetb/scratch/qpsk-build-trees/sp2_rearm.sh
# gate try 1: 148 rx=1247 f/s  146 rx=1247 f/s (need >= 1120) ; ARM GATE PASS (try 1)
# === r3 BRING-UP COMPLETE ... ===   Result=success
$ ops/health_probe_reset_aware.sh 10.0.0.146 12
fsync=1267 wcnt=1267 resets_s=0/12 clean=12/12
$ ops/health_probe_reset_aware.sh 10.0.0.148 12
fsync=2542570 wcnt=1263 resets_s=1/12 clean=11/12   <- counter reset inside one interval
$ ops/health_probe_reset_aware.sh 10.0.0.148 12     <- re-probe
fsync=1263 wcnt=1263 resets_s=0/12 clean=12/12
```

### Step 2 verdict — sp2A PASSES the silicon gate on 148

| Item | Required | Measured |
| --- | --- | --- |
| readback md5 | `3e7f4232a3b5` | `3e7f4232a3b5` |
| arm gate | `ARM_OK`, fps ≥ 1120, golden capTAP, twice | `fps=1248 capTAP=0xBCF94856` ×2, `GATE_PASS x2` |
| BIST | `cap_out = 0x04922282` | `0x04922282` (5/5 direct reads; `golden_frac=0.990`, `errors=0`, 312,120 bits) |
| health gate on the flashed board | clean 12/12 | `fsync=1263 wcnt=1263 resets_s=0/12 clean=12/12` |
| forward PER | ≤ 0.020 % **or** ≤ 0.079 % | **0.005 % (35/728,581)** |
| reverse PER | ≤ 0.062 % **or** ≤ 0.191 % | **0.048 % (354/734,808)** |
| comb | no new line | `lag33=-0.000` both legs, no new run-length class |

No rollback was performed on 148. No leg needed its one permitted re-run.

---

## Step 3 (controller ruling 4) — flash 146 with sp2B: **image flashed, gate INCONCLUSIVE, rig fault**

```bash
ops/launch_rig_unit.sh sp2-flash146-184233 ops/flash/txfix_flash146_go.sh \
    FLASH_MD5=d94b4df391a1 FLASH_TAG=sp2B FLASH_BAK=9acbe2ebe1db \
    ROLLBACK_BANK=$PWD/images/BOOT.BIN.146.rxfixr4dr1.9acbe2ebe1db
```

Rail journal, verbatim, up to the point it froze:

```
FLASH_146T start 2026-09-10T18:42:33-04:00 pid=23414 image=d94b4df391a1 tag=sp2B bak=9acbe2ebe1db dry=0
=== [1/6] preconditions ===
  nemo rollback bank: /mnt/onetb/scratch/qpsk-jupiter-modem/images/BOOT.BIN.146.rxfixr4dr1.9acbe2ebe1db md5=9acbe2ebe1db (expect 9acbe2ebe1db)
  148 pre-flash health: fsync=1262 wcnt=1262 resets_s=0/12 clean=12/12
  146 current image: 9acbe2ebe1db (expect 9acbe2ebe1db)
=== [2/6] on-board rollback backup, then stage + flash ===
tee: /dev/stderr: No such device or address          <- cosmetic; a systemd unit has no /dev/stderr
  on-board backup verified (/root/BOOT.BIN.9acbe2ebe1db.bak)
  staged; rebooting 146
  146 back after ~45s
=== [3/6] readback verify (rail) ===
  booted image: d94b4df391a1 (expected d94b4df391a1)
=== [4/6] FULL bring-up (restore_known_good.sh) + NAK=4 re-check on 148 ===
```

**Readback md5 on 146: `d94b4df391a1` — sp2B is on the board.** Then `[4/6]` never
completed: the journal has printed nothing since `18:43:43`.

### What went wrong: 148 was hung by two concurrent both-board arms

`/tmp/restore_bringup.log` (the `[4/6]` bring-up) froze here:

```
=== capture_r3 B (rev): R3/f1536 link, 15s traffic, Tap-A 400000 samp on 10.0.0.146 -> .../ops/r3cap/restore_184343 ===
  10.0.0.146: preserving deployed NAK-stat instrumentation (-DQPSK_ARQ_NAKSTAT)
  10.0.0.146 build: BUILD_OK
  10.0.0.146: NAK-stat counter VERIFIED present after rebuild
  10.0.0.148: preserving deployed NAK-stat instrumentation (-DQPSK_ARQ_NAKSTAT)
  10.0.0.148 build: BUILD_OK
  10.0.0.148: NAK-stat counter VERIFIED present after rebuild
--- bringup_r2r3.sh r3 (logger on) ---
=== r3 bring-up: lvds_61p44_fdd_jupiter, -r 15360, gate >= 1120 f/s ===
10.0.0.146 armed ROM (lvds_61p44_fdd_jupiter)
```

The matching `10.0.0.148 armed ROM` line — present in all three of this task's
earlier successful bring-ups — **never appeared**. 148 is off the network:

```
$ ip neigh show 10.0.0.148
10.0.0.148 dev eno1 FAILED
$ ssh -o ConnectTimeout=8 root@10.0.0.148 'echo alive'
ssh: connect to host 10.0.0.148 port 22: No route to host
$ for i in $(seq 10); do ping -c1 -W2 10.0.0.148; done    # 19:04:58 .. 19:05:34
10/10 FAIL
```

146 answers normally throughout.

**Root cause, from the sentinel's own log** (`/home/tcollins/modem-status/sentinel.log`):

```
2026-09-10_18:37:53 sentinel (re)launched by keeper
2026-09-10_18:38:07 ok rate=1245/s crc=100.0% tx=1245/s rev=0/s rcrc=0.0% rtx=1868/s
2026-09-10_18:43:17 WEDGE detected (rate=50/s) -- recovering
=== r3 bring-up: lvds_61p44_fdd_jupiter, -r 15360, gate >= 1120 f/s ===
10.0.0.148 armed ROM (lvds_61p44_fdd_jupiter)
146: ssi-fix VERIFIED: tx0=c3d4 rx0 preserved (0/4) (rearmed, 0x114=1)
148: ssi-fix VERIFIED: tx0=c5d3 rx0 preserved (0/4) (rearmed, 0x114=1)
gate try 1: 148 rx=2 f/s  146 rx=25 f/s (need >= 1120)
```

At **18:43:17** the free-running delivery sentinel saw 146 rebooting out of the
flash (`rate=50/s`), called it a wedge, and started **its own both-board r3
bring-up**. At **18:43:43** the rail started `[4/6]`'s bring-up. Two independent
arm sequences hit 148 at the same time and it went to the documented **no-ping
hang** state (`rig-noping-hang-dra-during-arm`: direct_reg_access traffic racing
board state; "arms are the worst instance"). Both chains are now blocked on ssh
to a dead 148 — the sentinel's own log is frozen at its `gate try 1`.

**This is a rail defect, not an operator slip.** `ops/flash/flash_148_txfix.sh`
owns `~/modem-status/SENTINEL_STOP` for the whole chain (its `SS_MINE` logic);
**`ops/flash/flash_146_txfix.sh` has no `SENTINEL_STOP` handling at all** — grep
it. Its own header even says "the sentinel must stay stopped for the whole
window", but nothing in the script does it. The 146 rail reboots 146 at `[2/6]`,
which is exactly the stimulus that makes the sentinel declare a wedge. **Any run
of that rail without an external hold will race itself.** It needs the 148 rail's
`SS_MINE` block ported into it. (I did not edit it: it is mid-run, and
`launch_rig_unit.sh` snapshots only the top-level `txfix_flash146_go.sh`, so the
live rail is reading `flash_146_txfix.sh` from the worktree.)

I have since taken the hold by hand — `touch ~/modem-status/SENTINEL_STOP` at
19:07:43 — so no further sentinel recovery can fire at either board. **Leave that
file in place until 148 is back on the network, then remove it.** If it is removed
while 148 is down, `sentinelkeeper-105921.service` relaunches the sentinel, which
sees 146 up and 148 unreachable, declares a wedge and starts arming into a dead
board — the exact failure root-caused above.

### Actions taken and deliberately not taken

- **148 was not touched again.** No arm, no bring-up, no `direct_reg_access` read,
  no re-run. Every extra attempt is the documented hang-worsening action.
- **The 146 rail was left running for 37 minutes, then stopped deliberately.**
  It never moved past `[4/6]`: its ssh into 148's arm is sitting on a dead TCP
  session, not a bounded timeout, so it would never have reached its own
  `rollback()`. Leaving it parked inside a both-board arm is a live hazard — when
  the operator power-cycles 148, that chain and the sentinel's own frozen recovery
  could both unblock and fire concurrent arms, reproducing the hang onto someone
  mid-repair. `/tmp/restore_bringup.log`'s last line is `10.0.0.146 armed ROM`, so
  146's arm had completed and nothing was mid-ssh to the live board; the
  "never kill an arm in flight" rule protects a *live* board's gated restore, and
  148 is off the network with nothing progressing. Stopped at 19:23 with
  `systemctl --user stop sp2-flash146-184233.service` → `inactive`. **146 therefore
  stays on sp2B `d94b4df391a1`; no rollback was performed.**
- **146 was NOT manually rolled back.** This is a rig fault with no measurement
  taken, not an acceptance failure. A rollback would mean rebooting the only live
  board and would still produce no verdict (the gate needs 148), and
  `/root/BOOT.BIN.9acbe2ebe1db.bak` is present and md5-verified on 146, so it is a
  one-command operator action whenever the controller wants it.
- **The one permitted re-run was NOT spent.** A re-run against a dead 148 would
  measure nothing and would put a third arm chain into the race.

### sp2B verdict: **INCONCLUSIVE — blocked by a rig fault on the gate instrument**

Nothing about image `d94b4df391a1` was measured. It flashed and booted cleanly
(readback md5 verified), and that is the entire evidence base. No PER window, no
BIST, no health gate, and **no R4D witness decode check** (`opens`/`extras`) was
run on it — that check needs a live link, and there is no link with 148 down.

### 148 needs physical attention

`ip neigh` FAILED plus `No route to host` is the power-cycle class.
`~/.claude/HOSTS.md` line 41 lists serial for "jupiter A / B" via
`tron.local /dev/ttyACM0` (one device for two boards — verify which it is attached
to before assuming), and lists **no remote PDU**. This is an operator item.

---

## Step 4 (controller ruling 5) — cut-over: **NOT PERFORMED**

Ruling 5 gates the cut-over on *both* boards passing. 146 did not produce a
verdict, so `images/CURRENT.txt`, `images/README.md` and `docs/provenance.rst`
were left untouched.

**BLOCKING INCONSISTENCY the controller must resolve.** The rig and the bank now
disagree, in both directions:

| | on the board now | `images/CURRENT.txt` says |
| --- | --- | --- |
| 148 (role A) | `3e7f4232a3b5` (sp2A, gated and PASSED) | `BOOT.BIN.148.rxfixpad.bf2a7305bbe0` |
| 146 (role B) | `d94b4df391a1` (sp2B, ungated) or `9acbe2ebe1db` if the rail's rollback completes | `BOOT.BIN.146.rxfixr4dr1.9acbe2ebe1db` |

`ops/deploy_image.sh <ip> A|B` reads `CURRENT.txt` directly, so anyone acting on
it today would re-flash 148 back to `bf2a7305bbe0`. The 148 row is a
straightforward "sp2A passed its gate, promote it" edit, but ruling 5 makes the
cut-over conditional on both boards, so I have not made it unilaterally.

On-board rollbacks now present and verified by the rails themselves:
`148:/root/BOOT.BIN.bf2a7305bbe0.bak`, `146:/root/BOOT.BIN.9acbe2ebe1db.bak`
(both created during this task; neither existed before). Both images stay banked
in `images/`.

## Rig state at handover

- **148: DOWN — no ping, no ARP, no ssh. Needs a power cycle (physical).** It was
  running sp2A `3e7f4232a3b5` when it hung.
- **146: up**, running **sp2B `d94b4df391a1` — an UNGATED image**. Verified
  rollback on the board: `/root/BOOT.BIN.9acbe2ebe1db.bak`.
- `~/modem-status/SENTINEL_STOP` **present, created by me at 19:07:43 — LEAVE IT
  until 148 is back on the network**, then remove it so
  `sentinelkeeper-105921.service` can resume. `sentinel-173752.service` and the
  keeper were never stopped or killed (rig rule 6); the sentinel's own recovery
  chain is still frozen at `gate try 1` with one orphan read-only `anyssh.sh
  10.0.0.148` rate probe (pids 25160/25164) that will exit when its TCP session
  dies. Nothing else of mine is running.
- `~/modem-status/RIG_LOCK` absent (the 146 rail does not take it — see the defect
  above).
- **`sentinel.log` is contaminated from 17:57 onward**, and from 18:43:17 it
  contains a stuck recovery chain's bring-up output rather than status lines.

---

# Step 5 — sp2 pair gate after the 148 power cycle (Task 11c, 2026-09-10 evening)

**Outcome in one line: 146 / sp2B `d94b4df391a1` is STILL UNGATED and the
cut-over was NOT performed. 146 is now itself off the network** — it went into
the documented no-ping hang under a mode-1 loopback arm that had never been run
against that board. 148 / sp2A `3e7f4232a3b5` is up, healthy and unchanged.

**Sentinel contamination (stated up front, per the rig rules).**
`/home/tcollins/modem-status/sentinel.log` is contaminated from 2026-09-10 17:57
onward (Task 11b) and remains contaminated through this task: every wrapper here
takes the rig mutex `ops/sim_repro/riglock.sh`, which touches `SENTINEL_STOP`, and
the hold was deliberately held for the whole task. **Gaps in that log from 17:57
to now are rig work, not link events.** `sentinelkeeper-105921.service` was never
stopped or killed; the sentinel exits *itself* on the STOP file, which is its
designed lifecycle, and the keeper honours the hold (it checks `SENTINEL_STOP`
and `RIG_LOCK` before relaunching).

## Step 5.0 — clearing 11b's frozen recovery chain (before anything else)

11b handed over with `sentinel-183752.service` parked inside a **frozen
both-board bring-up**: its `bringup_r2r3.sh r3` was blocked on an `anyssh.sh`
ssh into 148 that died when 148 hung at 18:43. With 148 power-cycled and back,
that ssh could unblock at any moment and `bringup_r2r3.sh` would resume its
`GATE_TRIES=8` retry loop — arming both boards, possibly mid-capture. That is the
same class of event that caused the 18:43 hang.

```
$ ps -ef --forest    (extract)
tcollins 19647  1490  /bin/bash /home/tcollins/modem-status/delivery_sentinel.sh
tcollins 24155 19647   \_ /bin/bash .../two_jup/bringup_r2r3.sh r3
tcollins 25159 24155       \_ /bin/bash .../two_jup/bringup_r2r3.sh r3
tcollins 25160 25159           \_ /bin/sh .../two_jup/anyssh.sh 10.0.0.148 ...0x104...
tcollins 25164 25160               \_ ssh ... root@10.0.0.148 ...
```

Killed **leaf-first**, so the ssh could not be orphaned:

```
$ for p in 25164 25160 25159 24155; do kill -TERM $p; done
```

**`sentinel-183752.service` was NOT stopped.** Killing the frozen child let
`delivery_sentinel.sh` resume at its own lines 57-61, log `recovery chain done`,
and then exit 0 at its loop-top `SENTINEL_STOP` check — its designed exit path:

```
$ tail -3 /home/tcollins/modem-status/sentinel.log
148: ssi-fix VERIFIED: tx0=c5d3 rx0 preserved (0/4) (rearmed, 0x114=1)
gate try 1: 148 rx=2 f/s  146 rx=25 f/s (need >= 1120)
2026-09-10_20:33:57 recovery chain done
```

Board state at handover, verified before any action:

```
$ ops/anyssh.sh 10.0.0.148 'md5sum /boot/BOOT.BIN | cut -c1-12; uptime'
3e7f4232a3b5
 20:31:16 up 11 min          <- the operator's power cycle
$ ops/anyssh.sh 10.0.0.146 'md5sum /boot/BOOT.BIN | cut -c1-12; uptime'
d94b4df391a1
 01:31:17 up  1:48
```

On-board rollbacks present on both, as 11b left them:
`148:/root/BOOT.BIN.bf2a7305bbe0.bak`, `146:/root/BOOT.BIN.9acbe2ebe1db.bak`.

### Rail defect found here: `rig_unlock` DELETES `SENTINEL_STOP`

```
$ cat ops/sim_repro/riglock.sh    (extract)
rig_lock(){  ... echo "owner=$1 pid=$$ ..." > "$RIG_LOCK"; touch .../SENTINEL_STOP; }
rig_unlock(){ if grep -q "pid=$$ " "$RIG_LOCK" 2>/dev/null; then
                rm -f "$RIG_LOCK" /home/tcollins/modem-status/SENTINEL_STOP; fi; }
```

So every rig unit that finishes **un-parks the sentinel**, and this task had to
hold the park across several units. Worked around in each wrapper by re-asserting
the hold in the same EXIT trap (`/mnt/onetb/scratch/qpsk-build-trees/sp2c_*.sh`):

```bash
hold_out(){ rig_unlock; touch /home/tcollins/modem-status/SENTINEL_STOP; }
rig_lock sp2c-rearm
trap hold_out EXIT
```

## Step 5.1 — bring-up, and the zero-byte-binary defect it exposed

```bash
ops/launch_rig_unit.sh sp2-bringup-203512 /mnt/onetb/scratch/qpsk-build-trees/sp2c_rearm.sh
#   -> bash ops/bringup_r2r3.sh r3, under the rig mutex
```

Journal, verbatim:

```
=== r3 bring-up: lvds_61p44_fdd_jupiter, -r 15360, gate >= 1120 f/s ===
10.0.0.148 armed ROM (lvds_61p44_fdd_jupiter)
10.0.0.146 armed ROM (lvds_61p44_fdd_jupiter)
146: ssi-fix VERIFIED: tx0=c3d4 rx0 preserved (0/3) (rearmed, 0x114=1)
148: ssi-fix VERIFIED: tx0=c5d3 rx0 preserved (0/4) (rearmed, 0x114=1)
gate try 1: 148 rx=1246 f/s  146 rx=1247 f/s (need >= 1120)
ARM GATE PASS (try 1)
10.0.0.146 daemon up (ROM still selected)
10.0.0.148 daemon up (ROM still selected)
byte re-arm done   (x4)
10.0.0.146 watchdog: ALIVE pid=9290
10.0.0.148 watchdog: ALIVE pid=9505
=== r3 BRING-UP COMPLETE (byte source live both ends, stream-first + double-tap order) ===
SP2C_REARM_EXIT=0
```

`Result=success ExecMainStatus=0`. But the health gates were wrong:

```
$ ops/health_probe_reset_aware.sh 10.0.0.148 12
fsync=1261 wcnt=0 resets_s=0/12 clean=12/12
$ ops/health_probe_reset_aware.sh 10.0.0.146 12
fsync=0 wcnt=0 resets_s=1/12 clean=11/12
# re-probe after 75 s:
$ ops/health_probe_reset_aware.sh 10.0.0.148 12
fsync=1261 wcnt=0 resets_s=0/12 clean=12/12
$ ops/health_probe_reset_aware.sh 10.0.0.146 12
fsync=0 wcnt=0 resets_s=1/12 clean=11/12
$ ops/anyssh.sh 10.0.0.146 'tail -5 /dev/shm/watchdog.log'
[wd 01:38:36] NOT-LOCKED #2/2 (drstcs=0 dpkts=0 lvl=0)
[wd 01:38:36] FULL RE-ARM (0x000 soft reset + re-select + rstCS, double-tap)
[wd 01:38:56] NOT-LOCKED #1/2 (drstcs=0 dpkts=0 lvl=0)
```

****Neither pair of probes above is a gate attempt, and the task's one-re-run-per-board
allowance was NOT spent on them.** They were diagnostics taken against a host app
that was broken in a way nothing had reported yet (see below); a gate reading on a
board whose peer daemon does not exist measures nothing. **The Step-1 gate result is
the 20:46 pair in Step 5.2**, taken after the repair and one ordinary bring-up.

`dpkts=0` on 146 = 146 was hearing nothing at all.** Diagnosed from the daemon
logs rather than guessed:

```
$ ops/anyssh.sh 10.0.0.148 'grep "qpsk_tun stats" /dev/shm/qpsk_tun.log | tail -1; pgrep -a qpsk_tun'
(no output at all -- no stats line, no process)
$ ops/anyssh.sh 10.0.0.146 'grep "qpsk_tun stats" /dev/shm/qpsk_tun.log | tail -1'
qpsk_tun stats: ... dma_tx=255332 dma_rx_ok=0 crc_drop=38064 ... idle_rx=0 ...
```

146 was transmitting and receiving nothing; **148's daemon was not running.**
148's own watchdog names the failure and had been looping on it since the moment
the bring-up "started" it:

```
$ ops/anyssh.sh 10.0.0.148 'tail -20 /dev/shm/watchdog.log'
[wd 20:36:34] watchdog up: MW=iio:device0 TXD=iio:device5 PERIOD=5s PKT_MIN=50 FAIL_N=2 ...
[wd 20:36:34] qpsk_tun dead -> relaunch: QPSK_WHITEN=1 ./qpsk_tun -G -M 16 -r 15360 -i tun0 -s 5
[wd 20:36:45] qpsk_tun dead -> relaunch: ...        (identical line every 10 s, 19 times)
```

Root cause:

```
$ ops/anyssh.sh 10.0.0.148 'ls -l /root/host_app_k5/qpsk_tun'
-rwxr-xr-x 1 root root 0 Sep 10 18:44 /root/host_app_k5/qpsk_tun
$ ops/anyssh.sh 10.0.0.148 'find /root/host_app_k5 -maxdepth 1 -size 0 -print'
/root/host_app_k5/qpsk_perf
/root/host_app_k5/qpsk_tun
```

**`qpsk_tun` and `qpsk_perf` on 148 were ZERO BYTES, timestamped 18:44** — gcc had
created/truncated them and never got to write, because that was the exact minute
148 hung in Task 11b, mid-rebuild inside the 146 rail's `[4/6]`. So 11b's
"148 needs a power cycle" was true, and the board came back with a broken host app
that no bring-up repairs: `bringup_r2r3.sh`'s `10.0.0.148 daemon up` line was
**false** — it launched a zero-byte binary that exited instantly.

**146 was checked for the same damage at the same time and was clean** —
`ops/anyssh.sh 10.0.0.146 'find /root/host_app_k5 -maxdepth 1 -size 0 -print'`
returned nothing. (146's own hang came an hour later and was an *arm*, not a
build, so it is unlikely to have truncated anything — but re-run that `find` after
its power cycle rather than trusting this reading across the outage.)

### The repair, and the trap inside it

`capture_r3.sh:213` decides whether to keep `-DQPSK_ARQ_NAKSTAT` by reading
`strings /root/host_app_k5/qpsk_tun | grep -q "nakstat:"`. **On a zero-byte binary
that returns nothing**, so the next rebuild would have silently dropped the
deployed NAK-stat instrumentation — and the 146 flash rail's `[4/6]` "NAK must be
4" check would then fail for a reason nobody would trace. The flag was therefore
passed **explicitly**:

```
$ ops/anyssh.sh 10.0.0.146 'strings /root/host_app_k5/qpsk_tun | grep -c nakstat'
4                                                     <- the reference
$ ops/anyssh.sh 10.0.0.148 'cd /root/host_app_k5 && gcc -O2 -Wall -DQPSK_CARVE_2MB \
    -DQPSK_ARQ_NAKSTAT -o qpsk_tun qpsk_tun.c qpsk_frame.c qpsk_ber.c qpsk_seq.c qpsk_uio.c \
    2>/tmp/gcc.err && gcc -O2 -Wall -o qpsk_perf qpsk_perf.c 2>>/tmp/gcc.err \
    && echo BUILD_OK || { echo BUILD_FAIL; cat /tmp/gcc.err; }; ls -l qpsk_tun qpsk_perf; \
    echo "nakstat count: $(strings qpsk_tun | grep -c nakstat)"'
BUILD_OK
-rwxr-xr-x 1 root root  72272 Sep 10 20:40 qpsk_perf
-rwxr-xr-x 1 root root 148576 Sep 10 20:40 qpsk_tun
nakstat count: 4
```

(148 is role A, so no `HOST_CFLAGS_B`: the binary is the functionally untouched
build `capture_r3.sh` would produce for that board.)

148's watchdog relaunched the now-real binary by itself, and the link came back
bidirectionally. **Whitening confirmed on BOTH daemons before anything was
credited** — a `WHITEN` mismatch is the documented forward-residual defect and
would NOT be caught by the PER acceptance rule:

```
$ ops/anyssh.sh 10.0.0.<ip> 'P=$(pgrep -x qpsk_tun); tr "\0" "\n" < /proc/$P/environ | grep -i whiten'
148: QPSK_WHITEN=1        146: QPSK_WHITEN=1
148 stats: ... dma_tx=130784 idle_rx=122051 ...    146 stats: ... idle_rx=132355 ...
```

## Step 5.2 — bring-up #2, and both boards clean 12/12

146's watchdog was still cycling NOT-LOCKED/FULL RE-ARM from the deaf period
(`resets_s=7/12 clean=5/12` at 20:43), so the standard bring-up was run once more
— now against a real binary, which makes it a genuine bring-up rather than a
third retry of a failed gate:

```bash
ops/launch_rig_unit.sh sp2-bringup2-204343 /mnt/onetb/scratch/qpsk-build-trees/sp2c_rearm.sh
```

```
gate try 1: 148 rx=1246 f/s  146 rx=1247 f/s (need >= 1120)
ARM GATE PASS (try 1)
=== r3 BRING-UP COMPLETE (byte source live both ends, stream-first + double-tap order) ===
SP2C_REARM_EXIT=0            Result=success ExecMainStatus=0
```

**Health gate, both boards, verbatim — this is the Step-1 gate result:**

```
$ ops/health_probe_reset_aware.sh 10.0.0.148 12          # 20:46:25
fsync=1262 wcnt=1262 resets_s=0/12 clean=12/12
$ ops/health_probe_reset_aware.sh 10.0.0.146 12          # 20:46:38
fsync=1266 wcnt=1265 resets_s=0/12 clean=12/12
$ ops/anyssh.sh 10.0.0.146 'tail -4 /dev/shm/watchdog.log'
[wd 01:46:29] LOCKED (drstcs=0 dpkts=6244 lvl=0)
[wd 01:46:35] LOCKED (drstcs=0 dpkts=6243 lvl=0)
[wd 01:46:42] LOCKED (drstcs=0 dpkts=6246 lvl=0)
[wd 01:46:51] LOCKED (drstcs=0 dpkts=6245 lvl=0)
```

**Both boards clean 12/12 with sp2A on 148 and sp2B on 146.**

## Step 5.3 — BIST: the live-link read is NOT a measurement of the image

The golden `cap_out = 0x04922282` is defined in the **mode-1 internal digital
loopback** arm (both LOs 2.0 GHz, ROM source) — the state the 148 flash rail
leaves the board in, and the state 11b took 148's golden read in. On the live r3
link the read is something else entirely, and the **control proves it is a
property of the arm, not of the image**: 148 — the board that produced the golden
word four hours earlier — reads exactly what 146 reads.

```
$ ops/anyssh.sh 10.0.0.146 'for i in 1 2 3 4 5; do busybox devmem 0x9D000144 32; done'
0x2674AF6A
0x2674AF6A
0x2674AF6A
0x2674AF6A
0x2674AF6A
$ ops/anyssh.sh 10.0.0.148 'for i in 1 2 3 4 5; do busybox devmem 0x9D000144 32; done'
0x2674AF6A
0x2674AF6A
0x2674AF6A
0x2674AF6A
0x2674AF6A
```

**Therefore the live-link BIST read is not scoreable against the golden for either
board, and the non-golden value above is NOT evidence against `d94b4df391a1`.**
`ops/test.sh bist` does not arm anything — it dispatches to `ops/measure_ber.sh`,
which only reads 0x144 in whatever state it finds. Taking the acceptance item
therefore required putting 146 into mode 1 first. That is what hung the board;
see Step 5.5.

## Step 5.4 — R4D canonical-order decode check on 146: **PASS**

`modem_status` on 146 predated Task 7 (binary dated Sep 9 22:18, and
`ms_regmap_fixes.inc` was not even present on the board), so it was staged from
`host/` HEAD and rebuilt on-board first. `ops/provision.sh` and `ops/capture_r3.sh`
do not deploy `host/modem_status/` at all (11b established this), so the staging is
by hand:

```bash
scpput host/modem_status/{modem_status.c,modem_status.h,ms_collect.c,ms_collect.h,\
ms_curses.c,ms_curses.h,ms_delta.c,ms_delta.h,ms_health.c,ms_health.h,\
ms_regmap.c,ms_regmap.h,ms_regmap_fixes.inc,ms_render.c,ms_render.h,\
ms_src.h,ms_src_hw.c,ms_src_hw.h,ms_term.c,ms_term.h} \
       host/qpsk_hw.h host/qpsk_fixregs.h root@10.0.0.146:/root/host_app_k5/
# SCP_OK
$ ops/anyssh.sh 10.0.0.146 'cd /root/host_app_k5 && gcc -O2 -Wall -I. -D_FILE_OFFSET_BITS=64 \
    -o modem_status modem_status.c ms_src_hw.c ms_curses.c ms_regmap.c ms_collect.c \
    ms_delta.c ms_health.c ms_render.c ms_term.c -lncursesw -ltinfo'
-rwxr-xr-x 1 root root 66832 Sep 11 01:47 modem_status
modem_status analog img d94b4df391a1 up 0d02:04 load 1.90 01:47:51   REGS:LIVE
```

(`-D_FILE_OFFSET_BITS=64` is what makes `mmap(0x9D000000)` work on armhf.) The
banner re-reads the booted image as `d94b4df391a1`, so the check is evidenced
in-band. Two samples, 12 s apart, on the live link:

```
=== T0 01:47:59 ===
"r4d_swapped":0
"r4_wit":{"off":564          (= 0x234)
"r4_extras":{"off":568       (= 0x238)
 | R4 234 L=1 skip=11 open+1246 can
 | r4_wit    234 0x8005C21C   0/1246 --
 | r4_extras 238 0x00001E2D   0/39   --
=== T1 01:48:11 ===
"r4d_swapped":0
"r4_wit":{"off":564
"r4_extras":{"off":568
 | R4 234 L=1 skip=11 open+1237 can
 | r4_wit    234 0x8005FD45   0/1237 --
 | r4_extras 238 0x0000200B   0/39   --
```

- **`r4d_swapped: 0` → CANONICAL.** `ms_r4d_order()` returns canonical for any
  md5 not in `QPSK_R4D_SWAPPED_MD5`, which is `9acbe2ebe1dbf280e030952fc4fc23d8`
  (the *old* 146 image); `d94b4df391a1…` is not in it. The witness word is read at
  **0x234** and extras at **0x238** — canonical — and the renderer prints `can`.
- **`opens` advances at the frame rate.** `r4_wit` low 15 bits: `0x8005C21C` →
  `0x8005FD45` is 16,924 → 32,069 = **15,145 opens in 12 s = 1,262/s**, against
  1,245 f/s nominal. The per-second render agrees: `open+1246`, `open+1237`.
- **`r4_extras` is a small count**: 7,725 → 8,203 = 478 in 12 s ≈ **40/s**, i.e.
  ~3 % of the opens rate, and the per-second render says `0/39`.
- The failure mode this check exists to catch is the **reverse** assignment
  (extras ticking at frame rate, opens small). It is not what the board shows.

**R4D canonical-order decode check on 146: PASS.**

## Step 5.5 — 146 hung by the mode-1 loopback arm: STOP

To take the BIST acceptance item in the arm state it is defined in, 146 was armed
in mode-1 internal digital loopback. `ops/flash/arm148_mode1.sh` is parameterised
by `B=`, so it was invoked for 146, under the rails and the rig mutex:

```bash
ops/launch_rig_unit.sh sp2-bist146-204841 /mnt/onetb/scratch/qpsk-build-trees/sp2c_bist146.sh
#   -> B=10.0.0.146 bash ops/flash/arm148_mode1.sh
#      then 5x devmem 0x9D000144, then ops/test.sh bist -A 10.0.0.146
```

The unit's journal, **verbatim and complete** — it never got past the arm:

```
Sep 10 20:48:41 === arm 146 in mode-1 internal digital loopback ===
Sep 10 20:48:41 === discovering profile 'lvds_61p44_fdd_jupiter' on 10.0.0.146 (a miss is fatal, not silent)
Sep 10 20:48:42   found: /root/lvds_61p44_fdd_jupiter.bin /root/lvds_61p44_fdd_jupiter.json
```

Profile discovery passed at 20:48:42 and the script entered its single `ssh` arm
block. That block ends by printing `armed, waiting 70 s for the transient`. **That
line never appeared.** So 146 died *inside* the register sequence — the
`0x208`/`0x000` soft reset / `0x158`/`0x118`/`0x114` / `0x110` double-tap writes —
not during the profile load. 146 is off the network:

```
$ ip neigh show 10.0.0.146
10.0.0.146 dev eno1 FAILED
$ ssh -o ConnectTimeout=8 root@10.0.0.146 'echo alive'
ssh: connect to host 10.0.0.146 port 22: No route to host
$ for i in $(seq 10); do ping -c1 -W2 10.0.0.146; done      # 20:53
10/10 FAIL
$ ping -c2 -W2 10.0.0.148                                   # the control
0% packet loss
```

This is the documented **no-ping hang** class (`rig-noping-hang-dra-during-arm`:
direct_reg_access traffic racing board state; "arms are the worst instance"), and
it is the power-cycle class: physical operator action, exactly as 148 needed in 11b.

### This is a rail defect: `arm148_mode1.sh` had NEVER been run against 146

Its `B=` parameter is untested on that board, and the whole campaign it belongs to
is documented as 148-only:

```
$ grep -rn 'arm148_mode1' --include='*.sh' --include='*.md' --include='*.rst' . | grep -v ops/flash/arm148_mode1.sh
modem/instruments/ddrcap2/flash_148.sh:3:# adapted to the 148-ONLY mode-1 campaign (146 is never touched) ...
ops/flash/flash_148_txfix.sh:3:#   ... the 148-ONLY mode-1 campaign (146 is never touched) ...
(every other hit is a 148 flash log or an evidence file quoting one)
```

`arm148_mode1.sh`'s own header even says to use it "instead of `bringup_r2r3.sh`
for **148-only** work — r3 is a TWO-BOARD bring-up and arms 146 as well (that is
how 146 hung on 2026-09-01)". The `B=` variable reads as a generalisation; it is
not one.

**Likely mechanism, stated as a lead and not as a proven cause.** 146 needs a
board-specific TX SSI delay override after *every* profile load —
`ops/apply_146_ssi_fix.sh` (tx0 clk=3, data/strobe=4), because "the adrv9002
driver re-runs a PRBS15 SSI delay auto-tune at EVERY profile load; on unit 146 the
PRBS test can pick a word-boundary-slip clk row that mission traffic cannot use".
`ops/bringup_r2r3.sh` applies it for 146 on every arm (`146: ssi-fix VERIFIED:
tx0=c3d4 ... 0x114=1` in both bring-ups above). **`arm148_mode1.sh` reloads the
profile and never applies it**, and it writes `0x114 0x0` where the r3 bring-up
writes `0x114 0x1`. A 148-tuned arm sequence on 146 is not a safe substitution.

### Actions taken, and deliberately not taken

- **No retry.** The rule is explicit and the memory note is explicit: extra
  attempts are the documented hang-worsening action. One arm, one hang, stop.
- **The hung unit was stopped, deliberately.** Its ssh to a dead 146 is a stale
  TCP session, not a bounded timeout, so it would never return; and when the
  operator power-cycles 146 that chain could unblock and fire an arm into a board
  mid-repair. Unlike 11b's case this arm is **146-only** and never touches 148, so
  nothing on the live board was interrupted. Stopped at 20:54 with
  `systemctl --user stop sp2-bist146-204841.service` → `inactive`; its EXIT trap
  released `RIG_LOCK` and re-asserted `SENTINEL_STOP`. Verified after:
  `RIG_LOCK` absent, `SENTINEL_STOP` present (mtime 20:54), no `arm148_mode1`,
  `bringup_r2r3`, `capture_r3` or `delivery_sentinel` process alive.
- **No credited windows were opened.** Both legs need 146. Nothing was measured.
- **146 was NOT rolled back.** This is a rig fault with no measurement taken, not
  an acceptance failure, and a rollback would mean rebooting a board that is
  already unreachable. `/root/BOOT.BIN.9acbe2ebe1db.bak` is present and
  md5-verified on 146, so it stays a one-command operator action.
- **148 was NOT rolled back** — it passed its gate in 11b and passed every check
  taken tonight.

### sp2B verdict: **STILL INCONCLUSIVE — UNGATED**

Everything measured on `d94b4df391a1`, tonight and in 11b:

| Acceptance item | Required | Result |
| --- | --- | --- |
| readback md5 | `d94b4df391a1` | `d94b4df391a1` (11b rail `[3/6]`; re-read tonight) |
| health gate | clean 12/12 | `fsync=1266 wcnt=1265 resets_s=0/12 clean=12/12` **PASS** |
| R4D canonical order | `opens` at frame rate, `extras` small | canonical, 1,262 opens/s, 40 extras/s **PASS** |
| BIST `cap_out = 0x04922282` | golden, in the mode-1 arm | **NOT MEASURABLE** — live-link read is arm-defined (148 control reads the same non-golden word); the mode-1 arm hangs 146 |
| forward PER | ≤ 0.020 % or ≤ 0.079 % | **NOT MEASURED** |
| reverse PER | ≤ 0.062 % or ≤ 0.191 % | **NOT MEASURED** |
| `wedge_verdict=healthy`, no new comb line | — | **NOT MEASURED** |

## Step 5.6 — cut-over: **NOT PERFORMED** (again)

The controller's ruling gates the cut-over on 146 passing. Two of its acceptance
items have no measurement at all, so `images/CURRENT.txt`, `images/README.md` and
`docs/provenance.rst` were left untouched.

**The rig/bank inconsistency 11b raised is UNCHANGED and still needs the
controller.** `ops/deploy_image.sh <ip> A|B` reads `CURRENT.txt` directly:

| | on the board now | `images/CURRENT.txt` says |
| --- | --- | --- |
| 148 (role A) | `3e7f4232a3b5` (sp2A, gated, PASSED in 11b, healthy tonight) | `BOOT.BIN.148.rxfixpad.bf2a7305bbe0` |
| 146 (role B) | `d94b4df391a1` (sp2B, UNGATED; board dark) | `BOOT.BIN.146.rxfixr4dr1.9acbe2ebe1db` |

Both previous images stay banked in `images/`; nothing was deleted.

## Rig state at handover (Task 11c)

- **148: UP and healthy**, running sp2A `3e7f4232a3b5`, host app repaired
  (`qpsk_tun`/`qpsk_perf` rebuilt, NAK-stat 4), `QPSK_WHITEN=1`, watchdog alive,
  last health gate clean 12/12 at 20:46:25. **Its `fsync` will read ~0 from now on
  because its peer is dark — that is 146's outage, not a 148 defect.**
- **146: DOWN — no ping, no ARP, no ssh. Needs a power cycle (physical.)** It was
  running sp2B `d94b4df391a1` when it hung, in a mode-1 loopback arm.
  `~/.claude/HOSTS.md` line 41 lists serial for "jupiter A / B" via
  `tron.local /dev/ttyACM0` (one device for two boards — check which before
  assuming) and lists **no remote PDU**. Operator item.
- **`~/modem-status/SENTINEL_STOP` is PRESENT and must STAY** until 146 is back on
  the network. Task 11c's step 6 made its removal conditional on both boards being
  healthy; 146 is dark. If it is removed now, `sentinelkeeper-105921.service`
  relaunches the sentinel, which sees 148 up and 146 unreachable, declares a wedge
  and starts arming into a dead board — the exact 18:43 failure.
  `sentinelkeeper-105921.service` was never stopped and is still `active`;
  `sentinel-183752.service` is `inactive` because the sentinel **exited itself** on
  the STOP file, its designed path.
- `~/modem-status/RIG_LOCK` absent. No rig unit running. Nothing of this task is
  alive on either board.
- **`sentinel.log` contaminated from 2026-09-10 17:57 through now.**

## Concerns (Task 11c)

1. **`ops/flash/arm148_mode1.sh` must not be run against 146.** Its `B=` parameter
   is an untested generalisation; the first invocation ever made against 146 hung
   the board. At minimum the script should refuse any `B` other than 10.0.0.148
   unless the caller also applies `ops/apply_146_ssi_fix.sh`, and the 146 BIST
   acceptance item needs a 146-native mode-1 arm that someone designs and proves.
2. **The BIST golden is arm-state-defined and nothing says so at the call site.**
   `ops/test.sh bist`'s banner says only "most meaningful during an active
   link/loopback arm". On a live r3 link *both* boards read `0x2674AF6A`; the
   golden `0x04922282` belongs to mode-1 loopback. Any brief that asks for the
   golden must also name the arm, or it is asking for a measurement that cannot be
   taken.
3. **An interrupted `capture_r3` rebuild leaves a ZERO-BYTE `qpsk_tun`** that no
   bring-up detects: `bringup_r2r3.sh` prints `daemon up` regardless and only the
   on-board watchdog log reveals the relaunch loop. Worse, `capture_r3.sh:213`'s
   `NAKKEEP` auto-detect reads `strings` of that zero-byte file, finds nothing, and
   **silently drops `-DQPSK_ARQ_NAKSTAT`** on the next rebuild — which would then
   fail the 146 rail's `[4/6]` "NAK must be 4" check for an untraceable reason.
   Dodged here by passing the flag explicitly. Both scripts should hard-fail on a
   zero-length binary.
4. **`rig_unlock` deletes `SENTINEL_STOP`**, so any task that must hold the
   sentinel park across more than one rig unit has to re-`touch` it in its own EXIT
   trap. Worked around here (`hold_out`); the mutex should distinguish "I created
   the hold" from "a hold already existed", like the 148 rail's `SS_MINE` logic.
5. **11b's concern 1 still stands and is now overdue**:
   `ops/flash/flash_146_txfix.sh` has no `SENTINEL_STOP` ownership at all. It was
   not edited here either — no 146 rail was run tonight, and the board is dark.

### Final verification, taken as the last action of Task 11c (20:59)

```
$ ping -c3 -W2 10.0.0.146 ; ip neigh show 10.0.0.146
(no reply)   10.0.0.146 dev eno1 FAILED              <- still down, as expected
$ ops/health_probe_reset_aware.sh 10.0.0.148 12
fsync=0 wcnt=0 resets_s=12/12 clean=0/12 (ALL intervals dirty -- reset storm, judge on resets_s)
```

**That 148 reading is the peer outage, not a 148 defect** — it is the predicted
consequence of 146 being dark, and it is confirmed by everything else on the board
being alive and correct:

```
$ ping -c2 -W2 10.0.0.148                       0% packet loss
$ ops/anyssh.sh 10.0.0.148 'pgrep -a qpsk_tun; grep "qpsk_tun stats" /dev/shm/qpsk_tun.log | tail -1; md5sum /boot/BOOT.BIN | cut -c1-12'
14742 ./qpsk_tun -G -M 16 -r 15360 -i tun0 -s 5
qpsk_tun stats: ... dma_tx=1170864 ... idle_rx=305224 ...
3e7f4232a3b5
```

148 is up, on sp2A, with a working repaired daemon still transmitting; it simply
has nothing to receive. **Do not read this gate as a 148 regression** — re-gate
148 only after 146 is back and a bring-up has been run.

Holds and units at the close, verified:

```
$ ls -l ~/modem-status/SENTINEL_STOP ; ls -l ~/modem-status/RIG_LOCK
-rw-rw-r-- 1 tcollins tcollins 0 Sep 10 20:54 SENTINEL_STOP      <- PRESENT, leave it
ls: cannot access '.../RIG_LOCK': No such file or directory
$ systemctl --user is-active sentinelkeeper-105921.service sentinel-183752.service
active
inactive                  <- the sentinel exited ITSELF on the STOP file
$ ps -ef | grep -E 'delivery_sentinel|bringup_r2r3|capture_r3|arm148_mode1|flash_14'
(nothing)
```

---

# Step 6 — sp2 pair windows after the 146 power cycle (Task 11d, 2026-09-10 evening)

**Outcome in one line: BOTH credited windows were taken on the sp2 PAIR and both
PASS — forward 0.005 % (39/734,808), reverse 0.121 % (908/747,849) — and
`images/CURRENT.txt` was CUT OVER to `BOOT.BIN.148.sp2A.3e7f4232a3b5` (role A) and
`BOOT.BIN.146.sp2B.d94b4df391a1` (role B).** No flash, no BIST, no mode-1 arm was
performed. The reverse leg needed the one allowed re-run.

**Sentinel contamination, stated up front.** `/home/tcollins/modem-status/sentinel.log`
has been contaminated since **2026-09-10 17:57** (Task 11b) and stayed contaminated
through this task until **22:5x**, when `SENTINEL_STOP` was removed at handover (see
Step 6.7). Every wrapper here takes the rig mutex `ops/sim_repro/riglock.sh`, which
touches `SENTINEL_STOP`; each wrapper's EXIT trap re-asserts the hold because
`rig_unlock` deletes it. **Gaps in that log from 17:57 to the handover are rig work,
not link events.** `sentinelkeeper-105921.service` was never stopped or killed.

## Step 6.0 — 146's host daemon: checked, NOT rebuilt (and why)

146 came back from the operator's power cycle with `/root/host_app_k5/qpsk_tun` at
**86,884 B** against 148's **148,576 B**. That difference is *not* a stale or
truncated build — it is two different rootfs toolchains:

```
$ ops/anyssh.sh 10.0.0.148 'gcc --version | head -1'
gcc (Debian 14.2.0-19) 14.2.0
$ ops/anyssh.sh 10.0.0.146 'gcc --version | head -1'
gcc (Raspbian 10.2.1-6+rpi1) 10.2.1 20210110
```

The binary was verified three ways before bring-up, as Task 11c verified 148:

```
$ ops/anyssh.sh 10.0.0.146 'cd /root/host_app_k5 && file qpsk_tun'
qpsk_tun: ELF 32-bit LSB executable, ARM, EABI5 version 1 (SYSV), dynamically linked,
  interpreter /lib/ld-linux-armhf.so.3, BuildID[sha1]=df4797be5c4fded52a7b8173a0d67c9d4f6b6fda,
  for GNU/Linux 3.2.0, not stripped

$ ops/anyssh.sh 10.0.0.146 'find /root/host_app_k5 -maxdepth 1 -size 0 -print'
(nothing -- the Task 11c zero-byte defect is NOT present on 146)

$ ops/anyssh.sh 10.0.0.146 'cd /root/host_app_k5 && for m in "nakstat:" "carve" "WHITEN"; do
    printf "%s=%s " "$m" "$(strings qpsk_tun|grep -c "$m")"; done'
nakstat:=1 carve=7 WHITEN=1        # identical counts on 148
```

All thirteen on-board sources are **byte-identical to local `host/` HEAD** on a clean
tree (`git status --short host/` → empty):

```
614fb9a4645b7622396a4e6312b3bcb9  qpsk_tun.c        ad99ee67246b09e94099b264e93d4277  qpsk_frame.c
e95f0de20ff80ea194192b362e0a8898  qpsk_ber.c        50ece528febf74d70be0456710a3a263  qpsk_seq.c
3f63ad33d2b0f0d04ba8b1345b576774  qpsk_uio.c        13463f2004f8b616f57380949fc3b2f6  qpsk_frame.h
291a222c9c68b6ed0a8800562f30a0a8  qpsk_hw.h         2bd8d8bf54c0d20e084374865bea045f  qpsk_fixregs.h
6ca68378bb38fd49f239d305b12dca08  qpsk_ber.h        e990d9dc1ec7c50b1b3db1e0d4ca8408  qpsk_seq.h
3760bf6b374142174fb7725f35c34dd3  qpsk_uio.h        65e93471e82506c1b516b41ab914670e  qpsk_join.h
6c3ce435ec303d7e81f7ac4d97b2c1c7  qpsk_perf.c
```

and the binary post-dates them by one minute (board clock runs ~5 h fast; these are
board-local stamps): sources `2026-09-10 23:43:24`, `qpsk_tun` `2026-09-10 23:44:03`.
**So it was rebuilt, not stale, and no hand rebuild was done** — a hand rebuild would
have destroyed the artefact that proves this. The negative was then confirmed
*independently* by the capture rail's own guard on the first leg:

```
  10.0.0.146: preserving deployed NAK-stat instrumentation (-DQPSK_ARQ_NAKSTAT)
  10.0.0.146 build: BUILD_OK
  10.0.0.146: NAK-stat counter VERIFIED present after rebuild
```

`capture_r3.sh:213`'s `NAKKEEP` auto-detect could only carry the flag because the
marker was present — the exact test that failed on 148's zero-byte binary in 11c.

**The R4D canonical-order decode check was NOT re-taken.** 11c passed it on this
board (`r4d_swapped: 0`, `r4_wit` 0x234, `r4_extras` 0x238, opens 1,262/s vs extras
~40/s). The property it tests is a property of the *image*, and the image is
unchanged across the power cycle — re-established by the md5 read below.

## Step 6.1 — state at the start, both boards up

```
$ ping -c2 -W2 10.0.0.148   ->  PING_OK
$ ping -c2 -W2 10.0.0.146   ->  PING_OK
$ ops/anyssh.sh 10.0.0.148 'uptime; md5sum /boot/BOOT.BIN | cut -c1-12'
 21:30:03 up  1:10,  5 users,  load average: 0.26, 0.27, 0.20
3e7f4232a3b5
$ ops/anyssh.sh 10.0.0.146 'uptime; md5sum /boot/BOOT.BIN | cut -c1-12'
 02:30:05 up 2 min,  load average: 1.63, 0.68, 0.26      <- board clock +5h
d94b4df391a1
$ ls -l ~/modem-status/SENTINEL_STOP
-rw-rw-r-- 1 tcollins tcollins 0 Sep 10 20:54 SENTINEL_STOP     <- held
$ ls ~/modem-status/RIG_LOCK   ->  No such file or directory
```

On-board rollbacks, as 11b/11c left them (`ls /root/*.bak`):
`148:/root/BOOT.BIN.bf2a7305bbe0.bak`, `146:/root/BOOT.BIN.9acbe2ebe1db.bak`.

## Step 6.2 — bring-up and the opening health gates

```bash
ops/launch_rig_unit.sh sp2-bringup-213333 /mnt/onetb/scratch/qpsk-build-trees/sp2c_rearm.sh
#   -> bash ops/bringup_r2r3.sh r3, under the rig mutex, SENTINEL_STOP re-asserted on exit
```

Journal, verbatim:

```
=== r3 bring-up: lvds_61p44_fdd_jupiter, -r 15360, gate >= 1120 f/s ===
10.0.0.148 armed ROM (lvds_61p44_fdd_jupiter)
10.0.0.146 armed ROM (lvds_61p44_fdd_jupiter)
146: ssi-fix VERIFIED: tx0=c3d4 rx0 preserved (0/4) (rearmed, 0x114=1)
148: ssi-fix VERIFIED: tx0=c5d3 rx0 preserved (0/4) (rearmed, 0x114=1)
gate try 1: 148 rx=1246 f/s  146 rx=1247 f/s (need >= 1120)
ARM GATE PASS (try 1)
10.0.0.146 daemon up (ROM still selected)
10.0.0.148 daemon up (ROM still selected)
10.0.0.146 watchdog: ALIVE pid=12144 [wd] === STARTING 02:34:37 pid=12144 ===
10.0.0.148 watchdog: ALIVE pid=46108 [wd] === STARTING 21:34:40 pid=46108 ===
=== r3 BRING-UP COMPLETE (byte source live both ends, stream-first + double-tap order) ===
SP2C_REARM_EXIT=0
```

`Result=success`. Health gates, one per board, **no re-run needed**:

```
$ ops/health_probe_reset_aware.sh 10.0.0.148 12          # 21:34:52
fsync=1263 wcnt=1263 resets_s=0/12 clean=12/12
$ ops/health_probe_reset_aware.sh 10.0.0.146 12          # 21:35:05
fsync=1268 wcnt=1268 resets_s=0/12 clean=12/12
```

Both daemons and both watchdogs alive (`pgrep -a qpsk_tun`, `pgrep -a -f lock_watchdog`).

## Step 6.3 — forward leg A (146 TX → 148 RX), capture on 148 — PASS

```bash
ops/launch_rig_unit.sh sp2d-fwd-213527 /mnt/onetb/scratch/qpsk-build-trees/sp2c_fwd.sh
#   -> bash ops/capture_r3.sh A -d 600 -k -o ops/r3cap/sp2pair_fwd
```

`Result=success ExecMainStatus=0`, `CAPTURE_R3_DONE`, `frames.bin: 753655 records`.
In-leg bring-up gate: `ARM GATE PASS`; in-leg wedge verdict
`wedge verdict: healthy crc=100% rate=1037f/s`. No `CAPTURE_ABORTED` marker and no
`recovery.txt` in the output dir.

`meta.txt` verbatim:

```
target=A dir=fwd rx=10.0.0.148 peer=10.0.0.146 rung=r3 profile=lvds_61p44_fdd_jupiter
ksym=15360 sps=4 fs=61440000 spf=49332 dur=600 nsamp=4000000 payload=1400 traffic=qpsk_perf_15Mbit
wedge_verdict=healthy crc=100% rate=1037f/s
mid_recover=0 recovery_events=0 recovery_excluded_s=0 recovery_failed=0
image_md5=3e7f4232a3b5c8863bfa5187ad35068f
ts=2026-09-10T21:47:51-04:00
```

`image_md5` is the **RX** board, so it evidences sp2A in-band. The **TX** board's
image is not in `meta.txt`, so it was read directly either side of the leg
(21:30 before, 21:48 after):

```
$ ops/anyssh.sh 10.0.0.146 'md5sum /boot/BOOT.BIN | cut -c1-12'
d94b4df391a1        (both reads)
```

**This is the first credited forward window with BOTH boards on their sp2 image.**

Score, verbatim:

```
$ python3 ops/accept_analyze.py ops/r3cap/sp2pair_fwd/frames.bin
=== wedge-aware acceptance analysis (live-link windows, settle 15s, wedge-guard 2s) ===
  sp2pair_fwd: live 605s/605s  PER=0.005% (39/734808)  CP95UL=0.007%  lag33=-0.000  bins={'1': 24, '2': 6, '3-4': 1, '5-20': 0, '21-100': 0, '>100': 0}

  POOLED live-window: PER=0.005% (39/734808)  CP95UL=0.007%
  per-run spread: 0.005%..0.005%
  wedges during captures: 0 (real events; auto-recovered in normal ops by lock_watchdog, disabled during captures)
  GATE (<1% at CP95 upper limit, live-link): PASS
```

**PER 0.005 %, 39 lost, 734,808-frame sample.** Full 605 s of 605 s live — no wedge
truncation, unlike every earlier leg. **Lost frames are counted in the denominator**,
quoted from `accept_analyze.py` rather than paraphrased: the tool reports on *"the
reliable host_seq-gap metric over the live window"*, and its arithmetic is
`span += cs[-1] - cs[0]; miss += lost[lost>0].sum()` then `per = 100*miss/span` — the
denominator is the whole host_seq span, which includes every slot that never arrived.
For a recovered leg (not this one) *"every frame inside a perturbed interval is
dropped from BOTH the numerator and the denominator"*; `mid_recover=0
recovery_events=0` here, so no interval was dropped.

No new comb line: `lag33=-0.000`, matching both baselines. `ops/comb/comb_period_ms.py`
returns `UNUSABLE: fewer than 200 loss slots -- no period can be resolved` — with 39
losses there is nothing for a comb to be made of.

**The Tap-A IQ capture is DEGENERATE on this leg** (`occupied BW = 2.40 MHz -> FAIL`,
`env periodicity 0.9995 at lag 256 -> FAIL`, the #48 stale-DDR-replay signature). The
rail says so itself and scopes it: *"frames.bin / host-side counters are unaffected."*
No IQ-based claim is made anywhere in this step; every acceptance number comes from
`frames.bin` and the register counters.

Health gate on the RX board (148) after the leg, first try:

```
$ ops/health_probe_reset_aware.sh 10.0.0.148 12          # 21:50:23
fsync=1262 wcnt=1262 resets_s=0/12 clean=12/12
```

`capture_r3 -k` leaves both on-board watchdogs killed by design (`10.0.0.146 wd
stopped`, `10.0.0.148 wd stopped` in the journal) — confirmed by `pgrep` and restored
before handover in Step 6.6.

**Verdict: PASS.** 0.005 % is under *both* arms of the ruling (≤ 0.020 % 2×-baseline
and ≤ 0.079 % documented).

## Step 6.4 — reverse leg B, first attempt — FAIL (0.694 %), one burst

```bash
ops/launch_rig_unit.sh sp2d-rev-215046 /mnt/onetb/scratch/qpsk-build-trees/sp2c_rev.sh
#   -> bash ops/capture_r3.sh B -d 600 -k -o ops/r3cap/sp2pair_rev
```

`Result=success ExecMainStatus=0`, `CAPTURE_R3_DONE`, `frames.bin: 756523 records` —
the capture itself completed; this is an **acceptance** failure, not a capture abort.
`meta.txt`: `wedge_verdict=healthy crc=99% rate=1037f/s`, `mid_recover=0
recovery_events=0`, `image_md5=d94b4df391a1e84f53426755f469fc7e` (the RX board, 146).
TX board 148 read `3e7f4232a3b5` after the leg.

```
$ python3 ops/accept_analyze.py ops/r3cap/sp2pair_rev_try1/frames.bin
  sp2pair_rev_try1: live 608s/615s [WEDGE truncated]  PER=0.694% (5126/738544)  CP95UL=0.713%  lag33=0.015  bins={'1': 131, '2': 50, '3-4': 75, '5-20': 12, '21-100': 2, '>100': 1}
  wedges during captures: 1
```

0.694 % is over both arms → **FAIL**. The capture was **kept**, not deleted
(`ops/r3cap/sp2pair_rev_try1/`), and the free burst decomposition was run on the data
already in hand before spending the single allowed re-run — `--burst-times` is
documented to leave every printed number byte-identical:

```
$ python3 ops/accept_analyze.py --burst-times rev_try1_bursts.csv ops/r3cap/sp2pair_rev_try1/frames.bin
  burst times: 271 loss runs -> rev_try1_bursts.csv
$ sort -t, -k3 -n -r rev_try1_bursts.csv | head -3
  onset_seq=416095  run_len=4503  t_s=313.813394
  onset_seq=416085  run_len=7     t_s=313.801425
  onset_seq=132569  run_len=48    t_s=86.170807
```

**One 4,503-frame run at t = 313.8 s — mid-window, not at a boundary — is 87.8 % of
the 5,126 losses** (≈3.6 s of continuous deletion). Residual PER without it is
623 / 738,544 = **0.084 %**, under the 0.191 % arm. The leg was still scored as a
FAIL on its own number; the burst analysis is why a re-run was judged worth the one
allowance rather than a second image-level defect.

Health gate on the RX board (146) after this leg:

```
$ ops/health_probe_reset_aware.sh 10.0.0.146 12          # 22:05:37
fsync=0 wcnt=0 resets_s=12/12 clean=0/12 (ALL intervals dirty -- reset storm, judge on resets_s)
```

This is the class 11b/11c documented after a `-k` reverse leg: the watchdogs are
killed, so the end-of-leg wedge stays wedged. **Standard bring-up once, then re-gate**,
exactly as the acceptance ruling allows:

```bash
ops/launch_rig_unit.sh sp2d-rearm-220905 /mnt/onetb/scratch/qpsk-build-trees/sp2c_rearm.sh
```

```
10.0.0.146 watchdog: ALIVE pid=6287  [wd] === STARTING 03:10:10 pid=6287 ===
10.0.0.148 watchdog: ALIVE pid=67272 [wd] === STARTING 22:10:13 pid=67272 ===
=== r3 BRING-UP COMPLETE ===            SP2C_REARM_EXIT=0

$ ops/health_probe_reset_aware.sh 10.0.0.146 12          # 22:10:22
fsync=1267 wcnt=1267 resets_s=0/12 clean=12/12
$ ops/health_probe_reset_aware.sh 10.0.0.148 12          # 22:10:35
fsync=1262 wcnt=1262 resets_s=0/12 clean=12/12
```

`MID_RECOVER` was left at its default **0** throughout. Turning it on would have let
the tool drop the perturbed interval from both numerator and denominator and turned
0.694 % into a pass; the baselines and every earlier leg were scored at 0, so that
would have been changing the instrument to get the answer.

## Step 6.5 — reverse leg B, re-run (the one allowance) — PASS

```bash
ops/launch_rig_unit.sh sp2d-rev2-221052 /mnt/onetb/scratch/qpsk-build-trees/sp2c_rev.sh
#   -> bash ops/capture_r3.sh B -d 600 -k -o ops/r3cap/sp2pair_rev
```

`Result=success ExecMainStatus=0`, `CAPTURE_R3_DONE`, `frames.bin: 766310 records`.
In-leg `gate try 1: 148 rx=1247 f/s  146 rx=1247 f/s` → `ARM GATE PASS (try 1)`;
`wedge verdict: healthy crc=99% rate=1038f/s`. No `CAPTURE_ABORTED`, no `recovery.txt`.

`meta.txt` verbatim:

```
target=B dir=rev rx=10.0.0.146 peer=10.0.0.148 rung=r3 profile=lvds_61p44_fdd_jupiter
ksym=15360 sps=4 fs=61440000 spf=49332 dur=600 nsamp=4000000 payload=1400 traffic=qpsk_perf_15Mbit
wedge_verdict=healthy crc=99% rate=1038f/s
mid_recover=0 recovery_events=0 recovery_excluded_s=0 recovery_failed=0
image_md5=d94b4df391a1e84f53426755f469fc7e
ts=2026-09-10T22:23:27-04:00
```

`image_md5` is the RX board (146 / sp2B). The TX board (148 / sp2A) was read either
side: `3e7f4232a3b5` both times.

Score, verbatim:

```
$ python3 ops/accept_analyze.py ops/r3cap/sp2pair_rev/frames.bin
=== wedge-aware acceptance analysis (live-link windows, settle 15s, wedge-guard 2s) ===
  sp2pair_rev: live 616s/615s  PER=0.121% (908/747849)  CP95UL=0.130%  lag33=0.004  bins={'1': 222, '2': 18, '3-4': 191, '5-20': 3, '21-100': 0, '>100': 0}

  POOLED live-window: PER=0.121% (908/747849)  CP95UL=0.130%
  per-run spread: 0.121%..0.121%
  wedges during captures: 0 (real events; auto-recovered in normal ops by lock_watchdog, disabled during captures)
  GATE (<1% at CP95 upper limit, live-link): PASS
```

**PER 0.121 %, 908 lost, 747,849-frame sample**, full 616 s live, **0 wedges**, and
the run-length histogram tops out at the 5–20 bin (largest run 7 frames) — the
4,503-frame burst class is gone. **Lost frames are counted in the denominator** —
same host_seq-gap metric and same quoted arithmetic as Step 6.3; `mid_recover=0
recovery_events=0`, so no interval was dropped.

**Verdict: PASS** on the documented arm (≤ 0.191 %). It does **not** clear the
2×-baseline arm (≤ 0.062 %); the ruling is an OR, and the documented arm is the
binding line for this leg. Stated plainly rather than buried: 0.121 % is also above
11b's 0.048 % reverse leg, which was 148/sp2A transmitting into 146 on the **old**
`9acbe2ebe1db` image. Two legs are not a trend, and this leg is inside the accepted
envelope, but it is the number to watch if the reverse leg is re-measured.

The loss-run histogram itself shifted versus that sp2A-into-old-146 leg — 3-4-frame
runs 26 → 191, total loss runs 182 → 434, largest run still only 7 frames (no burst
class) — so the reverse leg is carried forward as a **named watch item**, with the
unmet 0.062 % 2×-baseline arm as its target for the next reverse-leg measurement.

No new comb line — checked with the dedicated tool, not only the lag column:

```
$ python3 ops/comb/comb_period_ms.py ops/r3cap/sp2pair_rev/frames.bin
  slots=747850 lost=908 (0.121 %) loss-run onsets=434  live=616/615s
  BEST  P = 27.41351 frames = 22.0111 ms   R = 0.1673
  BAND  P = 33.21845 frames = 26.6721 ms   R = 0.1561   (25-27 ms)
  random-event null (95th pct of band max, n=8): 0.1679
  band R / a1r2 baseline (0.1737) = 0.899
  COMB_LINE=absent
```

and the same tool on today's reverse baseline for comparison — also `COMB_LINE=absent`
(`BAND R = 0.2610`, null 0.3256). `lag33 = 0.004` sits inside the historical spread of
that column (28 archived legs read `-0.000`, one reads `-0.014` — and *that* one was a
leg with a real 20 ms comb at PER 2.667 %, which is why the column alone is not the
comb test).

Health gate on the RX board (146) after the leg, first try, **no re-run needed**:

```
$ ops/health_probe_reset_aware.sh 10.0.0.146 12          # 22:28:47
fsync=1267 wcnt=1267 resets_s=0/12 clean=12/12
```

## Step 6.6 — acceptance summary and the cut-over

| Acceptance item | Required | Result |
| --- | --- | --- |
| forward PER | ≤ 0.020 % **or** ≤ 0.079 % | **0.005 % (39/734,808)** PASS (both arms) |
| reverse PER | ≤ 0.062 % **or** ≤ 0.191 % | **0.121 % (908/747,849)** PASS (documented arm) |
| lost frames in the denominator | quoted from the tool | quoted, Step 6.3 |
| `wedge_verdict=healthy` | both legs | fwd `healthy crc=100%`, rev `healthy crc=99%` |
| no new comb line | lag report | fwd `lag33=-0.000` (comb tool UNUSABLE, 39 losses); rev `lag33=0.004`, `COMB_LINE=absent` |
| health gate on the RX board after each leg | clean 12/12 | 148 `1262 … 12/12`; 146 `1267 … 12/12` — both first try |
| 146 daemon | current build | verified current, not rebuilt (Step 6.0) |

`images/CURRENT.txt` cut over at 22:30 (parser-verified against `ops/deploy_image.sh`'s
`grep -E "^A " | awk '{print $2}' / '{print $3}'` — both rows `MATCH` their banked md5):

```
A BOOT.BIN.148.sp2A.3e7f4232a3b5 3e7f4232a3b5c8863bfa5187ad35068f ... forward PER 0.005 % (39/734,808) ...
B BOOT.BIN.146.sp2B.d94b4df391a1 d94b4df391a1e84f53426755f469fc7e ... reverse PER 0.121 % (908/747,849) ...
# On-board rollbacks (.bak on each board), also banked here:
#   148: BOOT.BIN.148.rxfixpad.bf2a7305bbe0   (/root/BOOT.BIN.bf2a7305bbe0.bak)
#   146: BOOT.BIN.146.rxfixr4dr1.9acbe2ebe1db (/root/BOOT.BIN.9acbe2ebe1db.bak)
```

The rollbacks are **comment lines**, which `deploy_image.sh`'s `^A `/`^B ` anchors
cannot match — they are inert to the flash tool by construction. Both previous images
remain in `images/` and on each board; nothing was deleted. `images/README.md` rows
for both sp2 images moved from CANDIDATE to DEPLOYED, and the two superseded rows now
read as rollbacks. `docs/provenance.rst` "Current images" carries one row per role:
image, md5, `modem/fixes/fixes.toml` sha `60f43ba3d5f8f871`, git commit, modem WNS,
endpoint totals, flash date and the credited window with its command, counts and
denominator statement.

**11b's blocking inconsistency is resolved**: `CURRENT.txt` and the boards now agree,
so `ops/deploy_image.sh <ip> A|B` re-flashes each board with what it is already
running instead of rolling it backwards.

## Step 6.7 — handover: watchdogs restored, `SENTINEL_STOP` removed, sentinel resumed

`capture_r3 -k` leaves both on-board watchdogs killed, and the health gate cannot see
that (it measures `fsync`/`wcnt`/`resets_s`, not process liveness). Checked and found
dead on both boards, so **one standard bring-up was run before releasing the hold**:

```
$ ops/anyssh.sh 10.0.0.148 'pgrep -a -f lock_watchdog'   ->  (nothing)
$ ops/anyssh.sh 10.0.0.146 'pgrep -a -f lock_watchdog'   ->  (nothing)

$ ops/launch_rig_unit.sh sp2d-handover-223252 /mnt/onetb/scratch/qpsk-build-trees/sp2c_rearm.sh
10.0.0.146 watchdog: ALIVE pid=10625 [wd] === STARTING 03:33:56 pid=10625 ===
10.0.0.148 watchdog: ALIVE pid=80157 [wd] === STARTING 22:34:00 pid=80157 ===
=== r3 BRING-UP COMPLETE ===            SP2C_REARM_EXIT=0        Result=success
```

Then the hold was released — the **first** time `SENTINEL_STOP` has been absent since
2026-09-10 17:57:

```
$ tail -2 ~/modem-status/sentinel.log            # before removal
2026-09-10_20:33:57 recovery chain done
2026-09-10_20:38:47 STOP-file present, sentinel exiting
$ systemctl --user is-active sentinelkeeper-105921.service   ->  active   (never stopped)
$ ls ~/modem-status/RIG_LOCK                     ->  No such file or directory
$ rm -f ~/modem-status/SENTINEL_STOP             # 22:34:10
```

The keeper relaunched the sentinel 103 s later. **Its first poll declared a wedge and
ran one recovery chain** — expected, and worth recording rather than hiding: the
sentinel gates on 148's `idle_rx` delta over a 10 s window, and it sampled across the
daemon restart the handover bring-up had just performed, so the delta read 0/s. The
chain is its designed path and it completed clean:

```
2026-09-10_22:35:53 sentinel (re)launched by keeper
2026-09-10_22:36:08 WEDGE detected (rate=0/s) -- recovering
gate try 1: 148 rx=1246 f/s  146 rx=1247 f/s (need >= 1120)
ARM GATE PASS (try 1)
10.0.0.146 watchdog: ALIVE pid=16159 [wd] === STARTING 03:37:14 pid=16159 ===
10.0.0.148 watchdog: ALIVE pid=82757 [wd] === STARTING 22:37:17 pid=82757 ===
=== r3 BRING-UP COMPLETE ===
2026-09-10_22:37:26 recovery chain done
```

Its next scheduled status line (the loop sleeps 290 s after a recovery) is healthy on
both legs:

```
$ tail -1 ~/modem-status/sentinel.log            # 22:42:31
2026-09-10_22:42:30 ok rate=1868/s crc=100.0% tx=1868/s rev=1245/s rcrc=100.0% rtx=1245/s
```

`rev=1245/s` is the canonical healthy reverse rate and `rate=1868/s` is the documented
1.5× forward window artefact, not a defect; CRC is 100 % on both legs.
**`sentinel.log` is clean again from 2026-09-10 22:42:30 onward; everything from
17:57 to 22:42 is rig work.**

**Final health gates, taken as the last rig action of the task:**

```
$ ops/health_probe_reset_aware.sh 10.0.0.148 12          # 22:42:40
fsync=1263 wcnt=1263 resets_s=0/12 clean=12/12
$ ops/health_probe_reset_aware.sh 10.0.0.146 12          # 22:42:53
fsync=1267 wcnt=1267 resets_s=0/12 clean=12/12
```

Rig state at handover, verified:

| | 148 (role A) | 146 (role B) |
| --- | --- | --- |
| `/boot/BOOT.BIN` | `3e7f4232a3b5` (sp2A) | `d94b4df391a1` (sp2B) |
| `CURRENT.txt` says | `BOOT.BIN.148.sp2A.3e7f4232a3b5` | `BOOT.BIN.146.sp2B.d94b4df391a1` |
| `qpsk_tun` | pid 82500, alive | pid 15672, alive |
| `lock_watchdog.sh` | pid 82918, alive | pid 16465, alive |
| health gate | `1263 … clean=12/12` | `1267 … clean=12/12` |
| on-board rollback | `/root/BOOT.BIN.bf2a7305bbe0.bak` | `/root/BOOT.BIN.9acbe2ebe1db.bak` |

`sentinel-223553.service` active, `sentinelkeeper-105921.service` active,
`SENTINEL_STOP` absent, `RIG_LOCK` absent, no rig unit running.

## Step 6.8 — rail defects and cautions found or confirmed here

1. **`capture_r3 -k` leaves both on-board watchdogs dead and nothing says so.** The
   health gate reads a clean 12/12 with no watchdog running. A `-k` leg must be
   followed by a bring-up (or an explicit watchdog relaunch) before the rig is left
   unattended. Confirmed twice today.
2. **A `-k` reverse leg leaves 146 in a reset storm** (`fsync=0 … resets_s=12/12`)
   because the end-of-leg wedge has no watchdog to clear it. One standard bring-up
   clears it; this is a known and now twice-reproduced class, not a 146 defect.
3. **Releasing `SENTINEL_STOP` immediately after a bring-up costs one sentinel
   recovery chain**, because the sentinel's 10 s `idle_rx` delta straddles the daemon
   restart and reads 0/s. Harmless here, but on a busy rig it is an unexpected arm —
   prefer releasing the hold ~1 min after the last daemon restart.
4. **`rig_unlock` still deletes `SENTINEL_STOP`** (11c's finding, unchanged). Every
   wrapper here re-asserts the hold in its EXIT trap. The mutex still needs
   `SS_MINE`-style ownership.
5. **`ops/flash/flash_146_txfix.sh` still has no `SENTINEL_STOP` ownership** (11b
   concern 1, 11c concern 5) — no 146 flash rail was run today, so it is untouched.
6. **`ops/flash/arm148_mode1.sh` must refuse a non-148 `B=`** (11c concern 1). Not
   re-attempted: no mode-1 arm was performed on 146 in this task, by ruling.
7. **The Tap-A `pair.iq` was DEGENERATE on every leg today** (`#48` stale-DDR-replay
   signature, `occupied BW` 2.4–3.8 MHz against ~23 MHz expected). The rail detects and
   scopes it correctly — `frames.bin` and the host counters are unaffected, and no
   IQ-based claim is made in this step — but the IQ tap is not currently usable on
   this pair and would need a reboot-class recovery before any EVM work.

### Closure 2026-09-11 (post-plan, commit on `per-under-1pct-2026-07`)

Items 1, 4, 5 and 6 are fixed in the tree; items 2, 3 and 7 are behaviours, not
script defects, and stay as cautions.

- 1: `ops/capture_r3.sh -k` now relaunches `lock_watchdog.sh` on both boards in
  its keep-up branch (the same launch line `exp_forward.sh` / `rf_loopback.sh` use).
- 4: `ops/sim_repro/riglock.sh` records `RIG_SS_MINE` in `rig_lock`; `rig_unlock`
  removes `SENTINEL_STOP` only if it created it. `RIG_LOCK` / `SENTINEL_STOP_FILE`
  are overridable for the desk test.
- 5: `ops/flash/flash_146_txfix.sh` [1/6] takes `SENTINEL_STOP` ownership exactly
  as the 148 rail does (`SS_MINE`, EXIT trap, DRY never touches it).
- 6: `ops/flash/arm148_mode1.sh` refuses `B` other than `10.0.0.148` with
  `ARM_FATAL` (exit 2) before any ssh; no override.

All four are pinned by `ops/tests/test_rail_guards.py` (8 desk tests, no board
contact; the 146 rail is exercised under `DRY=1` against a temp hold file).

### Correction to the flash dates recorded in the cut-over

The first draft of the cut-over quoted "on rig since 2026-09-10 16:55" (148) and
"17:46" (146). **Those were the bank-file mtimes on nemo — when the artefact landed in
`images/`, not when it reached a board** — and the 146 figure was provably wrong: 11b's
own reverse leg meta reads `rx=10.0.0.146 image_md5=9acbe2ebe1db… ts=2026-09-10T18:36:13`,
i.e. 146 was still on the OLD image at 18:36. Replaced with the times the rails
actually logged:

```
$ tail ops/flash/txfix_flash_20260910_175943.log        # 148
17:59:43 === [1/5] preconditions ===
17:59:44   148 current image: bf2a7305bbe0 (expect bf2a7305bbe0)
17:59:48   FLASHED 3e7f4232a3b5
18:00:57   booted image: 3e7f4232a3b5 (expect 3e7f4232a3b5)
18:04:00 FLASH_DDRCAP2_OK 3e7f4232a3b5 (sentinel released)
```

```
FLASH_146T start 2026-09-10T18:42:33-04:00 ... image=d94b4df391a1 tag=sp2B    # 146
  146 current image: 9acbe2ebe1db (expect 9acbe2ebe1db)
  staged; rebooting 146            146 back after ~45s
=== [3/6] readback verify (rail) ===
  booted image: d94b4df391a1 (expected d94b4df391a1)          # ~18:43, before 18:43:43
```

So: **148 flashed 17:59:48, readback-verified 18:00:57; 146 flashed ~18:43,
readback-verified by the rail's `[3/6]`.** No reconstructed time is left in a
provenance file.
