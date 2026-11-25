#!/bin/bash
# Compila ArtNet Stage SENZA Xcode, usando solo i Command Line Tools,
# e crea il bundle ArtNetStage.app nella stessa cartella dello script.
#
# Uso:   bash build_app.sh
#
# Icona: se accanto allo script c'è AppIcon.png (quadrata, consigliato 1024x1024),
# viene convertita in AppIcon.icns con `sips` + `iconutil` (strumenti di macOS) e inserita
# nel bundle. Senza AppIcon.png l'app viene creata con l'icona generica.
set -euo pipefail
cd "$(dirname "$0")"

APP="ArtNetStage.app"
NAME="ArtNetStage"
MIN_MACOS="13.0"

APP_VERSION="2.3"       # CFBundleShortVersionString (deve coincidere con AppInfo.version nel codice)
APP_BUILD="10"           # CFBundleVersion            (deve coincidere con AppInfo.build nel codice)
ICON_SRC="AppIcon.png"  # sorgente dell'icona, nella cartella principale del repository
ICON_NAME="AppIcon"     # nome del file .icns nel bundle = valore di CFBundleIconFile

if ! command -v swiftc >/dev/null 2>&1 || ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "Compilatore Swift non trovato."
    echo "Installa i Command Line Tools (molto più leggeri di Xcode) con:  xcode-select --install"
    echo "poi rilancia:  bash build_app.sh"
    exit 1
fi

# Converte un PNG quadrato in un file .icns con tutte le dimensioni richieste da macOS.
#   $1 = PNG sorgente   $2 = file .icns di destinazione
# Restituisce 0 se l'icona è stata creata, 1 altrimenti (il chiamante decide cosa fare).
make_icns() {
    local src="$1" dst="$2" tmp iconset w h spec px name

    if ! command -v sips >/dev/null 2>&1 || ! command -v iconutil >/dev/null 2>&1; then
        echo "  'sips' o 'iconutil' non trovati (servono macOS)."
        return 1
    fi

    w="$(sips -g pixelWidth "$src" 2>/dev/null | awk '/pixelWidth/ {print $2}')"
    h="$(sips -g pixelHeight "$src" 2>/dev/null | awk '/pixelHeight/ {print $2}')"
    if [ -z "$w" ] || [ -z "$h" ]; then
        echo "  '$src' non sembra un'immagine valida."
        return 1
    fi
    if [ "$w" != "$h" ]; then
        echo "  '$src' è ${w}x${h}: l'icona deve essere quadrata (consigliato 1024x1024)."
        return 1
    fi
    if [ "$w" -lt 1024 ]; then
        echo "  Avviso: '$src' è ${w}x${w}, le dimensioni grandi risulteranno sfocate (consigliato 1024x1024)."
    fi

    tmp="$(mktemp -d)"
    iconset="$tmp/$ICON_NAME.iconset"
    mkdir -p "$iconset"

    # Serie standard di un .iconset: "pixel nome-file"
    for spec in \
        "16 icon_16x16"      "32 icon_16x16@2x" \
        "32 icon_32x32"      "64 icon_32x32@2x" \
        "128 icon_128x128"   "256 icon_128x128@2x" \
        "256 icon_256x256"   "512 icon_256x256@2x" \
        "512 icon_512x512"   "1024 icon_512x512@2x"; do
        px="${spec%% *}"
        name="${spec#* }"
        if ! sips -z "$px" "$px" "$src" --out "$iconset/$name.png" >/dev/null 2>&1; then
            echo "  Ridimensionamento a ${px}px non riuscito."
            rm -rf "$tmp"
            return 1
        fi
    done

    if ! iconutil -c icns "$iconset" -o "$dst" >/dev/null 2>&1; then
        echo "  'iconutil' non è riuscito a creare il file .icns."
        rm -rf "$tmp"
        return 1
    fi

    rm -rf "$tmp"
    return 0
}

ARCH="$(uname -m)"          # arm64 oppure x86_64
echo "Architettura: $ARCH  ·  macOS minimo: $MIN_MACOS  ·  versione $APP_VERSION ($APP_BUILD)"
swiftc --version 2>&1 | head -1

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

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

# Info.plist del bundle: parte dal file del progetto (tipo di file .artnetstage, permesso rete locale)…
if [ ! -f Info.plist ]; then
    echo "Info.plist non trovato accanto a build_app.sh."
    exit 1
fi
PLIST="$APP/Contents/Info.plist"
cp Info.plist "$PLIST"

# …e riceve versione e icona in modo esplicito (plutil -replace aggiunge la chiave se manca).
plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$PLIST"
plutil -replace CFBundleVersion -string "$APP_BUILD" "$PLIST"

# Icona dell'app: AppIcon.png → AppIcon.icns → Contents/Resources + CFBundleIconFile
echo "Icona…"
ICON_OK=0
if [ -f "$ICON_SRC" ]; then
    if make_icns "$ICON_SRC" "$APP/Contents/Resources/$ICON_NAME.icns"; then
        ICON_OK=1
        echo "  $ICON_SRC → Contents/Resources/$ICON_NAME.icns"
    else
        echo "  Continuo senza icona personalizzata."
    fi
else
    echo "  $ICON_SRC non trovato accanto a build_app.sh: uso l'icona generica."
fi

if [ "$ICON_OK" = "1" ]; then
    plutil -replace CFBundleIconFile -string "$ICON_NAME" "$PLIST"
else
    plutil -remove CFBundleIconFile "$PLIST" 2>/dev/null || true   # nessun riferimento a un file inesistente
fi

plutil -lint "$PLIST" >/dev/null || { echo "Info.plist del bundle non valido."; exit 1; }

# Firma ad-hoc (nessun account sviluppatore necessario). Nessuna sandbox: non si applica entitlement.
# Va fatta DOPO aver inserito icona e Info.plist, altrimenti la firma risulterebbe non valida.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "(avviso: firma ad-hoc non riuscita, l'app dovrebbe comunque partire)"

# Aggiorna la data del bundle così il Finder rilegge subito l'icona.
touch "$APP"

echo
echo "Fatto: $(pwd)/$APP"
echo "Avvio con:  open \"$APP\""
if [ "${NO_OPEN:-0}" != "1" ]; then
    open "$APP" || true
fi
