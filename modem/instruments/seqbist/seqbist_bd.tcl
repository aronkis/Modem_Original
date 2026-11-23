# seqbist_bd.tcl -- GENERATED, DO NOT EDIT BY HAND.
#
# Regenerate with:
#   python3 modem/instruments/seqbist/patch_seqbist_tcl.py \
#       --emit-tcl modem/instruments/seqbist/seqbist_bd.tcl --lineage vendh --with-crc 1
#
# This is the SEQBIST_PATCH_V1 block that patch_seqbist_tcl.py inserts into a
# build kit's build_txfix.tcl, emitted as a standalone script so the sp3 `hdl`
# stage (modem/build_hdl.sh) can source it into the SAME Vivado session that
# already ran complete_byte_bd.tcl and ddrcap_bd.tcl.  See patch_seqbist_tcl.py's
# module docstring for the control-bit map, the slot map and the WITH_CRC
# escape hatch.
#
# LINEAGE, and why a fresh regen uses `vendh` (sp3 Task 11 finding).
# `--lineage` selects BD *STATE*, not the board.  `148` asserts the chain is
# ALREADY in system.bd (traffic_gen / rx_checker / tx_checker / tx_starve /
# cnt_mux16 / sel_slice / the three 0x9D4x GPIOs -- added incrementally by the
# resynth_probe*.tcl scripts and living only in that old kit's system.bd) and
# exits 1 if any of them is absent.  `vendh` asserts NONE of them are present
# and CREATES the whole chain.  A tree that has just been completed by
# complete_byte_bd.tcl has none of it, so `vendh` is the emitter that applies --
# even though the sp3 single image is the 148 board lineage (no TMR).  The
# SEQBIST_WIRE_OK token therefore reads `lineage=vendh`; that names the BD-state
# selector, not the board.
#
# CONTRACT: source this into a Vivado -mode batch session with vivado_prj.xpr
# already open, after update_ip_catalog/report_ip_status, with cwd =
# <tree>/hdl_prj_jupiter_composite/vivado_ip_prj, and with this file plus
# qpsk_traffic_gen_v2.v, rx_seq_checker.v and cnt_mux32.v in the SAME directory
# (`[file dirname [info script]]` is how the RTL is found -- build_hdl.sh
# installs all four at the kit root, as modem/instruments/seqbist/apply_seqbist.sh
# does for a kit).  Ends with validate_bd_design + save_bd_design and prints
# SEQBIST_WIRE_OK.

# ==== SEQBIST_PATCH_V1 (T0b, plan happy-bubbling-owl) =======================
# Inserted by modem/instruments/seqbist/patch_seqbist_tcl.py -- see that file's header for
# the control-bit map, the 148 fill_len[1:0] aliasing note and the slot map.
puts "=== SEQBIST: block-design patch (lineage=vendh) ==="
set HDLCODERIPINST TxRxCompo_ip_0
set _sb_kit [file dirname [info script]]
foreach _f {qpsk_traffic_gen_v2.v rx_seq_checker.v cnt_mux32.v} {
  set _p [file join $_sb_kit $_f]
  if {![file exists $_p]} { puts "SEQBIST_FAIL missing RTL source $_p"; exit 1 }
  add_files -norecurse $_p
}
update_compile_order -fileset sources_1
open_bd_design [get_files system.bd]

