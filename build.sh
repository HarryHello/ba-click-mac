#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p .build/Resources
cp Resources/* .build/Resources/
swiftc \
  -module-cache-path .build/module-cache \
  -o .build/ba-click-mac \
  Sources/BaClickMac/*.swift \
  -framework AppKit \
  -framework Metal \
  -framework MetalKit \
  -framework MetalPerformanceShaders \
  -framework CoreGraphics \
  -framework QuartzCore

echo "✅ Built .build/ba-click-mac"
echo "Run with: ./.build/ba-click-mac"