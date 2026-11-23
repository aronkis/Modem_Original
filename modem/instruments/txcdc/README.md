# txcdc -- a real asynchronous FIFO on the modem -> DAC sample crossing

Why: `docs/evidence/sp3/SP3_GATE3_RETEST.md` sections 7-8. The DUT runs on the ADRV9001 RX
clock (`axi_adrv9001_adc_1_clk`); its transmit samples reach the ADI DAC core on the TX
reference clock (`axi_adrv9001_dac_1_clk`, same 8 ns, phase re-established at every profile
load). The reference design crosses them through `sync_output/sync_fast_to_slow` (an ADI ring
buffer whose read/write addresses are compared across the clocks unsynchronised) under a
`set_max_delay -datapath_only` only. Every arm is a phase lottery; with the sp3 placement on
148 about 40 % of arms transmit corrupt samples.

Files (copied to the kit root by `modem/build_hdl.sh` step [6], or by hand for a rebuild):

| file | role |
|---|---|
| `tx_cdc_fifo.v` | module `tx_cdc_fifo_v2`: `xpm_fifo_async`, 64 deep, fwft, {I,Q} 32 bit, primed to 32 entries; paces the DUT (`dut_req`, paused above 48 entries); re-primes on underflow; sticky underflow/overflow witnesses |
| `txcdc_bd.tcl` | moves `dac_1_data_i0/q0` from `sync_output` to `tx_cdc`; gates `TXCDC_WIRE_OK`, `TXCDC_VALIDATE_OK`; `SP3_SKIP_TXCDC=1` skips |
| `pre_synth.tcl` | the kit hook `build_txfix.tcl` (modem/vivado/txfix_build.tcl.tmpl) sources after `open_project`, before `generate_target` |
| `tb_tx_cdc_fifo.sv`, `run_tb.sh` | xsim testbench: 32 clock phases across the 8 ns period, 4000 samples each, exact sequence check |

Log tokens to require in a build: `PRE_SYNTH_HOOK_OK`, `TXCDC_WIRE_OK`, `TXCDC_VALIDATE_OK`.
