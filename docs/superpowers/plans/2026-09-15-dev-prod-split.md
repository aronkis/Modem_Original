# dev / prod model split -- implementation plan (PR 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split `modem/` into `dev/` (overlay-driven source) and `prod/` (tracked flattened model derived from dev by script), without changing the shipped build's behaviour.

**Architecture:** Each tree is a complete kit root; shared files live once at `modem/` and are symlinked into both trees; kit copies dereference symlinks. `prod/` is produced by `prod/tools/derive.sh` (dev kit copy + assemble + scripted cleanup chain in one MATLAB session) and committed as a binary snapshot with a structural diff as the change record.

**Tech Stack:** bash, MATLAB R2025b batch (`/mnt/onetb/MATLAB/R2025b/bin/matlab`), Simulink API, rsync, pytest, Sphinx.

**Spec:** `docs/superpowers/specs/2026-09-15-dev-prod-split-design.md`

## Global Constraints

- Kit-root contract: overlays by bare name after `addpath(kit)`, `cd(kit)`; `hdlworkflow_loopback.m` and stamps opened by relative name; Tcl by `[info script]`; goldens at `<kit>/../contract`.
- Kit copies must use `rsync -aL` (dereference symlinks).
- `build_hdl.sh` default tree stays `dev`; the shipped chain's behaviour must not change in PR 1.
- `tools/check_paths.sh` must stay green; no retired names (`jupiter_240k5_byte`, `host_app_k5` as repo path, `two_jup`, `k5_240`, `boot_known_good`).
- Commit with `git commit -s`; work on branch `dev-prod-split-2026-09-15`; push and open a PR.

---

### Task 1: `modem/dev/` tree, shared symlinks, build/tests repointed

**Files:**
- Move (git mv) into `modem/dev/`: `commhdlQPSKTxRx.slx`, `commhdlQPSKTxRxLoopback.slx`, `commhdlQPSKTxRxLoopback_asrun_433fd8da.slx`, `asrun_433fd8da/`, `assemble_jupiter_240k5_byte.m`, every `*_overlay*.m`, `fec_remove_scrambler.m`, `resolver_lookback_fix.m`, `patch_hdlworkflow_*.m`, `build_composite_local.m`, `variant_pre.m`, `hdlworkflow_loopback.m`, `build_variant_byte.m`, `run_assemble_byte.m`, `sim_byte_gate_k5.m`, `checkhdl_gate_240k5_byte.m`, `gen_byte_vectors_k5.m`, `s1_analyze_240k5.m`, `s1b_analyze_byte.m`, `run_netlist_gates.sh`, `run_full_gates_t8.sh`, the four `*_GATE*.txt`/`CHECKHDL_*.txt` stamps, the four tracked `*.out` logs, `rxfix/`, `instruments/beatila/` (overlays).
- Symlink into `modem/dev/` (relative `../x`): `frame_config_k5.m`, `commhdlQPSKTxRxParameters.m`, `commhdlQPSKTxRxModelInit.m`, `qpskFindTxInputData.m`, `qpskByte*.m` (6), `complete_byte_bd.tcl`, `complete_byte_t8.tcl`, `wire_byte_irqs.tcl`, `timing_gate.tcl`, `cdc_exceptions.xdc`, `tmr_keep.xdc`, `image_a_3072_clocks.xdc`, `tmr_attr_inject.sh`, `instruments`, `rtl_sim`, `rxfifo_bram`, `vivado`, `gates`.
- Create symlink `modem/contract -> ../contract`.
- Modify: `modem/build_hdl.sh:125-127,190-191` (`--tree`, `KIT="$REPO/modem/$TREE"`, `rsync -aL`), `modem/build_variant_byte.m:16` (beatila path stays `instruments/beatila` via the symlink), `modem/flat/make_flat_model.sh:38` and `modem/flat/edit/make_edit_kit.sh:34` (KIT = dev, `rsync -aL`), `tests/helpers/modem_paths.m` (`p.kit = modem/dev`), `modem/tests/test_assemble_phases.py:2`, `modem/tests/test_rxfix_overlays.py:13` (M = `parents[1]/'dev'`), `tools/check_paths.sh:36-41` waiver paths, `.gitignore:59-65`.

**Interfaces:**
- Produces: `modem/build_hdl.sh --tree dev|prod` (default dev) selecting `KIT="$REPO/modem/$TREE"`.

- [ ] Step 1: moves and symlinks (script, then `ls -la modem/dev | head`).
- [ ] Step 2: repoint `build_hdl.sh`, flat scripts, tests, check_paths, gitignore.
- [ ] Step 3: `bash tools/check_paths.sh` -> `CHECK_PATHS_OK`; `python3 -m pytest modem/tests -q` -> all pass; `bash -n` on edited shell scripts.
- [ ] Step 4: prove the kit contract: `modem/flat/make_flat_model.sh` (kit copy from dev via `rsync -aL` + assemble) -> `FLAT_MODEL_BANKED`, blocks=3374.
- [ ] Step 5: commit `modem: dev/ tree for the overlay-driven source; shared files symlinked; build_hdl --tree`.

