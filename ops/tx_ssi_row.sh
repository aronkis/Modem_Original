#!/bin/bash
# tx_ssi_row.sh <ip> <fallback "clk data"> [image-md5-12] -- print the tx0 SSI row for this board
# and its CURRENT image from ops/profiles/tx_ssi.conf (TX_SSI_CONF overrides the path).
# Never fatal: any failure (ssh, missing conf, no row) prints the fallback so bring-up proceeds
# exactly as before. The image md5 is read from the board (md5sum /boot/BOOT.BIN) unless given.
IP=$1; FB=$2; MD5=$3
D=$(cd "$(dirname "$0")" && pwd); W=${W:-$D/anyssh.sh}; CONF=${TX_SSI_CONF:-$D/profiles/tx_ssi.conf}
[ -n "$IP" ] && [ -n "$FB" ] || { echo "${FB:-}"; exit 0; }
if [ -z "$MD5" ]; then MD5=$($W "$IP" 'md5sum /boot/BOOT.BIN' 2>/dev/null | tr -d '\r' | cut -c1-12); fi
[ -r "$CONF" ] || { echo "$FB"; exit 0; }
row=$(awk -v ip="$IP" -v md5="$MD5" '
  $1 ~ /^#/ || NF < 4 { next }
  $1 == ip && $2 == md5 { print $3, $4; found=1; exit }
  $1 == ip && $2 == "default" { def=$3 " " $4 }
  END { if (!found && def != "") print def }' "$CONF")
[ -n "$row" ] && echo "$row" || echo "$FB"
