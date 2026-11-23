# pre_synth.tcl -- kit hook sourced by build_txfix.tcl (modem/vivado/txfix_build.tcl.tmpl) right
# after open_project and before generate_target. Copied into the kit root beside build_txfix.tcl
# together with txcdc_bd.tcl + tx_cdc_fifo.v (build_hdl.sh [5d] or by hand for a rebuild).
open_bd_design [get_files system.bd]
source [file join [file dirname [file normalize [info script]]] txcdc_bd.tcl]
