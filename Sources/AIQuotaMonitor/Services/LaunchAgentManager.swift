import Foundation

/// 开机自启：用户级 LaunchAgent，不需要管理员权限，也不改动系统级目录。
enum LaunchAgentManager {
    static let label = "com.skye.aiquotamonitor"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func enable() throws {
        let appPath = Bundle.main.bundlePath
        guard appPath.hasSuffix(".app") else {
            throw ProviderError.io("当前不是以 .app 方式运行，无法设置开机启动")
        }
        let dir = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-a", appPath],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                     format: .xml,
                                                     options: 0)
        try data.write(to: plistURL, options: .atomic)
    }

    static func disable() {
        try? FileManager.default.removeItem(at: plistURL)
    }
}
