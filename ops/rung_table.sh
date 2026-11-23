#!/bin/bash
# =============================================================================
# rung_table.sh -- THE ONE rate-rung table for the rig rails (sourced, or run).
#
#   . ops/rung_table.sh; rung_set r4     -> sets the variables below (return 2 = unknown rung)
#   ops/rung_table.sh r4                 -> prints them as KEY=VALUE lines (tests, shell eval)
#   rung_from_ksym 30720                 -> prints the rung whose -r value that is (r4)
#
#   RUNG        r2 | r3 | r4
#   PROF        ADRV9002 stream/profile pair on the boards (/root/$PROF.{bin,json})
#   FS          ADC/DAC sample rate (Hz)
#   KSYM        qpsk_tun -r value (ksym/s = symbol rate / 1000)
#   SPS         samples per symbol in the fabric
#   FRAME       host/fabric frame geometry (f1536 = 12333 slots x 4 sps, f3072 = 24634 x 2)
#   SPF         samples per frame at FS (align_frames.py --spf; frame period = SPF / FS)
#   FPS         frames per second on the air (FS / SPF, rounded)
#   GATE_FPS_DEFAULT  bring-up arm-quality gate (90 % of FPS)
#   TUN_GFLAG   qpsk_tun geometry flag (-G = f1536, -G3 = f3072)
#   CARVE_MB / CARVE_CFLAG  host DMA carve the daemon is built for (dtb must match)
#   MTU / ADVMSS  tun0 MTU (= QPSK_FRAME_MAX_PAYLOAD of the frame) and TCP advmss (MTU - 40)
#   PERF_BPS    capture_r3.sh saturating-traffic rate (qpsk_perf -b), ~ the link's payload rate
#   LO_A_RX_DEFAULT / LO_B_RX_DEFAULT  the per-rung RX LO plan. The demod has a DEAD ZONE at
#          residual CFO ~= 0 (bringup_r2r3.sh header: CFC dither, 0x154 sign-flips, sync collapse),
#          so both RX residuals are deliberately offset. r4 needs a BIGGER offset in Hz than r3 for
#          the same margin: at 2 sps the symbol rate is doubled, so a given Hz offset is HALF the
#          normalised offset it was at 4 sps. Measured (docs/evidence/sp4/ACQUISITION_COLLAPSE.md).
#   LO_A_TX_DEFAULT / LO_B_TX_DEFAULT  the per-rung TX carriers (148 transmits the REVERSE leg, 146
#          the FORWARD leg). 2026-09-29: the r2/r3 reverse carrier moved from 1.9 GHz to 1.85 GHz.
#          The reverse leg's weeks of collapse were a frequency NOTCH at 1.9 GHz -- interference
#          signature: 1850 and 1950 both clean either side of it, and the same notch appeared on
#          148's receiver when the forward leg was moved onto 1.9 GHz -- and at 1.85 GHz the reverse
#          leg ran 10 of 10 fault-paired measurements clean (613 s at 0.004 %, zero resets) with
#          the forward leg unaffected by the plan. 1950/2050 are NOT usable (50 MHz TX-RX spacing
#          raises each board's self-leakage ~13-15 dB). The +40 kHz RX offset carries over as-is.
#          r4 keeps its own, unmeasured-at-1850 plan. docs/evidence/link/OVERNIGHT_CAMPAIGN_2026-09-29.md,
#          GATE3_REVERSE_PLAN_2026-09-29.md.
#   SRO_SIGN_CONF  the per-rung sro_sign (R4B/R4D steering) profile ops/sro_sign.sh reads. r2/r3 keep
#          profiles/sro_sign.conf (148=R4B, 146=R4D); r4 uses profiles/sro_sign.r4.conf (BOTH R4D --
#          docs/evidence/sp4/GATE1.md sec 3a). A value already in the environment always wins.
#
# The on-board daemon binary is /root/host_app_k5/qpsk_tun at EVERY rung (17 rails pkill/pgrep
# it by that exact name); the rung's CARVE_CFLAG selects the build (capture_r3.sh /
# provision.sh rebuild it on the board), and the binary carries the literal
# "<CARVE_CFLAG> build requires" (the carve guard's FATAL text) so a rail can verify which
# build is deployed with `strings`.
#
# FORWARD CARRIER 2.1 GHz at r2/r3 (and r4, 2026-10-02: the chain is the same radios) since 2026-10-01 (docs/evidence/link/FORWARD_LINK_2026-10-01.md): the 2.0 GHz
# forward link lost 1.5-2.4 % (18 % at 2.05) from 09-29 evening on every image while 2.1 GHz read its 0.03 %
# baseline; _LOA = 148 RX (+20 kHz off-null kept), _LOBT = 146 TX; r4 keeps its +60 kHz RX offset (2100060000). Gated at r4 by the sp4clamp004 Gate 3.
#
# r4 (sp4, 2026-09-22): f3072 at 2 sps on the SAME 61.44 MSPS profile as r3 -- the symbol rate
# doubles (30.72 Msym/s), the frame is 24634 slots / 49268 samples, so the frame rate is the
# same ~1247 f/s; the host frame is 3056 B (MTU 3044) on a 4 MB carve (images/CURRENT.txt DTB rows).
# =============================================================================
rung_set(){
  case "$1" in
    r2) PROF=lvds_30p72_fdd_jupiter; FS=30720000; KSYM=7680;  SPS=4; FRAME=f1536; SPF=49332; FPS=623
        TUN_GFLAG=-G;  CARVE_MB=2; CARVE_CFLAG=-DQPSK_CARVE_2MB; MTU=1516; ADVMSS=1476; PERF_BPS=7500000; _SSC=sro_sign.conf; _LOA=2100020000; _LOB=1850040000; _LOAT=1850000000; _LOBT=2100000000 ;;
    r3) PROF=lvds_61p44_fdd_jupiter; FS=61440000; KSYM=15360; SPS=4; FRAME=f1536; SPF=49332; FPS=1245
        TUN_GFLAG=-G;  CARVE_MB=2; CARVE_CFLAG=-DQPSK_CARVE_2MB; MTU=1516; ADVMSS=1476; PERF_BPS=15000000; _SSC=sro_sign.conf; _LOA=2100020000; _LOB=1850040000; _LOAT=1850000000; _LOBT=2100000000 ;;
    r4) PROF=lvds_61p44_fdd_jupiter; FS=61440000; KSYM=30720; SPS=2; FRAME=f3072; SPF=49268; FPS=1247
        TUN_GFLAG=-G3; CARVE_MB=4; CARVE_CFLAG=-DQPSK_CARVE_4MB; MTU=3044; ADVMSS=3004; PERF_BPS=30000000; _SSC=sro_sign.r4.conf; _LOA=2100060000; _LOB=1900080000; _LOAT=1900000000; _LOBT=2100000000 ;;
    *)  echo "unknown rung '${1:-}' (r2|r3|r4)" >&2; return 2 ;;
  esac
  RUNG=$1; GATE_FPS_DEFAULT=$(( FPS * 90 / 100 ))
  # an explicit SRO_SIGN_CONF in the environment always wins (the tx_ssi_row idiom)
  [ -n "${SRO_SIGN_CONF:-}" ] || SRO_SIGN_CONF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/profiles/$_SSC"
  LO_A_RX_DEFAULT=$_LOA; LO_B_RX_DEFAULT=$_LOB; LO_A_TX_DEFAULT=$_LOAT; LO_B_TX_DEFAULT=$_LOBT
  export RUNG PROF FS KSYM SPS FRAME SPF FPS GATE_FPS_DEFAULT TUN_GFLAG CARVE_MB CARVE_CFLAG MTU ADVMSS PERF_BPS SRO_SIGN_CONF LO_A_RX_DEFAULT LO_B_RX_DEFAULT LO_A_TX_DEFAULT LO_B_TX_DEFAULT
}
rung_from_ksym(){
  case "$1" in 7680) echo r2 ;; 15360) echo r3 ;; 30720) echo r4 ;; *) return 1 ;; esac
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  rung_set "${1:-}" || exit 2
  for v in RUNG PROF FS KSYM SPS FRAME SPF FPS GATE_FPS_DEFAULT TUN_GFLAG CARVE_MB CARVE_CFLAG MTU ADVMSS PERF_BPS SRO_SIGN_CONF LO_A_RX_DEFAULT LO_B_RX_DEFAULT LO_A_TX_DEFAULT LO_B_TX_DEFAULT; do
    eval "echo $v=\$$v"
  done
fi
