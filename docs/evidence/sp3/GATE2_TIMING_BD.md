# sp3 hdl stage — the BD-completion evidence, verbatim

Companion to `GATE2_TIMING.md`. This page exists because the evidence it quotes
lived only on scratch disk, inside a tree that is routinely deleted and rebuilt
(`modem/build_hdl.sh` step [1] is `rm -rf "$FRESH"`), and it was in fact
destroyed within an hour of the build — see "Provenance of these quotes" below.
Everything here is copied verbatim from the run that produced the banked image.

## What this proves

The controller's load-bearing finding for sp3 Task 11 was that the regenerated
tree is **not** a completed Vivado project: HDL Coder's Create Project task
fails on this kit, so `system.bd` carries the byte reference design but no
`TxRxCompo_ip_0` cell, and the BD completion (`modem/complete_byte_t8.tcl`) had
never been part of the regeneration recipe. The lines below are the first
machine-checked demonstration that the `hdl` stage now completes the block
design itself, wires both BD instruments into it, and hands the `vivado` stage a
tree the sp2 template can build unchanged.

## STAMP.hdl — the stamp the banked image was built from

```
stage=hdl tag=sp3 model_tree_sha=144c89e8fe98317d git=ba4e056c when=2026-09-12T02:42:03-04:00 result=BUILD_HDL_BD_OK tokens=BYTE_WIRE_OK,WIRE_OK,VALIDATE_OK,DDS_DIET_OK,COMPLETE_BYTE_BD_DONE,DDRCAP_BD_WIRE_OK,SEQBIST_WIRE_OK
```

`STAMP.vivado`, written by the build that produced the banked BOOT.BIN, carries
the **same** `model_tree_sha`, which is what ties the image to this tree:

```
stage=vivado tag=sp3 model_tree_sha=144c89e8fe98317d git=9eeb0651 when=2026-09-12T03:18:59-04:00 result=md5=c5ec53bc610c5eff837a62b439466660 modem_wns=0.785 remote_base=/mnt/disk2/scratch/qpsk-builds
```

(The two `git=` values differ only because two commits of unrelated repo work
landed between 02:42 and 03:18; `model_tree_sha` is the identity that matters,
and it is identical.)

## The hdl stage, verbatim (`work_sp3/build_hdl_stage2.out`)

```
== stage hdl (tag sp3, kit jupiter_byte_sp3_build, git ba4e056c, work /mnt/onetb/scratch/qpsk-build-trees/work_sp3)
BASE_REGEN kit=/mnt/onetb/scratch/qpsk-jupiter-modem/modem dest=/mnt/onetb/scratch/qpsk-build-trees/regen11/jupiter_byte_sp3_build bank=/mnt/onetb/scratch/qpsk-build-trees/base/jupiter_byte_ddrcap2_build  2026-09-12T02:13:51-04:00
BASE_REGEN matlab=25.2.0.3177638 (R2025b) Update 5
=== [1/5] fresh kit copy -> /mnt/onetb/scratch/qpsk-build-trees/regen11/jupiter_byte_sp3_build ===
=== [2/5] KITDIR repoint ===
=== [3/5] MATLAB build_variant_byte (QPSK_LEAN=1; CreateProject fail EXPECTED) ===
  matlab exit=1 (nonzero at Create Project is expected)  elapsed=1443s
  byte reference-design BD confirmed (byte_breakout present)
=== [4/5] TXCAP -> DDRCAP (TXMARK=1) -> BD ports -> DDRCAP-v2 ===
=== [4a/5] rxfifo: BRAM drop-in ByteRxFifo (modem/rxfifo_inject.sh) ===
  zip patched: .../vivado_ip_prj/ipcore/TxRxCompo_ip_v1_0.zip
RXFIFO_INJECT_OK depth=4096 files+zips=5 verified_loose=3
    zip member TxRxCompo_ip_src_TxRxComposite.v              patched  (TxRxCompo_ip_v1_0.zip)
TXCAP_INJECT files=6 zip_members_patched=6 zips_found=2
    VERIFY_OK .../vivado_ip_prj/ipcore/TxRxCompo_ip_v1_0.zip
DDRCAP_INJECT loose_files=9 logical_groups_satisfied=8/8 zip_members_patched=18 zips_verified=2/2
  BD step deferred to [5] (--complete-bd)
    VERIFY_OK .../vivado_ip_prj/ipcore/TxRxCompo_ip_v1_0.zip
DDRCAP2_INJECT loose=7 missing=[] zips=2 zips_verified=2
BASE_REGEN_DONE tree=/mnt/onetb/scratch/qpsk-build-trees/regen11/jupiter_byte_sp3_build
=== [5] BD completion: complete_byte_bd -> ddrcap_bd -> seqbist_bd ===
  seqbist rtl qpsk_traffic_gen_v2.v md5=e085adeed456958354b53bc76d9615e5
  seqbist rtl rx_seq_checker.v md5=15aa6c6da8704fcebb8cc0f8a7b7a549
  seqbist rtl cnt_mux32.v md5=414ffbf5986992bb403389d54ae138f2
BUILD_HDL_BD_OK tokens=BYTE_WIRE_OK,WIRE_OK,VALIDATE_OK,DDS_DIET_OK,COMPLETE_BYTE_BD_DONE,DDRCAP_BD_WIRE_OK,SEQBIST_WIRE_OK
=== [6] kit assembly (modem/vivado templates) ===
BUILD_HDL_KIT_OK kit=/mnt/onetb/scratch/qpsk-build-trees/regen11/jupiter_byte_sp3_build variant=SP3
MODEL_OVERLAYS_OK W1 R4B/R4D R4DR1 BS PAD F3 all present in the generated RTL
BS_READY_PAD_OK
BASE_RTL_DIFF_SKIPPED (no --diff-bank; the sp3 pipeline does not consult the bank)
BUILD_HDL_DONE tree=/mnt/onetb/scratch/qpsk-build-trees/regen11/jupiter_byte_sp3_build
HDL_STAGE_EXIT=0
```

