# images — banked BOOT.BIN images for the two-Jupiter rig

Canonical bank of the load-bearing boot images (ADALM Jupiter, ZynqMP, f1536 /
61.44 MSPS byte-plane modem). Filenames carry board + lineage + md5-12; verify
against `MD5SUMS` before any flash. All BOOT.BIN images 7,203,552 bytes, bootgen
`-arch zynqmp -w`. Evidence for every claim: `docs/evidence/SINGLES_CAMPAIGN.md`
(dated sections) and `docs/evidence/NETLIST_PROVENANCE.md`.

## sp3 — the SINGLE image (both boards), added 2026-09-12

sp3 ends the two-image split. The W1 / R4B / R4D+R1 / BS / PAD / F3 fixes are
now MODEL overlays (`modem/rxfix/`, assemble phase 2.21) rather than netlist
injections, so ONE regeneration produces one image that carries all of them and
is meant to run on both boards; `modem/build_image.sh` has no `--role` any more.
Which of R4B and R4D+R1 is active at runtime is a register selection, not a
build (Tasks 12-15).

| file | md5-12 | what it is |
|---|---|---|
| `BOOT.BIN.jupiter.sp3.c5ec53bc610c5eff837a62b439466660` | `c5ec53bc610c` | **BANKED, NOT DEPLOYED — GATE 3 (silicon) FAILED 2026-09-12, both boards rolled back to the sp2 pair.** Built end to end by `modem/build_image.sh --tag sp3 --remote-base /mnt/disk2/scratch/qpsk-builds` (stages `hdl` then `vivado`), kit `jupiter_byte_sp3_build`, `model_tree_sha=144c89e8fe98317d`, repo git `ba4e056c`, `IMPL_STRATEGY=explore`, Vivado v2025.1 on hdl-dev-2, built 2026-09-12 03:17. FIRST image whose block design is completed by the build itself (`modem/complete_byte_bd.tcl` then `ddrcap_bd.tcl` then `seqbist_bd.tcl`, in one local Vivado session) rather than by a kit inherited from an earlier tree, and the FIRST to carry SEQ-BIST as a built-in BD instrument (`rx_seq_checker` with `WITH_CRC=1`, `cnt_mux32`, `qpsk_traffic_gen_v2`, and the three GPIOs at 0x9D400000 / 0x9D410000 / 0x9D450000 -- the same control-bit map as the 148 SEQ-BIST kit; see `modem/instruments/seqbist/patch_seqbist_tcl.py`). **Gate 2 PASSED: modem-clock intra-clock post-route WNS +0.785 ns, TNS 0, 0 failing endpoints of 85,948** (`BUILD_IMAGE_WNS_OK wns=0.785 floor=0.005 ref_pad=0.105 ref_sp2A=0.447 ref_sp2B=0.785`); overall routed WNS +0.207, TNS 0. Evidence: `docs/evidence/sp3/GATE2_TIMING.md`. **Gate 1 PASSED separately**, on Task 9's own gate tree (`MODEL_TREE_SHA e615c4a4…`, differs from this build's `144c89e8fe98317d` only in `TxRxCompo_ip.v`'s `ip_timestamp` constant): the full sim equivalence matrix at both `sro_sign` settings, `docs/evidence/sp3/GATE1_EQUIVALENCE.md` -- `build_image.sh` still flagged `BUILD_IMAGE_WARN ... building UNGATED` because Gate 1's own stage did not run inline for THIS build. **Gate 3 (silicon) FAILED:** flashed and gated green on both boards (148 needs `GOLD=1` for its mode-1 arm gate -- it reads `0x20C`, not the sp2-era `0x144`, and this image's `0x20C` golden is `1`), and the one forward window taken with an **sp2** transmitter (146 on sp2B) passed at 607 s live, **PER 0.003 % (22/736,509)**, lost frames in the denominator -- but every path driven by an **sp3 transmitter** wedged: three consecutive reverse legs at 18 s / 34 s / 61 s wall (at both `sro_sign` settings, exonerating that bit), then the forward leg itself once an sp3 146 started transmitting into 148 (`rate=219/s crc=40.6%` -> `WEDGE detected (rate=0/s)`). Both boards rolled back under the rails 07:55–08:07, rig healthy on sp2A/sp2B. Full record, open suspects for the sp3 TX-side defect, and the discriminating rebuild recipe: `docs/evidence/sp3/SP3_SILICON.md`. Do not flash without addressing that defect. |

**No aliases (2026-09-17).** The bank holds one file per image. The rails take `FLASH_MD5=<md5-12>`
and resolve it through `MD5SUMS` (`awk index($1,p)==1`), so no board-named copy or link is needed;
the former `BOOT.BIN.{146,148}.<tag>.<md5-12>` symlinks were removed. Board-named files that remain
below (sp2A/sp2B, rxfix*, w1x148) are real, distinct images from before the single-image era.

| file | md5-12 | what it is |
|---|---|---|
| `BOOT.BIN.jupiter.sp4b.bc9ac1e6b736ddb401701b652ef26bf3` | `bc9ac1e6b736` | **sp4b (f3072, 2 sps) = sp4 with Tap-A back on IQ -- BANKED, NOT DEPLOYED (2026-09-24).** Beat observer removed from the netlist (`beatobs_overlay.m` taps-only; `docs/evidence/sp4/TAP_A_BEATOBS.md`), ddrcap2 sel 15 reads zero. Prod re-derived (`c0a25b6b7623`), S1B + Simulink gate PASS, **Gate 1 53/53 sample-identical to the sp4 bank, Gate 2 WNS 0.928 ns**. **Gate 3 attempt 2 (2026-09-24, `docs/evidence/sp4/SILICON.md` sec 7): FAIL** -- 6 of 17 windows aborted on the byte-plane ring stall (`no ENGINE event`, peer-dominated), forward leg 2.0-5.0 %, reverse 0.05-0.065 % on healthy arms and 7.9 % on three arms where a 0x000 re-arm had cleared `sro_sign`. Tap-A carries real IQ again. Rolled back; still the sp4 candidate, but no further silicon run until the wedge class is characterised. |
| `BOOT.BIN.jupiter.sp4.5108cdb77aebb0989c53c65f4a0eac75` | `5108cdb77aeb` | **sp4 (f3072 = 24634 slots at 2 sps, 30.72 Msym/s on the 61.44 MSPS profile, rung r4) -- BANKED, NOT DEPLOYED (2026-09-22).** Built from the derived `modem/prod` at `QPSK_FRAME=f3072 QPSK_SPS=2`; Gate 1 53/53 dev and prod (`docs/evidence/sp4/GATE1.md`, `GATE1_PROD.md`), Gate 2 WNS 0.794 ns on the modem clock (`GATE2_TIMING.md`). Host: `qpsk_tun -G3 -r 30720` built `-DQPSK_CARVE_4MB` on the 4 MB dtb (`DTB148`/`DTB146` rows in `CURRENT.txt`); ops rung `r4` (`ops/rung_table.sh`). **Gate 3 attempt 1 (2026-09-22, `docs/evidence/sp4/SILICON.md`): FAIL** -- the stack comes up on air (mode-1 1250 f/s, arm gate try 1, health gate pass 1); forward leg 0.037-0.049 % (fwd600 343/732,021), **reverse leg ~21 % (rev600 67,043/319,732) with 250 carrier resets/s: below the 2-sps decoder's threshold on the 146 antenna**, not the LO plan (+80/+120 kHz cells lock the CFC loop and change nothing) nor the steering branch (sro_sign=0 identical). Both boards rolled back to sp3prod. Keep banked; re-gate after the 146 antenna / a 2-sps receiver margin fix. |
| `BOOT.BIN.jupiter.sp3prod.b68dbf1d932186ad1f769ebb7dbfbc03` | `b68dbf1d9321` | **CURRENT, both roles (deployed 2026-09-16).** Built from the derived `modem/prod` model; Gate 3 0 bad arms of 11 (`docs/evidence/sp3prod/GATE3_2026-09-16.md`). |
| `BOOT.BIN.jupiter.sp3txclk.cae8c4fdac0983f6010898a9dcb822e8` | `cae8c4fdac09` | **Rollback for both roles** (on-board `/root/BOOT.BIN.cae8c4fdac09.bak`); the sp3 single image + txclk hook, Gate 3 PASS 2026-09-13. |
| `BOOT.BIN.jupiter.sp2Atxclk.9d4f8d24fc9e1536fa6bc55e810507c2`, `BOOT.BIN.jupiter.sp2Btxclk.e975e506e6133328d062f1c941cccfc7` | `9d4f8d24fc9e`, `e975e506e613` | sp2 role images rebuilt with the txclk hook (banked, not deployed). |
| `BOOT.BIN.jupiter.sp3txonly.8126659ac9c65c34775b5c85acc0f185`, `BOOT.BIN.jupiter.sp3rxonly.8affa3e59582d46fc238674024df4ee3` | `8126659ac9c6`, `8affa3e59582` | ONE-WAY test images (TX-only / RX-only); bring up with `ops/oneway_bringup.sh`, never the rails. `docs/evidence/oneway/`. |


## 146 (10.0.0.146 — TMR lineage, byte-plane TX under study)

| file | md5-12 | what it is |
|---|---|---|
| `BOOT.BIN.146.sp2B.d94b4df391a1` | `d94b4df391a1` | **DEPLOYED on 146 2026-09-10 18:43 (readback-verified by the flash rail's [3/6]) and CURRENT (role B in `CURRENT.txt` since 2026-09-10 22:30).** Silicon gate PASSED: credited reverse PER **0.121 % (908/747,849)** on the sp2 pair (`ops/r3cap/sp2pair_rev`, 2026-09-10 22:23, lost frames in the denominator), `wedge_verdict=healthy`, lag33 0.004, `COMB_LINE=absent`, health gate 12/12 — and it **passes the documented arm (≤ 0.191 %), not the 2×-baseline arm (≤ 0.062 %)**; the same-day reverse baseline on the old pair was 0.031 % (227/733,562), and 0.048 % (354/734,808) with sp2A transmitting into the old 146 — `docs/evidence/sp2/SP2_SILICON.md` Step 6. The first attempt scored 0.694 % on a single 4,503-frame deletion burst and was re-run once, as the acceptance ruling allows (`ops/r3cap/sp2pair_rev_try1` kept). On-board rollback `/root/BOOT.BIN.9acbe2ebe1db.bak` (`BOOT.BIN.146.rxfixr4dr1.9acbe2ebe1db`, still banked). Role B (146) rebuilt end-to-end by `modem/build_image.sh --role B` **as that script existed at repo git `1ef3fa6b`** (it is now the sp3 single-image flow and has no `--role`; the by-hand sp2 recipe is in `docs/build-and-flash.rst`) from the banked base tree + the fix manifest `modem/fixes/fixes.toml` (manifest sha `60f43ba3d5f8f871`, repo git `1ef3fa6b`), kit `jupiter_byte_rxfixr4dr1sp2_build`, `IMPL_STRATEGY=explore`, Vivado v2025.1 on hdl-dev-2, built 2026-09-10 17:42. FIRST build to use `--remote-base /mnt/disk2/scratch/qpsk-builds` (hdl-dev-2's second disk, 136 GB free; `/` was at 45 GB and holds the AS-BUILT reference kits, which are untouched). Same fix set as the deployed `rxfixr4dr1` image (W1 + R4D + R1). Sim gates `GATES_DONE role=B pass=4 fail=0` (all 26 legs reused from Task 5, `modem/rtl_sim/evidence/sp2/gates_B.log`). Modem-clock intra-clock post-route WNS **+0.785 ns**, TNS 0, 0 failing endpoints (`modem/rtl_sim/evidence/sp2/modem_wns_B.txt`); the as-built reference kit measures +0.620 with the same tool, so the one-sided drift gate passed (`BUILD_IMAGE_WNS_OK wns=0.785 ref=0.62 role=B`). NOTE: the synthesised netlist is not identical to the reference (84,063 vs 84,673 modem-clock endpoints, -610; role A saw -597 on its own reference) — fresh synthesis from byte-identical RTL, Vivado run-to-run variation; cleared by the silicon gate (see `docs/provenance.rst`). Build log tail: `modem/rtl_sim/evidence/sp2/build_B.log`. |
| `BOOT.BIN.146.rxfixr4dr1.9acbe2ebe1db` | `9acbe2ebe1db` | **RXFIX candidate for 146: W1 + R4D + R1 — and it is a 148-LINEAGE IMAGE.** Source kit `jupiter_byte_seqbist_build` (the **148** SEQ-BIST tree, `a1ff3c876d91`), injector `10b27b7`, kit `jupiter_byte_rxfixr4dr1_build`, `IMPL_STRATEGY=explore`. Fix content: R4D = R4B's structural pcEnd window plus a FULL-side extra pop armed at occ >= 24; R1 = the Preamble_Detector realignment FIFO's pop becomes occupancy-indexed (`Delay10_full = FIFO_numEntries == 14'd12333`), without which that FIFO deletes the extra (Task 14). Sim gate: Task 20 S1, +10 ppm loss **0.00 %** (baseline 4.99 %, R4B 6.65 %, R4D alone 70.28 %), `rh_push_on_full` 0, `pdOcc` pinned at 12,333. **Modem-clock intra-clock routed WNS +0.620 ns**, TNS 0, 0 failing endpoints. R1 trims the 49,332-deep `Delay10_reg`: **CLB Registers 110,550 -> 61,331 (-49,219)**, **SRLC32E 2,977 -> 1,435 (-1,542)**. Witness words 0x234 (R4B's layout) and **0x238** (`{16'b0, extras[15:0]}`, unread by any tool in-repo yet). **Flashed on 146 2026-09-05 14:11; was role B in CURRENT.txt until 2026-09-10, now the ROLLBACK for role B (banked here and on-board as `/root/BOOT.BIN.9acbe2ebe1db.bak`).** Reverse PER 0.191 % (09-06, DP cable out), 0.06–0.09 % on 2026-09-09 with whitening (level-limited). On-board rollback `BOOT.BIN.146.w1x148.2728dab3979a` (`/root/BOOT.BIN.2728dab3979a.bak`). |
| `BOOT.BIN.146.w1x148.2728dab3979a` | `2728dab3979a` | **On-board rollback bank for 146**, banked here as `w1x148` because the content is a 148-lineage W1-only image (originally `BOOT.BIN.148.rxfixw1.2728dab3979a`, superseded on 148 by R4B `9f13705d9fb0`) that was cross-flashed to 146 ahead of `rxfixr4dr1` as its verified `.bak`. W1 = the Rate_Handle-only fix, no R4B/R4D/R1/BS on top. Do not treat as a 146-native lineage image; see the `rxfixr4dr1` row for the confound history. |

Note (2026-08-26): the comb is CFO-sign-asymmetric and requires cross-board
clocks; per-image PER deltas may be receiver-side sensitivity — see
`docs/evidence/KNOWN_HOLES.md` H-1/H-3 before spending flashes on placement draws.

## 148 (10.0.0.148 — RX/tap board)

| file | md5-12 | what it is |
|---|---|---|
| `BOOT.BIN.148.sp2A.3e7f4232a3b5` | `3e7f4232a3b5` | **DEPLOYED on 148 2026-09-10 17:59:48 (readback-verified 18:00:57) and CURRENT (role A in `CURRENT.txt` since 2026-09-10 22:30).** Silicon gate PASSED: credited forward PER **0.005 % (39/734,808)** on the sp2 pair (`ops/r3cap/sp2pair_fwd`, 2026-09-10 21:47, lost frames in the denominator), `wedge_verdict=healthy`, lag33 −0.000, health gate 12/12 — `docs/evidence/sp2/SP2_SILICON.md` Step 6. On-board rollback `/root/BOOT.BIN.bf2a7305bbe0.bak` (`BOOT.BIN.148.rxfixpad.bf2a7305bbe0`, still banked). Role A (148) rebuilt end-to-end by `modem/build_image.sh --role A` **as that script existed at repo git `c14e7b11`** (it is now the sp3 single-image flow and has no `--role`; the by-hand sp2 recipe is in `docs/build-and-flash.rst`) from the banked base tree + the fix manifest `modem/fixes/fixes.toml` (manifest sha `60f43ba3d5f8f871`, repo git `c14e7b11`), kit `jupiter_byte_rxfixpadsp2_build`, `IMPL_STRATEGY=explore`, Vivado v2025.1 on hdl-dev-2, built 2026-09-10 16:52. Same fix set as the deployed `rxfixpad` image (W1 + R4B + BS + PAD) and its `hdlsrc` tree is BYTE-IDENTICAL to the as-built reference kit. Sim gates `GATES_DONE role=A pass=5 fail=0` (`modem/rtl_sim/evidence/sp2/gates_A.log`). Modem-clock intra-clock post-route WNS **+0.447 ns**, TNS 0, 0 failing endpoints (`modem/rtl_sim/evidence/sp2/modem_wns_A.txt`); reference build was +0.105. NOTE: the synthesised netlist is not identical to the reference (185,874 vs 186,471 modem-clock endpoints) — Vivado run-to-run variation from identical RTL; cleared by the silicon gate (see `docs/provenance.rst`). Build log tail: `modem/rtl_sim/evidence/sp2/build_A.log`. |
| `BOOT.BIN.148.rxfixpad.bf2a7305bbe0` | `bf2a7305bbe0` | **RXFIX W1 + R4B + BS + PAD (F4: ByteSerializer pads truncated frames to 191 words).** Kit `jupiter_byte_rxfixpad_build` from the SEQ-BIST tree, injector f75d522, `IMPL_STRATEGY=explore`; modem-clock intra-clock routed WNS **+0.105 ns** / TNS 0 (overall 1.544). Sim gate §47.8 PASS (truncation control 418×191-word frames, 0 orphans; identity byte-identical). Built 2026-09-08 17:10 on hdl-dev-2. Flash/result: ledger FWD_CRC_REGRESSION_0907 §47.9–§47.10. **Flashed on 148 2026-09-08 17:12; was role A in CURRENT.txt until 2026-09-10, now the ROLLBACK for role A (banked here and on-board as `/root/BOOT.BIN.bf2a7305bbe0.bak`);** forward PER 0.008 % with WHITEN=1 (§47.24, §48.3). Rollback `BOOT.BIN.148.rxfixbs.dec007ae70dd` on-board. |
| `BOOT.BIN.148.rxfixbs.dec007ae70dd` | `dec007ae70dd` | **On-board rollback bank for 148.** W1 + R4B + BS (byte-seam census), the lineage immediately before PAD/F4: kit `jupiter_byte_rxfixbs_build`, injector `e95a013`. Flashed on 148 2026-09-07 18:14 under full rails, GATE_PASS x2 (`fps=1248`, `capTAP=0xBCF94856`), Tier-2 witness clean; superseded on-board by `rxfixpad` on 2026-09-08 and kept as that image's verified `.bak`. |

## Kernel Image and device trees (added 2026-09-09)

The boot set per board is BOOT.BIN + `/boot/Image` + `/boot/system.dtb`. All
three are banked; identities below were read back from both rig boards on
2026-09-09 and match.

| file | identity | what it is |
|---|---|---|
| `Image.6.12.77-uio.a1ba00b51431.gz` | raw `Image` sha256 `a1ba00b514319d8006d9555815e48427840c9291d785868da986feb5cbffe0b5` (`SHA256SUMS.Image`), 48,239,104 B; gz md5 in `MD5SUMS` | UIO kernel, `6.12.77-gcfe32235a832-dirty`: ADI `xlnx/release/v6.12.y-2026r1` @ `cfe32235` + `modem/boot/kernel-arm64-cmdline-extend.patch` (`CONFIG_UIO_PDRV_GENIRQ=y`, `uio_pdrv_genirq.of_id=generic-uio` baked in). Same file on 148 and 146. `gunzip -k` it (the raw `Image.6.12.77-uio.a1ba00b51431` is gitignored); `sha256sum -c SHA256SUMS.Image` and `ops/deploy_kernel.sh check <Image>` both verify the sha256. |
| `system-qpsk.148.dtb.4c63f54656dc` | md5-12 | **f3072 rung (sp4)** qpsk dtb for **148**: pristine base + `modem/boot/qpsk_byte_uio.dtso` (SPI cells 110/111) + `ops/dtb/carve_4mb.dtso` = **4 MB carve @ `0x7FC00000`** (host `-DQPSK_CARVE_4MB`, `qpsk_tun -G3`). Built by `ops/dtb/build_dtb_4mb.sh` 2026-09-22, which proves pristine+overlay reproduces the 2 MB dtb below and that the only change is the carve `reg` (`ops/tests/test_dtb_carve.py`). The 4 MB span contains the 2 MB one, so the shipped sp3prod pair still runs on it. `CURRENT.txt` row `DTB148`; not yet on a board. |
| `system-qpsk.146.dtb.72d4028d5cbe` | md5-12 | same 4 MB carve on 146's own base (`DTB146`); not yet on a board. |
| `system-qpsk.148.dtb.1da3a9cf05a0` | md5-12 | qpsk dtb for **148**: pristine base + `qpsk_byte_uio.sub.dtso` (pre-cleanup tree; see tag `archive/pre-cleanup-2026-09-09`) (2 MB carve @ `0x7FE00000`, 3 UIO nodes, SPI cells 110/111). On 148 as of 2026-09-22; the rollback for the 4 MB dtb. |
| `system-qpsk.146.dtb.19e974098b6e` | md5-12 | qpsk dtb for **146**, same overlay on 146's own base. On 146 as of 2026-09-22; the rollback. |
| `system.dtb.pristine.148.3334673acf50` | md5-12 | Reference (stock ADI) `system.dtb` 148 shipped with; rollback + `BASE_DTB` for `deploy_dtb.sh build`. |
| `system.dtb.pristine.146.dba6d8f74aac` | md5-12 | Reference (stock ADI) `system.dtb` 146 shipped with. |

Deploy order per board: `deploy_kernel.sh <ip> <Image>` → `deploy_dtb.sh <ip> <qpsk dtb>` →
`deploy_image.sh <ip> A|B`, one board at a time (`docs/build-and-flash.rst`, `docs/setup-prebuilt.rst` Step 0).

## Deployment (all scripts tracked in `ops/`)

- Flash under full rails (md5 precondition, on-board + repo rollback banks,
  readback verify, full bring-up, two-pass reset-aware health gate
  fsync>=1100 AND wcnt>=1100 on 148, auto-rollback, NO retry):
  - 148: `modem/dev/simulink/beatila/flash_148_beatfix2.sh <md5-12>`
  - 146: `flash_146_vendh.sh <md5-12>` (carried the 2026-08-26 rails
    amendment: pre-flash 148 liveness/health precondition; adapt BB/BAK_MD5
    header vars per target image), also `flash_146_tmrfresh.sh`,
    `flash_146_rollback433.sh` — all three retired, on tag
    `archive/pre-cleanup-2026-09-09`
- Bring-up / restore: `ops/restore_known_good.sh` (full both-board restore:
  profile arm, ROM double-tap, stream-first byte flip, daemons, watchdogs),
  `ops/bringup_r2r3.sh r3`. Forward RX LO default is +20k off-null
  (2026-08-26, comb 13%->6%), env-overridable via `LO_A_RX`.
- Health: `ops/health_probe_reset_aware.sh <ip> 12` (the trusted probe).
- Watchdog: `ops/lock_watchdog.sh` (hardened build, deployed to
  `/root/lock_watchdog.sh` on both boards; restart via ISOLATED ssh calls).
- Flash discipline: stop the nemo sentinel first
  (`touch ~/modem-status/SENTINEL_STOP`), relaunch after; one flash event per
  board per session unless operator-gated; rollback flashes end the lane.

`MD5SUMS` in this directory is authoritative — `md5sum -c MD5SUMS` before use.

Images removed on 2026-09-09 are on tag `archive/pre-cleanup-2026-09-09` under the image bank's pre-cleanup path.

## sp3clamp004 -- sp3 lineage with the symbol-sync integrator clamp at 0.004, built 2026-09-30

`BOOT.BIN.jupiter.sp3clamp004.8503f226395c46d94631f5f9bcae6123` (md5 8503f226395c...). The dev tree at
`5ecc07ab` regenerated at the shipped rung (`QPSK_FRAME=f1536 QPSK_SPS=4 modem/build_image.sh --tag
sp3clamp004`): `timing_hardening_overlay.m` IntegClamp 0.06 -> 0.004 (docs/evidence/link/
CARRIER_LOCK_LATCH_2026-09-29.md), plus everything merged into dev since the sp3prod derivation
(BeatObs observer pruned, sp4-era rate/steer/census overlays). Gate 1: 48/5 IDENTICAL to the shipped
lineage's set on the f1536 harness (worktree ae2996bd; the current harness is f3072-only and cannot
gate an f1536 image); no-latch gate 7/7 + clean-run identity; Gate 2 WNS 1.187. Candidate for the
carrier-lock fix -- Gate 3 / latch test / soak recorded in the evidence doc.

## sp3clamp004 one-way pair -- TX-only / RX-only rebuilt from current dev, 2026-10-01

`BOOT.BIN.jupiter.sp3clamp004txo.512fce05378ddec29eb5a1ddbf419abf` (TXO, md5 512fce05378d..., WNS 2.684) and
`BOOT.BIN.jupiter.sp3clamp004rxo.b985971fa137859c69abbdec30b4b900` (RXO, md5 b985971fa137..., WNS 1.217): `build_image.sh --oneway tx|rx`
at f1536 / 4 sps from dev `8d6f6a4f` -- the 09-15 one-way pair carried neither the symbol-sync integrator
clamp 0.004 (`CARRIER_LOCK_LATCH_2026-09-29.md`) nor the two weeks of merged dev overlays. Gated by the
model-level pair simulation (`SIM_ONEWAY_PAIR_GATE.txt` 01-Oct: TX-only -> RX-only, ROM source, golden
`cap_out 0x04922282`, both stubs inert) as the one-way chain requires; not yet hardware-verified
(`ops/oneway_hw_verify.sh`). The 09-15 pair (`8126659ac9c6` / `8affa3e59582`) stays banked as the previous rows.

## sp4clamp004 -- the sp4 (f3072, 2 sps) rung regenerated with the clamp, 2026-10-01

`BOOT.BIN.jupiter.sp4clamp004.66c84cbc0a85613feacbdeb64e1ef6c4` (md5 66c84cbc0a85..., WNS 1.138): dev `7b32d325` at the default
f3072 rung, Gate 1 `model_matrix.legs` **53/53 PASS** on its native f3072 harness (`SRO_SIM_DIR=sro_sim_f3072`),
Gate 2 WNS 1.138. The r4 lineage inherits the symbol-sync integrator clamp 0.004; its carrier plan is still the
2026-09-26 one (`ops/rung_table.sh` r4: 148 RX 2000060000 / 146 TX 2000000000 -- the band the forward link is
impaired on since 09-29, `docs/evidence/link/FORWARD_LINK_2026-10-01.md`). Not deployed, no CURRENT role; r4 Gate 3
on hardware (4 MB dtb on both boards) is the next step for that rung.
