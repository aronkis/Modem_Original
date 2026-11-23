# debug -- model experiments, not part of any build or gate

Standalone MATLAB studies run against the assembled DUT model. None of them is
called by `build_image.sh`, `build_hdl.sh`, the assemble script or the gates.
Each one sets the kit root to its parent directory (`modem/`), changes to it and
adds it to the path, so it can be run from anywhere with the production
`QPSK_*` environment exported (see `build_hdl.sh` for the list):

```
matlab -batch "run('modem/debug/loop_gain_poke_test_k5.m')"
```

| Script | Purpose | Output |
|---|---|---|
| `loop_gain_poke_test_k5.m` | C3 loop-gain register poke test: proves the AXI-driven gains reach the loops | `LOOP_GAIN_POKE_K5.txt` |
| `sps4_sync_sweep_k5.m` | A3 rung study: symbol-sync behaviour across the sps=4 parameter space | `SPS4_SYNC_SWEEP_K5.txt` |
| `sim_beat_f1536.m` | long-dwell hunt for the ~120 s error-burst beat seen on silicon | `beat_run/` beside this script |
| `ram_probe_rxdeint.m` | HDL Coder RAM-mapping probe for the deinterleaver | console |

Model-level simulation caveats that apply to all of them are recorded in
`modem/flat/edit/flat_simfix.m`: the BIST message print and the RxAlign latency
literal both differ between simulation and the netlist.
