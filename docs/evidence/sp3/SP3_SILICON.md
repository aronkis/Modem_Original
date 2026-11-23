# SP3_SILICON — Gate 3, silicon, 2026-09-12

Task 13 of the 2026-09-11 model-back-port / SRO-select sub-project. One image
(`BOOT.BIN.jupiter.sp3.c5ec53bc610c5eff837a62b439466660`, 7,203,552 B) onto both
boards, one at a time, under the standing flash rails; a credited forward window;
a credited reverse window; the Gate 3 bit-swap test; then cut-over.

**OUTCOME: GATE 3 FAILED. Both boards were rolled back to the sp2 pair under the
rails and the rig is healthy on sp2A/sp2B.** No cut-over happened:
`images/CURRENT.txt`, `docs/provenance.rst` and `images/README.md` are unchanged
and still correctly describe the boards.

The sp3 image flashed and gated green on both boards, and the one window taken
with an **sp2B** transmitter passed easily (forward, 0.003 %, §5). But every
path driven by an **sp3 transmitter** wedged: three consecutive reverse legs
(§9) and then the forward leg itself once the sentinel resumed watching it
(`07:44:43 ok rate=219/s crc=40.6 %`, `07:49:47 WEDGE detected (rate=0/s)`,
§12). On that evidence the controller ruled Gate 3 FAILED at 07:55 and directed
the rollback, which is recorded in §14.

The failure is **not** the one the brief's stop rule anticipated. The rule that
mandates rollback is "the swapped bit does not bring the comb back — the bit is
inert on silicon", and that condition is **not** met: the sro_sign bit writes,
reads back on `0x25C`, holds under load, and was cleanly exonerated by a
controlled A/B (§9). What failed is the sp3 transmitter path.

Two defects found on silicon along the way are real, independent of the gate,
and one of them is already fixed and committed (§7, §10).

Everything below is verbatim from the rail logs, the capture logs and the
journal at
`/tmp/claude-1000/-mnt-onetb-scratch-qpsk-jupiter-modem/39b6874d-c6fc-487b-ba4e-4530c92c5bc1/scratchpad/t13/`.

---

## 1. Pre-flight (06:27)

```
ping 10.0.0.148 -> PING_OK        ping 10.0.0.146 -> PING_OK
systemctl --user list-units 'sentinel*'
  sentinel-223553.service        loaded active running  delivery_sentinel.sh
  sentinelkeeper-105921.service  loaded active running  sentinel_keeper.sh
ls ~/modem-status/SENTINEL_STOP -> absent (the rails own it)

ops/health_probe_reset_aware.sh 10.0.0.148 12
  fsync=1262 wcnt=1262 resets_s=0/12 clean=12/12
ops/health_probe_reset_aware.sh 10.0.0.146 12
  fsync=1262 wcnt=1261 resets_s=0/12 clean=12/12

md5sum /boot/BOOT.BIN  ->  148: 3e7f4232a3b5 (sp2A)   146: d94b4df391a1 (sp2B)

md5sum images/BOOT.BIN.jupiter.sp3.c5ec53bc610c5eff837a62b439466660
             images/BOOT.BIN.148.sp3.c5ec53bc610c
             images/BOOT.BIN.146.sp3.c5ec53bc610c
  c5ec53bc610c5eff837a62b439466660  (all three — one image, two rail-shaped symlinks)
  stat -c %s -> 7203552
```

Gate 1 covers this tree by the controller's 2026-09-12 ruling (gated tree vs
synthesised tree differ only in `TxRxCompo_ip.v`'s `ip_timestamp` constant);
Gate 2 WNS +0.785 ns (`docs/evidence/sp3/GATE2_TIMING.md`).

Neither board had an on-board `.bak` for its current image beforehand
(`/root/BOOT.BIN.3e7f4232a3b5.bak`, `/root/BOOT.BIN.d94b4df391a1.bak` were
absent); both rails create and re-verify it themselves before touching `/boot`,
and both did.

---

## 2. 148 flash — attempt 1 rolled back on the capTAP golden

```
FLASH_MD5=c5ec53bc610c FLASH_TAG=sp3 FLASH_BAK=3e7f4232a3b5 ops/flash/flash_148_txfix.sh
```
unit `t13-flash148.service`; log `ops/flash/txfix_flash_20260912_063119.log`.

```
06:31:19 === [1/5] preconditions ===
06:31:19   sentinel stopped (SENTINEL_STOP)
06:31:20   148 current image: 3e7f4232a3b5 (expect 3e7f4232a3b5)
06:31:25   FLASHED c5ec53bc610c
06:32:33   booted image: c5ec53bc610c (expect c5ec53bc610c)
06:33:xx   post-arm: fps=1248 errps=0 capTAP=0x1
           ARM_FAIL: capTAP [1] != golden [BCF94856]
06:34:03 === ROLLBACK to 3e7f4232a3b5 (rail: no retry) ===
06:35:13   rollback booted: 3e7f4232a3b5
           post-arm: fps=1248 errps=0 capTAP=0xBCF94856
           ARM_OK profile=lvds_61p44_fdd_jupiter fps=1248 capTAP=0xBCF94856
06:36:43 FLASH_DDRCAP2_ROLLED_BACK
```

