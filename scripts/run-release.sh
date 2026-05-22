#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACT_DIR="${ROOT_DIR}/.release-artifacts"
DEFAULT_VERSION="$(
  cd "${ROOT_DIR}" &&
  rg -o 'MARKETING_VERSION = [^;]+' Orbit.xcodeproj/project.pbxproj | head -n1 | sed 's/.*= //'
)"
VERSION="${1:-${DEFAULT_VERSION:-1.0.0}}"

ARCHIVE_PATH="${ARTIFACT_DIR}/Orbit.xcarchive"
EXPORT_PATH="${ARTIFACT_DIR}/export"
DMG_PATH="${ARTIFACT_DIR}/Orbit-${VERSION}.dmg"

rm -rf "${ARCHIVE_PATH}" "${EXPORT_PATH}" "${DMG_PATH}"
mkdir -p "${ARTIFACT_DIR}"

echo "Packaging Orbit ${VERSION}"
echo "Artifacts: ${ARTIFACT_DIR}"

xcodebuild archive \
  -project "${ROOT_DIR}/Orbit.xcodeproj" \
  -scheme orbit \
  -configuration Release \
  -archivePath "${ARCHIVE_PATH}" \
  MARKETING_VERSION="${VERSION}" \
  CURRENT_PROJECT_VERSION="$(cd "${ROOT_DIR}" && git rev-list --count HEAD)" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES

xcodebuild -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportPath "${EXPORT_PATH}" \
  -exportOptionsPlist "${ROOT_DIR}/ExportOptions.plist"

codesign \
  --sign - \
  --deep \
  --force \
  --options runtime \
  "${EXPORT_PATH}/Orbit.app"

hdiutil create \
  -volname "Orbit" \
  -srcfolder "${EXPORT_PATH}/Orbit.app" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

echo
echo "DMG: ${DMG_PATH}"
echo "SHA256: $(shasum -a 256 "${DMG_PATH}" | awk '{print $1}')"
