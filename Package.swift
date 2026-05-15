// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "iOSFeedBot",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/nmdias/FeedKit.git", from: "9.1.2")
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            pkgConfig: "sqlite3",
            providers: [
                .apt(["libsqlite3-dev"])
            ]
        ),
        .target(
            name: "iOSFeedMetrics",
            dependencies: ["CSQLite"],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "iOSFeedBot",
            dependencies: [
                "iOSFeedMetrics",
                .product(name: "FeedKit", package: "FeedKit")
            ]
        ),
        .executableTarget(
            name: "iOSFeedDashboard",
            dependencies: [
                "iOSFeedMetrics"
            ]
        ),
        .testTarget(
            name: "iOSFeedBotTests",
            dependencies: [
                "iOSFeedBot",
                "iOSFeedMetrics"
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
