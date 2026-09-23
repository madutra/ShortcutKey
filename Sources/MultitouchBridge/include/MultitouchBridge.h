#ifndef MULTITOUCH_BRIDGE_H
#define MULTITOUCH_BRIDGE_H

/// Um dedo no trackpad, com posição normalizada (0...1, origem no canto inferior esquerdo).
typedef struct {
    int identifier;
    int state;
    float x;
    float y;
    float size;
} SKTouch;

typedef void (*SKTouchHandler)(const SKTouch *touches, int count, double timestamp);

/// Começa a ler os trackpads. Retorna o número de dispositivos encontrados,
/// ou -1 se o framework MultitouchSupport não estiver disponível.
int SKMultitouchStart(SKTouchHandler handler);

/// Para de ler os trackpads.
void SKMultitouchStop(void);

/// Envia uma notificação privada ao Dock (ex.: "com.apple.showdesktop.awake").
/// Retorna 0 se a função não estiver disponível.
int SKCoreDockSend(const char *notification);

/// ID da janela (CGWindowID) de um AXUIElement, ou 0 se não for possível.
unsigned int SKWindowIDForAXElement(const void *element);

/// Liga/desliga um atalho do sistema (1 = ⌘⇥, 2 = ⇧⌘⇥). Retorna 0 se indisponível.
int SKSetSymbolicHotKeyEnabled(int hotKey, int enabled);

#endif
