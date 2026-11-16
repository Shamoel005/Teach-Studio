#!/bin/bash
# Builds "Teach Studio.app" for Apple Silicon (needs Xcode or Command Line Tools, macOS 15+)
set -e
cd "$(dirname "$0")"

APP="Teach Studio.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos15.0 \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/TeachStudio"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Teach Studio</string>
  <key>CFBundleDisplayName</key><string>Teach Studio</string>
  <key>CFBundleIdentifier</key><string>com.example.teachstudio</string>
  <key>CFBundleExecutable</key><string>TeachStudio</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Teach Studio needs the microphone to record your voice.</string>
  <key>NSCameraUsageDescription</key>
  <string>Teach Studio shows your webcam in a bubble on the recording.</string>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$APP"
echo "Built: $APP"
# Don't try to launch the app on CI machines (GitHub Actions sets CI=true)
if [ -z "$CI" ]; then
  open "$APP"
fi