(The four long `.../` paths are the only elision: they are the same
`<tree>/hdl_prj_jupiter_composite` prefix as the `BASE_REGEN` line above.)

## Inside the one Vivado session (`<kit>/complete_bd.log`)

`build_hdl.sh` gates on eight tokens and prints the seven it checks by name in
`BUILD_HDL_BD_OK` above. The lines themselves, each appearing exactly once, in
source order:

```
BYTE_WIRE_OK
CYCLIC_RXBYTE_OK rx_byte_dma CONFIG.CYCLIC=1
WIRE_OK
VALIDATE_OK
DDS_DIET_OK
COMPLETE_BYTE_BD_DONE
DDRCAP_BD_WIRE_OK
DDRCAP_BD_VALIDATE_OK
SEQBIST_WITH_CRC 1
SEQBIST_RXSEQ_OK
SEQBIST_GPIO_OK tgen_ctrl_gpio    offset=0x9D400000 m_port=M11_AXI
SEQBIST_GPIO_OK tgen_rx_ctrl_gpio offset=0x9D410000 m_port=M12_AXI
SEQBIST_GPIO_OK tgen_rx_wit_gpio  offset=0x9D450000 m_port=M13_AXI
SEQBIST_CNTMUX32_OK num_mi=14
SEQBIST_WIRE_OK lineage=vendh
COMPLETE_BD_RUN_DONE
```

Read that list against the three scripts that produced it:

* `complete_byte_bd.tcl` contributes `BYTE_WIRE_OK` (all nine DUT byte ports
  driven), `CYCLIC_RXBYTE_OK`, `WIRE_OK` (the four stock DAC pins driven),
  `VALIDATE_OK`, `DDS_DIET_OK` and `COMPLETE_BYTE_BD_DONE`. The
  `create_bd_cell ... TxRxCompo_ip_0` that the whole ruling is about is inside
  it; `BYTE_WIRE_OK` cannot print unless that cell exists and every byte port on
  it is connected.
* `modem/instruments/ddrcap/ddrcap_bd.tcl` contributes `DDRCAP_BD_WIRE_OK` and
  `DDRCAP_BD_VALIDATE_OK`. This is the token that had **never** appeared on a
  regenerated tree before: the script aborts with "`TxRxCompo_ip_0` missing
  pins" when the cell does not exist, which is why it was a tolerated WARN in
  every earlier regen. It is a hard gate now, and it passes.
* `modem/instruments/seqbist/seqbist_bd.tcl` contributes the rest.
  `SEQBIST_WIRE_OK lineage=vendh` names the **BD-state** selector, not the
  board: `148` asserts the tgen/checker chain is already in `system.bd` and
  exits 1 otherwise, `vendh` asserts none of it is present and creates it. A
  tree just completed by `complete_byte_bd.tcl` has none of it. The sp3 image is
  still 148 board lineage (no MOVSUM TMR, as sp2A).

`SEQBIST_RETAP_CAPTURED` is **absent**, correctly: it fires only when a
pre-existing `traffic_gen` cell must be deleted and its net consumers re-tapped,
and a freshly completed BD has no such cell.

The log also carries 18 `ERROR: [BD 41-84] required object is not specified` /
`ERROR: [BD 5-4] Error: running connect_bd_net` lines. They are benign and
predicted: three GPIOs x two pins (ACLK, ARESETN) x three `catch`-ed per-master
pin spellings. `patch_seqbist_tcl.py`'s own comment says the design's
interconnect is a smartconnect with no per-master clock pins, "so the three
catches above are expected to miss". They are inside `catch`, and
`validate_bd_design` passes after them. Error counts by kind:

