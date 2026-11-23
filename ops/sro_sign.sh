#!/bin/bash
# =============================================================================
# sro_sign.sh -- bring-up writes fixctl (0x208) bit 5, sro_sign, per board from
# ops/profiles/sro_sign.conf, and cross-checks the choice against the measured
# CFC residual (Task 12, cleanup sub-project 3 / model back-port).
#
# fixctl (0x208) IS WRITE-ONLY ON THE BUS. There was NO shadow convention
# anywhere in ops/ or host/ before this task (checked 2026-09-11/12: the only
# other 0x208 writer in the tree is ops/flash/arm148_mode1.sh, which writes
# the FULL WORD 0x0 -- it clears every fixctl bit, including this one, and is
# out of this task's file scope to change). This script OWNS the convention
# from here on: every write to 0x208 goes through fixctl_write() below, which
# writes the given word AND records it verbatim in /dev/shm/fixctl.word on the
# target board. A reader (this script, or any future one) treats that file's
# last line as the last-written fixctl word; if it is missing (fresh boot, or
# a writer -- e.g. arm148_mode1.sh -- that does not use this convention) the
# shadow is UNKNOWN and this script assumes 0x0, which is only ever wrong if
# some other bit (w1_freeze, bit 4) was set by a path outside this convention;
# document that residual risk rather than hide it.
#
# THE STALE-SHADOW CASE. /dev/shm is tmpfs: it survives everything short of a
# reboot. A fabric SOFT RESET clears the 0x208 register but does NOT touch
# /dev/shm/fixctl.word, so after one the shadow OVER-STATES the register --
# it still claims w1_freeze (or any other bit) is set when the hardware has
# forgotten it. The read-modify-write below would then write those stale bits
# back and silently re-assert them as a side effect of setting sro_sign.
#
# Bring-up and restore ALWAYS follow a reset, so on that path the shadow is
# known-wrong by construction and the correct prior is 0x0, not whatever the
# file remembers. `--bringup` re-seeds the shadow to 0 before the read-modify-
# write and prints SRO_SIGN_RESEED; ops/bringup_r2r3.sh and
# ops/restore_known_good.sh pass it. This DISCARDS remembered bits on purpose:
# nothing else in the tree sets them at that point in the sequence, and
# re-asserting a forgotten w1_freeze would be worse than dropping it.
#
# The plain `sro_sign.sh <ip>` path is unchanged and still trusts the shadow:
# it is the mid-session path, where the register and the file agree.
#
# Usage:
#   sro_sign.sh <ip>                 write sro_sign from the conf, verify readback
#   sro_sign.sh <ip> --bringup       as above, but re-seed the fixctl shadow to
#                                    0 first (bring-up/restore always follow a
#                                    fabric reset, which clears 0x208 while
#                                    /dev/shm/fixctl.word survives); prints
#                                    SRO_SIGN_RESEED before the write
#   sro_sign.sh <ip> --read          read the shadow + 0x25C only, no write
#   sro_sign.sh <ip> --force <0|1>   write the given value regardless of the
#                                    conf (Task 13's manual override); prints
#                                    SRO_SIGN_FORCED instead of SRO_SIGN
#   sro_sign.sh --check <ip>         cross-check: CFC (0x154) mean over 10 s at
#                                    1 s cadence vs. the leg's deliberate RX-LO
#                                    offset (bringup_r2r3.sh LO_A_RX/LO_B_RX
#                                    minus the PEER's transmit carrier from
#                                    ops/rung_table.sh: 2.0 GHz for 148, 1.85 GHz
#                                    for 146 at r2/r3 since 2026-09-29); prints
#                                    "SRO_SIGN_CHECK <ip> residual=<n> units=reg
#                                    cfc_mean=<n> lo_offset_hz=<n> implies=<0|1>
#                                    conf=<0|1> AGREE|DISAGREE" (units=hz if a
#                                    register-to-Hz scale is ever documented).
#                                    DISAGREE is a WARNING line -- it never
#                                    changes anything.
#
# CFC UNITS: ms_regmap.c's 0x154 row ("cfc", MS_F_SNAP, "coarse frequency
# compensator estimate") carries no documented register-to-Hz scale anywhere
# in the tree (checked host/modem_status/ms_regmap.c, ms_render.c,
# docs/bringup.rst); test_modem_status.c's golden output prints it as a bare
# signed integer ("cfc 154 -3301"), not a frequency. So the cross-check here
# is expressed in RAW REGISTER UNITS, SIGN ONLY: negative implies sro_sign=0
# (EMPTY-edge / oscillator fast), positive implies sro_sign=1 (FULL-edge). The
# LO offset is reported alongside for context (it is the deliberate, sign-known
# perturbation that keeps the link off the CFO dead zone) but is NOT combined
# arithmetically with cfc_mean -- the two are in different, unrelated units.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd)
W=${W:-$D/anyssh.sh}
BRINGUP=$D/bringup_r2r3.sh
CONF=${SRO_SIGN_CONF:-$D/profiles/sro_sign.conf}
A=10.0.0.148; B=10.0.0.146
SRO_SIGN_BIT=5

