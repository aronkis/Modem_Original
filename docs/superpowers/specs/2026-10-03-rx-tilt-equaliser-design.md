# Receiver in-band tilt corrector (equaliser) -- design note

Date: 2026-10-03. Status: design note, not yet approved for implementation. Author: written up by Claude from
the 10-01/10-02 forward-link study (`docs/evidence/link/FORWARD_LINK_2026-10-01.md` §9-§11).

## 1. Problem, in numbers

The receiver has no equaliser. A frequency-selective channel (multipath on the bench, drifting ~100 MHz a day)
puts a **slope across the 15.36 Msym/s band**, and the receiver fails on it long before the SNR is gone:

| in-band tilt (dB across 16 MHz) | air (lost frames in denominator) | model, noise-free (`PERT_TILT_DB`, 112 frames) |
|---|---|---|
| ≤ 4.7 | 0.006-0.05 % (baseline) | 112/112 syncs, estimate bias −14, noise 93 |
| −6 | — | 112/112, bias −23, noise 173 |
| −8 | — | 112/112, bias −472, noise 418 |
| −10.5 / −10 | **2.4 %** (10-01 2.0 GHz) | 112/112, bias −1,141, noise 670 |
| −12 | — | 112/112, bias −2,401, noise 927 |
| −14.6 / −14 | **46.6 %** (10-02 2.1 GHz) | 111/112, bias −3,781, noise 1,009 |
| −16 | — | 106/112, bias **−11,321**, noise 1,769 |

Mechanism (§9, §11): the power-4 coarse frequency estimator assumes a spectrally symmetric signal. A tilt
biases it (the −11,321-unit model bias at −16 dB **is** the −11,817 / −12,310 "LO shift" the rig read on the
46 % day) and makes it noisy; the derotator then wanders, the 13-symbol preamble correlator misses, CRCs fail.
On the air the attenuated half of the band also loses SNR against a link with only 10-20 dB of margin (§10), so
the air fails ~4 dB earlier than the noise-free model.

**Budget (from §11):** the demodulator must see **≤ 6 dB** of slope (bias < 30 units, noise < 200 units -- the
clean-air regime) from channels of up to **±16 dB**, and the correction must leave the clean-channel decode
bit-identical to today's.

## 2. What is proposed: a host-steered one-pole tilt corrector, not an adaptive FIR

The bench channel is, to first order, a slope -- the sim reproduces every live number with cascaded one-tap
stages `y = x + a·j·x[n−1]` (|H(f)|² = 1 + a² + 2a·sin(2πf/FS)). The cheapest exact correction is the
**inverse of that stage**: a complex one-pole IIR

```
y[n] = x[n] − a·j·y[n−1]          i.e.  yI = xI + a·yQ[n−1],  yQ = xQ − a·yI[n−1]
```

two real multipliers and two adders per stage, stable for |a| < 1, exactly flattening a one-tap slope. One stage
corrects up to ~8 dB (a = 0.9 → 8.0 dB; 0.52 → 6 dB; 0.33 → 4 dB); **three cascaded stages** cover ±24 dB, more than
the worst day seen (−14.6). Gain change per stage is 10·log₁₀(1 + a²) ≤ 2.6 dB, absorbed by the AGC that follows.

The FIR form `y = x − a·j·x[n−1]` (no feedback) was considered and rejected as the primary: it cancels the slope
but leaves a **symmetric mid-band bulge** of 0.9 dB (a = 0.33), 2.1 dB (0.52), 5.2 dB (0.9) -- harmless to the
power-4 estimator (it is even) but a real ripple for the matched filter. It stays the fallback if the IIR's
fixed-point behaviour disappoints in Gate 1.

Why not an adaptive FIR (CMA / LMS)? A 5-9 tap complex FIR at the sample rate is 20-36 real multipliers plus an
update engine, it needs a convergence/ambiguity story against the carrier loop, the 13-symbol Barker preamble is
too short to train it, and nothing measured on this bench needs it: the channel is a slope that drifts over
**days**, so a coefficient written by the host at bring-up and refreshed by the degraded trigger is fast enough.
`HDL_CMA_core` in the tree is a CORDIC angle block, not an equaliser (§9), so there is no partial implementation
to build on. Revisit if the corrected spectra show structure the slope model misses (the deepest 1 MHz dip on the
46 % day was −10 dB, mostly explained by the slope).

## 3. Where it sits, and the numeric contract

Insert in the dev model receiver **between the ADC input and `Automatic_Gain_Control`** (`QPSK_Rx`: AGC → RRC →
FixCtlDec → Frequency_and_Time_Synchronizer → …). Reasons: the tilt is a channel property, so correcting it on
the raw samples fixes every downstream consumer (AGC level estimate, RRC, estimator, preamble correlator) at once;
the AGC then absorbs the ≤ 2.6 dB/stage gain change; the RRC's sfix16_En12 output and everything after are
untouched, which keeps the "bit-identical when off" gate trivial (a = 0 → y = x exactly).

