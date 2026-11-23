#!/bin/bash
# =============================================================================
# build_dtb_4mb.sh -- build the 4 MB-carve qpsk system.dtb for each rig board
# (f3072 rung, sp4 Task 10). NO board contact.
#
# Every input is DISCOVERED (never hardcoded) and the build is FATAL if a piece
# is missing or ambiguous:
#   base   images/system.dtb.pristine.<board>.<md5-12>  (stock ADI system.dtb,
#          exactly one per board; the board list IS this glob)
#   uio    modem/boot/qpsk_byte_uio.dtso  (3 UIO nodes + 2 MB carve; carries
#          @TX_SPI_CELL@/@RX_SPI_CELL@ placeholders)
#   cells  read back from that board's banked 2 MB qpsk dtb
#          (fdtget /axi_pl/qpsk_{tx,rx}_dma@... interrupts, middle cell);
#          TX_SPI_CELL/RX_SPI_CELL in the env override
#   carve  ops/dtb/carve_4mb.dtso  (reg -> <0 0x7fc00000 0 0x400000>)
#
# Chain per board:  sed cells -> dtc -@ -> fdtoverlay onto the pristine base
#                   -> fdtoverlay carve_4mb.dtso -> system-qpsk.<board>.dtb.<md5-12>
# Cross-check: carve_4mb.dtso applied to the board's banked 2 MB dtb must yield
# the SAME tree (dtc -I dtb -O dts text equal) as the from-pristine chain --
# i.e. pristine+uio reproduces what the board runs today and the ONLY change
# is the carve reg. A mismatch is FATAL (the overlay source has drifted from
# the deployed dtb; find out why before banking).
#
# usage: build_dtb_4mb.sh [--out-dir DIR] [--board 148|146 ...]
#   default: both discovered boards, output into images/ with an MD5SUMS row
#   appended (idempotent). With --out-dir the files are written there and
#   MD5SUMS is NOT touched (tests / dry builds).
# prints one line per board:  DTB4MB_OK board=<b> file=<path> md5=<md5-12>
# =============================================================================
set -u
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)
IMG=$ROOT/images
UIO=$ROOT/modem/boot/qpsk_byte_uio.dtso
CARVE=$HERE/carve_4mb.dtso
PLACEHOLDERS='@TX_SPI_CELL@|@RX_SPI_CELL@'
WANT_REG4="0 2143289344 0 4194304"    # <0 0x7fc00000 0 0x400000>
WANT_REG2="0 2145386496 0 2097152"    # <0 0x7fe00000 0 0x200000>
die(){ echo "FATAL: $*" >&2; exit 1; }

OUT=$IMG; BANK=1; BOARDS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --out-dir) OUT=$2; BANK=0; shift 2 ;;
    --board)   BOARDS+=("$2"); shift 2 ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
for t in dtc fdtoverlay fdtget md5sum; do which "$t" >/dev/null 2>&1 || die "$t not found"; done
[ -f "$UIO" ]   || die "UIO overlay source missing: $UIO"
[ -f "$CARVE" ] || die "carve overlay missing: $CARVE"
[ -d "$OUT" ]   || die "output dir missing: $OUT"
grep -Eq "$PLACEHOLDERS" "$UIO" || die "$UIO has no @SPI@ placeholders -- not the overlay source this script expects"

