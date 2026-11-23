# Link status, 2026-10-02 -- what is fixed, what is known, what is next

One page over the week's evidence (`CARRIER_LOCK_LATCH_2026-09-29.md`, `FORWARD_LINK_2026-10-01.md`,
`RESET_LEDGER_2026-09-29.md`, `INTERRUPT_RESPONSE_2026-09-29.md`, `GATE3_REVERSE_PLAN_2026-09-29.md`,
`sp4/GATE3_SP4CLAMP004_2026-10-02.md`, `oneway/ONEWAY_HW_VERIFY_2026-10-01.md`). Rig: two Jupiters, 148 (A) and
146 (B), both on `sp3clamp004 8503f226395c` (`images/CURRENT.txt`), rung r3 (f1536, 15.36 Msym/s), plan forward
146 TX 2.100 → 148 RX 2.100020 GHz, reverse 148 TX 1.850 → 146 RX 1.850040 GHz (`ops/rung_table.sh`).

## Fixed

| what | evidence |
|---|---|
| **The receiver latched** (half-rate detection + carrier-reset storm until a soft reset; 146 re-armed 4,341× in 225 h) -- the symbol-timing loop integrator pinned on its 0.06 clamp rail. **IntegClamp 0.06 → 0.004** (`timing_hardening_overlay.m`, both rungs in RTL, gate `carrier_lock.legs`). | latch test 12/12 pauses 0 resets <1 s (shipped: 16 min latch); soaks 4 h + 4 h + 12 h with 0 resets / 0 re-arms on both boards; `CARRIER_LOCK_LATCH` §1-11 |
| Daemon relaunch without `chrt -f 50` (2-3 ms TX holes latched the peer) | recorded launch line, `relaunch_daemon()` (PR #77) |
| Reverse carrier 1.9 GHz notch → 1.85 GHz | `GATE3_REVERSE_PLAN`; reverse 0.002-0.010 % on every row since |
| Gate harness pinned to f3072 (an f1536 image could not be gated) | `geometry_gen.py`, `run_gates.sh --rung`, `model_matrix_f1536.legs` (PR #93) |
| Rails: `deploy_image.sh` DRY + sentinel hold; `gate3_pair.sh` rolls 148 back on a 146 flash failure and runs its rollback with the rollback rung's steering conf (PR #98, #100) | r4 attempt of 10-02 |
| One-way TXO/RXO images rebuilt with the clamp and verified both directions | `ONEWAY_HW_VERIFY_2026-10-01` |

## Known, not fixed

| what | status |
|---|---|
| **Forward link multipath fade.** The forward air path (146 → 148) has a frequency-selective slope that drifts ~100 MHz/day (2.0 GHz bad on 10-01, 2.1 bad on 10-02, both reverse-link clean at the other's bad carrier at first, reverse wedged at 2.1 on 10-02). The receiver has **no equaliser**; a tilt > ~8-10 dB across its 16 MHz breaks it (−14.6 dB → 46 %, −10.5 → 2.4 %, ≤ 4.7 → clean). `ops/tilt_score.py` measures it from any `pair.iq`. | antennas moved 10-02 17:00 (cells running); mitigations below |
| Forward link **noise-limited** even when flat: 0.04-0.05 % at 0 dB, ×5.5 at −6 dB TX; both radios at max gain (RX table tops at 34 dB) | link budget (antenna / path), not firmware |
| **r4 (sp4) pair gate** fails: 148 detects 0 f/s on the r4 plan while 146 receives 885 f/s | the r4 forward plan sat on the faded carrier; retry after the fade question |
| `0x15C` levelLog reads 0 on this image; `images/CURRENT.txt` DTB rows: both boards now carry the 4 MB carve (r3 host builds run on it) | informational |

## Next

1. **Antenna move result** (running): forward cells 2.1 / 2.0 / 2.15 + reverse, with tilt per cell; and the **r2 hedge**
   (same image, 30.72 MSPS profile, half the bandwidth → half the slope) measured on the same plan.
2. **Bring-up carrier probe** (`ops/carrier_probe.sh`): arm 2-3 candidate forward carriers, score tilt + detection,
   arm on the flattest; optional pre-step of `bringup_r2r3.sh`.
3. **Sim tilt leg**: `sim_sro_perturb.cpp PERT_TILT_DB` → the receiver's tolerance curve; a `carrier_lock.legs`
   row so receiver changes are judged against it.
4. **Equaliser** in the receiver model (fractionally-spaced LMS/CMA ahead of the carrier loops; the coarse estimator
   made robust to an asymmetric spectrum) -- the standing fix; the tilt leg is its acceptance test.
5. r4 retry with the rail fixes once the forward carrier is settled.
