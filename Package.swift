// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GlassStats",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "GlassStats", targets: ["GlassStats"])],
    targets: [
        .target(name: "DarwinMetrics", linkerSettings: [.linkedLibrary("sqlite3"), .linkedLibrary("curl")]),
        .target(name: "GlassStatsCore", dependencies: ["DarwinMetrics"]),
        .target(name: "WidgetSnapshot"),
        .executableTarget(name: "GlassStats", dependencies: ["GlassStatsCore", "WidgetSnapshot"]),
        .testTarget(name: "GlassStatsCoreTests", dependencies: ["GlassStatsCore"])
    ]
)