# --- discover the boards from the pristine bases ---------------------------
if [ ${#BOARDS[@]} -eq 0 ]; then
  for f in "$IMG"/system.dtb.pristine.*.*; do
    [ -f "$f" ] || continue
    b=$(basename "$f" | cut -d. -f4); BOARDS+=("$b")
  done
fi
[ ${#BOARDS[@]} -gt 0 ] || die "no pristine base dtb found: $IMG/system.dtb.pristine.<board>.<md5>"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

carve_reg(){ fdtget "$1" /reserved-memory/qpsk_byte_buf@7ff00000 reg 2>/dev/null; }
spi_cell(){ fdtget "$1" "/axi_pl/$2" interrupts 2>/dev/null | awk '{print $2}'; }

for b in "${BOARDS[@]}"; do
  echo "=== board $b ==="
  # pristine base: exactly one
  bases=("$IMG"/system.dtb.pristine."$b".*)
  [ -f "${bases[0]}" ] || die "no pristine base for board $b ($IMG/system.dtb.pristine.$b.*)"
  [ ${#bases[@]} -eq 1 ] || die "several pristine bases for board $b: ${bases[*]}"
  base=${bases[0]}
  echo "  base : $(basename "$base")"
  # the banked 2 MB qpsk dtb of this board (cells source + cross-check reference)
  ref=""
  for f in "$IMG"/system-qpsk."$b".dtb.*; do
    [ -f "$f" ] || continue
    [ "$(carve_reg "$f")" = "$WANT_REG2" ] && { [ -z "$ref" ] || die "several 2 MB qpsk dtbs banked for board $b"; ref=$f; }
  done
  tx=${TX_SPI_CELL:-}; rx=${RX_SPI_CELL:-}
  if [ -n "$ref" ]; then
    echo "  ref  : $(basename "$ref") (banked 2 MB carve)"
    [ -n "$tx" ] || tx=$(spi_cell "$ref" qpsk_tx_dma@9d100000)
    [ -n "$rx" ] || rx=$(spi_cell "$ref" qpsk_rx_dma@9d200000)
  else
    echo "  ref  : none (no banked 2 MB qpsk dtb for $b -- cells must come from TX_SPI_CELL/RX_SPI_CELL, no cross-check)"
  fi
  [ -n "$tx" ] && [ -n "$rx" ] || die "SPI cells unknown for board $b (no banked 2 MB dtb to read them from; set TX_SPI_CELL/RX_SPI_CELL)"
  echo "$tx$rx" | grep -Eq '^[0-9]+$' || die "SPI cells must be integers (got tx=$tx rx=$rx)"
  echo "  cells: tx=$tx rx=$rx (GIC SPI $((tx+32))/$((rx+32)))"

  # 1. uio overlay with the cells -> dtbo
  sed -e "s/@TX_SPI_CELL@/$tx/g" -e "s/@RX_SPI_CELL@/$rx/g" "$UIO" > "$tmp/uio.$b.dtso"
  grep -Eq "$PLACEHOLDERS" "$tmp/uio.$b.dtso" && die "placeholders left after substitution"
  dtc -@ -I dts -O dtb -o "$tmp/uio.$b.dtbo" "$tmp/uio.$b.dtso" 2>"$tmp/dtc.uio.$b.log" \
    || { cat "$tmp/dtc.uio.$b.log" >&2; die "uio overlay failed to compile"; }
  # 2. carve overlay -> dtbo (the reg_format/addr-size warnings are the known
  #    standalone-compile noise; the merged result is what is checked)
  dtc -@ -I dts -O dtb -o "$tmp/carve.dtbo" "$CARVE" 2>"$tmp/dtc.carve.log" \
    || { cat "$tmp/dtc.carve.log" >&2; die "carve overlay failed to compile"; }
  # 3. pristine + uio (= the 2 MB dtb the boards run) + carve
  fdtoverlay -i "$base" -o "$tmp/qpsk2mb.$b.dtb" "$tmp/uio.$b.dtbo" || die "fdtoverlay (uio) failed for $b"
  [ "$(carve_reg "$tmp/qpsk2mb.$b.dtb")" = "$WANT_REG2" ] || die "pristine+uio did not give the 2 MB carve for $b"
  fdtoverlay -i "$tmp/qpsk2mb.$b.dtb" -o "$tmp/qpsk4mb.$b.dtb" "$tmp/carve.dtbo" || die "fdtoverlay (carve) failed for $b"
  got=$(carve_reg "$tmp/qpsk4mb.$b.dtb")
  [ "$got" = "$WANT_REG4" ] || die "carve reg after overlay is '$got', want '$WANT_REG4'"
  # 4. cross-check against the banked 2 MB dtb: same tree except the carve reg
  if [ -n "$ref" ]; then
    dtc -q -I dtb -O dts "$ref" > "$tmp/ref.$b.dts" || die "ref dtb does not round-trip"
    dtc -q -I dtb -O dts "$tmp/qpsk2mb.$b.dtb" > "$tmp/mine2.$b.dts" || die "built 2 MB dtb does not round-trip"
    if ! diff -q "$tmp/ref.$b.dts" "$tmp/mine2.$b.dts" >/dev/null; then
      diff "$tmp/ref.$b.dts" "$tmp/mine2.$b.dts" | head -20 >&2
      die "pristine+uio does NOT reproduce the banked 2 MB dtb for $b (overlay source drifted from the deployed dtb)"
    fi
    fdtoverlay -i "$ref" -o "$tmp/refcarve.$b.dtb" "$tmp/carve.dtbo" || die "fdtoverlay (carve on ref) failed"
    dtc -q -I dtb -O dts "$tmp/refcarve.$b.dtb" > "$tmp/refcarve.$b.dts"
    dtc -q -I dtb -O dts "$tmp/qpsk4mb.$b.dtb" > "$tmp/mine4.$b.dts"
    diff -q "$tmp/refcarve.$b.dts" "$tmp/mine4.$b.dts" >/dev/null || die "carve-on-banked and carve-on-pristine trees differ for $b"
    ndiff=$(diff "$tmp/ref.$b.dts" "$tmp/mine4.$b.dts" | grep -c '^[<>]')
    [ "$ndiff" -eq 2 ] || { diff "$tmp/ref.$b.dts" "$tmp/mine4.$b.dts" >&2; die "expected exactly the reg line to change vs the banked dtb, got $ndiff changed lines"; }
    echo "  xcheck: pristine+uio == banked 2 MB tree; 4 MB tree differs in the carve reg only"
  fi
  # 5. bank
  md5=$(md5sum "$tmp/qpsk4mb.$b.dtb" | cut -c1-32); m12=${md5:0:12}
  out=$OUT/system-qpsk.$b.dtb.$m12
  if [ -f "$out" ]; then
    cmp -s "$out" "$tmp/qpsk4mb.$b.dtb" || die "$out exists with different content"
    echo "  bank : $(basename "$out") already present (identical)"
  else
    cp "$tmp/qpsk4mb.$b.dtb" "$out"
  fi
  if [ "$BANK" -eq 1 ]; then
    grep -q "  system-qpsk.$b.dtb.$m12\$" "$IMG/MD5SUMS" || echo "$md5  system-qpsk.$b.dtb.$m12" >> "$IMG/MD5SUMS"
  fi
  echo "DTB4MB_OK board=$b file=$out md5=$m12 carve='$got' cells=$tx/$rx"
done
