#!/bin/bash
# Compila o ShortcutKey e monta build/ShortcutKey.app (não precisa do Xcode).
set -euo pipefail
cd "$(dirname "$0")"

# UNIVERSAL=1 ./build.sh gera um app que roda em Macs Apple Silicon e Intel (usado no release).
BUILD_FLAGS=(-c release)
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    BUILD_FLAGS+=(--arch arm64 --arch x86_64)
fi
swift build "${BUILD_FLAGS[@]}"

APP="build/ShortcutKey.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)/ShortcutKey" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "$APP/Contents/Resources/"

# Assinatura: com o certificado "ShortcutKey Dev" (veja o README) a assinatura fica sempre igual
# e o macOS lembra das permissões entre compilações.
IDENTITY="ShortcutKey Dev"
# Se o chaveiro estiver bloqueado, o codesign pode ficar esperando uma janela de senha para sempre.
# Por isso ele tem 15 segundos; depois disso o build segue com a assinatura ad-hoc.
sign_with_timeout() {
    codesign --force --sign "$IDENTITY" "$APP" 2>/dev/null &
    local pid=$!
    for _ in $(seq 1 15); do
        sleep 1
        kill -0 "$pid" 2>/dev/null || { wait "$pid"; return $?; }
    done
    kill "$pid" 2>/dev/null
    return 1
}

if security find-certificate -c "$IDENTITY" >/dev/null 2>&1 && sign_with_timeout; then
    echo "Assinado com o certificado \"$IDENTITY\" — as permissões continuam valendo."
elif security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    codesign --force --sign - "$APP"
    echo "⚠️  Não foi possível usar o certificado (chaveiro bloqueado?). Assinado ad-hoc;"
    echo "    reinicie a sessão ou desbloqueie o chaveiro e rode o build de novo."
else
    # Assinatura ad-hoc: muda a cada compilação e o macOS passa a ignorar a permissão antiga
    # (a chave continua ligada em Ajustes, mas não vale mais). Remove as entradas velhas para
    # o macOS pedir as permissões de novo na próxima vez que o app abrir.
    codesign --force --sign - "$APP"
    tccutil reset Accessibility app.shortcutkey.ShortcutKey >/dev/null 2>&1 || true
    tccutil reset ScreenCapture app.shortcutkey.ShortcutKey >/dev/null 2>&1 || true
    echo "Assinatura ad-hoc: libere Acessibilidade e Gravação de Tela de novo ao abrir o app."
fi

echo "Pronto: $APP"
echo "Para instalar: cp -R \"$APP\" /Applications/"
