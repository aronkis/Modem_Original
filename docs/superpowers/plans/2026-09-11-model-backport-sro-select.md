# Model Back-port with Runtime SRO Select (cleanup sub-project 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Outcome (2026-09-12):** executed 2026-09-11/12. Gate 0 (instrument-complete regen), Gate 1 (combined-tree
> equivalence, exact at both `sro_sign` settings) and Gate 2 (WNS 0.785 ns) PASSED; Gate 3 (silicon) FAILED — every
> path with an sp3 transmitter wedged, both boards were rolled back under the rails and the sp2 pair remains the
> shipped state. Task 15 was cancelled by ruling (the injected flow is the shipped build); the sp3 chain is banked as
> a non-deployed candidate. Evidence: `docs/evidence/sp3/` (SP3_SILICON.md first). Ledger archive:
> `/mnt/onetb/scratch/qpsk-build-trees/sdd-progress-2026-09-11-model-backport-sro-select.md`.

**Goal:** The Simulink model emits the fixed receiver and transmitter directly; one image built with no `--role` passes the sim gates with no netlist injectors, sits on both boards with a runtime `sro_sign` bit, and `modem/fixes/` is deleted.

**Architecture:** Every fix that today is `sed`-ed into HDL Coder output by `modem/fixes/rxfix_inject.py` / `txfix_inject.py` is rebuilt as an env-gated **overlay** of the assemble script (the pattern `modem/framestat_overlay.m` and `modem/instruments/beatila/beatfix_overlay.m` already use: `add_block`/`add_line` on the loaded model, MATLAB Function blocks for stateful logic, `patch_hdlworkflow_*.m` text-splices for the AXI-lite addresses). The two build-time steering variants (R4B EMPTY-edge skip, R4D FULL-edge extra pop) become two permanently present branches into one pop-enable OR, armed by a new `fixctl` bit `sro_sign` (bit 5 of 0x208). The existing Verilator SRO gates are re-pointed at the model-generated tree and run with `sro_sign` forced each way; the injected trees stay in place until the end as the reference the gates compare against. The `hdl` stage of `build_image.sh` becomes the real input to `vivado`; `base`/`fixes` and the base bank go away in the last task. Silicon gating and cut-over follow the sub-project-2 rails.

**Tech Stack:** MATLAB R2025b + HDL Coder on nemo (`/mnt/onetb/MATLAB/R2025b`), Verilator SRO gates in `modem/rtl_sim/` driven by `run_gates.sh` `.legs` tables, python3 (`tomllib`, `pytest`), Vivado 2025.1 on `hdl-dev-2` via `systemd-run --user`, the flash rails in `ops/flash/`, `ops/accept_analyze.py` for PER.

**Spec:** `docs/superpowers/specs/2026-09-09-repo-and-design-cleanup-design.md`, sub-project 3 section (lines 210-270). Research the plan argues from: `docs/evidence/sp2/BASE_REGEN_DIVERGENCE.md` (why the tracked recipe is not instrument-complete), `docs/evidence/rxfix/W1_REGMAP.md` (register semantics), `modem/fixes/fixes.toml` (the list of fixes to re-implement, sha `60f43ba3d5f8f871`).

## Rulings that amend the spec (recorded here so executors do not re-derive them)

1. **Gate 0 precedes Gate 1.** The spec assumes HDL Coder output can be gated directly. It cannot today: the tracked `modem/assemble_jupiter_240k5_byte.m` lacks the BEATFIX/BEATOBS phases the deployed base tree carries (they are inserted by a build-time sed in `modem/instruments/beatila/run_beatfix_build.sh:24,39`), so the regenerated tree has no `fixctl` port and every downstream instrument injection fails. Task 1 promotes those phases into the assemble script. The regenerated tree is then the **new base** for everything after; bit-identity with the sp2 bank is not a target (the bank is model 11.331, the repo is 11.334; 148 LOGIC diffs recorded).
2. **The "run-to-run spread" the spec cites does not exist.** Verilator runs are deterministic; the ledgers record single banked numbers. Task 3 establishes the reference table by running the full ppm matrix on the injected trees, and the equivalence rule is fixed here: identity/structural legs keep their `.legs` criteria unchanged; every loss leg passes when `|loss_model - loss_ref| <= max(0.10 pp, 0.10 * loss_ref)`; every count leg (skips, extras, opens, pop_on_empty, push_on_full) passes within `±10 %` or `±2`, whichever is larger.
3. **TX F3 moves into the model too.** The spec's table lists only receiver fixes, but "no injectors" and "`modem/fixes/` does not exist" require the TX fix (F1+F2+F3, files `Data_Bits_FIFO`, `RAM_Frame_Status_Indicator`, `Bit_Packetizer`, `MATLAB_Function1`) to be a model overlay as well. It is Task 8, gated by the existing txfix gate matrix.
4. **SEQ-BIST is not a model fix.** It is block-design Tcl patching outside the IP core (`modem/fixes/patch_seqbist_tcl.py` + three `.v` on the DUT byte pins, own GPIO slaves). It moves to `modem/instruments/seqbist/` and is applied by the `vivado` stage as a BD instrument; it stays out of the Simulink model. The spec's "Instruments ... SEQ-BIST" row is satisfied by "tracked, no netlist text injection".
5. **The register manifest survives the deletion of `modem/fixes/`.** `gen_regmap.py` and the witness/control tables move to `modem/regmap/` (`regmap.toml`); the injector chain sections (`[chain]`, `[roles.*]`, `files=`, `gates=`) are dropped. The R4D swapped-order md5 exception stays (the rollback image `9acbe2ebe1db` still exists on 146).
6. **`sro_sign` is written from a per-board config with a measured cross-check, not from a measurement alone.** `ops/profiles/sro_sign.conf` holds the value per board IP (148 → 0 EMPTY-edge, 146 → 1 FULL-edge, the sp2 role assignment). `bringup_r2r3.sh` writes it after every arm and prints a WARNING when the CFC-residual sign check disagrees. Rationale: a mis-derived sign silently returns the comb; Gate 3's bit-swap test is what proves the bit works.
7. **Stop rule (spec "Stated risk"), made operational.** If Task 9's full matrix diverges and two fix iterations (Task 9 rounds) do not find the cause, the plan stops after Task 9: the sp2 pair stays deployed, `docs/evidence/sp3/GATE1_DIVERGENCE.md` is written, Tasks 10-15 are not run, and the branch is left with the overlays in place behind their env gates (byte-identical HDL when unset, so nothing regresses).
8. **Timing floor.** Gate 2 uses the spec's wording literally: post-route intra-clock WNS on `axi_adrv9001_adc_1_clk` must be `>= 0.105 - 0.1 = 0.005 ns` (the rxfixpad reference margin minus 0.1), checked with `modem_wns.py --min 0.005`. The sp2 values (0.447 / 0.785) are recorded beside it but are not the floor.

## Global Constraints

