#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SternXD <stern@sidestore.io>
# SPDX-License-Identifier: GPL-3.0+
set -e

cd "$(dirname "$0")/.."

echo "Building release..."
xcodebuild \
  -scheme Vacate \
  -configuration Release \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="-" \
  build

codesign --force --deep --sign - build/Build/Products/Release/Vacate.app

mkdir -p dist
npx create-dmg build/Build/Products/Release/Vacate.app dist --overwrite --no-code-sign

VERSION=$(defaults read "$PWD/build/Build/Products/Release/Vacate.app/Contents/Info" CFBundleShortVersionString)
mv dist/*.dmg "dist/Vacate-${VERSION}.dmg" 2>/dev/null || true
