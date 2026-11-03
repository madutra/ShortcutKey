import AppKit

/// O que está tocando. Pelo "Tocando Agora" do macOS (qualquer app, inclusive YouTube no navegador),
/// com a ponte em Helpers/MediaRemoteBridge.c. Se a ponte não funcionar, cai para o Spotify e o Música:
/// as informações chegam pelos avisos desses players e os comandos vão por AppleScript.
final class NowPlaying: ObservableObject {
    static let shared = NowPlaying()

    enum Player: String {
        case spotify = "com.spotify.client"
        case music = "com.apple.Music"

        var name: String { self == .spotify ? "Spotify" : "Música" }
        var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: rawValue).isEmpty }
    }

    struct Track: Equatable {
        var title: String
        var artist: String
        var album: String
        var id: String
        /// Em segundos (0 = desconhecida).
        var duration: Double
    }

    @Published private(set) var player: Player?
    /// App que está tocando, quando vem do "Tocando Agora" do macOS.
    @Published private(set) var sourceApp: NSRunningApplication?
    @Published private(set) var track: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var artwork: NSImage?
    /// Posição conhecida e quando ela foi lida; a posição atual é calculada a partir daqui.
    @Published private(set) var position: (seconds: Double, at: Date) = (0, Date())

    private var started = false
    private var artworkTrackID: String?
    private let bridge = MediaRemoteBridge()
    /// A ponte está funcionando: ela manda em tudo e os avisos do Spotify/Música são ignorados.
    private var usingBridge = false

    var sourceName: String? { sourceApp?.localizedName ?? player?.name }
    var canOpenPlayer: Bool { sourceApp != nil || player != nil }

    func currentPosition(at date: Date = Date()) -> Double {
        let elapsed = isPlaying ? date.timeIntervalSince(position.at) : 0
        let value = position.seconds + elapsed
        guard let duration = track?.duration, duration > 0 else { return value }
        return min(value, duration)
    }

    func start() {
        guard !started else { return }
        started = true
        bridge.onUpdate = { [weak self] info in self?.receivedFromBridge(info) }
        bridge.onStop = { [weak self] in
            guard let self, self.usingBridge else { return }
            self.usingBridge = false
            self.clear()
        }
        bridge.start()
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { [weak self] note in
            self?.received(note.userInfo, from: .spotify)
        }
        center.addObserver(forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] note in
            self?.received(note.userInfo, from: .music)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let self, app?.bundleIdentifier == self.player?.rawValue { self.clear() }
        }
    }

    // MARK: Comandos

    func playPause() {
        // Troca o ícone na hora; a confirmação do player chega logo depois.
        position = (currentPosition(), Date())
        isPlaying.toggle()
        usingBridge ? bridge.send(.togglePlayPause) : send("playpause")
    }
    func next() { usingBridge ? bridge.send(.next) : send("next track") }
    func previous() { usingBridge ? bridge.send(.previous) : send("previous track") }

    func openPlayer() {
        if let sourceApp {
            sourceApp.activate()
            return
        }
        guard let player, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.rawValue) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Lê a música atual direto do player (na primeira vez que o notch abre, antes de qualquer aviso chegar).
    func refreshIfNeeded() {
        guard track == nil, !usingBridge else { return }
        let target: Player? = Player.spotify.isRunning ? .spotify : Player.music.isRunning ? .music : nil
        guard let target else { return }
        let script = """
        tell application id "\(target.rawValue)"
            if player state is stopped then return {}
            set t to current track
            return {name of t, artist of t, album of t, (id of t) as text, (duration of t) as text, (player position) as text, (player state) as text}
        end tell
        """
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let result = Self.run(script), result.numberOfItems >= 7 else { return }
            let values = (1...7).map { result.atIndex($0)?.stringValue ?? "" }
            DispatchQueue.main.async {
                guard let self, self.track == nil else { return }
                // O Spotify dá a duração em milissegundos; o Música, em segundos.
                let rawDuration = Double(values[4].replacingOccurrences(of: ",", with: ".")) ?? 0
                self.update(player: target,
                            track: Track(title: values[0], artist: values[1], album: values[2], id: values[3],
                                         duration: target == .spotify ? rawDuration / 1000 : rawDuration),
                            playing: values[6].lowercased().contains("play"),
                            position: Double(values[5].replacingOccurrences(of: ",", with: ".")) ?? 0)
            }
        }
    }

    private func send(_ command: String) {
        guard let player, player.isRunning else { return }
        let script = "tell application id \"\(player.rawValue)\" to \(command)"
        DispatchQueue.global(qos: .userInitiated).async { _ = Self.run(script) }
    }

    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { Log.write("notch: AppleScript falhou: \(error[NSAppleScript.errorMessage] ?? error)") }
        return result
    }

    // MARK: Avisos dos players

    private func received(_ info: [AnyHashable: Any]?, from source: Player) {
        guard let info, !usingBridge else { return }
        let state = info["Player State"] as? String ?? ""
        if state == "Stopped" {
            if player == source { clear() }
            return
        }
        // Um player pausado não toma o lugar de outro que está tocando.
        if player != nil, player != source, isPlaying, state != "Playing" { return }

        let duration: Double
        if source == .spotify {
            duration = (info["Duration"] as? Double ?? 0) / 1000
        } else {
            duration = (info["Total Time"] as? Double ?? 0) / 1000
        }
        let id = info["Track ID"] as? String ?? (info["PersistentID"] as? NSNumber)?.stringValue
            ?? "\(info["Name"] ?? "")-\(info["Artist"] ?? "")"
        let track = Track(title: info["Name"] as? String ?? "",
                          artist: info["Artist"] as? String ?? "",
                          album: info["Album"] as? String ?? "",
                          id: id,
                          duration: duration)
        let newPosition = info["Playback Position"] as? Double
            ?? (track.id == self.track?.id ? currentPosition() : 0)
        update(player: source, track: track, playing: state == "Playing", position: newPosition)
    }

    private func update(player: Player, track: Track, playing: Bool, position: Double) {
        self.player = player
        if self.track != track { self.track = track }
        isPlaying = playing
        self.position = (position, Date())
        loadArtwork(for: track, player: player)
    }

    private func clear() {
        player = nil
        sourceApp = nil
        track = nil
        isPlaying = false
        artwork = nil
        artworkTrackID = nil
    }

    // MARK: "Tocando Agora" do macOS

    private func receivedFromBridge(_ info: [String: Any]) {
        usingBridge = true
        let title = info["title"] as? String ?? ""
        guard !title.isEmpty else {
            // Sem informações e sem nada tocando = parou. Se ainda está tocando, as informações vêm já já.
            if info["playing"] as? Bool != true { clear() } else { isPlaying = true }
            return
        }
        let artist = info["artist"] as? String ?? ""
        let track = Track(title: title, artist: artist, album: info["album"] as? String ?? "",
                          id: "\(title)\u{1}\(artist)", duration: info["duration"] as? Double ?? 0)
        let rate = info["rate"] as? Double ?? 0
        // A velocidade (0 = pausado) é mais confiável que o aviso de "tocando", que às vezes atrasa.
        let playing = info["rate"] != nil ? rate > 0 : info["playing"] as? Bool ?? false
        // O tempo vem "parado" no instante em que foi lido; soma o que passou desde então.
        var elapsed = info["elapsed"] as? Double ?? 0
        if let timestamp = info["timestamp"] as? Double, timestamp > 0, playing, rate > 0 {
            elapsed += max(0, Date().timeIntervalSince1970 - timestamp) * rate
        }

        player = nil
        sourceApp = (info["pid"] as? Int).flatMap { Self.app(forPID: pid_t($0)) }
        if self.track != track { self.track = track }
        isPlaying = playing
        position = (elapsed, Date())
        if let encoded = info["artwork"] as? String {
            artworkTrackID = track.id
            artwork = encoded.isEmpty ? nil : Data(base64Encoded: encoded).flatMap(NSImage.init(data:))

        } else if artworkTrackID != track.id {
            artworkTrackID = track.id
            artwork = nil
        }
    }

    /// O som de um navegador costuma vir de um processo auxiliar: procura o app "de verdade".
    private static func app(forPID pid: pid_t) -> NSRunningApplication? {
        guard pid > 0, let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        if app.activationPolicy == .regular { return app }
        let path = app.bundleURL?.path ?? ""
        return NSWorkspace.shared.runningApplications.first { other in
            guard other.activationPolicy == .regular, let base = other.bundleURL?.path else { return false }
            return path.hasPrefix(base + "/")
        } ?? app
    }

    // MARK: Capa

    /// A capa do Spotify vem do link público da música (oEmbed); sem conta nem permissão.
    private func loadArtwork(for track: Track, player: Player) {
        guard artworkTrackID != track.id else { return }
        artworkTrackID = track.id
        artwork = nil
        guard player == .spotify, track.id.hasPrefix("spotify:track:") else { return }
        let trackURL = "https://open.spotify.com/track/" + track.id.dropFirst("spotify:track:".count)
        var components = URLComponents(string: "https://open.spotify.com/oembed")!
        components.queryItems = [URLQueryItem(name: "url", value: trackURL)]
        guard let url = components.url else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let thumbnail = (json["thumbnail_url"] as? String).flatMap(URL.init(string:)) else { return }
            URLSession.shared.dataTask(with: thumbnail) { data, _, _ in
                guard let data, let image = NSImage(data: data) else { return }
                DispatchQueue.main.async {
                    guard let self, self.artworkTrackID == track.id else { return }
                    self.artwork = image
                }
            }.resume()
        }.resume()
    }
}

