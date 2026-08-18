#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -x .build/ba-click-mac ]; then
  ./build.sh
fi

exec ./.build/ba-click-mac