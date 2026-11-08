import Foundation

/// 与本地 `codex app-server` 通信的极简 JSON-RPC over stdio 客户端。
///
/// 只调用账户与用量读取接口，不会触发任何模型推理，因此不产生 Token 费用。
/// 不读取、不记录 auth.json，也不打印任何凭据。
final class CodexClient {

    /// 单次会话的硬超时。app-server 启动 + 两个后端查询一般 1~3 秒。
    private let timeout: TimeInterval = 20

    // MARK: - 二进制定位

    private static var cachedBinary: String?
    private static var cachedAt: Date?

    static func locateBinary() -> String? {
        if let cachedBinary, let cachedAt, Date().timeIntervalSince(cachedAt) < 3600 {
            return cachedBinary
        }
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            cachedBinary = path
            cachedAt = Date()
            return path
        }
        if let found = shellWhich("codex"), FileManager.default.isExecutableFile(atPath: found) {
            cachedBinary = found
            cachedAt = Date()
            return found
        }
        return nil
    }

    private static func shellWhich(_ name: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "command -v \(name)"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(6)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning { proc.terminate() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { return nil }
        return text.components(separatedBy: "\n").last
    }

    // MARK: - 拉取

    /// `includeUsage` 为 false 时不请求逐日 Token。额度窗口比用量统计变得勤，没必要每次都等它。
    func fetch(includeUsage: Bool = true) async throws -> CodexSnapshot {
        guard let binary = Self.locateBinary() else {
            throw ProviderError.notInstalled("未找到 codex 可执行文件")
        }
        let limit = timeout
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let raw = try Self.runSession(binary: binary, timeout: limit, includeUsage: includeUsage)
                    cont.resume(returning: try Self.parse(raw))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - 底层会话

    private static func runSession(binary: String, timeout: TimeInterval, includeUsage: Bool) throws -> [String: Any] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = ["app-server"]
        proc.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())

        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        proc.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            throw ProviderError.spawnFailed(error.localizedDescription)
        }

        let lock = NSLock()
        var buffer = Data()
        var streamClosed = false

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock()
            if chunk.isEmpty {
                streamClosed = true
            } else {
                buffer.append(chunk)
            }
            lock.unlock()
        }

        defer {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            if proc.isRunning { proc.terminate() }
            let deadline = Date().addingTimeInterval(2)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
        }

        let version = AppVersion.short
        let initReq: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["clientInfo": ["name": "ai-quota-monitor", "version": version],
                       "capabilities": ["experimentalApi": true]]
        ]

        let input = stdinPipe.fileHandleForWriting
        guard let initData = try? JSONSerialization.data(withJSONObject: initReq),
              var initLine = String(data: initData, encoding: .utf8) else {
            throw ProviderError.rpc("无法构造 initialize 请求")
        }
        initLine += "\n"
        input.write(Data(initLine.utf8))

        // 先等 initialize 成功，再发后续请求，避免依赖版本碰巧接受连续写入的时序
        let initDeadline = Date().addingTimeInterval(min(8, timeout))
        var initOK = false
        var initError: String?
        while Date() < initDeadline {
            lock.lock()
            let snapshotData = buffer
            let closed = streamClosed
            lock.unlock()
            if let text = String(data: snapshotData, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          let id = obj["id"] as? Int, id == 1 else { continue }
                    if obj["error"] != nil {
                        initError = errorMessage(obj)
                    } else if obj["result"] != nil {
                        initOK = true
                    }
                }
            }
            if initOK || initError != nil || closed { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard initOK else {
            throw ProviderError.rpc(initError ?? "app-server 初始化失败")
        }

        var requests: [[String: Any]] = [
            ["jsonrpc": "2.0", "method": "initialized", "params": [:] as [String: Any]],
            ["jsonrpc": "2.0", "id": 2, "method": "account/read", "params": [:] as [String: Any]],
            ["jsonrpc": "2.0", "id": 3, "method": "account/rateLimits/read",
             "params": ["excludeResetCreditDetails": true]]
        ]
        if includeUsage {
            requests.append(["jsonrpc": "2.0", "id": 4, "method": "account/usage/read", "params": [:] as [String: Any]])
        }

        for req in requests {
            guard let data = try? JSONSerialization.data(withJSONObject: req),
                  var line = String(data: data, encoding: .utf8) else { continue }
            line += "\n"
            input.write(Data(line.utf8))
        }

        let deadline = Date().addingTimeInterval(timeout)
        var responses: [Int: [String: Any]] = [:]
        var rateLimitSeenAt: Date?

        while Date() < deadline {
            lock.lock()
            let snapshotData = buffer
            let closed = streamClosed
            lock.unlock()

            if let text = String(data: snapshotData, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          let id = obj["id"] as? Int else { continue }
                    responses[id] = obj
                }
            }
            if responses[3] != nil {
                if rateLimitSeenAt == nil { rateLimitSeenAt = Date() }
                if !includeUsage || responses[4] != nil { break }
                if let rateLimitSeenAt, Date().timeIntervalSince(rateLimitSeenAt) > 6 { break }
            }
            if closed && responses[3] == nil { break }
            Thread.sleep(forTimeInterval: 0.08)
        }

        guard responses[3] != nil else {
            if let err = responses[2]?["error"] {
                let msg = Self.errorMessage(["error": err])
                throw ProviderError.notLoggedIn(msg)
            }
            throw ProviderError.timeout
        }

        var merged: [String: Any] = [:]
        if let account = responses[2]?["result"] as? [String: Any] { merged["account"] = account }
        if let rate = responses[3]?["result"] as? [String: Any] { merged["rate"] = rate }
        if let usage = responses[4]?["result"] as? [String: Any] { merged["usage"] = usage }
        if let err = responses[3]?["error"] { merged["rateError"] = Self.errorMessage(err as? [String: Any] ?? [:]) }
        return merged
    }

    private static func errorMessage(_ obj: [String: Any]) -> String {
        guard let err = obj["error"] as? [String: Any] else { return "接口无返回" }
        if let msg = err["message"] as? String { return friendly(msg) }
        if let data = err["data"] as? [String: Any], let msg = data["message"] as? String {
            return friendly(msg)
        }
        if let code = err["code"] as? Int { return "接口错误（code \(code)）" }
        return "接口错误"
    }

    /// 白名单化后端错误，避免把原始长文案当脱敏结果。
    private static func friendly(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("not logged") || lower.contains("unauthorized")
            || lower.contains("authentication") || lower.contains("login")
            || lower.contains("no account") || lower.contains("missing auth") {
            return "Codex 未登录，请在终端运行 codex login"
        }
        if lower.contains("timeout") || lower.contains("timed out") { return "读取超时" }
        if lower.contains("network") || lower.contains("connection") || lower.contains("offline") {
            return "网络不可用"
        }
        if lower.contains("rate limit") { return "接口限流" }
        return "Codex 接口错误"
    }

    // MARK: - 解析

    static func parse(_ raw: [String: Any]) throws -> CodexSnapshot {
        var snap = CodexSnapshot()
        let now = Date()
        snap.fetchedAt = now

        let accountResponse = raw["account"] as? [String: Any]
        let accountInfo = accountResponse?["account"] as? [String: Any]
        if let accountInfo {
            snap.accountType = accountInfo["type"] as? String
            snap.email = accountInfo["email"] as? String
            snap.planType = accountInfo["planType"] as? String
            snap.workspaceName = accountInfo["workspaceName"] as? String
        }

        guard let rate = raw["rate"] as? [String: Any] else {
            snap.origin = .unavailable
            if accountResponse != nil && accountInfo == nil {
                snap.errorMessage = "Codex 未登录，请在终端运行 codex login"
            } else {
                snap.errorMessage = (raw["rateError"] as? String) ?? "额度接口无返回"
            }
            return snap
        }

        snap.origin = .codexAppServer
        snap.ordinaryUsageAllowed = rate["ordinaryUsageAllowed"] as? Bool

        // 保留 limitId 身份；多池按 id 排序仅影响展示顺序，不用于去重
        let namedBuckets: [(id: String, body: [String: Any])]
        if let byId = rate["rateLimitsByLimitId"] as? [String: Any], !byId.isEmpty {
            namedBuckets = byId
                .compactMap { key, value -> (String, [String: Any])? in
                    guard let body = value as? [String: Any] else { return nil }
                    return (key, body)
                }
                .sorted { $0.0 < $1.0 }
        } else if let single = rate["rateLimits"] as? [String: Any] {
            let id = (single["limitId"] as? String) ?? "default"
            namedBuckets = [(id, single)]
        } else {
            namedBuckets = []
        }

        // Credits / 限流：优先带 credits 字段的池，其次 id 含 default/chatgpt 的池，再退回主池
        let creditsBucket = namedBuckets.first(where: { ($0.body["credits"] as? [String: Any]) != nil })
            ?? namedBuckets.first(where: {
                let id = ($0.body["limitId"] as? String) ?? $0.id
                let lower = id.lowercased()
                return lower.contains("default") || lower.contains("chatgpt") || lower.contains("primary")
            })
            ?? namedBuckets.first

        if let creditsBucket {
            snap.creditsLimitId = (creditsBucket.body["limitId"] as? String) ?? creditsBucket.id
            if let credits = (creditsBucket.body["credits"] as? [String: Any])
                ?? (rate["credits"] as? [String: Any]) {
                snap.hasCredits = credits["hasCredits"] as? Bool ?? false
                snap.unlimitedCredits = credits["unlimited"] as? Bool ?? false
                snap.creditsBalance = credits["balance"] as? String
            }
            snap.rateLimitReachedType = creditsBucket.body["rateLimitReachedType"] as? String
        } else if let credits = rate["credits"] as? [String: Any] {
            snap.hasCredits = credits["hasCredits"] as? Bool ?? false
            snap.unlimitedCredits = credits["unlimited"] as? Bool ?? false
            snap.creditsBalance = credits["balance"] as? String
        }
        if let reset = rate["rateLimitResetCredits"] as? [String: Any] {
            snap.resetCreditsAvailable = reset["availableCount"] as? Int
        }

        var windows: [QuotaWindow] = []
        var missingPercent = false

        for entry in namedBuckets {
            let limitId = (entry.body["limitId"] as? String) ?? entry.id
            let limitName = entry.body["limitName"] as? String
            for (index, slot) in ["primary", "secondary"].enumerated() {
                guard let win = entry.body[slot] as? [String: Any] else { continue }
                guard let used = number(win["usedPercent"]) else {
                    // 字段缺失/类型错误：不算满额，记解析问题
                    missingPercent = true
                    continue
                }
                let mins = win["windowDurationMins"] as? Int
                    ?? (win["windowDurationMins"] as? NSNumber)?.intValue
                let resets = number(win["resetsAt"]).map { Date(timeIntervalSince1970: $0) }
                let durationTitle = QuotaWindow.title(forDuration: mins)
                let title: String = {
                    if let limitName, !limitName.isEmpty, namedBuckets.count > 1 {
                        return "\(limitName) · \(durationTitle)"
                    }
                    if let limitName, !limitName.isEmpty, durationTitle == "额度窗口" {
                        return limitName
                    }
                    return durationTitle
                }()
                windows.append(QuotaWindow(
                    id: "\(limitId)-\(slot)",
                    title: title,
                    usedPercent: max(0, min(100, used)),
                    resetsAt: resets,
                    durationMins: mins,
                    limitId: limitId
                ))
                _ = index
            }
        }

        // 按窗口长度升序（短的在前），未知长度放最后
        windows.sort { ($0.durationMins ?? Int.max) < ($1.durationMins ?? Int.max) }

        // 仅按 limitId + primary/secondary 身份去重（不做跨池数值去重）
        var seen = Set<String>()
        windows = windows.filter { win in
            if seen.contains(win.id) { return false }
            seen.insert(win.id)
            return true
        }
        snap.windows = windows

        if let usage = raw["usage"] as? [String: Any] {
            if let summary = usage["summary"] as? [String: Any] {
                snap.lifetimeTokens = (summary["lifetimeTokens"] as? NSNumber)?.int64Value
                snap.peakDailyTokens = (summary["peakDailyTokens"] as? NSNumber)?.int64Value
            }
            if let buckets = usage["dailyUsageBuckets"] as? [[String: Any]] {
                snap.dailyBuckets = buckets.compactMap { row in
                    guard let date = row["startDate"] as? String,
                          let tokens = (row["tokens"] as? NSNumber)?.int64Value else { return nil }
                    return DailyTokenBucket(startDate: date, tokens: tokens)
                }
                .sorted { $0.startDate < $1.startDate }
            }
            if !snap.dailyBuckets.isEmpty || snap.lifetimeTokens != nil {
                snap.tokenSuccessAt = now
            }
        }

        if windows.isEmpty {
            snap.origin = .unavailable
            if missingPercent {
                snap.errorMessage = "额度窗口缺少已用百分比"
            } else if snap.accountType == "apiKey" {
                snap.errorMessage = "当前是 API Key 登录，没有订阅额度可读"
            } else if accountInfo == nil {
                snap.errorMessage = "Codex 未登录，请在终端运行 codex login"
            } else {
                snap.errorMessage = "接口未返回任何额度窗口"
            }
        } else {
            snap.quotaSuccessAt = now
            if missingPercent {
                snap.errorMessage = "部分窗口缺少已用百分比，已跳过"
            }
        }
        return snap
    }

    private static func number(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        return nil
    }
}
