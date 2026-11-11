#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./script/build-app.sh
/usr/bin/open -n dist/FFmpegFreeUI_macOS.app
if [[ "${1:-}" == --verify ]]; then
    for attempt in {1..20}; do
        if /usr/bin/pgrep -fx "$PWD/dist/FFmpegFreeUI_macOS.app/Contents/MacOS/FFmpegFreeUI_macOS"; then exit 0; fi
        sleep 0.25
    done
    exit 1
fi
