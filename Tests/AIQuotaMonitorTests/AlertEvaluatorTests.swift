import XCTest
@testable import AIQuotaMonitorCore

final class AlertEvaluatorTests: XCTestCase {
    func testClosingResetNotifyStillAllowsNextCycleLowAlerts() {
        let evaluator = AlertEvaluator(alertAt10: true, alertAt20: true, notifyOnReset: false)
        let windowA = QuotaWindow(
            id: "w",
            title: "5 小时",
            usedPercent: 50,
            resetsAt: Date(timeIntervalSince1970: 1_000_000),
            durationMins: 300
        )
        let d1 = evaluator.consider(name: "Codex", provider: "codex", window: windowA, previous: nil)
        XCTAssertFalse(d1.alert20)

        let low1 = QuotaWindow(
            id: "w",
            title: "5 小时",
            usedPercent: 85,
            resetsAt: Date(timeIntervalSince1970: 1_000_000),
            durationMins: 300
        )
        let d2 = evaluator.consider(name: "Codex", provider: "codex", window: low1, previous: d1.updatedSeen)
        XCTAssertTrue(d2.alert20)
        XCTAssertFalse(d2.sendResetNotification)

        // 新周期：重置到接近满额
        let reset = QuotaWindow(
            id: "w",
            title: "5 小时",
            usedPercent: 2,
            resetsAt: Date(timeIntervalSince1970: 1_000_000 + 6 * 3600),
            durationMins: 300
        )
        let d3 = evaluator.consider(name: "Codex", provider: "codex", window: reset, previous: d2.updatedSeen)
        XCTAssertTrue(d3.clearAlertPrefix)
        XCTAssertFalse(d3.sendResetNotification) // 开关关闭只影响通知，不影响清去重
        XCTAssertFalse(d3.alert20)

        let mid = QuotaWindow(
            id: "w",
            title: "5 小时",
            usedPercent: 50,
            resetsAt: Date(timeIntervalSince1970: 1_000_000 + 6 * 3600),
            durationMins: 300
        )
        let d4 = evaluator.consider(name: "Codex", provider: "codex", window: mid, previous: d3.updatedSeen)
        let low2 = QuotaWindow(
            id: "w",
            title: "5 小时",
            usedPercent: 85,
            resetsAt: Date(timeIntervalSince1970: 1_000_000 + 6 * 3600),
            durationMins: 300
        )
        let d5 = evaluator.consider(name: "Codex", provider: "codex", window: low2, previous: d4.updatedSeen)
        // 第二周期再次跌破 20%：即使关闭重置通知也应提醒
        XCTAssertTrue(d5.alert20)
    }

    func testNotifyOnResetOnlyControlsNotificationNotCycleClear() {
        let on = AlertEvaluator(alertAt10: true, alertAt20: true, notifyOnReset: true)
        let off = AlertEvaluator(alertAt10: true, alertAt20: true, notifyOnReset: false)
        let prev = AlertEvaluator.SeenQuota(resetsAt: 1_000_000, used: 90, cycleKey: "r5")
        let next = QuotaWindow(
            id: "w",
            title: "每周",
            usedPercent: 10,
            resetsAt: Date(timeIntervalSince1970: 1_000_000 + 8 * 86400),
            durationMins: 7 * 1440
        )
        let a = on.consider(name: "X", provider: "p", window: next, previous: prev)
        let b = off.consider(name: "X", provider: "p", window: next, previous: prev)
        XCTAssertEqual(a.clearAlertPrefix, b.clearAlertPrefix)
        XCTAssertTrue(a.clearAlertPrefix)
        XCTAssertTrue(a.sendResetNotification)
        XCTAssertFalse(b.sendResetNotification)
    }
}