# extend the net already on $srcpin (if any) to $dstpin, else make a new net.
# Used everywhere so that re-wiring a pin whose old consumer was just deleted
# cannot leave a dangling net behind.
proc sb_conn {srcpin dstpin} {
  set n [get_bd_nets -quiet -of_objects [get_bd_pins $srcpin]]
  if {[llength $n]} {
    connect_bd_net -net [lindex $n 0] [get_bd_pins $dstpin]
  } else {
    connect_bd_net [get_bd_pins $srcpin] [get_bd_pins $dstpin]
  }
}
proc sb_require_driven {pins} {
  foreach p $pins {
    if {![llength [get_bd_pins -quiet $p]]} { puts "SEQBIST_FAIL pin $p does not exist"; exit 1 }
    if {![llength [get_bd_nets -quiet -of_objects [get_bd_pins $p]]]} {
      puts "SEQBIST_FAIL pin $p left floating"; exit 1
    }
  }
}
# rx_seq_checker's WITH_CRC parameter (RTL header "PARAMETER"): 1 = instantiate
# the CRC32 datapath, 0 = omit it (the compile-time escape hatch for a routed-WNS
# or utilisation failure; every tgen_mode stage works without it).  The default
# below is baked in by patch_seqbist_tcl.py --with-crc; the build driver can
# override it per run with env SEQBIST_WITH_CRC=0|1 without re-patching.
set _sb_with_crc 1
if {[info exists ::env(SEQBIST_WITH_CRC)] && [string is integer -strict $::env(SEQBIST_WITH_CRC)]} {
  set _sb_with_crc $::env(SEQBIST_WITH_CRC)
}
if {$_sb_with_crc != 0 && $_sb_with_crc != 1} { puts "SEQBIST_FAIL bad SEQBIST_WITH_CRC=$_sb_with_crc (want 0 or 1)"; exit 1 }
puts "SEQBIST_WITH_CRC $_sb_with_crc"
set _sb_slicedef [lindex [lsort -decreasing [get_ipdefs -filter {NAME == xlslice}]] 0]
if {$_sb_slicedef eq ""} { puts "SEQBIST_FAIL no xlslice ipdef"; exit 1 }
proc sb_bitslice {name srcpin bit} {
  global _sb_slicedef
  if {![llength [get_bd_cells -quiet $name]]} {
    create_bd_cell -type ip -vlnv $_sb_slicedef $name
  }
  set_property -dict [list CONFIG.DIN_WIDTH 32 CONFIG.DIN_FROM $bit CONFIG.DIN_TO $bit \
    CONFIG.DOUT_WIDTH 1] [get_bd_cells $name]
  sb_conn $srcpin $name/Din
}

foreach c {TxRxCompo_ip_0 axi_adrv9001 rx_rstn_inverter axi_hpm0_lpd_interconnect
           byte_breakout rx_byte_breakout byte_ctrl_gpio} {
  if {![llength [get_bd_cells -quiet $c]]} { puts "SEQBIST_FAIL(vendh) cell $c missing -- wrong lineage?"; exit 1 }
}
# Cross-lineage guard: probe cells that ONLY the 148 lineage has and that this
# patch never creates, so a RE-RUN of an already-patched vendh build tcl (which
# does have traffic_gen / rx_seq / cnt_mux / the GPIOs) is not mistaken for 148.
foreach c {rx_checker tx_checker tx_starve traffic_gen_rx} {
  if {[llength [get_bd_cells -quiet $c]]} { puts "SEQBIST_FAIL(vendh) cell $c present -- this is the 148 lineage, use --lineage 148"; exit 1 }
}
set _sb_gpiodef [lindex [lsort -decreasing [get_ipdefs -filter {NAME == axi_gpio}]] 0]
if {$_sb_gpiodef eq ""} { puts "SEQBIST_FAIL no axi_gpio ipdef"; exit 1 }
set _sb_constdef [lindex [lsort -decreasing [get_ipdefs -filter {NAME == xlconstant}]] 0]
if {$_sb_constdef eq ""} { puts "SEQBIST_FAIL no xlconstant ipdef"; exit 1 }
# the interconnect that already carries byte_ctrl_gpio (0x9D300000)
set _sb_bcintf [get_bd_intf_pins -quiet -of_objects \
  [get_bd_intf_nets -of_objects [get_bd_intf_pins byte_ctrl_gpio/S_AXI]] -filter {MODE == Master}]
