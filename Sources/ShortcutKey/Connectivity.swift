import AppKit
import CoreLocation
import CoreWLAN
import IOBluetooth
import IOKit.ps
import Network

/// Wi-Fi, Bluetooth e internet para a aba "Conexões" do notch. Só atualiza enquanto a aba está aberta.
final class Connectivity: NSObject, ObservableObject {
    static let shared = Connectivity()

    struct BluetoothDevice: Identifiable, Equatable {
        let id: String // endereço
        let name: String
        let isConnected: Bool
        let symbol: String
        let battery: Int?
    }

    @Published private(set) var wifiOn = false
    @Published private(set) var wifiName: String?
    @Published private(set) var wifiSignal: Int? // RSSI em dBm
    @Published private(set) var ipAddress: String?
    @Published private(set) var bluetoothOn = false
    @Published private(set) var devices: [BluetoothDevice] = []
    @Published private(set) var internet = "Verificando…"
    @Published private(set) var internetOK = false
    @Published private(set) var needsLocationForWifiName = false
    @Published private(set) var busyDevice: String?

    private var timer: Timer?
    private let pathMonitor = NWPathMonitor()
    private var location: CLLocationManager?
    private var monitoring = false

    // MARK: Ciclo

    func startUpdating() {
        if !monitoring {
            monitoring = true
            pathMonitor.pathUpdateHandler = { [weak self] path in
                DispatchQueue.main.async { self?.update(path) }
            }
            pathMonitor.start(queue: DispatchQueue(label: "app.shortcutkey.network"))
        }
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stopUpdating() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let wifi = CWWiFiClient.shared().interface()
        wifiOn = wifi?.powerOn() ?? false
        wifiName = wifiOn ? wifi?.ssid() : nil
        let rssi = wifiOn ? wifi?.rssiValue() ?? 0 : 0
        wifiSignal = rssi != 0 ? rssi : nil // 0 = não conectado a nenhuma rede
        let status = location?.authorizationStatus ?? CLLocationManager().authorizationStatus
        needsLocationForWifiName = wifiOn && wifiName == nil && wifiSignal != nil && status != .authorizedAlways
        ipAddress = Self.ipAddress(interface: wifi?.interfaceName)

        bluetoothOn = IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let batteries = Self.accessoryBatteries()
        devices = paired
            .map { BluetoothDevice(id: $0.addressString ?? UUID().uuidString, name: $0.name ?? "Dispositivo",
                                   isConnected: $0.isConnected(), symbol: Self.symbol(for: $0),
                                   battery: $0.isConnected() ? batteries[$0.name ?? ""] : nil) }
            .sorted { ($0.isConnected ? 0 : 1, $0.name) < ($1.isConnected ? 0 : 1, $1.name) }
    }

    private func update(_ path: NWPath) {
        internetOK = path.status == .satisfied
        guard internetOK else { internet = "Sem internet"; return }
        let via = path.usesInterfaceType(.wiredEthernet) ? "cabo"
            : path.usesInterfaceType(.wifi) ? "Wi-Fi"
            : path.usesInterfaceType(.cellular) ? "celular"
            : "outra conexão"
        let vpn = path.availableInterfaces.contains { $0.name.hasPrefix("utun") || $0.name.hasPrefix("ipsec") } && path.usesInterfaceType(.other)
        internet = "Conectado por \(via)" + (vpn ? " · VPN" : "")
    }

    // MARK: Ações

    func toggleWifi() {
        guard let wifi = CWWiFiClient.shared().interface() else { return }
        do { try wifi.setPower(!wifi.powerOn()) } catch { Log.write("notch: Wi-Fi não mudou: \(error)") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refresh() }
    }

    func toggleBluetooth() {
        let newState: Int32 = bluetoothOn ? 0 : 1
        if let set = Self.setBluetoothPower { set(newState) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refresh() }
    }

    func toggle(_ device: BluetoothDevice) {
        guard let target = IOBluetoothDevice(addressString: device.id) else { return }
        busyDevice = device.id
        DispatchQueue.global(qos: .userInitiated).async {
            let result = target.isConnected() ? target.closeConnection() : target.openConnection()
            if result != kIOReturnSuccess { Log.write(String(format: "notch: Bluetooth %@ falhou (0x%x)", device.name, result)) }
            DispatchQueue.main.async {
                self.busyDevice = nil
                self.refresh()
            }
        }
    }

    func requestLocation() {
        let manager = CLLocationManager()
        manager.delegate = self
        location = manager
        if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        manager.requestWhenInUseAuthorization()
    }

    func openWifiSettings() { openSettings("x-apple.systempreferences:com.apple.wifi-settings-extension") }
    func openBluetoothSettings() { openSettings("x-apple.systempreferences:com.apple.BluetoothSettings") }
    func openNetworkSettings() { openSettings("x-apple.systempreferences:com.apple.Network-Settings.extension") }

