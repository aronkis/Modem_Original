# Fix Layer Promotion (cleanup sub-project 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `modem/build_image.sh --role A|B` rebuilds the two deployed images from a fresh clone plus one banked base tree, with the netlist injectors as a documented, manifest-driven stage, proven by the existing sim gates, the timing gate, and a credited silicon window per leg.

**Architecture:** The shipped chain is base Vivado tree → TXFIX F3 injection → SEQ-BIST kit → RXFIX variant injection → Vivado on hdl-dev-2 → bootgen. This plan keeps that chain byte-for-byte, moves its scripts under `modem/fixes/`, drives them from a `fixes.toml` manifest, and wraps them in one stage-runner. The base tree (a 2 GB Vivado project that no clone can carry) becomes a banked, checksummed artifact fetched by the runner; regenerating it from the Simulink model is the last task and is gated by RTL equivalence, so the deliverable does not hinge on HDL Coder reproducibility. The register window the fixes add is generated from the same manifest for both host consumers.

**Tech Stack:** bash, python3 (3.12; `tomllib`, `pytest`), Verilator/Icarus sim gates already in `modem/rtl_sim/`, Vivado 2025.1 on `hdl-dev-2` via `systemd-run --user`, MATLAB R2025b + HDL Coder on nemo (Task 12 only), rsync/ssh, the existing flash rails in `ops/skidfix/`.

**Spec:** `docs/superpowers/specs/2026-09-09-repo-and-design-cleanup-design.md`, sub-project 2 section. Chain evidence: `docs/superpowers/plans/2026-09-10-fix-layer-promotion-chain-trace.md` (condensed trace with file:line citations; read it before any task).

## Global Constraints

- Branch `per-under-1pct-2026-07`; every commit `git commit -s`; push to `origin` after each commit. Never `git add -A`.
- The two reference images are `images/BOOT.BIN.148.rxfixpad.bf2a7305bbe0` (role A: `W1 R4B BS PAD`, injector `f75d5223`) and `images/BOOT.BIN.146.rxfixr4dr1.9acbe2ebe1db` (role B: `W1 R4D R1`, injector `10b27b7`). Both are **148-lineage** kits: the rxfix kit script refuses a 146 board argument by design (`ops/skidfix/jupiter_byte_rxfix_kit.sh:80`). `build_image.sh` takes `--role`, never a board.
- Injection order is load-bearing and must be preserved: `W1` first, then `R4B`/`R4D`, then `BS`, then `PAD`; `R1` composes anywhere after `W1`.
- The authoritative timing gate is the post-route intra-clock WNS on `axi_adrv9001_adc_1_clk`. `TXFIX_ROUTED_WNS` (overall) and `TIMING_GATE_WNS` (post-synth) are NOT the gate. Ladder of accepted values: W1 +0.169, SEQ-BIST +0.227, R4B +0.437, R4D+R1 +0.620, PAD +0.105 ns. Acceptance for a rebuilt image: WNS ≥ 0 on that row, and within 0.1 ns of the reference image's value for the same role.
- Vivado runs only on `hdl-dev-2` (`/opt/Xilinx/2025.1/Vivado/bin`, 8 cores, ~47 GB free; each kit needs ≥25 GB per `build_txfix.sh:46-54`). At most two concurrent builds. Every remote build runs under `systemd-run --user` with `timeout 14400`, launched by the tracked template logic; never poll it in the foreground; watch with a background loop on the unit state and read the log at the end. `--dry` on `build_txfix.sh` is POSITIONAL; `DRY=1` in the environment launches a real build.
- Long local jobs (sim gates, MATLAB) run under `systemd-run --user --collect` with a timeout and an artifact post-check.
- Flashes are pre-authorised by the operator: run the rails (`ops/skidfix/flash_148_txfix.sh`, `flash_146_txfix.sh`) yourself, one board at a time, `FLASH_BAK` = the currently banked image, rollback `.bak` on-board verified by the rail's precondition. Never a raw `deploy_image.sh` for a candidate.
- Rig rules: IPs `10.0.0.148` / `10.0.0.146` only; never poll faster than 1 s; never kill an arm in flight; do not stop `sentinel-105922.service` or `sentinelkeeper-105921.service`; take the rig lock via the rails.
- Any PER number reported carries the command, the sample count, and the statement that lost frames are in the denominator. Acceptance per spec: forward within 2× of 0.070–0.079 %, reverse within 2× of 0.191 %, no new comb line, on a credited ≥10-minute window.
- `tools/check_paths.sh` must print `CHECK_PATHS_OK` at every commit; `make -C host clean all test` must pass; `sphinx-build -W` must pass; `tests/runTests('L1')` 17 pass / 2 incomplete.
- Off-repo bank: `/mnt/onetb/scratch/qpsk-build-trees/` (local) and `hdl-dev-2:~/qpsk-builds/` (remote). Nothing over 20 MiB is committed (the pre-commit size guard enforces it).
- `hdl-dev-2` is not in `~/.claude/HOSTS.md`; it is the Vivado host every kit script already names. Note it in the final report for the infra repo.

---

## File map

| Action | Path | Responsibility |
|---|---|---|
| Create | `modem/fixes/fixes.toml` | single source: fixes, order, injector, control bits, witness words, gates, per-role variant lists, reference images |
| Create | `modem/fixes/apply_fixes.py` + `tests/test_apply_fixes.py` | reads the manifest, runs the kit chain (txfix → seqbist → rxfix) against a base tree copy; `--plan` prints without running |
| Create | `modem/fixes/modem_wns.py` + `tests/test_modem_wns.py` | parses a Vivado timing summary, prints `MODEM_CLK_WNS clock=... wns=... tns=... failing=... total=...` |
| Create | `modem/fixes/gen_regmap.py` + `tests/test_gen_regmap.py` | emits `host/qpsk_fixregs.h` and `host/modem_status/ms_regmap_fixes.inc` from the manifest |
| Create | `modem/fixes/run_gates.sh` | runs the manifest's gate list (six SRO gates + seqbist unit) under systemd-run, collects logs |
| Create | `modem/rtl_sim/make_sro_trees.sh` | regenerates `s1_rtl` and the `s1_rtl_<variant>` trees from a base tree + injector |
| Create | `modem/build_image.sh` | stage runner: `base fixes gates vivado` (+ `hdl` in Task 12), `--role A|B`, `--from/--stop-after`, stamps |
| Create | `modem/fixes/base_tree.sh` | fetch/verify the banked base tree (`jupiter_byte_ddrcap2_build` minus runs) by manifest md5 |
| Create | `modem/instruments/<name>/README.md` + moved injectors | ddrcap, ddrcap2, dbgcap, demodcap, rxfe, stagesig, stagesig3, txcap, txint |
| Move | `ops/skidfix/{jupiter_byte_seqbist_kit.sh,jupiter_byte_rxfix_kit.sh,rxfix_inject.py,txfix_inject.py,test_rxfix_inject.py,patch_seqbist_tcl.py,pad_patch.py,txfix_build.sh.tmpl,txfix_build.tcl.tmpl,txfix_build_vendh.tcl.tmpl,txfix_kit_readme.md.tmpl}` → `modem/fixes/` | the fix kit |
| Recover from tag | `jupiter_byte_txfix_kit.sh`, `jupiter_byte_txfix_fetch.sh` → `modem/fixes/txfix_kit.sh`, `txfix_fetch.sh`; `two_jup/arm148_mode1.sh` → `ops/skidfix/arm148_mode1.sh`; `two_jup/rxfix/add_postplace_report.sh` → `modem/fixes/add_postplace_report.sh` | chain pieces that exist only on the tag |
| Move | `ops/skidfix/flash_148_txfix.sh`, `flash_146_txfix.sh`, `txfix_flash_go.sh`, `txfix_flash146_go.sh`, `arm148_mode1.sh` → `ops/flash/` | flash rails stay operator kit |
| Modify | `host/qpsk_hw.h` (include the generated header), `host/modem_status/ms_regmap.c` (include the generated table rows), `host/Makefile` (regen check target) | generated register map |
| Modify | `.github/workflows/docs.yml` (regmap regen diff job), `tools/check_paths.sh` (drop the `ops/skidfix` waiver), `.gitignore` | CI and gates |
| Modify | `docs/build-and-flash.rst`, `docs/provenance.rst`, `docs/byte-plane.rst`, `docs/debug-instruments.rst`, `images/CURRENT.txt`, `images/README.md`, `ops/README.md` | docs and provenance |
| Delete | `ops/skidfix/` (after every file has a home), `modem/rtl_sim/build_sro_rxfix{,2,3,3s,4,4e}.sh`, rejected-variant gate ledgers stay in `docs/evidence/` | cleanup |

---

### Task 1: Recover the chain pieces that exist only on the tag, the bank, or the remote

**Files:**
- Create: `modem/fixes/txfix_kit.sh`, `modem/fixes/txfix_fetch.sh`, `modem/fixes/add_postplace_report.sh`, `ops/skidfix/arm148_mode1.sh`
- Modify: `ops/skidfix/flash_146_txfix.sh:62` (`ROLLBACK_BANK` default)
- Create (off-repo): `/mnt/onetb/scratch/qpsk-build-trees/base/jupiter_byte_ddrcap2_build/` (rsync from `hdl-dev-2`, runs excluded), `/mnt/onetb/scratch/qpsk-build-trees/base/BASE_MANIFEST.txt`, `/mnt/onetb/scratch/qpsk-build-trees/ref/jupiter_byte_rxfixr4dr1_build/` (146 reference kit, runs excluded), `/mnt/onetb/scratch/qpsk-build-trees/ref/rxfixpad_ipcore/`, `/mnt/onetb/scratch/qpsk-build-trees/ref/rxfixr4dr1_ipcore/` (the patched `TxRxCompo_ip_v1_0` RTL of both reference kits, for the equivalence gate), and both reference kits' `impl_1/*timing_summary*.rpt`

**Interfaces:**
- Produces: `BASE_MANIFEST.txt` = `sha256sum` of every file in the base tree (relative paths), plus a header line `base=jupiter_byte_ddrcap2_build source=hdl-dev-2:~/qpsk-builds fetched=<date>`. Task 4's `base_tree.sh` verifies against it. The ref ipcore dirs are what Task 5's equivalence check diffs against.

- [ ] **Step 1: Recover the four scripts from the tag and read their headers**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem
mkdir -p modem/fixes
git show archive/pre-cleanup-2026-09-09:jupiter_byte_txfix_kit.sh   > modem/fixes/txfix_kit.sh
git show archive/pre-cleanup-2026-09-09:jupiter_byte_txfix_fetch.sh > modem/fixes/txfix_fetch.sh
git show archive/pre-cleanup-2026-09-09:two_jup/rxfix/add_postplace_report.sh > modem/fixes/add_postplace_report.sh
git show archive/pre-cleanup-2026-09-09:two_jup/arm148_mode1.sh > ops/skidfix/arm148_mode1.sh
chmod +x modem/fixes/*.sh ops/skidfix/arm148_mode1.sh
bash -n modem/fixes/txfix_kit.sh modem/fixes/txfix_fetch.sh modem/fixes/add_postplace_report.sh ops/skidfix/arm148_mode1.sh && echo SYNTAX_OK
grep -n "HERE=\|ROOT=\|two_jup\|skidfix\|jupiter_byte_ddrcap2_build\|TMPL_SH=\|TMPL_TCL=" modem/fixes/txfix_kit.sh | head -20
```
Expected: `SYNTAX_OK`; the grep shows `HERE`/`ROOT` derivations and the template paths `two_jup/skidfix/txfix_build.sh.tmpl` (rewritten in Task 2 when the templates move).

- [ ] **Step 2: Fix the two known dangling defaults**

In `ops/skidfix/flash_146_txfix.sh` line 62, change the `ROLLBACK_BANK` default from `$ROOT/jupiter_byte_tmr146_gates/variants_placement/v_endh/BOOT.BIN` to `$ROOT/images/BOOT.BIN.146.w1x148.2728dab3979a` (the banked on-board rollback for 146; `images/CURRENT.txt` names it). In `ops/skidfix/flash_148_txfix.sh` line 75, confirm the `arm148_mode1.sh` path resolves to `ops/skidfix/arm148_mode1.sh` (adjust `$(dirname "$0")` usage if it pointed at `two_jup/`).

```bash
grep -n "ROLLBACK_BANK=" ops/skidfix/flash_146_txfix.sh; grep -n "arm148_mode1" ops/skidfix/flash_148_txfix.sh
bash -n ops/skidfix/flash_146_txfix.sh ops/skidfix/flash_148_txfix.sh && echo OK
```

- [ ] **Step 3: Bank the base tree and the reference material from hdl-dev-2**

```bash
B=/mnt/onetb/scratch/qpsk-build-trees
mkdir -p $B/base $B/ref
EXCL='--exclude vivado_prj.runs/synth_1/ --exclude vivado_prj.runs/impl_1/ --exclude vivado_prj.runs/v_*/ --exclude vivado_prj.cache/ --exclude vivado_prj.sim/ --exclude vivado_prj.hw/ --exclude *.log --exclude *.jou'
rsync -a $EXCL hdl-dev-2:qpsk-builds/jupiter_byte_ddrcap2_build/ $B/base/jupiter_byte_ddrcap2_build/
rsync -a $EXCL hdl-dev-2:qpsk-builds/jupiter_byte_rxfixr4dr1_build/ $B/ref/jupiter_byte_rxfixr4dr1_build/
for k in rxfixpad rxfixr4dr1; do
  rsync -a hdl-dev-2:qpsk-builds/jupiter_byte_${k}_build/hdl_prj_jupiter_composite/ipcore/TxRxCompo_ip_v1_0/ $B/ref/${k}_ipcore/
  rsync -a --include '*timing_summary*.rpt' --include '*/' --exclude '*' hdl-dev-2:qpsk-builds/jupiter_byte_${k}_build/hdl_prj_jupiter_composite/vivado_ip_prj/vivado_prj.runs/impl_1/ $B/ref/${k}_impl1_reports/
