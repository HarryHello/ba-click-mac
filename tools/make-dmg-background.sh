#!/bin/bash
# Regenerate Resources/dmg-background.jpg: room_night.png resized to the
# DMG window size (640x360), JPEG-compressed.
#
# Usage: ./tools/make-dmg-background.sh [path/to/room_night.png]
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${1:-../room_night.png}"
OUT="Resources/dmg-background.jpg"
[ -f "$SRC" ] || { echo "source not found: $SRC" >&2; exit 1; }

sips -s format jpeg -s formatOptions 80 -z 360 640 "$SRC" --out "$OUT" >/dev/null
echo "✅ $OUT"