set icell [get_bd_cells -of_objects $_sb_bcintf]
if {![llength $icell]} { puts "SEQBIST_FAIL(vendh) could not find byte_ctrl_gpio's interconnect"; exit 1 }
set _sb_nmi0 [get_property CONFIG.NUM_MI $icell]
set _sb_gpio_added 0
proc sb_gpio {name cfg offset} {
  global _sb_gpiodef icell _sb_gpio_added
  if {[llength [get_bd_cells -quiet $name]]} {
    puts "SEQBIST_GPIO_EXISTS $name offset=$offset (re-run: left as is)"
    return
  }
  create_bd_cell -type ip -vlnv $_sb_gpiodef $name
  set_property -dict $cfg [get_bd_cells $name]
  set nmi [get_property CONFIG.NUM_MI $icell]
  set_property CONFIG.NUM_MI [expr {$nmi + 1}] $icell
  set newm [format "M%02d_AXI" $nmi]
  connect_bd_intf_net [get_bd_intf_pins $icell/$newm] [get_bd_intf_pins $name/S_AXI]
  foreach p {ACLK ARESETN} sfx {s_axi_aclk s_axi_aresetn} {
    set src [get_bd_nets -of_objects [get_bd_pins byte_ctrl_gpio/$sfx]]
    connect_bd_net -net $src [get_bd_pins $name/$sfx]
    catch { connect_bd_net -net $src [get_bd_pins $icell/[format "M%02d_$p" $nmi]] }
    catch { connect_bd_net -net $src [get_bd_pins $icell/${newm}_[string tolower $p]] }
    catch { connect_bd_net -net $src [get_bd_pins $icell/[format "M%02d" $nmi]_[string tolower $p]] }
    # precedent: patch_tgen_tcl.py:55-60.  On this design the interconnect is a
    # smartconnect (NUM_CLKS 2, no per-master clock pins), so the three catches
    # above are expected to miss and master-to-clock association is by
    # connectivity -- but if a per-master ACLK pin DOES exist and stayed unwired,
    # say so rather than discovering it at validate_bd_design.
    if {$p eq "ACLK"} {
      set _ckpin [get_bd_pins -quiet $icell/[format "M%02d_ACLK" $nmi]]
      if {[llength $_ckpin] && ![llength [get_bd_nets -quiet -of_objects $_ckpin]]} {
        puts "SEQBIST_WARN: ${newm} clock unwired -- validate_bd_design will decide"
      }
    }
  }
  assign_bd_address -target_address_space /sys_ps8/Data \
    [get_bd_addr_segs $name/S_AXI/Reg] -offset $offset -range 64K
  incr _sb_gpio_added
  puts "SEQBIST_GPIO_OK $name offset=$offset m_port=$newm"
}
set _sb_gpio_out [list CONFIG.C_IS_DUAL 1 CONFIG.C_ALL_OUTPUTS 1 CONFIG.C_ALL_OUTPUTS_2 1 \
  CONFIG.C_GPIO_WIDTH 32 CONFIG.C_GPIO2_WIDTH 32 CONFIG.C_DOUT_DEFAULT 0x00000000 \
  CONFIG.C_DOUT_DEFAULT_2 0x00000000]
set _sb_gpio_in [list CONFIG.C_IS_DUAL 1 CONFIG.C_ALL_INPUTS 1 CONFIG.C_ALL_INPUTS_2 1 \
  CONFIG.C_GPIO_WIDTH 32 CONFIG.C_GPIO2_WIDTH 32]

# ---- (A) traffic_gen v2 at the TX byte pins + tgen_ctrl_gpio @0x9D400000 ----
sb_gpio tgen_ctrl_gpio $_sb_gpio_out 0x9D400000

