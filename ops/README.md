# ops/ — operator kit

Scripts that touch the rig. Each one is either named by a docs page, invoked at
runtime by a script that is, or a profile/fixture such a script loads; nothing
here is a campaign one-off. `comb/` keeps only the four files the kit still uses
(the shared frames/slot plumbing `accept_analyze.py` is pinned to, the comb-period
scorer, the package marker, and the band sweep `docs/bringup.rst` names); the rest of
the comb campaign, and all of `rxfix/`, `agents/`, `seqbist/` and the per-run drivers,
are retired -- recoverable from tag `archive/pre-cleanup-2026-09-09`, with their
conclusions in `docs/evidence/`.

ADRV9002 profiles the boards load are in `profiles/` (`provision.sh` scps the
`.bin`+`.json` pair to `/root/`). `flash/` holds the TXFIX flash rails
(`flash_148_txfix.sh`, `flash_146_txfix.sh`, their `txfix_flash_go.sh` /
`txfix_flash146_go.sh` wrappers, `arm148_mode1.sh` and the `ddrcap2_decode.py`
the 148 rail's tier-2 witness step calls). The capture/probe injectors and
their non-rail flash scripts moved to `modem/instruments/<name>/` in cleanup
sub-project 2 task 8; the campaign kit directory they all came from is retired,
recoverable from tag `archive/pre-cleanup-2026-09-09`.

Board-side paths (`/root/host_app_k5/`, `/root/lvds_*.{bin,json}`) are NOT
repo paths and are deliberately unchanged by the rename — the boards in the rig
already carry them, and `link_test.sh preflight` checks for them.

| Script | Purpose | Doc |
|---|---|---|
| `anyssh.sh`, `askpass.sh` | Password-ssh transport every board call goes through | setup-prebuilt |
| `deploy_kernel.sh`, `deploy_dtb.sh`, `deploy_image.sh` | Flash kernel, dtb, BOOT.BIN from `images/` (size-checked, backed up) | setup-prebuilt |
| `provision.sh <ip>` | Host app sources (built on-board), `profiles/`, watchdog onto one board | setup-prebuilt |
| `lock_watchdog.sh` | On-board acquisition watchdog (deployed to `/root/` by `provision.sh`) | setup-prebuilt |
| `restore_known_good.sh` | Full both-board restore to the banked image + rung | setup-prebuilt |
| `bringup_r2r3.sh r2\|r3\|r4` | Profile, LO plan, ROM double-tap, daemons, watchdogs on both boards; rate/geometry/carve from `rung_table.sh` (r4 = f3072 at 2 sps, `-r 30720 -G3`, 4 MB carve, MTU 3044; strict r4 pre-flight of the deployed daemon build + live dtb carve) | bringup |
| `rung_table.sh r2\|r3\|r4` | The one rate-rung table (PROF, KSYM, SPS, FRAME, SPF, FPS, carve, MTU, perf rate); sourced by bringup / capture / restore / provision | bringup |
| `oneway_bringup.sh <tx_ip> <rx_ip> [rom\|byte]` | ONE-DIRECTIONAL test: TX-only image on one board, RX-only on the other; gates on the RX board only, no daemons/mode-1 gate | bringup |
| `oneway_measure.sh <rx_ip> [dwell_s] [rom\|byte]` | Score a one-way link on the RX-only board: reset-aware 0x104/0x108/0x144, lost frames in the denominator | bringup |
| `oneway_hw_verify.sh [fwd\|both\|restore]` | Unattended silicon run for the one-way images: flash TXO/RXO, bring up, measure, swap, RESTORE the pair (evidence docs/evidence/oneway/) | bringup |
| `gate3_run.sh <md5-12> <tag>` (or `GATE3_MD5= GATE3_TAG=` env) | Gate 3 on a candidate already flashed on BOTH boards: 6 rev + 3 fwd x 180 s, 600 s each way via `capture_r3.sh`, scored by `accept_analyze.py`, then rollback to CURRENT.txt roles | bringup |
| `gate3_pair.sh --tag <tag> --md5 <md5-12> [--rung r4] [--soak N] [--keep]` | Gate 3 as ONE rail for a banked candidate at a new rung (sp4): sentinel hold, dtb deploy, flash 148 then 146 under the flash rails (rollback = CURRENT.txt roles), the same lottery gate + 600 s legs at the candidate's rung, soak rounds, verdict against the plan's PER limits, rollback (or `--keep`). `DRY=1` prints the whole sequence and touches nothing | bringup |
| `dtb/build_dtb_4mb.sh` | Build the 4 MB-carve qpsk dtbs (f3072) from the discovered pristine base + `qpsk_byte_uio.dtso` + `dtb/carve_4mb.dtso`, cross-checked against the banked 2 MB dtb | setup-prebuilt |
| `apply_146_ssi_fix.sh <ip> <clk> <dat>` | SSI delay override via the SAFE cache protocol (called by `bringup_r2r3.sh`) | bringup |
| `health_probe_reset_aware.sh <ip> <n>` | Two-pass health gate; healthy = fsync 1245 | bringup |
| `exp_forward.sh` | Verified-lock forward loop (watchdog → probe → score) | bringup |
| `comb/__init__.py` | Package marker so `from comb.common import ...` resolves in the kit's tests | testing |
| `comb/band_ber_sweep.sh` | RF band sweep used when a leg is antenna-limited | bringup |
| `sim_repro/riglock.sh`, `sim_repro/no_arm_inflight.sh` | Rig mutex and arm-in-flight guard | bringup |
| `sim_repro/delivery_sentinel.sh`, `sim_repro/sentinel_keeper.sh` | Delivery recovery loop and the unit that keeps it alive | bringup |
| `capture_r3.sh` | Credited PER window; writes `frames.bin` + `recovery.txt` | measurement-discipline |
| `accept_analyze.py` | Acceptance scoring; lost frames stay in the denominator | measurement-discipline |
| `recovery_windows.py` | The ONE reader of `recovery.txt` (what is excluded, and why) | measurement-discipline |
| `frame_taxonomy.py` | Assumption-free error-source derivation from `frames.bin` | measurement-discipline |
| `align_frames.py` | Errored frames → `pair.iq` windows | measurement-discipline |
| `check_capture_health.py` | Capture-path health gate: is this IQ the modem, or garbage? | measurement-discipline |
| `loss_ledger.py` | Class accounting behind `docs/evidence/LOSS_LEDGER.md` | measurement-discipline |
| `paired_report.py` | Run-level paired analysis for interleaved captures | measurement-discipline |
| `comb/comb_period_ms.py`, `comb/common.py` | Comb-period scorer and the shared frames/slot plumbing it and `accept_analyze.py` are pinned to | measurement-discipline |
| `arq_r3.sh` | R3/f1536 ARQ delivered-PER measurement, both directions | measurement-discipline |
| `launch_rig_unit.sh` | Run a rig script as a frozen copy under a systemd user unit | measurement-discipline |
| `test.sh loopback\|bist\|link` | Tier A/B/C entry point | testing |
| `link_test.sh` | Two-Jupiter RF link test (preflight, ber, tun) | testing |
| `link_test_1536.sh` | Same, for the retired f1536 rung; kept only for rollback against a frozen Image A board, not cited by any current doc page | testing |
| `ber_loopback_gate.sh <ip>` | On-board internal FPGA loopback BER gate | testing |
| `measure_ber.sh <ip> <nreads>` | On-chip hardware BIST BER | testing |
| `rf_loopback.sh <ip> [lo_mhz]` | Single-board RF loopback | testing |
| `mux_test.sh` | Daemon-restart mux/tap survival check | debug-instruments |
| `rate_probe.sh` | Per-stage rate probe | debug-instruments |
| `tap_smoke.sh` | Exercise the four IQ tap mux modes | debug-instruments |
| `capture_paired.sh A\|B` | Paired capture (Tap-A during a live scored window) | debug-instruments |
| `capture_evm.sh` | EVM capture off the tap | debug-instruments |
| `dcp_rail_dump.tcl` | Implemented-design rail/enable forensics (used by the instrument build rails) | debug-instruments |
| `profiles/lvds_*.{bin,json}` | ADRV9002 profiles: r3 `61p44_fdd` (deployed), r2 `30p72_fdd`, legacy `1p92_mhz`, f1536 `15p36` | bringup |
| `flash/` | The TXFIX flash rails: `txfix_flash_go.sh` → `flash_148_txfix.sh` (role A / 148), `txfix_flash146_go.sh` → `flash_146_txfix.sh` (role B / 146), plus `arm148_mode1.sh` (148-only mode-1 arm) and `ddrcap2_decode.py` (witness decode). Run logs and witness `.bin`s land here and are gitignored | build-and-flash |
| `tests/` | Unit tests for the kit's scorers, plus `test_ddrcap2_inject.py` (imports the injector from `modem/instruments/ddrcap2/`) and `test_ddrcap2_decode.py` (imports the decoder from `ops/flash/`) | testing |
