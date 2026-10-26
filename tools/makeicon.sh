#!/bin/sh
# Regenerate Resources/AppIcon.icns from tools/genicon.swift.
set -e
cd "$(dirname "$0")/.."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

swiftc -O tools/genicon.swift -o "$TMP/genicon"
"$TMP/genicon" "$TMP"

ISET="$TMP/AppIcon.iconset"
mkdir -p "$ISET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$TMP/icon-1024.png" --out "$ISET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$TMP/icon-1024.png" --out "$ISET/icon_${size}x${size}@2x.png" >/dev/null
done

mkdir -p Resources
iconutil -c icns "$ISET" -o Resources/AppIcon.icns
echo "wrote Resources/AppIcon.icns"
