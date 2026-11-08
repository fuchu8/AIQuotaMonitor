import XCTest
@testable import AIQuotaMonitorCore

final class PanelChromeTests: XCTestCase {
    @MainActor
    func testPreferredViewportIsStableAndBelowOldFullScreenHack() {
        // 旧实现先撑 hosting=900 再读 fittingSize，气泡常接近全高（约 860+）。
        XCTAssertEqual(PanelChrome.width, 342)
        XCTAssertEqual(PanelChrome.preferredHeight, 620)
        XCTAssertLessThan(PanelChrome.preferredHeight, 860)
        XCTAssertGreaterThanOrEqual(PanelChrome.preferredHeight, 320)
    }
}
