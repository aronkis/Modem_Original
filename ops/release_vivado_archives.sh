#!/bin/bash
# =============================================================================
# release_vivado_archives.sh -- package the Vivado projects of the released designs on the build host and
# attach them (plus the current images) to the rolling GitHub "development" release.
#
#   ops/release_vivado_archives.sh [LINEAGES="sp3tilteq2 sp3clamp004 sp3clamp004txo sp3clamp004rxo"] [DRY=1]
#
# Per lineage, on hdl-dev-2 (HOSTS.md; Vivado 2023.2 at $VIVADO), the kit /mnt/disk2/scratch/qpsk-builds/
# jupiter_byte_<lineage>_build/hdl_prj_jupiter_composite is packaged as jupiter_qpsk_<lineage>.vivado.zip:
#   ipcore/ hdlsrc/ vivado_ip_prj/{*.tcl,*.xdc,scripts,boot/system_top.bit}  +  <lineage>_prj.zip
# where <lineage>_prj.zip is Vivado's archive_project of vivado_prj.xpr (-exclude_run_results). The zips are pulled
# to $OUT (default images/release/, gitignored) and uploaded with `gh release upload development --clobber`
# together with the image assets listed in images/CURRENT.txt roles A/B/TXO/RXO, the kernel and the dtbs.
# DRY=1 prints every remote and gh command and runs nothing. The release itself (tag `development`, prerelease,
# notes) is created/edited by hand with `gh release create|edit`; this script only refreshes assets.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$D/.." && pwd)
HOST=${HOST:-hdl-dev-2}; VIVADO=${VIVADO:-/opt/Xilinx/2025.1/Vivado/bin/vivado}   # the version the kits were built with (build_txfix.sh PATH); 2023.2 cannot open them
RBASE=${RBASE:-/mnt/disk2/scratch/qpsk-builds}; ROUT=${ROUT:-/mnt/disk2/scratch/qpsk-release}
LINEAGES=${LINEAGES:-"sp3tilteq2 sp3clamp004 sp3clamp004txo sp3clamp004rxo"}
OUT=${OUT:-$ROOT/images/release}; TAG=${TAG:-development}; REPO=${REPO:-tfcollins/qpsk-jupiter-modem}
DRY=${DRY:-0}
run(){ if [ "$DRY" = 1 ]; then echo "[DRY] $*"; else "$@"; fi; }
mkdir -p "$OUT"
for k in $LINEAGES; do
  d=$RBASE/jupiter_byte_${k}_build/hdl_prj_jupiter_composite; z=$ROUT/jupiter_qpsk_${k}.vivado.zip
  script="set -e; mkdir -p $ROUT; rm -f $z $ROUT/${k}_prj.zip
printf 'open_project $d/vivado_ip_prj/vivado_prj.xpr\narchive_project $ROUT/${k}_prj.zip -force -exclude_run_results\nclose_project\n' > $ROUT/arch_$k.tcl
$VIVADO -mode batch -nolog -nojournal -source $ROUT/arch_$k.tcl > $ROUT/arch_$k.log 2>&1
cd $d && zip -qr $z ipcore hdlsrc vivado_ip_prj/*.tcl vivado_ip_prj/*.xdc vivado_ip_prj/scripts vivado_ip_prj/boot/system_top.bit -x '*.jou' '*.log'
cd $ROUT && zip -qj $z ${k}_prj.zip && rm -f ${k}_prj.zip
echo ARCHIVE_OK $k \$(stat -c %s $z) \$(md5sum $z | cut -c1-12)"
  if [ "$DRY" = 1 ]; then echo "[DRY] ssh $HOST: archive $k -> $z"; else ssh -o BatchMode=yes "$HOST" "$script" | tail -n 1 || { echo "ARCHIVE_FAILED $k"; exit 1; }; fi
  run scp -q -o BatchMode=yes "$HOST:$z" "$OUT/"
done
ASSETS=""
for role in A B TXO RXO; do f=$(awk -v r="$role" '$1==r{print $2}' "$ROOT/images/CURRENT.txt"); [ -n "$f" ] && ASSETS="$ASSETS $ROOT/images/$f"; done
for f in $(awk '$1=="DTB148"||$1=="DTB146"{print $2}' "$ROOT/images/CURRENT.txt") $(ls "$ROOT"/images/Image.*.gz) MD5SUMS SHA256SUMS.Image; do ASSETS="$ASSETS $ROOT/images/$(basename $f)"; done
for k in $LINEAGES; do ASSETS="$ASSETS $OUT/jupiter_qpsk_${k}.vivado.zip"; done
run gh release upload "$TAG" -R "$REPO" --clobber $ASSETS
echo "RELEASE_ASSETS_DONE tag=$TAG $(echo $ASSETS | wc -w) files"
