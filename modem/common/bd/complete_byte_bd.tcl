# complete_byte_bd.tcl -- the BLOCK-DESIGN HALF of complete_byte_t8.tcl.
#
# WHY THIS FILE EXISTS (sp3 Task 11, controller ruling 2026-09-12 01:10).
# HDL Coder's "Create Project" task fails on this kit (the insert-path bug), so a
# fresh MATLAB regen leaves vivado_prj.srcs/sources_1/bd/system/system.bd with the
# byte reference design (byte_breakout, rx_byte_dma, ...) but WITHOUT the
# TxRxCompo_ip_0 cell -- the modem DUT is not in the block design at all.
# complete_byte_t8.tcl (run by build_byte_image.sh step 4 for every byte image
# ever built) is what adds it; modem/fixes/build_base_tree.sh stopped BEFORE all
# of that, which is why modem/instruments/ddrcap/ddrcap_bd.tcl aborted on every
# regen with "TxRxCompo_ip_0 missing pins" and was tolerated as a WARN.
#
# This file is complete_byte_t8.tcl lines 1-137 VERBATIM: the XDC adds, the IP
# catalog update, create_bd_cell TxRxCompo_ip_0, the AXI/clock/reset/sync wiring,
# the byte DMA wiring (BYTE_WIRE_OK), wire_byte_irqs.tcl, the stock TX wiring
# check (WIRE_OK), VALIDATE_OK, the DDS diet (DDS_DIET_OK), and the final
# set top / generate_target / update_compile_order.  It stops there: NO
# synth, NO impl, NO bootgen -- those belong to the `vivado` stage
# (modem/vivado/txfix_build.tcl.tmpl) which runs on the Vivado host.
#
# complete_byte_t8.tcl itself is UNCHANGED and still carries both halves, so the
# legacy build_byte_image.sh flow is untouched.  Keep the two in step: this file
# is the prefix of that one.  Verify with
#   diff <(sed -n '1,137p' modem/bd/complete_byte_t8.tcl) \
#        <(sed -n '/^# --- BEGIN complete_byte_t8.tcl lines 1-137/,$p' modem/bd/complete_byte_bd.tcl | tail -n +2)
#
# Contract: run with cwd = <tree>/hdl_prj_jupiter_composite/vivado_ip_prj and
# with this file at the KIT ROOT (`[file dirname [info script]]` is where
# cdc_exceptions.xdc / tmr_keep.xdc / image_a_3072_clocks.xdc / wire_byte_irqs.tcl
# are looked up), exactly as complete_byte_t8.tcl is.  SOURCE it (do not exec it
# standalone) when a caller wants to keep the project open for further BD edits;
# build_hdl.sh does precisely that and then sources ddrcap_bd.tcl and
# seqbist_bd.tcl into the same session before saving.
#
# Hard gates the caller must see in the log: BYTE_WIRE_OK, WIRE_OK, VALIDATE_OK,
# DDS_DIET_OK, then this file's own COMPLETE_BYTE_BD_DONE.
# --- BEGIN complete_byte_t8.tcl lines 1-137 (verbatim) ---------------------
open_project vivado_prj.xpr
# CDC exceptions: the MATLAB IP packaging emits ADI's axi_adrv9001/axi_dmac
# constraint files as stub .txt (never loaded); without these the async
# PS<->ADRV9001-domain crossings are fully timed and placement quality is a
# lottery (lean-image no-lock, 2026-07-15). Kit file: cdc_exceptions.xdc.
set kdir [file dirname [info script]]
file copy -force $kdir/cdc_exceptions.xdc cdc_exceptions.xdc
add_files -fileset constrs_1 -norecurse cdc_exceptions.xdc
set_property USED_IN {implementation} [get_files cdc_exceptions.xdc]
# T8.9 TMR stall fix: the triplicated accumulator registers MUST NOT be merged
# by equivalent-register removal, or the fix is silently deleted from the
# bitstream (netlist sim would still pass -- Verilator does not merge). Applied
# only when the TMR overlay is in the build (env QPSK_MOVSUM_TMR set).
if {[info exists ::env(QPSK_MOVSUM_TMR)] && $::env(QPSK_MOVSUM_TMR) ne ""} {
  file copy -force $kdir/tmr_keep.xdc tmr_keep.xdc
  add_files -fileset constrs_1 -norecurse tmr_keep.xdc
  set_property USED_IN {synthesis implementation} [get_files tmr_keep.xdc]
  set_property PROCESSING_ORDER LATE [get_files tmr_keep.xdc]
  puts "TMR_XDC_ADDED tmr_keep.xdc (DONT_TOUCH on triplicated accumulator)"
}
# IMAGE A (30.72 MHz rungs R0/R1): re-time the fabric to 30.72 MHz. The ADI RD
# constrains the SSI at 125 MHz, but the f1536 modem is sized for 30.72 MHz and
# cannot close at 125 MHz (interleaver mod/idivide(1537) arithmetic). Applied only
# when QPSK_TARGET_MHZ selects the low rung (< 60 MHz -> Image A; Image B @122.88
# leaves the RD's 125 MHz). PROCESSING_ORDER LATE so it overrides the RD's
# create_clock on the dclk ports. See image_a_3072_clocks.xdc for the LOAD-BEARING
# deploy discipline (Image A boards may load ONLY 1.92/15.36 MSPS profiles).
if {[info exists ::env(QPSK_FRAME)] && ($::env(QPSK_FRAME) eq "f1536" || $::env(QPSK_FRAME) eq "f3072") \
        && [info exists ::env(QPSK_TARGET_MHZ)] && [string is double -strict $::env(QPSK_TARGET_MHZ)] && $::env(QPSK_TARGET_MHZ) < 60} {
    file copy -force $kdir/image_a_3072_clocks.xdc image_a_3072_clocks.xdc
    add_files -fileset constrs_1 -norecurse image_a_3072_clocks.xdc
    set_property USED_IN {synthesis implementation} [get_files image_a_3072_clocks.xdc]
    set_property PROCESSING_ORDER LATE [get_files image_a_3072_clocks.xdc]
    puts "IMAGE_A_RECLOCK: applied image_a_3072_clocks.xdc -> fabric adc_1_clk @ 30.72 MHz"
}
set project {jupiter_sdr}
set ref_design {rxtx}
set preprocess {off}
set postprocess {off}
set number_of_inputs {4}
set number_of_bits {16}
set number_of_valids {1}
set multiple {2}
set HDLVerifierAXI {off}
update_ip_catalog -delete_ip {./ipcore/TxRxCompo_ip_v1_0/component.xml} -repo_path {./ipcore} -quiet
update_ip_catalog -add_ip {./ipcore/TxRxCompo_ip_v1_0.zip} -repo_path {./ipcore}
update_ip_catalog
set HDLCODERIPVLNV [get_property VLNV [get_ipdefs -filter {NAME==TxRxCompo_ip && VERSION==1.0}]]
set HDLCODERIPINST TxRxCompo_ip_0
set BDFILEPATH [get_files -quiet system.bd]
open_bd_design $BDFILEPATH
create_bd_cell -type ip -vlnv $HDLCODERIPVLNV $HDLCODERIPINST
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins axi_adrv9001/adc_1_clk]]]} { connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins axi_adrv9001/adc_1_clk]] [get_bd_pins $HDLCODERIPINST/AXI4_Lite_ACLK] [get_bd_pins axi_adrv9001/adc_1_clk] } else { connect_bd_net [get_bd_pins $HDLCODERIPINST/AXI4_Lite_ACLK] [get_bd_pins axi_adrv9001/adc_1_clk] }
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins rx_rstn_inverter/Res]]]} { connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins rx_rstn_inverter/Res]] [get_bd_pins $HDLCODERIPINST/AXI4_Lite_ARESETN] [get_bd_pins rx_rstn_inverter/Res] } else { connect_bd_net [get_bd_pins $HDLCODERIPINST/AXI4_Lite_ARESETN] [get_bd_pins rx_rstn_inverter/Res] }
connect_bd_intf_net [get_bd_intf_pins $HDLCODERIPINST/AXI4_Lite] [get_bd_intf_pins axi_hpm0_lpd_interconnect/M07_AXI]
create_bd_addr_seg -range 0x10000 -offset 0x9D000000 [get_bd_addr_spaces sys_ps8/Data] [get_bd_addr_segs $HDLCODERIPINST/AXI4_Lite/reg0] SEG_${HDLCODERIPINST}_reg0
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins sync_output/data_valid_in_rx_0]]]} { connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins sync_output/data_valid_in_rx_0]] [get_bd_pins $HDLCODERIPINST/dut_data_valid_out_rx] [get_bd_pins sync_output/data_valid_in_rx_0] } else { connect_bd_net [get_bd_pins $HDLCODERIPINST/dut_data_valid_out_rx] [get_bd_pins sync_output/data_valid_in_rx_0] }
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins sync_input/data_valid_out_rx_0]]]} { connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins sync_input/data_valid_out_rx_0]] [get_bd_pins $HDLCODERIPINST/dut_data_valid_in_rx] [get_bd_pins sync_input/data_valid_out_rx_0] } else { connect_bd_net [get_bd_pins $HDLCODERIPINST/dut_data_valid_in_rx] [get_bd_pins sync_input/data_valid_out_rx_0] }
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins sync_output/data_in_rx_0]]]} { connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins sync_output/data_in_rx_0]] [get_bd_pins $HDLCODERIPINST/dut_data_out_0_rx] [get_bd_pins sync_output/data_in_rx_0] } else { connect_bd_net [get_bd_pins $HDLCODERIPINST/dut_data_out_0_rx] [get_bd_pins sync_output/data_in_rx_0] }
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins sync_output/data_in_rx_1]]]} { connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins sync_output/data_in_rx_1]] [get_bd_pins $HDLCODERIPINST/dut_data_out_1_rx] [get_bd_pins sync_output/data_in_rx_1] } else { connect_bd_net [get_bd_pins $HDLCODERIPINST/dut_data_out_1_rx] [get_bd_pins sync_output/data_in_rx_1] }
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins sync_output/data_in_rx_2]]]} { connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins sync_output/data_in_rx_2]] [get_bd_pins $HDLCODERIPINST/dut_data_out_2_rx] [get_bd_pins sync_output/data_in_rx_2] } else { connect_bd_net [get_bd_pins $HDLCODERIPINST/dut_data_out_2_rx] [get_bd_pins sync_output/data_in_rx_2] }
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins sync_output/data_in_rx_3]]]} { connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins sync_output/data_in_rx_3]] [get_bd_pins $HDLCODERIPINST/dut_data_out_3_rx] [get_bd_pins sync_output/data_in_rx_3] } else { connect_bd_net [get_bd_pins $HDLCODERIPINST/dut_data_out_3_rx] [get_bd_pins sync_output/data_in_rx_3] }
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins sync_input/data_out_rx_0]]]} { connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins sync_input/data_out_rx_0]] [get_bd_pins $HDLCODERIPINST/dut_data_in_0_rx] [get_bd_pins sync_input/data_out_rx_0] } else { connect_bd_net [get_bd_pins $HDLCODERIPINST/dut_data_in_0_rx] [get_bd_pins sync_input/data_out_rx_0] }
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins sync_input/data_out_rx_1]]]} { connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins sync_input/data_out_rx_1]] [get_bd_pins $HDLCODERIPINST/dut_data_in_1_rx] [get_bd_pins sync_input/data_out_rx_1] } else { connect_bd_net [get_bd_pins $HDLCODERIPINST/dut_data_in_1_rx] [get_bd_pins sync_input/data_out_rx_1] }
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins sync_input/data_valid_out_tx_0]]]} { connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins sync_input/data_valid_out_tx_0]] [get_bd_pins $HDLCODERIPINST/dut_data_valid_in_tx] [get_bd_pins sync_input/data_valid_out_tx_0] } else { connect_bd_net [get_bd_pins $HDLCODERIPINST/dut_data_valid_in_tx] [get_bd_pins sync_input/data_valid_out_tx_0] }
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins sync_output/data_valid_in_tx_0]]]} { connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins sync_output/data_valid_in_tx_0]] [get_bd_pins $HDLCODERIPINST/dut_data_valid_out_tx] [get_bd_pins sync_output/data_valid_in_tx_0] } else { connect_bd_net [get_bd_pins $HDLCODERIPINST/dut_data_valid_out_tx] [get_bd_pins sync_output/data_valid_in_tx_0] }
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins sync_output/data_in_tx_0]]]} { connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins sync_output/data_in_tx_0]] [get_bd_pins $HDLCODERIPINST/dut_data_out_0_tx] [get_bd_pins sync_output/data_in_tx_0] } else { connect_bd_net [get_bd_pins $HDLCODERIPINST/dut_data_out_0_tx] [get_bd_pins sync_output/data_in_tx_0] }
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins sync_output/data_in_tx_1]]]} { connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins sync_output/data_in_tx_1]] [get_bd_pins $HDLCODERIPINST/dut_data_out_1_tx] [get_bd_pins sync_output/data_in_tx_1] } else { connect_bd_net [get_bd_pins $HDLCODERIPINST/dut_data_out_1_tx] [get_bd_pins sync_output/data_in_tx_1] }
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins sync_input/data_out_tx_0]]]} { connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins sync_input/data_out_tx_0]] [get_bd_pins $HDLCODERIPINST/dut_data_in_0_tx] [get_bd_pins sync_input/data_out_tx_0] } else { connect_bd_net [get_bd_pins $HDLCODERIPINST/dut_data_in_0_tx] [get_bd_pins sync_input/data_out_tx_0] }
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins sync_input/data_out_tx_1]]]} { connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins sync_input/data_out_tx_1]] [get_bd_pins $HDLCODERIPINST/dut_data_in_1_tx] [get_bd_pins sync_input/data_out_tx_1] } else { connect_bd_net [get_bd_pins $HDLCODERIPINST/dut_data_in_1_tx] [get_bd_pins sync_input/data_out_tx_1] }
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins axi_adrv9001/adc_1_clk]]]} { connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins axi_adrv9001/adc_1_clk]] [get_bd_pins $HDLCODERIPINST/IPCORE_CLK] [get_bd_pins axi_adrv9001/adc_1_clk] } else { connect_bd_net [get_bd_pins $HDLCODERIPINST/IPCORE_CLK] [get_bd_pins axi_adrv9001/adc_1_clk] }
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins rx_rstn_inverter/Res]]]} { connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins rx_rstn_inverter/Res]] [get_bd_pins $HDLCODERIPINST/IPCORE_RESETN] [get_bd_pins rx_rstn_inverter/Res] } else { connect_bd_net [get_bd_pins $HDLCODERIPINST/IPCORE_RESETN] [get_bd_pins rx_rstn_inverter/Res] }
add_files -norecurse {projects/jupiter_sdr/system_top.v}
puts "=== BYTE DMA path: connect DUT byte ports to the byte breakouts (June-proven wiring) ==="
# assert the byte reference-design blocks are present in the BD
foreach c {byte_breakout rx_byte_breakout tx_byte_dma rx_byte_dma byte_ctrl_gpio} {
  if {![llength [get_bd_cells -quiet $c]]} { puts "BYTE_FAIL: cell $c missing (wrong reference design?)"; exit 1 }
}
# CYCLIC-capable MODEM RX DMAC (DMAC_IDENTIFIED.md, tag
# archive/pre-cleanup-2026-09-09): rx_byte_dma is the
# modem byte-plane S2MM DMAC at 0x9D200000, instantiated by TransceiverToolbox
# matlab_processors.tcl:1061 with CONFIG.CYCLIC 0. Flip it to 1 here. Safe to
# bake: the axi_dmac register path is runtime-opt-in (up_dma_cyclic <=
# up_wdata[0] & DMA_CYCLIC), so the current host runs unchanged until FLAGS
# bit0 is set. Do NOT touch axi_adrv9001_rx1_dma (the ADI IQ-capture DMA at
# 0x44A30000 -- the prior cyclic patch's wrong target).
set_property CONFIG.CYCLIC 1 [get_bd_cells rx_byte_dma]
puts "CYCLIC_RXBYTE_OK rx_byte_dma CONFIG.CYCLIC=[get_property CONFIG.CYCLIC [get_bd_cells rx_byte_dma]]"
# proc: connect a DUT byte pin to a reference-design breakout pin (idempotent:
# extend the breakout pin's existing net if present, else create a new net)
proc bconn {inst dutpin blkpin} {
  set existing [get_bd_nets -quiet -of_objects [get_bd_pins $blkpin]]
  if {[llength $existing]} {
    connect_bd_net -net $existing [get_bd_pins $inst/$dutpin] [get_bd_pins $blkpin]
  } else {
    connect_bd_net [get_bd_pins $inst/$dutpin] [get_bd_pins $blkpin]
  }
}
# TX host->fabric (byte_breakout drives the DUT byte inputs; DUT ready back)
bconn $HDLCODERIPINST dut_byte_data_in  byte_breakout/byte_data
bconn $HDLCODERIPINST dut_byte_first_in byte_breakout/byte_first
bconn $HDLCODERIPINST dut_byte_valid_in byte_breakout/byte_valid
bconn $HDLCODERIPINST dut_byte_ready_out byte_breakout/byte_ready
# RX fabric->host (DUT byte outputs drive rx_byte_breakout; breakout ready back)
bconn $HDLCODERIPINST dut_byte_data_out  rx_byte_breakout/byte_data
bconn $HDLCODERIPINST dut_byte_last_out  rx_byte_breakout/byte_last
bconn $HDLCODERIPINST dut_byte_user_out  rx_byte_breakout/byte_user
bconn $HDLCODERIPINST dut_byte_valid_out rx_byte_breakout/byte_valid
bconn $HDLCODERIPINST dut_byte_ready_in  rx_byte_breakout/byte_ready
# verify every DUT byte port is now driven/connected
foreach dp {dut_byte_data_in dut_byte_first_in dut_byte_valid_in dut_byte_ready_out dut_byte_data_out dut_byte_last_out dut_byte_user_out dut_byte_valid_out dut_byte_ready_in} {
  if {![llength [get_bd_nets -quiet -of_objects [get_bd_pins $HDLCODERIPINST/$dp]]]} { puts "BYTE_FAIL: $dp unconnected"; exit 1 }
}
puts "BYTE_WIRE_OK"
# Workstream B (interrupt-driven DMA): wire the byte-DMA EOT IRQs into the PS
# pl_ps_irq concat. Guarded/idempotent + a no-op on the lean flow (the sourced
# script self-checks for the byte DMA cells), so the lean build is unaffected.
source [file join [file dirname [info script]] wire_byte_irqs.tcl]
update_compile_order -fileset sources_1
validate_bd_design
save_bd_design
add_files -fileset constrs_1 -norecurse projects/jupiter_sdr/system_constr.xdc
puts "=== STOCK TX WIRING (no gather) — verify sync_output drives the DAC ==="
foreach p {dac_1_data_i0 dac_1_data_q0 dac_1_data_i1 dac_1_data_q1} { if {![llength [get_bd_nets -quiet -of_objects [get_bd_pins axi_adrv9001/$p]]]} { puts "WIRE_FAIL: $p undriven"; exit 1 } }
puts "WIRE_OK"
if {[catch {validate_bd_design} verr]} { puts "VALIDATE_FAILED: $verr"; exit 1 }
puts "VALIDATE_OK"; save_bd_design
# DDS diet (2026-07-18): the P1D/P1E debug-class images from this kit never
# use the DAC DDS tone path; disabling it frees ~11k LUTs -- required since
# p1e pushed the ZU3EG past detail placement (5504 vs 5434 CLBs).  PHY LOs
# and the modem DMA TX path are unaffected.
set_property CONFIG.DDS_DISABLE 1 [get_bd_cells axi_adrv9001]
if {[catch {validate_bd_design} verr]} { puts "VALIDATE_FAILED(dds): $verr"; exit 1 }
puts "DDS_DIET_OK"; save_bd_design
set_property top system_top [current_fileset]
generate_target all [get_files system.bd]
update_compile_order -fileset sources_1
# --- END complete_byte_t8.tcl lines 1-137 ----------------------------------
puts "COMPLETE_BYTE_BD_DONE"