# --8<-- SEQBIST_RETAP_CAPTURE_BEGIN
# Deleting the traffic_gen cell destroys every net it drives, silently orphaning
# EVERY OTHER consumer of those nets -- not just the snoops this patch knows
# about.  On the live 148 BD the dut_valid net has five consumers, one of them a
# system_ila probe that a hard-coded re-tap list would silently drop; and
# save_bd_design then persists the damage into the kit's own system.bd.
# So: enumerate every consumer of every net the cell drives BEFORE the delete and
# re-connect them all after.  This is inherently existence-guarded and
# future-proof -- a lineage with fewer consumers simply captures fewer pins.
set _sb_retap {}
if {[llength [get_bd_cells -quiet traffic_gen]]} {
  foreach _op {dut_data dut_valid dut_first host_ready} {
    set _n [get_bd_nets -quiet -of_objects [get_bd_pins -quiet traffic_gen/$_op]]
    if {![llength $_n]} { continue }
    foreach _pn [get_bd_pins -quiet -of_objects [lindex $_n 0]] {
      if {[lindex [split [string trimleft $_pn /] /] 0] eq "traffic_gen"} { continue }
      lappend _sb_retap $_op $_pn
    }
  }
  puts "SEQBIST_RETAP_CAPTURED n=[expr {[llength $_sb_retap] / 2}] pins=$_sb_retap"
  delete_bd_objs [get_bd_cells traffic_gen]
}
# --8<-- SEQBIST_RETAP_CAPTURE_END
create_bd_cell -type module -reference qpsk_traffic_gen_v2 traffic_gen
foreach {bo dut tg_h tg_d} {
  byte_data  dut_byte_data_in  host_data  dut_data
  byte_valid dut_byte_valid_in host_valid dut_valid
  byte_first dut_byte_first_in host_first dut_first
} {
  set n [get_bd_nets -quiet -of_objects [get_bd_pins byte_breakout/$bo]]
  if {[llength $n]} { delete_bd_objs $n }
  connect_bd_net [get_bd_pins byte_breakout/$bo] [get_bd_pins traffic_gen/$tg_h]
  connect_bd_net [get_bd_pins traffic_gen/$tg_d] [get_bd_pins $HDLCODERIPINST/$dut]
}
set n [get_bd_nets -quiet -of_objects [get_bd_pins byte_breakout/byte_ready]]
if {[llength $n]} { delete_bd_objs $n }
connect_bd_net [get_bd_pins traffic_gen/host_ready] [get_bd_pins byte_breakout/byte_ready]
connect_bd_net [get_bd_pins $HDLCODERIPINST/dut_byte_ready_out] [get_bd_pins traffic_gen/dut_ready]
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins axi_adrv9001/adc_1_clk]] [get_bd_pins traffic_gen/clk]
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins rx_rstn_inverter/Res]]   [get_bd_pins traffic_gen/resetn]
sb_conn tgen_ctrl_gpio/gpio_io_o  traffic_gen/ctrl
sb_conn tgen_ctrl_gpio/gpio2_io_o traffic_gen/gap
sb_require_driven {traffic_gen/host_data traffic_gen/host_valid traffic_gen/host_first
  traffic_gen/dut_ready traffic_gen/ctrl traffic_gen/gap traffic_gen/clk traffic_gen/resetn}
# --8<-- SEQBIST_RETAP_RESTORE_BEGIN
# Re-connect every captured consumer to the v2 cell's corresponding output net.
# Pins the splice above already put back on that same net are skipped; every
# captured pin is then asserted driven, so a lost consumer fails the build.
set _sb_retapped 0
foreach {_op _pn} $_sb_retap {
  set _dn  [get_bd_nets -quiet -of_objects [get_bd_pins traffic_gen/$_op]]
  set _pnn [get_bd_nets -quiet -of_objects [get_bd_pins $_pn]]
  if {[llength $_dn] && [llength $_pnn] && [lindex $_dn 0] eq [lindex $_pnn 0]} { continue }
  sb_conn traffic_gen/$_op $_pn
  incr _sb_retapped
}
foreach {_op _pn} $_sb_retap { sb_require_driven [list $_pn] }
puts "SEQBIST_RETAP_OK captured=[expr {[llength $_sb_retap] / 2}] reconnected=$_sb_retapped"
# --8<-- SEQBIST_RETAP_RESTORE_END
puts "SEQBIST_TGEN_V2_OK"

# ---- (B) tgen_rx_ctrl_gpio @0x9D410000 (control word + mux select) ---------
sb_gpio tgen_rx_ctrl_gpio $_sb_gpio_out 0x9D410000

if {[llength [get_bd_cells -quiet rx_seq]]} { delete_bd_objs [get_bd_cells rx_seq] }
create_bd_cell -type module -reference rx_seq_checker rx_seq
set_property CONFIG.WITH_CRC $_sb_with_crc [get_bd_cells rx_seq]
puts "SEQBIST_RXSEQ_WITH_CRC [get_property CONFIG.WITH_CRC [get_bd_cells rx_seq]]"
foreach {dut pin} {
  dut_byte_data_out  data
  dut_byte_valid_out valid
  dut_byte_user_out  user
  dut_byte_ready_in  ready
} {
  connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins $HDLCODERIPINST/$dut]] [get_bd_pins rx_seq/$pin]
}
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins axi_adrv9001/adc_1_clk]] [get_bd_pins rx_seq/clk]
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins rx_rstn_inverter/Res]]   [get_bd_pins rx_seq/rst_n]
# control bits out of tgen_rx_ctrl_gpio ch1 (0x9D410000): [3] freeze [4] en [5] tgen_mode
sb_bitslice sb_freeze_slice tgen_rx_ctrl_gpio/gpio_io_o 3
sb_bitslice sb_en_slice     tgen_rx_ctrl_gpio/gpio_io_o 4
sb_bitslice sb_mode_slice   tgen_rx_ctrl_gpio/gpio_io_o 5
sb_conn sb_freeze_slice/Dout rx_seq/freeze
sb_conn sb_en_slice/Dout     rx_seq/en
sb_conn sb_mode_slice/Dout   rx_seq/tgen_mode
sb_require_driven {rx_seq/data rx_seq/valid rx_seq/user rx_seq/ready rx_seq/clk rx_seq/rst_n
  rx_seq/en rx_seq/freeze rx_seq/tgen_mode}
