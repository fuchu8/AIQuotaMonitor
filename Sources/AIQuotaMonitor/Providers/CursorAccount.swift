import Foundation
import CommonCrypto

/// Cursor 账户用量。读的是本机已有登录态，只用来查询当前账号的两个模型池和 Token。
/// 不把令牌写入日志、配置或历史库。接口为账户 DashboardService，非公开稳定 API。
enum CursorAccount {
    struct Quota: Sendable {
        var windows: [QuotaWindow] = []
        var todayTokens: Int64?
        var periodTokens: Int64?
        var lifetimeTokens: Int64?
        /// 累计实际覆盖说明
        var lifetimeNote: String = "近 90 天"
        var quotaOK: Bool = false
        var tokenOK: Bool = false
        var tokenError: String?
        var error: String?
    }

    private static let usageURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!
    private static let aggregatedURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetAggregatedUsageEvents")!

    /// 供 Grok Bot 等共用同一套本机登录态，不落盘。
    static func accessToken() async -> String? {
        await CursorAuthCache.shared.token(reader: { readTokenSync() })
    }

    static func invalidateAuth() async {
        await CursorAuthCache.shared.invalidate()
    }

    static func fetch() async -> Quota {
        guard let token = await accessToken() else {
            return Quota(error: "登录态不可用。请确认 Cursor 已登录，或在设置中稍后重试。")
        }
        do {
            async let usageTask = post(usageURL, token: token, body: [:])
            async let periodTask = post(aggregatedURL, token: token, body: [:])
            async let todayTask = post(aggregatedURL, token: token, body: todayRange())
            async let lifeTask = post(aggregatedURL, token: token, body: lifetimeRange())

            let usage = try await usageTask
            var quota = parseWindows(usage)
            if quota.windows.isEmpty, quota.error == nil {
                return Quota(error: "Cursor 没有返回模型池用量")
            }
            quota.quotaOK = !quota.windows.isEmpty

            var tokenError: String?
            var anyToken = false
            do {
                let period = try await periodTask
                quota.periodTokens = tokenTotal(period)
                anyToken = true
            } catch {
                tokenError = "本周期 Token 读取失败"
            }
            do {
                let today = try await todayTask
                quota.todayTokens = tokenTotal(today)
                anyToken = true
            } catch {
                if tokenError == nil { tokenError = "今日 Token 读取失败" }
            }
            do {
                let life = try await lifeTask
                // 近 90 天；失败时绝不回退为本周期冒充累计
                quota.lifetimeTokens = tokenTotal(life)
                quota.lifetimeNote = "近 90 天"
                anyToken = true
            } catch {
                quota.lifetimeTokens = nil
                if tokenError == nil { tokenError = "近 90 天 Token 读取失败" }
            }
            quota.tokenOK = anyToken && tokenError == nil
            quota.tokenError = tokenError
            return quota
        } catch let error as ProviderError {
            if case .notLoggedIn = error {
                await invalidateAuth()
            }
            return Quota(error: error.errorDescription)
        } catch {
            return Quota(error: "Cursor 用量读取失败")
        }
    }

    // MARK: 登录态

    private static func readTokenSync() -> String? {
        // actor 外同步读：缓存命中已在 actor 处理；这里只做钥匙串/库读取
        if let cli = keychain(service: "cursor-access-token", account: "cursor-user", timeout: 5),
           cli.split(separator: ".").count == 3 {
            return cli
        }
        return desktopToken()
    }

    /// 桌面端现在把 accessToken 封成 `cursor-safe-storage:v1:`。
    /// 钥匙串若弹出授权，超时后本进程不再反复问。
    private static func desktopToken() -> String? {
        // 同步探测阻塞标记：用 UserDefaults 简记，避免跨 actor 再 await
        if let until = UserDefaults.standard.object(forKey: "cursorDesktopBlockedUntil") as? Date,
           Date() < until {
            return nil
        }
        guard let sealed = sqliteValue("cursorAuth/accessToken"), !sealed.isEmpty else { return nil }
        if sealed.split(separator: ".").count == 3 { return sealed }
        let prefix = "cursor-safe-storage:v1:"
        guard sealed.hasPrefix(prefix) else { return nil }
        guard let password = keychain(service: "Cursor Safe Storage", account: "Cursor Key", timeout: 8) else {
            let until = Date().addingTimeInterval(6 * 3600)
            UserDefaults.standard.set(until, forKey: "cursorDesktopBlockedUntil")
            Task { await CursorAuthCache.shared.desktopBlocked(until: until) }
            return nil
        }
        guard let raw = Data(base64Encoded: String(sealed.dropFirst(prefix.count))),
              raw.starts(with: Data("v10".utf8)) else { return nil }
        return decryptV10(raw, password: password)
    }

    private static func sqliteValue(_ key: String) -> String? {
        // 活动库：普通只读，不用 immutable
        guard let db = SQLiteReader(path: CursorProvider.stateDBPath, immutable: false) else { return nil }
        switch db.queryResult("SELECT value FROM ItemTable WHERE key = ?", bind: [key]) {
        case .success(let rows):
            return rows.first?.first
        case .failure:
            return nil
        }
    }

