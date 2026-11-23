# modem/dev -- the overlay-driven source

This is the kit root the release build uses today (`build_hdl.sh --tree dev`,
the default). `commhdlQPSKTxRx.slx` is the source model; every build runs
`assemble_jupiter_240k5_byte.m`, which applies the ordered overlay stack and
rewrites `commhdlQPSKTxRxLoopback.slx`, then `hdlworkflow_loopback.m` generates
the IP core. Both `.slx` files here are therefore mutable as-built artefacts.

Shared files that a kit root needs but that are identical for dev and prod
(frame config, parameter and init functions, byte-plane function bodies,
`kitpath.m`, the Tcl/XDC cluster, `rxfifo`) live once under `modem/common/`;
`instruments`, `rtl_sim`, `vivado` and `gates` live under `modem/`. Nothing here is
a symlink: `modem/common/tools/make_kit.sh dev <kit>` copies all of it beside this
tree's files when a kit is assembled. Everything that is dev's own sits in a folder
named for the build stage that uses it, numbered in `modem/README.md` "Build order";
every entry point calls `kitpath(KITDIR)`
to put those folders on the MATLAB path.

| Step | Where | Stage | Contents |
|---|---|---|---|
| entry | root | entry points | `commhdlQPSKTxRx.slx` (source model), `commhdlQPSKTxRxLoopback.slx` (assembled output), `build_variant_byte.m` (assemble + HDL Coder), `hdlworkflow_loopback.m` (exported Workflow Advisor script, patched in place by the `hdlcoder/` patchers), the gate stamps and logs (`SIM_BYTE_GATE_K5.txt`, `CHECKHDL_240K5_BYTE.txt`, `S1_GATE.txt`, `S1B_GATE.txt`, `*.out`) |
| 1 | `simulink/` | model assembly | `assemble_jupiter_240k5_byte.m` (the ordered overlay stack), `run_assemble_byte.m`, `build_composite_local.m`, `variant_pre.m`, every `*_overlay*.m`, `resolver_lookback_fix.m`, `fec_remove_scrambler.m`; `beatila/` and `rxfix/` (the beat-fix and RX-fix overlay sets); `oneway_overlay.m` + `assemble_oneway.sh` (ONE-DIRECTIONAL images, `QPSK_ONEWAY=tx\|rx`, phase 2.22) |
| 2 | `hdlcoder/` | HDL Coder setup | `patch_hdlworkflow_{counters,taps,forensic,loopgain}.m`: phase-0 patchers of the AXI map in `hdlworkflow_loopback.m` (the beatfix and rxfix patchers live with their overlays) |
| 3 | `simgate/` | model-level simulation gates | `sim_byte_gate_k5.m` (byte gate on the assembled model), `gen_byte_vectors_k5.m` (golden vectors for the netlist gates), `sim_oneway_pair_gate.m` + `run_oneway_pair_gate.sh` (TX-only -> RX-only pair simulation, the one-way images' Gate 1) |
| 4 | `hdlsim/` | netlist gates | `checkhdl_gate_240k5_byte.m` (checkhdl + makehdl + HDL grep gates), `s1_analyze_240k5.m` (S1, k5 only), `s1b_analyze_byte.m` (S1B), `run_netlist_gates.sh` (checkhdl -> vectors -> S1 -> S1B), `run_full_gates_t8.sh` (assemble + sim gate + the netlist gates) |
| -- | `asrun/` | provenance | `asrun_433fd8da/`, `commhdlQPSKTxRxLoopback_asrun_433fd8da.slx`: as-run snapshot for a banked image |

What the steps do in this tree:

- **entry** -- `build_variant_byte.m` sets up the toolbox, calls `kitpath`, runs the assembly
  (step 1) and the HDL Coder workflow (step 2) in one MATLAB session; `hdlworkflow_loopback.m`
  is the exported workflow script that the patchers rewrite before it runs.
- **1 `simulink/`** -- `assemble_jupiter_240k5_byte.m` loads `commhdlQPSKTxRx.slx`, runs
  `build_composite_local.m` and `variant_pre.m` to shape the composite, then applies every
  `*_overlay*.m` in order (`beatila/` and `rxfix/` hold the beat-fix and RX-fix overlay sets,
  `oneway_overlay.m` runs last and only when `QPSK_ONEWAY` is set) and saves
  `commhdlQPSKTxRxLoopback.slx`. Its pre-synth gates assert the overlays landed.
- **2 `hdlcoder/`** -- the phase-0 patchers add the counters, taps, forensic and loop-gain
  registers to the workflow script's AXI map; the beat-fix and RX-fix patchers live beside
  their overlays. Nothing here runs HDL Coder itself; the entry script does.
- **3 `simgate/`** -- `sim_byte_gate_k5.m` builds the byte harness round the assembled model
  and runs its four cases (aligned, rotated, alternate pad, ROM regression);
  `gen_byte_vectors_k5.m` writes the golden vectors the netlist gates reuse;
  `sim_oneway_pair_gate.m` drives a TX-only composite into an RX-only one for the one-way
  images.
- **4 `hdlsim/`** -- `checkhdl_gate_240k5_byte.m` re-runs checkhdl and makehdl and greps the
  generated HDL for the expected constants; `s1_analyze_240k5.m` scores the Icarus ROM replay;
  `s1b_analyze_byte.m` scores the Verilator byte replay; `run_netlist_gates.sh` chains them,
  `run_full_gates_t8.sh` prefixes the assembly and the model gate.
- **`asrun/`** -- the model exactly as it was when a banked image was generated, for
  provenance; nothing builds from it.

To produce the flattened `modem/prod` from this tree: `modem/prod/derive/derive.sh`.
