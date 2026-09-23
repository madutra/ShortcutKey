import AppKit
import SwiftUI

/// Tela de boas-vindas: guia as permissões na primeira vez (e quando alguma estiver faltando).
enum Onboarding {
    private static let doneKey = "onboardingDone"
    private static var window: NSWindow?

    static var isDone: Bool { UserDefaults.standard.bool(forKey: doneKey) }

    static func showIfNeeded() {
        if !isDone || !AX.isTrusted { show() }
    }

    static func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:
            OnboardingView(model: OnboardingModel()) { finish() }
                .environmentObject(AppController.shared)
        )
        window.setContentSize(window.contentView!.fittingSize)
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private static func finish() {
        UserDefaults.standard.set(true, forKey: doneKey)
        window?.close()
        window = nil
    }
}

final class OnboardingModel: ObservableObject {
    @Published var accessibility = AX.isTrusted
    @Published var screenRecording = Thumbnails.hasPermission
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let accessibility = AX.isTrusted
            let screenRecording = Thumbnails.hasPermission
            if accessibility != self.accessibility { self.accessibility = accessibility }
            if screenRecording != self.screenRecording { self.screenRecording = screenRecording }
        }
    }

    deinit { timer?.invalidate() }
}

private struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @EnvironmentObject private var controller: AppController
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bem-vindo ao ShortcutKey").font(.title2.bold())
                    Text("Libere as permissões abaixo e está tudo pronto.")
                        .foregroundStyle(.secondary)
                }
            }

            PermissionRow(
                number: 1,
                title: "Acessibilidade",
                detail: "Necessária para gestos, atalhos, botões das janelas e o alternador de apps.",
                granted: model.accessibility,
                buttonTitle: "Permitir"
            ) {
                AX.promptForPermission()
                AX.openAccessibilitySettings()
            }

            PermissionRow(
                number: 2,
                title: "Gravação de Tela",
                detail: "Opcional: miniaturas das janelas no alternador e o print com ⌘⇧S. Se o macOS pedir para reabrir o app, aceite.",
                granted: model.screenRecording,
                buttonTitle: "Permitir"
            ) {
                Thumbnails.requestPermission()
            }

            Divider()

            Toggle("Abrir o ShortcutKey ao iniciar sessão", isOn: Binding(
                get: { controller.launchAtLogin },
                set: { controller.setLaunchAtLogin($0) }
            ))

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "hand.draw").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Vai usar gestos de 3 ou 4 dedos? Desative o mesmo gesto do macOS para eles não acontecerem juntos.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Abrir ajustes do Trackpad") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
            }

            HStack {
                Text("O ícone do ShortcutKey fica na barra de menu, lá em cima à direita.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(model.accessibility ? "Começar a usar" : "Fazer depois", action: done)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(28)
        .frame(width: 540)
    }
}

private struct PermissionRow: View {
    let number: Int
    let title: String
    let detail: String
    let granted: Bool
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(granted ? Color.green : Color.accentColor).frame(width: 26, height: 26)
                if granted {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                Text("Liberada").foregroundStyle(.green).font(.callout.bold())
            } else {
                Button(buttonTitle, action: action)
            }
        }
    }
}