conf_value(){ # $1 ip -> prints 0/1, exit 1 if not in the conf
  awk -v ip="$1" '
    /^[[:space:]]*#/ {next} NF<2 {next}
    $1==ip {print $2; found=1}
    END{exit(found?0:1)}' "$CONF"
}

# --- the fixctl shadow convention (this script owns it from here on) -------
fixctl_write(){ # $1 ip  $2 hex word, e.g. 0x20 -- writes 0x208 and, ONLY if that
                 # write succeeds, records it in the shadow -- both inside the SAME
                 # remote script, so a failed register write can never leave a
                 # shadow that claims a word was written when it was not (a false
                 # shadow would corrupt the next read-modify-write's "other bits").
                 # Returns nonzero, with the shadow left untouched, on failure.
  out=$($W "$1" "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
 echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
 if echo '0x208 $2' > \$DRA; then
   printf '%s\n' '$2' > /dev/shm/fixctl.word
 else
   echo FIXCTL_WRITE_FAILED
   exit 1
 fi" 2>/dev/null)
  rc=$?
  case "$out" in *FIXCTL_WRITE_FAILED*) return 1 ;; esac
  [ $rc -eq 0 ]
}

fixctl_shadow(){ # $1 ip -> last word written via fixctl_write, or 0x0 if unknown
  s=$($W "$1" 'cat /dev/shm/fixctl.word 2>/dev/null' 2>/dev/null | tr -d '\r\n[:space:]')
  [ -n "$s" ] && printf '%s' "$s" || printf '0x0'
}

read_sro_mode(){ # $1 ip -> raw 0x25C readback
  $W "$1" 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
 echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
 echo 0x25C > $DRA; cat $DRA' 2>/dev/null | tr -d '\r\n[:space:]'
}

read_cfc(){ # $1 ip -> raw 0x154 readback
  $W "$1" 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
 echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
 echo 0x154 > $DRA; cat $DRA' 2>/dev/null | tr -d '\r\n[:space:]'
}

cfc_mean(){ # $1 ip -> "<mean> <valid> <wanted>" -- the integer mean of the VALID
            # reads of 0x154, SIGN-EXTENDED as int32, plus how many of the
            # SRO_CHECK_SAMPLES (default 10 @ 1 s) reads actually produced a
            # number. do_check() classifies; this function never decides.
            #
            # SIGN EXTENSION. 0x154 is a 32-bit signed register; the raw text a
            # DRA read prints ("0xFFFFED1E" etc.) is unsigned as far as $(( v ))
            # is concerned, and bash arithmetic is 64-bit, so it never wraps --
            # every negative reading was silently averaged and compared as a
            # huge POSITIVE number before that fix, which inverted every
            # implies=/AGREE|DISAGREE verdict this function had ever printed
            # (docs/evidence/sp3/SP3_SILICON.md section 10). Any reading with
            # bit 31 set (>= 2^31) is a negative int32: subtract 2^32.
            #
            # FAILED READS. read_cfc() prints the EMPTY string when the ssh or
            # the DRA read fails, and `vv=$(( v )) || vv=0` then folded that
            # into the average as a genuine 0 sample -- a board that answered
            # nothing at all averaged to exactly 0 and was reported as a
            # confident positive sign (0 is not < 0). A read that does not
            # produce an integer is now DISCARDED and does not increment the
            # valid count, so do_check() can tell "no signal" from "a signal
            # that happens to be near zero".
  ip=$1; n=${SRO_CHECK_SAMPLES:-10}; slp=${SRO_CHECK_SLEEP:-1}
  sum=0; got=0; i=1
  while [ $i -le "$n" ]; do
    v=$(read_cfc "$ip")
    case "$v" in
      0[xX]*[!0-9a-fA-FxX]*|"") v="" ;;              # junk, or nothing at all
      0[xX]*) ;;                                     # hex, fine
      -*[!0-9-]*|*[!0-9-]*) v="" ;;                  # not a decimal integer
      -|"") v="" ;;
    esac
    if [ -n "$v" ]; then
      if vv=$(( v )) 2>/dev/null; then
        if [ "$vv" -ge 2147483648 ] 2>/dev/null; then vv=$(( vv - 4294967296 )); fi
        sum=$(( sum + vv )); got=$(( got + 1 ))
      fi
    fi
    [ $i -lt "$n" ] && sleep "$slp"
    i=$(( i + 1 ))
  done
  if [ $got -gt 0 ]; then echo "$(( sum / got )) $got $n"; else echo "0 0 $n"; fi
}

