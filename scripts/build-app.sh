#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

mkdir -p /tmp/clang-module-cache /tmp/swiftpm-cache
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/clang-module-cache}"

echo "Building TokenPulse (release)..."
swift build -c release --disable-sandbox --cache-path /tmp/swiftpm-cache

BIN_PATH="$(swift build -c release --disable-sandbox --cache-path /tmp/swiftpm-cache --show-bin-path)/TokenPulse"
APP_DIR="$ROOT_DIR/dist/TokenPulse.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/TokenPulse"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"

cp "$ROOT_DIR/Resources/TokenPulse.icns" "$RESOURCES_DIR/TokenPulse.icns"

# Ad-hoc sign so macOS notifications & LaunchServices recognize bundle identity
codesign --force --deep --sign - "$APP_DIR"

echo "Built $APP_DIR"
