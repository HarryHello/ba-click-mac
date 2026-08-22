#!/bin/bash
# Build (if needed) then run the raw binary. Rebuilds automatically when any
# source file or resource is newer than the existing binary, so ./run.sh never
# silently runs stale code.
set -euo pipefail
cd "$(dirname "$0")"

BIN=.build/ba-click-mac

needs_rebuild() {
  [ ! -x "$BIN" ] && return 0
  # Any source or resource newer than the binary => rebuild.
  if find Sources Resources -type f -newer "$BIN" -print -quit 2>/dev/null | grep -q .; then
    return 0
  fi
  return 1
}

if needs_rebuild; then
  ./build.sh
fi

exec "$BIN"
