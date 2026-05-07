#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${ROOT_DIR}/build/macos/Build/Products/Release/XplainR.app"

if [[ ! -d "${APP_PATH}" ]]; then
  echo "XplainR.app not found. Run: flutter build macos"
  exit 1
fi

codesign \
  --force \
  --deep \
  --sign - \
  --identifier pl.krzysztof.xplainr \
  --requirements '=designated => identifier "pl.krzysztof.xplainr"' \
  "${APP_PATH}"

codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
