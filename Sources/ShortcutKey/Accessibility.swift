import AppKit
import ApplicationServices

/// Pequenos utilitários em cima da API de Acessibilidade (AXUIElement).
enum AX {
    static let systemWide = AXUIElementCreateSystemWide()

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func promptForPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Leitura

    private static func raw(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = raw(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        raw(element, attribute) as? [AXUIElement] ?? []
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        raw(element, attribute) as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        raw(element, attribute) as? Bool
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let posValue = raw(element, kAXPositionAttribute),
              let sizeValue = raw(element, kAXSizeAttribute),
              CFGetTypeID(posValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    static func pid(_ element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    static func element(at point: CGPoint) -> AXUIElement? {
        var result: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &result) == .success else { return nil }
        return result
    }

    /// Janela que contém um elemento (ex.: um dos botões vermelho/amarelo/verde).
    static func window(of element: AXUIElement) -> AXUIElement? {
        self.element(element, kAXWindowAttribute) ?? self.element(element, kAXParentAttribute)
    }

    static func focusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return element(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute)
    }

    /// Janelas "de verdade" de um app (ignora painéis flutuantes, menus etc.).
    static func standardWindows(pid: pid_t) -> [AXUIElement] {
        elements(AXUIElementCreateApplication(pid), kAXWindowsAttribute).filter {
            let subrole = string($0, kAXSubroleAttribute)
            return subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
        }
    }

    // MARK: Escrita

    static func setBool(_ element: AXUIElement, _ attribute: String, _ value: Bool) {
        AXUIElementSetAttributeValue(element, attribute as CFString, value as CFBoolean)
    }

    static func setFrame(_ element: AXUIElement, _ frame: CGRect) {
        var origin = frame.origin
        var size = frame.size
        guard let pos = AXValueCreate(.cgPoint, &origin), let sz = AXValueCreate(.cgSize, &size) else { return }
        // Posição → tamanho → posição: evita que o macOS limite o tamanho pela posição antiga.
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, pos)
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sz)
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, pos)
    }

    static func press(_ element: AXUIElement) {
        AXUIElementPerformAction(element, kAXPressAction as CFString)
    }
}
