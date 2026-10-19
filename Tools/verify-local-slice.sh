#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
HELLO="${1:-../notch-extension-hello}"
[[ -d "$HELLO" ]] || { echo 'Pass separate Hello repo path' >&2; exit 1; }
HELLO="$(cd "$HELLO" && pwd)"
bash "$HELLO/Tools/build-fixture.sh"
swift test
swift run NotchSmoke "$HELLO/dist/hello-0.1.0"
swift run NotchNetworkSmoke "$HELLO/dist/hello-0.1.0"
