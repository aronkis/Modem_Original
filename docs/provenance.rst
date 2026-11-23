Provenance
==========

Which image is on which board, what it carries, and the lineage that led there.
Identity is by BIST golden ``cap_out = 0x04922282`` and the gate stamps, not md5.

That last point is not pedantry. Vivado place-and-route and ``bootgen``
embed timestamps and non-deterministic placement, so three builds of the
*same* source produce three different md5s. The md5 prefix is how an
image is **named**; whether two images are equivalent is settled by the
gates being green and the on-chip BIST golden reading back correctly.

Current images
--------------

The deployment record is ``images/CURRENT.txt``, which
``ops/deploy_image.sh <ip> A|B`` reads directly — so the file is both
the documentation and the input to the flash tool. As of 2026-09-10 both
roles run **sp2 images** — rebuilt end to end from the pinned base tree
by ``modem/build_image.sh`` against the fix manifest
``modem/fixes/fixes.toml`` — and the two boards do not share one image:

.. list-table::
   :header-rows: 1
   :widths: 10 24 66

   * - Board
     - Image
     - Provenance and credited window
   * - 148 (role A)
     - ``BOOT.BIN.148.sp2A.3e7f4232a3b5``
     - md5 ``3e7f4232a3b5c8863bfa5187ad35068f``. Fix manifest
       ``modem/fixes/fixes.toml`` sha ``60f43ba3d5f8f871``, repo commit
       ``c14e7b11``; W1 witness + R4B ring-skip steering + byte-seam
       census + PAD. Modem-clock intra-clock post-route WNS
       **+0.447 ns** (TNS 0, 0 failing endpoints), **185,874**
       modem-clock endpoints. Flashed on 148 **2026-09-10** 17:59:48, readback-verified
       18:00:57 (``ops/flash/txfix_flash_20260910_175943.log``).
       Credited window::

         python3 ops/accept_analyze.py ops/r3cap/sp2pair_fwd/frames.bin
         sp2pair_fwd: live 605s/605s  PER=0.005% (39/734808)
           CP95UL=0.007%  lag33=-0.000

       — 600 s forward leg, 146 TX → 148 RX, both boards on their sp2
       image, ``wedge_verdict=healthy``. **Lost frames are counted in the
       denominator**: the metric is the host_seq gap over the live
       window, so the 734,808-slot span includes every slot that never
       arrived. On-board rollback: ``bf2a7305bbe0``
       (``/root/BOOT.BIN.bf2a7305bbe0.bak``).
   * - 146 (role B)
     - ``BOOT.BIN.146.sp2B.d94b4df391a1``
     - md5 ``d94b4df391a1e84f53426755f469fc7e``. Fix manifest
       ``modem/fixes/fixes.toml`` sha ``60f43ba3d5f8f871``, repo commit
       ``1ef3fa6b``; 148-lineage tree + W1 + R4D + R1. Modem-clock
       intra-clock post-route WNS **+0.785 ns** (TNS 0, 0 failing
       endpoints), **84,063** modem-clock endpoints. Flashed on 146
       **2026-09-10** ~18:43, readback-verified by the 146 flash
       rail's ``[3/6]``. Credited window::

         python3 ops/accept_analyze.py ops/r3cap/sp2pair_rev/frames.bin
         sp2pair_rev: live 616s/615s  PER=0.121% (908/747849)
           CP95UL=0.130%  lag33=0.004

       — 600 s reverse leg, 148 TX → 146 RX, both boards on their sp2
       image, ``wedge_verdict=healthy``, ``COMB_LINE=absent``. Same
       host_seq-gap metric, so **lost frames are counted in the
       denominator** of the 747,849-slot span. This leg passes the
       **documented arm (≤ 0.191 %), not the 2×-baseline arm
       (≤ 0.062 %)**: the same-day reverse baseline on the old pair was
       0.031 % (227/733,562), and 0.048 % (354/734,808) with sp2A
       transmitting into the old 146. The credited leg's loss-run
       histogram shifted versus that sp2A-into-old-146 leg
       (3-4-frame runs 26 → 191, of 182 → 434 runs total; largest run
       still 7 frames) — the reverse leg is carried forward as a
       **named watch item**, with the unmet 0.062 % arm as the target
       for the next measurement. The BIST golden was not taken for
       role B: it is defined only in 148's ROM/loopback arm state
       (``cap_out = 0x04922282``); on a live r3 link both boards read
       ``0x2674AF6A`` instead, because the golden is arm-state-defined
       and no call site names the arm
       (``docs/evidence/sp2/SP2_SILICON.md``, "Concerns (Task 11c)",
       concern 2), and the one attempt at a 146-native mode-1 loopback
       arm hung the board
       (``docs/evidence/sp2/SP2_SILICON.md``, "Concerns (Task 11c)",
       concern 1) — the credited window and the health gate above
       stand in for it. The
       superseded on-board rollback ``9acbe2ebe1db``
       (``/root/BOOT.BIN.9acbe2ebe1db.bak``) survives only as that
       banked binary: it cannot be rebuilt from this tree, since its
       swapped R4D fix order is rejected by ``modem/fixes/rxfix_kit.sh``
       by design (its R4D verification block fails a build on the
       pre-Task-33 swapped index) and the kit reader —
       ``ms_r4d_order()`` in ``host/modem_status/ms_regmap.c`` — is
       md5-keyed.

