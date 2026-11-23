# stagesig3

`stagesig3_inject.py` is the GATE-4 bounded-window revision of `stagesig`:
same per-stage per-frame signature idea, narrowed to a bounded capture window
to make the signature tractable to read out. Like `stagesig`, this
investigation line was abandoned. Uses fixctl `0x208` bits 8-11 (`stageSel`),
same as `stagesig`. Checked against both `images/README.md` and
`docs/evidence/` (by instrument name and by every md5 on record) —
stagesig3 genuinely has no tracked flashed-image citation, same as
`stagesig`. No md5 is asserted here.

No injection prerequisites beyond the base netlist tree.

Not on the fix chain's critical path.
