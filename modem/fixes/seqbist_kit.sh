#!/bin/bash
# seqbist_kit.sh -- the fix chain's name (fixes.toml [chain] seqbist.script) for the SEQ-BIST
# kit builder, which lives in modem/instruments/seqbist/apply_seqbist.sh. A wrapper, not a
# symlink; apply_seqbist.sh locates itself with readlink -f "$0" so exec by real path is
# identical to the former link. Its sha is stamped into every sp2 kit -- do not edit the target.
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")/../instruments/seqbist" && pwd)/apply_seqbist.sh" "$@"
