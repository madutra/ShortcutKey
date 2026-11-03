import AppKit

/// O que está tocando no Spotify (ou no app Música). As informações chegam pelos avisos que os próprios
/// players publicam a cada troca de música ou de play/pause; os comandos vão por AppleScript.
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
    @Published private(set) var track: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var artwork: NSImage?
    /// Posição conhecida e quando ela foi lida; a posição atual é calculada a partir daqui.
    @Published private(set) var position: (seconds: Double, at: Date) = (0, Date())

    private var started = false
    private var artworkTrackID: String?

    func currentPosition(at date: Date = Date()) -> Double {
        let elapsed = isPlaying ? date.timeIntervalSince(position.at) : 0
        let value = position.seconds + elapsed
        guard let duration = track?.duration, duration > 0 else { return value }
        return min(value, duration)
    }

    func start() {
        guard !started else { return }
        started = true
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

    func playPause() { send("playpause") }
    func next() { send("next track") }
    func previous() { send("previous track") }

    func openPlayer() {
        guard let player, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.rawValue) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Lê a música atual direto do player (na primeira vez que o notch abre, antes de qualquer aviso chegar).
    func refreshIfNeeded() {
        guard track == nil else { return }
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
        guard let info else { return }
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
        track = nil
        isPlaying = false
        artwork = nil
        artworkTrackID = nil
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
