import AppKit

/// AppKit 拖动条（由 `DesktopWindowRootView` 叠在 SwiftUI 之上使用）。
///
/// 根因：`NSHostingView` / `NSViewRepresentable` 嵌在 SwiftUI 时经常吃不到鼠标；
/// `isMovableByWindowBackground` 在 NonKey accessory 窗上不可靠。
/// 这里用 `performDrag(with:)` + `acceptsFirstMouse`。
final class DesktopWindowDragSurface: NSView {
    var label: String = "拖动"

    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 不再依赖 mouseDownCanMoveWindow（对 NonKey + SwiftUI 宿主不可靠）。
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        // NonKey 窗上 `performDrag` 对合成/部分真实拖移不可靠；改用屏幕坐标跟踪。
        // 坐标系：NSEvent.mouseLocation 与 window.frame 同为 Cocoa 底左原点。
        let startMouse = NSEvent.mouseLocation
        let startOrigin = window.frame.origin

        while true {
            guard let next = window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: Date.distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) else { break }

            let current = NSEvent.mouseLocation
            let origin = CGPoint(
                x: startOrigin.x + (current.x - startMouse.x),
                y: startOrigin.y + (current.y - startMouse.y)
            )
            window.setFrameOrigin(origin)

            if next.type == .leftMouseUp {
                break
            }
        }
    }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)

        // 安静手把：浅底 + 细边，避免上下两块「拖动」按钮感。
        let fill = NSColor.labelColor.withAlphaComponent(0.045)
        fill.setFill()
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        path.fill()

        NSColor.labelColor.withAlphaComponent(0.08).setStroke()
        path.lineWidth = 1
        path.stroke()

        // 六点握把
        let gripColor = NSColor.secondaryLabelColor.withAlphaComponent(0.75)
        gripColor.setFill()
        let gripOrigin = CGPoint(x: rect.minX + 9, y: rect.midY - 4.5)
        for row in 0..<3 {
            for col in 0..<2 {
                let r = CGRect(
                    x: gripOrigin.x + CGFloat(col) * 5,
                    y: gripOrigin.y + CGFloat(row) * 3.5,
                    width: 2.0,
                    height: 2.0
                )
                ctx.fillEllipse(in: r)
            }
        }

        let text = label as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let size = text.size(withAttributes: attrs)
        let textOrigin = CGPoint(
            x: gripOrigin.x + 16,
            y: rect.midY - size.height / 2
        )
        text.draw(at: textOrigin, withAttributes: attrs)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 28)
    }
}
