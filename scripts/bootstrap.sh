#!/usr/bin/env bash

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Noted's Apple project must be generated on macOS." >&2
  exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required to install XcodeGen: https://brew.sh" >&2
  exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  brew install xcodegen
fi

"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/generate-project.sh"