This is exactly the case the brief and the controller's notes anticipated: the
golden was the *only* failing criterion (`fps=1248 >= 1120`, `errps=0`), and the
rail's own post-rollback gate passed on sp2A with the golden value, proving the
instrument and the rig were fine.

**Register-naming correction, load-bearing.** The brief and the controller's
notes name the golden as `0x144` compared against `0x04922282`. The rail does
not read `0x144`: `ops/flash/arm148_mode1.sh:24,77` defines `GOLD=${GOLD:-BCF94856}`
and compares it against a read of **`0x20C`** (`viol_count`, the DBGCAP/beatfix
violation-count word — `host/modem_status/ms_regmap.c:73`,
`modem/instruments/dbgcap/README.md`). The script is ground truth; the notes'
register number and value belong to a different word. Both were then read
directly on sp3 (§3) and the notes' `0x04922282` turns out to be correct — for
`0x144`, which the gate does not look at.

## 2b. 148 flash — attempt 2 with `GOLD=1`, PASS

```
FLASH_MD5=c5ec53bc610c FLASH_TAG=sp3 FLASH_BAK=3e7f4232a3b5 GOLD=1 \
  ops/flash/flash_148_txfix.sh
```
unit `t13-flash148b.service`; log `ops/flash/txfix_flash_20260912_063813.log`.

```
06:38:13   148 current image: 3e7f4232a3b5 (expect 3e7f4232a3b5)
06:38:18   FLASHED c5ec53bc610c
06:39:26   booted image: c5ec53bc610c (expect c5ec53bc610c)
06:39:26 === [4/5] two-pass gate ===
           post-arm: fps=1248 errps=0 capTAP=0x1
           ARM_OK profile=lvds_61p44_fdd_jupiter fps=1248 capTAP=0x1
           post-arm: fps=1248 errps=0 capTAP=0x1
           ARM_OK profile=lvds_61p44_fdd_jupiter fps=1248 capTAP=0x1
06:42:26   GATE_PASS x2
06:42:26 === [5/5] Tier-2 witness: sel6 4 MB, decoded ===
06:42:28   4194304
           records 524288  demod_marks 43  tx_marks 43
           toff min 12314 max 12314 mode 12314 (1.000)  distinct 1
           slot histogram [131072, 131072, 131072, 131072]
06:42:29 FLASH_DDRCAP2_OK c5ec53bc610c (sentinel released)
```

The two-pass gate is the consistency test the notes asked for: `0x20C` read
`0x1` on both passes, with `fps=1248` and `errps=0` on both. The witness decode
is clean (`toff distinct 1`, even slot histogram).

---

## 3. The sp3 arm-state instrument words on 148

Read on 148 in the mode-1 arm state left by the rail's gate, three times at 1 s:

```
ops/anyssh.sh 10.0.0.148 '... rd(){ echo "$1">$DRA; cat $DRA; } ...'
read1 0x13C=0x5216F3E2 0x140=0x52B9CE5C 0x144=0x4922282 0x20C=0x1 0x104=0x2B50E 0x108=0x43
read2 0x13C=0x5216F3E2 0x140=0x52B9CE5C 0x144=0x4922282 0x20C=0x1 0x104=0x2BA06 0x108=0x43
read3 0x13C=0x5216F3E2 0x140=0x52B9CE5C 0x144=0x4922282 0x20C=0x1 0x104=0x2BEFF 0x108=0x43
```

* **`0x144` (`cap_out`, the FEC capture word) reads `0x04922282` on sp3 — bit for
  bit the value the controller's notes name as the golden.** The documented
  mode-1 BIST digest is therefore *unchanged* by the sp3 image. `0x13C` and
  `0x140` (`cap_in`, `cap_deint`) are likewise constant across the reads.
* `0x20C` (`viol_count`) reads `0x1` where sp2A reads `0xBCF94856`. This is the
  word the rail gates on, and it is a beatfix violation counter, not a link
  metric; `arm148_mode1.sh`'s arm writes `0x208 0x0`, which leaves the
  DBGCAP/DEMODCAP mux (fixctl bit 13) deselected, so the value is whatever the
  unselected counter holds. A value of 1 on an image that carries the beatfix
  work, against a large number on the older lineage, is consistent but was not
  investigated further — no rig time was spent on it.
* `0x104` climbing and `0x108` frozen at `0x43` = the loopback link is running
  with no new bit errors.

The sp3 `GOLD=` value for `ops/flash/flash_148_txfix.sh` is therefore **`1`**,
and the pre-existing `0x144` golden `0x04922282` still holds. Both are recorded
here as observations; the credited window is the acceptance.

