import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let brazil = Locale(identifier: "pt_BR")

// MARK: - Calendário (aba Início)

struct CalendarPanel: View {
    @ObservedObject var calendar: NotchCalendar
    @Namespace private var selection

    private static let month: DateFormatter = {
        let f = DateFormatter(); f.locale = brazil; f.setLocalizedDateFormatFromTemplate("MMMMyyyy"); return f
    }()

    private static func capitalizedFirst(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }

    private var isTodaySelected: Bool { Calendar.current.isDateInToday(calendar.selectedDay) }
    private var monthTitle: String { Self.capitalizedFirst(Self.month.string(from: calendar.selectedDay)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // O mês desliza quando a seleção passa para outro mês.
                Text(monthTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .id(monthTitle)
                    .transition(.push(from: calendar.direction > 0 ? .bottom : .top))
                Spacer()
                if !isTodaySelected {
                    Button { calendar.select(Date()) } label: {
                        Label("Hoje", systemImage: calendar.direction > 0 ? "arrow.uturn.backward" : "arrow.uturn.forward")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain).font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(.white.opacity(0.12)))
                    .foregroundStyle(.white.opacity(0.85))
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                Button { calendar.openCalendarApp() } label: {
                    Image(systemName: "calendar").font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).help("Abrir o Calendário")
            }
            .clipped()

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 2) {
                        ForEach(calendar.days, id: \.self) { day in
                            DayCell(day: day,
                                    selected: Calendar.current.isDate(day, inSameDayAs: calendar.selectedDay),
                                    hasEvents: calendar.daysWithEvents.contains(day),
                                    selection: selection)
                                .id(day)
                                .onTapGesture { calendar.select(day) }
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 4)
                }
                .scrollTargetBehavior(.viewAligned)
                // Bordas que somem aos poucos: dá a ideia de que a faixa continua dos lados.
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08),
                                             .init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
                .onAppear { proxy.scrollTo(calendar.selectedDay, anchor: .center) }
                .onChange(of: calendar.selectedDay) { _, day in
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { proxy.scrollTo(day, anchor: .center) }
                }
            }
            .frame(height: 44)

            ZStack(alignment: .topLeading) {
                events
                    .id(calendar.selectedDay)
                    .transition(.asymmetric(
                        insertion: .move(edge: calendar.direction > 0 ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: calendar.direction > 0 ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var events: some View {
        switch calendar.access {
        case .notDetermined, .denied:
            VStack(alignment: .leading, spacing: 6) {
                Text(calendar.access == .denied ? "Sem acesso ao Calendário." : "Veja seus eventos aqui.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                Button(calendar.access == .denied ? "Abrir Ajustes" : "Mostrar meus eventos") { calendar.requestAccess() }
                    .controlSize(.small)
            }
            .padding(.top, 4)
        case .granted:
            if calendar.events.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").foregroundStyle(.white.opacity(0.4))
                    Text("Nenhum evento \(isTodaySelected ? "hoje" : "neste dia")")
                }
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                .padding(.top, 6)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(calendar.events) { EventRow(event: $0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct DayCell: View {
    let day: Date
    let selected: Bool
    let hasEvents: Bool
    let selection: Namespace.ID

    private static let weekday: DateFormatter = {
        let f = DateFormatter(); f.locale = brazil; f.dateFormat = "EEEEE"; return f
    }()

    var body: some View {
        let today = Calendar.current.isDateInToday(day)
        VStack(spacing: 2) {
            Text(Self.weekday.string(from: day).uppercased())
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(selected ? 0.95 : 0.45))
            ZStack {
                if selected {
                    // A bolinha da seleção desliza de um dia para o outro.
                    Circle()
                        .fill(today ? Color.red : .white)
                        .matchedGeometryEffect(id: "selected-day", in: selection)
                } else if today {
                    Circle().strokeBorder(Color.red.opacity(0.8), lineWidth: 1.5)
                }
                Text("\(Calendar.current.component(.day, from: day))")
                    .font(.system(size: 13, weight: selected || today ? .bold : .regular))
                    .foregroundStyle(selected ? (today ? .white : .black) : today ? .red : .white)
            }
            .frame(width: 26, height: 26)
            .scaleEffect(selected ? 1.08 : 1)
            Circle()
                .fill(selected ? Color.white : .white.opacity(0.5))
                .frame(width: 4, height: 4)
                .opacity(hasEvents ? 1 : 0)
        }
        .frame(width: 32)
        .contentShape(Rectangle())
    }
}

private struct EventRow: View {
    let event: NotchCalendar.Event

    private static let time: DateFormatter = {
        let f = DateFormatter(); f.locale = brazil; f.dateFormat = "HH:mm"; return f
    }()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let isPast = !event.isAllDay && event.end < now
            let isNow = !event.isAllDay && event.start <= now && now < event.end
            let minutes = Int(event.start.timeIntervalSince(now) / 60)
            let color = Color(nsColor: event.color)
            HStack(alignment: .center, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(event.isAllDay ? "Dia inteiro"
                         : "\(Self.time.string(from: event.start)) – \(Self.time.string(from: event.end))"
                            + (event.location.map { " · \($0)" } ?? ""))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if isNow {
                    Badge(text: "agora", color: color, pulsing: true)
                } else if !event.isAllDay, minutes >= 0, minutes < 60 {
                    Badge(text: minutes == 0 ? "já já" : "em \(minutes) min", color: color, pulsing: false)
                }
            }
            .padding(.vertical, 3).padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isNow ? color.opacity(0.16) : .clear))
            .opacity(isPast ? 0.45 : 1)
        }
    }
}

private struct Badge: View {
    let text: String
    let color: Color
    let pulsing: Bool

    var body: some View {
        HStack(spacing: 4) {
            if pulsing {
                TimelineView(.animation(minimumInterval: 1 / 15)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    Circle().fill(color).frame(width: 5, height: 5)
                        .opacity(0.55 + 0.45 * (sin(t * 4) + 1) / 2)
                }
            }
            Text(text)
        }
        .font(.system(size: 9, weight: .semibold))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.25)))
        .foregroundStyle(.white)
    }
}

