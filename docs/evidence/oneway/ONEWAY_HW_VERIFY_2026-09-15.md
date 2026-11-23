# One-directional test images: silicon verification, 2026-09-15

Branch `oneway-images-2026-09-15` (4a1dce6a + the rig-run fixes committed after it).
Runbook: `ops/oneway_hw_verify.sh both` as rig unit `oneway-hwverify-202806`; full log
`/mnt/onetb/scratch/qpsk-build-trees/oneway/hw_verify.log`. Operator authorised the flashes
("verify on hardware when we have the available boot files"); pair restored afterwards.

## Images

| Role | File (images/) | md5 | Gate 2 modem-clock WNS |
|---|---|---|---|
| TXO | `BOOT.BIN.jupiter.sp3txonly.8126659ac9c65c34775b5c85acc0f185` | `8126659ac9c6…` | 2.89 ns, 0 failing / 18,636 |
| RXO | `BOOT.BIN.jupiter.sp3rxonly.8affa3e59582d46fc238674024df4ee3` | `8affa3e59582…` | 0.744 ns, 0 failing / 74,763 |

Both built from `modem/dev` with `QPSK_ONEWAY=tx|rx` (`build_image.sh --oneway`), git 916b39a0
model tree; hdl stage `BUILD_HDL_BD_OK` (no ddrcap token), `MODEL_OVERLAYS_OK` (stubbed half
exempt), RXO `BS_READY_PAD_OK depth=2` (drop-in FIFO mirrored at the measured chain), TXO
`byte_ready` pin lag 8 (unchanged). Gate 1 replaced by the pair simulation
(`SIM_ONEWAY_PAIR_GATE.txt`: packets=5 errLate=0 cap_out=0x04922282 golden, byte_rx_words=849).

## Forward leg: 146 (TXO) -> 148 (RXO), LO 2.000 / 2.000020 GHz

Arm gate: PASS on try 3 at 1247 f/s (the ROM double-tap; tries 1-2 below 1120 f/s).

```
oneway_measure.sh 10.0.0.148 120 rom
rom: samples=121 clean_s=120 resets_s=0 frames=151748 expected=149400 lost=0 PER_est=0.000%
     biterr=0 bits=18209760 BER_120win=0.00000% golden_frac=0.000 fps_mean=1265
health: fsync=1261 wcnt=0 resets_s=0/12 clean=12/12
```

Byte source (`qpsk_tun -B` on 146, scorer on 148, 60 s):

```
frames_scored=74720  aligned(clean+noisy)=74708  total_bits=76500992  bit_errors=3  BER=3.922e-08
expected 1245 f/s * 60 s = 74700 -> lost = 0
```

## Reverse leg: 148 (TXO) -> 146 (RXO), LO 1.900 / 1.900040 GHz

Arm gate: PASS on try 2 at 1248 f/s.

```
oneway_measure.sh 10.0.0.146 120 rom
rom: samples=121 clean_s=116 resets_s=4 frames=147154 expected=144420 lost=0 PER_est=0.000%
     biterr=867 bits=17658480 BER_120win=0.00491% golden_frac=0.000 fps_mean=1269
health: fsync=1264 wcnt=0 resets_s=0/12 clean=12/12
```

Byte source (`qpsk_tun -B` on 148, scorer on 146, 60 s):

```
frames_scored=74723  aligned(clean+noisy)=74710  total_bits=76503040  bit_errors=2  BER=2.614e-08
expected 1245 f/s * 60 s = 74700 -> lost = 0
```

## Reading

* Denominators: ROM = 1245 f/s x reset-free seconds with lost frames counted (none were
  lost; the receiver counted MORE detected frames than expected because 0x104 counts
  detections and the TX cadence runs a hair above 1245). Byte = frames_scored vs the
  expected 74,700; lost = 0 both legs.
* Bit errors: forward ROM 0 in 18.2 Mbit of BIST window; reverse ROM 867 in 17.7 Mbit
  (4.9e-5) with 4 reset intervals excluded -- the reverse leg is the known weaker RF leg
  (146 antenna, see the sp3 Gate 3 retest); the byte scorer over the whole 2240-bit
  frame saw 2-3 bit errors in 76.5 Mbit on both legs (2.6e-8 / 3.9e-8).
* `golden_frac=0.000`: 0x144 never read 0x04922282 on either RX-only board. The BIST
  digest is an arm-state value (memory: no constant golden across arms) and the
  RX-only image drives its Transmitter stub, so this field is informational here;
  the pair SIMULATION reproduces the golden.
* `wcnt=0` in the health probe: the byte-plane word counter 0x1C0 only advances with a
  byte DMA consumer, which the one-way ROM test does not run; fsync is the live metric.
