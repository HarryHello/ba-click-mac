#!/bin/bash
# Regenerate the app icon from icons/icon.svg:
#   - Resources/icon.png        (1024x1024, used for the Dock icon in run.sh)
#   - Resources/AppIcon.icns    (all sizes, used by the .app bundle)
set -euo pipefail
cd "$(dirname "$0")/.."

./tools/svg2png.sh icons/icon.svg Resources/icon.png 1024

rm -rf /tmp/AppIcon.iconset
mkdir -p /tmp/AppIcon.iconset
ICON=Resources/icon.png
sips -z 16 16 "$ICON" --out /tmp/AppIcon.iconset/icon_16x16.png >/dev/null
sips -z 32 32 "$ICON" --out /tmp/AppIcon.iconset/icon_16x16@2x.png >/dev/null
sips -z 32 32 "$ICON" --out /tmp/AppIcon.iconset/icon_32x32.png >/dev/null
sips -z 64 64 "$ICON" --out /tmp/AppIcon.iconset/icon_32x32@2x.png >/dev/null
sips -z 128 128 "$ICON" --out /tmp/AppIcon.iconset/icon_128x128.png >/dev/null
sips -z 256 256 "$ICON" --out /tmp/AppIcon.iconset/icon_128x128@2x.png >/dev/null
sips -z 256 256 "$ICON" --out /tmp/AppIcon.iconset/icon_256x256.png >/dev/null
sips -z 512 512 "$ICON" --out /tmp/AppIcon.iconset/icon_256x256@2x.png >/dev/null
sips -z 512 512 "$ICON" --out /tmp/AppIcon.iconset/icon_512x512.png >/dev/null
cp "$ICON" /tmp/AppIcon.iconset/icon_512x512@2x.png
iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns
rm -rf /tmp/AppIcon.iconset

echo "✅ Resources/icon.png (1024) + Resources/AppIcon.icns"