// MARK: - Arquivos

struct FilesPage: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var shelf: NotchShelf
    private let anchor = ViewAnchor()

    var body: some View {
        HStack(spacing: 12) {
            shelfBox
            VStack(spacing: 8) {
                DropTile(symbol: "dot.radiowaves.up.forward", title: "AirDrop", isTargeted: $shelf.airDropTargeted) { urls in
                    shelf.airDrop(urls)
                }
                DropTile(symbol: "square.and.arrow.up", title: "Compartilhar", isTargeted: $shelf.shareTargeted) { urls in
                    shelf.add(urls)
                    share(urls)
                }
            }
            .frame(width: 120)
        }
        .background(AnchorView(anchor: anchor))
    }

    private var shelfBox: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: shelf.items.isEmpty || model.isDropTargeted ? [5, 4] : []))
                .foregroundStyle(model.isDropTargeted ? Color.accentColor : .white.opacity(0.2))
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(model.isDropTargeted ? Color.accentColor.opacity(0.15) : .white.opacity(0.04)))

            if shelf.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 22))
                    Text("Arraste arquivos para cá para guardar").font(.system(size: 12))
                }
                .foregroundStyle(.white.opacity(0.55))
            } else {
                VStack(spacing: 4) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(shelf.items, id: \.self) { ShelfItem(url: $0, shelf: shelf) }
                        }
                        .padding(.horizontal, 10)
                    }
                    HStack(spacing: 12) {
                        Text("\(shelf.items.count) arquivo(s)")
                        Spacer()
                        Button("Compartilhar") { share(shelf.items) }
                        Button("AirDrop") { shelf.airDrop(shelf.items) }
                        Button("Limpar") { shelf.clear() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.horizontal, 12)
                }
                .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Menu de compartilhar do macOS (Mensagens, Mail, AirDrop, Notas…), aberto embaixo do notch.
    private func share(_ urls: [URL]) {
        guard !urls.isEmpty, let view = anchor.view else { return }
        model.isPinned = true
        let picker = NSSharingServicePicker(items: urls)
        let delegate = SharePickerDelegate { [weak model] in model?.isPinned = false }
        picker.delegate = delegate
        objc_setAssociatedObject(picker, &SharePickerDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN)
        let rect = CGRect(x: view.bounds.maxX - 120, y: view.bounds.minY, width: 120, height: 20)
        picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
    }
}