    private static func keychain(service: String, account: String, timeout: TimeInterval) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            proc.terminate()
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty, !text.contains("could not be found") else { return nil }
        return text
    }

    private static func decryptV10(_ data: Data, password: String) -> String? {
        let salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: 16)
        let derived = password.withCString { ptr in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                ptr, strlen(ptr),
                salt, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                1003,
                &key, key.count
            )
        }
        guard derived == kCCSuccess else { return nil }
        let cipher = data.dropFirst(3)
        var clear = [UInt8](repeating: 0, count: cipher.count + kCCBlockSizeAES128)
        var moved = 0
        var iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        let status = cipher.withUnsafeBytes { raw in
            CCCrypt(
                CCOperation(kCCDecrypt),
                CCAlgorithm(kCCAlgorithmAES),
                CCOptions(kCCOptionPKCS7Padding),
                key, key.count,
                &iv,
                raw.baseAddress, cipher.count,
                &clear, clear.count,
                &moved
            )
        }
        guard status == kCCSuccess else { return nil }
        let text = String(bytes: clear.prefix(moved), encoding: .utf8)
        guard let text, text.split(separator: ".").count == 3 else { return nil }
        return text
    }

    // MARK: 请求

    private static func todayRange() -> [String: Any] {
        let start = Calendar.current.startOfDay(for: Date())
        return [
            "startDate": String(Int(start.timeIntervalSince1970 * 1000)),
            "endDate": String(Int(Date().timeIntervalSince1970 * 1000))
        ]
    }

    /// Cursor 聚合接口拒绝过长的时间窗（实测约 90 天可用，180 天起失败）。
    private static func lifetimeRange() -> [String: Any] {
        let start = Date().addingTimeInterval(-90 * 86400)
        return [
            "startDate": String(Int(start.timeIntervalSince1970 * 1000)),
            "endDate": String(Int(Date().timeIntervalSince1970 * 1000))
        ]
    }

    private static func post(_ url: URL, token: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 {
            await invalidateAuth()
            throw ProviderError.notLoggedIn("Cursor 登录已失效，请在 Cursor 里重新登录")
        }
        guard (200..<300).contains(code) else { throw ProviderError.rpc("Cursor 用量接口返回 \(code)") }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.rpc("Cursor 用量接口无返回")
        }
        return obj
    }

    /// 仪表盘上的两根条：Cursor Models = autoPercentUsed，Other Models = apiPercentUsed。
    static func parseWindows(_ raw: [String: Any]) -> Quota {
        guard let plan = raw["planUsage"] as? [String: Any] else {
            return Quota(error: "Cursor 没有返回用量")
        }
        let auto = number(plan["autoPercentUsed"])
        let api = number(plan["apiPercentUsed"])
        guard auto != nil || api != nil else {
            return Quota(error: "Cursor 没有返回模型池百分比")
        }

        let end = epoch(raw["billingCycleEnd"])
        let start = epoch(raw["billingCycleStart"])
        let mins: Int? = {
            guard let start, let end, end > start else { return nil }
            return Int((end - start) / 60)
        }()
        let resets = end.map { Date(timeIntervalSince1970: $0) }

        var windows: [QuotaWindow] = []
        if let auto {
            windows.append(QuotaWindow(id: "cursor-models", title: "Cursor Models",
                                       usedPercent: clamp(auto), resetsAt: resets, durationMins: mins))
        }
        if let api {
            windows.append(QuotaWindow(id: "cursor-other", title: "Other Models",
                                       usedPercent: clamp(api), resetsAt: resets, durationMins: mins))
        }
        return Quota(windows: windows, quotaOK: !windows.isEmpty)
    }

    /// 只计输入 + 输出。字段存在且合计为 0 时返回 0，与「没有数据」区分。
    private static func tokenTotal(_ raw: [String: Any]) -> Int64? {
        let hasInput = raw["totalInputTokens"] != nil
        let hasOutput = raw["totalOutputTokens"] != nil
        guard hasInput || hasOutput else { return nil }
        let input = int64(raw["totalInputTokens"]) ?? 0
        let output = int64(raw["totalOutputTokens"]) ?? 0
        return input + output
    }

    private static func clamp(_ value: Double) -> Double { max(0, min(100, value)) }

    private static func number(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    private static func int64(_ any: Any?) -> Int64? {
        if let n = any as? NSNumber { return n.int64Value }
        if let s = any as? String { return Int64(s) }
        return nil
    }

    private static func epoch(_ any: Any?) -> TimeInterval? {
        let raw: Double?
        if let n = any as? NSNumber { raw = n.doubleValue }
        else if let s = any as? String { raw = Double(s) }
        else { raw = nil }
        guard let raw, raw > 0 else { return nil }
        return raw > 1_000_000_000_000 ? raw / 1000 : raw
    }
}