/// Roda a ponte do "Tocando Agora" dentro do perl do sistema e lê o que ela escreve.
private final class MediaRemoteBridge {
    enum Command: Int32 {
        case togglePlayPause = 2
        case next = 4
        case previous = 5
    }

    var onUpdate: (([String: Any]) -> Void)?
    var onStop: (() -> Void)?

    private var process: Process?
    private var buffer = Data()
    private var failures = 0

    private static let loader = "use DynaLoader; DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();"
    private static var library: String? {
        Bundle.main.path(forResource: "MediaRemoteBridge", ofType: "dylib")
    }

    func start() {
        guard process == nil, let library = Self.library else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", Self.loader, library]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.received(data) }
        }
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async { self?.stopped(status: finished.terminationStatus) }
        }
        do {
            try process.run()
            self.process = process
            Log.write("tocando: ponte iniciada")
        } catch {
            Log.write("tocando: ponte não iniciou: \(error)")
        }
    }

    func send(_ command: Command) {
        guard let library = Self.library else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", Self.loader, library]
        process.environment = ["SK_MR_COMMAND": String(command.rawValue)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private func received(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                failures = 0
                onUpdate?(json)
            }
        }
    }

    private func stopped(status: Int32) {
        process?.standardOutput.flatMap { ($0 as? Pipe)?.fileHandleForReading.readabilityHandler = nil }
        process = nil
        buffer.removeAll()
        failures += 1
        Log.write("tocando: ponte parou (\(status))")
        onStop?()
        // Tenta de novo algumas vezes (ex.: depois de o Mac acordar); se nunca funcionar, fica no Spotify/Música.
        guard failures <= 3 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(failures) * 5) { [weak self] in self?.start() }
    }
}
