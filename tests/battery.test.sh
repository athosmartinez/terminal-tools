#!/usr/bin/env bash
# Tests for lib/battery/Battery.swift (config, labels, order, title). They
# compile with Battery.swift only, so they need no Bluetooth and no permission.
# macOS only: they need swiftc.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

swiftc -swift-version 5 "$ROOT/lib/battery/Battery.swift" "$ROOT/tests/battery/main.swift" -o "$WORK/battery-tests"
"$WORK/battery-tests"
