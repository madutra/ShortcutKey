import AppKit
import SwiftUI

struct MouseTab: View {
    @EnvironmentObject private var store: SettingsStore
    @ObservedObject private var dpi = MouseDPI.shared
    @StateObject private var detector = MouseButtonDetector()

    var body: some View {
        Form {
            buttonsSection
            dpiSection
        }
        .formStyle(.grouped)
        .onAppear { dpi.refresh() }
    }

    // MARK: Botões

    private var buttonNumbers: [Int] {
        let configured = store.settings.mouse.buttons.keys.compactMap(Int.init)
        return Array(Set([2, 3, 4] + configured)).sorted()
    }

    private func binding(for number: Int) -> Binding<ActionBinding> {
        Binding(
            get: { store.settings.mouse.binding(forButton: number) },
            set: { store.settings.mouse.buttons[String(number)] = $0 }
        )
    }

    private var buttonsSection: some View {
        Section {
            ForEach(buttonNumbers, id: \.self) { number in
                ActionPicker(title: MouseSettings.name(ofButton: number), binding: binding(for: number))
            }
            HStack {
                Button(detector.isDetecting ? "Aperte um botão do mouse aqui na janela…" : "Detectar outro botão") {
                    detector.isDetecting ? detector.stop() : detector.start { number in
                        if store.settings.mouse.buttons[String(number)] == nil, ![2, 3, 4].contains(number) {
                            store.settings.mouse.buttons[String(number)] = ActionBinding()
                        }
                    }
                }
                if let last = detector.lastDetected {
                    Text("Último detectado: \(MouseSettings.name(ofButton: last))").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Botões")
        } footer: {
            Text("\"Nenhuma\" mantém o que o botão já faz. Funciona com qualquer mouse. Botões que o próprio mouse trata por dentro (como DPI + / − e o shift / precisão do G502) só chegam ao Mac com os perfis da memória do mouse desligados (abaixo); depois disso, use \"Detectar outro botão\" e aperte o botão.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: DPI

    @ViewBuilder
    private var dpiSection: some View {
        Section {
            switch dpi.state {
            case .searching:
                Text("Procurando o mouse…").foregroundStyle(.secondary)
            case .needsPermission:
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Para mudar o DPI, o ShortcutKey precisa da permissão de Monitoramento de Entrada.")
                        .font(.callout)
                    Spacer()
                    Button("Permitir") { dpi.requestPermission() }
                    Button("Tentar de novo") { dpi.refresh() }
                }
            case .noDevice:
                HStack {
                    Text("Nenhum mouse Logitech com DPI ajustável encontrado.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Procurar de novo") { dpi.reconnect() }
                }
            case .busy(let name):
                VStack(alignment: .leading, spacing: 6) {
                    Label("Outro app está usando o \(name) com exclusividade.", systemImage: "lock.fill")
                    Text("Normalmente é o Karabiner-Elements. Abra o Karabiner-Elements › Devices e desligue \"Modify events\" no \(name); depois clique em Procurar de novo.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Procurar de novo") { dpi.reconnect() }
                }
            case .unsupported(let name):
                Text("O \(name) não permite mudar o DPI pelo computador.").foregroundStyle(.secondary)
            case .ready:
                readyRows
            }
        } header: {
            Text("DPI do sensor")
        } footer: {
            Text("Muda o DPI dentro do próprio mouse (mouses Logitech com HID++, como o G502). O valor fica guardado e é aplicado de novo quando o mouse é reconectado ou o Mac acorda.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var readyRows: some View {
        LabeledContent(dpi.deviceName) {
            HStack {
                Text(dpi.currentDPI.map { "\($0) DPI agora" } ?? "—").foregroundStyle(.secondary)
                Button("Reconectar") { dpi.reconnect() }.controlSize(.small)
            }
        }

        if let range = dpi.dpiRange {
            if dpi.dpiValues.isEmpty {
                HStack {
                    Slider(value: Binding(
                        get: { Double(dpi.draftDPI) },
                        set: { dpi.draftDPI = Int($0) }
                    ), in: Double(range.lowerBound)...Double(range.upperBound), step: Double(max(dpi.dpiStep, 1)))
                    Text("\(dpi.draftDPI)").monospacedDigit().frame(width: 56, alignment: .trailing)
                    Button("Aplicar") { dpi.setDPI(dpi.draftDPI) }
                        .disabled(dpi.draftDPI == dpi.currentDPI)
                }
                HStack(spacing: 6) {
                    ForEach([400, 800, 1200, 1600, 2400, 3200].filter(range.contains), id: \.self) { value in
                        Button("\(value)") { dpi.draftDPI = value; dpi.setDPI(value) }
                            .controlSize(.small)
                    }
                }
            } else {
                Picker("DPI", selection: Binding(
                    get: { dpi.currentDPI ?? dpi.dpiValues[0] },
                    set: { dpi.setDPI($0) }
                )) {
                    ForEach(dpi.dpiValues, id: \.self) { Text("\($0)").tag($0) }
                }
            }
        }

        if let onboard = dpi.onboardProfilesActive {
            Toggle("Perfis da memória do mouse", isOn: Binding(
                get: { onboard },
                set: { dpi.setOnboardProfiles($0) }
            ))
            Text(onboard
                 ? "Ligados: o mouse usa os perfis e botões de DPI gravados nele e pode ignorar o DPI escolhido aqui."
                 : "Desligados: o ShortcutKey controla o DPI, e os botões de DPI e shift viram botões comuns que você pode configurar acima.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if let message = dpi.message {
            Text(message).font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// Descobre o número de um botão do mouse: o próximo botão extra apertado dentro da janela de configurações.
final class MouseButtonDetector: ObservableObject {
    @Published private(set) var isDetecting = false
    @Published private(set) var lastDetected: Int?
    private var monitor: Any?

    func start(onDetect: @escaping (Int) -> Void) {
        isDetecting = true
        EventTapController.shared.isPaused = true // deixa o clique chegar aqui, mesmo se já tiver ação
        monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            self?.lastDetected = event.buttonNumber
            onDetect(event.buttonNumber)
            self?.stop()
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if isDetecting { isDetecting = false }
        EventTapController.shared.isPaused = false
    }
}
