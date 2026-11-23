# ddrcap2

`ddrcap2_inject.py` patches `Interpolation_Control.v`, `Symbol_Synchronizer.v`,
`Preamble_Detector.v`, `Frequency_and_Time_Synchronizer.v`, `QPSK_Rx.v`,
`Receiver.v` and `TxRxComposite.v` to expose joint timing-recovery capture:
the interpolator's `countReg`, the symbol synchronizer's `dc_*` ports, and the
preamble detector's correlator/timing-offset outputs, muxed into a slotted
capture word (`ddrcap2_slot_r`, `ddrcap_sel_r`) alongside the ddrcap markers.
It reuses fixctl `0x208` bits 12/13 (TXCAP / DBGCAP-DEMODCAP mux selects) as
its capture-source muxes.

Flashed image: `jupiter_byte_ddrcap2_build`, md5 `638b36de3493` — confirmed
banked and flashed+verified on 148 (see prior DDRCAP-v2 instrument-facts
notes; this is the same tree, carried unchanged, not a re-derivation here).

**This is the only instrument on the fix chain's critical path** — not
because `ddrcap2_inject.py` runs as a build step of either deployed image,
but because `jupiter_byte_ddrcap2_build` is the root kit both the 148
(rxfixpad) and 146 (rxfixr4dr1) deployed images descend from
(`modem/fixes/apply_fixes.py`'s chain starts from this base tree name).

Injection prerequisite: applies to the loose/sim tree directly; typically
run ahead of `ddrcap` in the sim-build scripts (`build_beat_sim.sh`,
`build_ddrcap2_sim.sh`). `ops/tests/test_ddrcap2_inject.py` is the regression
test for this injector's per-file patchers and the full-tree lint/idempotency
check; it imports from this directory.

## Record layout per frame (2026-09-19, sp4 rung)

`ddrcap2_inject.py` reads `QPSK_FRAME` (the hdl stage exports it):

| frame | ch2 | ch3 | sidecar slots |
|---|---|---|---|
| k5 / f1536 (shipped) | `{mark_demod, mark_fec, toff[13:0]}` | `{slot[1:0], side[13:0]}` | heldts[13:0], tref[13:0], runmax[31:18], corrthr[31:18] |
| f3072 (WIDE) | `{mark_demod, toff[14:0]}` | `{mark_fec, slot[1:0], side[12:0]}` | heldts[12:0], **tref[14:2]**, runmax[31:19], corrthr[31:19] |

At f3072 the search window is 24634 slots, so Peak_Search emits ufix15 timingOffset / p1c_tref and the
14-bit fields cannot hold them; the injector refuses a ufix15 tree unless `QPSK_FRAME=f3072`, and
refuses `QPSK_FRAME=f3072` on a ufix14/11 tree. `ops/flash/ddrcap2_decode.py --frame f3072` (or the
env) decodes the wide layout and reports tref x4. The 148 rail's tier-2 witness decode must pass
`--frame f3072` for an sp4 image (ops rung r4 work).
