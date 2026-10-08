import AppKit
import MultitouchBridge
import QuartzCore
import ScreenCaptureKit

/// "Deslizar entre apps": igual à troca de apps em tela cheia do macOS, mas com qualquer app aberto.
/// A tela atual acompanha os dedos e o app vizinho entra pelo lado; soltar decide se troca ou volta.
///
/// Fluxo (chamado pelo GestureEngine, sempre na thread principal):
/// `prepare()` quando os dedos encostam → `begin()` quando o arraste lateral começa →
/// `update(dx:)` a cada movimento → `end()` quando os dedos saem (ou `discard()` se não era arraste).
final class AppSwipeController {
    static let shared = AppSwipeController()

    /// Quanto do trackpad (0...1) é preciso arrastar para atravessar a tela inteira.
    private let trackpadPerScreen = 0.55
    private let gap: CGFloat = 28

    private var prep: Preparation?
    private var overlay: AppSwipeOverlay?
    private var isTracking = false
    private var offset: CGFloat = 0
    private var samples: [(time: CFTimeInterval, offset: CGFloat)] = []

    // MARK: Gesto

    func prepare() {
        guard prep == nil, !isTracking else { return }
        AppSnapshots.shared.refreshFrontmost()
        prep = Preparation.make()
        prep?.onImagesReady = { [weak self] in self?.buildOverlay() }
    }

    func discard() {
        guard !isTracking else { return }
        reset()
    }

    func begin() {
        if prep == nil { prepare() }
        isTracking = true
        offset = 0
        samples = []
    }

    func update(dx: Double) {
        guard isTracking, let prep else { return }
        let width = prep.screenFrame.width
        var raw = CGFloat(dx / trackpadPerScreen) * width

        // Sem vizinho naquele lado: estica um pouco e para (como no fim das Mesas).
        if (raw < 0 && prep.next == nil) || (raw > 0 && prep.previous == nil) {
            raw = (raw < 0 ? -1 : 1) * min(abs(raw) * 0.25, width * 0.08)
        }
        offset = max(-(width + gap), min(width + gap, raw))

        let now = CACurrentMediaTime()
        samples.append((now, offset))
        samples.removeAll { now - $0.time > 0.1 }

        overlay?.show()
        overlay?.setOffset(offset, animated: false)
    }

    func end() {
        guard isTracking, let prep else { return reset() }
        isTracking = false

        let width = prep.screenFrame.width
        let velocity = samples.count > 1
            ? (samples.last!.offset - samples.first!.offset) / CGFloat(max(samples.last!.time - samples.first!.time, 0.001))
            : 0
        let projected = offset + velocity * 0.15
        let target: NSRunningApplication? = projected < -width * 0.35 ? prep.next
            : projected > width * 0.35 ? prep.previous : nil

        guard let overlay, overlay.isVisible else {
            // Imagens ainda não prontas (ou sem Gravação de Tela): troca direto, sem animação.
            if let target { Self.activate(target) }
            return reset()
        }
        guard let target else {
            overlay.setOffset(0, animated: true) { [weak self] in self?.reset() }
            return
        }
        overlay.setOffset((projected < 0 ? -1 : 1) * (width + gap), animated: true) { [weak self] in
            Self.activate(target)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                overlay.fadeOut { self?.reset() }
            }
        }
    }

    private func buildOverlay() {
        guard let prep, overlay == nil, prep.currentImage != nil else { return }
        overlay = AppSwipeOverlay(prep: prep, gap: gap)
        if isTracking {
            overlay?.show()
            overlay?.setOffset(offset, animated: false)
        }
    }

    private func reset() {
        overlay?.close()
        overlay = nil
        prep = nil
        isTracking = false
        offset = 0
    }

    private static func activate(_ app: NSRunningApplication) {
        AX.setBool(AXUIElementCreateApplication(app.processIdentifier), kAXFrontmostAttribute, true)
        app.activate(options: [.activateAllWindows])
    }

    /// Teste: prepara as imagens e salva em ~/Library/Logs/ShortcutKey-swipe-*.jpg.
    func debugSnapshot() {
        let start = CACurrentMediaTime()
        guard let prep = Preparation.make() else { return Log.write("deslizar (teste): nada para preparar") }
        Log.write("deslizar (teste): anterior=\(prep.previous?.localizedName ?? "-") próximo=\(prep.next?.localizedName ?? "-")")
        self.prep = prep
        prep.onImagesReady = { [weak self] in
            Log.write(String(format: "deslizar (teste): imagens prontas em %.0f ms", (CACurrentMediaTime() - start) * 1000))
            let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
            for (name, image) in [("current", prep.currentImage), ("previous", prep.previousImage), ("next", prep.nextImage)] {
                guard let image else { continue }
                try? NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.6])?
                    .write(to: logs.appendingPathComponent("ShortcutKey-swipe-\(name).jpg"))
            }
            self?.prep = nil
        }
    }
}

