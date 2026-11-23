Build & flash flow
==================

You are reading this because you are about to build an FPGA image, or —
more consequentially — flash one to a board. This page describes the
pipeline from the Simulink model to a banked BOOT.BIN, the image-bank
discipline, and the safety rails around flashing. The rails exist
because each one was paid for; do not improvise around them.

.. raw:: html
   :file: _static/images/build-flash-pipeline.svg

A longer companion page, `build-flow.html <_static/build-flow.html>`_,
walks the same pipeline stage by stage: the Simulink overlay stack, every
edit made to the generated HDL before synthesis, the two Vivado sessions,
and a table of every tool in the chain besides Simulink, MATLAB and Vivado.

The two model trees: ``modem/dev`` and ``modem/prod``
-----------------------------------------------------

Since 2026-09-15 the model lives in two trees under ``modem/``. ``dev/`` is the
overlay-driven source: ``commhdlQPSKTxRx.slx`` plus ``assemble_jupiter_240k5_byte.m``
and every overlay, which every build replays to produce the DUT. ``prod/`` is
the flattened, cleaned model committed as a binary: every overlay applied, the
register ports prefixed ``reg_`` and numbered, subsystems laid out, the debug
outputs on the delete-list removed, a simulation harness at the root. ``prod``
is *derived* from ``dev`` by ``modem/prod/derive/derive.sh`` and never
hand-maintained; ``modem/prod/DERIVATION.txt`` records what changed
structurally on each derivation.

Each tree becomes a complete kit root when ``modem/common/tools/make_kit.sh``
copies it together with the shared ``modem/common/`` files (the repo carries no
symlinks). ``build_hdl.sh --tree dev|prod`` selects the
tree (``dev`` is the default and remains the shipped chain until ``prod`` has
passed Gates 1-3).

Which chain actually built the deployed images
-----------------------------------------------

Be honest about this before reading further: **the images now on the
boards are the sp2 role pair**, built on 2026-09-10 by
``modem/build_image.sh --role A|B`` *as that script existed then*
(repo git ``c14e7b11`` for role A, ``1ef3fa6b`` for role B) — stages
``base fixes gates vivado``, driven by ``modem/fixes/fixes.toml``
(manifest sha ``60f43ba3d5f8f871``). Their lineage before that is the
pre-cleanup campaign kit chain (per-lineage ``run_*_build.sh`` scripts
driving the ``txfix_build.*.tmpl`` templates), recoverable from tag
``archive/pre-cleanup-2026-09-09``.

**That entry point no longer exists in that form.** Cleanup
sub-project 3 rewrote ``modem/build_image.sh`` into the sp3
*single-image* flow (stages ``hdl gates vivado``, no ``--role``, no fix
chain), so the command recorded in ``images/CURRENT.txt`` and
``images/README.md`` is provenance, not a recipe you can re-run today.
To rebuild an sp2 role image now, drive the netlist fix chain by hand::

   modem/fixes/base_tree.sh fetch <parent>
   python3 modem/fixes/apply_fixes.py --manifest modem/fixes/fixes.toml \
           --role A|B --kit-tag sp2 \
           --base <parent>/jupiter_byte_ddrcap2_build --work <work>
   modem/gates/run_gates.sh --role A|B
   IMPL_STRATEGY=explore REMOTE_BASE=/mnt/disk2/scratch/qpsk-builds \
           <work>/jupiter_byte_rxfixpadsp2_build/build_txfix.sh

(the last kit basename is ``jupiter_byte_rxfixr4dr1sp2_build`` for role
B; ``apply_fixes.py --plan`` prints the exact chain, including that
name, without touching disk). A build reproduced this way is a
*functionally equivalent* image, not a byte-identical one — equivalence
is established by the gates plus the BIST golden, never by md5 (see
below).

``modem/legacy_builds/build_lean_image.sh`` is the model-to-netlist step of that
chain: it runs the ``QPSK_LEAN=1`` gate suite and the HDL Coder
workflow. It is not, by itself, the recipe that produced any image in
``images/``.

