import AppKit
import Combine
import SwiftUI

// MARK: - Ações

enum ActionKind: String, Codable, CaseIterable, Identifiable {
    case none
    // Sistema
    case showDesktop, missionControl, appExpose, previousSpace, nextSpace
    // Janela
    case closeWindow, minimizeWindow, maximizeWindow, toggleFullScreen, leftHalf, rightHalf, centerWindow
    // App
    case quitApp, hideApp
    // Navegação
    case middleClick, nextTab, previousTab, back, forward
    // Personalizado
    case customShortcut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "Nenhuma"
        case .showDesktop: "Mostrar a Mesa (área de trabalho)"
        case .missionControl: "Mission Control"
        case .appExpose: "Janelas do app (App Exposé)"
        case .previousSpace: "Mesa anterior (Space ←)"
        case .nextSpace: "Próxima mesa (Space →)"
        case .closeWindow: "Fechar janela"
        case .minimizeWindow: "Minimizar janela"
        case .maximizeWindow: "Maximizar / restaurar janela"
        case .toggleFullScreen: "Tela cheia"
        case .leftHalf: "Janela na metade esquerda"
        case .rightHalf: "Janela na metade direita"
        case .centerWindow: "Centralizar janela"
        case .quitApp: "Encerrar app"
        case .hideApp: "Ocultar app"
        case .middleClick: "Clique do meio"
        case .nextTab: "Próxima aba (⌃⇥)"
        case .previousTab: "Aba anterior (⌃⇧⇥)"
        case .back: "Voltar (⌘[)"
        case .forward: "Avançar (⌘])"
        case .customShortcut: "Atalho de teclado personalizado…"
        }
    }

    /// Grupos usados para separar as opções nos menus.
    static let groups: [[ActionKind]] = [
        [.none],
        [.showDesktop, .missionControl, .appExpose, .previousSpace, .nextSpace],
        [.closeWindow, .minimizeWindow, .maximizeWindow, .toggleFullScreen, .leftHalf, .rightHalf, .centerWindow],
        [.quitApp, .hideApp],
        [.middleClick, .nextTab, .previousTab, .back, .forward],
        [.customShortcut],
    ]
}

struct KeyCombo: Codable, Equatable, Hashable {
    var keyCode: UInt16
    /// `NSEvent.ModifierFlags.rawValue` limitado a ⌘ ⌥ ⌃ ⇧.
    var modifiers: UInt
    var display: String

    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var cgFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if modifierFlags.contains(.command) { flags.insert(.maskCommand) }
        if modifierFlags.contains(.option) { flags.insert(.maskAlternate) }
        if modifierFlags.contains(.control) { flags.insert(.maskControl) }
        if modifierFlags.contains(.shift) { flags.insert(.maskShift) }
        return flags
    }
}

struct ActionBinding: Codable, Equatable {
    var action: ActionKind = .none
    /// Usado apenas quando `action == .customShortcut`.
    var shortcut: KeyCombo?
}

// MARK: - Gestos

enum Gesture: String, Codable, CaseIterable, Identifiable {
    case tap3, tap4, tap5
    case swipe3Up, swipe3Down, swipe3Left, swipe3Right
    case swipe4Up, swipe4Down, swipe4Left, swipe4Right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tap3: "Tocar com 3 dedos"
        case .tap4: "Tocar com 4 dedos"
        case .tap5: "Tocar com 5 dedos"
        case .swipe3Up, .swipe4Up: "Arrastar para cima"
        case .swipe3Down, .swipe4Down: "Arrastar para baixo"
        case .swipe3Left, .swipe4Left: "Arrastar para a esquerda"
        case .swipe3Right, .swipe4Right: "Arrastar para a direita"
        }
    }

    var fingers: Int {
        switch self {
        case .tap3, .swipe3Up, .swipe3Down, .swipe3Left, .swipe3Right: 3
        case .tap4, .swipe4Up, .swipe4Down, .swipe4Left, .swipe4Right: 4
        case .tap5: 5
        }
    }

    var isHorizontalSwipe: Bool {
        [.swipe3Left, .swipe3Right, .swipe4Left, .swipe4Right].contains(self)
    }

    static let taps: [Gesture] = [.tap3, .tap4, .tap5]
    static let swipes3: [Gesture] = [.swipe3Up, .swipe3Down, .swipe3Left, .swipe3Right]
    static let swipes4: [Gesture] = [.swipe4Up, .swipe4Down, .swipe4Left, .swipe4Right]

    static func swipe(fingers: Int, dx: Double, dy: Double) -> Gesture? {
        let horizontal = abs(dx) > abs(dy)
        switch (fingers, horizontal) {
        case (3, true): return dx > 0 ? .swipe3Right : .swipe3Left
        case (3, false): return dy > 0 ? .swipe3Up : .swipe3Down
        case (4, true): return dx > 0 ? .swipe4Right : .swipe4Left
        case (4, false): return dy > 0 ? .swipe4Up : .swipe4Down
        default: return nil
        }
    }

    static func tap(fingers: Int) -> Gesture? {
        switch fingers {
        case 3: .tap3
        case 4: .tap4
        case 5: .tap5
        default: nil
        }
    }
}

