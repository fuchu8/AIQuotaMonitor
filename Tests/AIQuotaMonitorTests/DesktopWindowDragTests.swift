import XCTest
import AppKit
@testable import AIQuotaMonitorCore

/// 验证拖动条首击策略；真实窗口跟随拖拽在安装后用合成鼠标验收。
final class DesktopWindowDragTests: XCTestCase {

    @MainActor
    func testDragSurfaceAcceptsFirstMouseOnNonKeyWindow() {
        let win = NSWindow(
            contentRect: NSRect(x: 40, y: 80, width: 200, height: 60),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isReleasedWhenClosed = false
        win.level = .normal

        let surface = DesktopWindowDragSurface(frame: NSRect(x: 0, y: 0, width: 160, height: 28))
        win.contentView = surface
        win.orderFront(nil)

        XCTAssertTrue(surface.acceptsFirstMouse(for: nil),
                      "accessory 未激活时也必须接收首击，否则看起来像不能拖")
        XCTAssertFalse(surface.mouseDownCanMoveWindow,
                       "不依赖 mouseDownCanMoveWindow；由 mouseLocation 跟踪拖动")

        win.orderOut(nil)
    }
}
