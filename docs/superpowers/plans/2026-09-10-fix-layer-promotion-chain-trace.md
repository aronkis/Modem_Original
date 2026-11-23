# sp2 chain trace (condensed from the read-only research pass, 2026-09-10)

Repo at dd118d0e. Build trees: /mnt/onetb/scratch/qpsk-build-trees (local), hdl-dev-2:~/qpsk-builds (remote, Vivado /opt/Xilinx/2025.1, 8 cores, 47 GB free).
Remote kits present: jupiter_byte_{ddrcap2,rxfixpad,rxfixr4dr1,rxfixr4b,rxfixw1,rxfixbs,seqbist,seqbist146,txfixF2,txfixF3,txfixF3vendh,...}_build (2 GB each, stamps present).
Local: jupiter_byte_rxfixpad_build whole; harvest tarballs for all 62 trees (VARIANT stamps were NOT captured by the harvest filter).

## 1. Chain (both images share everything up to the rxfix stage)

model -> netlist: modem/build_byte_image.sh:24-28 (MATLAB build_variant_byte -> HDL Coder IP core), :45-46 (complete_byte_t8.tcl -> synth/impl/bootgen). Lean wrapper modem/build_lean_image.sh:19-26, dual-DMA :39-42.
Overlays: modem/assemble_jupiter_240k5_byte.m lines 51-201 (rate_240k, ss8_fix, timing_hardening, agc_gain_range, msggen_rom_k5, fec_insert_rxonly_k5, fec_counters, fec_skipreg, fec_capture, fec_nodescr, taps_240k5, rx_framing_k5, adc_forensic, iq_debug_tap, movsum_hardening, loop_tune_axi, movsum_tmr, canary*, ...). QPSK_LEAN=1 (build_lean_image.sh:5) drops instrument overlays.
HDL Coder: modem/hdlworkflow_loopback.m:551 RunTaskGenerateRTLCodeAndIPCore, :597 runWorkflow; ProjectFolder hdl_prj_jupiter_composite (:26,:545), hdlsrc (:34), part xczu3eg-sfva625-2-e (:31).

Kit lineage (archived jupiter_byte_txfix_kit.sh, tag archive/pre-cleanup-2026-09-09):
  root kit = jupiter_byte_ddrcap2_build (DDRCAP-v2 tree; :5,:67)
  -> jupiter_byte_txfix_kit.sh F3 -> jupiter_byte_txfixF3_build; installs ops/skidfix/txfix_build.{sh,tcl}.tmpl as build_txfix.{sh,tcl}; runs txfix_inject.py <composite> F3 (:116-119,:134); stamp TXFIX_VARIANT = "F3\n07f3badc..."
  -> ops/skidfix/jupiter_byte_seqbist_kit.sh 148: SRC txfixF3 -> jupiter_byte_seqbist_build (:40); copies modem/rtl_sim/{qpsk_traffic_gen_v2.v,rx_seq_checker.v,cnt_mux32.v} (:54,:103-106); python3 ops/skidfix/patch_seqbist_tcl.py <kit> --lineage 148 --with-crc 1 (:110-112); widens build_txfix.sh kit-name guard (:117-124); stamp SEQBIST_VARIANT (:148)
  -> ops/skidfix/jupiter_byte_rxfix_kit.sh 148 with RXFIX_VARIANTS:
       148: 'W1 R4B BS PAD' -> KIT_SUFFIX=pad, READ_WORDS 0x214..0x258 (17 words) (:75,:79)
       146: 'W1 R4D R1'     -> KIT_SUFFIX=r4dr1, READ_WORDS 0x214..0x238 (10 words) (:63); BOARD arg is 148 for BOTH (:80 refuses 146 -> "148-lineage image")
     injector provenance asserted (:106-113), rsync copy (:124-136), injection loop python3 ops/skidfix/rxfix_inject.py <kit> <V> in order (:139-144; ordering load-bearing :31-32, rxfix_inject.py:4302-4305, :69-75), witness assertions (:149-152), marker present in exactly 3 loose copies + both TxRxCompo_ip_v1_0.zip (:176-203), variant-specific asserts R4B :251-269 / BS :271-288 / PAD :290-298 / R4D :220-233 / R1 :239-249, carry-over asserts (:210-217), guard widen (:301-308), stamp RXFIX_VARIANT (:312-314).
  Build launch: <kit>/build_txfix.sh (from tmpl): guard :33-36, remote disk >=25 GB :46-54, concurrency :56-63, rsync to hdl-dev-2:~/qpsk-builds/<kit> :66-78, systemd-run --user + timeout 14400 vivado -mode batch -source build_txfix.tcl :90-104; env JOBS, IMPL_STRATEGY, VARIANT, SEQBIST_WITH_CRC. `--dry` is POSITIONAL (memory). PATH=/opt/Xilinx/2025.1/Vivado/bin.
  Vivado tcl (build_txfix.tcl): open_project + update_ip_catalog -rebuild -scan_changes :23-24; SEQBIST_PATCH_V1 block :26-252; generate_target/reset_run :254-258; synth :259-260; pre-impl `source timing_gate.tcl` :261; IMPL_STRATEGY=explore :263-271; impl+bitstream :272-273; routed-WNS gate :275-277 (TXFIX_ROUTED_WNS, exit 1 if <0); bootgen -arch zynqmp -image zynq.bif -o BOOT.BIN -w :281; md5 :282-286.
  As-built 148: 2 h 18; TXFIX_ROUTED_WNS 0.105; MODEM_CLK_WNS clock=axi_adrv9001_adc_1_clk wns=0.105 (docs/evidence/comb/FWD_CRC_REGRESSION_0907.md:4874-4882). 146: routed modem WNS +0.620 (images/README.md:13). Both IMPL_STRATEGY=explore.
  Differences 148 vs 146: variant list; kit suffix; READ_WORDS; files patched (+ByteSerializer/ByteRxFifo vs +Preamble_Detector); injector commit (f75d5223 vs 10b27b7); postplace_report.tcl hook present only in 146 tree; flash rail (flash_148_txfix.sh gates on 148; flash_146_txfix.sh :108-113 requires 148 live first, health measured on 148).
  Flash: ops/skidfix/txfix_flash_go.sh -> flash_148_txfix.sh (FLASH_MD5/FLASH_BAK/FLASH_TAG :42; two-pass gate arm148_mode1.sh :74-76,:108-109); ops/skidfix/txfix_flash146_go.sh -> flash_146_txfix.sh (:56-61 md5 regex + bank path images/BOOT.BIN.146.$TAG.$EXP; :103-107 A0 rollback-bank gate; :153 health fsync>=1100 AND wcnt>=1100).

