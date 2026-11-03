#!/bin/bash
# Builds Grab.app from Grab.swift. Requires Xcode Command Line Tools (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"

APP="Grab.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling…"
swiftc -O -parse-as-library Grab.swift -o "$APP/Contents/MacOS/Grab"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Grab</string>
    <key>CFBundleDisplayName</key><string>Grab</string>
    <key>CFBundleIdentifier</key><string>local.grab.downloader</string>
    <key>CFBundleExecutable</key><string>Grab</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so Gatekeeper lets a locally built app run.
codesign --force --sign - "$APP"

echo "Built $APP"
echo "Run:  open $APP    (or drag it into /Applications)"
command -v yt-dlp >/dev/null || echo "Note: yt-dlp not found – install with: brew install yt-dlp"
command -v ffmpeg >/dev/null || echo "Note: ffmpeg not found – install with: brew install ffmpeg"
