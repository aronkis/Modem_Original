# txclk -- modem and DAC on one clock (axi_adrv9001 USE_RX_CLK_FOR_TX1 = 1)

The root cause of the sp3 Gate 3 wedges and of the long-standing reverse-leg "comb"
(`docs/evidence/sp3/SP3_GATE3_RETEST.md` sections 7-9): the modem runs on the ADRV9001 RX SSI
clock while the ADI DAC core ran on the TX reference clock, with the transmit samples crossing
between them through an unsynchronised ring buffer under a datapath-only constraint. The two clocks
also drift against each other by up to ~0.6 ppm per arm, so even a proper asynchronous FIFO
(`modem/instruments/txcdc`, the first attempt, kept for the record) slips periodically.

`txclk_bd.tcl` sets `USE_RX_CLK_FOR_TX1 = 1` on the ADI core (the TX1 PHY is then clocked from the
RX1 clock, `axi_adrv9001_if.v`), removes a txcdc FIFO if the kit carried one, restores the
reference-design nets, and gates on `TXCLK_PARAM_OK`, `TXCLK_WIRE_OK`, `TXCLK_VALIDATE_OK`.
`pre_synth.tcl` is the kit-root hook `build_txfix.tcl` sources before `generate_target`.
`build_hdl.sh` step [6] copies both into every kit (`SP3_SKIP_TXCLK=1` leaves them out).
Precondition (ADI): TX and RX at the same sample rate -- true for every profile on this rig.
