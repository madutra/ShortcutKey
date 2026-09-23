import AppKit
import MultitouchBridge
import ScreenCaptureKit
import SwiftUI

// MARK: - Itens

struct SwitcherItem: Identifiable {
    let id: String
    let app: NSRunningApplication
    let window: AXUIElement?
    let windowID: CGWindowID
    let title: String
    let appName: String
    let icon: NSImage
    let isMinimized: Bool

    /// "Safari – Título da janela"
    var fullTitle: String {
        title.isEmpty || title == appName ? appName : "\(appName) – \(title)"
    }
}

enum WindowList {
    static func items(_ settings: SwitcherSettings) -> [SwitcherItem] {
        // Ordem de empilhamento das janelas visíveis (da frente para trás) ≈ ordem de uso recente.
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var zOrder: [CGWindowID: Int] = [:]
        var appOrder: [pid_t: Int] = [:]
        for (index, window) in info.enumerated() where (window[kCGWindowLayer as String] as? Int) == 0 {
            if let number = window[kCGWindowNumber as String] as? Int { zOrder[CGWindowID(number)] = index }
            if let pid = window[kCGWindowOwnerPID as String] as? Int, appOrder[pid_t(pid)] == nil {
                appOrder[pid_t(pid)] = index
            }
        }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0 != NSRunningApplication.current
                && !settings.excludedBundleIDs.contains($0.bundleIdentifier ?? "")
                && (settings.showHidden || !$0.isHidden)
        }

        var entries: [(item: SwitcherItem, rank: Int)] = []
        for (appIndex, app) in apps.enumerated() {
            let pid = app.processIdentifier
            let appName = app.localizedName ?? "App"
            let icon = app.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
            // Apps na frente primeiro; depois janelas escondidas/minimizadas na ordem dos apps.
            let appRank = pid == frontPID ? -1 : (appOrder[pid] ?? 100_000 + appIndex)

            var windows: [(item: SwitcherItem, rank: Int)] = []
            for window in AX.standardWindows(pid: pid) {
                let minimized = AX.bool(window, kAXMinimizedAttribute) ?? false
                if minimized && !settings.showMinimized { continue }
                let windowID = CGWindowID(SKWindowIDForAXElement(Unmanaged.passUnretained(window).toOpaque()))
                let item = SwitcherItem(
                    id: "w\(pid)-\(windowID)-\(windows.count)", app: app, window: window, windowID: windowID,
                    title: AX.string(window, kAXTitleAttribute) ?? "", appName: appName, icon: icon, isMinimized: minimized)
                let rank = zOrder[windowID] ?? (minimized ? 200_000 : 150_000) + appIndex
                windows.append((item, pid == frontPID ? min(rank, -1) : rank))
            }
            windows.sort { $0.rank < $1.rank }

            if windows.isEmpty {
                guard settings.showWindowless else { continue }
                let item = SwitcherItem(id: "a\(pid)", app: app, window: nil, windowID: 0, title: "",
                                        appName: appName, icon: icon, isMinimized: false)
                entries.append((item, 300_000 + appIndex))
            } else if settings.grouping == .apps, let first = windows.first {
                entries.append((first.item, min(first.rank, appRank)))
            } else {
                entries.append(contentsOf: windows)
            }
        }
        return entries.sorted { $0.rank < $1.rank }.map(\.item)
    }

    /// Traz a janela para frente e ativa o app.
    static func focus(_ item: SwitcherItem) {
        let app = item.app
        if app.isHidden { app.unhide() }
        if let window = item.window {
            if item.isMinimized { AX.setBool(window, kAXMinimizedAttribute, false) }
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AX.setBool(window, kAXMainAttribute, true)
        }
        AX.setBool(AXUIElementCreateApplication(app.processIdentifier), kAXFrontmostAttribute, true)
        app.activate()
    }
}

// MARK: - Miniaturas (ScreenCaptureKit)

enum Thumbnails {
    /// Última miniatura de cada janela, para aparecer na hora enquanto a nova é capturada.
    private(set) static var cache: [CGWindowID: NSImage] = [:]

