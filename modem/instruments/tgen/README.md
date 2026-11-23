# tgen

Traffic-generator (TX) and traffic-generator-RX splice for closed-loop
byte-plane testing, independent of the live air link. Configured at runtime
via `tgen_ctrl_gpio @0x9D400000`, not through the fixctl `0x208` window.

Files:
- `patch_tgen_tcl.py` — splices the traffic-gen core into
  `complete_byte_t8.tcl`. Lineage/style source for
  `modem/dev/simulink/beatila/patch_beatila_tcl.py`.
- `run_tgen_build.sh`, `run_tgenrx_build.sh` — build wrappers for the TX-side
  and RX-side generators respectively.
- `flash_148_tgen.sh`, `flash_148_tgenrx.sh` — matching flash rails.

Flashed image: the tgenrx image md5 `9259cfade5b4` flew 2026-08-18/19
(`docs/evidence/SINGLES_CAMPAIGN.md`, "Task 3: tgenrx flash"). Readback
passed but the health gate failed after its one permitted re-bring-up
(fsync 4225, wcnt 0, TGEN GPIO witness all 0); auto-rolled back to
`e49c011b`. TAP_VERDICT: NOT OBTAINED — it is a standing suspect in the
08-13→08-22 ramp bracket, never convicted. No flashed-image md5 is recorded
for the plain (non-RX) tgen build.

No injection prerequisites; not on the fix chain's critical path.
