#!/usr/bin/env bash
# Compila em release e monta LowerX.app (app só de barra de menus, assinatura ad-hoc).
# O bundle é montado fora deste volume (exFAT cria arquivos ._* que quebram o codesign)
# e instalado em /Applications (ou em DEST=/outro/lugar).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
DEST="${DEST:-/Applications}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/LowerX.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/LowerX" "$APP/Contents/MacOS/LowerX"

# Imagens dos produtos (tools/prepare_device_images.py) e a fonte da HyperX.
cp -R Assets/Devices Assets/Fonts Assets/AppIcon.icns "$APP/Contents/Resources/"
find "$APP/Contents/Resources" -name '._*' -delete

# Driver da saída virtual 7.1 (instalado pelo próprio app em /Library/Audio/Plug-Ins/HAL).
DRIVER="$APP/Contents/Resources/LowerX71.driver"
mkdir -p "$DRIVER/Contents/MacOS"
cp Driver/Info.plist "$DRIVER/Contents/Info.plist"
clang -bundle -O2 -Wall -mmacosx-version-min=14.2 -arch arm64 -arch x86_64 \
    -framework CoreAudio -framework CoreFoundation \
    -o "$DRIVER/Contents/MacOS/LowerX71" Driver/LowerX71.c
# Arquivos vindos do exFAT chegam com permissão 0700; o coreaudiod carrega o driver
# com um usuário próprio e precisa ler tudo.
chmod -R u=rwX,go=rX "$DRIVER"
codesign --force --sign - "$DRIVER"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.local.lowerx</string>
    <key>CFBundleName</key><string>LowerX</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleExecutable</key><string>LowerX</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.2</string>
    <key>LSUIElement</key><true/>
    <key>ATSApplicationFontsPath</key><string>Fonts</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>O equalizador processa o áudio do Mac antes de enviá-lo ao headset.</string>
    <key>NSAppTransportSecurity</key>
    <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
mkdir -p "$DEST"
rm -rf "$DEST/LowerX.app"
ditto "$APP" "$DEST/LowerX.app"
echo "Pronto: $DEST/LowerX.app"
