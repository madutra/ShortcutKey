import AppKit
import Combine
import IOKit.ps
import SwiftUI

/// Um painel preto colado no notch que cresce ao passar o mouse: música, bateria e uma prateleira de arquivos.
/// A janela é marcada como não compartilhável, então não aparece em prints nem no compartilhamento de tela.
final class NotchController {
    static let shared = NotchController()

    /// Espaço da janela: o notch aberto cabe aqui dentro, o resto é transparente.
    static let canvasSize = CGSize(width: 680, height: 260)

    private var panels: [NotchPanel] = []
    private var observers: [AnyCancellable] = []
    private var monitors: [Any] = []
    private var dragChangeCount = NSPasteboard(name: .drag).changeCount

    func start() {
        NowPlaying.shared.start()
        PowerMonitor.shared.start()
        observers.append(SettingsStore.shared.$settings
            .map(\.notch)
            .removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.rebuild() } })
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.rebuild() }
        // Gatilho de teste: abre (ou fecha) o notch sem o mouse.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("app.shortcutkey.debug.notch"), object: nil, queue: .main
        ) { [weak self] note in
            for panel in self?.panels ?? [] {
                if note.object as? String == "close" { panel.model.isPinned = false; panel.model.close() }
                else if note.object as? String == "charging" { panel.model.flash(.charging) }
                else if let name = note.object as? String, let page = NotchPage(rawValue: name) {
                    panel.model.open(reason: .hover); panel.model.page = page; panel.model.isPinned = true
                }
                else { panel.model.open(reason: .hover) }
            }
        }
        NotificationWatcher.shared.onAlert = { [weak self] alert in
            let settings = SettingsStore.shared.current.notch
            guard alert.kind == .call ? settings.calls : settings.notifications else { return }
            self?.panels.forEach { $0.model.show(alert) }
        }
        NotificationWatcher.shared.onRemove = { [weak self] id in
            self?.panels.forEach { $0.model.removeAlert(id: id) }
        }
        FocusWatcher.shared.onChange = { [weak self] name, symbol in
            guard SettingsStore.shared.current.notch.focus else { return }
            let alert = NotchAlert(id: "focus-\(UUID().uuidString)", kind: .focus(on: name != nil), appName: "Foco",
                                   title: name ?? "Foco desativado", body: "", icon: nil,
                                   symbol: name == nil ? "moon.zzz" : symbol ?? "moon.fill")
            self?.panels.forEach { $0.model.show(alert) }
        }
        PowerMonitor.shared.onPlugIn = { [weak self] in
            guard SettingsStore.shared.current.notch.battery else { return }
            self?.panels.forEach { $0.model.flash(.charging) }
        }

        let mouseEvents: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents, handler: { [weak self] event in
            self?.mouseEvent(event)
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mouseEvents, handler: { [weak self] event in
            self?.mouseEvent(event)
            return event
        }) { monitors.append(local) }
    }

    private func rebuild() {
        panels.forEach { $0.close() }
        panels = []
        let settings = SettingsStore.shared.current.notch
        guard settings.enabled else {
            FocusWatcher.shared.stop()
            return
        }
        if settings.notifications || settings.calls { NotificationWatcher.shared.start() }
        if settings.focus { FocusWatcher.shared.start() } else { FocusWatcher.shared.stop() }

        var screens = NSScreen.screens.filter { $0.safeAreaInsets.top > 0 }
        if screens.isEmpty, settings.showWithoutNotch, let main = NSScreen.screens.first { screens = [main] }
        for screen in screens {
            let panel = NotchPanel(screen: screen)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        if !panels.isEmpty { Log.write("notch: \(panels.count) tela(s)") }
    }

    private func mouseEvent(_ event: NSEvent) {
        let point = NSEvent.mouseLocation
        let pasteboard = NSPasteboard(name: .drag)
        switch event.type {
        case .leftMouseDown:
            dragChangeCount = pasteboard.changeCount
        case .leftMouseDragged:
            // Arrastando um arquivo até o notch: abre para receber na prateleira.
            if pasteboard.changeCount != dragChangeCount,
               pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]),
               SettingsStore.shared.current.notch.shelf {
                panels.first { $0.hotZone.contains(point) }?.model.open(reason: .drag)
            }
        default:
            break
        }
        for panel in panels { panel.mouseMoved(to: point) }
    }
}

// MARK: - Janela

final class NotchPanel: NSPanel {
    let model: NotchModel
    private let screenFrame: CGRect
    private var hoverWork: DispatchWorkItem?
    private var openObserver: AnyCancellable?

