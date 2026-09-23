import Foundation

/// Log simples em ~/Library/Logs/ShortcutKey.log, para diagnosticar problemas.
enum Log {
    private static let queue = DispatchQueue(label: "ShortcutKey.log")
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ShortcutKey.log")

    static func write(_ message: String) {
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