### Task 2: `modem/prod/` tree exported from the edit kit; flat tooling becomes `prod/tools`

**Files:**
- Create `modem/prod/commhdlQPSKTxRxLoopback.slx` (copy of the edit kit model), `prod/hdlworkflow_loopback.m` (kit copy, `reg_` paths), `prod/sim_byte_gate_k5.m` (kit copy: error instead of re-assemble, `rxAlignLat` assignment), `prod/checkhdl_gate_240k5_byte.m` (kit `checkhdl_gate_flat.m`), `prod/run_netlist_gates.sh` (kit copy, S1 skipped at f1536), `prod/rtl_sim_overrides/wrap_byte.v`, `prod/rtl_sim_overrides/sim_byte.cpp`, `prod/build_variant_byte.m` (load_system + workflow, no assemble), `prod/gen_byte_vectors_k5.m` + `prod/s1b_analyze_byte.m` (symlinks to dev's, they are frame-generic), the same shared symlinks as dev.
- Move `modem/flat/` -> `modem/prod/tools/` (`edit/` stays a subfolder); `make_edit_kit.sh` default source = `modem/prod` (copy the tree, no patching needed except installing `rtl_sim_overrides` over `rtl_sim`).
- Modify `modem/build_hdl.sh`: when `--tree prod`, after the kit copy install `rtl_sim_overrides/*` over `<kit>/rtl_sim/` and skip the assemble-specific post-checks that grep overlay markers only when `--tree dev` (keep `MODEL_OVERLAYS_OK` for prod too: the modules exist in the flat model).

- [ ] Step 1: export files from `/mnt/onetb/scratch/qpsk-build-trees/flat_edit/jupiter_byte_flatedit_build` into `prod/`; record origin in `prod/PROD_ORIGIN` (kit md5, date, git sha).
- [ ] Step 2: write `prod/build_variant_byte.m`.
- [ ] Step 3: `make_edit_kit.sh` builds a kit from prod; `flat_gate.sh diff` on it vs `flat_ref.slx` (the exported model) -> STRUCTURE EQUAL.
- [ ] Step 4: commit `modem: prod/ tree (flattened model snapshot + its gate/consumer files); flat tooling -> prod/tools`.

### Task 3: derivation `prod/tools/derive.sh` + `derive_prod.m` + `prod_cleanup.m`

**Files:**
- Create `modem/prod/tools/derive.sh` (kit copy of dev with `rsync -aL`, env exports, `matlab -batch "addpath(kit/prod_tools); derive_prod"`, copy result to `modem/prod/commhdlQPSKTxRxLoopback.slx`, run `flat_diff` vs previous, write `prod/DERIVATION.txt`).
- Create `modem/prod/tools/derive_prod.m`: in one session: assemble (via `make_flat_model` core), then `flat_rename_reg_ports(...,'Apply',true)` (model only: the consumer rewrite targets prod's tracked copies, which are already renamed), `flat_order_ports`, `flat_layout_lanes('TxRxComposite')`, `flat_layout_lanes('TxRxComposite/Receiver')`, `flat_snap_ports` (both), `flat_simfix`, `prod_cleanup`, `flat_root_harness`, save.
- Create `modem/prod/tools/prod_cleanup.m`: delete-list = `TxRxComposite/Transmitter/{Bus Creator, Bus Selector, Delay10, Delay6, Repeat3, Repeat4, Repeat5, complex, dataOutI2, dataOutQ2, msg_count_out, txDiagBus}`; after deleting, terminate any dangling output pins; comment out (not delete) the stock example root blocks (everything at the root not tagged `FLAT_HARNESS` and not `TxRxComposite`).

- [ ] Step 1: write the three files.
- [ ] Step 2: run `derive.sh` -> derived model; `flat_diff` derived vs exported prod -> STRUCTURE EQUAL (harness/annotations excluded by construction; Display/Terminator differences from the manual edit are reconciled by the delete-list).
- [ ] Step 3: adopt the derived model as `prod/commhdlQPSKTxRxLoopback.slx`; commit `modem/prod: scripted derivation from dev (derive.sh, prod_cleanup delete-list)`.

### Task 4: gates on prod

- [ ] Step 1: `make_edit_kit.sh` from prod (scratch), `flat_gate.sh sim` (background unit) -> `result: PASS` with a fresh stamp.
- [ ] Step 2: `flat_gate.sh hdl` -> CHECKHDL PASS fresh, S1 SKIPPED, S1B PASS fresh.
- [ ] Step 3: record both in `prod/DERIVATION.txt`.

### Task 5: docs, READMEs, PR

- [ ] Step 1: `modem/README.md` (root index rewritten for the split), `modem/dev/README.md`, `modem/prod/README.md` (derivation rule, workflow, how to run gates), `docs/build-and-flash.rst` (new "dev and prod trees" section), `docs/_static/build-flow.html` (paths).
- [ ] Step 2: `sphinx-build -W`, `check_paths`, pytest.
- [ ] Step 3: commit, push branch, open PR against master.

## PR 2 (not in this plan)

`build_image.sh --tree prod` end to end on hdl-dev-2, Gates 1-2, then Gate 3 on the rig.
