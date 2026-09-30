import AppKit
import ScreenCaptureKit

/// ⌘⇧S: seleciona uma área (Espaço alterna para janela), copia na hora para a área de transferência
/// e mostra uma miniatura no canto da tela. Clicar nela abre o print na Pré-Visualização.
final class ScreenshotController {
    static let shared = ScreenshotController()

    private var isCapturing = false
    private var thumbnail: ScreenshotThumbnail?

    private let freezer = ScreenFreezer()

    func capture() {
        guard !isCapturing else { return }
        isCapturing = true
        thumbnail?.dismiss(animated: false)

        guard SettingsStore.shared.settings.screenshot.freezeScreen else {
            runScreencapture(frozen: false)
            return
        }
        // Congela a tela: mostra uma foto de cada monitor por cima de tudo e seleciona em cima dela.
        freezer.freeze { [weak self] frozen in
            // Um instante para a imagem congelada aparecer antes da seleção começar.
            DispatchQueue.main.asyncAfter(deadline: .now() + (frozen ? 0.05 : 0)) {
                self?.runScreencapture(frozen: frozen)
            }
        }
    }

    private func runScreencapture(frozen: Bool) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShortcutKey-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i: seleção interativa, com o som padrão. Com a tela congelada, só seleção de área (-s):
        // o modo janela (Espaço) pegaria a imagem congelada inteira em vez de uma janela.
        process.arguments = (frozen ? ["-i", "-s"] : ["-i"]) + [tempURL.path]
        process.terminationHandler = { _ in
            DispatchQueue.main.async {
                self.freezer.unfreeze()
                self.isCapturing = false
                self.finish(tempURL)
            }
        }
        do {
            try process.run()
        } catch {
            freezer.unfreeze()
            isCapturing = false
            Log.write("print: falha ao abrir o screencapture: \(error)")
        }
    }

    private func finish(_ tempURL: URL) {
        // Sem arquivo = o usuário cancelou com Esc.
        guard let data = try? Data(contentsOf: tempURL), let image = NSImage(data: data) else { return }
        let settings = SettingsStore.shared.settings.screenshot

        // 1. Área de transferência primeiro, antes de qualquer outra coisa.
        if settings.copyToClipboard {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(data, forType: .png)
            if let tiff = image.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
        }

        // 2. Arquivo: por padrão fica numa pasta temporária (a Pré-Visualização abre de lá; para guardar,
        //    use Arquivo › Salvar nela). Opcionalmente, também na pasta de capturas do sistema.
        let folder = settings.saveToDesktop ? Self.screenshotFolder : Self.temporaryFolder
        var fileURL = folder.appendingPathComponent(Self.fileName())
        do {
            try FileManager.default.moveItem(at: tempURL, to: fileURL)
        } catch {
            Log.write("print: não foi possível mover para \(fileURL.path): \(error)")
            fileURL = tempURL
        }
        Log.write("print capturado: \(fileURL.lastPathComponent)")

        // 3. Miniatura no canto da tela.
        thumbnail = ScreenshotThumbnail(image: image, fileURL: fileURL)
    }

    /// Pasta temporária dos prints (o macOS limpa sozinho depois de alguns dias).
    private static var temporaryFolder: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ShortcutKey Prints", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Pasta configurada em ⌘⇧5 › Opções (padrão: Mesa).
    private static var screenshotFolder: URL {
        if let path = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
    }

    /// "Captura de Tela 2026-09-23 às 13.30.10.png", como o macOS.
    private static func fileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'às' HH.mm.ss"
        return "Captura de Tela \(formatter.string(from: Date())).png"
    }

    static func openInPreview(_ url: URL) {
        let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview")
            ?? URL(fileURLWithPath: "/System/Applications/Preview.app")
        NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - Congelar a tela

/// Tira uma foto de cada monitor e mostra por cima de tudo, para a tela "parar" durante a seleção.
final class ScreenFreezer {
    private var windows: [NSWindow] = []

    /// Chama `completion(true)` com a tela congelada, ou `false` se não deu (ex.: sem Gravação de Tela).
    func freeze(completion: @escaping (Bool) -> Void) {
        // Lê as telas aqui (thread principal); a captura roda em segundo plano.
        let targets = NSScreen.screens.compactMap { screen -> ScreenTarget? in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            else { return nil }
            return ScreenTarget(displayID: id, frame: screen.frame, scale: screen.backingScaleFactor)
        }
        Task {
            let shots = await Self.capture(targets)
            await MainActor.run {
                guard !shots.isEmpty else {
                    completion(false)
                    return
                }
                for shot in shots { self.show(shot.image, frame: shot.frame) }
                completion(true)
            }
        }
    }

    func unfreeze() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    private func show(_ image: CGImage, frame: CGRect) {
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = NSImageView(frame: NSRect(origin: .zero, size: frame.size))
        view.image = NSImage(cgImage: image, size: frame.size)
        view.imageScaling = .scaleAxesIndependently
        window.contentView = view
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        windows.append(window)
    }

    private struct ScreenTarget: Sendable {
        let displayID: CGDirectDisplayID
        let frame: CGRect
        let scale: CGFloat
    }

    private struct Shot: @unchecked Sendable {
        let frame: CGRect
        let image: CGImage
    }

    private static func capture(_ targets: [ScreenTarget]) async -> [Shot] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return []
        }
        var shots: [Shot] = []
        for display in content.displays {
            guard let target = targets.first(where: { $0.displayID == display.displayID }) else { continue }
            let config = SCStreamConfiguration()
            config.width = Int(target.frame.width * target.scale)
            config.height = Int(target.frame.height * target.scale)
            config.showsCursor = false
            let filter = SCContentFilter(display: display, excludingWindows: [])
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                shots.append(Shot(frame: target.frame, image: image))
            }
        }
        return shots
    }
}

