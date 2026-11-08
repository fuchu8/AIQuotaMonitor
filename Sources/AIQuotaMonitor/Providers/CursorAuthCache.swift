import Foundation

/// Cursor / Grok 共用的本机登录态缓存。合并并发读取，统一失效。
actor CursorAuthCache {
    static let shared = CursorAuthCache()

    private var cachedToken: String?
    private var desktopBlockedUntil: Date?
    private var inflight: Task<String?, Never>?

    func token(reader: @escaping @Sendable () -> String?) async -> String? {
        if let cachedToken, cachedToken.split(separator: ".").count == 3 {
            return cachedToken
        }
        if let inflight {
            return await inflight.value
        }
        let task = Task.detached(priority: .utility) {
            reader()
        }
        inflight = task
        let value = await task.value
        inflight = nil
        if let value, value.split(separator: ".").count == 3 {
            cachedToken = value
        }
        return value
    }

    func invalidate() {
        cachedToken = nil
        inflight?.cancel()
        inflight = nil
    }

    func desktopBlocked(until: Date) {
        desktopBlockedUntil = until
    }

    func isDesktopBlocked(now: Date = Date()) -> Bool {
        guard let desktopBlockedUntil else { return false }
        return now < desktopBlockedUntil
    }

    func clearDesktopBlock() {
        desktopBlockedUntil = nil
    }
}
