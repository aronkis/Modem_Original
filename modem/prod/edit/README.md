# prod/edit -- cleaning up the flat model

Tooling for turning `modem/commhdlQPSKTxRxLoopback_flat.slx` (every overlay
applied, auto-arranged) into a clean model by hand, with the repo's own gates
run against each step. The image build does not read the flat model; promoting
the cleaned model to a build source is a separate decision (see the last section).

## Workflow

```
modem/prod/edit/make_edit_kit.sh                 # once: scratch kit with the flat model installed
source /mnt/onetb/scratch/qpsk-build-trees/flat_edit/jupiter_byte_flatedit_build/env.sh
cd /mnt/onetb/scratch/qpsk-build-trees/flat_edit/jupiter_byte_flatedit_build
matlab                                            # open commhdlQPSKTxRxLoopback.slx, edit, save

modem/prod/edit/flat_gate.sh candidates           # what looks like debug (read-only list)
modem/prod/edit/flat_gate.sh diff                 # what changed vs the snapshot, port order
modem/prod/edit/flat_gate.sh rename apply         # reg_ prefix on every register port (+ kit consumers)
modem/prod/edit/flat_gate.sh order apply          # renumber ports DATA / CONTROL / DEBUG
modem/prod/edit/flat_gate.sh layout apply         # TxRxComposite canvas: TX / RX / byte DMA / debug lanes
modem/prod/edit/flat_gate.sh snap apply [all]     # then: ports beside the pin they feed, colour-coded (all = every level)
modem/prod/edit/flat_gate.sh reroute [all|Sub]    # rebuild wires with the smart router after any hand move
modem/prod/edit/flat_gate.sh harness apply        # sources/sinks/loopback round TxRxComposite at the root (Play runs it)
modem/prod/edit/flat_gate.sh sim                  # inner loop: model-level byte gate
modem/prod/edit/flat_gate.sh tidy Receiver ...    # auto-arrange named subsystems (NOT TxRxComposite: that undoes the lanes)
modem/prod/edit/flat_gate.sh hdl                  # outer loop: checkhdl + makehdl + S1/S1B netlist gates
modem/prod/edit/flat_gate.sh status
```

Edit only inside the kit. The repo copy of the flat model is the snapshot you
started from; copy the kit model back over it (or under a new name) when a
cleanup pass is done and gated.

## Port colours (flat_snap_ports)

| | DATA | CONTROL | DEBUG |
|---|---|---|---|
| Inport | light blue | light amber | light grey |
| Outport | blue | amber | grey |

Class comes from `flat_port_class.m` (exact lists for the composite names, name
patterns below that). Run `layout` before `snap`: layout places the lanes and a
first port arrangement, snap then pulls each port to the pin it is wired to.

## What the kit guards against

* The gates bind to the literal model name `commhdlQPSKTxRxLoopback`; the kit
  installs the flat model under that name and keeps `flat_ref.slx` read-only.
* `sim_byte_gate_k5.m` normally re-assembles from the source model when the
  description stamp does not match. In the kit that path is an error, so a bad
  edit can never be silently replaced by a rebuilt model.
* `checkhdl_gate_flat.m` is the checkhdl gate with the assemble call replaced by
  `load_system`; `run_netlist_gates.sh` calls it.
* `assemble_jupiter_240k5_byte.m` errors on line 1 in the kit.
* `env.sh` carries the production `QPSK_*` exports. Without them the frame
  config falls back to the old rung and the gates fail for the wrong reason.

## Removing debug: what else has to move

| You delete | Also change |
|---|---|
| a `TxRxComposite` outport (register / witness) | its `hdlset_param ... IOInterface` line in `hdlworkflow_loopback.m` (block-existence guarded, drops out silently); the entry in `modem/regmap/regmap.toml` for 0x208 and up, then `gen_regmap.py`; `host/` readers of that offset |
| any beatobs / beatfix / W1 port on `Symbol Synchronizer` or `Frequency and Time Synchronizer` | `modem/instruments/ddrcap2/ddrcap2_inject.py` anchors on port NAMES and on `beatobsPop` being the LAST pin; `flat_gate.sh diff` prints the port order for exactly this reason |
| `debugI/Q`, `debugI1/Q1`, `debugValid` | the RX capture DMA in the reference design; `hdlworkflow_loopback.m` maps them to `IP Data 0/1/2/3 OUT` |
| anything on the TX chain | the BIST golden `cap_out` and the S1 ROM gate will tell you immediately |

`flat_debug_candidates.m` marks composite ports that are not one of the
functional interfaces as `COMPOSITEPORT`; those are the ones that need the
register-map edits above. `fixctl`, `tx_data_source`, `rx_input_select` and the
byte-plane ports are load-bearing and are excluded from that list.

## Promoting the cleaned model to a build source (later)

`build_variant_byte.m` runs the assemble then `hdlworkflow_loopback.m`. To build
an image from the cleaned model instead: install it in a regular kit as
`commhdlQPSKTxRxLoopback.slx`, replace the `run('assemble_...')` line with
`load_system`, keep `hdlworkflow_loopback.m` in sync with the surviving ports,
and run `modem/build_image.sh` from the `hdl` stage so Gates 1 and 2 re-prove it.
The overlay scripts and the cleaned model will diverge from the first deletion;
that is expected, and the netlist gates are what keep the two honest.
