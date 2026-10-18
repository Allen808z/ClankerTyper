import Foundation

/// Appends one line per event to ~/Library/Logs/ClankerTyper/clanker.log, for diagnosing what the app
/// actually did when a key was pressed.
enum AppLog {
    static func write(_ message: String) {
        guard let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/ClankerTyper", isDirectory: true) else { return }
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appendingPathComponent("clanker.log")
        let entry = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? entry.write(to: file, atomically: true, encoding: .utf8)
        }
    }
}