    /// `CGPreflightScreenCaptureAccess()` guarda a resposta de quando o app abriu. Então também checa
    /// na hora: sem a permissão, o macOS esconde o título das janelas dos outros apps.
    static var hasPermission: Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        let ownPID = Int(getpid())
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.contains { window in
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? Int, pid != ownPID,
                  let name = window[kCGWindowName as String] as? String else { return false }
            return !name.isEmpty
        }
    }

    /// Reabre o app (alguns recursos do macOS só reconhecem a permissão depois disso).
    static func relaunchApp() {
        let path = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? process.run()
        NSApp.terminate(nil)
    }

    static func requestPermission() {
        if !CGRequestScreenCaptureAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    static func capture(_ ids: [CGWindowID], maxSize: CGSize, onImage: @escaping (CGWindowID, NSImage) -> Void) {
        guard hasPermission, !ids.isEmpty else { return }
        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return }
            var byID: [CGWindowID: SCWindow] = [:]
            for window in content.windows { byID[window.windowID] = window }

            await withTaskGroup(of: Void.self) { group in
                for id in ids {
                    guard let window = byID[id], window.frame.width > 1, window.frame.height > 1 else { continue }
                    group.addTask {
                        let config = SCStreamConfiguration()
                        let scale = min(maxSize.width / window.frame.width, maxSize.height / window.frame.height, 1) * 2
                        config.width = max(1, Int(window.frame.width * scale))
                        config.height = max(1, Int(window.frame.height * scale))
                        config.showsCursor = false
                        config.ignoreShadowsSingleWindow = true
                        let filter = SCContentFilter(desktopIndependentWindow: window)
                        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return }
                        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
                        await MainActor.run {
                            cache[id] = nsImage
                            onImage(id, nsImage)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Controlador

final class SwitcherController: ObservableObject {
    static let shared = SwitcherController()

    @Published private(set) var items: [SwitcherItem] = []
    @Published private(set) var selected = 0
    @Published private(set) var thumbnails: [CGWindowID: NSImage] = [:]
    @Published private(set) var maxWidth: CGFloat = 1200

    private(set) var isVisible = false
    private var panel: SwitcherPanel?
    private var previewPanel: NSPanel?
    private var clickMonitor: Any?

    var settings: SwitcherSettings { SettingsStore.shared.settings.switcher }

    /// Abre o alternador (ou anda um item, se já estiver aberto).
    func show(forward: Bool = true) {
        if isVisible {
            move(forward ? 1 : -1)
            return
        }
        let settings = settings
        items = WindowList.items(settings)
        guard !items.isEmpty else { return }

        selected = items.count > 1 ? (forward ? 1 : items.count - 1) : 0
        thumbnails = Thumbnails.cache
        isVisible = true
        present(settings)
        updatePreview()

        if settings.style == .thumbnails {
            let size = SwitcherLayout(settings).thumbnailSize
            Thumbnails.capture(items.filter { !$0.isMinimized }.map(\.windowID), maxSize: size) { [weak self] id, image in
                guard let self, self.isVisible else { return }
                self.thumbnails[id] = image
            }
        }
    }

    func move(_ delta: Int) {
        guard isVisible, !items.isEmpty else { return }
        selected = (selected + delta + items.count) % items.count
        updatePreview()
    }

    func select(_ index: Int) {
        guard items.indices.contains(index), index != selected else { return }
        selected = index
        updatePreview()
    }

    /// Soltou as teclas ou levantou os dedos.
    func triggerReleased() {
        if settings.afterRelease == .focus { commit() }
    }

    func commit() {
        guard isVisible else { return }
        let item = items.indices.contains(selected) ? items[selected] : nil
        hide()
        if let item { WindowList.focus(item) }
    }

    func cancel() { hide() }

    private func hide() {
        isVisible = false
        panel?.orderOut(nil)
        previewPanel?.orderOut(nil)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    /// Salva uma imagem do alternador em ~/Library/Logs/ShortcutKey-switcher.png (para testes).
    func saveSnapshot() {
        guard let view = panel?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ShortcutKey-switcher.png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        Log.write("alternador: \(items.count) itens, \(thumbnails.count) miniaturas, gravação de tela: \(Thumbnails.hasPermission)")
    }

    // MARK: Janela do alternador

    private func present(_ settings: SwitcherSettings) {
        let screen = targetScreen(settings.screen)
        maxWidth = screen.visibleFrame.width * 0.9

        let panel = self.panel ?? SwitcherPanel()
        self.panel = panel
        switch settings.theme {
        case .light: panel.appearance = NSAppearance(named: .aqua)
        case .dark: panel.appearance = NSAppearance(named: .darkAqua)
        case .system: panel.appearance = nil
        }

        let hosting = FirstMouseHostingView(rootView: SwitcherView(controller: self, layout: SwitcherLayout(settings)))
        panel.contentView = hosting
        let size = hosting.fittingSize
        let area = screen.visibleFrame
        panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()

        // No modo "manter aberto", clicar fora fecha.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.cancel()
        }
    }

    private func targetScreen(_ choice: SwitcherScreen) -> NSScreen {
        let screens = NSScreen.screens
        switch choice {
        case .main:
            return screens.first ?? NSScreen.main!
        case .mouse:
            let mouse = NSEvent.mouseLocation
            return screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? screens[0]
        case .active:
            if let window = AX.focusedWindow(), let frame = AX.frame(window) {
                let height = screens.first?.frame.height ?? 0
                let center = CGPoint(x: frame.midX, y: height - frame.midY)
                if let screen = screens.first(where: { $0.frame.contains(center) }) { return screen }
            }
            return NSScreen.main ?? screens[0]
        }
    }

    // MARK: Pré-visualização da janela selecionada

    private func updatePreview() {
        guard settings.previewSelectedWindow, isVisible, items.indices.contains(selected),
              let window = items[selected].window, !items[selected].isMinimized,
              let frame = AX.frame(window) else {
            previewPanel?.orderOut(nil)
            return
        }
        let panel = previewPanel ?? makePreviewPanel()
        previewPanel = panel
        let height = NSScreen.screens.first?.frame.height ?? 0
        panel.setFrame(NSRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height), display: true)
        panel.order(.below, relativeTo: self.panel?.windowNumber ?? 0)
    }

    private func makePreviewPanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = NSHostingView(rootView:
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.accentColor.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 4))
        )
        return panel
    }
}

/// Painel flutuante que não rouba o foco do app atual.
final class SwitcherPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }
}

/// Deixa o primeiro clique funcionar mesmo com o painel fora de foco.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
