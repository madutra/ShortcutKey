import Foundation
import MultitouchBridge

/// Reconhece toques e arrastes com 3, 4 e 5 dedos a partir dos dados brutos do trackpad.
final class GestureEngine {
    static let shared = GestureEngine()

    /// Chamado (na main thread) sempre que um gesto é reconhecido — usado na tela de configurações.
    var onGesture: ((Gesture) -> Void)?

    // Ajustes finos (posições normalizadas: 0...1 do tamanho do trackpad).
    private let swipeDistance = 0.12
    private let tapMaxDuration = 0.30
    private let tapMaxMovement = 0.04
    private let switcherStartDistance = 0.06
    private let switcherStepDistance = 0.08

    private struct Session {
        var startTime: Double
        var maxFingers = 0
        var currentFingers = 0
        var anchor: (x: Double, y: Double)?
        var maxMovement = 0.0
        var fired = false
        /// Alternador de apps aberto; guarda o X do último passo.
        var switcherLastX: Double?
        /// true = alternador do ShortcutKey; false = ⌘⇥ do macOS.
        var usesOwnSwitcher = false
    }

    private let lock = NSLock()
    private var session: Session?
    private var loggedFrames = 0

    /// Número de trackpads encontrados, ou -1 se o framework não estiver disponível.
    @discardableResult
    func start() -> Int {
        Int(SKMultitouchStart { touches, count, timestamp in
            GestureEngine.shared.process(touches, Int(count), timestamp)
        })
    }

    func stop() {
        SKMultitouchStop()
        lock.withLock {
            AppSwitcher.end()
            session = nil
        }
    }

    private func process(_ touches: UnsafePointer<SKTouch>?, _ count: Int, _ timestamp: Double) {
        // Estados 4 e 5 = dedo encostado no trackpad (ignora dedos "pairando" ou saindo).
        var xs: [Double] = []
        var ys: [Double] = []
        if let touches {
            for i in 0..<count where (4...5).contains(touches[i].state) {
                xs.append(Double(touches[i].x))
                ys.append(Double(touches[i].y))
            }
        }

        lock.lock()
        if loggedFrames < 40, count > 0, let touches {
            loggedFrames += 1
            let desc = (0..<count).map { "[estado \(touches[$0].state) x=\(String(format: "%.2f", touches[$0].x)) y=\(String(format: "%.2f", touches[$0].y))]" }
            Log.write("toque: \(count) dedo(s) \(desc.joined(separator: " "))")
        }
        let recognized = update(fingers: xs.count, xs: xs, ys: ys, timestamp: timestamp)
        lock.unlock()

        guard let recognized else { return }
        Log.write("gesto reconhecido: \(recognized.rawValue)")
        let binding = SettingsStore.shared.current.binding(for: recognized)
        ActionPerformer.perform(binding)
        DispatchQueue.main.async { self.onGesture?(recognized) }
    }

    private func update(fingers: Int, xs: [Double], ys: [Double], timestamp: Double) -> Gesture? {
        let settings = SettingsStore.shared.current
        guard settings.gesturesEnabled else {
            AppSwitcher.end()
            session = nil
            return nil
        }

        // Levantou algum dedo com o alternador aberto: solta o ⌘ e troca de app.
        if var s = session, s.switcherLastX != nil, fingers < s.maxFingers {
            if s.usesOwnSwitcher {
                DispatchQueue.main.async { SwitcherController.shared.triggerReleased() }
            } else {
                AppSwitcher.end()
            }
            s.switcherLastX = nil
            session = s
        }

        // Todos os dedos saíram: fim do gesto. Foi um toque rápido?
        if fingers == 0 {
            defer { session = nil }
            guard let s = session, !s.fired,
                  timestamp - s.startTime < tapMaxDuration,
                  s.maxMovement < tapMaxMovement else { return nil }
            return Gesture.tap(fingers: s.maxFingers)
        }

        var s = session ?? Session(startTime: timestamp)
        let cx = xs.reduce(0, +) / Double(fingers)
        let cy = ys.reduce(0, +) / Double(fingers)

        if fingers != s.currentFingers {
            s.currentFingers = fingers
            if fingers > s.maxFingers {
                s.maxFingers = fingers
                s.anchor = (cx, cy)
                s.maxMovement = 0
            }
        }

        var recognized: Gesture?
        // Só mede o arraste com o número máximo de dedos (evita ruído ao levantar os dedos).
        if fingers == s.maxFingers, let anchor = s.anchor {
            let dx = cx - anchor.x
            let dy = cy - anchor.y
            s.maxMovement = max(s.maxMovement, hypot(dx, dy))
            let isHorizontal = abs(dx) > 1.3 * abs(dy)

            if let lastX = s.switcherLastX {
                // Alternador aberto: cada passo para o lado anda um app.
                let delta = cx - lastX
                if abs(delta) > switcherStepDistance {
                    let forward = delta > 0
                    if s.usesOwnSwitcher {
                        DispatchQueue.main.async { SwitcherController.shared.move(forward ? 1 : -1) }
                    } else {
                        AppSwitcher.step(forward: forward)
                    }
                    s.switcherLastX = lastX + (delta > 0 ? switcherStepDistance : -switcherStepDistance)
                }
            } else if !s.fired, fingers == settings.appSwitcher.fingers, isHorizontal, abs(dx) > switcherStartDistance {
                s.fired = true
                s.switcherLastX = cx
                s.usesOwnSwitcher = settings.switcher.enabled
                let forward = dx > 0
                if s.usesOwnSwitcher {
                    DispatchQueue.main.async { SwitcherController.shared.show(forward: forward) }
                } else {
                    AppSwitcher.begin(forward: forward)
                }
                Log.write("alternador de apps aberto")
            } else if !s.fired, fingers == 3 || fingers == 4, max(abs(dx), abs(dy)) > swipeDistance {
                let dominant = max(abs(dx), abs(dy)) > 1.3 * min(abs(dx), abs(dy))
                if dominant {
                    s.fired = true
                    let gesture = Gesture.swipe(fingers: fingers, dx: dx, dy: dy)
                    if let gesture, !settings.isReservedByAppSwitcher(gesture) {
                        recognized = gesture
                    }
                }
            }
        }

        session = s
        return recognized
    }
}
