#!/bin/bash
# Regenerate Resources/dmg-background.jpg: room_night.png resized to the
# DMG window size (640x360) with frosted light panels baked under the two
# icon LABEL zones — Finder label color follows the system appearance, so
# black labels (light mode) need a light backdrop to stay readable.
#
# Usage: ./tools/make-dmg-background.sh [path/to/room_night.png]
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${1:-../room_night.png}"
OUT="Resources/dmg-background.jpg"
[ -f "$SRC" ] || { echo "source not found: $SRC" >&2; exit 1; }

sips -s format png -z 360 640 "$SRC" --out /tmp/dmg-bg-360.png >/dev/null

python3 - <<'PY'
from PIL import Image, ImageDraw

base = Image.open('/tmp/dmg-bg-360.png').convert('RGBA')
overlay = Image.new('RGBA', base.size, (0, 0, 0, 0))
draw = ImageDraw.Draw(overlay)

# Frosted light cards under the label zones. Icon (top-left) positions:
#   app          x 170..298, y 120..248   -> label ~ (140..330, 246..288)
#   Applications x 470..598, y 120..248   -> label ~ (420..628, 246..288)
for box in [(128, 240, 342, 292), (408, 240, 630, 292)]:
    draw.rounded_rectangle(box, radius=10, fill=(235, 240, 248, 118))

Image.alpha_composite(base, overlay).convert('RGB').save(
    'Resources/dmg-background.jpg', quality=80
)
print('wrote', 'Resources/dmg-background.jpg')
PY
rm -f /tmp/dmg-bg-360.png
echo "✅ $OUT"