// MARK: - Fotos guardadas dos apps

/// Foto das janelas de cada app, tirada enquanto ele está na frente. No Organizador Visual as janelas
/// dos outros apps ficam encolhidas na faixa lateral e o macOS não deixa capturá-las; por isso a prévia
/// do app de destino usa a última foto guardada.
final class AppSnapshots {
    static let shared = AppSnapshots()

    struct Shot: @unchecked Sendable {
        let image: CGImage
        /// Posição real da janela (coordenadas globais, origem no topo).
        let frame: CGRect
    }

    /// De trás para a frente, por app. Só lido e escrito na thread principal.
    private(set) var shots: [pid_t: [Shot]] = [:]
    private var pending: DispatchWorkItem?

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            // Espera a animação do Organizador Visual terminar.
            self?.pending?.cancel()
            let work = DispatchWorkItem { self?.refreshFrontmost() }
            self?.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.shots[app.processIdentifier] = nil
            }
        }
        refreshFrontmost()
    }

    func refreshFrontmost() {
        guard Thumbnails.hasPermission, let app = NSWorkspace.shared.frontmostApplication,
              app.activationPolicy == .regular, app != NSRunningApplication.current else { return }
        let pid = app.processIdentifier

        var frames: [CGWindowID: CGRect] = [:]
        for window in AX.standardWindows(pid: pid) where AX.bool(window, kAXMinimizedAttribute) != true {
            let id = CGWindowID(SKWindowIDForAXElement(Unmanaged.passUnretained(window).toOpaque()))
            if id != 0, let frame = AX.frame(window) { frames[id] = frame }
        }
        guard !frames.isEmpty else { return }
        let zOrder = Preparation.windowZOrder()

        Task { @MainActor [weak self] in
            let captured = await Self.capture(pid: pid, frames: frames, zOrder: zOrder)
            if !captured.isEmpty { self?.shots[pid] = captured }
        }
    }

    /// Captura em 1x (não Retina) para economizar memória: é só uma prévia durante a animação.
    nonisolated private static func capture(pid: pid_t, frames: [CGWindowID: CGRect], zOrder: [CGWindowID: Int]) async -> [Shot] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return [] }
        let windows = content.windows
            .filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && frames[$0.windowID] != nil }
            .sorted { (zOrder[$0.windowID] ?? .max) > (zOrder[$1.windowID] ?? .max) }

        return await withTaskGroup(of: (Int, Shot)?.self) { group in
            for (order, window) in windows.enumerated() {
                let frame = frames[window.windowID]!
                group.addTask {
                    let config = SCStreamConfiguration()
                    config.width = Int(frame.width)
                    config.height = Int(frame.height)
                    config.showsCursor = false
                    config.ignoreShadowsSingleWindow = true
                    guard let image = try? await SCScreenshotManager.captureImage(
                        contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
                    else { return nil }
                    return (order, Shot(image: image, frame: frame))
                }
            }
            var results: [(Int, Shot)] = []
            for await result in group { if let result { results.append(result) } }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}

// MARK: - Preparação: lista de apps e imagens

/// Apps com janelas na Mesa atual, em ordem fixa (ordem de abertura), e as imagens de cada "tela".
private final class Preparation {
    let screenFrame: CGRect
    let previous: NSRunningApplication?
    let next: NSRunningApplication?
    private(set) var currentImage: CGImage?
    private(set) var previousImage: CGImage?
    private(set) var nextImage: CGImage?
    var onImagesReady: (() -> Void)?

    private init(screenFrame: CGRect, previous: NSRunningApplication?, next: NSRunningApplication?) {
        self.screenFrame = screenFrame
        self.previous = previous
        self.next = next
    }

    /// Ordem das janelas visíveis, da frente para trás.
    static func windowZOrder() -> [CGWindowID: Int] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var order: [CGWindowID: Int] = [:]
        for (index, window) in info.enumerated() {
            if let number = window[kCGWindowNumber as String] as? Int { order[CGWindowID(number)] = index }
        }
        return order
    }

    static func make() -> Preparation? {
        let settings = SettingsStore.shared.settings
        // Apps com alguma janela na Mesa atual (inclui as da faixa do Organizador Visual).
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var pidsWithWindows = Set<pid_t>()
        for window in info where (window[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
            pidsWithWindows.insert(pid_t(pid))
        }

        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isHidden && $0 != NSRunningApplication.current
                && pidsWithWindows.contains($0.processIdentifier)
                && !settings.switcher.excludedBundleIDs.contains($0.bundleIdentifier ?? "")
        }
        guard !apps.isEmpty else { return nil }

        let front = NSWorkspace.shared.frontmostApplication
        let previous: NSRunningApplication?
        let next: NSRunningApplication?
        if let index = apps.firstIndex(where: { $0 == front }) {
            previous = index > 0 ? apps[index - 1] : nil
            next = index < apps.count - 1 ? apps[index + 1] : nil
        } else {
            // App da frente sem janelas (ex.: Finder): qualquer lado leva para a lista.
            previous = apps.last
            next = apps.first
        }

        guard let screen = currentScreen(),
              let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        else { return nil }

        let prep = Preparation(screenFrame: screen.frame, previous: previous, next: next)
        guard Thumbnails.hasPermission else { return prep } // sem imagens: troca sem animação

        let neighbors = [previous, next].map { app in
            Neighbor(shots: app.flatMap { AppSnapshots.shared.shots[$0.processIdentifier] },
                     icon: app?.icon?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        }
        let scale = screen.backingScaleFactor
        Task { @MainActor [weak prep] in
            // A captura roda fora da thread principal; o resultado volta para ela.
            let images = await capture(displayID: displayID, scale: scale, previous: neighbors[0], next: neighbors[1])
            guard let prep else { return }
            prep.currentImage = images.current
            prep.previousImage = images.previous
            prep.nextImage = images.next
            prep.onImagesReady?()
        }
        return prep
    }

    /// Tela da janela em foco (ou a do cursor).
    private static func currentScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if let window = AX.focusedWindow(), let frame = AX.frame(window) {
            let height = screens.first?.frame.height ?? 0
            let center = CGPoint(x: frame.midX, y: height - frame.midY)
            if let screen = screens.first(where: { $0.frame.contains(center) }) { return screen }
        }
        let mouse = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    private struct Neighbor: @unchecked Sendable {
        let shots: [AppSnapshots.Shot]?
        let icon: CGImage?
    }

    private struct Images: @unchecked Sendable {
        var current: CGImage?
        var previous: CGImage?
        var next: CGImage?
    }

    /// Tela atual e, para cada vizinho, a tela atual com as janelas dele por cima
    /// (é assim que a tela fica depois da troca).
    nonisolated private static func capture(displayID: CGDirectDisplayID, scale: CGFloat,
                                            previous: Neighbor, next: Neighbor) async -> Images {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == displayID }) else { return Images() }

        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.showsCursor = false
        guard let current = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config)
        else { return Images() }

        func destination(_ neighbor: Neighbor) -> CGImage? {
            if let shots = neighbor.shots, !shots.isEmpty {
                return compose(base: current, shots: shots, displayFrame: display.frame, scale: scale)
            }
            return placeholder(base: current, icon: neighbor.icon, scale: scale)
        }
        return Images(current: current, previous: destination(previous), next: destination(next))
    }

    private static func context(like base: CGImage) -> CGContext? {
        let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        ctx?.interpolationQuality = .high
        ctx?.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        return ctx
    }

    private static func compose(base: CGImage, shots: [AppSnapshots.Shot], displayFrame: CGRect, scale: CGFloat) -> CGImage? {
        guard let ctx = context(like: base) else { return nil }
        for shot in shots {
            // Quadros em coordenadas globais com origem no topo; o CGContext tem origem embaixo.
            let rect = CGRect(x: (shot.frame.minX - displayFrame.minX) * scale,
                              y: (displayFrame.maxY - shot.frame.maxY) * scale,
                              width: shot.frame.width * scale, height: shot.frame.height * scale)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 40 * scale,
                          color: CGColor(gray: 0, alpha: 0.45))
            ctx.draw(shot.image, in: rect)
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    /// Sem foto guardada: tela escurecida com o ícone do app no meio.
    private static func placeholder(base: CGImage, icon: CGImage?, scale: CGFloat) -> CGImage? {
        guard let ctx = context(like: base) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
        ctx.fill(CGRect(x: 0, y: 0, width: base.width, height: base.height))
        if let icon {
            let size = 200 * scale
            ctx.draw(icon, in: CGRect(x: (CGFloat(base.width) - size) / 2, y: (CGFloat(base.height) - size) / 2,
                                      width: size, height: size))
        }
        return ctx.makeImage()
    }
}