* Byte-plane on the RX-only image worked end to end (74.7 k frames scored per leg), which
  is the direct silicon proof for the mirrored 2-deep FIFO chain.

## Restore

The first restore attempt failed BEFORE touching the boards: `deploy_image.sh` sized the
role-B image with `stat -c %s`, which on the worktree's symlinked image returned the
58-byte link length and refused. Fixed (`stat -L`); restore re-run as unit
`oneway-restore-204723` (see the end of the log and the section below).

## Second pass (unit `oneway-restore-204723`, 20:47-21:08)

The restore-only relaunch read its mode from the wrong place (fixed: `MODE` env now
honoured) and re-ran the full two-leg test before restoring. Second sample, same procedure:

| Leg | Arm gate | ROM 120 s | Byte 60 s |
|---|---|---|---|
| 146 -> 148 | try 1, 1247 f/s | frames=151756 lost=0 biterr=0 resets=0 | frames_scored=74712 lost=0 bit_errors=0 |
| 148 -> 146 | try 2, 1247 f/s | frames=152276 lost=0 biterr=0 resets=0 | frames_scored=74714 lost=0 bit_errors=3 (3.9e-08) |

The reverse leg's 867 window errors in pass 1 did not recur (0 in pass 2, 0 reset seconds):
consistent with the episodic RF reverse-leg class, not the image.

## Restore result

`deploy_image.sh 10.0.0.146 B` and `10.0.0.148 A` (both sp3txclk cae8c4fdac09, md5 read back),
`bringup_r2r3.sh r3`: ARM GATE PASS (try 1), byte source live both ends.

```
restore health: 146 fsync=1267 wcnt=1267 resets_s=0/12 clean=12/12
                148 fsync=1263 wcnt=1263 resets_s=0/12 clean=12/12
after: 146=cae8c4fdac0983f6010898a9dcb822e8 148=cae8c4fdac0983f6010898a9dcb822e8
```

SENTINEL_STOP released 21:09. Rollback copies of the pre-test image sit on each board as
`/boot/BOOT.BIN.oneway` (identical to the restored image).

## Verdict

Both one-way images work on silicon in both directions: ROM frames delivered at 1245+ f/s with
zero lost frames over 4 x 120 s, and the host byte plane (`qpsk_tun -B`) scored 4 x ~74.7 k
frames with 0-3 bit errors per 76.5 Mbit. Flash with `deploy_image.sh <ip> TXO|RXO`, bring up
with `oneway_bringup.sh`, measure with `oneway_measure.sh`; put the pair back with
`oneway_hw_verify.sh restore`.

## 2026-09-17: IP over the one-way link (tun), forward leg 146 TXO -> 148 RXO

`qpsk_tun` gained `QPSK_TUN_TXONLY=1` / `QPSK_TUN_RXONLY=1` (host/qpsk_tun.c); `oneway_bringup.sh
... tun` starts one half per board, `oneway_measure.sh ... tun` pushes a paced UDP stream with
`qpsk_perf` (88-byte datagrams, one air frame each, 400 kb/s). Three runs of
`oneway_hw_verify.sh fwd TUN=1` (each flashes TXO/RXO, ROM gate, tun phase, restore):

| run | RX daemon mode | client tx_pkts | server rx_pkts | verdict |
|---|---|---|---|---|
| 1 | -M 16 queued | 34,091 | (server never printed: `qpsk_perf -s` ignores -t, needs SIGINT) | measurement bug, fixed |
| 2 | -M 16 queued (QPSK_RX_QUEUED=1) | 34,091 | **0** -- RX daemon dma_rx_ok=1, crc_drop=50,318, idle_rx=7,313 | data frames CRC-dropped in multi-packet mode |
| 3 | **-M 0 legacy per-packet** | 34,091 | **34,078, lost 13, dup 0, reorder 0 (PER 0.038 %)** -- RX daemon dma_rx_ok=33,161, crc_drop=5,299, idle_rx=51,897 | **PASS** |

TX side in all runs: tunA_rx = every UDP packet, dma_tx ~100k (data + keepalives), tx_stall 0.
Finding: on the RX-only image the queued 16-packet capture decodes idle frames but fails every
DATA frame's CRC, while per-packet TLAST capture delivers. The RXO image's byte-plane pad is
2 deep (the full image's is 4; `rxfifo_inject.sh` mirrors the measured depth), and the
multi-packet path locates frames by scanning the landing buffer -- the likely interaction, not
yet root-caused. The tun source therefore defaults the RX-only daemon to `-M 0`
(`RXM`/`RXQ` override). Pair restored to sp3prod after each run.