The WNS numbers above are the intra-clock post-route rows for
``axi_adrv9001_adc_1_clk`` — the only rows the drift gate reads. The
endpoint totals differ from the as-built reference kits (186,471 and
84,673) because the sp2 builds are fresh synthesis runs from
byte-identical RTL; the silicon gate above is what clears that.

Both boards run the same radio profile — ``lvds_61p44_fdd_jupiter``
(61.44 MSPS FDD LVDS DDR, 40 MHz bandwidth, 4 samples/symbol →
15.36 Msym/s, fabric clock 122.88 MHz), armed by ``ops/bringup_r2r3.sh
r3`` and verifiable by reading back
``in_voltage0_sampling_frequency = 61440000``. The boot set is three
files per board, not one: the ``BOOT.BIN`` above, the banked kernel
``Image.6.12.77-uio.a1ba00b51431`` and the per-board qpsk device tree —
deploy the kernel and dtb **before** the image on a fresh board
(:doc:`setup-prebuilt` Step 0). The host daemon is rebuilt from
``host/`` HEAD on every capture leg.

The two receiver fixes assume **opposite** sample-rate-offset signs, so
the A/B role assignment is not interchangeable on a fresh pair — see
:doc:`bringup`. The credited numbers, with their sample counts and the
lost-frame convention, are in :doc:`performance`.

2026-09-10: operator kit relocated to ``ops/``; bring-up and health gate
re-run on both boards, fsync/wcnt 1262 (148) and 1268 (146), clean 12/12
each, no flash (commands in the hygiene plan Task 13).

2026-09-10 22:30: ``CURRENT.txt`` cut over to the sp2 pair after the
credited windows above. The previous pair (``bf2a7305bbe0`` on 148,
``9acbe2ebe1db`` on 146) stays banked in ``images/`` and on each board as
``/root/BOOT.BIN.<md5>.bak``; nothing was deleted. The earlier role-A
numbers (forward 0.005 %, 35/728,581; reverse 0.048 %, 354/734,808 —
2026-09-10 18:20 and 18:36) were taken with 148 on sp2A against 146 on
the **old** ``9acbe2ebe1db`` image, so they evidence role A only; the
table above is the first window taken with both boards on sp2.

Candidates (not deployed)
--------------------------

sp3 — the runtime-select single-image chain (cleanup sub-project 3,
2026-09-11 model-back-port / SRO-select). Built and Gate-2 clean; the
Gate 3 silicon trial **FAILED** on the transmitter side, so no cut-over
happened and this section stays here rather than in "Current images".
``images/CURRENT.txt`` and the sp2 rows above are unchanged.

