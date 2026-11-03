import AppKit
import Combine
import IOKit.hid

/// Uma tecla física: nome, código HID (página << 32 | uso), código de tecla do macOS e nome no Karabiner.
struct KeyInfo: Hashable {
    let name: String
    let usage: UInt64
    let keyCode: UInt16?
    let karabiner: String
}

enum Keys {
    private static func k(_ name: String, _ usage: UInt64, _ keyCode: UInt16?, _ karabiner: String) -> KeyInfo {
        KeyInfo(name: name, usage: 0x7_0000_0000 | usage, keyCode: keyCode, karabiner: karabiner)
    }

    static let all: [KeyInfo] = {
        var keys: [KeyInfo] = [
            k("英数 (eisū)", 0x91, 102, "japanese_eisuu"),
            k("かな (kana)", 0x90, 104, "japanese_kana"),
            k("¥ (iene)", 0x89, 93, "international3"),
            k("ろ / _ (JIS)", 0x87, 94, "international1"),
            KeyInfo(name: "fn / 🌐", usage: 0xFF_0000_0003, keyCode: 63, karabiner: "keyboard_fn"),
            k("⇪ Caps Lock", 0x39, 57, "caps_lock"),
            k("⌘ Command esquerdo", 0xE3, 55, "left_command"),
            k("⌘ Command direito", 0xE7, 54, "right_command"),
            k("⌥ Option esquerdo", 0xE2, 58, "left_option"),
            k("⌥ Option direito", 0xE6, 61, "right_option"),
            k("⌃ Control esquerdo", 0xE0, 59, "left_control"),
            k("⌃ Control direito", 0xE4, 62, "right_control"),
            k("⇧ Shift esquerdo", 0xE1, 56, "left_shift"),
            k("⇧ Shift direito", 0xE5, 60, "right_shift"),
            k("⎋ Esc", 0x29, 53, "escape"),
            k("⇥ Tab", 0x2B, 48, "tab"),
            k("↩ Return", 0x28, 36, "return_or_enter"),
            k("⌫ Delete", 0x2A, 51, "delete_or_backspace"),
            k("⌦ Delete para frente", 0x4C, 117, "delete_forward"),
            k("Espaço", 0x2C, 49, "spacebar"),
            k("` ~ (crase / til)", 0x35, 50, "grave_accent_and_tilde"),
            k("' \" (aspas)", 0x34, 39, "quote"),
            k("- _ (hífen)", 0x2D, 27, "hyphen"),
            k("= +", 0x2E, 24, "equal_sign"),
            k("[ {", 0x2F, 33, "open_bracket"),
            k("] }", 0x30, 30, "close_bracket"),
            k("\\ |", 0x31, 42, "backslash"),
            k("; :", 0x33, 41, "semicolon"),
            k(", <", 0x36, 43, "comma"),
            k(". >", 0x37, 47, "period"),
            k("/ ?", 0x38, 44, "slash"),
            k("§ ± (ISO)", 0x64, 10, "non_us_backslash"),
            k("← Seta esquerda", 0x50, 123, "left_arrow"),
            k("→ Seta direita", 0x4F, 124, "right_arrow"),
            k("↓ Seta para baixo", 0x51, 125, "down_arrow"),
            k("↑ Seta para cima", 0x52, 126, "up_arrow"),
        ]
        let fKeyCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (i, code) in fKeyCodes.enumerated() {
            keys.append(k("F\(i + 1)", 0x3A + UInt64(i), code, "f\(i + 1)"))
        }
        let letterCodes: [Character: UInt16] = ["a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34,
            "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35, "q": 12, "r": 15, "s": 1, "t": 17,
            "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6]
        for (i, letter) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            keys.append(k(letter.uppercased(), 0x04 + UInt64(i), letterCodes[letter], String(letter)))
        }
        let digitCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
        for (i, digit) in "1234567890".enumerated() {
            keys.append(k(String(digit), 0x1E + UInt64(i), digitCodes[i], String(digit)))
        }
        return keys
    }()

    static func info(usage: UInt64) -> KeyInfo? { all.first { $0.usage == usage } }
    static func info(keyCode: UInt16) -> KeyInfo? { all.first { $0.keyCode == keyCode } }
    static func info(karabiner: String) -> KeyInfo? { all.first { $0.karabiner == karabiner } }
}

/// Remapeamento de teclas pelo próprio macOS (o mesmo do `hidutil`): sem driver, sem "segurar" o teclado.
/// Vale enquanto o ShortcutKey está aberto; é reaplicado quando um teclado é conectado.
final class KeyRemapper {
    static let shared = KeyRemapper()

    private var observer: AnyCancellable?
    private var manager: IOHIDManager?
    private var pending: DispatchWorkItem?

    func start() {
        observer = SettingsStore.shared.$settings
            .map(\.keyRemaps)
            .removeDuplicates()
            .sink { [weak self] remaps in self?.apply(remaps) }

        // Teclado novo (ou reconectado) não herda o mapeamento: reaplica.
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                                                kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard] as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, _ in
            guard let context else { return }
            Unmanaged<KeyRemapper>.fromOpaque(context).takeUnretainedValue().scheduleReapply()
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        self.manager = manager
    }

    /// Desfaz o remapeamento (ao sair do app).
    func clear() { run(mappings: []) }

    func scheduleReapply() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.apply(SettingsStore.shared.settings.keyRemaps) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func apply(_ remaps: [KeyRemap]) {
        run(mappings: remaps.filter { $0.from != $0.to })
    }

    private func run(mappings: [KeyRemap]) {
        let list = mappings
            .map { "{\"HIDKeyboardModifierMappingSrc\":\($0.from),\"HIDKeyboardModifierMappingDst\":\($0.to)}" }
            .joined(separator: ",")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = ["property", "--set", "{\"UserKeyMapping\":[\(list)]}"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            Log.write("teclas remapeadas: \(mappings.count) (hidutil \(process.terminationStatus))")
        } catch {
            Log.write("teclas: falha ao rodar o hidutil: \(error)")
        }
    }

    // MARK: Importar do Karabiner-Elements

    static var karabinerConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/karabiner/karabiner.json")
    }

    static var hasKarabinerConfig: Bool { FileManager.default.fileExists(atPath: karabinerConfigURL.path) }

    /// Lê as "Simple Modifications" do perfil ativo do Karabiner. Retorna os remapeamentos e quantos foram ignorados.
    static func karabinerRemaps() -> (remaps: [KeyRemap], skipped: Int)? {
        guard let data = try? Data(contentsOf: karabinerConfigURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profiles = json["profiles"] as? [[String: Any]] else { return nil }
        let profile = profiles.first { $0["selected"] as? Bool == true } ?? profiles.first
        let simple = profile?["simple_modifications"] as? [[String: Any]] ?? []

        func key(_ value: Any?) -> KeyInfo? {
            let dict = (value as? [[String: Any]])?.first ?? value as? [String: Any]
            guard let dict else { return nil }
            let name = dict["key_code"] as? String ?? dict["apple_vendor_top_case_key_code"] as? String
            return name.flatMap { Keys.info(karabiner: $0 == "fn" ? "keyboard_fn" : $0) }
        }

        var remaps: [KeyRemap] = []
        var skipped = 0
        for modification in simple {
            if let from = key(modification["from"]), let to = key(modification["to"]) {
                remaps.append(KeyRemap(from: from.usage, to: to.usage))
            } else {
                skipped += 1
            }
        }
        return (remaps, skipped)
    }
}
