#!/bin/bash
# Compila ArtNet Stage SENZA Xcode, usando solo i Command Line Tools,
# e crea il bundle ArtNetStage.app nella stessa cartella dello script.
#
# Uso:   bash build_app.sh
set -euo pipefail
cd "$(dirname "$0")"

APP="ArtNetStage.app"
NAME="ArtNetStage"
MIN_MACOS="13.0"

if ! command -v swiftc >/dev/null 2>&1 || ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "Compilatore Swift non trovato."
    echo "Installa i Command Line Tools (molto più leggeri di Xcode) con:  xcode-select --install"
    echo "poi rilancia:  bash build_app.sh"
    exit 1
fi

ARCH="$(uname -m)"          # arm64 oppure x86_64
echo "Architettura: $ARCH  ·  macOS minimo: $MIN_MACOS"
swiftc --version 2>&1 | head -1

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find "$NAME" -name '*.swift' | sort)
echo "File sorgente: ${#SOURCES[@]}"

compile_for() {   # $1 = architettura, $2 = file di output
    swiftc -O -wmo -parse-as-library \
        -module-name "$NAME" \
        -target "$1-apple-macosx${MIN_MACOS}" \
        "${SOURCES[@]}" \
        -o "$2"
}

echo "Compilo… (1-3 minuti, i warning sono normali)"
if [ "${UNIVERSAL:-0}" = "1" ]; then
    # Binario universale (Apple Silicon + Intel), usato dalla build su GitHub.
    compile_for arm64 "build_tmp_arm64"
    compile_for x86_64 "build_tmp_x86_64"
    lipo -create build_tmp_arm64 build_tmp_x86_64 -output "$APP/Contents/MacOS/$NAME"
    rm -f build_tmp_arm64 build_tmp_x86_64
else
    compile_for "$ARCH" "$APP/Contents/MacOS/$NAME"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ArtNet Stage</string>
    <key>CFBundleDisplayName</key><string>ArtNet Stage</string>
    <key>CFBundleIdentifier</key><string>local.artnetstage.app</string>
    <key>CFBundleExecutable</key><string>ArtNetStage</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>ArtNet Stage riceve pacchetti Art-Net/DMX dalla rete locale.</string>
</dict>
</plist>
PLIST

# Firma ad-hoc (nessun account sviluppatore necessario). Nessuna sandbox: non si applica entitlement.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "(avviso: firma ad-hoc non riuscita, l'app dovrebbe comunque partire)"

echo
echo "Fatto: $(pwd)/$APP"
echo "Avvio con:  open \"$APP\""
if [ "${NO_OPEN:-0}" != "1" ]; then
    open "$APP" || true
fi