| item | value |
|---|---|
| data in/out | sfix16_En14 complex at 61.44 MSPS, one sample per clock (the AGC's input type) |
| coefficient per stage | sfix16_En15, |a| ≤ 0.95 enforced in the decoder (pole margin) |
| stages | 3, each with its own a_k; a_k = 0 bypasses exactly |
| internal state | y[n−1] per stage at sfix18_En14 (2 guard bits), output saturated to sfix16_En14 |
| latency | 3 clocks (one register per stage); the FTS/byte-plane contracts do not see it (AGC is upstream of every pinned latency) |
| control | new regmap word `0x260` TILT_EQ: bits [15:0] a_1, [31:16] a_2 of a second word `0x264`, [15:0] a_3, bit 31 of `0x264` = enable; written by the host, read back; cleared by 0x000 like `0x208` (so bring-up re-applies it, same as `sro_sign.sh`) |
| resources | 6 DSP48 (or LUT multipliers), ~120 FFs, no BRAM. Post-route WNS of the shipped image is 0.137 ns overall; the corrector is a short feed-forward/feedback pair at 61.44 MHz and must not be the new critical path -- Gate 2 pins the intra-clock gate row at ≥ its current value |

## 4. Who computes `a`

The host already measures the in-band slope from a Tap-A IQ snapshot (`ops/tilt_score.py`, used by
`ops/carrier_probe.sh`). The corrector closes that loop:

1. At bring-up (after the ARM gate, before the daemons start): capture 4 ms of Tap-A IQ on the receiving board,
   fit the slope `t` dB/16 MHz, solve the one-stage bisection of the sim driver for `a` per stage
   (same code as `PERT_TILT_DB`: `want = |t| / K`, K = 1 for |t| ≤ 7, 2 for ≤ 14, 3 above), **with the
   opposite sign**, write `0x260/0x264`, re-measure and log `TILT_EQ ip t_before t_after a1 a2 a3`.
2. On every degraded-trigger fire and every watchdog FULL RE-ARM path that re-applies `0x208`, re-apply (and
   optionally re-measure) -- the same place `sro_sign.sh --bringup` runs today.
3. Never adapt on the fabric: the coefficient is a slowly varying bench property, and a host-written register is
   observable, loggable and bit-reproducible in the gates.

## 5. Verification plan (the gates this note is judged by)

* **Gate 1 identity (sim):** `a = 0`: decode bit-identical to the shipped sp3clamp004 tree on every
  `model_matrix_f1536.legs` row (the `cl_identity` pattern -- `cmp` of the first 10 columns of `*_pert.txt`).
* **Gate 1 tilt rows (sim, new):** `PERT_TILT_DB = −8, −12, −16, +10` with the corrector set to the inverse (host
  formula): **112/112 syncs, |bias| < 30, noise < 200** at every point (the clean regime); and the same rows with
  the corrector **mis-set by one stage** (a_k off by 20 %) must still pass the 6 dB budget -- the correction must
  not be fragile against the measurement.
* **Live-signal replay (desk, new):** replay the recorded 46 % day (`ops/r3cap/fwddiag_20261002_1604/gate3/cell1_A_2100020000/pair.iq`,
  −14.6 dB) and the 2.4 % day (`fwd2100_20261001_1110` cell 1, −10.5 dB) through the corrected receiver model
  with `a` taken from `tilt_score.py` on those very files (`iq-replay-through-receiver-model`): syncs and estimator
  noise must reach the clean regime. This is the test the air cannot schedule.
* **Gate 2:** WNS gate row ≥ current; utilisation delta reported.
* **Gate 3 (silicon):** the standard pair run on a flat day proves nothing is broken; the tilt benefit is proven
  by the first naturally tilted day (trigger-captured `pair.iq` tilt > 8 dB with PER at baseline) or by the
  replay above -- state which one the evidence doc cites.

## 6. Work plan and estimate

| step | where | time |
|---|---|---|
| overlay `tilt_eq_overlay.m` (3 stages, decoder, regmap taps) + `regmap.toml` + `gen_regmap.py --check` | dev model, desk | 1 day |
| sim: wrapper taps, legs rows, `perturb_score.py` tilt budget columns, replay script | `modem/rtl_sim`, `modem/gates` | 0.5 day |
| host: `ops/tilt_eq.sh` (measure → solve → write → verify), bring-up hook next to `sro_sign.sh`, tests | `ops/` | 0.5 day |
| regen + image on hdl-dev-2, Gate 1/2 | lab host | 3-4 h wall |
| Gate 3 pair, evidence doc | bench | 2.5 h |

## 7. Out of scope

Adaptive equalisation; the r2 rung as a tilt mitigation (it halves the slope but also the rate -- an operational
choice, not a fix); the self-interference class of 10-02 (antenna placement, §10); the reverse link's weak path.