lo_rx_offset(){ # $1 ip -> deliberate RX-LO offset in Hz from THAT BOARD'S nominal carrier,
                # discovered (never hardcoded here) and overridable the same way
                # bringup_r2r3.sh honours it.  2026-09-26: the LO plan became PER RUNG
                # and moved to ops/rung_table.sh, because at 2 sps a given Hz offset is
                # half the normalised offset it was at 4 sps -- see
                # docs/evidence/sp4/ACQUISITION_COLLAPSE.md.  Look for the old literal
                # form in bringup_r2r3.sh first so this still reads an archived checkout,
                # then fall back to the rung table for current trees.
  # NOMINAL IS PER BOARD (fixed 2026-09-28). The quiet pair is not symmetric: the forward leg
  # runs at 2.00 GHz (146 TX -> 148 RX) and the reverse at 1.90 GHz (148 TX -> 146 RX). This
  # function subtracted 2.0 GHz for BOTH, so board B's deliberate +40 kHz was printed in every
  # bring-up and restore log as lo_offset_hz=-99960000, i.e. -99.96 MHz. The AGREE/DISAGREE
  # verdict was never affected -- do_check derives `implies` from the SIGN OF CFC, not from this
  # number -- but the printed offset is read by humans diagnosing this link, and it was wrong.
  # The nominal is the PEER's transmit carrier: for 148's receiver that is 146's TX, for 146's
  # receiver it is 148's TX. Both live in ops/rung_table.sh (LO_*_TX_DEFAULT) since 2026-09-29,
  # when the r2/r3 reverse carrier moved 1.9 -> 1.85 GHz; an env override of the carrier (the
  # band-swap experiment) moves the nominal with it. A hard-coded nominal here would print the
  # same -50 MHz nonsense the 2.0-GHz-for-both bug did. The literal fallbacks are for archived
  # checkouts whose bringup_r2r3.sh still carries the pre-09-29 numbers.
  case "$1" in
    "$A") lovar=LO_A_RX; defvar=LO_A_RX_DEFAULT; nomvar=LO_B_TX; nomdef=LO_B_TX_DEFAULT; nomlit=2100000000 ;;
    "$B") lovar=LO_B_RX; defvar=LO_B_RX_DEFAULT; nomvar=LO_A_TX; nomdef=LO_A_TX_DEFAULT; nomlit=1900000000 ;;
    *) return 1 ;;
  esac
  default=$(grep -oE "${lovar}=\\\$\\{${lovar}:-[0-9]+\\}" "$BRINGUP" | grep -oE '[0-9]+' | tail -1)
  nominal=""
  # Say which rung's plan was used and whether RUNG was inherited or assumed: run by hand
  # without RUNG this silently reads the r3 row, and at r4 that is a wrong number (the sign,
  # which is all do_check uses, happens to agree -- but the printed offset would mislead).
  if [ -r "${D:-}/rung_table.sh" ]; then
    if [ -z "$default" ]; then
      if [ -n "${RUNG:-}" ]; then echo "LO_PLAN_SRC rung=$RUNG (inherited)" >&2
      else echo "LO_PLAN_SRC rung=r3 (ASSUMED -- RUNG was not set; export RUNG=r4 at the 2-sps rung)" >&2; fi
    fi
    _tv=$( . "${D}/rung_table.sh" >/dev/null 2>&1; rung_set "${RUNG:-r3}" >/dev/null 2>&1; eval "printf '%s %s' \"\${$defvar:-}\" \"\${$nomdef:-}\"" )
    _tdef=${_tv%% *}; _tnom=${_tv#* }
    [ -n "$default" ] || default=$_tdef
    nominal=$_tnom
  fi
  [ -n "$default" ] || return 1
  eval "_nomenv=\${$nomvar:-}"
  [ -n "$_nomenv" ] && nominal=$_nomenv
  [ -n "$nominal" ] || nominal=$nomlit
  eval "loval=\${$lovar:-$default}"
  echo $(( loval - nominal ))
}

