#!/usr/bin/env bash

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Apple builds require macOS." >&2
  exit 1
fi

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${REPOSITORY_ROOT}/.build/DerivedData}"
SOURCE_PACKAGES_PATH="${SOURCE_PACKAGES_PATH:-${REPOSITORY_ROOT}/.build/SourcePackages}"
PROJECT_PATH="${REPOSITORY_ROOT}/Noted.xcodeproj"

"${REPOSITORY_ROOT}/scripts/generate-project.sh"

COMMON_ARGUMENTS=(
  -project "${PROJECT_PATH}"
  -scheme NotedApp
  -configuration Debug
  -derivedDataPath "${DERIVED_DATA_PATH}"
  -clonedSourcePackagesDirPath "${SOURCE_PACKAGES_PATH}"
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGN_IDENTITY=
)

xcodebuild \
  -resolvePackageDependencies \
  -project "${PROJECT_PATH}" \
  -scheme NotedApp \
  -clonedSourcePackagesDirPath "${SOURCE_PACKAGES_PATH}"

xcodebuild \
  "${COMMON_ARGUMENTS[@]}" \
  -destination "platform=macOS" \
  build-for-testing

xcodebuild \
  "${COMMON_ARGUMENTS[@]}" \
  -destination "platform=macOS" \
  test-without-building

xcodebuild \
  "${COMMON_ARGUMENTS[@]}" \
  -destination "generic/platform=iOS Simulator" \
  build-for-testing