**148 was never observed on sp2A with these words read directly** — the
controller's instruction to record `0x13C/0x140/0x144` on sp2A *before* the
re-flash arrived after the `GOLD=1` run had already completed, by which point
sp2A was no longer on the board. The sp2A comparison point available is the one
the rail printed: `capTAP=0xBCF94856` at `fps=1248 errps=0`.

---

## 4. Bring-up on sp3(148) + sp2B(146) — and the first sro_sign reading

`ops/bringup_r2r3.sh r3`, unit `t13-bringup1.service` (06:43:53 → 06:46):

```
gate try 1: 148 rx=1247 f/s  146 rx=1243 f/s (need >= 1120)
ARM GATE PASS (try 1)
SRO_SIGN 10.0.0.146 wrote=1 readback_mode=0x0 edge=EMPTY
SRO_SIGN_HOOK_FAILED 10.0.0.146
SRO_SIGN_CHECK 10.0.0.146 residual=4294962462 units=reg cfc_mean=4294962462 lo_offset_hz=-99960000 implies=1 conf=1 AGREE
SRO_SIGN 10.0.0.148 wrote=0 readback_mode=0x0 edge=EMPTY
SRO_SIGN_CHECK 10.0.0.148 residual=2147476869 units=reg cfc_mean=2147476869 lo_offset_hz=20000 implies=1 conf=0 DISAGREE
=== r3 BRING-UP COMPLETE ===
```

`SRO_SIGN_HOOK_FAILED 10.0.0.146` here is expected and benign: 146 was still on
sp2B, which has no `0x25C` (`sro_mode`) readback, so the write could not be
confirmed. It cleared the moment 146 was on sp3 (§6).

---

## 5. Forward credited window — PASS

```
ops/capture_r3.sh A -d 600 -k -o ops/r3cap/sp3_fwd_20260912_064628
```
unit `t13-capfwd.service`; log `t13/cap_fwd.log`; `-k` because the brief requires
a `clean=12/12` health gate afterwards, which a quiesced link cannot give, and
because `-k` relaunches both watchdogs since the 2026-09-11 fix.

```
  health try 1: rev 100% fwd 100% (need >= 50%)  rate 1038 f/s (need >= 300)
  wedge verdict: healthy crc=100% rate=1038f/s
  CAP_START ... cfc=0xFFFFF281      CAP_END ... cfc=0xFFFFF260
  frames.bin: 756819 records
CAPTURE_R3_DONE ops/r3cap/sp3_fwd_20260912_064628
```

`meta.txt`:
```
target=A dir=fwd rx=10.0.0.148 peer=10.0.0.146 rung=r3 profile=lvds_61p44_fdd_jupiter
ksym=15360 sps=4 fs=61440000 spf=49332 dur=600 nsamp=4000000 payload=1400 traffic=qpsk_perf_15Mbit
wedge_verdict=healthy crc=100% rate=1038f/s
mid_recover=0 recovery_events=0 recovery_excluded_s=0 recovery_failed=0
image_md5=c5ec53bc610c5eff837a62b439466660
ts=2026-09-12T06:59:43-04:00
```

Scoring:
```
python3 ops/accept_analyze.py ops/r3cap/sp3_fwd_20260912_064628/frames.bin
  sp3_fwd_20260912_064628: live 607s/610s  PER=0.003% (22/736509)  CP95UL=0.005%
      lag33=-0.000  bins={'1': 13, '2': 3, '3-4': 1, '5-20': 0, '21-100': 0, '>100': 0}
  POOLED live-window: PER=0.003% (22/736509)  CP95UL=0.005%
  GATE (<1% at CP95 upper limit, live-link): PASS
```

**Forward PER = 0.003 % = 22 / 736,509**, against the `<= 0.158 %` bar. The
metric is `miss/span` on the host_seq axis, so lost frames are in the
denominator; `mid_recover=0 recovery_events=0` means nothing was excluded from
either numerator or denominator.

Comb:
```
python3 ops/comb/comb_period_ms.py ops/r3cap/sp3_fwd_20260912_064628/frames.bin
  === ops/r3cap/sp3_fwd_20260912_064628/frames.bin
    UNUSABLE: fewer than 200 loss slots -- no period can be resolved
```
Stated precisely: **the tool did not test for and clear a lag line — there were
too few loss events for any period to be resolved.** That is a stronger result
than "no new lag line", not a weaker one.

Health afterwards, twice:
```
pass1 10.0.0.148: fsync=1263 wcnt=1262 resets_s=0/12 clean=12/12
pass1 10.0.0.146: fsync=30   wcnt=31   resets_s=0/12 clean=12/12
pass2 10.0.0.148: fsync=1262 wcnt=1262 resets_s=0/12 clean=12/12
pass2 10.0.0.146: fsync=1262 wcnt=1262 resets_s=0/12 clean=12/12
```
146's first pass caught the post-`-k` transient (no resets, but a rate well
under the 1100 f/s standing gate); the second pass is clean. 148, the receiver
for this window, is clean on both.

