import XCTest
@testable import AIQuotaMonitorCore

final class DesktopFrameMathTests: XCTestCase {
    func testDefaultOriginIsTopRightInset() {
        let visible = CGRect(x: 100, y: 50, width: 1200, height: 700)
        let origin = DesktopFrameMath.defaultOrigin(inVisible: visible)
        let size = DesktopFrameMath.defaultSize
        XCTAssertEqual(origin.x, visible.maxX - size.width - DesktopFrameMath.margin, accuracy: 0.5)
        XCTAssertEqual(origin.y, visible.maxY - size.height - DesktopFrameMath.margin, accuracy: 0.5)
    }

    func testClampPullsFullyOffscreenFrameBack() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let size = CGSize(width: 200, height: 100)
        let far = CGPoint(x: 5000, y: -2000)
        let clamped = DesktopFrameMath.clampOrigin(far, size: size, visible: visible, minVisible: 48)
        let frame = CGRect(origin: clamped, size: size)
        XCTAssertFalse(frame.intersection(visible).isNull)
        XCTAssertGreaterThan(frame.intersection(visible).width, 40)
    }

    func testPreferredVisibleUsesOverlappingScreen() {
        let screens = [
            (visible: CGRect(x: 0, y: 0, width: 800, height: 600), isMain: true),
            (visible: CGRect(x: 800, y: 0, width: 800, height: 600), isMain: false)
        ]
        let origin = CGPoint(x: 900, y: 100)
        let preferred = DesktopFrameMath.preferredVisibleFrame(
            forOrigin: origin,
            size: CGSize(width: 200, height: 100),
            screens: screens
        )
        XCTAssertEqual(preferred.origin.x, 800, accuracy: 0.1)
    }

    func testPreferredFallsBackToMainWhenNoOverlap() {
        let screens = [
            (visible: CGRect(x: 0, y: 0, width: 800, height: 600), isMain: true),
            (visible: CGRect(x: 800, y: 0, width: 800, height: 600), isMain: false)
        ]
        let preferred = DesktopFrameMath.preferredVisibleFrame(
            forOrigin: CGPoint(x: -4000, y: -4000),
            size: CGSize(width: 200, height: 100),
            screens: screens
        )
        XCTAssertEqual(preferred.origin.x, 0, accuracy: 0.1)
    }
}
