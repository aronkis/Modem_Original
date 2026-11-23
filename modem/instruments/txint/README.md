# txint

`txint_inject.py` patches a copy of the netlist tree to add bounded capture
for the four TX blocks. This is the FINAL lineage of the TX-side capture
work: it requires `dbgcap`, `txcap`, and `demodcap` already applied ahead of
it, in that order.

Flashed image: md5 `0f203cf887d3` — confirmed in
`docs/superpowers/plans/2026-09-10-fix-layer-promotion-chain-trace.md` §6
("txint (FINAL lineage 0f203cf887d3)").

Not on the fix chain's critical path.