    init(screen: NSScreen) {
        screenFrame = screen.frame
        let notch = Self.notchSize(of: screen)
        model = NotchModel(notchSize: notch)
        let size = NotchController.canvasSize
        let frame = CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)

        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3) // por cima da barra de menu
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        // Fora de prints e do compartilhamento de tela (`defaults write … notch.debugCapture -bool true` para testar).
        sharingType = UserDefaults.standard.bool(forKey: "notch.debugCapture") ? .readOnly : .none
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        setFrame(frame, display: false)

        let host = NSHostingView(rootView: NotchView(model: model))
        host.frame = CGRect(origin: .zero, size: size)
        contentView = host

        // Fechado, os cliques passam direto (a barra de menu continua funcionando em volta do notch).
        openObserver = model.$isOpen.combineLatest(model.$alert).sink { [weak self] open, alert in
            let clickable = alert.map { $0.kind == .notification || $0.kind == .call } ?? false
            self?.ignoresMouseEvents = !(open || clickable)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    static func notchSize(of screen: NSScreen) -> CGSize {
        let height = screen.safeAreaInsets.top
        if height > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return CGSize(width: screen.frame.width - left.width - right.width, height: height)
        }
        // Sem notch: uma ilha do tamanho de um notch, na altura da barra de menu.
        return CGSize(width: 190, height: max(NSStatusBar.system.thickness, 24))
    }

    /// Área em volta do notch fechado que abre ao passar o mouse.
    var hotZone: CGRect {
        let size = model.notchSize
        // Passa um pouco do topo da tela: com o cursor encostado em cima (bem na câmera), a posição é
        // exatamente o limite da tela, que um retângulo que termina ali não contaria como dentro.
        return CGRect(x: screenFrame.midX - size.width / 2 - 12, y: screenFrame.maxY - size.height - 6,
                      width: size.width + 24, height: size.height + 16)
    }

    /// Área do notch aberto (com uma folga para o mouse não fechar por pouco).
    private var openZone: CGRect {
        let size = model.openSize
        return CGRect(x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - size.height,
                      width: size.width, height: size.height).insetBy(dx: -16, dy: -16)
    }

    func mouseMoved(to point: CGPoint) {
        if model.isOpen {
            // Não fecha no meio de um arraste (ex.: tirando um arquivo da prateleira).
            guard !openZone.contains(point), NSEvent.pressedMouseButtons == 0 else { return }
            hoverWork?.cancel()
            model.close()
        } else if hotZone.contains(point) {
            guard hoverWork == nil, SettingsStore.shared.current.notch.expandOnHover else { return }
            let work = DispatchWorkItem { [weak self] in
                self?.hoverWork = nil
                guard let self, self.hotZone.contains(NSEvent.mouseLocation) else { return }
                self.model.open(reason: .hover)
            }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        } else {
            hoverWork?.cancel()
            hoverWork = nil
        }
    }
}

// MARK: - Estado do notch

enum NotchPage: String, CaseIterable {
    case home, files, connectivity

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .files: "tray.full.fill"
        case .connectivity: "wifi"
        }
    }

    var title: String {
        switch self {
        case .home: "Início"
        case .files: "Arquivos"
        case .connectivity: "Conexões"
        }
    }
}

final class NotchModel: ObservableObject {
    enum OpenReason { case hover, drag }
    enum Flash { case charging }

    let notchSize: CGSize
    @Published private(set) var isOpen = false
    @Published private(set) var flash: Flash?
    @Published private(set) var alert: NotchAlert?
    private var alertWork: DispatchWorkItem?
    @Published var isDropTargeted = false
    @Published var page: NotchPage = .home { didSet { pageChanged() } }
    /// Mantém o notch aberto enquanto um menu dele está na tela (ex.: Compartilhar).
    var isPinned = false

    let nowPlaying = NowPlaying.shared
    let power = PowerMonitor.shared
    let shelf = NotchShelf.shared
    let calendar = NotchCalendar.shared
    let connectivity = Connectivity.shared
    private var flashWork: DispatchWorkItem?
    private var forwarders: [AnyCancellable] = []

