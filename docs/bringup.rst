Bring-up and porting
====================

How to take a provisioned pair of boards from power-on to a credited link, and
what changes when the pair is not the lab pair (10.0.0.148 / 10.0.0.146).

This page assumes the boards already carry the banked kernel, device tree,
boot image and host daemon — that is :doc:`setup-prebuilt`, and it is the
prerequisite for everything below. Board access throughout is
``ops/anyssh.sh <ip> '<command>'`` (password auth). The boards have **no
remote power**: the only remote recovery from a bad ``/boot`` write is a
reflash, so treat ``/boot/BOOT.BIN``, ``/boot/Image`` and
``/boot/system.dtb`` as precious.

Standing rules, before any of it
--------------------------------

Three rules cost real campaign time to learn, and each one silently
invalidates measurements taken without it.

**No monitor on a board that is receiving.** A DisplayPort or HDMI cable
plugged into a receiving Jupiter costs roughly **1–3 % packet error rate**
on that board's receive leg. It is not an RF effect: the DisplayPort DMA,
its DDR read stream and the PS-GTR lanes beat against the modem's frame
rate and destroy *frame starts*, so the damage appears as bad-magic frames
rather than CRC failures, is visible at the fabric pins, follows the board
rather than the image, and its beat period is re-seeded at every reboot.
Measured on this rig with the same image in the same session
(``docs/evidence/RXFIX_STATE.md`` Tasks 36–37): reverse-leg PER **0.967–2.825 %**
with the display attached against **0.180–0.201 %** with it unplugged, host
bad-magic frames 2.2 % against 0.012 %. Check any board before trusting a
number from it::

   ssh root@<board> 'grep " 28:" /proc/interrupts; sleep 10; grep " 28:" /proc/interrupts'
   # ~1200 counts in 10 s (~120/s) = a display is attached -> unplug it
   # also: cat /sys/class/drm/card0-DP-1/status   -> want "disconnected"

If a display is genuinely needed, keep it on the transmitting board only,
and never quote a receive number measured with one attached.

**Payload whitening is on, and is both-ends-or-nothing.** The TX scrambler
in the fabric is hard-disabled and there is no RX descrambler, so payload
bytes reach the air as they are written. With whitening off, the daemon's
idle frames are a constant byte pattern containing two preamble-like
stretches; the preamble detector occasionally locks onto one of them, the
payload gate starts the frame 1,549 or 3,085 symbols early, and the next
true start truncates it. That was 97 % of the forward residual — the
census-window PER fell 0.045 % → 0.005 % with whitening on
(``docs/evidence/comb/FWD_CRC_REGRESSION_0907.md`` §47.21–§47.23).
``ops/bringup_r2r3.sh`` defaults ``WHITEN=1`` and carries ``QPSK_WHITEN``
into the watchdog's relaunch string; a daemon started by hand must set
``QPSK_WHITEN=1`` too, or the link decodes nothing. Confirm on both
boards::

   tr '\0' '\n' < /proc/$(pgrep -x qpsk_tun)/environ | grep QPSK_WHITEN

**Register reads and arms do not mix.** A ``direct_reg_access`` read on a
board while its ADRV9002 profile is being reloaded hangs the PS with no log
entry, and recovery is a power cycle. Any unit that runs
``ops/bringup_r2r3.sh`` arms **both** boards — a reverse-leg bring-up arms
148 as well. So: no register read on a board while anything that can arm it
is running; every host-side reader sources
``ops/sim_repro/no_arm_inflight.sh`` and calls ``arm_guard`` first; polls
stay at 1 s or slower; rig actors take ``RIG_LOCK``
(``ops/sim_repro/riglock.sh``). The occurrences are logged in
``docs/evidence/RIG_NOPING_FAULT.md``.

Sequence
--------

**1. Flash and provision** — only when the image changes.
``images/CURRENT.txt`` names the current role-A and role-B images, and
``ops/deploy_image.sh <ip> A|B`` reads it, refusing to flash on an md5
mismatch. One board at a time, confirming each is back before touching the
other; then ``ops/provision.sh <ip>`` on each to build the daemon on-board
and stage the LVDS profiles and the watchdog. The full deploy, including
the kernel and device tree a fresh board needs first, is
:doc:`setup-prebuilt`.

