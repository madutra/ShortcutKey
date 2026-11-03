import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NotchView: View {
    @ObservedObject var model: NotchModel

    private var topRadius: CGFloat { model.isOpen ? 12 : 6 }
    private var radius: CGFloat { model.isOpen ? 28 : model.notchSize.height / 2.4 }
    /// As pontinhas de cima ficam para fora do tamanho pedido, como as do notch de verdade.
    private var size: CGSize {
        let base = model.isOpen ? model.openSize : model.closedSize
        return CGSize(width: base.width + 2 * topRadius, height: base.height)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(bottomRadius: radius, topRadius: topRadius)
                    .fill(Color.black)
                if model.isOpen {
                    OpenNotchContent(model: model)
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
                } else {
                    ClosedNotchContent(model: model)
                        .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(NotchShape(bottomRadius: radius, topRadius: topRadius))
            .shadow(color: .black.opacity(model.isOpen ? 0.45 : 0), radius: 12, y: 4)
            .onDrop(of: [UTType.fileURL], isTargeted: $model.isDropTargeted) { providers in
                guard model.settings.shelf else { return false }
                loadFileURLs(providers) { NotchShelf.shared.add($0) }
                return true
            }
            Spacer(minLength: 0)
        }
        .frame(width: NotchController.canvasSize.width, height: NotchController.canvasSize.height)
        .environment(\.colorScheme, .dark)
    }
}

