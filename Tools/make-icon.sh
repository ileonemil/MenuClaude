#!/bin/bash
# Rigenera Resources/AppIcon.icns partendo da make-icon.swift.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

swiftc -O -target "$(uname -m)-apple-macosx11.0" -o "$TMP/gen" "$ROOT/Tools/make-icon.swift"
"$TMP/gen" "$TMP"

SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
cp "$TMP/icon_16.png"   "$SET/icon_16x16.png"
cp "$TMP/icon_32.png"   "$SET/icon_16x16@2x.png"
cp "$TMP/icon_32.png"   "$SET/icon_32x32.png"
cp "$TMP/icon_64.png"   "$SET/icon_32x32@2x.png"
cp "$TMP/icon_128.png"  "$SET/icon_128x128.png"
cp "$TMP/icon_256.png"  "$SET/icon_128x128@2x.png"
cp "$TMP/icon_256.png"  "$SET/icon_256x256.png"
cp "$TMP/icon_512.png"  "$SET/icon_256x256@2x.png"
cp "$TMP/icon_512.png"  "$SET/icon_512x512.png"
cp "$TMP/icon_1024.png" "$SET/icon_512x512@2x.png"

mkdir -p "$ROOT/Resources"
iconutil -c icns "$SET" -o "$ROOT/Resources/AppIcon.icns"
echo "✓ Resources/AppIcon.icns"