**2. Arm, per session.** The whole two-board ceremony is one command::

   cd ops && bash restore_known_good.sh     # or: ./bringup_r2r3.sh r3   (RUNG=r4 / r4 for the sp4 f3072 pair)

It loads the r3 LVDS profile on both boards, sets the LO plan, does the ROM
arm with the double-tap that defeats the false-lock latch, applies the SSI
overrides, starts the daemons with whitening on, flips the byte source, and
starts the watchdogs. The canonical, do-not-paraphrase register sequence
underneath it lives in ``ops/link_test.sh`` (``arm_ber`` / ``coldstart_tun``):
load the profile, ENSM ``calibrated``, front-end GPIOs, ``tx_a`` port, TX LO
with 0 dB attenuation and ``rf_enabled``, RX LO with ``rf_enabled`` and
``automatic`` gain, modem regfile reset, ``0x158=1`` (byte TX), ``0x118=0``,
``0x114=1`` (RX from air), DAC mux, rstCS pulse, byte-DMA arm (``devmem
0x9D300000 32 0x1``).

Two arm-time rules that are load-bearing: the ``agpio4-7`` writes are part
of the sequence, not decoration, and **ADRV9002 tracking calibrations must
not be enabled beyond the profile defaults** — ``quadrature_w_poly`` /
``fic`` / ``rfdc`` enabled at arm time mis-converge and scramble the
constellation past the resolver's one-time lock. The profile ships with the
correct calibration set.

**One-directional test (TX-only / RX-only images).** With role ``TXO`` on
the transmitting board and ``RXO`` on the receiving one
(``ops/deploy_image.sh <ip> TXO|RXO``), the ceremony is::

   ops/oneway_bringup.sh 10.0.0.146 10.0.0.148 [rom|byte]   # tx_ip rx_ip
   ops/oneway_measure.sh 10.0.0.148 60 [rom|byte]

It arms both boards (the TX board keeps its RX SSI enabled for pacing), applies
the TX board's SSI row, ROM double-taps, and gates on the **RX board only**
(0x104 ≥ 90 % of 1245 f/s). ``rom`` radiates the BIST ROM frame with no host
process; ``byte`` starts ``qpsk_tun -B`` on the TX board. The measure script
prints one ``ONEWAY_MEASURE`` line with the command, sample count and the
denominator (expected frames at 1245 f/s over reset-free seconds, lost frames
counted). No tun link, no watchdog pair, no mode-1 BIST gate: none of them
exist on a half image. Swap the two IPs to test the other direction; the LO
plan follows the TX board (146 → 2.000/2.000020 GHz, 148 → 1.900/1.900040 GHz).
Restore the pair with ``deploy_image.sh <ip> A|B`` and
``restore_known_good.sh``; see :doc:`build-and-flash` for how the images are
built and gated.

**3. Acquire — verified lock.** Acquisition is stochastic: a board armed
before its peer radiates can sit in a never-locks state, and roughly one arm
in three needs a nudge. The procedure that makes lock deterministic is

1. start ``ops/lock_watchdog.sh`` on the receiving board, detached;
2. wait about 12 s, then kill it (``pkill -f '[l]ock_watchdog'``) — never
   leave it running through a measurement, because a mid-window re-arm
   pulses reset and corrupts the run;
3. probe with a short ``qpsk_tun -B`` and require aligned frames
   (clean + noisy) above 100;
4. on zero aligned, pulse the carrier-sync reset (``0x110`` 1 → 0), re-arm
   the byte DMA, and repeat from step 1, up to three tries.

``ops/exp_forward.sh`` implements this loop; fold it into any new runner
rather than re-deriving it.

**4. Pin the RX gain, after lock.** The hardware AGC's mid-frame gain steps
cost about 2× in BER on the margin-limited direction. After verified lock,
read the settled ``in_voltage0_hardwaregain``, switch
``in_voltage0_gain_control_mode`` to **``spi``** (the token ``manual`` is
silently rejected) and write the value back. Pin only *after* lock, so the
captured value is the settled operating point; leave the mode ``automatic``
during acquisition.

**5. Verify** — the health gate below, then the acceptance ladder in
:doc:`testing`.

SRO sign on a fresh pair
------------------------