/// Alternar entre apps arrastando para os lados (como no Windows).
enum AppSwitcherGesture: String, Codable, CaseIterable, Identifiable {
    case off, threeFingers, fourFingers
    var id: String { rawValue }

    var fingers: Int? {
        switch self {
        case .off: nil
        case .threeFingers: 3
        case .fourFingers: 4
        }
    }

    var title: String {
        switch self {
        case .off: "Desativado"
        case .threeFingers: "Arrastar com 3 dedos para os lados"
        case .fourFingers: "Arrastar com 4 dedos para os lados"
        }
    }
}

// MARK: - Alternador de apps

enum SwitcherStyle: String, Codable, CaseIterable, Identifiable {
    case thumbnails, icons, titles
    var id: String { rawValue }
    var title: String {
        switch self {
        case .thumbnails: "Miniaturas"
        case .icons: "Ícones de apps"
        case .titles: "Títulos"
        }
    }
}

enum SwitcherSize: String, Codable, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var title: String {
        switch self {
        case .small: "Pequeno"
        case .medium: "Médio"
        case .large: "Grande"
        }
    }
    var scale: CGFloat {
        switch self {
        case .small: 0.75
        case .medium: 1
        case .large: 1.3
        }
    }
}

enum SwitcherTheme: String, Codable, CaseIterable, Identifiable {
    case light, dark, system
    var id: String { rawValue }
    var title: String {
        switch self {
        case .light: "Clara"
        case .dark: "Escura"
        case .system: "Sistema"
        }
    }
}

enum SwitcherRelease: String, Codable, CaseIterable, Identifiable {
    case focus, keepOpen
    var id: String { rawValue }
    var title: String {
        switch self {
        case .focus: "Focar"
        case .keepOpen: "Manter aberto"
        }
    }
}

enum SwitcherScreen: String, Codable, CaseIterable, Identifiable {
    case active, mouse, main
    var id: String { rawValue }
    var title: String {
        switch self {
        case .active: "Tela ativa"
        case .mouse: "Tela com o cursor"
        case .main: "Tela principal"
        }
    }
}

enum SwitcherGrouping: String, Codable, CaseIterable, Identifiable {
    case windows, apps
    var id: String { rawValue }
    var title: String {
        switch self {
        case .windows: "Cada janela"
        case .apps: "Um item por app"
        }
    }
}

struct SwitcherSettings: Codable, Equatable {
    var enabled = true
    var style: SwitcherStyle = .thumbnails
    var size: SwitcherSize = .medium
    var theme: SwitcherTheme = .system
    var afterRelease: SwitcherRelease = .focus
    var previewSelectedWindow = false
    var screen: SwitcherScreen = .active
    var grouping: SwitcherGrouping = .windows
    var showMinimized = true
    var showHidden = true
    var showWindowless = false
    var shortcut: KeyCombo? = KeyCombo(keyCode: 48, modifiers: NSEvent.ModifierFlags.option.rawValue, display: "⌥⇥")
    var replaceCommandTab = false
    var excludedBundleIDs: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SwitcherSettings()
        enabled = c.value(.enabled, d.enabled)
        style = c.value(.style, d.style)
        size = c.value(.size, d.size)
        theme = c.value(.theme, d.theme)
        afterRelease = c.value(.afterRelease, d.afterRelease)
        previewSelectedWindow = c.value(.previewSelectedWindow, d.previewSelectedWindow)
        screen = c.value(.screen, d.screen)
        grouping = c.value(.grouping, d.grouping)
        showMinimized = c.value(.showMinimized, d.showMinimized)
        showHidden = c.value(.showHidden, d.showHidden)
        showWindowless = c.value(.showWindowless, d.showWindowless)
        shortcut = c.value(.shortcut, d.shortcut)
        replaceCommandTab = c.value(.replaceCommandTab, d.replaceCommandTab)
        excludedBundleIDs = c.value(.excludedBundleIDs, d.excludedBundleIDs)
    }
}

extension KeyedDecodingContainer {
    /// Lê um valor, usando o padrão se ele não existir ou estiver num formato antigo.
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

// MARK: - Print

struct ScreenshotSettings: Codable, Equatable {
    var enabled = true
    var copyToClipboard = true
    var saveToDesktop = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ScreenshotSettings()
        enabled = c.value(.enabled, d.enabled)
        copyToClipboard = c.value(.copyToClipboard, d.copyToClipboard)
        saveToDesktop = c.value(.saveToDesktop, d.saveToDesktop)
    }
}

// MARK: - Botões da janela

