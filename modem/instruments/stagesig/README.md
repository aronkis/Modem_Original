# stagesig

`stagesig_inject.py` patches a copy of the netlist tree to add a per-stage,
per-frame signature witness across the pipeline, selected via fixctl `0x208`
bits 8-11 (`stageSel`). This line of investigation was abandoned in favour of
the bounded-window revision (`stagesig3`). Checked against both
`images/README.md` (the image bank's own md5 rows) and `docs/evidence/`
(searched by instrument name and by every md5 this repo has on record) —
stagesig genuinely has no tracked flashed-image citation. No md5 is
asserted here.

No injection prerequisites beyond the base netlist tree.

Not on the fix chain's critical path.

`flash_148.sh` (formerly `flash_148_stagesig.sh`) and `run_flash_stagesig.sh`
are this instrument's flash rail and its build-then-flash wrapper.
