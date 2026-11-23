# ddrcap

`ddrcap_inject.py` patches a copy of the netlist tree to expose raw IQ plus
both frame markers on 5 new top-level ports, reusing the existing `0x10C`
`iq_debug_mux` select register rather than adding a new one. It is the
precursor capture used ahead of `ddrcap2` (see `modem/rtl_sim/build_beat_sim.sh`
and `build_ddrcap2_sim.sh`, both of which invoke this injector before the
ddrcap2 injector in the same sim-tree build). No separately confirmed
flashed-image md5 is recorded in tracked `docs/evidence/`; not asserted here.

No injection prerequisites — it patches ports directly off the composite,
independent of the other capture instruments.

Not on the fix chain's critical path.

`test_ddrcap_inject.py` is the regression test for `main()`'s pass/fail
verdict (stubbed per-file patchers, live zip verification) — run with
`python3 -m pytest modem/instruments/ddrcap/test_ddrcap_inject.py -q` or
directly as a script.
