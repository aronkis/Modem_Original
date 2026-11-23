# modem/prod -- the flattened, cleaned model

`commhdlQPSKTxRxLoopback.slx` here is a TRACKED binary: the dev model with every
overlay applied, auto-arranged, register ports prefixed `reg_` and numbered
DATA / CONTROL / DEBUG, the composite and Receiver laid out in lanes, ports
snapped to their pins, the two model-simulation fixes applied (BIST print branch
removed, RxAlign latency as the `rxAlignLat` parameter), the debug outputs on
the delete-list removed, and a root simulation harness so Play runs it.

**It is derived, not hand-maintained.** `derive/derive.sh` rebuilds it from
`modem/dev` in one MATLAB session and records the structural diff against the
previous prod model in `DERIVATION.txt` / `DERIVATION_DIFF.txt`. Hand edits in a
prod edit kit are for exploration; anything to keep goes into the derivation
(`derive/prod_cleanup.m` holds the delete-list) and is re-derived.

```
modem/prod/derive/derive.sh            # dev -> prod (about 15 min of MATLAB)
git diff --stat modem/prod            # the model + its consumers changed
cat modem/prod/DERIVATION.txt         # what changed structurally vs the previous prod
```

## Layout (stage folders, like `dev/`; Step = the row in `modem/README.md` "Build order", 0 = the dev -> prod derivation that replaces step 1)

| Step | Where | Stage | Contents |
|---|---|---|---|
| 0 | `derive/` | dev -> prod derivation | `derive.sh`, `derive_prod.m`, `prod_cleanup.m` (delete-list), `make_flat_model.{sh,m}`, `patch_gates_for_flat.sh`, `annotate_flat_rate_handle.m`, `resize_ports_like.m`, the flat-model pictures and report |
| entry | root | entry points | `commhdlQPSKTxRxLoopback.slx` (the derived model), `build_variant_byte.m` (loads the model and runs the workflow; no assemble), `hdlworkflow_loopback.m` (AXI register map with the `reg_` block paths), `DERIVATION.txt` / `DERIVATION_DIFF.txt`, the gate stamps |
| 3 | `simgate/` | model-level simulation gate | `sim_byte_gate_k5.m` (errors instead of re-assembling; sets `rxAlignLat = 25` for its run); `gen_byte_vectors_k5.m` (link to dev) |
| 4 | `hdlsim/` | netlist gates | `checkhdl_gate_240k5_byte.m` (checkhdl + makehdl on the loaded model), `run_netlist_gates.sh` (skips the k5-only S1 at f1536; S1B is the proof), `s1_analyze_240k5.m` / `s1b_analyze_byte.m` (links to dev), `rtl_sim_overrides/` (`wrap_byte.v`, `sim_byte.cpp` bound to the `reg_` pin names; installed over `rtl_sim/` in a kit) |
| loop | `edit/` | prod edit kit | `make_edit_kit.sh`, `flat_gate.sh` (diff \| candidates \| rename \| order \| layout \| snap \| reroute \| harness \| simfix \| sim \| hdl \| status), the `flat_*.m` cleanup functions |
| 7-8 | `evidence/` | | Gate 1 / Gate 2 records of the prod-built image |
| -- | from `modem/common/` and `modem/` at kit time | | frame config, parameter/init functions, byte-plane bodies, `kitpath.m`, Tcl/XDC, `rxfifo`, `tools`, plus `instruments`, `rtl_sim`, `vivado`, `gates` and dev's `gen_byte_vectors_k5.m` / `s1_analyze_240k5.m` / `s1b_analyze_byte.m` -- copied by `modem/common/tools/make_kit.sh prod <kit>`; no symlinks in the repo |

Every entry point calls `kitpath(KITDIR)`, which puts the stage folders on the
MATLAB path; nothing else needs to know the layout.

What the steps do in this tree:

- **0 `derive/`** -- `derive.sh` copies `modem/dev` into a scratch kit, runs the full assembly
  there, then `derive_prod.m` flattens the result (`make_flat_model.m`), renames the register
  ports with the `reg_` prefix, orders and lays out the ports and lanes, applies the two
  simulation fixes, deletes the debug blocks on `prod_cleanup.m`'s list, adds the root
  harness, patches the gate scripts for a flattened model and installs the outputs here,
  recording the structural diff in `DERIVATION_DIFF.txt`. This replaces step 1.
- **entry** -- `build_variant_byte.m` loads the derived model and runs the HDL Coder workflow
  (step 2); there is no assembly. `hdlworkflow_loopback.m` already carries the `reg_` block
  paths.
- **3 `simgate/`** -- the same byte gate as dev's, patched to refuse re-assembly and to set the
  `rxAlignLat` simulation value; the vector generator is dev's, linked.
- **4 `hdlsim/`** -- checkhdl and the netlist gates on the loaded model; S1 is skipped at the
  f1536 geometry (its analyser is k5-only) and S1B is the proof; `rtl_sim_overrides/` binds the
  Verilator bench to the `reg_` pin names.
- **loop `edit/`** -- `make_edit_kit.sh` builds a scratch kit with the flat model installed and
  `flat_gate.sh` offers the cleanup and check verbs (diff, candidates, rename, order, layout,
  snap, reroute, harness, simfix, sim, hdl, status). Edits worth keeping go back into the
  derivation, not into this tree.
- **7-8 `evidence/`** -- the Gate 1 leg log and the Gate 2 timing line of the prod-built image.


## Simulating

Set `rxAlignLat = uint16(25)` in the base workspace, then Play. The InitFcn
defaults it to 41, the netlist value used for HDL, and only when the variable
does not exist yet. `txds` 0 = ROM BIST frames (bit errors stop at the warm-up
value, `cap_out` = 0x04922282); `rx_sel` false = internal loopback.

## Gates

```
modem/prod/edit/make_edit_kit.sh   # scratch kit copied from this tree
modem/prod/edit/flat_gate.sh sim   # model-level byte gate (fresh stamp required)
modem/prod/edit/flat_gate.sh hdl   # checkhdl + S1B (S1 skipped at f1536)
```

`build_image.sh --tree prod` is the shipped chain since 2026-09-16: image
`b68dbf1d9321` passed Gates 1-3 (`DERIVATION.txt`, `evidence/`) and runs on both
boards as roles A and B.
