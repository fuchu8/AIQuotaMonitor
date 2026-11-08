import Foundation

/// OpenCode Go 本机日志 Token 增量聚合。
/// 按文件偏移只读追加内容；处理截断/轮转；以请求标识去重；保留聚合结果而非日志原文。
final class GoLogTokenAggregator: @unchecked Sendable {
    static let shared = GoLogTokenAggregator()

    struct Totals: Sendable, Equatable {
        var today: Int64 = 0
        var period: Int64 = 0
        var lifetime: Int64 = 0
        var coverageStart: String?
        var coverageEnd: String?
        var skippedFiles: Int = 0
        var incomplete: Bool = false
        var estimatedByModel: Bool = true
        var ok: Bool = false
        var error: String?
    }

    private struct FileState {
        var inode: UInt64?
        var size: Int64
        var offset: Int64
        var partial: String
    }

    private struct EventKey: Hashable {
        var file: String
        var id: String
    }

    private let lock = NSLock()
    private var files: [String: FileState] = [:]
    private var seenEvents = Set<EventKey>()
    private var today: Int64 = 0
    private var period: Int64 = 0
    private var lifetime: Int64 = 0
    private var coverageStart: String?
    private var coverageEnd: String?
    private var skippedFiles: Int = 0
    private var incomplete = false
    private var cachedDayKey: String = ""
    private var cachedPeriodStart: Date = .distantPast
    private var allowFingerprint: Int = 0