`pair.iq` was **DEGENERATE** on this leg (`occupied BW 2.40 MHz`, `env
periodicity 0.9993 at lag 256`) — the known `#48` stale-DDR-replay class already
recorded in `docs/evidence/sp2/SP2_SILICON.md` Step 6.8 item 7. `frames.bin` and
the host counters are unaffected and **no IQ-based claim is made anywhere in
this document.**

---

## 6. 146 flash — PASS

```
FLASH_MD5=c5ec53bc610c FLASH_TAG=sp3 FLASH_BAK=d94b4df391a1 \
  ROLLBACK_BANK=images/BOOT.BIN.146.sp2B.d94b4df391a1 ops/flash/flash_146_txfix.sh
```
unit `t13-flash146.service`; log `t13/flash146_rail.log` (the 146 rail logs to
its unit's journal, not to `ops/flash/`).

```
FLASH_146T start 2026-09-12T07:03:23-04:00 image=c5ec53bc610c tag=sp3 bak=d94b4df391a1 dry=0
=== [1/6] preconditions ===
  SENTINEL_STOP already present (external hold) -- will NOT remove it
  nemo rollback bank: images/BOOT.BIN.146.sp2B.d94b4df391a1 md5=d94b4df391a1 (expect d94b4df391a1)
  148 pre-flash health: fsync=1262 wcnt=1262 resets_s=0/12 clean=12/12
  146 current image: d94b4df391a1 (expect d94b4df391a1)
=== [2/6] on-board rollback backup, then stage + flash ===
  on-board backup verified (/root/BOOT.BIN.d94b4df391a1.bak)
  staged; rebooting 146 ... 146 back after ~45s
=== [3/6] readback verify (rail) ===
  booted image: c5ec53bc610c (expected c5ec53bc610c)
=== [4/6] FULL bring-up (restore_known_good.sh) + NAK=4 re-check on 148 ===
  148 nakstat=4 (rail: must be 4)
=== [5/6] reset-aware health gate on 148 ===
  148 (gate pass 1): fsync=1262 wcnt=1262 resets_s=0/12 clean=12/12 raw_0x1C0_delta=3306806
  HEALTH_GATE_PASS fsync=1262 wcnt=1262 raw_0x1C0_delta=3306806 (pass 1)
FLASH_146T_DONE 2026-09-12T07:11:14-04:00 image=c5ec53bc610c on 146, bring-up + gates green
```

The `SENTINEL_STOP` line is correct behaviour: the hold was mine (taken at
06:43:53 for the bring-up and window, released at 07:43:10), and the rail's
`SS_MINE` ownership check refused to remove someone else's hold.

Bring-up on the sp3 pair, unit `t13-bringup2.service` (07:11 → 07:14):
```
gate try 1: 148 rx=1246 f/s  146 rx=1246 f/s (need >= 1120)
SRO_SIGN 10.0.0.146 wrote=1 readback_mode=0x1 edge=FULL
SRO_SIGN 10.0.0.148 wrote=0 readback_mode=0x0 edge=EMPTY
```
**First confirmed sro_sign readback in the project's history** — `0x25C` is an
sp3 register, and it says the bit landed FULL on 146 and EMPTY on 148, exactly
as `ops/profiles/sro_sign.conf` asks.

---

## 7. DEFECT FOUND ON SILICON: the bring-up was discarding every sro_sign value

Immediately after that bring-up completed, `0x25C` was read on both boards:

```
146: read1 0x25C=0x0 0x234=0x8004B213 0x238=0x0 0x104=0xB225
     read2 0x25C=0x0 0x234=0x8004B70B 0x238=0x0 0x104=0xB71C
     read3 0x25C=0x0 0x234=0x8004BC01 0x238=0x0 0x104=0xBC10
148:       0x25C=0x0 0x234=0x90652332 0x238=0x0
```

`0x25C` reads **`0x0` on both boards** although the hook had just written and
read back `0x1` on 146. Every conf value was being silently discarded before any
traffic ran.

The bit itself is sound. Written on a live, locked link with the watchdog
running (`[wd] LOCKED (drstcs=0 ...)` throughout), it held across 15 reads over
30 s:

```
bash ops/sro_sign.sh 10.0.0.146
  SRO_SIGN 10.0.0.146 wrote=1 readback_mode=0x1 edge=FULL
t+1s .. t+15s  0x25C=0x1  (every read)
```

**Cause:** the bring-up *tail*. `ops/apply_146_ssi_fix.sh:94`, every `rearm_rom`
and every `rearm_byte` pulse `0x000 0x1; 0x000 0x0` — the fabric soft reset —
which clears the write-only fixctl register at `0x208`. `arm148_mode1.sh`
writing `0x208 0x0` beside its own `0x000` pulse corroborates it. The individual
pulse responsible was **not** isolated; no rig time was spent doing so.

**Fix (commit `c8fb117a`):** the sro_sign hook moves from immediately after
`arm_rom` to the last step before `BRING-UP COMPLETE`, after the watchdog
launch. It must not move back above the arm-quality gate, whose retry path calls
`rearm_rom` again. `ops/restore_known_good.sh`'s copy already sits after its
nested bring-up and needed no change. `bash -n` clean; `python3 -m pytest
ops/tests/ -q` → **126 passed**.

Verified on silicon, bring-up unit `t13-bringup3.service`:
```
SRO_SIGN 10.0.0.146 wrote=1 readback_mode=0x1 edge=FULL
SRO_SIGN 10.0.0.148 wrote=0 readback_mode=0x0 edge=EMPTY
=== r3 BRING-UP COMPLETE ===
10.0.0.146 0x25C=0x1 then 0x1
10.0.0.148 0x25C=0x0 then 0x0
```

**Consequence the controller needs stated, not implied: every previously
credited window in this project — including sp2's reverse 0.121 % (908/747,849)
and forward 0.005 % (39/734,808) — was taken with `sro_sign` effectively 0 on
both boards, because the bit was cleared before traffic ever started.** The
forward window in §5 above is in the same position: 148's conf value is 0, so
the intended and actual states coincide, and the window stands. No reverse
window has ever been measured at `sro_sign=1`.

---

## 8. R4D witness decode on 146 (sp3)

With the link up and locked (§7 reads):

* `0x238` (`r4_extras` for the canonical R4D order — `ms_r4_extras_off(0) ==
  0x238`, `host/modem_status/test_modem_status.c:115`) reads **`0x0`**: the
  required "upper half 0" holds, and in fact the whole word is zero.
* `0x234` (`r4_wit`, the witness for that order) is live and advancing
  (`0x8004B213 → 0x8004B70B → 0x8004BC01`), i.e. the R4D witness is counting.
* `0x25C` (`sro_mode` = `{30'b0, extra_armed[1], sro_sign[0]}`) was observed as
  `0x1` (sro_sign=1, extra_armed=0) whenever the bit was set, and `0x0` when it
  was not. **The brief's acceptance value `0x3` was never observed** —
  `extra_armed` was not seen asserted at any point. This is recorded as an open
  question, not explained: no mechanism is asserted here, and the one condition
  not tested is a read taken *during* saturating traffic, which was ruled out
  because mid-capture `direct_reg_access` traffic perturbs the record.

---

## 9. Reverse window — THREE consecutive wedges, not creditable

| leg | out dir | 146 `sro_sign` | outcome |
|---|---|---|---|
| 1 | `ops/r3cap/sp3_rev_20260912_072455` | `1` (readback `0x1` FULL) | `CAPTURE_ABORTED_WEDGED` after 18 s wall (`rstcs=0x4782`) |
| 2 | `ops/r3cap/sp3_rev_20260912_072953` | `1` (readback `0x1` FULL) | `CAPTURE_ABORTED_WEDGED` after 34 s wall |
| 3 (A/B) | `ops/r3cap/sp3_rev_force0_20260912_073506` | `0` (readback `0x0` EMPTY) | `CAPTURE_ABORTED_WEDGED` after 61 s wall |

```
ops/capture_r3.sh B -d 600 -k -o ops/r3cap/sp3_rev_20260912_072455      # unit t13-caprev
ops/capture_r3.sh B -d 600 -k -o ops/r3cap/sp3_rev_20260912_072953      # unit t13-caprev2
SRO_SIGN_CONF=<temp: 148 0 / 146 0> \
  ops/capture_r3.sh B -d 600 -k -o ops/r3cap/sp3_rev_force0_20260912_073506   # unit t13-caprev0
```
All three exited 3 with `CAPTURE_R3_WEDGED ... NOT usable data`. `MID_RECOVER`
was left at its default 0 throughout, so nothing was excluded from any
denominator and no partial leg was scored. `frames.bin` sizes (23,775 / 41,930
records against the ~750,000 of a full leg) confirm these are aborts, not
windows.

Legs 1 and 2 were the **first reverse legs ever taken with `sro_sign` actually
asserted on 146** (§7), which made "the FULL-edge pop wedges the reverse leg" a
live hypothesis — and one that matters, because the corrected CFC reading (§10)
also points at `146=1` being the wrong sign. Leg 3 is the controlled A/B for
exactly that hypothesis, run as a bit-swap (a temp conf consumed by the tail
hook, never a change to `ops/profiles/sro_sign.conf`) and confirmed from its own
log line `SRO_SIGN 10.0.0.146 wrote=0 ... edge=EMPTY` before the traffic started.

**It wedged too. `sro_sign` is therefore exonerated as the cause of these
wedges.** Two wedges out of two is p ≈ 0.09 against the documented ~3-in-10
wedge rate and would never have supported an attribution on its own; the A/B
settles it.

What remains unexplained is that the reverse leg wedged **three times in a row**
(p ≈ 0.027 against that same rate) on a pair whose forward leg ran 607 s of 610
clean at 0.003 % an hour earlier. The forward direction is 146 TX → 148 RX; the
reverse is 148 TX → 146 RX, i.e. the direction that exercises the newly-flashed
148's transmitter into the newly-flashed 146's receiver. **A reverse-direction
regression on the sp3 pair is not excluded by this evidence and is the open
question Gate 3 now turns on.** No further reverse attempts were made: the rig
budget for the session was spent and a fourth capture on a wedging pair buys
less than a rested retry.

## 9b. The 148 bit-swap test was NOT run

The planned Gate 3 bit-swap (`ops/sro_sign.sh --force 1 10.0.0.148`, 300 s
forward, then back to conf, 300 s) was **not performed**. It depends on a
credited reverse window preceding it in the brief's order, and by the time the
reverse leg had failed three times the pair was wedging and the session budget
was gone. Running a forced-1 forward leg on a pair in that state would have
produced an uninterpretable result in the one direction that is currently good.

The stop rule that mandates rolling both boards back is "the swapped bit does
NOT bring the comb back — the bit is inert on silicon". **That condition is not
met, and the opposite is evidenced**: the bit is written, reads back on `0x25C`,
holds under load, and is the only knob whose state was varied between legs 2 and
3. Rolling back was therefore not triggered, and was not done.

---

## 10. The CFC cross-check prints an inverted verdict on both legs

`ops/sro_sign.sh`'s `cfc_mean()` evaluates the raw `0x154` readback with
`$(( v ))`, which treats the 32-bit word as **unsigned** — it never sign-extends.
Every `SRO_SIGN_CHECK` line in this session is therefore wrong-signed:

```
SRO_SIGN_CHECK 10.0.0.146 residual=4294962551 ... implies=1 conf=1 AGREE
SRO_SIGN_CHECK 10.0.0.148 residual=4294963838 ... implies=1 conf=0 DISAGREE
```

`4294962551 = 0xFFFFEC77` and `4294963838 = 0xFFFFF17E` are **negative** as
int32 (−4745 and −3458). Independent confirmation from a tool that does decode
the sign — `capture_r3.sh`'s own `CAP_START` line — gives `cfc=0xFFFFF281` =
−3455 on the forward leg and `cfc=0xFFFFED63` = −4765 on the reverse, matching
the documented healthy values (forward ≈ −3300, reverse ≈ −4750).

Corrected for sign extension, **both** legs read negative, so the documented
rule ("negative implies `sro_sign=0`") gives `implies=0` on both:

| board | printed | corrected | conf |
|---|---|---|---|
| 10.0.0.148 | `implies=1 conf=0 DISAGREE` | `implies=0 conf=0` → **AGREE** | 0 |
| 10.0.0.146 | `implies=1 conf=1 AGREE` | `implies=0 conf=1` → **DISAGREE** | 1 |

**The tool printed the opposite verdict for both boards.** Nothing should read
the session's `AGREE` on 146 as the cross-check endorsing `146=1`; under the
corrected reading it does not. Per `docs/bringup.rst`, **a DISAGREE is a
finding, not an automatic flip**, and no conf value was changed. The mean is in
any case meaningless before sign-extension, since it averages wrapped unsigned
values — the earlier `residual=2147476869` and `residual=859008320` lines on 148
are that artefact. Fixing `cfc_mean()` belongs to Task 12's file scope, not
this task's, and was not attempted here.

---

## 11. Cut-over — NOT performed

`images/CURRENT.txt`, `docs/provenance.rst` and `images/README.md` are
**unchanged**, and after the rollback (§14) they again describe the boards
exactly. No sp3 current row and no sp3 provenance row was ever written: only one
of the two windows existed, and a current row would additionally have claimed a
configuration (`146 sro_sign=1`) that has never survived a window — precisely the
blind spot §7 exposes.

## 12. The forward leg wedged too, once the sentinel resumed watching it

My `SENTINEL_STOP` hold (taken 06:43:53 for the bring-up and windows) was
released at 07:43:10, and the keeper relaunched the sentinel at 07:44:28. The
sentinel watches the **forward** leg (146 TX → 148 RX) — the direction whose
window had passed an hour earlier:

```
2026-09-12_06:27:08 ok rate=1245/s crc=100.0% tx=1245/s rev=1848/s rcrc=99.2% rtx=1868/s   <- sp2 pair, pre-flash
2026-09-12_06:31:58 STOP-file present, sentinel exiting                                    <- first flash rail took the hold
2026-09-12_07:44:28 sentinel (re)launched by keeper
2026-09-12_07:44:43 ok rate=219/s crc=40.6% tx=1245/s rev=-20666/s rcrc=- rtx=-23666/s     <- sp3 pair
2026-09-12_07:49:47 WEDGE detected (rate=0/s) -- recovering
2026-09-12_07:51:52 recovery chain done
```

The healthy sentinel line is `rate=1245 crc=100.0%`. Some caution is due on the
07:44:43 sample — a first sample straddling a daemon restart is a known artefact
(`SP2_SILICON.md` 6.8 item 3) — but the `07:49:47 WEDGE detected (rate=0/s)` five
minutes later is not an artefact.

Independently, `146`'s health probe would not come clean on the sp3 pair across
three consecutive probes, while its *rates* were fine:

```
10.0.0.146: fsync=1264 wcnt=1264 resets_s=2/12 clean=10/12
10.0.0.146: fsync=1266 wcnt=1265 resets_s=2/12 clean=10/12
10.0.0.146: fsync=1259 wcnt=1259 resets_s=3/12 clean=9/12
```
A persistent non-zero `rstcs` delta at a healthy frame rate is a reset storm, not
a settling transient — and 146's receiver is fed by 148's sp3 transmitter.

**The pattern across every measurement of the day:**

| path | transmitter | outcome |
|---|---|---|
| forward window, §5 | 146 on **sp2B** | 607/610 s clean, PER 0.003 % |
| reverse legs 1–3, §9 | 148 on **sp3** | wedged at 18 s, 34 s, 61 s |
| forward, sentinel 07:44–07:49 | 146 on **sp3** | `rate=219/s crc=40.6 %` → `WEDGE (rate=0/s)` |
| 146 RX health, sp3 pair | 148 on **sp3** | reset storm, `clean` 9–10/12 |

The only passing window of the day is the only one whose transmitter was not
running sp3. On that evidence the controller ruled **Gate 3 FAILED** at 07:55 and
directed the rollback.

## 13. What this does and does not establish

* **Established:** the sp3 image builds, flashes, boots, passes both rails' gates
  on both boards, and its receive path is good — the forward window at 0.003 %
  (22/736,509) was received by 148 on sp3. The `sro_sign` bit is live on silicon
  (§7) and exonerated as a cause of the wedges (§9).
* **Established:** every path with an sp3 transmitter wedged, in both directions,
  at both `sro_sign` settings.
* **NOT established:** the mechanism. No transmitter-side instrument was read
  during a wedge, and `pair.iq` was DEGENERATE on every leg (the `#48` class), so
  there is no IQ evidence. "sp3 TX regression" is the leading explanation, not a
  demonstrated one, and it is the question a next iteration has to answer. The
  F3 TX-stall overlay and the fact that Task 8's TX gate was accepted by
  adjudication on witness identity rather than on an absolute criterion (progress
  ruling, 2026-09-11) are the first places to look.
* **NOT established:** anything about `146 sro_sign=1` in service. It has still
  never run a window.

## 14. Rollback to the sp2 pair — both rails green

Ordered by the controller: 146 first (removing the sp3 transmitter feeding 148),
then 148. Started only after the sentinel's recovery chain had finished
(`07:51:52 recovery chain done`) and with no arm in flight; 148's pre-flash
health was `clean=12/12`. 146's own probe was reading `clean` 9–10/12 at the
time — recorded here because it is the defect itself, not a settling transient,
and waiting longer would not have cleared it; the 146 rail's precondition gate
measures 148, which was clean.

**146 → sp2B**, unit `t13-rb146.service`, log `t13/rollback146_rail.log`:
```
FLASH_MD5=d94b4df391a1 FLASH_TAG=sp2B FLASH_BAK=c5ec53bc610c \
  ROLLBACK_BANK=images/BOOT.BIN.146.sp3.c5ec53bc610c ops/flash/flash_146_txfix.sh

FLASH_146T start 2026-09-12T07:55:33-04:00 image=d94b4df391a1 tag=sp2B bak=c5ec53bc610c dry=0
  sentinel stopped (SENTINEL_STOP, owned by this rail)
  nemo rollback bank: images/BOOT.BIN.146.sp3.c5ec53bc610c md5=c5ec53bc610c (expect c5ec53bc610c)
  148 pre-flash health: fsync=1262 wcnt=1262 resets_s=0/12 clean=12/12
  146 current image: c5ec53bc610c (expect c5ec53bc610c)
  on-board backup verified (/root/BOOT.BIN.c5ec53bc610c.bak)
  booted image: d94b4df391a1 (expected d94b4df391a1)
  148 nakstat=4 (rail: must be 4)
  148 (gate pass 1): fsync=1262 wcnt=1262 resets_s=2/12 clean=10/12 raw_0x1C0_delta=3309857
  HEALTH_GATE_PASS fsync=1262 wcnt=1262 raw_0x1C0_delta=3309857 (pass 1)
FLASH_146T_DONE 2026-09-12T08:01:51-04:00 image=d94b4df391a1 on 146, bring-up + gates green
```

**148 → sp2A**, unit `t13-rb148.service`, log
`ops/flash/txfix_flash_20260912_080255.log`. Default `GOLD` applies again:
```
FLASH_MD5=3e7f4232a3b5 FLASH_TAG=sp2A FLASH_BAK=c5ec53bc610c ops/flash/flash_148_txfix.sh

08:02:56   148 current image: c5ec53bc610c (expect c5ec53bc610c)
08:03:00   FLASHED 3e7f4232a3b5
08:04:09   booted image: 3e7f4232a3b5 (expect 3e7f4232a3b5)
           post-arm: fps=1248 errps=0 capTAP=0xBCF94856
           ARM_OK profile=lvds_61p44_fdd_jupiter fps=1248 capTAP=0xBCF94856
           post-arm: fps=1248 errps=0 capTAP=0xBCF94856
           ARM_OK profile=lvds_61p44_fdd_jupiter fps=1248 capTAP=0xBCF94856
08:07:09   GATE_PASS x2
08:07:11   records 524288  demod_marks 42  tx_marks 42
           toff min 12314 max 12314 mode 12314 (1.000)  distinct 1
08:07:12 FLASH_DDRCAP2_OK 3e7f4232a3b5 (sentinel released)
```
The sp2A capTAP golden `0xBCF94856` came back on both passes — the `GOLD=1`
adjudication of §2b was image-specific, exactly as recorded.

**Post-rollback bring-up and verification**, unit `t13-bringup5.service`:
```
ops/bringup_r2r3.sh r3
  10.0.0.146 watchdog: ALIVE pid=24394     10.0.0.148 watchdog: ALIVE pid=4099
  SRO_SIGN 10.0.0.146 wrote=1 readback_mode=0x0 edge=EMPTY
  SRO_SIGN_HOOK_FAILED 10.0.0.146          <- expected: sp2B has no 0x25C readback
  SRO_SIGN 10.0.0.148 wrote=0 readback_mode=0x0 edge=EMPTY
  === r3 BRING-UP COMPLETE ===

md5sum /boot/BOOT.BIN   ->   10.0.0.148: 3e7f4232a3b5     10.0.0.146: d94b4df391a1
ops/health_probe_reset_aware.sh 10.0.0.148 12 -> fsync=1263 wcnt=1263 resets_s=0/12 clean=12/12
ops/health_probe_reset_aware.sh 10.0.0.146 12 -> fsync=1262 wcnt=1261 resets_s=1/12 clean=11/12
```

Both boards are back on the images `images/CURRENT.txt` describes, with their
on-board `.bak` rollbacks intact, and the sp3 image is banked untouched at
`images/BOOT.BIN.jupiter.sp3.c5ec53bc610c5eff837a62b439466660` (plus its two
rail-shaped symlinks) for the next iteration.

---

## 15. Open items for the controller

1. **The sp3 transmitter path is the defect to chase.** Every wedge of the day
   had an sp3 transmitter; the only clean window had an sp2B one. Mechanism not
   established (§13).
2. **`sro_sign` on 146.** The corrected CFC sign says `0`; the conf says `1`; no
   window has ever run at `1`. A finding, deliberately not flipped.
3. ~~**`ops/sro_sign.sh` `cfc_mean()` does not sign-extend** (§10) — Task 12 file
   scope. Until fixed, every `SRO_SIGN_CHECK` verdict is inverted.~~
   **FIXED in commit `45fb5802`** (any reading with bit 31 set is a negative
   int32; the §10 raw values are pinned as regression tests in
   `ops/tests/test_sro_sign_conf.py::TestCfcSignExtension`). Every
   `SRO_SIGN_CHECK` line taken before that commit — including all of §10's —
   is still inverted and must be re-read with the sign flipped; the finding in
   item 2 above was already restated against the corrected sign.

   The final sp3 fix wave found two more defects in the same function and
   fixed them: a FAILED `0x154` read was folded into the average as a genuine
   `0` sample (so a board that answered nothing averaged to exactly 0 and, `0`
   not being negative, was reported as a confident `implies=1`), and a mean of
   exactly 0 was read as a positive sign rather than as the CFO dead zone.
   Both now print `SRO_SIGN_CHECK <ip> UNKNOWN reason=reads_failed|cfo_dead_zone`
   and exit 1. This does not retroactively validate any pre-`45fb5802`
   verdict; it means a *new* `--check` line is either a sign or an explicit
   non-answer.
4. **`extra_armed` (`0x25C` bit 1) never observed asserted**; `0x25C == 0x3` has
   not been seen. Unexplained.
5. **The sp3 `GOLD` for `ops/flash/flash_148_txfix.sh` is `1`** (register
   `0x20C`), while `0x144`'s golden `0x04922282` is unchanged by sp3. Any future
   sp3 flash needs `GOLD=1` passed explicitly; making the golden image-keyed
   would be better than a per-invocation env var.
6. **The brief's and the notes' `0x144` / `0x04922282` do not match the register
   the rail actually gates on** (§2). Reconcile the notes against
   `arm148_mode1.sh` before the next flash task, or the next executor repeats
   this adjudication.
7. **The hook fix (`c8fb117a`) stays** — it is correct and valuable regardless of
   Gate 3's outcome, and it means the *next* sp3 attempt will be the first that
   can actually measure a configured `sro_sign`.