done
du -sh $B/base/jupiter_byte_ddrcap2_build $B/ref/*
ls $B/ref/rxfixpad_impl1_reports/ | head
```
Expected: base tree a few hundred MB; each `*_ipcore` a few MB of `.v` files; the reports dir contains `system_top_timing_summary_routed.rpt` (and/or `..._postroute_physopted.rpt`). If the impl_1 reports are missing on the remote (they live under `vivado_prj.runs/impl_1`, which the remote kit keeps), say so; Task 6's parser test then uses the excerpt quoted in `docs/evidence/comb/FWD_CRC_REGRESSION_0907.md:4874-4882` instead.

- [ ] **Step 4: Write the base manifest and verify the reference stamps**

```bash
B=/mnt/onetb/scratch/qpsk-build-trees
( cd $B/base/jupiter_byte_ddrcap2_build && find . -type f -print0 | sort -z | xargs -0 sha256sum ) > $B/base/BASE_MANIFEST.body
{ echo "base=jupiter_byte_ddrcap2_build source=hdl-dev-2:~/qpsk-builds fetched=$(date -Is) files=$(wc -l < $B/base/BASE_MANIFEST.body)"; cat $B/base/BASE_MANIFEST.body; } > $B/base/BASE_MANIFEST.txt
sha256sum $B/base/BASE_MANIFEST.txt | cut -c1-16
ssh hdl-dev-2 'for k in rxfixpad rxfixr4dr1; do echo "== $k"; cat qpsk-builds/jupiter_byte_${k}_build/{TXFIX_VARIANT,SEQBIST_VARIANT,RXFIX_VARIANT}; done'
```
Expected: the stamps print `F3`, `148 ... WITH_CRC=1`, and `W1 R4B BS PAD` / `W1 R4D R1` with injector commits `f75d5223...` / `10b27b7...`. Record all three stamps per kit in the report; Task 2's manifest copies them.

- [ ] **Step 5: Commit the recovered scripts**

```bash
git add modem/fixes/txfix_kit.sh modem/fixes/txfix_fetch.sh modem/fixes/add_postplace_report.sh ops/skidfix/arm148_mode1.sh ops/skidfix/flash_146_txfix.sh ops/skidfix/flash_148_txfix.sh
git commit -s -m "fixes: recover txfix kit builder, postplace hook generator and arm148_mode1 from the tag; flash_146 rollback default -> images/

Base tree jupiter_byte_ddrcap2_build and both reference kits' patched ipcore RTL banked under /mnt/onetb/scratch/qpsk-build-trees/{base,ref} (BASE_MANIFEST.txt sha256 <prefix>)."
git push origin per-under-1pct-2026-07
```

---

### Task 2: Move the fix kit under `modem/fixes/` and make every path relative to the repo root

**Files:**
- Move: `ops/skidfix/{jupiter_byte_seqbist_kit.sh,jupiter_byte_rxfix_kit.sh,rxfix_inject.py,txfix_inject.py,test_rxfix_inject.py,patch_seqbist_tcl.py,pad_patch.py,txfix_build.sh.tmpl,txfix_build.tcl.tmpl,txfix_build_vendh.tcl.tmpl,txfix_kit_readme.md.tmpl}` → `modem/fixes/` (names: `seqbist_kit.sh`, `rxfix_kit.sh`, rest unchanged)
- Modify: every moved script's `HERE`/`ROOT`/template/injector path; `modem/fixes/txfix_kit.sh` (from Task 1); `modem/rtl_sim/build_sro_*.sh` references to `ops/skidfix/rxfix_inject.py`; `modem/rtl_sim/build_beat_sim.sh`, `build_ddrcap2_sim.sh` (they name `ops/skidfix`)
- Test: `modem/fixes/test_rxfix_inject.py` (existing) must still pass from its new location

**Interfaces:**
- Produces: `modem/fixes/txfix_kit.sh <VARIANT> [SRC_KIT_DIR] [DEST_PARENT]`, `modem/fixes/seqbist_kit.sh <LINEAGE> [SRC_KIT_DIR] [DEST_PARENT]`, `modem/fixes/rxfix_kit.sh <LINEAGE> [SRC_KIT_DIR] [DEST_PARENT]` with `RXFIX_VARIANTS` in the environment as today. The two optional positionals default to today's behaviour (kits as siblings of the repo root) so the scripts keep working by hand; `apply_fixes.py` (Task 3) always passes both.

- [ ] **Step 1: Move with history**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem
git mv ops/skidfix/jupiter_byte_seqbist_kit.sh modem/fixes/seqbist_kit.sh
git mv ops/skidfix/jupiter_byte_rxfix_kit.sh   modem/fixes/rxfix_kit.sh
for f in rxfix_inject.py txfix_inject.py test_rxfix_inject.py patch_seqbist_tcl.py pad_patch.py txfix_build.sh.tmpl txfix_build.tcl.tmpl txfix_build_vendh.tcl.tmpl txfix_kit_readme.md.tmpl; do git mv ops/skidfix/$f modem/fixes/$f; done
git ls-files modem/fixes | wc -l
```
Expected: 15 (11 moved + 4 from Task 1).

- [ ] **Step 2: Parameterise the kit scripts**

In each of `txfix_kit.sh`, `seqbist_kit.sh`, `rxfix_kit.sh`:
- `HERE="$(cd "$(dirname "$0")" && pwd)"` and `ROOT="$(cd "$HERE/../.." && pwd)"`.
- Replace `two_jup/skidfix/` → `modem/fixes/` for templates and injectors (`TMPL_SH="$HERE/txfix_build.sh.tmpl"`, `python3 "$HERE/rxfix_inject.py"`, `python3 "$HERE/patch_seqbist_tcl.py"`, `python3 "$HERE/txfix_inject.py"`).
- Replace `modem/rtl_sim/` copies (`qpsk_traffic_gen_v2.v` etc.) with `$ROOT/modem/rtl_sim/...`.
- Add optional positionals: `SRC_KIT_DIR="${2:-$ROOT/../$SRC_KIT_NAME}"`, `DEST_PARENT="${3:-$ROOT/..}"`; kit path = `$DEST_PARENT/$KIT_NAME`. Keep the existing kit-name guards (`jupiter_byte_txfix*_build`, `jupiter_byte_seqbist*_build`, `jupiter_byte_rxfix*_build`) untouched: `build_txfix.sh` derives its remote dir from the basename.
- Keep the injector-provenance check (`rxfix_kit.sh:106-113`) but make the "dirty injector" test look at `modem/fixes/rxfix_inject.py`.

```bash
grep -n "two_jup\|skidfix\|jupiter_240k5_byte" modem/fixes/*.sh modem/fixes/*.py modem/fixes/*.tmpl | grep -v "^modem/fixes/txfix_kit_readme.md.tmpl" 
```
Expected: no output (the readme template may keep its historical prose; rewrite its `ops/skidfix/` mentions to `modem/fixes/`).

- [ ] **Step 3: Fix the sim-gate scripts that call the injector**

```bash
grep -ln "ops/skidfix" modem/rtl_sim/*.sh modem/rtl_sim/*.py | tee /dev/stderr | xargs sed -i 's#ops/skidfix/rxfix_inject.py#modem/fixes/rxfix_inject.py#g; s#ops/skidfix/pad_patch.py#modem/fixes/pad_patch.py#g; s#ops/skidfix/#modem/fixes/#g'
grep -rn "ops/skidfix" modem/ | grep -v "^modem/fixes/txfix_kit_readme" ; echo "remaining=$?"
for f in modem/rtl_sim/build_sro_*.sh modem/fixes/*.sh; do bash -n "$f" || echo "SYNTAX $f"; done
```
Expected: `remaining=1` (grep found nothing); no `SYNTAX` lines. Note: `modem/rtl_sim/build_beat_sim.sh` and `build_ddrcap2_sim.sh` reference instrument injectors that move in Task 8; point them at `modem/instruments/<name>/<name>_inject.py` now, matching Task 8's layout.

- [ ] **Step 4: Run the injector unit tests from the new location**

```bash
cd modem/fixes && python3 -m pytest test_rxfix_inject.py -q 2>&1 | tail -3; cd ../..
```
Expected: all pass (the count the file reports; record it). If it imports `ops.skidfix` or relies on a cwd, fix the import to a relative one.

- [ ] **Step 5: Dry-run the chain by hand against the banked base tree**

```bash
B=/mnt/onetb/scratch/qpsk-build-trees; W=$B/work; mkdir -p $W
modem/fixes/txfix_kit.sh F3 $B/base/jupiter_byte_ddrcap2_build $W 2>&1 | tail -5
cat $W/jupiter_byte_txfixF3_build/TXFIX_VARIANT
modem/fixes/seqbist_kit.sh 148 $W/jupiter_byte_txfixF3_build $W 2>&1 | tail -5
cat $W/jupiter_byte_seqbist_build/SEQBIST_VARIANT
RXFIX_VARIANTS='W1 R4B BS PAD' modem/fixes/rxfix_kit.sh 148 $W/jupiter_byte_seqbist_build $W 2>&1 | tail -8
cat $W/jupiter_byte_rxfixpad_build/RXFIX_VARIANT
```
Expected: three kits under `$W`, each with its stamp; the rxfix run prints `r4b_witness=on`, the 3-copies/2-zips verification lines, and no `skipped=`. Nothing is sent to hdl-dev-2 (the kit scripts never launch Vivado; only `build_txfix.sh` does, and you do not run it here).

- [ ] **Step 6: Equivalence check of the patched RTL against the reference kit**

```bash
B=/mnt/onetb/scratch/qpsk-build-trees
diff -rq $B/work/jupiter_byte_rxfixpad_build/hdl_prj_jupiter_composite/ipcore/TxRxCompo_ip_v1_0 $B/ref/rxfixpad_ipcore | grep -v '\.zip' | tee $B/work/equiv_A.txt | wc -l
```
Expected: 0 differing `.v` files if the injector's W1/R4B/BS/PAD code paths are unchanged since commit `f75d5223`. If files differ, for each: `git log --oneline f75d5223..HEAD -- modem/fixes/rxfix_inject.py` and `diff` the file; every difference must be attributable to a listed injector commit and must not touch the W1/R4B/BS/PAD logic. Record the verdict in the report; an unexplained difference is BLOCKED (report, do not proceed).

- [ ] **Step 7: Commit**

```bash
git add -u; git add modem/fixes modem/rtl_sim
git commit -s -m "modem/fixes: the netlist fix kit moves under modem/, kit scripts take src/dest paths, sim gates point at the new injector path

Chain re-run by hand against the banked base tree: F3 -> seqbist 148 -> rxfix W1 R4B BS PAD; patched TxRxCompo_ip_v1_0 RTL diffed against the reference rxfixpad kit: <N> differing files, <explanation>."
git push origin per-under-1pct-2026-07
```

---

### Task 3: The manifest and `apply_fixes.py`

**Files:**
- Create: `modem/fixes/fixes.toml`, `modem/fixes/apply_fixes.py`, `modem/fixes/tests/test_apply_fixes.py`, `modem/fixes/tests/conftest.py`
- Test: `python3 -m pytest modem/fixes/tests -q`

**Interfaces:**
- Produces: `apply_fixes.py --manifest modem/fixes/fixes.toml --role A --base <dir> --work <dir> [--plan] [--instrument NAME ...]`. Exit 0 and prints `APPLY_FIXES_DONE kit=<path> variants=<list> manifest_sha=<16hex>`; `--plan` prints the ordered command list and exits 0 without touching disk. The kit path it produces is `<work>/jupiter_byte_rxfix<suffix>_build` exactly as the kit scripts name it. Also exposes `load_manifest(path) -> dict` and `role_variants(manifest, role) -> list[str]` for Task 7's generator.
- The manifest schema (all keys required unless noted):

```toml
[meta]
schema = 1
base_tree = "jupiter_byte_ddrcap2_build"
base_manifest_sha256 = "<sha256 of BASE_MANIFEST.txt>"     # from Task 1
vivado_host = "hdl-dev-2"
vivado_path = "/opt/Xilinx/2025.1/Vivado/bin"
timing_clock = "axi_adrv9001_adc_1_clk"

[chain]                       # applied in this order, before any rxfix variant
txfix = { script = "txfix_kit.sh", variant = "F3", injector = "txfix_inject.py" }
seqbist = { script = "seqbist_kit.sh", lineage = "148", with_crc = 1, rtl = ["modem/rtl_sim/qpsk_traffic_gen_v2.v", "modem/rtl_sim/rx_seq_checker.v", "modem/rtl_sim/cnt_mux32.v"] }
rxfix = { script = "rxfix_kit.sh", lineage = "148", injector = "rxfix_inject.py" }

[roles.A]
board = "148"
variants = ["W1", "R4B", "BS", "PAD"]
kit_suffix = "pad"
reference_image = "images/BOOT.BIN.148.rxfixpad.bf2a7305bbe0"
reference_md5 = "bf2a7305bbe0e0e38b3529d09edddaef"
reference_injector_commit = "f75d52236b5c0c1d9d12c169cbf26d099ca23d04"
reference_modem_wns_ns = 0.105
sro_sign = "negative"        # receiver oscillator faster: EMPTY-edge steering

[roles.B]
board = "146"
variants = ["W1", "R4D", "R1"]
kit_suffix = "r4dr1"
reference_image = "images/BOOT.BIN.146.rxfixr4dr1.9acbe2ebe1db"
reference_md5 = "9acbe2ebe1dbf280e030952fc4fc23d8"
reference_injector_commit = "10b27b7"
reference_modem_wns_ns = 0.620
sro_sign = "positive"

[fixes.W1]
order = 10
files = ["Validate_Input_Push_Pop_block", "FIFO_block", "Rate_Handle", "Symbol_Synchronizer", "Frequency_and_Time_Synchronizer", "QPSK_Rx", "Receiver", "TxRxComposite", "TxRxCompo_ip", "TxRxCompo_ip_dut", "TxRxCompo_ip_axi_lite", "TxRxCompo_ip_addr_decoder"]
control = [{ reg = 0x208, bit = 4, name = "w1_freeze", kind = "level" }]
witness = [
  { addr = 0x214, name = "W1_WITA", fields = "[15:10] occTrue [9:5] pushPtr [4:0] popPtr" },
  { addr = 0x218, name = "W1_WITB", fields = "[31:16] push_on_full [15:0] pop_on_empty" },
  { addr = 0x21C, name = "W1_CNT_SS" }, { addr = 0x220, name = "W1_CNT_RH" }, { addr = 0x224, name = "W1_CNT_CFC" },
  { addr = 0x228, name = "W1_CNT_CS" }, { addr = 0x22C, name = "W1_CNT_PD" }, { addr = 0x230, name = "W1_CNT_PC" } ]
gates = ["build_sro_w1.sh"]

[fixes.R4B]
order = 20
requires = ["W1"]
files = ["Rate_Handle", "TxRxCompo_ip_addr_decoder"]
witness = [{ addr = 0x234, name = "r4_wit", fields = "{locked[31] skips[30:15] opens[14:0]}" }]
gates = ["build_sro_rxfix4b.sh"]

[fixes.R4D]
order = 20
requires = ["W1"]
conflicts = ["R4B"]
files = ["Rate_Handle", "TxRxCompo_ip_addr_decoder"]
witness = [
  { addr = 0x234, name = "r4_wit",    fields = "{locked[31] skips[30:15] opens[14:0]}" },
  { addr = 0x238, name = "r4_extras", fields = "{16'b0 extras[15:0]}" } ]
witness_swapped_in_images = ["9acbe2ebe1dbf280e030952fc4fc23d8"]   # silicon exception, W1_REGMAP.md 6-R4D.2
gates = ["build_sro_rxfix4d.sh", "build_sro_rxfix4dr1.sh"]

[fixes.R1]
order = 25
requires = ["W1"]
files = ["Preamble_Detector"]
gates = ["build_sro_rxfix4dr1.sh"]

[fixes.BS]
order = 30
requires = ["W1"]
files = ["ByteSerializer", "ByteRxFifo", "TxRxComposite", "TxRxCompo_ip_addr_decoder"]
control = [{ reg = 0x208, bit = 4, name = "w1_freeze", kind = "level", shared = true }]
witness = [
  { addr = 0x23C, name = "bs_words" }, { addr = 0x240, name = "bs_starts" }, { addr = 0x244, name = "bs_push" }, { addr = 0x248, name = "bs_pop" },
  { addr = 0x24C, name = "bs_drop" }, { addr = 0x250, name = "bs_marks", fields = "{lasts[31:16] markpush[15:0]}" },
  { addr = 0x254, name = "bs_evt", fields = "{trunc_last trunc_min trunc_max dropmax}" }, { addr = 0x258, name = "bs_cnt", fields = "{trunc[31:16] q24[15:8]}" } ]
gates = ["build_sro_bs.sh"]

[fixes.PAD]
order = 40
requires = ["BS"]
files = ["ByteSerializer"]
gates = ["build_sro_pad.sh"]

[gates]
common = ["seqbist_unit/run_unit.sh"]
```

- [ ] **Step 1: Write the failing tests**

`modem/fixes/tests/test_apply_fixes.py`:
```python
import subprocess, sys, pathlib, tomllib
HERE = pathlib.Path(__file__).resolve().parent
FIXES = HERE.parent
sys.path.insert(0, str(FIXES))
import apply_fixes as af

def test_manifest_loads_and_roles_ordered():
    m = af.load_manifest(FIXES / "fixes.toml")
    assert af.role_variants(m, "A") == ["W1", "R4B", "BS", "PAD"]
    assert af.role_variants(m, "B") == ["W1", "R4D", "R1"]

def test_role_order_respects_requires_and_conflicts():
    m = af.load_manifest(FIXES / "fixes.toml")
    bad = dict(m); bad["roles"] = {"X": {"variants": ["PAD", "W1"], "kit_suffix": "x", "board": "148"}}
    try:
        af.role_variants(bad, "X"); assert False, "PAD before BS/W1 must fail"
    except af.ManifestError as e:
        assert "PAD" in str(e)
    bad["roles"] = {"Y": {"variants": ["W1", "R4B", "R4D"], "kit_suffix": "y", "board": "148"}}
    try:
        af.role_variants(bad, "Y"); assert False
    except af.ManifestError as e:
        assert "conflicts" in str(e)

def test_plan_prints_chain_without_touching_disk(tmp_path):
    out = subprocess.run([sys.executable, str(FIXES / "apply_fixes.py"), "--manifest", str(FIXES / "fixes.toml"),
                          "--role", "A", "--base", str(tmp_path / "nobase"), "--work", str(tmp_path / "w"), "--plan"],
                         capture_output=True, text=True)
    assert out.returncode == 0, out.stderr
    lines = out.stdout.splitlines()
    assert any("txfix_kit.sh F3" in l for l in lines)
    assert any("seqbist_kit.sh 148" in l for l in lines)
    assert any("RXFIX_VARIANTS='W1 R4B BS PAD'" in l and "rxfix_kit.sh 148" in l for l in lines)
    assert not (tmp_path / "w").exists()

def test_manifest_sha_is_stable():
    m1 = af.manifest_sha(FIXES / "fixes.toml"); m2 = af.manifest_sha(FIXES / "fixes.toml")
    assert m1 == m2 and len(m1) == 16

def test_witness_addresses_unique_per_role():
    m = af.load_manifest(FIXES / "fixes.toml")
    for role in ("A", "B"):
        addrs = [w["addr"] for v in af.role_variants(m, role) for w in m["fixes"][v].get("witness", [])]
        assert len(addrs) == len(set(addrs)), role
```

- [ ] **Step 2: Run to see them fail**

```bash
python3 -m pytest modem/fixes/tests -q 2>&1 | tail -3
```
Expected: `ModuleNotFoundError: apply_fixes` (or file-not-found for fixes.toml).

- [ ] **Step 3: Write `fixes.toml` (the schema above, with the real `base_manifest_sha256` from Task 1) and `apply_fixes.py`**

`apply_fixes.py` responsibilities, in order:
1. `load_manifest(path)`: `tomllib.load`; validate `meta.schema == 1`, every role's variants exist in `[fixes]`, every `requires`/`conflicts` name exists. Raise `ManifestError` (a `ValueError` subclass) with the offending name in the message.
2. `role_variants(manifest, role)`: return the role's list after checking it is sorted by `order` (stable), every `requires` appears earlier, and no `conflicts` member appears at all. Do not reorder silently: a wrong order is an error, because the kit scripts apply what they are given.
3. `manifest_sha(path)`: first 16 hex of sha256 of the file bytes.
4. `plan(manifest, role, base, work)`: list of `(cwd, argv, env)` triples: `txfix_kit.sh F3 <base> <work>`, `seqbist_kit.sh 148 <work>/jupiter_byte_txfixF3_build <work>`, `RXFIX_VARIANTS='...' rxfix_kit.sh 148 <work>/jupiter_byte_seqbist_build <work>`; for each `--instrument NAME` append `python3 modem/instruments/NAME/NAME_inject.py <kit>` after the rxfix step (Task 8 defines that CLI).
5. `main()`: argparse; `--plan` prints one shell-quoted line per step and exits 0; otherwise verify `base` against `meta.base_manifest_sha256` by hashing the base tree's `BASE_MANIFEST.txt` beside it (`<base>/../BASE_MANIFEST.txt`), run the steps with `subprocess.run(check=True)` streaming output, then write `<kit>/FIXES_MANIFEST` containing `manifest_sha=<16hex>\nrole=<A|B>\nvariants=<space list>\ngit=<git rev-parse HEAD>\n` and print the `APPLY_FIXES_DONE` line.

- [ ] **Step 4: Run the tests**

```bash
python3 -m pytest modem/fixes/tests -q 2>&1 | tail -3
```
Expected: 5 passed.

- [ ] **Step 5: Real run for role A against the banked base tree, then equivalence**

```bash
B=/mnt/onetb/scratch/qpsk-build-trees; rm -rf $B/work && mkdir -p $B/work
python3 modem/fixes/apply_fixes.py --manifest modem/fixes/fixes.toml --role A --base $B/base/jupiter_byte_ddrcap2_build --work $B/work 2>&1 | tail -4
cat $B/work/jupiter_byte_rxfixpad_build/FIXES_MANIFEST
diff -rq $B/work/jupiter_byte_rxfixpad_build/hdl_prj_jupiter_composite/ipcore/TxRxCompo_ip_v1_0 $B/ref/rxfixpad_ipcore | grep -v '\.zip' | wc -l
```
Expected: `APPLY_FIXES_DONE kit=... variants=W1 R4B BS PAD manifest_sha=...`; the diff count equals Task 2 Step 6's count (the same chain, now driven by the manifest).

- [ ] **Step 6: Commit**

```bash
git add modem/fixes/fixes.toml modem/fixes/apply_fixes.py modem/fixes/tests
git commit -s -m "modem/fixes: fixes.toml manifest and apply_fixes.py (txfix -> seqbist -> rxfix chain driven from one file, --plan dry run, order/requires/conflicts validated)"
git push origin per-under-1pct-2026-07
```

---

### Task 4: `base_tree.sh` and the `base` stage

**Files:**
- Create: `modem/fixes/base_tree.sh`
- Test: shell-level, in the steps

**Interfaces:**
- Produces: `modem/fixes/base_tree.sh fetch|verify <dest_parent>`: `fetch` rsyncs `hdl-dev-2:qpsk-builds/jupiter_byte_ddrcap2_build` (runs excluded, same exclude list as `txfix_build.sh.tmpl:66-78`) into `<dest_parent>/jupiter_byte_ddrcap2_build` unless a local `/mnt/onetb/scratch/qpsk-build-trees/base/` copy exists (copied with `rsync -a` then); `verify` recomputes the sha256 list and compares against `<dest_parent>/BASE_MANIFEST.txt` and against `meta.base_manifest_sha256` in the manifest; prints `BASE_TREE_OK files=<n>` or `BASE_TREE_MISMATCH <first differing path>` and exits 1.

- [ ] **Step 1: Write the script**

```bash
#!/bin/bash
# base_tree.sh -- fetch/verify the banked base Vivado tree the fix chain starts from.
# The base tree (jupiter_byte_ddrcap2_build, ~hundreds of MB without runs) cannot live
# in git; it is banked locally and on hdl-dev-2 and pinned by sha256 in fixes.toml.
# Usage: base_tree.sh fetch <dest_parent> | verify <dest_parent>
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)
MAN="$HERE/fixes.toml"
NAME=$(python3 -c "import tomllib,sys;print(tomllib.load(open(sys.argv[1],'rb'))['meta']['base_tree'])" "$MAN")
WANT=$(python3 -c "import tomllib,sys;print(tomllib.load(open(sys.argv[1],'rb'))['meta']['base_manifest_sha256'])" "$MAN")
HOST=$(python3 -c "import tomllib,sys;print(tomllib.load(open(sys.argv[1],'rb'))['meta']['vivado_host'])" "$MAN")
LOCAL_BANK=/mnt/onetb/scratch/qpsk-build-trees/base
CMD=${1:?fetch|verify}; DEST=${2:?dest_parent}
EXCL=(--exclude 'vivado_prj.runs/synth_1/' --exclude 'vivado_prj.runs/impl_1/' --exclude 'vivado_prj.runs/v_*/' --exclude 'vivado_prj.cache/' --exclude 'vivado_prj.sim/' --exclude 'vivado_prj.hw/' --exclude '*.log' --exclude '*.jou')
manifest_body() { ( cd "$1" && find . -type f -print0 | sort -z | xargs -0 sha256sum ); }
case "$CMD" in
  fetch)
    mkdir -p "$DEST"
    if [ -d "$LOCAL_BANK/$NAME" ]; then rsync -a "${EXCL[@]}" "$LOCAL_BANK/$NAME/" "$DEST/$NAME/"; cp "$LOCAL_BANK/BASE_MANIFEST.txt" "$DEST/"
    else rsync -a "${EXCL[@]}" "$HOST:qpsk-builds/$NAME/" "$DEST/$NAME/"
         { echo "base=$NAME source=$HOST:~/qpsk-builds fetched=$(date -Is)"; manifest_body "$DEST/$NAME"; } > "$DEST/BASE_MANIFEST.txt"; fi
    exec "$0" verify "$DEST" ;;
  verify)
    [ -f "$DEST/BASE_MANIFEST.txt" ] || { echo "BASE_TREE_MISMATCH no BASE_MANIFEST.txt in $DEST"; exit 1; }
    HAVE=$(sha256sum "$DEST/BASE_MANIFEST.txt" | cut -d' ' -f1)
    [ "$HAVE" = "$WANT" ] || { echo "BASE_TREE_MISMATCH manifest sha $HAVE != $WANT"; exit 1; }
    manifest_body "$DEST/$NAME" > "$DEST/.verify.body"
    if ! diff -q <(tail -n +2 "$DEST/BASE_MANIFEST.txt") "$DEST/.verify.body" >/dev/null; then
      echo "BASE_TREE_MISMATCH $(diff <(tail -n +2 "$DEST/BASE_MANIFEST.txt") "$DEST/.verify.body" | grep '^[<>]' | head -1)"; exit 1; fi
    echo "BASE_TREE_OK files=$(wc -l < "$DEST/.verify.body")" ;;
  *) echo "usage: $0 fetch|verify <dest_parent>"; exit 2 ;;
