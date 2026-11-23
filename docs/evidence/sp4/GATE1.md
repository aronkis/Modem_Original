# sp4 (f3072, 2 sps) Gate 1: the model matrix on the f3072 stimulus bank

Plan: `docs/superpowers/plans/2026-09-13-2sps-rung.md` Task 7. Branch `2sps-rung-2026-09-18`.
This file records the four Gate 1 runs of 2026-09-19..22: runs 1-3 each exposed defects in the
sps-2 model and in the benches (fixed in `cf738974`, `80982106`, `22aba6e6`), run 4 is the one the
bank and the reference table are cut from. Every number below has its command and denominator.

## 1. The f3072 stimulus bank

Directory `/mnt/onetb/scratch/qpsk-build-trees/sro_sim_f3072` (scratch; sha256 list in
`modem/gates/bank_f3072.sha256`). Geometry from `modem/rtl_sim/geometry.h` / `sro_score/geometry.py`:
49268 samples per air frame (24634 slots x 2 sps), 3056-byte host packet, 382 delivered words.

| file | recipe | samples / frames |
|---|---|---|
| `tx432.iq` | `Vwrap_byte_sro_model txcap 21086704` (ROM source, frame-periodic) | 21086704 / 428 |
| `tx432n.iq` | `Vwrap_byte_sro_model txcap2 21283776 tx432n.iq 20000 3044` (TGEN v2 on the byte plane, incrementing seq, gap 20000 clks, fill 3044) | 21283776 / 432, emitted=432 seq=432 repeat_frames=0 |
| `n_p000 n_p2p5 n_m2p5 n_p10 n_m10` | `gen_sro_stim.py tx432n.iq <out> --ppm {0,2.5,-2.5,10,-10} --no-tile --frames 428` | 21086704 / 428 each |
| `s_p000`, `s_m10` | `gen_sro_stim.py tx432.iq ... --ppm 0 --frames 165` / `--ppm -10 --frames 210` (tiled) | 8129220 / 165, 10346280 / 210 |

The non-repeating capture follows the sps-4 recipe exactly (gap 20000 = one fresh packet per air
frame, capacity-bound). A first attempt with gap 95050 (from a wrong reading of the f1536 recipe)
produced a packet only every OTHER frame (emitted=214 of 428) and was discarded: the delivery rows
(`T7_NAIR=428`, `G1_ident` common seq >= 420, `nrxw_*`) assume one packet per frame.

The objects are the six `obj_byte_*_model_*` Verilator builds of `modem/rtl_sim/s1_rtl_model`
(`make_sro_trees.sh --from-regen <kit>`), the kit being the dev-tree hdl stage of `build_image.sh
--tag sp4 --tree dev --stop-after hdl` (`GATE0_REGEN.md`).

## 2. Run 1 (regen 1, 2026-09-19 21:15): LOSS=100 % everywhere -- two causes

Work `/mnt/onetb/scratch/sp2_gates/work_sp4/model_matrix`, log `sro_sim_f3072/gate1_run1.log`. The
four R4B run legs passed (1.5 h each), every `_t7` scorer said `OK=0 CORRUPT=421 LOSS=100.00%`.

**2a. Bench: the per-frame byte cap.** `sim_sro.cpp` accumulated at most 1600 bytes per frame (an
f1536 literal that `test_sim_geometry.py` did not list), so a 3056-byte packet never reached
`GEOM_PKT_BYTES` and scored `nbad=-1` = corrupt. The packets were in fact bit-exact: the FNV-1a
hash the bench logs per delivery (`*_deliv.txt`) equals the hash of the traffic generator's expected
content (`t7_expect`, ported to Python) for **423 of 423** magic packets of `m0_n_p000`. Fixed
(`GEOM_PKT_BYTES`; `1600` added to the retired-literal regex).

