#!/bin/bash
# Compila MenuClaude.app senza Xcode: bastano i Command Line Tools.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/MenuClaude.app"
ARCH="$(uname -m)"

echo "→ Pulizia"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ Compilazione ($ARCH)"
# shellcheck disable=SC2046
swiftc \
	-O \
	-target "${ARCH}-apple-macosx11.0" \
	-module-name MenuClaude \
	-framework Cocoa \
	-o "$APP/Contents/MacOS/MenuClaude" \
	$(find "$ROOT/Sources" -name '*.swift' | sort)

echo "→ Bundle"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
	cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# L'autorizzazione del portachiavi ("Sempre") è legata all'identità del codice
# firmato. Con la firma ad-hoc quell'identità è l'hash del binario, quindi ogni
# ricompilazione fa ricomparire il pannello una volta. Un certificato di firma
# personale, se presente, rende l'autorizzazione permanente.
IDENTITY="${MENUCLAUDE_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "MenuClaude"; then
	IDENTITY="MenuClaude"
fi

if [ -n "$IDENTITY" ]; then
	echo "→ Firma con «$IDENTITY»"
	codesign --force --sign "$IDENTITY" --identifier com.menuclaude.MenuClaude "$APP"
else
	echo "→ Firma ad-hoc"
	codesign --force --sign - --identifier com.menuclaude.MenuClaude "$APP"
	echo "  (al primo avvio il portachiavi chiederà di nuovo l'autorizzazione:"
	echo "   scegli «Sempre» — vale finché non ricompili)"
fi

echo "✓ Pronto: $APP"
