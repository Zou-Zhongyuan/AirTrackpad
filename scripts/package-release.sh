#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-v1.0.0}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
ZIP_NAME="AirTrackpad-${VERSION}-macOS-arm64.zip"
ZIP_PATH="${BUILD_DIR}/${ZIP_NAME}"

cd "${ROOT_DIR}"

"${ROOT_DIR}/scripts/build-app.sh"

echo "==> Creating release archive ${ZIP_PATH}..."
rm -f "${ZIP_PATH}" "${BUILD_DIR}/SHA256SUMS.txt"
ditto -c -k --sequesterRsrc --keepParent "${BUILD_DIR}/AirTrackpad.app" "${ZIP_PATH}"

echo "==> Computing SHA-256 checksum..."
(
  cd "${BUILD_DIR}"
  shasum -a 256 "${ZIP_NAME}" > SHA256SUMS.txt
)

echo "==> Copying app icon to docs/assets/icon-512.png..."
mkdir -p "${ROOT_DIR}/docs/assets"
cp "${BUILD_DIR}/AirTrackpad.app/Contents/Resources/web/icon-512.png" "${ROOT_DIR}/docs/assets/icon-512.png"

echo "==> Release artifacts ready:"
cat "${BUILD_DIR}/SHA256SUMS.txt"
