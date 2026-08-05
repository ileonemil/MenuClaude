#!/bin/bash
# Crea build/MenuClaude.dmg: finestra con sfondo grafico, l'app a sinistra,
# Applicazioni a destra e le istruzioni sotto. Si trascina e basta.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/MenuClaude.app"
DMG="$ROOT/build/MenuClaude.dmg"
VOLUME="MenuClaude"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist" 2>/dev/null || echo 1.0)"

if [ ! -d "$APP" ]; then
	echo "MenuClaude.app non trovata: eseguo build.sh"
	"$ROOT/build.sh"
fi

WORK="$(mktemp -d)"
DEVICE=""
cleanup() {
	[ -n "$DEVICE" ] && hdiutil detach "$DEVICE" -quiet 2>/dev/null
	rm -rf "$WORK"
}
trap cleanup EXIT

echo "→ Sfondo"
swiftc -O -target "$(uname -m)-apple-macosx11.0" -o "$WORK/background-gen" \
	"$ROOT/Tools/make-dmg-background.swift"
# Lo script restituisce le misure con cui è stato disegnato, così finestra e
# icone combaciano con la grafica senza numeri duplicati a mano.
read -r WIN_W WIN_H APP_X APP_Y LINK_X LINK_Y < <("$WORK/background-gen" "$WORK")
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" \
	-out "$WORK/background.tiff" >/dev/null

echo "→ Immagine scrivibile"
STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$WORK/background.tiff" "$STAGE/.background/background.tiff"

rm -f "$WORK/rw.dmg"
hdiutil create -srcfolder "$STAGE" -volname "$VOLUME" -fs HFS+ \
	-format UDRW -ov "$WORK/rw.dmg" >/dev/null

# Senza -nobrowse: il Finder deve poter vedere il volume per impaginarlo.
DEVICE="$(hdiutil attach "$WORK/rw.dmg" -noautoopen -owners on | grep -E '^/dev/' | head -1 | awk '{print $1}')"
sleep 1

echo "→ Aspetto della finestra"
# Solo il Finder sa scrivere il .DS_Store che conserva sfondo e posizioni.
# Se l'automazione non è consentita, il DMG resta valido ma senza grafica.
if osascript >/dev/null 2>&1 <<APPLESCRIPT
tell application "Finder"
	tell disk "$VOLUME"
		open
		set current view of container window to icon view
		set toolbar visible of container window to false
		set statusbar visible of container window to false
		set the bounds of container window to {200, 140, $((200 + WIN_W)), $((140 + WIN_H))}
		set opts to the icon view options of container window
		set arrangement of opts to not arranged
		set icon size of opts to 112
		set background picture of opts to file ".background:background.tiff"
		set position of item "MenuClaude.app" of container window to {${APP_X}, ${APP_Y}}
		set position of item "Applications" of container window to {${LINK_X}, ${LINK_Y}}
		update without registering applications
		delay 1
		close
	end tell
end tell
APPLESCRIPT
then
	echo "  finestra personalizzata ✓"
else
	echo "  ⚠︎ il Finder non ha risposto: il DMG funziona ma senza sfondo grafico."
	echo "    Concedi a Terminale il controllo del Finder in Impostazioni di Sistema"
	echo "    › Privacy e Sicurezza › Automazione, poi rilancia."
fi

sync
hdiutil detach "$DEVICE" -quiet
DEVICE=""

echo "→ Compressione"
rm -f "$DMG"
hdiutil convert "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null

echo "✓ Pronto: $DMG ($(du -h "$DMG" | cut -f1)) — versione $VERSION"
