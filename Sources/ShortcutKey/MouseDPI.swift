import AppKit
import IOKit.hid

/// DPI de verdade (no sensor) de mouses Logitech, pelo protocolo HID++ 2.0 — o mesmo do software da Logitech.
/// Precisa da permissão de Monitoramento de Entrada para conversar com o mouse.
final class MouseDPI: ObservableObject {
    static let shared = MouseDPI()

    enum State: Equatable {
        case searching
        case needsPermission
        case noDevice
        case unsupported(String)
        /// Outro app (ex.: Karabiner-Elements) abriu o mouse com exclusividade.
        case busy(String)
        case ready
    }

    @Published private(set) var state: State = .searching
    @Published private(set) var deviceName = ""
    @Published private(set) var currentDPI: Int?
    @Published private(set) var dpiRange: ClosedRange<Int>?
    @Published private(set) var dpiStep = 50
    @Published private(set) var dpiValues: [Int] = []
    /// nil = o mouse não tem perfis na memória.
    @Published private(set) var onboardProfilesActive: Bool?
    @Published private(set) var message: String?
    /// Valor do controle deslizante (antes de aplicar).
    @Published var draftDPI = 1600

    private let thread = HIDThread()
    private var manager: IOHIDManager?
    private var mouse: HIDPPMouse?

    var hasPermission: Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }

    func requestPermission() {
        if !IOHIDRequestAccess(kIOHIDRequestTypeListenEvent),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    func start() {
        thread.start()
        thread.perform { [weak self] in self?.setUpManager() }
    }

    /// Procura o mouse de novo e reaplica o DPI guardado.
    func refresh() {
        thread.perform { [weak self] in self?.connect(applySaved: true) }
    }

    func setDPI(_ dpi: Int) {
        var settings = SettingsStore.shared.settings
        settings.mouse.dpi = dpi
        SettingsStore.shared.settings = settings
        thread.perform { [weak self] in self?.apply(dpi: dpi, report: true) }
    }

    func setOnboardProfiles(_ enabled: Bool) {
        var settings = SettingsStore.shared.settings
        settings.mouse.onboardProfiles = enabled
        if enabled { settings.mouse.dpi = nil } // os perfis do mouse voltam a mandar no DPI
        SettingsStore.shared.settings = settings
        thread.perform { [weak self] in
            guard let self, let mouse = self.mouse else { return }
            mouse.setOnboardMode(enabled)
            self.readState(mouse)
        }
    }

    // MARK: Na thread do HID

    private func setUpManager() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: HIDPPMouse.logitechVendorID] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let me = Unmanaged<MouseDPI>.fromOpaque(context).takeUnretainedValue()
            // Mouse conectado (ou reconectado): espera ele terminar de iniciar e reaplica o DPI.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { me.refresh() }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let me = Unmanaged<MouseDPI>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { me.refresh() }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        self.manager = manager
        connect(applySaved: true)
    }

    private func connect(applySaved: Bool) {
        Log.write("mouse: monitoramento de entrada = \(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent).rawValue) (0 = liberado)")
        guard hasPermission else {
            mouse = nil
            return publish { $0.state = .needsPermission }
        }
        guard let manager else { return }
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        // A interface HID++ é a que aceita relatórios de 20 bytes.
        let candidates = devices.filter { (IOHIDDeviceGetProperty($0, kIOHIDMaxOutputReportSizeKey as CFString) as? Int ?? 0) >= 20 }

        mouse = nil
        var unsupportedName: String?
        var busyName: String?
        for device in candidates {
            guard let found = HIDPPMouse(device: device) else {
                if HIDPPMouse.lastOpenError == kIOReturnExclusiveAccess {
                    busyName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "mouse"
                }
                continue
            }
            if found.dpiFeature == nil {
                unsupportedName = found.name
                continue
            }
            mouse = found
            break
        }
        guard let mouse else {
            return publish { $0.state = busyName.map { .busy($0) } ?? unsupportedName.map { .unsupported($0) } ?? .noDevice }
        }
        Log.write("mouse: \(mouse.name) (HID++), DPI \(mouse.currentDPI() ?? 0)")

        if applySaved {
            let saved = SettingsStore.shared.current.mouse
            if let onboard = saved.onboardProfiles, mouse.onboardMode() != onboard { mouse.setOnboardMode(onboard) }
            if let dpi = saved.dpi { apply(dpi: dpi, report: false) }
        }
        readState(mouse)
    }

    private func apply(dpi: Int, report: Bool) {
        guard let mouse else { return }
        mouse.setDPI(dpi)
        let now = mouse.currentDPI()
        Log.write("mouse: DPI pedido \(dpi), agora \(now ?? 0)")
        readState(mouse)
        guard report else { return }
        let ignored = now != dpi && mouse.onboardMode() == true
        publish { state in
            state.message = now == dpi ? "DPI do mouse: \(dpi)"
                : ignored ? "O mouse está usando os perfis da memória interna e ignorou a mudança. Desligue \"Perfis da memória do mouse\" abaixo e tente de novo."
                : "O mouse não aceitou esse valor (ficou em \(now ?? 0))."
        }
    }

    private func readState(_ mouse: HIDPPMouse) {
        let list = mouse.dpiList()
        let current = mouse.currentDPI()
        let onboard = mouse.onboardMode()
        let name = mouse.name // não capturar o mouse: ele tem que ser liberado nesta thread
        publish { state in
            state.state = .ready
            state.deviceName = name
            state.currentDPI = current
            state.dpiRange = list.range
            state.dpiStep = list.step
            state.dpiValues = list.values
            state.onboardProfilesActive = onboard
            if let current { state.draftDPI = current }
        }
    }

    private func publish(_ change: @escaping (MouseDPI) -> Void) {
        DispatchQueue.main.async { change(self) }
    }
}

