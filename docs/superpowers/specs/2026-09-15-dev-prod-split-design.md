# dev / prod model split -- design

Date: 2026-09-15. Status: approved in conversation (two PRs; deletions scripted).

## Problem

The modem model exists in two forms that are currently kept in two different
places: the overlay-driven source in the repo (`modem/` root: source `.slx`,
assemble script, ~50 overlays) and a hand-cleaned flattened copy in a scratch
edit kit outside git. Nothing feeds the cleaned model back, and a fresh clone
cannot reproduce it.

## Target layout

```
modem/
  dev/      the overlay-driven source and everything that only it needs:
            commhdlQPSKTxRx.slx, assembled commhdlQPSKTxRxLoopback.slx,
            assemble_jupiter_240k5_byte.m + every overlay, patch_hdlworkflow_*,
            build_composite_local.m, variant_pre.m, hdlworkflow_loopback.m,
            build_variant_byte.m, gate scripts + runners + stamps + recorded
            .out logs, rxfix/, asrun snapshot
  prod/     the flattened, cleaned model as a TRACKED .slx plus the files that
            bind to its renamed ports: hdlworkflow_loopback.m, a load-only
            build_variant_byte.m, sim_byte_gate_k5.m, checkhdl gate,
            run_netlist_gates.sh, rtl_sim_overrides/{wrap_byte.v,sim_byte.cpp},
            and tools/ (derivation + cleanup kit, formerly modem/flat)
  (root)    shared: build_image.sh, build_hdl.sh, rxfifo_inject.sh + rxfifo_bram/,
            instruments/, vivado/, gates/, rtl_sim/, fixes/, regmap/, boot/,
            tests/, legacy_builds/, debug/, the Tcl/XDC cluster,
            frame_config_k5.m, the model parameter/init functions, the byte-plane
            MATLAB Function bodies, tmr_attr_inject.sh, complete_byte_t8.tcl
```

Files a kit root needs but which are shared appear in `dev/` and `prod/` as
relative symlinks. The kit copy (`build_hdl.sh`, the derivation, the edit-kit
builder) dereferences symlinks (`rsync -aL`) so a kit is self-contained as today.
`modem/contract -> ../contract` provides the sibling contract dir for kit roots.

## Kit-root contract (unchanged)

Each tree is a complete kit root: `cd <kit>` + `addpath(<kit>)`, overlays by bare
name, `hdlworkflow_loopback.m` and the four stamps by relative name, Tcl by
`[info script]`, `../contract` for goldens.

## Build selection

`build_hdl.sh --tree dev|prod` (default `dev`) chooses which tree becomes the kit.
`dev` assembles; `prod` loads the flat model and runs the workflow. Everything
downstream is identical. PR 1 adds the option and keeps `dev` default; PR 2
proves `--tree prod` through the hdl stage and Gates 1-2 before it is used.

## Derivation rule

`prod/` is DERIVED from `dev/` by `prod/tools/derive.sh`: kit copy of dev,
assemble, arrange, then the cleanup chain in ONE MATLAB session
(`derive_prod.m`): rename register ports `reg_`, DATA/CONTROL/DEBUG numbering,
lane layouts (TxRxComposite, Receiver), pin snapping + rerouting, simulation
fixes (BIST print branch removed, RxAlign latency -> `rxAlignLat`), root harness,
`prod_cleanup.m` delete-list (the manual deletions, with dangling outputs
terminated). Output replaces `prod/commhdlQPSKTxRxLoopback.slx`; the structural
diff against the previous prod model is the change record. Hand edits in prod are
for exploration; anything to keep goes into the derivation.

## Acceptance (PR 1)

- `tools/check_paths.sh` OK; `pytest modem/tests` all pass; `sphinx-build -W` clean.
- `derive.sh` runs from a clean tree and its output is STRUCTURE EQUAL (flat_diff)
  to the current edit-kit model, ignoring harness/annotation-only differences.
- sim gate PASS on `prod/` (fresh stamp); checkhdl PASS on `prod/`.
- The shipped build (`build_image.sh`, dev tree) is unchanged in behaviour:
  `build_hdl.sh --dry`-equivalent path checks and the modem tests cover it.

## Out of scope for PR 1

`build_image.sh --tree prod` end-to-end image and Gates 1-3 on it (PR 2).
