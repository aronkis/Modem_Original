# One-directional test images: silicon verification, 2026-10-01 (sp3clamp004 one-way pair)

Runbook `ops/oneway_hw_verify.sh both` inside rig unit `evening-165244` (`ops/r3cap/evening_20261001_1652/oneway_hw_verify.log`;
full log `/mnt/onetb/scratch/qpsk-build-trees/oneway/hw_verify.log`), 16:54-17:21. Operator authorised
("Do 2,3,4"); pair restored to the `images/CURRENT.txt` roles (sp3clamp004 `8503f226395c` on both) afterwards.
Carrier plan of the day: forward 2.100 / 2.100020 GHz, reverse 1.850 / 1.850040 GHz (`ops/rung_table.sh`, PR #90).

## Images

| Role | File (images/) | md5 | Gate 2 modem-clock WNS |
|---|---|---|---|
| TXO | `BOOT.BIN.jupiter.sp3clamp004txo.512fce05378ddec29eb5a1ddbf419abf` | `512fce05378d…` | 2.684 ns |
| RXO | `BOOT.BIN.jupiter.sp3clamp004rxo.b985971fa137859c69abbdec30b4b900` | `b985971fa137…` | 1.217 ns |

Both `build_image.sh --oneway tx|rx` at f1536 / 4 sps from dev `8d6f6a4f` -- the 09-15 pair plus the symbol-sync
integrator clamp 0.004 (`docs/evidence/link/CARRIER_LOCK_LATCH_2026-09-29.md`) and every dev overlay merged since.
`timing_hardening_overlay: IntegClamp limit 0.06 -> +-0.004` in both assembles; pair-sim gate
`SIM_ONEWAY_PAIR_GATE.txt` 01-Oct 14:34 PASS (packets=5 errLate=0 cap_out=0x04922282 golden, byte_rx_words=849, both
stubs inert) in place of Gate 1, as the one-way chain requires.

## Forward leg: 146 (TXO) -> 148 (RXO), LO 2.100 / 2.100020 GHz

Arm gate PASS on try 1 at 1246 f/s (09-15: try 3).

| phase | command | denominator | result |
|---|---|---|---|
| ROM | `oneway_measure.sh 10.0.0.148 120 rom` | expected 1245 f/s × 120 clean s, lost counted, 0 reset intervals | frames 151,743, **PER_est 0.000 %, BER (120-bit window) 0.00000 %** |
| byte (`qpsk_tun -B`) | `oneway_measure.sh 10.0.0.148 60 byte` | expected 74,700, lost = 0 counted | frames 74,715, **BER 9.15e-8** |
| tun/UDP | `oneway_measure.sh 10.0.0.148 60 tun` | client tx_pkts 34,091; lost = tx − rx counted | rx 34,047, **PER 0.129 % (44/34,091)**, 400 kb/s |

## Reverse leg: 148 (TXO) -> 146 (RXO), LO 1.850 / 1.850040 GHz

Arm gate PASS on try 1 at 1247 f/s (09-15: try 2; 09-25 re-verification: UNVERIFIED, 148 hung mid-leg).

| phase | command | denominator | result |
|---|---|---|---|
| ROM | `oneway_measure.sh 10.0.0.146 120 rom` | 1245 f/s × 120 clean s, lost counted, 0 reset intervals | frames 152,271, **PER_est 0.000 %, BER 0.00000 %** |
| byte | `oneway_measure.sh 10.0.0.146 60 byte` | expected 74,700, lost = 30 counted | frames 74,670, **BER 2.62e-8** |
| tun/UDP | `oneway_measure.sh 10.0.0.146 60 tun` | tx_pkts 34,091; lost = 0 counted | rx 34,091, **PER 0.000 %**, 400 kb/s |

## Reading

* Both directions now verified on the clamp-0.004 one-way images; the reverse direction, unverified since 09-15,
  passes all three phases, and its ROM BER is 0 where the 09-15 run read 4.9e-5 with 4 reset intervals (the
  reverse carrier was 1.9 GHz then, 1.85 now; the receiver no longer latches).
* The forward tun phase lost 44 of 34,091 packets (0.129 %) with ROM and byte phases clean -- the forward link's
  residual CRC class (`FORWARD_LINK_2026-10-01.md` §7, ~0.04-0.05 % of frames, noise-limited) shows up at the
  packet level with the 1.5-frame UDP packets; the reverse direction lost none.
* `PER_est`, `BER_120win` and `golden_frac` carry the 09-15 caveats (0x104 counts detections; the BIST window is
  the first 120 bits; the golden is an arm-state value).

## Restore

`deploy_image.sh` both boards from the CURRENT roles (`8503f226395c`, read back), pair bring-up at r3, arm gate
PASS try 1, byte re-arm both ends, watchdogs relaunched from the freshly provisioned `/root/lock_watchdog.sh`
(`9ae7f2fbb792`, the #81 version with the re-arm register snapshot). Trigger re-armed; a 12 h soak followed.