/// Retângulo preto com as pontinhas de cima curvadas para fora (como o notch) e os cantos de baixo arredondados.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var topRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, topRadius) }
        set { bottomRadius = newValue.first; topRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let top = min(topRadius, rect.width / 4)
        let bottom = min(bottomRadius, rect.height / 2, (rect.width - 2 * top) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top, y: rect.minY + top),
                          control: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
                          control: CGPoint(x: rect.minX + top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
                          control: CGPoint(x: rect.maxX - top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Fechado

private struct ClosedNotchContent: View {
    @ObservedObject var model: NotchModel

    @ViewBuilder
    var body: some View {
        if let alert = model.alert {
            AlertContent(alert: alert, model: model)
        } else {
            indicators
        }
    }

    private var indicators: some View {
        HStack(spacing: 0) {
            if model.flash == .charging {
                Image(systemName: "bolt.fill").foregroundStyle(.green)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.leading, 18)
                Spacer()
                Text(model.power.level.map { "\($0)%" } ?? "")
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.green)
                    .padding(.trailing, 18)
            } else if model.showsMiniPlayer {
                Artwork(image: model.nowPlaying.artwork, size: model.notchSize.height - 10, corner: 5)
                    .padding(.leading, 14)
                Spacer()
                EqualizerBars(isPlaying: model.nowPlaying.isPlaying)
                    .frame(width: 18, height: 12)
                    .padding(.trailing, 16)
            }
        }
        .frame(maxHeight: model.notchSize.height)
    }
}

private struct AlertContent: View {
    let alert: NotchAlert
    @ObservedObject var model: NotchModel

    var body: some View {
        switch alert.kind {
        case .focus(let on):
            HStack {
                Image(systemName: alert.symbol ?? "moon.fill")
                    .foregroundStyle(on ? Color.indigo : .white.opacity(0.6))
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.leading, 18)
                Spacer()
                Text(on ? alert.title : "Foco desativado")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(on ? Color.indigo : .white.opacity(0.7))
                    .lineLimit(1)
                    .padding(.trailing, 18)
            }
            .frame(maxHeight: model.notchSize.height)
        case .notification, .call:
            VStack(spacing: 0) {
                Spacer().frame(height: model.notchSize.height)
                HStack(spacing: 10) {
                    Group {
                        if let icon = alert.icon {
                            Image(nsImage: icon).resizable()
                        } else {
                            Image(systemName: alert.kind == .call ? "phone.fill" : "bell.fill")
                                .font(.system(size: 18)).foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    .frame(width: 38, height: 38)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(alert.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(alert.kind == .call ? "chamada" : alert.appName.lowercased())
                                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                        }
                        if !alert.body.isEmpty {
                            Text(alert.body).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { model.openAlert() }

                    if alert.kind == .call {
                        ForEach(alert.actions.filter { $0.role != .other }.sorted { $0.role == .decline && $1.role == .accept }) { action in
                            Button { model.perform(action) } label: {
                                Image(systemName: action.role == .accept ? "phone.fill" : "phone.down.fill")
                                    .font(.system(size: 15, weight: .semibold))
                                    .frame(width: 38, height: 38)
                                    .background(Circle().fill(action.role == .accept ? Color.green : Color.red))
                            }
                            .buttonStyle(.plain)
                            .help(action.title)
                        }
                    } else if let first = alert.actions.first {
                        Button(first.title) { model.perform(first) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(.white.opacity(0.15)))
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Aberto

private struct OpenNotchContent: View {
    @ObservedObject var model: NotchModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            // Faixa de cima, dos lados do notch físico: abas à esquerda, bateria e ajustes à direita.
            HStack(spacing: 4) {
                ForEach(model.pages, id: \.self) { page in
                    Button { model.page = page } label: {
                        Image(systemName: page.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 30, height: 22)
                            .background(Capsule().fill(model.page == page ? .white.opacity(0.18) : .clear))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(model.page == page ? 1 : 0.55))
                    .help(page.title)
                }
                Spacer()
                if model.settings.battery, let level = model.power.level {
                    BatteryLabel(level: level, charging: model.power.isCharging, pluggedIn: model.power.isPluggedIn)
                }
                Button {
                    model.close()
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 12))
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.7))
                .help("Configurações do ShortcutKey")
                .padding(.leading, 6)
            }
            .padding(.horizontal, 22)
            .frame(height: model.notchSize.height)

            Group {
                switch model.page {
                case .home: HomePage(model: model)
                case .files: FilesPage(model: model, shelf: model.shelf)
                case .connectivity: ConnectivityPage(connectivity: model.connectivity)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
    }
}

private struct HomePage: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        HStack(spacing: 16) {
            if model.settings.music {
                MusicPanel(nowPlaying: model.nowPlaying)
                    .frame(width: model.settings.calendar ? 290 : nil)
            }
            if model.settings.music && model.settings.calendar {
                Rectangle().fill(.white.opacity(0.1)).frame(width: 1)
            }
            if model.settings.calendar {
                CalendarPanel(calendar: model.calendar)
            }
        }
    }
}

private struct BatteryLabel: View {
    let level: Int
    let charging: Bool
    let pluggedIn: Bool

    private var symbol: String {
        if charging || pluggedIn { return "battery.100percent.bolt" }
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Text("\(level)%").font(.system(size: 12, weight: .medium)).monospacedDigit()
            Image(systemName: symbol)
                .symbolRenderingMode(.palette)
                .foregroundStyle(level <= 20 && !pluggedIn ? .red : charging ? .green : .white, .white.opacity(0.5))
        }
        .foregroundStyle(.white.opacity(0.85))
    }
}

// MARK: Música

private struct MusicPanel: View {
    @ObservedObject var nowPlaying: NowPlaying

    var body: some View {
        HStack(spacing: 14) {
            Button { nowPlaying.openPlayer() } label: {
                Artwork(image: nowPlaying.artwork, size: 96, corner: 12)
            }
            .buttonStyle(.plain)
            .disabled(nowPlaying.player == nil)

            VStack(alignment: .leading, spacing: 4) {
                if let track = nowPlaying.track {
                    Text(track.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(track.artist).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    Spacer(minLength: 4)
                    ProgressRow(nowPlaying: nowPlaying)
                    Controls(nowPlaying: nowPlaying)
                } else {
                    Text("Nada tocando").font(.system(size: 14, weight: .semibold))
                    Text("Abra o Spotify e dê play").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                    Spacer()
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ProgressRow: View {
    @ObservedObject var nowPlaying: NowPlaying

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let position = nowPlaying.currentPosition(at: context.date)
            let duration = nowPlaying.track?.duration ?? 0
            HStack(spacing: 8) {
                Text(Self.format(position))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.2))
                        Capsule().fill(.white)
                            .frame(width: duration > 0 ? geo.size.width * min(position / duration, 1) : 0)
                    }
                }
                .frame(height: 4)
                Text(Self.format(duration))
            }
            .font(.system(size: 10)).monospacedDigit()
            .foregroundStyle(.white.opacity(0.6))
        }
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct Controls: View {
    @ObservedObject var nowPlaying: NowPlaying

    var body: some View {
        HStack(spacing: 22) {
            controlButton("backward.fill", size: 15) { nowPlaying.previous() }
            controlButton(nowPlaying.isPlaying ? "pause.fill" : "play.fill", size: 20) { nowPlaying.playPause() }
            controlButton("forward.fill", size: 15) { nowPlaying.next() }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }

    private func controlButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}

struct Artwork: View {
    let image: NSImage?
    let size: CGFloat
    let corner: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom)
                    Image(systemName: "music.note").font(.system(size: size * 0.4)).foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

/// Barrinhas que pulam enquanto a música toca.
private struct EqualizerBars: View {
    let isPlaying: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !isPlaying)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let wave = isPlaying ? (sin(t * (5 + Double(i) * 1.7) + Double(i)) + 1) / 2 : 0.15
                    Capsule().fill(Color.green)
                        .frame(width: 3, height: 3 + 9 * wave)
                }
            }
        }
    }
}

// MARK: Prateleira

struct ShelfItem: View {
    let url: URL
    let shelf: NotchShelf

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 44, height: 44)
            Text(url.lastPathComponent)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 64)
                .foregroundStyle(.white.opacity(0.85))
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { shelf.open(url) }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .contextMenu {
            Button("Abrir") { shelf.open(url) }
            Button("Mostrar no Finder") { shelf.reveal(url) }
            Divider()
            Button("Tirar da prateleira") { shelf.remove(url) }
        }
        .help(url.path)
    }
}

func loadFileURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
    let group = DispatchGroup()
    var urls: [URL] = []
    let lock = NSLock()
    for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url { lock.lock(); urls.append(url); lock.unlock() }
            group.leave()
        }
    }
    group.notify(queue: .main) { completion(urls) }
}