Both boards run the same image (``images/CURRENT.txt`` roles A and B, sp3clamp004
``8503f226395c`` since 2026-10-01), but the receiver steering branch is chosen per
board at bring-up by ``ops/sro_sign.sh`` (``ops/profiles/sro_sign.conf``), and the two
branches assume opposite sample-rate-offset signs. Board 148 runs R4B, which
wants the receiver's oscillator to be the **faster** one (a negative
sample-rate offset); board 146 runs R4D + R1, which wants the **slower**
one. On the lab pair this is settled and recorded in the conf; on a fresh pair it is not.

So before flashing a fresh pair, **measure the RX-LO residual sign first**
and pick the role assignment from it — the sign cross-check procedure is in
``docs/evidence/RXFIX_STATE.md``. Getting it backwards does not fail
loudly; it costs PER on both legs.

Two operating points are deliberate and should not be "fixed" back to the
plain LO without a cell run: the forward RX LO sits **+20 kHz off-null**
(``LO_A_RX=2100020000``) and the reverse RX LO **+40 kHz off-null**
(``LO_B_RX=1850040000``), both set from sweeps in August. They were load-bearing
on the shipped images because the receiver's coarse carrier estimate dithers in
sign around a zero residual (the "dead zone") and a dither could knock the
symbol-timing loop onto its clamp rail, where it stayed until a soft reset
(``docs/evidence/link/CARRIER_LOCK_LATCH_2026-09-29.md``). Since sp3clamp004 the
timing loop cannot latch (clamp 0.004: a gap or a wrong-way start re-locks in
3-4 frames, verified on silicon), so the offsets are no longer what keeps the
link locked -- they remain the measured operating points, and a null-residual
plan is a cell run away, not a default change.

The forward leg's **carrier** is 2.1 GHz since 2026-10-01 (``LO_B_TX=2100000000``; the 2.0 GHz
forward link lost 1.5-2.4 % from 09-29 evening on every image while 2.1 GHz read its baseline --
``docs/evidence/link/FORWARD_LINK_2026-10-01.md``). The reverse leg's **carrier** is 1.85 GHz since 2026-09-29 (``LO_A_TX=1850000000``,
with the RX offset above; it was 1.9 GHz before). The pair's weeks of reverse-leg
collapse were a frequency notch at 1.9 GHz -- an interference signature, with
1850 and 1950 both clean either side of it and the same notch appearing on
148's receiver when the forward leg was moved onto it -- and at 1.85 GHz the
reverse leg ran ten of ten fault-paired measurements clean (613 s at 0.004 %,
zero carrier resets) with the forward leg unaffected by the plan. 1950 and 2050
are **not** usable: a 50 MHz TX-RX spacing raises each board's self-leakage by
13-15 dB. All four LOs live in ``ops/rung_table.sh`` per rung (r4 keeps its own
plan) and stay environment-overridable. Evidence:
``docs/evidence/link/OVERNIGHT_CAMPAIGN_2026-09-29.md`` and
``docs/evidence/link/GATE3_REVERSE_PLAN_2026-09-29.md``.

**Arm gate when one direction is down: ``GATE_DIR``, not a lower threshold.** The
arm-quality gate requires both receivers at ``GATE_FPS`` (1120 f/s at r3). When one
direction is intentionally or knowingly down (a collapsed reverse leg, a one-way
image), ``GATE_DIR=A`` scopes the gate to 148's receive (the forward direction) and
``GATE_DIR=B`` to 146's; ``ops/degraded_capture.sh`` already relies on it. Lowering
``GATE_FPS`` instead (as the 2026-10-04 bench did with ``GATE_FPS=400``) passes a
half-dead pair on a number that means nothing; use the direction knob. Export it into
``capture_r3.sh`` legs too -- the rail re-runs the bring-up at the start of every ``-k``
leg with the default gate.

**One-cell diagnostics the rails carry (2026-10-07).** ``SELF_MUTE=1`` on a
``capture_r3.sh`` leg mutes the receiving board's *own* transmitter (TX attenuation
−40 dB, restored by the next arm): duplex self-interference looks exactly like a
demodulator defect (frame-start garbage, periodic) and this cell separates it in one
leg (1.9 % → 0.013 % on 2026-10-02). ``TILT_EQ_SET=off|<dB>|auto`` writes the tilt
corrector words after the rail's own bring-up (which clears them). The bring-up now
ships ``ops/lock_watchdog.sh`` to ``/root`` on both boards, so a watchdog fix no
longer needs ``ops/provision.sh`` or a manual copy.


