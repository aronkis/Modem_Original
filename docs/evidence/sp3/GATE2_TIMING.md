# Gate 2 — sp3 single-image post-route modem-clock timing

**Verdict: PASS.** `wns = +0.785 ns` against the floor `0.005` (spec Gate 2 /
controller ruling 8). TNS 0.000, **0 failing endpoints of 85,948**.

The runtime-select work (Tasks 12-15) is therefore NOT dropped on timing
grounds. This page exists because the plan makes Gate 2 a stop/go decision
point: below the floor the runtime select is abandoned and sp2 stays shipped,
with no "squeeze it with another implementation strategy" retry. That branch was
not taken.

## The number, and where it comes from

```
MODEM_CLK_WNS clock=axi_adrv9001_adc_1_clk wns=0.785 tns=0.0 failing=0 total=85948
BUILD_IMAGE_WNS_OK wns=0.785 floor=0.005 ref_pad=0.105 ref_sp2A=0.447 ref_sp2B=0.785
```

`modem/gates/modem_wns.py` parses the **Intra Clock Table** of the fetched
`impl_1` timing summary, preferring `*_postroute_physopted.rpt` (the final
as-built netlist) over `*_timing_summary_routed.rpt`. Both reports were fetched
and both carry the identical row, so the choice is not load-bearing here:

```
Clock                    WNS(ns)  TNS(ns)  TNS Failing Endpoints  TNS Total Endpoints  WHS(ns)
axi_adrv9001_adc_1_clk     0.785    0.000                      0                85948    0.009
```

Hold is clean too (WHS +0.009, THS 0, 0 failing of 85,948) and pulse width has
2.560 ns slack over 33,641 endpoints.

**Two other WNS numbers appear in the build log and are NOT Gate 2.** Quote the
right one:

| number | value here | what it is |
| --- | --- | --- |
| `TIMING_GATE_WNS modem_dut=` | 1.807 | `timing_gate.tcl`'s PRE-implementation estimate, scoped to the `TxRxCompo_ip_0` cells. Also what the build's own `TXFIX_BUILD_DONE variant=SP3 ... wns=1.807` reports. |
| `TXFIX_ROUTED_WNS wns=` | 0.207257 | post-route WNS over the WHOLE design, every clock domain including the stock ADI IP. The template refuses to run bootgen below 0. |
| `MODEM_CLK_WNS wns=` | **0.785** | **Gate 2**: post-route, intra-clock, `axi_adrv9001_adc_1_clk` only. |

`timing_gate.tcl` also printed `overall=-1.119` post-synth; that is the stock
ADI IP's own cross-domain pessimism before implementation, and it resolves to
+0.207 after place and route.

## Against the reference points

| build | modem-clock post-route WNS | note |
| --- | --- | --- |
| floor (ruling 8) | 0.005 | Gate 2 |
| `rxfixpad` (deployed, netlist fixes) | 0.105 | `BOOT.BIN.148.rxfixpad.bf2a7305bbe0` |
| sp2A (deployed 148) | 0.447 | `BOOT.BIN.148.sp2A.3e7f4232a3b5` |
| sp2B (deployed 146) | 0.785 | `BOOT.BIN.146.sp2B.d94b4df391a1` |
| **sp3** | **0.785** | this build |

sp3 lands 157x the floor, and above both of the deployed sp2 images' worse half.
The exact tie with sp2B's 0.785 is not a copied value: the number is read out of
this build's own report rows quoted above, and the two builds differ in both
fix content and BD content. Read it as "the same slack bucket", not as
provenance.

Model-backported fixes and a SEQ-BIST instrument (a CRC32 datapath, a 32-slot
counter mux, three AXI GPIOs, a traffic generator spliced into the TX byte path)
were added to the design in this build, and it still closed with room. That is
the substantive result: SEQ-BIST does not have to be dropped, and `WITH_CRC=0`
— the escape hatch `rx_seq_checker` carries for exactly this case — was not
needed.

## Provenance

