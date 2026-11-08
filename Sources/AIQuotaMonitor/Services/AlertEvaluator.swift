import Foundation

/// 告警状态机：周期推进 / 去重清理 与「是否发送重置通知」解耦，便于单测。
struct AlertEvaluator {
    struct SeenQuota: Codable, Equatable {
        var resetsAt: Double
        var used: Double
        /// 可信周期标识（优先用重置边界桶）；跨睡眠/断网后也能换周期清去重。
        var cycleKey: String
    }

    struct Decision: Equatable {
        var updatedSeen: SeenQuota
        var clearAlertPrefix: Bool
        var sendResetNotification: Bool
        var alert10: Bool
        var alert20: Bool
        var resetKey: String?
        var alert10Key: String?
        var alert20Key: String?
    }

    var alertAt10: Bool
    var alertAt20: Bool
    var notifyOnReset: Bool

    func consider(
        name: String,
        provider: String,
        window: QuotaWindow,
        previous: SeenQuota?
    ) -> Decision {
        let id = "\(provider)|\(window.id)"
        let epoch = window.resetsAt?.timeIntervalSince1970 ?? 0
        let cycleKey = Self.cycleKey(for: window)
        let remaining = window.remainingPercent

        var clearPrefix = false
        var sendReset = false
        var resetKey: String?

        if let previous {
            let cycleChanged = previous.cycleKey != cycleKey && !previous.cycleKey.isEmpty
            let realReset = Self.isRealReset(previous: previous, window: window)
            if cycleChanged || realReset {
                clearPrefix = true
                if notifyOnReset {
                    sendReset = true
                    resetKey = "reset-\(id)-\(cycleKey)"
                }
            }
        }

        var alert10 = false
        var alert20 = false
        var alert10Key: String?
        var alert20Key: String?
        if let previous {
            let prevRemaining = 100 - previous.used
            // 同一周期内：从阈值外跨进来才提醒；换周期后 previous 已是新样本，用 clear 后的去重键。
            if remaining <= 10, prevRemaining > 10, alertAt10 {
                alert10 = true
                alert10Key = "alert-\(id)-10"
            } else if remaining <= 20, prevRemaining > 20, alertAt20 {
                alert20 = true
                alert20Key = "alert-\(id)-20"
            }
        }

        // 换周期后：用「新周期内相对满额」再判一次低额度（覆盖睡眠错过 drop 启发式）
        if clearPrefix {
            if remaining <= 10, alertAt10 {
                alert10 = true
                alert10Key = "alert-\(id)-10"
            } else if remaining <= 20, alertAt20 {
                alert20 = true
                alert20Key = "alert-\(id)-20"
            }
        }

        _ = name
        return Decision(
            updatedSeen: SeenQuota(resetsAt: epoch, used: window.usedPercent, cycleKey: cycleKey),
            clearAlertPrefix: clearPrefix,
            sendResetNotification: sendReset,
            alert10: alert10,
            alert20: alert20,
            resetKey: resetKey,
            alert10Key: alert10Key,
            alert20Key: alert20Key
        )
    }

    /// 固定周期：优先用重置时间桶；滑动空闲窗口用 duration 粗桶。
    static func cycleKey(for window: QuotaWindow) -> String {
        let secs = max(TimeInterval((window.durationMins ?? 60) * 60), 3600)
        let epoch = window.resetsAt?.timeIntervalSince1970 ?? 0
        if epoch > 0 {
            return "r\(Int(epoch / secs))"
        }
        return "u\(Int(window.usedPercent))"
    }

    /// 启发式真实重置：已用明显下降且重置时间跳过窗口大半。
    /// 周期切换不再只依赖这条；它只作为辅助。
    static func isRealReset(previous: SeenQuota, window: QuotaWindow) -> Bool {
        let epoch = window.resetsAt?.timeIntervalSince1970 ?? 0
        let jump = epoch - previous.resetsAt
        let drop = previous.used - window.usedPercent
        let windowSecs = TimeInterval(max(window.durationMins ?? 60, 60) * 60)
        let significantJump = jump > max(30 * 60, windowSecs * 0.5)
        return drop >= 15 && significantJump
    }
}
