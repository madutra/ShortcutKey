import AppKit

/// Um aviso que aparece na ilha do notch.
struct NotchAlert: Identifiable, Equatable {
    enum Kind: Equatable {
        case notification
        case call
        case focus(on: Bool)
    }

    struct Action: Equatable, Identifiable {
        enum Role { case accept, decline, other }

        var id: String { rawName }
        let title: String
        /// Nome da ação na Acessibilidade (para apertar o botão de verdade no banner do macOS).
        let rawName: String
        let role: Role
    }

    let id: String
    let kind: Kind
    let appName: String
    let title: String
    let body: String
    let icon: NSImage?
    var symbol: String?
    var actions: [Action] = []

    static func == (a: NotchAlert, b: NotchAlert) -> Bool {
        a.id == b.id && a.kind == b.kind && a.title == b.title && a.body == b.body && a.actions == b.actions
    }
}

/// Lê os banners de notificação do macOS pela Acessibilidade (mensagens, WhatsApp, ligações…)
/// e permite apertar os botões deles (Atender, Recusar…) pelo notch.
final class NotificationWatcher {
    static let shared = NotificationWatcher()

    /// Aviso novo (ou ligação atualizada), na thread principal.
    var onAlert: ((NotchAlert) -> Void)?
    /// O banner sumiu (respondido, fechado ou expirou).
    var onRemove: ((String) -> Void)?

    private static let bundleID = "com.apple.notificationcenterui"
    private var observer: AXObserver?
    private var app: AXUIElement?
    private var banners: [String: AXUIElement] = [:]
    private var pendingScan: DispatchWorkItem?
    private var started = false

    func start() {
        if !started {
            started = true
            // A Central de Notificações pode reiniciar: observa de novo.
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                let launched = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if launched?.bundleIdentifier == Self.bundleID {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.attach() }
                }
            }
        }
        if observer == nil { attach() }
    }

    private func attach() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        observer = nil
        app = nil
        banners = [:]
        guard AX.isTrusted,
              let center = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else { return }
        let pid = center.processIdentifier
        var created: AXObserver?
        guard AXObserverCreate(pid, { _, _, _, context in
            guard let context else { return }
            Unmanaged<NotificationWatcher>.fromOpaque(context).takeUnretainedValue().scheduleScan()
        }, &created) == .success, let created else { return }
        let app = AXUIElementCreateApplication(pid)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowCreatedNotification, kAXCreatedNotification, kAXUIElementDestroyedNotification, kAXLayoutChangedNotification] {
            AXObserverAddNotification(created, app, name as CFString, context)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        self.app = app
        Log.write("avisos: observando a Central de Notificações")
    }

    /// Junta várias mudanças seguidas numa leitura só.
    private func scheduleScan() {
        pendingScan?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        pendingScan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    // MARK: Ações

    func perform(_ action: NotchAlert.Action, on alertID: String) {
        guard let banner = banners[alertID] else { return }
        let result = AXUIElementPerformAction(banner, action.rawName as CFString)
        Log.write("avisos: \(action.title) = \(result.rawValue)")
        scheduleScan()
    }

    /// Clique no aviso: abre o app, como clicar no banner.
    func open(_ alertID: String) {
        guard let banner = banners[alertID] else { return }
        let show = Self.actionNames(banner).first { ["Mostrar", "Show"].contains(Self.title(of: $0)) } ?? kAXPressAction
        AXUIElementPerformAction(banner, show as CFString)
    }

    // MARK: Leitura dos banners

    private func scan() {
        guard let app else { return }
        var found: [String: AXUIElement] = [:]
        for window in AX.elements(app, kAXWindowsAttribute) where AX.string(window, kAXSubroleAttribute) == "AXSystemDialog" {
            collectBanners(in: window, depth: 0, into: &found)
        }

        for (id, banner) in found {
            let isNew = banners[id] == nil
            banners[id] = banner
            guard let alert = Self.alert(from: banner, id: id) else { continue }
            if isNew || alert.kind == .call { onAlert?(alert) }
        }
        for id in banners.keys where found[id] == nil {
            banners[id] = nil
            onRemove?(id)
        }
    }

    private func collectBanners(in element: AXUIElement, depth: Int, into found: inout [String: AXUIElement]) {
        guard depth < 8 else { return }
        if AX.string(element, kAXSubroleAttribute) == "AXNotificationCenterBanner" {
            let id = AX.string(element, kAXIdentifierAttribute) ?? AX.string(element, kAXDescriptionAttribute) ?? UUID().uuidString
            found[id] = element
            return
        }
        for child in AX.elements(element, kAXChildrenAttribute) {
            collectBanners(in: child, depth: depth + 1, into: &found)
        }
    }

    private static func alert(from banner: AXUIElement, id: String) -> NotchAlert? {
        var texts: [String: String] = [:]
        for child in AX.elements(banner, kAXChildrenAttribute) {
            if let key = AX.string(child, kAXIdentifierAttribute), let value = AX.string(child, kAXValueAttribute) {
                texts[key] = value
            }
        }
        let title = texts["title"] ?? ""
        let subtitle = texts["subtitle"] ?? ""
        let body = texts["body"] ?? ""
        guard !(title.isEmpty && body.isEmpty) else { return nil }

        // A descrição é "App, título, subtítulo, corpo": o nome do app é o que vem antes do título.
        let description = AX.string(banner, kAXDescriptionAttribute) ?? ""
        var appName = description
        if !title.isEmpty, let range = description.range(of: ", " + title) {
            appName = String(description[..<range.lowerBound])
        } else if let comma = description.firstIndex(of: ",") {
            appName = String(description[..<comma])
        }

        let ignored: Set<String> = ["Mostrar Detalhes", "Show Details", "Mostrar", "Show", "Fechar", "Close", "Limpar", "Clear"]
        let actions = actionNames(banner).compactMap { raw -> NotchAlert.Action? in
            guard raw.hasPrefix("Name:") else { return nil }
            let name = Self.title(of: raw)
            guard !ignored.contains(name) else { return nil }
            let lower = name.lowercased()
            let role: NotchAlert.Action.Role =
                ["atender", "aceitar", "answer", "accept"].contains(where: lower.contains) ? .accept
                : ["recusar", "rejeitar", "decline", "ignorar", "encerrar"].contains(where: lower.contains) ? .decline
                : .other
            return NotchAlert.Action(title: name, rawName: raw, role: role)
        }
        let text = (title + " " + subtitle + " " + body).lowercased()
        let mentionsCall = ["ligação", "ligando", "chamada", "call", "facetime"].contains(where: text.contains)
        let isCall = actions.contains { $0.role == .accept } || (mentionsCall && actions.contains { $0.role == .decline })

        return NotchAlert(id: id, kind: isCall ? .call : .notification, appName: appName,
                          title: title.isEmpty ? appName : title,
                          body: [subtitle, body].filter { !$0.isEmpty }.joined(separator: " · "),
                          icon: icon(forAppNamed: appName), symbol: nil, actions: actions)
    }

    private static func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        AXUIElementCopyActionNames(element, &names)
        return (names as? [String]) ?? []
    }

    /// "Name:Atender\nTarget:0x0\nSelector:(null)" → "Atender".
    private static func title(of rawAction: String) -> String {
        let firstLine = rawAction.split(separator: "\n").first.map(String.init) ?? rawAction
        return firstLine.hasPrefix("Name:") ? String(firstLine.dropFirst(5)) : firstLine
    }

    private static func icon(forAppNamed name: String) -> NSImage? {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) {
            return app.icon
        }
        return installedApps[name].map { NSWorkspace.shared.icon(forFile: $0) }
    }

    /// Nome que aparece no banner (já traduzido, ex.: "Editor de Scripts") → caminho do app.
    private static let installedApps: [String: String] = {
        var apps: [String: String] = [:]
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                       FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        for folder in folders {
            for item in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where item.hasSuffix(".app") {
                let path = "\(folder)/\(item)"
                let display = FileManager.default.displayName(atPath: path)
                apps[display.hasSuffix(".app") ? String(display.dropLast(4)) : display] = path
                apps[String(item.dropLast(4))] = apps[String(item.dropLast(4))] ?? path
            }
        }
        return apps
    }()
}

