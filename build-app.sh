#!/bin/bash
# Convenience wrapper: build the double-clickable .app bundle.
set -euo pipefail
cd "$(dirname "$0")"
exec ./build.sh --app
