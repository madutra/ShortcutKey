import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NotchView: View {
    @ObservedObject var model: NotchModel

    static var hasLiquidGlass: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    private var topRadius: CGFloat { model.isOpen ? 12 : 6 }
    /// Vidro no notch aberto e na ilha de volume/brilho; preto quando só "veste" o notch.
    private var isGlass: Bool {
        if model.isOpen { return true }
        if case .level = model.flash { return true }
        if case .device = model.flash { return true }
        if let alert = model.alert, alert.kind == .notification || alert.kind == .call { return true }
        return false
    }
    private var radius: CGFloat { model.isOpen ? 28 : model.notchSize.height / 2.4 }
    /// As pontinhas de cima ficam para fora do tamanho pedido, como as do notch de verdade.
    private var size: CGSize {
        let base = model.isOpen ? model.openSize : model.closedSize
        return CGSize(width: base.width + 2 * topRadius, height: base.height)
    }

    var body: some View {
        // Notch e barra das abas ficam fora de um GlassEffectContainer de propósito: dentro dele o
        // vidro do notch é desenhado por cima do conteúdo e esconde tudo.
        stack
            .frame(width: NotchController.canvasSize.width, height: NotchController.canvasSize.height)
            .environment(\.colorScheme, .dark)
    }

    private var stack: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // Fechado (ou sem Liquid Glass): preto, para se misturar com o notch de verdade.
                NotchShape(bottomRadius: radius, topRadius: topRadius)
                    .fill(Color.black)
                    .opacity(isGlass && Self.hasLiquidGlass ? 0 : 1)
                if isGlass {
                    GlassPanelBackground(notchHeight: model.notchSize.height, native: Self.hasLiquidGlass)
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
            // Liquid Glass de verdade (macOS 26+) por trás do conteúdo, fora do recorte para a borda
            // de luz do sistema aparecer inteira. Nos sistemas mais antigos, vidro fosco + brilho feito à mão.
            .background {
                if isGlass {
                    NativeGlass(shape: NotchShape(bottomRadius: radius, topRadius: topRadius))
                        .transition(.opacity)
                }
            }
            .overlay(
                NotchShape(bottomRadius: radius, topRadius: topRadius)
                    .stroke(LinearGradient(colors: [.clear, .white.opacity(0.05), .white.opacity(0.12)],
                                           startPoint: .top, endPoint: .bottom), lineWidth: 3)
                    .blur(radius: 3)
                    .clipShape(NotchShape(bottomRadius: radius, topRadius: topRadius))
                    .opacity(isGlass && !Self.hasLiquidGlass ? 1 : 0)
            )
            // Sombra larga e difusa: o vidro "flutua" e se mistura com o que está atrás.
            .shadow(color: .black.opacity(isGlass ? 0.30 : 0), radius: 26, y: 12)
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
        if case .device(let name, let symbol, let connected, let battery) = model.flash {
            DeviceBanner(notchHeight: model.notchSize.height, name: name, symbol: symbol, connected: connected, battery: battery)
        } else if case .level(let kind, let value, let muted) = model.flash {
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

/// Fone, teclado ou mouse Bluetooth conectando/desconectando (como os AirPods no iPhone).
private struct DeviceBanner: View {
    let notchHeight: CGFloat
    let name: String
    let symbol: String
    let connected: Bool
    let battery: Int?

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: notchHeight)
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 38, height: 38)
                    .modifier(GlassCircle(prominent: false))
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(connected ? "Conectado" : "Desconectado")
                        .font(.system(size: 11)).foregroundStyle(connected ? Color.green : .white.opacity(0.55))
                }
                Spacer(minLength: 6)
                if let battery { BatteryRing(level: battery) }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .frame(maxHeight: .infinity)
        }
    }
}

/// Anel de bateria, como o widget de Baterias do macOS.
private struct BatteryRing: View {
    let level: Int

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.18), lineWidth: 3)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(level, 0), 100)) / 100)
                .stroke(level <= 20 ? Color.red : .green, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(level)").font(.system(size: 10, weight: .semibold)).monospacedDigit()
        }
        .frame(width: 32, height: 32)
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

    private var lowSymbol: String {
        switch kind {
        case .brightness: return "sun.min.fill"
        case .volume: return muted ? "speaker.slash.fill" : "speaker.fill"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: model.notchSize.height)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(kind == .volume ? "Som" : "Tela").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if kind == .volume, let name = SystemLevels.outputName {
                        Text(name).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                    }
                }
                HStack(spacing: 10) {
                    // Ícone baixo à esquerda (no volume, clicar liga/desliga o mudo) e alto à direita.
                    Button { if kind == .volume { model.toggleMute() } } label: {
                        Image(systemName: lowSymbol)
                            .font(.system(size: 13, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 18, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(kind == .volume ? (muted ? "Tirar do mudo" : "Deixar mudo") : "")

                    GlassKnobSlider(value: shown, knobVisible: model.levelKnobVisible) { model.setLevel(kind, to: $0) }
                        .frame(height: 26)

                    Image(systemName: kind == .volume ? "speaker.wave.3.fill" : "sun.max.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 22)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 12)
            .frame(maxHeight: .infinity)
        }
    }
}

/// O controle deslizante do macOS 26: trilho fino, parte cheia branca e um botão de vidro que se arrasta.
private struct GlassKnobSlider: View {
    let value: Float
    var knobVisible = true
    let onChange: (Float) -> Void
    /// Enquanto o dedo/mouse segura a barra, o botão fica visível mesmo parado.
    @GestureState private var dragging = false

    private let knob = CGSize(width: 38, height: 24)

    var body: some View {
        GeometryReader { geo in
            let travel = max(geo.size.width - knob.width, 1)
            let x = travel * CGFloat(value)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22)).frame(height: 6)
                Capsule().fill(.white).frame(width: x + knob.width / 2, height: 6)
                // Botão de vidro transparente, como uma lente em cima da barra: dá para ver a barra por baixo.
                Color.clear
                    .frame(width: knob.width, height: knob.height)
                    .modifier(ClearGlassKnob())
                    .scaleEffect(knobVisible || dragging ? 1 : 0.6)
                    .opacity(knobVisible || dragging ? 1 : 0)
                    .offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .updating($dragging) { _, state, _ in state = true }
                .onChanged { drag in
                    let position = (drag.location.x - knob.width / 2) / travel
                    onChange(Float(min(max(position, 0), 1)))
                })
            .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.86), value: value)
            .animation(.easeOut(duration: 0.2), value: dragging)
        }
    }
}

