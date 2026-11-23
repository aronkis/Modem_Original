# dcp

Post-implementation checkpoint (`.dcp`) forensics — these do not patch the
netlist or produce a new bitstream; they inspect an already-implemented
design checkpoint directly. No register window or fixctl bits are involved.

Files:
- `dcp_glitch_probe.tcl` — byte-plane CE/rail glitch-path forensic tool run
  against a shipping implementation checkpoint (per HANDOFF_20260815),
  investigating BUFGCE/BUFGCE_DIV CE-driving LUT structures for
  glitch-proneness.
- `dcp_loadpins.tcl` — pin-load dump from a checkpoint.

No flashed image applies — these tools read an existing checkpoint, they do
not build or flash one.

No injection prerequisites; not on the fix chain's critical path.
