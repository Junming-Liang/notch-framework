#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
FIXTURE="$PWD/.build/native-network-fixture"
mkdir -p "$FIXTURE"
swiftc Tools/ci-hello.swift -o "$FIXTURE/HelloNotchExtension"
cat > "$FIXTURE/manifest.json" <<'JSON'
{"id":"org.notchframework.hello","name":"Hello Notch","version":"0.1.0","entrypoint":"HelloNotchExtension","files":["HelloNotchExtension"],"protocolVersion":1}
JSON
swift run NotchSmoke "$FIXTURE"
swift run NotchNetworkSmoke "$FIXTURE"
