#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
APP_DIR="${BUILD_DIR}/AirTrackpad.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
WEB_RES_DIR="${RESOURCES_DIR}/web"
ICONSET_DIR="${BUILD_DIR}/AppIcon.iconset"

cd "${ROOT_DIR}"

echo "==> Building release binary..."
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/AirTrackpad"
if [[ ! -x "${BIN_PATH}" ]]; then
  echo "Error: release binary not found at ${BIN_PATH}" >&2
  exit 1
fi

echo "==> Assembling ${APP_DIR}..."
rm -rf "${APP_DIR}" "${ICONSET_DIR}"
mkdir -p "${MACOS_DIR}" "${WEB_RES_DIR}"

cp "${BIN_PATH}" "${MACOS_DIR}/AirTrackpad"
chmod +x "${MACOS_DIR}/AirTrackpad"

cp "${ROOT_DIR}/Web/index.html" "${WEB_RES_DIR}/index.html"
cp "${ROOT_DIR}/Web/style.css" "${WEB_RES_DIR}/style.css"
cp "${ROOT_DIR}/Web/gesture-engine.js" "${WEB_RES_DIR}/gesture-engine.js"
cp "${ROOT_DIR}/Web/app.js" "${WEB_RES_DIR}/app.js"

echo "==> Generating macOS .icns and PWA icons..."
swift "${ROOT_DIR}/scripts/generate-icons.swift" "${ICONSET_DIR}" "${WEB_RES_DIR}"
/usr/bin/iconutil -c icns "${ICONSET_DIR}" -o "${RESOURCES_DIR}/AppIcon.icns"
rm -rf "${ICONSET_DIR}"

cat > "${CONTENTS_DIR}/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleDisplayName</key>
  <string>AirTrackpad</string>
  <key>CFBundleExecutable</key>
  <string>AirTrackpad</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>com.airtrackpad.app</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>AirTrackpad</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>AirTrackpad 需要使用本地网络接收同一局域网或个人热点下 iPhone 发送的触控手势。</string>
</dict>
</plist>
PLIST

echo "==> Validating Info.plist..."
/usr/bin/plutil -lint "${CONTENTS_DIR}/Info.plist"

echo "==> Ad-hoc code signing..."
/usr/bin/codesign --force --deep --sign - "${APP_DIR}"
/usr/bin/codesign --verify --deep --strict "${APP_DIR}"

echo "==> Built successfully: ${APP_DIR}"