// MARK: - Miniatura flutuante

/// Miniatura no canto inferior direito, como a do ⌘⇧3: clique abre na Pré-Visualização,
/// arrastar solta o arquivo em outro app, e ela some sozinha depois de alguns segundos.
final class ScreenshotThumbnail {
    private let panel: NSPanel
    private var hideTimer: Timer?
    private var finalFrame: NSRect = .zero

    init(image: NSImage, fileURL: URL) {
        let maxSize = NSSize(width: 220, height: 150)
        let ratio = min(maxSize.width / max(image.size.width, 1), maxSize.height / max(image.size.height, 1), 1)
        let size = NSSize(width: max(60, image.size.width * ratio), height: max(40, image.size.height * ratio))

        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let view = ScreenshotThumbnailView(frame: NSRect(origin: .zero, size: size), image: image, fileURL: fileURL)
        panel.contentView = view
        view.onClick = { [weak self] in
            ScreenshotController.openInPreview(fileURL)
            self?.dismiss(animated: true)
        }
        view.onClose = { [weak self] in self?.dismiss(animated: true) }
        view.onDragEnded = { [weak self] in self?.dismiss(animated: false) }
        view.onHover = { [weak self] hovering in
            if hovering { self?.hideTimer?.invalidate() } else { self?.scheduleHide(after: 3) }
        }

        // Entra deslizando pela direita, na tela onde está o cursor.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let area = screen.visibleFrame
        finalFrame = NSRect(x: area.maxX - size.width - 20, y: area.minY + 20, width: size.width, height: size.height)
        panel.setFrame(finalFrame.offsetBy(dx: size.width + 40, dy: 0), display: false)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(finalFrame, display: true)
        }
        scheduleHide(after: 6)
    }

    private func scheduleHide(after seconds: TimeInterval) {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.dismiss(animated: true)
        }
    }

    func dismiss(animated: Bool) {
        hideTimer?.invalidate()
        guard panel.isVisible else { return }
        guard animated else {
            panel.orderOut(nil)
            return
        }
        let panel = self.panel
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().setFrame(finalFrame.offsetBy(dx: finalFrame.width + 40, dy: 0), display: true)
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }
}

private final class ScreenshotThumbnailView: NSView, NSDraggingSource {
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    private let image: NSImage
    private let fileURL: URL
    private let closeButton: NSButton
    private var mouseDownPoint: NSPoint?
    private var didDrag = false

    init(frame: NSRect, image: NSImage, fileURL: URL) {
        self.image = image
        self.fileURL = fileURL
        closeButton = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Fechar")!,
                               target: nil, action: nil)
        super.init(frame: frame)

        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 3
        layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor

        let imageView = NSImageView(frame: bounds)
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)

        closeButton.isBordered = false
        closeButton.contentTintColor = .white
        closeButton.frame = NSRect(x: 6, y: bounds.height - 26, width: 20, height: 20)
        closeButton.isHidden = true
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        addSubview(closeButton)

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        toolTip = "Clique para abrir na Pré-Visualização · arraste para soltar em outro app"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func closeClicked() { onClose?() }

    override func mouseEntered(with event: NSEvent) {
        closeButton.isHidden = false
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        closeButton.isHidden = true
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didDrag, let start = mouseDownPoint else { return }
        let point = event.locationInWindow
        guard hypot(point.x - start.x, point.y - start.y) > 4 else { return }
        didDrag = true
        let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag, mouseDownPoint != nil { onClick?() }
        mouseDownPoint = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation != [] { onDragEnded?() }
    }
}
