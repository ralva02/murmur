#!/bin/bash
# Builds Wisprrr in release mode and assembles a launchable .app bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/Wisprrr.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Wisprrr "$APP/Contents/MacOS/Wisprrr"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Wisprrr</string>
    <key>CFBundleIdentifier</key>
    <string>com.raul.wisprrr</string>
    <key>CFBundleName</key>
    <string>Wisprrr</string>
    <key>CFBundleDisplayName</key>
    <string>Wisprrr</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Wisprrr records your voice while you hold the dictation hotkey so it can transcribe what you say.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Wisprrr transcribes your speech on-device to insert text where you're typing.</string>
</dict>
</plist>
PLIST

# Sign with a stable identity when available. Ad-hoc signatures change every
# build, which resets TCC permission grants (Accessibility/Input Monitoring/
# Microphone) on each rebuild; a real identity keeps them across rebuilds.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development/ {print $2; exit}')
if [ -n "$IDENTITY" ]; then
    codesign --force -s "$IDENTITY" "$APP"
    echo "Signed with: $IDENTITY"
else
    codesign --force -s - "$APP"
    echo "WARNING: ad-hoc signed — permission grants will reset on every rebuild"
fi
echo "Built $APP"
