# rxfe

`rxfe_inject.py` patches a copy of the netlist tree to add RRC receive-filter
and coarse-CFC witness capture on the RX front end. No separately confirmed
flashed-image md5 is recorded in tracked `docs/evidence/`; not asserted here
— an untracked scratch listing (no longer present on disk at time of
writing) suggested it may be folded into a combined/final image rather than
flashed standalone, but that is not independently confirmed and is not
asserted as fact.

Injection prerequisite: apply after `dbgcap` and `demodcap`.

Not on the fix chain's critical path.
