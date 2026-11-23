# modem/rtl_sim/studies -- retired simulation campaigns (provenance only)

These benches are not on any build or gate path (see `../README.md` for how that was
decided). They are kept so the evidence under `docs/evidence/`, `../RESULTS/` and
`../evidence/` reads against real code. **They are not maintained and are not rewritten
for this layout**: every script here ran from the flat `modem/rtl_sim/` of git
`f7fb7d68` (2026-09-16) and earlier, with cwd = `modem/rtl_sim` and sibling files by bare
name. To rerun one, check out that revision or copy the campaign's files back beside the
live wrappers. Old path `modem/rtl_sim/<file>` == `modem/rtl_sim/studies/<campaign>/<file>`.

| Campaign | What it was |
|---|---|
| `beat/` | 120-s beat hunt: long unforced ROM/BIST mode-1 loopback on the TXMARK netlist, heartbeat loop |
| `byte_variants/` | one-off `sim_byte_*` drivers and `wrap_byte_*` wrappers: dbg, dip, inject, lock, qtick, stall, tickfix, trace, hyp, fec, pc, padinj, dbgcap, ddrcap (v1), the RX-seam traffic gen v1, replay byte scorers |
| `cnt_mux/` | 8:1 and 16:1 counter selectors (the 32:1 one is live) |
| `corr_ring/` | COMB32 SRO reproduction: correlator magnitude dump and Rate_Handle ring dump around EMPTY edges |
| `dmac/` | TXMUX-era adversarial byte gates: MM2S accept/pop tracing, S2MM egress reproduction, `run_mm2s_gate.sh` (byte_ready lag assertion; superseded by the model matrix) |
| `e5fix/` | E5 fix localisation: per-stage taps driver and wrapper, scorer |
| `fir/` | REP_Tx FIR verification against MATLAB (`fir_verify.m`) and the FIR probe bench |
| `iq_tools/` | IQ stimulus preparation, dither, perturbation, gap marking, telemetry parsing, slack scoring |
| `misc/` | TX-side kick experiments (`sim_burst_force_tx*.cpp`) |
| `moddiag/` | modulation / phase / cadence replay diagnostics on the jupiter composite, AGC wrapper, phase-contract patch |
| `ratehandle_patches/` | netlist text patches used during the Rate_Handle anchor / occupancy / push-slave and serializer-anchor investigations |
| `replay/` | capture replay through the netlist: CE, inject, lock, v3 builds, `replay_gate_n2.sh`, quadrant-sweep and splice scorers |
| `rxfe/` | RX front-end image gate and its RRC / CFCAP positive controls |
| `rxloop/` | closed-loop RX front-end harness (Task 8d) |
| `seqbist/` | SEQ-BIST full-loop sim gate launcher and its run manifest |
| `sro_legacy/` | pre-model SRO builds (`build_sro.sh`, `build_sro_ram.sh`), the ENABLE-INJECT positive control, the R4E wrapper |
| `stagewin/` | stage-signature witness pre-build gate and falsifier dump |
| `taps/` | tapped FEC harness, golden-taps record writer, mu-stage taps |
| `tb/` | Icarus testbenches: IC shadow alignment, shadow-loop alignment, timing-wedge proof, TX checker/starve, RX seam checker |
| `tgen/` | in-fabric traffic generator benches (`tb_tgen*`), short-fill wedge reproduction, golden generator |
| `txfix_gate/` | TXFIX gate lane fixer, serializer-counter offset sweep and its scorer |
| `txint/` | TXCAP / TXINT instrument pre-build gates and the TXFIX force harness |
| `txplane/` | TX-plane frame generator, scorer and drivers (`../RESULTS/TXPLANE_SIM_RESULTS.md`) |
| `txrate/` | TX rate and kick simulations (F1/F2/F3 variants) |
