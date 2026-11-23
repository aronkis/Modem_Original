# Rig mutex, settle gate and witnesses: silicon validation, 2026-09-25 22:45-23:05

Plan `docs/superpowers/plans/2026-09-25-rig-instability.md` Task 8, on the shipped sp3prod pair at
r3. **No flashing** -- one bring-up and two short captures. Tasks 1-7 were merged first (master
`1f548625`).

## 1. The mutex stops the collision that hung 148

While a bring-up held the lock (`owner=bringup-r3 pid=1312169`), an ad-hoc board call -- the exact
shape of the 2026-09-25 incident -- was refused before reaching ssh:

    $ ops/anyssh.sh 10.0.0.148 'echo should-not-happen'
    RIG_LOCKED by: owner=bringup-r3 pid=1312169 since=2026-09-25_22:45:23 -- refusing 10.0.0.148 ...

    $ ops/rigprobe.sh 10.0.0.148 0x104
    RIG_LOCKED by: owner=bringup-r3 ... -- refusing to start (rigprobe-1312419)

The stronger proof came unprompted. During the first validation capture the delivery sentinel
independently decided to recover, and its own log records the refusal:

    2026-09-25_22:51:11 probe failed x2 with both boards pingable -- recovering (post-reboot bring-up)
    RIG_LOCKED by: owner=capture_r3-B pid=1315699 since=2026-09-25_22:49:04 -- refusing to start (bringup-r3)
    2026-09-25_22:51:11 recovery chain done (post-reboot, attempt 1/3)

That is the sentinel's recovery arm and a measurement overlapping -- the thing that cost a physical
power cycle this afternoon -- now prevented by construction rather than by luck.

## 2. The settle gate holds the arm

    gate try 1: 148 rx=1246 f/s  146 rx=1245 f/s (need >= 1120)
    ARM GATE PASS (try 1)
    ARM_SETTLE_OK after 60s: 148 rx=1247 f/s  146 rx=1246 f/s

The 2026-09-25 failure was a gate that passed at 1247 f/s over a link that was at 478 f/s a minute
later. The re-check now runs and, here, confirmed the arm held. Latched steering writes verified on
both boards in the same run (`SRO_SIGN 10.0.0.146 wrote=1 readback_mode=0x1`, `148 wrote=0
readback_mode=0x0`) -- the Task 4 path, exercised end to end.

## 3. A finding the validation produced: the sentinel was causing wedges

The first validation capture **wedged after 23 s** (`MID_CAPTURE_WEDGE ... delivery flatlined 16s`)
on the shipped pair. Its own new `sentinel_before` field recorded why: the sentinel was mid-recovery
at the time. Standalone `capture_r3.sh` held the rig lock but **not** `SENTINEL_STOP`, so the
sentinel kept probing, had its probes refused by the new guard, read that as `probe failed (ssh?)`,
and escalated.

Fixed: a standalone capture now takes the sentinel hold as well, with the ownership rule unchanged
(a hold it did not create is never removed; campaign rails that already hold it pass through). The
identical capture re-run immediately afterwards:

| | first capture | after the fix |
|---|---|---|
| verdict | `MID_CAPTURE_WEDGE` after 23 s | **`healthy crc=99% rate=988f/s`** |
| sentinel during the run | mid-recovery | `STOP-file present, sentinel exiting` |

**Scope of this finding.** It does NOT explain the 6 of 17 wedges in the 2026-09-24 sp4b campaign:
`gate3_pair.sh` has always held `SENTINEL_STOP` for its whole run, so those legs were not exposed to
this. It does mean any STANDALONE `capture_r3.sh` measurement taken before today was exposed, and
that is worth remembering when reading older one-off captures.

## 4. The new witnesses are populated

`regs_post.txt` from the second capture:

    t=1790391905.63 pkts=0x1B6FA biterr=0x6AA023 rstcs=0xC cfc=0xFFFFF22A fx=0x0 \
      bytewords=0x1479C30 sro_mode=0x1 r4_wit=0x802236C3 r4_extras=0xD05 fixshadow=0x20

`bytewords` is 0x1C0, the discriminator `WEDGE_CLASS.md` sec 4 asked for -- fabric-ring stall versus
host-drain stall is now decidable on the next r4 leg. `sro_mode`/`r4_wit`/`r4_extras`/`fixshadow`
make a leg's steering branch a recorded fact rather than an inference. `meta.txt` carried
`image_md5_peer`, `rf_rx`, `rf_peer` and `sentinel_before` on both captures.

Lock and hold were released cleanly by every run; the rig was left on sp3prod at r3 with the sentinel
monitoring.

## 5. Not done

Task 8 step 2 called for re-running "whichever campaign is next" in full. That is a multi-hour,
four-flash campaign and which one it should be is an operator decision (sp4b Gate 3 versus the
one-way reverse leg), so it was not started unattended overnight. Everything it would exercise --
the mutex, the settle gate, the latched-write path, the new meta fields and register witnesses --
was validated above on real hardware without flashing.