.. list-table::
   :header-rows: 1
   :widths: 12 22 66

   * - Image
     - Provenance
     - Result
   * - ``images/BOOT.BIN.jupiter.sp3.c5ec53bc610c5eff837a62b439466660``
       (at the time also reachable as ``BOOT.BIN.148.sp3.c5ec53bc610c`` /
       ``BOOT.BIN.146.sp3.c5ec53bc610c``; the bank carries no such
       aliases since 2026-09-17 -- the rails resolve a 12-hex md5
       through ``images/MD5SUMS``)
     - Model tree: Task 9's Gate 1 tree, ``MODEL_TREE_SHA
       e615c4a49009eed348b0790951515ab6b11237fade7a761537c4c6f33f629bba``
       (sha256 over the 172 gate ``.v`` files,
       ``docs/evidence/sp3/GATE1_EQUIVALENCE.md``), and Task 11/13's
       build tree, ``model_tree_sha 144c89e8fe98317d`` (the ``STAMP.hdl``
       / ``STAMP.vivado`` sha256-over-generated-``.v`` digest,
       ``docs/evidence/sp3/GATE2_TIMING.md``). **These two shas differ
       only in ``TxRxCompo_ip.v``'s ``ip_timestamp`` constant** — a
       HDL-Coder build-wall-clock stamp, not logic — so the gated tree
       and the synthesised tree are the same design
       (``docs/evidence/sp3/SP3_SILICON.md`` section 1,
       ``docs/evidence/sp3/TXFIX_F3_GATE.md`` section 5.3). Repo git:
       ``df674056`` (Gate 1 regen) / ``ba4e056c`` (hdl stage) /
       ``9eeb0651`` (vivado stage). Modem-clock intra-clock post-route
       **WNS +0.785 ns**, TNS 0.000, 0 failing endpoints of 85,948
       (``BUILD_IMAGE_WNS_OK wns=0.785 floor=0.005 ref_pad=0.105
       ref_sp2A=0.447 ref_sp2B=0.785``). Flash times: 148 attempt 1
       rolled back 06:31:19–06:36:43 on the capTAP golden (see the
       GOLD=1 note below); 148 attempt 2 ``ops/flash/txfix_flash_
       20260912_063813.log``, 06:38:13 → 06:42:29, ``FLASH_DDRCAP2_OK``;
       146 ``ops/flash/flash_146_txfix.sh`` (146 rail log, unit
       ``t13-flash146.service``), 07:03:23 → 07:11:14,
       ``FLASH_146T_DONE``. Rollback: 146 → sp2B 07:55:33 → 08:01:51,
       148 → sp2A 08:02:56 → 08:07:12 (``ops/flash/txfix_flash_
       20260912_080255.log``), both green, ordered 146-first (removes
       the sp3 transmitter feeding 148).
     - **GATE 3 FAILED — NOT DEPLOYED.** Forward window (146 on **sp2B**,
       148 on sp3, the only path without an sp3 transmitter): ``python3
       ops/accept_analyze.py ops/r3cap/sp3_fwd_20260912_064628/frames.bin``
       → ``live 607s/610s PER=0.003% (22/736509) CP95UL=0.005%``, lost
       frames counted in the denominator, ``mid_recover=0``. Every path
       with an **sp3 transmitter** wedged instead: three consecutive
       reverse legs (148 TX → 146 RX) at 18 s, 34 s and 61 s wall — legs
       1–2 with 146 ``sro_sign=1``, leg 3 a controlled A/B with
       ``sro_sign=0``, which wedged too and exonerates the bit as the
       cause; then the forward leg itself once the sentinel resumed
       watching it, ``07:44:43 rate=219/s crc=40.6%`` → ``07:49:47 WEDGE
       detected (rate=0/s)``. GOLD: 148's mode-1 arm gate reads ``0x20C``
       (not ``0x144``, which is unchanged from sp2); its golden for this
       image is **``GOLD=1``**, passed explicitly to
       ``ops/flash/flash_148_txfix.sh`` — the default ``GOLD=BCF94856``
       rolled attempt 1 back on a false-negative mismatch. Full record,
       verbatim rail/capture logs and the open suspects for the sp3
       transmitter defect: ``docs/evidence/sp3/SP3_SILICON.md``.

Lineage
-------

The images above descend from a long build lineage. Two fixes from
early in it are carried by every image since and are worth naming
because their symptoms still appear in old logs:

.. list-table::
   :header-rows: 1
   :widths: 22 34 44

   * - Fix
     - Locus
     - Effect on the live link
   * - CFO reset-storm fix ("rxfix")
     - ``modem/common/model/commhdlQPSKTxRxParameters.m`` —
       ``CFOChangeDetectThreshold`` 0.0015625 → 0.0125
     - ``rstcs`` 52/s → 0; frame yield 40 % → 93.5 %
   * - Phase-ambiguity resolver
     - ``resolver_lookback_fix``, git ``8033363``, applied by the
       assemble script
     - The byte plane carries **arbitrary** payloads (99.9 % on
       hardware), not only the golden BIST vector

The 2026-07 lineage below is **history, not deployment**. Its build
trees (``jupiter_byte_*_build/``) were never tracked and exist only on
the build host; the images themselves are either superseded or banked in
``images/``. Full per-build entries, including the forensic notes that
have been abridged here, are in the retired provenance page, preserved
on tag ``archive/pre-cleanup-2026-09-09``.

