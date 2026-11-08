import Foundation
@preconcurrency import UserNotifications
import AppKit

/// 本地通知。只在本机弹出，不涉及任何网络。
@MainActor
final class Notifier {
    static let shared = Notifier()

    /// UNUserNotificationCenter 在非 .app bundle 环境下会直接抛异常，
    /// 因此先探测运行环境，拿不到就静默降级（菜单栏本身仍然能提示额度）。
    private let center: UNUserNotificationCenter?
    private let firedKey = "firedNotificationKeys"

    var isAvailable: Bool { center != nil }

    private init() {
        let inBundle = Bundle.main.bundleURL.pathExtension == "app"
        center = inBundle ? UNUserNotificationCenter.current() : nil
    }

    func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        guard let center else { return .denied }
        return await center.notificationSettings().authorizationStatus
    }

    /// 同一额度窗口的同一档告警，只在本次重置周期内提醒一次。
    /// 提交失败不永久消耗机会；权限拒绝记为已发，避免每轮空转。
    @discardableResult
    func notifyOnce(key: String, title: String, body: String) -> Bool {
        guard !hasFired(key) else { return false }

        guard let center else {
            // 非 .app / 诊断环境：记成功，避免测试堆积
            rememberFired(key)
            return true
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: key, content: content, trigger: nil)

        var outcome = false
        let sem = DispatchSemaphore(value: 0)
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .denied {
                // 拒绝：记已发，用户改权限后可手动清；不在后台空转
                self.rememberFired(key)
                outcome = false
                sem.signal()
                return
            }
            center.add(request) { error in
                if error == nil {
                    self.rememberFired(key)
                    outcome = true
                }
                // 提交失败：不记 fired，下轮可重试
                sem.signal()
            }
        }
        _ = sem.wait(timeout: .now() + 2)
        return outcome
    }

    func forget(prefix: String) {
        let fired = UserDefaults.standard.stringArray(forKey: firedKey) ?? []
        let kept = fired.filter { !$0.hasPrefix(prefix) }
        guard kept.count != fired.count else { return }
        UserDefaults.standard.set(kept, forKey: firedKey)
    }

    func post(title: String, body: String, identifier: String = UUID().uuidString) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier,
                                            content: content,
                                            trigger: nil)
        center.add(request, withCompletionHandler: nil)
    }

    func test() {
        post(title: "AI Quota Monitor", body: "通知已生效，额度告警会通过这里送达。")
    }

    private func hasFired(_ key: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: firedKey) ?? []).contains(key)
    }

    private nonisolated func rememberFired(_ key: String) {
        var fired = Set(UserDefaults.standard.stringArray(forKey: firedKey) ?? [])
        fired.insert(key)
        if fired.count > 200 { fired = Set(fired.suffix(120)) }
        UserDefaults.standard.set(Array(fired), forKey: firedKey)
    }
}