do_write(){ # $1 ip  $2 val(0/1)  $3 tag -- honours RESEED=1 (see the header's
            # stale-shadow note): the bring-up path starts from a known 0x0
            # prior instead of a tmpfs file the reset did not clear.
  ip=$1; val=$2; tag=$3
  case "$val" in 0|1) ;; *) echo "$tag $ip: bad sro_sign value '$val' (want 0 or 1)" >&2; return 2 ;; esac
  if [ "${RESEED:-0}" = 1 ]; then
    stale=$(fixctl_shadow "$ip")
    echo "SRO_SIGN_RESEED $ip was=$stale now=0x0 (post-reset: 0x208 is cleared, /dev/shm/fixctl.word is not)"
    shadow_dec=0
  else
    shadow=$(fixctl_shadow "$ip")
    shadow_dec=$(( shadow )) 2>/dev/null || shadow_dec=0
  fi
  newword=$(( (shadow_dec & ~(1 << SRO_SIGN_BIT)) | ((val & 1) << SRO_SIGN_BIT) ))
  hexword=$(printf '0x%X' "$newword")
  # LATCHED WRITE (2026-09-25, plan 2026-09-25-rig-instability Task 4): write, read the witness
  # back, and on disagreement retry ONCE before failing loudly. 0x208 is a latched control with a
  # witness at 0x25C, and on 2026-09-25 a write that did not land on 148 was printed and ignored --
  # the board was in fact minutes from hanging. A control write that cannot be verified means the
  # leg's measurements cannot be attributed, so this must be a failure, not a note.
  _lw_attempt=1
  while : ; do
    if ! fixctl_write "$ip" "$hexword"; then
      echo "$tag $ip: FIXCTL_WRITE_FAILED (0x208 register write did not land; shadow left unchanged)" >&2
    else
      raw=$(read_sro_mode "$ip")
      rb=$(( raw )) 2>/dev/null || rb=0
      bit=$(( rb & 1 ))
      edge=EMPTY; [ "$bit" = 1 ] && edge=FULL
      hexrb=$(printf '0x%X' "$rb")
      # the observed readback is reported on EVERY attempt (contract pinned by
      # ops/tests/test_sro_sign_conf.py), agreeing or not
      echo "$tag $ip wrote=$val readback_mode=$hexrb edge=$edge"
      [ "$bit" = "$val" ] && return 0
      echo "$tag $ip: witness disagrees (attempt $_lw_attempt of 2)" >&2
    fi
    [ "$_lw_attempt" -ge 2 ] && break
    _lw_attempt=$(( _lw_attempt + 1 ))
    sleep 1
  done
  echo "LATCHED_WRITE_FAIL $ip reg=0x208 want=$val witness=0x25C after $_lw_attempt attempts" >&2
  return 1
}

do_read(){ # $1 ip -- no write
  ip=$1
  shadow=$(fixctl_shadow "$ip")
  raw=$(read_sro_mode "$ip")
  rb=$(( raw )) 2>/dev/null || rb=0
  bit=$(( rb & 1 ))
  edge=EMPTY; [ "$bit" = 1 ] && edge=FULL
  echo "SRO_SIGN_READ $ip shadow=$shadow readback_mode=$(printf '0x%X' "$rb") edge=$edge"
}

