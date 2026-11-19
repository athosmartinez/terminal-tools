#!/usr/bin/env bash
# Tests for the pure rules of lib/monitor (macOS): the config, which displays
# count as external, where the virtual display goes, and the Moonlight command.
# They run the rules on fake displays, so no test lists, creates or changes a
# display. macOS only: they need swiftc.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

swiftc -swift-version 5 "$ROOT"/lib/monitor/*.swift "$ROOT/tests/monitor/main.swift" -o "$WORK/monitor-tests"
"$WORK/monitor-tests"
