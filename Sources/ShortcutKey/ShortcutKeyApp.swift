import AppKit
import Combine
import MultitouchBridge
import ServiceManagement
import SwiftUI

@main
struct ShortcutKeyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = SettingsStore.shared
    @StateObject private var controller = AppController.shared

    /// Daruma monocromático da barra de menu (Resources/MenuBarIcon.png).
    private static let menuBarIcon: NSImage? = {
        guard let image = Bundle.main.image(forResource: "MenuBarIcon") else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(store)
                .environmentObject(controller)
        } label: {
            if let icon = Self.menuBarIcon {
                Image(nsImage: icon)
            } else {
                Image(systemName: "command.square")
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(controller)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppController.shared.launch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Devolve o ⌘⇥ ao macOS.
        SystemHotkeys.setCommandTabEnabled(true)
    }
}

/// Liga/desliga o ⌘⇥ nativo quando o alternador do ShortcutKey o substitui.
enum SystemHotkeys {
    static func setCommandTabEnabled(_ enabled: Bool) {
        SKSetSymbolicHotKeyEnabled(1, enabled ? 1 : 0)
        SKSetSymbolicHotKeyEnabled(2, enabled ? 1 : 0)
    }

    static func apply(_ settings: SwitcherSettings) {
        setCommandTabEnabled(!(settings.enabled && settings.replaceCommandTab))
    }
}

/// Liga as peças: permissão, event tap e trackpad.
final class AppController: ObservableObject {
    static let shared = AppController()

    @Published var isTrusted = AX.isTrusted
    @Published var trackpadCount = 0
    @Published var lastGesture: Gesture?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var permissionTimer: Timer?
    private var settingsObserver: AnyCancellable?

    func launch() {
        AXUIElementSetMessagingTimeout(AX.systemWide, 0.25)
        Log.write("iniciado — acessibilidade: \(isTrusted), gravação de tela: \(Thumbnails.hasPermission)")

        Onboarding.showIfNeeded()
        refreshPermission()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refreshPermission()
        }

        settingsObserver = SettingsStore.shared.$settings
            .map(\.switcher)
            .removeDuplicates()
            .sink { SystemHotkeys.apply($0) }

        // Gatilho de teste: `./scripts/test-switcher.sh` abre o alternador por alguns segundos.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("app.shortcutkey.debug.showSwitcher"), object: nil, queue: .main
        ) { _ in
            SwitcherController.shared.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { SwitcherController.shared.saveSnapshot() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { SwitcherController.shared.cancel() }
        }

        GestureEngine.shared.onGesture = { [weak self] gesture in self?.lastGesture = gesture }
        restartTrackpad()

        // O trackpad precisa ser reconectado depois que o Mac acorda.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.restartTrackpad() }
        }
    }

    func restartTrackpad() {
        trackpadCount = GestureEngine.shared.start()
        Log.write("trackpads encontrados: \(trackpadCount)")
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("ShortcutKey: não foi possível alterar 'abrir ao iniciar': \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func refreshPermission() {
        let trusted = AX.isTrusted
        if trusted != isTrusted {
            isTrusted = trusted
            Log.write("acessibilidade mudou: \(trusted)")
        }
        if trusted, !EventTapController.shared.isRunning {
            Log.write("event tap iniciado: \(EventTapController.shared.start())")
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var controller: AppController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if !controller.isTrusted {
            Button("⚠️ Permitir Acessibilidade…") {
                AX.promptForPermission()
                AX.openAccessibilitySettings()
            }
            Divider()
        }

        Toggle("Gestos do trackpad", isOn: $store.settings.gesturesEnabled)

        if store.settings.screenshot.enabled {
            Button("Tirar print (⌘⇧S)") { ScreenshotController.shared.capture() }
        }

        Button("Configurações…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")

        Button("Reconectar trackpad") { controller.restartTrackpad() }
        Button("Permissões e boas-vindas…") { Onboarding.show() }

        Divider()

        Button("Sair do ShortcutKey") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
