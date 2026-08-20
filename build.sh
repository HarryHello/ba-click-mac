#!/bin/bash
# Build the ba-click-mac overlay.
#   ./build.sh          -> command-line binary at .build/ba-click-mac
#   ./build.sh --app    -> double-clickable app bundle at build/BaClickMac.app
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-}"
APP=build/BaClickMac.app

if [ "$MODE" = "--app" ]; then
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  OUT="$APP/Contents/MacOS/BaClickMac"
  cp Resources/* "$APP/Contents/Resources/"
else
  mkdir -p .build/Resources
  cp Resources/* .build/Resources/
  OUT=.build/ba-click-mac
fi

swiftc \
  -module-cache-path .build/module-cache \
  -o "$OUT" \
  Sources/BaClickMac/*.swift \
  -framework AppKit \
  -framework Metal \
  -framework MetalKit \
  -framework MetalPerformanceShaders \
  -framework CoreGraphics \
  -framework QuartzCore

if [ "$MODE" = "--app" ]; then
  cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>BaClickMac</string>
    <key>CFBundleIdentifier</key>
    <string>local.ba-click-mac</string>
    <key>CFBundleName</key>
    <string>BA Click</string>
    <key>CFBundleDisplayName</key>
    <string>BA Click</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

  echo "✅ Built $APP"
  echo "Run with: open $APP"
else
  echo "✅ Built .build/ba-click-mac"
  echo "Run with: ./.build/ba-click-mac"
fi