// MARK: - Animação

/// Janela por cima de tudo com três "telas" lado a lado: anterior, atual e próxima.
/// Criada assim que as imagens ficam prontas e só aparece quando o arraste começa.
private final class AppSwipeOverlay {
    private let window: NSWindow
    private let currentLayer = CALayer()
    private let previousLayer = CALayer()
    private let nextLayer = CALayer()
    private let width: CGFloat
    private let gap: CGFloat
    private var offset: CGFloat = 0

    var isVisible: Bool { window.isVisible }

    init(prep: Preparation, gap: CGFloat) {
        let frame = prep.screenFrame
        width = frame.width
        self.gap = gap

        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        for layer in [previousLayer, nextLayer, currentLayer] {
            layer.frame = view.bounds
            layer.contentsGravity = .resize
            layer.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
            layer.shadowOpacity = 0.5
            layer.shadowRadius = 20
            view.layer?.addSublayer(layer)
        }
        currentLayer.contents = prep.currentImage
        previousLayer.contents = prep.previousImage
        nextLayer.contents = prep.nextImage
        previousLayer.isHidden = prep.previous == nil
        nextLayer.isHidden = prep.next == nil

        window.contentView = view
        window.setFrame(frame, display: false)
        layout()
    }

    func show() {
        guard !window.isVisible else { return }
        window.orderFrontRegardless()
    }

    func setOffset(_ value: CGFloat, animated: Bool, completion: (() -> Void)? = nil) {
        offset = value
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.28)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            CATransaction.setCompletionBlock(completion)
        } else {
            CATransaction.setDisableActions(true)
        }
        layout()
        CATransaction.commit()
        if !animated { completion?() }
    }

    func fadeOut(completion: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            window.animator().alphaValue = 0
        }, completionHandler: completion)
    }

    func close() {
        window.orderOut(nil)
    }

    private func layout() {
        currentLayer.position.x = width / 2 + offset
        nextLayer.position.x = width / 2 + offset + width + gap
        previousLayer.position.x = width / 2 + offset - width - gap
    }
}
