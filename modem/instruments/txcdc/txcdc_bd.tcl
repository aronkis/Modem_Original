# txcdc_bd.tcl -- put tx_cdc_fifo (a real async FIFO) on the modem -> DAC sample crossing.
# Sourced with the Vivado project OPEN (cwd = <kit>/hdl_prj_jupiter_composite/vivado_ip_prj),
# from the vivado stage's pre_synth hook or from build_hdl.sh's BD session. Idempotent.
# Hard gates printed for the caller: TXCDC_WIRE_OK, TXCDC_VALIDATE_OK. Skip: env SP3_SKIP_TXCDC=1.
#
# Before:  TxRxCompo_ip_0/dut_data_out_{0,1}_tx --(adc_1_clk)--> sync_output/sync_fast_to_slow
#          --(dac_1_clk, unsynchronised ring buffer)--> axi_adrv9001/dac_1_data_{i0,q0}
# After:   TxRxCompo_ip_0/dut_data_out_{0,1}_tx + dut_data_valid_out_tx --> tx_cdc (wr, adc_1_clk)
#          tx_cdc (rd, dac_1_clk, popped by axi_adrv9001/dac_1_valid_i0) --> dac_1_data_{i0,q0}
#          sync_output keeps its inputs (unchanged) and its i1/q1 outputs; only i0/q0 move.
if {[info exists ::env(SP3_SKIP_TXCDC)] && $::env(SP3_SKIP_TXCDC) eq "1"} {
  puts "TXCDC_SKIPPED (SP3_SKIP_TXCDC=1)"
} else {
set _txcdc_dir [file dirname [file normalize [info script]]]
set _txcdc_v   [file join $_txcdc_dir tx_cdc_fifo.v]
if {![file exists $_txcdc_v]} { puts "TXCDC_FATAL tx_cdc_fifo.v not beside [info script]"; exit 1 }
file copy -force $_txcdc_v tx_cdc_fifo.v      ;# always refresh the project copy from the kit root
if {![llength [get_files -quiet -all tx_cdc_fifo.v]]} {
  add_files -norecurse tx_cdc_fifo.v
  update_compile_order -fileset sources_1
}
# the module is tx_cdc_fifo_v2 (renamed with the v2 port set: IP integrator keeps a stale parse of a
# module reference whose file changed underneath it, and a new name cannot be stale)
if {![llength [get_bd_cells -quiet tx_cdc]]} {
  create_bd_cell -type module -reference tx_cdc_fifo_v2 tx_cdc
} elseif {![llength [get_bd_pins -quiet tx_cdc/dut_req]]} {
  # the cell was made from an older tx_cdc_fifo.v (v1 had no dut_req): re-read the module and
  # rebuild the cell from it (update_module_reference wants cell OBJECTS, and a stale parse of the
  # file is what left the pin missing, so the file is re-added as well)
  delete_bd_objs [get_bd_cells tx_cdc]
  remove_files [get_files -all tx_cdc_fifo.v]
  add_files -norecurse tx_cdc_fifo.v
  update_compile_order -fileset sources_1
  create_bd_cell -type module -reference tx_cdc_fifo_v2 tx_cdc
}
puts "TXCDC_CELL_PINS [get_bd_pins -quiet tx_cdc/*]"
# the two nets that carried the crossed samples into the DAC core
foreach n {sync_output_data_out_tx_0 sync_output_data_out_tx_1} {
  set net [get_bd_nets -quiet $n]
  if {[llength $net]} {
    foreach p [get_bd_pins -quiet -of_objects $net -filter {NAME =~ dac_1_data_*}] { disconnect_bd_net $net $p }
  }
}
# v2: the DUT's TX request no longer comes from the crossed DAC valid (sync_input) but from the FIFO
set _vin [get_bd_pins TxRxCompo_ip_0/dut_data_valid_in_tx]
set _vnet [get_bd_nets -quiet -of_objects $_vin]
if {[llength $_vnet] && ![llength [get_bd_pins -quiet -of_objects $_vnet -filter {NAME =~ dut_req}]]} { disconnect_bd_net $_vnet $_vin }
# connect only what is not connected yet (the script is re-sourced on every build of a kit whose
# BD already carries tx_cdc: a saved dry run, or a second synth pass)
proc _txcdc_conn {a b} {
  if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins $a]]]} { return }
  connect_bd_net [get_bd_pins $a] [get_bd_pins $b]
}
# write side (adc domain, straight from the DUT)
_txcdc_conn tx_cdc/wr_clk   axi_adrv9001/adc_1_clk
_txcdc_conn tx_cdc/wr_rstn  TxRxCompo_ip_0/IPCORE_RESETN
_txcdc_conn tx_cdc/wr_valid TxRxCompo_ip_0/dut_data_valid_out_tx
_txcdc_conn tx_cdc/wr_i     TxRxCompo_ip_0/dut_data_out_0_tx
_txcdc_conn tx_cdc/wr_q     TxRxCompo_ip_0/dut_data_out_1_tx
_txcdc_conn tx_cdc/dut_req  TxRxCompo_ip_0/dut_data_valid_in_tx
# read side (dac domain)
_txcdc_conn tx_cdc/rd_clk   axi_adrv9001/dac_1_clk
_txcdc_conn tx_cdc/rd_rstn  sync_output/tx_rstn
_txcdc_conn tx_cdc/rd_req   axi_adrv9001/dac_1_valid_i0
_txcdc_conn tx_cdc/rd_i     axi_adrv9001/dac_1_data_i0
_txcdc_conn tx_cdc/rd_q     axi_adrv9001/dac_1_data_q0
# gate: every DAC i0/q0 input is driven by tx_cdc and by nothing else; the DUT pins fan out to tx_cdc
set _ok 1
foreach {pin want} {axi_adrv9001/dac_1_data_i0 tx_cdc/rd_i axi_adrv9001/dac_1_data_q0 tx_cdc/rd_q TxRxCompo_ip_0/dut_data_valid_in_tx tx_cdc/dut_req} {
  set net [get_bd_nets -quiet -of_objects [get_bd_pins $pin]]
  set drv [get_bd_pins -quiet -of_objects $net -filter {DIR == O}]
  if {[llength $drv] != 1 || [string trim [get_property NAME $drv] /] ne [lindex [split $want /] end] } { puts "TXCDC_WIRE_BAD $pin <- $drv"; set _ok 0 }
}
foreach pin {tx_cdc/wr_valid tx_cdc/wr_i tx_cdc/wr_q tx_cdc/rd_req tx_cdc/wr_clk tx_cdc/rd_clk} {
  if {![llength [get_bd_nets -quiet -of_objects [get_bd_pins $pin]]]} { puts "TXCDC_WIRE_BAD $pin unconnected"; set _ok 0 }
}
if {!$_ok} { puts "TXCDC_WIRE_FAILED"; exit 1 }
puts "TXCDC_WIRE_OK dac_1_data_i0/q0 <- tx_cdc (xpm_fifo_async, 64 deep, primed 32); dut_data_valid_in_tx <- tx_cdc/dut_req (v2 pacing)"
validate_bd_design -quiet
puts "TXCDC_VALIDATE_OK"
save_bd_design
}