**Status (2026-09-12): the sp3 single-image chain exists and is BANKED,
NOT DEPLOYED.** The ``hdl``/``gates``/``vivado`` stages below describe a
real, working chain — Task 9's Gate 1 passed the full sim equivalence
matrix on one model tree at both ``sro_sign`` settings
(``docs/evidence/sp3/GATE1_EQUIVALENCE.md``), and Task 13's Gate 2 closed
timing at ``wns=+0.785 ns`` against the ``0.005`` floor
(``docs/evidence/sp3/GATE2_TIMING.md``). But the Gate 3 silicon trial
**FAILED**: the built image (``images/BOOT.BIN.jupiter.sp3.c5ec53bc610c…``)
flashed and gated green on both boards, and the one forward window run
with an **sp2** transmitter passed at 0.003 % (22/736,509) — but every
path driven by an **sp3** transmitter wedged, in both directions, at both
``sro_sign`` settings (``docs/evidence/sp3/SP3_SILICON.md``, the full
record). Both boards were rolled back under the rails; the rig runs the
sp2 pair. The sp2 role images therefore remain shipped, and the
``modem/fixes/`` netlist-injection chain that (re)builds them is
retained for exactly that reason — Task 15 (deleting it) is cancelled.
Because ``build_image.sh`` is now the sp3 flow, that chain is driven by
hand (``base_tree.sh fetch`` → ``apply_fixes.py --role A|B --kit-tag
sp2`` → the kit's ``build_txfix.sh``, spelled out above), not by
``build_image.sh --role``.
The sp3 model-overlay chain (``modem/dev/simulink/rxfix/``, ``modem/build_hdl.sh``,
``modem/build_image.sh``, ``modem/gates/``, ``modem/vivado/``,
``modem/instruments/seqbist/``) stays in the tree as the candidate flow
for the next iteration, which has to chase the sp3 transmitter-side
defect — see ``modem/dev/simulink/rxfix/README.md`` and ``SP3_SILICON.md`` section 15
for the open suspects and the discriminating rebuild
(``QPSK_TXFIX=``/without the SEQ-BIST stage, 146-only, forward window).

The three build stages
----------------------

``modem/build_image.sh`` runs three stages in order — ``hdl gates
vivado`` — each writing ``<work>/STAMP.<stage>`` (``stage=<s> tag=<t>
model_tree_sha=<16hex> git=<sha> when=<iso> result=<line>``).
``--from <STAGE>`` starts partway through and refuses to run unless the
preceding stage is stamped at the **same** ``model_tree_sha``, so a
stale kit can never reach Vivado.

There is **no** ``--role`` any more, and no fix chain. sp2 built a role
A image (148: W1 R4B BS PAD) and a role B image (146: W1 R4D R1) by
applying netlist fixes to a banked base tree, driven by
``modem/fixes/fixes.toml``. Those fixes are now **model overlays**
(``modem/dev/simulink/rxfix/``, assemble phase 2.21), so one regeneration produces
one image carrying all of them, for both boards. ``--role`` therefore
exits 2 with ``BUILD_IMAGE_NO_ROLE`` rather than silently handing over
the single image: a caller still passing it believes in two. The
banked base tree is no longer an input to anything. The fixctl control
bits and witness register map remain a separate manifest,
``modem/regmap/regmap.toml``; ``modem/regmap/gen_regmap.py``
regenerates the host-side register headers from it (see
:doc:`byte-plane`).

``model_tree_sha`` replaces sp2's ``manifest_sha``: it is sha256 over
the sorted list of generated ``.v`` files in the regenerated kit. It
does not exist until ``hdl`` has run, so it is computed lazily from the
tree on disk; the environment variable ``MODEL_TREE_SHA`` overrides it,
which is what makes ``--dry`` and the shell tests runnable without a
one-hour regeneration.

* **hdl** — ``modem/build_hdl.sh <regen-parent> --kit-name
  jupiter_byte_<tag>_build --complete-bd``. The MATLAB regeneration
  (``QPSK_LEAN``/``BEATFIX``/``BEATOBS``/``FRAMESTAT``/``RXFIX``/``TXFIX``
  at the ``f1536`` ``sps=4`` rung), the rxfifo/txcap/ddrcap/ddrcap-v2
  instrument injections, then the **block-design completion** and the
  two BD instruments in one local Vivado session, then kit assembly.
  Stamp: ``STAMP.hdl``. Gates: ``BUILD_HDL_BD_OK``,
  ``BUILD_HDL_KIT_OK``, ``MODEL_OVERLAYS_OK``, each of which must
  appear in ``<work>/hdl.log``.

  The BD completion is the part that had been missing. HDL Coder's
  Create Project task fails on this kit (the insert-path bug), so a
  fresh regeneration leaves ``system.bd`` with the byte reference
  design but **no** ``TxRxCompo_ip_0`` cell — the modem DUT is not in
  the block design at all. ``modem/common/bd/complete_byte_t8.tcl`` is what adds
  it, and ``legacy_builds/build_byte_image.sh`` step 4 has run that file for every
  byte image ever built; the regeneration recipe stopped short of it,
  which is why ``ddrcap_bd.tcl`` aborted on every regen with
  "``TxRxCompo_ip_0`` missing pins" and was tolerated as a warning. Its
  BD half is now split out verbatim as ``modem/common/bd/complete_byte_bd.tcl``
  (lines 1–137, no synth; ``complete_byte_t8.tcl`` itself is unchanged
  for the legacy flow) and sourced here, followed by
  ``modem/instruments/ddrcap/ddrcap_bd.tcl`` (now a **hard** gate) and
  ``modem/instruments/seqbist/seqbist_bd.tcl``. All three edit the same
  open block design, in that order, in one session.

  Kit assembly then installs ``modem/vivado/txfix_build.{sh,tcl}.tmpl``
  and a ``TXFIX_VARIANT`` marker into the tree, so the tree **is** a
  build kit named ``jupiter_byte_<tag>_build`` and the ``vivado`` stage
  runs the template unchanged. Before that, the stage asserts that
  ``vivado_prj.xpr`` carries no absolute source paths: those would not
  resolve on the Vivado host after the rsync, and the failure would
  surface two hours into the build.

  Invoked with only a destination parent — the way concurrent
  regeneration tasks call it — ``build_hdl.sh`` behaves exactly as the
  old ``modem/build_hdl.sh`` did, including the
  ``BASE_RTL_EQUIV`` diff against the banked tree. That diff is now
  optional evidence (``--diff-bank DIR``), off once ``--kit-name`` or
  ``--complete-bd`` is given.
* **gates** — ``modem/rtl_sim/make_sro_trees.sh --from-regen <kit>``
  builds the model gate tree ``s1_rtl_model`` and its wrappers out of
  the kit's ``hdlsrc``; ``modem/rtl_sim/tree_marker.sh`` must then read
  ``model`` (not ``injector``) for every one of W1, R4B, R4DR1, BS, PAD
  and F3, or the stage aborts with
  ``BUILD_IMAGE_TREE_MARKER_FAIL``; then
  ``modem/gates/run_gates.sh --legs modem/gates/model_matrix.legs``.
  Stamp: ``STAMP.gates`` (``GATES_DONE ... fail=0``). As in sp2, an
  explicit ``--from vivado`` skips this stage and prints
  ``BUILD_IMAGE_WARN ... building UNGATED`` rather than refusing.
* **vivado** — ``<kit>/build_txfix.sh`` on ``hdl-dev-2``. Stamp:
  ``STAMP.vivado`` (``md5=<hash> modem_wns=<f> remote_base=<dir>``).
  Gate 2: the post-route timing report for
  ``axi_adrv9001_adc_1_clk`` must clear an **absolute** floor of
  ``wns >= 0.005`` (``modem/gates/modem_wns.py --min``). This is a
  single floor, not sp2's per-role drift check against
  ``reference_modem_wns_ns`` — that manifest is gone. The three earlier
  numbers survive only as reference points printed beside the
  measurement: ``BUILD_IMAGE_WNS_OK wns=<f> floor=0.005 ref_pad=0.105
  ref_sp2A=0.447 ref_sp2B=0.785``. Below the floor is a **stop**, not a
  prompt to try another implementation strategy: it is recorded in
  ``docs/evidence/sp3/GATE2_TIMING.md`` and the runtime select is
  dropped, leaving sp2 shipped.

  The number Gate 2 reads is *not* the ``wns=`` field in the build's
  own ``TXFIX_BUILD_DONE`` line — that is ``timing_gate.tcl``'s
  pre-implementation estimate. Gate 2 reads the fetched ``impl_1``
  timing summary, intra-clock post-route row.

The image lands as ``<work>/BOOT.BIN.jupiter.<tag>.<md5:0:12>`` and is
banked as ``images/BOOT.BIN.jupiter.<tag>.<md5>``.

Remote build host facts, gathered in one place: the Vivado host is
``hdl-dev-2``; ``--remote-base /mnt/disk2/scratch/qpsk-builds`` points
the remote build tree at the host's second disk (136 GB free) instead
of the default ``~/qpsk-builds`` on ``/`` (~45 GB free, and where the
AS-BUILT reference kits are snapshotted as ``*_build_ref``). The
build template now refuses a ``*_build_ref`` kit name outright
(``TXFIX_BUILD_REFUSE_REF_KIT``) — it rsyncs ``--delete`` into its kit
directory, so the refusal is unconditional rather than a matter of
choosing a distinct tag. ``--dry`` stops the ``vivado`` stage at the
remote launch command and forces rsync to ``-n`` via a ``PATH`` shim
(older ``build_txfix.sh`` template instantiations run ``rsync -a
--delete`` *above* their own ``--dry`` gate). The flash rails that
write a built image to a board live under ``ops/flash/``
(``flash_148_txfix.sh``, ``flash_146_txfix.sh`` and the go-scripts
around them).

Off-repo inputs
---------------

The build chain depends on inputs that cannot live in git. On the
build workstation they are two banks: the base bank (``BASE_BANK``,
default ``/mnt/onetb/scratch/qpsk-build-trees/base``, holding the
fetched base tree plus its ``BASE_MANIFEST.txt``) and the SRO sim bank
(``SRO_SIM_DIR``, default ``/mnt/onetb/scratch/qpsk-build-trees/sro_sim``,
the stimulus/scorer tree ``run_gates.sh`` reads), beside the pristine
RTL lineage tarball ``s1_rtl_pristine.tar.gz`` in the same parent
directory. On the Vivado host ``hdl-dev-2`` they are the AS-BUILT
reference kits ``~/qpsk-builds/*_build_ref`` and the
``/mnt/disk2/scratch/qpsk-builds`` build area named above. Three of
these are pinned by sha256 in ``modem/gates/bank.sha256``: the
tarball, ``BASE_MANIFEST.txt``, and a per-file content digest over the
SRO sim tree. Because the ``gates`` stage reads both banks, it is
reachable only on a host that holds them; a fresh checkout elsewhere
can run ``hdl`` and ``vivado`` but not ``gates``. ``modem/fixes/base_tree.sh
verify-bank`` recomputes all three and compares against the pin file
(override with ``BANK_SHA256_FILE``); it prints ``BANK_OK`` or
``BANK_MISMATCH`` and is run automatically by the ``base`` stage above
and by ``run_gates.sh`` before Stage 4. A stray process that touches
``sro_sim/`` (even a python run that only leaves a
``__pycache__/*.pyc`` behind) trips ``BANK_MISMATCH`` on the listing
line — that is a deliberate re-pin trigger, not a bug; recompute with
the recipe in ``bank.sha256``'s header comment and update the line on
purpose, the same way a base tree re-fetch gets a deliberate re-pin in
``fixes.toml``.

The build host
--------------

.. list-table::
   :header-rows: 1
   :widths: 34 66

   * - Need
     - Value on the build host used
   * - MATLAB (HDL Coder + Simulink)
     - R2025b
   * - Vivado
     - 2025.1
   * - Verilator / iverilog
     - on ``PATH`` — the S1B and S1 netlist gates
   * - ADI byte reference design
     - the TransceiverToolbox Jupiter plugin "JUPITER (RX & TX, BYTE
       DMA)" — a **read-only donor**, never edited
   * - Device target
     - Zynq UltraScale+ ``xczu3eg-sfva625-2-e``

Do not set ``ADI_PERF_TIMING``: Jupiter closes at about +2 ns without it
and the performance directives cost roughly 20 minutes per run for
nothing.

Model → netlist
---------------

The modem source of truth is the Simulink model
``commhdlQPSKTxRxLoopback`` plus a stack of env-gated overlay scripts
applied by ``assemble_jupiter_240k5_byte.m`` (frame geometry, LEAN
stripping, framestat, loop-gain AXI threading, witness counters …).
The environment at assemble time therefore *is* the image
configuration — e.g. the proven instrument lineage is
``QPSK_LEAN=1 QPSK_FRAME=f1536 QPSK_SPS=4 QPSK_FRAMESTAT=1``.

One structural caveat that generates recurring false alarms
(``docs/evidence/SLX_RECONCILE.md``): the ``.slx`` files are **mutable
as-built artifacts, not sources** — every assemble re-saves the model
in place. A "dirty" ``.slx`` after a build is expected; the reconcile
procedure is to XML-diff the extracted model against HEAD before
trusting or reverting anything.

HDL Coder then emits the netlist, which is gated *before* Vivado. The
pre-synthesis suite is six stages, each dropping a stamp file that is
the "green build" evidence:

.. list-table::
   :header-rows: 1
   :widths: 8 46 46

   * - #
     - Stage
     - Stamp / marker
   * - 1
     - Assemble the composite from the overlays
     - the assemble script's own pre-synth structural gates
   * - 2
     - Model-level byte oracle — four runs: aligned golden, rotated word
       phase, alternate-PN pad, and ROM source
     - ``SIM_BYTE_GATE_K5.txt`` (``result: PASS``)
   * - 3
     - ``checkhdl`` + ``makehdl``
     - ``CHECKHDL_240K5_BYTE.txt``
   * - 4
     - Golden byte vectors
     - ``tx_words_golden.hex``
   * - 5
     - S1B byte netlist under Verilator (rot0 + rot17)
     - ``S1B_GATE.txt`` (``result: PASS``)
   * - 6
     - S1 ROM path under iverilog
     - ``S1_GATE.txt`` (``result: PASS``)

The oracles are the real safety net, and stage 2's alternate-PN run is
the load-bearing one: it proves the air comes from the **in-fabric
encoder fed by the host bytes** rather than from a stuck ROM. Stages 5
and 6 re-prove that the generated *netlist*, not merely the model,
reproduces the golden air stream bit-exactly. Note that stage 1
re-assembles the ``.slx`` in place, so ``git status`` will show the
model and the refreshed stamps as modified after any build — stage a
targeted ``git add``, never a blanket one.

Two cautions about that suite, both paid for:

* **S1B has a coverage hole.** It is a self-consistent TX→RX BIST
  simulation on a clean synthetic signal, so it does not catch real-IQ
  regressions. A green S1B is necessary, not sufficient.
* **Real-IQ replay gate** — Verilator replay of a pinned captured-air
  chunk, scored by CRC. The critical contract
  (``docs/evidence/HARNESS_AB.md``): the **drive cadence is a property of
  the netlist generation** — the Jul-25 netlist consumes one ADC
  sample per 4 DUT clocks (CAD=4); post-Jul-29 generations consume one
  per 2 (CAD=2). Driving a netlist at the wrong cadence produces a
  catastrophic-looking false failure (5/78 packets) that once
  red-gated two perfectly good images.

Vivado → BOOT.BIN
-----------------

The image-side scripts in ``modem/legacy_builds/`` (``build_cyclic_image.sh`` and its
siblings, with ``QPSK_BUILD_DIR`` for a fresh build directory) drive the
TransceiverToolbox Vivado project: the netlist lands in the
reference-design block design, ``matlab_processors.tcl`` instantiates
the byte DMAs (see :doc:`byte-plane`), and the run ends in
``boot/BOOT.BIN``.

Two structural facts about that run are worth carrying in your head.
First, **the HDL Coder IP-core workflow fails by design at its "Create
Project" task** — an ADI ``add_ip`` insert-path bug — and the Vivado
completion Tcl (``modem/common/bd/complete_byte_t8.tcl``) finishes the project
instead: it inserts the packaged IP, wires the nine byte DUT ↔ breakout
pins, keeps the stock DAC wiring, validates the block design, and runs
synthesis, implementation, ``write_bitstream`` and ``bootgen``. A
MATLAB error at Create Project is expected and benign; the build guards
on the real artifacts (the ``.xpr`` exists, the packaged IP zip exists,
and the block design contains ``byte_breakout`` — its absence means the
wrong reference design was applied). Second, **there is no XSA/HDF
export**: ``bootgen`` packages the PS boot chain (FSBL, PMU firmware,
ATF, U-Boot) with the PL bitstream straight from the Vivado project.

Post-implementation gates: timing (WNS/WHS clean),
``static_rate_parity_gate`` against the known-good image (timing
controller, rails, per-port, BD parity), and — since the witness
forensic — the DCP rail check below.

The synthesis rail-re-hosting hazard
------------------------------------

The most subtle build hazard found so far
(``docs/evidence/HANDOFF_20260813.md``, the 02:45–03:15 forensic): in two
independent *witness builds* (images extended with the 0x1C4/0x1C8
witness counters), Vivado synthesis **re-hosted the modem's
rail-generation and byte-plane enable logic out of the DUT into the
AXI-Lite address-decoder hierarchy** — the exact module the witness
overlay extended. Every netlist/BD/timing/clock diff was clean, yet
both images deterministically ran the byte plane at ~46 % of line rate
on silicon. The trigger: the witness logic bridged byte-plane signals
into the address decoder's readback, and cross-hierarchy resource
sharing then elected addr-decoder copies as the canonical hosts for
shared enable LUTs design-wide.

Mitigation (specified, pending validation by the wit4 build, which is
**still unbuilt** as of 2026-08-15): pin the implementation structure
with ``KEEP_HIERARCHY``/``DONT_TOUCH`` on ``u_TxRxComposite_tc`` and the
addr-decoder instances, and gate every future build with
``ops/dcp_rail_dump.tcl`` — assert the tc-cell census matches the
known-good image and that the ``enb_1_2_0`` driver lives under
``u_TxRxComposite_tc``. The DCP rail-census gate is now standard on
every build and has caught real recipe artifacts.

**Do not extrapolate this forensic to the forward loss class.** It was
tested directly at that altitude on 2026-08-15 and refuted: a
glitch-path probe on the shipping image's own routed DCP found every
BUFGCE CE pin tied to VCC with zero pulse-width violators, all 129 DUT
modules clock only on ``posedge clk``, and a ``GATED_CLOCK_CONVERSION``
build came out bit-identical in WNS and rail census. The rail-rehosting
mechanism remains the named explanation for the *witness builds'*
half-rate behaviour only — see :doc:`current-state`.

Kernel provenance: how the UIO bind is delivered
------------------------------------------------

The banked kernel ``Image.6.12.77-uio.a1ba00b51431`` is not stock, and the
reason is worth knowing before anyone rebuilds it.
``CONFIG_UIO_PDRV_GENIRQ=y`` is **built in**, so ``modprobe.d`` and
``modules-load.d`` are ignored — ``generic-uio`` binds only if the kernel
command line carries ``uio_pdrv_genirq.of_id=generic-uio``. On these boards
the effective ``/proc/cmdline`` comes from **U-Boot's compiled default
environment**: the on-disk device tree's ``/chosen/bootargs`` is rewritten by
U-Boot at ``bootm``, ``uEnv.txt`` is not consulted, and the persistent U-Boot
environment in ``/dev/mtd1`` is invalid, so U-Boot falls back to its built-in
default. Both of the obvious delivery mechanisms are therefore dead.

The option is instead **compiled into the kernel** and appended to whatever
the bootloader passes, via ``CONFIG_CMDLINE`` + ``CONFIG_CMDLINE_EXTEND``
(the append is done by the generic ``drivers/of/fdt.c``
``early_init_dt_scan_chosen``). This survives a BOOT.BIN swap and is
independent of uEnv, mtd and ``/chosen``, which is why the deploy script does
not touch ``uEnv.txt``.

One arm64 caveat: this xlnx 6.12 tree's ``arch/arm64/Kconfig`` exposes only
``CMDLINE_FROM_BOOTLOADER`` and ``CMDLINE_FORCE`` — no ``CMDLINE_EXTEND``
menu entry, although the backing code exists regardless. A three-line Kconfig
delta adds it, saved as
``modem/boot/kernel-arm64-cmdline-extend.patch``. ``CMDLINE_FORCE`` was
rejected deliberately: it *replaces* the whole command line, dropping
``root=`` / ``rootwait`` unless perfectly replicated — a brick risk on a
board with no remote power. ``CMDLINE_EXTEND`` only appends, so a failed
append still boots and the missing option is caught at the deploy verify.

To reproduce the Image, from the ADI kernel tree with its own build
environment sourced (Xilinx 2025.1 ``aarch64-linux-gnu-``)::

   git apply modem/boot/kernel-arm64-cmdline-extend.patch
   ./scripts/config --set-str CMDLINE "uio_pdrv_genirq.of_id=generic-uio" \
                    --disable CMDLINE_FROM_BOOTLOADER --disable CMDLINE_FORCE \
                    --enable CMDLINE_EXTEND
   make ARCH=arm64 olddefconfig
   grep -E '^CONFIG_CMDLINE' .config     # CMDLINE_EXTEND=y + the of_id string
   make -j8 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- Image
   sha256sum arch/arm64/boot/Image       # must match SHA256SUMS.Image in images/
   strings vmlinux | grep uio_pdrv_genirq.of_id=generic-uio

The deploy side — which script writes what, in which order, and how to roll
each step back — is :doc:`setup-prebuilt` Step 0.

The image bank
--------------

Images are identified **by md5 prefix, forever** — logs, handoffs, and
rollback files all refer to images this way. The prefix is a *name*, not
a checksum contract: Vivado place-and-route and ``bootgen`` embed
timestamps and non-deterministic placement, so a functionally identical
rebuild produces a different md5. Equivalence is established by the
gates being green and the on-chip BIST golden reading
``cap_out = 0x04922282``, never by md5 equality.

**The bank below is the 2026-08 development generation**, kept because
the refuted-hypothesis ledger and the handoffs refer to these images by
name. It is *not* the deployment record: what is on the boards today,
and what it carries, is :doc:`provenance` and ``images/CURRENT.txt``.

.. list-table::
   :header-rows: 1
   :widths: 16 84

   * - md5 prefix
     - Image
   * - ``e49c011b``
     - **Proven-good** LEAN f1536 instrument image on 148: framestat
       CP1 live, cyclic-capable ``rx_byte_dma``. The reference lineage.
   * - ``433fd8da``
     - The TMR image running on 146.
   * - ``64bb2476``
     - 148's pre-instrument image (kept as a rollback generation).
   * - ``f2e22135``
     - fsv2 witness (stall 0x1C4 + txur 0x1C8) — genuinely ~46 %
       byte-plane rate on silicon; do not flash.
   * - ``c79b72d2``
     - wit3 witness, same lineage, same silicon rate break — banked,
       not flash-eligible until the rail-guard (wit4) validates.
   * - ``4be9286c``
     - tmr146-v2 witness variant for 146 — never flashed.
   * - ``c9d3e1ec``
     - skid v1. **Flashed and failed**: deadlocked the byte plane on
       silicon (fsync 1252, wcnt = 0). Do not flash.
   * - ``c85b0693``
     - skid v2 (guard-preserving). **Flashed and failed**: forward PER
       +5.6 pp worse, replicated; its witness was blind. Do not flash.
   * - ``6c06ecb7``
     - skid3 v3 witness-wire — the 2026-08 rig image on 148. Datapath
       production-equivalent to ``e49c011b`` (PER verified identical)
       plus a marker-free gap witness at 0x9D300008. The witness itself
       has no positive control and its output is not interpretable
       (:doc:`debug-instruments`); the datapath is sound.
   * - ``33a962a8``
     - skid4, ``GATED_CLOCK_CONVERSION`` experiment — banked, never
       flashed; bit-identical to its parent in WNS and rail census.

Banking is separate from flashing: a green gate matrix makes an image
*flash-eligible*, and flashing remains an explicit operator-context
decision.

Flashing: the standing rails
----------------------------

The procedure, verbatim from the overnight runbooks:

1. **Rollback first.** The known-good BOOT.BIN backup must exist on the
   board (e.g. ``/root/BOOT.BIN.e49c011b.bak``) plus host and in-repo
   copies, before anything is written.
2. **Flash by scp** to ``/boot``, then **readback md5 verify**.
3. **Full bring-up** (``restore_known_good``: reset sequence, selects,
   daemons, watchdog) — never measure a freshly-flashed board without
   it; a witness run without bring-up once produced an entire false
   "quarter-rate" verdict.
4. **Health gate before counting anything:** reset-aware framesync
   rate ≥ 1100 f/s **and** wordcnt-derived rate ≥ 1100 f/s. Use
   ``ops/health_probe_reset_aware.sh``, not a naive 0x104 delta —
   0x104 resets every ~5–7 s on a healthy link and a naive 4 s window
   probe reads ~½ rate on a link genuinely running 1245 f/s
   (``docs/evidence/BRINGUP_SEQUENCER.md`` rung 6).
5. **Any failure = halt**: roll back, md5-verify the rollback, **no
   retry variants**, bank the evidence, stop rig work.

One-directional test images (TX-only / RX-only)
-----------------------------------------------

For link tests that isolate one direction, two half images exist: **TX-only**
(the ``Receiver`` subsystem replaced by a same-interface stub) and **RX-only**
(the ``Transmitter`` stubbed). Both keep the full ``TxRxComposite`` interface,
so the AXI register map, the block-design byte wiring, the DMAs, the device
tree and every host tool are unchanged; synthesis prunes the constant-driven
half. The stub is an env-gated overlay, ``modem/dev/simulink/oneway_overlay.m``
(``QPSK_ONEWAY=tx|rx``), applied LAST by ``assemble_jupiter_240k5_byte.m``
(phase 2.22) so every earlier overlay still sees the real subsystem; with the
variable unset the HDL is byte-identical to the full image.

Build one half at a time (the remote guard refuses concurrent Vivado runs)::

   modem/build_image.sh --tag sp3txonly --oneway tx    # TX-only
   modem/build_image.sh --tag sp3rxonly --oneway rx    # RX-only

What changes in the chain under ``--oneway``:

* ``build_hdl.sh`` skips the txcap/ddrcap/ddrcap2 netlist injectors (they
  anchor on both halves) and the ``ddrcap_bd.tcl`` block-design step, so the
  BD token set has no ``DDRCAP_BD_WIRE_OK``; the ``MODEL_OVERLAYS_OK`` check
  exempts the stubbed half; ``TXFIX_VARIANT`` carries ``ONEWAY=tx|rx``.
* **Gate 1 does not apply** (the SRO matrix is TX → internal loopback → RX in
  one composite). The gates stage stamps ``SKIPPED-ONEWAY`` and instead
  requires a fresh PASS from the **pair simulation**,
  ``modem/dev/simgate/sim_oneway_pair_gate.m``: the TX-only composite drives the
  RX-only composite in one harness and must reproduce the BIST golden
  (``0x04922282``) with zero late bit errors. The two half kits it needs come
  from ``modem/dev/assemble_oneway.sh tx`` and ``rx``; run it with
  ``modem/dev/simgate/run_oneway_pair_gate.sh`` (production geometry environment).
* ``checkhdl_gate_240k5_byte.m`` honours ``QPSK_ONEWAY`` (ROM word / encoder
  gates for the TX half, RXFIX threshold for the RX half; each also asserts
  the other half's constants are GONE).
* Gate 2 (timing, ``modem_wns.py``) is unchanged.
* The half image is **not** the full netlist with one half pruned: HDL Coder's
  delay balancer solves the whole model, so the pipeline setup latency and the
  byte-plane ``delayMatch`` pads differ (RX-only measured 3/6 cycles and a
  2-deep ready pad against the full image's 4/8 and 4). ``rxfifo_inject.sh``
  therefore measures the generated ``ByteRxFifo`` chain depth and mirrors it in
  the BRAM drop-in (``chain=N`` in ``rxfifo_inject.out``), and the
  ``BS_READY_PAD`` post-check requires census depth == drop-in depth on the
  RX-only image (the full image stays pinned to 4). The TX-only image keeps the
  ``byte_ready`` pin lag of 8 that ``qpskByteSkidLag.m`` pins.

On the rig the images are roles ``TXO`` / ``RXO`` in ``images/CURRENT.txt``
(``ops/deploy_image.sh <ip> TXO``), brought up with ``ops/oneway_bringup.sh
<tx_ip> <rx_ip> [rom|byte]`` and scored with ``ops/oneway_measure.sh <rx_ip>
<dwell_s> [rom|byte]`` — see :doc:`bringup`. The ``flash_*_txfix.sh`` rails and
``arm148_mode1.sh`` are **not** used: their internal-loopback mode-1 gate
cannot pass on a half image. The TX-only board still needs its RX SSI and
profile enabled: TX pacing (``DS_TxValid``) is driven by ``adc_validIn``.

IP over the one-way link: ``qpsk_tun`` gains ``QPSK_TUN_TXONLY=1`` /
``QPSK_TUN_RXONLY=1`` (the -F/-G tun modes only), each disabling the dead DMA
side of a half image; ``oneway_bringup.sh ... tun`` and
``oneway_measure.sh ... tun`` (UDP via ``qpsk_perf``) use them. Unidirectional
traffic only: see :doc:`setup-prebuilt` Step 5.

Silicon result 2026-09-15 (``docs/evidence/oneway/ONEWAY_HW_VERIFY_2026-09-15.md``):
both directions, ROM 4 x 120 s with zero lost frames at 1245+ f/s, byte plane
4 x ~74.7 k frames with 0-3 bit errors per 76.5 Mbit; pair restored and healthy.
``ops/oneway_hw_verify.sh`` is the unattended runbook that produced it.

RTL-sim harness contract
------------------------

When replaying captures through a netlist (the replay gate, the tap
ladder, the tick-fix campaign), the drive cadence must match the
netlist generation: **Jul-25 netlist = cadence 4; post-Jul-29 (fsv2
lineage and later) = cadence 2** (``docs/evidence/HARNESS_AB.md``). The
fixed harness (``replay_gate_n2.sh``) defaults to CAD=2 and scales the
rstCS window and drain tail with cadence. Reference score on the pinned
78-frame chunk: Jul-25 archive 74/78 CRC-good, fsv2 lineage 73/78 —
the true generation gap is one frame on one marginal-heavy slice, not
the 5/78 the mis-driven harness reported.

See also
--------

* :doc:`measurement-discipline` — why the health gate and the negative
  control around it exist.
* :doc:`current-state` — the current rig state, the open fault classes,
  and the ledger of mechanisms already refuted for them.
* :doc:`debug-instruments` — the sim harnesses this contract governs and
  the rest of the instrument catalogue.
