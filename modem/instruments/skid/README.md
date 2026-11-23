# skid

A 1-deep AXIS skid buffer plus a beat-parity witness counter, spliced into
the byte-plane write port. The skid register absorbs a stall beat so it
never reaches the DUT's own drop-on-stall decision, letting the beat-parity
witness distinguish "stalled and recovered" from "stalled and dropped". No
fixctl register is involved — this instrument works by insertion into the
byte-plane datapath itself, not via a capture mux.

Files:
- `qpsk_axis_skid.v`, `qpsk_axis_skid_v2.v`, `qpsk_axis_skid_v3.v` — three
  generations of the skid buffer core.
- `run_skid_build.sh`..`run_skid_build4.sh` — build wrappers for each
  generation.
- `run_tb_ab.sh` — A/B testbench runner; `tb/` holds its stream fixtures
  (`stream_m{0,1,2}_t{0,1}.txt`) and `tb_dma_contract.v`.
- `patch_complete_tcl.py`, `patch_gcc.py` — splice the skid buffer into the
  build Tcl flow and patch generated C accordingly (skid-specific; not
  shared with other instruments).
- `flash_148_skid.sh`, `flash_148_skid2.sh` — flash rails for the first two
  generations.

Flashed images, both confirmed dead ends (`docs/evidence/SKID_BUILD.md`,
`docs/evidence/TICK_FIX_SIM.md`): v1 md5 `c9d3e1ece983` deadlocked the byte
plane on flash (fsync 1252, wcnt 0), reproduced in `tb/tb_dma_contract.v`
(frozen `tuser`=0 beat blocks `SYNC_TRANSFER_START`); v3 md5 `6c06ecb7e888`
(transparent wire + marker-free gap witness) flashed and ran PER-identical
to the pre-skid baseline `e49c011b`, but its own witness proved not to be a
working instrument. v2's flashed md5 is not recorded, only that it cost
+5.6 pp forward PER and was rolled back. The whole skid/backpressure fix
class is dead per `docs/evidence/TICK_FIX_SIM.md`'s superseded-notice.

No injection prerequisites; not on the fix chain's critical path.