    init(notchSize: CGSize) {
        self.notchSize = notchSize
        // A view só observa este modelo: repassa as mudanças dos outros.
        for publisher in [nowPlaying.objectWillChange.eraseToAnyPublisher(),
                          power.objectWillChange.eraseToAnyPublisher(),
                          shelf.objectWillChange.eraseToAnyPublisher(),
                          calendar.objectWillChange.eraseToAnyPublisher(),
                          connectivity.objectWillChange.eraseToAnyPublisher(),
                          SettingsStore.shared.objectWillChange.eraseToAnyPublisher()] {
            forwarders.append(publisher.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.objectWillChange.send() })
        }
    }

    var settings: NotchSettings { SettingsStore.shared.current.notch }

    var openSize: CGSize { CGSize(width: 640, height: notchSize.height + 172) }

    var pages: [NotchPage] {
        var pages: [NotchPage] = []
        if settings.music || settings.calendar { pages.append(.home) }
        if settings.shelf { pages.append(.files) }
        if settings.connectivity { pages.append(.connectivity) }
        return pages
    }

    /// Notch fechado mostrando algo dos lados (música tocando ou carregador).
    var closedSize: CGSize {
        if let alert {
            switch alert.kind {
            case .focus: return CGSize(width: notchSize.width + 240, height: notchSize.height)
            case .notification, .call: return CGSize(width: 440, height: notchSize.height + 74)
            }
        }
        if flash == .charging { return CGSize(width: notchSize.width + 140, height: notchSize.height) }
        if showsMiniPlayer { return CGSize(width: notchSize.width + 80, height: notchSize.height) }
        return notchSize
    }

    var showsMiniPlayer: Bool {
        settings.music && settings.showMusicWhenClosed && nowPlaying.isPlaying && nowPlaying.track != nil
    }

    func open(reason: OpenReason) {
        if reason == .drag, pages.contains(.files), page != .files { page = .files }
        guard !isOpen else { return }
        if !pages.contains(page), let first = pages.first { page = first }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) { isOpen = true }
        pageChanged()
    }

    func close() {
        guard isOpen, !isPinned else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { isOpen = false }
        connectivity.stopUpdating()
    }

    private func pageChanged() {
        guard isOpen else { return }
        if page == .home {
            if settings.music { nowPlaying.refreshIfNeeded() }
            if settings.calendar { calendar.start() }
        }
        if page == .connectivity { connectivity.startUpdating() } else { connectivity.stopUpdating() }
    }

    func show(_ alert: NotchAlert) {
        alertWork?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { self.alert = alert }
        // Ligações ficam até serem atendidas/recusadas (o banner some); o resto some sozinho.
        let seconds: Double
        switch alert.kind {
        case .call: seconds = 60
        case .focus: seconds = 2.5
        case .notification: seconds = 5
        }
        let work = DispatchWorkItem { [weak self] in self?.dismissAlert() }
        alertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func removeAlert(id: String) {
        guard alert?.id == id else { return }
        dismissAlert()
    }

    func dismissAlert() {
        alertWork?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { alert = nil }
    }

    func perform(_ action: NotchAlert.Action) {
        guard let alert else { return }
        NotificationWatcher.shared.perform(action, on: alert.id)
        dismissAlert()
    }

    func openAlert() {
        guard let alert else { return }
        NotificationWatcher.shared.open(alert.id)
        dismissAlert()
    }

    func flash(_ kind: Flash) {
        flashWork?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { flash = kind }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { self?.flash = nil }
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}

// MARK: - Bateria

final class PowerMonitor: ObservableObject {
    static let shared = PowerMonitor()

    @Published private(set) var level: Int?
    @Published private(set) var isCharging = false
    @Published private(set) var isPluggedIn = false
    var onPlugIn: (() -> Void)?

    private var source: CFRunLoopSource?

    func start() {
        guard source == nil else { return }
        read(initial: true)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue().read(initial: false)
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        self.source = source
    }

    private func read(initial: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        let battery = list.lazy
            .compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
            .first { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }
        guard let battery else { return } // Mac de mesa: sem bateria

        let current = battery[kIOPSCurrentCapacityKey] as? Int ?? 0
        let max = battery[kIOPSMaxCapacityKey] as? Int ?? 100
        let pluggedIn = battery[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        let wasPluggedIn = isPluggedIn
        level = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : nil
        isCharging = battery[kIOPSIsChargingKey] as? Bool ?? false
        isPluggedIn = pluggedIn
        if !initial, pluggedIn, !wasPluggedIn { onPlugIn?() }
    }
}

// MARK: - Prateleira

/// Arquivos guardados no notch para levar de um lugar para outro (só a referência; nada é copiado).
final class NotchShelf: ObservableObject {
    static let shared = NotchShelf()

    @Published private(set) var items: [URL] = []
    @Published var airDropTargeted = false
    @Published var shareTargeted = false

    func add(_ urls: [URL]) {
        for url in urls where !items.contains(url) { items.append(url) }
    }

    func remove(_ url: URL) { items.removeAll { $0 == url } }
    func clear() { items.removeAll() }

    func open(_ url: URL) { NSWorkspace.shared.open(url) }
    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: urls)
    }
}
