import XCTest
@testable import AIQuotaMonitorCore

final class CodexParseTests: XCTestCase {
    func testDifferentLimitIdsWithSameReadingsStaySeparate() throws {
        let raw: [String: Any] = [
            "account": ["account": ["type": "chatgpt", "email": "a@b.c", "planType": "plus"]],
            "rate": [
                "rateLimitsByLimitId": [
                    "pool-a": [
                        "limitId": "pool-a",
                        "limitName": "Pool A",
                        "primary": [
                            "usedPercent": 42.0,
                            "windowDurationMins": 300,
                            "resetsAt": 1_800_000_000.0
                        ]
                    ],
                    "pool-b": [
                        "limitId": "pool-b",
                        "limitName": "Pool B",
                        "primary": [
                            "usedPercent": 42.0,
                            "windowDurationMins": 300,
                            "resetsAt": 1_800_000_000.0
                        ]
                    ]
                ]
            ]
        ]
        let snap = try CodexClient.parse(raw)
        XCTAssertEqual(snap.windows.count, 2)
        XCTAssertEqual(Set(snap.windows.map(\.limitId)), Set(["pool-a", "pool-b"]))
        XCTAssertTrue(snap.windows.contains(where: { $0.title.contains("Pool A") }))
        XCTAssertTrue(snap.windows.contains(where: { $0.title.contains("Pool B") }))
    }

    func testMissingUsedPercentIsNotTreatedAsFullRemaining() throws {
        let raw: [String: Any] = [
            "account": ["account": ["type": "chatgpt", "planType": "plus"]],
            "rate": [
                "rateLimitsByLimitId": [
                    "pool-a": [
                        "limitId": "pool-a",
                        "primary": [
                            "windowDurationMins": 300,
                            "resetsAt": 1_800_000_000.0
                            // usedPercent 缺失
                        ]
                    ]
                ]
            ]
        ]
        let snap = try CodexClient.parse(raw)
        XCTAssertTrue(snap.windows.isEmpty)
        XCTAssertNotNil(snap.errorMessage)
        XCTAssertFalse((snap.errorMessage ?? "").contains("100"))
        // 不得把缺失百分比显示成剩余 100%
        XCTAssertNil(snap.windows.first?.remainingPercent)
    }

    func testCreditsPreferBucketThatHasCreditsField() throws {
        let raw: [String: Any] = [
            "account": ["account": ["type": "chatgpt"]],
            "rate": [
                "rateLimitsByLimitId": [
                    "zzz-other": [
                        "limitId": "zzz-other",
                        "primary": ["usedPercent": 10.0, "windowDurationMins": 300]
                    ],
                    "aaa-main": [
                        "limitId": "aaa-main",
                        "credits": ["hasCredits": true, "unlimited": false, "balance": "12.5"],
                        "primary": ["usedPercent": 20.0, "windowDurationMins": 10080]
                    ]
                ]
            ]
        ]
        let snap = try CodexClient.parse(raw)
        XCTAssertEqual(snap.creditsLimitId, "aaa-main")
        XCTAssertEqual(snap.creditsBalance, "12.5")
        XCTAssertTrue(snap.hasCredits)
    }
}