enum CloseButtonBehavior: String, Codable, CaseIterable, Identifiable {
    case standard, quitIfLastWindow, quitApp, hideApp, minimize
    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: "Padrão do macOS (só fecha a janela)"
        case .quitIfLastWindow: "Fechar e encerrar o app se for a última janela"
        case .quitApp: "Encerrar o app sempre"
        case .hideApp: "Ocultar o app"
        case .minimize: "Minimizar a janela"
        }
    }
}

enum MinimizeButtonBehavior: String, Codable, CaseIterable, Identifiable {
    case standard, hideApp, quitApp
    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: "Padrão do macOS (minimizar)"
        case .hideApp: "Ocultar o app"
        case .quitApp: "Encerrar o app"
        }
    }
}

enum ZoomButtonBehavior: String, Codable, CaseIterable, Identifiable {
    case standard, maximize, fullScreen
    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: "Padrão do macOS"
        case .maximize: "Maximizar / restaurar (sem tela cheia)"
        case .fullScreen: "Tela cheia"
        }
    }
}

// MARK: - Atalhos de teclado

struct HotkeyBinding: Codable, Identifiable, Equatable {
    var id = UUID()
    var trigger: KeyCombo?
    var binding = ActionBinding()
}

// MARK: - Configurações

struct AppSettings: Codable, Equatable {
    var closeButton: CloseButtonBehavior = .quitIfLastWindow
    var minimizeButton: MinimizeButtonBehavior = .standard
    var zoomButton: ZoomButtonBehavior = .standard
    var quitOnCommandW = false
    var optionKeyBypass = true
    var excludedBundleIDs: [String] = ["com.apple.finder"]

    var gesturesEnabled = true
    var appSwitcher: AppSwitcherGesture = .threeFingers
    var switcher = SwitcherSettings()
    var screenshot = ScreenshotSettings()
    var gestures: [String: ActionBinding] = [:]

    var hotkeys: [HotkeyBinding] = []

    init() {}

    func binding(for gesture: Gesture) -> ActionBinding {
        gestures[gesture.rawValue] ?? ActionBinding()
    }

    /// Arrastes laterais usados pelo alternador de apps não disparam a ação configurada.
    func isReservedByAppSwitcher(_ gesture: Gesture) -> Bool {
        gesture.isHorizontalSwipe && gesture.fingers == appSwitcher.fingers
    }

    func isExcluded(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return excludedBundleIDs.contains(bundleID)
    }

    // Decodificação tolerante: campos novos em versões futuras não apagam as configurações antigas.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        closeButton = (try? c.decodeIfPresent(CloseButtonBehavior.self, forKey: .closeButton)) ?? d.closeButton
        minimizeButton = (try? c.decodeIfPresent(MinimizeButtonBehavior.self, forKey: .minimizeButton)) ?? d.minimizeButton
        zoomButton = (try? c.decodeIfPresent(ZoomButtonBehavior.self, forKey: .zoomButton)) ?? d.zoomButton
        quitOnCommandW = (try? c.decodeIfPresent(Bool.self, forKey: .quitOnCommandW)) ?? d.quitOnCommandW
        optionKeyBypass = (try? c.decodeIfPresent(Bool.self, forKey: .optionKeyBypass)) ?? d.optionKeyBypass
        excludedBundleIDs = (try? c.decodeIfPresent([String].self, forKey: .excludedBundleIDs)) ?? d.excludedBundleIDs
        gesturesEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .gesturesEnabled)) ?? d.gesturesEnabled
        appSwitcher = (try? c.decodeIfPresent(AppSwitcherGesture.self, forKey: .appSwitcher)) ?? d.appSwitcher
        switcher = c.value(.switcher, d.switcher)
        screenshot = c.value(.screenshot, d.screenshot)
        gestures = (try? c.decodeIfPresent([String: ActionBinding].self, forKey: .gestures)) ?? d.gestures
        hotkeys = (try? c.decodeIfPresent([HotkeyBinding].self, forKey: .hotkeys)) ?? d.hotkeys
    }
}

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private static let defaultsKey = "settings.v1"
    private let lock = NSLock()
    private var snapshot: AppSettings

    @Published var settings: AppSettings {
        didSet {
            lock.withLock { snapshot = settings }
            if let data = try? JSONEncoder().encode(settings) {
                UserDefaults.standard.set(data, forKey: Self.defaultsKey)
            }
        }
    }

    /// Cópia segura para ler de qualquer thread (event tap, trackpad).
    var current: AppSettings { lock.withLock { snapshot } }

    private init() {
        var loaded = AppSettings()
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            loaded = decoded
        }
        snapshot = loaded
        settings = loaded
    }

    func gestureBinding(_ gesture: Gesture) -> Binding<ActionBinding> {
        Binding(
            get: { self.settings.binding(for: gesture) },
            set: { self.settings.gestures[gesture.rawValue] = $0 }
        )
    }
}
