#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACT_DIR="${ROOT_DIR}/.release-artifacts"
DEFAULT_VERSION="$(
  cd "${ROOT_DIR}" &&
  rg -o 'MARKETING_VERSION = [^;]+' Orbit.xcodeproj/project.pbxproj | head -n1 | sed 's/.*= //'
)"
VERSION="${1:-${DEFAULT_VERSION:-1.0.0}}"
BUILD_PATH="${ARTIFACT_DIR}/build"
APP_PATH="${BUILD_PATH}/Build/Products/Release/Orbit.app"
DMG_PATH="${ARTIFACT_DIR}/Orbit-${VERSION}.dmg"

rm -rf "${BUILD_PATH}" "${DMG_PATH}"
mkdir -p "${ARTIFACT_DIR}"

echo "Packaging Orbit ${VERSION}"
echo "Artifacts: ${ARTIFACT_DIR}"

xcodebuild build \
  -project "${ROOT_DIR}/Orbit.xcodeproj" \
  -scheme orbit \
  -configuration Release \
  -derivedDataPath "${BUILD_PATH}" \
  MARKETING_VERSION="${VERSION}" \
  CURRENT_PROJECT_VERSION="$(cd "${ROOT_DIR}" && git rev-list --count HEAD)" \
  ENABLE_APP_SANDBOX=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO

test -d "${APP_PATH}"

hdiutil create \
  -volname "Orbit" \
  -srcfolder "${APP_PATH}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

echo
echo "DMG: ${DMG_PATH}"
echo "SHA256: $(shasum -a 256 "${DMG_PATH}" | awk '{print $1}')"
