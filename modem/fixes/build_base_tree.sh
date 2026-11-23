#!/bin/bash
# build_base_tree.sh -- the pre-sp3 name of modem/build_hdl.sh (sp3 Task 11 rename). Kept as a
# thin wrapper (NOT a symlink: the repo carries none) for the docs, legs tables and evidence
# that still say build_base_tree.sh. build_hdl.sh locates itself with readlink -f "$0", so
# exec'ing it by its real path is exactly the old symlink behaviour.
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/build_hdl.sh" "$@"
