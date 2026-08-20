#!/bin/bash
# Build the app icon from a modern Icon Composer .icon package
# (macOS 26+ / Xcode 26 format: icon.json + Assets/*.svg) into:
#   - Resources/icon.png     (1024x1024 master)
#   - Resources/AppIcon.icns (all sizes, used by the .app bundle)
#
# Uses the ictool CLI bundled inside /Applications/Icon Composer.app.
# Usage: ./tools/build-icon.sh [path/to/icon.icon]
set -euo pipefail
cd "$(dirname "$0")/.."

ICON="${1:-icons/icon.icon}"
ICT="/Applications/Icon Composer.app/Contents/Executables/ictool"
if [ ! -x "$ICT" ]; then
  echo "error: ictool not found at $ICT (Icon Composer.app missing)" >&2
  exit 1
fi
if [ ! -f "$ICON/icon.json" ]; then
  echo "error: $ICON is not an Icon Composer .icon package" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Render the square (shared) rendition at 1024x1024. The .icon format is
# full-bleed: macOS applies its own squircle mask, so no corners are baked.
"$ICT" "$ICON" \
  --export-image \
  --output-file "$TMP/icon-1024.png" \
  --platform iOS \
  --rendition Default \
  --width 512 --height 512 --scale 2

cp "$TMP/icon-1024.png" Resources/icon.png

mkdir -p "$TMP/AppIcon.iconset"
python3 - "$TMP" <<'PY'
from PIL import Image
import os, sys
tmp = sys.argv[1]
src = Image.open(os.path.join(tmp, 'icon-1024.png')).convert('RGBA')
sizes = {
    'icon_16x16.png': 16,       'icon_16x16@2x.png': 32,
    'icon_32x32.png': 32,       'icon_32x32@2x.png': 64,
    'icon_128x128.png': 128,    'icon_128x128@2x.png': 256,
    'icon_256x256.png': 256,    'icon_256x256@2x.png': 512,
    'icon_512x512.png': 512,    'icon_512x512@2x.png': 1024,
}
out = os.path.join(tmp, 'AppIcon.iconset')
for name, size in sizes.items():
    img = src.resize((size, size), Image.LANCZOS)
    img.save(os.path.join(out, name))
print(f"wrote {len(sizes)} icon sizes")
PY

iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns

echo "✅ Resources/icon.png (1024) + Resources/AppIcon.icns from $ICON"
