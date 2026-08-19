#!/bin/bash
# Build and run the unit tests (BAEval / ParticleSystem / FXSettings).
# Compiles all sources except main.swift (which launches the app) plus the
# test harness, then runs the resulting binary.
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p .build

SRCS=$(ls Sources/BaClickMac/*.swift | grep -v '/main\.swift$')

swiftc \
  -module-cache-path .build/module-cache \
  -o .build/baclick-tests \
  $SRCS Tests/main.swift \
  -framework AppKit \
  -framework Metal \
  -framework MetalKit \
  -framework MetalPerformanceShaders \
  -framework CoreGraphics \
  -framework QuartzCore

.build/baclick-tests