Re-entry into Vivado is NOT via resynth_*.tcl (those are instrument lineages): injectors patch TxRxCompo_ip_src_<Module>.v + TxRxCompo_ip{,_dut,_axi_lite,_addr_decoder}.v in hdlsrc/, ipcore/, vivado_ip_prj/ipcore/ and both TxRxCompo_ip_v1_0.zip (rxfix_inject.py:4345-4409, :4457-4471); build_txfix.tcl re-reads the IP with update_ip_catalog.

## 2. Registers
fixctl 0x208 write-only (ms_regmap.c:64). Bits: 0 enContract, 1 enSerAnchor, 2 enGridPace, 3 enSlack (PD FIFO push_on_full), 4 w1_freeze (level; rxfix_inject.py:1536), 8-11 stageSel (stagesig), 12 TXCAP mux, 13 DBGCAP/DEMODCAP mux, 14-17/20/21 other instrument selects.
Read window (byte addr / AXI word / name / layout / reader ms_regmap.c line):
0x20C/0x83 viol_count (DBGCAP-owned; W1 must not disturb) :65; 0x210/0x84 viol_latch :66;
0x214/0x85 W1_WITA [15:10]occTrue [9:5]pushPtr [4:0]popPtr :67; 0x218/0x86 W1_WITB [31:16]push_on_full [15:0]pop_on_empty (16-bit wrap) :68;
0x21C..0x230 /0x87..0x8C W1_CNT_{SS,RH,CFC,CS,PD,PC} :69-74;
0x234/0x8D r4_wit {locked[31],skips[30:15],opens[14:0]} :75 (IMGKEY); 0x238/0x8E r4_extras {16'b0,extras} :76 (IMGKEY);
0x23C..0x258 /0x8F..0x96 BS census bs_words,bs_starts,bs_push,bs_pop,bs_drop,bs_marks{lasts[31:16],markpush[15:0]},bs_evt{trunc_last,trunc_min,trunc_max,dropmax},bs_cnt{trunc[31:16],q24[15:8]} :77-84 (docs/evidence/rxfix/W1_REGMAP.md:423-430).
Decode: w1_hit 0x85..0x8C (rxfix_inject.py:1647-1650); r4b_hit ==0x8D; bs_hit >=0x8F with bs_idx = addr[2:0]-7 (kit :280-284 asserts; missing -7 = silent rotation).
R4D word swap: deployed 146 (9acbe2ebe1db) returns 0x234/0x238 SWAPPED (rxfix_inject.py:2314-2318,:2786-2787); fixed in injector (Task 33, :2788 r4d_idx = (addr==8'h8E)); W1_REGMAP.md:315 "6-R4D.2 silicon exception"; readers key on md5: ms_r4d_order() MS_R4D_SWAPPED_MD5 (ms_regmap.c:112-130), fail-closed 0 on unknown md5. A rebuild from the current injector yields canonical order + new md5 -> ms_r4d_order returns canonical automatically. host/qpsk_hw.h has NO 0x2xx defines; the window is owned by ms_regmap.c.

## 3. Sim gates (keep = covers deployed content)
KEEP: modem/rtl_sim/build_sro_w1.sh (W1; base vs W1 byte-identical at 0/-10 ppm, push_on_full 0), build_sro_rxfix4b.sh (R4B; gates G4-G17 in docs/evidence/rxfix/RXFIX_R4B_SIM_GATE.md:95-111), build_sro_rxfix4d.sh (R4D; J rows), build_sro_rxfix4dr1.sh (R4D+R1; legs p000/p10/m10/tm10 + diag m40/m10c/lol; pdOcc pinned 12333; +10 ppm loss 0.00 %), build_sro_bs.sh (BS; identity legs byte-identical incl. banked b_p000_frames.txt), build_sro_pad.sh (PAD; 418 frames x 191 words, 0 orphans; p000 byte-identical), seqbist_unit/run_unit.sh (icarus tbs), ops/skidfix/test_rxfix_inject.py, test_ddrcap_inject.py.
DROP: build_sro_rxfix.sh, _rxfix2, _rxfix3, _rxfix3s, _rxfix4, _rxfix4e + RXFIX_R3S/R4/R4C/R4E_SIM_GATE.md (rejected variants). TXFIX gate family (txfix_gate_launch.sh/score.py, evidence/txfix_gate_runs.txt) selected F3 and predates both images: keep as evidence, not as a build stage.
All SRO gates need the untracked trees modem/rtl_sim/s1_rtl and s1_rtl_{rxfix_W1,rxfix_R4B,rxfix_R4D,rxfix_R4DR1,bs,bs_base,bs_gen,pad} (locally only modem/s1_rtl/hdlsrc exists); each script asserts its tree (e.g. build_sro_pad.sh:7). Trees are the pristine netlist + one injected copy; regenerable from the netlist + injector.

## 4. Timing gate — three layers
1) modem/timing_gate.tcl pre-impl post-synth, modem-scoped, floor -1.0 ns (pessimism floor). 2) build_txfix.tcl:275-277 routed overall WNS (vendor IDELAYCTRL path; build-blocking only). 3) AUTHORITATIVE: post-route intra-clock row axi_adrv9001_adc_1_clk in impl_1/system_top_timing_summary_routed.rpt (memory txfix-wns-gate-trap says *_postroute_physopted.rpt), printed as MODEM_CLK_WNS by modem_wns.py — WHICH DOES NOT EXIST ANYWHERE (must be re-authored). Ladder: W1 +0.169, SEQ-BIST +0.227, R4B +0.437, R4D+R1 +0.620, PAD +0.105.

