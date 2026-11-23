# sp4 Gate 0: regen at sps 2 / f3072, 2026-09-19

`build_image.sh --tag sp4 --tree dev --stop-after hdl` (regen parent `/mnt/onetb/scratch/qpsk-build-trees/regen_sp4`,
kit `jupiter_byte_sp4_build`, git f2989a0b). Two runs: the first stopped at the DDRCAP-v2
injector (14-bit record vs the ufix15 timing offset of a 24634-slot window; fixed by the frame-selected
15-bit layout, commit ae2996bd); the second passed every token:

```
BASE_REGEN matlab=25.2.0.3177638 (R2025b) Update 5
  matlab exit=1 (nonzero at Create Project is expected)  elapsed=1295s
RXFIFO_INJECT_OK depth=8192 chain=4 files+zips=5 verified_loose=3
TXCAP_INJECT files=6 zip_members_patched=6 zips_found=2
DDRCAP_INJECT loose_files=9 logical_groups_satisfied=8/8 zip_members_patched=18 zips_verified=2/2
DDRCAP2_INJECT loose=7 missing=[] zips=2 zips_verified=2
BUILD_HDL_BD_OK tokens=BYTE_WIRE_OK,WIRE_OK,VALIDATE_OK,DDS_DIET_OK,COMPLETE_BYTE_BD_DONE,DDRCAP_BD_WIRE_OK,SEQBIST_WIRE_OK
TXCLK_KIT_OK pre_synth.tcl txclk_bd.tcl
BUILD_HDL_KIT_OK kit=/mnt/onetb/scratch/qpsk-build-trees/regen_sp4/jupiter_byte_sp4_build variant=SP3
MODEL_OVERLAYS_OK W1 R4B/R4D R4DR1 BS PAD F3 all present in the generated RTL
BS_READY_PAD_OK depth=4
BUILD_HDL_DONE tree=/mnt/onetb/scratch/qpsk-build-trees/regen_sp4/jupiter_byte_sp4_build
TASK5_HDL_DONE rc=0 2026-09-19T17:09:34-04:00
```

## The rung in the generated RTL (the change census against sps 4)

| what | generated at f3072 / sps 2 | at f1536 / sps 4 |
|---|---|---|
| Rate_Handle counter | `reg  HDL_Counter_out1;  // ufix1` (mod-2) | `reg [1:0] HDL_Counter_out1; // ufix2` (mod-4) |
| PdPopIndex full compare | numEntries == 24634 | 12333 |
| ByteSerializer words per frame | 16'd382 | 191 |
| Peak_Search timingOffset / p1c_tref | ufix15 | ufix14 |
| Rate Handle pop | RxSteerOccFloor present (3 refs) | absent |
| ByteRxFifo drop-in | depth 8192, chain 4 | depth 4096, chain 4 |
| DDRCAP-v2 record | 15-bit layout | 14-bit layout |
| generated files | 190 | 190 |

Model-level facts printed by the assemble in the kit log (`build_byte_matlab.log`): Rsym 7.68e6 x sps 2 = rail
15.36e6, WPP382, ROM 1538 words, preamble 26 symbols (energy window 26/24), resolver look-back 6 extra
samples, SSKp 1.35, RRC 0.25/8 (17 taps). Pre-synthesis gates: `ASSEMBLE_240K5_BYTE PRE-SYNTH GATES OK`.
Sweep evidence: `GATE0_SWEEP_2026-09-19.md` (22/23 cells + the documented last-slot corner).
