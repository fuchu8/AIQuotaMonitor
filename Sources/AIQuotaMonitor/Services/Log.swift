import Foundation

/// 轻量本地日志：只记录运行状态与错误原因，绝不记录任何凭据、Token 或 Cookie。
enum AppLog {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AIQuotaMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("app.log")
    }()

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    static func write(_ message: String) {
        let line = "[\(stamp.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
        trimIfNeeded()
    }

    /// 超过 200KB 时只保留末尾一半，避免日志无限增长
    private static func trimIfNeeded() {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              size > 200_000,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let half = text.suffix(text.count / 2)
        try? String(half).write(to: url, atomically: true, encoding: .utf8)
    }
}
