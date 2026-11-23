#!/bin/bash
# tree_marker.sh must accept an injector tree, a model tree, and refuse an empty one.
# Also covers ruling 3 (PAD's model check is ByteSerializer.v/padCount, no BsPad.v)
# and the F3 model-without-fullRAM negative branch, and the bad-variant exit code.
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); f=0
mkdir -p $T/inj $T/mod $T/none $T/pad_ok $T/pad_bad $T/f3_bad $T/badvar
echo "// RXFIX_R4B steering" > $T/inj/Rate_Handle.v
echo "model /x abc 2026" > $T/mod/RXFIX_ORIGIN; echo "module RxSteer;" > $T/mod/RxSteer.v; echo "" > $T/mod/Rate_Handle.v
echo "" > $T/none/Rate_Handle.v

# PAD: model check is ByteSerializer.v containing padCount (ruling 3, no BsPad.v)
echo "model /x abc 2026" > $T/pad_ok/RXFIX_ORIGIN
echo "// has padCount here" > $T/pad_ok/ByteSerializer.v
echo "model /x abc 2026" > $T/pad_bad/RXFIX_ORIGIN
echo "// no marker here" > $T/pad_bad/ByteSerializer.v

# F3: model tree without the fullRAM dataReady gate must be refused
echo "model /x abc 2026" > $T/f3_bad/RXFIX_ORIGIN
echo "// assign dataReady = something_else;" > $T/f3_bad/Bit_Packetizer.v

$H/tree_marker.sh $T/inj R4B | grep -q "injector$" || { echo FAIL inj; f=1; }
$H/tree_marker.sh $T/mod R4B | grep -q "model$"    || { echo FAIL mod; f=1; }
$H/tree_marker.sh $T/none R4B >/dev/null 2>&1 && { echo FAIL none; f=1; }

$H/tree_marker.sh $T/pad_ok PAD | grep -q "model$" || { echo FAIL pad_ok; f=1; }
$H/tree_marker.sh $T/pad_bad PAD >/dev/null 2>&1 && { echo FAIL pad_bad; f=1; }

$H/tree_marker.sh $T/f3_bad F3 >/dev/null 2>&1 && { echo FAIL f3_bad; f=1; }

$H/tree_marker.sh $T/badvar NOPE >/dev/null 2>&1
[ $? = 2 ] || { echo FAIL badvar; f=1; }

rm -rf $T; [ $f = 0 ] && echo TREE_MARKER_TEST_OK; exit $f
