# demodcap

`demodcap_inject.py` patches a copy of the netlist tree to add a
demod-vs-FEC-input bit/position discriminator, distinguishing where in the
pipeline a bit disagreement originates. Selected via fixctl `0x208` bit 13
(shared DBGCAP/DEMODCAP mux).

Flashed image: md5 `0f203cf887d3` — confirmed on 148, carrying DBGCAP, TXCAP
and DEMODCAP together (`docs/superpowers/plans/2026-08-31-parallel-datapath-agents.md:966`,
`docs/superpowers/specs/2026-08-31-parallel-datapath-agents-design.md:39,223`,
and `docs/superpowers/plans/2026-09-10-fix-layer-promotion-chain-trace.md` §6).

Injection prerequisite: apply after `dbgcap`.

Not on the fix chain's critical path.
