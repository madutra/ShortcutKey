import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NotchView: View {
    @ObservedObject var model: NotchModel

    private var topRadius: CGFloat { model.isOpen ? 12 : 6 }
    /// Vidro no notch aberto e na ilha de volume/brilho; preto quando só "veste" o notch.
    private var isGlass: Bool {
        if model.isOpen { return true }
        if case .level = model.flash { return true }
        return false
    }
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
                if isGlass {
                    GlassPanelBackground(notchHeight: model.notchSize.height)
                        .transition(.opacity)
                }
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
            .overlay(
                // Brilho bem suave por dentro da borda (sem linha marcada): dá volume ao vidro.
                NotchShape(bottomRadius: radius, topRadius: topRadius)
                    .stroke(LinearGradient(colors: [.clear, .white.opacity(0.05), .white.opacity(0.12)],
                                           startPoint: .top, endPoint: .bottom), lineWidth: 3)
                    .blur(radius: 3)
                    .clipShape(NotchShape(bottomRadius: radius, topRadius: topRadius))
                    .opacity(isGlass ? 1 : 0)
            )
            // Sombra larga e difusa: o vidro "flutua" e se mistura com o que está atrás.
            .shadow(color: .black.opacity(isGlass ? 0.35 : 0), radius: 26, y: 12)
            .shadow(color: .black.opacity(isGlass ? 0.25 : 0), radius: 6, y: 2)
            .onDrop(of: [UTType.fileURL], isTargeted: $model.isDropTargeted) { providers in
                guard model.settings.shelf else { return false }
                loadFileURLs(providers) { NotchShelf.shared.add($0) }
                return true
            }
            if model.isOpen, model.pages.count > 1 {
                PageBar(model: model)
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .offset(y: -10)))
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

    @ViewBuilder
    private var indicators: some View {
        if case .level(let kind, let value, let muted) = model.flash {
            LevelControl(model: model, kind: kind, value: value, muted: muted)
        } else {
            sideIndicators
        }
    }

    private var sideIndicators: some View {
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
                Artwork(image: model.nowPlaying.artwork, size: model.notchSize.height - 10, corner: 5, fallback: model.nowPlaying.sourceApp?.icon)
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

/// Volume ou brilho, no estilo da Central de Controle do macOS: título, nome da saída e uma barra
/// grossa com o ícone dentro. Clique ou arraste na barra para mudar.
private struct LevelControl: View {
    @ObservedObject var model: NotchModel
    let kind: SystemLevels.Kind
    let value: Float
    let muted: Bool

    private var shown: Float { muted ? 0 : min(max(value, 0), 1) }

    private var symbol: String {
        switch kind {
        case .brightness:
            return value < 0.35 ? "sun.min.fill" : "sun.max.fill"
        case .volume:
            if muted || value == 0 { return "speaker.slash.fill" }
            return value < 0.34 ? "speaker.wave.1.fill" : value < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: model.notchSize.height)
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text(kind == .volume ? "Som" : "Tela").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if kind == .volume, let name = SystemLevels.outputName {
                        Text(name).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                    }
                }
                AppleSlider(value: shown, symbol: symbol,
                            onChange: { model.setLevel(kind, to: $0) },
                            onSymbolTap: kind == .volume ? { model.toggleMute() } : nil)
                    .frame(height: 24)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 12)
            .frame(maxHeight: .infinity)
        }
    }
}

/// A barra dos controles do macOS: trilho de vidro, parte cheia branca e o ícone dentro, à esquerda.
private struct AppleSlider: View {
    let value: Float
    let symbol: String
    let onChange: (Float) -> Void
    var onSymbolTap: (() -> Void)?

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            // Como no macOS, a parte cheia nunca fica menor que um círculo (onde o ícone mora).
            let filled = height + (geo.size.width - height) * CGFloat(value)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.14)).modifier(GlassCapsule())
                Capsule().fill(.white).frame(width: filled)
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.55))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: height, height: height)
                    .contentShape(Circle())
                    .onTapGesture { onSymbolTap?() }
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 1).onChanged { drag in
                let x = (drag.location.x - height / 2) / max(geo.size.width - height, 1)
                onChange(Float(min(max(x, 0), 1)))
            })
            .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                guard tap.location.x > height else { return } // o toque no ícone é o mudo
                let x = (tap.location.x - height / 2) / max(geo.size.width - height, 1)
                onChange(Float(min(max(x, 0), 1)))
            })
            .animation(.easeOut(duration: 0.12), value: value)
        }
    }
}

private struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(Capsule().fill(.ultraThinMaterial)).overlay(Capsule().strokeBorder(.white.opacity(0.15)))
        }
    }
}

// MARK: - Aberto

/// Fundo de vidro do notch aberto (como o NotchNook): desfoca o que está atrás da janela, escurece um
/// pouco para o texto ler bem e fica preto em cima, onde encosta no notch de verdade.
private struct GlassPanelBackground: View {
    let notchHeight: CGFloat

    var body: some View {
        ZStack {
            VisualEffectBlur()
            LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.30)], startPoint: .top, endPoint: .bottom)
            // Reflexo sutil no topo do vidro.
            LinearGradient(colors: [.white.opacity(0.06), .clear], startPoint: .top, endPoint: .center)
            VStack(spacing: 0) {
                LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: notchHeight + 14)
                Spacer()
            }
        }
    }
}

