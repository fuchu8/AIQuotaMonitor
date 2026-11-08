import Foundation

enum ProviderError: LocalizedError {
    case notInstalled(String)
    case notLoggedIn(String)
    case spawnFailed(String)
    case timeout
    case rpc(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let m): return m
        case .notLoggedIn(let m): return m.isEmpty ? "未登录" : m
        case .spawnFailed(let m): return "启动失败：\(m)"
        case .timeout: return "读取超时"
        case .rpc(let m): return m
        case .io(let m): return m
        }
    }
}
