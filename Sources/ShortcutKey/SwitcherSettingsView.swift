import AppKit
import SwiftUI

struct SwitcherTab: View {
    @EnvironmentObject private var store: SettingsStore
    @StateObject private var permission = ScreenRecordingPermission()

    private var switcher: Binding<SwitcherSettings> { $store.settings.switcher }

    var body: some View {
        Form {
            Section {
                Toggle("Usar o alternador do ShortcutKey", isOn: switcher.enabled)
            } footer: {
                Text("Desligado, o gesto do trackpad usa o ⌘⇥ padrão do macOS.")
                    .foregroundStyle(.secondary)
            }

            Group {
                appearanceSection
                screensSection
                controlsSection
                contentSection
                exclusionsSection
            }
            .disabled(!store.settings.switcher.enabled)
        }
        .formStyle(.grouped)
    }

    // MARK: Aparência

    private var appearanceSection: some View {
        Section {
            HStack(spacing: 12) {
                ForEach(SwitcherStyle.allCases) { style in
                    StyleCard(style: style, isSelected: store.settings.switcher.style == style) {
                        store.settings.switcher.style = style
                    }
                }
            }
            .padding(.vertical, 4)

            if store.settings.switcher.style == .thumbnails, !permission.granted {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("As miniaturas precisam da permissão de Gravação de Tela. Sem ela, aparecem os ícones.")
                        .font(.callout)
                    Spacer()
                    Button("Permitir") { permission.request() }
                    Button("Reiniciar app") { Thumbnails.relaunchApp() }
                        .help("Use se você já liberou a permissão e o aviso continua aparecendo")
                }
            }

            Picker("Tamanho", selection: switcher.size) {
                ForEach(SwitcherSize.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Picker("Tema", selection: switcher.theme) {
                ForEach(SwitcherTheme.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Picker("Depois de soltar as teclas ou os dedos", selection: switcher.afterRelease) {
                ForEach(SwitcherRelease.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Toggle("Destacar na tela a janela selecionada", isOn: switcher.previewSelectedWindow)
        } header: {
            Text("Aparência")
        }
    }

    private var screensSection: some View {
        Section("Várias telas") {
            Picker("Mostrar em", selection: switcher.screen) {
                ForEach(SwitcherScreen.allCases) { Text($0.title).tag($0) }
            }
        }
    }

    // MARK: Controles

    private var controlsSection: some View {
        Section {
            LabeledContent("Atalho de teclado") {
                KeyRecorder(combo: switcher.shortcut, placeholder: "⌥⇥")
                    .frame(width: 140)
            }
            Toggle("Substituir o ⌘⇥ do macOS", isOn: switcher.replaceCommandTab)
            Picker("Gesto do trackpad", selection: $store.settings.appSwitcher) {
                ForEach(AppSwitcherGesture.allCases) { Text($0.title).tag($0) }
            }
        } header: {
            Text("Controles")
        } footer: {
            Text("Segure o modificador (ex.: ⌥) e aperte ⇥ para avançar, ⇧ para voltar; solte para trocar. Com o alternador aberto: ← → navegam, Esc cancela, Return escolhe. No trackpad: arraste para o lado e solte os dedos.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: O que mostrar

    private var contentSection: some View {
        Section("O que mostrar") {
            Picker("Mostrar", selection: switcher.grouping) {
                ForEach(SwitcherGrouping.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Janelas minimizadas", isOn: switcher.showMinimized)
            Toggle("Apps ocultos", isOn: switcher.showHidden)
            Toggle("Apps abertos sem janelas", isOn: switcher.showWindowless)
        }
    }

    private var exclusionsSection: some View {
        Section {
            ForEach(store.settings.switcher.excludedBundleIDs, id: \.self) { bundleID in
                HStack {
                    AppLabel(bundleID: bundleID)
                    Spacer()
                    Button(role: .destructive) {
                        store.settings.switcher.excludedBundleIDs.removeAll { $0 == bundleID }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Menu("Adicionar app aberto…") {
                ForEach(runningApps, id: \.bundleIdentifier) { app in
                    Button(app.localizedName ?? app.bundleIdentifier ?? "?") {
                        if let id = app.bundleIdentifier { store.settings.switcher.excludedBundleIDs.append(id) }
                    }
                }
            }
        } header: {
            Text("Esconder do alternador")
        }
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0 != NSRunningApplication.current }
            .filter { !store.settings.switcher.excludedBundleIDs.contains($0.bundleIdentifier!) }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }
}

/// Cartão de escolha do estilo, com uma prévia desenhada.
private struct StyleCard: View {
    let style: SwitcherStyle
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    LinearGradient(colors: [.pink.opacity(0.7), .purple.opacity(0.6), .green.opacity(0.6)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    preview
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.35)))
                }
                .frame(height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3))

                Text(style.title).fontWeight(isSelected ? .semibold : .regular)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var preview: some View {
        switch style {
        case .thumbnails:
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.9)).frame(width: 30, height: 22)
                }
            }
        case .icons:
            HStack(spacing: 4) {
                ForEach(["safari", "folder.fill", "note.text"], id: \.self) { symbol in
                    Image(systemName: symbol)
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.2)))
                }
            }
        case .titles:
            VStack(alignment: .leading, spacing: 3) {
                ForEach(["Safari", "Finder", "Notas"], id: \.self) { name in
                    Text(name)
                        .font(.system(size: 8))
                        .foregroundStyle(.white)
                        .frame(width: 70, alignment: .leading)
                        .padding(.horizontal, 4)
                        .background(RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.2)))
                }
            }
        }
    }
}

final class ScreenRecordingPermission: ObservableObject {
    @Published var granted = Thumbnails.hasPermission
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            let granted = Thumbnails.hasPermission
            if self?.granted != granted {
                self?.granted = granted
                Log.write("gravação de tela: \(granted)")
            }
        }
    }

    deinit { timer?.invalidate() }

    func request() { Thumbnails.requestPermission() }
}
