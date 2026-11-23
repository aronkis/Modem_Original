# txclk_bd.tcl -- ONE clock for the modem and the DAC path: axi_adrv9001 USE_RX_CLK_FOR_TX1 = 1.
#
# WHY (docs/evidence/sp3/SP3_GATE3_RETEST.md sections 7-9): the DUT runs on the ADRV9001 RX SSI clock
# (adc_1_clk) and its transmit samples were handed to the ADI DAC core on the TX reference clock
# (dac_1_clk) through sync_output/sync_fast_to_slow -- an unsynchronised ring buffer under a
# datapath-only max-delay. Per-arm clock phase made ~40 % of arms on 148/sp3 transmit corrupt
# samples; an async FIFO (txcdc, v1/v2) removed the phase dependence but the two clocks also drift
# relative to each other by up to ~0.6 ppm per arm, so any buffer slips periodically (the reverse-leg
# "comb"). With USE_RX_CLK_FOR_TX1 = 1 the ADI TX1 PHY is clocked from the RX1 clock
# (axi_adrv9001_if.v: ext_tx1_clk = adc_1_clk), dac_1_clk IS adc_1_clk, and every path between the
# modem and the DAC is an ordinary same-clock path that Vivado times. TX and RX run at the same rate
# in every profile this rig uses (lvds_61p44_fdd_jupiter), which is the ADI precondition.
#
# Sourced with the Vivado project OPEN (cwd = <kit>/hdl_prj_jupiter_composite/vivado_ip_prj) from the
# vivado stage's pre_synth hook. Idempotent. Undoes a txcdc FIFO (tx_cdc cell) if the kit carried
# one, restoring the reference-design nets. Gates: TXCLK_PARAM_OK, TXCLK_WIRE_OK, TXCLK_VALIDATE_OK.
# Skip: env SP3_SKIP_TXCLK=1.
if {[info exists ::env(SP3_SKIP_TXCLK)] && $::env(SP3_SKIP_TXCLK) eq "1"} {
  puts "TXCLK_SKIPPED (SP3_SKIP_TXCLK=1)"
} else {
set_property CONFIG.USE_RX_CLK_FOR_TX1 {1} [get_bd_cells axi_adrv9001]
if {[get_property CONFIG.USE_RX_CLK_FOR_TX1 [get_bd_cells axi_adrv9001]] ne "1"} { puts "TXCLK_PARAM_FAILED"; exit 1 }
puts "TXCLK_PARAM_OK axi_adrv9001 USE_RX_CLK_FOR_TX1=1 (TX1 PHY clocked from the RX1 clock)"
# undo a txcdc FIFO if present
if {[llength [get_bd_cells -quiet tx_cdc]]} { delete_bd_objs [get_bd_cells tx_cdc]; puts "TXCLK: removed tx_cdc" }
foreach f [get_files -quiet -all tx_cdc_fifo.v] { remove_files $f }
proc _txclk_conn {a b} {
  set pa [get_bd_pins $a]; set pb [get_bd_pins $b]
  set na [get_bd_nets -quiet -of_objects $pa]; set nb [get_bd_nets -quiet -of_objects $pb]
  if {[llength $na] && [llength $nb] && [get_property NAME $na] eq [get_property NAME $nb]} { return }
  if {[llength $nb]} { disconnect_bd_net $nb $pb }
  if {[llength $na]} { connect_bd_net -net $na $pb } else { connect_bd_net $pa $pb }
}
# reference-design nets (the sp2 shape): DUT -> sync_output -> DAC data; DAC valid -> sync_input -> DUT
_txclk_conn sync_output/data_out_tx_0        axi_adrv9001/dac_1_data_i0
_txclk_conn sync_output/data_out_tx_1        axi_adrv9001/dac_1_data_q0
_txclk_conn sync_input/data_valid_out_tx_0   TxRxCompo_ip_0/dut_data_valid_in_tx
set _ok 1
foreach {pin want} {axi_adrv9001/dac_1_data_i0 sync_output/data_out_tx_0 axi_adrv9001/dac_1_data_q0 sync_output/data_out_tx_1 TxRxCompo_ip_0/dut_data_valid_in_tx sync_input/data_valid_out_tx_0} {
  set net [get_bd_nets -quiet -of_objects [get_bd_pins $pin]]
  set drv [get_bd_pins -quiet -of_objects $net -filter {DIR == O}]
  if {[llength $drv] != 1 || [string trim [get_property NAME $drv] /] ne [lindex [split $want /] end]} { puts "TXCLK_WIRE_BAD $pin <- $drv"; set _ok 0 }
}
if {!$_ok} { puts "TXCLK_WIRE_FAILED"; exit 1 }
puts "TXCLK_WIRE_OK reference nets in place; modem and DAC on one clock"
validate_bd_design -quiet
puts "TXCLK_VALIDATE_OK"
save_bd_design
}
