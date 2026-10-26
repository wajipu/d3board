#!/bin/sh
# Build D3Board.app into dist/. No Xcode project, no dependencies.
#
#   ./build.sh                          build for this Mac's arch (fast, local)
#   ARCHS="arm64 x86_64" ./build.sh     universal binary (what CI does)
#   VERSION=1.2.0 ./build.sh            stamp a version into the bundle
set -e
cd "$(dirname "$0")"

APP=dist/D3Board.app
WORK=build
ARCHS=${ARCHS:-$(uname -m)}

rm -rf "$APP" "$WORK"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$WORK"

SLICES=""
for arch in $ARCHS; do
  case "$arch" in
    arm64|x86_64) ;;
    *) echo "build.sh: unsupported arch '$arch'" >&2; exit 1 ;;
  esac
  swiftc -O -swift-version 5 -target "${arch}-apple-macos12.0" \
    Sources/Engine.swift Sources/main.swift -o "$WORK/D3Board-$arch"
  SLICES="$SLICES $WORK/D3Board-$arch"
done

# shellcheck disable=SC2086
lipo -create $SLICES -output "$APP/Contents/MacOS/D3Board"

cp Info.plist "$APP/Contents/Info.plist"
if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER:-1}" "$APP/Contents/Info.plist"
fi
if [ -d Resources ]; then cp -R Resources/. "$APP/Contents/Resources/"; fi
touch "$APP"

# Ad-hoc signature: enough to run locally, not notarized for distribution.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "built $(pwd)/$APP ($(lipo -archs "$APP/Contents/MacOS/D3Board"))"
