#!/bin/bash
# Compile + run the SVG->PNG converter (projects the module cache so it works
# in restricted environments too).
#
# Usage: ./tools/svg2png.sh <input.svg> <output.png> <pixelSize>
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p .build
swiftc \
  -module-cache-path .build/module-cache \
  tools/svg2png.swift \
  -o .build/svg2png \
  -framework AppKit

.build/svg2png "$@"