esac
```
Note the manifest header line format must match Task 1's exactly (`base=... source=... fetched=... files=N`); if Task 1 wrote `files=` in the header, keep `tail -n +2` and compare the body only, as above.

- [ ] **Step 2: Verify against the bank, then a negative test**

```bash
B=/mnt/onetb/scratch/qpsk-build-trees
modem/fixes/base_tree.sh verify $B/base
cp -r $B/base $B/base_tamper && echo x >> $B/base_tamper/jupiter_byte_ddrcap2_build/hdl_prj_jupiter_composite/ipcore/TxRxCompo_ip_v1_0/src/TxRxCompo_ip_src_Rate_Handle.v
modem/fixes/base_tree.sh verify $B/base_tamper; echo "exit=$?"; rm -rf $B/base_tamper
```
Expected: `BASE_TREE_OK files=<n>`; then `BASE_TREE_MISMATCH ...Rate_Handle.v` and `exit=1`. (If `meta.base_manifest_sha256` is the sha of the whole file including the header, `verify` must compute it the same way; keep the two consistent and say which in the script comment.)

- [ ] **Step 3: Commit**

```bash
git add modem/fixes/base_tree.sh
git commit -s -m "modem/fixes: base_tree.sh fetches/verifies the banked base Vivado tree against the manifest sha256"
git push origin per-under-1pct-2026-07
```

---

### Task 5: Sim-gate trees and `run_gates.sh` (Stage 4)

**Files:**
- Create: `modem/rtl_sim/make_sro_trees.sh`, `modem/fixes/run_gates.sh`
- Delete: `modem/rtl_sim/build_sro_rxfix.sh`, `build_sro_rxfix2.sh`, `build_sro_rxfix3.sh`, `build_sro_rxfix3s.sh`, `build_sro_rxfix4.sh`, `build_sro_rxfix4e.sh` (rejected variants; ledgers stay in `docs/evidence/rxfix/`)
- Modify: `.gitignore` (the `s1_rtl_*` block from sub-project 1 already ignores generated trees; confirm `modem/rtl_sim/s1_rtl/` is ignored too)
- Test: the six gate scripts' own pass criteria plus `seqbist_unit/run_unit.sh`

**Interfaces:**
- Consumes: a kit produced by `apply_fixes.py` (has `hdl_prj_jupiter_composite/hdlsrc/...` pristine? No: the kit is already injected. The pristine netlist comes from the base tree.)
- Produces: `make_sro_trees.sh <base_tree> <variant...>` writes `modem/rtl_sim/s1_rtl` (pristine copy of `<base>/hdl_prj_jupiter_composite/hdlsrc/commhdlQPSKTxRxLoopback/`) and, per variant, `modem/rtl_sim/s1_rtl_rxfix_<V>` / `s1_rtl_bs` / `s1_rtl_pad` by copying `s1_rtl` and running the injector on the copy with the manifest's order up to and including that variant (W1 for `rxfix_W1`; W1+R4B for `rxfix_R4B`; W1+R4D for `rxfix_R4D`; W1+R4D+R1 for `rxfix_R4DR1`; W1+R4B+BS for `bs` plus `bs_base`/`bs_gen` as `build_sro_bs.sh:8-27` expects; W1+R4B+BS+PAD for `pad`). `run_gates.sh --role A|B [--work DIR]` runs each script in `fixes.<V>.gates` for the role's variants plus `gates.common`, each under `systemd-run --user --collect --unit sp2-gate-<name>-<ts>` with `timeout 7200`, waits with a 30 s poll on unit state, writes `modem/rtl_sim/evidence/sp2/<role>/<gate>.log`, and prints `GATES_DONE role=<r> pass=<n> fail=<m>` (exit 1 on any fail).

- [ ] **Step 1: Read the gate scripts' tree contracts before writing anything**

```bash
grep -n "s1_rtl\|define+\|obj_\|wrap_\|sim_.*cpp" modem/rtl_sim/build_sro_w1.sh modem/rtl_sim/build_sro_rxfix4b.sh modem/rtl_sim/build_sro_rxfix4d.sh modem/rtl_sim/build_sro_rxfix4dr1.sh modem/rtl_sim/build_sro_bs.sh modem/rtl_sim/build_sro_pad.sh | head -60
grep -n "PASS\|FAIL\|exit 1" modem/rtl_sim/build_sro_pad.sh | head
```
Record per script: tree name(s) it reads, define, driver, and the string it prints on pass. `make_sro_trees.sh` must produce exactly those tree names; `run_gates.sh` greps exactly those pass strings.

- [ ] **Step 2: Write `make_sro_trees.sh`**

Skeleton (fill the variant table from Step 1):
```bash
#!/bin/bash
# make_sro_trees.sh -- regenerate the pristine and per-variant RTL trees the build_sro_*.sh
# gates read. Trees are gitignored; this script is how a fresh clone gets them.
# Usage: make_sro_trees.sh <base_tree_dir> [W1 R4B R4D R4DR1 BS PAD ...]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd); INJ="$ROOT/modem/fixes/rxfix_inject.py"
BASE=${1:?base tree}; shift
SRC="$BASE/hdl_prj_jupiter_composite/hdlsrc/commhdlQPSKTxRxLoopback"
[ -d "$SRC" ] || { echo "MAKE_SRO_NO_HDLSRC $SRC"; exit 1; }
rm -rf "$HERE/s1_rtl" && cp -r "$SRC" "$HERE/s1_rtl" && echo "s1_rtl <- $SRC"
mk() { local name=$1; shift; rm -rf "$HERE/$name"; cp -r "$HERE/s1_rtl" "$HERE/$name"; for v in "$@"; do python3 "$INJ" "$HERE/$name" "$v" --tree-only; done; echo "$name <- $*"; }
for want in "${@:-W1 R4B R4D R4DR1 BS PAD}"; do case $want in
  W1)    mk s1_rtl_rxfix_W1 W1 ;;
  R4B)   mk s1_rtl_rxfix_R4B W1 R4B ;;
  R4D)   mk s1_rtl_rxfix_R4D W1 R4D ;;
  R4DR1) mk s1_rtl_rxfix_R4DR1 W1 R4D R1 ;;
  BS)    mk s1_rtl_bs W1 R4B BS; mk s1_rtl_bs_gen; rm -rf "$HERE/s1_rtl_bs_base"; cp -r "$HERE/s1_rtl" "$HERE/s1_rtl_bs_base"; python3 "$ROOT/modem/fixes/pad_patch.py" --bs-base "$HERE/s1_rtl_bs_base" 2>/dev/null || true ;;
  PAD)   mk s1_rtl_pad W1 R4B BS PAD ;;