    private func openSettings(_ address: String) {
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }

    // MARK: Utilitários

    /// Ligar/desligar o Bluetooth não tem API pública; é a mesma função que o menu do Bluetooth usa.
    private static let setBluetoothPower: (@convention(c) (Int32) -> Void)? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY),
              let symbol = dlsym(handle, "IOBluetoothPreferenceSetControllerPowerState") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (Int32) -> Void).self)
    }()

    /// Bateria de fones, teclados e mouses: o macOS lista junto com a bateria do Mac (o mesmo que `pmset -g accps`).
    static func accessoryBatteries() -> [String: Int] {
        // A função pública só lista a bateria do Mac; a "por tipo" (a do pmset) inclui os acessórios.
        guard let info = (copyPowerSourcesByType?(4)?.takeRetainedValue() ?? IOPSCopyPowerSourcesInfo()?.takeRetainedValue()),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return [:] }
        var result: [String: Int] = [:]
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String != kIOPSInternalBatteryType,
                  let name = description[kIOPSNameKey] as? String,
                  let current = description[kIOPSCurrentCapacityKey] as? Int else { continue }
            let max = description[kIOPSMaxCapacityKey] as? Int ?? 100
            result[name] = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current
        }
        return result
    }

    private static let copyPowerSourcesByType: (@convention(c) (Int32) -> Unmanaged<CFTypeRef>?)? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "IOPSCopyPowerSourcesByType") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (Int32) -> Unmanaged<CFTypeRef>?).self)
    }()

    static func symbol(for device: IOBluetoothDevice) -> String {
        let name = (device.name ?? "").lowercased()
        if name.contains("airpods") { return "airpodspro" }
        if ["keyboard", "teclado", "keychron", "keys", "magic kb"].contains(where: name.contains) { return "keyboard" }
        if ["mouse", "mx master", "mx anywhere"].contains(where: name.contains) { return "computermouse" }
        if ["buds", "headphone", "fone", "tws", "beats", "wh-", "wf-"].contains(where: name.contains) { return "headphones" }
        if name.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if name.contains("iphone") { return "iphone" }
        if name.contains("watch") { return "applewatch" }
        switch device.deviceClassMajor {
        case 0x04: return "headphones"          // áudio
        case 0x05: return "keyboard"            // periféricos
        case 0x02: return "iphone"              // telefone
        case 0x01: return "laptopcomputer"      // computador
        default: return "dot.radiowaves.left.and.right"
        }
    }

    private static func ipAddress(interface: String?) -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var fallback: String?
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard name != "lo0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if name == interface { return ip }
            if fallback == nil, name.hasPrefix("en") { fallback = ip }
        }
        return fallback
    }
}

extension Connectivity: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async { self.refresh() }
    }
}

// MARK: - Avisos de conexão

/// Avisa quando um dispositivo Bluetooth conecta ou desconecta (fones, teclado, mouse…), com a bateria
/// quando o dispositivo informa.
final class BluetoothWatcher: NSObject {
    static let shared = BluetoothWatcher()

    struct Event {
        let name: String
        let symbol: String
        let connected: Bool
        let battery: Int?
    }

    var onEvent: ((Event) -> Void)?

    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var startedAt = Date()

    func start() {
        guard connectNotification == nil else { return }
        startedAt = Date()
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
    }

    @objc private func connected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let id = device.addressString ?? UUID().uuidString
        disconnectNotifications[id]?.unregister()
        disconnectNotifications[id] = device.register(forDisconnectNotification: self, selector: #selector(disconnected(_:device:)))
        // Ao registrar, o macOS avisa de todos os que já estavam conectados: esses não viram aviso.
        guard Date().timeIntervalSince(startedAt) > 3 else { return }
        // A bateria costuma chegar um instante depois da conexão.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.onEvent?(Event(name: device.name ?? "Dispositivo", symbol: Connectivity.symbol(for: device),
                                 connected: true, battery: Self.battery(of: device)))
        }
    }

    @objc private func disconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        disconnectNotifications.removeValue(forKey: device.addressString ?? "")?.unregister()
        onEvent?(Event(name: device.name ?? "Dispositivo", symbol: Connectivity.symbol(for: device), connected: false, battery: nil))
    }

    /// Primeiro a lista de baterias do macOS; senão, propriedades não documentadas (fones da Apple).
    private static func battery(of device: IOBluetoothDevice) -> Int? {
        if let name = device.name, let level = Connectivity.accessoryBatteries()[name] { return level }
        for key in ["batteryPercentCombined", "batteryPercentSingle", "batteryPercentLeft", "batteryPercentRight"] {
            guard device.responds(to: NSSelectorFromString(key)),
                  let value = device.value(forKey: key) as? NSNumber, value.intValue > 0 else { continue }
            return value.intValue
        }
        return nil
    }
}
