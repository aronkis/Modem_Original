#!/bin/bash
# rigprobe.sh <ip> <reg> [reg ...] -- THE sanctioned one-off register read.
#
# Why this exists (2026-09-25): reading a handful of modem registers "just to check" is how board
# 148 was hung -- the reads landed while the delivery sentinel was arming both boards. Ad-hoc
# `anyssh + direct_reg_access` takes no lock and nothing stopped it. This takes the rig mutex for
# the duration of the read, so the sentinel stands down (rig_lock holds SENTINEL_STOP) and no other
# rail can start, then releases exactly what it took.
#
#   rigprobe.sh 10.0.0.148 0x104 0x25C 0x234
#   -> RIGPROBE ip=10.0.0.148 0x104=0x... 0x25C=0x... 0x234=0x...
#
# Refuses (exit 3) if another actor already holds the lock -- check what it is before overriding.
# For a repeated/rate measurement use the rails (health_probe_reset_aware.sh, capture_r3.sh), which
# hold the lock for their whole run; this is for a single snapshot.
set -u
D=$(cd "$(dirname "$0")" && pwd)
IP=${1:?usage: rigprobe.sh <ip> <reg> [reg ...]}; shift
[ $# -ge 1 ] || { echo "usage: rigprobe.sh <ip> <reg> [reg ...]" >&2; exit 2; }
. "$D/sim_repro/riglock.sh"
rig_lock "rigprobe-$$"
trap 'rig_unlock' EXIT
REGS="$*"
OUT=$("$D/anyssh.sh" "$IP" "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
 echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
 for r in $REGS; do echo \$r > \$DRA; printf '%s=%s ' \$r \"\$(cat \$DRA)\"; done; echo" 2>/dev/null | tail -1)
echo "RIGPROBE ip=$IP ${OUT:-READ_FAILED}"
