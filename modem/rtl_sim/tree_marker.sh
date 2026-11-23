#!/bin/bash
# tree_marker.sh <tree> <VARIANT> -- provenance check for a gate tree. Accepts the injector
# token (RXFIX_<V> / TXFIX_F3 in the variant's file) OR a model-generated tree (RXFIX_ORIGIN
# file + the overlay's module file). Exit 1 and TREE_MARKER_MISSING otherwise.
#
# PAD's model check is ByteSerializer.v containing padCount (ruling 3, 2026-09-11
# model-backport controller ruling): there is no BsPad.v -- HDL Coder folds the pad
# counter into ByteSerializer itself, the same shape F3's fullRAM check already uses.
set -u; T=$1; V=$2
case $V in
  W1)    F=Rate_Handle.v;       TOK=RXFIX_W1;  MOD=RxW1Census.v ;;
  R4B)   F=Rate_Handle.v;       TOK=RXFIX_R4B; MOD=RxSteer.v ;;
  R4D)   F=Rate_Handle.v;       TOK=RXFIX_R4D; MOD=RxSteer.v ;;
  R4DR1) F=Preamble_Detector.v; TOK=RXFIX_R1;  MOD=PdPopIndex.v ;;
  BS)    F=ByteSerializer.v;    TOK=RXFIX_BS;  MOD=BsSeamCensus.v ;;
  PAD)   F=ByteSerializer.v;    TOK=RXFIX_PAD; MOD=ByteSerializer.v ;;
  F3)    F=Bit_Packetizer.v;    TOK=TXFIX_F3;  MOD=Bit_Packetizer.v ;;
  *) echo "TREE_MARKER_BAD_VARIANT $V"; exit 2 ;;
esac
if grep -q "$TOK" "$T/$F" 2>/dev/null; then echo "TREE_MARKER $T $V injector"; exit 0; fi
if [ -f "$T/RXFIX_ORIGIN" ] && [ -f "$T/$MOD" ]; then
  if [ "$V" = F3 ] && ! grep -q "fullRAM" "$T/$MOD"; then echo "TREE_MARKER_MISSING $T $V (model tree without the F3 dataReady gate)"; exit 1; fi
  if [ "$V" = PAD ] && ! grep -q "padCount" "$T/$MOD"; then echo "TREE_MARKER_MISSING $T $V (model tree without the PAD padCount counter)"; exit 1; fi
  echo "TREE_MARKER $T $V model"; exit 0
fi
echo "TREE_MARKER_MISSING $T $V"; exit 1
