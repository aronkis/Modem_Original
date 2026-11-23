# beatila

The BEATILA line of instruments splices an XVC/ILA debug bridge plus a
burst-onset trigger into the implemented design, entirely via post-synthesis
Tcl/XDC manipulation rather than a `*_inject.py` netlist patcher — there is
no register-window or fixctl mux involved; it works by inserting a debug
core (`u_ila_beat3`) directly into a linked design checkpoint.

Files:
- `beatila3_insert_impl.tcl` — the RECOVERY-tail build: direct debug-core
  insertion into a synth-linked DCP, gated by hard verification of
  `u_ila_beat3` before spending implementation time. Args:
  `<synth_linked_dcp> <debug_xdc> <outdir>`.
- `beatila3_preflight.tcl`, `beatila3_preflight_dataout.tcl` — preflight
  checks ahead of the insertion.
- `beatila3_debug.xdc` — the debug-core XDC; `gen_beatila3_xdc.py` generates
  variants of it.
- `patch_beatila_tcl.py`, `patch_beatila3_tcl.py` — splice the BEATILA
  insertion into the ordinary build Tcl flow. `patch_beatila_tcl.py`'s
  style/lineage follows `modem/instruments/tgen/patch_tgen_tcl.py`.
- `patch_hdlworkflow_beatfix.m`, `beatfix_overlay.m`, `beatobs_overlay.m` —
  MATLAB-side overlays for the BEATFIX/BEATOBS build variants (HDL Coder
  workflow patch + burst-fix/burst-observe simulink overlays).
- `run_beatfix_build.sh`, `run_beatfix2_build.sh`, `run_beatila_build.sh`,
  `run_beatila2_build.sh`, `run_beatila3_build.sh`, `run_beatobs_build.sh` —
  the build wrappers for each generation of this instrument.
- `flash_148_beatfix.sh`, `flash_148_beatfix2.sh`, `flash_148_beatila.sh`,
  `flash_148_beatobs.sh` — the matching flash rails.

Flashed image: BEATFIX v3, md5 `fe5bd8a4fe19`, confirmed on 148
(`docs/evidence/NETLIST_PROVENANCE.md`; produced by
`jupiter_byte_beatfix2_build/`, flashed via `flash_148_beatfix2.sh`,
`fixctl@0x208` default 0 = legacy). No md5 is recorded for the BEATILA3/
BEATOBS generations specifically; not asserted here.

No injection prerequisites — operates on an implemented checkpoint directly.

Not on the fix chain's critical path.