// MARK: - HID++ 2.0

/// Um mouse Logitech conectado por cabo (índice de dispositivo 0xFF), falando HID++ 2.0.
private final class HIDPPMouse {
    static let logitechVendorID = 0x046d
    private static let softwareID: UInt8 = 0x0B
    /// Modo só para esperar respostas: assim outros trabalhos da thread (ex.: um novo "procurar mouse")
    /// não rodam no meio de uma conversa com o mouse.
    private static let waitMode = CFRunLoopMode("app.shortcutkey.hidpp" as CFString)

    /// Motivo da última falha ao abrir (ex.: kIOReturnExclusiveAccess).
    static var lastOpenError: IOReturn = kIOReturnSuccess

    let device: IOHIDDevice
    let name: String
    private(set) var dpiFeature: UInt8?
    private var onboardFeature: UInt8?

    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var isOpen = false
    private var waitingFeature: UInt8 = 0
    private var response: [UInt8]?

    init?(device: IOHIDDevice) {
        self.device = device
        name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Mouse Logitech"
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        Self.lastOpenError = result
        guard result == kIOReturnSuccess else {
            Log.write(String(format: "mouse: não foi possível abrir o %@ (0x%x)", name, result))
            return nil // o deinit libera o buffer
        }
        isOpen = true
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { context, _, _, _, reportID, report, length in
            guard let context else { return }
            let me = Unmanaged<HIDPPMouse>.fromOpaque(context).takeUnretainedValue()
            var bytes = Array(UnsafeBufferPointer(start: report, count: length))
            if bytes.first != UInt8(truncatingIfNeeded: reportID) { bytes.insert(UInt8(truncatingIfNeeded: reportID), at: 0) }
            me.received(bytes)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), Self.waitMode.rawValue)