esac; done
```
`--tree-only` must exist on `rxfix_inject.py` (it patches a kit: hdlsrc + ipcore + zips). Read `rxfix_inject.py`'s argument handling; if it already accepts a bare hdlsrc dir (the sim-gate scripts historically injected into `s1_rtl_*` copies, check `docs/evidence/rxfix/RXFIX_R4B_SIM_GATE.md` for the exact command they used), use that form instead of adding a flag. Whatever `build_sro_bs.sh:8-27` says `s1_rtl_bs_base` is (drop-in FIFO, no define) is what Step 2 must reproduce; read it and adjust the `BS)` line.

- [ ] **Step 3: Generate the trees and run ONE cheap gate by hand**

```bash
B=/mnt/onetb/scratch/qpsk-build-trees
modem/rtl_sim/make_sro_trees.sh $B/base/jupiter_byte_ddrcap2_build W1 R4B R4D R4DR1 BS PAD 2>&1 | tail -8
ls -d modem/rtl_sim/s1_rtl*
git status --short | grep -c '^??'
systemd-run --user --collect --unit sp2-gate-w1-$(date +%s) --same-dir bash -c 'modem/rtl_sim/build_sro_w1.sh > modem/rtl_sim/evidence/sp2/manual_w1.log 2>&1'
```
Expected: nine tree dirs; `0` untracked (all ignored); the W1 gate unit starts. Wait with a background `until ! systemctl --user is-active --quiet <unit>; do sleep 30; done` and then `tail -5 modem/rtl_sim/evidence/sp2/manual_w1.log` shows the script's pass line (identity at 0 and −10 ppm).

- [ ] **Step 4: Write `run_gates.sh`**

```bash
#!/bin/bash
# run_gates.sh -- Stage 4: run every sim gate the manifest lists for a role, each as a
# transient user unit, and collect the logs under modem/rtl_sim/evidence/sp2/<role>/.
# Usage: run_gates.sh --role A|B [--only GATE] ; exit 1 if any gate fails.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd); MAN="$HERE/fixes.toml"
ROLE=""; ONLY=""
while [ $# -gt 0 ]; do case $1 in --role) ROLE=$2; shift 2;; --only) ONLY=$2; shift 2;; *) echo "bad arg $1"; exit 2;; esac; done
[ -n "$ROLE" ] || { echo "usage: --role A|B"; exit 2; }
GATES=$(python3 - "$MAN" "$ROLE" <<'EOF'
import sys, tomllib; m = tomllib.load(open(sys.argv[1], 'rb')); role = sys.argv[2]
seen = []
for v in m['roles'][role]['variants']:
    for g in m['fixes'][v].get('gates', []):
        if g not in seen: seen.append(g)
for g in m['gates']['common']:
    if g not in seen: seen.append(g)
print(' '.join(seen))
EOF
)
OUT="$ROOT/modem/rtl_sim/evidence/sp2/$ROLE"; mkdir -p "$OUT"; TS=$(date +%s); pass=0; fail=0
for g in $GATES; do
  [ -z "$ONLY" ] || [ "$g" = "$ONLY" ] || continue
  name=$(basename "$g" .sh); unit="sp2-gate-$name-$TS"; log="$OUT/$name.log"
  systemd-run --user --collect --unit "$unit" --same-dir --setenv=PATH="$PATH" bash -c "timeout 7200 $ROOT/modem/rtl_sim/$g > '$log' 2>&1"
  until ! systemctl --user is-active --quiet "$unit"; do sleep 30; done
  if grep -qE "$(python3 -c "import sys;print({'build_sro_w1.sh':'W1_GATE_PASS|identical','build_sro_rxfix4b.sh':'R4B_GATE_PASS|G17','build_sro_rxfix4d.sh':'R4D_GATE_PASS','build_sro_rxfix4dr1.sh':'S1_GATE_PASS|R4DR1_GATE_PASS','build_sro_bs.sh':'BS_GATE_PASS|identical','build_sro_pad.sh':'PAD_GATE_PASS|191','seqbist_unit/run_unit.sh':'PASS'}.get(sys.argv[1],'PASS'))" "$g")" "$log" && ! grep -qE "FAIL|Error|error:" "$log"; then
    echo "GATE_PASS $g"; pass=$((pass+1)); else echo "GATE_FAIL $g (see $log)"; fail=$((fail+1)); fi
done
echo "GATES_DONE role=$ROLE pass=$pass fail=$fail"; [ "$fail" = 0 ]
```
Replace the pass-string table with the exact strings recorded in Step 1; do not guess. Gates run sequentially (Verilator sims are multi-core; do not oversubscribe nemo).

- [ ] **Step 5: Run the full role-A and role-B gate sets, then delete the rejected-variant gate scripts**

```bash
systemd-run --user --collect --unit sp2-gates-A-$(date +%s) --same-dir bash -c 'modem/fixes/run_gates.sh --role A > modem/rtl_sim/evidence/sp2/gates_A.log 2>&1'
# wait (background poll), then:
tail -3 modem/rtl_sim/evidence/sp2/gates_A.log
systemd-run --user --collect --unit sp2-gates-B-$(date +%s) --same-dir bash -c 'modem/fixes/run_gates.sh --role B > modem/rtl_sim/evidence/sp2/gates_B.log 2>&1'
tail -3 modem/rtl_sim/evidence/sp2/gates_B.log
git rm -q modem/rtl_sim/build_sro_rxfix.sh modem/rtl_sim/build_sro_rxfix2.sh modem/rtl_sim/build_sro_rxfix3.sh modem/rtl_sim/build_sro_rxfix3s.sh modem/rtl_sim/build_sro_rxfix4.sh modem/rtl_sim/build_sro_rxfix4e.sh
```
Expected: `GATES_DONE role=A pass=5 fail=0` (W1, R4B, BS, PAD, seqbist) and `GATES_DONE role=B pass=4 fail=0` (W1, R4D, R4DR1, seqbist). Record wall-clock per gate. A failing gate on unchanged injector code is BLOCKED: report the log tail and stop; do not edit the gate.

- [ ] **Step 6: Commit (evidence logs are tracked under `modem/rtl_sim/evidence/`)**

```bash
git add modem/rtl_sim/make_sro_trees.sh modem/fixes/run_gates.sh modem/rtl_sim/evidence/sp2 .gitignore; git add -u
git commit -s -m "Stage 4: make_sro_trees.sh regenerates the gate trees from the base tree; run_gates.sh runs the manifest's gates per role; rejected-variant gate scripts retired

Role A: W1 R4B BS PAD + seqbist_unit all pass; role B: W1 R4D R4DR1 + seqbist_unit all pass (logs in modem/rtl_sim/evidence/sp2/)."
git push origin per-under-1pct-2026-07
```

---

### Task 6: `modem_wns.py`, the authoritative timing gate

**Files:**
- Create: `modem/fixes/modem_wns.py`, `modem/fixes/tests/test_modem_wns.py`, `modem/fixes/tests/data/timing_summary_excerpt.rpt`

**Interfaces:**
- Produces: `modem_wns.py <timing_summary.rpt> [--clock axi_adrv9001_adc_1_clk] [--min 0.0]` prints `MODEM_CLK_WNS clock=<c> wns=<f> tns=<f> failing=<n> total=<n>` and exits 0 when `wns >= --min`, 1 otherwise, 2 if the clock row is absent. Also `parse_intra_clock(text) -> dict[clock, (wns, tns, failing, total)]`.

- [ ] **Step 1: Get a real report and cut the excerpt**

```bash
R=/mnt/onetb/scratch/qpsk-build-trees/ref/rxfixpad_impl1_reports
ls $R
F=$(ls $R/*timing_summary_routed.rpt $R/*postroute_physopted.rpt 2>/dev/null | head -1); echo "$F"
grep -n "Intra Clock Table" "$F" | head -2
awk '/Intra Clock Table/{f=1} f{print} /Inter Clock Table/{exit}' "$F" > modem/fixes/tests/data/timing_summary_excerpt.rpt
grep -n "axi_adrv9001_adc_1_clk" modem/fixes/tests/data/timing_summary_excerpt.rpt | head -3
```
Expected: the excerpt holds the Intra Clock Table with a row for `axi_adrv9001_adc_1_clk` whose WNS is `0.105` (the reference 148 value). If no report was banked in Task 1, fetch one now: `rsync hdl-dev-2:qpsk-builds/jupiter_byte_rxfixpad_build/hdl_prj_jupiter_composite/vivado_ip_prj/vivado_prj.runs/impl_1/system_top_timing_summary_routed.rpt $R/`. Keep the excerpt under 200 lines (it is committed as test data).

- [ ] **Step 2: Write the failing test**

```python
import pathlib, subprocess, sys
HERE = pathlib.Path(__file__).resolve().parent; FIXES = HERE.parent
sys.path.insert(0, str(FIXES))
import modem_wns

def test_parse_finds_modem_clock_row():
    text = (HERE / "data/timing_summary_excerpt.rpt").read_text()
    rows = modem_wns.parse_intra_clock(text)
    assert "axi_adrv9001_adc_1_clk" in rows
    wns, tns, failing, total = rows["axi_adrv9001_adc_1_clk"]
    assert abs(wns - 0.105) < 0.001 and tns == 0.0 and failing == 0 and total > 100000

def test_cli_exit_codes(tmp_path):
    rpt = HERE / "data/timing_summary_excerpt.rpt"
    ok = subprocess.run([sys.executable, str(FIXES / "modem_wns.py"), str(rpt)], capture_output=True, text=True)
    assert ok.returncode == 0 and ok.stdout.startswith("MODEM_CLK_WNS clock=axi_adrv9001_adc_1_clk wns=0.105")
    strict = subprocess.run([sys.executable, str(FIXES / "modem_wns.py"), str(rpt), "--min", "0.2"], capture_output=True, text=True)
    assert strict.returncode == 1
    missing = subprocess.run([sys.executable, str(FIXES / "modem_wns.py"), str(rpt), "--clock", "no_such_clk"], capture_output=True, text=True)
    assert missing.returncode == 2
```

- [ ] **Step 3: Run to see it fail, then implement**

`parse_intra_clock`: find the line containing `Intra Clock Table`, skip to the header row (`Clock  WNS(ns)  TNS(ns)  TNS Failing Endpoints  TNS Total Endpoints  WHS(ns) ...`), then for each following non-blank, non-dashed line split on whitespace: `clock = parts[0]`, `wns = float(parts[1])`, `tns = float(parts[2])`, `failing = int(parts[3])`, `total = int(parts[4])`; stop at the first blank line after data. Vivado writes `NA` for clocks with no paths; skip those rows. CLI as specified.

```bash
python3 -m pytest modem/fixes/tests/test_modem_wns.py -q 2>&1 | tail -2
```
Expected: 2 passed.

- [ ] **Step 4: Commit**

```bash
git add modem/fixes/modem_wns.py modem/fixes/tests/test_modem_wns.py modem/fixes/tests/data/timing_summary_excerpt.rpt
git commit -s -m "modem/fixes: modem_wns.py, the post-route intra-clock WNS gate on axi_adrv9001_adc_1_clk (re-authored; the original was never tracked), with a test on the reference 148 report"
git push origin per-under-1pct-2026-07
```

---

### Task 7: Generated register map for both host consumers

**Files:**
- Create: `modem/fixes/gen_regmap.py`, `modem/fixes/tests/test_gen_regmap.py`, `host/qpsk_fixregs.h` (generated), `host/modem_status/ms_regmap_fixes.inc` (generated)
- Modify: `host/qpsk_hw.h` (add `#include "qpsk_fixregs.h"` after its last register define), `host/modem_status/ms_regmap.c` (replace the hand-written rows for 0x208 and 0x214–0x258 with `#include "ms_regmap_fixes.inc"` and read `MS_R4D_SWAPPED_MD5` from the generated header), `host/Makefile` (`regmap-check` target), `.github/workflows/docs.yml` (job `regmap` runs `python3 modem/fixes/gen_regmap.py --check`)
- Test: `make -C host clean all test` (228 checks unchanged), `python3 -m pytest modem/fixes/tests -q`

**Interfaces:**
- Consumes: `apply_fixes.load_manifest`, `role_variants`.
- Produces: `gen_regmap.py [--check]` writes the two files (or, with `--check`, regenerates to a temp dir and exits 1 with a unified diff if they differ). Header content: `#define QPSK_REG_FIXCTL 0x208`, one `#define QPSK_FIXCTL_<NAME>_BIT n` per control bit, one `#define QPSK_REG_<NAME> 0xADDR` per witness word (names upper-cased, unique across all fixes), `#define QPSK_R4D_SWAPPED_MD5 "9acbe2ebe1dbf280e030952fc4fc23d8"` from `witness_swapped_in_images`, and a `/* generated from modem/fixes/fixes.toml sha <16hex>; do not edit */` banner. The `.inc` holds `{ 0xADDR, "name", W, <flags>, "<fields or fix name>" },` rows in address order matching the existing `ms_regmap.c` row format exactly (read the existing rows 64–84 first and reproduce their macros `M`, `W`, `MS_F_WO`, `MS_F_PACKED`, `MS_F_IMGKEY`; the two R4 words get `MS_F_PACKED|MS_F_IMGKEY`, 0x208 gets `M, MS_F_WO`).

- [ ] **Step 1: Write the failing tests**

```python
import pathlib, subprocess, sys, re
HERE = pathlib.Path(__file__).resolve().parent; FIXES = HERE.parent; ROOT = FIXES.parent.parent
sys.path.insert(0, str(FIXES))
import gen_regmap

def test_header_has_every_witness_and_control():
    h = gen_regmap.render_header(gen_regmap.load(FIXES / "fixes.toml"))
    for name, addr in [("W1_WITA", 0x214), ("W1_WITB", 0x218), ("R4_WIT", 0x234), ("R4_EXTRAS", 0x238), ("BS_WORDS", 0x23C), ("BS_CNT", 0x258)]:
        assert re.search(rf"#define QPSK_REG_{name}\s+0x{addr:03X}", h), name
    assert "#define QPSK_FIXCTL_W1_FREEZE_BIT 4" in h
    assert '#define QPSK_R4D_SWAPPED_MD5 "9acbe2ebe1dbf280e030952fc4fc23d8"' in h

def test_inc_rows_are_address_sorted_and_unique():
    inc = gen_regmap.render_inc(gen_regmap.load(FIXES / "fixes.toml"))
    addrs = [int(m, 16) for m in re.findall(r"\{\s*0x([0-9A-Fa-f]+),", inc)]
    assert addrs == sorted(addrs) and len(addrs) == len(set(addrs))
    assert '{ 0x234, "r4_wit"' in inc and "MS_F_IMGKEY" in inc

def test_check_mode_is_clean_after_generate(tmp_path):
    subprocess.run([sys.executable, str(FIXES / "gen_regmap.py")], check=True)
    r = subprocess.run([sys.executable, str(FIXES / "gen_regmap.py"), "--check"], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
```

- [ ] **Step 2: Implement `gen_regmap.py`, wire the includes, regenerate**

Witness names in the manifest are the `ms_regmap.c` names (`r4_wit`, `bs_words`, ...); the header upper-cases them. Where two fixes declare the same witness address (R4B and R4D both declare 0x234 `r4_wit`), the generator emits it once and records both fix names in the row comment; a same-address declaration with a different name is an error.

In `ms_regmap.c`: delete rows 64 and 67–84 (keep 65–66, the DBGCAP-owned 0x20C/0x210) and insert `#include "ms_regmap_fixes.inc"` at that point; change `MS_R4D_SWAPPED_MD5` to be defined from `QPSK_R4D_SWAPPED_MD5` (`#include "../qpsk_fixregs.h"`).

```bash
python3 modem/fixes/gen_regmap.py && git diff --stat
make -C host clean all test 2>&1 | tail -3
python3 -m pytest modem/fixes/tests -q 2>&1 | tail -2
```
Expected: `test_modem_status: 228 checks, 0 failures` (the table content is unchanged, only its source moved); all pytest pass.

- [ ] **Step 3: Makefile target and CI job**

`host/Makefile`: add
```make
regmap-check:
	python3 ../modem/fixes/gen_regmap.py --check
```
and make `test` depend on it. `.github/workflows/docs.yml`: add a job `regmap` (ubuntu, python 3.12, `python3 modem/fixes/gen_regmap.py --check`) and make `build` `needs: [paths, regmap]`.

- [ ] **Step 4: Commit and watch CI**

```bash
git add modem/fixes/gen_regmap.py modem/fixes/tests/test_gen_regmap.py host/qpsk_fixregs.h host/modem_status/ms_regmap_fixes.inc host/qpsk_hw.h host/modem_status/ms_regmap.c host/Makefile .github/workflows/docs.yml
git commit -s -m "regmap: fixes.toml generates host/qpsk_fixregs.h and ms_regmap_fixes.inc; CI --check keeps them in sync (the R4D word-swap md5 now has one source)"
git push origin per-under-1pct-2026-07
gh run list --repo tfcollins/qpsk-jupiter-modem --branch per-under-1pct-2026-07 --limit 1 --json databaseId,status
```
Watch the run in the background; expected `paths`, `regmap`, `build`, `deploy` all success.

---

### Task 8: Instruments under `modem/instruments/`

**Files:**
- Move: `ops/skidfix/{ddrcap_inject.py,ddrcap2_inject.py,test_ddrcap_inject.py,dbgcap_inject.py,demodcap_inject.py,rxfe_inject.py,stagesig_inject.py,stagesig3_inject.py,txcap_inject.py,txint_inject.py,ddrcap_bd.tcl,beatila3_*.tcl,gen_beatila3_xdc.py,patch_beatila3_tcl.py,patch_beatila_tcl.py,dcp_*.tcl,beatfix_overlay.m,beatobs_overlay.m,ddrcap2_witness_*.bin (untracked, leave)}` → `modem/instruments/<name>/`
- Create: `modem/instruments/README.md` and one `README.md` per instrument dir
- Modify: `modem/fixes/apply_fixes.py` (`--instrument NAME` runs `modem/instruments/NAME/NAME_inject.py <kit>`), `modem/rtl_sim/build_beat_sim.sh`, `build_ddrcap2_sim.sh` paths

**Interfaces:**
- Produces: directory names `ddrcap`, `ddrcap2`, `dbgcap`, `demodcap`, `rxfe`, `stagesig`, `stagesig3`, `txcap`, `txint`, `beatila` (the beatila3/beatfix/beatobs tcl/xdc/overlay set), `dcp` (the two dcp probe tcls). Each README states in one paragraph: what it captures, its register window / fixctl bits, the image it last went into (md5 from `docs/evidence/`), its injection prerequisites (e.g. `demodcap` after `dbgcap`), and whether it is on the fix chain's critical path (only `ddrcap2`, as the base tree's ancestor).

- [ ] **Step 1: Move and write READMEs**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem; mkdir -p modem/instruments
for n in ddrcap ddrcap2 dbgcap demodcap rxfe stagesig stagesig3 txcap txint; do mkdir -p modem/instruments/$n; git mv ops/skidfix/${n}_inject.py modem/instruments/$n/; done
git mv ops/skidfix/test_ddrcap_inject.py modem/instruments/ddrcap/; git mv ops/skidfix/ddrcap_bd.tcl modem/instruments/ddrcap/
mkdir -p modem/instruments/beatila modem/instruments/dcp
git mv ops/skidfix/beatila3_insert_impl.tcl ops/skidfix/beatila3_preflight.tcl ops/skidfix/beatila3_preflight_dataout.tcl ops/skidfix/beatila3_debug.xdc ops/skidfix/gen_beatila3_xdc.py ops/skidfix/patch_beatila3_tcl.py ops/skidfix/patch_beatila_tcl.py ops/skidfix/beatfix_overlay.m ops/skidfix/beatobs_overlay.m modem/instruments/beatila/ 2>&1 | grep -v "^$"
git mv ops/skidfix/dcp_glitch_probe.tcl ops/skidfix/dcp_loadpins.tcl modem/instruments/dcp/
git ls-files ops/skidfix
```
Expected: what remains in `ops/skidfix` is only flash rails, `patch_complete_tcl.py`, `jupiter_byte_*_kit` leftovers (none), `*_flash_*.log`, `ddrcap2_flash_*.log`, `SKID_BUILD.md`-class notes (already in evidence), `cal_snapshot_1959.txt`, `loadpins_*.txt`, `glitch_probe_skid3.txt`, `dipab*`. Decide each: flash rails → Task 9; recorded logs/txt → `docs/evidence/skidfix/` (verbatim, provenance line); `dipab*` → tag (delete). List every decision in the report.

Write each README from the one-line table in `docs/superpowers/plans/2026-09-10-fix-layer-promotion-chain-trace.md` §6, expanded with the injector's own header comment (lines 1–15 of each file).

- [ ] **Step 2: Wire `--instrument` and the sim scripts; run the ddrcap test**

```bash
sed -i 's#modem/fixes/ddrcap2_inject.py#modem/instruments/ddrcap2/ddrcap2_inject.py#g; s#modem/fixes/ddrcap_inject.py#modem/instruments/ddrcap/ddrcap_inject.py#g' modem/rtl_sim/build_beat_sim.sh modem/rtl_sim/build_ddrcap2_sim.sh
grep -rn "skidfix" modem/ ops/README.md | grep -v "docs/evidence" ; echo "hits=$?"
cd modem/instruments/ddrcap && python3 -m pytest test_ddrcap_inject.py -q 2>&1 | tail -2; cd ../../..
python3 modem/fixes/apply_fixes.py --manifest modem/fixes/fixes.toml --role A --base /x --work /y --plan --instrument txcap | tail -2
```
Expected: `hits=1`; ddrcap tests pass; the plan's last line is the `txcap_inject.py` step.

- [ ] **Step 3: Commit**

```bash
git add -u; git add modem/instruments docs/evidence
git commit -s -m "modem/instruments: capture/probe injectors move out of the fix kit, one README each; apply_fixes --instrument adds one to a kit"
git push origin per-under-1pct-2026-07
```

---

### Task 9: `build_image.sh`, the stage runner, and the Vivado stage

**Files:**
- Create: `modem/build_image.sh`
- Move: `ops/skidfix/{flash_148_txfix.sh,flash_146_txfix.sh,txfix_flash_go.sh,txfix_flash146_go.sh,arm148_mode1.sh}` → `ops/flash/`; remaining `ops/skidfix/*` per Task 8's decisions; then `git rm -r ops/skidfix`
- Modify: `tools/check_paths.sh` (remove the `ops/skidfix/` waiver and the `qpsk_variants` filter's note if it referenced skidfix), `.gitignore` (`ops/skidfix` rules → none; build dirs under `/mnt/onetb/scratch/qpsk-build-trees/work` are off-repo), `ops/README.md` (flash rows point at `ops/flash/`)

**Interfaces:**
- Produces: `modem/build_image.sh --role A|B [--work DIR] [--from STAGE] [--stop-after STAGE] [--instrument NAME]... [--dry]` with stages `base fixes gates vivado` (Task 12 adds `hdl` in front). Each stage writes `<work>/STAMP.<stage>` containing `stage=<s> role=<r> manifest_sha=<16hex> git=<sha> when=<iso> result=<line>`; `--from` requires the previous stage's stamp to exist with the same `manifest_sha`. The `vivado` stage: (1) instantiates `build_txfix.sh`/`.tcl` into the kit exactly as `txfix_kit.sh` does (they are already there from the fixes stage), (2) runs `build_txfix.sh` (positional `--dry` when `--dry`), which rsyncs and launches the remote unit, (3) waits with `ssh hdl-dev-2 systemctl --user is-active <unit>` every 60 s up to 4 h, (4) fetches `build_txfix_vivado.log`, `BOOT.BIN`, and `impl_1/system_top_timing_summary_routed.rpt` (or `_postroute_physopted.rpt`), (5) runs `modem_wns.py <rpt> --min 0.0`, checks `|wns - roles.<R>.reference_modem_wns_ns| <= 0.1`, greps `TXFIX_BUILD_DONE ... md5=`, (6) copies `BOOT.BIN` to `<work>/BOOT.BIN.<board>.sp2<role>.<md5-12>` and prints `BUILD_IMAGE_DONE role=<r> image=<path> md5=<32> modem_wns=<f>`.

- [ ] **Step 1: Write `build_image.sh`**

```bash
#!/bin/bash
# build_image.sh -- build a deployable BOOT.BIN for role A (148 lineage, W1 R4B BS PAD) or
# role B (148 lineage, W1 R4D R1) from the banked base tree, the manifest-driven fix
# chain, the sim gates, and a Vivado run on hdl-dev-2. Stages: base fixes gates vivado.
# Usage: build_image.sh --role A|B [--work DIR] [--from S] [--stop-after S] [--instrument N]... [--dry]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/.." && pwd); FX="$HERE/fixes"; MAN="$FX/fixes.toml"
ROLE=""; WORK=/mnt/onetb/scratch/qpsk-build-trees/work; FROM=base; STOP=vivado; DRY=""; INST=()
while [ $# -gt 0 ]; do case $1 in
  --role) ROLE=$2; shift 2;; --work) WORK=$2; shift 2;; --from) FROM=$2; shift 2;; --stop-after) STOP=$2; shift 2;;
  --instrument) INST+=(--instrument "$2"); shift 2;; --dry) DRY=--dry; shift;; *) echo "bad arg $1"; exit 2;; esac; done
[ "$ROLE" = A ] || [ "$ROLE" = B ] || { echo "usage: --role A|B"; exit 2; }
MSHA=$(python3 -c "import sys;sys.path.insert(0,'$FX');import apply_fixes as a;print(a.manifest_sha('$MAN'))")
GIT=$(git -C "$ROOT" rev-parse --short HEAD)
q() { python3 -c "import tomllib,sys;m=tomllib.load(open('$MAN','rb'));print(eval('m'+sys.argv[1]))" "$1"; }
BOARD=$(q "['roles']['$ROLE']['board']"); SUFFIX=$(q "['roles']['$ROLE']['kit_suffix']"); REFWNS=$(q "['roles']['$ROLE']['reference_modem_wns_ns']")
HOST=$(q "['meta']['vivado_host']"); CLK=$(q "['meta']['timing_clock']"); BASE_NAME=$(q "['meta']['base_tree']")
KIT="$WORK/jupiter_byte_rxfix${SUFFIX}_build"
STAGES=(base fixes gates vivado); mkdir -p "$WORK"
stamp() { printf 'stage=%s role=%s manifest_sha=%s git=%s when=%s result=%s\n' "$1" "$ROLE" "$MSHA" "$GIT" "$(date -Is)" "$2" > "$WORK/STAMP.$1"; }
need() { [ -f "$WORK/STAMP.$1" ] && grep -q "manifest_sha=$MSHA" "$WORK/STAMP.$1" || { echo "BUILD_IMAGE_NEED_STAGE $1 (run --from $1 or earlier)"; exit 1; }; }
run=0
for s in "${STAGES[@]}"; do
  [ "$s" = "$FROM" ] && run=1; [ $run = 1 ] || continue
  echo "== stage $s (role $ROLE, manifest $MSHA, git $GIT)"
  case $s in
    base)   "$FX/base_tree.sh" fetch "$WORK" | tee "$WORK/base.log"; stamp base "$(tail -1 "$WORK/base.log")" ;;
    fixes)  need base; rm -rf "$KIT" "$WORK/jupiter_byte_txfixF3_build" "$WORK/jupiter_byte_seqbist_build"
            python3 "$FX/apply_fixes.py" --manifest "$MAN" --role "$ROLE" --base "$WORK/$BASE_NAME" --work "$WORK" "${INST[@]}" | tee "$WORK/fixes.log"
            stamp fixes "$(grep APPLY_FIXES_DONE "$WORK/fixes.log")" ;;
    gates)  need fixes; "$ROOT/modem/rtl_sim/make_sro_trees.sh" "$WORK/$BASE_NAME" | tee "$WORK/gates_trees.log"
            "$FX/run_gates.sh" --role "$ROLE" | tee "$WORK/gates.log"; stamp gates "$(grep GATES_DONE "$WORK/gates.log")" ;;
    vivado) need fixes; [ -f "$WORK/STAMP.gates" ] || echo "WARNING: gates stage not stamped for this manifest; continuing because --from vivado was requested"
            ( cd "$KIT" && IMPL_STRATEGY=explore bash ./build_txfix.sh $DRY ) | tee "$WORK/vivado_launch.log"
            [ -n "$DRY" ] && { stamp vivado "dry"; echo "BUILD_IMAGE_DRY role=$ROLE"; exit 0; }
            UNIT=$(grep -oE 'txfix-build-[A-Za-z0-9_-]+' "$WORK/vivado_launch.log" | head -1); REMOTE="qpsk-builds/$(basename "$KIT")"
            for i in $(seq 1 240); do ssh "$HOST" systemctl --user is-active --quiet "$UNIT" || break; sleep 60; done
            rsync -a "$HOST:$REMOTE/build_txfix_vivado.log" "$WORK/"; rsync -a "$HOST:$REMOTE/hdl_prj_jupiter_composite/vivado_ip_prj/BOOT.BIN" "$WORK/BOOT.BIN.$ROLE" 2>/dev/null || rsync -a "$HOST:$REMOTE/BOOT.BIN" "$WORK/BOOT.BIN.$ROLE"
            rsync -a --include '*timing_summary*.rpt' --include '*/' --exclude '*' "$HOST:$REMOTE/hdl_prj_jupiter_composite/vivado_ip_prj/vivado_prj.runs/impl_1/" "$WORK/impl1_reports_$ROLE/"
            RPT=$(ls "$WORK/impl1_reports_$ROLE/"*routed.rpt "$WORK/impl1_reports_$ROLE/"*postroute_physopted.rpt 2>/dev/null | head -1)
            WNSLINE=$(python3 "$FX/modem_wns.py" "$RPT" --clock "$CLK" --min 0.0); echo "$WNSLINE"
            WNS=$(echo "$WNSLINE" | sed -n 's/.*wns=\([-0-9.]*\).*/\1/p')
            python3 -c "import sys; w=float('$WNS'); r=float('$REFWNS'); sys.exit(0 if abs(w-r)<=0.1 else 1)" || { echo "BUILD_IMAGE_WNS_DRIFT wns=$WNS ref=$REFWNS"; exit 1; }
            grep -q "TXFIX_BUILD_DONE" "$WORK/build_txfix_vivado.log" || { echo "BUILD_IMAGE_VIVADO_FAIL"; tail -20 "$WORK/build_txfix_vivado.log"; exit 1; }
            MD5=$(md5sum "$WORK/BOOT.BIN.$ROLE" | cut -d' ' -f1); OUT="$WORK/BOOT.BIN.$BOARD.sp2$ROLE.${MD5:0:12}"; cp "$WORK/BOOT.BIN.$ROLE" "$OUT"
            stamp vivado "md5=$MD5 modem_wns=$WNS"; echo "BUILD_IMAGE_DONE role=$ROLE image=$OUT md5=$MD5 modem_wns=$WNS" ;;
  esac
  [ "$s" = "$STOP" ] && break
done
```
Read `build_txfix.sh.tmpl` for the exact unit-name pattern and where `BOOT.BIN` lands (`build_txfix.tcl:281` writes it in the tcl's cwd, which is the kit's `vivado_ip_prj`); fix the two rsync paths to match. The remote kit dir is derived from the kit basename by the template (`REMOTE_DIR="~/qpsk-builds/$KIT"`), which is why `KIT` must keep the `jupiter_byte_rxfix<suffix>_build` name.

- [ ] **Step 2: Move the flash rails, retire `ops/skidfix`, fix the gate waiver**

```bash
mkdir -p ops/flash
for f in flash_148_txfix.sh flash_146_txfix.sh txfix_flash_go.sh txfix_flash146_go.sh arm148_mode1.sh; do git mv ops/skidfix/$f ops/flash/$f; done
sed -i 's#ops/skidfix/#ops/flash/#g; s#\$(dirname "\$0")/flash_#$(dirname "$0")/flash_#' ops/flash/*.sh; bash -n ops/flash/*.sh && echo OK
git ls-files ops/skidfix
```
For every remaining file: evidence → `git mv` to `docs/evidence/skidfix/` with the provenance line; else `git rm`. Then `git rm -r ops/skidfix` must leave nothing. Remove the `^ops/skidfix/` entries from `tools/check_paths.sh` (both the exclusion and any waiver list), and the `ops/skidfix` lines from `.gitignore`. Update `ops/README.md` (flash rows → `ops/flash/`, the `skidfix/` intro sentence gone) and `docs/setup-prebuilt.rst` / `docs/bringup.rst` where they name `ops/skidfix/flash_*`.

```bash
tools/check_paths.sh | tail -1; git grep -n "ops/skidfix" -- ':!docs/evidence' ':!docs/superpowers' | wc -l
```
Expected: `CHECK_PATHS_OK`; `0`.

- [ ] **Step 3: Dry run both roles end to end (no Vivado)**

```bash
modem/build_image.sh --role A --dry 2>&1 | tail -6
modem/build_image.sh --role B --dry --from fixes 2>&1 | tail -6
cat /mnt/onetb/scratch/qpsk-build-trees/work/STAMP.*
```
Expected: for A: `BASE_TREE_OK`, `APPLY_FIXES_DONE`, `GATES_DONE role=A pass=5 fail=0` (this re-runs the sim gates; several hours; run the whole command under `systemd-run --user` and wait in the background), then `TXFIX_BUILD_DRY would run: ssh hdl-dev-2 ...` and `BUILD_IMAGE_DRY role=A`. For B the same from `fixes`. Stamps show matching `manifest_sha`.

- [ ] **Step 4: Commit**

```bash
git add modem/build_image.sh ops/flash tools/check_paths.sh .gitignore ops/README.md docs; git add -u
git commit -s -m "modem/build_image.sh: stage runner base->fixes->gates->vivado with stamps, --from/--stop-after/--dry; flash rails to ops/flash; ops/skidfix retired

Recoverable from tag archive/pre-cleanup-2026-09-09."
git push origin per-under-1pct-2026-07
```

---

### Task 10: Build both roles on hdl-dev-2 and bank the images

**Files:**
- Create: `images/BOOT.BIN.148.sp2A.<md5-12>`, `images/BOOT.BIN.146.sp2B.<md5-12>` (git add -f), rows in `images/README.md`, entries in `images/MD5SUMS`
- Create: `modem/rtl_sim/evidence/sp2/build_A.log`, `build_B.log` (the fetched `build_txfix_vivado.log` tails, ≤ 200 lines each), `modem/rtl_sim/evidence/sp2/modem_wns_A.txt`, `modem_wns_B.txt`

**Interfaces:**
- Consumes: `build_image.sh` from Task 9. Produces: two candidate images and their WNS evidence; `images/CURRENT.txt` is NOT changed until Task 11's silicon gate passes.

- [ ] **Step 1: Preflight the remote host**

```bash
ssh hdl-dev-2 'df -Ph $HOME | tail -1; systemctl --user list-units --state=running "txfix-build-*" --no-legend; nproc'
```
Expected: ≥ 50 GB free (two kits at 25 GB each; if under, delete the oldest `~/qpsk-builds/jupiter_byte_{txfixF2,stagesig3,txint,txmark}_build` after confirming they are not the deployed kits, and say which), no running build units.

- [ ] **Step 2: Launch role A, then role B (≤ 2 concurrent), under local user units**

```bash
systemd-run --user --collect --unit sp2-build-A-$(date +%s) --same-dir bash -c 'modem/build_image.sh --role A --from vivado > /mnt/onetb/scratch/qpsk-build-trees/work/build_A.out 2>&1'
systemd-run --user --collect --unit sp2-build-B-$(date +%s) --same-dir bash -c 'modem/build_image.sh --role B --work /mnt/onetb/scratch/qpsk-build-trees/workB --from base --stop-after fixes > /mnt/onetb/scratch/qpsk-build-trees/workB/prep_B.out 2>&1 && modem/build_image.sh --role B --work /mnt/onetb/scratch/qpsk-build-trees/workB --from vivado > /mnt/onetb/scratch/qpsk-build-trees/workB/build_B.out 2>&1'
```
(Role B needs its own work dir because the kit names differ but the txfix/seqbist intermediates collide; `--from vivado` for A is valid because Task 9 Step 3 stamped `fixes` and `gates` for A with this manifest. For B, run `gates` too if Task 9's dry run stopped before it: `--from gates`.) Wait with a background `until` loop on both unit states (up to 3 h each); do not sleep in the foreground.

- [ ] **Step 3: Read the results**

```bash
tail -3 /mnt/onetb/scratch/qpsk-build-trees/work/build_A.out /mnt/onetb/scratch/qpsk-build-trees/workB/build_B.out
grep -E "MODEM_CLK_WNS|TXFIX_ROUTED_WNS|TXFIX_BUILD_DONE|BUILD_IMAGE_DONE" /mnt/onetb/scratch/qpsk-build-trees/work/build_A.out /mnt/onetb/scratch/qpsk-build-trees/workB/build_B.out
```
Expected: two `BUILD_IMAGE_DONE` lines; `MODEM_CLK_WNS` ≥ 0 and within 0.1 ns of 0.105 (A) and 0.620 (B). md5s will differ from the reference images (Vivado is not bit-reproducible; `docs/provenance.rst` says so). If `BUILD_IMAGE_WNS_DRIFT` fires: rerun that role once with the same settings (place/route noise); if it fires twice, BLOCKED with both WNS values.

- [ ] **Step 4: Bank the images and the evidence**

```bash
W=/mnt/onetb/scratch/qpsk-build-trees
A=$(ls $W/work/BOOT.BIN.148.sp2A.*); B=$(ls $W/workB/BOOT.BIN.146.sp2B.*)
cp "$A" "$B" images/; git add -f images/$(basename "$A") images/$(basename "$B")
( cd images && md5sum BOOT.BIN.* Image.*.gz system*.dtb* daemon/* > MD5SUMS && md5sum -c MD5SUMS | grep -c OK )
mkdir -p modem/rtl_sim/evidence/sp2; tail -200 $W/work/build_txfix_vivado.log > modem/rtl_sim/evidence/sp2/build_A.log; tail -200 $W/workB/build_txfix_vivado.log > modem/rtl_sim/evidence/sp2/build_B.log
grep MODEM_CLK_WNS $W/work/build_A.out > modem/rtl_sim/evidence/sp2/modem_wns_A.txt; grep MODEM_CLK_WNS $W/workB/build_B.out > modem/rtl_sim/evidence/sp2/modem_wns_B.txt
cat $W/work/STAMP.vivado $W/workB/STAMP.vivado
```
Add two rows to `images/README.md` (candidate, NOT deployed, manifest sha, git sha, WNS, built date). Do not touch `CURRENT.txt`.

- [ ] **Step 5: Commit**

```bash
git add images/MD5SUMS images/README.md modem/rtl_sim/evidence/sp2
git commit -s -m "images: sp2 candidate images for roles A and B built by modem/build_image.sh (manifest <sha>, git <sha>); modem WNS A=<f> B=<f>; not deployed"
git push origin per-under-1pct-2026-07
```

---

### Task 11: Silicon gate, one board at a time, and cut-over

**Files:**
- Modify: `images/CURRENT.txt` (roles A/B → the sp2 images; rollback lines → the previous images), `images/README.md` (deployed flags), `docs/provenance.rst` (current rows name the manifest sha + commit), `ops/flash/flash_148_txfix.sh` / `flash_146_txfix.sh` only if a path assumption breaks
- Create: `docs/evidence/sp2/SP2_SILICON.md` (the credited windows: commands, counts, verdicts)

**Interfaces:**
- Consumes: the two banked candidates. Rails: `ops/flash/txfix_flash_go.sh` (148) and `ops/flash/txfix_flash146_go.sh` (146) with `FLASH_MD5=<12>`, `FLASH_TAG=sp2A|sp2B`, `FLASH_BAK=bf2a7305bbe0` (148) / `9acbe2ebe1db` (146). Health gate `ops/health_probe_reset_aware.sh <ip> 12`. Credited window: `ops/capture_r3.sh` per leg (read its header for the leg/duration arguments; DUR=600) scored by `ops/accept_analyze.py` (lost frames in the denominator).

Rig rules from Global Constraints apply verbatim. The sentinel keeper will see contamination during flashes; say so in the evidence file.

- [ ] **Step 1: Baseline windows on the CURRENT images (same day, same rig)**

```bash
ops/launch_rig_unit.sh sp2-base-fwd-$(date +%H%M%S) ops/capture_r3.sh LEG=fwd DUR=600   # read capture_r3.sh's header for its real argument names
# wait (background), then score:
python3 ops/accept_analyze.py <run_dir> | tail -5
# repeat for LEG=rev
```
Record forward and reverse PER with frame counts. These are today's reference points (expected near 0.07–0.08 % and ~0.19 %); if either is more than 2× off its documented value, stop and report before flashing (the rig itself has moved).

- [ ] **Step 2: Flash 148 with sp2A under the rail, gate, window**

```bash
A=$(ls images/BOOT.BIN.148.sp2A.* | head -1); M=$(echo $A | sed 's/.*\.//')
FLASH_MD5=$M FLASH_TAG=sp2A FLASH_BAK=bf2a7305bbe0 ops/launch_rig_unit.sh sp2-flash148-$(date +%H%M%S) ops/flash/txfix_flash_go.sh
# wait for the unit; then read its journal: expect the five stages, readback md5 = $M, two-pass gate ARM_OK fps>=1120 capTAP golden
ops/health_probe_reset_aware.sh 10.0.0.148 12 | tail -2
ops/health_probe_reset_aware.sh 10.0.0.146 12 | tail -2
ops/test.sh bist 2>&1 | grep -E "cap_out|0x04922282"     # BIST golden cap_out = 0x04922282 on the flashed board (read test.sh for the per-board form)
# credited windows both legs (forward = 146 TX -> 148 RX, reverse = 148 TX -> 146 RX)
```
Acceptance: BIST golden `cap_out = 0x04922282`; forward and reverse PER each ≤ 2× the Step 1 baseline for that leg, lost frames counted, no new comb line in `accept_analyze.py`'s lag report. On failure: `ops/flash/flash_148_txfix.sh` rollback path with `FLASH_MD5=bf2a7305bbe0 FLASH_BAK=<sp2A md5>` (the rail's documented reverse), re-gate, and STOP with the numbers.

- [ ] **Step 3: Flash 146 with sp2B (the rail requires 148 live first), gate, window**

```bash
B=$(ls images/BOOT.BIN.146.sp2B.* | head -1); M=$(echo $B | sed 's/.*\.//')
FLASH_MD5=$M FLASH_TAG=sp2B FLASH_BAK=9acbe2ebe1db ROLLBACK_BANK=$PWD/images/BOOT.BIN.146.rxfixr4dr1.9acbe2ebe1db ops/launch_rig_unit.sh sp2-flash146-$(date +%H%M%S) ops/flash/txfix_flash146_go.sh
# wait; health gate both boards; credited windows both legs as in Step 2
```
Note for the reverse leg on the rebuilt 146 image: the R4D witness words are in CANONICAL order (the injector's Task-33 fix), so `modem_status` on 146 must decode them un-swapped; `ms_r4d_order()` returns canonical for any md5 not in `QPSK_R4D_SWAPPED_MD5`, which is the generated single source. Verify with `ssh root@10.0.0.146 /root/host_app_k5/modem_status --once | grep -E "r4_wit|r4_extras"`: `opens` should tick at the frame rate and `extras` should be a small count, not the reverse.

- [ ] **Step 4: Cut over the bank and provenance**

`images/CURRENT.txt`: role A → `BOOT.BIN.148.sp2A.<md5>`, role B → `BOOT.BIN.146.sp2B.<md5>`, notes carry the PER numbers with counts; rollback comment lines → the previous images (`bf2a7305bbe0`, `9acbe2ebe1db`), which stay banked. `images/README.md` rows flip to deployed. `docs/provenance.rst` "Current images": one row per role with image, md5, `modem/fixes/fixes.toml` sha, git commit, modem WNS, flash date, PER window (command + counts). Write `docs/evidence/sp2/SP2_SILICON.md` with every command and output from Steps 1–3.

```bash
/mnt/onetb/scratch/qpsk-build-trees/sphinx-venv/bin/sphinx-build -W -b html docs docs/_build/html 2>&1 | tail -1
git add images/CURRENT.txt images/README.md docs/provenance.rst docs/evidence/sp2
git commit -s -m "cut-over: roles A/B are the sp2 images built by modem/build_image.sh; previous images kept as rollbacks; silicon windows in docs/evidence/sp2/SP2_SILICON.md"
git push origin per-under-1pct-2026-07
```

- [ ] **Step 5: Memory**

Update `repo-layout-2026-09.md` (fix kit at `modem/fixes/`, rails at `ops/flash/`, `ops/skidfix` gone) and write `sp2-build-chain.md` (type project): how to rebuild (`modem/build_image.sh --role A`), where the base tree is banked and its sha, the WNS ladder, the R4D canonical-order note, hdl-dev-2 facts. Add both to `MEMORY.md`.

---

### Task 12: The `hdl` stage: regenerate the base tree from the Simulink model, gated by RTL equivalence

**Files:**
- Create: `modem/fixes/build_base_tree.sh`
- Modify: `modem/build_image.sh` (stage `hdl` before `base`; `--from hdl` regenerates instead of fetching; the `base` stage's `verify` then compares the regenerated tree's `hdlsrc` and `ipcore` RTL to the banked base tree), `docs/build-and-flash.rst` (Stage 1–2 text)

**Interfaces:**
- Produces: `build_base_tree.sh <dest_parent>`: runs the model→netlist step (`modem/build_byte_image.sh` lines 24–28 equivalent: MATLAB `build_variant_byte` under `QPSK_LEAN=1` with the overlay stack of `assemble_jupiter_240k5_byte.m`), then the Vivado project creation and the DDRCAP + DDRCAP-v2 instrument injections that the banked base tree carries (`modem/instruments/ddrcap/ddrcap_inject.py` with `TXMARK=1`, then `ddrcap2_inject.py`, and `ddrcap_bd.tcl` for the BD ports; read `docs/evidence/` DDRCAP ledgers and the instruments' READMEs for the exact order), writing `<dest_parent>/jupiter_byte_ddrcap2_build.regen`. Prints `BASE_REGEN_DONE` and then `BASE_RTL_EQUIV files=<n> diff=<m>` after diffing every `.v` under `hdlsrc/` and `ipcore/` against the banked base tree.

This is the riskiest task and the deliverable does not depend on it: the spec's "fresh clone builds" is met by the banked base tree. Rule at the start: if the regenerated RTL differs from the banked base tree in any way not explained by a header timestamp, the banked tree remains canonical, the diff is written to `docs/evidence/sp2/BASE_REGEN_DIVERGENCE.md`, and `build_image.sh --from hdl` is documented as "reproduces the design, not the bit-identical base tree". Do not iterate on the model to chase equivalence in this sub-project.

- [ ] **Step 1: Write the script by lifting the exact commands from `modem/build_byte_image.sh` and `build_lean_image.sh`**

Keep their MATLAB invocation verbatim (it is the recorded recipe); parameterise only the output directory. Run MATLAB under `systemd-run --user` with a 3 h timeout; `PATH=/usr/bin:/bin` first (the `~/.local/bin/as` shadow on nemo breaks builds).

- [ ] **Step 2: Run it, diff, write the verdict**

```bash
systemd-run --user --collect --unit sp2-regen-$(date +%s) --same-dir bash -c 'PATH=/usr/bin:/bin:$PATH modem/fixes/build_base_tree.sh /mnt/onetb/scratch/qpsk-build-trees/regen > /mnt/onetb/scratch/qpsk-build-trees/regen.out 2>&1'
# wait in the background; then
tail -3 /mnt/onetb/scratch/qpsk-build-trees/regen.out
diff -rq /mnt/onetb/scratch/qpsk-build-trees/regen/jupiter_byte_ddrcap2_build.regen/hdl_prj_jupiter_composite/hdlsrc /mnt/onetb/scratch/qpsk-build-trees/base/jupiter_byte_ddrcap2_build/hdl_prj_jupiter_composite/hdlsrc | grep -v '\.zip' | wc -l
```
Whatever the count, write `docs/evidence/sp2/BASE_REGEN_DIVERGENCE.md` (0 differing files is also a recorded result) and wire the `hdl` stage into `build_image.sh` with the verdict in its stamp.

- [ ] **Step 3: Docs and commit**

`docs/build-and-flash.rst`: rewrite around the five stages `hdl base fixes gates vivado`, one paragraph each, naming the script, the stamp, the gate, and the fallback for `hdl`. `docs/provenance.rst`: current rows already carry manifest + commit (Task 11). `docs/byte-plane.rst` / `docs/debug-instruments.rst`: register window "generated from `modem/fixes/fixes.toml`", instruments at `modem/instruments/`.

```bash
/mnt/onetb/scratch/qpsk-build-trees/sphinx-venv/bin/sphinx-build -W -b html docs docs/_build/html 2>&1 | tail -1; tools/check_paths.sh | tail -1
git add modem/fixes/build_base_tree.sh modem/build_image.sh docs
git commit -s -m "hdl stage: regenerate the base tree from the Simulink model, RTL-equivalence gated against the banked tree; docs rewritten around the five build stages"
git push origin per-under-1pct-2026-07
```

---

### Task 13: Final verification and report

- [ ] Fresh-clone proof: `git clone --branch per-under-1pct-2026-07 https://github.com/tfcollins/qpsk-jupiter-modem.git /mnt/onetb/scratch/qpsk-build-trees/fresh && cd fresh && modem/build_image.sh --role A --work /mnt/onetb/scratch/qpsk-build-trees/fresh_work --stop-after fixes` → `APPLY_FIXES_DONE` (proves base fetch + chain from a clone; gates and Vivado already proven).
- [ ] `make -C host clean all test`, `python3 -m pytest modem/fixes/tests modem/instruments -q`, `tests/runTests('L1')`, `sphinx-build -W`, `tools/check_paths.sh`, CI green at HEAD.
- [ ] Report: images deployed with md5 + WNS, PER windows with commands/counts/denominator statement, the manifest sha, what the `hdl` stage's equivalence verdict was, the ledger's rulings, the hdl-dev-2 HOSTS.md gap, and the handoff to sub-project 3 (the model back-port starts from `fixes.toml` as the list of what to reimplement, and from the `hdl` stage's verdict as the reproducibility baseline).
