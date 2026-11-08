import AppKit

/// 盖在状态栏按钮上的透明感应层：自管 TrackingArea 生命周期。
/// 打开详情仍由控制器用 mouseLocation 轮询兜底（合成鼠标常不触发 entered）。
final class StatusBarHoverSensor: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    private var tracking: NSTrackingArea?

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        // 不用 assumeInside：安装时若指针在外，会错过下一次真正进入。
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect, .enabledDuringMouseDrag],
            owner: self,
            userInfo: nil
        )
        tracking = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        onEnter?()
    }

    override func mouseExited(with event: NSEvent) {
        onExit?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 让点击仍落到下层 NSStatusBarButton（兼容点击打开）。
        nil
    }
}