    private let stamp = try? NSRegularExpression(
        pattern: #"^\[(\d{1,2}/\d{1,2}/\d{4}), (\d{1,2}:\d{2}:\d{2} (?:AM|PM))"#
    )
    private let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "M/d/yyyy h:mm:ss a"
        return f
    }()

    func aggregate(periodStart: Date, now: Date = Date(), logsRoot: URL? = nil, allowlist: Set<String>? = nil) -> Totals {
        lock.lock()
        defer { lock.unlock() }

        let dayKey = Fmt.dayKey(now)
        let allow = allowlist ?? Self.loadAllowlist()
        let fp = allow.hashValue
        if dayKey != cachedDayKey || abs(periodStart.timeIntervalSince(cachedPeriodStart)) > 1 || fp != allowFingerprint {
            resetAggregates(keepingFiles: true)
            cachedDayKey = dayKey
            cachedPeriodStart = periodStart
            allowFingerprint = fp
            // 跨日/周期：文件偏移保留，但事件集合与合计重算——最稳是重扫已读区间。
            // 为控制成本：清空偏移，下一轮增量从文件头重建合计。
            for key in files.keys {
                files[key]?.offset = 0
                files[key]?.partial = ""
            }
            seenEvents.removeAll(keepingCapacity: true)
        }

        let root = logsRoot ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".workbuddy/logs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path),
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .fileResourceIdentifierKey],
                options: [.skipsHiddenFiles]
              ) else {
            return Totals(ok: false, error: "未找到 Go 本机日志目录")
        }

        skippedFiles = 0
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)

        while let item = enumerator.nextObject() as? URL {
            guard item.pathExtension.lowercased() == "log" else { continue }
            let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let size = Int64(values?.fileSize ?? 0)
            if size <= 0 { continue }

            let path = item.path
            var state = files[path] ?? FileState(inode: nil, size: 0, offset: 0, partial: "")
            let inode = Self.inode(of: item)

            // 轮转 / 截断：inode 变或体积变小 → 重置偏移
            if let inode, let old = state.inode, inode != old {
                state = FileState(inode: inode, size: size, offset: 0, partial: "")
            } else if size < state.size || size < state.offset {
                state.offset = 0
                state.partial = ""
            }
            state.inode = inode ?? state.inode
            state.size = size

            // 超大文件：已有进度则只读追加；首次遇到超大文件从末尾 8MB 起读并标不完整
            let maxBootstrap: Int64 = 8_000_000
            if state.offset == 0, size > 30_000_000 {
                state.offset = max(0, size - maxBootstrap)
                incomplete = true
                skippedFiles += 1
            }

            guard let handle = try? FileHandle(forReadingFrom: item) else {
                skippedFiles += 1
                continue
            }
            defer { try? handle.close() }

            do {
                try handle.seek(toOffset: UInt64(state.offset))
            } catch {
                skippedFiles += 1
                continue
            }

            var chunk = handle.readDataToEndOfFile()
            if chunk.isEmpty {
                files[path] = state
                continue
            }

            // 拼接上次半行
            if !state.partial.isEmpty, let prefix = state.partial.data(using: .utf8) {
                chunk = prefix + chunk
                state.partial = ""
            }

            guard var text = String(data: chunk, encoding: .utf8) else {
                // 编码失败：推进偏移避免死循环，标记不完整
                state.offset = size
                files[path] = state
                incomplete = true
                skippedFiles += 1
                continue
            }

            // 末尾半行留下轮
            if !text.hasSuffix("\n"), let lastNL = text.lastIndex(of: "\n") {
                state.partial = String(text[text.index(after: lastNL)...])
                text = String(text[..<text.index(after: lastNL)])
            } else if !text.hasSuffix("\n"), !text.contains("\n") {
                state.partial = text
                text = ""
            }

            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for (lineIndex, rawLine) in lines.enumerated() {
                let line = String(rawLine)
                guard line.contains("[ModelProvider]") else { continue }
                guard let brace = line.firstIndex(of: "{"),
                      let obj = try? JSONSerialization.jsonObject(with: Data(line[brace...].utf8)) as? [String: Any]
                else { continue }

                let model = (obj["model"] as? String) ?? ""
                let base = model.hasPrefix("custom-local:")
                    ? String(model.dropFirst("custom-local:".count))
                    : model
                guard allow.contains(base) else { continue }

                // 优先请求标识去重；否则用文件+逻辑偏移近似
                let eventId = (obj["requestId"] as? String)
                    ?? (obj["request_id"] as? String)
                    ?? (obj["id"] as? String)
                    ?? "\(state.offset)+\(lineIndex)"
                let key = EventKey(file: path, id: eventId)
                if seenEvents.contains(key) { continue }
                seenEvents.insert(key)

                let input = Self.int64(obj["input_tokens"]) ?? 0
                let output = Self.int64(obj["output_tokens"]) ?? 0
                let cached = Self.int64(obj["cached_read_tokens"]) ?? 0
                let tokens = max(Int64(0), input - cached) + output
                // 成功解析到字段时 0 也计入（已知合计为 0）
                let ns = line as NSString
                guard let match = stamp?.firstMatch(in: line, options: [],
                                                    range: NSRange(location: 0, length: ns.length)),
                      match.numberOfRanges >= 3 else { continue }
                let dateText = ns.substring(with: match.range(at: 1)) + " " + ns.substring(with: match.range(at: 2))
                guard let when = parser.date(from: dateText) else { continue }

                let day = Fmt.dayKey(when)
                if coverageStart == nil || day < (coverageStart ?? day) { coverageStart = day }
                if coverageEnd == nil || day > (coverageEnd ?? day) { coverageEnd = day }

                lifetime += tokens
                if when >= periodStart { period += tokens }
                if when >= todayStart { today += tokens }
            }

            state.offset = size
            files[path] = state
        }

        // 清理已消失文件
        let existing = Set(files.keys)
        for path in existing where !FileManager.default.fileExists(atPath: path) {
            files.removeValue(forKey: path)
        }

        return Totals(
            today: today,
            period: period,
            lifetime: lifetime,
            coverageStart: coverageStart,
            coverageEnd: coverageEnd,
            skippedFiles: skippedFiles,
            incomplete: incomplete,
            estimatedByModel: true,
            ok: true,
            error: nil
        )
    }

    /// 测试用：清空全部状态
    func resetAll() {
        lock.lock()
        defer { lock.unlock() }
        files.removeAll()
        seenEvents.removeAll()
        resetAggregates(keepingFiles: false)
        cachedDayKey = ""
        cachedPeriodStart = .distantPast
    }

    private func resetAggregates(keepingFiles: Bool) {
        today = 0
        period = 0
        lifetime = 0
        coverageStart = nil
        coverageEnd = nil
        skippedFiles = 0
        incomplete = false
        if !keepingFiles {
            files.removeAll()
            seenEvents.removeAll()
        }
    }

    private static func inode(of url: URL) -> UInt64? {
        guard let values = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]),
              let id = values.fileResourceIdentifier as? NSObject else { return nil }
        return UInt64(bitPattern: Int64(id.hash))
    }

    static func loadAllowlist() -> Set<String> {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".workbuddy/tools/opencode-go-proxy/models-allowlist.json")
        if let data = try? Data(contentsOf: url),
           let rows = try? JSONSerialization.jsonObject(with: data) as? [String] {
            return Set(rows)
        }
        return [
            "deepseek-v4.1-flash", "deepseek-v4-pro",
            "kimi-k3.1-pro", "kimi-k3", "glm-5.3", "glm-5.3-flash",
            "qwen3.8-flash", "qwen3.8-max", "minimax-m3", "grok-4.7"
        ]
    }

    private static func int64(_ any: Any?) -> Int64? {
        if let n = any as? NSNumber { return n.int64Value }
        if let s = any as? String { return Int64(s) }
        return nil
    }
}