```
     18 ERROR: [BD 41-84]
     18 ERROR: [BD 5-4]
```

No other `ERROR:` of any kind. The `CRITICAL WARNING: [BD 41-1367] ... 'byte' ...
is a reserved keyword` lines are pre-existing in this reference design (they
name `byte_breakout`, `rx_byte_breakout` and `valid_regularizer`, none of which
this task touched).

## Independent re-verification against the SAVED system.bd

`build_hdl.sh` does not trust the log. After the Vivado session it greps the
saved block design and refuses on any miss:

```
grep -q 'TxRxCompo_ip_0' "$Z/vivado_prj.srcs/sources_1/bd/system/system.bd"
for c in rx_seq cnt_mux traffic_gen tgen_ctrl_gpio tgen_rx_ctrl_gpio tgen_rx_wit_gpio; do
  grep -q "\"$c\"" "$SBD" || BUILD_HDL_BD_FAIL
done
```

That is **one** `TxRxCompo_ip_0` check plus **six** SEQ-BIST cell checks, seven
in all, every one of which passed on this tree (the stage exits 1 on the first
miss, and it reached `BUILD_HDL_BD_OK`). For contrast, the same grep on the
pre-Task-11 regenerated tree
(`/mnt/onetb/scratch/qpsk-build-trees/regen/jupiter_byte_sp3_build.sps8`,
2026-09-11) returns **0** occurrences of `TxRxCompo_ip_0` — that measurement is
the controller's finding, and it is what this stage now fixes.

The stage then asserts the project carries no absolute source paths, since those
would not resolve on the Vivado host after the rsync. The seqbist sources came
out as tree-relative, which is why they are installed at the kit root rather
than referenced in place under `modem/rtl_sim/`:

```
<File Path="$PPRDIR/../../qpsk_traffic_gen_v2.v"
<File Path="$PPRDIR/../../rx_seq_checker.v"
<File Path="$PPRDIR/../../cnt_mux32.v"
```

## Kit assembly — what makes the vivado stage possible

`BUILD_HDL_KIT_OK` means the tree is a build kit: `build_txfix.sh` and
`build_txfix.tcl` installed from `modem/vivado/*.tmpl`, `timing_gate.tcl` at the
kit root (`build_txfix.tcl` sources it via `[file dirname [info script]]`),
`TXFIX_VARIANT` (`SP3` — `build_txfix.sh` exits 1 without it), `SEQBIST_VARIANT`,
`seqbist_bd.tcl` and the three SEQ-BIST `.v`. Verified present on the tree at
02:47, immediately before the remote launch:

```
build_txfix.sh  build_txfix.tcl  timing_gate.tcl  TXFIX_VARIANT  SEQBIST_VARIANT
seqbist_bd.tcl  cnt_mux32.v  rx_seq_checker.v  qpsk_traffic_gen_v2.v
```

## Provenance of these quotes

| | |
| --- | --- |
| source files | `work_sp3/{STAMP.hdl,STAMP.vivado,build_hdl_stage2.out}`, `<kit>/complete_bd.log` |
| snapshot | `/mnt/onetb/scratch/qpsk-build-trees/work_sp3_evidence/` (taken 2026-09-12 03:45) |
| hdl unit | `sp3-hdl-r2-021351.service`, nemo, 02:13 → 02:47 |

**Why the snapshot exists.** At 03:25 a runaway `modem/build_image.sh --tag sp3`
started and `rm -rf`'d `regen11/jupiter_byte_sp3_build`, destroying the tree the
banked image was built from — `complete_bd.log` included. Cause, and it was
mine: a Bash tool call used an **unquoted** heredoc delimiter (`python3 - <<PYEOF`
rather than `<<'PYEOF'`) to write prose containing backticked paths, so zsh
command-substituted the prose and executed
`` `modem/build_image.sh --tag sp3 --remote-base …` `` as a command. Killed at
03:45 along with its MATLAB child; `work_sp3/hdl.log` was the only work_sp3 file
it overwrote, and the files quoted above survived and were snapshotted
immediately. The banked BOOT.BIN, its md5, its timing reports and both STAMPs
were written before 03:25 and are untouched.

The same prose also contained `` `ops/flash/flash_148_txfix.sh` ``, which was
therefore executed with no arguments. **No board was touched**: the rail's first
statement is `EXP=${FLASH_MD5:?}` and it exits immediately with
`FLASH_MD5: parameter null or not set`, above every `ssh`. Confirmed by
`ops/flash/` carrying no flash log newer than 2026-09-10.

The rebuildable consequence: `regen11/jupiter_byte_sp3_build` no longer holds
the tree the banked image came from. The image, its md5, its timing reports and
`model_tree_sha=144c89e8fe98317d` are all intact, and the tree is reproducible
by `modem/build_image.sh --tag sp3 --stop-after hdl` at git `ba4e056c`.