| | |
| --- | --- |
| image (canonical) | `images/BOOT.BIN.jupiter.sp3.c5ec53bc610c5eff837a62b439466660` (7,203,552 B) |
| rail-shaped names | `images/BOOT.BIN.148.sp3.c5ec53bc610c`, `images/BOOT.BIN.146.sp3.c5ec53bc610c` -- **symlinks**, not hard links, onto the canonical file, and carrying the **12-hex** md5 because both rails take `FLASH_MD5` as exactly 12 lowercase hex and open `images/BOOT.BIN.<board>.$FLASH_TAG.$FLASH_MD5` (`ops/flash/flash_148_txfix.sh:43-44`, `flash_146_txfix.sh:66-68`). Deleting or renaming the canonical `BOOT.BIN.jupiter.sp3.<32-hex>` BREAKS BOTH rail names -- they are links, not copies. `modem/tests/test_image_rail_names.py` fails if either stops resolving to a file whose md5 begins with the 12 hex in its own name. |
| md5 | `c5ec53bc610c5eff837a62b439466660` (matches the remote `BYTE_BUILD_DONE` and `TXFIX_BUILD_DONE` lines) |
| command | `modem/build_image.sh --tag sp3 --remote-base /mnt/disk2/scratch/qpsk-builds` (`hdl` stage run first as `--stop-after hdl`, then `--from vivado`) |
| kit | `jupiter_byte_sp3_build` (never a `*_build_ref`; the template now refuses those by name) |
| `model_tree_sha` | `144c89e8fe98317d` -- the SAME value in `STAMP.hdl` and `STAMP.vivado`, which is what ties this image to the tree the hdl stage gated. Both stamps and the hdl log are quoted verbatim in `GATE2_TIMING_BD.md` and snapshotted at `/mnt/onetb/scratch/qpsk-build-trees/work_sp3_evidence/`. |
| repo git | `ba4e056c` |
| local hdl unit | `sp3-hdl-r2-021351.service`, nemo, 02:13 → 02:47 (34 min; MATLAB 1708 s + BD session) |
| remote build unit | `txfix-build-sp3_build-1789195646.service`, hdl-dev-2, 02:47 → 03:17 (**30 min** at `IMPL_STRATEGY=explore`, `JOBS=6`) |
| remote tree | `/mnt/disk2/scratch/qpsk-builds/jupiter_byte_sp3_build` (132 GB free at preflight) |
| Vivado | v2025.1, `/opt/Xilinx/2025.1/Vivado/bin` |
| reports | `<work>/impl1_reports_sp3/system_top_timing_summary_{routed,postroute_physopted}.rpt` |
| build log | `<work>/build_txfix_vivado.log`, `<work>/build_vivado.out` (`<work>` = `/mnt/onetb/scratch/qpsk-build-trees/work_sp3`) |

The 30-minute wall time is short against sp2's 2 h 15 and was checked rather
than assumed: the remote `build_txfix_vivado.log` and `boot/BOOT.BIN` are both
stamped 03:17 (the remote script `rm -f`s BOOT.BIN before launching), the log
carries `=== impl strategy: explore ===`, `TXFIX_ROUTED_WNS`, `BYTE_BUILD_DONE`
and `TXFIX_BUILD_DONE` in order, and the md5 of the fetched file equals the md5
the remote bootgen printed. It is a real build, not a stale artefact.

## The block design this image was built from

The `hdl` stage's BD-completion evidence -- `BUILD_HDL_BD_OK`, the `DDRCAP_BD_WIRE_OK` that had never appeared on a regenerated tree before, `SEQBIST_WIRE_OK lineage=vendh`, the seven `TxRxCompo_ip_0`/SEQ-BIST cell re-verifications against the saved `system.bd`, and both STAMP lines -- is quoted **verbatim** in `GATE2_TIMING_BD.md`. It lived only on scratch disk inside a tree that `build_hdl.sh` deletes on every run, and was in fact destroyed an hour after the build; that page explains how, and why the image itself is unaffected.

## What this page does NOT claim

* **Not Gate 1.** The `gates` stage did not complete for this tree (see the Task
  11 report: `make_sro_trees.sh --from-regen` and the Verilator object dirs are
  single shared paths, and Task 9 was running the same matrix concurrently, so
  my legs would have scored Task 9's binaries). The structural half did pass on
  the sp3 tree — `MAKE_SRO_FROM_REGEN_DONE`, `tree_marker.sh` reading `model`
  for all of W1/R4B/R4DR1/BS/PAD/F3, and `BANK_OK`. `build_image.sh` printed
  `BUILD_IMAGE_WARN gates stage not stamped ... building UNGATED` and that is
  the honest status of this image.
* **Not a silicon gate.** Nothing was flashed. No board was touched by this
  task. PER, BER and link behaviour of this image are unmeasured.
* **Not a deployment.** `images/CURRENT.txt` is unchanged; sp2A/sp2B remain the
  current roles.
