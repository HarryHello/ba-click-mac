#!/bin/bash
# Build the ba-click-mac overlay.
#   ./build.sh            -> command-line binary at .build/ba-click-mac
#   ./build.sh --app      -> double-clickable app bundle at build/BaClickMac.app
#   ./build.sh --release  -> signed arm64 + x64 DMGs at build/release/
#
# Release signing uses the local self-signed identity "BA Click Mac Signing"
# (override with BA_CLICK_SIGN_IDENTITY) and the version from BA_CLICK_VERSION
# (default 0.1.0). DMGs are NOT notarized — self-signed certificates cannot be
# notarized, so first launch shows the standard "unidentified developer"
# prompt on other machines (right-click -> Open to bypass).
#
# For reproducibility, --release can import the .p12 into a throwaway signing
# keychain instead of relying on the login keychain ACL:
#   BA_CLICK_P12=/path/to/signing.p12 BA_CLICK_P12_PASSWORD=... ./build.sh --release
# If BA_CLICK_P12 is unset, the identity is looked up in the default keychains.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${BA_CLICK_VERSION:-0.1.0}"
SIGN_IDENTITY="${BA_CLICK_SIGN_IDENTITY:-BA Click Mac Signing}"
# macOS 14 is the floor: the primary render driver is a CADisplayLink
# (the macOS 13 Timer fallback stays in the code but is no longer a target).
DEPLOY_TARGET="14.0"
FRAMEWORKS="-framework AppKit -framework Metal -framework MetalKit -framework MetalPerformanceShaders -framework CoreGraphics -framework QuartzCore"

MODE="${1:-}"

# Write a versioned Info.plist into an app bundle root ($1).
write_info_plist() {
  cat > "$1/Contents/Info.plist" <<EOF
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
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>$DEPLOY_TARGET</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF
}

case "$MODE" in
  "")
    mkdir -p .build/Resources
    cp Resources/* .build/Resources/
    swiftc \
      -module-cache-path .build/module-cache \
      -o .build/ba-click-mac \
      Sources/BaClickMac/*.swift \
      $FRAMEWORKS
    echo "✅ Built .build/ba-click-mac"
    echo "Run with: ./.build/ba-click-mac"
    ;;

  --app)
    APP=build/BaClickMac.app
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    cp Resources/* "$APP/Contents/Resources/"
    swiftc \
      -module-cache-path .build/module-cache \
      -o "$APP/Contents/MacOS/BaClickMac" \
      Sources/BaClickMac/*.swift \
      $FRAMEWORKS
    write_info_plist "$APP"
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
    echo "✅ Built $APP"
    echo "Run with: open $APP"
    ;;

  --release)
    RELEASE=build/release
    rm -rf "$RELEASE"
    mkdir -p "$RELEASE"
    echo "🔑 Signing identity: $SIGN_IDENTITY"
    echo "📦 Version: $VERSION"

    # Throwaway signing keychain so codesign never depends on the login
    # keychain ACL (self-signed certs usually sit there without a codesign
    # partition list). Cleaned up after all DMGs are built.
    TMP_KEYCHAIN=""
    SIGN_ARGS=()
    if [ -n "${BA_CLICK_P12:-}" ]; then
      TMP_KEYCHAIN="$RELEASE/signing.keychain-db"
      KC_PW="$(uuidgen)"
      echo "🔐 Creating throwaway signing keychain..."
      security create-keychain -p "$KC_PW" "$TMP_KEYCHAIN"
      security set-keychain-settings -lut 3600 "$TMP_KEYCHAIN"
      security unlock-keychain -p "$KC_PW" "$TMP_KEYCHAIN"
      security import "$BA_CLICK_P12" \
        -k "$TMP_KEYCHAIN" \
        -P "${BA_CLICK_P12_PASSWORD:-}" \
        -T /usr/bin/codesign
      security set-key-partition-list \
        -S apple-tool:,apple:,codesign: \
        -s -k "$KC_PW" "$TMP_KEYCHAIN"
      security find-identity -v -p codesigning "$TMP_KEYCHAIN"
      SIGN_ARGS=(--keychain "$TMP_KEYCHAIN")
    fi

    for SPEC in "arm64 arm64" "x64 x86_64"; do
      read -r ARCH TRIPLE <<< "$SPEC"
      APP="$RELEASE/$ARCH/BA Click.app"
      mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
      cp Resources/* "$APP/Contents/Resources/"
      echo "⚙️  Building $ARCH ($TRIPLE-apple-macos$DEPLOY_TARGET)..."
      swiftc \
        -target "$TRIPLE-apple-macos$DEPLOY_TARGET" \
        -module-cache-path ".build/module-cache-$ARCH" \
        -o "$APP/Contents/MacOS/BaClickMac" \
        Sources/BaClickMac/*.swift \
        $FRAMEWORKS
      write_info_plist "$APP"
      echo "✍️  Signing $ARCH app..."
      codesign "${SIGN_ARGS[@]}" --force --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/BaClickMac"
      codesign "${SIGN_ARGS[@]}" --force --sign "$SIGN_IDENTITY" "$APP"
      codesign --verify --strict --verbose=2 "$APP" >/dev/null
      DMGSTAGE="$RELEASE/dmg-$ARCH"
      mkdir -p "$DMGSTAGE"
      cp -R "$APP" "$DMGSTAGE/"
      ln -s /Applications "$DMGSTAGE/Applications"
      echo "💿 Building $ARCH DMG..."
      hdiutil create \
        -volname "BA Click" \
        -srcfolder "$DMGSTAGE" \
        -ov -format UDZO \
        "$RELEASE/BA-Click-$VERSION-$ARCH.dmg" >/dev/null
      rm -rf "$DMGSTAGE"
    done

    if [ -n "$TMP_KEYCHAIN" ]; then
      security delete-keychain "$TMP_KEYCHAIN" >/dev/null 2>&1 || true
    fi

    echo "✅ Built signed DMGs:"
    ls -lh "$RELEASE"/*.dmg
    echo "Drag BA Click.app into /Applications to install."
    ;;

  *)
    echo "Unknown mode: $MODE" >&2
    echo "Usage: ./build.sh [--app|--release]" >&2
    exit 1
    ;;
esac
