#!/bin/zsh
# Runs the unit tests (Tests/) with Swift Testing. The Command Line Tools ship the Testing macros in a folder the
# compiler doesn't search by itself, so it is passed explicitly when it exists.
set -euo pipefail
cd "${0:A:h}/.."

args=()
plugins=${$(xcrun --find swift):h:h}/lib/swift/host/plugins/testing
[[ -d $plugins ]] && args=(-Xswiftc -plugin-path -Xswiftc $plugins)
swift test --quiet $args "$@"