- Branch `per-under-1pct-2026-07`; every commit `git commit -s`; push to `origin` after each commit. Never `git add -A`. Nothing over 20 MiB is committed.
- Every overlay is env-gated with an early return (`if isempty(getenv('QPSK_RXFIX')), return; end`) so an unset-env build is byte-identical HDL to today's regen (the G0 idiom, `modem/framestat_overlay.m:94-96`). Every overlay is idempotent (re-running on a patched model is a no-op) and fails loudly on a missing anchor (`assert`/`error`, never silent).
- MATLAB runs on nemo only, under `systemd-run --user --collect` with `timeout 5400`, log to a file, artifact post-check (the `hdl_prj_jupiter_composite/hdlsrc/.../TxRxCompo_ip_src_*.v` set). Never poll in the foreground; watch with a background loop. A regen takes ~22 min (`BASE_REGEN_DIVERGENCE.md` §2).
- Sim gates run through `run_gates.sh` (systemd-run legs, content-keyed `.ok` reuse). `SRO_SIM_DIR` is the bank `/mnt/onetb/scratch/qpsk-build-trees/sro_sim`; never write into it (the bank pin trips).
- The injected trees `modem/rtl_sim/s1_rtl_rxfix_*`, `s1_rtl_bs*`, `s1_rtl_pad`, `s1_rtl_txfix_*` and the kits are the **reference** until Task 15 deletes the injectors; do not delete or modify them earlier.
- Vivado runs only on `hdl-dev-2` (`/opt/Xilinx/2025.1/Vivado/bin`, 8 cores). Build under `/mnt/disk2/scratch/qpsk-builds` (`--remote-base`), never on top of `~/qpsk-builds/*_build_ref`. `systemd-run --user`, `timeout 14400`, background watcher, artifact post-check. `build_txfix.sh --dry` is positional.
- Timing gate: `modem/fixes/modem_wns.py` (moves to `modem/gates/` in Task 11) post-route intra-clock WNS on `axi_adrv9001_adc_1_clk`, floor 0.005 ns (ruling 8).
- Flashes are pre-authorised: run `ops/flash/flash_148_txfix.sh` then `flash_146_txfix.sh` yourself, one board at a time, `FLASH_BAK` = the image on the board (sp2A `3e7f4232a3b5` / sp2B `d94b4df391a1`), rollback `.bak` verified by the rail. Both rails now own `SENTINEL_STOP` (`SS_MINE`). Never mode-1 arm 146 (`arm148_mode1.sh` refuses it). The 146 gate is health + R4D decode + credited PER windows.
- Rig rules: IPs `10.0.0.148` / `10.0.0.146` only (HOSTS.md's "jupiter A/B" labels are the opposite of the image roles); never poll faster than 1 s; never kill an arm in flight; never stop `sentinel-*` / `sentinelkeeper-105921` units; take the rig lock via `ops/sim_repro/riglock.sh` (`rig_lock`/`rig_unlock`, ownership-safe since 0bac0192).
- Any PER number reported carries the exact command, the sample count, and the statement that lost frames are in the denominator (`accept_analyze.py`: `per = miss/span`). Acceptance (spec): forward `<= 2 x 0.079 % = 0.158 %` and reverse `<= 0.191 %` on a credited `>= 10 min` window, no new comb line (`ops/comb/comb_period_ms.py` shows no new lag).
- At every commit: `tools/check_paths.sh` prints `CHECK_PATHS_OK`; `python3 modem/fixes/gen_regmap.py --check` (path moves in Task 10) exits 0; `make -C host clean all test` passes; `sphinx-build -W` passes; `python3 -m pytest -p no:libiio modem ops -q` passes.
- Never edit a script a live rig unit runs (`launch_rig_unit.sh` runs frozen copies). `hdl-dev-2` is in `~/.claude/HOSTS.md` (infra PR #50).

---

## File map

| Action | Path | Responsibility |
|---|---|---|
| Modify | `modem/assemble_jupiter_240k5_byte.m` | phases 2.20 (BEATOBS/BEATFIX, env-gated) and 2.21 (RXFIX overlays, env-gated `QPSK_RXFIX`), plus the `patch_hdlworkflow_*` calls |
| Create | `modem/rxfix/rxfix_w1_overlay.m` | W1 census: six valid counters, occupancy/pointer packer, freeze-gated shadow bank, ports up to the composite |
| Create | `modem/rxfix/rxfix_steer_overlay.m` | Rate Handle steering: pcEnd window, lock-after-8, skip branch, extra-pop branch, `sro_sign` decode, witness words 0x234/0x238/0x25C |
| Create | `modem/rxfix/rxfix_r1_overlay.m` | Preamble Detector realignment FIFO pop indexed by occupancy == 12333 |
| Create | `modem/rxfix/rxfix_bs_overlay.m` | byte-seam census 0x23C-0x258 (every-clk sampling, freeze shared with W1) |
| Create | `modem/rxfix/rxfix_pad_overlay.m` | ByteSerializer chart edit: pad truncated frames to 191 words with a 3-deep real-word queue |
| Create | `modem/rxfix/txfix_f3_overlay.m` | TX F1+F2+F3: pop-clear guard, saturating frameCount, `dataReady & ~fullRAM`, saturating occupancy |
| Create | `modem/rxfix/patch_hdlworkflow_rxfix.m` | AXI-lite mappings for 0x214-0x25C (idempotent text splice, block-existence guarded) |
| Create | `modem/rxfix/README.md` | which overlay implements which former injector, env gates, register table pointer |
| Modify | `modem/fixes/build_base_tree.sh` → later `modem/build_hdl.sh` | exports the env set, runs MATLAB under systemd-run, produces the regen tree, equivalence diff becomes optional evidence |
| Create | `modem/rtl_sim/wrap_byte_sro_model.v`, `wrap_txkick_model.v` | sim wrappers that drive the composite `fixctl` port from a `FIXCTL_INIT` parameter |
| Modify | `modem/rtl_sim/make_sro_trees.sh` | `--from-regen DIR` populates the `s1_rtl_*` gate dirs from one model tree (no injection) |
| Create | `modem/rtl_sim/tree_marker.sh` | provenance check accepting either the injector token or the model block module |
| Modify | `modem/rtl_sim/build_sro_{w1,rxfix4b,rxfix4d,rxfix4dr1,bs,pad}.sh`, `build_txkick_sim.sh` | `TREE=`/`FIXCTL=` overrides; marker check via `tree_marker.sh` |
| Create | `modem/fixes/gates/reference_loss.toml` → `modem/gates/reference_loss.toml` | the ppm matrix reference numbers measured on the injected trees (Task 3) |
| Create | `modem/gates/model_matrix.legs` | the Gate 1 matrix: every variant leg at 0/±2.5/±10 ppm, both `sro_sign`, scored against `reference_loss.toml` |
| Create | `modem/gates/score_matrix.py` + `modem/gates/tests/test_score_matrix.py` | applies ruling 2's tolerance rule |
| Move | `modem/fixes/{run_gates.sh,gates/,modem_wns.py,tests/test_modem_wns.py}` → `modem/gates/` | gate runner and timing gate outlive the injectors |
| Move | `modem/fixes/{gen_regmap.py,tests/test_gen_regmap.py}` → `modem/regmap/`; new `modem/regmap/regmap.toml` | register manifest without the injector chain; adds `sro_sign` and 0x25C |
| Modify | `host/qpsk_fixregs.h`, `host/modem_status/ms_regmap_fixes.inc` (generated), `host/modem_status/ms_regmap.c`, `host/modem_status/ms_panels.c`, `host/modem_status/test_modem_status.c` | `sro_sign` bit + active-edge display |
| Modify | `modem/build_image.sh` | stages `hdl seqbist gates vivado`; no `--role`; single image `BOOT.BIN.jupiter.<tag>.<md5>` |
| Move | `modem/fixes/{seqbist_kit.sh,patch_seqbist_tcl.py}` + the three `.v` → `modem/instruments/seqbist/` | BD instrument, applied by the vivado stage |
| Create | `ops/profiles/sro_sign.conf`; Modify `ops/bringup_r2r3.sh`, `ops/restore_known_good.sh` | write `sro_sign` after every arm, CFC cross-check |
| Create | `docs/evidence/sp3/{GATE0_REGEN.md,REFERENCE_MATRIX.md,GATE1_EQUIVALENCE.md,GATE2_TIMING.md,SP3_SILICON.md}` | evidence per gate |
| Modify | `docs/byte-plane.rst`, `docs/debug-instruments.rst`, `docs/build-and-flash.rst`, `docs/provenance.rst`, `docs/bringup.rst`, `images/CURRENT.txt`, `images/README.md`, `tools/check_paths.sh`, `.github/workflows/docs.yml` | docs, provenance, CI paths |
| Delete (Task 15) | `modem/fixes/` entirely, `modem/rtl_sim/s1_rtl_rxfix_*` etc. (untracked), `modem/rtl_sim/build_sro_rxfix4d.sh` (R4D-alone variant), `modem/instruments/beatila/run_beatfix_build.sh`'s sed block | the injected flow; archive tag `archive/pre-cleanup-2026-09-09` holds it |

---

### Task 1: Gate 0 — make the tracked recipe instrument-complete and regenerate the base

**Files:**
- Modify: `modem/assemble_jupiter_240k5_byte.m:44-48` (patch_hdlworkflow calls) and `:295-298` (after the framestat phase)
- Modify: `modem/instruments/beatila/run_beatfix_build.sh:24-45` (delete the python sed block; export the env vars only)
- Modify: `modem/fixes/build_base_tree.sh:60-70` (export `QPSK_BEATFIX=1 QPSK_BEATOBS=1 QPSK_FRAMESTAT=1`)
- Create: `modem/tests/test_assemble_phases.py`, `docs/evidence/sp3/GATE0_REGEN.md`

**Interfaces:**
- Consumes: `beatobs_overlay(sys, loop)`, `beatfix_overlay(sys, loop)`, `patch_hdlworkflow_beatfix('hdlworkflow_loopback.m')` in `modem/instruments/beatila/` (on the MATLAB path via `build_variant_byte.m`'s `addpath` — verify with `grep -n addpath modem/build_variant_byte.m`; if `modem/instruments/beatila` is not on the path, add `addpath(fullfile(fileparts(mfilename('fullpath')),'instruments','beatila'))` there).
- Produces: a regen tree at `/mnt/onetb/scratch/qpsk-build-trees/regen/jupiter_byte_sp3_build/` whose `TxRxCompo_ip_src_Receiver.v` has the `beatfix_viol_latch` port and whose `TxRxCompo_ip_addr_decoder.v` decodes `0x208`; the ddrcap/ddrcap2 instrument injections succeed (`BASE_REGEN_NOT_INSTRUMENT_COMPLETE` absent). This tree is `REGEN_BASE` for Tasks 2-9.

- [ ] **Step 1: Write the failing test** (`modem/tests/test_assemble_phases.py`)

```python
import pathlib, re
M = pathlib.Path(__file__).resolve().parents[1]

def test_assemble_calls_beat_overlays_as_env_gated_phase():
    s = (M / "assemble_jupiter_240k5_byte.m").read_text()
    i = s.index("framestat_overlay(sys, loop);")
    tail = s[i:]
    assert "beatobs_overlay(sys, loop);" in tail and "beatfix_overlay(sys, loop);" in tail
    # gated on the env var, not unconditional
    assert re.search(r"getenv\('QPSK_BEATOBS'\)", s) and re.search(r"getenv\('QPSK_BEATFIX'\)", s)

def test_assemble_patches_hdlworkflow_for_beatfix():
    s = (M / "assemble_jupiter_240k5_byte.m").read_text()
    assert "patch_hdlworkflow_beatfix('hdlworkflow_loopback.m');" in s

def test_run_beatfix_build_no_longer_seds_assemble():
    s = (M / "instruments/beatila/run_beatfix_build.sh").read_text()
    assert "assemble hooked" not in s and "s.replace(a, a+" not in s

def test_build_base_tree_exports_instrument_env():
    s = (M / "fixes/build_base_tree.sh").read_text()
    for v in ("QPSK_BEATFIX=1", "QPSK_BEATOBS=1", "QPSK_FRAMESTAT=1"):
        assert f"export {v}" in s
```

- [ ] **Step 2: Run it** — `python3 -m pytest -p no:libiio modem/tests/test_assemble_phases.py -q` → 4 FAIL.

- [ ] **Step 3: Promote the phases.** In `assemble_jupiter_240k5_byte.m`, directly after the framestat block (`if ~isempty(getenv('QPSK_FRAMESTAT')) ... framestat_overlay(sys, loop); ... end`) insert:

```matlab
% --- phase 2.20: BEAT observability + BEATFIX phase contract (env-gated, G0: unset => byte-identical HDL)
% Promoted from modem/instruments/beatila/run_beatfix_build.sh's build-time sed (2026-09-11,
% docs/evidence/sp2/BASE_REGEN_DIVERGENCE.md §3): the deployed base tree carries these and the
% tracked recipe did not.
if ~isempty(getenv('QPSK_BEATOBS'))
    fprintf('=== applying BEAT observability overlay (env-gated QPSK_BEATOBS) ===\n');
    beatobs_overlay(sys, loop);
end
if ~isempty(getenv('QPSK_BEATFIX'))
    fprintf('=== applying BEATFIX overlay (env-gated QPSK_BEATFIX) ===\n');
    beatfix_overlay(sys, loop);
end
```

and after `patch_hdlworkflow_loopgain('hdlworkflow_loopback.m');   % C3: ...` (line 48) insert:

```matlab
patch_hdlworkflow_beatfix('hdlworkflow_loopback.m');   % BEATFIX: fixctl 0x208 + viol 0x20C/0x210 (env-gated inside)
```

In `run_beatfix_build.sh` (and its byte-identical twin `run_beatila_build.sh`) delete the `python3 - "$FRESH/assemble_jupiter_240k5_byte.m" <<'PYEOF' ... PYEOF` block; keep the `export QPSK_BEATOBS=1` / `QPSK_BEATFIX=1` lines and add a comment `# the assemble script carries phase 2.20 itself since 2026-09-11`. In `build_base_tree.sh` next to `export QPSK_LEAN=1` add `export QPSK_BEATFIX=1; export QPSK_BEATOBS=1; export QPSK_FRAMESTAT=1` with a comment citing BASE_REGEN_DIVERGENCE §4 (the bank is LEAN + BEATFIX + BEATOBS + FRAMESTAT: confirm FRAMESTAT by `grep -l FrameStatFifo /mnt/onetb/scratch/qpsk-build-trees/base/jupiter_byte_ddrcap2_build/hdl_prj_jupiter_composite/hdlsrc/commhdlQPSKTxRxLoopback/*.v`; if absent, do NOT export it and record that in the evidence).

- [ ] **Step 4: Run the tests** → 4 PASS.

- [ ] **Step 5: Regenerate.** From the repo root:

```bash
mkdir -p /mnt/onetb/scratch/qpsk-build-trees/regen
systemd-run --user --collect --unit sp3-gate0-$(date +%H%M%S) -p TimeoutStartSec=6000 \
  --working-directory=/mnt/onetb/scratch/qpsk-jupiter-modem \
  bash -c 'modem/fixes/build_base_tree.sh /mnt/onetb/scratch/qpsk-build-trees/regen > /mnt/onetb/scratch/qpsk-build-trees/regen/gate0.log 2>&1'
```

Watch in the background (`until grep -q "BASE_REGEN_DONE\|BASE_REGEN_FAILED" .../gate0.log; do sleep 60; done`). Expected in the log: `BASE_REGEN_DONE`, no `BASE_REGEN_INJECT_FAILED`, no `DDRCAP_BD_ABORT`, `BASE_REGEN_NOT_INSTRUMENT_COMPLETE` absent. Post-check:

```bash
R=/mnt/onetb/scratch/qpsk-build-trees/regen/jupiter_byte_ddrcap2_build.regen/hdl_prj_jupiter_composite/hdlsrc/commhdlQPSKTxRxLoopback
grep -c beatfix_viol_latch $R/TxRxCompo_ip_src_Receiver.v          # >= 1
grep -c "14'b00000010000010" $R/TxRxCompo_ip_addr_decoder.v         # >= 1 (0x208 decode)
ls $R | wc -l                                                         # ~= 308 (bank count)
```

Then `mv .../jupiter_byte_ddrcap2_build.regen /mnt/onetb/scratch/qpsk-build-trees/regen/jupiter_byte_sp3_build` (this is `REGEN_BASE`).

- [ ] **Step 6: Evidence.** Write `docs/evidence/sp3/GATE0_REGEN.md`: the command, the unit name, wall time, the three post-check numbers, the `BASE_RTL_EQUIV files= diff=` line and the class histogram vs the sp2 bank (expected to still show LOGIC diffs from the 11.331→11.334 model move — say so, and say why it is not the gate).

- [ ] **Step 7: Commit**

```bash
git add modem/assemble_jupiter_240k5_byte.m modem/instruments/beatila/run_beatfix_build.sh modem/instruments/beatila/run_beatila_build.sh modem/fixes/build_base_tree.sh modem/tests/test_assemble_phases.py docs/evidence/sp3/GATE0_REGEN.md
git commit -s -m "sp3 gate 0: assemble carries the BEATOBS/BEATFIX phase itself; regen is instrument-complete"
git push
```

---

### Task 2: Gate harness for model-generated trees

**Files:**
- Create: `modem/rtl_sim/wrap_byte_sro_model.v` (copy of `wrap_byte_sro.v`), `modem/rtl_sim/wrap_txkick_model.v` (copy of the wrapper `build_txkick_sim.sh:32` names), `modem/rtl_sim/tree_marker.sh`, `modem/rtl_sim/tests/test_tree_marker.sh`
- Modify: `modem/rtl_sim/make_sro_trees.sh`, `modem/rtl_sim/build_sro_w1.sh`, `build_sro_rxfix4b.sh`, `build_sro_rxfix4d.sh`, `build_sro_rxfix4dr1.sh`, `build_sro_bs.sh`, `build_sro_pad.sh`, `build_txkick_sim.sh`, `build_txrate_sim.sh`

**Interfaces:**
- Produces: `make_sro_trees.sh --from-regen <REGEN_BASE> [VARIANTS...]` populates `modem/rtl_sim/s1_rtl_model/` (one flat copy of `<REGEN_BASE>/hdl_prj_jupiter_composite/hdlsrc/commhdlQPSKTxRxLoopback/*.v` with the `TxRxCompo_ip_src_` prefix stripped from file names AND module names, the same transform the pristine `s1_rtl` lineage has — check `head -3 modem/rtl_sim/s1_rtl_rxfix_R4B/Rate_Handle.v` for the module-name form) and writes `s1_rtl_model/RXFIX_ORIGIN` = `model <REGEN_BASE> <git sha> <date>`.
- Every `build_sro_*.sh` honours `TREE=<dir>` (default unchanged) and `FIXCTL=<hex>` (default `0`); when `TREE` ends in `s1_rtl_model` the script verilates `wrap_byte_sro_model.v` with `-GFIXCTL_INIT=32'h$FIXCTL` and the obj dir becomes `obj_byte_sro_<variant>_model_<FIXCTL>`.
- `tree_marker.sh <tree> <VARIANT>` exits 0 when either the injector token (`RXFIX_<VARIANT>` in the variant's file) or the model origin file plus the variant's overlay module file (table below) is present; prints `TREE_MARKER <tree> <VARIANT> injector|model`.

| VARIANT | injector token file | model module file |
|---|---|---|
| W1 | `Rate_Handle.v` `RXFIX_W1` | `RxW1Census.v` |
| R4B | `Rate_Handle.v` `RXFIX_R4B` | `RxSteer.v` |
| R4D | `Rate_Handle.v` `RXFIX_R4D` | `RxSteer.v` |
| R4DR1 | `Preamble_Detector.v` `RXFIX_R1` | `PdPopIndex.v` |
| BS | `ByteSerializer.v` `RXFIX_BS` | `BsSeamCensus.v` |
| PAD | `ByteSerializer.v` `RXFIX_PAD` | `BsPad.v` (or the `ByteSerializer.v` containing `padCount`) |
| F3 | `Bit_Packetizer.v` `TXFIX_F3` | `Bit_Packetizer.v` containing `fullRAM` in the `dataReady` assign |

The model module names are the MLFB block names Tasks 4-8 must use exactly (HDL Coder names the generated module after the block).

- [ ] **Step 1: Write the failing test** (`modem/rtl_sim/tests/test_tree_marker.sh`)

```bash
#!/bin/bash
# tree_marker.sh must accept an injector tree, a model tree, and refuse an empty one.
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); f=0
mkdir -p $T/inj $T/mod $T/none
echo "// RXFIX_R4B steering" > $T/inj/Rate_Handle.v
echo "model /x abc 2026" > $T/mod/RXFIX_ORIGIN; echo "module RxSteer;" > $T/mod/RxSteer.v; echo "" > $T/mod/Rate_Handle.v
echo "" > $T/none/Rate_Handle.v
$H/tree_marker.sh $T/inj R4B | grep -q "injector$" || { echo FAIL inj; f=1; }
$H/tree_marker.sh $T/mod R4B | grep -q "model$"    || { echo FAIL mod; f=1; }
$H/tree_marker.sh $T/none R4B >/dev/null 2>&1 && { echo FAIL none; f=1; }
rm -rf $T; [ $f = 0 ] && echo TREE_MARKER_TEST_OK; exit $f
```

- [ ] **Step 2: Run it** → `tree_marker.sh: No such file`.

- [ ] **Step 3: Implement `tree_marker.sh`**

```bash
#!/bin/bash
# tree_marker.sh <tree> <VARIANT> -- provenance check for a gate tree. Accepts the injector
# token (RXFIX_<V> / TXFIX_F3 in the variant's file) OR a model-generated tree (RXFIX_ORIGIN
# file + the overlay's module file). Exit 1 and TREE_MARKER_MISSING otherwise.
set -u; T=$1; V=$2
case $V in
  W1)    F=Rate_Handle.v;       TOK=RXFIX_W1;  MOD=RxW1Census.v ;;
  R4B)   F=Rate_Handle.v;       TOK=RXFIX_R4B; MOD=RxSteer.v ;;
  R4D)   F=Rate_Handle.v;       TOK=RXFIX_R4D; MOD=RxSteer.v ;;
  R4DR1) F=Preamble_Detector.v; TOK=RXFIX_R1;  MOD=PdPopIndex.v ;;
  BS)    F=ByteSerializer.v;    TOK=RXFIX_BS;  MOD=BsSeamCensus.v ;;
  PAD)   F=ByteSerializer.v;    TOK=RXFIX_PAD; MOD=BsPad.v ;;
  F3)    F=Bit_Packetizer.v;    TOK=TXFIX_F3;  MOD=Bit_Packetizer.v ;;
  *) echo "TREE_MARKER_BAD_VARIANT $V"; exit 2 ;;
esac
if grep -q "$TOK" "$T/$F" 2>/dev/null; then echo "TREE_MARKER $T $V injector"; exit 0; fi
if [ -f "$T/RXFIX_ORIGIN" ] && [ -f "$T/$MOD" ]; then
  if [ "$V" = F3 ] && ! grep -q "fullRAM" "$T/$MOD"; then echo "TREE_MARKER_MISSING $T $V (model tree without the F3 dataReady gate)"; exit 1; fi
  echo "TREE_MARKER $T $V model"; exit 0
fi
echo "TREE_MARKER_MISSING $T $V"; exit 1
```

- [ ] **Step 4: Run the test** → `TREE_MARKER_TEST_OK`.

- [ ] **Step 5: Wrappers.** `cp modem/rtl_sim/wrap_byte_sro.v modem/rtl_sim/wrap_byte_sro_model.v`; in the copy add `parameter [31:0] FIXCTL_INIT = 32'h0;` after `module wrap_byte_sro_model` (rename the module) and connect the composite's `fixctl` input: find the `TxRxComposite` instantiation in the wrapper and add `.fixctl(FIXCTL_INIT),`. Confirm the port name with `grep -n "input.*fixctl" <REGEN_BASE>/.../TxRxCompo_ip_src_TxRxComposite.v`. Repeat for the txkick wrapper. Then in each `build_sro_*.sh` replace the hard-coded `VD=` with:

```bash
TREE=${TREE:-$KIT/rtl_sim/s1_rtl_rxfix_R4B}; VD=$TREE; FIXCTL=${FIXCTL:-0}
if [ "$(basename "$TREE")" = s1_rtl_model ]; then
  WRAP=wrap_byte_sro_model.v; OBJ=obj_byte_sro_rxfix4b_model_$FIXCTL; GPARAM="-GFIXCTL_INIT=32'h$FIXCTL"
else
  WRAP=wrap_byte_sro4b.v; OBJ=obj_byte_sro_rxfix4b; GPARAM=""
fi
```

(per script: its own default tree, wrapper and obj name), use `$WRAP $GPARAM` and `-Mdir $OBJ` in the verilator line, and replace the `grep -q 'RXFIX_R4B' "$VD/Rate_Handle.v" || ...` marker line with `"$KIT/rtl_sim/tree_marker.sh" "$VD" R4B || exit 1`. The verilate-log wrapper-name asserts (lines 18-24) must accept `wrap_byte_sro_model.v` when `$WRAP` is the model wrapper. `build_sro_rxfix4b.sh`'s `+define+RXFIX_R4B` stays (it only affects the wrapper).

- [ ] **Step 6: `make_sro_trees.sh --from-regen`.** Add the option: when given, skip injection entirely, `rsync` the regen hdlsrc into `$OUT/s1_rtl_model/`, strip the `TxRxCompo_ip_src_` prefix from file names (`for f in TxRxCompo_ip_src_*.v; do mv "$f" "${f#TxRxCompo_ip_src_}"; done`) and module names (`sed -i 's/\bTxRxCompo_ip_src_//g' *.v`), write `RXFIX_ORIGIN`, print `SRO_TREE_MODEL $OUT/s1_rtl_model files=<n>`. Guard: refuse if the regen has no `TxRxCompo_ip_src_TxRxComposite.v`.

- [ ] **Step 7: Prove the harness on the injected trees is unchanged.** `cd modem/rtl_sim && bash build_sro_rxfix4b.sh` (default `TREE`) → same `obj_byte_sro_rxfix4b/Vwrap_byte_sro` binary; run one leg: `./obj_byte_sro_rxfix4b/Vwrap_byte_sro rx $SRO/n_p000.iq 21114096 8400 /tmp/claude-1000/.../r4b_p000 2 0` and `diff` its `_res.txt` against the sp2 gate work copy `/mnt/onetb/scratch/sp2_gates/work/build_sro_rxfix4b/r4b_p000_res.txt` → identical. Then `bash make_sro_trees.sh --from-regen <REGEN_BASE>` and `TREE=$PWD/s1_rtl_model FIXCTL=0 bash build_sro_w1.sh` → verilates (expected: `tree_marker` FAILS with `TREE_MARKER_MISSING ... W1` because no overlay exists yet — that is the correct state; record it).

- [ ] **Step 8: Commit** `git add modem/rtl_sim/{wrap_byte_sro_model.v,wrap_txkick_model.v,tree_marker.sh,tests/test_tree_marker.sh,make_sro_trees.sh,build_sro_*.sh,build_txkick_sim.sh,build_txrate_sim.sh}` ; `git commit -s -m "sp3: gate harness accepts model-generated trees (TREE=, FIXCTL=, tree_marker)"`; `git push`.

---

### Task 3: The reference matrix (the numbers Gate 1 compares against)

**Files:**
- Create: `modem/fixes/gates/reference_loss.toml`, `modem/fixes/gates/reference_matrix.legs`, `modem/fixes/score_matrix.py`, `modem/fixes/tests/test_score_matrix.py`, `docs/evidence/sp3/REFERENCE_MATRIX.md`
- Modify: `modem/fixes/run_gates.sh` (accept `--legs FILE` to run a named table outside the manifest)

**Interfaces:**
- Produces: `reference_loss.toml` with one table per `(variant, stimulus)`:

```toml
[ref."R4B/n_m10"]   # variant R4B, stimulus n_m10.iq (-10 ppm), injected tree, FIXCTL n/a
loss_pct = 0.48
skips = 30
extras = 0
opens = 412
pop_on_empty = 0
push_on_full = 28
nsamp = 21114096
tree_sha = "<sha256 of the injected tree's Rate_Handle.v>"
```

- `score_matrix.py --ref reference_loss.toml --run <dir> --map "<variant>/<stim>=<prefix>"...` prints one `MATRIX <variant>/<stim> PASS|FAIL loss=<m> ref=<r> tol=<t> ...` line per pair and `MATRIX_EXIT 0|1`, applying ruling 2 exactly: loss tol = `max(0.10, 0.10*ref)` pp; counts tol = `max(2, ceil(0.10*ref))`.
- Stimuli (all in `$SRO`): `n_p000.iq`, `n_p2p5.iq`, `n_m2p5.iq`, `n_p10.iq`, `n_m10.iq` (checked 2026-09-11: the bank holds `n_p000.iq n_m2p5.iq n_p10.iq n_m10.iq n_m40.iq` but NO `n_p2p5.iq`. Generate `n_p2p5.iq` with the same resampling recipe that produced `n_m2p5.iq` — find it with `grep -rn 'm2p5' modem/rtl_sim/sro_score docs/evidence/comb | head` and mirror the sign — write it to `$SRO/n_p2p5.iq`, then re-pin `modem/fixes/bank.sha256`'s sro_sim listing line deliberately (recompute with the command in its header) in the same commit, stating the reason).

- [ ] **Step 1: Test for the scorer** (`modem/fixes/tests/test_score_matrix.py`)

```python
import subprocess, sys, pathlib, textwrap
H = pathlib.Path(__file__).resolve().parents[1]

def run(tmp, ref, res):
    (tmp/"ref.toml").write_text(ref); (tmp/"x_res.txt").write_text(res)
    return subprocess.run([sys.executable, str(H/"score_matrix.py"), "--ref", str(tmp/"ref.toml"),
                           "--run", str(tmp), "--map", "R4B/n_m10=x"], text=True, capture_output=True)

REF = 'ref = { "R4B/n_m10" = { loss_pct = 0.48, skips = 30, extras = 0 } }\n'

def test_within_tolerance_passes(tmp_path):
    r = run(tmp_path, REF, "LOSS 0.55 %\nr3_skips=32 r3_extras=0\n")
    assert "MATRIX R4B/n_m10 PASS" in r.stdout and "MATRIX_EXIT 0" in r.stdout

def test_loss_outside_tolerance_fails(tmp_path):
    r = run(tmp_path, REF, "LOSS 0.70 %\nr3_skips=30 r3_extras=0\n")   # 0.22 pp > max(0.10, 0.048)
    assert "MATRIX R4B/n_m10 FAIL" in r.stdout and "MATRIX_EXIT 1" in r.stdout

def test_count_tolerance_floor_is_two():
    from score_matrix import count_tol, loss_tol
    assert count_tol(0) == 2 and count_tol(30) == 3 and count_tol(412) == 42
    assert abs(loss_tol(0.48) - 0.10) < 1e-9 and abs(loss_tol(4.99) - 0.499) < 1e-9
```

- [ ] **Step 2: Run** → ImportError / no such file.

- [ ] **Step 3: Implement `score_matrix.py`** (parse `LOSS <f> %` and `r3_skips=<n> r3_extras=<n>` from `<prefix>_res.txt` — the exact tokens the `.legs` criteria already grep, e.g. `build_sro_rxfix4b.legs:50`; `opens`, `pop_on_empty`, `push_on_full` from the same file when present; missing keys are skipped, not failed). Functions `loss_tol(ref)`, `count_tol(ref)`, `score(ref_table, run_dir, mapping) -> list[(key, ok, detail)]`.

- [ ] **Step 4: Run** → 3 PASS.

- [ ] **Step 5: `run_gates.sh --legs FILE`.** Add the option: when given, `GATES` is the single table `FILE` (key = its basename), `--role` optional. Keep everything else (systemd-run legs, `.ok` reuse).

- [ ] **Step 6: Write `reference_matrix.legs`** — for each injected variant tree (W1, R4B, R4DR1 = the two shipped role variants plus W1 alone; R4D-alone is refuted and excluded; BS and PAD have no ppm dependence and are covered by their own tables) and each stimulus `n_p000 n_p2p5 n_m2p5 n_p10 n_m10`, one run leg in the exact ledger shape:

```
r4b_n_m10|$RTL/obj_byte_sro_rxfix4b/Vwrap_byte_sro rx $SRO/n_m10.iq 21114096 8400 r4b_n_m10 2 0|test -s r4b_n_m10_res.txt
```

plus one final `collect|python3 $HERE/collect_reference.py --out $HERE/gates/reference_loss.toml <prefixes...>|test -s $HERE/gates/reference_loss.toml` leg (write `collect_reference.py`: reads each `<prefix>_res.txt`, emits the toml table above, `tree_sha` from the tree file the variant names).

- [ ] **Step 7: Run it** — `modem/fixes/run_gates.sh --legs modem/fixes/gates/reference_matrix.legs` under a background watcher (15 legs × ~10-25 min each; runs in parallel units only if you split the table — keep it serial, budget ~4 h). Post-check: `python3 -c "import tomllib;d=tomllib.load(open('modem/fixes/gates/reference_loss.toml','rb'));print(len(d['ref']))"` → 15. Sanity against the ledgers: `R4B/n_m10` loss ≈ 0.48, skips ≈ 30; `R4B/n_p10` ≈ 6.65; `R4DR1/n_p10` ≤ 1.00; `R4DR1/n_p000` = 0.00 (these are the banked numbers in the `.legs` headers; a mismatch > tolerance means the harness, not the design, is wrong — stop and fix Task 2).

- [ ] **Step 8: Evidence + commit.** `docs/evidence/sp3/REFERENCE_MATRIX.md`: the table, commands, unit names, wall time, the tolerance rule verbatim (ruling 2). `git add modem/fixes/gates/{reference_loss.toml,reference_matrix.legs} modem/fixes/{score_matrix.py,collect_reference.py,run_gates.sh} modem/fixes/tests/test_score_matrix.py docs/evidence/sp3/REFERENCE_MATRIX.md`; `git commit -s -m "sp3: reference ppm matrix on the injected trees + tolerance scorer"`; `git push`.

---

### Task 4: W1 census overlay

**Files:**
- Create: `modem/rxfix/rxfix_w1_overlay.m`, `modem/rxfix/patch_hdlworkflow_rxfix.m`, `modem/rxfix/README.md`, `modem/tests/test_rxfix_overlays.py`
- Modify: `modem/assemble_jupiter_240k5_byte.m` (phase 2.21 call, after phase 2.20), `modem/build_variant_byte.m` (`addpath` for `modem/rxfix`), `modem/fixes/build_base_tree.sh` (`export QPSK_RXFIX=1`)

**Interfaces:**
- Consumes: block paths from `beatfix_overlay.m:30-40` (`qrx`, `fts`, `ssy`, `rh = [qrx '/Frequency and Time Synchronizer/Symbol Synchronizer/Rate Handle']`), the `fixctl` uint32 Inport already plumbed Receiver → QPSK Rx by `beatfix_overlay.m:68-79`, `FixCtlDec` (extend it: add output `w1Freeze = bitand(fixctl, uint32(16)) ~= 0` = bit 4).
- Produces: MATLAB Function block `RxW1Census` inside `Rate Handle` (so HDL Coder emits `RxW1Census.v`) with inputs `occ, pushPtr, popPtr, popEmpty, pushFull, vSS, vRH, vCFC, vCS, vPD, vPC, freeze` and outputs `witA, witB, cSS, cRH, cCFC, cCS, cPD, cPC` (uint32), surfaced as eight composite Outports `w1_wita, w1_witb, w1_ss, w1_rh, w1_cfc, w1_cs, w1_pd, w1_pc`, mapped to `x"214"`..`x"230"` by `patch_hdlworkflow_rxfix.m`. Semantics exactly `docs/evidence/rxfix/W1_REGMAP.md`: `witA = {16'b0, occ[5:0], pushPtr[4:0], popPtr[4:0]}`, `witB = {push_on_full[15:0], pop_on_empty[15:0]}`, six wrap-32 valid counters, freeze is a level holding the shadow copy while live counters keep running.
- Signal sources (find with `find_system(rh,'SearchDepth',1,...)` and assert): occupancy = the Rate Handle `FIFO`'s `numEntries`/`Push Counter`−`Pop Counter` (the pair `beatobs_overlay.m:57-100` already taps), `popEmpty`/`pushFull` = the `Validate Input Push Pop` block's outputs of the same names, the six valids = the `validOut` port of Symbol Synchronizer, Rate Handle, CFC (`Frequency and Time Synchronizer/Coarse Frequency Compensator` — confirm the name with `find_system(fts,'SearchDepth',1)`), Carrier Synchronizer, Preamble Detector, Packet Controller (inside `QPSK Rx`).

- [ ] **Step 1: Static tests** (`modem/tests/test_rxfix_overlays.py`; grows in Tasks 5-8)

```python
import pathlib, re
M = pathlib.Path(__file__).resolve().parents[1]
def src(p): return (M / p).read_text()

def test_w1_overlay_is_env_gated_and_idempotent():
    s = src("rxfix/rxfix_w1_overlay.m")
    assert "getenv('QPSK_RXFIX')" in s and "return" in s.split("getenv('QPSK_RXFIX')")[1][:200]
    assert "RxW1Census" in s and "find_system" in s          # idempotency probe by block name

def test_w1_addresses_match_regmap():
    s = src("rxfix/patch_hdlworkflow_rxfix.m")
    for a in ("214","218","21C","220","224","228","22C","230"):
        assert f'x"{a}"' in s

def test_assemble_calls_rxfix_phase_after_beatfix():
    s = src("assemble_jupiter_240k5_byte.m")
    assert s.index("beatfix_overlay(sys, loop);") < s.index("rxfix_w1_overlay(sys, loop);")
    assert "getenv('QPSK_RXFIX')" in s
```

- [ ] **Step 2: Run** → FAIL (files missing).

- [ ] **Step 3: Write the overlay.** Skeleton (fill every `add_block`/`add_line` against the asserted anchors; the MLFB body is the census):

```matlab
function rxfix_w1_overlay(sys, base)
% rxfix_w1_overlay -- W1 RX census (formerly modem/fixes/rxfix_inject.py W1). Env-gated: QPSK_RXFIX.
% Registers 0x214-0x230, freeze = fixctl bit 4 (level). See docs/evidence/rxfix/W1_REGMAP.md.
if isempty(getenv('QPSK_RXFIX')), return; end
qrx = [base '/Receiver/QPSK Rx'];
fts = [qrx '/Frequency and Time Synchronizer'];
ssy = [fts '/Symbol Synchronizer'];
rh  = [ssy '/Rate Handle'];
if ~isempty(find_system(rh,'SearchDepth',1,'Name','RxW1Census')), fprintf('rxfix_w1: already applied\n'); return; end
need = {rh, [rh '/FIFO'], [rh '/FIFO/Validate Input Push Pop'], [fts '/Preamble Detector'], [qrx '/FixCtlDec']};
for i = 1:numel(need), assert(~isempty(find_system(need{i})), 'rxfix_w1: anchor missing: %s', need{i}); end
blk = add_block('simulink/User-Defined Functions/MATLAB Function', [rh '/RxW1Census'], 'Position', [900 500 1040 700]);
S = sfroot; ch = S.find('Path', [rh '/RxW1Census'], '-isa', 'Stateflow.EMChart');
ch.Script = sprintf([ ...
 'function [witA, witB, cSS, cRH, cCFC, cCS, cPD, cPC] = RxW1Census(occ, pushPtr, popPtr, popEmpty, pushFull, vSS, vRH, vCFC, vCS, vPD, vPC, freeze)\n' ...
 'persistent pof poe c sA sB sC\n' ...
 'if isempty(pof), pof=uint16(0); poe=uint16(0); c=zeros(1,6,''uint32''); sA=uint32(0); sB=uint32(0); sC=zeros(1,6,''uint32''); end\n' ...
 'if pushFull, pof = pof + uint16(1); end\n' ...      % wraps at 16 bits like the injector
 'if popEmpty, poe = poe + uint16(1); end\n' ...
 'v = [vSS vRH vCFC vCS vPD vPC]; for k=1:6, if v(k), c(k) = c(k) + uint32(1); end, end\n' ...
 'wA = bitor(bitor(bitshift(uint32(occ),10), bitshift(uint32(pushPtr),5)), uint32(popPtr));\n' ...
 'wB = bitor(bitshift(uint32(pof),16), uint32(poe));\n' ...
 'if ~freeze, sA = wA; sB = wB; sC = c; end\n' ...
 'witA=sA; witB=sB; cSS=sC(1); cRH=sC(2); cCFC=sC(3); cCS=sC(4); cPD=sC(5); cPC=sC(6);\n']);
% inputs: occ/pushPtr/popPtr from the FIFO's Push Counter / Pop Counter (beatobs_overlay.m:57-100 pattern),
% popEmpty/pushFull from Validate Input Push Pop, the six valids via new Inports at each level
% (framestat_overlay.m:148-171 pattern, in reverse: drive DOWN into Rate Handle), freeze from
% FixCtlDec's new w1Freeze output plumbed qrx -> FTS -> Symbol Synchronizer -> Rate Handle
% (exactly how beatfix_overlay.m:285-295 plumbs bfGridEn).
% outputs: eight Outports up Rate Handle -> Symbol Synchronizer -> FTS -> QPSK Rx -> Receiver -> TxRxComposite
% named w1_wita w1_witb w1_ss w1_rh w1_cfc w1_cs w1_pd w1_pc (beatfix_overlay.m:190-207 pattern).
end
```

`patch_hdlworkflow_rxfix.m` follows `patch_hdlworkflow_beatfix.m` line for line: env-gated on `QPSK_RXFIX`, idempotent on the comment `% --- rxfix mapping`, anchored after the beatfix mapping block, one `IOInterface`/`IOInterfaceMapping` pair per port, every stanza wrapped in `if ~isempty(find_system(...,'Name','w1_wita'))`. In assemble, after phase 2.20:

```matlab
% --- phase 2.21: RXFIX overlays (env-gated QPSK_RXFIX; formerly netlist injectors modem/fixes/)
if ~isempty(getenv('QPSK_RXFIX'))
    fprintf('=== applying RXFIX overlays (env-gated QPSK_RXFIX) ===\n');
    rxfix_w1_overlay(sys, loop);
end
```

and `patch_hdlworkflow_rxfix('hdlworkflow_loopback.m');` after the beatfix patch call. Extend `FixCtlDec`'s script in `beatfix_overlay.m:81-89` with `w1Freeze` (bit 4) and `sroSign` (bit 5, used in Task 5) outputs — both unused outputs are fine for HDL Coder.

- [ ] **Step 4: Run static tests** → PASS. Regenerate (Task 1 Step 5 command, `QPSK_RXFIX=1` now exported by `build_base_tree.sh`; unit `sp3-w1-<ts>`; ~22 min). Post-check: `RxW1Census.v` exists under the regen hdlsrc (as `TxRxCompo_ip_src_RxW1Census.v`), `grep -c '8.h85\|00000010000101' TxRxCompo_ip_addr_decoder.v` ≥ 1 (0x214 decode). Refresh: `cd modem/rtl_sim && bash make_sro_trees.sh --from-regen <REGEN_BASE>`.

- [ ] **Step 5: Gate.** `TREE=$PWD/s1_rtl_model FIXCTL=0 bash build_sro_w1.sh` then `modem/fixes/run_gates.sh --legs modem/fixes/gates/build_sro_w1.legs` with `RTL_OBJ_SUFFIX=_model_0` (add this env to `run_gates.sh`: it substitutes `obj_byte_sro_<v>` → `obj_byte_sro_<v>$RTL_OBJ_SUFFIX` in leg commands; keep it simple: `sed "s#obj_byte_sro_\([a-z0-9]*\)/#obj_byte_sro_\1$RTL_OBJ_SUFFIX/#g"` on `$cmd`). Pass = every leg of `build_sro_w1.legs` passes unchanged (Gate A md5s are on delivered frames, which the census does not touch; `edge_m10` poe==21/occ==21 is the ring's behaviour, unchanged). If a Gate A md5 differs, the overlay perturbed the datapath — that is a defect, not a tolerance case.

- [ ] **Step 6: Commit** `git add modem/rxfix/ modem/tests/test_rxfix_overlays.py modem/assemble_jupiter_240k5_byte.m modem/build_variant_byte.m modem/fixes/build_base_tree.sh modem/fixes/run_gates.sh modem/instruments/beatila/beatfix_overlay.m`; `git commit -s -m "sp3: W1 census as a model overlay (0x214-0x230); w1 gate passes on the model tree"`; `git push`.

---

### Task 5: Rate Handle steering overlay with runtime `sro_sign`

**Files:**
- Create: `modem/rxfix/rxfix_steer_overlay.m`
- Modify: `modem/rxfix/patch_hdlworkflow_rxfix.m` (0x234, 0x238, 0x25C), `modem/assemble_jupiter_240k5_byte.m` (call after `rxfix_w1_overlay`), `modem/tests/test_rxfix_overlays.py`

**Interfaces:**
- Consumes: `FixCtlDec.sroSign` (bit 5), the Rate Handle pop-enable net = the `Logical Operator` block whose output is `Logical_Operator_out1` in `Rate_Handle.v` (the injectors redefine that assign: `rxfix_inject.py` R4B/R4D sections), `validIn`, `Compare To Constant` (nominal pop), `HDL Counter` (mod-4 phase, the block `beatfix_overlay.m:255-284` muxes), `pcEnd` = `Packet Controller/endOut` in QPSK Rx (plumb DOWN via new Inports like Task 4's valids), occupancy from the FIFO.
- Produces: MLFB `RxSteer` inside `Rate Handle`; the existing pop-enable line is cut (`delete_line`) and re-driven (`beatfix_overlay.m:185-188` pattern) from a `NOT`/`AND`/`AND4`/`OR` chain around `RxSteer`'s two registered arming levels `skipEn`/`extraEn` — AS BUILT the MLFB does not emit `popEn` itself; see the deviation note below. Outputs `r4Wit` → Outport `r4_wit` (`x"234"`, `{locked[31] skips[30:15] opens[14:0]}`), `r4Extras` → `r4_extras` (`x"238"`, `{16'b0 extras[15:0]}`), `sroMode` → `sro_mode` (`x"25C"`, `{30'b0, extraArmed[1], sroSign[0]}`).

MLFB body: **the skeleton that was here was REFUTED and has been replaced** (Task 5,
2026-09-11). It was diffed line by line against `rxfix_inject.py`'s `RH_POP_NEW_R4B`
(:1856) and `RH_POP_NEW_R4D` (:2422) — the truth — and had **six** slips, each of
which changes which pop is suppressed. The implemented, gated transcription is
`modem/rxfix/rxfix_steer_overlay.m` (block `RxSteer`); read it, not a copy here. The
six corrections, for anyone re-deriving it:

1. the registered decision also carries the slot guard `& (wslot <= uint8(12))`
   (the injector's `(r4b_wslot <= 4'b1100)`), which is what keeps the skip inside
   `[pcEnd+1, pcEnd+13]`;
2. it needs the explicit clear `if doSkip, nSkipArm = false; else ... end` — with
   non-blocking semantics `skipDone` is still 0 on that same edge, so a plain
   `& ~skipDone` RE-ARMS instead of clearing, allowing a second skip in one window;
3. the window advances **one slot per NOMINAL pop opportunity** (`if win && popNom`),
   and `wslot >= 13` closes it *without* incrementing — not one slot per enb beat
   (that would make the window ~4x shorter);
4. `pcEnd` is REGISTERED ON ARRIVAL and the level of that one-tick registered pulse
   opens the window; there is no `pcd` rising-edge detector (`Packet_Controller.endOut`
   is already exactly one enb tick wide);
5. `occLe8`/`occGe24` are re-evaluated EVERY enb beat, not sampled once at window open;
6. `frames` is a 4-bit counter capped by the lock gate, and `opens` (15-bit) / `skips`
   / `extras` (16-bit) all WRAP — MATLAB integer arithmetic saturates where the RTL
   wraps, so each increment is written as an explicit wrap.

Two structural deviations the implementation also carries, with their reasons in the
overlay header and `modem/rxfix/README.md`: the pop expression is rebuilt from
primitives OUTSIDE the MLFB (HDL Coder delay-matches some MATLAB Function inputs and
not others; one landing on `popNom`/`validIn` would move the FIFO pop a beat), and
the two long paths are `Delay` blocks (a MATLAB Function block is direct-feedthrough
and would have left two algebraic loops the RTL does not have).

Also corrected in Step 4 below: this tree's `TxRxCompo_ip_addr_decoder.v` uses 8-bit
case labels, and 0x25C → word 0x97 is `8'b10010111` (the `00000010001111` written
here was 0x8F).


- [ ] **Step 1: Static tests** (append to `test_rxfix_overlays.py`): `RxSteer` present, env-gated, `x"234" x"238" x"25C"` mapped, the script contains `sroSign` in the `doExtra` term, and `skipEn` is never combinational with `popNom` in the same expression that assigns it (grep the body: `skipEn  = locked & win` line exists).

- [ ] **Step 2: Run** → FAIL. **Step 3:** write the overlay (anchor asserts; `delete_line` the pop-enable; `add_line` from `RxSteer/1`; plumb `pcEnd` down, `sroSign` down beside `w1Freeze`, three Outports up). **Step 4:** static PASS; regenerate (`sp3-steer-<ts>`); post-check `RxSteer.v` and the decoder cases `8'b10001101` / `8'b10001110` / `8'b10010111` (0x234/0x238/0x25C = words 0x8D/0x8E/0x97); refresh `s1_rtl_model`.

- [ ] **Step 5: Gate, both signs.** Build `TREE=$PWD/s1_rtl_model FIXCTL=0 bash build_sro_rxfix4b.sh` and `FIXCTL=20 bash build_sro_rxfix4dr1.sh` (bit 5 = 0x20; R1 is not in yet, so run the R4D-half legs only): run `build_sro_rxfix4b.legs` with `RTL_OBJ_SUFFIX=_model_0` (G1 ident ≥ 420 common seq, G2 skips 4..14 in the first 12 air frames, G3 ring plateau 8-12 / pop_on_empty 0, G4 prearm) — all must pass; then with `FIXCTL=20` run `build_sro_rxfix4d.legs` legs `J5_ident`, `J5_extras` (extras=0, skips=8 on n_p000 — the `occ>=24` predicate never fires there) and `S1_vs_r4b`. Then the ppm pairs: `n_m10` at `FIXCTL=0` vs `reference_loss.toml` `R4B/n_m10` via `score_matrix.py`; `n_p10` at `FIXCTL=20` is NOT scored here (R4D alone is refuted, J1-J4; it needs R1, Task 6).

- [ ] **Step 6: Commit** `git commit -s -m "sp3: Rate Handle steering overlay -- skip + extra-pop branches, runtime sro_sign (fixctl bit 5), witnesses 0x234/0x238/0x25C"`; `git push`.

---

### Task 6: R1 — realignment FIFO pop indexed by occupancy

**Files:** Create `modem/rxfix/rxfix_r1_overlay.m`; modify assemble (call after steer), `test_rxfix_overlays.py`.

**Interfaces:** in `Preamble Detector`, the pop input of `FIFO` is driven by the tail of a 49,332-deep delay (`Delay10_out1 = Delay10_reg[49331]` in the generated RTL; find the Simulink `Delay` block with `DelayLength` 49332 or the chain ending in it: `find_system(pd,'BlockType','Delay')` and read `get_param(b,'DelayLength')`). The FIFO's occupancy is `FIFO_numEntries` (the `numEntries` output of the FIFO subsystem or its `Push Counter − Pop Counter`). Produces MLFB `PdPopIndex(delay8Out, numEntries) → pop = delay8Out & (numEntries == uint16(12333))` where `delay8Out` is the signal the RTL calls `Delay8_out1` (the pop-qualify one stage earlier in the same chain); `delete_line` the old pop, `add_line` from `PdPopIndex/1`. The 49,332-deep delay block is left in place but unconnected only if HDL Coder would otherwise error on an unused block; prefer `delete_block` on it and its now-dangling lines so the 49k-bit shift register is not synthesised (that is what the spec means by "retires the Delay10 shift register"; check the sp2 role-B kit: `grep -c Delay10_reg ref/rxfixr4dr1_ipcore/hdl/Preamble_Detector.v` shows whether the injected build kept it).

- [ ] Steps 1-4 as Task 5 (static test: `PdPopIndex`, `12333`, env gate; regenerate `sp3-r1-<ts>`; post-check `PdPopIndex.v`; refresh tree).
- [ ] **Step 5: Gate.** `FIXCTL=20 bash build_sro_rxfix4dr1.sh` then `build_sro_rxfix4dr1.legs` with `RTL_OBJ_SUFFIX=_model_20`: `S1_p000_D1` LOSS=0.00, `S1_p000_D2` t7_ok 423/424 extras 0 skips 8, `S2_p10_D1` LOSS ≤ 1.00, `S2_p10_D2` t7_ok ≥ 420, `S3_p10_pof` push_on_full=0, `S4_p10_pdocc` 12333, `S5_p10_ring` extras 30-45 / occTrue_end 21-25. Then `score_matrix.py` on `R4DR1/n_p10`, `R4DR1/n_m10`, `R4DR1/n_p2p5`, `R4DR1/n_m2p5` vs the reference. Also re-run Task 5's `FIXCTL=0` R4B legs on the new tree (R1 is unconditional; the spec says R1 is unconditional, so the EMPTY-edge role now carries R1 too — `R4B/n_*` must still match the reference within tolerance; if `R4B/n_m10` moves outside tolerance because of R1, that is a real finding: record it and stop for the two-iteration rule of ruling 7).
- [ ] **Step 6: Commit** `git commit -s -m "sp3: R1 realignment-FIFO pop by occupancy as a model overlay; R4D+R1 legs pass on the model tree"`; `git push`.

---

### Task 7: BS census and PAD

**Files:** Create `modem/rxfix/rxfix_bs_overlay.m`, `modem/rxfix/rxfix_pad_overlay.m`; modify `patch_hdlworkflow_rxfix.m` (0x23C-0x258), assemble, tests.

**Interfaces:**
- BS: MLFB `BsSeamCensus` at the composite level (`TxRxComposite`, where `ByteSerializer` and `ByteRxFifo` are instantiated), sampled every clk — in Simulink terms the block runs at the base rate (30.72 MHz, `ce_out_1`), not the serializer's half rate: set its sample time to the base rate and read the serializer signals through rate-transition-free direct lines (both are already in the composite's single clock domain; the two "enb" domains are clock enables, so a base-rate block sees every edge). Inputs: `wv`, `wl`, `start`, `wordCnt` from the ByteSerializer chart's outputs (add chart outputs if `wordCnt` is internal state), `push`, `pop`, `drop` from `ByteRxFifo`, `freeze` (W1's). Outputs → Outports `bs_words bs_starts bs_push bs_pop bs_drop bs_marks bs_evt bs_cnt` → `x"23C"`..`x"258"` with the packings in `fixes.toml [fixes.BS]`; `trunc_ev = start & (wordCnt in 1..190)`, `q24_ev = (191-wordCnt) ∈ {24,48,72,96,120,144,168}`.
- **ByteRxFifo precondition (resolve first):** the bank's `ByteRxFifo.v` is a hand-authored v5 BRAM drop-in, not HDL Coder output (`BASE_REGEN_DIVERGENCE.md`, research note). Diff `<REGEN_BASE>/.../TxRxCompo_ip_src_ByteRxFifo.v` against the bank's. If the regen's is the 64-deep register form, the BS overlay's `push/pop/drop` taps still exist (the chart emits them) but the SHIPPED FIFO is the BRAM one. Ruling for the executor: the v5 drop-in's behaviour (true simple-dual-port synchronous-read RAM, depth per `byte_rxfifo_overlay.m`'s comments, `drop-oldest` on full, handshake state on 0x1B0) is re-expressed in `modem/byte_rxfifo_overlay.m` as an MLFB + `HDL FIFO`/`Simple Dual Port RAM` block pair so HDL Coder emits a BRAM (`RAMB36`) mapping; the drop-in `.v` and the `rxfifo_inject.sh` step die with the injectors. Verify with `grep -c "Simple Dual Port RAM\|SimpleDualPortRAM" <regen>/TxRxCompo_ip_src_ByteRxFifo*.v` ≥ 1 after regen. This is the riskiest step of the plan; if the BRAM form cannot be reached in two regen iterations, keep the drop-in as a documented post-HDL-Coder file substitution in `modem/instruments/byterxfifo/` (a file copy, not a text patch) and record the divergence.
- PAD: edit the `ByteSerializer` chart script (the `sfroot` chart at `[base '/ByteSerializer']`; `assemble_jupiter_240k5_byte.m:551-553` shows how it is located) to add the filler state machine from `rxfix_inject.py`'s PAD section: on a frame start with `1 <= wordCnt <= 190`, `pad = 191 - wordCnt`; while `pad > 0` emit `w = 0, wv = 1, wl = (pad == 1)`, decrement; queue up to three real words (`pq0..pq2`, `pl0..pl2`, `pqn`) arriving mid-burst and drain them after. Chart-script edit = string surgery on `ch.Script` with an anchor assert and an idempotency check (`'padCount'` absent before insert).

- [ ] Steps 1-4 as before (static tests: `BsSeamCensus`, eight addresses, `padCount` in the PAD overlay, env gate; regenerate `sp3-bspad-<ts>`; post-check `BsSeamCensus.v`, `padCount` or `pad_` in `ByteSerializer.v`, BRAM form of ByteRxFifo; refresh tree).
- [ ] **Step 5: Gate.** `TREE=... FIXCTL=0 bash build_sro_bs.sh` → `build_sro_bs.legs` (I1 frames, I4 res, I5 wrapper transparency, census_clean zero defects, census_grid) and `bash build_sro_pad.sh` → `build_sro_pad.legs` (`pad_k1536`: `t7_ok=104`, `t7_nomagic 319`, `words191_k1536` 418 frames / 0 orphans / bs_trunc 312 / q24 255 / 79,760 words; `merge_control`, `nrxw_k1536` 80,960). `census_grid` compares against a banked record file whose grid depends on `BS_PUSH_GRID=4096` — the model tree must dump on the same grid; if the model census cannot reproduce the exact banked records, the leg is re-scored on the invariants (`bs_words == bs_push`, `bs_drop == 0`, starts == frames) and the ledger note explains why.
- [ ] **Step 6: Commit** `git commit -s -m "sp3: BS seam census and PAD as model overlays; ByteRxFifo BRAM form from the model"`; `git push`.

---

### Task 8: TX F3 overlay

**Files:** Create `modem/rxfix/txfix_f3_overlay.m`; modify assemble (phase 2.21, after PAD), tests.

**Interfaces (from `txfix_inject.py`):** in the transmitter (`[base '/Transmitter/...']` — locate with `find_system(base,'Name','Data Bits FIFO')`, `'RAM Frame Status Indicator'`, `'Bit Packetizer'`, and the MATLAB Function block HDL Coder emitted as `MATLAB_Function1.v` — identify it by `grep -n "Source Path" <bank>/TxRxCompo_ip_src_MATLAB_Function1.v`):
- F1: the pop-enable latch clear moves inside the `sampleCount == 0` guard (`Compare To Constant3`); in Simulink, gate the latch's reset input with that compare (`add_block` a Logical Operator AND, re-route).
- F2: `frameCount` 2-bit up/down counter becomes saturating: replace the counter's increment/decrement enable with `fcInc & ~fcDec & (frameCount != 3)` / `fcDec & ~fcInc & (frameCount != 0)` — an MLFB `FrameCountSat` replacing the counter block.
- F3: `dataReady = DataReadyPaceCmp & ~fullRAM` (AND block on the existing compare output and the inverted `Data_Bits_FIFO.fullRAM`), and `MATLAB_Function1`'s `count` becomes saturating uint16 (edit that chart's script: `count = min(count+1, 65535)` / `max(count-1, 0)` forms, anchor assert). F3b margin (`49263` vs `49279`) is NOT applied (the shipped variant is F3, `fixes.toml [chain].txfix.variant = "F3"`).
- Verification: `Bit_Packetizer.v` in the regen contains `fullRAM` in the `dataReady` assign; `tree_marker.sh <tree> F3` → `model`.

- [ ] Steps 1-4 (static tests, regenerate `sp3-f3-<ts>`, post-check, refresh; also `cp -a` the regen hdlsrc to `modem/rtl_sim/s1_rtl_model_tx/hdlsrc/commhdlQPSKTxRxLoopback` in the layout `build_txkick_sim.sh:32` expects).
- [ ] **Step 5: Gate.** `TREE=s1_rtl_model_tx bash build_txkick_sim.sh` (and `build_txrate_sim.sh`) → run the G0-G14 matrix rows for variant `F3` from `modem/rtl_sim/evidence/txfix_gate_runs.txt` via `txfix_gate_launch.sh` against the new binaries (add a `BIN_OVERRIDE` env or a copied runs file with `obj_txkick_model/Vtxkick`), score with `txfix_gate_score.py`: every `TXFIX_GATE G<n> F3 PASS` that the banked `beat_runs/txfix_gate_summary.txt` shows PASS must PASS.
- [ ] **Step 6: Commit** `git commit -s -m "sp3: TX F1+F2+F3 as a model overlay; txfix gate matrix passes on the model tree"`; `git push`.

---

### Task 9: Gate 1 — the full equivalence matrix, one tree, both signs

**Files:** Create `modem/gates/model_matrix.legs` (note: `modem/gates/` is created here; the move of `run_gates.sh` happens in Task 11 — until then put it at `modem/fixes/gates/model_matrix.legs`), `docs/evidence/sp3/GATE1_EQUIVALENCE.md`.

- [ ] **Step 1: Write the table.** Every row runs against `s1_rtl_model` binaries: `FIXCTL=0`: W1 legs (all), R4B legs (all kept) + `n_p000 n_p2p5 n_m2p5 n_p10 n_m10`; `FIXCTL=20`: R4DR1 legs (all kept) + the five stimuli; BS legs; PAD legs; the F3 rows; a final `score` leg calling `score_matrix.py` with the ten `<variant>/<stim>=<prefix>` maps and `MATRIX_EXIT 0` as the criterion.
- [ ] **Step 2: Run it** — `run_gates.sh --legs ... --force` (fresh, no `.ok` reuse; background watcher; ~6 h). **Step 3:** if any leg fails: one fix iteration (overlay change → regen → rerun failed legs), then a second; after that ruling 7 applies. Record every iteration in the evidence file.
- [ ] **Step 4: Evidence.** `GATE1_EQUIVALENCE.md`: the table of model-vs-reference numbers with tolerances, the commands, unit names, wall time, the regen tree sha (`sha256sum` over the sorted `.v` list, recorded as `MODEL_TREE_SHA`), git sha. Commit `git commit -s -m "sp3 gate 1: model tree matches the injected references at 0/±2.5/±10 ppm, both sro_sign"`; push.

---

### Task 10: Register manifest and host consumers (`sro_sign`, 0x25C)

**Files:**
- Create: `modem/regmap/regmap.toml`, `modem/regmap/gen_regmap.py` (moved from `modem/fixes/gen_regmap.py`, `git mv`), `modem/regmap/tests/test_gen_regmap.py` (moved)
- Modify: `host/qpsk_fixregs.h`, `host/modem_status/ms_regmap_fixes.inc` (regenerated), `host/modem_status/ms_regmap.c`, `host/modem_status/ms_panels.c` (the fixctl/witness panel), `host/modem_status/test_modem_status.c`, `host/Makefile` (regen-check path), `.github/workflows/docs.yml` (`regmap` job path), `docs/byte-plane.rst`, `docs/debug-instruments.rst`
- Leave `modem/fixes/fixes.toml` untouched until Task 15 (its sha is recorded in the sp2 stamps).

**Interfaces:**
- `regmap.toml` = the `[fixes.*]` `control`/`witness`/`witness_section` tables of `fixes.toml` (W1, R4B/R4D merged into one `[fixes.STEER]` with both witness words canonical + `witness_swapped_in_images` kept, BS) plus:

```toml
[fixes.STEER]
control = [{ reg = 0x208, bit = 5, name = "sro_sign", kind = "level", desc = "0 = EMPTY-edge steering only (skip); 1 = also FULL-edge extra pop" }]
witness = [
  { addr = 0x234, name = "r4_wit",    flags = ["MS_F_PACKED", "MS_F_IMGKEY"], fields = "{locked[31] skips[30:15] opens[14:0]}" },
  { addr = 0x238, name = "r4_extras", flags = ["MS_F_PACKED", "MS_F_IMGKEY"], fields = "{16'b0 extras[15:0]}" },
  { addr = 0x25C, name = "sro_mode",  flags = ["MS_F_PACKED"],                fields = "{30'b0 extra_armed[1] sro_sign[0]}" } ]
witness_swapped_in_images = ["9acbe2ebe1dbf280e030952fc4fc23d8"]
```

- `gen_regmap.py` reads `regmap.toml` (no `[chain]`/`[roles]`), emits the same two files plus `#define QPSK_FIXCTL_SRO_SIGN_BIT 5` and `QPSK_FIXCTL_W1_FREEZE_BIT 4`; `--check` unchanged.
- `modem_status`: the witness panel shows `sro_sign=<0|1> edge=<EMPTY|FULL> extra_armed=<0|1>` decoded from 0x25C (`ms_dec_sro_mode`), `MS_F_IMGKEY` handling unchanged (`ms_r4d_order` still keys the swapped image).

- [ ] **Step 1: Tests.** In `test_gen_regmap.py` add: `test_manifest_has_sro_sign_bit5_and_0x25c` (parse `regmap.toml`, assert the control bit and the 0x25C row), `test_generated_header_defines_sro_sign_bit`. In `test_modem_status.c` add a decode check: `ms_dec_sro_mode(0x3)` → `sro_sign=1 extra_armed=1`, `(0x0)` → `0/0`, and a row-table check that 0x25C is present with `MS_F_PACKED`.
- [ ] **Step 2: Run** → FAIL. **Step 3:** `git mv`, write `regmap.toml`, adapt `gen_regmap.py` (drop the chain/role parsing; keep everything else byte-for-byte so the W1/BS rows regenerate identically — assert with `git diff --stat host/` showing only the new lines), regenerate, add the decoder + panel line. **Step 4:** `python3 -m pytest -p no:libiio modem/regmap -q` PASS; `python3 modem/regmap/gen_regmap.py --check` rc 0; `make -C host clean all test` PASS (expect `> 228 checks`).
- [ ] **Step 5: Docs.** `docs/byte-plane.rst` and `docs/debug-instruments.rst`: replace `modem/fixes/fixes.toml` by `modem/regmap/regmap.toml` as the source of truth; add the `sro_sign` bit and 0x25C to the register prose; CI `regmap` job path.
- [ ] **Step 6: Commit** `git commit -s -m "sp3: register manifest moves to modem/regmap (sro_sign bit 5, 0x25C sro_mode); modem_status shows the active steering edge"`; push.

---

### Task 11: Single-image `build_image.sh`, SEQ-BIST as a BD instrument, Gate 2 timing

**Files:**
- Modify: `modem/build_image.sh` (stages `hdl seqbist gates vivado`; no `--role`; `--tag` default `sp3`), `modem/fixes/build_base_tree.sh` → `git mv` to `modem/build_hdl.sh` (drops the equivalence diff into an optional `--diff-bank DIR`), `modem/fixes/tests/test_build_image.py` → `modem/tests/test_build_image.py`
- Move: `modem/fixes/{run_gates.sh,gates/,modem_wns.py,score_matrix.py,collect_reference.py}` and their tests → `modem/gates/`; `modem/fixes/{seqbist_kit.sh,patch_seqbist_tcl.py}` + `modem/rtl_sim/{qpsk_traffic_gen_v2.v,rx_seq_checker.v,cnt_mux32.v}` references → `modem/instruments/seqbist/` (`seqbist_kit.sh` becomes `apply_seqbist.sh <kit>`: same body, `SRC` = the hdl-stage kit instead of `jupiter_byte_txfixF3_build`)
- Create: `docs/evidence/sp3/GATE2_TIMING.md`; modify `docs/build-and-flash.rst`

**Interfaces:**
- `modem/build_image.sh [--tag T] [--from S] [--stop-after S] [--work DIR] [--remote-base DIR] [--concurrent] [--dry]`; stages: `hdl` (MATLAB regen with `QPSK_LEAN=1 QPSK_BEATFIX=1 QPSK_BEATOBS=1 QPSK_FRAMESTAT=1 QPSK_RXFIX=1`, then the ddrcap/ddrcap2 instrument injections as today — they are instruments, not fixes, and stay injectors per the spec's cleanup rule; post-check `tree_marker.sh` for W1 R4B R4DR1 BS PAD F3 all `model`) → `seqbist` (BD Tcl) → `gates` (`make_sro_trees.sh --from-regen`, `run_gates.sh --legs modem/gates/model_matrix.legs`) → `vivado` (unchanged mechanics: `build_txfix.sh` template on `hdl-dev-2` under `systemd-run`, rsync back, `modem_wns.py --min 0.005`, `BUILD_IMAGE_WNS_OK wns= floor=0.005 ref_pad=0.105 ref_sp2A=0.447 ref_sp2B=0.785`). Image lands as `$WORK/BOOT.BIN.jupiter.<tag>.<md5:0:12>`, banked as `images/BOOT.BIN.jupiter.<tag>.<md5>`.
- STAMP contract unchanged except `manifest_sha` becomes `model_tree_sha` (the `MODEL_TREE_SHA` of Task 9).
- The base bank is no longer consulted; `base_tree.sh verify-bank` still runs for the `sro_sim` listing pin (move the pin file to `modem/gates/bank.sha256` with only the sro_sim line and, until Task 15, the tarball/manifest lines).

- [ ] **Step 1: Tests** (`modem/tests/test_build_image.py`, adapted): `--role` is rejected with `BUILD_IMAGE_NO_ROLE` (exit 2); stage order `hdl seqbist gates vivado`; `--stop-after` earlier than `--from` → `BUILD_IMAGE_BAD_RANGE`; `--dry` writes `STAMP.hdl.dry`/`STAMP.vivado.dry` only; the header documents the terminal lines.
- [ ] **Step 2-4:** implement, tests PASS, `bash -n`, `tools/check_paths.sh` OK (update its waivers: the `rxfix_inject.py` waiver stays until Task 15).
- [ ] **Step 5: Build.** `modem/build_image.sh --tag sp3 --remote-base /mnt/disk2/scratch/qpsk-builds` under `systemd-run --user` (whole chain ~4 h: 22 min hdl + 6 h gates if `.ok` reuse from Task 9 is not available → run `--from vivado` only if Task 9's stamps are present, else let it run). Post-check on hdl-dev-2: the kit dir is `jupiter_byte_sp3_build` (never a `*_build_ref`), `BOOT.BIN` > 6 MB, md5 recorded. Gate 2: `MODEM_CLK_WNS ... wns >= 0.005`. If `< 0.005`: ruling 8 / spec Gate 2 — stop, record in `GATE2_TIMING.md`, the runtime select is dropped, sp2 stays shipped (Tasks 12-15 not run).
- [ ] **Step 6: Bank + evidence.** `cp $WORK/BOOT.BIN.jupiter.sp3.<md5> images/`; `GATE2_TIMING.md`: WNS/TNS/endpoints, the report path, the floor rule, comparison with sp2A/sp2B. Commit `git commit -s -m "sp3: single-image build_image.sh (hdl seqbist gates vivado); sp3 image <md5> banked, modem WNS <x>"`; push (the image is < 20 MiB? BOOT.BIN is ~6-8 MB — yes; the size guard allows it, as for sp2).

---

### Task 12: Bring-up writes `sro_sign`; cross-check

**Files:** Create `ops/profiles/sro_sign.conf`; modify `ops/bringup_r2r3.sh` (after `arm_rom` for each board), `ops/restore_known_good.sh` (same hook), `ops/tests/test_sro_sign_conf.py`, `docs/bringup.rst`.

**Interfaces:**
- `sro_sign.conf`:

```
# sro_sign per board (fixctl 0x208 bit 5). 0 = EMPTY-edge steering only (receiver oscillator FAST,
# negative sample-rate offset, the sp2 role-A/148 case); 1 = also FULL-edge extra pop (role-B/146).
# Change ONLY after a credited PER window with the bit swapped shows the comb (Gate 3 bit-swap test).
10.0.0.148 0
10.0.0.146 1
```

- `ops/sro_sign.sh <ip> [--read]`: reads the conf, reads 0x208's current value from the daemon's shadow (0x208 is write-only on the bus and NO shadow convention exists yet in `ops/` (checked 2026-09-11: `grep -n fixctl ops/*.sh` is empty — W1's freeze is toggled by the modem_status/w1 tooling with a full-word write). Create the convention here: `/dev/shm/fixctl.word` on the board holds the last word written; every writer of 0x208 in `ops/` and `host/` goes through `sro_sign.sh`'s `fixctl_write <word>` helper from now on — grep `host/` for `0x208` writers and route them the same way or document that they write the full word), sets/clears bit 5 preserving the others, writes via `direct_reg_access`, reads 0x25C back and prints `SRO_SIGN <ip> wrote=<0|1> readback_mode=<hex> edge=<EMPTY|FULL>`; exits 1 if `readback & 1 != wrote`.
- Cross-check: `ops/sro_sign.sh --check <ip>` reads the CFC median (0x154 `cfc_est` mean over 10 s at 1 s cadence, the same read `modem_status` does) and the programmed RX-LO offset for that leg (`LO_A_RX`/`LO_B_RX` in `bringup_r2r3.sh:65` minus the nominal 2.0 GHz), derives `residual_hz = cfc_hz - lo_offset_hz`, and prints `SRO_SIGN_CHECK <ip> residual_hz=<f> implies=<0|1> conf=<0|1> AGREE|DISAGREE` — `DISAGREE` is a WARNING line, never a change. The scale factor from cfc units to Hz is whatever `ms_regmap.c`'s 0x154 row uses; cite it.
- `bringup_r2r3.sh` and `restore_known_good.sh`: after each board's arm completes (after the `0x110` pulse), `bash "$D/sro_sign.sh" $ip` and `bash "$D/sro_sign.sh" --check $ip`; both lines go to the bring-up log.

- [ ] **Step 1: Test** (`ops/tests/test_sro_sign_conf.py`): the conf parses to `{"10.0.0.148": 0, "10.0.0.146": 1}`; `sro_sign.sh` with `W=` pointed at a fake anyssh (the `test_capture_r3_recovery.py` pattern) that answers `0x25C` with `1` after a write of bit 5 → prints `wrote=1 ... edge=FULL`, exit 0; the fake answering `0` → exit 1; `--check` with a scripted cfc/LO → `AGREE`/`DISAGREE` lines.
- [ ] **Steps 2-4:** implement, tests PASS, `bash -n`. Do NOT run against the rig here (Task 13 does, under the rails).
- [ ] **Step 5: Docs + commit.** `docs/bringup.rst`: the bit, the conf, the cross-check, "a DISAGREE is a finding, not an automatic flip". `git commit -s -m "ops: bring-up writes sro_sign per board from ops/profiles/sro_sign.conf with a CFC residual cross-check"`; push.

---

### Task 13: Gate 3 — silicon, one board at a time, bit-swap test, cut-over

**Files:** Create `docs/evidence/sp3/SP3_SILICON.md`; modify `images/CURRENT.txt`, `docs/provenance.rst`, `images/README.md`.

Pre-flight (all three before any flash): (a) rig health both boards (`ops/health_probe_reset_aware.sh <ip> 12` → `clean=12/12`), (b) `SENTINEL_STOP` not present (the rails own it), (c) `images/BOOT.BIN.jupiter.sp3.<md5>` exists and `md5sum` matches; and the rails need per-board file names — the rails build `images/BOOT.BIN.<board>.$TAG.$EXP`: create `images/BOOT.BIN.148.sp3.<md5>` and `images/BOOT.BIN.146.sp3.<md5>` as hard links (`ln`) of the single image and say so in `images/README.md` (one image, two rail-shaped names; `md5sum` identical).

- [ ] **Step 1: 148.** `FLASH_MD5=<md5-12> FLASH_TAG=sp3 FLASH_BAK=3e7f4232a3b5 ops/flash/flash_148_txfix.sh` (log under `ops/flash/`). The rail's two-pass `arm148_mode1` gate uses the BIST golden — that golden is arm-state-defined and unchanged by this image only if the loopback arm path is untouched; if `GATE_FAIL` on the golden alone with `ARM_OK` and `fps>=1120`, do NOT roll back blindly: read 0x144 twice, compare with `0x04922282`, and if the new image's mode-1 BIST word differs consistently, record it as the sp3 golden after the credited window passes (the rail has `GOLD=` env: rerun the gate with the observed value). Then the normal bring-up (`bringup_r2r3.sh r3`) — it writes `sro_sign=0` on 148 and prints the check line.
- [ ] **Step 2: Forward window on sp3(148)+sp2B(146).** `ops/capture_r3.sh A -d 600 -o r3cap/sp3_fwd_<ts>` (`RIG_LOCK` via the rail conventions; sentinel held by the rail), score `python3 ops/accept_analyze.py r3cap/sp3_fwd_<ts>/frames.bin` → PER `<= 0.158 %`; `python3 ops/comb/comb_period_ms.py ...` → no new lag line. Health after: `clean=12/12` twice.
- [ ] **Step 3: 146.** `FLASH_MD5=<md5-12> FLASH_TAG=sp3 FLASH_BAK=d94b4df391a1 ROLLBACK_BANK=images/BOOT.BIN.146.sp2B.d94b4df391a1 ops/flash/flash_146_txfix.sh` (the rail's gate = restore_known_good + health on 148 + NAK recheck; no BIST on 146). Bring-up writes `sro_sign=1` on 146. Reverse window: `ops/capture_r3.sh B -d 600 ...` → PER `<= 0.191 %`, no new lag, plus the R4D witness decode on 146 (`r4_extras` upper half 0, `sro_mode = 0x3` after lock).
- [ ] **Step 4: Bit-swap test (spec Gate 3, last clause).** On 148 only: `ops/sro_sign.sh --force 1 10.0.0.148` (add `--force <v>` to the script: writes the given value regardless of the conf, prints `SRO_SIGN_FORCED`), 300 s forward capture → expect the comb to return (PER rises and/or `comb_period_ms.py` shows the ~32-frame line, `r4_extras` climbing); then `ops/sro_sign.sh 10.0.0.148` (back to conf, 0), 300 s capture → PER back under the bar and the line gone. Both captures scored and quoted with commands and sample counts. If the swapped bit does NOT bring the comb back, the bit is inert on silicon — Gate 3 fails; roll back both boards with the rails (`FLASH_MD5=3e7f4232a3b5 FLASH_TAG=sp2A FLASH_BAK=<sp3 md5>` and the 146 twin) and stop per ruling 7.
- [ ] **Step 5: Cut-over.** `images/CURRENT.txt`: one current row (`jupiter sp3 <md5>` on both boards, PER numbers with sample counts, "lost frames in the denominator"), rollbacks sp2A/sp2B banked and on-board `.bak`; `docs/provenance.rst`: the sp3 row (model tree sha, git, WNS, endpoints, flash times from the rail logs, both windows, the bit-swap result), the "one image" note, and the R4D swapped-order note retained for the 9acbe2ebe1db rollback. `SP3_SILICON.md`: every command, unit, log path, number.
- [ ] **Step 6: Commit** `git commit -s -m "sp3 gate 3: sp3 image on both boards; fwd <x> % (<n>/<N>), rev <y> % (<n>/<N>); bit-swap test reproduces and clears the comb; CURRENT cut over"`; push.

---

### Task 14: Memory and rig-facing docs

- [ ] Update `docs/build-and-flash.rst` (one image, the four stages, `sro_sign` at bring-up, off-repo inputs now = sro_sim bank + `*_build_ref` kits + disk2 area; the base bank is retired), `docs/bringup.rst` (done in Task 12; cross-link), `ops/README.md`. Update the auto-memory files in `~/.claude/projects/-mnt-onetb-scratch-qpsk-jupiter-modem/memory/` that describe roles/images (`sp2-build-chain.md`, `repo-layout-2026-09.md`, `shipped-defaults-2026-08.md`, `MEMORY.md` lines) — one image, `sro_sign` conf, the sp3 md5. Commit `-s`, push.

---

### Task 15: Delete the injected flow

**Files:**
- Delete: `modem/fixes/` (everything left: `fixes.toml`, `apply_fixes.py`, `rxfix_inject.py`, `txfix_inject.py`, `rxfix_kit.sh`, `txfix_kit.sh`, `txfix_fetch.sh`, `pad_patch.py`, `add_postplace_report.sh`, `base_tree.sh`, `bank.sha256` (tarball/manifest lines; the sro_sim line lives in `modem/gates/bank.sha256` since Task 11), the `txfix_build*.tmpl` files → these move to `modem/vivado/` first if `build_image.sh`'s vivado stage still instantiates them (it does: keep `txfix_build.sh.tmpl`, `txfix_build.tcl.tmpl`, `txfix_kit_readme.md.tmpl` under `modem/vivado/`), `modem/fixes/tests/`), `modem/rtl_sim/build_sro_rxfix4d.sh` (R4D-alone, refuted variant), `modem/rtl_sim/wrap_byte_sro4b.v`/`4.v`/`3s.v` if only injected trees used them (check each with `grep -l` across `build_sro_*.sh`), the `s1_rtl_rxfix_*`/`s1_rtl_bs*`/`s1_rtl_pad`/`s1_rtl_txfix_*` untracked dirs (untracked: `rm -rf`, they are regenerable from the archive tag + the pristine tarball, which stays banked off-repo), `modem/instruments/byterxfifo/` drop-in if Task 7 reached the BRAM form.
- Modify: `modem/rtl_sim/make_sro_trees.sh` (`--from-regen` becomes the only mode), `modem/rtl_sim/build_sro_*.sh` (default `TREE` = `s1_rtl_model`), `tools/check_paths.sh` (drop the `rxfix_inject.py` waiver), `.github/workflows/docs.yml`, `docs/build-and-flash.rst`, `docs/byte-plane.rst`, `docs/debug-instruments.rst`, `docs/provenance.rst` ("rebuilt from the model, no injectors; the sp2 images and their injectors are on tag `archive/pre-cleanup-2026-09-09` plus commit `bd12da59`"), `images/README.md`.
- `git tag -s`? No: use `git tag -a archive/pre-sp3-injected-flow-2026-09 bd12da59 -m "..."` and push the tag, so the deleted flow has a second, precise anchor besides the cleanup tag.

- [ ] **Step 1:** `grep -rn "modem/fixes" --include='*.sh' --include='*.py' --include='*.rst' --include='*.md' --include='*.yml' --include='Makefile' . | grep -v "docs/evidence\|docs/superpowers"` → every hit fixed or waived before the delete. **Step 2:** `git rm -r modem/fixes` (after the `git mv`s), the other deletions, tag. **Step 3:** full verification: `tools/check_paths.sh`, `python3 modem/regmap/gen_regmap.py --check`, `make -C host clean all test`, `python3 -m pytest -p no:libiio modem ops -q`, `sphinx-build -W`, `cd tests && matlab -batch "runTests('L1')"` (17 pass / 2 incomplete), a fresh-clone `modem/build_image.sh --dry --stop-after hdl` from `/tmp/claude-1000/.../clone` proving nothing under `modem/fixes` is referenced. **Step 4:** commit `-s` `"sp3: delete the injected fix flow; the model is the source"`, push, confirm CI green.

---

### Task 16: Final verification and report

- [ ] Run the Task 15 Step 3 suite again on HEAD; confirm CI; write `docs/evidence/sp3/SP3_REPORT.md` (gates 0-3 results with pointers, the rulings above and any made during execution, the deployed md5, PER numbers with commands/sample counts/denominator statement, what was left out and why). Commit `-s`, push. Then `superpowers:finishing-a-development-branch`.

---

## Self-review notes (writer's pass)

- Spec coverage: Goal → Tasks 1-9, 11, 15; "What moves into the model" table → Tasks 4 (W1), 5 (R4B/R4D), 6 (R1), 7 (BS, PAD), 8 (F3, ruling 3), SEQ-BIST → Task 11 (ruling 4); "Runtime SRO select" → Tasks 5, 10, 12; Gate 1 → Tasks 3, 9; Gate 2 → Task 11; Gate 3 incl. bit-swap → Task 13; "Stated risk" → ruling 7 + Task 9 Step 3; "Cleanup at the end" → Task 15; "Done when" → Tasks 11 (no `--role`), 13, 15.
- Names used across tasks: `RxW1Census`, `RxSteer`, `PdPopIndex`, `BsSeamCensus`, `BsPad`/`padCount`, `FixCtlDec.{w1Freeze,sroSign}`, `tree_marker.sh`, `s1_rtl_model`, `FIXCTL=`/`TREE=`/`RTL_OBJ_SUFFIX=`, `score_matrix.py` (`loss_tol`, `count_tol`), `reference_loss.toml` `[ref."<V>/<stim>"]`, `modem/gates/`, `modem/regmap/regmap.toml`, `ops/sro_sign.sh` (`--check`, `--force <v>`), `ops/profiles/sro_sign.conf`, `MODEL_TREE_SHA`, `BUILD_IMAGE_NO_ROLE`, image name `BOOT.BIN.jupiter.<tag>.<md5>` with rail-shaped hard links.
- Known open points an executor must resolve on contact (each has an instruction in its task, none blocks Task 1): the exact Simulink block names inside Rate Handle / Preamble Detector / the transmitter (asserted at overlay run time), whether the regen ByteRxFifo reaches the BRAM form (Task 7 fallback), whether `n_p2p5.iq`/`n_m2p5.iq` stimuli exist as files (Task 3), the fixctl shadow-word convention on the boards (Task 12), and whether the 148 mode-1 BIST golden survives the new image (Task 13 Step 1).
