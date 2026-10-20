import AppKit
import MultitouchBridge

/// Marca os eventos criados pelo próprio app, para o event tap ignorá-los.
let syntheticEventMarker: Int64 = 0x53_4B_45_59 // "SKEY"

// MARK: - Teclado e mouse sintéticos

enum InputSender {
    static func key(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    static func key(_ combo: KeyCombo) {
        key(CGKeyCode(combo.keyCode), flags: combo.cgFlags)
    }

    /// Setas precisam das flags Fn/NumPad para o macOS reconhecer como seta de verdade.
    static func arrow(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        key(keyCode, flags: flags.union([.maskSecondaryFn, .maskNumericPad]))
    }

    static func middleClick() {
        let location = CGEvent(source: nil)?.location ?? .zero
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: .center) else { continue }
            event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
            event.post(tap: .cghidEventTap)
        }
    }
}

enum KeyCode {
    static let w: CGKeyCode = 13
    static let tab: CGKeyCode = 48
    static let leftBracket: CGKeyCode = 33
    static let rightBracket: CGKeyCode = 30
    static let leftArrow: CGKeyCode = 123
    static let rightArrow: CGKeyCode = 124
    static let q: CGKeyCode = 12
}

// MARK: - Dock / Mission Control

enum Dock {
    private static let missionControlBinary = "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control"

    static func showDesktop() { send("com.apple.showdesktop.awake", fallbackArgument: "1") }
    static func missionControl() { send("com.apple.expose.awake", fallbackArgument: nil) }
    static func appExpose() { send("com.apple.expose.front.awake", fallbackArgument: "2") }

    private static func send(_ notification: String, fallbackArgument: String?) {
        if SKCoreDockSend(notification) != 0 { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: missionControlBinary)
        process.arguments = fallbackArgument.map { [$0] } ?? []
        try? process.run()
    }
}

// MARK: - Janelas e apps

enum WindowActions {
    private static var savedFrames: [CFHashCode: CGRect] = [:]

    static func close(_ window: AXUIElement) {
        if let button = AX.element(window, kAXCloseButtonAttribute) { AX.press(button) }
    }

    static func minimize(_ window: AXUIElement) {
        AX.setBool(window, kAXMinimizedAttribute, true)
    }

    static func toggleFullScreen(_ window: AXUIElement) {
        let isFullScreen = AX.bool(window, "AXFullScreen") ?? false
        AX.setBool(window, "AXFullScreen", !isFullScreen)
    }

    static func toggleMaximize(_ window: AXUIElement) {
        guard let frame = AX.frame(window), let screen = screen(containing: frame) else { return }
        let key = CFHash(window)
        let target = axRect(fromCocoa: screen.visibleFrame)

        if isClose(frame, target), let previous = savedFrames[key] {
            savedFrames[key] = nil
            AX.setFrame(window, previous)
        } else {
            savedFrames[key] = frame
            AX.setFrame(window, target)
        }
    }

    enum Half { case left, right }

    static func snap(_ window: AXUIElement, to half: Half) {
        guard let frame = AX.frame(window), let screen = screen(containing: frame) else { return }
        var area = screen.visibleFrame
        area.size.width /= 2
        if half == .right { area.origin.x += area.width }
        AX.setFrame(window, axRect(fromCocoa: area))
    }

    static func center(_ window: AXUIElement) {
        guard let frame = AX.frame(window), let screen = screen(containing: frame) else { return }
        let area = axRect(fromCocoa: screen.visibleFrame)
        let origin = CGPoint(x: area.midX - frame.width / 2, y: area.midY - frame.height / 2)
        AX.setFrame(window, CGRect(origin: origin, size: frame.size))
    }

    // Coordenadas: a Acessibilidade usa origem no canto superior esquerdo da tela principal;
    // o AppKit usa o canto inferior esquerdo.
    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    private static func axRect(fromCocoa rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func screen(containing axFrame: CGRect) -> NSScreen? {
        let center = CGPoint(x: axFrame.midX, y: primaryHeight - axFrame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
    }

    private static func isClose(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 8 && abs(a.minY - b.minY) < 8 && abs(a.width - b.width) < 16 && abs(a.height - b.height) < 16
    }
}

enum AppActions {
    private static let neverQuit: Set<String> = ["com.apple.finder", "com.apple.dock", "com.apple.systemuiserver"]

    static func runningApp(_ pid: pid_t) -> NSRunningApplication? {
        NSRunningApplication(processIdentifier: pid)
    }

    static func quit(_ app: NSRunningApplication?) {
        guard let app, app != NSRunningApplication.current,
              !neverQuit.contains(app.bundleIdentifier ?? "") else { return }
        app.terminate() // Igual ao ⌘Q: o app ainda pergunta se quer salvar.
    }

    static func hide(_ app: NSRunningApplication?) {
        app?.hide()
    }

    /// Encerra o app se ele ficou sem janelas. Checa duas vezes para dar tempo da animação de fechar.
    static func quitIfNoWindows(pid: pid_t) {
        for delay in [0.4, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let app = runningApp(pid), !app.isTerminated,
                      app.activationPolicy == .regular,
                      !SettingsStore.shared.current.isExcluded(app.bundleIdentifier),
                      AX.standardWindows(pid: pid).isEmpty else { return }
                quit(app)
            }
        }
    }
}

// MARK: - Executor

enum ActionPerformer {
    static func perform(_ binding: ActionBinding) {
        guard binding.action != .none else { return }
        if Thread.isMainThread {
            run(binding)
        } else {
            DispatchQueue.main.async { run(binding) }
        }
    }

    private static func run(_ binding: ActionBinding) {
        let frontApp = NSWorkspace.shared.frontmostApplication

        switch binding.action {
        case .none: break
        case .showDesktop: Dock.showDesktop()
        case .missionControl: Dock.missionControl()
        case .appExpose: Dock.appExpose()
        case .previousSpace: InputSender.arrow(KeyCode.leftArrow, flags: .maskControl)
        case .nextSpace: InputSender.arrow(KeyCode.rightArrow, flags: .maskControl)

        case .closeWindow: AX.focusedWindow().map(WindowActions.close)
        case .minimizeWindow: AX.focusedWindow().map(WindowActions.minimize)
        case .maximizeWindow: AX.focusedWindow().map(WindowActions.toggleMaximize)
        case .toggleFullScreen: AX.focusedWindow().map(WindowActions.toggleFullScreen)
        case .leftHalf: AX.focusedWindow().map { WindowActions.snap($0, to: .left) }
        case .rightHalf: AX.focusedWindow().map { WindowActions.snap($0, to: .right) }
        case .centerWindow: AX.focusedWindow().map(WindowActions.center)

        case .quitApp: AppActions.quit(frontApp)
        case .hideApp: AppActions.hide(frontApp)
        case .lockScreen: InputSender.key(KeyCode.q, flags: [.maskControl, .maskCommand]) // ⌃⌘Q do macOS

        case .middleClick: InputSender.middleClick()
        case .nextTab: InputSender.key(KeyCode.tab, flags: .maskControl)
        case .previousTab: InputSender.key(KeyCode.tab, flags: [.maskControl, .maskShift])
        case .back: InputSender.key(KeyCode.leftBracket, flags: .maskCommand)
        case .forward: InputSender.key(KeyCode.rightBracket, flags: .maskCommand)

        case .customShortcut:
            if let shortcut = binding.shortcut { InputSender.key(shortcut) }
        }
    }
}
