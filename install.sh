#!/bin/bash
# Installa MenuClaude in /Applications e la avvia.
#
# Perché esiste: MenuClaude non è firmata da uno sviluppatore Apple registrato
# e da macOS 15 il vecchio trucco del clic destro → Apri non funziona più. Un
# file scaricato da un browser viene messo "in quarantena" e Gatekeeper lo
# blocca; scaricato con curl, invece, la quarantena non viene applicata affatto,
# quindi l'app parte senza passare da Impostazioni di Sistema.
#
#   curl -fsSL https://raw.githubusercontent.com/ileonemil/MenuClaude/main/install.sh | bash
#
set -euo pipefail

REPO="ileonemil/MenuClaude"
DEST="/Applications/MenuClaude.app"
WORK="$(mktemp -d)"
trap 'hdiutil detach "$WORK/mnt" -quiet 2>/dev/null || true; rm -rf "$WORK"' EXIT

say() { printf '%s\n' "$1"; }

say "MenuClaude — installazione / install"
say ""

# 1. Ultima release
say "→ Cerco l'ultima versione…"
API="https://api.github.com/repos/$REPO/releases/latest"
# Solo grep e sed: su un Mac senza gli strumenti da sviluppatore `python3` non
# c'è davvero, è un segnaposto che apre la finestra di installazione di Xcode.
URL="$(curl -fsSL "$API" \
	| grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*\.dmg"' \
	| head -1 \
	| sed 's/.*"\(https[^"]*\)"/\1/')"
if [ -z "${URL:-}" ]; then
	say "✗ Nessun DMG nella release. Riprova più tardi o scarica a mano:"
	say "  https://github.com/$REPO/releases/latest"
	exit 1
fi
VERSION="$(basename "$(dirname "$URL")")"
say "  trovata $VERSION"

# 2. Download
say "→ Scarico…"
curl -fL# -o "$WORK/MenuClaude.dmg" "$URL"

# 3. Estrazione
say "→ Installo in /Applications…"
mkdir -p "$WORK/mnt"
hdiutil attach "$WORK/MenuClaude.dmg" -mountpoint "$WORK/mnt" -nobrowse -readonly -quiet

if [ ! -d "$WORK/mnt/MenuClaude.app" ]; then
	say "✗ Il DMG non contiene MenuClaude.app"
	exit 1
fi

# Se è già in esecuzione va chiusa, altrimenti la sostituzione lascia in giro
# una copia vecchia ancora viva.
if pgrep -f "MenuClaude.app/Contents/MacOS/MenuClaude" >/dev/null 2>&1; then
	say "  chiudo la versione in esecuzione"
	pkill -f "MenuClaude.app/Contents/MacOS/MenuClaude" || true
	sleep 1
fi

rm -rf "$DEST"
ditto "$WORK/mnt/MenuClaude.app" "$DEST"
hdiutil detach "$WORK/mnt" -quiet
# Cintura e bretelle: curl non mette la quarantena, ma se qualcuno lancia questo
# script su un file scaricato altrimenti, meglio toglierla comunque.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

# 4. Avvio
say "→ Avvio…"
open "$DEST"

say ""
say "✓ Fatto. L'icona è nella barra dei menu, in alto a destra — non nel Dock."
say ""
say "  Al primo avvio macOS chiede l'accesso al portachiavi: scegli «Sempre»."
say "  Serve per leggere il token di Claude Code e sapere quanto hai consumato."
say ""
say "  Done. The icon is in the menu bar, top right — not in the Dock."
say "  macOS will ask for Keychain access: choose \"Always Allow\"."
