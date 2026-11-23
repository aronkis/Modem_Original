# txcap

`txcap_inject.py` patches a copy of the netlist tree to add TX-side capture
anchored on the transmitter's own frame start, using fixctl `0x208` bit 12
(TXCAP mux) as its capture-source select.

Flashed image: md5 `0f203cf887d3` — confirmed on 148, carrying DBGCAP, TXCAP
and DEMODCAP together (`docs/superpowers/plans/2026-08-31-parallel-datapath-agents.md:966`,
`docs/superpowers/specs/2026-08-31-parallel-datapath-agents-design.md:39,223`,
and `docs/superpowers/plans/2026-09-10-fix-layer-promotion-chain-trace.md` §6).

Injection prerequisite: apply after `dbgcap`.

Not on the fix chain's critical path. `apply_fixes.py --instrument txcap`
is the reference example wired into the driver's `plan()` (see
`modem/fixes/tests/test_apply_fixes.py::test_instrument_step_path`).
