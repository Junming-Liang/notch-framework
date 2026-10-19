#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == "Darwin" ]] || { echo 'macOS + Xcode command-line tools required' >&2; exit 1; }
swift test
swift build -c release
APP="$PWD/dist/NotchHost-Development.app"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/NotchHost" "$APP/Contents/MacOS/NotchHost"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.notchframework.host.development</string>
<key>CFBundleName</key><string>NotchHost Development</string>
<key>CFBundleExecutable</key><string>NotchHost</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
# Ad-hoc local build seal only. No certificate/private key is created or required.
# This is NOT Developer ID signing, notarization, or authorization to bypass Gatekeeper.
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
echo "Built local development app: $APP"
