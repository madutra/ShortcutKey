import AppKit
import AudioToolbox
import CoreAudio

/// Volume e brilho mudados pelas teclas do teclado, para o notch mostrar no lugar do aviso do macOS.
final class SystemLevels {
    static let shared = SystemLevels()

    enum Kind { case volume, brightness }

    /// Na thread principal: o que mudou, o nível (0 a 1) e se o som está mudo.
    var onChange: ((Kind, Float, Bool) -> Void)?

    // Teclas especiais (NX_KEYTYPE_*), que chegam como eventos "de sistema".
    private enum MediaKey: Int {
        case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
    }

    private var swallowed: Set<Int> = []
    private static let systemDefinedType = CGEventType(rawValue: 14)!
    static var eventMask: CGEventMask { 1 << systemDefinedType.rawValue }

    /// Chamado pelo event tap. Retorna `true` se a tecla foi tratada aqui (e o aviso do macOS não deve aparecer).
    func handle(_ event: CGEvent, type: CGEventType) -> Bool {
        guard type == Self.systemDefinedType, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return false }
        let code = (ns.data1 & 0xFFFF0000) >> 16
        let isDown = ((ns.data1 & 0xFF00) >> 8) == 0xA
        guard let key = MediaKey(rawValue: code) else { return false }

        let notch = SettingsStore.shared.current.notch
        guard notch.enabled, notch.levels else { return false }
        // A tecla solta não faz nada, mas também não pode chegar ao macOS se a apertada não chegou.
        guard isDown else { return swallowed.remove(code) != nil }

        // Só troca o aviso do macOS quando consegue mudar o nível sozinho (ex.: sem tela embutida, o
        // brilho de um monitor externo continua com o macOS).
        let isVolume = key == .soundUp || key == .soundDown || key == .mute
        let replace = notch.replaceSystemHUD && (isVolume ? Self.volume != nil : Self.brightness != nil)
        if replace { swallowed.insert(code) }

        let fine = ns.modifierFlags.contains([.shift, .option]) // ⇧⌥ = passos menores, como no macOS
        let step: Float = fine ? 1 / 64 : 1 / 16
        switch key {
        case .soundUp, .soundDown, .mute:
            if replace {
                if key == .mute {
                    Self.setMuted(!Self.isMuted)
                } else {
                    Self.setMuted(false)
                    Self.setVolume((Self.volume ?? 0) + (key == .soundUp ? step : -step))
                }
            }
            report(.volume, after: replace ? 0 : 0.06)
        case .brightnessUp, .brightnessDown:
            if replace, let current = Self.brightness {
                Self.setBrightness(current + (key == .brightnessUp ? step : -step))
            }
            report(.brightness, after: replace ? 0 : 0.08)
        }
        return replace
    }

    /// Lê o nível depois que o macOS aplicou a mudança (quando ele mesmo trata a tecla).
    private func report(_ kind: Kind, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            switch kind {
            case .volume: self?.onChange?(.volume, Self.volume ?? 0, Self.isMuted)
            case .brightness: self?.onChange?(.brightness, Self.brightness ?? 0, false)
            }
        }
    }

    // MARK: Volume (CoreAudio)

    private static var outputDevice: AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

    private static var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

    static var volume: Float? {
        guard let device = outputDevice else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func setVolume(_ value: Float) {
        guard let device = outputDevice else { return }
        var level = Float32(min(max(value, 0), 1))
        AudioObjectSetPropertyData(device, &volumeAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &level)
    }

    /// Nome da saída de som (ex.: "Alto-falantes do MacBook Air", "AirPods").
    static var outputName: String? {
        guard let device = outputDevice else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    static var isMuted: Bool {
        guard let device = outputDevice else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &value) == noErr && value != 0
    }

    static func setMuted(_ muted: Bool) {
        guard let device = outputDevice else { return }
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(device, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    // MARK: Brilho (tela embutida)

    /// O brilho da tela do Mac não tem API pública; são as mesmas funções que os Ajustes usam.
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getBrightness: GetBrightness? = displayServices.flatMap { dlsym($0, "DisplayServicesGetBrightness") }
        .map { unsafeBitCast($0, to: GetBrightness.self) }
    private static let setBrightnessFn: SetBrightness? = displayServices.flatMap { dlsym($0, "DisplayServicesSetBrightness") }
        .map { unsafeBitCast($0, to: SetBrightness.self) }

    private static var builtInDisplay: CGDirectDisplayID {
        var displays = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(8, &displays, &count)
        return displays.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
    }

    static var brightness: Float? {
        var value: Float = 0
        guard let getBrightness, getBrightness(builtInDisplay, &value) == 0 else { return nil }
        return value
    }

    static func setBrightness(_ value: Float) {
        _ = setBrightnessFn?(builtInDisplay, min(max(value, 0), 1))
    }
}
