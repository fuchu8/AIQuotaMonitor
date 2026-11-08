import Foundation
import CoreGraphics

/// 桌面小窗位置：持久化与屏幕变化时的边界钳制（纯函数，便于测试）。
enum DesktopFrameMath {
    /// 略收高度：去掉底栏「拖动」后更紧凑。
    static let defaultSize = CGSize(width: 260, height: 248)
    static let margin: CGFloat = 16

    /// 首次默认：当前屏可见区域右上角内侧。
    static func defaultOrigin(inVisible visible: CGRect, size: CGSize = defaultSize) -> CGPoint {
        CGPoint(
            x: visible.maxX - size.width - margin,
            y: visible.maxY - size.height - margin
        )
    }

    /// 把窗口 origin 钳到 visible 内，保证至少露出 `minVisible` 边长。
    static func clampOrigin(
        _ origin: CGPoint,
        size: CGSize,
        visible: CGRect,
        minVisible: CGFloat = 48
    ) -> CGPoint {
        guard visible.width > 0, visible.height > 0 else { return origin }
        let maxX = visible.maxX - min(minVisible, size.width)
        let maxY = visible.maxY - min(minVisible, size.height)
        let minX = visible.minX - max(0, size.width - minVisible)
        let minY = visible.minY - max(0, size.height - minVisible)
        return CGPoint(
            x: min(max(origin.x, minX), maxX),
            y: min(max(origin.y, minY), maxY)
        )
    }

    /// 在多屏中选包含点最多的可见区域；都不包含则用主屏 visible。
    static func preferredVisibleFrame(
        forOrigin origin: CGPoint,
        size: CGSize,
        screens: [(visible: CGRect, isMain: Bool)]
    ) -> CGRect {
        let frame = CGRect(origin: origin, size: size)
        var best: (CGRect, CGFloat)?
        for screen in screens {
            let overlap = frame.intersection(screen.visible)
            let area = max(0, overlap.width) * max(0, overlap.height)
            if area > 0 {
                if best == nil || area > best!.1 {
                    best = (screen.visible, area)
                }
            }
        }
        if let best { return best.0 }
        if let main = screens.first(where: { $0.isMain })?.visible { return main }
        return screens.first?.visible ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
    }
}
