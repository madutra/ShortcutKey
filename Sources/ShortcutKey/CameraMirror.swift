import AppKit
import AVFoundation
import SwiftUI

/// Espelho da câmera no notch, para ver como você está antes de uma chamada.
/// A câmera só liga quando você clica no espelho e desliga quando o notch fecha.
final class CameraMirror: ObservableObject {
    static let shared = CameraMirror()

    enum State: Equatable { case off, starting, on, denied, noCamera }

    @Published private(set) var state: State = .off
    let session = AVCaptureSession()
    private(set) lazy var previewLayer: AVCaptureVideoPreviewLayer = {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        return layer
    }()
    private let queue = DispatchQueue(label: "app.shortcutkey.camera")
    private var configured = false

    func toggle() { state == .on || state == .starting ? stop() : start() }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run()
        case .notDetermined:
            state = .starting
            NSApp.activate(ignoringOtherApps: true)
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { granted ? self.run() : (self.state = .denied) }
            }
        default:
            state = .denied
        }
    }

    func stop() {
        guard state == .on || state == .starting else { return }
        state = .off
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    private func run() {
        state = .starting
        queue.async {
            if !self.configured {
                let device = AVCaptureDevice.default(for: .video)
                guard let device, let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input) else {
                    DispatchQueue.main.async { self.state = .noCamera }
                    return
                }
                self.session.beginConfiguration()
                self.session.sessionPreset = .medium
                self.session.addInput(input)
                self.session.commitConfiguration()
                self.configured = true
            }
            self.session.startRunning()
            Log.write("câmera: ligada \(self.session.isRunning)")
            DispatchQueue.main.async {
                if let connection = self.previewLayer.connection, connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = true
                }
                // Pode ter sido desligada enquanto ligava (ex.: notch fechou).
                if self.state == .starting { self.state = .on } else { self.queue.async { self.session.stopRunning() } }
            }
        }
    }
}

/// A imagem da câmera, espelhada como num espelho de verdade. A camada de vídeo é sempre a mesma
/// (fica no CameraMirror): criar uma nova a cada vez que o notch abre deixava a imagem preta.
struct CameraPreview: NSViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.attach(layer)
        return view
    }

    func updateNSView(_ view: PreviewView, context: Context) { view.attach(layer) }

    final class PreviewView: NSView {
        private weak var preview: CALayer?

        func attach(_ layer: CALayer) {
            wantsLayer = true
            if layer.superlayer !== self.layer {
                layer.removeFromSuperlayer()
                self.layer?.addSublayer(layer)
            }
            preview = layer
            needsLayout = true
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            preview?.frame = bounds
            CATransaction.commit()
        }
    }
}

struct CameraTile: View {
    @ObservedObject var camera: CameraMirror

    var body: some View {
        Button {
            if camera.state == .denied { camera.openPrivacySettings() } else {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { camera.toggle() }
            }
        } label: {
            ZStack {
                Circle().fill(.white.opacity(0.07))
                switch camera.state {
                case .on:
                    CameraPreview(layer: camera.previewLayer)
                        .clipShape(Circle())
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                case .starting:
                    ProgressView().controlSize(.small)
                case .off:
                    label("camera.fill", "Espelho")
                case .denied:
                    label("video.slash.fill", "Sem acesso")
                case .noCamera:
                    label("video.slash", "Sem câmera")
                }
                Circle().strokeBorder(.white.opacity(camera.state == .on ? 0.25 : 0.12), lineWidth: 1.5)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(camera.state == .on ? "Clique para desligar a câmera" : "Clique para ver a câmera")
    }

    private func label(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 18))
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.6))
    }
}
