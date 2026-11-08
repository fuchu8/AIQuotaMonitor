import AppKit
import SwiftUI

/// 桌面窗根视图：SwiftUI 在下层，AppKit 拖动手把叠在上层。
///
/// `NSViewRepresentable` 嵌在 SwiftUI 里时，NonKey 窗上经常吃不到鼠标
/// （AX 树里甚至没有拖动条）。把拖动面放在 hosting 之外可稳定命中。
final class DesktopWindowRootView: NSView {
    private var hosting: NSHostingView<AnyView>?
    private let topDrag = DesktopWindowDragSurface()

    override var isFlipped: Bool { true }

    func embed(hosting: NSHostingView<AnyView>) {
        self.hosting?.removeFromSuperview()
        self.hosting = hosting
        hosting.translatesAutoresizingMaskIntoConstraints = true
        addSubview(hosting, positioned: .below, relativeTo: nil)

        topDrag.label = "AI Quota"
        topDrag.toolTip = "按住此处拖动窗口"
        // 勿用 .button：系统可能把点击当 AX Press 吞掉，导致无法拖动。
        topDrag.setAccessibilityElement(true)
        topDrag.setAccessibilityRole(.layoutArea)
        topDrag.setAccessibilityTitle("拖动桌面窗")
        topDrag.setAccessibilityHelp("按住并拖动以移动窗口位置")

        addSubview(topDrag)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        applyRoundedMask()
        hosting?.frame = bounds

        let pad: CGFloat = 14
        let handleH: CGFloat = 30
        // 右侧留给刷新/详情/关闭按钮
        let rightReserve: CGFloat = 96
        let topWidth = max(120, bounds.width - pad * 2 - rightReserve)
        topDrag.frame = CGRect(x: pad, y: pad - 2, width: topWidth, height: handleH)
    }

    /// 窗口阴影按这个圆角裁，避免底角露出方角黑边。
    private func applyRoundedMask() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        layer?.cornerRadius = 16
        if #available(macOS 13.0, *) {
            layer?.cornerCurve = .continuous
        }
        layer?.masksToBounds = true
        hosting?.wantsLayer = true
        hosting?.layer?.isOpaque = false
        hosting?.layer?.backgroundColor = NSColor.clear.cgColor
    }
}
