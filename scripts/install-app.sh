#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SRC="${ROOT_DIR}/build/AirTrackpad.app"
APP_DEST="/Applications/AirTrackpad.app"

"${ROOT_DIR}/scripts/build-app.sh"

echo "==> Stopping running AirTrackpad (if any)..."
pkill -x AirTrackpad 2>/dev/null || true
sleep 0.5

echo "==> Installing to ${APP_DEST}..."
rm -rf "${APP_DEST}"
ditto "${APP_SRC}" "${APP_DEST}"
/usr/bin/codesign --verify --deep --strict "${APP_DEST}"

echo "==> Installed! Launching AirTrackpad..."
open "${APP_DEST}"
