# modem/ -- two model trees and the shared build machinery

```
modem/
  README.md            this map
  build_image.sh       the driver: hdl -> gates -> vivado (stamps, Gate 2)
  build_hdl.sh         the hdl stage (--tree dev|prod)
  dev/                 KIT ROOT 1: the overlay-driven source model + assemble/overlays/gates
  prod/                KIT ROOT 2: the flattened, derived model (prod/derive/derive.sh)
  common/              everything both trees share, ONCE, as real files (no symlinks anywhere):
    bd/                Vivado block-design completion Tcl + the three XDC (one sibling group)
    model/             the shared MATLAB files (frame config, parameter/init fns, byte-plane bodies, kitpath)
    rxfifo/            the BRAM ByteRxFifo drop-in and its injector (hdl stage [4a])
    tools/             make_kit.sh (assembles a scratch kit from a tree + common/), tmr_attr_inject.sh
  gates/  rtl_sim/     Gate 1: the Verilator leg matrix and the live simulation benches
  instruments/         netlist / block-design injectors (txcap, ddrcap, ddrcap2, seqbist, txclk ...)
  vivado/              remote build templates (hdl-dev-2)
  fixes/  regmap/  boot/   sp2 netlist-fix chain, register map source, board-side boot files
  tests/               pytest + shell tests of the build scripts
  legacy_builds/  debug/  retired build scripts (provenance); standalone model experiments
```

## Build order (what runs when, and where it lives)

| # | Stage | Where | Runs as |
|---|---|---|---|
| 1 | Model assembly: overlays applied to the source model | `dev/simulink/` (`assemble_jupiter_240k5_byte.m`) -- `prod/` skips this, its model is derived by `prod/derive/derive.sh` | `build_hdl.sh` step [3] (`build_variant_byte.m`) |
| 2 | HDL Coder: workflow script patched, IP core generated | `<kit>/hdlworkflow_loopback.m`, `dev/hdlcoder/` patchers, `model/` function bodies | same MATLAB session |
| 3 | Model-level gates (Simulink simulation) | `<kit>/simgate/` (`sim_byte_gate_k5.m`; one-way pair sim) | `simgate/` runners, `prod/edit/flat_gate.sh sim` |
| 4 | Netlist gates on the generated RTL (checkhdl, S1, S1B) | `<kit>/hdlsim/` + `rtl_sim/` (wrap_byte.v, sim_byte.cpp) | `hdlsim/run_netlist_gates.sh`, `flat_gate.sh hdl` |
| 5 | Netlist injections + the BRAM FIFO drop-in | `instruments/` (txcap, ddrcap, ddrcap2), `rxfifo/` | `build_hdl.sh` steps [4], [4a] |
| 6 | Block-design completion (Vivado, local) | `bd/` (Tcl + XDC), `instruments/{ddrcap,seqbist}/*_bd.tcl` | `build_hdl.sh` step [5] -> `BUILD_HDL_BD_OK` |
| 7 | Gate 1: the Verilator leg matrix on the model tree | `gates/` (legs, runner), `rtl_sim/` (make_sro_trees, six objects) | `build_image.sh` gates stage (`GATES_JOBS=N`) |
| 8 | Synthesis, implementation, boot image; Gate 2 timing | `vivado/` templates on hdl-dev-2, `gates/modem_wns.py` | `build_image.sh` vivado stage -> `BUILD_IMAGE_WNS_OK` |
| 9 | Bank, deploy, Gate 3 on the rig | `../images/`, `../ops/` (flash rails, `gate3_run.sh`, `gate3_pair.sh` for a new rung such as sp4/r4, `oneway_*.sh`; rungs in `../ops/rung_table.sh`) | operator-directed |

What each step does:

1. **Model assembly.** Starts from the MathWorks example model and applies the overlay
   stack in a fixed order: the K5 frame geometry and ROM message source, the in-fabric
   FEC encoder and interleaver, the byte-plane DMA plumbing, the AXI-visible taps and
   counters, the beat-fix, RX-fix and TX-fix subsystems, and (for a one-way image) the stub
   of the unused half. The result is the assembled model the rest of the chain uses. `prod/`
   holds that result already flattened and cleaned, so it skips this step.