do_check(){ # $1 ip
  ip=$1
  lo_offset=$(lo_rx_offset "$ip") || { echo "SRO_SIGN_CHECK $ip: unknown board (no LO_*_RX for $ip)" >&2; return 2; }
  conf=$(conf_value "$ip") || { echo "SRO_SIGN_CHECK $ip: no conf entry in $CONF" >&2; return 2; }
  set -- $(cfc_mean "$ip")
  cfc=$1; valid=$2; wanted=$3
  # A cross-check that could not be MADE is not a verdict. Two ways:
  #   reads_failed  -- fewer than SRO_CHECK_SAMPLES reads produced an integer
  #                    (ssh down, DRA unreadable, board wedged). The old code
  #                    scored every failed read as a 0 sample, so a board that
  #                    answered nothing averaged to 0 and was reported as a
  #                    confident positive sign.
  #   cfo_dead_zone -- every read landed, and the mean is EXACTLY 0. 0 has no
  #                    sign, and a near-zero CFC median is the documented CFO
  #                    dead-zone signature (a leg in the dead zone is a health
  #                    finding in its own right), not evidence for sro_sign=1.
  # Both print UNKNOWN and return 1. The bring-up/restore hooks call --check
  # additively and non-fatally, so this surfaces as one SRO_SIGN_CHECK_HOOK_
  # FAILED line in the log and changes nothing on the board.
  if [ "$valid" -lt "$wanted" ]; then
    echo "SRO_SIGN_CHECK $ip UNKNOWN reason=reads_failed valid=$valid wanted=$wanted conf=$conf"
    echo "WARNING: SRO_SIGN_CHECK $ip UNKNOWN -- only $valid/$wanted 0x154 reads returned a number; no sign verdict" >&2
    return 1
  fi
  if [ "$cfc" -eq 0 ]; then
    echo "SRO_SIGN_CHECK $ip UNKNOWN reason=cfo_dead_zone residual=0 units=reg cfc_mean=0 lo_offset_hz=$lo_offset conf=$conf"
    echo "WARNING: SRO_SIGN_CHECK $ip UNKNOWN -- cfc mean is exactly 0 (CFO dead zone); 0 has no sign, no verdict" >&2
    return 1
  fi
  if [ "$cfc" -lt 0 ] 2>/dev/null; then implies=0; else implies=1; fi
  rel=DISAGREE; [ "$implies" = "$conf" ] && rel=AGREE
  # UNITS=reg: no register-to-Hz scale for 0x154 is documented anywhere in the tree (see the
  # header note above), so "residual" here is the raw cfc mean, sign-significant only; if a
  # scale is ever documented, UNITS becomes hz and residual is recomputed in Hz there.
  UNITS=reg
  echo "SRO_SIGN_CHECK $ip residual=$cfc units=$UNITS cfc_mean=$cfc lo_offset_hz=$lo_offset implies=$implies conf=$conf $rel"
  [ "$rel" = DISAGREE ] && echo "WARNING: SRO_SIGN_CHECK $ip DISAGREE -- a finding, not an automatic flip" >&2
  return 0
}

# ---- arg parsing ------------------------------------------------------------
[ $# -ge 1 ] || { echo "usage: sro_sign.sh <ip> [--read | --bringup | --force <0|1>] | sro_sign.sh --check <ip>" >&2; exit 2; }

if [ "$1" = "--check" ]; then
  shift
  IP=${1:?usage: sro_sign.sh --check <ip>}
  do_check "$IP"
  exit $?
fi

IP=$1; shift
ACTION=write; FORCEVAL=""; RESEED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --read) ACTION=read; shift ;;
    --bringup) RESEED=1; shift ;;
    --force) FORCEVAL=${2:?--force needs a value}; ACTION=force; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
export RESEED

case "$ACTION" in
  read) do_read "$IP"; exit 0 ;;
  force) do_write "$IP" "$FORCEVAL" SRO_SIGN_FORCED; exit $? ;;
  write)
    CONFVAL=$(conf_value "$IP") || { echo "SRO_SIGN $IP: no conf entry in $CONF" >&2; exit 2; }
    do_write "$IP" "$CONFVAL" SRO_SIGN; exit $?
    ;;
esac
