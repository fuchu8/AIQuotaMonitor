import AppKit
import ApplicationServices
import CoreGraphics

/// 判断前台普通应用是否处于系统全屏。
/// 优先读 AX `AXFullScreen`（失败则降级）；不用全局 NSEvent 监视，不主动弹权限。
enum FullscreenPresence {
    static func frontmostLooksFullScreen() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.activationPolicy == .regular,
              front.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return false
        }

        if let ax = axFullScreen(pid: front.processIdentifier) {
            return ax
        }

        // AX 不可用时的保守降级：仅认「顶贴齐、几乎铺满」的真全屏，避免把普通最大化误判。
        return cgEdgeToEdgeFullScreen(pid: front.processIdentifier)
    }

    private static func axFullScreen(pid: pid_t) -> Bool? {
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        let focusedStatus = AXUIElementCopyAttributeValue(
            app,
            kAXFocusedWindowAttribute as CFString,
            &focused
        )
        let window: AXUIElement?
        if focusedStatus == .success, let focused {
            window = (focused as! AXUIElement)
        } else {
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let windows = windowsRef as? [AXUIElement],
                  let first = windows.first else {
                return nil
            }
            window = first
        }
        guard let window else { return nil }

        var fsRef: CFTypeRef?
        let read = AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fsRef)
        guard read == .success, let fsRef else { return nil }
        if let flag = fsRef as? Bool { return flag }
        if let num = fsRef as? NSNumber { return num.boolValue }
        return nil
    }

    private static func cgEdgeToEdgeFullScreen(pid: pid_t) -> Bool {
        guard let screen = NSScreen.main else { return false }
        let screenW = screen.frame.width
        let screenH = screen.frame.height
        let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        for w in info {
            let ownerPID = w[kCGWindowOwnerPID as String] as? pid_t ?? 0
            guard ownerPID == pid else { continue }
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }
            guard let b = w[kCGWindowBounds as String] as? [String: Any],
                  let width = b["Width"] as? CGFloat,
                  let height = b["Height"] as? CGFloat,
                  let y = b["Y"] as? CGFloat else { continue }
            // 仅当窗口顶边贴齐屏幕顶且高度接近整屏（盖住菜单栏区域）才算。
            if abs(width - screenW) <= 2, y <= 1, height >= screenH - 2 {
                return true
            }
        }
        return false
    }
}
