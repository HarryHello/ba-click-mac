#!/bin/bash
# Regenerate the Homebrew cask in the tap repo after a release: writes
# Casks/ba-click.rb with the release version and the sha256 of both built
# DMGs, then commits + pushes the tap.
#
# Usage: ./tools/update-homebrew-tap.sh [version]
#   version defaults to the VERSION in build.sh. Expects
#   build/release/BA-Click-<version>-arm64.dmg and -x64.dmg to exist (run
#   ./build.sh --release first) and TAP_DIR (default ~/Development/homebrew-tap)
#   to be a clone of https://github.com/HarryHello/homebrew-tap.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(sed -n 's/^VERSION="${BA_CLICK_VERSION:-\(.*\)}"$/\1/p' build.sh)}"
TAP_DIR="${TAP_DIR:-$HOME/Development/homebrew-tap}"
ARM_DMG="build/release/BA-Click-$VERSION-arm64.dmg"
X64_DMG="build/release/BA-Click-$VERSION-x64.dmg"

[ -n "$VERSION" ] || { echo "could not read VERSION from build.sh" >&2; exit 1; }
[ -f "$ARM_DMG" ] || { echo "missing $ARM_DMG (run ./build.sh --release first)" >&2; exit 1; }
[ -f "$X64_DMG" ] || { echo "missing $X64_DMG (run ./build.sh --release first)" >&2; exit 1; }
[ -d "$TAP_DIR/.git" ] || { echo "tap clone not found at $TAP_DIR (set TAP_DIR or clone https://github.com/HarryHello/homebrew-tap)" >&2; exit 1; }

ARM_SHA=$(shasum -a 256 "$ARM_DMG" | cut -d' ' -f1)
X64_SHA=$(shasum -a 256 "$X64_DMG" | cut -d' ' -f1)

mkdir -p "$TAP_DIR/Casks"
cat > "$TAP_DIR/Casks/ba-click.rb" <<EOF
cask "ba-click" do
  version "$VERSION"

  on_arm do
    sha256 "$ARM_SHA"

    url "https://github.com/HarryHello/ba-click-mac/releases/download/v#{version}/BA-Click-#{version}-arm64.dmg"
  end
  on_intel do
    sha256 "$X64_SHA"

    url "https://github.com/HarryHello/ba-click-mac/releases/download/v#{version}/BA-Click-#{version}-x64.dmg"
  end

  name "BA Click"
  desc "Blue Archive style click effect and cursor trail"
  homepage "https://github.com/HarryHello/ba-click-mac"

  livecheck do
    url "https://github.com/HarryHello/ba-click-mac/releases/latest"
    regex(/BA-Click[._-]v?(\d+(?:\.\d+)+)[._-]arm64\.dmg/i)
  end

  depends_on :macos

  app "BA Click.app"

  zap trash: [
    "~/.ba-click-mac-settings.json",
    "~/.ba-click-mac.lock",
  ]
end
EOF

cd "$TAP_DIR"
git add Casks/ba-click.rb
if git diff --cached --quiet; then
  echo "tap already up to date for $VERSION"
else
  git commit -m "ba-click $VERSION"
  git push
fi
echo "✅ tap updated — users install with: brew install --cask harryhello/tap/ba-click"