2. **HDL Coder.** The exported Workflow Advisor script is patched in place with the register
   map the overlays need (each phase-0 patcher adds its addresses), then HDL Coder generates
   the `TxRxComposite` IP core into `hdl_prj_jupiter_composite/hdlsrc`. The shared `model/`
   functions are the MATLAB Function block bodies it compiles.
3. **Model-level gates.** The assembled Simulink model is simulated end to end with a byte
   harness: ROM frames and host byte frames go through the transmitter, the loopback and the
   receiver, and the gate checks the BIST digest, the bit-error counter and the delivered
   byte words against the golden vectors. This proves the model before any HDL is trusted.
4. **Netlist gates.** `checkhdl` and `makehdl` re-run on the loaded model, then the generated
   Verilog is simulated: S1 replays the ROM path through Icarus (k5 geometry only), S1B runs
   the byte path through Verilator with the same golden vectors as step 3. A mismatch here
   is a model-to-HDL translation defect, not a model defect.
5. **Netlist injections.** Python injectors splice the capture instruments (txcap, ddrcap,
   ddrcap2) into the generated Verilog by anchoring on known lines, and the hand-written
   BRAM ByteRxFifo drop-in replaces the generated register FIFO in every copy (loose files,
   IP core, zips), mirrored at the delay-balance depth the generator chose.
6. **Block-design completion.** A local Vivado session opens the HDL Coder project, adds the
   modem IP to the reference design, wires the byte DMAs and IRQs, applies the constraints,
   attaches the ddrcap and SEQ-BIST block-design instruments and validates the design. The
   printed tokens are the hard gate for the stage.
7. **Gate 1.** The regenerated RTL is turned into a model gate tree, six Verilator objects
   are compiled from it, and the leg matrix runs every documented simulation leg (SRO
   stimuli, steering, census, pad, identity checks) against the banked references. The
   verdict is compared leg for leg with the dev tree's; five legs are documented exceptions.
8. **Synthesis and Gate 2.** The kit is rsynced to the build host and the template runs
   synthesis, implementation and bootgen. Gate 2 reads the post-route timing report for the
   modem clock and fails the image if its worst slack is below the floor.
9. **Bank, deploy, Gate 3.** The boot image is banked with its md5 and role, flashed through
   the rails (backup, readback, arm gate, rollback on failure), and Gate 3 runs the capture
   set on the pair: short arms in each direction and 600 s windows, scored with lost frames
   in the denominator. Deployment as the shipped roles is the operator's decision.

Workflow: edit overlays in `dev/` -> `prod/derive/derive.sh` -> review
`prod/DERIVATION.txt` -> gates on prod (`prod/edit/flat_gate.sh sim|hdl`)
-> image (`build_image.sh`, `--tree prod` once it has passed Gates 1-3).

## Shared at this level

