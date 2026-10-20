import AppKit
import ApplicationServices

/// Intercepta cliques nos botões vermelho/amarelo/verde e os atalhos de teclado globais.
final class EventTapController {
    static let shared = EventTapController()

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var swallowNextMouseUp = false
    /// Modificadores que abriram o alternador pelo teclado (soltar = escolher).
    private var switcherModifiers: NSEvent.ModifierFlags?

    /// Pausado enquanto o usuário grava um atalho nas configurações.
    var isPaused = false

    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }

        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .keyDown, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }

        let callback: CGEventTapCallBack = { _, type, event, _ in
            EventTapController.shared.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: callback, userInfo: nil) else { return false }

        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        if isPaused || event.getIntegerValueField(.eventSourceUserData) == syntheticEventMarker {
            return pass
        }

        let settings = SettingsStore.shared.current
        switch type {
        case .leftMouseDown:
            return handleMouseDown(event, settings) ? nil : pass
        case .leftMouseUp:
            if swallowNextMouseUp {
                swallowNextMouseUp = false
                return nil
            }
            return pass
        case .keyDown:
            // Área de trabalho remota / máquina virtual em foco: os atalhos vão todos para ela.
            if settings.isKeyboardPaused(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) {
                return pass
            }
            if handleScreenshotKey(event, settings) { return nil }
            if handleSwitcherKey(event, settings) { return nil }
            return handleKeyDown(event, settings) ? nil : pass
        case .flagsChanged:
            handleSwitcherFlags(event)
            return pass
        default:
            return pass
        }
    }

    // MARK: Botões da janela

    /// Retorna `true` se o clique foi consumido (não chega ao app).
    private func handleMouseDown(_ event: CGEvent, _ settings: AppSettings) -> Bool {
        if settings.closeButton == .standard, settings.minimizeButton == .standard, settings.zoomButton == .standard {
            return false
        }
        if settings.optionKeyBypass, event.flags.contains(.maskAlternate) {
            return false
        }

        guard let element = AX.element(at: event.location),
              let subrole = AX.string(element, kAXSubroleAttribute),
              let pid = AX.pid(element) else { return false }

        let app = AppActions.runningApp(pid)
        if settings.isExcluded(app?.bundleIdentifier) { return false }
        let window = AX.window(of: element)

        var action: (() -> Void)?
        switch subrole {
        case kAXCloseButtonSubrole:
            switch settings.closeButton {
            case .standard: break
            case .quitIfLastWindow:
                AppActions.quitIfNoWindows(pid: pid)
                return false // deixa o clique fechar a janela normalmente
            case .quitApp: action = { AppActions.quit(app) }
            case .hideApp: action = { AppActions.hide(app) }
            case .minimize: action = { window.map(WindowActions.minimize) }
            }

        case kAXMinimizeButtonSubrole:
            switch settings.minimizeButton {
            case .standard: break
            case .hideApp: action = { AppActions.hide(app) }
            case .quitApp: action = { AppActions.quit(app) }
            }

        case kAXFullScreenButtonSubrole, kAXZoomButtonSubrole:
            switch settings.zoomButton {
            case .standard: break
            case .maximize: action = { window.map(WindowActions.toggleMaximize) }
            case .fullScreen: action = { window.map(WindowActions.toggleFullScreen) }
            }

        default: break
        }

        guard let action else { return false }
        swallowNextMouseUp = true
        DispatchQueue.main.async(execute: action)
        return true
    }

    // MARK: Print (⌘⇧S)

    private func handleScreenshotKey(_ event: CGEvent, _ settings: AppSettings) -> Bool {
        guard settings.screenshot.enabled,
              event.getIntegerValueField(.keyboardEventKeycode) == 1, // S
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return false }
        let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)).intersection(KeyCombo.relevantModifiers)
        guard flags == [.command, .shift] else { return false }
        DispatchQueue.main.async { ScreenshotController.shared.capture() }
        return true
    }

    // MARK: Alternador de apps

    private func handleSwitcherKey(_ event: CGEvent, _ settings: AppSettings) -> Bool {
        let switcher = SwitcherController.shared
        guard settings.switcher.enabled else { return false }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)).intersection(KeyCombo.relevantModifiers)
        let backward = flags.contains(.shift)

        if switcher.isVisible {
            switch keyCode {
            case 48: switcher.move(backward ? -1 : 1)          // ⇥
            case 123, 126: switcher.move(-1)                    // ← ↑
            case 124, 125: switcher.move(1)                     // → ↓
            case 53: cancelSwitcher()                           // Esc
            case 36, 76, 49: commitSwitcher()                   // Return, Enter, Espaço
            default: return false
            }
            return true
        }

        var triggers: [KeyCombo] = []
        if let shortcut = settings.switcher.shortcut { triggers.append(shortcut) }
        if settings.switcher.replaceCommandTab {
            triggers.append(KeyCombo(keyCode: 48, modifiers: NSEvent.ModifierFlags.command.rawValue, display: "⌘⇥"))
        }
        let withoutShift = flags.subtracting(.shift)
        guard let trigger = triggers.first(where: {
            $0.keyCode == keyCode && ($0.modifierFlags == flags || (!$0.modifierFlags.contains(.shift) && $0.modifierFlags == withoutShift))
        }) else { return false }

        let modifiers = trigger.modifierFlags.subtracting(.shift)
        switcherModifiers = modifiers.isEmpty ? nil : modifiers
        switcher.show(forward: !backward || trigger.modifierFlags.contains(.shift))
        return true
    }

    private func handleSwitcherFlags(_ event: CGEvent) {
        guard let held = switcherModifiers, SwitcherController.shared.isVisible else { return }
        let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        if !flags.contains(held) {
            switcherModifiers = nil
            SwitcherController.shared.triggerReleased()
        }
    }

    private func commitSwitcher() {
        switcherModifiers = nil
        SwitcherController.shared.commit()
    }

    private func cancelSwitcher() {
        switcherModifiers = nil
        SwitcherController.shared.cancel()
    }

    // MARK: Teclado

    private func handleKeyDown(_ event: CGEvent, _ settings: AppSettings) -> Bool {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
            .intersection(KeyCombo.relevantModifiers).rawValue

        if let hotkey = settings.hotkeys.first(where: { $0.trigger?.keyCode == keyCode && $0.trigger?.modifiers == modifiers }) {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !isRepeat { ActionPerformer.perform(hotkey.binding) }
            return true
        }

        if settings.quitOnCommandW, keyCode == UInt16(KeyCode.w),
           modifiers == NSEvent.ModifierFlags.command.rawValue,
           let app = NSWorkspace.shared.frontmostApplication,
           !settings.isExcluded(app.bundleIdentifier) {
            AppActions.quitIfNoWindows(pid: app.processIdentifier)
        }
        return false
    }
}
