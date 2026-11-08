// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIQuotaMonitor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AIQuotaMonitor", targets: ["AIQuotaMonitor"]),
        .library(name: "WidgetSupport", targets: ["WidgetSupport"])
    ],
    targets: [
        .target(
            name: "WidgetSupport",
            path: "Sources/WidgetSupport",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .target(
            name: "AIQuotaMonitorCore",
            dependencies: ["WidgetSupport"],
            path: "Sources/AIQuotaMonitor",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "AIQuotaMonitor",
            dependencies: ["AIQuotaMonitorCore"],
            path: "Sources/App",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "AIQuotaMonitorTests",
            dependencies: ["AIQuotaMonitorCore", "WidgetSupport"],
            path: "Tests/AIQuotaMonitorTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
