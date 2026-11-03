import AppKit
import CoreLocation
import CoreWLAN
import IOBluetooth
import Network

/// Wi-Fi, Bluetooth e internet para a aba "Conexões" do notch. Só atualiza enquanto a aba está aberta.
final class Connectivity: NSObject, ObservableObject {
    static let shared = Connectivity()

    struct BluetoothDevice: Identifiable, Equatable {
        let id: String // endereço
        let name: String
        let isConnected: Bool
        let symbol: String
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
        devices = paired
            .map { BluetoothDevice(id: $0.addressString ?? UUID().uuidString, name: $0.name ?? "Dispositivo",
                                   isConnected: $0.isConnected(), symbol: Self.symbol(for: $0)) }
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

    private static func symbol(for device: IOBluetoothDevice) -> String {
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