## 5. Missing from a fresh clone
jupiter_byte_txfix_kit.sh + _fetch.sh (tag only); jupiter_byte_ddrcap2_build, txfixF3_build, seqbist_build (harvest tarballs locally; whole trees on hdl-dev-2); instantiated build_txfix.{sh,tcl} incl. SEQBIST patch (generated); modem_wns.py (nowhere); postplace_report.tcl (146 tree; generator two_jup/rxfix/add_postplace_report.sh on tag); arm148_mode1.sh (called by flash_148_txfix.sh:75, MISSING from HEAD); flash_146_txfix.sh:62 ROLLBACK_BANK default points at a deleted dir (override needed); s1_rtl* sim trees (untracked).
Tracked and sufficient: ops/skidfix/jupiter_byte_{seqbist,rxfix}_kit.sh, rxfix_inject.py, txfix_inject.py, patch_seqbist_tcl.py, txfix_build.{sh,tcl}.tmpl, modem/timing_gate.tcl, complete_byte_t8.tcl, build_byte_image.sh, run_full_gates_t8.sh, assemble_jupiter_240k5_byte.m, hdlworkflow_loopback.m, commhdlQPSKTxRxLoopback.slx, build_sro_*.sh, sim_sro.cpp, wrap_byte_sro4d.v, pad_patch.py, flash_1{46,48}_txfix.sh.

## 6. Instruments (ops/skidfix/*_inject.py)
ddrcap (raw IQ+markers, reuses 0x10C mux); ddrcap2 (joint timing capture; fixctl[12]/[13] muxes; ROOT KIT of both deployed images — carried unchanged); dbgcap (per-stage decision capture; owns 0x20C/0x210 -> why W1 starts at 0x214); demodcap (after dbgcap); rxfe (after dbgcap+demodcap); stagesig/stagesig3 (abandoned); txcap (fixctl[12], after dbgcap); txint (FINAL lineage 0f203cf887d3). Only ddrcap2 is on the critical path, as an ancestor tree, not as a build step.
