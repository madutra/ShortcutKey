#!/bin/bash
# Gera os arquivos para publicar no GitHub Releases:
#   dist/ShortcutKey-<versão>.dmg  (arrastar para Aplicativos)
#   dist/ShortcutKey-<versão>.zip
set -euo pipefail
cd "$(dirname "$0")/.."

UNIVERSAL=1 ./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
APP="build/ShortcutKey.app"
DIST="dist"
rm -rf "$DIST"
mkdir -p "$DIST"

# ZIP (ditto preserva a assinatura e os atributos do app)
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/ShortcutKey-$VERSION.zip"

# DMG com atalho para a pasta Aplicativos
STAGING=$(mktemp -d)
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "ShortcutKey" -srcfolder "$STAGING" -ov -format UDZO \
    "$DIST/ShortcutKey-$VERSION.dmg" >/dev/null
rm -rf "$STAGING"

echo
echo "Release $VERSION pronto em $DIST/:"
ls -lh "$DIST"