**2b. Model: a 382-word all-zero packet every frame.** 850 deliveries for 428 frames; every second
delivery hashes to the all-zero 3056-byte packet (`0ab3e285`) and follows the real one by 754
samples. Cause: the RxAlign bound delivers 24535 info bits per frame, WPP=382 consumes 24448, and
the 87 spare bits complete a **383rd 64-bit word**; the next `start` found `wordCnt=1` and the F4 pad
logic (`rxfix_pad_overlay`, "a start with 1..WPP-1 words schedules WPP-wordCnt fillers") emitted
381 zero words + that word = a filler packet. At k5 (60 spare bits) and f1536 (23) no full word can
complete, which is why it never showed. Fix: `qpskByteSerializer` **done latch** (bits after the
packet's last word are ignored until the next start), unit test
`TestByteHelpersK5/serializerDiscardsBitsAfterLastWord`; note beside the bound in `frame_config_k5`.
Confirmed on the regen-2 tree by the loopback smoke (`sim_lb.cpp`, TGEN loopback, 12 frames:
zero packets 12 -> 2 start-up truncations) and by the Simulink byte gate (Run A rx oracle true,
`rxwords=2674` = 7 x 382).

## 3. Run 2 (regen 2 = serializer fix, 2026-09-19 23:44 .. 09-20 05:02)

Work `sp2_gates/work_sp4b/model_matrix`, log `gate1_run2.log`; 33 legs PASS. Run-leg losses
(`score_t7.py`, `T7_NAIR=428`, lost frames in the denominator):

| leg | loss | leg | loss |
|---|---|---|---|
| m0_n_p000 (R4B) | 0.00 % (421/421) | m20_n_p000 (R4DR1) | 0.00 % (421/421) |
| m0_n_p2p5 | 0.24 % (420/421) | m20_n_m10 | 0.00 % (420/420) |
| m0_n_m2p5 | 0.00 % (420/420) | m20_n_p10 | **30.57 %** (293/422) |
| m0_n_m10 | 0.00 % (420/420) | | |
| m0_n_p10 | t7_ok=333 t7_bad=18 t7_nomagic=76 of 428 (scorer refused: corrupt seq field) | | |

**3a. R4B at +10 ppm (structural).** Pushes exceed pops by 0.246 symbols per frame (+10 ppm of 24634),
R4B has no full-edge branch, the 32-deep ring fills 1 entry per 4 frames and overflows from frame
~112 (`rh_push_on_full=79`). The sps-4 reference for this leg is 6.65 % with the ring filling at half
the rate (12333 symbols per frame); at f3072 it is ~22 %. Same mechanism, twice the fill rate. The
image must run the R4D branch (`sro_sign=1`) on both boards at this rung (Task 11 note).

**3b. R4DR1 at +10 ppm: every extra pop killed a frame.** The extras fire as designed (87, ring held at
occupancy 23-24) but the lost packets follow each extra by two frames, one for one. Probe
(`extraprobe`, `r4Extras` tap): the extra fires ~36 samples after `taSync`, i.e. ~94 symbols INTO the
data of the frame entering the ring, because the window opens at `pcEnd` and the ring -> Packet
Controller pipeline is ~94 symbols long at sps 2. A delay sweep of the window (model tree patched to
open N nominal pops after pcEnd, `n_p10`, 130 frames, 14 extras, R4DR1):

| N | 0 | 30 | 100 | 300 | 1000 | 3000 | 24500 | **24540** | 24560 | 24580 | 24600 | 24620 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| frames lost (of 128, 2 start-up excluded) | 20 | 18 | 18 | 21 | 21 | 20 | 3 | **0** | 17 | 3 | 21 | 20 |

The harmless zone is SlotsPerFrame - [84..119] pops after pcEnd = the 24 filler + 26 preamble symbols
of the frame entering the ring. Fix: `rxfix_steer_overlay` opens the window `SlotsPerFrame - 100`
nominal pops after pcEnd at sps 2 (`PCEND_LEAD_POPS`; 0 = unchanged f1536 behaviour at sps 4/8).

**3c. S1B netlist gate (`run_netlist_gates.sh` stage 4) at f3072.** Never run before at this rung (the
`S1B_GATE.txt` inside a kit is a stale copy of the dev tree's file). It failed on both the pristine and
the model tree with all-zero deliveries and `cap_out=0`, while the same RTL decoded TGEN packets
bit-exact in loopback. Two causes: (i) bench -- `sim_byte.cpp` sampled `byte_ready` one cycle after the
posedge and applied it to the next word; benign at f1536 (ready pulses are long), at f3072 the
unaligned discard runs one word per beat and every word mis-handshaked. Fixed to the same-cycle
handshake `qpsk_traffic_gen_v2.v` uses -> rot=0 PASS (`cap_out 0x04922282`, 769 pops per frame from
frame 2). (ii) model -- rot=17 still never aligned: the strict shifter sees the buffer's registered head
one step old and its pop lands one step late; discarding one word per beat, the first-marked word is
in view exactly when the previous discard eats it (trace: 1535 marked heads seen, 0 latched). At sps 4
the shifter steps every other beat and the race cannot occur. Fix: `discardGap` (one discard per two
enabled steps) in `qpskByteBitShifterStrict`, passed as `cfg.Sps == 2` by `byte_tx_overlay_k5`; unit
test `strictShifterRealignsWithLatePops` models the registered head + late pop.

**3d. Bench taps and oracles.** `pdOcc` wrapper tap was 14 bits (24634 read as 8250; `S4_p10_pdocc`);
the air oracle of `sim_byte_gate_k5` (dev + prod) and `s1b_analyze_byte` used a 13-symbol Barker
template and started a bogus frame at the second half of the 26-symbol preamble every other frame
(`perFrameErr = [24587 0 24587 0 ...]`, RESULT FAIL with rx and BIST oracles true). Both match the
full configured preamble now.

## 4. Run 3 (regen 3 = serializer latch + steering lead; 2026-09-21 19:07 .. 09-22)

Work `sp2_gates/work_sp4c/model_matrix`, log `gate1_run3.log`. Regen 3 did NOT carry the shifter
discard gap: `framestat_overlay` rewrites the ByteBitShifter chart for its underrun witness from its
own six-argument template and dropped the seventh argument (fixed in `80982106`, regen 4 below). The
RX legs are unaffected by that (the shifter is TX ingress, idle in `rx` mode), so run 3 is the test of
the serializer latch and the steering lead:

| leg | run 2 | run 3 | extras / skips (run 3) |
|---|---|---|---|
| m20_n_p10 (R4DR1, +10 ppm) | **30.57 %** (293/422) | **0.00 % (422/422)** | 87 extras, ring occupancy 23, `pdOcc_end=24634` |
| m20_n_p2p5 | -- | 0.00 % (421/421) | 10 extras |
| m20_n_p000 / m20_n_m2p5 | 0.00 % | 0.00 % | 8 / -- skips |
| m0_n_p000 / m0_n_m2p5 / m0_n_m10 (R4B) | 0.00 % | 0.00 % | 8 / 32 / -- skips |
| m0_n_p2p5 (R4B) | 0.24 % (420/421) | 0.24 % (420/421) | ring overflow x2 (`push_on_full=2`) |
| m0_n_p10 (R4B) | t7_ok 333 / 428 | t7_ok 333 / 428 | structural: no full-edge branch, `push_on_full=79` |

The skip-window witness (`t12b_window.py`, made lead-aware in `22aba6e6`): 8 of 8 skips at RTL slot 1 /
recount slot 24536, i.e. `SlotsPerFrame-100+2` pops after pcEnd, all at tref 24408 = 226 symbols
before the air-frame boundary (`STEER_TREF_OFF`), so the window sits in the filler + preamble as
intended. The Simulink byte gate with the full-preamble oracle passes on this kit (runs A, C, D:
air golden from frame 3 / 1, BIST 0x04922282, byte-rx packets golden).

Rows failing in run 3 for want of a bank or of an f3072 pin (re-pinned from run 4): `G1_ident`,
`G4_prearm`, `repro_p000*`, `census_grid`, `merge_control`, `*_k1536` (bank); `gateA_p000` /
`gateA_m10` (W1 == base deliveries identical, 164 / 209 packets; only the f1536 md5 pin fails),
`edge_m10`, `S1_p000_D2` (t7_ok 424), `S5_p10_ring` (87 extras at twice the f1536 fill rate),
`G3_ring` (occupancy range), `G2_skips` (fixed scorer), `m0_n_p10_t7` (see 3a).

## 5. Run 4 (regen 4 = all fixes; the bank and the reference table)

Regen 4 (`regen_sp4d`, 2026-09-21 19:34): RTL delta vs regen 3 = `ByteBitShifter.v` only (the
discard gap now present). Gate 0 on this kit, before the matrix:

* **S1B** (`run_netlist_gates.sh` stage 4 recipe, `sim_byte.cpp` same-cycle handshake, f3072 goldens
  769 / 382 words): rot=0 AND rot=17 PASS on the pristine composite RTL and on the model tree
  (`cap_out 0x04922282`, 21 packets, 8021 = 21 x 382 rx words, no filler packets; the rotated source
  realigns within the first frame: 753 discards, marked word at the head on the second start).
* Loopback smoke (`sim_lb.cpp`, TGEN, 12 frames): 9 / 9 packets after start-up, 2 start-up truncations.
* **Simulink byte gate** (`sim_byte_gate_k5.m`, full-preamble oracle, T = 9 frames): runs A (golden
  info), C (alternate pad discriminator) and D (ROM regression) PASS -- air golden from frame 3 / 3 / 1
  of 7, BIST `cap 0x04922282` with no late errors, byte-rx 6 complete 382-word packets golden
  (`SIM_BYTE_GATE_K5.txt` in the kit, 2026-09-22 03:29).

**The matrix.** Work `sp2_gates/work_sp4d/model_matrix`, model tree `fc9003aa52b919b6` (sha256 over the kit's
generated `*.v`, cut to 16 hex; `GATES_TREE_SHA` keys the leg reuse), 2026-09-22 00:41 .. 06:01
(`gate1_run4.log`, wall 5:20 with 4 jobs). Run-leg results (`score_t7.py`, `T7_NAIR=428`, lost
frames in the denominator; `IMPLAUSIBLE` = corrupt seq fields counted as lost):

| leg | loss | skips / extras | ring end | leg | loss | skips / extras | ring end |
|---|---|---|---|---|---|---|---|
| m0_n_p000 (R4B) | 0.00 % (421/421) | 8 / -- | 2 | m20_n_p000 (R4DR1) | 0.00 % (421/421) | 8 / 0 | 2 |
| m0_n_p2p5 | 0.24 % (420/421) | 5 / -- | 31 (overflow x2) | m20_n_p2p5 | 0.00 % (421/421) | 5 / 10 | 23 |
| m0_n_m2p5 | 0.00 % (420/420) | 32 / -- | 9 | m20_n_m2p5 | 0.00 % (420/420) | 32 / 0 | 9 |
| m0_n_p10 | **22.75 %** (330 ok, 14 corrupt, 79 missing, 4 implausible of 422) | 3 / -- | 31 (overflow x79) | m20_n_p10 | **0.00 % (422/422)** | 3 / 87 | 23 |
| m0_n_m10 | 0.00 % (420/420) | 110 / -- | 2 | m20_n_m10 | 0.00 % (420/420) | 110 / 0 | 2 |

The W1 legs (`w1_p000` / `base_p000`, `w1_m10` / `base_m10`) deliver identical streams (164 and
209 x 382-word packets); the BS and PAD census legs agree (`bs_vs_pad`), `census_clean` holds
(0 short, 0 orphan, 0 drops), and the `+bsskip=3056` control stream gives 159743 words / 419
frames / 365 truncation events, `t7_ok=51 t7_nomagic=374`.

**The bank and the reference table.** `task7_bankfromrun4.sh`: the run's own `m0_n_p000_*` become
`b_p000_*`, `m0_n_p000_{deliv,frames}` -> `r4b_p000_*`, `m_bs_p000_census` -> `bs1_p000_census`,
`m_pad_k1536_{res,census}` -> `bs1_k1536_*` (16 files), and `collect_reference.py` writes
`reference_loss_f3072.toml` from the ten run legs (installed as `modem/gates/reference_loss.toml`;
the f1536 table is kept as `reference_loss_f1536.toml`). `modem/gates/bank_f3072.sha256` pins the
23 bank files and `run_gates.sh` verifies it whenever `SRO_SIM_DIR` is the f3072 bank.

**Re-pins.** Ten witness rows carried f1536 stream constants; they were re-pinned to the run-4
values, each with its rationale in the legs table header (sp4 block): the W1 md5s, `edge_m10`
(0 ring underruns with the occupancy floor), `G3_ring` (drain skip / drain frame excluded,
occupancy 9..10 inside the unchanged 8..12 band), the four `k1536` rows, `S1_p000_D2` (424),
`S5_p10_ring` (87 extras, occupancy 23), `census_grid` (all rows to the bank's last clock).

**Result.** `run_gates.sh --legs model_matrix.legs --jobs 4` on the banked tree with the bank and
the reference table in place (`gate1_run4c.log`, 2026-09-22 06:08):

    GATE_LEGS model_matrix pass=53 fail=0
    GATE_PASS model_matrix

**Gate 1 PASS, 53 of 53, no exception set** (the f1536 gate ran with 48 of 53 and five documented
exceptions). The identity rows pin this tree as the sp4 baseline; every later regen of the rung
(prod re-derivation, re-time rounds) is judged against it. Gate log:
`modem/rtl_sim/evidence/sp4/legs/model_matrix.log`.
