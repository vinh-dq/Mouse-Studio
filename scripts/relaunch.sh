#!/bin/zsh
# Quits the running Mouse Studio and opens the app in ./build.
# Usage: scripts/relaunch.sh          (open the existing build)
#        scripts/relaunch.sh --build  (build first, then open)
set -euo pipefail
cd "$(dirname "$0")/.."

[[ "${1:-}" == "--build" ]] && ./scripts/build_app.sh

[[ -d "build/Mouse Studio.app" ]] || { echo "No build found. Run: scripts/relaunch.sh --build"; exit 1; }

pkill -x MouseStudio || true
while pgrep -x MouseStudio >/dev/null; do sleep 0.2; done
open "build/Mouse Studio.app"
echo "Opened: build/Mouse Studio.app"