/// O vidro fosco do macOS (o mesmo dos menus), desfocando o que está atrás da janela.
private struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Barra das abas, flutuando embaixo do notch aberto (cápsula de vidro).
private struct PageBar: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(model.pages, id: \.self) { page in
                let selected = model.page == page
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.page = page }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: page.symbol).font(.system(size: 11, weight: .semibold))
                        if selected { Text(page.title).font(.system(size: 11, weight: .semibold)) }
                    }
                    .padding(.horizontal, selected ? 11 : 9)
                    .frame(height: 26)
                    .background(Capsule().fill(.white.opacity(selected ? 0.16 : 0)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(selected ? 1 : 0.6))
                .help(page.title)
            }
        }
        .padding(4)
        .background(
            ZStack {
                VisualEffectBlur()
                Color.black.opacity(0.35)
            }
            .clipShape(Capsule())
        )
        .overlay(Capsule().stroke(.white.opacity(0.10), lineWidth: 2).blur(radius: 2).clipShape(Capsule()))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }
}

private struct OpenNotchContent: View {
    @ObservedObject var model: NotchModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            // Faixa de cima, dos lados do notch físico: data e hora à esquerda, bateria e ajustes à direita.
            HStack(spacing: 4) {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    Text(context.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()
                        .locale(Locale(identifier: "pt_BR"))))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
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
                    .frame(width: model.settings.calendar ? 230 : nil)
            }
            if model.settings.camera {
                // Mini webcam redonda entre a música e o calendário.
                CameraTile(camera: CameraMirror.shared)
                    .frame(width: 104, height: 104)
            } else if model.settings.music && model.settings.calendar {
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

/// No estilo do "Tocando Agora" do macOS: capa em cima, nome e tempo no meio, controles de vidro embaixo.
private struct MusicPanel: View {
    @ObservedObject var nowPlaying: NowPlaying

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button { nowPlaying.openPlayer() } label: { cover }
                .buttonStyle(.plain)
                .disabled(!nowPlaying.canOpenPlayer)
                .help(nowPlaying.sourceName.map { "Abrir \($0)" } ?? "")

            if let track = nowPlaying.track {
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text([track.artist, nowPlaying.sourceName ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                ProgressRow(nowPlaying: nowPlaying)
                Controls(nowPlaying: nowPlaying)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Nada tocando").font(.system(size: 13, weight: .semibold))
                    Text("Dê play numa música ou vídeo").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// A capa ocupa a largura toda. Capas quadradas (música) ficam inteiras, com a própria capa
    /// desfocada atrás; miniaturas de vídeo preenchem o espaço.
    private var cover: some View {
        ZStack {
            if let image = nowPlaying.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .blur(radius: 18).opacity(0.55)
                Image(nsImage: image).resizable()
                    .aspectRatio(contentMode: image.size.width / max(image.size.height, 1) > 1.3 ? .fill : .fit)
            } else {
                LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom)
                if let icon = nowPlaying.sourceApp?.icon {
                    Image(nsImage: icon).resizable().frame(width: 40, height: 40)
                } else {
                    Image(systemName: "music.note").font(.system(size: 30)).foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .frame(width: 136, height: 77) // 16:9, centralizada em cima do resto
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.3), value: nowPlaying.artwork)
    }
}

private struct ProgressRow: View {
    @ObservedObject var nowPlaying: NowPlaying

    var body: some View {
        if (nowPlaying.track?.duration ?? 0) <= 0 {
            // Transmissão ao vivo (ou sem duração): não tem barra de tempo.
            HStack(spacing: 5) {
                Circle().fill(Color.red).frame(width: 6, height: 6)
                Text("AO VIVO").font(.system(size: 10, weight: .bold))
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.red.opacity(0.22)))
            .foregroundStyle(.white)
        } else {
            timeline
        }
    }

    private var timeline: some View {
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
        HStack(spacing: 10) {
            GlassButton(symbol: "backward.fill", size: 13, diameter: 32) { nowPlaying.previous() }
            GlassButton(symbol: nowPlaying.isPlaying ? "pause.fill" : "play.fill", size: 17, diameter: 40, prominent: true) {
                nowPlaying.playPause()
            }
            GlassButton(symbol: "forward.fill", size: 13, diameter: 32) { nowPlaying.next() }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Botão redondo de vidro (Liquid Glass no macOS 26 ou mais novo; vidro fosco nos anteriores).
private struct GlassButton: View {
    let symbol: String
    let size: CGFloat
    let diameter: CGFloat
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .modifier(GlassCircle(prominent: prominent))
    }
}

struct GlassCircle: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(prominent ? .regular.tint(.white.opacity(0.12)).interactive() : .regular.interactive(), in: Circle())
        } else {
            content.background(Circle().fill(.ultraThinMaterial)).overlay(Circle().strokeBorder(.white.opacity(0.15)))
        }
    }
}

struct Artwork: View {
    let image: NSImage?
    let size: CGFloat
    let corner: CGFloat
    var fallback: NSImage? = nil

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else if let fallback {
                ZStack {
                    LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom)
                    Image(nsImage: fallback).resizable().frame(width: size * 0.6, height: size * 0.6)
                }
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