        dpiFeature = featureIndex(0x2201)     // Adjustable DPI
        onboardFeature = featureIndex(0x8100) // Onboard Profiles
    }

    deinit {
        if isOpen {
            IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), Self.waitMode.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        buffer.deallocate()
    }

    // DPI (função 0x2201)

    struct DPIList {
        var values: [Int] = []
        var range: ClosedRange<Int>?
        var step = 50
    }

    func dpiList() -> DPIList {
        guard let dpiFeature, let p = call(dpiFeature, 1, [0]) else { return DPIList() }
        var raw: [Int] = []
        var i = 1
        while i + 1 < p.count {
            let value = Int(p[i]) << 8 | Int(p[i + 1])
            if value == 0 { break }
            raw.append(value)
            i += 2
        }
        // Formato "mínimo, passo (0xE000 | passo), máximo" ou uma lista de valores fixos.
        if let s = raw.firstIndex(where: { $0 >= 0xE000 }), s > 0, s + 1 < raw.count {
            return DPIList(values: [], range: raw[s - 1]...raw[s + 1], step: raw[s] & 0x1FFF)
        }
        return DPIList(values: raw, range: raw.isEmpty ? nil : raw.min()!...raw.max()!, step: 0)
    }

    func currentDPI() -> Int? {
        guard let dpiFeature, let p = call(dpiFeature, 2, [0]), p.count >= 3 else { return nil }
        return Int(p[1]) << 8 | Int(p[2])
    }

    func setDPI(_ dpi: Int) {
        guard let dpiFeature else { return }
        _ = call(dpiFeature, 3, [0, UInt8(dpi >> 8), UInt8(dpi & 0xFF)])
    }

    // Perfis da memória (função 0x8100): 1 = perfis do mouse, 2 = controlado pelo computador.

    func onboardMode() -> Bool? {
        guard let onboardFeature, let p = call(onboardFeature, 2) else { return nil }
        return p[0] == 1
    }

    func setOnboardMode(_ enabled: Bool) {
        guard let onboardFeature else { return }
        _ = call(onboardFeature, 1, [enabled ? 1 : 2])
    }

    // Comunicação

    private func featureIndex(_ id: UInt16) -> UInt8? {
        guard let p = call(0x00, 0, [UInt8(id >> 8), UInt8(id & 0xFF)]), p[0] != 0 else { return nil }
        return p[0]
    }

    private func received(_ report: [UInt8]) {
        guard report.count >= 5, report[0] == 0x10 || report[0] == 0x11 else { return }
        let isAnswer = report[2] == waitingFeature && report[3] & 0x0F == Self.softwareID
        let isError = report[2] == 0xFF && report[3] == waitingFeature
        if isAnswer || isError { response = report }
    }

    /// Envia um pedido HID++ longo e espera a resposta (até 1 s). Retorna os parâmetros da resposta.
    private func call(_ feature: UInt8, _ function: UInt8, _ params: [UInt8] = []) -> [UInt8]? {
        var report = [UInt8](repeating: 0, count: 20)
        report[0] = 0x11
        report[1] = 0xFF
        report[2] = feature
        report[3] = function << 4 | Self.softwareID
        for (i, value) in params.prefix(16).enumerated() { report[4 + i] = value }

        response = nil
        waitingFeature = feature
        guard IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x11, report, report.count) == kIOReturnSuccess else { return nil }
        let deadline = Date().addingTimeInterval(1)
        while response == nil, Date() < deadline {
            CFRunLoopRunInMode(Self.waitMode, 0.02, true)
        }
        guard let response, response[2] != 0xFF else { return nil }
        return Array(response[4...])
    }
}

/// Thread com run loop próprio para conversar com o mouse sem travar a interface.
private final class HIDThread: Thread {
    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)
    private var started = false

    override func start() {
        guard !started else { return }
        started = true
        super.start()
        ready.wait()
    }

    override func main() {
        runLoop = CFRunLoopGetCurrent()
        RunLoop.current.add(Port(), forMode: .default) // mantém o run loop vivo
        ready.signal()
        while !isCancelled {
            RunLoop.current.run(mode: .default, before: .distantFuture)
        }
    }

    func perform(_ block: @escaping () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }
}
