#!/bin/bash
# run_gates.sh -- compatibility wrapper: the gate runner lives in modem/gates/run_gates.sh.
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")/../gates" && pwd)/run_gates.sh" "$@"
