#!/bin/sh
# Build D3Board.app into dist/. No Xcode project, no dependencies.
set -e
cd "$(dirname "$0")"

APP=dist/D3Board.app
BIN="$APP/Contents/MacOS/D3Board"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -target arm64-apple-macos12.0 \
  Sources/Engine.swift Sources/main.swift -o "$BIN"

cp Info.plist "$APP/Contents/Info.plist"
if [ -d Resources ]; then cp -R Resources/. "$APP/Contents/Resources/"; fi
touch "$APP"

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "built $(pwd)/$APP"