puts "SEQBIST_RXSEQ_OK"

# ---- (C) cnt_mux32 + tgen_rx_wit_gpio @0x9D450000 --------------------------
if {![llength [get_bd_cells -quiet sb_zero32]]} { create_bd_cell -type ip -vlnv $_sb_constdef sb_zero32 }
set_property -dict [list CONFIG.CONST_WIDTH 32 CONFIG.CONST_VAL 0] [get_bd_cells sb_zero32]
if {![llength [get_bd_cells -quiet sel_slice]]} { create_bd_cell -type ip -vlnv $_sb_slicedef sel_slice }
set_property -dict [list CONFIG.DIN_WIDTH 32 CONFIG.DIN_FROM 31 CONFIG.DIN_TO 27 \
  CONFIG.DOUT_WIDTH 5] [get_bd_cells sel_slice]
sb_conn tgen_rx_ctrl_gpio/gpio2_io_o sel_slice/Din
if {[llength [get_bd_cells -quiet cnt_mux]]} { delete_bd_objs [get_bd_cells cnt_mux] }
create_bd_cell -type module -reference cnt_mux32 cnt_mux
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins axi_adrv9001/adc_1_clk]] [get_bd_pins cnt_mux/clk]
sb_conn sel_slice/Dout cnt_mux/sel
sb_gpio tgen_rx_wit_gpio $_sb_gpio_in 0x9D450000
sb_conn sb_zero32/dout tgen_rx_wit_gpio/gpio_io_i
connect_bd_net [get_bd_pins cnt_mux/q] [get_bd_pins tgen_rx_wit_gpio/gpio2_io_i]
# slots 0-15: no traffic_gen_rx / rx_checker / tx_starve on this lineage -> 0
for {set i 0} {$i < 16} {incr i} { sb_conn sb_zero32/dout cnt_mux/c$i }
# slots 16-31: rx_seq_checker cnt0..cnt15 (Task-1 interface contract)
sb_conn rx_seq/cnt0  cnt_mux/c16
sb_conn rx_seq/cnt1  cnt_mux/c17
sb_conn rx_seq/cnt2  cnt_mux/c18
sb_conn rx_seq/cnt3  cnt_mux/c19
sb_conn rx_seq/cnt4  cnt_mux/c20
sb_conn rx_seq/cnt5  cnt_mux/c21
sb_conn rx_seq/cnt6  cnt_mux/c22
sb_conn rx_seq/cnt7  cnt_mux/c23
sb_conn rx_seq/cnt8  cnt_mux/c24
sb_conn rx_seq/cnt9  cnt_mux/c25
sb_conn rx_seq/cnt10 cnt_mux/c26
sb_conn rx_seq/cnt11 cnt_mux/c27
sb_conn rx_seq/cnt12 cnt_mux/c28
sb_conn rx_seq/cnt13 cnt_mux/c29
sb_conn rx_seq/cnt14 cnt_mux/c30
sb_conn rx_seq/cnt15 cnt_mux/c31

set _sb_nmi1 [get_property CONFIG.NUM_MI $icell]
if {$_sb_nmi1 != $_sb_nmi0 + $_sb_gpio_added} { puts "SEQBIST_FAIL(vendh) NUM_MI $_sb_nmi0 -> $_sb_nmi1 (expected +$_sb_gpio_added new axi_gpio slaves)"; exit 1 }
if {$_sb_gpio_added != 0 && $_sb_gpio_added != 3} { puts "SEQBIST_FAIL(vendh) partial GPIO set: $_sb_gpio_added of 3 created"; exit 1 }
puts "SEQBIST_CNTMUX32_OK num_mi=$_sb_nmi1"

validate_bd_design
save_bd_design
puts "SEQBIST_WIRE_OK lineage=vendh"
# ==== end SEQBIST_PATCH_V1 ==================================================
