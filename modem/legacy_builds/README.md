# legacy_builds -- retired build scripts, kept for provenance

Nothing in this folder is on the release path. The shipped images are built by
`modem/build_image.sh` (stages `hdl`, `gates`, `vivado`) and the scripts it
calls from the `modem/` root. These files are the earlier generations of that
chain and the one-off image derivations that produced specific banked images.
They are kept so the provenance rows in `images/README.md` and the evidence
ledgers under `docs/evidence/` can still be read against real code.

They are **not maintained**. Every script here now resolves the kit root as its
parent directory (`modem/`) and refers to its siblings through `legacy_builds/`,
so the paths are consistent, but none of them has been re-run since the move,
and three carry absolute paths to build trees that no longer exist
(`run_gates_resume_t8.sh`, `sidecar_fix.sh`, `build_ch2_image.sh`) or to a
session scratch directory (`build_forensic_image.sh`, `build_t85fix_image.sh`).

| File | What it was |
|---|---|
| `build_byte_image.sh` | pre-sp3 image build: kit copy, `build_variant_byte`, `complete_byte_t8.tcl` to `BOOT.BIN` |
| `build_lean_image.sh`, `build_cyclic_image.sh`, `build_forensic_image.sh`, `build_t85fix_image.sh` | derivations on top of it: LEAN, cyclic RX DMA, ADC forensic taps, the T8.5 fix; each then runs the dual-DMA tap and ch2 rebuild Tcl |
| `build_ch2_image.sh` + `bd_ch2_rewire.tcl`, `bd_ch2_reset.tcl`, `bd_ch2_tapfix.tcl`, `ch2_fix_ch1_bdonly.tcl`, `ch2_fix_ch1.tcl`, `ch2_build2.tcl`, `bd_tap_dualdma.tcl` | the second-channel capture tap and its block-design surgery |
| `build_rxfifo_image.sh` + `resynth_rxfifo.tcl` | re-synthesis after the BRAM ByteRxFifo drop-in (now step 4a of `build_hdl.sh`) |
| `complete_stock_t8.tcl`, `complete_and_gather.tcl`, `vivado_insert_ip_TEMPLATE.tcl`, `tcl_connect_fix.py` | earlier Vivado completion flows and the insert-path workaround they needed |
| `run_gates_resume_t8.sh`, `s2_gate_v4.sh`, `s2_gate_v5.sh`, `static_rate_parity_gate.sh`, `sidecar_fix.sh` | resumable gate runner, post-build S2 gates, the static rate-parity check, a sidecar patch |
| `tx_dac_cdc_fifo.v`, `tx_dac_gather.v` | superseded TX DAC path Verilog (the txclk fix replaced them) |
| `hdlworkflow_loopback.m.mult1bak`, `complete_byte_t8.tcl.pre_cyclic` | backups of two root files from before specific edits |

Still at the `modem/` root because live code or tests depend on them:
`bd/complete_byte_t8.tcl` (the block-design half is checked byte-for-byte against
`complete_byte_bd.tcl` by `modem/tests/test_build_image.py`) and
`tools/tmr_attr_inject.sh` (opt-in `TMR_ATTR=1` path of `modem/fixes/txfix_kit.sh`).
