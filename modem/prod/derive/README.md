# prod/derive -- the readable reference model and its tooling

The build chain regenerates the DUT from `modem/commhdlQPSKTxRx.slx` plus the
overlay stack every time. `commhdlQPSKTxRxLoopback_flat.slx` is a one-shot copy
of the result with every overlay applied and every subsystem auto-arranged, made
for reading, review and cleanup. Nothing in the build or the gates reads it.

| File | Purpose |
|---|---|
| `commhdlQPSKTxRxLoopback_flat.slx` | the flat reference model (untracked; regenerate with the script below) |
| `commhdlQPSKTxRxLoopback_flat_report.txt`, `*_0N.png` | arrange log and snapshots of the top levels from the last regeneration |
| `make_flat_model.sh` / `make_flat_model.m` | regenerate: kit copy, production environment, assemble, arrange, annotate, bank here |
| `annotate_flat_rate_handle.m` | explanatory notes inside the Rate Handle subsystem (idempotent) |
| `resize_ports_like.m` | give every Inport/Outport the on-canvas size of a reference port |
| `edit/` | the cleanup kit: scratch-kit setup, structural diff, port rename/order/snap, lane layout, rerouting, root simulation harness, simulation fixes, and gate runners. See `edit/README.md` |

Regenerate:

```
systemd-run --user --collect --same-dir --unit flat-model-$(date +%s) \
  bash -c 'modem/prod/derive/make_flat_model.sh > /mnt/onetb/scratch/qpsk-build-trees/flat_model/run.out 2>&1'
```