/// Botão do controle como uma lente de vidro quase transparente: a barra continua visível por baixo,
/// com borda de luz e um reflexo no topo. (O vidro do sistema aqui ficava escuro demais, porque
/// "copia" o preto do notch atrás dele.)
private struct ClearGlassKnob: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Capsule().fill(.white.opacity(0.07)))
            .overlay(
                // Reflexo na metade de cima, como luz batendo no vidro.
                Capsule()
                    .fill(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0)], startPoint: .top, endPoint: .center))
                    .padding(1.5)
            )
            .overlay(Capsule().strokeBorder(
                LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0.18), .white.opacity(0.45)],
                               startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.2))
            .shadow(color: .black.opacity(0.22), radius: 5, y: 2)
    }
}

private struct GlassCapsule: ViewModifier {
    var interactive = false

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: Capsule())
        } else {
            content.background(Capsule().fill(.ultraThinMaterial)).overlay(Capsule().strokeBorder(.white.opacity(0.25)))
        }
    }
}

// MARK: - Aberto

/// Fundo de vidro do notch aberto (como o NotchNook): desfoca o que está atrás da janela, escurece um
/// pouco para o texto ler bem e fica preto em cima, onde encosta no notch de verdade.
private struct GlassPanelBackground: View {
    let notchHeight: CGFloat
    /// Com o Liquid Glass nativo, aqui só fica o escurecimento para o texto ler bem e o preto do topo.
    let native: Bool

    var body: some View {
        ZStack {
            if !native { VisualEffectBlur() }
            LinearGradient(colors: [.black.opacity(native ? 0.35 : 0.55), .black.opacity(native ? 0.12 : 0.30)],
                           startPoint: .top, endPoint: .bottom)
            if !native {
                LinearGradient(colors: [.white.opacity(0.06), .clear], startPoint: .top, endPoint: .center)
            }
            // Preto em cima, onde encosta no notch de verdade (sem "costura").
            VStack(spacing: 0) {
                LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: notchHeight + 14)
                Spacer()
            }
        }
    }
}

/// O material Liquid Glass do sistema numa forma qualquer (macOS 26+).
private struct NativeGlass<S: Shape>: View {
    let shape: S

    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular.tint(.black.opacity(0.25)), in: shape)
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

private struct PageBarGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(.black.opacity(0.2)).interactive(), in: Capsule())
        } else {
            content
                .background(ZStack { VisualEffectBlur(); Color.black.opacity(0.35) }.clipShape(Capsule()))
                .overlay(Capsule().stroke(.white.opacity(0.10), lineWidth: 2).blur(radius: 2).clipShape(Capsule()))
        }
    }
}

/// Barra das abas, flutuando embaixo do notch aberto (cápsula de vidro).
private struct PageBar: View {
    @ObservedObject var model: NotchModel
    @Namespace private var pill

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
                    .background {
                        // A cápsula da aba escolhida desliza de uma aba para a outra.
                        if selected { Capsule().fill(.white.opacity(0.16)).matchedGeometryEffect(id: "pill", in: pill) }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(selected ? 1 : 0.6))
                .help(page.title)
            }
        }
        .padding(4)
        .modifier(PageBarGlass())
        .shadow(color: .black.opacity(0.30), radius: 18, y: 8)
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
        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                GlassButton(symbol: "backward.fill", size: 13, diameter: 32) { nowPlaying.previous() }
                GlassButton(symbol: nowPlaying.isPlaying ? "pause.fill" : "play.fill", size: 17, diameter: 40, prominent: true) {
                    nowPlaying.playPause()
                }
                GlassButton(symbol: "forward.fill", size: 13, diameter: 32) { nowPlaying.next() }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Agrupa peças de vidro vizinhas (GlassEffectContainer): renderizam juntas e se fundem quando se aproximam.
struct GlassGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
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
