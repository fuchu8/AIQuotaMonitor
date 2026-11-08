import Foundation

/// 主程序写入、小组件只读的脱敏快照。
/// 禁止包含 JWT、API Key、邮箱、原始日志路径或请求正文。
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var updatedAt: Date
    public var refreshMinutes: Int
    public var stale: Bool
    public var note: String
    public var items: [Item]

    public struct Item: Codable, Equatable, Identifiable, Sendable {
        public var id: String
        public var title: String
        public var remainingPercent: Double?
        public var usedPercent: Double?
        public var windowTitle: String?
        public var resetsAt: Date?
        public var stale: Bool
        public var error: String?
        public var subtitle: String?

        public init(
            id: String,
            title: String,
            remainingPercent: Double? = nil,
            usedPercent: Double? = nil,
            windowTitle: String? = nil,
            resetsAt: Date? = nil,
            stale: Bool = false,
            error: String? = nil,
            subtitle: String? = nil
        ) {
            self.id = id
            self.title = title
            self.remainingPercent = remainingPercent
            self.usedPercent = usedPercent
            self.windowTitle = windowTitle
            self.resetsAt = resetsAt
            self.stale = stale
            self.error = error
            self.subtitle = subtitle
        }
    }

    public init(
        schemaVersion: Int = 1,
        updatedAt: Date = Date(),
        refreshMinutes: Int = 5,
        stale: Bool = false,
        note: String = "",
        items: [Item] = []
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.refreshMinutes = refreshMinutes
        self.stale = stale
        self.note = note
        self.items = items
    }

    public static let empty = WidgetSnapshot(
        note: "等待主程序刷新",
        items: [
            Item(id: "codex", title: "Codex"),
            Item(id: "cursor", title: "Cursor"),
            Item(id: "go", title: "OpenCode Go"),
            Item(id: "grok", title: "Grok Bot")
        ]
    )
}

public enum WidgetSnapshotPaths {
    /// App Group（需要开发者账号启用后才可用）。主程序与扩展共用。
    public static let appGroupID = "group.com.skye.aiquotamonitor"
    public static let fileName = "widget-snapshot.json"
    public static let openURL = URL(string: "aiquotamonitor://open")!

    /// 主程序 Application Support 回退路径（扩展沙盒通常读不到，仅供主程序/诊断）。
    public static var appSupportFile: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AIQuotaMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent(fileName)
    }

    public static var appGroupFile: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(fileName)
    }
}

public enum WidgetSnapshotStore {
    public static func save(_ snapshot: WidgetSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }

        try? data.write(to: WidgetSnapshotPaths.appSupportFile, options: .atomic)
        if let group = WidgetSnapshotPaths.appGroupFile {
            try? FileManager.default.createDirectory(
                at: group.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: group, options: .atomic)
        }
    }

    public static func load() -> WidgetSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let candidates = [
            WidgetSnapshotPaths.appGroupFile,
            WidgetSnapshotPaths.appSupportFile
        ].compactMap { $0 }
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let snap = try? decoder.decode(WidgetSnapshot.self, from: data) else { continue }
            return snap
        }
        return nil
    }

    /// 供测试与主程序：从额度窗口生成脱敏条目。
    public static func item(
        id: String,
        title: String,
        windowTitle: String?,
        remaining: Double?,
        used: Double?,
        resetsAt: Date?,
        stale: Bool,
        error: String?,
        subtitle: String? = nil
    ) -> WidgetSnapshot.Item {
        // 二次 scrub：错误文案去掉疑似邮箱 / token 片段
        let cleaned = error.map(scrub)
        return WidgetSnapshot.Item(
            id: id,
            title: title,
            remainingPercent: remaining.map { max(0, min(100, $0)) },
            usedPercent: used.map { max(0, min(100, $0)) },
            windowTitle: windowTitle,
            resetsAt: resetsAt,
            stale: stale,
            error: cleaned,
            subtitle: subtitle
        )
    }

    public static func scrub(_ text: String) -> String {
        var out = text
        // 邮箱
        if let regex = try? NSRegularExpression(pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, options: .caseInsensitive) {
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "[redacted]")
        }
        // JWT 形态
        if let regex = try? NSRegularExpression(pattern: #"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#) {
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "[redacted]")
        }
        // oc_ 密钥前缀
        if let regex = try? NSRegularExpression(pattern: #"oc_[A-Za-z0-9]+"#) {
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "[redacted]")
        }
        if out.count > 80 { out = String(out.prefix(80)) + "…" }
        return out
    }
}
