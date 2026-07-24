#!/usr/bin/env bash

set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen 2.45.4 or newer is required. Run 'make bootstrap' on macOS." >&2
  exit 1
fi

cd "${REPOSITORY_ROOT}"
xcodegen generate --spec project.yml