.. list-table::
   :header-rows: 1
   :widths: 16 22 62

   * - md5
     - Kit / build dir
     - What it was, and where it went
   * - ``dcf5c5fb29e6``
     - ``jupiter_byte_lean_build``
     - **The 2026-07-20 shipped image.** A LEAN debug-strip of P1E-v3:
       instrumentation removed (``QPSK_LEAN=1``; state-pairs
       0x160–0x16C stripped) to restore ZU3EG timing margin while
       keeping every fix — rxfix, resolver, pifix, byte RX FIFO, the
       P1E-v3 tick compensation, the dual-DMA tap, P1D telemetry.
       Deployed to both boards; rollback held v3 ``0de4d5cb``.
       Superseded by the current pair.
   * - ``0de4d5cba0af``
     - ``jupiter_byte_p1e2_build``
     - v3 tick compensation (accumulator-position arm qualifier) + P1D
       telemetry + dual-DMA tap. Deployed 2026-07-19, retained as the
       ``prelean`` rollback.
   * - ``d06f67410d4d``
     - ``jupiter_byte_telemetry_build``
     - T8.7 state telemetry (mux mode 4 = 24-slot state broadcast) and
       mode 5 = CFC output tap. Flashed both boards 2026-07-14.
   * - ``58429a449cf9``
     - ``jupiter_byte_t863_build``
     - T8.6.3 canary2: path canary, interpolation-control shadow with
       the leading-beat compensation, carrier loop-filter shadow. First
       build on which all seven canary registers read zero post-lock —
       every instrument truthful for the first time.
   * - ``a34233c5a3c2``
     - ``jupiter_byte_ch2hard_build``
     - Channel-2 retarget plus hardening and the dual-DMA tap. Held in
       reserve: the RX2 SSI path died on **both** boards during its
       test window, and the morning-golden configuration failed
       identically, which exonerates the image.
   * - ``a498d76d7428``
     - ``jupiter_byte_canary_build``
     - T8.5 canary instrumentation (shadow timing loop, divergence
       counters, strobe forensic) at 0x170–0x188. Its flat-zero
       divergence counters rejected the random-register-corruption
       model.
   * - ``6ed649badc9e``
     - ``jupiter_byte_hard_build``
     - T8.4 timing-loop anti-wedge hardening (interpolation delta clamp,
       integrator clamp, DTC saturate) — the class-4 acquisition-wedge
       fix.
   * - ``6b1b4409017d``
     - ``jupiter_byte_tap_build``
     - The dual-DMA tap that made the ``0x10C`` mux stream reachable
       from the host, by riding the second RX DMA.
   * - ``d32475cb1f42``
     - ``jupiter_byte_ch2tap_build``
     - The channel-2 variant. A/B'd against channel 1 on 2026-07-12;
       channel 1 was adopted.
   * - ``5c85af2cf62d``
     - ``jupiter_byte_pifix_build``
     - **pifix**: demodulator decision boundary returned to the 45° grid
       (it had been skewed 30.68°, the source of a 2–3e-3 floor) and the
       carrier-sync loop gains returned to design.
   * - ``8d6b82ff597e``
     - ``jupiter_byte_rxfix_build``
     - K5 byte modem + rxfix + resolver — but still carrying the
       poisoned demod/CS constants pifix later corrected.
   * - ``447caa20736a``
     - ``jupiter_byte_build``
     - K5 byte modem, pre-rxfix. The image that floored on 148.
   * - ``f351ad874b74``
     - ``jupiter_byte_verify_build``
     - A standalone rebuild of the rxfix source, never deployed. It is
       the reproducibility evidence: a different md5, all gates PASS,
       BIST golden — which is why identity in this project is by
       function, not by hash.

Gate evidence
-------------

Each build gate drops a stamp file, and those stamps in ``modem/`` are
the "green build" evidence a flash decision rests on:
``SIM_BYTE_GATE_K5.txt`` (the model oracle), ``CHECKHDL_240K5_BYTE.txt``
(checkhdl + makehdl), ``S1_GATE.txt`` (the ROM path under iverilog,
per-frame ``cap_out=04922282``) and ``S1B_GATE.txt`` (the byte netlist
under Verilator, rot0 and rot17). The recorded netlist provenance for
the campaign generations is ``docs/evidence/NETLIST_PROVENANCE.md``.

For an image *already on a board*, the check is the same golden by a
different route: arm the ROM source and read ``cap_out`` at 0x144. That
is why the BIST golden, not the md5, is the identity of record — an
image whose md5 you cannot reproduce still proves itself on silicon in
one read. What the gates do **not** cover, and never have, is anything
downstream of the IP pin: the block design, the S2MM egress and the host
are exercised only on hardware.

Those gates in turn depend on off-repo inputs — the pristine RTL
lineage tarball, the banked base tree's ``BASE_MANIFEST.txt``, and the
SRO sim stimulus/scorer tree — that cannot themselves be git-tracked
and so cannot be checked by ``git diff``. ``modem/gates/bank.sha256``
pins all three by sha256 and ``modem/fixes/base_tree.sh verify-bank``
recomputes and compares them, printing ``BANK_OK`` or
``BANK_MISMATCH``; ``build_image.sh``'s ``base`` stage and
``run_gates.sh`` both run it before touching the bank, so a corrupted
or silently-edited off-repo input is caught before it can produce a
"green" gate over the wrong stimulus. See :doc:`build-and-flash` for
the mechanics.
