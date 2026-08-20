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

# Isolate from the user's real ~/.ba-click-mac-settings.json: FXSettings.load()
# walks candidate URLs beyond the cwd file (cwd -> exe dir -> $HOME), so the
# "invalid JSON falls back to defaults" test could otherwise pick up the user's
# real settings file and fail. Running with a throwaway HOME makes the test
# hermetic.
TEST_HOME="$(mktemp -d)"
trap 'rm -rf "$TEST_HOME"' EXIT

HOME="$TEST_HOME" .build/baclick-tests