**Receiver in-band tilt corrector (TiltEq, images from ``sp3tilteq2`` on).** A
multipath fade on the air path puts a slope across the 15.36 Msym/s band that
biases the power-4 coarse frequency estimator (−14.6 dB across 16 MHz cost 46 %
of frames on 2026-10-02; ``docs/evidence/link/FORWARD_LINK_2026-10-01.md`` §9/§11).
The receiver model now carries three cascaded complex one-pole stages in front
of the AGC whose coefficients are two AXI write words, ``0x260`` ``tilt_eq_a12``
``{a2[31:16] a1[15:0]}`` and ``0x264`` ``tilt_eq_a3en`` ``{en[31] a3[15:0]}``
(sfix16_En15, zero = exact pass-through). Like ``0x208`` they are cleared by the
soft reset, so the write belongs at the very end of a bring-up:
``ops/tilt_eq.sh <ip>`` captures 262k Tap-A samples, scores the slope
(``ops/tilt_score.py``), solves the coefficients (``ops/tilt_eq_solve.py``),
writes the words through ``direct_reg_access``, reads them back and re-measures,
printing one ``TILT_EQ <ip> t_before=.. a1=.. a2=.. a3=.. w260=.. w264=..
readback=OK t_after=..`` line (below 3 dB of slope it writes zeros). The hook in
``bringup_r2r3.sh`` is **opt-in** -- ``QPSK_TILT_EQ=1`` -- until the corrector has
a Gate 3 pass on silicon (``docs/evidence/link/TILT_EQ_2026-10-03.md``); on an
image without the block the words read back 0 and the hook reports MISMATCH.

``ops/sro_sign.sh`` automates the write and a cross-check, and both
``bringup_r2r3.sh`` and ``restore_known_good.sh`` call it for each board **last,
after every re-arm and soft reset in the sequence** — it used to run right after
the board's arm (its ``0x110`` pulse), where the bring-up's own tail undid it;
commit ``c8fb117a`` moved it to the end (see the Status note below):

* it writes fixctl (``0x208``) **bit 5** from ``ops/profiles/sro_sign.conf``
  (one ``<ip> <0|1>`` row per board — ``0`` = EMPTY-edge steering only, the
  148 case above; ``1`` = also FULL-edge extra pop, the 146 case) and reads
  back ``0x25C`` (``sro_mode``) to confirm the bit landed, printing
  ``SRO_SIGN <ip> wrote=<0|1> readback_mode=<hex> edge=<EMPTY|FULL>``;
* ``0x208`` is **write-only on the bus**. ``sro_sign.sh`` is the one place in
  the tree that owns a shadow for it: every write goes through its
  ``fixctl_write`` helper, which writes the full word and then records it
  verbatim in ``/dev/shm/fixctl.word`` on the board, so a later write can
  flip bit 5 without disturbing ``w1_freeze`` (bit 4) or anything else in the
  word. (``ops/flash/arm148_mode1.sh`` still writes ``0x208`` directly with
  the full word ``0x0`` for its 148-only loopback arm and does not go through
  this convention — a mode-1 arm there clears the shadow's meaning until the
  next ``sro_sign.sh`` write re-establishes it.)
* **The shadow goes stale across a fabric soft reset.** ``/dev/shm`` is tmpfs
  and survives everything short of a reboot, but the soft reset (``0x000 0x1;
  0x000 0x0``) **clears** ``0x208``. After one, ``/dev/shm/fixctl.word``
  over-states the register: it still claims ``w1_freeze`` (or any other bit)
  is set when the hardware has forgotten it, and the read-modify-write would
  write those stale bits back and silently re-assert them as a side effect of
  setting ``sro_sign``. Bring-up and restore always follow a reset, so on that
  path the correct prior is ``0x0``, not the file — and both hooks therefore
  pass ``ops/sro_sign.sh <ip> --bringup``, which re-seeds the shadow to zero
  before the write and prints ``SRO_SIGN_RESEED <ip> was=<hex> now=0x0``. It
  discards remembered bits on purpose. A plain ``sro_sign.sh <ip>`` (the
  mid-session path, where the register and the file agree) is unchanged and
  still preserves the other bits.
* ``ops/sro_sign.sh <ip> --force <v>`` writes the given value regardless of
  the conf and prints ``SRO_SIGN_FORCED`` instead of ``SRO_SIGN`` — the
  manual override for a bit-swap test.