| Where | Role |
|---|---|
| `build_image.sh` | the driver: `hdl` -> `gates` (`gates/`, `rtl_sim/`) -> `vivado` (remote synth via `vivado/` templates), stamps and Gate 2; `--tree dev|prod`, `--oneway tx|rx` |
| `build_hdl.sh` | `hdl` stage: fresh kit (`common/tools/make_kit.sh`), production `QPSK_*` environment, MATLAB regeneration (dev assembles, prod loads), netlist injections, block-design completion, kit assembly |
| `common/model/frame_config_k5.m` | single source of truth for frame geometry and samples per symbol (`QPSK_FRAME`, `QPSK_SPS`) |
| `common/model/commhdlQPSKTxRxParameters.m`, `commhdlQPSKTxRxModelInit.m`, `qpskFindTxInputData.m` | the model's parameter and init functions |
| `common/model/qpskByte*.m` | MATLAB Function bodies of the byte plane (bit shifter, serializer, word buffer, skid lag), referenced from both models by name |
| `common/bd/complete_byte_bd.tcl`, `wire_byte_irqs.tcl`, `timing_gate.tcl`, `{cdc_exceptions,tmr_keep,image_a_3072_clocks}.xdc` | Vivado block-design completion and constraints; they locate each other with `[info script]`, so they move as one group |
| `common/bd/complete_byte_t8.tcl` | the full pre-sp3 completion flow; its block-design half is the source of `complete_byte_bd.tcl` and is checked byte-for-byte by `tests/` |
| `common/rxfifo/rxfifo_inject.sh` + `ByteRxFifo.v` | hdl stage [4a]: the hand-written BRAM ByteRxFifo drop-in over the generated one, mirrored at the measured delay-balance chain depth |
| `common/tools/make_kit.sh` | `make_kit.sh <dev\|prod> <kit> [--with-tools]`: the ONE kit assembler (tree + `common/*` + `gates instruments vivado rtl_sim` + a copied sibling `contract/`); every build/derive/edit script calls it; `tests/test_make_kit.sh` |
| `common/model/kitpath.m`, `kit_contract_dir.m` | MATLAB path for a kit root (stage folders + `model/`, in-repo fallbacks) and the sibling `contract/` lookup |
| `common/tools/tmr_attr_inject.sh` | opt-in TMR attribute re-annotation used by `fixes/txfix_kit.sh` (`<kit>/tools/`) |
| `instruments/` | netlist and block-design injectors (`txcap`, `ddrcap`, `ddrcap2`, `seqbist`, `txclk` are on the release path); the beatila instrument lives in `dev/simulink/beatila/` |
| `vivado/`, `gates/`, `rtl_sim/` | remote build templates, the Verilator gate matrix, the live simulation benches (`rtl_sim/README.md`; retired campaigns under `rtl_sim/studies/`) |
| `fixes/`, `regmap/`, `boot/` | the sp2 netlist-fix chain (rollback rebuilds), the register map source, boot-side files |
| `tests/` | pytest and shell tests of the build scripts (kit root = `dev/`) |
| `legacy_builds/`, `debug/` | retired build scripts kept for provenance; standalone model experiments |

## The kit-root contract (no symlinks)

The repo carries every shared file once, under `common/`, and no symlinks at all
(`tests/test_no_symlinks.sh`). `dev/` and `prod/` hold only what is theirs. A build,
a gate run or a derivation never runs in the repo tree: `common/tools/make_kit.sh
<dev|prod> <kit>` assembles a scratch kit -- the tree, then `common/{bd,model,rxfifo,tools}`
as `<kit>/{bd,model,rxfifo,tools}`, then `gates/ instruments/ vivado/ rtl_sim/` (minus
objects and studies), prod's three borrowed dev analysers, prod's `rtl_sim_overrides`,
and a COPY of the repo's `contract/` next to the kit -- and the scripts run with the kit
as the working directory. MATLAB reaches the stage folders and `<kit>/model` through
`kitpath(KITDIR)`; the K5 overlays find `contract/` through `kit_contract_dir(KITDIR)`
(`<kit>/../contract`); Tcl finds its siblings in `<kit>/bd` via `[info script]`. Add a
shared file to `common/` and, if a script needs it by name, to the checklist at the end
of `make_kit.sh`.

## What lives only in a tree

`dev/`: the source model, the assembled model, the assemble script and every
overlay, `beatila/` and `rxfix/`, `hdlworkflow_loopback.m`, `build_variant_byte.m`,
the gate scripts, runners, stamps and recorded logs, the as-run snapshot.

`prod/`: the derived model, its `hdlworkflow_loopback.m` (`reg_` paths), the
load-only `build_variant_byte.m`, its gate scripts and runner, `rtl_sim_overrides/`,
`DERIVATION.txt`, and `tools/` (derive, cleanup kit, generator).

See `dev/README.md` and `prod/README.md`.
