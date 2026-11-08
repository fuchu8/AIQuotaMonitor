import XCTest
@testable import WidgetSupport

final class WidgetSnapshotTests: XCTestCase {
    func testScrubRemovesEmailJWTAndAPIKeyShapes() {
        let raw = "user a@b.com token eyJhbGciOiJIUzI1NiJ9.aaa.bbb key oc_abc123XYZ rest"
        let cleaned = WidgetSnapshotStore.scrub(raw)
        XCTAssertFalse(cleaned.contains("@"))
        XCTAssertFalse(cleaned.contains("eyJ"))
        XCTAssertFalse(cleaned.contains("oc_"))
        XCTAssertTrue(cleaned.contains("[redacted]"))
    }

    func testSaveAndLoadRoundTripWithoutSecrets() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aqm-widget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let snap = WidgetSnapshot(
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            refreshMinutes: 5,
            stale: true,
            note: "test",
            items: [
                WidgetSnapshotStore.item(
                    id: "codex",
                    title: "Codex",
                    windowTitle: "5 小时",
                    remaining: 42,
                    used: 58,
                    resetsAt: Date(timeIntervalSince1970: 1_700_003_600),
                    stale: false,
                    error: "fail a@b.com"
                )
            ]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snap)
        let file = dir.appendingPathComponent("widget-snapshot.json")
        try data.write(to: file)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = try decoder.decode(WidgetSnapshot.self, from: Data(contentsOf: file))
        XCTAssertEqual(loaded.items.count, 1)
        XCTAssertEqual(loaded.items[0].remainingPercent, 42)
        XCTAssertEqual(loaded.items[0].error, "fail [redacted]")
        XCTAssertFalse((loaded.items[0].error ?? "").contains("@"))
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("@"))
        XCTAssertFalse(json.lowercased().contains("eyj"))
    }

    func testItemClampsPercents() {
        let item = WidgetSnapshotStore.item(
            id: "x",
            title: "X",
            windowTitle: nil,
            remaining: 120,
            used: -5,
            resetsAt: nil,
            stale: false,
            error: nil
        )
        XCTAssertEqual(item.remainingPercent, 100)
        XCTAssertEqual(item.usedPercent, 0)
    }
}
