# modem/rtl_sim -- the netlist simulation benches on the release path

Everything at this level is **live**: named by `build_image.sh` (gates stage), the
gate tables in `modem/gates/*.legs`, `modem/gates/run_gates.sh`, `make_sro_trees.sh`,
the two `run_netlist_gates.sh` (dev and prod), an instrument injector, or a test.
Study benches that are not on any of those paths live under `studies/` (provenance
only, not maintained) and the recorded result notes under `RESULTS/`. The split was
computed on 2026-09-16 as the transitive closure of file names reachable from those
callers; if you add a bench that a gate will call, it belongs here, otherwise in
`studies/<campaign>/`.

## How the gates reach this directory

* `modem/gates/run_gates.sh` exports `RTL=modem/rtl_sim` and `SCORE=modem/rtl_sim/sro_score`;
  the `.legs` rows run `$RTL/obj_byte_*_model_*/Vwrap_byte_sro_model ...` and
  `$SCORE/<scorer>.py`.
* `build_image.sh` (gates stage) runs `make_sro_trees.sh --from-regen <kit>` (writes the
  model gate tree `s1_rtl_model/` and the `wrap_byte_*_model.v` wrappers here), then
  `cd modem/rtl_sim && bash ./build_sro_<x>.sh` for the six Verilator objects
  (`obj_byte_*_model_*`), then the legs.
* `dev/run_netlist_gates.sh` and `prod/run_netlist_gates.sh` `cd "$KIT/rtl_sim"` (the
  kit's dereferenced copy of this directory) and use `wrap_byte.v`, `sim_byte.cpp`,
  `tb_tx_240k5.v`, `tx_words_golden.hex`. `prod/hdlsim/rtl_sim_overrides/{wrap_byte.v,sim_byte.cpp}`
  are installed over those two names in a prod kit (the `reg_` pin names).
* `build_hdl.sh` copies `qpsk_traffic_gen_v2.v`, `rx_seq_checker.v`, `cnt_mux32.v` into
  the kit root for the SEQ-BIST block-design instrument.
* Scripts here run with **cwd = this directory** and name wrappers and drivers by bare
  name (`verilator --cc wrap_byte_bs_model.v -y "$KIT/rtl_sim" --exe sim_sro.cpp`).
  Keep the live basenames stable.

## What is here

| Group | Files |
|---|---|
| gate build scripts (six live objects + census benches) | `build_sro_{bs,pad,rxfix4b,rxfix4d,rxfix4dr1,w1}.sh`, `build_w1_census.sh`, `build_bs_census_tb.sh`, `build_ddrcap2_sim.sh`, `build_iq_instruments.sh`, `build_replay_iq.sh` |
| tree maker / marker / lint | `make_sro_trees.sh`, `tree_marker.sh`, `txfix_lint.sh`, `txfix_gate_launch.sh` |
| Verilator wrappers | `wrap_byte.v` (S1B), `wrap_byte_sro*.v`, `wrap_byte_bs.v`, `wrap_byte_w1.v`, `wrap_byte_{bf2,dbgcap,ddrcap,dmac,dmac_rtl,lock,seqbist,taps,tgen}.v` |
| C++ drivers | `sim_byte.cpp` (S1B reference), `sim_sro.cpp`, `sim_w1.cpp`, `sim_w1_census.cpp`, `sim_stagewin.cpp`, `sim_ddrcap2.cpp`, `sim_byte_{dmac,dmac_rtl,iq,iq_cfclog,iq_perframe,seqbist,taps}.cpp`, `sim_burst_force.cpp`, `sim_jup.cpp` |
| RTL and testbenches | `tb_tx_240k5.v` (S1), `tb_pad.v`, `tb_bs_census.v`, `qpsk_traffic_gen{,_rx,_v2}.v`, `rx_seq_checker.v`, `rx_seam_checker.v`, `tx_seam_checker.v`, `cnt_mux32.v`, `burst_onset_det.v`, `rx_wrap_jup.v` |
| scorers | `sro_score/` (the legs' scorers), `txfix_gate_score.py`, `seqbist_gate_score.py`, `kick_seq.py` |
| goldens | `tx_words_golden.hex`, `rx_words_golden.hex`, `golden_taps/` |
| trees and objects (generated, gitignored) | `s1_rtl_*/` (gate trees; `s1_rtl_model/` is the current one), `obj_byte_*_model_*/` (the six live Verilator objects), `wrap_byte_*_model.v` |
| evidence and studies | `evidence/` (tracked gate logs), `tap_replay_study/`, `txplane_runs/`, `seqbist_unit/`, `dmac_src/` (ADI axi_dmac sources), `RESULTS/`, `studies/`, `tests/` |

## Outputs

Sim outputs (`*.txt *.csv *.bin *.vvp`, `obj_*/`, `*.log`) are gitignored. Gate runs write
into `SP2_WORK` (`/mnt/onetb/scratch/sp2_gates/work`), not here. On 2026-09-16 the
accumulated loose outputs of earlier campaigns were parked at
`/mnt/onetb/scratch/qpsk-build-trees/rtl_sim_untracked_2026-09-16/` and the stale
`obj_*` directories deleted (22 GB); the six live objects are rebuilt by `build_image.sh`
whenever the model tree changes.
