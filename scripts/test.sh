#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# The standalone Command Line Tools store Swift Testing macros outside the default plugin path.
plugins="$(dirname "$(xcrun --find swiftc)")/../lib/swift/host/plugins/testing"
if [[ -d "$plugins" ]]; then
    exec swift test -Xswiftc -plugin-path -Xswiftc "$plugins" "$@"
fi
exec swift test "$@"
