# modem/instruments/ — capture/probe injectors

Netlist-patching instruments used to add witness/capture logic to a build
tree during bring-up debugging, moved out of the pre-cleanup campaign kit directory (cleanup
sub-project 2, task 8, 2026-09-10). Each
subdirectory is one instrument: a `<name>_inject.py` (or, for `beatila`/`dcp`,
a set of Tcl/overlay files) that patches a copy of the netlist tree, plus the
build/flash scripts specific to that instrument and a `README.md`.

These are debug tooling, not the fix chain. `modem/fixes/apply_fixes.py
--instrument NAME` can splice one onto a fix kit at the end of the chain
(after `txfix_kit.sh` / `seqbist_kit.sh` / `rxfix_kit.sh`), resolving
`modem/instruments/NAME/NAME_inject.py`; it is otherwise no part of any
build. Of everything below, **only `ddrcap2` is on the fix chain's critical
path**, and only as an ancestor tree — `jupiter_byte_ddrcap2_build` is the
root kit both deployed images (148 rxfixpad, 146 rxfixr4dr1) descend from,
not because `ddrcap2_inject.py` itself runs as a build step of either.

| Instrument | What it captures | Critical path? |
|---|---|---|
| `ddrcap` | Raw IQ + both frame markers on 5 new top-level ports, reusing the 0x10C `iq_debug_mux` select | No |
| `ddrcap2` | Joint timing capture (correlator/interpolator/timing signals); fixctl[12]/[13] muxes | **Yes — ancestor tree of both deployed images** |
| `dbgcap` | Per-stage RX decision capture armed by frame start; owns 0x20C/0x210 (why W1's read window starts at 0x214) | No |
| `demodcap` | Demod-vs-FEC-input bit/position discriminator; apply after `dbgcap` | No |
| `rxfe` | RRC receive-filter and coarse-CFC witnesses; apply after `dbgcap` + `demodcap` | No |
| `stagesig` / `stagesig3` | Per-stage per-frame signature witness (abandoned; stagesig3 is the GATE-4 bounded-window revision) | No |
| `txcap` | TX-side capture anchored on the transmitter's own frame start (fixctl[12]); apply after `dbgcap` | No |
| `txint` | Bounded capture for the four TX blocks; FINAL lineage, requires `dbgcap`+`txcap`+`demodcap` already applied | No |
| `beatila` | BEATILA XVC/ILA debug bridge + burst-onset trigger splice (beatila3/beatfix/beatobs Tcl, XDC, MATLAB overlays) | No |
| `dcp` | Post-implementation checkpoint (.dcp) forensics: glitch-path probe and pin-load dump, no netlist patch | No |
| `skid` | 1-deep AXIS skid buffer + beat-parity witness spliced into the byte-plane write port | No |
| `tgen` | Traffic-gen (TX) and traffic-gen-RX splice for closed-loop byte-plane testing | No |

Registers: fixctl is `0x208`, write-only. See `modem/fixes/apply_fixes.py`'s
manifest chain and `docs/evidence/rxfix/W1_REGMAP.md` for the fix-chain's own
read window (0x20C-0x258); instruments above that reuse or extend the same
window say so in their own README.

None of these are run, built, or flashed by this move — that is an operator
decision documented per-README.