* ``ops/sro_sign.sh --check <ip>`` cross-checks the choice: it reads the CFC
  estimate (``0x154``, the same register ``modem_status`` reads) ten times at
  1 s cadence and averages it, and reports the leg's deliberate RX-LO offset
  from ``bringup_r2r3.sh``'s ``LO_A_RX``/``LO_B_RX`` for context. **No
  register-to-Hz scale for 0x154 is documented anywhere in this tree**
  (``ms_regmap.c`` carries no conversion, and ``test_modem_status.c``'s
  golden output prints it as a bare signed integer, e.g. ``cfc 154 -3301``),
  so the cross-check is by **sign only, in raw register units**: a negative
  mean implies ``sro_sign=0``, a positive mean implies ``sro_sign=1``. It
  prints ``SRO_SIGN_CHECK <ip> residual=<n> units=reg cfc_mean=<n>
  lo_offset_hz=<n> implies=<0|1> conf=<0|1> AGREE|DISAGREE`` — ``residual``
  and ``cfc_mean`` are the same raw register value; ``units=reg`` records
  that no register-to-Hz scale is documented (this becomes ``units=hz``,
  with ``residual`` recomputed in Hz, if a scale is ever documented).
  **A DISAGREE is a finding, not an automatic flip** — it means the sign
  convention above should be re-derived for this leg before the next
  credited PER window, not that the bit gets flipped on the spot.
* **A cross-check that could not be made prints ``UNKNOWN``, not a sign.**
  Two cases, both exiting 1: ``reason=reads_failed`` when fewer than
  ``SRO_CHECK_SAMPLES`` of the ``0x154`` reads returned a number (a failed
  read used to be folded into the average as a genuine ``0`` sample, so a
  board that answered nothing at all averaged to exactly ``0`` and — since
  ``0`` is not negative — was reported as a confident ``implies=1``); and
  ``reason=cfo_dead_zone`` when every read landed and the mean is exactly
  ``0``, which has no sign and is the documented CFO dead-zone signature
  rather than evidence for ``sro_sign=1``. Because the hooks call ``--check``
  additively and non-fatally, an ``UNKNOWN`` surfaces as one
  ``SRO_SIGN_CHECK_HOOK_FAILED`` line in the bring-up log and changes nothing
  on the board.

**Status (2026-09-12).** Two defects found running the sp3 silicon gate
(Task 13/14, ``docs/evidence/sp3/SP3_SILICON.md``):

* **The bring-up used to clear every ``sro_sign`` write before any traffic
  ran (FIXED, commit ``c8fb117a``).** ``ops/apply_146_ssi_fix.sh``'s
  ``rearm_rom``/``rearm_byte`` pulse the fabric soft reset (``0x000 0x1;
  0x000 0x0``), which clears the write-only fixctl register at ``0x208`` —
  so the hook running right after ``arm_rom`` had its write undone by the
  bring-up's own tail. ``0x25C`` read back ``0x0`` on both boards
  immediately after a bring-up that had just printed a confirmed
  ``SRO_SIGN ... wrote=1 readback_mode=0x1 edge=FULL``
  (``SP3_SILICON.md`` section 7). **Every previously credited window in
  this project — including sp2's reverse 0.121 % (908/747,849) and
  forward 0.005 % (39/734,808) — was taken with ``sro_sign`` effectively 0
  on both boards**, because the bit was cleared before traffic ever
  started; those windows are unaffected only because 148's conf value is
  0 anyway, so the intended and actual states coincided. The fix moves
  the ``sro_sign.sh`` hook to the **last** step before bring-up prints
  ``r3 BRING-UP COMPLETE``, after the watchdog launch, and it must stay
  there — not move back above the arm-quality gate, whose retry path
  calls ``rearm_rom`` again. ``ops/restore_known_good.sh``'s own copy
  already sat after its nested bring-up and needed no change.
* **``ops/sro_sign.sh``'s ``--check`` printed inverted verdicts (FIXED,
  Task 14).** ``cfc_mean()`` evaluated the raw ``0x154`` readback with
  bash's ``$(( v ))``, which never sign-extends a 32-bit register in
  64-bit arithmetic — every negative CFC reading was averaged and
  sign-tested as a huge positive number instead, inverting every
  ``implies=``/``AGREE``/``DISAGREE`` verdict the tool has ever printed.
  Sign-extending a reading is now explicit: any raw value ``>= 2**31`` is
  treated as negative (subtract ``2**32``) before it is summed. Example
  from the same session, ``docs/evidence/sp3/SP3_SILICON.md`` section 4:
  raw ``0x154`` readback ``4294962462`` (``0xFFFFED1E``) is **−4834** as
  int32, not the ``4294962462`` the unfixed tool printed and compared as
  positive. **A DISAGREE is still a finding, not an automatic flip** —
  the fix corrects the sign of the printed verdict, it does not change
  what the tool does with it.
