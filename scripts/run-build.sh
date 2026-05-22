#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="${ROOT_DIR}/.build-logs"
mkdir -p "${LOG_DIR}"

timestamp="$(date +"%Y%m%d-%H%M%S")"
log_path="${LOG_DIR}/build-${timestamp}.log"

cmd=(
  xcodebuild
  -project Orbit.xcodeproj
  -scheme orbit
  -destination "platform=macOS"
  build
)

echo "Running build..."
echo "Log: ${log_path}"

(
  cd "${ROOT_DIR}"
  if ! "${cmd[@]}" > "${log_path}" 2>&1; then
    echo
    echo "Build failed. Recent log output:"
    echo
    tail -n 80 "${log_path}"
    exit 1
  fi
)

echo
echo "Build succeeded"
echo "Log: ${log_path}"
