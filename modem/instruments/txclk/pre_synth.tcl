# pre_synth.tcl -- kit hook sourced by build_txfix.tcl (modem/vivado/txfix_build.tcl.tmpl) right
# after open_project and before generate_target. Copied to the kit root by build_hdl.sh step [6].
open_bd_design [get_files system.bd]
source [file join [file dirname [file normalize [info script]]] txclk_bd.tcl]
