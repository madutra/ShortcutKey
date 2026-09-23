import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("Geral", systemImage: "gearshape") }
            WindowsTab().tabItem { Label("Janelas", systemImage: "macwindow") }
            SwitcherTab().tabItem { Label("Alternador", systemImage: "rectangle.on.rectangle") }
            TrackpadTab().tabItem { Label("Trackpad", systemImage: "hand.draw") }
            KeyboardTab().tabItem { Label("Teclado", systemImage: "keyboard") }
            ScreenshotTab().tabItem { Label("Print", systemImage: "camera.viewfinder") }
        }
        .frame(width: 700, height: 640)
    }
}

// MARK: - Geral

private struct GeneralTab: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var store: SettingsStore

    var body: some View {
        Form {
            Section("Permissões") {
                HStack {
                    Image(systemName: controller.isTrusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(controller.isTrusted ? .green : .orange)
                    Text(controller.isTrusted ? "Acessibilidade permitida" : "O ShortcutKey precisa de permissão de Acessibilidade")
                    Spacer()
                    if !controller.isTrusted {
                        Button("Abrir Ajustes") {
                            AX.promptForPermission()
                            AX.openAccessibilitySettings()
                        }
                    }
                }
            }

            Section("Geral") {
                Toggle("Abrir ao iniciar sessão", isOn: Binding(
                    get: { controller.launchAtLogin },
                    set: { controller.setLaunchAtLogin($0) }
                ))
                Toggle("Segurar ⌥ Option ao clicar usa o comportamento padrão dos botões", isOn: $store.settings.optionKeyBypass)
            }

            Section {
                Text("ShortcutKey é gratuito e de código aberto.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Janelas

private struct WindowsTab: View {
    @EnvironmentObject private var store: SettingsStore

    var body: some View {
        Form {
            Section("Botões da janela") {
                Picker(selection: $store.settings.closeButton) {
                    ForEach(CloseButtonBehavior.allCases) { Text($0.title).tag($0) }
                } label: {
                    Label("Vermelho", systemImage: "circle.fill").foregroundStyle(.red)
                }
                Picker(selection: $store.settings.minimizeButton) {
                    ForEach(MinimizeButtonBehavior.allCases) { Text($0.title).tag($0) }
                } label: {
                    Label("Amarelo", systemImage: "circle.fill").foregroundStyle(.yellow)
                }
                Picker(selection: $store.settings.zoomButton) {
                    ForEach(ZoomButtonBehavior.allCases) { Text($0.title).tag($0) }
                } label: {
                    Label("Verde", systemImage: "circle.fill").foregroundStyle(.green)
                }
                Toggle("⌘W também encerra o app ao fechar a última janela", isOn: $store.settings.quitOnCommandW)
            }

            Section {
                ForEach(store.settings.excludedBundleIDs, id: \.self) { bundleID in
                    HStack {
                        AppLabel(bundleID: bundleID)
                        Spacer()
                        Button(role: .destructive) {
                            store.settings.excludedBundleIDs.removeAll { $0 == bundleID }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Menu("Adicionar app aberto…") {
                    ForEach(runningApps, id: \.bundleIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "?") {
                            if let id = app.bundleIdentifier { store.settings.excludedBundleIDs.append(id) }
                        }
                    }
                }
            } header: {
                Text("Exceções")
            } footer: {
                Text("Nesses apps os botões da janela mantêm o comportamento padrão do macOS.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .filter { !store.settings.excludedBundleIDs.contains($0.bundleIdentifier!) }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }
}

struct AppLabel: View {
    let bundleID: String

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        HStack {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 18, height: 18)
            }
            Text(url.map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID)
        }
    }
}

// MARK: - Trackpad

private struct TrackpadTab: View {
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var controller: AppController

    var body: some View {
        Form {
            Section {
                Toggle("Ativar gestos do trackpad", isOn: $store.settings.gesturesEnabled)
                HStack {
                    Text(trackpadStatus).foregroundStyle(.secondary)
                    Spacer()
                    Text("Último gesto: \(controller.lastGesture.map(gestureName) ?? "—")")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }

            Section {
                Label {
                    Text("Se o macOS já usa o mesmo gesto (ex.: arrastar com 4 dedos para o Mission Control ou para trocar de mesa), os dois vão acontecer juntos. Desative o gesto do sistema em **Ajustes › Trackpad › Mais Gestos** (e \"Arrastar com três dedos\" em Acessibilidade, se estiver ligado) para usar só o do ShortcutKey.")
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.callout)
                Button("Abrir ajustes do Trackpad") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .disabled(!store.settings.gesturesEnabled)

            Section {
                LabeledContent("Alternar entre apps") {
                    Text(store.settings.appSwitcher.title).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Configure na aba Alternador.").foregroundStyle(.secondary)
            }

            gestureSection("Arrastar com 4 dedos", Gesture.swipes4)
            gestureSection("Arrastar com 3 dedos", Gesture.swipes3)
            gestureSection("Toques", Gesture.taps)
        }
        .formStyle(.grouped)
    }

    private func gestureSection(_ title: String, _ gestures: [Gesture]) -> some View {
        Section(title) {
            ForEach(gestures) { gesture in
                if store.settings.isReservedByAppSwitcher(gesture) {
                    LabeledContent(gesture.title) {
                        Text("Alternar entre apps").foregroundStyle(.secondary)
                    }
                } else {
                    ActionPicker(title: gesture.title, binding: store.gestureBinding(gesture))
                }
            }
        }
        .disabled(!store.settings.gesturesEnabled)
    }

    private var trackpadStatus: String {
        switch controller.trackpadCount {
        case ..<0: "Leitura do trackpad indisponível neste macOS"
        case 0: "Nenhum trackpad encontrado"
        case 1: "1 trackpad conectado"
        default: "\(controller.trackpadCount) trackpads conectados"
        }
    }

    private func gestureName(_ gesture: Gesture) -> String {
        if Gesture.swipes4.contains(gesture) { return "4 dedos, \(gesture.title.lowercased())" }
        if Gesture.swipes3.contains(gesture) { return "3 dedos, \(gesture.title.lowercased())" }
        return gesture.title
    }
}

// MARK: - Teclado

private struct KeyboardTab: View {
    @EnvironmentObject private var store: SettingsStore

    var body: some View {
        Form {
            Section {
                if store.settings.hotkeys.isEmpty {
                    Text("Nenhum atalho ainda.").foregroundStyle(.secondary)
                }
                ForEach($store.settings.hotkeys) { $hotkey in
                    HStack(alignment: .top) {
                        KeyRecorder(combo: $hotkey.trigger, placeholder: "Gravar atalho")
                            .frame(width: 140)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary).padding(.top, 4)
                        ActionPicker(title: nil, binding: $hotkey.binding)
                        Button(role: .destructive) {
                            store.settings.hotkeys.removeAll { $0.id == hotkey.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .padding(.top, 4)
                    }
                }
                Button("Adicionar atalho") {
                    store.settings.hotkeys.append(HotkeyBinding())
                }
            } header: {
                Text("Atalhos globais")
            } footer: {
                Text("Funcionam em qualquer app. Use \"Atalho de teclado personalizado\" para remapear uma combinação em outra.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Print

private struct ScreenshotTab: View {
    @EnvironmentObject private var store: SettingsStore
    @StateObject private var permission = ScreenRecordingPermission()

    var body: some View {
        Form {
            Section {
                Toggle("Tirar print com ⌘⇧S", isOn: $store.settings.screenshot.enabled)
                Group {
                    Toggle("Copiar o print para a área de transferência", isOn: $store.settings.screenshot.copyToClipboard)
                    Toggle("Também salvar o arquivo na pasta de capturas (Mesa)", isOn: $store.settings.screenshot.saveToDesktop)
                }
                .disabled(!store.settings.screenshot.enabled)
            } footer: {
                Text("Arraste para escolher a área (Espaço captura uma janela inteira, Esc cancela). O print vai na hora para a área de transferência e aparece uma miniatura no canto da tela: clique nela para abrir na Pré-Visualização, ou arraste para soltar o arquivo em outro app. Em alguns apps ⌘⇧S é \"Salvar como…\"; com esta opção ligada, o print tem prioridade.")
                    .foregroundStyle(.secondary)
            }

            if !permission.granted {
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("O print precisa da permissão de Gravação de Tela.").font(.callout)
                        Spacer()
                        Button("Permitir") { permission.request() }
                        Button("Reiniciar app") { Thumbnails.relaunchApp() }
                    }
                }
            }

            Section {
                Button("Tirar print agora") { ScreenshotController.shared.capture() }
                    .disabled(!store.settings.screenshot.enabled)
            } footer: {
                Text("A pasta de capturas é a mesma do macOS (⌘⇧5 › Opções).")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Componentes

/// Menu para escolher uma ação (e o atalho, se for personalizado).
struct ActionPicker: View {
    let title: String?
    @Binding var binding: ActionBinding

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Picker(selection: $binding.action) {
                ForEach(Array(ActionKind.groups.enumerated()), id: \.offset) { index, group in
                    if index > 0 { Divider() }
                    ForEach(group) { Text($0.title).tag($0) }
                }
            } label: {
                if let title { Text(title) }
            }
            .labelsHidden(title == nil)

            if binding.action == .customShortcut {
                HStack {
                    Text("Enviar:").foregroundStyle(.secondary)
                    KeyRecorder(combo: $binding.shortcut, placeholder: "Gravar teclas")
                        .frame(width: 140)
                }
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func labelsHidden(_ hidden: Bool) -> some View {
        if hidden { labelsHidden() } else { self }
    }
}

/// Botão que grava a próxima combinação de teclas.
struct KeyRecorder: View {
    @Binding var combo: KeyCombo?
    let placeholder: String

    // (Sem @State: no SDK das Command Line Tools ele é uma macro que só existe no Xcode.)
    @StateObject private var recorder = Recorder()

    var body: some View {
        Button {
            recorder.isRecording ? recorder.stop() : recorder.start { combo = $0 }
        } label: {
            Text(recorder.isRecording ? "Pressione as teclas…" : (combo?.display ?? placeholder))
                .frame(maxWidth: .infinity)
                .foregroundStyle(recorder.isRecording ? Color.accentColor : (combo == nil ? .secondary : .primary))
        }
        .onDisappear { recorder.stop() }
    }

    final class Recorder: ObservableObject {
        @Published var isRecording = false
        private var monitor: Any?

        /// `onRecord(nil)` apaga o atalho (tecla Delete). Esc cancela.
        func start(onRecord: @escaping (KeyCombo?) -> Void) {
            isRecording = true
            EventTapController.shared.isPaused = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let modifiers = event.modifierFlags.intersection(KeyCombo.relevantModifiers)
                switch (event.keyCode, modifiers.isEmpty) {
                case (53, true):
                    break
                case (51, true):
                    onRecord(nil)
                default:
                    onRecord(KeyCombo(keyCode: event.keyCode, modifiers: modifiers.rawValue,
                                      display: KeyNames.display(keyCode: event.keyCode, modifiers: modifiers, event: event)))
                }
                self?.stop()
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if isRecording { isRecording = false }
            EventTapController.shared.isPaused = false
        }
    }
}

enum KeyNames {
    private static let special: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Espaço", 51: "⌫", 53: "⎋", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    static func display(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, event: NSEvent) -> String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        text += special[keyCode] ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
        return text
    }
}
