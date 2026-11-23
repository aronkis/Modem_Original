# dbgcap

`dbgcap_inject.py` patches a copy of the netlist tree to add per-stage RX
decision capture, armed by frame start. It owns the `0x20C` (`viol_count`)
and `0x210` (`viol_latch`) registers — this is why the W1 fix's own read
window starts one word later, at `0x214`, and why W1 must not disturb those
two addresses. Selected via fixctl `0x208` bit 13 (shared DBGCAP/DEMODCAP
mux).

Flashed image: md5 `0f203cf887d3` — confirmed on 148, carrying DBGCAP, TXCAP
and DEMODCAP together (`docs/superpowers/plans/2026-08-31-parallel-datapath-agents.md:966`,
`docs/superpowers/specs/2026-08-31-parallel-datapath-agents-design.md:39,223`,
and `docs/superpowers/plans/2026-09-10-fix-layer-promotion-chain-trace.md` §6).

No injection prerequisites — this is the base capture instrument that
`demodcap`, `rxfe`, `txcap`, and `txint` all apply after.

Not on the fix chain's critical path.