// MARK: - Modo de foco

/// Avisa quando um modo de foco liga ou desliga, olhando o ícone do Foco na barra de menu
/// (ele só aparece com um foco ligado). Usa a Acessibilidade; não precisa de outra permissão.
final class FocusWatcher {
    static let shared = FocusWatcher()

    var onChange: ((_ name: String?, _ symbol: String?) -> Void)?

    private var timer: Timer?
    private var current: String?
    private var isActive = false

    func start() {
        guard timer == nil else { return }
        let state = Self.read()
        isActive = state != nil
        current = state
        Log.write("foco: \(state.map { "ligado (\($0))" } ?? "desligado")")
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.check() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func check() {
        let state = Self.read()
        guard (state != nil) != isActive || (state != nil && state != current) else { return }
        isActive = state != nil
        current = state
        Log.write("foco: \(state.map { "ligado (\($0))" } ?? "desligado")")
        onChange?(state.flatMap { $0.isEmpty ? nil : $0 } ?? (isActive ? "Foco ativado" : nil), Self.symbol(for: state))
    }

    /// nil = nenhum foco ligado; senão, o nome do foco (pode vir vazio).
    private static func read() -> String? {
        for bundleID in ["com.apple.MenuBarAgent", "com.apple.controlcenter"] {
            guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { continue }
            let app = AXUIElementCreateApplication(process.processIdentifier)
            guard let bar = AX.element(app, "AXExtrasMenuBar") else { continue }
            for item in allItems(bar, depth: 0) {
                guard let id = AX.string(item, kAXIdentifierAttribute), id.lowercased().contains("focus") else { continue }
                let text = [AX.string(item, kAXValueAttribute), AX.string(item, kAXDescriptionAttribute), AX.string(item, kAXTitleAttribute)]
                    .compactMap { $0 }.first { !$0.isEmpty } ?? ""
                return text
            }
        }
        return nil
    }

    private static func allItems(_ element: AXUIElement, depth: Int) -> [AXUIElement] {
        guard depth < 3 else { return [] }
        return AX.elements(element, kAXChildrenAttribute).flatMap { child in
            AX.string(child, kAXRoleAttribute) == kAXMenuBarItemRole ? [child] : allItems(child, depth: depth + 1)
        }
    }

    private static func symbol(for name: String?) -> String {
        guard let name = name?.lowercased() else { return "moon.zzz" }
        if name.contains("trabalho") || name.contains("work") { return "briefcase.fill" }
        if name.contains("dormir") || name.contains("sono") || name.contains("sleep") { return "bed.double.fill" }
        if name.contains("pessoal") || name.contains("personal") { return "person.fill" }
        if name.contains("dire") || name.contains("driv") { return "car.fill" }
        if name.contains("leitura") || name.contains("reading") { return "book.fill" }
        if name.contains("jogo") || name.contains("gaming") { return "gamecontroller.fill" }
        return "moon.fill"
    }
}