* **sp3's mode-1 arm-gate golden is a different register from sp2's.**
  ``ops/flash/arm148_mode1.sh``'s ``GOLD=${GOLD:-BCF94856}`` gates on a
  read of ``0x20C`` (``viol_count``, the DBGCAP/beatfix violation-count
  word), not the ``0x144`` BIST capture word the sp2-era notes name. On
  the sp3 image ``0x20C`` reads ``0x1`` where the sp2 lineage reads
  ``0xBCF94856`` (``0x144``'s golden ``0x04922282`` is unchanged by sp3);
  **any sp3 flash needs** ``GOLD=1`` **passed explicitly to
  ``ops/flash/flash_148_txfix.sh``**, or the rail's post-arm gate rolls
  the flash back on a false-negative golden mismatch
  (``SP3_SILICON.md`` sections 2 and 3). This is image-keyed, not a
  standing default: the sp2 golden ``0xBCF94856`` still applies to every
  sp2 flash.

Health gate
-----------

Nothing counts until the link passes the gate, and the gate must be the
reset-aware probe — ``0x104`` is reset by rstCS and by the watchdog's
``0x000`` soft reset every 5–7 s on a *healthy* link, so a naive
delta-over-window probe under-reads a healthy link by roughly 2×::

   cd ops
   bash health_probe_reset_aware.sh 10.0.0.148 12   # forward (146 TX -> 148 RX)
   bash health_probe_reset_aware.sh 10.0.0.146 12   # reverse (148 TX -> 146 RX)

Healthy reads ``fsync≈1245 wcnt≈1245 clean=12/12``. The standing gate for
counting anything is **framesync rate ≥ 1100 f/s and wordcnt-derived rate
≥ 1100 f/s**; a frozen ``wordcnt`` is an unambiguous wedge verdict. A
growing ``rstcs`` (0x150) delta means a reset storm, which in practice means
the wrong or an old image; all-PHASE buckets mean a quadrant mis-lock, so
redo the verified-lock loop; ``frames_scored=0`` means no lock at all.

Why the ladder exists at all is :doc:`measurement-discipline`; what the
credited numbers are, and how a credited run is taken, is
:doc:`performance`.

A one-directional degradation is an antenna, not a DSP problem
--------------------------------------------------------------

On 2026-09-06/07 the forward leg collapsed to about 60 % CRC-good with no
image and no configuration change. Board 148's ``in_voltage0_rssi`` at the
shipped carrier had drifted 27.5 → 34.9 dBFS (weaker) over three days while
the reverse receiver did not move; the loss was frequency-selective; and it
produced every DSP-looking symptom — carrier-loop reset storms, an apparent
CFO error on the preamble correlator, a receiver that went deaf, and a
failing arm gate. **Swapping 148's RX antenna with 146's moved the loss to
146** (``docs/evidence/comb/FWD_CRC_REGRESSION_0907.md`` §46.8–§46.12).

The forward and reverse legs use *different* antenna pairs (146-TX → 148-RX
against 148-TX → 146-RX), so a one-direction-only defect points at one of
two physical elements, not at "the band". Before any DSP investigation of a
leg that degraded without a configuration change: compare that receiver's
rssi against its own history at the same LO and gain, and if it drifted, run
``ops/comb/band_ber_sweep.sh FREQS="1900 1960 2000 2040 2110" DWELL=25``,
then swap one antenna or cable and re-run. Fifteen minutes. Note also that
"level excluded" arguments comparing *different* frequencies do not survive
a frequency-selective element.

Porting to another pair
-----------------------

Everything in the repository is already board-agnostic: ``ops/anyssh.sh``,
``ops/provision.sh``, the LVDS profiles, ``ops/lock_watchdog.sh``, the host
sources and ``ops/link_test.sh``'s arm sequence carry no hardcoded IP or
board identity (the arm uses the fixed channel-1 datapath — ``voltage0``,
TX1/RX1 LO, ``tx_a``, ``agpio4-7`` — on any board). Point the tools at your
boards with ``export A_IP=<ip> B_IP=<ip>`` (or ``-A``/``-B`` per call) and
run ``./link_test.sh preflight``; "A" and "B" are role labels, and the
frequency plan is keyed to the roles.

A new board needs its **own** device tree: the qpsk dtb is merged onto that
board's pristine ``system.dtb``, so pull it read-only first, keep it, and
build against it (``ops/deploy_dtb.sh build``) — :doc:`setup-prebuilt`
Step 0. The kernel ``Image`` is common to all boards.

What you must re-survey, and must not copy from this rig:

* **The frequency plan.** Forward 2.00 / reverse 1.90 GHz came from a
  1.5–2.1 GHz survey of *these* units, where 2.10 GHz was polluted by 148's
  TX-LO leakage. Re-run the survey and set ``FWD_HZ`` / ``REV_HZ``.
* **The RX-gain pin value.** The procedure is universal; the number is the
  settled operating point of *this* link budget.
* **The SRO sign**, and therefore which image goes on which board — see
  above.
* **Whether your boards tick.** The ~1.5 s BBDC calibration insertion is a
  per-unit artifact observed on one of these two units
  (``docs/evidence/ESCALATION_ADI.md``). The shipped compensation is a no-op
  on a board that does not exhibit it, so it costs nothing either way —
  but do not assume you have inherited the defect.
* **The PER numbers themselves.** :doc:`performance` records what this pair
  achieves on its own antennas and bench.

The rung table
--------------

Every rail takes its rate, geometry and carve from ``ops/rung_table.sh`` (``rung_set r3``
in a script, ``ops/rung_table.sh r4`` to print a rung):

.. list-table::
   :header-rows: 1

   * - rung
     - profile / SSI
     - ``qpsk_tun``
     - fabric frame
     - frames/s (gate)
     - host carve, MTU
   * - ``r2``
     - ``lvds_30p72_fdd_jupiter`` 30.72 MSPS
     - ``-G -r 7680``
     - f1536, 4 sps (49332 samples)
     - 623 (560)
     - 2 MB, 1516
   * - ``r3`` (shipped, sp3prod)
     - ``lvds_61p44_fdd_jupiter`` 61.44 MSPS
     - ``-G -r 15360``
     - f1536, 4 sps (49332 samples)
     - 1245 (1120)
     - 2 MB, 1516
   * - ``r4`` (sp4, f3072)
     - ``lvds_61p44_fdd_jupiter`` 61.44 MSPS
     - ``-G3 -r 30720``
     - f3072, 2 sps (49268 samples)
     - 1247 (1122)
     - 4 MB (``-DQPSK_CARVE_4MB``, ``DTB148``/``DTB146`` dtbs), 3044

``bringup_r2r3.sh r4`` refuses to arm unless each board's deployed daemon is the 4 MB build
and its live device tree reserves >= 4 MB; ``capture_r3.sh`` reads the rung back from the
running daemon (``RUNG=`` overrides), rebuilds the daemons for the rung's carve and records
``rung= ksym= sps= spf= frame= carve_mb=`` in ``meta.txt``. ``restore_known_good.sh`` is
``r3`` until the sp4 pair is gated (``RUNG=r4`` afterwards). The sp4 silicon gate is
``ops/gate3_pair.sh --tag sp4 --md5 5108cdb77aeb`` (flashes both boards; operator's go).

The 1.92 MSPS rung and the f1536 upgrade
-----------------------------------------

The original operating point was 1.92 MSPS SSI, 8 samples per symbol,
240 ksym/s. It is retired: the banked images are characterised on rung r3
only, and the legacy profile ``lvds_1p92_mhz`` survives solely because
``ops/link_test.sh``'s ``ber`` and ``tun`` subcommands still load it (its
``preflight`` is rung-independent and still the right readiness check).

The move to f1536 with interrupt-driven DMA was carried out board-by-board
in 2026-07 and its session record — the deploy runbook, the three
integration bugs found on hardware, the over-air deframe blocker and its
root cause — is preserved on tag ``archive/pre-cleanup-2026-09-09`` (the
retired deploy runbook and bring-up results pages). Nothing in
it is needed to bring the current stack up; the one piece that outlived the
session, the kernel command-line provenance, is in :doc:`build-and-flash`.