private struct DropTile: View {
    let symbol: String
    let title: String
    @Binding var isTargeted: Bool
    let onDrop: ([URL]) -> Void

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 18))
            Text(title).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.white.opacity(isTargeted ? 1 : 0.7))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(isTargeted ? Color.accentColor.opacity(0.35) : .white.opacity(0.07)))
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            loadFileURLs(providers, completion: onDrop)
            return true
        }
        .help("Solte arquivos aqui")
    }
}

private final class SharePickerDelegate: NSObject, NSSharingServicePickerDelegate {
    static var key = 0
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

    func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        onFinish()
        if service != nil { NSApp.activate(ignoringOtherApps: true) } // a janela do serviço (ex.: Mail) vem para a frente
    }
}

/// Guarda a NSView por trás de uma view SwiftUI, para menus do AppKit saberem onde aparecer.
final class ViewAnchor { weak var view: NSView? }

private struct AnchorView: NSViewRepresentable {
    let anchor: ViewAnchor
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}

// MARK: - Conexões

struct ConnectivityPage: View {
    @ObservedObject var connectivity: Connectivity

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 8) {
                wifiCard
                internetCard
            }
            .frame(width: 250)
            bluetoothCard
        }
        .foregroundStyle(.white)
    }

    private var wifiCard: some View {
        Card {
            HStack(spacing: 10) {
                ToggleCircle(symbol: connectivity.wifiOn ? "wifi" : "wifi.slash", isOn: connectivity.wifiOn) {
                    connectivity.toggleWifi()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wi-Fi").font(.system(size: 12, weight: .semibold))
                    Group {
                        if !connectivity.wifiOn {
                            Text("Desligado")
                        } else if let name = connectivity.wifiName {
                            Text(name)
                        } else if connectivity.wifiSignal != nil {
                            if connectivity.needsLocationForWifiName {
                                Button("Mostrar nome da rede") { connectivity.requestLocation() }
                                    .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                            } else {
                                Text("Conectado")
                            }
                        } else {
                            Text("Sem rede")
                        }
                    }
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let rssi = connectivity.wifiSignal { SignalBars(rssi: rssi) }
                settingsButton { connectivity.openWifiSettings() }
            }
        }
    }

    private var internetCard: some View {
        Card {
            HStack(spacing: 10) {
                Image(systemName: connectivity.internetOK ? "globe" : "exclamationmark.triangle")
                    .font(.system(size: 13))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(connectivity.internetOK ? Color.green.opacity(0.35) : Color.orange.opacity(0.4)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(connectivity.internet).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(connectivity.ipAddress.map { "IP \($0)" } ?? "Sem endereço IP")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
                settingsButton { connectivity.openNetworkSettings() }
            }
        }
    }

    private var bluetoothCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    ToggleCircle(symbol: "dot.radiowaves.left.and.right", isOn: connectivity.bluetoothOn) {
                        connectivity.toggleBluetooth()
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bluetooth").font(.system(size: 12, weight: .semibold))
                        let connected = connectivity.devices.filter(\.isConnected).count
                        Text(!connectivity.bluetoothOn ? "Desligado" : connected == 0 ? "Nenhum conectado" : "\(connected) conectado(s)")
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer()
                    settingsButton { connectivity.openBluetoothSettings() }
                }
                if connectivity.bluetoothOn {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 2) {
                            ForEach(connectivity.devices) { device in
                                DeviceRow(device: device, busy: connectivity.busyDevice == device.id) {
                                    connectivity.toggle(device)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func settingsButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                .frame(width: 18, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.45)).help("Abrir nos Ajustes do Sistema")
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.07)))
    }
}

private struct ToggleCircle: View {
    let symbol: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(isOn ? Color.accentColor : .white.opacity(0.15)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .help(isOn ? "Desligar" : "Ligar")
    }
}

private struct SignalBars: View {
    let rssi: Int
    private var level: Int { rssi >= -55 ? 3 : rssi >= -67 ? 2 : rssi >= -78 ? 1 : 0 }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(.white.opacity(i < level ? 0.9 : 0.25))
                    .frame(width: 3, height: CGFloat(5 + i * 3))
            }
        }
        .help("Sinal \(rssi) dBm")
    }
}

private struct DeviceRow: View {
    let device: Connectivity.BluetoothDevice
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: device.symbol)
                    .font(.system(size: 11))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(device.isConnected ? Color.accentColor : .white.opacity(0.12)))
                Text(device.name).font(.system(size: 11)).lineLimit(1)
                Spacer()
                if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(device.isConnected ? "Desconectar" : "Conectar")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }
}
