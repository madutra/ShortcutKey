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
    /// Quanto arrastar para o lado antes de a tela começar a deslizar entre apps.
    private let appSwipeStartDistance = 0.03

    private struct Session {
        var startTime: Double
        var maxFingers = 0
        var currentFingers = 0
        var anchor: (x: Double, y: Double)?
        var maxMovement = 0.0
        var fired = false
        /// Imagens do "deslizar entre apps" sendo preparadas (os dedos encostaram).
        var appSwipePrepared = false
        /// A tela está acompanhando os dedos.
        var appSwiping = false
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
            if let session { finishAppSwipe(session) }
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
            if let session { finishAppSwipe(session) }
            session = nil
            return nil
        }

        // Levantou algum dedo: termina o deslizar entre apps (troca ou volta).
        if var s = session, s.appSwipePrepared, fingers < s.maxFingers {
            finishAppSwipe(s)
            s.appSwipePrepared = false
            s.appSwiping = false
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
        let swipeFingers = settings.appSwipe.fingers

        if fingers != s.currentFingers {
            s.currentFingers = fingers
            if fingers > s.maxFingers {
                s.maxFingers = fingers
                s.anchor = (cx, cy)
                s.maxMovement = 0
                // Encostou o número de dedos do gesto: já prepara as imagens das telas.
                if fingers == swipeFingers, !s.appSwipePrepared {
                    s.appSwipePrepared = true
                    DispatchQueue.main.async { AppSwipeController.shared.prepare() }
                } else if s.appSwipePrepared, !s.appSwiping {
                    s.appSwipePrepared = false
                    DispatchQueue.main.async { AppSwipeController.shared.discard() }
                }
            }
        }

        var recognized: Gesture?
        // Só mede o arraste com o número máximo de dedos (evita ruído ao levantar os dedos).
        if fingers == s.maxFingers, let anchor = s.anchor {
            let dx = cx - anchor.x
            let dy = cy - anchor.y
            s.maxMovement = max(s.maxMovement, hypot(dx, dy))
            let isHorizontal = abs(dx) > 1.3 * abs(dy)

            if s.appSwiping {
                DispatchQueue.main.async { AppSwipeController.shared.update(dx: dx) }
            } else if !s.fired, fingers == swipeFingers, isHorizontal, abs(dx) > appSwipeStartDistance {
                s.fired = true
                s.appSwiping = true
                DispatchQueue.main.async {
                    AppSwipeController.shared.begin()
                    AppSwipeController.shared.update(dx: dx)
                }
                Log.write("deslizar entre apps")
            } else if !s.fired, fingers == 3 || fingers == 4, max(abs(dx), abs(dy)) > swipeDistance {
                let dominant = max(abs(dx), abs(dy)) > 1.3 * min(abs(dx), abs(dy))
                if dominant {
                    s.fired = true
                    let gesture = Gesture.swipe(fingers: fingers, dx: dx, dy: dy)
                    if let gesture, !settings.isReservedByAppSwipe(gesture) {
                        recognized = gesture
                    }
                }
            }
        }

        session = s
        return recognized
    }

    /// Fim do gesto: se a tela estava deslizando, decide a troca; se só preparou, descarta.
    private func finishAppSwipe(_ s: Session) {
        if s.appSwiping {
            DispatchQueue.main.async { AppSwipeController.shared.end() }
        } else if s.appSwipePrepared {
            DispatchQueue.main.async { AppSwipeController.shared.discard() }
        }
    }
}
